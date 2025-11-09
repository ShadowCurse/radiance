const std = @import("std");
const log = @import("log.zig");
const nix = @import("nix.zig");
const Vcpu = @import("vcpu.zig");

const KERNEL_BACKLOG = 128;

fd: nix.fd_t,

vcpus: []Vcpu,
vcpu_threads: []std.Thread,
vcpus_barrier: *std.Thread.ResetEvent,

const Self = @This();

pub fn init(
    comptime System: type,
    socket_path: []const u8,
    vcpus: []Vcpu,
    vcpu_threads: []std.Thread,
    vcpus_barrier: *std.Thread.ResetEvent,
) Self {
    const address = std.net.Address.initUnix(socket_path) catch |err| {
        log.panic(@src(), "Api socket name is too long: {t}", .{err});
    };
    const sock_flags = nix.SOCK.STREAM | nix.SOCK.CLOEXEC;
    const proto: u32 = 0;

    const fd = nix.assert(@src(), System, "socket", .{ address.any.family, sock_flags, proto });
    errdefer System.close(fd);

    const socklen = address.getOsSockLen();
    _ = nix.assert(@src(), System, "bind", .{ fd, &address.any, socklen });
    _ = nix.assert(@src(), System, "listen", .{ fd, KERNEL_BACKLOG });
    return .{
        .fd = fd,
        .vcpus = vcpus,
        .vcpu_threads = vcpu_threads,
        .vcpus_barrier = vcpus_barrier,
    };
}

pub fn handle_default(self: *Self) void {
    self.handle(nix.System);
}
pub fn handle(self: *Self, comptime System: type) void {
    log.info(@src(), "api server handle", .{});

    var accepted_addr: std.net.Address = undefined;
    var addr_len: nix.socklen_t = @sizeOf(std.net.Address);
    const fd = nix.assert(
        @src(),
        System,
        "accept",
        .{
            self.fd,
            &accepted_addr.any,
            &addr_len,
            nix.SOCK.CLOEXEC | nix.SOCK.NONBLOCK,
        },
    );
    defer System.close(fd);
    while (true) {
        var buffer: [1024]u8 = undefined;

        const len = System.read(fd, &buffer) catch |err| {
            log.assert(@src(), err == nix.ReadError.WouldBlock, "read err: {t}", .{err});
            break;
        };
        if (len == 0) break;
        const msg = buffer[0 .. len - 1];
        log.debug(@src(), "Got message: {s} len: {d}", .{ msg, msg.len });

        if (std.mem.eql(u8, msg, "pause")) {
            self.vcpus_barrier.reset();
            for (self.vcpus) |vcpu| vcpu.pause(nix.System);
        } else if (std.mem.eql(u8, msg, "resume")) {
            for (self.vcpus) |vcpu| vcpu.kvm_run.immediate_exit = 0;
            self.vcpus_barrier.set();
        }
    }
}
