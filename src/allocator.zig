const std = @import("std");
const nix = @import("nix.zig");

const Memory = @import("memory.zig");

pub const GuestMemory = struct {
    inner: std.heap.FixedBufferAllocator,

    const Self = @This();

    pub fn init(memory: *const Memory, kernel_size: u64) Self {
        const start = ((kernel_size / Memory.HOST_PAGE_SIZE) + 1) * Memory.HOST_PAGE_SIZE;
        return .{
            .inner = .init(memory.mem[start..]),
        };
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return self.inner.allocator();
    }
};
