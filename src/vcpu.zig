const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig");
const nix = @import("nix.zig");
const arch = @import("arch.zig");
const profiler = @import("profiler.zig");
const memory = @import("memory.zig");
const Kvm = @import("kvm.zig");
const Mmio = @import("mmio.zig");
const Vm = @import("vm.zig");
const EventFd = @import("eventfd.zig");

pub const aarch64 = struct {
    fn core_reg_id(comptime name: []const u8) u64 {
        const offset = @offsetOf(nix.kvm_regs, "regs") + @offsetOf(nix.user_pt_regs, name);
        return nix.KVM_REG_ARM64 |
            nix.KVM_REG_SIZE_U64 |
            nix.KVM_REG_ARM_CORE |
            (offset / @sizeOf(u32));
    }

    fn core_regs_ids() [31]u64 {
        log.comptime_assert(
            @src(),
            @typeInfo(@typeInfo(nix.user_pt_regs).@"struct".fields[0].type).array.len == 31,
            "",
            .{},
        );
        var ids: [31]u64 = undefined;
        for (0..31) |i| ids[i] = core_reg_id("regs") + i * 2;
        return ids;
    }

    fn sys_reg_id(op0: u64, op1: u64, crn: u64, crm: u64, op2: u64) u64 {
        return nix.KVM_REG_ARM64 |
            nix.KVM_REG_SIZE_U64 |
            nix.KVM_REG_ARM64_SYSREG |
            ((op0 << nix.KVM_REG_ARM64_SYSREG_OP0_SHIFT) & nix.KVM_REG_ARM64_SYSREG_OP0_MASK) |
            ((op1 << nix.KVM_REG_ARM64_SYSREG_OP1_SHIFT) & nix.KVM_REG_ARM64_SYSREG_OP1_MASK) |
            ((crn << nix.KVM_REG_ARM64_SYSREG_CRN_SHIFT) & nix.KVM_REG_ARM64_SYSREG_CRN_MASK) |
            ((crm << nix.KVM_REG_ARM64_SYSREG_CRM_SHIFT) & nix.KVM_REG_ARM64_SYSREG_CRM_MASK) |
            ((op2 << nix.KVM_REG_ARM64_SYSREG_OP2_SHIFT) & nix.KVM_REG_ARM64_SYSREG_OP2_MASK);
    }

    fn fp_reg_id(comptime name: []const u8) u64 {
        const offset = @offsetOf(nix.kvm_regs, "fp_regs") + @offsetOf(nix.user_fpsimd_state, name);
        return nix.KVM_REG_ARM64 |
            nix.KVM_REG_SIZE_U128 |
            nix.KVM_REG_ARM_CORE |
            (offset / @sizeOf(u32));
    }

    fn fp_vreg_ids() [32]u64 {
        log.comptime_assert(
            @src(),
            @typeInfo(@typeInfo(nix.user_fpsimd_state).@"struct".fields[0].type).array.len == 32,
            "",
            .{},
        );
        var ids: [32]u64 = undefined;
        for (0..32) |i| ids[i] = fp_reg_id("vregs") + i * 4;
        return ids;
    }

    pub const REGS = core_regs_ids();
    pub const VREGS = fp_vreg_ids();
    pub const SP = core_reg_id("sp");
    pub const PC = core_reg_id("pc");
    pub const PSTATE = core_reg_id("pstate");
    pub const FPSR = sys_reg_id(3, 3, 4, 4, 1);
    pub const FPCR = sys_reg_id(3, 3, 4, 4, 0);
    pub const MPIDR_EL1 = sys_reg_id(3, 0, 0, 0, 5);
    pub const TTBR0_EL1 = sys_reg_id(3, 0, 2, 0, 0);
    pub const TTBR1_EL1 = sys_reg_id(3, 0, 2, 0, 1);
    pub const PTE_ADDR_MASK: u64 = 0x0000_FFFF_FFFF_F000;

    /// PSR (Processor State Register) bits.
    /// arch/arm64/include/uapi/asm/ptrace.h.
    const PSR_MODE_EL1h: u64 = 0x0000_0005;
    const PSR_F_BIT: u64 = 0x0000_0040;
    const PSR_I_BIT: u64 = 0x0000_0080;
    const PSR_A_BIT: u64 = 0x0000_0100;
    const PSR_D_BIT: u64 = 0x0000_0200;
    /// arch/arm64/kvm/inject_fault.c.
    pub const PSTATE_FAULT_BITS_64: u64 = PSR_MODE_EL1h |
        PSR_A_BIT |
        PSR_F_BIT |
        PSR_I_BIT |
        PSR_D_BIT;

    pub const REG_LIST_SIZE = 500;
    // The FAM structure will include 1 additional u64 to store the number of entries
    // in the array.
    pub const RegList = [REG_LIST_SIZE + 1]u64;
    // 4K page can hold 512 8byte registers. This should be enough to store state of vcpu
    // since KVM only has around 300 registers with sizes of 4,8,16 bytes.
    // Regs of all sizes wil be stored in a single byte slice.
    pub const PER_VCPU_REGS_BYTES = 4096;

    pub fn set_reg(
        self: *const Self,
        comptime System: type,
        comptime t: type,
        reg_id: u64,
        value: t,
    ) void {
        log.debug(@src(), "setting reg: 0x{x} to 0x{x}", .{ reg_id, value });
        const kor: nix.kvm_one_reg = .{ .id = reg_id, .addr = @intFromPtr(&value) };
        _ = nix.assert(@src(), System, "ioctl", .{
            self.fd,
            nix.KVM_SET_ONE_REG,
            @intFromPtr(&kor),
        });
    }

    pub fn get_reg(self: *const Self, comptime System: type, reg_id: u64) u64 {
        var value: u64 = undefined;
        const kor: nix.kvm_one_reg = .{ .id = reg_id, .addr = @intFromPtr(&value) };
        _ = nix.assert(@src(), System, "ioctl", .{
            self.fd,
            nix.KVM_GET_ONE_REG,
            @intFromPtr(&kor),
        });
        log.debug(@src(), "vcpu: get_reg: id: 0x{x}, value: 0x{x}", .{ reg_id, value });
        return value;
    }

    pub fn try_get_reg(self: *const Self, comptime T: type, comptime System: type, reg_id: u64) ?T {
        var value: T = undefined;
        const kor: nix.kvm_one_reg = .{ .id = reg_id, .addr = @intFromPtr(&value) };
        const r = System.ioctl(self.fd, nix.KVM_GET_ONE_REG, @intFromPtr(&kor));
        log.debug(@src(), "vcpu: get_reg: id: 0x{x}, value: 0x{x}", .{ reg_id, value });
        if (r == 0) return value else return null;
    }

    pub fn get_reg_list(self: *const Self, comptime System: type, reg_list: *RegList) void {
        reg_list[0] = REG_LIST_SIZE;
        _ = nix.assert(@src(), System, "ioctl", .{
            self.fd,
            nix.KVM_GET_REG_LIST,
            @intFromPtr(reg_list),
        });
    }

    fn reg_size(reg_id: u64) usize {
        const shift: u6 = @truncate((reg_id & nix.KVM_REG_SIZE_MASK) >> nix.KVM_REG_SIZE_SHIFT);
        return @as(usize, 1) << shift;
    }

    pub fn save_regs(
        self: *const Self,
        comptime System: type,
        reg_list: *const RegList,
        reg_bytes: []u8,
        mp_state: *nix.kvm_mp_state,
    ) usize {
        var bytes = reg_bytes;
        for (0..reg_list[0]) |i| {
            const reg_id = reg_list[1 + i];
            var value: u2048 = 0;

            const kor: nix.kvm_one_reg = .{ .id = reg_id, .addr = @intFromPtr(&value) };
            _ = nix.assert(@src(), System, "ioctl", .{
                self.fd,
                nix.KVM_GET_ONE_REG,
                @intFromPtr(&kor),
            });

            const rs = reg_size(reg_id);
            const value_bytes: []u8 = @ptrCast(&value);
            @memcpy(bytes[0..rs], value_bytes[0..rs]);
            bytes = bytes[rs..];
        }
        _ = nix.assert(@src(), System, "ioctl", .{
            self.fd,
            nix.KVM_GET_MP_STATE,
            @intFromPtr(mp_state),
        });

        return reg_bytes.len - bytes.len;
    }

    pub fn restore_regs(
        self: *const Self,
        comptime System: type,
        reg_list: *const RegList,
        reg_bytes: []const u8,
        mp_state: *const nix.kvm_mp_state,
    ) usize {
        var bytes = reg_bytes;
        for (0..reg_list[0]) |i| {
            const reg_id = reg_list[1 + i];
            var value: u2048 = 0;

            const rs = reg_size(reg_id);
            const value_bytes: []u8 = @ptrCast(&value);
            @memcpy(value_bytes[0..rs], bytes[0..rs]);
            bytes = bytes[rs..];

            const kor: nix.kvm_one_reg = .{ .id = reg_id, .addr = @intFromPtr(&value) };
            _ = nix.assert(@src(), System, "ioctl", .{
                self.fd,
                nix.KVM_SET_ONE_REG,
                @intFromPtr(&kor),
            });
        }
        _ = nix.assert(@src(), System, "ioctl", .{
            self.fd,
            nix.KVM_SET_MP_STATE,
            @intFromPtr(mp_state),
        });
        return reg_bytes.len - bytes.len;
    }
};

pub const x64 = struct {
    const x64_boot = @import("x64_boot.zig");

    const EFER_LMA = 0x400;
    const EFER_LME = 0x100;

    const X86_CR0_PE = 0x1;
    const X86_CR0_ET = 0x10;
    const X86_CR0_PG = 0x8000_0000;
    const X86_CR4_PAE = 0x20;

    const APIC_LVT0 = 0x350;
    const APIC_LVT1 = 0x360;
    const APIC_MODE_NMI = 0x4;
    const APIC_MODE_EXTINT = 0x7;

    fn kvm_segment_from_gdt(entry: x64_boot.GdtEntry, table_index: u8) nix.kvm_segment {
        const base = @as(u64, @intCast(entry.base_high)) << 24 |
            @as(u64, @intCast(entry.base_mid)) << 16 |
            entry.base_low;

        var limit = @as(u32, @intCast(entry.limit_high)) << 16 | entry.limit_low;
        if (entry.g != 0) limit = (limit << 12) | 0xFFF;

        const result: nix.kvm_segment = .{
            .base = base,
            .limit = limit,
            .selector = table_index * 8,
            .type = entry.type,
            .present = entry.p,
            .dpl = entry.dpl,
            .db = entry.db,
            .s = entry.s,
            .l = entry.l,
            .g = entry.g,
            .avl = entry.avl,
            .unusable = if (entry.p != 0) 0 else 1,
        };
        return result;
    }

    pub fn configure(
        self: *const Self,
        comptime System: type,
        index: u32,
        entry_point: u64,
        supported_cpuid: nix.kvm_cpuid2.with_entries(nix.KVM_MAX_CPUID_ENTRIES),
    ) void {
        var cpuid = supported_cpuid;
        for (cpuid.entries[0..cpuid.nent]) |*e| {
            if (e.function == 0x1) {
                // APIC ID is in bits 31:24 of EBX
                e.ebx &= 0x00ffffff;
                e.ebx |= index << 24;
            }
            // Fix extended topology leaf
            if (e.function == 0xb) {
                e.edx = index; // x2APIC ID
            }
        }
        // check arch/x86/include/asm/cpufeatures.h for filtering
        _ = nix.assert(@src(), System, "ioctl", .{ self.fd, nix.KVM_SET_CPUID2, @intFromPtr(&cpuid) });

        const MSR_IA32_SYSENTER_CS: u32 = 0x174;
        const MSR_IA32_SYSENTER_ESP: u32 = 0x175;
        const MSR_IA32_SYSENTER_EIP: u32 = 0x176;
        const MSR_STAR: u32 = 0xc0000081;
        const MSR_LSTAR: u32 = 0xc0000082;
        const MSR_CSTAR: u32 = 0xc0000083;
        const MSR_SYSCALL_MASK: u32 = 0xc0000084;
        const MSR_KERNEL_GS_BASE: u32 = 0xc0000102;
        const MSR_IA32_TSC: u32 = 0x10;

        const MSR_IA32_MISC_ENABLE: u32 = 0x1a0;
        const MSR_IA32_MISC_ENABLE_FAST_STRING: u32 = 0x1;

        const kvm_msrs: nix.kvm_msrs.with_entries(10) = .{
            .entries = .{
                .{ .index = MSR_IA32_TSC },
                .{ .index = MSR_IA32_MISC_ENABLE, .data = MSR_IA32_MISC_ENABLE_FAST_STRING },
                .{ .index = MSR_IA32_SYSENTER_CS },
                .{ .index = MSR_IA32_SYSENTER_ESP },
                .{ .index = MSR_IA32_SYSENTER_EIP },
                // x64 specific msrs, we only run on x64 not x86.
                .{ .index = MSR_STAR },
                .{ .index = MSR_CSTAR },
                .{ .index = MSR_KERNEL_GS_BASE },
                .{ .index = MSR_SYSCALL_MASK },
                .{ .index = MSR_LSTAR },
                // end of x64 specific code
            },
        };
        _ = nix.assert(@src(), System, "ioctl", .{ self.fd, nix.KVM_SET_MSRS, @intFromPtr(&kvm_msrs) });

        var kvm_regs: nix.kvm_regs = .{
            .rflags = 0x2,
            .rip = 0,
        };
        if (index == 0) {
            kvm_regs.rip = entry_point;
            kvm_regs.rsi = x64_boot.ZERO_PAGE_START;
        }
        _ = nix.assert(@src(), System, "ioctl", .{ self.fd, nix.KVM_SET_REGS, @intFromPtr(&kvm_regs) });

        const kvm_fpu: nix.kvm_fpu = .{ .fcw = 0x37f, .mxcsr = 0x1f80 };
        _ = nix.assert(@src(), System, "ioctl", .{ self.fd, nix.KVM_SET_FPU, @intFromPtr(&kvm_fpu) });

        // if (index == 0) {
        var kvm_sregs: nix.kvm_sregs = undefined;
        _ = nix.assert(@src(), System, "ioctl", .{ self.fd, nix.KVM_GET_SREGS, @intFromPtr(&kvm_sregs) });

        const code_seg = kvm_segment_from_gdt(x64_boot.GDT_TABLE[1], 1);
        const data_seg = kvm_segment_from_gdt(x64_boot.GDT_TABLE[2], 2);
        const tss_seg = kvm_segment_from_gdt(x64_boot.GDT_TABLE[3], 3);
        kvm_sregs.gdt.base = x64_boot.BOOT_GDT_OFFSET;
        kvm_sregs.gdt.limit = @sizeOf(x64_boot.GdtEntry) * x64_boot.GDT_TABLE.len - 1;
        kvm_sregs.idt.base = x64_boot.BOOT_IDT_OFFSET;
        kvm_sregs.idt.limit = @sizeOf(u64) - 1;

        kvm_sregs.cs = code_seg;
        kvm_sregs.ds = data_seg;
        kvm_sregs.es = data_seg;
        kvm_sregs.fs = data_seg;
        kvm_sregs.gs = data_seg;
        kvm_sregs.ss = data_seg;
        kvm_sregs.tr = tss_seg;

        // 64-bit protected mode
        kvm_sregs.cr0 |= X86_CR0_PE | X86_CR0_ET | X86_CR0_PG;
        kvm_sregs.cr3 = x64_boot.PML4_START;
        kvm_sregs.cr4 |= X86_CR4_PAE;
        kvm_sregs.efer |= EFER_LME | EFER_LMA;

        _ = nix.assert(@src(), System, "ioctl", .{ self.fd, nix.KVM_SET_SREGS, @intFromPtr(&kvm_sregs) });

        var kvm_lapic: nix.kvm_lapic_state = undefined;
        _ = nix.assert(@src(), System, "ioctl", .{ self.fd, nix.KVM_GET_LAPIC, @intFromPtr(&kvm_lapic) });

        var lvt_lint0: u32 = undefined;
        @memcpy(@as([]u8, @ptrCast(&lvt_lint0)), kvm_lapic.regs[APIC_LVT0..][0..4]);
        lvt_lint0 = (lvt_lint0 & ~@as(u32, 0x700)) | ((APIC_MODE_EXTINT) << 8);
        @memcpy(kvm_lapic.regs[APIC_LVT0..][0..4], @as([]u8, @ptrCast(&lvt_lint0)));

        var lvt_lint1: u32 = undefined;
        @memcpy(@as([]u8, @ptrCast(&lvt_lint1)), kvm_lapic.regs[APIC_LVT1..][0..4]);
        lvt_lint1 = (lvt_lint1 & ~@as(u32, 0x700)) | ((APIC_MODE_NMI) << 8);
        @memcpy(kvm_lapic.regs[APIC_LVT1..][0..4], @as([]u8, @ptrCast(&lvt_lint1)));

        _ = nix.assert(@src(), System, "ioctl", .{
            self.fd,
            nix.KVM_SET_LAPIC,
            @intFromPtr(&kvm_lapic),
        });
        // }
    }
};

pub const VCPU_SIGNAL = nix.SIGUSR1;

fd: nix.fd_t,
kvm_run: *nix.kvm_run,
tid: u32,
exit_event: EventFd,

const Self = @This();

fn signal_handler(s: c_int) callconv(.c) void {
    _ = s;
}

fn set_thread_handler(comptime System: type) void {
    const sigact = nix.Sigaction{
        .handler = .{ .handler = signal_handler },
        .flags = 4,
        .mask = std.mem.zeroes(nix.sigset_t),
    };
    _ = nix.assert(@src(), System, "sigaction", .{ VCPU_SIGNAL, &sigact, null });
}

pub fn pause(self: *const Self, comptime System: type) void {
    self.kvm_run.immediate_exit = 1;
    arch.load_store_barrier();
    _ = System.tkill(self.tid, VCPU_SIGNAL);
}

pub fn create(
    comptime System: type,
    vm: Vm,
    index: u64,
    exit_event: EventFd,
    vcpu_mmap_size: u32,
) Self {
    const fd = nix.assert(@src(), System, "ioctl", .{
        vm.fd,
        nix.KVM_CREATE_VCPU,
        index,
    });

    const size: usize = @intCast(vcpu_mmap_size);
    const prot = nix.PROT.READ | nix.PROT.WRITE;
    const flags = nix.MAP{
        .TYPE = .SHARED,
    };
    const kvm_run = nix.assert(@src(), System, "mmap", .{
        null,
        size,
        prot,
        flags,
        fd,
        @as(u64, 0),
    });

    return Self{
        .fd = fd,
        .kvm_run = @ptrCast(kvm_run.ptr),
        .tid = 0,
        .exit_event = exit_event,
    };
}

/// Init must be called after all vcpus have been created
pub fn init(
    self: *const Self,
    comptime System: type,
    index: u64,
    preferred_target: nix.kvm_vcpu_init,
) void {
    var kvi = preferred_target;
    kvi.features[0] |= 1 << nix.KVM_ARM_VCPU_PSCI_0_2;
    // All vcpus are powered off except first one
    if (0 < index) kvi.features[0] |= 1 << nix.KVM_ARM_VCPU_POWER_OFF;

    _ = nix.assert(
        @src(),
        System,
        "ioctl",
        .{ self.fd, nix.KVM_ARM_VCPU_INIT, @intFromPtr(&kvi) },
    );
}

pub fn run(self: *Self, comptime System: type, mmio: *Mmio) bool {
    const r = System.ioctl(self.fd, nix.KVM_RUN, @as(u32, 0));
    if (r < 0) {
        const e = nix.errno(r);
        switch (e) {
            .INTR => return false,
            else => {
                log.err(
                    @src(),
                    "[VCPU: {d}] ioctl call error: {}:{}",
                    .{ self.tid, r, e },
                );
                self.exit_event.write(System, 1);
                return false;
            },
        }
    }

    switch (self.kvm_run.exit_reason) {
        nix.KVM_EXIT_IO => {
            if (builtin.cpu.arch == .aarch64) {
                unreachable;
            } else if (builtin.cpu.arch == .x86_64) {
                const x64_io = @import("x64_io.zig");
                switch (x64_io.handle(self.kvm_run)) {
                    .handled => {},
                    .uart_read => |read| mmio.mmio_devices[Mmio.UART_INDEX].read(read[0], read[1]),
                    .uart_write => |write| mmio.mmio_devices[Mmio.UART_INDEX].write(write[0], write[1]),
                    .exit => {
                        self.exit_event.write(System, 1);
                        log.info(
                            @src(),
                            "[VCPU: {d}] Got IO reset. Shutting down",
                            .{self.tid},
                        );
                        return false;
                    },
                }
            }
        },
        nix.KVM_EXIT_DEBUG => {
            log.debug(@src(), "[VCPU: {d}] Got KVM_EXIT_DEBUG", .{self.tid});
            return false;
        },
        nix.KVM_EXIT_HLT => {
            log.info(@src(), "[VCPU: {d}] Got KVM_EXIT_HLT", .{self.tid});
            self.exit_event.write(System, 1);
            return false;
        },
        nix.KVM_EXIT_SHUTDOWN => {
            log.info(@src(), "[VCPU: {d}] Got KVM_EXIT_SHUTDOWN", .{self.tid});
            self.exit_event.write(System, 1);
            return false;
        },
        nix.KVM_EXIT_SYSTEM_EVENT => {
            switch (self.kvm_run.kvm_exit_info.system_event.type) {
                nix.KVM_SYSTEM_EVENT_SHUTDOWN => {
                    log.info(
                        @src(),
                        "[VCPU: {d}] Got KVM_EXIT_SYSTEM_EVENT with type: KVM_SYSTEM_EVENT_SHUTDOWN",
                        .{self.tid},
                    );
                    self.exit_event.write(System, 1);
                    return false;
                },
                nix.KVM_SYSTEM_EVENT_RESET => {
                    log.info(
                        @src(),
                        "[VCPU: {d}] Got KVM_EXIT_SYSTEM_EVENT with type: KVM_SYSTEM_EVENT_RESET",
                        .{self.tid},
                    );
                    self.exit_event.write(System, 1);
                    return false;
                },
                nix.KVM_SYSTEM_EVENT_CRASH => {
                    log.info(
                        @src(),
                        "[VCPU: {d}] Got KVM_EXIT_SYSTEM_EVENT with type: KVM_SYSTEM_EVENT_CRASH",
                        .{self.tid},
                    );
                    self.exit_event.write(System, 1);
                    return false;
                },
                nix.KVM_SYSTEM_EVENT_WAKEUP => {
                    log.info(
                        @src(),
                        "[VCPU: {d}] Got KVM_EXIT_SYSTEM_EVENT with type: KVM_SYSTEM_EVENT_WAKEUP",
                        .{self.tid},
                    );
                },
                nix.KVM_SYSTEM_EVENT_SUSPEND => {
                    log.info(
                        @src(),
                        "[VCPU: {d}] Got KVM_EXIT_SYSTEM_EVENT with type: KVM_SYSTEM_EVENT_SUSPEND",
                        .{self.tid},
                    );
                },
                else => |x| {
                    log.info(
                        @src(),
                        "[VCPU: {d}] Got KVM_EXIT_SYSTEM_EVENT with unknown type: {}",
                        .{ self.tid, x },
                    );
                },
            }
        },
        nix.KVM_EXIT_MMIO => {
            if (self.kvm_run.kvm_exit_info.mmio.is_write == 1) {
                mmio.write(
                    self.kvm_run.kvm_exit_info.mmio.phys_addr,
                    self.kvm_run.kvm_exit_info.mmio.data[0..self.kvm_run.kvm_exit_info.mmio.len],
                );
            } else {
                mmio.read(
                    self.kvm_run.kvm_exit_info.mmio.phys_addr,
                    self.kvm_run.kvm_exit_info.mmio.data[0..self.kvm_run.kvm_exit_info.mmio.len],
                );
            }
        },
        nix.KVM_EXIT_UNKNOWNW => log.info(
            @src(),
            "[VCPU: {d}] Got KVM_EXIT_UNKNOWNW: hardware_exit_reason: 0x{x}",
            .{ self.tid, self.kvm_run.kvm_exit_info.hw.hardware_exit_reason },
        ),
        else => |exit| {
            log.info(@src(), "[VCPU: {d}] Got unknown KVM_EXIT: {}", .{ self.tid, exit });
            return false;
        },
    }
    return true;
}

pub fn run_threaded(
    self: *Self,
    comptime System: type,
    barrier: *std.Thread.ResetEvent,
    mmio: *Mmio,
) void {
    profiler.take_thread_id();
    Self.set_thread_handler(System);
    self.tid = std.Thread.getCurrentId();
    barrier.wait();
    while (true) {
        while (self.run(System, mmio)) {}
        barrier.wait();
    }
}
