const std = @import("std");
const log = @import("log.zig");
const nix = @import("nix.zig");
const args_parser = @import("args_parser.zig");
const config_parser = @import("config_parser.zig");

const Uart = @import("devices/uart.zig");
const Rtc = @import("devices/rtc.zig");
const VirtioBlock = @import("devices/virtio-block.zig").VirtioBlock;

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
    kernel_path: []const u8,
    rootfs_path: []const u8,
    memory_size: u32,
    config_path: []const u8,
};

pub fn main() !void {
    const args = try args_parser.parse(Args);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var config = try config_parser.parse(args.config_path, allocator);
    defer config.deinit(allocator);
    std.log.info("machine config: {any}", .{config.machine});
    std.log.info("kernel config: {s}", .{config.kernel.path});
    std.log.info("rootfs config: {any}", .{config.rootfs});
    for (config.drives.drives.items) |*d| {
        std.log.info("drive config read only: {}", .{d.read_only});
        std.log.info("drive config path: {s}", .{d.path});
    }

    var memory = try Memory.init(args.memory_size << 20);
    defer memory.deinit();
    const kernel_load_address = try memory.load_linux_kernel(args.kernel_path);
    std.log.info("kernel_load_address: 0x{x}", .{kernel_load_address});

    const kvm = try Kvm.new();

    // create vm
    const vm = try Vm.new(&kvm);
    try vm.set_memory(&memory);

    // create vcpu
    var vcpu = try Vcpu.new(&kvm, &vm, 0);
    const kvi = try vm.get_preferred_target();
    try vcpu.init(kvi);
    try vcpu.set_reg(u64, Vcpu.PC, kernel_load_address);

    const vcpu_mpidr = try vcpu.get_reg(Vcpu.MIDR_EL1);
    std.log.info("mpidr: 0x{x}", .{vcpu_mpidr});

    const gicv2 = try Gicv2.new(&vm);

    var mmio = Mmio.new();
    const uart_device_info = mmio.allocate();
    const rtc_device_info = mmio.allocate();
    const virtio_block_device_info = mmio.allocate();

    var uart = try Uart.new(&vm, std.os.STDIN_FILENO, std.os.STDOUT_FILENO, uart_device_info);
    var rtc = Rtc.new(rtc_device_info);
    var virtio_block = try VirtioBlock.new(&vm, args.rootfs_path, true, &memory, virtio_block_device_info);

    mmio.add_device(Mmio.MmioDevice{ .Uart = &uart });
    mmio.add_device(Mmio.MmioDevice{ .Rtc = &rtc });
    mmio.add_device(Mmio.MmioDevice{ .VirtioBlock = &virtio_block });

    var cmdline = try CmdLine.new(allocator, 50);
    defer cmdline.deinit();

    try cmdline.append("console=ttyS0 reboot=k panic=1 pci=off");
    try virtio_block.add_to_cmdline(&cmdline);
    try uart.add_to_cmdline(&cmdline);

    const cmdline_0 = try cmdline.sentinel_str();
    std.log.info("cmdline: {s}", .{cmdline_0});

    const fdt_addr = fdt: {
        var fdt = try FDT.create_fdt(allocator, &memory, &.{vcpu_mpidr}, cmdline_0, &gicv2, uart_device_info, rtc_device_info, &.{virtio_block_device_info});
        defer fdt.deinit();

        const fdt_addr = try memory.load_fdt(&fdt);

        std.log.info("last_addr: 0x{x}", .{memory.last_addr()});
        std.log.info("fdt_addr: 0x{x}", .{fdt_addr});

        break :fdt fdt_addr;
    };

    try vcpu.set_reg(u64, Vcpu.REGS0, @as(u64, fdt_addr));
    try vcpu.set_reg(u64, Vcpu.PSTATE, Vcpu.PSTATE_FAULT_BITS_64);

    // const sig = try Vcpu.set_thread_handler();
    const t = try std.Thread.spawn(.{}, Vcpu.run_threaded, .{ &vcpu, &mmio });
    // Vcpu.kick_thread(&t, sig);

    const stdin = std.io.getStdIn();
    const state = configure_terminal(&stdin);
    const input_thread = try std.Thread.spawn(.{}, Uart.read_input_threaded, .{&uart});
    t.join();
    restore_terminal(&stdin, &state);

    _ = nix.pthread_kill(@intFromPtr(input_thread.impl.handle), nix.SIGINT);
    input_thread.join();
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
