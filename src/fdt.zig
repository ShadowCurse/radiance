const std = @import("std");
const Allocator = std.mem.Allocator;

const CacheDir = @import("cache.zig").CacheDir;
const Gicv2 = @import("gicv2.zig");
const MmioDeviceInfo = @import("mmio.zig").MmioDeviceInfo;
const Memory = @import("memory.zig");

pub const FdtHeader = packed struct {
    magic: u32,
    totalsize: u32,
    off_dt_struct: u32,
    off_dt_strings: u32,
    off_mem_rsvmap: u32,
    version: u32,
    last_comp_version: u32,
    boot_cpuid_phys: u32,
    size_dt_strings: u32,
    size_dt_struct: u32,
};

pub const FdtReserveEntry = packed struct {
    address: u64,
    size: u64,
};

// https://devicetree-specification.readthedocs.io/en/stable/flattened-format.html
pub const FdtBuilder = struct {
    data: std.ArrayList(u8),
    strings_map: std.StringHashMap(usize),
    stored_strings: std.ArrayList(u8),

    /// Maximum size of the device tree blob as specified in https://www.kernel.org/doc/Documentation/arm64/booting.txt.
    const FDT_MAX_SIZE: usize = 0x20_0000;
    const FDT_VERSION: u32 = 17;
    const FDT_LAST_COMP_VERSION: u32 = 16;
    const FDT_MAGIC: u32 = 0xd00dfeed;
    const FDT_BEGIN_NODE: u32 = 0x00000001;
    const FDT_END_NODE: u32 = 0x00000002;
    const FDT_PROP: u32 = 0x00000003;
    const FDT_NOP: u32 = 0x00000004;
    const FDT_END: u32 = 0x00000009;

    // This is a value for uniquely identifying the FDT node declaring the interrupt controller.
    const GIC_PHANDLE: u32 = 1;
    // This is a value for uniquely identifying the FDT node containing the clock definition.
    const CLOCK_PHANDLE: u32 = 2;
    // As per kvm tool and
    // https://www.kernel.org/doc/Documentation/devicetree/bindings/interrupt-controller/arm%2Cgic.txt
    // Look for "The 1st cell..."
    const GIC_FDT_IRQ_TYPE_SPI: u32 = 0;
    const GIC_FDT_IRQ_TYPE_PPI: u32 = 1;

    // From https://elixir.bootlin.com/linux/v4.9.62/source/include/dt-bindings/interrupt-controller/irq.h#L17
    const IRQ_TYPE_EDGE_RISING: u32 = 1;
    const IRQ_TYPE_LEVEL_HI: u32 = 4;

    const Self = @This();

    pub fn new(allocator: Allocator) !Self {
        var data = std.ArrayList(u8).init(allocator);

        // Allocation 40 bytes. This is a size of FdtHeader struct.
        // For some reason @sizeOf(FdtHeader) returns 48.
        try data.resize(40);
        @memset(data.items, 0);

        // The memory reservation block shall be aligned to an 8-byte boundary
        try Self.align_data(&data, 8);

        const off_mem_rsvmap: u32 = @intCast(data.items.len);

        try Self.write_fdt_reserve_entry(&data, &.{});

        // The structure block to a 4-byte boundary
        try Self.align_data(&data, 4);
        const off_dt_struct: u32 = @intCast(data.items.len);

        const header_ptr: *FdtHeader = @ptrCast(@alignCast(data.items.ptr));
        // All values in the FDT should be in big endian format.
        header_ptr.off_dt_struct = @byteSwap(off_dt_struct);
        header_ptr.off_mem_rsvmap = @byteSwap(off_mem_rsvmap);

        return Self{
            .data = data,
            .strings_map = std.StringHashMap(usize).init(allocator),
            .stored_strings = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.data.deinit();
        self.strings_map.deinit();
        self.stored_strings.deinit();
    }

    pub fn fdt_addr(last_addr: u64) u64 {
        return last_addr - Self.FDT_MAX_SIZE + 1;
    }

    fn align_data(data: *std.ArrayList(u8), alignment: usize) !void {
        const offset = data.items.len % alignment;
        if (offset != 0) {
            try data.appendNTimes(
                0,
                alignment - offset,
            );
        }
    }

    fn write_fdt_reserve_entry(data: *std.ArrayList(u8), entries: []FdtReserveEntry) !void {
        for (entries) |entry| {
            try Self.data_append(u64, data, entry.address);
            try Self.data_append(u64, data, entry.size);
        }
        // The list of reserved blocks shall be terminated with an entry where both address and size are equal to 0
        try Self.data_append(u64, data, @as(u64, 0));
        try Self.data_append(u64, data, @as(u64, 0));
    }

    fn data_append(comptime t: type, data: *std.ArrayList(u8), item: t) !void {
        switch (t) {
            void => {},
            u32, u64 => {
                const i = @byteSwap(item);
                try data.appendSlice(@as([]const u8, std.mem.asBytes(&i)));
            },
            []const u32, []const u64 => {
                for (item) |i| {
                    const s = @byteSwap(i);
                    try data.appendSlice(@as([]const u8, std.mem.asBytes(&s)));
                }
            },
            []const u8 => {
                try data.appendSlice(item);
            },
            [:0]const u8 => {
                try data.appendSlice(item);
                try data.append(0);
            },
            else => std.debug.panic("Unknown type: {any}", .{t}),
        }
    }

    pub fn begin_node(self: *Self, name: [:0]const u8) !void {
        try Self.data_append(u32, &self.data, FDT_BEGIN_NODE);
        try Self.data_append([:0]const u8, &self.data, name);
        try Self.align_data(&self.data, 4);
    }

    pub fn end_node(self: *Self) !void {
        try Self.data_append(u32, &self.data, FDT_END_NODE);
    }

    /// Expects integer types to be in big endian format. (use @byteSwap(..) before passing integers)
    pub fn add_property(self: *Self, comptime t: type, name: [:0]const u8, item: t) !void {
        const name_offset = try self.string_offset(name);
        try Self.data_append(u32, &self.data, FDT_PROP);
        const bytes: usize = switch (t) {
            void => 0,
            u32, u64 => @sizeOf(t),
            [:0]const u8 => @sizeOf(u8) * item.len + 1,
            []const u32 => @sizeOf(u32) * item.len,
            []const u64 => @sizeOf(u64) * item.len,
            else => std.debug.panic("Unknown type: {any}", .{t}),
        };
        const len: u32 = @intCast(bytes);
        try Self.data_append(u32, &self.data, len);
        const offset: u32 = @intCast(name_offset);
        try Self.data_append(u32, &self.data, offset);
        try Self.data_append(t, &self.data, item);
        // All tokens shall be aligned on a 32-bit boundary,
        // which may require padding bytes (with 0)
        // to be inserted after the previous token’s data
        try Self.align_data(&self.data, 4);
    }

    fn string_offset(self: *Self, s: [:0]const u8) !usize {
        if (self.strings_map.get(s)) |offset| {
            return offset;
        } else {
            const new_offset = self.stored_strings.items.len;
            try self.stored_strings.appendSlice(s);
            try self.stored_strings.append(0);
            try self.strings_map.put(s, new_offset);
            return new_offset;
        }
    }

    pub fn finish(self: *Self) !void {
        try Self.data_append(u32, &self.data, FDT_END);

        const header_ptr: *FdtHeader = @ptrCast(@alignCast(self.data.items.ptr));
        // All values in the FDT should be in big endian format.
        header_ptr.magic = @byteSwap(FDT_MAGIC);
        header_ptr.totalsize = @byteSwap(@as(u32, @intCast(self.data.items.len + self.stored_strings.items.len)));
        // Already set.
        // header_ptr.off_dt_struct: u32,
        header_ptr.off_dt_strings = @byteSwap(@as(u32, @intCast(self.data.items.len)));
        // Already set.
        // header_ptr.off_mem_rsvmap: u32,
        header_ptr.version = @byteSwap(FDT_VERSION);
        header_ptr.last_comp_version = @byteSwap(FDT_LAST_COMP_VERSION);
        header_ptr.boot_cpuid_phys = 0;
        header_ptr.size_dt_strings = @byteSwap(@as(u32, @intCast(self.stored_strings.items.len)));
        header_ptr.size_dt_struct = @byteSwap(@as(u32, @intCast(self.data.items.len)) - @byteSwap(header_ptr.off_dt_struct));

        try Self.data_append([]const u8, &self.data, self.stored_strings.items);
    }
};

pub fn create_fdt(
    allocator: Allocator,
    memory: *const Memory,
    mpidrs: []const u64,
    cmdline: [:0]const u8,
    gic: *const Gicv2,
    serial_device_info: MmioDeviceInfo,
    rtc_device_info: MmioDeviceInfo,
    virtio_devices_info: []const MmioDeviceInfo,
) !FdtBuilder {
    const ADDRESS_CELLS: u32 = 0x2;
    const SIZE_CELLS: u32 = 0x2;
    const GIC_PHANDLE: u32 = 1;

    var fdt_builder = try FdtBuilder.new(allocator);

    // use &.{0} to make an empty string with 0 at the end
    try fdt_builder.begin_node(&.{0});

    try fdt_builder.add_property([:0]const u8, "compatible", "linux,dummy-virt");
    // For info on #address-cells and size-cells read "Note about cells and address representation"
    // from the above mentioned txt file.
    try fdt_builder.add_property(u32, "#address-cells", ADDRESS_CELLS);
    try fdt_builder.add_property(u32, "#size-cells", SIZE_CELLS);
    // This is not mandatory but we use it to point the root node to the node
    // containing description of the interrupt controller for this VM.
    try fdt_builder.add_property(u32, "interrupt-parent", GIC_PHANDLE);

    try create_cpu_fdt(&fdt_builder, mpidrs);
    try create_memory_fdt(&fdt_builder, memory);
    try create_cmdline_fdt(&fdt_builder, cmdline);
    try create_gic_fdt(&fdt_builder, gic);
    try create_timer_node(&fdt_builder);
    try create_clock_node(&fdt_builder);
    try create_psci_node(&fdt_builder);

    try create_serial_node(&fdt_builder, serial_device_info);
    try create_rtc_node(&fdt_builder, rtc_device_info);

    for (virtio_devices_info) |*info| {
        try create_virtio_node(&fdt_builder, info);
    }

    // End Header node.
    try fdt_builder.end_node();
    try fdt_builder.finish();
    return fdt_builder;
}

fn create_cpu_fdt(builder: *FdtBuilder, mpidrs: []const u64) !void {
    // This phandle is used to uniquely identify the FDT nodes containing cache information. Each cpu
    // can have a variable number of caches, some of these caches may be shared with other cpus.
    // So, we start the indexing of the phandles used from a really big number and then substract from
    // it as we need more and more phandle for each cache representation.
    const LAST_CACHE_PHANDLE: u32 = 4000;

    const cache_dir = try CacheDir.new();
    const cache_entries = try cache_dir.get_caches();
    // See https://github.com/torvalds/linux/blob/master/Documentation/devicetree/bindings/arm/cpus.yaml.
    try builder.begin_node("cpus");
    // As per documentation, on ARM v8 64-bit systems value should be set to 2.
    try builder.add_property(u32, "#address-cells", 0x02);
    try builder.add_property(u32, "#size-cells", 0x0);

    for (mpidrs, 0..) |mpidr, i| {
        var print_buff: [20]u8 = undefined;
        const cpu_name = try std.fmt.bufPrintZ(&print_buff, "cpu@{x}", .{i});
        try builder.begin_node(cpu_name);
        try builder.add_property([:0]const u8, "device_type", "cpu");
        try builder.add_property([:0]const u8, "compatible", "arm,arm-v8");
        // The power state coordination interface (PSCI) needs to be enabled for
        // all vcpus.
        try builder.add_property([:0]const u8, "enable-method", "psci");
        // Set the field to first 24 bits of the MPIDR - Multiprocessor Affinity Register.
        // See http://infocenter.arm.com/help/index.jsp?topic=/com.arm.doc.ddi0488c/BABHBJCI.html.
        try builder.add_property(u64, "reg", mpidr & 0x7FFFFF);
        for (cache_entries) |entry| {
            const cache = entry orelse continue;
            if (cache.level != 1) {
                continue;
            }
            // https://github.com/devicetree-org/devicetree-specification/releases/download/v0.3/devicetree-specification-v0.3.pdf
            const cache_size: u32 = @intCast(cache.size);
            try builder.add_property(u32, cache.cache_type.cache_size_str(), cache_size);

            const line_size: u32 = @intCast(cache.line_size);
            try builder.add_property(u32, cache.cache_type.cache_line_size_str(), line_size);

            const number_of_sets: u32 = @intCast(cache.number_of_sets);
            try builder.add_property(u32, cache.cache_type.cache_sets_str(), number_of_sets);
        }
        var prev_level: u8 = 1;
        var in_cache_node: bool = false;
        for (cache_entries) |entry| {
            const cache = entry orelse continue;
            if (cache.level == 1) {
                continue;
            }
            // skip ather levels for now
            const cache_phandle: u32 = LAST_CACHE_PHANDLE -
                @as(u32, @intCast(mpidrs.len)) * @as(u32, cache.level - 2) +
                @as(u32, @intCast(i)) / cache.cpus_per_unit;
            if (prev_level != cache.level) {
                try builder.add_property(u32, "next-level-cache", cache_phandle);
                if (prev_level > 1 and in_cache_node) {
                    try builder.end_node();
                }
            }
            if (i % cache.cpus_per_unit == 0) {
                in_cache_node = true;
                const node_name = try std.fmt.bufPrintZ(
                    &print_buff,
                    "l{}-{}-cache",
                    .{ cache.level, i / cache.cpus_per_unit },
                );
                try builder.begin_node(node_name);
                try builder.add_property(u32, "phandle", cache_phandle);
                try builder.add_property([:0]const u8, "compatible", "cache");
                try builder.add_property(u32, "cache-level", cache.level);
                const cache_size: u32 = @intCast(cache.size);
                try builder.add_property(u32, cache.cache_type.cache_size_str(), cache_size);
                const line_size: u32 = @intCast(cache.line_size);
                try builder.add_property(u32, cache.cache_type.cache_line_size_str(), line_size);
                const number_of_sets: u32 = @intCast(cache.number_of_sets);
                try builder.add_property(u32, cache.cache_type.cache_sets_str(), number_of_sets);
                if (cache.cache_type.cache_type_str()) |s| {
                    try builder.add_property(void, s, {});
                }
                prev_level = cache.level;
            }
        }
        if (in_cache_node) {
            try builder.end_node();
        }

        try builder.end_node();
    }
    try builder.end_node();
}

fn create_memory_fdt(builder: *FdtBuilder, memory: *const Memory) !void {
    const mem_size = memory.guest_addr + memory.mem.len - Memory.DRAM_START;
    // See https://github.com/torvalds/linux/blob/master/Documentation/devicetree/booting-without-of.txt#L960
    // for an explanation of this.
    const mem_reg_prop = [_]u64{ Memory.DRAM_START, mem_size };

    try builder.begin_node("memory");
    try builder.add_property([:0]const u8, "device_type", "memory");
    try builder.add_property([]const u64, "reg", &mem_reg_prop);
    try builder.end_node();
}

fn create_cmdline_fdt(builder: *FdtBuilder, cmdline: [:0]const u8) !void {
    try builder.begin_node("chosen");
    try builder.add_property([:0]const u8, "bootargs", cmdline);
    try builder.end_node();
}

fn create_gic_fdt(builder: *FdtBuilder, gic: *const Gicv2) !void {
    _ = gic;
    try builder.begin_node("intc");
    try builder.add_property([:0]const u8, "compatible", "arm,gic-400");
    try builder.add_property(void, "interrupt-controller", {});
    // "interrupt-cells" field specifies the number of cells needed to encode an
    // interrupt source. The type shall be a <u32> and the value shall be 3 if no PPI affinity
    // description is required.
    try builder.add_property(u32, "#interrupt-cells", 3);
    try builder.add_property([]const u64, "reg", &Gicv2.DEVICE_PROPERTIES);
    try builder.add_property(u32, "phandle", FdtBuilder.GIC_PHANDLE);
    try builder.add_property(u32, "#address-cells", 2);
    try builder.add_property(u32, "#size-cells", 2);
    try builder.add_property(void, "ranges", {});

    const gic_intr = [_]u32{
        FdtBuilder.GIC_FDT_IRQ_TYPE_PPI,
        Gicv2.ARCH_GIC_V2_MAINT_IRQ,
        FdtBuilder.IRQ_TYPE_LEVEL_HI,
    };

    try builder.add_property([]const u32, "interrupts", &gic_intr);
    try builder.end_node();
}

fn create_clock_node(builder: *FdtBuilder) !void {
    // The Advanced Peripheral Bus (APB) is part of the Advanced Microcontroller Bus Architecture
    // (AMBA) protocol family. It defines a low-cost interface that is optimized for minimal power
    // consumption and reduced interface complexity.
    // PCLK is the clock source and this node defines exactly the clock for the APB.
    try builder.begin_node("apb-pclk");
    try builder.add_property([:0]const u8, "compatible", "fixed-clock");
    try builder.add_property(u32, "#clock-cells", 0x0);
    try builder.add_property(u32, "clock-frequency", 24_000_000);
    try builder.add_property([:0]const u8, "clock-output-names", "clk24mhz");
    try builder.add_property(u32, "phandle", FdtBuilder.CLOCK_PHANDLE);
    try builder.end_node();
}

fn create_timer_node(builder: *FdtBuilder) !void {
    // https://github.com/torvalds/linux/blob/master/Documentation/devicetree/bindings/interrupt-controller/arch_timer.txt
    // These are fixed interrupt numbers for the timer device.
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
    try builder.begin_node("timer");
    try builder.add_property([:0]const u8, "compatible", "arm,armv8-timer");
    try builder.add_property(void, "always-on", {});
    try builder.add_property([]const u32, "interrupts", &interrupts);
    try builder.end_node();
}

fn create_psci_node(builder: *FdtBuilder) !void {
    try builder.begin_node("psci");
    try builder.add_property([:0]const u8, "compatible", "arm,psci-0.2");
    // Two methods available: hvc and smc.
    // As per documentation, PSCI calls between a guest and hypervisor may use the HVC conduit
    // instead of SMC. So, since we are using kvm, we need to use hvc.
    try builder.add_property([:0]const u8, "method", "hvc");
    try builder.end_node();
}

fn create_serial_node(builder: *FdtBuilder, device_info: MmioDeviceInfo) !void {
    var buff: [20]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&buff, "uart@{x:.8}", .{device_info.addr});
    try builder.begin_node(name);

    try builder.add_property([:0]const u8, "compatible", "ns16550a");
    try builder.add_property([]const u64, "reg", &.{ device_info.addr, device_info.len });
    try builder.add_property(u32, "clocks", FdtBuilder.CLOCK_PHANDLE);
    try builder.add_property([:0]const u8, "clock-names", "apb_pclk");
    try builder.add_property(
        []const u32,
        "interrupts",
        &.{ FdtBuilder.GIC_FDT_IRQ_TYPE_SPI, device_info.irq, FdtBuilder.IRQ_TYPE_EDGE_RISING },
    );
    try builder.end_node();
}

fn create_rtc_node(builder: *FdtBuilder, device_info: MmioDeviceInfo) !void {
    // Driver requirements:
    // https://elixir.bootlin.com/linux/latest/source/Documentation/devicetree/bindings/rtc/arm,pl031.yaml
    // We do not offer the `interrupt` property because the device
    // does not implement interrupt support.
    var buff: [20]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&buff, "rtc@{x:.8}", .{device_info.addr});
    try builder.begin_node(name);

    try builder.add_property([:0]const u8, "compatible", "arm,pl031\u{0}arm,primecell");
    try builder.add_property([]const u64, "reg", &.{ device_info.addr, device_info.len });
    try builder.add_property(u32, "clocks", FdtBuilder.CLOCK_PHANDLE);
    try builder.add_property([:0]const u8, "clock-names", "apb_pclk");
    try builder.end_node();
}

fn create_virtio_node(
    builder: *FdtBuilder,
    device_info: *const MmioDeviceInfo,
) !void {
    var buff: [30]u8 = undefined;
    const name = try std.fmt.bufPrintZ(&buff, "virtio_mmio@{x:.8}", .{device_info.addr});
    try builder.begin_node(name);

    try builder.add_property([:0]const u8, "compatible", "virtio,mmio");
    try builder.add_property([]const u64, "reg", &.{ device_info.addr, device_info.len });
    try builder.add_property(
        []const u32,
        "interrupts",
        &.{ FdtBuilder.GIC_FDT_IRQ_TYPE_SPI, device_info.irq, FdtBuilder.IRQ_TYPE_EDGE_RISING },
    );
    try builder.add_property(u32, "interrupt-parent", FdtBuilder.GIC_PHANDLE);
    try builder.end_node();
}
