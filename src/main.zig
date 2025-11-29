const std = @import("std");
const build_options = @import("build_options");
const log = @import("log.zig");
const nix = @import("nix.zig");
const gdb = @import("gdb.zig");
const args_parser = @import("args_parser.zig");
const config_parser = @import("config_parser.zig");
const profiler = @import("profiler.zig");

const Allocator = std.mem.Allocator;

const Pmem = @import("devices/pmem.zig");
const Uart = @import("devices/uart.zig");
const Rtc = @import("devices/rtc.zig");
const block_devices = @import("devices/block.zig");
const BlockPci = block_devices.BlockPci;
const BlockMmio = block_devices.BlockMmio;
const BlockPciIoUring = block_devices.BlockPciIoUring;
const BlockMmioIoUring = block_devices.BlockMmioIoUring;
const net_devices = @import("devices/net.zig");
const NetMmio = net_devices.NetMmio;
const NetMmioVhost = net_devices.NetMmioVhost;

const Ecam = @import("virtio/ecam.zig");
const IovRing = @import("virtio/iov_ring.zig");
const EventLoop = @import("event_loop.zig");
const EventFd = @import("eventfd.zig");
const CmdLine = @import("cmdline.zig");
const FDT = @import("fdt.zig");
const Gicv2 = @import("gicv2.zig");
const Kvm = @import("kvm.zig");
const Memory = @import("memory.zig");
const Mmio = @import("mmio.zig");
const Api = @import("api.zig");
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

pub const profiler_options = profiler.Options{
    .enabled = false,
};

pub const MEASUREMENTS = profiler.Measurements("main", &.{
    "build_from_config",
    "create_block_mmio",
    "create_block_mmio_io_uring",
    "create_block_pci",
    "create_block_pci_io_uring",
    "create_net_mmio",
    "create_net_mmio_vhost",
    "build_from_snapshot",
    "State.from_config",
    "State.from_snapshot",
});

const ALL_MEASUREMENTS = &.{
    MEASUREMENTS,
    args_parser.MEASUREMENTS,
    config_parser.MEASUREMENTS,
    block_devices.MEASUREMENTS,
    net_devices.MEASUREMENTS,
    @import("virtio/context.zig").MEASUREMENTS,
    @import("virtio/pci_context.zig").MEASUREMENTS,
    nix.MEASUREMENTS,
};

const Args = struct {
    config_path: ?[]const u8 = null,
    snapshot_path: ?[]const u8 = null,
};

pub const ConfigState = extern struct {
    memory_mb: u32,
    vcpus: u32,
    uart_enabled: bool,
    block_mmio_count: u8,
    block_pci_count: u8,
    block_mmio_io_uring_count: u8,
    block_pci_io_uring_count: u8,
    net_mmio_count: u8,
    net_vhost_mmio_count: u8,
    pmem_count: u8,
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
        BlockPciIoUring,
        NetMmio,
        NetMmioVhost,
        Ecam,
        Ecam.Type0ConfigurationHeader,
        Ecam.HeaderBarSizes,
        Uart,
        Rtc,
    }) |t| {
        log.comptime_assert(
            @src(),
            @alignOf(t) <= 8 and @sizeOf(t) % 8 == 0,
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

    profiler.start();
    const args = try args_parser.parse(Args);

    var runtime: Runtime = undefined;
    var state: State = undefined;

    if (args.config_path) |config_path| {
        try build_from_config(config_path, &runtime, &state);
    } else if (args.snapshot_path) |snapshot_path| {
        try build_from_snapshot(snapshot_path, &runtime, &state);
    } else {
        try args_parser.print_help(Args);
        return;
    }

    // start vcpu threads
    log.debug(@src(), "starting vcpu threads", .{});
    for (state.vcpu_threads, state.vcpus) |*t, *vcpu|
        t.* = try nix.System.spawn_thread(
            .{},
            Vcpu.run_threaded,
            .{ vcpu, nix.System, &runtime.vcpu_barrier, &runtime.mmio },
        );

    // Disable gdb for now as it is not operational anyway
    // if (config.gdb) |gdb_config| {
    //     // start gdb server
    //     var gdb_server = try gdb.GdbServer.init(
    //         nix.System,
    //         gdb_config.socket_path,
    //         state.vcpus,
    //         state.vcpu_threads,
    //         &vcpu_barrier,
    //         state.memory,
    //         &mmio,
    //         &el,
    //     );
    //     el.add_event(
    //         nix.System,
    //         gdb_server.connection.stream.handle,
    //         @ptrCast(&gdb.GdbServer.process_request),
    //         &gdb_server,
    //     );
    //
    //     // start event loop
    //     el.run(nix.System);
    // } else {

    profiler.print(ALL_MEASUREMENTS);

    // start vcpus
    runtime.vcpu_barrier.set();

    // start event loop
    runtime.el.run(nix.System);
    // }

    log.info(@src(), "Shutting down", .{});
    if (runtime.terminal_state) |ts| restore_terminal(nix.System, &ts);
    return;
}

fn build_from_config(config_path: []const u8, runtime: *Runtime, state: *State) !void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    const config_parse_result = try config_parser.parse_file(nix.System, config_path);
    defer config_parse_result.deinit(nix.System);

    const config = &config_parse_result.config;

    state.* = .from_config(config);

    runtime.kvm = .init(nix.System);
    runtime.vm = .init(nix.System, runtime.kvm);
    runtime.vm.set_memory(nix.System, .{
        .guest_phys_addr = Memory.DRAM_START,
        .memory_size = state.memory.mem.len,
        .userspace_addr = @intFromPtr(state.memory.mem.ptr),
    });
    runtime.ecam = .init(state.ecam_memory, state.block_pci.len + state.block_pci_io_uring.len);
    runtime.mmio = .init(runtime.ecam);
    runtime.el = .init(nix.System);
    if (state.block_mmio_io_uring.len != 0 or state.block_pci_io_uring.len != 0) {
        runtime.io_uring = IoUring.init(nix.System, 256);
        runtime.el.add_event(
            nix.System,
            runtime.io_uring.eventfd.fd,
            @ptrCast(&IoUring.event_process_event),
            @ptrCast(&runtime.io_uring),
        );
    }
    runtime.vcpu_barrier = .{};
    if (config.api.socket_path) |socket_path| {
        runtime.api = .init(
            nix.System,
            socket_path,
            state.vcpus,
            state.vcpu_threads,
            &runtime.vcpu_barrier,
            state.vcpu_reg_list,
            state.vcpu_regs,
            state.vcpu_mp_states,
            &runtime.gicv2,
            state.gicv2_state,
            state.permanent_memory,
        );
        runtime.el.add_event(
            nix.System,
            runtime.api.fd,
            @ptrCast(&Api.handle_default),
            &runtime.api,
        );
    }

    const kvi = runtime.vm.get_preferred_target(nix.System);
    const vcpu_exit_event = EventFd.init(nix.System, 0, nix.EFD_NONBLOCK);
    runtime.el.add_event(nix.System, vcpu_exit_event.fd, @ptrCast(&EventLoop.stop), &runtime.el);
    const vcpu_mmap_size = runtime.kvm.vcpu_mmap_size(nix.System);

    for (state.vcpus, 0..) |*vcpu, i|
        vcpu.* = .create(nix.System, runtime.vm, i, vcpu_exit_event, vcpu_mmap_size);
    for (state.vcpus, 0..) |*vcpu, i| vcpu.init(nix.System, i, kvi);

    runtime.gicv2 = .init(nix.System, runtime.vm);

    if (config.uart.enabled) {
        runtime.terminal_state = configure_terminal(nix.System);
        state.uart.init(nix.System, &runtime.vm, nix.STDIN_FILENO, nix.STDOUT_FILENO);
        runtime.mmio.set_uart(.{
            .ptr = state.uart,
            .read_ptr = @ptrCast(&Uart.read),
            .write_ptr = @ptrCast(&Uart.write_with_system),
        });
        runtime.el.add_event(
            nix.System,
            nix.STDIN,
            @ptrCast(&Uart.read_input_with_system),
            state.uart,
        );
    }
    runtime.mmio.set_rtc(.{
        .ptr = state.rtc,
        .read_ptr = @ptrCast(&Rtc.read_with_system),
        .write_ptr = @ptrCast(&Rtc.write_with_system),
    });

    var load_result = state.memory.load_linux_kernel(nix.System, config.kernel.path);
    const tmp_alloc = load_result.post_kernel_allocator.allocator();

    var mmio_resources: Mmio.Resources = .{};
    // preallocate all mmio regions for the devices. This is needed to
    // pass a single slice of mmio regions to the fdt builder.
    const block_mmio_info_count = state.block_mmio.len + state.block_mmio_io_uring.len;
    const net_mmio_info_count = state.net_mmio.len + state.net_mmio_vhost.len;
    const mmio_info_count = block_mmio_info_count + net_mmio_info_count;
    const mmio_infos = try tmp_alloc.alloc(Mmio.Resources.MmioVirtioInfo, mmio_info_count);
    var mmio_regions = state.mmio_regions;
    for (mmio_infos) |*info| {
        info.* = mmio_resources.allocate_mmio_virtio();
        info.mem_ptr = mmio_regions.ptr;
        mmio_regions = mmio_regions[Mmio.MMIO_DEVICE_ALLOCATED_REGION_SIZE..];
    }

    var mmio_block_infos = mmio_infos[0..block_mmio_info_count];
    var mmio_net_infos = mmio_infos[block_mmio_info_count..][0..net_mmio_info_count];

    create_block_mmio(
        runtime,
        state,
        mmio_block_infos[0..state.block_mmio.len],
        config.block.configs.slice_const(),
    );
    mmio_block_infos = mmio_block_infos[state.block_mmio.len..];
    defer for (state.block_mmio) |*block| block.sync(nix.System);

    create_block_mmio_io_uring(
        runtime,
        state,
        mmio_block_infos[0..state.block_mmio_io_uring.len],
        config.block.configs.slice_const(),
    );
    mmio_block_infos = mmio_block_infos[state.block_mmio_io_uring.len..];
    defer for (state.block_mmio_io_uring) |*block| block.sync(nix.System);

    create_block_pci(runtime, state, &mmio_resources, config.block.configs.slice_const());
    defer for (state.block_pci) |*block| block.sync(nix.System);

    create_block_pci_io_uring(runtime, state, &mmio_resources, config.block.configs.slice_const());
    defer for (state.block_pci_io_uring) |*block| block.sync(nix.System);

    create_net_mmio(
        runtime,
        state,
        mmio_net_infos[0..state.net_mmio.len],
        config.network.configs.slice_const(),
    );
    mmio_net_infos = mmio_net_infos[state.net_mmio.len..];

    create_net_mmio_vhost(
        runtime,
        state,
        mmio_net_infos[0..state.net_mmio_vhost.len],
        config.network.configs.slice_const(),
    );
    mmio_net_infos = mmio_net_infos[state.net_mmio_vhost.len..];

    var last_addr = Memory.align_addr(state.memory.last_addr(), Pmem.ALIGNMENT);
    const pmem_infos = try tmp_alloc.alloc(Pmem.Info, config.pmem.configs.slice_const().len);
    for (config.pmem.configs.slice_const(), pmem_infos) |*pmem_config, *info| {
        info.start = last_addr;
        info.len = Pmem.attach(nix.System, &runtime.vm, pmem_config.path, info.start);
        last_addr += info.len;
    }

    var cmdline = try CmdLine.init(tmp_alloc, 128);
    try cmdline.append(config.machine.cmdline);
    for (config.block.configs.slice_const(), 0..) |*block_config, i| {
        if (block_config.rootfs) {
            var name_buff: [32]u8 = undefined;
            const mod = if (block_config.read_only) "ro" else "rw";
            var letter: u8 = 'a' + @as(u8, @intCast(i));
            // pci block will be initialized after mmio ones
            // There can only be less than 256 blocks
            if (block_config.pci) letter += @intCast(block_mmio_info_count);
            const name = try std.fmt.bufPrint(
                &name_buff,
                " root=/dev/vd{c} {s}",
                .{ letter, mod },
            );
            log.info(@src(), "Using root cmd line params: {s}", .{name});
            try cmdline.append(name);
            break;
        }
    } else for (config.pmem.configs.slice_const(), 0..) |*pmem_config, i| {
        if (pmem_config.rootfs) {
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
        log.err(@src(), "No rootfs device selected", .{});
        return error.NoRootDevice;
    }
    if (config.uart.enabled) try Uart.add_to_cmdline(&cmdline);

    const mpidrs = try tmp_alloc.alloc(u64, config.machine.vcpus);
    for (mpidrs, state.vcpus) |*mpidr, *vcpu| mpidr.* = vcpu.get_reg(nix.System, Vcpu.MPIDR_EL1);
    const fdt_addr = FDT.create_fdt(
        nix.System,
        tmp_alloc,
        state.memory,
        mpidrs,
        try cmdline.sentinel_str(),
        config.uart.enabled,
        mmio_infos,
        pmem_infos,
    );

    state.vcpus[0].set_reg(nix.System, u64, Vcpu.PC, load_result.start);
    state.vcpus[0].set_reg(nix.System, u64, Vcpu.REGS0, @as(u64, fdt_addr));
    for (state.vcpus) |*vcpu|
        vcpu.set_reg(nix.System, u64, Vcpu.PSTATE, Vcpu.PSTATE_FAULT_BITS_64);
}

fn create_block_mmio(
    runtime: *Runtime,
    state: *State,
    mmio_infos: []const Mmio.Resources.MmioVirtioInfo,
    configs: []const config_parser.BlockConfig,
) void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    var index: u8 = 0;
    for (configs) |*config| {
        if (!config.io_uring and !config.pci) {
            const block = &state.block_mmio[index];
            const info = mmio_infos[index];
            index += 1;

            block.init(
                nix.System,
                config.path,
                config.read_only,
                config.id,
                &runtime.vm,
                state.memory,
                info,
            );
            runtime.mmio.add_device_virtio(.{
                .ptr = block,
                .read_ptr = @ptrCast(&BlockMmio.read),
                .write_ptr = @ptrCast(&BlockMmio.write_with_system),
            });
            runtime.el.add_event(
                nix.System,
                block.context.queue_events[0].fd,
                @ptrCast(&BlockMmio.process_queue_event_with_system),
                block,
            );
        }
    }
}

fn create_block_mmio_io_uring(
    runtime: *Runtime,
    state: *State,
    mmio_infos: []const Mmio.Resources.MmioVirtioInfo,
    configs: []const config_parser.BlockConfig,
) void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    var index: u8 = 0;
    for (configs) |*config| {
        if (config.io_uring and !config.pci) {
            const block = &state.block_mmio_io_uring[index];
            const info = mmio_infos[index];
            index += 1;
            block.init(
                nix.System,
                config.path,
                config.read_only,
                config.id,
                &runtime.vm,
                state.memory,
                info,
            );
            block.io_uring_device = runtime.io_uring.add_device(
                @ptrCast(&BlockMmioIoUring.process_io_uring_event_with_system),
                block,
            );
            runtime.mmio.add_device_virtio(.{
                .ptr = block,
                .read_ptr = @ptrCast(&BlockMmioIoUring.read),
                .write_ptr = @ptrCast(&BlockMmioIoUring.write_with_system),
            });
            runtime.el.add_event(
                nix.System,
                block.context.queue_events[0].fd,
                @ptrCast(&BlockMmioIoUring.process_queue_event_with_system),
                block,
            );
        }
    }
}

fn create_block_pci(
    runtime: *Runtime,
    state: *State,
    mmio_resources: *Mmio.Resources,
    configs: []const config_parser.BlockConfig,
) void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    var index: u8 = 0;
    for (configs) |*config| {
        if (!config.io_uring and config.pci) {
            const block = &state.block_pci[index];
            index += 1;

            const info = mmio_resources.allocate_pci();
            runtime.ecam.add_header(
                block_devices.TYPE_BLOCK,
                @intFromEnum(Ecam.PciClass.MassStorage),
                @intFromEnum(Ecam.PciMassStorageSubclass.NvmeController),
                info.bar_addr,
            );
            block.init(
                nix.System,
                config.path,
                config.read_only,
                config.id,
                &runtime.vm,
                state.memory,
                info,
            );
            runtime.mmio.add_device_pci(.{
                .ptr = block,
                .read_ptr = @ptrCast(&BlockPci.read),
                .write_ptr = @ptrCast(&BlockPci.write_with_system),
            });
            runtime.el.add_event(
                nix.System,
                block.context.queue_events[0].fd,
                @ptrCast(&BlockPci.process_queue_event_with_system),
                block,
            );
        }
    }
}

fn create_block_pci_io_uring(
    runtime: *Runtime,
    state: *State,
    mmio_resources: *Mmio.Resources,
    configs: []const config_parser.BlockConfig,
) void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    var index: u8 = 0;
    for (configs) |*config| {
        if (config.io_uring and config.pci) {
            const block = &state.block_pci_io_uring[index];
            index += 1;

            const info = mmio_resources.allocate_pci();
            runtime.ecam.add_header(
                block_devices.TYPE_BLOCK,
                @intFromEnum(Ecam.PciClass.MassStorage),
                @intFromEnum(Ecam.PciMassStorageSubclass.NvmeController),
                info.bar_addr,
            );
            block.init(
                nix.System,
                config.path,
                config.read_only,
                config.id,
                &runtime.vm,
                state.memory,
                info,
            );
            block.io_uring_device = runtime.io_uring.add_device(
                @ptrCast(&BlockPciIoUring.process_io_uring_event_with_system),
                block,
            );
            runtime.mmio.add_device_pci(.{
                .ptr = block,
                .read_ptr = @ptrCast(&BlockPciIoUring.read),
                .write_ptr = @ptrCast(&BlockPciIoUring.write_with_system),
            });
            runtime.el.add_event(
                nix.System,
                block.context.queue_events[0].fd,
                @ptrCast(&BlockPciIoUring.process_queue_event_with_system),
                block,
            );
        }
    }
}

fn create_net_mmio(
    runtime: *Runtime,
    state: *State,
    mmio_infos: []const Mmio.Resources.MmioVirtioInfo,
    configs: []const config_parser.NetConfig,
) void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    var index: u8 = 0;
    var iov_ring = state.net_iov_ring;
    for (configs) |*config| {
        if (!config.vhost) {
            const net = &state.net_mmio[index];
            const mmio_info = mmio_infos[index];
            const iov_ring_memory = iov_ring[0..IovRing.BACKING_SIZE];
            iov_ring = iov_ring[IovRing.BACKING_SIZE..];
            index += 1;

            net.init(
                nix.System,
                &runtime.vm,
                config.dev_name,
                config.mac,
                state.memory,
                mmio_info,
                iov_ring_memory,
            );
            runtime.mmio.add_device_virtio(.{
                .ptr = net,
                .read_ptr = @ptrCast(&NetMmio.read),
                .write_ptr = @ptrCast(&NetMmio.write_with_system),
            });
            runtime.el.add_event(
                nix.System,
                net.context.queue_events[0].fd,
                @ptrCast(&NetMmio.process_rx_event_with_system),
                net,
            );
            runtime.el.add_event(
                nix.System,
                net.context.queue_events[1].fd,
                @ptrCast(&NetMmio.process_tx_event_with_system),
                net,
            );
            runtime.el.add_event(
                nix.System,
                net.tun,
                @ptrCast(&NetMmio.process_tap_event_with_system),
                net,
            );
        }
    }
}

fn create_net_mmio_vhost(
    runtime: *Runtime,
    state: *State,
    mmio_infos: []const Mmio.Resources.MmioVirtioInfo,
    configs: []const config_parser.NetConfig,
) void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    var index: u8 = 0;
    for (configs) |*config| {
        if (config.vhost) {
            const net = &state.net_mmio_vhost[index];
            const mmio_info = mmio_infos[index];
            index += 1;

            net.init(
                nix.System,
                &runtime.vm,
                config.dev_name,
                config.mac,
                state.memory,
                mmio_info,
            );
            runtime.mmio.add_device_virtio(.{
                .ptr = net,
                .read_ptr = @ptrCast(&NetMmioVhost.read),
                .write_ptr = @ptrCast(&NetMmioVhost.write_with_system),
            });
        }
    }
}

fn build_from_snapshot(snapshot_path: []const u8, runtime: *Runtime, state: *State) !void {
    const prof_point = MEASUREMENTS.start(@src());
    defer MEASUREMENTS.end(prof_point);

    state.* = .from_snapshot(nix.System, snapshot_path);

    runtime.kvm = .init(nix.System);
    runtime.vm = .init(nix.System, runtime.kvm);
    runtime.vm.set_memory(nix.System, .{
        .guest_phys_addr = Memory.DRAM_START,
        .memory_size = state.memory.mem.len,
        .userspace_addr = @intFromPtr(state.memory.mem.ptr),
    });
    runtime.ecam = @ptrCast(state.ecam_memory.ptr);
    runtime.mmio = .init(runtime.ecam);
    runtime.el = .init(nix.System);
    if (state.block_mmio_io_uring.len != 0 or state.block_pci_io_uring.len != 0) {
        runtime.io_uring = IoUring.init(nix.System, 256);
        runtime.el.add_event(
            nix.System,
            runtime.io_uring.eventfd.fd,
            @ptrCast(&IoUring.event_process_event),
            @ptrCast(&runtime.io_uring),
        );
    }
    runtime.vcpu_barrier = .{};

    const kvi = runtime.vm.get_preferred_target(nix.System);
    const vcpu_exit_event = EventFd.init(nix.System, 0, nix.EFD_NONBLOCK);
    runtime.el.add_event(nix.System, vcpu_exit_event.fd, @ptrCast(&EventLoop.stop), &runtime.el);
    const vcpu_mmap_size = runtime.kvm.vcpu_mmap_size(nix.System);

    for (state.vcpus, 0..) |*vcpu, i|
        vcpu.* = .create(nix.System, runtime.vm, i, vcpu_exit_event, vcpu_mmap_size);
    for (state.vcpus, 0..) |*vcpu, i| vcpu.init(nix.System, i, kvi);
    runtime.gicv2 = .init(nix.System, runtime.vm);

    var regs_bytes = state.vcpu_regs;
    for (state.vcpus, state.vcpu_mp_states) |*vcpu, *mp_state| {
        const used = vcpu.restore_regs(nix.System, state.vcpu_reg_list, regs_bytes, mp_state);
        regs_bytes = regs_bytes[used..];
    }
    runtime.gicv2.restore_state(nix.System, state.gicv2_state, @intCast(state.vcpus.len));

    if (state.config_state.uart_enabled) {
        runtime.terminal_state = configure_terminal(nix.System);
        state.uart.restore(nix.System, &runtime.vm);
        runtime.mmio.set_uart(.{
            .ptr = state.uart,
            .read_ptr = @ptrCast(&Uart.read),
            .write_ptr = @ptrCast(&Uart.write_with_system),
        });
        runtime.el.add_event(
            nix.System,
            nix.STDIN,
            @ptrCast(&Uart.read_input_with_system),
            state.uart,
        );
    }
    runtime.mmio.set_rtc(.{
        .ptr = state.rtc,
        .read_ptr = @ptrCast(&Rtc.read_with_system),
        .write_ptr = @ptrCast(&Rtc.write_with_system),
    });

    var mmio_resources: Mmio.Resources = .{};
    var mmio_regions = state.mmio_regions;

    var config_device_state_bytes = state.config_devices_state;
    for (0..state.config_state.block_mmio_count) |i| {
        const read_only = config_device_state_bytes[0] == 1;
        const path_len = config_device_state_bytes[1];
        const path = config_device_state_bytes[2..][0..path_len];
        config_device_state_bytes = config_device_state_bytes[2 + path_len ..];

        var info = mmio_resources.allocate_mmio_virtio();
        info.mem_ptr = mmio_regions.ptr;
        mmio_regions = mmio_regions[Mmio.MMIO_DEVICE_ALLOCATED_REGION_SIZE..];

        const block = &state.block_mmio[i];
        block.restore(nix.System, &runtime.vm, read_only, path, info);
        runtime.mmio.add_device_virtio(.{
            .ptr = block,
            .read_ptr = @ptrCast(&BlockMmio.read),
            .write_ptr = @ptrCast(&BlockMmio.write_with_system),
        });
        runtime.el.add_event(
            nix.System,
            block.context.queue_events[0].fd,
            @ptrCast(&BlockMmio.process_queue_event_with_system),
            block,
        );
    }
    for (0..state.config_state.block_pci_count) |i| {
        const read_only = config_device_state_bytes[0] == 1;
        const path_len = config_device_state_bytes[1];
        const path = config_device_state_bytes[2..][0..path_len];
        config_device_state_bytes = config_device_state_bytes[2 + path_len ..];

        const info = mmio_resources.allocate_pci();

        const block = &state.block_pci[i];
        block.restore(nix.System, &runtime.vm, read_only, path, info);
        runtime.mmio.add_device_pci(.{
            .ptr = block,
            .read_ptr = @ptrCast(&BlockPci.read),
            .write_ptr = @ptrCast(&BlockPci.write_with_system),
        });
        runtime.el.add_event(
            nix.System,
            block.context.queue_events[0].fd,
            @ptrCast(&BlockPci.process_queue_event_with_system),
            block,
        );
    }
    for (0..state.config_state.block_mmio_io_uring_count) |i| {
        const read_only = config_device_state_bytes[0] == 1;
        const path_len = config_device_state_bytes[1];
        const path = config_device_state_bytes[2..][0..path_len];
        config_device_state_bytes = config_device_state_bytes[2 + path_len ..];

        var info = mmio_resources.allocate_mmio_virtio();
        info.mem_ptr = mmio_regions.ptr;
        mmio_regions = mmio_regions[Mmio.MMIO_DEVICE_ALLOCATED_REGION_SIZE..];

        const block = &state.block_mmio_io_uring[i];
        block.restore(nix.System, &runtime.vm, read_only, path, info);
        block.io_uring_device = runtime.io_uring.add_device(
            @ptrCast(&BlockMmioIoUring.process_io_uring_event_with_system),
            block,
        );
        runtime.mmio.add_device_virtio(.{
            .ptr = block,
            .read_ptr = @ptrCast(&BlockMmioIoUring.read),
            .write_ptr = @ptrCast(&BlockMmioIoUring.write_with_system),
        });
        runtime.el.add_event(
            nix.System,
            block.context.queue_events[0].fd,
            @ptrCast(&BlockMmioIoUring.process_queue_event_with_system),
            block,
        );
    }
    for (0..state.config_state.block_pci_io_uring_count) |i| {
        const read_only = config_device_state_bytes[0] == 1;
        const path_len = config_device_state_bytes[1];
        const path = config_device_state_bytes[2..][0..path_len];
        config_device_state_bytes = config_device_state_bytes[2 + path_len ..];

        const info = mmio_resources.allocate_pci();

        const block = &state.block_pci_io_uring[i];
        block.restore(nix.System, &runtime.vm, read_only, path, info);
        block.io_uring_device = runtime.io_uring.add_device(
            @ptrCast(&BlockPciIoUring.process_io_uring_event_with_system),
            block,
        );
        runtime.mmio.add_device_pci(.{
            .ptr = block,
            .read_ptr = @ptrCast(&BlockPciIoUring.read),
            .write_ptr = @ptrCast(&BlockPciIoUring.write_with_system),
        });
        runtime.el.add_event(
            nix.System,
            block.context.queue_events[0].fd,
            @ptrCast(&BlockPciIoUring.process_queue_event_with_system),
            block,
        );
    }
    var net_iov_ring = state.net_iov_ring;
    for (0..state.config_state.net_mmio_count) |i| {
        const path_len = config_device_state_bytes[0];
        const path = config_device_state_bytes[1..][0..path_len];
        config_device_state_bytes = config_device_state_bytes[1 + path_len ..];

        const iov_ring_bytes = net_iov_ring[0..IovRing.BACKING_SIZE];
        net_iov_ring = net_iov_ring[IovRing.BACKING_SIZE..];

        var info = mmio_resources.allocate_mmio_virtio();
        info.mem_ptr = mmio_regions.ptr;
        mmio_regions = mmio_regions[Mmio.MMIO_DEVICE_ALLOCATED_REGION_SIZE..];

        const net = &state.net_mmio[i];
        net.restore(nix.System, &runtime.vm, path, info, iov_ring_bytes);
        runtime.mmio.add_device_virtio(.{
            .ptr = net,
            .read_ptr = @ptrCast(&NetMmio.read),
            .write_ptr = @ptrCast(&NetMmio.write_with_system),
        });
        runtime.el.add_event(
            nix.System,
            net.context.queue_events[0].fd,
            @ptrCast(&NetMmio.process_rx_event_with_system),
            net,
        );
        runtime.el.add_event(
            nix.System,
            net.context.queue_events[1].fd,
            @ptrCast(&NetMmio.process_tx_event_with_system),
            net,
        );
        runtime.el.add_event(
            nix.System,
            net.tun,
            @ptrCast(&NetMmio.process_tap_event_with_system),
            net,
        );
    }
    for (0..state.config_state.net_vhost_mmio_count) |i| {
        const path_len = config_device_state_bytes[0];
        const path = config_device_state_bytes[1..][0..path_len];
        config_device_state_bytes = config_device_state_bytes[1 + path_len ..];

        var info = mmio_resources.allocate_mmio_virtio();
        info.mem_ptr = mmio_regions.ptr;
        mmio_regions = mmio_regions[Mmio.MMIO_DEVICE_ALLOCATED_REGION_SIZE..];

        const net = &state.net_mmio_vhost[i];
        net.restore(nix.System, &runtime.vm, path, info);
        runtime.mmio.add_device_virtio(.{
            .ptr = net,
            .read_ptr = @ptrCast(&NetMmioVhost.read),
            .write_ptr = @ptrCast(&NetMmioVhost.write_with_system),
        });
    }
    var last_addr = Memory.align_addr(state.memory.last_addr(), Pmem.ALIGNMENT);
    for (0..state.config_state.pmem_count) |_| {
        const path_len = config_device_state_bytes[0];
        const path = config_device_state_bytes[1..][0..path_len];
        config_device_state_bytes = config_device_state_bytes[1 + path_len ..];
        last_addr += Pmem.attach(nix.System, &runtime.vm, path, last_addr);
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

pub const Runtime = struct {
    kvm: Kvm,
    vm: Vm,
    gicv2: Gicv2,
    ecam: *Ecam,
    mmio: Mmio,
    el: EventLoop,
    io_uring: IoUring,
    vcpu_barrier: std.Thread.ResetEvent,
    api: Api,
    terminal_state: ?nix.termios,
};

pub const State = struct {
    permanent_memory: Memory.Permanent,
    memory: Memory.Guest,
    mmio_regions: []align(Memory.HOST_PAGE_SIZE) u8,
    net_iov_ring: []align(Memory.HOST_PAGE_SIZE) u8,
    vcpus: []Vcpu,
    vcpu_threads: []std.Thread,
    block_mmio: []BlockMmio,
    block_pci: []BlockPci,
    block_mmio_io_uring: []BlockMmioIoUring,
    block_pci_io_uring: []BlockPciIoUring,
    net_mmio: []NetMmio,
    net_mmio_vhost: []NetMmioVhost,
    ecam_memory: []align(8) u8,
    uart: *Uart,
    rtc: *Rtc,
    vcpu_reg_list: *Vcpu.RegList,
    vcpu_regs: []u8,
    vcpu_mp_states: []nix.kvm_mp_state,
    gicv2_state: []u32,
    config_devices_state: []u8,
    config_state: *ConfigState,

    pub fn from_config(config: *const config_parser.Config) State {
        const prof_point = MEASUREMENTS.start_named("State.from_config");
        defer MEASUREMENTS.end(prof_point);

        var net_mmio_count: u8 = 0;
        var net_vhost_mmio_count: u8 = 0;
        for (config.network.configs.slice_const()) |*net_config| {
            if (net_config.vhost) {
                net_vhost_mmio_count += 1;
            } else {
                net_mmio_count += 1;
            }
        }

        var pci_devices: u8 = 0;
        var block_mmio_count: u8 = 0;
        var block_pci_count: u8 = 0;
        var block_mmio_io_uring_count: u8 = 0;
        var block_pci_io_uring_count: u8 = 0;
        for (config.block.configs.slice_const()) |*block_config| {
            if (block_config.pci) {
                pci_devices += 1;
                if (block_config.io_uring) block_pci_io_uring_count += 1 else block_pci_count += 1;
            } else {
                if (block_config.io_uring) block_mmio_io_uring_count += 1 else block_mmio_count += 1;
            }
        }

        // These need to be host page aligned
        const memory_bytes = config.machine.memory_mb << 20;
        // These are for optimized mmio devices that need actual memory to be put in
        // mmio region
        const mmio_regions_bytes = Mmio.MMIO_DEVICE_ALLOCATED_REGION_SIZE *
            (block_mmio_count + block_mmio_io_uring_count + net_mmio_count + net_vhost_mmio_count);
        // These will be used to back iov_ring types in the VirtioNet devices
        const net_iov_ring_bytes = IovRing.BACKING_SIZE * net_mmio_count;

        // Need to be 8 bytes aligned, so they go after host page aligned items
        const vcpu_bytes = @sizeOf(Vcpu) * config.machine.vcpus;
        const thread_bytes = @sizeOf(std.Thread) * config.machine.vcpus;
        const block_mmio_bytes = @sizeOf(BlockMmio) * @as(usize, @intCast(block_mmio_count));
        const block_pci_bytes = @sizeOf(BlockPci) * @as(usize, @intCast(block_pci_count));
        const block_mmio_io_uring_bytes = @sizeOf(BlockMmioIoUring) *
            @as(usize, @intCast(block_mmio_io_uring_count));
        const block_pci_io_uring_bytes = @sizeOf(BlockPciIoUring) *
            @as(usize, @intCast(block_pci_io_uring_count));
        const net_bytes = @sizeOf(NetMmio) * @as(usize, @intCast(net_mmio_count));
        const vhost_net_bytes = @sizeOf(NetMmioVhost) * @as(usize, @intCast(net_vhost_mmio_count));

        const ecam_bytes = @sizeOf(Ecam) +
            @sizeOf(Ecam.Type0ConfigurationHeader) * pci_devices +
            @sizeOf(Ecam.HeaderBarSizes) * pci_devices;

        var uart_bytes: usize = 0;
        if (config.uart.enabled)
            uart_bytes = @sizeOf(Uart);
        const rtc_bytes: usize = @sizeOf(Rtc);

        // Additional bytes needed to store VM state
        // 8 byte aligned
        const vcpu_reg_list_bytes = @sizeOf(Vcpu.RegList);
        const vcpu_regs_bytes = config.machine.vcpus * Vcpu.PER_VCPU_REGS_BYTES;
        // 4 byte aligned
        const vcpu_mpstates_bytes = config.machine.vcpus * @sizeOf(nix.kvm_mp_state);
        const gicv2_state_bytes =
            config.machine.vcpus * Gicv2.VGIC_CPU_REGS_BYTES + Gicv2.VGIC_DIST_REGS_BYTES;
        // 1 byte aligned
        var config_devices_bytes: usize = 0;
        // The only thing needed saving for devices are paths and read_only flags
        for (config.block.configs.slice_const()) |bc| config_devices_bytes += bc.path.len + 1 + 1;
        for (config.network.configs.slice_const()) |nc|
            config_devices_bytes += nc.dev_name.len + 1;
        for (config.pmem.configs.slice_const()) |pc| config_devices_bytes += pc.path.len + 1;
        // 4 byte aligned
        const config_bytes: usize = @sizeOf(ConfigState);

        var permanent_memory_size =
            memory_bytes +
            mmio_regions_bytes +
            net_iov_ring_bytes +
            vcpu_bytes +
            thread_bytes +
            block_mmio_bytes +
            block_pci_bytes +
            block_mmio_io_uring_bytes +
            block_pci_io_uring_bytes +
            net_bytes +
            vhost_net_bytes +
            ecam_bytes +
            uart_bytes +
            rtc_bytes;

        if (config.api.socket_path != null) {
            permanent_memory_size +=
                vcpu_reg_list_bytes +
                vcpu_regs_bytes +
                vcpu_mpstates_bytes +
                gicv2_state_bytes +
                config_devices_bytes;

            // Need to store ConfigState last and it needs aligment update;
            permanent_memory_size = Memory.align_addr(permanent_memory_size, @alignOf(ConfigState));
            permanent_memory_size += config_bytes;
        }

        log.info(@src(), "permanent memory size: {} bytes", .{permanent_memory_size});
        var result: State = undefined;

        log.debug(@src(), "permanent_memory_size: {d}", .{permanent_memory_size});
        result.permanent_memory = .init(nix.System, permanent_memory_size);
        var pm: []u8 = result.permanent_memory.mem;

        log.debug(@src(), "memory_bytes: {d}", .{memory_bytes});
        result.memory = .{ .mem = @alignCast(pm[0..memory_bytes]) };
        pm = pm[memory_bytes..];

        log.debug(@src(), "mmio_regions_bytes: {d}", .{mmio_regions_bytes});
        result.mmio_regions = @alignCast(pm[0..mmio_regions_bytes]);
        pm = pm[mmio_regions_bytes..];

        log.debug(@src(), "net_iov_ring_bytes: {d}", .{net_iov_ring_bytes});
        result.net_iov_ring = @alignCast(pm[0..net_iov_ring_bytes]);
        pm = pm[net_iov_ring_bytes..];

        log.debug(@src(), "vcpu_bytes: {d}", .{vcpu_bytes});
        result.vcpus = @ptrCast(@alignCast(pm[0..vcpu_bytes]));
        pm = pm[vcpu_bytes..];

        log.debug(@src(), "thread_bytes: {d}", .{thread_bytes});
        result.vcpu_threads = @ptrCast(@alignCast(pm[0..thread_bytes]));
        pm = pm[thread_bytes..];

        log.debug(@src(), "block_mmio_bytes: {d}", .{block_mmio_bytes});
        result.block_mmio = @ptrCast(@alignCast(pm[0..block_mmio_bytes]));
        pm = pm[block_mmio_bytes..];

        log.debug(@src(), "block_pci_bytes: {d}", .{block_pci_bytes});
        result.block_pci = @ptrCast(@alignCast(pm[0..block_pci_bytes]));
        pm = pm[block_pci_bytes..];

        log.debug(@src(), "block_mmio_io_uring_bytes: {d}", .{block_mmio_io_uring_bytes});
        result.block_mmio_io_uring =
            @ptrCast(@alignCast(pm[0..block_mmio_io_uring_bytes]));
        pm = pm[block_mmio_io_uring_bytes..];

        log.debug(@src(), "block_pci_io_uring_bytes: {d}", .{block_pci_io_uring_bytes});
        result.block_pci_io_uring =
            @ptrCast(@alignCast(pm[0..block_pci_io_uring_bytes]));
        pm = pm[block_pci_io_uring_bytes..];

        log.debug(@src(), "net_bytes: {d}", .{net_bytes});
        result.net_mmio = @ptrCast(@alignCast(pm[0..net_bytes]));
        pm = pm[net_bytes..];

        log.debug(@src(), "vhost_net_bytes: {d}", .{vhost_net_bytes});
        result.net_mmio_vhost = @ptrCast(@alignCast(pm[0..vhost_net_bytes]));
        pm = pm[vhost_net_bytes..];

        log.debug(@src(), "ecam_bytes: {d}", .{ecam_bytes});
        result.ecam_memory = @ptrCast(@alignCast(pm[0..ecam_bytes]));
        pm = pm[ecam_bytes..];

        if (config.uart.enabled) {
            log.debug(@src(), "uart_bytes: {d}", .{uart_bytes});
            result.uart = @ptrCast(@alignCast(pm[0..uart_bytes]));
            pm = pm[uart_bytes..];
        }
        log.debug(@src(), "rtc_bytes: {d}", .{rtc_bytes});
        result.rtc = @ptrCast(@alignCast(pm[0..rtc_bytes]));
        result.rtc.* = .{};
        pm = pm[rtc_bytes..];

        if (config.api.socket_path != null) {
            result.vcpu_reg_list = @ptrCast(@alignCast(pm[0..vcpu_reg_list_bytes]));
            // First value is the number of ids in the list. Set to 0 to
            // be able to detect when list needs to be queried.
            log.debug(@src(), "vcpu_reg_list_bytes: {d}", .{vcpu_reg_list_bytes});
            result.vcpu_reg_list[0] = 0;
            pm = pm[vcpu_reg_list_bytes..];

            log.debug(@src(), "vcpu_regs_bytes: {d}", .{vcpu_regs_bytes});
            result.vcpu_regs = @ptrCast(@alignCast(pm[0..vcpu_regs_bytes]));
            pm = pm[vcpu_regs_bytes..];

            log.debug(@src(), "vcpu_mpstates_bytes: {d}", .{vcpu_mpstates_bytes});
            result.vcpu_mp_states = @ptrCast(@alignCast(pm[0..vcpu_mpstates_bytes]));
            pm = pm[vcpu_mpstates_bytes..];

            log.debug(@src(), "gicv2_state_bytes: {d}", .{gicv2_state_bytes});
            result.gicv2_state = @ptrCast(@alignCast(pm[0..gicv2_state_bytes]));
            pm = pm[gicv2_state_bytes..];

            log.debug(@src(), "config_devices_bytes: {d}", .{config_devices_bytes});
            result.config_devices_state = @ptrCast(pm[0..config_devices_bytes]);
            pm = pm[config_devices_bytes..];

            result.config_state = @ptrCast(@alignCast(pm[pm.len - @sizeOf(ConfigState) ..]));

            result.config_state.memory_mb = config.machine.memory_mb;
            result.config_state.vcpus = config.machine.vcpus;
            result.config_state.uart_enabled = config.uart.enabled;
            result.config_state.block_mmio_count = block_mmio_count;
            result.config_state.block_pci_count = block_pci_count;
            result.config_state.block_mmio_io_uring_count = block_mmio_io_uring_count;
            result.config_state.block_pci_io_uring_count = block_pci_io_uring_count;
            result.config_state.net_mmio_count = net_mmio_count;
            result.config_state.net_vhost_mmio_count = net_vhost_mmio_count;
            result.config_state.pmem_count = @truncate(config.pmem.configs.slice_const().len);
            log.debug(@src(), "Saved ConfigState: {any}", .{result.config_state});
            var config_device_state_bytes = result.config_devices_state;

            for (config.block.configs.slice_const()) |*bc| {
                if (!bc.pci and !bc.io_uring) {
                    config_device_state_bytes[0] = @intFromBool(bc.read_only);
                    config_device_state_bytes[1] = @intCast(bc.path.len);
                    @memcpy(config_device_state_bytes[2..][0..bc.path.len], bc.path);
                    config_device_state_bytes = config_device_state_bytes[2 + bc.path.len ..];
                }
            }
            log.debug(
                @src(),
                "Saved BlockMmio devices. Bytes left: {d}",
                .{config_device_state_bytes.len},
            );
            for (config.block.configs.slice_const()) |*bc| {
                if (bc.pci and !bc.io_uring) {
                    config_device_state_bytes[0] = @intFromBool(bc.read_only);
                    config_device_state_bytes[1] = @intCast(bc.path.len);
                    @memcpy(config_device_state_bytes[2..][0..bc.path.len], bc.path);
                    config_device_state_bytes = config_device_state_bytes[2 + bc.path.len ..];
                }
            }
            log.debug(
                @src(),
                "Saved BlockPci devices. Bytes left: {d}",
                .{config_device_state_bytes.len},
            );
            for (config.block.configs.slice_const()) |*bc| {
                if (!bc.pci and bc.io_uring) {
                    config_device_state_bytes[0] = @intFromBool(bc.read_only);
                    config_device_state_bytes[1] = @intCast(bc.path.len);
                    @memcpy(config_device_state_bytes[2..][0..bc.path.len], bc.path);
                    config_device_state_bytes = config_device_state_bytes[2 + bc.path.len ..];
                }
            }
            log.debug(
                @src(),
                "Saved BlockMmioIoUring devices. Bytes left: {d}",
                .{config_device_state_bytes.len},
            );
            for (config.block.configs.slice_const()) |*bc| {
                if (bc.pci and bc.io_uring) {
                    config_device_state_bytes[0] = @intFromBool(bc.read_only);
                    config_device_state_bytes[1] = @intCast(bc.path.len);
                    @memcpy(config_device_state_bytes[2..][0..bc.path.len], bc.path);
                    config_device_state_bytes = config_device_state_bytes[2 + bc.path.len ..];
                }
            }
            log.debug(
                @src(),
                "Saved BlockPciIoUring devices. Bytes left: {d}",
                .{config_device_state_bytes.len},
            );
            for (config.network.configs.slice_const()) |*nc| {
                if (!nc.vhost) {
                    config_device_state_bytes[0] = @intCast(nc.dev_name.len);
                    @memcpy(config_device_state_bytes[1 .. 1 + nc.dev_name.len], nc.dev_name);
                    config_device_state_bytes = config_device_state_bytes[nc.dev_name.len + 1 ..];
                }
            }
            log.debug(
                @src(),
                "Saved VirtioNet devices. Bytes left: {d}",
                .{config_device_state_bytes.len},
            );
            for (config.network.configs.slice_const()) |*nc| {
                if (nc.vhost) {
                    config_device_state_bytes[0] = @intCast(nc.dev_name.len);
                    @memcpy(config_device_state_bytes[1 .. 1 + nc.dev_name.len], nc.dev_name);
                    config_device_state_bytes = config_device_state_bytes[nc.dev_name.len + 1 ..];
                }
            }
            log.debug(
                @src(),
                "Saved VhostNet devices. Bytes left: {d}",
                .{config_device_state_bytes.len},
            );
            for (config.pmem.configs.slice_const()) |pc| {
                config_device_state_bytes[0] = @intCast(pc.path.len);
                @memcpy(config_device_state_bytes[1 .. 1 + pc.path.len], pc.path);
                config_device_state_bytes = config_device_state_bytes[pc.path.len + 1 ..];
            }
            log.debug(
                @src(),
                "Saved Pmem devices. Bytes left: {d}",
                .{config_device_state_bytes.len},
            );
            log.assert(
                @src(),
                config_device_state_bytes.len == 0,
                "Not all config_state bytes were used. {d} left",
                .{config_device_state_bytes.len},
            );
        }

        return result;
    }

    pub fn from_snapshot(comptime System: type, snapshot_path: []const u8) State {
        const prof_point = MEASUREMENTS.start_named("State.from_snapshot");
        defer MEASUREMENTS.end(prof_point);

        var result: State = undefined;

        result.permanent_memory = .init_from_snapshot(System, snapshot_path);
        var pm: []u8 = result.permanent_memory.mem;

        result.config_state = @ptrCast(@alignCast(pm[pm.len - @sizeOf(ConfigState) ..]));
        log.debug(@src(), "Restored ConfigState: {any}", .{result.config_state});

        const memory_bytes = result.config_state.memory_mb << 20;
        const mmio_regions_bytes = Mmio.MMIO_DEVICE_ALLOCATED_REGION_SIZE *
            (result.config_state.block_mmio_count +
                result.config_state.block_mmio_io_uring_count +
                result.config_state.net_mmio_count +
                result.config_state.net_vhost_mmio_count);
        const net_iov_ring_bytes = IovRing.BACKING_SIZE * result.config_state.net_mmio_count;

        const vcpu_bytes = @sizeOf(Vcpu) * result.config_state.vcpus;
        const thread_bytes = @sizeOf(std.Thread) * result.config_state.vcpus;
        const block_mmio_bytes =
            @sizeOf(BlockMmio) * @as(usize, @intCast(result.config_state.block_mmio_count));
        const block_pci_bytes =
            @sizeOf(BlockPci) * @as(usize, @intCast(result.config_state.block_pci_count));
        const block_mmio_io_uring_bytes = @sizeOf(BlockMmioIoUring) *
            @as(usize, @intCast(result.config_state.block_mmio_io_uring_count));
        const block_pci_io_uring_bytes = @sizeOf(BlockPciIoUring) *
            @as(usize, @intCast(result.config_state.block_pci_io_uring_count));
        const net_bytes =
            @sizeOf(NetMmio) * @as(usize, @intCast(result.config_state.net_mmio_count));
        const vhost_net_bytes =
            @sizeOf(NetMmioVhost) * @as(usize, @intCast(result.config_state.net_vhost_mmio_count));

        const pci_devices =
            result.config_state.block_pci_count + result.config_state.block_pci_io_uring_count;
        const ecam_bytes = @sizeOf(Ecam) +
            @sizeOf(Ecam.Type0ConfigurationHeader) * pci_devices +
            @sizeOf(Ecam.HeaderBarSizes) * pci_devices;

        var uart_bytes: usize = 0;
        if (result.config_state.uart_enabled)
            uart_bytes = @sizeOf(Uart);
        const rtc_bytes: usize = @sizeOf(Rtc);

        const vcpu_reg_list_bytes = @sizeOf(Vcpu.RegList);
        const vcpu_regs_bytes = result.config_state.vcpus * Vcpu.PER_VCPU_REGS_BYTES;
        const vcpu_mpstates_bytes = result.config_state.vcpus * @sizeOf(nix.kvm_mp_state);
        const gicv2_state_bytes =
            result.config_state.vcpus * Gicv2.VGIC_CPU_REGS_BYTES + Gicv2.VGIC_DIST_REGS_BYTES;

        log.debug(@src(), "memory_bytes: {d}", .{memory_bytes});
        result.memory = .{ .mem = @alignCast(pm[0..memory_bytes]) };
        pm = pm[memory_bytes..];

        log.debug(@src(), "mmio_regions_bytes: {d}", .{mmio_regions_bytes});
        result.mmio_regions = @alignCast(pm[0..mmio_regions_bytes]);
        pm = pm[mmio_regions_bytes..];

        log.debug(@src(), "net_iov_ring_bytes: {d}", .{net_iov_ring_bytes});
        result.net_iov_ring = @alignCast(pm[0..net_iov_ring_bytes]);
        pm = pm[net_iov_ring_bytes..];

        log.debug(@src(), "vcpu_bytes: {d}", .{vcpu_bytes});
        result.vcpus = @ptrCast(@alignCast(pm[0..vcpu_bytes]));
        pm = pm[vcpu_bytes..];

        log.debug(@src(), "thread_bytes: {d}", .{thread_bytes});
        result.vcpu_threads = @ptrCast(@alignCast(pm[0..thread_bytes]));
        pm = pm[thread_bytes..];

        log.debug(@src(), "block_mmio_bytes: {d}", .{block_mmio_bytes});
        result.block_mmio = @ptrCast(@alignCast(pm[0..block_mmio_bytes]));
        pm = pm[block_mmio_bytes..];

        log.debug(@src(), "block_pci_bytes: {d}", .{block_pci_bytes});
        result.block_pci = @ptrCast(@alignCast(pm[0..block_pci_bytes]));
        pm = pm[block_pci_bytes..];

        log.debug(@src(), "block_mmio_io_uring_bytes: {d}", .{block_mmio_io_uring_bytes});
        result.block_mmio_io_uring =
            @ptrCast(@alignCast(pm[0..block_mmio_io_uring_bytes]));
        pm = pm[block_mmio_io_uring_bytes..];

        log.debug(@src(), "block_pci_io_uring_bytes: {d}", .{block_pci_io_uring_bytes});
        result.block_pci_io_uring =
            @ptrCast(@alignCast(pm[0..block_pci_io_uring_bytes]));
        pm = pm[block_pci_io_uring_bytes..];

        log.debug(@src(), "net_bytes: {d}", .{net_bytes});
        result.net_mmio = @ptrCast(@alignCast(pm[0..net_bytes]));
        pm = pm[net_bytes..];

        log.debug(@src(), "vhost_net_bytes: {d}", .{vhost_net_bytes});
        result.net_mmio_vhost = @ptrCast(@alignCast(pm[0..vhost_net_bytes]));
        pm = pm[vhost_net_bytes..];

        log.debug(@src(), "ecam_bytes: {d}", .{ecam_bytes});
        result.ecam_memory = @ptrCast(@alignCast(pm[0..ecam_bytes]));
        pm = pm[ecam_bytes..];

        if (result.config_state.uart_enabled) {
            log.debug(@src(), "uart_bytes: {d}", .{uart_bytes});
            result.uart = @ptrCast(@alignCast(pm[0..uart_bytes]));
            pm = pm[uart_bytes..];
        }
        log.debug(@src(), "rtc_bytes: {d}", .{rtc_bytes});
        result.rtc = @ptrCast(@alignCast(pm[0..rtc_bytes]));
        pm = pm[rtc_bytes..];

        log.debug(@src(), "vcpu_reg_list_bytes: {d}", .{vcpu_reg_list_bytes});
        result.vcpu_reg_list = @ptrCast(@alignCast(pm[0..vcpu_reg_list_bytes]));
        pm = pm[vcpu_reg_list_bytes..];

        log.debug(@src(), "vcpu_regs_bytes: {d}", .{vcpu_regs_bytes});
        result.vcpu_regs = @ptrCast(@alignCast(pm[0..vcpu_regs_bytes]));
        pm = pm[vcpu_regs_bytes..];

        log.debug(@src(), "vcpu_mpstates_bytes: {d}", .{vcpu_mpstates_bytes});
        result.vcpu_mp_states = @ptrCast(@alignCast(pm[0..vcpu_mpstates_bytes]));
        pm = pm[vcpu_mpstates_bytes..];

        log.debug(@src(), "gicv2_state_bytes: {d}", .{gicv2_state_bytes});
        result.gicv2_state = @ptrCast(@alignCast(pm[0..gicv2_state_bytes]));
        pm = pm[gicv2_state_bytes..];

        log.debug(@src(), "config_devices_bytes: {d}", .{pm.len - @sizeOf(ConfigState)});
        result.config_devices_state = @ptrCast(pm[0 .. pm.len - @sizeOf(ConfigState)]);

        return result;
    }
};

comptime {
    _ = @import("./virtio/queue.zig");
    _ = @import("./virtio/iov_ring.zig");
    _ = @import("./ring_buffer.zig");
}
