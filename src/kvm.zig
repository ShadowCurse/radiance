const nix = @import("nix.zig");

fd: nix.fd_t,

const Self = @This();

pub fn new() !Self {
    return .{
        .fd = try nix.open("/dev/kvm", .{}, 0),
    };
}
