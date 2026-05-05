const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");
const log = @import("log.zig");
const nix = @import("nix.zig");
const Vcpu = @import("vcpu.zig");
const Gicv2 = @import("gicv2.zig");
const Memory = @import("memory.zig");

const KERNEL_BACKLOG = 128;

fd: nix.fd_t,

vcpus: []Vcpu,
vcpu_threads: []std.Thread,
vcpus_barrier: *Vcpu.Barrier,
runtime_arch: *root.RuntimeArch,
state_arch: *root.StateArch,
permanent_memory: Memory.Permanent,

const Self = @This();

pub fn init(
    comptime System: type,
    socket_path: []const u8,
    vcpus: []Vcpu,
    vcpu_threads: []std.Thread,
    vcpus_barrier: *Vcpu.Barrier,
    runtime_arch: *root.RuntimeArch,
    state_arch: *root.StateArch,
    permanent_memory: Memory.Permanent,
) Self {
    const sock_addr = nix.configure_unix_socket(socket_path);
    const fd = nix.assert(
        @src(),
        System,
        "socket",
        .{ sock_addr.family, nix.SOCK.STREAM | nix.SOCK.CLOEXEC, 0 },
    );
    _ = nix.assert(@src(), System, "bind", .{ fd, @ptrCast(&sock_addr), @sizeOf(std.os.linux.sockaddr.un) });
    _ = nix.assert(@src(), System, "listen", .{ fd, KERNEL_BACKLOG });
    return .{
        .fd = fd,
        .vcpus = vcpus,
        .vcpu_threads = vcpu_threads,
        .vcpus_barrier = vcpus_barrier,
        .runtime_arch = runtime_arch,
        .state_arch = state_arch,
        .permanent_memory = permanent_memory,
    };
}

pub fn handle_default(self: *Self) void {
    self.handle(nix.System);
}
pub fn handle(self: *Self, comptime System: type) void {
    log.info(@src(), "api server handle", .{});

    var accepted_addr: std.os.linux.sockaddr.un = undefined;
    var addr_len: nix.socklen_t = @sizeOf(std.os.linux.sockaddr.un);
    const fd = nix.assert(
        @src(),
        System,
        "accept4",
        .{
            self.fd,
            @ptrCast(&accepted_addr),
            &addr_len,
            nix.SOCK.CLOEXEC | nix.SOCK.NONBLOCK,
        },
    );
    defer System.close(fd);
    while (true) {
        var buffer: [1024]u8 = undefined;

        const len = System.read(fd, &buffer) catch |err| {
            log.assert(@src(), err == nix.SystemError.EAGAIN, "read err: {t}", .{err});
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

            if (builtin.cpu.arch == .aarch64) {
                self.runtime_arch.gicv2.save_state(
                    nix.System,
                    self.state_arch.gicv2_state,
                    @intCast(self.vcpus.len),
                );
                // No reason to query list more than 1 time
                if (self.state_arch.vcpu_reg_list[0] == 0) {
                    Vcpu.aarch64.get_reg_list(&self.vcpus[0], nix.System, self.state_arch.vcpu_reg_list);
                }
                var regs_bytes = self.state_arch.vcpu_regs;
                for (self.vcpus, self.state_arch.vcpu_mp_states) |*vcpu, *mpstate| {
                    const used = Vcpu.aarch64.save_regs(
                        vcpu,
                        nix.System,
                        self.state_arch.vcpu_reg_list,
                        regs_bytes,
                        mpstate,
                    );
                    regs_bytes = regs_bytes[used..];
                }
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
