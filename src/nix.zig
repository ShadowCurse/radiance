const std = @import("std");
const log = @import("log.zig");

pub const KVMIO = 0xAE;
pub const _IOC_NRBITS = 8;
pub const _IOC_TYPEBITS = 8;
pub const _IOC_SIZEBITS = 14;
pub const _IOC_DIRBITS = 2;
pub const _IOC_NRMASK = (1 << _IOC_NRBITS) - 1;
pub const _IOC_TYPEMASK = (1 << _IOC_TYPEBITS) - 1;
pub const _IOC_SIZEMASK = (1 << _IOC_SIZEBITS) - 1;
pub const _IOC_DIRMASK = (1 << _IOC_DIRBITS) - 1;
pub const _IOC_NRSHIFT = 0;
pub const _IOC_TYPESHIFT = _IOC_NRSHIFT + _IOC_NRBITS;
pub const _IOC_SIZESHIFT = _IOC_TYPESHIFT + _IOC_TYPEBITS;
pub const _IOC_DIRSHIFT = _IOC_SIZESHIFT + _IOC_SIZEBITS;
pub const _IOC_NONE = 0;
pub const _IOC_WRITE = 1;
pub const _IOC_READ = 2;

pub inline fn _IOC(
    comptime dir: u32,
    comptime @"type": u32,
    comptime nr: u32,
    comptime size: u32,
) u32 {
    return (((dir << _IOC_DIRSHIFT) |
        (@"type" << _IOC_TYPESHIFT)) |
        (nr << _IOC_NRSHIFT)) |
        (size << _IOC_SIZESHIFT);
}
pub inline fn _IO(comptime @"type": u32, comptime nr: u32) u32 {
    return _IOC(_IOC_NONE, @"type", nr, 0);
}
pub inline fn _IOR(comptime @"type": u32, comptime nr: u32, comptime arg_type: anytype) u32 {
    return _IOC(_IOC_READ, @"type", nr, @sizeOf(arg_type));
}
pub inline fn _IOW(comptime @"type": u32, comptime nr: u32, comptime arg_type: anytype) u32 {
    return _IOC(_IOC_WRITE, @"type", nr, @sizeOf(arg_type));
}
pub inline fn _IOWR(comptime @"type": u32, comptime nr: u32, comptime arg_type: anytype) u32 {
    return _IOC(_IOC_READ | _IOC_WRITE, @"type", nr, @sizeOf(arg_type));
}

pub const KVM_CREATE_VM = _IO(KVMIO, 0x01);
pub const KVM_SET_USER_MEMORY_REGION = _IOW(KVMIO, 0x46, kvm_userspace_memory_region);
pub const KVM_CREATE_VCPU = _IO(KVMIO, 0x41);
pub const KVM_GET_VCPU_MMAP_SIZE = _IO(KVMIO, 0x04);
pub const KVM_CREATE_DEVICE = _IOWR(KVMIO, 0xe0, kvm_create_device);
pub const KVM_IRQFD = _IOW(KVMIO, 0x76, kvm_irqfd);
pub const KVM_IOEVENTFD = _IOW(KVMIO, 0x79, kvm_ioeventfd);
pub const KVM_RUN = _IO(KVMIO, 0x80);
pub const KVM_GET_ONE_REG = _IOW(KVMIO, 0xab, kvm_one_reg);
pub const KVM_SET_ONE_REG = _IOW(KVMIO, 0xac, kvm_one_reg);

pub const KVM_SET_DEVICE_ATTR = _IOW(KVMIO, 0xe1, kvm_device_attr);
pub const KVM_VGIC_V2_DIST_SIZE = 0x1000;
pub const KVM_VGIC_V2_CPU_SIZE = 0x2000;
pub const KVM_VGIC_V2_ADDR_TYPE_DIST = 0;
pub const KVM_VGIC_V2_ADDR_TYPE_CPU = 1;
pub const KVM_DEV_TYPE_ARM_VGIC_V2 = 5;
pub const KVM_DEV_ARM_VGIC_GRP_ADDR = 0;
pub const KVM_DEV_ARM_VGIC_GRP_NR_IRQS = 3;
pub const KVM_DEV_ARM_VGIC_GRP_CTRL = 4;
pub const KVM_DEV_ARM_VGIC_CTRL_INIT = 0;

pub const KVM_ARM_VCPU_INIT = _IOW(KVMIO, 0xae, kvm_vcpu_init);
pub const KVM_ARM_PREFERRED_TARGET = _IOR(KVMIO, 0xaf, kvm_vcpu_init);
pub const KVM_ARM_VCPU_PSCI_0_2 = 2;
pub const KVM_ARM_VCPU_POWER_OFF = 0;

pub const KVM_REG_ARM_COPROC_SHIFT = 16;
pub const KVM_REG_SIZE_U64 = 0x0030000000000000;
pub const KVM_REG_ARM_CORE = 0x0010 << KVM_REG_ARM_COPROC_SHIFT;
pub const KVM_REG_ARM64 = 0x6000000000000000;
pub const KVM_REG_ARM64_SYSREG = 0x0013 << KVM_REG_ARM_COPROC_SHIFT;
pub const KVM_REG_ARM64_SYSREG_OP0_MASK = 0x000000000000c000;
pub const KVM_REG_ARM64_SYSREG_OP0_SHIFT = 14;
pub const KVM_REG_ARM64_SYSREG_OP1_MASK = 0x0000000000003800;
pub const KVM_REG_ARM64_SYSREG_OP1_SHIFT = 11;
pub const KVM_REG_ARM64_SYSREG_CRN_MASK = 0x0000000000000780;
pub const KVM_REG_ARM64_SYSREG_CRN_SHIFT = 7;
pub const KVM_REG_ARM64_SYSREG_CRM_MASK = 0x0000000000000078;
pub const KVM_REG_ARM64_SYSREG_CRM_SHIFT = 3;
pub const KVM_REG_ARM64_SYSREG_OP2_MASK = 0x0000000000000007;
pub const KVM_REG_ARM64_SYSREG_OP2_SHIFT = 0;

pub const KVM_EXIT_IO = 2;
pub const KVM_EXIT_HLT = 5;
pub const KVM_EXIT_MMIO = 6;
pub const KVM_EXIT_SYSTEM_EVENT = 24;
pub const KVM_SYSTEM_EVENT_SHUTDOWN = 1;
pub const KVM_SYSTEM_EVENT_RESET = 2;
pub const KVM_SYSTEM_EVENT_CRASH = 3;
pub const KVM_SYSTEM_EVENT_WAKEUP = 4;
pub const KVM_SYSTEM_EVENT_SUSPEND = 5;

pub const KVM_IOEVENTFD_FLAG_NR_DATAMATCH = 1;

pub const kvm_vcpu_init = extern struct {
    target: u32 = 0,
    features: [7]u32 = .{0} ** 7,
};

pub const kvm_userspace_memory_region = extern struct {
    slot: u32 = 0,
    flags: u32 = 0,
    guest_phys_addr: u64 = 0,
    memory_size: u64 = 0,
    userspace_addr: u64 = 0,
};

pub const kvm_create_device = extern struct {
    type: u32 = 0,
    fd: u32 = 0,
    flags: u32 = 0,
};

pub const kvm_irqfd = extern struct {
    fd: u32 = 0,
    gsi: u32 = 0,
    flags: u32 = 0,
    resamplefd: u32 = 0,
    pad: [16]u8 = .{0} ** 16,
};

pub const kvm_ioeventfd = extern struct {
    datamatch: u64 = 0,
    addr: u64 = 0,
    len: u32 = 0,
    fd: fd_t = 0,
    flags: u32 = 0,
    pad: [36]u8 = .{0} ** 36,
};

pub const kvm_device_attr = extern struct {
    flags: u32 = 0,
    group: u32 = 0,
    attr: u64 = 0,
    addr: u64 = 0,
};

pub const kvm_run = extern struct {
    request_interrupt_window: u8 = 0,
    immediate_exit: u8 = 0,
    padding1: [6]u8 = .{0} ** 6,
    exit_reason: u32 = 0,
    ready_for_interrupt_injection: u8 = 0,
    if_flag: u8 = 0,
    flags: u16 = 0,
    cr8: u64 = 0,
    apic_base: u64 = 0,
    kvm_exit_info: extern union {
        mmio: extern struct {
            phys_addr: u64 = 0,
            data: [8]u8 = 0,
            len: u32 = 0,
            is_write: u8 = 0,
        },
        system_event: extern struct {
            type: u32 = 0,
            ndata: u32 = 0,
            unnamed_0: extern union {
                flags: u64,
                data: [16]u64,
            },
        },
        padding: [256]u8,
    },
    kvm_valid_regs: u64 = 0,
    kvm_dirty_regs: u64 = 0,
    padding: [2048]u8 = .{0} ** 2048,
};

pub const kvm_one_reg = extern struct {
    id: u64 = 0,
    addr: u64 = 0,
};
pub const user_pt_regs = extern struct {
    regs: [31]u64 = .{0} ** 31,
    sp: u64 = 0,
    pc: u64 = 0,
    pstate: u64 = 0,
};
pub const user_fpsimd_state = extern struct {
    vregs: [32]u128 = .{0} ** 32,
    fpsr: u32 = 0,
    fpcr: u32 = 0,
    reserved: [2]u32 = .{0} ** 2,
};
pub const kvm_regs = extern struct {
    regs: user_pt_regs = .{},
    sp_el1: u64 = 0,
    elr_el1: u64 = 0,
    spsr: [5]u64 = 0,
    fp_regs: user_fpsimd_state = .{},
};

pub const VIRTIO_MMIO_INT_VRING = 1;
pub const VIRTIO_F_VERSION_1 = 32;
pub const VIRTIO_F_RING_PACKED = 34;
pub const VIRTIO_RING_F_EVENT_IDX = 29;
pub const VIRTIO_RING_F_INDIRECT_DESC = 28;
pub const VIRTIO_BLK_F_SEG_MAX = 2;

pub const VIRTIO_BLK_S_OK = 0;
pub const VIRTIO_BLK_F_RO = 5;
pub const VIRTIO_BLK_T_IN = 0;
pub const VIRTIO_BLK_T_OUT = 1;
pub const VIRTIO_BLK_T_FLUSH = 4;
pub const VIRTIO_BLK_T_GET_ID = 8;
pub const VIRTIO_BLK_ID_BYTES = 20;

pub const virtio_blk_outhdr = extern struct {
    type: u32 = 0,
    ioprio: u32 = 0,
    sector: u64 = 0,
};
pub const ifreq = std.posix.ifreq;
pub const IFF_TAP = 0x0002;
pub const IFF_NO_PI = 0x1000;
pub const IFF_VNET_HDR = 0x4000;
pub const TUN_F_CSUM = 0x01;
pub const TUN_F_UFO = 0x10;
pub const TUN_F_USO4 = 0x20;
pub const TUN_F_USO6 = 0x40;
pub const TUN_F_TSO4 = 0x02;
pub const TUN_F_TSO6 = 0x04;
pub const TUNSETOFFLOAD = _IOW('T', @as(c_int, 208), c_uint);
pub const TUNSETIFF = _IOW('T', @as(c_int, 202), c_int);
pub const TUNSETVNETHDRSZ = _IOW('T', @as(c_int, 216), c_int);
pub const VIRTIO_NET_F_GUEST_CSUM = 1;
pub const VIRTIO_NET_F_CSUM = 0;
pub const VIRTIO_NET_F_GUEST_TSO4 = 7;
pub const VIRTIO_NET_F_HOST_TSO4 = 11;
pub const VIRTIO_NET_F_GUEST_TSO6 = 8;
pub const VIRTIO_NET_F_HOST_TSO6 = 12;
pub const VIRTIO_NET_F_GUEST_UFO = 10;
pub const VIRTIO_NET_F_HOST_UFO = 14;
pub const VIRTIO_NET_F_GUEST_USO4 = 54;
pub const VIRTIO_NET_F_GUEST_USO6 = 55;
pub const VIRTIO_NET_F_HOST_USO = 56;
pub const VIRTIO_NET_F_MRG_RXBUF = 15;
pub const VIRTIO_NET_F_MAC = 5;

pub const virtio_net_hdr_v1 = extern struct {
    flags: u8 = 0,
    gso_type: u8 = 0,
    hdr_len: u16 = 0,
    gso_size: u16 = 0,
    unnamed_0: extern struct {
        _: u16,
        __: u16,
    },
    num_buffers: u16 = 0,
};

pub const EPOLLIN = 0x001;
pub const EPOLL_CTL_ADD = 1;
pub const EPOLL_CTL_DEL = 2;
pub const epoll_ctl = std.posix.epoll_ctl;
pub const epoll_wait = std.posix.epoll_wait;
pub const epoll_create1 = std.posix.epoll_create1;
pub const epoll_event = std.os.linux.epoll_event;

pub const VRING_DESC_F_NEXT = 1;
pub const vring_desc = extern struct {
    addr: u64 = 0,
    len: u32 = 0,
    flags: u16 = 0,
    next: u16 = 0,
};
pub const vring_avail = extern struct {
    flags: u16 align(2) = 0,
    idx: u16 = 0,
    pub fn ring(self: *const volatile vring_avail) [*]const volatile u16 {
        return @ptrCast(@alignCast(@as([*]const volatile u8, @ptrCast(self)) + 4));
    }
    pub fn used_event(self: *const volatile vring_avail, size: u16) *const volatile u16 {
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
    pub fn ring(self: *volatile vring_used) [*]volatile vring_used_elem {
        return @ptrCast(@alignCast(@as([*]volatile u8, @ptrCast(self)) + 4));
    }
    pub fn avail_event(self: *volatile vring_used, size: u16) *volatile u16 {
        return @ptrFromInt(@intFromPtr(self) + 4 + @sizeOf(vring_used_elem) * size);
    }
};

pub const VHOST_VIRTIO = 0xAF;
pub const VHOST_SET_OWNER = _IO(VHOST_VIRTIO, @as(c_int, 0x01));
pub const VHOST_SET_MEM_TABLE = _IOW(VHOST_VIRTIO, @as(c_int, 0x03), vhost_memory);
pub const VHOST_SET_FEATURES = _IOW(VHOST_VIRTIO, @as(c_int, 0x00), u64);
pub const VHOST_SET_VRING_NUM = _IOW(VHOST_VIRTIO, @as(c_int, 0x10), vhost_vring_state);
pub const VHOST_SET_VRING_CALL = _IOW(VHOST_VIRTIO, @as(c_int, 0x21), vhost_vring_file);
pub const VHOST_SET_VRING_KICK = _IOW(VHOST_VIRTIO, @as(c_int, 0x20), vhost_vring_file);
pub const VHOST_SET_VRING_ADDR = _IOW(VHOST_VIRTIO, @as(c_int, 0x11), vhost_vring_addr);
pub const VHOST_NET_SET_BACKEND = _IOW(VHOST_VIRTIO, @as(c_int, 0x30), vhost_vring_file);
pub const vhost_memory_region = extern struct {
    guest_phys_addr: u64 = 0,
    memory_size: u64 = 0,
    userspace_addr: u64 = 0,
    flags_padding: u64 = 0,
};
pub const vhost_memory = extern struct {
    nregions: u32 align(8) = 0,
    padding: u32 = 0,
    pub fn regions(self: *const vhost_memory) [*]vhost_memory_region {
        return @ptrFromInt(@intFromPtr(self) + 8);
    }
};
pub const vhost_vring_state = extern struct {
    index: u32 = 0,
    num: u32 = 0,
};
pub const vhost_vring_file = extern struct {
    index: u32 = 0,
    fd: fd_t = 0,
};
pub const vhost_vring_addr = extern struct {
    index: u32 = 0,
    flags: u32 = 0,
    desc_user_addr: u64 = 0,
    used_user_addr: u64 = 0,
    avail_user_addr: u64 = 0,
    log_guest_addr: u64 = 0,
};

pub const EFD_NONBLOCK = 0o4000;
pub const eventfd = std.posix.eventfd;

pub const getpid = std.os.linux.getpid;
pub const kill = std.os.linux.kill;
pub const SIGUSR1 = 10;

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
pub const ReadError = std.posix.ReadError;
pub const iovec = std.posix.iovec;
pub const iovec_const = std.posix.iovec_const;
pub const open = std.posix.open;
pub const close = std.posix.close;
pub const read = std.posix.read;
pub const readv = std.posix.readv;
pub const write = std.posix.write;
pub const writev = std.posix.writev;
pub const accept = std.posix.accept;
pub const errno = std.posix.errno;

pub const ioctl = std.os.linux.ioctl;

pub const MSF = std.posix.MSF;
pub const msync = std.posix.msync;

pub const Statx = std.os.linux.Statx;
pub fn statx(fd: fd_t) !Statx {
    var stx = std.mem.zeroes(Statx);
    const rcx = std.os.linux.statx(
        fd,
        "\x00",
        std.os.linux.AT.EMPTY_PATH,
        std.os.linux.STATX_TYPE |
            std.os.linux.STATX_MODE |
            std.os.linux.STATX_ATIME |
            std.os.linux.STATX_MTIME |
            std.os.linux.STATX_BTIME,
        &stx,
    );

    switch (errno(rcx)) {
        .SUCCESS => {},
        else => |e| return std.posix.unexpectedErrno(e),
    }
    return stx;
}

pub const FD_CLOEXEC = std.posix.FD_CLOEXEC;
pub const memfd_create = std.posix.memfd_create;
pub const ftruncate = std.posix.ftruncate;

fn clean_return_type(
    comptime src: std.builtin.SourceLocation,
    comptime function: anytype,
) type {
    const fn_type = @typeInfo(@TypeOf(function));
    if (fn_type.Fn.return_type) |t| {
        const return_type = @typeInfo(t);
        switch (t) {
            usize => return i32,
            else => switch (return_type) {
                .ErrorUnion => return return_type.ErrorUnion.payload,
                else => {},
            },
        }
    }
    comptime log.comptime_err(
        src,
        "Invalid type: {s} Note: nix.assert can only be called with functions returning usize or error union",
        .{
            @typeName(fn_type.Fn.return_type),
        },
    );
}

pub inline fn assert(
    comptime src: std.builtin.SourceLocation,
    comptime function: anytype,
    args: std.meta.ArgsTuple(@TypeOf(function)),
) clean_return_type(src, function) {
    const fn_type = @typeInfo(@TypeOf(function));
    const t = if (fn_type.Fn.return_type) |tt| tt else void;
    const return_type = @typeInfo(t);
    switch (return_type) {
        .ErrorUnion => {
            return @call(.always_inline, function, args) catch |e| {
                log.assert(src, false, "{}", .{e});
                unreachable;
            };
        },
        .Int => {
            const r = @call(.always_inline, function, args);
            log.assert(src, std.posix.errno(r) == .SUCCESS, "{}({})", .{
                r,
                std.posix.errno(r),
            });
            return @intCast(r);
        },
        else => comptime log.comptime_err(
            src,
            "assert can only be called with functions returning usize or error union",
            .{},
        ),
    }
}

test "test_bindings" {
    const TypeCheck = struct {
        size_of: usize,
        align_of: usize,

        const Self = @This();
        pub fn init(t: anytype) Self {
            return .{
                .size_of = @sizeOf(t),
                .align_of = @alignOf(t),
            };
        }
    };

    const C = @cImport({
        @cInclude("linux/kvm.h");
        @cInclude("linux/if.h");
        @cInclude("linux/if_tun.h");
        @cInclude("linux/vhost.h");
        @cInclude("linux/virtio_ring.h");
        @cInclude("linux/virtio_config.h");
        @cInclude("linux/virtio_blk.h");
        @cInclude("linux/virtio_net.h");
        @cInclude("linux/virtio_mmio.h");
        @cInclude("sys/epoll.h");
        @cInclude("sys/eventfd.h");
        @cInclude("fcntl.h");
        @cInclude("signal.h");
        @cInclude("pthread.h");
    });

    try std.testing.expectEqual(KVMIO, C.KVMIO);
    try std.testing.expectEqual(_IOC_NRBITS, C._IOC_NRBITS);
    try std.testing.expectEqual(_IOC_TYPEBITS, C._IOC_TYPEBITS);
    try std.testing.expectEqual(_IOC_SIZEBITS, C._IOC_SIZEBITS);
    try std.testing.expectEqual(_IOC_DIRBITS, C._IOC_DIRBITS);
    try std.testing.expectEqual(_IOC_NRMASK, C._IOC_NRMASK);
    try std.testing.expectEqual(_IOC_TYPEMASK, C._IOC_TYPEMASK);
    try std.testing.expectEqual(_IOC_SIZEMASK, C._IOC_SIZEMASK);
    try std.testing.expectEqual(_IOC_DIRMASK, C._IOC_DIRMASK);
    try std.testing.expectEqual(_IOC_NRSHIFT, C._IOC_NRSHIFT);
    try std.testing.expectEqual(_IOC_TYPESHIFT, C._IOC_TYPESHIFT);
    try std.testing.expectEqual(_IOC_SIZESHIFT, C._IOC_SIZESHIFT);
    try std.testing.expectEqual(_IOC_DIRSHIFT, C._IOC_DIRSHIFT);
    try std.testing.expectEqual(_IOC_NONE, C._IOC_NONE);
    try std.testing.expectEqual(_IOC_WRITE, C._IOC_WRITE);
    try std.testing.expectEqual(_IOC_READ, C._IOC_READ);

    try std.testing.expectEqual(KVM_CREATE_VM, C.KVM_CREATE_VM);
    try std.testing.expectEqual(KVM_SET_USER_MEMORY_REGION, C.KVM_SET_USER_MEMORY_REGION);
    try std.testing.expectEqual(KVM_CREATE_VCPU, C.KVM_CREATE_VCPU);
    try std.testing.expectEqual(KVM_GET_VCPU_MMAP_SIZE, C.KVM_GET_VCPU_MMAP_SIZE);
    try std.testing.expectEqual(KVM_CREATE_DEVICE, C.KVM_CREATE_DEVICE);
    try std.testing.expectEqual(KVM_IRQFD, C.KVM_IRQFD);
    try std.testing.expectEqual(KVM_IOEVENTFD, C.KVM_IOEVENTFD);
    try std.testing.expectEqual(KVM_RUN, C.KVM_RUN);
    try std.testing.expectEqual(KVM_GET_ONE_REG, C.KVM_GET_ONE_REG);
    try std.testing.expectEqual(KVM_SET_ONE_REG, C.KVM_SET_ONE_REG);

    try std.testing.expectEqual(KVM_SET_DEVICE_ATTR, C.KVM_SET_DEVICE_ATTR);
    try std.testing.expectEqual(KVM_VGIC_V2_DIST_SIZE, C.KVM_VGIC_V2_DIST_SIZE);
    try std.testing.expectEqual(KVM_VGIC_V2_CPU_SIZE, C.KVM_VGIC_V2_CPU_SIZE);
    try std.testing.expectEqual(KVM_VGIC_V2_ADDR_TYPE_DIST, C.KVM_VGIC_V2_ADDR_TYPE_DIST);
    try std.testing.expectEqual(KVM_VGIC_V2_ADDR_TYPE_CPU, C.KVM_VGIC_V2_ADDR_TYPE_CPU);
    try std.testing.expectEqual(KVM_DEV_TYPE_ARM_VGIC_V2, C.KVM_DEV_TYPE_ARM_VGIC_V2);
    try std.testing.expectEqual(KVM_DEV_ARM_VGIC_GRP_ADDR, C.KVM_DEV_ARM_VGIC_GRP_ADDR);
    try std.testing.expectEqual(KVM_DEV_ARM_VGIC_GRP_NR_IRQS, C.KVM_DEV_ARM_VGIC_GRP_NR_IRQS);
    try std.testing.expectEqual(KVM_DEV_ARM_VGIC_GRP_CTRL, C.KVM_DEV_ARM_VGIC_GRP_CTRL);
    try std.testing.expectEqual(KVM_DEV_ARM_VGIC_CTRL_INIT, C.KVM_DEV_ARM_VGIC_CTRL_INIT);

    // try std.testing.expectEqual(struct_user_pt_regs, C.struct_user_pt_regs);
    try std.testing.expectEqual(KVM_ARM_VCPU_INIT, C.KVM_ARM_VCPU_INIT);
    try std.testing.expectEqual(KVM_ARM_PREFERRED_TARGET, C.KVM_ARM_PREFERRED_TARGET);
    try std.testing.expectEqual(KVM_ARM_VCPU_PSCI_0_2, C.KVM_ARM_VCPU_PSCI_0_2);
    try std.testing.expectEqual(KVM_ARM_VCPU_POWER_OFF, C.KVM_ARM_VCPU_POWER_OFF);

    try std.testing.expectEqual(KVM_REG_ARM_COPROC_SHIFT, C.KVM_REG_ARM_COPROC_SHIFT);
    try std.testing.expectEqual(KVM_REG_SIZE_U64, C.KVM_REG_SIZE_U64);
    try std.testing.expectEqual(KVM_REG_ARM_CORE, C.KVM_REG_ARM_CORE);
    try std.testing.expectEqual(KVM_REG_ARM64, C.KVM_REG_ARM64);
    try std.testing.expectEqual(KVM_REG_ARM64_SYSREG, C.KVM_REG_ARM64_SYSREG);
    try std.testing.expectEqual(KVM_REG_ARM64_SYSREG_OP0_MASK, C.KVM_REG_ARM64_SYSREG_OP0_MASK);
    try std.testing.expectEqual(KVM_REG_ARM64_SYSREG_OP0_SHIFT, C.KVM_REG_ARM64_SYSREG_OP0_SHIFT);
    try std.testing.expectEqual(KVM_REG_ARM64_SYSREG_OP1_MASK, C.KVM_REG_ARM64_SYSREG_OP1_MASK);
    try std.testing.expectEqual(KVM_REG_ARM64_SYSREG_OP1_SHIFT, C.KVM_REG_ARM64_SYSREG_OP1_SHIFT);
    try std.testing.expectEqual(KVM_REG_ARM64_SYSREG_CRN_MASK, C.KVM_REG_ARM64_SYSREG_CRN_MASK);
    try std.testing.expectEqual(KVM_REG_ARM64_SYSREG_CRN_SHIFT, C.KVM_REG_ARM64_SYSREG_CRN_SHIFT);
    try std.testing.expectEqual(KVM_REG_ARM64_SYSREG_CRM_MASK, C.KVM_REG_ARM64_SYSREG_CRM_MASK);
    try std.testing.expectEqual(KVM_REG_ARM64_SYSREG_CRM_SHIFT, C.KVM_REG_ARM64_SYSREG_CRM_SHIFT);
    try std.testing.expectEqual(KVM_REG_ARM64_SYSREG_OP2_MASK, C.KVM_REG_ARM64_SYSREG_OP2_MASK);
    try std.testing.expectEqual(KVM_REG_ARM64_SYSREG_OP2_SHIFT, C.KVM_REG_ARM64_SYSREG_OP2_SHIFT);

    try std.testing.expectEqual(KVM_EXIT_IO, C.KVM_EXIT_IO);
    try std.testing.expectEqual(KVM_EXIT_HLT, C.KVM_EXIT_HLT);
    try std.testing.expectEqual(KVM_EXIT_MMIO, C.KVM_EXIT_MMIO);
    try std.testing.expectEqual(KVM_EXIT_SYSTEM_EVENT, C.KVM_EXIT_SYSTEM_EVENT);
    try std.testing.expectEqual(KVM_SYSTEM_EVENT_SHUTDOWN, C.KVM_SYSTEM_EVENT_SHUTDOWN);
    try std.testing.expectEqual(KVM_SYSTEM_EVENT_RESET, C.KVM_SYSTEM_EVENT_RESET);
    try std.testing.expectEqual(KVM_SYSTEM_EVENT_CRASH, C.KVM_SYSTEM_EVENT_CRASH);
    try std.testing.expectEqual(KVM_SYSTEM_EVENT_WAKEUP, C.KVM_SYSTEM_EVENT_WAKEUP);
    try std.testing.expectEqual(KVM_SYSTEM_EVENT_SUSPEND, C.KVM_SYSTEM_EVENT_SUSPEND);

    try std.testing.expectEqual(
        KVM_IOEVENTFD_FLAG_NR_DATAMATCH,
        1 << C.kvm_ioeventfd_flag_nr_datamatch,
    );

    try std.testing.expectEqual(
        TypeCheck.init(kvm_vcpu_init),
        TypeCheck.init(C.struct_kvm_vcpu_init),
    );
    try std.testing.expectEqual(
        TypeCheck.init(kvm_userspace_memory_region),
        TypeCheck.init(C.struct_kvm_userspace_memory_region),
    );
    try std.testing.expectEqual(
        TypeCheck.init(kvm_create_device),
        TypeCheck.init(C.struct_kvm_create_device),
    );
    try std.testing.expectEqual(TypeCheck.init(kvm_irqfd), TypeCheck.init(C.struct_kvm_irqfd));
    try std.testing.expectEqual(
        TypeCheck.init(kvm_ioeventfd),
        TypeCheck.init(C.struct_kvm_ioeventfd),
    );
    try std.testing.expectEqual(
        TypeCheck.init(kvm_device_attr),
        TypeCheck.init(C.struct_kvm_device_attr),
    );
    try std.testing.expectEqual(TypeCheck.init(kvm_run), TypeCheck.init(C.struct_kvm_run));
    try std.testing.expectEqual(TypeCheck.init(kvm_one_reg), TypeCheck.init(C.struct_kvm_one_reg));
    try std.testing.expectEqual(
        TypeCheck.init(user_pt_regs),
        TypeCheck.init(C.struct_user_pt_regs),
    );
    try std.testing.expectEqual(
        TypeCheck.init(user_fpsimd_state),
        TypeCheck.init(C.struct_user_fpsimd_state),
    );
    try std.testing.expectEqual(TypeCheck.init(kvm_regs), TypeCheck.init(C.struct_kvm_regs));

    try std.testing.expectEqual(VIRTIO_MMIO_INT_VRING, C.VIRTIO_MMIO_INT_VRING);
    try std.testing.expectEqual(VIRTIO_F_VERSION_1, C.VIRTIO_F_VERSION_1);
    try std.testing.expectEqual(VIRTIO_F_RING_PACKED, C.VIRTIO_F_RING_PACKED);
    try std.testing.expectEqual(VIRTIO_RING_F_EVENT_IDX, C.VIRTIO_RING_F_EVENT_IDX);
    try std.testing.expectEqual(VIRTIO_RING_F_INDIRECT_DESC, C.VIRTIO_RING_F_INDIRECT_DESC);

    try std.testing.expectEqual(VIRTIO_BLK_S_OK, C.VIRTIO_BLK_S_OK);
    try std.testing.expectEqual(VIRTIO_BLK_F_RO, C.VIRTIO_BLK_F_RO);
    try std.testing.expectEqual(VIRTIO_BLK_T_IN, C.VIRTIO_BLK_T_IN);
    try std.testing.expectEqual(VIRTIO_BLK_T_OUT, C.VIRTIO_BLK_T_OUT);
    try std.testing.expectEqual(VIRTIO_BLK_T_FLUSH, C.VIRTIO_BLK_T_FLUSH);
    try std.testing.expectEqual(VIRTIO_BLK_T_GET_ID, C.VIRTIO_BLK_T_GET_ID);
    try std.testing.expectEqual(VIRTIO_BLK_ID_BYTES, C.VIRTIO_BLK_ID_BYTES);

    try std.testing.expectEqual(
        TypeCheck.init(virtio_blk_outhdr),
        TypeCheck.init(C.struct_virtio_blk_outhdr),
    );

    try std.testing.expectEqual(IFF_TAP, C.IFF_TAP);
    try std.testing.expectEqual(IFF_NO_PI, C.IFF_NO_PI);
    try std.testing.expectEqual(IFF_VNET_HDR, C.IFF_VNET_HDR);
    try std.testing.expectEqual(TUN_F_CSUM, C.TUN_F_CSUM);
    try std.testing.expectEqual(TUN_F_UFO, C.TUN_F_UFO);
    try std.testing.expectEqual(TUN_F_USO4, C.TUN_F_USO4);
    try std.testing.expectEqual(TUN_F_USO6, C.TUN_F_USO6);
    try std.testing.expectEqual(TUN_F_TSO4, C.TUN_F_TSO4);
    try std.testing.expectEqual(TUN_F_TSO6, C.TUN_F_TSO6);
    try std.testing.expectEqual(TUNSETOFFLOAD, C.TUNSETOFFLOAD);
    try std.testing.expectEqual(TUNSETIFF, C.TUNSETIFF);
    try std.testing.expectEqual(TUNSETVNETHDRSZ, C.TUNSETVNETHDRSZ);
    try std.testing.expectEqual(VIRTIO_NET_F_GUEST_CSUM, C.VIRTIO_NET_F_GUEST_CSUM);
    try std.testing.expectEqual(VIRTIO_NET_F_CSUM, C.VIRTIO_NET_F_CSUM);
    try std.testing.expectEqual(VIRTIO_NET_F_GUEST_TSO4, C.VIRTIO_NET_F_GUEST_TSO4);
    try std.testing.expectEqual(VIRTIO_NET_F_HOST_TSO4, C.VIRTIO_NET_F_HOST_TSO4);
    try std.testing.expectEqual(VIRTIO_NET_F_GUEST_TSO6, C.VIRTIO_NET_F_GUEST_TSO6);
    try std.testing.expectEqual(VIRTIO_NET_F_HOST_TSO6, C.VIRTIO_NET_F_HOST_TSO6);
    try std.testing.expectEqual(VIRTIO_NET_F_GUEST_UFO, C.VIRTIO_NET_F_GUEST_UFO);
    try std.testing.expectEqual(VIRTIO_NET_F_HOST_UFO, C.VIRTIO_NET_F_HOST_UFO);
    try std.testing.expectEqual(VIRTIO_NET_F_GUEST_USO4, C.VIRTIO_NET_F_GUEST_USO4);
    try std.testing.expectEqual(VIRTIO_NET_F_GUEST_USO6, C.VIRTIO_NET_F_GUEST_USO6);
    try std.testing.expectEqual(VIRTIO_NET_F_HOST_USO, C.VIRTIO_NET_F_HOST_USO);
    try std.testing.expectEqual(VIRTIO_NET_F_MRG_RXBUF, C.VIRTIO_NET_F_MRG_RXBUF);
    try std.testing.expectEqual(VIRTIO_NET_F_MAC, C.VIRTIO_NET_F_MAC);

    try std.testing.expectEqual(
        TypeCheck.init(virtio_net_hdr_v1),
        TypeCheck.init(C.struct_virtio_net_hdr_v1),
    );

    try std.testing.expectEqual(EPOLLIN, C.EPOLLIN);
    try std.testing.expectEqual(EPOLL_CTL_ADD, C.EPOLL_CTL_ADD);
    try std.testing.expectEqual(EPOLL_CTL_DEL, C.EPOLL_CTL_DEL);

    try std.testing.expectEqual(VRING_DESC_F_NEXT, C.VRING_DESC_F_NEXT);

    try std.testing.expectEqual(TypeCheck.init(vring_desc), TypeCheck.init(C.struct_vring_desc));
    try std.testing.expectEqual(TypeCheck.init(vring_avail), TypeCheck.init(C.struct_vring_avail));
    try std.testing.expectEqual(
        TypeCheck.init(vring_used_elem),
        TypeCheck.init(C.struct_vring_used_elem),
    );
    try std.testing.expectEqual(TypeCheck.init(vring_used), TypeCheck.init(C.struct_vring_used));

    try std.testing.expectEqual(VHOST_VIRTIO, C.VHOST_VIRTIO);
    try std.testing.expectEqual(VHOST_SET_OWNER, C.VHOST_SET_OWNER);
    try std.testing.expectEqual(VHOST_SET_MEM_TABLE, C.VHOST_SET_MEM_TABLE);
    try std.testing.expectEqual(VHOST_SET_FEATURES, C.VHOST_SET_FEATURES);
    try std.testing.expectEqual(VHOST_SET_VRING_NUM, C.VHOST_SET_VRING_NUM);
    try std.testing.expectEqual(VHOST_SET_VRING_CALL, C.VHOST_SET_VRING_CALL);
    try std.testing.expectEqual(VHOST_SET_VRING_KICK, C.VHOST_SET_VRING_KICK);
    try std.testing.expectEqual(VHOST_SET_VRING_ADDR, C.VHOST_SET_VRING_ADDR);
    try std.testing.expectEqual(VHOST_NET_SET_BACKEND, C.VHOST_NET_SET_BACKEND);

    try std.testing.expectEqual(
        TypeCheck.init(vhost_memory_region),
        TypeCheck.init(C.struct_vhost_memory_region),
    );
    try std.testing.expectEqual(
        TypeCheck.init(vhost_memory),
        TypeCheck.init(C.struct_vhost_memory),
    );
    try std.testing.expectEqual(
        TypeCheck.init(vhost_vring_state),
        TypeCheck.init(C.struct_vhost_vring_state),
    );
    try std.testing.expectEqual(
        TypeCheck.init(vhost_vring_file),
        TypeCheck.init(C.struct_vhost_vring_file),
    );
    try std.testing.expectEqual(
        TypeCheck.init(vhost_vring_addr),
        TypeCheck.init(C.struct_vhost_vring_addr),
    );

    try std.testing.expectEqual(EFD_NONBLOCK, C.EFD_NONBLOCK);
}
