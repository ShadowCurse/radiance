const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig");
const nix = @import("nix.zig");
const arch = @import("arch.zig");

const EventLoop = @import("event_loop.zig");
const Memory = @import("memory.zig");
const Mmio = @import("mmio.zig");
const Vcpu = @import("vcpu.zig");

fn fmt_hex_bytes(buf: []u8, bytes: []const u8) void {
    log.assert(@src(), bytes.len / 2 <= buf.len, "{d} < {d}", .{ buf.len, bytes.len / 2 });
    const hex_chars = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        buf[i * 2] = hex_chars[b >> 4];
        buf[i * 2 + 1] = hex_chars[b & 0xf];
    }
}

fn fmt_hex(comptime R: type, buf: []u8, value: R) u32 {
    fmt_hex_bytes(buf, @ptrCast(&value));
    return @sizeOf(R) * 2;
}

fn fmt_response(buffer: []u8, msg: []const u8) ![]const u8 {
    var sum: u32 = 0;
    for (msg) |b| sum += b;
    const checksum: u8 = @truncate(sum);
    return std.fmt.bufPrint(buffer, "+${s}#{x:0>2}", .{ msg, checksum });
}

fn parse_hex_bytes(hex: []const u8, out: []u8) ?usize {
    if (hex.len % 2 != 0) return null;
    const len = hex.len / 2;
    if (out.len < len) return null;
    for (0..len) |i| out[i] = std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16) catch return null;
    return len;
}

fn parse_hex(comptime TT: type, hex: []const u8) ?u64 {
    var result: TT = undefined;
    const buf: []u8 = @ptrCast(&result);
    const len = parse_hex_bytes(hex, buf) orelse return null;
    if (@sizeOf(TT) < len) return null;
    return result;
}

fn get_x64_reg(vcpu: *Vcpu, reg_num: u64) ?u64 {
    // GP registers and rip/rflags
    if (reg_num <= 17) {
        var kvm_regs: nix.kvm_regs = undefined;
        _ = nix.assert(@src(), nix.System, "ioctl", .{
            vcpu.fd,
            nix.KVM_GET_REGS,
            @intFromPtr(&kvm_regs),
        });
        return switch (reg_num) {
            0 => kvm_regs.rax,
            1 => kvm_regs.rbx,
            2 => kvm_regs.rcx,
            3 => kvm_regs.rdx,
            4 => kvm_regs.rsi,
            5 => kvm_regs.rdi,
            6 => kvm_regs.rbp,
            7 => kvm_regs.rsp,
            8 => kvm_regs.r8,
            9 => kvm_regs.r9,
            10 => kvm_regs.r10,
            11 => kvm_regs.r11,
            12 => kvm_regs.r12,
            13 => kvm_regs.r13,
            14 => kvm_regs.r14,
            15 => kvm_regs.r15,
            16 => kvm_regs.rip,
            17 => kvm_regs.rflags,
            else => unreachable,
        };
    }
    // Segment registers (18-23: cs, ss, ds, es, fs, gs)
    // fs_base (58/0x3a), gs_base (59/0x3b)
    if ((18 <= reg_num and reg_num <= 23) or reg_num == 58 or reg_num == 59) {
        var kvm_sregs: nix.kvm_sregs = undefined;
        _ = nix.assert(@src(), nix.System, "ioctl", .{
            vcpu.fd,
            nix.KVM_GET_SREGS,
            @intFromPtr(&kvm_sregs),
        });
        return switch (reg_num) {
            18 => kvm_sregs.cs.selector,
            19 => kvm_sregs.ss.selector,
            20 => kvm_sregs.ds.selector,
            21 => kvm_sregs.es.selector,
            22 => kvm_sregs.fs.selector,
            23 => kvm_sregs.gs.selector,
            58 => kvm_sregs.fs.base,
            59 => kvm_sregs.gs.base,
            else => unreachable,
        };
    }
    // FPU control registers (32-39) and mxcsr (56) are 32-bit, fit in u64
    if ((32 <= reg_num and reg_num <= 39) or reg_num == 56) {
        var kvm_fpu: nix.kvm_fpu = undefined;
        _ = nix.assert(@src(), nix.System, "ioctl", .{
            vcpu.fd,
            nix.KVM_GET_FPU,
            @intFromPtr(&kvm_fpu),
        });
        return switch (reg_num) {
            32 => @as(u32, kvm_fpu.fcw),
            33 => @as(u32, kvm_fpu.fsw),
            34 => @as(u32, kvm_fpu.ftwx),
            35 => 0, // fiseg (not used in 64-bit mode)
            36 => @truncate(kvm_fpu.last_ip),
            37 => 0, // foseg (not used in 64-bit mode)
            38 => @truncate(kvm_fpu.last_dp),
            39 => @as(u32, kvm_fpu.last_opcode),
            56 => kvm_fpu.mxcsr,
            else => unreachable,
        };
    }
    return null;
}

// Bind the read/write to 256 bytes just to have
// fixed buffers
const MAX_READ_LEN = 256;
const MAX_WRITE_LEN = 256;

const PAGE_SHIFT = std.math.log2_int_ceil(u64, Memory.HOST_PAGE_SIZE);
const PAGE_SIZE = 1 << PAGE_SHIFT;
const PAGE_MASK: u64 = PAGE_SIZE - 1;

// Page table constants for aarch64
const PTE_VALID: u64 = 1 << 0;
const PTE_TABLE: u64 = 1 << 1;

fn read_memory_at_gpa(
    buffer: []u8,
    memory: *const Memory.Guest,
    gpa: u64,
    length: u64,
) ![]const u8 {
    var hex_buffer: [MAX_READ_LEN * 2]u8 = undefined;
    const slice = memory.get_slice(u8, length, gpa);
    fmt_hex_bytes(&hex_buffer, @volatileCast(slice));
    return fmt_response(buffer, hex_buffer[0 .. length * 2]);
}

fn write_memory_at_gpa(
    buffer: []u8,
    memory: *const Memory.Guest,
    gpa: u64,
    data_hex: []const u8,
    length: u64,
) ![]const u8 {
    var data_buf: [MAX_WRITE_LEN]u8 = undefined;
    const count = parse_hex_bytes(data_hex, &data_buf) orelse return fmt_response(buffer, "E01");
    if (count != length) return fmt_response(buffer, "E01");

    const slice = memory.get_slice(u8, length, gpa);
    @memcpy(slice, data_buf[0..length]);
    return fmt_response(buffer, "OK");
}

fn translate_gva(vcpu: *Vcpu, memory: *const Memory.Guest, gva: u64) ?u64 {
    if (builtin.cpu.arch == .aarch64) {
        return translate_gva_aarch64(vcpu, memory, gva);
    } else if (builtin.cpu.arch == .x86_64) {
        return translate_gva_x64(vcpu, gva);
    } else @compileError("Only aarch64 and x64 are supported");
    return null;
}

fn translate_gva_x64(vcpu: *Vcpu, gva: u64) ?u64 {
    var translation: nix.kvm_translation = .{ .linear_address = gva };
    const ret = nix.System.ioctl(vcpu.fd, nix.KVM_TRANSLATE, @intFromPtr(&translation));
    if (ret < 0) return null;
    if (translation.valid == 0) return null;

    // Combine page-aligned GPA with page offset from GVA
    const page_offset = gva & PAGE_MASK;
    return (translation.physical_address & ~PAGE_MASK) | page_offset;
}

fn translate_gva_aarch64(vcpu: *Vcpu, memory: *const Memory.Guest, gva: u64) ?u64 {
    // Determine which TTBR to use based on address range
    // Bit 55 set = kernel space (TTBR1), clear = user space (TTBR0)
    const is_kernel = (gva & (@as(u64, 1) << 55)) != 0;

    const ttbr_reg_id = if (is_kernel) Vcpu.aarch64.TTBR1_EL1 else Vcpu.aarch64.TTBR0_EL1;
    var table_addr = Vcpu.aarch64.get_reg(vcpu, nix.System, ttbr_reg_id);
    table_addr &= Vcpu.aarch64.PTE_ADDR_MASK; // Mask off ASID bits

    // TODO comptime switch on host page size
    const indices = [4]u9{
        @truncate((gva >> 39) & 0x1FF),
        @truncate((gva >> 30) & 0x1FF),
        @truncate((gva >> 21) & 0x1FF),
        @truncate((gva >> 12) & 0x1FF),
    };

    for (0..4) |level| {
        const pte_addr = table_addr + @as(u64, indices[level]) * 8;
        if (pte_addr < Memory.DRAM_START or memory.last_addr() <= pte_addr) return null;
        const pte = memory.get_ptr(u64, pte_addr).*;

        if ((pte & PTE_VALID) == 0) return null;

        if (level < 3 and (pte & PTE_TABLE) == 0) {
            // Block entry (large page) is the last one
            const block_shift: u6 = @intCast(PAGE_SHIFT + (3 - level) * 9);
            const block_mask = (@as(u64, 1) << block_shift) - 1;
            return (pte & Vcpu.aarch64.PTE_ADDR_MASK & ~block_mask) | (gva & block_mask);
        } else {
            // Table entry -> continue to next level
            table_addr = pte & Vcpu.aarch64.PTE_ADDR_MASK;
        }
    }

    // L3 entry - this is the final page
    const page_offset = gva & PAGE_MASK;
    return table_addr | page_offset;
}

const ThreadId = struct {
    pid: ?Id,
    tid: Id,

    const IdEnum = enum { all, any, id };
    const Id = union(IdEnum) {
        all,
        any,
        id: u32,

        fn from_bytes(bytes: []const u8) ?Id {
            return switch (bytes[0]) {
                '-' => .all,
                '0' => .any,
                else => .{ .id = std.fmt.parseInt(u32, bytes, 16) catch return null },
            };
        }
    };

    const Self = @This();

    fn from_bytes(bytes: []const u8) ?Self {
        switch (bytes[0]) {
            // p(pid).[tid]
            'p' => {
                var iter = std.mem.splitScalar(u8, bytes[1..], '.');
                var pid: ?Id = null;
                if (iter.next()) |pid_slice| {
                    if (Id.from_bytes(pid_slice)) |id| {
                        pid = id;
                    } else return null;
                }
                var tid: Id = .all;
                if (iter.next()) |tid_slice| {
                    if (Id.from_bytes(tid_slice)) |id| {
                        tid = id;
                    } else return null;
                }
                return .{ .pid = pid, .tid = tid };
            },
            // (tid) - just a bare thread ID without 'p' prefix
            else => {
                if (Id.from_bytes(bytes)) |tid| {
                    return .{
                        .pid = null,
                        .tid = tid,
                    };
                } else return null;
            },
        }
    }
};

const Interrupt = struct {
    const Self = @This();

    fn response(self: *const Self, buffer: []u8, gdb: *GdbServer) ![]const u8 {
        _ = self;
        gdb.pause_vcpus();
        // Return SIGTRAP to indicate debugger stop
        return fmt_response(buffer, "S05");
    }
};

const qSupported = struct {
    bytes: []const u8,

    const Self = @This();

    fn from_bytes(bytes: []const u8) ?Self {
        return if (std.mem.startsWith(u8, bytes, "qSupported")) .{ .bytes = bytes } else null;
    }

    fn response(self: *const Self, buffer: []u8) ![]const u8 {
        _ = self;
        // PacketSize=800 (2048 bytes) to accommodate large register packets
        const msg = "PacketSize=800;vContSupported+;multiprocess+";
        return fmt_response(buffer, msg);
    }
};

const qfThreadInfo = struct {
    bytes: []const u8,

    const Self = @This();

    fn from_bytes(bytes: []const u8) ?Self {
        return if (std.mem.startsWith(u8, bytes, "qfThreadInfo")) .{ .bytes = bytes } else null;
    }

    fn response(self: *const Self, buffer: []u8, gdb: *GdbServer) ![]const u8 {
        _ = self;
        // Response format: m<thread-id>[,<thread-id>...]
        // Thread IDs start from 1 (0 means "any thread" in GDB)
        var buff: [32]u8 = undefined;
        var slice: []u8 = &buff;
        // Start with 'm' prefix
        slice[0] = 'm';
        slice = slice[1..];
        for (0..gdb.vcpu_threads.len) |i| {
            const str = try std.fmt.bufPrint(slice, "{X},", .{i + 1});
            slice = slice[str.len..];
        }
        // Remove trailing comma
        const end_pos = buff.len - slice.len - 1;
        return fmt_response(buffer, buff[0..end_pos]);
    }
};

const qsThreadInfo = struct {
    bytes: []const u8,

    const Self = @This();

    fn from_bytes(bytes: []const u8) ?Self {
        return if (std.mem.startsWith(u8, bytes, "qsThreadInfo")) .{ .bytes = bytes } else null;
    }

    fn response(self: *const Self, buffer: []u8) ![]const u8 {
        _ = self;
        const msg = "l";
        return fmt_response(buffer, msg);
    }
};

const qAttached = struct {
    bytes: []const u8,

    const Self = @This();

    fn from_bytes(bytes: []const u8) ?Self {
        return if (std.mem.startsWith(u8, bytes, "qAttached")) .{ .bytes = bytes } else null;
    }

    fn response(self: *const Self, buffer: []u8) ![]const u8 {
        _ = self;
        // The remote server attached to an existing process.
        const msg = "1";
        return fmt_response(buffer, msg);
    }
};

// 'qC' - Return the current thread ID
const qC = struct {
    const Self = @This();

    fn from_bytes(bytes: []const u8) ?Self {
        return if (std.mem.eql(u8, bytes, "qC")) .{} else null;
    }

    fn response(self: *const Self, buffer: []u8, gdb: *GdbServer) ![]const u8 {
        _ = self;
        // Return current thread ID (1-indexed)
        // Format: QC<thread-id>
        var msg_buf: [16]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf, "QC{x}", .{gdb.selected_vcpu + 1});
        return fmt_response(buffer, msg);
    }
};

const vCont = struct {
    t: Type,

    const Self = @This();

    const Type = enum {
        @"continue",
        step,
        @"?",
    };

    fn from_bytes(bytes: []const u8) ?Self {
        if (std.mem.startsWith(u8, bytes, "vCont")) {
            const t = switch (bytes[5]) {
                '?' => Type.@"?",
                ';' => switch (bytes[6]) {
                    'c' => Type.@"continue",
                    's' => Type.step,
                    else => return null,
                },
                else => return null,
            };
            return .{ .t = t };
        } else return null;
    }

    fn response(self: *const Self, buffer: []u8, gdb: *GdbServer) ![]const u8 {
        switch (self.t) {
            .@"continue" => {
                gdb.disable_selected_vcpu_debug();
                gdb.resume_vcpus();
                // GDB expects no immediate response for continue - only a stop reply
                // when the target actually stops (breakpoint, signal, etc.)
                return "+";
            },
            .step => {
                gdb.enable_selected_vcpu_debug();
                gdb.resume_vcpus();
                // There is no sync between main thread and vcpus so just do
                // a hacky wait
                for (0..100_000) |_| std.atomic.spinLoopHint();
                gdb.vcpus_barier.reset();
                gdb.disable_selected_vcpu_debug();
                return fmt_response(buffer, "S05");
            },
            // Currently supported:
            // c - continue
            // s - step
            .@"?" => return fmt_response(buffer, "vCont;c;s"),
        }
    }
};

const H = struct {
    bytes: []const u8,
    op: Op,
    thread_id: ThreadId,

    const Self = @This();

    const Op = enum {
        step_continue,
        other,
    };

    fn from_bytes(bytes: []const u8) ?Self {
        if (std.mem.startsWith(u8, bytes, "H")) {
            const op_byte = bytes[1];
            const thread_id_slice = bytes[2..];

            const op = switch (op_byte) {
                'g' => Op.other,
                'c' => Op.step_continue,
                else => return null,
            };

            const thread_id = ThreadId.from_bytes(thread_id_slice) orelse return null;
            return .{
                .bytes = bytes,
                .op = op,
                .thread_id = thread_id,
            };
        } else return null;
    }

    fn response(self: *const Self, buffer: []u8, gdb: *GdbServer) ![]const u8 {
        switch (self.thread_id.tid) {
            .id => |id| if (1 <= id and id <= gdb.vcpus.len) {
                gdb.selected_vcpu = id - 1;
            },
            .all, .any => gdb.selected_vcpu = 0,
        }
        return fmt_response(buffer, "OK");
    }
};

const g = struct {
    bytes: []const u8,

    const Self = @This();

    // Each byte is 2 hex chars, so u64 takes 16 hex chars, u32 - 8 hex chars
    const REG_BUF_SIZE = if (builtin.cpu.arch == .aarch64)
        // 33 x 64-bit regs (x0-x30, sp, pc) + 1 x 32-bit cpsr
        // + 32 x 128-bit V regs (V0-V31) + 2 x 32-bit (FPSR, FPCR)
        33 * 16 + 8 + 32 * 32 + 2 * 8
    else if (builtin.cpu.arch == .x86_64)
        // 17 x 64-bit GP regs (rax-r15, rip) = 272 hex chars
        // 1 x 32-bit eflags = 8 hex chars
        // 6 x 32-bit segment selectors (cs,ss,ds,es,fs,gs) = 48 hex chars
        // 8 x 80-bit st regs (st0-st7) = 160 hex chars
        // 8 x 32-bit fpu control regs = 64 hex chars
        // 16 x 128-bit xmm regs (xmm0-xmm15) = 512 hex chars
        // 1 x 32-bit mxcsr = 8 hex chars
        17 * 16 + 8 + 6 * 8 + 8 * 20 + 8 * 8 + 16 * 32 + 8
    else
        @compileError("Only aarch64 and x64 are supported");

    fn from_bytes(bytes: []const u8) ?Self {
        return if (std.mem.startsWith(u8, bytes, "g")) .{ .bytes = bytes } else null;
    }

    fn response(self: *const Self, buffer: []u8, gdb: *GdbServer) ![]const u8 {
        _ = self;
        var reg_buffer: [REG_BUF_SIZE]u8 = undefined;
        var pos: u32 = 0;

        const vcpu = &gdb.vcpus[gdb.selected_vcpu];

        if (builtin.cpu.arch == .aarch64) {
            for (Vcpu.aarch64.REGS) |reg_id| {
                const value = Vcpu.aarch64.get_reg(vcpu, nix.System, reg_id);
                pos += fmt_hex(u64, reg_buffer[pos..], value);
            }
            const sp = Vcpu.aarch64.get_reg(vcpu, nix.System, Vcpu.aarch64.SP);
            pos += fmt_hex(u64, reg_buffer[pos..], sp);
            const pc = Vcpu.aarch64.get_reg(vcpu, nix.System, Vcpu.aarch64.PC);
            pos += fmt_hex(u64, reg_buffer[pos..], pc);
            const pstate = Vcpu.aarch64.get_reg(vcpu, nix.System, Vcpu.aarch64.PSTATE);
            pos += fmt_hex(u32, reg_buffer[pos..], @truncate(pstate));

            // V0-V31: 128-bit SIMD/FP registers
            for (Vcpu.aarch64.VREGS) |vreg_id| {
                if (Vcpu.aarch64.try_get_reg(vcpu, u128, nix.System, vreg_id)) |v| {
                    pos += fmt_hex(u128, reg_buffer[pos..], v);
                } else {
                    @memset(reg_buffer[pos..][0..16], 0);
                    pos += 16;
                }
            }

            if (Vcpu.aarch64.try_get_reg(vcpu, u32, nix.System, Vcpu.aarch64.FPSR)) |v| {
                pos += fmt_hex(u32, reg_buffer[pos..], @truncate(v));
            } else {
                @memset(reg_buffer[pos..][0..8], 0);
                pos += 8;
            }
            if (Vcpu.aarch64.try_get_reg(vcpu, u32, nix.System, Vcpu.aarch64.FPCR)) |v| {
                pos += fmt_hex(u32, reg_buffer[pos..], @truncate(v));
            } else {
                @memset(reg_buffer[pos..][0..8], 0);
                pos += 8;
            }
        } else if (builtin.cpu.arch == .x86_64) {
            var kvm_regs: nix.kvm_regs = undefined;
            _ = nix.assert(@src(), nix.System, "ioctl", .{
                vcpu.fd,
                nix.KVM_GET_REGS,
                @intFromPtr(&kvm_regs),
            });

            // GDB x86_64 register order: 17 x 64-bit GP registers
            const regs = [_]u64{
                kvm_regs.rax, kvm_regs.rbx, kvm_regs.rcx, kvm_regs.rdx,
                kvm_regs.rsi, kvm_regs.rdi, kvm_regs.rbp, kvm_regs.rsp,
                kvm_regs.r8,  kvm_regs.r9,  kvm_regs.r10, kvm_regs.r11,
                kvm_regs.r12, kvm_regs.r13, kvm_regs.r14, kvm_regs.r15,
                kvm_regs.rip,
            };
            for (regs) |reg| pos += fmt_hex(u64, reg_buffer[pos..], reg);

            // eflags as 32-bit
            pos += fmt_hex(u32, reg_buffer[pos..], @truncate(kvm_regs.rflags));

            // Segment registers (32-bit selectors): cs, ss, ds, es, fs, gs
            var kvm_sregs: nix.kvm_sregs = undefined;
            _ = nix.assert(@src(), nix.System, "ioctl", .{
                vcpu.fd,
                nix.KVM_GET_SREGS,
                @intFromPtr(&kvm_sregs),
            });
            const seg_selectors = [_]u32{
                kvm_sregs.cs.selector, kvm_sregs.ss.selector,
                kvm_sregs.ds.selector, kvm_sregs.es.selector,
                kvm_sregs.fs.selector, kvm_sregs.gs.selector,
            };
            for (seg_selectors) |sel| pos += fmt_hex(u32, reg_buffer[pos..], sel);

            // FPU/SSE state
            var kvm_fpu: nix.kvm_fpu = undefined;
            _ = nix.assert(@src(), nix.System, "ioctl", .{
                vcpu.fd,
                nix.KVM_GET_FPU,
                @intFromPtr(&kvm_fpu),
            });

            // st0-st7: 80-bit (10 bytes each), from kvm_fpu.fpr (stored as 16-byte)
            for (kvm_fpu.fpr) |fpr| {
                fmt_hex_bytes(reg_buffer[pos..], fpr[0..10]);
                pos += 20;
            }

            // FPU control registers (32-bit each):
            // fctrl, fstat, ftag, fiseg, fioff, foseg, fooff, fop
            const fpu_ctrl = [_]u32{
                @as(u32, kvm_fpu.fcw),
                @as(u32, kvm_fpu.fsw),
                @as(u32, kvm_fpu.ftwx),
                0, // fiseg (not used in 64-bit mode)
                @truncate(kvm_fpu.last_ip),
                0, // foseg (not used in 64-bit mode)
                @truncate(kvm_fpu.last_dp),
                @as(u32, kvm_fpu.last_opcode),
            };
            for (fpu_ctrl) |val| pos += fmt_hex(u32, reg_buffer[pos..], val);

            // xmm0-xmm15: 128-bit (16 bytes each)
            for (kvm_fpu.xmm) |xmm| {
                fmt_hex_bytes(reg_buffer[pos..], &xmm);
                pos += 32;
            }

            // mxcsr: 32-bit
            pos += fmt_hex(u32, reg_buffer[pos..], kvm_fpu.mxcsr);
        }

        return fmt_response(buffer, reg_buffer[0..pos]);
    }
};

// 'p n'
// Read the value of the register n
const p = struct {
    register: u64,

    const Self = @This();

    fn from_bytes(bytes: []const u8) ?Self {
        if (std.mem.startsWith(u8, bytes, "p")) {
            const register = std.fmt.parseInt(u64, bytes[1..], 16) catch return null;
            return .{ .register = register };
        } else return null;
    }

    fn response(self: *const Self, buffer: []u8, gdb: *GdbServer) ![]const u8 {
        // 32 bytes = max 16-byte register (u128) as 32 hex chars
        var reg_buffer: [32]u8 = undefined;
        const vcpu = &gdb.vcpus[gdb.selected_vcpu];

        if (builtin.cpu.arch == .aarch64) {
            switch (self.register) {
                0...30 => {
                    const reg_id = Vcpu.aarch64.REGS[self.register];
                    if (Vcpu.aarch64.try_get_reg(vcpu, u64, nix.System, reg_id)) |v| {
                        _ = fmt_hex(u64, &reg_buffer, v);
                        return fmt_response(buffer, reg_buffer[0..16]);
                    } else return fmt_response(buffer, "E01");
                },
                31 => {
                    if (Vcpu.aarch64.try_get_reg(vcpu, u64, nix.System, Vcpu.aarch64.SP)) |v| {
                        _ = fmt_hex(u64, &reg_buffer, v);
                        return fmt_response(buffer, reg_buffer[0..16]);
                    } else return fmt_response(buffer, "E01");
                },
                32 => {
                    if (Vcpu.aarch64.try_get_reg(vcpu, u64, nix.System, Vcpu.aarch64.PC)) |v| {
                        _ = fmt_hex(u64, &reg_buffer, v);
                        return fmt_response(buffer, reg_buffer[0..16]);
                    } else return fmt_response(buffer, "E01");
                },
                33 => {
                    if (Vcpu.aarch64.try_get_reg(vcpu, u64, nix.System, Vcpu.aarch64.PSTATE)) |v| {
                        _ = fmt_hex(u64, &reg_buffer, v);
                        return fmt_response(buffer, reg_buffer[0..16]);
                    } else return fmt_response(buffer, "E01");
                },
                34...65 => {
                    const vreg_idx = self.register - 34;
                    if (Vcpu.aarch64.try_get_reg(vcpu, u128, nix.System, Vcpu.aarch64.VREGS[vreg_idx])) |v| {
                        _ = fmt_hex(u128, &reg_buffer, v);
                        return fmt_response(buffer, &reg_buffer);
                    } else return fmt_response(buffer, "E01");
                },
                66 => {
                    if (Vcpu.aarch64.try_get_reg(vcpu, u32, nix.System, Vcpu.aarch64.FPSR)) |v| {
                        _ = fmt_hex(u32, &reg_buffer, v);
                        return fmt_response(buffer, reg_buffer[0..8]);
                    } else return fmt_response(buffer, "E01");
                },
                67 => {
                    if (Vcpu.aarch64.try_get_reg(vcpu, u32, nix.System, Vcpu.aarch64.FPCR)) |v| {
                        _ = fmt_hex(u32, &reg_buffer, v);
                        return fmt_response(buffer, reg_buffer[0..8]);
                    } else return fmt_response(buffer, "E01");
                },
                else => return fmt_response(buffer, "E01"),
            }
        } else if (builtin.cpu.arch == .x86_64) {
            // st0-st7 (regs 24-31): 10 bytes, xmm0-xmm15 (regs 40-55): 16 bytes
            if ((24 <= self.register and self.register <= 31) or
                (40 <= self.register and self.register <= 55))
            {
                var kvm_fpu: nix.kvm_fpu = undefined;
                _ = nix.assert(@src(), nix.System, "ioctl", .{
                    vcpu.fd,
                    nix.KVM_GET_FPU,
                    @intFromPtr(&kvm_fpu),
                });
                if (24 <= self.register and self.register <= 31) {
                    // st regs: 10 bytes = 20 hex chars
                    const idx = self.register - 24;
                    fmt_hex_bytes(&reg_buffer, kvm_fpu.fpr[idx][0..10]);
                    return fmt_response(buffer, reg_buffer[0..20]);
                } else {
                    // xmm regs: 16 bytes = 32 hex chars
                    const idx = self.register - 40;
                    fmt_hex_bytes(&reg_buffer, &kvm_fpu.xmm[idx]);
                    return fmt_response(buffer, &reg_buffer);
                }
            } else if (self.register == 17 or
                (18 <= self.register and self.register <= 23) or
                (32 <= self.register and self.register <= 39) or
                self.register == 56)
            {
                if (get_x64_reg(vcpu, self.register)) |v| {
                    _ = fmt_hex(u32, reg_buffer[0..8], @truncate(v));
                    return fmt_response(buffer, reg_buffer[0..8]);
                } else return fmt_response(buffer, "E01");
            } else {
                if (get_x64_reg(vcpu, self.register)) |v| {
                    _ = fmt_hex(u64, reg_buffer[0..16], v);
                    return fmt_response(buffer, reg_buffer[0..16]);
                } else return fmt_response(buffer, "E01");
            }
        } else @compileError("Only aarch64 and x64 are supported");
    }
};

// 'm addr,length'
// Read length addressable memory units starting at address addr
const m = struct {
    addr: u64,
    length: u64,

    const Self = @This();

    fn from_bytes(bytes: []const u8) ?Self {
        if (std.mem.startsWith(u8, bytes, "m")) {
            var iter = std.mem.splitScalar(u8, bytes[1..], ',');
            const addr = std.fmt.parseInt(u64, iter.next().?, 16) catch return null;
            const length = std.fmt.parseInt(u64, iter.next().?, 16) catch return null;
            return .{ .addr = addr, .length = length };
        } else return null;
    }

    fn response(self: *const Self, buffer: []u8, gdb: *GdbServer) ![]const u8 {
        const vcpu = &gdb.vcpus[gdb.selected_vcpu];
        const read_len = @min(self.length, MAX_READ_LEN);

        // If translation failed try direct physical address access
        // (GDB might be sending physical addresses for kernel debugging)
        const gpa = translate_gva(vcpu, &gdb.memory, self.addr) orelse self.addr;

        if (Memory.DRAM_START <= gpa and gpa + read_len <= gdb.memory.last_addr()) {
            return read_memory_at_gpa(buffer, &gdb.memory, gpa, read_len);
        } else {
            return fmt_response(buffer, "E14"); // EFAULT
        }
    }
};

// 'P n=r...'
// Write register n with value r (hex-encoded, LE byte order)
const P = struct {
    register: u64,
    value_hex: []const u8,

    const Self = @This();

    fn from_bytes(bytes: []const u8) ?Self {
        if (std.mem.startsWith(u8, bytes, "P")) {
            const eq_pos = std.mem.indexOfScalar(u8, bytes[1..], '=') orelse return null;
            const reg_num = std.fmt.parseInt(u64, bytes[1 .. 1 + eq_pos], 16) catch return null;
            return .{ .register = reg_num, .value_hex = bytes[2 + eq_pos ..] };
        } else return null;
    }

    fn response(self: *const Self, buffer: []u8, gdb: *GdbServer) ![]const u8 {
        const vcpu = &gdb.vcpus[gdb.selected_vcpu];

        if (builtin.cpu.arch == .aarch64) {
            if (self.register <= 32) {
                const value = parse_hex(u64, self.value_hex) orelse return fmt_response(buffer, "E01");
                const reg_id = if (self.register <= 30)
                    Vcpu.aarch64.REGS[self.register]
                else if (self.register == 31)
                    Vcpu.aarch64.SP
                else
                    Vcpu.aarch64.PC;
                Vcpu.aarch64.set_reg(vcpu, nix.System, u64, reg_id, value);
                return fmt_response(buffer, "OK");
            } else {
                return fmt_response(buffer, "E01");
            }
        } else if (builtin.cpu.arch == .x86_64) {
            // GP registers (0-16) and rflags (17) are writable
            if (self.register <= 17) {
                var kvm_regs: nix.kvm_regs = undefined;
                _ = nix.assert(@src(), nix.System, "ioctl", .{
                    vcpu.fd,
                    nix.KVM_GET_REGS,
                    @intFromPtr(&kvm_regs),
                });
                const value = parse_hex(u64, self.value_hex) orelse return fmt_response(buffer, "E01");
                switch (self.register) {
                    0 => kvm_regs.rax = value,
                    1 => kvm_regs.rbx = value,
                    2 => kvm_regs.rcx = value,
                    3 => kvm_regs.rdx = value,
                    4 => kvm_regs.rsi = value,
                    5 => kvm_regs.rdi = value,
                    6 => kvm_regs.rbp = value,
                    7 => kvm_regs.rsp = value,
                    8 => kvm_regs.r8 = value,
                    9 => kvm_regs.r9 = value,
                    10 => kvm_regs.r10 = value,
                    11 => kvm_regs.r11 = value,
                    12 => kvm_regs.r12 = value,
                    13 => kvm_regs.r13 = value,
                    14 => kvm_regs.r14 = value,
                    15 => kvm_regs.r15 = value,
                    16 => kvm_regs.rip = value,
                    17 => kvm_regs.rflags = value,
                    else => unreachable,
                }
                _ = nix.assert(@src(), nix.System, "ioctl", .{
                    vcpu.fd,
                    nix.KVM_SET_REGS,
                    @intFromPtr(&kvm_regs),
                });
                return fmt_response(buffer, "OK");
            } else {
                // Segment registers not writable via this interface
                return fmt_response(buffer, "E01");
            }
        } else {
            return fmt_response(buffer, "E01");
        }
    }
};

// 'M addr,length:XX...'
// Write length addressable memory units starting at address addr
const M = struct {
    addr: u64,
    length: u64,
    data_hex: []const u8,

    const Self = @This();

    fn from_bytes(bytes: []const u8) ?Self {
        if (std.mem.startsWith(u8, bytes, "M")) {
            const comma = std.mem.indexOfScalar(u8, bytes[1..], ',') orelse return null;
            const colon = std.mem.indexOfScalar(u8, bytes[1..], ':') orelse return null;
            const addr = std.fmt.parseInt(u64, bytes[1 .. 1 + comma], 16) catch return null;
            const length = std.fmt.parseInt(u64, bytes[2 + comma .. 1 + colon], 16) catch return null;
            return .{
                .addr = addr,
                .length = length,
                .data_hex = bytes[2 + colon ..],
            };
        } else return null;
    }

    fn response(self: *const Self, buffer: []u8, gdb: *GdbServer) ![]const u8 {
        const vcpu = &gdb.vcpus[gdb.selected_vcpu];
        const write_len = @min(self.length, MAX_WRITE_LEN);

        // If translation failed try direct physical address access
        // (GDB might be sending physical addresses for kernel debugging)
        const gpa = translate_gva(vcpu, &gdb.memory, self.addr) orelse self.addr;

        if (Memory.DRAM_START <= gpa and gpa + self.length <= gdb.memory.last_addr()) {
            return write_memory_at_gpa(buffer, &gdb.memory, gpa, self.data_hex, write_len);
        } else {
            return fmt_response(buffer, "E14"); // EFAULT
        }
    }
};

// 'G XX...'
// Write general registers from hex data
const G = struct {
    data_hex: []const u8,

    const Self = @This();

    fn from_bytes(bytes: []const u8) ?Self {
        return if (std.mem.startsWith(u8, bytes, "G")) .{ .data_hex = bytes[1..] } else null;
    }

    fn response(self: *const Self, buffer: []u8, gdb: *GdbServer) ![]const u8 {
        const vcpu = &gdb.vcpus[gdb.selected_vcpu];

        if (builtin.cpu.arch == .aarch64) {
            var hex_bytes = self.data_hex;
            for (Vcpu.aarch64.REGS) |reg_id| {
                if (hex_bytes.len < 16) return fmt_response(buffer, "E01");
                const value = parse_hex(u64, hex_bytes[0..16]) orelse return fmt_response(buffer, "E01");
                Vcpu.aarch64.set_reg(vcpu, nix.System, u64, reg_id, value);
                hex_bytes = hex_bytes[16..];
            }
            if (hex_bytes.len < 16) return fmt_response(buffer, "E01");
            const sp = parse_hex(u64, hex_bytes[0..16]) orelse return fmt_response(buffer, "E01");
            Vcpu.aarch64.set_reg(vcpu, nix.System, u64, Vcpu.aarch64.SP, sp);
            hex_bytes = hex_bytes[16..];
            if (hex_bytes.len < 16) return fmt_response(buffer, "E01");
            const pc = parse_hex(u64, hex_bytes[0..16]) orelse return fmt_response(buffer, "E01");
            Vcpu.aarch64.set_reg(vcpu, nix.System, u64, Vcpu.aarch64.PC, pc);

            // skip remaining regs

            return fmt_response(buffer, "OK");
        } else if (builtin.cpu.arch == .x86_64) {
            var kvm_regs: nix.kvm_regs = undefined;
            _ = nix.assert(@src(), nix.System, "ioctl", .{
                vcpu.fd,
                nix.KVM_GET_REGS,
                @intFromPtr(&kvm_regs),
            });

            var hex_bytes = self.data_hex;
            const gp_fields = [_]*u64{
                &kvm_regs.rax, &kvm_regs.rbx, &kvm_regs.rcx, &kvm_regs.rdx,
                &kvm_regs.rsi, &kvm_regs.rdi, &kvm_regs.rbp, &kvm_regs.rsp,
                &kvm_regs.r8,  &kvm_regs.r9,  &kvm_regs.r10, &kvm_regs.r11,
                &kvm_regs.r12, &kvm_regs.r13, &kvm_regs.r14, &kvm_regs.r15,
                &kvm_regs.rip,
            };
            for (gp_fields) |field| {
                if (hex_bytes.len < 16) return fmt_response(buffer, "E01");
                field.* = parse_hex(u64, hex_bytes[0..16]) orelse return fmt_response(buffer, "E01");
                hex_bytes = hex_bytes[16..];
            }

            if (hex_bytes.len < 8) return fmt_response(buffer, "E01");
            const eflags = parse_hex(u32, hex_bytes[0..8]) orelse return fmt_response(buffer, "E01");
            kvm_regs.rflags = eflags;

            // Skip remaining regs - not writable via KVM_SET_REGS

            _ = nix.assert(@src(), nix.System, "ioctl", .{
                vcpu.fd,
                nix.KVM_SET_REGS,
                @intFromPtr(&kvm_regs),
            });
            return fmt_response(buffer, "OK");
        } else @compileError("Only aarch64 and x64 are supported");
    }
};

// 'T thread-id'
// Check if thread is alive
const T = struct {
    thread_id: u32,

    const Self = @This();

    fn from_bytes(bytes: []const u8) ?Self {
        if (std.mem.startsWith(u8, bytes, "T")) {
            const tid = std.fmt.parseInt(u32, bytes[1..], 16) catch return null;
            return .{ .thread_id = tid };
        } else return null;
    }

    fn response(self: *const Self, buffer: []u8, gdb: *GdbServer) ![]const u8 {
        if (1 <= self.thread_id and self.thread_id <= gdb.vcpu_threads.len) {
            return fmt_response(buffer, "OK");
        } else {
            return fmt_response(buffer, "E01");
        }
    }
};

// 'Z0,addr,kind' - Insert software breakpoint
const Z0 = struct {
    addr: u64,

    const Self = @This();

    fn from_bytes(bytes: []const u8) ?Self {
        if (std.mem.startsWith(u8, bytes, "Z0,")) {
            const second_comma = std.mem.indexOfScalarPos(u8, bytes, 3, ',') orelse return null;
            const addr = std.fmt.parseInt(u64, bytes[3..second_comma], 16) catch return null;
            return .{ .addr = addr };
        } else return null;
    }

    fn response(self: *const Self, buffer: []u8, gdb: *GdbServer) ![]const u8 {
        if (gdb.add_sw_breakpoint(self.addr)) {
            return fmt_response(buffer, "OK");
        }
        return fmt_response(buffer, "E01");
    }
};

// 'z0,addr,kind' - Remove software breakpoint
const z0 = struct {
    addr: u64,

    const Self = @This();

    fn from_bytes(bytes: []const u8) ?Self {
        if (std.mem.startsWith(u8, bytes, "z0,")) {
            const second_comma = std.mem.indexOfScalarPos(u8, bytes, 3, ',') orelse return null;
            const addr = std.fmt.parseInt(u64, bytes[3..second_comma], 16) catch return null;
            return .{ .addr = addr };
        } else return null;
    }

    fn response(self: *const Self, buffer: []u8, gdb: *GdbServer) ![]const u8 {
        if (gdb.remove_sw_breakpoint(self.addr)) {
            return fmt_response(buffer, "OK");
        } else {
            return fmt_response(buffer, "E01");
        }
    }
};

// 'c [addr]'
// Continue at addr, which is the address to resume. If addr is omitted, resume at current address.
const c = struct {
    const Self = @This();

    fn from_bytes(bytes: []const u8) ?Self {
        return if (std.mem.startsWith(u8, bytes, "c")) .{} else null;
    }

    fn response(self: *const Self, buffer: []u8, gdb: *GdbServer) ![]const u8 {
        _ = self;
        _ = buffer;
        gdb.disable_selected_vcpu_debug();
        gdb.resume_vcpus();
        // GDB expects no immediate response for 'c' - only a stop reply
        // when the target actually stops (breakpoint, signal, etc.)
        return "+";
    }
};

// 's [addr]'
// Single step. addr is the address to resume. If addr is omitted, resume at current address.
const s = struct {
    const Self = @This();

    fn from_bytes(bytes: []const u8) ?Self {
        return if (std.mem.eql(u8, bytes, "s") or std.mem.startsWith(u8, bytes, "s ")) .{} else null;
    }

    fn response(self: *const Self, buffer: []u8, gdb: *GdbServer) ![]const u8 {
        _ = self;
        gdb.enable_selected_vcpu_debug();
        gdb.resume_vcpus();
        // There is no sync between main thread and vcpus so just do
        // a hacky wait
        for (0..100_000) |_| std.atomic.spinLoopHint();
        gdb.vcpus_barier.reset();
        gdb.disable_selected_vcpu_debug();
        return fmt_response(buffer, "S05");
    }
};

const QuestionMark = struct {
    const Self = @This();

    fn from_bytes(bytes: []const u8) ?Self {
        return if (std.mem.startsWith(u8, bytes, "?")) .{} else null;
    }

    fn response(self: *const Self, buffer: []u8, gdb: *GdbServer) ![]const u8 {
        _ = self;
        // T05thread:<tid>; - stopped with SIGTRAP, include thread ID
        var msg_buf: [32]u8 = undefined;
        const msg = try std.fmt.bufPrint(&msg_buf, "T05thread:{x};", .{gdb.selected_vcpu + 1});
        return fmt_response(buffer, msg);
    }
};

// 'D' or 'D;pid' - Detach from target
const D = struct {
    const Self = @This();

    fn from_bytes(bytes: []const u8) ?Self {
        return if (std.mem.startsWith(u8, bytes, "D")) .{} else null;
    }

    fn response(self: *const Self, buffer: []u8, gdb: *GdbServer) ![]const u8 {
        _ = self;
        gdb.remove_all_sw_breakpoint();
        gdb.disable_all_vcpus_debug();
        gdb.resume_vcpus();
        return fmt_response(buffer, "OK");
    }
};

const Unknown = struct {
    const Self = @This();
    fn response(self: *const Self) ![]const u8 {
        _ = self;
        return "+$#00";
    }
};

const PayloadEnum = enum {
    Acknowledgment,
    Retransmission,
    Interrupt,
    qSupported,
    qfThreadInfo,
    qsThreadInfo,
    qAttached,
    qC,
    vCont,
    H,
    G,
    g,
    p,
    m,
    c,
    s,
    T,
    P,
    M,
    Z0,
    z0,
    D,
    QuestionMark,
    Unknown,
};

const PayloadIterator = struct {
    i: usize = 0,
    buf: []const u8,

    const Self = @This();

    fn init(buf: []const u8) Self {
        return .{ .buf = buf };
    }

    fn next(self: *Self) !?Payload {
        return if (self.buf.len <= self.i) blk: {
            break :blk null;
        } else if (self.buf[self.i] == '+') blk: {
            const payload = try Payload.from(self.buf[self.i .. self.i + 1]);
            self.i += 1;
            break :blk payload;
        } else if (self.buf[self.i] == '-') blk: {
            const payload = try Payload.from(self.buf[self.i .. self.i + 1]);
            self.i += 1;
            break :blk payload;
        } else if (self.buf[self.i] == 0x03) blk: {
            const payload = try Payload.from(self.buf[self.i .. self.i + 1]);
            self.i += 1;
            break :blk payload;
        } else if (self.buf[self.i] == '$') blk: {
            const slice = std.mem.sliceTo(self.buf[self.i..], '#');
            const payload_slice = self.buf[self.i .. self.i + slice.len + 2];
            const payload = try Payload.from(payload_slice);
            self.i += slice.len + 2;
            break :blk payload;
        } else blk: {
            break :blk null;
        };
    }
};

const Payload = union(PayloadEnum) {
    Acknowledgment,
    Retransmission,
    Interrupt: Interrupt,
    qSupported: qSupported,
    qfThreadInfo: qfThreadInfo,
    qsThreadInfo: qsThreadInfo,
    qAttached: qAttached,
    qC: qC,
    vCont: vCont,
    H: H,
    G: G,
    g: g,
    p: p,
    m: m,
    c: c,
    s: s,
    T: T,
    P: P,
    M: M,
    Z0: Z0,
    z0: z0,
    D: D,
    QuestionMark: QuestionMark,
    Unknown: Unknown,

    const Self = @This();

    fn from(bytes: []const u8) !Self {
        return if (bytes.len == 1) blk: {
            break :blk switch (bytes[0]) {
                '+' => .Acknowledgment,
                '-' => .Retransmission,
                0x03 => .{ .Interrupt = .{} },
                else => error.Invalid,
            };
        } else blk: {
            const stripped = try Self.strip_bytes(bytes);
            log.debug(@src(), "got stripped: {s}", .{stripped});
            if (qSupported.from_bytes(stripped)) |payload| {
                break :blk .{ .qSupported = payload };
            } else if (qfThreadInfo.from_bytes(stripped)) |paylod| {
                break :blk .{ .qfThreadInfo = paylod };
            } else if (qsThreadInfo.from_bytes(stripped)) |payload| {
                break :blk .{ .qsThreadInfo = payload };
            } else if (qAttached.from_bytes(stripped)) |payload| {
                break :blk .{ .qAttached = payload };
            } else if (qC.from_bytes(stripped)) |payload| {
                break :blk .{ .qC = payload };
            } else if (vCont.from_bytes(stripped)) |payload| {
                break :blk .{ .vCont = payload };
            } else if (H.from_bytes(stripped)) |payload| {
                break :blk .{ .H = payload };
            } else if (Z0.from_bytes(stripped)) |payload| {
                break :blk .{ .Z0 = payload };
            } else if (z0.from_bytes(stripped)) |payload| {
                break :blk .{ .z0 = payload };
            } else if (G.from_bytes(stripped)) |payload| {
                break :blk .{ .G = payload };
            } else if (g.from_bytes(stripped)) |payload| {
                break :blk .{ .g = payload };
            } else if (T.from_bytes(stripped)) |payload| {
                break :blk .{ .T = payload };
            } else if (P.from_bytes(stripped)) |payload| {
                break :blk .{ .P = payload };
            } else if (p.from_bytes(stripped)) |payload| {
                break :blk .{ .p = payload };
            } else if (M.from_bytes(stripped)) |payload| {
                break :blk .{ .M = payload };
            } else if (m.from_bytes(stripped)) |payload| {
                break :blk .{ .m = payload };
            } else if (c.from_bytes(stripped)) |payload| {
                break :blk .{ .c = payload };
            } else if (s.from_bytes(stripped)) |payload| {
                break :blk .{ .s = payload };
            } else if (D.from_bytes(stripped)) |payload| {
                break :blk .{ .D = payload };
            } else if (QuestionMark.from_bytes(stripped)) |payload| {
                break :blk .{ .QuestionMark = payload };
            } else {
                log.warn(@src(), "Unknown payload: {s}", .{stripped});
                break :blk .{ .Unknown = .{} };
            }
        };
    }

    fn strip_bytes(bytes: []const u8) ![]const u8 {
        return if (bytes.len < 4) blk: {
            break :blk error.Invalid;
        } else blk: {
            break :blk bytes[1 .. bytes.len - 2];
        };
    }
};

pub const GdbServer = struct {
    address: std.net.Address,
    server: std.net.Server,
    connection: std.net.Server.Connection,

    read_buffer: [2048]u8 = undefined,
    write_buffer: [2048]u8 = undefined,
    last_response: []const u8 = undefined,

    vcpus: []Vcpu,
    vcpu_threads: []std.Thread,
    vcpus_barier: *std.Thread.ResetEvent,
    memory: Memory.Guest,
    mmio: *Mmio,
    event_loop: *EventLoop,

    // Currently selected VCPU for register/memory operations (set by H command)
    selected_vcpu: u32 = 0,

    // Software breakpoint storage
    sw_breakpoints: [MAX_SW_BREAKPOINTS]SwBreakpoint = [_]SwBreakpoint{.{}} ** MAX_SW_BREAKPOINTS,
    sw_breakpoint_count: u32 = 0,

    const MAX_SW_BREAKPOINTS = 64;
    const TRAP_INSN = if (builtin.cpu.arch == .aarch64)
        0xD4200000
    else if (builtin.cpu.arch == .x86_64)
        0xCC
    else
        @compileError("Only aarch64 and x64 are supported");
    const TRAP_SIZE = if (builtin.cpu.arch == .aarch64)
        4
    else if (builtin.cpu.arch == .x86_64)
        1
    else
        @compileError("Only aarch64 and x64 are supported");
    const TRAP_INST_TYPE = if (builtin.cpu.arch == .aarch64)
        u32
    else if (builtin.cpu.arch == .x86_64)
        u8
    else
        @compileError("Only aarch64 and x64 are supported");

    const SwBreakpoint = struct {
        gpa: u64 = 0,
        original: if (builtin.cpu.arch == .aarch64)
            u32
        else if (builtin.cpu.arch == .x86_64)
            u8
        else
            @compileError("Only aarch64 and x64 are supported") = 0,
        active: bool = false,
    };

    const Self = @This();

    // TODO move Server and Connectino to use System
    pub fn init(
        comptime System: type,
        socket_path: []const u8,
        vcpus: []Vcpu,
        vcpu_threads: []std.Thread,
        vcpus_barier: *std.Thread.ResetEvent,
        memory: Memory.Guest,
        mmio: *Mmio,
        event_loop: *EventLoop,
    ) !Self {
        log.debug(@src(), "Initializing gdb connection ...", .{});
        const address = try std.net.Address.initUnix(socket_path);
        var server = try address.listen(.{});
        errdefer server.deinit();

        var accepted_addr: std.net.Address = undefined;
        var addr_len: nix.socklen_t = @sizeOf(std.net.Address);
        const fd = try System.accept(
            server.stream.handle,
            &accepted_addr.any,
            &addr_len,
            nix.SOCK.CLOEXEC | nix.SOCK.NONBLOCK,
        );
        const connection = std.net.Server.Connection{
            .stream = .{ .handle = fd },
            .address = accepted_addr,
        };
        log.debug(@src(), "gdb connection established", .{});

        return .{
            .address = address,
            .server = server,
            .connection = connection,

            .vcpus = vcpus,
            .vcpu_threads = vcpu_threads,
            .vcpus_barier = vcpus_barier,
            .memory = memory,
            .mmio = mmio,
            .event_loop = event_loop,
        };
    }

    pub fn process_request(self: *Self) !void {
        while (true) {
            log.debug(@src(), "reading payload", .{});

            const len = self.connection.stream.read(&self.read_buffer) catch |err| {
                if (err == std.posix.ReadError.WouldBlock) {
                    return;
                }
                return err;
            };
            if (len == 0) {
                self.event_loop.exit = true;
                log.debug(@src(), "got payload of len 0. exiting", .{});
                return;
            }

            const payload_data = self.read_buffer[0..len];
            log.debug(@src(), "got payload: {s} len: {}", .{ payload_data, len });

            var iter = PayloadIterator.init(payload_data);
            blk: while (iter.next()) |payload| {
                if (payload) |paylod_type| {
                    log.debug(@src(), "payload type: {any}", .{paylod_type});
                    switch (paylod_type) {
                        .Acknowledgment => {},
                        .Retransmission => {
                            // log.debug(
                            //     @src(),
                            //     "sending Retransmission: {s}",
                            //     .{self.last_response},
                            // );
                            // _ = try self.connection.stream.write(self.last_response);
                        },
                        .Interrupt => |*inner_payload| {
                            self.last_response =
                                try inner_payload.response(&self.write_buffer, self);
                            log.debug(@src(), "sending Interrupt ack: {s}", .{self.last_response});
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .qSupported => |*inner_payload| {
                            self.last_response =
                                try inner_payload.response(&self.write_buffer);
                            log.debug(@src(), "sending qSupported ack: {s}", .{self.last_response});
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .qfThreadInfo => |*inner_payload| {
                            self.last_response =
                                try inner_payload.response(&self.write_buffer, self);
                            log.debug(
                                @src(),
                                "sending qfThreadInfo ack: {s}",
                                .{self.last_response},
                            );
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .qsThreadInfo => |*inner_payload| {
                            self.last_response = try inner_payload.response(&self.write_buffer);
                            log.debug(
                                @src(),
                                "sending qsThreadInfo ack: {s}",
                                .{self.last_response},
                            );
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .qAttached => |*inner_payload| {
                            self.last_response = try inner_payload.response(&self.write_buffer);
                            log.debug(@src(), "sending qAttached ack: {s}", .{self.last_response});
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .qC => |*inner_payload| {
                            self.last_response = try inner_payload.response(&self.write_buffer, self);
                            log.debug(@src(), "sending qC ack: {s}", .{self.last_response});
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .vCont => |*inner_payload| {
                            self.last_response =
                                try inner_payload.response(&self.write_buffer, self);
                            log.debug(@src(), "sending vCont ack: {s}", .{self.last_response});
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .H => |*inner_payload| {
                            self.last_response = try inner_payload.response(&self.write_buffer, self);
                            log.debug(@src(), "sending H ack: {s}", .{self.last_response});
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .G => |*inner_payload| {
                            self.last_response = try inner_payload.response(&self.write_buffer, self);
                            log.debug(@src(), "sending G ack: {s}", .{self.last_response});
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .g => |*inner_payload| {
                            self.last_response = try inner_payload.response(&self.write_buffer, self);
                            log.debug(@src(), "sending g ack: {s}", .{self.last_response});
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .T => |*inner_payload| {
                            self.last_response = try inner_payload.response(&self.write_buffer, self);
                            log.debug(@src(), "sending T ack: {s}", .{self.last_response});
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .P => |*inner_payload| {
                            self.last_response = try inner_payload.response(&self.write_buffer, self);
                            log.debug(@src(), "sending P ack: {s}", .{self.last_response});
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .p => |*inner_payload| {
                            self.last_response = try inner_payload.response(&self.write_buffer, self);
                            log.debug(@src(), "sending p ack: {s}", .{self.last_response});
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .M => |*inner_payload| {
                            self.last_response = try inner_payload.response(&self.write_buffer, self);
                            log.debug(@src(), "sending M ack: {s}", .{self.last_response});
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .m => |*inner_payload| {
                            self.last_response = try inner_payload.response(&self.write_buffer, self);
                            log.debug(@src(), "sending m ack: {s}", .{self.last_response});
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .Z0 => |*inner_payload| {
                            self.last_response = try inner_payload.response(&self.write_buffer, self);
                            log.debug(@src(), "sending Z0 ack: {s}", .{self.last_response});
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .z0 => |*inner_payload| {
                            self.last_response = try inner_payload.response(&self.write_buffer, self);
                            log.debug(@src(), "sending z0 ack: {s}", .{self.last_response});
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .c => |*inner_payload| {
                            self.last_response =
                                try inner_payload.response(&self.write_buffer, self);
                            log.debug(@src(), "sending c ack: {s}", .{self.last_response});
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .s => |*inner_payload| {
                            self.last_response =
                                try inner_payload.response(&self.write_buffer, self);
                            log.debug(@src(), "sending s ack: {s}", .{self.last_response});
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .D => |*inner_payload| {
                            self.last_response = try inner_payload.response(&self.write_buffer, self);
                            log.debug(@src(), "sending D ack: {s}", .{self.last_response});
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .QuestionMark => |*inner_payload| {
                            self.last_response = try inner_payload.response(&self.write_buffer, self);
                            log.debug(
                                @src(),
                                "sending QuestionMark ack: {s}",
                                .{self.last_response},
                            );
                            _ = try self.connection.stream.write(self.last_response);
                        },
                        .Unknown => |*inner_payload| {
                            self.last_response = try inner_payload.response();
                            log.debug(@src(), "sending Unknown ack: {s}", .{self.last_response});
                            _ = try self.connection.stream.write(self.last_response);
                        },
                    }
                } else {
                    log.debug(@src(), "end of the payload", .{});
                    break :blk;
                }
            } else |err| {
                log.err(@src(), "payload err: {any}", .{err});
                log.debug(@src(), "sending retransmit", .{});
                _ = try self.connection.stream.write("-");
            }
        }
    }

    fn add_sw_breakpoint(self: *Self, addr: u64) bool {
        if (MAX_SW_BREAKPOINTS <= self.sw_breakpoint_count) return false;

        const vcpu = &self.vcpus[self.selected_vcpu];
        const gpa = translate_gva(vcpu, &self.memory, addr) orelse addr;

        // Check if GPA is in valid guest memory range
        if (gpa < Memory.DRAM_START or self.memory.last_addr() <= gpa) return false;

        // Check if breakpoint already exists at this address
        for (self.sw_breakpoints[0..self.sw_breakpoint_count]) |*bp| {
            if (bp.gpa == gpa and bp.active) return true;
        }

        // Save original byte and write trap instruction
        const ptr = self.memory.get_ptr(TRAP_INST_TYPE, gpa);
        const original = ptr.*;
        ptr.* = TRAP_INSN;

        self.sw_breakpoints[self.sw_breakpoint_count] = .{
            .gpa = gpa,
            .original = original,
            .active = true,
        };
        self.sw_breakpoint_count += 1;

        // Enable software breakpoint debug on selected VCPU
        var debug: nix.kvm_guest_debug = .{
            .control = nix.KVM_GUESTDBG_ENABLE | nix.KVM_GUESTDBG_USE_SW_BP,
        };
        _ = nix.assert(@src(), nix.System, "ioctl", .{
            vcpu.fd,
            nix.KVM_SET_GUEST_DEBUG,
            @intFromPtr(&debug),
        });

        return true;
    }

    fn remove_sw_breakpoint(self: *Self, addr: u64) bool {
        const vcpu = &self.vcpus[self.selected_vcpu];
        const gpa = translate_gva(vcpu, &self.memory, addr) orelse addr;

        for (self.sw_breakpoints[0..self.sw_breakpoint_count]) |*bp| {
            if (bp.gpa == gpa and bp.active) {
                const ptr = self.memory.get_ptr(TRAP_INST_TYPE, gpa);
                ptr.* = bp.original;
                bp.active = false;
                return true;
            }
        }
        return false;
    }

    fn remove_all_sw_breakpoint(self: *Self) void {
        for (self.sw_breakpoints[0..self.sw_breakpoint_count]) |*bp| {
            if (bp.active) {
                const ptr = self.memory.get_ptr(TRAP_INST_TYPE, bp.gpa);
                ptr.* = bp.original;
                bp.active = false;
            }
        }
        self.sw_breakpoint_count = 0;
    }

    // Enable single-step via KVM_SET_GUEST_DEBUG on the selected VCPU
    fn enable_selected_vcpu_debug(self: *Self) void {
        const vcpu = &self.vcpus[self.selected_vcpu];
        var debug: nix.kvm_guest_debug = .{
            .control = nix.KVM_GUESTDBG_ENABLE | nix.KVM_GUESTDBG_SINGLESTEP,
        };
        _ = nix.assert(@src(), nix.System, "ioctl", .{
            vcpu.fd,
            nix.KVM_SET_GUEST_DEBUG,
            @intFromPtr(&debug),
        });
    }

    fn disable_selected_vcpu_debug(self: *Self) void {
        const vcpu = &self.vcpus[self.selected_vcpu];
        var debug: nix.kvm_guest_debug = .{ .control = 0 };
        _ = nix.assert(@src(), nix.System, "ioctl", .{
            vcpu.fd,
            nix.KVM_SET_GUEST_DEBUG,
            @intFromPtr(&debug),
        });
    }

    fn disable_all_vcpus_debug(self: *Self) void {
        for (self.vcpus) |*vcpu| {
            var debug: nix.kvm_guest_debug = .{ .control = 0 };
            _ = nix.assert(@src(), nix.System, "ioctl", .{
                vcpu.fd,
                nix.KVM_SET_GUEST_DEBUG,
                @intFromPtr(&debug),
            });
        }
    }

    fn pause_vcpus(self: *Self) void {
        self.vcpus_barier.reset();
        for (self.vcpus) |*vcpu| vcpu.pause(nix.System);
    }

    fn resume_vcpus(self: *Self) void {
        for (self.vcpus) |*vcpu| vcpu.kvm_run.immediate_exit = 0;
        self.vcpus_barier.set();
    }
};
