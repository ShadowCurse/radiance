const std = @import("std");
const nix = @import("nix.zig");

fd: nix.fd_t,

const Self = @This();

pub const EventfdError = error{
    Create,
    Read,
    Write,
};

pub fn new(init: u32, flags: u32) !Self {
    const fd = try nix.eventfd(init, flags);
    return Self{ .fd = fd };
}

pub fn deinit(self: *Self) void {
    _ = nix.close(self.fd);
}

pub fn read(self: *Self) !u64 {
    var buf: u64 = undefined;
    const buf_slice = std.mem.asBytes(&buf);
    const n = try nix.read(self.fd, buf_slice);
    if (n != @sizeOf(u64)) {
        return EventfdError.Read;
    } else {
        return buf;
    }
}

pub fn write(self: *Self, val: u64) !void {
    const buf_slice = std.mem.asBytes(&val);
    const n = try nix.write(self.fd, buf_slice);
    if (n != @sizeOf(u64)) {
        return EventfdError.Write;
    }
}
