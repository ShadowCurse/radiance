const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");

pub const std_options = std.Options{
    .log_level = .info,
};

const ITERATIONS = 10;
const RESULTS_PATH = "perf_results/fio";
const CONFIG_PATH = "test/fio_config.toml";
const MODES = [_][]const u8{ "randread", "randwrite", "read", "write" };
const BLOCK_SIZES = [_][]const u8{ "4K", "8K", "16K" };

const Device = struct {
    path: []const u8,
    name: []const u8,
};
const DEVICES = [_]Device{
    .{
        .path = "/dev/vdb",
        .name = "block",
    },
    .{
        .path = "/dev/pmem0",
        .name = "pmem",
    },
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const timestamp = std.time.timestamp();
    const results_path = try std.fmt.allocPrint(alloc, "{s}_{}", .{ RESULTS_PATH, timestamp });
    defer alloc.free(results_path);

    std.log.info("creating results directory", .{});
    try utils.Process.run(&.{ "mkdir", "-p", RESULTS_PATH }, alloc);

    try utils.dummy_block_create(alloc, 256, 4096);
    defer utils.dummy_block_delete(alloc) catch unreachable;

    try utils.vmtouch_files(alloc, &.{ CONFIG_PATH, utils.DummyFilePath });
    defer utils.vmtouch_free(alloc);

    {
        var system_cpu_usage = try utils.SystemCpuUsage.init(RESULTS_PATH);
        defer system_cpu_usage.deinit();

        var process_resource_usage = try utils.ProcessResourceUsage.init(RESULTS_PATH);
        defer process_resource_usage.deinit();

        var cpu_usage_thread_stop: bool = false;
        const cpu_usage_thread = try std.Thread.spawn(.{}, utils.system_cpu_usage_thread, .{
            &system_cpu_usage,
            alloc,
            std.time.ns_per_s,
            &cpu_usage_thread_stop,
        });

        for (0..ITERATIONS) |i| {
            inline for (DEVICES) |device| {
                inline for (MODES) |mode| {
                    inline for (BLOCK_SIZES) |bs| {
                        std.log.info(
                            "Running iteration: {d}, mode: {s}, block_size: {s}",
                            .{ i, mode, bs },
                        );

                        var radinace_process = try utils.Process.start(
                            "radiance",
                            &utils.RadianceCmd(CONFIG_PATH),
                            alloc,
                        );
                        std.log.info("Waiting for radiance to boot", .{});
                        std.time.sleep(utils.RadianceBootTimeDelay);

                        const fio_cmd = utils.FioCmd(device.path, bs, mode);
                        try utils.Process.run(&(utils.SshCmd ++ fio_cmd), alloc);

                        const scp_result_file =
                            RESULTS_PATH ++ "/fio_" ++ "_" ++ device.name ++ "_" ++ mode ++ "_" ++ bs ++ ".json";
                        const result_file = try std.fmt.allocPrint(
                            alloc,
                            "{s}/fio_{s}_{s}_{s}_{d}.json",
                            .{ RESULTS_PATH, device.name, mode, bs, i },
                        );
                        defer alloc.free(result_file);

                        try utils.Process.run(&utils.ScpCmd(utils.FioResult, scp_result_file), alloc);
                        try utils.Process.run(&.{ "mv", scp_result_file, result_file }, alloc);

                        try utils.Process.run(&(utils.SshCmd ++ .{"reboot"}), alloc);
                        var output = try radinace_process.end(alloc);
                        defer output.deinit(alloc);

                        try process_resource_usage.update(&radinace_process, alloc);
                    }
                }
            }
        }

        cpu_usage_thread_stop = true;
        cpu_usage_thread.join();
    }

    std.log.info("moving results to {s}", .{results_path});
    try utils.Process.run(&.{ "mv", RESULTS_PATH, results_path }, alloc);
}
