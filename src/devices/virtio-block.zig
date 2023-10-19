const std = @import("std");
const nix = @import("../nix.zig");
const log = @import("../log.zig");

const MmioDeviceInfo = @import("../mmio.zig").MmioDeviceInfo;
const VIRTIO_CONTEXT = @import("../virtio/context.zig");
const VirtioContext = VIRTIO_CONTEXT.VirtioContext;
const VirtioAction = VIRTIO_CONTEXT.VirtioAction;

pub const CONFIG_SPACE_SIZE: usize = 8;
pub const SECTOR_SHIFT: u8 = 9;
pub const TYPE_BLOCK: u32 = 2;

pub const VirtioBlockConfig = [CONFIG_SPACE_SIZE]u8;

pub const VirtioBlock = struct {
    virtio_context: VirtioContext(VirtioBlockConfig),
    mmio_info: MmioDeviceInfo,
    file: std.fs.File,
    nsectors: u64,

    const Self = @This();

    pub fn new(file_path: []const u8, mmio_info: MmioDeviceInfo) !Self {
        const file = try std.fs.openFileAbsolute(file_path, .{});
        const meta = try file.metadata();
        const nsectors = meta.size() >> SECTOR_SHIFT;
        return Self{
            .virtio_context = try VirtioContext(VirtioBlockConfig).new(TYPE_BLOCK),
            .mmio_info = mmio_info,
            .file = file,
            .nsectors = nsectors,
        };
    }

    pub fn write(self: *Self, addr: u64, data: []u8) !bool {
        if (addr < self.mmio_info.addr or self.mmio_info.addr + self.mmio_info.len < addr) {
            return false;
        }
        const offset = addr - self.mmio_info.addr;
        switch (self.virtio_context.write(offset, data)) {
            else => {},
        }
        return true;
    }

    pub fn read(self: *Self, addr: u64, data: []u8) !bool {
        if (addr < self.mmio_info.addr or self.mmio_info.addr + self.mmio_info.len < addr) {
            return false;
        }
        const offset = addr - self.mmio_info.addr;
        switch (self.virtio_context.read(offset, data)) {
            else => {},
        }
        return true;
    }
};
