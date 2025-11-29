// More info about barriers.
// https://developer.arm.com/documentation/100941/0101/Barriers?lang=en

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

pub fn get_perf_counter() u64 {
    return asm volatile ("mrs %[ret], cntvct_el0"
        : [ret] "=r" (-> u64),
    );
}

pub fn get_perf_counter_frequency() u64 {
    return asm volatile ("mrs %[ret], cntfrq_el0"
        : [ret] "=r" (-> u64),
    );
}
