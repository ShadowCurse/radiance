const std = @import("std");
const nix = @import("../nix.zig");
const log = @import("../log.zig");

const Vm = @import("../vm.zig");
const CmdLine = @import("../cmdline.zig");
const MmioDeviceInfo = @import("../mmio.zig").MmioDeviceInfo;
const EventFd = @import("../eventfd.zig");

// Impementation of 16550 UART device with baud of 9600

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

const FIFO_SIZE: usize = 0x40;

// IER : Interrupt enable register (R/W)
// Received data available
const IER_RDA_MASK: u8 = 1 << 0;
// Transmitter holding register empty
const IER_THR_EMPTY_MASK: u8 = 1 << 1;
// The interrupts that are available on 16550 and older models.
const IER_UART_VALID_MASK: u8 = 0xF;

// IIR : Interrupt identification register (RO)
// No interrupt pending
const IIR_NO_INT: u8 = 1;
// Transmitter holding register empty
const IIR_THR_EMPTY_MASK: u8 = 0b001 << 1;
// Received data available
const IIR_RDA_MASK: u8 = 0b010 << 1;
const IIR_FIFO_MASK: u8 = 0b1100_0000;

// LCR : Line control register (R/W)
// 0 -> DLAB : RBR, THR and IER accessible
// 1 -> DLAB : DLL and DLM accessible
const LCR_DLAB_MASK: u8 = 0b1000_0000;

// LSR : Line status register (RO)
// Data available
const LSR_DATA_READY_MASK: u8 = 1 << 0;
// THR is empty.
const LSR_THR_EMPTY_MASK: u8 = 1 << 5;
// THR is empty, and line is idle
const LSR_IDLE_MASK: u8 = 1 << 6;

// MCR : Modem control register (R/W)
// The following five MCR bits allow direct manipulation of the device and
// are available on 16550 and older models.
// Data terminal ready.
const MCR_DTR_MASK: u8 = 1 << 0;
// Request to send.
const MCR_RTS_MASK: u8 = 1 << 1;
// Auxiliary output 1.
const MCR_OUT1_MASK: u8 = 1 << 2;
// Auxiliary output 2.
const MCR_OUT2_MASK: u8 = 1 << 3;
// Loopback mode.
const MCR_LOOP_MASK: u8 = 1 << 4;

// MSR : Modem status register (RO)
// Clear to send.
const MSR_CTS_MASK: u8 = 1 << 4;
// Data set ready.
const MSR_DSR_MASK: u8 = 1 << 5;
// Ring indicator.
const MSR_RI_MASK: u8 = 1 << 6;
// Data carrier detect.
const MSR_DCD_MASK: u8 = 1 << 7;

// The following values can be used to set the baud rate to 9600 bps.
const DEFAULT_BAUD_DIVISOR_HIGH: u8 = 0x00;
const DEFAULT_BAUD_DIVISOR_LOW: u8 = 0x0C;

pub const UartError = error{
    New,
};

in: nix.fd_t,
out: nix.fd_t,

baud_divisor_low: u8,
baud_divisor_high: u8,
IER: u8,
IIR: u8,
LCR: u8,
LSR: u8,
MCR: u8,
MSR: u8,
SCR: u8,
// The RBR, receiver buffer register contains the byte received if no FIFO is used, or the oldest unread byte with FIFO’s.
// If FIFO buffering is used, each new read action of the register will return the next byte,
// until no more bytes are present. Bit 0 in the LSR line status register can be used to check
// if all received bytes have been read. This bit will change to zero if no more bytes are present.
// rbr: [FIFO_SIZE]u8,
fifo: std.fifo.LinearFifo(u8, std.fifo.LinearFifoBufferType{ .Static = FIFO_SIZE }),

irq_evt: EventFd,

const Self = @This();

pub fn new(vm: *const Vm, in: nix.fd_t, out: nix.fd_t, mmio_info: MmioDeviceInfo) !Self {
    const irq_evt = try EventFd.new(0, nix.EFD_NONBLOCK);
    const kvm_irqfd: nix.kvm_irqfd = .{
        .fd = @intCast(irq_evt.fd),
        .gsi = mmio_info.irq,
    };

    _ = try nix.checked_ioctl(
        @src(),
        UartError.New,
        vm.fd,
        nix.KVM_IRQFD,
        &kvm_irqfd,
    );

    return Self{
        .in = in,
        .out = out,

        .baud_divisor_low = DEFAULT_BAUD_DIVISOR_LOW,
        .baud_divisor_high = DEFAULT_BAUD_DIVISOR_HIGH,

        // No interrupts enabled.
        .IER = 0,
        .IIR = IIR_NO_INT,
        // 8 bits word length.
        .LCR = 0b0000_0011,
        // This is a virtual device and it should always be ready to received
        // data.
        .LSR = LSR_THR_EMPTY_MASK | LSR_IDLE_MASK,
        // Most UARTs need Auxiliary Output 2 set to '1' to enable interrupts.
        .MCR = MCR_OUT2_MASK,
        .MSR = MSR_DSR_MASK | MSR_CTS_MASK | MSR_DCD_MASK,
        .SCR = 0,
        .irq_evt = irq_evt,
        .fifo = std.fifo.LinearFifo(u8, std.fifo.LinearFifoBufferType{ .Static = FIFO_SIZE }).init(),
    };
}

pub fn add_to_cmdline(cmdline: *CmdLine, mmio_info: MmioDeviceInfo) !void {
    var buff: [50]u8 = undefined;
    const cmd = try std.fmt.bufPrint(&buff, " earlycon=uart,mmio,0x{x:.8}", .{mmio_info.addr});
    try cmdline.append(cmd);
}

pub fn read_input(self: *Self) !void {
    var buff: [8]u8 = undefined;
    const n = try nix.read(self.in, &buff);
    if (n <= 0) {
        return;
    }
    if (n <= self.fifo.writableLength() and !self.in_loop_mode()) {
        try self.fifo.write(buff[0..n]);
        self.LSR |= LSR_DATA_READY_MASK;
        try self.received_data_interrupt();
    }
}

fn dlab_set(self: *const Self) bool {
    return (self.LCR & LCR_DLAB_MASK) != 0;
}

fn rda_interrupt_enabled(self: *const Self) bool {
    return (self.IER & IER_RDA_MASK) != 0;
}

fn thr_interrupt_enabled(self: *const Self) bool {
    return (self.IER & IER_THR_EMPTY_MASK) != 0;
}

fn rda_interrupt_set(self: *const Self) bool {
    return (self.IIR & IIR_RDA_MASK) != 0;
}

fn thr_interrupt_set(self: *const Self) bool {
    return (self.IIR & IIR_THR_EMPTY_MASK) != 0;
}

fn in_loop_mode(self: *const Self) bool {
    return (self.MCR & MCR_LOOP_MASK) != 0;
}

fn add_interrupt(self: *Self, interrupt_bits: u8) void {
    self.IIR &= ~IIR_NO_INT;
    self.IIR |= interrupt_bits;
}

fn remove_interrupt(self: *Self, interrupt_bits: u8) void {
    self.IIR &= ~interrupt_bits;
    if (self.IIR == 0) {
        self.IIR = IIR_NO_INT;
    }
}

fn thr_empty_interrupt(self: *Self) !void {
    if (self.thr_interrupt_enabled()) {
        // Trigger the interrupt only if the identification bit wasn't
        // set or acknowledged.
        if ((self.IIR & IIR_THR_EMPTY_MASK) == 0) {
            self.add_interrupt(IIR_THR_EMPTY_MASK);
            try self.irq_evt.write(1);
        }
    }
}

fn received_data_interrupt(self: *Self) !void {
    if (self.rda_interrupt_enabled()) {
        // Trigger the interrupt only if the identification bit wasn't
        // set or acknowledged.
        if (self.IIR & IIR_RDA_MASK == 0) {
            self.add_interrupt(IIR_RDA_MASK);
            try self.irq_evt.write(1);
        }
    }
}

pub fn write(self: *Self, offset: u64, data: []u8) !void {
    const value = data[0];
    switch (offset) {
        0 => {
            if (self.dlab_set()) {
                self.baud_divisor_low = value;
            } else {
                if (self.in_loop_mode()) {
                    // In loopback mode, what is written in the transmit register
                    // will be immediately found in the receive register, so we
                    // simulate this behavior by adding in `in_buffer` the
                    // transmitted bytes and letting the driver know there is some
                    // pending data to be read, by setting RDA bit and its
                    // corresponding interrupt.
                    if (self.fifo.writeItem(value)) |_| {
                        self.LSR |= LSR_DATA_READY_MASK;
                        try self.received_data_interrupt();
                    } else |_| {}
                } else {
                    _ = try nix.write(self.out, data);

                    // Because we cannot block the driver, the THRE interrupt is sent
                    // irrespective of whether we are able to write the byte or not
                    try self.thr_empty_interrupt();
                }
            }
        },
        // We want to enable only the interrupts that are available for 16550A (and below).
        1 => {
            if (self.dlab_set()) {
                self.baud_divisor_high = value;
            } else {
                self.IER = value & IER_UART_VALID_MASK;
            }
        },
        3 => self.LCR = value,
        4 => self.MCR = value,
        7 => self.SCR = value,
        else => {},
    }
}

pub fn read(self: *Self, offset: u64, data: []u8) !void {
    data[0] = switch (offset) {
        0 => blk: {
            if (self.dlab_set()) {
                break :blk self.baud_divisor_low;
            } else {
                // Here we emulate the reset method for when RDA interrupt
                // was raised (i.e. read the receive buffer and clear the
                // interrupt identification register and RDA bit when no
                // more data is available).
                self.remove_interrupt(IIR_RDA_MASK);
                const byte = self.fifo.readItem() orelse 0;
                if (self.fifo.count == 0) {
                    self.LSR &= ~LSR_DATA_READY_MASK;
                }
                break :blk byte;
            }
        },
        1 => blk: {
            if (self.dlab_set()) {
                break :blk self.baud_divisor_high;
            } else {
                break :blk self.IER;
            }
        },
        2 => blk: {
            // We're enabling FIFO capability by setting the serial port to 16550A:
            // https://elixir.bootlin.com/linux/latest/source/drivers/tty/serial/8250/8250_port.c#L1299.
            const iir = self.IIR | IIR_FIFO_MASK;
            // resetting IIR
            self.IIR = IIR_NO_INT;
            break :blk iir;
        },
        3 => self.LCR,
        4 => self.MCR,
        5 => self.LSR,
        6 => blk: {
            if (self.in_loop_mode()) {
                // In loopback mode, the four modem control inputs (CTS, DSR, RI, DCD) are
                // internally connected to the four modem control outputs (RTS, DTR, OUT1, OUT2).
                // This way CTS is controlled by RTS, DSR by DTR, RI by OUT1 and DCD by OUT2.
                // (so they will basically contain the same value).
                var msr =
                    self.MSR & ~(MSR_DSR_MASK | MSR_CTS_MASK | MSR_RI_MASK | MSR_DCD_MASK);
                if ((self.MCR & MCR_DTR_MASK) != 0) {
                    msr |= MSR_DSR_MASK;
                }
                if ((self.MCR & MCR_RTS_MASK) != 0) {
                    msr |= MSR_CTS_MASK;
                }
                if ((self.MCR & MCR_OUT1_MASK) != 0) {
                    msr |= MSR_RI_MASK;
                }
                if ((self.MCR & MCR_OUT2_MASK) != 0) {
                    msr |= MSR_DCD_MASK;
                }
                break :blk msr;
            } else {
                break :blk self.MSR;
            }
        },
        7 => self.SCR,
        else => 0,
    };
}
