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

pub fn new(init: u32, flags: u32) Self {
    const fd = nix.assert(@src(), nix.eventfd, .{ init, flags });
    return Self{ .fd = fd };
}

pub fn deinit(self: *Self) void {
    _ = nix.assert(nix.close, .{self.fd});
}

pub fn read(self: *Self) u64 {
    var buf: u64 = undefined;
    const buf_slice = std.mem.asBytes(&buf);
    const n = nix.assert(@src(), nix.read, .{ self.fd, buf_slice });
    log.assert(
        @src(),
        n == @sizeOf(u64),
        "incorrect return size: {} != {}",
        .{ n, @as(usize, @sizeOf(u64)) },
    );
    return buf;
}

pub fn write(self: *Self, val: u64) void {
    const buf_slice = std.mem.asBytes(&val);
    const n = nix.assert(@src(), nix.write, .{ self.fd, buf_slice });
    log.assert(
        @src(),
        n == @sizeOf(u64),
        "incorrect return size: {} != {}",
        .{ n, @as(usize, @sizeOf(u64)) },
    );
}
