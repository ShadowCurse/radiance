const std = @import("std");
const log = @import("../log.zig");
const nix = @import("../nix.zig");
const arch = @import("../arch.zig");

const Vm = @import("../vm.zig");
const Mmio = @import("../mmio.zig");
const Memory = @import("../memory.zig");
const _virtio = @import("../virtio/context.zig");
const VirtioContext = _virtio.VirtioContext;
const _queue = @import("../virtio/queue.zig");
const Queue = _queue.Queue;
const DescriptorChain = _queue.DescriptorChain;
const IovRing = @import("../virtio/iov_ring.zig");
const RingBuffer = @import("../ring_buffer.zig").RingBuffer;
const BoundedArray = @import("../bounded_array.zig").BoundedArray;

pub const TYPE_NET: u32 = 1;

pub const Config = extern struct {
    mac: [6]u8,
};
pub const QueueSizes = .{ 256, 256 };

const RX_INDEX = 0;
const TX_INDEX = 1;

fn open_tap(comptime System: type, tap_name: []const u8) nix.fd_t {
    const tun = nix.assert(@src(), System, "open", .{
        "/dev/net/tun",
        .{ .CLOEXEC = true, .NONBLOCK = true, .ACCMODE = .RDWR },
        0,
    });
    var ifreq = nix.ifreq{ .flags = .{ .TAP = true, .NO_PI = true, .VNET_HDR = true } };
    log.assert(
        @src(),
        tap_name.len <= nix.IFNAMESIZE,
        "{s} is larger than maxinum allowed size: {d}",
        .{ tap_name, @as(u32, nix.IFNAMESIZE) },
    );
    @memcpy(ifreq.name[0..tap_name.len], tap_name);
    _ = nix.assert(@src(), System, "ioctl", .{
        tun,
        nix.TUNSETIFF,
        @intFromPtr(&ifreq),
    });
    const size = @as(i32, @sizeOf(nix.virtio_net_hdr_v1));
    _ = nix.assert(@src(), System, "ioctl", .{
        tun,
        nix.TUNSETVNETHDRSZ,
        @intFromPtr(&size),
    });
    return tun;
}

fn configure_tun_flags(comptime System: type, fd: nix.fd_t, acked_features: u64) void {
    // TUN_F_CSUM - L4 packet checksum offload
    // TUN_F_TSO4 - TCP Segmentation Offload - TSO for IPv4 packets
    // TUN_F_TSO6 - TSO for IPv6 packets
    // TUN_F_TSO_ECN - TSO with ECN bits
    // TUN_F_UFO - UDP Fragmentation offload - UFO packets. Deprecated
    // TUN_F_USO4 - UDP Segmentation offload - USO for IPv4 packets
    // TUN_F_USO6 - USO for IPv6 packets
    var tun_flags: u32 = 0;
    if (acked_features & (1 << nix.VIRTIO_NET_F_GUEST_CSUM) != 0) tun_flags |= nix.TUN_F_CSUM;
    if (acked_features & (1 << nix.VIRTIO_NET_F_GUEST_UFO) != 0) tun_flags |= nix.TUN_F_UFO;
    if (acked_features & (1 << nix.VIRTIO_NET_F_GUEST_TSO4) != 0) tun_flags |= nix.TUN_F_TSO4;
    if (acked_features & (1 << nix.VIRTIO_NET_F_GUEST_TSO6) != 0) tun_flags |= nix.TUN_F_TSO6;
    _ = nix.assert(@src(), System, "ioctl", .{ fd, nix.TUNSETOFFLOAD, tun_flags });
}

pub const NetMmio = struct {
    memory: Memory.Guest,
    context: VIRTIO_CONTEXT,
    tun: nix.fd_t,

    rx_chains: RxChains,
    tx_chain: TxChain,

    activated: bool = false,

    const Self = @This();
    const VIRTIO_CONTEXT = VirtioContext(QueueSizes.len, TYPE_NET, Config);

    pub fn init(
        self: *Self,
        comptime System: type,
        vm: *Vm,
        tap_name: []const u8,
        mac: ?[6]u8,
        memory: Memory.Guest,
        mmio_info: Mmio.Resources.MmioVirtioInfo,
        iov_ring_memory: []align(Memory.HOST_PAGE_SIZE) u8,
    ) void {
        const tun = open_tap(System, tap_name);
        var virtio_context = VIRTIO_CONTEXT.init(
            System,
            vm,
            QueueSizes,
            mmio_info,
        );

        virtio_context.avail_features =
            1 << nix.VIRTIO_F_VERSION_1 |
            1 << nix.VIRTIO_RING_F_EVENT_IDX |
            1 << nix.VIRTIO_NET_F_GUEST_CSUM |
            1 << nix.VIRTIO_NET_F_CSUM |
            1 << nix.VIRTIO_NET_F_GUEST_TSO4 |
            1 << nix.VIRTIO_NET_F_HOST_TSO4 |
            1 << nix.VIRTIO_NET_F_GUEST_TSO6 |
            1 << nix.VIRTIO_NET_F_HOST_TSO6 |
            1 << nix.VIRTIO_NET_F_GUEST_UFO |
            1 << nix.VIRTIO_NET_F_HOST_UFO | 1 << nix.VIRTIO_NET_F_MRG_RXBUF;
        if (mac) |m| {
            virtio_context.config.mac = m;
            virtio_context.avail_features |= 1 << nix.VIRTIO_NET_F_MAC;
        }

        const rx_chains = RxChains.init(System, iov_ring_memory);
        const tx_chain = TxChain.init();

        self.memory = memory;
        self.context = virtio_context;
        self.tun = tun;
        self.rx_chains = rx_chains;
        self.tx_chain = tx_chain;
    }

    pub fn restore(
        self: *Self,
        comptime System: type,
        vm: *Vm,
        tap_name: []const u8,
        mmio_info: Mmio.Resources.MmioVirtioInfo,
        iov_ring_memory: []align(Memory.HOST_PAGE_SIZE) u8,
    ) void {
        self.rx_chains.restore(System, iov_ring_memory);
        self.tun = open_tap(System, tap_name);

        self.activate(System);
        self.context.restore(System, vm, mmio_info);

        // Rerun rx/tx processing in case there was an event
        // before state was saved
        self.process_tap(System);
        self.process_tx(System);
    }

    pub fn activate(self: *Self, comptime System: type) void {
        configure_tun_flags(System, self.tun, self.context.acked_features);
    }

    pub fn write_default(self: *Self, offset: u64, data: []u8) void {
        self.write(nix.System, offset, data);
    }
    pub fn write(self: *Self, comptime System: type, offset: u64, data: []u8) void {
        switch (self.context.write(System, offset, data)) {
            .NoAction => {},
            .ActivateDevice => {
                // Only VIRTIO_MMIO_INT_VRING notification type is supported.
                if (self.context.acked_features & (1 << nix.VIRTIO_RING_F_EVENT_IDX) != 0) {
                    for (&self.context.queues) |*q| {
                        q.notification_suppression = true;
                    }
                }
                self.activate(System);
                self.activated = true;
            },
            else => |action| {
                log.err(@src(), "unhandled write virtio action: {}", .{action});
            },
        }
    }

    pub fn read(self: *Self, offset: u64, data: []u8) void {
        switch (self.context.read(offset, data)) {
            .NoAction => {},
            else => |action| {
                log.err(@src(), "unhandled read virtio action: {}", .{action});
            },
        }
    }

    pub fn event_process_rx(self: *Self) void {
        self.process_rx_event(nix.System);
    }
    pub fn process_rx_event(self: *Self, comptime System: type) void {
        _ = self.context.queue_events[RX_INDEX].read(System);
        self.process_tap(System);
    }

    pub fn event_process_tx(self: *Self) void {
        self.process_tx(nix.System);
    }
    pub fn process_tx_event(self: *Self, comptime System: type) void {
        _ = self.context.queue_events[TX_INDEX].read(System);
        self.process_tx(System);
    }
    pub fn process_tx(self: *Self, comptime System: type) void {
        const queue = &self.context.queues[TX_INDEX];

        while (queue.pop_desc_chain(self.memory)) |dc| {
            self.tx_chain.add_chain(self.memory, dc);

            const iov_slice = self.tx_chain.slice();
            _ = nix.assert(@src(), System, "writev", .{ self.tun, iov_slice });
            self.tx_chain.finish_used(self.memory, queue);
        }

        if (queue.send_notification(self.memory)) self.context.irq_evt.write(System, 1);
    }

    pub fn event_process_tap(self: *Self) void {
        self.process_tap(nix.System);
    }
    pub fn process_tap(self: *Self, comptime System: type) void {
        if (!self.activated) return;
        const queue = &self.context.queues[RX_INDEX];

        while (queue.pop_desc_chain(self.memory)) |dc| self.rx_chains.add_chain(self.memory, dc);

        // Technically not needed check, but seems compiler really
        // needs it.
        if (self.rx_chains.chain_infos.len == 0 or
            self.rx_chains.iovec_ring.capacity <= std.math.maxInt(u16))
            return;

        while (true) {
            if (self.rx_chains.chain_infos.len == 0 or
                self.rx_chains.iovec_ring.capacity <= std.math.maxInt(u16))
                break;

            const iov_slice = if (self.context.acked_features &
                (1 << nix.VIRTIO_NET_F_MRG_RXBUF) != 0)
                self.rx_chains.all_chains_slice()
            else
                self.rx_chains.first_chain_slice();

            const bytes = System.readv(self.tun, iov_slice) catch |e| {
                log.assert(
                    @src(),
                    e == nix.ReadError.WouldBlock,
                    "readv error: {}",
                    .{e},
                );
                break;
            };

            self.rx_chains.mark_used_bytes(self.memory, queue, @intCast(bytes));
        }

        if (queue.send_notification(self.memory)) self.context.irq_evt.write(System, 1);
    }
};

const RxChains = struct {
    const ChainInfo = struct {
        head_index: u16,
        len: u16,
        capacity: u32,
    };

    const Self = @This();
    iovec_ring: IovRing,
    chain_infos: RingBuffer(ChainInfo, IovRing.MAX_IOVECS),

    pub fn init(comptime System: type, iov_ring_memory: []align(Memory.HOST_PAGE_SIZE) u8) Self {
        return .{
            .iovec_ring = .init(System, iov_ring_memory),
            .chain_infos = .empty,
        };
    }

    pub fn restore(
        self: *Self,
        comptime System: type,
        iov_ring_memory: []align(Memory.HOST_PAGE_SIZE) u8,
    ) void {
        self.iovec_ring.restore(System, iov_ring_memory);
    }

    pub fn first_chain_slice(self: *Self) []nix.iovec {
        const chain_info = self.chain_infos.first();
        return self.iovec_ring.slice()[0..chain_info.len];
    }

    pub fn all_chains_slice(self: *Self) []nix.iovec {
        return self.iovec_ring.slice();
    }

    pub fn add_chain(self: *Self, memory: Memory.Guest, dc: DescriptorChain) void {
        var chain = dc;
        var chain_info: ChainInfo = .{
            .head_index = dc.index.?,
            .len = 0,
            .capacity = 0,
        };
        while (chain.next()) |desc| {
            chain_info.len += 1;
            chain_info.capacity += desc.len;
            const iovec_slice = memory.get_slice(u8, desc.len, desc.addr);
            const iovec: nix.iovec = .{
                .base = @volatileCast(iovec_slice.ptr),
                .len = iovec_slice.len,
            };
            self.iovec_ring.push_back(iovec);
        }
        self.chain_infos.push_back(chain_info);
    }

    pub fn mark_used_bytes(self: *Self, memory: Memory.Guest, queue: *Queue, bytes: u32) void {
        log.assert(@src(), self.iovec_ring.len != 0, "Empty iovec_ring", .{});
        log.assert(
            @src(),
            @sizeOf(nix.virtio_net_hdr_v1) <= self.iovec_ring.slice()[0].len,
            "Buffer size too smal for virtio_net_hdr_v1: {} <= {}",
            .{ @as(usize, @sizeOf(nix.virtio_net_hdr_v1)), self.iovec_ring.slice()[0].len },
        );
        var net_hdr_v1: *volatile nix.virtio_net_hdr_v1 =
            @ptrCast(@alignCast(self.iovec_ring.slice()[0].base));

        const used_ring = memory.get_ptr(nix.vring_used, queue.used_ring);
        const used_ring_ring = used_ring.ring();

        var bytes_left = bytes;
        var chains_used: u16 = 0;
        while (true) {
            const next_used = (queue.next_used +% chains_used) % queue.size;

            const chain_info = self.chain_infos.pop_front().?;
            self.iovec_ring.pop_front_n(chain_info.len);

            if (bytes_left <= chain_info.capacity) {
                used_ring_ring[next_used] = .{
                    .id = chain_info.head_index,
                    .len = bytes_left,
                };
                chains_used += 1;
                break;
            } else {
                used_ring_ring[next_used] = .{
                    .id = chain_info.head_index,
                    .len = chain_info.capacity,
                };
                chains_used += 1;
                bytes_left -= chain_info.capacity;
            }
        }
        net_hdr_v1.num_buffers = chains_used;

        queue.next_used = queue.next_used +% chains_used;
        queue.suppressed = queue.suppressed +% chains_used;

        arch.load_store_barrier();
        used_ring.idx = queue.next_used;
    }
};

const TxChain = struct {
    const Self = @This();
    iovec_array: BoundedArray(nix.iovec_const, 16),
    head_index: u16,

    pub fn init() Self {
        return .{
            .iovec_array = .empty,
            .head_index = 0,
        };
    }

    pub fn slice(self: *const Self) []const nix.iovec_const {
        return self.iovec_array.slice_const();
    }

    pub fn add_chain(self: *Self, memory: Memory.Guest, dc: DescriptorChain) void {
        self.head_index = dc.index.?;
        var chain = dc;
        while (chain.next()) |desc| {
            const iovec_slice = memory.get_slice(u8, desc.len, desc.addr);
            const iovec: nix.iovec_const = .{
                .base = @volatileCast(iovec_slice.ptr),
                .len = iovec_slice.len,
            };
            self.iovec_array.append(iovec);
        }
    }

    pub fn finish_used(self: *Self, memory: Memory.Guest, queue: *Queue) void {
        queue.add_used_desc(memory, self.head_index, 0);
        self.iovec_array.reset();
    }
};

pub const NetMmioVhost = struct {
    memory: Memory.Guest,
    context: VIRTIO_CONTEXT,

    tun: nix.fd_t,
    vhost: nix.fd_t,

    const Self = @This();
    const VIRTIO_CONTEXT = VirtioContext(QueueSizes.len, TYPE_NET, Config);

    pub fn init(
        self: *Self,
        comptime System: type,
        vm: *Vm,
        tap_name: []const u8,
        mac: ?[6]u8,
        memory: Memory.Guest,
        mmio_info: Mmio.Resources.MmioVirtioInfo,
    ) void {
        const tun = open_tap(System, tap_name);

        var virtio_context = VIRTIO_CONTEXT.init(
            System,
            vm,
            QueueSizes,
            mmio_info,
        );

        virtio_context.avail_features =
            1 << nix.VIRTIO_F_VERSION_1 |
            1 << nix.VIRTIO_RING_F_INDIRECT_DESC |
            1 << nix.VIRTIO_RING_F_EVENT_IDX |
            1 << nix.VIRTIO_NET_F_GUEST_CSUM |
            1 << nix.VIRTIO_NET_F_CSUM |
            1 << nix.VIRTIO_NET_F_GUEST_TSO4 |
            1 << nix.VIRTIO_NET_F_HOST_TSO4 |
            1 << nix.VIRTIO_NET_F_GUEST_TSO6 |
            1 << nix.VIRTIO_NET_F_HOST_TSO6 |
            1 << nix.VIRTIO_NET_F_GUEST_UFO |
            1 << nix.VIRTIO_NET_F_HOST_UFO |
            1 << nix.VIRTIO_NET_F_GUEST_USO4 |
            1 << nix.VIRTIO_NET_F_GUEST_USO6 |
            1 << nix.VIRTIO_NET_F_HOST_USO |
            1 << nix.VIRTIO_NET_F_MRG_RXBUF;
        if (mac) |m| {
            virtio_context.config.mac = m;
            virtio_context.avail_features |= 1 << nix.VIRTIO_NET_F_MAC;
        }

        self.memory = memory;
        self.context = virtio_context;
        self.tun = tun;
        self.vhost = 0;
    }

    pub fn restore(
        self: *Self,
        comptime System: type,
        vm: *Vm,
        tap_name: []const u8,
        mmio_info: Mmio.Resources.MmioVirtioInfo,
    ) void {
        self.tun = nix.assert(@src(), System, "open", .{
            "/dev/net/tun",
            .{ .CLOEXEC = true, .NONBLOCK = true, .ACCMODE = .RDWR },
            0,
        });
        var ifreq = nix.ifreq{ .flags = .{ .TAP = true, .NO_PI = true, .VNET_HDR = true } };
        log.assert(
            @src(),
            tap_name.len <= nix.IFNAMESIZE,
            "{s} is larger than maxinum allowed size: {d}",
            .{ tap_name, @as(u32, nix.IFNAMESIZE) },
        );
        @memcpy(ifreq.name[0..tap_name.len], tap_name);
        _ = nix.assert(@src(), System, "ioctl", .{
            self.tun,
            nix.TUNSETIFF,
            @intFromPtr(&ifreq),
        });
        const size = @as(i32, @sizeOf(nix.virtio_net_hdr_v1));
        _ = nix.assert(@src(), System, "ioctl", .{
            self.tun,
            nix.TUNSETVNETHDRSZ,
            @intFromPtr(&size),
        });

        self.activate(System);
        self.context.restore(System, vm, mmio_info);

        for (&self.context.queue_events) |*queue_event| queue_event.write(System, 1);
    }

    pub fn activate(self: *Self, comptime System: type) void {
        configure_tun_flags(System, self.tun, self.context.acked_features);

        const vhost = nix.assert(@src(), System, "open", .{
            "/dev/vhost-net",
            .{ .CLOEXEC = true, .NONBLOCK = true, .ACCMODE = .RDWR },
            0,
        });
        _ = nix.assert(@src(), System, "ioctl", .{
            vhost,
            nix.VHOST_SET_OWNER,
            @as(usize, 0),
        });

        {
            const features: u64 = 1 << nix.VIRTIO_F_VERSION_1 |
                1 << nix.VIRTIO_RING_F_EVENT_IDX |
                1 << nix.VIRTIO_RING_F_INDIRECT_DESC |
                1 << nix.VIRTIO_NET_F_MRG_RXBUF;
            _ = nix.assert(@src(), System, "ioctl", .{
                vhost,
                nix.VHOST_SET_FEATURES,
                @intFromPtr(&features),
            });
        }

        {
            const size: usize = (@sizeOf(nix.vhost_memory) +
                @sizeOf(nix.vhost_memory_region)) /
                @sizeOf(nix.vhost_memory);
            var memory: [size]nix.vhost_memory = undefined;
            memory[0].nregions = 1;
            memory[0].padding = 0;
            memory[0].regions()[0] = nix.vhost_memory_region{
                .guest_phys_addr = Memory.DRAM_START,
                .memory_size = self.memory.mem.len,
                .userspace_addr = @intFromPtr(self.memory.mem.ptr),
                .flags_padding = 0,
            };
            _ = nix.assert(@src(), System, "ioctl", .{
                vhost,
                nix.VHOST_SET_MEM_TABLE,
                @intFromPtr(&memory),
            });
        }

        for (0..2) |i| {
            const vring = nix.vhost_vring_file{
                .index = @intCast(i),
                .fd = self.context.irq_evt.fd,
            };
            _ = nix.assert(@src(), System, "ioctl", .{
                vhost,
                nix.VHOST_SET_VRING_CALL,
                @intFromPtr(&vring),
            });
        }

        for (&self.context.queue_events, 0..) |*queue_event, i| {
            const vring = nix.vhost_vring_file{
                .index = @intCast(i),
                .fd = queue_event.fd,
            };
            _ = nix.assert(@src(), System, "ioctl", .{
                vhost,
                nix.VHOST_SET_VRING_KICK,
                @intFromPtr(&vring),
            });
        }

        for (&self.context.queues, 0..) |*queue, i| {
            {
                const vring = nix.vhost_vring_state{
                    .index = @intCast(i),
                    .num = queue.size,
                };
                _ = nix.assert(@src(), System, "ioctl", .{
                    vhost,
                    nix.VHOST_SET_VRING_NUM,
                    @intFromPtr(&vring),
                });
            }

            {
                const vring = nix.vhost_vring_addr{
                    .index = @intCast(i),
                    .flags = 0,
                    .desc_user_addr = @intFromPtr(self.memory.get_ptr(u8, queue.desc_table)),
                    .used_user_addr = @intFromPtr(self.memory.get_ptr(u8, queue.used_ring)),
                    .avail_user_addr = @intFromPtr(self.memory.get_ptr(u8, queue.avail_ring)),
                    .log_guest_addr = 0,
                };
                _ = nix.assert(@src(), System, "ioctl", .{
                    vhost,
                    nix.VHOST_SET_VRING_ADDR,
                    @intFromPtr(&vring),
                });
            }

            {
                const vring = nix.vhost_vring_file{
                    .index = @intCast(i),
                    .fd = self.tun,
                };
                _ = nix.assert(@src(), System, "ioctl", .{
                    vhost,
                    nix.VHOST_NET_SET_BACKEND,
                    @intFromPtr(&vring),
                });
            }
        }
        self.vhost = vhost;
    }

    pub fn write_default(self: *Self, offset: u64, data: []u8) void {
        self.write(nix.System, offset, data);
    }
    pub fn write(self: *Self, comptime System: type, offset: u64, data: []u8) void {
        switch (self.context.write(System, offset, data)) {
            .NoAction => {},
            .ActivateDevice => self.activate(System),
            else => |action| {
                log.err(@src(), "unhandled write virtio action: {}", .{action});
            },
        }
    }

    pub fn read(self: *Self, offset: u64, data: []u8) void {
        switch (self.context.read(offset, data)) {
            .NoAction => {},
            else => |action| {
                log.err(@src(), "unhandled read virtio action: {}", .{action});
            },
        }
    }
};
