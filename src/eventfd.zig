const std = @import("std");
const log = @import("log.zig");
const nix = @import("nix.zig");

fd: nix.fd_t,

const Self = @This();

pub const EventfdError = error{
    Create,
    Read,
    Write,
};

pub fn new(comptime System: type, init: u32, flags: u32) Self {
    const fd = nix.assert(@src(), System.eventfd, .{ init, flags });
    return Self{ .fd = fd };
}

pub fn deinit(self: *Self, comptime System: type) void {
    _ = nix.assert(System.close, .{self.fd});
}

pub fn read(self: *Self, comptime System: type) u64 {
    var buf: u64 = undefined;
    const buf_slice = std.mem.asBytes(&buf);
    const n = nix.assert(@src(), System.read, .{ self.fd, buf_slice });
    log.assert(
        @src(),
        n == @sizeOf(u64),
        "incorrect return size: {} != {}",
        .{ n, @as(usize, @sizeOf(u64)) },
    );
    return buf;
}

pub fn write(self: *Self, comptime System: type, val: u64) void {
    const buf_slice = std.mem.asBytes(&val);
    const n = nix.assert(@src(), System.write, .{ self.fd, buf_slice });
    log.assert(
        @src(),
        n == @sizeOf(u64),
        "incorrect return size: {} != {}",
        .{ n, @as(usize, @sizeOf(u64)) },
    );
}
