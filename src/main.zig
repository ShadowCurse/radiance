const std = @import("std");
const log = @import("log.zig");
const nix = @import("nix.zig");
const allocator = @import("allocator.zig");
const args_parser = @import("args_parser.zig");
const config_parser = @import("config_parser.zig");

const gdb = @import("gdb.zig");

const Uart = @import("devices/uart.zig");
const Rtc = @import("devices/rtc.zig");
const VirtioBlock = @import("devices/virtio-block.zig").VirtioBlock;
const VhostNet = @import("devices/vhost-net.zig").VhostNet;
const VirtioNet = @import("devices/virtio-net.zig").VirtioNet;

const EventLoop = @import("event_loop.zig");
const CmdLine = @import("cmdline.zig");
const FDT = @import("fdt.zig");
const Gicv2 = @import("gicv2.zig");
const Kvm = @import("kvm.zig");
const Memory = @import("memory.zig");
const Mmio = @import("mmio.zig");
const Vcpu = @import("vcpu.zig");
const Vm = @import("vm.zig");

pub const std_options = std.Options{
    .log_level = .info,
};

const Args = struct {
    config_path: []const u8,
};

pub fn main() !void {
    const start_time = try std.time.Instant.now();
    const args = try args_parser.parse(Args);
    const config_parse_result = try config_parser.parse(args.config_path);
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

    const permanent_memory_size = @sizeOf(Vcpu) * config.machine.vcpus +
        @sizeOf(std.Thread) * config.machine.vcpus +
        @sizeOf(VirtioBlock) * @as(u32, @intCast(config.drives.drives.len)) +
        @sizeOf(VirtioNet) * virtio_net_count +
        @sizeOf(VhostNet) * vhost_net_count;

    log.info(@src(), "permanent memory size: {} bytes", .{permanent_memory_size});
    var permanent_memory = try allocator.PermanentMemory.init(permanent_memory_size);
    const permanent_alloc = permanent_memory.allocator();

    var memory = try Memory.init(config.machine.memory_mb << 20);
    const load_result = try memory.load_linux_kernel(config.kernel.path);
    const kernel_load_address = load_result[0];
    const kernel_size = load_result[1];

    var guest_memory = allocator.GuestMemory.init(&memory, kernel_size);
    const tmp_alloc = guest_memory.allocator();

    const kvm = try Kvm.new();

    // create vm
    var vm = try Vm.new(&kvm);
    try vm.set_memory(.{
        .guest_phys_addr = memory.guest_addr,
        .memory_size = memory.mem.len,
        .userspace_addr = @intFromPtr(memory.mem.ptr),
    });

    const kvi = try vm.get_preferred_target();

    // create vcpu
    var vcpus = try permanent_alloc.alloc(Vcpu, config.machine.vcpus);

    for (vcpus, 0..) |*vcpu, i| {
        vcpu.* = try Vcpu.new(&kvm, &vm, i);
        try vcpu.init(kvi);
    }

    // create interrupt controller
    try Gicv2.new(&vm);

    // create mmio devices
    var mmio = Mmio.new();
    const uart_device_info = mmio.allocate();
    const rtc_device_info = mmio.allocate();
    mmio.start_mmio_opt();

    const virtio_device_infos_num = config.drives.drives.len + config.networks.networks.len;
    var virtio_device_infos = try tmp_alloc.alloc(Mmio.MmioDeviceInfo, virtio_device_infos_num);
    for (0..virtio_device_infos_num) |i| {
        virtio_device_infos[i] = mmio.allocate_virtio();
    }

    var uart = try Uart.new(&vm, nix.STDIN_FILENO, nix.STDOUT_FILENO, uart_device_info);
    var rtc = Rtc.new();

    const virtio_blocks = try permanent_alloc.alloc(VirtioBlock, config.drives.drives.len);
    const vb_infos = virtio_device_infos[0..config.drives.drives.len];
    for (virtio_blocks, config.drives.drives.slice(), vb_infos) |*block, *drive, mmio_info| {
        block.* = try VirtioBlock.new(&vm, drive.path, drive.read_only, &memory, mmio_info);
    }

    const virtio_nets = try permanent_alloc.alloc(VirtioNet, virtio_net_count);
    const vhost_nets = try permanent_alloc.alloc(VhostNet, vhost_net_count);

    var virtio_net_index: u8 = 0;
    var vhost_net_index: u8 = 0;
    const net_infos = virtio_device_infos[config.drives.drives.len..];
    for (config.networks.networks.slice(), net_infos) |*net_config, mmio_info| {
        if (net_config.vhost) {
            vhost_nets[vhost_net_index] = try VhostNet.new(&vm, net_config.dev_name, net_config.mac, &memory, mmio_info);
            vhost_net_index += 1;
        } else {
            virtio_nets[virtio_net_index] = try VirtioNet.new(&vm, net_config.dev_name, net_config.mac, &memory, mmio_info);
            virtio_net_index += 1;
        }
    }

    mmio.add_device(.{ .ptr = &uart, .read_ptr = @ptrCast(&Uart.read), .write_ptr = @ptrCast(&Uart.write) });
    mmio.add_device(.{ .ptr = &rtc, .read_ptr = @ptrCast(&Uart.read), .write_ptr = @ptrCast(&Uart.write) });
    for (virtio_blocks) |*virtio_block| {
        mmio.add_device_virtio(.{ .ptr = virtio_block, .read_ptr = @ptrCast(&VirtioBlock.read), .write_ptr = @ptrCast(&VirtioBlock.write) });
    }
    for (virtio_nets) |*virtio_net| {
        mmio.add_device_virtio(.{ .ptr = virtio_net, .read_ptr = @ptrCast(&VirtioNet.read), .write_ptr = @ptrCast(&VirtioNet.write) });
    }
    for (vhost_nets) |*vhost_net| {
        mmio.add_device_virtio(.{ .ptr = vhost_net, .read_ptr = @ptrCast(&VhostNet.read), .write_ptr = @ptrCast(&VhostNet.write) });
    }

    // create kernel cmdline
    var cmdline = try CmdLine.new(tmp_alloc, 50);

    try cmdline.append("console=ttyS0 reboot=k panic=1 pci=off");
    if (virtio_blocks[0].read_only) {
        try cmdline.append(" root=/dev/vda ro");
    } else {
        try cmdline.append(" root=/dev/vda rw");
    }
    try Uart.add_to_cmdline(&cmdline, uart_device_info);

    const cmdline_0 = try cmdline.sentinel_str();

    // create fdt
    const mpidrs = try tmp_alloc.alloc(u64, config.machine.vcpus);
    for (mpidrs, vcpus) |*mpidr, *vcpu| {
        mpidr.* = try vcpu.get_reg(Vcpu.MPIDR_EL1);
    }

    const fdt_addr = try FDT.create_fdt(
        tmp_alloc,
        &memory,
        mpidrs,
        cmdline_0,
        uart_device_info,
        rtc_device_info,
        virtio_device_infos,
    );

    // configure vcpus
    try vcpus[0].set_reg(u64, Vcpu.PC, kernel_load_address);
    try vcpus[0].set_reg(u64, Vcpu.REGS0, @as(u64, fdt_addr));

    for (vcpus) |*vcpu| {
        try vcpu.set_reg(u64, Vcpu.PSTATE, Vcpu.PSTATE_FAULT_BITS_64);
    }

    // configure terminal for uart in/out
    const stdin = std.io.getStdIn();
    const state = configure_terminal(&stdin);

    // start vcpu threads
    const vcpu_threads = try permanent_alloc.alloc(std.Thread, config.machine.vcpus);

    // free config memory
    config_parse_result.deinit();

    std.log.info("starting vcpu threads", .{});
    var barrier: std.Thread.ResetEvent = .{};
    for (vcpu_threads, vcpus) |*t, *vcpu| {
        t.* = try std.Thread.spawn(
            .{},
            Vcpu.run_threaded,
            .{ vcpu, &barrier, &mmio, &start_time },
        );
    }

    // create event loop
    var el = try EventLoop.new();
    try el.add_event(stdin.handle, @ptrCast(&Uart.read_input), &uart);
    for (virtio_blocks) |*block| {
        try el.add_event(
            block.virtio_context.queue_events[0].fd,
            @ptrCast(&VirtioBlock.process_queue),
            block,
        );
    }
    for (virtio_nets) |*net| {
        try el.add_event(
            net.virtio_context.queue_events[0].fd,
            @ptrCast(&VirtioNet.process_rx),
            net,
        );
        try el.add_event(
            net.virtio_context.queue_events[1].fd,
            @ptrCast(&VirtioNet.process_tx),
            net,
        );
        try el.add_event(
            net.tun,
            @ptrCast(&VirtioNet.process_tap),
            net,
        );
    }
    for (vcpus) |*vcpu| {
        try el.add_event(vcpu.exit_event.fd, @ptrCast(&EventLoop.stop), &el);
    }

    if (config.gdb.socket_path) |sp| {
        // start gdb server
        var gdb_server = try gdb.GdbServer.init(
            sp,
            vcpus,
            vcpu_threads,
            &barrier,
            &memory,
            &mmio,
            &el,
        );
        try el.add_event(gdb_server.connection.stream.handle, @ptrCast(&gdb.GdbServer.process_request), &gdb_server);

        // start event loop
        try el.run();
    } else {
        // start vcpus
        barrier.set();

        // start event loop
        try el.run();
    }

    log.info(@src(), "Shutting down", .{});
    restore_terminal(&stdin, &state);
    return;
}

fn configure_terminal(stdin: *const std.fs.File) nix.termios {
    var ttystate: nix.termios = undefined;
    var ttysave: nix.termios = undefined;

    _ = nix.tcgetattr(stdin.handle, &ttystate);
    ttysave = ttystate;

    //turn off canonical mode and echo
    ttystate.lflag.ECHO = false;
    ttystate.lflag.ICANON = false;
    //minimum of number input read.
    ttystate.cc[4] = 1;

    //set the terminal attributes.
    _ = nix.tcsetattr(stdin.handle, nix.TCSA.NOW, &ttystate);
    return ttysave;
}

fn restore_terminal(
    stdin: *const std.fs.File,
    state: *const nix.termios,
) void {
    //set the terminal attributes.
    _ = nix.tcsetattr(stdin.handle, nix.TCSA.NOW, state);
}

pub const _queue = @import("./virtio/queue.zig");
pub const _iov_ring = @import("./virtio/iov_ring.zig");
pub const _ring_buffer = @import("./ring_buffer.zig");
test {
    std.testing.refAllDecls(@This());
}
