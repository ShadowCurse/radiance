const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;

const KVM = @cImport(@cInclude("linux/kvm.h"));

const GICv2 = @import("gicv2.zig").GICv2;
const Kvm = @import("kvm.zig").Kvm;
const GuestMemory = @import("memory.zig").GuestMemory;
const Vcpu = @import("vcpu.zig").Vcpu;
const Vm = @import("vm.zig").Vm;

// ioctl in std uses c_int as a request type which is incorrect.
pub extern "c" fn ioctl(fd: std.os.fd_t, request: c_ulong, ...) c_int;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    _ = allocator;

    // create guest memory (128 MB)
    var gm = try GuestMemory.init(128 << 20);
    defer gm.deinit();
    const kernel_load_address = try gm.load_linux_kernel("vmlinux-5.10.186");
    std.log.info("kernel_load_address: {}", .{kernel_load_address});

    // create kvm context
    const kvm = try Kvm.new();

    const version = try kvm.version();
    std.log.info("kvm version: {}", .{version});

    // create vm
    const vm = try Vm.new(&kvm);
    try vm.set_memory(&gm);

    // create vcpu
    const vcpu = try Vcpu.new(&vm, 0);
    const kvi = try vm.get_preferred_target();
    try vcpu.init(kvi);
    try vcpu.set_pc(kernel_load_address);

    const gicv2 = try GICv2.new(&vm);
    _ = gicv2;
}

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
