const std = @import("std");

pub const ParseError = error{
    NotEnoughArgs,
};

pub fn parse(comptime T: type) !T {
    const type_fields = comptime @typeInfo(T).@"struct".fields;

    var t: T = undefined;
    inline for (type_fields) |field| {
        if (find_arg(field.name)) |arg| {
            switch (field.type) {
                []const u8 => {
                    @field(t, field.name) = arg;
                },
                u32 => {
                    @field(t, field.name) = try std.fmt.parseInt(u32, arg, 10);
                },
                else => unreachable,
            }
        } else {
            try print_args_help(T);
            return ParseError.NotEnoughArgs;
        }
    }
    return t;
}

fn find_arg(comptime field_name: []const u8) ?[]const u8 {
    const arg_name = std.fmt.comptimePrint("--{s}", .{field_name});
    var args_iter = std.process.args();

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, arg_name)) {
            return args_iter.next();
        }
    }
    return null;
}

fn print_args_help(comptime T: type) !void {
    const type_fields = comptime @typeInfo(T).@"struct".fields;

    const stdout = std.io.getStdOut();
    const writer = stdout.writer();
    try writer.print("Usage:\n", .{});

    inline for (type_fields) |field| {
        try writer.print("\t--{s}: type {any}\n", .{ field.name, field.type });
    }
}
