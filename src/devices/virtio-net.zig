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

pub const VirtioNet = struct {
    memory: *Memory,
    context: VIRTIO_CONTEXT,
    tun: nix.fd_t,

    rx_chains: RxChains,
    tx_chain: TxChain,

    activated: bool = false,

    const Self = @This();
    const VIRTIO_CONTEXT = VirtioContext(QueueSizes.len, TYPE_NET, Config);

    pub fn init(
        comptime System: type,
        vm: *Vm,
        tap_name: []const u8,
        mac: ?[6]u8,
        memory: *Memory,
        mmio_info: Mmio.Resources.MmioInfo,
    ) Self {
        const tun = nix.assert(@src(), System, "open", .{
            "/dev/net/tun",
            .{ .CLOEXEC = true, .NONBLOCK = true, .ACCMODE = .RDWR },
            0,
        });
        var ifreq = nix.ifreq{
            .flags = .{ .TAP = true, .NO_PI = true, .VNET_HDR = true },
        };
        log.assert(
            @src(),
            tap_name.len <= nix.IFNAMESIZE,
            "VirtioNet dev_name: {s} is larger than maxinum allowed size: {d}",
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

        const rx_chains = RxChains.init(System);
        const tx_chain = TxChain.init();

        return .{
            .memory = memory,
            .context = virtio_context,
            .tun = tun,
            .rx_chains = rx_chains,
            .tx_chain = tx_chain,
        };
    }

    pub fn activate(self: *Self, comptime System: type) void {
        // TUN_F_CSUM - L4 packet checksum offload
        // TUN_F_TSO4 - TCP Segmentation Offload - TSO for IPv4 packets
        // TUN_F_TSO6 - TSO for IPv6 packets
        // TUN_F_TSO_ECN - TSO with ECN bits
        // TUN_F_UFO - UDP Fragmentation offload - UFO packets. Deprecated
        // TUN_F_USO4 - UDP Segmentation offload - USO for IPv4 packets
        // TUN_F_USO6 - USO for IPv6 packets
        var tun_flags: u32 = 0;
        if (self.context.acked_features & (1 << nix.VIRTIO_NET_F_GUEST_CSUM) != 0) {
            tun_flags |= nix.TUN_F_CSUM;
        }
        if (self.context.acked_features & (1 << nix.VIRTIO_NET_F_GUEST_UFO) != 0) {
            tun_flags |= nix.TUN_F_UFO;
        }
        if (self.context.acked_features & (1 << nix.VIRTIO_NET_F_GUEST_TSO4) != 0) {
            tun_flags |= nix.TUN_F_TSO4;
        }
        if (self.context.acked_features & (1 << nix.VIRTIO_NET_F_GUEST_TSO6) != 0) {
            tun_flags |= nix.TUN_F_TSO6;
        }
        _ = nix.assert(@src(), System, "ioctl", .{
            self.tun,
            nix.TUNSETOFFLOAD,
            tun_flags,
        });
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
        self.process_rx(nix.System);
    }
    pub fn process_rx(self: *Self, comptime System: type) void {
        _ = self.context.queue_events[RX_INDEX].read(System);
        self.process_tap(System);
    }

    pub fn event_process_tx(self: *Self) void {
        self.process_tx(nix.System);
    }
    pub fn process_tx(self: *Self, comptime System: type) void {
        _ = self.context.queue_events[TX_INDEX].read(System);
        const queue = &self.context.queues[TX_INDEX];

        while (queue.pop_desc_chain(self.memory)) |dc| {
            self.tx_chain.add_chain(self.memory, dc);

            const iov_slice = self.tx_chain.slice();
            _ = nix.assert(@src(), System, "writev", .{ self.tun, iov_slice });
            self.tx_chain.finish_used(self.memory, queue);
        }

        if (queue.send_notification(self.memory)) {
            self.context.irq_evt.write(System, 1);
        }
    }

    pub fn event_process_tap(self: *Self) void {
        self.process_tap(nix.System);
    }
    pub fn process_tap(self: *Self, comptime System: type) void {
        if (!self.activated) {
            return;
        }
        const queue = &self.context.queues[RX_INDEX];

        while (queue.pop_desc_chain(self.memory)) |dc| {
            self.rx_chains.add_chain(self.memory, dc);
        }

        // Technically not needed check, but seems compiler really
        // needs it.
        if (self.rx_chains.chain_infos.len == 0 or
            self.rx_chains.iovec_ring.capacity <= std.math.maxInt(u16))
        {
            return;
        }

        while (true) {
            if (self.rx_chains.chain_infos.len == 0 or
                self.rx_chains.iovec_ring.capacity <= std.math.maxInt(u16))
            {
                break;
            }

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

        if (queue.send_notification(self.memory)) {
            self.context.irq_evt.write(System, 1);
        }
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

    pub fn init(comptime System: type) Self {
        return .{
            .iovec_ring = .init(System),
            .chain_infos = .empty,
        };
    }

    pub fn first_chain_slice(self: *Self) []nix.iovec {
        const chain_info = self.chain_infos.first();
        return self.iovec_ring.slice()[0..chain_info.len];
    }

    pub fn all_chains_slice(self: *Self) []nix.iovec {
        return self.iovec_ring.slice();
    }

    pub fn add_chain(self: *Self, memory: *Memory, dc: DescriptorChain) void {
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

    pub fn mark_used_bytes(self: *Self, memory: *Memory, queue: *Queue, bytes: u32) void {
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

    pub fn add_chain(self: *Self, memory: *Memory, dc: DescriptorChain) void {
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

    pub fn finish_used(self: *Self, memory: *Memory, queue: *Queue) void {
        queue.add_used_desc(memory, self.head_index, 0);
        self.iovec_array.reset();
    }
};
