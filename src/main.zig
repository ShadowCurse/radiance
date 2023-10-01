const std = @import("std");

const Uart = @import("devices/uart.zig");
const Rtc = @import("devices/rtc.zig");
const CacheDir = @import("cache.zig").CacheDir;
const CmdLine = @import("cmdline.zig");
const FDT = @import("fdt.zig");
const Gicv2 = @import("gicv2.zig");
const Kvm = @import("kvm.zig");
const GuestMemory = @import("memory.zig").GuestMemory;
const MMIO = @import("mmio.zig");
const Mmio = MMIO.Mmio;
const MmioDevice = MMIO.MmioDevice;
const Vcpu = @import("vcpu.zig");
const Vm = @import("vm.zig");

pub const log_level: std.log.Level = .debug;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // @import("log.zig").info(@src(), "{} and {s} and {x}", .{ 69, "lol", 0x69 });

    // create guest memory (128 MB)
    var gm = try GuestMemory.init(128 << 20);
    defer gm.deinit();
    const kernel_load_address = try gm.load_linux_kernel("vmlinux-5.10.186");
    std.log.info("kernel_load_address: 0x{x}", .{kernel_load_address});

    // create kvm context
    const kvm = try Kvm.new();

    const version = try kvm.version();
    std.log.info("kvm version: {}", .{version});

    // create vm
    const vm = try Vm.new(&kvm);
    try vm.set_memory(&gm);

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

    var uart = Uart.new(std.os.STDIN_FILENO, std.os.STDOUT_FILENO, uart_device_info);
    var rtc = Rtc.new(rtc_device_info);

    mmio.add_device(MmioDevice{ .Uart = &uart });
    mmio.add_device(MmioDevice{ .Rtc = &rtc });

    var cmdline = try CmdLine.new(allocator, 50);
    defer cmdline.deinit();

    try cmdline.append("console=ttyS0 reboot=k panic=1 pci=off");
    try uart.add_to_cmdline(&cmdline);

    const cmdline_0 = try cmdline.sentinel_str();
    std.log.info("cmdline: {s}", .{cmdline_0});

    var fdt = try FDT.create_fdt(allocator, &gm, &.{vcpu_mpidr}, cmdline_0, &gicv2, uart_device_info);
    defer fdt.deinit();

    const fdt_addr = try gm.load_fdt(&fdt);
    std.log.info("last_addr: 0x{x}", .{gm.last_addr()});
    std.log.info("fdt_addr: 0x{x}", .{fdt_addr});
    try vcpu.set_reg(u64, Vcpu.REGS0, @as(u64, fdt_addr));
    try vcpu.set_reg(u64, Vcpu.PSTATE, Vcpu.PSTATE_FAULT_BITS_64);

    std.log.info("fdt built", .{});

    const sig = try Vcpu.set_thread_handler();
    const t = try std.Thread.spawn(.{}, Vcpu.run_threaded, .{ &vcpu, &mmio });

    std.log.info("sleeping...", .{});
    // 1 second
    std.time.sleep(1 * 1000_000_000);
    Vcpu.kick_thread(&t, sig);
    std.log.info("immediate_exit set", .{});

    t.join();
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
