// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Guest DOM kernel for the BIOS browser UI — a bounded lirx-dom-shaped row
//! store at `__ui_dom` plus `DomPaint` onto the 4bpp `__gr_plane`.
//!
//! `kernel-spec/lirx-dom` semantics materialized as ASM IR: stable rows keyed
//! by id, `set_inner_text` / `set_visible` imports called by the lowered
//! `WasmStart` (`g6b-wasm::jit::start_ops`), and `fetch` echoing the kernel
//! file router (`GET <path>` over serial, same shape as `GetFile`). Visibility
//! flips never destroy the row or its text. Everything is bounded: rows, id
//! length, printed bytes, painted characters, and rows per frame.

#![allow(missing_docs)]

use g6b_spec::BoardSpec;

use crate::encode::{
    A0, A1, A2, A3, A4, A5, A6, A7, RA, S0, S1, S2, S3, S4, S5, S6, S7, S8, S9, SBI_PUTCHAR, SP,
    T0, T1, T2, T3, T4, T5, T6, X0,
};
use crate::font::FONT_BOX;
use crate::{gr_stride, Addr, Module, Node, Op, Purpose, GR_HEADER_BYTES};

/// Bounded DOM rows (`lirx-dom`-shaped; not a general allocator).
pub const DOM_ROWS: i64 = 48;
/// One row: id_ptr(x) +8 text_ptr(x) +16 id_len(u32) +20 text_len(u32) +24 flags(u32).
pub const DOM_ROW_BYTES: i64 = 32;
/// Table header: +0 count(u32), +4 dirty(u32), +8 painted(u32),
/// +12 npend(u32), +16..+28 await slots[4](u32).
pub const DOM_HDR: i32 = 32;
/// Header +8: dirty watermark the last background repaint covered
/// (`trap_timer` paints when `dirty != painted`).
pub const DOM_PAINTED: i32 = 8;
/// Header +12: pending-await count — the cheap "any pending" test for the
/// `DomAwait` poll; `Await` increments, `DomAwait` decrements per resolve.
pub const DOM_AWAIT: i32 = 12;
/// Header +16: `AWAIT_SLOTS` u32 slots — 0 idle, 1 pending, 2 resolved,
/// 3 rejected. A `Await` claims the first non-pending slot; all-pending is
/// the bounded `AWAIT-REJ full` (fail closed). Pending ops resolve on the
/// poll points (timer tick or `Ui`/`Keys`), never inline — `await` does
/// not block DOM events.
pub const AWAIT_SLOT_OFF: i32 = 16;
pub const AWAIT_SLOTS: i64 = 4;
pub const AWAIT_PEND: i64 = 1;
pub const AWAIT_DONE: i64 = 2;
pub const AWAIT_REJ: i64 = 3;
/// `__ui_dom` BSS size.
pub const UI_DOM_BYTES: u64 = 32 + 48 * 32;
/// id byte-length cap (longer ids are dropped, fail-closed).
pub const DOM_ID_MAX: i64 = 96;
/// Bytes a `fetch`/`log` string may print.
pub const DOM_PUTS_MAX: i64 = 96;
/// Painted / echoed characters per row.
pub const DOM_TEXT_MAX: i64 = 72;
/// First text row y (below the y=0 scanline and the y=8 `G6LC` blit).
pub const DOM_Y0: i64 = 24;
/// Row flag: visible (set_visible / set_inner_text semantics).
pub const DOM_F_VISIBLE: i64 = 1;
/// Row flag: has text content.
pub const DOM_F_TEXT: i64 = 2;

/// xlen-dependent pointer load (`ld` on rv64, `lw` on rv32).
fn ld_x(xlen: u32, rd: u32, rs: u32, off: i32) -> Op {
    if xlen == 64 {
        Op::Ld { rd, rs, off }
    } else {
        Op::Lw { rd, rs, off }
    }
}

/// xlen-dependent pointer store.
fn st_x(xlen: u32, rs2: u32, rs1: u32, off: i32) -> Op {
    if xlen == 64 {
        Op::Sd { rs2, rs1, off }
    } else {
        Op::Sw { rs2, rs1, off }
    }
}

fn lw(rd: u32, rs: u32, off: i32) -> Op {
    Op::Lw { rd, rs, off }
}

fn putc(ch: i64) -> Vec<Op> {
    vec![
        Op::Li { rd: A0, imm: ch },
        Op::Li {
            rd: A7,
            imm: SBI_PUTCHAR,
        },
        Op::Ecall,
    ]
}

fn puts_str(s: &str) -> Vec<Op> {
    s.bytes().flat_map(|b| putc(i64::from(b))).collect()
}

fn ret() -> Op {
    Op::Jalr {
        rd: X0,
        rs: RA,
        imm: 0,
    }
}

fn jump(to: &str) -> Op {
    Op::Jal {
        rd: X0,
        to: to.into(),
    }
}

pub(crate) fn signbit(xlen: u32) -> u32 {
    xlen.saturating_sub(1)
}

/// DOM service nodes for `payload` when `kernel.wasm.jit` is live.
/// `WasmStart` ships as a `ret` stub; `g6b-elf` replaces its ops with
/// `g6b_wasm::jit::start_ops` output so the label always resolves.
pub fn nodes(spec: &BoardSpec) -> Vec<Node> {
    let xlen = spec.isa.xlen;
    let mut nodes = vec![
        wasm_ui_node(xlen),
        wasm_start_stub_node(),
        dom_find_node(xlen),
        dom_text_node(xlen),
        dom_visible_node(xlen),
        wasm_puts_node(xlen),
        wasm_fetch_node(xlen),
        wasm_log_node(xlen),
        dom_paint_node(spec),
        dom_await_node(xlen),
        wasm_await_node(xlen),
        wasm_throw_node(xlen),
        wasm_catch_node(xlen),
    ];
    if spec.wants_virtio_gpu() || spec.wants_disp_scan() {
        nodes.push(dom_paint32_node(spec));
    }
    nodes
}

/// `WasmAwait` — the `env.await` import (also `uart_await`'s body): claim
/// the first non-pending await slot of `AWAIT_SLOTS` u32s at `__ui_dom`
/// header +16 — state → 1=pending, `npend` (+12) increments, the `await.N`
/// row is set to `"pending menu"` and `AWAIT pending N` prints. All slots
/// pending → `AWAIT-REJ full` (bounded capacity, fail closed). The claim
/// never blocks: resolution happens on the `DomAwait` poll points, so an
/// awaited op never stalls DOM events. s0=slot index, s1=`__ui_dom` —
/// both framed (caller-saved-in-trap and wasm callers alike).
fn wasm_await_node(xlen: u32) -> Node {
    let mut ops = vec![
        Op::Comment(
            "WasmAwait — env.await: claim a bounded pending slot (await.N row); full → AWAIT-REJ"
                .into(),
        ),
        Op::Glob("WasmAwait".into()),
        Op::Label("WasmAwait".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -32,
        },
        st_x(xlen, RA, SP, 24),
        st_x(xlen, S0, SP, 16),
        st_x(xlen, S1, SP, 8),
        Op::La {
            rd: S1,
            addr: Addr::UiDom,
        },
        Op::Li { rd: S0, imm: 0 },
        Op::Label("wawait_find".into()),
        Op::Li {
            rd: T6,
            imm: AWAIT_SLOTS,
        },
        Op::Beq {
            rs1: S0,
            rs2: T6,
            to: "wawait_full".into(),
        },
        Op::Slli {
            rd: T4,
            rs: S0,
            shamt: 2,
        },
        Op::Add {
            rd: T4,
            rs1: S1,
            rs2: T4,
        },
        Op::Lw {
            rd: T1,
            rs: T4,
            off: AWAIT_SLOT_OFF,
        },
        Op::Li {
            rd: T6,
            imm: AWAIT_PEND,
        },
        Op::Bne {
            rs1: T1,
            rs2: T6,
            to: "wawait_got".into(),
        },
        Op::Addi {
            rd: S0,
            rs: S0,
            imm: 1,
        },
        Op::Jal {
            rd: X0,
            to: "wawait_find".into(),
        },
        Op::Label("wawait_got".into()),
        Op::Li {
            rd: T1,
            imm: AWAIT_PEND,
        },
        Op::Sw {
            rs2: T1,
            rs1: T4,
            off: AWAIT_SLOT_OFF,
        },
        Op::Lw {
            rd: T2,
            rs: S1,
            off: DOM_AWAIT,
        },
        Op::Addi {
            rd: T2,
            rs: T2,
            imm: 1,
        },
        Op::Sw {
            rs2: T2,
            rs1: S1,
            off: DOM_AWAIT,
        },
        // id = domawait_ids + i*8 ("await.N\0") → row "pending menu".
        Op::La {
            rd: A0,
            addr: Addr::Label("domawait_ids".into()),
        },
        Op::Slli {
            rd: T4,
            rs: S0,
            shamt: 3,
        },
        Op::Add {
            rd: A0,
            rs1: A0,
            rs2: T4,
        },
        Op::Li { rd: A1, imm: 7 },
        Op::La {
            rd: A2,
            addr: Addr::Label("domawait_pend".into()),
        },
        Op::Li { rd: A3, imm: 12 },
        Op::Jal {
            rd: RA,
            to: "WasmDomText".into(),
        },
    ];
    ops.extend(puts_str("AWAIT pending "));
    ops.extend([
        Op::Addi {
            rd: A0,
            rs: S0,
            imm: i32::from(b'0'),
        },
        Op::Li {
            rd: A7,
            imm: SBI_PUTCHAR,
        },
        Op::Ecall,
        Op::Li {
            rd: A0,
            imm: i64::from(b'\n'),
        },
        Op::Li {
            rd: A7,
            imm: SBI_PUTCHAR,
        },
        Op::Ecall,
        Op::Jal {
            rd: X0,
            to: "wawait_ret".into(),
        },
        Op::Label("wawait_full".into()),
    ]);
    ops.extend(puts_str("AWAIT-REJ full\n"));
    ops.extend([
        Op::Li { rd: S0, imm: -1 },
        Op::Label("wawait_ret".into()),
        // a0 = claimed slot index (or -1 when full) — the env.await result.
        Op::Addi {
            rd: A0,
            rs: S0,
            imm: 0,
        },
        Op::Label("wawait_out".into()),
        ld_x(xlen, S1, SP, 8),
        ld_x(xlen, S0, SP, 16),
        ld_x(xlen, RA, SP, 24),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: 32,
        },
        ret(),
    ]);
    Node {
        purpose: Purpose::UiDom,
        ops,
    }
}

/// `WasmThrow` — the `env.throw` import (also `uart_throw`'s body): reject
/// the newest pending await slot — state → 3=rejected, `npend`--, the
/// `await.N` row is set to `"rejected menu"` (the caught state, visible in
/// the next repaint) and `AWAIT-THROW /bios/menu` prints. Nothing pending
/// → `AWAIT-THROW none` (a throw with no in-flight await is a no-op, not
/// an abort). A rejected slot is reclaimable like a resolved one.
/// s0=newest pending idx (AWAIT_SLOTS sentinel = none), s1=`__ui_dom`.
fn wasm_throw_node(xlen: u32) -> Node {
    let mut ops = vec![
        Op::Comment(
            "WasmThrow — env.throw: reject the newest pending await (AWAIT-THROW; row → rejected)"
                .into(),
        ),
        Op::Glob("WasmThrow".into()),
        Op::Label("WasmThrow".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -32,
        },
        st_x(xlen, RA, SP, 24),
        st_x(xlen, S0, SP, 16),
        st_x(xlen, S1, SP, 8),
        Op::La {
            rd: S1,
            addr: Addr::UiDom,
        },
        // a0 < 0 → the newest-pending scan (the UART Throw path);
        // 0 <= a0 < AWAIT_SLOTS → targeted reject (the env.throw(i32)
        // import — the rejected slot is the awaiter's own, not always the
        // newest). Anything else / non-pending → AWAIT-THROW none.
        Op::Srli {
            rd: T6,
            rs: A0,
            shamt: signbit(xlen),
        },
        Op::Bne {
            rs1: T6,
            rs2: X0,
            to: "wthrow_scan".into(),
        },
        // Bounds: t6 = SLOTS - a0 must be > 0.
        Op::Li {
            rd: T6,
            imm: AWAIT_SLOTS,
        },
        Op::Sub {
            rd: T6,
            rs1: T6,
            rs2: A0,
        },
        Op::Beq {
            rs1: T6,
            rs2: X0,
            to: "wthrow_none".into(),
        },
        Op::Srli {
            rd: T6,
            rs: T6,
            shamt: signbit(xlen),
        },
        Op::Bne {
            rs1: T6,
            rs2: X0,
            to: "wthrow_none".into(),
        },
        Op::Addi {
            rd: S0,
            rs: A0,
            imm: 0,
        },
        // Targeted slot must actually be pending.
        Op::Slli {
            rd: T4,
            rs: S0,
            shamt: 2,
        },
        Op::Add {
            rd: T4,
            rs1: S1,
            rs2: T4,
        },
        Op::Lw {
            rd: T1,
            rs: T4,
            off: AWAIT_SLOT_OFF,
        },
        Op::Li {
            rd: T6,
            imm: AWAIT_PEND,
        },
        Op::Bne {
            rs1: T1,
            rs2: T6,
            to: "wthrow_none".into(),
        },
        Op::Jal {
            rd: X0,
            to: "wthrow_reject".into(),
        },
        Op::Label("wthrow_scan".into()),
        Op::Li {
            rd: S0,
            imm: AWAIT_SLOTS,
        },
        Op::Li { rd: T3, imm: 0 },
        Op::Label("wthrow_loop".into()),
        Op::Li {
            rd: T6,
            imm: AWAIT_SLOTS,
        },
        Op::Beq {
            rs1: T3,
            rs2: T6,
            to: "wthrow_pick".into(),
        },
        Op::Slli {
            rd: T4,
            rs: T3,
            shamt: 2,
        },
        Op::Add {
            rd: T4,
            rs1: S1,
            rs2: T4,
        },
        Op::Lw {
            rd: T1,
            rs: T4,
            off: AWAIT_SLOT_OFF,
        },
        Op::Li {
            rd: T6,
            imm: AWAIT_PEND,
        },
        Op::Bne {
            rs1: T1,
            rs2: T6,
            to: "wthrow_next".into(),
        },
        Op::Addi {
            rd: S0,
            rs: T3,
            imm: 0,
        },
        Op::Label("wthrow_next".into()),
        Op::Addi {
            rd: T3,
            rs: T3,
            imm: 1,
        },
        Op::Jal {
            rd: X0,
            to: "wthrow_loop".into(),
        },
        Op::Label("wthrow_pick".into()),
        Op::Li {
            rd: T6,
            imm: AWAIT_SLOTS,
        },
        Op::Beq {
            rs1: S0,
            rs2: T6,
            to: "wthrow_none".into(),
        },
        Op::Label("wthrow_reject".into()),
        Op::Slli {
            rd: T4,
            rs: S0,
            shamt: 2,
        },
        Op::Add {
            rd: T4,
            rs1: S1,
            rs2: T4,
        },
        Op::Li {
            rd: T1,
            imm: AWAIT_REJ,
        },
        Op::Sw {
            rs2: T1,
            rs1: T4,
            off: AWAIT_SLOT_OFF,
        },
        Op::Lw {
            rd: T0,
            rs: S1,
            off: DOM_AWAIT,
        },
        Op::Addi {
            rd: T0,
            rs: T0,
            imm: -1,
        },
        Op::Sw {
            rs2: T0,
            rs1: S1,
            off: DOM_AWAIT,
        },
    ];
    ops.extend(puts_str("AWAIT-THROW /bios/menu\n"));
    ops.extend([
        Op::La {
            rd: A0,
            addr: Addr::Label("domawait_ids".into()),
        },
        Op::Slli {
            rd: T4,
            rs: S0,
            shamt: 3,
        },
        Op::Add {
            rd: A0,
            rs1: A0,
            rs2: T4,
        },
        Op::Li { rd: A1, imm: 7 },
        Op::La {
            rd: A2,
            addr: Addr::Label("domawait_rej".into()),
        },
        Op::Li { rd: A3, imm: 13 },
        Op::Jal {
            rd: RA,
            to: "WasmDomText".into(),
        },
        Op::Jal {
            rd: X0,
            to: "wthrow_out".into(),
        },
        Op::Label("wthrow_none".into()),
    ]);
    ops.extend(puts_str("AWAIT-THROW none\n"));
    ops.extend([
        Op::Label("wthrow_out".into()),
        ld_x(xlen, S1, SP, 8),
        ld_x(xlen, S0, SP, 16),
        ld_x(xlen, RA, SP, 24),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: 32,
        },
        ret(),
    ]);
    Node {
        purpose: Purpose::UiDom,
        ops,
    }
}

/// `WasmCatch` — the `env.catch` import: `a0=slot` → `a0=1` iff that slot
/// is currently rejected (`AWAIT_REJ`=3), else 0. Leaf — no frame. Bounds
/// out-of-range or negative slots as 0.
fn wasm_catch_node(xlen: u32) -> Node {
    let mut ops = vec![
        Op::Comment("WasmCatch — env.catch(slot)->i32: 1 iff the slot is rejected".into()),
        Op::Glob("WasmCatch".into()),
        Op::Label("WasmCatch".into()),
    ];
    // a0 < 0 → 0
    ops.push(Op::Srli {
        rd: T6,
        rs: A0,
        shamt: signbit(xlen),
    });
    ops.push(Op::Bne {
        rs1: T6,
        rs2: X0,
        to: "wcatch_zero".into(),
    });
    // a0 >= AWAIT_SLOTS → 0 (t6 = AWAIT_SLOTS - a0; t6 <= 0)
    ops.push(Op::Li {
        rd: T6,
        imm: AWAIT_SLOTS,
    });
    ops.push(Op::Sub {
        rd: T6,
        rs1: T6,
        rs2: A0,
    });
    ops.push(Op::Beq {
        rs1: T6,
        rs2: X0,
        to: "wcatch_zero".into(),
    });
    ops.push(Op::Srli {
        rd: T6,
        rs: T6,
        shamt: signbit(xlen),
    });
    ops.push(Op::Bne {
        rs1: T6,
        rs2: X0,
        to: "wcatch_zero".into(),
    });
    // state = __ui_dom[AWAIT_SLOT_OFF + a0*4]
    ops.push(Op::La {
        rd: T5,
        addr: Addr::UiDom,
    });
    ops.push(Op::Slli {
        rd: T4,
        rs: A0,
        shamt: 2,
    });
    ops.push(Op::Add {
        rd: T4,
        rs1: T5,
        rs2: T4,
    });
    ops.push(Op::Lw {
        rd: T1,
        rs: T4,
        off: AWAIT_SLOT_OFF,
    });
    // a0 = (state == AWAIT_REJ). State is at most AWAIT_REJ, so
    // t1 = state - AWAIT_REJ is 0 iff rejected, negative otherwise.
    // a0 = 1 - sign_bit(t1).
    ops.push(Op::Li {
        rd: T6,
        imm: AWAIT_REJ,
    });
    ops.push(Op::Sub {
        rd: T1,
        rs1: T1,
        rs2: T6,
    });
    ops.push(Op::Srli {
        rd: T6,
        rs: T1,
        shamt: signbit(xlen),
    });
    ops.push(Op::Li { rd: A0, imm: 1 });
    ops.push(Op::Sub {
        rd: A0,
        rs1: A0,
        rs2: T6,
    });
    ops.push(ret());
    ops.push(Op::Label("wcatch_zero".into()));
    ops.push(Op::Li { rd: A0, imm: 0 });
    ops.push(ret());
    Node {
        purpose: Purpose::UiDom,
        ops,
    }
}

/// `DomAwait` — the bounded pending-op poll: drains the await slots
/// (`__ui_dom` header +16, `AWAIT_SLOTS` u32s) — every slot marked
/// 1=pending resolves in order: state → 2=resolved, `npend` (+12)
/// decrements, the deferred router call prints (`AWAIT-GET /bios/menu`)
/// and the `await.N` row is set to `"resolved menu"` via `WasmDomText`
/// (which bumps `dirty`, so the next `trap_timer` background repaint
/// picks it up). Draining is bounded by `AWAIT_SLOTS`; an idle scan is a
/// no-op. Row texts are fixed rodata — a slot only ever awaits the one
/// bounded fetch, never an arbitrary path. Called from `trap_timer` and
/// the `Ui`/`Keys` polls. s0=i/s1=base live across `WasmDomText`, which
/// clobbers only caller-saved t/a regs.
fn dom_await_node(xlen: u32) -> Node {
    let mut ops = vec![
        Op::Comment(
            "DomAwait — resolve at most one pending await slot per call \
             (pending→resolved); bounded O(1) work so the timer/IRQ context \
             never spins. Callers that must drain (Ui/Keys polls) call it \
             AWAIT_SLOTS times."
                .into(),
        ),
        Op::Glob("DomAwait".into()),
        Op::Label("DomAwait".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -32,
        },
        st_x(xlen, RA, SP, 24),
        st_x(xlen, S0, SP, 16),
        st_x(xlen, S1, SP, 8),
        Op::La {
            rd: S1,
            addr: Addr::UiDom,
        },
        // Fast path: npend == 0 → nothing to resolve.
        Op::Lw {
            rd: T0,
            rs: S1,
            off: DOM_AWAIT,
        },
        Op::Beq {
            rs1: T0,
            rs2: X0,
            to: "dawait_out".into(),
        },
        Op::Li { rd: S0, imm: 0 },
        Op::Label("dawait_scan".into()),
        Op::Li {
            rd: T6,
            imm: AWAIT_SLOTS,
        },
        Op::Beq {
            rs1: S0,
            rs2: T6,
            to: "dawait_out".into(),
        },
        Op::Slli {
            rd: T4,
            rs: S0,
            shamt: 2,
        },
        Op::Add {
            rd: T4,
            rs1: S1,
            rs2: T4,
        },
        Op::Lw {
            rd: T1,
            rs: T4,
            off: AWAIT_SLOT_OFF,
        },
        Op::Li {
            rd: T6,
            imm: AWAIT_PEND,
        },
        Op::Bne {
            rs1: T1,
            rs2: T6,
            to: "dawait_next".into(),
        },
        // Resolve slot i.
        Op::Li {
            rd: T1,
            imm: AWAIT_DONE,
        },
        Op::Sw {
            rs2: T1,
            rs1: T4,
            off: AWAIT_SLOT_OFF,
        },
        Op::Lw {
            rd: T0,
            rs: S1,
            off: DOM_AWAIT,
        },
        Op::Addi {
            rd: T0,
            rs: T0,
            imm: -1,
        },
        Op::Sw {
            rs2: T0,
            rs1: S1,
            off: DOM_AWAIT,
        },
    ];
    ops.extend(puts_str("AWAIT-GET /bios/menu\n"));
    ops.extend([
        // id = domawait_ids + i*8 ("await.N\0", 7 chars)
        Op::La {
            rd: A0,
            addr: Addr::Label("domawait_ids".into()),
        },
        Op::Slli {
            rd: T4,
            rs: S0,
            shamt: 3,
        },
        Op::Add {
            rd: A0,
            rs1: A0,
            rs2: T4,
        },
        Op::Li { rd: A1, imm: 7 },
        Op::La {
            rd: A2,
            addr: Addr::Label("domawait_ok".into()),
        },
        Op::Li { rd: A3, imm: 13 },
        Op::Jal {
            rd: RA,
            to: "WasmDomText".into(),
        },
        // Resolved one slot — stop. Bounded per-call work; the drain
        // callers loop this routine.
        Op::Jal {
            rd: X0,
            to: "dawait_out".into(),
        },
        Op::Label("dawait_next".into()),
        Op::Addi {
            rd: S0,
            rs: S0,
            imm: 1,
        },
        Op::Jal {
            rd: X0,
            to: "dawait_scan".into(),
        },
        Op::Label("dawait_out".into()),
        ld_x(xlen, S1, SP, 8),
        ld_x(xlen, S0, SP, 16),
        ld_x(xlen, RA, SP, 24),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: 32,
        },
        ret(),
        // Inline rodata (after ret): the four 8B row ids + the two fixed
        // await texts. "await.N\0" per slot.
        Op::Label("domawait_ids".into()),
        Op::Word(u32::from_le_bytes(*b"awai")),
        Op::Word(u32::from_le_bytes(*b"t.0\0")),
        Op::Word(u32::from_le_bytes(*b"awai")),
        Op::Word(u32::from_le_bytes(*b"t.1\0")),
        Op::Word(u32::from_le_bytes(*b"awai")),
        Op::Word(u32::from_le_bytes(*b"t.2\0")),
        Op::Word(u32::from_le_bytes(*b"awai")),
        Op::Word(u32::from_le_bytes(*b"t.3\0")),
        // "pending menu" (12B) — the text uart_await points the row at.
        Op::Label("domawait_pend".into()),
        Op::Word(u32::from_le_bytes(*b"pend")),
        Op::Word(u32::from_le_bytes(*b"ing ")),
        Op::Word(u32::from_le_bytes(*b"menu")),
        // "resolved menu" (13B).
        Op::Label("domawait_ok".into()),
        Op::Word(u32::from_le_bytes(*b"reso")),
        Op::Word(u32::from_le_bytes(*b"lved")),
        Op::Word(u32::from_le_bytes(*b" men")),
        Op::Word(u32::from_le_bytes(*b"u\0\0\0")),
        // "rejected menu" (13B) — the `Throw` path's caught state.
        Op::Label("domawait_rej".into()),
        Op::Word(u32::from_le_bytes(*b"reje")),
        Op::Word(u32::from_le_bytes(*b"cted")),
        Op::Word(u32::from_le_bytes(*b" men")),
        Op::Word(u32::from_le_bytes(*b"u\0\0\0")),
    ]);
    Node {
        purpose: Purpose::UiDom,
        ops,
    }
}

/// `WasmUi` — kernel browser entry: lowered `_start` then repaint.
fn wasm_ui_node(xlen: u32) -> Node {
    Node {
        purpose: Purpose::UiDom,
        ops: vec![
            Op::Comment("WasmUi — goja-shaped kernel _start → DOM ops → DomPaint (bounded)".into()),
            Op::Glob("WasmUi".into()),
            Op::Label("WasmUi".into()),
            Op::Addi {
                rd: SP,
                rs: SP,
                imm: -16,
            },
            st_x(xlen, RA, SP, 8),
            Op::Jal {
                rd: RA,
                to: "WasmStart".into(),
            },
            Op::Jal {
                rd: RA,
                to: "DomPaint".into(),
            },
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

/// `WasmStart` anchor — replaced by `g6b-wasm::jit::start_ops` at ELF build.
fn wasm_start_stub_node() -> Node {
    Node {
        purpose: Purpose::UiDom,
        ops: vec![
            Op::Comment("WasmStart — guest ISel of wasm _start; ops installed at ELF build".into()),
            Op::Glob("WasmStart".into()),
            Op::Label("WasmStart".into()),
            ret(),
        ],
    }
}

/// `WasmDomFind(a0=id_ptr, a1=id_len)` → a0 = row index or -1.
fn dom_find_node(xlen: u32) -> Node {
    Node {
        purpose: Purpose::UiDom,
        ops: vec![
            Op::Comment("WasmDomFind — bounded id lookup over __ui_dom rows".into()),
            Op::Glob("WasmDomFind".into()),
            Op::Label("WasmDomFind".into()),
            Op::La {
                rd: T0,
                addr: Addr::UiDom,
            },
            Op::Lw {
                rd: T1,
                rs: T0,
                off: 0,
            },
            Op::Li { rd: T2, imm: 0 },
            Op::Label("domfind_loop".into()),
            Op::Beq {
                rs1: T2,
                rs2: T1,
                to: "domfind_miss".into(),
            },
            Op::Slli {
                rd: T3,
                rs: T2,
                shamt: 5,
            },
            Op::Add {
                rd: T3,
                rs1: T0,
                rs2: T3,
            },
            Op::Addi {
                rd: T3,
                rs: T3,
                imm: DOM_HDR,
            },
            Op::Lw {
                rd: T4,
                rs: T3,
                off: 16,
            },
            Op::Bne {
                rs1: T4,
                rs2: A1,
                to: "domfind_next".into(),
            },
            ld_x(xlen, T4, T3, 0),
            Op::Li { rd: T5, imm: 0 },
            Op::Label("domfind_cmp".into()),
            Op::Beq {
                rs1: T5,
                rs2: A1,
                to: "domfind_hit".into(),
            },
            Op::Add {
                rd: T6,
                rs1: T4,
                rs2: T5,
            },
            Op::Lbu {
                rd: T6,
                rs: T6,
                off: 0,
            },
            Op::Add {
                rd: A6,
                rs1: A0,
                rs2: T5,
            },
            Op::Lbu {
                rd: A6,
                rs: A6,
                off: 0,
            },
            Op::Bne {
                rs1: T6,
                rs2: A6,
                to: "domfind_next".into(),
            },
            Op::Addi {
                rd: T5,
                rs: T5,
                imm: 1,
            },
            jump("domfind_cmp"),
            Op::Label("domfind_next".into()),
            Op::Addi {
                rd: T2,
                rs: T2,
                imm: 1,
            },
            jump("domfind_loop"),
            Op::Label("domfind_hit".into()),
            Op::Addi {
                rd: A0,
                rs: T2,
                imm: 0,
            },
            ret(),
            Op::Label("domfind_miss".into()),
            Op::Li { rd: A0, imm: -1 },
            ret(),
        ],
    }
}

/// `WasmDomText(a0=id_ptr, a1=id_len, a2=text_ptr, a3=text_len)` — the
/// `env.set_inner_text` import: find-or-insert row, store text, mark visible.
fn dom_text_node(xlen: u32) -> Node {
    Node {
        purpose: Purpose::UiDom,
        ops: vec![
            Op::Comment("WasmDomText — env.set_inner_text import (bounded, transactional)".into()),
            Op::Glob("WasmDomText".into()),
            Op::Label("WasmDomText".into()),
            Op::Addi {
                rd: SP,
                rs: SP,
                imm: -48,
            },
            st_x(xlen, A0, SP, 0),
            st_x(xlen, A1, SP, 8),
            st_x(xlen, A2, SP, 16),
            st_x(xlen, A3, SP, 24),
            st_x(xlen, RA, SP, 40),
            // id_len: reject negative or > DOM_ID_MAX.
            Op::Srli {
                rd: T0,
                rs: A1,
                shamt: signbit(xlen),
            },
            Op::Bne {
                rs1: T0,
                rs2: X0,
                to: "domtext_out".into(),
            },
            Op::Li {
                rd: T0,
                imm: DOM_ID_MAX,
            },
            Op::Sub {
                rd: T0,
                rs1: T0,
                rs2: A1,
            },
            Op::Srli {
                rd: T0,
                rs: T0,
                shamt: signbit(xlen),
            },
            Op::Bne {
                rs1: T0,
                rs2: X0,
                to: "domtext_out".into(),
            },
            // text_len: reject negative.
            Op::Srli {
                rd: T0,
                rs: A3,
                shamt: signbit(xlen),
            },
            Op::Bne {
                rs1: T0,
                rs2: X0,
                to: "domtext_out".into(),
            },
            Op::Jal {
                rd: RA,
                to: "WasmDomFind".into(),
            },
            Op::Li { rd: T0, imm: -1 },
            Op::Beq {
                rs1: A0,
                rs2: T0,
                to: "domtext_alloc".into(),
            },
            Op::Addi {
                rd: T2,
                rs: A0,
                imm: 0,
            },
            jump("domtext_store"),
            Op::Label("domtext_alloc".into()),
            Op::La {
                rd: T0,
                addr: Addr::UiDom,
            },
            Op::Lw {
                rd: T1,
                rs: T0,
                off: 0,
            },
            Op::Li {
                rd: T2,
                imm: DOM_ROWS,
            },
            Op::Beq {
                rs1: T1,
                rs2: T2,
                to: "domtext_out".into(),
            },
            Op::Addi {
                rd: T3,
                rs: T1,
                imm: 1,
            },
            Op::Sw {
                rs2: T3,
                rs1: T0,
                off: 0,
            },
            Op::Addi {
                rd: T2,
                rs: T1,
                imm: 0,
            },
            Op::Slli {
                rd: T3,
                rs: T2,
                shamt: 5,
            },
            Op::Add {
                rd: T3,
                rs1: T0,
                rs2: T3,
            },
            Op::Addi {
                rd: T3,
                rs: T3,
                imm: DOM_HDR,
            },
            ld_x(xlen, T4, SP, 0),
            st_x(xlen, T4, T3, 0),
            ld_x(xlen, T4, SP, 8),
            Op::Sw {
                rs2: T4,
                rs1: T3,
                off: 16,
            },
            Op::Sw {
                rs2: X0,
                rs1: T3,
                off: 24,
            },
            Op::Label("domtext_store".into()),
            Op::La {
                rd: T0,
                addr: Addr::UiDom,
            },
            Op::Slli {
                rd: T3,
                rs: T2,
                shamt: 5,
            },
            Op::Add {
                rd: T3,
                rs1: T0,
                rs2: T3,
            },
            Op::Addi {
                rd: T3,
                rs: T3,
                imm: DOM_HDR,
            },
            ld_x(xlen, T4, SP, 16),
            st_x(xlen, T4, T3, 8),
            ld_x(xlen, T4, SP, 24),
            Op::Sw {
                rs2: T4,
                rs1: T3,
                off: 20,
            },
            Op::Li {
                rd: T4,
                imm: DOM_F_VISIBLE | DOM_F_TEXT,
            },
            Op::Sw {
                rs2: T4,
                rs1: T3,
                off: 24,
            },
            Op::Lw {
                rd: T4,
                rs: T0,
                off: 4,
            },
            Op::Addi {
                rd: T4,
                rs: T4,
                imm: 1,
            },
            Op::Sw {
                rs2: T4,
                rs1: T0,
                off: 4,
            },
            Op::Label("domtext_out".into()),
            ld_x(xlen, RA, SP, 40),
            Op::Addi {
                rd: SP,
                rs: SP,
                imm: 48,
            },
            ret(),
        ],
    }
}

/// `WasmDomVisible(a0=id_ptr, a1=id_len, a2=on)` — the `env.set_visible`
/// import: flips the visible flag; the row and its text are retained.
fn dom_visible_node(xlen: u32) -> Node {
    Node {
        purpose: Purpose::UiDom,
        ops: vec![
            Op::Comment("WasmDomVisible — env.set_visible import (row retained, flag only)".into()),
            Op::Glob("WasmDomVisible".into()),
            Op::Label("WasmDomVisible".into()),
            Op::Addi {
                rd: SP,
                rs: SP,
                imm: -32,
            },
            st_x(xlen, A0, SP, 0),
            st_x(xlen, A1, SP, 8),
            st_x(xlen, A2, SP, 16),
            st_x(xlen, RA, SP, 24),
            Op::Srli {
                rd: T0,
                rs: A1,
                shamt: signbit(xlen),
            },
            Op::Bne {
                rs1: T0,
                rs2: X0,
                to: "domvis_out".into(),
            },
            Op::Li {
                rd: T0,
                imm: DOM_ID_MAX,
            },
            Op::Sub {
                rd: T0,
                rs1: T0,
                rs2: A1,
            },
            Op::Srli {
                rd: T0,
                rs: T0,
                shamt: signbit(xlen),
            },
            Op::Bne {
                rs1: T0,
                rs2: X0,
                to: "domvis_out".into(),
            },
            Op::Jal {
                rd: RA,
                to: "WasmDomFind".into(),
            },
            Op::Li { rd: T0, imm: -1 },
            Op::Beq {
                rs1: A0,
                rs2: T0,
                to: "domvis_out".into(),
            },
            Op::La {
                rd: T0,
                addr: Addr::UiDom,
            },
            Op::Slli {
                rd: T3,
                rs: A0,
                shamt: 5,
            },
            Op::Add {
                rd: T3,
                rs1: T0,
                rs2: T3,
            },
            Op::Addi {
                rd: T3,
                rs: T3,
                imm: DOM_HDR,
            },
            Op::Lw {
                rd: T4,
                rs: T3,
                off: 24,
            },
            Op::Andi {
                rd: T4,
                rs: T4,
                imm: -2,
            },
            ld_x(xlen, T5, SP, 16),
            Op::Beq {
                rs1: T5,
                rs2: X0,
                to: "domvis_set".into(),
            },
            Op::Addi {
                rd: T4,
                rs: T4,
                imm: 1,
            },
            Op::Label("domvis_set".into()),
            Op::Sw {
                rs2: T4,
                rs1: T3,
                off: 24,
            },
            Op::Lw {
                rd: T4,
                rs: T0,
                off: 4,
            },
            Op::Addi {
                rd: T4,
                rs: T4,
                imm: 1,
            },
            Op::Sw {
                rs2: T4,
                rs1: T0,
                off: 4,
            },
            Op::Label("domvis_out".into()),
            ld_x(xlen, RA, SP, 24),
            Op::Addi {
                rd: SP,
                rs: SP,
                imm: 32,
            },
            ret(),
        ],
    }
}

/// `WasmPuts(a0=ptr, a1=len)` — bounded serial string (≤ DOM_PUTS_MAX bytes).
fn wasm_puts_node(xlen: u32) -> Node {
    Node {
        purpose: Purpose::UiDom,
        ops: vec![
            Op::Comment("WasmPuts — bounded serial string out (fail-closed)".into()),
            Op::Glob("WasmPuts".into()),
            Op::Label("WasmPuts".into()),
            Op::Addi {
                rd: T3,
                rs: A0,
                imm: 0,
            },
            Op::Addi {
                rd: T4,
                rs: A1,
                imm: 0,
            },
            Op::Srli {
                rd: T0,
                rs: T4,
                shamt: signbit(xlen),
            },
            Op::Bne {
                rs1: T0,
                rs2: X0,
                to: "wasmputs_out".into(),
            },
            Op::Li {
                rd: T0,
                imm: DOM_PUTS_MAX,
            },
            Op::Sub {
                rd: T0,
                rs1: T0,
                rs2: T4,
            },
            Op::Srli {
                rd: T0,
                rs: T0,
                shamt: signbit(xlen),
            },
            Op::Beq {
                rs1: T0,
                rs2: X0,
                to: "wasmputs_len".into(),
            },
            Op::Li {
                rd: T4,
                imm: DOM_PUTS_MAX,
            },
            Op::Label("wasmputs_len".into()),
            Op::Label("wasmputs_loop".into()),
            Op::Beq {
                rs1: T4,
                rs2: X0,
                to: "wasmputs_out".into(),
            },
            Op::Lbu {
                rd: A0,
                rs: T3,
                off: 0,
            },
            Op::Li {
                rd: A7,
                imm: SBI_PUTCHAR,
            },
            Op::Ecall,
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
            jump("wasmputs_loop"),
            Op::Label("wasmputs_out".into()),
            ret(),
        ],
    }
}

/// `WasmFetch(a0=url_ptr, a1=url_len)` — the `env.fetch` /
/// `Object_Call_string__Handle` import: `GET <path>` over serial, matching the
/// `GetFile` router shape (file bytes stay host/mailbox-side for now).
fn wasm_fetch_node(xlen: u32) -> Node {
    let mut ops = vec![
        Op::Comment("WasmFetch — env.fetch import → GET <path> (router shape)".into()),
        Op::Glob("WasmFetch".into()),
        Op::Label("WasmFetch".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -32,
        },
        st_x(xlen, A0, SP, 0),
        st_x(xlen, A1, SP, 8),
        st_x(xlen, RA, SP, 16),
    ];
    ops.extend(puts_str("GET "));
    ops.extend([
        ld_x(xlen, A0, SP, 0),
        ld_x(xlen, A1, SP, 8),
        Op::Jal {
            rd: RA,
            to: "WasmPuts".into(),
        },
    ]);
    ops.extend(putc(i64::from(b'\n')));
    ops.extend([
        ld_x(xlen, RA, SP, 16),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: 32,
        },
        ret(),
    ]);
    Node {
        purpose: Purpose::UiDom,
        ops,
    }
}

/// `WasmLog(a0=ptr, a1=len)` — the `env.console_log` import.
fn wasm_log_node(xlen: u32) -> Node {
    let mut ops = vec![
        Op::Comment("WasmLog — env.console_log import (bounded)".into()),
        Op::Glob("WasmLog".into()),
        Op::Label("WasmLog".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -32,
        },
        st_x(xlen, A0, SP, 0),
        st_x(xlen, A1, SP, 8),
        st_x(xlen, RA, SP, 16),
    ];
    ops.extend(puts_str("LOG "));
    ops.extend([
        ld_x(xlen, A0, SP, 0),
        ld_x(xlen, A1, SP, 8),
        Op::Jal {
            rd: RA,
            to: "WasmPuts".into(),
        },
    ]);
    ops.extend(putc(i64::from(b'\n')));
    ops.extend([
        ld_x(xlen, RA, SP, 16),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: 32,
        },
        ret(),
    ]);
    Node {
        purpose: Purpose::UiDom,
        ops,
    }
}

/// `DomPaint` — walk visible rows: `DOM| <text>` on serial, then 4bpp glyphs
/// at `__gr_plane` (x=0, y=DOM_Y0+p*8) when Gr/proxy is live.
fn dom_paint_node(spec: &BoardSpec) -> Node {
    let xlen = spec.isa.xlen;
    let gr_live = spec.kernel.gr.enable || spec.kernel.proxy.enable;
    let w = if spec.kernel.gr.enable {
        spec.kernel.gr.w.max(8)
    } else {
        640
    };
    let h = if spec.kernel.gr.enable {
        spec.kernel.gr.h.max(8)
    } else {
        480
    };
    let stride = i64::from(gr_stride(w, spec.kernel.gr.colors.max(16)));
    let paint_rows = ((i64::from(h) - DOM_Y0) / 8).clamp(0, DOM_ROWS);
    let mut ops = vec![
        Op::Comment(format!(
            "DomPaint — DOM| serial rows{}",
            if gr_live {
                " + 4bpp glyphs @ __gr_plane"
            } else {
                " (no Gr plane)"
            }
        )),
        Op::Glob("DomPaint".into()),
        Op::Label("DomPaint".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -64,
        },
        st_x(xlen, RA, SP, 56),
        st_x(xlen, S0, SP, 48),
        st_x(xlen, S1, SP, 40),
        st_x(xlen, S2, SP, 32),
        st_x(xlen, S3, SP, 24),
        st_x(xlen, S4, SP, 16),
        st_x(xlen, S5, SP, 8),
        Op::La {
            rd: S0,
            addr: Addr::UiDom,
        },
        Op::Lw {
            rd: S1,
            rs: S0,
            off: 0,
        },
        Op::Li { rd: S2, imm: 0 },
        Op::Li { rd: S3, imm: 0 },
        Op::Label("dom_row".into()),
        Op::Beq {
            rs1: S2,
            rs2: S1,
            to: "dom_done".into(),
        },
        Op::Li {
            rd: T0,
            imm: paint_rows,
        },
        Op::Beq {
            rs1: S3,
            rs2: T0,
            to: "dom_done".into(),
        },
        Op::Slli {
            rd: T3,
            rs: S2,
            shamt: 5,
        },
        Op::Add {
            rd: T3,
            rs1: S0,
            rs2: T3,
        },
        Op::Addi {
            rd: T3,
            rs: T3,
            imm: DOM_HDR,
        },
        Op::Lw {
            rd: T4,
            rs: T3,
            off: 24,
        },
        Op::Andi {
            rd: T4,
            rs: T4,
            imm: (DOM_F_VISIBLE | DOM_F_TEXT) as i32,
        },
        Op::Li {
            rd: T5,
            imm: DOM_F_VISIBLE | DOM_F_TEXT,
        },
        Op::Bne {
            rs1: T4,
            rs2: T5,
            to: "dom_next".into(),
        },
    ];
    ops.extend(puts_str("DOM| "));
    ops.extend([
        ld_x(xlen, T4, T3, 8),
        Op::Lw {
            rd: T5,
            rs: T3,
            off: 20,
        },
        // clamp text_len ≤ DOM_TEXT_MAX.
        Op::Li {
            rd: T0,
            imm: DOM_TEXT_MAX,
        },
        Op::Sub {
            rd: T0,
            rs1: T0,
            rs2: T5,
        },
        Op::Srli {
            rd: T0,
            rs: T0,
            shamt: signbit(xlen),
        },
        Op::Beq {
            rs1: T0,
            rs2: X0,
            to: "dom_len_ok".into(),
        },
        Op::Li {
            rd: T5,
            imm: DOM_TEXT_MAX,
        },
        Op::Label("dom_len_ok".into()),
        Op::Li { rd: T6, imm: 0 },
        Op::Label("dom_ser".into()),
        Op::Beq {
            rs1: T6,
            rs2: T5,
            to: "dom_ser_done".into(),
        },
        Op::Add {
            rd: T0,
            rs1: T4,
            rs2: T6,
        },
        Op::Lbu {
            rd: A0,
            rs: T0,
            off: 0,
        },
        Op::Li {
            rd: A7,
            imm: SBI_PUTCHAR,
        },
        Op::Ecall,
        Op::Addi {
            rd: T6,
            rs: T6,
            imm: 1,
        },
        jump("dom_ser"),
        Op::Label("dom_ser_done".into()),
    ]);
    ops.extend(putc(i64::from(b'\n')));
    if gr_live {
        ops.extend([
            // s4 = plane + header + (DOM_Y0 + p*8) * stride; s5 = stride.
            Op::La {
                rd: A3,
                addr: Addr::GrPlane,
            },
            Op::Addi {
                rd: A3,
                rs: A3,
                imm: GR_HEADER_BYTES as i32,
            },
            Op::Slli {
                rd: A4,
                rs: S3,
                shamt: 3,
            },
            Op::Addi {
                rd: A4,
                rs: A4,
                imm: DOM_Y0 as i32,
            },
            Op::Li {
                rd: A5,
                imm: stride,
            },
            Op::Mul {
                rd: A4,
                rs1: A4,
                rs2: A5,
            },
            Op::Add {
                rd: S4,
                rs1: A3,
                rs2: A4,
            },
            Op::Li {
                rd: S5,
                imm: stride,
            },
            ld_x(xlen, T4, T3, 8),
            Op::Lw {
                rd: T5,
                rs: T3,
                off: 20,
            },
            Op::Li {
                rd: T0,
                imm: DOM_TEXT_MAX,
            },
            Op::Sub {
                rd: T0,
                rs1: T0,
                rs2: T5,
            },
            Op::Srli {
                rd: T0,
                rs: T0,
                shamt: signbit(xlen),
            },
            Op::Beq {
                rs1: T0,
                rs2: X0,
                to: "dom_px_len".into(),
            },
            Op::Li {
                rd: T5,
                imm: DOM_TEXT_MAX,
            },
            Op::Label("dom_px_len".into()),
            Op::Li { rd: T6, imm: 0 },
            Op::Label("dom_px".into()),
            Op::Beq {
                rs1: T6,
                rs2: T5,
                to: "dom_px_done".into(),
            },
            // x byte bound: t6*4 <= stride-4.
            Op::Slli {
                rd: A0,
                rs: T6,
                shamt: 2,
            },
            Op::Li {
                rd: A1,
                imm: stride - 4,
            },
            Op::Sub {
                rd: A1,
                rs1: A1,
                rs2: A0,
            },
            Op::Srli {
                rd: A1,
                rs: A1,
                shamt: signbit(xlen),
            },
            Op::Bne {
                rs1: A1,
                rs2: X0,
                to: "dom_px_done".into(),
            },
            Op::Add {
                rd: A0,
                rs1: T4,
                rs2: T6,
            },
            Op::Lbu {
                rd: A0,
                rs: A0,
                off: 0,
            },
            // glyph index: ch in [0x20,0x7E] → ch-0x20 else box.
            Op::Addi {
                rd: A1,
                rs: A0,
                imm: -0x20,
            },
            Op::Srli {
                rd: A2,
                rs: A1,
                shamt: signbit(xlen),
            },
            Op::Bne {
                rs1: A2,
                rs2: X0,
                to: "dom_px_box".into(),
            },
            Op::Addi {
                rd: A2,
                rs: A0,
                imm: -0x7F,
            },
            Op::Srli {
                rd: A2,
                rs: A2,
                shamt: signbit(xlen),
            },
            Op::Beq {
                rs1: A2,
                rs2: X0,
                to: "dom_px_box".into(),
            },
            jump("dom_px_glyph"),
            Op::Label("dom_px_box".into()),
            Op::Li {
                rd: A1,
                imm: i64::from(FONT_BOX),
            },
            Op::Label("dom_px_glyph".into()),
            Op::La {
                rd: A2,
                addr: Addr::UiFont,
            },
            Op::Slli {
                rd: A1,
                rs: A1,
                shamt: 3,
            },
            Op::Add {
                rd: A4,
                rs1: A2,
                rs2: A1,
            },
            Op::Li { rd: A5, imm: 0 },
            Op::Label("dom_gy".into()),
            Op::Add {
                rd: A0,
                rs1: A4,
                rs2: A5,
            },
            Op::Lbu {
                rd: A2,
                rs: A0,
                off: 0,
            },
            Op::Li { rd: A3, imm: 0 },
            Op::Li { rd: A6, imm: 0 },
            Op::Label("dom_byte".into()),
            Op::Li { rd: A1, imm: 0 },
            Op::Andi {
                rd: A0,
                rs: A2,
                imm: 1,
            },
            Op::Beq {
                rs1: A0,
                rs2: X0,
                to: "dom_nb0".into(),
            },
            Op::Addi {
                rd: A1,
                rs: A1,
                imm: 0x0F,
            },
            Op::Label("dom_nb0".into()),
            Op::Srli {
                rd: A2,
                rs: A2,
                shamt: 1,
            },
            Op::Andi {
                rd: A0,
                rs: A2,
                imm: 1,
            },
            Op::Beq {
                rs1: A0,
                rs2: X0,
                to: "dom_nb1".into(),
            },
            Op::Addi {
                rd: A1,
                rs: A1,
                imm: 0xF0,
            },
            Op::Label("dom_nb1".into()),
            Op::Srli {
                rd: A2,
                rs: A2,
                shamt: 1,
            },
            Op::Slli {
                rd: A3,
                rs: A3,
                shamt: 8,
            },
            Op::Add {
                rd: A3,
                rs1: A3,
                rs2: A1,
            },
            Op::Addi {
                rd: A6,
                rs: A6,
                imm: 1,
            },
            Op::Li { rd: A0, imm: 4 },
            Op::Bne {
                rs1: A6,
                rs2: A0,
                to: "dom_byte".into(),
            },
            // addr = s4 + gy*stride + char*4.
            Op::Mul {
                rd: A0,
                rs1: A5,
                rs2: S5,
            },
            Op::Add {
                rd: A0,
                rs1: A0,
                rs2: S4,
            },
            Op::Slli {
                rd: A1,
                rs: T6,
                shamt: 2,
            },
            Op::Add {
                rd: A0,
                rs1: A0,
                rs2: A1,
            },
            Op::Sw {
                rs2: A3,
                rs1: A0,
                off: 0,
            },
            Op::Addi {
                rd: A5,
                rs: A5,
                imm: 1,
            },
            Op::Li { rd: A0, imm: 8 },
            Op::Bne {
                rs1: A5,
                rs2: A0,
                to: "dom_gy".into(),
            },
            Op::Addi {
                rd: T6,
                rs: T6,
                imm: 1,
            },
            jump("dom_px"),
            Op::Label("dom_px_done".into()),
        ]);
    }
    ops.extend([
        Op::Addi {
            rd: S3,
            rs: S3,
            imm: 1,
        },
        Op::Label("dom_next".into()),
        Op::Addi {
            rd: S2,
            rs: S2,
            imm: 1,
        },
        jump("dom_row"),
        Op::Label("dom_done".into()),
        ld_x(xlen, S5, SP, 8),
        ld_x(xlen, S4, SP, 16),
        ld_x(xlen, S3, SP, 24),
        ld_x(xlen, S2, SP, 32),
        ld_x(xlen, S1, SP, 40),
        ld_x(xlen, S0, SP, 48),
        ld_x(xlen, RA, SP, 56),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: 64,
        },
        ret(),
    ]);
    Node {
        purpose: Purpose::UiDom,
        ops,
    }
}

/// `DomPaint32` — walk visible rows: `DOM| <text>` on serial, then 32bpp glyphs
/// directly into `__scan_fb` at the resolved high-res geometry.
///
/// This is the GPU-surface native text path: instead of sourcing the 8×8
/// low-res `__gr_plane` through `FbExpand1`, it paints the same DOM rows into
/// the X8R8G8B8 scanout. The font stays 8×8, but the column count is the
/// native `high_w / 8` rather than the low-res `DOM_TEXT_MAX`, so a single row
/// can use more of the screen width. Source rows are still bounded (`DOM_ROWS`,
/// `DOM_TEXT_MAX`), so a row longer than the screen width is truncated.
fn dom_paint32_node(spec: &BoardSpec) -> Node {
    let xlen = spec.isa.xlen;
    let mut ops = vec![
        Op::Comment(
            "DomPaint32 — DOM| serial rows + 32bpp glyphs @ __scan_fb; geometry \
             from __disp (runtime-selected output)"
                .to_string(),
        ),
        Op::Glob("DomPaint32".into()),
        Op::Label("DomPaint32".into()),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: -96,
        },
        st_x(xlen, RA, SP, 88),
        st_x(xlen, S0, SP, 80),
        st_x(xlen, S1, SP, 72),
        st_x(xlen, S2, SP, 64),
        st_x(xlen, S3, SP, 56),
        st_x(xlen, S4, SP, 48),
        st_x(xlen, S5, SP, 40),
        st_x(xlen, S6, SP, 32),
        st_x(xlen, S7, SP, 24),
        st_x(xlen, S8, SP, 16),
        st_x(xlen, S9, SP, 8),
        // s0 = __ui_dom, s1 = dest fb, s2 = w, s3 = h, s4 = stride,
        // s5 = paint row, s6 = row count, s7 = DOM row index. Geometry comes
        // from `__disp` (DispSel's latch), not the gen-time proxy default, so
        // the native painter follows the resolved output. The destination is
        // the output's own linear window when `DispSel` latched one (the
        // pcie-linear-fb rung stores the accepted BAR in `DISP_SEL_FB_LO`),
        // else the shared `__scan_fb` the virtio/uncore transports commit.
        Op::La {
            rd: S0,
            addr: Addr::UiDom,
        },
        Op::La {
            rd: T5,
            addr: Addr::VioBss,
        },
        lw(S2, T5, crate::vio::DISP_SEL_W),
        lw(S3, T5, crate::vio::DISP_SEL_H),
        lw(S4, T5, crate::vio::DISP_SEL_STRIDE),
        lw(S1, T5, crate::vio::DISP_SEL_FB_LO),
        Op::Bne {
            rs1: S1,
            rs2: X0,
            to: "dp32_dst".into(),
        },
        Op::La {
            rd: S1,
            addr: Addr::ScanFb,
        },
        Op::Label("dp32_dst".into()),
        // paint_rows = clamp((h - DOM_Y0) >> 3, 0, DOM_ROWS). h is u32;
        // a negative difference would come out of the sign-bit check.
        Op::Addi {
            rd: S8,
            rs: S3,
            imm: -DOM_Y0 as i32,
        },
        Op::Srli {
            rd: T0,
            rs: S8,
            shamt: signbit(xlen),
        },
        Op::Bne {
            rs1: T0,
            rs2: X0,
            to: "dp32_rows_zero".into(),
        },
        Op::Srli {
            rd: S8,
            rs: S8,
            shamt: 3,
        },
        Op::Li {
            rd: T0,
            imm: DOM_ROWS,
        },
        Op::Sltu {
            rd: T1,
            rs1: T0,
            rs2: S8,
        },
        Op::Beq {
            rs1: T1,
            rs2: X0,
            to: "dp32_rows_ok".into(),
        },
        Op::Addi {
            rd: S8,
            rs: T0,
            imm: 0,
        },
        jump("dp32_rows_ok"),
        Op::Label("dp32_rows_zero".into()),
        Op::Li { rd: S8, imm: 0 },
        Op::Label("dp32_rows_ok".into()),
        // cols = clamp(w >> 3, 1, 1024). w ≥ 8 on every spec path, so the low
        // clamp is defensive; the high clamp matches the serial row bound.
        Op::Srli {
            rd: S9,
            rs: S2,
            shamt: 3,
        },
        Op::Li { rd: T0, imm: 1 },
        Op::Sltu {
            rd: T1,
            rs1: S9,
            rs2: T0,
        },
        Op::Beq {
            rs1: T1,
            rs2: X0,
            to: "dp32_cols_hi".into(),
        },
        Op::Li { rd: S9, imm: 1 },
        Op::Label("dp32_cols_hi".into()),
        Op::Li { rd: T0, imm: 1024 },
        Op::Sltu {
            rd: T1,
            rs1: T0,
            rs2: S9,
        },
        Op::Beq {
            rs1: T1,
            rs2: X0,
            to: "dp32_cols_ok".into(),
        },
        Op::Li { rd: S9, imm: 1024 },
        Op::Label("dp32_cols_ok".into()),
        Op::Li { rd: S5, imm: 0 },
        // Clear __scan_fb to black; total_words = w*h is runtime.
        Op::Mul {
            rd: T0,
            rs1: S2,
            rs2: S3,
        },
        Op::Li { rd: T1, imm: 0 },
        Op::Label("dp32_clear".into()),
        Op::Beq {
            rs1: T1,
            rs2: T0,
            to: "dp32_done_clear".into(),
        },
        Op::Slli {
            rd: T2,
            rs: T1,
            shamt: 2,
        },
        Op::Add {
            rd: T2,
            rs1: T2,
            rs2: S1,
        },
        Op::Sw {
            rs2: X0,
            rs1: T2,
            off: 0,
        },
        Op::Addi {
            rd: T1,
            rs: T1,
            imm: 1,
        },
        jump("dp32_clear"),
        Op::Label("dp32_done_clear".into()),
        Op::Lw {
            rd: S6,
            rs: S0,
            off: 0,
        },
        Op::Li { rd: S7, imm: 0 },
        Op::Li { rd: S5, imm: 0 },
        Op::Label("dp32_row".into()),
        Op::Beq {
            rs1: S5,
            rs2: S8,
            to: "dp32_done".into(),
        },
        Op::Beq {
            rs1: S7,
            rs2: S6,
            to: "dp32_done".into(),
        },
        Op::Slli {
            rd: T3,
            rs: S7,
            shamt: 5,
        },
        Op::Add {
            rd: T3,
            rs1: T3,
            rs2: S0,
        },
        Op::Addi {
            rd: T3,
            rs: T3,
            imm: DOM_HDR,
        },
        Op::Lw {
            rd: T4,
            rs: T3,
            off: 24,
        },
        Op::Andi {
            rd: T4,
            rs: T4,
            imm: (DOM_F_VISIBLE | DOM_F_TEXT) as i32,
        },
        Op::Li {
            rd: T5,
            imm: DOM_F_VISIBLE | DOM_F_TEXT,
        },
        Op::Bne {
            rs1: T4,
            rs2: T5,
            to: "dp32_next".into(),
        },
    ];
    ops.extend(puts_str("DOM| "));
    ops.extend([
        ld_x(xlen, T4, T3, 8),
        Op::Lw {
            rd: T5,
            rs: T3,
            off: 20,
        },
        // clamp text_len ≤ cols.
        Op::Sub {
            rd: T0,
            rs1: S9,
            rs2: T5,
        },
        Op::Srli {
            rd: T0,
            rs: T0,
            shamt: signbit(xlen),
        },
        Op::Beq {
            rs1: T0,
            rs2: X0,
            to: "dp32_len_ok".into(),
        },
        Op::Addi {
            rd: T5,
            rs: S9,
            imm: 0,
        },
        Op::Label("dp32_len_ok".into()),
        Op::Li { rd: T6, imm: 0 },
        Op::Label("dp32_ser".into()),
        Op::Beq {
            rs1: T6,
            rs2: T5,
            to: "dp32_ser_done".into(),
        },
        Op::Add {
            rd: T0,
            rs1: T4,
            rs2: T6,
        },
        Op::Lbu {
            rd: A0,
            rs: T0,
            off: 0,
        },
        Op::Li {
            rd: A7,
            imm: SBI_PUTCHAR,
        },
        Op::Ecall,
        Op::Addi {
            rd: T6,
            rs: T6,
            imm: 1,
        },
        jump("dp32_ser"),
        Op::Label("dp32_ser_done".into()),
    ]);
    ops.extend(putc(i64::from(b'\n')));
    // 32bpp glyph paint for this row.
    ops.extend([
        // row_y = DOM_Y0 + paint_row * 8; row_base = __scan_fb + row_y * stride.
        Op::Slli {
            rd: A6,
            rs: S5,
            shamt: 3,
        },
        Op::Addi {
            rd: A6,
            rs: A6,
            imm: DOM_Y0 as i32,
        },
        Op::Mul {
            rd: A6,
            rs1: A6,
            rs2: S4,
        },
        Op::Add {
            rd: A6,
            rs1: S1,
            rs2: A6,
        },
        // reload text pointer and clamped length for the pixel loop.
        ld_x(xlen, T4, T3, 8),
        Op::Lw {
            rd: T5,
            rs: T3,
            off: 20,
        },
        Op::Sub {
            rd: T0,
            rs1: S9,
            rs2: T5,
        },
        Op::Srli {
            rd: T0,
            rs: T0,
            shamt: signbit(xlen),
        },
        Op::Beq {
            rs1: T0,
            rs2: X0,
            to: "dp32_px_len".into(),
        },
        Op::Addi {
            rd: T5,
            rs: S9,
            imm: 0,
        },
        Op::Label("dp32_px_len".into()),
        Op::Li { rd: T6, imm: 0 },
        Op::Label("dp32_px".into()),
        Op::Beq {
            rs1: T6,
            rs2: T5,
            to: "dp32_px_done".into(),
        },
        // a0 = ch, then a1 = glyph index.
        Op::Add {
            rd: A0,
            rs1: T4,
            rs2: T6,
        },
        Op::Lbu {
            rd: A0,
            rs: A0,
            off: 0,
        },
        Op::Addi {
            rd: A1,
            rs: A0,
            imm: -0x20,
        },
        Op::Srli {
            rd: A2,
            rs: A1,
            shamt: signbit(xlen),
        },
        Op::Bne {
            rs1: A2,
            rs2: X0,
            to: "dp32_px_box".into(),
        },
        Op::Addi {
            rd: A2,
            rs: A0,
            imm: -0x7F,
        },
        Op::Srli {
            rd: A2,
            rs: A2,
            shamt: signbit(xlen),
        },
        Op::Beq {
            rs1: A2,
            rs2: X0,
            to: "dp32_px_box".into(),
        },
        jump("dp32_px_glyph"),
        Op::Label("dp32_px_box".into()),
        Op::Li {
            rd: A1,
            imm: i64::from(FONT_BOX),
        },
        Op::Label("dp32_px_glyph".into()),
        // a3 = font base = __font + glyph_index * 8.
        Op::La {
            rd: A3,
            addr: Addr::UiFont,
        },
        Op::Slli {
            rd: A1,
            rs: A1,
            shamt: 3,
        },
        Op::Add {
            rd: A3,
            rs1: A3,
            rs2: A1,
        },
        // a2 = destination base for this character = row_base + col * 32.
        Op::Slli {
            rd: A1,
            rs: T6,
            shamt: 5,
        },
        Op::Add {
            rd: A2,
            rs1: A6,
            rs2: A1,
        },
        Op::Li {
            rd: A7,
            imm: 0x00FF_FFFF,
        },
        Op::Li { rd: A4, imm: 0 },
        Op::Label("dp32_gy".into()),
        Op::Add {
            rd: A1,
            rs1: A3,
            rs2: A4,
        },
        Op::Lbu {
            rd: A0,
            rs: A1,
            off: 0,
        },
        Op::Li { rd: A5, imm: 0 },
        Op::Label("dp32_gx".into()),
        Op::Andi {
            rd: A1,
            rs: A0,
            imm: 0x80,
        },
        Op::Beq {
            rs1: A1,
            rs2: X0,
            to: "dp32_nb".into(),
        },
        Op::Sw {
            rs2: A7,
            rs1: A2,
            off: 0,
        },
        Op::Label("dp32_nb".into()),
        Op::Slli {
            rd: A0,
            rs: A0,
            shamt: 1,
        },
        Op::Addi {
            rd: A2,
            rs: A2,
            imm: 4,
        },
        Op::Addi {
            rd: A5,
            rs: A5,
            imm: 1,
        },
        Op::Li { rd: A1, imm: 8 },
        Op::Bne {
            rs1: A5,
            rs2: A1,
            to: "dp32_gx".into(),
        },
        // next glyph row: back to the start of this char column, then + stride.
        Op::Addi {
            rd: A2,
            rs: A2,
            imm: -32,
        },
        Op::Add {
            rd: A2,
            rs1: A2,
            rs2: S4,
        },
        Op::Addi {
            rd: A4,
            rs: A4,
            imm: 1,
        },
        Op::Li { rd: A1, imm: 8 },
        Op::Bne {
            rs1: A4,
            rs2: A1,
            to: "dp32_gy".into(),
        },
        Op::Addi {
            rd: T6,
            rs: T6,
            imm: 1,
        },
        jump("dp32_px"),
        Op::Label("dp32_px_done".into()),
        Op::Addi {
            rd: S5,
            rs: S5,
            imm: 1,
        },
        Op::Label("dp32_next".into()),
        Op::Addi {
            rd: S7,
            rs: S7,
            imm: 1,
        },
        jump("dp32_row"),
        Op::Label("dp32_done".into()),
        ld_x(xlen, S9, SP, 8),
        ld_x(xlen, S8, SP, 16),
        ld_x(xlen, S7, SP, 24),
        ld_x(xlen, S6, SP, 32),
        ld_x(xlen, S5, SP, 40),
        ld_x(xlen, S4, SP, 48),
        ld_x(xlen, S3, SP, 56),
        ld_x(xlen, S2, SP, 64),
        ld_x(xlen, S1, SP, 72),
        ld_x(xlen, S0, SP, 80),
        ld_x(xlen, RA, SP, 88),
        Op::Addi {
            rd: SP,
            rs: SP,
            imm: 96,
        },
        ret(),
    ]);
    Node {
        purpose: Purpose::UiDom,
        ops,
    }
}

/// Attach the DOM service to `module` when `kernel.wasm.jit` is live:
/// BSS row table + first-party font (font only when a Gr plane exists).
pub fn attach(module: &mut Module, spec: &BoardSpec) {
    module.dom_bytes = UI_DOM_BYTES;
    if spec.kernel.gr.enable || spec.kernel.proxy.enable {
        module.font = crate::font::font_bytes();
    }
    for n in nodes(spec) {
        module.push(n);
    }
}
