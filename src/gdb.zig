const std = @import("std");
const log = @import("log.zig");

fn fmt_response(buffer: []u8, msg: []const u8) ![]const u8 {
    var sum: u32 = 0;
    for (msg) |b| {
        sum += b;
    }
    const checksum = sum % 256;
    return std.fmt.bufPrint(buffer, "+${s}#{x}", .{ msg, checksum });
}

const ThreadId = struct {
    const Self = @This();

    const IdEnum = enum { All, Any, Id };

    const Id = union(IdEnum) {
        All,
        Any,
        Id: u32,

        fn from_bytes(bytes: []const u8) ?Id {
            return switch (bytes[0]) {
                '-' => .All,
                '0' => .Any,
                else => .{ .Id = std.fmt.parseInt(u32, bytes, 16) catch return null },
            };
        }
    };

    pid: ?Id,
    tid: Id,

    fn from_bytes(bytes: []const u8) ?Self {
        switch (bytes[0]) {
            // p(pid).[tid]
            'p' => {
                var iter = std.mem.splitScalar(u8, bytes[1..], '.');
                const pid = if (iter.next()) |pid_slice| blk: {
                    if (Id.from_bytes(pid_slice)) |pid| {
                        break :blk pid;
                    } else {
                        return null;
                    }
                } else blk: {
                    break :blk null;
                };
                const tid = if (iter.next()) |tid_slice| blk: {
                    if (Id.from_bytes(tid_slice)) |tid| {
                        break :blk tid;
                    } else {
                        return null;
                    }
                } else blk: {
                    break :blk .All;
                };
                return .{
                    .pid = pid,
                    .tid = tid,
                };
            },
            // (tid)
            else => {
                const tid = if (Id.from_bytes(bytes[1..])) |tid| blk: {
                    break :blk tid;
                } else {
                    return null;
                };
                return .{
                    .pid = null,
                    .tid = tid,
                };
            },
        }
    }
};

const qSupported = struct {
    bytes: []const u8,

    const Self = @This();

    fn from_bytes(bytes: []const u8) ?Self {
        return if (std.mem.startsWith(u8, bytes, "qSupported")) blk: {
            break :blk .{
                .bytes = bytes,
            };
        } else blk: {
            break :blk null;
        };
    }

    fn response(self: *const Self, buffer: []u8) ![]const u8 {
        _ = self;
        // 16 regs each 4 bytes (8 hex chars) = 128 chars + 1 = 129 = 0x81
        const msg = "PacketSize=81;vContSupported+;multiprocess+";
        return fmt_response(buffer, msg);
    }
};

const qfThreadInfo = struct {
    bytes: []const u8,

    const Self = @This();

    fn from_bytes(bytes: []const u8) ?Self {
        return if (std.mem.startsWith(u8, bytes, "qfThreadInfo")) blk: {
            break :blk .{
                .bytes = bytes,
            };
        } else blk: {
            break :blk null;
        };
    }

    fn response(self: *const Self, buffer: []u8) ![]const u8 {
        _ = self;
        const msg = "mp01.01";
        return fmt_response(buffer, msg);
    }
};

const qsThreadInfo = struct {
    bytes: []const u8,

    const Self = @This();

    fn from_bytes(bytes: []const u8) ?Self {
        return if (std.mem.startsWith(u8, bytes, "qsThreadInfo")) blk: {
            break :blk .{
                .bytes = bytes,
            };
        } else blk: {
            break :blk null;
        };
    }

    fn response(self: *const Self, buffer: []u8) ![]const u8 {
        _ = self;
        const msg = "l";
        return fmt_response(buffer, msg);
    }
};

const qAttached = struct {
    bytes: []const u8,

    const Self = @This();

    fn from_bytes(bytes: []const u8) ?Self {
        return if (std.mem.startsWith(u8, bytes, "qAttached")) blk: {
            break :blk .{
                .bytes = bytes,
            };
        } else blk: {
            break :blk null;
        };
    }

    fn response(self: *const Self, buffer: []u8) ![]const u8 {
        _ = self;
        const msg = "1";
        return fmt_response(buffer, msg);
    }
};

const vCont = struct {
    bytes: []const u8,

    const Self = @This();

    fn from_bytes(bytes: []const u8) ?Self {
        return if (std.mem.startsWith(u8, bytes, "vCont")) blk: {
            break :blk .{
                .bytes = bytes,
            };
        } else blk: {
            break :blk null;
        };
    }

    fn response(self: *const Self, buffer: []u8) ![]const u8 {
        _ = self;
        const msg = "vCont;c;C";
        return fmt_response(buffer, msg);
    }
};

const H = struct {
    bytes: []const u8,
    op: Op,
    thread_id: ThreadId,

    const Self = @This();

    const Op = enum {
        StepContinue,
        Other,
    };

    fn from_bytes(bytes: []const u8) ?Self {
        return if (std.mem.startsWith(u8, bytes, "H")) blk: {
            const op_byte = bytes[1];
            const thread_id_slice = bytes[2..];

            const op = switch (op_byte) {
                'g' => Op.Other,
                'c' => Op.StepContinue,
                else => break :blk null,
            };

            const thread_id = if (ThreadId.from_bytes(thread_id_slice)) |thread_id| t: {
                break :t thread_id;
            } else {
                break :blk null;
            };

            break :blk .{
                .bytes = bytes,
                .op = op,
                .thread_id = thread_id,
            };
        } else blk: {
            break :blk null;
        };
    }

    fn response(self: *const Self, buffer: []u8) ![]const u8 {
        _ = self;
        const msg = "OK";
        return fmt_response(buffer, msg);
    }
};

const g = struct {
    bytes: []const u8,

    const Self = @This();

    fn from_bytes(bytes: []const u8) ?Self {
        return if (std.mem.startsWith(u8, bytes, "g")) blk: {
            break :blk .{
                .bytes = bytes,
            };
        } else blk: {
            break :blk null;
        };
    }

    fn response(self: *const Self, buffer: []u8) ![]const u8 {
        _ = self;
        const msg = "xxxx" ** 16;
        return fmt_response(buffer, msg);
    }
};

const QuestionMark = struct {
    const Self = @This();

    fn from_bytes(bytes: []const u8) ?Self {
        return if (std.mem.startsWith(u8, bytes, "?")) blk: {
            break :blk Self{};
        } else blk: {
            break :blk null;
        };
    }

    fn response(self: *const Self, buffer: []u8) ![]const u8 {
        _ = self;
        // TODO do smth about this
        const msg = "S05";
        return fmt_response(buffer, msg);
    }
};

const Unknown = struct {
    const Self = @This();
    fn response(self: *const Self) ![]const u8 {
        _ = self;
        return "+$#00";
    }
};

const PayloadEnum = enum {
    Acknowledgment,
    Retransmission,
    qSupported,
    qfThreadInfo,
    qsThreadInfo,
    qAttached,
    vCont,
    H,
    g,
    QuestionMark,
    Unknown,
};

const PayloadIterator = struct {
    i: usize = 0,
    buf: []const u8,

    const Self = @This();

    fn new(buf: []const u8) Self {
        return .{ .buf = buf };
    }

    fn next(self: *Self) !?Payload {
        return if (self.buf.len <= self.i) blk: {
            break :blk null;
        } else if (self.buf[self.i] == '+') blk: {
            const payload = try Payload.from(self.buf[self.i .. self.i + 1]);
            self.i += 1;
            break :blk payload;
        } else if (self.buf[self.i] == '-') blk: {
            const payload = try Payload.from(self.buf[self.i .. self.i + 1]);
            self.i += 1;
            break :blk payload;
        } else if (self.buf[self.i] == '$') blk: {
            const slice = std.mem.sliceTo(self.buf[self.i..], '#');
            const payload_slice = self.buf[self.i .. self.i + slice.len + 2];
            const payload = try Payload.from(payload_slice);
            self.i += slice.len + 2;
            break :blk payload;
        } else blk: {
            break :blk null;
        };
    }
};

const PayloadError = error{
    Invalid,
};

const Payload = union(PayloadEnum) {
    Acknowledgment,
    Retransmission,
    qSupported: qSupported,
    qfThreadInfo: qfThreadInfo,
    qsThreadInfo: qsThreadInfo,
    qAttached: qAttached,
    vCont: vCont,
    H: H,
    g: g,
    QuestionMark: QuestionMark,
    Unknown: Unknown,

    const Self = @This();

    fn from(bytes: []const u8) !Self {
        return if (bytes.len == 1) blk: {
            break :blk switch (bytes[0]) {
                '+' => .Acknowledgment,
                '-' => .Retransmission,
                else => PayloadError.Invalid,
            };
        } else blk: {
            const stripped = try Self.strip_bytes(bytes);
            log.info(@src(), "got stripped: {s}", .{stripped});
            if (qSupported.from_bytes(stripped)) |p| {
                break :blk .{ .qSupported = p };
            } else if (qfThreadInfo.from_bytes(stripped)) |p| {
                break :blk .{ .qfThreadInfo = p };
            } else if (qsThreadInfo.from_bytes(stripped)) |p| {
                break :blk .{ .qsThreadInfo = p };
            } else if (qAttached.from_bytes(stripped)) |p| {
                break :blk .{ .qAttached = p };
            } else if (vCont.from_bytes(stripped)) |p| {
                break :blk .{ .vCont = p };
            } else if (H.from_bytes(stripped)) |p| {
                break :blk .{ .H = p };
            } else if (g.from_bytes(stripped)) |p| {
                break :blk .{ .g = p };
            } else if (QuestionMark.from_bytes(stripped)) |p| {
                break :blk .{ .QuestionMark = p };
            } else {
                log.warn(@src(), "Unknown payload: {s}", .{stripped});
                break :blk .{ .Unknown = .{} };
            }
        };
    }

    fn strip_bytes(bytes: []const u8) ![]const u8 {
        return if (bytes.len < 4) blk: {
            break :blk PayloadError.Invalid;
        } else blk: {
            break :blk bytes[1 .. bytes.len - 2];
        };
    }
};

pub const GdbServer = struct {
    address: std.net.Address,
    server: std.net.Server,
    connection: std.net.Server.Connection,

    // vcpus: []const Vcpu,
    // memory: *Memory,
    // mmio: *Mmio,

    const Self = @This();

    pub fn init(socket_path: []const u8) !Self {
        const address = try std.net.Address.initUnix(socket_path);
        var server = try address.listen(.{});
        defer server.deinit();
        const connection = try server.accept();
        return .{
            .address = address,
            .server = server,
            .connection = connection,
        };
    }

    pub fn process_request(self: *const Self) !void {
        var read_buffer: [1024]u8 = undefined;
        var write_buffer: [1024]u8 = undefined;
        var len: usize = 9999;
        while (len != 0) {
            log.info(@src(), "reading payload", .{});
            len = try self.connection.stream.read(&read_buffer);
            const payload_data = read_buffer[0..len];
            log.info(@src(), "got payload: {s} len: {}", .{ payload_data, len });

            var iter = PayloadIterator.new(payload_data);
            blk: while (iter.next()) |payload| {
                if (payload) |paylod_type| {
                    log.info(@src(), "payload type: {any}", .{paylod_type});
                    switch (paylod_type) {
                        .Acknowledgment => {},
                        .Retransmission => {},
                        .qSupported => |*p| {
                            const res = try p.response(&write_buffer);
                            log.info(@src(), "sending qSupported ack: {s}", .{res});
                            _ = try self.connection.stream.write(res);
                        },
                        .qfThreadInfo => |*p| {
                            const res = try p.response(&write_buffer);
                            log.info(@src(), "sending qfThreadInfo ack: {s}", .{res});
                            _ = try self.connection.stream.write(res);
                        },
                        .qsThreadInfo => |*p| {
                            const res = try p.response(&write_buffer);
                            log.info(@src(), "sending qsThreadInfo ack: {s}", .{res});
                            _ = try self.connection.stream.write(res);
                        },
                        .qAttached => |*p| {
                            const res = try p.response(&write_buffer);
                            log.info(@src(), "sending qAttached ack: {s}", .{res});
                            _ = try self.connection.stream.write(res);
                        },
                        .vCont => |*p| {
                            const res = try p.response(&write_buffer);
                            log.info(@src(), "sending vCont ack: {s}", .{res});
                            _ = try self.connection.stream.write(res);
                        },
                        .H => |*p| {
                            const res = try p.response(&write_buffer);
                            log.info(@src(), "sending H ack: {s}", .{res});
                            _ = try self.connection.stream.write(res);
                        },
                        .g => |*p| {
                            const res = try p.response(&write_buffer);
                            log.info(@src(), "sending g ack: {s}", .{res});
                            _ = try self.connection.stream.write(res);
                        },
                        .QuestionMark => |*p| {
                            const res = try p.response(&write_buffer);
                            log.info(@src(), "sending QuestionMark ack: {s}", .{res});
                            _ = try self.connection.stream.write(res);
                        },
                        .Unknown => |*p| {
                            const res = try p.response();
                            log.info(@src(), "sending Unknown ack: {s}", .{res});
                            _ = try self.connection.stream.write(res);
                        },
                    }
                } else {
                    log.info(@src(), "end of the payload", .{});
                    break :blk;
                }
            } else |err| {
                log.err(@src(), "payload err: {any}", .{err});
                log.info(@src(), "sending retransmit", .{});
                _ = try self.connection.stream.write("-");
            }
        }
    }
};
