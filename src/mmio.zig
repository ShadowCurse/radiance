const std = @import("std");
const log = @import("log.zig");
const Memory = @import("memory.zig");
const Gicv2 = @import("gicv2.zig");
const Uart = @import("devices/uart.zig");
const Rtc = @import("devices/rtc.zig");
const VirtioBlock = @import("devices/virtio-block.zig").VirtioBlock;
const VhostNet = @import("devices/vhost-net.zig").VhostNet;
const VirtioNet = @import("devices/virtio-net.zig").VirtioNet;

const VIRTIO_INTERRUPT_STATUS_OFFSET = @import("virtio/context.zig").INTERRUPT_STATUS_OFFSET;

pub const MMIO_MEM_START: u64 = Memory.MMIO_START;
pub const MMIO_MEM_SIZE: u64 = Memory.DRAM_START - Memory.MMIO_START;
pub const MMIO_DEVICE_SIZE: u64 = Memory.GUEST_PAGE_SIZE;

pub const MmioDevice = struct {
    ptr: *anyopaque,
    read_ptr: *const fn (*anyopaque, u64, []u8) anyerror!void,
    write_ptr: *const fn (*anyopaque, u64, []u8) anyerror!void,

    pub fn read(self: *const MmioDevice, addr: u64, data: []u8) anyerror!void {
        return self.read_ptr(self.ptr, addr, data);
    }
    pub fn write(self: *const MmioDevice, addr: u64, data: []u8) anyerror!void {
        return self.write_ptr(self.ptr, addr, data);
    }
};

pub const MmioDeviceInfo = struct {
    addr: u64,
    len: u64,
    irq: u32,
};

last_irq: u16,
last_address: u64,
virtio_address_start: u64,

num_devices: u8,
devices: [2]MmioDevice,

virtio_num_devices: u8,
virtio_devices: [8]MmioDevice,

const Self = @This();

pub fn new() Self {
    return Self{
        .last_irq = Gicv2.IRQ_BASE,
        .last_address = MMIO_MEM_START,
        .virtio_address_start = MMIO_MEM_START,
        .num_devices = 0,
        .devices = undefined,
        .virtio_num_devices = 0,
        .virtio_devices = undefined,
    };
}

pub fn start_mmio_opt(self: *Self) void {
    self.virtio_address_start = self.last_address;
}

// MMIO devices should be allocated before VIRTIO devices.
// Devices are allocated one after another each taking
// MMIO_DEVICE_SIZE space in the MMIO region.
pub fn allocate(self: *Self) MmioDeviceInfo {
    const addr = self.last_address;
    self.last_address += MMIO_DEVICE_SIZE;
    const irq = self.last_irq;
    self.last_irq += 1;
    log.debug(
        @src(),
        "allocate mmio region: addr: 0x{x}, len: 0x{x}, irq: {}",
        .{ addr, MMIO_DEVICE_SIZE, irq },
    );
    return MmioDeviceInfo{
        .addr = addr,
        .len = MMIO_DEVICE_SIZE,
        .irq = irq,
    };
}

// VIRTIO devices should be allocated after all MMIO devices
// are allocated. VIRTIO MMIO space will be offset from the
// beginning of the page by (MMIO_DEVICE_SIZE - VIRTIO_INTERRUPT_STATUS_OFFSET) and thus
// will be split between 2 guest physical pages.
pub fn allocate_virtio(self: *Self) MmioDeviceInfo {
    const addr = self.last_address + MMIO_DEVICE_SIZE - VIRTIO_INTERRUPT_STATUS_OFFSET;
    self.last_address += MMIO_DEVICE_SIZE;
    const irq = self.last_irq;
    self.last_irq += 1;
    log.debug(
        @src(),
        "allocate mmio opt region: addr: 0x{x}, len: 0x{x}, irq: {}",
        .{ addr, MMIO_DEVICE_SIZE, irq },
    );
    return MmioDeviceInfo{
        .addr = addr,
        .len = MMIO_DEVICE_SIZE,
        .irq = irq,
    };
}

pub fn add_device(self: *Self, device: MmioDevice) void {
    self.devices[self.num_devices] = device;
    self.num_devices += 1;
}

pub fn add_device_virtio(self: *Self, device: MmioDevice) void {
    self.virtio_devices[self.virtio_num_devices] = device;
    self.virtio_num_devices += 1;
}

pub fn write(self: *Self, addr: u64, data: []u8) !void {
    if (addr < self.virtio_address_start) {
        const index = (addr - MMIO_MEM_START) / MMIO_DEVICE_SIZE;
        const offset = (addr - MMIO_MEM_START) - MMIO_DEVICE_SIZE * index;
        const device = self.devices[index];
        try device.write(offset, data);
    } else {
        const index = (addr - self.virtio_address_start) / MMIO_DEVICE_SIZE / 2;
        const offset = (addr - self.virtio_address_start) -
            (MMIO_DEVICE_SIZE * index * 2) -
            (MMIO_DEVICE_SIZE - VIRTIO_INTERRUPT_STATUS_OFFSET);
        const device = self.virtio_devices[index];
        try device.write(offset, data);
    }
}

pub fn read(self: *Self, addr: u64, data: []u8) !void {
    if (addr < self.virtio_address_start) {
        const index = (addr - MMIO_MEM_START) / MMIO_DEVICE_SIZE;
        const offset = (addr - MMIO_MEM_START) - MMIO_DEVICE_SIZE * index;
        const device = self.devices[index];
        try device.read(offset, data);
    } else {
        const index = (addr - self.virtio_address_start) / MMIO_DEVICE_SIZE / 2;
        const offset = (addr - self.virtio_address_start) -
            (MMIO_DEVICE_SIZE * index * 2) -
            (MMIO_DEVICE_SIZE - VIRTIO_INTERRUPT_STATUS_OFFSET);
        const device = self.virtio_devices[index];
        try device.read(offset, data);
    }
}
