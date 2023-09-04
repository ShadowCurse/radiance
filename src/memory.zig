const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;

const KVM = @cImport(@cInclude("linux/kvm.h"));

pub const MemoryError = error{
    InvalidMagicNumber,
    NotAllignedKernelOffset,
};

pub const MemoryLayout = struct {
    /// Start of RAM on 64 bit ARM.
    pub const DRAM_MEM_START: u64 = 0x8000_0000; // 2 GB.
    /// The maximum RAM size.
    pub const DRAM_MEM_MAX_SIZE: u64 = 0x00FF_8000_0000; // 1024 - 2 = 1022G.

    /// Kernel command line maximum size.
    /// As per `arch/arm64/include/uapi/asm/setup.h`.
    pub const CMDLINE_MAX_SIZE: usize = 2048;

    /// Maximum size of the device tree blob as specified in https://www.kernel.org/doc/Documentation/arm64/booting.txt.
    pub const FDT_MAX_SIZE: usize = 0x20_0000;

    // As per virt/kvm/arm/vgic/vgic-kvm-device.c we need
    // the number of interrupts our GIC will support to be:
    // * bigger than 32
    // * less than 1023 and
    // * a multiple of 32.
    /// The highest usable SPI on aarch64.
    pub const IRQ_MAX: u32 = 128;

    /// First usable interrupt on aarch64.
    pub const IRQ_BASE: u32 = 32;

    /// Below this address will reside the GIC, above this address will reside the MMIO devices.
    pub const MAPPED_IO_START: u64 = 1 << 30; // 1 GB

};

pub const GuestMemory = struct {
    guest_addr: u64,
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
        const prot = linux.PROT.READ | linux.PROT.WRITE;
        const flags = linux.MAP.PRIVATE | linux.MAP.ANONYMOUS | 0x4000; //std.os.system.MAP.NORESERVE;
        const mem = try std.os.mmap(null, size, prot, flags, -1, 0);

        std.log.info("mem size: 0x{x}", .{size});
        std.log.info("guest_addr: 0x{x}", .{MemoryLayout.DRAM_MEM_START});

        return Self{ .guest_addr = MemoryLayout.DRAM_MEM_START, .mem = mem };
    }

    pub fn deinit(self: *const Self) void {
        std.os.munmap(self.mem);
    }

    pub fn load_linux_kernel(self: *Self, path: []const u8) !u64 {
        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const file_meta = try file.metadata();
        const kernel_size = file_meta.size();

        try file.seekTo(0);

        var arm64_header: arm64_image_header = undefined;
        var header_slice = std.mem.asBytes(&arm64_header);
        const n = try file.read(@as([]u8, header_slice));
        std.debug.assert(n == header_slice.len);

        std.log.info("header: {any}", .{arm64_header});

        if (arm64_header.magic != 0x644d_5241) {
            return MemoryError.InvalidMagicNumber;
        }

        var text_offset = arm64_header.text_offset;
        if (text_offset == 0) {
            text_offset = 0x80000;
        }
        std.log.info("text_offset: 0x{x}", .{text_offset});

        const kernel_offset = MemoryLayout.DRAM_MEM_START;

        // Validate that kernel_offset is 2 MB aligned, as required by the
        // arm64 boot protocol
        if (kernel_offset % 0x0020_0000 != 0) {
            return MemoryError.NotAllignedKernelOffset;
        }

        const mem_offset = kernel_offset + text_offset;
        const kernel_end = mem_offset + kernel_size;

        std.log.info("mem_offset: 0x{x}", .{mem_offset});
        std.log.info("kernel_end: 0x{x}", .{kernel_end});

        try file.seekTo(0);

        // _ = try file.read(self.mem[mem_offset..kernel_end]);
        _ = try file.read(self.mem[0..kernel_size]);

        return mem_offset;
    }
};
