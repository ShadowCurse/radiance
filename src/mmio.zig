const log = @import("log.zig");
const Memory = @import("memory.zig");
const Gicv2 = @import("gicv2.zig");

const Ecam = @import("virtio/ecam.zig");
const Gicv2Mmio = @import("gicv2.zig").Gicv2Mmio;

const VIRTIO_INTERRUPT_STATUS_OFFSET = @import("virtio/context.zig").INTERRUPT_STATUS_OFFSET;

pub const MMIO_MEM_START: u64 = Memory.MMIO_START;
pub const MMIO_MEM_SIZE: u64 = Memory.DRAM_START - Memory.MMIO_START;
// The region the guest will access. This is host/guest kernel page size
// independent.
pub const MMIO_DEVICE_REGION_SIZE: u64 = 0x1000;
// The region size which will be reserved from a guest physical memory.
pub const MMIO_DEVICE_ALLOCATED_REGION_SIZE: u64 = Memory.HOST_PAGE_SIZE;

pub const UART_INDEX = 0;
pub const UART_ADDR = MMIO_MEM_START;
pub const UART_IRQ = Gicv2.IRQ_BASE;
pub const RTC_INDEX = 1;
pub const RTC_ADDR = UART_ADDR + MMIO_DEVICE_ALLOCATED_REGION_SIZE;
pub const VIRTIO_IRQ_START = UART_IRQ + 1;
pub const VIRTIO_ADDRESS_START = RTC_ADDR + MMIO_DEVICE_ALLOCATED_REGION_SIZE;

pub const Resources = struct {
    last_irq: u16 = VIRTIO_IRQ_START,
    last_address: u64 = VIRTIO_ADDRESS_START,
    last_bar_address: u64 = Memory.PCI_START,

    pub const MmioVirtioInfo = struct {
        addr: u64,
        len: u32,
        irq: u32,
        mem_ptr: [*]align(Memory.HOST_PAGE_SIZE) u8,
    };
    // VIRTIO devices should be allocated after all MMIO devices
    // are allocated. VIRTIO MMIO space will be offset from the
    // beginning of the page by
    // MMIO_DEVICE_ALLOCATED_REGION_SIZE - VIRTIO_INTERRUPT_STATUS_OFFSET
    // and thus will be split between 2 guest physical pages.
    pub fn allocate_mmio_virtio(self: *Resources) MmioVirtioInfo {
        const addr =
            self.last_address + MMIO_DEVICE_ALLOCATED_REGION_SIZE - VIRTIO_INTERRUPT_STATUS_OFFSET;
        self.last_address += 2 * MMIO_DEVICE_ALLOCATED_REGION_SIZE;
        const irq = self.last_irq;
        self.last_irq += 1;
        log.debug(
            @src(),
            "allocate mmio opt region: addr: 0x{x}, len: 0x{x}, irq: {}",
            .{ addr, MMIO_DEVICE_ALLOCATED_REGION_SIZE, irq },
        );
        return .{
            .addr = addr,
            .len = MMIO_DEVICE_REGION_SIZE,
            .irq = irq,
            .mem_ptr = undefined,
        };
    }

    pub const PciInfo = struct { bar_addr: u64 };
    pub fn allocate_pci(self: *Resources) PciInfo {
        const addr = self.last_bar_address;
        self.last_bar_address += Memory.PCI_BAR_SIZE;
        log.debug(
            @src(),
            "allocate pci region: addr: 0x{x}, len: 0x{x}",
            .{ addr, @as(u32, Memory.PCI_BAR_SIZE) },
        );
        return .{ .bar_addr = addr };
    }
};

mmio_devices: [MAX_MMIO_DEVICES]MmioDevice,
virtio_num_devices: u8,
virtio_devices: [MAX_VIRTIO_DEVICES]MmioDevice,

pci_num_devices: u8,
pci_devices: [MAX_VIRTIO_DEVICES]MmioDevice,
ecam: *Ecam,

const MAX_MMIO_DEVICES = 2;
const MAX_VIRTIO_DEVICES = 8;

pub const MmioDevice = struct {
    ptr: *anyopaque,
    read_ptr: *const fn (*anyopaque, u64, []u8) void,
    write_ptr: *const fn (*anyopaque, u64, []u8) void,

    pub fn read(self: *const MmioDevice, addr: u64, data: []u8) void {
        return self.read_ptr(self.ptr, addr, data);
    }
    pub fn write(self: *const MmioDevice, addr: u64, data: []u8) void {
        return self.write_ptr(self.ptr, addr, data);
    }
};

const Self = @This();

pub fn init(ecam: *Ecam) Self {
    return .{
        .mmio_devices = undefined,
        .virtio_num_devices = 0,
        .virtio_devices = undefined,
        .pci_num_devices = 0,
        .pci_devices = undefined,
        .ecam = ecam,
    };
}

pub fn set_uart(self: *Self, device: MmioDevice) void {
    self.mmio_devices[UART_INDEX] = device;
}

pub fn set_rtc(self: *Self, device: MmioDevice) void {
    self.mmio_devices[RTC_INDEX] = device;
}

pub fn add_device_virtio(self: *Self, device: MmioDevice) void {
    log.assert(
        @src(),
        self.virtio_num_devices < MAX_VIRTIO_DEVICES,
        "Trying to attach more virtio devices to mmio bus than maximum: {d}",
        .{@as(u32, MAX_VIRTIO_DEVICES)},
    );
    self.virtio_devices[self.virtio_num_devices] = device;
    self.virtio_num_devices += 1;
}

pub fn add_device_pci(self: *Self, device: MmioDevice) void {
    log.assert(
        @src(),
        self.pci_num_devices < MAX_VIRTIO_DEVICES,
        "Trying to attach more ci devices to mmio bus than maximum: {d}",
        .{@as(u32, MAX_VIRTIO_DEVICES)},
    );
    self.pci_devices[self.pci_num_devices] = device;
    self.pci_num_devices += 1;
}

pub fn write(self: *Self, addr: u64, data: []u8) void {
    if (addr < Memory.GICV2M_MSI_ADDR + Memory.GICV2M_MSI_LEN) {
        const offset = addr - Memory.GICV2M_MSI_ADDR;
        Gicv2.write(offset, data);
    } else if (Memory.PCI_START <= addr) {
        const index = (addr - Memory.PCI_START) / Memory.PCI_BAR_SIZE;
        const offset = (addr - Memory.PCI_START) - Memory.PCI_BAR_SIZE * index;
        const device = self.pci_devices[index];
        device.write(offset, data);
    } else if (Memory.PCI_CONFIG_START <= addr) {
        const offset = addr - Memory.PCI_CONFIG_START;
        self.ecam.write(offset, data);
    } else if (addr < VIRTIO_ADDRESS_START) {
        const index = (addr - MMIO_MEM_START) / MMIO_DEVICE_ALLOCATED_REGION_SIZE;
        const offset = (addr - MMIO_MEM_START) - MMIO_DEVICE_ALLOCATED_REGION_SIZE * index;
        const device = self.mmio_devices[index];
        device.write(offset, data);
    } else {
        const index = (addr - VIRTIO_ADDRESS_START) / MMIO_DEVICE_ALLOCATED_REGION_SIZE / 2;
        const offset = (addr - VIRTIO_ADDRESS_START) -
            (MMIO_DEVICE_ALLOCATED_REGION_SIZE * index * 2) -
            (MMIO_DEVICE_ALLOCATED_REGION_SIZE - VIRTIO_INTERRUPT_STATUS_OFFSET);
        const device = self.virtio_devices[index];
        device.write(offset, data);
    }
}

pub fn read(self: *Self, addr: u64, data: []u8) void {
    if (addr < Memory.GICV2M_MSI_ADDR + Memory.GICV2M_MSI_LEN) {
        const offset = addr - Memory.GICV2M_MSI_ADDR;
        Gicv2.read(offset, data);
    } else if (Memory.PCI_START <= addr) {
        const index = (addr - Memory.PCI_START) / Memory.PCI_BAR_SIZE;
        const offset = (addr - Memory.PCI_START) - Memory.PCI_BAR_SIZE * index;
        const device = self.pci_devices[index];
        device.read(offset, data);
    } else if (Memory.PCI_CONFIG_START <= addr) {
        const offset = addr - Memory.PCI_CONFIG_START;
        self.ecam.read(offset, data);
    } else if (addr < VIRTIO_ADDRESS_START) {
        const index = (addr - MMIO_MEM_START) / MMIO_DEVICE_ALLOCATED_REGION_SIZE;
        const offset = (addr - MMIO_MEM_START) - MMIO_DEVICE_ALLOCATED_REGION_SIZE * index;
        const device = self.mmio_devices[index];
        device.read(offset, data);
    } else {
        const index = (addr - VIRTIO_ADDRESS_START) / MMIO_DEVICE_ALLOCATED_REGION_SIZE / 2;
        const offset = (addr - VIRTIO_ADDRESS_START) -
            (MMIO_DEVICE_ALLOCATED_REGION_SIZE * index * 2) -
            (MMIO_DEVICE_ALLOCATED_REGION_SIZE - VIRTIO_INTERRUPT_STATUS_OFFSET);
        const device = self.virtio_devices[index];
        device.read(offset, data);
    }
}
