const std = @import("std");
const Allocator = std.mem.Allocator;
const utils = @import("utils.zig");

const ResultsPath = "perf_results/iperf";
const ConfigPath = "test/iperf_config.toml";

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

    const modes = [_]struct { []const u8, []const u8 }{
        .{ "", "h2g" },
        .{ "-R", "g2h" },
    };
    inline for (modes) |mode| {
        std.log.info("Starting iperf on the host", .{});
        try utils.Process.run(&.{ "iperf3", "-s", "-D", "-1" }, alloc);

        var radinace_process = try utils.Process.start("radiance", &utils.RadianceCmd(ConfigPath), alloc);

        std.log.info("Waiting for radiance to boot", .{});
        std.time.sleep(utils.RadianceBootTimeDelay);

        const iperf_cmd = utils.IperfCmd(mode[0]);
        var iperf_ssh_process = try utils.Process.start("iperf_ssh", &(utils.SshCmd ++ iperf_cmd), alloc);
        try iperf_ssh_process.end(alloc);

        var iperf_scp_process = try utils.Process.start(
            "iperf_scp",
            &utils.ScpCmd("iperf.json", ResultsPath ++ "/iperf_" ++ mode[1] ++ ".json"),
            alloc,
        );
        try iperf_scp_process.end(alloc);

        var ssh_process = try utils.Process.start("reboot_ssh", &(utils.SshCmd ++ .{"reboot"}), alloc);

        try radinace_process.end(alloc);
        try ssh_process.end(alloc);
    }

    std.log.info("moving results to {s}", .{results_path});
    try utils.Process.run(&.{ "mv", ResultsPath, results_path }, alloc);
}
