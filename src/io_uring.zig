const std = @import("std");
const log = @import("log.zig");
const nix = @import("nix.zig");
const EventFd = @import("eventfd.zig");

fd: nix.fd_t,
submit_queue: SubmitQueue,
complete_queue: CompleteQueue,
eventfd: EventFd,
callbacks: [16]EventCallback = undefined,
callbacks_num: u8 = 0,

const CallbackFn = *const fn (*anyopaque, *const nix.io_uring_cqe) void;
const CallbackParam = *anyopaque;
const EventCallback = struct {
    callback: CallbackFn,
    parameter: CallbackParam,
};

const SubmitQueue = struct {
    ring_tail: *u32,
    ring_mask: *u32,
    ring_array: []u32,
    queue: []nix.io_uring_sqe,
    to_submit: u32,

    pub fn next_sqe(self: *SubmitQueue) ?*nix.io_uring_sqe {
        if (self.to_submit == self.queue.len)
            return null;

        const tail = self.ring_tail.*;
        const index = tail & self.ring_mask.*;
        self.ring_array[index] = index;
        @atomicStore(u32, self.ring_tail, tail +% 1, .release);
        self.to_submit += 1;
        return &self.queue[index];
    }
};

const CompleteQueue = struct {
    ring_head: *u32,
    ring_tail: *u32,
    ring_mask: *u32,
    queue: []nix.io_uring_cqe,

    pub fn read(self: *const CompleteQueue) ?*const nix.io_uring_cqe {
        const head = @atomicLoad(u32, self.ring_head, .acquire);
        if (head == self.ring_tail.*)
            return null;
        const index = head & self.ring_mask.*;
        const cqe = &self.queue[index];
        @atomicStore(u32, self.ring_head, head +% 1, .release);
        return cqe;
    }
};

const Self = @This();

pub fn init(comptime System: type, entries: u32) Self {
    var params: nix.io_uring_params = std.mem.zeroes(nix.io_uring_params);
    const fd = nix.assert(@src(), System, "io_uring_setup", .{
        entries,
        &params,
    });

    var submit_ring_size =
        params.sq_off.array + params.sq_entries * @sizeOf(u32);
    var complete_ring_size =
        params.cq_off.cqes +
        params.cq_entries * @sizeOf(nix.io_uring_cqe);

    // From io_uring man page:
    //
    // io_uring communication happens via 2 shared kernel-user space ring
    // buffers, which can be jointly mapped with a single mmap() call in
    // kernels >= 5.4.
    //
    // Rather than check for kernel version, the recommended way is to
    // check the features field of the io_uring_params structure, which is a
    // bitmask. If IORING_FEAT_SINGLE_MMAP is set, we can do away with the
    // second mmap() call to map in the completion ring separately.
    if (params.flags & nix.IORING_FEAT_SINGLE_MMAP != 0) {
        submit_ring_size = @max(submit_ring_size, complete_ring_size);
        complete_ring_size = submit_ring_size;
    }

    const submit_ring = nix.assert(@src(), System, "mmap", .{
        null,
        submit_ring_size,
        nix.PROT.READ | nix.PROT.WRITE,
        .{ .TYPE = .SHARED, .POPULATE = true },
        fd,
        nix.IORING_OFF_SQ_RING,
    });
    const submit_tail: *u32 = @alignCast(@ptrCast(&submit_ring[params.sq_off.tail]));
    const submit_mask: *u32 = @alignCast(@ptrCast(&submit_ring[params.sq_off.ring_mask]));
    const submit_array: []u32 = @alignCast(@ptrCast(submit_ring[params.sq_off.array..]));

    const submit_queue_size = params.sq_entries * @sizeOf(nix.io_uring_sqe);
    const submit_queue_entries_u8 = nix.assert(@src(), System, "mmap", .{
        null,
        submit_queue_size,
        nix.PROT.READ | nix.PROT.WRITE,
        .{ .TYPE = .SHARED, .POPULATE = true },
        fd,
        nix.IORING_OFF_SQES,
    });
    const submit_queue_entries: []nix.io_uring_sqe = @ptrCast(submit_queue_entries_u8);

    var complete_ring: []u8 = undefined;
    if (params.flags & nix.IORING_FEAT_SINGLE_MMAP != 0)
        complete_ring = submit_ring
    else
        complete_ring = nix.assert(@src(), System, "mmap", .{
            null,
            complete_ring_size,
            nix.PROT.READ | nix.PROT.WRITE,
            .{ .TYPE = .SHARED, .POPULATE = true },
            fd,
            nix.IORING_OFF_CQ_RING,
        });

    const complete_head: *u32 = @alignCast(@ptrCast(&complete_ring[params.cq_off.head]));
    const complete_tail: *u32 = @alignCast(@ptrCast(&complete_ring[params.cq_off.tail]));
    const complete_mask: *u32 =
        @alignCast(@ptrCast(&complete_ring[params.cq_off.ring_mask]));
    const complete_queue_entries: []nix.io_uring_cqe =
        @alignCast(@ptrCast(complete_ring[params.cq_off.cqes..]));

    const eventfd = EventFd.new(nix.System, 0, nix.EFD_NONBLOCK);
    _ = nix.assert(@src(), System, "io_uring_register", .{
        fd,
        nix.IORING_REGISTER.REGISTER_EVENTFD,
        &eventfd.fd,
        1,
    });

    return .{
        .fd = fd,
        .submit_queue = .{
            .ring_tail = submit_tail,
            .ring_mask = submit_mask,
            .ring_array = submit_array,
            .queue = submit_queue_entries,
            .to_submit = 0,
        },
        .complete_queue = .{
            .ring_head = complete_head,
            .ring_tail = complete_tail,
            .ring_mask = complete_mask,
            .queue = complete_queue_entries,
        },
        .eventfd = eventfd,
    };
}

pub fn add_event(
    self: *Self,
    callback: CallbackFn,
    parameter: CallbackParam,
) Device {
    const idx = self.callbacks_num;
    self.callbacks[idx] = .{
        .callback = callback,
        .parameter = parameter,
    };
    self.callbacks_num += 1;
    return .{
        .io_uring = self,
        .device_idx = idx,
    };
}

pub fn next_sqe(self: *Self) ?*nix.io_uring_sqe {
    return self.submit_queue.next_sqe();
}

pub fn submit(self: *Self, comptime System: type) void {
    const submitted = nix.assert(@src(), System, "io_uring_enter", .{
        self.fd,
        self.submit_queue.to_submit,
        0,
        0,
        null,
    });
    log.debug(
        @src(),
        "submitted: {d} out of {d}",
        .{ submitted, self.submit_queue.to_submit },
    );
    self.submit_queue.to_submit = 0;
}

pub fn event_process_event(self: *Self) void {
    self.process_event(nix.System);
}
pub fn process_event(self: *Self, comptime System: type) void {
    _ = self.eventfd.read(System);

    while (self.complete_queue.read()) |cqe| {
        const entry_idx: EntryIdx = @bitCast(cqe.user_data);
        const callback_idx = entry_idx.device_idx;
        const callback = self.callbacks[callback_idx];

        log.debug(@src(), "io_uring completion entry_idx: {any}", .{entry_idx});
        callback.callback(callback.parameter, cqe);
    }
}

pub const EntryIdx = packed struct(u64) {
    device_idx: u32,
    custom_idx: u32,
};

pub const Device = struct {
    io_uring: *Self,
    device_idx: u32,

    pub fn next_sqe(self: *const Device) *nix.io_uring_sqe {
        return self.io_uring.next_sqe().?;
    }

    pub fn finish_sqe(self: *const Device, sqe: *nix.io_uring_sqe, idx: u32) void {
        sqe.user_data = @bitCast(EntryIdx{
            .device_idx = self.device_idx,
            .custom_idx = idx,
        });
    }

    pub fn submit(self: *const Device, comptime System: type) void {
        self.io_uring.submit(System);
    }
};
