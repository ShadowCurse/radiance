const log = @import("log.zig");
const nix = @import("nix.zig");
const Vm = @import("vm.zig");
const Memory = @import("memory.zig");

// More info about GICv2 and GICv3
// https://documentation-service.arm.com/static/65ba63b032ae5f7841c42508
// https://www.linux-kvm.org/images/7/79/03x09-Aspen-Andre_Przywara-ARM_Interrupt_Virtualization.pdf
pub const DEVICE_PROPERTIES = [_]u64{
    Memory.GICV2_DISTRIBUTOR_ADDRESS,
    nix.KVM_VGIC_V2_DIST_SIZE,
    Memory.GICV2_CPU_ADDRESS,
    nix.KVM_VGIC_V2_CPU_SIZE,
};

/// 0-15 are SGIs (Software Generated Interrupt) - can be delivered to any connected core.
/// 16-31 are PPIs (Private Peripheral Interrupt) - private to one core.
/// 32-1019 are SPIs (Shared Peripheral Interrupt) <- these we can use
///                                                 - used for inter-process communication
/// KVM internally adds 32 to the IRQ numbers we allocate. This means we can allocate from 0 withot
/// worryings about SGIs,PPIs.
pub const GIC_INTERNAL_OFFSET = 32;

pub const IRQ_BASE: u32 = 0;
/// https://github.com/torvalds/linux/blob/master/arch/arm64/kvm/vgic/vgic-kvm-device.c
/// The value must be bigger than 64 and smaller than 1024 and be a multiple of 32.
/// Because 64..128 are highest SPIs used for MSIX, the max is 128 - 32 (because SPIs for MSIX are
/// real SPIs, for KVM need to subtract 32)
pub const IRQ_MAX: u32 = 96;

/// Gicv2m needs it's own range of irqs. It will assign them to MSIX at PCI device init.
/// MSIX_IRQ_BASE must be above 32 (because it needs to be SPI). These are not touched by KVM,
/// so when creating kvm_irqfd we need to subtract 32 (so KVM can add it again later).
pub const MSIX_IRQ_BASE = 64;
pub const MSIX_IRQ_NUM = 64;

const Register = struct {
    offset: u32,
    len: u32,

    fn with_byte_len(offset: u32, len: u32) Register {
        return .{ .offset = offset, .len = len / @sizeOf(u32) };
    }

    fn with_bits_per_irq(offset: u32, bits: u32) Register {
        // Skip KVM only registers
        const start = offset + GIC_INTERNAL_OFFSET * bits / 8;
        const size_in_bits = bits * IRQ_MAX;
        const size_in_bytes = size_in_bits / 8;
        log.comptime_assert(
            @src(),
            size_in_bits % 8 == 0,
            "Number of bits must be multiple of 8, got: {d}",
            .{size_in_bits},
        );
        log.comptime_assert(
            @src(),
            size_in_bytes % 4 == 0,
            "Number of bytes must be multiple of 4, got: {d}",
            .{size_in_bytes},
        );
        return .{
            .offset = start,
            .len = size_in_bytes / @sizeOf(u32),
        };
    }
};

// 4.1.3 CPU interface register map (page 76) in
// https://developer.arm.com/documentation/ihi0048/latest/
// Only RW regs. Also skip GICC_NSAPRn since it is only available when security
// extensions present.
// Kernel defines:
// https://elixir.bootlin.com/linux/v6.17.7/source/include/linux/irqchip/arm-gic.h#L10
const GIC_CPU_CTLR: Register = .with_byte_len(0x0, 4);
const GIC_CPU_PRIMASK: Register = .with_byte_len(0x04, 4);
const GIC_CPU_BINPOINT: Register = .with_byte_len(0x08, 4);
const GIC_CPU_ALIAS_BINPOINT: Register = .with_byte_len(0x001c, 4);
const GIC_CPU_ACTIVE_PRIO0: Register = .with_byte_len(0x00d0, 16);

const VGIC_CPU_REGS = [_]Register{
    GIC_CPU_CTLR,
    GIC_CPU_PRIMASK,
    GIC_CPU_BINPOINT,
    GIC_CPU_ALIAS_BINPOINT,
    GIC_CPU_ACTIVE_PRIO0,
};

// 4.1.3 CPU interface register map (page 75) in
// https://developer.arm.com/documentation/ihi0048/latest/
// Only RW regs
// Kernel defines:
// https://elixir.bootlin.com/linux/v6.17.7/source/include/linux/irqchip/arm-gic.h#L42
const GIC_DIST_CTRL: Register = .with_byte_len(0x0, 12);
const GIC_DIST_IGROUP: Register = .with_bits_per_irq(0x80, 1);
const GIC_DIST_ENABLE_SET: Register = .with_bits_per_irq(0x100, 1);
const GIC_DIST_ENABLE_CLEAR: Register = .with_bits_per_irq(0x180, 1);
const GIC_DIST_PENDING_SET: Register = .with_bits_per_irq(0x200, 1);
const GIC_DIST_PENDING_CLEAR: Register = .with_bits_per_irq(0x280, 1);
const GIC_DIST_ACTIVE_SET: Register = .with_bits_per_irq(0x300, 1);
const GIC_DIST_ACTIVE_CLEAR: Register = .with_bits_per_irq(0x380, 1);
const GIC_DIST_PRI: Register = .with_bits_per_irq(0x400, 8);
const GIC_DIST_CONFIG: Register = .with_bits_per_irq(0xc00, 2);
const GIC_DIST_SGI_PENDING_CLEAR: Register = .with_byte_len(0xf10, 16);
const GIC_DIST_SGI_PENDING_SET: Register = .with_byte_len(0xf20, 16);

// The order here is different from definitions above because
// of a dependency between CLEAR and SET registers
const VGIC_DIST_REGS = [_]Register{
    GIC_DIST_PRI,
    GIC_DIST_CTRL,
    GIC_DIST_IGROUP,
    GIC_DIST_CONFIG,
    // Must restore CLEAR before SET, oterwise VM stalls
    GIC_DIST_ENABLE_CLEAR,
    GIC_DIST_ENABLE_SET,
    GIC_DIST_PENDING_CLEAR,
    GIC_DIST_PENDING_SET,
    GIC_DIST_ACTIVE_CLEAR,
    GIC_DIST_ACTIVE_SET,
    GIC_DIST_SGI_PENDING_CLEAR,
    GIC_DIST_SGI_PENDING_SET,
};

fn total_regs_entries(regs: []const Register) u32 {
    var total: u32 = 0;
    for (regs) |reg| total += reg.len;
    return total;
}

const VGIC_INTERFACE_REGS_BYTES = total_regs_entries(&VGIC_CPU_REGS);
const VGIC_DIST_REGS_BYTES = total_regs_entries(&VGIC_DIST_REGS);
pub const State = [VGIC_INTERFACE_REGS_BYTES + VGIC_DIST_REGS_BYTES]u32;

fd: nix.fd_t,

const Self = @This();

pub fn init(comptime System: type, vm: Vm) Self {
    var device: nix.kvm_create_device = .{
        .type = nix.KVM_DEV_TYPE_ARM_VGIC_V2,
        .fd = 0,
        .flags = 0,
    };
    _ = nix.assert(@src(), System, "ioctl", .{
        vm.fd,
        nix.KVM_CREATE_DEVICE,
        @intFromPtr(&device),
    });
    const fd: nix.fd_t = @intCast(device.fd);

    set_attribute(
        System,
        fd,
        0,
        nix.KVM_DEV_ARM_VGIC_GRP_ADDR,
        nix.KVM_VGIC_V2_ADDR_TYPE_DIST,
        @intFromPtr(&Memory.GICV2_DISTRIBUTOR_ADDRESS),
    );
    set_attribute(
        System,
        fd,
        0,
        nix.KVM_DEV_ARM_VGIC_GRP_ADDR,
        nix.KVM_VGIC_V2_ADDR_TYPE_CPU,
        @intFromPtr(&Memory.GICV2_CPU_ADDRESS),
    );
    // KVM_DEV_ARM_VGIC_GRP_NR_IRQS sets the highest SPI interrupt number.
    // Total number of available interrupts is: IRQ_MAX - IRQ_BASE
    set_attribute(
        System,
        fd,
        0,
        nix.KVM_DEV_ARM_VGIC_GRP_NR_IRQS,
        0,
        @intFromPtr(&IRQ_MAX),
    );
    set_attribute(
        System,
        fd,
        0,
        nix.KVM_DEV_ARM_VGIC_GRP_CTRL,
        nix.KVM_DEV_ARM_VGIC_CTRL_INIT,
        0,
    );

    return .{ .fd = fd };
}

pub fn save_state(self: *const Self, comptime System: type, state: *State) void {
    var current_reg: u32 = 0;
    for (VGIC_CPU_REGS) |reg| {
        for (0..reg.len) |i| {
            get_attribute(
                System,
                self.fd,
                0,
                nix.KVM_DEV_ARM_VGIC_GRP_CPU_REGS,
                reg.offset + i * @sizeOf(u32),
                @intFromPtr(&state[current_reg]),
            );
            log.debug(
                @src(),
                "Reading GICv2 cpu reg: 0x{x} value: 0x{x}",
                .{ reg.offset + i * @sizeOf(u32), state[current_reg] },
            );
            current_reg += 1;
        }
    }

    for (VGIC_DIST_REGS) |reg| {
        for (0..reg.len) |i| {
            get_attribute(
                System,
                self.fd,
                0,
                nix.KVM_DEV_ARM_VGIC_GRP_DIST_REGS,
                reg.offset + i * @sizeOf(u32),
                @intFromPtr(&state[current_reg]),
            );
            log.debug(
                @src(),
                "Reading GICv2 dist reg: 0x{x} value: 0x{x}",
                .{ reg.offset + i * @sizeOf(u32), state[current_reg] },
            );
            current_reg += 1;
        }
    }
}

pub fn restore_state(self: *const Self, comptime System: type, state: *const State) void {
    var current_reg: u32 = 0;
    for (VGIC_CPU_REGS) |reg| {
        for (0..reg.len) |i| {
            set_attribute(
                System,
                self.fd,
                0,
                nix.KVM_DEV_ARM_VGIC_GRP_CPU_REGS,
                reg.offset + i * @sizeOf(u32),
                @intFromPtr(&state[current_reg]),
            );
            log.debug(
                @src(),
                "Setting GICv2 cpu reg: 0x{x} value: 0x{x}",
                .{ reg.offset + i * @sizeOf(u32), state[current_reg] },
            );
            current_reg += 1;
        }
    }

    for (VGIC_DIST_REGS) |reg| {
        for (0..reg.len) |i| {
            set_attribute(
                System,
                self.fd,
                0,
                nix.KVM_DEV_ARM_VGIC_GRP_DIST_REGS,
                reg.offset + i * @sizeOf(u32),
                @intFromPtr(&state[current_reg]),
            );
            log.debug(
                @src(),
                "Setting GICv2 dist reg: 0x{x} value: 0x{x}",
                .{ reg.offset + i * @sizeOf(u32), state[current_reg] },
            );
            current_reg += 1;
        }
    }
}

fn set_attribute(
    comptime System: type,
    fd: nix.fd_t,
    flags: u32,
    group: u32,
    attr: u64,
    addr: u64,
) void {
    const kda = nix.kvm_device_attr{
        .flags = flags,
        .group = group,
        .attr = attr,
        .addr = addr,
    };
    log.debug(@src(), "Setting device attributes: {any}", .{kda});
    _ = nix.assert(@src(), System, "ioctl", .{
        fd,
        nix.KVM_SET_DEVICE_ATTR,
        @intFromPtr(&kda),
    });
}

fn get_attribute(
    comptime System: type,
    fd: nix.fd_t,
    flags: u32,
    group: u32,
    attr: u64,
    addr: u64,
) void {
    const kda = nix.kvm_device_attr{
        .flags = flags,
        .group = group,
        .attr = attr,
        .addr = addr,
    };
    log.debug(@src(), "Getting device attributes: {any}", .{kda});
    _ = nix.assert(@src(), System, "ioctl", .{
        fd,
        nix.KVM_GET_DEVICE_ATTR,
        @intFromPtr(&kda),
    });
}

pub fn write(offset: u64, data: []u8) void {
    _ = data;
    log.assert(
        @src(),
        false,
        "Unknown write into gicv2m memory region at the offset: 0x{x}",
        .{offset},
    );
    return;
}
pub fn read(offset: u64, data: []u8) void {
    const data_u32: *u32 = @ptrCast(@alignCast(data.ptr));
    switch (offset) {
        nix.V2M_MSI_TYPER => {
            log.debug(@src(), "V2M_MSI_TYPER MMIO READ serving offset {x}", .{offset});
            data_u32.* = MSIX_IRQ_BASE << nix.V2M_MSI_TYPER_BASE_SHIFT | MSIX_IRQ_NUM;
            log.debug(
                @src(),
                "spi_start: {d}, nr_spis: {d}",
                .{
                    nix.V2M_MSI_TYPER_BASE_SPI(data_u32.*),
                    nix.V2M_MSI_TYPER_NUM_SPI(data_u32.*),
                },
            );
        },
        nix.V2M_MSI_IIDR => {
            log.debug(@src(), "V2M_MSI_IIDR MMIO READ serving offset {x}", .{offset});
            data_u32.* = 0;
        },
        else => log.assert(
            @src(),
            false,
            "Unknown read into gicv2m memory region at the offset: 0x{x}",
            .{offset},
        ),
    }
    return;
}
