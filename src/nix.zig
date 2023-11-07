const std = @import("std");
const C = @cImport({
    @cInclude("linux/kvm.h");
    @cInclude("linux/virtio_ring.h");
    @cInclude("linux/virtio_config.h");
    @cInclude("linux/virtio_blk.h");
    @cInclude("sys/eventfd.h");
    @cInclude("fcntl.h");
    @cInclude("signal.h");
    @cInclude("pthread.h");
});

// Can not just use std.os.linux because of ioctl redefinition
// pub usingnamespace std.os.linux;
pub const PROT = std.os.linux.PROT;
pub const MAP = std.os.linux.MAP;
pub const Sigaction = std.os.linux.Sigaction;
pub const close = std.c.close;
pub const read = std.c.read;
pub const write = std.c.write;

pub usingnamespace C;

// ioctl in std uses c_int as a request type which is incorrect.
pub extern "c" fn ioctl(fd: std.os.fd_t, request: c_ulong, ...) c_int;
