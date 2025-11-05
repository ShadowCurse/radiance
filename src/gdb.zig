const std = @import("std");
const log = @import("log.zig");
const nix = @import("nix.zig");

const EventLoop = @import("event_loop.zig");
const Memory = @import("memory.zig");
const Mmio = @import("mmio.zig");
const Vcpu = @import("vcpu.zig");

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

const Interrupt = struct {
    const Self = @This();

    fn response(self: *const Self, buffer: []u8, gdb: *GdbServer) ![]const u8 {
        _ = self;

        gdb.vcpus_barier.reset();
        // for (gdb.vcpu_threads) |*t| {
        //     Vcpu.kick_thread(t, gdb.vcpu_exit_signal);
        // }
        // Vcpu.kick_threads();

        const msg = "S05";
        return fmt_response(buffer, msg);
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

    fn response(self: *const Self, buffer: []u8, gdb: *GdbServer) ![]const u8 {
        _ = self;
        var buff: [16]u8 = undefined;
        var slice: []u8 = &buff;
        for (0..gdb.vcpu_threads.len) |i| {
            const str = try std.fmt.bufPrint(slice, "{X},", .{i});
            slice = slice[str.len..];
        }
        slice = buff[0 .. buff.len - slice.len - 1];
        return fmt_response(buffer, slice);
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
        // The remote server attached to an existing process.
        const msg = "1";
        return fmt_response(buffer, msg);
    }
};

const vCont = struct {
    t: Type,

    const Self = @This();

    const Type = enum {
        Continue,
        Step,
        QuestionMark,
    };

    fn from_bytes(bytes: []const u8) ?Self {
        return if (std.mem.startsWith(u8, bytes, "vCont")) blk: {
            const t = switch (bytes[5]) {
                '?' => Type.QuestionMark,
                ';' => switch (bytes[6]) {
                    'c' => Type.Continue,
                    's' => Type.Step,
                    else => break :blk null,
                },
                else => break :blk null,
            };
            break :blk .{
                .t = t,
            };
        } else blk: {
            break :blk null;
        };
    }

    fn response(self: *const Self, buffer: []u8, gdb: *GdbServer) ![]const u8 {
        const msg = switch (self.t) {
            .Continue => blk: {
                gdb.vcpus_barier.set();
                break :blk "OK";
            },
            .Step => "OK",
            .QuestionMark =>
            // support
            // c - continue
            // s - step
            // "vCont;c;s",
            "vCont;c;s",
        };
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
        // 33 8 byte regs
        // x0 - x31, sp, pc
        const msg = "0000000000000000" ** 33;
        return fmt_response(buffer, msg);
    }
};

// 'p n'
// Read the value of the register n
const p = struct {
    register: u64,

    const Self = @This();

    fn from_bytes(bytes: []const u8) ?Self {
        return if (std.mem.startsWith(u8, bytes, "p")) blk: {
            const register = std.fmt.parseInt(u8, bytes[1..], 16) catch return null;
            break :blk .{
                .register = register,
            };
        } else blk: {
            break :blk null;
        };
    }

    fn response(self: *const Self, buffer: []u8) ![]const u8 {
        _ = self;
        const msg = "00";
        return fmt_response(buffer, msg);
    }
};

// ‘m addr,length’
// Read length addressable memory units starting at address addr
const m = struct {
    addr: u64,
    length: u64,

    const Self = @This();

    fn from_bytes(bytes: []const u8) ?Self {
        return if (std.mem.startsWith(u8, bytes, "m")) blk: {
            var iter = std.mem.splitScalar(u8, bytes[1..], ',');
            const addr = std.fmt.parseInt(u64, iter.next().?, 16) catch return null;
            const length = std.fmt.parseInt(u64, iter.next().?, 16) catch return null;
            break :blk .{
                .addr = addr,
                .length = length,
            };
        } else blk: {
            break :blk null;
        };
    }

    fn response(self: *const Self, buffer: []u8) ![]const u8 {
        var buff: [256]u8 = .{'0'} ** 256;
        return fmt_response(buffer, buff[0..self.length]);
    }
};

// ‘c [addr]’
// Continue at addr, which is the address to resume. If addr is omitted, resume at current address.
const c = struct {
    const Self = @This();

    fn from_bytes(bytes: []const u8) ?Self {
        return if (std.mem.startsWith(u8, bytes, "c")) blk: {
            break :blk .{};
        } else blk: {
            break :blk null;
        };
    }

    fn response(self: *const Self, buffer: []u8, gdb: *GdbServer) ![]const u8 {
        _ = self;
        gdb.vcpus_barier.set();
        const msg = "OK";
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
    Interrupt,
    qSupported,
    qfThreadInfo,
    qsThreadInfo,
    qAttached,
    vCont,
    H,
    g,
    p,
    m,
    c,
    QuestionMark,
    Unknown,
};

const PayloadIterator = struct {
    i: usize = 0,
    buf: []const u8,

    const Self = @This();

    fn init(buf: []const u8) Self {
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
        } else if (self.buf[self.i] == 0x03) blk: {
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

const Payload = union(PayloadEnum) {
    Acknowledgment,
    Retransmission,
    Interrupt: Interrupt,
    qSupported: qSupported,
    qfThreadInfo: qfThreadInfo,
    qsThreadInfo: qsThreadInfo,
    qAttached: qAttached,
    vCont: vCont,
    H: H,
    g: g,
    p: p,
    m: m,
    c: c,
    QuestionMark: QuestionMark,
    Unknown: Unknown,

    const Self = @This();

    fn from(bytes: []const u8) !Self {
        return if (bytes.len == 1) blk: {
            break :blk switch (bytes[0]) {
                '+' => .Acknowledgment,
                '-' => .Retransmission,
                0x03 => .{ .Interrupt = .{} },
                else => error.Invalid,
            };
        } else blk: {
            const stripped = try Self.strip_bytes(bytes);
            log.info(@src(), "got stripped: {s}", .{stripped});
            if (qSupported.from_bytes(stripped)) |payload| {
                break :blk .{ .qSupported = payload };
            } else if (qfThreadInfo.from_bytes(stripped)) |paylod| {
                break :blk .{ .qfThreadInfo = paylod };
            } else if (qsThreadInfo.from_bytes(stripped)) |payload| {
                break :blk .{ .qsThreadInfo = payload };
            } else if (qAttached.from_bytes(stripped)) |payload| {
                break :blk .{ .qAttached = payload };
            } else if (vCont.from_bytes(stripped)) |payload| {
                break :blk .{ .vCont = payload };
            } else if (H.from_bytes(stripped)) |payload| {
                break :blk .{ .H = payload };
            } else if (g.from_bytes(stripped)) |payload| {
                break :blk .{ .g = payload };
            } else if (p.from_bytes(stripped)) |payload| {
                break :blk .{ .p = payload };
            } else if (m.from_bytes(stripped)) |payload| {
                break :blk .{ .m = payload };
            } else if (c.from_bytes(stripped)) |payload| {
                break :blk .{ .c = payload };
            } else if (QuestionMark.from_bytes(stripped)) |payload| {
                break :blk .{ .QuestionMark = payload };
            } else {
                log.warn(@src(), "Unknown payload: {s}", .{stripped});
                break :blk .{ .Unknown = .{} };
            }
        };
    }

    fn strip_bytes(bytes: []const u8) ![]const u8 {
        return if (bytes.len < 4) blk: {
            break :blk error.Invalid;
        } else blk: {
            break :blk bytes[1 .. bytes.len - 2];
        };
    }
};

pub const GdbServer = struct {
    address: std.net.Address,
    server: std.net.Server,
    connection: std.net.Server.Connection,

    read_buffer: [1024]u8 = undefined,
    write_buffer: [1024]u8 = undefined,
    last_response: []const u8 = undefined,

    vcpus: []Vcpu,
    vcpu_threads: []std.Thread,
    vcpus_barier: *std.Thread.ResetEvent,
    memory: *Memory.Guest,
    mmio: *Mmio,
    event_loop: *EventLoop,

    const Self = @This();

    // TODO move Server and Connectino to use System
    pub fn init(
        comptime System: type,
        socket_path: []const u8,
        vcpus: []Vcpu,
        vcpu_threads: []std.Thread,
        vcpus_barier: *std.Thread.ResetEvent,
        memory: *Memory.Guest,
        mmio: *Mmio,
        event_loop: *EventLoop,
    ) !Self {
        log.info(@src(), "Initializing gdb connection ...", .{});
        const address = try std.net.Address.initUnix(socket_path);
        var server = try address.listen(.{});
        errdefer server.deinit();

        var accepted_addr: std.net.Address = undefined;
        var addr_len: nix.socklen_t = @sizeOf(std.net.Address);
        const fd = try System.accept(
            server.stream.handle,
            &accepted_addr.any,
            &addr_len,
            nix.SOCK.CLOEXEC | nix.SOCK.NONBLOCK,
        );
        const connection = std.net.Server.Connection{
            .stream = .{ .handle = fd },
            .address = accepted_addr,
        };
        log.info(@src(), "gdb connection established", .{});

        return .{
            .address = address,
            .server = server,
            .connection = connection,

            .vcpus = vcpus,
            .vcpu_threads = vcpu_threads,
            .vcpus_barier = vcpus_barier,
            .memory = memory,
            .mmio = mmio,
            .event_loop = event_loop,
        };
    }

    pub fn process_request(self: *Self) !void {
        while (true) {
            log.info(@src(), "reading payload", .{});

            const len = self.connection.stream.read(&self.read_buffer) catch |err| {
                if (err == std.posix.ReadError.WouldBlock) {
                    return;
                }
                return err;
            };
            if (len == 0) {
                self.event_loop.exit = true;
                log.info(@src(), "got payload of len 0. exiting", .{});
                return;
            }

            const payload_data = self.read_buffer[0..len];
            log.info(@src(), "got payload: {s} len: {}", .{ payload_data, len });

            var iter = PayloadIterator.init(payload_data);
            blk: while (iter.next()) |payload| {
                if (payload) |paylod_type| {
                    log.info(@src(), "payload type: {any}", .{paylod_type});
                    switch (paylod_type) {
                        .Acknowledgment => {},
                        .Retransmission => {
                            // log.info(
                            //     @src(),
                            //     "sending Retransmission: {s}",
                            //     .{self.last_response},
                            // );
                            // _ = try self.connection.stream.write(self.last_response);
                        },
                        .Interrupt => |*inner_payload| {
                            self.last_response =
                                try inner_payload.response(&self.write_buffer, self);
                            log.info(@src(), "sending Interrupt ack: {s}", .{self.last_response});
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .qSupported => |*inner_payload| {
                            self.last_response =
                                try inner_payload.response(&self.write_buffer);
                            log.info(@src(), "sending qSupported ack: {s}", .{self.last_response});
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .qfThreadInfo => |*inner_payload| {
                            self.last_response =
                                try inner_payload.response(&self.write_buffer, self);
                            log.info(
                                @src(),
                                "sending qfThreadInfo ack: {s}",
                                .{self.last_response},
                            );
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .qsThreadInfo => |*inner_payload| {
                            self.last_response = try inner_payload.response(&self.write_buffer);
                            log.info(
                                @src(),
                                "sending qsThreadInfo ack: {s}",
                                .{self.last_response},
                            );
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .qAttached => |*inner_payload| {
                            self.last_response = try inner_payload.response(&self.write_buffer);
                            log.info(@src(), "sending qAttached ack: {s}", .{self.last_response});
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .vCont => |*inner_payload| {
                            self.last_response =
                                try inner_payload.response(&self.write_buffer, self);
                            log.info(@src(), "sending vCont ack: {s}", .{self.last_response});
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .H => |*inner_payload| {
                            self.last_response = try inner_payload.response(&self.write_buffer);
                            log.info(@src(), "sending H ack: {s}", .{self.last_response});
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .g => |*inner_payload| {
                            self.last_response = try inner_payload.response(&self.write_buffer);
                            log.info(@src(), "sending g ack: {s}", .{self.last_response});
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .p => |*inner_payload| {
                            self.last_response = try inner_payload.response(&self.write_buffer);
                            log.info(@src(), "sending p ack: {s}", .{self.last_response});
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .m => |*inner_payload| {
                            self.last_response = try inner_payload.response(&self.write_buffer);
                            log.info(@src(), "sending m ack: {s}", .{self.last_response});
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .c => |*inner_payload| {
                            self.last_response =
                                try inner_payload.response(&self.write_buffer, self);
                            log.info(@src(), "sending c ack: {s}", .{self.last_response});
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .QuestionMark => |*inner_payload| {
                            self.last_response = try inner_payload.response(&self.write_buffer);
                            log.info(
                                @src(),
                                "sending QuestionMark ack: {s}",
                                .{self.last_response},
                            );
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .Unknown => |*inner_payload| {
                            self.last_response = try inner_payload.response();
                            log.info(@src(), "sending Unknown ack: {s}", .{self.last_response});
                            _ = try self.connection.stream.write(self.last_response);
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
