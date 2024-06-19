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

pub const TYPE_NET: u32 = 1;

pub const MacAddr = [6]u8;
pub const VirtioNetConfig = MacAddr;

pub const VirtioNetError = error{
    NewTUNSETIFF,
    NewTUNSETVNETHDRSZ,
    NewKVM_IRQFD,
    NewKVM_IOEVENTFD,
    ActivateTUNSETOFFLOAD,
    ActivateVHOST_SET_OWNER,
    ActivateVHOST_SET_FEATURES,
    ActivateVHOST_SET_MEM_TABLE,
    ActivateVHOST_SET_VRING_CALL,
    ActivateVHOST_SET_VRING_KICK,
    ActivateVHOST_SET_VRING_NUM,
    ActivateVHOST_SET_VRING_ADDR,
    ActivateVHOST_NET_SET_BACKEND,
};

pub const VhostNet = struct {
    memory: *Memory,
    virtio_context: VIRTIO_CONTEXT,
    mmio_info: MmioDeviceInfo,

    tun: std.fs.File,
    vhost: ?std.fs.File,

    const Self = @This();
    const VIRTIO_CONTEXT = VirtioContext(2, TYPE_NET, VirtioNetConfig);

    pub fn new(
        vm: *const Vm,
        tap_name: [:0]const u8,
        mac: ?[6]u8,
        memory: *Memory,
        mmio_info: MmioDeviceInfo,
    ) !Self {
        const tun = try std.fs.openFileAbsolute(
            "/dev/net/tun",
            .{ .mode = .read_write, .lock_nonblocking = true },
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
                tun.handle,
                nix.TUNSETIFF,
                &ifreq,
            );
        }
        {
            const size = @as(i32, @sizeOf(nix.virtio_net_hdr_v1));
            _ = try nix.checked_ioctl(
                @src(),
                VirtioNetError.NewTUNSETVNETHDRSZ,
                tun.handle,
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
            1 << nix.VIRTIO_RING_F_INDIRECT_DESC |
            1 << nix.VIRTIO_RING_F_EVENT_IDX |
            1 << nix.VIRTIO_NET_F_GUEST_CSUM |
            1 << nix.VIRTIO_NET_F_CSUM |
            1 << nix.VIRTIO_NET_F_GUEST_TSO4 |
            1 << nix.VIRTIO_NET_F_HOST_TSO4 |
            1 << nix.VIRTIO_NET_F_GUEST_TSO6 |
            1 << nix.VIRTIO_NET_F_HOST_TSO6 |
            1 << nix.VIRTIO_NET_F_HOST_USO |
            1 << nix.VIRTIO_NET_F_MRG_RXBUF;
        if (mac) |m| {
            virtio_context.config_blob = m;
            virtio_context.avail_features |= 1 << nix.VIRTIO_NET_F_MAC;
        }

        return Self{
            .memory = memory,
            .virtio_context = virtio_context,
            .mmio_info = mmio_info,
            .tun = tun,
            .vhost = null,
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
        var tun_flags: u64 = 0;
        if (self.virtio_context.acked_features & 1 << nix.VIRTIO_NET_F_CSUM != 0) {
            tun_flags |= 1 << nix.TUN_F_CSUM;
        }
        if (self.virtio_context.acked_features & 1 << nix.VIRTIO_NET_F_GUEST_UFO != 0) {
            tun_flags |= 1 << nix.TUN_F_UFO;
        }
        if (self.virtio_context.acked_features & 1 << nix.VIRTIO_NET_F_GUEST_TSO4 != 0) {
            tun_flags |= 1 << nix.TUN_F_TSO4;
        }
        if (self.virtio_context.acked_features & 1 << nix.VIRTIO_NET_F_GUEST_TSO6 != 0) {
            tun_flags |= 1 << nix.TUN_F_TSO6;
        }
        _ = try nix.checked_ioctl(
            @src(),
            VirtioNetError.ActivateTUNSETOFFLOAD,
            self.tun.handle,
            nix.TUNSETOFFLOAD,
            tun_flags,
        );

        const vhost = try std.fs.openFileAbsolute(
            "/dev/vhost-net",
            .{ .mode = .read_write, .lock_nonblocking = true },
        );
        _ = try nix.checked_ioctl(
            @src(),
            VirtioNetError.ActivateVHOST_SET_OWNER,
            vhost.handle,
            nix.VHOST_SET_OWNER,
            .{},
        );

        {
            const features: u64 = 1 << nix.VIRTIO_F_VERSION_1 |
                1 << nix.VIRTIO_RING_F_EVENT_IDX |
                1 << nix.VIRTIO_RING_F_INDIRECT_DESC |
                1 << nix.VIRTIO_NET_F_MRG_RXBUF;
            _ = try nix.checked_ioctl(
                @src(),
                VirtioNetError.ActivateVHOST_SET_FEATURES,
                vhost.handle,
                nix.VHOST_SET_FEATURES,
                &features,
            );
        }

        {
            const size: usize = (@sizeOf(nix.vhost_memory) + @sizeOf(nix.vhost_memory_region)) / @sizeOf(nix.vhost_memory);
            var memory: [size]nix.vhost_memory = undefined;
            memory[0].nregions = 1;
            memory[0].padding = 0;
            memory[0].regions()[0] = nix.vhost_memory_region{
                .guest_phys_addr = self.memory.guest_addr,
                .memory_size = self.memory.mem.len,
                .userspace_addr = @intFromPtr(self.memory.mem.ptr),
                .flags_padding = 0,
            };
            _ = try nix.checked_ioctl(
                @src(),
                VirtioNetError.ActivateVHOST_SET_MEM_TABLE,
                vhost.handle,
                nix.VHOST_SET_MEM_TABLE,
                &memory,
            );
        }

        for (0..2) |i| {
            const vring = nix.vhost_vring_file{
                .index = @intCast(i),
                .fd = self.virtio_context.irq_evt.fd,
            };
            _ = try nix.checked_ioctl(
                @src(),
                VirtioNetError.ActivateVHOST_SET_VRING_CALL,
                vhost.handle,
                nix.VHOST_SET_VRING_CALL,
                &vring,
            );
        }

        for (&self.virtio_context.queue_events, 0..) |*queue_event, i| {
            const vring = nix.vhost_vring_file{
                .index = @intCast(i),
                .fd = queue_event.fd,
            };
            _ = try nix.checked_ioctl(
                @src(),
                VirtioNetError.ActivateVHOST_SET_VRING_KICK,
                vhost.handle,
                nix.VHOST_SET_VRING_KICK,
                &vring,
            );
        }

        for (&self.virtio_context.queues, 0..) |*queue, i| {
            {
                const vring = nix.vhost_vring_state{
                    .index = @intCast(i),
                    .num = queue.size,
                };
                _ = try nix.checked_ioctl(
                    @src(),
                    VirtioNetError.ActivateVHOST_SET_VRING_NUM,
                    vhost.handle,
                    nix.VHOST_SET_VRING_NUM,
                    &vring,
                );
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
                _ = try nix.checked_ioctl(
                    @src(),
                    VirtioNetError.ActivateVHOST_SET_VRING_ADDR,
                    vhost.handle,
                    nix.VHOST_SET_VRING_ADDR,
                    &vring,
                );
            }

            {
                const vring = nix.vhost_vring_file{
                    .index = @intCast(i),
                    .fd = self.tun.handle,
                };
                _ = try nix.checked_ioctl(
                    @src(),
                    VirtioNetError.ActivateVHOST_NET_SET_BACKEND,
                    vhost.handle,
                    nix.VHOST_NET_SET_BACKEND,
                    &vring,
                );
            }
        }
        self.vhost = vhost;
    }

    pub fn write(self: *Self, addr: u64, data: []u8) !bool {
        if (addr < self.mmio_info.addr or self.mmio_info.addr + self.mmio_info.len - 1 < addr) {
            return false;
        }
        const offset = addr - self.mmio_info.addr;
        switch (self.virtio_context.write(offset, data)) {
            VirtioAction.NoAction => {},
            VirtioAction.ActivateDevice => try self.activate(),
            else => |action| {
                log.err(@src(), "unhandled write virtio action: {}", .{action});
            },
        }
        return true;
    }

    pub fn read(self: *Self, addr: u64, data: []u8) !bool {
        if (addr < self.mmio_info.addr or self.mmio_info.addr + self.mmio_info.len - 1 < addr) {
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
};
