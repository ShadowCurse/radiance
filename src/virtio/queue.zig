const std = @import("std");
const log = @import("../log.zig");
const nix = @import("../nix.zig");
const Memory = @import("../memory.zig");

/// A virtio descriptor chain.
pub const DescriptorChain = struct {
    // Address of descriptor table in guest memory
    desc_table: []nix.vring_desc,
    /// Index into the descriptor table
    index: ?u16,

    const Self = @This();

    pub fn next(self: *Self) ?nix.vring_desc {
        if (self.index) |index| {
            const desc = self.desc_table[index];
            if (desc.flags & nix.VRING_DESC_F_NEXT != 0) {
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
    pub const MAX_SIZE: u32 = 256;

    /// Guest physical address of the descriptor table.
    /// Points to `nix.vring_desc`.
    desc_table: u64,
    /// Guest physical address of the available ring.
    /// Points to `nix.vring_avail`
    avail_ring: u64,
    /// Guest physical address of the used ring.
    /// Points to `nix.vring_used`
    used_ring: u64,
    /// The queue size in elements the driver selected
    size: u16,
    /// Indicates if the queue is finished with configuration
    ready: bool,

    next_avail: u16,
    next_used: u16,

    /// VIRTIO_F_RING_EVENT_IDX negotiated (notification suppression enabled)
    uses_notif_suppression: bool,

    const Self = @This();

    /// Constructs an empty virtio queue with the given `max_size`.
    pub fn new() Self {
        return Self{
            .desc_table = 0,
            .avail_ring = 0,
            .used_ring = 0,
            .size = 0,
            .ready = false,
            .next_avail = 0,
            .next_used = 0,
            .uses_notif_suppression = false,
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

    /// Pop the first available descriptor chain from the avail ring.
    pub fn pop_desc_chain(self: *Self, memory: *const Memory) ?DescriptorChain {
        // std.atomic.fence(std.atomic.Ordering.Acquire);

        // avail_ring is only written by the driver
        const avail_ring = memory.get_ptr(nix.vring_avail, self.avail_ring);

        if (self.next_avail == avail_ring.idx) {
            return null;
        }

        const next_avail = self.next_avail % self.size;
        const desc_index = avail_ring.ring()[next_avail];

        self.next_avail = self.next_avail +% 1;

        var desc_table_slice: []nix.vring_desc = undefined;
        desc_table_slice.ptr = @ptrCast(memory.get_ptr(nix.vring_desc, self.desc_table));
        desc_table_slice.len = self.size;

        return DescriptorChain{
            .desc_table = desc_table_slice,
            .index = desc_index,
        };
    }

    /// Puts an available descriptor head into the used ring for use by the guest.
    pub fn add_used_desc(
        self: *Self,
        memory: *Memory,
        desc_id: u16,
        data_len: u32,
    ) void {
        // used_ring is only written by the device
        const used_ring = memory.get_ptr(nix.vring_used, self.used_ring);
        const next_used = self.next_used % self.size;
        used_ring.ring()[next_used].id = desc_id;
        used_ring.ring()[next_used].len = data_len;

        self.next_used = self.next_used +% 1;

        // std.atomic.fence(std.atomic.Ordering.Release);

        used_ring.idx = self.next_used;
    }
};
