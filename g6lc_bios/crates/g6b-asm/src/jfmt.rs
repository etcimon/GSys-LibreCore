// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
//! `jfmt` — the `__jit_in` wire format **owned by the guest side**.
//!
//! This is the guest ABI: the producer (`g6b_wasm::jcode`, host predecoder)
//! and the consumer (`crate::jitr`, the emitted translator routines) both
//! reference these constants. They live here — not in `g6b-wasm` — because
//! the dependency direction is `g6b-wasm → g6b-asm`, and because the format
//! is what the *payload* sees.
//!
//! ```text
//! __jit_in:
//!   +0  magic 'G6JC' | +4 nfuncs | +8 nimports | +12 entry_func
//!   +16 mem_pages | +20 glob_len(u64 count) | +24 nrecords | +28 data_len
//!   +32 fhdr[nfuncs]  {bc_off, bc_len, nparams, nlocals, nresults, flags}×24B
//!   …   rec[nrecords] {op u32, a u32, b u64}×16B
//!   …   glob[glob_len] u64
//!   …   data[data_len] u8   (linear-memory image, copied to __wasm_mem at 0)
//!
//!   M3 trailer (8-aligned, after data — absent on M1 images):
//!   +0  u32 n_sig | +4 u32 n_table
//!   +8  sig[n_sig] u32    funcidx → typeidx   (call_indirect sig check)
//!   …   tbl[n_table] i64  funcref → funcidx, -1 = null (call_indirect/table.get)
//! ```

#![allow(missing_docs)]

/// `__jit_in` magic: `"G6JC"` little-endian.
pub const MAGIC: u32 = 0x434A_3647;

/// Header is 8 u32s.
pub const HDR_BYTES: usize = 32;
/// Per-function header: bc_off, bc_len, nparams, nlocals, nresults, flags.
pub const FHDR_BYTES: usize = 24;
/// Record: op u32, a u32, b u64.
pub const REC_BYTES: usize = 16;
/// Imported-function flag in the func header.
pub const FHDR_F_IMPORT: u32 = 1;

// ---- record ops (the jcode instruction set the guest translator emits) ----

pub const R_NOP: u32 = 0;
pub const R_CONST: u32 = 1; // b = i64 value (i32 values are sign-extended)
pub const R_LGET: u32 = 2; // a = local idx
pub const R_LSET: u32 = 3;
pub const R_LTEE: u32 = 4;
pub const R_DROP: u32 = 5;
pub const R_I32ALU: u32 = 6; // a = subop (ALU_* below)
pub const R_I64ALU: u32 = 7; // a = subop (ALU_* below)
pub const R_CMP: u32 = 8; // a = subop (CMP_* below)
pub const R_JMP: u32 = 9; // a = target record idx
pub const R_JZ: u32 = 10; // a = target record idx (br_if false → fall)
pub const R_JNZ: u32 = 11; // a = target record idx
pub const R_RET: u32 = 12;
pub const R_CALL: u32 = 13; // a = funcidx (defined only)
pub const R_LOAD: u32 = 14; // a = (size<<1)|sign, b = static offset
pub const R_STORE: u32 = 15; // a = size, b = static offset
pub const R_GGET: u32 = 16; // a = global idx
pub const R_GSET: u32 = 17;
pub const R_MEMSIZE: u32 = 18;
pub const R_MEMGROW: u32 = 19; // bounded M1: pushes -1 (no growth)
pub const R_EXT: u32 = 20; // a = ext id (import trampoline)
pub const R_TRAP: u32 = 21; // a = trap code, b = original opcode (diagnostic)
pub const R_SELECT: u32 = 22;
pub const R_I32DIV: u32 = 23; // a: 0 div_s,1 div_u,2 rem_s,3 rem_u
pub const R_I64DIV: u32 = 24; // a: same
pub const R_I32ROT: u32 = 25; // a: 0 rotl,1 rotr — multiword sequence
pub const R_I64ROT: u32 = 26;
/// `br_table` — `a` = label count; the next `a+1` records are `R_JMP`
/// (labels then the default), used purely as a readable index→target table.
pub const R_BRTBL: u32 = 27;
/// `memory.fill` — pops n,val,d (wasm order d,val,n on the stack).
pub const R_MEMFILL: u32 = 28;
/// `memory.copy` — pops n,s,d.
pub const R_MEMCOPY: u32 = 29;
/// `call_indirect` — `a` = expected typeidx, `b` = tableidx (only table 0).
/// The funcref table + per-func typeidx table live in the `__jit_in` trailer.
pub const R_CALLI: u32 = 30;
/// `i32/i64.clz` — a: 0 = i32, 1 = i64.
pub const R_CLZ: u32 = 31;
/// `i32/i64.ctz` — a: 0 = i32, 1 = i64.
pub const R_CTZ: u32 = 32;
/// `i32/i64.popcnt` — a: 0 = i32, 1 = i64.
pub const R_POPCNT: u32 = 33;
/// Sign-extension ops — a: 0 i32.extend8_s, 1 i32.extend16_s,
/// 2 i64.extend8_s, 3 i64.extend16_s, 4 i64.extend32_s.
pub const R_SEXT: u32 = 34;
/// `memory.grow` that actually grows within `max_mem_pages` (M3) — a = cap in
/// pages, b = growable flag. Distinct from R_MEMGROW's M1 "always -1".
pub const R_MEMGROW2: u32 = 35;
/// `f32/f64` arithmetic + unary — `a` = the RISC-V OP-FP `funct7` (bit0 is the
/// fmt width: 0=f32, 1=f64; abs/neg carry just the fmt bit since they are int
/// bit-ops). `b` = `funct3 | (mode<<4)` where mode 0=binary, 1=unary(sqrt),
/// 2=abs, 3=neg. FP values ride the value stack as raw bit patterns; the
/// handler parks operands in the exec-model FPU regs (`f0`/`f1`).
pub const R_FPALU: u32 = 36;
/// `f32/f64` compare → i32 — `a` = funct7 (0x50|fmt); `b` = `funct3 | swap<<4 |
/// invert<<5` (feq f3=2, flt f3=1, fle f3=0; swap emits flt/fle with operands
/// reversed for gt/ge; invert xoris for ne). Result pushed as an i32 0/1.
pub const R_FPCMP: u32 = 37;
/// int↔float / float↔float conversions — `a` = `funct7 | (rs2sel<<8)`. The
/// handler derives direction from funct7: 0x60/0x61 fp→int, 0x68/0x69 int→fp,
/// 0x20/0x21 fp→fp (demote/promote). rs2sel picks int width/signedness.
pub const R_FPCVT: u32 = 38;
/// Cross-function `throw`/`rethrow` — an exception escaping the function. `b` =
/// the exception tag (`u64::MAX` for `rethrow`, which keeps the in-flight tag
/// in `OFF_EXCTAG`). The generated code sets `OFF_EXC`, folds the callee frame
/// back to the caller's pre-`call` vsp (`s10 = s11`), and returns into the
/// caller's `R_EXCCHK` — which routes to a `catch` or propagates the unwind.
pub const R_THROW: u32 = 39;
/// Post-`call`/`call_indirect` exception check — `a` = the enclosing `catch`
/// handler record (`u32::MAX` = propagate: unwind this frame to its caller).
/// Emitted after every direct/indirect call so a callee's `R_THROW` has a
/// landing pad on return.
pub const R_EXCCHK: u32 = 40;
/// `catch` handler entry — clears `OFF_EXC` so nested calls in the handler do
/// not immediately re-fire. All throws (local `R_JMP` and cross-function
/// `R_EXCCHK`) land here first, then fall through into the catch body.
pub const R_EXCCLR: u32 = 41;
/// One past the last record op — the guest dispatcher range-checks against it.
pub const R_OP_COUNT: u32 = 42;

// I32ALU/I64ALU subops — the guest indexes a literal pool of machine words.
pub const ALU_ADD: u32 = 0;
pub const ALU_SUB: u32 = 1;
pub const ALU_MUL: u32 = 2;
pub const ALU_AND: u32 = 3;
pub const ALU_OR: u32 = 4;
pub const ALU_XOR: u32 = 5;
pub const ALU_SHL: u32 = 6;
pub const ALU_SHR_S: u32 = 7;
pub const ALU_SHR_U: u32 = 8;

// CMP subops: 0..=9 i32, 10..=19 i64, 20 i32.eqz, 21 i64.eqz.
pub const CMP_EQ: u32 = 0;
pub const CMP_NE: u32 = 1;
pub const CMP_LT_S: u32 = 2;
pub const CMP_LT_U: u32 = 3;
pub const CMP_GT_S: u32 = 4;
pub const CMP_GT_U: u32 = 5;
pub const CMP_LE_S: u32 = 6;
pub const CMP_LE_U: u32 = 7;
pub const CMP_GE_S: u32 = 8;
pub const CMP_GE_U: u32 = 9;
pub const CMP64: u32 = 10; // add for the i64 row
pub const CMP_EQZ32: u32 = 20;
pub const CMP_EQZ64: u32 = 21;

// Trap codes stored in hdr `err` and printed as `WASM-JIT-TRAP <code> <aux>`.
pub const TRAP_XLATE: u32 = 1; // slot/code-arena overflow during translate
pub const TRAP_UNSUP: u32 = 2; // unsupported wasm feature (aux = opcode)
pub const TRAP_UNREACH: u32 = 3; // `unreachable` executed
pub const TRAP_DIV0: u32 = 4;
pub const TRAP_OOB: u32 = 5; // linear-memory access out of bounds
pub const TRAP_BADFUNC: u32 = 6;
pub const TRAP_FUEL: u32 = 7;
pub const TRAP_EXT: u32 = 8; // unknown import trampoline id
pub const TRAP_STK: u32 = 9; // value-stack overflow
pub const TRAP_OVF: u32 = 10; // signed div INT_MIN / -1
/// An uncaught wasm exception unwound all the way to the `JitRun`/`JitCall`
/// continuation — `OFF_EXC` still set on entry return (aux = `OFF_EXCTAG`).
pub const TRAP_EXC: u32 = 11;

// EXT ids — import trampoline table order in `jitr` (`jit_ext_tab`).
pub const EXT_LOG: u32 = 1;
pub const EXT_SET_TEXT: u32 = 2;
pub const EXT_SET_VISIBLE: u32 = 3;
pub const EXT_FETCH: u32 = 4;
pub const EXT_AWAIT: u32 = 5;
pub const EXT_THROW: u32 = 6;
pub const EXT_CATCH: u32 = 7;
// M3d libwasm handle-ABI bridge — the shipped cell's `env.*` imports map onto
// the `__dom`/`__dom_str` tree routines (`Lw*`/`Domt*`). The R_EXT `b` field
// carries `arity | has_result<<8`, so arity is per-call-site, not per-table.
pub const EXT_SETPROP: u32 = 8; // setProperty(h,noff,nlen,voff,vlen)
pub const EXT_CREATEEL: u32 = 9; // createElement(tag_str) -> node
pub const EXT_APPEND: u32 = 10; // appendChild(parent,child)
pub const EXT_AWAIT_SUP: u32 = 11; // libwasm_await_supported() -> 0
pub const EXT_AWAIT_VOID: u32 = 12; // libwasm_await__void(x)
pub const EXT_AWAIT_VAL: u32 = 13; // libwasm_await_value(x)
pub const EXT_GETROOT: u32 = 14; // getRoot() -> node
pub const EXT_ADDLSN: u32 = 15; // add_event_listener(h,eoff,elen,cb,..)
pub const EXT_RMOBJ: u32 = 16; // libwasm_removeObject(h)
pub const EXT_ADDSTR: u32 = 17; // libwasm_add__string(off,len) -> str-handle
// `__ev_obj` event-property bridge — the typed `Object_Getter__*`
// (int/uint/ushort/bool/Handle) getters read a `__ev_obj` field by name; the
// no-arg-void `Object_Call___void` is the `preventDefault` write-back.
pub const EXT_EVGET: u32 = 18; // Object_Getter__*(ev,nlen,nptr) -> field
pub const EXT_EVCALL: u32 = 19; // Object_Call___void(ev,mlen,mptr) -> void

/// M3 bounds — sized to the shipped `bios-ui-libwasm` cell (252 funcs,
/// ~69k records, 17 mem pages, ≤845 locals, 62-entry table). These are the
/// guest-side fences; the host predecoder (`jcode::encode`) fails closed
/// against them before an image is ever embedded.
pub const MAX_JIT_FUNCS: usize = 256;
pub const MAX_JIT_GLOBALS: usize = 128;
/// Locals per function — the libwasm Svelte compiler emits frames up to ~845.
pub const MAX_JIT_LOCALS: usize = 1024;
/// Records across all functions — the shipped cell decodes to ~69k.
pub const MAX_JIT_RECORDS: usize = 131_072;
/// Linear-memory pages — the cell wants 17; 64 matches `MAX_MEMORY_PAGES`.
pub const MAX_JIT_MEM_PAGES: u32 = 64;
/// Code-arena cap: `MAX_JIT_RECORDS * SLOT_BYTES` plus prologue headroom.
/// The fixed 128 B/record slot model is memory-hungry (~16 MB for the full
/// cell); that is the honest cost of the template JIT — see BROWSER-RUNTIME.
pub const MAX_JIT_CODE_BYTES: u64 = 24 << 20;
/// Guest value/call stack — must hold deep recursion over ~7 KB frames.
pub const JIT_STK_BYTES: u64 = 1 << 20;

// ---- `__jit_in` field offsets (u32 slots) ----------------------------------

pub const OFF_NFUNCS: u64 = 4;
pub const OFF_NIMPORTS: u64 = 8;
pub const OFF_ENTRY: u64 = 12;
pub const OFF_MEM_PAGES: u64 = 16;
pub const OFF_GLOB_LEN: u64 = 20;
pub const OFF_NRECORDS: u64 = 24;
pub const OFF_DATA_LEN: u64 = 28;

// ---- M3 trailer (call_indirect tables) ------------------------------------
// The trailer begins at `meta_offset`: `data_off + data_len` rounded up to 8.

/// Byte offset of the M3 trailer inside `__jit_in`, or `None` for an M1 image
/// (no trailer → `n_sig = n_table = 0`, so call_indirect traps cleanly).
pub fn meta_offset(img: &[u8]) -> Option<u64> {
    if img.len() < HDR_BYTES || u32::from_le_bytes(img[0..4].try_into().ok()?) != MAGIC {
        return None;
    }
    let nfuncs = u32::from_le_bytes(img[4..8].try_into().ok()?) as u64;
    let nrecords = u32::from_le_bytes(img[24..28].try_into().ok()?) as u64;
    let glob_len = u32::from_le_bytes(img[20..24].try_into().ok()?) as u64;
    let data_len = u32::from_le_bytes(img[28..32].try_into().ok()?) as u64;
    let off =
        HDR_BYTES as u64 + nfuncs * FHDR_BYTES as u64 + nrecords * REC_BYTES as u64 + glob_len * 8;
    let meta = (off + data_len + 7) & !7;
    if img.len() as u64 >= meta + 8 {
        Some(meta)
    } else {
        None
    }
}
/// Trailer field offsets (relative to `meta_offset`). `+0` is a magic so the
/// guest can tell an M3 trailer from absent/garbage; `n_sig` is `nfuncs`.
pub const TMETA_MAGIC: u32 = 0x324A_5447; // "GTJ2" LE — M3 trailer present
pub const META_MAGIC: u64 = 0;
pub const META_NTBL: u64 = 4;
pub const META_SIG: u64 = 8; // sig[nfuncs] u32 follows; tbl after, 8-aligned

/// Absolute offset of the AX trailer inside `__jit_in`, given the M3 trailer's
/// `meta` offset, `nfuncs`, and `n_table`. The AX block sits at
/// `tblb + n_table*8` — right after the funcref table.
pub fn ax_offset(meta: u64, nfuncs: u64, n_table: u64) -> u64 {
    let sig_len = (nfuncs * 4 + 7) & !7;
    meta + META_SIG + sig_len + n_table * 8
}

// ---- AX trailer (asyncify/listener re-entry funcidx table) -----------------
// Emitted after the M3 trailer's `tbl[]`: `{ AMETA_MAGIC, AX_COUNT, fidx[AX_COUNT] }`.
// Each slot is a funcidx the guest re-enters via `JitCall` — `u32::MAX` when the
// cell does not export that symbol. This is what turns the JIT into a re-entrant
// runtime: input events and asyncify rewind re-invoke cell functions by index.

/// `G6JM` little-endian — AX trailer present.
pub const AMETA_MAGIC: u32 = 0x4d4a_3647;
/// `_start` — the resume entry the asyncify rewind re-invokes.
pub const AX_START: u32 = 0;
/// `asyncify_get_state` → i32.
pub const AX_GET_STATE: u32 = 1;
/// `asyncify_start_unwind(data)`.
pub const AX_START_UNWIND: u32 = 2;
/// `asyncify_stop_unwind()`.
pub const AX_STOP_UNWIND: u32 = 3;
/// `asyncify_start_rewind(pos)`.
pub const AX_START_REWIND: u32 = 4;
/// `asyncify_stop_rewind()`.
pub const AX_STOP_REWIND: u32 = 5;
/// `jsCallback` — the `add_event_listener` dispatch entry.
pub const AX_JSCB: u32 = 6;
/// `jsCallback0`.
pub const AX_JSCB0: u32 = 7;
/// `allocString` — inject a string into the cell's heap.
pub const AX_ALLOC_STR: u32 = 8;
/// `__asyncify_state` *global* index (not a funcidx) — parsed from
/// `asyncify_get_state`'s `global.get` body. The guest `LwAwaitVoid`/`jit_after`
/// drive read/write it directly (`global.set` would need a mid-run `JitCall`).
pub const AX_STATE_GLOB: u32 = 9;
/// `__asyncify_data` *global* index — parsed from `asyncify_start_unwind`'s
/// second `global.set`. `u32::MAX` = no asyncify (MVP cells).
pub const AX_DATA_GLOB: u32 = 10;
/// Number of AX slots.
pub const AX_COUNT: u32 = 11;
