const std = @import("std");
const Allocator = std.mem.Allocator;

const CacheDir = @import("cache.zig").CacheDir;
const Gicv2 = @import("gicv2.zig").GICv2;
const m_memory = @import("memory.zig");
const GuestMemory = m_memory.GuestMemory;
const MemoryLayout = m_memory.MemoryLayout;

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

        try data.resize(@sizeOf(FdtHeader));

        // The memory reservation block shall be aligned to an 8-byte boundary
        try Self.align_data(&data, 8);

        const off_mem_rsvmap: u32 = @intCast(data.items.len);

        try Self.write_fdt_reserve_entry(&data, &.{});

        // The structure block to a 4-byte boundary
        try Self.align_data(&data, 4);
        const off_dt_struct: u32 = @intCast(data.items.len);

        const header_ptr: *FdtHeader = @ptrCast(@alignCast(data.items.ptr));
        header_ptr.off_dt_struct = off_dt_struct;
        header_ptr.off_mem_rsvmap = off_mem_rsvmap;

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
            []const u8, [:0]const u8 => {
                try data.appendSlice(item);
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

    // expects integer types to be in big endian format
    pub fn add_property(self: *Self, comptime t: type, name: [:0]const u8, item: t) !void {
        const name_offset = try self.string_offset(name);
        try Self.data_append(u32, &self.data, FDT_PROP);
        const bytes: usize = switch (t) {
            void => 0,
            u32, u64 => @sizeOf(t),
            [:0]const u8 => @sizeOf(u8) * item.len,
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
        // which may require padding bytes (with a value of 0x0)
        // to be inserted after the previous token’s data
        try Self.align_data(&self.data, 4);
    }

    fn string_offset(self: *Self, s: []const u8) !usize {
        if (self.strings_map.get(s)) |offset| {
            return offset;
        } else {
            const new_offset = self.stored_strings.items.len;
            try self.stored_strings.appendSlice(s);
            try self.strings_map.put(s, new_offset);
            return new_offset;
        }
    }

    pub fn finish(self: *Self) !void {
        try Self.data_append(u32, &self.data, FDT_END);

        const header_ptr: *FdtHeader = @ptrCast(@alignCast(self.data.items.ptr));
        header_ptr.magic = FDT_MAGIC;
        header_ptr.totalsize = @intCast(self.data.items.len + self.stored_strings.items.len);
        // header_ptr.off_dt_struct: u32,
        header_ptr.off_dt_strings = @intCast(self.data.items.len);
        // header_ptr.off_mem_rsvmap: u32,
        header_ptr.version = FDT_VERSION;
        header_ptr.last_comp_version = FDT_LAST_COMP_VERSION;
        header_ptr.boot_cpuid_phys = 0;
        header_ptr.size_dt_strings = @intCast(self.stored_strings.items.len);
        header_ptr.size_dt_struct = @as(u32, @intCast(self.data.items.len)) - header_ptr.off_dt_struct;

        try Self.data_append([]const u8, &self.data, self.stored_strings.items);
    }
};

pub fn create_fdt(
    allocator: Allocator,
    guest_mem: *const GuestMemory,
    mpidrs: []const u64,
    cmdline: [:0]const u8,
    gic: *const Gicv2,
) !FdtBuilder {
    const ADDRESS_CELLS: u32 = 0x2;
    const SIZE_CELLS: u32 = 0x2;
    const GIC_PHANDLE: u32 = 1;

    var fdt_builder = try FdtBuilder.new(allocator);

    try fdt_builder.add_property([:0]const u8, "compatible", "linux,dummy-virt");
    // For info on #address-cells and size-cells read "Note about cells and address representation"
    // from the above mentioned txt file.
    try fdt_builder.add_property(u32, "#address-cells", ADDRESS_CELLS);
    try fdt_builder.add_property(u32, "#size-cells", SIZE_CELLS);
    // This is not mandatory but we use it to point the root node to the node
    // containing description of the interrupt controller for this VM.
    try fdt_builder.add_property(u32, "interrupt-parent", GIC_PHANDLE);

    try create_cpu_fdt(&fdt_builder, mpidrs);
    try create_memory_fdt(&fdt_builder, guest_mem);
    try create_cmdline_fdt(&fdt_builder, cmdline);
    try create_gic_fdt(&fdt_builder, gic);
    try create_serial_node(&fdt_builder);

    // End Header node.
    try fdt_builder.end_node();
    try fdt_builder.finish();
    return fdt_builder;
}

fn create_cpu_fdt(builder: *FdtBuilder, mpidrs: []const u64) !void {
    const cache_dir = try CacheDir.new();
    const cache_entries = try cache_dir.get_caches();
    // See https://github.com/torvalds/linux/blob/master/Documentation/devicetree/bindings/arm/cpus.yaml.
    try builder.begin_node("cpus");
    // As per documentation, on ARM v8 64-bit systems value should be set to 2.
    try builder.add_property(u32, "#address-cells", 0x02);
    try builder.add_property(u32, "#size-cells", 0x0);

    for (mpidrs, 0..) |mpidr, i| {
        var print_buff: [10]u8 = undefined;
        const cpu_name = try std.fmt.bufPrintZ(&print_buff, "cpu@{x}", .{i});
        try builder.begin_node(cpu_name);
        try builder.add_property([:0]const u8, "device_type", "cpu");
        try builder.add_property([:0]const u8, "compatible", "arm,arm-v8");
        // The power state coordination interface (PSCI) needs to be enabled for
        // all vcpus.
        try builder.add_property([:0]const u8, "enable-method", "psci");
        // Set the field to first 24 bits of the MPIDR - Multiprocessor Affinity Register.
        // See http://infocenter.arm.com/help/index.jsp?topic=/com.arm.doc.ddi0488c/BABHBJCI.html.
        try builder.add_property(u64, "reg", @byteSwap(mpidr & 0x7FFFFF));
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
        for (cache_entries) |entry| {
            const cache = entry orelse continue;
            if (cache.level == 1) {
                continue;
            }
            // skip ather levels for now
            continue;
        }
        try builder.end_node();
    }
    try builder.end_node();
}

fn create_memory_fdt(builder: *FdtBuilder, guest_memory: *const GuestMemory) !void {
    const mem_size = guest_memory.guest_addr + guest_memory.mem.len - MemoryLayout.DRAM_MEM_START;
    // See https://github.com/torvalds/linux/blob/master/Documentation/devicetree/booting-without-of.txt#L960
    // for an explanation of this.
    const mem_reg_prop = [_]u64{ @byteSwap(MemoryLayout.DRAM_MEM_START), @byteSwap(mem_size) };

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
    try builder.add_property([:0]const u8, "compatible", Gicv2.FDT_COMPATIBILITY);
    try builder.add_property(void, "interrupt-controller", void);
    // "interrupt-cells" field specifies the number of cells needed to encode an
    // interrupt source. The type shall be a <u32> and the value shall be 3 if no PPI affinity
    // description is required.
    try builder.add_property(u32, "#interrupt-cells", 3);

    const device_properties = [_]u64{
        @byteSwap(Gicv2.DISTRIBUTOR_ADDRESS),
        @byteSwap(Gicv2.KVM_VGIC_V2_DIST_SIZE),
        @byteSwap(Gicv2.CPU_ADDRESS),
        @byteSwap(Gicv2.KVM_VGIC_V2_CPU_SIZE),
    };
    try builder.add_property([]const u64, "reg", &device_properties);

    try builder.add_property(u32, "phandle", FdtBuilder.GIC_PHANDLE);
    try builder.add_property(u32, "#address-cells", 2);
    try builder.add_property(u32, "#size-cells", 2);
    try builder.add_property(void, "ranges", void);

    const gic_intr = [_]u32{
        FdtBuilder.GIC_FDT_IRQ_TYPE_PPI,
        Gicv2.ARCH_GIC_V2_MAINT_IRQ,
        FdtBuilder.IRQ_TYPE_LEVEL_HI,
    };

    try builder.add_property([]const u32, "interrupts", &gic_intr);
    try builder.end_node();
}

fn create_serial_node(
    builder: *FdtBuilder,
) !void {
    try builder.begin_node("uart@0x40001000");

    try builder.add_property([:0]const u8, "compatible", "ns16550a");
    try builder.add_property([]const u64, "reg", &.{ 0x40001000, 0x1000 });
    try builder.add_property(u32, "clocks", FdtBuilder.CLOCK_PHANDLE);
    try builder.add_property([:0]const u8, "clock-names", "apb_pclk");
    try builder.add_property(
        []const u32,
        "interrupts",
        &.{ FdtBuilder.GIC_FDT_IRQ_TYPE_SPI, 32, FdtBuilder.IRQ_TYPE_EDGE_RISING },
    );
    try builder.end_node();
}
