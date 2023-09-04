const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;

const KVM = @cImport(@cInclude("linux/kvm.h"));

const Kvm = @import("kvm.zig").Kvm;
const GuestMemory = @import("memory.zig").GuestMemory;
const Vcpu = @import("vcpu.zig").Vcpu;

// ioctl in std uses c_int as a request type which is incorrect.
extern "c" fn ioctl(fd: std.os.fd_t, request: c_ulong, ...) c_int;

pub const VmError = error{
    New,
    SetMemory,
    GetPreferredTarget,
    CreateDevice,
};

pub const Vm = struct {
    fd: std.os.fd_t,

    const Self = @This();

    pub fn new(kvm: *const Kvm) !Self {
        const fd = ioctl(kvm.*.file.handle, KVM.KVM_CREATE_VM, @as(usize, 0));
        if (fd < 0) {
            return VmError.New;
        } else {
            return Vm{
                .fd = fd,
            };
        }
    }

    pub fn set_memory(self: *const Self, guest_memory: *GuestMemory) !void {
        const memory_region: KVM.kvm_userspace_memory_region = .{
            .slot = 0,
            .flags = 0,
            .guest_phys_addr = guest_memory.guest_addr,
            .memory_size = @as(u64, guest_memory.mem.len),
            .userspace_addr = @intFromPtr(guest_memory.mem.ptr),
        };

        const r = ioctl(self.fd, KVM.KVM_SET_USER_MEMORY_REGION, @intFromPtr(&memory_region));
        if (r < 0) {
            return VmError.SetMemory;
        }
    }

    pub fn get_preferred_target(self: *const Self) !Vcpu.kvm_vcpu_init {
        var kvi: Vcpu.kvm_vcpu_init = undefined;
        const r = ioctl(self.fd, KVM.KVM_ARM_PREFERRED_TARGET, @intFromPtr(&kvi));
        if (r < 0) {
            return VmError.GetPreferredTarget;
        }
        return kvi;
    }
};
