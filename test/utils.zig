const std = @import("std");
const Allocator = std.mem.Allocator;

pub const KernelPath = "./resources/vmlinux-6.12";
pub const RootFsPath = "./resources/ubuntu.ext4";
pub const DummyFilePath = "./dummy";

pub const RadianceBin = "./zig-out/bin/radiance";
pub const RadianceBootTimeDelay = 2 * std.time.ns_per_s;

pub fn vmtouch_files(io: std.Io, other_paths: []const []const u8) !void {
    std.log.info("using vmtouch on all files", .{});
    try Process.run(io, &.{ "vmtouch", "-L", "-d", KernelPath });
    try Process.run(io, &.{ "vmtouch", "-L", "-d", RootFsPath });
    for (other_paths) |op| try Process.run(io, &.{ "vmtouch", "-L", "-d", op });
}

pub fn vmtouch_free(io: std.Io) void {
    std.log.info("killing vmtouch", .{});
    Process.run(io, &.{ "killall", "vmtouch" }) catch unreachable;
}

pub fn dummy_block_create(io: std.Io, alloc: Allocator, size_mb: u32, block_size: u32) !void {
    const block_count = size_mb * 1024 * 1024 / block_size;
    const bs = try std.fmt.allocPrint(alloc, "bs={d}", .{block_size});
    defer alloc.free(bs);
    const count = try std.fmt.allocPrint(alloc, "count={d}", .{block_count});
    defer alloc.free(count);
    std.log.info(
        "creating dummy block with size: {d}MB, block_size: {d}, blocks: {d}",
        .{ size_mb, block_size, block_count },
    );
    try Process.run(io, &.{ "dd", "if=/dev/zero", "of=" ++ DummyFilePath, bs, count });
}

pub fn dummy_block_delete(io: std.Io) !void {
    std.log.info("deleting dummy block", .{});
    try Process.run(io, &.{ "rm", "dummy" });
}

pub fn RadianceCmd(comptime config_path: []const u8) [4][]const u8 {
    return [_][]const u8{
        "sudo",
        RadianceBin,
        "--config-path",
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
        stdout: []const u8,
        stderr: []const u8,

        pub fn deinit(self: *Output, alloc: Allocator) void {
            alloc.free(self.stderr);
            alloc.free(self.stdout);
        }
    };

    pub fn run(io: std.Io, argv: []const []const u8) !void {
        std.log.info("Running:", .{});
        for (argv) |arg| std.debug.print("{s} ", .{arg});
        std.debug.print("\n", .{});

        var p = try std.process.spawn(io, .{ .argv = argv });
        _ = try p.wait(io);
        return;
    }

    pub fn start(io: std.Io, name: []const u8, argv: []const []const u8) !Process {
        std.log.info("Starting {s}", .{name});
        for (argv) |arg| std.debug.print("{s} ", .{arg});
        std.debug.print("\n", .{});
        const child = try std.process.spawn(io, .{
            .argv = argv,
            .request_resource_usage_statistics = true,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .pipe,
        });
        return .{ .name = name, .child = child };
    }

    pub fn end(self: *Process, io: std.Io, alloc: std.mem.Allocator) !Output {
        std.log.info("Ending {s}", .{self.name});

        const exit = try self.child.wait(io);
        std.log.info("{s} exit: {any}", .{ self.name, exit });

        var stdout_reader = self.child.stdout.?.reader(io, &.{});
        const stdout = try stdout_reader.interface.allocRemaining(alloc, .unlimited);
        var stderr_reader = self.child.stderr.?.reader(io, &.{});
        const stderr = try stderr_reader.interface.allocRemaining(alloc, .unlimited);

        std.log.info("{s} stdout: {s}", .{ self.name, stdout });
        std.log.info("{s} stderr: {s}", .{ self.name, stderr });

        return .{ .stdout = stdout, .stderr = stderr };
    }
};

pub const ProcessResourceUsage = struct {
    file: std.Io.File,

    const Self = @This();

    pub fn init(io: std.Io, comptime result_path: []const u8) !Self {
        const usage_path = result_path ++ "/resource_usage.txt";
        std.log.info("{s}", .{usage_path});
        const file = try std.Io.Dir.cwd().createFile(io, usage_path, .{});
        return .{ .file = file };
    }

    pub fn deinit(self: *const Self, io: std.Io) void {
        self.file.close(io);
    }

    pub fn update(self: *Self, io: std.Io, process: *const Process, alloc: Allocator) !void {
        const rusage = process.child.resource_usage_statistics.rusage.?;
        const t = @TypeOf(rusage);
        const fields = @typeInfo(t).@"struct".fields;
        inline for (fields) |field| {
            switch (field.type) {
                isize => {
                    const s = try std.fmt.allocPrint(alloc, "{s} {}\n", .{ field.name, @field(rusage, field.name) });
                    defer alloc.free(s);

                    var w = self.file.writer(io, &.{});
                    _ = try w.interface.write(s);
                },
                std.os.linux.timeval => {
                    const f = @field(rusage, field.name);
                    const s = try std.fmt.allocPrint(alloc, "{s} {} {}\n", .{ field.name, f.sec, f.usec });
                    defer alloc.free(s);

                    var w = self.file.writer(io, &.{});
                    _ = try w.interface.write(s);
                },
                else => {},
            }
        }
    }
};

pub const ProcessStartupTime = struct {
    file: std.Io.File,

    const LINE_START = "[profiler.zig:162:INFO] Total ";
    const Self = @This();

    pub fn init(io: std.Io, comptime result_path: []const u8) !Self {
        const usage_path = result_path ++ "/startup_time.txt";
        std.log.info("{s}", .{usage_path});
        const file = try std.Io.Dir.cwd().createFile(io, usage_path, .{});
        return .{ .file = file };
    }

    pub fn deinit(self: *const Self, io: std.Io) void {
        self.file.close(io);
    }

    pub fn update(self: *Self, io: std.Io, output: *const Process.Output) !void {
        var iter = std.mem.splitScalar(u8, output.stderr, '\n');
        while (iter.next()) |line| {
            if (std.mem.indexOf(u8, line, LINE_START)) |_| {
                const time = line[LINE_START.len..];
                const time_ms = time[0 .. time.len - "ms".len];
                var w = self.file.writer(io, &.{});
                _ = try w.interface.write(time_ms);
                _ = try w.interface.write("\n");
            }
        }
    }
};

pub const SystemCpuUsage = struct {
    file: std.Io.File,

    const Self = @This();

    pub fn init(io: std.Io, comptime result_path: []const u8) !Self {
        const usage_path = result_path ++ "/cpu_usage.txt";
        std.log.info("{s}", .{usage_path});
        const file = try std.Io.Dir.cwd().createFile(io, usage_path, .{});
        return .{ .file = file };
    }

    pub fn deinit(self: *const Self, io: std.Io) void {
        self.file.close(io);
    }

    pub fn update(self: *Self, io: std.Io, alloc: Allocator) !void {
        const cpustat = try std.Io.Dir.openFileAbsolute(io, "/proc/stat", .{ .mode = .read_only });
        defer cpustat.close(io);

        var text_reader = cpustat.reader(io, &.{});
        const text = try text_reader.interface.allocRemaining(alloc, .unlimited);
        defer alloc.free(text);

        var iter = std.mem.splitScalar(u8, text, '\n');
        while (iter.next()) |line| {
            if (std.mem.startsWith(u8, line, "cpu")) {
                var w = self.file.writer(io, &.{});
                _ = try w.interface.write(line);
                _ = try w.interface.write("\n");
            }
        }
    }
};

pub fn system_cpu_usage_thread(
    io: std.Io,
    alloc: Allocator,
    system_cpu_usage: *SystemCpuUsage,
    delta: u64,
    stop: *bool,
) !void {
    while (!stop.*) {
        try system_cpu_usage.update(io, alloc);
        std.Io.sleep(io, .fromNanoseconds(delta), .real) catch unreachable;
    }
}
