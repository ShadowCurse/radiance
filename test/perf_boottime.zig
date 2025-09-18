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

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const timestamp = std.time.timestamp();
    const results_path = try std.fmt.allocPrint(alloc, "{s}_{}", .{ ResultsPath, timestamp });
    defer alloc.free(results_path);

    try utils.vmtouch_files(alloc, ConfigPaths);
    defer utils.vmtouch_free(alloc);

    std.log.info("creating results directory", .{});
    try utils.Process.run(&.{ "mkdir", "-p", ResultsPath }, alloc);

    {
        var system_cpu_usage = try utils.SystemCpuUsage.init(ResultsPath);
        defer system_cpu_usage.deinit();

        var process_resource_usage = try utils.ProcessResourceUsage.init(ResultsPath);
        defer process_resource_usage.deinit();

        var process_startup_time = try utils.ProcessStartupTime.init(ResultsPath);
        defer process_startup_time.deinit();

        var cpu_usage_thread_stop: bool = false;
        const cpu_usage_thread = try std.Thread.spawn(.{}, utils.system_cpu_usage_thread, .{
            &system_cpu_usage,
            alloc,
            std.time.ns_per_s,
            &cpu_usage_thread_stop,
        });

        inline for (ConfigPaths, ConfigName) |config_path, config_name| {
            for (0..Iterations) |i| {
                var radinace_process =
                    try utils.Process.start("radiance", &utils.RadianceCmd(config_path), alloc);

                std.log.info("Waiting for radiance to boot", .{});
                std.Thread.sleep(utils.RadianceBootTimeDelay);

                try utils.Process.run(
                    &(utils.SshCmd ++ .{ "systemd-analyze", ">", "boottime.txt" }),
                    alloc,
                );

                const scp_result_file = ResultsPath ++ "/boottime.txt";
                const result_file = try std.fmt.allocPrint(
                    alloc,
                    "{s}/boottime_{s}_{d}.txt",
                    .{ ResultsPath, config_name, i },
                );
                defer alloc.free(result_file);

                try utils.Process.run(&utils.ScpCmd("boottime.txt", scp_result_file), alloc);
                try utils.Process.run(&.{ "mv", scp_result_file, result_file }, alloc);

                try utils.Process.run(&(utils.SshCmd ++ .{"reboot"}), alloc);
                var output = try radinace_process.end(alloc);
                defer output.deinit(alloc);

                try process_resource_usage.update(&radinace_process, alloc);
                try process_startup_time.update(&output);
            }
        }

        cpu_usage_thread_stop = true;
        cpu_usage_thread.join();
    }

    std.log.info("moving results to {s}", .{results_path});
    try utils.Process.run(&.{ "mv", ResultsPath, results_path }, alloc);
}
