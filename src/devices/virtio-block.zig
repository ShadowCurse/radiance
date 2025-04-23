const std = @import("std");
const nix = @import("../nix.zig");
const log = @import("../log.zig");

const Vm = @import("../vm.zig");
const CmdLine = @import("../cmdline.zig");
const MmioDeviceInfo = @import("../mmio.zig").MmioDeviceInfo;

const Memory = @import("../memory.zig");
const HOST_PAGE_SIZE = Memory.HOST_PAGE_SIZE;

const _virtio = @import("../virtio/context.zig");
const VirtioContext = _virtio.VirtioContext;

pub const SECTOR_SHIFT: u8 = 9;
pub const TYPE_BLOCK: u32 = 2;

pub const Config = extern struct {
    capacity: u64,
    size_max: u32,
    seg_max: u32,
};
pub const QUEUE_SIZE = 256;
// Request can take the whole queue of descriptors
// but it needs to have 1 descriptor for header
// and 1 for the ack location.
pub const MAX_SEGMENTS = QUEUE_SIZE - 2;
pub const QUEUE_SIZES = .{ QUEUE_SIZE, QUEUE_SIZE };

pub const VirtioBlock = struct {
    read_only: bool,
    memory: *Memory,
    virtio_context: VIRTIO_CONTEXT,
    file_mem: []align(HOST_PAGE_SIZE) u8,
    block_id: [nix.VIRTIO_BLK_ID_BYTES]u8,

    const Self = @This();
    const VIRTIO_CONTEXT = VirtioContext(QUEUE_SIZES.len, TYPE_BLOCK, Config);

    pub fn new(
        comptime System: type,
        vm: *Vm,
        file_path: []const u8,
        read_only: bool,
        memory: *Memory,
        mmio_info: MmioDeviceInfo,
    ) Self {
        const fd = nix.assert(@src(), System, "open", .{
            file_path,
            .{ .ACCMODE = if (read_only) .RDONLY else .RDWR },
            0,
        });
        defer System.close(fd);

        const statx = nix.assert(@src(), System, "statx", .{fd});

        const file_mem = nix.assert(@src(), System, "mmap", .{
            null,
            statx.size,
            if (read_only) nix.PROT.READ else nix.PROT.READ | nix.PROT.WRITE,
            .{ .TYPE = if (read_only) .PRIVATE else .SHARED },
            fd,
            0,
        });

        const nsectors = statx.size >> SECTOR_SHIFT;

        var block_id = [_]u8{0} ** nix.VIRTIO_BLK_ID_BYTES;
        var dev_major = statx.dev_major;
        dev_major = dev_major << 16;
        dev_major = dev_major << 16;
        const dev = statx.dev_minor | dev_major;

        var rdev_major = statx.rdev_major;
        rdev_major = rdev_major << 16;
        rdev_major = rdev_major << 16;
        const rdev = statx.rdev_minor | rdev_major;

        _ = std.fmt.bufPrint(&block_id, "{}{}{}", .{ dev, rdev, statx.ino }) catch |e| {
            log.assert(@src(), false, "block id formatting error: {}", .{e});
        };

        var virtio_context = VIRTIO_CONTEXT.new(
            System,
            vm,
            QUEUE_SIZES,
            mmio_info.irq,
            mmio_info.addr,
        );
        virtio_context.avail_features = (1 << nix.VIRTIO_F_VERSION_1) |
            (1 << nix.VIRTIO_RING_F_EVENT_IDX) |
            (1 << nix.VIRTIO_BLK_F_SEG_MAX);
        if (read_only) {
            virtio_context.avail_features |= 1 << nix.VIRTIO_BLK_F_RO;
        }
        virtio_context.config.capacity = nsectors;
        virtio_context.config.seg_max = MAX_SEGMENTS;

        return Self{
            .read_only = read_only,
            .memory = memory,
            .virtio_context = virtio_context,
            .file_mem = file_mem,
            .block_id = block_id,
        };
    }

    pub fn add_to_cmdline(self: *const Self, cmdline: *CmdLine) !void {
        if (self.read_only) {
            try cmdline.append(" root=/dev/vda ro");
        } else {
            try cmdline.append(" root=/dev/vda rw");
        }
    }

    pub fn write_default(self: *Self, offset: u64, data: []u8) void {
        self.write(nix.System, offset, data);
    }
    pub fn write(self: *Self, comptime System: type, offset: u64, data: []u8) void {
        switch (self.virtio_context.write(offset, data)) {
            .NoAction => {},
            .ActivateDevice => {
                self.virtio_context.set_memory(System);

                // Only VIRTIO_MMIO_INT_VRING notification type is supported.
                if (self.virtio_context.acked_features & (1 << nix.VIRTIO_RING_F_EVENT_IDX) != 0) {
                    for (&self.virtio_context.queues) |*q| {
                        q.notification_suppression = true;
                    }
                }
            },
            else => |action| {
                log.err(@src(), "unhandled write virtio action: {}", .{action});
            },
        }
    }

    pub fn read(self: *Self, offset: u64, data: []u8) void {
        switch (self.virtio_context.read(offset, data)) {
            .NoAction => {},
            else => |action| {
                log.err(@src(), "unhandled read virtio action: {}", .{action});
            },
        }
    }

    pub fn sync(self: *Self, comptime System: type) void {
        if (!self.read_only)
            nix.assert(@src(), System, "msync", .{ self.file_mem, nix.MSF.ASYNC });
    }

    pub fn event_process_queue(self: *Self) void {
        self.process_queue(nix.System);
    }
    pub fn process_queue(self: *Self, comptime System: type) void {
        _ = self.virtio_context.queue_events[self.virtio_context.selected_queue].read(System);

        var segments: [MAX_SEGMENTS][]volatile u8 = undefined;
        var segments_n: u32 = 0;
        var total_segments_len: u32 = 0;

        const queue = &self.virtio_context.queues[self.virtio_context.selected_queue];
        while (queue.pop_desc_chain(self.memory)) |dc| {
            segments_n = 0;
            total_segments_len = 0;

            var desc_chain = dc;
            const header_desc_index = desc_chain.index.?;
            const header_desc = desc_chain.next().?;
            const header = self.memory.get_ptr(nix.virtio_blk_outhdr, header_desc.addr);
            var offset = header.sector << SECTOR_SHIFT;

            var data_desc = desc_chain.next().?;

            while ((data_desc.flags & nix.VRING_DESC_F_NEXT) != 0) {
                log.assert(
                    @src(),
                    segments_n <= MAX_SEGMENTS,
                    "Got descriptor chain with more data segments than MAX_SEGMENTS({d})",
                    .{@as(u32, MAX_SEGMENTS)},
                );
                segments[segments_n] = self.memory.get_slice(u8, data_desc.len, data_desc.addr);
                total_segments_len += data_desc.len;
                segments_n += 1;
                data_desc = desc_chain.next().?;
            }
            const status_desc = data_desc;

            if (segments_n == 0) {
                self.sync(System);

                const status_ptr = self.memory.get_ptr(u32, status_desc.addr);
                status_ptr.* = nix.VIRTIO_BLK_S_OK;
            } else {
                switch (header.type) {
                    nix.VIRTIO_BLK_T_IN => {
                        for (segments[0..segments_n]) |segment| {
                            @memcpy(segment, self.file_mem[offset .. offset + segment.len]);
                            offset += segment.len;
                        }
                    },
                    nix.VIRTIO_BLK_T_OUT => {
                        for (segments[0..segments_n]) |segment| {
                            @memcpy(self.file_mem[offset .. offset + segment.len], segment);
                            offset += segment.len;
                        }
                    },
                    nix.VIRTIO_BLK_T_FLUSH => {
                        self.sync(System);
                    },
                    nix.VIRTIO_BLK_T_GET_ID => {
                        log.assert(
                            @src(),
                            segments_n == 1,
                            "Descriptor chain has more than 1 data descriptor for VIRTIO_BLK_T_GET_ID request",
                            .{},
                        );
                        const segment = segments[0];
                        @memcpy(segment, &self.block_id);
                        total_segments_len = nix.VIRTIO_BLK_ID_BYTES;
                    },
                    else => log.err(@src(), "unknown virtio request type: {}", .{header.type}),
                }
                const status_ptr = self.memory.get_ptr(u32, status_desc.addr);
                status_ptr.* = nix.VIRTIO_BLK_S_OK;

                self.virtio_context.queues[self.virtio_context.selected_queue]
                    .add_used_desc(self.memory, header_desc_index, total_segments_len);
            }
        }

        if (self.virtio_context.queues[self.virtio_context.selected_queue]
            .send_notification(self.memory))
        {
            self.virtio_context.irq_evt.write(System, 1);
        }
    }
};
