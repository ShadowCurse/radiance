const std = @import("std");
const build_options = @import("build_options");
const log = @import("log.zig");
const nix = @import("nix.zig");
const allocator = @import("allocator.zig");
const args_parser = @import("args_parser.zig");
const config_parser = @import("config_parser.zig");

const gdb = @import("gdb.zig");

const Pmem = @import("devices/pmem.zig");
const Uart = @import("devices/uart.zig");
const Rtc = @import("devices/rtc.zig");
const _virtio_block = @import("devices/virtio-block.zig");
const VirtioBlock = _virtio_block.VirtioBlock;
const VirtioBlockIoUring = _virtio_block.VirtioBlockIoUring;
const VhostNet = @import("devices/vhost-net.zig").VhostNet;
const VirtioNet = @import("devices/virtio-net.zig").VirtioNet;

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
    config_path: []const u8,
};

pub fn main() !void {
    const start_time = try std.time.Instant.now();
    const args = try args_parser.parse(Args);
    const config_parse_result = try config_parser.parse_file(nix.System, args.config_path);
    const config = &config_parse_result.config;

    var vhost_net_count: u32 = 0;
    var virtio_net_count: u32 = 0;
    for (config.networks.networks.slice()) |*net_config| {
        if (net_config.vhost) {
            vhost_net_count += 1;
        } else {
            virtio_net_count += 1;
        }
    }

    var virtio_block_count: u32 = 0;
    var virtio_block_io_uring_count: u32 = 0;
    for (config.drives.drives.slice()) |*drive_config| {
        if (drive_config.io_uring) {
            virtio_block_io_uring_count += 1;
        } else {
            virtio_block_count += 1;
        }
    }

    const permanent_memory_size =
        @sizeOf(Vcpu) * config.machine.vcpus +
        @sizeOf(std.Thread) * config.machine.vcpus +
        @sizeOf(VirtioBlock) * virtio_block_count +
        @sizeOf(VirtioBlockIoUring) * virtio_block_io_uring_count +
        @sizeOf(VirtioNet) * virtio_net_count +
        @sizeOf(VhostNet) * vhost_net_count;

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
        .guest_phys_addr = memory.guest_addr,
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
    for (config.pmems.pmems.slice(), pmem_infos) |*pmem_config, *info| {
        info.start = last_addr;
        info.len = Pmem.attach(nix.System, &vm, pmem_config.path, info.start);
        last_addr += info.len;
    }

    // create mmio devices
    var mmio = Mmio.new();
    const uart_device_info = if (config.uart.enabled) mmio.allocate() else undefined;
    const rtc_device_info = mmio.allocate();
    mmio.start_mmio_opt();

    const virtio_device_infos_num = config.drives.drives.len + config.networks.networks.len;
    var virtio_device_infos = try tmp_alloc.alloc(Mmio.MmioDeviceInfo, virtio_device_infos_num);
    for (0..virtio_device_infos_num) |i| {
        virtio_device_infos[i] = mmio.allocate_virtio();
    }

    var uart = if (config.uart.enabled) Uart.new(
        nix.System,
        &vm,
        nix.STDIN_FILENO,
        nix.STDOUT_FILENO,
        uart_device_info,
    ) else undefined;
    var rtc = Rtc.new();

    var io_uring: IoUring = undefined;
    if (virtio_block_io_uring_count != 0)
        io_uring = IoUring.init(nix.System, 256);

    const virtio_blocks = try permanent_alloc.alloc(VirtioBlock, virtio_block_count);
    const virtio_io_uring_blocks = try permanent_alloc.alloc(VirtioBlockIoUring, virtio_block_io_uring_count);
    var virtio_block_index: u8 = 0;
    var virtio_block_io_uring_index: u8 = 0;
    const block_infos = virtio_device_infos[0 .. virtio_block_count + virtio_block_io_uring_count];
    for (config.drives.drives.slice(), block_infos) |*drive_config, mmio_info| {
        if (drive_config.io_uring) {
            const block = &virtio_io_uring_blocks[virtio_block_io_uring_index];
            virtio_block_io_uring_index += 1;
            block.* = VirtioBlockIoUring.new(
                nix.System,
                &vm,
                drive_config.path,
                drive_config.read_only,
                &memory,
                mmio_info,
            );
            block.io_uring_device = io_uring.add_device(
                @ptrCast(&VirtioBlockIoUring.event_process_io_uring_event),
                block,
            );
        } else {
            const block = &virtio_blocks[virtio_block_index];
            virtio_block_index += 1;
            block.* = VirtioBlock.new(
                nix.System,
                &vm,
                drive_config.path,
                drive_config.read_only,
                &memory,
                mmio_info,
            );
        }
    }
    defer {
        for (virtio_blocks) |*block|
            block.sync(nix.System);
        for (virtio_io_uring_blocks) |*block|
            block.sync(nix.System);
    }

    const virtio_nets = try permanent_alloc.alloc(VirtioNet, virtio_net_count);
    const vhost_nets = try permanent_alloc.alloc(VhostNet, vhost_net_count);
    var virtio_net_index: u8 = 0;
    var vhost_net_index: u8 = 0;
    const net_infos = virtio_device_infos[virtio_block_count + virtio_block_io_uring_count ..];
    for (config.networks.networks.slice(), net_infos) |*net_config, mmio_info| {
        if (net_config.vhost) {
            vhost_nets[vhost_net_index] = VhostNet.new(
                nix.System,
                &vm,
                net_config.dev_name,
                net_config.mac,
                &memory,
                mmio_info,
            );
            vhost_net_index += 1;
        } else {
            virtio_nets[virtio_net_index] = VirtioNet.new(
                nix.System,
                &vm,
                net_config.dev_name,
                net_config.mac,
                &memory,
                mmio_info,
            );
            virtio_net_index += 1;
        }
    }

    if (config.uart.enabled) mmio.add_device(.{
        .ptr = &uart,
        .read_ptr = @ptrCast(&Uart.read),
        .write_ptr = @ptrCast(&Uart.write_default),
    });
    mmio.add_device(.{
        .ptr = &rtc,
        .read_ptr = @ptrCast(&Rtc.read),
        .write_ptr = @ptrCast(&Rtc.write),
    });
    for (virtio_blocks) |*block| {
        mmio.add_device_virtio(.{
            .ptr = block,
            .read_ptr = @ptrCast(&VirtioBlock.read),
            .write_ptr = @ptrCast(&VirtioBlock.write_default),
        });
    }
    for (virtio_io_uring_blocks) |*block| {
        mmio.add_device_virtio(.{
            .ptr = block,
            .read_ptr = @ptrCast(&VirtioBlockIoUring.read),
            .write_ptr = @ptrCast(&VirtioBlockIoUring.write_default),
        });
    }
    for (virtio_nets) |*virtio_net| {
        mmio.add_device_virtio(.{
            .ptr = virtio_net,
            .read_ptr = @ptrCast(&VirtioNet.read),
            .write_ptr = @ptrCast(&VirtioNet.write_default),
        });
    }
    for (vhost_nets) |*vhost_net| {
        mmio.add_device_virtio(.{
            .ptr = vhost_net,
            .read_ptr = @ptrCast(&VhostNet.read),
            .write_ptr = @ptrCast(&VhostNet.write_default),
        });
    }

    // create kernel cmdline
    var cmdline = try CmdLine.new(tmp_alloc, 128);
    try cmdline.append(config.machine.cmdline);
    for (config.drives.drives.slice(), 0..) |*d, i| {
        if (d.rootfs) {
            var name_buff: [32]u8 = undefined;
            const mod = if (d.read_only) "ro" else "rw";
            const letter: u8 = 'a' + @as(u8, @intCast(i));
            const name = try std.fmt.bufPrint(
                &name_buff,
                " root=/dev/vd{c} {s}",
                .{ letter, mod },
            );
            log.info(@src(), "Using root cmd line params: {s}", .{name});
            try cmdline.append(name);
            break;
        }
    } else for (config.pmems.pmems.slice(), 0..) |*pm, i| {
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
        virtio_device_infos,
        pmem_infos,
    );

    // configure vcpus
    vcpus[0].set_reg(nix.System, u64, Vcpu.PC, load_result.start);
    vcpus[0].set_reg(nix.System, u64, Vcpu.REGS0, @as(u64, fdt_addr));

    for (vcpus) |*vcpu| {
        vcpu.set_reg(nix.System, u64, Vcpu.PSTATE, Vcpu.PSTATE_FAULT_BITS_64);
    }

    // configure terminal for uart in/out
    const stdin = if (config.uart.enabled) std.io.getStdIn() else undefined;
    const state = if (config.uart.enabled) configure_terminal(nix.System, &stdin) else undefined;

    // start vcpu threads
    const vcpu_threads = try permanent_alloc.alloc(std.Thread, config.machine.vcpus);

    // free config memory
    config_parse_result.deinit(nix.System);

    // create event loop
    var el = EventLoop.new(nix.System);
    if (config.uart.enabled) el.add_event(
        nix.System,
        stdin.handle,
        @ptrCast(&Uart.event_read_input),
        &uart,
    );
    if (virtio_block_io_uring_count != 0)
        el.add_event(
            nix.System,
            io_uring.eventfd.fd,
            @ptrCast(&IoUring.event_process_event),
            @ptrCast(&io_uring),
        );
    for (virtio_blocks) |*block| {
        el.add_event(
            nix.System,
            block.virtio_context.queue_events[0].fd,
            @ptrCast(&VirtioBlock.event_process_queue),
            block,
        );
    }
    for (virtio_io_uring_blocks) |*block| {
        el.add_event(
            nix.System,
            block.virtio_context.queue_events[0].fd,
            @ptrCast(&VirtioBlockIoUring.event_process_queue),
            block,
        );
    }
    for (virtio_nets) |*net| {
        el.add_event(
            nix.System,
            net.virtio_context.queue_events[0].fd,
            @ptrCast(&VirtioNet.event_process_rx),
            net,
        );
        el.add_event(
            nix.System,
            net.virtio_context.queue_events[1].fd,
            @ptrCast(&VirtioNet.event_process_tx),
            net,
        );
        el.add_event(
            nix.System,
            net.tun,
            @ptrCast(&VirtioNet.event_process_tap),
            net,
        );
    }
    el.add_event(nix.System, vcpu_exit_event.fd, @ptrCast(&EventLoop.stop), &el);

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
    if (config.uart.enabled) restore_terminal(nix.System, &stdin, &state);
    return;
}

fn configure_terminal(comptime System: type, stdin: *const std.fs.File) nix.termios {
    var ttystate: nix.termios = undefined;
    var ttysave: nix.termios = undefined;

    _ = System.tcgetattr(stdin.handle, &ttystate);
    ttysave = ttystate;

    //turn off canonical mode and echo
    ttystate.lflag.ECHO = false;
    ttystate.lflag.ICANON = false;
    //minimum of number input read.
    ttystate.cc[4] = 1;

    //set the terminal attributes.
    _ = System.tcsetattr(stdin.handle, nix.TCSA.NOW, &ttystate);
    return ttysave;
}

fn restore_terminal(
    comptime System: type,
    stdin: *const std.fs.File,
    state: *const nix.termios,
) void {
    //set the terminal attributes.
    _ = System.tcsetattr(stdin.handle, nix.TCSA.NOW, state);
}

pub const _queue = @import("./virtio/queue.zig");
pub const _iov_ring = @import("./virtio/iov_ring.zig");
pub const _ring_buffer = @import("./ring_buffer.zig");
test {
    std.testing.refAllDecls(@This());
}
