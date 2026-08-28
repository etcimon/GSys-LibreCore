// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! RV64 instruction representation and decoder.
//!
//! Q3 starts with the base integer instruction set. The decoder is table-driven over the
//! opcode / funct3 / funct7 / funct2 fields rather than a wall of `match` arms, because
//! that is the form that is auditable against the spec and that a future JIT can consume
//! directly.

/// An instruction after decoding.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[allow(missing_docs)]
pub enum Insn {
    /// Illegal / unimplemented instruction.
    Illegal(u32),

    /// AI-island queue: enqueue a descriptor pointer from `rs1`, write ticket to `rd`.
    AiEnq {
        rd: u8,
        rs1: u8,
    },
    /// AI-island queue: poll the ticket in `rs1`, write status to `rd`.
    AiPoll {
        rd: u8,
        rs1: u8,
    },
    /// AI-island queue: fence until outstanding descriptors complete.
    AiQfence,

    // RV64I base
    Lui {
        rd: u8,
        imm: i64,
    },
    Auipc {
        rd: u8,
        imm: i64,
    },
    Jal {
        rd: u8,
        imm: i64,
    },
    Jalr {
        rd: u8,
        rs1: u8,
        imm: i64,
    },
    Beq {
        rs1: u8,
        rs2: u8,
        imm: i64,
    },
    Bne {
        rs1: u8,
        rs2: u8,
        imm: i64,
    },
    Blt {
        rs1: u8,
        rs2: u8,
        imm: i64,
    },
    Bge {
        rs1: u8,
        rs2: u8,
        imm: i64,
    },
    Bltu {
        rs1: u8,
        rs2: u8,
        imm: i64,
    },
    Bgeu {
        rs1: u8,
        rs2: u8,
        imm: i64,
    },
    Lb {
        rd: u8,
        rs1: u8,
        imm: i64,
    },
    Lh {
        rd: u8,
        rs1: u8,
        imm: i64,
    },
    Lw {
        rd: u8,
        rs1: u8,
        imm: i64,
    },
    Lbu {
        rd: u8,
        rs1: u8,
        imm: i64,
    },
    Lhu {
        rd: u8,
        rs1: u8,
        imm: i64,
    },
    Lwu {
        rd: u8,
        rs1: u8,
        imm: i64,
    },
    Ld {
        rd: u8,
        rs1: u8,
        imm: i64,
    },
    Sb {
        rs1: u8,
        rs2: u8,
        imm: i64,
    },
    Sh {
        rs1: u8,
        rs2: u8,
        imm: i64,
    },
    Sw {
        rs1: u8,
        rs2: u8,
        imm: i64,
    },
    Sd {
        rs1: u8,
        rs2: u8,
        imm: i64,
    },
    Addi {
        rd: u8,
        rs1: u8,
        imm: i64,
    },
    Slti {
        rd: u8,
        rs1: u8,
        imm: i64,
    },
    Sltiu {
        rd: u8,
        rs1: u8,
        imm: i64,
    },
    Xori {
        rd: u8,
        rs1: u8,
        imm: i64,
    },
    Ori {
        rd: u8,
        rs1: u8,
        imm: i64,
    },
    Andi {
        rd: u8,
        rs1: u8,
        imm: i64,
    },
    Slli {
        rd: u8,
        rs1: u8,
        shamt: u8,
    },
    Srli {
        rd: u8,
        rs1: u8,
        shamt: u8,
    },
    Srai {
        rd: u8,
        rs1: u8,
        shamt: u8,
    },
    Addiw {
        rd: u8,
        rs1: u8,
        imm: i32,
    },
    Slliw {
        rd: u8,
        rs1: u8,
        shamt: u8,
    },
    Srliw {
        rd: u8,
        rs1: u8,
        shamt: u8,
    },
    Sraiw {
        rd: u8,
        rs1: u8,
        shamt: u8,
    },
    Add {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Sub {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Sll {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Slt {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Sltu {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Xor {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Srl {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Sra {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Or {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    And {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Addw {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Subw {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Sllw {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Srlw {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Sraw {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },

    // Zicsr
    Csrrw {
        rd: u8,
        rs1: u8,
        csr: u16,
    },
    Csrrs {
        rd: u8,
        rs1: u8,
        csr: u16,
    },
    Csrrc {
        rd: u8,
        rs1: u8,
        csr: u16,
    },
    Csrrwi {
        rd: u8,
        uimm: u8,
        csr: u16,
    },
    Csrrsi {
        rd: u8,
        uimm: u8,
        csr: u16,
    },
    Csrrci {
        rd: u8,
        uimm: u8,
        csr: u16,
    },

    // Zifencei (currently a no-op here)
    Fence,
    FenceI,
    Ecall,
    Ebreak,
    Mret,
    Sret,
    Wfi,

    // Zicbom / Zicboz (native model: no cache; cbo.zero writes a 64-byte block)
    CboInval {
        rs1: u8,
    },
    CboFlush {
        rs1: u8,
    },
    CboClean {
        rs1: u8,
    },
    CboZero {
        rs1: u8,
    },

    // RV64M
    Mul {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Mulh {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Mulhsu {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Mulhu {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Div {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Divu {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Rem {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Remu {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Mulw {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Divw {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Divuw {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Remw {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Remuw {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },

    // RV64A (single-hart model; LR/SC reservation is one address per hart)
    LrW {
        rd: u8,
        rs1: u8,
        aqrl: u8,
    },
    LrD {
        rd: u8,
        rs1: u8,
        aqrl: u8,
    },
    ScW {
        rd: u8,
        rs1: u8,
        rs2: u8,
        aqrl: u8,
    },
    ScD {
        rd: u8,
        rs1: u8,
        rs2: u8,
        aqrl: u8,
    },
    AmoaddW {
        rd: u8,
        rs1: u8,
        rs2: u8,
        aqrl: u8,
    },
    AmoswapW {
        rd: u8,
        rs1: u8,
        rs2: u8,
        aqrl: u8,
    },
    AmoxorW {
        rd: u8,
        rs1: u8,
        rs2: u8,
        aqrl: u8,
    },
    AmoorW {
        rd: u8,
        rs1: u8,
        rs2: u8,
        aqrl: u8,
    },
    AmoandW {
        rd: u8,
        rs1: u8,
        rs2: u8,
        aqrl: u8,
    },
    AmominW {
        rd: u8,
        rs1: u8,
        rs2: u8,
        aqrl: u8,
    },
    AmomaxW {
        rd: u8,
        rs1: u8,
        rs2: u8,
        aqrl: u8,
    },
    AmominuW {
        rd: u8,
        rs1: u8,
        rs2: u8,
        aqrl: u8,
    },
    AmomaxuW {
        rd: u8,
        rs1: u8,
        rs2: u8,
        aqrl: u8,
    },
    AmoaddD {
        rd: u8,
        rs1: u8,
        rs2: u8,
        aqrl: u8,
    },
    AmoswapD {
        rd: u8,
        rs1: u8,
        rs2: u8,
        aqrl: u8,
    },
    AmoxorD {
        rd: u8,
        rs1: u8,
        rs2: u8,
        aqrl: u8,
    },
    AmoorD {
        rd: u8,
        rs1: u8,
        rs2: u8,
        aqrl: u8,
    },
    AmoandD {
        rd: u8,
        rs1: u8,
        rs2: u8,
        aqrl: u8,
    },
    AmominD {
        rd: u8,
        rs1: u8,
        rs2: u8,
        aqrl: u8,
    },
    AmomaxD {
        rd: u8,
        rs1: u8,
        rs2: u8,
        aqrl: u8,
    },
    AmominuD {
        rd: u8,
        rs1: u8,
        rs2: u8,
        aqrl: u8,
    },
    AmomaxuD {
        rd: u8,
        rs1: u8,
        rs2: u8,
        aqrl: u8,
    },

    // Zacas
    AmocasW {
        rd: u8,
        rs1: u8,
        rs2: u8,
        aqrl: u8,
    },
    AmocasD {
        rd: u8,
        rs1: u8,
        rs2: u8,
        aqrl: u8,
    },

    // Zba (address generation)
    Sh1add {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Sh2add {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Sh3add {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    AddUw {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Sh1addUw {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Sh2addUw {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Sh3addUw {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    SlliUw {
        rd: u8,
        rs1: u8,
        shamt: u8,
    },

    // Zbs (single-bit)
    Bclr {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Bext {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Binv {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Bset {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Bclri {
        rd: u8,
        rs1: u8,
        shamt: u8,
    },
    Bexti {
        rd: u8,
        rs1: u8,
        shamt: u8,
    },
    Binvi {
        rd: u8,
        rs1: u8,
        shamt: u8,
    },
    Bseti {
        rd: u8,
        rs1: u8,
        shamt: u8,
    },

    // Zbb (basic bit-manipulation)
    Andn {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Orn {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Xnor {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Clz {
        rd: u8,
        rs1: u8,
    },
    Ctz {
        rd: u8,
        rs1: u8,
    },
    Cpop {
        rd: u8,
        rs1: u8,
    },
    Clzw {
        rd: u8,
        rs1: u8,
    },
    Ctzw {
        rd: u8,
        rs1: u8,
    },
    Cpopw {
        rd: u8,
        rs1: u8,
    },
    Min {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Minu {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Max {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Maxu {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Rol {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Ror {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Rori {
        rd: u8,
        rs1: u8,
        shamt: u8,
    },
    Rev8 {
        rd: u8,
        rs1: u8,
    },
    OrcB {
        rd: u8,
        rs1: u8,
    },
    SextB {
        rd: u8,
        rs1: u8,
    },
    SextH {
        rd: u8,
        rs1: u8,
    },
    ZextH {
        rd: u8,
        rs1: u8,
    },
    Rolw {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Rorw {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    Roriw {
        rd: u8,
        rs1: u8,
        shamt: u8,
    },

    // F (single-precision floating-point)
    Flw {
        rd: u8,
        rs1: u8,
        imm: i32,
    },
    Fsw {
        rs1: u8,
        rs2: u8,
        imm: i32,
    },
    FmaddS {
        rd: u8,
        rs1: u8,
        rs2: u8,
        rs3: u8,
        rm: u8,
    },
    FmsubS {
        rd: u8,
        rs1: u8,
        rs2: u8,
        rs3: u8,
        rm: u8,
    },
    FnmsubS {
        rd: u8,
        rs1: u8,
        rs2: u8,
        rs3: u8,
        rm: u8,
    },
    FnmaddS {
        rd: u8,
        rs1: u8,
        rs2: u8,
        rs3: u8,
        rm: u8,
    },
    FaddS {
        rd: u8,
        rs1: u8,
        rs2: u8,
        rm: u8,
    },
    FsubS {
        rd: u8,
        rs1: u8,
        rs2: u8,
        rm: u8,
    },
    FmulS {
        rd: u8,
        rs1: u8,
        rs2: u8,
        rm: u8,
    },
    FdivS {
        rd: u8,
        rs1: u8,
        rs2: u8,
        rm: u8,
    },
    FsqrtS {
        rd: u8,
        rs1: u8,
        rm: u8,
    },
    FsgnjS {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    FsgnjnS {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    FsgnjxS {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    FminS {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    FmaxS {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    FcvtWS {
        rd: u8,
        rs1: u8,
        rm: u8,
    },
    FcvtWuS {
        rd: u8,
        rs1: u8,
        rm: u8,
    },
    FcvtLS {
        rd: u8,
        rs1: u8,
        rm: u8,
    },
    FcvtLuS {
        rd: u8,
        rs1: u8,
        rm: u8,
    },
    FmvXW {
        rd: u8,
        rs1: u8,
    },
    FeqS {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    FltS {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    FleS {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    FclassS {
        rd: u8,
        rs1: u8,
    },
    FcvtSW {
        rd: u8,
        rs1: u8,
        rm: u8,
    },
    FcvtSWu {
        rd: u8,
        rs1: u8,
        rm: u8,
    },
    FcvtSL {
        rd: u8,
        rs1: u8,
        rm: u8,
    },
    FcvtSLu {
        rd: u8,
        rs1: u8,
        rm: u8,
    },
    FmvWX {
        rd: u8,
        rs1: u8,
    },

    // D (double-precision floating-point)
    Fld {
        rd: u8,
        rs1: u8,
        imm: i32,
    },
    Fsd {
        rs1: u8,
        rs2: u8,
        imm: i32,
    },
    FmaddD {
        rd: u8,
        rs1: u8,
        rs2: u8,
        rs3: u8,
        rm: u8,
    },
    FmsubD {
        rd: u8,
        rs1: u8,
        rs2: u8,
        rs3: u8,
        rm: u8,
    },
    FnmsubD {
        rd: u8,
        rs1: u8,
        rs2: u8,
        rs3: u8,
        rm: u8,
    },
    FnmaddD {
        rd: u8,
        rs1: u8,
        rs2: u8,
        rs3: u8,
        rm: u8,
    },
    FaddD {
        rd: u8,
        rs1: u8,
        rs2: u8,
        rm: u8,
    },
    FsubD {
        rd: u8,
        rs1: u8,
        rs2: u8,
        rm: u8,
    },
    FmulD {
        rd: u8,
        rs1: u8,
        rs2: u8,
        rm: u8,
    },
    FdivD {
        rd: u8,
        rs1: u8,
        rs2: u8,
        rm: u8,
    },
    FsqrtD {
        rd: u8,
        rs1: u8,
        rm: u8,
    },
    FsgnjD {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    FsgnjnD {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    FsgnjxD {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    FminD {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    FmaxD {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    FcvtSD {
        rd: u8,
        rs1: u8,
        rm: u8,
    },
    FcvtDS {
        rd: u8,
        rs1: u8,
        rm: u8,
    },
    FcvtWD {
        rd: u8,
        rs1: u8,
        rm: u8,
    },
    FcvtWuD {
        rd: u8,
        rs1: u8,
        rm: u8,
    },
    FcvtLD {
        rd: u8,
        rs1: u8,
        rm: u8,
    },
    FcvtLuD {
        rd: u8,
        rs1: u8,
        rm: u8,
    },
    FmvXD {
        rd: u8,
        rs1: u8,
    },
    FeqD {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    FltD {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    FleD {
        rd: u8,
        rs1: u8,
        rs2: u8,
    },
    FclassD {
        rd: u8,
        rs1: u8,
    },
    FcvtDW {
        rd: u8,
        rs1: u8,
        rm: u8,
    },
    FcvtDWu {
        rd: u8,
        rs1: u8,
        rm: u8,
    },
    FcvtDL {
        rd: u8,
        rs1: u8,
        rm: u8,
    },
    FcvtDLu {
        rd: u8,
        rs1: u8,
        rm: u8,
    },
    FmvDX {
        rd: u8,
        rs1: u8,
    },
}

fn u8_field(w: u32, hi: u32, lo: u32) -> u8 {
    ((w >> lo) & ((1u32 << (hi - lo + 1)) - 1)) as u8
}

fn u16_field(w: u32, hi: u32, lo: u32) -> u16 {
    ((w >> lo) & ((1u32 << (hi - lo + 1)) - 1)) as u16
}

fn sign_extend_12(v: u32) -> i64 {
    let v = v & 0x0fff;
    if v & 0x0800 != 0 {
        (v as i64) - 0x1000
    } else {
        v as i64
    }
}

fn sign_extend_13(v: u32) -> i64 {
    let v = v & 0x1fff;
    if v & 0x1000 != 0 {
        (v as i64) - 0x2000
    } else {
        v as i64
    }
}

fn sign_extend_21(v: u32) -> i64 {
    let v = v & 0x001f_ffff;
    if v & 0x0010_0000 != 0 {
        (v as i64) - 0x0020_0000
    } else {
        v as i64
    }
}

fn i_imm(w: u32) -> i64 {
    sign_extend_12(w >> 20)
}

fn s_imm(w: u32) -> i64 {
    let hi = (w >> 25) & 0x7f; // imm[11:5]
    let lo = (w >> 7) & 0x1f; // imm[4:0]
    let imm = (hi << 5) | lo;
    sign_extend_12(imm)
}

fn b_imm(w: u32) -> i64 {
    let bit12 = (w >> 31) & 1;
    let bits10_5 = (w >> 25) & 0x3f;
    let bit4_1 = (w >> 8) & 0x0f;
    let bit11 = (w >> 7) & 1;
    let imm = (bit12 << 12) | (bit11 << 11) | (bits10_5 << 5) | (bit4_1 << 1);
    sign_extend_13(imm)
}

fn u_imm(w: u32) -> i64 {
    (w & 0xffff_f000) as i32 as i64
}

fn j_imm(w: u32) -> i64 {
    let bit20 = (w >> 31) & 1;
    let bits10_1 = (w >> 21) & 0x3ff;
    let bit11 = (w >> 20) & 1;
    let bits19_12 = (w >> 12) & 0xff;
    let imm = (bit20 << 20) | (bits19_12 << 12) | (bit11 << 11) | (bits10_1 << 1);
    sign_extend_21(imm)
}

/// True for a valid static/dynamic rounding-mode field in an instruction.
fn rm_legal(rm: u8) -> bool {
    rm <= 0x4 || rm == 0x7
}

fn decode_fp(w: u32, xlen: u32) -> Insn {
    let rd = u8_field(w, 11, 7);
    let rs1 = u8_field(w, 19, 15);
    let rs2 = u8_field(w, 24, 20);
    let funct3 = u8_field(w, 14, 12);
    let funct7 = u8_field(w, 31, 25);

    match funct7 {
        // FADD.S/D, FSUB.S/D, FMUL.S/D, FDIV.S/D
        0x00 | 0x01 | 0x04 | 0x05 | 0x08 | 0x09 | 0x0c | 0x0d if rm_legal(funct3) => match funct7 {
            0x00 => Insn::FaddS {
                rd,
                rs1,
                rs2,
                rm: funct3,
            },
            0x01 => Insn::FaddD {
                rd,
                rs1,
                rs2,
                rm: funct3,
            },
            0x04 => Insn::FsubS {
                rd,
                rs1,
                rs2,
                rm: funct3,
            },
            0x05 => Insn::FsubD {
                rd,
                rs1,
                rs2,
                rm: funct3,
            },
            0x08 => Insn::FmulS {
                rd,
                rs1,
                rs2,
                rm: funct3,
            },
            0x09 => Insn::FmulD {
                rd,
                rs1,
                rs2,
                rm: funct3,
            },
            0x0c => Insn::FdivS {
                rd,
                rs1,
                rs2,
                rm: funct3,
            },
            0x0d => Insn::FdivD {
                rd,
                rs1,
                rs2,
                rm: funct3,
            },
            _ => unreachable!(),
        },
        0x2c | 0x2d if rm_legal(funct3) && rs2 == 0x0 => match funct7 {
            0x2c => Insn::FsqrtS {
                rd,
                rs1,
                rm: funct3,
            },
            0x2d => Insn::FsqrtD {
                rd,
                rs1,
                rm: funct3,
            },
            _ => unreachable!(),
        },
        // FSGNJ/N/X.S/D
        0x10 | 0x11 => match (funct3, funct7) {
            (0x0, 0x10) => Insn::FsgnjS { rd, rs1, rs2 },
            (0x0, 0x11) => Insn::FsgnjD { rd, rs1, rs2 },
            (0x1, 0x10) => Insn::FsgnjnS { rd, rs1, rs2 },
            (0x1, 0x11) => Insn::FsgnjnD { rd, rs1, rs2 },
            (0x2, 0x10) => Insn::FsgnjxS { rd, rs1, rs2 },
            (0x2, 0x11) => Insn::FsgnjxD { rd, rs1, rs2 },
            _ => Insn::Illegal(w),
        },
        // FMIN/FMAX.S/D
        0x14 | 0x15 => match (funct3, funct7) {
            (0x0, 0x14) => Insn::FminS { rd, rs1, rs2 },
            (0x0, 0x15) => Insn::FminD { rd, rs1, rs2 },
            (0x1, 0x14) => Insn::FmaxS { rd, rs1, rs2 },
            (0x1, 0x15) => Insn::FmaxD { rd, rs1, rs2 },
            _ => Insn::Illegal(w),
        },
        // FCVT.{W,WU,L,LU}.S/D (floating-point to integer)
        0x30 | 0x31 => {
            if !rm_legal(funct3) {
                return Insn::Illegal(w);
            }
            let is_d = funct7 == 0x31;
            match rs2 {
                0x0 => {
                    if is_d {
                        Insn::FcvtWD {
                            rd,
                            rs1,
                            rm: funct3,
                        }
                    } else {
                        Insn::FcvtWS {
                            rd,
                            rs1,
                            rm: funct3,
                        }
                    }
                }
                0x1 => {
                    if is_d {
                        Insn::FcvtWuD {
                            rd,
                            rs1,
                            rm: funct3,
                        }
                    } else {
                        Insn::FcvtWuS {
                            rd,
                            rs1,
                            rm: funct3,
                        }
                    }
                }
                0x2 if xlen == 64 => {
                    if is_d {
                        Insn::FcvtLD {
                            rd,
                            rs1,
                            rm: funct3,
                        }
                    } else {
                        Insn::FcvtLS {
                            rd,
                            rs1,
                            rm: funct3,
                        }
                    }
                }
                0x3 if xlen == 64 => {
                    if is_d {
                        Insn::FcvtLuD {
                            rd,
                            rs1,
                            rm: funct3,
                        }
                    } else {
                        Insn::FcvtLuS {
                            rd,
                            rs1,
                            rm: funct3,
                        }
                    }
                }
                _ => Insn::Illegal(w),
            }
        }
        // FCVT.S.D / FCVT.D.S
        0x20 | 0x21 => {
            if !rm_legal(funct3) {
                return Insn::Illegal(w);
            }
            match (funct7, rs2) {
                (0x20, 0x1) => Insn::FcvtSD {
                    rd,
                    rs1,
                    rm: funct3,
                },
                (0x21, 0x0) => Insn::FcvtDS {
                    rd,
                    rs1,
                    rm: funct3,
                },
                _ => Insn::Illegal(w),
            }
        }
        // FCVT.S/D.{W,WU,L,LU} (integer to floating-point)
        0x34 | 0x35 => {
            if !rm_legal(funct3) {
                return Insn::Illegal(w);
            }
            let is_d = funct7 == 0x35;
            match rs2 {
                0x0 => {
                    if is_d {
                        Insn::FcvtDW {
                            rd,
                            rs1,
                            rm: funct3,
                        }
                    } else {
                        Insn::FcvtSW {
                            rd,
                            rs1,
                            rm: funct3,
                        }
                    }
                }
                0x1 => {
                    if is_d {
                        Insn::FcvtDWu {
                            rd,
                            rs1,
                            rm: funct3,
                        }
                    } else {
                        Insn::FcvtSWu {
                            rd,
                            rs1,
                            rm: funct3,
                        }
                    }
                }
                0x2 if xlen == 64 => {
                    if is_d {
                        Insn::FcvtDL {
                            rd,
                            rs1,
                            rm: funct3,
                        }
                    } else {
                        Insn::FcvtSL {
                            rd,
                            rs1,
                            rm: funct3,
                        }
                    }
                }
                0x3 if xlen == 64 => {
                    if is_d {
                        Insn::FcvtDLu {
                            rd,
                            rs1,
                            rm: funct3,
                        }
                    } else {
                        Insn::FcvtSLu {
                            rd,
                            rs1,
                            rm: funct3,
                        }
                    }
                }
                _ => Insn::Illegal(w),
            }
        }
        // FEQ/FLT/FLE.S/D
        0x50 | 0x51 => match (funct3, funct7) {
            (0x0, 0x50) => Insn::FleS { rd, rs1, rs2 },
            (0x0, 0x51) => Insn::FleD { rd, rs1, rs2 },
            (0x1, 0x50) => Insn::FltS { rd, rs1, rs2 },
            (0x1, 0x51) => Insn::FltD { rd, rs1, rs2 },
            (0x2, 0x50) => Insn::FeqS { rd, rs1, rs2 },
            (0x2, 0x51) => Insn::FeqD { rd, rs1, rs2 },
            _ => Insn::Illegal(w),
        },
        // FMV.X.W / FCLASS.S / FMV.X.D / FCLASS.D
        0x38 | 0x39 => match (funct3, rs2) {
            (0x0, 0x0) => {
                if funct7 == 0x39 {
                    Insn::FmvXD { rd, rs1 }
                } else {
                    Insn::FmvXW { rd, rs1 }
                }
            }
            (0x1, 0x0) => {
                if funct7 == 0x39 {
                    Insn::FclassD { rd, rs1 }
                } else {
                    Insn::FclassS { rd, rs1 }
                }
            }
            _ => Insn::Illegal(w),
        },
        // FMV.W.X / FMV.D.X
        0x3c | 0x3d if funct3 == 0x0 && rs2 == 0x0 => {
            if funct7 == 0x3d {
                Insn::FmvDX { rd, rs1 }
            } else {
                Insn::FmvWX { rd, rs1 }
            }
        }
        _ => Insn::Illegal(w),
    }
}

fn shamt(w: u32, xlen: u32) -> u8 {
    let mask = if xlen == 64 { 0x3f } else { 0x1f };
    ((w >> 20) & mask) as u8
}

/// Decode one 32-bit or 16-bit (compressed) instruction.
pub fn decode(w: u32, xlen: u32) -> Insn {
    decode_with_ai(w, xlen, None)
}

/// Decode with an optional AI-island instruction set.
pub fn decode_with_ai(w: u32, xlen: u32, ai: Option<&g6q_core::model::AiInstrSet>) -> Insn {
    if w & 0b11 != 0b11 {
        return crate::c::decode_c((w & 0xffff) as u16, xlen);
    }
    if (w >> 2) & 0b111 == 0b111 {
        // 48/64-bit and reserved encodings are not supported.
        return Insn::Illegal(w);
    }

    let opcode = w & 0x7f;
    let rd = u8_field(w, 11, 7);
    let rs1 = u8_field(w, 19, 15);
    let rs2 = u8_field(w, 24, 20);
    let funct3 = u8_field(w, 14, 12);
    let funct7 = u8_field(w, 31, 25);
    let csr = u16_field(w, 31, 20);

    if let Some(ai) = ai {
        if opcode == ai.opcode_custom2 {
            let masked = w & ai.mask_f7f3op;
            if masked == ai.match_enq {
                return Insn::AiEnq { rd, rs1 };
            }
            if masked == ai.match_poll {
                return Insn::AiPoll { rd, rs1 };
            }
            if masked == ai.match_qfence {
                return Insn::AiQfence;
            }
        }
    }

    match opcode {
        0x37 => Insn::Lui { rd, imm: u_imm(w) },
        0x17 => Insn::Auipc { rd, imm: u_imm(w) },
        0x6f => Insn::Jal { rd, imm: j_imm(w) },
        0x67 => match funct3 {
            0x0 => Insn::Jalr {
                rd,
                rs1,
                imm: i_imm(w),
            },
            _ => Insn::Illegal(w),
        },
        0x63 => match funct3 {
            0x0 => Insn::Beq {
                rs1,
                rs2,
                imm: b_imm(w),
            },
            0x1 => Insn::Bne {
                rs1,
                rs2,
                imm: b_imm(w),
            },
            0x4 => Insn::Blt {
                rs1,
                rs2,
                imm: b_imm(w),
            },
            0x5 => Insn::Bge {
                rs1,
                rs2,
                imm: b_imm(w),
            },
            0x6 => Insn::Bltu {
                rs1,
                rs2,
                imm: b_imm(w),
            },
            0x7 => Insn::Bgeu {
                rs1,
                rs2,
                imm: b_imm(w),
            },
            _ => Insn::Illegal(w),
        },
        0x03 => match funct3 {
            0x0 => Insn::Lb {
                rd,
                rs1,
                imm: i_imm(w),
            },
            0x1 => Insn::Lh {
                rd,
                rs1,
                imm: i_imm(w),
            },
            0x2 => Insn::Lw {
                rd,
                rs1,
                imm: i_imm(w),
            },
            0x3 => Insn::Ld {
                rd,
                rs1,
                imm: i_imm(w),
            },
            0x4 => Insn::Lbu {
                rd,
                rs1,
                imm: i_imm(w),
            },
            0x5 => Insn::Lhu {
                rd,
                rs1,
                imm: i_imm(w),
            },
            0x6 => Insn::Lwu {
                rd,
                rs1,
                imm: i_imm(w),
            },
            _ => Insn::Illegal(w),
        },
        0x23 => match funct3 {
            0x0 => Insn::Sb {
                rs1,
                rs2,
                imm: s_imm(w),
            },
            0x1 => Insn::Sh {
                rs1,
                rs2,
                imm: s_imm(w),
            },
            0x2 => Insn::Sw {
                rs1,
                rs2,
                imm: s_imm(w),
            },
            0x3 => Insn::Sd {
                rs1,
                rs2,
                imm: s_imm(w),
            },
            _ => Insn::Illegal(w),
        },
        0x13 => match funct3 {
            0x0 => Insn::Addi {
                rd,
                rs1,
                imm: i_imm(w),
            },
            0x2 => Insn::Slti {
                rd,
                rs1,
                imm: i_imm(w),
            },
            0x3 => Insn::Sltiu {
                rd,
                rs1,
                imm: i_imm(w),
            },
            0x4 => Insn::Xori {
                rd,
                rs1,
                imm: i_imm(w),
            },
            0x6 => Insn::Ori {
                rd,
                rs1,
                imm: i_imm(w),
            },
            0x7 => Insn::Andi {
                rd,
                rs1,
                imm: i_imm(w),
            },
            0x1 => match (w >> 26) & 0x3f {
                0x00 => Insn::Slli {
                    rd,
                    rs1,
                    shamt: shamt(w, xlen),
                },
                0x0a => Insn::Bseti {
                    rd,
                    rs1,
                    shamt: shamt(w, xlen),
                },
                0x12 => Insn::Bclri {
                    rd,
                    rs1,
                    shamt: shamt(w, xlen),
                },
                0x1a => Insn::Binvi {
                    rd,
                    rs1,
                    shamt: shamt(w, xlen),
                },
                0x18 => match (w >> 20) & 0x3f {
                    0x00 => Insn::Clz { rd, rs1 },
                    0x01 => Insn::Ctz { rd, rs1 },
                    0x02 => Insn::Cpop { rd, rs1 },
                    0x04 => Insn::SextB { rd, rs1 },
                    0x05 => Insn::SextH { rd, rs1 },
                    _ => Insn::Illegal(w),
                },
                _ => Insn::Illegal(w),
            },
            0x5 => {
                let imm12 = (w >> 20) & 0xfff;
                match (w >> 26) & 0x3f {
                    0x00 => Insn::Srli {
                        rd,
                        rs1,
                        shamt: shamt(w, xlen),
                    },
                    0x10 => Insn::Srai {
                        rd,
                        rs1,
                        shamt: shamt(w, xlen),
                    },
                    0x12 => Insn::Bexti {
                        rd,
                        rs1,
                        shamt: shamt(w, xlen),
                    },
                    0x18 => Insn::Rori {
                        rd,
                        rs1,
                        shamt: shamt(w, xlen),
                    },
                    _ if imm12 == 0x287 => Insn::OrcB { rd, rs1 },
                    _ if imm12 == (if xlen == 64 { 0x6b8 } else { 0x698 }) => {
                        Insn::Rev8 { rd, rs1 }
                    }
                    _ => Insn::Illegal(w),
                }
            }
            _ => Insn::Illegal(w),
        },
        0x1b => match funct3 {
            0x0 => Insn::Addiw {
                rd,
                rs1,
                imm: i_imm(w) as i32,
            },
            0x1 => match (w >> 26) & 0x3f {
                0x00 if w & (1 << 25) == 0 => Insn::Slliw {
                    rd,
                    rs1,
                    shamt: shamt(w, 32),
                },
                0x02 => Insn::SlliUw {
                    rd,
                    rs1,
                    shamt: shamt(w, 64),
                },
                0x18 => match (w >> 20) & 0x3f {
                    0x00 => Insn::Clzw { rd, rs1 },
                    0x01 => Insn::Ctzw { rd, rs1 },
                    0x02 => Insn::Cpopw { rd, rs1 },
                    _ => Insn::Illegal(w),
                },
                _ => Insn::Illegal(w),
            },
            0x5 => match (w >> 26) & 0x3f {
                0x00 => Insn::Srliw {
                    rd,
                    rs1,
                    shamt: shamt(w, 32),
                },
                0x10 => Insn::Sraiw {
                    rd,
                    rs1,
                    shamt: shamt(w, 32),
                },
                0x18 => Insn::Roriw {
                    rd,
                    rs1,
                    shamt: shamt(w, 32),
                },
                _ => Insn::Illegal(w),
            },
            _ => Insn::Illegal(w),
        },
        0x33 => match funct3 {
            0x0 => match funct7 {
                0x00 => Insn::Add { rd, rs1, rs2 },
                0x20 => Insn::Sub { rd, rs1, rs2 },
                0x01 => Insn::Mul { rd, rs1, rs2 },
                _ => Insn::Illegal(w),
            },
            0x1 => match funct7 {
                0x00 => Insn::Sll { rd, rs1, rs2 },
                0x01 => Insn::Mulh { rd, rs1, rs2 },
                0x14 => Insn::Bset { rd, rs1, rs2 },
                0x24 => Insn::Bclr { rd, rs1, rs2 },
                0x34 => Insn::Binv { rd, rs1, rs2 },
                0x30 => Insn::Rol { rd, rs1, rs2 },
                _ => Insn::Illegal(w),
            },
            0x2 => match funct7 {
                0x00 => Insn::Slt { rd, rs1, rs2 },
                0x01 => Insn::Mulhsu { rd, rs1, rs2 },
                0x10 => Insn::Sh1add { rd, rs1, rs2 },
                _ => Insn::Illegal(w),
            },
            0x3 => match funct7 {
                0x00 => Insn::Sltu { rd, rs1, rs2 },
                0x01 => Insn::Mulhu { rd, rs1, rs2 },
                _ => Insn::Illegal(w),
            },
            0x4 => match funct7 {
                0x00 => Insn::Xor { rd, rs1, rs2 },
                0x01 => Insn::Div { rd, rs1, rs2 },
                0x10 => Insn::Sh2add { rd, rs1, rs2 },
                0x05 => Insn::Min { rd, rs1, rs2 },
                0x20 => Insn::Xnor { rd, rs1, rs2 },
                0x04 if xlen == 32 && rs2 == 0 => Insn::ZextH { rd, rs1 },
                _ => Insn::Illegal(w),
            },
            0x5 => match funct7 {
                0x00 => Insn::Srl { rd, rs1, rs2 },
                0x20 => Insn::Sra { rd, rs1, rs2 },
                0x01 => Insn::Divu { rd, rs1, rs2 },
                0x24 => Insn::Bext { rd, rs1, rs2 },
                0x30 => Insn::Ror { rd, rs1, rs2 },
                0x05 => Insn::Minu { rd, rs1, rs2 },
                _ => Insn::Illegal(w),
            },
            0x6 => match funct7 {
                0x00 => Insn::Or { rd, rs1, rs2 },
                0x01 => Insn::Rem { rd, rs1, rs2 },
                0x10 => Insn::Sh3add { rd, rs1, rs2 },
                0x05 => Insn::Max { rd, rs1, rs2 },
                0x20 => Insn::Orn { rd, rs1, rs2 },
                _ => Insn::Illegal(w),
            },
            0x7 => match funct7 {
                0x00 => Insn::And { rd, rs1, rs2 },
                0x01 => Insn::Remu { rd, rs1, rs2 },
                0x05 => Insn::Maxu { rd, rs1, rs2 },
                0x20 => Insn::Andn { rd, rs1, rs2 },
                _ => Insn::Illegal(w),
            },
            _ => Insn::Illegal(w),
        },
        0x3b => match funct3 {
            0x0 => match funct7 {
                0x00 => Insn::Addw { rd, rs1, rs2 },
                0x20 => Insn::Subw { rd, rs1, rs2 },
                0x01 => Insn::Mulw { rd, rs1, rs2 },
                0x04 => Insn::AddUw { rd, rs1, rs2 },
                _ => Insn::Illegal(w),
            },
            0x1 => match funct7 {
                0x00 => Insn::Sllw { rd, rs1, rs2 },
                0x30 => Insn::Rolw { rd, rs1, rs2 },
                _ => Insn::Illegal(w),
            },
            0x2 => match funct7 {
                0x10 => Insn::Sh1addUw { rd, rs1, rs2 },
                _ => Insn::Illegal(w),
            },
            0x4 => match funct7 {
                0x00 => Insn::Divw { rd, rs1, rs2 },
                0x10 => Insn::Sh2addUw { rd, rs1, rs2 },
                0x04 if rs2 == 0 => Insn::ZextH { rd, rs1 },
                _ => Insn::Illegal(w),
            },
            0x5 => match funct7 {
                0x00 => Insn::Srlw { rd, rs1, rs2 },
                0x20 => Insn::Sraw { rd, rs1, rs2 },
                0x01 => Insn::Divuw { rd, rs1, rs2 },
                0x30 => Insn::Rorw { rd, rs1, rs2 },
                _ => Insn::Illegal(w),
            },
            0x6 => match funct7 {
                0x00 => Insn::Remw { rd, rs1, rs2 },
                0x10 => Insn::Sh3addUw { rd, rs1, rs2 },
                _ => Insn::Illegal(w),
            },
            0x7 => Insn::Remuw { rd, rs1, rs2 },
            _ => Insn::Illegal(w),
        },
        0x2f => {
            let aqrl = u8_field(w, 26, 25);
            let funct5 = u8_field(w, 31, 27);
            match (funct3, funct5) {
                (0x2, 0x02) => Insn::LrW { rd, rs1, aqrl },
                (0x3, 0x02) => Insn::LrD { rd, rs1, aqrl },
                (0x2, 0x03) => Insn::ScW { rd, rs1, rs2, aqrl },
                (0x3, 0x03) => Insn::ScD { rd, rs1, rs2, aqrl },
                (0x2, 0x00) => Insn::AmoaddW { rd, rs1, rs2, aqrl },
                (0x3, 0x00) => Insn::AmoaddD { rd, rs1, rs2, aqrl },
                (0x2, 0x01) => Insn::AmoswapW { rd, rs1, rs2, aqrl },
                (0x3, 0x01) => Insn::AmoswapD { rd, rs1, rs2, aqrl },
                (0x2, 0x04) => Insn::AmoxorW { rd, rs1, rs2, aqrl },
                (0x3, 0x04) => Insn::AmoxorD { rd, rs1, rs2, aqrl },
                (0x2, 0x08) => Insn::AmoandW { rd, rs1, rs2, aqrl },
                (0x3, 0x08) => Insn::AmoandD { rd, rs1, rs2, aqrl },
                (0x2, 0x0c) => Insn::AmoorW { rd, rs1, rs2, aqrl },
                (0x3, 0x0c) => Insn::AmoorD { rd, rs1, rs2, aqrl },
                (0x2, 0x10) => Insn::AmominW { rd, rs1, rs2, aqrl },
                (0x3, 0x10) => Insn::AmominD { rd, rs1, rs2, aqrl },
                (0x2, 0x14) => Insn::AmomaxW { rd, rs1, rs2, aqrl },
                (0x3, 0x14) => Insn::AmomaxD { rd, rs1, rs2, aqrl },
                (0x2, 0x18) => Insn::AmominuW { rd, rs1, rs2, aqrl },
                (0x3, 0x18) => Insn::AmominuD { rd, rs1, rs2, aqrl },
                (0x2, 0x1c) => Insn::AmomaxuW { rd, rs1, rs2, aqrl },
                (0x3, 0x1c) => Insn::AmomaxuD { rd, rs1, rs2, aqrl },
                (0x2, 0x05) => Insn::AmocasW { rd, rs1, rs2, aqrl },
                (0x3, 0x05) => Insn::AmocasD { rd, rs1, rs2, aqrl },
                _ => Insn::Illegal(w),
            }
        }
        0x73 => match funct3 {
            0x0 => match (funct7, rs2) {
                (0x00, 0x00) if rd == 0 => Insn::Ecall,
                (0x00, 0x01) if rd == 0 => Insn::Ebreak,
                (0x00, 0x02) => Insn::FenceI,
                (0x18, 0x02) if rd == 0 && rs1 == 0 => Insn::Mret,
                (0x08, 0x02) if rd == 0 && rs1 == 0 => Insn::Sret,
                (0x10, 0x05) if rd == 0 && rs1 == 0 => Insn::Wfi,
                _ => Insn::Illegal(w),
            },
            0x1 => Insn::Csrrw { rd, rs1, csr },
            0x2 => Insn::Csrrs { rd, rs1, csr },
            0x3 => Insn::Csrrc { rd, rs1, csr },
            0x5 => Insn::Csrrwi { rd, uimm: rs1, csr },
            0x6 => Insn::Csrrsi { rd, uimm: rs1, csr },
            0x7 => Insn::Csrrci { rd, uimm: rs1, csr },
            _ => Insn::Illegal(w),
        },
        0x0f => match funct3 {
            0x0 => Insn::Fence,
            0x2 if rd == 0 => match w >> 20 {
                0x000 => Insn::CboInval { rs1 },
                0x001 => Insn::CboClean { rs1 },
                0x002 => Insn::CboFlush { rs1 },
                0x004 => Insn::CboZero { rs1 },
                _ => Insn::Illegal(w),
            },
            _ => Insn::Illegal(w),
        },
        0x07 => match funct3 {
            0x2 => Insn::Flw {
                rd,
                rs1,
                imm: i_imm(w) as i32,
            },
            0x3 => Insn::Fld {
                rd,
                rs1,
                imm: i_imm(w) as i32,
            },
            _ => Insn::Illegal(w),
        },
        0x27 => match funct3 {
            0x2 => Insn::Fsw {
                rs1,
                rs2,
                imm: s_imm(w) as i32,
            },
            0x3 => Insn::Fsd {
                rs1,
                rs2,
                imm: s_imm(w) as i32,
            },
            _ => Insn::Illegal(w),
        },
        0x43 | 0x47 | 0x4b | 0x4f => {
            let rs3 = u8_field(w, 31, 27);
            let fmt = u8_field(w, 26, 25);
            if fmt > 0x1 || !rm_legal(funct3) {
                // Single- and double-precision (fmt=00/01) only in this pass.
                return Insn::Illegal(w);
            }
            let is_d = fmt == 0x1;
            match opcode {
                0x43 => {
                    if is_d {
                        Insn::FmaddD {
                            rd,
                            rs1,
                            rs2,
                            rs3,
                            rm: funct3,
                        }
                    } else {
                        Insn::FmaddS {
                            rd,
                            rs1,
                            rs2,
                            rs3,
                            rm: funct3,
                        }
                    }
                }
                0x47 => {
                    if is_d {
                        Insn::FmsubD {
                            rd,
                            rs1,
                            rs2,
                            rs3,
                            rm: funct3,
                        }
                    } else {
                        Insn::FmsubS {
                            rd,
                            rs1,
                            rs2,
                            rs3,
                            rm: funct3,
                        }
                    }
                }
                0x4b => {
                    if is_d {
                        Insn::FnmsubD {
                            rd,
                            rs1,
                            rs2,
                            rs3,
                            rm: funct3,
                        }
                    } else {
                        Insn::FnmsubS {
                            rd,
                            rs1,
                            rs2,
                            rs3,
                            rm: funct3,
                        }
                    }
                }
                0x4f => {
                    if is_d {
                        Insn::FnmaddD {
                            rd,
                            rs1,
                            rs2,
                            rs3,
                            rm: funct3,
                        }
                    } else {
                        Insn::FnmaddS {
                            rd,
                            rs1,
                            rs2,
                            rs3,
                            rm: funct3,
                        }
                    }
                }
                _ => Insn::Illegal(w),
            }
        }
        0x53 => decode_fp(w, xlen),
        _ => Insn::Illegal(w),
    }
}

#[cfg(test)]
#[allow(clippy::precedence)]
mod tests {
    use super::*;

    fn enc_i(op: u32, rd: u32, f3: u32, rs1: u32, imm: i64) -> u32 {
        let imm12 = ((imm as i32) & 0xfff) as u32;
        imm12 << 20 | rs1 << 15 | f3 << 12 | rd << 7 | op
    }
    fn enc_b(op: u32, f3: u32, rs1: u32, rs2: u32, off: i64) -> u32 {
        let o = off as u32;
        let b12 = (o >> 12) & 1;
        let b10_5 = (o >> 5) & 0x3f;
        let b4_1 = (o >> 1) & 0x0f;
        let b11 = (o >> 11) & 1;
        (b12 << 31)
            | (b10_5 << 25)
            | (rs2 << 20)
            | (rs1 << 15)
            | (f3 << 12)
            | (b4_1 << 8)
            | (b11 << 7)
            | op
    }

    #[test]
    fn immediates_are_sign_extended_correctly() {
        assert_eq!(i_imm(enc_i(0x13, 1, 0, 2, -5)), -5);
        assert_eq!(i_imm(enc_i(0x13, 1, 0, 2, 2047)), 2047);
        assert_eq!(i_imm(enc_i(0x13, 1, 0, 2, -2048)), -2048);
    }

    #[test]
    fn branch_offsets_drop_bit_zero() {
        // A branch offset must be even; bit 0 is implicit and not encoded.
        assert_eq!(b_imm(enc_b(0x63, 0, 1, 2, 16)), 16);
        assert_eq!(b_imm(enc_b(0x63, 0, 1, 2, -16)), -16);
    }

    #[test]
    fn jal_offset_is_word_aligned_and_sign_extended() {
        let w = 0x6f | (1 << 7) | (0x123 << 12); // contrived
        if let Insn::Jal { rd: 1, .. } = decode(w, 64) {
            // shape is enough
        } else {
            panic!("expected jal with rd=1");
        }
    }

    #[test]
    fn all_load_widths_decode() {
        assert!(matches!(
            decode(enc_i(0x03, 1, 0, 2, 0), 64),
            Insn::Lb { .. }
        ));
        assert!(matches!(
            decode(enc_i(0x03, 1, 1, 2, 0), 64),
            Insn::Lh { .. }
        ));
        assert!(matches!(
            decode(enc_i(0x03, 1, 2, 2, 0), 64),
            Insn::Lw { .. }
        ));
        assert!(matches!(
            decode(enc_i(0x03, 1, 3, 2, 0), 64),
            Insn::Ld { .. }
        ));
        assert!(matches!(
            decode(enc_i(0x03, 1, 4, 2, 0), 64),
            Insn::Lbu { .. }
        ));
        assert!(matches!(
            decode(enc_i(0x03, 1, 5, 2, 0), 64),
            Insn::Lhu { .. }
        ));
        assert!(matches!(
            decode(enc_i(0x03, 1, 6, 2, 0), 64),
            Insn::Lwu { .. }
        ));
    }

    #[test]
    fn rv64_only_word_ops_decode_separately() {
        assert!(matches!(
            decode(enc_i(0x1b, 1, 0, 2, 5), 64),
            Insn::Addiw { .. }
        ));
        assert!(matches!(
            decode(enc_i(0x1b, 1, 1, 2, 0x1f), 64),
            Insn::Slliw { .. }
        ));
    }

    #[test]
    fn shifts_mask_the_shamt_for_the_requested_xlen() {
        // XLEN=64 -> 6 bits; XLEN=32 -> 5 bits.
        let slli64 = enc_i(0x13, 1, 1, 2, 0) | (0x2f << 20);
        assert_eq!(
            decode(slli64, 64),
            Insn::Slli {
                rd: 1,
                rs1: 2,
                shamt: 0x2f
            }
        );

        let slli32 = enc_i(0x13, 1, 1, 2, 0) | (0x1f << 20);
        assert_eq!(
            decode(slli32, 64),
            Insn::Slli {
                rd: 1,
                rs1: 2,
                shamt: 0x1f
            }
        );
    }

    #[test]
    fn csr_immediates_are_zero_source_not_register_zero() {
        // csrrwi x1, 0x123, uimm=5: funct3=101 (5), immediate in rs1 field.
        let w = (5 << 15) | (0x5 << 12) | (1 << 7) | 0x73;
        assert_eq!(
            decode(w, 64),
            Insn::Csrrwi {
                rd: 1,
                uimm: 5,
                csr: 0
            }
        );
    }

    #[test]
    fn ecall_and_ebreak_decode_only_to_a_halt() {
        let ecall = 0x73; // rd=0, funct3=0, funct7=0, rs2=0
        assert!(matches!(decode(ecall, 64), Insn::Ecall));

        let ebreak = 0x73 | (1 << 20); // rs2=1
        assert!(matches!(decode(ebreak, 64), Insn::Ebreak));
    }

    #[test]
    fn unknown_opcodes_are_illegal() {
        assert!(matches!(decode(0x00, 64), Insn::Illegal(_)));
    }

    #[test]
    fn ai_queue_instructions_decode_when_instr_set_is_provided() {
        let ai = g6q_core::model::AiInstrSet {
            opcode_custom2: 0x5B,
            mask_f7f3op: 0xFE00707F,
            match_enq: 0x0000505B,
            match_poll: 0x0200505B,
            match_qfence: 0x0400505B,
            ..Default::default()
        };
        let rs1 = 10;
        let rd = 5;
        let enq = (rs1 << 15) | (5 << 12) | (rd << 7) | 0x5B;
        assert!(matches!(
            decode_with_ai(enq, 64, Some(&ai)),
            Insn::AiEnq { rd: 5, rs1: 10 }
        ));

        let poll = (1 << 25) | (rs1 << 15) | (5 << 12) | (rd << 7) | 0x5B;
        assert!(matches!(
            decode_with_ai(poll, 64, Some(&ai)),
            Insn::AiPoll { rd: 5, rs1: 10 }
        ));

        let qfence = (2 << 25) | (5 << 12) | 0x5B;
        assert!(matches!(
            decode_with_ai(qfence, 64, Some(&ai)),
            Insn::AiQfence
        ));

        // Without an AI set, custom-2 is illegal.
        assert!(matches!(decode(enq, 64), Insn::Illegal(_)));
    }

    #[test]
    fn decoding_is_deterministic() {
        assert_eq!(decode(0x12345678, 64), decode(0x12345678, 64));
    }

    #[test]
    fn zicbo_instructions_decode() {
        // cbo.inval base(rs1=2): op=0x0f, f3=0x2, rd=0, funct12=0x000
        let w = (2 << 15) | (0x2 << 12) | 0x0f;
        assert!(matches!(decode(w, 64), Insn::CboInval { rs1: 2 }));

        // cbo.clean base(rs1=3): funct12=0x001
        let w = (0x001 << 20) | (3 << 15) | (0x2 << 12) | 0x0f;
        assert!(matches!(decode(w, 64), Insn::CboClean { rs1: 3 }));

        // cbo.flush base(rs1=4): funct12=0x002
        let w = (0x002 << 20) | (4 << 15) | (0x2 << 12) | 0x0f;
        assert!(matches!(decode(w, 64), Insn::CboFlush { rs1: 4 }));

        // cbo.zero base(rs1=5): funct12=0x004
        let w = (0x004 << 20) | (5 << 15) | (0x2 << 12) | 0x0f;
        assert!(matches!(decode(w, 64), Insn::CboZero { rs1: 5 }));
    }
}
