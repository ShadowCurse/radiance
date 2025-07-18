const std = @import("std");
const nix = @import("nix.zig");

const HOST_PAGE_SIZE = @import("memory.zig").HOST_PAGE_SIZE;

const Allocator = std.mem.Allocator;
const SplitIterator = std.mem.SplitIterator;

pub const MachineConfig = struct {
    vcpus: u32 = 0,
    memory_mb: u32 = 0,
    cmdline: []const u8 = &.{},

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

pub const UartConfig = struct {
    enabled: bool = true,

    const Self = @This();

    fn update(self: *Self, line_iter: *SplitIterator(u8, .scalar)) !void {
        const new_self = try parse_type(Self, line_iter);
        self.* = new_self;
    }
};

pub const DriveConfig = struct {
    path: []const u8 = "",
    read_only: bool = false,
    io_uring: bool = false,
    pci: bool = false,
    rootfs: bool = false,
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

pub const PmemConfig = struct {
    path: []const u8 = "",
    rootfs: bool = false,
};

pub const PmemConfigs = struct {
    pmems: std.BoundedArray(PmemConfig, 8) = .{},

    const Self = @This();

    fn update(self: *Self, line_iter: *SplitIterator(u8, .scalar)) !void {
        const new_config = try parse_type(PmemConfig, line_iter);
        try self.pmems.append(new_config);
    }
};

pub const GdbConfig = struct {
    socket_path: []const u8 = "",

    const Self = @This();

    fn update(self: *Self, line_iter: *SplitIterator(u8, .scalar)) !void {
        const new_self = try parse_type(Self, line_iter);
        self.* = new_self;
    }
};

pub const Config = struct {
    machine: MachineConfig = .{},
    kernel: KernelConfig = .{},
    uart: UartConfig = .{},
    drives: DrivesConfigs = .{},
    networks: NetConfigs = .{},
    pmems: PmemConfigs = .{},
    gdb: ?GdbConfig = null,
};

pub const ParseResult = struct {
    config: Config = .{},
    file_mem: []align(HOST_PAGE_SIZE) const u8 = undefined,

    const Self = @This();

    pub fn deinit(self: *const Self, comptime System: type) void {
        System.munmap(self.file_mem);
    }
};

pub fn parse_file(comptime System: type, config_path: []const u8) !ParseResult {
    const fd = try System.open(
        config_path,
        .{
            .ACCMODE = .RDONLY,
        },
        0,
    );
    defer System.close(fd);

    return parse_fd(System, fd);
}

pub fn parse_fd(comptime System: type, fd: nix.fd_t) !ParseResult {
    const statx = try System.statx(fd);
    const file_mem = try System.mmap(
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
    const type_fields = comptime @typeInfo(Config).@"struct".fields;
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
                    return error.UnknownTableType;
                }
            };
            inline for (type_fields) |field| {
                if (std.mem.eql(u8, field.name, filed_name)) {
                    const field_type = @typeInfo(field.type);
                    if (field_type == .optional) {
                        @field(config, field.name) = .{};
                        try @field(config, field.name).?.update(&line_iter);
                    } else {
                        try @field(config, field.name).update(&line_iter);
                    }
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
    const type_fields = comptime @typeInfo(T).@"struct".fields;
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
                return error.NoFieldName;
            }
        };
        const field_value = blk: {
            if (iter.next()) |value| {
                break :blk std.mem.trim(u8, value, " ");
            } else {
                return error.NoFieldValue;
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
                            return error.NoFieldValue;
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

fn dump_file(comptime System: type, config: Config, config_path: []const u8) void {
    const fd = nix.assert(@src(), System, "open", .{
        config_path,
        .{
            .CREAT = true,
            .ACCMODE = .WRONLY,
        },
        0,
    });
    defer System.close(fd);

    dump_fd(config, fd);
}

fn dump_fd(comptime System: type, config: Config, fd: nix.fd_t) void {
    const type_fields = comptime @typeInfo(Config).@"struct".fields;
    inline for (type_fields, 0..) |field, i| {
        const last = type_fields.len - 1 == i;
        if (@typeInfo(field.type) == .optional) {
            if (@field(config, field.name)) |v| {
                dump_section(System, field.name, v, fd, last);
            }
        } else {
            dump_section(System, field.name, @field(config, field.name), fd, last);
        }
    }
}

fn dump_section(
    comptime System: type,
    comptime name: []const u8,
    t: anytype,
    fd: nix.fd_t,
    comptime last: bool,
) void {
    const t_type = @TypeOf(t);
    switch (t_type) {
        DrivesConfigs, PmemConfigs, NetConfigs => {
            const type_fields = @typeInfo(t_type).@"struct".fields;
            const first_field = type_fields[0];
            const items = @field(t, first_field.name).slice();
            for (items) |item| {
                dump_type(System, name, item, fd);
                if (!last)
                    _ = nix.assert(@src(), System, "write", .{ fd, "\n" });
            }
        },
        else => {
            dump_type(System, name, t, fd);
            if (!last)
                _ = nix.assert(@src(), System, "write", .{ fd, "\n" });
        },
    }
}

fn dump_type(comptime System: type, comptime name: []const u8, t: anytype, fd: nix.fd_t) void {
    const type_fields = @typeInfo(@TypeOf(t)).@"struct".fields;

    const header = if (std.mem.endsWith(u8, name, "s"))
        std.fmt.comptimePrint("[[{s}]]\n", .{name})
    else
        std.fmt.comptimePrint("[{s}]\n", .{name});
    _ = nix.assert(@src(), System, "write", .{ fd, header });

    inline for (type_fields) |field| {
        switch (field.type) {
            ?[6]u8 => {
                if (@field(t, field.name)) |value| {
                    const field_start = std.fmt.comptimePrint("{s} = ", .{field.name});
                    _ = nix.assert(@src(), System, "write", .{ fd, field_start });

                    var buff: [24]u8 = undefined;
                    const v = std.fmt.bufPrint(
                        &buff,
                        "[{X:0>2}, {X:0>2}, {X:0>2}, {X:0>2}, {X:0>2}, {X:0>2}]",
                        .{ value[0], value[1], value[2], value[3], value[4], value[5] },
                    ) catch unreachable;
                    _ = nix.assert(@src(), System, "write", .{ fd, v });

                    _ = nix.assert(@src(), System, "write", .{ fd, "\n" });
                }
            },
            [:0]const u8, []const u8 => {
                if (@field(t, field.name).len != 0) {
                    const field_start = std.fmt.comptimePrint("{s} = \"", .{field.name});
                    _ = nix.assert(@src(), System, "write", .{ fd, field_start });
                    _ = nix.assert(@src(), System, "write", .{ fd, @field(t, field.name) });
                    _ = nix.assert(@src(), System, "write", .{ fd, "\"\n" });
                }
            },
            u32, bool => {
                const field_start = std.fmt.comptimePrint("{s} = ", .{field.name});
                _ = nix.assert(@src(), System, "write", .{ fd, field_start });

                var buff: [16]u8 = undefined;
                const v = std.fmt.bufPrint(&buff, "{}", .{@field(t, field.name)}) catch unreachable;
                _ = nix.assert(@src(), System, "write", .{ fd, v });

                _ = nix.assert(@src(), System, "write", .{ fd, "\n" });
            },
            else => unreachable,
        }
    }
}

test "dump_and_parse" {
    const config_toml =
        \\[machine]
        \\vcpus = 69
        \\memory_mb = 69
        \\
        \\[kernel]
        \\path = "kernel_path"
        \\
        \\[uart]
        \\enabled = false
        \\
        \\[[drives]]
        \\path = "drive_1_path"
        \\read_only = false
        \\io_uring = false
        \\pci = false
        \\rootfs = true
        \\
        \\[[drives]]
        \\path = "drive_2_path"
        \\read_only = true
        \\io_uring = true
        \\pci = false
        \\rootfs = false
        \\
        \\[[drives]]
        \\path = "drive_3_path"
        \\read_only = true
        \\io_uring = false
        \\pci = true
        \\rootfs = false
        \\
        \\[[networks]]
        \\dev_name = "net_1"
        \\vhost = true
        \\
        \\[[networks]]
        \\dev_name = "net_2"
        \\mac = [00, 02, DE, AD, BE, EF]
        \\vhost = false
        \\
        \\[gdb]
        \\socket_path = "gdb_sock"
        \\
    ;

    var drives: DrivesConfigs = .{};
    drives.drives.append(.{
        .path = "drive_1_path",
        .read_only = false,
        .io_uring = false,
        .pci = false,
        .rootfs = true,
    }) catch unreachable;
    drives.drives.append(.{
        .path = "drive_2_path",
        .read_only = true,
        .io_uring = true,
        .pci = false,
        .rootfs = false,
    }) catch unreachable;
    drives.drives.append(.{
        .path = "drive_3_path",
        .read_only = true,
        .io_uring = false,
        .pci = true,
        .rootfs = false,
    }) catch unreachable;

    var nets: NetConfigs = .{};
    nets.networks.append(.{
        .mac = null,
        .vhost = true,
        .dev_name = "net_1",
    }) catch unreachable;
    nets.networks.append(.{
        .mac = .{ 0x0, 0x2, 0xDE, 0xAD, 0xBE, 0xEF },
        .vhost = false,
        .dev_name = "net_2",
    }) catch unreachable;

    const config: Config = .{
        .machine = .{
            .vcpus = 69,
            .memory_mb = 69,
        },
        .kernel = .{
            .path = "kernel_path",
        },
        .uart = .{
            .enabled = false,
        },
        .drives = drives,
        .networks = nets,
        .gdb = .{
            .socket_path = "gdb_sock",
        },
    };

    const System = nix.System;

    const memfd = nix.assert(
        @src(),
        System,
        "memfd_create",
        .{ "test_config_parse", nix.FD_CLOEXEC },
    );
    dump_fd(System, config, memfd);

    const statx = try System.statx(memfd);
    const file_mem = try System.mmap(
        null,
        statx.size,
        nix.PROT.READ,
        .{
            .TYPE = .PRIVATE,
        },
        memfd,
        0,
    );

    try std.testing.expect(std.mem.eql(u8, file_mem, config_toml));

    const new_config = try parse_fd(System, memfd);

    try std.testing.expect(new_config.config.machine.vcpus == config.machine.vcpus);
    try std.testing.expect(new_config.config.machine.memory_mb == config.machine.memory_mb);

    try std.testing.expect(std.mem.eql(u8, new_config.config.kernel.path, config.kernel.path));

    try std.testing.expect(new_config.config.uart.enabled == config.uart.enabled);

    for (new_config.config.drives.drives.slice(), config.drives.drives.slice()) |nd, od| {
        try std.testing.expect(std.mem.eql(u8, nd.path, od.path));
        try std.testing.expect(nd.read_only == od.read_only);
    }

    for (new_config.config.networks.networks.slice(), config.networks.networks.slice()) |nn, on| {
        if (nn.mac) |nm| {
            const om = on.mac.?;
            try std.testing.expect(std.mem.eql(u8, &nm, &om));
        }
        try std.testing.expect(std.mem.eql(u8, nn.dev_name, on.dev_name));
        try std.testing.expect(nn.vhost == on.vhost);
    }

    try std.testing.expect(
        std.mem.eql(u8, new_config.config.gdb.?.socket_path, config.gdb.?.socket_path),
    );
}
