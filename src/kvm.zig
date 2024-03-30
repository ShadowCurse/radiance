const std = @import("std");
const nix = @import("nix.zig");

file: std.fs.File,

const Self = @This();

pub const KvmError = error{
    KvmVersion,
};

pub fn new() !Self {
    return .{ .file = try std.fs.openFileAbsolute("/dev/kvm", .{}) };
}

pub fn version(self: *const Self) !i32 {
    return try nix.checked_ioctl(@src(), KvmError.KvmVersion, self.file.handle, nix.KVM_GET_API_VERSION, @as(usize, 0));
    // const v = std.c.ioctl(self.file.handle, nix.KVM_GET_API_VERSION, @as(usize, 0));
    // if (v < 0) {
    //     return KvmError.KvmVersion;
    // } else {
    //     return v;
    // }
}
