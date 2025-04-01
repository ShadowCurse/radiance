const std = @import("std");
const log = @import("log.zig");
const nix = @import("nix.zig");

pub const CacheType = enum(u8) {
    Instruction,
    Data,
    Unified,

    const Self = @This();

    pub fn from_str(s: []const u8) Self {
        if (std.mem.eql(u8, s, "Instruction")) {
            return Self.Instruction;
        } else if (std.mem.eql(u8, s, "Data")) {
            return Self.Data;
        } else if (std.mem.eql(u8, s, "Unified")) {
            return Self.Unified;
        } else {
            unreachable;
        }
    }

    pub fn cache_size_str(self: Self) [:0]const u8 {
        return switch (self) {
            Self.Instruction => "i-cache-size",
            Self.Data => "d-cache-size",
            Self.Unified => "cache-size",
        };
    }

    pub fn cache_line_size_str(self: Self) [:0]const u8 {
        return switch (self) {
            Self.Instruction => "i-cache-line-size",
            Self.Data => "d-cache-line-size",
            Self.Unified => "cache-line-size",
        };
    }

    pub fn cache_type_str(self: Self) ?[:0]const u8 {
        return switch (self) {
            Self.Instruction => null,
            Self.Data => null,
            Self.Unified => "cache-unified",
        };
    }

    pub fn cache_sets_str(self: Self) [:0]const u8 {
        return switch (self) {
            Self.Instruction => "i-cache-sets",
            Self.Data => "d-cache-sets",
            Self.Unified => "cache-sets",
        };
    }
};

pub const CacheEntry = struct {
    level: u8,
    cache_type: CacheType,
    size: u32,
    cpus_per_unit: u16,
    line_size: u16,
    number_of_sets: u16,

    const Self = @This();

    pub fn new(comptime index: usize) !Self {
        var read_buff: [30]u8 = undefined;

        // removing 1 from read bytes because last byte is `10` ASCII and
        // it breaks `parseInt`
        const level_bytes = try Self.read_info(index, "level", &read_buff) - 1;
        const level = try std.fmt.parseInt(u8, read_buff[0..level_bytes], 10);

        const cache_type_bytes = try Self.read_info(index, "type", &read_buff) - 1;
        const cache_type = CacheType.from_str(read_buff[0..cache_type_bytes]);

        const scm_bytes = try Self.read_info(index, "shared_cpu_map", &read_buff) - 1;
        var scm: u16 = 0;
        var scm_iter = std.mem.splitScalar(u8, read_buff[0..scm_bytes], ',');
        while (scm_iter.next()) |slice| {
            const v = try std.fmt.parseInt(u8, slice, 16);
            scm += @popCount(v);
        }

        const cls_bytes = try Self.read_info(index, "coherency_line_size", &read_buff) - 1;
        const cls = try std.fmt.parseInt(u16, read_buff[0..cls_bytes], 10);

        const size_bytes = try Self.read_info(index, "size", &read_buff) - 1;
        const size = try parse_size(read_buff[0..size_bytes]);

        const nos_bytes = try Self.read_info(index, "number_of_sets", &read_buff) - 1;
        const nos = try std.fmt.parseInt(u16, read_buff[0..nos_bytes], 10);

        return Self{
            .level = level,
            .cache_type = cache_type,
            .size = size,
            .cpus_per_unit = scm,
            .line_size = cls,
            .number_of_sets = nos,
        };
    }

    fn parse_size(s: []u8) !u32 {
        return switch (s[s.len - 1]) {
            'K' => try std.fmt.parseInt(u32, s[0 .. s.len - 1], 10) * 1024,
            'M' => try std.fmt.parseInt(u32, s[0 .. s.len - 1], 10) * 1024 * 1024,
            else => unreachable,
        };
    }

    fn read_info(
        comptime index: u32,
        comptime name: []const u8,
        read_buff: []u8,
    ) !usize {
        const path =
            std.fmt.comptimePrint(
                "/sys/devices/system/cpu/cpu0/cache/index{d}/{s}",
                .{ index, name },
            );
        log.debug(@src(), "reading cache path: {s}", .{path});
        const fd = try nix.open(path, .{ .CLOEXEC = true, .ACCMODE = .RDONLY }, 0);
        defer nix.close(fd);
        return try nix.read(fd, read_buff);
    }
};

// 0 - l1i
// 1 - l1d
// 2 - l2
// 3 - l3
const MAX_CACHE_INDEXES = 4;
pub const Caches = struct {
    l1d_cache: ?CacheEntry = null,
    l1i_cache: ?CacheEntry = null,
    l2_cache: ?CacheEntry = null,
    l3_cache: ?CacheEntry = null,
};
pub fn read_host_caches() Caches {
    var caches: Caches = .{};
    inline for (0..MAX_CACHE_INDEXES) |i| {
        if (CacheEntry.new(i)) |entry| {
            switch (entry.level) {
                1 => {
                    switch (entry.cache_type) {
                        .Data => caches.l1d_cache = entry,
                        .Instruction => caches.l1i_cache = entry,
                        .Unified => unreachable,
                    }
                },
                2 => caches.l2_cache = entry,
                3 => caches.l3_cache = entry,
                else => {},
            }
            log.debug(@src(), "Processed cache entry: {any}", .{entry});
        } else |e| log.warn(@src(), "Skipping cache index {} due to error: {}", .{ i, e });
    }
    return caches;
}
