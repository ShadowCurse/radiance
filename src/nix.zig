const std = @import("std");
const log = @import("log.zig");
const C = @cImport({
    @cInclude("linux/kvm.h");
    @cInclude("linux/if.h");
    @cInclude("linux/if_tun.h");
    @cInclude("linux/vhost.h");
    @cInclude("linux/virtio_ring.h");
    @cInclude("linux/virtio_config.h");
    @cInclude("linux/virtio_blk.h");
    @cInclude("linux/virtio_net.h");
    @cInclude("sys/epoll.h");
    @cInclude("sys/eventfd.h");
    @cInclude("fcntl.h");
    @cInclude("signal.h");
    @cInclude("pthread.h");
});

pub const KVM_CREATE_VM = C.KVM_CREATE_VM;
pub const KVM_SET_USER_MEMORY_REGION = C.KVM_SET_USER_MEMORY_REGION;
pub const KVM_CREATE_VCPU = C.KVM_CREATE_VCPU;
pub const KVM_GET_VCPU_MMAP_SIZE = C.KVM_GET_VCPU_MMAP_SIZE;
pub const KVM_CREATE_DEVICE = C.KVM_CREATE_DEVICE;
pub const KVM_IRQFD = C.KVM_IRQFD;
pub const KVM_IOEVENTFD = C.KVM_IOEVENTFD;
pub const KVM_RUN = C.KVM_RUN;
pub const KVM_GET_ONE_REG = C.KVM_GET_ONE_REG;
pub const KVM_SET_ONE_REG = C.KVM_SET_ONE_REG;

pub const KVM_REG_SIZE_U64 = C.KVM_REG_SIZE_U64;
pub const KVM_REG_ARM_CORE = C.KVM_REG_ARM_CORE;
pub const KVM_REG_ARM64 = C.KVM_REG_ARM64;
pub const KVM_REG_ARM64_SYSREG = C.KVM_REG_ARM64_SYSREG;

pub const KVM_SET_DEVICE_ATTR = C.KVM_SET_DEVICE_ATTR;
pub const KVM_VGIC_V2_DIST_SIZE = C.KVM_VGIC_V2_DIST_SIZE;
pub const KVM_VGIC_V2_CPU_SIZE = C.KVM_VGIC_V2_CPU_SIZE;
pub const KVM_VGIC_V2_ADDR_TYPE_DIST = C.KVM_VGIC_V2_ADDR_TYPE_DIST;
pub const KVM_VGIC_V2_ADDR_TYPE_CPU = C.KVM_VGIC_V2_ADDR_TYPE_CPU;
pub const KVM_DEV_TYPE_ARM_VGIC_V2 = C.KVM_DEV_TYPE_ARM_VGIC_V2;
pub const KVM_DEV_ARM_VGIC_GRP_ADDR = C.KVM_DEV_ARM_VGIC_GRP_ADDR;
pub const KVM_DEV_ARM_VGIC_GRP_NR_IRQS = C.KVM_DEV_ARM_VGIC_GRP_NR_IRQS;
pub const KVM_DEV_ARM_VGIC_GRP_CTRL = C.KVM_DEV_ARM_VGIC_GRP_CTRL;
pub const KVM_DEV_ARM_VGIC_CTRL_INIT = C.KVM_DEV_ARM_VGIC_CTRL_INIT;

pub const struct_user_pt_regs = C.struct_user_pt_regs;
pub const KVM_ARM_VCPU_INIT = C.KVM_ARM_VCPU_INIT;
pub const KVM_ARM_PREFERRED_TARGET = C.KVM_ARM_PREFERRED_TARGET;
pub const KVM_ARM_VCPU_PSCI_0_2 = C.KVM_ARM_VCPU_PSCI_0_2;
pub const KVM_ARM_VCPU_POWER_OFF = C.KVM_ARM_VCPU_POWER_OFF;
pub const KVM_REG_ARM64_SYSREG_OP0_MASK = C.KVM_REG_ARM64_SYSREG_OP0_MASK;
pub const KVM_REG_ARM64_SYSREG_OP0_SHIFT = C.KVM_REG_ARM64_SYSREG_OP0_SHIFT;
pub const KVM_REG_ARM64_SYSREG_OP1_MASK = C.KVM_REG_ARM64_SYSREG_OP1_MASK;
pub const KVM_REG_ARM64_SYSREG_OP1_SHIFT = C.KVM_REG_ARM64_SYSREG_OP1_SHIFT;
pub const KVM_REG_ARM64_SYSREG_CRN_MASK = C.KVM_REG_ARM64_SYSREG_CRN_MASK;
pub const KVM_REG_ARM64_SYSREG_CRN_SHIFT = C.KVM_REG_ARM64_SYSREG_CRN_SHIFT;
pub const KVM_REG_ARM64_SYSREG_CRM_MASK = C.KVM_REG_ARM64_SYSREG_CRM_MASK;
pub const KVM_REG_ARM64_SYSREG_CRM_SHIFT = C.KVM_REG_ARM64_SYSREG_CRM_SHIFT;
pub const KVM_REG_ARM64_SYSREG_OP2_MASK = C.KVM_REG_ARM64_SYSREG_OP2_MASK;
pub const KVM_REG_ARM64_SYSREG_OP2_SHIFT = C.KVM_REG_ARM64_SYSREG_OP2_SHIFT;

pub const KVM_EXIT_IO = C.KVM_EXIT_IO;
pub const KVM_EXIT_HLT = C.KVM_EXIT_HLT;
pub const KVM_EXIT_MMIO = C.KVM_EXIT_MMIO;
pub const KVM_EXIT_SYSTEM_EVENT = C.KVM_EXIT_SYSTEM_EVENT;
pub const KVM_SYSTEM_EVENT_SHUTDOWN = C.KVM_SYSTEM_EVENT_SHUTDOWN;
pub const KVM_SYSTEM_EVENT_RESET = C.KVM_SYSTEM_EVENT_RESET;
pub const KVM_SYSTEM_EVENT_CRASH = C.KVM_SYSTEM_EVENT_CRASH;
pub const KVM_SYSTEM_EVENT_WAKEUP = C.KVM_SYSTEM_EVENT_WAKEUP;
pub const KVM_SYSTEM_EVENT_SUSPEND = C.KVM_SYSTEM_EVENT_SUSPEND;

pub const kvm_run = C.kvm_run;
pub const kvm_regs = C.kvm_regs;
pub const kvm_irqfd = C.kvm_irqfd;
pub const kvm_one_reg = C.kvm_one_reg;
pub const kvm_vcpu_init = C.kvm_vcpu_init;
pub const kvm_ioeventfd = C.kvm_ioeventfd;
pub const kvm_device_attr = C.kvm_device_attr;
pub const kvm_create_device = C.kvm_create_device;
pub const kvm_userspace_memory_region = C.kvm_userspace_memory_region;
pub const kvm_ioeventfd_flag_nr_datamatch = C.kvm_ioeventfd_flag_nr_datamatch;

pub const EFD_NONBLOCK = C.EFD_NONBLOCK;
pub const eventfd = C.eventfd;

pub const VIRTIO_F_VERSION_1 = C.VIRTIO_F_VERSION_1;
pub const VIRTIO_RING_F_EVENT_IDX = C.VIRTIO_RING_F_EVENT_IDX;
pub const VIRTIO_RING_F_INDIRECT_DESC = C.VIRTIO_RING_F_INDIRECT_DESC;

pub const VIRTIO_BLK_S_OK = C.VIRTIO_BLK_S_OK;
pub const VIRTIO_BLK_F_RO = C.VIRTIO_BLK_F_RO;
pub const VIRTIO_BLK_T_IN = C.VIRTIO_BLK_T_IN;
pub const VIRTIO_BLK_T_OUT = C.VIRTIO_BLK_T_OUT;
pub const VIRTIO_BLK_T_FLUSH = C.VIRTIO_BLK_T_FLUSH;
pub const VIRTIO_BLK_T_GET_ID = C.VIRTIO_BLK_T_GET_ID;
pub const VIRTIO_BLK_ID_BYTES = C.VIRTIO_BLK_ID_BYTES;
pub const virtio_blk_outhdr = C.virtio_blk_outhdr;

pub const ifreq = C.ifreq;
pub const IFF_TAP = C.IFF_TAP;
pub const IFF_NO_PI = C.IFF_NO_PI;
pub const IFF_VNET_HDR = C.IFF_VNET_HDR;
pub const TUN_F_CSUM = C.TUN_F_CSUM;
pub const TUN_F_UFO = C.TUN_F_UFO;
pub const TUN_F_TSO4 = C.TUN_F_TSO4;
pub const TUN_F_TSO6 = C.TUN_F_TSO6;
pub const TUNSETOFFLOAD = C.TUNSETOFFLOAD;
pub const TUNSETIFF = C.TUNSETIFF;
pub const TUNSETVNETHDRSZ = C.TUNSETVNETHDRSZ;
pub const VIRTIO_NET_F_GUEST_CSUM = C.VIRTIO_NET_F_GUEST_CSUM;
pub const VIRTIO_NET_F_CSUM = C.VIRTIO_NET_F_CSUM;
pub const VIRTIO_NET_F_GUEST_TSO4 = C.VIRTIO_NET_F_GUEST_TSO4;
pub const VIRTIO_NET_F_HOST_TSO4 = C.VIRTIO_NET_F_HOST_TSO4;
pub const VIRTIO_NET_F_GUEST_TSO6 = C.VIRTIO_NET_F_GUEST_TSO6;
pub const VIRTIO_NET_F_HOST_TSO6 = C.VIRTIO_NET_F_HOST_TSO6;
pub const VIRTIO_NET_F_HOST_USO = C.VIRTIO_NET_F_HOST_USO;
pub const VIRTIO_NET_F_MRG_RXBUF = C.VIRTIO_NET_F_MRG_RXBUF;
pub const VIRTIO_NET_F_MAC = C.VIRTIO_NET_F_MAC;
pub const VIRTIO_NET_F_GUEST_UFO = C.VIRTIO_NET_F_GUEST_UFO;
pub const virtio_net_hdr_v1 = C.virtio_net_hdr_v1;

pub const EPOLLIN = C.EPOLLIN;
pub const EPOLL_CTL_ADD = C.EPOLL_CTL_ADD;
pub const EPOLL_CTL_DEL = C.EPOLL_CTL_DEL;
pub const epoll_ctl = C.epoll_ctl;
pub const epoll_wait = C.epoll_wait;
pub const epoll_create1 = C.epoll_create1;
pub const epoll_event = C.epoll_event;

pub const vring_desc = extern struct {
    addr: u64 = 0,
    len: u32 = 0,
    flags: u16 = 0,
    next: u16 = 0,
};
pub const vring_avail = extern struct {
    flags: u16 align(2) = 0,
    idx: u16 = 0,
    pub fn ring(self: *const vring_avail) @import("std").zig.c_translation.FlexibleArrayType(@TypeOf(self), c_ushort) {
        const Intermediate = @import("std").zig.c_translation.FlexibleArrayType(@TypeOf(self), u8);
        const ReturnType = @import("std").zig.c_translation.FlexibleArrayType(@TypeOf(self), c_ushort);
        return @as(ReturnType, @ptrCast(@alignCast(@as(Intermediate, @ptrCast(self)) + 4)));
    }
    pub fn used_event(self: *const vring_avail, size: u16) *const u16 {
        return @ptrFromInt(@intFromPtr(self) + 4 + @sizeOf(u16) * size);
    }
};
pub const vring_used_elem = extern struct {
    id: u32 = 0,
    len: u32 = 0,
};
pub const vring_used = extern struct {
    flags: u16 align(4) = 0,
    idx: u16 = 0,
    pub fn ring(self: *vring_used) @import("std").zig.c_translation.FlexibleArrayType(@TypeOf(self), vring_used_elem) {
        const Intermediate = @import("std").zig.c_translation.FlexibleArrayType(@TypeOf(self), u8);
        const ReturnType = @import("std").zig.c_translation.FlexibleArrayType(@TypeOf(self), vring_used_elem);
        return @as(ReturnType, @ptrCast(@alignCast(@as(Intermediate, @ptrCast(self)) + 4)));
    }
    pub fn avail_event(self: *vring_used, size: u16) *u16 {
        return @ptrFromInt(@intFromPtr(self) + 4 + @sizeOf(vring_used_elem) * size);
    }
};

pub const VRING_DESC_F_NEXT = C.VRING_DESC_F_NEXT;

pub const VHOST_SET_OWNER = C.VHOST_SET_OWNER;
pub const VHOST_SET_MEM_TABLE = C.VHOST_SET_MEM_TABLE;
pub const VHOST_SET_FEATURES = C.VHOST_SET_FEATURES;
pub const VHOST_SET_VRING_NUM = C.VHOST_SET_VRING_NUM;
pub const VHOST_SET_VRING_CALL = C.VHOST_SET_VRING_CALL;
pub const VHOST_SET_VRING_KICK = C.VHOST_SET_VRING_KICK;
pub const VHOST_SET_VRING_ADDR = C.VHOST_SET_VRING_ADDR;
pub const VHOST_NET_SET_BACKEND = C.VHOST_NET_SET_BACKEND;
pub const vhost_memory = C.vhost_memory;
pub const vhost_memory_region = C.vhost_memory_region;
pub const vhost_vring_file = C.vhost_vring_file;
pub const vhost_vring_state = C.vhost_vring_state;
pub const vhost_vring_addr = C.vhost_vring_addr;

pub const pthread_kill = C.pthread_kill;
pub const __libc_current_sigrtmin = C.__libc_current_sigrtmin;

pub const PROT = std.os.linux.PROT;
pub const MAP = std.os.linux.MAP;
pub const MAP_TYPE = std.os.linux.MAP_TYPE;
pub const Sigaction = std.os.linux.Sigaction;
pub const sigset_t = std.os.linux.sigset_t;
pub const tcgetattr = std.os.linux.tcgetattr;
pub const tcsetattr = std.os.linux.tcsetattr;
pub const TCSA = std.os.linux.TCSA;
pub const termios = std.posix.termios;
pub const mmap = std.posix.mmap;
pub const munmap = std.posix.munmap;
pub const sigaction = std.posix.sigaction;
pub const fd_t = std.posix.fd_t;
pub const socklen_t = std.posix.socklen_t;
pub const STDIN_FILENO = std.posix.STDIN_FILENO;
pub const STDOUT_FILENO = std.posix.STDOUT_FILENO;
pub const SOCK = std.posix.SOCK;
pub const close = std.posix.close;
pub const read = std.posix.read;
pub const write = std.posix.write;
pub const accept = std.posix.accept;

// ioctl in std uses c_int as a request type which is incorrect.
pub extern "c" fn ioctl(fd: fd_t, request: c_ulong, ...) c_int;

pub fn checked_ioctl(
    comptime src: std.builtin.SourceLocation,
    comptime err: anyerror,
    fd: fd_t,
    request: c_ulong,
    arg: anytype,
) !c_int {
    const r = ioctl(fd, request, arg);
    if (r < 0) {
        log.err(src, "ioctl call error: {}:{}", .{ r, std.posix.errno(r) });
        return err;
    } else {
        return r;
    }
}
