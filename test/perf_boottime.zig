const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");

pub const std_options = std.Options{
    .log_level = .info,
};

const Iterations = 10;
const ResultsPath = "perf_results/boottime";
const ConfigPaths = &.{ "test/boottime_config_drive.toml", "test/boottime_config_pmem.toml" };
const ConfigName = &.{ "drive", "pmem" };

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.arena.allocator();

    const timestamp = std.Io.Timestamp.now(io, .real);
    const results_path = try std.fmt.allocPrint(alloc, "{s}_{}", .{ ResultsPath, timestamp });

    try utils.vmtouch_files(io, ConfigPaths);
    defer utils.vmtouch_free(io);

    std.log.info("creating results directory", .{});
    try utils.Process.run(io, &.{ "mkdir", "-p", ResultsPath });

    {
        var system_cpu_usage = try utils.SystemCpuUsage.init(io, ResultsPath);
        defer system_cpu_usage.deinit(io);

        var process_resource_usage = try utils.ProcessResourceUsage.init(io, ResultsPath);
        defer process_resource_usage.deinit(io);

        var process_startup_time = try utils.ProcessStartupTime.init(io, ResultsPath);
        defer process_startup_time.deinit(io);

        var cpu_usage_thread_stop: bool = false;
        const cpu_usage_thread = try std.Thread.spawn(.{}, utils.system_cpu_usage_thread, .{
            io,
            alloc,
            &system_cpu_usage,
            std.time.ns_per_s,
            &cpu_usage_thread_stop,
        });

        inline for (ConfigPaths, ConfigName) |config_path, config_name| {
            for (0..Iterations) |i| {
                var radinace_process =
                    try utils.Process.start(io, "radiance", &utils.RadianceCmd(config_path));

                std.log.info("Waiting for radiance to boot", .{});
                std.Io.sleep(io, .fromNanoseconds(utils.RadianceBootTimeDelay), .real) catch unreachable;

                try utils.Process.run(io, &(utils.SshCmd ++ .{ "systemd-analyze", ">", "boottime.txt" }));

                const scp_result_file = ResultsPath ++ "/boottime.txt";
                const result_file = try std.fmt.allocPrint(
                    alloc,
                    "{s}/boottime_{s}_{d}.txt",
                    .{ ResultsPath, config_name, i },
                );
                defer alloc.free(result_file);

                try utils.Process.run(io, &utils.ScpCmd("boottime.txt", scp_result_file));
                try utils.Process.run(io, &.{ "mv", scp_result_file, result_file });

                try utils.Process.run(io, &(utils.SshCmd ++ .{"reboot"}));
                var output = try radinace_process.end(io, alloc);
                defer output.deinit(alloc);

                try process_resource_usage.update(io, &radinace_process, alloc);
                try process_startup_time.update(io, &output);
            }
        }

        cpu_usage_thread_stop = true;
        cpu_usage_thread.join();
    }

    std.log.info("moving results to {s}", .{results_path});
    try utils.Process.run(io, &.{ "mv", ResultsPath, results_path });
}
