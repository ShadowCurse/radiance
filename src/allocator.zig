const std = @import("std");
const nix = @import("nix.zig");

pub const TmpMemory = struct {
    inner: std.heap.ArenaAllocator,

    const Self = @This();

    pub fn init() Self {
        return .{
            .inner = std.heap.ArenaAllocator.init(std.heap.page_allocator),
        };
    }

    pub fn deinit(self: *const Self) void {
        self.inner.deinit();
    }

    pub fn allocator(self: *Self) std.mem.Allocator {
        return self.inner.allocator();
    }

    pub fn used_capacity(self: *const Self) usize {
        return self.inner.queryCapacity();
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
