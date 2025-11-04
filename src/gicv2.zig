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

pub fn init(comptime System: type, vm: *const Vm) void {
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

    set_attributes(
        System,
        fd,
        0,
        nix.KVM_DEV_ARM_VGIC_GRP_ADDR,
        nix.KVM_VGIC_V2_ADDR_TYPE_DIST,
        @intFromPtr(&Memory.GICV2_DISTRIBUTOR_ADDRESS),
    );
    set_attributes(
        System,
        fd,
        0,
        nix.KVM_DEV_ARM_VGIC_GRP_ADDR,
        nix.KVM_VGIC_V2_ADDR_TYPE_CPU,
        @intFromPtr(&Memory.GICV2_CPU_ADDRESS),
    );
    // KVM_DEV_ARM_VGIC_GRP_NR_IRQS sets the highest SPI interrupt number.
    // Total number of available interrupts is: IRQ_MAX - IRQ_BASE
    set_attributes(
        System,
        fd,
        0,
        nix.KVM_DEV_ARM_VGIC_GRP_NR_IRQS,
        0,
        @intFromPtr(&IRQ_MAX),
    );
    set_attributes(
        System,
        fd,
        0,
        nix.KVM_DEV_ARM_VGIC_GRP_CTRL,
        nix.KVM_DEV_ARM_VGIC_CTRL_INIT,
        0,
    );
}

fn set_attributes(
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
