const std = @import("std");
const log = @import("log.zig");
const nix = @import("nix.zig");
const Kvm = @import("kvm.zig");
const Mmio = @import("mmio.zig");
const Vm = @import("vm.zig");

pub const PC = Self.core_reg_id("pc");
pub const REGS0 = Self.core_reg_id("regs");
pub const PSTATE = Self.core_reg_id("pstate");
pub const MPIDR_EL1 = Self.sys_reg_id(3, 0, 0, 0, 5);

/// PSR (Processor State Register) bits.
/// arch/arm64/include/uapi/asm/ptrace.h.
const PSR_MODE_EL1h: u64 = 0x0000_0005;
const PSR_F_BIT: u64 = 0x0000_0040;
const PSR_I_BIT: u64 = 0x0000_0080;
const PSR_A_BIT: u64 = 0x0000_0100;
const PSR_D_BIT: u64 = 0x0000_0200;
/// arch/arm64/kvm/inject_fault.c.
pub const PSTATE_FAULT_BITS_64: u64 = PSR_MODE_EL1h | PSR_A_BIT | PSR_F_BIT | PSR_I_BIT | PSR_D_BIT;

fd: std.os.fd_t,
kvm_run: *nix.kvm_run,
index: u64,
// Needed for signal handler to kick vcpu from the KVM_RUN loop
threadlocal var self_ref: ?*Self = null;

const Self = @This();

pub const VcpuError = error{
    New,
    Init,
    SetReg,
    GetReg,
    Run,
};

pub fn core_reg_id(comptime name: []const u8) u64 {
    const offset = @offsetOf(nix.kvm_regs, "regs") + @offsetOf(nix.struct_user_pt_regs, name);
    return nix.KVM_REG_ARM64 | nix.KVM_REG_SIZE_U64 | nix.KVM_REG_ARM_CORE | (offset / @sizeOf(u32));
}

pub fn sys_reg_id(op0: u64, op1: u64, crn: u64, crm: u64, op2: u64) u64 {
    return nix.KVM_REG_ARM64 | nix.KVM_REG_SIZE_U64 | nix.KVM_REG_ARM64_SYSREG | ((op0 << nix.KVM_REG_ARM64_SYSREG_OP0_SHIFT) & nix.KVM_REG_ARM64_SYSREG_OP0_MASK) | ((op1 << nix.KVM_REG_ARM64_SYSREG_OP1_SHIFT) & nix.KVM_REG_ARM64_SYSREG_OP1_MASK) | ((crn << nix.KVM_REG_ARM64_SYSREG_CRN_SHIFT) & nix.KVM_REG_ARM64_SYSREG_CRN_MASK) | ((crm << nix.KVM_REG_ARM64_SYSREG_CRM_SHIFT) & nix.KVM_REG_ARM64_SYSREG_CRM_MASK) | ((op2 << nix.KVM_REG_ARM64_SYSREG_OP2_SHIFT) & nix.KVM_REG_ARM64_SYSREG_OP2_MASK);
}

fn signal_handler(s: c_int) callconv(.C) void {
    _ = s;
    Self.self_ref.?.kvm_run.immediate_exit = 1;
}

pub fn set_thread_handler() !i32 {
    const sig = nix.__libc_current_sigrtmin();
    const sigact = nix.Sigaction{
        .handler = .{ .handler = signal_handler },
        .flags = 4,
        .mask = .{},
        .restorer = null,
    };
    try std.os.sigaction(@intCast(sig), &sigact, null);
    return sig;
}

pub fn kick_thread(thread: *const std.Thread, sig: i32) void {
    const r = nix.pthread_kill(@intFromPtr(thread.impl.handle), sig);
    log.debug(@src(), "kick_thread: {}", .{r});
}

pub fn new(kvm: *const Kvm, vm: *const Vm, index: u64) !Self {
    const fd = nix.ioctl(vm.fd, nix.KVM_CREATE_VCPU, index);
    if (fd < 0) {
        return VcpuError.New;
    }
    const vcpu_mmap_size = nix.ioctl(kvm.file.handle, nix.KVM_GET_VCPU_MMAP_SIZE, @as(u32, 0));
    if (vcpu_mmap_size <= 0) {
        return VcpuError.New;
    }

    const size: usize = @intCast(vcpu_mmap_size);
    const kvm_run = try std.os.mmap(null, size, nix.PROT.READ | nix.PROT.WRITE, nix.MAP.SHARED, fd, @as(u64, 0));
    return Self{
        .fd = fd,
        .kvm_run = @ptrCast(kvm_run.ptr),
        .index = index,
    };
}

pub fn init(self: *const Self, preferred_target: nix.kvm_vcpu_init) !void {
    var kvi = preferred_target;
    kvi.features[0] |= 1 << nix.KVM_ARM_VCPU_PSCI_0_2;
    // All vcpus are powered off except first one
    if (0 < self.index) {
        kvi.features[0] |= 1 << nix.KVM_ARM_VCPU_POWER_OFF;
    }
    const r = nix.ioctl(self.fd, nix.KVM_ARM_VCPU_INIT, @intFromPtr(&kvi));
    if (r < 0) {
        return VcpuError.Init;
    }
}

pub fn set_reg(self: *const Self, comptime t: type, reg_id: u64, value: t) !void {
    log.debug(@src(), "setting reg: 0x{x} to 0x{x}", .{ reg_id, value });
    const kor: nix.kvm_one_reg = .{ .id = reg_id, .addr = @intFromPtr(&value) };
    const r = nix.ioctl(self.fd, nix.KVM_SET_ONE_REG, @intFromPtr(&kor));
    if (r < 0) {
        return VcpuError.SetReg;
    }
}

pub fn get_reg(self: *const Self, reg_id: u64) !u64 {
    var value: u64 = undefined;
    const kor: nix.kvm_one_reg = .{ .id = reg_id, .addr = @intFromPtr(&value) };
    const r = nix.ioctl(self.fd, nix.KVM_GET_ONE_REG, @intFromPtr(&kor));
    if (r < 0) {
        return VcpuError.GetReg;
    }
    log.debug(@src(), "vcpu: get_reg: id: 0x{x}, value: 0x{x}", .{ reg_id, value });
    return value;
}

pub fn run(self: *const Self, mmio: *Mmio) !bool {
    const r = nix.ioctl(self.fd, nix.KVM_RUN, @as(u32, 0));
    // -4 == -EINTR - if vcpu was interrupted
    if (r < 0 and r != -4) {
        log.err(@src(), "vcpu run error: {}:{}", .{ r, std.c.getErrno(r) });
        return VcpuError.Run;
    }

    switch (self.kvm_run.exit_reason) {
        nix.KVM_EXIT_IO => log.info(@src(), "Got KVM_EXIT_IO", .{}),
        nix.KVM_EXIT_HLT => log.info(@src(), "Got KVM_EXIT_HLT", .{}),
        nix.KVM_EXIT_SYSTEM_EVENT => {
            switch (self.kvm_run.unnamed_0.system_event.type) {
                nix.KVM_SYSTEM_EVENT_SHUTDOWN => {
                    log.info(@src(), "Got KVM_EXIT_SYSTEM_EVENT with type: KVM_SYSTEM_EVENT_SHUTDOWN", .{});
                    return false;
                },
                nix.KVM_SYSTEM_EVENT_RESET => {
                    log.info(@src(), "Got KVM_EXIT_SYSTEM_EVENT with type: KVM_SYSTEM_EVENT_RESET", .{});
                    return false;
                },
                nix.KVM_SYSTEM_EVENT_CRASH => {
                    log.info(@src(), "Got KVM_EXIT_SYSTEM_EVENT with type: KVM_SYSTEM_EVENT_CRASH", .{});
                    return false;
                },
                nix.KVM_SYSTEM_EVENT_WAKEUP => {
                    log.info(@src(), "Got KVM_EXIT_SYSTEM_EVENT with type: KVM_SYSTEM_EVENT_WAKEUP", .{});
                },
                nix.KVM_SYSTEM_EVENT_SUSPEND => {
                    log.info(@src(), "Got KVM_EXIT_SYSTEM_EVENT with type: KVM_SYSTEM_EVENT_SUSPEND", .{});
                },
                else => |x| {
                    log.info(@src(), "Got KVM_EXIT_SYSTEM_EVENT with unknown type: {}", .{x});
                },
            }
        },
        nix.KVM_EXIT_MMIO => {
            if (self.kvm_run.unnamed_0.mmio.is_write == 1) {
                try mmio.write(self.kvm_run.unnamed_0.mmio.phys_addr, self.kvm_run.unnamed_0.mmio.data[0..self.kvm_run.unnamed_0.mmio.len]);
            } else {
                try mmio.read(self.kvm_run.unnamed_0.mmio.phys_addr, self.kvm_run.unnamed_0.mmio.data[0..self.kvm_run.unnamed_0.mmio.len]);
            }
        },
        else => |exit| log.info(@src(), "Got KVM_EXIT: {}", .{exit}),
    }
    return true;
}

pub fn run_threaded(self: *Self, barrier: *std.Thread.ResetEvent, mmio: *Mmio) !void {
    self_ref = self;
    barrier.wait();
    var r = true;
    while (r) {
        r = try self.run(mmio);
    }
    barrier.reset();
}
