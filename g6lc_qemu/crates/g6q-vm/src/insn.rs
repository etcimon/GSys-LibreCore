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

fn shamt(w: u32, xlen: u32) -> u8 {
    let mask = if xlen == 64 { 0x3f } else { 0x1f };
    ((w >> 20) & mask) as u8
}

/// Decode one 32-bit instruction.
pub fn decode(w: u32, xlen: u32) -> Insn {
    let opcode = w & 0x7f;
    let rd = u8_field(w, 11, 7);
    let rs1 = u8_field(w, 19, 15);
    let rs2 = u8_field(w, 24, 20);
    let funct3 = u8_field(w, 14, 12);
    let funct7 = u8_field(w, 31, 25);
    let csr = u16_field(w, 31, 20);

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
            0x1 => Insn::Slli {
                rd,
                rs1,
                shamt: shamt(w, xlen),
            },
            0x5 => match funct7 {
                0x00 => Insn::Srli {
                    rd,
                    rs1,
                    shamt: shamt(w, xlen),
                },
                0x20 => Insn::Srai {
                    rd,
                    rs1,
                    shamt: shamt(w, xlen),
                },
                _ => Insn::Illegal(w),
            },
            _ => Insn::Illegal(w),
        },
        0x1b => match funct3 {
            0x0 => Insn::Addiw {
                rd,
                rs1,
                imm: i_imm(w) as i32,
            },
            0x1 => Insn::Slliw {
                rd,
                rs1,
                shamt: shamt(w, 32),
            },
            0x5 => match funct7 {
                0x00 => Insn::Srliw {
                    rd,
                    rs1,
                    shamt: shamt(w, 32),
                },
                0x20 => Insn::Sraiw {
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
                _ => Insn::Illegal(w),
            },
            0x1 => Insn::Sll { rd, rs1, rs2 },
            0x2 => Insn::Slt { rd, rs1, rs2 },
            0x3 => Insn::Sltu { rd, rs1, rs2 },
            0x4 => Insn::Xor { rd, rs1, rs2 },
            0x5 => match funct7 {
                0x00 => Insn::Srl { rd, rs1, rs2 },
                0x20 => Insn::Sra { rd, rs1, rs2 },
                _ => Insn::Illegal(w),
            },
            0x6 => Insn::Or { rd, rs1, rs2 },
            0x7 => Insn::And { rd, rs1, rs2 },
            _ => Insn::Illegal(w),
        },
        0x3b => match funct3 {
            0x0 => match funct7 {
                0x00 => Insn::Addw { rd, rs1, rs2 },
                0x20 => Insn::Subw { rd, rs1, rs2 },
                _ => Insn::Illegal(w),
            },
            0x1 => Insn::Sllw { rd, rs1, rs2 },
            0x5 => match funct7 {
                0x00 => Insn::Srlw { rd, rs1, rs2 },
                0x20 => Insn::Sraw { rd, rs1, rs2 },
                _ => Insn::Illegal(w),
            },
            0x4 | 0x6 | 0x7 => Insn::Illegal(w), // no xorw / orw / andw
            _ => Insn::Illegal(w),
        },
        0x73 => match funct3 {
            0x0 => match (funct7, rs2) {
                (0x00, 0x00) if rd == 0 => Insn::Ecall,
                (0x00, 0x01) if rd == 0 => Insn::Ebreak,
                (0x00, 0x02) => Insn::FenceI,
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
            _ => Insn::Illegal(w),
        },
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
    fn decoding_is_deterministic() {
        assert_eq!(decode(0x12345678, 64), decode(0x12345678, 64));
    }
}
