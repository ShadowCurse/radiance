const std = @import("std");
const log = @import("log.zig");
const nix = @import("nix.zig");
const args_parser = @import("args_parser.zig");
const config_parser = @import("config_parser.zig");

const Uart = @import("devices/uart.zig");
const Rtc = @import("devices/rtc.zig");
const VirtioBlock = @import("devices/virtio-block.zig").VirtioBlock;
const VhostNet = @import("devices/vhost-net.zig").VhostNet;

const EventLoop = @import("event_loop.zig");
const CmdLine = @import("cmdline.zig");
const FDT = @import("fdt.zig");
const Gicv2 = @import("gicv2.zig");
const Kvm = @import("kvm.zig");
const Memory = @import("memory.zig");
const Mmio = @import("mmio.zig");
const Vcpu = @import("vcpu.zig");
const Vm = @import("vm.zig");

pub const std_options = struct {
    pub const log_level = .info;
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

    var uart = try Uart.new(&vm, std.os.STDIN_FILENO, std.os.STDOUT_FILENO, uart_device_info);
    var rtc = Rtc.new(rtc_device_info);

    var virtio_blocks = try allocator.alloc(VirtioBlock, config.drives.drives.items.len);
    defer allocator.free(virtio_blocks);
    const vb_infos = virtio_device_infos[0..config.drives.drives.items.len];
    for (virtio_blocks, config.drives.drives.items, vb_infos) |*block, *drive, mmio_info| {
        block.* = try VirtioBlock.new(&vm, drive.path, drive.read_only, &memory, mmio_info);
    }

    var vhost_nets = try allocator.alloc(VhostNet, config.networks.networks.items.len);
    defer allocator.free(vhost_nets);
    const vhn_infos = virtio_device_infos[config.drives.drives.items.len..];
    for (vhost_nets, config.networks.networks.items, vhn_infos) |*vhn, *net, mmio_info| {
        vhn.* = try VhostNet.new(&vm, net.dev_name, net.mac, &memory, mmio_info);
    }

    mmio.add_device(Mmio.MmioDevice{ .Uart = &uart });
    mmio.add_device(Mmio.MmioDevice{ .Rtc = &rtc });
    for (virtio_blocks) |*virtio_block| {
        mmio.add_device(Mmio.MmioDevice{ .VirtioBlock = virtio_block });
    }
    for (vhost_nets) |*vhost_net| {
        mmio.add_device(Mmio.MmioDevice{ .VhostNet = vhost_net });
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
    try uart.add_to_cmdline(&cmdline);

    const cmdline_0 = try cmdline.sentinel_str();

    // create fdt
    const fdt_addr = fdt: {
        var mpidrs = try allocator.alloc(u64, config.machine.vcpus);
        defer allocator.free(mpidrs);
        for (mpidrs, vcpus) |*mpidr, *vcpu| {
            mpidr.* = try vcpu.get_reg(Vcpu.MPIDR_EL1);
        }

        var fdt = try FDT.create_fdt(allocator, &memory, mpidrs, cmdline_0, &gicv2, uart_device_info, rtc_device_info, virtio_device_infos);
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
    var vcpu_threads = try allocator.alloc(std.Thread, config.machine.vcpus);
    defer allocator.free(vcpu_threads);

    std.log.info("starting vcpu threads", .{});
    var barrier: std.Thread.ResetEvent = .{};
    for (vcpu_threads, vcpus) |*t, *vcpu| {
        t.* = try std.Thread.spawn(.{}, Vcpu.run_threaded, .{ vcpu, &barrier, &mmio, &start_time });
    }

    // create event loop
    var el = try EventLoop.new();
    try el.add_event(stdin.handle, @ptrCast(&Uart.read_input), &uart);
    for (virtio_blocks) |*block| {
        try el.add_event(block.virtio_context.queue_events[0].fd, @ptrCast(&VirtioBlock.process_queue), block);
    }
    for (vcpus) |*vcpu| {
        try el.add_event(vcpu.exit_event.fd, @ptrCast(&EventLoop.stop), &el);
    }

    // start vcpus
    barrier.set();
    // start event loop
    try el.run();

    // stop all vcpus
    vcpu_threads[0].join();
    for (vcpu_threads[1..]) |*t| {
        Vcpu.kick_thread(t, vcpu_exit_signal);
        t.join();
    }

    restore_terminal(&stdin, &state);

    log.info(@src(), "Successful shutdown", .{});
}

fn configure_terminal(stdin: *const std.fs.File) std.os.termios {
    var ttystate: std.os.termios = undefined;
    var ttysave: std.os.termios = undefined;

    _ = std.os.linux.tcgetattr(stdin.handle, &ttystate);
    ttysave = ttystate;

    //turn off canonical mode and echo
    ttystate.lflag &= ~(std.os.linux.ICANON | std.os.linux.ECHO);
    //minimum of number input read.
    ttystate.cc[4] = 1;

    //set the terminal attributes.
    _ = std.os.linux.tcsetattr(stdin.handle, std.os.linux.TCSA.NOW, &ttystate);
    return ttysave;
}

fn restore_terminal(stdin: *const std.fs.File, state: *const std.os.termios) void {
    //set the terminal attributes.
    _ = std.os.linux.tcsetattr(stdin.handle, std.os.linux.TCSA.NOW, state);
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
