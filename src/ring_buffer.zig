const std = @import("std");
const nix = @import("nix.zig");
const log = @import("log.zig");

pub fn RingBuffer(comptime T: type, comptime SIZE: u32) type {
    return struct {
        const Self = @This();
        items: [SIZE]T = undefined,
        start: u32 = 0,
        len: u32 = 0,

        pub const empty: Self = .{
            .items = undefined,
            .start = 0,
            .len = 0,
        };

        pub fn first(self: *const Self) *const T {
            log.assert(@src(), self.len != 0, "empty", .{});
            return &self.items[self.start];
        }

        pub fn remaining_len(self: *const Self) u32 {
            return SIZE - self.len;
        }

        pub fn push_back(self: *Self, item: T) void {
            log.assert(
                @src(),
                self.len != SIZE,
                "overflow: self.len({}) == {}",
                .{ self.len, @as(u32, SIZE) },
            );

            const index = (self.start + self.len) % SIZE;
            self.items[index] = item;
            self.len += 1;
        }

        pub fn push_back_slice(self: *Self, slice: []const T) void {
            for (slice) |e| self.push_back(e);
        }

        pub fn pop_front(self: *Self) ?T {
            if (self.len == 0) {
                return null;
            } else {
                const index = self.start;
                self.start += 1;
                self.start %= SIZE;
                self.len -= 1;
                return self.items[index];
            }
        }
    };
}

test "test_ring_buffer_push" {
    var rb: RingBuffer(usize, 256) = .empty;

    for (0..256) |i| rb.push_back(i);
    try std.testing.expectEqual(rb.start, 0);
    try std.testing.expectEqual(rb.len, 256);
}

test "test_ring_buffer_pop_front" {
    var rb: RingBuffer(usize, 256) = .empty;

    for (0..256) |i| rb.push_back(i);
    try std.testing.expectEqual(rb.start, 0);
    try std.testing.expectEqual(rb.len, 256);

    for (0..128) |i| try std.testing.expectEqual(rb.pop_front().?, i);
    try std.testing.expectEqual(rb.start, 128);
    try std.testing.expectEqual(rb.len, 128);

    for (0..128) |i| try std.testing.expectEqual(rb.pop_front().?, 128 + i);
    try std.testing.expectEqual(rb.pop_front(), null);
    try std.testing.expectEqual(rb.start, 0);
    try std.testing.expectEqual(rb.len, 0);
}
