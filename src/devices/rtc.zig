const std = @import("std");
const log = @import("../log.zig");

// PL031 Real Time Clock (RTC)
// https://developer.arm.com/documentation/ddi0224/c/Programmers-model/Summary-of-RTC-registers
// Data Register (RO).
const RTCDR: u16 = 0x000;
// Match Register.
const RTCMR: u16 = 0x004;
// Load Register.
const RTCLR: u16 = 0x008;
// Control Register.
const RTCCR: u16 = 0x00C;
// Interrupt Mask Set or Clear Register.
const RTCIMSC: u16 = 0x010;
// Raw Interrupt Status (RO).
const RTCRIS: u16 = 0x014;
// Masked Interrupt Status (RO).
const RTCMIS: u16 = 0x018;
// Interrupt Clear Register (WO).
const RTCICR: u16 = 0x01C;

// The load register.
lr: u32,
// The offset applied to the counter to get the RTC value.
offset: u32,
// TODO: Implement the match register functionality.
mr: u32,
// The interrupt mask.
imsc: u32,
// The raw interrupt value.
ris: u32,

const Self = @This();

pub fn new() Self {
    return Self{
        .lr = 0,
        .offset = 0,
        .mr = 0,
        .imsc = 0,
        .ris = 0,
    };
}

fn now() u32 {
    const n = std.time.Instant.now() catch unreachable;
    return @intCast(n.timestamp.sec);
}

pub fn write(self: *Self, offset: u64, data: []u8) void {
    const val: *u32 = @alignCast(@ptrCast(data.ptr));

    switch (offset) {
        RTCMR => self.mr = val.*,
        RTCLR => {
            // The guest can make adjustments to its time by writing to
            // this register. When these adjustments happen, we calculate the
            // offset as the difference between the LR value and the host time.
            // This offset is later used to calculate the RTC value.
            self.lr = val.*;
            self.offset = self.lr - now();
        },
        RTCCR => {
            if (val.* == 1) {
                self.lr = 0;
                self.offset = 0;
            }
        },
        RTCIMSC => self.imsc = val.* & 1,
        RTCICR => {
            self.ris &= ~val.*;
        },
        else => {
            log.assert(
                @src(),
                false,
                "invalid rtc write: offset: 0x{x} data: 0x{x}",
                .{ offset, val.* },
            );
        },
    }
}

pub fn read(self: *Self, offset: u64, data: []u8) void {
    const v = switch (offset) {
        // The RTC value is the time + offset as per:
        // https://developer.arm.com/documentation/ddi0224/c/Functional-overview/RTC-functional-description/Update-block
        RTCDR => now() + self.offset,
        RTCMR => self.mr,
        RTCLR => self.lr,
        RTCCR => @as(u32, 1), // RTC is always enabled.
        RTCIMSC => self.imsc,
        RTCRIS => self.ris,
        RTCMIS => self.ris & self.imsc,
        0xFE0 => @as(u32, 0x31),
        0xFE4 => @as(u32, 0x10),
        0xFE8 => @as(u32, 0x04),
        0xFEC => @as(u32, 0x00),
        0xFF0 => @as(u32, 0x0D),
        0xFF4 => @as(u32, 0xF0),
        0xFF8 => @as(u32, 0x05),
        0xFFC => @as(u32, 0xB1),
        else => {
            log.assert(@src(), false, "invalid rtc read: offset: 0x{x}", .{offset});
            unreachable;
        },
    };

    const bytes = std.mem.asBytes(&v);
    @memcpy(data, bytes);
}
