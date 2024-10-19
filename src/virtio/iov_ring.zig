const std = @import("std");
const nix = @import("../nix.zig");
const log = @import("../log.zig");

pub const MAX_IOVECS = std.mem.page_size / @sizeOf(nix.iovec);

const Self = @This();
iovecs: [*]nix.iovec,
start: u16,
len: u16,
capacity: u32,

pub fn init() !Self {
    const memfd = try nix.memfd_create("iov_ring", nix.FD_CLOEXEC);
    try nix.ftruncate(memfd, std.mem.page_size);
    const mem = try nix.mmap(
        null,
        std.mem.page_size * 2,
        nix.PROT.NONE,
        nix.MAP{
            .TYPE = .PRIVATE,
            .ANONYMOUS = true,
        },
        -1,
        0,
    );
    _ = try nix.mmap(
        mem.ptr,
        std.mem.page_size,
        nix.PROT.READ | nix.PROT.WRITE,
        nix.MAP{
            .TYPE = .SHARED,
            .FIXED = true,
        },
        memfd,
        0,
    );
    _ = try nix.mmap(
        mem.ptr + std.mem.page_size,
        std.mem.page_size,
        nix.PROT.READ | nix.PROT.WRITE,
        nix.MAP{
            .TYPE = .SHARED,
            .FIXED = true,
        },
        memfd,
        0,
    );
    return .{
        .iovecs = @ptrCast(mem.ptr),
        .start = 0,
        .len = 0,
        .capacity = 0,
    };
}

pub fn push_back(self: *Self, iovec: nix.iovec) void {
    log.assert(
        @src(),
        self.len != MAX_IOVECS,
        "overflow: self.len({}) == {}",
        .{ self.len, @as(u16, MAX_IOVECS) },
    );

    const index = self.start + self.len;
    self.iovecs[index] = iovec;
    self.len += 1;
    self.capacity += @intCast(iovec.len);
}

pub fn pop_front_n(self: *Self, n: u16) void {
    log.assert(
        @src(),
        n <= self.len,
        "underflow: n({}) <= self.len({})",
        .{ n, self.len },
    );

    for (self.slice()[0..n]) |*iovec| {
        self.capacity -= @intCast(iovec.len);
    }
    self.start += n;
    self.len -= n;
    if (MAX_IOVECS <= self.start) {
        self.start -= MAX_IOVECS;
    }
}

pub fn slice(self: *Self) []nix.iovec {
    return self.iovecs[self.start..(self.start + self.len)];
}

test "test_iov_ring_push_back" {
    var ir = try Self.init();
    try std.testing.expectEqual(ir.start, 0);
    try std.testing.expectEqual(ir.len, 0);
    try std.testing.expectEqual(ir.capacity, 0);

    for (0..256) |i| {
        ir.push_back(.{ .base = undefined, .len = 1 });
        try std.testing.expectEqual(ir.start, 0);
        try std.testing.expectEqual(ir.len, i + 1);
        try std.testing.expectEqual(ir.capacity, i + 1);
    }
    try std.testing.expectEqual(ir.start, 0);
    try std.testing.expectEqual(ir.len, 256);
    try std.testing.expectEqual(ir.capacity, 256);
}

test "test_iov_ring_pop_front_n" {
    var ir = try Self.init();

    for (0..256) |_| {
        ir.push_back(.{ .base = undefined, .len = 1 });
    }

    ir.pop_front_n(128);
    try std.testing.expectEqual(ir.start, 128);
    try std.testing.expectEqual(ir.len, 128);
    try std.testing.expectEqual(ir.capacity, 128);

    ir.pop_front_n(128);
    try std.testing.expectEqual(ir.start, 0);
    try std.testing.expectEqual(ir.len, 0);
    try std.testing.expectEqual(ir.capacity, 0);
}

test "test_iov_ring_slice" {
    var ir = try Self.init();

    for (0..128) |_| {
        ir.push_back(.{ .base = undefined, .len = 1 });
    }
    ir.pop_front_n(128);
    try std.testing.expectEqual(ir.start, 128);
    try std.testing.expectEqual(ir.len, 0);
    try std.testing.expectEqual(ir.capacity, 0);

    for (0..256) |_| {
        ir.push_back(.{ .base = undefined, .len = 1 });
    }
    try std.testing.expectEqual(ir.start, 128);
    try std.testing.expectEqual(ir.len, 256);
    try std.testing.expectEqual(ir.capacity, 256);

    {
        const expected_slice = [_]nix.iovec{
            .{ .base = undefined, .len = 1 },
        } ** 256;
        try std.testing.expectEqualSlices(nix.iovec, &expected_slice, ir.slice());
    }

    ir.pop_front_n(128);
    {
        const expected_slice = [_]nix.iovec{
            .{ .base = undefined, .len = 1 },
        } ** 128;
        try std.testing.expectEqualSlices(nix.iovec, &expected_slice, ir.slice());
    }
}
