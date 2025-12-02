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

pub const Barrier = struct {
    generation: u32 = 0,
    arrived: u32 = 0,
    total_workers: u32 = 0,

    const Self = @This();

    pub fn wait(self: *Self) void {
        const current_gen = @atomicLoad(u32, &self.generation, .acquire);
        const old_arrived = @atomicRmw(u32, &self.arrived, .Add, 1, .acq_rel) + 1;
        if (old_arrived == self.total_workers) {
            @atomicStore(u32, &self.arrived, 0, .unordered);
            _ = @atomicRmw(u32, &self.generation, .Add, 1, .release);
        } else {
            while (@atomicLoad(u32, &self.generation, .acquire) == current_gen) {
                asm volatile ("yield" ::: .{ .memory = true });
            }
        }
    }
};
