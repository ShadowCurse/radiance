const std = @import("std");
const log = @import("../log.zig");
const nix = @import("../nix.zig");

const Vm = @import("../vm.zig");
const CmdLine = @import("../cmdline.zig");
const Mmio = @import("../mmio.zig");
const EventFd = @import("../eventfd.zig");
const RingBuffer = @import("../ring_buffer.zig").RingBuffer;

// https://uart16550.readthedocs.io/en/latest/uart16550doc.html
// From  https://www.lammertbies.nl/comm/info/serial-uart
//
// I/O port | Read (DLAB=0)                | Write (DLAB=0)          | Read (DLAB=1)                | Write (DLAB=1)
// -------------------------------------------------------------------------------------------------------------------------
// base     | RBR receiver buffer          | THR transmitter holding | DLL divisor latch  LSB       | DLL divisor latch LSB
// base+1   | IER interrupt enable         | IER interrupt enable    | DLM divisor latch MSB        | DLM divisor latch MSB
// base+2   | IIR interrupt identification | FCR FIFO control        | IIR interrupt identification | FCR FIFO control
// base+3   | LCR line control             | LCR line control        | LCR line control             | LCR line control
// base+4   | MCR modem control            | MCR modem control       | MCR modem control            | MCR modem control
// base+5   | LSR line status              | factory test            | LSR line status              | factory test
// base+6   | MSR modem status             | not used                | MSR modem status             | not used
// base+7   | SCR scratch                  | SCR scratch             | SCR scratch                  | SCR scratch

const IER = packed struct(u8) {
    receive_data_available: bool = false,
    transmitter_holding_register_empty: bool = false,
    _: u6 = 0,
};

const IIR = packed struct(u8) {
    no_pending_interrupt: bool = false,
    status: enum(u3) {
        modem_status_change,
        transmitter_holding_register_empty,
        receive_data_available,
        line_status_change,
        _,
    } = .modem_status_change,
    _: u2 = 0,
    fifo: enum(u2) {
        no_fifo,
        unusable_fifo,
        unknown,
        fifo_enabled,
    } = .no_fifo,
};

const LCR = packed struct(u8) {
    data_bits: enum(u2) {
        @"5bits",
        @"6bits",
        @"7bits",
        @"8bits",
    } = .@"5bits",
    stop_bits: enum(u1) {
        @"1bit",
        @"2bit",
    } = .@"1bit",
    parity_bits: u3 = 0,
    break_signal: bool = false,
    dlab: bool = false,
};

const LSR = packed struct(u8) {
    data_available: bool = false,
    overrun_error: bool = false,
    parity_error: bool = false,
    framing_error: bool = false,
    break_signal_recieved: bool = false,
    thr_empty: bool = false,
    thr_empty_and_line_is_idle: bool = false,
    error_data_in_fifo: bool = false,
};

const MCR = packed struct(u8) {
    data_terminal_ready: bool = false,
    request_to_send: bool = false,
    auxiliary_output_1: bool = false,
    auxiliary_output_2: bool = false,
    loopback_mode: bool = false,
    autoflow_control: bool = false,
    _: u2 = 0,
};

const MSR = packed struct(u8) {
    change_in_clear_to_send: bool = false,
    change_in_data_set_ready: bool = false,
    trailing_edge_ring_indicator: bool = false,
    change_in_carrier_detect: bool = false,
    clear_to_send: bool = false,
    data_set_ready: bool = false,
    ring_indicator: bool = false,
    carrier_detect: bool = false,
};

const SCR = packed struct(u8) {
    _: u8 = 0,
};

// The following values can be used to set the baud rate to 9600 bps.
const DEFAULT_BAUD_DIVISOR_HIGH: u8 = 0x00;
const DEFAULT_BAUD_DIVISOR_LOW: u8 = 0x0C;

in: nix.fd_t,
out: nix.fd_t,
irq_evt: EventFd,

baud_divisor_low: u8,
baud_divisor_high: u8,
ier: IER,
iir: IIR,
lcr: LCR,
lsr: LSR,
mcr: MCR,
msr: MSR,
scr: SCR,
fifo: RingBuffer(u8, 64),

const Self = @This();

pub fn new(
    comptime System: type,
    vm: *const Vm,
    in: nix.fd_t,
    out: nix.fd_t,
    mmio_info: Mmio.Resources.MmioInfo,
) Self {
    const irq_evt = EventFd.new(System, 0, nix.EFD_NONBLOCK);
    const kvm_irqfd: nix.kvm_irqfd = .{
        .fd = @intCast(irq_evt.fd),
        .gsi = mmio_info.irq,
    };

    _ = nix.assert(@src(), System, "ioctl", .{
        vm.fd,
        nix.KVM_IRQFD,
        @intFromPtr(&kvm_irqfd),
    });

    return Self{
        .in = in,
        .out = out,
        .irq_evt = irq_evt,
        .baud_divisor_low = DEFAULT_BAUD_DIVISOR_LOW,
        .baud_divisor_high = DEFAULT_BAUD_DIVISOR_HIGH,
        .ier = .{},
        .iir = .{ .no_pending_interrupt = true, .fifo = .fifo_enabled },
        .lcr = .{ .data_bits = .@"8bits" },
        .lsr = .{ .thr_empty = true, .thr_empty_and_line_is_idle = true },
        .mcr = .{ .auxiliary_output_2 = true },
        .msr = .{ .clear_to_send = true, .data_set_ready = true, .carrier_detect = true },
        .scr = .{},
        .fifo = .empty,
    };
}

pub fn add_to_cmdline(cmdline: *CmdLine, mmio_info: Mmio.Resources.MmioInfo) !void {
    var buff: [50]u8 = undefined;
    const cmd = try std.fmt.bufPrint(
        &buff,
        " console=ttyS0 earlycon=uart,mmio,0x{x:.8}",
        .{mmio_info.addr},
    );
    try cmdline.append(cmd);
}

pub fn event_read_input(self: *Self) void {
    self.read_input(nix.System);
}
pub fn read_input(self: *Self, comptime System: type) void {
    var buff: [8]u8 = undefined;
    const n = nix.assert(@src(), System, "read", .{ self.in, &buff });
    if (n <= self.fifo.remaining_len() and !self.mcr.loopback_mode) {
        self.fifo.push_back_slice(buff[0..n]);
        self.lsr.data_available = true;
        self.received_data_interrupt(System);
    }
}

fn transmitter_interrupt(self: *Self, comptime System: type) void {
    if (self.ier.transmitter_holding_register_empty and
        self.iir.status != .transmitter_holding_register_empty)
    {
        self.iir.no_pending_interrupt = false;
        self.iir.status = .transmitter_holding_register_empty;
        self.irq_evt.write(System, 1);
    }
}

fn received_data_interrupt(self: *Self, comptime System: type) void {
    if (self.ier.receive_data_available and
        self.iir.status != .receive_data_available)
    {
        self.iir.no_pending_interrupt = false;
        self.iir.status = .receive_data_available;
        self.irq_evt.write(System, 1);
    }
}

pub fn write_default(self: *Self, offset: u64, data: []u8) void {
    self.write(nix.System, offset, data);
}
pub fn write(self: *Self, comptime System: type, offset: u64, data: []u8) void {
    log.assert(@src(), data.len == 1, "Invalid uart wrtie data length: {d} != 1", .{data.len});
    const value = data[0];
    switch (offset) {
        0 => {
            if (self.lcr.dlab) {
                self.baud_divisor_low = value;
            } else {
                if (self.mcr.loopback_mode) {
                    self.fifo.push_back(value);
                    self.lsr.data_available = true;
                    self.received_data_interrupt(System);
                } else {
                    _ = nix.assert(@src(), System, "write", .{ self.out, data });
                    self.transmitter_interrupt(System);
                }
            }
        },
        // We want to enable only the interrupts that are available for 16550A (and below).
        1 => {
            if (self.lcr.dlab) {
                self.baud_divisor_high = value;
            } else {
                self.ier = @bitCast(value);
            }
        },
        3 => self.lcr = @bitCast(value),
        4 => self.mcr = @bitCast(value & 0x1f),
        7 => self.scr = @bitCast(value),
        else => {},
    }
}

pub fn read(self: *Self, offset: u64, data: []u8) void {
    log.assert(@src(), data.len == 1, "Invalid uart read data length: {d} != 1", .{data.len});
    data[0] = switch (offset) {
        0 => blk: {
            if (self.lcr.dlab) {
                break :blk self.baud_divisor_low;
            } else {
                self.iir.status = .modem_status_change;
                self.iir.no_pending_interrupt = true;
                const byte = self.fifo.pop_front() orelse 0;
                if (self.fifo.len == 0) {
                    self.lsr.data_available = false;
                    self.lsr.break_signal_recieved = false;
                }
                break :blk byte;
            }
        },
        1 => blk: {
            if (self.lcr.dlab) {
                break :blk self.baud_divisor_high;
            } else {
                break :blk @bitCast(self.ier);
            }
        },
        2 => blk: {
            const r: u8 = @bitCast(self.iir);
            if (self.iir.status == .transmitter_holding_register_empty) {
                self.iir.status = .modem_status_change;
                self.iir.no_pending_interrupt = true;
            }
            break :blk r;
        },
        3 => @bitCast(self.lcr),
        4 => @bitCast(self.mcr),
        5 => @bitCast(self.lsr),
        6 => blk: {
            if (self.mcr.loopback_mode) {
                const msr: MSR = .{
                    .clear_to_send = self.mcr.request_to_send,
                    .data_set_ready = self.mcr.data_terminal_ready,
                    .ring_indicator = self.mcr.auxiliary_output_1,
                    .carrier_detect = self.mcr.auxiliary_output_2,
                };
                break :blk @bitCast(msr);
            } else {
                break :blk @bitCast(self.msr);
            }
        },
        7 => @bitCast(self.scr),
        else => 0,
    };
}
