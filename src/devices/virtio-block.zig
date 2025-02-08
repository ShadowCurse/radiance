const std = @import("std");
const nix = @import("../nix.zig");
const log = @import("../log.zig");

const Vm = @import("../vm.zig");
const CmdLine = @import("../cmdline.zig");
const MmioDeviceInfo = @import("../mmio.zig").MmioDeviceInfo;

const Memory = @import("../memory.zig");
const HOST_PAGE_SIZE = Memory.HOST_PAGE_SIZE;

const VIRTIO = @import("../virtio/context.zig");
const VirtioContext = VIRTIO.VirtioContext;
const VirtioAction = VIRTIO.VirtioAction;

pub const SECTOR_SHIFT: u8 = 9;
pub const TYPE_BLOCK: u32 = 2;

pub const Config = extern struct {
    capacity: u64,
};
pub const QueueSizes = .{ 256, 256 };

pub const VirtioBlock = struct {
    read_only: bool,
    memory: *Memory,
    virtio_context: VIRTIO_CONTEXT,
    file_mem: []align(HOST_PAGE_SIZE) u8,
    block_id: [nix.VIRTIO_BLK_ID_BYTES]u8,

    const Self = @This();
    const VIRTIO_CONTEXT = VirtioContext(QueueSizes.len, TYPE_BLOCK, Config);

    pub fn new(
        vm: *Vm,
        file_path: []const u8,
        read_only: bool,
        memory: *Memory,
        mmio_info: MmioDeviceInfo,
    ) Self {
        const fd = nix.assert(@src(), nix.open, .{
            file_path,
            .{ .ACCMODE = if (read_only) .RDONLY else .RDWR },
            0,
        });
        defer nix.close(fd);

        const statx = nix.assert(@src(), nix.statx, .{fd});

        const file_mem = nix.assert(@src(), nix.mmap, .{
            null,
            statx.size,
            if (read_only) nix.PROT.READ else nix.PROT.READ | nix.PROT.WRITE,
            .{ .TYPE = .PRIVATE },
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
            vm,
            QueueSizes,
            mmio_info.irq,
            mmio_info.addr,
        );
        virtio_context.avail_features = (1 << nix.VIRTIO_F_VERSION_1) |
            (1 << nix.VIRTIO_RING_F_EVENT_IDX);
        if (read_only) {
            virtio_context.avail_features |= 1 << nix.VIRTIO_BLK_F_RO;
        }
        virtio_context.config.capacity = nsectors;

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

    pub fn write(self: *Self, offset: u64, data: []u8) void {
        switch (self.virtio_context.write(offset, data)) {
            VirtioAction.NoAction => {},
            VirtioAction.ActivateDevice => {
                self.virtio_context.set_memory();

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
            VirtioAction.NoAction => {},
            else => |action| {
                log.err(@src(), "unhandled read virtio action: {}", .{action});
            },
        }
    }

    pub fn process_queue(self: *Self) void {
        _ = self.virtio_context.queue_events[self.virtio_context.selected_queue].read();

        const queue = &self.virtio_context.queues[self.virtio_context.selected_queue];
        while (queue.pop_desc_chain(self.memory)) |dc| {
            var desc_chain = dc;
            const first_desc_index = desc_chain.index.?;
            const first_desc = desc_chain.next().?;
            const header = self.memory.get_ptr(nix.virtio_blk_outhdr, first_desc.addr);
            const offset = header.sector << SECTOR_SHIFT;

            const second_desc = desc_chain.next().?;
            const data_addr = second_desc.addr;
            const data_len = second_desc.len;
            // if has next
            if ((second_desc.flags & nix.VRING_DESC_F_NEXT) != 0) {
                const third_desc = desc_chain.next().?;
                var data_transfered: usize = 0;
                switch (header.type) {
                    nix.VIRTIO_BLK_T_IN => {
                        const buffer = self.memory.get_slice(u8, data_len, data_addr);
                        @memcpy(buffer, self.file_mem[offset .. offset + buffer.len]);
                    },
                    nix.VIRTIO_BLK_T_OUT => {
                        const buffer = self.memory.get_slice(u8, data_len, data_addr);
                        @memcpy(self.file_mem[offset .. offset + buffer.len], buffer);
                    },
                    nix.VIRTIO_BLK_T_FLUSH => {
                        // TODO maybe add a msync with SYNC call at the end of VM lifetime
                        nix.assert(@src(), nix.msync, .{ self.file_mem, nix.MSF.ASYNC });
                    },
                    nix.VIRTIO_BLK_T_GET_ID => {
                        const buffer = self.memory.get_slice(u8, data_len, data_addr);
                        @memcpy(buffer, &self.block_id);
                        data_transfered = nix.VIRTIO_BLK_ID_BYTES;
                    },
                    else => log.err(@src(), "unknown virtio request type: {}", .{header.type}),
                }

                const status_ptr = self.memory.get_ptr(u32, third_desc.addr);
                status_ptr.* = nix.VIRTIO_BLK_S_OK;

                self.virtio_context.queues[self.virtio_context.selected_queue]
                    .add_used_desc(self.memory, first_desc_index, @intCast(data_transfered + 1));
            } else {
                if (!self.read_only) {
                    nix.assert(@src(), nix.msync, .{ self.file_mem, nix.MSF.ASYNC });
                }

                const status_ptr = self.memory.get_ptr(u32, second_desc.addr);
                status_ptr.* = nix.VIRTIO_BLK_S_OK;
            }
        }

        if (self.virtio_context.queues[self.virtio_context.selected_queue]
            .send_notification(self.memory))
        {
            self.virtio_context.irq_evt.write(1);
        }
    }
};
