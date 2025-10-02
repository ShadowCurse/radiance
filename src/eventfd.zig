const std = @import("std");
const log = @import("log.zig");
const nix = @import("nix.zig");

fd: nix.fd_t,

const Self = @This();

pub fn new(comptime System: type, init: u32, flags: u32) Self {
    const fd = nix.assert(@src(), System, "eventfd", .{ init, flags });
    return Self{ .fd = fd };
}

pub fn read(self: *const Self, comptime System: type) u64 {
    var buf: u64 = undefined;
    const buf_slice: []u8 = @ptrCast(&buf);
    const n = nix.assert(@src(), System, "read", .{ self.fd, buf_slice });
    log.assert(
        @src(),
        n == @sizeOf(u64),
        "incorrect return size: {} != {}",
        .{ n, @as(usize, @sizeOf(u64)) },
    );
    return buf;
}

pub fn write(self: *const Self, comptime System: type, val: u64) void {
    const buf_slice: []const u8 = @ptrCast(&val);
    const n = nix.assert(@src(), System, "write", .{ self.fd, buf_slice });
    log.assert(
        @src(),
        n == @sizeOf(u64),
        "incorrect return size: {} != {}",
        .{ n, @as(usize, @sizeOf(u64)) },
    );
}
