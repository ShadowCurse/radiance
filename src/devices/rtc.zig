const std = @import("std");
const nix = @import("../nix.zig");
const log = @import("../log.zig");

// PL031 RTC
// https://developer.arm.com/documentation/ddi0224/c/Programmers-model/Summary-of-RTC-registers
const RTCDR = 0x000;
const RTCMR = 0x004;
const RTCLR = 0x008;
const RTCCR = 0x00c;
const RTCIMSC = 0x010;
const RTCRIS = 0x014;
const RTCMIS = 0x018;
const RTCICR = 0x01c;

match: u32 = 0,
load: u32 = 0,
interrupt_mask_or_clear: u32 = 0,
raw_interrupt: u32 = 0,
time_offset: u32 = 0,
// Technically wasted 4 bytes, but it makes Rtc size to be multiple of 8, so it can
// be allocated along types which are 8 bytes aligned.
_: u32 = 0,
const ID = [_]u8{ 0x31, 0x10, 0x14, 0x00, 0x0d, 0xf0, 0x05, 0xb1 };

const Self = @This();

fn now(comptime System: type) u32 {
    var tv: nix.timeval = undefined;
    System.gettimeofday(&tv, null);
    return @intCast(tv.sec);
}

pub fn write_default(self: *Self, offset: u64, data: []u8) void {
    self.write(nix.System, offset, data);
}
pub fn write(self: *Self, comptime System: type, offset: u64, data: []u8) void {
    log.assert(
        @src(),
        data.len == @sizeOf(u32),
        "Invalid RTC write data len: {d} != 4",
        .{data.len},
    );
    const val: u32 = @as(*const u32, @ptrCast(@alignCast(data.ptr))).*;

    switch (offset) {
        RTCMR => self.match = val,
        RTCLR => {
            self.load = val;
            self.time_offset = self.load - now(System);
        },
        RTCCR => {},
        RTCIMSC => self.interrupt_mask_or_clear = val & 1,
        RTCICR => self.raw_interrupt &= ~val,
        else => {
            log.assert(
                @src(),
                false,
                "Invalid rtc write: offset: 0x{x} data: 0x{x}",
                .{ offset, val },
            );
        },
    }
}

pub fn read_default(self: *Self, offset: u64, data: []u8) void {
    self.read(nix.System, offset, data);
}
pub fn read(self: *Self, comptime System: type, offset: u64, data: []u8) void {
    log.assert(
        @src(),
        data.len == @sizeOf(u32),
        "Invalid RTC write data len: {d} != 4",
        .{data.len},
    );
    const val: *u32 = @ptrCast(@alignCast(data.ptr));
    val.* = switch (offset) {
        RTCDR => now(System) + self.time_offset,
        RTCMR => self.match,
        RTCLR => self.load,
        RTCCR => 1,
        RTCIMSC => self.interrupt_mask_or_clear,
        RTCRIS => self.raw_interrupt,
        RTCMIS => self.raw_interrupt & self.interrupt_mask_or_clear,
        0xfe0...0xfff => ID[(offset - 0xfe0) >> 2],
        else => {
            log.assert(@src(), false, "Invalid rtc read: offset: 0x{x}", .{offset});
            unreachable;
        },
    };
}
