const std = @import("std");
const log = @import("log.zig");
const nix = @import("nix.zig");
const Vcpu = @import("vcpu.zig");
const Gicv2 = @import("gicv2.zig");
const Memory = @import("memory.zig");

const KERNEL_BACKLOG = 128;

fd: nix.fd_t,

vcpus: []Vcpu,
vcpu_threads: []std.Thread,
vcpus_barrier: *std.Thread.ResetEvent,
vcpu_reg_list: *Vcpu.RegList,
vcpu_regs: []u8,
vcpu_mpstates: []nix.kvm_mp_state,
gicv2: *const Gicv2,
gicv2_state: []u32,
permanent_memory: Memory.Permanent,

const Self = @This();

pub fn init(
    comptime System: type,
    socket_path: []const u8,
    vcpus: []Vcpu,
    vcpu_threads: []std.Thread,
    vcpus_barrier: *std.Thread.ResetEvent,
    vcpu_reg_list: *Vcpu.RegList,
    vcpu_regs: []u8,
    vcpu_mpstates: []nix.kvm_mp_state,
    gicv2: *const Gicv2,
    gicv2_state: []u32,
    permanent_memory: Memory.Permanent,
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
        .vcpu_reg_list = vcpu_reg_list,
        .vcpu_regs = vcpu_regs,
        .vcpu_mpstates = vcpu_mpstates,
        .gicv2 = gicv2,
        .gicv2_state = gicv2_state,
        .permanent_memory = permanent_memory,
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
        } else if (std.mem.startsWith(u8, msg, "snapshot ")) {
            const snapshot_path = msg["snapshot ".len..];

            const snapshot_fd = nix.assert(@src(), System, "open", .{
                snapshot_path,
                .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true },
                std.os.linux.S.IRWXU,
            });
            defer System.close(snapshot_fd);

            _ = std.os.linux.ftruncate(snapshot_fd, @intCast(self.permanent_memory.mem.len));

            self.gicv2.save_state(nix.System, self.gicv2_state, @intCast(self.vcpus.len));
            // No reason to query list more than 1 time
            if (self.vcpu_reg_list[0] == 0) {
                self.vcpus[0].get_reg_list(nix.System, self.vcpu_reg_list);
            }
            var regs_bytes = self.vcpu_regs;
            for (self.vcpus, self.vcpu_mpstates) |*vcpu, *mpstate| {
                const used = vcpu.save_regs(nix.System, self.vcpu_reg_list, regs_bytes, mpstate);
                regs_bytes = regs_bytes[used..];
            }

            _ = nix.assert(
                @src(),
                System,
                "write",
                .{ snapshot_fd, self.permanent_memory.mem },
            );
            _ = std.os.linux.fsync(snapshot_fd);
        }
    }
}
