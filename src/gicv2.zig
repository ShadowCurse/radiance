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

/// https://github.com/torvalds/linux/blob/master/arch/arm64/kvm/vgic/vgic-kvm-device.c
pub const IRQ_MAX: u32 = 128;

/// First usable interrupt on aarch64.
pub const IRQ_BASE: u32 = 32;

pub fn new(vm: *const Vm) void {
    var device: nix.kvm_create_device = .{
        .type = nix.KVM_DEV_TYPE_ARM_VGIC_V2,
        .fd = 0,
        .flags = 0,
    };
    _ = nix.assert(@src(), nix.ioctl, .{
        vm.fd,
        nix.KVM_CREATE_DEVICE,
        @intFromPtr(&device),
    });

    const fd: nix.fd_t = @intCast(device.fd);

    log.debug(@src(), "gic dist_addr: 0x{x}", .{DISTRIBUTOR_ADDRESS});
    set_attributes(
        fd,
        0,
        nix.KVM_DEV_ARM_VGIC_GRP_ADDR,
        nix.KVM_VGIC_V2_ADDR_TYPE_DIST,
        @intFromPtr(&DISTRIBUTOR_ADDRESS),
    );

    log.debug(@src(), "gic cpu_addr: 0x{x}", .{CPU_ADDRESS});
    set_attributes(
        fd,
        0,
        nix.KVM_DEV_ARM_VGIC_GRP_ADDR,
        nix.KVM_VGIC_V2_ADDR_TYPE_CPU,
        @intFromPtr(&CPU_ADDRESS),
    );

    // KVM_DEV_ARM_VGIC_GRP_NR_IRQS sets the highest SPI interrupt number.
    // Total number of available interrupts is: IRQ_MAX - IRQ_BASE
    set_attributes(
        fd,
        0,
        nix.KVM_DEV_ARM_VGIC_GRP_NR_IRQS,
        0,
        @intFromPtr(&IRQ_MAX),
    );

    set_attributes(
        fd,
        0,
        nix.KVM_DEV_ARM_VGIC_GRP_CTRL,
        nix.KVM_DEV_ARM_VGIC_CTRL_INIT,
        0,
    );
}

fn set_attributes(
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
    log.debug(@src(), "setting gic attributes: {any}", .{kda});
    _ = nix.assert(@src(), nix.ioctl, .{
        fd,
        nix.KVM_SET_DEVICE_ATTR,
        @intFromPtr(&kda),
    });
}
