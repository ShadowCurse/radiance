const nix = @import("../nix.zig");
const log = @import("../log.zig");

const Vm = @import("../vm.zig");
const Mmio = @import("../mmio.zig");
const Memory = @import("../memory.zig");
const _virtio = @import("../virtio/context.zig");
const VirtioContext = _virtio.VirtioContext;

pub const TYPE_NET: u32 = 1;

pub const Config = extern struct {
    mac: [6]u8,
};
pub const QueueSizes = .{ 256, 256 };

pub const VhostNet = struct {
    memory: *Memory,
    context: VIRTIO_CONTEXT,

    tun: nix.fd_t,
    vhost: ?nix.fd_t,

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
            "VhostNet dev_name: {s} is larger than maxinum allowed size: {d}",
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

        return .{
            .memory = memory,
            .context = virtio_context,
            .tun = tun,
            .vhost = null,
        };
    }

    pub fn activate(
        self: *Self,
        comptime System: type,
    ) void {
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
        if (self.context.acked_features & (1 << nix.VIRTIO_NET_F_GUEST_USO4) != 0) {
            tun_flags |= nix.TUN_F_USO4;
        }
        if (self.context.acked_features & (1 << nix.VIRTIO_NET_F_GUEST_USO6) != 0) {
            tun_flags |= nix.TUN_F_USO6;
        }
        _ = nix.assert(@src(), System, "ioctl", .{
            self.tun,
            nix.TUNSETOFFLOAD,
            tun_flags,
        });

        const vhost = nix.assert(@src(), System, "open", .{
            "/dev/vhost-net",
            .{
                .CLOEXEC = true,
                .NONBLOCK = true,
                .ACCMODE = .RDWR,
            },
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
