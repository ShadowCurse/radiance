const std = @import("std");
// const os = @import("os.zig");

state: std.atomic.Value(State),

const Self = @This();

pub const init: Self = .{ .state = .init(.unlocked) };

pub const State = enum(u32) {
    unlocked,
    locked_once,
    contended,
};

pub fn tryLock(m: *Self) bool {
    return m.state.cmpxchgStrong(.unlocked, .locked_once, .acquire, .monotonic) == null;
}

pub fn lock(m: *Self) void {
    const initial_state = m.state.cmpxchgStrong(
        .unlocked,
        .locked_once,
        .acquire,
        .monotonic,
    ) orelse {
        @branchHint(.likely);
        return;
    };
    if (initial_state == .contended) {
        // _ = os.futex2_wait(&m.state.raw, @intCast(@intFromEnum(State.contended))) catch unreachable;
    }
    while (m.state.swap(.contended, .acquire) != .unlocked) {
        // _ = os.futex2_wait(&m.state.raw, @intCast(@intFromEnum(State.contended))) catch unreachable;
    }
}

pub fn unlock(m: *Self) void {
    switch (m.state.swap(.unlocked, .release)) {
        .unlocked => unreachable,
        .locked_once => {},
        .contended => {
            @branchHint(.unlikely);
            // _ = os.futex2_wake(&m.state.raw, 1) catch unreachable;
        },
    }
}
