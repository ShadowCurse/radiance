const std = @import("std");
const Allocator = std.mem.Allocator;
const KVM = @cImport(@cInclude("linux/kvm.h"));
const linux = std.os.linux;

pub extern "c" fn ioctl(fd: std.os.fd_t, request: c_ulong, ...) c_int;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    _ = allocator;

    // create guest memory
    var gm = try GuestMemory.new(128 << 20);
    const kernel_load_address = try gm.load_linux_kernel("vmlinux-5.10.186");
    std.log.info("kernel_load_address: {}", .{kernel_load_address});
}

const Error = error{
    GuestMemoryLoadKernel,
};

const GuestMemory = struct {
    guest_addr: u64,
    mem: []u8,

    const Self = @This();

    const arm64_image_header = struct {
        code0: u32,
        code1: u32,
        text_offset: u64,
        image_size: u64,
        flags: u64,
        res2: u64,
        res3: u64,
        res4: u64,
        magic: u32,
        res5: u32,
    };

    fn new(size: usize) !Self {
        // Start of RAM on 64 bit ARM.
        const DRAM_MEM_START: u64 = 0x8000_0000;

        const prot = linux.PROT.READ | linux.PROT.WRITE;
        const flags = linux.MAP.PRIVATE | linux.MAP.ANONYMOUS | 0x4000; //std.os.system.MAP.NORESERVE;
        const mem = try std.os.mmap(null, size, prot, flags, -1, 0);

        std.log.info("mem size: 0x{x}", .{size});

        return Self{ .guest_addr = DRAM_MEM_START, .mem = mem };
    }

    fn load_linux_kernel(self: *Self, path: []const u8) !u64 {
        var file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const file_meta = try file.metadata();
        const kernel_size = file_meta.size();

        var arm64_header: arm64_image_header = undefined;
        var header_slice = std.mem.asBytes(&arm64_header);
        const n = try file.read(@as([]u8, header_slice));
        std.debug.assert(n == header_slice.len);
        if (arm64_header.magic != 0x644d_5241) {
            return Error.GuestMemory;
        }

        var text_offset = arm64_header.text_offset;
        if (text_offset == 0) {
            text_offset = 0x80000;
        }
        std.log.info("text_offset: 0x{x}", .{text_offset});

        const DRAM_MEM_START: u64 = 0x8000_0000; // 2 GB.
        const kernel_offset = DRAM_MEM_START;

        // Validate that kernel_offset is 2 MB aligned, as required by the
        // arm64 boot protocol
        if (kernel_offset % 0x0020_0000 != 0) {
            return Error.GuestMemoryLoadKernel;
        }

        const mem_offset = kernel_offset + text_offset;
        const kernel_end = mem_offset + kernel_size;

        std.log.info("mem_offset: 0x{x}", .{mem_offset});
        std.log.info("kernel_end: 0x{x}", .{kernel_end});

        try file.seekTo(0);

        // _ = try file.read(self.mem[mem_offset..kernel_end]);
        _ = try file.read(self.mem[0..kernel_size]);

        return mem_offset;
    }
};

test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
