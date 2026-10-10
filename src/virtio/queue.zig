const std = @import("std");
const log = @import("../log.zig");
const nix = @import("../nix.zig");
const arch = @import("../arch.zig");
const Memory = @import("../memory.zig");

/// A virtio descriptor chain.
pub const DescriptorChain = struct {
    // Address of descriptor table in guest memory
    desc_table: []volatile nix.vring_desc,
    /// Index into the descriptor table
    index: ?u16,

    const Self = @This();

    pub fn next(self: *Self) ?nix.vring_desc {
        if (self.index) |index| {
            const desc = self.desc_table[index];
            if (desc.flags & nix.VRING_DESC_F_NEXT != 0) {
                log.assert(
                    @src(),
                    desc.next < self.desc_table.len,
                    "Next descriptor index {} outside queue size {}",
                    .{ desc.next, self.desc_table.len },
                );
                self.index = desc.next;
            } else {
                self.index = null;
            }
            return desc;
        } else {
            return null;
        }
    }
};

/// A virtio queue's parameters.
pub const Queue = struct {
    /// Guest physical address of the descriptor table.
    /// Points to `nix.vring_desc`.
    desc_table: u64,
    /// Guest physical address of the available ring.
    /// Points to `nix.vring_avail`
    avail_ring: u64,
    /// Guest physical address of the used ring.
    /// Points to `nix.vring_used`
    used_ring: u64,
    /// Max size of the queue driver can select.
    max_size: u16,
    /// The queue size in elements the driver selected
    size: u16,
    /// Indicates if the queue is finished with configuration
    ready: bool,

    next_avail: u16,
    next_used: u16,

    /// VIRTIO_F_RING_EVENT_IDX negotiated (notification suppression enabled)
    notification_suppression: bool,
    suppressed: u16,

    const Self = @This();

    /// Constructs an empty virtio queue with the given `max_size`.
    pub fn init(max_size: u16) Self {
        return .{
            .desc_table = 0,
            .avail_ring = 0,
            .used_ring = 0,
            .max_size = max_size,
            .size = 0,
            .ready = false,
            .next_avail = 0,
            .next_used = 0,
            .notification_suppression = false,
            .suppressed = 0,
        };
    }

    pub fn set_desc_table(self: *Self, high_bits: bool, value: u32) void {
        if (high_bits) {
            self.desc_table = (self.desc_table & 0xffff_ffff) | (@as(u64, value) << 32);
        } else {
            self.desc_table = (self.desc_table & ~@as(u64, 0xffff_ffff)) | @as(u64, value);
        }
    }

    pub fn set_avail_ring(self: *Self, high_bits: bool, value: u32) void {
        if (high_bits) {
            self.avail_ring = (self.avail_ring & 0xffff_ffff) | (@as(u64, value) << 32);
        } else {
            self.avail_ring = (self.avail_ring & ~@as(u64, 0xffff_ffff)) | @as(u64, value);
        }
    }

    pub fn set_used_ring(self: *Self, high_bits: bool, value: u32) void {
        if (high_bits) {
            self.used_ring = (self.used_ring & 0xffff_ffff) | (@as(u64, value) << 32);
        } else {
            self.used_ring = (self.used_ring & ~@as(u64, 0xffff_ffff)) | @as(u64, value);
        }
    }

    pub fn activate(self: *Self, notification_suppression: bool) void {
        log.assert(@src(), self.size != 0, "Queue size is 0", .{});
        log.assert(
            @src(),
            self.size & (self.size - 1) == 0,
            "Queue size {} is not a power of 2",
            .{self.size},
        );
        self.notification_suppression = notification_suppression;
    }

    /// Makes all descriptors added with `add_used_desc` visible to the driver.
    /// Returns true if the driver needs to be notified.
    pub fn publish_used(self: *Self, memory: Memory.Guest) bool {
        // used_ring is only written by the device
        const used_ring = memory.get_ptr(nix.vring_used, self.used_ring);
        // Used ring entries must be visible before the used idx.
        arch.store_barrier();
        used_ring.idx = self.next_used;

        if (self.notification_suppression) {
            // The used_event must be read after used idx is visible to the driver,
            // otherwise the driver can miss an interrupt.
            arch.load_store_barrier();
            // avail_ring is only written by the driver
            const avail_ring = memory.get_ptr(nix.vring_avail, self.avail_ring);
            const used_event = avail_ring.used_event(self.size).*;
            const before = self.next_used -% self.suppressed;
            const result = used_event -% before <= self.suppressed;
            self.suppressed = 0;
            return result;
        } else {
            return true;
        }
    }

    /// Pop the first available descriptor chain from the avail ring.
    pub fn pop_desc_chain(self: *Self, memory: Memory.Guest) ?DescriptorChain {
        // avail_ring is only written by the driver
        const avail_ring = memory.get_ptr(nix.vring_avail, self.avail_ring);
        if (self.next_avail == avail_ring.idx) {
            if (!self.notification_suppression) {
                return null;
            }
            // Only ask driver for notifications once the ring looks empty and re-check it after,
            // so the entries added before driver saw the new avail_event are not missed.
            // used_ring is only written by the device
            const used_ring = memory.get_ptr(nix.vring_used, self.used_ring);
            used_ring.avail_event(self.size).* = self.next_avail;
            arch.load_store_barrier();
            if (self.next_avail == avail_ring.idx) {
                return null;
            }
        }

        arch.load_barrier();

        const desc_index = avail_ring.ring()[self.next_avail & (self.size - 1)];
        log.assert(
            @src(),
            desc_index < self.size,
            "Descriptor index {} outside queue size {}",
            .{ desc_index, self.size },
        );

        self.next_avail = self.next_avail +% 1;

        const desc_table = memory.get_slice(nix.vring_desc, self.size, self.desc_table);
        return DescriptorChain{
            .desc_table = desc_table,
            .index = desc_index,
        };
    }

    /// Puts an available descriptor head into the used ring.
    /// It is visible to the guest only after `publish_used`.
    pub fn add_used_desc(
        self: *Self,
        memory: Memory.Guest,
        desc_id: u16,
        data_len: u32,
    ) void {
        // used_ring is only written by the device
        const used_ring = memory.get_ptr(nix.vring_used, self.used_ring);
        used_ring.ring()[self.next_used & (self.size - 1)] = .{
            .id = desc_id,
            .len = data_len,
        };

        self.next_used = self.next_used +% 1;
        self.suppressed = self.suppressed +% 1;
    }
};

const TestSystem = struct {
    const memory = @import("../memory.zig");
    var M align(memory.HOST_PAGE_SIZE) = [_]u8{0} ** 4096;
};
test "test_queue_pop_desc_chain" {
    const memory: Memory.Guest = .{ .mem = TestSystem.M[0..] };

    var queue = Queue.init(16);
    queue.size = 16;
    queue.desc_table = Memory.DRAM_START;
    queue.avail_ring = Memory.DRAM_START + 0x100;
    queue.used_ring = Memory.DRAM_START + 0x200;

    try std.testing.expectEqual(null, queue.pop_desc_chain(memory));

    const avail_ring = memory.get_ptr(nix.vring_avail, queue.avail_ring);
    avail_ring.idx = 10;
    for (0..10) |i| @constCast(avail_ring.ring())[i] = @intCast(i);
    for (0..10) |i| {
        const dc = queue.pop_desc_chain(memory);
        try std.testing.expect(dc != null);
        try std.testing.expectEqual(@as(u16, @intCast(i)), dc.?.index);
        try std.testing.expectEqual(
            memory.get_ptr(nix.vring_desc, queue.desc_table),
            &dc.?.desc_table[0],
        );
        try std.testing.expectEqual(queue.size, dc.?.desc_table.len);
        try std.testing.expectEqual(i + 1, queue.next_avail);
    }
}

test "test_queue_add_used_desc" {
    var memory: Memory.Guest = .{ .mem = TestSystem.M[0..] };

    var queue = Queue.init(16);
    queue.size = 16;
    queue.desc_table = Memory.DRAM_START;
    queue.avail_ring = Memory.DRAM_START + 0x100;
    queue.used_ring = Memory.DRAM_START + 0x200;

    const used_ring = memory.get_ptr(nix.vring_used, queue.used_ring);
    for (0..10) |i| {
        queue.add_used_desc(memory, @intCast(i), 69);
        try std.testing.expectEqual(i, used_ring.idx);
        try std.testing.expect(queue.publish_used(memory));
        const a = used_ring.ring()[i];
        try std.testing.expectEqual(i, a.id);
        try std.testing.expectEqual(69, a.len);
        try std.testing.expectEqual(i + 1, queue.next_used);
        try std.testing.expectEqual(i + 1, used_ring.idx);
    }
}
