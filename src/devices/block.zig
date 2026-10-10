const std = @import("std");
const nix = @import("../nix.zig");
const log = @import("../log.zig");
const profiler = @import("../profiler.zig");

const Vm = @import("../vm.zig");
const CmdLine = @import("../cmdline.zig");

const _pci = @import("../virtio/pci_context.zig");
const PciVirtioContext = _pci.PciVirtioContext;

const Memory = @import("../memory.zig");
const HOST_PAGE_SIZE = Memory.HOST_PAGE_SIZE;

const _virtio = @import("../virtio/context.zig");
const VirtioContext = _virtio.VirtioContext;

pub const MEASUREMENTS = profiler.Measurements("block", &.{
    "init",
    "restore",
    "process_queue_event_with_system",
});

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
        memory: Memory.Guest,
        file_mem: []align(HOST_PAGE_SIZE) u8,
        block_id: [nix.VIRTIO_BLK_ID_BYTES]u8,

        context: Context,

        const Self = @This();

        pub fn init(
            self: *Self,
            comptime System: type,
            file_path: []const u8,
            read_only: bool,
            id: ?[nix.VIRTIO_BLK_ID_BYTES]u8,
            vm: *Vm,
            memory: Memory.Guest,
            info: anytype,
        ) void {
            const prof_point = MEASUREMENTS.start_named("init");
            defer MEASUREMENTS.end(prof_point);

            self.read_only = read_only;
            self.memory = memory;

            const fd = nix.assert(@src(), System, "open", .{
                file_path,
                .{ .ACCMODE = if (read_only) .RDONLY else .RDWR },
                0,
            });
            defer System.close(fd);

            const statx = nix.assert(@src(), System, "statx", .{fd});
            self.file_mem = nix.assert(@src(), System, "mmap", .{
                null,
                statx.size,
                .{ .READ = true, .WRITE = !read_only },
                .{ .TYPE = if (read_only) .PRIVATE else .SHARED },
                fd,
                0,
            });

            const nsectors = statx.size >> SECTOR_SHIFT;
            self.block_id = if (id) |i| i else .{0} ** nix.VIRTIO_BLK_ID_BYTES;

            self.context.init(
                System,
                vm,
                QUEUE_SIZES,
                info,
            );
            self.context.avail_features =
                (1 << nix.VIRTIO_F_VERSION_1) |
                (1 << nix.VIRTIO_RING_F_EVENT_IDX) |
                (1 << nix.VIRTIO_BLK_F_SEG_MAX);
            if (read_only) self.context.avail_features |= 1 << nix.VIRTIO_BLK_F_RO;
            self.context.config.capacity = nsectors;
            self.context.config.seg_max = MAX_SEGMENTS;
        }

        pub fn restore(
            self: *Self,
            comptime System: type,
            vm: *Vm,
            read_only: bool,
            file_path: []const u8,
            info: anytype,
        ) void {
            const prof_point = MEASUREMENTS.start_named("restore");
            defer MEASUREMENTS.end(prof_point);

            const fd = nix.assert(@src(), System, "open", .{
                file_path,
                .{ .ACCMODE = if (read_only) .RDONLY else .RDWR },
                0,
            });
            defer System.close(fd);

            const statx = nix.assert(@src(), System, "statx", .{fd});
            self.file_mem = nix.assert(@src(), System, "mmap", .{
                null,
                statx.size,
                .{ .READ = true, .WRITE = !read_only },
                .{ .TYPE = if (read_only) .PRIVATE else .SHARED },
                fd,
                0,
            });

            self.context.restore(System, vm, info);

            // Rerun queue processing in case there was an event
            // before state was saved
            self.process_queue(System);
        }

        pub fn write_with_system(self: *Self, offset: u64, data: []u8) void {
            self.write(nix.System, offset, data);
        }
        fn write(self: *Self, comptime System: type, offset: u64, data: []u8) void {
            switch (self.context.write(System, offset, data)) {
                .NoAction => {},
                .ActivateDevice => {
                    const notification_suppression =
                        self.context.acked_features & (1 << nix.VIRTIO_RING_F_EVENT_IDX) != 0;
                    for (&self.context.queues) |*q| {
                        q.activate(notification_suppression);
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

        pub fn process_queue_event_with_system(self: *Self) void {
            const prof_point = MEASUREMENTS.start(@src());
            defer MEASUREMENTS.end(prof_point);

            self.process_queue_event(nix.System);
        }
        fn process_queue_event(self: *Self, comptime System: type) void {
            const queue_event = &self.context.queue_events[self.context.selected_queue];
            _ = queue_event.read(System);
            self.process_queue(System);
        }
        pub fn process_queue(self: *Self, comptime System: type) void {
            const queue = &self.context.queues[self.context.selected_queue];
            while (queue.pop_desc_chain(self.memory)) |dc| {
                var desc_chain = dc;
                const head_index = desc_chain.index.?;

                var desc = desc_chain.next().?;
                const header = self.memory.get_ptr(nix.virtio_blk_outhdr, desc.addr);
                // Read guest header only once, so it can not be changed after validation.
                const request_type = header.type;
                const sector = header.sector;
                switch (request_type) {
                    nix.VIRTIO_BLK_T_IN, nix.VIRTIO_BLK_T_OUT => {
                        log.assert(
                            @src(),
                            sector <= self.file_mem.len >> SECTOR_SHIFT,
                            "Request sector {} is beyond the end of the device",
                            .{sector},
                        );
                    },
                    nix.VIRTIO_BLK_T_FLUSH, nix.VIRTIO_BLK_T_GET_ID => {},
                    else => log.err(@src(), "unknown virtio request type: {}", .{request_type}),
                }
                var offset = sector << SECTOR_SHIFT;

                // Data descriptors are processed while walking the chain.
                var data_len: u32 = 0;
                for (0..MAX_SEGMENTS + 1) |_| {
                    const next = desc_chain.next();
                    log.assert(@src(), next != null, "Descriptor chain ends before the status descriptor", .{});
                    desc = next.?;
                    // The status descriptor is the only one without the NEXT flag.
                    if (desc_chain.index == null) {
                        break;
                    }

                    const segment = self.memory.get_slice(u8, desc.len, desc.addr);
                    switch (request_type) {
                        nix.VIRTIO_BLK_T_IN => {
                            log.assert(
                                @src(),
                                segment.len <= self.file_mem.len - offset,
                                "Read request reaches beyond the end of the device: offset: {} len: {}",
                                .{ offset, segment.len },
                            );
                            @memcpy(segment, self.file_mem[offset..][0..segment.len]);
                            offset += segment.len;
                        },
                        nix.VIRTIO_BLK_T_OUT => {
                            log.assert(
                                @src(),
                                segment.len <= self.file_mem.len - offset,
                                "Write request reaches beyond the end of the device: offset: {} len: {}",
                                .{ offset, segment.len },
                            );
                            @memcpy(self.file_mem[offset..][0..segment.len], segment);
                            offset += segment.len;
                        },
                        nix.VIRTIO_BLK_T_GET_ID => {
                            log.assert(
                                @src(),
                                segment.len == nix.VIRTIO_BLK_ID_BYTES,
                                "VIRTIO_BLK_T_GET_ID data descriptor has invalid length: {}",
                                .{segment.len},
                            );
                            @memcpy(segment, &self.block_id);
                        },
                        else => {},
                    }
                    data_len +%= desc.len;
                } else log.panic(
                    @src(),
                    "Got descriptor chain with more data segments than MAX_SEGMENTS({d})",
                    .{@as(u32, MAX_SEGMENTS)},
                );

                if (request_type == nix.VIRTIO_BLK_T_GET_ID) {
                    log.assert(
                        @src(),
                        data_len == nix.VIRTIO_BLK_ID_BYTES,
                        "Descriptor chain has more than 1 data descriptor for VIRTIO_BLK_T_GET_ID request",
                        .{},
                    );
                }
                if (request_type == nix.VIRTIO_BLK_T_FLUSH) {
                    self.sync(System);
                }

                self.memory.get_ptr(u8, desc.addr).* = nix.VIRTIO_BLK_S_OK;
                queue.add_used_desc(self.memory, head_index, data_len);
            }

            if (queue.publish_used(self.memory)) {
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
        memory: Memory.Guest,
        file_fd: nix.fd_t,
        // Trusted device size. The config capacity can not be used, since
        // the MMIO transport lets the guest write the config.
        file_size: u64,
        block_id: [nix.VIRTIO_BLK_ID_BYTES]u8,

        io_uring_device: IoUring.Device,
        submission_ring: SubmissionsRing,

        context: Context,

        const Self = @This();

        pub fn init(
            self: *Self,
            comptime System: type,
            file_path: []const u8,
            read_only: bool,
            id: ?[nix.VIRTIO_BLK_ID_BYTES]u8,
            vm: *Vm,
            memory: Memory.Guest,
            info: anytype,
        ) void {
            self.read_only = read_only;
            self.memory = memory;
            self.file_fd = nix.assert(@src(), System, "open", .{
                file_path,
                .{ .ACCMODE = if (read_only) .RDONLY else .RDWR },
                0,
            });

            const statx = nix.assert(@src(), System, "statx", .{self.file_fd});
            self.file_size = statx.size;
            const nsectors = statx.size >> SECTOR_SHIFT;
            self.block_id = if (id) |i| i else .{0} ** nix.VIRTIO_BLK_ID_BYTES;

            self.io_uring_device = undefined;
            self.submission_ring = .{};

            self.context.init(
                System,
                vm,
                QUEUE_SIZES,
                info,
            );
            self.context.avail_features =
                (1 << nix.VIRTIO_F_VERSION_1) |
                (1 << nix.VIRTIO_RING_F_EVENT_IDX);
            if (read_only) self.context.avail_features |= (1 << nix.VIRTIO_BLK_F_RO);
            self.context.config.capacity = nsectors;
            self.context.config.seg_max = MAX_SEGMENTS_IO_URING;
        }

        pub fn restore(
            self: *Self,
            comptime System: type,
            vm: *Vm,
            read_only: bool,
            file_path: []const u8,
            info: anytype,
        ) void {
            self.file_fd = nix.assert(@src(), System, "open", .{
                file_path,
                .{ .ACCMODE = if (read_only) .RDONLY else .RDWR },
                0,
            });
            self.context.restore(System, vm, info);

            // Rerun queue processing in case there was an event
            // before state was saved
            self.process_queue(System);
        }

        pub fn write_with_system(self: *Self, offset: u64, data: []u8) void {
            self.write(nix.System, offset, data);
        }
        fn write(self: *Self, comptime System: type, offset: u64, data: []u8) void {
            switch (self.context.write(System, offset, data)) {
                .NoAction => {},
                .ActivateDevice => {
                    const notification_suppression =
                        self.context.acked_features & (1 << nix.VIRTIO_RING_F_EVENT_IDX) != 0;
                    for (&self.context.queues) |*q| {
                        q.activate(notification_suppression);
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

        pub fn process_queue_event_with_system(self: *Self) void {
            self.process_queue_event(nix.System);
        }
        fn process_queue_event(self: *Self, comptime System: type) void {
            _ = self.context.queue_events[self.context.selected_queue].read(System);
            self.process_queue(System);
        }
        fn process_queue(self: *Self, comptime System: type) void {
            var completed = false;

            const queue = &self.context.queues[self.context.selected_queue];
            while (queue.pop_desc_chain(self.memory)) |dc| {
                var desc_chain = dc;
                const head_index = desc_chain.index.?;

                var desc = desc_chain.next().?;
                const header = self.memory.get_ptr(nix.virtio_blk_outhdr, desc.addr);
                // Read guest header only once, so it can not be changed after validation.
                const request_type = header.type;
                const sector = header.sector;
                switch (request_type) {
                    nix.VIRTIO_BLK_T_IN, nix.VIRTIO_BLK_T_OUT => {
                        log.assert(
                            @src(),
                            sector <= self.file_size >> SECTOR_SHIFT,
                            "Request sector {} is beyond the end of the device",
                            .{sector},
                        );
                    },
                    nix.VIRTIO_BLK_T_FLUSH, nix.VIRTIO_BLK_T_GET_ID => {},
                    else => log.err(@src(), "unknown virtio request type: {}", .{request_type}),
                }
                const offset = sector << SECTOR_SHIFT;

                var segment: ?[]volatile u8 = null;
                const next = desc_chain.next();
                log.assert(@src(), next != null, "Descriptor chain ends before the status descriptor", .{});
                desc = next.?;
                // The status descriptor is the only one without the NEXT flag.
                if (desc_chain.index != null) {
                    segment = self.memory.get_slice(u8, desc.len, desc.addr);
                    desc = desc_chain.next().?;
                    log.assert(
                        @src(),
                        desc_chain.index == null,
                        "Got descriptor chain with more data segments than MAX_SEGMENTS({d})",
                        .{@as(u32, MAX_SEGMENTS_IO_URING)},
                    );
                }

                self.memory.get_ptr(u8, desc.addr).* = nix.VIRTIO_BLK_S_OK;

                switch (request_type) {
                    nix.VIRTIO_BLK_T_IN, nix.VIRTIO_BLK_T_OUT => {
                        log.assert(@src(), segment != null, "Read/write request without data descriptor", .{});
                        const data = segment.?;
                        log.assert(
                            @src(),
                            data.len <= self.file_size - offset,
                            "Request reaches beyond the end of the device: offset: {} len: {}",
                            .{ offset, data.len },
                        );
                        const i = self.submission_ring.add(
                            self.context.selected_queue,
                            head_index,
                            @intCast(data.len),
                        );
                        const sqe = self.io_uring_device.next_sqe();
                        if (request_type == nix.VIRTIO_BLK_T_IN)
                            sqe.prep_read(self.file_fd, @volatileCast(data), offset)
                        else
                            sqe.prep_write(self.file_fd, @volatileCast(data), offset);
                        self.io_uring_device.finish_sqe(sqe, i);
                    },
                    nix.VIRTIO_BLK_T_FLUSH => {
                        const i = self.submission_ring.add(self.context.selected_queue, head_index, 0);
                        const sqe = self.io_uring_device.next_sqe();
                        sqe.prep_fsync(self.file_fd, nix.MSF.ASYNC);
                        self.io_uring_device.finish_sqe(sqe, i);
                    },
                    nix.VIRTIO_BLK_T_GET_ID => {
                        log.assert(
                            @src(),
                            segment != null and segment.?.len == nix.VIRTIO_BLK_ID_BYTES,
                            "VIRTIO_BLK_T_GET_ID data descriptor is missing or has invalid length",
                            .{},
                        );
                        @memcpy(segment.?, &self.block_id);
                        queue.add_used_desc(self.memory, head_index, nix.VIRTIO_BLK_ID_BYTES);
                        completed = true;
                    },
                    else => {
                        const len: u32 = if (segment) |data| @intCast(data.len) else 0;
                        queue.add_used_desc(self.memory, head_index, len);
                        completed = true;
                    },
                }
            }

            if (completed and queue.publish_used(self.memory)) {
                self.context.notify_current_queue(System);
            }
            self.io_uring_device.submit(System);
        }

        pub fn process_io_uring_event_with_system(self: *Self, cqe: *const nix.io_uring_cqe) void {
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

            if (queue.publish_used(self.memory))
                self.context.notify_current_queue(System);
        }
    };
}
