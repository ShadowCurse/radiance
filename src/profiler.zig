const std = @import("std");
const log = @import("log.zig");
const arch = @import("arch.zig");
const builtin = @import("builtin");

pub var global_start: u64 = 0;
pub var global_freq: u64 = 0;
pub var global_last_thread_id: std.atomic.Value(u32) = .init(0);
pub threadlocal var current: ?*Measurement = null;
pub threadlocal var thread_id: u32 = 0;

pub const Options = struct {
    enabled: bool = false,
    num_threads: u32 = 8,
};

const root = @import("root");
pub const options: Options = if (@hasDecl(root, "profiler_options"))
    root.profiler_options
else
    .{};

pub const Measurement = struct {
    without_children: u64 = 0,
    with_children: u64 = 0,
    hit_count: u64 = 0,
};

pub fn start() void {
    global_freq = arch.get_perf_counter_frequency();
    global_start = arch.get_perf_counter();
}

pub fn thread_take_id() void {
    thread_id = global_last_thread_id.fetchAdd(1, .seq_cst);
}

pub fn Measurements(comptime FILE: []const u8, comptime NAMES: []const []const u8) type {
    return if (!options.enabled)
        struct {
            pub fn start(comptime _: std.builtin.SourceLocation) void {}
            pub fn start_named(comptime _: []const u8) void {}
            pub fn end(_: void) void {}
            pub fn print() void {}
        }
    else
        struct {
            // pub var measurements: [NAMES.len]Measurement = .{Measurement{}} ** NAMES.len;
            pub var measurements: [options.num_threads][NAMES.len]Measurement =
                .{.{Measurement{}} ** NAMES.len} ** options.num_threads;

            pub const Point = struct {
                start_time: u64,
                parent: ?*Measurement,
                current: *Measurement,
                current_with_children: u64,
            };

            pub fn start(comptime src: std.builtin.SourceLocation) Point {
                return start_named(src.fn_name);
            }

            pub fn start_named(comptime name: []const u8) Point {
                const index = comptime blk: {
                    var found: bool = false;
                    for (NAMES, 0..) |n, i| {
                        if (std.mem.eql(u8, n, name)) {
                            found = true;
                            break :blk i;
                        }
                    }
                    if (!found) log.comptime_err(
                        @src(),
                        "Cannot find profile point: {s} in the file: {s}",
                        .{ name, FILE },
                    );
                };
                const parent = current;
                current = &measurements[thread_id][index];
                return .{
                    .start_time = arch.get_perf_counter(),
                    .parent = parent,
                    .current = current.?,
                    .current_with_children = current.?.with_children,
                };
            }

            pub fn end(point: Point) void {
                const end_time = arch.get_perf_counter();
                const elapsed = end_time - point.start_time;
                point.current.hit_count += 1;
                point.current.without_children +%= elapsed;
                point.current.with_children = point.current_with_children + elapsed;
                if (point.parent) |parent| parent.without_children -%= elapsed;
                current = point.parent;
            }

            pub fn max_name_aligment() u64 {
                var longest: u64 = 0;
                for (NAMES) |n| longest = @max(longest, n.len);
                return longest + FILE.len;
            }

            pub fn print(comptime NAME_ALIGN: u64) void {
                const freq: f64 = @floatFromInt(global_freq);
                const global_end = arch.get_perf_counter();
                const global_elapsed: f64 = @floatFromInt(global_end - global_start);
                for (0..options.num_threads) |ti| {
                    inline for (NAMES, measurements[ti]) |name, m| {
                        if (m.hit_count != 0) {
                            const without_children_ms: f64 =
                                @as(f64, @floatFromInt(m.without_children)) / freq * 1000.0;
                            const without_children: f64 =
                                @as(f64, @floatFromInt(m.without_children)) / global_elapsed * 100.0;
                            const with_children_ms: f64 =
                                @as(f64, @floatFromInt(m.with_children)) / freq * 1000.0;
                            const with_children: f64 =
                                @as(f64, @floatFromInt(m.with_children)) / global_elapsed * 100.0;
                            const full_name = std.fmt.comptimePrint("{s}:{s}", .{ FILE, name });
                            log.info(
                                @src(),
                                "t: {d} | {s:<" ++
                                    std.fmt.comptimePrint("{d}", .{NAME_ALIGN + 1}) ++
                                    "} | hit: {d:>9} | exclusive: {d:>9} cycles {d:>9.6} ms {d:>9.6}% | inclusive: {d:>9} cycles {d:>9.6} ms {d:>9.6}%",
                                .{
                                    ti,
                                    full_name,
                                    m.hit_count,
                                    m.without_children,
                                    without_children_ms,
                                    without_children,
                                    m.with_children,
                                    with_children_ms,
                                    with_children,
                                },
                            );
                        }
                    }
                }
            }
        };
}

pub fn print(comptime types: []const type) void {
    @setEvalBranchQuota(20000);
    log.info(@src(), "Counter frequency: {d}", .{global_freq});

    if (options.enabled) {
        const longest_name_aligment = comptime blk: {
            var longest: u64 = 0;
            for (types) |t| longest = @max(longest, t.max_name_aligment());
            break :blk longest;
        };
        inline for (types) |t| t.print(longest_name_aligment);
    }

    const freq: f64 = @floatFromInt(global_freq);
    const global_end = arch.get_perf_counter();
    const global_elapsed: f64 = @floatFromInt(global_end - global_start);
    const global_time_ms = global_elapsed / freq * 1000.0;
    log.info(@src(), "Total {d:>6.6}ms", .{global_time_ms});
}
