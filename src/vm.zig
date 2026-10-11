const log = @import("log.zig");
const nix = @import("nix.zig");
const Kvm = @import("kvm.zig");
const Memory = @import("memory.zig");

fd: nix.fd_t,
num_slots: u8,

const Self = @This();

pub fn init(comptime System: type, kvm: Kvm) Self {
    const fd = nix.assert(@src(), System, "ioctl", .{ kvm.fd, nix.KVM_CREATE_VM, @as(usize, 0) });
    return Self{
        .fd = @truncate(@as(i64, @bitCast(fd))),
        .num_slots = 0,
    };
}

pub fn alloc_kvm_slot(self: *Self) u8 {
    log.assert(
        @src(),
        self.num_slots < 255,
        "Out of memory slots: {d}",
        .{self.num_slots},
    );
    const slot = self.num_slots;
    self.num_slots += 1;
    return slot;
}

pub fn set_memory(self: *const Self, comptime System: type, memory: nix.kvm_userspace_memory_region) void {
    log.assert(
        @src(),
        memory.slot < self.num_slots,
        "Memory slot: {d} is not allocated. Allocated slots: {d}",
        .{ memory.slot, self.num_slots },
    );
    _ = nix.assert(@src(), System, "ioctl", .{
        self.fd,
        nix.KVM_SET_USER_MEMORY_REGION,
        @intFromPtr(&memory),
    });
}

pub fn get_preferred_target(self: *const Self, comptime System: type) nix.kvm_vcpu_init {
    var kvi: nix.kvm_vcpu_init = undefined;
    _ = nix.assert(@src(), System, "ioctl", .{
        self.fd,
        nix.KVM_ARM_PREFERRED_TARGET,
        @intFromPtr(&kvi),
    });
    return kvi;
}

pub fn get_pit2(self: *const Self, comptime System: type, result: *nix.kvm_pit_state2) void {
    _ = nix.assert(@src(), System, "ioctl", .{
        self.fd,
        nix.KVM_GET_PIT2,
        @intFromPtr(result),
    });
}

pub fn set_pit2(self: *const Self, comptime System: type, result: *const nix.kvm_pit_state2) void {
    _ = nix.assert(@src(), System, "ioctl", .{
        self.fd,
        nix.KVM_SET_PIT2,
        @intFromPtr(result),
    });
}

pub fn get_clock(self: *const Self, comptime System: type, result: *nix.kvm_clock_data) void {
    _ = nix.assert(@src(), System, "ioctl", .{
        self.fd,
        nix.KVM_GET_CLOCK,
        @intFromPtr(result),
    });
}

pub fn set_clock(self: *const Self, comptime System: type, result: *const nix.kvm_clock_data) void {
    _ = nix.assert(@src(), System, "ioctl", .{
        self.fd,
        nix.KVM_SET_CLOCK,
        @intFromPtr(result),
    });
}

pub fn get_irqchip(self: *const Self, comptime System: type, result: *nix.kvm_irqchip) void {
    _ = nix.assert(@src(), System, "ioctl", .{
        self.fd,
        nix.KVM_GET_IRQCHIP,
        @intFromPtr(result),
    });
}

pub fn set_irqchip(self: *const Self, comptime System: type, result: *const nix.kvm_irqchip) void {
    _ = nix.assert(@src(), System, "ioctl", .{
        self.fd,
        nix.KVM_SET_IRQCHIP,
        @intFromPtr(result),
    });
}
