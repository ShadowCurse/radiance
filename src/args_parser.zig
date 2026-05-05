// Copyright (c) 2026 Egor Lazarchuk
// SPDX-License-Identifier: MIT

const std = @import("std");
const log = @import("log.zig");
const profiler = @import("profiler.zig");
const Allocator = std.mem.Allocator;

pub const MEASUREMENTS = profiler.Measurements("args_parser", &.{
    "parse",
});

pub fn parse(args: std.process.Args, comptime T: type) !T {
    const prof_point = MEASUREMENTS.start_named("parse");
    defer MEASUREMENTS.end(prof_point);

    const type_fields = @typeInfo(T).@"struct".fields;
    var t: T = .{};
    // Track which args were consumed, including the 0th arg.
    var consumed_args: u64 = 0;
    inline for (type_fields) |field| {
        if (find_arg(args, field)) |r| {
            const i, const arg = r;
            const field_type_info = @typeInfo(field.type);
            switch (field_type_info) {
                .optional => |optional| try handle_arg(T, &t, optional.child, field.name, &consumed_args, i, arg),
                else => try handle_arg(T, &t, field.type, field.name, &consumed_args, i, arg),
            }
        }
    }
    return t;
}

fn handle_arg(
    comptime T: type,
    t: *T,
    comptime field_type: type,
    comptime field_name: []const u8,
    consumed_args: *u64,
    i: u32,
    arg: [:0]const u8,
) !void {
    switch (field_type) {
        void => {
            consumed_args.* |= @as(u64, 1) << @truncate(i);
        },
        bool => {
            consumed_args.* |= @as(u64, 1) << @truncate(i);
            @field(t, field_name) = true;
        },
        i32, u32, u64 => {
            consumed_args.* |= @as(u64, 1) << @truncate(i);
            consumed_args.* |= @as(u64, 1) << @truncate(i + 1);
            if (std.mem.startsWith(u8, arg, "0x"))
                @field(t, field_name) = try std.fmt.parseInt(field_type, arg[2..], 16)
            else
                @field(t, field_name) = try std.fmt.parseInt(field_type, arg, 10);
        },
        []const u8, [:0]const u8 => {
            consumed_args.* |= @as(u64, 1) << @truncate(i);
            consumed_args.* |= @as(u64, 1) << @truncate(i + 1);
            @field(t, field_name) = arg;
        },
        else => {
            const field_type_info = @typeInfo(field_type);
            switch (field_type_info) {
                .@"enum" => |@"enum"| {
                    inline for (@"enum".fields) |f| {
                        if (std.mem.eql(u8, arg, f.name)) {
                            consumed_args.* |= @as(u64, 1) << @truncate(i);
                            consumed_args.* |= @as(u64, 1) << @truncate(i + 1);
                            @field(t, field_name) = @enumFromInt(f.value);
                            break;
                        }
                    }
                    const original_type = @typeInfo(@TypeOf(@field(t, field_name)));
                    if (original_type == .optional and @field(t, field_name) == null) {
                        log.err(@src(), "Argument --{s} invalid value of {s}", .{ field_name_to_arg_name(field_name), arg });
                        return error.InvalidEnum;
                    }
                },
                else => unreachable,
            }
        },
    }
}

fn find_arg(args: std.process.Args, comptime field: std.builtin.Type.StructField) ?struct { u32, [:0]const u8 } {
    const name = std.fmt.comptimePrint("--{s}", .{field.name});
    var arg_name: [name.len]u8 = undefined;
    _ = std.mem.replace(u8, name, "_", "-", &arg_name);

    var args_iter = args.iterate();
    // skip the binary name
    _ = args_iter.next();
    var i: u32 = 1;
    while (args_iter.next()) |arg| : (i += 1) {
        if (std.mem.eql(u8, arg, &arg_name)) {
            return switch (field.type) {
                void, bool => .{ i, field.name },
                else => if (args_iter.next()) |next| .{ i, next } else null,
            };
        }
    }
    return null;
}

fn field_name_to_arg_name(comptime field_name: []const u8) [field_name.len]u8 {
    var arg_name: [field_name.len]u8 = undefined;
    _ = std.mem.replace(u8, field_name, "_", "-", &arg_name);
    return arg_name;
}

pub fn print_help(comptime T: type) void {
    const type_fields = comptime @typeInfo(T).@"struct".fields;

    log.output("Usage:\n", .{});
    inline for (type_fields) |field| {
        const arg_name = field_name_to_arg_name(field.name);
        log.output("\t--{s}\n", .{&arg_name});
    }
}

pub fn print_args(args: anytype) void {
    const type_fields = comptime @typeInfo(@TypeOf(args)).@"struct".fields;
    inline for (type_fields) |field| {
        const arg_name = field_name_to_arg_name(field.name);
        switch (field.type) {
            void => {
                log.output("\t{s}\n", .{&arg_name});
            },
            bool => {
                log.output("\t{s}: {}\n", .{ &arg_name, @field(args, field.name) });
            },
            ?i32 => {
                log.output("\t{s}: {?}\n", .{ &arg_name, @field(args, field.name) });
            },
            ?u32 => {
                log.output("\t{s}: {?}\n", .{ &arg_name, @field(args, field.name) });
            },
            ?[]const u8 => {
                log.output("\t{s}: {?s}\n", .{ &arg_name, @field(args, field.name) });
            },
            else => unreachable,
        }
    }
}
