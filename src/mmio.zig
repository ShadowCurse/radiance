const std = @import("std");
const log = @import("log.zig");
const Memory = @import("memory.zig");
const Gicv2 = @import("gicv2.zig");
const Uart = @import("devices/uart.zig");
const Rtc = @import("devices/rtc.zig");
const VirtioBlock = @import("devices/virtio-block.zig").VirtioBlock;

pub const MMIO_MEM_START: u64 = Memory.MMIO_START;
/// The size of the memory area reserved for MMIO devices.
pub const MMIO_MEM_SIZE: u64 = Memory.DRAM_START - Memory.MMIO_START;
/// Size of memory reserved for each mmio device.
/// Needs to be bigger than 0x100.
pub const MMIO_LEN: u64 = 0x1000;

pub const MmioDeviceTag = enum {
    Uart,
    Rtc,
    VirtioBlock,
};

pub const MmioDevice = union(MmioDeviceTag) {
    Uart: *Uart,
    Rtc: *Rtc,
    VirtioBlock: *VirtioBlock,
};

pub const MmioDeviceInfo = struct {
    addr: u64,
    len: u64,
    irq: u32,
};

last_irq: u32,
last_address: u64,
num_devices: usize,
devices: [10]MmioDevice,
mutex: std.Thread.Mutex,

const Self = @This();

pub fn new() Self {
    return Self{ .last_irq = Gicv2.IRQ_BASE, .last_address = MMIO_MEM_START, .num_devices = 0, .devices = undefined, .mutex = .{} };
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
    self.mutex.lock();
    defer self.mutex.unlock();
    var handled: bool = false;
    for (self.devices[0..self.num_devices]) |device| {
        switch (device) {
            .Uart => |uart| handled = try uart.write(addr, data),
            .Rtc => |rtc| handled = try rtc.write(addr, data),
            .VirtioBlock => |vb| handled = try vb.write(addr, data),
        }
        if (handled) {
            break;
        }
    }
    if (!handled) {
        log.err(@src(), "unhandled mmio write addr: {x} data: {any}", .{ addr, data });
    }
}

pub fn read(self: *Self, addr: u64, data: []u8) !void {
    self.mutex.lock();
    defer self.mutex.unlock();
    var handled: bool = false;
    for (self.devices[0..self.num_devices]) |device| {
        switch (device) {
            .Uart => |uart| handled = try uart.read(addr, data),
            .Rtc => |rtc| handled = try rtc.read(addr, data),
            .VirtioBlock => |vb| handled = try vb.read(addr, data),
        }
        if (handled) {
            break;
        }
    }
    if (!handled) {
        log.err(@src(), "unhandled mmio read addr: {x} data: {any}", .{ addr, data });
    }
}
