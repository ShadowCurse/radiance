const nix = @import("nix.zig");

// KVM_CAP_ADJUST_CLOCK - enable this for CMOS emulation by the KVM
const COM1_BASE: u16 = 0x3f8;

var cmos_index: u8 = 0;

pub const Result = union(enum) {
    handled,
    uart_write: struct { u16, []u8 },
    uart_read: struct { u16, []u8 },
    exit,
};
pub fn handle(kvm_run: *nix.kvm_run) Result {
    const io = &kvm_run.kvm_exit_info.io;
    const kvm_run_ptr: [*]u8 = @ptrCast(kvm_run);
    var data: []u8 = undefined;
    data.ptr = kvm_run_ptr + io.data_offset;
    data.len = io.count * io.size;

    //0x70/0x71  CMOS RTC        — implement stub
    //0x3f8-0x3ff COM1 UART      — reuse 16550
    //0x60/0x64  PS/2 keyboard   — return 0xff or ignore
    //0x80       POST code port  — ignore writes
    //0xcf8/0xcfc PCI config     — already seeing these
    //0x3c0-0x3df VGA            — ignore
    //0x20/0x21  PIC master      — may need basic stub
    //0xa0/0xa1  PIC slave       — may need basic stub
    switch (io.port) {
        COM1_BASE...COM1_BASE + 7 => {
            const offset = io.port - COM1_BASE;
            if (io.direction == .in)
                return .{ .uart_read = .{ offset, data } }
            else if (io.direction == .out)
                return .{ .uart_write = .{ offset, data } };
        },
        0x64 => {
            if (io.direction == .out and data[0] == 0xfe) {
                return .exit;
            } else @memset(data, 0);
        },
        0x70 => {
            if (io.direction == .out) cmos_index = data[0] & 0x7f; // mask NMI bit
        },
        0x71 => {
            if (io.direction == .in) {
                data[0] = switch (cmos_index) {
                    0x0a => 0x00, // not updating
                    0x0b => 0x02, // 24hr mode, binary mode
                    0x0d => 0x80, // valid RAM and time
                    else => 0x00,
                };
            }
        },
        0xcf8...0xcfc => if (io.direction == .in) @memset(data, 0xff),
        else => if (io.direction == .in) @memset(data, 0),
    }
    return .handled;
}
