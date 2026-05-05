const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");

pub const std_options = std.Options{
    .log_level = .info,
};

const Iterations = 10;
const ResultsPath = "perf_results/iperf";
const ConfigPath = "test/iperf_config.toml";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.arena.allocator();

    const timestamp = std.Io.Timestamp.now(io, .real);
    const results_path = try std.fmt.allocPrint(alloc, "{s}_{}", .{ ResultsPath, timestamp });
    defer alloc.free(results_path);

    try utils.vmtouch_files(io, &.{ConfigPath});
    defer utils.vmtouch_free(io);

    std.log.info("creating results directory", .{});
    try utils.Process.run(io, &.{ "mkdir", "-p", ResultsPath });

    {
        var system_cpu_usage = try utils.SystemCpuUsage.init(io, ResultsPath);
        defer system_cpu_usage.deinit(io);

        var process_resource_usage = try utils.ProcessResourceUsage.init(io, ResultsPath);
        defer process_resource_usage.deinit(io);

        var cpu_usage_thread_stop: bool = false;
        const cpu_usage_thread = try std.Thread.spawn(.{}, utils.system_cpu_usage_thread, .{
            io,
            alloc,
            &system_cpu_usage,
            std.time.ns_per_s,
            &cpu_usage_thread_stop,
        });

        for (0..Iterations) |i| {
            const modes = [_]struct { []const u8, []const u8 }{
                .{ "", "h2g" },
                .{ "-R", "g2h" },
            };
            inline for (modes) |mode| {
                std.log.info("Starting iperf on the host", .{});
                try utils.Process.run(io, &.{ "iperf3", "-s", "-D", "-1" });

                var radinace_process = try utils.Process.start(
                    io,
                    "radiance",
                    &utils.RadianceCmd(ConfigPath),
                );

                std.log.info("Waiting for radiance to boot", .{});
                std.Io.sleep(io, .fromNanoseconds(utils.RadianceBootTimeDelay), .real) catch unreachable;

                const iperf_cmd = utils.IperfCmd(mode[0]);
                try utils.Process.run(io, &(utils.SshCmd ++ iperf_cmd));

                const scp_result_file = ResultsPath ++ "/iperf_" ++ mode[1] ++ ".json";
                const result_file = try std.fmt.allocPrint(alloc, "{s}/iperf_{s}_{}.json", .{ ResultsPath, mode[1], i });
                defer alloc.free(result_file);

                try utils.Process.run(io, &utils.ScpCmd(utils.IperfResult, scp_result_file));
                try utils.Process.run(io, &.{ "mv", scp_result_file, result_file });

                try utils.Process.run(io, &(utils.SshCmd ++ .{"reboot"}));
                var output = try radinace_process.end(io, alloc);
                defer output.deinit(alloc);

                try process_resource_usage.update(io, &radinace_process, alloc);
            }
        }

        cpu_usage_thread_stop = true;
        cpu_usage_thread.join();
    }

    std.log.info("moving results to {s}", .{results_path});
    try utils.Process.run(io, &.{ "mv", ResultsPath, results_path });
}
