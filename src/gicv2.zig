const log = @import("log.zig");
const nix = @import("nix.zig");
const Vm = @import("vm.zig");
const Memory = @import("memory.zig");

// More info about GICv2 and GICv3
// https://documentation-service.arm.com/static/65ba63b032ae5f7841c42508
// https://www.linux-kvm.org/images/7/79/03x09-Aspen-Andre_Przywara-ARM_Interrupt_Virtualization.pdf

// The GICv2 controller needs memory to place the
// irq distributor data and cpu interrupt handling data.
// We place it just before the MMIO region as it is conveniently aligned and
// it is simple to calculate GICv2 addresses.
pub const DISTRIBUTOR_ADDRESS: u64 = Memory.MMIO_START - nix.KVM_VGIC_V2_DIST_SIZE;
pub const CPU_ADDRESS: u64 = DISTRIBUTOR_ADDRESS - nix.KVM_VGIC_V2_CPU_SIZE;

pub const DEVICE_PROPERTIES = [_]u64{
    DISTRIBUTOR_ADDRESS,
    nix.KVM_VGIC_V2_DIST_SIZE,
    CPU_ADDRESS,
    nix.KVM_VGIC_V2_CPU_SIZE,
};

/// 0-15 are SGIs (Software Generated Interrupt) - can be delivered to any connected core.
/// 16-31 are PPIs (Private Peripheral Interrupt) - private to one core.
/// 32-1019 are SPIs (Shared Peripheral Interrupt) <- these we can use
///                                                 - used for inter-process communication
pub const IRQ_BASE: u32 = 32;

/// https://github.com/torvalds/linux/blob/master/arch/arm64/kvm/vgic/vgic-kvm-device.c
/// The value must be bigger than 64 and smaller than 1024 and be a multiple of 32.
pub const IRQ_MAX: u32 = 128;

pub fn new(comptime System: type, vm: *const Vm) void {
    var device: nix.kvm_create_device = .{
        .type = nix.KVM_DEV_TYPE_ARM_VGIC_V2,
        .fd = 0,
        .flags = 0,
    };
    _ = nix.assert(@src(), System.ioctl, .{
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
        @intFromPtr(&DISTRIBUTOR_ADDRESS),
    );
    set_attributes(
        System,
        fd,
        0,
        nix.KVM_DEV_ARM_VGIC_GRP_ADDR,
        nix.KVM_VGIC_V2_ADDR_TYPE_CPU,
        @intFromPtr(&CPU_ADDRESS),
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
    _ = nix.assert(@src(), System.ioctl, .{
        fd,
        nix.KVM_SET_DEVICE_ATTR,
        @intFromPtr(&kda),
    });
}
