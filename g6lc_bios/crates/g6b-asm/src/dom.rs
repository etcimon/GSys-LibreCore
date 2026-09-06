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
    A0, A1, A2, A3, A4, A5, A6, A7, RA, S0, S1, S2, S3, S4, S5, SBI_PUTCHAR, SP, T0, T1, T2, T3,
    T4, T5, T6, X0,
};
use crate::font::FONT_BOX;
use crate::{gr_stride, Addr, Module, Node, Op, Purpose, GR_HEADER_BYTES};

/// Bounded DOM rows (`lirx-dom`-shaped; not a general allocator).
pub const DOM_ROWS: i64 = 48;
/// One row: id_ptr(x) +8 text_ptr(x) +16 id_len(u32) +20 text_len(u32) +24 flags(u32).
pub const DOM_ROW_BYTES: i64 = 32;
/// Table header: +0 count(u32), +4 dirty(u32).
pub const DOM_HDR: i32 = 16;
/// `__ui_dom` BSS size.
pub const UI_DOM_BYTES: u64 = 16 + 48 * 32;
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

fn signbit(xlen: u32) -> u32 {
    xlen.saturating_sub(1)
}

/// DOM service nodes for `payload` when `kernel.wasm.jit` is live.
/// `WasmStart` ships as a `ret` stub; `g6b-elf` replaces its ops with
/// `g6b_wasm::jit::start_ops` output so the label always resolves.
pub fn nodes(spec: &BoardSpec) -> Vec<Node> {
    let xlen = spec.isa.xlen;
    vec![
        wasm_ui_node(xlen),
        wasm_start_stub_node(),
        dom_find_node(xlen),
        dom_text_node(xlen),
        dom_visible_node(xlen),
        wasm_puts_node(xlen),
        wasm_fetch_node(xlen),
        wasm_log_node(xlen),
        dom_paint_node(spec),
    ]
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
