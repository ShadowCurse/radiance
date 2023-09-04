const std = @import("std");
const linux = std.os.linux;

const KVM = @cImport(@cInclude("linux/kvm.h"));

const Vm = @import("vm.zig").Vm;

// ioctl in std uses c_int as a request type which is incorrect.
extern "c" fn ioctl(fd: std.os.fd_t, request: c_ulong, ...) c_int;

const VcpuError = error{
    New,
    Init,
    SetReg,
};

pub const Vcpu = struct {
    fd: std.os.fd_t,

    const Self = @This();

    pub const kvm_vcpu_init = struct {
        target: u32,
        features: [7]u32,
    };

    pub fn new(vm: *const Vm, index: u64) !Self {
        const fd = ioctl(vm.fd, KVM.KVM_CREATE_VCPU, index);
        if (fd < 0) {
            return VcpuError.New;
        }
        return Self{
            .fd = fd,
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

    pub fn set_pc(self: *const Self, pc: u64) !void {
        const offset = @offsetOf(KVM.kvm_regs, "regs") + @offsetOf(KVM.struct_user_pt_regs, "pc");
        const pc_id = KVM.KVM_REG_ARM64 | KVM.KVM_REG_SIZE_U64 | KVM.KVM_REG_ARM_CORE | offset / @sizeOf(u32);
        const kor: KVM.kvm_one_reg = .{ .id = pc_id, .addr = @intFromPtr(&pc) };
        const r = ioctl(self.fd, KVM.KVM_SET_ONE_REG, @intFromPtr(&kor));
        if (r < 0) {
            return VcpuError.SetReg;
        }
    }

    pub fn set_fdt(self: *const Self, fdt_addr: u64) !void {
        const offset = @offsetOf(KVM.kvm_regs, "regs") + @offsetOf(KVM.struct_user_pt_regs, "regs");
        const regs_id = KVM.KVM_REG_ARM64 | KVM.KVM_REG_SIZE_U64 | KVM.KVM_REG_ARM_CORE | offset;
        const kor: KVM.kvm_one_reg = .{ .id = regs_id, .addr = @intFromPtr(&fdt_addr) };
        const r = ioctl(self.fd, KVM.KVM_SET_ONE_REG, @intFromPtr(&kor));
        if (r < 0) {
            return VcpuError.SetReg;
        }
    }
};
