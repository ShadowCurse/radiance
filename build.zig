const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const host_page_size =
        b.option(usize, "host_page_size", "Page size on the host system") orelse
        std.heap.pageSize();

    const options = b.addOptions();
    options.addOption(usize, "host_page_size", host_page_size);

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "radiance",
        .root_module = exe_mod,
    });
    exe.root_module.addOptions("build_options", options);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{
        .name = "unit_tests",
        .root_module = unit_test_mod,
        .filters = b.args orelse &.{},
    });
    unit_tests.linkLibC();
    b.installArtifact(unit_tests);

    if (b.option(bool, "generate-coverage", "Generate test coverage")) |_| {
        unit_tests.setExecCmd(&.{
            "kcov",
            "--exclude-pattern=/nix",
            "kcov-output",
            null,
        });
    }

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    inline for (.{ "perf_boottime", "perf_fio", "perf_iperf" }) |perf| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path("test/" ++ perf ++ ".zig"),
            .target = target,
            .optimize = optimize,
        });
        const test_exe = b.addExecutable(.{
            .name = perf,
            .root_module = test_mod,
        });
        b.installArtifact(test_exe);
        const test_run_cmd = b.addRunArtifact(exe);
        test_run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| test_run_cmd.addArgs(args);
        const test_run_step = b.step(perf, "Run the " ++ perf);
        test_run_step.dependOn(&run_cmd.step);
    }
}
