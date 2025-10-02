const std = @import("std");
const Allocator = std.mem.Allocator;

const log = @import("log.zig");

const _cache = @import("cache.zig");
const read_host_caches = _cache.read_host_caches;
const Gicv2 = @import("gicv2.zig");
const MmioDeviceInfo = @import("mmio.zig").MmioDeviceInfo;
const Memory = @import("memory.zig");
const Pmem = @import("devices/pmem.zig");

const FdtData = struct {
    mem: []u8,
    len: u64,

    const Self = @This();

    pub fn init(memory: *const Memory) Self {
        const fdt_addr = FdtBuilder.fdt_addr(memory.last_addr());
        const memory_fdt_start = fdt_addr - Memory.DRAM_START;
        return .{
            .mem = memory.mem[memory_fdt_start..],
            .len = 0,
        };
    }

    pub fn align_self(self: *Self, alignment: u64) void {
        const offset = self.len % alignment;
        if (offset != 0) {
            self.len += alignment - offset;
        }
    }

    pub fn write_fdt_reserve_entry(self: *Self, entries: []FdtReserveEntry) void {
        for (entries) |entry| {
            self.append(u64, entry.address);
            self.append(u64, entry.size);
        }
        // The list of reserved blocks shall be terminated with an entry
        // where both address and size are equal to 0
        self.append(u64, @as(u64, 0));
        self.append(u64, @as(u64, 0));
    }

    pub fn append(self: *Self, comptime t: type, item: t) void {
        switch (t) {
            void => {},
            u32, u64 => {
                const b = @byteSwap(item);
                const bytes: []const u8 = @ptrCast(&b);
                @memcpy(self.mem[self.len .. self.len + bytes.len], bytes);
                self.len += bytes.len;
            },
            []const u32, []const u64 => {
                for (item) |i| {
                    const b = @byteSwap(i);
                    const bytes: []const u8 = @ptrCast(&b);
                    @memcpy(self.mem[self.len .. self.len + bytes.len], bytes);
                    self.len += bytes.len;
                }
            },
            []const u8 => {
                @memcpy(self.mem[self.len .. self.len + item.len], item);
                self.len += item.len;
            },
            [:0]const u8 => {
                @memcpy(self.mem[self.len .. self.len + item.len], item);
                self.len += item.len;
                self.mem[self.len] = 0;
                self.len += 1;
            },
            else => log.assert(@src(), false, "Trying to append unknown type: {any}", .{t}),
        }
    }
};

pub const FdtHeader = extern struct {
    magic: u32 = 0,
    totalsize: u32 = 0,
    off_dt_struct: u32 = 0,
    off_dt_strings: u32 = 0,
    off_mem_rsvmap: u32 = 0,
    version: u32 = 0,
    last_comp_version: u32 = 0,
    boot_cpuid_phys: u32 = 0,
    size_dt_strings: u32 = 0,
    size_dt_struct: u32 = 0,
};

pub const FdtReserveEntry = packed struct {
    address: u64,
    size: u64,
};

// Builder for DeviceTree directly in the VM memory.
// https://devicetree-specification.readthedocs.io/en/stable/flattened-format.html
pub const FdtBuilder = struct {
    data: FdtData,
    allocator: Allocator,
    strings_map: std.StringHashMapUnmanaged(usize),
    stored_strings: std.ArrayListUnmanaged(u8),

    /// Maximum size of the device tree blob as specified in
    /// https://www.kernel.org/doc/Documentation/arm64/booting.txt.
    const FDT_MAX_SIZE: usize = 0x20_0000;
    const FDT_VERSION: u32 = 17;
    const FDT_LAST_COMP_VERSION: u32 = 16;
    const FDT_MAGIC: u32 = 0xd00dfeed;
    const FDT_BEGIN_NODE: u32 = 0x00000001;
    const FDT_END_NODE: u32 = 0x00000002;
    const FDT_PROP: u32 = 0x00000003;
    const FDT_NOP: u32 = 0x00000004;
    const FDT_END: u32 = 0x00000009;

    const GIC_PHANDLE: u32 = 1;
    const MSI_PHANDLE: u32 = 2;
    const CLOCK_PHANDLE: u32 = 3;
    // https://github.com/torvalds/linux/blob/master/Documentation/devicetree/bindings/interrupt-controller/arm%2Cgic.yaml
    const GIC_FDT_IRQ_TYPE_SPI: u32 = 0;
    const GIC_FDT_IRQ_TYPE_PPI: u32 = 1;

    // https://github.com/torvalds/linux/blob/master/include/dt-bindings/interrupt-controller/irq.h
    const IRQ_TYPE_EDGE_RISING: u32 = 1;
    const IRQ_TYPE_LEVEL_HI: u32 = 4;

    const Self = @This();

    pub fn new(allocator: Allocator, memory: *const Memory) Self {
        var data = FdtData.init(memory);

        // Allocation 40 bytes. This is a size of FdtHeader struct.
        const header: FdtHeader = .{};
        data.append([]const u8, @ptrCast(&header));

        // The memory reservation block shall be aligned to an 8-byte boundary
        data.align_self(8);

        const off_mem_rsvmap: u32 = @intCast(data.len);

        data.write_fdt_reserve_entry(&.{});

        // The structure block to a 4-byte boundary
        data.align_self(4);
        const off_dt_struct: u32 = @intCast(data.len);

        const header_ptr: *FdtHeader = @ptrCast(@alignCast(data.mem.ptr));
        // All values in the FDT should be in big endian format.
        header_ptr.off_dt_struct = @byteSwap(off_dt_struct);
        header_ptr.off_mem_rsvmap = @byteSwap(off_mem_rsvmap);

        return Self{
            .data = data,
            .allocator = allocator,
            .strings_map = .empty,
            .stored_strings = .empty,
        };
    }

    pub fn fdt_addr(last_addr: u64) u64 {
        return last_addr - Self.FDT_MAX_SIZE + 1;
    }

    pub fn begin_node(self: *Self, name: [:0]const u8) void {
        log.debug(@src(), "FDT: start node: {s}", .{name});

        self.data.append(u32, FDT_BEGIN_NODE);
        self.data.append([:0]const u8, name);
        self.data.align_self(4);
    }

    pub fn end_node(self: *Self) void {
        log.debug(@src(), "FDT: end node", .{});
        self.data.append(u32, FDT_END_NODE);
    }

    /// Expects integer types to be in big endian format. (use @byteSwap(..) before passing integers)
    pub fn add_property(self: *Self, comptime t: type, name: [:0]const u8, item: t) void {
        if (t == [:0]const u8)
            log.debug(@src(), "FDT: add property: name: {s}, item: {s}", .{ name, item })
        else
            log.debug(@src(), "FDT: add property: name: {s}, item: {any}", .{ name, item });

        const name_offset = self.string_offset(name);
        self.data.append(u32, FDT_PROP);
        const bytes: usize = switch (t) {
            void => 0,
            u32, u64 => @sizeOf(t),
            [:0]const u8 => @sizeOf(u8) * item.len + 1,
            []const u32 => @sizeOf(u32) * item.len,
            []const u64 => @sizeOf(u64) * item.len,
            else => log.assert(
                @src(),
                false,
                "Trying to convert unknown type to bytes: {any}",
                .{t},
            ),
        };
        const len: u32 = @intCast(bytes);
        self.data.append(u32, len);
        const offset: u32 = @intCast(name_offset);
        self.data.append(u32, offset);
        self.data.append(t, item);
        // All tokens shall be aligned on a 32-bit boundary,
        // which may require padding bytes (with 0)
        // to be inserted after the previous token’s data
        self.data.align_self(4);
    }

    fn string_offset(self: *Self, s: [:0]const u8) usize {
        if (self.strings_map.get(s)) |offset| {
            return offset;
        } else {
            const new_offset = self.stored_strings.items.len;
            self.stored_strings.appendSlice(self.allocator, s) catch unreachable;
            self.stored_strings.append(self.allocator, 0) catch unreachable;
            self.strings_map.put(self.allocator, s, new_offset) catch unreachable;
            return new_offset;
        }
    }

    pub fn finish(self: *Self) void {
        self.data.append(u32, FDT_END);

        const header_ptr: *FdtHeader = @ptrCast(@alignCast(self.data.mem.ptr));
        // All values in the FDT should be in big endian format.
        header_ptr.magic = @byteSwap(FDT_MAGIC);
        header_ptr.totalsize = @byteSwap(
            @as(u32, @intCast(self.data.len + self.stored_strings.items.len)),
        );
        // Already set.
        // header_ptr.off_dt_struct: u32,
        header_ptr.off_dt_strings = @byteSwap(@as(u32, @intCast(self.data.len)));
        // Already set.
        // header_ptr.off_mem_rsvmap: u32,
        header_ptr.version = @byteSwap(FDT_VERSION);
        header_ptr.last_comp_version = @byteSwap(FDT_LAST_COMP_VERSION);
        header_ptr.boot_cpuid_phys = 0;
        header_ptr.size_dt_strings = @byteSwap(@as(u32, @intCast(self.stored_strings.items.len)));
        header_ptr.size_dt_struct = @byteSwap(
            @as(u32, @intCast(self.data.len)) - @byteSwap(header_ptr.off_dt_struct),
        );

        self.data.append([]const u8, self.stored_strings.items);
    }
};

pub fn create_fdt(
    comptime System: type,
    allocator: Allocator,
    memory: *const Memory,
    mpidrs: []const u64,
    cmdline: [:0]const u8,
    uart_device_info: ?MmioDeviceInfo,
    rtc_device_info: MmioDeviceInfo,
    virtio_devices_info: []const MmioDeviceInfo,
    pmem_info: []const Pmem.Info,
) u64 {
    // https://mjmwired.net/kernel/Documentation/devicetree/booting-without-of.txt
    const ADDRESS_CELLS: u32 = 0x2;
    const SIZE_CELLS: u32 = 0x2;

    var fdt_builder = FdtBuilder.new(allocator, memory);

    // use &.{0} to make an empty string with 0 at the end
    fdt_builder.begin_node(&.{0});

    fdt_builder.add_property([:0]const u8, "compatible", "linux,dummy-virt");
    fdt_builder.add_property(u32, "#address-cells", ADDRESS_CELLS);
    fdt_builder.add_property(u32, "#size-cells", SIZE_CELLS);
    fdt_builder.add_property(u32, "interrupt-parent", FdtBuilder.GIC_PHANDLE);

    create_cpu_fdt(System, &fdt_builder, mpidrs);
    create_memory_fdt(&fdt_builder, memory);
    create_cmdline_fdt(&fdt_builder, cmdline);
    create_gic_fdt(&fdt_builder);
    create_timer_node(&fdt_builder);
    create_clock_node(&fdt_builder);
    create_psci_node(&fdt_builder);
    create_ecam_node(&fdt_builder);

    if (uart_device_info) |info|
        create_uart_node(&fdt_builder, info);
    create_rtc_node(&fdt_builder, rtc_device_info);

    for (virtio_devices_info) |*info| {
        create_virtio_node(&fdt_builder, info);
    }

    for (pmem_info) |info| {
        create_pmem_node(&fdt_builder, info);
    }

    fdt_builder.end_node();
    fdt_builder.finish();

    return FdtBuilder.fdt_addr(memory.last_addr());
}

fn create_ecam_node(builder: *FdtBuilder) void {
    // https://github.com/devicetree-org/dt-schema/tree/main/dtschema/schemas/pci
    // https://elinux.org/Device_Tree_Usage#PCI_Address_Translation
    // https://github.com/devicetree-org/dt-schema/blob/main/dtschema/schemas/pci/pci-host-bridge.yaml

    var print_buff: [20]u8 = undefined;
    const name = std.fmt.bufPrintZ(
        &print_buff,
        "pcie@{x}",
        .{Memory.PCI_CONFIG_START},
    ) catch unreachable;

    builder.begin_node(name);
    defer builder.end_node();

    builder.add_property([:0]const u8, "compatible", "pci-host-ecam-generic");
    builder.add_property([:0]const u8, "device_type", "pci");
    builder.add_property(u32, "#address-cells", 3);
    builder.add_property(u32, "#size-cells", 2);
    builder.add_property(u32, "#interrupt-cells", 1);
    builder.add_property(u32, "linux,pci-domain", 0);
    builder.add_property([]const u64, "reg", &.{
        Memory.PCI_CONFIG_START,
        Memory.PCI_ECAM_REGION_SIZE,
    });
    builder.add_property([]const u32, "bus-range", &.{ 0, 0 });
    builder.add_property([]const u32, "ranges", &.{
        // 64bit addresses olny
        0x300_0000,
        Memory.PCI_START >> 32, // PCI address
        Memory.PCI_START & 0xffff_ffff,
        Memory.PCI_START >> 32, // CPU address
        Memory.PCI_START & 0xffff_ffff,
        Memory.PCI_SIZE >> 32, // Range size
        Memory.PCI_SIZE & 0xffff_ffff,
    });
    builder.add_property(void, "dma-coherent", {});
    builder.add_property([]const u32, "msi-map", &.{ 0, FdtBuilder.MSI_PHANDLE, 0, 0x10000 });
    builder.add_property(u32, "msi-parent", FdtBuilder.MSI_PHANDLE);
    builder.add_property(void, "interrupt-map", {});
    builder.add_property(void, "interrupt-map-mask", {});
}

fn create_cpu_fdt(comptime System: type, builder: *FdtBuilder, mpidrs: []const u64) void {
    // https://github.com/torvalds/linux/blob/master/Documentation/devicetree/bindings/arm/cpus.yaml
    // In order to not overlap with other phandles start from a big offset.
    const LAST_CACHE_PHANDLE: u32 = 4000;

    const caches = read_host_caches(System);

    builder.begin_node("cpus");
    defer builder.end_node();

    builder.add_property(u32, "#address-cells", 0x02);
    builder.add_property(u32, "#size-cells", 0x0);

    var print_buff: [20]u8 = undefined;
    for (mpidrs, 0..) |mpidr, i| {
        const cpu_name = std.fmt.bufPrintZ(&print_buff, "cpu@{x}", .{i}) catch unreachable;
        builder.begin_node(cpu_name);
        defer builder.end_node();

        builder.add_property([:0]const u8, "device_type", "cpu");
        builder.add_property([:0]const u8, "compatible", "arm,arm-v8");
        builder.add_property([:0]const u8, "enable-method", "psci");
        builder.add_property(u64, "reg", mpidr & 0x7FFFFF);

        if (caches.l1d_cache) |l1d| {
            const cache_size: u32 = @intCast(l1d.size);
            builder.add_property(u32, l1d.cache_type.cache_size_str(), cache_size);

            const line_size: u32 = @intCast(l1d.line_size);
            builder.add_property(u32, l1d.cache_type.cache_line_size_str(), line_size);

            const number_of_sets: u32 = @intCast(l1d.number_of_sets);
            builder.add_property(u32, l1d.cache_type.cache_sets_str(), number_of_sets);
        }
        if (caches.l1i_cache) |l1i| {
            const cache_size: u32 = @intCast(l1i.size);
            builder.add_property(u32, l1i.cache_type.cache_size_str(), cache_size);

            const line_size: u32 = @intCast(l1i.line_size);
            builder.add_property(u32, l1i.cache_type.cache_line_size_str(), line_size);

            const number_of_sets: u32 = @intCast(l1i.number_of_sets);
            builder.add_property(u32, l1i.cache_type.cache_sets_str(), number_of_sets);
        }

        if (caches.l2_cache) |_| {
            const l2_cache_phandle: u32 = LAST_CACHE_PHANDLE - @as(u32, @intCast(i));
            builder.add_property(u32, "next-level-cache", l2_cache_phandle);
        }
    }

    if (caches.l2_cache) |l2| {
        for (0..mpidrs.len) |i| {
            const l2_cache_phandle: u32 = LAST_CACHE_PHANDLE - @as(u32, @intCast(i));

            const node_name = std.fmt.bufPrintZ(&print_buff, "l2-cache-{}", .{i}) catch unreachable;
            builder.begin_node(node_name);
            defer builder.end_node();

            builder.add_property(u32, "phandle", l2_cache_phandle);
            builder.add_property([:0]const u8, "compatible", "cache");
            builder.add_property(u32, "cache-level", l2.level);
            const cache_size: u32 = @intCast(l2.size);
            builder.add_property(u32, l2.cache_type.cache_size_str(), cache_size);
            const line_size: u32 = @intCast(l2.line_size);
            builder.add_property(u32, l2.cache_type.cache_line_size_str(), line_size);
            const number_of_sets: u32 = @intCast(l2.number_of_sets);
            builder.add_property(u32, l2.cache_type.cache_sets_str(), number_of_sets);
            if (l2.cache_type.cache_type_str()) |s| {
                builder.add_property(void, s, {});
            }
            if (caches.l3_cache) |_| {
                const l3_cache_phandle: u32 = LAST_CACHE_PHANDLE - @as(u32, @intCast(mpidrs.len));
                builder.add_property(u32, "next-level-cache", l3_cache_phandle);
            }
        }

        if (caches.l3_cache) |l3| {
            const l3_cache_phandle: u32 = LAST_CACHE_PHANDLE - @as(u32, @intCast(mpidrs.len));

            builder.begin_node("l3-cache");
            defer builder.end_node();

            builder.add_property(u32, "phandle", l3_cache_phandle);
            builder.add_property([:0]const u8, "compatible", "cache");
            builder.add_property(u32, "cache-level", l3.level);
            const cache_size: u32 = @intCast(l3.size);
            builder.add_property(u32, l3.cache_type.cache_size_str(), cache_size);
            const line_size: u32 = @intCast(l3.line_size);
            builder.add_property(u32, l3.cache_type.cache_line_size_str(), line_size);
            const number_of_sets: u32 = @intCast(l3.number_of_sets);
            builder.add_property(u32, l3.cache_type.cache_sets_str(), number_of_sets);
            if (l3.cache_type.cache_type_str()) |s| {
                builder.add_property(void, s, {});
            }
        }
    }
}

fn create_memory_fdt(builder: *FdtBuilder, memory: *const Memory) void {
    // https://github.com/torvalds/linux/blob/master/Documentation/devicetree/usage-model.rst
    const mem_reg_prop = [_]u64{ Memory.DRAM_START, memory.mem.len };

    builder.begin_node("memory");
    defer builder.end_node();

    builder.add_property([:0]const u8, "device_type", "memory");
    builder.add_property([]const u64, "reg", &mem_reg_prop);
}

fn create_cmdline_fdt(builder: *FdtBuilder, cmdline: [:0]const u8) void {
    builder.begin_node("chosen");
    builder.add_property([:0]const u8, "bootargs", cmdline);
    builder.end_node();
}

fn create_gic_fdt(builder: *FdtBuilder) void {
    // https://github.com/torvalds/linux/blob/master/Documentation/devicetree/bindings/interrupt-controller/arm%2Cgic.yaml
    builder.begin_node("intc");
    defer builder.end_node();

    builder.add_property([:0]const u8, "compatible", "arm,gic-400");
    builder.add_property(void, "interrupt-controller", {});
    builder.add_property(u32, "#interrupt-cells", 3);
    builder.add_property([]const u64, "reg", &Gicv2.DEVICE_PROPERTIES);
    builder.add_property(u32, "phandle", FdtBuilder.GIC_PHANDLE);
    builder.add_property(u32, "#address-cells", 2);
    builder.add_property(u32, "#size-cells", 2);
    builder.add_property(void, "ranges", {});

    // https://github.com/torvalds/linux/blob/master/Documentation/devicetree/bindings/interrupt-controller/arm%2Cgic.yaml
    // use number 8 as in the example
    const gic_intr = [_]u32{
        FdtBuilder.GIC_FDT_IRQ_TYPE_PPI,
        8,
        FdtBuilder.IRQ_TYPE_LEVEL_HI,
    };

    // https://github.com/devicetree-org/dt-schema/tree/main/dtschema/schemas/pci
    builder.add_property([]const u32, "interrupts", &gic_intr);
    {
        var print_buff: [20]u8 = undefined;
        const name = std.fmt.bufPrintZ(
            &print_buff,
            "v2m@{x}",
            .{Memory.GICV2M_MSI_ADDR},
        ) catch unreachable;

        builder.begin_node(name);
        defer builder.end_node();

        builder.add_property([:0]const u8, "compatible", "arm,gic-v2m-frame");
        builder.add_property(void, "msi-controller", {});
        builder.add_property(
            []const u64,
            "reg",
            &.{ Memory.GICV2M_MSI_ADDR, Memory.GICV2M_MSI_LEN },
        );
        builder.add_property(u32, "phandle", FdtBuilder.MSI_PHANDLE);
    }
}

fn create_clock_node(builder: *FdtBuilder) void {
    // https://github.com/torvalds/linux/blob/master/Documentation/devicetree/bindings/clock/fixed-clock.yaml
    builder.begin_node("apb-pclk");
    defer builder.end_node();
    builder.add_property([:0]const u8, "compatible", "fixed-clock");
    builder.add_property(u32, "#clock-cells", 0x0);
    builder.add_property(u32, "clock-frequency", 24_000_000);
    builder.add_property([:0]const u8, "clock-output-names", "clk24mhz");
    builder.add_property(u32, "phandle", FdtBuilder.CLOCK_PHANDLE);
}

fn create_timer_node(builder: *FdtBuilder) void {
    // https://github.com/torvalds/linux/blob/master/Documentation/devicetree/bindings/timer/arm%2Carch_timer.yaml
    // Use 13, 14, 11, 10 interrupts as in the example
    const interrupts: [12]u32 = .{
        FdtBuilder.GIC_FDT_IRQ_TYPE_PPI,
        13,
        FdtBuilder.IRQ_TYPE_LEVEL_HI,
        FdtBuilder.GIC_FDT_IRQ_TYPE_PPI,
        14,
        FdtBuilder.IRQ_TYPE_LEVEL_HI,
        FdtBuilder.GIC_FDT_IRQ_TYPE_PPI,
        11,
        FdtBuilder.IRQ_TYPE_LEVEL_HI,
        FdtBuilder.GIC_FDT_IRQ_TYPE_PPI,
        10,
        FdtBuilder.IRQ_TYPE_LEVEL_HI,
    };
    builder.begin_node("timer");
    defer builder.end_node();

    builder.add_property([:0]const u8, "compatible", "arm,armv8-timer");
    builder.add_property(void, "always-on", {});
    builder.add_property([]const u32, "interrupts", &interrupts);
}

fn create_psci_node(builder: *FdtBuilder) void {
    // https://github.com/torvalds/linux/blob/master/Documentation/devicetree/bindings/arm/psci.yaml
    builder.begin_node("psci");
    defer builder.end_node();

    builder.add_property([:0]const u8, "compatible", "arm,psci-0.2");
    builder.add_property([:0]const u8, "method", "hvc");
}

fn create_uart_node(builder: *FdtBuilder, device_info: MmioDeviceInfo) void {
    // https://github.com/torvalds/linux/blob/master/Documentation/devicetree/bindings/serial/8250.yaml
    var buff: [20]u8 = undefined;
    const name = std.fmt.bufPrintZ(&buff, "uart@{x:.8}", .{device_info.addr}) catch unreachable;
    builder.begin_node(name);
    defer builder.end_node();

    builder.add_property([:0]const u8, "compatible", "ns16550a");
    builder.add_property([]const u64, "reg", &.{ device_info.addr, device_info.len });
    builder.add_property(u32, "clocks", FdtBuilder.CLOCK_PHANDLE);
    builder.add_property([:0]const u8, "clock-names", "apb_pclk");
    builder.add_property(
        []const u32,
        "interrupts",
        &.{ FdtBuilder.GIC_FDT_IRQ_TYPE_SPI, device_info.irq, FdtBuilder.IRQ_TYPE_EDGE_RISING },
    );
}

fn create_rtc_node(builder: *FdtBuilder, device_info: MmioDeviceInfo) void {
    // https://github.com/torvalds/linux/blob/master/Documentation/devicetree/bindings/rtc/arm%2Cpl031.yaml
    var buff: [20]u8 = undefined;
    const name = std.fmt.bufPrintZ(&buff, "rtc@{x:.8}", .{device_info.addr}) catch unreachable;
    builder.begin_node(name);
    defer builder.end_node();

    builder.add_property([:0]const u8, "compatible", "arm,pl031\u{0}arm,primecell");
    builder.add_property([]const u64, "reg", &.{ device_info.addr, device_info.len });
    builder.add_property(u32, "clocks", FdtBuilder.CLOCK_PHANDLE);
    builder.add_property([:0]const u8, "clock-names", "apb_pclk");
}

fn create_virtio_node(
    builder: *FdtBuilder,
    device_info: *const MmioDeviceInfo,
) void {
    // https://github.com/torvalds/linux/blob/master/Documentation/devicetree/bindings/virtio/mmio.yaml
    var buff: [30]u8 = undefined;
    const name = std.fmt.bufPrintZ(&buff, "virtio_mmio@{x:.8}", .{device_info.addr}) catch unreachable;
    builder.begin_node(name);
    defer builder.end_node();

    builder.add_property([:0]const u8, "compatible", "virtio,mmio");
    builder.add_property([]const u64, "reg", &.{ device_info.addr, device_info.len });
    builder.add_property(
        []const u32,
        "interrupts",
        &.{ FdtBuilder.GIC_FDT_IRQ_TYPE_SPI, device_info.irq, FdtBuilder.IRQ_TYPE_EDGE_RISING },
    );
    builder.add_property(u32, "interrupt-parent", FdtBuilder.GIC_PHANDLE);
}

fn create_pmem_node(builder: *FdtBuilder, info: Pmem.Info) void {
    var buff: [20]u8 = undefined;
    const name = std.fmt.bufPrintZ(&buff, "pmem@{x:.8}", .{info.start}) catch unreachable;
    builder.begin_node(name);
    defer builder.end_node();

    builder.add_property([:0]const u8, "compatible", "pmem-region");
    builder.add_property([]const u64, "reg", &.{ info.start, info.len });
    builder.add_property(void, "volatile", {});
}
