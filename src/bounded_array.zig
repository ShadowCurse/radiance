const log = @import("log.zig");

pub fn BoundedArray(comptime T: type, comptime SIZE: u32) type {
    return struct {
        const Self = @This();
        items: [SIZE]T = undefined,
        len: u32 = 0,

        pub const empty: Self = .{
            .items = undefined,
            .len = 0,
        };

        pub fn append(self: *Self, item: T) void {
            log.assert(
                @src(),
                self.len != SIZE,
                "overflow: self.len({}) == {}",
                .{ self.len, SIZE },
            );
            self.items[self.len] = item;
            self.len += 1;
        }

        pub fn full(self: *const Self) bool {
            return self.len == SIZE;
        }

        pub fn slice_const(self: *const Self) []const T {
            return self.items[0..self.len];
        }

        pub fn reset(self: *Self) void {
            self.len = 0;
        }
    };
}
