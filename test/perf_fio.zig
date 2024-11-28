const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");

const Iterations = 10;
const ResultsPath = "perf_results/fio";
const ConfigPath = "test/fio_config.toml";

fn create_dummy_block(alloc: Allocator) !void {
    std.log.info("creating dummy block", .{});
    try utils.Process.run(&.{ "dd", "if=/dev/zero", "of=dummy", "bs=4096B", "count=65536" }, alloc);
}

fn remove_dummy_block(alloc: Allocator) void {
    std.log.info("deleting dummy block", .{});
    utils.Process.run(&.{ "rm", "dummy" }, alloc) catch unreachable;
}

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

    try create_dummy_block(alloc);
    defer remove_dummy_block(alloc);

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
            const modes = [_][]const u8{ "randread", "randwrite", "read", "write" };
            inline for (modes) |mode| {
                var radinace_process = try utils.Process.start("radiance", &utils.RadianceCmd(ConfigPath), alloc);

                std.log.info("Waiting for radiance to boot", .{});
                std.time.sleep(utils.RadianceBootTimeDelay);

                const fio_cmd = utils.FioCmd(mode);
                var fio_ssh_process = try utils.Process.start("fio_ssh", &(utils.SshCmd ++ fio_cmd), alloc);
                try fio_ssh_process.end(alloc);

                const scp_result_file = ResultsPath ++ "/fio_" ++ mode ++ ".json";
                const result_file = try std.fmt.allocPrint(alloc, "{s}/fio_{s}_{}.json", .{ ResultsPath, mode, i });
                defer alloc.free(result_file);

                var fio_scp_process = try utils.Process.start(
                    "fio_scp",
                    &utils.ScpCmd(utils.FioResult, scp_result_file),
                    alloc,
                );
                try fio_scp_process.end(alloc);
                try utils.Process.run(&.{ "mv", scp_result_file, result_file }, alloc);

                var ssh_process = try utils.Process.start("reboot_ssh", &(utils.SshCmd ++ .{"reboot"}), alloc);

                try radinace_process.end(alloc);
                try ssh_process.end(alloc);
            }
        }

        cpu_usage_thread_stop = true;
        cpu_usage_thread.join();
    }

    std.log.info("moving results to {s}", .{results_path});
    try utils.Process.run(&.{ "mv", ResultsPath, results_path }, alloc);
}
