const std = @import("std");
const log = @import("log.zig");
const nix = @import("nix.zig");
const Kvm = @import("kvm.zig");
const Memory = @import("memory.zig");

fd: std.os.fd_t,

const Self = @This();

pub const VmError = error{
    New,
    SetMemory,
    GetPreferredTarget,
    CreateDevice,
};

pub fn new(kvm: *const Kvm) !Self {
    const fd = nix.ioctl(kvm.*.file.handle, nix.KVM_CREATE_VM, @as(usize, 0));
    if (fd < 0) {
        return VmError.New;
    } else {
        return Self{
            .fd = fd,
        };
    }
}

pub fn set_memory(self: *const Self, memory: *const Memory) !void {
    const memory_region: nix.kvm_userspace_memory_region = .{
        .slot = 0,
        .flags = 0,
        .guest_phys_addr = memory.guest_addr,
        .memory_size = @as(u64, memory.mem.len),
        .userspace_addr = @intFromPtr(memory.mem.ptr),
    };

    log.debug(@src(), "set_memory slot: {}", .{memory_region.slot});
    log.debug(@src(), "set_memory flags: {}", .{memory_region.flags});
    log.debug(@src(), "set_memory guest_phys_addr: 0x{x}", .{memory_region.guest_phys_addr});
    log.debug(@src(), "set_memory memory_size: 0x{x}", .{memory_region.memory_size});
    log.debug(@src(), "set_memory userspace_addr: 0x{x}", .{memory_region.userspace_addr});

    const r = nix.ioctl(self.fd, nix.KVM_SET_USER_MEMORY_REGION, @intFromPtr(&memory_region));
    if (r < 0) {
        return VmError.SetMemory;
    }
}

pub fn get_preferred_target(self: *const Self) !nix.kvm_vcpu_init {
    var kvi: nix.kvm_vcpu_init = undefined;
    const r = nix.ioctl(self.fd, nix.KVM_ARM_PREFERRED_TARGET, @intFromPtr(&kvi));
    if (r < 0) {
        return VmError.GetPreferredTarget;
    }
    return kvi;
}
