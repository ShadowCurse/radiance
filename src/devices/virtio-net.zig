const std = @import("std");
const nix = @import("../nix.zig");
const log = @import("../log.zig");

const Vm = @import("../vm.zig");
const CmdLine = @import("../cmdline.zig");
const MmioDeviceInfo = @import("../mmio.zig").MmioDeviceInfo;
const Memory = @import("../memory.zig");
const VIRTIO = @import("../virtio/context.zig");
const VirtioContext = VIRTIO.VirtioContext;
const VirtioAction = VIRTIO.VirtioAction;
const QUEUE = @import("../virtio/queue.zig");
const Queue = QUEUE.Queue;
const DescriptorChain = QUEUE.DescriptorChain;
const IovRing = @import("../virtio/iov_ring.zig");
const RingBuffer = @import("../ring_buffer.zig").RingBuffer;

pub const TYPE_NET: u32 = 1;
pub const MacAddr = [6]u8;
pub const VirtioNetConfig = MacAddr;
const RX_INDEX = 0;
const TX_INDEX = 1;

pub const VirtioNetError = error{
    NewTUNSETIFF,
    NewTUNSETVNETHDRSZ,
    NewKVM_IRQFD,
    NewKVM_IOEVENTFD,
    ActivateTUNSETOFFLOAD,
};

pub const VirtioNet = struct {
    memory: *Memory,
    virtio_context: VIRTIO_CONTEXT,
    mmio_info: MmioDeviceInfo,
    tun: nix.fd_t,

    rx_chains: RxChains,
    tx_chain: TxChain,

    activated: bool = false,

    const Self = @This();
    const VIRTIO_CONTEXT = VirtioContext(2, TYPE_NET, VirtioNetConfig);

    pub fn new(
        vm: *const Vm,
        tap_name: [:0]const u8,
        mac: ?[6]u8,
        memory: *Memory,
        mmio_info: MmioDeviceInfo,
    ) !Self {
        const tun = try nix.open(
            "/dev/net/tun",
            .{ .CLOEXEC = true, .NONBLOCK = true, .ACCMODE = .RDWR },
            0,
        );
        var ifreq = std.mem.zeroInit(nix.ifreq, .{});
        @memcpy(ifreq.ifr_ifrn.ifrn_name[0..tap_name.len], tap_name);
        // IFF_TAP / IFF_TUN - select TAP or TUN
        // IFF_NO_CARRIER - Holding an open tap device file descriptor sets the Ethernet interface CARRIER flag up. In some cases it might be desired to delay that until a TUNSETCARRIER call.
        // IFF_NO_PI - Historically each packet on tap had a "struct tun_pi" 4 byte prefix. There are now better alternatives and this option disables this prefix.
        // IFF_TUN_EXCL - Ensures a new device is created. Returns EBUSY if the device exists
        // IFF_VNET_HDR -Prepend "struct virtio_net_hdr" before the RX and TX packets, should be followed by setsockopt(TUNSETVNETHDRSZ).
        // IFF_MULTI_QUEUE - Use multi queue tap, see below.
        ifreq.ifr_ifru.ifru_flags = nix.IFF_TAP | nix.IFF_NO_PI | nix.IFF_VNET_HDR;
        {
            _ = try nix.checked_ioctl(
                @src(),
                VirtioNetError.NewTUNSETIFF,
                tun,
                nix.TUNSETIFF,
                &ifreq,
            );
        }
        {
            const size = @as(i32, @sizeOf(nix.virtio_net_hdr_v1));
            _ = try nix.checked_ioctl(
                @src(),
                VirtioNetError.NewTUNSETVNETHDRSZ,
                tun,
                nix.TUNSETVNETHDRSZ,
                &size,
            );
        }

        var virtio_context = try VIRTIO_CONTEXT.new(
            vm,
            mmio_info.irq,
            mmio_info.addr,
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
            virtio_context.config_blob = m;
            virtio_context.avail_features |= 1 << nix.VIRTIO_NET_F_MAC;
        }

        const rx_chains = try RxChains.init();
        const tx_chain = TxChain.init();

        return Self{
            .memory = memory,
            .virtio_context = virtio_context,
            .mmio_info = mmio_info,
            .tun = tun,
            .rx_chains = rx_chains,
            .tx_chain = tx_chain,
        };
    }

    pub fn activate(self: *Self) !void {
        // TUN_F_CSUM - L4 packet checksum offload
        // TUN_F_TSO4 - TCP Segmentation Offload - TSO for IPv4 packets
        // TUN_F_TSO6 - TSO for IPv6 packets
        // TUN_F_TSO_ECN - TSO with ECN bits
        // TUN_F_UFO - UDP Fragmentation offload - UFO packets. Deprecated
        // TUN_F_USO4 - UDP Segmentation offload - USO for IPv4 packets
        // TUN_F_USO6 - USO for IPv6 packets
        var tun_flags: u32 = 0;
        if (self.virtio_context.acked_features & (1 << nix.VIRTIO_NET_F_GUEST_CSUM) != 0) {
            tun_flags |= nix.TUN_F_CSUM;
        }
        if (self.virtio_context.acked_features & (1 << nix.VIRTIO_NET_F_GUEST_UFO) != 0) {
            tun_flags |= nix.TUN_F_UFO;
        }
        if (self.virtio_context.acked_features & (1 << nix.VIRTIO_NET_F_GUEST_TSO4) != 0) {
            tun_flags |= nix.TUN_F_TSO4;
        }
        if (self.virtio_context.acked_features & (1 << nix.VIRTIO_NET_F_GUEST_TSO6) != 0) {
            tun_flags |= nix.TUN_F_TSO6;
        }
        _ = try nix.checked_ioctl(
            @src(),
            VirtioNetError.ActivateTUNSETOFFLOAD,
            self.tun,
            nix.TUNSETOFFLOAD,
            tun_flags,
        );
    }

    pub fn write(self: *Self, addr: u64, data: []u8) !bool {
        if (!self.mmio_info.contains_addr(addr)) {
            return false;
        }
        const offset = addr - self.mmio_info.addr;
        switch (self.virtio_context.write(offset, data)) {
            VirtioAction.NoAction => {},
            VirtioAction.ActivateDevice => {
                // Only VIRTIO_MMIO_INT_VRING notification type is supported.
                _ = self.virtio_context.irq_status.fetchOr(nix.VIRTIO_MMIO_INT_VRING, .seq_cst);
                if (self.virtio_context.acked_features & (1 << nix.VIRTIO_RING_F_EVENT_IDX) != 0) {
                    for (&self.virtio_context.queues) |*q| {
                        q.notification_suppression = true;
                    }
                }
                try self.activate();
                self.activated = true;
            },
            else => |action| {
                log.err(@src(), "unhandled write virtio action: {}", .{action});
            },
        }
        return true;
    }

    pub fn read(self: *Self, addr: u64, data: []u8) !bool {
        if (!self.mmio_info.contains_addr(addr)) {
            return false;
        }
        const offset = addr - self.mmio_info.addr;
        switch (self.virtio_context.read(offset, data)) {
            VirtioAction.NoAction => {},
            else => |action| {
                log.err(@src(), "unhandled read virtio action: {}", .{action});
            },
        }
        return true;
    }

    pub fn process_rx(self: *Self) !void {
        _ = try self.virtio_context.queue_events[RX_INDEX].read();
        try self.process_tap();
    }

    pub fn process_tx(self: *Self) !void {
        _ = try self.virtio_context.queue_events[TX_INDEX].read();
        const queue = &self.virtio_context.queues[TX_INDEX];

        while (queue.pop_desc_chain(self.memory)) |dc| {
            self.tx_chain.add_chain(self.memory, dc);

            const iov_slice = self.tx_chain.slice();
            _ = try nix.writev(self.tun, iov_slice);
            self.tx_chain.finish_used(self.memory, queue);
        }

        if (queue.send_notification(self.memory)) {
            try self.virtio_context.irq_evt.write(1);
        }
    }

    pub fn process_tap(self: *Self) !void {
        if (!self.activated) {
            return;
        }
        const queue = &self.virtio_context.queues[RX_INDEX];

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

            const iov_slice = if (self.virtio_context.acked_features & (1 << nix.VIRTIO_NET_F_MRG_RXBUF) != 0)
                self.rx_chains.all_chains_slice()
            else
                self.rx_chains.first_chain_slice();

            const bytes = nix.readv(self.tun, iov_slice) catch |e| {
                if (e == nix.ReadError.WouldBlock) {
                    break;
                } else {
                    log.err(@src(), "virtio-net readv: {}", .{e});
                    return e;
                }
            };

            self.rx_chains.mark_used_bytes(self.memory, queue, @intCast(bytes));
        }

        if (queue.send_notification(self.memory)) {
            try self.virtio_context.irq_evt.write(1);
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

    pub fn init() !Self {
        return .{
            .iovec_ring = try IovRing.init(),
            .chain_infos = try RingBuffer(ChainInfo, IovRing.MAX_IOVECS).init(),
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
                .base = iovec_slice.ptr,
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
        var net_hdr_v1: *volatile nix.virtio_net_hdr_v1 = @alignCast(@ptrCast(self.iovec_ring.slice()[0].base));

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

        queue.next_used = queue.next_used +% chains_used;
        queue.suppressed = queue.suppressed +% chains_used;
        used_ring.idx = queue.next_used;

        net_hdr_v1.num_buffers = chains_used;

        @fence(.release);
    }
};

const TxChain = struct {
    const Self = @This();
    iovec_array: std.BoundedArray(nix.iovec_const, 16),
    head_index: u16,

    pub fn init() Self {
        return .{
            .iovec_array = std.BoundedArray(nix.iovec_const, 16).init(0) catch unreachable,
            .head_index = 0,
        };
    }

    pub fn slice(self: *const Self) []const nix.iovec_const {
        return self.iovec_array.slice();
    }

    pub fn add_chain(self: *Self, memory: *Memory, dc: DescriptorChain) void {
        self.head_index = dc.index.?;
        var chain = dc;
        while (chain.next()) |desc| {
            const iovec_slice = memory.get_slice(u8, desc.len, desc.addr);
            const iovec: nix.iovec_const = .{
                .base = iovec_slice.ptr,
                .len = iovec_slice.len,
            };
            self.iovec_array.append(iovec) catch unreachable;
        }
    }

    pub fn finish_used(self: *Self, memory: *Memory, queue: *Queue) void {
        queue.add_used_desc(memory, self.head_index, 0);
        self.iovec_array.resize(0) catch unreachable;
    }
};
