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
    comptime System: type,
    vm: *Vm,
    file_path: []const u8,
    guest_addr: u64,
) u64 {
    const fd = nix.assert(@src(), System.open, .{
        file_path,
        .{ .ACCMODE = .RDWR },
        0,
    });
    defer System.close(fd);

    const statx = nix.assert(@src(), System.statx, .{fd});

    if (Memory.is_aligned(statx.size, ALIGNMENT)) {
        const file_mem = nix.assert(@src(), System.mmap, .{
            null,
            statx.size,
            nix.PROT.READ | nix.PROT.WRITE,
            .{ .TYPE = .PRIVATE },
            fd,
            0,
        });
        vm.set_memory(
            System,
            .{
                .guest_phys_addr = guest_addr,
                .memory_size = statx.size,
                .userspace_addr = @intFromPtr(file_mem.ptr),
            },
        );
        return statx.size;
    } else {
        const alined_size = Memory.align_addr(statx.size, ALIGNMENT);
        log.warn(
            @src(),
            "PMEM backign file {s} has size 0x{x} which is not 2MB aligned. Aligning it up to 0x{x}",
            .{ file_path, statx.size, alined_size },
        );
        const pmem_mem = nix.assert(@src(), System.mmap, .{
            null,
            alined_size,
            nix.PROT.READ | nix.PROT.WRITE,
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        });
        const file_mem = nix.assert(@src(), System.mmap, .{
            pmem_mem.ptr,
            statx.size,
            nix.PROT.READ | nix.PROT.WRITE,
            .{ .TYPE = .PRIVATE, .FIXED = true },
            fd,
            0,
        });
        vm.set_memory(
            System,
            .{
                .guest_phys_addr = guest_addr,
                .memory_size = alined_size,
                .userspace_addr = @intFromPtr(file_mem.ptr),
            },
        );
        return alined_size;
    }
}
