const std = @import("std");
const log = @import("log.zig");
const nix = @import("nix.zig");

const CallbackFn = *const fn (*anyopaque) anyerror!void;
const CallbackParam = *anyopaque;

const EventCallback = struct {
    callback: CallbackFn,
    parameter: CallbackParam,
};

stop: bool,
epollfd: nix.fd_t,
events: [MAX_EVENTS]nix.epoll_event,
events_info_num: u64,
events_info: [MAX_EVENTS]struct {
    fd: nix.fd_t,
    callback: EventCallback,
},

const Self = @This();

const MAX_EVENTS = 16;

pub const EventLoopError = error{
    New,
    TooMuchEvents,
    AddEvent,
    Run,
};

pub fn new() !Self {
    const epollfd = try nix.epoll_create1(0);

    return Self{
        .stop = false,
        .epollfd = epollfd,
        .events = undefined,
        .events_info_num = 0,
        .events_info = undefined,
    };
}

pub fn add_event(
    self: *Self,
    fd: nix.fd_t,
    callback: CallbackFn,
    parameter: CallbackParam,
) !void {
    var event = std.mem.zeroInit(nix.epoll_event, .{});
    event.events = nix.EPOLLIN;

    if (self.events_info_num == MAX_EVENTS) {
        return EventLoopError.TooMuchEvents;
    }

    self.events_info[self.events_info_num] = .{
        .fd = fd,
        .callback = .{
            .callback = callback,
            .parameter = parameter,
        },
    };

    event.data.u64 = self.events_info_num;
    self.events_info_num += 1;

    try nix.epoll_ctl(self.epollfd, nix.EPOLL_CTL_ADD, fd, &event);
}

pub fn remove_event(
    self: *Self,
    fd: nix.fd_t,
) !void {
    for (&self.events_info) |*ec| {
        if (ec.fd == fd) {
            try nix.epoll_ctl(self.epollfd, nix.EPOLL_CTL_DEL, fd, null);
            return;
        }
    }
}

pub fn run(self: *Self) !void {
    while (!self.stop) {
        const nfds = nix.epoll_wait(self.epollfd, &self.events, -1);
        if (nfds < 0) {
            return EventLoopError.Run;
        }

        const n: usize = @intCast(nfds);
        for (0..n) |i| {
            const event = &self.events[i];
            const callback = self.events_info[event.data.u64].callback;
            try callback.callback(callback.parameter);
        }
    }
}

pub fn stop(self: *Self) !void {
    self.stop = true;
}
