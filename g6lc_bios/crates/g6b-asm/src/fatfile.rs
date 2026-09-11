// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Minimal FAT32 root-directory file reader for the S-mode payload.
//!
//! `FatRead` runs after `BlkSig` on a board with a virtio-blk device. It reads
//! the FAT32 BPB from LBA 0, walks the root directory for a fixed file name,
//! and, if found, reads the first cluster and prints the first 64 bytes. This is
//! the payload's first file-level read, not a full VFS, and deliberately stays
//! on simple 8.3 root entries with one data cluster.

use crate::analyze::Object;
use crate::encode::SBI_PUTCHAR;
use crate::encode::{
    A0, A1, A2, A3, A4, A5, A6, A7, RA, S0, S1, S2, S3, SP, T0, T1, T2, T3, T4, T5, T6, X0,
};
use crate::{Node, Op, Purpose};

use crate::vio::{BLK_BASE, BLK_DATA_OFF, BLK_DEV, BLK_SIG};

/// File to look for in the root directory: 8.3 "HELLO   TXT".
const FAT_TARGET: &[u8] = b"HELLO   TXT";

fn ret() -> Op {
    Op::Jalr {
        rd: X0,
        rs: RA,
        imm: 0,
    }
}

fn lbu(rd: u32, rs: u32, off: i32) -> Op {
    Op::Lbu { rd, rs, off }
}

fn st_x(xlen: u32, rs2: u32, rs1: u32, off: i32) -> Op {
    if xlen == 64 {
        Op::Sd { rs2, rs1, off }
    } else {
        Op::Sw { rs2, rs1, off }
    }
}

fn ld_x(xlen: u32, rd: u32, rs: u32, off: i32) -> Op {
    if xlen == 64 {
        Op::Ld { rd, rs, off }
    } else {
        Op::Lw { rd, rs, off }
    }
}

fn putc_str(ops: &mut Vec<Op>, s: &str) {
    for ch in s.bytes() {
        ops.extend([
            Op::Li {
                rd: A0,
                imm: ch.into(),
            },
            Op::Li {
                rd: A7,
                imm: SBI_PUTCHAR,
            },
            Op::Ecall,
        ]);
    }
}

/// Build a `FatRead` node that reads a fixed file from a FAT32 medium.
pub fn fat_read_node(o: Object, xlen: u32) -> Node {
    let mut ops = vec![
        Op::Comment(format!("{} — FAT32 root file read", o.why)),
        Op::Glob("FatRead".into()),
        Op::Label("FatRead".into()),
        // Save RA and s-regs; the routine is not leaf because it calls BlkRead.
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -32,
        },
        st_x(xlen, RA, SP, 0),
        st_x(xlen, S0, SP, 8),
        st_x(xlen, S1, SP, 16),
        st_x(xlen, S2, SP, 24),
        // Verify a block device was accepted; BlkInit wrote the device base.
        Op::La {
            rd: T5,
            addr: crate::Addr::VioBss,
        },
        Op::Li {
            rd: T4,
            imm: BLK_BASE,
        },
        Op::Add {
            rd: T5,
            rs1: T5,
            rs2: T4,
        },
        Op::Lw {
            rd: T6,
            rs: T5,
            off: BLK_DEV,
        },
        Op::Beq {
            rs1: T6,
            rs2: X0,
            to: "fat_out".into(),
        },
        // Only proceed when BlkSig latched a FAT signature (kind 1). The BPB it
        // read is still in the sector buffer. Anything else returns silently so
        // a non-FAT medium pays nothing and prints nothing here.
        Op::Lw {
            rd: A0,
            rs: T5,
            off: BLK_SIG,
        },
        Op::Li { rd: T0, imm: 1 },
        Op::Bne {
            rs1: A0,
            rs2: T0,
            to: "fat_done".into(),
        },
        Op::Label("fat_have_bpb".into()),
        // ---- Parse the FAT32 BPB (offsets in the 512-byte buffer) ----
        // S0 = bytes per sector = u16 at 0x0B
        lbu(T0, T5, BLK_DATA_OFF + 0x0B),
        lbu(T1, T5, BLK_DATA_OFF + 0x0C),
        Op::Slli {
            rd: T1,
            rs: T1,
            shamt: 8,
        },
        Op::Add {
            rd: S0,
            rs1: T0,
            rs2: T1,
        },
        // S1 = sectors per cluster = u8 at 0x0D (kept for LBA arithmetic).
        lbu(S1, T5, BLK_DATA_OFF + 0x0D),
        // T2 = rsvd sectors = u16 at 0x0E
        lbu(T0, T5, BLK_DATA_OFF + 0x0E),
        lbu(T1, T5, BLK_DATA_OFF + 0x0F),
        Op::Slli {
            rd: T1,
            rs: T1,
            shamt: 8,
        },
        Op::Add {
            rd: T2,
            rs1: T0,
            rs2: T1,
        },
        // T3 = num_fats = u8 at 0x10
        lbu(T3, T5, BLK_DATA_OFF + 0x10),
        // T0 = sectors per FAT = u32 at 0x24
        lbu(T0, T5, BLK_DATA_OFF + 0x24),
        lbu(T1, T5, BLK_DATA_OFF + 0x25),
        lbu(T4, T5, BLK_DATA_OFF + 0x26),
        lbu(A1, T5, BLK_DATA_OFF + 0x27),
        Op::Slli {
            rd: T1,
            rs: T1,
            shamt: 8,
        },
        Op::Slli {
            rd: T4,
            rs: T4,
            shamt: 16,
        },
        Op::Slli {
            rd: A1,
            rs: A1,
            shamt: 24,
        },
        Op::Add {
            rd: T0,
            rs1: T0,
            rs2: T1,
        },
        Op::Add {
            rd: T0,
            rs1: T0,
            rs2: T4,
        },
        Op::Add {
            rd: T0,
            rs1: T0,
            rs2: A1,
        },
        // S2 = data start LBA = rsvd + num_fats * fatsz
        Op::Mul {
            rd: T0,
            rs1: T3,
            rs2: T0,
        },
        Op::Add {
            rd: S2,
            rs1: T2,
            rs2: T0,
        },
        // S3 = root cluster = u32 at 0x2C
        lbu(T0, T5, BLK_DATA_OFF + 0x2C),
        lbu(T1, T5, BLK_DATA_OFF + 0x2D),
        lbu(T4, T5, BLK_DATA_OFF + 0x2E),
        lbu(A1, T5, BLK_DATA_OFF + 0x2F),
        Op::Slli {
            rd: T1,
            rs: T1,
            shamt: 8,
        },
        Op::Slli {
            rd: T4,
            rs: T4,
            shamt: 16,
        },
        Op::Slli {
            rd: A1,
            rs: A1,
            shamt: 24,
        },
        Op::Add {
            rd: T0,
            rs1: T0,
            rs2: T1,
        },
        Op::Add {
            rd: T0,
            rs1: T0,
            rs2: T4,
        },
        Op::Add {
            rd: S3,
            rs1: T0,
            rs2: A1,
        },
        // Sanity: S0 must be 512 and S1 positive.
        Op::Li { rd: T2, imm: 512 },
        Op::Bne {
            rs1: S0,
            rs2: T2,
            to: "fat_out".into(),
        },
        Op::Beq {
            rs1: S1,
            rs2: X0,
            to: "fat_out".into(),
        },
        // Read root directory: root_lba = S2 + (S3 - 2) * S1.
        Op::Addi {
            rd: T0,
            rs: S3,
            imm: -2,
        },
        Op::Mul {
            rd: T0,
            rs1: T0,
            rs2: S1,
        },
        Op::Add {
            rd: A0,
            rs1: S2,
            rs2: T0,
        },
        Op::Jal {
            rd: RA,
            to: "BlkRead".into(),
        },
        Op::Beq {
            rs1: A0,
            rs2: X0,
            to: "fat_out".into(),
        },
    ];

    // ---- Walk the 16 root-directory 32-byte entries in the first root cluster.
    ops.extend([
        Op::Li { rd: A2, imm: 0 },
        Op::Label("fat_dir_loop".into()),
        // if A2 >= 16 goto notfound
        Op::Li { rd: T0, imm: 16 },
        Op::Sltu {
            rd: T1,
            rs1: T0,
            rs2: A2,
        },
        Op::Bne {
            rs1: T1,
            rs2: X0,
            to: "fat_notfound".into(),
        },
        // if A2 == 16 goto notfound
        Op::Beq {
            rs1: A2,
            rs2: T0,
            to: "fat_notfound".into(),
        },
        // A3 = BLK_DATA_OFF + A2 * 32
        Op::Li { rd: T0, imm: 32 },
        Op::Mul {
            rd: T1,
            rs1: A2,
            rs2: T0,
        },
        Op::Addi {
            rd: A3,
            rs: T5,
            imm: BLK_DATA_OFF,
        },
        Op::Add {
            rd: A3,
            rs1: A3,
            rs2: T1,
        },
        lbu(T0, A3, 0),
        // 0x00 = no more entries.
        Op::Li { rd: T1, imm: 0x00 },
        Op::Beq {
            rs1: T0,
            rs2: T1,
            to: "fat_notfound".into(),
        },
        // 0xE5 = deleted entry.
        Op::Li { rd: T1, imm: 0xE5 },
        Op::Beq {
            rs1: T0,
            rs2: T1,
            to: "fat_next".into(),
        },
        // attribute at offset 11.
        lbu(T6, A3, 11),
        // Skip LFN (0x0F): (attr & 0x0F) == 0x0F
        Op::Andi {
            rd: T4,
            rs: T6,
            imm: 0x0F,
        },
        Op::Li { rd: T1, imm: 0x0F },
        Op::Beq {
            rs1: T4,
            rs2: T1,
            to: "fat_next".into(),
        },
        // Skip volume label (0x08): (attr & 0x08) != 0
        Op::Andi {
            rd: T4,
            rs: T6,
            imm: 0x08,
        },
        Op::Bne {
            rs1: T4,
            rs2: X0,
            to: "fat_next".into(),
        },
        // Skip directories (0x10): (attr & 0x10) != 0
        Op::Andi {
            rd: T4,
            rs: T6,
            imm: 0x10,
        },
        Op::Bne {
            rs1: T4,
            rs2: X0,
            to: "fat_next".into(),
        },
        // Compare the 11-byte name against FAT_TARGET.
        Op::Li { rd: A4, imm: 0 },
        Op::Label("fat_name_loop".into()),
        // if A4 >= 11 goto found
        Op::Li { rd: T0, imm: 11 },
        Op::Sltu {
            rd: T1,
            rs1: T0,
            rs2: A4,
        },
        Op::Bne {
            rs1: T1,
            rs2: X0,
            to: "fat_found".into(),
        },
        Op::Beq {
            rs1: A4,
            rs2: T0,
            to: "fat_found".into(),
        },
    ]);

    // Inline the 11-byte comparison. We load one directory byte and compare
    // against the fixed target byte. If any mismatch, jump to fat_next
    // (through fat_name_bad).
    for (i, &b) in FAT_TARGET.iter().enumerate() {
        ops.extend([
            lbu(T0, A3, i as i32),
            Op::Li {
                rd: T1,
                imm: i64::from(b),
            },
            Op::Bne {
                rs1: T0,
                rs2: T1,
                to: "fat_name_bad".into(),
            },
        ]);
    }

    ops.extend([
        Op::Jal {
            rd: X0,
            to: "fat_found".into(),
        },
        Op::Label("fat_name_bad".into()),
        Op::Jal {
            rd: X0,
            to: "fat_next".into(),
        },
    ]);

    // ---- Found the file.
    ops.extend([
        Op::Label("fat_found".into()),
        // first cluster = u16 at 0x1A | u16 at 0x14 << 16
        lbu(T0, A3, 0x1A),
        lbu(T1, A3, 0x1B),
        Op::Slli {
            rd: T1,
            rs: T1,
            shamt: 8,
        },
        Op::Add {
            rd: T0,
            rs1: T0,
            rs2: T1,
        },
        lbu(T2, A3, 0x14),
        lbu(T3, A3, 0x15),
        Op::Slli {
            rd: T3,
            rs: T3,
            shamt: 8,
        },
        Op::Slli {
            rd: T2,
            rs: T2,
            shamt: 16,
        },
        Op::Add {
            rd: T2,
            rs1: T2,
            rs2: T3,
        },
        Op::Add {
            rd: A5,
            rs1: T0,
            rs2: T2,
        }, // A5 = start cluster
        // file size = u32 at 0x1C
        lbu(T0, A3, 0x1C),
        lbu(T1, A3, 0x1D),
        lbu(T2, A3, 0x1E),
        lbu(T3, A3, 0x1F),
        Op::Slli {
            rd: T1,
            rs: T1,
            shamt: 8,
        },
        Op::Slli {
            rd: T2,
            rs: T2,
            shamt: 16,
        },
        Op::Slli {
            rd: T3,
            rs: T3,
            shamt: 24,
        },
        Op::Add {
            rd: T0,
            rs1: T0,
            rs2: T1,
        },
        Op::Add {
            rd: T0,
            rs1: T0,
            rs2: T2,
        },
        Op::Add {
            rd: A6,
            rs1: T0,
            rs2: T3,
        }, // A6 = file size
        // file_lba = S2 + (A5 - 2) * S1
        Op::Addi {
            rd: T0,
            rs: A5,
            imm: -2,
        },
        Op::Mul {
            rd: T0,
            rs1: T0,
            rs2: S1,
        },
        Op::Add {
            rd: A0,
            rs1: S2,
            rs2: T0,
        },
        Op::Jal {
            rd: RA,
            to: "BlkRead".into(),
        },
        Op::Beq {
            rs1: A0,
            rs2: X0,
            to: "fat_out".into(),
        },
    ]);

    putc_str(&mut ops, "FILE-FOUND ");
    // Print the first 15 bytes of the file (the test payload is text).
    for i in 0..15 {
        ops.extend([
            lbu(A0, T5, BLK_DATA_OFF + i),
            Op::Li {
                rd: A7,
                imm: SBI_PUTCHAR,
            },
            Op::Ecall,
        ]);
    }
    putc_str(&mut ops, "\n");

    ops.extend([
        Op::Jal {
            rd: X0,
            to: "fat_done".into(),
        },
        // Next directory entry.
        Op::Label("fat_next".into()),
        Op::Addi {
            rd: A2,
            rs: A2,
            imm: 1,
        },
        Op::Jal {
            rd: X0,
            to: "fat_dir_loop".into(),
        },
        // Not found.
        Op::Label("fat_notfound".into()),
    ]);
    putc_str(&mut ops, "FILE-NOTFOUND\n");
    ops.extend([
        Op::Label("fat_done".into()),
        ld_x(xlen, S2, SP, 24),
        ld_x(xlen, S1, SP, 16),
        ld_x(xlen, S0, SP, 8),
        ld_x(xlen, RA, SP, 0),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: 32,
        },
        ret(),
        // No device or bad BPB.
        Op::Label("fat_out".into()),
    ]);
    putc_str(&mut ops, "FILE-NODEV\n");
    ops.extend([
        ld_x(xlen, S2, SP, 24),
        ld_x(xlen, S1, SP, 16),
        ld_x(xlen, S0, SP, 8),
        ld_x(xlen, RA, SP, 0),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: 32,
        },
        ret(),
    ]);

    Node {
        purpose: Purpose::VirtioBlk,
        ops,
    }
}
