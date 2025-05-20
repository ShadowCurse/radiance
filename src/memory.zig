const std = @import("std");
const log = @import("log.zig");
const nix = @import("nix.zig");

pub const GUEST_PAGE_SIZE = 0x1000;
pub const HOST_PAGE_SIZE = std.heap.page_size_min;

/// Start of RAM on 64 bit ARM.
pub const DRAM_START: u64 = 0x8000_0000; // 2 GB.
/// GIC is bellow, MMIO devices are here.
pub const MMIO_START: u64 = 0x4000_0000; // 1 GB

const arm64_image_header = packed struct {
    code0: u32,
    code1: u32,
    text_offset: u64,
    image_size: u64,
    flags: u64,
    res2: u64,
    res3: u64,
    res4: u64,
    magic: u32,
    res5: u32,
};

guest_addr: u64,
mem: []align(HOST_PAGE_SIZE) u8,

const Self = @This();

pub fn init(comptime System: type, size: usize) Self {
    const prot = nix.PROT.READ | nix.PROT.WRITE;
    const flags = nix.MAP{
        .TYPE = .PRIVATE,
        .ANONYMOUS = true,
        .NORESERVE = true,
    };
    const mem = nix.assert(@src(), System, "mmap", .{
        null,
        size,
        prot,
        flags,
        -1,
        0,
    });

    log.debug(@src(), "mem size: 0x{x}", .{size});
    log.debug(@src(), "guest_addr: 0x{x}", .{DRAM_START});

    return Self{ .guest_addr = DRAM_START, .mem = mem };
}

pub fn get_ptr(self: *const Self, comptime T: type, addr: u64) *volatile T {
    const offset = addr - self.guest_addr;
    const end_of_type = offset + @sizeOf(T);
    log.assert(
        @src(),
        end_of_type <= self.mem.len,
        "Guest memory type access reaches beyond the end of the RAM: {} <= {}",
        .{ self.mem.len, end_of_type },
    );
    return @ptrFromInt(@as(u64, @intFromPtr(self.mem.ptr)) + offset);
}

pub fn get_slice(self: *const Self, comptime T: type, len: u64, addr: u64) []volatile T {
    const offset = addr - self.guest_addr;
    const end_of_slice = offset + @sizeOf(T) * len;
    log.assert(
        @src(),
        end_of_slice <= self.mem.len,
        "Guest memory slice access reaches beyond the end of the RAM: {} <= {}",
        .{ self.mem.len, end_of_slice },
    );
    var slice: []T = undefined;
    slice.ptr = @ptrFromInt(@as(u64, @intFromPtr(self.mem.ptr)) + offset);
    slice.len = len;
    return slice;
}

pub fn last_addr(self: *const Self) u64 {
    return self.guest_addr + self.mem.len - 1;
}

pub fn align_addr(addr: u64, align_to: u64) u64 {
    return (addr + align_to) & ~(align_to - 1);
}

pub fn is_aligned(addr: u64, align_to: u64) bool {
    return (addr & (align_to - 1)) == 0;
}

/// Loads the linux kernel into the memory.
/// Returns the guest memory address where
/// the executable code starts and a size of the kernel.
/// https://github.com/torvalds/linux/blob/master/Documentation/arch/arm64/booting.rst
pub const LoadResult = struct {
    start: u64,
    size: u64,
};
pub fn load_linux_kernel(self: *Self, comptime System: type, path: []const u8) LoadResult {
    const fd = nix.assert(@src(), System, "open", .{
        path,
        .{
            .CLOEXEC = true,
            .ACCMODE = .RDONLY,
        },
        0,
    });
    const meta = nix.assert(@src(), System, "statx", .{fd});

    const prot = nix.PROT.READ | nix.PROT.WRITE;
    const flags = nix.MAP{
        .TYPE = .PRIVATE,
        .FIXED = true,
        .NORESERVE = true,
    };
    const file_mem = nix.assert(@src(), System, "mmap", .{
        self.mem.ptr,
        meta.size,
        prot,
        flags,
        fd,
        0,
    });

    const arm64_header: *arm64_image_header = @ptrCast(file_mem.ptr);
    log.assert(
        @src(),
        arm64_header.magic == 0x644d_5241,
        "Kernel magic value is invalid: {} != {}",
        .{ arm64_header.magic, @as(u32, 0x644d_5241) },
    );

    var text_offset = arm64_header.text_offset;
    if (arm64_header.image_size == 0) {
        text_offset = 0x80000;
    }

    return .{ .start = DRAM_START + text_offset, .size = meta.size };
}
