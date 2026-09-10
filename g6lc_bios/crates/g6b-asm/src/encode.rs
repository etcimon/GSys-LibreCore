// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! RISC-V encodings used by IR lowering. No x86.

#![allow(missing_docs)]

pub const X0: u32 = 0;
pub const RA: u32 = 1;
pub const SP: u32 = 2;
pub const TP: u32 = 4;
pub const T0: u32 = 5;
pub const T1: u32 = 6;
pub const T2: u32 = 7;
pub const S0: u32 = 8;
pub const S1: u32 = 9;
pub const A0: u32 = 10;
pub const A1: u32 = 11;
pub const A2: u32 = 12;
pub const A3: u32 = 13;
pub const A4: u32 = 14;
pub const A5: u32 = 15;
pub const A6: u32 = 16;
pub const A7: u32 = 17;
pub const S2: u32 = 18;
pub const S3: u32 = 19;
pub const S4: u32 = 20;
pub const S5: u32 = 21;
pub const S6: u32 = 22;
pub const S7: u32 = 23;
pub const S8: u32 = 24;
pub const S9: u32 = 25;
pub const S10: u32 = 26;
pub const S11: u32 = 27;
pub const T3: u32 = 28;
pub const T4: u32 = 29;
pub const T5: u32 = 30;
pub const T6: u32 = 31;

pub const CSR_SSTATUS: u32 = 0x100;
pub const CSR_SIE: u32 = 0x104;
pub const CSR_STVEC: u32 = 0x105;
/// Supervisor address-translation (`satp`). Bare = 0 (Priv ch. 4).
pub const CSR_SATP: u32 = 0x180;
pub const CSR_SEPC: u32 = 0x141;
pub const CSR_SCAUSE: u32 = 0x142;
/// Supervisor trap value (`stval`) — fault address on access faults.
pub const CSR_STVAL: u32 = 0x143;
/// Unprivileged `time` CSR (`rdtime`). S-mode; OpenSBI may trap-and-emulate.
pub const CSR_TIME: u32 = 0xC01;
pub const SRET: u32 = 0x1020_0073;
/// `sie` / `sstatus` bits: supervisor timer + global SIE (Priv spec ch. 3).
/// `sie` supervisor software interrupt (SSI / SBI IPI wake).
pub const SIE_SSIE: i64 = 1 << 1;
pub const SIE_STIE: i64 = 1 << 5;
/// `sie` supervisor external interrupt (PLIC / SEI, Priv ch. 3).
pub const SIE_SEIE: i64 = 1 << 9;
pub const SSTATUS_SIE: i64 = 1 << 1;
/// QEMU virt / SiFive PLIC. S-mode context for hart `h` is `2*h + 1`:
/// enable block `+0x2000 + ctx*0x80`, claim/threshold page `+0x200000 +
/// ctx*0x1000` (ctx1 = hart0 shown for reference).
pub const PLIC_BASE: u64 = 0x0c00_0000;
pub const PLIC_ENABLE_BASE: u64 = PLIC_BASE + 0x2000;
pub const PLIC_CTXT_BASE: u64 = PLIC_BASE + 0x20_0000;
pub const PLIC_ENABLE_S0: u64 = PLIC_ENABLE_BASE + 0x80;
pub const PLIC_THRESH_S0: u64 = PLIC_CTXT_BASE + 0x1000;
pub const PLIC_CLAIM_S0: u64 = PLIC_CTXT_BASE + 0x1004;
/// QEMU virt ns16550 UART0 PLIC line — `interrupts = <0x0a>` in the
/// machine DTB (not COM1, and *not* irq 1: that is virtio-mmio slot 0).
pub const UART_IRQ: i64 = 10;
/// ns16550 IER received-data bit (`ERBFI`).
pub const UART_IER_RX: i64 = 1;
/// ns16550 LSR data-ready bit.
pub const UART_LSR_DR: i64 = 1;
/// Sideband mailbox (not a netdev). Matches generated `g6lc_bios_mbox.h`.
pub const MBOX_MAGIC: u32 = 0x4736_4d42;
pub const MBOX_OFF_DOORBELL: u64 = 0x00;
pub const MBOX_OFF_LENGTH: u64 = 0x04;
pub const MBOX_OFF_STATUS: u64 = 0x08;
pub const MBOX_OFF_IRQ_EN: u64 = 0x0c;
pub const MBOX_OFF_CMD: u64 = 0x10;
pub const MBOX_OFF_RSP: u64 = 0x110;
pub const MBOX_CMD_BYTES: u64 = 0x100;
pub const MBOX_RSP_BYTES: u64 = 0x100;
pub const MBOX_ST_BUSY: u32 = 0x1;
pub const MBOX_ST_RSP: u32 = 0x2;
pub const MBOX_ST_DELEG: u32 = 0x4;
/// Linux `write()` doorbell kick (not the `G6MB` identity word).
pub const MBOX_KICK: u32 = 1;
/// Little-endian `VIEW` / `WAKE` / `UI` / `FILE` / `KEYS` response words.
pub const MBOX_RSP_VIEW: u32 = 0x5745_4956;
pub const MBOX_RSP_WAKE: u32 = 0x454b_4157;
pub const MBOX_RSP_UI: u32 = 0x000a_4955;
pub const MBOX_RSP_FILE: u32 = 0x454c_4946;
pub const MBOX_RSP_KEYS: u32 = 0x5359_454b;
/// SysGrInit plane magic `GR16` (640×480×16; not VGA).
pub const GR16_MAGIC: u32 = 0x3631_5247;
/// Guest UI blob ident at `__ui_blob` (`G6UI`).
pub const UI_MAGIC: u32 = 0x4955_3647;
/// WASM module magic `\0asm` (little-endian), echoed at G6UI+24 after FileServe.
pub const WASM_MAGIC: u32 = 0x6d73_6100;
/// Packed 4bpp colour-1 word for the boot scanline.
pub const GR_FILL_WORD: u32 = 0x1111_1111;
/// QEMU virt virtio-mmio transports: 8 slots at `0x10001000 + 0x200*i`.
/// Register offsets: +0x00 MagicValue `0x74726976` ("virt"), +0x04 Version,
/// +0x08 DeviceID (16 = GPU). Probed read-only; virtqueues/scanout are open.
pub const VIO_MMIO_BASE: u64 = 0x1000_1000;
/// QEMU virt instantiates all 8 virtio-mmio transports at a 0x1000 stride
/// (each region is 0x200 wide; the gaps are unmapped and fault on access).
pub const VIO_MMIO_STEP: u64 = 0x1000;
pub const VIO_MMIO_SLOTS: i64 = 8;
pub const VIO_MAGIC: u32 = 0x7472_6976;
pub const VIO_DEV_GPU: u32 = 16;
/// virtio-net device id (virtio spec 5.1). Guest `VioNetProbe` enumerates it.
/// BIOS `qemu-args` never attaches `virtio-net-device` / `-netdev`.
pub const VIO_DEV_NET: u32 = 1;
/// Exec-model virtio-mmio slot for virtio-net (irq 1+slot = 6). Slots 0–3
/// are GPU / keyboard / mailbox-gap / tablet; slot 4 would collide irq 5.
pub const VIO_NET_SLOT: u64 = 5;
/// virtio-input device id (virtio spec 5.8) — `virtio-keyboard-device` /
/// `virtio-tablet-device` attach to their own virtio-mmio slot.
pub const VIO_DEV_INPUT: u32 = 18;
/// virtio-mmio register offsets (modern interface; `Version` = 2).
pub const VIO_REG_FEATURES: i32 = 0x10;
pub const VIO_REG_FEATURES_SEL: i32 = 0x14;
pub const VIO_REG_DRV_FEATURES: i32 = 0x20;
pub const VIO_REG_DRV_FEATURES_SEL: i32 = 0x24;
pub const VIO_REG_QUEUE_SEL: i32 = 0x30;
pub const VIO_REG_QUEUE_NUM_MAX: i32 = 0x34;
pub const VIO_REG_QUEUE_NUM: i32 = 0x38;
pub const VIO_REG_QUEUE_READY: i32 = 0x44;
pub const VIO_REG_QUEUE_NOTIFY: i32 = 0x50;
pub const VIO_REG_ISR_STATUS: i32 = 0x60;
pub const VIO_REG_ISR_ACK: i32 = 0x64;
pub const VIO_REG_STATUS: i32 = 0x70;
pub const VIO_REG_QUEUE_DESC: i32 = 0x80;
pub const VIO_REG_QUEUE_AVAIL: i32 = 0x90;
pub const VIO_REG_QUEUE_USED: i32 = 0xa0;
/// virtio status bits (STATUS register).
pub const VIO_ST_ACK: i32 = 1;
pub const VIO_ST_DRIVER: i32 = 2;
pub const VIO_ST_DRIVER_OK: i32 = 4;
pub const VIO_ST_FEATURES_OK: i32 = 8;
/// `VIRTIO_F_VERSION_1` — bit 32 of the feature space = bit 0 of word 1.
pub const VIO_F_VERSION_1: u32 = 1;
/// virtio-gpu ctrlq commands (`ctrl_hdr.type`; virtio spec 5.7.6).
pub const VIO_GPU_GET_DISPLAY_INFO: u32 = 0x0100;
pub const VIO_GPU_RESOURCE_CREATE_2D: u32 = 0x0101;
pub const VIO_GPU_SET_SCANOUT: u32 = 0x0103;
pub const VIO_GPU_RESOURCE_FLUSH: u32 = 0x0104;
pub const VIO_GPU_TRANSFER_TO_HOST_2D: u32 = 0x0105;
pub const VIO_GPU_RESOURCE_ATTACH_BACKING: u32 = 0x0106;
/// virtio-gpu response types (`resp_hdr.type`).
pub const VIO_GPU_RESP_OK_NODATA: u32 = 0x1100;
pub const VIO_GPU_RESP_OK_DISPLAY_INFO: u32 = 0x1101;
pub const VIO_GPU_RESP_ERR_UNSPEC: u32 = 0x1200;
/// `virtio_input_event` field values: `type` (Linux `EV_*`).
/// `InpDrain` queues `EV_KEY` into `__vio`'s bounded key queue (VGA
/// `DomNav`); `EV_ABS`/`EV_REL` are WebFeed (svelte-d pointer). The
/// statusq (queue 1) is unused — the guest is a passive consumer.
pub const VIO_INP_EV_KEY: u32 = 1;
/// Linux `EV_REL` — virtio-mouse deltas (`REL_X`/`REL_Y`).
pub const VIO_INP_EV_REL: u32 = 2;
/// Linux `EV_ABS` — virtio-tablet axes (`ABS_X`/`ABS_Y`, 0..=`VIO_ABS_MAX`).
pub const VIO_INP_EV_ABS: u32 = 3;
/// `scause` exception codes for MMIO access faults — `trap_fault` treats
/// these inside a bounded probe window as "device absent" and resumes.
pub const SCAUSE_LOAD_ACCESS: u32 = 5;
/// Store/AMO access fault (Priv ch3 table).
pub const SCAUSE_STORE_ACCESS: u32 = 7;
/// `VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM` — X8R8G8B8 little-endian words.
pub const VIO_GPU_FMT_B8G8R8X8: u32 = 2;
/// Controlq depth (descriptors) and descriptor flag bits.
pub const VIO_QUEUE_NUM: i64 = 8;
pub const VIO_DESC_NEXT: u32 = 1;
pub const VIO_DESC_WRITE: u32 = 2;
/// Little-endian 4-char UART/HolyC command prefixes.
pub const CMD_VIEW: u32 = 0x7765_6956; // "View"
pub const CMD_REBO: u32 = 0x6f62_6552; // "Rebo"
pub const CMD_SHUT: u32 = 0x7475_6853; // "Shut"
pub const CMD_WAKE: u32 = 0x656b_6157; // "Wake"
pub const CMD_UI: u32 = 0x0000_6955; // "Ui\0\0"
pub const CMD_FILE: u32 = 0x656c_6946; // "File"
pub const CMD_GET: u32 = 0x0074_6547; // "Get\0"
pub const CMD_KEYS: u32 = 0x7379_654b; // "Keys" — dump the virtio-input key queue
pub const CMD_AWAI: u32 = 0x6961_7741; // "Awai" — Await: claim a bounded pending slot
pub const CMD_THRO: u32 = 0x6f72_6854; // "Thro" — Throw: reject the newest pending await
/// SBI TIME extension id (`'TIME'`).
pub const SBI_TIME_EID: i64 = 0x5449_4d45;
/// QEMU virt / OpenSBI default timebase (Hz). Interval = TIMEBASE / fps.
pub const TIMEBASE_HZ: u64 = 10_000_000;
pub const VTYPE_E8_M1_TA_MA: u32 = 0xC0;
/// SBI `sbi_console_putchar` extension id (legacy).
pub const SBI_PUTCHAR: i64 = 1;
/// SBI SRST extension id (`'SRST'`).
pub const SBI_SRST_EID: i64 = 0x5352_5354;
/// SBI HSM extension id (`'HSM'`).
pub const SBI_HSM_EID: i64 = 0x0048_534d;
/// SBI IPI extension id (`'sPI'`).
pub const SBI_IPI_EID: i64 = 0x0073_5049;

pub fn lui(rd: u32, imm20: u32) -> u32 {
    (imm20 << 12) | (rd << 7) | 0x37
}

pub fn auipc(rd: u32, imm20: u32) -> u32 {
    (imm20 << 12) | (rd << 7) | 0x17
}

/// I/S-type immediates are 12-bit signed — trap silently-truncated offsets
/// (a `0x1000` step once encoded as `addi rd,rs,0` → an infinite rescan).
#[inline]
fn check_imm12(imm: i32) -> u32 {
    assert!(
        (-2048..=2047).contains(&imm),
        "imm12 out of range: {imm} (use li+add / la)"
    );
    (imm as u32) & 0xfff
}

pub fn addi(rd: u32, rs1: u32, imm: i32) -> u32 {
    (check_imm12(imm) << 20) | (rs1 << 15) | (rd << 7) | 0x13
}

pub fn andi(rd: u32, rs1: u32, imm: i32) -> u32 {
    (check_imm12(imm) << 20) | (rs1 << 15) | (0x7 << 12) | (rd << 7) | 0x13
}

pub fn lbu(rd: u32, rs1: u32, imm: i32) -> u32 {
    (check_imm12(imm) << 20) | (rs1 << 15) | (0x4 << 12) | (rd << 7) | 0x03
}

pub fn lw(rd: u32, rs1: u32, imm: i32) -> u32 {
    (check_imm12(imm) << 20) | (rs1 << 15) | (0x2 << 12) | (rd << 7) | 0x03
}

pub fn ld(rd: u32, rs1: u32, imm: i32) -> u32 {
    (check_imm12(imm) << 20) | (rs1 << 15) | (0x3 << 12) | (rd << 7) | 0x03
}

pub fn sb(rs2: u32, rs1: u32, imm: i32) -> u32 {
    let imm = check_imm12(imm);
    ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | ((imm & 0x1f) << 7) | 0x23
}

pub fn sw(rs2: u32, rs1: u32, imm: i32) -> u32 {
    let imm = (imm as u32) & 0xfff;
    ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (0x2 << 12) | ((imm & 0x1f) << 7) | 0x23
}

pub fn sd(rs2: u32, rs1: u32, imm: i32) -> u32 {
    let imm = check_imm12(imm);
    ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (0x3 << 12) | ((imm & 0x1f) << 7) | 0x23
}

pub fn srli(rd: u32, rs1: u32, shamt: u32) -> u32 {
    (shamt << 20) | (rs1 << 15) | (0x5 << 12) | (rd << 7) | 0x13
}

pub fn slli(rd: u32, rs1: u32, shamt: u32) -> u32 {
    (shamt << 20) | (rs1 << 15) | (0x1 << 12) | (rd << 7) | 0x13
}

pub fn add(rd: u32, rs1: u32, rs2: u32) -> u32 {
    (rs2 << 20) | (rs1 << 15) | (rd << 7) | 0x33
}

/// RV32M/RV64M `mul`.
pub fn mul(rd: u32, rs1: u32, rs2: u32) -> u32 {
    (0x01 << 25) | (rs2 << 20) | (rs1 << 15) | (rd << 7) | 0x33
}

/// RV32M/RV64M `divu` — unsigned divide, funct3=0b101.
pub fn divu(rd: u32, rs1: u32, rs2: u32) -> u32 {
    (0x01 << 25) | (rs2 << 20) | (rs1 << 15) | (0x5 << 12) | (rd << 7) | 0x33
}

pub fn xor(rd: u32, rs1: u32, rs2: u32) -> u32 {
    (rs2 << 20) | (rs1 << 15) | (0x4 << 12) | (rd << 7) | 0x33
}

pub fn sub(rd: u32, rs1: u32, rs2: u32) -> u32 {
    (0x20 << 25) | (rs2 << 20) | (rs1 << 15) | (rd << 7) | 0x33
}

/// `sltu rd, rs1, rs2` — R-type, funct3=0b011.
pub fn sltu(rd: u32, rs1: u32, rs2: u32) -> u32 {
    (rs2 << 20) | (rs1 << 15) | (0x3 << 12) | (rd << 7) | 0x33
}

pub fn beq(rs1: u32, rs2: u32, imm: i32) -> u32 {
    let imm = imm as u32;
    (((imm >> 12) & 1) << 31)
        | (((imm >> 5) & 0x3f) << 25)
        | (rs2 << 20)
        | (rs1 << 15)
        | (((imm >> 1) & 0xf) << 8)
        | (((imm >> 11) & 1) << 7)
        | 0x63
}

pub fn bne(rs1: u32, rs2: u32, imm: i32) -> u32 {
    beq(rs1, rs2, imm) | (1 << 12)
}

pub fn jal(rd: u32, imm: i32) -> u32 {
    let imm = imm as u32;
    (((imm >> 20) & 1) << 31)
        | (((imm >> 1) & 0x3ff) << 21)
        | (((imm >> 11) & 1) << 20)
        | (((imm >> 12) & 0xff) << 12)
        | (rd << 7)
        | 0x6f
}

pub fn jalr(rd: u32, rs1: u32, imm: i32) -> u32 {
    (((imm as u32) & 0xfff) << 20) | (rs1 << 15) | (rd << 7) | 0x67
}

pub fn csrrw(rd: u32, csr: u32, rs1: u32) -> u32 {
    (csr << 20) | (rs1 << 15) | (1 << 12) | (rd << 7) | 0x73
}

pub fn csrrs(rd: u32, csr: u32, rs1: u32) -> u32 {
    (csr << 20) | (rs1 << 15) | (2 << 12) | (rd << 7) | 0x73
}

pub fn csrrc(rd: u32, csr: u32, rs1: u32) -> u32 {
    (csr << 20) | (rs1 << 15) | (3 << 12) | (rd << 7) | 0x73
}

pub fn ecall() -> u32 {
    0x0000_0073
}

pub fn wfi() -> u32 {
    0x1050_0073
}

pub fn sfence_vma() -> u32 {
    0x1200_0073
}

pub fn vsetvli(rd: u32, rs1: u32, vtype: u32) -> u32 {
    (vtype << 20) | (rs1 << 15) | (0x7 << 12) | (rd << 7) | 0x57
}

pub fn vle8(vd: u32, rs1: u32) -> u32 {
    (1 << 25) | (rs1 << 15) | (vd << 7) | 0x07
}

pub fn vse8(vs3: u32, rs1: u32) -> u32 {
    (1 << 25) | (rs1 << 15) | (vs3 << 7) | 0x27
}

pub fn hi_lo(addr: u64) -> (u32, i32) {
    let lo = (addr & 0xfff) as i32;
    let lo = if lo >= 0x800 { lo - 0x1000 } else { lo };
    let hi = ((addr.wrapping_add(0x800)) >> 12) as u32;
    (hi, lo)
}

pub fn fits12(imm: i64) -> bool {
    (-2048..=2047).contains(&imm)
}

pub fn li_nwords(imm: i64) -> usize {
    if fits12(imm) {
        1
    } else {
        2
    }
}

pub fn li_words(rd: u32, imm: i64) -> Vec<u32> {
    if fits12(imm) {
        vec![addi(rd, X0, imm as i32)]
    } else {
        let (hi, lo) = hi_lo(imm as u64);
        vec![lui(rd, hi), addi(rd, rd, lo)]
    }
}

pub fn reg_name(r: u32) -> &'static str {
    match r {
        0 => "zero",
        1 => "ra",
        2 => "sp",
        3 => "gp",
        4 => "tp",
        5 => "t0",
        6 => "t1",
        7 => "t2",
        8 => "s0",
        9 => "s1",
        10 => "a0",
        11 => "a1",
        12 => "a2",
        13 => "a3",
        14 => "a4",
        15 => "a5",
        16 => "a6",
        17 => "a7",
        18 => "s2",
        19 => "s3",
        20 => "s4",
        21 => "s5",
        22 => "s6",
        23 => "s7",
        24 => "s8",
        25 => "s9",
        26 => "s10",
        27 => "s11",
        28 => "t3",
        29 => "t4",
        30 => "t5",
        31 => "t6",
        _ => "x?",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn addi_a0_x0_1() {
        assert_eq!(addi(A0, X0, 1), 0x0010_0513);
        assert_eq!(ecall(), 0x0000_0073);
        assert_eq!(csrrw(X0, CSR_STVEC, T2), 0x1053_9073);
    }

    #[test]
    fn cmd_words_are_le_ascii() {
        assert_eq!(CMD_VIEW, u32::from_le_bytes(*b"View"));
        assert_eq!(CMD_REBO, u32::from_le_bytes(*b"Rebo"));
        assert_eq!(CMD_SHUT, u32::from_le_bytes(*b"Shut"));
        assert_eq!(CMD_WAKE, u32::from_le_bytes(*b"Wake"));
        assert_eq!(CMD_UI, u32::from_le_bytes(*b"Ui\0\0"));
        assert_eq!(CMD_FILE, u32::from_le_bytes(*b"File"));
        assert_eq!(CMD_GET, u32::from_le_bytes(*b"Get\0"));
        assert_eq!(CMD_KEYS, u32::from_le_bytes(*b"Keys"));
        assert_eq!(CMD_AWAI, u32::from_le_bytes(*b"Awai"));
        assert_eq!(CMD_THRO, u32::from_le_bytes(*b"Thro"));
        assert_eq!(MBOX_RSP_UI, u32::from_le_bytes(*b"UI\n\0"));
        assert_eq!(MBOX_RSP_FILE, u32::from_le_bytes(*b"FILE"));
        assert_eq!(WASM_MAGIC, u32::from_le_bytes(*b"\0asm"));
    }

    #[test]
    fn li_sbi_srst_is_two_words() {
        assert_eq!(li_nwords(SBI_SRST_EID), 2);
        assert_eq!(li_nwords(SBI_PUTCHAR), 1);
        let w = li_words(A7, SBI_SRST_EID);
        assert_eq!(w.len(), 2);
    }

    #[test]
    fn srli_scause_interrupt_bit_rv64() {
        // srli t2, t0, 63 — isolate scause[63] (Priv ch3 interrupt bit).
        assert_eq!(srli(T2, T0, 63), 0x03f2_d393);
        assert_eq!(CSR_TIME, 0xC01);
    }
}
