const std = @import("std");

pub fn info(
    src: std.builtin.SourceLocation,
    comptime format: []const u8,
    args: anytype,
) void {
    const T = make_struct(@typeInfo(@TypeOf(args)).Struct.fields);

    var t = T{
        .file = "lol", //src.file,
        .line = 1, // src.line,
        .column = 2, //src.column,
        .fn_name = "fnlol", //src.fn_name,
    };
    t.file = src.file;
    std.log.info("[{s}:{}:{}] {s}: " ++ format, t); //.{ src.file, src.line, src.column, src.fn_name, args });
}

fn make_struct(comptime input_fields: []const std.builtin.Type.StructField) type {
    var fields: [input_fields.len + 4]std.builtin.Type.StructField = undefined;
    fields[0] = .{
        .name = "file",
        .type = [:0]const u8,
        .default_value = null,
        .is_comptime = false,
        .alignment = @alignOf([:0]const u8),
    };
    fields[1] = .{
        .name = "line",
        .type = u32,
        .default_value = null,
        .is_comptime = false,
        .alignment = @alignOf(u32),
    };
    fields[2] = .{
        .name = "column",
        .type = u32,
        .default_value = null,
        .is_comptime = false,
        .alignment = @alignOf(u32),
    };
    fields[3] = .{
        .name = "fn_name",
        .type = [:0]const u8,
        .default_value = null,
        .is_comptime = false,
        .alignment = @alignOf([:0]const u8),
    };
    for (input_fields, 4..) |f, i| {
        fields[i] = f;
    }

    return @Type(.{
        .Struct = .{
            .layout = .Auto,
            .fields = fields[0..],
            .decls = &[_]std.builtin.Type.Declaration{},
            .is_tuple = false,
        },
    });
}

// pub fn with_src(
//     comptime format: []const u8,
//     args: anytype,
// ) void {
//     const f = "[{s} | {}:{}] {s}:" ++ format;
//     const args_type = @typeInfo(args);
//     const args_fields = args_type.Struct.fields;
//     _ = args_fields;
//
//     const builtin = std.builtin;
//     const WithSrc = @Type(.{
//         .Struct = .{
//             .layout = .Auto,
//             .fields = &.{ .name = "file", .field_type = []const u8, .default_value = null, .is_comptime = false, .aligment = 0 } ++ args_type.Struct.fields,
//             .decls = &[_]builtin.TypeInfo.Declaration{},
//             .is_tuple = false,
//         },
//     });
//     _ = WithSrc;
//
//     std.log.info(f, .{});
// }

// pub fn info(
//     comptime format: []const u8,
//     args: anytype,
// ) void {
//     const src = @src();
//     _ = src;
//     std.log.info(format, args);
// }
