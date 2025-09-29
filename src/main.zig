const std = @import("std");
const build_options = @import("build_options");
const log = @import("log.zig");
const nix = @import("nix.zig");
const gdb = @import("gdb.zig");
const allocator = @import("allocator.zig");
const args_parser = @import("args_parser.zig");
const config_parser = @import("config_parser.zig");

const Allocator = std.mem.Allocator;

const Pmem = @import("devices/pmem.zig");
const Uart = @import("devices/uart.zig");
const Rtc = @import("devices/rtc.zig");
const block_devices = @import("devices/block.zig");
const BlockPci = block_devices.BlockPci;
const BlockMmio = block_devices.BlockMmio;
const BlockPciIoUring = block_devices.BlockPciIoUring;
const BlockMmioIoUring = block_devices.BlockMmioIoUring;
const VhostNet = @import("devices/vhost-net.zig").VhostNet;
const VirtioNet = @import("devices/virtio-net.zig").VirtioNet;

const Ecam = @import("virtio/ecam.zig");
const EventLoop = @import("event_loop.zig");
const EventFd = @import("eventfd.zig");
const CmdLine = @import("cmdline.zig");
const FDT = @import("fdt.zig");
const Gicv2 = @import("gicv2.zig");
const Kvm = @import("kvm.zig");
const Memory = @import("memory.zig");
const Mmio = @import("mmio.zig");
const Vcpu = @import("vcpu.zig");
const Vm = @import("vm.zig");
const IoUring = @import("io_uring.zig");

pub const std_options = std.Options{
    .page_size_min = build_options.host_page_size,
};

pub const log_options = log.Options{
    .level = .Info,
    .colors = true,
};

const Args = struct {
    config_path: ?[]const u8 = null,
};

// All of these types are allocated from a single arena. In order to easily determine
// the size of that arena it is better to have all of them be easily allocated one right
// after another.
fn check_aligments() void {
    inline for (.{
        Vcpu,
        std.Thread,
        BlockMmio,
        BlockPci,
        BlockMmioIoUring,
        VirtioNet,
        VhostNet,
    }) |t| {
        log.comptime_assert(
            @src(),
            @alignOf(t) == 8 and @sizeOf(t) % 8 == 0,
            "{s} aligment must be 8 and size must be a multiple of 8. Alignment: {d} Size: {d}",
            .{
                @typeName(t),
                @alignOf(t),
                @sizeOf(t),
            },
        );
    }
}

pub fn main() !void {
    comptime check_aligments();

    const start_time = try std.time.Instant.now();
    const args = try args_parser.parse(Args);
    if (args.config_path == null) {
        try args_parser.print_help(Args);
        return;
    }
    const config_parse_result = try config_parser.parse_file(nix.System, args.config_path.?);
    const config = &config_parse_result.config;

    var net_mmio_count: u32 = 0;
    var net_vhost_mmio_count: u32 = 0;
    for (config.networks.networks.slice_const()) |*net_config| {
        if (net_config.vhost) {
            net_vhost_mmio_count += 1;
        } else {
            net_mmio_count += 1;
        }
    }

    var block_mmio_count: u32 = 0;
    var block_pci_count: u32 = 0;
    var block_mmio_io_uring_count: u32 = 0;
    for (config.drives.drives.slice_const()) |*drive_config| {
        if (drive_config.io_uring) {
            block_mmio_io_uring_count += 1;
        } else if (drive_config.pci) {
            block_pci_count += 1;
        } else {
            block_mmio_count += 1;
        }
    }

    const permanent_memory_size =
        @sizeOf(Vcpu) * config.machine.vcpus +
        @sizeOf(std.Thread) * config.machine.vcpus +
        @sizeOf(BlockMmio) * block_mmio_count +
        @sizeOf(BlockPci) * block_pci_count +
        @sizeOf(BlockMmioIoUring) * block_mmio_io_uring_count +
        @sizeOf(VirtioNet) * net_mmio_count +
        @sizeOf(VhostNet) * net_vhost_mmio_count;

    log.info(@src(), "permanent memory size: {} bytes", .{permanent_memory_size});
    var permanent_memory = allocator.PermanentMemory.init(nix.System, permanent_memory_size);
    const permanent_alloc = permanent_memory.allocator();

    var memory = Memory.init(nix.System, config.machine.memory_mb << 20);
    const load_result =
        memory.load_linux_kernel(nix.System, config.kernel.path);

    var guest_memory = allocator.GuestMemory.init(&memory, load_result.size);
    const tmp_alloc = guest_memory.allocator();

    const kvm = Kvm.new(nix.System);

    // create vm
    var vm = Vm.new(nix.System, &kvm);
    vm.set_memory(nix.System, .{
        .guest_phys_addr = Memory.DRAM_START,
        .memory_size = memory.mem.len,
        .userspace_addr = @intFromPtr(memory.mem.ptr),
    });

    // create vcpu
    const kvi = vm.get_preferred_target(nix.System);
    const vcpu_exit_event = EventFd.new(nix.System, 0, nix.EFD_NONBLOCK);
    const vcpu_mmap_size = kvm.vcpu_mmap_size(nix.System);

    var vcpus = try permanent_alloc.alloc(Vcpu, config.machine.vcpus);
    for (vcpus, 0..) |*vcpu, i| {
        vcpu.* = Vcpu.new(nix.System, &vm, i, vcpu_exit_event, vcpu_mmap_size);
        vcpu.init(nix.System, kvi);
    }

    // create interrupt controller
    Gicv2.new(nix.System, &vm);

    // attach pmem
    var last_addr = Memory.align_addr(memory.last_addr(), Pmem.ALIGNMENT);
    const pmem_infos = try tmp_alloc.alloc(Pmem.Info, config.pmems.pmems.len);
    for (config.pmems.pmems.slice_const(), pmem_infos) |*pmem_config, *info| {
        info.start = last_addr;
        info.len = Pmem.attach(nix.System, &vm, pmem_config.path, info.start);
        last_addr += info.len;
    }

    // create mmio devices
    var ecam: Ecam = .{};
    var mmio = Mmio.new(&ecam);
    var el = EventLoop.new(nix.System);

    const uart_device_info = if (config.uart.enabled) mmio.allocate() else undefined;
    const rtc_device_info = mmio.allocate();
    mmio.start_mmio_opt();

    // preallocate all mmio regions for the devices. This is needed to
    // pass a single slice of mmio regions to the fdt builder.
    const block_mmio_info_count = block_mmio_count +
        block_mmio_io_uring_count;
    const net_mmio_info_count = net_mmio_count +
        net_vhost_mmio_count;
    const mmio_info_count = block_mmio_info_count + net_mmio_info_count;
    const mmio_infos = try tmp_alloc.alloc(Mmio.MmioDeviceInfo, mmio_info_count);
    for (mmio_infos) |*info|
        info.* = mmio.allocate_virtio();

    var mmio_block_infos = mmio_infos[0..block_mmio_info_count];
    var mmio_net_infos = mmio_infos[block_mmio_info_count..][0..net_mmio_info_count];

    // configure terminal for uart in/out
    const state = if (config.uart.enabled) configure_terminal(nix.System) else undefined;
    var uart: Uart = undefined;
    if (config.uart.enabled) {
        uart = Uart.new(
            nix.System,
            &vm,
            nix.STDIN_FILENO,
            nix.STDOUT_FILENO,
            uart_device_info,
        );
        mmio.add_device(.{
            .ptr = &uart,
            .read_ptr = @ptrCast(&Uart.read),
            .write_ptr = @ptrCast(&Uart.write_default),
        });
        el.add_event(
            nix.System,
            nix.STDIN,
            @ptrCast(&Uart.event_read_input),
            &uart,
        );
    } else undefined;

    var rtc: Rtc = .{};
    mmio.add_device(.{
        .ptr = &rtc,
        .read_ptr = @ptrCast(&Rtc.read),
        .write_ptr = @ptrCast(&Rtc.write),
    });

    var io_uring: IoUring = undefined;
    if (block_mmio_io_uring_count != 0) {
        io_uring = IoUring.init(nix.System, 256);
        el.add_event(
            nix.System,
            io_uring.eventfd.fd,
            @ptrCast(&IoUring.event_process_event),
            @ptrCast(&io_uring),
        );
    }

    const mmio_blocks = try create_block_mmio(
        permanent_alloc,
        &vm,
        &mmio,
        &memory,
        &el,
        mmio_block_infos[0..block_mmio_count],
        config.drives.drives.slice_const(),
    );
    mmio_block_infos = mmio_block_infos[block_mmio_count..];
    defer for (mmio_blocks) |*block|
        block.sync(nix.System);

    const mmio_io_uring_blocks = try create_block_mmio_io_uring(
        permanent_alloc,
        &vm,
        &mmio,
        &memory,
        &el,
        &io_uring,
        mmio_block_infos[0..block_mmio_io_uring_count],
        config.drives.drives.slice_const(),
    );
    mmio_block_infos = mmio_block_infos[block_mmio_io_uring_count..];
    defer for (mmio_io_uring_blocks) |*block|
        block.sync(nix.System);

    const pci_blocks = try create_block_pci(
        permanent_alloc,
        &vm,
        &mmio,
        &memory,
        &el,
        &ecam,
        block_pci_count,
        config.drives.drives.slice_const(),
    );
    defer for (pci_blocks) |*block|
        block.sync(nix.System);

    try create_net_mmio(
        permanent_alloc,
        &vm,
        &mmio,
        &memory,
        &el,
        mmio_net_infos[0..net_mmio_count],
        config.networks.networks.slice_const(),
    );
    mmio_net_infos = mmio_net_infos[net_mmio_count..];

    try create_net_mmio_vhost(
        permanent_alloc,
        &vm,
        &mmio,
        &memory,
        mmio_net_infos[0..net_vhost_mmio_count],
        config.networks.networks.slice_const(),
    );
    mmio_net_infos = mmio_net_infos[net_vhost_mmio_count..];

    // create kernel cmdline
    var cmdline = try CmdLine.new(tmp_alloc, 128);
    try cmdline.append(config.machine.cmdline);
    for (config.drives.drives.slice_const(), 0..) |*drive_config, i| {
        if (drive_config.rootfs) {
            var name_buff: [32]u8 = undefined;
            const mod = if (drive_config.read_only) "ro" else "rw";
            var letter: u8 = 'a' + @as(u8, @intCast(i));
            // pci block will be initialized after mmio ones
            if (drive_config.pci) {
                // There can only be less than 256 drives
                letter += @intCast(block_mmio_info_count);
            }
            const name = try std.fmt.bufPrint(
                &name_buff,
                " root=/dev/vd{c} {s}",
                .{ letter, mod },
            );
            log.info(@src(), "Using root cmd line params: {s}", .{name});
            try cmdline.append(name);
            break;
        }
    } else for (config.pmems.pmems.slice_const(), 0..) |*pm, i| {
        if (pm.rootfs) {
            var name_buff: [64]u8 = undefined;
            const name = try std.fmt.bufPrint(
                &name_buff,
                " root=/dev/pmem{d} rw rootflags=dax",
                .{i},
            );
            log.info(@src(), "Using root cmd line params: {s}", .{name});
            try cmdline.append(name);
            break;
        }
    } else {
        @panic("No rootfs device selected");
    }
    if (config.uart.enabled) try Uart.add_to_cmdline(&cmdline, uart_device_info);

    const cmdline_0 = try cmdline.sentinel_str();

    // create fdt
    const mpidrs = try tmp_alloc.alloc(u64, config.machine.vcpus);
    for (mpidrs, vcpus) |*mpidr, *vcpu| {
        mpidr.* = vcpu.get_reg(nix.System, Vcpu.MPIDR_EL1);
    }

    const fdt_addr = FDT.create_fdt(
        nix.System,
        tmp_alloc,
        &memory,
        mpidrs,
        cmdline_0,
        if (config.uart.enabled) uart_device_info else null,
        rtc_device_info,
        mmio_infos,
        pmem_infos,
    );

    // configure vcpus
    vcpus[0].set_reg(nix.System, u64, Vcpu.PC, load_result.start);
    vcpus[0].set_reg(nix.System, u64, Vcpu.REGS0, @as(u64, fdt_addr));
    for (vcpus) |*vcpu| {
        vcpu.set_reg(nix.System, u64, Vcpu.PSTATE, Vcpu.PSTATE_FAULT_BITS_64);
    }
    el.add_event(nix.System, vcpu_exit_event.fd, @ptrCast(&EventLoop.stop), &el);

    // free config memory
    config_parse_result.deinit(nix.System);

    // start vcpu threads
    const vcpu_threads = try permanent_alloc.alloc(std.Thread, config.machine.vcpus);
    log.debug(@src(), "starting vcpu threads", .{});
    // TODO this does linux futex syscalls. Maybe can be replaced
    // by simple atomic value?
    var barrier: std.Thread.ResetEvent = .{};
    for (vcpu_threads, vcpus) |*t, *vcpu| {
        t.* = try nix.System.spawn_thread(
            .{},
            Vcpu.run_threaded,
            .{ vcpu, nix.System, &barrier, &mmio, &start_time },
        );
    }

    if (config.gdb) |gdb_config| {
        // start gdb server
        var gdb_server = try gdb.GdbServer.init(
            nix.System,
            gdb_config.socket_path,
            vcpus,
            vcpu_threads,
            &barrier,
            &memory,
            &mmio,
            &el,
        );
        el.add_event(
            nix.System,
            gdb_server.connection.stream.handle,
            @ptrCast(&gdb.GdbServer.process_request),
            &gdb_server,
        );

        // start event loop
        el.run(nix.System);
    } else {
        // start vcpus
        barrier.set();

        // start event loop
        el.run(nix.System);
    }

    log.info(@src(), "Shutting down", .{});
    if (config.uart.enabled) restore_terminal(nix.System, &state);
    return;
}

fn create_block_mmio(
    alloc: Allocator,
    vm: *Vm,
    mmio: *Mmio,
    memory: *Memory,
    event_loop: *EventLoop,
    mmio_infos: []const Mmio.MmioDeviceInfo,
    configs: []const config_parser.DriveConfig,
) ![]const BlockMmio {
    const blocks = try alloc.alloc(BlockMmio, mmio_infos.len);
    var index: u8 = 0;
    for (configs) |*config| {
        if (!config.io_uring and !config.pci) {
            const block = &blocks[index];
            const info = mmio_infos[index];
            index += 1;

            block.* = BlockMmio.new(
                nix.System,
                vm,
                config.path,
                config.read_only,
                memory,
                info,
            );
            mmio.add_device_virtio(.{
                .ptr = block,
                .read_ptr = @ptrCast(&BlockMmio.read),
                .write_ptr = @ptrCast(&BlockMmio.write_default),
            });
            event_loop.add_event(
                nix.System,
                block.context.queue_events[0].fd,
                @ptrCast(&BlockMmio.event_process_queue),
                block,
            );
        }
    }
    return blocks;
}

fn create_block_mmio_io_uring(
    alloc: Allocator,
    vm: *Vm,
    mmio: *Mmio,
    memory: *Memory,
    event_loop: *EventLoop,
    io_uring: *IoUring,
    mmio_infos: []const Mmio.MmioDeviceInfo,
    configs: []const config_parser.DriveConfig,
) ![]const BlockMmioIoUring {
    const blocks = try alloc.alloc(BlockMmioIoUring, mmio_infos.len);
    var index: u8 = 0;
    for (configs) |*config| {
        if (config.io_uring and !config.pci) {
            const block = &blocks[index];
            const info = mmio_infos[index];
            index += 1;
            block.* = BlockMmioIoUring.new(
                nix.System,
                vm,
                config.path,
                config.read_only,
                memory,
                info,
            );
            block.io_uring_device = io_uring.add_device(
                @ptrCast(&BlockMmioIoUring.event_process_io_uring_event),
                block,
            );
            mmio.add_device_virtio(.{
                .ptr = block,
                .read_ptr = @ptrCast(&BlockMmioIoUring.read),
                .write_ptr = @ptrCast(&BlockMmioIoUring.write_default),
            });
            event_loop.add_event(
                nix.System,
                block.context.queue_events[0].fd,
                @ptrCast(&BlockMmioIoUring.event_process_queue),
                block,
            );
        }
    }
    return blocks;
}

fn create_block_pci(
    alloc: Allocator,
    vm: *Vm,
    mmio: *Mmio,
    memory: *Memory,
    event_loop: *EventLoop,
    ecam: *Ecam,
    pci_blocks_count: u32,
    configs: []const config_parser.DriveConfig,
) ![]const BlockPci {
    const blocks = try alloc.alloc(BlockPci, pci_blocks_count);
    var index: u8 = 0;
    for (configs) |*config| {
        if (!config.io_uring and config.pci) {
            const block = &blocks[index];
            index += 1;

            const info = mmio.allocate_pci();
            ecam.add_header(
                block_devices.TYPE_BLOCK,
                @intFromEnum(Ecam.PciClass.MassStorage),
                @intFromEnum(Ecam.PciMassStorageSubclass.NvmeController),
                info.bar_addr,
            );
            block.* = BlockPci.new(
                nix.System,
                vm,
                config.path,
                config.read_only,
                memory,
                info,
            );
            mmio.add_device_pci(.{
                .ptr = block,
                .read_ptr = @ptrCast(&BlockPci.read),
                .write_ptr = @ptrCast(&BlockPci.write_default),
            });
            event_loop.add_event(
                nix.System,
                block.context.queue_events[0].fd,
                @ptrCast(&BlockPci.event_process_queue),
                block,
            );
        }
    }
    return blocks;
}

fn create_net_mmio(
    alloc: Allocator,
    vm: *Vm,
    mmio: *Mmio,
    memory: *Memory,
    event_loop: *EventLoop,
    mmio_infos: []const Mmio.MmioDeviceInfo,
    configs: []const config_parser.NetConfig,
) !void {
    const nets = try alloc.alloc(VirtioNet, mmio_infos.len);
    var index: u8 = 0;
    for (configs) |*config| {
        if (!config.vhost) {
            const net = &nets[index];
            const mmio_info = mmio_infos[index];
            index += 1;

            net.* = VirtioNet.new(
                nix.System,
                vm,
                config.dev_name,
                config.mac,
                memory,
                mmio_info,
            );
            mmio.add_device_virtio(.{
                .ptr = net,
                .read_ptr = @ptrCast(&VirtioNet.read),
                .write_ptr = @ptrCast(&VirtioNet.write_default),
            });
            event_loop.add_event(
                nix.System,
                net.context.queue_events[0].fd,
                @ptrCast(&VirtioNet.event_process_rx),
                net,
            );
            event_loop.add_event(
                nix.System,
                net.context.queue_events[1].fd,
                @ptrCast(&VirtioNet.event_process_tx),
                net,
            );
            event_loop.add_event(
                nix.System,
                net.tun,
                @ptrCast(&VirtioNet.event_process_tap),
                net,
            );
        }
    }
}

fn create_net_mmio_vhost(
    alloc: Allocator,
    vm: *Vm,
    mmio: *Mmio,
    memory: *Memory,
    mmio_infos: []const Mmio.MmioDeviceInfo,
    configs: []const config_parser.NetConfig,
) !void {
    const nets = try alloc.alloc(VhostNet, mmio_infos.len);
    var index: u8 = 0;
    for (configs) |*config| {
        if (config.vhost) {
            const net = &nets[index];
            const mmio_info = mmio_infos[index];
            index += 1;

            net.* = VhostNet.new(
                nix.System,
                vm,
                config.dev_name,
                config.mac,
                memory,
                mmio_info,
            );
            mmio.add_device_virtio(.{
                .ptr = net,
                .read_ptr = @ptrCast(&VhostNet.read),
                .write_ptr = @ptrCast(&VhostNet.write_default),
            });
        }
    }
}

fn configure_terminal(comptime System: type) nix.termios {
    var ttystate: nix.termios = undefined;
    var ttysave: nix.termios = undefined;

    _ = System.tcgetattr(nix.STDIN, &ttystate);
    ttysave = ttystate;

    //turn off canonical mode and echo
    ttystate.lflag.ECHO = false;
    ttystate.lflag.ICANON = false;
    //minimum of number input read.
    ttystate.cc[4] = 1;

    //set the terminal attributes.
    _ = System.tcsetattr(nix.STDIN, nix.TCSA.NOW, &ttystate);
    return ttysave;
}

fn restore_terminal(comptime System: type, state: *const nix.termios) void {
    //set the terminal attributes.
    _ = System.tcsetattr(nix.STDIN, nix.TCSA.NOW, state);
}

comptime {
    _ = @import("./virtio/queue.zig");
    _ = @import("./virtio/iov_ring.zig");
    _ = @import("./ring_buffer.zig");
}
