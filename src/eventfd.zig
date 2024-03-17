const std = @import("std");
const nix = @import("nix.zig");

fd: std.os.fd_t,

const Self = @This();

pub const EventfdError = error{
    Create,
    Read,
    Write,
};

pub fn new(init: u32, flags: i32) !Self {
    const fd = nix.eventfd(init, flags);
    if (fd < 0) {
        return EventfdError.Create;
    }
    return Self{ .fd = fd };
}

pub fn deinit(self: *Self) void {
    _ = nix.close(self.fd);
}

pub fn read(self: *Self) !u64 {
    var buf: u64 = undefined;
    const buf_slice = std.mem.asBytes(&buf);
    if (nix.read(self.fd, buf_slice.ptr, buf_slice.len) < 0) {
        return EventfdError.Read;
    } else {
        return buf;
    }
}

pub fn write(self: *Self, val: u64) !void {
    const buf_slice = std.mem.asBytes(&val);
    if (nix.write(self.fd, buf_slice.ptr, buf_slice.len) < 0) {
        return EventfdError.Write;
    }
}
