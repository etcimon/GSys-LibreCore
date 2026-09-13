// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Packed display list (`__web_dl`) — the same host-rendered `BrowserSession`
// scene as `__web_pk`, but carried as an *operation stream* + glyph atlas the
// guest `DlPaint` replays into the `__disp`-latched scanout surface. This is
// the goosie `PaintCommand` boundary packed for the guest: layout and the
// cascade ran host-side (`g6b_kernel::dl_pack`); what ships is a bounded op
// vocabulary — fills, rounded fills/strokes, coverage blits, raw-pixel
// relief — plus the tables that make the list live: per-menu state lists,
// `TEXTREF` anchors (id-keyed text the guest re-rasterizes from `__dom`),
// and the hit boxes pointer/keys dispatch against (stage 3).
//
// ```text
// +0   u32  magic 'G6DL' (WEB_DL_MAGIC)
// +4   u32  canvas w (pixels)          +8   u32  canvas h
// +12  u32  n_state                    +16  u32  n_tref
// +20  u32  n_size                     +24  u32  n_glyph
// +28  u32  n_blob                     +32  u32  n_hit
// +36  u32  state_off                  +40  u32  tref_off
// +44  u32  size_off                   +48  u32  glyph_off
// +52  u32  blobtab_off                +56  u32  hit_off
// +60  u32  str_off                    +64  u32  str_len
// +68  u32  blobdata_off
// ```
//
// All offsets are absolute byte offsets from `__web_dl`. Tables:
//
// ```text
// state 16B: {name[8] NUL-padded, off, len}        — off → op stream
// tref  56B: {cx,cy,cw,ch, pen_x,base_y,max_w, size_idx, fg,bg,
//             id_off,id_len, txt_off,txt_len}
// size   4B: {px_x8}
// glyph 24B: {code, size_idx, blob_idx, mx:i32, my:i32, adv_x64}
// blob  16B: {off, w, h, len}                      — off → coverage bytes
// hit   24B: {id_off, id_len, x, y, w, h}
// ```
//
// Op stream — u32 opcode + u32 args, paint order:
//
// ```text
// 0 END                               1 FILL  {x,y,w,h,c}
// 2 FILLR {x,y,w,h,r,c}               3 STRKR {x,y,w,h,r,bw,c}
// 4 COV   {x,y,blob_idx,c}            5 TILEPX{x,y,w,h} + webp RLE stream
// 6 TREF  {tref_idx}
// ```
//
// `c` is the RGBA word (R<<24|G<<16|B<<8|A); pixels land as B8G8R8X8 in the
// latched surface, like `WebBlit`. `TILEPX` carries the webp token format
// (run / literal, row-bounded, no terminator — `w*h` pixels exactly) for
// pixels the op vocabulary cannot express (shadow blur, image blits) — the
// packer's host replay+diff guarantees the stream is pixel-exact.
//
// `DlPaint` answers `a0`: `1` = a web canvas is live on the surface (DL just
// painted, or was already live with the requested state), `0` = no
// `__web_dl` installed / malformed / no output latched — the caller then
// falls through to `WebBlit` (the pixel pack remains the fallback).
//
// `WebPaint` is the composite call sites use: `DlPaint` first, `WebBlit`
// when it reports no list — one ownership contract for both carries.

#![allow(missing_docs)]

use g6b_spec::BoardSpec;

use crate::domt::{
    DOMT_HDR, DOMT_NODE, DOMT_NODES, F_DIRTY, H_DIRTY, H_DLS, H_WST, NONE, N_FLAGS, N_TLEN, N_TPTR,
};
use crate::encode::{
    A0, A1, A2, A6, A7, RA, S0, S1, S10, S11, S2, S3, S4, S5, S6, S7, S8, S9, SBI_PUTCHAR, SP, T0,
    T1, T2, T3, T4, T5, T6, X0,
};
use crate::vio::{
    DISP_SEL_FB_HI, DISP_SEL_FB_LO, DISP_SEL_H, DISP_SEL_STRIDE, DISP_SEL_W, UI_CAP_FLAG_PK,
    UI_CAP_FLAG_WEB, UI_CAP_MAGIC, UI_CAP_OFF_FLAGS, UI_CAP_OFF_NODES, UI_CAP_OFF_NTILE,
    UI_CAP_OFF_RECTS,
};
use crate::{Addr, Node, Op, Purpose, WEB_STAMPED_OFF};

/// `__web_dl+0` — 'G6DL'.
pub const WEB_DL_MAGIC: u32 = u32::from_le_bytes(*b"G6DL");
/// Header bytes before the offset table ends.
pub const WEB_DL_HDR: i32 = 72;
/// `__web_dl` byte ceiling — same `.rodata` budget as `__web_pk`.
pub const WEB_DL_MAX_BYTES: usize = 0x10_0000;

// Header field offsets (u32 words at fixed byte offsets).
pub const DL_OFF_W: i32 = 4;
pub const DL_OFF_H: i32 = 8;
pub const DL_OFF_NSTATE: i32 = 12;
pub const DL_OFF_NTREF: i32 = 16;
pub const DL_OFF_NSIZE: i32 = 20;
pub const DL_OFF_NGLYPH: i32 = 24;
pub const DL_OFF_NBLOB: i32 = 28;
pub const DL_OFF_NHIT: i32 = 32;
pub const DL_OFF_STATE: i32 = 36;
pub const DL_OFF_TREF: i32 = 40;
pub const DL_OFF_SIZE: i32 = 44;
pub const DL_OFF_GLYPH: i32 = 48;
pub const DL_OFF_BLOBTAB: i32 = 52;
pub const DL_OFF_HIT: i32 = 56;
pub const DL_OFF_STR: i32 = 60;

// Record strides (bytes).
pub const DL_STATE_REC: i32 = 16;
pub const DL_TREF_REC: i32 = 56;
pub const DL_GLYPH_REC: i32 = 24;
pub const DL_BLOB_REC: i32 = 16;
pub const DL_HIT_REC: i32 = 24;

// Op words.
pub const DLOP_END: i64 = 0;
pub const DLOP_FILL: i64 = 1;
pub const DLOP_FILLR: i64 = 2;
pub const DLOP_STRKR: i64 = 3;
pub const DLOP_COV: i64 = 4;
pub const DLOP_TILEPX: i64 = 5;
pub const DLOP_TREF: i64 = 6;

/// `blob_idx` value for a glyph with no coverage (space) — skip the blit.
pub const DL_BLOB_NONE: i64 = -1;
/// Bounded `TEXTREF` character walk (a live `textContent` can be long; the
/// pack keeps the packed-text fallback under the same bound).
pub const DL_TREF_MAX_CHARS: i64 = 96;

// DlPaint frame scratch slots (below the saved s-regs at +72). The three
// pointer slots (`SC_TXP`, `SC_M0`, `SC_CUR`) are 8-BYTE slots — `sd`/`ld`
// pairs — so each must own its full 8 bytes: a 4-byte neighbour inside the
// range would corrupt the pointer's high word (a `0x8xxxxxxx` guest address
// sign-extended once faulted the whole paint).
const SC_STATE: i32 = 68; // selected state index (for H_DLS)
const SC_CNT: i32 = 64; // loop counter
const SC_YY: i32 = 60; // loop row
const SC_XX: i32 = 56; // loop column
const SC_CUR: i32 = 48; // dst pixel cursor            — 8B slot @48..55
const SC_M0: i32 = 40; // misc (cov ptr / adv)         — 8B slot @40..47
const SC_TXP: i32 = 32; // tref text pointer          — 8B slot @32..39
const SC_TXL: i32 = 28; // tref text length
const SC_PEN: i32 = 4; // tref pen x, 1/64 px
const SC_M1: i32 = 0; // misc2

fn lw(rd: u32, rs: u32, off: i32) -> Op {
    Op::Lw { rd, rs, off }
}
fn sw(rs2: u32, rs1: u32, off: i32) -> Op {
    Op::Sw { rs2, rs1, off }
}
fn lbu(rd: u32, rs: u32, off: i32) -> Op {
    Op::Lbu { rd, rs, off }
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
fn andi(rd: u32, rs: u32, imm: i32) -> Op {
    Op::Andi { rd, rs, imm }
}
fn slli(rd: u32, rs: u32, shamt: u32) -> Op {
    Op::Slli { rd, rs, shamt }
}
fn srli(rd: u32, rs: u32, shamt: u32) -> Op {
    Op::Srli { rd, rs, shamt }
}
fn srai(rd: u32, rs: u32, shamt: u32) -> Op {
    Op::Srai { rd, rs, shamt }
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
fn mul(rd: u32, a: u32, b: u32) -> Op {
    Op::Mul { rd, rs1: a, rs2: b }
}
fn divu(rd: u32, a: u32, b: u32) -> Op {
    Op::Divu { rd, rs1: a, rs2: b }
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
fn blt(a: u32, b: u32, to: &str) -> Op {
    Op::Blt {
        rs1: a,
        rs2: b,
        to: to.into(),
    }
}
fn bge(a: u32, b: u32, to: &str) -> Op {
    Op::Bge {
        rs1: a,
        rs2: b,
        to: to.into(),
    }
}
fn bltu(a: u32, b: u32, to: &str) -> Op {
    Op::Bltu {
        rs1: a,
        rs2: b,
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
fn call(to: &str) -> Op {
    Op::Jal {
        rd: RA,
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
        andi(T2, T2, 0xf),
        slli(T0, T0, 4),
        la(A6, Addr::Label("hexdig".into())),
        add(A6, A6, T2),
        lbu(A0, A6, 0),
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
/// Scratch-slot store for slots that hold POINTERS (`SC_CUR`, `SC_TXP`,
/// `SC_M0`): a `sw`+`lw` pair would truncate to 32 bits and sign-extend on
/// RV64, turning a `0x8xxxxxxx` guest address into a faulting pointer.
fn st_p(xlen: u32, rs2: u32, rs1: u32, off: i32) -> Op {
    st_x(xlen, rs2, rs1, off)
}
fn ld_p(xlen: u32, rd: u32, rs: u32, off: i32) -> Op {
    ld_x(xlen, rd, rs, off)
}

// ---------------------------------------------------------------------------
// DlPaint — the op-stream interpreter.
//
// Register plan (saved s-regs): S0 dst fb base · S1 op cursor · S2 `__web_dl`
// base · S3 stride bytes · S4 clip w · S5 clip h · S6..S9 op rect → clipped
// x0,y0,x1,y1 · S10 op colour/store word · S11 op extra (trec/blob rec ptr).
// Mutable loop state lives in the SC_* frame slots so the leaf helpers
// (`DlBlendPx`, `DlFillRect`, `DlFindId`) can clobber every t/a register.
// ---------------------------------------------------------------------------

/// Emit the opaque-fill row loop for the current clip (s6..s9 = x0,y0,x1,y1,
/// s10 = store word). Ends with `j {cont}` at `{pfx}_done`.
fn emit_opaque_fill(ops: &mut Vec<Op>, xlen: u32, pfx: &str, cont: &str) {
    ops.extend([
        mul(T0, S7, S3),
        add(T0, T0, S0),
        slli(T1, S6, 2),
        add(T0, T0, T1),
        st_p(xlen, T0, SP, SC_CUR),
        sw(S7, SP, SC_YY),
        Op::Label(format!("{pfx}_row")),
        lw(T1, SP, SC_YY),
        bge(T1, S9, &format!("{pfx}_done")),
        ld_p(xlen, T2, SP, SC_CUR),
        sub(T3, S8, S6),
        Op::Label(format!("{pfx}_px")),
        sw(S10, T2, 0),
        addi(T2, T2, 4),
        addi(T3, T3, -1),
        bne(T3, X0, &format!("{pfx}_px")),
        lw(T1, SP, SC_YY),
        addi(T1, T1, 1),
        sw(T1, SP, SC_YY),
        ld_p(xlen, T2, SP, SC_CUR),
        add(T2, T2, S3),
        st_p(xlen, T2, SP, SC_CUR),
        j(&format!("{pfx}_row")),
        Op::Label(format!("{pfx}_done")),
        j(cont),
    ]);
}

/// Emit an inline corner-square fill. The square is `[S6,S7)` of side `S11`
/// (the op's radius); a pixel is painted with `S10` when its distance² from
/// the circle centre `(S8,S9)` satisfies `dist² <= SC_M0` (r²) — or, for a
/// stroke ring, `SC_M1 < dist² <= SC_M0` (ir² < dist² <= r²). This is exactly
/// the corner quadrant of `inside_rounded`: outside the square `cx`/`cy` is
/// zero so the straight band is a solid span the caller fills separately.
/// Inline (no frame): `SC_XX`/`SC_YY` carry the cursor across `DlBlendPx`.
fn emit_corner_sq(ops: &mut Vec<Op>, xlen: u32, pfx: &str, ring: bool) {
    let _ = xlen;
    ops.extend([
        sw(S7, SP, SC_YY),
        Op::Label(format!("{pfx}_row")),
        lw(T0, SP, SC_YY),
        add(T1, S7, S11),
        bge(T0, T1, &format!("{pfx}_done")),
        sw(S6, SP, SC_XX),
        Op::Label(format!("{pfx}_px")),
        lw(T0, SP, SC_XX),
        add(T1, S6, S11),
        bge(T0, T1, &format!("{pfx}_eol")),
        // canvas bounds (off-screen pixels skip without faulting).
        blt(T0, X0, &format!("{pfx}_next")),
        bge(T0, S4, &format!("{pfx}_next")),
        lw(T1, SP, SC_YY),
        blt(T1, X0, &format!("{pfx}_next")),
        bge(T1, S5, &format!("{pfx}_next")),
        // dist² = (xx-ccx)² + (yy-ccy)²  (T0=xx, T1=yy)
        sub(T2, T0, S8),
        mul(T2, T2, T2),
        sub(T3, T1, S9),
        mul(T3, T3, T3),
        add(T2, T2, T3),
        lw(T4, SP, SC_M0), // r²
        blt(T4, T2, &format!("{pfx}_next")),
    ]);
    if ring {
        ops.extend([
            lw(T4, SP, SC_M1), // ir²
            bge(T4, T2, &format!("{pfx}_next")),
        ]);
    }
    ops.extend([
        mul(T1, T1, S3),
        add(T1, T1, S0),
        slli(T2, T0, 2),
        add(A2, T1, T2),
        mv(A0, S10),
        li(A1, 255),
        call("DlBlendPx"),
        Op::Label(format!("{pfx}_next")),
        lw(T0, SP, SC_XX),
        addi(T0, T0, 1),
        sw(T0, SP, SC_XX),
        j(&format!("{pfx}_px")),
        Op::Label(format!("{pfx}_eol")),
        lw(T0, SP, SC_YY),
        addi(T0, T0, 1),
        sw(T0, SP, SC_YY),
        j(&format!("{pfx}_row")),
        Op::Label(format!("{pfx}_done")),
    ]);
}

/// Emit the per-px "store T2 if (xx=T3, yy=T4) is inside the clip" body used
/// by the TILEPX decoder (T3/T4 scratch, T5/T6 clobbered).
fn emit_tp_store(ops: &mut Vec<Op>, skip: &str) {
    ops.extend([
        blt(T3, X0, skip),
        bge(T3, S4, skip),
        blt(T4, X0, skip),
        bge(T4, S5, skip),
        mul(T5, T4, S3),
        add(T5, T5, S0),
        slli(T6, T3, 2),
        add(T5, T5, T6),
        sw(T2, T5, 0),
        Op::Label(skip.into()),
    ]);
}

fn dl_paint_node(spec: &BoardSpec) -> Node {
    let xlen = spec.isa.xlen;
    let has_vio = spec.wants_virtio_gpu()
        || spec.wants_virtio_net()
        || spec.wants_disp_scan()
        || spec.kernel.gr.enable
        || spec.kernel.proxy.enable;
    let has_cap = spec.wants_virtio_gpu() || spec.wants_disp_scan();
    let has_dom = spec.kernel.wasm.guest_jit;
    let mut ops = vec![
        Op::Comment(
            "DlPaint — replay __web_dl (op stream + atlas) into the latched \
             surface; a0=1 when a web canvas is live, 0 → caller's WebBlit"
                .into(),
        ),
        Op::Glob("DlPaint".into()),
        Op::Label("DlPaint".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -176,
        },
        st_x(xlen, RA, SP, 168),
        st_x(xlen, S0, SP, 160),
        st_x(xlen, S1, SP, 152),
        st_x(xlen, S2, SP, 144),
        st_x(xlen, S3, SP, 136),
        st_x(xlen, S4, SP, 128),
        st_x(xlen, S5, SP, 120),
        st_x(xlen, S6, SP, 112),
        st_x(xlen, S7, SP, 104),
        st_x(xlen, S8, SP, 96),
        st_x(xlen, S9, SP, 88),
        st_x(xlen, S10, SP, 80),
        st_x(xlen, S11, SP, 72),
    ];
    // ---- live check: a canvas already owns the surface *and* shows the
    // requested state. `UI_CAP_FLAG_PK` is the ownership bit (same contract
    // as `WebBlit`); `H_DLS`/`H_WST` in the `__dom` header track which
    // `__web_dl` state was painted vs requested (the `__uart_line` map is
    // full). A mismatch repaints the new state over the old canvas.
    if has_cap {
        ops.extend([
            la(T6, Addr::UiCap),
            lw(T0, T6, 0),
            li(T1, i64::from(UI_CAP_MAGIC)),
            bne(T0, T1, "dl_chk_lat"),
            lw(T0, T6, UI_CAP_OFF_FLAGS),
            andi(T0, T0, UI_CAP_FLAG_PK as i32),
            beq(T0, X0, "dl_chk_lat"),
        ]);
        if has_dom {
            ops.extend([
                la(T6, Addr::DomT),
                lw(T0, T6, H_DLS),
                lw(T1, T6, H_WST),
                beq(T0, T1, "dl_live"),
                Op::Label("dl_chk_lat".into()),
            ]);
        } else {
            ops.extend([j("dl_live"), Op::Label("dl_chk_lat".into())]);
        }
    }
    ops.extend([
        la(T6, Addr::UartLine),
        lw(T0, T6, WEB_STAMPED_OFF),
        beq(T0, X0, "dl_fresh"),
    ]);
    if has_dom {
        ops.extend([
            la(T6, Addr::DomT),
            lw(T0, T6, H_DLS),
            lw(T1, T6, H_WST),
            beq(T0, T1, "dl_live"),
        ]);
    } else {
        ops.push(j("dl_live"));
    }
    ops.extend([
        // ---- list present? `__web_dl` reads a non-magic word when none was
        // installed (aliases `boot_log`) → a0=0 → the caller's WebBlit.
        Op::Label("dl_fresh".into()),
        la(S2, Addr::WebDl),
        la(S2, Addr::WebDl),
        lw(T0, S2, 0),
        li(T1, i64::from(WEB_DL_MAGIC)),
        bne(T0, T1, "dl_absent"),
        lw(T0, S2, DL_OFF_NSTATE),
        beq(T0, X0, "dl_absent"),
    ]);
    // ---- state select: `__dom+H_WST` (fail-closed to 0 when out of range).
    if has_dom {
        ops.extend([
            la(T6, Addr::DomT),
            lw(T0, T6, H_WST),
            lw(T1, S2, DL_OFF_NSTATE),
            bltu(T0, T1, "dl_st_ok"),
            li(T0, 0),
            Op::Label("dl_st_ok".into()),
            sw(T0, SP, SC_STATE),
        ]);
    } else {
        ops.extend([li(T0, 0), sw(T0, SP, SC_STATE)]);
    }
    ops.extend([
        // stream = dl + state[state].off
        lw(T1, S2, DL_OFF_STATE),
        add(T1, T1, S2),
        li(T2, DL_STATE_REC as i64),
        mul(T3, T0, T2),
        add(T1, T1, T3),
        lw(S1, T1, 8),
        add(S1, S1, S2),
    ]);
    // ---- geometry latch (same contract as `WebBlit`).
    if has_vio {
        ops.extend([
            la(T6, Addr::VioBss),
            lw(T0, T6, DISP_SEL_W),
            beq(T0, X0, "dl_absent"),
            lw(T1, T6, DISP_SEL_H),
            beq(T1, X0, "dl_absent"),
            lw(S4, S2, DL_OFF_W),
            lw(S5, S2, DL_OFF_H),
            bgeu(T0, S4, "dl_w_ok"),
            mv(S4, T0),
            Op::Label("dl_w_ok".into()),
            bgeu(T1, S5, "dl_h_ok"),
            mv(S5, T1),
            Op::Label("dl_h_ok".into()),
            lw(S3, T6, DISP_SEL_STRIDE),
            lw(T0, T6, DISP_SEL_FB_LO),
            lw(T1, T6, DISP_SEL_FB_HI),
            slli(T1, T1, 32),
            or_(T0, T0, T1),
            bne(T0, X0, "dl_havefb"),
            la(T0, Addr::ScanFb),
            Op::Label("dl_havefb".into()),
            mv(S0, T0),
        ]);
    } else {
        ops.extend([
            lw(S4, S2, DL_OFF_W),
            lw(S5, S2, DL_OFF_H),
            la(S0, Addr::ScanFb),
            slli(T0, S4, 2),
            mv(S3, T0),
        ]);
    }
    ops.extend([
        beq(S4, X0, "dl_absent"),
        beq(S5, X0, "dl_absent"),
        // ================= op-walk loop =================
        Op::Label("dl_op".into()),
        lw(T0, S1, 0),
        beq(T0, X0, "dl_done"),
        li(T1, DLOP_FILL),
        beq(T0, T1, "dl_fill"),
        li(T1, DLOP_FILLR),
        beq(T0, T1, "dl_fillr"),
        li(T1, DLOP_STRKR),
        beq(T0, T1, "dl_strkr"),
        li(T1, DLOP_COV),
        beq(T0, T1, "dl_cov"),
        li(T1, DLOP_TILEPX),
        beq(T0, T1, "dl_tilepx"),
        li(T1, DLOP_TREF),
        beq(T0, T1, "dl_tref"),
        // Unknown op word: fail closed like END (bounded, never a wild read).
        j("dl_done"),
    ]);
    // ---------------- FILL {x,y,w,h,c} ----------------
    ops.extend([
        Op::Label("dl_fill".into()),
        lw(S6, S1, 4),
        lw(S7, S1, 8),
        lw(S8, S1, 12),
        lw(S9, S1, 16),
        lw(S10, S1, 20),
        call("dl_clip"),
        beq(A0, X0, "dl_fill_out"),
        andi(T0, S10, 0xff),
        li(T1, 255),
        bne(T0, T1, "dl_fill_b"),
        // opaque: store word = 0xFF00_0000 | c>>8
        srli(T0, S10, 8),
        li(T1, 0xFF00_0000),
        or_(S10, T0, T1),
    ]);
    emit_opaque_fill(&mut ops, xlen, "dlfo", "dl_fill_out");
    ops.extend([
        // a<255: per-px DlBlendPx
        Op::Label("dl_fill_b".into()),
        mul(T0, S7, S3),
        add(T0, T0, S0),
        slli(T1, S6, 2),
        add(T0, T0, T1),
        st_p(xlen, T0, SP, SC_CUR),
        sw(S7, SP, SC_YY),
        Op::Label("dlfi_row".into()),
        lw(T1, SP, SC_YY),
        bge(T1, S9, "dl_fill_out"),
        ld_p(xlen, T2, SP, SC_CUR),
        st_p(xlen, T2, SP, SC_M0),
        sub(T3, S8, S6),
        sw(T3, SP, SC_CNT),
        Op::Label("dlfi_px".into()),
        lw(T3, SP, SC_CNT),
        beq(T3, X0, "dlfi_eol"),
        ld_p(xlen, A2, SP, SC_M0),
        mv(A0, S10),
        li(A1, 255),
        call("DlBlendPx"),
        ld_p(xlen, T2, SP, SC_M0),
        addi(T2, T2, 4),
        st_p(xlen, T2, SP, SC_M0),
        lw(T3, SP, SC_CNT),
        addi(T3, T3, -1),
        sw(T3, SP, SC_CNT),
        j("dlfi_px"),
        Op::Label("dlfi_eol".into()),
        lw(T1, SP, SC_YY),
        addi(T1, T1, 1),
        sw(T1, SP, SC_YY),
        ld_p(xlen, T2, SP, SC_CUR),
        add(T2, T2, S3),
        st_p(xlen, T2, SP, SC_CUR),
        j("dlfi_row"),
        Op::Label("dl_fill_out".into()),
        addi(S1, S1, 24),
        j("dl_op"),
    ]);
    // ---------------- FILLR {x,y,w,h,r,c} ----------------
    // Decompose the rounded fill into the spans `inside_rounded` always
    // includes (the straight band, painted as solid rects) plus the four
    // r×r corner squares that need the circle test. This keeps the per-px
    // `DlBlendPx` work to the corners instead of the whole bbox.
    ops.extend([
        Op::Label("dl_fillr".into()),
        lw(S10, S1, 24), // c
        lw(S11, S1, 20), // r
        mul(T0, S11, S11),
        sw(T0, SP, SC_M0), // r²
        // R1 middle band {x, y+r, w, h-2r}
        lw(S6, S1, 4),
        lw(T0, S1, 8),
        add(S7, T0, S11),
        lw(S8, S1, 12),
        lw(T0, S1, 16),
        slli(T1, S11, 1),
        sub(S9, T0, T1),
        call("dl_clip"),
        beq(A0, X0, "dflr_r1x"),
        call("DlFillRect"),
        Op::Label("dflr_r1x".into()),
        // R2 top band middle {x+r, y, w-2r, r}
        lw(T0, S1, 4),
        add(S6, T0, S11),
        lw(S7, S1, 8),
        lw(T0, S1, 12),
        slli(T1, S11, 1),
        sub(S8, T0, T1),
        mv(S9, S11),
        call("dl_clip"),
        beq(A0, X0, "dflr_r2x"),
        call("DlFillRect"),
        Op::Label("dflr_r2x".into()),
        // R3 bottom band middle {x+r, y+h-r, w-2r, r}
        lw(T0, S1, 4),
        add(S6, T0, S11),
        lw(T0, S1, 8),
        lw(T1, S1, 16),
        add(T0, T0, T1),
        sub(S7, T0, S11),
        lw(T0, S1, 12),
        slli(T1, S11, 1),
        sub(S8, T0, T1),
        mv(S9, S11),
        call("dl_clip"),
        beq(A0, X0, "dflr_r3x"),
        call("DlFillRect"),
        Op::Label("dflr_r3x".into()),
        // TL corner {x,y}, centre (x+r, y+r)
        lw(T0, S1, 4),
        add(S8, T0, S11),
        lw(T2, S1, 8),
        add(S9, T2, S11),
        mv(S6, T0),
        mv(S7, T2),
    ]);
    emit_corner_sq(&mut ops, xlen, "dflr_tl", false);
    ops.extend([
        // TR corner {x+w-r,y}, centre (x+w-r-1, y+r)
        lw(T0, S1, 4),
        lw(T2, S1, 12),
        add(T0, T0, T2),
        sub(T0, T0, S11),
        mv(S6, T0),
        addi(S8, T0, -1),
        lw(T2, S1, 8),
        mv(S7, T2),
        add(S9, T2, S11),
    ]);
    emit_corner_sq(&mut ops, xlen, "dflr_tr", false);
    ops.extend([
        // BL corner {x,y+h-r}, centre (x+r, y+h-r-1)
        lw(T0, S1, 4),
        mv(S6, T0),
        add(S8, T0, S11),
        lw(T0, S1, 8),
        lw(T2, S1, 16),
        add(T0, T0, T2),
        sub(T0, T0, S11),
        mv(S7, T0),
        addi(S9, T0, -1),
    ]);
    emit_corner_sq(&mut ops, xlen, "dflr_bl", false);
    ops.extend([
        // BR corner {x+w-r,y+h-r}, centre (x+w-r-1, y+h-r-1)
        lw(T0, S1, 4),
        lw(T2, S1, 12),
        add(T0, T0, T2),
        sub(T0, T0, S11),
        mv(S6, T0),
        addi(S8, T0, -1),
        lw(T0, S1, 8),
        lw(T2, S1, 16),
        add(T0, T0, T2),
        sub(T0, T0, S11),
        mv(S7, T0),
        addi(S9, T0, -1),
    ]);
    emit_corner_sq(&mut ops, xlen, "dflr_br", false);
    ops.extend([
        Op::Label("dl_fillr_out".into()),
        addi(S1, S1, 28),
        j("dl_op"),
    ]);
    // ---------------- STRKR {x,y,w,h,r,bw,c} ----------------
    // `stroke_rounded_rect` paints `inside outer && !inside inner`. Inside
    // the inner rect's straight band `cy==0`/`cx==0` makes `inside_inner`
    // true, so the straight edges are *not* painted — only the four corner
    // squares hold ring pixels (`ir² < dist² <= r²`). Paint just those.
    ops.extend([
        Op::Label("dl_strkr".into()),
        lw(S10, S1, 28), // c
        lw(S11, S1, 20), // r
        mul(T0, S11, S11),
        sw(T0, SP, SC_M0), // r²
        lw(T0, S1, 20),    // r
        lw(T1, S1, 24),    // bw
        sub(T0, T0, T1),   // r-bw
        bge(T0, X0, "dlsk_ir"),
        li(T0, 0),
        Op::Label("dlsk_ir".into()),
        mul(T0, T0, T0),
        sw(T0, SP, SC_M1), // ir²
        // TL corner
        lw(T0, S1, 4),
        add(S8, T0, S11),
        lw(T2, S1, 8),
        add(S9, T2, S11),
        mv(S6, T0),
        mv(S7, T2),
    ]);
    emit_corner_sq(&mut ops, xlen, "dlsk_tl", true);
    ops.extend([
        // TR corner
        lw(T0, S1, 4),
        lw(T2, S1, 12),
        add(T0, T0, T2),
        sub(T0, T0, S11),
        mv(S6, T0),
        addi(S8, T0, -1),
        lw(T2, S1, 8),
        mv(S7, T2),
        add(S9, T2, S11),
    ]);
    emit_corner_sq(&mut ops, xlen, "dlsk_tr", true);
    ops.extend([
        // BL corner
        lw(T0, S1, 4),
        mv(S6, T0),
        add(S8, T0, S11),
        lw(T0, S1, 8),
        lw(T2, S1, 16),
        add(T0, T0, T2),
        sub(T0, T0, S11),
        mv(S7, T0),
        addi(S9, T0, -1),
    ]);
    emit_corner_sq(&mut ops, xlen, "dlsk_bl", true);
    ops.extend([
        // BR corner
        lw(T0, S1, 4),
        lw(T2, S1, 12),
        add(T0, T0, T2),
        sub(T0, T0, S11),
        mv(S6, T0),
        addi(S8, T0, -1),
        lw(T0, S1, 8),
        lw(T2, S1, 16),
        add(T0, T0, T2),
        sub(T0, T0, S11),
        mv(S7, T0),
        addi(S9, T0, -1),
    ]);
    emit_corner_sq(&mut ops, xlen, "dlsk_br", true);
    ops.extend([
        Op::Label("dl_strkr_out".into()),
        addi(S1, S1, 32),
        j("dl_op"),
    ]);
    // ---------------- COV {x,y,blob_idx,c} ----------------
    ops.extend([
        Op::Label("dl_cov".into()),
        lw(S6, S1, 4),
        lw(S7, S1, 8),
        lw(S8, S1, 12),
        lw(S10, S1, 16),
        // S11 = blob rec ptr
        lw(T0, S2, DL_OFF_BLOBTAB),
        add(T0, T0, S2),
        li(T1, DL_BLOB_REC as i64),
        mul(T2, S8, T1),
        add(S11, T0, T2),
        lw(T0, S11, 0),
        add(T0, T0, S2),
        st_p(xlen, T0, SP, SC_M0), // cov ptr
        sw(X0, SP, SC_YY),
        Op::Label("dlcv_row".into()),
        lw(T0, SP, SC_YY),
        lw(T1, S11, 8), // bh
        bge(T0, T1, "dl_cov_out"),
        sw(X0, SP, SC_XX),
        Op::Label("dlcv_px".into()),
        lw(T0, SP, SC_XX),
        lw(T1, S11, 4), // bw
        bge(T0, T1, "dlcv_eol"),
        // cov = covptr[row*bw + col]
        ld_p(xlen, T2, SP, SC_M0),
        lw(T3, SP, SC_YY),
        mul(T3, T3, T1),
        add(T2, T2, T3),
        add(T2, T2, T0),
        lbu(A1, T2, 0),
        beq(A1, X0, "dlcv_next"),
        // px bounds: xx = S6+col, yy = S7+row
        add(T3, S6, T0),
        lw(T4, SP, SC_YY),
        add(T4, S7, T4),
        blt(T3, X0, "dlcv_next"),
        bge(T3, S4, "dlcv_next"),
        blt(T4, X0, "dlcv_next"),
        bge(T4, S5, "dlcv_next"),
        mul(T5, T4, S3),
        add(T5, T5, S0),
        slli(T6, T3, 2),
        add(A2, T5, T6),
        mv(A0, S10),
        call("DlBlendPx"),
        Op::Label("dlcv_next".into()),
        lw(T0, SP, SC_XX),
        addi(T0, T0, 1),
        sw(T0, SP, SC_XX),
        j("dlcv_px"),
        Op::Label("dlcv_eol".into()),
        lw(T0, SP, SC_YY),
        addi(T0, T0, 1),
        sw(T0, SP, SC_YY),
        j("dlcv_row"),
        Op::Label("dl_cov_out".into()),
        addi(S1, S1, 20),
        j("dl_op"),
    ]);
    // ---------------- TILEPX {x,y,w,h} + RLE stream ----------------
    ops.extend([
        Op::Label("dl_tilepx".into()),
        lw(S6, S1, 4),
        lw(S7, S1, 8),
        lw(S8, S1, 12),
        lw(S9, S1, 16),
        addi(S1, S1, 20), // token cursor
        sw(X0, SP, SC_YY),
        Op::Label("dltp_row".into()),
        lw(T0, SP, SC_YY),
        bge(T0, S9, "dl_op"), // h rows consumed → next op
        sw(X0, SP, SC_XX),
        Op::Label("dltp_tok".into()),
        lw(T0, SP, SC_XX),
        bge(T0, S8, "dltp_eol"),
        lw(T1, S1, 0),
        addi(S1, S1, 4),
        beq(T1, X0, "dl_done"), // early 0 → fail closed
        blt(T1, X0, "dltp_lit"),
        // RUN: T1 copies of the next word (clamped to the row remainder).
        lw(T2, S1, 0),
        addi(S1, S1, 4),
        lw(T0, SP, SC_XX),
        sub(T0, S8, T0), // row remainder
        bgeu(T0, T1, "dltp_run_n"),
        mv(T1, T0),
        Op::Label("dltp_run_n".into()),
        Op::Label("dltp_run".into()),
        lw(T3, SP, SC_XX),
        add(T3, S6, T3),
        lw(T4, SP, SC_YY),
        add(T4, S7, T4),
    ]);
    emit_tp_store(&mut ops, "dltp_run_s");
    ops.extend([
        lw(T3, SP, SC_XX),
        addi(T3, T3, 1),
        sw(T3, SP, SC_XX),
        addi(T1, T1, -1),
        bne(T1, X0, "dltp_run"),
        j("dltp_tok"),
        // LITERAL: xlen-aware count funnel (RV64 `lw` sign-extends the tag —
        // the same `xlen-31` funnel `webp_lit` uses).
        Op::Label("dltp_lit".into()),
        slli(T1, T1, xlen - 31),
        srli(T1, T1, xlen - 31),
        lw(T0, SP, SC_XX),
        sub(T0, S8, T0),
        bgeu(T0, T1, "dltp_lit_n"),
        mv(T1, T0),
        Op::Label("dltp_lit_n".into()),
        Op::Label("dltp_litc".into()),
        lw(T2, S1, 0),
        addi(S1, S1, 4),
        lw(T3, SP, SC_XX),
        add(T3, S6, T3),
        lw(T4, SP, SC_YY),
        add(T4, S7, T4),
    ]);
    emit_tp_store(&mut ops, "dltp_lit_s");
    ops.extend([
        lw(T3, SP, SC_XX),
        addi(T3, T3, 1),
        sw(T3, SP, SC_XX),
        addi(T1, T1, -1),
        bne(T1, X0, "dltp_litc"),
        j("dltp_tok"),
        Op::Label("dltp_eol".into()),
        lw(T0, SP, SC_YY),
        addi(T0, T0, 1),
        sw(T0, SP, SC_YY),
        j("dltp_row"),
    ]);
    // ---------------- TREF {tref_idx} ----------------
    ops.extend([
        Op::Label("dl_tref".into()),
        lw(T0, S1, 4),
        lw(T1, S2, DL_OFF_TREF),
        add(T1, T1, S2),
        li(T2, DL_TREF_REC as i64),
        mul(T3, T0, T2),
        add(S11, T1, T3), // S11 = trec ptr
        addi(S1, S1, 8),
        // ---- clear rect: opaque fill bg over {trec+0..15}
        lw(S6, S11, 0),
        lw(S7, S11, 4),
        lw(S8, S11, 8),
        lw(S9, S11, 12),
        call("dl_clip"),
        beq(A0, X0, "dl_tref_txt"),
        lw(S10, S11, 36), // bg word (already X8R8)
    ]);
    emit_opaque_fill(&mut ops, xlen, "dltr", "dl_tref_txt");
    ops.extend([
        // ---- text source: live `__dom` text when the id resolves, else the
        // packed fallback bytes. Rec string fields are *pool*-relative —
        // `str_off` rebases them into the image.
        Op::Label("dl_tref_txt".into()),
        lw(T1, S2, DL_OFF_STR),
        lw(T0, S11, 48),
        add(T0, T0, T1),
        add(T0, T0, S2),
        st_p(xlen, T0, SP, SC_TXP),
        lw(T0, S11, 52),
        sw(T0, SP, SC_TXL),
    ]);
    if has_dom {
        ops.extend([
            lw(A0, S11, 40),
            lw(T1, S2, DL_OFF_STR),
            add(A0, A0, T1),
            add(A0, A0, S2),
            lw(A1, S11, 44),
            call("DlFindId"),
            blt(A0, X0, "dl_tref_have"), // NONE → packed fallback
            la(T1, Addr::DomT),
            li(T2, DOMT_NODE),
            mul(T3, A0, T2),
            add(T1, T1, T3),
            addi(T1, T1, DOMT_HDR as i32),
            lw(T4, T1, N_TLEN),
            beq(T4, X0, "dl_tref_have"),
            lw(T5, T1, N_TPTR),
            la(T6, Addr::DomS),
            add(T5, T5, T6),
            st_p(xlen, T5, SP, SC_TXP),
            sw(T4, SP, SC_TXL),
        ]);
    }
    ops.extend([
        Op::Label("dl_tref_have".into()),
        // clamp len ≤ DL_TREF_MAX_CHARS
        lw(T0, SP, SC_TXL),
        li(T1, DL_TREF_MAX_CHARS),
        bge(T1, T0, "dl_tref_len"),
        sw(T1, SP, SC_TXL),
        Op::Label("dl_tref_len".into()),
        // pen = pen_x<<6
        lw(T0, S11, 16),
        slli(T0, T0, 6),
        sw(T0, SP, SC_PEN),
        sw(X0, SP, SC_XX),
        Op::Label("dl_tref_ch".into()),
        lw(T0, SP, SC_XX),
        lw(T1, SP, SC_TXL),
        bge(T0, T1, "dl_op"),
        ld_p(xlen, T2, SP, SC_TXP),
        add(T2, T2, T0),
        lbu(T2, T2, 0), // ch
        // glyph scan: match (code, size_idx)
        lw(T3, S2, DL_OFF_GLYPH),
        add(T3, T3, S2),
        lw(T4, S2, DL_OFF_NGLYPH),
        lw(T5, S11, 28), // size_idx
        li(T6, 0),
        Op::Label("dl_tref_gs".into()),
        bge(T6, T4, "dl_tref_adv"),
        li(T0, DL_GLYPH_REC as i64),
        mul(T0, T6, T0),
        add(T0, T0, T3),
        lw(T1, T0, 0),
        bne(T1, T2, "dl_tref_gn"),
        lw(T1, T0, 4),
        bne(T1, T5, "dl_tref_gn"),
        j("dl_tref_gf"),
        Op::Label("dl_tref_gn".into()),
        addi(T6, T6, 1),
        j("dl_tref_gs"),
        Op::Label("dl_tref_adv".into()),
        // not found → half-em advance (size's px_x8*4 in x64)
        lw(T0, S11, 28),
        slli(T0, T0, 2),
        lw(T1, S2, DL_OFF_SIZE),
        add(T1, T1, S2),
        add(T1, T1, T0),
        lw(T0, T1, 0),   // px_x8
        slli(T0, T0, 2), // half em in x64
        sw(T0, SP, SC_M0),
        j("dl_tref_pen"),
        Op::Label("dl_tref_gf".into()),
        // T0 = glyph rec {code,size,blob,mx,my,adv}
        lw(T1, T0, 20),
        sw(T1, SP, SC_M0), // adv_x64
        lw(T1, T0, 8),
        li(T2, DL_BLOB_NONE),
        beq(T1, T2, "dl_tref_pen"),
        // blob rec
        lw(T2, S2, DL_OFF_BLOBTAB),
        add(T2, T2, S2),
        li(T3, DL_BLOB_REC as i64),
        mul(T4, T1, T3),
        add(T2, T2, T4),
        // covptr → S8, bw → S9, x0 → S6, top → S7, fg → S10, bh → SC_M1
        lw(T3, T2, 0),
        add(S8, T3, S2),
        lw(S9, T2, 4),
        lw(T3, T2, 8),
        sw(T3, SP, SC_M1), // bh
        lw(T3, T0, 12),    // mx
        lw(T4, SP, SC_PEN),
        srai(T4, T4, 6),
        add(S6, T3, T4), // x0 = pen>>6 + mx
        lw(T4, T0, 16),  // my
        lw(T5, S11, 20), // base_y
        sub(T5, T5, T4),
        lw(T6, SP, SC_M1),
        addi(T6, T6, -1),
        sub(S7, T5, T6),  // top = base_y - my - (bh-1)
        lw(S10, S11, 32), // fg
        // cov walk: SC_YY=row, SC_CNT=col
        sw(X0, SP, SC_YY),
        Op::Label("dltrb_row".into()),
        lw(T0, SP, SC_YY),
        lw(T1, SP, SC_M1),
        bge(T0, T1, "dl_tref_pen"),
        sw(X0, SP, SC_CNT),
        Op::Label("dltrb_px".into()),
        lw(T0, SP, SC_CNT),
        bge(T0, S9, "dltrb_eol"),
        lw(T2, SP, SC_YY),
        mul(T2, T2, S9),
        add(T2, T2, T0),
        add(T2, T2, S8),
        lbu(A1, T2, 0),
        beq(A1, X0, "dltrb_next"),
        add(T3, S6, T0),
        lw(T4, SP, SC_YY),
        add(T4, S7, T4),
        blt(T3, X0, "dltrb_next"),
        bge(T3, S4, "dltrb_next"),
        blt(T4, X0, "dltrb_next"),
        bge(T4, S5, "dltrb_next"),
        mul(T5, T4, S3),
        add(T5, T5, S0),
        slli(T6, T3, 2),
        add(A2, T5, T6),
        mv(A0, S10),
        call("DlBlendPx"),
        Op::Label("dltrb_next".into()),
        lw(T0, SP, SC_CNT),
        addi(T0, T0, 1),
        sw(T0, SP, SC_CNT),
        j("dltrb_px"),
        Op::Label("dltrb_eol".into()),
        lw(T0, SP, SC_YY),
        addi(T0, T0, 1),
        sw(T0, SP, SC_YY),
        j("dltrb_row"),
        Op::Label("dl_tref_pen".into()),
        // pen += adv; stop when past max_w
        lw(T0, SP, SC_PEN),
        lw(T1, SP, SC_M0),
        add(T0, T0, T1),
        sw(T0, SP, SC_PEN),
        srai(T0, T0, 6),
        lw(T1, S11, 16), // pen_x
        sub(T0, T0, T1),
        lw(T1, S11, 24), // max_w
        bge(T0, T1, "dl_op"),
        lw(T0, SP, SC_XX),
        addi(T0, T0, 1),
        sw(T0, SP, SC_XX),
        j("dl_tref_ch"),
    ]);
    // ================= done: marker + stamp =================
    ops.push(Op::Label("dl_done".into()));
    puts(&mut ops, "WEBDL ");
    ops.push(lw(T0, SP, SC_STATE));
    put_hex(&mut ops, "dl_hexs");
    putc(&mut ops, i64::from(b'\n'));
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
        ]);
        if has_dom {
            ops.extend([
                la(T5, Addr::DomT),
                lw(T0, T5, crate::domt::H_NEXT), // live guest-DOM node count
                sw(T0, T6, UI_CAP_OFF_NODES),
            ]);
        }
        ops.extend([
            li(T0, 1),
            sw(T0, T6, UI_CAP_OFF_NTILE),
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
    if has_dom {
        ops.extend([
            // record the painted state for the live-check.
            la(T6, Addr::DomT),
            lw(T0, SP, SC_STATE),
            sw(T0, T6, H_DLS),
        ]);
    }
    ops.extend([
        // ---- shared live tail: clear the text-face rasterizer's dirty
        // marks (same contract as `webp_live`).
        Op::Label("dl_live".into()),
    ]);
    if has_dom {
        ops.extend([
            la(T6, Addr::DomT),
            sw(X0, T6, H_DIRTY),
            li(T2, DOMT_NODES),
            addi(T6, T6, DOMT_HDR as i32),
            Op::Label("dl_clr".into()),
            lw(T1, T6, N_FLAGS),
            andi(T1, T1, !F_DIRTY as i32),
            sw(T1, T6, N_FLAGS),
            addi(T6, T6, DOMT_NODE as i32),
            addi(T2, T2, -1),
            bne(T2, X0, "dl_clr"),
        ]);
    }
    ops.extend([
        li(A0, 1),
        j("dl_out"),
        Op::Label("dl_absent".into()),
        li(A0, 0),
        Op::Label("dl_out".into()),
        ld_x(xlen, S11, SP, 72),
        ld_x(xlen, S10, SP, 80),
        ld_x(xlen, S9, SP, 88),
        ld_x(xlen, S8, SP, 96),
        ld_x(xlen, S7, SP, 104),
        ld_x(xlen, S6, SP, 112),
        ld_x(xlen, S5, SP, 120),
        ld_x(xlen, S4, SP, 128),
        ld_x(xlen, S3, SP, 136),
        ld_x(xlen, S2, SP, 144),
        ld_x(xlen, S1, SP, 152),
        ld_x(xlen, S0, SP, 160),
        ld_x(xlen, RA, SP, 168),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: 176,
        },
        ret(),
    ]);
    // ================= leaf helpers =================
    // dl_clip: s6..s9 {x,y,w,h} → {x0,y0,x1,y1} clipped to (S4,S5); a0 = nonempty.
    ops.extend([
        Op::Glob("dl_clip".into()),
        Op::Label("dl_clip".into()),
        add(T0, S6, S8),
        add(T1, S7, S9),
        bge(S6, X0, "dlc_x0"),
        mv(S6, X0),
        Op::Label("dlc_x0".into()),
        bge(S7, X0, "dlc_y0"),
        mv(S7, X0),
        Op::Label("dlc_y0".into()),
        bge(T0, S4, "dlc_x1"),
        mv(S8, T0),
        j("dlc_y1a"),
        Op::Label("dlc_x1".into()),
        mv(S8, S4),
        Op::Label("dlc_y1a".into()),
        bge(T1, S5, "dlc_y1"),
        mv(S9, T1),
        j("dlc_t"),
        Op::Label("dlc_y1".into()),
        mv(S9, S5),
        Op::Label("dlc_t".into()),
        blt(S6, S8, "dlc_n1"),
        li(A0, 0),
        ret(),
        Op::Label("dlc_n1".into()),
        blt(S7, S9, "dlc_n2"),
        li(A0, 0),
        ret(),
        Op::Label("dlc_n2".into()),
        li(A0, 1),
        ret(),
    ]);
    // DlFillRect(s6..s9 = clipped {x0,y0,x1,y1}, s10 = rgba-src) — fill the
    // rect. Opaque source takes the `sw` span loop (same as `emit_opaque_fill`);
    // a<255 falls to per-px `DlBlendPx`. Keeps its own frame (it calls the
    // blend leaf); reads the caller's `S0` fb / `S3` stride / `S6..S10` args.
    ops.extend([
        Op::Glob("DlFillRect".into()),
        Op::Label("DlFillRect".into()),
        addi(SP, SP, -48),
        st_x(xlen, RA, SP, 40),
        andi(T0, S10, 0xff),
        li(T1, 255),
        bne(T0, T1, "dfr_blend"),
        // opaque: stored word = 0xFF00_0000 | c>>8
        srli(T4, S10, 8),
        li(T1, 0xFF00_0000),
        or_(T4, T4, T1),
        mul(T0, S7, S3),
        add(T0, T0, S0),
        slli(T1, S6, 2),
        add(T0, T0, T1),
        st_p(xlen, T0, SP, 0),
        sw(S7, SP, 8),
        Op::Label("dfr_row".into()),
        lw(T1, SP, 8),
        bge(T1, S9, "dfr_out"),
        ld_p(xlen, T2, SP, 0),
        sub(T3, S8, S6),
        Op::Label("dfr_px".into()),
        sw(T4, T2, 0),
        addi(T2, T2, 4),
        addi(T3, T3, -1),
        bne(T3, X0, "dfr_px"),
        lw(T1, SP, 8),
        addi(T1, T1, 1),
        sw(T1, SP, 8),
        ld_p(xlen, T2, SP, 0),
        add(T2, T2, S3),
        st_p(xlen, T2, SP, 0),
        j("dfr_row"),
        // a<255: per-px DlBlendPx over the same clipped rect.
        Op::Label("dfr_blend".into()),
        sw(S7, SP, 8),
        Op::Label("dfrb_row".into()),
        lw(T1, SP, 8),
        bge(T1, S9, "dfr_out"),
        sw(S6, SP, 12),
        Op::Label("dfrb_px".into()),
        lw(T3, SP, 12),
        bge(T3, S8, "dfrb_eol"),
        lw(T5, SP, 8),
        mul(T5, T5, S3),
        add(T5, T5, S0),
        slli(T6, T3, 2),
        add(A2, T5, T6),
        mv(A0, S10),
        li(A1, 255),
        call("DlBlendPx"),
        lw(T3, SP, 12),
        addi(T3, T3, 1),
        sw(T3, SP, 12),
        j("dfrb_px"),
        Op::Label("dfrb_eol".into()),
        lw(T1, SP, 8),
        addi(T1, T1, 1),
        sw(T1, SP, 8),
        j("dfrb_row"),
        Op::Label("dfr_out".into()),
        ld_x(xlen, RA, SP, 40),
        addi(SP, SP, 48),
        ret(),
    ]);
    // DlBlendPx(a0=rgba,a1=cov,a2=dst) — the `Canvas32::blend` rule over an
    // opaque dst (every recorded op paints onto opaque ground; the first op
    // is always the page FILL).
    ops.extend([
        Op::Glob("DlBlendPx".into()),
        Op::Label("DlBlendPx".into()),
        // af = (src_a * cov + 127) / 255
        andi(T0, A0, 0xff),
        mul(T0, T0, A1),
        addi(T0, T0, 127),
        li(T1, 255),
        divu(T0, T0, T1),
        beq(T0, X0, "dlbp_out"),
        li(T1, 255),
        bne(T0, T1, "dlbp_blend"),
        srli(T1, A0, 8),
        li(T2, 0xFF00_0000),
        or_(T1, T1, T2),
        sw(T1, A2, 0),
        Op::Label("dlbp_out".into()),
        ret(),
        Op::Label("dlbp_blend".into()),
        // keep = 255-af; dst word = 0xFFRRGGBB
        li(T1, 255),
        sub(T1, T1, T0),
        lw(T2, A2, 0),
        // r: (s_r*af + d_r*keep)/255 → T3 (accumulates word)
        srli(T3, A0, 24),
        andi(T3, T3, 0xff),
        srli(T4, T2, 16),
        andi(T4, T4, 0xff),
        mul(T3, T3, T0),
        mul(T4, T4, T1),
        add(T3, T3, T4),
        li(T4, 255),
        divu(T3, T3, T4),
        slli(T3, T3, 16),
        // g
        srli(T5, A0, 16),
        andi(T5, T5, 0xff),
        srli(T6, T2, 8),
        andi(T6, T6, 0xff),
        mul(T5, T5, T0),
        mul(T6, T6, T1),
        add(T5, T5, T6),
        divu(T5, T5, T4),
        slli(T5, T5, 8),
        or_(T3, T3, T5),
        // b
        srli(T5, A0, 8),
        andi(T5, T5, 0xff),
        andi(T6, T2, 0xff),
        mul(T5, T5, T0),
        mul(T6, T6, T1),
        add(T5, T5, T6),
        divu(T5, T5, T4),
        or_(T3, T3, T5),
        li(T4, 0xFF00_0000),
        or_(T3, T3, T4),
        sw(T3, A2, 0),
        ret(),
    ]);
    // DlFindId(a0=id ptr,a1=len) → a0 = node idx | NONE — `LwFindId`'s scan,
    // but the target bytes live in `__web_dl` rodata, not `__wasm_mem`.
    if has_dom {
        ops.extend([
            Op::Glob("DlFindId".into()),
            Op::Label("DlFindId".into()),
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
            mv(S3, A0),
            mv(S1, A1),
            li(S2, 0),
            beq(S1, X0, "dfi_none"),
            Op::Label("dfi_loop".into()),
            li(T0, DOMT_NODES),
            bgeu(S2, T0, "dfi_none"),
            slli(T6, S2, 5), // i * DOMT_ID_SLOT(32)
            la(T5, Addr::DomId),
            add(T6, T6, T5),
            lw(T0, T6, 0),
            bne(T0, S1, "dfi_next"),
            mv(T3, X0),
            Op::Label("dfi_cmp".into()),
            bgeu(T3, S1, "dfi_found"),
            add(T0, T6, T3),
            lbu(T0, T0, 4),
            add(T1, S3, T3),
            lbu(T1, T1, 0),
            bne(T0, T1, "dfi_next"),
            addi(T3, T3, 1),
            j("dfi_cmp"),
            Op::Label("dfi_next".into()),
            addi(S2, S2, 1),
            j("dfi_loop"),
            Op::Label("dfi_found".into()),
            mv(A0, S2),
            j("dfi_out"),
            Op::Label("dfi_none".into()),
            li(A0, NONE),
            Op::Label("dfi_out".into()),
            ld_x(xlen, RA, SP, 40),
            ld_x(xlen, S0, SP, 32),
            ld_x(xlen, S1, SP, 24),
            ld_x(xlen, S2, SP, 16),
            ld_x(xlen, S3, SP, 8),
            Op::Addi {
                rd: SP,
                rs: SP,
                imm: 48,
            },
            ret(),
        ]);
    }
    Node {
        purpose: Purpose::UiDom,
        ops,
    }
}

/// `WebPaint` — the single ownership call sites use: `DlPaint` replays a
/// `__web_dl` list when one is installed (and owns the surface from then
/// on); `WebBlit` stays the pixel-pack fallback for a build without a list.
/// `a0` propagates whichever answered.
fn web_paint_node(spec: &BoardSpec) -> Node {
    let xlen = spec.isa.xlen;
    Node {
        purpose: Purpose::UiDom,
        ops: vec![
            Op::Comment("WebPaint — DlPaint (list) else WebBlit (pixel pack)".into()),
            Op::Glob("WebPaint".into()),
            Op::Label("WebPaint".into()),
            Op::Addi {
                rd: SP,
                rs: SP,
                imm: -16,
            },
            st_x(xlen, RA, SP, 8),
            call("DlPaint"),
            bne(A0, X0, "wp_out"),
            call("WebBlit"),
            Op::Label("wp_out".into()),
            ld_x(xlen, RA, SP, 8),
            Op::Addi {
                rd: SP,
                rs: SP,
                imm: 16,
            },
            ret(),
        ],
    }
}

/// Guest display-list routines (`DlPaint`, `WebPaint`), attached under
/// `guest_jit` beside the `webp` set. `g6b-elf` installs the `__web_dl`
/// payload (`g6b_kernel::dl_pack`); a build without one gets `__web_dl`
/// aliased onto `boot_log` (non-magic) and `DlPaint` falls through to a0=0.
pub fn nodes(spec: &BoardSpec) -> Vec<Node> {
    vec![dl_paint_node(spec), web_paint_node(spec)]
}
