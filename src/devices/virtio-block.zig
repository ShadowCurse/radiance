const std = @import("std");
const nix = @import("../nix.zig");
const log = @import("../log.zig");

const Vm = @import("../vm.zig");
const CmdLine = @import("../cmdline.zig");
const MmioDeviceInfo = @import("../mmio.zig").MmioDeviceInfo;
const Memory = @import("../memory.zig");
const VIRTIO = @import("../virtio/context.zig");
const VirtioContext = VIRTIO.VirtioContext;
const VirtioAction = VIRTIO.VirtioAction;

pub const CONFIG_SPACE_SIZE: usize = 8;
pub const SECTOR_SHIFT: u8 = 9;
pub const TYPE_BLOCK: u32 = 2;

pub const VirtioBlockConfig = [CONFIG_SPACE_SIZE]u8;

pub const VirtioBlockError = error{
    New,
};

pub const VirtioBlock = struct {
    read_only: bool,
    memory: *Memory,
    virtio_context: VirtioContext(1, VirtioBlockConfig),
    mmio_info: MmioDeviceInfo,
    file: std.fs.File,
    block_id: [nix.VIRTIO_BLK_ID_BYTES]u8,

    const Self = @This();

    pub fn new(
        vm: *const Vm,
        file_path: []const u8,
        read_only: bool,
        memory: *Memory,
        mmio_info: MmioDeviceInfo,
    ) !Self {
        var file_options: std.fs.File.OpenFlags = .{};
        if (read_only) {
            file_options.mode = std.fs.File.OpenMode.read_write;
        }
        const file = try std.fs.cwd().openFile(file_path, file_options);
        const meta = try file.metadata();
        const nsectors = meta.size() >> SECTOR_SHIFT;

        var block_id = [_]u8{0} ** nix.VIRTIO_BLK_ID_BYTES;
        var dev_major = meta.inner.statx.dev_major;
        dev_major = dev_major << 16;
        dev_major = dev_major << 16;
        const dev = meta.inner.statx.dev_minor | dev_major;

        var rdev_major = meta.inner.statx.rdev_major;
        rdev_major = rdev_major << 16;
        rdev_major = rdev_major << 16;
        const rdev = meta.inner.statx.rdev_minor | rdev_major;

        _ = try std.fmt.bufPrint(&block_id, "{}{}{}", .{ dev, rdev, meta.inner.statx.ino });

        var virtio_context = try VirtioContext(1, VirtioBlockConfig).new(TYPE_BLOCK);
        virtio_context.avail_features = (1 << nix.VIRTIO_F_VERSION_1); // | (1 << nix.VIRTIO_RING_F_EVENT_IDX);
        if (read_only) {
            virtio_context.avail_features |= 1 << nix.VIRTIO_BLK_F_RO;
        }

        const nsectors_slice = std.mem.asBytes(&nsectors);
        const config_slice = std.mem.asBytes(&virtio_context.config_blob);
        @memcpy(config_slice, nsectors_slice);

        var kvm_irqfd = std.mem.zeroInit(nix.kvm_irqfd, .{});
        kvm_irqfd.fd = @intCast(virtio_context.irq_evt.fd);
        kvm_irqfd.gsi = mmio_info.irq;
        _ = try nix.checked_ioctl(
            @src(),
            VirtioBlockError.New,
            vm.fd,
            nix.KVM_IRQFD,
            &kvm_irqfd,
        );

        for (&virtio_context.queue_events, 0..) |*queue_event, i| {
            var kvm_ioeventfd = std.mem.zeroInit(nix.kvm_ioeventfd, .{});
            kvm_ioeventfd.datamatch = i;
            kvm_ioeventfd.len = @sizeOf(u32);
            kvm_ioeventfd.addr = mmio_info.addr + 0x50;
            kvm_ioeventfd.fd = queue_event.fd;
            kvm_ioeventfd.flags = 1 << nix.kvm_ioeventfd_flag_nr_datamatch;
            _ = try nix.checked_ioctl(
                @src(),
                VirtioBlockError.New,
                vm.fd,
                nix.KVM_IOEVENTFD,
                &kvm_ioeventfd,
            );
        }

        return Self{
            .read_only = read_only,
            .memory = memory,
            .virtio_context = virtio_context,
            .mmio_info = mmio_info,
            .file = file,
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

    pub fn write(self: *Self, addr: u64, data: []u8) !bool {
        if (addr < self.mmio_info.addr or self.mmio_info.addr + self.mmio_info.len - 1 < addr) {
            return false;
        }
        const offset = addr - self.mmio_info.addr;
        switch (self.virtio_context.write(offset, data)) {
            VirtioAction.NoAction => {},
            VirtioAction.ActivateDevice => {},
            else => |action| {
                log.err(@src(), "unhandled write virtio action: {}", .{action});
            },
        }
        return true;
    }

    pub fn read(self: *Self, addr: u64, data: []u8) !bool {
        if (addr < self.mmio_info.addr or self.mmio_info.addr + self.mmio_info.len - 1 < addr) {
            return false;
        }
        const offset = addr - self.mmio_info.addr;
        switch (self.virtio_context.read(offset, data)) {
            VirtioAction.NoAction => {},
            else => |action| {
                log.err(@src(), "unhandled read virtio action: {}", .{action});
            },
        }
        return true;
    }

    pub fn process_queue(self: *Self) !void {
        _ = try self.virtio_context.queue_events[self.virtio_context.selected_queue].read();

        while (self.virtio_context.queues[self.virtio_context.selected_queue].pop_desc_chain(self.memory)) |dc| {
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
                        try self.file.seekTo(offset);
                        var buffer: []u8 = undefined;
                        buffer.ptr = @ptrCast(self.memory.get_ptr(u8, data_addr));
                        buffer.len = data_len;
                        data_transfered = try self.file.read(buffer);
                    },
                    nix.VIRTIO_BLK_T_OUT => {
                        try self.file.seekTo(offset);
                        var buffer: []const u8 = undefined;
                        buffer.ptr = @ptrCast(self.memory.get_ptr(u8, data_addr));
                        buffer.len = data_len;
                        data_transfered = try self.file.write(buffer);
                    },
                    nix.VIRTIO_BLK_T_FLUSH => {
                        try self.file.sync();
                    },
                    nix.VIRTIO_BLK_T_GET_ID => {
                        var buffer: []u8 = undefined;
                        buffer.ptr = @ptrCast(self.memory.get_ptr(u8, data_addr));
                        buffer.len = data_len;
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
                try self.file.sync();

                const status_ptr = self.memory.get_ptr(u32, second_desc.addr);
                status_ptr.* = nix.VIRTIO_BLK_S_OK;
            }

            try self.virtio_context.irq_evt.write(1);
        }
    }
};
