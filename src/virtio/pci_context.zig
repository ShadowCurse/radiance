const std = @import("std");
const nix = @import("../nix.zig");
const log = @import("../log.zig");

const Memory = @import("../memory.zig");
const HOST_PAGE_SIZE = Memory.HOST_PAGE_SIZE;

const Gicv2 = @import("../gicv2.zig");
const Vm = @import("../vm.zig");
const Mmio = @import("../mmio.zig");
const Ecam = @import("ecam.zig");
const Queue = @import("queue.zig").Queue;
const EventFd = @import("../eventfd.zig");

const _virtio = @import("context.zig");
const DeviceStatus = _virtio.DeviceStatus;
const VirtioAction = _virtio.VirtioAction;

pub const virtio_pci_common_cfg = extern struct {
    // About the whole device
    device_feature_select: u32 = 0, // read-write
    device_feature: u32 = 0, // read-only for driver
    driver_feature_select: u32 = 0, // read-write
    driver_feature: u32 = 0, // read-write
    config_msix_vector: u16 = 0, // read-write
    num_queues: u16 = 0, // read-only for driver
    device_status: u8 = 0, // read-write
    config_generation: u8 = 0, // read-only for driver

    // About a specific virtqueue.
    queue_select: u16 = 0, // read-write
    queue_size: u16 = 0, // read-write
    queue_msix_vector: u16 = 0, // read-write
    queue_enable: u16 = 0, // read-write
    queue_notify_off: u16 = 0, // read-only for driver
    queue_desc_lo: u32 = 0, // read-write
    queue_desc_hi: u32 = 0, // read-write
    queue_driver_lo: u32 = 0, // read-write
    queue_driver_hi: u32 = 0, // read-write
    queue_device_lo: u32 = 0, // read-write
    queue_device_hi: u32 = 0, // read-write
    queue_notify_data: u16 = 0, // read-only for driver
    queue_reset: u16 = 0, // read-write
};

const MsixEntry = extern struct {
    address_lo: u32 = 0,
    address_hi: u32 = 0,
    message_data: u32 = 0,
    vector_control: u32 = 1,
};
pub fn PciVirtioContext(
    comptime NUM_QUEUES: usize,
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
        device_status: DeviceStatus = .{},

        // There are max 2 queues
        selected_queue: u1 = 0,
        queues: [NUM_QUEUES]Queue,
        queue_msi: [NUM_QUEUES]u8 = .{0} ** NUM_QUEUES,
        queue_events: [NUM_QUEUES]EventFd,
        queue_irqs: [NUM_QUEUES]EventFd,

        config_msi: u8 = 0,
        config_irq: EventFd,

        config: CONFIG = undefined,
        msix_table: [NUM_IRQS]MsixEntry = .{MsixEntry{}} ** NUM_IRQS,

        vm: *Vm,

        const NUM_IRQS = NUM_QUEUES + 1;
        const Self = @This();

        pub fn new(
            comptime System: type,
            vm: *Vm,
            queue_sizes: [NUM_QUEUES]u16,
            info: Mmio.Resources.PciInfo,
        ) Self {
            var queues: [NUM_QUEUES]Queue = undefined;
            for (&queues, queue_sizes) |*q, size| {
                q.* = Queue.new(size);
            }
            const self = Self{
                .queues = queues,
                .queue_events = .{EventFd.new(System, 0, nix.EFD_NONBLOCK)} ** NUM_QUEUES,
                .queue_irqs = .{EventFd.new(System, 0, nix.EFD_NONBLOCK)} ** NUM_QUEUES,
                .config_irq = .new(System, 0, nix.EFD_NONBLOCK),
                .vm = vm,
            };

            for (&self.queue_events, 0..) |*queue_event, i| {
                const kvm_ioeventfd: nix.kvm_ioeventfd = .{
                    .addr = info.bar_addr +
                        Ecam.VIRTIO_PCI_NOTIFY_BAR_OFFSET +
                        i * Ecam.VIRTIO_PCI_NOTIFY_MULTIPLIER,
                    .fd = queue_event.fd,
                };
                _ = nix.assert(@src(), System, "ioctl", .{
                    vm.fd,
                    nix.KVM_IOEVENTFD,
                    @intFromPtr(&kvm_ioeventfd),
                });
            }
            return self;
        }

        pub fn write(self: *Self, comptime System: type, offset: u64, data: []u8) VirtioAction {
            var t: []const u8 = "???";
            if (offset < Ecam.VIRTIO_PCI_NOTIFY_BAR_OFFSET) {
                t = "virtio_pci_common";
                switch (offset) {
                    @offsetOf(virtio_pci_common_cfg, "device_feature_select") => {
                        self.device_features_word = @truncate(data[0]);
                    },
                    @offsetOf(virtio_pci_common_cfg, "device_feature") => unreachable,
                    @offsetOf(virtio_pci_common_cfg, "driver_feature_select") => {
                        self.driver_features_word = @truncate(data[0]);
                    },
                    @offsetOf(virtio_pci_common_cfg, "driver_feature") => {
                        const data_u32: *u32 = @ptrCast(@alignCast(data.ptr));
                        switch (self.driver_features_word) {
                            // Set the lower 32-bits of the features bitfield.
                            0 => self.acked_features |= data_u32.*,
                            // Set the upper 32-bits of the features bitfield.
                            1 => self.acked_features |= @as(u64, data_u32.*) << 32,
                        }
                    },
                    @offsetOf(virtio_pci_common_cfg, "config_msix_vector") => {
                        self.config_msi = data[0];
                        log.assert(
                            @src(),
                            self.config_msi == 0,
                            "Config MSIX should be 0, but it is {d}",
                            .{self.config_msi},
                        );
                    },
                    @offsetOf(virtio_pci_common_cfg, "num_queues") => unreachable,
                    @offsetOf(virtio_pci_common_cfg, "device_status") => {
                        return self.device_status.update(data[0]);
                    },
                    @offsetOf(virtio_pci_common_cfg, "config_generation") => unreachable,
                    @offsetOf(virtio_pci_common_cfg, "queue_select") => {
                        self.selected_queue = @truncate(data[0]);
                    },
                    @offsetOf(virtio_pci_common_cfg, "queue_size") => {
                        const data_u16: *u16 = @ptrCast(@alignCast(data.ptr));
                        self.queues[self.selected_queue].size = data_u16.*;
                    },
                    @offsetOf(virtio_pci_common_cfg, "queue_msix_vector") => {
                        self.queue_msi[self.selected_queue] = data[0];
                    },
                    @offsetOf(virtio_pci_common_cfg, "queue_enable") => {
                        self.queues[self.selected_queue].ready = data[0] == 1;
                    },
                    @offsetOf(virtio_pci_common_cfg, "queue_notify_off") => unreachable,
                    @offsetOf(virtio_pci_common_cfg, "queue_desc_lo") => {
                        const data_u32: *u32 = @ptrCast(@alignCast(data.ptr));
                        self.queues[self.selected_queue].set_desc_table(false, data_u32.*);
                    },
                    @offsetOf(virtio_pci_common_cfg, "queue_desc_hi") => {
                        const data_u32: *u32 = @ptrCast(@alignCast(data.ptr));
                        self.queues[self.selected_queue].set_desc_table(true, data_u32.*);
                    },
                    @offsetOf(virtio_pci_common_cfg, "queue_driver_lo") => {
                        const data_u32: *u32 = @ptrCast(@alignCast(data.ptr));
                        self.queues[self.selected_queue].set_avail_ring(false, data_u32.*);
                    },
                    @offsetOf(virtio_pci_common_cfg, "queue_driver_hi") => {
                        const data_u32: *u32 = @ptrCast(@alignCast(data.ptr));
                        self.queues[self.selected_queue].set_avail_ring(true, data_u32.*);
                    },
                    @offsetOf(virtio_pci_common_cfg, "queue_device_lo") => {
                        const data_u32: *u32 = @ptrCast(@alignCast(data.ptr));
                        self.queues[self.selected_queue].set_used_ring(false, data_u32.*);
                    },
                    @offsetOf(virtio_pci_common_cfg, "queue_device_hi") => {
                        const data_u32: *u32 = @ptrCast(@alignCast(data.ptr));
                        self.queues[self.selected_queue].set_used_ring(true, data_u32.*);
                    },
                    @offsetOf(virtio_pci_common_cfg, "queue_notify_data") => unreachable,
                    @offsetOf(virtio_pci_common_cfg, "queue_reset") => {},
                    else => {
                        log.err(@src(), "unhandled write bar", .{});
                    },
                }
            } else if (offset < Ecam.VIRTIO_PCI_ISR_BAR_OFFSET) {
                t = "virtio_pci_notify";
            } else if (offset < Ecam.VIRTIO_PCI_DEV_CONFIG_BAR_OFFSET) {
                t = "virtio_pci_isr";
            } else if (offset < Ecam.VIRTIO_PCI_DEV_CONFIG_BAR_OFFSET + Ecam.VIRTIO_PCI_DEV_CONFIG_BAR_SIZE) {
                t = "virtio_pci_device_cfg";
            } else if (Ecam.VIRTIO_PCI_MSIX_TABLE_BAR_OFFSET <= offset and
                offset < Ecam.VIRTIO_PCI_MSIX_PBA_BAR_OFFSET)
            {
                t = "msix_table";

                log.assert(
                    @src(),
                    data.len == 4,
                    "Write to the msix table is not 4 bytes: {any}",
                    .{data},
                );

                const table_offset = offset - Ecam.VIRTIO_PCI_MSIX_TABLE_BAR_OFFSET;
                const table_bytes: []u8 = @ptrCast(&self.msix_table);
                @memcpy(table_bytes[table_offset..][0..data.len], data);

                const msi = table_offset / @sizeOf(MsixEntry);
                const field_offset = table_offset - msi * @sizeOf(MsixEntry);
                if (field_offset == @offsetOf(MsixEntry, "vector_control") and
                    self.msix_table[msi].vector_control == 0)
                {
                    const kvm_irqfd: nix.kvm_irqfd = .{
                        .fd = if (msi == self.config_msi)
                            @intCast(self.config_irq.fd)
                        else
                            @intCast(self.queue_irqs[msi - 1].fd),
                        // The MSI number provided by the guest is converted to KVM
                        // usable SPI by decrementing the KVM added offset
                        .gsi = self.msix_table[msi].message_data - Gicv2.GIC_INTERNAL_OFFSET,
                    };
                    _ = nix.assert(@src(), System, "ioctl", .{
                        self.vm.fd,
                        nix.KVM_IRQFD,
                        @intFromPtr(&kvm_irqfd),
                    });
                }
            } else {
                t = "msix_pba";
            }

            log.debug(
                @src(),
                "write bar ({s}) at offset: 0x{x} len: {d} data: {any}",
                .{
                    t,
                    offset,
                    data.len,
                    data,
                },
            );

            return VirtioAction.NoAction;
        }

        pub fn read(self: *Self, offset: u64, data: []u8) VirtioAction {
            var t: []const u8 = "???";
            if (offset < Ecam.VIRTIO_PCI_NOTIFY_BAR_OFFSET) {
                t = "virtio_pci_common";
                switch (offset) {
                    @offsetOf(virtio_pci_common_cfg, "device_feature_select") => unreachable,
                    @offsetOf(virtio_pci_common_cfg, "device_feature") => {
                        const features =
                            switch (self.device_features_word) {
                                // Get the lower 32-bits of the features bitfield.
                                0 => (self.avail_features & 0xFFFFFFFF),
                                // Get the upper 32-bits of the features bitfield.
                                1 => self.avail_features >> 32,
                            };
                        const features_u32: u32 = @truncate(features);
                        const data_u32: *u32 = @ptrCast(@alignCast(data.ptr));
                        data_u32.* = features_u32;
                    },
                    @offsetOf(virtio_pci_common_cfg, "driver_feature_select") => unreachable,
                    @offsetOf(virtio_pci_common_cfg, "driver_feature") => unreachable,
                    @offsetOf(virtio_pci_common_cfg, "config_msix_vector") => {
                        data[0] = self.config_msi;
                    },
                    @offsetOf(virtio_pci_common_cfg, "num_queues") => {
                        data[0] = NUM_QUEUES;
                    },
                    @offsetOf(virtio_pci_common_cfg, "device_status") => {
                        data[0] = @bitCast(self.device_status);
                    },
                    @offsetOf(virtio_pci_common_cfg, "config_generation") => {
                        data[0] = 0;
                    },
                    @offsetOf(virtio_pci_common_cfg, "queue_select") => unreachable,
                    @offsetOf(virtio_pci_common_cfg, "queue_size") => {
                        const data_u16: *u16 = @ptrCast(@alignCast(data.ptr));
                        data_u16.* = self.queues[self.selected_queue].max_size;
                    },
                    @offsetOf(virtio_pci_common_cfg, "queue_msix_vector") => {
                        data[0] = self.queue_msi[self.selected_queue];
                    },
                    @offsetOf(virtio_pci_common_cfg, "queue_enable") => {
                        data[0] = @intFromBool(self.queues[self.selected_queue].ready);
                    },
                    @offsetOf(virtio_pci_common_cfg, "queue_notify_off") => {
                        data[0] = self.selected_queue;
                    },
                    @offsetOf(virtio_pci_common_cfg, "queue_desc_lo") => unreachable,
                    @offsetOf(virtio_pci_common_cfg, "queue_desc_hi") => unreachable,
                    @offsetOf(virtio_pci_common_cfg, "queue_driver_lo") => unreachable,
                    @offsetOf(virtio_pci_common_cfg, "queue_driver_hi") => unreachable,
                    @offsetOf(virtio_pci_common_cfg, "queue_device_lo") => unreachable,
                    @offsetOf(virtio_pci_common_cfg, "queue_device_hi") => unreachable,
                    @offsetOf(virtio_pci_common_cfg, "queue_notify_data") => unreachable,
                    @offsetOf(virtio_pci_common_cfg, "queue_reset") => unreachable,
                    else => unreachable,
                }
            } else if (offset < Ecam.VIRTIO_PCI_ISR_BAR_OFFSET) {
                t = "virtio_pci_notify";
            } else if (offset < Ecam.VIRTIO_PCI_DEV_CONFIG_BAR_OFFSET) {
                t = "virtio_pci_isr";
            } else if (offset < Ecam.VIRTIO_PCI_DEV_CONFIG_BAR_OFFSET + Ecam.VIRTIO_PCI_DEV_CONFIG_BAR_SIZE) {
                t = "virtio_pci_device_cfg";
                const config_offset = offset - Ecam.VIRTIO_PCI_DEV_CONFIG_BAR_OFFSET;
                const bytes: []const u8 = @ptrCast(&self.config);
                @memcpy(data, bytes[config_offset..][0..data.len]);
            } else if (Ecam.VIRTIO_PCI_MSIX_TABLE_BAR_OFFSET <= offset and
                offset < Ecam.VIRTIO_PCI_MSIX_PBA_BAR_OFFSET)
            {
                t = "msix_table";

                log.assert(
                    @src(),
                    data.len == 4,
                    "Read from the msix table is not 4 bytes: {any}",
                    .{data},
                );
                const table_offset = offset - Ecam.VIRTIO_PCI_MSIX_TABLE_BAR_OFFSET;
                const table_bytes: []u8 = @ptrCast(&self.msix_table);
                @memcpy(data, table_bytes[table_offset..][0..data.len]);
            } else {
                t = "msix_pba";
                log.assert(
                    @src(),
                    data.len == 4,
                    "Read from the msix pba is not 4 bytes: {any}",
                    .{data},
                );
                const data_u32: *u32 = @ptrCast(@alignCast(data.ptr));
                data_u32.* = 0;
            }
            log.debug(
                @src(),
                "read bar ({s}) at offset: 0x{x} len: {d} data: {any}",
                .{
                    t,
                    offset,
                    data.len,
                    data,
                },
            );

            return VirtioAction.NoAction;
        }

        pub fn notify_current_queue(self: *const Self, comptime System: type) void {
            self.queue_irqs[self.selected_queue].write(System, 1);
        }
    };
}
