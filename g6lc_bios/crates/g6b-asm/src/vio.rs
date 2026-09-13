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
use crate::dom::signbit;
use crate::encode::{
    A0, A1, A2, A3, A4, A5, A6, A7, RA, S0, S1, S2, S3, S4, S5, S6, SP, T0, T1, T2, T3, T4, T5, T6,
    X0,
};
use crate::encode::{
    SBI_PUTCHAR, VIO_BLK_SECTOR, VIO_BLK_S_OK, VIO_BLK_T_IN, VIO_DESC_NEXT, VIO_DESC_WRITE,
    VIO_DEV_BLK, VIO_DEV_GPU, VIO_DEV_INPUT, VIO_F_VERSION_1, VIO_GPU_FMT_B8G8R8X8,
    VIO_GPU_F_VIRGL, VIO_GPU_GET_DISPLAY_INFO, VIO_GPU_RESOURCE_ATTACH_BACKING,
    VIO_GPU_RESOURCE_CREATE_2D, VIO_GPU_RESOURCE_FLUSH, VIO_GPU_RESP_OK_DISPLAY_INFO,
    VIO_GPU_RESP_OK_NODATA, VIO_GPU_SET_SCANOUT, VIO_GPU_TRANSFER_FROM_HOST_3D,
    VIO_GPU_TRANSFER_TO_HOST_2D, VIO_INP_EV_ABS, VIO_INP_EV_KEY, VIO_MAGIC, VIO_MMIO_BASE,
    VIO_MMIO_SLOTS,
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
/// device-base scratch @0x3f0, irq counter @0x3f4, keyboard-device scratch
/// @0x3f8, `G6FB` scanout descriptor @0x400 (28B — the
/// `simple-framebuffer`-shaped handoff), then the virtio-input eventq block:
/// desc table @0x440 (8×16B), avail @0x4c0, used @0x4e0 (72B used), event
/// buffers @0x530 (8×8B `virtio_input_event`), used-idx shadow @0x570,
/// key-queue head/tail @0x574/0x578, key codes @0x580 (16×4B), tablet-device
/// scratch @0x5f4, `DispSel` @0x600, tablet eventq @0x680 (desc / avail @0x700 /
/// used @0x720 / evbuf @0x770 / used-idx @0x7b0), virtio-net scratch @0x7c0,
/// virtio-blk scratch @0x7c4, then the blk requestq: desc @0x800, avail @0x880,
/// used @0x8c0, request header @0x920, status @0x930, used-idx @0x934, cached
/// sector @0x938, and one 512-byte sector buffer @0x940. The FAT file reader
/// uses an extra 1 KiB scratch at 0xc00, so `__vio` is sized to 0x1000.
pub const VIO_BSS: u64 = 0x1000;

/// Compact persist (`__ui_cap`) after `__ui_dom`. Dirty tiles + live node
/// count for the web engine. Not the 48-row `__ui_dom` table.
pub const UI_CAP_MAGIC: u32 = u32::from_le_bytes(*b"G6CP");
/// Host exec / later guest compact paint filled `__scan_fb`; skip FbExpandSel.
pub const UI_CAP_FLAG_WEB: u32 = 1;
/// A *rendered* web canvas owns the surface — set only by `WebBlit` (packed
/// `__web_pk` decode) and the exec-model `inject_web_present`. `DomtRaster`'s
/// text-face stamp carries `FLAG_WEB` alone so `WebBlit` can tell its own
/// canvas apart from the block-flow fallback it must not suppress.
pub const UI_CAP_FLAG_PK: u32 = 2;
pub const UI_CAP_OFF_FLAGS: i32 = 4;
pub const UI_CAP_OFF_NODES: i32 = 8;
pub const UI_CAP_OFF_NTILE: i32 = 12;
pub const UI_CAP_OFF_RECTS: i32 = 16;
pub const UI_CAP_MAX_TILES: usize = 64;
pub const UI_CAP_BYTES: u64 = 16 + (UI_CAP_MAX_TILES as u64) * 16;

/// `DispSel` result block in `__vio` — the *runtime* answer to "which output
/// won and what feeds it". Written once at boot by `DispSel`, read by the paint
/// path and dumped by the UART `Disp` command. Everything before `0x600` is the
/// virtio/input/G6FB state; this block is appended so those offsets are stable.
pub const DISP_SEL_OFF: i32 = 0x600;
/// Resolved [`g6b_spec::OutputClass`] code (0 none, 1 virtio-gpu, 2
/// uncore-scanout, 3 pcie-linear-fb).
pub const DISP_SEL_CLASS: i32 = DISP_SEL_OFF;
/// Index into the gen-time `proxy_outputs` table.
pub const DISP_SEL_IDX: i32 = DISP_SEL_OFF + 0x04;
/// Resolved [`g6b_spec::Surface`] code (0 vga, 1 gpu).
pub const DISP_SEL_SURFACE: i32 = DISP_SEL_OFF + 0x08;
pub const DISP_SEL_W: i32 = DISP_SEL_OFF + 0x0c;
pub const DISP_SEL_H: i32 = DISP_SEL_OFF + 0x10;
pub const DISP_SEL_STRIDE: i32 = DISP_SEL_OFF + 0x14;
/// Framebuffer the winning output scans out of, low/high 32.
pub const DISP_SEL_FB_LO: i32 = DISP_SEL_OFF + 0x18;
pub const DISP_SEL_FB_HI: i32 = DISP_SEL_OFF + 0x1c;
/// Hot-plug state: `0` unknown (contract rev 1 has no HPD register — see
/// `architecture/uncore/hdmi-display.md`), `1` connected, `2` disconnected.
pub const DISP_SEL_HPD: i32 = DISP_SEL_OFF + 0x20;
/// `PciProbe` result: BAR0 of a class-0x03 controller with a usable linear
/// framebuffer, or `0` when none was accepted.
pub const DISP_PCI_FB: i32 = DISP_SEL_OFF + 0x24;
/// `vendor << 16 | device` of the accepted controller, for diagnostics.
pub const DISP_PCI_ID: i32 = DISP_SEL_OFF + 0x28;

/// HPD state codes.
pub const HPD_UNKNOWN: i64 = 0;
pub const HPD_CONNECTED: i64 = 1;
pub const HPD_ABSENT: i64 = 2;
/// Contract revision that adds `HPD`/`EDID_*`. Revision 1 boards report
/// `HPD_UNKNOWN` and are still accepted on `MAGIC` alone.
pub const DISP_REV_HPD: u32 = 2;
/// Revision-2 register offsets (`architecture/uncore/hdmi-display.md`).
pub const DISP_REG_REV: i32 = 0x04;
pub const DISP_REG_HPD: i32 = 0x2c;
pub const DISP_REG_EDID_W: i32 = 0x30;
pub const DISP_REG_EDID_H: i32 = 0x34;
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
/// Scratch u32 holding the probed virtio-net (DeviceID 1) mmio base.
pub const VIO_NET_OFF: i32 = 0x7c0;
/// Used-buffer interrupt counter in `__vio`, bumped by `trap_vio` (the SEI
/// path for the virtio-mmio PLIC source, irq 1+slot on QEMU virt — see the
/// machine DTB).
pub const VIO_IRQF_OFF: i32 = 0x3f4;
/// `G6FB` scanout handoff descriptor at `__vio+0x400`: `{magic, fb u64,
/// width, height, stride, format=1 (x8r8g8b8)}` — the shape a Linux
/// `simple-framebuffer`/`simpledrm` node inherits, so the same surface
/// serves the BIOS scanout and the OS.
pub const DISP_DESC_OFF: i32 = 0x400;
/// Scratch u32 holding the probed virtio-input (DeviceID 18) mmio base
/// (keyboard — first DeviceID 18 slot).
pub const VIO_INP_OFF: i32 = 0x3f8;
/// Input eventq descriptor table (8 descs — one per posted event buffer).
pub const INP_DESC_OFF: i32 = 0x440;
pub const INP_AVAIL_OFF: i32 = 0x4c0;
pub const INP_USED_OFF: i32 = 0x4e0;
/// 8 `virtio_input_event` buffers (8B each: u16 type, u16 code, u32 value).
pub const INP_EVBUF_OFF: i32 = 0x530;
/// Shadow of the last-consumed eventq used idx (`InpDrain` walks forward).
pub const INP_LAST_USED: i32 = 0x570;
/// Bounded key queue: head (producer), tail (consumer) u16s.
pub const INP_KQ_HEAD: i32 = 0x574;
pub const INP_KQ_TAIL: i32 = 0x578;
/// 16 u32 entries `(code << 8) | value` — consumed by the `Keys` UART
/// command / the DOM input lane.
pub const INP_KQ_OFF: i32 = 0x580;
/// 16B scratch: `DomKey` builds `"key <8hex>"` here before `WasmDomText`
/// copies it into the `inp.last` DOM row (0x5c0..0x5d0 of `__vio`).
pub const INP_KEYTXT_OFF: i32 = 0x5c0;
/// `NAV_SEEN` — `INP_KQ` index watermark: entries before it are already
/// consumed by `DomNav` (non-destructive — `Keys` still dumps the ring).
pub const NAV_SEEN_OFF: i32 = 0x5d0;
/// `NAV_SEL` — selected menu index (0..`spec.menus().len()`).
pub const NAV_SEL_OFF: i32 = 0x5d4;
/// `NAV_OPEN` — Enter latch: 1 = the selected menu is "open".
pub const NAV_OPEN_OFF: i32 = 0x5d8;
/// `NAV_TEXT` — 16B scratch holding the `nav.sel` row text
/// (`"nav <name>"`/`"open <name>"`). `WasmDomText` stores the pointer, so
/// this must be a dedicated buffer — not the `INP_KEYTXT` scratch `DomKey`
/// rewrites on every key.
pub const NAV_TEXT_OFF: i32 = 0x5e0;
/// `VIO_BUSY` — ctrlq re-entrancy guard: `VioCmd` sets it for the length of
/// a transaction and clears on every exit; `VioPaint`/`trap_timer` skip the
/// repaint while set so a trap-time paint can never preempt a boot-time
/// `VioCmd` mid-transaction and corrupt the shared rings (the trap frame
/// saves registers, but the descriptor chain is shared state, not regs).
pub const VIO_BUSY_OFF: i32 = 0x5f0;
/// Scratch u32 holding the virtio-tablet (second DeviceID 18) mmio base.
/// Sits in the 12B gap between `VIO_BUSY` (0x5f0) and `DispSel` (0x600).
pub const VIO_TAB_OFF: i32 = 0x5f4;
/// `CLI_SEEN` — `INP_KQ` index watermark for the zealcli edit line, separate
/// from `NAV_SEEN` so the `Keys` dump and the DOM navigator keep their own
/// view of the same non-destructive ring.
pub const CLI_SEEN_OFF: i32 = 0x5f8;
/// `DOMT_SEEN` — `INP_KQ` index watermark for the guest DOM-tree input
/// consumer (`DomtKey`), a fourth reader of the same ring so the tree's
/// key dispatch does not disturb `NAV_SEEN`/`CLI_SEEN`/`Keys`.
pub const DOMT_SEEN_OFF: i32 = 0x5fc;
/// Scratch u32 holding the probed virtio-blk (DeviceID 2) mmio base, at
/// `__vio+0x7c4`. Reached as [`BLK_DEV`] from the blk base register.
pub const VIO_BLK_OFF: i32 = 0x7c4;
/// The blk block starts past the 12-bit immediate reach of `__vio` (0x800 > 2047),
/// so every routine forms **one base register** for it and uses small offsets from
/// there. That is cheaper than an address computation per access and it is why the
/// offsets below are relative rather than absolute.
pub const BLK_BASE: i64 = 0x800;
/// Device-base scratch, relative to [`BLK_BASE`] (`0x800 - 0x3c = 0x7c4`).
pub const BLK_DEV: i32 = -0x3c;
/// virtio-blk **requestq** (queue 0) — the rings and buffers that let the payload
/// read a sector itself. A request is a three-descriptor chain, which is the shape
/// the device requires (virtio spec 5.2.6): a read-only 16-byte header, a
/// device-writable data buffer, and a one-byte device-writable status.
/// All offsets are relative to [`BLK_BASE`].
pub const BLK_DESC_OFF: i32 = 0x000;
pub const BLK_AVAIL_OFF: i32 = 0x080;
pub const BLK_USED_OFF: i32 = 0x0c0;
/// `virtio_blk_req` header: `{u32 type, u32 reserved, u64 sector}`.
pub const BLK_REQ_OFF: i32 = 0x120;
/// One status byte the device writes (`VIRTIO_BLK_S_OK` = 0).
pub const BLK_STATUS_OFF: i32 = 0x130;
/// Used-ring index shadow for the requestq.
pub const BLK_LAST_USED: i32 = 0x134;
/// The sector this buffer currently holds, +1 (0 = nothing read yet), so a reader
/// can tell a cached sector 0 from an empty buffer.
pub const BLK_CUR_SECTOR: i32 = 0x138;
/// The medium signature `BlkSig` latched: 0 none, 1 fat, 2 gpt, 3 mbr, 4 ext4,
/// 5 raw. `FatRead`/`Ext4Read` gate on this rather than re-parsing the buffer,
/// because `BLK_CUR_SECTOR` alone cannot say *why* a sector is cached.
pub const BLK_SIG: i32 = 0x13c;
/// One 512-byte sector landing zone.
pub const BLK_DATA_OFF: i32 = 0x140;
/// Tablet eventq — after `DispSel` (0x600..0x62c) and the original 0x680 BSS.
pub const TAB_DESC_OFF: i32 = 0x680;
pub const TAB_AVAIL_OFF: i32 = 0x700;
pub const TAB_USED_OFF: i32 = 0x720;
/// 8 `virtio_input_event` buffers for the tablet.
pub const TAB_EVBUF_OFF: i32 = 0x770;
/// Shadow of the last-consumed tablet used idx.
pub const TAB_LAST_USED: i32 = 0x7b0;
/// Pointer scratch — `TabDrain` decodes each consumed `virtio_input_event`
/// into the last-seen `ABS_X`/`ABS_Y` (tablet units `0..=VIO_ABS_MAX`) and
/// latches `PTR_CLICK` on a `BTN_LEFT` press. A later `DomtPtr` consumes the
/// click flag, scales to display px, hit-tests `__dom` and dispatches
/// `EV_CLICK`. These are plain `__vio` BSS slots (no lock — the eventq drain
/// is single-writer from `trap_tab`).
pub const PTR_X: i32 = 0x7b4;
/// Last-seen tablet `ABS_Y`.
pub const PTR_Y: i32 = 0x7b8;
/// Pending primary-click flag — set by `TabDrain`, consumed by `DomtPtr`.
pub const PTR_CLICK: i32 = 0x7bc;
/// Linux `EV_KEY` codes the menu navigator consumes (virtio-input carries
/// the kernel's `KEY_*` codes verbatim — QEMU `sendkey down`/`ret`).
pub const VIO_KEY_ESC: i64 = 1;
pub const VIO_KEY_ENTER: i64 = 28;
pub const VIO_KEY_F10: i64 = 68;
pub const VIO_KEY_HOME: i64 = 102;
pub const VIO_KEY_UP: i64 = 103;
pub const VIO_KEY_LEFT: i64 = 105;
pub const VIO_KEY_RIGHT: i64 = 106;
pub const VIO_KEY_END: i64 = 107;
pub const VIO_KEY_DOWN: i64 = 108;
/// Linux `BTN_LEFT` (EV_KEY) — virtio-tablet / virtio-mouse primary click.
pub const VIO_BTN_LEFT: i64 = 0x110;
/// Linux `BTN_RIGHT`.
pub const VIO_BTN_RIGHT: i64 = 0x111;
/// Linux `BTN_MIDDLE`.
pub const VIO_BTN_MIDDLE: i64 = 0x112;
/// Linux `ABS_X` / `REL_X` axis code.
pub const VIO_ABS_X: i64 = 0;
/// Linux `ABS_Y` / `REL_Y` axis code.
pub const VIO_ABS_Y: i64 = 1;
/// Linux `REL_X` (same numeric code as `ABS_X`; distinguished by `EV_*` type).
pub const VIO_REL_X: i64 = 0;
/// Linux `REL_Y`.
pub const VIO_REL_Y: i64 = 1;
/// QEMU `INPUT_EVENT_ABS_MAX` — virtio-tablet `ABS_X`/`ABS_Y` range.
pub const VIO_ABS_MAX: u32 = 0x7fff;
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

fn jump(to: &str) -> Op {
    Op::Jal {
        rd: X0,
        to: to.into(),
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
/// → used-ring wait → `VIRTIO-INFO`. Fail-closed: any mismatch or timeout
/// prints `VIRTIO-GPU-FAIL`; an absent device returns silently (`VioProbe`
/// already printed `VIRTIO-GPU-NONE`). The used wait is WFI-driven when
/// `uncore.plic` armed SEIE (`PlicInit` runs earlier in the boot flow).
pub fn init_node(o: Object, spec: &BoardSpec) -> Node {
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
        // features: accept VIRTIO_F_VERSION_1 (word 1) plus, in word 0, the
        // VIRTIO_GPU_F_VIRGL bit iff the device offers it (a `virtio-gpu-gl-
        // device`/`proxy.gl` board; a plain virtio-gpu-device offers 0, so the
        // mask accepts nothing — fail-closed, no codegen branch needed).
        sw(X0, T0, VIO_REG_FEATURES_SEL),
        lw(T2, T0, VIO_REG_FEATURES),
        Op::Andi {
            rd: T2,
            rs: T2,
            imm: VIO_GPU_F_VIRGL as i32,
        },
        sw(X0, T0, VIO_REG_DRV_FEATURES_SEL),
        sw(T2, T0, VIO_REG_DRV_FEATURES),
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
        Op::Beq {
            rs1: T4,
            rs2: X0,
            to: "vi2_fail".into(),
        },
    ]);
    if spec.uncore.plic {
        ops.push(Op::Wfi);
    }
    ops.extend([
        Op::Jal {
            rd: X0,
            to: "vi2_poll".into(),
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

/// PCI config-space offsets used by the display scan.
pub const PCI_CFG_ID: i32 = 0x00;
pub const PCI_CFG_CLASS: i32 = 0x08;
pub const PCI_CFG_BAR0: i32 = 0x10;
/// Base class 0x03 = display controller.
pub const PCI_CLASS_DISPLAY: i64 = 0x03;
/// Devices probed on bus 0, function 0 only. Bounded, and enough for the
/// single-bus topologies this BIOS supports.
pub const PCI_MAX_DEV: i64 = 32;
/// ECAM stride per device on bus 0 function 0 (`dev << 15`).
pub const PCI_DEV_STRIDE: i64 = 0x8000;

/// `PciProbe` — read-only PCIe display-controller scan.
///
/// Walks bus 0, function 0, devices `0..PCI_MAX_DEV` in the declared ECAM
/// window looking for base class `0x03`, then accepts BAR0 **only** if it is a
/// memory BAR (bit0 clear) whose address is nonzero and inside the declared
/// `pcie.mmio` window. The accepted address lands in `DISP_PCI_FB` and
/// `vendor<<16|device` in `DISP_PCI_ID`; otherwise `DISP_PCI_FB` stays 0 and
/// the mux falls to the next rung.
///
/// What this deliberately does **not** do:
/// - assign or size BARs (that is resource allocation, which needs the host
///   bridge's window arbiter — only firmware-assigned BARs are honoured);
/// - touch AMD AtomBIOS/DCN or NVIDIA GSP devinit, so an adapter that has not
///   already been mode-set by something else is *demoted, not driven*;
/// - probe buses behind a bridge.
///
/// Prints `PCI-GPU <vendor:device hex>` on acceptance, `PCI-GPU-DEMOTED` when a
/// display controller was found without a usable linear BAR, `PCI-GPU-NONE`
/// when none was found at all. Leaf, t-regs only.
pub fn pci_probe_node(spec: &BoardSpec) -> Node {
    let ecam = spec.pcie_ecam().unwrap_or(0) as i64;
    let (mmio, len) = spec.pcie_mmio_window().unwrap_or((0, 0));
    let (lo, hi) = (mmio as i64, mmio.saturating_add(len) as i64);
    let mut ops = vec![
        Op::Comment(format!(
            "PciProbe — ECAM {ecam:#x} bus0 fn0 dev0..{PCI_MAX_DEV}, class 0x03, \
             BAR0 must land in {lo:#x}..{hi:#x} (read-only; no modeset)"
        )),
        Op::Glob("PciProbe".into()),
        Op::Label("PciProbe".into()),
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
        // Fail-closed default: no framebuffer accepted.
        sw(X0, T5, DISP_PCI_FB),
        sw(X0, T5, DISP_PCI_ID),
        Op::Li { rd: T1, imm: ecam },
        Op::Li {
            rd: T2,
            imm: PCI_MAX_DEV,
        },
        // t4 tracks "saw a display controller but could not use it".
        Op::Li { rd: T4, imm: 0 },
        Op::Label("pci_dev".into()),
        // Vendor/device: 0xffffffff means no device in this slot.
        lw(T0, T1, PCI_CFG_ID),
        Op::Li { rd: T3, imm: -1 },
        Op::Beq {
            rs1: T0,
            rs2: T3,
            to: "pci_next".into(),
        },
        Op::Beq {
            rs1: T0,
            rs2: X0,
            to: "pci_next".into(),
        },
        // Base class is the top byte of the class word.
        lw(T3, T1, PCI_CFG_CLASS),
        Op::Srli {
            rd: T3,
            rs: T3,
            shamt: 24,
        },
        Op::Andi {
            rd: T3,
            rs: T3,
            imm: 0xff,
        },
        Op::Li {
            rd: A1,
            imm: PCI_CLASS_DISPLAY,
        },
        Op::Bne {
            rs1: T3,
            rs2: A1,
            to: "pci_next".into(),
        },
        // A display controller exists; remember that even if its BAR is
        // unusable, so the diagnostic can say "demoted" rather than "none".
        Op::Li { rd: T4, imm: 1 },
        Op::Addi {
            rd: A3,
            rs: T0,
            imm: 0,
        },
        // BAR0: bit0 set => I/O space, which is not a framebuffer.
        lw(T3, T1, PCI_CFG_BAR0),
        Op::Andi {
            rd: A1,
            rs: T3,
            imm: 1,
        },
        Op::Bne {
            rs1: A1,
            rs2: X0,
            to: "pci_next".into(),
        },
        // Mask the memory-BAR type/prefetch bits (low 4) to get the address.
        Op::Andi {
            rd: T3,
            rs: T3,
            imm: -16,
        },
        Op::Beq {
            rs1: T3,
            rs2: X0,
            to: "pci_next".into(),
        },
    ];
    // Window check: refuse a BAR firmware left outside the declared window.
    // Unsigned compare is synthesised from the two bounds with `sltu`-free
    // arithmetic: (bar - lo) must be < (hi - lo).
    ops.extend([
        Op::Li { rd: A1, imm: lo },
        Op::Sub {
            rd: A2,
            rs1: T3,
            rs2: A1,
        },
        Op::Li {
            rd: A1,
            imm: hi.saturating_sub(lo),
        },
        Op::Sltu {
            rd: A2,
            rs1: A2,
            rs2: A1,
        },
        Op::Beq {
            rs1: A2,
            rs2: X0,
            to: "pci_next".into(),
        },
        // Accepted.
        sw(T3, T5, DISP_PCI_FB),
        sw(A3, T5, DISP_PCI_ID),
    ]);
    putc_str(&mut ops, "PCI-GPU\n");
    ops.push(ret());
    ops.extend([
        Op::Label("pci_next".into()),
        Op::Li {
            rd: A1,
            imm: PCI_DEV_STRIDE,
        },
        Op::Add {
            rd: T1,
            rs1: T1,
            rs2: A1,
        },
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: -1,
        },
        Op::Bne {
            rs1: T2,
            rs2: X0,
            to: "pci_dev".into(),
        },
        // Exhausted: distinguish "found one but unusable" from "found none".
        Op::Beq {
            rs1: T4,
            rs2: X0,
            to: "pci_none".into(),
        },
    ]);
    putc_str(&mut ops, "PCI-GPU-DEMOTED\n");
    ops.push(ret());
    ops.push(Op::Label("pci_none".into()));
    putc_str(&mut ops, "PCI-GPU-NONE\n");
    ops.push(ret());
    Node {
        purpose: Purpose::PciScan,
        ops,
    }
}

/// `DispSel` — the runtime display-output mux.
///
/// Walks the candidate ladder from `BoardSpec::display_outputs()` **highest
/// priority first** and latches the first rung that is actually present into
/// the `__disp` block (`DISP_SEL_*` in `__vio`). The candidate set and every
/// geometry constant are gen-time; only *presence* is a boot-time fact, which
/// is exactly what needs resolving at runtime:
///
/// | rung | presence test |
/// |---|---|
/// | `pcie-linear-fb` | `DISP_PCI_FB != 0` — `PciProbe` accepted a linear BAR |
/// | `uncore-scanout` | `MAGIC == 'G6DS'` at the declared window |
/// | `virtio-gpu` | `VIO_DEV_OFF != 0` — `VioProbe` bound a DeviceID-16 slot |
/// | `none` | always taken last |
///
/// The surface latched with the winner is that output's default, so the low-res
/// plane is never upscaled onto a GPU-class output unless something later
/// overrides it. On the uncore rung, `REV >= 2` reads the `HPD` register;
/// revision 1 has none, so `HPD_UNKNOWN` is recorded and the engine is still
/// accepted on `MAGIC` alone — do not read that as hot-plug detection.
///
/// Prints `DISP-SEL <class><surface>` as two hex digits (the shared `hexdig`
/// table). Leaf, t-regs only.
pub fn disp_sel_node(spec: &BoardSpec) -> Node {
    let outs = spec.display_outputs();
    // An explicit `kernel.proxy.surface` overrides every rung's class default,
    // exactly as `BoardSpec::default_surface()` does on the host — otherwise
    // the guest and the host would disagree about which surface is live.
    let forced = g6b_spec::Surface::parse(&spec.kernel.proxy.surface);
    let mut ops = vec![
        Op::Comment(format!(
            "DispSel — resolve {} candidate output(s) at boot, highest priority first",
            outs.len()
        )),
        Op::Glob("DispSel".into()),
        Op::Label("DispSel".into()),
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
    ];
    // Each rung stores its constants then jumps to the shared report tail.
    for (idx, o) in outs.iter().enumerate() {
        let next = format!("ds_try{}", idx + 1);
        ops.push(Op::Comment(format!(
            "  rung {} {} pri={} {}x{} surface={}",
            o.id,
            o.class.as_str(),
            o.class.priority(),
            o.w,
            o.h,
            o.surface.as_str()
        )));
        match o.class {
            g6b_spec::OutputClass::PcieLinearFb => {
                ops.extend([
                    lw(T0, T5, DISP_PCI_FB),
                    Op::Beq {
                        rs1: T0,
                        rs2: X0,
                        to: next.clone(),
                    },
                    sw(T0, T5, DISP_SEL_FB_LO),
                ]);
                sw_i(&mut ops, T5, DISP_SEL_HPD, HPD_CONNECTED);
            }
            g6b_spec::OutputClass::UncoreScanout => {
                let base = o.base.unwrap_or(0) as i64;
                ops.extend([
                    Op::Li { rd: T1, imm: base },
                    lw(T0, T1, 0),
                    Op::Li {
                        rd: T2,
                        imm: i64::from(DISP_MAGIC),
                    },
                    Op::Bne {
                        rs1: T0,
                        rs2: T2,
                        to: next.clone(),
                    },
                    // Contract-revision gate. Only the revision that actually
                    // defines `HPD` is read; revision 1 has no such register
                    // and must report unknown rather than reading a reserved
                    // offset. A later revision has to opt in here explicitly —
                    // there is no `blt` in this IR and guessing forward
                    // compatibility on a register map is how you read garbage.
                    lw(T0, T1, DISP_REG_REV),
                    Op::Li {
                        rd: T2,
                        imm: i64::from(DISP_REV_HPD),
                    },
                    Op::Bne {
                        rs1: T0,
                        rs2: T2,
                        to: format!("ds_norev{idx}"),
                    },
                    // HPD bit0: set = sink connected. Map 1 -> HPD_CONNECTED,
                    // 0 -> HPD_ABSENT via `2 - bit`.
                    lw(T0, T1, DISP_REG_HPD),
                    Op::Andi {
                        rd: T0,
                        rs: T0,
                        imm: 1,
                    },
                    Op::Li {
                        rd: T2,
                        imm: HPD_ABSENT,
                    },
                    Op::Sub {
                        rd: T0,
                        rs1: T2,
                        rs2: T0,
                    },
                    Op::Jal {
                        rd: X0,
                        to: format!("ds_hpd{idx}"),
                    },
                    Op::Label(format!("ds_norev{idx}")),
                    Op::Li {
                        rd: T0,
                        imm: HPD_UNKNOWN,
                    },
                    Op::Label(format!("ds_hpd{idx}")),
                    sw(T0, T5, DISP_SEL_HPD),
                ]);
                sw_i(&mut ops, T5, DISP_SEL_FB_LO, 0);
            }
            g6b_spec::OutputClass::VirtioGpu => {
                ops.extend([
                    lw(T0, T5, VIO_DEV_OFF),
                    Op::Beq {
                        rs1: T0,
                        rs2: X0,
                        to: next.clone(),
                    },
                ]);
                sw_i(&mut ops, T5, DISP_SEL_HPD, HPD_UNKNOWN);
                sw_i(&mut ops, T5, DISP_SEL_FB_LO, 0);
            }
            g6b_spec::OutputClass::None => {
                sw_i(&mut ops, T5, DISP_SEL_HPD, HPD_UNKNOWN);
                sw_i(&mut ops, T5, DISP_SEL_FB_LO, 0);
            }
        }
        sw_i(&mut ops, T5, DISP_SEL_CLASS, i64::from(o.class.code()));
        sw_i(&mut ops, T5, DISP_SEL_IDX, idx as i64);
        sw_i(
            &mut ops,
            T5,
            DISP_SEL_SURFACE,
            i64::from(forced.unwrap_or(o.surface).code()),
        );
        sw_i(&mut ops, T5, DISP_SEL_W, i64::from(o.w));
        sw_i(&mut ops, T5, DISP_SEL_H, i64::from(o.h));
        sw_i(&mut ops, T5, DISP_SEL_STRIDE, i64::from(o.stride()));
        sw_i(&mut ops, T5, DISP_SEL_FB_HI, 0);
        ops.push(jump("ds_report"));
        ops.push(Op::Label(next));
    }
    // The `none` rung always stores, so the last `ds_tryN` label is only
    // reachable if the table were empty — `display_outputs()` guarantees it is
    // not, but fall through to the report rather than into whatever follows.
    ops.push(Op::Label("ds_report".into()));
    putc_str(&mut ops, "DISP-SEL ");
    // Two hex digits: class then surface, via the shared `hexdig` table.
    for off in [DISP_SEL_CLASS, DISP_SEL_SURFACE] {
        ops.extend([
            lw(T0, T5, off),
            Op::Andi {
                rd: T0,
                rs: T0,
                imm: 0xf,
            },
            Op::La {
                rd: A6,
                addr: Addr::Label("hexdig".into()),
            },
            Op::Add {
                rd: A6,
                rs1: A6,
                rs2: T0,
            },
            Op::Lbu {
                rd: A0,
                rs: A6,
                off: 0,
            },
            Op::Li {
                rd: A7,
                imm: SBI_PUTCHAR,
            },
            Op::Ecall,
        ]);
    }
    putc_str(&mut ops, "\n");
    ops.push(ret());
    Node {
        purpose: Purpose::DisplayMux,
        ops,
    }
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
/// (0 on timeout / unprobed device). Clobbers t0..t6, a0. When
/// `uncore.plic` is live the completion wait is WFI-driven: each poll miss
/// sleeps until the virtio used-buffer irq (or any other enabled source —
/// the loop bound still bounds wake-check cycles, and the periodic timer
/// keeps wakes coming so a silent device degrades to a bounded timeout).
pub fn cmd_node(spec: &BoardSpec) -> Node {
    let wfi = spec.uncore.plic;
    let mut ops = vec![
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
        // Re-entrancy: a trap-context repaint (trap_timer/Ui) may land while
        // a boot-context VioCmd sleeps on its wfi — the shared desc chain
        // and avail idx would be corrupted. Fail closed: busy → a0=0.
        lw(T2, T5, VIO_BUSY_OFF),
        Op::Bne {
            rs1: T2,
            rs2: X0,
            to: "vqc_busy".into(),
        },
        Op::Li { rd: T2, imm: 1 },
        sw(T2, T5, VIO_BUSY_OFF),
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
        Op::Beq {
            rs1: T4,
            rs2: X0,
            to: "vqc_ret0".into(),
        },
    ];
    if wfi {
        // Sleep until the virtio used-buffer irq (or any enabled source)
        // instead of burning the poll budget — the loop bound still caps
        // wake-check cycles and the periodic timer guarantees wakes.
        ops.push(Op::Wfi);
    }
    ops.extend([
        Op::Jal {
            rd: X0,
            to: "vqc_poll".into(),
        },
        // Entered while another context holds the ctrlq — return a0=0
        // without touching the flag (it belongs to the outer transaction).
        Op::Label("vqc_busy".into()),
        Op::Li { rd: A0, imm: 0 },
        ret(),
        Op::Label("vqc_ret0".into()),
        sw(X0, T5, VIO_BUSY_OFF),
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
        sw(X0, T5, VIO_BUSY_OFF),
        ret(),
    ]);
    Node {
        purpose: Purpose::Virtio,
        ops,
    }
}

/// `VioCmdBuf` — 3-descriptor ctrlq submitter for commands that carry an extra
/// OUT payload (the `SUBMIT_3D` execbuffer). In: a0 = request bytes (at
/// `__vio+VIO_REQ_OFF`), a1 = response bytes (`__vio+VIO_RSP_OFF`), a2 = OUT
/// payload pointer, a3 = OUT payload bytes. Chain: desc0=req OUT → desc1=buf
/// OUT → desc2=resp WRITE. Out: a0 = response `type` (0 on timeout). Clobbers
/// t0..t6, a0..a3. Same WFI/bounded poll + `VIO_BUSY` guard as `VioCmd`.
pub fn cmdbuf_node(spec: &BoardSpec) -> Node {
    let wfi = spec.uncore.plic;
    let mut ops = vec![
        Op::Comment(
            "VioCmdBuf — submit a 3-desc ctrlq chain (desc0=req OUT, \
                 desc1=execbuf OUT, desc2=resp WRITE); used by SUBMIT_3D"
                .into(),
        ),
        Op::Glob("VioCmdBuf".into()),
        Op::Label("VioCmdBuf".into()),
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
        // Re-entrancy guard, same as VioCmd.
        lw(T2, T5, VIO_BUSY_OFF),
        Op::Bne {
            rs1: T2,
            rs2: X0,
            to: "vcb_busy".into(),
        },
        Op::Li { rd: T2, imm: 1 },
        sw(T2, T5, VIO_BUSY_OFF),
        lw(T6, T5, VIO_DEV_OFF),
        Op::Beq {
            rs1: T6,
            rs2: X0,
            to: "vcb_ret0".into(),
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
        // desc1 = {execbuf a2, a3, NEXT, next=2}
        sw(A2, T5, 16),
        sw(X0, T5, 20),
        sw(A3, T5, 24),
        Op::Li {
            rd: T3,
            imm: i64::from(VIO_DESC_NEXT | (2 << 16)),
        },
        sw(T3, T5, 28),
        // desc2 = {resp, a1, WRITE}
        Op::Addi {
            rd: T2,
            rs: T5,
            imm: VIO_RSP_OFF,
        },
        sw(T2, T5, 32),
        sw(X0, T5, 36),
        sw(A1, T5, 40),
        Op::Li {
            rd: T3,
            imm: i64::from(VIO_DESC_WRITE),
        },
        sw(T3, T5, 44),
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
        Op::Label("vcb_poll".into()),
        lw(T2, T5, VIO_USED_OFF),
        Op::Srli {
            rd: T2,
            rs: T2,
            shamt: 16,
        },
        Op::Beq {
            rs1: T2,
            rs2: T1,
            to: "vcb_done".into(),
        },
        Op::Addi {
            rd: T4,
            rs: T4,
            imm: -1,
        },
        Op::Beq {
            rs1: T4,
            rs2: X0,
            to: "vcb_ret0".into(),
        },
    ];
    if wfi {
        ops.push(Op::Wfi);
    }
    ops.extend([
        Op::Jal {
            rd: X0,
            to: "vcb_poll".into(),
        },
        Op::Label("vcb_busy".into()),
        Op::Li { rd: A0, imm: 0 },
        ret(),
        Op::Label("vcb_ret0".into()),
        sw(X0, T5, VIO_BUSY_OFF),
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
        Op::Label("vcb_done".into()),
        lw(T3, T6, VIO_REG_ISR_STATUS),
        sw(T3, T6, VIO_REG_ISR_ACK),
        lw(A0, T5, VIO_RSP_OFF),
        sw(X0, T5, VIO_BUSY_OFF),
        ret(),
    ]);
    Node {
        purpose: Purpose::Virtio,
        ops,
    }
}

/// `VioVirgl` — the M4 virgl/GLES bring-up, run after `VioScan` on a
/// `virtio-gpu-gl-device` board (`proxy.gl`). It walks the `__virgl_req`
/// record table (`crate::virgl::reqtab`): `GET_CAPSET_INFO` → `GET_CAPSET` →
/// `CTX_CREATE` → `CTX_ATTACH_RESOURCE` → `SUBMIT_3D` (the `__virgl_cmd`
/// execbuffer rides the second OUT descriptor via `VioCmdBuf`) →
/// `TRANSFER_FROM_HOST_3D` → `RESOURCE_FLUSH`. Each record is
/// `[req_len][resp_len][flags][req]`; `flags&1` selects `VioCmdBuf`. Prints
/// `VIRTIO-VIRGL ` once the sequence has been submitted. Requires the scanout
/// resource (id 1) `VioScan` already created/backed/scanned out.
pub fn virgl_node(spec: &BoardSpec) -> Node {
    let xlen = spec.isa.xlen;
    let gp = g6b_spec_proxy(spec);
    let eb_len = crate::virgl::execbuf(gp.0, gp.1).len() as i64;
    let frame = 48i32; // ra + s3..s6
    let mut ops = vec![
        Op::Comment(
            "VioVirgl — virgl bring-up: CAPSET → CTX_CREATE → SUBMIT_3D \
                 (execbuffer) → TRANSFER_FROM_HOST_3D → FLUSH"
                .into(),
        ),
        Op::Glob("VioVirgl".into()),
        Op::Label("VioVirgl".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -frame,
        },
        st_x(xlen, RA, SP, 0),
        st_x(xlen, S3, SP, 8),
        st_x(xlen, S4, SP, 16),
        st_x(xlen, S5, SP, 24),
        st_x(xlen, S6, SP, 32),
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
        Op::La {
            rd: S3,
            addr: Addr::VirglReq,
        },
        Op::Label("vgl_rec".into()),
        // a0 = req_len (0 → done); a1 = resp_len; s6 = flags.
        lw(A0, S3, 0),
        Op::Beq {
            rs1: A0,
            rs2: X0,
            to: "vgl_done".into(),
        },
        lw(A1, S3, 4),
        lw(S6, S3, 8),
        Op::Addi {
            rd: S3,
            rs: S3,
            imm: 12,
        },
        Op::Addi {
            rd: S4,
            rs: A0,
            imm: 0,
        },
        Op::Addi {
            rd: S5,
            rs: A1,
            imm: 0,
        },
        // copy a0 bytes: cursor(s3) → __vio+VIO_REQ (dst t4)
        Op::Addi {
            rd: T4,
            rs: T5,
            imm: VIO_REQ_OFF,
        },
        Op::Li { rd: T0, imm: 0 },
        Op::Label("vgl_copy".into()),
        Op::Beq {
            rs1: T0,
            rs2: A0,
            to: "vgl_copied".into(),
        },
        Op::Add {
            rd: A6,
            rs1: S3,
            rs2: T0,
        },
        Op::Lbu {
            rd: A6,
            rs: A6,
            off: 0,
        },
        Op::Add {
            rd: T1,
            rs1: T4,
            rs2: T0,
        },
        Op::Sb {
            rs2: A6,
            rs1: T1,
            off: 0,
        },
        Op::Addi {
            rd: T0,
            rs: T0,
            imm: 1,
        },
        jump("vgl_copy"),
        Op::Label("vgl_copied".into()),
        // flags&1 → VioCmdBuf (execbuffer OUT desc); else VioCmd.
        Op::Andi {
            rd: T3,
            rs: S6,
            imm: 1,
        },
        Op::Beq {
            rs1: T3,
            rs2: X0,
            to: "vgl_cmd".into(),
        },
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
        Op::La {
            rd: A2,
            addr: Addr::VirglCmd,
        },
        Op::Li {
            rd: A3,
            imm: eb_len,
        },
        Op::Jal {
            rd: RA,
            to: "VioCmdBuf".into(),
        },
        jump("vgl_next"),
        Op::Label("vgl_cmd".into()),
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
            to: "VioCmd".into(),
        },
        Op::Label("vgl_next".into()),
        // cursor += req_len (s4) → next record
        Op::Add {
            rd: S3,
            rs1: S3,
            rs2: S4,
        },
        jump("vgl_rec"),
        Op::Label("vgl_done".into()),
    ];
    // ---- M4b guest readback ----
    // The SUBMIT_3D quad rastered into the device-side `virgl_fb`; attaching
    // `__virgl_out` as RES_RT's guest backing makes TRANSFER_FROM_HOST_3D
    // DMA it back into guest RAM (real `La` — a static reqtab record can't
    // carry the resolved BSS address, so the readback pair is sw-built here).
    let out_bytes = (gp.0 as i64) * (gp.1 as i64) * 4;
    // RESOURCE_ATTACH_BACKING — hdr(24) + res@24 + nr@28 + entry{addr@32,len@40}.
    req_hdr(&mut ops, VIO_GPU_RESOURCE_ATTACH_BACKING);
    sw_i(&mut ops, T2, 16, i64::from(crate::virgl::CTX_ID));
    sw_i(&mut ops, T2, 24, i64::from(crate::virgl::RES_RT));
    sw_i(&mut ops, T2, 28, 1);
    ops.push(Op::La {
        rd: T0,
        addr: Addr::VirglOut,
    });
    ops.push(st_x(xlen, T0, T2, 32)); // entries[0].addr = __virgl_out
    sw_i(&mut ops, T2, 40, out_bytes); // entries[0].length
    sw(X0, T2, 44); // entries[0].pad
    submit_nodata(&mut ops, 48, "vgl_skip");
    // TRANSFER_FROM_HOST_3D — hdr(24) + box{x,y,z,w,h,d}@24 + off@48 + res@56.
    req_hdr(&mut ops, VIO_GPU_TRANSFER_FROM_HOST_3D);
    sw_i(&mut ops, T2, 16, i64::from(crate::virgl::CTX_ID));
    sw_i(&mut ops, T2, 24, 0); // box.x
    sw_i(&mut ops, T2, 28, 0); // box.y
    sw_i(&mut ops, T2, 32, 0); // box.z
    sw_i(&mut ops, T2, 36, i64::from(gp.0)); // box.w
    sw_i(&mut ops, T2, 40, i64::from(gp.1)); // box.h
    sw_i(&mut ops, T2, 44, 1); // box.d
    ops.push(st_x(xlen, X0, T2, 48)); // offset = 0
    sw_i(&mut ops, T2, 56, i64::from(crate::virgl::RES_RT)); // resource_id
    sw_i(&mut ops, T2, 60, 0); // level
    sw_i(&mut ops, T2, 64, 0); // stride (0 → device derives)
    sw_i(&mut ops, T2, 68, 0); // layer_stride
    submit_nodata(&mut ops, 72, "vgl_skip");
    ops.push(Op::Label("vgl_skip".into()));
    putc_str(&mut ops, "VIRTIO-VIRGL ");
    ops.extend([
        ld_x(xlen, RA, SP, 0),
        ld_x(xlen, S3, SP, 8),
        ld_x(xlen, S4, SP, 16),
        ld_x(xlen, S5, SP, 24),
        ld_x(xlen, S6, SP, 32),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: frame,
        },
        ret(),
    ]);
    Node {
        purpose: Purpose::Virtio,
        ops,
    }
}

/// `InpInit` — virtio-input (DeviceID 18) eventq bring-up. `VioProbe` stores
/// the input device base at `__vio+VIO_INP_OFF` (0 → silent return). Performs
/// the same virtio 1.x status handshake as `VioInit` on the input slot, then
/// sets up the *eventq* (queue 0 — virtio-input's event ring is queue 0, the
/// statusq is queue 1 and unused here): 8 posted `virtio_input_event`
/// buffers in `__vio+INP_*`, one `QUEUE_NOTIFY`. Prints `VIRTIO-INPUT-OK`;
/// `VIRTIO-INPUT-FAIL` on a handshake/queue mismatch. Leaf (t-regs only).
pub fn inp_init_node(o: Object) -> Node {
    let mut ops = vec![
        Op::Comment(format!(
            "{} — slot scan for DeviceID 18, then eventq handshake + 8 posted event buffers",
            o.why
        )),
        Op::Glob("InpInit".into()),
        Op::Label("InpInit".into()),
        // Scan the virtio-mmio slots for an input device (the GPU probe
        // already claimed its own slot — this looks for DeviceID 18 only).
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
        Op::Label("ipi_slot".into()),
        lw(T2, T0, 0),
        Op::Li {
            rd: T3,
            imm: i64::from(VIO_MAGIC),
        },
        Op::Bne {
            rs1: T2,
            rs2: T3,
            to: "ipi_next".into(),
        },
        lw(T2, T0, 8),
        Op::Li {
            rd: T3,
            imm: i64::from(VIO_DEV_INPUT),
        },
        Op::Beq {
            rs1: T2,
            rs2: T3,
            to: "ipi_claim".into(),
        },
        Op::Label("ipi_next".into()),
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
            to: "ipi_slot".into(),
        },
        // Scan done: handshake the keyboard (first DeviceID 18) if any.
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
        lw(T0, T5, VIO_INP_OFF),
        Op::Bne {
            rs1: T0,
            rs2: X0,
            to: "ipi_dev".into(),
        },
    ];
    putc_str(&mut ops, "VIRTIO-INPUT-NONE\n");
    ops.push(ret());
    ops.extend([
        Op::Label("ipi_claim".into()),
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
        lw(T2, T5, VIO_INP_OFF),
        Op::Bne {
            rs1: T2,
            rs2: X0,
            to: "ipi_claim_tab".into(),
        },
        sw(T0, T5, VIO_INP_OFF),
        jump("ipi_next"),
        Op::Label("ipi_claim_tab".into()),
        lw(T2, T5, VIO_TAB_OFF),
        Op::Bne {
            rs1: T2,
            rs2: X0,
            to: "ipi_next".into(),
        },
        sw(T0, T5, VIO_TAB_OFF),
        jump("ipi_next"),
        Op::Label("ipi_dev".into()),
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
        // publish the input device base: trap_vio resolves its PLIC source.
        sw(T0, T5, VIO_INP_OFF),
        Op::Addi {
            rd: T6,
            rs: T0,
            imm: 0,
        },
        // reset → bounded readback poll
        sw(X0, T6, VIO_REG_STATUS),
        Op::Li { rd: T4, imm: 4 },
        Op::Label("ipi_rst".into()),
        lw(T2, T6, VIO_REG_STATUS),
        Op::Beq {
            rs1: T2,
            rs2: X0,
            to: "ipi_ack".into(),
        },
        Op::Addi {
            rd: T4,
            rs: T4,
            imm: -1,
        },
        Op::Bne {
            rs1: T4,
            rs2: X0,
            to: "ipi_rst".into(),
        },
        Op::Jal {
            rd: X0,
            to: "ipi_fail".into(),
        },
        Op::Label("ipi_ack".into()),
        Op::Li {
            rd: T2,
            imm: i64::from(VIO_ST_ACK | VIO_ST_DRIVER),
        },
        sw(T2, T6, VIO_REG_STATUS),
        sw(X0, T6, VIO_REG_FEATURES_SEL),
        lw(T2, T6, VIO_REG_FEATURES),
        sw(X0, T6, VIO_REG_DRV_FEATURES_SEL),
        sw(X0, T6, VIO_REG_DRV_FEATURES),
        Op::Li { rd: T2, imm: 1 },
        sw(T2, T6, VIO_REG_FEATURES_SEL),
        lw(T3, T6, VIO_REG_FEATURES),
        Op::Andi {
            rd: T3,
            rs: T3,
            imm: VIO_F_VERSION_1 as i32,
        },
        Op::Li { rd: T2, imm: 1 },
        sw(T2, T6, VIO_REG_DRV_FEATURES_SEL),
        sw(T3, T6, VIO_REG_DRV_FEATURES),
        lw(T2, T6, VIO_REG_STATUS),
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: VIO_ST_FEATURES_OK,
        },
        sw(T2, T6, VIO_REG_STATUS),
        lw(T2, T6, VIO_REG_STATUS),
        Op::Andi {
            rd: T2,
            rs: T2,
            imm: VIO_ST_FEATURES_OK,
        },
        Op::Beq {
            rs1: T2,
            rs2: X0,
            to: "ipi_fail".into(),
        },
        // eventq = queue 0: rings in __vio+INP_*.
        sw(X0, T6, VIO_REG_QUEUE_SEL),
        lw(T2, T6, VIO_REG_QUEUE_NUM_MAX),
        Op::Beq {
            rs1: T2,
            rs2: X0,
            to: "ipi_fail".into(),
        },
        Op::Li {
            rd: T3,
            imm: VIO_QUEUE_NUM,
        },
        sw(T3, T6, VIO_REG_QUEUE_NUM),
        Op::Addi {
            rd: T3,
            rs: T5,
            imm: INP_DESC_OFF,
        },
        sw(T3, T6, VIO_REG_QUEUE_DESC),
        sw(X0, T6, VIO_REG_QUEUE_DESC + 4),
        Op::Addi {
            rd: T3,
            rs: T5,
            imm: INP_AVAIL_OFF,
        },
        sw(T3, T6, VIO_REG_QUEUE_AVAIL),
        sw(X0, T6, VIO_REG_QUEUE_AVAIL + 4),
        Op::Addi {
            rd: T3,
            rs: T5,
            imm: INP_USED_OFF,
        },
        sw(T3, T6, VIO_REG_QUEUE_USED),
        sw(X0, T6, VIO_REG_QUEUE_USED + 4),
        Op::Li { rd: T3, imm: 1 },
        sw(T3, T6, VIO_REG_QUEUE_READY),
        // post 8 event buffers: desc[i] = {evbuf+i*8, len 8, WRITE}.
        Op::Addi {
            rd: T2,
            rs: T5,
            imm: INP_DESC_OFF,
        },
        Op::Addi {
            rd: T3,
            rs: T5,
            imm: INP_EVBUF_OFF,
        },
        Op::Li { rd: T4, imm: 8 },
        Op::Label("ipi_buf".into()),
        sw(T3, T2, 0),
        sw(X0, T2, 4),
        Op::Li { rd: T1, imm: 8 },
        sw(T1, T2, 8),
        Op::Li {
            rd: T1,
            imm: i64::from(VIO_DESC_WRITE),
        },
        sw(T1, T2, 12),
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: 16,
        },
        Op::Addi {
            rd: T3,
            rs: T3,
            imm: 8,
        },
        Op::Addi {
            rd: T4,
            rs: T4,
            imm: -1,
        },
        Op::Bne {
            rs1: T4,
            rs2: X0,
            to: "ipi_buf".into(),
        },
        // avail ring: ring[0..8] = heads 0..7, idx = 8.
        sw(X0, T5, INP_AVAIL_OFF),
        Op::Li {
            rd: T1,
            imm: 0x0001_0000,
        },
        sw(T1, T5, INP_AVAIL_OFF + 4),
        Op::Li {
            rd: T1,
            imm: 0x0003_0002,
        },
        sw(T1, T5, INP_AVAIL_OFF + 8),
        Op::Li {
            rd: T1,
            imm: 0x0005_0004,
        },
        sw(T1, T5, INP_AVAIL_OFF + 12),
        Op::Li {
            rd: T1,
            imm: 0x0007_0006,
        },
        sw(T1, T5, INP_AVAIL_OFF + 16),
        Op::Fence,
        Op::Li {
            rd: T1,
            imm: 0x8_0000,
        },
        sw(T1, T5, INP_AVAIL_OFF),
        Op::Fence,
        sw(X0, T6, VIO_REG_QUEUE_NOTIFY),
        // DRIVER_OK after buffers are posted — the device can fill them as
        // soon as it is live.
        lw(T2, T6, VIO_REG_STATUS),
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: VIO_ST_DRIVER_OK,
        },
        sw(T2, T6, VIO_REG_STATUS),
    ]);
    putc_str(&mut ops, "VIRTIO-INPUT-OK slot=");
    // The slot is the diagnostic that matters: the PLIC source this keyboard
    // uses is `1 + slot`, and *which* slot it lands in depends on how many other
    // virtio-mmio devices the machine was given. Printing it is how a "keys do
    // not arrive" report becomes a one-line answer instead of a bisection.
    ops.extend([
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
        lw(T0, T5, VIO_INP_OFF),
        Op::Li {
            rd: T1,
            imm: VIO_MMIO_BASE as i64,
        },
        Op::Sub {
            rd: T0,
            rs1: T0,
            rs2: T1,
        },
        Op::Srli {
            rd: T0,
            rs: T0,
            shamt: 12,
        },
        // One decimal digit is enough: QEMU virt has 8 virtio-mmio slots.
        Op::Addi {
            rd: A0,
            rs: T0,
            imm: i32::from(b'0'),
        },
        Op::Li {
            rd: A7,
            imm: crate::encode::SBI_PUTCHAR,
        },
        Op::Ecall,
    ]);
    putc_str(&mut ops, " irq=");
    ops.extend([
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
        lw(T0, T5, VIO_INP_OFF),
        Op::Li {
            rd: T1,
            imm: VIO_MMIO_BASE as i64,
        },
        Op::Sub {
            rd: T0,
            rs1: T0,
            rs2: T1,
        },
        Op::Srli {
            rd: T0,
            rs: T0,
            shamt: 12,
        },
        Op::Addi {
            rd: A0,
            rs: T0,
            imm: i32::from(b'0') + VIO_IRQ_BASE as i32,
        },
        Op::Li {
            rd: A7,
            imm: crate::encode::SBI_PUTCHAR,
        },
        Op::Ecall,
    ]);
    putc_str(&mut ops, "\n");
    ops.push(Op::Label("ipi_ret".into()));
    ops.push(ret());
    ops.push(Op::Label("ipi_fail".into()));
    putc_str(&mut ops, "VIRTIO-INPUT-FAIL\n");
    ops.push(ret());
    Node {
        purpose: Purpose::Virtio,
        ops,
    }
}

/// `BlkInit` — virtio-blk (DeviceID 2) probe + requestq bring-up.
///
/// This is the driver that lets the payload **read a disk itself** rather than be
/// handed bytes: the boot picker can only *list* a medium without it, which is why
/// `AUTOBOOT-HANDOFF` has been staged since B97.
///
/// Slot scan for DeviceID 2 → the same virtio 1.x status handshake every other
/// device here performs (reset → ACK|DRIVER → FEATURES_OK readback → queue →
/// DRIVER_OK), with the requestq (queue 0) rings in `__vio+BLK_*`. No features are
/// negotiated beyond `VERSION_1`: read-only sector access needs none, and
/// accepting a feature this driver does not implement is how a device starts
/// speaking a protocol the driver cannot parse. Prints
/// `VIRTIO-BLK <slot>`/`VIRTIO-BLK-OK`, or `VIRTIO-BLK-NONE`/`-FAIL`. Leaf.
pub fn blk_init_node(o: Object) -> Node {
    let mut ops = vec![
        Op::Comment(format!(
            "{} — slot scan for DeviceID 2, then requestq handshake (payload-side sector reads)",
            o.why
        )),
        Op::Glob("BlkInit".into()),
        Op::Label("BlkInit".into()),
        // Scan the virtio-mmio window for a block device.
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
        // The blk block is past the 12-bit reach of `__vio`; form its base once.
        Op::Li {
            rd: T1,
            imm: BLK_BASE,
        },
        Op::Add {
            rd: T5,
            rs1: T5,
            rs2: T1,
        },
        sw(X0, T5, BLK_DEV),
        Op::Li {
            rd: T0,
            imm: VIO_MMIO_BASE as i64,
        },
        Op::Li {
            rd: T4,
            imm: VIO_MMIO_SLOTS,
        },
        Op::Label("blk_scan".into()),
        Op::Beq {
            rs1: T4,
            rs2: X0,
            to: "blk_none".into(),
        },
        lw(T1, T0, 0),
        Op::Li {
            rd: T2,
            imm: i64::from(VIO_MAGIC),
        },
        Op::Bne {
            rs1: T1,
            rs2: T2,
            to: "blk_next".into(),
        },
        lw(T1, T0, 0x08),
        Op::Li {
            rd: T2,
            imm: i64::from(VIO_DEV_BLK),
        },
        Op::Beq {
            rs1: T1,
            rs2: T2,
            to: "blk_found".into(),
        },
        Op::Label("blk_next".into()),
        // The 0x1000 slot stride does not fit a 12-bit immediate.
        Op::Li {
            rd: T2,
            imm: VIO_MMIO_STEP as i64,
        },
        Op::Add {
            rd: T0,
            rs1: T0,
            rs2: T2,
        },
        Op::Addi {
            rd: T4,
            rs: T4,
            imm: -1,
        },
        Op::Jal {
            rd: X0,
            to: "blk_scan".into(),
        },
        Op::Label("blk_none".into()),
    ];
    putc_str(&mut ops, "VIRTIO-BLK-NONE\n");
    ops.push(ret());
    ops.extend([
        Op::Label("blk_found".into()),
        // Publish the base: `BlkRead` and `trap_sei`'s ack path both need it.
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
        // The blk block is past the 12-bit reach of `__vio`; form its base once.
        Op::Li {
            rd: T1,
            imm: BLK_BASE,
        },
        Op::Add {
            rd: T5,
            rs1: T5,
            rs2: T1,
        },
        sw(T0, T5, BLK_DEV),
        Op::Addi {
            rd: T6,
            rs: T0,
            imm: 0,
        },
    ]);
    putc_str(&mut ops, "VIRTIO-BLK ");
    // The slot, as one digit — the same diagnostic the keyboard prints, and for
    // the same reason: the PLIC source is `1 + slot`.
    ops.extend([
        Op::Li {
            rd: T1,
            imm: VIO_MMIO_BASE as i64,
        },
        Op::Sub {
            rd: T1,
            rs1: T0,
            rs2: T1,
        },
        Op::Srli {
            rd: T1,
            rs: T1,
            shamt: 12,
        },
        Op::Addi {
            rd: A0,
            rs: T1,
            imm: i32::from(b'0'),
        },
        Op::Li {
            rd: A7,
            imm: SBI_PUTCHAR,
        },
        Op::Ecall,
    ]);
    putc_str(&mut ops, "\n");
    ops.extend([
        // reset → bounded readback poll (an absent device never answers 0).
        sw(X0, T6, VIO_REG_STATUS),
        Op::Li { rd: T4, imm: 4 },
        Op::Label("blk_rst".into()),
        lw(T2, T6, VIO_REG_STATUS),
        Op::Beq {
            rs1: T2,
            rs2: X0,
            to: "blk_ack".into(),
        },
        Op::Addi {
            rd: T4,
            rs: T4,
            imm: -1,
        },
        Op::Bne {
            rs1: T4,
            rs2: X0,
            to: "blk_rst".into(),
        },
        Op::Jal {
            rd: X0,
            to: "blk_fail".into(),
        },
        Op::Label("blk_ack".into()),
        Op::Li {
            rd: T2,
            imm: i64::from(VIO_ST_ACK | VIO_ST_DRIVER),
        },
        sw(T2, T6, VIO_REG_STATUS),
        // Accept VERSION_1 and nothing else: an unimplemented accepted feature
        // changes the request format under a driver that cannot parse it.
        sw(X0, T6, VIO_REG_FEATURES_SEL),
        lw(T2, T6, VIO_REG_FEATURES),
        sw(X0, T6, VIO_REG_DRV_FEATURES_SEL),
        sw(X0, T6, VIO_REG_DRV_FEATURES),
        Op::Li { rd: T2, imm: 1 },
        sw(T2, T6, VIO_REG_FEATURES_SEL),
        lw(T3, T6, VIO_REG_FEATURES),
        Op::Andi {
            rd: T3,
            rs: T3,
            imm: VIO_F_VERSION_1 as i32,
        },
        Op::Li { rd: T2, imm: 1 },
        sw(T2, T6, VIO_REG_DRV_FEATURES_SEL),
        sw(T3, T6, VIO_REG_DRV_FEATURES),
        lw(T2, T6, VIO_REG_STATUS),
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: VIO_ST_FEATURES_OK,
        },
        sw(T2, T6, VIO_REG_STATUS),
        lw(T2, T6, VIO_REG_STATUS),
        Op::Andi {
            rd: T2,
            rs: T2,
            imm: VIO_ST_FEATURES_OK,
        },
        Op::Beq {
            rs1: T2,
            rs2: X0,
            to: "blk_fail".into(),
        },
        // requestq = queue 0, rings in __vio+BLK_*.
        sw(X0, T6, VIO_REG_QUEUE_SEL),
        lw(T2, T6, VIO_REG_QUEUE_NUM_MAX),
        Op::Beq {
            rs1: T2,
            rs2: X0,
            to: "blk_fail".into(),
        },
        Op::Li {
            rd: T3,
            imm: VIO_QUEUE_NUM,
        },
        sw(T3, T6, VIO_REG_QUEUE_NUM),
        Op::Addi {
            rd: T3,
            rs: T5,
            imm: BLK_DESC_OFF,
        },
        sw(T3, T6, VIO_REG_QUEUE_DESC),
        sw(X0, T6, VIO_REG_QUEUE_DESC + 4),
        Op::Addi {
            rd: T3,
            rs: T5,
            imm: BLK_AVAIL_OFF,
        },
        sw(T3, T6, VIO_REG_QUEUE_AVAIL),
        sw(X0, T6, VIO_REG_QUEUE_AVAIL + 4),
        Op::Addi {
            rd: T3,
            rs: T5,
            imm: BLK_USED_OFF,
        },
        sw(T3, T6, VIO_REG_QUEUE_USED),
        sw(X0, T6, VIO_REG_QUEUE_USED + 4),
        Op::Li { rd: T3, imm: 1 },
        sw(T3, T6, VIO_REG_QUEUE_READY),
        // DRIVER_OK last: the device may service requests from here on.
        lw(T2, T6, VIO_REG_STATUS),
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: VIO_ST_DRIVER_OK,
        },
        sw(T2, T6, VIO_REG_STATUS),
        // Nothing has been read yet.
        sw(X0, T5, BLK_LAST_USED),
        sw(X0, T5, BLK_CUR_SECTOR),
    ]);
    putc_str(&mut ops, "VIRTIO-BLK-OK\n");
    ops.push(ret());
    ops.push(Op::Label("blk_fail".into()));
    putc_str(&mut ops, "VIRTIO-BLK-FAIL\n");
    ops.push(ret());
    Node {
        purpose: Purpose::VirtioBlk,
        ops,
    }
}

/// `BlkRead` — read sector `a0` into `__vio+BLK_DATA_OFF`. Returns `a0`=1 on a
/// device-reported OK, `a0`=0 otherwise.
///
/// The chain is the one virtio-blk mandates (spec 5.2.6):
///
/// | desc | contents | flags |
/// |---|---|---|
/// | 0 | `{type=VIRTIO_BLK_T_IN, reserved=0, sector}` (16B) | `NEXT` |
/// | 1 | 512-byte landing zone | `WRITE \| NEXT` |
/// | 2 | one status byte | `WRITE` |
///
/// The status byte is what decides success — **not** the fact that the used ring
/// advanced. A device can complete a request and report `IOERR`, and a reader that
/// only checks the ring would then parse the previous sector's bytes as if they
/// were the ones it asked for. The poll is bounded by the same budget as the ctrlq
/// (`QueueNotify` is serviced asynchronously by QEMU).
pub fn blk_read_node(o: Object) -> Node {
    let mut ops = vec![
        Op::Comment(format!(
            "{} — one VIRTIO_BLK_T_IN request: 3-desc chain, bounded used poll, status checked",
            o.why
        )),
        Op::Glob("BlkRead".into()),
        Op::Label("BlkRead".into()),
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
        // The blk block is past the 12-bit reach of `__vio`; form its base once.
        Op::Li {
            rd: T1,
            imm: BLK_BASE,
        },
        Op::Add {
            rd: T5,
            rs1: T5,
            rs2: T1,
        },
        lw(T6, T5, BLK_DEV),
        Op::Beq {
            rs1: T6,
            rs2: X0,
            to: "blkr_no".into(),
        },
        // ---- request header: type = IN, reserved = 0, sector = a0 ----------
        Op::Addi {
            rd: T0,
            rs: T5,
            imm: BLK_REQ_OFF,
        },
        Op::Li {
            rd: T1,
            imm: VIO_BLK_T_IN,
        },
        sw(T1, T0, 0),
        sw(X0, T0, 4),
        sw(A0, T0, 8),
        // The sector is a u64 on the wire; this driver reads the low 32 bits of
        // an LBA, which is 2 TiB of addressable medium — and it writes the high
        // word explicitly rather than leaving stale bytes there.
        sw(X0, T0, 12),
        // Remember what the buffer will hold (+1, so 0 still means "empty").
        Op::Addi {
            rd: T1,
            rs: A0,
            imm: 1,
        },
        sw(T1, T5, BLK_CUR_SECTOR),
        // Clear the status byte so a device that writes nothing cannot look OK.
        Op::Li { rd: T1, imm: 0xff },
        Op::Sb {
            rs2: T1,
            rs1: T5,
            off: BLK_STATUS_OFF,
        },
        // ---- desc0: header, read-only, chained -----------------------------
        Op::Addi {
            rd: T2,
            rs: T5,
            imm: BLK_DESC_OFF,
        },
        Op::Addi {
            rd: T3,
            rs: T5,
            imm: BLK_REQ_OFF,
        },
        sw(T3, T2, 0),
        sw(X0, T2, 4),
        Op::Li { rd: T1, imm: 16 },
        sw(T1, T2, 8),
        // flags(u16) | next(u16) packed in one word: NEXT → desc 1.
        Op::Li {
            rd: T1,
            imm: i64::from(VIO_DESC_NEXT) | (1 << 16),
        },
        sw(T1, T2, 12),
        // ---- desc1: 512-byte data, device-writable, chained ----------------
        Op::Addi {
            rd: T3,
            rs: T5,
            imm: BLK_DATA_OFF,
        },
        sw(T3, T2, 16),
        sw(X0, T2, 20),
        Op::Li {
            rd: T1,
            imm: VIO_BLK_SECTOR,
        },
        sw(T1, T2, 24),
        Op::Li {
            rd: T1,
            imm: i64::from(VIO_DESC_WRITE | VIO_DESC_NEXT) | (2 << 16),
        },
        sw(T1, T2, 28),
        // ---- desc2: status byte, device-writable, end of chain -------------
        Op::Addi {
            rd: T3,
            rs: T5,
            imm: BLK_STATUS_OFF,
        },
        sw(T3, T2, 32),
        sw(X0, T2, 36),
        Op::Li { rd: T1, imm: 1 },
        sw(T1, T2, 40),
        Op::Li {
            rd: T1,
            imm: i64::from(VIO_DESC_WRITE),
        },
        sw(T1, T2, 44),
        // ---- publish: avail.ring[idx % QUEUE_NUM] = 0, then avail.idx ------
        Op::Addi {
            rd: T2,
            rs: T5,
            imm: BLK_AVAIL_OFF,
        },
        lw(T1, T2, 0),
        Op::Srli {
            rd: T1,
            rs: T1,
            shamt: 16,
        },
        // ring entries are u16; slot 0 of the word pair is enough for a depth-1
        // submission pattern (one request in flight, which is what a BIOS needs).
        sw(X0, T2, 4),
        Op::Addi {
            rd: T3,
            rs: T1,
            imm: 1,
        },
        Op::Slli {
            rd: T3,
            rs: T3,
            shamt: 16,
        },
        Op::Fence,
        sw(T3, T2, 0),
        Op::Fence,
        sw(X0, T6, VIO_REG_QUEUE_NOTIFY),
        // ---- bounded used.idx poll ----------------------------------------
        //
        // Against the **shadow**, not against zero. The second request in a run
        // already sees a nonzero `used.idx` from the first, so a `!= 0` test
        // returns before the device has written anything — the reader then parses
        // the previous sector's bytes as the ones it asked for. That is exactly the
        // bug QEMU showed (`BLK-ERR` on the LBA 1 read of a real GPT disk), and it
        // is the reason the status byte is cleared to 0xff before submitting.
        lw(A1, T5, BLK_LAST_USED),
        Op::Li {
            rd: T4,
            imm: VIO_POLL_MAX,
        },
        Op::Label("blkr_poll".into()),
        lw(T2, T5, BLK_USED_OFF),
        Op::Srli {
            rd: T2,
            rs: T2,
            shamt: 16,
        },
        Op::Bne {
            rs1: T2,
            rs2: A1,
            to: "blkr_done".into(),
        },
        Op::Addi {
            rd: T4,
            rs: T4,
            imm: -1,
        },
        Op::Bne {
            rs1: T4,
            rs2: X0,
            to: "blkr_poll".into(),
        },
    ];
    putc_str(&mut ops, "BLK-TIMEOUT\n");
    ops.extend([Op::Li { rd: A0, imm: 0 }, ret()]);
    ops.extend([
        Op::Label("blkr_done".into()),
        // Ack the device's used-buffer interrupt: the line is level-triggered.
        lw(T3, T6, VIO_REG_ISR_STATUS),
        sw(T3, T6, VIO_REG_ISR_ACK),
        sw(T2, T5, BLK_LAST_USED),
        // The status byte, not the ring, decides.
        Op::Lbu {
            rd: T1,
            rs: T5,
            off: BLK_STATUS_OFF,
        },
        Op::Li {
            rd: T2,
            imm: VIO_BLK_S_OK,
        },
        Op::Beq {
            rs1: T1,
            rs2: T2,
            to: "blkr_ok".into(),
        },
    ]);
    putc_str(&mut ops, "BLK-ERR\n");
    ops.extend([
        Op::Li { rd: A0, imm: 0 },
        ret(),
        Op::Label("blkr_ok".into()),
        Op::Li { rd: A0, imm: 1 },
        ret(),
        Op::Label("blkr_no".into()),
    ]);
    putc_str(&mut ops, "BLK-NODEV\n");
    ops.extend([Op::Li { rd: A0, imm: 0 }, ret()]);
    Node {
        purpose: Purpose::VirtioBlk,
        ops,
    }
}

/// `BlkSig` — read LBA 0 (and LBA 1 when it looks like a GPT) and say what the
/// medium *is*, from its own bytes.
///
/// This is the payload's first act of reading a disk on its own: `BLK-SIG gpt`
/// when LBA 1 carries `"EFI PART"`, `BLK-SIG mbr` on a `0x55AA` boot signature,
/// `BLK-SIG fat` on a FAT BPB, and `BLK-SIG raw` when the sector claims nothing.
/// It deliberately reports what it found rather than guessing a filesystem: the
/// full table/superblock parse lives in `g6b-vfs` on the host side, and a guest
/// that pretended otherwise would be the dishonest kind of progress.
pub fn blk_sig_node(o: Object, xlen: u32) -> Node {
    let mut ops = vec![
        Op::Comment(format!("{} — identify the medium from LBA 0/1", o.why)),
        Op::Glob("BlkSig".into()),
        Op::Label("BlkSig".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -16,
        },
        st_x(xlen, RA, SP, 0),
        // LBA 0.
        Op::Li { rd: A0, imm: 0 },
        Op::Jal {
            rd: RA,
            to: "BlkRead".into(),
        },
        Op::Beq {
            rs1: A0,
            rs2: X0,
            to: "blks_out".into(),
        },
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
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
        // A `0x55AA` at 510 is the boot signature both MBR and FAT carry.
        Op::Lbu {
            rd: T1,
            rs: T5,
            off: BLK_DATA_OFF + 510,
        },
        Op::Lbu {
            rd: T2,
            rs: T5,
            off: BLK_DATA_OFF + 511,
        },
        Op::Li { rd: T3, imm: 0x55 },
        Op::Bne {
            rs1: T1,
            rs2: T3,
            to: "blks_maybe_ext4".into(),
        },
        Op::Li { rd: T3, imm: 0xaa },
        Op::Bne {
            rs1: T2,
            rs2: T3,
            to: "blks_maybe_ext4".into(),
        },
        // The same boot signature is on a FAT32 BPB. Look for a plausible FAT32
        // layout before reading LBA 1, so a FAT volume is reported from LBA 0.
        // bps = u16 at 0x0B; must be 512.
        Op::Lbu {
            rd: T0,
            rs: T5,
            off: BLK_DATA_OFF + 0x0B,
        },
        Op::Lbu {
            rd: T1,
            rs: T5,
            off: BLK_DATA_OFF + 0x0C,
        },
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
        Op::Li { rd: T1, imm: 512 },
        Op::Bne {
            rs1: T0,
            rs2: T1,
            to: "blks_not_fat".into(),
        },
        // spc = u8 at 0x0D; must be non-zero.
        Op::Lbu {
            rd: T0,
            rs: T5,
            off: BLK_DATA_OFF + 0x0D,
        },
        Op::Beq {
            rs1: T0,
            rs2: X0,
            to: "blks_not_fat".into(),
        },
        // root_ent_cnt = u16 at 0x11; must be 0 for FAT32.
        Op::Lbu {
            rd: T0,
            rs: T5,
            off: BLK_DATA_OFF + 0x11,
        },
        Op::Lbu {
            rd: T1,
            rs: T5,
            off: BLK_DATA_OFF + 0x12,
        },
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
        Op::Bne {
            rs1: T0,
            rs2: X0,
            to: "blks_not_fat".into(),
        },
        // fatsz16 = u16 at 0x16; must be 0 for FAT32.
        Op::Lbu {
            rd: T0,
            rs: T5,
            off: BLK_DATA_OFF + 0x16,
        },
        Op::Lbu {
            rd: T1,
            rs: T5,
            off: BLK_DATA_OFF + 0x17,
        },
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
        Op::Bne {
            rs1: T0,
            rs2: X0,
            to: "blks_not_fat".into(),
        },
        // totsec32 = u32 at 0x20; must be non-zero.
        Op::Lbu {
            rd: T0,
            rs: T5,
            off: BLK_DATA_OFF + 0x20,
        },
        Op::Lbu {
            rd: T1,
            rs: T5,
            off: BLK_DATA_OFF + 0x21,
        },
        Op::Lbu {
            rd: T2,
            rs: T5,
            off: BLK_DATA_OFF + 0x22,
        },
        Op::Lbu {
            rd: T3,
            rs: T5,
            off: BLK_DATA_OFF + 0x23,
        },
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
            rd: T0,
            rs1: T0,
            rs2: T3,
        },
        Op::Beq {
            rs1: T0,
            rs2: X0,
            to: "blks_not_fat".into(),
        },
        // fatsz32 = u32 at 0x24; must be non-zero.
        Op::Lbu {
            rd: T0,
            rs: T5,
            off: BLK_DATA_OFF + 0x24,
        },
        Op::Lbu {
            rd: T1,
            rs: T5,
            off: BLK_DATA_OFF + 0x25,
        },
        Op::Lbu {
            rd: T2,
            rs: T5,
            off: BLK_DATA_OFF + 0x26,
        },
        Op::Lbu {
            rd: T3,
            rs: T5,
            off: BLK_DATA_OFF + 0x27,
        },
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
            rd: T0,
            rs1: T0,
            rs2: T3,
        },
        Op::Beq {
            rs1: T0,
            rs2: X0,
            to: "blks_not_fat".into(),
        },
        // This looks like a FAT32 volume; report it and keep LBA 0 in the cache.
        Op::Jal {
            rd: X0,
            to: "blks_fat".into(),
        },
        Op::Label("blks_not_fat".into()),
        // A protective MBR points at a GPT: check LBA 1 for "EFI PART" rather
        // than trusting the 0xEE type byte, which is only a claim.
        Op::Li { rd: A0, imm: 1 },
        Op::Jal {
            rd: RA,
            to: "BlkRead".into(),
        },
        Op::Beq {
            rs1: A0,
            rs2: X0,
            to: "blks_mbr".into(),
        },
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
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
        Op::Lbu {
            rd: T1,
            rs: T5,
            off: BLK_DATA_OFF,
        },
        Op::Li {
            rd: T3,
            imm: i64::from(b'E'),
        },
        Op::Bne {
            rs1: T1,
            rs2: T3,
            to: "blks_mbr".into(),
        },
        Op::Lbu {
            rd: T1,
            rs: T5,
            off: BLK_DATA_OFF + 1,
        },
        Op::Li {
            rd: T3,
            imm: i64::from(b'F'),
        },
        Op::Bne {
            rs1: T1,
            rs2: T3,
            to: "blks_mbr".into(),
        },
        Op::Lbu {
            rd: T1,
            rs: T5,
            off: BLK_DATA_OFF + 2,
        },
        Op::Li {
            rd: T3,
            imm: i64::from(b'I'),
        },
        Op::Bne {
            rs1: T1,
            rs2: T3,
            to: "blks_mbr".into(),
        },
        Op::Lbu {
            rd: T1,
            rs: T5,
            off: BLK_DATA_OFF + 4,
        },
        Op::Li {
            rd: T3,
            imm: i64::from(b'P'),
        },
        Op::Bne {
            rs1: T1,
            rs2: T3,
            to: "blks_mbr".into(),
        },
    ];
    // GPT: LBA 1 carried "EFI PART". Latch the signature kind for the file
    // readers (kind 2) before reporting.
    ops.extend([Op::Li { rd: T0, imm: 2 }, sw(T0, T5, BLK_SIG)]);
    putc_str(&mut ops, "BLK-SIG gpt\n");
    ops.push(jump("blks_out"));
    ops.extend([
        Op::Label("blks_mbr".into()),
        Op::Li { rd: T0, imm: 3 },
        sw(T0, T5, BLK_SIG),
    ]);
    putc_str(&mut ops, "BLK-SIG mbr\n");
    ops.push(jump("blks_out"));
    ops.extend([
        Op::Label("blks_fat".into()),
        Op::Li { rd: T0, imm: 1 },
        sw(T0, T5, BLK_SIG),
    ]);
    putc_str(&mut ops, "BLK-SIG fat\n");
    ops.push(jump("blks_out"));
    // No boot signature at 510: either a filesystem superfloppy with no MBR
    // (ext4 keeps its superblock at byte 1024 = LBA 2) or genuinely raw media.
    // Probe LBA 2 for the ext4 magic before settling for "raw".
    ops.extend([
        Op::Label("blks_maybe_ext4".into()),
        Op::Li { rd: A0, imm: 2 },
        Op::Jal {
            rd: RA,
            to: "BlkRead".into(),
        },
        Op::Beq {
            rs1: A0,
            rs2: X0,
            to: "blks_raw".into(),
        },
        // BlkRead re-forms T5 from scratch, so rebuild the base register here.
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
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
        Op::Lbu {
            rd: T0,
            rs: T5,
            off: BLK_DATA_OFF + 56,
        },
        Op::Lbu {
            rd: T1,
            rs: T5,
            off: BLK_DATA_OFF + 57,
        },
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
            imm: 0xEF53,
        },
        Op::Bne {
            rs1: T0,
            rs2: T1,
            to: "blks_raw".into(),
        },
        Op::Label("blks_ext4".into()),
        Op::Li { rd: T0, imm: 4 },
        sw(T0, T5, BLK_SIG),
    ]);
    putc_str(&mut ops, "BLK-SIG ext4\n");
    ops.push(jump("blks_out"));
    ops.extend([
        Op::Label("blks_raw".into()),
        Op::Li { rd: T0, imm: 5 },
        sw(T0, T5, BLK_SIG),
    ]);
    putc_str(&mut ops, "BLK-SIG raw\n");
    ops.extend([
        Op::Label("blks_out".into()),
        ld_x(xlen, RA, SP, 0),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: 16,
        },
        ret(),
    ]);
    Node {
        purpose: Purpose::VirtioBlk,
        ops,
    }
}

/// `TabInit` — virtio-tablet (second DeviceID 18) eventq. `InpInit` already
/// stored the mmio base at `VIO_TAB_OFF` (0 → `VIRTIO-TABLET-NONE`). Same
/// handshake as the keyboard, rings in `__vio+TAB_*`. VGA `DomNav` does not
/// consume tablet events; `TabDrain` only re-posts. Leaf.
pub fn tab_init_node(o: Object) -> Node {
    let mut ops = vec![
        Op::Comment(format!(
            "{} — tablet eventq handshake + 8 posted event buffers",
            o.why
        )),
        Op::Glob("TabInit".into()),
        Op::Label("TabInit".into()),
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
        lw(T0, T5, VIO_TAB_OFF),
        Op::Bne {
            rs1: T0,
            rs2: X0,
            to: "ipt_dev".into(),
        },
    ];
    putc_str(&mut ops, "VIRTIO-TABLET-NONE\n");
    ops.push(ret());
    ops.extend([
        Op::Label("ipt_dev".into()),
        Op::Addi {
            rd: T6,
            rs: T0,
            imm: 0,
        },
        sw(X0, T6, VIO_REG_STATUS),
        Op::Li { rd: T4, imm: 4 },
        Op::Label("ipt_rst".into()),
        lw(T2, T6, VIO_REG_STATUS),
        Op::Beq {
            rs1: T2,
            rs2: X0,
            to: "ipt_ack".into(),
        },
        Op::Addi {
            rd: T4,
            rs: T4,
            imm: -1,
        },
        Op::Bne {
            rs1: T4,
            rs2: X0,
            to: "ipt_rst".into(),
        },
        jump("ipt_fail"),
        Op::Label("ipt_ack".into()),
        Op::Li {
            rd: T2,
            imm: i64::from(VIO_ST_ACK | VIO_ST_DRIVER),
        },
        sw(T2, T6, VIO_REG_STATUS),
        sw(X0, T6, VIO_REG_FEATURES_SEL),
        lw(T2, T6, VIO_REG_FEATURES),
        sw(X0, T6, VIO_REG_DRV_FEATURES_SEL),
        sw(X0, T6, VIO_REG_DRV_FEATURES),
        Op::Li { rd: T2, imm: 1 },
        sw(T2, T6, VIO_REG_FEATURES_SEL),
        lw(T3, T6, VIO_REG_FEATURES),
        Op::Andi {
            rd: T3,
            rs: T3,
            imm: VIO_F_VERSION_1 as i32,
        },
        Op::Li { rd: T2, imm: 1 },
        sw(T2, T6, VIO_REG_DRV_FEATURES_SEL),
        sw(T3, T6, VIO_REG_DRV_FEATURES),
        lw(T2, T6, VIO_REG_STATUS),
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: VIO_ST_FEATURES_OK,
        },
        sw(T2, T6, VIO_REG_STATUS),
        lw(T2, T6, VIO_REG_STATUS),
        Op::Andi {
            rd: T2,
            rs: T2,
            imm: VIO_ST_FEATURES_OK,
        },
        Op::Beq {
            rs1: T2,
            rs2: X0,
            to: "ipt_fail".into(),
        },
        sw(X0, T6, VIO_REG_QUEUE_SEL),
        lw(T2, T6, VIO_REG_QUEUE_NUM_MAX),
        Op::Beq {
            rs1: T2,
            rs2: X0,
            to: "ipt_fail".into(),
        },
        Op::Li {
            rd: T3,
            imm: VIO_QUEUE_NUM,
        },
        sw(T3, T6, VIO_REG_QUEUE_NUM),
        Op::Addi {
            rd: T3,
            rs: T5,
            imm: TAB_DESC_OFF,
        },
        sw(T3, T6, VIO_REG_QUEUE_DESC),
        sw(X0, T6, VIO_REG_QUEUE_DESC + 4),
        Op::Addi {
            rd: T3,
            rs: T5,
            imm: TAB_AVAIL_OFF,
        },
        sw(T3, T6, VIO_REG_QUEUE_AVAIL),
        sw(X0, T6, VIO_REG_QUEUE_AVAIL + 4),
        Op::Addi {
            rd: T3,
            rs: T5,
            imm: TAB_USED_OFF,
        },
        sw(T3, T6, VIO_REG_QUEUE_USED),
        sw(X0, T6, VIO_REG_QUEUE_USED + 4),
        Op::Li { rd: T3, imm: 1 },
        sw(T3, T6, VIO_REG_QUEUE_READY),
        Op::Addi {
            rd: T2,
            rs: T5,
            imm: TAB_DESC_OFF,
        },
        Op::Addi {
            rd: T3,
            rs: T5,
            imm: TAB_EVBUF_OFF,
        },
        Op::Li { rd: T4, imm: 8 },
        Op::Label("ipt_buf".into()),
        sw(T3, T2, 0),
        sw(X0, T2, 4),
        Op::Li { rd: T1, imm: 8 },
        sw(T1, T2, 8),
        Op::Li {
            rd: T1,
            imm: i64::from(VIO_DESC_WRITE),
        },
        sw(T1, T2, 12),
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: 16,
        },
        Op::Addi {
            rd: T3,
            rs: T3,
            imm: 8,
        },
        Op::Addi {
            rd: T4,
            rs: T4,
            imm: -1,
        },
        Op::Bne {
            rs1: T4,
            rs2: X0,
            to: "ipt_buf".into(),
        },
        sw(X0, T5, TAB_AVAIL_OFF),
        Op::Li {
            rd: T1,
            imm: 0x0001_0000,
        },
        sw(T1, T5, TAB_AVAIL_OFF + 4),
        Op::Li {
            rd: T1,
            imm: 0x0003_0002,
        },
        sw(T1, T5, TAB_AVAIL_OFF + 8),
        Op::Li {
            rd: T1,
            imm: 0x0005_0004,
        },
        sw(T1, T5, TAB_AVAIL_OFF + 12),
        Op::Li {
            rd: T1,
            imm: 0x0007_0006,
        },
        sw(T1, T5, TAB_AVAIL_OFF + 16),
        Op::Fence,
        Op::Li {
            rd: T1,
            imm: 0x8_0000,
        },
        sw(T1, T5, TAB_AVAIL_OFF),
        Op::Fence,
        sw(X0, T6, VIO_REG_QUEUE_NOTIFY),
        lw(T2, T6, VIO_REG_STATUS),
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: VIO_ST_DRIVER_OK,
        },
        sw(T2, T6, VIO_REG_STATUS),
    ]);
    putc_str(&mut ops, "VIRTIO-TABLET-OK\n");
    ops.push(Op::Label("ipt_ret".into()));
    ops.push(ret());
    ops.push(Op::Label("ipt_fail".into()));
    putc_str(&mut ops, "VIRTIO-TABLET-FAIL\n");
    ops.push(ret());
    Node {
        purpose: Purpose::Virtio,
        ops,
    }
}

/// `TabDrain` — consume the tablet eventq used ring and re-post every
/// buffer. Does **not** push `INP_KQ` (VGA `DomNav` is keyboard-only).
/// Marker `TAB` per consumed event so the exec-model poke is observable.
pub fn tab_drain_node(o: Object) -> Node {
    let mut ops = vec![
        Op::Comment(format!(
            "{} — tablet eventq used-ring drain + re-post",
            o.why
        )),
        Op::Glob("TabDrain".into()),
        Op::Label("TabDrain".into()),
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
        lw(T6, T5, VIO_TAB_OFF),
        Op::Beq {
            rs1: T6,
            rs2: X0,
            to: "tpd_ret".into(),
        },
        lw(T4, T5, TAB_LAST_USED),
        Op::Label("tpd_next".into()),
        lw(T1, T5, TAB_USED_OFF),
        Op::Srli {
            rd: T1,
            rs: T1,
            shamt: 16,
        },
        Op::Beq {
            rs1: T1,
            rs2: T4,
            to: "tpd_done".into(),
        },
        Op::Andi {
            rd: T2,
            rs: T4,
            imm: 7,
        },
        Op::Slli {
            rd: T2,
            rs: T2,
            shamt: 3,
        },
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: TAB_USED_OFF + 4,
        },
        Op::Add {
            rd: T2,
            rs1: T2,
            rs2: T5,
        },
        lw(T3, T2, 0),
    ];
    putc_str(&mut ops, "TAB\n");
    ops.extend([
        // T3 = consumed buffer idx → decode the `virtio_input_event` at
        // `TAB_EVBUF + T3*8` (`{type:u16, code:u16, value:u32}`). Track the
        // last `ABS_X`/`ABS_Y` into `PTR_X`/`PTR_Y` and latch `PTR_CLICK` on a
        // `BTN_LEFT` press so `DomtPtr` can turn the sequence into an
        // `EV_CLICK` dispatch. T0/T1/T2 are scratch here — the re-post below
        // recomputes T1/T2 and keeps T3.
        Op::Slli {
            rd: T0,
            rs: T3,
            shamt: 3,
        },
        Op::Addi {
            rd: T0,
            rs: T0,
            imm: TAB_EVBUF_OFF,
        },
        Op::Add {
            rd: T0,
            rs1: T0,
            rs2: T5,
        },
        Op::Lhu {
            rd: T1,
            rs: T0,
            off: 0,
        },
        Op::Lhu {
            rd: T2,
            rs: T0,
            off: 2,
        },
        lw(T0, T0, 4),
        // T1 = type, T2 = code, T0 = value.
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: -(VIO_INP_EV_ABS as i32),
        },
        Op::Bne {
            rs1: T1,
            rs2: X0,
            to: "tpd_ev_key".into(),
        },
        Op::Bne {
            rs1: T2,
            rs2: X0,
            to: "tpd_abs_y".into(),
        },
        sw(T0, T5, PTR_X),
        jump("tpd_ev_done"),
        Op::Label("tpd_abs_y".into()),
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: -(VIO_ABS_Y as i32),
        },
        Op::Bne {
            rs1: T2,
            rs2: X0,
            to: "tpd_ev_done".into(),
        },
        sw(T0, T5, PTR_Y),
        jump("tpd_ev_done"),
        Op::Label("tpd_ev_key".into()),
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: 2,
        },
        Op::Bne {
            rs1: T1,
            rs2: X0,
            to: "tpd_ev_done".into(),
        },
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: -(VIO_BTN_LEFT as i32),
        },
        Op::Bne {
            rs1: T2,
            rs2: X0,
            to: "tpd_ev_done".into(),
        },
        Op::Beq {
            rs1: T0,
            rs2: X0,
            to: "tpd_ev_done".into(),
        },
        Op::Li { rd: T0, imm: 1 },
        sw(T0, T5, PTR_CLICK),
        Op::Label("tpd_ev_done".into()),
        lw(T2, T5, TAB_AVAIL_OFF),
        Op::Srli {
            rd: T2,
            rs: T2,
            shamt: 16,
        },
        Op::Andi {
            rd: T1,
            rs: T2,
            imm: 7,
        },
        Op::Slli {
            rd: T1,
            rs: T1,
            shamt: 1,
        },
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: TAB_AVAIL_OFF + 4,
        },
        Op::Add {
            rd: T1,
            rs1: T1,
            rs2: T5,
        },
        Op::Sb {
            rs2: T3,
            rs1: T1,
            off: 0,
        },
        Op::Srli {
            rd: T3,
            rs: T3,
            shamt: 8,
        },
        Op::Sb {
            rs2: T3,
            rs1: T1,
            off: 1,
        },
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: 1,
        },
        Op::Slli {
            rd: T2,
            rs: T2,
            shamt: 16,
        },
        sw(T2, T5, TAB_AVAIL_OFF),
        Op::Addi {
            rd: T4,
            rs: T4,
            imm: 1,
        },
        sw(T4, T5, TAB_LAST_USED),
        jump("tpd_next"),
        Op::Label("tpd_done".into()),
        Op::Fence,
        sw(X0, T6, VIO_REG_QUEUE_NOTIFY),
        Op::Label("tpd_ret".into()),
    ]);
    ops.push(ret());
    let _ = o;
    Node {
        purpose: Purpose::Virtio,
        ops,
    }
}

/// `InpDrain` — consume the eventq used ring: each used elem's desc id picks
/// one `virtio_input_event` buffer; EV_KEY press/release events are pushed
/// into the bounded `INP_KQ` key queue as `(code << 8) | value` and marked
/// `INP`. Every consumed buffer is re-posted to the avail ring + notified,
/// so the device never runs dry. Leaf; safe from trap context (t-regs +
/// saved a-regs only) — callers must have interrupts off or the queue
/// shadow is single-writer.
pub fn inp_drain_node(o: Object) -> Node {
    let mut ops = vec![
        Op::Comment(format!(
            "{} — eventq used-ring drain → INP_KQ + re-post",
            o.why
        )),
        Op::Glob("InpDrain".into()),
        Op::Label("InpDrain".into()),
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
        lw(T6, T5, VIO_INP_OFF),
        Op::Beq {
            rs1: T6,
            rs2: X0,
            to: "ipd_ret".into(),
        },
        lw(T4, T5, INP_LAST_USED),
        Op::Label("ipd_next".into()),
        // used idx is the hi16 of the used ring header.
        lw(T1, T5, INP_USED_OFF),
        Op::Srli {
            rd: T1,
            rs: T1,
            shamt: 16,
        },
        Op::Beq {
            rs1: T1,
            rs2: T4,
            to: "ipd_done".into(),
        },
        // elem i = INP_USED + 4 + (last % 8) * 8 → id in t3.
        Op::Andi {
            rd: T2,
            rs: T4,
            imm: 7,
        },
        Op::Slli {
            rd: T2,
            rs: T2,
            shamt: 3,
        },
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: INP_USED_OFF + 4,
        },
        Op::Add {
            rd: T2,
            rs1: T2,
            rs2: T5,
        },
        lw(T3, T2, 0),
        // event = __vio + INP_EVBUF + id*8 → {type:u16, code:u16, value:u32}.
        Op::Andi {
            rd: T2,
            rs: T3,
            imm: 7,
        },
        Op::Slli {
            rd: T2,
            rs: T2,
            shamt: 3,
        },
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: INP_EVBUF_OFF,
        },
        Op::Add {
            rd: T2,
            rs1: T2,
            rs2: T5,
        },
        lw(A2, T2, 4),
        // EV_KEY only; type is the u16 at offset 0 — lbu suffices (EV_*
        // constants are all < 256) and is xlen-agnostic.
        Op::Lbu {
            rd: A1,
            rs: T2,
            off: 0,
        },
        Op::Li {
            rd: T1,
            imm: i64::from(VIO_INP_EV_KEY),
        },
        Op::Bne {
            rs1: A1,
            rs2: T1,
            to: "ipd_repost".into(),
        },
        // push (code<<8 | value&0xff) — code is the hi16 of word0.
        lw(A1, T2, 0),
        Op::Srli {
            rd: A1,
            rs: A1,
            shamt: 16,
        },
        Op::Slli {
            rd: A1,
            rs: A1,
            shamt: 8,
        },
        Op::Andi {
            rd: A2,
            rs: A2,
            imm: 0xff,
        },
        Op::Xor {
            rd: A1,
            rs1: A1,
            rs2: A2,
        },
        lw(T1, T5, INP_KQ_HEAD),
        Op::Andi {
            rd: T2,
            rs: T1,
            imm: 15,
        },
        Op::Slli {
            rd: T2,
            rs: T2,
            shamt: 2,
        },
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: INP_KQ_OFF,
        },
        Op::Add {
            rd: T2,
            rs1: T2,
            rs2: T5,
        },
        sw(A1, T2, 0),
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: 1,
        },
        sw(T1, T5, INP_KQ_HEAD),
    ];
    putc_str(&mut ops, "INP\n");
    ops.extend([
        Op::Label("ipd_repost".into()),
        // re-post the consumed buffer id (t3) at avail idx; then last++.
        lw(T2, T5, INP_AVAIL_OFF),
        Op::Srli {
            rd: T2,
            rs: T2,
            shamt: 16,
        },
        Op::Andi {
            rd: T1,
            rs: T2,
            imm: 7,
        },
        Op::Slli {
            rd: T1,
            rs: T1,
            shamt: 1,
        },
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: INP_AVAIL_OFF + 4,
        },
        Op::Add {
            rd: T1,
            rs1: T1,
            rs2: T5,
        },
        Op::Sb {
            rs2: T3,
            rs1: T1,
            off: 0,
        },
        Op::Srli {
            rd: T3,
            rs: T3,
            shamt: 8,
        },
        Op::Sb {
            rs2: T3,
            rs1: T1,
            off: 1,
        },
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: 1,
        },
        Op::Slli {
            rd: T2,
            rs: T2,
            shamt: 16,
        },
        sw(T2, T5, INP_AVAIL_OFF),
        Op::Addi {
            rd: T4,
            rs: T4,
            imm: 1,
        },
        sw(T4, T5, INP_LAST_USED),
        Op::Jal {
            rd: X0,
            to: "ipd_next".into(),
        },
        Op::Label("ipd_done".into()),
        Op::Fence,
        sw(X0, T6, VIO_REG_QUEUE_NOTIFY),
        Op::Label("ipd_ret".into()),
    ]);
    ops.push(ret());
    let _ = o;
    Node {
        purpose: Purpose::Virtio,
        ops,
    }
}

/// `InpPoll` — UART `Keys` command body: drain the eventq, then pop the key
/// queue printing `KEY <8-hex>` per entry (`hexdig` lives in the trap node —
/// the label is module-wide). Bounded by the 16-entry queue.
pub fn inp_poll_node(o: Object, spec: &BoardSpec) -> Node {
    let xlen = spec.isa.xlen;
    let mut ops = vec![
        Op::Comment(format!("{} — jal InpDrain then pop INP_KQ", o.why)),
        Op::Glob("InpPoll".into()),
        Op::Label("InpPoll".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -16,
        },
        st_x(xlen, RA, SP, 0),
        Op::Jal {
            rd: RA,
            to: "InpDrain".into(),
        },
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
        Op::Label("ipp_next".into()),
        lw(T1, T5, INP_KQ_TAIL),
        lw(T2, T5, INP_KQ_HEAD),
        Op::Beq {
            rs1: T1,
            rs2: T2,
            to: "ipp_done".into(),
        },
        Op::Andi {
            rd: T2,
            rs: T1,
            imm: 15,
        },
        Op::Slli {
            rd: T2,
            rs: T2,
            shamt: 2,
        },
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: INP_KQ_OFF,
        },
        Op::Add {
            rd: T2,
            rs1: T2,
            rs2: T5,
        },
        lw(T0, T2, 0),
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: 1,
        },
        sw(T1, T5, INP_KQ_TAIL),
    ];
    putc_str(&mut ops, "KEY ");
    // print 8 hex digits of t0 via the shared hexdig table.
    ops.extend([
        Op::Li { rd: A2, imm: 8 },
        Op::Label("ipp_hex".into()),
        Op::Srli {
            rd: T2,
            rs: T0,
            shamt: 28,
        },
        Op::Andi {
            rd: T2,
            rs: T2,
            imm: 0xf,
        },
        Op::Slli {
            rd: T0,
            rs: T0,
            shamt: 4,
        },
        Op::La {
            rd: A6,
            addr: Addr::Label("hexdig".into()),
        },
        Op::Add {
            rd: A6,
            rs1: A6,
            rs2: T2,
        },
        Op::Lbu {
            rd: A0,
            rs: A6,
            off: 0,
        },
        Op::Li {
            rd: A7,
            imm: SBI_PUTCHAR,
        },
        Op::Ecall,
        Op::Addi {
            rd: A2,
            rs: A2,
            imm: -1,
        },
        Op::Bne {
            rs1: A2,
            rs2: X0,
            to: "ipp_hex".into(),
        },
    ]);
    putc_str(&mut ops, "\n");
    ops.extend([
        Op::Jal {
            rd: X0,
            to: "ipp_next".into(),
        },
        Op::Label("ipp_done".into()),
        ld_x(xlen, RA, SP, 0),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: 16,
        },
    ]);
    ops.push(ret());
    Node {
        purpose: Purpose::Virtio,
        ops,
    }
}

/// `DomKey` — DOM-input bridge: mirror the newest `INP_KQ` entry into the
/// `inp.last` DOM row (`"key <8hex>"`, 12 bytes in `INP_KEYTXT`) via
/// `WasmDomText` (find-or-create, bounded like every DOM op). No-op when the
/// queue is empty. Emitted only when both the virtio-input lane and the DOM
/// lane (`kernel.wasm.jit`) are live; `trap_inp` and the `Keys`/`K` commands
/// `jal` it, then repaint. t-regs are trap-clobberable (InpDrain convention).
pub fn dom_key_node(o: Object, spec: &BoardSpec) -> Node {
    let xlen = spec.isa.xlen;
    let ops = vec![
        Op::Comment(format!("{} — INP_KQ[head-1] → DOM row inp.last", o.why)),
        Op::Glob("DomKey".into()),
        Op::Label("DomKey".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -16,
        },
        st_x(xlen, RA, SP, 0),
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
        lw(T1, T5, INP_KQ_HEAD),
        Op::Beq {
            rs1: T1,
            rs2: X0,
            to: "dkey_done".into(),
        },
        // t0 = KQ[(head-1) & 15] — the newest queued key.
        Op::Addi {
            rd: T0,
            rs: T1,
            imm: -1,
        },
        Op::Andi {
            rd: T0,
            rs: T0,
            imm: 15,
        },
        Op::Slli {
            rd: T0,
            rs: T0,
            shamt: 2,
        },
        Op::Addi {
            rd: T0,
            rs: T0,
            imm: INP_KQ_OFF,
        },
        Op::Add {
            rd: T0,
            rs1: T0,
            rs2: T5,
        },
        lw(T0, T0, 0),
        // text "key " + 8 hex digits into INP_KEYTXT.
        Op::Li {
            rd: T3,
            imm: i64::from(u32::from_le_bytes(*b"key ")),
        },
        sw(T3, T5, INP_KEYTXT_OFF),
        Op::Addi {
            rd: T6,
            rs: T5,
            imm: INP_KEYTXT_OFF + 4,
        },
        Op::Li { rd: T4, imm: 8 },
        Op::Label("dkey_hex".into()),
        Op::Srli {
            rd: T3,
            rs: T0,
            shamt: 28,
        },
        Op::Andi {
            rd: T3,
            rs: T3,
            imm: 0xf,
        },
        Op::Slli {
            rd: T0,
            rs: T0,
            shamt: 4,
        },
        Op::La {
            rd: A6,
            addr: Addr::Label("hexdig".into()),
        },
        Op::Add {
            rd: A6,
            rs1: A6,
            rs2: T3,
        },
        Op::Lbu {
            rd: T3,
            rs: A6,
            off: 0,
        },
        Op::Sb {
            rs2: T3,
            rs1: T6,
            off: 0,
        },
        Op::Addi {
            rd: T6,
            rs: T6,
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
            to: "dkey_hex".into(),
        },
        // WasmDomText(a0=id_ptr, a1=id_len, a2=text_ptr, a3=text_len) —
        // find-or-create the `inp.last` row.
        Op::La {
            rd: A0,
            addr: Addr::Label("domkey_id".into()),
        },
        Op::Li { rd: A1, imm: 8 },
        Op::Addi {
            rd: A2,
            rs: T5,
            imm: INP_KEYTXT_OFF,
        },
        Op::Li { rd: A3, imm: 12 },
        Op::Jal {
            rd: RA,
            to: "WasmDomText".into(),
        },
        Op::Label("dkey_done".into()),
        ld_x(xlen, RA, SP, 0),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: 16,
        },
        ret(),
        // Inline rodata (never executed — sits after ret): the DOM row id.
        Op::Label("domkey_id".into()),
        Op::Word(u32::from_le_bytes(*b"inp.")),
        Op::Word(u32::from_le_bytes(*b"last")),
    ];
    Node {
        purpose: Purpose::Virtio,
        ops,
    }
}

/// `DomNav` — menu navigation over `INP_KQ`: walks entries from the
/// `NAV_SEEN` watermark to `INP_KQ_HEAD` (non-destructive — the physical
/// ring stays intact for the `Keys` dump), applies press events (value≥1):
/// UP/LEFT → sel-1, DOWN/RIGHT → sel+1 (wrap over `spec.menus()`), ESC →
/// sel=0+closed, ENTER → open latch + serial `NAV <name>`. The `nav.sel`
/// DOM row shows `"nav <name>"` / `"open <name>"` via `WasmDomText`
/// (find-or-create; t1/t2/t5 saved across the call — the DOM op clobbers
/// all t/a regs). Menu names come from `spec.menus()` as 8-byte rodata
/// slots — generated, not hard-coded.
pub fn dom_nav_node(o: Object, spec: &BoardSpec) -> Node {
    let xlen = spec.isa.xlen;
    let n = spec.menus().len() as i64;
    let mut ops = vec![
        Op::Comment(format!(
            "{} — INP_KQ nav: arrows→nav.sel, Enter→open (watermark scan)",
            o.why
        )),
        Op::Glob("DomNav".into()),
        Op::Label("DomNav".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -48,
        },
        st_x(xlen, RA, SP, 0),
        st_x(xlen, T1, SP, 8),
        st_x(xlen, T2, SP, 16),
        st_x(xlen, T5, SP, 24),
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
        lw(T1, T5, INP_KQ_HEAD),
        lw(T2, T5, NAV_SEEN_OFF),
        Op::Label("dnav_next".into()),
        Op::Beq {
            rs1: T2,
            rs2: T1,
            to: "dnav_done".into(),
        },
        // t3 = KQ[t2 & 15] = (code<<8)|value
        Op::Andi {
            rd: T3,
            rs: T2,
            imm: 15,
        },
        Op::Slli {
            rd: T3,
            rs: T3,
            shamt: 2,
        },
        Op::Addi {
            rd: T3,
            rs: T3,
            imm: INP_KQ_OFF,
        },
        Op::Add {
            rd: T3,
            rs1: T3,
            rs2: T5,
        },
        lw(T3, T3, 0),
        Op::Andi {
            rd: T4,
            rs: T3,
            imm: 0xff,
        },
        Op::Srli {
            rd: T0,
            rs: T3,
            shamt: 8,
        },
        // press/repeat only — releases (value 0) don't navigate.
        Op::Beq {
            rs1: T4,
            rs2: X0,
            to: "dnav_skip".into(),
        },
        Op::Li {
            rd: T6,
            imm: VIO_KEY_ENTER,
        },
        Op::Beq {
            rs1: T0,
            rs2: T6,
            to: "dnav_enter".into(),
        },
        Op::Li {
            rd: T6,
            imm: VIO_KEY_ESC,
        },
        Op::Beq {
            rs1: T0,
            rs2: T6,
            to: "dnav_esc".into(),
        },
        Op::Li {
            rd: T6,
            imm: VIO_KEY_UP,
        },
        Op::Beq {
            rs1: T0,
            rs2: T6,
            to: "dnav_prev".into(),
        },
        Op::Li {
            rd: T6,
            imm: VIO_KEY_LEFT,
        },
        Op::Beq {
            rs1: T0,
            rs2: T6,
            to: "dnav_prev".into(),
        },
        Op::Li {
            rd: T6,
            imm: VIO_KEY_DOWN,
        },
        Op::Beq {
            rs1: T0,
            rs2: T6,
            to: "dnav_fwd".into(),
        },
        Op::Li {
            rd: T6,
            imm: VIO_KEY_RIGHT,
        },
        Op::Beq {
            rs1: T0,
            rs2: T6,
            to: "dnav_fwd".into(),
        },
        jump("dnav_skip"),
        Op::Label("dnav_prev".into()),
        lw(T3, T5, NAV_SEL_OFF),
        Op::Bne {
            rs1: T3,
            rs2: X0,
            to: "dnav_prev_dec".into(),
        },
        Op::Li { rd: T3, imm: n },
        Op::Label("dnav_prev_dec".into()),
        Op::Addi {
            rd: T3,
            rs: T3,
            imm: -1,
        },
        jump("dnav_set"),
        Op::Label("dnav_fwd".into()),
        lw(T3, T5, NAV_SEL_OFF),
        Op::Addi {
            rd: T3,
            rs: T3,
            imm: 1,
        },
        Op::Li { rd: T6, imm: n },
        Op::Bne {
            rs1: T3,
            rs2: T6,
            to: "dnav_set".into(),
        },
        Op::Li { rd: T3, imm: 0 },
        Op::Label("dnav_set".into()),
        sw(T3, T5, NAV_SEL_OFF),
        // moving the selection closes any open menu
        sw(X0, T5, NAV_OPEN_OFF),
        jump("dnav_show"),
        Op::Label("dnav_esc".into()),
        sw(X0, T5, NAV_SEL_OFF),
        sw(X0, T5, NAV_OPEN_OFF),
        jump("dnav_show"),
        Op::Label("dnav_enter".into()),
        Op::Li { rd: T3, imm: 1 },
        sw(T3, T5, NAV_OPEN_OFF),
        jump("dnav_show"),
        Op::Label("dnav_skip".into()),
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: 1,
        },
        jump("dnav_next"),
        // ---- nav_show: "nav <name>" / "open <name>" → nav.sel DOM row;
        // on open also print "NAV <name>\n" over serial.
        Op::Label("dnav_show".into()),
        lw(T3, T5, NAV_OPEN_OFF),
        Op::Bne {
            rs1: T3,
            rs2: X0,
            to: "dnav_open_txt".into(),
        },
        Op::Li {
            rd: T3,
            imm: i64::from(u32::from_le_bytes(*b"nav ")),
        },
        sw(T3, T5, NAV_TEXT_OFF),
        Op::Li { rd: T6, imm: 4 },
        jump("dnav_name"),
        Op::Label("dnav_open_txt".into()),
        Op::Li {
            rd: T3,
            imm: i64::from(u32::from_le_bytes(*b"open")),
        },
        sw(T3, T5, NAV_TEXT_OFF),
        Op::Li {
            rd: T3,
            imm: i64::from(b' '),
        },
        Op::Sb {
            rs2: T3,
            rs1: T5,
            off: NAV_TEXT_OFF + 4,
        },
        Op::Li { rd: T6, imm: 5 },
        Op::Label("dnav_name".into()),
        // t3 = domnav_names + sel*8 (8-byte slots)
        lw(T3, T5, NAV_SEL_OFF),
        Op::Slli {
            rd: T3,
            rs: T3,
            shamt: 3,
        },
        Op::La {
            rd: T4,
            addr: Addr::Label("domnav_names".into()),
        },
        Op::Add {
            rd: T3,
            rs1: T3,
            rs2: T4,
        },
        // dst cursor t4 = NAV_TEXT + prefix len; copy ≤8, stop at NUL; t0 = i
        Op::Addi {
            rd: T4,
            rs: T5,
            imm: NAV_TEXT_OFF,
        },
        Op::Add {
            rd: T4,
            rs1: T4,
            rs2: T6,
        },
        Op::Li { rd: T0, imm: 0 },
        Op::Label("dnav_ncopy".into()),
        Op::Li { rd: A6, imm: 8 },
        Op::Beq {
            rs1: T0,
            rs2: A6,
            to: "dnav_ncopied".into(),
        },
        Op::Add {
            rd: A6,
            rs1: T3,
            rs2: T0,
        },
        Op::Lbu {
            rd: A6,
            rs: A6,
            off: 0,
        },
        Op::Beq {
            rs1: A6,
            rs2: X0,
            to: "dnav_ncopied".into(),
        },
        Op::Sb {
            rs2: A6,
            rs1: T4,
            off: 0,
        },
        Op::Addi {
            rd: T4,
            rs: T4,
            imm: 1,
        },
        Op::Addi {
            rd: T0,
            rs: T0,
            imm: 1,
        },
        jump("dnav_ncopy"),
        Op::Label("dnav_ncopied".into()),
        // text len = prefix(t6) + name i(t0) — compute before the open
        // latch read below reuses t6.
        Op::Add {
            rd: A3,
            rs1: T6,
            rs2: T0,
        },
        // open latch → serial "NAV <name>\n" (t3 = name src, t0 = copied len)
        lw(T6, T5, NAV_OPEN_OFF),
        Op::Beq {
            rs1: T6,
            rs2: X0,
            to: "dnav_dom".into(),
        },
    ];
    putc_str(&mut ops, "NAV ");
    ops.extend([
        Op::Li { rd: T4, imm: 0 },
        Op::Label("dnav_pname".into()),
        Op::Beq {
            rs1: T4,
            rs2: T0,
            to: "dnav_pnamed".into(),
        },
        Op::Add {
            rd: A0,
            rs1: T3,
            rs2: T4,
        },
        Op::Lbu {
            rd: A0,
            rs: A0,
            off: 0,
        },
        Op::Li {
            rd: A7,
            imm: SBI_PUTCHAR,
        },
        Op::Ecall,
        Op::Addi {
            rd: T4,
            rs: T4,
            imm: 1,
        },
        jump("dnav_pname"),
        Op::Label("dnav_pnamed".into()),
    ]);
    putc_str(&mut ops, "\n");
    ops.extend([
        Op::Label("dnav_dom".into()),
        // WasmDomText(a0=id_ptr, a1=id_len, a2=text_ptr, a3=text_len) —
        // "nav.sel" (7) ← NAV_TEXT (dedicated — the row keeps the pointer),
        // a3 already holds the text length.
        Op::La {
            rd: A0,
            addr: Addr::Label("domnav_id".into()),
        },
        Op::Li { rd: A1, imm: 7 },
        Op::Addi {
            rd: A2,
            rs: T5,
            imm: NAV_TEXT_OFF,
        },
        // The DOM call clobbers all t/a regs — save the nav state.
        st_x(xlen, T1, SP, 8),
        st_x(xlen, T2, SP, 16),
        st_x(xlen, T5, SP, 24),
        Op::Jal {
            rd: RA,
            to: "WasmDomText".into(),
        },
        ld_x(xlen, T1, SP, 8),
        ld_x(xlen, T2, SP, 16),
        ld_x(xlen, T5, SP, 24),
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: 1,
        },
        jump("dnav_next"),
        Op::Label("dnav_done".into()),
        sw(T2, T5, NAV_SEEN_OFF),
        ld_x(xlen, RA, SP, 0),
        ld_x(xlen, T1, SP, 8),
        ld_x(xlen, T2, SP, 16),
        ld_x(xlen, T5, SP, 24),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: 48,
        },
        ret(),
        // Inline rodata (never executed — sits after ret): row id + the
        // spec-derived menu ids as 8-byte slots.
        Op::Label("domnav_id".into()),
        Op::Word(u32::from_le_bytes(*b"nav.")),
        Op::Word(u32::from_le_bytes([b's', b'e', b'l', 0])),
        Op::Label("domnav_names".into()),
    ]);
    for m in spec.menus() {
        let mut b = [0u8; 8];
        let id = m.id.as_bytes();
        b[..id.len().min(8)].copy_from_slice(&id[..id.len().min(8)]);
        ops.push(Op::Word(u32::from_le_bytes([b[0], b[1], b[2], b[3]])));
        ops.push(Op::Word(u32::from_le_bytes([b[4], b[5], b[6], b[7]])));
    }
    Node {
        purpose: Purpose::Virtio,
        ops,
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
    let mut ops = vec![
        Op::Comment(
            "VioScan — __disp w×h scanout: create/attach/scanout/transfer/flush".to_string(),
        ),
        Op::Glob("VioScan".into()),
        Op::Label("VioScan".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -40,
        },
        st_x(xlen, RA, SP, 32),
        st_x(xlen, S0, SP, 24),
        st_x(xlen, S1, SP, 16),
        st_x(xlen, S2, SP, 8),
        st_x(xlen, S3, SP, 0),
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
        // Only scan out when DispSel picked the virtio-gpu rung — the mux may
        // have selected pcie/uncore instead, in which case the scanout belongs
        // to that backend and this lane must not clobber it.
        lw(T6, T5, DISP_SEL_CLASS),
        Op::Li {
            rd: T3,
            imm: i64::from(g6b_spec::OutputClass::VirtioGpu.code()),
        },
        Op::Bne {
            rs1: T6,
            rs2: T3,
            to: "vs_out".into(),
        },
        // Geometry from `__disp`, not the gen-time proxy default: S0 = w,
        // S1 = h, S2 = w*h*4, S3 = min(h, VIO_BAND_H).
        lw(S0, T5, DISP_SEL_W),
        lw(S1, T5, DISP_SEL_H),
        Op::Mul {
            rd: S2,
            rs1: S0,
            rs2: S1,
        },
        Op::Slli {
            rd: S2,
            rs: S2,
            shamt: 2,
        },
        Op::Li {
            rd: S3,
            imm: i64::from(VIO_BAND_H),
        },
        Op::Sltu {
            rd: T6,
            rs1: S1,
            rs2: S3,
        },
        Op::Beq {
            rs1: T6,
            rs2: X0,
            to: "vs_band_ok".into(),
        },
        Op::Addi {
            rd: S3,
            rs: S1,
            imm: 0,
        },
        Op::Label("vs_band_ok".into()),
    ];
    // 1. RESOURCE_CREATE_2D — res 1, B8G8R8X8, w×h.
    req_hdr(&mut ops, VIO_GPU_RESOURCE_CREATE_2D);
    sw_i(&mut ops, T2, 24, 1); // resource_id
    sw_i(&mut ops, T2, 28, i64::from(VIO_GPU_FMT_B8G8R8X8));
    ops.push(sw(S0, T2, 32));
    ops.push(sw(S1, T2, 36));
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
    ops.push(sw(S2, T2, 40));
    sw_i(&mut ops, T2, 44, 0);
    submit_nodata(&mut ops, 48, "vs_fail");
    // 3. SET_SCANOUT — scanout 0, res 1, rect {0,0,w,h}.
    req_hdr(&mut ops, VIO_GPU_SET_SCANOUT);
    ops.push(sw(X0, T2, 24));
    ops.push(sw(X0, T2, 28));
    ops.push(sw(S0, T2, 32));
    ops.push(sw(S1, T2, 36));
    sw_i(&mut ops, T2, 40, 0); // scanout_id
    sw_i(&mut ops, T2, 44, 1); // resource_id
    submit_nodata(&mut ops, 48, "vs_fail");
    // 4. paint the top `band` rows of the backing (bounded loop).
    // B91: WEB_PRESENT means host already filled Canvas32; do not paint the
    // bring-up green band over it.
    ops.extend([
        Op::La {
            rd: T6,
            addr: Addr::UiCap,
        },
        lw(T3, T6, UI_CAP_OFF_FLAGS),
        Op::Andi {
            rd: T3,
            rs: T3,
            imm: UI_CAP_FLAG_WEB as i32,
        },
        Op::Bne {
            rs1: T3,
            rs2: X0,
            to: "vs_no_fill".into(),
        },
        Op::La {
            rd: T2,
            addr: Addr::ScanFb,
        },
        Op::Li {
            rd: T3,
            imm: VIO_BAND_COLOR,
        },
        Op::Mul {
            rd: T4,
            rs1: S0,
            rs2: S3,
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
        Op::Label("vs_no_fill".into()),
    ]);
    // 5. TRANSFER_TO_HOST_2D — rect {0,0,w,band}, backing offset 0, res 1.
    req_hdr(&mut ops, VIO_GPU_TRANSFER_TO_HOST_2D);
    ops.push(sw(X0, T2, 24));
    ops.push(sw(X0, T2, 28));
    ops.push(sw(S0, T2, 32));
    ops.push(sw(S3, T2, 36));
    ops.push(sw(X0, T2, 40));
    ops.push(sw(X0, T2, 44)); // offset u64
    sw_i(&mut ops, T2, 48, 1);
    sw_i(&mut ops, T2, 52, 0);
    submit_nodata(&mut ops, 56, "vs_fail");
    // 6. RESOURCE_FLUSH — rect {0,0,w,band}, res 1.
    req_hdr(&mut ops, VIO_GPU_RESOURCE_FLUSH);
    ops.push(sw(X0, T2, 24));
    ops.push(sw(X0, T2, 28));
    ops.push(sw(S0, T2, 32));
    ops.push(sw(S3, T2, 36));
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
    ops.push(ld_x(xlen, S3, SP, 0));
    ops.push(ld_x(xlen, S2, SP, 8));
    ops.push(ld_x(xlen, S1, SP, 16));
    ops.push(ld_x(xlen, S0, SP, 24));
    ops.push(ld_x(xlen, RA, SP, 32));
    ops.push(Op::Addi {
        rd: SP,
        rs: SP,
        imm: 40,
    });
    ops.push(ret());
    Node {
        purpose: Purpose::Virtio,
        ops,
    }
}

/// The scanout palette, for host-side checks that must agree with the guest
/// blit rather than re-listing the values.
pub fn vio_palette() -> [u32; 16] {
    VIO_PAL
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
/// (ox=(W-low_w*sc)/2, oy=(H-low_h*sc)/2, exactly like `to_ppm`'s
/// sample window); `fill` stretches per axis (sx=W/low_w,
/// sy=H/low_h — the bounded integer form of `to_ppm`'s continuous
/// stretch; exact when the ratios are integral). W/H/stride are read from
/// `__disp` at runtime — the output `DispSel` latched, not the gen-time
/// proxy default — and `divu` supplies the scale so one routine covers
/// every declared output geometry. Backend-agnostic —
/// `VioPaint` (virtio TRANSFER+FLUSH) and `DispPaint` (uncore display
/// engine commit, `architecture/uncore/hdmi-display.md`) both call it, so
/// the BIOS scales the plane identically on every output path. 4bpp:
/// low_w even, each byte → two pixels. Saves t3..t6 + s0..s2 (trap-safe);
/// callers need no frame for it.
pub fn expand_node(spec: &BoardSpec) -> Node {
    expand_node_named(spec, "FbExpand", None)
}

/// `FbExpand1` — the **native-surface** blit: the same palette expansion at
/// scale 1, centred, with no magnification.
///
/// This is the `Surface::Gpu` half of the split. It exists because upscaling
/// the 640×480 ZealOS-intent plane onto a 1920×1080 output is exactly the
/// artefact the surface split removes: on a GPU-class output the plane is
/// placed 1:1 instead of being blown up ×2. Native-resolution *glyph*
/// rasterization (a 32bpp `DomPaint`) is a further step and is not this
/// routine — see `architecture/DISPLAY.md`.
pub fn expand1_node(spec: &BoardSpec) -> Node {
    expand_node_named(spec, "FbExpand1", Some(1))
}

/// `FbExpandSel` — surface-gated dispatcher.
///
/// Reads the surface `DispSel` latched and calls the matching blit, so the
/// scanout source follows the resolved output rather than being hard-wired to
/// the upscaled low-res plane. One dispatcher rather than one blit per output:
/// `FbExpand`/`FbExpand1`/`DomPaint32` all read their geometry from `__disp`
/// at runtime, so differing per-output modes need no jump table — the scale
/// and letterbox are computed from the latched output itself.
pub fn expand_sel_node(spec: &BoardSpec) -> Node {
    let xlen = spec.isa.xlen;
    let dom32 = spec.kernel.wasm.jit && (spec.wants_virtio_gpu() || spec.wants_disp_scan());
    let mut ops = vec![
        Op::Comment(
            "FbExpandSel — __disp.surface: gpu → DomPaint32 (DOM rows) or FbExpand1 (no DOM), vga → FbExpand (upscale)".into(),
        ),
        Op::Glob("FbExpandSel".into()),
        Op::Label("FbExpandSel".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -16,
        },
        st_x(xlen, RA, SP, 8),
        // Mark the current DOM dirty watermark as painted before the blit so a
        // nested timer during the long native clear does not re-enter and paint
        // again. The dirty counter is re-checked on the next tick; if it moved,
        // a repaint is still scheduled.
        Op::La {
            rd: T0,
            addr: Addr::UiDom,
        },
        Op::Lw {
            rd: T1,
            rs: T0,
            off: 4,
        },
        Op::Sw {
            rs2: T1,
            rs1: T0,
            off: crate::dom::DOM_PAINTED,
        },
        Op::La {
            rd: T0,
            addr: Addr::VioBss,
        },
        lw(T1, T0, DISP_SEL_SURFACE),
        Op::Li {
            rd: T2,
            imm: i64::from(g6b_spec::Surface::Gpu.code()),
        },
        Op::Bne {
            rs1: T1,
            rs2: T2,
            to: "fbs_vga".into(),
        },
    ];
    if dom32 {
        // GPU + DOM live: paint the DOM rows directly into __scan_fb. If the
        // DOM is empty, fall back to the native 1:1 plane blit.
        ops.push(Op::La {
            rd: T3,
            addr: Addr::UiDom,
        });
        ops.push(lw(T4, T3, 0));
        ops.push(Op::Bne {
            rs1: T4,
            rs2: X0,
            to: "fbs_dom32".into(),
        });
    }
    ops.push(Op::Jal {
        rd: RA,
        to: "FbExpand1".into(),
    });
    ops.push(jump("fbs_out"));
    if dom32 {
        ops.push(Op::Label("fbs_dom32".into()));
        ops.push(Op::Jal {
            rd: RA,
            to: "DomPaint32".into(),
        });
    }
    ops.extend([
        jump("fbs_out"),
        Op::Label("fbs_vga".into()),
        Op::Jal {
            rd: RA,
            to: "FbExpand".into(),
        },
        Op::Label("fbs_out".into()),
        ld_x(xlen, RA, SP, 8),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: 16,
        },
        ret(),
    ]);
    Node {
        purpose: Purpose::DisplayMux,
        ops,
    }
}

fn expand_node_named(spec: &BoardSpec, label: &str, force_scale: Option<u32>) -> Node {
    let xlen = spec.isa.xlen;
    let gp = g6b_spec_proxy(spec);
    let (low_w, low_h) = (gp.0, gp.1);
    // The destination geometry is *not* a gen-time constant: it is the
    // output `DispSel` latched into `__disp` (a pcie/uncore/virtio rung may
    // declare a different mode than `proxy.high_w×high_h`, and the `none`
    // fallback is the low-res geometry itself). Scale, letterbox and the
    // right-row pad are therefore computed at runtime from `__disp.w/h/
    // stride`; `divu` covers the `fit`/`fill`/`dpi` modes without a
    // per-output jump table.
    let dpi_cap = (i64::from(gp.4) / 96).max(1);
    let row_bytes = i64::from(low_w / 2);
    // Loop labels are per-copy: two blits with the same internal label names
    // would collide in the label map and branch into each other's body.
    let tag = label.to_ascii_lowercase();
    // Clamp `reg` into 1..=64. Uses a scratch `T0`; `{tag}_cl{which}` labels
    // keep the two legs apart.
    let clamp = |ops: &mut Vec<Op>, reg: u32, which: &str| {
        ops.extend([
            Op::Li { rd: T0, imm: 1 },
            Op::Sltu {
                rd: T0,
                rs1: reg,
                rs2: T0,
            },
            Op::Beq {
                rs1: T0,
                rs2: X0,
                to: format!("{tag}_cl{which}hi"),
            },
            Op::Li { rd: reg, imm: 1 },
            Op::Label(format!("{tag}_cl{which}hi")),
            Op::Li { rd: T0, imm: 64 },
            Op::Sltu {
                rd: T0,
                rs1: T0,
                rs2: reg,
            },
            Op::Beq {
                rs1: T0,
                rs2: X0,
                to: format!("{tag}_cl{which}ok"),
            },
            Op::Li { rd: reg, imm: 64 },
            Op::Label(format!("{tag}_cl{which}ok")),
        ]);
    };
    let mut ops = vec![
        Op::Comment(format!(
            "{label} — __gr_plane {low_w}x{low_h} (4bpp) → __scan_fb __disp.w×h \
             (X8R8G8B8); runtime scale/letterbox from __disp via vio_pal"
        )),
        Op::Glob(label.into()),
        Op::Label(label.into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -56,
        },
        st_x(xlen, T3, SP, 0),
        st_x(xlen, T4, SP, 8),
        st_x(xlen, T5, SP, 16),
        st_x(xlen, T6, SP, 24),
        st_x(xlen, S0, SP, 32),
        st_x(xlen, S1, SP, 40),
        st_x(xlen, S2, SP, 48),
        // Runtime output geometry: a3 = W, a4 = H, a5 = stride (bytes).
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
        lw(A3, T5, DISP_SEL_W),
        lw(A4, T5, DISP_SEL_H),
        lw(A5, T5, DISP_SEL_STRIDE),
    ];
    // sx → S0, sy → S1. `force_scale` pins both (FbExpand1's 1:1 placement);
    // otherwise the mode string is a gen-time pick between runtime-divide
    // forms.
    match force_scale {
        Some(s) => {
            let s = i64::from(s.clamp(1, 64));
            ops.push(Op::Li { rd: S0, imm: s });
            ops.push(Op::Li { rd: S1, imm: s });
        }
        None if gp.6 == "fill" => {
            ops.extend([
                Op::Li {
                    rd: T0,
                    imm: i64::from(low_w),
                },
                Op::Divu {
                    rd: S0,
                    rs1: A3,
                    rs2: T0,
                },
            ]);
            clamp(&mut ops, S0, "x");
            ops.extend([
                Op::Li {
                    rd: T0,
                    imm: i64::from(low_h),
                },
                Op::Divu {
                    rd: S1,
                    rs1: A4,
                    rs2: T0,
                },
            ]);
            clamp(&mut ops, S1, "y");
        }
        None => {
            // fit = min(W/low_w, H/low_h); dpi caps it at dpi/96.
            ops.extend([
                Op::Li {
                    rd: T0,
                    imm: i64::from(low_w),
                },
                Op::Divu {
                    rd: T1,
                    rs1: A3,
                    rs2: T0,
                },
                Op::Li {
                    rd: T0,
                    imm: i64::from(low_h),
                },
                Op::Divu {
                    rd: T2,
                    rs1: A4,
                    rs2: T0,
                },
                // s = min(qx, qy): sltu t0, qx, qy → qx<qy ⇒ keep qx.
                Op::Sltu {
                    rd: T0,
                    rs1: T1,
                    rs2: T2,
                },
                Op::Bne {
                    rs1: T0,
                    rs2: X0,
                    to: format!("{tag}_fqx"),
                },
                Op::Addi {
                    rd: T1,
                    rs: T2,
                    imm: 0,
                },
                Op::Label(format!("{tag}_fqx")),
            ]);
            if gp.6 == "dpi" {
                ops.extend([
                    Op::Li {
                        rd: T0,
                        imm: dpi_cap,
                    },
                    Op::Sltu {
                        rd: T2,
                        rs1: T0,
                        rs2: T1,
                    },
                    Op::Beq {
                        rs1: T2,
                        rs2: X0,
                        to: format!("{tag}_fdpi"),
                    },
                    Op::Addi {
                        rd: T1,
                        rs: T0,
                        imm: 0,
                    },
                    Op::Label(format!("{tag}_fdpi")),
                ]);
            }
            ops.push(Op::Addi {
                rd: S0,
                rs: T1,
                imm: 0,
            });
            clamp(&mut ops, S0, "s");
            ops.push(Op::Addi {
                rd: S1,
                rs: S0,
                imm: 0,
            });
        }
    }
    ops.extend([
        // used_w = low_w*sx → t2, used_h = low_h*sy → t3.
        Op::Li {
            rd: T0,
            imm: i64::from(low_w),
        },
        Op::Mul {
            rd: T2,
            rs1: T0,
            rs2: S0,
        },
        Op::Li {
            rd: T0,
            imm: i64::from(low_h),
        },
        Op::Mul {
            rd: T3,
            rs1: T0,
            rs2: S1,
        },
        // ox = max(0, (W - used_w) >> 1) → t4; oy → t1.
        Op::Sub {
            rd: T4,
            rs1: A3,
            rs2: T2,
        },
        Op::Srli {
            rd: T0,
            rs: T4,
            shamt: signbit(xlen),
        },
        Op::Bne {
            rs1: T0,
            rs2: X0,
            to: format!("{tag}_oxz"),
        },
        Op::Srli {
            rd: T4,
            rs: T4,
            shamt: 1,
        },
        jump(&format!("{tag}_oxd")),
        Op::Label(format!("{tag}_oxz")),
        Op::Li { rd: T4, imm: 0 },
        Op::Label(format!("{tag}_oxd")),
        Op::Sub {
            rd: T1,
            rs1: A4,
            rs2: T3,
        },
        Op::Srli {
            rd: T0,
            rs: T1,
            shamt: signbit(xlen),
        },
        Op::Bne {
            rs1: T0,
            rs2: X0,
            to: format!("{tag}_oyz"),
        },
        Op::Srli {
            rd: T1,
            rs: T1,
            shamt: 1,
        },
        jump(&format!("{tag}_oyd")),
        Op::Label(format!("{tag}_oyz")),
        Op::Li { rd: T1, imm: 0 },
        Op::Label(format!("{tag}_oyd")),
        // row_pad = max(0, stride - used_w*4) → s2.
        Op::Slli {
            rd: T6,
            rs: T2,
            shamt: 2,
        },
        Op::Sub {
            rd: S2,
            rs1: A5,
            rs2: T6,
        },
        Op::Srli {
            rd: T0,
            rs: S2,
            shamt: signbit(xlen),
        },
        Op::Beq {
            rs1: T0,
            rs2: X0,
            to: format!("{tag}_rpok"),
        },
        Op::Li { rd: S2, imm: 0 },
        Op::Label(format!("{tag}_rpok")),
        // t0 = src row base, t1 = dst = __scan_fb + oy*stride + ox*4,
        // t5 = palette, t6 = src rows left.
        Op::La {
            rd: T0,
            addr: Addr::GrPlane,
        },
        Op::Addi {
            rd: T0,
            rs: T0,
            imm: crate::GR_HEADER_BYTES as i32,
        },
        Op::Mul {
            rd: T1,
            rs1: T1,
            rs2: A5,
        },
        Op::Slli {
            rd: T4,
            rs: T4,
            shamt: 2,
        },
        Op::Add {
            rd: T1,
            rs1: T1,
            rs2: T4,
        },
        // Destination framebuffer: `DISP_SEL_FB_LO` is nonzero only on the
        // pcie-linear-fb rung (the accepted BAR), so a latched linear window
        // is painted in place and `__scan_fb` is the shared fallback for the
        // virtio/uncore transports (which DMA or scan it themselves). T5 is
        // still `__vio` here; it is rebound to the palette next.
        lw(T4, T5, DISP_SEL_FB_LO),
        Op::Bne {
            rs1: T4,
            rs2: X0,
            to: format!("{tag}_dst"),
        },
        Op::La {
            rd: T4,
            addr: Addr::ScanFb,
        },
        Op::Label(format!("{tag}_dst")),
        Op::Add {
            rd: T1,
            rs1: T1,
            rs2: T4,
        },
        Op::La {
            rd: T5,
            addr: Addr::Label("vio_pal".into()),
        },
        Op::Li {
            rd: T6,
            imm: i64::from(low_h),
        },
        Op::Label(format!("{tag}_row")),
        Op::Addi {
            rd: T2,
            rs: S1,
            imm: 0,
        },
        Op::Label(format!("{tag}_rep")),
        Op::Addi {
            rd: T3,
            rs: T0,
            imm: 0,
        },
        Op::Li {
            rd: T4,
            imm: row_bytes,
        },
        Op::Label(format!("{tag}_byte")),
        Op::Lbu {
            rd: A0,
            rs: T3,
            off: 0,
        },
        // even pixel = high nibble → sx scaled words (runtime count in a1)
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
        Op::Addi {
            rd: A1,
            rs: S0,
            imm: 0,
        },
        Op::Label(format!("{tag}_hx")),
        sw(A2, T1, 0),
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: 4,
        },
        Op::Addi {
            rd: A1,
            rs: A1,
            imm: -1,
        },
        Op::Bne {
            rs1: A1,
            rs2: X0,
            to: format!("{tag}_hx"),
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
        Op::Addi {
            rd: A1,
            rs: S0,
            imm: 0,
        },
        Op::Label(format!("{tag}_lx")),
        sw(A2, T1, 0),
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: 4,
        },
        Op::Addi {
            rd: A1,
            rs: A1,
            imm: -1,
        },
        Op::Bne {
            rs1: A1,
            rs2: X0,
            to: format!("{tag}_lx"),
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
            to: format!("{tag}_byte"),
        },
        // next dst row: skip the right-letterbox pad (0 on a full-width fill).
        Op::Add {
            rd: T1,
            rs1: T1,
            rs2: S2,
        },
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: -1,
        },
        Op::Bne {
            rs1: T2,
            rs2: X0,
            to: format!("{tag}_rep"),
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
            to: format!("{tag}_row"),
        },
        ld_x(xlen, S2, SP, 48),
        ld_x(xlen, S1, SP, 40),
        ld_x(xlen, S0, SP, 32),
        ld_x(xlen, T6, SP, 24),
        ld_x(xlen, T5, SP, 16),
        ld_x(xlen, T4, SP, 8),
        ld_x(xlen, T3, SP, 0),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: 56,
        },
        ret(),
    ]);
    // Inline rodata (never executed — sits after ret). Emitted once, by the
    // primary copy; `FbExpand1` shares the same table via its `La`.
    if force_scale.is_none() {
        ops.push(Op::Label("vio_pal".into()));
        for w32 in VIO_PAL {
            ops.push(Op::Word(w32));
        }
    }
    Node {
        purpose: Purpose::Virtio,
        ops,
    }
}

/// "a web canvas owns the paint surface" test for the expand gates: `__ui_cap`
/// reads `G6CP` + `FLAG_WEB` — `DomtRaster`'s text canvas, a decoded
/// `__web_pk`, and an exec-model injected present all stamp it (the cap
/// survives the boot BSS-zero precisely so a pre-filled persist counts), or
/// — on boards with no cap block (pcie-linear-fb) — the `WEB_STAMPED` latch
/// `WebBlit`/`CliInit` maintain. Branches to `have` when a canvas is live and
/// falls through to the caller's `FbExpandSel` otherwise. Scratches T0/T1/T6
/// (both callers save them).
fn web_canvas_live_ops(spec: &BoardSpec, have: &str, chk: &str) -> Vec<Op> {
    let has_cap = spec.wants_virtio_gpu() || spec.wants_disp_scan();
    let mut ops = Vec::new();
    if has_cap {
        ops.extend([
            Op::La {
                rd: T6,
                addr: Addr::UiCap,
            },
            lw(T0, T6, 0),
            Op::Li {
                rd: T1,
                imm: i64::from(UI_CAP_MAGIC),
            },
            Op::Bne {
                rs1: T0,
                rs2: T1,
                to: chk.into(),
            },
            lw(T0, T6, UI_CAP_OFF_FLAGS),
            Op::Andi {
                rd: T0,
                rs: T0,
                imm: UI_CAP_FLAG_WEB as i32,
            },
            Op::Bne {
                rs1: T0,
                rs2: X0,
                to: have.into(),
            },
            Op::Label(chk.into()),
        ]);
    }
    ops.extend([
        Op::La {
            rd: T6,
            addr: Addr::UartLine,
        },
        lw(T0, T6, crate::WEB_STAMPED_OFF),
        Op::Bne {
            rs1: T0,
            rs2: X0,
            to: have.into(),
        },
    ]);
    ops
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
    let mut ops = vec![
        Op::Comment(format!(
            "DispPaint — FbExpandSel + display-engine commit @ {base:#x} \
             (geometry from __disp) + G6FB descriptor"
        )),
        Op::Glob("DispPaint".into()),
        Op::Label("DispPaint".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -64,
        },
        st_x(xlen, RA, SP, 56),
        st_x(xlen, T3, SP, 48),
        st_x(xlen, T4, SP, 40),
        st_x(xlen, T5, SP, 32),
        st_x(xlen, T6, SP, 24),
        st_x(xlen, S0, SP, 16),
        st_x(xlen, S1, SP, 8),
        st_x(xlen, S2, SP, 0),
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
        // Only commit when DispSel picked the uncore-scanout rung — a
        // virtio/pcie winner means this engine is not the output.
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
        lw(T6, T5, DISP_SEL_CLASS),
        Op::Li {
            rd: T3,
            imm: i64::from(g6b_spec::OutputClass::UncoreScanout.code()),
        },
        Op::Bne {
            rs1: T6,
            rs2: T3,
            to: "dp_out".into(),
        },
        // Runtime geometry from `__disp` (the latched output), not the
        // gen-time proxy default: S0 = w, S1 = h, S2 = stride.
        lw(S0, T5, DISP_SEL_W),
        lw(S1, T5, DISP_SEL_H),
        lw(S2, T5, DISP_SEL_STRIDE),
        // Surface-gated: the resolved surface decides whether the plane is
        // upscaled or placed 1:1, so a GPU-class output never gets the
        // magnified low-res picture by default. A live web canvas is
        // different again: `WebBlit`/`DomtRaster`/an injected present already
        // wrote `__scan_fb`, so the plane expand must not paint over it.
    ];
    ops.extend(web_canvas_live_ops(spec, "dp_have_canvas", "dp_chk_latch"));
    ops.extend([
        Op::Jal {
            rd: RA,
            to: "FbExpandSel".into(),
        },
        Op::Label("dp_have_canvas".into()),
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
    ]);
    ops.push(sw(S0, T0, 0x14));
    ops.push(sw(S1, T0, 0x18));
    ops.push(sw(S2, T0, 0x1c));
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
    ops.push(sw(S0, T5, DISP_DESC_OFF + 12));
    ops.push(sw(S1, T5, DISP_DESC_OFF + 16));
    ops.push(sw(S2, T5, DISP_DESC_OFF + 20));
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
    ops.push(ld_x(xlen, S2, SP, 0));
    ops.push(ld_x(xlen, S1, SP, 8));
    ops.push(ld_x(xlen, S0, SP, 16));
    ops.push(ld_x(xlen, T6, SP, 24));
    ops.push(ld_x(xlen, T5, SP, 32));
    ops.push(ld_x(xlen, T4, SP, 40));
    ops.push(ld_x(xlen, T3, SP, 48));
    ops.push(ld_x(xlen, RA, SP, 56));
    ops.push(Op::Addi {
        rd: SP,
        rs: SP,
        imm: 64,
    });
    ops.push(ret());
    Node {
        purpose: Purpose::DispScan,
        ops,
    }
}

pub fn paint_node(spec: &BoardSpec) -> Node {
    let xlen = spec.isa.xlen;
    let mut ops = vec![
        Op::Comment(
            "VioPaint — if __ui_cap WEB_PRESENT, TRANSFER dirty tiles of \
             Canvas32 already in __scan_fb (B91; skip FbExpandSel). Else \
             jal FbExpandSel then full-frame TRANSFER+FLUSH"
                .to_string(),
        ),
        Op::Glob("VioPaint".into()),
        Op::Label("VioPaint".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -64,
        },
        st_x(xlen, RA, SP, 56),
        st_x(xlen, T3, SP, 48),
        st_x(xlen, T4, SP, 40),
        st_x(xlen, T5, SP, 32),
        st_x(xlen, T6, SP, 24),
        st_x(xlen, S0, SP, 16),
        st_x(xlen, S1, SP, 8),
        st_x(xlen, S2, SP, 0),
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
        // Re-entrancy: a trap-context paint (trap_timer tick / Ui) may land
        // while a boot-context VioCmd sleeps on its wfi — the shared ctrlq
        // can't interleave, so skip the frame (the in-flight transaction's
        // own flush covers it).
        lw(T6, T5, VIO_BUSY_OFF),
        Op::Bne {
            rs1: T6,
            rs2: X0,
            to: "vp_out".into(),
        },
        // Only paint when DispSel picked the virtio-gpu rung; a pcie/uncore
        // winner means this backend is not the committed output.
        lw(T6, T5, DISP_SEL_CLASS),
        Op::Li {
            rd: T3,
            imm: i64::from(g6b_spec::OutputClass::VirtioGpu.code()),
        },
        Op::Bne {
            rs1: T6,
            rs2: T3,
            to: "vp_out".into(),
        },
        // Runtime scanout geometry from `__disp` (the latched output), not
        // the gen-time proxy default.
        lw(S0, T5, DISP_SEL_W),
        lw(S1, T5, DISP_SEL_H),
        // Surface-gated (see DispPaint): upscale only on the VGA surface.
        // B91: compact persist WEB_PRESENT means __scan_fb already holds
        // Canvas32; TRANSFER those dirty tiles instead of FbExpandSel.
        Op::La {
            rd: T6,
            addr: Addr::UiCap,
        },
        lw(T3, T6, UI_CAP_OFF_FLAGS),
        Op::Andi {
            rd: T3,
            rs: T3,
            imm: UI_CAP_FLAG_WEB as i32,
        },
        Op::Bne {
            rs1: T3,
            rs2: X0,
            to: "vp_web".into(),
        },
        Op::Jal {
            rd: RA,
            to: "FbExpandSel".into(),
        },
        Op::Jal {
            rd: X0,
            to: "vp_full".into(),
        },
        Op::Label("vp_web".into()),
        lw(T4, T6, UI_CAP_OFF_NTILE),
        Op::Beq {
            rs1: T4,
            rs2: X0,
            to: "vp_skip".into(),
        },
        Op::Li { rd: S2, imm: 0 },
        Op::Label("vp_tile".into()),
        Op::La {
            rd: T6,
            addr: Addr::UiCap,
        },
        Op::Slli {
            rd: T1,
            rs: S2,
            shamt: 4,
        },
        Op::Add {
            rd: T1,
            rs1: T6,
            rs2: T1,
        },
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: UI_CAP_OFF_RECTS,
        },
        lw(A3, T1, 0),
        lw(A4, T1, 4),
        lw(A5, T1, 8),
        lw(A6, T1, 12),
    ];
    req_hdr(&mut ops, VIO_GPU_TRANSFER_TO_HOST_2D);
    ops.push(sw(A3, T2, 24));
    ops.push(sw(A4, T2, 28));
    ops.push(sw(A5, T2, 32));
    ops.push(sw(A6, T2, 36));
    ops.push(sw(X0, T2, 40));
    ops.push(sw(X0, T2, 44));
    sw_i(&mut ops, T2, 48, 1);
    sw_i(&mut ops, T2, 52, 0);
    submit_nodata(&mut ops, 56, "vp_fail");
    ops.extend([
        Op::Addi {
            rd: S2,
            rs: S2,
            imm: 1,
        },
        Op::La {
            rd: T6,
            addr: Addr::UiCap,
        },
        lw(T4, T6, UI_CAP_OFF_NTILE),
        Op::Bne {
            rs1: S2,
            rs2: T4,
            to: "vp_tile".into(),
        },
        // Consume tiles so a later tick is skip-if-clean.
        sw(X0, T6, UI_CAP_OFF_NTILE),
        Op::Jal {
            rd: X0,
            to: "vp_flush".into(),
        },
        Op::Label("vp_skip".into()),
    ]);
    putc_str(&mut ops, "VIRTIO-PAINT-SKIP\n");
    ops.push(Op::Jal {
        rd: X0,
        to: "vp_out".into(),
    });
    ops.push(Op::Label("vp_full".into()));
    // TRANSFER_TO_HOST_2D — rect {0,0,w,h}, backing offset 0, res 1.
    req_hdr(&mut ops, VIO_GPU_TRANSFER_TO_HOST_2D);
    ops.push(sw(X0, T2, 24));
    ops.push(sw(X0, T2, 28));
    ops.push(sw(S0, T2, 32));
    ops.push(sw(S1, T2, 36));
    ops.push(sw(X0, T2, 40));
    ops.push(sw(X0, T2, 44)); // offset u64
    sw_i(&mut ops, T2, 48, 1);
    sw_i(&mut ops, T2, 52, 0);
    submit_nodata(&mut ops, 56, "vp_fail");
    ops.push(Op::Label("vp_flush".into()));
    // RESOURCE_FLUSH — rect {0,0,w,h}, res 1.
    req_hdr(&mut ops, VIO_GPU_RESOURCE_FLUSH);
    ops.push(sw(X0, T2, 24));
    ops.push(sw(X0, T2, 28));
    ops.push(sw(S0, T2, 32));
    ops.push(sw(S1, T2, 36));
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
    ops.push(ld_x(xlen, S2, SP, 0));
    ops.push(ld_x(xlen, S1, SP, 8));
    ops.push(ld_x(xlen, S0, SP, 16));
    ops.push(ld_x(xlen, T6, SP, 24));
    ops.push(ld_x(xlen, T5, SP, 32));
    ops.push(ld_x(xlen, T4, SP, 40));
    ops.push(ld_x(xlen, T3, SP, 48));
    ops.push(ld_x(xlen, RA, SP, 56));
    ops.push(Op::Addi {
        rd: SP,
        rs: SP,
        imm: 64,
    });
    ops.push(ret());
    Node {
        purpose: Purpose::Virtio,
        ops,
    }
}

/// `PciPaint` — commit the frame to a PCIe-linear-fb output.
///
/// There is no register window and no doorbell on this rung: the accepted BAR
/// *is* the display memory the adapter scans out, so the commit is just the
/// blit. `DispSel` copied the BAR into `DISP_SEL_FB_LO`, and the `FbExpand`/
/// `FbExpand1`/`DomPaint32` destination pick writes it in place — `__scan_fb`
/// is never touched on this rung. A `fence` orders the (possibly WC) stores
/// before the frame is considered live. Prints `PCI-PAINT`; gates out silently
/// when `DispSel` did not pick the pcie rung or no BAR was accepted — the
/// other paint backends own their own surfaces.
pub fn pci_paint_node(spec: &BoardSpec) -> Node {
    let xlen = spec.isa.xlen;
    let mut ops = vec![
        Op::Comment(
            "PciPaint — jal FbExpandSel straight into the accepted BAR \
             (__disp.fb), then fence; class-gated on pcie-linear-fb"
                .to_string(),
        ),
        Op::Glob("PciPaint".into()),
        Op::Label("PciPaint".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -32,
        },
        st_x(xlen, RA, SP, 24),
        st_x(xlen, T5, SP, 16),
        st_x(xlen, T6, SP, 8),
        st_x(xlen, T3, SP, 0),
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
        // Only paint when DispSel picked the pcie-linear-fb rung — a
        // virtio/uncore winner means this backend is not the output.
        lw(T6, T5, DISP_SEL_CLASS),
        Op::Li {
            rd: T3,
            imm: i64::from(g6b_spec::OutputClass::PcieLinearFb.code()),
        },
        Op::Bne {
            rs1: T6,
            rs2: T3,
            to: "pp_out".into(),
        },
        // Fail closed when PciProbe accepted no BAR: there is no linear
        // framebuffer to paint.
        lw(T6, T5, DISP_PCI_FB),
        Op::Beq {
            rs1: T6,
            rs2: X0,
            to: "pp_out".into(),
        },
        // A live web canvas already fills the BAR/`__scan_fb` — the plane
        // expand would paint the container over it.
    ];
    ops.extend(web_canvas_live_ops(spec, "pp_have_canvas", "pp_chk_latch"));
    ops.extend([
        Op::Jal {
            rd: RA,
            to: "FbExpandSel".into(),
        },
        Op::Label("pp_have_canvas".into()),
        // Order the framebuffer stores before the frame is considered live —
        // the BAR may be mapped WC, so posted writes need a fence to be
        // visible to the adapter's scanout in program order.
        Op::Fence,
    ]);
    putc_str(&mut ops, "PCI-PAINT\n");
    ops.push(Op::Label("pp_out".into()));
    ops.push(ld_x(xlen, T3, SP, 0));
    ops.push(ld_x(xlen, T6, SP, 8));
    ops.push(ld_x(xlen, T5, SP, 16));
    ops.push(ld_x(xlen, RA, SP, 24));
    ops.push(Op::Addi {
        rd: SP,
        rs: SP,
        imm: 32,
    });
    ops.push(ret());
    Node {
        purpose: Purpose::PciScan,
        ops,
    }
}
