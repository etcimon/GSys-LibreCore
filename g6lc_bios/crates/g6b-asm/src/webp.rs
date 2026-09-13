// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
//! Packed web present (`__web_pk`) — the host-rendered `BrowserSession`
//! `Canvas32` scene carried in `.rodata` and blitted into the `__disp`-latched
//! scanout surface by the guest `WebBlit` routine.
//!
//! This is a *computed scene*, not an in-guest CSS engine: the cascade,
//! layout and raster all ran host-side (`g6b_kernel::web_pk_pack` at the
//! `default_output()` geometry); what ships is a bounded RLE word stream of
//! B8G8R8X8 pixels the guest replays verbatim. The record:
//!
//! ```text
//! +0   u32  magic 'G6PK' (WEB_PK_MAGIC)
//! +4   u32  pack width  (pixels, = default_output().w at pack time)
//! +8   u32  pack height (pixels, = default_output().h at pack time)
//! +12  u32  live DOM node count (carried into __ui_cap's node field)
//! +16  …    token stream, row-major, never crossing a row boundary:
//!           T == 0            end of stream
//!           T & 0x8000_0000   LITERAL — copy (T & 0x7fff_ffff) pixel words
//!           else              RUN — emit T copies of the next pixel word
//! ```
//!
//! `WebBlit` answers `a0`: `1` = a web canvas is live on the surface (the
//! caller must not paint a legacy face over it), `0` = no pack installed or
//! no output latched (the caller's `WasmUi`/`DomtRaster` fallback still
//! applies — e.g. the bounded `test` cell).

#![allow(missing_docs)]

use g6b_spec::BoardSpec;

use crate::domt::{DOMT_HDR, DOMT_NODE, DOMT_NODES, F_DIRTY, H_DIRTY, N_FLAGS};
use crate::encode::{
    A0, A2, A6, A7, RA, S0, S1, S2, S3, S4, SBI_PUTCHAR, SP, T0, T1, T2, T5, T6, X0,
};
use crate::vio::{
    DISP_SEL_FB_HI, DISP_SEL_FB_LO, DISP_SEL_H, DISP_SEL_STRIDE, DISP_SEL_W, UI_CAP_FLAG_PK,
    UI_CAP_FLAG_WEB, UI_CAP_MAGIC, UI_CAP_OFF_FLAGS, UI_CAP_OFF_NODES, UI_CAP_OFF_NTILE,
    UI_CAP_OFF_RECTS,
};
use crate::{Addr, Node, Op, Purpose, WEB_STAMPED_OFF};

/// `__web_pk+0` — 'G6PK'.
pub const WEB_PK_MAGIC: u32 = u32::from_le_bytes(*b"G6PK");
/// Header bytes before the token stream.
pub const WEB_PK_HDR: i32 = 16;
/// `__web_pk` byte ceiling — the pack is `.rodata`, so it shares the payload
/// image's footprint. The styled shell scene is overwhelmingly flat navy
/// (runs), so 1 MiB is generous headroom over the observed ~100–400 KiB; a
/// scene that cannot stay under it is a build error, not a silent fallback.
pub const WEB_PK_MAX_BYTES: usize = 0x10_0000;

fn lw(rd: u32, rs: u32, off: i32) -> Op {
    Op::Lw { rd, rs, off }
}
fn sw(rs2: u32, rs1: u32, off: i32) -> Op {
    Op::Sw { rs2, rs1, off }
}
fn addi(rd: u32, rs: u32, imm: i32) -> Op {
    Op::Addi { rd, rs, imm }
}
fn add(rd: u32, a: u32, b: u32) -> Op {
    Op::Add { rs1: a, rs2: b, rd }
}
fn sub(rd: u32, a: u32, b: u32) -> Op {
    Op::Sub { rs1: a, rs2: b, rd }
}
fn or_(rd: u32, a: u32, b: u32) -> Op {
    Op::Or { rs: a, rs2: b, rd }
}
fn slli(rd: u32, rs: u32, shamt: u32) -> Op {
    Op::Slli { rd, rs, shamt }
}
fn srli(rd: u32, rs: u32, shamt: u32) -> Op {
    Op::Srli { rd, rs, shamt }
}
fn li(rd: u32, imm: i64) -> Op {
    Op::Li { rd, imm }
}
fn la(rd: u32, addr: Addr) -> Op {
    Op::La { rd, addr }
}
fn mv(rd: u32, rs: u32) -> Op {
    Op::Addi { rd, rs, imm: 0 }
}
fn beq(a: u32, b: u32, to: &str) -> Op {
    Op::Beq {
        rs1: a,
        rs2: b,
        to: to.into(),
    }
}
fn bne(a: u32, b: u32, to: &str) -> Op {
    Op::Bne {
        rs1: a,
        rs2: b,
        to: to.into(),
    }
}
fn bltz(a: u32, to: &str) -> Op {
    Op::Blt {
        rs1: a,
        rs2: X0,
        to: to.into(),
    }
}
fn bgeu(a: u32, b: u32, to: &str) -> Op {
    Op::Bgeu {
        rs1: a,
        rs2: b,
        to: to.into(),
    }
}
fn j(to: &str) -> Op {
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
fn putc(ops: &mut Vec<Op>, ch: i64) {
    ops.push(li(A0, ch));
    ops.push(li(A7, SBI_PUTCHAR));
    ops.push(Op::Ecall);
}
fn puts(ops: &mut Vec<Op>, s: &str) {
    for b in s.bytes() {
        putc(ops, i64::from(b));
    }
}
/// Print `T0` as 16 hex digits via the shared `hexdig` table (trap node).
fn put_hex(ops: &mut Vec<Op>, label: &str) {
    ops.extend([
        li(A2, 16),
        Op::Label(label.into()),
        srli(T2, T0, 60),
        Op::Andi {
            rd: T2,
            rs: T2,
            imm: 0xf,
        },
        slli(T0, T0, 4),
        la(A6, Addr::Label("hexdig".into())),
        add(A6, A6, T2),
        Op::Lbu {
            rd: A0,
            rs: A6,
            off: 0,
        },
        li(A7, SBI_PUTCHAR),
        Op::Ecall,
        addi(A2, A2, -1),
        bne(A2, X0, label),
    ]);
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

/// `WebBlit` — decode `__web_pk` into the `__disp`-latched surface and stamp
/// the compact persist so `vp_web` transfers the frame.
///
/// Idempotence/ownership contract:
///
/// * "live" = `__ui_cap` reads `G6CP` magic *and* `UI_CAP_FLAG_PK` (the
///   rendered-canvas bit — `DomtRaster` stamps `FLAG_WEB` alone for its
///   text-face tiles, so WEB cannot serve here), or — on a board with no
///   `__ui_cap` (pcie-only) — the `WEB_STAMPED` latch in `__uart_line`.
///   Live ⇒ `a0=1` with no re-blit, so an exec-model `inject_web_present`
///   canvas and an already-decoded pack both suppress redundant work.
/// * On success the routine sets `WEB_STAMPED`, stamps `__ui_cap`
///   (MAGIC + WEB|PK flags + node count + one full-frame wipe tile — the
///   only tile shape a backing-offset-0 `TRANSFER_TO_HOST_2D` reads
///   correctly), and clears `__dom`'s `H_DIRTY`/node `F_DIRTY` bits so the
///   bounded `DomtRaster` never repaints its text face over the packed
///   scene.
/// * `CliInit` clears both latches on the web→CLI transition, so the pack
///   re-blits if the browser face is picked again.
///
/// `s0..s4` carry the decode state and are saved/restored like `DomtRaster`'s
/// (the trap frame does not cover s-regs). Everything else is scratch.
fn web_blit_node(spec: &BoardSpec) -> Node {
    let xlen = spec.isa.xlen;
    // `__vio` (and therefore `__disp`) exists only when a scanout backend or
    // the mux is compiled — the same condition that allocates `vio_bytes`.
    let has_vio = spec.wants_virtio_gpu()
        || spec.wants_virtio_net()
        || spec.wants_disp_scan()
        || spec.kernel.gr.enable
        || spec.kernel.proxy.enable;
    // `__ui_cap` exists only where `vp_web` can consume it (analyze.rs).
    let has_cap = spec.wants_virtio_gpu() || spec.wants_disp_scan();
    let has_dom = spec.kernel.wasm.guest_jit;
    let mut ops = vec![
        Op::Comment(
            "WebBlit — decode __web_pk (host Canvas32 RLE) into the latched \
             surface; a0=1 when a web canvas is live"
                .into(),
        ),
        Op::Glob("WebBlit".into()),
        Op::Label("WebBlit".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -48,
        },
        st_x(xlen, RA, SP, 40),
        st_x(xlen, S0, SP, 32),
        st_x(xlen, S1, SP, 24),
        st_x(xlen, S2, SP, 16),
        st_x(xlen, S3, SP, 8),
        st_x(xlen, S4, SP, 0),
    ];
    // Already live? `UI_CAP_FLAG_PK` is the ownership bit — `DomtRaster`
    // stamps `G6CP`+`FLAG_WEB` for its text-face tiles, so the WEB bit alone
    // cannot distinguish its persist from a real canvas; only a decoded pack
    // or an injected `GuestWebPresent` sets PK. `__ui_cap` survives the boot
    // BSS-zero (deliberately skipped for B91 pre-fill), which `__uart_line`
    // does not — the `WEB_STAMPED` latch still covers cap-less boards (a pack
    // decoded earlier this boot) and post-boot injects.
    if has_cap {
        ops.extend([
            la(T6, Addr::UiCap),
            lw(T0, T6, 0),
            li(T1, i64::from(UI_CAP_MAGIC)),
            bne(T0, T1, "webp_chk_stamp"),
            lw(T0, T6, UI_CAP_OFF_FLAGS),
            Op::Andi {
                rd: T0,
                rs: T0,
                imm: UI_CAP_FLAG_PK as i32,
            },
            bne(T0, X0, "webp_live"),
            Op::Label("webp_chk_stamp".into()),
        ]);
    }
    ops.extend([
        la(T6, Addr::UartLine),
        lw(T0, T6, WEB_STAMPED_OFF),
        bne(T0, X0, "webp_live"),
        // Pack present? `__web_pk` reads a non-magic word when none was
        // installed (it aliases `boot_log`'s 'KSTA' first word).
        la(S3, Addr::WebPk),
        lw(T0, S3, 0),
        li(T1, i64::from(WEB_PK_MAGIC)),
        bne(T0, T1, "webp_absent"),
    ]);
    if has_vio {
        ops.extend([
            // Geometry: the output the mux latched, clamped to the pack. A
            // zero latch means DispSel found no output — nothing to paint.
            la(T6, Addr::VioBss),
            lw(T0, T6, DISP_SEL_W),
            beq(T0, X0, "webp_absent"),
            lw(T1, T6, DISP_SEL_H),
            beq(T1, X0, "webp_absent"),
            lw(S1, S3, 4), // pack w
            lw(S2, S3, 8), // pack h
            bgeu(T0, S1, "webp_w_ok"),
            mv(S1, T0),
            Op::Label("webp_w_ok".into()),
            bgeu(T1, S2, "webp_h_ok"),
            mv(S2, T1),
            Op::Label("webp_h_ok".into()),
            // s0 = dest fb: the latched surface, else __scan_fb.
            lw(T2, T6, DISP_SEL_STRIDE), // bytes
            lw(T0, T6, DISP_SEL_FB_LO),
            lw(T1, T6, DISP_SEL_FB_HI),
            slli(T1, T1, 32),
            or_(T0, T0, T1),
            bne(T0, X0, "webp_havefb"),
            la(T0, Addr::ScanFb),
            Op::Label("webp_havefb".into()),
            mv(S0, T0),
            // s4 = pitch adjust = stride - w*4 (bytes).
            slli(T1, S1, 2),
            sub(S4, T2, T1),
        ]);
    } else {
        // No `__disp` block — paint the pack verbatim into `__scan_fb` (the
        // only surface such a build can have); pack geometry is the truth
        // and the buffer is tightly packed (no pitch adjust).
        ops.extend([
            lw(S1, S3, 4),
            lw(S2, S3, 8),
            la(S0, Addr::ScanFb),
            li(S4, 0),
        ]);
    }
    ops.extend([
        // Malformed dims fail closed: a 0-width or 0-height pack must not
        // stamp the surface live — the text-face fallback still applies.
        beq(S1, X0, "webp_absent"),
        beq(S2, X0, "webp_absent"),
        addi(S3, S3, WEB_PK_HDR),
        // ---- row loop: s2 rows left, t2 = pixels left in this row ---------
        Op::Label("webp_row".into()),
        beq(S2, X0, "webp_done"),
        mv(T2, S1),
        Op::Label("webp_tok".into()),
        beq(T2, X0, "webp_eol"),
        lw(T0, S3, 0),
        addi(S3, S3, 4),
        beq(T0, X0, "webp_done"), // stream-end marker mid-row: fail closed
        bltz(T0, "webp_lit"),
        // RUN: t0 copies of the next word (clamped to the row remainder).
        bgeu(T2, T0, "webp_run_n"),
        mv(T0, T2),
        Op::Label("webp_run_n".into()),
        sub(T2, T2, T0),
        lw(T1, S3, 0),
        addi(S3, S3, 4),
        Op::Label("webp_run".into()),
        sw(T1, S0, 0),
        addi(S0, S0, 4),
        addi(T0, T0, -1),
        bne(T0, X0, "webp_run"),
        j("webp_tok"),
        // LITERAL: copy (T & 0x7fff_ffff) words verbatim. `lw` sign-extends
        // on RV64, so the tag bit sits under a full sign-extension — a
        // 33-bit funnel drops both (31 payload bits survive); on RV32 the
        // same extraction is a single-bit shift.
        Op::Label("webp_lit".into()),
        slli(T0, T0, xlen - 31),
        srli(T0, T0, xlen - 31),
        bgeu(T2, T0, "webp_lit_n"),
        mv(T0, T2),
        Op::Label("webp_lit_n".into()),
        sub(T2, T2, T0),
        Op::Label("webp_litc".into()),
        lw(T1, S3, 0),
        sw(T1, S0, 0),
        addi(S3, S3, 4),
        addi(S0, S0, 4),
        addi(T0, T0, -1),
        bne(T0, X0, "webp_litc"),
        j("webp_tok"),
        Op::Label("webp_eol".into()),
        add(S0, S0, S4),
        addi(S2, S2, -1),
        j("webp_row"),
        Op::Label("webp_done".into()),
    ]);
    // Evidence: `WEBPK <w>x<h>` at the written (clamped) geometry — the value
    // a screen capture can be checked against.
    puts(&mut ops, "WEBPK ");
    ops.push(mv(T0, S1));
    put_hex(&mut ops, "webp_hexw");
    putc(&mut ops, i64::from(b'x'));
    ops.push(mv(T0, S2));
    put_hex(&mut ops, "webp_hexh");
    putc(&mut ops, i64::from(b'\n'));
    // Latch + persist stamp + quiet the text-face rasterizer.
    ops.extend([
        la(T6, Addr::UartLine),
        li(T0, 1),
        sw(T0, T6, WEB_STAMPED_OFF),
    ]);
    if has_cap {
        ops.extend([
            la(T6, Addr::UiCap),
            li(T0, i64::from(UI_CAP_MAGIC)),
            sw(T0, T6, 0),
            li(T0, i64::from(UI_CAP_FLAG_WEB | UI_CAP_FLAG_PK)),
            sw(T0, T6, UI_CAP_OFF_FLAGS),
            la(T5, Addr::WebPk),
            lw(T0, T5, 12),
            sw(T0, T6, UI_CAP_OFF_NODES),
            li(T0, 1),
            sw(T0, T6, UI_CAP_OFF_NTILE),
            // One wipe tile = the whole latched output (TRANSFER with
            // backing offset 0 cannot express a strided subrect).
            la(T5, Addr::VioBss),
            lw(T1, T5, DISP_SEL_W),
            lw(T2, T5, DISP_SEL_H),
            addi(T6, T6, UI_CAP_OFF_RECTS),
            sw(X0, T6, 0),
            sw(X0, T6, 4),
            sw(T1, T6, 8),
            sw(T2, T6, 12),
        ]);
    }
    ops.extend([
        // The packed/injected scene owns the surface: clear the header
        // watermark and every node's F_DIRTY so a later dirty DOM (listeners,
        // cell mutations) neither overlays text glyphs on the canvas nor
        // re-arms the timer rung forever (a live `WebBlit` must leave the
        // tick clean — the `webp_live` early return lands here too).
        Op::Label("webp_live".into()),
    ]);
    if has_dom {
        ops.extend([
            la(T6, Addr::DomT),
            sw(X0, T6, H_DIRTY),
            li(T2, DOMT_NODES),
            addi(T6, T6, DOMT_HDR as i32),
            Op::Label("webp_clr".into()),
            lw(T1, T6, N_FLAGS),
            Op::Andi {
                rd: T1,
                rs: T1,
                imm: !F_DIRTY as i32,
            },
            sw(T1, T6, N_FLAGS),
            addi(T6, T6, DOMT_NODE as i32),
            addi(T2, T2, -1),
            bne(T2, X0, "webp_clr"),
        ]);
    }
    ops.extend([
        li(A0, 1),
        j("webp_out"),
        Op::Label("webp_absent".into()),
        li(A0, 0),
        Op::Label("webp_out".into()),
        ld_x(xlen, S4, SP, 0),
        ld_x(xlen, S3, SP, 8),
        ld_x(xlen, S2, SP, 16),
        ld_x(xlen, S1, SP, 24),
        ld_x(xlen, S0, SP, 32),
        ld_x(xlen, RA, SP, 40),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: 48,
        },
        ret(),
    ]);
    Node {
        purpose: Purpose::UiDom,
        ops,
    }
}

/// Guest web-present routines (`WebBlit`), attached under `guest_jit` like
/// the `domt` set. The `__web_pk` payload itself is installed by `g6b-elf`
/// (`g6b_kernel::web_pk_pack`) — a build without the LDC cell gets `__web_pk`
/// aliased onto `boot_log` (non-magic) and `WebBlit` falls through to `a0=0`.
pub fn nodes(spec: &BoardSpec) -> Vec<Node> {
    vec![web_blit_node(spec)]
}
