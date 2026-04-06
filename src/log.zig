const std = @import("std");
const profiler = @import("profiler.zig");

const DEFAULT_COLOR = "\x1b[0m";
const WHITE = "\x1b[37m";
const HIGH_WHITE = "\x1b[90m";
const YELLOW = "\x1b[33m";
const RED = "\x1b[31m";

pub const LogLevel = enum {
    err,
    warn,
    info,
    debug,
};
pub const Options = struct {
    colors: bool = true,
    level: LogLevel = .info,
    asserts: bool = true,
    buffer_size: u32 = 256,

    const Self = @This();
    pub fn log_enabled(self: Self, level: LogLevel) bool {
        const self_level_int = @intFromEnum(self.level);
        const level_int = @intFromEnum(level);
        return level_int <= self_level_int;
    }
};

const root = @import("root");
pub const options: Options = if (@hasDecl(root, "log_options"))
    root.log_options
else
    .{};

pub var output_fd: i32 = std.posix.STDERR_FILENO;
var output_mutex: std.Thread.Mutex.Recursive = .init;
var buffer: [options.buffer_size]u8 = undefined;

pub fn comptime_err(
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    comptime args: anytype,
) noreturn {
    const T = make_struct_comptime(src, @TypeOf(args));
    const t = fill_struct_comptime(T, args);
    if (comptime options.colors)
        @compileError(std.fmt.comptimePrint(
            RED ++ "[{s}:{}:COMPILE][{d}] " ++ format ++ DEFAULT_COLOR,
            t,
        ))
    else
        @compileError(std.fmt.comptimePrint("[{s}:{}:COMPILE][{d}] " ++ format, t));
}

pub fn comptime_assert(
    comptime src: std.builtin.SourceLocation,
    comptime ok: bool,
    comptime format: []const u8,
    comptime args: anytype,
) void {
    if (comptime !options.asserts) return;
    if (!ok) comptime_err(src, format, args);
}

pub fn panic(
    src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) noreturn {
    const T = make_struct(@TypeOf(args));
    const t = fill_struct(T, src.file, src.line, args);
    if (comptime options.colors)
        std.debug.panic(RED ++ "[{s}:{}:PANIC][{d}] " ++ format ++ DEFAULT_COLOR, t)
    else
        std.debug.panic("[{s}:{}:PANIC][{d}] " ++ format, t);
}

pub fn assert(
    src: std.builtin.SourceLocation,
    ok: bool,
    comptime format: []const u8,
    args: anytype,
) void {
    if (comptime !options.asserts) return;

    if (!ok) {
        @branchHint(.cold);
        const T = make_struct(@TypeOf(args));
        const t = fill_struct(T, src.file, src.line, args);
        if (comptime options.colors)
            std.debug.panic(RED ++ "[{s}:{}:ASSERT][{d}] " ++ format ++ DEFAULT_COLOR, t)
        else
            std.debug.panic("[{s}:{}:ASSERT][{d}] " ++ format, t);
    }
}

pub fn info(
    src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    if (comptime !options.log_enabled(.info)) return;

    const T = make_struct(@TypeOf(args));
    const t = fill_struct(T, src.file, src.line, args);
    if (comptime options.colors)
        output(WHITE ++ "[{s}:{}:INFO][{d}] " ++ format ++ DEFAULT_COLOR ++ "\n", t)
    else
        output("[{s}:{}:INFO][{d}] " ++ format ++ "\n", t);
}

pub fn debug(
    src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    if (comptime !options.log_enabled(.debug)) return;

    const T = make_struct(@TypeOf(args));
    const t = fill_struct(T, src.file, src.line, args);
    if (comptime options.colors)
        output(HIGH_WHITE ++ "[{s}:{}:DEBUG][{d}] " ++ format ++ DEFAULT_COLOR ++ "\n", t)
    else
        output("[{s}:{}:DEBUG][{d}] " ++ format ++ "\n", t);
}

pub fn warn(
    src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    if (comptime !options.log_enabled(.warn)) return;

    const T = make_struct(@TypeOf(args));
    const t = fill_struct(T, src.file, src.line, args);
    if (comptime options.colors)
        output(YELLOW ++ "[{s}:{}:WARN][{d}] " ++ format ++ DEFAULT_COLOR ++ "\n", t)
    else
        output("[{s}:{}:WARN][{d}] " ++ format ++ "\n", t);
}

pub fn err(
    src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    if (comptime !options.log_enabled(.err)) return;

    const T = make_struct(@TypeOf(args));
    const t = fill_struct(T, src.file, src.line, args);
    if (comptime options.colors)
        output(RED ++ "[{s}:{}:ERROR][{d}] " ++ format ++ DEFAULT_COLOR ++ "\n", t)
    else
        output("[{s}:{}:ERROR][{d}] " ++ format ++ "\n", t);
}

pub fn output(comptime format: []const u8, args: anytype) void {
    var output_writer: std.fs.File.Writer = .{
        .interface = std.fs.File.Writer.initInterface(&.{}),
        .file = .{
            .handle = output_fd,
        },
        .mode = .streaming,
    };
    const writer = &output_writer.interface;

    nosuspend {
        output_mutex.lock();
        defer output_mutex.unlock();

        writer.print(format, args) catch return;
        writer.flush() catch return;
    }
}

fn fill_struct_comptime(comptime T: type, args: anytype) T {
    const args_fields = comptime @typeInfo(@TypeOf(args)).@"struct".fields;
    var t: T = undefined;

    @field(t, "2") = 0;//profiler.thread_id orelse 0;
    inline for (args_fields, 0..) |_, i| {
        const t_index = std.fmt.comptimePrint("{}", .{3 + i});
        const args_index = std.fmt.comptimePrint("{}", .{i});
        @field(t, t_index) = @field(args, args_index);
    }
    return t;
}

fn make_struct_comptime(comptime src: std.builtin.SourceLocation, comptime T: type) type {
    const type_fields = comptime @typeInfo(T).@"struct".fields;
    var fields: [type_fields.len + 3]std.builtin.Type.StructField = undefined;
    // file
    fields[0] = .{
        .name = "0",
        .type = @TypeOf(src.file),
        .default_value_ptr = @ptrCast(&src.file),
        .is_comptime = true,
        .alignment = @alignOf(@TypeOf(src.file)),
    };
    // line
    fields[1] = .{
        .name = "1",
        .type = @TypeOf(src.line),
        .default_value_ptr = @ptrCast(&src.line),
        .is_comptime = true,
        .alignment = @alignOf(@TypeOf(src.line)),
    };
    fields[2] = .{
        .name = "2",
        .type = u32,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = @alignOf(u32),
    };
    for (type_fields, 3..) |f, i| {
        var ff = f;
        ff.name = std.fmt.comptimePrint("{}", .{i});
        ff.is_comptime = false;
        ff.default_value_ptr = null;
        fields[i] = ff;
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = true,
        },
    });
}

fn fill_struct(comptime T: type, file: [:0]const u8, line: u32, args: anytype) T {
    @setEvalBranchQuota(5000);

    const args_fields = comptime @typeInfo(@TypeOf(args)).@"struct".fields;
    var t: T = undefined;

    @field(t, "0") = file;
    @field(t, "1") = line;
    @field(t, "2") = profiler.thread_id orelse 0;

    inline for (args_fields, 0..) |_, i| {
        const t_index = std.fmt.comptimePrint("{}", .{3 + i});
        const args_index = std.fmt.comptimePrint("{}", .{i});
        @field(t, t_index) = @field(args, args_index);
    }
    return t;
}

fn make_struct(comptime T: type) type {
    const type_fields = comptime @typeInfo(T).@"struct".fields;
    var fields: [type_fields.len + 3]std.builtin.Type.StructField = undefined;
    // file
    fields[0] = .{
        .name = "0",
        .type = [:0]const u8,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = @alignOf([:0]const u8),
    };
    // line
    fields[1] = .{
        .name = "1",
        .type = u32,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = @alignOf(u32),
    };
    fields[2] = .{
        .name = "2",
        .type = u32,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = @alignOf(u32),
    };
    for (type_fields, 3..) |f, i| {
        var ff = f;
        ff.name = std.fmt.comptimePrint("{}", .{i});
        ff.is_comptime = false;
        ff.default_value_ptr = null;
        fields[i] = ff;
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = &fields,
            .decls = &.{},
            .is_tuple = true,
        },
    });
}
