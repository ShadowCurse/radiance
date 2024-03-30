const std = @import("std");
const log = @import("log.zig");
const nix = @import("nix.zig");
const Vm = @import("vm.zig");
const Memory = @import("memory.zig");

// Device trees specific constants
pub const ARCH_GIC_V2_MAINT_IRQ: u32 = 8;

pub const DISTRIBUTOR_ADDRESS: u64 = Memory.MMIO_START - nix.KVM_VGIC_V2_DIST_SIZE;
pub const CPU_ADDRESS: u64 = DISTRIBUTOR_ADDRESS - nix.KVM_VGIC_V2_CPU_SIZE;

pub const DEVICE_PROPERTIES = [_]u64{
    DISTRIBUTOR_ADDRESS,
    nix.KVM_VGIC_V2_DIST_SIZE,
    CPU_ADDRESS,
    nix.KVM_VGIC_V2_CPU_SIZE,
};

// As per virt/kvm/arm/vgic/vgic-kvm-device.c we need
// the number of interrupts our GIC will support to be:
// * bigger than 32
// * less than 1023 and
// * a multiple of 32.
/// The highest usable SPI on aarch64.
pub const IRQ_MAX: u32 = 128;

/// First usable interrupt on aarch64.
pub const IRQ_BASE: u32 = 32;

pub const Gicv2Error = error{
    New,
    SetAttributes,
};

fd: std.os.fd_t,

const Self = @This();

pub fn new(vm: *const Vm) !Self {
    var device: nix.kvm_create_device = .{
        .type = nix.KVM_DEV_TYPE_ARM_VGIC_V2,
        .fd = 0,
        .flags = 0,
    };
    _ = try nix.checked_ioctl(
        @src(),
        Gicv2Error.New,
        vm.fd,
        nix.KVM_CREATE_DEVICE,
        @intFromPtr(&device),
    );

    const fd: std.os.fd_t = @intCast(device.fd);

    // Setting up the distributor attribute.
    // We are placing the GIC below 1GB so we need to substract the size of the distributor.
    log.debug(@src(), "gic dist_addr: 0x{x}", .{Self.DISTRIBUTOR_ADDRESS});
    try Self.set_attributes(
        fd,
        0,
        nix.KVM_DEV_ARM_VGIC_GRP_ADDR,
        nix.KVM_VGIC_V2_ADDR_TYPE_DIST,
        @intFromPtr(&Self.DISTRIBUTOR_ADDRESS),
    );

    // Setting up the CPU attribute.
    log.debug(@src(), "gic cpu_addr: 0x{x}", .{Self.CPU_ADDRESS});
    try Self.set_attributes(
        fd,
        0,
        nix.KVM_DEV_ARM_VGIC_GRP_ADDR,
        nix.KVM_VGIC_V2_ADDR_TYPE_CPU,
        @intFromPtr(&Self.CPU_ADDRESS),
    );

    // On arm there are 3 types of interrupts: SGI (0-15), PPI (16-31), SPI (32-1020).
    // SPIs are used to signal interrupts from various peripherals accessible across
    // the whole system so these are the ones that we increment when adding a new virtio device.
    // KVM_DEV_ARM_VGIC_GRP_NR_IRQS sets the highest SPI number. Consequently, we will have a
    // total of `IRQ_MAX - 32` usable SPIs in our microVM.
    try Self.set_attributes(
        fd,
        0,
        nix.KVM_DEV_ARM_VGIC_GRP_NR_IRQS,
        0,
        @intFromPtr(&Self.IRQ_MAX),
    );

    // Finalize the GIC.
    // See https://code.woboq.org/linux/linux/virt/kvm/arm/vgic/vgic-kvm-device.c.html#211.
    try Self.set_attributes(
        fd,
        0,
        nix.KVM_DEV_ARM_VGIC_GRP_CTRL,
        nix.KVM_DEV_ARM_VGIC_CTRL_INIT,
        0,
    );

    return Self{ .fd = fd };
}

fn set_attributes(
    fd: std.os.fd_t,
    flags: u32,
    group: u32,
    attr: u64,
    addr: u64,
) !void {
    const kda = nix.kvm_device_attr{
        .flags = flags,
        .group = group,
        .attr = attr,
        .addr = addr,
    };
    log.debug(@src(), "setting gic attributes: {any}", .{kda});
    _ = try nix.checked_ioctl(
        @src(),
        Gicv2Error.SetAttributes,
        fd,
        nix.KVM_SET_DEVICE_ATTR,
        @intFromPtr(&kda),
    );
}
