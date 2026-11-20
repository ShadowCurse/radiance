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

    const type_info = @typeInfo(T).@"struct";
    var t: T = .{};
    // Track which args were consumed, including the 0th arg.
    var consumed_args: u64 = 0;
    inline for (type_info.field_names, type_info.field_types) |field_name, field_type| {
        if (find_arg(args, field_name, field_type)) |r| {
            const i, const arg = r;
            const field_type_info = @typeInfo(field_type);
            switch (field_type_info) {
                .optional => |optional| try handle_arg(T, &t, optional.child, field_name, &consumed_args, i, arg),
                else => try handle_arg(T, &t, field_type, field_name, &consumed_args, i, arg),
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
                    inline for (@"enum".field_names, @"enum".field_values) |name, value| {
                        if (std.mem.eql(u8, arg, name)) {
                            consumed_args.* |= @as(u64, 1) << @truncate(i);
                            consumed_args.* |= @as(u64, 1) << @truncate(i + 1);
                            @field(t, field_name) = @fromBackingInt(@intCast(value));
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

fn find_arg(
    args: std.process.Args,
    comptime field_name: [:0]const u8,
    comptime field_type: type,
) ?struct { u32, [:0]const u8 } {
    const name = std.fmt.comptimePrint("--{s}", .{field_name});
    var arg_name: [name.len]u8 = undefined;
    _ = std.mem.replace(u8, name, "_", "-", &arg_name);

    var args_iter = args.iterate();
    // skip the binary name
    _ = args_iter.next();
    var i: u32 = 1;
    while (args_iter.next()) |arg| : (i += 1) {
        if (std.mem.eql(u8, arg, &arg_name)) {
            return switch (field_type) {
                void, bool => .{ i, field_name },
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
    log.output("Usage:\n", .{});
    inline for (comptime @typeInfo(T).@"struct".field_names) |field_name| {
        const arg_name = field_name_to_arg_name(field_name);
        log.output("\t--{s}\n", .{&arg_name});
    }
}

pub fn print_args(args: anytype) void {
    const type_info = comptime @typeInfo(@TypeOf(args)).@"struct";
    inline for (type_info.field_names, type_info.field_types) |field_name, field_type| {
        const arg_name = field_name_to_arg_name(field_name);
        switch (field_type) {
            void => {
                log.output("\t{s}\n", .{&arg_name});
            },
            bool => {
                log.output("\t{s}: {}\n", .{ &arg_name, @field(args, field_name) });
            },
            ?i32 => {
                log.output("\t{s}: {?}\n", .{ &arg_name, @field(args, field_name) });
            },
            ?u32 => {
                log.output("\t{s}: {?}\n", .{ &arg_name, @field(args, field_name) });
            },
            ?[]const u8 => {
                log.output("\t{s}: {?s}\n", .{ &arg_name, @field(args, field_name) });
            },
            else => unreachable,
        }
    }
}
