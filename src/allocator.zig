const std = @import("std");
const nix = @import("nix.zig");

const Memory = @import("memory.zig");

pub const GuestMemory = struct {
    inner: std.heap.FixedBufferAllocator,

    const Self = @This();

    pub fn init(memory: *const Memory, kernel_size: u64) Self {
        const start = ((kernel_size / std.mem.page_size) + 1) * std.mem.page_size;
        return .{
            .inner = std.heap.FixedBufferAllocator.init(memory.mem[start..]),
        };
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return self.inner.allocator();
    }
};

pub const PermanentMemory = struct {
    inner: std.heap.FixedBufferAllocator,

    const Self = @This();

    pub fn init(size: usize) !Self {
        const prot = nix.PROT.READ | nix.PROT.WRITE;
        const flags = nix.MAP{
            .TYPE = .PRIVATE,
            .ANONYMOUS = true,
            .NORESERVE = true,
        };
        const mem = try nix.mmap(null, size, prot, flags, -1, 0);
        return .{
            .inner = std.heap.FixedBufferAllocator.init(mem),
        };
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return self.inner.allocator();
    }
};
