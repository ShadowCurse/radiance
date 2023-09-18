const std = @import("std");

const CmdLine = @import("../cmdline.zig").CmdLine;
const MmioDeviceInfo = @import("../mmio.zig").MmioDeviceInfo;

// Register offsets.
// Receiver and Transmitter registers offset, depending on the I/O
// access type: write -> THR, read -> RBR.
const DATA_OFFSET: u8 = 0;
const IER_OFFSET: u8 = 1;
const IIR_OFFSET: u8 = 2;
const LCR_OFFSET: u8 = 3;
const MCR_OFFSET: u8 = 4;
const LSR_OFFSET: u8 = 5;
const MSR_OFFSET: u8 = 6;
const SCR_OFFSET: u8 = 7;
const DLAB_LOW_OFFSET: u8 = 0;
const DLAB_HIGH_OFFSET: u8 = 1;

const FIFO_SIZE: usize = 0x40;

// Received Data Available interrupt - for letting the driver know that
// there is some pending data to be processed.
const IER_RDA_BIT: u8 = 0b0000_0001;
// Transmitter Holding Register Empty interrupt - for letting the driver
// know that the entire content of the output buffer was sent.
const IER_THR_EMPTY_BIT: u8 = 0b0000_0010;
// The interrupts that are available on 16550 and older models.
const IER_UART_VALID_BITS: u8 = 0b0000_1111;

//FIFO enabled.
const IIR_FIFO_BITS: u8 = 0b1100_0000;
const IIR_NONE_BIT: u8 = 0b0000_0001;
const IIR_THR_EMPTY_BIT: u8 = 0b0000_0010;
const IIR_RDA_BIT: u8 = 0b0000_0100;

const LCR_DLAB_BIT: u8 = 0b1000_0000;

const LSR_DATA_READY_BIT: u8 = 0b0000_0001;
// These two bits help the driver know if the device is ready to accept
// another character.
// THR is empty.
const LSR_EMPTY_THR_BIT: u8 = 0b0010_0000;
// The shift register, which takes a byte from THR and breaks it in bits
// for sending them on the line, is empty.
const LSR_IDLE_BIT: u8 = 0b0100_0000;

// The following five MCR bits allow direct manipulation of the device and
// are available on 16550 and older models.
// Data Terminal Ready.
const MCR_DTR_BIT: u8 = 0b0000_0001;
// Request To Send.
const MCR_RTS_BIT: u8 = 0b0000_0010;
// Auxiliary Output 1.
const MCR_OUT1_BIT: u8 = 0b0000_0100;
// Auxiliary Output 2.
const MCR_OUT2_BIT: u8 = 0b0000_1000;
// Loopback Mode.
const MCR_LOOP_BIT: u8 = 0b0001_0000;

// Clear To Send.
const MSR_CTS_BIT: u8 = 0b0001_0000;
// Data Set Ready.
const MSR_DSR_BIT: u8 = 0b0010_0000;
// Ring Indicator.
const MSR_RI_BIT: u8 = 0b0100_0000;
// Data Carrier Detect.
const MSR_DCD_BIT: u8 = 0b1000_0000;

// The following values can be used to set the baud rate to 9600 bps.
const DEFAULT_BAUD_DIVISOR_HIGH: u8 = 0x00;
const DEFAULT_BAUD_DIVISOR_LOW: u8 = 0x0C;

// No interrupts enabled.
const DEFAULT_INTERRUPT_ENABLE: u8 = 0x00;
// No pending interrupt.
const DEFAULT_INTERRUPT_IDENTIFICATION: u8 = IIR_NONE_BIT;
// We're setting the default to include LSR_EMPTY_THR_BIT and LSR_IDLE_BIT
// and never update those bits because we're working with a virtual device,
// hence we should always be ready to receive more data.
const DEFAULT_LINE_STATUS: u8 = LSR_EMPTY_THR_BIT | LSR_IDLE_BIT;
// 8 bits word length.
const DEFAULT_LINE_CONTROL: u8 = 0b0000_0011;
// Most UARTs need Auxiliary Output 2 set to '1' to enable interrupts.
const DEFAULT_MODEM_CONTROL: u8 = MCR_OUT2_BIT;
const DEFAULT_MODEM_STATUS: u8 = MSR_DSR_BIT | MSR_CTS_BIT | MSR_DCD_BIT;
const DEFAULT_SCRATCH: u8 = 0x00;

pub const Uart = struct {
    in: std.os.fd_t,
    out: std.os.fd_t,
    mmio_info: MmioDeviceInfo,

    // Some UART registers.
    baud_divisor_low: u8,
    baud_divisor_high: u8,
    interrupt_enable: u8,
    interrupt_identification: u8,
    line_control: u8,
    line_status: u8,
    modem_control: u8,
    modem_status: u8,
    scratch: u8,
    // This is the buffer that is used for achieving the Receiver register
    // functionality in FIFO mode. Reading from RBR will return the oldest
    // unread byte from the RX FIFO.
    // in_buffer: VecDeque<u8>,

    // Used for notifying the driver about some in/out events.
    // interrupt_evt: T,
    // events: EV,
    // out: W,

    const Self = @This();

    pub fn new(in: std.os.fd_t, out: std.os.fd_t, mmio_info: MmioDeviceInfo) Self {
        return Self{
            .in = in,
            .out = out,
            .mmio_info = mmio_info,

            .baud_divisor_low = DEFAULT_BAUD_DIVISOR_LOW,
            .baud_divisor_high = DEFAULT_BAUD_DIVISOR_HIGH,
            .interrupt_enable = DEFAULT_INTERRUPT_ENABLE,
            .interrupt_identification = DEFAULT_INTERRUPT_IDENTIFICATION,
            .line_control = DEFAULT_LINE_CONTROL,
            .line_status = DEFAULT_LINE_STATUS,
            .modem_control = DEFAULT_MODEM_CONTROL,
            .modem_status = DEFAULT_MODEM_STATUS,
            .scratch = DEFAULT_SCRATCH,
        };
    }

    pub fn add_to_cmdline(self: *const Self, cmdline: *CmdLine) !void {
        var buff: [50]u8 = undefined;
        const cmd = try std.fmt.bufPrint(&buff, " earlycon=uart,mmio,0x{x:.8}", .{self.mmio_info.addr});
        try cmdline.append(cmd);
    }

    fn is_dlab_set(self: *const Self) bool {
        return (self.line_control & LCR_DLAB_BIT) != 0;
    }

    fn is_rda_interrupt_enabled(self: *const Self) bool {
        return (self.interrupt_enable & IER_RDA_BIT) != 0;
    }

    fn is_thr_interrupt_enabled(self: *const Self) bool {
        return (self.interrupt_enable & IER_THR_EMPTY_BIT) != 0;
    }

    fn is_rda_interrupt_set(self: *const Self) bool {
        return (self.interrupt_identification & IIR_RDA_BIT) != 0;
    }

    fn is_thr_interrupt_set(self: *const Self) bool {
        return (self.interrupt_identification & IIR_THR_EMPTY_BIT) != 0;
    }

    fn is_in_loop_mode(self: *const Self) bool {
        return (self.modem_control & MCR_LOOP_BIT) != 0;
    }

    // fn trigger_interrupt(&mut self) -> Result<(), T::E> {
    //     self.interrupt_evt.trigger()
    // }

    fn set_lsr_rda_bit(self: *Self) void {
        self.line_status |= LSR_DATA_READY_BIT;
    }

    fn clear_lsr_rda_bit(self: *Self) void {
        self.line_status &= ~LSR_DATA_READY_BIT;
    }

    fn add_interrupt(self: *Self, interrupt_bits: u8) void {
        self.interrupt_identification &= ~IIR_NONE_BIT;
        self.interrupt_identification |= interrupt_bits;
    }

    fn del_interrupt(self: *Self, interrupt_bits: u8) void {
        self.interrupt_identification &= ~interrupt_bits;
        if (self.interrupt_identification == 0) {
            self.interrupt_identification = IIR_NONE_BIT;
        }
    }

    fn thr_empty_interrupt(self: *Self) !void {
        if (self.is_thr_interrupt_enabled()) {
            // Trigger the interrupt only if the identification bit wasn't
            // set or acknowledged.
            if ((self.interrupt_identification & IIR_THR_EMPTY_BIT) == 0) {
                self.add_interrupt(IIR_THR_EMPTY_BIT);
                // self.trigger_interrupt()?
            }
        }
    }

    // fn received_data_interrupt(&mut self) -> Result<(), T::E> {
    //     if self.is_rda_interrupt_enabled() {
    //         // Trigger the interrupt only if the identification bit wasn't
    //         // set or acknowledged.
    //         if self.interrupt_identification & IIR_RDA_BIT == 0 {
    //             self.add_interrupt(IIR_RDA_BIT);
    //             self.trigger_interrupt()?
    //         }
    //     }
    //     Ok(())
    // }

    fn reset_iir(self: *Self) void {
        self.interrupt_identification = DEFAULT_INTERRUPT_IDENTIFICATION;
    }

    /// Handles a write request from the driver at `offset` offset from the
    /// base Port I/O address.
    ///
    /// # Arguments
    /// * `offset` - The offset that will be added to the base PIO address
    ///              for writing to a specific register.
    /// * `value` - The byte that should be written.
    ///
    /// # Example
    ///
    /// You can see an example of how to use this function in the
    /// [`Example` section from `Serial`](struct.Serial.html#example).
    pub fn write(self: *Self, addr: u64, data: []u8) !bool {
        // pub fn write(self: *Self, offset: u8, value: u8) !void {
        if (addr < self.mmio_info.addr or self.mmio_info.addr + self.mmio_info.len < addr) {
            return false;
        }
        const offset = addr - self.mmio_info.addr;
        const value = data[0];
        switch (offset) {
            DATA_OFFSET => {
                if (self.is_dlab_set()) {
                    self.baud_divisor_low = value;
                } else {
                    if (self.is_in_loop_mode()) {
                        // In loopback mode, what is written in the transmit register
                        // will be immediately found in the receive register, so we
                        // simulate this behavior by adding in `in_buffer` the
                        // transmitted bytes and letting the driver know there is some
                        // pending data to be read, by setting RDA bit and its
                        // corresponding interrupt.
                        // if (self.in_buffer.len() < FIFO_SIZE) {
                        // self.in_buffer.push_back(value);
                        self.set_lsr_rda_bit();
                        // try self.received_data_interrupt();
                        // }
                    } else {
                        _ = try std.os.write(self.out, data);

                        // Because we cannot block the driver, the THRE interrupt is sent
                        // irrespective of whether we are able to write the byte or not
                        try self.thr_empty_interrupt();
                    }
                }
            },
            // We want to enable only the interrupts that are available for 16550A (and below).
            IER_OFFSET => {
                if (self.is_dlab_set()) {
                    self.baud_divisor_high = value;
                } else {
                    self.interrupt_enable = value & IER_UART_VALID_BITS;
                }
            },
            LCR_OFFSET => self.line_control = value,
            MCR_OFFSET => self.modem_control = value,
            SCR_OFFSET => self.scratch = value,
            // We are not interested in writing to other offsets (such as FCR offset).
            else => {},
        }
        return true;
    }

    /// Handles a read request from the driver at `offset` offset from the
    /// base Port I/O address.
    ///
    /// Returns the read value.
    ///
    /// # Arguments
    /// * `offset` - The offset that will be added to the base PIO address
    ///              for reading from a specific register.
    ///
    /// # Example
    ///
    /// You can see an example of how to use this function in the
    /// [`Example` section from `Serial`](struct.Serial.html#example).
    pub fn read(self: *Self, addr: u64, data: []u8) !bool {
        if (addr < self.mmio_info.addr or self.mmio_info.addr + self.mmio_info.len < addr) {
            return false;
        }
        const offset = addr - self.mmio_info.addr;
        const val = switch (offset) {
            DATA_OFFSET => blk: {
                if (self.is_dlab_set()) {
                    break :blk self.baud_divisor_low;
                } else {
                    // Here we emulate the reset method for when RDA interrupt
                    // was raised (i.e. read the receive buffer and clear the
                    // interrupt identification register and RDA bit when no
                    // more data is available).
                    self.del_interrupt(IIR_RDA_BIT);
                    const byte = 0; //self.in_buffer.pop_front().unwrap_or_default();
                    // if (self.in_buffer.is_empty()) {
                    self.clear_lsr_rda_bit();
                    // self.events.in_buffer_empty();
                    // }
                    // self.events.buffer_read();
                    break :blk byte;
                }
            },
            IER_OFFSET => blk: {
                if (self.is_dlab_set()) {
                    break :blk self.baud_divisor_high;
                } else {
                    break :blk self.interrupt_enable;
                }
            },
            IIR_OFFSET => blk: {
                // We're enabling FIFO capability by setting the serial port to 16550A:
                // https://elixir.bootlin.com/linux/latest/source/drivers/tty/serial/8250/8250_port.c#L1299.
                const iir = self.interrupt_identification | IIR_FIFO_BITS;
                self.reset_iir();
                break :blk iir;
            },
            LCR_OFFSET => self.line_control,
            MCR_OFFSET => self.modem_control,
            LSR_OFFSET => self.line_status,
            MSR_OFFSET => blk: {
                if (self.is_in_loop_mode()) {
                    // In loopback mode, the four modem control inputs (CTS, DSR, RI, DCD) are
                    // internally connected to the four modem control outputs (RTS, DTR, OUT1, OUT2).
                    // This way CTS is controlled by RTS, DSR by DTR, RI by OUT1 and DCD by OUT2.
                    // (so they will basically contain the same value).
                    var msr =
                        self.modem_status & ~(MSR_DSR_BIT | MSR_CTS_BIT | MSR_RI_BIT | MSR_DCD_BIT);
                    if ((self.modem_control & MCR_DTR_BIT) != 0) {
                        msr |= MSR_DSR_BIT;
                    }
                    if ((self.modem_control & MCR_RTS_BIT) != 0) {
                        msr |= MSR_CTS_BIT;
                    }
                    if ((self.modem_control & MCR_OUT1_BIT) != 0) {
                        msr |= MSR_RI_BIT;
                    }
                    if ((self.modem_control & MCR_OUT2_BIT) != 0) {
                        msr |= MSR_DCD_BIT;
                    }
                    break :blk msr;
                } else {
                    break :blk self.modem_status;
                }
            },
            SCR_OFFSET => self.scratch,
            else => 0,
        };
        data[0] = val;
        return true;
    }
};
