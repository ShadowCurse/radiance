const std = @import("std");

pub fn comptime_err(
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    comptime args: anytype,
) void {
    const header = std.fmt.comptimePrint("[{s}:{}]", .{ src.file, src.line });
    const T = make_struct(@TypeOf(args));
    const t = fill_struct(T, header, args);
    @compileError(std.fmt.comptimePrint("{s} " ++ format, t));
}

pub fn assert(
    comptime src: std.builtin.SourceLocation,
    ok: bool,
    comptime format: []const u8,
    args: anytype,
) void {
    if (!ok) {
        @branchHint(.cold);
        const header = std.fmt.comptimePrint("[{s}:{}]", .{ src.file, src.line });
        const T = make_struct(@TypeOf(args));
        const t = fill_struct(T, header, args);
        std.debug.panic("{s} " ++ format, t);
    }
}

pub fn info(
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    const header = std.fmt.comptimePrint("[{s}:{}]", .{ src.file, src.line });
    const T = make_struct(@TypeOf(args));
    const t = fill_struct(T, header, args);
    std.log.info("{s} " ++ format, t);
}

pub fn debug(
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    const header = std.fmt.comptimePrint("[{s}:{}]", .{ src.file, src.line });
    const T = make_struct(@TypeOf(args));
    const t = fill_struct(T, header, args);
    std.log.debug("{s} " ++ format, t);
}

pub fn warn(
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    const header = std.fmt.comptimePrint("[{s}:{}]", .{ src.file, src.line });
    const T = make_struct(@TypeOf(args));
    const t = fill_struct(T, header, args);
    std.log.warn("{s} " ++ format, t);
}

pub fn err(
    comptime src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    const header = std.fmt.comptimePrint("[{s}:{}]", .{ src.file, src.line });
    const T = make_struct(@TypeOf(args));
    const t = fill_struct(T, header, args);
    std.log.err("{s} " ++ format, t);
}

fn fill_struct(comptime T: type, comptime header: [:0]const u8, args: anytype) T {
    const args_fields = comptime @typeInfo(@TypeOf(args)).@"struct".fields;
    var t: T = undefined;

    @field(t, "0") = header;

    // need to inline so the loop would be unrolled
    // because these fields are assigned at runtime
    // but we need to generate indexes at comptime
    inline for (args_fields, 0..) |_, i| {
        const t_index = std.fmt.comptimePrint("{}", .{1 + i});
        const args_index = std.fmt.comptimePrint("{}", .{i});
        @field(t, t_index) = @field(args, args_index);
    }
    return t;
}

fn make_struct(comptime T: type) type {
    const type_fields = comptime @typeInfo(T).@"struct".fields;
    var fields: [type_fields.len + 1]std.builtin.Type.StructField = undefined;
    // header
    fields[0] = .{
        .name = "0",
        .type = [:0]const u8,
        .default_value_ptr = null,
        .is_comptime = false,
        .alignment = @alignOf([:0]const u8),
    };
    for (type_fields, 1..) |f, i| {
        var ff = f;
        ff.name = std.fmt.comptimePrint("{}", .{i});
        ff.is_comptime = false;
        ff.default_value_ptr = null;
        fields[i] = ff;
    }

    return @Type(.{
        .@"struct" = .{
            .layout = .auto,
            .fields = fields[0..],
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = true,
        },
    });
}
