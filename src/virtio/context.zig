const std = @import("std");
const nix = @import("../nix.zig");
const log = @import("../log.zig");

const Queue = @import("queue.zig").Queue;
const EventFd = @import("eventfd.zig");

pub const INIT: u32 = 0;
pub const ACKNOWLEDGE: u32 = 1;
pub const DRIVER: u32 = 2;
pub const FAILED: u32 = 128;
pub const FEATURES_OK: u32 = 8;
pub const DRIVER_OK: u32 = 4;
pub const DEVICE_NEEDS_RESET: u32 = 64;

pub const VENDOR_ID: u32 = 0;

/// Interrupt flags (re: interrupt status & acknowledge registers).
/// See linux/virtio_mmio.h.
pub const VIRTIO_MMIO_INT_VRING: u32 = 0x01;
pub const VIRTIO_MMIO_INT_CONFIG: u32 = 0x02;

// required by the virtio mmio device register layout at offset 0 from base
pub const MMIO_MAGIC_VALUE: u32 = 0x7472_6976;

// current version specified by the mmio standard (legacy devices used 1 here)
pub const MMIO_VERSION: u32 = 2;

pub const VirtioAction = enum {
    NoAction,
    ActivateDevice,
    ResetDevice,
    ConfigRead,
    ConfigWrite,
};

pub fn VirtioContext(comptime config_type: type) type {
    return struct {
        // Selects a set of 32 device feature bits
        // accessible by reading from DeviceFeatures
        device_features_word: u32,
        avail_features: u64,

        driver_features_word: u32,
        acked_features: u64,

        device_type: u32,
        device_status: u32,
        interrupt_status: u32,

        config_blob: config_type,
        config_generation: u32,

        selected_queue: u32,
        queue: Queue,
        queue_event: EventFd,

        irq_status: std.atomic.Atomic(u32),
        irq_evt: EventFd,

        const Self = @This();

        pub fn new(device_type: u32) !Self {
            return Self{
                .device_features_word = 0,
                .avail_features = 0,
                .driver_features_word = 0,
                .acked_features = 0,

                .device_type = device_type,
                .device_status = 0,
                .interrupt_status = 0,

                .config_blob = undefined,
                .config_generation = 0,

                .selected_queue = 0,
                .queue = Queue.new(),
                .queue_event = try EventFd.new(0, nix.EFD_NONBLOCK),

                .irq_status = std.atomic.Atomic(u32).init(0),
                .irq_evt = try EventFd.new(0, nix.EFD_NONBLOCK),
            };
        }

        fn update_device_status(self: *Self, status: u32) ?VirtioAction {
            const changed_bit = ~self.device_status & status;
            log.info(@src(), "changin device status: {}", .{changed_bit});
            switch (changed_bit) {
                ACKNOWLEDGE => if (self.device_status == INIT) {
                    self.device_status = status;
                },
                DRIVER => if (self.device_status == ACKNOWLEDGE) {
                    self.device_status = status;
                },
                FEATURES_OK => if (self.device_status == (ACKNOWLEDGE | DRIVER)) {
                    self.device_status = status;
                },
                DRIVER_OK => if (self.device_status == (ACKNOWLEDGE | DRIVER | FEATURES_OK)) {
                    self.device_status = status;
                    return VirtioAction.ActivateDevice;
                },
                DEVICE_NEEDS_RESET => {
                    self.device_status = status;
                    return VirtioAction.ResetDevice;
                },
                else => {
                    log.warn(@src(), "invalid virtio driver status transition: 0x{x} => 0x{x}", .{ self.device_status, status });
                },
            }
        }

        pub fn read(self: *Self, offset: u64, data: []u8) VirtioAction {
            const data_u32: *u32 = @ptrCast(@alignCast(data.ptr));
            switch (offset) {
                0x0 => data_u32.* = MMIO_MAGIC_VALUE,
                0x04 => data_u32.* = MMIO_VERSION,
                0x08 => data_u32.* = self.device_type,
                0x0c => data_u32.* = VENDOR_ID,
                0x10 => {
                    const features =
                        switch (self.device_features_word) {
                        // Get the lower 32-bits of the features bitfield.
                        0 => (self.avail_features & 0xFFFFFFFF),
                        // Get the upper 32-bits of the features bitfield.
                        1 => self.avail_features >> 32,
                        else => unreachable,
                    };
                    const features_u32: u32 = @truncate(features);
                    data_u32.* = features_u32;
                },
                0x34 => data_u32.* = Queue.MAX_SIZE,
                0x44 => data_u32.* = @intFromBool(self.queue.ready),
                0x60 => {
                    data_u32.* = self.interrupt_status;
                },
                0x70 => data_u32.* = self.device_status,
                0xfc => data_u32.* = self.config_generation,
                0x100...0xfff => {
                    const new_offset = offset - 0x100;
                    const config_blob_slice = std.mem.asBytes(&self.config_blob);
                    @memcpy(data, config_blob_slice[new_offset .. new_offset + data.len]);
                    return VirtioAction.ConfigRead;
                },
                else => {
                    log.warn(@src(), "invalid virtio read: offset: 0x{x}, data: {any}", .{ offset, data });
                },
            }
            return VirtioAction.NoAction;
        }

        pub fn write(self: *Self, offset: u64, data: []u8) VirtioAction {
            const data_u32: *u32 = @ptrCast(@alignCast(data.ptr));
            switch (offset) {
                0x14 => self.device_features_word = data_u32.*,
                0x20 => {
                    const value_u32 = data_u32.*;

                    // TODO why shifting by 32 does not work
                    var shifted = value_u32 << 16;
                    shifted = shifted << 16;

                    switch (self.driver_features_word) {
                        // Set the lower 32-bits of the features bitfield.
                        0 => self.avail_features = (self.avail_features & 0xffff_ffff_0000_0000) & value_u32,
                        // Set the upper 32-bits of the features bitfield.
                        1 => self.avail_features = (self.avail_features & 0x0000_0000_ffff_ffff) & shifted,
                        else => unreachable,
                    }
                },
                0x24 => self.driver_features_word = data_u32.*,
                0x30 => self.selected_queue = data_u32.*,
                0x38 => self.queue.size = data_u32.*,
                0x44 => self.queue.ready = data_u32.* == 1,
                0x64 => {
                    self.interrupt_status &= ~data_u32.*;
                },
                0x70 => self.device_status = data_u32.*,
                0x80 => self.queue.set_desc_table(false, data_u32.*),
                0x84 => self.queue.set_desc_table(true, data_u32.*),
                0x90 => self.queue.set_avail_ring(false, data_u32.*),
                0x94 => self.queue.set_avail_ring(true, data_u32.*),
                0xa0 => self.queue.set_used_ring(false, data_u32.*),
                0xa4 => self.queue.set_used_ring(true, data_u32.*),
                0x100...0xfff => {
                    const new_offset = offset - 0x100;
                    const config_blob_slice = std.mem.asBytes(&self.config_blob);
                    @memcpy(config_blob_slice[new_offset .. new_offset + data.len], data);
                    return VirtioAction.ConfigWrite;
                },
                else => {
                    log.warn(@src(), "invalid virtio write: offset: 0x{x}, data: {any}", .{ offset, data });
                },
            }
            return VirtioAction.NoAction;
        }
    };
}
