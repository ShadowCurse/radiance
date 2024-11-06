const std = @import("std");
const nix = @import("../nix.zig");
const log = @import("../log.zig");

const Vm = @import("../vm.zig");
const EventFd = @import("../eventfd.zig");
const Queue = @import("queue.zig").Queue;

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

pub const VirtioContextError = error{
    New,
};

pub const VirtioActionTag = enum {
    NoAction,
    ActivateDevice,
    ResetDevice,
    ConfigWrite,
    QueueNotification,
};

pub const VirtioAction = union(VirtioActionTag) {
    NoAction: void,
    ActivateDevice: void,
    ResetDevice: void,
    ConfigWrite: void,
    QueueNotification: u32,
};

pub fn VirtioContext(
    comptime NUM_QUEUES: usize,
    comptime DEVICE_TYPE: u32,
    comptime CONFIG_TYPE: type,
) type {
    if (NUM_QUEUES == 0) {
        unreachable;
    }

    return struct {
        // There are 2 32 bits in 64 bit
        device_features_word: u1 = 0,
        avail_features: u64 = 0,

        // There are 2 32 bits in 64 bit
        driver_features_word: u1 = 0,
        acked_features: u64 = 0,

        // The biggest type if 2 (TYPE_NET)
        device_type: u2 = DEVICE_TYPE,
        device_status: u8 = 0,

        config_blob: CONFIG_TYPE = undefined,

        // There are max 2 queues
        selected_queue: u1 = 0,
        queues: [NUM_QUEUES]Queue,
        queue_events: [NUM_QUEUES]EventFd,

        irq_evt: EventFd,

        const Self = @This();

        pub fn new(
            vm: *const Vm,
            queue_sizes: [NUM_QUEUES]u16,
            irq: u32,
            addr: u64,
        ) !Self {
            var queue_events: [NUM_QUEUES]EventFd = undefined;
            for (&queue_events) |*qe| {
                qe.* = try EventFd.new(0, nix.EFD_NONBLOCK);
            }
            var queues: [NUM_QUEUES]Queue = undefined;
            for (&queues, queue_sizes) |*q, size| {
                q.* = Queue.new(size);
            }
            const self = Self{
                .queues = queues,
                .queue_events = queue_events,
                .irq_evt = try EventFd.new(0, nix.EFD_NONBLOCK),
            };

            const kvm_irqfd: nix.kvm_irqfd = .{
                .fd = @intCast(self.irq_evt.fd),
                .gsi = irq,
            };
            _ = try nix.checked_ioctl(
                @src(),
                VirtioContextError.New,
                vm.fd,
                nix.KVM_IRQFD,
                &kvm_irqfd,
            );

            for (&self.queue_events, 0..) |*queue_event, i| {
                const kvm_ioeventfd: nix.kvm_ioeventfd = .{
                    .datamatch = i,
                    .len = @sizeOf(u32),
                    .addr = addr + 0x50,
                    .fd = queue_event.fd,
                    .flags = nix.KVM_IOEVENTFD_FLAG_NR_DATAMATCH,
                };
                _ = try nix.checked_ioctl(
                    @src(),
                    VirtioContextError.New,
                    vm.fd,
                    nix.KVM_IOEVENTFD,
                    &kvm_ioeventfd,
                );
            }
            return self;
        }

        fn update_device_status(self: *Self, status: u8) VirtioAction {
            const changed_bit = ~self.device_status & status;
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
                    log.warn(
                        @src(),
                        "invalid virtio driver status transition: 0x{x} => 0x{x}",
                        .{ self.device_status, status },
                    );
                },
            }
            return VirtioAction.NoAction;
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
                    };
                    const features_u32: u32 = @truncate(features);
                    data_u32.* = features_u32;
                },
                0x34 => data_u32.* = self.queues[self.selected_queue].max_size,
                0x44 => data_u32.* = @intFromBool(self.queues[self.selected_queue].ready),
                0x60 => {
                    // 0x1 means status is always ready
                    data_u32.* = 0x1;
                },
                0x70 => data_u32.* = self.device_status,
                // No generation updates
                0xfc => data_u32.* = 0,
                0x100...0xfff => {
                    const new_offset = offset - 0x100;
                    const config_blob_slice = std.mem.asBytes(&self.config_blob);
                    @memcpy(data, config_blob_slice[new_offset .. new_offset + data.len]);
                },
                else => {
                    log.warn(
                        @src(),
                        "invalid virtio read: offset: 0x{x}, data: {any}",
                        .{ offset, data },
                    );
                },
            }
            return VirtioAction.NoAction;
        }

        pub fn write(self: *Self, offset: u64, data: []u8) VirtioAction {
            const data_u32: *u32 = @ptrCast(@alignCast(data.ptr));
            switch (offset) {
                0x14 => self.device_features_word = @truncate(data_u32.*),
                0x20 => {
                    switch (self.driver_features_word) {
                        // Set the lower 32-bits of the features bitfield.
                        0 => self.acked_features |= data_u32.*,
                        // Set the upper 32-bits of the features bitfield.
                        1 => self.acked_features |= @as(u64, data_u32.*) << 32,
                    }
                },
                0x24 => self.driver_features_word = @truncate(data_u32.*),
                0x30 => self.selected_queue = @truncate(data_u32.*),
                0x38 => {
                    self.queues[self.selected_queue].size = @truncate(data_u32.*);
                },
                0x44 => self.queues[self.selected_queue].ready = data_u32.* == 1,
                0x50 => return VirtioAction{ .QueueNotification = data_u32.* },
                0x64 => {
                    // There is no interrupt status to update
                },
                0x70 => return self.update_device_status(data[0]),
                0x80 => self.queues[self.selected_queue].set_desc_table(false, data_u32.*),
                0x84 => self.queues[self.selected_queue].set_desc_table(true, data_u32.*),
                0x90 => self.queues[self.selected_queue].set_avail_ring(false, data_u32.*),
                0x94 => self.queues[self.selected_queue].set_avail_ring(true, data_u32.*),
                0xa0 => self.queues[self.selected_queue].set_used_ring(false, data_u32.*),
                0xa4 => self.queues[self.selected_queue].set_used_ring(true, data_u32.*),
                0x100...0xfff => {
                    const new_offset = offset - 0x100;
                    const config_blob_slice = std.mem.asBytes(&self.config_blob);
                    @memcpy(config_blob_slice[new_offset .. new_offset + data.len], data);
                    return VirtioAction.ConfigWrite;
                },
                else => {
                    log.warn(
                        @src(),
                        "invalid virtio write: offset: 0x{x}, data: {any}",
                        .{ offset, data },
                    );
                },
            }
            return VirtioAction.NoAction;
        }
    };
}
