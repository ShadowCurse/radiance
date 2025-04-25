const std = @import("std");
const log = @import("log.zig");
const nix = @import("nix.zig");
const EventFd = @import("eventfd.zig");

pub const IoUring = struct {
    fd: nix.fd_t,
    submit_queue: SubmitQueue,
    complete_queue: CompleteQueue,

    const SubmitQueue = struct {
        ring_tail: *u32,
        ring_mask: *u32,
        ring_array: []u32,
        queue: []nix.io_uring_sqe,
        to_submit: u32,

        pub fn next_sqe(self: *SubmitQueue) ?*nix.io_uring_sqe {
            const tail = self.ring_tail.*;
            const index = tail & self.ring_mask.*;
            self.ring_array[index] = index;
            @atomicStore(u32, self.ring_tail, tail, .release);
            self.to_submit += 1;
            return &self.queue[index];
        }
    };

    const CompleteQueue = struct {
        ring_head: *u32,
        ring_tail: *u32,
        ring_mask: *u32,
        queue: []nix.io_uring_cqe,

        pub fn read(self: *const CompleteQueue) ?*nix.io_uring_cqe {
            const head = @atomicLoad(u32, self.ring_head, .acquire);
            if (head == self.ring_tail.*)
                return null;
            const index = head & self.ring_mask.*;
            const cqe = &self.queue[index];
            @atomicStore(u32, self.ring_head, head + 1, .release);
            return cqe;
        }
    };

    const Self = @This();

    pub fn init(comptime System: type) Self {
        var params: nix.io_uring_params = std.mem.zeroes(nix.io_uring_params);
        const fd = nix.assert(@src(), System, "io_uring_setup", .{
            32,
            &params,
        });

        var submit_ring_size =
            params.sq_off.array + params.sq_entries * @sizeOf(u32);
        var complete_ring_size =
            params.cq_off.cqes +
            params.cq_entries * @sizeOf(nix.io_uring_cqe);

        if (params.flags & nix.IORING_FEAT_SINGLE_MMAP != 0) {
            submit_ring_size = @max(submit_ring_size, complete_ring_size);
            complete_ring_size = submit_ring_size;
        }

        const submit_ring_u8 = nix.assert(@src(), System, "mmap", .{
            null,
            submit_ring_size,
            nix.PROT.READ | nix.PROT.WRITE,
            .{ .TYPE = .SHARED, .POPULATE = true },
            fd,
            nix.IORING_OFF_SQ_RING,
        });
        const submit_ring: []u32 = @ptrCast(submit_ring_u8);
        const submit_tail: *u32 = &submit_ring[params.sq_off.tail];
        const submit_mask: *u32 = &submit_ring[params.sq_off.ring_mask];
        const submit_array: []u32 = submit_ring[params.sq_off.array / @sizeOf(u32) ..];

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

        var complete_ring_u8: []u8 = undefined;
        if (params.flags & nix.IORING_FEAT_SINGLE_MMAP != 0)
            complete_ring_u8 = submit_ring_u8
        else
            complete_ring_u8 = nix.assert(@src(), System, "mmap", .{
                null,
                complete_ring_size,
                nix.PROT.READ | nix.PROT.WRITE,
                .{ .TYPE = .SHARED, .POPULATE = true },
                fd,
                nix.IORING_OFF_CQ_RING,
            });

        const complete_ring: []u32 = @alignCast(@ptrCast(complete_ring_u8));
        const complete_head: *u32 = &complete_ring[params.cq_off.head];
        const complete_tail: *u32 = &complete_ring[params.cq_off.tail];
        const complete_mask: *u32 = &complete_ring[params.cq_off.ring_mask];
        const complete_queue_entries: []nix.io_uring_cqe =
            @alignCast(@ptrCast(complete_ring_u8[params.cq_off.cqes..]));

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
        };
    }

    pub fn register_eventfd(
        self: *const Self,
        comptime System: type,
        eventfd: *const EventFd,
    ) void {
        _ = nix.assert(@src(), System, "io_uring_register", .{
            self.fd,
            nix.IORING_REGISTER.REGISTER_EVENTFD,
            &eventfd.fd,
            1,
        });
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
        log.info(
            @src(),
            "submitted: {d} out of {d}",
            .{ submitted, self.submit_queue.to_submit },
        );
        self.submit_queue.to_submit = 0;
    }

    pub fn event_process_event(self: *const Self) void {
        self.process_event(nix.System);
    }
    pub fn process_event(self: *const Self, comptime System: type) void {
        var buf: u64 = undefined;
        const buf_slice = std.mem.asBytes(&buf);
        _ = nix.assert(@src(), System, "read", .{ self.fd, buf_slice });
        if (self.complete_queue.read()) |r| {
            log.info(@src(), "io_uring completion event: {any}", .{r});
        }
        log.info(@src(), "io_uring event", .{});
    }
};
