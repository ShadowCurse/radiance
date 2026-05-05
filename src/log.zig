const std = @import("std");
const profiler = @import("profiler.zig");
const Mutex = @import("mutex.zig");

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
var output_mutex: Mutex = .init;
var output_buffer: [options.buffer_size]u8 = undefined;

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

const Output = struct {
    fd: std.os.linux.fd_t,
    writer: std.Io.Writer,

    pub fn init(fd: std.os.linux.fd_t, buffer: []u8) Output {
        return .{ .fd = fd, .writer = .{ .vtable = &.{ .drain = drain }, .buffer = buffer } };
    }

    pub fn drain(io_w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const o: *Output = @alignCast(@fieldParentPtr("writer", io_w));
        _ = splat;

        var iovecs: [16]std.posix.iovec_const = undefined;
        iovecs[0] = .{ .base = io_w.buffer.ptr, .len = io_w.end };
        defer io_w.end = 0;

        const n_data_iovecs = @min(iovecs.len - 1, data.len - 1);
        var n_data_bytes: usize = 0;
        for (iovecs[1..][0..n_data_iovecs], data[0..n_data_iovecs]) |*iov, d| {
            iov.* = .{ .base = d.ptr, .len = d.len };
            n_data_bytes += d.len;
        }
        assert(
            @src(),
            n_data_iovecs == data.len - 1,
            "Number of `data` segments is {d}, which is bigger than `iovecs` buffer of 16",
            .{data.len - 1},
        );

        while (true) {
            const r = std.os.linux.writev(o.fd, &iovecs, @intCast(1 + n_data_iovecs));
            switch (std.posix.errno(r)) {
                .SUCCESS => return n_data_bytes,
                .INTR => continue,
                else => return error.WriteFailed,
            }
        }
    }
};

pub fn output(comptime format: []const u8, args: anytype) void {
    var out: Output = .init(output_fd, &output_buffer);
    nosuspend {
        output_mutex.lock();
        defer output_mutex.unlock();

        out.writer.print(format, args) catch return;
        out.writer.flush() catch return;
    }
}

fn fill_struct_comptime(comptime T: type, args: anytype) T {
    const args_fields = comptime @typeInfo(@TypeOf(args)).@"struct".fields;
    var t: T = undefined;

    inline for (args_fields, 0..) |_, i| {
        const t_index = std.fmt.comptimePrint("{}", .{2 + i});
        const args_index = std.fmt.comptimePrint("{}", .{i});
        @field(t, t_index) = @field(args, args_index);
    }
    return t;
}

fn make_struct_comptime(comptime src: std.builtin.SourceLocation, comptime T: type) type {
    const type_fields = comptime @typeInfo(T).@"struct".fields;
    // var fields: [type_fields.len + 2]std.builtin.Type.StructField = undefined;

    var field_names: [type_fields.len + 2][]const u8 = undefined;
    var field_types: [type_fields.len + 2]type = undefined;
    var field_attrs: [type_fields.len + 2]std.builtin.Type.StructField.Attributes = undefined;

    // file
    field_names[0] = "0";
    field_types[0] = @TypeOf(src.file);
    field_attrs[0] = .{
        .@"comptime" = true,
        .@"align" = @alignOf(@TypeOf(src.file)),
        .default_value_ptr = @ptrCast(&src.file),
    };
    // line
    field_names[1] = "1";
    field_types[1] = @TypeOf(src.line);
    field_attrs[1] = .{
        .@"comptime" = true,
        .@"align" = @alignOf(@TypeOf(src.line)),
        .default_value_ptr = @ptrCast(&src.line),
    };
    for (type_fields, 2..) |f, i| {
        field_names[i] = std.fmt.comptimePrint("{d}", .{i});
        field_types[i] = f.type;
        field_attrs[i] = .{
            .@"comptime" = f.is_comptime,
            .@"align" = f.alignment,
            .default_value_ptr = f.default_value_ptr,
        };
    }

    return @Struct(
        .auto,
        null,
        &field_names,
        &field_types,
        &field_attrs,
    );
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
    var field_names: [type_fields.len + 3][]const u8 = undefined;
    var field_types: [type_fields.len + 3]type = undefined;
    var field_attrs: [type_fields.len + 3]std.builtin.Type.StructField.Attributes = undefined;
    // file
    field_names[0] = "0";
    field_types[0] = [:0]const u8;
    field_attrs[0] = .{
        .@"comptime" = false,
        .@"align" = @alignOf([:0]const u8),
        .default_value_ptr = null,
    };
    // line
    field_names[1] = "1";
    field_types[1] = u32;
    field_attrs[1] = .{
        .@"comptime" = false,
        .@"align" = @alignOf(u32),
        .default_value_ptr = null,
    };
    field_names[2] = "2";
    field_types[2] = u32;
    field_attrs[2] = .{
        .@"comptime" = false,
        .@"align" = @alignOf(u32),
        .default_value_ptr = null,
    };
    for (type_fields, 3..) |f, i| {
        field_names[i] = std.fmt.comptimePrint("{d}", .{i});
        field_types[i] = f.type;
        field_attrs[i] = .{
            .@"comptime" = f.is_comptime,
            .@"align" = f.alignment,
            .default_value_ptr = f.default_value_ptr,
        };
    }

    return @Struct(
        .auto,
        null,
        &field_names,
        &field_types,
        &field_attrs,
    );
}
