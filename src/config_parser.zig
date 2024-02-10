const std = @import("std");
const Allocator = std.mem.Allocator;
const Reader = std.fs.File.Reader;

pub const ConfigParseError = error{
    UnknownTableType,
    NoFieldName,
    NoFieldValue,
};

pub const MachineConfig = struct {
    vcpus: u32,
    memory_mb: u32,

    const Self = @This();

    pub fn default() Self {
        return Self{
            .vcpus = 0,
            .memory_mb = 0,
        };
    }

    fn update(self: *Self, reader: *Reader, buffer: *std.ArrayList(u8), allocator: Allocator) !void {
        const new_self = try parse_type(Self, reader, buffer, allocator);
        self.* = new_self;
    }
};

pub const KernelConfig = struct {
    path: []const u8,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: Allocator) void {
        allocator.free(self.path);
    }

    pub fn default() Self {
        return Self{ .path = "" };
    }

    fn update(self: *Self, reader: *Reader, buffer: *std.ArrayList(u8), allocator: Allocator) !void {
        const new_self = try parse_type(Self, reader, buffer, allocator);
        self.* = new_self;
    }
};

pub const RootfsConfig = struct {
    read_only: bool,

    const Self = @This();

    pub fn default() Self {
        return Self{ .read_only = false };
    }

    fn update(self: *Self, reader: *Reader, buffer: *std.ArrayList(u8), allocator: Allocator) !void {
        const new_self = try parse_type(Self, reader, buffer, allocator);
        self.* = new_self;
    }
};

pub const DriveConfig = struct {
    read_only: bool,
    path: []const u8,

    const Self = @This();

    pub fn deinit(self: *Self, allocator: Allocator) void {
        allocator.free(self.path);
    }

    pub fn default() Self {
        return Self{ .read_only = false, .path = "" };
    }
};

pub const DrivesConfigs = struct {
    drives: std.ArrayListUnmanaged(DriveConfig),

    const Self = @This();

    pub fn default() Self {
        return Self{
            .drives = std.ArrayListUnmanaged(DriveConfig){},
        };
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        for (self.drives.items) |*drive| {
            drive.deinit(allocator);
        }
        self.drives.deinit(allocator);
    }

    fn update(self: *Self, reader: *Reader, buffer: *std.ArrayList(u8), allocator: Allocator) !void {
        const new_config = try parse_type(DriveConfig, reader, buffer, allocator);
        try self.drives.append(allocator, new_config);
    }
};

pub const Config = struct {
    machine: MachineConfig,
    kernel: KernelConfig,
    rootfs: RootfsConfig,
    drives: DrivesConfigs,

    const Self = @This();

    pub fn default() Self {
        return Self{
            .machine = MachineConfig.default(),
            .kernel = KernelConfig.default(),
            .rootfs = RootfsConfig.default(),
            .drives = DrivesConfigs.default(),
        };
    }

    pub fn deinit(self: *Self, allocator: Allocator) void {
        self.kernel.deinit(allocator);
        self.drives.deinit(allocator);
    }
};

pub fn parse(config_path: []const u8, allocator: Allocator) !Config {
    var file_options: std.fs.File.OpenFlags = .{};
    file_options.mode = std.fs.File.OpenMode.read_write;
    const file = try std.fs.cwd().openFile(config_path, file_options);
    var reader = file.reader();

    var buffer = std.ArrayList(u8).init(allocator);
    defer buffer.deinit();

    const type_fields = comptime @typeInfo(Config).Struct.fields;
    var config = Config.default();

    while (true) {
        var writer = buffer.writer();
        reader.streamUntilDelimiter(writer, '\n', null) catch {
            break;
        };

        if (buffer.items.len != 0) {
            const filed_name = blk: {
                if (std.mem.startsWith(u8, buffer.items, "[[")) {
                    break :blk buffer.items[2 .. buffer.items.len - 2];
                } else if (std.mem.startsWith(u8, buffer.items, "[")) {
                    break :blk buffer.items[1 .. buffer.items.len - 1];
                } else {
                    return ConfigParseError.UnknownTableType;
                }
            };
            inline for (type_fields) |field| {
                if (std.mem.eql(u8, field.name, filed_name)) {
                    buffer.clearRetainingCapacity();
                    try @field(config, field.name).update(&reader, &buffer, allocator);
                    break;
                }
            }
        }

        buffer.clearRetainingCapacity();
    }

    return config;
}

fn parse_type(comptime T: type, reader: *Reader, buffer: *std.ArrayList(u8), allocator: Allocator) !T {
    const type_fields = comptime @typeInfo(T).Struct.fields;
    var t: T = T.default();
    while (true) {
        var writer = buffer.writer();
        reader.streamUntilDelimiter(writer, '\n', null) catch {
            break;
        };

        if (buffer.items.len == 0 or buffer.items[0] == '[') {
            break;
        }

        var iter = std.mem.splitScalar(u8, buffer.items, '=');
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
                    []const u8 => {
                        @field(t, field.name) = try allocator.dupe(u8, field_value);
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
        buffer.clearRetainingCapacity();
    }
    return t;
}
