const nix = @import("nix.zig");
const Kvm = @import("kvm.zig");
const Memory = @import("memory.zig");

fd: nix.fd_t,
num_slots: u32,

const Self = @This();

pub fn new(comptime System: type, kvm: *const Kvm) Self {
    const fd = nix.assert(@src(), System.ioctl, .{
        kvm.fd,
        nix.KVM_CREATE_VM,
        @as(usize, 0),
    });
    return Self{
        .fd = fd,
        .num_slots = 0,
    };
}

pub fn set_memory(self: *Self, comptime System: type, memory: nix.kvm_userspace_memory_region) void {
    var memory_region = memory;
    memory_region.slot = self.num_slots;
    self.num_slots += 1;

    _ = nix.assert(@src(), System.ioctl, .{
        self.fd,
        nix.KVM_SET_USER_MEMORY_REGION,
        @intFromPtr(&memory_region),
    });
}

pub fn get_preferred_target(
    self: *const Self,
    comptime System: type,
) nix.kvm_vcpu_init {
    var kvi: nix.kvm_vcpu_init = undefined;
    _ = nix.assert(@src(), System.ioctl, .{
        self.fd,
        nix.KVM_ARM_PREFERRED_TARGET,
        @intFromPtr(&kvi),
    });
    return kvi;
}
