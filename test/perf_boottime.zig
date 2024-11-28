const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");

const Iterations = 10;
const ResultsPath = "perf_results/boottime";
const ConfigPath = "test/boottime_config.toml";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const timestamp = std.time.timestamp();
    const results_path = try std.fmt.allocPrint(alloc, "{s}_{}", .{ ResultsPath, timestamp });
    defer alloc.free(results_path);

    try utils.vmtouch_files(ConfigPath, alloc);
    defer utils.vmtouch_free(alloc);

    std.log.info("creating results directory", .{});
    try utils.Process.run(&.{ "mkdir", "-p", ResultsPath }, alloc);

    std.log.info("Waiting for resources to be ready", .{});
    std.time.sleep(utils.RadianceBootTimeDelay);

    {
        var system_cpu_usage = try utils.SystemCpuUsage.init(ResultsPath);
        defer system_cpu_usage.deinit();

        var cpu_usage_thread_stop: bool = false;
        const cpu_usage_thread = try std.Thread.spawn(.{}, utils.system_cpu_usage_thread, .{
            &system_cpu_usage,
            alloc,
            std.time.ns_per_s,
            &cpu_usage_thread_stop,
        });

        for (0..Iterations) |i| {
            var radinace_process = try utils.Process.start("radiance", &utils.RadianceCmd(ConfigPath), alloc);

            std.log.info("Waiting for radiance to boot", .{});
            std.time.sleep(utils.RadianceBootTimeDelay);

            var boottime_ssh_process = try utils.Process.start(
                "boottime_ssh",
                &(utils.SshCmd ++ .{ "systemd-analyze", ">", "boottime.txt" }),
                alloc,
            );
            try boottime_ssh_process.end(alloc);

            const scp_result_file = ResultsPath ++ "/boottime.txt";
            const result_file = try std.fmt.allocPrint(alloc, "{s}/boottime_{}.txt", .{ ResultsPath, i });
            defer alloc.free(result_file);

            var boottime_scp_process = try utils.Process.start(
                "boottime_scp",
                &utils.ScpCmd("boottime.txt", scp_result_file),
                alloc,
            );
            try boottime_scp_process.end(alloc);
            try utils.Process.run(&.{ "mv", scp_result_file, result_file }, alloc);

            var ssh_process = try utils.Process.start("reboot_ssh", &(utils.SshCmd ++ .{"reboot"}), alloc);

            try radinace_process.end(alloc);
            try ssh_process.end(alloc);
        }

        cpu_usage_thread_stop = true;
        cpu_usage_thread.join();
    }

    std.log.info("moving results to {s}", .{results_path});
    try utils.Process.run(&.{ "mv", ResultsPath, results_path }, alloc);
}
