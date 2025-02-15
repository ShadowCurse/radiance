const std = @import("std");
const nix = @import("../nix.zig");
const log = @import("../log.zig");

const Vm = @import("../vm.zig");
const Memory = @import("../memory.zig");

pub const ALIGNMENT = 2 * 1024 * 1024;

pub const Info = struct {
    start: u64,
    len: u64,
};

pub fn attach(
    vm: *Vm,
    file_path: []const u8,
    read_only: bool,
    guest_addr: u64,
) u64 {
    const fd = nix.assert(@src(), nix.open, .{
        file_path,
        .{ .ACCMODE = if (read_only) .RDONLY else .RDWR },
        0,
    });
    defer nix.close(fd);

    const statx = nix.assert(@src(), nix.statx, .{fd});
    log.info(@src(), "pmem file size: {d}", .{statx.size});
    log.assert(
        @src(),
        Memory.is_aligned(statx.size, ALIGNMENT),
        "File size: {s} for pmem device is not 2MB aligned",
        .{file_path},
    );

    const file_mem = nix.assert(@src(), nix.mmap, .{
        null,
        statx.size,
        if (read_only) nix.PROT.READ else nix.PROT.READ | nix.PROT.WRITE,
        .{ .TYPE = .PRIVATE },
        fd,
        0,
    });

    vm.set_memory(.{
        .guest_phys_addr = guest_addr,
        .memory_size = statx.size,
        .userspace_addr = @intFromPtr(file_mem.ptr),
    });
    return statx.size;
}
