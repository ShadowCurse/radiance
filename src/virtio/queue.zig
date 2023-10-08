const std = @import("std");
const log = @import("../log.zig");
const nix = @import("../nix.zig");

const GuestMemory = @import("../memory.zig").GuestMemory;

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
            if (desc.flags & nix.VIRTQ_DESC_F_NEXT) {
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
    /// Guest physical address of the descriptor table
    desc_table: ?[]nix.vring_desc,
    /// Guest physical address of the available ring
    avail_ring: ?*nix.vring_avail,
    /// Guest physical address of the used ring
    used_ring: ?*nix.vring_used,
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
            .desc_table = null,
            .avail_ring = null,
            .used_ring = null,
            .size = 0,
            .ready = false,
            .next_avail = 0,
            .next_used = 0,
            .uses_notif_suppression = false,
        };
    }

    /// Pop the first available descriptor chain from the avail ring.
    pub fn pop_desc_chain(self: *Self) DescriptorChain {
        const desc_index = self.avail_ring.?.ring()[self.next_avail];

        self.next_avail = self.next_avail % self.size;
        self.next_avail = self.next_avail +% 1;

        return DescriptorChain{
            .desc_table = self.desc_table.?,
            .index = desc_index,
        };
    }

    /// Puts an available descriptor head into the used ring for use by the guest.
    pub fn add_used_desc(
        self: *Self,
        desc_id: u16,
        data_len: u32,
    ) void {
        self.used_ring.?.ring()[self.next_used].id = desc_id;
        self.used_ring.?.ring()[self.next_used].len = data_len;

        self.next_used = self.next_used % self.size;
        self.next_used = self.next_used +% 1;

        self.used_ring.?.idx = self.next_used;
    }
};
