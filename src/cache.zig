const std = @import("std");
const Allocator = std.mem.Allocator;

pub const CacheType = enum {
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
    size: u64,
    cpus_per_unit: u16,
    line_size: u16,
    number_of_sets: u16,

    const Self = @This();

    pub fn new(cache_dir: *const CacheDir, comptime index: usize) !Self {
        var read_buff: [30]u8 = undefined;

        // removing 1 from read bytes because last byte is `10` ASCII and
        // it breaks `parseInt`
        const level_bytes = try cache_dir.read_info(index, "level", &read_buff) - 1;
        const level = try std.fmt.parseInt(u8, read_buff[0..level_bytes], 10);

        const cache_type_bytes = try cache_dir.read_info(index, "type", &read_buff) - 1;
        const cache_type = CacheType.from_str(read_buff[0..cache_type_bytes]);

        const scm_bytes = try cache_dir.read_info(index, "shared_cpu_map", &read_buff) - 1;
        const scm: u16 =
            @intCast(std.mem.count(u8, read_buff[0..scm_bytes], "1"));

        const cls_bytes = try cache_dir.read_info(index, "coherency_line_size", &read_buff) - 1;
        const cls = try std.fmt.parseInt(u16, read_buff[0..cls_bytes], 10);

        const size_bytes = try cache_dir.read_info(index, "size", &read_buff) - 1;
        const size = try parse_size(read_buff[0..size_bytes]);

        const nos_bytes = try cache_dir.read_info(index, "number_of_sets", &read_buff) - 1;
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

    fn parse_size(s: []u8) !u64 {
        return switch (s[s.len - 1]) {
            'K' => try std.fmt.parseInt(u64, s[0 .. s.len - 1], 10) * 1024,
            'M' => try std.fmt.parseInt(u64, s[0 .. s.len - 1], 10) * 1024 * 1024,
            else => unreachable,
        };
    }
};

pub const CacheDir = struct {
    dir: std.fs.Dir,

    const MAX_CACHE_LEVEL: u8 = 7;

    const Self = @This();

    pub fn new() !Self {
        const dir = try std.fs.openDirAbsolute("/sys/devices/system/cpu/cpu0/cache", .{});
        return Self{
            .dir = dir,
        };
    }

    pub fn get_caches(dir: *const CacheDir) ![Self.MAX_CACHE_LEVEL]?CacheEntry {
        var entries: [Self.MAX_CACHE_LEVEL]?CacheEntry = undefined;
        inline for (0..Self.MAX_CACHE_LEVEL) |i| {
            if (CacheEntry.new(dir, i)) |entry| {
                entries[i] = entry;
            } else |_| {
                entries[i] = null;
            }
        }
        return entries;
    }

    fn read_info(self: *const Self, comptime index: u32, comptime name: []const u8, read_buff: []u8) !usize {
        const path = std.fmt.comptimePrint("index{d}/{s}", .{ index, name });
        std.log.info("cache: reading path: {s}", .{path});
        const file = try self.dir.openFile(path, .{});
        return try file.read(read_buff);
    }
};
