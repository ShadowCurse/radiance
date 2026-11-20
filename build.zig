const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const host_page_size =
        b.option(usize, "host_page_size", "Page size on the host system") orelse
        std.heap.pageSize();
    const use_llvm = b.option(bool, "use_llvm", "Use LLVM backend") != null;

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
        .use_llvm = use_llvm,
    });
    exe.root_module.addOptions("build_options", options);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const unit_test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    const linux_h = b.addWriteFiles().add("linux.h",
        \\#include <linux/kvm.h>
        \\#include <linux/if.h>
        \\#include <linux/if_tun.h>
        \\#include <linux/vhost.h>
        \\#include <linux/virtio_ring.h>
        \\#include <linux/virtio_config.h>
        \\#include <linux/virtio_blk.h>
        \\#include <linux/virtio_net.h>
        \\#include <linux/virtio_mmio.h>
        \\
        \\#ifdef __x86_64__
        \\#include <linux/elf.h>
        \\#include <asm/bootparam.h>
        \\#include <asm/setup_data.h>
        \\#include <asm/e820.h>
        \\#endif
        \\
        \\#include <sys/epoll.h>
        \\#include <sys/eventfd.h>
        \\#include <fcntl.h>
        \\#include <signal.h>
        \\#include <pthread.h>
    );
    const linux_bindings = b.addTranslateC(.{
        .root_source_file = linux_h,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    unit_test_mod.addImport("linux_bindings", linux_bindings.createModule());
    const unit_tests = b.addTest(.{
        .name = "unit_tests",
        .root_module = unit_test_mod,
        .filters = b.option([]const []const u8, "test-filter", "Unit test name filter") orelse &.{},
    });
    b.installArtifact(unit_tests);

    const run_unit_tests = if (b.option(bool, "generate-coverage", "Generate test coverage")) |_| blk: {
        const kcov = b.addSystemCommand(&.{ "kcov", "--exclude-pattern=/nix", "kcov-output" });
        kcov.addArtifactArg(unit_tests);
        break :blk kcov;
    } else b.addRunArtifact(unit_tests);
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
        test_run_cmd.addPassthruArgs();
        const test_run_step = b.step(perf, "Run the " ++ perf);
        test_run_step.dependOn(&run_cmd.step);
    }
}
