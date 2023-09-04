const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;

const KVM = @cImport(@cInclude("linux/kvm.h"));

const Vm = @import("vm.zig").Vm;
const MemoryLayout = @import("memory.zig").MemoryLayout;

// ioctl in std uses c_int as a request type which is incorrect.
extern "c" fn ioctl(fd: std.os.fd_t, request: c_ulong, ...) c_int;

pub const Gicv2Error = error{
    New,
    SetAttributes,
};

pub const GICv2 = struct {
    fd: std.os.fd_t,

    const VERSION = 5;
    const KVM_VGIC_V2_DIST_SIZE: u64 = 0x1000;
    const KVM_VGIC_V2_CPU_SIZE: u64 = 0x2000;
    // Device trees specific constants
    const ARCH_GIC_V2_MAINT_IRQ: u32 = 8;

    const Self = @This();

    pub fn new(vm: *const Vm) !Self {
        var device: KVM.kvm_create_device = .{
            .type = Self.VERSION,
            .fd = 0,
            .flags = 0,
        };
        const r = ioctl(vm.fd, KVM.KVM_CREATE_DEVICE, @intFromPtr(&device));
        if (r < 0) {
            return Gicv2Error.New;
        }

        const fd: std.os.fd_t = @intCast(device.fd);

        // Setting up the distributor attribute.
        // We are placing the GIC below 1GB so we need to substract the size of the distributor.
        const dist_addr = MemoryLayout.MAPPED_IO_START - Self.KVM_VGIC_V2_DIST_SIZE;
        std.log.info("gic addr dist_addr: {}", .{dist_addr});
        try Self.set_attributes(
            fd,
            0,
            KVM.KVM_DEV_ARM_VGIC_GRP_ADDR,
            KVM.KVM_VGIC_V2_ADDR_TYPE_DIST,
            @intFromPtr(&dist_addr),
        );

        // Setting up the CPU attribute.
        const cpu_addr = dist_addr - Self.KVM_VGIC_V2_CPU_SIZE;
        std.log.info("gic addr cpu_addr: {}", .{cpu_addr});
        try Self.set_attributes(
            fd,
            0,
            KVM.KVM_DEV_ARM_VGIC_GRP_ADDR,
            KVM.KVM_VGIC_V2_ADDR_TYPE_CPU,
            @intFromPtr(&cpu_addr),
        );

        // On arm there are 3 types of interrupts: SGI (0-15), PPI (16-31), SPI (32-1020).
        // SPIs are used to signal interrupts from various peripherals accessible across
        // the whole system so these are the ones that we increment when adding a new virtio device.
        // KVM_DEV_ARM_VGIC_GRP_NR_IRQS sets the highest SPI number. Consequently, we will have a
        // total of `super::layout::IRQ_MAX - 32` usable SPIs in our microVM.
        try Self.set_attributes(
            fd,
            0,
            KVM.KVM_DEV_ARM_VGIC_GRP_NR_IRQS,
            0,
            @intFromPtr(&MemoryLayout.IRQ_MAX),
        );

        // Finalize the GIC.
        // See https://code.woboq.org/linux/linux/virt/kvm/arm/vgic/vgic-kvm-device.c.html#211.
        try Self.set_attributes(
            fd,
            0,
            KVM.KVM_DEV_ARM_VGIC_GRP_CTRL,
            KVM.KVM_DEV_ARM_VGIC_CTRL_INIT,
            0,
        );

        return Self{ .fd = fd };
    }

    fn set_attributes(fd: std.os.fd_t, flags: u32, group: u32, attr: u64, addr: u64) !void {
        const kda = KVM.kvm_device_attr{
            .flags = flags,
            .group = group,
            .attr = attr,
            .addr = addr,
        };
        std.log.info("setting gic attributes: {any}", .{kda});
        const r = ioctl(fd, KVM.KVM_SET_DEVICE_ATTR, @intFromPtr(&kda));
        if (r < 0) {
            std.log.err("gicv2 set addr error code: {}", .{r});
            return Gicv2Error.SetAttributes;
        }
    }
};
