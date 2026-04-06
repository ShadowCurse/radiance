const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig");
const nix = @import("nix.zig");
const profiler = @import("profiler.zig");

pub const MEASUREMENTS = profiler.Measurements("args_parser", &.{
    "load_linux_kernel",
});

pub const HOST_PAGE_SIZE = std.heap.page_size_min;

/// Address for gicv2m MSI registers.
pub const GICV2M_MSI_ADDR = 0x80000;
pub const GICV2M_MSI_LEN = 0x1000;

// The GICv2 controller needs memory to place the
// irq distributor data and cpu interrupt handling data.
// We place it just before the MMIO region as it is conveniently aligned and
// it is simple to calculate GICv2 addresses.
pub const GICV2_CPU_ADDRESS: u64 = GICV2_DISTRIBUTOR_ADDRESS - nix.KVM_VGIC_V2_CPU_SIZE;
pub const GICV2_DISTRIBUTOR_ADDRESS: u64 = MMIO_START - nix.KVM_VGIC_V2_DIST_SIZE;

/// GIC is bellow, MMIO devices are here.
pub const MMIO_START: u64 = 0x4000_0000; // 1 GB
/// Start of RAM on 64 bit ARM.
pub const DRAM_START: u64 = if (builtin.cpu.arch == .aarch64)
    // 2 GB
    0x8000_0000
else if (builtin.cpu.arch == .x86_64)
    0
else
    @compileError("Only aarch64 and x64 are supported");

// The 1TB version seems to be so far, it crashes the kernel.
// The PCI will be mapped there
pub const PCI_START = 1 << 39; // 512 GB
// The size of the memory area reserved for MMIO 64-bit accesses.
pub const PCI_SIZE = 1 << 30; // 1 GB
pub const PCI_BAR_SIZE = 256 << 20; // 256 MB

pub const PCI_CONFIG_SIZE = 1 << 30; // 1 GB
pub const PCI_CONFIG_START = PCI_START - PCI_CONFIG_SIZE;
pub const PCI_ECAM_REGION_SIZE = 256 << 20; // 256 MB

pub const Guest = struct {
    mem: []align(HOST_PAGE_SIZE) u8,

    const Self = @This();

    pub fn get_ptr(self: *const Self, comptime T: type, addr: u64) *volatile T {
        const offset = addr - DRAM_START;
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
        const offset = addr - DRAM_START;
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
        return DRAM_START + self.mem.len - 1;
    }

    /// Loads the linux kernel into the memory.
    /// Returns the guest memory address where
    /// the executable code starts and a size of the kernel.
    /// https://github.com/torvalds/linux/blob/master/Documentation/arch/arm64/booting.rst
    pub const LoadResult = struct {
        start: u64,
        end: u64,
        post_kernel_allocator: std.heap.FixedBufferAllocator,
    };
    pub const load_linux_kernel = if (builtin.cpu.arch == .aarch64)
        load_linux_kernel_aarch64
    else if (builtin.cpu.arch == .x86_64)
        load_linux_kernel_x64
    else
        @compileError("Only aarch64 and x64 are supported");

    pub fn load_linux_kernel_aarch64(self: *Self, comptime System: type, path: []const u8) LoadResult {
        const prof_point = MEASUREMENTS.start_named("load_linux_kernel");
        defer MEASUREMENTS.end(prof_point);

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
        const arm64_header: *arm64_image_header = @ptrCast(file_mem.ptr);
        log.assert(
            @src(),
            arm64_header.magic == 0x644d_5241,
            "Kernel magic value is invalid: {} != {}",
            .{ arm64_header.magic, @as(u32, 0x644d_5241) },
        );

        var text_offset = arm64_header.text_offset;
        if (arm64_header.image_size == 0)
            text_offset = 0x80000;

        const post_kernel_allocator_start = ((meta.size / HOST_PAGE_SIZE) + 1) * HOST_PAGE_SIZE;
        return .{
            .start = DRAM_START + text_offset,
            .end = 0,
            .post_kernel_allocator = .init(self.mem[post_kernel_allocator_start..]),
        };
    }

    fn load_linux_kernel_x64(self: *Self, comptime System: type, path: []const u8) LoadResult {
        const prof_point = MEASUREMENTS.start_named("load_linux_kernel");
        defer MEASUREMENTS.end(prof_point);

        const fd = nix.assert(@src(), System, "open", .{
            path,
            .{ .CLOEXEC = true, .ACCMODE = .RDONLY },
            0,
        });
        defer System.close(fd);
        const meta = nix.assert(@src(), System, "statx", .{fd});

        const prot = nix.PROT.READ;
        const flags = nix.MAP{ .TYPE = .SHARED };
        const file_mem = nix.assert(@src(), System, "mmap", .{ null, meta.size, prot, flags, fd, 0 });

        const ehdr: *const nix.Elf64_Ehdr = @ptrCast(@alignCast(file_mem.ptr));
        log.assert(
            @src(),
            std.mem.eql(u8, ehdr.e_ident[0..nix.Elf64_Magic.len], nix.Elf64_Magic),
            "Invalid ELF header magic: {x} expected: {x}",
            .{ ehdr.e_ident[0..nix.Elf64_Magic.len], nix.Elf64_Magic },
        );
        log.assert(
            @src(),
            ehdr.e_ident[nix.EI_DATA] == nix.ELFDATA2LSB,
            "Unexpected endiannes. Found 0x{x} expected 0x{x}(little)",
            .{ ehdr.e_ident[nix.EI_DATA], @as(u8, nix.ELFDATA2LSB) },
        );
        const kernel_start = ehdr.e_entry;

        var phdrs: []nix.Elf64_Phdr = undefined;
        phdrs.ptr = @ptrCast(@alignCast(file_mem.ptr + ehdr.e_phoff));
        phdrs.len = ehdr.e_phnum;

        var kernel_end: u64 = 0;
        for (phdrs) |phdr| {
            if (phdr.p_type == nix.PT_LOAD and phdr.p_filesz != 0) {
                log.debug(@src(), "kernel phdr: paddr: 0x{x} file offset: 0x{x}, file_size: 0x{x}", .{
                    phdr.p_paddr,
                    phdr.p_offset,
                    phdr.p_filesz,
                });
                const section_start = phdr.p_paddr;
                const section_end = phdr.p_paddr + phdr.p_memsz;
                if (self.mem.len < section_end) {
                    log.assert(@src(), false, "phdr region [0x{x}..0x{x}], but memory is [0x{x}..0x{x}]", .{
                        section_start,
                        section_end,
                        @as(u32, 0),
                        self.mem.len,
                    });
                }
                _ = nix.assert(@src(), System, "mmap", .{
                    @ptrCast(@alignCast(self.mem.ptr + section_start)),
                    phdr.p_filesz,
                    nix.PROT.READ | nix.PROT.WRITE,
                    nix.MAP{
                        .TYPE = .PRIVATE,
                        .FIXED = true,
                        .NORESERVE = true,
                    },
                    fd,
                    phdr.p_offset,
                });

                kernel_end = @max(kernel_end, section_end);
            } else {
                log.debug(
                    @src(),
                    "Skipping ELF phdr with type: 0x{x} filesz: 0x{x}",
                    .{ phdr.p_type, phdr.p_filesz },
                );
            }
        }
        return .{
            .start = kernel_start,
            .end = kernel_end,
            .post_kernel_allocator = .init(self.mem[kernel_end..]),
        };
    }
};

pub const Permanent = struct {
    mem: []align(HOST_PAGE_SIZE) u8,

    const LOCATION = 0x8000000;

    const Self = @This();

    pub fn init(comptime System: type, size: usize) Self {
        const mem = nix.assert(@src(), System, "mmap", .{
            @ptrFromInt(LOCATION),
            size,
            nix.PROT.READ | nix.PROT.WRITE,
            nix.MAP{
                .TYPE = .PRIVATE,
                .FIXED = true,
                .ANONYMOUS = true,
                .NORESERVE = true,
            },
            -1,
            0,
        });
        return .{ .mem = mem };
    }

    pub fn init_from_snapshot(comptime System: type, snapshot_path: []const u8) Self {
        const fd = nix.assert(@src(), System, "open", .{
            snapshot_path,
            .{ .ACCMODE = .RDWR },
            0,
        });
        defer System.close(fd);
        const statx = nix.assert(@src(), System, "statx", .{fd});

        const mem = nix.assert(@src(), System, "mmap", .{
            @ptrFromInt(LOCATION),
            statx.size,
            nix.PROT.READ | nix.PROT.WRITE,
            .{
                .TYPE = .PRIVATE,
                .FIXED = true,
                .NORESERVE = true,
            },
            fd,
            0,
        });
        return .{ .mem = mem };
    }
};

pub fn align_addr(addr: u64, align_to: u64) u64 {
    return (addr + align_to) & ~(align_to - 1);
}

pub fn is_aligned(addr: u64, align_to: u64) bool {
    return (addr & (align_to - 1)) == 0;
}
