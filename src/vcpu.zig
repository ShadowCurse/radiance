const std = @import("std");
const linux = std.os.linux;

const KVM = @cImport(@cInclude("linux/kvm.h"));

const Kvm = @import("kvm.zig").Kvm;
const Vm = @import("vm.zig").Vm;

// ioctl in std uses c_int as a request type which is incorrect.
extern "c" fn ioctl(fd: std.os.fd_t, request: c_ulong, ...) c_int;

const VcpuError = error{
    New,
    Init,
    SetReg,
    Run,
};

pub const Vcpu = struct {
    fd: std.os.fd_t,
    kvm_run: *KVM.kvm_run,

    const Self = @This();

    pub const kvm_vcpu_init = struct {
        target: u32,
        features: [7]u32,
    };

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

    pub fn run(self: *const Self) !void {
        const r = ioctl(self.fd, KVM.KVM_RUN, @as(u32, 0));
        if (r < 0) {
            std.log.err("vcpu run error: {}", .{std.c.getErrno(r)});
            return VcpuError.Run;
        }

        switch (self.kvm_run.exit_reason) {
            else => |exit| std.log.info("Got KVM_EXIT: {}", .{exit}),
        }
    }
};
