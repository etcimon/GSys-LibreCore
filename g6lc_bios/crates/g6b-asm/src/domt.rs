// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! M2 guest DOM tree — a real bounded node store at `__dom` plus a
//! bump-allocated string pool at `__dom_str`, the DOM-op routines the JIT'd
//! cell reaches through `env.*` EXT trampolines, a bounded block layout that
//! computes per-node rects, and a raster pass that paints dirty nodes into
//! the 32bpp `__scan_fb` at the `__disp` geometry.
//!
//! This is the genuine tree the browser face drives — not the bounded
//! `__ui_dom` *row* table the text/CLI face uses. A node is a fixed 64-byte
//! record (tag, links, text, two colors, one listener, one dirty bit, one
//! laid-out rect); handles are stable pool indices. Everything is bounded:
//! `DOMT_NODES` records, `DOMT_STR` pool bytes, `DOMT_TEXT` bytes per node,
//! `DOMT_DEPTH` block nesting, `DOMT_GLYPH` painted characters per text node.

#![allow(missing_docs)]

use g6b_spec::BoardSpec;

use crate::encode::{
    A0, A1, A2, A3, A4, A5, A6, A7, RA, S0, S1, S2, S3, S4, S5, S6, S7, S8, S9, SBI_PUTCHAR, SP,
    T0, T1, T2, T3, T4, T5, T6, X0,
};
use crate::jfmt::{AX_DATA_GLOB, AX_STATE_GLOB};
use crate::jitr::{OFF_GLOB, OFF_MEMB};
use crate::kget::{
    KGET_ASTK_BYTES, KGET_ENT, KGET_E_JSON_LEN, KGET_E_JSON_OFF, KGET_E_URL_LEN, KGET_E_URL_OFF,
    KGET_HDR, KGET_KSTR_BYTES, KGET_MAGIC, KGET_OFF_N, KGET_TAIL_BYTES,
};
use crate::{Addr, Module, Node, Op, Purpose};

/// Node pool bound (records; index 0 is the root, allocated by `DomtInit`).
/// Sized for the full shipped-cell DOM: ~80 static elements + every menu's
/// `items[]` rows (3 nodes each — tr/td/td) + text nodes — a few hundred.
pub const DOMT_NODES: i64 = 1024;
/// Bytes per node record.
pub const DOMT_NODE: i64 = 64;
/// Header bytes at `__dom` before node records.
pub const DOMT_HDR: i64 = 64;
/// `__dom` BSS size: header + `DOMT_NODES` records.
pub const DOMT_BYTES: u64 = (DOMT_HDR + DOMT_NODES * DOMT_NODE) as u64;
/// `__dom_str` pool bytes (bump-allocated text/id content).
pub const DOMT_STR_BYTES: u64 = 32768;
/// `__dom_id` per-node slot bytes: `[len:u32][bytes:≤28]` inline element id.
pub const DOMT_ID_SLOT: u64 = 32;
/// `__dom_id` BSS size: one slot per node.
pub const DOMT_ID_BYTES: u64 = (DOMT_NODES as u64) * DOMT_ID_SLOT;
/// Painted characters per text node.
pub const DOMT_TEXT: i64 = 96;
/// Block-nesting bound for layout recursion.
pub const DOMT_DEPTH: i64 = 24;
/// Magic at `__dom+0`.
pub const DOMT_MAGIC: i64 = 0x4736_4454; // 'G6DT'

// header offsets (i32, fit addi/lw)
pub const H_MAGIC: i32 = 0;
pub const H_NEXT: i32 = 4; // bump-alloc: next free node index
pub const H_STR: i32 = 8; // __dom_str bump cursor (bytes used)
pub const H_DIRTY: i32 = 12; // count of dirty nodes (nonzero => repaint)
pub const H_FOCUS: i32 = 16; // focused node index (key listener target)
pub const H_NRECT: i32 = 20; // laid-out node count this pass
/// `__dom+24` — requested `__web_dl` state index (menu the hit dispatch
/// wants on screen). Lives in the dom header because `__uart_line` is full
/// and `__dom` exists exactly when `DlPaint` does.
pub const H_WST: i32 = 24;
/// `__dom+28` — the state `DlPaint` last painted; a repaint is due when it
/// differs from `H_WST` (or no canvas is live yet).
pub const H_DLS: i32 = 28;
/// `__dom+32` — `__kget` byte offset of the *current* resolved fetch body
/// (`LwAwaitVoid` records it; `LwAwaitVal` copies it into `__wasm_mem`).
pub const H_KCUR_OFF: i32 = 32;
/// `__dom+36` — length of the current resolved fetch body.
pub const H_KCUR_LEN: i32 = 36;
/// `__dom+40` — `libwasm_await_value` string-pool bump cursor (bytes used
/// past `mem_pages*64K` in `__wasm_mem`).
pub const H_KSTR_CUR: i32 = 40;

// node-record field offsets
pub const N_TAG: i32 = 0;
pub const N_FLAGS: i32 = 4;
pub const N_PARENT: i32 = 8;
pub const N_FC: i32 = 12;
pub const N_LC: i32 = 16;
pub const N_NSIB: i32 = 20;
pub const N_TPTR: i32 = 24;
pub const N_TLEN: i32 = 28;
pub const N_BG: i32 = 32;
pub const N_FG: i32 = 36;
pub const N_LISTEN: i32 = 40;
pub const N_LEV: i32 = 44;
pub const N_X: i32 = 48;
pub const N_Y: i32 = 52;
pub const N_W: i32 = 56;
pub const N_H: i32 = 60;

/// Tag values.
pub const TAG_FREE: i64 = 0;
pub const TAG_ROOT: i64 = 1;
pub const TAG_ELEM: i64 = 2;
pub const TAG_TEXT: i64 = 3;
/// Bias applied to a libwasm `NodeType` ordinal before it rides in `N_TAG`, so
/// a `0` ordinal still stores nonzero (the raster's free-check is `N_TAG != 0`)
/// and the value never collides with `TAG_ROOT/ELEM/TEXT`. Recover the ordinal
/// as `N_TAG - TAG_LW` when mapping back through `LIBWASM_TAGS`.
pub const TAG_LW: i64 = 4;

/// flags bits.
pub const F_VIS: i64 = 1;
pub const F_DIRTY: i64 = 2;
pub const F_TEXT: i64 = 4;

/// "no node" sentinel for link fields (0 is a valid index — the root — so
/// empty links use the all-ones sentinel instead).
pub const NONE: i64 = -1;

/// Event-mask bits for `DomtListen` / `DomtKey` dispatch.
pub const EV_KEYDOWN: i64 = 1;
pub const EV_CLICK: i64 = 2;

/// `N_LISTEN` selector for the bounded builtin key handler the M2 demo wires:
/// `DomtKey` reads the focused node's `N_LISTEN` and routes `LSN_DEMO` to
/// `DomtDemo` (recolor). `0` = no listener / BIOS protocol; `>= 0x100` is a
/// JIT'd-cell funcidx re-entered via `JitCall` (value = `0x100 + funcidx`, so
/// `N_LISTEN - LSN_FUNC` recovers the `ftab` index).
pub const LSN_DEMO: i64 = 1;
/// `N_LISTEN` bias marking a wasm `add_event_listener` funcidx: `cb != 0`
/// stores `0x100 + cb` so the reserved low band (`0` BIOS protocol, `LSN_DEMO`)
/// can't alias a real function index. `DomtKey` subtracts it before `JitCall`.
pub const LSN_FUNC: i64 = 0x100;

// `__ev_obj` field offsets — the bounded event record `DomtKey` fills before
// `JitCall`-ing a wasm listener; the delegate receives `__ev_obj`'s address as
// the event handle (`add_event_listener` → `Listener::Wasm` → `fn(handle)`).
pub const EVO_TYPE: i32 = 0; // event mask that fired (EV_KEYDOWN / EV_CLICK)
pub const EVO_CODE: i32 = 4; // virtio-input EV_KEY code (keycode)
pub const EVO_VALUE: i32 = 8; // press/release value
pub const EVO_CX: i32 = 12; // clientX (0 for key events)
pub const EVO_CY: i32 = 16; // clientY (0 for key events)
pub const EVO_TARGET: i32 = 20; // target node handle (index+1)
pub const EVO_PD: i32 = 24; // defaultPrevented flag — `preventDefault` write-back
pub const EVOBJ_BYTES: u64 = 64;

// `__prom` — the bounded guest promise-object table (the guest-side correlate
// of the interpreter's `ObjectTable` promise subset). `LwFetch` allocates a
// record per call instead of returning a raw `__kget` index; `LwAwaitVoid`
// consults the record's settle state so a fetch can fulfill *or reject*, and
// `PromDrain` settles genuinely-pending records before resuming a suspended
// `_start`. A promise handle is the record index +1 (0 = null/unresolved).
pub const PROM_MAGIC: i64 = 0x4736_5052; // 'G6PR'
/// `__prom` header bytes: `[magic][n_alloc][afail][alast][asusp][rsvd×3]`.
pub const PROM_HDR: i32 = 32;
/// Bounded record cap — a fetch storm fails closed (handle 0) past this. The
/// shipped cell issues ~8 fetches; a combinator adds one array + one result
/// record per `libasync_promise_*` call. Records bump-allocate and are not
/// reclaimed (no `release`/`free` in the await contract), so this is a fixed
/// ceiling on total promises for the cell's lifetime — 64 gives the shipped
/// path ~8× headroom while staying a ~3KB BSS region.
pub const PROM_MAX: i64 = 64;
/// Per-record bytes.
pub const PROM_REC: i32 = 48;
/// `__prom` BSS size: header + `PROM_MAX` records.
pub const PROM_BYTES: u64 = (PROM_HDR as u64) + (PROM_MAX as u64) * (PROM_REC as u64);

// `__prom` header offsets
pub const P_MAGIC: i32 = 0; // 'G6PR'
pub const P_N: i32 = 4; // n_alloc (next free record index)
pub const P_AFAIL: i32 = 8; // 1 if the last awaited promise rejected
pub const P_ALAST: i32 = 12; // last-awaited promise handle (for await_error)
pub const P_ASUSP: i32 = 16; // promise handle the cell is suspended on (0=none)
/// `__prom+20` — set by `PromDrain` when a suspended `_start`'s promise
/// settled; the foreground loop re-invokes the cell to complete the rewind.
pub const P_RESUME: i32 = 20;

// `__prom` record offsets
pub const PR_STATE: i32 = 0; // PROM_ST_*
pub const PR_KIND: i32 = 4; // PROM_K_*
pub const PR_VOFF: i32 = 8; // fulfilled: __kget body off | array: __wasm_mem elem off
pub const PR_VLEN: i32 = 12; // body len | elem count
pub const PR_EOFF: i32 = 16; // rejected reason __wasm_mem off (the failing url)
pub const PR_ELEN: i32 = 20; // reason len
pub const PR_AOFF: i32 = 24; // pending fetch url __wasm_mem off | combinator input-array handle
pub const PR_ALEN: i32 = 28; // url len | combinator input count
pub const PR_SUB: i32 = 32; // combinator remaining-unsettled count
pub const PR_BUDGET: i32 = 36; // pending poll countdown → reject at 0

/// Settle states.
pub const PROM_ST_FREE: i64 = 0;
pub const PROM_ST_PEND: i64 = 1;
pub const PROM_ST_FUL: i64 = 2;
pub const PROM_ST_REJ: i64 = 3;
/// Record kinds.
pub const PROM_K_FETCH: i64 = 0;
pub const PROM_K_ALL: i64 = 1;
pub const PROM_K_ANY: i64 = 2;
pub const PROM_K_ALLS: i64 = 3;
pub const PROM_K_IARR: i64 = 4; // i32 handle-array (combinator input / allSettled result)
/// Pending-poll budget: a pending fetch settles on the next `PromDrain` tick,
/// so the budget is a fail-closed ceiling, not a latency estimate.
pub const PROM_BUDGET: i64 = 64;

/// Text cell metrics: an 8×8 `__font` glyph at `DOMT_CELL`px pitch.
pub const DOMT_CELL: i64 = 8;
/// Block-flow margins.
pub const DOMT_MX: i64 = 16;
pub const DOMT_MY: i64 = 24;

// ---- local Op builders (dom.rs conventions) --------------------------------

fn ld(rd: u32, rs: u32, off: i32) -> Op {
    Op::Ld { rd, rs, off }
}
fn sd(rs2: u32, rs1: u32, off: i32) -> Op {
    Op::Sd { rs2, rs1, off }
}
fn lw(rd: u32, rs: u32, off: i32) -> Op {
    Op::Lw { rd, rs, off }
}
fn sw(rs2: u32, rs1: u32, off: i32) -> Op {
    Op::Sw { rs2, rs1, off }
}
fn lbu(rd: u32, rs: u32, off: i32) -> Op {
    Op::Lbu { rd, rs, off }
}
fn sb(rs2: u32, rs1: u32, off: i32) -> Op {
    Op::Sb { rs2, rs1, off }
}
fn addi(rd: u32, rs: u32, imm: i32) -> Op {
    Op::Addi { rd, rs, imm }
}
fn add(rd: u32, a: u32, b: u32) -> Op {
    Op::Add { rd, rs1: a, rs2: b }
}
fn sub(rd: u32, a: u32, b: u32) -> Op {
    Op::Sub { rd, rs1: a, rs2: b }
}
fn and_(rd: u32, a: u32, b: u32) -> Op {
    Op::And { rd, rs: a, rs2: b }
}
fn or_(rd: u32, a: u32, b: u32) -> Op {
    Op::Or { rd, rs: a, rs2: b }
}
fn slli(rd: u32, rs: u32, shamt: u32) -> Op {
    Op::Slli { rd, rs, shamt }
}
fn srli(rd: u32, rs: u32, shamt: u32) -> Op {
    Op::Srli { rd, rs, shamt }
}
fn mul(rd: u32, a: u32, b: u32) -> Op {
    Op::Mul { rd, rs1: a, rs2: b }
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
fn bltu(a: u32, b: u32, to: &str) -> Op {
    Op::Bltu {
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
fn bgeu(a: u32, b: u32, to: &str) -> Op {
    Op::Bgeu {
        rs1: a,
        rs2: b,
        to: to.into(),
    }
}
fn jal(to: &str) -> Op {
    Op::Jal {
        rd: RA,
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
/// `node_addr` — `rd` = `__dom + DOMT_HDR + idx*64` for node index `idx`.
/// `T5` is the scratch base, so `rd` may be `T6` (callers' address reg).
fn node_addr(ops: &mut Vec<Op>, rd: u32, idx: u32) {
    ops.push(slli(rd, idx, 6)); // *64
    ops.push(la(T5, Addr::DomT));
    ops.push(add(rd, rd, T5));
    ops.push(addi(rd, rd, DOMT_HDR as i32));
}
/// `mark_dirty` — set F_DIRTY on node `idx`, bump the header dirty count.
/// Clobbers t6/t5/a3. Caller keeps the node index in a callee-saved reg.
fn mark_dirty(ops: &mut Vec<Op>, idx: u32) {
    node_addr(ops, T6, idx);
    ops.push(lw(T5, T6, N_FLAGS));
    ops.push(li(A3, F_DIRTY));
    ops.push(or_(T5, T5, A3));
    ops.push(sw(T5, T6, N_FLAGS));
    ops.push(la(T6, Addr::DomT));
    ops.push(lw(T5, T6, H_DIRTY));
    ops.push(addi(T5, T5, 1));
    ops.push(sw(T5, T6, H_DIRTY));
}

/// `DomtInit` — one-time arena setup: magic, bump index 1 (root is 0),
/// str cursor 0, and node 0 = root (tag ROOT, visible+dirty, links NONE).
/// Idempotent: a nonzero magic returns immediately so a warm re-entry does
/// not re-zero a live tree. Clobbers a/t regs only.
fn domt_init_node() -> Vec<Op> {
    let mut ops = vec![
        Op::Comment("DomtInit — __dom magic + root node; idempotent".into()),
        Op::Glob("DomtInit".into()),
        Op::Label("DomtInit".into()),
        // NOTE: clobbers a/t regs only — callers keep args in s-regs across
        // the lazy `jal DomtInit`, so the base pointer must be a t-reg.
        la(T3, Addr::DomT),
        lw(T0, T3, H_MAGIC),
        li(T1, DOMT_MAGIC),
        beq(T0, T1, "domt_init_done"),
        // header
        sw(T1, T3, H_MAGIC),
        li(T0, 1),
        sw(T0, T3, H_NEXT),
        sw(X0, T3, H_STR),
        sw(X0, T3, H_DIRTY),
        sw(X0, T3, H_FOCUS),
        sw(X0, T3, H_NRECT),
        // node 0 = root
        addi(T6, T3, DOMT_HDR as i32),
        li(T0, TAG_ROOT),
        sw(T0, T6, N_TAG),
        li(T0, F_VIS | F_DIRTY),
        sw(T0, T6, N_FLAGS),
        li(T0, NONE),
        sw(T0, T6, N_PARENT),
        sw(T0, T6, N_FC),
        sw(T0, T6, N_LC),
        sw(T0, T6, N_NSIB),
        sw(X0, T6, N_TPTR),
        sw(X0, T6, N_TLEN),
        // root bg = dark page, fg = light text
        li(T0, 0x0010_1620),
        sw(T0, T6, N_BG),
        li(T0, 0x00e8_e8e8),
        sw(T0, T6, N_FG),
        sw(X0, T6, N_LISTEN),
        sw(X0, T6, N_LEV),
        sw(X0, T6, N_X),
        sw(X0, T6, N_Y),
        sw(X0, T6, N_W),
        sw(X0, T6, N_H),
        // one dirty node so the first tick paints
        li(T0, 1),
        sw(T0, T3, H_DIRTY),
        Op::Label("domt_init_done".into()),
        ret(),
    ];
    ops.shrink_to_fit();
    ops
}

/// `DomtRoot` → a0 = root node index (0). Lazily `DomtInit`s so a cell that
/// reaches getRoot first always sees a live arena.
fn domt_root_node() -> Vec<Op> {
    let mut ops = vec![
        Op::Comment("DomtRoot → a0=0 (root index)".into()),
        Op::Glob("DomtRoot".into()),
        Op::Label("DomtRoot".into()),
        // frame for the DomtInit call
        addi(SP, SP, -16),
        sd(RA, SP, 8),
        jal("DomtInit"),
        ld(RA, SP, 8),
        addi(SP, SP, 16),
        li(A0, 0),
        ret(),
    ];
    ops.shrink_to_fit();
    ops
}

/// `DomtCreate(a0=tag)` → a0 = new node index. Bump-allocates the next
/// record, zeroes it, stamps `tag` + F_VIS, links NONE. Bounded: when the
/// pool is full it returns `NONE` (fail-closed) — no wraparound, no reuse of
/// a live record.
fn domt_create_node() -> Vec<Op> {
    let mut ops = vec![
        Op::Comment("DomtCreate(a0=tag) → a0=idx | NONE when pool full".into()),
        Op::Glob("DomtCreate".into()),
        Op::Label("DomtCreate".into()),
        addi(SP, SP, -16),
        sd(RA, SP, 8),
        sd(S0, SP, 0),
        mv(S0, A0), // tag
        jal("DomtInit"),
        la(T6, Addr::DomT),
        lw(T5, T6, H_NEXT),
        li(T4, DOMT_NODES),
        bgeu(T5, T4, "domt_create_full"),
        // record addr = __dom + DOMT_HDR + idx*64 ; idx=t5, addr->t3
        slli(T3, T5, 6),
        add(T3, T3, T6),
        addi(T3, T3, DOMT_HDR as i32),
        // bump next
        addi(T4, T5, 1),
        sw(T4, T6, H_NEXT),
        // zero the 16 u32 fields
        mv(T4, X0),
        Op::Label("domt_create_z".into()),
        slli(T0, T4, 2),
        add(T0, T0, T3),
        sw(X0, T0, 0),
        addi(T4, T4, 1),
        li(T1, 16),
        bltu(T4, T1, "domt_create_z"),
        // tag + flags + links
        sw(S0, T3, N_TAG),
        li(T0, F_VIS | F_DIRTY),
        sw(T0, T3, N_FLAGS),
        li(T0, NONE),
        sw(T0, T3, N_PARENT),
        sw(T0, T3, N_FC),
        sw(T0, T3, N_LC),
        sw(T0, T3, N_NSIB),
        // default fg (light) — bg left transparent(0) so parents show through
        li(T0, 0x00e8_e8e8),
        sw(T0, T3, N_FG),
        mv(A0, T5), // return idx
        // bump header dirty (a fresh node is dirty)
        lw(T5, T6, H_DIRTY),
        addi(T5, T5, 1),
        sw(T5, T6, H_DIRTY),
        j("domt_create_out"),
        Op::Label("domt_create_full".into()),
        // DIAG: 'E' = node pool exhausted
        li(A0, i64::from(b'E')),
        li(A7, SBI_PUTCHAR),
        Op::Ecall,
        li(A0, NONE),
        Op::Label("domt_create_out".into()),
        ld(RA, SP, 8),
        ld(S0, SP, 0),
        addi(SP, SP, 16),
        ret(),
    ];
    ops.shrink_to_fit();
    ops
}

/// `DomtAppend(a0=parent, a1=child)` — link `child` under `parent`'s child
/// list (fc/lc chain via nsib), set child.parent=parent, mark parent dirty.
/// Refuses NONE/self/out-of-range indices (fail-closed).
fn domt_append_node() -> Vec<Op> {
    let mut ops = vec![
        Op::Comment("DomtAppend(a0=parent,a1=child) — link + dirty".into()),
        Op::Glob("DomtAppend".into()),
        Op::Label("DomtAppend".into()),
        addi(SP, SP, -32),
        sd(RA, SP, 24),
        sd(S0, SP, 16),
        sd(S1, SP, 8),
        mv(S0, A0), // parent
        mv(S1, A1), // child
        jal("DomtInit"),
        // reject child==NONE or child==parent
        li(T0, NONE),
        beq(S1, T0, "domt_append_out"),
        beq(S1, S0, "domt_append_out"),
        li(T0, DOMT_NODES),
        bgeu(S1, T0, "domt_append_out"),
        bgeu(S0, T0, "domt_append_out"),
        // parent record -> t2 ; child record -> t3
        slli(T2, S0, 6),
        la(T6, Addr::DomT),
        add(T2, T2, T6),
        addi(T2, T2, DOMT_HDR as i32),
        slli(T3, S1, 6),
        add(T3, T3, T6),
        addi(T3, T3, DOMT_HDR as i32),
        // child.parent = parent
        sw(S0, T3, N_PARENT),
        // if parent.lc == NONE: fc=child else node[parent.lc].nsib=child
        lw(T4, T2, N_LC),
        li(T0, NONE),
        bne(T4, T0, "domt_append_tail"),
        sw(S1, T2, N_FC),
        j("domt_append_lc"),
        Op::Label("domt_append_tail".into()),
        // node[parent.lc].nsib = child : t4=last-child idx
        slli(T5, T4, 6),
        add(T5, T5, T6),
        addi(T5, T5, DOMT_HDR as i32),
        sw(S1, T5, N_NSIB),
        Op::Label("domt_append_lc".into()),
        sw(S1, T2, N_LC),
        // mark parent + child dirty
        Op::Label("domt_append_md".into()),
    ];
    // mark_dirty pushes inline ops (clobbers t6/t5/a3); s0/s1 are framed.
    mark_dirty(&mut ops, S0);
    mark_dirty(&mut ops, S1);
    ops.extend([
        Op::Label("domt_append_out".into()),
        ld(RA, SP, 24),
        ld(S0, SP, 16),
        ld(S1, SP, 8),
        addi(SP, SP, 32),
        ret(),
    ]);
    ops.shrink_to_fit();
    ops
}

/// `DomtText(a0=node, a1=strptr, a2=len)` — copy `len` (≤DOMT_TEXT) bytes
/// from `__wasm_mem + strptr` into the `__dom_str` pool at `str_head`, bump
/// the cursor, point the node at it, set F_TEXT|F_DIRTY. The `strptr` is a
/// linear-memory offset so the JIT'd cell passes its own pointers verbatim.
fn domt_text_node() -> Vec<Op> {
    let mut ops = vec![
        Op::Comment(
            "DomtText(a0=node,a1=strptr,a2=len) — pool-copy text, set F_TEXT|F_DIRTY".into(),
        ),
        Op::Glob("DomtText".into()),
        Op::Label("DomtText".into()),
        addi(SP, SP, -32),
        sd(RA, SP, 24),
        sd(S0, SP, 16),
        sd(S1, SP, 8),
        sd(S2, SP, 0),
        mv(S0, A0), // node
        mv(S1, A1), // strptr (wasm-mem offset)
        mv(S2, A2), // len
        jal("DomtInit"),
        // clamp len to DOMT_TEXT and to pool free space
        li(T0, DOMT_TEXT),
        bgeu(S2, T0, "domt_text_cap"),
        j("domt_text_lenok"),
        Op::Label("domt_text_cap".into()),
        mv(S2, T0),
        Op::Label("domt_text_lenok".into()),
        la(T6, Addr::DomT),
        lw(T4, T6, H_STR), // cursor
        la(T5, Addr::DomS),
        // free = DOMT_STR_BYTES - cursor ; need len
        li(T0, DOMT_STR_BYTES as i64),
        sub(T0, T0, T4),
        bgeu(S2, T0, "domt_text_out"), // pool full → drop (fail-closed)
        // copy S2 bytes from __wasm_mem+S1 → __dom_str+cursor
        add(T1, T5, T4), // dst
        la(T2, Addr::WasmMem),
        add(T2, T2, S1), // src
        mv(T3, X0),      // i
        Op::Label("domt_text_cp".into()),
        bgeu(T3, S2, "domt_text_cp_done"),
        add(T0, T2, T3),
        lbu(A3, T0, 0),
        add(A4, T1, T3),
        sb(A3, A4, 0),
        addi(T3, T3, 1),
        j("domt_text_cp"),
        Op::Label("domt_text_cp_done".into()),
        // node.tptr=cursor, tlen=S2, flags|=F_TEXT|F_DIRTY
    ];
    node_addr(&mut ops, T6, S0);
    ops.extend([
        sw(T4, T6, N_TPTR),
        sw(S2, T6, N_TLEN),
        lw(T0, T6, N_FLAGS),
        li(T1, F_TEXT | F_DIRTY),
        or_(T0, T0, T1),
        sw(T0, T6, N_FLAGS),
        // bump str cursor + header dirty
        la(T6, Addr::DomT),
        add(T4, T4, S2),
        sw(T4, T6, H_STR),
        lw(T5, T6, H_DIRTY),
        addi(T5, T5, 1),
        sw(T5, T6, H_DIRTY),
        Op::Label("domt_text_out".into()),
        ld(RA, SP, 24),
        ld(S0, SP, 16),
        ld(S1, SP, 8),
        ld(S2, SP, 0),
        addi(SP, SP, 32),
        ret(),
    ]);
    ops.shrink_to_fit();
    ops
}

/// `DomtStyle(a0=node, a1=bg, a2=fg)` — set the two colors, mark dirty.
fn domt_style_node() -> Vec<Op> {
    let mut ops = vec![
        Op::Comment("DomtStyle(a0=node,a1=bg,a2=fg) — colors + dirty".into()),
        Op::Glob("DomtStyle".into()),
        Op::Label("DomtStyle".into()),
        addi(SP, SP, -16),
        sd(RA, SP, 8),
        sd(S0, SP, 0),
        mv(S0, A0),
        jal("DomtInit"),
    ];
    node_addr(&mut ops, T6, S0);
    ops.extend([sw(A1, T6, N_BG), sw(A2, T6, N_FG)]);
    mark_dirty(&mut ops, S0);
    ops.extend([ld(RA, SP, 8), ld(S0, SP, 0), addi(SP, SP, 16), ret()]);
    ops.shrink_to_fit();
    ops
}

/// `DomtListen(a0=node, a1=evmask, a2=funcidx)` — register the JIT'd-cell
/// callback `funcidx` for the event bits in `evmask`. One listener slot per
/// node (bounded); a second registration overwrites.
fn domt_listen_node() -> Vec<Op> {
    let mut ops = vec![
        Op::Comment("DomtListen(a0=node,a1=evmask,a2=funcidx)".into()),
        Op::Glob("DomtListen".into()),
        Op::Label("DomtListen".into()),
        addi(SP, SP, -16),
        sd(RA, SP, 8),
        jal("DomtInit"),
    ];
    node_addr(&mut ops, T6, A0);
    ops.extend([
        sw(A1, T6, N_LEV),
        sw(A2, T6, N_LISTEN),
        ld(RA, SP, 8),
        addi(SP, SP, 16),
        ret(),
    ]);
    ops.shrink_to_fit();
    ops
}

/// `DomtFocus(a0=node)` — set the focused node (key-dispatch target).
fn domt_focus_node() -> Vec<Op> {
    let mut ops = vec![
        Op::Comment("DomtFocus(a0=node) — key listener target".into()),
        Op::Glob("DomtFocus".into()),
        Op::Label("DomtFocus".into()),
        la(T6, Addr::DomT),
        sw(A0, T6, H_FOCUS),
        ret(),
    ];
    ops.shrink_to_fit();
    ops
}

// ---- M3d: libwasm handle-ABI bridge (Lw*) --------------------------------
// The shipped LDC/libwasm cell calls a *handle*-shaped DOM ABI — integer
// object handles and interned string handles — not the flat `__ui_dom` row
// table the text/CLI face uses. These `Lw*` routines adapt that ABI onto the
// `__dom`/`__dom_str`/`__dom_id` arenas the M2 lane already owns. The real ABI
// (from `browser-ui/out/kernel.js`):
//
//   object handle  = `__dom` node index + 1  (getRoot→1, createElement→2,3,…;
//                                             index = handle-1, 0 = null)
//   string args    = (len, ptr) — length BEFORE the `__wasm_mem` offset
//   string handle  = byte offset of a `[len:u32][bytes]` record in `__dom_str`
//
// `createElement` takes a `NodeType` *ordinal* (not a string); it rides in
// `N_TAG` biased by `TAG_LW`. `setProperty` is `(handle, nameLen, namePtr,
// valLen, valPtr)`; `id` values go to the `__dom_id` side-table so
// `add_event_listener`'s id-string target resolves to a node (`LwFindId`).
// Everything is bounded — pool exhaustion / a bad handle fails closed.

/// Interned-string byte cap for `libwasm_add__string`.
pub const LWS_MAX: i64 = 128;

/// `LwNameEq(a0=wm_off, a1=wm_len, a2=lit, a3=lit_len) → a0=1` iff the
/// `wm_len` bytes at `__wasm_mem + wm_off` equal the `lit_len` host bytes at
/// `lit`. Leaf — a/t regs only, no frame.
fn lw_nameeq_node() -> Vec<Op> {
    vec![
        Op::Comment("LwNameEq(a0=wmoff,a1=wmlen,a2=lit,a3=litlen) → a0=eq".into()),
        Op::Glob("LwNameEq".into()),
        Op::Label("LwNameEq".into()),
        bne(A1, A3, "lwne_no"),
        la(T4, Addr::WasmMem),
        add(A0, T4, A0), // a0 = name bytes in wasm mem
        mv(T0, X0),      // i
        Op::Label("lwne_l".into()),
        bgeu(T0, A1, "lwne_yes"),
        add(T1, A0, T0),
        lbu(T1, T1, 0),
        add(T2, A2, T0),
        lbu(T2, T2, 0),
        bne(T1, T2, "lwne_no"),
        addi(T0, T0, 1),
        j("lwne_l"),
        Op::Label("lwne_yes".into()),
        li(A0, 1),
        ret(),
        Op::Label("lwne_no".into()),
        li(A0, 0),
        ret(),
    ]
}

/// `LwHexVal(a0=c) → a0=digit` — ASCII hex digit value (0..15), else 0.
/// Leaf — a/t regs only.
fn lw_hexval_node() -> Vec<Op> {
    vec![
        Op::Comment("LwHexVal(a0=c) → a0=0..15 | 0".into()),
        Op::Glob("LwHexVal".into()),
        Op::Label("LwHexVal".into()),
        li(T0, i64::from(b'0')),
        sub(T1, A0, T0), // c - '0'
        li(T0, 9),
        bgeu(T1, T0, "lwhv_alpha"), // >9 (incl. wrap for c<'0') → try alpha
        mv(A0, T1),
        ret(),
        Op::Label("lwhv_alpha".into()),
        li(T0, 0x20),
        or_(T1, A0, T0), // c | 0x20 → lowercase
        li(T0, i64::from(b'a')),
        sub(T1, T1, T0), // lower - 'a'
        li(T0, 5),
        bgeu(T1, T0, "lwhv_bad"),
        addi(A0, T1, 10),
        ret(),
        Op::Label("lwhv_bad".into()),
        li(A0, 0),
        ret(),
    ]
}

/// `LwAddStr(a0=len, a1=wm_ptr) → a0=handle` — `libwasm_add__string`. The
/// libwasm string ABI is **len-before-ptr**, so `a0` is the byte count and
/// `a1` the `__wasm_mem` offset. Copies `len` (≤`LWS_MAX`) bytes into
/// `__dom_str` as a `[len:u32][bytes]` record and returns the `bytes` offset
/// (≥4) as the intern handle. Pool exhaustion → 0 (fail-closed).
fn lw_addstr_node() -> Vec<Op> {
    let mut ops = vec![
        Op::Comment("LwAddStr(a0=len,a1=wmptr) → a0=str-handle (__dom_str off)".into()),
        Op::Glob("LwAddStr".into()),
        Op::Label("LwAddStr".into()),
        addi(SP, SP, -32),
        sd(RA, SP, 24),
        sd(S0, SP, 16),
        sd(S1, SP, 8),
        mv(S0, A1), // wm off = a1 (ptr)
        mv(S1, A0), // len   = a0
        // DIAG: 's' + the stored string (reveals the console.error msg)
        li(A0, 's' as i64),
        li(A7, SBI_PUTCHAR),
        Op::Ecall,
        la(T3, Addr::WasmMem),
        add(T3, T3, S0),
        mv(A3, X0),
        Op::Label("lwas_dp".into()),
        bgeu(A3, S1, "lwas_dpd"),
        add(A4, T3, A3),
        lbu(A0, A4, 0),
        li(A7, SBI_PUTCHAR),
        Op::Ecall,
        addi(A3, A3, 1),
        j("lwas_dp"),
        Op::Label("lwas_dpd".into()),
        li(A0, '\n' as i64),
        li(A7, SBI_PUTCHAR),
        Op::Ecall,
        jal("DomtInit"),
        li(T0, LWS_MAX),
        bltu(S1, T0, "lwas_lenok"),
        mv(S1, T0),
        Op::Label("lwas_lenok".into()),
        la(T6, Addr::DomT),
        lw(T4, T6, H_STR), // cursor (bytes used)
        li(T0, DOMT_STR_BYTES as i64),
        sub(T0, T0, T4), // free
        addi(T1, S1, 4), // need = 4 + len
        bltu(T0, T1, "lwas_full"),
        la(T5, Addr::DomS),
        add(T2, T5, T4), // dst = __dom_str + cursor
        sw(S1, T2, 0),   // [len:u32]
        la(T3, Addr::WasmMem),
        add(T3, T3, S0), // src = __wasm_mem + off
        mv(A3, X0),
        Op::Label("lwas_cp".into()),
        bgeu(A3, S1, "lwas_cpd"),
        add(T0, T3, A3),
        lbu(T0, T0, 0),
        add(A4, T2, A3),
        sb(T0, A4, 4), // dst[4+i]
        addi(A3, A3, 1),
        j("lwas_cp"),
        Op::Label("lwas_cpd".into()),
        addi(A0, T4, 4), // handle = bytes offset (≥4)
        add(T4, T4, S1),
        addi(T4, T4, 4),
        sw(T4, T6, H_STR),
        j("lwas_out"),
        Op::Label("lwas_full".into()),
        li(A0, 0),
        Op::Label("lwas_out".into()),
        ld(RA, SP, 24),
        ld(S0, SP, 16),
        ld(S1, SP, 8),
        addi(SP, SP, 32),
        ret(),
    ];
    ops.shrink_to_fit();
    ops
}

/// `LwCreateEl(a0=tag_ordinal) → a0=handle` — `createElement`. The libwasm
/// ABI passes a `NodeType` enum ordinal (not a string); it rides in `N_TAG`
/// biased by `TAG_LW` so a `0` ordinal stays nonzero for the raster free-check
/// (`__dom_str` recovers the tag via `LIBWASM_TAGS[N_TAG-TAG_LW]`). The return
/// is a *handle* = `index+1` (root is `1`), so a `DomtCreate` `NONE` folds to
/// the `0` null handle — fail-closed.
fn lw_createel_node() -> Vec<Op> {
    vec![
        Op::Comment("LwCreateEl(a0=tag-ordinal) → a0=handle (index+1)".into()),
        Op::Glob("LwCreateEl".into()),
        Op::Label("LwCreateEl".into()),
        addi(SP, SP, -16),
        sd(RA, SP, 8),
        addi(A0, A0, TAG_LW as i32), // tag = ordinal + TAG_LW (nonzero)
        jal("DomtCreate"),           // a0 = index | NONE
        addi(A0, A0, 1),             // handle = index+1 ; NONE→0 (null)
        ld(RA, SP, 8),
        addi(SP, SP, 16),
        ret(),
    ]
}

/// `LwGetRoot() → a0=handle` — `getRoot`. The host returns `1` for the root
/// element; under the `handle = index+1` convention the root index `0` maps to
/// handle `1`. Lazily `DomtInit`s so a first call sees a live arena.
fn lw_getroot_node() -> Vec<Op> {
    let mut ops = vec![
        Op::Comment("LwGetRoot → a0=1 (root handle = index0+1)".into()),
        Op::Glob("LwGetRoot".into()),
        Op::Label("LwGetRoot".into()),
        addi(SP, SP, -16),
        sd(RA, SP, 8),
        jal("DomtInit"),
        ld(RA, SP, 8),
        addi(SP, SP, 16),
        li(A0, 1),
        ret(),
    ];
    ops.shrink_to_fit();
    ops
}

/// `LwAppend(a0=parent_handle, a1=child_handle)` — `appendChild`. Converts the
/// two libwasm handles to node indices (`-1` each) and tail-calls `DomtAppend`,
/// whose bounds checks reject a `0`/out-of-range handle (index `-1`/`≥N`).
fn lw_append_node() -> Vec<Op> {
    vec![
        Op::Comment("LwAppend(a0=parenth,a1=childh) — handle→idx, tail DomtAppend".into()),
        Op::Glob("LwAppend".into()),
        Op::Label("LwAppend".into()),
        addi(A0, A0, -1),
        addi(A1, A1, -1),
        j("DomtAppend"),
    ]
}

/// `LwParseColor(a0=wm_off, a1=len) → a0=0xRRGGBB` — parse a `#rrggbb` CSS
/// color out of `__wasm_mem`; anything else → 0 (absent/transparent).
fn lw_parsecolor_node() -> Vec<Op> {
    let mut ops = vec![
        Op::Comment("LwParseColor(a0=wmoff,a1=len) → a0=0xRRGGBB | 0".into()),
        Op::Glob("LwParseColor".into()),
        Op::Label("LwParseColor".into()),
        addi(SP, SP, -32),
        sd(RA, SP, 24),
        sd(S0, SP, 16),
        sd(S1, SP, 8),
        sd(S2, SP, 0),
        // need len>=7 and byte0=='#'
        li(T0, 7),
        bltu(A1, T0, "lwpc_zero"),
        la(T4, Addr::WasmMem),
        add(S0, T4, A0), // s0 = src
        lbu(T1, S0, 0),
        li(T2, i64::from(b'#')),
        bne(T1, T2, "lwpc_zero"),
        mv(S2, X0), // value
        li(S1, 1),  // i = 1..7
        Op::Label("lwpc_l".into()),
        li(T0, 7),
        bgeu(S1, T0, "lwpc_done"),
        add(T1, S0, S1),
        lbu(A0, T1, 0), // c
        jal("LwHexVal"),
        slli(S2, S2, 4),
        or_(S2, S2, A0),
        addi(S1, S1, 1),
        j("lwpc_l"),
        Op::Label("lwpc_done".into()),
        mv(A0, S2),
        j("lwpc_out"),
        Op::Label("lwpc_zero".into()),
        li(A0, 0),
        Op::Label("lwpc_out".into()),
        ld(RA, SP, 24),
        ld(S0, SP, 16),
        ld(S1, SP, 8),
        ld(S2, SP, 0),
        addi(SP, SP, 32),
        ret(),
    ];
    ops.shrink_to_fit();
    ops
}

/// `LwSetId(a0=node_idx, a1=val_off, a2=val_len)` — store the element `id`
/// value into the node's `__dom_id` slot as `[len:u32][bytes≤28]`, copied from
/// `__wasm_mem + val_off`. `node_idx` is already an index (handle resolved by
/// the caller). Bounded by `DOMT_ID_SLOT-4`; an out-of-range index drops out.
fn lw_setid_node() -> Vec<Op> {
    let mut ops = vec![
        Op::Comment("LwSetId(a0=idx,a1=voff,a2=vlen) — id bytes → __dom_id".into()),
        Op::Glob("LwSetId".into()),
        Op::Label("LwSetId".into()),
        addi(SP, SP, -32),
        sd(RA, SP, 24),
        sd(S0, SP, 16),
        sd(S1, SP, 8),
        sd(S2, SP, 0),
        mv(S0, A0),
        mv(S1, A1),
        mv(S2, A2),
        jal("DomtInit"),
        // idx bound
        li(T0, DOMT_NODES),
        bgeu(S0, T0, "lwsi_out"),
        // clamp len ≤ DOMT_ID_SLOT-4 (28)
        li(T0, (DOMT_ID_SLOT - 4) as i64),
        bltu(S2, T0, "lwsi_lenok"),
        mv(S2, T0),
        Op::Label("lwsi_lenok".into()),
        // slot = __dom_id + idx*32
        slli(T6, S0, 5),
        la(T5, Addr::DomId),
        add(T6, T6, T5),
        sw(S2, T6, 0), // [len]
        la(T4, Addr::WasmMem),
        add(T4, T4, S1), // src = __wasm_mem + voff
        mv(T3, X0),
        Op::Label("lwsi_cp".into()),
        bgeu(T3, S2, "lwsi_out"),
        add(T0, T4, T3),
        lbu(T0, T0, 0),
        add(T1, T6, T3),
        sb(T0, T1, 4), // dst[4+i]
        addi(T3, T3, 1),
        j("lwsi_cp"),
        Op::Label("lwsi_out".into()),
        ld(RA, SP, 24),
        ld(S0, SP, 16),
        ld(S1, SP, 8),
        ld(S2, SP, 0),
        addi(SP, SP, 32),
        ret(),
    ];
    ops.shrink_to_fit();
    ops
}

/// `LwFindId(a0=id_off, a1=id_len) → a0=idx | NONE` — resolve an element `id`
/// string (at `__wasm_mem + id_off`) to the node index whose `__dom_id` slot
/// matches byte-for-byte. A `0` length never matches; scanning is bounded by
/// `DOMT_NODES`. Used by `add_event_listener`, whose target is an id string.
fn lw_findid_node() -> Vec<Op> {
    let mut ops = vec![
        Op::Comment("LwFindId(a0=idoff,a1=idlen) → a0=idx | NONE".into()),
        Op::Glob("LwFindId".into()),
        Op::Label("LwFindId".into()),
        addi(SP, SP, -48),
        sd(RA, SP, 40),
        sd(S0, SP, 32),
        sd(S1, SP, 24),
        sd(S2, SP, 16),
        sd(S3, SP, 8),
        mv(S0, A0), // id off
        mv(S1, A1), // id len
        jal("DomtInit"),
        beq(S1, X0, "lwfi_none"), // empty id never resolves
        la(T4, Addr::WasmMem),
        add(S3, T4, S0), // s3 = target bytes
        mv(S2, X0),      // i
        Op::Label("lwfi_loop".into()),
        li(T0, DOMT_NODES),
        bgeu(S2, T0, "lwfi_none"),
        // slot = __dom_id + i*32
        slli(T6, S2, 5),
        la(T5, Addr::DomId),
        add(T6, T6, T5),
        lw(T0, T6, 0), // slot len
        bne(T0, S1, "lwfi_next"),
        // compare s1 bytes: slot+4 vs s3
        mv(T3, X0),
        Op::Label("lwfi_cmp".into()),
        bgeu(T3, S1, "lwfi_found"),
        add(T0, T6, T3),
        lbu(T0, T0, 4),
        add(T1, S3, T3),
        lbu(T1, T1, 0),
        bne(T0, T1, "lwfi_next"),
        addi(T3, T3, 1),
        j("lwfi_cmp"),
        Op::Label("lwfi_next".into()),
        addi(S2, S2, 1),
        j("lwfi_loop"),
        Op::Label("lwfi_found".into()),
        mv(A0, S2),
        j("lwfi_out"),
        Op::Label("lwfi_none".into()),
        li(A0, NONE),
        Op::Label("lwfi_out".into()),
        ld(RA, SP, 40),
        ld(S0, SP, 32),
        ld(S1, SP, 24),
        ld(S2, SP, 16),
        ld(S3, SP, 8),
        addi(SP, SP, 48),
        ret(),
    ];
    ops.shrink_to_fit();
    ops
}

/// `LwSetProp(a0=handle, a1=name_len, a2=name_ptr, a3=val_len, a4=val_ptr)` —
/// `setProperty`. The libwasm ABI is **len-before-ptr** for both strings and
/// `a0` is a *handle* (`index+1`), so `S0 = a0-1` is the node index. Routes by
/// name: text-bearing names (`innerText`, `textContent`, `value`, `innerHTML`,
/// `nodeValue`) pool-copy the value via `DomtText`; `id` copies into the
/// `__dom_id` side-table (`LwSetId`) for `add_event_listener` resolution;
/// `background`/`backgroundColor`/`background-color`/`bgcolor` parse `#rrggbb`
/// into `N_BG`; `color` into `N_FG`. Unknown names drop (bounded, no trap).
fn lw_setprop_node() -> Vec<Op> {
    let mut ops = vec![
        Op::Comment("LwSetProp(a0=handle,a1=nlen,a2=nptr,a3=vlen,a4=vptr) — len-first".into()),
        Op::Glob("LwSetProp".into()),
        Op::Label("LwSetProp".into()),
        addi(SP, SP, -48),
        sd(RA, SP, 40),
        sd(S0, SP, 32),
        sd(S1, SP, 24),
        sd(S2, SP, 16),
        sd(S3, SP, 8),
        sd(S4, SP, 0),
        addi(S0, A0, -1), // node idx = handle-1
        mv(S1, A1),       // name len
        mv(S2, A2),       // name ptr
        mv(S3, A3),       // val len
        mv(S4, A4),       // val ptr
        jal("DomtInit"),
        // reject a null/out-of-range handle (idx 0..DOMT_NODES-1; -1 wraps huge)
        li(T0, DOMT_NODES),
        bgeu(S0, T0, "lsp_out"),
    ];
    // name-match dispatch: name is (off=S2, len=S1); each candidate is
    // (lit label, lit len, target).
    for (lit, len, target) in [
        ("lw_lit_innerText", 9i64, "lsp_text"),
        ("lw_lit_textContent", 11, "lsp_text"),
        ("lw_lit_innerHTML", 9, "lsp_text"),
        ("lw_lit_nodeValue", 9, "lsp_text"),
        ("lw_lit_value", 5, "lsp_text"),
        ("lw_lit_id", 2, "lsp_id"),
        ("lw_lit_background", 10, "lsp_bg"),
        ("lw_lit_backgroundColor", 15, "lsp_bg"),
        ("lw_lit_background-color", 16, "lsp_bg"),
        ("lw_lit_bgcolor", 7, "lsp_bg"),
        ("lw_lit_color", 5, "lsp_fg"),
        ("lw_lit_hidden", 6, "lsp_hidden"),
    ] {
        ops.extend([
            mv(A0, S2), // name off
            mv(A1, S1), // name len
            la(A2, Addr::Label(lit.into())),
            li(A3, len),
            jal("LwNameEq"),
            bne(A0, X0, target),
        ]);
    }
    ops.push(j("lsp_out")); // no name matched → drop
                            // text-bearing value → DomtText(node, val_off=S4, val_len=S3)
    ops.extend([
        Op::Label("lsp_text".into()),
        mv(A0, S0),
        mv(A1, S4),
        mv(A2, S3),
        jal("DomtText"),
        j("lsp_out"),
    ]);
    // id value → __dom_id side-table (LwSetId(node, val_off=S4, val_len=S3))
    ops.extend([
        Op::Label("lsp_id".into()),
        mv(A0, S0),
        mv(A1, S4),
        mv(A2, S3),
        jal("LwSetId"),
        j("lsp_out"),
    ]);
    // color value → N_BG / N_FG (LwParseColor(val_off=S4, val_len=S3))
    for (target, off) in [("lsp_bg", N_BG), ("lsp_fg", N_FG)] {
        ops.extend([
            Op::Label(target.into()),
            mv(A0, S4),
            mv(A1, S3),
            jal("LwParseColor"),
            mv(A1, A0), // rgb
        ]);
        node_addr(&mut ops, T6, S0);
        ops.push(sw(A1, T6, off));
        mark_dirty(&mut ops, S0);
        ops.push(j("lsp_out"));
    }
    // `hidden` boolean: `setProperty(el,"hidden","true")` hides the node —
    // clear F_VIS. `"false"`/`"0"`/empty re-shows it (the tab switch flips
    // inactive menus this way). Descendants inherit via DomtVis (a node paints
    // only when it *and* every ancestor are F_VIS).
    ops.extend([
        Op::Label("lsp_hidden".into()),
        // T6 = node rec (S0 = node idx).
        slli(T6, S0, 6),
        la(T5, Addr::DomT),
        add(T6, T6, T5),
        addi(T6, T6, DOMT_HDR as i32),
        // A bare `hidden` attr emits `setProperty(el,"hidden","")` — an empty
        // value means *present* → hide. Only an explicit "false"/"0" re-shows
        // (the tab switch flips menus via `menu.hidden = …`).
        beq(S3, X0, "lsp_hidden_do"),
        la(T0, Addr::WasmMem),
        add(T0, T0, S4),
        lbu(T0, T0, 0), // val[0]
        li(T1, 0x66),   // 'f'
        beq(T0, T1, "lsp_hidden_show"),
        li(T1, 0x46), // 'F'
        beq(T0, T1, "lsp_hidden_show"),
        li(T1, 0x30), // '0'
        beq(T0, T1, "lsp_hidden_show"),
        // hide: flags &= ~F_VIS
        Op::Label("lsp_hidden_do".into()),
        lw(T0, T6, N_FLAGS),
        li(T1, F_VIS),
        li(T2, -1),
        Op::Xor {
            rd: T2,
            rs1: T1,
            rs2: T2,
        }, // ~F_VIS
        and_(T0, T0, T2),
        sw(T0, T6, N_FLAGS),
        j("lsp_hidden_done"),
        // show: flags |= F_VIS
        Op::Label("lsp_hidden_show".into()),
        lw(T0, T6, N_FLAGS),
        li(T1, F_VIS),
        or_(T0, T0, T1),
        sw(T0, T6, N_FLAGS),
        Op::Label("lsp_hidden_done".into()),
    ]);
    mark_dirty(&mut ops, S0);
    ops.extend([
        j("lsp_out"),
        Op::Label("lsp_out".into()),
        ld(RA, SP, 40),
        ld(S0, SP, 32),
        ld(S1, SP, 24),
        ld(S2, SP, 16),
        ld(S3, SP, 8),
        ld(S4, SP, 0),
        addi(SP, SP, 48),
        ret(),
    ]);
    ops.shrink_to_fit();
    ops
}

/// `LwAddLsn(a0=tptr, a1=tlen, a2=typtr, a3=tylen, a4=cb, a5=capture)` —
/// `add_event_listener`. The libwasm target is an **element-id string**, not a
/// node handle: `LwFindId` resolves it through `__dom_id` (set earlier by
/// `setProperty(el,"id",..)`). The event-type string maps to an `EV_*` mask
/// (`click`→CLICK, `keydown`/`keyup`/`keypress`→KEYDOWN); the `cb` funcidx is
/// stored in `N_LISTEN` for the bounded dispatch lane. An unresolvable id or
/// unknown event is a no-op (bounded, no trap).
fn lw_addlsn_node() -> Vec<Op> {
    let mut ops = vec![
        Op::Comment("LwAddLsn(a0=tptr,a1=tlen,a2=typtr,a3=tylen,a4=cb) — id→node + ev→mask".into()),
        Op::Glob("LwAddLsn".into()),
        Op::Label("LwAddLsn".into()),
        addi(SP, SP, -64),
        sd(RA, SP, 56),
        sd(S0, SP, 48),
        sd(S1, SP, 40),
        sd(S2, SP, 32),
        sd(S3, SP, 24),
        sd(S4, SP, 16),
        sd(S5, SP, 8),
        mv(S0, A0), // target id off
        mv(S1, A1), // target id len
        mv(S2, A2), // ev-type off
        mv(S3, A3), // ev-type len
        mv(S4, A4), // cb funcidx
        jal("DomtInit"),
    ];
    // ev-type name → mask in S5 (type is (off=S2, len=S3)). Each candidate gets
    // a unique skip label — a shared `lwal_next` would collapse all six `beq`s
    // onto one address and misroute every non-final match.
    ops.push(li(S5, 0));
    for (i, (lit, len, mask)) in [
        ("lw_lit_click", 5i64, EV_CLICK),
        ("lw_lit_mousedown", 9, EV_CLICK),
        ("lw_lit_keydown", 7, EV_KEYDOWN),
        ("lw_lit_keyup", 5, EV_KEYDOWN),
        ("lw_lit_keypress", 8, EV_KEYDOWN),
        ("lw_lit_input", 5, EV_KEYDOWN),
    ]
    .iter()
    .enumerate()
    {
        let next = format!("lwal_next{i}");
        ops.extend([
            mv(A0, S2), // type off
            mv(A1, S3), // type len
            la(A2, Addr::Label((*lit).into())),
            li(A3, *len),
            jal("LwNameEq"),
            beq(A0, X0, &next),
            li(S5, *mask),
            Op::Label(next),
        ]);
    }
    // resolve the target id string (off=S0, len=S1) → node index
    ops.extend([
        mv(A0, S0),
        mv(A1, S1),
        jal("LwFindId"),
        li(T0, NONE),
        beq(A0, T0, "lwal_out"), // id not found → no-op
        mv(A1, S5),              // evmask
        mv(A2, S4),              // cb funcidx
        // cb != 0 is a wasm funcidx — bias into the reserved >=LSN_FUNC band
        // so it can't alias the BIOS-protocol `0` / `LSN_DEMO` builtins;
        // `DomtKey` subtracts `LSN_FUNC` to recover the `ftab` index.
        beq(A2, X0, "lwal_lsn"),
        li(T0, LSN_FUNC),
        add(A2, A2, T0),
        Op::Label("lwal_lsn".into()),
        jal("DomtListen"), // DomtListen(node=a0, evmask, funcidx|0x100+funcidx)
        Op::Label("lwal_out".into()),
        ld(RA, SP, 56),
        ld(S0, SP, 48),
        ld(S1, SP, 40),
        ld(S2, SP, 32),
        ld(S3, SP, 24),
        ld(S4, SP, 16),
        ld(S5, SP, 8),
        addi(SP, SP, 64),
        ret(),
    ]);
    ops.shrink_to_fit();
    ops
}

/// `LwEvGet(a0=evhandle, a1=nlen, a2=nptr) → a0` — the `Object_Getter__*`
/// bridge for the `__ev_obj` event record. The libwasm getter ABI is
/// `(handle, nameLen, namePtr)`; the property name is a `__wasm_mem` string
/// matched byte-for-byte via `LwNameEq`. `handle` must be the live event
/// object `&__ev_obj` — any other handle returns 0 (the bridge is bounded to
/// the in-flight event; node/object getters stay a separate lane). Numeric and
/// handle fields load `lw(handle,off)` straight out of the record; `target`/
/// `srcElement`/`currentTarget` return the stored node handle; `type` is the
/// `EV_*` mask as an int (the string `type` getter is a separate sret lane);
/// `defaultPrevented` reads the `EVO_PD` write-back bit set by `LwEvCall`;
/// `cancelable`/`bubbles`/`isTrusted` are constant-1 — every synthetic event is
/// cancelable+bubbling. Unknown names fall through to 0 (no trap).
fn lw_evget_node() -> Vec<Op> {
    let mut ops = vec![
        Op::Comment("LwEvGet(a0=evhandle,a1=nlen,a2=nptr) → a0 — __ev_obj getter".into()),
        Op::Glob("LwEvGet".into()),
        Op::Label("LwEvGet".into()),
        addi(SP, SP, -48),
        sd(RA, SP, 40),
        sd(S0, SP, 32),
        sd(S1, SP, 24),
        sd(S2, SP, 16),
        mv(S0, A0), // event handle — must be &__ev_obj
        mv(S1, A1), // property-name len
        mv(S2, A2), // property-name wasm-mem off
        // bounded: only the live event object is served — other handles → 0.
        la(T0, Addr::EvObj),
        bne(S0, T0, "lveg_null"),
    ];
    // integer + handle fields — each loads `lw(handle, off)`. Unique skip
    // labels per candidate (a shared label would collapse the `beq`s).
    for (i, (lit, len, off)) in [
        ("lw_lit_clientX", 7i64, EVO_CX),
        ("lw_lit_screenX", 7, EVO_CX),
        ("lw_lit_pageX", 5, EVO_CX),
        ("lw_lit_offsetX", 7, EVO_CX),
        ("lw_lit_clientY", 7, EVO_CY),
        ("lw_lit_screenY", 7, EVO_CY),
        ("lw_lit_pageY", 5, EVO_CY),
        ("lw_lit_offsetY", 7, EVO_CY),
        ("lw_lit_code", 4, EVO_CODE),
        ("lw_lit_keyCode", 7, EVO_CODE),
        ("lw_lit_which", 5, EVO_CODE),
        ("lw_lit_button", 6, EVO_CODE),
        ("lw_lit_detail", 6, EVO_VALUE),
        ("lw_lit_value", 5, EVO_VALUE),
        ("lw_lit_deltaY", 6, EVO_VALUE),
        ("lw_lit_type", 4, EVO_TYPE),
        ("lw_lit_target", 6, EVO_TARGET),
        ("lw_lit_srcElement", 10, EVO_TARGET),
        ("lw_lit_currentTarget", 13, EVO_TARGET),
        ("lw_lit_defaultPrevented", 16, EVO_PD),
    ]
    .iter()
    .enumerate()
    {
        let next = format!("lveg_n{i}");
        ops.extend([
            mv(A0, S2), // name off
            mv(A1, S1), // name len
            la(A2, Addr::Label((*lit).into())),
            li(A3, *len),
            jal("LwNameEq"),
            beq(A0, X0, &next),
            lw(A0, S0, *off),
            j("lveg_out"),
            Op::Label(next),
        ]);
    }
    // constant-true boolean fields — our synthetic events cancel+bubble.
    for (i, (lit, len)) in [
        ("lw_lit_cancelable", 10i64),
        ("lw_lit_bubbles", 7),
        ("lw_lit_isTrusted", 9),
    ]
    .iter()
    .enumerate()
    {
        let next = format!("lveg_c{i}");
        ops.extend([
            mv(A0, S2),
            mv(A1, S1),
            la(A2, Addr::Label((*lit).into())),
            li(A3, *len),
            jal("LwNameEq"),
            beq(A0, X0, &next),
            li(A0, 1),
            j("lveg_out"),
            Op::Label(next),
        ]);
    }
    ops.extend([
        Op::Label("lveg_null".into()),
        li(A0, 0),
        Op::Label("lveg_out".into()),
        ld(RA, SP, 40),
        ld(S0, SP, 32),
        ld(S1, SP, 24),
        ld(S2, SP, 16),
        addi(SP, SP, 48),
        ret(),
    ]);
    ops.shrink_to_fit();
    ops
}

/// `LwEvCall(a0=evhandle, a1=mlen, a2=mptr)` — the `Object_Call___void`
/// (no-arg, void-return) method dispatch on the event object. `preventDefault`
/// sets `EVO_PD` so a later `defaultPrevented` getter reads 1 — the write-back
/// half of the property bridge. Any other method name, or a non-event handle,
/// is a bounded no-op. (`preventDefault`/`stopPropagation` share the
/// `Object_Call___void` shape; only `preventDefault` is matched.)
fn lw_evcall_node() -> Vec<Op> {
    let mut ops = vec![
        Op::Comment("LwEvCall(a0=evhandle,a1=mlen,a2=mptr) — preventDefault→EVO_PD".into()),
        Op::Glob("LwEvCall".into()),
        Op::Label("LwEvCall".into()),
        addi(SP, SP, -32),
        sd(RA, SP, 24),
        sd(S0, SP, 16),
        sd(S1, SP, 8),
        sd(S2, SP, 0),
        mv(S0, A0), // event handle
        mv(S1, A1), // method-name len
        mv(S2, A2), // method-name wasm-mem off
        la(T0, Addr::EvObj),
        bne(S0, T0, "lvcl_out"), // not the event object → no-op
        mv(A0, S2),
        mv(A1, S1),
        la(A2, Addr::Label("lw_lit_preventDefault".into())),
        li(A3, 14),
        jal("LwNameEq"),
        beq(A0, X0, "lvcl_out"),
        li(T0, 1),
        sw(T0, S0, EVO_PD),
        Op::Label("lvcl_out".into()),
        ld(RA, SP, 24),
        ld(S0, SP, 16),
        ld(S1, SP, 8),
        ld(S2, SP, 0),
        addi(SP, SP, 32),
        ret(),
    ];
    ops.shrink_to_fit();
    ops
}

/// `LwRemove(a0=handle)` — `libwasm_removeObject`: unlink the node from its
/// parent's child chain (fc/lc via nsib), then tombstone it (`N_TAG=0`,
/// `F_VIS` cleared). `a0` is a libwasm handle, so the index is `a0-1`.
/// Bounded; a detached/root/null node is simply hidden.
fn lw_remove_node() -> Vec<Op> {
    let mut ops = vec![
        Op::Comment("LwRemove(a0=handle) — idx=handle-1, unlink + tombstone".into()),
        Op::Glob("LwRemove".into()),
        Op::Label("LwRemove".into()),
        addi(SP, SP, -32),
        sd(RA, SP, 24),
        sd(S0, SP, 16),
        sd(S1, SP, 8),
        addi(S0, A0, -1), // node idx = handle-1
        jal("DomtInit"),
        // reject NONE/out-of-range/root
        li(T0, NONE),
        beq(S0, T0, "lwr_out"),
        beq(S0, X0, "lwr_out"),
        li(T0, DOMT_NODES),
        bgeu(S0, T0, "lwr_out"),
        // parent = node.parent
    ];
    node_addr(&mut ops, T6, S0);
    ops.push(lw(S1, T6, N_PARENT)); // s1 = parent idx
    ops.push(li(T0, NONE));
    ops.push(beq(S1, T0, "lwr_tomb")); // no parent → just tombstone
                                       // parent rec -> t2 ; walk fc/nsib chain tracking prev(t5) & cur(t4).
    node_addr(&mut ops, T2, S1);
    // prev = NONE, cur = parent.fc
    ops.push(li(T5, NONE));
    ops.push(lw(T4, T2, N_FC));
    ops.push(Op::Label("lwr_walk".into()));
    ops.push(li(T0, NONE));
    ops.push(beq(T4, T0, "lwr_tomb")); // not found in chain → just tombstone
    ops.push(beq(T4, S0, "lwr_found")); // cur == node → unlink
                                        // prev = cur ; cur = node[cur].nsib
    ops.push(mv(T5, T4));
    node_addr(&mut ops, T3, T4);
    ops.push(lw(T4, T3, N_NSIB));
    ops.push(j("lwr_walk"));
    // found: link prev→node.nsib (or parent.fc when prev==NONE)
    ops.push(Op::Label("lwr_found".into()));
    node_addr(&mut ops, T3, S0); // node rec
    ops.push(lw(T1, T3, N_NSIB)); // node.nsib
    ops.push(li(T0, NONE));
    ops.push(bne(T5, T0, "lwr_prev"));
    ops.push(sw(T1, T2, N_FC)); // node was first child → parent.fc = nsib
    ops.push(j("lwr_lcfix"));
    ops.push(Op::Label("lwr_prev".into()));
    node_addr(&mut ops, T3, T5); // prev rec
    ops.push(sw(T1, T3, N_NSIB)); // prev.nsib = node.nsib
                                  // if parent.lc == node → parent.lc = prev
    ops.push(Op::Label("lwr_lcfix".into()));
    ops.push(lw(T4, T2, N_LC));
    ops.push(bne(T4, S0, "lwr_tomb"));
    ops.push(sw(T5, T2, N_LC));
    // tombstone: tag=0, flags &= ~F_VIS, links NONE
    ops.push(Op::Label("lwr_tomb".into()));
    node_addr(&mut ops, T3, S0);
    ops.extend([
        sw(X0, T3, N_TAG),
        lw(T0, T3, N_FLAGS),
        li(T1, F_VIS),
        li(T2, -1),
        Op::Xor {
            rd: T2,
            rs1: T1,
            rs2: T2,
        }, // ~F_VIS
        and_(T0, T0, T2),
        sw(T0, T3, N_FLAGS),
        li(T0, NONE),
        sw(T0, T3, N_PARENT),
        sw(T0, T3, N_NSIB),
    ]);
    mark_dirty(&mut ops, S0);
    ops.extend([
        Op::Label("lwr_out".into()),
        ld(RA, SP, 24),
        ld(S0, SP, 16),
        ld(S1, SP, 8),
        addi(SP, SP, 32),
        ret(),
    ]);
    ops.shrink_to_fit();
    ops
}

/// `LwFetch(a0=wm_off, a1=len)` — libwasm `fetch(ptr, len)`. The guest-JIT
/// ext dispatch passes `a0` as a raw `__wasm_mem` offset, whereas `WasmFetch`
/// (also the old `start_ops` stub) reads an absolute pointer. This shim adds
/// the `__wasm_mem` base and tail-calls `WasmFetch`, so the old absolute-
/// pointer callers are unaffected. `WasmFetch` returns the (nonzero) pointer,
/// which the cell may hold as a promise handle — `libwasm_await_supported` is
/// `0`, so it is never awaited.
/// `lw_putc(ch)` — one SBI putchar (the `dom.rs` `putc` helper is private).
fn lw_putc(ch: i64) -> Vec<Op> {
    vec![li(A0, ch), li(A7, SBI_PUTCHAR), Op::Ecall]
}

/// `KernelGet(a0=url_off, a1=url_len) → a0 = entry index | -1` — linearly scan
/// `__kget` for a fetch path byte-equal to `__wasm_mem[url_off..+len]`. The
/// entry index is the promise handle `LwFetch` hands the cell and
/// `LwAwaitVoid` resolves back to the body span. `-1` = no entry (the caller
/// then returns a `0` handle — never a pointer the cell would walk).
fn kernel_get_node() -> Vec<Op> {
    vec![
        Op::Comment("KernelGet(a0=url_off,a1=len) → a0=entry|-1 — __kget scan".into()),
        Op::Glob("KernelGet".into()),
        Op::Label("KernelGet".into()),
        la(T6, Addr::KGet),
        lw(T0, T6, 0),
        li(T1, i64::from(KGET_MAGIC)),
        bne(T0, T1, "kg_none"),
        lw(T5, T6, KGET_OFF_N), // n_entry
        addi(T4, T6, KGET_HDR), // entry cursor
        li(T3, 0),              // i
        Op::Label("kg_loop".into()),
        bgeu(T3, T5, "kg_none"),
        lw(T0, T4, KGET_E_URL_LEN),
        bne(T0, A1, "kg_next"),
        // memcmp __wasm_mem[a0..+a1] vs __kget[e_url_off..+e_url_len]
        lw(T2, T4, KGET_E_URL_OFF),
        add(T2, T6, T2), // src2 = __kget + url_off
        la(T1, Addr::WasmMem),
        add(T1, T1, A0), // src1 = __wasm_mem + url_off
        li(A4, 0),
        Op::Label("kg_cmp".into()),
        bgeu(A4, A1, "kg_match"),
        add(T0, T1, A4),
        lbu(T0, T0, 0),
        add(A5, T2, A4),
        lbu(A5, A5, 0),
        bne(T0, A5, "kg_next"),
        addi(A4, A4, 1),
        j("kg_cmp"),
        Op::Label("kg_match".into()),
        mv(A0, T3),
        ret(),
        Op::Label("kg_next".into()),
        addi(T3, T3, 1),
        addi(T4, T4, KGET_ENT),
        j("kg_loop"),
        Op::Label("kg_none".into()),
        li(A0, -1),
        ret(),
    ]
}

/// `LwFetch(a0=url_off, a1=url_len) → a0 = promise handle` — libwasm `fetch`.
/// Prints `GET <path>` (the `GetFile`/`WasmFetch` router shape), resolves the
/// path through `KernelGet`, and allocates a `__prom` record as the promise the
/// cell then awaits. A `/bios/*` hit settles the record `PROM_ST_FUL` with the
/// `__kget` body span; a miss leaves it `PROM_ST_PEND` — `__kget` is the route
/// cache, so the miss is an in-flight fetch `PromDrain` resolves on the poll
/// (late hit→`FUL`, `PR_BUDGET` expiry→`REJ` with the url as the reason). `0` =
/// `__prom` table full (fail closed).
fn lw_fetch_node() -> Vec<Op> {
    let mut ops = vec![
        Op::Comment("LwFetch(a0=url_off,a1=len) → a0=promise — GET + PromAlloc + settle".into()),
        Op::Glob("LwFetch".into()),
        Op::Label("LwFetch".into()),
        addi(SP, SP, -48),
        sd(RA, SP, 40),
        sd(S0, SP, 32),
        sd(S1, SP, 24),
        sd(S2, SP, 16),
        sd(S3, SP, 8),
        mv(S0, A0),
        mv(S1, A1),
    ];
    for ch in b"GET " {
        ops.extend(lw_putc(i64::from(*ch)));
    }
    ops.extend([
        la(T0, Addr::WasmMem),
        add(A0, T0, S0), // abs url = __wasm_mem + off
        mv(A1, S1),
        jal("WasmPuts"),
    ]);
    ops.extend(lw_putc(i64::from(b'\n')));
    // s2 = KernelGet(url) → entry idx | -1
    ops.extend([mv(A0, S0), mv(A1, S1), jal("KernelGet"), mv(S2, A0)]);
    // s3 = PromAlloc() → promise handle | 0
    ops.extend([jal("PromAlloc"), mv(S3, A0), beq(S3, X0, "lf_out")]);
    // a3 = rec = PromGet(s3); record url as pending-arg + rejection reason.
    ops.extend([
        mv(A0, S3),
        jal("PromGet"),
        mv(A3, A0),
        sw(S0, A3, PR_AOFF),
        sw(S1, A3, PR_ALEN),
        sw(S0, A3, PR_EOFF),
        sw(S1, A3, PR_ELEN),
        // A KernelGet miss leaves the record `PROM_ST_PEND` (set by PromAlloc):
        // `__kget` is the route *cache*, and a miss means "the host may still
        // resolve it" — the real-fetch semantic (an unrouted url pends, then
        // the host's roundtrip settles it). `PromDrain` re-runs `KernelGet` on
        // the stored url each tick and rejects at `PR_BUDGET`=0. An await on a
        // pending handle suspends (`LwAwaitVoid`→`P_ASUSP`) instead of the old
        // inline-reject.
        blt(S2, X0, "lf_ret"), // miss → stay pending for PromDrain
    ]);
    // fulfill: PR_VOFF/VLEN = __kget[s2].json_off/len
    ops.extend([
        la(T6, Addr::KGet),
        li(T0, KGET_ENT as i64),
        mul(T1, S2, T0),
        addi(T1, T1, KGET_HDR),
        add(T1, T6, T1), // ent = __kget + KGET_HDR + idx*KGET_ENT
        lw(T2, T1, KGET_E_JSON_OFF),
        lw(T3, T1, KGET_E_JSON_LEN),
        sw(T2, A3, PR_VOFF),
        sw(T3, A3, PR_VLEN),
        li(T2, PROM_ST_FUL),
        sw(T2, A3, PR_STATE),
        Op::Label("lf_ret".into()),
        mv(A0, S3), // promise handle
        Op::Label("lf_out".into()),
        ld(RA, SP, 40),
        ld(S0, SP, 32),
        ld(S1, SP, 24),
        ld(S2, SP, 16),
        ld(S3, SP, 8),
        addi(SP, SP, 48),
        ret(),
    ]);
    ops
}

/// `LwAwaitSup() → a0=1` — `libwasm_await_supported`: the await lane is live.
/// A `LwFetch` route hit is already `FUL` by the time `libwasm_await__void`
/// runs (resolved-sync), and a miss suspends on the `PEND` record until
/// `PromDrain` settles it — the full Asyncify unwind/rewind the cell's
/// `await_supported=1` path is built for.
fn lw_awaitsup_node() -> Vec<Op> {
    vec![
        Op::Comment("LwAwaitSup → a0=1 (resolved-sync await)".into()),
        Op::Glob("LwAwaitSup".into()),
        Op::Label("LwAwaitSup".into()),
        li(A0, 1),
        ret(),
    ]
}

/// `LwAwaitVoid(a0=slot)` — `libwasm_await__void`. Matches the interpreter's
/// `libwasm_await__void` dispatch: on a rewind re-call (`state==REWINDING`)
/// restore `NORMAL` and return; otherwise resolve the `__kget` body for `slot`
/// into `cur` (the value `LwAwaitVal` writes) *then* arm the Asyncify unwind —
/// `__asyncify_state=UNWINDING`, `__asyncify_data=data`, and the `{pos,end}`
/// descriptor at `data`. The cell's own instrumentation sees UNWINDING and
/// unwinds out of `_start`; `jit_after` then drives `stop_unwind`→`start_rewind`
/// →re-invoke `_start`, which rewinds past this call to `libwasm_await_value`.
fn lw_awaitvoid_node() -> Vec<Op> {
    let mut ops = vec![
        Op::Comment("LwAwaitVoid(a0=slot) — resolve cur + arm UNWINDING".into()),
        Op::Glob("LwAwaitVoid".into()),
        Op::Label("LwAwaitVoid".into()),
        addi(SP, SP, -48),
        sd(RA, SP, 40),
        sd(S0, SP, 32),
        sd(S1, SP, 24),
        sd(S2, SP, 16),
        mv(S0, A0), // slot
        // s1 = state_global idx (JitAx), -1 = MVP cell / no asyncify
        li(A0, i64::from(AX_STATE_GLOB)),
        jal("JitAx"),
        mv(S1, A0),
        // state = globals[s1] (when asyncify present)
        blt(S1, X0, "lav_resolve"),
        slli(T0, S1, 3),
        li(T1, i64::from(OFF_GLOB)),
        add(T0, T0, T1),
        la(T1, Addr::JitHdr),
        add(T0, T1, T0), // &globals[state_idx]
        ld(T2, T0, 0),
        // DIAG: print 'v' + slot + 's' + state (a0/a7 scratch; S0/T2 live)
        li(A0, i64::from(b'v')),
        li(A7, SBI_PUTCHAR),
        Op::Ecall,
        addi(A0, S0, 48),
        li(A7, SBI_PUTCHAR),
        Op::Ecall,
        li(A0, i64::from(b's')),
        li(A7, SBI_PUTCHAR),
        Op::Ecall,
        addi(A0, T2, 48),
        li(A7, SBI_PUTCHAR),
        Op::Ecall,
        li(T1, 2), // STATE_REWINDING
        bne(T2, T1, "lav_resolve"),
        // rewind re-call: restore NORMAL, leave cur as the resolved value
        sd(X0, T0, 0),
        li(S1, -1),
        Op::Label("lav_resolve".into()),
    ];
    // resolve the promise handle → cur + afail via the record's settle state.
    // fulfilled → cur = the __kget body span; rejected → cur empty + afail=1
    // (the reason stays in PR_EOFF/PR_ELEN for `libwasm_await_error`); pending/
    // free → cur empty, no fail (the bounded-resolved default — a genuinely
    // pending fetch is the PromDrain suspend/resume lane, not this path).
    ops.extend([
        la(T4, Addr::DomT),
        sw(X0, T4, H_KCUR_OFF),
        sw(X0, T4, H_KCUR_LEN),
        la(T6, Addr::Prom),
        sw(X0, T6, P_AFAIL),
        sw(S0, T6, P_ALAST), // last-awaited handle → await_error
        beq(S0, X0, "lav_arm"),
        mv(A0, S0),
        jal("PromGet"),
        beq(A0, X0, "lav_arm"),
        lw(T0, A0, PR_STATE),
        li(T1, PROM_ST_FUL),
        beq(T0, T1, "lav_ful"),
        li(T1, PROM_ST_REJ),
        beq(T0, T1, "lav_rej"),
        li(T1, PROM_ST_PEND),
        beq(T0, T1, "lav_pend"),
        j("lav_arm"),
        // pending — park: record the promise the cell suspended on; jit_after
        // sees UNWINDING+P_ASUSP and skips the rewind until PromDrain settles
        // it, then the foreground loop re-invokes `_start` to rewind.
        Op::Label("lav_pend".into()),
        la(T6, Addr::Prom),
        sw(S0, T6, P_ASUSP),
        j("lav_arm"),
        Op::Label("lav_ful".into()),
        // Only a fetch record's PR_VOFF is a __kget body offset — the span
        // `await_value` copies. A combinator/i32-array result keeps a
        // __wasm_mem element offset there (its value is a handle array, not a
        // string), so leave `cur` empty rather than misread __kget.
        lw(T0, A0, PR_KIND),
        bne(T0, X0, "lav_arm"), // PROM_K_FETCH only
        lw(T2, A0, PR_VOFF),
        lw(T3, A0, PR_VLEN),
        la(T4, Addr::DomT),
        sw(T2, T4, H_KCUR_OFF),
        sw(T3, T4, H_KCUR_LEN),
        j("lav_arm"),
        Op::Label("lav_rej".into()),
        la(T6, Addr::Prom),
        li(T1, 1),
        sw(T1, T6, P_AFAIL),
        Op::Label("lav_arm".into()),
    ]);
    // arm the Asyncify unwind (only when the cell has asyncify globals)
    ops.extend([
        blt(S1, X0, "lav_out"), // no asyncify → just resolved sync
        // s2 = data_global idx
        li(A0, i64::from(AX_DATA_GLOB)),
        jal("JitAx"),
        mv(S2, A0),
        // data = OFF_MEMB - KGET_TAIL_BYTES  (mem_pages*64KiB, the scratch base)
        la(T6, Addr::JitHdr),
        ld(T0, T6, OFF_MEMB),
        li(T1, KGET_TAIL_BYTES as i64),
        sub(T0, T0, T1), // data (a __wasm_mem offset)
        // descriptor {pos=data+8, end=data+KGET_ASTK_BYTES} at __wasm_mem[data]
        la(T6, Addr::WasmMem),
        add(T6, T6, T0), // &wasm_mem[data]
        addi(T1, T0, 8),
        sw(T1, T6, 0), // pos = data+8
        li(T1, KGET_ASTK_BYTES as i64),
        add(T1, T0, T1),
        sw(T1, T6, 4), // end = data+ASTK
        // globals[state_idx] = UNWINDING ; globals[data_idx] = data
        slli(T1, S1, 3),
        li(T2, i64::from(OFF_GLOB)),
        add(T1, T1, T2),
        la(T2, Addr::JitHdr),
        add(T1, T2, T1), // &globals[state_idx]
        li(T2, 1),       // STATE_UNWINDING
        sd(T2, T1, 0),
        blt(S2, X0, "lav_out"),
        slli(T1, S2, 3),
        li(T2, i64::from(OFF_GLOB)),
        add(T1, T1, T2),
        la(T2, Addr::JitHdr),
        add(T1, T2, T1), // &globals[data_idx]
        sd(T0, T1, 0),   // __asyncify_data = data
        Op::Label("lav_out".into()),
        li(A0, 0),
        ld(RA, SP, 40),
        ld(S0, SP, 32),
        ld(S1, SP, 24),
        ld(S2, SP, 16),
        addi(SP, SP, 48),
        ret(),
    ]);
    ops
}

/// `LwAwaitVal(a0=raw)` — `libwasm_await_value`: write the current resolution
/// as a D `string {len:u32, ptr:u32}` at `__wasm_mem[raw]`. The `__kget` body
/// is copied into the `__wasm_mem` string pool — the region past the cell's
/// declared `mem_pages` that `OFF_MEMB` covers but `memory.size` does not
/// report, so the cell dereferences `ptr` while its allocator never reaches
/// it. `raw`/`ptr` are `__wasm_mem` offsets, like the interpreter's
/// `write_string`.
fn lw_awaitval_node() -> Vec<Op> {
    let mut ops = vec![
        Op::Comment("LwAwaitVal(a0=raw) — write {len,ptr} of cur into __wasm_mem".into()),
        Op::Glob("LwAwaitVal".into()),
        Op::Label("LwAwaitVal".into()),
        addi(SP, SP, -96),
        sd(A0, SP, 8), // save raw
        sd(RA, SP, 16),
        sd(S0, SP, 24),
        sd(S1, SP, 32),
        la(T4, Addr::DomT),
        lw(T2, T4, H_KCUR_OFF), // json_off in __kget
        lw(T3, T4, H_KCUR_LEN), // json_len
        lw(T5, T4, H_KSTR_CUR), // pool cursor (bytes used)
    ];
    ops.extend([
        // kstr_cur + len overflow → wrap the bump cursor to 0.
        add(T1, T5, T3),
        li(T6, KGET_KSTR_BYTES as i64),
        bltu(T1, T6, "lavl_ok"),
        li(T5, 0),
        Op::Label("lavl_ok".into()),
        // dst_off = pool_base + kstr_cur; pool_base = __jit[OFF_MEMB] - KSTR
        la(T6, Addr::JitHdr),
        ld(T6, T6, OFF_MEMB),
        li(T1, KGET_KSTR_BYTES as i64),
        sub(T6, T6, T1), // pool_base wasm-offset = mem_pages*64K
        add(T0, T6, T5), // dst_off
        // src = __kget + cur_off ; dst = __wasm_mem + dst_off
        la(T1, Addr::KGet),
        add(T1, T1, T2), // src
        la(T6, Addr::WasmMem),
        add(T6, T6, T0), // dst abs
        li(A4, 0),
        Op::Label("lavl_cp".into()),
        bgeu(A4, T3, "lavl_cpd"),
        add(A5, T1, A4),
        lbu(A5, A5, 0),
        add(A3, T6, A4),
        sb(A5, A3, 0),
        addi(A4, A4, 1),
        j("lavl_cp"),
        Op::Label("lavl_cpd".into()),
        // NUL-terminate: parseJSON!ThreadMemAllocator is a validating parser whose
        // `unnest` checks `*m_text != '\0'` one byte past the closing bracket.
        add(A3, T6, T3),
        sb(X0, A3, 0),
        // write {len,ptr} at __wasm_mem[raw]
        ld(A0, SP, 8), // raw
        la(T1, Addr::WasmMem),
        add(T1, T1, A0), // raw abs
        sw(T3, T1, 0),   // len
        sw(T0, T1, 4),   // ptr = dst_off (a __wasm_mem offset the cell reads)
        // kstr_cur += align8(len)
        addi(T3, T3, 7),
        Op::Andi {
            rd: T3,
            rs: T3,
            imm: -8,
        },
        add(T5, T5, T3),
        sw(T5, T4, H_KSTR_CUR),
        li(A0, 0),
        ld(RA, SP, 16),
        ld(S0, SP, 24),
        ld(S1, SP, 32),
        addi(SP, SP, 96),
        ret(),
    ]);
    ops
}

/// `lavl_hx` — DIAG helper: print `T0` as 16 hex digits via the shared
/// `hexdig` table. Leaf routine; clobbers a0/a2/a6/a7/t0/t2 (caller saves
/// what it needs). `ra` is preserved (no nested `jal`).
fn lw_phex_node() -> Vec<Op> {
    vec![
        Op::Label("lavl_hx".into()),
        li(A2, 16),
        Op::Label("lavl_hx_l".into()),
        Op::Srli {
            rd: T2,
            rs: T0,
            shamt: 60,
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
        la(A6, Addr::Label("hexdig".into())),
        add(A6, A6, T2),
        lbu(A0, A6, 0),
        li(A7, SBI_PUTCHAR),
        Op::Ecall,
        addi(A2, A2, -1),
        bne(A2, X0, "lavl_hx_l"),
        ret(),
    ]
}

/// libwasm property/event name literals — a jumped-over data island so the
/// `Op::Word` bytes are never executed. Each literal is NUL-padded to a word.
/// `PromAlloc() → a0 = handle (1..=PROM_MAX) | 0` — lazily init the `__prom`
/// header, then bump-claim a record: zero it and mark it `PROM_ST_PEND` /
/// `PROM_K_FETCH`. Returns the record index +1 (the promise handle). `0` =
/// table full — the caller fails closed (returns a null promise the cell
/// treats as unresolved, never a pointer it dereferences).
fn prom_alloc_node() -> Vec<Op> {
    vec![
        Op::Comment("PromAlloc() → a0=handle|0 — claim a __prom record".into()),
        Op::Glob("PromAlloc".into()),
        Op::Label("PromAlloc".into()),
        la(T6, Addr::Prom),
        lw(T0, T6, P_MAGIC),
        li(T1, PROM_MAGIC),
        beq(T0, T1, "pa_have"),
        sw(T1, T6, P_MAGIC),
        sw(X0, T6, P_N),
        sw(X0, T6, P_AFAIL),
        sw(X0, T6, P_ALAST),
        sw(X0, T6, P_ASUSP),
        Op::Label("pa_have".into()),
        lw(T0, T6, P_N), // i = n_alloc
        li(T1, PROM_MAX),
        bgeu(T0, T1, "pa_full"),
        // rec = __prom + PROM_HDR + i*PROM_REC
        li(T1, PROM_REC as i64),
        mul(T2, T0, T1),
        addi(T2, T2, PROM_HDR),
        add(T2, T6, T2), // rec abs
        // zero PROM_REC bytes (word-at-a-time)
        li(T3, 0),
        Op::Label("pa_z".into()),
        li(T4, PROM_REC as i64),
        bgeu(T3, T4, "pa_zd"),
        add(T4, T2, T3),
        sw(X0, T4, 0),
        addi(T3, T3, 4),
        j("pa_z"),
        Op::Label("pa_zd".into()),
        li(T4, PROM_ST_PEND),
        sw(T4, T2, PR_STATE),
        sw(X0, T2, PR_KIND), // PROM_K_FETCH
        li(T4, PROM_BUDGET),
        sw(T4, T2, PR_BUDGET), // pending-poll grace before a miss rejects
        addi(T0, T0, 1),
        sw(T0, T6, P_N),
        mv(A0, T0),
        ret(),
        Op::Label("pa_full".into()),
        li(A0, 0),
        ret(),
    ]
}

/// `PromGet(a0=handle) → a0 = record addr | 0` — bounds-checked `__prom` ref:
/// `0` when the table is absent or `handle` is 0 / past `n_alloc`.
fn prom_get_node() -> Vec<Op> {
    vec![
        Op::Comment("PromGet(a0=handle) → a0=rec|0 — bounds-checked __prom ref".into()),
        Op::Glob("PromGet".into()),
        Op::Label("PromGet".into()),
        la(T6, Addr::Prom),
        lw(T0, T6, P_MAGIC),
        li(T1, PROM_MAGIC),
        bne(T0, T1, "pg_none"),
        beq(A0, X0, "pg_none"), // null handle
        lw(T1, T6, P_N),
        bltu(T1, A0, "pg_none"), // handle > n_alloc
        addi(T0, A0, -1),
        li(T1, PROM_REC as i64),
        mul(T2, T0, T1),
        addi(T2, T2, PROM_HDR),
        add(A0, T6, T2),
        ret(),
        Op::Label("pg_none".into()),
        li(A0, 0),
        ret(),
    ]
}

/// `LwAwaitFail() → a0 = __prom[P_AFAIL]` — `libwasm_await_failed`: 1 when the
/// last `libwasm_await__void` target rejected, 0 when it fulfilled (or the
/// promise table is absent). Leaf; reads only the header.
fn lw_awaitfail_node() -> Vec<Op> {
    vec![
        Op::Comment("LwAwaitFail() → a0=afail — libwasm_await_failed".into()),
        Op::Glob("LwAwaitFail".into()),
        Op::Label("LwAwaitFail".into()),
        la(T6, Addr::Prom),
        lw(T0, T6, P_MAGIC),
        li(T1, PROM_MAGIC),
        bne(T0, T1, "laf_zero"),
        lw(A0, T6, P_AFAIL),
        ret(),
        Op::Label("laf_zero".into()),
        li(A0, 0),
        ret(),
    ]
}

/// `LwAwaitErr(a0=raw)` — `libwasm_await_error`: write the last-awaited
/// promise's rejection reason as a D `string {len:u32, ptr:u32}` at
/// `__wasm_mem[raw]`. The reason is the failing url, already a `__wasm_mem`
/// span (`PR_EOFF`/`PR_ELEN`), so unlike `LwAwaitVal` no copy is needed —
/// `ptr` is emitted verbatim. On a fulfilled/absent last await it writes a
/// zero-length string.
fn lw_awaiterr_node() -> Vec<Op> {
    vec![
        Op::Comment("LwAwaitErr(a0=raw) — write {len,ptr} of rejection reason".into()),
        Op::Glob("LwAwaitErr".into()),
        Op::Label("LwAwaitErr".into()),
        addi(SP, SP, -32),
        sd(A0, SP, 0), // save raw (PromGet clobbers a0)
        sd(RA, SP, 8),
        sd(S1, SP, 16),
        sd(S0, SP, 24),
        li(S0, 0), // len
        li(S1, 0), // ptr
        la(T6, Addr::Prom),
        lw(T0, T6, P_MAGIC),
        li(T1, PROM_MAGIC),
        bne(T0, T1, "lae_wr"),
        lw(A0, T6, P_ALAST),
        jal("PromGet"),
        beq(A0, X0, "lae_wr"),
        lw(T0, A0, PR_STATE),
        li(T1, PROM_ST_REJ),
        bne(T0, T1, "lae_wr"),
        lw(S0, A0, PR_ELEN),
        lw(S1, A0, PR_EOFF),
        Op::Label("lae_wr".into()),
        // write {len,ptr} at __wasm_mem[raw]  (raw was clobbered by PromGet —
        // it was the a0 arg; reload from the caller's stack save)
        ld(A0, SP, 0),
        la(T1, Addr::WasmMem),
        add(T1, T1, A0),
        sw(S0, T1, 0),
        sw(S1, T1, 4),
        ld(RA, SP, 8),
        ld(S1, SP, 16),
        ld(S0, SP, 24),
        addi(SP, SP, 32),
        ret(),
    ]
}

/// `LwAddInts(a0=len, a1=wm_ptr) → a0 = i32-array handle` — `libwasm_add__ints`
/// (libwasm len-before-ptr order). Allocates a `PROM_K_IARR` `__prom` record
/// holding the `__wasm_mem` element span — the bounded handle-array the
/// `libasync_promise_*` combinators consume. `0` = table full (fail closed).
fn lw_addints_node() -> Vec<Op> {
    vec![
        Op::Comment("LwAddInts(a0=len,a1=wmptr) → a0=i32-array handle".into()),
        Op::Glob("LwAddInts".into()),
        Op::Label("LwAddInts".into()),
        addi(SP, SP, -32),
        sd(RA, SP, 24),
        sd(S0, SP, 16),
        sd(S1, SP, 8),
        sd(S2, SP, 0),
        mv(S0, A0), // count
        mv(S1, A1), // __wasm_mem elem ptr
        jal("PromAlloc"),
        mv(S2, A0),
        beq(S2, X0, "lai_out"),
        mv(A0, S2),
        jal("PromGet"), // a0 = rec
        li(T0, PROM_K_IARR),
        sw(T0, A0, PR_KIND),
        li(T0, PROM_ST_FUL),
        sw(T0, A0, PR_STATE), // arrays are always resolved
        sw(S1, A0, PR_VOFF),  // __wasm_mem elem ptr
        sw(S0, A0, PR_VLEN),  // count
        Op::Label("lai_out".into()),
        mv(A0, S2),
        ld(S2, SP, 0),
        ld(RA, SP, 24),
        ld(S0, SP, 16),
        ld(S1, SP, 8),
        addi(SP, SP, 32),
        ret(),
    ]
}

/// `PromScan(a0=arrH, a1=kind, a2=rrec)` — fill `rrec` (a `__prom` record addr)
/// with the aggregate settle-state of the `PROM_K_IARR` handle array `arrH`.
/// Shared by `PromCombine` (fresh record) and `PromDrain` (re-settle in place).
/// - all: first REJ → REJ(reason); any PEND → PEND(SUB=count); else FUL(array)
/// - any: first FUL → FUL(value);  any PEND → PEND;         all REJ → REJ(last)
/// - allsettled: any PEND → PEND; else FUL(array)
fn prom_scan_node() -> Vec<Op> {
    vec![
        Op::Comment("PromScan(a0=arrH,a1=kind,a2=rrec) — aggregate settle-state".into()),
        Op::Glob("PromScan".into()),
        Op::Label("PromScan".into()),
        addi(SP, SP, -96),
        sd(RA, SP, 88),
        sd(S0, SP, 80),
        sd(S1, SP, 72),
        sd(S2, SP, 56),
        sd(S3, SP, 48),
        sd(S5, SP, 40),
        sd(S6, SP, 32),
        sd(S7, SP, 24),
        sd(S8, SP, 16),
        mv(S0, A0), // arrH
        mv(S1, A1), // kind
        mv(S2, A2), // rrec
        // arec = the input array record
        jal("PromGet"),
        beq(A0, X0, "ps_out"),
        mv(S3, A0),
        lw(T0, S3, PR_KIND),
        li(T1, PROM_K_IARR),
        bne(T0, T1, "ps_out"),
        // rrec header: kind / input-array / count / pending=0
        sw(S1, S2, PR_KIND),
        sw(S0, S2, PR_AOFF),
        lw(S6, S3, PR_VLEN),
        // Clamp the element count to the promise-table bound — a cell-supplied
        // `add__ints(len)` past `PROM_MAX` can't hold that many live promises
        // anyway, and an unbounded count would scan `__wasm_mem` out of range.
        li(T1, PROM_MAX),
        bltu(S6, T1, "ps_len_ok"),
        mv(S6, T1),
        Op::Label("ps_len_ok".into()),
        sw(S6, S2, PR_ALEN),
        sw(X0, S2, PR_SUB),
        li(T0, PROM_ST_PEND),
        sw(T0, S2, PR_STATE), // default until scan settles
        la(T0, Addr::WasmMem),
        lw(T1, S3, PR_VOFF),
        add(S7, T0, T1), // elem base = __wasm_mem + VOFF
        li(S5, 0),       // i
        Op::Label("ps_loop".into()),
        bgeu(S5, S6, "ps_done"),
        slli(T0, S5, 2),
        add(T0, S7, T0),
        lw(A0, T0, 0), // elem = promise handle
        jal("PromGet"),
        mv(S8, A0),
        beq(S8, X0, "ps_next"), // invalid handle → skip
        lw(T0, S8, PR_STATE),
        li(T1, PROM_K_ALL),
        beq(S1, T1, "ps_all"),
        li(T1, PROM_K_ANY),
        beq(S1, T1, "ps_any"),
        j("ps_alls"),
        // ---- all ----
        Op::Label("ps_all".into()),
        li(T1, PROM_ST_REJ),
        beq(T0, T1, "ps_all_rej"),
        li(T1, PROM_ST_FUL),
        bne(T0, T1, "ps_pend"),
        j("ps_next"),
        Op::Label("ps_all_rej".into()),
        lw(T2, S8, PR_EOFF),
        sw(T2, S2, PR_EOFF),
        lw(T2, S8, PR_ELEN),
        sw(T2, S2, PR_ELEN),
        li(T2, PROM_ST_REJ),
        sw(T2, S2, PR_STATE),
        j("ps_done"),
        // ---- any ----
        Op::Label("ps_any".into()),
        li(T1, PROM_ST_FUL),
        beq(T0, T1, "ps_any_ful"),
        li(T1, PROM_ST_REJ),
        bne(T0, T1, "ps_pend"),
        lw(T2, S8, PR_EOFF), // track last rejection reason
        sw(T2, S2, PR_EOFF),
        lw(T2, S8, PR_ELEN),
        sw(T2, S2, PR_ELEN),
        j("ps_next"),
        Op::Label("ps_any_ful".into()),
        lw(T2, S8, PR_VOFF),
        sw(T2, S2, PR_VOFF),
        lw(T2, S8, PR_VLEN),
        sw(T2, S2, PR_VLEN),
        li(T2, PROM_ST_FUL),
        sw(T2, S2, PR_STATE),
        j("ps_done"),
        // ---- allsettled ----
        Op::Label("ps_alls".into()),
        li(T1, PROM_ST_PEND),
        beq(T0, T1, "ps_pend"),
        li(T1, PROM_ST_FREE),
        beq(T0, T1, "ps_pend"),
        j("ps_next"),
        Op::Label("ps_pend".into()),
        lw(T2, S2, PR_SUB),
        addi(T2, T2, 1),
        sw(T2, S2, PR_SUB),
        Op::Label("ps_next".into()),
        addi(S5, S5, 1),
        j("ps_loop"),
        // scan done with no early settle — resolve by pending count + kind
        Op::Label("ps_done".into()),
        lw(T2, S2, PR_STATE),
        li(T1, PROM_ST_PEND),
        bne(T2, T1, "ps_out"), // already FUL/REJ (early settle) → keep
        lw(T2, S2, PR_SUB),
        li(T1, PROM_K_ANY),
        beq(S1, T1, "ps_any_d"),
        beq(T2, X0, "ps_set_ful"), // all/alls: no pending → FUL
        j("ps_out"),               // stays PEND
        Op::Label("ps_any_d".into()),
        bne(T2, X0, "ps_out"), // pending remain → stays PEND
        li(T1, PROM_ST_REJ),   // no ful + no pend → all rejected
        sw(T1, S2, PR_STATE),
        j("ps_out"),
        Op::Label("ps_set_ful".into()),
        li(T1, PROM_ST_FUL),
        sw(T1, S2, PR_STATE),
        lw(T1, S3, PR_VOFF), // result = the input handle array
        sw(T1, S2, PR_VOFF),
        lw(T1, S3, PR_VLEN),
        sw(T1, S2, PR_VLEN),
        Op::Label("ps_out".into()),
        ld(RA, SP, 88),
        ld(S0, SP, 80),
        ld(S1, SP, 72),
        ld(S2, SP, 56),
        ld(S3, SP, 48),
        ld(S5, SP, 40),
        ld(S6, SP, 32),
        ld(S7, SP, 24),
        ld(S8, SP, 16),
        addi(SP, SP, 96),
        ret(),
    ]
}

/// `PromCombine(a0=arrH, a1=kind) → a0 = promise handle | 0` — allocate a
/// `__prom` record and `PromScan` the `arrH` handle array into it.
fn prom_combine_node() -> Vec<Op> {
    vec![
        Op::Comment("PromCombine(a0=arrH,a1=kind) → a0=promise|0".into()),
        Op::Glob("PromCombine".into()),
        Op::Label("PromCombine".into()),
        addi(SP, SP, -48),
        sd(RA, SP, 40),
        sd(S0, SP, 32), // arrH
        sd(S1, SP, 24), // kind
        sd(S2, SP, 16), // result handle
        mv(S0, A0),
        mv(S1, A1),
        jal("PromAlloc"),
        mv(S2, A0),
        beq(S2, X0, "pcb_out"),
        mv(A0, S2),
        jal("PromGet"), // a0 = rrec
        mv(A2, A0),
        mv(A0, S0), // arrH
        mv(A1, S1), // kind
        jal("PromScan"),
        Op::Label("pcb_out".into()),
        mv(A0, S2),
        ld(RA, SP, 40),
        ld(S0, SP, 32),
        ld(S1, SP, 24),
        ld(S2, SP, 16),
        addi(SP, SP, 48),
        ret(),
    ]
}

/// `LwPromAll(a0=arrH) → a0=promise` — `libasync_promise_all__promise`.
fn lw_promall_node() -> Vec<Op> {
    vec![
        Op::Comment("LwPromAll(a0=arrH) → promise — libasync_promise_all__promise".into()),
        Op::Glob("LwPromAll".into()),
        Op::Label("LwPromAll".into()),
        li(A1, PROM_K_ALL),
        j("PromCombine"),
    ]
}

/// `LwPromAny(a0=arrH) → a0=promise` — `libasync_promise_any__promise`.
fn lw_promany_node() -> Vec<Op> {
    vec![
        Op::Comment("LwPromAny(a0=arrH) → promise — libasync_promise_any__promise".into()),
        Op::Glob("LwPromAny".into()),
        Op::Label("LwPromAny".into()),
        li(A1, PROM_K_ANY),
        j("PromCombine"),
    ]
}

/// `LwPromAlls(a0=arrH) → a0=promise` — `libasync_promise_allsettled__promise`.
fn lw_promalls_node() -> Vec<Op> {
    vec![
        Op::Comment("LwPromAlls(a0=arrH) → promise — libasync_promise_allsettled".into()),
        Op::Glob("LwPromAlls".into()),
        Op::Label("LwPromAlls".into()),
        li(A1, PROM_K_ALLS),
        j("PromCombine"),
    ]
}

/// `LwNoteFul(a0=handle)` — `libwasm_note_await_ok`: the cell reports an await
/// resolved with the value carried by `handle`. Bounded correlate of the
/// reference `objGet(handle) → asyncify.value; failed=false`: `P_AFAIL`→0,
/// `P_ALAST`→handle, and — when `handle` names a `__prom` record — its
/// `PR_VOFF`/`PR_VLEN` body span is adopted as `H_KCUR` so `libwasm_await_value`
/// returns it. A non-`__prom` handle still clears `afail` (value unsurfaced).
fn lw_noteful_node() -> Vec<Op> {
    vec![
        Op::Comment("LwNoteFul(a0=handle) — note_await_ok: record resolution".into()),
        Op::Glob("LwNoteFul".into()),
        Op::Label("LwNoteFul".into()),
        addi(SP, SP, -32),
        sd(RA, SP, 24),
        sd(S0, SP, 16),
        mv(S0, A0),
        la(T6, Addr::Prom),
        sw(X0, T6, P_AFAIL),
        sw(S0, T6, P_ALAST),
        mv(A0, S0),
        jal("PromGet"),
        beq(A0, X0, "lnf_out"),
        // Only a fetch record's PR_VOFF is a __kget body offset — the kind
        // `await_value` copies. A combinator/i32-array record's PR_VOFF is a
        // __wasm_mem element offset, so adopting it would misread __kget.
        lw(T0, A0, PR_KIND),
        bne(T0, X0, "lnf_out"), // PROM_K_FETCH only
        lw(T2, A0, PR_VOFF),
        lw(T3, A0, PR_VLEN),
        la(T4, Addr::DomT),
        sw(T2, T4, H_KCUR_OFF),
        sw(T3, T4, H_KCUR_LEN),
        Op::Label("lnf_out".into()),
        li(A0, 0),
        ld(RA, SP, 24),
        ld(S0, SP, 16),
        addi(SP, SP, 32),
        ret(),
    ]
}

/// `LwNoteRej(a0=handle)` — `libwasm_note_await_fail`: the cell reports an
/// await rejected with the error carried by `handle`. `P_AFAIL`→1 and
/// `P_ALAST`→handle, so `libwasm_await_error` reads that record's
/// `PR_EOFF`/`PR_ELEN` reason span. A non-`__prom` handle still sets `afail`.
fn lw_noterej_node() -> Vec<Op> {
    vec![
        Op::Comment("LwNoteRej(a0=handle) — note_await_fail: record rejection".into()),
        Op::Glob("LwNoteRej".into()),
        Op::Label("LwNoteRej".into()),
        la(T6, Addr::Prom),
        li(T1, 1),
        sw(T1, T6, P_AFAIL),
        sw(A0, T6, P_ALAST),
        li(A0, 0),
        ret(),
    ]
}

/// `PromDrain()` — the pending-promise settle pass, run from the timer tick.
/// For each `PROM_ST_PEND` record: a `PROM_K_FETCH` re-runs `KernelGet` on its
/// stored url (fulfills on a hit, rejects when `PR_BUDGET` hits 0); a combinator
/// re-scans its input array in place via `PromScan`. After the scan, if the
/// suspended `_start`'s promise (`P_ASUSP`) has settled, `PromDrain` clears it
/// and raises `P_RESUME` so `trap_timer` re-invokes the cell (`JitCall`) to
/// finish the asyncify rewind. Fail-closed: budget expiry rejects, never wedges.
fn prom_drain_node() -> Vec<Op> {
    vec![
        Op::Comment("PromDrain — settle pending __prom records + flag resume".into()),
        Op::Glob("PromDrain".into()),
        Op::Label("PromDrain".into()),
        addi(SP, SP, -48),
        sd(RA, SP, 40),
        sd(S0, SP, 32),
        sd(S1, SP, 24),
        sd(S2, SP, 16),
        sd(S3, SP, 8),
        la(T6, Addr::Prom),
        lw(T0, T6, P_MAGIC),
        li(T1, PROM_MAGIC),
        bne(T0, T1, "pd_out"),
        lw(S1, T6, P_N),
        li(S0, 0),
        Op::Label("pd_loop".into()),
        bgeu(S0, S1, "pd_res"),
        li(T0, PROM_REC as i64),
        mul(T1, S0, T0),
        addi(T1, T1, PROM_HDR),
        add(S2, T6, T1), // rec
        lw(T0, S2, PR_STATE),
        li(T1, PROM_ST_PEND),
        bne(T0, T1, "pd_next"),
        lw(T2, S2, PR_BUDGET),
        addi(T2, T2, -1),
        sw(T2, S2, PR_BUDGET),
        lw(T3, S2, PR_KIND),
        beq(T3, X0, "pd_fetch"),
        j("pd_comb"),
        Op::Label("pd_fetch".into()),
        lw(A0, S2, PR_AOFF),
        lw(A1, S2, PR_ALEN),
        jal("KernelGet"),
        mv(S3, A0),
        blt(S3, X0, "pd_miss"),
        la(T6, Addr::KGet),
        li(T0, KGET_ENT as i64),
        mul(T1, S3, T0),
        addi(T1, T1, KGET_HDR),
        add(T1, T6, T1),
        lw(T2, T1, KGET_E_JSON_OFF),
        sw(T2, S2, PR_VOFF),
        lw(T2, T1, KGET_E_JSON_LEN),
        sw(T2, S2, PR_VLEN),
        li(T2, PROM_ST_FUL),
        sw(T2, S2, PR_STATE),
        la(T6, Addr::Prom),
        j("pd_next"),
        Op::Label("pd_miss".into()),
        la(T6, Addr::Prom),
        lw(T2, S2, PR_BUDGET),
        blt(X0, T2, "pd_next"), // budget>0 → stay pending
        li(T2, PROM_ST_REJ),
        sw(T2, S2, PR_STATE),
        j("pd_next"),
        Op::Label("pd_comb".into()),
        la(T6, Addr::Prom),
        lw(A0, S2, PR_AOFF),
        lw(A1, S2, PR_KIND),
        mv(A2, S2),
        jal("PromScan"),
        la(T6, Addr::Prom),
        lw(T0, S2, PR_STATE),
        li(T1, PROM_ST_PEND),
        bne(T0, T1, "pd_next"),
        lw(T2, S2, PR_BUDGET),
        blt(X0, T2, "pd_next"),
        li(T2, PROM_ST_REJ),
        sw(T2, S2, PR_STATE),
        Op::Label("pd_next".into()),
        addi(S0, S0, 1),
        j("pd_loop"),
        Op::Label("pd_res".into()),
        la(T6, Addr::Prom),
        lw(A0, T6, P_ASUSP),
        beq(A0, X0, "pd_out"),
        jal("PromGet"),
        beq(A0, X0, "pd_out"),
        lw(T0, A0, PR_STATE),
        li(T1, PROM_ST_PEND),
        beq(T0, T1, "pd_out"), // still pending → keep suspended
        la(T6, Addr::Prom),
        sw(X0, T6, P_ASUSP),
        li(T0, 1),
        sw(T0, T6, P_RESUME),
        Op::Label("pd_out".into()),
        ld(RA, SP, 40),
        ld(S0, SP, 32),
        ld(S1, SP, 24),
        ld(S2, SP, 16),
        ld(S3, SP, 8),
        addi(SP, SP, 48),
        ret(),
    ]
}

fn lw_lits_node() -> Vec<Op> {
    let lit = |ops: &mut Vec<Op>, name: &str, s: &str| {
        ops.push(Op::Label(name.into()));
        let b = s.as_bytes();
        let mut i = 0;
        while i < b.len() {
            let mut w = [0u8; 4];
            let n = (b.len() - i).min(4);
            w[..n].copy_from_slice(&b[i..i + n]);
            ops.push(Op::Word(u32::from_le_bytes(w)));
            i += 4;
        }
    };
    let mut ops = vec![j("lw_lits_end")];
    lit(&mut ops, "lw_lit_innerText", "innerText");
    lit(&mut ops, "lw_lit_textContent", "textContent");
    lit(&mut ops, "lw_lit_innerHTML", "innerHTML");
    lit(&mut ops, "lw_lit_nodeValue", "nodeValue");
    lit(&mut ops, "lw_lit_value", "value");
    lit(&mut ops, "lw_lit_id", "id");
    lit(&mut ops, "lw_lit_background", "background");
    lit(&mut ops, "lw_lit_backgroundColor", "backgroundColor");
    lit(&mut ops, "lw_lit_background-color", "background-color");
    lit(&mut ops, "lw_lit_bgcolor", "bgcolor");
    lit(&mut ops, "lw_lit_color", "color");
    lit(&mut ops, "lw_lit_hidden", "hidden");
    lit(&mut ops, "lw_lit_click", "click");
    lit(&mut ops, "lw_lit_mousedown", "mousedown");
    lit(&mut ops, "lw_lit_keydown", "keydown");
    lit(&mut ops, "lw_lit_keyup", "keyup");
    lit(&mut ops, "lw_lit_keypress", "keypress");
    lit(&mut ops, "lw_lit_input", "input");
    // `__ev_obj` property names for `LwEvGet`/`LwEvCall` (the typed-getter
    // bridge). "value" reuses `lw_lit_value` above.
    lit(&mut ops, "lw_lit_clientX", "clientX");
    lit(&mut ops, "lw_lit_screenX", "screenX");
    lit(&mut ops, "lw_lit_pageX", "pageX");
    lit(&mut ops, "lw_lit_offsetX", "offsetX");
    lit(&mut ops, "lw_lit_clientY", "clientY");
    lit(&mut ops, "lw_lit_screenY", "screenY");
    lit(&mut ops, "lw_lit_pageY", "pageY");
    lit(&mut ops, "lw_lit_offsetY", "offsetY");
    lit(&mut ops, "lw_lit_code", "code");
    lit(&mut ops, "lw_lit_keyCode", "keyCode");
    lit(&mut ops, "lw_lit_which", "which");
    lit(&mut ops, "lw_lit_button", "button");
    lit(&mut ops, "lw_lit_detail", "detail");
    lit(&mut ops, "lw_lit_deltaY", "deltaY");
    lit(&mut ops, "lw_lit_type", "type");
    lit(&mut ops, "lw_lit_target", "target");
    lit(&mut ops, "lw_lit_srcElement", "srcElement");
    lit(&mut ops, "lw_lit_currentTarget", "currentTarget");
    lit(&mut ops, "lw_lit_defaultPrevented", "defaultPrevented");
    lit(&mut ops, "lw_lit_cancelable", "cancelable");
    lit(&mut ops, "lw_lit_bubbles", "bubbles");
    lit(&mut ops, "lw_lit_isTrusted", "isTrusted");
    lit(&mut ops, "lw_lit_preventDefault", "preventDefault");
    ops.push(Op::Label("lw_lits_end".into()));
    ops
}

/// `DomtDemo(a0=node, a1=keycode)` — the bounded builtin listener the M2 demo
/// registers on row 2. A keydown toggles the node's bg between the boot
/// `0x202020` and `0xc02a10`, then marks it dirty. This is the stand-in for a
/// JIT'd-cell callback while the real DOM imports are still wired — it proves
/// the input→hit-test→listener→mutation→dirty→repaint→present chain end to
/// end on the exec model. Leaf routine; a/t regs only so the `DomtKey`
/// caller's s-regs survive.
fn domt_demo_node() -> Vec<Op> {
    let mut ops = vec![
        Op::Comment("DomtDemo(a0=node,a1=code) — toggle bg + dirty".into()),
        Op::Glob("DomtDemo".into()),
        Op::Label("DomtDemo".into()),
        // rec = __dom + DOMT_HDR + node*64 (t6), scratch base t3.
        slli(T6, A0, 6),
        la(T3, Addr::DomT),
        add(T6, T6, T3),
        addi(T6, T6, DOMT_HDR as i32),
        lw(T0, T6, N_BG),
        li(T1, 0x0020_2020),
        bne(T0, T1, "domt_demo_norm"),
        li(T1, 0x00c0_2a10), // recolor target
        j("domt_demo_set"),
        Op::Label("domt_demo_norm".into()),
        li(T1, 0x0020_2020), // back to boot color
        Op::Label("domt_demo_set".into()),
        sw(T1, T6, N_BG),
        // mark_dirty: set F_DIRTY + bump the header count.
        lw(T0, T6, N_FLAGS),
        li(T1, F_DIRTY),
        or_(T0, T0, T1),
        sw(T0, T6, N_FLAGS),
        la(T6, Addr::DomT),
        lw(T0, T6, H_DIRTY),
        addi(T0, T0, 1),
        sw(T0, T6, H_DIRTY),
        ret(),
    ];
    ops.shrink_to_fit();
    ops
}

/// `DomtKey` — the tree-DOM key consumer. Drains new `INP_KQ` entries off its
/// own `DOMT_SEEN` watermark and, for each key *press*, focus-dispatches to
/// the node `H_FOCUS` points at: the node needs `N_LEV & EV_KEYDOWN` and a
/// nonzero `N_LISTEN`, which selects the handler (`LSN_DEMO` → `DomtDemo`).
/// Runs in trap context (like `DomNav`/`DomKey`) — it mutates the tree and
/// bumps `H_DIRTY`; the `trap_timer` tick then repaints. No paint here.
fn domt_key_node() -> Vec<Op> {
    let mut ops = vec![
        Op::Comment("DomtKey — INP_KQ → focused-node keydown listener → dirty".into()),
        Op::Glob("DomtKey".into()),
        Op::Label("DomtKey".into()),
        addi(SP, SP, -32),
        sd(RA, SP, 24),
        sd(S0, SP, 16),
        sd(S1, SP, 8),
        sd(S2, SP, 0),
        // s2 = __vio base (survives the DomtDemo call — it keeps to a/t regs).
        la(S2, Addr::VioBss),
        lw(S0, S2, crate::vio::INP_KQ_HEAD),
        lw(S1, S2, crate::vio::DOMT_SEEN_OFF),
        Op::Label("dtk_next".into()),
        beq(S1, S0, "dtk_done"),
        la(T6, Addr::Prom),
        lw(T1, T6, P_ASUSP),
        bne(T1, X0, "dtk_done"),
        lw(T1, T6, P_RESUME),
        bne(T1, X0, "dtk_done"),
        // t3 = KQ[s1 & 15] = (code<<8)|value
        Op::Andi {
            rd: T3,
            rs: S1,
            imm: 15,
        },
        slli(T3, T3, 2),
        addi(T3, T3, crate::vio::INP_KQ_OFF),
        add(T3, T3, S2),
        lw(T3, T3, 0),
        Op::Andi {
            rd: T4,
            rs: T3,
            imm: 0xff,
        },
        srli(T0, T3, 8), // t0 = code, t4 = value
        // press/repeat only — releases (value 0) don't dispatch.
        beq(T4, X0, "dtk_skip"),
        // Menu nav keys → `__web_dl` state switch. The shipped cell wires its
        // nav tabs with `listener=0` (the BIOS protocol — the host, not a wasm
        // callback, runs fetch/select), so the guest honours the arrows/Home/
        // End the same way `guest_cell_key` does: recompute `__dom+H_WST` mod
        // `n_state` and bump `H_DIRTY`; the `trap_timer` tick then repaints the
        // new `DlPaint` state. A missing `__web_dl` falls through to the
        // focused-node listener lane (`dtk_lsn`).
        la(T6, Addr::WebDl),
        lw(T3, T6, 0),
        li(T1, i64::from(crate::dlp::WEB_DL_MAGIC)),
        bne(T3, T1, "dtk_lsn"),
        lw(T3, T6, crate::dlp::DL_OFF_NSTATE), // t3 = n_state
        beq(T3, X0, "dtk_lsn"),
        // t0 = keycode → nav keys (t3 = n_state survives to dtk_set). Only
        // Left/Right/Home/End switch menu states — `menu_for_key` maps exactly
        // these (Up/Down are in-menu field nav, not a state change).
        li(T1, crate::vio::VIO_KEY_RIGHT),
        beq(T0, T1, "dtk_fwd"),
        li(T1, crate::vio::VIO_KEY_LEFT),
        beq(T0, T1, "dtk_back"),
        li(T1, crate::vio::VIO_KEY_HOME),
        beq(T0, T1, "dtk_home"),
        li(T1, crate::vio::VIO_KEY_END),
        beq(T0, T1, "dtk_end"),
        j("dtk_lsn"),
        // forward: wst+1, wrap to 0 at n_state.
        Op::Label("dtk_fwd".into()),
        la(T6, Addr::DomT),
        lw(T2, T6, H_WST),
        addi(T2, T2, 1),
        bltu(T2, T3, "dtk_set"),
        li(T2, 0),
        j("dtk_set"),
        // back: wst-1, wrap to n_state-1 from 0.
        Op::Label("dtk_back".into()),
        la(T6, Addr::DomT),
        lw(T2, T6, H_WST),
        bne(T2, X0, "dtk_back_dec"),
        addi(T2, T3, -1),
        j("dtk_set"),
        Op::Label("dtk_back_dec".into()),
        addi(T2, T2, -1),
        j("dtk_set"),
        // home → first state; end → last state.
        Op::Label("dtk_home".into()),
        li(T2, 0),
        j("dtk_set"),
        Op::Label("dtk_end".into()),
        addi(T2, T3, -1),
        j("dtk_set"),
        // commit: H_WST = t2, bump H_DIRTY so the tick repaints the new state.
        Op::Label("dtk_set".into()),
        la(T6, Addr::DomT),
        sw(T2, T6, H_WST),
        lw(T1, T6, H_DIRTY),
        addi(T1, T1, 1),
        sw(T1, T6, H_DIRTY),
        j("dtk_skip"),
        Op::Label("dtk_lsn".into()),
        // focus node idx -> t2
        la(T6, Addr::DomT),
        lw(T2, T6, crate::domt::H_FOCUS),
        li(T1, NONE),
        beq(T2, T1, "dtk_skip"),
        // focus rec -> t6
        slli(T6, T2, 6),
        la(T3, Addr::DomT),
        add(T6, T6, T3),
        addi(T6, T6, DOMT_HDR as i32),
        // needs N_LEV & EV_KEYDOWN and a nonzero N_LISTEN
        lw(T3, T6, N_LEV),
        Op::Andi {
            rd: T3,
            rs: T3,
            imm: EV_KEYDOWN as i32,
        },
        beq(T3, X0, "dtk_skip"),
        lw(T3, T6, N_LISTEN),
        li(T1, LSN_DEMO),
        beq(T3, T1, "dtk_demo"),
        li(T1, LSN_FUNC),
        bltu(T3, T1, "dtk_skip"), // 0 (BIOS) / reserved-low → no wasm re-entry
        // N_LISTEN >= LSN_FUNC → a wasm `add_event_listener` funcidx (the
        // `Listener::Wasm` lane). Fill `__ev_obj` with the key event, then
        // `JitCall(funcidx)` re-enters the cell *between* JitRuns — the same
        // re-entry the asyncify rewind uses, so it can't run mid-frame.
        la(T5, Addr::EvObj),
        li(T1, EV_KEYDOWN),
        sw(T1, T5, EVO_TYPE),
        sw(T0, T5, EVO_CODE),
        sw(T4, T5, EVO_VALUE),
        addi(T1, T2, 1), // target = node handle (index+1), not the raw index
        sw(T1, T5, EVO_TARGET),
        sw(X0, T5, EVO_CX),
        sw(X0, T5, EVO_CY),
        sw(X0, T5, EVO_PD),               // fresh event — not yet prevented
        addi(A0, T3, -(LSN_FUNC as i32)), // funcidx = N_LISTEN - LSN_FUNC
        li(A1, 1),                        // nargs=1 — Listener::Wasm calls fn(ev)
        mv(A2, T5),                       // event handle = __ev_obj
        jal("JitCall"),
        // A listener mutation repaints: bump H_DIRTY so the tick re-runs the DOM.
        la(T6, Addr::DomT),
        lw(T1, T6, H_DIRTY),
        addi(T1, T1, 1),
        sw(T1, T6, H_DIRTY),
        j("dtk_skip"),
        Op::Label("dtk_demo".into()),
        // DomtDemo(node, code)
        mv(A0, T2),
        mv(A1, T0),
        jal("DomtDemo"),
        Op::Label("dtk_skip".into()),
        addi(S1, S1, 1),
        j("dtk_next"),
        Op::Label("dtk_done".into()),
        sw(S1, S2, crate::vio::DOMT_SEEN_OFF),
        ld(RA, SP, 24),
        ld(S0, SP, 16),
        ld(S1, SP, 8),
        ld(S2, SP, 0),
        addi(SP, SP, 32),
        ret(),
    ];
    ops.shrink_to_fit();
    ops
}

/// `DomtHit(a0=px, a1=py, a2=ev_mask) -> a0 = idx | NONE` — bounded hit-test.
/// Walks the live `__dom` arena and returns the *topmost* node that is
/// `F_VIS`, contains the display-px point, and latches `N_LEV & ev_mask`.
/// "Topmost" is the last match in document order — children append after
/// their parents and paint over them, so the highest index under the point
/// wins. Zero-size (unlaid) rects can never contain a point. There is no
/// capture/bubble walk — the single topmost listening node is the target.
fn domt_hit_node() -> Vec<Op> {
    let mut ops = vec![
        Op::Comment("DomtHit(px,py,mask) — topmost F_VIS rect node with the event bit".into()),
        Op::Glob("DomtHit".into()),
        Op::Label("DomtHit".into()),
        // t0 = H_NEXT, t5 = first node record, t1 = idx, t2 = best. Scan from
        // idx0 — the root can carry a document-level listener too; a deeper
        // (later) hit still overrides it.
        la(T5, Addr::DomT),
        lw(T0, T5, H_NEXT),
        addi(T5, T5, DOMT_HDR as i32),
        li(T1, 0),
        li(T2, NONE),
        Op::Label("dph_loop".into()),
        bgeu(T1, T0, "dph_done"),
        slli(T3, T1, 6),
        add(T3, T3, T5),
        lw(T4, T3, N_FLAGS),
        Op::Andi {
            rd: T4,
            rs: T4,
            imm: F_VIS as i32,
        },
        beq(T4, X0, "dph_next"),
        lw(T4, T3, N_LEV),
        and_(T4, T4, A2),
        beq(T4, X0, "dph_next"),
        // x <= px < x+w
        lw(T4, T3, N_X),
        bltu(A0, T4, "dph_next"),
        lw(T6, T3, N_W),
        add(T4, T4, T6),
        bgeu(A0, T4, "dph_next"),
        // y <= py < y+h
        lw(T4, T3, N_Y),
        bltu(A1, T4, "dph_next"),
        lw(T6, T3, N_H),
        add(T4, T4, T6),
        bgeu(A1, T4, "dph_next"),
        mv(T2, T1),
        Op::Label("dph_next".into()),
        addi(T1, T1, 1),
        j("dph_loop"),
        Op::Label("dph_done".into()),
        mv(A0, T2),
        ret(),
    ];
    ops.shrink_to_fit();
    ops
}

/// `DomtPtr` — the tree-DOM pointer consumer. Runs after `TabDrain` in
/// `trap_tab`: when `PTR_CLICK` is latched it scales the last `PTR_X`/`PTR_Y`
/// (tablet `0..=VIO_ABS_MAX`) into display px via `DISP_SEL_W`/`DISP_SEL_H`,
/// `DomtHit`s the topmost `EV_CLICK` node, fills `__ev_obj` with the click
/// coordinates + node-handle target, and `JitCall`s the node's wasm
/// `add_event_listener` funcidx — the same between-`JitRun`s re-entry
/// `DomtKey` uses for keys. Bumps `H_DIRTY` so the tick repaints; no paint
/// here. Trap-context leaf (saved s0-s2 only).
fn domt_ptr_node() -> Vec<Op> {
    let mut ops = vec![
        Op::Comment(
            "DomtPtr — PTR_CLICK → scale → DomtHit → __ev_obj(click) → JitCall → dirty".into(),
        ),
        Op::Glob("DomtPtr".into()),
        Op::Label("DomtPtr".into()),
        addi(SP, SP, -32),
        sd(RA, SP, 24),
        sd(S0, SP, 16),
        sd(S1, SP, 8),
        sd(S2, SP, 0),
        // s2 = __vio base. Consume a single pending click per trap.
        la(S2, Addr::VioBss),
        la(T6, Addr::Prom),
        lw(T1, T6, P_ASUSP),
        bne(T1, X0, "dp_ret"),
        lw(T1, T6, P_RESUME),
        bne(T1, X0, "dp_ret"),
        lw(T0, S2, crate::vio::PTR_CLICK),
        beq(T0, X0, "dp_ret"),
        sw(X0, S2, crate::vio::PTR_CLICK),
        // px = PTR_X * DISP_SEL_W >> 15 (VIO_ABS_MAX+1 = 0x8000 = 2^15).
        lw(T0, S2, crate::vio::PTR_X),
        lw(T1, S2, crate::vio::DISP_SEL_W),
        bne(T1, X0, "dp_w_ok"),
        li(T1, 640),
        Op::Label("dp_w_ok".into()),
        mul(T0, T0, T1),
        Op::Srli {
            rd: T0,
            rs: T0,
            shamt: 15,
        },
        mv(S0, T0),
        // py = PTR_Y * DISP_SEL_H >> 15.
        lw(T0, S2, crate::vio::PTR_Y),
        lw(T1, S2, crate::vio::DISP_SEL_H),
        bne(T1, X0, "dp_h_ok"),
        li(T1, 480),
        Op::Label("dp_h_ok".into()),
        mul(T0, T0, T1),
        Op::Srli {
            rd: T0,
            rs: T0,
            shamt: 15,
        },
        mv(S1, T0),
        // DomtHit(px, py, EV_CLICK) → a0 = node idx | NONE.
        mv(A0, S0),
        mv(A1, S1),
        li(A2, EV_CLICK),
        jal("DomtHit"),
        li(T1, NONE),
        beq(A0, T1, "dp_ret"),
        mv(T2, A0),
        // node record → t6; need a wasm funcidx listener (N_LISTEN >= LSN_FUNC).
        slli(T6, T2, 6),
        la(T3, Addr::DomT),
        add(T6, T6, T3),
        addi(T6, T6, DOMT_HDR as i32),
        lw(T3, T6, N_LISTEN),
        li(T1, LSN_FUNC),
        bltu(T3, T1, "dp_ret"), // 0 (BIOS) / LSN_DEMO / reserved-low → no wasm
        // Fill `__ev_obj` with the click event, then `JitCall(funcidx)` re-enters
        // the cell between JitRuns. `code`=BTN_LEFT, `value`=1 (press),
        // `clientX`/`clientY` = display-px, `target` = node handle (index+1).
        la(T5, Addr::EvObj),
        li(T1, EV_CLICK),
        sw(T1, T5, EVO_TYPE),
        li(T1, crate::vio::VIO_BTN_LEFT),
        sw(T1, T5, EVO_CODE),
        li(T1, 1),
        sw(T1, T5, EVO_VALUE),
        addi(T1, T2, 1),
        sw(T1, T5, EVO_TARGET),
        sw(S0, T5, EVO_CX),
        sw(S1, T5, EVO_CY),
        sw(X0, T5, EVO_PD),               // fresh event — not yet prevented
        addi(A0, T3, -(LSN_FUNC as i32)), // funcidx = N_LISTEN - LSN_FUNC
        li(A1, 1),                        // nargs=1 — Listener::Wasm calls fn(ev)
        mv(A2, T5),
        jal("JitCall"),
        la(T6, Addr::DomT),
        lw(T1, T6, H_DIRTY),
        addi(T1, T1, 1),
        sw(T1, T6, H_DIRTY),
        Op::Label("dp_ret".into()),
        ld(RA, SP, 24),
        ld(S0, SP, 16),
        ld(S1, SP, 8),
        ld(S2, SP, 0),
        addi(SP, SP, 32),
        ret(),
    ];
    ops.shrink_to_fit();
    ops
}

/// `DomtLayout` — bounded block flow. Node rects are computed top-down:
/// the root spans the `__disp` output minus margins; each visible child is a
/// block row stacked under the previous sibling. A text node's height is one
/// scaled cell; an element's height is `cell` plus its laid-out children.
/// Writes x/y/w/h into each node and `H_NRECT` = laid-out count.
///
/// This is the honest bounded subset — vertical block flow with margin:auto
/// collapse to a fixed content box — not a general CSS engine. Unsupported
/// display kinds degrade to block, matching the deterministic-degradation
/// contract.
/// Inline px gap between horizontally-flowed children (nav tabs, table cells).
pub const DOMT_GAP: i64 = 12;
/// Small left indent added to block children for visual nesting.
pub const DOMT_INDENT: i64 = 10;

fn domt_layout_node(_spec: &BoardSpec) -> Vec<Op> {
    let mut ops = vec![
        Op::Comment(
            "DomtLayout — recursive block+inline flow. DomtLay(idx,x,y,w,depth) \
             assigns each node a real nested rect: row containers (nav/tr) flow \
             children horizontally at their measured width; everything else \
             stacks children vertically. A leaf/text node is one DOMT_CELL row. \
             Returns the node's laid-out height."
                .into(),
        ),
        Op::Glob("DomtLayout".into()),
        Op::Label("DomtLayout".into()),
        addi(SP, SP, -48),
        sd(RA, SP, 40),
        sd(S0, SP, 32),
        sd(S3, SP, 24),
        sd(S4, SP, 16),
        jal("DomtInit"),
        la(S0, Addr::DomT), // header
        // Pull disp w/h from the __vio DispSel latch; fall back to the proxy geom.
        la(T6, Addr::VioBss),
        lw(S3, T6, crate::vio::DISP_SEL_W),
        bne(S3, X0, "domt_layout_w"),
        li(S3, 640),
        Op::Label("domt_layout_w".into()),
        lw(S4, T6, crate::vio::DISP_SEL_H),
        bne(S4, X0, "domt_layout_h"),
        li(S4, 480),
        Op::Label("domt_layout_h".into()),
        // root content box: x=DOMT_MX, y=DOMT_MY, w=disp_w-2*MX
        // a0=idx(root=0) a1=x a2=y a3=w a4=depth
        li(A0, 0),
        li(A1, DOMT_MX),
        li(A2, DOMT_MY),
        li(T0, DOMT_MX),
        slli(T0, T0, 1),
        sub(A3, S3, T0),
        li(A4, 0),
        jal("DomtLay"),
        // store the laid-out total height (root) as the layout watermark.
        sw(A0, S0, H_NRECT),
        // The root element generates the initial containing block: its box is
        // the whole viewport, so a document-level listener (e.g. `click` on the
        // root) is hit by a pointer anywhere on the page — not just inside the
        // content strip. Clamp the root's laid height up to the display height.
        lw(T0, S0, DOMT_HDR as i32 + N_H),
        bgeu(T0, S4, "domt_layout_rootdone"),
        sw(S4, S0, DOMT_HDR as i32 + N_H),
        Op::Label("domt_layout_rootdone".into()),
        ld(RA, SP, 40),
        ld(S0, SP, 32),
        ld(S3, SP, 24),
        ld(S4, SP, 16),
        addi(SP, SP, 48),
        ret(),
        // ------------------------------------------------------------------
        // DomtMeasure(a0=idx) -> a0 = intrinsic content width in px.
        //   text node -> tlen*DOMT_CELL ; empty leaf -> DOMT_CELL ; element ->
        //   the widest child. Used to size inline (row-container) children.
        Op::Comment(
            "DomtMeasure(a0=idx) -> a0 intrinsic width: text=len*cell, el=max child".into(),
        ),
        Op::Label("DomtMeasure".into()),
        addi(SP, SP, -48),
        sd(RA, SP, 40),
        sd(S0, SP, 32),
        sd(S1, SP, 24),
        sd(S2, SP, 16),
        sd(S6, SP, 8),
        // s0 = node rec
        slli(S0, A0, 6),
        la(T5, Addr::DomT),
        add(S0, S0, T5),
        addi(S0, S0, DOMT_HDR as i32),
        // text node? -> tlen*CELL
        lw(T0, S0, N_FLAGS),
        andi_text(T0),
        beq(T0, X0, "domt_meas_el"),
        lw(T0, S0, N_TLEN),
        li(T1, DOMT_TEXT), // clamp
        bgeu(T1, T0, "domt_meas_tl"),
        mv(T0, T1),
        Op::Label("domt_meas_tl".into()),
        li(T1, DOMT_CELL),
        mul(A0, T0, T1),
        j("domt_meas_out"),
        Op::Label("domt_meas_el".into()),
        // element: max over children; leaf -> DOMT_CELL
        lw(S1, S0, N_FC),
        li(T0, NONE),
        bne(S1, T0, "domt_meas_kids"),
        li(A0, DOMT_CELL),
        j("domt_meas_out"),
        Op::Label("domt_meas_kids".into()),
        li(S2, 0), // acc = max child width
        Op::Label("domt_meas_l".into()),
        li(T0, NONE),
        beq(S1, T0, "domt_meas_done"),
        mv(A0, S1),
        jal("DomtMeasure"), // a0 = child width
        bgeu(S2, A0, "domt_meas_keep"),
        mv(S2, A0),
        Op::Label("domt_meas_keep".into()),
        // s1 = s1.nsib
        slli(S6, S1, 6),
        la(T5, Addr::DomT),
        add(S6, S6, T5),
        addi(S6, S6, DOMT_HDR as i32),
        lw(S1, S6, N_NSIB),
        j("domt_meas_l"),
        Op::Label("domt_meas_done".into()),
        mv(A0, S2),
        Op::Label("domt_meas_out".into()),
        ld(RA, SP, 40),
        ld(S0, SP, 32),
        ld(S1, SP, 24),
        ld(S2, SP, 16),
        ld(S6, SP, 8),
        addi(SP, SP, 48),
        ret(),
        // ------------------------------------------------------------------
        // DomtLay(a0=idx, a1=x, a2=y, a3=w, a4=depth) -> a0 = node height.
        //   Assigns node.{x,y,w} then lays out children. Row containers flow
        //   children horizontally (each child width = DomtMeasure(child)); other
        //   nodes stack children vertically (full width, DOMT_INDENT left pad).
        Op::Comment("DomtLay(idx,x,y,w,depth) -> h — recursive nested block/inline layout".into()),
        Op::Label("DomtLay".into()),
        addi(SP, SP, -80),
        sd(RA, SP, 72),
        sd(S0, SP, 64),
        sd(S1, SP, 56),
        sd(S2, SP, 48),
        sd(S3, SP, 40),
        sd(S4, SP, 32),
        sd(S5, SP, 24),
        sd(S6, SP, 16),
        sd(S7, SP, 8),
        // s6 = node.y ; s1=x s3=w s2=cursor(=y) s5=depth
        mv(S6, A2),
        mv(S1, A1),
        mv(S3, A3),
        mv(S2, A2),
        mv(S5, A4),
        // s0 = node rec
        slli(S0, A0, 6),
        la(T5, Addr::DomT),
        add(S0, S0, T5),
        addi(S0, S0, DOMT_HDR as i32),
        // hidden (`setProperty(el,"hidden",..)` cleared F_VIS) → collapse: h=0,
        // no children laid (they keep 0 rects; DomtRaster skips them via the
        // ancestor check in DomtVis).
        lw(T0, S0, N_FLAGS),
        andi_visible(T0),
        bne(T0, X0, "domt_lay_vis"),
        sw(X0, S0, N_H),
        li(A0, 0),
        j("domt_lay_out"),
        Op::Label("domt_lay_vis".into()),
        // node.{x,y,w}
        sw(S1, S0, N_X),
        sw(S6, S0, N_Y),
        sw(S3, S0, N_W),
        // leaf or depth bound -> one row
        li(T0, DOMT_DEPTH),
        bgeu(S5, T0, "domt_lay_leaf"),
        lw(S4, S0, N_FC),
        li(T0, NONE),
        beq(S4, T0, "domt_lay_leaf"),
        // decide flow: row container (nav/tr/thead/tbody/tfoot) -> horizontal.
        // node.tag = ordinal+TAG_LW: nav 66, tr 105, thead 102, tbody 96, tfoot 100.
        lw(T0, S0, N_TAG),
        li(T1, 62 + TAG_LW), // nav
        beq(T0, T1, "domt_lay_row"),
        li(T1, 101 + TAG_LW), // tr
        beq(T0, T1, "domt_lay_row"),
        li(T1, 98 + TAG_LW), // thead
        beq(T0, T1, "domt_lay_row"),
        li(T1, 92 + TAG_LW), // tbody
        beq(T0, T1, "domt_lay_row"),
        li(T1, 96 + TAG_LW), // tfoot
        beq(T0, T1, "domt_lay_row"),
        // ---- vertical block flow: children at (x+indent, cy, w-indent) ----
        Op::Label("domt_lay_vl".into()),
        li(T0, NONE),
        beq(S4, T0, "domt_lay_done"),
        mv(A0, S4),
        li(T0, DOMT_INDENT),
        add(A1, S1, T0), // child x = x + indent
        mv(A2, S2),      // child y = cursor
        sub(A3, S3, T0), // child w = w - indent
        addi(A4, S5, 1), // depth+1
        jal("DomtLay"),
        add(S2, S2, A0), // cursor += child h
        // s4 = s4.nsib
        slli(S6, S4, 6), // reuse s6 as childrec scratch (node.y no longer needed)
        la(T5, Addr::DomT),
        add(S6, S6, T5),
        addi(S6, S6, DOMT_HDR as i32),
        lw(S4, S6, N_NSIB),
        j("domt_lay_vl"),
        // ---- horizontal inline flow: children at (cx, y, childw, CELL) ----
        Op::Label("domt_lay_row".into()),
        mv(S2, S1), // cursor_x = x
        Op::Label("domt_lay_hl".into()),
        li(T0, NONE),
        beq(S4, T0, "domt_lay_rowdone"),
        mv(A0, S4),
        jal("DomtMeasure"), // a0 = child intrinsic width
        mv(S7, A0),         // s7 = child w (s7 free here — row branch)
        mv(A0, S4),
        mv(A1, S2), // child x = cursor_x
        mv(A2, S6), // child y = node.y
        mv(A3, S7), // child w = measured
        addi(A4, S5, 1),
        jal("DomtLay"), // lays child's subtree inside [x,y,w]
        li(T0, DOMT_GAP),
        add(T0, T0, S7),
        add(S2, S2, T0), // cursor_x += childw + gap
        // s4 = s4.nsib
        slli(S6, S4, 6),
        la(T5, Addr::DomT),
        add(S6, S6, T5),
        addi(S6, S6, DOMT_HDR as i32),
        lw(S4, S6, N_NSIB),
        // restore node.y into s6 for the next child's y
        lw(S6, S0, N_Y),
        j("domt_lay_hl"),
        Op::Label("domt_lay_rowdone".into()),
        // row height = one cell
        li(A0, DOMT_CELL),
        sw(A0, S0, N_H),
        j("domt_lay_out"),
        Op::Label("domt_lay_done".into()),
        // vertical: node.h = cursor - node.y ; node.y saved in s6? no — s6 was
        // reused. Recompute height as cursor - original y (reload node.y).
        lw(T0, S0, N_Y),
        sub(A0, S2, T0),
        sw(A0, S0, N_H),
        j("domt_lay_out"),
        Op::Label("domt_lay_leaf".into()),
        li(A0, DOMT_CELL),
        sw(A0, S0, N_H),
        Op::Label("domt_lay_out".into()),
        ld(RA, SP, 72),
        ld(S0, SP, 64),
        ld(S1, SP, 56),
        ld(S2, SP, 48),
        ld(S3, SP, 40),
        ld(S4, SP, 32),
        ld(S5, SP, 24),
        ld(S6, SP, 16),
        ld(S7, SP, 8),
        addi(SP, SP, 80),
        ret(),
    ];
    // DomtVis(a0=node idx) -> a0=1 iff the node *and* every ancestor are F_VIS.
    // `setProperty(el,"hidden",..)` clears F_VIS on the section only — its
    // children keep F_VIS but must not paint, so the check walks N_PARENT to
    // the root (parent==NONE), bounded by DOMT_DEPTH hops.
    ops.extend([
        Op::Label("DomtVis".into()),
        addi(SP, SP, -16),
        sd(S0, SP, 8),
        mv(S0, A0),
        li(T3, DOMT_DEPTH),
        Op::Label("domt_vis_l".into()),
        slli(T0, S0, 6),
        la(T5, Addr::DomT),
        add(T0, T0, T5),
        addi(T0, T0, DOMT_HDR as i32),
        lw(T1, T0, N_FLAGS),
        andi_visible(T1),
        beq(T1, X0, "domt_vis_no"),
        lw(S0, T0, N_PARENT),
        li(T1, NONE),
        beq(S0, T1, "domt_vis_yes"),
        addi(T3, T3, -1),
        beq(T3, X0, "domt_vis_yes"),
        j("domt_vis_l"),
        Op::Label("domt_vis_yes".into()),
        li(A0, 1),
        j("domt_vis_out"),
        Op::Label("domt_vis_no".into()),
        li(A0, 0),
        Op::Label("domt_vis_out".into()),
        ld(S0, SP, 8),
        addi(SP, SP, 16),
        ret(),
    ]);
    ops.shrink_to_fit();
    ops
}

/// `DomtRaster` — paint every visible node into the 32bpp `__scan_fb` at the
/// `__disp` geometry. For each node: fill its bg rect (when bg != 0) and draw
/// its text glyphs via `__font` at its laid-out rect, then clear F_DIRTY.
/// Dirty bookkeeping: `H_DIRTY` resets to 0; `__ui_dom`'s `DOM_PAINTED`
/// watermark is bumped to `dirty` so the `VioPaint` commit path (TRANSFER+
/// FLUSH) presents the frame. s-regs hold the loop state; this runs in the
/// trap_timer context (caller-clobberable t/a only is NOT enough — it uses s).
fn domt_raster_node(spec: &BoardSpec) -> Vec<Op> {
    let mut ops = vec![
        Op::Comment("DomtRaster — dirty visible nodes → __scan_fb bg fill + __font glyphs".into()),
        Op::Glob("DomtRaster".into()),
        Op::Label("DomtRaster".into()),
        addi(SP, SP, -96),
        sd(RA, SP, 88),
        sd(S0, SP, 80),
        sd(S1, SP, 72),
        sd(S2, SP, 64),
        sd(S3, SP, 56),
        sd(S4, SP, 48),
        sd(S5, SP, 40),
        sd(S6, SP, 32),
        sd(S7, SP, 24),
        sd(S8, SP, 16),
        sd(S9, SP, 8),
        jal("DomtInit"),
        // fast path: nothing dirty → return (H_DIRTY==0)
        la(S0, Addr::DomT),
        lw(T0, S0, H_DIRTY),
        beq(T0, X0, "domt_raster_out"),
        // s1 = dest fb: DispSel fb when latched, else __scan_fb
        la(T6, Addr::VioBss),
        lw(S2, T6, crate::vio::DISP_SEL_W),
        lw(S3, T6, crate::vio::DISP_SEL_H),
        lw(S4, T6, crate::vio::DISP_SEL_STRIDE),
        lw(S1, T6, crate::vio::DISP_SEL_FB_LO),
        bne(S1, X0, "domt_raster_dst"),
        la(S1, Addr::ScanFb),
        Op::Label("domt_raster_dst".into()),
        // geometry fallback: stride = w*4 when 0
        bne(S4, X0, "domt_raster_geom"),
        slli(S4, S2, 2),
        Op::Label("domt_raster_geom".into()),
        bne(S2, X0, "domt_raster_w"),
        li(S2, 640),
        Op::Label("domt_raster_w".into()),
        bne(S3, X0, "domt_raster_h"),
        li(S3, 480),
        Op::Label("domt_raster_h".into()),
        // Wipe the whole frame to the page background before painting nodes.
        // `__scan_fb` is shared with the picker's DomPaint32 menu and the
        // bring-up band, so pixels outside the laid-out DOM box would persist
        // around the raster without the clear. S1=fb S2=w S3=h S4=stride are
        // resolved above.
        li(A7, 0x0010_1620), // page bg (root navy)
        li(A0, 0),           // py
        Op::Label("domt_clr_row".into()),
        bgeu(A0, S3, "domt_clr_done"),
        mul(A1, A0, S4), // row offset = py * stride
        add(A1, A1, S1), // row base
        slli(A3, S2, 2),
        add(A3, A1, A3), // row end = base + w*4
        mv(A2, A1),      // cursor
        Op::Label("domt_clr_px".into()),
        bgeu(A2, A3, "domt_clr_rowdone"),
        sw(A7, A2, 0),
        addi(A2, A2, 4),
        j("domt_clr_px"),
        Op::Label("domt_clr_rowdone".into()),
        addi(A0, A0, 1),
        j("domt_clr_row"),
        Op::Label("domt_clr_done".into()),
    ];
    // Publish the wipe as dirty rect 0 so `vp_web` transfers a clean full
    // frame; the per-node `record_tile` calls then append on top of it.
    // `__ui_cap` exists only where `vp_web`/`DispPaint` can consume it — on a
    // pcie-only board `Addr::UiCap` would alias `__vio` and clobber its queue
    // state, so the stamp is omitted there.
    if spec.wants_virtio_gpu() || spec.wants_disp_scan() {
        ops.extend([
            la(T6, Addr::UiCap),
            li(T5, 1),
            sw(T5, T6, crate::vio::UI_CAP_OFF_NTILE),
            addi(T6, T6, crate::vio::UI_CAP_OFF_RECTS),
            sw(X0, T6, 0),
            sw(X0, T6, 4),
            sw(S2, T6, 8),
            sw(S3, T6, 12),
        ]);
    }
    ops.extend([
        // S5 = node index loop 0..H_NEXT
        li(S5, 0),
        Op::Label("domt_raster_l".into()),
        lw(T0, S0, H_NEXT),
        bgeu(S5, T0, "domt_raster_done"),
        // node rec -> s6
        slli(S6, S5, 6),
        add(S6, S6, S0),
        addi(S6, S6, DOMT_HDR as i32),
        // visible? — self *and* every ancestor F_VIS (hidden sections collapse
        // but their children stay F_VIS, so the ancestor walk is required).
        mv(A0, S5),
        jal("DomtVis"),
        beq(A0, X0, "domt_raster_next"),
        // skip tag==FREE
        lw(T0, S6, N_TAG),
        beq(T0, X0, "domt_raster_next"),
        // ---- bg fill: bg != 0 → fill rect (x,y,w,h) in __scan_fb ----
        lw(T1, S6, N_BG),
        beq(T1, X0, "domt_raster_text"),
        // row loop: py = y .. y+h ; each row fills x..x+w words at
        //   fb + py*stride + x*4
        lw(S7, S6, N_Y), // py start
        lw(S8, S6, N_H), // h
        add(S8, S8, S7), // py end = y+h
        // clamp py end to disp h
        bgeu(S3, S8, "domt_raster_hok"),
        mv(S8, S3),
        Op::Label("domt_raster_hok".into()),
        Op::Label("domt_raster_row".into()),
        bgeu(S7, S8, "domt_raster_text"),
        // row base = fb + py*stride + x*4
        mul(T2, S7, S4),
        add(T2, T2, S1),
        lw(T3, S6, N_X),
        slli(T3, T3, 2),
        add(T2, T2, T3),
        // fill w words
        lw(T3, S6, N_W),
        // clamp w to disp_w - x
        lw(T4, S6, N_X),
        sub(T5, S2, T4),
        bgeu(T5, T3, "domt_raster_wok"),
        mv(T3, T5),
        Op::Label("domt_raster_wok".into()),
        mv(T4, X0), // i
        Op::Label("domt_raster_px".into()),
        bgeu(T4, T3, "domt_raster_rowdone"),
        slli(T5, T4, 2),
        add(T5, T5, T2),
        sw(T1, T5, 0),
        addi(T4, T4, 1),
        j("domt_raster_px"),
        Op::Label("domt_raster_rowdone".into()),
        addi(S7, S7, 1),
        j("domt_raster_row"),
        // ---- text glyphs ----
        Op::Label("domt_raster_text".into()),
        lw(T0, S6, N_FLAGS),
        andi_text(T0),
        beq(T0, X0, "domt_raster_clear"),
        lw(T0, S6, N_TLEN),
        beq(T0, X0, "domt_raster_clear"),
        // draw up to DOMT_TEXT glyphs at (x + i*cell, y)
        // s7=glyph i, s8=char count(clamped), s9=dst text origin
        li(S7, 0),
        lw(S8, S6, N_TLEN),
        li(T0, DOMT_TEXT),
        bgeu(T0, S8, "domt_raster_tn"),
        mv(S8, T0),
        Op::Label("domt_raster_tn".into()),
        Op::Label("domt_raster_g".into()),
        bgeu(S7, S8, "domt_raster_clear"),
        // glyph src = __font + ch*8
        lw(T1, S6, N_TPTR),
        la(T2, Addr::DomS),
        add(T1, T1, T2),
        add(T1, T1, S7),
        lbu(T1, T1, 0), // ch
        // glyph index: __font is indexed `ch - 0x20` (FONT8X8 folds a-z onto
        // the A-Z bitmaps). Raw `ch*8` landed lowercase/punct out of the
        // 96-glyph table — the garbled cells. Clamp to the box glyph.
        li(T3, 0x20),
        sub(T1, T1, T3), // ch - 0x20
        li(T3, 96),
        bltu(T1, T3, "domt_raster_gi"),
        li(T1, 95), // FONT_BOX = FONT_GLYPHS-1
        Op::Label("domt_raster_gi".into()),
        la(T2, Addr::UiFont),
        slli(T3, T1, 3), // glyph_index*8
        add(T2, T2, T3), // glyph row bytes (8 rows of 8 bits)
        // dest origin = fb + (y)*stride + (x + i*cell)*4
        lw(T3, S6, N_Y),
        mul(T3, T3, S4),
        add(T3, T3, S1),
        lw(T4, S6, N_X),
        li(T5, DOMT_CELL),
        mul(T5, T5, S7),
        add(T4, T4, T5),
        slli(T4, T4, 2),
        add(T3, T3, T4), // s9 = dst
        mv(S9, T3),
        // 8 glyph rows
        li(A6, 0), // row r
        Op::Label("domt_raster_gr".into()),
        li(T5, 8),
        bgeu(A6, T5, "domt_raster_gd"),
        add(T4, T2, A6),
        lbu(T4, T4, 0), // 8-bit row mask
        // row base = s9 + r*stride
        mul(A4, A6, S4),
        add(A4, A4, S9),
        // 8 px
        li(A5, 0),
        Op::Label("domt_raster_gp".into()),
        li(T5, 8),
        bgeu(A5, T5, "domt_raster_grdone"),
        // bit = (mask >> (7-col)) & 1
        li(T5, 7),
        sub(T5, T5, A5),
        // srlv not in Op set; use srl by shamt via srlw? use a temp shift loop:
        // simpler: srli needs imm — build a per-col test with andi on a shifted copy
        // We rotate the mask right by (7-col): emulate with a small loop.
        mv(A3, T4),
        mv(A7, T5),
        Op::Label("domt_raster_sh".into()),
        beq(A7, X0, "domt_raster_shd"),
        srli(A3, A3, 1),
        addi(A7, A7, -1),
        j("domt_raster_sh"),
        Op::Label("domt_raster_shd".into()),
        andi_px(A3),
        beq(A3, X0, "domt_raster_skippx"),
        // write fg at row_base + col*4
        slli(T5, A5, 2),
        add(T5, T5, A4),
        lw(T6, S6, N_FG),
        sw(T6, T5, 0),
        Op::Label("domt_raster_skippx".into()),
        addi(A5, A5, 1),
        j("domt_raster_gp"),
        Op::Label("domt_raster_grdone".into()),
        addi(A6, A6, 1),
        j("domt_raster_gr"),
        Op::Label("domt_raster_gd".into()),
        addi(S7, S7, 1),
        j("domt_raster_g"),
        // ---- clear dirty on this node ----
        Op::Label("domt_raster_clear".into()),
    ]);
    // The painted rect does *not* join `__ui_cap` as its own tile: on the
    // linear `__scan_fb` a sub-rect is not a contiguous blob, so a per-node
    // TRANSFER_TO_HOST_2D (offset=0) would copy the frame's top-left pixels
    // over the node's region — QEMU would erase the text the full-frame wipe
    // already transferred (the exec model masks this by folding `off` into
    // the per-pixel source offset). The wipe tile recorded above covers the
    // whole frame contiguously and is the only tile vp_web needs.
    ops.extend([
        lw(T0, S6, N_FLAGS),
        li(T1, !F_DIRTY & 0xffffffff),
        and_(T0, T0, T1),
        sw(T0, S6, N_FLAGS),
        Op::Label("domt_raster_next".into()),
        addi(S5, S5, 1),
        j("domt_raster_l"),
        Op::Label("domt_raster_done".into()),
        // reset header dirty — the caller (trap_timer / paint rung) decides
        // whether to present this frame; `__dom` tracks its own dirty count
        // and never touches the `__ui_dom` row-table watermark.
        sw(X0, S0, H_DIRTY),
    ]);
    // Stamp `__ui_cap`: magic + guest WEB flag + live node count, so the
    // present backends route the recorded dirty rects (vp_web) rather than
    // FbExpandSel/DomPaint32 repainting the row-DOM over the guest frame.
    // Same `has_cap` guard as the wipe tile above — without the block,
    // `Addr::UiCap` aliases `__vio`.
    if spec.wants_virtio_gpu() || spec.wants_disp_scan() {
        ops.extend([
            la(T6, Addr::UiCap),
            li(T0, crate::vio::UI_CAP_MAGIC as i64),
            sw(T0, T6, 0),
            li(T0, crate::vio::UI_CAP_FLAG_WEB as i64),
            sw(T0, T6, crate::vio::UI_CAP_OFF_FLAGS),
            lw(T0, S0, H_NEXT),
            sw(T0, T6, crate::vio::UI_CAP_OFF_NODES),
        ]);
    }
    ops.extend([
        Op::Label("domt_raster_out".into()),
        ld(RA, SP, 88),
        ld(S0, SP, 80),
        ld(S1, SP, 72),
        ld(S2, SP, 64),
        ld(S3, SP, 56),
        ld(S4, SP, 48),
        ld(S5, SP, 40),
        ld(S6, SP, 32),
        ld(S7, SP, 24),
        ld(S8, SP, 16),
        ld(S9, SP, 8),
        addi(SP, SP, 96),
        ret(),
    ]);
    let _ = spec;
    ops.shrink_to_fit();
    ops
}

/// `andi` immediate helpers — return a single `Op::Andi` for use inline in
/// `vec![...]` op lists.
fn andi_visible(rd: u32) -> Op {
    Op::Andi {
        rd,
        rs: rd,
        imm: F_VIS as i32,
    }
}
fn andi_text(rd: u32) -> Op {
    Op::Andi {
        rd,
        rs: rd,
        imm: F_TEXT as i32,
    }
}
fn andi_px(rd: u32) -> Op {
    Op::Andi { rd, rs: rd, imm: 1 }
}

/// `DomtSetTextOff(a0=node, a1=str_offset, a2=len)` — bind a node to `len`
/// bytes already sitting at `__dom_str + str_offset` (no copy). Used by
/// `DomtBoot` after it stores the demo strings; `DomtText` does the copy
/// itself. Sets F_TEXT|F_DIRTY and bumps the header dirty count.
fn domt_settext_off_node() -> Vec<Op> {
    let mut ops = vec![
        Op::Comment("DomtSetTextOff(a0=node,a1=stroff,a2=len) — bind, no copy".into()),
        Op::Glob("DomtSetTextOff".into()),
        Op::Label("DomtSetTextOff".into()),
        addi(SP, SP, -16),
        sd(RA, SP, 8),
        sd(S0, SP, 0),
        mv(S0, A0),
    ];
    node_addr(&mut ops, T6, S0);
    ops.extend([
        sw(A1, T6, N_TPTR),
        sw(A2, T6, N_TLEN),
        lw(T0, T6, N_FLAGS),
        li(T1, F_TEXT | F_DIRTY),
        or_(T0, T0, T1),
        sw(T0, T6, N_FLAGS),
        la(T6, Addr::DomT),
        lw(T5, T6, H_DIRTY),
        addi(T5, T5, 1),
        sw(T5, T6, H_DIRTY),
        ld(RA, SP, 8),
        ld(S0, SP, 0),
        addi(SP, SP, 16),
        ret(),
    ]);
    ops.shrink_to_fit();
    ops
}

/// `DomtBoot` — a bounded demo tree the M2 gate drives before the full
/// shipped-cell ABI lands: root → one styled text row → a second row that a
/// key listener recolors. The demo strings are stored into `__dom_str` by
/// this routine (bounded `sb` writes) and bound with `DomtSetTextOff`, so no
/// rodata-label mechanism is needed. This is *not* the shipped UI; it exists
/// so the input→listener→mutation→repaint→present chain has a live tree to
/// mutate and repaint while the real cell's DOM imports are still being
/// wired. Idempotent — returns once the root has a child.
fn domt_boot_node(spec: &BoardSpec) -> Vec<Op> {
    let mut ops = vec![
        Op::Comment("DomtBoot — demo tree (root + 2 text rows) + focus/key listener".into()),
        Op::Glob("DomtBoot".into()),
        Op::Label("DomtBoot".into()),
        addi(SP, SP, -32),
        sd(RA, SP, 24),
        sd(S0, SP, 16),
        sd(S1, SP, 8),
        jal("DomtInit"),
    ];
    // if root has a child already, the demo is built — return
    node_addr(&mut ops, T6, X0);
    ops.extend([
        lw(T0, T6, N_FC),
        li(T1, NONE),
        bne(T0, T1, "domt_boot_out"),
        // ---- write "G6LC-M2-ROW-A" at __dom_str+0 (13 bytes) ----
        la(T2, Addr::DomS),
    ]);
    demo_str(&mut ops, T2, 0, b"G6LC-M2-ROW-A");
    ops.extend([
        // advance str cursor past both strings (13 + 13)
        la(T6, Addr::DomT),
        li(T0, 26),
        sw(T0, T6, H_STR),
        // ---- row 1: text node bound to __dom_str+0 ----
        li(A0, TAG_TEXT),
        jal("DomtCreate"),
        mv(S0, A0),
        mv(A0, S0),
        li(A1, 0),
        li(A2, 13),
        jal("DomtSetTextOff"),
        mv(A0, S0),
        li(A1, 0x001e_3a5a),
        li(A2, 0x00ff_ffff),
        jal("DomtStyle"),
        li(A0, 0),
        mv(A1, S0),
        jal("DomtAppend"),
        // ---- row 2: the key-recolor target ----
        la(T2, Addr::DomS),
    ]);
    demo_str(&mut ops, T2, 13, b"G6LC-M2-ROW-B");
    ops.extend([
        li(A0, TAG_TEXT),
        jal("DomtCreate"),
        mv(S1, A0),
        mv(A0, S1),
        li(A1, 13),
        li(A2, 13),
        jal("DomtSetTextOff"),
        mv(A0, S1),
        li(A1, 0x0020_2020),
        li(A2, 0x00c0_c0c0),
        jal("DomtStyle"),
        li(A0, 0),
        mv(A1, S1),
        jal("DomtAppend"),
        // row2 gets the demo keydown listener, then focus so a key lands on it
        mv(A0, S1),
        li(A1, EV_KEYDOWN),
        li(A2, LSN_DEMO),
        jal("DomtListen"),
        mv(A0, S1),
        jal("DomtFocus"),
        Op::Label("domt_boot_out".into()),
        ld(RA, SP, 24),
        ld(S0, SP, 16),
        ld(S1, SP, 8),
        addi(SP, SP, 32),
        ret(),
    ]);
    let _ = spec;
    ops.shrink_to_fit();
    ops
}

/// `demo_str` — store `s` at `base + off` via bounded `sb` writes.
fn demo_str(ops: &mut Vec<Op>, base: u32, off: i32, s: &[u8]) {
    for (i, &b) in s.iter().enumerate() {
        ops.push(li(T0, i64::from(b)));
        ops.push(sb(T0, base, off + i as i32));
    }
}

/// `nodes` — the M2 guest-DOM service nodes. Attaches beside the bounded
/// `__ui_dom` face; `__dom` is the real tree the browser/JIT lane drives.
pub fn nodes(spec: &BoardSpec) -> Vec<Node> {
    vec![Node {
        purpose: Purpose::UiDom,
        ops: {
            let mut v = Vec::new();
            v.extend(domt_init_node());
            v.extend(domt_root_node());
            v.extend(domt_create_node());
            v.extend(domt_append_node());
            v.extend(domt_text_node());
            v.extend(domt_settext_off_node());
            v.extend(domt_style_node());
            v.extend(domt_listen_node());
            v.extend(domt_focus_node());
            v.extend(lw_nameeq_node());
            v.extend(lw_hexval_node());
            v.extend(lw_addstr_node());
            v.extend(lw_createel_node());
            v.extend(lw_getroot_node());
            v.extend(lw_append_node());
            v.extend(lw_parsecolor_node());
            v.extend(lw_setid_node());
            v.extend(lw_findid_node());
            v.extend(lw_setprop_node());
            v.extend(lw_addlsn_node());
            v.extend(lw_evget_node());
            v.extend(lw_evcall_node());
            v.extend(lw_remove_node());
            v.extend(lw_fetch_node());
            v.extend(kernel_get_node());
            v.extend(prom_alloc_node());
            v.extend(prom_get_node());
            v.extend(lw_awaitsup_node());
            v.extend(lw_awaitvoid_node());
            v.extend(lw_awaitval_node());
            v.extend(lw_awaitfail_node());
            v.extend(lw_awaiterr_node());
            v.extend(lw_addints_node());
            v.extend(prom_scan_node());
            v.extend(prom_combine_node());
            v.extend(lw_promall_node());
            v.extend(lw_promany_node());
            v.extend(lw_promalls_node());
            v.extend(lw_noteful_node());
            v.extend(lw_noterej_node());
            v.extend(prom_drain_node());
            v.extend(lw_phex_node());
            v.extend(lw_lits_node());
            v.extend(domt_demo_node());
            v.extend(domt_key_node());
            v.extend(domt_hit_node());
            v.extend(domt_ptr_node());
            v.extend(domt_layout_node(spec));
            v.extend(domt_raster_node(spec));
            v.extend(domt_boot_node(spec));
            v
        },
    }]
}

/// Ensure `__dom` + `__dom_str` + `__dom_id` + `__ev_obj` BSS is sized on the
/// module.
pub fn ensure_bss(m: &mut Module) {
    if m.domt_bytes == 0 {
        m.domt_bytes = DOMT_BYTES;
    }
    if m.doms_bytes == 0 {
        m.doms_bytes = DOMT_STR_BYTES;
    }
    if m.domid_bytes == 0 {
        m.domid_bytes = DOMT_ID_BYTES;
    }
    if m.evobj_bytes == 0 {
        m.evobj_bytes = EVOBJ_BYTES;
    }
    if m.prom_bytes == 0 {
        m.prom_bytes = PROM_BYTES;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A spec with the guest JIT + a virtio-gpu scanout, so `__dom`/`__dom_str`
    /// and `__scan_fb` are all allocated and the Domt* rung + repaint path are
    /// compiled. The demo tree needs no wasm cell — `DomtBoot` is emitted asm.
    fn domt_spec() -> BoardSpec {
        BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},
 "gr":{"enable":true,"w":640,"h":480,"colors":16,"backend":"virtio-gpu"},
 "wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"test"}},
"uncore":{"clint":true,"plic":true},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap()
    }

    /// M2 raster increment: `DomtBoot` seeds a demo tree, `DomtLayout` computes
    /// its rects, `DomtRaster` fills `__scan_fb`. Assert the scanout has live
    /// (nonzero) pixels — the row-1 background fill — and that the DOM header
    /// reported a clean post-raster state.
    #[test]
    fn guest_dom_raster_fills_scan_fb() {
        let spec = domt_spec();
        let m = crate::analyze::kstart(&spec);
        assert!(m.domt_bytes == DOMT_BYTES, "__dom allocated");
        assert!(m.doms_bytes == DOMT_STR_BYTES, "__dom_str allocated");
        assert!(m.vio_fb_bytes > 0, "__scan_fb allocated");
        let s = crate::exec::run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(
            !s.console.contains("TRAP-"),
            "guest DOM boot must not fault: {}",
            s.console
        );
        // The demo tree's first row paints its bg (0x1e3a5a) over a ~608px-wide
        // rect. Count the exact pixel value (u32-LE) — not just any lit byte —
        // so a stray nonzero word can't pass for a real raster.
        let bg = 0x001e_3a5au32.to_le_bytes();
        let lit = s.scan_fb.chunks_exact(4).filter(|px| *px == bg).count();
        assert!(
            lit > 0,
            "row-1 bg 0x1e3a5a should fill a scan_fb rect: {}",
            s.console
        );
        // The text row also paints its fg (0xffffff) glyph pixels.
        let fg = 0x00ff_ffffu32.to_le_bytes();
        let glyphs = s.scan_fb.chunks_exact(4).filter(|px| *px == fg).count();
        assert!(
            glyphs > 0,
            "row text should paint fg 0xffffff glyphs: {}",
            s.console
        );
    }

    /// M2 gate — injected `KEY_*` produces different guest pixels on the tree
    /// path. `run_module` parks then delivers the canned virtio-input burst
    /// (`sendkey a`/`down`/`ret`); `InpDrain` fills `INP_KQ`, `DomtKey` drains
    /// it through `DOMT_SEEN` and focus-dispatches each press to row 2's
    /// `LSN_DEMO` listener, `DomtDemo` recolors the node's bg, and the next
    /// `trap_timer` tick repaints it into `__scan_fb` (presented via the
    /// guest-recorded `__ui_cap` dirty rects — host `inject_web_present` is
    /// off in this lane). `0xc02a10` exists nowhere but that listener, so its
    /// pixels prove input→hit-test→listener→mutation→dirty→repaint→present.
    #[test]
    fn guest_dom_key_recolors_a_node() {
        let spec = domt_spec();
        let m = crate::analyze::kstart(&spec);
        let s = crate::exec::run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(
            !s.console.contains("TRAP-"),
            "guest DOM input must not fault: {}",
            s.console
        );
        // The keys drained into the input path at all (3 EV_KEY presses).
        assert_eq!(
            s.console.matches("INP\n").count(),
            3,
            "virtio-input burst should deliver 3 presses: {}",
            s.console
        );
        let px = |v: u32| {
            s.scan_fb
                .chunks_exact(4)
                .filter(|p| *p == v.to_le_bytes())
                .count()
        };
        // Row 2 boot bg is 0x202020; the LSN_DEMO listener toggled it to
        // 0xc02a10 across the three presses (a→recolor, down→back, ret→recolor
        // — odd count ends on the recolor). 0xc02a10 is listener-only evidence.
        let recolored = px(0x00c0_2a10);
        assert!(
            recolored > 0,
            "key listener should have repainted row2 bg 0xc02a10: {}",
            s.console
        );
        // And the boot color it replaced is gone from row 2's rect.
        let leftover = px(0x0020_2020);
        assert!(
            leftover == 0,
            "row2 boot bg 0x202020 should be fully repainted, got {leftover}: {}",
            s.console
        );
    }
}
