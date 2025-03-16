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
