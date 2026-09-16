// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Same-guest Linux entry: `satp=0`, `a0=hartid`, `a1=FDT`, jump to an Image.
//! Does not copy over the BIOS and does not load a real OpenWrt kernel.

use crate::encode::{
    A0, A1, A2, A3, A7, CSR_SATP, CSR_SIE, CSR_TIME, RA, S0, S1, S2, S3, S4, S5, S6, SBI_PUTCHAR,
    SP, T0, T1, T2, T3, T4, T5, TP, X0,
};
use crate::{Addr, Module, Node, Op, Purpose};

/// Image window then FDT window inside `__linux_load`.
pub const IMAGE_CAP: u64 = 0x2000;
pub const FDT_CAP: u64 = 0x400;
/// Platform watchdog record at the end of `__linux_load` (`armed` + `deadline`).
/// Independent of `sie`; `trap_timer` cannot run after `LinuxEnter`.
pub const WDT_BYTES: u64 = 8;
pub const LOAD_BYTES: u64 = IMAGE_CAP + FDT_CAP + WDT_BYTES;
/// Little-endian `G6WD`.
pub const WDT_MAGIC: u32 = u32::from_le_bytes(*b"G6WD");
/// `mtime` ticks after arm before the platform WDT fires.
pub const WDT_TICKS: i64 = 0x2_0000;
pub const WDT_ARMED_OFF: i32 = 0;
pub const WDT_DEADLINE_OFF: i32 = 4;
/// First LBA after firmware B (`FirmwareLayout::BIOS` slot B ends at 40).
pub const DISK_IMAGE_LBA: i64 = 40;

fn putc_str(ops: &mut Vec<Op>, s: &str) {
    for ch in s.bytes() {
        ops.extend([
            Op::Li {
                rd: A0,
                imm: i64::from(ch),
            },
            Op::Li {
                rd: A7,
                imm: SBI_PUTCHAR,
            },
            Op::Ecall,
        ]);
    }
}

/// `LinuxEnter(a0=entry, a1=dtb)` — Linux S-mode entry ABI, then `jalr` entry.
pub fn linux_enter_node() -> Node {
    Node {
        purpose: Purpose::LinuxHandoff,
        ops: vec![
            Op::Comment(
                "LinuxEnter — RFB/KVM must already be idle; arm platform WDT, satp=0, sie=0, a0=hartid (tp), a1=FDT, jalr entry"
                    .into(),
            ),
            Op::Glob("LinuxEnter".into()),
            Op::Label("LinuxEnter".into()),
            Op::Addi {
                rd: T2,
                rs: A0,
                imm: 0,
            },
            Op::Addi {
                rd: T3,
                rs: A1,
                imm: 0,
            },
            Op::Csrrs {
                rd: T0,
                csr: CSR_TIME,
                rs: X0,
            },
            Op::Li {
                rd: T4,
                imm: WDT_TICKS,
            },
            Op::Add {
                rd: T0,
                rs1: T0,
                rs2: T4,
            },
            Op::La {
                rd: T1,
                addr: Addr::Wdt,
            },
            Op::Sw {
                rs2: T0,
                rs1: T1,
                off: WDT_DEADLINE_OFF,
            },
            Op::Li {
                rd: T0,
                imm: i64::from(WDT_MAGIC),
            },
            Op::Sw {
                rs2: T0,
                rs1: T1,
                off: WDT_ARMED_OFF,
            },
            Op::Csrrw {
                rd: X0,
                csr: CSR_SATP,
                rs: X0,
            },
            Op::SfenceVma,
            Op::Csrrw {
                rd: X0,
                csr: CSR_SIE,
                rs: X0,
            },
            Op::Addi {
                rd: A0,
                rs: TP,
                imm: 0,
            },
            Op::Addi {
                rd: A1,
                rs: T3,
                imm: 0,
            },
            Op::FenceI,
            Op::Jalr {
                rd: X0,
                rs: T2,
                imm: 0,
            },
        ],
    }
}

/// Canary Image body: checks satp/a0/a1 then prints `LINUX-ENTRY-OK`.
pub fn linux_stub_node() -> Node {
    let mut ops = vec![
        Op::Comment("LinuxStub — canary, not a real kernel".into()),
        Op::Glob("LinuxStub".into()),
        Op::Label("LinuxStub".into()),
        Op::Csrrs {
            rd: T0,
            csr: CSR_SATP,
            rs: X0,
        },
        Op::Bne {
            rs1: T0,
            rs2: X0,
            to: "linux_stub_fail".into(),
        },
        Op::Bne {
            rs1: A0,
            rs2: X0,
            to: "linux_stub_fail".into(),
        },
        Op::Lbu {
            rd: T0,
            rs: A1,
            off: 0,
        },
        Op::Li { rd: T1, imm: 0xd0 },
        Op::Bne {
            rs1: T0,
            rs2: T1,
            to: "linux_stub_fail".into(),
        },
        Op::Lbu {
            rd: T0,
            rs: A1,
            off: 1,
        },
        Op::Li { rd: T1, imm: 0x0d },
        Op::Bne {
            rs1: T0,
            rs2: T1,
            to: "linux_stub_fail".into(),
        },
        Op::Lbu {
            rd: T0,
            rs: A1,
            off: 2,
        },
        Op::Li { rd: T1, imm: 0xfe },
        Op::Bne {
            rs1: T0,
            rs2: T1,
            to: "linux_stub_fail".into(),
        },
        Op::Lbu {
            rd: T0,
            rs: A1,
            off: 3,
        },
        Op::Li { rd: T1, imm: 0xed },
        Op::Bne {
            rs1: T0,
            rs2: T1,
            to: "linux_stub_fail".into(),
        },
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -32,
        },
        Op::Li {
            rd: T0,
            imm: i64::from(b'g'),
        },
        Op::Sb {
            rs2: T0,
            rs1: SP,
            off: 0,
        },
        Op::Li {
            rd: T0,
            imm: i64::from(b'6'),
        },
        Op::Sb {
            rs2: T0,
            rs1: SP,
            off: 1,
        },
        Op::Li {
            rd: T0,
            imm: i64::from(b'b'),
        },
        Op::Sb {
            rs2: T0,
            rs1: SP,
            off: 2,
        },
        Op::Li {
            rd: T0,
            imm: i64::from(b','),
        },
        Op::Sb {
            rs2: T0,
            rs1: SP,
            off: 3,
        },
        Op::Li {
            rd: T0,
            imm: i64::from(b'b'),
        },
        Op::Sb {
            rs2: T0,
            rs1: SP,
            off: 4,
        },
        Op::Li {
            rd: T0,
            imm: i64::from(b'o'),
        },
        Op::Sb {
            rs2: T0,
            rs1: SP,
            off: 5,
        },
        Op::Sb {
            rs2: T0,
            rs1: SP,
            off: 6,
        },
        Op::Li {
            rd: T0,
            imm: i64::from(b't'),
        },
        Op::Sb {
            rs2: T0,
            rs1: SP,
            off: 7,
        },
        Op::Li {
            rd: T0,
            imm: i64::from(b'-'),
        },
        Op::Sb {
            rs2: T0,
            rs1: SP,
            off: 8,
        },
        Op::Li {
            rd: T0,
            imm: i64::from(b'h'),
        },
        Op::Sb {
            rs2: T0,
            rs1: SP,
            off: 9,
        },
        Op::Li {
            rd: T0,
            imm: i64::from(b'e'),
        },
        Op::Sb {
            rs2: T0,
            rs1: SP,
            off: 10,
        },
        Op::Li {
            rd: T0,
            imm: i64::from(b'a'),
        },
        Op::Sb {
            rs2: T0,
            rs1: SP,
            off: 11,
        },
        Op::Li {
            rd: T0,
            imm: i64::from(b'l'),
        },
        Op::Sb {
            rs2: T0,
            rs1: SP,
            off: 12,
        },
        Op::Li {
            rd: T0,
            imm: i64::from(b't'),
        },
        Op::Sb {
            rs2: T0,
            rs1: SP,
            off: 13,
        },
        Op::Li {
            rd: T0,
            imm: i64::from(b'h'),
        },
        Op::Sb {
            rs2: T0,
            rs1: SP,
            off: 14,
        },
        Op::Li {
            rd: T0,
            imm: i64::from(b'-'),
        },
        Op::Sb {
            rs2: T0,
            rs1: SP,
            off: 15,
        },
        Op::Li {
            rd: T0,
            imm: i64::from(b'1'),
        },
        Op::Sb {
            rs2: T0,
            rs1: SP,
            off: 16,
        },
        Op::Sb {
            rs2: X0,
            rs1: SP,
            off: 17,
        },
        Op::Lbu {
            rd: T0,
            rs: A1,
            off: 4,
        },
        Op::Slli {
            rd: T2,
            rs: T0,
            shamt: 8,
        },
        Op::Lbu {
            rd: T0,
            rs: A1,
            off: 5,
        },
        Op::Or {
            rd: T2,
            rs: T2,
            rs2: T0,
        },
        Op::Slli {
            rd: T2,
            rs: T2,
            shamt: 8,
        },
        Op::Lbu {
            rd: T0,
            rs: A1,
            off: 6,
        },
        Op::Or {
            rd: T2,
            rs: T2,
            rs2: T0,
        },
        Op::Slli {
            rd: T2,
            rs: T2,
            shamt: 8,
        },
        Op::Lbu {
            rd: T0,
            rs: A1,
            off: 7,
        },
        Op::Or {
            rd: T2,
            rs: T2,
            rs2: T0,
        },
        Op::Li { rd: T0, imm: 40 },
        Op::Bltu {
            rs1: T2,
            rs2: T0,
            to: "linux_stub_entry".into(),
        },
        Op::Li {
            rd: T0,
            imm: FDT_CAP as i64,
        },
        Op::Bltu {
            rs1: T0,
            rs2: T2,
            to: "linux_stub_entry".into(),
        },
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: -18,
        },
        Op::Li { rd: T3, imm: 0 },
        Op::Label("linux_stub_scan".into()),
        Op::Bgeu {
            rs1: T3,
            rs2: T2,
            to: "linux_stub_entry".into(),
        },
        Op::Li { rd: T4, imm: 0 },
        Op::Label("linux_stub_cmp".into()),
        Op::Li { rd: T0, imm: 18 },
        Op::Bgeu {
            rs1: T4,
            rs2: T0,
            to: "linux_stub_health".into(),
        },
        Op::Add {
            rd: T5,
            rs1: A1,
            rs2: T3,
        },
        Op::Add {
            rd: T5,
            rs1: T5,
            rs2: T4,
        },
        Op::Lbu {
            rd: T0,
            rs: T5,
            off: 0,
        },
        Op::Add {
            rd: T5,
            rs1: SP,
            rs2: T4,
        },
        Op::Lbu {
            rd: T1,
            rs: T5,
            off: 0,
        },
        Op::Bne {
            rs1: T0,
            rs2: T1,
            to: "linux_stub_next".into(),
        },
        Op::Addi {
            rd: T4,
            rs: T4,
            imm: 1,
        },
        Op::Jal {
            rd: X0,
            to: "linux_stub_cmp".into(),
        },
        Op::Label("linux_stub_next".into()),
        Op::Addi {
            rd: T3,
            rs: T3,
            imm: 1,
        },
        Op::Jal {
            rd: X0,
            to: "linux_stub_scan".into(),
        },
        Op::Label("linux_stub_health".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: 32,
        },
    ];
    putc_str(&mut ops, "LINUX-HEALTH-OK\n");
    ops.extend([
        Op::Jal {
            rd: X0,
            to: "linux_stub_ok".into(),
        },
        Op::Label("linux_stub_entry".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: 32,
        },
        Op::Label("linux_stub_ok".into()),
    ]);
    putc_str(&mut ops, "LINUX-ENTRY-OK\n");
    ops.extend([
        Op::Label("linux_stub_hold".into()),
        Op::Wfi,
        Op::Jal {
            rd: X0,
            to: "linux_stub_hold".into(),
        },
        Op::Label("linux_stub_fail".into()),
    ]);
    putc_str(&mut ops, "LINUX-ENTRY-FAIL\n");
    ops.extend([Op::Jal {
        rd: X0,
        to: "linux_stub_hold".into(),
    }]);
    Node {
        purpose: Purpose::LinuxHandoff,
        ops,
    }
}

/// Build an FDT magic on the stack and `jal LinuxEnter` to `LinuxStub`.
pub fn linux_enter_selftest_node() -> Node {
    Node {
        purpose: Purpose::LinuxHandoff,
        ops: vec![
            Op::Comment("test: a1=FDT magic on stack, a0=LinuxStub".into()),
            Op::Label("LinuxEnterSelftest".into()),
            Op::Addi {
                rd: crate::encode::SP,
                rs: crate::encode::SP,
                imm: -16,
            },
            Op::Li { rd: T0, imm: 0xd0 },
            Op::Sb {
                rs2: T0,
                rs1: crate::encode::SP,
                off: 0,
            },
            Op::Li { rd: T0, imm: 0x0d },
            Op::Sb {
                rs2: T0,
                rs1: crate::encode::SP,
                off: 1,
            },
            Op::Li { rd: T0, imm: 0xfe },
            Op::Sb {
                rs2: T0,
                rs1: crate::encode::SP,
                off: 2,
            },
            Op::Li { rd: T0, imm: 0xed },
            Op::Sb {
                rs2: T0,
                rs1: crate::encode::SP,
                off: 3,
            },
            Op::Addi {
                rd: A1,
                rs: crate::encode::SP,
                imm: 0,
            },
            Op::La {
                rd: A0,
                addr: crate::Addr::Label("LinuxStub".into()),
            },
            Op::Jal {
                rd: RA,
                to: "LinuxEnter".into(),
            },
        ],
    }
}

/// Hang after `LinuxEnter` with `sie=0`. The platform WDT must still fire.
pub fn linux_hang_selftest_node() -> Node {
    Node {
        purpose: Purpose::LinuxHandoff,
        ops: vec![
            Op::Comment("test: LinuxEnter a WFI hang; platform WDT fires with sie=0".into()),
            Op::Label("LinuxHangSelftest".into()),
            Op::Addi {
                rd: SP,
                rs: SP,
                imm: -16,
            },
            Op::Li { rd: T0, imm: 0xd0 },
            Op::Sb {
                rs2: T0,
                rs1: SP,
                off: 0,
            },
            Op::Li { rd: T0, imm: 0x0d },
            Op::Sb {
                rs2: T0,
                rs1: SP,
                off: 1,
            },
            Op::Li { rd: T0, imm: 0xfe },
            Op::Sb {
                rs2: T0,
                rs1: SP,
                off: 2,
            },
            Op::Li { rd: T0, imm: 0xed },
            Op::Sb {
                rs2: T0,
                rs1: SP,
                off: 3,
            },
            Op::Addi {
                rd: A1,
                rs: SP,
                imm: 0,
            },
            Op::La {
                rd: A0,
                addr: Addr::Label("LinuxHangStub".into()),
            },
            Op::Jal {
                rd: RA,
                to: "LinuxEnter".into(),
            },
            Op::Label("LinuxHangStub".into()),
            Op::Wfi,
            Op::Jal {
                rd: X0,
                to: "LinuxHangStub".into(),
            },
        ],
    }
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

fn memcpy_bytes(ops: &mut Vec<Op>, dst: u32, src: u32, len: u32, again: &str, done: &str) {
    ops.extend([
        Op::Beq {
            rs1: len,
            rs2: X0,
            to: done.into(),
        },
        Op::Addi {
            rd: T0,
            rs: dst,
            imm: 0,
        },
        Op::Addi {
            rd: T1,
            rs: src,
            imm: 0,
        },
        Op::Addi {
            rd: T2,
            rs: len,
            imm: 0,
        },
        Op::Label(again.into()),
        Op::Lbu {
            rd: T3,
            rs: T1,
            off: 0,
        },
        Op::Sb {
            rs2: T3,
            rs1: T0,
            off: 0,
        },
        Op::Addi {
            rd: T0,
            rs: T0,
            imm: 1,
        },
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: 1,
        },
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: -1,
        },
        Op::Bne {
            rs1: T2,
            rs2: X0,
            to: again.into(),
        },
        Op::Label(done.into()),
    ]);
}

/// `LinuxRelocate(a0=src_img, a1=src_dtb, a2=img_len, a3=dtb_len)` copies into
/// reserved BSS that does not overlap the running payload, then `LinuxEnter`.
pub fn linux_relocate_node(xlen: u32, dest_off: u64) -> Node {
    let mut ops = vec![
        Op::Comment(format!(
            "LinuxRelocate — copy Image+FDT to stacks_end+{dest_off:#x}, refuse overlap"
        )),
        Op::Glob("LinuxRelocate".into()),
        Op::Label("LinuxRelocate".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -56,
        },
        st_x(xlen, RA, SP, 0),
        st_x(xlen, S0, SP, 8),
        st_x(xlen, S1, SP, 16),
        st_x(xlen, S2, SP, 24),
        st_x(xlen, S3, SP, 32),
        st_x(xlen, S4, SP, 40),
        st_x(xlen, S5, SP, 48),
        Op::Addi {
            rd: S0,
            rs: A0,
            imm: 0,
        },
        Op::Addi {
            rd: S1,
            rs: A1,
            imm: 0,
        },
        Op::Addi {
            rd: S2,
            rs: A2,
            imm: 0,
        },
        Op::Addi {
            rd: S3,
            rs: A3,
            imm: 0,
        },
        Op::La {
            rd: T0,
            addr: Addr::StacksEnd,
        },
        Op::Li {
            rd: T1,
            imm: dest_off as i64,
        },
        Op::Add {
            rd: S4,
            rs1: T0,
            rs2: T1,
        },
        Op::Li {
            rd: T1,
            imm: IMAGE_CAP as i64,
        },
        Op::Add {
            rd: S5,
            rs1: S4,
            rs2: T1,
        },
        Op::Beq {
            rs1: S2,
            rs2: X0,
            to: "linux_rel_fail".into(),
        },
        Op::Bltu {
            rs1: T1,
            rs2: S2,
            to: "linux_rel_fail".into(),
        },
        Op::Beq {
            rs1: S3,
            rs2: X0,
            to: "linux_rel_fail".into(),
        },
        Op::Li {
            rd: T1,
            imm: FDT_CAP as i64,
        },
        Op::Bltu {
            rs1: T1,
            rs2: S3,
            to: "linux_rel_fail".into(),
        },
        Op::Add {
            rd: T0,
            rs1: S4,
            rs2: S2,
        },
        Op::Bgeu {
            rs1: S0,
            rs2: T0,
            to: "linux_rel_no_img".into(),
        },
        Op::Add {
            rd: T1,
            rs1: S0,
            rs2: S2,
        },
        Op::Bgeu {
            rs1: S4,
            rs2: T1,
            to: "linux_rel_no_img".into(),
        },
        Op::Jal {
            rd: X0,
            to: "linux_rel_overlap".into(),
        },
        Op::Label("linux_rel_no_img".into()),
        Op::Add {
            rd: T0,
            rs1: S5,
            rs2: S3,
        },
        Op::Bgeu {
            rs1: S1,
            rs2: T0,
            to: "linux_rel_copy".into(),
        },
        Op::Add {
            rd: T1,
            rs1: S1,
            rs2: S3,
        },
        Op::Bgeu {
            rs1: S5,
            rs2: T1,
            to: "linux_rel_copy".into(),
        },
        Op::Jal {
            rd: X0,
            to: "linux_rel_overlap".into(),
        },
        Op::Label("linux_rel_copy".into()),
    ];
    memcpy_bytes(&mut ops, S4, S0, S2, "linux_rel_img", "linux_rel_img_done");
    memcpy_bytes(&mut ops, S5, S1, S3, "linux_rel_fdt", "linux_rel_fdt_done");
    ops.extend([
        Op::Addi {
            rd: A0,
            rs: S4,
            imm: 0,
        },
        Op::Addi {
            rd: A1,
            rs: S5,
            imm: 0,
        },
        Op::Jal {
            rd: RA,
            to: "LinuxEnter".into(),
        },
        Op::Label("linux_rel_overlap".into()),
    ]);
    putc_str(&mut ops, "LINUX-LOAD-OVERLAP\n");
    ops.extend([
        Op::Jal {
            rd: X0,
            to: "linux_rel_out".into(),
        },
        Op::Label("linux_rel_fail".into()),
    ]);
    putc_str(&mut ops, "LINUX-LOAD-FAIL\n");
    ops.extend([
        Op::Label("linux_rel_out".into()),
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
            imm: 56,
        },
        Op::Jalr {
            rd: X0,
            rs: RA,
            imm: 0,
        },
    ]);
    Node {
        purpose: Purpose::LinuxHandoff,
        ops,
    }
}

/// Copy `LinuxStub` + stack FDT into the reserved window, then enter.
pub fn linux_relocate_selftest_node() -> Node {
    Node {
        purpose: Purpose::LinuxHandoff,
        ops: vec![
            Op::Comment("test: relocate LinuxStub+FDT into reserved BSS".into()),
            Op::Label("LinuxRelocateSelftest".into()),
            Op::Addi {
                rd: SP,
                rs: SP,
                imm: -16,
            },
            Op::Li { rd: T0, imm: 0xd0 },
            Op::Sb {
                rs2: T0,
                rs1: SP,
                off: 0,
            },
            Op::Li { rd: T0, imm: 0x0d },
            Op::Sb {
                rs2: T0,
                rs1: SP,
                off: 1,
            },
            Op::Li { rd: T0, imm: 0xfe },
            Op::Sb {
                rs2: T0,
                rs1: SP,
                off: 2,
            },
            Op::Li { rd: T0, imm: 0xed },
            Op::Sb {
                rs2: T0,
                rs1: SP,
                off: 3,
            },
            Op::La {
                rd: A0,
                addr: Addr::Label("LinuxStub".into()),
            },
            Op::Addi {
                rd: A1,
                rs: SP,
                imm: 0,
            },
            Op::Li { rd: A2, imm: 0x800 },
            Op::Li { rd: A3, imm: 8 },
            Op::Jal {
                rd: RA,
                to: "LinuxRelocate".into(),
            },
        ],
    }
}

/// Source equals dest → overlap refuse, then continue.
pub fn linux_relocate_overlap_selftest_node(dest_off: u64) -> Node {
    Node {
        purpose: Purpose::LinuxHandoff,
        ops: vec![
            Op::Comment("test: relocate src==dest must print LINUX-LOAD-OVERLAP".into()),
            Op::Label("LinuxRelocateOverlapSelftest".into()),
            Op::Addi {
                rd: SP,
                rs: SP,
                imm: -16,
            },
            Op::Li { rd: T0, imm: 0xd0 },
            Op::Sb {
                rs2: T0,
                rs1: SP,
                off: 0,
            },
            Op::Addi {
                rd: A1,
                rs: SP,
                imm: 0,
            },
            Op::La {
                rd: T0,
                addr: Addr::StacksEnd,
            },
            Op::Li {
                rd: T1,
                imm: dest_off as i64,
            },
            Op::Add {
                rd: A0,
                rs1: T0,
                rs2: T1,
            },
            Op::Li { rd: A2, imm: 16 },
            Op::Li { rd: A3, imm: 4 },
            Op::Jal {
                rd: RA,
                to: "LinuxRelocate".into(),
            },
        ],
    }
}

/// `LinuxLoadDisk(a0=img_lba, a1=img_sectors, a2=dtb_lba, a3=dtb_sectors)`
/// reads those sectors into `__linux_load` then `LinuxEnter`s `dest+text_offset`.
pub fn linux_load_disk_node(xlen: u32, dest_off: u64) -> Node {
    use crate::vio::{BLK_BASE, BLK_DATA_OFF};
    let mut ops = vec![
        Op::Comment("LinuxLoadDisk — BlkRead Image+FDT into reserved BSS, then enter".into()),
        Op::Glob("LinuxLoadDisk".into()),
        Op::Label("LinuxLoadDisk".into()),
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
        Op::Addi {
            rd: S0,
            rs: A0,
            imm: 0,
        },
        Op::Addi {
            rd: S1,
            rs: A1,
            imm: 0,
        },
        Op::Addi {
            rd: S2,
            rs: A2,
            imm: 0,
        },
        Op::Addi {
            rd: S3,
            rs: A3,
            imm: 0,
        },
        Op::La {
            rd: T0,
            addr: Addr::StacksEnd,
        },
        Op::Li {
            rd: T1,
            imm: dest_off as i64,
        },
        Op::Add {
            rd: S4,
            rs1: T0,
            rs2: T1,
        },
        Op::Li {
            rd: T1,
            imm: IMAGE_CAP as i64,
        },
        Op::Add {
            rd: S5,
            rs1: S4,
            rs2: T1,
        },
        Op::Beq {
            rs1: S1,
            rs2: X0,
            to: "linux_ld_fail".into(),
        },
        Op::Li {
            rd: T0,
            imm: (IMAGE_CAP / 512) as i64,
        },
        Op::Bltu {
            rs1: T0,
            rs2: S1,
            to: "linux_ld_fail".into(),
        },
        Op::Beq {
            rs1: S3,
            rs2: X0,
            to: "linux_ld_fail".into(),
        },
        Op::Li {
            rd: T0,
            imm: (FDT_CAP / 512) as i64,
        },
        Op::Bltu {
            rs1: T0,
            rs2: S3,
            to: "linux_ld_fail".into(),
        },
        Op::Li { rd: S6, imm: 0 },
        Op::Label("linux_ld_img".into()),
        Op::Bgeu {
            rs1: S6,
            rs2: S1,
            to: "linux_ld_img_done".into(),
        },
        Op::Add {
            rd: A0,
            rs1: S0,
            rs2: S6,
        },
        Op::Jal {
            rd: RA,
            to: "BlkRead".into(),
        },
        Op::Beq {
            rs1: A0,
            rs2: X0,
            to: "linux_ld_fail".into(),
        },
        Op::Slli {
            rd: T0,
            rs: S6,
            shamt: 9,
        },
        Op::Add {
            rd: A0,
            rs1: S4,
            rs2: T0,
        },
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
        Op::Li {
            rd: T1,
            imm: BLK_BASE,
        },
        Op::Add {
            rd: T5,
            rs1: T5,
            rs2: T1,
        },
        Op::Addi {
            rd: A1,
            rs: T5,
            imm: BLK_DATA_OFF,
        },
        Op::Li { rd: A2, imm: 512 },
    ];
    memcpy_bytes(
        &mut ops,
        A0,
        A1,
        A2,
        "linux_ld_icopy",
        "linux_ld_icopy_done",
    );
    ops.extend([
        Op::Addi {
            rd: S6,
            rs: S6,
            imm: 1,
        },
        Op::Jal {
            rd: X0,
            to: "linux_ld_img".into(),
        },
        Op::Label("linux_ld_img_done".into()),
        Op::Li { rd: S6, imm: 0 },
        Op::Label("linux_ld_dtb".into()),
        Op::Bgeu {
            rs1: S6,
            rs2: S3,
            to: "linux_ld_dtb_done".into(),
        },
        Op::Add {
            rd: A0,
            rs1: S2,
            rs2: S6,
        },
        Op::Jal {
            rd: RA,
            to: "BlkRead".into(),
        },
        Op::Beq {
            rs1: A0,
            rs2: X0,
            to: "linux_ld_fail".into(),
        },
        Op::Slli {
            rd: T0,
            rs: S6,
            shamt: 9,
        },
        Op::Add {
            rd: A0,
            rs1: S5,
            rs2: T0,
        },
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
        Op::Li {
            rd: T1,
            imm: BLK_BASE,
        },
        Op::Add {
            rd: T5,
            rs1: T5,
            rs2: T1,
        },
        Op::Addi {
            rd: A1,
            rs: T5,
            imm: BLK_DATA_OFF,
        },
        Op::Li { rd: A2, imm: 512 },
    ]);
    memcpy_bytes(
        &mut ops,
        A0,
        A1,
        A2,
        "linux_ld_dcopy",
        "linux_ld_dcopy_done",
    );
    ops.extend([
        Op::Addi {
            rd: S6,
            rs: S6,
            imm: 1,
        },
        Op::Jal {
            rd: X0,
            to: "linux_ld_dtb".into(),
        },
        Op::Label("linux_ld_dtb_done".into()),
        Op::Li {
            rd: A0,
            imm: crate::vio::BLK_JRN_LBA,
        },
        Op::Jal {
            rd: RA,
            to: "BlkRead".into(),
        },
        Op::Jal {
            rd: RA,
            to: "linux_ld_check".into(),
        },
        Op::Bne {
            rs1: A0,
            rs2: X0,
            to: "linux_ld_armed".into(),
        },
        Op::Li {
            rd: A0,
            imm: crate::vio::BLK_JRN_LBA + 8,
        },
        Op::Jal {
            rd: RA,
            to: "BlkRead".into(),
        },
        Op::Jal {
            rd: RA,
            to: "linux_ld_check".into(),
        },
        Op::Beq {
            rs1: A0,
            rs2: X0,
            to: "linux_ld_hold".into(),
        },
        Op::Label("linux_ld_armed".into()),
        ld_x(xlen, T0, S4, 8),
        Op::Add {
            rd: A0,
            rs1: S4,
            rs2: T0,
        },
        Op::Addi {
            rd: A1,
            rs: S5,
            imm: 0,
        },
        Op::Jal {
            rd: RA,
            to: "LinuxEnter".into(),
        },
        Op::Label("linux_ld_check".into()),
        Op::Beq {
            rs1: A0,
            rs2: X0,
            to: "linux_ld_check_no".into(),
        },
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
        Op::Li {
            rd: T1,
            imm: crate::vio::BLK_BASE,
        },
        Op::Add {
            rd: T5,
            rs1: T5,
            rs2: T1,
        },
        Op::Lbu {
            rd: T0,
            rs: T5,
            off: crate::vio::BLK_DATA_OFF,
        },
        Op::Li {
            rd: T1,
            imm: i64::from(b'G'),
        },
        Op::Bne {
            rs1: T0,
            rs2: T1,
            to: "linux_ld_check_no".into(),
        },
        Op::Lbu {
            rd: T0,
            rs: T5,
            off: crate::vio::BLK_DATA_OFF + 1,
        },
        Op::Li {
            rd: T1,
            imm: i64::from(b'6'),
        },
        Op::Bne {
            rs1: T0,
            rs2: T1,
            to: "linux_ld_check_no".into(),
        },
        Op::Lbu {
            rd: T0,
            rs: T5,
            off: crate::vio::BLK_DATA_OFF + 2,
        },
        Op::Li {
            rd: T1,
            imm: i64::from(b'B'),
        },
        Op::Bne {
            rs1: T0,
            rs2: T1,
            to: "linux_ld_check_no".into(),
        },
        Op::Lbu {
            rd: T0,
            rs: T5,
            off: crate::vio::BLK_DATA_OFF + 3,
        },
        Op::Li {
            rd: T1,
            imm: i64::from(b'H'),
        },
        Op::Bne {
            rs1: T0,
            rs2: T1,
            to: "linux_ld_check_no".into(),
        },
        Op::Lbu {
            rd: T0,
            rs: T5,
            off: crate::vio::BLK_DATA_OFF + 17,
        },
        Op::Li { rd: T1, imm: 1 },
        Op::Bne {
            rs1: T0,
            rs2: T1,
            to: "linux_ld_check_no".into(),
        },
        Op::Li { rd: A0, imm: 1 },
        Op::Jalr {
            rd: X0,
            rs: RA,
            imm: 0,
        },
        Op::Label("linux_ld_check_no".into()),
        Op::Li { rd: A0, imm: 0 },
        Op::Jalr {
            rd: X0,
            rs: RA,
            imm: 0,
        },
        Op::Label("linux_ld_hold".into()),
    ]);
    putc_str(&mut ops, "LINUX-HOLD\n");
    ops.extend([
        Op::Jal {
            rd: X0,
            to: "linux_ld_out".into(),
        },
        Op::Label("linux_ld_fail".into()),
    ]);
    putc_str(&mut ops, "LINUX-LOAD-FAIL\n");
    ops.extend([
        Op::Label("linux_ld_out".into()),
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
        Op::Jalr {
            rd: X0,
            rs: RA,
            imm: 0,
        },
    ]);
    Node {
        purpose: Purpose::LinuxHandoff,
        ops,
    }
}

/// Call `LinuxLoadDisk` for the planted canary Image at [`DISK_IMAGE_LBA`].
pub fn linux_load_disk_selftest_node() -> Node {
    Node {
        purpose: Purpose::LinuxHandoff,
        ops: vec![
            Op::Comment("test: BlkRead canary Image+FDT from LBA 40, then enter".into()),
            Op::Label("LinuxLoadDiskSelftest".into()),
            Op::Li {
                rd: A0,
                imm: DISK_IMAGE_LBA,
            },
            Op::Li { rd: A1, imm: 4 },
            Op::Li {
                rd: A2,
                imm: DISK_IMAGE_LBA + 4,
            },
            Op::Li { rd: A3, imm: 1 },
            Op::Jal {
                rd: RA,
                to: "LinuxLoadDisk".into(),
            },
        ],
    }
}

/// Canary RISC-V Image (header + `LinuxStub` body) for disk plant/tests.
pub fn canary_image() -> Vec<u8> {
    let mut stub_mod = Module {
        nharts: 1,
        ..Default::default()
    };
    stub_mod.push(linux_stub_node());
    let (words, _) = stub_mod.to_words(0).expect("canary stub assembles");
    let mut body = Vec::new();
    for w in words {
        body.extend_from_slice(&w.to_le_bytes());
    }
    let mut img = vec![0u8; 0x40];
    img[8..16].copy_from_slice(&0x40u64.to_le_bytes());
    img[0x10..0x18].copy_from_slice(&((0x40 + body.len()) as u64).to_le_bytes());
    img[0x30..0x38].copy_from_slice(b"RISCV\0\0\0");
    img[0x38..0x3c].copy_from_slice(b"RSC\x05");
    img.extend_from_slice(&body);
    img
}

/// Plant the canary Image at LBA 40 and the health-handoff FDT at LBA 44.
/// Firmware A/B and the journal window are left untouched.
pub fn plant_canary(disk: &mut [u8]) -> Result<(), &'static str> {
    let img = canary_image();
    let off = DISK_IMAGE_LBA as usize * 512;
    let fdt = (DISK_IMAGE_LBA as usize + 4) * 512;
    let blob = g6b_boot_health::encode_handoff(g6b_boot_health::HealthHandoff::BIOS);
    if blob.len() > FDT_CAP as usize {
        return Err("health FDT exceeds FDT_CAP");
    }
    if disk.len() < fdt + blob.len() {
        return Err("disk too small for canary Image+FDT");
    }
    if off + img.len() > fdt {
        return Err("canary Image overlaps FDT LBA");
    }
    disk[off..off + img.len()].copy_from_slice(&img);
    disk[fdt..fdt + blob.len()].copy_from_slice(&blob);
    Ok(())
}
