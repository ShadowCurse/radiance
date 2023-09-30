const std = @import("std");

const nix = @import("nix.zig");

const FdtBuilder = @import("fdt.zig").FdtBuilder;

pub const MemoryError = error{
    InvalidMagicNumber,
    NotAllignedKernelOffset,
};

pub const MemoryLayout = struct {
    /// Start of RAM on 64 bit ARM.
    pub const DRAM_MEM_START: u64 = 0x8000_0000; // 2 GB.
    /// The maximum RAM size.
    pub const DRAM_MEM_MAX_SIZE: u64 = 0x00FF_8000_0000; // 1024 - 2 = 1022G.
    /// Below this address will reside the GIC, above this address will reside the MMIO devices.
    pub const MAPPED_IO_START: u64 = 1 << 30; // 1 GB
};

pub const GuestMemory = struct {
    guest_addr: u64,
    kernel_end: usize,
    mem: []align(std.mem.page_size) u8,

    const Self = @This();

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

    pub fn init(size: usize) !Self {
        const prot = nix.PROT.READ | nix.PROT.WRITE;
        const flags = nix.MAP.PRIVATE | nix.MAP.ANONYMOUS | 0x4000; //std.os.system.MAP.NORESERVE;
        const mem = try std.os.mmap(null, size, prot, flags, -1, 0);

        std.log.debug("mem size: 0x{x}", .{size});
        std.log.debug("guest_addr: 0x{x}", .{MemoryLayout.DRAM_MEM_START});

        return Self{ .guest_addr = MemoryLayout.DRAM_MEM_START, .kernel_end = 0, .mem = mem };
    }

    pub fn deinit(self: *const Self) void {
        std.os.munmap(self.mem);
    }

    pub fn last_addr(self: *const Self) u64 {
        return self.guest_addr + self.mem.len - 1;
    }

    pub fn load_linux_kernel(self: *Self, path: []const u8) !u64 {
        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const file_meta = try file.metadata();
        const kernel_size = file_meta.size();
        std.log.debug("kernel_size: 0x{x}", .{kernel_size});

        try file.seekTo(0);

        var arm64_header: arm64_image_header = undefined;
        var header_slice = std.mem.asBytes(&arm64_header);
        const n = try file.read(@as([]u8, header_slice));
        std.debug.assert(n == header_slice.len);

        std.log.debug("header: {any}", .{arm64_header});

        if (arm64_header.magic != 0x644d_5241) {
            return MemoryError.InvalidMagicNumber;
        }

        var text_offset = arm64_header.text_offset;
        if (arm64_header.image_size == 0) {
            text_offset = 0x80000;
        }
        std.log.debug("text_offset: 0x{x}", .{text_offset});

        const kernel_offset = MemoryLayout.DRAM_MEM_START;
        std.log.debug("kernel_offset: 0x{x}", .{kernel_offset});

        // Validate that kernel_offset is 2 MB aligned, as required by the
        // arm64 boot protocol
        if (kernel_offset % 0x0020_0000 != 0) {
            return MemoryError.NotAllignedKernelOffset;
        }

        const mem_offset = kernel_offset + text_offset;
        const kernel_end = mem_offset + kernel_size;
        std.log.debug("mem_offset: 0x{x}", .{mem_offset});
        std.log.debug("kernel_end: 0x{x}", .{kernel_end});

        try file.seekTo(0);

        _ = try file.read(self.mem[0..kernel_size]);

        self.kernel_end = kernel_size;

        return mem_offset;
    }

    pub fn load_fdt(self: *Self, fdt: *const FdtBuilder) !u64 {
        const fdt_addr = FdtBuilder.fdt_addr(self.last_addr());
        @memcpy(self.mem[fdt_addr - self.guest_addr .. fdt_addr - self.guest_addr + fdt.data.items.len], fdt.data.items[0..fdt.data.items.len]);
        return fdt_addr;
    }
};
