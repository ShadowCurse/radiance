const std = @import("std");
const nix = @import("nix.zig");
const log = @import("log.zig");
const apic = @import("apic.zig");
const Memory = @import("memory.zig");

pub const MAX_SUPPORTED_CPUS = 254;
pub const CPU_STEPPING = 0x600;
pub const CPU_FEATURE_APIC = 0x200;
pub const CPU_FEATURE_FPU = 0x001;

pub const ZERO_PAGE_START = 0x7000;
pub const ZERO_PAGE_SIZE = 0x1000;
pub const VGA_START = 0xa0000;
pub const VGA_SIZE = 0x50000;
pub const BIOS_START = 0xf0000;
pub const BIOS_SIZE = 0x10000;

pub const BOOT_GDT_OFFSET = 0x500;
pub const BOOT_IDT_OFFSET = 0x520;

pub const PML4_START = 0x9000;
pub const PDPTE_START = 0xa000;
pub const PDE_START = 0xb000;

pub const GdtEntry = packed struct(u64) {
    /// Segment Limit bits 0-15
    limit_low: u16 = 0,
    /// Base Address bits 0-15
    base_low: u16 = 0,
    /// Base Address bits 16-23
    base_mid: u8 = 0,
    /// Segment Type (e.g., Code, Data, Read/Write permissions)
    type: u4 = 0,
    /// Descriptor type (0 = system, 1 = code/data)
    s: u1 = 0,
    /// Descriptor Privilege Level (0-3)
    dpl: u2 = 0,
    /// Present bit (Must be 1 for valid segments)
    p: u1 = 0,
    /// Segment Limit bits 16-19
    limit_high: u4 = 0,
    /// Available for use by system software
    avl: u1 = 0,
    /// 64-bit code segment flag (IA-32e mode only)
    l: u1 = 0,
    /// Default operation size (0 = 16-bit, 1 = 32-bit)
    db: u1 = 0,
    /// Granularity (0 = 1B units, 1 = 4KB units)
    g: u1 = 0,
    /// Base Address bits 24-31
    base_high: u8 = 0,
};
pub const GDT_TABLE = [_]GdtEntry{
    .{}, // NULL
    .{ .limit_low = 0xffff, .type = 0xb, .s = 1, .p = 1, .limit_high = 0xf, .l = 1, .g = 1 }, // CODE
    .{ .limit_low = 0xffff, .type = 0x3, .s = 1, .p = 1, .limit_high = 0xf, .db = 1, .g = 1 }, // DATA
    .{ .limit_low = 0xffff, .type = 0xb, .s = 0, .p = 1, .limit_high = 0xf, .g = 1 }, // TSS
};

pub fn configure_gdt(memory: *const Memory.Guest) void {
    var gdt_table_slice: []GdtEntry = undefined;
    gdt_table_slice.ptr = @ptrCast(@alignCast(memory.mem.ptr + BOOT_GDT_OFFSET));
    gdt_table_slice.len = GDT_TABLE.len;
    @memcpy(gdt_table_slice, &GDT_TABLE);

    const idt_ptr: *u64 = @ptrCast(@alignCast(memory.mem.ptr + BOOT_IDT_OFFSET));
    idt_ptr.* = 0;
}

pub fn configure_page_tables(memory: *const Memory.Guest) void {
    // Entry covering VA [0..512GB)
    const boot_pml4_ptr: *u64 = @ptrCast(@alignCast(memory.mem.ptr + PML4_START));
    boot_pml4_ptr.* = PDPTE_START | 0x03;

    // Entry covering VA [0..1GB)
    const boot_pdpte_ptr: *u64 = @ptrCast(@alignCast(memory.mem.ptr + PDPTE_START));
    boot_pdpte_ptr.* = PDE_START | 0x03;

    // 512 2MB entries together covering VA [0..1GB). Note we are assuming
    // CPU supports 2MB pages (/proc/cpuinfo has 'pse'). All modern CPUs do.
    for (0..512) |i| {
        const ptr: *u64 = @ptrCast(@alignCast(memory.mem.ptr + PDE_START + i * 8));
        ptr.* = (i << 21) + 0x83;
    }
}

// Global memory layout:
//     [RAM]
// (  ZERO_PAGE  )
// ( boot_params )
// (   cmdline   )
//     [RAM]
// ( BIOS_START )
// (  mptable   )
//     [RAM]
// (    APIC    )
// ( setup_data )
// (    FDT     )
pub fn configure_e820(memory: *const Memory.Guest, cmdline: [:0]const u8, fdt_addr: u64, fdt_size: u32) void {
    const setup_data_addr = fdt_addr - @sizeOf(nix.setup_data);
    const setup_data = memory.get_ptr(nix.setup_data, setup_data_addr);
    setup_data.* = .{ .next = 0, .type = nix.SETUP_DTB, .len = fdt_size };

    const cmdline_addr = ZERO_PAGE_START + @sizeOf(nix.boot_params);
    const cmdline_slice = memory.get_slice(u8, cmdline.len, cmdline_addr);
    @memcpy(cmdline_slice, cmdline);

    const boot_params = memory.get_ptr(nix.boot_params, ZERO_PAGE_START);
    boot_params.* = .{};

    // e820 setup
    const KERNEL_LOADER_OTHER: u8 = 0xff;
    const KERNEL_MIN_ALIGNMENT_BYTES: u32 = 0x0100_0000; // Must be non-zero.
    boot_params.hdr.type_of_loader = KERNEL_LOADER_OTHER;
    boot_params.hdr.boot_flag = 0xaa55;
    boot_params.hdr.header = @bitCast(@as([4]u8, "HdrS".*));
    boot_params.hdr.cmd_line_ptr = @truncate(cmdline_addr);
    boot_params.hdr.cmdline_size = @truncate(cmdline.len);
    boot_params.hdr.kernel_alignment = KERNEL_MIN_ALIGNMENT_BYTES;
    boot_params.hdr.setup_data = setup_data_addr;

    boot_params.e820_table[boot_params.e820_entries] = .{
        .addr = 0,
        .size = ZERO_PAGE_START,
        .type = nix.E820_RAM,
    };
    boot_params.e820_entries += 1;

    boot_params.e820_table[boot_params.e820_entries] = .{
        .addr = ZERO_PAGE_START,
        .size = ZERO_PAGE_SIZE,
        .type = nix.E820_RESERVED,
    };
    boot_params.e820_entries += 1;

    boot_params.e820_table[boot_params.e820_entries] = .{
        .addr = ZERO_PAGE_START + ZERO_PAGE_SIZE,
        .size = VGA_START - (ZERO_PAGE_START + ZERO_PAGE_SIZE),
        .type = nix.E820_RAM,
    };
    boot_params.e820_entries += 1;

    // Cover both VGA and BIOS sections
    boot_params.e820_table[boot_params.e820_entries] = .{
        .addr = VGA_START,
        .size = VGA_SIZE + BIOS_SIZE,
        .type = nix.E820_RESERVED,
    };
    boot_params.e820_entries += 1;

    boot_params.e820_table[boot_params.e820_entries] = .{
        .addr = VGA_START + VGA_SIZE + BIOS_SIZE,
        .size = setup_data_addr - (VGA_START + VGA_SIZE + BIOS_SIZE),
        .type = nix.E820_RAM,
    };
    boot_params.e820_entries += 1;

    boot_params.e820_table[boot_params.e820_entries] = .{
        .addr = setup_data_addr,
        .size = memory.last_addr() - setup_data_addr + 1,
        .type = nix.E820_RESERVED,
    };
    boot_params.e820_entries += 1;
}

// The layout in memory:
// [mpf_intel]
// [mpc_table] header
// [mpc_cpu] ** n_cpus
// [mpc_bus]
// [mpc_ioapic]
// [mpc_intsrc]
// [mpc_lintsrc] mp_ExtINT
// [mpc_lintsrc] mp_NMI
pub fn configure_mptable(memory: *const Memory.Guest, n_cpus: u8) void {
    const Inner = struct {
        fn compute_checksum(comptime T: type, t: *const volatile T) u8 {
            const bytes: []const volatile u8 = @ptrCast(t);
            var result: u8 = 0;
            for (bytes) |b| result +%= b;
            return result;
        }

        fn finalize_checksum(v: u8) u8 {
            const result = ~v +% 1;
            return result;
        }
    };

    log.assert(
        @src(),
        n_cpus <= MAX_SUPPORTED_CPUS,
        "mptables cannot address more than {d} cpus, tried to address {d}",
        .{ @as(u32, MAX_SUPPORTED_CPUS), n_cpus },
    );

    // mptable lives in lower 4G of memory
    const mpf_intel_addr: u64 = BIOS_START;
    const mpc_table_addr = mpf_intel_addr + @sizeOf(nix.mpf_intel);

    const mpf_intel = memory.get_ptr(nix.mpf_intel, mpf_intel_addr);
    mpf_intel.* = .{
        .signature = nix.SMP_MAGIC_IDENT.*,
        .physptr = mpc_table_addr,
        .length = 1,
        .specification = 4,
    };
    mpf_intel.checksum = Inner.compute_checksum(nix.mpf_intel, mpf_intel);
    mpf_intel.checksum = Inner.finalize_checksum(mpf_intel.checksum);

    // mpc_table is a header, reserve space for it, it is filled last
    var current_addr = mpc_table_addr + @sizeOf(nix.mpc_table);
    var n_entries: u16 = 0;
    var checksum: u8 = 0;

    for (0..n_cpus) |i| {
        var cpuflag: u8 = nix.CPU_ENABLED;
        if (i == 0) cpuflag |= nix.CPU_BOOTPROCESSOR;
        const mpc_cpu = memory.get_ptr(nix.mpc_cpu, current_addr);
        mpc_cpu.* = .{
            .type = nix.MP_PROCESSOR,
            .apicid = @truncate(i),
            .apicver = apic.APIC_VERSION,
            .cpuflag = cpuflag,
            .cpufeature = CPU_STEPPING,
            .featureflag = CPU_FEATURE_APIC | CPU_FEATURE_FPU,
        };

        checksum +%= Inner.compute_checksum(nix.mpc_cpu, mpc_cpu);
        current_addr += @sizeOf(nix.mpc_cpu);
        n_entries += 1;
    }
    const mpc_bus = memory.get_ptr(nix.mpc_bus, current_addr);
    mpc_bus.* = .{
        .type = nix.MP_BUS,
        .busid = 0,
        .bustype = nix.BUSTYPE_ISA.*,
    };
    checksum +%= Inner.compute_checksum(nix.mpc_bus, mpc_bus);
    current_addr += @sizeOf(nix.mpc_bus);
    n_entries += 1;

    const ioapicid: u8 = n_cpus;
    const mpc_ioapic = memory.get_ptr(nix.mpc_ioapic, current_addr);
    mpc_ioapic.* = .{
        .type = nix.MP_IOAPIC,
        .apicid = ioapicid,
        .apicver = apic.APIC_VERSION,
        .flags = nix.MPC_APIC_USABLE,
        .apicaddr = apic.IO_APIC_DEFAULT_PHYS_BASE,
    };
    checksum +%= Inner.compute_checksum(nix.mpc_ioapic, mpc_ioapic);
    current_addr += @sizeOf(nix.mpc_ioapic);
    n_entries += 1;

    // Per kvm_setup_default_irq_routing() in kernel
    for (0..apic.IRQ_MAX + 1) |i| {
        const mpc_intsrc = memory.get_ptr(nix.mpc_intsrc, current_addr);
        mpc_intsrc.* = .{
            .type = nix.MP_INTSRC,
            .irqtype = .mp_INT,
            .irqflag = nix.MP_IRQPOL_DEFAULT,
            .srcbusirq = @truncate(i),
            .dstapic = ioapicid,
            .dstirq = @truncate(i),
        };
        checksum +%= Inner.compute_checksum(nix.mpc_intsrc, mpc_intsrc);
        current_addr += @sizeOf(nix.mpc_intsrc);
        n_entries += 1;
    }
    {
        const mpc_lintsrc = memory.get_ptr(nix.mpc_lintsrc, current_addr);
        mpc_lintsrc.* = .{
            .type = nix.MP_LINTSRC,
            .irqtype = .mp_ExtINT,
            .irqflag = nix.MP_IRQPOL_DEFAULT,
        };

        checksum +%= Inner.compute_checksum(nix.mpc_lintsrc, mpc_lintsrc);
        current_addr += @sizeOf(nix.mpc_lintsrc);
        n_entries += 1;
    }
    {
        const mpc_lintsrc = memory.get_ptr(nix.mpc_lintsrc, current_addr);
        mpc_lintsrc.* = .{
            .type = nix.MP_LINTSRC,
            .irqtype = .mp_NMI,
            .irqflag = nix.MP_IRQPOL_DEFAULT,
            .destapic = 0xFF,
            .destapiclint = 1,
        };

        checksum +%= Inner.compute_checksum(nix.mpc_lintsrc, mpc_lintsrc);
        current_addr += @sizeOf(nix.mpc_lintsrc);
        n_entries += 1;
    }

    const mpc_table = memory.get_ptr(nix.mpc_table, mpc_table_addr);
    mpc_table.* = .{
        .signature = nix.MPC_SIGNATURE.*,
        .length = @truncate(current_addr - mpc_table_addr),
        .spec = 4,
        .oem = "RADIANCE".*,
        .oemcount = n_entries,
        .lapic = apic.APIC_DEFAULT_PHYS_BASE,
    };
    checksum +%= Inner.compute_checksum(nix.mpc_table, mpc_table);
    checksum = Inner.finalize_checksum(checksum);
    mpc_table.checksum = checksum;
}
