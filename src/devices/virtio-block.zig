const std = @import("std");
const nix = @import("../nix.zig");
const log = @import("../log.zig");

const CmdLine = @import("../cmdline.zig");
const MmioDeviceInfo = @import("../mmio.zig").MmioDeviceInfo;
const GuestMemory = @import("../memory.zig").GuestMemory;
const VIRTIO = @import("../virtio/context.zig");
const VirtioContext = VIRTIO.VirtioContext;
const VirtioAction = VIRTIO.VirtioAction;

pub const CONFIG_SPACE_SIZE: usize = 8;
pub const SECTOR_SHIFT: u8 = 9;
pub const TYPE_BLOCK: u32 = 2;

pub const VirtioBlockConfig = [CONFIG_SPACE_SIZE]u8;

pub const VirtioBlock = struct {
    read_only: bool,
    guest_memory: *GuestMemory,
    virtio_context: VirtioContext(VirtioBlockConfig),
    mmio_info: MmioDeviceInfo,
    file: std.fs.File,

    const Self = @This();

    pub fn new(file_path: []const u8, read_only: bool, guest_memory: *GuestMemory, mmio_info: MmioDeviceInfo) !Self {
        const file = try std.fs.cwd().openFile(file_path, .{});
        const meta = try file.metadata();
        const nsectors = meta.size() >> SECTOR_SHIFT;

        log.info(@src(), "nsectors: {}", .{nsectors});

        var virtio_context = try VirtioContext(VirtioBlockConfig).new(TYPE_BLOCK);
        virtio_context.avail_features = (1 << nix.VIRTIO_F_VERSION_1) | (1 << nix.VIRTIO_RING_F_EVENT_IDX);
        if (read_only) {
            virtio_context.avail_features |= 1 << nix.VIRTIO_BLK_F_RO;
        }

        const nsectors_slice = std.mem.asBytes(&nsectors);
        const config_slice = std.mem.asBytes(&virtio_context.config_blob);
        std.mem.copy(u8, config_slice, nsectors_slice);

        return Self{
            .read_only = read_only,
            .guest_memory = guest_memory,
            .virtio_context = virtio_context,
            .mmio_info = mmio_info,
            .file = file,
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
            VirtioAction.ActivateDevice => self.activate(),
            else => {},
        }
        return true;
    }

    pub fn read(self: *Self, addr: u64, data: []u8) !bool {
        if (addr < self.mmio_info.addr or self.mmio_info.addr + self.mmio_info.len - 1 < addr) {
            return false;
        }
        const offset = addr - self.mmio_info.addr;
        switch (self.virtio_context.read(offset, data)) {
            else => {},
        }
        return true;
    }

    pub fn activate(self: *Self) void {
        self.virtio_context.queue.patch_ptrs(self.guest_memory);
    }
};
