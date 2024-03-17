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
epollfd: std.os.fd_t,
events: [8]nix.epoll_event,
event_callbacks_num: u64,
event_callbacks: [8]EventCallback,

const Self = @This();

pub const EventLoopError = error{
    New,
    AddEvent,
    Run,
};

pub fn new() !Self {
    const epollfd = nix.epoll_create1(0);
    if (epollfd < 0) {
        return EventLoopError.New;
    }

    return Self{
        .stop = false,
        .epollfd = epollfd,
        .events = undefined,
        .event_callbacks_num = 0,
        .event_callbacks = undefined,
    };
}

pub fn add_event(self: *Self, fd: std.os.fd_t, callback: CallbackFn, parameter: CallbackParam) !void {
    var event = std.mem.zeroInit(nix.epoll_event, .{});
    event.events = nix.EPOLLIN;

    self.event_callbacks[self.event_callbacks_num].callback = callback;
    self.event_callbacks[self.event_callbacks_num].parameter = parameter;
    event.data.u64 = self.event_callbacks_num;
    self.event_callbacks_num += 1;

    if (nix.epoll_ctl(self.epollfd, nix.EPOLL_CTL_ADD, fd, &event) < 0) {
        return EventLoopError.AddEvent;
    }
}

pub fn run(self: *Self) !void {
    while (!self.stop) {
        const nfds = nix.epoll_wait(self.epollfd, &self.events, self.events.len, -1);
        if (nfds < 0) {
            return EventLoopError.Run;
        }

        const n: usize = @intCast(nfds);
        for (0..n) |i| {
            const event = &self.events[i];
            const callback = self.event_callbacks[event.data.u64];
            try callback.callback(callback.parameter);
        }
    }
}

pub fn stop(self: *Self) !void {
    self.stop = true;
}
