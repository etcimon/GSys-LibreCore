// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Minimal ext4 root-directory file reader for the S-mode payload.
//!
//! `Ext4Read` runs after `BlkSig` on a board with a virtio-blk device. When
//! `BlkSig` latched an ext4 signature (`BLK_SIG` kind 4 — the LBA 2 superblock
//! is still in the sector buffer), it parses the superblock, finds the group-0
//! inode table, walks the root directory for a fixed file name, and, if found,
//! reads the file's first data block and prints the first 15 bytes. This is the
//! payload's second file-level read, not a full VFS: it only understands
//! direct-block `i_block` maps (no extent trees), one directory sector, and a
//! single fixed name. Anything outside that is refused silently so a non-ext4
//! medium pays nothing.

use crate::analyze::Object;
use crate::encode::SBI_PUTCHAR;
use crate::encode::{
    A0, A2, A3, A4, A7, RA, S0, S1, S2, S3, S4, S5, S6, SP, T0, T1, T2, T3, T4, T5, T6, X0,
};
use crate::{Node, Op, Purpose};

use crate::vio::{BLK_BASE, BLK_DATA_OFF, BLK_DEV, BLK_SIG};

/// File to look for in the ext4 root directory: "hello.txt" (9 bytes).
const EXT4_TARGET: &[u8] = b"hello.txt";

const EXT4_MAGIC: i64 = 0xEF53;
const S_IFDIR_HI: i64 = 0x4; // i_mode >> 12
const S_IFREG_HI: i64 = 0x8;

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

/// Read a little-endian u32 at `BLK_DATA_OFF + off` of the cached sector into
/// `rd`. T0..T3 are clobbered.
fn ld_u32(rd: u32, base: u32, off: i32) -> Vec<Op> {
    vec![
        lbu(rd, base, off),
        lbu(T1, base, off + 1),
        lbu(T2, base, off + 2),
        lbu(T3, base, off + 3),
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
            rd,
            rs1: rd,
            rs2: T1,
        },
        Op::Add {
            rd,
            rs1: rd,
            rs2: T2,
        },
        Op::Add {
            rd,
            rs1: rd,
            rs2: T3,
        },
    ]
}

/// Read a little-endian u32 at register address `A3 + off` into `rd`.
fn ld_u32_at(rd: u32, base: u32, off: i32) -> Vec<Op> {
    ld_u32(rd, base, off)
}

/// `i_flags` extent bit (19) must be clear — an extent tree is outside this
/// reader's contract. `a3` points at the inode. Clobbers T0..T3.
fn check_inode_flags(ops: &mut Vec<Op>, out: &str) {
    ops.extend(ld_u32_at(T0, A3, 32));
    ops.extend([
        Op::Srli {
            rd: T0,
            rs: T0,
            shamt: 19,
        },
        Op::Andi {
            rd: T0,
            rs: T0,
            imm: 1,
        },
        Op::Bne {
            rs1: T0,
            rs2: X0,
            to: out.into(),
        },
    ]);
}

/// `i_mode >> 12` must equal `want` (4 dir, 8 regular). `a3` points at the
/// inode. Clobbers T0..T1.
fn check_inode_mode(ops: &mut Vec<Op>, want: i64, out: &str) {
    ops.extend([
        lbu(T0, A3, 0),
        lbu(T1, A3, 1),
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
        Op::Srli {
            rd: T0,
            rs: T0,
            shamt: 12,
        },
        Op::Li { rd: T1, imm: want },
        Op::Bne {
            rs1: T0,
            rs2: T1,
            to: out.into(),
        },
    ]);
}

/// Build an `Ext4Read` node that reads a fixed file from an ext4 medium.
pub fn ext4_read_node(o: Object, xlen: u32) -> Node {
    let mut ops = vec![
        Op::Comment(format!("{} — ext4 root file read", o.why)),
        Op::Glob("Ext4Read".into()),
        Op::Label("Ext4Read".into()),
        // Save RA and s-regs; the routine is not leaf because it calls BlkRead.
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -64,
        },
        st_x(xlen, RA, SP, 0),
        st_x(xlen, S0, SP, 8),
        st_x(xlen, S1, SP, 16),
        st_x(xlen, S2, SP, 24),
        st_x(xlen, S3, SP, 32),
        st_x(xlen, S4, SP, 40),
        st_x(xlen, S5, SP, 48),
        st_x(xlen, S6, SP, 56),
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
            to: "ext4_out".into(),
        },
        // Only proceed when BlkSig latched an ext4 signature (kind 4); the LBA 2
        // superblock it read is still in the sector buffer.
        Op::Lw {
            rd: A0,
            rs: T5,
            off: BLK_SIG,
        },
        Op::Li { rd: T0, imm: 4 },
        Op::Bne {
            rs1: A0,
            rs2: T0,
            to: "ext4_done".into(),
        },
        Op::Label("ext4_have_sb".into()),
        // Re-verify the superblock magic in the cached sector: `s_magic` is the
        // u16 at offset 56 of the superblock, which sits at BLK_DATA_OFF.
        lbu(T0, T5, BLK_DATA_OFF + 56),
        lbu(T1, T5, BLK_DATA_OFF + 57),
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
        Op::Li {
            rd: T1,
            imm: EXT4_MAGIC,
        },
        Op::Bne {
            rs1: T0,
            rs2: T1,
            to: "ext4_done".into(),
        },
    ];

    // S0 = block size = 1024 << s_log_block_size (u8 at superblock offset 24).
    ops.extend([
        lbu(T0, T5, BLK_DATA_OFF + 24),
        Op::Li { rd: S0, imm: 1024 },
        Op::Li { rd: T1, imm: 0 },
        Op::Label("ext4_bs_loop".into()),
        Op::Beq {
            rs1: T1,
            rs2: T0,
            to: "ext4_bs_done".into(),
        },
        Op::Slli {
            rd: S0,
            rs: S0,
            shamt: 1,
        },
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: 1,
        },
        Op::Jal {
            rd: X0,
            to: "ext4_bs_loop".into(),
        },
        Op::Label("ext4_bs_done".into()),
        // S1 = sectors per block = S0 >> 9.
        Op::Srli {
            rd: S1,
            rs: S0,
            shamt: 9,
        },
        Op::Beq {
            rs1: S1,
            rs2: X0,
            to: "ext4_out".into(),
        },
    ]);

    // S3 = s_inode_size (u16 at 88); S2 = s_inodes_per_group (u32 at 40).
    ops.extend(ld_u32(S2, T5, BLK_DATA_OFF + 40));
    ops.extend([
        lbu(S3, T5, BLK_DATA_OFF + 88),
        lbu(T1, T5, BLK_DATA_OFF + 89),
        Op::Slli {
            rd: T1,
            rs: T1,
            shamt: 8,
        },
        Op::Add {
            rd: S3,
            rs1: S3,
            rs2: T1,
        },
        Op::Beq {
            rs1: S3,
            rs2: X0,
            to: "ext4_out".into(),
        },
    ]);

    // The group descriptor table starts on the block after the superblock's
    // block. For a 1024-byte block the superblock *is* block 1, so the GDT is
    // block 2; for larger blocks the superblock shares block 0 and the GDT is
    // block 1.
    ops.extend([
        Op::Li { rd: T0, imm: 1024 },
        Op::Bne {
            rs1: S0,
            rs2: T0,
            to: "ext4_gdt_big".into(),
        },
        Op::Li { rd: T2, imm: 2 },
        Op::Jal {
            rd: X0,
            to: "ext4_gdt_have".into(),
        },
        Op::Label("ext4_gdt_big".into()),
        Op::Li { rd: T2, imm: 1 },
        Op::Label("ext4_gdt_have".into()),
        // Read the GDT's first sector: A0 = gdt_block * S1.
        Op::Mul {
            rd: A0,
            rs1: T2,
            rs2: S1,
        },
        Op::Jal {
            rd: RA,
            to: "BlkRead".into(),
        },
        Op::Beq {
            rs1: A0,
            rs2: X0,
            to: "ext4_out".into(),
        },
    ]);

    // S4 = group-0 inode table block = bg_inode_table_lo (u32 at GDT offset 8).
    ops.extend(ld_u32(S4, T5, BLK_DATA_OFF + 8));
    ops.extend([
        Op::Beq {
            rs1: S4,
            rs2: X0,
            to: "ext4_out".into(),
        },
        // Read the first sector of the inode table: A0 = S4 * S1.
        Op::Mul {
            rd: A0,
            rs1: S4,
            rs2: S1,
        },
        Op::Jal {
            rd: RA,
            to: "BlkRead".into(),
        },
        Op::Beq {
            rs1: A0,
            rs2: X0,
            to: "ext4_out".into(),
        },
        // Inode 2 (root) sits at index 1 — offset S3 — inside the table.
        Op::Addi {
            rd: A3,
            rs: T5,
            imm: BLK_DATA_OFF,
        },
        Op::Add {
            rd: A3,
            rs1: A3,
            rs2: S3,
        },
    ]);

    // Root inode must be a directory without an extent tree.
    check_inode_mode(&mut ops, S_IFDIR_HI, "ext4_done");
    check_inode_flags(&mut ops, "ext4_done");

    // S5 = root directory's first data block = i_block[0] (u32 at inode +40).
    ops.extend(ld_u32_at(S5, A3, 40));
    ops.extend([
        Op::Beq {
            rs1: S5,
            rs2: X0,
            to: "ext4_out".into(),
        },
        // Read the root directory's first sector: A0 = S5 * S1.
        Op::Mul {
            rd: A0,
            rs1: S5,
            rs2: S1,
        },
        Op::Jal {
            rd: RA,
            to: "BlkRead".into(),
        },
        Op::Beq {
            rs1: A0,
            rs2: X0,
            to: "ext4_out".into(),
        },
    ]);

    // Walk the directory entries in the first 512 bytes. Each entry is
    // {inode u32, rec_len u16, name_len u8, file_type u8, name[]}.
    ops.extend([
        Op::Li { rd: A2, imm: 0 },
        Op::Label("ext4_dir_loop".into()),
        // if A2 >= 512 goto notfound
        Op::Li { rd: T0, imm: 512 },
        Op::Sltu {
            rd: T1,
            rs1: T0,
            rs2: A2,
        },
        Op::Bne {
            rs1: T1,
            rs2: X0,
            to: "ext4_notfound".into(),
        },
        Op::Beq {
            rs1: A2,
            rs2: T0,
            to: "ext4_notfound".into(),
        },
        // A3 = entry = BLK_DATA_OFF + A2.
        Op::Addi {
            rd: A3,
            rs: T5,
            imm: BLK_DATA_OFF,
        },
        Op::Add {
            rd: A3,
            rs1: A3,
            rs2: A2,
        },
    ]);
    // T0 = entry->inode (u32). T1 = entry->rec_len (u16).
    ops.extend(ld_u32_at(T0, A3, 0));
    ops.extend([
        lbu(T1, A3, 4),
        lbu(T2, A3, 5),
        Op::Slli {
            rd: T2,
            rs: T2,
            shamt: 8,
        },
        Op::Add {
            rd: T1,
            rs1: T1,
            rs2: T2,
        },
        Op::Beq {
            rs1: T1,
            rs2: X0,
            to: "ext4_notfound".into(),
        },
        Op::Beq {
            rs1: T0,
            rs2: X0,
            to: "ext4_next".into(),
        },
        // name_len (u8 at +6) must match the target length.
        lbu(T2, A3, 6),
        Op::Li {
            rd: T3,
            imm: EXT4_TARGET.len() as i64,
        },
        Op::Bne {
            rs1: T2,
            rs2: T3,
            to: "ext4_next".into(),
        },
        // A4 = name pointer.
        Op::Addi {
            rd: A4,
            rs: A3,
            imm: 8,
        },
    ]);

    // Inline the name comparison against the fixed target.
    for (i, &b) in EXT4_TARGET.iter().enumerate() {
        ops.extend([
            lbu(T4, A4, i as i32),
            Op::Li {
                rd: T6,
                imm: i64::from(b),
            },
            Op::Bne {
                rs1: T4,
                rs2: T6,
                to: "ext4_next".into(),
            },
        ]);
    }

    ops.extend([
        Op::Jal {
            rd: X0,
            to: "ext4_found".into(),
        },
        // Next entry: offset += rec_len (T1).
        Op::Label("ext4_next".into()),
        Op::Add {
            rd: A2,
            rs1: A2,
            rs2: T1,
        },
        Op::Jal {
            rd: X0,
            to: "ext4_dir_loop".into(),
        },
        Op::Label("ext4_notfound".into()),
    ]);
    putc_str(&mut ops, "FILE-NOTFOUND\n");
    ops.push(Op::Jal {
        rd: X0,
        to: "ext4_done".into(),
    });

    // ---- Found the file. T0 holds its inode number.
    ops.push(Op::Label("ext4_found".into()));
    ops.extend([
        // S6 = byte offset of the inode inside the group-0 table:
        // (ino - 1) * S3. It must live in a saved register — BlkRead clobbers
        // every t register, so anything computed before the call is gone after.
        Op::Addi {
            rd: T1,
            rs: T0,
            imm: -1,
        },
        Op::Mul {
            rd: S6,
            rs1: T1,
            rs2: S3,
        },
        // Sector index inside the table region: T2 = S6 >> 9.
        Op::Srli {
            rd: T2,
            rs: S6,
            shamt: 9,
        },
        // LBA = S4 * S1 + T2 (the inode table may span several blocks).
        Op::Mul {
            rd: A0,
            rs1: S4,
            rs2: S1,
        },
        Op::Add {
            rd: A0,
            rs1: A0,
            rs2: T2,
        },
        Op::Jal {
            rd: RA,
            to: "BlkRead".into(),
        },
        Op::Beq {
            rs1: A0,
            rs2: X0,
            to: "ext4_out".into(),
        },
        // A3 = inode address = BLK_DATA_OFF + (S6 & 511) — S6 survived BlkRead.
        Op::Andi {
            rd: T3,
            rs: S6,
            imm: 511,
        },
        Op::Addi {
            rd: A3,
            rs: T5,
            imm: BLK_DATA_OFF,
        },
        Op::Add {
            rd: A3,
            rs1: A3,
            rs2: T3,
        },
    ]);

    // File inode must be a regular file without an extent tree.
    check_inode_mode(&mut ops, S_IFREG_HI, "ext4_done");
    check_inode_flags(&mut ops, "ext4_done");

    // S5 = file's first data block = i_block[0] (u32 at inode +40).
    ops.extend(ld_u32_at(S5, A3, 40));
    ops.extend([
        Op::Beq {
            rs1: S5,
            rs2: X0,
            to: "ext4_out".into(),
        },
        // Read the file's first sector: A0 = S5 * S1.
        Op::Mul {
            rd: A0,
            rs1: S5,
            rs2: S1,
        },
        Op::Jal {
            rd: RA,
            to: "BlkRead".into(),
        },
        Op::Beq {
            rs1: A0,
            rs2: X0,
            to: "ext4_out".into(),
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
            to: "ext4_done".into(),
        },
        Op::Label("ext4_done".into()),
        ld_x(xlen, S6, SP, 56),
        ld_x(xlen, S5, SP, 48),
        ld_x(xlen, S4, SP, 40),
        ld_x(xlen, S3, SP, 32),
        ld_x(xlen, S2, SP, 24),
        ld_x(xlen, S1, SP, 16),
        ld_x(xlen, S0, SP, 8),
        ld_x(xlen, RA, SP, 0),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: 64,
        },
        ret(),
        // Device absent or a sector read failed.
        Op::Label("ext4_out".into()),
    ]);
    putc_str(&mut ops, "FILE-NODEV\n");
    ops.extend([
        ld_x(xlen, S6, SP, 56),
        ld_x(xlen, S5, SP, 48),
        ld_x(xlen, S4, SP, 40),
        ld_x(xlen, S3, SP, 32),
        ld_x(xlen, S2, SP, 24),
        ld_x(xlen, S1, SP, 16),
        ld_x(xlen, S0, SP, 8),
        ld_x(xlen, RA, SP, 0),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: 64,
        },
        ret(),
    ]);

    Node {
        purpose: Purpose::VirtioBlk,
        ops,
    }
}
