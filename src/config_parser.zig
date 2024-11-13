const std = @import("std");
const nix = @import("nix.zig");

const HOST_PAGE_SIZE = @import("memory.zig").HOST_PAGE_SIZE;

const Allocator = std.mem.Allocator;
const SplitIterator = std.mem.SplitIterator;

pub const ConfigParseError = error{
    UnknownTableType,
    NoFieldName,
    NoFieldValue,
};

pub const MachineConfig = struct {
    vcpus: u32 = 0,
    memory_mb: u32 = 0,

    const Self = @This();

    fn update(self: *Self, line_iter: *SplitIterator(u8, .scalar)) !void {
        const new_self = try parse_type(Self, line_iter);
        self.* = new_self;
    }
};

pub const KernelConfig = struct {
    path: []const u8 = "",

    const Self = @This();

    fn update(self: *Self, line_iter: *SplitIterator(u8, .scalar)) !void {
        const new_self = try parse_type(Self, line_iter);
        self.* = new_self;
    }
};

pub const DriveConfig = struct {
    read_only: bool = false,
    path: []const u8 = "",
};

pub const DrivesConfigs = struct {
    drives: std.BoundedArray(DriveConfig, 8) = .{},

    const Self = @This();

    fn update(self: *Self, line_iter: *SplitIterator(u8, .scalar)) !void {
        const new_config = try parse_type(DriveConfig, line_iter);
        try self.drives.append(new_config);
    }
};

pub const NetConfig = struct {
    dev_name: []const u8 = "",
    mac: ?[6]u8 = null,
    vhost: bool = false,
};

pub const NetConfigs = struct {
    networks: std.BoundedArray(NetConfig, 8) = .{},

    const Self = @This();

    fn update(self: *Self, line_iter: *SplitIterator(u8, .scalar)) !void {
        const new_config = try parse_type(NetConfig, line_iter);
        try self.networks.append(new_config);
    }
};

pub const GdbConfig = struct {
    socket_path: ?[]const u8 = null,

    const Self = @This();

    fn update(self: *Self, line_iter: *SplitIterator(u8, .scalar)) !void {
        const new_self = try parse_type(Self, line_iter);
        self.* = new_self;
    }
};

pub const Config = struct {
    machine: MachineConfig = .{},
    kernel: KernelConfig = .{},
    drives: DrivesConfigs = .{},
    networks: NetConfigs = .{},
    gdb: GdbConfig = .{},
};

pub const ParseResult = struct {
    config: Config = .{},
    file_mem: []align(HOST_PAGE_SIZE) const u8 = undefined,

    const Self = @This();

    pub fn deinit(self: *const Self) void {
        nix.munmap(self.file_mem);
    }
};

pub fn parse(config_path: []const u8) !ParseResult {
    const fd = try nix.open(
        config_path,
        .{
            .ACCMODE = .RDONLY,
        },
        0,
    );
    defer nix.close(fd);

    const statx = try nix.statx(fd);
    const file_mem = try nix.mmap(
        null,
        statx.size,
        nix.PROT.READ,
        .{
            .TYPE = .PRIVATE,
        },
        fd,
        0,
    );

    var line_iter = std.mem.splitScalar(u8, file_mem, '\n');
    const type_fields = comptime @typeInfo(Config).Struct.fields;
    var config: Config = .{};

    while (line_iter.next()) |line| {
        if (line.len != 0) {
            const filed_name = blk: {
                // Skip comments
                if (std.mem.startsWith(u8, line, "#")) {
                    continue;
                } else
                // Find groups
                if (std.mem.startsWith(u8, line, "[[")) {
                    break :blk line[2 .. line.len - 2];
                } else
                // Find single enements
                if (std.mem.startsWith(u8, line, "[")) {
                    break :blk line[1 .. line.len - 1];
                } else {
                    return ConfigParseError.UnknownTableType;
                }
            };
            inline for (type_fields) |field| {
                if (std.mem.eql(u8, field.name, filed_name)) {
                    try @field(config, field.name).update(&line_iter);
                    break;
                }
            }
        }
    }

    return .{
        .config = config,
        .file_mem = file_mem,
    };
}

fn parse_type(comptime T: type, line_iter: *SplitIterator(u8, .scalar)) !T {
    const type_fields = comptime @typeInfo(T).Struct.fields;
    var t: T = .{};
    while (line_iter.next()) |line| {
        if (line.len == 0 or line[0] == '[') {
            break;
        }

        var iter = std.mem.splitScalar(u8, line, '=');
        const field_name = blk: {
            if (iter.next()) |name| {
                break :blk std.mem.trim(u8, name, " ");
            } else {
                return ConfigParseError.NoFieldName;
            }
        };
        const field_value = blk: {
            if (iter.next()) |value| {
                break :blk std.mem.trim(u8, value, " ");
            } else {
                return ConfigParseError.NoFieldValue;
            }
        };

        inline for (type_fields) |field| {
            if (std.mem.eql(u8, field.name, field_name)) {
                switch (field.type) {
                    ?[6]u8 => {
                        var array: [6]u8 = undefined;
                        var i: usize = 0;
                        const val_array = std.mem.trim(u8, field_value, "[]");
                        var val_iter = std.mem.splitScalar(u8, val_array, ',');
                        while (val_iter.next()) |value| {
                            const v = std.mem.trim(u8, value, " ");
                            const n = try std.fmt.parseInt(u8, v, 16);
                            array[i] = n;
                            i += 1;
                        }
                        if (i != 6) {
                            return ConfigParseError.NoFieldValue;
                        }
                        @field(t, field.name) = array;
                    },
                    [:0]const u8 => {
                        const string = std.mem.trim(u8, field_value, "\"");
                        @field(t, field.name) = string;
                    },
                    []const u8 => {
                        const string = std.mem.trim(u8, field_value, "\"");
                        @field(t, field.name) = string;
                    },
                    ?[]const u8 => {
                        const string = std.mem.trim(u8, field_value, "\"");
                        @field(t, field.name) = string;
                    },
                    u32 => {
                        @field(t, field.name) = try std.fmt.parseInt(u32, field_value, 10);
                    },
                    bool => {
                        @field(t, field.name) = std.mem.eql(u8, field_value, "true");
                    },
                    else => unreachable,
                }
            }
        }
    }
    return t;
}
