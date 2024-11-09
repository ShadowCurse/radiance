const std = @import("std");
const log = @import("log.zig");
const Kvm = @import("kvm.zig");
const Memory = @import("memory.zig");

const nix = nix: {
    const real_nix = @import("nix.zig");
    if (!@import("builtin").is_test) {
        break :nix real_nix;
    } else {
        break :nix TestNix(real_nix);
    }
};

fd: nix.fd_t,

const Self = @This();

pub const VmError = error{
    New,
    SetMemory,
    GetPreferredTarget,
    CreateDevice,
};

pub fn new(kvm: *const Kvm) !Self {
    const fd = try nix.checked_ioctl(
        @src(),
        VmError.New,
        kvm.fd,
        nix.KVM_CREATE_VM,
        @as(usize, 0),
    );
    return Self{
        .fd = fd,
    };
}

pub fn set_memory(self: *const Self, memory: *const Memory) !void {
    const memory_region: nix.kvm_userspace_memory_region = .{
        .slot = 0,
        .flags = 0,
        .guest_phys_addr = memory.guest_addr,
        .memory_size = @as(u64, memory.mem.len),
        .userspace_addr = @intFromPtr(memory.mem.ptr),
    };

    log.debug(@src(), "set_memory slot: {}", .{memory_region.slot});
    log.debug(@src(), "set_memory flags: {}", .{memory_region.flags});
    log.debug(@src(), "set_memory guest_phys_addr: 0x{x}", .{memory_region.guest_phys_addr});
    log.debug(@src(), "set_memory memory_size: 0x{x}", .{memory_region.memory_size});
    log.debug(@src(), "set_memory userspace_addr: 0x{x}", .{memory_region.userspace_addr});

    _ = try nix.checked_ioctl(
        @src(),
        VmError.SetMemory,
        self.fd,
        nix.KVM_SET_USER_MEMORY_REGION,
        @intFromPtr(&memory_region),
    );
}

pub fn get_preferred_target(self: *const Self) !nix.kvm_vcpu_init {
    var kvi: nix.kvm_vcpu_init = undefined;
    _ = try nix.checked_ioctl(
        @src(),
        VmError.GetPreferredTarget,
        self.fd,
        nix.KVM_ARM_PREFERRED_TARGET,
        @intFromPtr(&kvi),
    );
    return kvi;
}

fn TestNix(comptime real_nix: type) type {
    return struct {
        const KVM_CREATE_VM = real_nix.KVM_CREATE_VM;
        const KVM_ARM_PREFERRED_TARGET = real_nix.KVM_ARM_PREFERRED_TARGET;
        const KVM_SET_USER_MEMORY_REGION = real_nix.KVM_SET_USER_MEMORY_REGION;
        const fd_t = real_nix.fd_t;
        const kvm_vcpu_init = real_nix.kvm_vcpu_init;
        const kvm_userspace_memory_region = real_nix.kvm_userspace_memory_region;
        pub fn checked_ioctl(
            _: std.builtin.SourceLocation,
            _: anyerror,
            fd: fd_t,
            request: c_ulong,
            _: anytype,
        ) E!c_int {
            last_ioctl_fd = fd;
            last_ioctl_request = request;
            return checked_ioctl_return;
        }

        pub const E = error{
            CHECKED_IOCTL_ERR,
        };

        var checked_ioctl_return: E!c_int = E.CHECKED_IOCTL_ERR;

        var last_ioctl_fd: fd_t = 0;
        var last_ioctl_request: c_ulong = 0;
    };
}

test "test_vcpu_new" {
    nix.checked_ioctl_return = 5;

    var kvm: Kvm = undefined;
    kvm.file.handle = 69;
    const vm = Self.new(&kvm) catch unreachable;

    try std.testing.expect(vm.fd == 5);
    try std.testing.expect(nix.last_ioctl_fd == 69);
    try std.testing.expect(nix.last_ioctl_request == nix.KVM_CREATE_VM);
}

test "test_vcpu_new_err" {
    nix.checked_ioctl_return = nix.E.CHECKED_IOCTL_ERR;

    var kvm: Kvm = undefined;
    kvm.file.handle = 69;
    try std.testing.expectError(nix.E.CHECKED_IOCTL_ERR, Self.new(&kvm));
}
