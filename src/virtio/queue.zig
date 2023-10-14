const std = @import("std");
const log = @import("../log.zig");
const nix = @import("../nix.zig");

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
    desc_table: *nix.vring_desc,
    /// Guest physical address of the available ring
    avail_ring: *nix.vring_avail,
    /// Guest physical address of the used ring
    used_ring: *nix.vring_used,
    /// The queue size in elements the driver selected
    size: u16,
    /// Indicates if the queue is finished with configuration
    ready: bool,

    next_avail: u16,
    next_used: u16,

    /// VIRTIO_F_RING_EVENT_IDX negotiated (notification suppression enabled)
    uses_notif_suppression: bool,

    const Self = @This();

    const MAX_SIZE: u32 = 256;

    /// Constructs an empty virtio queue with the given `max_size`.
    pub fn new() Self {
        return Self{
            .desc_table = @ptrFromInt(@alignOf(nix.vring_desc)),
            .avail_ring = @ptrFromInt(@alignOf(nix.vring_avail)),
            .used_ring = @ptrFromInt(@alignOf(nix.vring_used)),
            .size = 0,
            .ready = false,
            .next_avail = 0,
            .next_used = 0,
            .uses_notif_suppression = false,
        };
    }

    pub fn set_desc_table(self: *Self, high_bits: bool, value: u32) void {
        const ptr_u64 = @as(u64, @intFromPtr(self.desc_table));
        if (high_bits) {
            self.desc_table = @ptrFromInt((ptr_u64 & 0xffff_ffff) | (@as(u64, value) << 32));
        } else {
            self.desc_table = @ptrFromInt((ptr_u64 & ~@as(u64, 0xffff_ffff)) | @as(u64, value));
        }
    }

    pub fn set_avail_ring(self: *Self, high_bits: bool, value: u32) void {
        const ptr_u64 = @as(u64, @intFromPtr(self.avail_ring));
        if (high_bits) {
            self.avail_ring = @ptrFromInt((ptr_u64 & 0xffff_ffff) | (@as(u64, value) << 32));
        } else {
            self.avail_ring = @ptrFromInt((ptr_u64 & ~@as(u64, 0xffff_ffff)) | @as(u64, value));
        }
    }

    pub fn set_used_ring(self: *Self, high_bits: bool, value: u32) void {
        const ptr_u64 = @as(u64, @intFromPtr(self.used_ring));
        if (high_bits) {
            self.used_ring = @ptrFromInt((ptr_u64 & 0xffff_ffff) | (@as(u64, value) << 32));
        } else {
            self.used_ring = @ptrFromInt((ptr_u64 & ~@as(u64, 0xffff_ffff)) | @as(u64, value));
        }
    }

    /// Pop the first available descriptor chain from the avail ring.
    pub fn pop_desc_chain(self: *Self) DescriptorChain {
        const desc_index = self.avail_ring.ring()[self.next_avail];

        self.next_avail = self.next_avail % self.size;
        self.next_avail = self.next_avail +% 1;

        var desc_table_slice: []nix.vring_desc = undefined;
        desc_table_slice.ptr = @ptrCast(self.desc_table);
        desc_table_slice.len = self.size;

        return DescriptorChain{
            .desc_table = desc_table_slice,
            .index = desc_index,
        };
    }

    /// Puts an available descriptor head into the used ring for use by the guest.
    pub fn add_used_desc(
        self: *Self,
        desc_id: u16,
        data_len: u32,
    ) void {
        self.used_ring.ring()[self.next_used].id = desc_id;
        self.used_ring.ring()[self.next_used].len = data_len;

        self.next_used = self.next_used % self.size;
        self.next_used = self.next_used +% 1;

        self.used_ring.idx = self.next_used;
    }
};
