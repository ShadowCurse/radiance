const std = @import("std");
const Allocator = std.mem.Allocator;

pub const KernelPath = "./vmlinux-6.12";
pub const RootFsPath = "./resources/ubuntu.ext4";
pub const DummyFilePath = "./dummy";

pub const RadianceBin = "./zig-out/bin/radiance";
pub const RadianceBootTimeDelay = 2 * std.time.ns_per_s;

pub fn vmtouch_files(
    alloc: Allocator,
    other_paths: []const []const u8,
) !void {
    std.log.info("using vmtouch on all files", .{});
    try Process.run(&.{ "vmtouch", "-L", "-d", KernelPath }, alloc);
    try Process.run(&.{ "vmtouch", "-L", "-d", RootFsPath }, alloc);
    for (other_paths) |op| {
        try Process.run(&.{ "vmtouch", "-L", "-d", op }, alloc);
    }
}

pub fn vmtouch_free(alloc: Allocator) void {
    std.log.info("killing vmtouch", .{});
    Process.run(&.{ "killall", "vmtouch" }, alloc) catch unreachable;
}

pub fn dummy_block_create(alloc: Allocator, size_mb: u32, block_size: u32) !void {
    const block_count = size_mb * 1024 * 1024 / block_size;
    const bs = try std.fmt.allocPrint(alloc, "bs={d}", .{block_size});
    defer alloc.free(bs);
    const count = try std.fmt.allocPrint(alloc, "count={d}", .{block_count});
    defer alloc.free(count);
    std.log.info(
        "creating dummy block with size: {d}MB, block_size: {d}, blocks: {d}",
        .{ size_mb, block_size, block_count },
    );
    try Process.run(&.{ "dd", "if=/dev/zero", "of=" ++ DummyFilePath, bs, count }, alloc);
}

pub fn dummy_block_delete(alloc: Allocator) !void {
    std.log.info("deleting dummy block", .{});
    try Process.run(&.{ "rm", "dummy" }, alloc);
}

pub fn RadianceCmd(comptime config_path: []const u8) [4][]const u8 {
    return [_][]const u8{
        "sudo",
        RadianceBin,
        "--config_path",
        config_path,
    };
}

pub const RootfsSshKeyPath = "./resources/ubuntu.id_rsa";
pub const RootfsSshCreds = "root@172.16.0.2";
pub const SshCmd = [_][]const u8{
    "ssh",
    "-o",
    "ConnectTimeout=10",
    "-o",
    "UserKnownHostsFile=/dev/null",
    "-o",
    "StrictHostKeyChecking=no",
    "-o",
    "PreferredAuthentications=publickey",
    "-i",
    RootfsSshKeyPath,
    RootfsSshCreds,
};

pub fn ScpCmd(comptime from: []const u8, comptime to: []const u8) [13][]const u8 {
    return [_][]const u8{
        "scp",
        "-o",
        "ConnectTimeout=10",
        "-o",
        "UserKnownHostsFile=/dev/null",
        "-o",
        "StrictHostKeyChecking=no",
        "-o",
        "PreferredAuthentications=publickey",
        "-i",
        RootfsSshKeyPath,
        RootfsSshCreds ++ ":" ++ from,
        to,
    };
}

pub const FioResult = "/tmp/fio.json";
pub fn FioCmd(
    comptime device: []const u8,
    comptime block_size: []const u8,
    comptime mode: []const u8,
) [11][]const u8 {
    const bs = std.fmt.comptimePrint("--bs={s}", .{block_size});
    return [_][]const u8{
        "fio",
        "--name=a",
        "--filename=" ++ device,
        "--ioengine=libaio",
        bs,
        "--time_base=1",
        "--runtime=10",
        "--direct=1",
        "--output-format=json",
        "--output=" ++ FioResult,
        "--rw=" ++ mode,
    };
}

pub const IperfResult = "/tmp/iperf.json";
pub fn IperfCmd(comptime arg: []const u8) [8][]const u8 {
    return [_][]const u8{
        "iperf3",
        "-c",
        "172.16.0.1",
        "--time=10",
        "--json",
        "--logfile",
        IperfResult,
        arg,
    };
}

pub const Process = struct {
    name: []const u8,
    child: std.process.Child,

    pub const Output = struct {
        stdout: std.ArrayListUnmanaged(u8),
        stderr: std.ArrayListUnmanaged(u8),

        pub fn deinit(self: *Output, allocator: Allocator) void {
            self.stdout.deinit(allocator);
            self.stderr.deinit(allocator);
        }
    };

    pub fn run(argv: []const []const u8, allocator: std.mem.Allocator) !void {
        std.log.info("Running:", .{});

        for (argv) |arg| {
            std.debug.print("{s} ", .{arg});
        }
        std.debug.print("\n", .{});

        var p = std.process.Child.init(argv, allocator);
        _ = try p.spawnAndWait();
        return;
    }

    pub fn start(name: []const u8, argv: []const []const u8, allocator: std.mem.Allocator) !Process {
        std.log.info("Starting {s}", .{name});
        for (argv) |arg| {
            std.debug.print("{s} ", .{arg});
        }
        std.debug.print("\n", .{});
        var child = std.process.Child.init(argv, allocator);
        child.request_resource_usage_statistics = true;
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();
        return .{
            .name = name,
            .child = child,
        };
    }

    pub fn end(self: *Process, allocator: std.mem.Allocator) !Output {
        std.log.info("Ending {s}", .{self.name});
        var stdout = std.ArrayListUnmanaged(u8).empty;
        var stderr = std.ArrayListUnmanaged(u8).empty;
        try self.child.collectOutput(allocator, &stdout, &stderr, std.math.maxInt(usize));

        const exit = try self.child.wait();
        std.log.info("{s} exit: {any}", .{ self.name, exit });
        std.log.info("{s} stdout: {s}", .{ self.name, stdout.items });
        std.log.info("{s} stderr: {s}", .{ self.name, stderr.items });

        return .{
            .stdout = stdout,
            .stderr = stderr,
        };
    }
};

pub const ProcessResourceUsage = struct {
    file: std.fs.File,

    const Self = @This();

    pub fn init(comptime result_path: []const u8) !Self {
        const usage_path = result_path ++ "/resource_usage.txt";
        std.log.info("{s}", .{usage_path});
        const file = try std.fs.cwd().createFile(usage_path, .{});
        return .{
            .file = file,
        };
    }

    pub fn deinit(self: *const Self) void {
        self.file.close();
    }

    pub fn update(self: *Self, process: *const Process, allocator: Allocator) !void {
        const rusage = process.child.resource_usage_statistics.rusage.?;
        const t = @TypeOf(rusage);
        const fields = @typeInfo(t).@"struct".fields;
        inline for (fields) |field| {
            switch (field.type) {
                isize => {
                    const s = try std.fmt.allocPrint(allocator, "{s} {}\n", .{ field.name, @field(rusage, field.name) });
                    defer allocator.free(s);

                    _ = try self.file.write(s);
                },
                std.os.linux.timeval => {
                    const f = @field(rusage, field.name);
                    const s = try std.fmt.allocPrint(allocator, "{s} {} {}\n", .{ field.name, f.sec, f.usec });
                    defer allocator.free(s);

                    _ = try self.file.write(s);
                },
                else => {},
            }
        }
    }
};

pub const ProcessStartupTime = struct {
    file: std.fs.File,

    const Self = @This();

    pub fn init(comptime result_path: []const u8) !Self {
        const usage_path = result_path ++ "/startup_time.txt";
        std.log.info("{s}", .{usage_path});
        const file = try std.fs.cwd().createFile(usage_path, .{});
        return .{
            .file = file,
        };
    }

    pub fn deinit(self: *const Self) void {
        self.file.close();
    }

    pub fn update(self: *Self, output: *const Process.Output) !void {
        var iter = std.mem.splitScalar(u8, output.stderr.items, '\n');
        while (iter.next()) |line| {
            if (std.mem.indexOf(u8, line, "startup time")) |_| {
                _ = try self.file.write(line);
                _ = try self.file.write("\n");
            }
        }
    }
};

pub const SystemCpuUsage = struct {
    file: std.fs.File,

    const Self = @This();

    pub fn init(comptime result_path: []const u8) !Self {
        const usage_path = result_path ++ "/cpu_usage.txt";
        std.log.info("{s}", .{usage_path});
        const file = try std.fs.cwd().createFile(usage_path, .{});
        return .{
            .file = file,
        };
    }

    pub fn deinit(self: *const Self) void {
        self.file.close();
    }

    pub fn update(self: *Self, alloc: Allocator) !void {
        const cpustat = try std.fs.openFileAbsolute("/proc/stat", .{ .mode = .read_only });
        defer cpustat.close();

        const text = try cpustat.readToEndAlloc(alloc, std.math.maxInt(usize));
        defer alloc.free(text);

        var iter = std.mem.splitScalar(u8, text, '\n');
        while (iter.next()) |line| {
            if (std.mem.startsWith(u8, line, "cpu")) {
                _ = try self.file.write(line);
                _ = try self.file.write("\n");
            }
        }
    }
};

pub fn system_cpu_usage_thread(system_cpu_usage: *SystemCpuUsage, alloc: Allocator, delta: u64, stop: *bool) !void {
    while (!stop.*) {
        try system_cpu_usage.update(alloc);
        std.time.sleep(delta);
    }
}
