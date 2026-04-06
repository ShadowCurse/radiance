const std = @import("std");
const builtin = @import("builtin");

pub const load_store_barrier = if (builtin.cpu.arch == .aarch64)
    aarch64.load_store_barrier
else if (builtin.cpu.arch == .x86_64)
    x64.noop
else
    @compileError("Only aarch64 and x64 are supported");

pub const load_barrier = if (builtin.cpu.arch == .aarch64)
    aarch64.load_barrier
else if (builtin.cpu.arch == .x86_64)
    x64.noop
else
    @compileError("Only aarch64 and x64 are supported");

pub const get_perf_counter = if (builtin.cpu.arch == .aarch64)
    aarch64.cntvct_el0
else if (builtin.cpu.arch == .x86_64)
    x64.rdtc
else
    @compileError("Only aarch64 and x64 are supported");

pub const get_perf_counter_frequency = if (builtin.cpu.arch == .aarch64)
    aarch64.cntfrq_el0
else if (builtin.cpu.arch == .x86_64)
    x64.tsc_freq
else
    @compileError("Only aarch64 and x64 are supported");

// More info about barriers.
// https://developer.arm.com/documentation/100941/0101/Barriers?lang=en
pub const aarch64 = struct {
    /// Forbids load/store ops to be reordered across this fence.
    /// Replacement for removed `@fence(.release)`
    pub inline fn load_store_barrier() void {
        asm volatile ("dmb ish");
    }

    /// Forbids load ops to be reordered across this fence.
    /// Replacement for removed `@fence(.acquire)`
    pub inline fn load_barrier() void {
        asm volatile ("dmb ishld");
    }

    pub inline fn cntvct_el0() u64 {
        return asm volatile ("mrs %[ret], cntvct_el0"
            : [ret] "=r" (-> u64),
        );
    }

    pub inline fn cntfrq_el0() u64 {
        return asm volatile ("mrs %[ret], cntfrq_el0"
            : [ret] "=r" (-> u64),
        );
    }
};

pub const x64 = struct {
    pub inline fn noop() void {}

    pub const CpuidResult = struct {
        eax: u32,
        ebx: u32,
        ecx: u32,
        edx: u32,
    };

    pub inline fn cpuid(leaf: u32, subleaf: u32) CpuidResult {
        var eax: u32 = undefined;
        var ebx: u32 = undefined;
        var ecx: u32 = undefined;
        var edx: u32 = undefined;
        asm volatile (
            \\cpuid
            : [eax] "={eax}" (eax),
              [ebx] "={ebx}" (ebx),
              [ecx] "={ecx}" (ecx),
              [edx] "={edx}" (edx),
            : [leaf] "{eax}" (leaf),
              [subleaf] "{ecx}" (subleaf),
        );
        return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
    }

    pub inline fn is_intel() bool {
        const result = cpuid(0, 0);
        // "GenuineIntel" encoded as: EBX="Genu", EDX="ineI", ECX="ntel"
        return result.ebx == 0x756e6547 and result.edx == 0x49656e69 and result.ecx == 0x6c65746e;
    }

    pub inline fn rdtc() u64 {
        var high: u64 = 0;
        var low: u64 = 0;
        asm volatile (
            \\rdtsc
            : [low] "={eax}" (low),
              [high] "={edx}" (high),
        );
        return (high << 32) | low;
    }

    pub inline fn tsc_freq() u64 {
        const s = rdtc();
        std.Thread.sleep(1000_000);
        const e = rdtc();
        return (e - s) * 1000;
    }
};

