const log = @import("log.zig");
const nix = @import("nix.zig");
const Vm = @import("vm.zig");
const Memory = @import("memory.zig");

// x86_64: COM1 at 0x3f8 uses IRQ 4 (standard ISA assignment)
pub const UART_IO_PORT = 0x3f8;
pub const UART_IRQ = 4;
// IRQs below 6 are hardcoded for other devices
pub const IRQ_BASE = 6;
pub const IRQ_MAX = 23;

pub const IO_APIC_DEFAULT_PHYS_BASE = 0xfec0_0000; // source: linux/arch/x86/include/asm/apicdef.h
pub const APIC_DEFAULT_PHYS_BASE = 0xfee0_0000; // source: linux/arch/x86/include/asm/apicdef.h
pub const APIC_VERSION = 0x14;

pub const STATE_BYTES = @sizeOf(nix.kvm_pit_state2) + @sizeOf(nix.kvm_clock_data) +
    3 * @sizeOf(nix.kvm_irqchip);

pub fn init(comptime System: type, vm: Vm) void {
    _ = nix.assert(@src(), System, "ioctl", .{ vm.fd, nix.KVM_CREATE_IRQCHIP, 0 });

    // If not enabled causes more KVM_IO exits for
    // 0x61 0x61 0x43 0x42 0x42 0x42 0x42 0x42 0x42 addresses
    //
    // The kernel still start without this, but logs:
    // tsc: Unable to calibrate against PIT
    // tsc: No reference (HPET/PMTIMER) available
    // tsc: Marking TSC unstable due to could not calculate TSC khz
    //
    // We need to enable the emulation of a dummy speaker port stub so that writing to port 0x61
    // (i.e. KVM_SPEAKER_BASE_ADDRESS) does not trigger an exit to user space.
    const pit_config: nix.kvm_pit_config = .{ .flags = nix.KVM_PIT_SPEAKER_DUMMY };
    _ = nix.assert(@src(), System, "ioctl", .{ vm.fd, nix.KVM_CREATE_PIT2, @intFromPtr(&pit_config) });
}

pub fn save_state(comptime System: type, vm: Vm, state: []align(8) u8) void {
    log.assert(
        @src(),
        state.len == STATE_BYTES,
        "apic state is {d} bytes long instaed of {d} bytes",
        .{ state.len, @as(u32, STATE_BYTES) },
    );
    var state_bytes: []u8 = state;

    const pit_state: *nix.kvm_pit_state2 = @ptrCast(@alignCast(state_bytes.ptr));
    state_bytes = state_bytes[@sizeOf(nix.kvm_pit_state2)..];
    vm.get_pit2(System, pit_state);

    const clock_state: *nix.kvm_clock_data = @ptrCast(@alignCast(state_bytes.ptr));
    state_bytes = state_bytes[@sizeOf(nix.kvm_clock_data)..];
    vm.get_clock(System, clock_state);

    const pic_master: *nix.kvm_irqchip = @ptrCast(@alignCast(state_bytes.ptr));
    state_bytes = state_bytes[@sizeOf(nix.kvm_irqchip)..];
    pic_master.* = .{ .chip_id = nix.KVM_IRQCHIP_PIC_MASTER };
    vm.get_irqchip(System, pic_master);

    const pic_slave: *nix.kvm_irqchip = @ptrCast(@alignCast(state_bytes.ptr));
    state_bytes = state_bytes[@sizeOf(nix.kvm_irqchip)..];
    pic_slave.* = .{ .chip_id = nix.KVM_IRQCHIP_PIC_SLAVE };
    vm.get_irqchip(System, pic_slave);

    const ioapic: *nix.kvm_irqchip = @ptrCast(@alignCast(state_bytes.ptr));
    state_bytes = state_bytes[@sizeOf(nix.kvm_irqchip)..];
    ioapic.* = .{ .chip_id = nix.KVM_IRQCHIP_IOAPIC };
    vm.get_irqchip(System, ioapic);
    log.assert(
        @src(),
        state_bytes.len == 0,
        "apic state did not consume all given bytes. Left: {d} bytes",
        .{state_bytes.len},
    );
}

pub fn restore_state(comptime System: type, vm: Vm, state: []align(8) u8) void {
    log.assert(
        @src(),
        state.len == STATE_BYTES,
        "apic state is {d} bytes long instaed of {d} bytes",
        .{ state.len, @as(u32, STATE_BYTES) },
    );
    var state_bytes: []u8 = state;

    const pit_state: *const nix.kvm_pit_state2 = @ptrCast(@alignCast(state_bytes.ptr));
    state_bytes = state_bytes[@sizeOf(nix.kvm_pit_state2)..];
    vm.set_pit2(System, pit_state);

    const clock_state: *const nix.kvm_clock_data = @ptrCast(@alignCast(state_bytes.ptr));
    state_bytes = state_bytes[@sizeOf(nix.kvm_clock_data)..];
    vm.set_clock(System, clock_state);

    const pic_master: *const nix.kvm_irqchip = @ptrCast(@alignCast(state_bytes.ptr));
    state_bytes = state_bytes[@sizeOf(nix.kvm_irqchip)..];
    vm.set_irqchip(System, pic_master);

    const pic_slave: *const nix.kvm_irqchip = @ptrCast(@alignCast(state_bytes.ptr));
    state_bytes = state_bytes[@sizeOf(nix.kvm_irqchip)..];
    vm.set_irqchip(System, pic_slave);

    const ioapic: *const nix.kvm_irqchip = @ptrCast(@alignCast(state_bytes.ptr));
    state_bytes = state_bytes[@sizeOf(nix.kvm_irqchip)..];
    vm.set_irqchip(System, ioapic);
    log.assert(
        @src(),
        state_bytes.len == 0,
        "apic state did not consume all given bytes. Left: {d} bytes",
        .{state_bytes.len},
    );
}
