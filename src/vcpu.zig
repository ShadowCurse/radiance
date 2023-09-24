const std = @import("std");
const linux = std.os.linux;

const KVM = @cImport(@cInclude("linux/kvm.h"));

const Kvm = @import("kvm.zig").Kvm;
const Mmio = @import("mmio.zig").Mmio;
const Vm = @import("vm.zig").Vm;

// ioctl in std uses c_int as a request type which is incorrect.
extern "c" fn ioctl(fd: std.os.fd_t, request: c_ulong, ...) c_int;

extern "c" fn __libc_current_sigrtmin() c_int;
extern "c" fn pthread_kill(thread: std.c.pthread_t, sig: i32) std.c.E;

const VcpuError = error{
    New,
    Init,
    SetReg,
    GetReg,
    Run,
};

pub fn core_reg_id(comptime name: []const u8) u64 {
    const offset = @offsetOf(KVM.kvm_regs, "regs") + @offsetOf(KVM.struct_user_pt_regs, name);
    return KVM.KVM_REG_ARM64 | KVM.KVM_REG_SIZE_U64 | KVM.KVM_REG_ARM_CORE | (offset / @sizeOf(u32));
}

pub fn sys_reg_id(op0: u64, op1: u64, crn: u64, crm: u64, op2: u64) u64 {
    return KVM.KVM_REG_ARM64 | KVM.KVM_REG_SIZE_U64 | KVM.KVM_REG_ARM64_SYSREG | ((op0 << KVM.KVM_REG_ARM64_SYSREG_OP0_SHIFT) & KVM.KVM_REG_ARM64_SYSREG_OP0_MASK) | ((op1 << KVM.KVM_REG_ARM64_SYSREG_OP1_SHIFT) & KVM.KVM_REG_ARM64_SYSREG_OP1_MASK) | ((crn << KVM.KVM_REG_ARM64_SYSREG_CRN_SHIFT) & KVM.KVM_REG_ARM64_SYSREG_CRN_MASK) | ((crm << KVM.KVM_REG_ARM64_SYSREG_CRM_SHIFT) & KVM.KVM_REG_ARM64_SYSREG_CRM_MASK) | ((op2 << KVM.KVM_REG_ARM64_SYSREG_OP2_SHIFT) & KVM.KVM_REG_ARM64_SYSREG_OP2_MASK);
}

threadlocal var v: ?*Vcpu = null;

fn signal_handler(s: c_int) callconv(.C) void {
    _ = s;
    v.?.kvm_run.immediate_exit = 1;
}

pub fn set_thread_handler() !i32 {
    const sig = __libc_current_sigrtmin();
    const sigact = std.os.linux.Sigaction{
        .handler = .{ .handler = signal_handler },
        .flags = 4,
        .mask = .{},
        .restorer = null,
    };
    try std.os.sigaction(@intCast(sig), &sigact, null);
    return sig;
}

pub fn kick_thread(thread: *const std.Thread, sig: i32) void {
    const r = pthread_kill(thread.impl.handle, sig);
    std.log.info("kick_thread: {}", .{r});
}

pub const Vcpu = struct {
    fd: std.os.fd_t,
    kvm_run: *KVM.kvm_run,

    const Self = @This();

    pub const kvm_vcpu_init = struct {
        target: u32,
        features: [7]u32,
    };

    pub const PC = core_reg_id("pc");
    pub const REGS0 = core_reg_id("regs");
    pub const PSTATE = core_reg_id("pstate");
    pub const MIDR_EL1 = sys_reg_id(3, 0, 0, 0, 5);

    /// PSR (Processor State Register) bits.
    /// Taken from arch/arm64/include/uapi/asm/ptrace.h.
    const PSR_MODE_EL1h: u64 = 0x0000_0005;
    const PSR_F_BIT: u64 = 0x0000_0040;
    const PSR_I_BIT: u64 = 0x0000_0080;
    const PSR_A_BIT: u64 = 0x0000_0100;
    const PSR_D_BIT: u64 = 0x0000_0200;
    /// Taken from arch/arm64/kvm/inject_fault.c.
    pub const PSTATE_FAULT_BITS_64: u64 = PSR_MODE_EL1h | PSR_A_BIT | PSR_F_BIT | PSR_I_BIT | PSR_D_BIT;

    pub fn new(kvm: *const Kvm, vm: *const Vm, index: u64) !Self {
        const fd = ioctl(vm.fd, KVM.KVM_CREATE_VCPU, index);
        if (fd < 0) {
            return VcpuError.New;
        }
        const vcpu_mmap_size = ioctl(kvm.file.handle, KVM.KVM_GET_VCPU_MMAP_SIZE, @as(u32, 0));
        if (vcpu_mmap_size <= 0) {
            return VcpuError.New;
        }

        const size: usize = @intCast(vcpu_mmap_size);
        const kvm_run = try std.os.mmap(null, size, linux.PROT.READ | linux.PROT.WRITE, linux.MAP.SHARED, fd, @as(u64, 0));
        return Self{
            .fd = fd,
            .kvm_run = @ptrCast(kvm_run.ptr),
        };
    }

    pub fn init(self: *const Self, preferred_target: Self.kvm_vcpu_init) !void {
        var kvi = preferred_target;
        kvi.features[0] |= 1 << KVM.KVM_ARM_VCPU_PSCI_0_2;
        const r = ioctl(self.fd, KVM.KVM_ARM_VCPU_INIT, @intFromPtr(&kvi));
        if (r < 0) {
            return VcpuError.Init;
        }
    }

    pub fn set_reg(self: *const Self, comptime t: type, reg_id: u64, value: t) !void {
        std.log.info("setting reg: 0x{x} to 0x{x}", .{ reg_id, value });
        const kor: KVM.kvm_one_reg = .{ .id = reg_id, .addr = @intFromPtr(&value) };
        const r = ioctl(self.fd, KVM.KVM_SET_ONE_REG, @intFromPtr(&kor));
        if (r < 0) {
            return VcpuError.SetReg;
        }
    }

    pub fn get_reg(self: *const Self, reg_id: u64) !u64 {
        var value: u64 = undefined;
        const kor: KVM.kvm_one_reg = .{ .id = reg_id, .addr = @intFromPtr(&value) };
        const r = ioctl(self.fd, KVM.KVM_GET_ONE_REG, @intFromPtr(&kor));
        if (r < 0) {
            return VcpuError.GetReg;
        }
        std.log.debug("vcpu: get_reg: id: 0x{x}, value: 0x{x}", .{ reg_id, value });
        return value;
    }

    pub fn run(self: *const Self, mmio: *Mmio) !void {
        const r = ioctl(self.fd, KVM.KVM_RUN, @as(u32, 0));
        // -4 == -EINTR - if vcpu was interrupted
        if (r < 0 and r != -4) {
            std.log.err("vcpu run error: {}:{}", .{ r, std.c.getErrno(r) });
            return VcpuError.Run;
        }

        switch (self.kvm_run.exit_reason) {
            KVM.KVM_EXIT_IO => std.log.info("Got KVM_EXIT_IO", .{}),
            KVM.KVM_EXIT_HLT => std.log.info("Got KVM_EXIT_HLT", .{}),
            KVM.KVM_EXIT_MMIO => {
                if (self.kvm_run.unnamed_0.mmio.is_write == 1) {
                    try mmio.write(self.kvm_run.unnamed_0.mmio.phys_addr, self.kvm_run.unnamed_0.mmio.data[0..self.kvm_run.unnamed_0.mmio.len]);
                } else {
                    try mmio.read(self.kvm_run.unnamed_0.mmio.phys_addr, self.kvm_run.unnamed_0.mmio.data[0..self.kvm_run.unnamed_0.mmio.len]);
                }
            },
            else => |exit| std.log.info("Got KVM_EXIT: {}", .{exit}),
        }
    }

    pub fn run_threaded(self: *Self, mmio: *Mmio) !void {
        v = self;
        std.log.info("vcpu run", .{});
        while (true) {
            try self.run(mmio);
        }
    }
};
