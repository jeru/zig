//! This file contains the functionality for lowering x86_64 MIR into
//! machine code

const Emit = @This();

const std = @import("std");
const assert = std.debug.assert;
const bits = @import("bits.zig");
const leb128 = std.leb;
const link = @import("../../link.zig");
const log = std.log.scoped(.codegen);
const math = std.math;
const mem = std.mem;
const testing = std.testing;

const Air = @import("../../Air.zig");
const Allocator = mem.Allocator;
const DebugInfoOutput = @import("../../codegen.zig").DebugInfoOutput;
const DW = std.dwarf;
const Encoder = bits.Encoder;
const ErrorMsg = Module.ErrorMsg;
const MCValue = @import("CodeGen.zig").MCValue;
const Mir = @import("Mir.zig");
const Module = @import("../../Module.zig");
const Instruction = bits.Instruction;
const Register = bits.Register;
const Type = @import("../../type.zig").Type;

mir: Mir,
bin_file: *link.File,
debug_output: DebugInfoOutput,
target: *const std.Target,
err_msg: ?*ErrorMsg = null,
src_loc: Module.SrcLoc,
code: *std.ArrayList(u8),

prev_di_line: u32,
prev_di_column: u32,
/// Relative to the beginning of `code`.
prev_di_pc: usize,

code_offset_mapping: std.AutoHashMapUnmanaged(Mir.Inst.Index, usize) = .{},
relocs: std.ArrayListUnmanaged(Reloc) = .{},

const InnerError = error{
    OutOfMemory,
    Overflow,
    EmitFail,
};

const Reloc = struct {
    /// Offset of the instruction.
    source: u64,
    /// Target of the relocation.
    target: Mir.Inst.Index,
    /// Offset of the relocation within the instruction.
    offset: u64,
    /// Length of the instruction.
    length: u5,
};

pub fn emitMir(emit: *Emit) InnerError!void {
    const mir_tags = emit.mir.instructions.items(.tag);

    for (mir_tags) |tag, index| {
        const inst = @intCast(u32, index);
        try emit.code_offset_mapping.putNoClobber(emit.bin_file.allocator, inst, emit.code.items.len);
        switch (tag) {
            .adc => try emit.mirArith(.adc, inst),
            .add => try emit.mirArith(.add, inst),
            .sub => try emit.mirArith(.sub, inst),
            .xor => try emit.mirArith(.xor, inst),
            .@"and" => try emit.mirArith(.@"and", inst),
            .@"or" => try emit.mirArith(.@"or", inst),
            .sbb => try emit.mirArith(.sbb, inst),
            .cmp => try emit.mirArith(.cmp, inst),
            .mov => try emit.mirArith(.mov, inst),

            .adc_scale_src => try emit.mirArithScaleSrc(.adc, inst),
            .add_scale_src => try emit.mirArithScaleSrc(.add, inst),
            .sub_scale_src => try emit.mirArithScaleSrc(.sub, inst),
            .xor_scale_src => try emit.mirArithScaleSrc(.xor, inst),
            .and_scale_src => try emit.mirArithScaleSrc(.@"and", inst),
            .or_scale_src => try emit.mirArithScaleSrc(.@"or", inst),
            .sbb_scale_src => try emit.mirArithScaleSrc(.sbb, inst),
            .cmp_scale_src => try emit.mirArithScaleSrc(.cmp, inst),
            .mov_scale_src => try emit.mirArithScaleSrc(.mov, inst),

            .adc_scale_dst => try emit.mirArithScaleDst(.adc, inst),
            .add_scale_dst => try emit.mirArithScaleDst(.add, inst),
            .sub_scale_dst => try emit.mirArithScaleDst(.sub, inst),
            .xor_scale_dst => try emit.mirArithScaleDst(.xor, inst),
            .and_scale_dst => try emit.mirArithScaleDst(.@"and", inst),
            .or_scale_dst => try emit.mirArithScaleDst(.@"or", inst),
            .sbb_scale_dst => try emit.mirArithScaleDst(.sbb, inst),
            .cmp_scale_dst => try emit.mirArithScaleDst(.cmp, inst),
            .mov_scale_dst => try emit.mirArithScaleDst(.mov, inst),

            .adc_scale_imm => try emit.mirArithScaleImm(.adc, inst),
            .add_scale_imm => try emit.mirArithScaleImm(.add, inst),
            .sub_scale_imm => try emit.mirArithScaleImm(.sub, inst),
            .xor_scale_imm => try emit.mirArithScaleImm(.xor, inst),
            .and_scale_imm => try emit.mirArithScaleImm(.@"and", inst),
            .or_scale_imm => try emit.mirArithScaleImm(.@"or", inst),
            .sbb_scale_imm => try emit.mirArithScaleImm(.sbb, inst),
            .cmp_scale_imm => try emit.mirArithScaleImm(.cmp, inst),
            .mov_scale_imm => try emit.mirArithScaleImm(.mov, inst),

            .movabs => try emit.mirMovabs(inst),

            .lea => try emit.mirLea(inst),
            .lea_rip => try emit.mirLeaRip(inst),

            .imul_complex => try emit.mirIMulComplex(inst),

            .push => try emit.mirPushPop(.push, inst),
            .pop => try emit.mirPushPop(.pop, inst),

            .jmp => try emit.mirJmpCall(.jmp_near, inst),
            .call => try emit.mirJmpCall(.call_near, inst),

            .cond_jmp_greater_less,
            .cond_jmp_above_below,
            .cond_jmp_eq_ne,
            => try emit.mirCondJmp(tag, inst),

            .cond_set_byte_greater_less,
            .cond_set_byte_above_below,
            .cond_set_byte_eq_ne,
            => try emit.mirCondSetByte(tag, inst),

            .ret => try emit.mirRet(inst),

            .syscall => try emit.mirSyscall(),

            .@"test" => try emit.mirTest(inst),

            .brk => try emit.mirBrk(),
            .nop => try emit.mirNop(),

            .call_extern => try emit.mirCallExtern(inst),

            .dbg_line => try emit.mirDbgLine(inst),
            .dbg_prologue_end => try emit.mirDbgPrologueEnd(inst),
            .dbg_epilogue_begin => try emit.mirDbgEpilogueBegin(inst),
            .arg_dbg_info => try emit.mirArgDbgInfo(inst),

            .push_regs_from_callee_preserved_regs => try emit.mirPushPopRegsFromCalleePreservedRegs(.push, inst),
            .pop_regs_from_callee_preserved_regs => try emit.mirPushPopRegsFromCalleePreservedRegs(.pop, inst),

            else => {
                return emit.fail("Implement MIR->Isel lowering for x86_64 for pseudo-inst: {s}", .{tag});
            },
        }
    }

    try emit.fixupRelocs();
}

pub fn deinit(emit: *Emit) void {
    emit.relocs.deinit(emit.bin_file.allocator);
    emit.code_offset_mapping.deinit(emit.bin_file.allocator);
    emit.* = undefined;
}

fn fail(emit: *Emit, comptime format: []const u8, args: anytype) InnerError {
    @setCold(true);
    assert(emit.err_msg == null);
    emit.err_msg = try ErrorMsg.create(emit.bin_file.allocator, emit.src_loc, format, args);
    return error.EmitFail;
}

fn fixupRelocs(emit: *Emit) InnerError!void {
    // TODO this function currently assumes all relocs via JMP/CALL instructions are 32bit in size.
    // This should be reversed like it is done in aarch64 MIR emit code: start with the smallest
    // possible resolution, i.e., 8bit, and iteratively converge on the minimum required resolution
    // until the entire decl is correctly emitted with all JMP/CALL instructions within range.
    for (emit.relocs.items) |reloc| {
        const offset = try math.cast(usize, reloc.offset);
        const target = emit.code_offset_mapping.get(reloc.target) orelse
            return emit.fail("JMP/CALL relocation target not found!", .{});
        const disp = @intCast(i32, @intCast(i64, target) - @intCast(i64, reloc.source + reloc.length));
        mem.writeIntLittle(i32, emit.code.items[offset..][0..4], disp);
    }
}

fn mirBrk(emit: *Emit) InnerError!void {
    const encoder = try Encoder.init(emit.code, 1);
    encoder.opcode_1byte(0xcc);
}

fn mirNop(emit: *Emit) InnerError!void {
    const encoder = try Encoder.init(emit.code, 1);
    encoder.opcode_1byte(0x90);
}

fn mirSyscall(emit: *Emit) InnerError!void {
    const encoder = try Encoder.init(emit.code, 2);
    encoder.opcode_2byte(0x0f, 0x05);
}

fn mirPushPop(emit: *Emit, tag: Tag, inst: Mir.Inst.Index) InnerError!void {
    const ops = Mir.Ops.decode(emit.mir.instructions.items(.ops)[inst]);
    switch (ops.flags) {
        0b00 => {
            // PUSH/POP reg
            return lowerToOEnc(tag, ops.reg1, emit.code);
        },
        0b01 => {
            // PUSH/POP r/m64
            const imm = emit.mir.instructions.items(.data)[inst].imm;
            return lowerToMEnc(tag, RegisterOrMemory.mem(ops.reg1, imm), emit.code);
        },
        0b10 => {
            // PUSH imm32
            assert(tag == .push);
            const imm = emit.mir.instructions.items(.data)[inst].imm;
            return lowerToIEnc(.push, imm, emit.code);
        },
        0b11 => unreachable,
    }
}
fn mirPushPopRegsFromCalleePreservedRegs(emit: *Emit, tag: Tag, inst: Mir.Inst.Index) InnerError!void {
    const callee_preserved_regs = bits.callee_preserved_regs;
    const regs = emit.mir.instructions.items(.data)[inst].regs_to_push_or_pop;
    if (tag == .push) {
        for (callee_preserved_regs) |reg, i| {
            if ((regs >> @intCast(u5, i)) & 1 == 0) continue;
            try lowerToOEnc(.push, reg, emit.code);
        }
    } else {
        // pop in the reverse direction
        var i = callee_preserved_regs.len;
        while (i > 0) : (i -= 1) {
            const reg = callee_preserved_regs[i - 1];
            if ((regs >> @intCast(u5, i - 1)) & 1 == 0) continue;
            try lowerToOEnc(.pop, reg, emit.code);
        }
    }
}

fn mirJmpCall(emit: *Emit, tag: Tag, inst: Mir.Inst.Index) InnerError!void {
    const ops = Mir.Ops.decode(emit.mir.instructions.items(.ops)[inst]);
    const flag = @truncate(u1, ops.flags);
    if (flag == 0) {
        const target = emit.mir.instructions.items(.data)[inst].inst;
        const source = emit.code.items.len;
        try lowerToDEnc(tag, 0, emit.code);
        try emit.relocs.append(emit.bin_file.allocator, .{
            .source = source,
            .target = target,
            .offset = emit.code.items.len - 4,
            .length = 5,
        });
        return;
    }
    if (ops.reg1 == .none) {
        // JMP/CALL [imm]
        const imm = emit.mir.instructions.items(.data)[inst].imm;
        return lowerToMEnc(tag, RegisterOrMemory.mem(null, imm), emit.code);
    }
    // JMP/CALL reg
    return lowerToMEnc(tag, RegisterOrMemory.reg(ops.reg1), emit.code);
}

const CondType = enum {
    /// greater than or equal
    gte,

    /// greater than
    gt,

    /// less than
    lt,

    /// less than or equal
    lte,

    /// above or equal
    ae,

    /// above
    a,

    /// below
    b,

    /// below or equal
    be,

    /// not equal
    ne,

    /// equal
    eq,

    fn fromTagAndFlags(tag: Mir.Inst.Tag, flags: u2) CondType {
        return switch (tag) {
            .cond_jmp_greater_less,
            .cond_set_byte_greater_less,
            => switch (flags) {
                0b00 => CondType.gte,
                0b01 => CondType.gt,
                0b10 => CondType.lt,
                0b11 => CondType.lte,
            },
            .cond_jmp_above_below,
            .cond_set_byte_above_below,
            => switch (flags) {
                0b00 => CondType.ae,
                0b01 => CondType.a,
                0b10 => CondType.b,
                0b11 => CondType.be,
            },
            .cond_jmp_eq_ne,
            .cond_set_byte_eq_ne,
            => switch (@truncate(u1, flags)) {
                0b0 => CondType.ne,
                0b1 => CondType.eq,
            },
            else => unreachable,
        };
    }
};

inline fn getCondOpCode(tag: Mir.Inst.Tag, cond: CondType) u8 {
    switch (cond) {
        .gte => return switch (tag) {
            .cond_jmp_greater_less => 0x8d,
            .cond_set_byte_greater_less => 0x9d,
            else => unreachable,
        },
        .gt => return switch (tag) {
            .cond_jmp_greater_less => 0x8f,
            .cond_set_byte_greater_less => 0x9f,
            else => unreachable,
        },
        .lt => return switch (tag) {
            .cond_jmp_greater_less => 0x8c,
            .cond_set_byte_greater_less => 0x9c,
            else => unreachable,
        },
        .lte => return switch (tag) {
            .cond_jmp_greater_less => 0x8e,
            .cond_set_byte_greater_less => 0x9e,
            else => unreachable,
        },
        .ae => return switch (tag) {
            .cond_jmp_above_below => 0x83,
            .cond_set_byte_above_below => 0x93,
            else => unreachable,
        },
        .a => return switch (tag) {
            .cond_jmp_above_below => 0x87,
            .cond_set_byte_greater_less => 0x97,
            else => unreachable,
        },
        .b => return switch (tag) {
            .cond_jmp_above_below => 0x82,
            .cond_set_byte_greater_less => 0x92,
            else => unreachable,
        },
        .be => return switch (tag) {
            .cond_jmp_above_below => 0x86,
            .cond_set_byte_greater_less => 0x96,
            else => unreachable,
        },
        .eq => return switch (tag) {
            .cond_jmp_eq_ne => 0x84,
            .cond_set_byte_eq_ne => 0x94,
            else => unreachable,
        },
        .ne => return switch (tag) {
            .cond_jmp_eq_ne => 0x85,
            .cond_set_byte_eq_ne => 0x95,
            else => unreachable,
        },
    }
}

fn mirCondJmp(emit: *Emit, tag: Mir.Inst.Tag, inst: Mir.Inst.Index) InnerError!void {
    const ops = Mir.Ops.decode(emit.mir.instructions.items(.ops)[inst]);
    const target = emit.mir.instructions.items(.data)[inst].inst;
    const cond = CondType.fromTagAndFlags(tag, ops.flags);
    const opc = getCondOpCode(tag, cond);
    const source = emit.code.items.len;
    const encoder = try Encoder.init(emit.code, 6);
    encoder.opcode_2byte(0x0f, opc);
    try emit.relocs.append(emit.bin_file.allocator, .{
        .source = source,
        .target = target,
        .offset = emit.code.items.len,
        .length = 6,
    });
    encoder.imm32(0);
}

fn mirCondSetByte(emit: *Emit, tag: Mir.Inst.Tag, inst: Mir.Inst.Index) InnerError!void {
    const ops = Mir.Ops.decode(emit.mir.instructions.items(.ops)[inst]);
    const cond = CondType.fromTagAndFlags(tag, ops.flags);
    const opc = getCondOpCode(tag, cond);
    const encoder = try Encoder.init(emit.code, 4);
    encoder.rex(.{
        .w = true,
        .b = ops.reg1.isExtended(),
    });
    encoder.opcode_2byte(0x0f, opc);
    encoder.modRm_direct(0x0, ops.reg1.lowId());
}

fn mirTest(emit: *Emit, inst: Mir.Inst.Index) InnerError!void {
    const tag = emit.mir.instructions.items(.tag)[inst];
    assert(tag == .@"test");
    const ops = Mir.Ops.decode(emit.mir.instructions.items(.ops)[inst]);
    switch (ops.flags) {
        0b00 => {
            if (ops.reg2 == .none) {
                // TEST r/m64, imm32
                // MI
                const imm = emit.mir.instructions.items(.data)[inst].imm;
                if (ops.reg1.to64() == .rax) {
                    // TEST rax, imm32
                    // I
                    return lowerToIEnc(.@"test", imm, emit.code);
                }
                return lowerToMiEnc(.@"test", RegisterOrMemory.reg(ops.reg1), imm, emit.code);
            }
            // TEST r/m64, r64
            return emit.fail("TODO TEST r/m64, r64", .{});
        },
        else => return emit.fail("TODO more TEST alternatives", .{}),
    }
}

fn mirRet(emit: *Emit, inst: Mir.Inst.Index) InnerError!void {
    const tag = emit.mir.instructions.items(.tag)[inst];
    assert(tag == .ret);
    const ops = Mir.Ops.decode(emit.mir.instructions.items(.ops)[inst]);
    const encoder = try Encoder.init(emit.code, 3);
    switch (ops.flags) {
        0b00 => {
            // RETF imm16
            // I
            const imm = emit.mir.instructions.items(.data)[inst].imm;
            return lowerToIEnc(.ret_far, imm, emit.code);
        },
        0b01 => encoder.opcode_1byte(0xcb), // RETF
        0b10 => {
            // RET imm16
            // I
            const imm = emit.mir.instructions.items(.data)[inst].imm;
            return lowerToIEnc(.ret_near, imm, emit.code);
        },
        0b11 => encoder.opcode_1byte(0xc3), // RET
    }
}

const Tag = enum {
    adc,
    add,
    sub,
    xor,
    @"and",
    @"or",
    sbb,
    cmp,
    mov,
    lea,
    jmp_near,
    call_near,
    push,
    pop,
    @"test",
    ret_near,
    ret_far,
};

const Encoding = enum {
    /// OP rel32
    d,

    /// OP r/m64
    m,

    /// OP r64
    o,

    /// OP imm32
    i,

    /// OP r/m64, imm32
    mi,

    /// OP r/m64, r64
    mr,

    /// OP r64, r/m64
    rm,

    /// OP r64, imm64
    oi,

    /// OP al/ax/eax/rax, moffs
    fd,

    /// OP moffs, al/ax/eax/rax
    td,
};

inline fn getOpCode(tag: Tag, enc: Encoding) ?u8 {
    switch (enc) {
        .d => return switch (tag) {
            .jmp_near => 0xe9,
            .call_near => 0xe8,
            else => null,
        },
        .m => return switch (tag) {
            .jmp_near, .call_near, .push => 0xff,
            .pop => 0x8f,
            else => null,
        },
        .o => return switch (tag) {
            .push => 0x50,
            .pop => 0x58,
            else => null,
        },
        .i => return switch (tag) {
            .push => 0x68,
            .@"test" => 0xa9,
            .ret_near => 0xc2,
            .ret_far => 0xca,
            else => null,
        },
        .mi => return switch (tag) {
            .adc, .add, .sub, .xor, .@"and", .@"or", .sbb, .cmp => 0x81,
            .mov => 0xc7,
            .@"test" => 0xf7,
            else => null,
        },
        .mr => return switch (tag) {
            .adc => 0x11,
            .add => 0x01,
            .sub => 0x29,
            .xor => 0x31,
            .@"and" => 0x21,
            .@"or" => 0x09,
            .sbb => 0x19,
            .cmp => 0x39,
            .mov => 0x89,
            else => null,
        },
        .rm => return switch (tag) {
            .adc => 0x13,
            .add => 0x03,
            .sub => 0x2b,
            .xor => 0x33,
            .@"and" => 0x23,
            .@"or" => 0x0b,
            .sbb => 0x1b,
            .cmp => 0x3b,
            .mov => 0x8b,
            .lea => 0x8d,
            else => null,
        },
        .oi => return switch (tag) {
            .mov => 0xb8,
            else => null,
        },
        .fd => return switch (tag) {
            .mov => 0xa1,
            else => null,
        },
        .td => return switch (tag) {
            .mov => 0xa3,
            else => null,
        },
    }
}

inline fn getModRmExt(tag: Tag) ?u3 {
    return switch (tag) {
        .adc => 0x2,
        .add => 0x0,
        .sub => 0x5,
        .xor => 0x6,
        .@"and" => 0x4,
        .@"or" => 0x1,
        .sbb => 0x3,
        .cmp => 0x7,
        .mov => 0x0,
        .jmp_near => 0x4,
        .call_near => 0x2,
        .push => 0x6,
        .pop => 0x0,
        .@"test" => 0x0,
        else => null,
    };
}

const ScaleIndexBase = struct {
    scale: u2,
    index_reg: ?Register,
    base_reg: ?Register,
};

const Memory = struct {
    reg: ?Register,
    rip: bool = false,
    disp: i32,
    sib: ?ScaleIndexBase = null,
};

const RegisterOrMemory = union(enum) {
    register: Register,
    memory: Memory,

    fn reg(register: Register) RegisterOrMemory {
        return .{ .register = register };
    }

    fn mem(register: ?Register, disp: i32) RegisterOrMemory {
        return .{
            .memory = .{
                .reg = register,
                .disp = disp,
            },
        };
    }

    fn rip(disp: i32) RegisterOrMemory {
        return .{
            .memory = .{
                .reg = null,
                .rip = true,
                .disp = disp,
            },
        };
    }
};

fn lowerToIEnc(tag: Tag, imm: i32, code: *std.ArrayList(u8)) InnerError!void {
    var opc = getOpCode(tag, .i).?;
    if (tag == .ret_far or tag == .ret_near) {
        const encoder = try Encoder.init(code, 3);
        encoder.opcode_1byte(opc);
        encoder.imm16(@intCast(i16, imm));
        return;
    }
    if (immOpSize(imm) == 8) {
        // TODO I think getOpCode should track this
        switch (tag) {
            .push => opc += 2,
            .@"test" => opc -= 1,
            else => return error.EmitFail,
        }
    }
    const encoder = try Encoder.init(code, 5);
    if (immOpSize(imm) == 16) {
        encoder.opcode_1byte(0x66);
    }
    encoder.opcode_1byte(opc);
    if (immOpSize(imm) == 8) {
        encoder.imm8(@intCast(i8, imm));
    } else if (immOpSize(imm) == 16) {
        encoder.imm16(@intCast(i16, imm));
    } else {
        encoder.imm32(imm);
    }
}

fn lowerToOEnc(tag: Tag, reg: Register, code: *std.ArrayList(u8)) InnerError!void {
    if (reg.size() != 16 and reg.size() != 64) return error.EmitFail; // TODO correct for push/pop, but is it universal?
    const opc = getOpCode(tag, .o).?;
    const encoder = try Encoder.init(code, 3);
    if (reg.size() == 16) {
        encoder.opcode_1byte(0x66);
    }
    encoder.rex(.{
        .w = false,
        .b = reg.isExtended(),
    });
    encoder.opcode_withReg(opc, reg.lowId());
}

fn lowerToDEnc(tag: Tag, imm: i32, code: *std.ArrayList(u8)) InnerError!void {
    const opc = getOpCode(tag, .d).?;
    const encoder = try Encoder.init(code, 5);
    encoder.opcode_1byte(opc);
    encoder.imm32(imm);
}

fn lowerToMEnc(tag: Tag, reg_or_mem: RegisterOrMemory, code: *std.ArrayList(u8)) InnerError!void {
    const opc = getOpCode(tag, .m).?;
    const modrm_ext = getModRmExt(tag).?;
    switch (reg_or_mem) {
        .register => |reg| {
            if (reg.size() != 64) return error.EmitFail;
            const encoder = try Encoder.init(code, 3);
            encoder.rex(.{
                .w = false,
                .b = reg.isExtended(),
            });
            encoder.opcode_1byte(opc);
            encoder.modRm_direct(modrm_ext, reg.lowId());
        },
        .memory => |mem_op| {
            const encoder = try Encoder.init(code, 8);
            if (mem_op.reg) |reg| {
                if (reg.size() != 64) return error.EmitFail;
                encoder.rex(.{
                    .w = false,
                    .b = reg.isExtended(),
                });
                encoder.opcode_1byte(opc);
                if (reg.lowId() == 4) {
                    if (mem_op.disp == 0) {
                        encoder.modRm_SIBDisp0(modrm_ext);
                        encoder.sib_base(reg.lowId());
                    } else if (immOpSize(mem_op.disp) == 8) {
                        encoder.modRm_SIBDisp8(modrm_ext);
                        encoder.sib_baseDisp8(reg.lowId());
                        encoder.disp8(@intCast(i8, mem_op.disp));
                    } else {
                        encoder.modRm_SIBDisp32(modrm_ext);
                        encoder.sib_baseDisp32(reg.lowId());
                        encoder.disp32(mem_op.disp);
                    }
                } else {
                    if (mem_op.disp == 0) {
                        encoder.modRm_indirectDisp0(modrm_ext, reg.lowId());
                    } else if (immOpSize(mem_op.disp) == 8) {
                        encoder.modRm_indirectDisp8(modrm_ext, reg.lowId());
                        encoder.disp8(@intCast(i8, mem_op.disp));
                    } else {
                        encoder.modRm_indirectDisp32(modrm_ext, reg.lowId());
                        encoder.disp32(mem_op.disp);
                    }
                }
            } else {
                encoder.opcode_1byte(opc);
                if (mem_op.rip) {
                    encoder.modRm_RIPDisp32(modrm_ext);
                } else {
                    encoder.modRm_SIBDisp0(modrm_ext);
                    encoder.sib_disp32();
                }
                encoder.disp32(mem_op.disp);
            }
        },
    }
}

fn lowerToTdEnc(tag: Tag, moffs: i64, reg: Register, code: *std.ArrayList(u8)) InnerError!void {
    return lowerToTdFdEnc(tag, reg, moffs, code, true);
}

fn lowerToFdEnc(tag: Tag, reg: Register, moffs: i64, code: *std.ArrayList(u8)) InnerError!void {
    return lowerToTdFdEnc(tag, reg, moffs, code, false);
}

fn lowerToTdFdEnc(tag: Tag, reg: Register, moffs: i64, code: *std.ArrayList(u8), td: bool) InnerError!void {
    if (reg.lowId() != Register.rax.lowId()) return error.EmitFail;
    if (reg.size() != immOpSize(moffs)) return error.EmitFail;
    var opc = if (td) getOpCode(tag, .td).? else getOpCode(tag, .fd).?;
    if (reg.size() == 8) {
        opc -= 1;
    }
    const encoder = try Encoder.init(code, 10);
    if (reg.size() == 16) {
        encoder.opcode_1byte(0x66);
    }
    encoder.rex(.{
        .w = reg.size() == 64,
    });
    encoder.opcode_1byte(opc);
    switch (reg.size()) {
        8 => {
            const moffs8 = try math.cast(i8, moffs);
            encoder.imm8(moffs8);
        },
        16 => {
            const moffs16 = try math.cast(i16, moffs);
            encoder.imm16(moffs16);
        },
        32 => {
            const moffs32 = try math.cast(i32, moffs);
            encoder.imm32(moffs32);
        },
        64 => {
            encoder.imm64(@bitCast(u64, moffs));
        },
        else => unreachable,
    }
}

fn lowerToOiEnc(tag: Tag, reg: Register, imm: i64, code: *std.ArrayList(u8)) InnerError!void {
    var opc = getOpCode(tag, .oi).?;
    if (reg.size() != immOpSize(imm)) return error.EmitFail;
    if (reg.size() == 8) {
        opc -= 8;
    }
    const encoder = try Encoder.init(code, 10);
    if (reg.size() == 16) {
        encoder.opcode_1byte(0x66);
    }
    encoder.rex(.{
        .w = reg.size() == 64,
        .b = reg.isExtended(),
    });
    encoder.opcode_withReg(opc, reg.lowId());
    switch (reg.size()) {
        8 => {
            const imm8 = try math.cast(i8, imm);
            encoder.imm8(imm8);
        },
        16 => {
            const imm16 = try math.cast(i16, imm);
            encoder.imm16(imm16);
        },
        32 => {
            const imm32 = try math.cast(i32, imm);
            encoder.imm32(imm32);
        },
        64 => {
            encoder.imm64(@bitCast(u64, imm));
        },
        else => unreachable,
    }
}

fn lowerToMiEnc(tag: Tag, reg_or_mem: RegisterOrMemory, imm: i32, code: *std.ArrayList(u8)) InnerError!void {
    var opc = getOpCode(tag, .mi).?;
    const modrm_ext = getModRmExt(tag).?;
    switch (reg_or_mem) {
        .register => |dst_reg| {
            if (dst_reg.size() == 8) {
                opc -= 1;
            }
            const encoder = try Encoder.init(code, 7);
            if (dst_reg.size() == 16) {
                // 0x66 prefix switches to the non-default size; here we assume a switch from
                // the default 32bits to 16bits operand-size.
                // More info: https://www.cs.uni-potsdam.de/desn/lehre/ss15/64-ia-32-architectures-software-developer-instruction-set-reference-manual-325383.pdf#page=32&zoom=auto,-159,773
                encoder.opcode_1byte(0x66);
            }
            encoder.rex(.{
                .w = dst_reg.size() == 64,
                .b = dst_reg.isExtended(),
            });
            encoder.opcode_1byte(opc);
            encoder.modRm_direct(modrm_ext, dst_reg.lowId());
            switch (dst_reg.size()) {
                8 => {
                    const imm8 = try math.cast(i8, imm);
                    encoder.imm8(imm8);
                },
                16 => {
                    const imm16 = try math.cast(i16, imm);
                    encoder.imm16(imm16);
                },
                32, 64 => encoder.imm32(imm),
                else => unreachable,
            }
        },
        .memory => |dst_mem| {
            const encoder = try Encoder.init(code, 12);
            if (dst_mem.reg) |dst_reg| {
                // Register dst_reg can either be 64bit or 32bit in size.
                // TODO for memory operand, immediate operand pair, we currently
                // have no way of flagging whether the immediate can be 8-, 16- or
                // 32-bit and whether the corresponding memory operand is respectively
                // a byte, word or dword ptr.
                // TODO we currently don't have a way to flag imm32 64bit sign extended
                if (dst_reg.size() != 64) return error.EmitFail;
                encoder.rex(.{
                    .w = false,
                    .b = dst_reg.isExtended(),
                });
                encoder.opcode_1byte(opc);
                if (dst_reg.lowId() == 4) {
                    if (dst_mem.disp == 0) {
                        encoder.modRm_SIBDisp0(modrm_ext);
                        encoder.sib_base(dst_reg.lowId());
                    } else if (immOpSize(dst_mem.disp) == 8) {
                        encoder.modRm_SIBDisp8(modrm_ext);
                        encoder.sib_baseDisp8(dst_reg.lowId());
                        encoder.disp8(@intCast(i8, dst_mem.disp));
                    } else {
                        encoder.modRm_SIBDisp32(modrm_ext);
                        encoder.sib_baseDisp32(dst_reg.lowId());
                        encoder.disp32(dst_mem.disp);
                    }
                } else {
                    if (dst_mem.disp == 0) {
                        encoder.modRm_indirectDisp0(modrm_ext, dst_reg.lowId());
                    } else if (immOpSize(dst_mem.disp) == 8) {
                        encoder.modRm_indirectDisp8(modrm_ext, dst_reg.lowId());
                        encoder.disp8(@intCast(i8, dst_mem.disp));
                    } else {
                        encoder.modRm_indirectDisp32(modrm_ext, dst_reg.lowId());
                        encoder.disp32(dst_mem.disp);
                    }
                }
            } else {
                encoder.opcode_1byte(opc);
                if (dst_mem.rip) {
                    encoder.modRm_RIPDisp32(modrm_ext);
                } else {
                    encoder.modRm_SIBDisp0(modrm_ext);
                    encoder.sib_disp32();
                }
                encoder.disp32(dst_mem.disp);
            }
            encoder.imm32(imm);
        },
    }
}

fn lowerToRmEnc(
    tag: Tag,
    reg: Register,
    reg_or_mem: RegisterOrMemory,
    code: *std.ArrayList(u8),
) InnerError!void {
    var opc = getOpCode(tag, .rm).?;
    if (reg.size() == 8) {
        opc -= 1;
    }
    switch (reg_or_mem) {
        .register => |src_reg| {
            if (reg.size() != src_reg.size()) return error.EmitFail;
            const encoder = try Encoder.init(code, 3);
            encoder.rex(.{
                .w = reg.size() == 64,
                .r = reg.isExtended(),
                .b = src_reg.isExtended(),
            });
            encoder.opcode_1byte(opc);
            encoder.modRm_direct(reg.lowId(), src_reg.lowId());
        },
        .memory => |src_mem| {
            const encoder = try Encoder.init(code, 9);
            if (reg.size() == 16) {
                encoder.opcode_1byte(0x66);
            }
            if (src_mem.reg) |src_reg| {
                // TODO handle 32-bit base register - requires prefix 0x67
                // Intel Manual, Vol 1, chapter 3.6 and 3.6.1
                if (src_reg.size() != 64) return error.EmitFail;
                encoder.rex(.{
                    .w = reg.size() == 64,
                    .r = reg.isExtended(),
                    .b = src_reg.isExtended(),
                });
                encoder.opcode_1byte(opc);
                if (src_reg.lowId() == 4) {
                    if (src_mem.disp == 0) {
                        encoder.modRm_SIBDisp0(reg.lowId());
                        encoder.sib_base(src_reg.lowId());
                    } else if (immOpSize(src_mem.disp) == 8) {
                        encoder.modRm_SIBDisp8(reg.lowId());
                        encoder.sib_baseDisp8(src_reg.lowId());
                        encoder.disp8(@intCast(i8, src_mem.disp));
                    } else {
                        encoder.modRm_SIBDisp32(reg.lowId());
                        encoder.sib_baseDisp32(src_reg.lowId());
                        encoder.disp32(src_mem.disp);
                    }
                } else {
                    if (src_mem.disp == 0) {
                        encoder.modRm_indirectDisp0(reg.lowId(), src_reg.lowId());
                    } else if (immOpSize(src_mem.disp) == 8) {
                        encoder.modRm_indirectDisp8(reg.lowId(), src_reg.lowId());
                        encoder.disp8(@intCast(i8, src_mem.disp));
                    } else {
                        encoder.modRm_indirectDisp32(reg.lowId(), src_reg.lowId());
                        encoder.disp32(src_mem.disp);
                    }
                }
            } else {
                encoder.rex(.{
                    .w = reg.size() == 64,
                    .r = reg.isExtended(),
                });
                encoder.opcode_1byte(opc);
                if (src_mem.rip) {
                    encoder.modRm_RIPDisp32(reg.lowId());
                } else {
                    encoder.modRm_SIBDisp0(reg.lowId());
                    encoder.sib_disp32();
                }
                encoder.disp32(src_mem.disp);
            }
        },
    }
}

fn lowerToMrEnc(
    tag: Tag,
    reg_or_mem: RegisterOrMemory,
    reg: Register,
    code: *std.ArrayList(u8),
) InnerError!void {
    // We use size of source register reg to work out which
    // variant of memory ptr to pick:
    // * reg is 64bit - qword ptr
    // * reg is 32bit - dword ptr
    // * reg is 16bit - word ptr
    // * reg is 8bit - byte ptr
    var opc = getOpCode(tag, .mr).?;
    if (reg.size() == 8) {
        opc -= 1;
    }
    switch (reg_or_mem) {
        .register => |dst_reg| {
            if (dst_reg.size() != reg.size()) return error.EmitFail;
            const encoder = try Encoder.init(code, 3);
            encoder.rex(.{
                .w = dst_reg.size() == 64,
                .r = reg.isExtended(),
                .b = dst_reg.isExtended(),
            });
            encoder.opcode_1byte(opc);
            encoder.modRm_direct(reg.lowId(), dst_reg.lowId());
        },
        .memory => |dst_mem| {
            const encoder = try Encoder.init(code, 9);
            if (reg.size() == 16) {
                encoder.opcode_1byte(0x66);
            }
            if (dst_mem.reg) |dst_reg| {
                if (dst_reg.size() != 64) return error.EmitFail;
                encoder.rex(.{
                    .w = reg.size() == 64,
                    .r = reg.isExtended(),
                    .b = dst_reg.isExtended(),
                });
                encoder.opcode_1byte(opc);
                if (dst_reg.lowId() == 4) {
                    if (dst_mem.disp == 0) {
                        encoder.modRm_SIBDisp0(reg.lowId());
                        encoder.sib_base(dst_reg.lowId());
                    } else if (immOpSize(dst_mem.disp) == 8) {
                        encoder.modRm_SIBDisp8(reg.lowId());
                        encoder.sib_baseDisp8(dst_reg.lowId());
                        encoder.disp8(@intCast(i8, dst_mem.disp));
                    } else {
                        encoder.modRm_SIBDisp32(reg.lowId());
                        encoder.sib_baseDisp32(dst_reg.lowId());
                        encoder.disp32(dst_mem.disp);
                    }
                } else {
                    if (dst_mem.disp == 0) {
                        encoder.modRm_indirectDisp0(reg.lowId(), dst_reg.lowId());
                    } else if (immOpSize(dst_mem.disp) == 8) {
                        encoder.modRm_indirectDisp8(reg.lowId(), dst_reg.lowId());
                        encoder.disp8(@intCast(i8, dst_mem.disp));
                    } else {
                        encoder.modRm_indirectDisp32(reg.lowId(), dst_reg.lowId());
                        encoder.disp32(dst_mem.disp);
                    }
                }
            } else {
                encoder.rex(.{
                    .w = reg.size() == 64,
                    .r = reg.isExtended(),
                });
                encoder.opcode_1byte(opc);
                if (dst_mem.rip) {
                    encoder.modRm_RIPDisp32(reg.lowId());
                } else {
                    encoder.modRm_SIBDisp0(reg.lowId());
                    encoder.sib_disp32();
                }
                encoder.disp32(dst_mem.disp);
            }
        },
    }
}

fn mirArith(emit: *Emit, tag: Tag, inst: Mir.Inst.Index) InnerError!void {
    const ops = Mir.Ops.decode(emit.mir.instructions.items(.ops)[inst]);
    switch (ops.flags) {
        0b00 => {
            if (ops.reg2 == .none) {
                // mov reg1, imm32
                // MI
                const imm = emit.mir.instructions.items(.data)[inst].imm;
                return lowerToMiEnc(tag, RegisterOrMemory.reg(ops.reg1), imm, emit.code);
            }
            // mov reg1, reg2
            // RM
            return lowerToRmEnc(tag, ops.reg1, RegisterOrMemory.reg(ops.reg2), emit.code);
        },
        0b01 => {
            const imm = emit.mir.instructions.items(.data)[inst].imm;
            if (ops.reg2 == .none) {
                // mov reg1, [imm32]
                // RM
                return lowerToRmEnc(tag, ops.reg1, RegisterOrMemory.mem(null, imm), emit.code);
            }
            // mov reg1, [reg2 + imm32]
            // RM
            return lowerToRmEnc(tag, ops.reg1, RegisterOrMemory.mem(ops.reg2, imm), emit.code);
        },
        0b10 => {
            if (ops.reg2 == .none) {
                // mov dword ptr [reg1 + 0], imm32
                // MI
                const imm = emit.mir.instructions.items(.data)[inst].imm;
                return lowerToMiEnc(tag, RegisterOrMemory.mem(ops.reg1, 0), imm, emit.code);
            }
            // mov [reg1 + imm32], reg2
            // MR
            const imm = emit.mir.instructions.items(.data)[inst].imm;
            return lowerToMrEnc(tag, RegisterOrMemory.mem(ops.reg1, imm), ops.reg2, emit.code);
        },
        0b11 => {
            if (ops.reg2 == .none) {
                // mov dword ptr [reg1 + imm32], imm32
                // MI
                const payload = emit.mir.instructions.items(.data)[inst].payload;
                const imm_pair = emit.mir.extraData(Mir.ImmPair, payload).data;
                return lowerToMiEnc(
                    tag,
                    RegisterOrMemory.mem(ops.reg1, imm_pair.dest_off),
                    imm_pair.operand,
                    emit.code,
                );
            }
            return emit.fail("TODO unused variant: mov reg1, reg2, 0b11", .{});
        },
    }
}

fn immOpSize(imm: i64) u8 {
    blk: {
        _ = math.cast(i8, imm) catch break :blk;
        return 8;
    }
    blk: {
        _ = math.cast(i16, imm) catch break :blk;
        return 16;
    }
    blk: {
        _ = math.cast(i32, imm) catch break :blk;
        return 32;
    }
    return 64;
}

fn mirArithScaleSrc(emit: *Emit, tag: Tag, inst: Mir.Inst.Index) InnerError!void {
    const ops = Mir.Ops.decode(emit.mir.instructions.items(.ops)[inst]);
    const scale = ops.flags;
    // OP reg1, [reg2 + scale*rcx + imm32]
    var opc = getOpCode(tag, .rm).?;
    if (ops.reg1.size() == 8) {
        opc -= 1;
    }
    const imm = emit.mir.instructions.items(.data)[inst].imm;
    const encoder = try Encoder.init(emit.code, 8);
    encoder.rex(.{
        .w = ops.reg1.size() == 64,
        .r = ops.reg1.isExtended(),
        .b = ops.reg2.isExtended(),
    });
    encoder.opcode_1byte(opc);
    if (imm <= math.maxInt(i8)) {
        encoder.modRm_SIBDisp8(ops.reg1.lowId());
        encoder.sib_scaleIndexBaseDisp8(scale, Register.rcx.lowId(), ops.reg2.lowId());
        encoder.disp8(@intCast(i8, imm));
    } else {
        encoder.modRm_SIBDisp32(ops.reg1.lowId());
        encoder.sib_scaleIndexBaseDisp32(scale, Register.rcx.lowId(), ops.reg2.lowId());
        encoder.disp32(imm);
    }
}

fn mirArithScaleDst(emit: *Emit, tag: Tag, inst: Mir.Inst.Index) InnerError!void {
    const ops = Mir.Ops.decode(emit.mir.instructions.items(.ops)[inst]);
    const scale = ops.flags;
    const imm = emit.mir.instructions.items(.data)[inst].imm;

    if (ops.reg2 == .none) {
        // OP [reg1 + scale*rax + 0], imm32
        var opc = getOpCode(tag, .mi).?;
        const modrm_ext = getModRmExt(tag).?;
        if (ops.reg1.size() == 8) {
            opc -= 1;
        }
        const encoder = try Encoder.init(emit.code, 8);
        encoder.rex(.{
            .w = ops.reg1.size() == 64,
            .b = ops.reg1.isExtended(),
        });
        encoder.opcode_1byte(opc);
        encoder.modRm_SIBDisp0(modrm_ext);
        encoder.sib_scaleIndexBase(scale, Register.rax.lowId(), ops.reg1.lowId());
        if (imm <= math.maxInt(i8)) {
            encoder.imm8(@intCast(i8, imm));
        } else if (imm <= math.maxInt(i16)) {
            encoder.imm16(@intCast(i16, imm));
        } else {
            encoder.imm32(imm);
        }
        return;
    }

    // OP [reg1 + scale*rax + imm32], reg2
    var opc = getOpCode(tag, .mr).?;
    if (ops.reg1.size() == 8) {
        opc -= 1;
    }
    const encoder = try Encoder.init(emit.code, 8);
    encoder.rex(.{
        .w = ops.reg1.size() == 64,
        .r = ops.reg2.isExtended(),
        .b = ops.reg1.isExtended(),
    });
    encoder.opcode_1byte(opc);
    if (imm <= math.maxInt(i8)) {
        encoder.modRm_SIBDisp8(ops.reg2.lowId());
        encoder.sib_scaleIndexBaseDisp8(scale, Register.rax.lowId(), ops.reg1.lowId());
        encoder.disp8(@intCast(i8, imm));
    } else {
        encoder.modRm_SIBDisp32(ops.reg2.lowId());
        encoder.sib_scaleIndexBaseDisp32(scale, Register.rax.lowId(), ops.reg1.lowId());
        encoder.disp32(imm);
    }
}

fn mirArithScaleImm(emit: *Emit, tag: Tag, inst: Mir.Inst.Index) InnerError!void {
    const ops = Mir.Ops.decode(emit.mir.instructions.items(.ops)[inst]);
    const scale = ops.flags;
    const payload = emit.mir.instructions.items(.data)[inst].payload;
    const imm_pair = emit.mir.extraData(Mir.ImmPair, payload).data;
    var opc = getOpCode(tag, .mi).?;
    if (ops.reg1.size() == 8) {
        opc -= 1;
    }
    const modrm_ext = getModRmExt(tag).?;
    const encoder = try Encoder.init(emit.code, 2);
    encoder.rex(.{
        .w = ops.reg1.size() == 64,
        .b = ops.reg1.isExtended(),
    });
    encoder.opcode_1byte(opc);
    if (imm_pair.dest_off <= math.maxInt(i8)) {
        encoder.modRm_SIBDisp8(modrm_ext);
        encoder.sib_scaleIndexBaseDisp8(scale, Register.rax.lowId(), ops.reg1.lowId());
        encoder.disp8(@intCast(i8, imm_pair.dest_off));
    } else {
        encoder.modRm_SIBDisp32(modrm_ext);
        encoder.sib_scaleIndexBaseDisp32(scale, Register.rax.lowId(), ops.reg1.lowId());
        encoder.disp32(imm_pair.dest_off);
    }
    encoder.imm32(imm_pair.operand);
}

fn mirMovabs(emit: *Emit, inst: Mir.Inst.Index) InnerError!void {
    const tag = emit.mir.instructions.items(.tag)[inst];
    assert(tag == .movabs);
    const ops = Mir.Ops.decode(emit.mir.instructions.items(.ops)[inst]);
    const imm: i64 = if (ops.reg1.size() == 64) blk: {
        const payload = emit.mir.instructions.items(.data)[inst].payload;
        const imm = emit.mir.extraData(Mir.Imm64, payload).data;
        break :blk @bitCast(i64, imm.decode());
    } else emit.mir.instructions.items(.data)[inst].imm;
    if (ops.flags == 0b00) {
        // movabs reg, imm64
        // OI
        return lowerToOiEnc(.mov, ops.reg1, imm, emit.code);
    }
    if (ops.reg1 == .none) {
        // movabs moffs64, rax
        // TD
        return lowerToTdEnc(.mov, imm, ops.reg2, emit.code);
    } else {
        // movabs rax, moffs64
        // FD
        return lowerToFdEnc(.mov, ops.reg1, imm, emit.code);
    }
}

fn mirIMulComplex(emit: *Emit, inst: Mir.Inst.Index) InnerError!void {
    const tag = emit.mir.instructions.items(.tag)[inst];
    assert(tag == .imul_complex);
    const ops = Mir.Ops.decode(emit.mir.instructions.items(.ops)[inst]);
    switch (ops.flags) {
        0b00 => {
            const encoder = try Encoder.init(emit.code, 4);
            encoder.rex(.{
                .w = ops.reg1.size() == 64,
                .r = ops.reg1.isExtended(),
                .b = ops.reg2.isExtended(),
            });
            encoder.opcode_2byte(0x0f, 0xaf);
            encoder.modRm_direct(ops.reg1.lowId(), ops.reg2.lowId());
        },
        0b10 => {
            const imm = emit.mir.instructions.items(.data)[inst].imm;
            const opc: u8 = if (imm <= math.maxInt(i8)) 0x6b else 0x69;
            const encoder = try Encoder.init(emit.code, 7);
            encoder.rex(.{
                .w = ops.reg1.size() == 64,
                .r = ops.reg1.isExtended(),
                .b = ops.reg1.isExtended(),
            });
            encoder.opcode_1byte(opc);
            encoder.modRm_direct(ops.reg1.lowId(), ops.reg2.lowId());
            if (imm <= math.maxInt(i8)) {
                encoder.imm8(@intCast(i8, imm));
            } else if (imm <= math.maxInt(i16)) {
                encoder.imm16(@intCast(i16, imm));
            } else {
                encoder.imm32(imm);
            }
        },
        else => return emit.fail("TODO implement imul", .{}),
    }
}

fn mirLea(emit: *Emit, inst: Mir.Inst.Index) InnerError!void {
    const tag = emit.mir.instructions.items(.tag)[inst];
    assert(tag == .lea);
    const ops = Mir.Ops.decode(emit.mir.instructions.items(.ops)[inst]);
    assert(ops.flags == 0b01);
    const imm = emit.mir.instructions.items(.data)[inst].imm;
    return lowerToRmEnc(.lea, ops.reg1, RegisterOrMemory.mem(ops.reg2, imm), emit.code);
}

fn mirLeaRip(emit: *Emit, inst: Mir.Inst.Index) InnerError!void {
    const tag = emit.mir.instructions.items(.tag)[inst];
    assert(tag == .lea_rip);
    const ops = Mir.Ops.decode(emit.mir.instructions.items(.ops)[inst]);
    const start_offset = emit.code.items.len;
    try lowerToRmEnc(.lea, ops.reg1, RegisterOrMemory.rip(0), emit.code);
    const end_offset = emit.code.items.len;
    if (@truncate(u1, ops.flags) == 0b0) {
        // Backpatch the displacement
        // TODO figure out if this can be simplified
        const payload = emit.mir.instructions.items(.data)[inst].payload;
        const imm = emit.mir.extraData(Mir.Imm64, payload).data.decode();
        const disp = @intCast(i32, @intCast(i64, imm) - @intCast(i64, end_offset - start_offset));
        mem.writeIntLittle(i32, emit.code.items[end_offset - 4 ..][0..4], disp);
    } else {
        const got_entry = emit.mir.instructions.items(.data)[inst].got_entry;
        if (emit.bin_file.cast(link.File.MachO)) |macho_file| {
            // TODO I think the reloc might be in the wrong place.
            const decl = macho_file.active_decl.?;
            try decl.link.macho.relocs.append(emit.bin_file.allocator, .{
                .offset = @intCast(u32, end_offset - 4),
                .target = .{ .local = got_entry },
                .addend = 0,
                .subtractor = null,
                .pcrel = true,
                .length = 2,
                .@"type" = @enumToInt(std.macho.reloc_type_x86_64.X86_64_RELOC_GOT),
            });
        } else {
            return emit.fail("TODO implement lea_rip for linking backends different than MachO", .{});
        }
    }
}

fn mirCallExtern(emit: *Emit, inst: Mir.Inst.Index) InnerError!void {
    const tag = emit.mir.instructions.items(.tag)[inst];
    assert(tag == .call_extern);
    const n_strx = emit.mir.instructions.items(.data)[inst].extern_fn;
    const offset = blk: {
        // callq
        try lowerToDEnc(.call_near, 0, emit.code);
        break :blk @intCast(u32, emit.code.items.len) - 4;
    };
    if (emit.bin_file.cast(link.File.MachO)) |macho_file| {
        // Add relocation to the decl.
        try macho_file.active_decl.?.link.macho.relocs.append(emit.bin_file.allocator, .{
            .offset = offset,
            .target = .{ .global = n_strx },
            .addend = 0,
            .subtractor = null,
            .pcrel = true,
            .length = 2,
            .@"type" = @enumToInt(std.macho.reloc_type_x86_64.X86_64_RELOC_BRANCH),
        });
    } else {
        return emit.fail("TODO implement call_extern for linking backends different than MachO", .{});
    }
}

fn mirDbgLine(emit: *Emit, inst: Mir.Inst.Index) InnerError!void {
    const tag = emit.mir.instructions.items(.tag)[inst];
    assert(tag == .dbg_line);
    const payload = emit.mir.instructions.items(.data)[inst].payload;
    const dbg_line_column = emit.mir.extraData(Mir.DbgLineColumn, payload).data;
    try emit.dbgAdvancePCAndLine(dbg_line_column.line, dbg_line_column.column);
}

fn dbgAdvancePCAndLine(emit: *Emit, line: u32, column: u32) InnerError!void {
    const delta_line = @intCast(i32, line) - @intCast(i32, emit.prev_di_line);
    const delta_pc: usize = emit.code.items.len - emit.prev_di_pc;
    switch (emit.debug_output) {
        .dwarf => |dbg_out| {
            // TODO Look into using the DWARF special opcodes to compress this data.
            // It lets you emit single-byte opcodes that add different numbers to
            // both the PC and the line number at the same time.
            try dbg_out.dbg_line.ensureUnusedCapacity(11);
            dbg_out.dbg_line.appendAssumeCapacity(DW.LNS.advance_pc);
            leb128.writeULEB128(dbg_out.dbg_line.writer(), delta_pc) catch unreachable;
            if (delta_line != 0) {
                dbg_out.dbg_line.appendAssumeCapacity(DW.LNS.advance_line);
                leb128.writeILEB128(dbg_out.dbg_line.writer(), delta_line) catch unreachable;
            }
            dbg_out.dbg_line.appendAssumeCapacity(DW.LNS.copy);
            emit.prev_di_pc = emit.code.items.len;
            emit.prev_di_line = line;
            emit.prev_di_column = column;
            emit.prev_di_pc = emit.code.items.len;
        },
        .plan9 => |dbg_out| {
            if (delta_pc <= 0) return; // only do this when the pc changes
            // we have already checked the target in the linker to make sure it is compatable
            const quant = @import("../../link/Plan9/aout.zig").getPCQuant(emit.target.cpu.arch) catch unreachable;

            // increasing the line number
            try @import("../../link/Plan9.zig").changeLine(dbg_out.dbg_line, delta_line);
            // increasing the pc
            const d_pc_p9 = @intCast(i64, delta_pc) - quant;
            if (d_pc_p9 > 0) {
                // minus one because if its the last one, we want to leave space to change the line which is one quanta
                try dbg_out.dbg_line.append(@intCast(u8, @divExact(d_pc_p9, quant) + 128) - quant);
                if (dbg_out.pcop_change_index.*) |pci|
                    dbg_out.dbg_line.items[pci] += 1;
                dbg_out.pcop_change_index.* = @intCast(u32, dbg_out.dbg_line.items.len - 1);
            } else if (d_pc_p9 == 0) {
                // we don't need to do anything, because adding the quant does it for us
            } else unreachable;
            if (dbg_out.start_line.* == null)
                dbg_out.start_line.* = emit.prev_di_line;
            dbg_out.end_line.* = line;
            // only do this if the pc changed
            emit.prev_di_line = line;
            emit.prev_di_column = column;
            emit.prev_di_pc = emit.code.items.len;
        },
        .none => {},
    }
}

fn mirDbgPrologueEnd(emit: *Emit, inst: Mir.Inst.Index) InnerError!void {
    const tag = emit.mir.instructions.items(.tag)[inst];
    assert(tag == .dbg_prologue_end);
    switch (emit.debug_output) {
        .dwarf => |dbg_out| {
            try dbg_out.dbg_line.append(DW.LNS.set_prologue_end);
            try emit.dbgAdvancePCAndLine(emit.prev_di_line, emit.prev_di_column);
        },
        .plan9 => {},
        .none => {},
    }
}

fn mirDbgEpilogueBegin(emit: *Emit, inst: Mir.Inst.Index) InnerError!void {
    const tag = emit.mir.instructions.items(.tag)[inst];
    assert(tag == .dbg_epilogue_begin);
    switch (emit.debug_output) {
        .dwarf => |dbg_out| {
            try dbg_out.dbg_line.append(DW.LNS.set_epilogue_begin);
            try emit.dbgAdvancePCAndLine(emit.prev_di_line, emit.prev_di_column);
        },
        .plan9 => {},
        .none => {},
    }
}

fn mirArgDbgInfo(emit: *Emit, inst: Mir.Inst.Index) InnerError!void {
    const tag = emit.mir.instructions.items(.tag)[inst];
    assert(tag == .arg_dbg_info);
    const payload = emit.mir.instructions.items(.data)[inst].payload;
    const arg_dbg_info = emit.mir.extraData(Mir.ArgDbgInfo, payload).data;
    const mcv = emit.mir.function.args[arg_dbg_info.arg_index];
    try emit.genArgDbgInfo(arg_dbg_info.air_inst, mcv);
}

fn genArgDbgInfo(emit: *Emit, inst: Air.Inst.Index, mcv: MCValue) !void {
    const ty_str = emit.mir.function.air.instructions.items(.data)[inst].ty_str;
    const zir = &emit.mir.function.mod_fn.owner_decl.getFileScope().zir;
    const name = zir.nullTerminatedString(ty_str.str);
    const name_with_null = name.ptr[0 .. name.len + 1];
    const ty = emit.mir.function.air.getRefType(ty_str.ty);

    switch (mcv) {
        .register => |reg| {
            switch (emit.debug_output) {
                .dwarf => |dbg_out| {
                    try dbg_out.dbg_info.ensureUnusedCapacity(3);
                    dbg_out.dbg_info.appendAssumeCapacity(link.File.Elf.abbrev_parameter);
                    dbg_out.dbg_info.appendSliceAssumeCapacity(&[2]u8{ // DW.AT.location, DW.FORM.exprloc
                        1, // ULEB128 dwarf expression length
                        reg.dwarfLocOp(),
                    });
                    try dbg_out.dbg_info.ensureUnusedCapacity(5 + name_with_null.len);
                    try emit.addDbgInfoTypeReloc(ty); // DW.AT.type,  DW.FORM.ref4
                    dbg_out.dbg_info.appendSliceAssumeCapacity(name_with_null); // DW.AT.name, DW.FORM.string
                },
                .plan9 => {},
                .none => {},
            }
        },
        .stack_offset => {
            switch (emit.debug_output) {
                .dwarf => {},
                .plan9 => {},
                .none => {},
            }
        },
        else => {},
    }
}

/// Adds a Type to the .debug_info at the current position. The bytes will be populated later,
/// after codegen for this symbol is done.
fn addDbgInfoTypeReloc(emit: *Emit, ty: Type) !void {
    switch (emit.debug_output) {
        .dwarf => |dbg_out| {
            assert(ty.hasCodeGenBits());
            const index = dbg_out.dbg_info.items.len;
            try dbg_out.dbg_info.resize(index + 4); // DW.AT.type,  DW.FORM.ref4

            const gop = try dbg_out.dbg_info_type_relocs.getOrPut(emit.bin_file.allocator, ty);
            if (!gop.found_existing) {
                gop.value_ptr.* = .{
                    .off = undefined,
                    .relocs = .{},
                };
            }
            try gop.value_ptr.relocs.append(emit.bin_file.allocator, @intCast(u32, index));
        },
        .plan9 => {},
        .none => {},
    }
}

fn expectEqualHexStrings(expected: []const u8, given: []const u8, assembly: []const u8) !void {
    assert(expected.len > 0);
    if (mem.eql(u8, expected, given)) return;
    const expected_fmt = try std.fmt.allocPrint(testing.allocator, "{x}", .{std.fmt.fmtSliceHexLower(expected)});
    defer testing.allocator.free(expected_fmt);
    const given_fmt = try std.fmt.allocPrint(testing.allocator, "{x}", .{std.fmt.fmtSliceHexLower(given)});
    defer testing.allocator.free(given_fmt);
    const idx = mem.indexOfDiff(u8, expected_fmt, given_fmt).?;
    var padding = try testing.allocator.alloc(u8, idx + 5);
    defer testing.allocator.free(padding);
    mem.set(u8, padding, ' ');
    std.debug.print("\nASM: {s}\nEXP: {s}\nGIV: {s}\n{s}^ -- first differing byte\n", .{
        assembly,
        expected_fmt,
        given_fmt,
        padding,
    });
    return error.TestFailed;
}

const TestEmitCode = struct {
    buf: std.ArrayList(u8),
    next: usize = 0,

    fn init() TestEmitCode {
        return .{
            .buf = std.ArrayList(u8).init(testing.allocator),
        };
    }

    fn deinit(emit: *TestEmitCode) void {
        emit.buf.deinit();
        emit.next = undefined;
    }

    fn buffer(emit: *TestEmitCode) *std.ArrayList(u8) {
        emit.next = emit.buf.items.len;
        return &emit.buf;
    }

    fn emitted(emit: TestEmitCode) []const u8 {
        return emit.buf.items[emit.next..];
    }
};

test "lower MI encoding" {
    var code = TestEmitCode.init();
    defer code.deinit();
    try lowerToMiEnc(.mov, RegisterOrMemory.reg(.rax), 0x10, code.buffer());
    try expectEqualHexStrings("\x48\xc7\xc0\x10\x00\x00\x00", code.emitted(), "mov rax, 0x10");
    try lowerToMiEnc(.mov, RegisterOrMemory.mem(.r11, 0), 0x10, code.buffer());
    try expectEqualHexStrings("\x41\xc7\x03\x10\x00\x00\x00", code.emitted(), "mov dword ptr [r11 + 0], 0x10");
    try lowerToMiEnc(.add, RegisterOrMemory.mem(.rdx, -8), 0x10, code.buffer());
    try expectEqualHexStrings("\x81\x42\xF8\x10\x00\x00\x00", code.emitted(), "add dword ptr [rdx - 8], 0x10");
    try lowerToMiEnc(.sub, RegisterOrMemory.mem(.r11, 0x10000000), 0x10, code.buffer());
    try expectEqualHexStrings(
        "\x41\x81\xab\x00\x00\x00\x10\x10\x00\x00\x00",
        code.emitted(),
        "sub dword ptr [r11 + 0x10000000], 0x10",
    );
    try lowerToMiEnc(.@"and", RegisterOrMemory.mem(null, 0x10000000), 0x10, code.buffer());
    try expectEqualHexStrings(
        "\x81\x24\x25\x00\x00\x00\x10\x10\x00\x00\x00",
        code.emitted(),
        "and dword ptr [ds:0x10000000], 0x10",
    );
    try lowerToMiEnc(.@"and", RegisterOrMemory.mem(.r12, 0x10000000), 0x10, code.buffer());
    try expectEqualHexStrings(
        "\x41\x81\xA4\x24\x00\x00\x00\x10\x10\x00\x00\x00",
        code.emitted(),
        "and dword ptr [r12 + 0x10000000], 0x10",
    );
    try lowerToMiEnc(.mov, RegisterOrMemory.rip(0x10), 0x10, code.buffer());
    try expectEqualHexStrings(
        "\xC7\x05\x10\x00\x00\x00\x10\x00\x00\x00",
        code.emitted(),
        "mov [rip + 0x10], 0x10",
    );
}

test "lower RM encoding" {
    var code = TestEmitCode.init();
    defer code.deinit();
    try lowerToRmEnc(.mov, .rax, RegisterOrMemory.reg(.rbx), code.buffer());
    try expectEqualHexStrings("\x48\x8b\xc3", code.emitted(), "mov rax, rbx");
    try lowerToRmEnc(.mov, .rax, RegisterOrMemory.mem(.r11, 0), code.buffer());
    try expectEqualHexStrings("\x49\x8b\x03", code.emitted(), "mov rax, qword ptr [r11 + 0]");
    try lowerToRmEnc(.add, .r11, RegisterOrMemory.mem(null, 0x10000000), code.buffer());
    try expectEqualHexStrings(
        "\x4C\x03\x1C\x25\x00\x00\x00\x10",
        code.emitted(),
        "add r11, qword ptr [ds:0x10000000]",
    );
    try lowerToRmEnc(.add, .r12b, RegisterOrMemory.mem(null, 0x10000000), code.buffer());
    try expectEqualHexStrings(
        "\x44\x02\x24\x25\x00\x00\x00\x10",
        code.emitted(),
        "add r11b, byte ptr [ds:0x10000000]",
    );
    try lowerToRmEnc(.sub, .r11, RegisterOrMemory.mem(.r13, 0x10000000), code.buffer());
    try expectEqualHexStrings(
        "\x4D\x2B\x9D\x00\x00\x00\x10",
        code.emitted(),
        "sub r11, qword ptr [r13 + 0x10000000]",
    );
    try lowerToRmEnc(.sub, .r11, RegisterOrMemory.mem(.r12, 0x10000000), code.buffer());
    try expectEqualHexStrings(
        "\x4D\x2B\x9C\x24\x00\x00\x00\x10",
        code.emitted(),
        "sub r11, qword ptr [r12 + 0x10000000]",
    );
    try lowerToRmEnc(.mov, .rax, RegisterOrMemory.mem(.rbp, -4), code.buffer());
    try expectEqualHexStrings("\x48\x8B\x45\xFC", code.emitted(), "mov rax, qword ptr [rbp - 4]");
    try lowerToRmEnc(.lea, .rax, RegisterOrMemory.rip(0x10), code.buffer());
    try expectEqualHexStrings("\x48\x8D\x05\x10\x00\x00\x00", code.emitted(), "lea rax, [rip + 0x10]");
}

test "lower MR encoding" {
    var code = TestEmitCode.init();
    defer code.deinit();
    try lowerToMrEnc(.mov, RegisterOrMemory.reg(.rax), .rbx, code.buffer());
    try expectEqualHexStrings("\x48\x89\xd8", code.emitted(), "mov rax, rbx");
    try lowerToMrEnc(.mov, RegisterOrMemory.mem(.rbp, -4), .r11, code.buffer());
    try expectEqualHexStrings("\x4c\x89\x5d\xfc", code.emitted(), "mov qword ptr [rbp - 4], r11");
    try lowerToMrEnc(.add, RegisterOrMemory.mem(null, 0x10000000), .r12b, code.buffer());
    try expectEqualHexStrings(
        "\x44\x00\x24\x25\x00\x00\x00\x10",
        code.emitted(),
        "add byte ptr [ds:0x10000000], r12b",
    );
    try lowerToMrEnc(.add, RegisterOrMemory.mem(null, 0x10000000), .r12d, code.buffer());
    try expectEqualHexStrings(
        "\x44\x01\x24\x25\x00\x00\x00\x10",
        code.emitted(),
        "add dword ptr [ds:0x10000000], r12d",
    );
    try lowerToMrEnc(.sub, RegisterOrMemory.mem(.r11, 0x10000000), .r12, code.buffer());
    try expectEqualHexStrings(
        "\x4D\x29\xA3\x00\x00\x00\x10",
        code.emitted(),
        "sub qword ptr [r11 + 0x10000000], r12",
    );
    try lowerToMrEnc(.mov, RegisterOrMemory.rip(0x10), .r12, code.buffer());
    try expectEqualHexStrings("\x4C\x89\x25\x10\x00\x00\x00", code.emitted(), "mov qword ptr [rip + 0x10], r12");
}

test "lower OI encoding" {
    var code = TestEmitCode.init();
    defer code.deinit();
    try lowerToOiEnc(.mov, .rax, 0x1000000000000000, code.buffer());
    try expectEqualHexStrings(
        "\x48\xB8\x00\x00\x00\x00\x00\x00\x00\x10",
        code.emitted(),
        "movabs rax, 0x1000000000000000",
    );
    try lowerToOiEnc(.mov, .r11, 0x1000000000000000, code.buffer());
    try expectEqualHexStrings(
        "\x49\xBB\x00\x00\x00\x00\x00\x00\x00\x10",
        code.emitted(),
        "movabs r11, 0x1000000000000000",
    );
    try lowerToOiEnc(.mov, .r11d, 0x10000000, code.buffer());
    try expectEqualHexStrings("\x41\xBB\x00\x00\x00\x10", code.emitted(), "mov r11d, 0x10000000");
    try lowerToOiEnc(.mov, .r11w, 0x1000, code.buffer());
    try expectEqualHexStrings("\x66\x41\xBB\x00\x10", code.emitted(), "mov r11w, 0x1000");
    try lowerToOiEnc(.mov, .r11b, 0x10, code.buffer());
    try expectEqualHexStrings("\x41\xB3\x10", code.emitted(), "mov r11b, 0x10");
}

test "lower FD/TD encoding" {
    var code = TestEmitCode.init();
    defer code.deinit();
    try lowerToFdEnc(.mov, .rax, 0x1000000000000000, code.buffer());
    try expectEqualHexStrings(
        "\x48\xa1\x00\x00\x00\x00\x00\x00\x00\x10",
        code.emitted(),
        "mov rax, ds:0x1000000000000000",
    );
    try lowerToFdEnc(.mov, .eax, 0x10000000, code.buffer());
    try expectEqualHexStrings("\xa1\x00\x00\x00\x10", code.emitted(), "mov eax, ds:0x10000000");
    try lowerToFdEnc(.mov, .ax, 0x1000, code.buffer());
    try expectEqualHexStrings("\x66\xa1\x00\x10", code.emitted(), "mov ax, ds:0x1000");
    try lowerToFdEnc(.mov, .al, 0x10, code.buffer());
    try expectEqualHexStrings("\xa0\x10", code.emitted(), "mov al, ds:0x10");
}

test "lower M encoding" {
    var code = TestEmitCode.init();
    defer code.deinit();
    try lowerToMEnc(.jmp_near, RegisterOrMemory.reg(.r12), code.buffer());
    try expectEqualHexStrings("\x41\xFF\xE4", code.emitted(), "jmp r12");
    try lowerToMEnc(.jmp_near, RegisterOrMemory.mem(.r12, 0), code.buffer());
    try expectEqualHexStrings("\x41\xFF\x24\x24", code.emitted(), "jmp qword ptr [r12]");
    try lowerToMEnc(.jmp_near, RegisterOrMemory.mem(.r12, 0x10), code.buffer());
    try expectEqualHexStrings("\x41\xFF\x64\x24\x10", code.emitted(), "jmp qword ptr [r12 + 0x10]");
    try lowerToMEnc(.jmp_near, RegisterOrMemory.mem(.r12, 0x1000), code.buffer());
    try expectEqualHexStrings(
        "\x41\xFF\xA4\x24\x00\x10\x00\x00",
        code.emitted(),
        "jmp qword ptr [r12 + 0x1000]",
    );
    try lowerToMEnc(.jmp_near, RegisterOrMemory.rip(0x10), code.buffer());
    try expectEqualHexStrings("\xFF\x25\x10\x00\x00\x00", code.emitted(), "jmp qword ptr [rip + 0x10]");
    try lowerToMEnc(.jmp_near, RegisterOrMemory.mem(null, 0x10), code.buffer());
    try expectEqualHexStrings("\xFF\x24\x25\x10\x00\x00\x00", code.emitted(), "jmp qword ptr [ds:0x10]");
}

test "lower O encoding" {
    var code = TestEmitCode.init();
    defer code.deinit();
    try lowerToOEnc(.pop, .r12, code.buffer());
    try expectEqualHexStrings("\x41\x5c", code.emitted(), "pop r12");
    try lowerToOEnc(.push, .r12w, code.buffer());
    try expectEqualHexStrings("\x66\x41\x54", code.emitted(), "push r12w");
}
