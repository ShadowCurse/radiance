const std = @import("std");
const log = @import("log.zig");
const Memory = @import("memory.zig");
const Gicv2 = @import("gicv2.zig");
const Uart = @import("devices/uart.zig");
const Rtc = @import("devices/rtc.zig");
const VirtioBlock = @import("devices/virtio-block.zig").VirtioBlock;
const VhostNet = @import("devices/vhost-net.zig").VhostNet;
const VirtioNet = @import("devices/virtio-net.zig").VirtioNet;

pub const MMIO_MEM_START: u64 = Memory.MMIO_START;
/// The size of the memory area reserved for MMIO devices.
pub const MMIO_MEM_SIZE: u64 = Memory.DRAM_START - Memory.MMIO_START;
/// Size of memory reserved for each mmio device.
/// Needs to be bigger than 0x100.
pub const MMIO_LEN: u64 = 0x1000;

pub const MmioDevice = union(enum) {
    Uart: *Uart,
    Rtc: *Rtc,
    VirtioBlock: *VirtioBlock,
    VhostNet: *VhostNet,
    VirtioNet: *VirtioNet,
};

pub const MmioDeviceInfo = struct {
    addr: u64,
    len: u64,
    irq: u32,

    pub fn contains_addr(
        self: *const MmioDeviceInfo,
        addr: u64,
    ) bool {
        return self.addr <= addr and addr < self.addr + self.len;
    }
};

last_irq: u32,
last_address: u64,
num_devices: usize,
devices: [10]MmioDevice,

const Self = @This();

pub fn new() Self {
    return Self{
        .last_irq = Gicv2.IRQ_BASE,
        .last_address = MMIO_MEM_START,
        .num_devices = 0,
        .devices = undefined,
    };
}

pub fn allocate(self: *Self) MmioDeviceInfo {
    const addr = self.last_address;
    self.last_address += MMIO_LEN;
    const irq = self.last_irq;
    self.last_irq += 1;
    return MmioDeviceInfo{
        .addr = addr,
        .len = MMIO_LEN,
        .irq = irq,
    };
}

pub fn add_device(self: *Self, device: MmioDevice) void {
    self.devices[self.num_devices] = device;
    self.num_devices += 1;
}

pub fn write(self: *Self, addr: u64, data: []u8) !void {
    var handled: bool = false;
    for (self.devices[0..self.num_devices]) |device| {
        switch (device) {
            .Uart => |uart| handled = try uart.write(addr, data),
            .Rtc => |rtc| handled = try rtc.write(addr, data),
            .VirtioBlock => |vb| handled = try vb.write(addr, data),
            .VhostNet => |vn| handled = try vn.write(addr, data),
            .VirtioNet => |vn| handled = try vn.write(addr, data),
        }
        if (handled) {
            break;
        }
    }
    if (!handled) {
        log.err(
            @src(),
            "unhandled mmio write addr: {x} data: {any}",
            .{ addr, data },
        );
    }
}

pub fn read(self: *Self, addr: u64, data: []u8) !void {
    var handled: bool = false;
    for (self.devices[0..self.num_devices]) |device| {
        switch (device) {
            .Uart => |uart| handled = try uart.read(addr, data),
            .Rtc => |rtc| handled = try rtc.read(addr, data),
            .VirtioBlock => |vb| handled = try vb.read(addr, data),
            .VhostNet => |vn| handled = try vn.read(addr, data),
            .VirtioNet => |vn| handled = try vn.read(addr, data),
        }
        if (handled) {
            break;
        }
    }
    if (!handled) {
        log.err(
            @src(),
            "unhandled mmio read addr: {x} data: {any}",
            .{ addr, data },
        );
    }
}
