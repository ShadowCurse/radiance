const std = @import("std");
const log = @import("../log.zig");
const pci_context = @import("pci_context.zig");
const Memory = @import("../memory.zig");

const Allocator = std.mem.Allocator;

const NUM_DEVICE_IDS: usize = 32;
const NUM_CONFIGURATION_REGISTERS: usize = 1024;

const VIRTIO_VENDOR_ID = 0x1af4;
const VIRTIO_PCI_DEVICE_BASE_ID = 0x1040;

headers: []Type0ConfigurationHeader,
headers_meta: []HeaderBarSizes,
num_devices: u32,
// Same for all virtio devices
virtio_device_capability: VirtioPciDeviceCapabilities,

pub const PciClass = enum(u8) {
    TooOld,
    MassStorage,
    NetworkController,
    DisplayController,
    MultimediaController,
    MemoryController,
    BridgeDevice,
};

pub const PciBridgeSubclass = enum(u8) {
    HostBridge,
};

pub const PciMassStorageSubclass = enum(u8) {
    ScsiStorage,
    IdeInterface,
    FloppyController,
    IpiController,
    RaidController,
    AtaController,
    SataCnotroller,
    SerialScsiController,
    NvmeController,
    UfcController,
    Other = 0x80,
};

// https://docs.amd.com/r/en-US/pg344-pcie-dma-versal/Enhanced-Configuration-Access-Memory-Map
const ECAMAddress = packed struct(u32) {
    byte_address: u2,
    register_number: u6,
    extended_register_number: u4,
    function_number: u3,
    device_number: u5,
    bus_number: u8,
    _: u4,

    pub fn offset(self: *const ECAMAddress) u32 {
        return @as(u32, @bitCast(self.*)) & ((1 << 13) - 1);
    }
    pub fn register(self: *const ECAMAddress) u32 {
        return @as(u32, self.extended_register_number) << 6 |
            @as(u32, self.register_number);
    }

    pub fn format(value: *const ECAMAddress, writer: anytype) !void {
        try writer.print("{d}:{d}:{d}:{d}:{d}:{d}", .{
            value.byte_address,
            value.register_number,
            value.extended_register_number,
            value.function_number,
            value.device_number,
            value.bus_number,
        });
    }
};

const Bar = packed struct(u32) {
    // 0 - memory bar, 1 - io bar
    type: u1 = 0,
    // 0 - 32 bit, 2 - 64 bit
    memory_type: u2 = 0,
    // 1 if no side effects on reads
    prefetchable: u1 = 0,
    address: u28 = 0,

    fn set_address(self: *Bar, address: u32) void {
        self.address = @truncate(address >> 4);
    }
};

pub const Type0ConfigurationHeader = extern struct {
    reg0: packed struct(u32) {
        vendor_id: u16 = 0,
        device_id: u16 = 0,
    } = .{},
    reg1: packed struct(u32) {
        command: u16 = 0,
        status: packed struct(u16) {
            _unneeded: u4 = 0,
            capabilites_list: u1 = 0,
            _unneeded_2: u11 = 0,
        } = .{},
    } = .{},
    reg2: packed struct(u32) {
        revision_id: u8 = 0,
        class_code: packed struct(u24) {
            _: u8 = 0,
            sub_class_code: u8 = 0,
            base_class_code: u8 = 0,
        } = .{},
    } = .{},
    reg3: packed struct(u32) {
        cache_line_size: u8 = 0,
        primary_latency_timer: u8 = 0,
        header_type: u8 = 0,
        bist: u8 = 0,
    } = .{},
    bar0: Bar = .{},
    bar1: Bar = .{},
    bar2: Bar = .{},
    bar3: Bar = .{},
    bar4: Bar = .{},
    bar5: Bar = .{},
    reg10: packed struct(u32) {
        carbus_cis_pointer: u32 = 0,
    } = .{},
    reg11: packed struct(u32) {
        subsystem_vendor_id: u16 = 0,
        subsystem_id: u16 = 0,
    } = .{},
    reg12: packed struct(u32) {
        expansion_rom_base_address: u32 = 0,
    } = .{},
    reg13: packed struct(u32) {
        // Last 2 bits must be 0 and they will be ignored
        // by software
        capabilities_pointer: u8 = 0,
        _reserved: u24 = 0,
    } = .{},
    reg14: packed struct(u32) {
        _reserved_2: u32 = 0,
    } = .{},
    reg15: packed struct(u32) {
        interrupt_line: u8 = 0,
        interrupt_pin: u8 = 0,
        min_gnt: u8 = 0,
        max_lat: u8 = 0,
    } = .{},
};

const PciCapabilityId = enum(u8) {
    Msi = 0x05,
    VendorSpecific = 0x09,
    PCIe = 0x10,
    MsiX = 0x11,
};
const MsixCapability = extern struct {
    header: packed struct(u32) {
        capability_id: PciCapabilityId = .MsiX,
        next_capability_pointer: u8,
        table_size: u11 = 1,
        _: u3 = 0,
        function_mask: u1 = 0,
        msi_x_enable: u1 = 1,
    },
    table_offset: packed struct(u32) {
        bir: u3 = 0,
        offset: u29 = VIRTIO_PCI_MSIX_TABLE_BAR_OFFSET >> 3,
    } = .{},
    pba_offset: packed struct(u32) {
        bir: u3 = 0,
        offset: u29 = VIRTIO_PCI_MSIX_PBA_BAR_OFFSET >> 3,
    } = .{},
};

const VirtioPciConfigType = enum(u8) {
    Common = 1,
    Notify = 2,
    Isr = 3,
    Device = 4,
    Pci = 5,
    Shared_memory = 8,
    Vendor = 9,
};
const VirtioPciCapability = extern struct {
    header: packed struct(u32) {
        capability_id: PciCapabilityId = .VendorSpecific,
        next_capability_pointer: u8,
        length: u8 = @sizeOf(VirtioPciCapability),
        cfg_type: VirtioPciConfigType,
    },
    bar: u8 = 0,
    id: u8 = 0,
    _: u16 = 0,
    offset: u32 = 0,
    length: u32 = 0,
};

const CAPABILITY_OFFSET = 64;
pub const VIRTIO_PCI_CONFIG_BAR_OFFSET = 0;
pub const VIRTIO_PCI_NOTIFY_BAR_OFFSET = 0x1000;
pub const VIRTIO_PCI_NOTIFY_BAR_SIZE = 0x1000;
pub const VIRTIO_PCI_NOTIFY_MULTIPLIER = 4;
pub const VIRTIO_PCI_ISR_BAR_OFFSET = 0x2000;
pub const VIRTIO_PCI_ISR_BAR_SIZE = 1;
pub const VIRTIO_PCI_DEV_CONFIG_BAR_OFFSET = 0x3000;
pub const VIRTIO_PCI_DEV_CONFIG_BAR_SIZE = 0x1000;
pub const VIRTIO_PCI_MSIX_TABLE_BAR_OFFSET = 0x8000;
pub const VIRTIO_PCI_MSIX_PBA_BAR_OFFSET = 0x48000;
const VirtioPciDeviceCapabilities = extern struct {
    msix: MsixCapability = .{
        .header = .{
            .next_capability_pointer = CAPABILITY_OFFSET +
                @offsetOf(VirtioPciDeviceCapabilities, "virtio_pci_common"),
        },
    },
    virtio_pci_common: VirtioPciCapability = .{
        .header = .{
            .cfg_type = .Common,
            .next_capability_pointer = CAPABILITY_OFFSET +
                @offsetOf(VirtioPciDeviceCapabilities, "virtio_pci_notify"),
        },
        .offset = VIRTIO_PCI_CONFIG_BAR_OFFSET,
        .length = @sizeOf(pci_context.virtio_pci_common_cfg),
    },

    virtio_pci_notify: VirtioPciCapability = .{
        .header = .{
            .cfg_type = .Notify,
            .next_capability_pointer = CAPABILITY_OFFSET +
                @offsetOf(VirtioPciDeviceCapabilities, "virtio_pci_isr"),
        },
        .offset = VIRTIO_PCI_NOTIFY_BAR_OFFSET,
        .length = VIRTIO_PCI_NOTIFY_BAR_SIZE,
    },
    notify_off_multiplier: u32 = VIRTIO_PCI_NOTIFY_MULTIPLIER,

    virtio_pci_isr: VirtioPciCapability = .{
        .header = .{
            .cfg_type = .Isr,
            .next_capability_pointer = CAPABILITY_OFFSET +
                @offsetOf(VirtioPciDeviceCapabilities, "virtio_pci_device_cfg"),
        },
        .offset = VIRTIO_PCI_ISR_BAR_OFFSET,
        .length = VIRTIO_PCI_ISR_BAR_SIZE,
    },
    virtio_pci_device_cfg: VirtioPciCapability = .{
        .header = .{
            .cfg_type = .Device,
            .next_capability_pointer = CAPABILITY_OFFSET +
                @offsetOf(VirtioPciDeviceCapabilities, "virtio_pci_config"),
        },
        .offset = VIRTIO_PCI_DEV_CONFIG_BAR_OFFSET,
        .length = VIRTIO_PCI_DEV_CONFIG_BAR_SIZE,
    },
    virtio_pci_config: VirtioPciCapability = .{
        .header = .{
            .cfg_type = .Pci,
            .next_capability_pointer = 0,
        },
    },
    data: u32 = 0,
};

pub const HeaderBarSizes = struct {
    sizes: [6]Size = .{Size{}} ** 6,

    pub const Size = packed struct(u32) {
        read: bool = false,
        size: u31 = 0,
    };
};

const Self = @This();

pub fn init(memory: []align(8) u8, pci_devices: u32) !*Self {
    var mem: []align(8) u8 = memory;

    var self: *Self = @ptrCast(mem[0..@sizeOf(Self)]);
    mem = mem[@sizeOf(Self)..];

    const headers_bytes = @sizeOf(Type0ConfigurationHeader) * pci_devices;
    const headers: []Type0ConfigurationHeader = @ptrCast(mem[0..headers_bytes]);
    mem = @alignCast(mem[headers_bytes..]);
    for (headers) |*h| h.* = .{};

    const headers_meta_bytes = @sizeOf(HeaderBarSizes) * pci_devices;
    const headers_meta: []HeaderBarSizes = @ptrCast(mem[0..headers_meta_bytes]);
    for (headers_meta) |*h| h.* = .{};

    self.headers = headers;
    self.headers_meta = headers_meta;
    self.num_devices = 0;
    self.virtio_device_capability = .{};
    return self;
}

pub fn add_header(
    self: *Self,
    device_type: u16,
    sub_class_code: u8,
    base_class_code: u8,
    bar_addr: u64,
) void {
    log.debug(
        @src(),
        "Adding device to the ECAM region: device number: {d} device type: {d} sub class: {d} base class: {d} bar addr: 0x{x} bar len: {d}",
        .{
            self.num_devices,
            device_type,
            sub_class_code,
            base_class_code,
            bar_addr,
            @as(u32, Memory.PCI_BAR_SIZE),
        },
    );
    self.headers[self.num_devices] =
        .{
            .reg0 = .{
                .vendor_id = VIRTIO_VENDOR_ID,
                .device_id = VIRTIO_PCI_DEVICE_BASE_ID + device_type,
            },
            .reg1 = .{
                .status = .{
                    // For PCIe must be 1
                    .capabilites_list = 1,
                },
            },
            .reg2 = .{
                .revision_id = 1,
                .class_code = .{
                    .sub_class_code = sub_class_code,
                    .base_class_code = base_class_code,
                },
            },
            .reg11 = .{
                .subsystem_vendor_id = VIRTIO_VENDOR_ID,
                .subsystem_id = VIRTIO_PCI_DEVICE_BASE_ID + device_type,
            },
            .bar0 = blk: {
                var bar: Bar = .{ .memory_type = 2, .prefetchable = 1 };
                bar.set_address(@truncate(bar_addr));
                break :blk bar;
            },
            .bar1 = blk: {
                var bar: Bar = .{};
                bar.set_address(@truncate(bar_addr >> 32));
                break :blk bar;
            },
            .reg13 = .{
                .capabilities_pointer = @sizeOf(Type0ConfigurationHeader),
            },
        };
    self.headers_meta[self.num_devices] =
        .{
            .sizes = .{HeaderBarSizes.Size{ .size = Memory.PCI_BAR_SIZE }} ++ .{} ** 5,
        };
    self.num_devices += 1;
}

// https://elixir.bootlin.com/linux/v6.15.3/source/drivers/pci/probe.c#L1974
pub fn write(self: *Self, offset: u64, data: []u8) void {
    const ecam: ECAMAddress = @bitCast(@as(u32, @truncate(offset)));

    log.assert(
        @src(),
        ecam.device_number < self.headers.len,
        "Write to the config space of the non existing device. Offset: 0x{x}, ECAM: {f}",
        .{ offset, ecam },
    );

    const config_offset = ecam.offset();
    log.assert(
        @src(),
        config_offset < @sizeOf(Type0ConfigurationHeader) +
            @sizeOf(VirtioPciDeviceCapabilities),
        "Write beyond available memory in config space. Offset: 0x{x}, ECAM: {f}",
        .{ offset, ecam },
    );

    const header = &self.headers[ecam.device_number];
    if (config_offset < @sizeOf(Type0ConfigurationHeader)) {
        if (@offsetOf(Type0ConfigurationHeader, "bar0") <= config_offset and
            config_offset <= @offsetOf(Type0ConfigurationHeader, "bar5"))
        {
            const bar_idx = ecam.register() - 4;
            log.assert(
                @src(),
                data.len == 4,
                "Write to the bar{d} is not 4 bytes: {any}",
                .{ bar_idx, data },
            );
            const data_u32: *u32 = @ptrCast(@alignCast(data.ptr));
            if (data_u32.* == 0xffff_ffff)
                self.headers_meta[ecam.device_number].sizes[bar_idx].read = true;
        } else {
            const bytes: []u8 = @ptrCast(header);
            @memcpy(bytes[config_offset..][0..data.len], data);
        }
    } else {
        const capability_offset = config_offset - @sizeOf(Type0ConfigurationHeader);
        const bytes: []u8 = @ptrCast(&self.virtio_device_capability);
        @memcpy(bytes[capability_offset..][0..data.len], data);
    }

    log.debug(
        @src(),
        "ECAM W: offset: 0x{x} len: {d} ecam: {f} data: {any}",
        .{
            offset,
            data.len,
            ecam,
            data,
        },
    );
}

pub fn read(self: *Self, offset: u64, data: []u8) void {
    const ecam: ECAMAddress = @bitCast(@as(u32, @truncate(offset)));

    if (self.headers.len <= ecam.device_number) {
        @memset(data, 0xff);
        return;
    }

    const config_offset = ecam.offset();
    // PCI spec 7.6.1 Extended Capabilities begin at offset 0x100. Absence of
    // extended capabilities indicated by 0x0.
    if (config_offset == 0x100) {
        @memset(data, 0x0);
        return;
    }

    log.assert(
        @src(),
        config_offset < @sizeOf(Type0ConfigurationHeader) +
            @sizeOf(VirtioPciDeviceCapabilities),
        "Read beyond available memory in config space. Offset: 0x{x}, ECAM: {f}",
        .{ offset, ecam },
    );

    const header = &self.headers[ecam.device_number];
    if (config_offset < @sizeOf(Type0ConfigurationHeader)) blk: {
        if (@offsetOf(Type0ConfigurationHeader, "bar0") <= config_offset and
            config_offset <= @offsetOf(Type0ConfigurationHeader, "bar5"))
        {
            const bar_idx = ecam.register() - 4;
            log.assert(
                @src(),
                data.len == 4,
                "Read to the bar{d} is not 4 bytes: {any}",
                .{ bar_idx, data },
            );
            const data_u32: *u32 = @ptrCast(@alignCast(data.ptr));
            const header_meta = &self.headers_meta[ecam.device_number];
            if (header_meta.sizes[bar_idx].read) {
                data_u32.* = header_meta.sizes[bar_idx].size;
                header_meta.sizes[bar_idx].read = false;
                break :blk;
            }
        }
        // ROM is never present, so always return 0
        if (config_offset == @offsetOf(Type0ConfigurationHeader, "reg12"))
            @memset(data, 0)
        else {
            const bytes: []const u8 = @ptrCast(header);
            @memcpy(data, bytes[config_offset..][0..data.len]);
        }
    } else {
        const capability_offset = config_offset - @sizeOf(Type0ConfigurationHeader);
        const bytes: []const u8 = @ptrCast(&self.virtio_device_capability);
        @memcpy(data, bytes[capability_offset..][0..data.len]);
    }

    log.debug(
        @src(),
        "ECAM R: offset: 0x{x} len: {d} ecam: {f} data: {any}",
        .{
            offset,
            data.len,
            ecam,
            data,
        },
    );
}
