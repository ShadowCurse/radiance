const std = @import("std");

pub fn assert(
    src: std.builtin.SourceLocation,
    ok: bool,
    comptime format: []const u8,
    args: anytype,
) void {
    if (!ok) {
        err(src, format, args);
        unreachable;
    }
}

pub fn info(
    src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    const T = make_struct(@TypeOf(args));
    const t = fill_struct(T, src, args);
    std.log.info("[{s}:{s}:{}:{}] " ++ format, t);
}

pub fn debug(
    src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    const T = make_struct(@TypeOf(args));
    const t = fill_struct(T, src, args);
    std.log.debug("[{s}:{s}:{}:{}] " ++ format, t);
}

pub fn warn(
    src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    const T = make_struct(@TypeOf(args));
    const t = fill_struct(T, src, args);
    std.log.warn("[{s}:{s}:{}:{}] " ++ format, t);
}

pub fn err(
    src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    const T = make_struct(@TypeOf(args));
    const t = fill_struct(T, src, args);
    std.log.err("[{s}:{s}:{}:{}] " ++ format, t);
}

fn fill_struct(
    comptime T: type,
    src: std.builtin.SourceLocation,
    args: anytype,
) T {
    const args_fields = comptime @typeInfo(@TypeOf(args)).Struct.fields;
    var t: T = undefined;

    @field(t, "0") = src.file;
    @field(t, "1") = src.fn_name;
    @field(t, "2") = src.line;
    @field(t, "3") = src.column;

    // need to inline so the loop would be unrolled
    // because these fields are assigned at runtime
    // but we need to generate indexes at comptime
    inline for (args_fields, 0..) |_, i| {
        const t_index = std.fmt.comptimePrint("{}", .{4 + i});
        const args_index = std.fmt.comptimePrint("{}", .{i});
        @field(t, t_index) = @field(args, args_index);
    }
    return t;
}

fn make_struct(
    comptime T: type,
) type {
    const type_fields = comptime @typeInfo(T).Struct.fields;
    var fields: [type_fields.len + 4]std.builtin.Type.StructField = undefined;
    // file
    fields[0] = .{
        .name = "0",
        .type = [:0]const u8,
        .default_value = null,
        .is_comptime = false,
        .alignment = @alignOf([:0]const u8),
    };
    // fn_name
    fields[1] = .{
        .name = "1",
        .type = [:0]const u8,
        .default_value = null,
        .is_comptime = false,
        .alignment = @alignOf([:0]const u8),
    };
    // line
    fields[2] = .{
        .name = "2",
        .type = u32,
        .default_value = null,
        .is_comptime = false,
        .alignment = @alignOf(u32),
    };
    // column
    fields[3] = .{
        .name = "3",
        .type = u32,
        .default_value = null,
        .is_comptime = false,
        .alignment = @alignOf(u32),
    };
    for (type_fields, 4..) |f, i| {
        var ff = f;
        ff.name = std.fmt.comptimePrint("{}", .{i});
        ff.is_comptime = false;
        ff.default_value = null;
        fields[i] = ff;
    }

    return @Type(.{
        .Struct = .{
            .layout = .auto,
            .fields = fields[0..],
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = true,
        },
    });
}
