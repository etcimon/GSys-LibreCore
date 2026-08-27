// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Compressed (RVC) decoder for `g6q-vm`.
//!
//! The 16-bit RISC-V compressed encodings are expanded to full `Insn` variants so the
//! interpreter can reuse the existing 32-bit execution paths. This file is deliberately
//! self-contained: it does not import QEMU headers or other external material.

use crate::insn::Insn;

/// Sign-extend the low `bits` of `val` to a 64-bit signed integer.
fn sext(val: u64, bits: u32) -> i64 {
    ((val << (64 - bits)) as i64) >> (64 - bits)
}

/// Decode a 16-bit RVC instruction. `xlen` is 32 or 64 and gates width-specific forms.
pub fn decode_c(w: u16, xlen: u32) -> Insn {
    let b = |i: u32| ((w >> i) & 1) as u64;
    let bits = |hi: u32, lo: u32| ((w >> lo) & ((1 << (hi - lo + 1)) - 1)) as u64;

    let op = w & 0b11;
    let funct3 = (w >> 13) & 0b111;

    match op {
        0b00 => match funct3 {
            0b000 => {
                // c.addi4spn -> addi rd', sp, uimm
                let rd = 8 + bits(4, 2) as u8;
                let imm = ((bits(10, 7) & 0xf) << 6)
                    | ((bits(12, 11) & 0x3) << 4)
                    | ((b(5) & 1) << 3)
                    | ((b(6) & 1) << 2);
                if imm == 0 {
                    return Insn::Illegal(w as u32);
                }
                Insn::Addi {
                    rd,
                    rs1: 2,
                    imm: imm as i64,
                }
            }
            0b010 => {
                // c.lw -> lw rd', uimm(rs1')
                let rd = 8 + bits(4, 2) as u8;
                let rs1 = 8 + bits(9, 7) as u8;
                let imm = ((b(5) & 1) << 6) | ((bits(12, 10) & 0x7) << 3) | ((b(6) & 1) << 2);
                Insn::Lw {
                    rd,
                    rs1,
                    imm: imm as i64,
                }
            }
            0b011 if xlen == 64 => {
                // c.ld -> ld rd', uimm(rs1') (RV64)
                let rd = 8 + bits(4, 2) as u8;
                let rs1 = 8 + bits(9, 7) as u8;
                let imm = ((bits(6, 5) & 0x3) << 6) | ((bits(12, 10) & 0x7) << 3);
                Insn::Ld {
                    rd,
                    rs1,
                    imm: imm as i64,
                }
            }
            0b110 => {
                // c.sw -> sw rs2', uimm(rs1')
                let rs1 = 8 + bits(9, 7) as u8;
                let rs2 = 8 + bits(4, 2) as u8;
                let imm = ((b(5) & 1) << 6) | ((bits(12, 10) & 0x7) << 3) | ((b(6) & 1) << 2);
                Insn::Sw {
                    rs1,
                    rs2,
                    imm: imm as i64,
                }
            }
            0b111 if xlen == 64 => {
                // c.sd -> sd rs2', uimm(rs1') (RV64)
                let rs1 = 8 + bits(9, 7) as u8;
                let rs2 = 8 + bits(4, 2) as u8;
                let imm = ((bits(6, 5) & 0x3) << 6) | ((bits(12, 10) & 0x7) << 3);
                Insn::Sd {
                    rs1,
                    rs2,
                    imm: imm as i64,
                }
            }
            _ => Insn::Illegal(w as u32),
        },
        0b01 => match funct3 {
            0b000 => {
                // c.nop / c.addi -> addi rd, rd, imm
                let rd = bits(11, 7) as u8;
                let val = (b(12) << 5) | (bits(6, 2) & 0x1f);
                let imm = sext(val, 6);
                Insn::Addi { rd, rs1: rd, imm }
            }
            0b001 if xlen == 64 => {
                // c.addiw -> addiw rd, rd, imm (RV64)
                let rd = bits(11, 7) as u8;
                let val = (b(12) << 5) | (bits(6, 2) & 0x1f);
                let imm = sext(val, 6) as i32;
                Insn::Addiw { rd, rs1: rd, imm }
            }
            0b001 => {
                // c.jal (RV32) -> jal x1, imm
                Insn::Jal {
                    rd: 1,
                    imm: c_j_imm(w),
                }
            }
            0b010 => {
                // c.li -> addi rd, x0, imm
                let rd = bits(11, 7) as u8;
                let val = (b(12) << 5) | (bits(6, 2) & 0x1f);
                let imm = sext(val, 6);
                Insn::Addi { rd, rs1: 0, imm }
            }
            0b011 => {
                let rd = bits(11, 7) as u8;
                if rd == 2 {
                    // c.addi16sp -> addi sp, sp, imm
                    let val = (b(12) << 9)
                        | ((b(4) & 1) << 8)
                        | ((b(3) & 1) << 7)
                        | ((b(5) & 1) << 6)
                        | ((b(2) & 1) << 5)
                        | ((b(6) & 1) << 4);
                    if val == 0 {
                        return Insn::Illegal(w as u32);
                    }
                    let imm = sext(val, 10);
                    Insn::Addi { rd: 2, rs1: 2, imm }
                } else {
                    // c.lui -> lui rd, imm (rd != 0)
                    let lo = bits(6, 2);
                    if lo == 0 && b(12) == 0 {
                        return Insn::Illegal(w as u32);
                    }
                    Insn::Lui {
                        rd,
                        imm: c_lui_imm(w),
                    }
                }
            }
            0b100 => {
                let rd = 8 + bits(9, 7) as u8;
                match bits(11, 10) {
                    0b00 => {
                        // c.srli -> srli rd', rd', shamt
                        let sh = (bits(12, 12) << 5) | bits(6, 2);
                        if xlen == 32 && (sh & 0x20) != 0 {
                            return Insn::Illegal(w as u32);
                        }
                        Insn::Srli {
                            rd,
                            rs1: rd,
                            shamt: sh as u8,
                        }
                    }
                    0b01 => {
                        // c.srai -> srai rd', rd', shamt
                        let sh = (bits(12, 12) << 5) | bits(6, 2);
                        if xlen == 32 && (sh & 0x20) != 0 {
                            return Insn::Illegal(w as u32);
                        }
                        Insn::Srai {
                            rd,
                            rs1: rd,
                            shamt: sh as u8,
                        }
                    }
                    0b10 => {
                        // c.andi -> andi rd', rd', imm
                        let val = (b(12) << 5) | (bits(6, 2) & 0x1f);
                        let imm = sext(val, 6);
                        Insn::Andi { rd, rs1: rd, imm }
                    }
                    _ => {
                        // c.sub / c.xor / c.or / c.and (c.addw / c.subw on RV64)
                        match (w >> 5) & 0b11 {
                            0b00 => Insn::Sub {
                                rd,
                                rs1: rd,
                                rs2: 8 + bits(4, 2) as u8,
                            },
                            0b01 => Insn::Xor {
                                rd,
                                rs1: rd,
                                rs2: 8 + bits(4, 2) as u8,
                            },
                            0b10 => Insn::Or {
                                rd,
                                rs1: rd,
                                rs2: 8 + bits(4, 2) as u8,
                            },
                            0b11 if xlen == 64 => match (w >> 12) & 1 {
                                0 => Insn::Addw {
                                    rd,
                                    rs1: rd,
                                    rs2: 8 + bits(4, 2) as u8,
                                },
                                _ => Insn::Subw {
                                    rd,
                                    rs1: rd,
                                    rs2: 8 + bits(4, 2) as u8,
                                },
                            },
                            _ => Insn::And {
                                rd,
                                rs1: rd,
                                rs2: 8 + bits(4, 2) as u8,
                            },
                        }
                    }
                }
            }
            0b101 => {
                // c.j -> jal x0, imm
                Insn::Jal {
                    rd: 0,
                    imm: c_j_imm(w),
                }
            }
            0b110 => {
                // c.beqz -> beq rs1', x0, imm
                Insn::Beq {
                    rs1: 8 + bits(9, 7) as u8,
                    rs2: 0,
                    imm: c_b_imm(w),
                }
            }
            0b111 => {
                // c.bnez -> bne rs1', x0, imm
                Insn::Bne {
                    rs1: 8 + bits(9, 7) as u8,
                    rs2: 0,
                    imm: c_b_imm(w),
                }
            }
            _ => Insn::Illegal(w as u32),
        },
        0b10 => match funct3 {
            0b000 => {
                // c.slli -> slli rd, rd, shamt
                let rd = bits(11, 7) as u8;
                let sh = (bits(12, 12) << 5) | bits(6, 2);
                if xlen == 32 && (sh & 0x20) != 0 {
                    return Insn::Illegal(w as u32);
                }
                Insn::Slli {
                    rd,
                    rs1: rd,
                    shamt: sh as u8,
                }
            }
            0b010 => {
                // c.lwsp -> lw rd, uimm(sp) (rd != 0)
                let rd = bits(11, 7) as u8;
                if rd == 0 {
                    return Insn::Illegal(w as u32);
                }
                let imm = ((b(3) & 1) << 7)
                    | ((b(2) & 1) << 6)
                    | ((b(12) & 1) << 5)
                    | ((b(6) & 1) << 4)
                    | ((b(5) & 1) << 3)
                    | ((b(4) & 1) << 2);
                Insn::Lw {
                    rd,
                    rs1: 2,
                    imm: imm as i64,
                }
            }
            0b011 if xlen == 64 => {
                // c.ldsp -> ld rd, uimm(sp) (RV64, rd != 0)
                let rd = bits(11, 7) as u8;
                if rd == 0 {
                    return Insn::Illegal(w as u32);
                }
                let imm = ((b(4) & 1) << 8)
                    | ((b(3) & 1) << 7)
                    | ((b(2) & 1) << 6)
                    | ((b(12) & 1) << 5)
                    | ((b(6) & 1) << 4)
                    | ((b(5) & 1) << 3);
                Insn::Ld {
                    rd,
                    rs1: 2,
                    imm: imm as i64,
                }
            }
            0b100 => {
                let rd = bits(11, 7) as u8;
                let rs2 = bits(6, 2) as u8;
                let bit12 = b(12);
                if bit12 == 0 && rs2 == 0 && rd != 0 {
                    // c.jr -> jalr x0, rd, 0
                    Insn::Jalr {
                        rd: 0,
                        rs1: rd,
                        imm: 0,
                    }
                } else if bit12 == 0 && rs2 != 0 {
                    // c.mv -> add rd, x0, rs2
                    Insn::Add { rd, rs1: 0, rs2 }
                } else if bit12 == 1 && rs2 == 0 && rd != 0 {
                    // c.jalr -> jalr x1, rd, 0
                    Insn::Jalr {
                        rd: 1,
                        rs1: rd,
                        imm: 0,
                    }
                } else if bit12 == 1 && rs2 != 0 {
                    // c.add -> add rd, rd, rs2
                    Insn::Add { rd, rs1: rd, rs2 }
                } else if bit12 == 1 && rd == 0 && rs2 == 0 {
                    // c.ebreak
                    Insn::Ebreak
                } else {
                    // Reserved: c.jalr/c.jr with rs1=x0
                    Insn::Illegal(w as u32)
                }
            }
            0b110 => {
                // c.swsp -> sw rs2, uimm(sp)
                let rs2 = bits(6, 2) as u8;
                let imm = ((b(8) & 1) << 7)
                    | ((b(7) & 1) << 6)
                    | ((b(12) & 1) << 5)
                    | ((b(11) & 1) << 4)
                    | ((b(10) & 1) << 3)
                    | ((b(9) & 1) << 2);
                Insn::Sw {
                    rs1: 2,
                    rs2,
                    imm: imm as i64,
                }
            }
            0b111 if xlen == 64 => {
                // c.sdsp -> sd rs2, uimm(sp) (RV64)
                let rs2 = bits(6, 2) as u8;
                let imm = ((b(9) & 1) << 8)
                    | ((b(8) & 1) << 7)
                    | ((b(7) & 1) << 6)
                    | ((b(12) & 1) << 5)
                    | ((b(11) & 1) << 4)
                    | ((b(10) & 1) << 3);
                Insn::Sd {
                    rs1: 2,
                    rs2,
                    imm: imm as i64,
                }
            }
            _ => Insn::Illegal(w as u32),
        },
        _ => Insn::Illegal(w as u32),
    }
}

/// c.j / c.jal target: 12-bit signed offset with bit 0 tied to 0.
fn c_j_imm(w: u16) -> i64 {
    let b = |i: u32| ((w >> i) & 1) as u64;

    let off_11_1 = (b(12) << 10)
        | (b(8) << 9)
        | (b(10) << 8)
        | (b(9) << 7)
        | (b(6) << 6)
        | (b(7) << 5)
        | (b(2) << 4)
        | (b(11) << 3)
        | (b(5) << 2)
        | (b(4) << 1)
        | b(3);
    sext(off_11_1 << 1, 12)
}

/// c.beqz / c.bnez target: 9-bit signed offset with bit 0 tied to 0.
fn c_b_imm(w: u16) -> i64 {
    let b = |i: u32| ((w >> i) & 1) as u64;

    let val = (b(12) << 8)
        | (b(6) << 7)
        | (b(5) << 6)
        | (b(2) << 5)
        | (b(11) << 4)
        | (b(10) << 3)
        | (b(4) << 2)
        | (b(3) << 1);
    sext(val, 9)
}

/// c.lui expanded 20-bit `lui` immediate (bits [17:12] placed in the U-immediate).
fn c_lui_imm(w: u16) -> i64 {
    let b = |i: u32| ((w >> i) & 1) as u64;
    let lo = ((w >> 2) & 0x1f) as u64;

    // The 18-bit signed nzimm has bits [17:12] encoded and [11:0] zero.
    let imm18 = (b(12) << 17) | (lo << 12);
    let sext18 = ((imm18 as i64) << 46) >> 46;
    sext18 << 12
}
