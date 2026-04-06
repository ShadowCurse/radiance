const nix = @import("nix.zig");

fd: nix.fd_t,

const Self = @This();

pub fn init(comptime System: type) Self {
    return .{
        .fd = nix.assert(@src(), System, "open", .{ "/dev/kvm", .{}, 0 }),
    };
}

pub fn vcpu_mmap_size(self: *const Self, comptime System: type) u32 {
    const size = nix.assert(@src(), System, "ioctl", .{
        self.fd,
        nix.KVM_GET_VCPU_MMAP_SIZE,
        @as(u32, 0),
    });
    return @intCast(size);
}

pub fn supported_cpuid(self: *const Self) nix.kvm_cpuid2.with_entries(nix.KVM_MAX_CPUID_ENTRIES) {
    var result: nix.kvm_cpuid2.with_entries(nix.KVM_MAX_CPUID_ENTRIES) = .{};
    _ = nix.assert(@src(), nix.System, "ioctl", .{
        self.fd,
        nix.KVM_GET_SUPPORTED_CPUID,
        @intFromPtr(&result),
    });
    return result;
}
