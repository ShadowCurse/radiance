const nix = @import("nix.zig");

fd: nix.fd_t,

const Self = @This();

pub fn new() Self {
    return .{
        .fd = nix.assert(@src(), nix.open, .{ "/dev/kvm", .{}, 0 }),
    };
}

pub fn vcpu_mmap_size(self: *const Self) u32 {
    const size = nix.assert(@src(), nix.ioctl, .{
        self.fd,
        nix.KVM_GET_VCPU_MMAP_SIZE,
        @as(u32, 0),
    });
    return @intCast(size);
}
