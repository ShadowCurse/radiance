const std = @import("std");
const Allocator = std.mem.Allocator;
const linux = std.os.linux;

const KVM = @cImport(@cInclude("linux/kvm.h"));

// ioctl in std uses c_int as a request type which is incorrect.
extern "c" fn ioctl(fd: std.os.fd_t, request: c_ulong, ...) c_int;

pub const KvmError = error{
    KvmVersion,
};

pub const Kvm = struct {
    file: std.fs.File,

    const Self = @This();

    pub fn new() !Self {
        return .{ .file = try std.fs.openFileAbsolute("/dev/kvm", .{}) };
    }

    pub fn version(self: *const Self) !i32 {
        const v = ioctl(self.file.handle, KVM.KVM_GET_API_VERSION, @as(usize, 0));
        if (v < 0) {
            return KvmError.KvmVersion;
        } else {
            return v;
        }
    }
};
