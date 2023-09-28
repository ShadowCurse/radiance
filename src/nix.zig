const std = @import("std");
const KVM = @cImport(@cInclude("linux/kvm.h"));

// Can not just use std.os.linux because of ioctl redefinition
// pub usingnamespace std.os.linux;
pub const PROT = std.os.linux.PROT;
pub const MAP = std.os.linux.MAP;
pub const Sigaction = std.os.linux.Sigaction;

pub usingnamespace KVM;

// ioctl in std uses c_int as a request type which is incorrect.
pub extern "c" fn ioctl(fd: std.os.fd_t, request: c_ulong, ...) c_int;
pub extern "c" fn __libc_current_sigrtmin() c_int;
pub extern "c" fn pthread_kill(thread: std.c.pthread_t, sig: i32) std.c.E;
