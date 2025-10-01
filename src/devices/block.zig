const std = @import("std");
const nix = @import("../nix.zig");
const log = @import("../log.zig");

const Vm = @import("../vm.zig");
const CmdLine = @import("../cmdline.zig");
const mmio = @import("../mmio.zig");
const MmioDeviceInfo = mmio.MmioDeviceInfo;
const PciDeviceInfo = mmio.PciDeviceInfo;

const _pci = @import("../virtio/pci_context.zig");
const PciVirtioContext = _pci.PciVirtioContext;

const Memory = @import("../memory.zig");
const HOST_PAGE_SIZE = Memory.HOST_PAGE_SIZE;

const _virtio = @import("../virtio/context.zig");
const VirtioContext = _virtio.VirtioContext;

const IoUring = @import("../io_uring.zig");

pub const SECTOR_SHIFT: u8 = 9;
pub const TYPE_BLOCK: u32 = 2;

pub const Config = extern struct {
    capacity: u64,
    size_max: u32,
    seg_max: u32,
};
pub const QUEUE_SIZE = 256;
pub const QUEUE_SIZES = .{QUEUE_SIZE};

// Request can take the whole queue of descriptors
// but it needs to have 1 descriptor for header
// and 1 for the ack location.
pub const MAX_SEGMENTS = QUEUE_SIZE - 2;

const MmioContext = VirtioContext(QUEUE_SIZES.len, TYPE_BLOCK, Config);
const PciContext = PciVirtioContext(QUEUE_SIZES.len, Config);

pub const BlockMmio = Block(MmioContext);
pub const BlockPci = Block(PciContext);

pub fn Block(comptime Context: type) type {
    return struct {
        read_only: bool,
        memory: *Memory,
        file_mem: []align(HOST_PAGE_SIZE) u8,
        block_id: [nix.VIRTIO_BLK_ID_BYTES]u8,

        context: Context,

        const Self = @This();

        pub fn new(
            comptime System: type,
            file_path: []const u8,
            read_only: bool,
            id: ?[nix.VIRTIO_BLK_ID_BYTES]u8,
            vm: *Vm,
            memory: *Memory,
            info: anytype,
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
            const block_id = if (id) |i| i else .{0} ** nix.VIRTIO_BLK_ID_BYTES;

            var context = Context.new(
                System,
                vm,
                QUEUE_SIZES,
                info,
            );
            context.avail_features =
                (1 << nix.VIRTIO_F_VERSION_1) |
                (1 << nix.VIRTIO_RING_F_EVENT_IDX) |
                (1 << nix.VIRTIO_BLK_F_SEG_MAX);
            if (read_only) {
                context.avail_features |= 1 << nix.VIRTIO_BLK_F_RO;
            }
            context.config.capacity = nsectors;
            context.config.seg_max = MAX_SEGMENTS;

            return Self{
                .read_only = read_only,
                .memory = memory,
                .context = context,
                .file_mem = file_mem,
                .block_id = block_id,
            };
        }

        pub fn write_default(self: *Self, offset: u64, data: []u8) void {
            self.write(nix.System, offset, data);
        }
        pub fn write(self: *Self, comptime System: type, offset: u64, data: []u8) void {
            switch (self.context.write(System, offset, data)) {
                .NoAction => {},
                .ActivateDevice => {
                    // Only VIRTIO_MMIO_INT_VRING notification type is supported.
                    if (self.context.acked_features & (1 << nix.VIRTIO_RING_F_EVENT_IDX) != 0) {
                        for (&self.context.queues) |*q| {
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
            switch (self.context.read(offset, data)) {
                .NoAction => {},
                else => |action| {
                    log.err(@src(), "unhandled read virtio action: {}", .{action});
                },
            }
        }

        pub fn sync(self: *const Self, comptime System: type) void {
            if (!self.read_only)
                nix.assert(@src(), System, "msync", .{ self.file_mem, nix.MSF.ASYNC });
        }

        pub fn event_process_queue(self: *Self) void {
            self.process_queue(nix.System);
        }
        pub fn process_queue(self: *Self, comptime System: type) void {
            const queue_event = &self.context.queue_events[self.context.selected_queue];
            _ = queue_event.read(System);

            var segments: [MAX_SEGMENTS][]volatile u8 = undefined;
            var segments_n: u32 = 0;
            var total_segments_len: u32 = 0;

            const queue = &self.context.queues[self.context.selected_queue];
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

                queue.add_used_desc(self.memory, header_desc_index, total_segments_len);
            }

            if (queue.send_notification(self.memory)) {
                self.context.notify_current_queue(System);
            }
        }
    };
}

const SubmissionsRing = struct {
    submissions: [MAX_SUBMISSIONS]Submission = .{Submission{}} ** MAX_SUBMISSIONS,
    submission_idx: u32 = 0,

    // Each request consists of 3 descriptors, so
    // the maximum number of them which can fit in
    // the chain is QUEUE_SIZE / 3
    const MAX_SUBMISSIONS = @divFloor(QUEUE_SIZE, 3);
    const Submission = struct {
        submitted: bool = false,
        queue: u1 = 0,
        desc_index: u16 = 0,
        len: u32 = 0,
    };

    pub fn add(
        self: *SubmissionsRing,
        queue: u1,
        desc_index: u16,
        len: u32,
    ) u32 {
        for (0..MAX_SUBMISSIONS) |i| {
            const offset: u32 = @intCast(i);
            const idx = (self.submission_idx + offset) % MAX_SUBMISSIONS;
            if (self.submissions[idx].submitted)
                continue;

            self.submissions[idx] = .{
                .submitted = true,
                .queue = queue,
                .desc_index = desc_index,
                .len = len,
            };
            self.submission_idx = (idx + 1) % MAX_SUBMISSIONS;
            return idx;
        }
        log.assert(@src(), false, "The submission ring is full", .{});
        unreachable;
    }
};

// For io_uring there is no VIRTIO_BLK_F_SEG_MAX feature
// so there should only be 1 segment maximum.
pub const MAX_SEGMENTS_IO_URING = 1;

pub const BlockMmioIoUring = BlockIoUring(MmioContext);
pub const BlockPciIoUring = BlockIoUring(PciContext);

pub fn BlockIoUring(comptime Context: type) type {
    return struct {
        read_only: bool,
        memory: *Memory,
        file_fd: nix.fd_t,
        block_id: [nix.VIRTIO_BLK_ID_BYTES]u8,

        io_uring_device: IoUring.Device,
        submission_ring: SubmissionsRing,

        context: Context,

        const Self = @This();

        pub fn new(
            comptime System: type,
            file_path: []const u8,
            read_only: bool,
            id: ?[nix.VIRTIO_BLK_ID_BYTES]u8,
            vm: *Vm,
            memory: *Memory,
            info: anytype,
        ) Self {
            const file_fd = nix.assert(@src(), System, "open", .{
                file_path,
                .{ .ACCMODE = if (read_only) .RDONLY else .RDWR },
                0,
            });

            const statx = nix.assert(@src(), System, "statx", .{file_fd});
            const nsectors = statx.size >> SECTOR_SHIFT;
            const block_id = if (id) |i| i else .{0} ** nix.VIRTIO_BLK_ID_BYTES;

            var context = Context.new(
                System,
                vm,
                QUEUE_SIZES,
                info,
            );
            context.avail_features =
                (1 << nix.VIRTIO_F_VERSION_1) |
                (1 << nix.VIRTIO_RING_F_EVENT_IDX);
            if (read_only) {
                context.avail_features |= (1 << nix.VIRTIO_BLK_F_RO);
            }
            context.config.capacity = nsectors;
            context.config.seg_max = MAX_SEGMENTS_IO_URING;

            return Self{
                .read_only = read_only,
                .memory = memory,
                .file_fd = file_fd,
                .context = context,
                .block_id = block_id,
                .io_uring_device = undefined,
                .submission_ring = .{},
            };
        }

        pub fn write_default(self: *Self, offset: u64, data: []u8) void {
            self.write(nix.System, offset, data);
        }
        pub fn write(self: *Self, comptime System: type, offset: u64, data: []u8) void {
            switch (self.context.write(System, offset, data)) {
                .NoAction => {},
                .ActivateDevice => {
                    // Only VIRTIO_MMIO_INT_VRING notification type is supported.
                    if (self.context.acked_features & (1 << nix.VIRTIO_RING_F_EVENT_IDX) != 0) {
                        for (&self.context.queues) |*q| {
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
            switch (self.context.read(offset, data)) {
                .NoAction => {},
                else => |action| {
                    log.err(@src(), "unhandled read virtio action: {}", .{action});
                },
            }
        }

        pub fn sync(self: *const Self, comptime System: type) void {
            if (!self.read_only)
                nix.assert(@src(), System, "fsync", .{self.file_fd});
        }

        pub fn event_process_queue(self: *Self) void {
            self.process_queue(nix.System);
        }
        pub fn process_queue(self: *Self, comptime System: type) void {
            _ = self.context.queue_events[self.context.selected_queue].read(System);

            var segments: [MAX_SEGMENTS_IO_URING][]volatile u8 = undefined;
            var segments_n: u32 = 0;
            var total_segments_len: u32 = 0;

            const queue = &self.context.queues[self.context.selected_queue];
            while (queue.pop_desc_chain(self.memory)) |dc| {
                segments_n = 0;
                total_segments_len = 0;

                var desc_chain = dc;
                const header_desc_index = desc_chain.index.?;
                const header_desc = desc_chain.next().?;
                const header = self.memory.get_ptr(nix.virtio_blk_outhdr, header_desc.addr);
                const offset = header.sector << SECTOR_SHIFT;

                var data_desc = desc_chain.next().?;

                while ((data_desc.flags & nix.VRING_DESC_F_NEXT) != 0) {
                    log.assert(
                        @src(),
                        segments_n <= MAX_SEGMENTS_IO_URING,
                        "Got descriptor chain with more data segments than MAX_SEGMENTS({d})",
                        .{@as(u32, MAX_SEGMENTS_IO_URING)},
                    );
                    segments[segments_n] = self.memory.get_slice(u8, data_desc.len, data_desc.addr);
                    total_segments_len += data_desc.len;
                    segments_n += 1;
                    data_desc = desc_chain.next().?;
                }
                const status_desc = data_desc;

                switch (header.type) {
                    nix.VIRTIO_BLK_T_IN => {
                        const i = self.submission_ring.add(
                            self.context.selected_queue,
                            header_desc_index,
                            @intCast(segments[0].len),
                        );
                        const sqe = self.io_uring_device.next_sqe();
                        sqe.prep_read(self.file_fd, @volatileCast(segments[0]), offset);
                        self.io_uring_device.finish_sqe(sqe, i);
                    },
                    nix.VIRTIO_BLK_T_OUT => {
                        const i = self.submission_ring.add(
                            self.context.selected_queue,
                            header_desc_index,
                            @intCast(segments[0].len),
                        );
                        const sqe = self.io_uring_device.next_sqe();
                        sqe.prep_write(self.file_fd, @volatileCast(segments[0]), offset);
                        self.io_uring_device.finish_sqe(sqe, i);
                    },
                    nix.VIRTIO_BLK_T_FLUSH => {
                        const i = self.submission_ring.add(
                            self.context.selected_queue,
                            header_desc_index,
                            0,
                        );
                        const sqe = self.io_uring_device.next_sqe();
                        sqe.prep_fsync(self.file_fd, nix.MSF.ASYNC);
                        self.io_uring_device.finish_sqe(sqe, i);
                    },
                    nix.VIRTIO_BLK_T_GET_ID => {
                        log.assert(
                            @src(),
                            segments_n == 1,
                            "Descriptor chain has more than 1 data descriptor for VIRTIO_BLK_T_GET_ID request",
                            .{},
                        );
                        @memcpy(segments[0], &self.block_id);

                        const status_ptr = self.memory.get_ptr(u32, status_desc.addr);
                        status_ptr.* = nix.VIRTIO_BLK_S_OK;

                        queue.add_used_desc(
                            self.memory,
                            header_desc_index,
                            nix.VIRTIO_BLK_ID_BYTES,
                        );
                        if (queue.send_notification(self.memory))
                            self.context.notify_current_queue(System);
                        continue;
                    },
                    else => log.err(@src(), "unknown virtio request type: {}", .{header.type}),
                }

                const status_ptr = self.memory.get_ptr(u32, status_desc.addr);
                status_ptr.* = nix.VIRTIO_BLK_S_OK;
            }

            self.io_uring_device.submit(System);
        }

        pub fn event_process_io_uring_event(
            self: *Self,
            cqe: *const nix.io_uring_cqe,
        ) void {
            self.process_io_uring_event(nix.System, cqe);
        }
        pub fn process_io_uring_event(
            self: *Self,
            comptime System: type,
            cqe: *const nix.io_uring_cqe,
        ) void {
            const entry_idx: IoUring.EntryIdx = @bitCast(cqe.user_data);
            const submission_info = &self.submission_ring.submissions[entry_idx.custom_idx];
            submission_info.submitted = false;

            const queue = &self.context.queues[submission_info.queue];
            queue.add_used_desc(self.memory, submission_info.desc_index, submission_info.len);

            if (queue.send_notification(self.memory))
                self.context.notify_current_queue(System);
        }
    };
}
