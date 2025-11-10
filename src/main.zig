const std = @import("std");
const build_options = @import("build_options");
const log = @import("log.zig");
const nix = @import("nix.zig");
const gdb = @import("gdb.zig");
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

const Args = struct {
    config_path: ?[]const u8 = null,
    save_state: bool = false,
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
        VirtioNet,
        VhostNet,
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

    const start_time = try std.time.Instant.now();
    const args = try args_parser.parse(Args);
    if (args.config_path == null) {
        try args_parser.print_help(Args);
        return;
    }
    const config_parse_result = try config_parser.parse_file(nix.System, args.config_path.?);
    const config = &config_parse_result.config;

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
    const net_bytes = @sizeOf(VirtioNet) * @as(usize, @intCast(net_mmio_count));
    const vhost_net_bytes = @sizeOf(VhostNet) * @as(usize, @intCast(net_vhost_mmio_count));

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
    const gicv2_state_bytes = @sizeOf(Gicv2.State);
    // 1 byte aligned
    var config_devices_bytes: usize = 0;
    // The only thing needed saving for devices are paths and read_only flags
    for (config.block.configs.items) |bc| config_devices_bytes += bc.path.len + 1 + 1;
    for (config.network.configs.items) |nc| config_devices_bytes += nc.dev_name.len + 1;
    for (config.pmem.configs.items) |pc| config_devices_bytes += pc.path.len + 1;
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
    if (args.save_state) {
        permanent_memory_size += vcpu_reg_list_bytes +
            vcpu_regs_bytes + gicv2_state_bytes + config_devices_bytes;

        // Need to store ConfigState last and it needs aligment update;
        permanent_memory_size = Memory.align_addr(permanent_memory_size, @alignOf(ConfigState));
        permanent_memory_size += config_bytes;
    }

    log.info(@src(), "permanent memory size: {} bytes", .{permanent_memory_size});
    const permanent_memory: Memory.Permanent = .init(nix.System, permanent_memory_size);
    var pm: []u8 = permanent_memory.mem;

    var memory: Memory.Guest = .{ .mem = @alignCast(pm[0..memory_bytes]) };
    pm = pm[memory_bytes..];

    var mmio_regions: []align(Memory.HOST_PAGE_SIZE) u8 = @alignCast(pm[0..mmio_regions_bytes]);
    pm = pm[mmio_regions_bytes..];

    const net_iov_ring: []align(Memory.HOST_PAGE_SIZE) u8 = @alignCast(pm[0..net_iov_ring_bytes]);
    pm = pm[net_iov_ring_bytes..];

    const vcpus: []Vcpu = @ptrCast(@alignCast(pm[0..vcpu_bytes]));
    pm = pm[vcpu_bytes..];

    const vcpu_threads: []std.Thread = @ptrCast(@alignCast(pm[0..thread_bytes]));
    pm = pm[thread_bytes..];

    const block_mmio: []BlockMmio = @ptrCast(@alignCast(pm[0..block_mmio_bytes]));
    pm = pm[block_mmio_bytes..];

    const block_pci: []BlockPci = @ptrCast(@alignCast(pm[0..block_pci_bytes]));
    pm = pm[block_pci_bytes..];

    const block_mmio_io_uring: []BlockMmioIoUring =
        @ptrCast(@alignCast(pm[0..block_mmio_io_uring_bytes]));
    pm = pm[block_mmio_io_uring_bytes..];

    const block_pci_io_uring: []BlockPciIoUring =
        @ptrCast(@alignCast(pm[0..block_pci_io_uring_bytes]));
    pm = pm[block_pci_io_uring_bytes..];

    const net: []VirtioNet = @ptrCast(@alignCast(pm[0..net_bytes]));
    pm = pm[net_bytes..];

    const vhost_net: []VhostNet = @ptrCast(@alignCast(pm[0..vhost_net_bytes]));
    pm = pm[vhost_net_bytes..];

    const ecam_memory: []align(8) u8 = @ptrCast(@alignCast(pm[0..ecam_bytes]));
    pm = pm[ecam_bytes..];

    var uart: *Uart = undefined;
    if (config.uart.enabled) {
        uart = @ptrCast(@alignCast(pm[0..uart_bytes]));
        pm = pm[uart_bytes..];
    }
    const rtc: *Rtc = @ptrCast(@alignCast(pm[0..rtc_bytes]));
    rtc.* = .{};
    pm = pm[rtc_bytes..];

    var vcpu_reg_list: *Vcpu.RegList = undefined;
    var vcpu_regs: []u8 = undefined;
    var gicv2_state: *Gicv2.State = undefined;
    var config_state: *ConfigState = undefined;
    var config_devices_state: []u8 = undefined;
    if (args.save_state) {
        vcpu_reg_list = @ptrCast(@alignCast(pm[0..vcpu_reg_list_bytes]));
        // First value is the number of ids in the list. Set to 0 to
        // be able to detect when list needs to be queried.
        vcpu_reg_list[0] = 0;
        pm = pm[vcpu_reg_list_bytes..];

        vcpu_regs = @ptrCast(@alignCast(pm[0..vcpu_regs_bytes]));
        pm = pm[vcpu_regs_bytes..];

        gicv2_state = @ptrCast(@alignCast(pm[0..gicv2_state_bytes]));
        pm = pm[gicv2_state_bytes..];

        config_devices_state = @ptrCast(pm[0..config_devices_bytes]);
        pm = pm[config_devices_bytes..];

        config_state = @ptrCast(@alignCast(pm[pm.len - @sizeOf(ConfigState) ..]));
    }

    var load_result = memory.load_linux_kernel(nix.System, config.kernel.path);
    const tmp_alloc = load_result.post_kernel_allocator.allocator();

    // create vm
    const kvm = Kvm.init(nix.System);
    var vm = Vm.init(nix.System, &kvm);
    vm.set_memory(nix.System, .{
        .guest_phys_addr = Memory.DRAM_START,
        .memory_size = memory.mem.len,
        .userspace_addr = @intFromPtr(memory.mem.ptr),
    });

    // create vcpu
    const kvi = vm.get_preferred_target(nix.System);
    const vcpu_exit_event = EventFd.init(nix.System, 0, nix.EFD_NONBLOCK);
    const vcpu_mmap_size = kvm.vcpu_mmap_size(nix.System);
    for (vcpus, 0..) |*vcpu, i|
        vcpu.* = .init(nix.System, &vm, i, vcpu_exit_event, vcpu_mmap_size, kvi);

    // create interrupt controller
    const gicv2: Gicv2 = .init(nix.System, &vm);

    // attach pmem
    var last_addr = Memory.align_addr(memory.last_addr(), Pmem.ALIGNMENT);
    const pmem_infos = try tmp_alloc.alloc(Pmem.Info, config.pmem.configs.len);
    for (config.pmem.configs.slice_const(), pmem_infos) |*pmem_config, *info| {
        info.start = last_addr;
        info.len = Pmem.attach(nix.System, &vm, pmem_config.path, info.start);
        last_addr += info.len;
    }

    // create mmio devices
    var mmio_resources: Mmio.Resources = .{};

    // preallocate all mmio regions for the devices. This is needed to
    // pass a single slice of mmio regions to the fdt builder.
    const block_mmio_info_count = block_mmio_count +
        block_mmio_io_uring_count;
    const net_mmio_info_count = net_mmio_count +
        net_vhost_mmio_count;
    const mmio_info_count = block_mmio_info_count + net_mmio_info_count;
    const mmio_infos = try tmp_alloc.alloc(Mmio.Resources.MmioVirtioInfo, mmio_info_count);
    for (mmio_infos) |*info| {
        info.* = mmio_resources.allocate_mmio_virtio();
        info.mem_ptr = mmio_regions.ptr;
        mmio_regions = mmio_regions[Mmio.MMIO_DEVICE_ALLOCATED_REGION_SIZE..];
    }

    var mmio_block_infos = mmio_infos[0..block_mmio_info_count];
    var mmio_net_infos = mmio_infos[block_mmio_info_count..][0..net_mmio_info_count];

    const ecam: *Ecam = try .init(ecam_memory, pci_devices);
    var mmio: Mmio = .init(ecam);
    var el: EventLoop = .init(nix.System);
    var vcpu_barrier: std.Thread.ResetEvent = .{};

    var api: Api = undefined;
    if (config.api.socket_path) |socket_path| {
        api = .init(
            nix.System,
            socket_path,
            vcpus,
            vcpu_threads,
            &vcpu_barrier,
            vcpu_reg_list,
            vcpu_regs,
            gicv2,
            gicv2_state,
            permanent_memory,
        );
        el.add_event(
            nix.System,
            api.fd,
            @ptrCast(&Api.handle_default),
            &api,
        );
    }

    // configure terminal for uart in/out
    const state = if (config.uart.enabled) configure_terminal(nix.System) else undefined;
    if (config.uart.enabled) {
        uart.init(
            nix.System,
            &vm,
            nix.STDIN_FILENO,
            nix.STDOUT_FILENO,
        );
        mmio.add_device(.{
            .ptr = uart,
            .read_ptr = @ptrCast(&Uart.read),
            .write_ptr = @ptrCast(&Uart.write_default),
        });
        el.add_event(
            nix.System,
            nix.STDIN,
            @ptrCast(&Uart.event_read_input),
            uart,
        );
    } else undefined;

    mmio.add_device(.{
        .ptr = rtc,
        .read_ptr = @ptrCast(&Rtc.read),
        .write_ptr = @ptrCast(&Rtc.write),
    });

    var io_uring: IoUring = undefined;
    if (block_mmio_io_uring_count != 0 or block_pci_io_uring_count != 0) {
        io_uring = IoUring.init(nix.System, 256);
        el.add_event(
            nix.System,
            io_uring.eventfd.fd,
            @ptrCast(&IoUring.event_process_event),
            @ptrCast(&io_uring),
        );
    }

    try create_block_mmio(
        block_mmio,
        &vm,
        &mmio,
        memory,
        &el,
        mmio_block_infos[0..block_mmio_count],
        config.block.configs.slice_const(),
    );
    mmio_block_infos = mmio_block_infos[block_mmio_count..];
    defer for (block_mmio) |*block|
        block.sync(nix.System);

    try create_block_mmio_io_uring(
        block_mmio_io_uring,
        &vm,
        &mmio,
        memory,
        &el,
        &io_uring,
        mmio_block_infos[0..block_mmio_io_uring_count],
        config.block.configs.slice_const(),
    );
    mmio_block_infos = mmio_block_infos[block_mmio_io_uring_count..];
    defer for (block_mmio_io_uring) |*block|
        block.sync(nix.System);

    try create_block_pci(
        block_pci,
        &vm,
        &mmio,
        &mmio_resources,
        memory,
        &el,
        ecam,
        config.block.configs.slice_const(),
    );
    defer for (block_pci) |*block|
        block.sync(nix.System);

    try create_block_pci_io_uring(
        block_pci_io_uring,
        &vm,
        &mmio,
        &mmio_resources,
        memory,
        &el,
        &io_uring,
        ecam,
        config.block.configs.slice_const(),
    );
    defer for (block_pci_io_uring) |*block|
        block.sync(nix.System);

    try create_net_mmio(
        net,
        net_iov_ring,
        &vm,
        &mmio,
        memory,
        &el,
        mmio_net_infos[0..net_mmio_count],
        config.network.configs.slice_const(),
    );
    mmio_net_infos = mmio_net_infos[net_mmio_count..];

    try create_net_mmio_vhost(
        vhost_net,
        &vm,
        &mmio,
        memory,
        mmio_net_infos[0..net_vhost_mmio_count],
        config.network.configs.slice_const(),
    );
    mmio_net_infos = mmio_net_infos[net_vhost_mmio_count..];

    // create kernel cmdline
    var cmdline = try CmdLine.init(tmp_alloc, 128);
    try cmdline.append(config.machine.cmdline);
    for (config.block.configs.slice_const(), 0..) |*block_config, i| {
        if (block_config.rootfs) {
            var name_buff: [32]u8 = undefined;
            const mod = if (block_config.read_only) "ro" else "rw";
            var letter: u8 = 'a' + @as(u8, @intCast(i));
            // pci block will be initialized after mmio ones
            if (block_config.pci) {
                // There can only be less than 256 blocks
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
        @panic("No rootfs device selected");
    }
    if (config.uart.enabled) try Uart.add_to_cmdline(&cmdline);

    const cmdline_0 = try cmdline.sentinel_str();

    // create fdt
    const mpidrs = try tmp_alloc.alloc(u64, config.machine.vcpus);
    for (mpidrs, vcpus) |*mpidr, *vcpu| {
        mpidr.* = vcpu.get_reg(nix.System, Vcpu.MPIDR_EL1);
    }

    const fdt_addr = FDT.create_fdt(
        nix.System,
        tmp_alloc,
        memory,
        mpidrs,
        cmdline_0,
        config.uart.enabled,
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

    if (args.save_state) {
        config_state.memory_mb = config.machine.memory_mb;
        config_state.vcpus = config.machine.vcpus;
        config_state.uart_enabled = config.uart.enabled;
        config_state.block_mmio_count = block_mmio_count;
        config_state.block_pci_count = block_pci_count;
        config_state.block_mmio_io_uring_count = block_mmio_io_uring_count;
        config_state.block_pci_io_uring_count = block_pci_io_uring_count;
        config_state.net_mmio_count = net_mmio_count;
        config_state.net_vhost_mmio_count = net_vhost_mmio_count;
        config_state.pmem_count = @truncate(config.pmem.configs.items.len);
        var config_device_state_bytes = config_devices_state;
        for (config.block.configs.items) |bc| {
            config_device_state_bytes[0] = @intFromBool(bc.read_only);
            config_device_state_bytes[1] = @intCast(bc.path.len);
            @memcpy(config_device_state_bytes[2..][0..bc.path.len], bc.path);
            config_device_state_bytes = config_device_state_bytes[2 + bc.path.len ..];
        }
        for (config.network.configs.items) |nc| {
            config_device_state_bytes[0] = @intCast(nc.dev_name.len);
            @memcpy(config_device_state_bytes[1 .. 1 + nc.dev_name.len], nc.dev_name);
            config_device_state_bytes = config_device_state_bytes[nc.dev_name.len + 1 ..];
        }
        for (config.pmem.configs.items) |pc| {
            config_device_state_bytes[0] = @intCast(pc.path.len);
            @memcpy(config_device_state_bytes[1 .. 1 + pc.path.len], pc.path);
            config_device_state_bytes = config_device_state_bytes[pc.path.len + 1 ..];
        }
        log.assert(
            @src(),
            config_device_state_bytes.len == 0,
            "Not all config_state bytes were used. {d} left",
            .{config_device_state_bytes.len},
        );
    }
    config_parse_result.deinit(nix.System);

    // start vcpu threads
    log.debug(@src(), "starting vcpu threads", .{});
    // TODO this does linux futex syscalls. Maybe can be replaced
    // by simple atomic value?
    for (vcpu_threads, vcpus) |*t, *vcpu| {
        t.* = try nix.System.spawn_thread(
            .{},
            Vcpu.run_threaded,
            .{ vcpu, nix.System, &vcpu_barrier, &mmio, &start_time },
        );
    }

    if (config.gdb) |gdb_config| {
        // start gdb server
        var gdb_server = try gdb.GdbServer.init(
            nix.System,
            gdb_config.socket_path,
            vcpus,
            vcpu_threads,
            &vcpu_barrier,
            memory,
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
        vcpu_barrier.set();

        // start event loop
        el.run(nix.System);
    }

    log.info(@src(), "Shutting down", .{});
    if (config.uart.enabled) restore_terminal(nix.System, &state);
    return;
}

fn create_block_mmio(
    blocks: []BlockMmio,
    vm: *Vm,
    mmio: *Mmio,
    memory: Memory.Guest,
    event_loop: *EventLoop,
    mmio_infos: []const Mmio.Resources.MmioVirtioInfo,
    configs: []const config_parser.BlockConfig,
) !void {
    var index: u8 = 0;
    for (configs) |*config| {
        if (!config.io_uring and !config.pci) {
            const block = &blocks[index];
            const info = mmio_infos[index];
            index += 1;

            block.init(
                nix.System,
                config.path,
                config.read_only,
                config.id,
                vm,
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
}

fn create_block_mmio_io_uring(
    blocks: []BlockMmioIoUring,
    vm: *Vm,
    mmio: *Mmio,
    memory: Memory.Guest,
    event_loop: *EventLoop,
    io_uring: *IoUring,
    mmio_infos: []const Mmio.Resources.MmioVirtioInfo,
    configs: []const config_parser.BlockConfig,
) !void {
    var index: u8 = 0;
    for (configs) |*config| {
        if (config.io_uring and !config.pci) {
            const block = &blocks[index];
            const info = mmio_infos[index];
            index += 1;
            block.init(
                nix.System,
                config.path,
                config.read_only,
                config.id,
                vm,
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
}

fn create_block_pci(
    blocks: []BlockPci,
    vm: *Vm,
    mmio: *Mmio,
    mmio_resources: *Mmio.Resources,
    memory: Memory.Guest,
    event_loop: *EventLoop,
    ecam: *Ecam,
    configs: []const config_parser.BlockConfig,
) !void {
    var index: u8 = 0;
    for (configs) |*config| {
        if (!config.io_uring and config.pci) {
            const block = &blocks[index];
            index += 1;

            const info = mmio_resources.allocate_pci();
            ecam.add_header(
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
                vm,
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
}

fn create_block_pci_io_uring(
    blocks: []BlockPciIoUring,
    vm: *Vm,
    mmio: *Mmio,
    mmio_resources: *Mmio.Resources,
    memory: Memory.Guest,
    event_loop: *EventLoop,
    io_uring: *IoUring,
    ecam: *Ecam,
    configs: []const config_parser.BlockConfig,
) !void {
    var index: u8 = 0;
    for (configs) |*config| {
        if (config.io_uring and config.pci) {
            const block = &blocks[index];
            index += 1;

            const info = mmio_resources.allocate_pci();
            ecam.add_header(
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
                vm,
                memory,
                info,
            );
            block.io_uring_device = io_uring.add_device(
                @ptrCast(&BlockPciIoUring.event_process_io_uring_event),
                block,
            );
            mmio.add_device_pci(.{
                .ptr = block,
                .read_ptr = @ptrCast(&BlockPciIoUring.read),
                .write_ptr = @ptrCast(&BlockPciIoUring.write_default),
            });
            event_loop.add_event(
                nix.System,
                block.context.queue_events[0].fd,
                @ptrCast(&BlockPciIoUring.event_process_queue),
                block,
            );
        }
    }
}

fn create_net_mmio(
    nets: []VirtioNet,
    net_iov_ring: []align(Memory.HOST_PAGE_SIZE) u8,
    vm: *Vm,
    mmio: *Mmio,
    memory: Memory.Guest,
    event_loop: *EventLoop,
    mmio_infos: []const Mmio.Resources.MmioVirtioInfo,
    configs: []const config_parser.NetConfig,
) !void {
    var index: u8 = 0;
    var iov_ring = net_iov_ring;
    for (configs) |*config| {
        if (!config.vhost) {
            const net = &nets[index];
            const mmio_info = mmio_infos[index];
            const iov_ring_memory = iov_ring[0..IovRing.BACKING_SIZE];
            iov_ring = iov_ring[IovRing.BACKING_SIZE..];
            index += 1;

            net.init(
                nix.System,
                vm,
                config.dev_name,
                config.mac,
                memory,
                mmio_info,
                iov_ring_memory,
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
    nets: []VhostNet,
    vm: *Vm,
    mmio: *Mmio,
    memory: Memory.Guest,
    mmio_infos: []const Mmio.Resources.MmioVirtioInfo,
    configs: []const config_parser.NetConfig,
) !void {
    var index: u8 = 0;
    for (configs) |*config| {
        if (config.vhost) {
            const net = &nets[index];
            const mmio_info = mmio_infos[index];
            index += 1;

            net.init(
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
