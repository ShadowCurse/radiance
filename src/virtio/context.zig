const std = @import("std");
const nix = @import("../nix.zig");
const log = @import("../log.zig");

const Vm = @import("../vm.zig");
const Mmio = @import("../mmio.zig");
const Memory = @import("../memory.zig");
const EventFd = @import("../eventfd.zig");
const Queue = @import("queue.zig").Queue;

// The VIRTIO space allocation strategy is:
//            Page without memory backing                       Page with memory backing
//     --------------------------------------------==============================================
//     |            |++++++++++++++++++++++++++++++|#####################|              |
//     --------------------------------------------==============================================
//   MMIO_START   VIRTIO_REGION_START          MMIO_START       VIRTIO_REGION_END   MMIO_START
//                                                 +                                    +
//                                             PAGE_SIZE                           2 * PAGE_SIZE
//
//  The main idea here is to split VIRTIO space into 2 parts:
//  - First part before INTERRUPT_STATUS_OFFSET will be placed in the guest physical page
//    which will not have memory backing. This means all reads and writes to it by the guest
//    will trigger KVMExit and VMM will know about them
//  - Second part after INTERRUPT_STATUS_OFFSET will be placed in the guest physical page
//    which will have a RW memory backing. This page will be set after the device is initialized.
//    This means all reads and writes to it will be usual memory accesses and will not trigger
//    KVMExits.
//
//  This layout ensures no KVMExits for VIRTIO devices during their normal runtime.
//

// This is the offset into the VIRTIO MMIO register layout which
// is used to divide the MMIO space into 2 pages.
pub const INTERRUPT_STATUS_OFFSET = 0x60;

pub const DeviceStatus = packed struct(u8) {
    acknowledge: bool = false,
    driver: bool = false,
    driver_ok: bool = false,
    features_ok: bool = false,
    _: u2 = 0,
    need_reset: bool = false,
    failed: bool = false,

    pub fn update(self: *DeviceStatus, new_status: u8) VirtioAction {
        const current_status: u8 = @bitCast(self.*);
        const diff: DeviceStatus = @bitCast(~current_status & new_status);
        if ((new_status == 0) or
            (diff.acknowledge and
                current_status == 0) or
            (diff.driver and
                self.acknowledge) or
            (diff.features_ok and
                self.acknowledge and
                self.driver))
        {
            self.* = @bitCast(new_status);
        } else if ((diff.driver_ok and
            self.acknowledge and
            self.driver and
            self.features_ok))
        {
            self.* = @bitCast(new_status);
            return .ActivateDevice;
        } else {
            log.warn(
                @src(),
                "invalid virtio driver status transition: {any} -> {any}: {any}",
                .{ self, @as(DeviceStatus, @bitCast(new_status)), diff },
            );
        }
        return .NoAction;
    }
};

pub const VENDOR_ID: u32 = 0;

/// Interrupt flags (re: interrupt status & acknowledge registers).
/// See linux/virtio_mmio.h.
pub const VIRTIO_MMIO_INT_VRING: u32 = 0x01;
pub const VIRTIO_MMIO_INT_CONFIG: u32 = 0x02;

// required by the virtio mmio device register layout at offset 0 from base
pub const MMIO_MAGIC_VALUE: u32 = 0x7472_6976;

// current version specified by the mmio standard (legacy devices used 1 here)
pub const MMIO_VERSION: u32 = 2;

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
    comptime CONFIG: type,
) type {
    if (NUM_QUEUES == 0) unreachable;

    return struct {
        // There are 2 32 bits in 64 bit
        device_features_word: u1 = 0,
        avail_features: u64 = 0,

        // There are 2 32 bits in 64 bit
        driver_features_word: u1 = 0,
        acked_features: u64 = 0,

        // The biggest type if 2 (TYPE_NET)
        device_type: u2 = DEVICE_TYPE,
        device_status: DeviceStatus = .{},

        config: CONFIG = undefined,

        // There are max 2 queues
        selected_queue: u1 = 0,
        queues: [NUM_QUEUES]Queue,
        queue_events: [NUM_QUEUES]EventFd,

        irq_evt: EventFd,

        vm: *Vm,
        addr: u64,
        mem_ptr: [*]align(Memory.HOST_PAGE_SIZE) u8,

        const Self = @This();

        pub fn init(
            comptime System: type,
            vm: *Vm,
            queue_sizes: [NUM_QUEUES]u16,
            info: Mmio.Resources.MmioVirtioInfo,
        ) Self {
            var queue_events: [NUM_QUEUES]EventFd = undefined;
            for (&queue_events) |*qe|
                qe.* = .init(System, 0, nix.EFD_NONBLOCK);
            var queues: [NUM_QUEUES]Queue = undefined;
            for (&queues, queue_sizes) |*q, size|
                q.* = .init(size);
            const self = Self{
                .queues = queues,
                .queue_events = queue_events,
                .irq_evt = .init(System, 0, nix.EFD_NONBLOCK),
                .vm = vm,
                .addr = info.addr,
                .mem_ptr = info.mem_ptr,
            };

            const kvm_irqfd: nix.kvm_irqfd = .{
                .fd = @intCast(self.irq_evt.fd),
                .gsi = info.irq,
            };
            _ = nix.assert(@src(), System, "ioctl", .{
                vm.fd,
                nix.KVM_IRQFD,
                @intFromPtr(&kvm_irqfd),
            });

            for (&self.queue_events, 0..) |*queue_event, i| {
                const kvm_ioeventfd: nix.kvm_ioeventfd = .{
                    .datamatch = i,
                    .len = @sizeOf(u32),
                    .addr = info.addr + 0x50,
                    .fd = queue_event.fd,
                    .flags = nix.KVM_IOEVENTFD_FLAG_NR_DATAMATCH,
                };
                _ = nix.assert(@src(), System, "ioctl", .{
                    vm.fd,
                    nix.KVM_IOEVENTFD,
                    @intFromPtr(&kvm_ioeventfd),
                });
            }
            return self;
        }

        pub fn set_memory(self: *Self, comptime System: type) void {
            // Memory will be at the offset INTERRUPT_STATUS_OFFSET in VIRTIO region
            // Set Interrupt status to always be 1
            const mem: []align(Memory.HOST_PAGE_SIZE) u8 = self.mem_ptr[0..Memory.HOST_PAGE_SIZE];
            mem[0] = 1;

            const guest_phys_addr = self.addr + INTERRUPT_STATUS_OFFSET;
            log.debug(
                @src(),
                "setting mmio opt memory for device: {} guest_phys_addr: 0x{x}, memory_size: 0x{x}, userspace_addr: {*}",
                .{ self.device_type, guest_phys_addr, mem.len, mem.ptr },
            );
            self.vm.set_memory(
                System,
                .{
                    .guest_phys_addr = guest_phys_addr,
                    .memory_size = mem.len,
                    .userspace_addr = @intFromPtr(mem.ptr),
                },
            );
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
                0x70 => data_u32.* = @as(u8, @bitCast(self.device_status)),
                // No generation updates
                0xfc => data_u32.* = 0,
                0x100...0xfff => {
                    const new_offset = offset - 0x100;
                    const config_blob_slice: []const u8 = @ptrCast(&self.config);
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

        pub fn write(self: *Self, comptime System: type, offset: u64, data: []u8) VirtioAction {
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
                0x70 => {
                    const action = self.device_status.update(data[0]);
                    if (action == .ActivateDevice) self.set_memory(System);
                    return action;
                },
                0x80 => self.queues[self.selected_queue].set_desc_table(false, data_u32.*),
                0x84 => self.queues[self.selected_queue].set_desc_table(true, data_u32.*),
                0x90 => self.queues[self.selected_queue].set_avail_ring(false, data_u32.*),
                0x94 => self.queues[self.selected_queue].set_avail_ring(true, data_u32.*),
                0xa0 => self.queues[self.selected_queue].set_used_ring(false, data_u32.*),
                0xa4 => self.queues[self.selected_queue].set_used_ring(true, data_u32.*),
                0x100...0xfff => {
                    const new_offset = offset - 0x100;
                    const config_blob_slice: []u8 = @ptrCast(&self.config);
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

        pub fn notify_current_queue(self: *const Self, comptime System: type) void {
            self.irq_evt.write(System, 1);
        }
    };
}
