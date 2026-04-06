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
