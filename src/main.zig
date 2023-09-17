const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;

const KVM = @cImport(@cInclude("linux/kvm.h"));

const Serial = @import("devices/serial.zig").Serial;
const CacheDir = @import("cache.zig").CacheDir;
const CmdLine = @import("cmdline.zig").CmdLine;
const FDT = @import("fdt.zig");
const GICv2 = @import("gicv2.zig").GICv2;
const Kvm = @import("kvm.zig").Kvm;
const GuestMemory = @import("memory.zig").GuestMemory;
const Mmio = @import("mmio.zig").Mmio;
const VCPU = @import("vcpu.zig");
const Vcpu = VCPU.Vcpu;
const set_thread_handler = VCPU.set_thread_handler;
const kick_thread = VCPU.kick_thread;
const Vm = @import("vm.zig").Vm;

// ioctl in std uses c_int as a request type which is incorrect.
pub extern "c" fn ioctl(fd: std.os.fd_t, request: c_ulong, ...) c_int;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // create guest memory (128 MB)
    var gm = try GuestMemory.init(128 << 20);
    defer gm.deinit();
    const kernel_load_address = try gm.load_linux_kernel("vmlinux-5.10.186");
    std.log.info("kernel_load_address: 0x{x}", .{kernel_load_address});
    // for (0..10) |i| {
    //     std.log.info("kernel {}: 0x{x}", .{ i, gm.mem[i] });
    // }

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

    const gicv2 = try GICv2.new(&vm);

    var mmio = Mmio.new();
    const serial_device_info = mmio.allocate();

    const serial = Serial.new(std.os.STDIN_FILENO, std.os.STDOUT_FILENO, serial_device_info);
    // const block = try Block.new();

    var cmdline = try CmdLine.new(allocator, 50);
    defer cmdline.deinit();

    try cmdline.append("console=ttyS0 reboot=k panic=1 pci=off");
    try serial.add_to_cmdline(&cmdline);

    const cmdline_0 = try cmdline.sentinel_str();
    std.log.info("cmdline: {s}", .{cmdline_0});

    var fdt = try FDT.create_fdt(allocator, &gm, &.{vcpu_mpidr}, cmdline_0, &gicv2, serial_device_info);
    defer fdt.deinit();

    const fdt_addr = try gm.load_fdt(&fdt);
    std.log.info("last_addr: 0x{x}", .{gm.last_addr()});
    std.log.info("fdt_addr: 0x{x}", .{fdt_addr});
    try vcpu.set_reg(u64, Vcpu.REGS0, @as(u64, fdt_addr));
    try vcpu.set_reg(u64, Vcpu.PSTATE, Vcpu.PSTATE_FAULT_BITS_64);

    std.log.info("fdt built", .{});

    const sig = try set_thread_handler();
    const t = try std.Thread.spawn(.{}, Vcpu.run_threaded, .{&vcpu});

    std.log.info("sleeping...", .{});
    // 5 seconds
    std.time.sleep(5 * 1000_000_000);
    kick_thread(&t, sig);
    std.log.info("immediate_exit set", .{});

    t.join();
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
