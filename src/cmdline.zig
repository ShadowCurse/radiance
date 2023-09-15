const std = @import("std");
const Allocator = std.mem.Allocator;

pub const CmdLine = struct {
    allocator: Allocator,
    mem: []u8,
    len: usize,

    const Self = @This();

    pub fn new(allocator: Allocator, size: usize) !Self {
        const mem = try allocator.alloc(u8, size);
        return Self{ .allocator = allocator, .mem = mem, .len = 0 };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.mem);
    }

    pub fn append(self: *Self, s: []const u8) !void {
        if (self.mem.len <= self.len + s.len) {
            try self.reallocate(self.mem.len * 2);
        }
        @memcpy(self.mem[self.len .. self.len + s.len], s);
        self.len += s.len;
    }

    pub fn sentinel_str(self: *Self) ![:0]u8 {
        if (self.mem.len == self.len) {
            try self.reallocate(self.mem.len + 1);
        }
        self.mem[self.len] = 0;
        return self.mem[0..self.len :0];
    }

    fn reallocate(self: *Self, new_size: usize) !void {
        self.mem = try self.allocator.realloc(self.mem, new_size);
    }
};
