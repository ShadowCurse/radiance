const std = @import("std");
const Allocator = std.mem.Allocator;

pub const KernelPath = "./vmlinux-6.12";
pub const RootFsPath = "./resources/ubuntu.ext4";
pub const DummyFilePath = "./dummy";

pub const RadianceBin = "./zig-out/bin/radiance";
pub const RadianceBootTimeDelay = 2 * std.time.ns_per_s;

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
pub fn FioCmd(comptime t: []const u8) [11][]const u8 {
    return [_][]const u8{
        "fio",
        "--name=a",
        "--filename=/dev/vdb",
        "--ioengine=libaio",
        "--bs=4096",
        "--time_base=1",
        "--runtime=10",
        "--direct=1",
        "--output-format=json",
        "--output=" ++ FioResult,
        "--rw=" ++ t,
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
        stdout: std.ArrayList(u8),
        stderr: std.ArrayList(u8),

        pub fn deinit(self: *const Output) void {
            self.stdout.deinit();
            self.stderr.deinit();
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
        var stdout = std.ArrayList(u8).init(allocator);
        var stderr = std.ArrayList(u8).init(allocator);
        try self.child.collectOutput(&stdout, &stderr, std.math.maxInt(usize));

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
        const fields = @typeInfo(t).Struct.fields;
        inline for (fields) |field| {
            switch (field.type) {
                isize => {
                    const s = try std.fmt.allocPrint(allocator, "{s} {}\n", .{ field.name, @field(rusage, field.name) });
                    defer allocator.free(s);

                    _ = try self.file.write(s);
                },
                std.os.linux.timeval => {
                    const f = @field(rusage, field.name);
                    const s = try std.fmt.allocPrint(allocator, "{s} {} {}\n", .{ field.name, f.tv_sec, f.tv_usec });
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

pub fn vmtouch_files(comptime config_path: []const u8, alloc: Allocator) !void {
    std.log.info("using vmtouch on all files", .{});
    try Process.run(&.{ "vmtouch", "-L", "-d", KernelPath }, alloc);
    try Process.run(&.{ "vmtouch", "-L", "-d", RootFsPath }, alloc);
    try Process.run(&.{ "vmtouch", "-L", "-d", config_path }, alloc);
}

pub fn vmtouch_free(alloc: Allocator) void {
    std.log.info("killing vmtouch", .{});
    Process.run(&.{ "killall", "vmtouch" }, alloc) catch unreachable;
}

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
