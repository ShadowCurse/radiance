const std = @import("std");
const log = @import("log.zig");
const nix = @import("nix.zig");
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

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var config = try config_parser.parse(
        allocator,
        args.config_path,
    );
    defer config.deinit(allocator);

    var memory = try Memory.init(config.machine.memory_mb << 20);
    defer memory.deinit();
    const kernel_load_address = try memory.load_linux_kernel(config.kernel.path);

    const kvm = try Kvm.new();

    // create vm
    const vm = try Vm.new(&kvm);
    try vm.set_memory(&memory);

    const kvi = try vm.get_preferred_target();

    // create vcpu
    var vcpus = try allocator.alloc(Vcpu, config.machine.vcpus);
    defer allocator.free(vcpus);

    const vcpu_exit_signal = Vcpu.get_vcpu_interrupt_signal();

    for (vcpus, 0..) |*vcpu, i| {
        vcpu.* = try Vcpu.new(&kvm, &vm, i, vcpu_exit_signal);
        try vcpu.init(kvi);
    }

    // create interrupt controller
    const gicv2 = try Gicv2.new(&vm);

    // create mmio devices
    var mmio = Mmio.new();
    const uart_device_info = mmio.allocate();
    const rtc_device_info = mmio.allocate();

    const virtio_device_infos_num = config.drives.drives.items.len + config.networks.networks.items.len;
    var virtio_device_infos = try allocator.alloc(Mmio.MmioDeviceInfo, virtio_device_infos_num);
    defer allocator.free(virtio_device_infos);
    for (0..virtio_device_infos_num) |i| {
        virtio_device_infos[i] = mmio.allocate();
    }

    var uart = try Uart.new(&vm, nix.STDIN_FILENO, nix.STDOUT_FILENO, uart_device_info);
    var rtc = Rtc.new();

    const virtio_blocks = try allocator.alloc(VirtioBlock, config.drives.drives.items.len);
    defer allocator.free(virtio_blocks);
    const vb_infos = virtio_device_infos[0..config.drives.drives.items.len];
    for (virtio_blocks, config.drives.drives.items, vb_infos) |*block, *drive, mmio_info| {
        block.* = try VirtioBlock.new(&vm, drive.path, drive.read_only, &memory, mmio_info);
    }

    var vhost_net_count: u8 = 0;
    var virtio_net_count: u8 = 0;
    for (config.networks.networks.items) |*net_config| {
        if (net_config.vhost) {
            vhost_net_count += 1;
        } else {
            virtio_net_count += 1;
        }
    }

    const virtio_nets = try allocator.alloc(VirtioNet, virtio_net_count);
    defer allocator.free(virtio_nets);

    const vhost_nets = try allocator.alloc(VhostNet, vhost_net_count);
    defer allocator.free(vhost_nets);

    var virtio_net_index: u8 = 0;
    var vhost_net_index: u8 = 0;
    const net_infos = virtio_device_infos[config.drives.drives.items.len..];
    for (config.networks.networks.items, net_infos) |*net_config, mmio_info| {
        if (net_config.vhost) {
            vhost_nets[vhost_net_index] = try VhostNet.new(&vm, net_config.dev_name, net_config.mac, &memory, mmio_info);
            vhost_net_index += 1;
        } else {
            virtio_nets[virtio_net_index] = try VirtioNet.new(&vm, net_config.dev_name, net_config.mac, &memory, mmio_info);
            virtio_net_index += 1;
        }
    }

    // mmio.add_device(Mmio.MmioDevice{ .Uart = &uart });
    // mmio.add_device(Mmio.MmioDevice{ .Rtc = &rtc });
    // for (virtio_blocks) |*virtio_block| {
    //     mmio.add_device(Mmio.MmioDevice{ .VirtioBlock = virtio_block });
    // }
    // for (virtio_nets) |*virtio_net| {
    //     mmio.add_device(.{ .VirtioNet = virtio_net });
    // }
    // for (vhost_nets) |*vhost_net| {
    //     mmio.add_device(.{ .VhostNet = vhost_net });
    // }

    mmio.add_device(.{ .ptr = &uart, .read_ptr = @ptrCast(&Uart.read), .write_ptr = @ptrCast(&Uart.write) });
    mmio.add_device(.{ .ptr = &rtc, .read_ptr = @ptrCast(&Uart.read), .write_ptr = @ptrCast(&Uart.write) });
    for (virtio_blocks) |*virtio_block| {
        mmio.add_device(.{ .ptr = virtio_block, .read_ptr = @ptrCast(&VirtioBlock.read), .write_ptr = @ptrCast(&VirtioBlock.write) });
    }
    for (virtio_nets) |*virtio_net| {
        mmio.add_device(.{ .ptr = virtio_net, .read_ptr = @ptrCast(&VirtioNet.read), .write_ptr = @ptrCast(&VirtioNet.write) });
    }
    for (vhost_nets) |*vhost_net| {
        mmio.add_device(.{ .ptr = vhost_net, .read_ptr = @ptrCast(&VhostNet.read), .write_ptr = @ptrCast(&VhostNet.write) });
    }

    // create kernel cmdline
    var cmdline = try CmdLine.new(allocator, 50);
    defer cmdline.deinit();

    try cmdline.append("console=ttyS0 reboot=k panic=1 pci=off");
    if (virtio_blocks[0].read_only) {
        try cmdline.append(" root=/dev/vda ro");
    } else {
        try cmdline.append(" root=/dev/vda rw");
    }
    try Uart.add_to_cmdline(&cmdline, uart_device_info);

    const cmdline_0 = try cmdline.sentinel_str();

    // create fdt
    const fdt_addr = fdt: {
        const mpidrs = try allocator.alloc(u64, config.machine.vcpus);
        defer allocator.free(mpidrs);
        for (mpidrs, vcpus) |*mpidr, *vcpu| {
            mpidr.* = try vcpu.get_reg(Vcpu.MPIDR_EL1);
        }

        var fdt = try FDT.create_fdt(
            allocator,
            &memory,
            mpidrs,
            cmdline_0,
            &gicv2,
            uart_device_info,
            rtc_device_info,
            virtio_device_infos,
        );
        defer fdt.deinit();

        const fdt_addr = try memory.load_fdt(&fdt);
        break :fdt fdt_addr;
    };

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
    const vcpu_threads = try allocator.alloc(std.Thread, config.machine.vcpus);
    defer allocator.free(vcpu_threads);

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
            vcpu_exit_signal,
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
