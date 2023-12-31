const std = @import("std");
const log = @import("log.zig");
const nix = @import("nix.zig");

const FdtBuilder = @import("fdt.zig").FdtBuilder;

/// Start of RAM on 64 bit ARM.
pub const DRAM_START: u64 = 0x8000_0000; // 2 GB.
/// GIC is bellow, MMIO devices are here.
pub const MMIO_START: u64 = 0x4000_0000; // 1 GB

pub const MemoryError = error{
    InvalidMagicNumber,
    NotAllignedKernelOffset,
};

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
mem: []align(std.mem.page_size) u8,

const Self = @This();

pub fn init(size: usize) !Self {
    const prot = nix.PROT.READ | nix.PROT.WRITE;
    const flags = nix.MAP.PRIVATE | nix.MAP.ANONYMOUS | 0x4000; //std.os.system.MAP.NORESERVE;
    const mem = try std.os.mmap(null, size, prot, flags, -1, 0);

    log.debug(@src(), "mem size: 0x{x}", .{size});
    log.debug(@src(), "guest_addr: 0x{x}", .{DRAM_START});

    return Self{ .guest_addr = DRAM_START, .mem = mem };
}

pub fn deinit(self: *const Self) void {
    std.os.munmap(self.mem);
}

pub fn get_ptr(self: *const Self, comptime T: type, addr: u64) *T {
    const offset = addr - self.guest_addr;
    return @ptrFromInt(@as(u64, @intFromPtr(self.mem.ptr)) + offset);
}

pub fn last_addr(self: *const Self) u64 {
    return self.guest_addr + self.mem.len - 1;
}

/// Loads the linux kernel into the memory.
/// Returns the guest memory address where
/// the executable code starts.
pub fn load_linux_kernel(self: *Self, path: []const u8) !u64 {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const file_meta = try file.metadata();
    const kernel_size = file_meta.size();
    log.debug(@src(), "kernel_size: 0x{x}", .{kernel_size});

    try file.seekTo(0);

    var arm64_header: arm64_image_header = undefined;
    var header_slice = std.mem.asBytes(&arm64_header);
    const n = try file.read(@as([]u8, header_slice));
    std.debug.assert(n == header_slice.len);

    log.debug(@src(), "header: {any}", .{arm64_header});

    if (arm64_header.magic != 0x644d_5241) {
        return MemoryError.InvalidMagicNumber;
    }

    var text_offset = arm64_header.text_offset;
    if (arm64_header.image_size == 0) {
        text_offset = 0x80000;
    }
    log.debug(@src(), "text_offset: 0x{x}", .{text_offset});

    try file.seekTo(0);
    _ = try file.read(self.mem[0..kernel_size]);

    return DRAM_START + text_offset;
}

/// Loads fdt at the end of the memory.
pub fn load_fdt(self: *Self, fdt: *const FdtBuilder) !u64 {
    const fdt_addr = FdtBuilder.fdt_addr(self.last_addr());
    const memory_fdt_start = fdt_addr - self.guest_addr;
    const memory_fdt_end = memory_fdt_start + fdt.data.items.len;
    @memcpy(self.mem[memory_fdt_start..memory_fdt_end], fdt.data.items[0..fdt.data.items.len]);
    return fdt_addr;
}
