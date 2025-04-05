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
    pub fn new(max_size: u16) Self {
        return Self{
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

    pub fn send_notification(self: *Self, memory: *const Memory) bool {
        if (self.notification_suppression) {
            arch.load_barrier();
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
    pub fn pop_desc_chain(self: *Self, memory: *const Memory) ?DescriptorChain {
        if (self.notification_suppression) {
            // used_ring is only written by the device
            const used_ring = memory.get_ptr(nix.vring_used, self.used_ring);
            used_ring.avail_event(self.size).* = self.next_avail;
            arch.load_store_barrier();
        }

        // avail_ring is only written by the driver
        const avail_ring = memory.get_ptr(nix.vring_avail, self.avail_ring);
        if (self.next_avail == avail_ring.idx) {
            return null;
        }

        arch.load_barrier();

        const next_avail = self.next_avail % self.size;
        const desc_index = avail_ring.ring()[next_avail];
        log.assert(
            @src(),
            desc_index < self.size,
            "Descriptor index {} outside queue size {}",
            .{ desc_index, self.size },
        );

        self.next_avail = self.next_avail +% 1;

        const desc_table_slice = memory.get_slice(nix.vring_desc, self.size, self.desc_table);
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
        used_ring.ring()[next_used] = .{
            .id = desc_id,
            .len = data_len,
        };

        self.next_used = self.next_used +% 1;
        self.suppressed = self.suppressed +% 1;

        arch.load_store_barrier();
        used_ring.idx = self.next_used;
    }
};

const TestSystem = struct {
    const memory = @import("../memory.zig");

    var M align(memory.HOST_PAGE_SIZE) = [_]u8{0} ** 4096;
    pub fn mmap(
        ptr: ?[*]align(memory.HOST_PAGE_SIZE) u8,
        length: usize,
        prot: u32,
        flags: nix.MAP,
        fd: nix.fd_t,
        offset: u64,
    ) ![]align(memory.HOST_PAGE_SIZE) u8 {
        _ = ptr;
        _ = prot;
        _ = flags;
        _ = fd;
        _ = offset;
        return M[0..length];
    }
    pub fn munmap(m: []align(memory.HOST_PAGE_SIZE) const u8) void {
        _ = m;
    }
};
test "test_queue_pop_desc_chain" {
    const expect = std.testing.expect;

    var memory = Memory.init(TestSystem, 0x1000);
    defer memory.deinit(TestSystem);

    memory.guest_addr = 0;
    @memset(memory.mem, 0);

    const avail_ring_offset: u64 = 0;
    const desc_table_offset: u64 = avail_ring_offset + @sizeOf(nix.vring_avail) * 4;

    const avail_ring = memory.get_ptr(nix.vring_avail, avail_ring_offset);

    var queue = Queue.new(10);
    queue.size = 10;

    const avail_ring_offset_hight: u32 = @truncate(avail_ring_offset >> 32);
    const avail_ring_offset_low: u32 = @truncate(avail_ring_offset);
    queue.set_avail_ring(true, avail_ring_offset_hight);
    queue.set_avail_ring(false, avail_ring_offset_low);

    const desc_table_offset_hight: u32 = @truncate(desc_table_offset >> 32);
    const desc_table_offset_low: u32 = @truncate(desc_table_offset);
    queue.set_desc_table(true, desc_table_offset_hight);
    queue.set_desc_table(false, desc_table_offset_low);

    try expect(queue.pop_desc_chain(&memory) == null);

    avail_ring.idx = 10;
    for (0..10) |i| {
        @constCast(avail_ring.ring())[i] = @intCast(i);
    }
    for (0..10) |i| {
        const dc = queue.pop_desc_chain(&memory);
        try expect(dc != null);
        try expect(dc.?.index == @as(u16, @intCast(i)));
        try expect(@intFromPtr(dc.?.desc_table.ptr) ==
            @intFromPtr(memory.mem.ptr) + desc_table_offset);
        try expect(dc.?.desc_table.len == queue.size);
        try expect(queue.next_avail == i + 1);
    }
}

test "test_queue_add_used_desc" {
    const expect = std.testing.expect;

    var memory = Memory.init(TestSystem, 0x1000);
    defer memory.deinit(TestSystem);

    memory.guest_addr = 0;
    @memset(memory.mem, 0);

    const avail_ring_offset: u64 = 0;
    const desc_table_offset: u64 = avail_ring_offset + @sizeOf(nix.vring_avail) * 4;
    const used_ring_offset: u64 = desc_table_offset + @sizeOf(nix.vring_desc) * 10;

    const used_ring = memory.get_ptr(nix.vring_used, used_ring_offset);

    var queue = Queue.new(10);
    queue.size = 10;

    const used_ring_offset_hight: u32 = @truncate(used_ring_offset >> 32);
    const used_ring_offset_low: u32 = @truncate(used_ring_offset);
    queue.set_used_ring(true, used_ring_offset_hight);
    queue.set_used_ring(false, used_ring_offset_low);

    for (0..10) |i| {
        queue.add_used_desc(&memory, @intCast(i), 69);
        const a = used_ring.ring()[i];
        try expect(a.id == i);
        try expect(a.len == 69);
        try expect(queue.next_used == i + 1);
        try expect(used_ring.idx == i + 1);
    }
}
