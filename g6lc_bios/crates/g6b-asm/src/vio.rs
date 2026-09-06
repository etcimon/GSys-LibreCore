//! Virtio-mmio GPU bring-up for `g6lc_bios` — generated guest routines.
//!
//! `VioInit` runs after `VioProbe` when `BoardSpec::wants_virtio_gpu()`: it
//! rescans the QEMU-virt virtio-mmio window, performs the virtio status
//! handshake (reset → ACK → DRIVER → FEATURES_OK → DRIVER_OK), brings up
//! controlq (queue 0) with descriptor/avail/used rings in `__vio` BSS, and
//! submits one `GET_DISPLAY_INFO` command, verifying `RESP_OK_DISPLAY_INFO`.
//!
//! `VioScan` runs the pixel path (CREATE_2D → ATTACH_BACKING → SET_SCANOUT →
//! band fill → TRANSFER → FLUSH) and `VioPaint` palette-expands the 4bpp
//! `__gr_plane` into `__scan_fb` and transfers+flushes the full frame —
//! QEMU-verified via `screendump` (see `architecture/DISPLAY.md`).
//!
//! All routines are leaf (t-regs + `a0`/`a7` for `SBI_PUTCHAR` only), so they
//! need no stack frame and cannot clobber `KStart` callee-saved state.
#![allow(missing_docs)]

use crate::analyze::{g6b_spec_proxy, Object};
use crate::encode::{A0, A1, A2, A7, RA, SP, T0, T1, T2, T3, T4, T5, T6, X0};
use crate::encode::{
    SBI_PUTCHAR, VIO_DESC_NEXT, VIO_DESC_WRITE, VIO_DEV_GPU, VIO_F_VERSION_1, VIO_GPU_FMT_B8G8R8X8,
    VIO_GPU_GET_DISPLAY_INFO, VIO_GPU_RESOURCE_ATTACH_BACKING, VIO_GPU_RESOURCE_CREATE_2D,
    VIO_GPU_RESOURCE_FLUSH, VIO_GPU_RESP_OK_DISPLAY_INFO, VIO_GPU_RESP_OK_NODATA,
    VIO_GPU_SET_SCANOUT, VIO_GPU_TRANSFER_TO_HOST_2D, VIO_MAGIC, VIO_MMIO_BASE, VIO_MMIO_SLOTS,
    VIO_MMIO_STEP, VIO_QUEUE_NUM, VIO_REG_DRV_FEATURES, VIO_REG_DRV_FEATURES_SEL, VIO_REG_FEATURES,
    VIO_REG_FEATURES_SEL, VIO_REG_ISR_ACK, VIO_REG_ISR_STATUS, VIO_REG_QUEUE_AVAIL,
    VIO_REG_QUEUE_DESC, VIO_REG_QUEUE_NOTIFY, VIO_REG_QUEUE_NUM, VIO_REG_QUEUE_NUM_MAX,
    VIO_REG_QUEUE_READY, VIO_REG_QUEUE_SEL, VIO_REG_QUEUE_USED, VIO_REG_STATUS, VIO_ST_ACK,
    VIO_ST_DRIVER, VIO_ST_DRIVER_OK, VIO_ST_FEATURES_OK,
};
use crate::{Addr, Node, Op, Purpose};
use g6b_spec::BoardSpec;

/// `__vio` BSS: descriptor table (8×16B) @0, avail ring @0x80 (32B — 4+2*8+2
/// = 22B used), used ring @0xC0 (80B — 4+8*8+4 = 72B used), request area
/// @0x120 (96B — largest ctrlq req is 56B), response buffer @0x180 (512B),
/// device-base scratch @0x3f0, irq counter @0x3f4, `G6FB` scanout
/// descriptor @0x400 (28B — the `simple-framebuffer`-shaped handoff).
pub const VIO_BSS: u64 = 0x420;
pub const VIO_AVAIL_OFF: i32 = 0x80;
pub const VIO_USED_OFF: i32 = 0xc0;
pub const VIO_REQ_OFF: i32 = 0x120;
pub const VIO_RSP_OFF: i32 = 0x180;
/// Response buffer length; `resp_display_info` is 24 + 16*24 = 408 bytes.
pub const VIO_RSP_LEN: i64 = 0x200;
pub const VIO_RESP_DISPLAY_INFO: u32 = 408;
/// Bound on the used-ring poll (descriptor completions).
/// Used-ring poll bound: QEMU services QueueNotify on an iothread/bh, so the
/// used.idx bump is not synchronous with the mmio store — a few thousand
/// iterations is far too short on TCG. ~4M iterations ≈ tens of ms worst case.
pub const VIO_POLL_MAX: i64 = 1 << 22;
/// Scratch u32 in `__vio` holding the probed device mmio base for `VioCmd`.
pub const VIO_DEV_OFF: i32 = 0x3f0;
/// Used-buffer interrupt counter in `__vio`, bumped by `trap_vio` (the SEI
/// path for the virtio-mmio PLIC source, irq 1+slot on QEMU virt — see the
/// machine DTB).
pub const VIO_IRQF_OFF: i32 = 0x3f4;
/// `G6FB` scanout handoff descriptor at `__vio+0x400`: `{magic, fb u64,
/// width, height, stride, format=1 (x8r8g8b8)}` — the shape a Linux
/// `simple-framebuffer`/`simpledrm` node inherits, so the same surface
/// serves the BIOS scanout and the OS.
pub const DISP_DESC_OFF: i32 = 0x400;
/// Uncore display-engine presence magic (`architecture/uncore/hdmi-display.md`).
pub const DISP_MAGIC: u32 = u32::from_le_bytes(*b"G6DS");
/// `G6FB` descriptor magic.
pub const DISP_DESC_MAGIC: u32 = u32::from_le_bytes(*b"G6FB");
/// QEMU virt PLIC irq for virtio-mmio slot 0 — the machine DTB gives
/// `virtio_mmio@0x10001000+i*0x1000 → interrupts = <1+i>` (irqs 1..=8).
pub const VIO_IRQ_BASE: i64 = 1;
/// Top band height painted into the backing before TRANSFER/FLUSH (bounded).
pub const VIO_BAND_H: u32 = 64;
/// Band pixel word — X8R8G8B8 little-endian (B=0, G=0xAA, R=0) → green band.
pub const VIO_BAND_COLOR: i64 = 0x0000_aa00;
/// Max scanout backing: 16 MiB of X8R8G8B8 — covers the high-DPI proxy
/// target up to 1920×1080 (8.3 MB) with headroom.
pub const VIO_FB_MAX: u64 = 0x100_0000;

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

fn ret() -> Op {
    Op::Jalr {
        rd: X0,
        rs: RA,
        imm: 0,
    }
}

fn sw(rs2: u32, rs1: u32, off: i32) -> Op {
    Op::Sw { rs2, rs1, off }
}

fn lw(rd: u32, rs: u32, off: i32) -> Op {
    Op::Lw { rd, rs, off }
}

/// `VioInit` — rescan slots → reset → status handshake → `VIRTIO_F_VERSION_1`
/// negotiation → ctrlq rings in `__vio` → `GET_DISPLAY_INFO` descriptor chain
/// → bounded used-ring poll → `VIRTIO-INFO`. Fail-closed: any mismatch or
/// timeout prints `VIRTIO-GPU-FAIL`; an absent device returns silently
/// (`VioProbe` already printed `VIRTIO-GPU-NONE`).
pub fn init_node(o: Object) -> Node {
    let mut ops = vec![
        Op::Comment(format!(
            "{} — scan → reset → features → ctrlq → GET_DISPLAY_INFO",
            o.why
        )),
        Op::Glob("VioInit".into()),
        Op::Label("VioInit".into()),
        Op::La {
            rd: T0,
            addr: Addr::Abs(VIO_MMIO_BASE),
        },
        Op::Li {
            rd: T1,
            imm: VIO_MMIO_SLOTS,
        },
        // The 0x1000 slot stride does not fit an addi immediate.
        Op::Li {
            rd: T4,
            imm: VIO_MMIO_STEP as i64,
        },
        Op::Label("vi2_slot".into()),
        lw(T2, T0, 0),
        Op::Li {
            rd: T3,
            imm: i64::from(VIO_MAGIC),
        },
        Op::Bne {
            rs1: T2,
            rs2: T3,
            to: "vi2_next".into(),
        },
        lw(T2, T0, 8),
        Op::Li {
            rd: T3,
            imm: i64::from(VIO_DEV_GPU),
        },
        Op::Beq {
            rs1: T2,
            rs2: T3,
            to: "vi2_dev".into(),
        },
        Op::Label("vi2_next".into()),
        Op::Add {
            rd: T0,
            rs1: T0,
            rs2: T4,
        },
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: -1,
        },
        Op::Bne {
            rs1: T1,
            rs2: X0,
            to: "vi2_slot".into(),
        },
        ret(),
        // reset: STATUS = 0, bounded poll until the device reads back 0.
        Op::Label("vi2_dev".into()),
        // publish the device base early: trap_vio needs it to resolve the
        // virtio-mmio PLIC source (irq 16+slot) during the first notify.
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
        sw(T0, T5, VIO_DEV_OFF),
        sw(X0, T0, VIO_REG_STATUS),
        Op::Li { rd: T4, imm: 4 },
        Op::Label("vi2_rst".into()),
        lw(T2, T0, VIO_REG_STATUS),
        Op::Beq {
            rs1: T2,
            rs2: X0,
            to: "vi2_ack".into(),
        },
        Op::Addi {
            rd: T4,
            rs: T4,
            imm: -1,
        },
        Op::Bne {
            rs1: T4,
            rs2: X0,
            to: "vi2_rst".into(),
        },
        Op::Jal {
            rd: X0,
            to: "vi2_fail".into(),
        },
        Op::Label("vi2_ack".into()),
        Op::Li {
            rd: T2,
            imm: i64::from(VIO_ST_ACK | VIO_ST_DRIVER),
        },
        sw(T2, T0, VIO_REG_STATUS),
        // features: accept nothing but VIRTIO_F_VERSION_1 when offered.
        sw(X0, T0, VIO_REG_FEATURES_SEL),
        lw(T2, T0, VIO_REG_FEATURES),
        sw(X0, T0, VIO_REG_DRV_FEATURES_SEL),
        sw(X0, T0, VIO_REG_DRV_FEATURES),
        Op::Li { rd: T2, imm: 1 },
        sw(T2, T0, VIO_REG_FEATURES_SEL),
        lw(T3, T0, VIO_REG_FEATURES),
        Op::Andi {
            rd: T3,
            rs: T3,
            imm: VIO_F_VERSION_1 as i32,
        },
        Op::Li { rd: T2, imm: 1 },
        sw(T2, T0, VIO_REG_DRV_FEATURES_SEL),
        sw(T3, T0, VIO_REG_DRV_FEATURES),
        // FEATURES_OK then readback — device must keep the bit set.
        lw(T2, T0, VIO_REG_STATUS),
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: VIO_ST_FEATURES_OK,
        },
        sw(T2, T0, VIO_REG_STATUS),
        lw(T2, T0, VIO_REG_STATUS),
        Op::Andi {
            rd: T2,
            rs: T2,
            imm: VIO_ST_FEATURES_OK,
        },
        Op::Beq {
            rs1: T2,
            rs2: X0,
            to: "vi2_fail".into(),
        },
        // controlq: queue 0, VIO_QUEUE_NUM descriptors, rings in __vio.
        sw(X0, T0, VIO_REG_QUEUE_SEL),
        lw(T2, T0, VIO_REG_QUEUE_NUM_MAX),
        Op::Beq {
            rs1: T2,
            rs2: X0,
            to: "vi2_fail".into(),
        },
        Op::Li {
            rd: T3,
            imm: VIO_QUEUE_NUM,
        },
        sw(T3, T0, VIO_REG_QUEUE_NUM),
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
        sw(T5, T0, VIO_REG_QUEUE_DESC),
        sw(X0, T0, VIO_REG_QUEUE_DESC + 4),
        Op::Addi {
            rd: T3,
            rs: T5,
            imm: VIO_AVAIL_OFF,
        },
        sw(T3, T0, VIO_REG_QUEUE_AVAIL),
        sw(X0, T0, VIO_REG_QUEUE_AVAIL + 4),
        Op::Addi {
            rd: T3,
            rs: T5,
            imm: VIO_USED_OFF,
        },
        sw(T3, T0, VIO_REG_QUEUE_USED),
        sw(X0, T0, VIO_REG_QUEUE_USED + 4),
        Op::Li { rd: T3, imm: 1 },
        sw(T3, T0, VIO_REG_QUEUE_READY),
        lw(T2, T0, VIO_REG_STATUS),
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: VIO_ST_DRIVER_OK,
        },
        sw(T2, T0, VIO_REG_STATUS),
    ];
    putc_str(&mut ops, "VIRTIO-GPU-OK\n");
    // GET_DISPLAY_INFO: ctrl_hdr at __vio+VIO_REQ_OFF (24 bytes, all zero
    // except type), resp at __vio+VIO_RSP_OFF, desc chain 0→1, notify q0.
    ops.extend([
        Op::Addi {
            rd: T2,
            rs: T5,
            imm: VIO_REQ_OFF,
        },
        Op::Li {
            rd: T3,
            imm: i64::from(VIO_GPU_GET_DISPLAY_INFO),
        },
        sw(T3, T2, 0),
        sw(X0, T2, 4),
        sw(X0, T2, 8),
        sw(X0, T2, 12),
        sw(X0, T2, 16),
        sw(X0, T2, 20),
        // desc0 = {addr=req, len=24, flags=NEXT, next=1}
        sw(T2, T5, 0),
        sw(X0, T5, 4),
        Op::Li { rd: T3, imm: 24 },
        sw(T3, T5, 8),
        Op::Li {
            rd: T3,
            imm: i64::from(VIO_DESC_NEXT | (1 << 16)),
        },
        sw(T3, T5, 12),
        // desc1 = {addr=resp, len=VIO_RSP_LEN, flags=WRITE}
        Op::Addi {
            rd: T3,
            rs: T5,
            imm: VIO_RSP_OFF,
        },
        sw(T3, T5, 16),
        sw(X0, T5, 20),
        Op::Li {
            rd: T3,
            imm: VIO_RSP_LEN,
        },
        sw(T3, T5, 24),
        Op::Li {
            rd: T3,
            imm: i64::from(VIO_DESC_WRITE),
        },
        sw(T3, T5, 28),
        // avail.ring[0] = head 0 (one sw covers ring[0..1], both zero).
        sw(X0, T5, VIO_AVAIL_OFF + 4),
        Op::Fence,
        // avail: flags=0, idx=1 (packed u16 pair).
        Op::Li {
            rd: T3,
            imm: 0x1_0000,
        },
        sw(T3, T5, VIO_AVAIL_OFF),
        Op::Fence,
        sw(X0, T0, VIO_REG_QUEUE_NOTIFY),
        // bounded used.idx poll (idx is the high u16 of used+0).
        Op::Li {
            rd: T4,
            imm: VIO_POLL_MAX,
        },
        Op::Label("vi2_poll".into()),
        lw(T2, T5, VIO_USED_OFF),
        Op::Srli {
            rd: T2,
            rs: T2,
            shamt: 16,
        },
        Op::Bne {
            rs1: T2,
            rs2: X0,
            to: "vi2_got".into(),
        },
        Op::Addi {
            rd: T4,
            rs: T4,
            imm: -1,
        },
        Op::Bne {
            rs1: T4,
            rs2: X0,
            to: "vi2_poll".into(),
        },
        Op::Jal {
            rd: X0,
            to: "vi2_fail".into(),
        },
        Op::Label("vi2_got".into()),
        lw(T2, T5, VIO_RSP_OFF),
        Op::Li {
            rd: T3,
            imm: i64::from(VIO_GPU_RESP_OK_DISPLAY_INFO),
        },
        Op::Bne {
            rs1: T2,
            rs2: T3,
            to: "vi2_fail".into(),
        },
        // Ack the used-buffer interrupt the device raised for this chain
        // (read-to-see, write-to-ack — virtio-mmio InterruptStatus/ACK).
        lw(T3, T0, VIO_REG_ISR_STATUS),
        sw(T3, T0, VIO_REG_ISR_ACK),
    ]);
    putc_str(&mut ops, "VIRTIO-INFO\n");
    ops.push(ret());
    ops.push(Op::Label("vi2_fail".into()));
    putc_str(&mut ops, "VIRTIO-GPU-FAIL\n");
    ops.push(ret());
    Node {
        purpose: Purpose::Virtio,
        ops,
    }
}

/// xlen-dependent pointer store/load for the `VioScan` ra frame.
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

/// Emit `li t3, v; sw t3, off(rs)` (t3 is scratch).
fn sw_i(ops: &mut Vec<Op>, rs: u32, off: i32, v: i64) {
    ops.push(Op::Li { rd: T3, imm: v });
    ops.push(sw(T3, rs, off));
}

/// Zeroed ctrl_hdr with `type` at `__vio+VIO_REQ_OFF` (t2 = req, t5 = `__vio`).
fn req_hdr(ops: &mut Vec<Op>, ty: u32) {
    ops.extend([
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
        Op::Addi {
            rd: T2,
            rs: T5,
            imm: VIO_REQ_OFF,
        },
        Op::Li {
            rd: T3,
            imm: i64::from(ty),
        },
        sw(T3, T2, 0),
        sw(X0, T2, 4),
        sw(X0, T2, 8),
        sw(X0, T2, 12),
        sw(X0, T2, 16),
        sw(X0, T2, 20),
    ]);
}

/// Submit the pre-built request via `VioCmd`; `fail` unless `OK_NODATA`.
fn submit_nodata(ops: &mut Vec<Op>, req_len: i64, fail: &str) {
    ops.extend([
        Op::Li {
            rd: A0,
            imm: req_len,
        },
        Op::Li {
            rd: A1,
            imm: VIO_RSP_LEN,
        },
        Op::Jal {
            rd: RA,
            to: "VioCmd".into(),
        },
        Op::Li {
            rd: T3,
            imm: i64::from(VIO_GPU_RESP_OK_NODATA),
        },
        Op::Bne {
            rs1: A0,
            rs2: T3,
            to: fail.into(),
        },
    ]);
}

/// `VioCmd` — leaf ctrlq submitter. In: a0 = request bytes, a1 = response
/// bytes; the caller pre-builds the request at `__vio+VIO_REQ_OFF` and the
/// device base lives at `__vio+VIO_DEV_OFF`. Out: a0 = response `type` word
/// (0 on timeout / unprobed device). Clobbers t0..t6, a0.
pub fn cmd_node() -> Node {
    Node {
        purpose: Purpose::Virtio,
        ops: vec![
            Op::Comment(
                "VioCmd — submit one ctrlq chain (desc0=req OUT, desc1=resp WRITE); \
                 bounded used.idx poll; ring fields are u16 packed into sw words"
                    .into(),
            ),
            Op::Glob("VioCmd".into()),
            Op::Label("VioCmd".into()),
            Op::La {
                rd: T5,
                addr: Addr::VioBss,
            },
            lw(T6, T5, VIO_DEV_OFF),
            Op::Beq {
                rs1: T6,
                rs2: X0,
                to: "vqc_ret0".into(),
            },
            // desc0 = {req, a0, NEXT, next=1}
            Op::Addi {
                rd: T2,
                rs: T5,
                imm: VIO_REQ_OFF,
            },
            sw(T2, T5, 0),
            sw(X0, T5, 4),
            sw(A0, T5, 8),
            Op::Li {
                rd: T3,
                imm: i64::from(VIO_DESC_NEXT | (1 << 16)),
            },
            sw(T3, T5, 12),
            // desc1 = {resp, a1, WRITE}
            Op::Addi {
                rd: T2,
                rs: T5,
                imm: VIO_RSP_OFF,
            },
            sw(T2, T5, 16),
            sw(X0, T5, 20),
            sw(A1, T5, 24),
            Op::Li {
                rd: T3,
                imm: i64::from(VIO_DESC_WRITE),
            },
            sw(T3, T5, 28),
            // avail.ring[idx % 8] = head 0 — two byte stores (u16 slot)
            lw(T2, T5, VIO_AVAIL_OFF),
            Op::Srli {
                rd: T1,
                rs: T2,
                shamt: 16,
            },
            Op::Andi {
                rd: T4,
                rs: T1,
                imm: 7,
            },
            Op::Slli {
                rd: T4,
                rs: T4,
                shamt: 1,
            },
            Op::Addi {
                rd: T4,
                rs: T4,
                imm: VIO_AVAIL_OFF + 4,
            },
            Op::Add {
                rd: T4,
                rs1: T4,
                rs2: T5,
            },
            Op::Sb {
                rs2: X0,
                rs1: T4,
                off: 0,
            },
            Op::Sb {
                rs2: X0,
                rs1: T4,
                off: 1,
            },
            Op::Fence,
            // avail word = (idx + 1) << 16; flags stay 0 (we never set
            // VIRTQ_AVAIL_F_NO_INTERRUPT) — do NOT try to preserve the low
            // half: slli/srli by 16 on rv64 masks 48 bits, not 16.
            Op::Addi {
                rd: T1,
                rs: T1,
                imm: 1,
            },
            Op::Slli {
                rd: T3,
                rs: T1,
                shamt: 16,
            },
            sw(T3, T5, VIO_AVAIL_OFF),
            Op::Fence,
            sw(X0, T6, VIO_REG_QUEUE_NOTIFY),
            // poll used.idx == the avail idx we just published
            Op::Li {
                rd: T4,
                imm: VIO_POLL_MAX,
            },
            Op::Label("vqc_poll".into()),
            lw(T2, T5, VIO_USED_OFF),
            Op::Srli {
                rd: T2,
                rs: T2,
                shamt: 16,
            },
            Op::Beq {
                rs1: T2,
                rs2: T1,
                to: "vqc_done".into(),
            },
            Op::Addi {
                rd: T4,
                rs: T4,
                imm: -1,
            },
            Op::Bne {
                rs1: T4,
                rs2: X0,
                to: "vqc_poll".into(),
            },
            Op::Label("vqc_ret0".into()),
            Op::Li {
                rd: A0,
                imm: i64::from(b'X'),
            },
            Op::Li {
                rd: A7,
                imm: SBI_PUTCHAR,
            },
            Op::Ecall,
            Op::Li { rd: A0, imm: 0 },
            ret(),
            Op::Label("vqc_done".into()),
            // Read InterruptStatus and write it back to InterruptACK — the
            // device raised a used-buffer irq for this completion.
            lw(T3, T6, VIO_REG_ISR_STATUS),
            sw(T3, T6, VIO_REG_ISR_ACK),
            lw(A0, T5, VIO_RSP_OFF),
            ret(),
        ],
    }
}

/// `VioScan` — the bounded pixel path: `RESOURCE_CREATE_2D` →
/// `RESOURCE_ATTACH_BACKING` (the `__scan_fb` X8R8G8B8 buffer) → `SET_SCANOUT`
/// → fill the top `VIO_BAND_H` rows → `TRANSFER_TO_HOST_2D` →
/// `RESOURCE_FLUSH`. Prints `VIRTIO-SCAN` when every command answers
/// `RESP_OK_NODATA`; `VIRTIO-GPU-FAIL` on any error. Needs `VioInit` to have
/// completed (STATUS == 0xF). Non-leaf: saves `ra` for the `VioCmd` calls.
pub fn scan_node(spec: &BoardSpec) -> Node {
    let xlen = spec.isa.xlen;
    let gp = g6b_spec_proxy(spec);
    // The scanout is the *high-res* proxy target (gp.2×gp.3 = proxy.high_w×
    // high_h when `kernel.proxy` is live, else the `__gr_plane` geometry) —
    // `VioPaint` scale-expands the 4bpp plane into it.
    let (w, h) = (gp.2, gp.3);
    let band = h.min(VIO_BAND_H);
    let fill_words = i64::from(w.saturating_mul(band));
    let fb_len = i64::from(w.saturating_mul(h).saturating_mul(4));
    let mut ops = vec![
        Op::Comment(format!(
            "VioScan — {w}x{h} scanout: create/attach/scanout/transfer/flush"
        )),
        Op::Glob("VioScan".into()),
        Op::Label("VioScan".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -16,
        },
        st_x(xlen, RA, SP, 8),
        // rescan for the GPU transport (VioProbe/VioInit may have run first).
        Op::La {
            rd: T0,
            addr: Addr::Abs(VIO_MMIO_BASE),
        },
        Op::Li {
            rd: T1,
            imm: VIO_MMIO_SLOTS,
        },
        Op::Li {
            rd: T4,
            imm: VIO_MMIO_STEP as i64,
        },
        Op::Label("vi3_slot".into()),
        lw(T2, T0, 0),
        Op::Li {
            rd: T3,
            imm: i64::from(VIO_MAGIC),
        },
        Op::Bne {
            rs1: T2,
            rs2: T3,
            to: "vi3_next".into(),
        },
        lw(T2, T0, 8),
        Op::Li {
            rd: T3,
            imm: i64::from(VIO_DEV_GPU),
        },
        Op::Beq {
            rs1: T2,
            rs2: T3,
            to: "vi3_dev".into(),
        },
        Op::Label("vi3_next".into()),
        Op::Add {
            rd: T0,
            rs1: T0,
            rs2: T4,
        },
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: -1,
        },
        Op::Bne {
            rs1: T1,
            rs2: X0,
            to: "vi3_slot".into(),
        },
        Op::Jal {
            rd: X0,
            to: "vs_out".into(),
        },
        Op::Label("vi3_dev".into()),
        // only proceed when VioInit left ACK|DRIVER|FEATURES_OK|DRIVER_OK
        lw(T2, T0, VIO_REG_STATUS),
        Op::Li {
            rd: T3,
            imm: i64::from(VIO_ST_ACK | VIO_ST_DRIVER | VIO_ST_FEATURES_OK | VIO_ST_DRIVER_OK),
        },
        Op::Bne {
            rs1: T2,
            rs2: T3,
            to: "vs_out".into(),
        },
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
        sw(T0, T5, VIO_DEV_OFF),
    ];
    // 1. RESOURCE_CREATE_2D — res 1, B8G8R8X8, w×h.
    req_hdr(&mut ops, VIO_GPU_RESOURCE_CREATE_2D);
    sw_i(&mut ops, T2, 24, 1); // resource_id
    sw_i(&mut ops, T2, 28, i64::from(VIO_GPU_FMT_B8G8R8X8));
    sw_i(&mut ops, T2, 32, i64::from(w));
    sw_i(&mut ops, T2, 36, i64::from(h));
    submit_nodata(&mut ops, 40, "vs_fail");
    // 2. RESOURCE_ATTACH_BACKING — res 1, 1 entry → __scan_fb, w*h*4.
    req_hdr(&mut ops, VIO_GPU_RESOURCE_ATTACH_BACKING);
    sw_i(&mut ops, T2, 24, 1);
    sw_i(&mut ops, T2, 28, 1); // nr_entries
    ops.extend([
        Op::La {
            rd: T3,
            addr: Addr::ScanFb,
        },
        sw(T3, T2, 32),
        sw(X0, T2, 36), // addr u64 hi
    ]);
    sw_i(&mut ops, T2, 40, fb_len);
    sw_i(&mut ops, T2, 44, 0);
    submit_nodata(&mut ops, 48, "vs_fail");
    // 3. SET_SCANOUT — scanout 0, res 1, rect {0,0,w,h}.
    req_hdr(&mut ops, VIO_GPU_SET_SCANOUT);
    ops.push(sw(X0, T2, 24));
    ops.push(sw(X0, T2, 28));
    sw_i(&mut ops, T2, 32, i64::from(w));
    sw_i(&mut ops, T2, 36, i64::from(h));
    sw_i(&mut ops, T2, 40, 0); // scanout_id
    sw_i(&mut ops, T2, 44, 1); // resource_id
    submit_nodata(&mut ops, 48, "vs_fail");
    // 4. paint the top `band` rows of the backing (bounded loop).
    ops.extend([
        Op::La {
            rd: T2,
            addr: Addr::ScanFb,
        },
        Op::Li {
            rd: T3,
            imm: VIO_BAND_COLOR,
        },
        Op::Li {
            rd: T4,
            imm: fill_words,
        },
        Op::Label("vs_fill".into()),
        sw(T3, T2, 0),
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: 4,
        },
        Op::Addi {
            rd: T4,
            rs: T4,
            imm: -1,
        },
        Op::Bne {
            rs1: T4,
            rs2: X0,
            to: "vs_fill".into(),
        },
    ]);
    // 5. TRANSFER_TO_HOST_2D — rect {0,0,w,band}, backing offset 0, res 1.
    req_hdr(&mut ops, VIO_GPU_TRANSFER_TO_HOST_2D);
    ops.push(sw(X0, T2, 24));
    ops.push(sw(X0, T2, 28));
    sw_i(&mut ops, T2, 32, i64::from(w));
    sw_i(&mut ops, T2, 36, i64::from(band));
    ops.push(sw(X0, T2, 40));
    ops.push(sw(X0, T2, 44)); // offset u64
    sw_i(&mut ops, T2, 48, 1);
    sw_i(&mut ops, T2, 52, 0);
    submit_nodata(&mut ops, 56, "vs_fail");
    // 6. RESOURCE_FLUSH — rect {0,0,w,band}, res 1.
    req_hdr(&mut ops, VIO_GPU_RESOURCE_FLUSH);
    ops.push(sw(X0, T2, 24));
    ops.push(sw(X0, T2, 28));
    sw_i(&mut ops, T2, 32, i64::from(w));
    sw_i(&mut ops, T2, 36, i64::from(band));
    sw_i(&mut ops, T2, 40, 1); // resource_id
    sw_i(&mut ops, T2, 44, 0);
    submit_nodata(&mut ops, 48, "vs_fail");
    putc_str(&mut ops, "VIRTIO-SCAN\n");
    ops.push(Op::Jal {
        rd: X0,
        to: "vs_out".into(),
    });
    ops.push(Op::Label("vs_fail".into()));
    putc_str(&mut ops, "VIRTIO-GPU-FAIL\n");
    ops.push(Op::Label("vs_out".into()));
    ops.push(ld_x(xlen, RA, SP, 8));
    ops.push(Op::Addi {
        rd: SP,
        rs: SP,
        imm: 16,
    });
    ops.push(ret());
    Node {
        purpose: Purpose::Virtio,
        ops,
    }
}

/// VGA-like 16-colour palette as X8R8G8B8 words (0x00RRGGBB) — same values
/// as `g6b-gr::PALETTE` so the QEMU scanout matches the host PPM renders.
const VIO_PAL: [u32; 16] = [
    0x0000_0000,
    0x0000_00AA,
    0x0000_AA00,
    0x0000_AAAA,
    0x00AA_0000,
    0x00AA_00AA,
    0x00AA_5500,
    0x00AA_AAAA,
    0x0055_5555,
    0x0055_55FF,
    0x0055_FF55,
    0x0055_FFFF,
    0x00FF_5555,
    0x00FF_55FF,
    0x00FF_FF55,
    0x00FF_FFFF,
];

/// `VioPaint` — palette-expand the 4bpp `__gr_plane` into the X8R8G8B8
/// `__scan_fb` backing, then TRANSFER_TO_HOST_2D + RESOURCE_FLUSH the full
/// frame through `VioCmd`. Runs after the boot painters (`GrInit` /
/// `DomPaint` via `WasmUi`) and re-runs on the UART `Ui` re-dump, so the
/// QEMU scanout tracks DOM content. Prints `VIRTIO-PAINT` on success,
/// `VIRTIO-PAINT-FAIL` on a non-`OK_NODATA` response; bails silently when
/// `VioScan` never bound a device (`__vio+VIO_DEV_OFF == 0`). Saves ra +
/// t3..t6 — the trap frame only covers t0..t2/a0..a2/a6/a7, and this routine
/// is also reachable from the `trap_uart` `Ui` path.
/// `FbExpand` — the shared scanout blit: palette-expand the 4bpp
/// `__gr_plane` into the X8R8G8B8 `__scan_fb` surface. Same semantics as
/// the host display-proxy (`g6b_gr::proxy::Proxy`): `fit`/`dpi`/`""` use
/// the resolved uniform `scale` with a *centered* letterbox
/// (ox=(hi_w-low_w*sc)/2, oy=(hi_h-low_h*sc)/2, exactly like `to_ppm`'s
/// sample window); `fill` stretches per axis (sx=hi_w/low_w,
/// sy=hi_h/low_h — the bounded integer form of `to_ppm`'s continuous
/// stretch; exact when the ratios are integral). All constants are
/// gen-time, so the blit is a bounded branch-free nest. Backend-agnostic —
/// `VioPaint` (virtio TRANSFER+FLUSH) and `DispPaint` (uncore display
/// engine commit, `architecture/uncore/hdmi-display.md`) both call it, so
/// the BIOS scales the plane identically on every output path. 4bpp:
/// low_w even, each byte → two pixels. Saves t3..t6 (trap-safe); callers
/// need no frame for it.
pub fn expand_node(spec: &BoardSpec) -> Node {
    let xlen = spec.isa.xlen;
    let gp = g6b_spec_proxy(spec);
    let (low_w, low_h, hi_w, hi_h) = (gp.0, gp.1, gp.2, gp.3);
    let s = gp.7.max(1);
    let (sx, sy) = if gp.6 == "fill" {
        (
            (hi_w / low_w.max(1)).clamp(1, 64),
            (hi_h / low_h.max(1)).clamp(1, 64),
        )
    } else {
        (s.min(64), s.min(64))
    };
    // Content window (centered for the uniform-scale modes) and the
    // right-letterbox pad in dst bytes per row.
    let used_w = low_w.saturating_mul(sx);
    let used_h = low_h.saturating_mul(sy);
    let ox = hi_w.saturating_sub(used_w) / 2;
    let oy = hi_h.saturating_sub(used_h) / 2;
    let origin = i64::from(oy.saturating_mul(hi_w).saturating_add(ox)).saturating_mul(4);
    let row_pad = i64::from(hi_w.saturating_sub(used_w)).saturating_mul(4);
    let row_bytes = i64::from(low_w / 2);
    let mut ops = vec![
        Op::Comment(format!(
            "FbExpand — __gr_plane {low_w}x{low_h} (4bpp) → __scan_fb \
             {hi_w}x{hi_h} (X8R8G8B8) scale {sx}x{sy} +({ox},{oy}) via vio_pal"
        )),
        Op::Glob("FbExpand".into()),
        Op::Label("FbExpand".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -32,
        },
        st_x(xlen, T3, SP, 0),
        st_x(xlen, T4, SP, 8),
        st_x(xlen, T5, SP, 16),
        st_x(xlen, T6, SP, 24),
        // t0 = src row base, t1 = dst word, t2 = vertical rep countdown,
        // t3 = src byte cursor, t4 = row byte count, t5 = palette base,
        // t6 = src rows left; a0 = byte, a2 = pixel word.
        Op::La {
            rd: T0,
            addr: Addr::GrPlane,
        },
        Op::Addi {
            rd: T0,
            rs: T0,
            imm: crate::GR_HEADER_BYTES as i32,
        },
        Op::La {
            rd: T1,
            addr: Addr::ScanFb,
        },
        Op::Li {
            rd: A2,
            imm: origin,
        },
        Op::Add {
            rd: T1,
            rs1: T1,
            rs2: A2,
        },
        Op::La {
            rd: T5,
            addr: Addr::Label("vio_pal".into()),
        },
        Op::Li {
            rd: T6,
            imm: i64::from(low_h),
        },
        Op::Label("vp_row".into()),
        Op::Li {
            rd: T2,
            imm: i64::from(sy),
        },
        Op::Label("vp_rep".into()),
        Op::Addi {
            rd: T3,
            rs: T0,
            imm: 0,
        },
        Op::Li {
            rd: T4,
            imm: row_bytes,
        },
        Op::Label("vp_byte".into()),
        Op::Lbu {
            rd: A0,
            rs: T3,
            off: 0,
        },
        // even pixel = high nibble → sx scaled words
        Op::Srli {
            rd: A2,
            rs: A0,
            shamt: 4,
        },
        Op::Slli {
            rd: A2,
            rs: A2,
            shamt: 2,
        },
        Op::Add {
            rd: A2,
            rs1: A2,
            rs2: T5,
        },
        Op::Lw {
            rd: A2,
            rs: A2,
            off: 0,
        },
    ];
    for k in 0..sx {
        ops.push(sw(A2, T1, (k * 4) as i32));
    }
    ops.extend([
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: (sx * 4) as i32,
        },
        // odd pixel = low nibble → sx scaled words
        Op::Andi {
            rd: A2,
            rs: A0,
            imm: 0xf,
        },
        Op::Slli {
            rd: A2,
            rs: A2,
            shamt: 2,
        },
        Op::Add {
            rd: A2,
            rs1: A2,
            rs2: T5,
        },
        Op::Lw {
            rd: A2,
            rs: A2,
            off: 0,
        },
    ]);
    for k in 0..sx {
        ops.push(sw(A2, T1, (k * 4) as i32));
    }
    ops.extend([
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: (sx * 4) as i32,
        },
        Op::Addi {
            rd: T3,
            rs: T3,
            imm: 1,
        },
        Op::Addi {
            rd: T4,
            rs: T4,
            imm: -1,
        },
        Op::Bne {
            rs1: T4,
            rs2: X0,
            to: "vp_byte".into(),
        },
    ]);
    if row_pad > 0 {
        ops.extend([
            Op::Li {
                rd: A2,
                imm: row_pad,
            },
            Op::Add {
                rd: T1,
                rs1: T1,
                rs2: A2,
            },
        ]);
    }
    ops.extend([
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: -1,
        },
        Op::Bne {
            rs1: T2,
            rs2: X0,
            to: "vp_rep".into(),
        },
        Op::Li {
            rd: A2,
            imm: row_bytes,
        },
        Op::Add {
            rd: T0,
            rs1: T0,
            rs2: A2,
        },
        Op::Addi {
            rd: T6,
            rs: T6,
            imm: -1,
        },
        Op::Bne {
            rs1: T6,
            rs2: X0,
            to: "vp_row".into(),
        },
        ld_x(xlen, T3, SP, 0),
        ld_x(xlen, T4, SP, 8),
        ld_x(xlen, T5, SP, 16),
        ld_x(xlen, T6, SP, 24),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: 32,
        },
        ret(),
        // Inline rodata (never executed — sits after ret).
        Op::Label("vio_pal".into()),
    ]);
    for w32 in VIO_PAL {
        ops.push(Op::Word(w32));
    }
    Node {
        purpose: Purpose::Virtio,
        ops,
    }
}

/// `DispPaint` — `FbExpand` the plane into `__scan_fb`, then program the
/// declared uncore display engine (`class:"display"` peripheral) with the
/// framebuffer contract of `architecture/uncore/hdmi-display.md`: MAGIC
/// detect → FB/W/H/STRIDE/FORMAT/CTRL → `G6FB` handoff descriptor at
/// `__vio+0x400` (the `simple-framebuffer`-shaped surface a Linux
/// `simplefb`/`simpledrm` node inherits — the same scanout serves BIOS and
/// Linux) → COMMIT → STATUS check. Prints `DISP-OK` / `DISP-FAIL`; bails
/// silently when the engine is absent. Saves ra + t3..t6 (trap-safe).
pub fn disp_paint_node(spec: &BoardSpec) -> Node {
    let xlen = spec.isa.xlen;
    let base = spec.display_ctrl().unwrap_or(0) as i64;
    let gp = g6b_spec_proxy(spec);
    let (hi_w, hi_h) = (gp.2, gp.3);
    let mut ops = vec![
        Op::Comment(format!(
            "DispPaint — FbExpand + display-engine commit @ {base:#x} \
             ({hi_w}x{hi_h} x8r8g8b8) + G6FB descriptor"
        )),
        Op::Glob("DispPaint".into()),
        Op::Label("DispPaint".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -48,
        },
        st_x(xlen, RA, SP, 0),
        st_x(xlen, T3, SP, 8),
        st_x(xlen, T4, SP, 16),
        st_x(xlen, T5, SP, 24),
        st_x(xlen, T6, SP, 32),
        Op::Li { rd: T0, imm: base },
        lw(T1, T0, 0),
        Op::Li {
            rd: T2,
            imm: i64::from(DISP_MAGIC),
        },
        Op::Bne {
            rs1: T1,
            rs2: T2,
            to: "dp_out".into(),
        },
        Op::Jal {
            rd: RA,
            to: "FbExpand".into(),
        },
        Op::Li { rd: T0, imm: base },
        Op::La {
            rd: T6,
            addr: Addr::ScanFb,
        },
        sw(T6, T0, 0x0c), // FB_LO
        Op::Srli {
            rd: T4,
            rs: T6,
            shamt: 32,
        },
        sw(T4, T0, 0x10), // FB_HI
    ];
    sw_i(&mut ops, T0, 0x14, i64::from(hi_w));
    sw_i(&mut ops, T0, 0x18, i64::from(hi_h));
    sw_i(&mut ops, T0, 0x1c, i64::from(hi_w).saturating_mul(4));
    sw_i(&mut ops, T0, 0x20, 1); // FORMAT x8r8g8b8
    sw_i(&mut ops, T0, 0x08, 1); // CTRL enable
                                 // G6FB handoff descriptor at __vio+0x400.
    ops.push(Op::La {
        rd: T5,
        addr: Addr::VioBss,
    });
    sw_i(&mut ops, T5, DISP_DESC_OFF, i64::from(DISP_DESC_MAGIC));
    ops.push(sw(T6, T5, DISP_DESC_OFF + 4));
    ops.push(sw(T4, T5, DISP_DESC_OFF + 8));
    sw_i(&mut ops, T5, DISP_DESC_OFF + 12, i64::from(hi_w));
    sw_i(&mut ops, T5, DISP_DESC_OFF + 16, i64::from(hi_h));
    sw_i(
        &mut ops,
        T5,
        DISP_DESC_OFF + 20,
        i64::from(hi_w).saturating_mul(4),
    );
    sw_i(&mut ops, T5, DISP_DESC_OFF + 24, 1);
    // COMMIT → STATUS.
    ops.extend([
        Op::Li { rd: T2, imm: 1 },
        sw(T2, T0, 0x24),
        lw(T1, T0, 0x28),
        Op::Beq {
            rs1: T1,
            rs2: T2,
            to: "dp_ok".into(),
        },
    ]);
    putc_str(&mut ops, "DISP-FAIL\n");
    ops.push(Op::Jal {
        rd: X0,
        to: "dp_out".into(),
    });
    ops.push(Op::Label("dp_ok".into()));
    putc_str(&mut ops, "DISP-OK\n");
    ops.push(Op::Label("dp_out".into()));
    ops.push(ld_x(xlen, RA, SP, 0));
    ops.push(ld_x(xlen, T3, SP, 8));
    ops.push(ld_x(xlen, T4, SP, 16));
    ops.push(ld_x(xlen, T5, SP, 24));
    ops.push(ld_x(xlen, T6, SP, 32));
    ops.push(Op::Addi {
        rd: SP,
        rs: SP,
        imm: 48,
    });
    ops.push(ret());
    Node {
        purpose: Purpose::DispScan,
        ops,
    }
}

pub fn paint_node(spec: &BoardSpec) -> Node {
    let xlen = spec.isa.xlen;
    let gp = g6b_spec_proxy(spec);
    let (hi_w, hi_h) = (gp.2, gp.3);
    let mut ops = vec![
        Op::Comment(format!(
            "VioPaint — jal FbExpand (__gr_plane → __scan_fb {hi_w}x{hi_h} \
             X8R8G8B8), then full-frame TRANSFER+FLUSH"
        )),
        Op::Glob("VioPaint".into()),
        Op::Label("VioPaint".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -48,
        },
        st_x(xlen, RA, SP, 0),
        st_x(xlen, T3, SP, 8),
        st_x(xlen, T4, SP, 16),
        st_x(xlen, T5, SP, 24),
        st_x(xlen, T6, SP, 32),
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
        lw(T6, T5, VIO_DEV_OFF),
        Op::Beq {
            rs1: T6,
            rs2: X0,
            to: "vp_out".into(),
        },
        Op::Jal {
            rd: RA,
            to: "FbExpand".into(),
        },
    ];
    // TRANSFER_TO_HOST_2D — rect {0,0,hi_w,hi_h}, backing offset 0, res 1.
    req_hdr(&mut ops, VIO_GPU_TRANSFER_TO_HOST_2D);
    ops.push(sw(X0, T2, 24));
    ops.push(sw(X0, T2, 28));
    sw_i(&mut ops, T2, 32, i64::from(hi_w));
    sw_i(&mut ops, T2, 36, i64::from(hi_h));
    ops.push(sw(X0, T2, 40));
    ops.push(sw(X0, T2, 44)); // offset u64
    sw_i(&mut ops, T2, 48, 1);
    sw_i(&mut ops, T2, 52, 0);
    submit_nodata(&mut ops, 56, "vp_fail");
    // RESOURCE_FLUSH — rect {0,0,hi_w,hi_h}, res 1.
    req_hdr(&mut ops, VIO_GPU_RESOURCE_FLUSH);
    ops.push(sw(X0, T2, 24));
    ops.push(sw(X0, T2, 28));
    sw_i(&mut ops, T2, 32, i64::from(hi_w));
    sw_i(&mut ops, T2, 36, i64::from(hi_h));
    sw_i(&mut ops, T2, 40, 1);
    sw_i(&mut ops, T2, 44, 0);
    submit_nodata(&mut ops, 48, "vp_fail");
    putc_str(&mut ops, "VIRTIO-PAINT\n");
    ops.push(Op::Jal {
        rd: X0,
        to: "vp_out".into(),
    });
    ops.push(Op::Label("vp_fail".into()));
    putc_str(&mut ops, "VIRTIO-PAINT-FAIL\n");
    ops.push(Op::Label("vp_out".into()));
    ops.push(ld_x(xlen, RA, SP, 0));
    ops.push(ld_x(xlen, T3, SP, 8));
    ops.push(ld_x(xlen, T4, SP, 16));
    ops.push(ld_x(xlen, T5, SP, 24));
    ops.push(ld_x(xlen, T6, SP, 32));
    ops.push(Op::Addi {
        rd: SP,
        rs: SP,
        imm: 48,
    });
    ops.push(ret());
    Node {
        purpose: Purpose::Virtio,
        ops,
    }
}
