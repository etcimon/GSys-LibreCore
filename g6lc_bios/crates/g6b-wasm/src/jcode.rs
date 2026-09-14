// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
//! `jcode` — host-side predecode of a wasm module into the flat record stream
//! the **guest** JIT (`g6b-asm` `jitr`) consumes from `__jit_in`.
//!
//! Raw wasm is not what the guest translates: section framing, LEB immediates
//! and structured control flow are resolved here, on the host, once. What the
//! guest sees is a fixed-stride header + per-function headers + 16-byte
//! records (`op, a, b`) it can walk with `lw`/`ld`, so the emitted-code
//! builder stays a bounded straight-line routine — the thing that has to be
//! right in the payload is small.
//!
//! M1 subset: integer locals/globals, i32/i64 arithmetic and compares,
//! structured control flow (flattened to absolute record targets), direct
//! calls, linear-memory load/store, `memory.size/grow` (grow is fail-closed),
//! and the env import trampoline table. Everything else lowers to `TRAP`
//! records carrying the original opcode — a module loads and translates, and
//! the missing feature fails *named* at first execution, never silently.

#![allow(missing_docs)]

use crate::binary::{decode, Instr, ValType};

// The wire format is the guest ABI — it is owned by `g6b-asm` (`jfmt`), the
// consumer side; this crate produces it.
pub use g6b_asm::jfmt::*;

/// One emitted record.
#[derive(Debug, Clone, Copy)]
struct Rec {
    op: u32,
    a: u32,
    b: u64,
}

/// One control frame while lowering structured wasm to flat records.
#[derive(Debug)]
enum Ctrl {
    /// `block`/`if`/`try_table` body: `br` targets the record *after* `end`,
    /// backpatched when the end is seen.
    Fwd { patch: Vec<usize> },
    /// `loop`: `br` targets the record right after the `loop` opcode.
    Loop { start: u32 },
    /// `if`: the `JZ` to the else/end target, plus its own `Fwd` list for `br`.
    If { jz: usize, patch: Vec<usize> },
    /// Legacy `try`: `patch` collects the forward refs that resolve to `end`
    /// (`br`-outs plus the JMP-over-handler each `catch` emits); `throws` are
    /// `throw`/`rethrow` forward-refs patched to the first handler entry at the
    /// first `catch`. `seen_catch` stops later `catch` arms from re-patching.
    Try {
        patch: Vec<usize>,
        throws: Vec<usize>,
        seen_catch: bool,
    },
}

struct FnEnc {
    recs: Vec<Rec>,
    ctrls: Vec<Ctrl>,
}

impl FnEnc {
    fn at(&self) -> u32 {
        self.recs.len() as u32
    }
    fn push(&mut self, op: u32, a: u32, b: u64) -> usize {
        self.recs.push(Rec { op, a, b });
        self.recs.len() - 1
    }
    fn trap(&mut self, code: u32, orig: u64) {
        self.push(R_TRAP, code, orig);
    }
    /// Emit a post-`call`/`call_indirect` exception check — the landing pad a
    /// callee's `R_THROW` returns into. Inside a `try` *body* the record is
    /// queued into that try's `throws` so the first `catch` backpatches `a` to
    /// the handler; a call inside a `catch` (`seen_catch`) routes to the next
    /// enclosing try (its own protection is already consumed), and a call with
    /// no enclosing try keeps `a` = u32::MAX → propagate the unwind up a frame.
    fn excchk(&mut self) {
        let r = self.push(R_EXCCHK, u32::MAX, 0);
        for c in self.ctrls.iter_mut().rev() {
            if let Ctrl::Try {
                throws, seen_catch, ..
            } = c
            {
                if *seen_catch {
                    continue;
                }
                throws.push(r);
                break;
            }
        }
    }
    /// Resolve `br depth` to a JMP record (forward targets patch at `end`).
    fn br(&mut self, depth: u32, cond: bool) {
        let op = if cond { R_JNZ } else { R_JMP };
        let n = self.ctrls.len();
        if depth as usize >= n {
            self.trap(TRAP_XLATE, 0x0c);
            return;
        }
        let i = n - 1 - depth as usize;
        let loop_start = match &self.ctrls[i] {
            Ctrl::Loop { start } => Some(*start),
            _ => None,
        };
        let r = self.push(op, loop_start.unwrap_or(u32::MAX), 0);
        if loop_start.is_none() {
            match &mut self.ctrls[i] {
                Ctrl::Fwd { patch } | Ctrl::If { patch, .. } | Ctrl::Try { patch, .. } => {
                    patch.push(r)
                }
                _ => {}
            }
        }
    }
    fn end(&mut self) {
        let target = self.at();
        match self.ctrls.pop() {
            Some(Ctrl::If { jz, patch }) => {
                // An `if` with no `else` leaves its `jz` still pointing at the
                // u32::MAX sentinel — resolve it to `end` so `if (0)` skips the
                // then-body. `else_` already patched it when an else existed.
                if self.recs[jz].a == u32::MAX {
                    self.recs[jz].a = target;
                }
                for r in patch {
                    self.recs[r].a = target;
                }
            }
            Some(Ctrl::Fwd { patch }) | Some(Ctrl::Try { patch, .. }) => {
                for r in patch {
                    self.recs[r].a = target;
                }
            }
            Some(Ctrl::Loop { .. }) => {
                // `end` of a loop just falls through — `br` already points up.
            }
            None => {
                // Function `end`: leave an explicit RET so fallthrough returns.
                self.push(R_RET, 0, 0);
            }
        }
    }
    fn else_(&mut self) {
        let target = self.at() + 1; // record after the JMP we are about to emit
        match self.ctrls.last_mut() {
            Some(Ctrl::If { jz, .. }) => {
                self.recs[*jz].a = target;
            }
            _ => {
                self.trap(TRAP_XLATE, 0x05);
                return;
            }
        }
        // `else` reached at run time jumps to `end`: emit the JMP and let the
        // If frame's patch list fix it (the same patch list handles br).
        let r = self.push(R_JMP, u32::MAX, 0);
        if let Some(Ctrl::If { patch, .. }) = self.ctrls.last_mut() {
            patch.push(r);
        }
    }
    fn if_(&mut self) {
        let jz = self.push(R_JZ, u32::MAX, 0);
        self.ctrls.push(Ctrl::If { jz, patch: vec![] });
    }
}

/// Every WASM value type occupies one 64-bit stack/local slot — f32/f64 ride
/// as bit patterns, so the slot tag is uniform. (v128/reference types are not
/// part of the shipped cell and stay rejected.)
fn vt_wt(t: ValType) -> Result<u64, String> {
    match t {
        ValType::I32 | ValType::I64 | ValType::F32 | ValType::F64 => Ok(0),
    }
}

/// Lower one instruction list to records. `nimports` maps `call` of an
/// imported funcidx to `EXT` (unknown imports → TRAP records, named).
/// `m_mem_pages`/`m_max_pages` feed `memory.grow`'s emitted page cap.
fn lower_fn(
    instrs: &[Instr],
    imports: &[crate::binary::Import],
    types: &[crate::binary::FuncType],
    nfuncs: u32,
    m_mem_pages: u32,
    m_max_pages: Option<u32>,
    cur_fidx: u32,
    f: &mut FnEnc,
) {
    for ins in instrs {
        match *ins {
            Instr::Nop => {
                f.push(R_NOP, 0, 0);
            }
            Instr::End => f.end(),
            Instr::Block(_) => f.ctrls.push(Ctrl::Fwd { patch: vec![] }),
            Instr::Loop(_) => f.ctrls.push(Ctrl::Loop { start: f.at() }),
            Instr::If(_) => f.if_(),
            Instr::Else => f.else_(),
            Instr::Br(l) => f.br(l, false),
            Instr::BrIf(l) => f.br(l, true),
            Instr::BrTable {
                ref labels,
                default,
            } => {
                // R_BRTBL pops the index and dispatches through the `a` fields
                // of the `len+1` R_JMP records that immediately follow it
                // (labels then default). Each is lowered exactly like `br`.
                f.push(R_BRTBL, labels.len() as u32, 0);
                for l in labels {
                    f.br(*l, false);
                }
                f.br(default, false);
            }
            Instr::Return => {
                f.push(R_RET, 0, 0);
            }
            Instr::Unreachable => f.trap(TRAP_UNREACH, u64::from(cur_fidx)),
            Instr::Call(fidx) => {
                if fidx < imports.len() as u32 {
                    let im = &imports[fidx as usize];
                    match ext_id(&im.module, &im.name) {
                        Some(e) => {
                            // `b` = arity | has_result<<8 so `jit_h_ext` marshals
                            // exactly the wasm-declared params and pushes a0 only
                            // for a value-returning import (void calls leave no
                            // dead slot on the value stack).
                            let ty = &types[im.typeidx as usize];
                            let b = ty.params.len() as u64
                                | (u64::from(!ty.results.is_empty() as u32) << 8);
                            f.push(R_EXT, e, b);
                        }
                        None => f.trap(TRAP_EXT, fidx as u64),
                    }
                } else if fidx < nfuncs {
                    f.push(R_CALL, fidx, 0);
                    // Post-call exception landing pad — a callee's R_THROW
                    // returns here; the check routes to the enclosing catch or
                    // propagates the unwind. Cheap (one record per call site).
                    f.excchk();
                } else {
                    f.trap(TRAP_BADFUNC, fidx as u64);
                }
            }
            Instr::CallIndirect { typeidx, tableidx } => {
                // `a` = expected typeidx for the sig check, `b` = table index.
                f.push(R_CALLI, typeidx, u64::from(tableidx));
                f.excchk();
            }
            Instr::Drop => {
                f.push(R_DROP, 0, 0);
            }
            Instr::Select => {
                f.push(R_SELECT, 0, 0);
            }
            Instr::LocalGet(i) => {
                f.push(R_LGET, i, 0);
            }
            Instr::LocalSet(i) => {
                f.push(R_LSET, i, 0);
            }
            Instr::LocalTee(i) => {
                f.push(R_LTEE, i, 0);
            }
            Instr::GlobalGet(i) => {
                f.push(R_GGET, i, 0);
            }
            Instr::GlobalSet(i) => {
                f.push(R_GSET, i, 0);
            }
            Instr::I32Const(v) => {
                f.push(R_CONST, 0, v as i64 as u64);
            }
            Instr::I64Const(v) => {
                f.push(R_CONST, 0, v as u64);
            }
            // FP consts push the raw bit pattern (f32 low-32, f64 full u64).
            Instr::F32Const(v) => {
                f.push(R_CONST, 0, u64::from(v));
            }
            Instr::F64Const(v) => {
                f.push(R_CONST, 0, v);
            }
            Instr::I32Eqz => {
                f.push(R_CMP, CMP_EQZ32, 0);
            }
            Instr::I32Eq => {
                f.push(R_CMP, CMP_EQ, 0);
            }
            Instr::I32Ne => {
                f.push(R_CMP, CMP_NE, 0);
            }
            Instr::I32LtS => {
                f.push(R_CMP, CMP_LT_S, 0);
            }
            Instr::I32LtU => {
                f.push(R_CMP, CMP_LT_U, 0);
            }
            Instr::I32GtS => {
                f.push(R_CMP, CMP_GT_S, 0);
            }
            Instr::I32GtU => {
                f.push(R_CMP, CMP_GT_U, 0);
            }
            Instr::I32LeS => {
                f.push(R_CMP, CMP_LE_S, 0);
            }
            Instr::I32LeU => {
                f.push(R_CMP, CMP_LE_U, 0);
            }
            Instr::I32GeS => {
                f.push(R_CMP, CMP_GE_S, 0);
            }
            Instr::I32GeU => {
                f.push(R_CMP, CMP_GE_U, 0);
            }
            Instr::I32Add => {
                f.push(R_I32ALU, ALU_ADD, 0);
            }
            Instr::I32Sub => {
                f.push(R_I32ALU, ALU_SUB, 0);
            }
            Instr::I32Mul => {
                f.push(R_I32ALU, ALU_MUL, 0);
            }
            Instr::I32And => {
                f.push(R_I32ALU, ALU_AND, 0);
            }
            Instr::I32Or => {
                f.push(R_I32ALU, ALU_OR, 0);
            }
            Instr::I32Xor => {
                f.push(R_I32ALU, ALU_XOR, 0);
            }
            Instr::I32Shl => {
                f.push(R_I32ALU, ALU_SHL, 0);
            }
            Instr::I32ShrS => {
                f.push(R_I32ALU, ALU_SHR_S, 0);
            }
            Instr::I32ShrU => {
                f.push(R_I32ALU, ALU_SHR_U, 0);
            }
            Instr::I32DivS => {
                f.push(R_I32DIV, 0, 0);
            }
            Instr::I32DivU => {
                f.push(R_I32DIV, 1, 0);
            }
            Instr::I32RemS => {
                f.push(R_I32DIV, 2, 0);
            }
            Instr::I32RemU => {
                f.push(R_I32DIV, 3, 0);
            }
            Instr::I32Rotl => {
                f.push(R_I32ROT, 0, 0);
            }
            Instr::I32Rotr => {
                f.push(R_I32ROT, 1, 0);
            }
            Instr::I32Load { offset, .. } => {
                f.push(R_LOAD, 4 << 1, u64::from(offset));
            }
            Instr::I32Load8S { offset, .. } => {
                f.push(R_LOAD, (1 << 1) | 1, u64::from(offset));
            }
            Instr::I32Load8U { offset, .. } => {
                f.push(R_LOAD, 1 << 1, u64::from(offset));
            }
            Instr::I32Load16S { offset, .. } => {
                f.push(R_LOAD, (2 << 1) | 1, u64::from(offset));
            }
            Instr::I32Load16U { offset, .. } => {
                f.push(R_LOAD, 2 << 1, u64::from(offset));
            }
            Instr::I64Load { offset, .. } => {
                f.push(R_LOAD, 8 << 1, u64::from(offset));
            }
            Instr::I64Load8S { offset, .. } => {
                f.push(R_LOAD, (1 << 1) | 1, u64::from(offset));
            }
            Instr::I64Load8U { offset, .. } => {
                f.push(R_LOAD, 1 << 1, u64::from(offset));
            }
            Instr::I64Load16S { offset, .. } => {
                f.push(R_LOAD, (2 << 1) | 1, u64::from(offset));
            }
            Instr::I64Load16U { offset, .. } => {
                f.push(R_LOAD, 2 << 1, u64::from(offset));
            }
            Instr::I64Load32S { offset, .. } => {
                // sign-extends like i32.load — the same emitted `lw`.
                f.push(R_LOAD, 4 << 1, u64::from(offset));
            }
            Instr::I64Load32U { offset, .. } => {
                // zero-extend — needs `lwu`, so the sign bit distinguishes it.
                f.push(R_LOAD, (4 << 1) | 1, u64::from(offset));
            }
            // f32/f64 loads move the raw bit pattern — the same `lw`/`ld` as
            // i32/i64 (the value stack carries FP as bits; no sign-extend).
            Instr::F32Load { offset, .. } => {
                f.push(R_LOAD, 4 << 1, u64::from(offset));
            }
            Instr::F64Load { offset, .. } => {
                f.push(R_LOAD, 8 << 1, u64::from(offset));
            }
            Instr::I32Store { offset, .. } => {
                f.push(R_STORE, 4, u64::from(offset));
            }
            Instr::I32Store8 { offset, .. } => {
                f.push(R_STORE, 1, u64::from(offset));
            }
            Instr::I32Store16 { offset, .. } => {
                f.push(R_STORE, 2, u64::from(offset));
            }
            Instr::I64Store { offset, .. } => {
                f.push(R_STORE, 8, u64::from(offset));
            }
            Instr::I64Store8 { offset, .. } => {
                f.push(R_STORE, 1, u64::from(offset));
            }
            Instr::I64Store16 { offset, .. } => {
                f.push(R_STORE, 2, u64::from(offset));
            }
            Instr::I64Store32 { offset, .. } => {
                f.push(R_STORE, 4, u64::from(offset));
            }
            Instr::F32Store { offset, .. } => {
                f.push(R_STORE, 4, u64::from(offset));
            }
            Instr::F64Store { offset, .. } => {
                f.push(R_STORE, 8, u64::from(offset));
            }
            Instr::MemorySize => {
                f.push(R_MEMSIZE, 0, 0);
            }
            Instr::MemoryGrow => {
                // Real bounded grow (M3): `a` = page cap, `b` = 1 growable.
                let cap = m_max_pages.unwrap_or(m_mem_pages);
                f.push(R_MEMGROW2, cap, u64::from(m_max_pages.is_some()));
            }
            // i64 compares land in `Numeric` (0x50..=0x5a).
            Instr::Numeric(0x50) => {
                f.push(R_CMP, CMP_EQZ64, 0);
            }
            Instr::Numeric(op @ 0x51..=0x5a) => {
                f.push(R_CMP, CMP64 + u32::from(op - 0x51), 0);
            }
            // i64 arithmetic (0x7c..=0x8a; div/rem split below).
            Instr::Numeric(op @ (0x7c..=0x7e | 0x83..=0x86)) => {
                let sub = match op {
                    0x7c => ALU_ADD,
                    0x7d => ALU_SUB,
                    0x7e => ALU_MUL,
                    0x83 => ALU_AND,
                    0x84 => ALU_OR,
                    0x85 => ALU_XOR,
                    _ => ALU_SHL,
                };
                f.push(R_I64ALU, sub, 0);
            }
            Instr::Numeric(0x87) => {
                f.push(R_I64ALU, ALU_SHR_S, 0);
            }
            Instr::Numeric(0x88) => {
                f.push(R_I64ALU, ALU_SHR_U, 0);
            }
            Instr::Numeric(op @ (0x7f..=0x82)) => {
                let a = match op {
                    0x7f => 0, // div_s
                    0x80 => 1, // div_u
                    0x81 => 2, // rem_s
                    _ => 3,    // rem_u
                };
                f.push(R_I64DIV, a, 0);
            }
            Instr::Numeric(0x89) => {
                f.push(R_I64ROT, 0, 0);
            }
            Instr::Numeric(0x8a) => {
                f.push(R_I64ROT, 1, 0);
            }
            // f32/f64 compares (0x5b..=0x66) → i32 result. b: 0 f32 / 1 f64.
            // f32/f64 compares → the precomputed OP-FP encoding (funct7 /
            // funct3 / swap / invert); the guest handler is generic.
            Instr::Numeric(op @ 0x5b..=0x66) => match fp_cmp_rec(op) {
                Some((a, b)) => {
                    f.push(R_FPCMP, a, u64::from(b));
                }
                None => f.trap(TRAP_UNSUP, u64::from(op)),
            },
            // f32 (0x8b..=0x98) / f64 (0x99..=0xa6) arithmetic + unary.
            Instr::Numeric(op @ 0x8b..=0xa6) => match fp_alu_rec(op) {
                Some((a, b)) => {
                    f.push(R_FPALU, a, u64::from(b));
                }
                None => f.trap(TRAP_UNSUP, u64::from(op)),
            },
            // clz/ctz/popcnt (integer, no FP).
            Instr::Numeric(0x67) => {
                f.push(R_CLZ, 0, 0);
            }
            Instr::Numeric(0x68) => {
                f.push(R_CTZ, 0, 0);
            }
            Instr::Numeric(0x69) => {
                f.push(R_POPCNT, 0, 0);
            }
            Instr::Numeric(0x79) => {
                f.push(R_CLZ, 1, 0);
            }
            Instr::Numeric(0x7a) => {
                f.push(R_CTZ, 1, 0);
            }
            Instr::Numeric(0x7b) => {
                f.push(R_POPCNT, 1, 0);
            }
            Instr::Numeric(op) => f.trap(TRAP_UNSUP, u64::from(op)),
            // 0xc0..=0xc4 are the integer sign-extension ops (decoded as
            // Convert); 0xa7/0xac/0xad are pure-int wrap/extend.
            Instr::Convert(op @ 0xc0..=0xc4) => {
                f.push(R_SEXT, u32::from(op - 0xc0), 0);
            }
            Instr::Convert(0xa7) | Instr::Convert(0xac) => {
                f.push(R_SEXT, 4, 0); // i64→i32 / i32→i64 sign-extend low32
            }
            Instr::Convert(0xad) => {
                f.push(R_SEXT, 5, 0); // i64.extend_i32_u — zero-extend low32
            }
            // 0xa8..=0xbb — the real int↔float↔float conversions.
            Instr::Convert(op @ 0xa8..=0xbb) | Instr::SaturatingTrunc(op) => match fp_cvt_rec(op) {
                u32::MAX => f.trap(TRAP_UNSUP, 0x100 | u64::from(op)),
                a => {
                    f.push(R_FPCVT, a, 0);
                }
            },
            Instr::Convert(op) => f.trap(TRAP_UNSUP, 0x100 | u64::from(op)),
            // Legacy EH (M3c). The try body is a forward block; `catch`/`end`
            // resolve its exits. `throw`/`rethrow` emit a forward jump that the
            // innermost enclosing try's first `catch` backpatches. The operand
            // stack is NOT unwound to the handler depth — the throw path is a
            // cold error lane, so the handler reads whatever the stack holds.
            Instr::Try(_) => f.ctrls.push(Ctrl::Try {
                patch: vec![],
                throws: vec![],
                seen_catch: false,
            }),
            Instr::Catch(_) | Instr::CatchAll => {
                // close the try body / prior handler: its normal fallthrough
                // jumps to `end`; this handler begins at the next record and
                // the pending `throw` refs land here (first catch only).
                let r = f.push(R_JMP, u32::MAX, 0);
                // The handler head is an R_EXCCLR — a cross-function throw lands
                // here (via a caller-side R_EXCCHK) with OFF_EXC set; a local
                // throw arrives with it clear. Clearing keeps nested calls in
                // the handler from re-firing on the consumed exception.
                let handler_at = f.push(R_EXCCLR, 0, 0) as u32;
                match f.ctrls.last_mut() {
                    Some(Ctrl::Try {
                        patch,
                        throws,
                        seen_catch,
                    }) => {
                        patch.push(r);
                        if !*seen_catch {
                            for h in throws.drain(..) {
                                f.recs[h].a = handler_at;
                            }
                            *seen_catch = true;
                        }
                    }
                    _ => f.trap(TRAP_XLATE, 0x07),
                }
            }
            Instr::Delegate(l) => {
                // ends the try with no handler; its `br`-outs resolve to the
                // record right after the delegate, and pending `throw`s forward
                // to the enclosing try `l` (or propagate out → trap).
                let target = f.at();
                let mut pending = vec![];
                match f.ctrls.pop() {
                    Some(Ctrl::Try { patch, throws, .. }) => {
                        for r in patch {
                            f.recs[r].a = target;
                        }
                        pending = throws;
                    }
                    _ => {
                        f.trap(TRAP_XLATE, 0x08);
                    }
                }
                // forward the throws to frame `l` up; a non-try / out-of-range
                // target means the exception escapes the function — a pending
                // `R_JMP` throw becomes `R_THROW` (its tag rides `b`), while an
                // `R_EXCCHK` post-call check just stays `a`=u32::MAX (propagate).
                let n = f.ctrls.len();
                let fwd_try = if (l as usize) < n {
                    let i = n - 1 - l as usize;
                    matches!(f.ctrls[i], Ctrl::Try { .. }).then_some(i)
                } else {
                    None
                };
                match fwd_try {
                    Some(i) => {
                        if let Ctrl::Try { throws, .. } = &mut f.ctrls[i] {
                            throws.extend(pending);
                        }
                    }
                    None => {
                        for h in pending {
                            if f.recs[h].op == R_EXCCHK {
                                f.recs[h].a = u32::MAX; // propagate
                            } else {
                                f.recs[h].op = R_THROW; // escape, tag in `b`
                                f.recs[h].a = u32::MAX;
                            }
                        }
                    }
                }
            }
            Instr::Throw(t) => {
                // forward jump to the innermost enclosing try's handler. The tag
                // rides `b` up-front so a later escape (no try / delegate to a
                // non-try) keeps it when the record becomes R_THROW.
                let r = f.push(R_JMP, u32::MAX, u64::from(t));
                let mut placed = false;
                for c in f.ctrls.iter_mut().rev() {
                    if let Ctrl::Try { throws, .. } = c {
                        throws.push(r);
                        placed = true;
                        break;
                    }
                }
                if !placed {
                    // escapes the function — R_THROW unwinds the frame and
                    // returns into the caller's R_EXCCHK landing pad.
                    f.recs[r].op = R_THROW;
                    f.recs[r].a = u32::MAX;
                }
            }
            Instr::Rethrow(l) => {
                // rethrow the in-flight exception to enclosing `l`; with no such
                // enclosing try it escapes — R_THROW with b=u64::MAX keeps the
                // in-flight OFF_EXCTAG.
                let r = f.push(R_JMP, u32::MAX, u64::MAX);
                let n = f.ctrls.len();
                let mut placed = false;
                if (l as usize) < n {
                    let i = n - 1 - l as usize;
                    if let Ctrl::Try { throws, .. } = &mut f.ctrls[i] {
                        throws.push(r);
                        placed = true;
                    }
                }
                if !placed {
                    f.recs[r].op = R_THROW;
                    f.recs[r].a = u32::MAX;
                }
            }
            Instr::TryTable { .. } | Instr::ThrowRef => f.trap(TRAP_UNSUP, 0x500),
            // Bulk memory: copy/fill are real bounded loops; init/drop need a
            // passive-segment descriptor table (M3b residual — the shipped
            // cell has only active segments).
            Instr::MemoryCopy => {
                f.push(R_MEMCOPY, 0, 0);
            }
            Instr::MemoryFill => {
                f.push(R_MEMFILL, 0, 0);
            }
            Instr::MemoryInit(_)
            | Instr::DataDrop(_)
            | Instr::ElemDrop(_)
            | Instr::TableCopy { .. }
            | Instr::TableFill(_)
            | Instr::TableGet(_)
            | Instr::TableSet(_)
            | Instr::TableGrow(_)
            | Instr::TableSize(_)
            | Instr::TableInit { .. } => f.trap(TRAP_UNSUP, 0xfc),
            Instr::Unsupported(op) => f.trap(TRAP_UNSUP, u64::from(op)),
        }
    }
}

/// The `env.*` import → trampoline id. The table must match `jit_ext_tab`.
fn ext_id(module: &str, name: &str) -> Option<u32> {
    if module == "env" {
        // `Object_Getter__<kind>` is a name-encoded libwasm property getter,
        // not a fixed import. The i32-returning kinds route onto the
        // `__ev_obj` bridge (`LwEvGet`); `string`/`Optional*` take a leading
        // sret arg and `float`/`double` return FP — still unmapped (TRAP_EXT).
        if let Some(kind) = name.strip_prefix("Object_Getter__") {
            return match kind {
                "int" | "uint" | "ushort" | "bool" | "Handle" => Some(EXT_EVGET),
                _ => None,
            };
        }
        // The no-arg, void `Object_Call__<args>__void` method shape — the event
        // object's `preventDefault`/`stopPropagation` — is the `__ev_obj`
        // write-back lane (`LwEvCall`). `Object_Call` arities with args or a
        // non-void ret (`_string_string`, `_string`) fall through to the table.
        if let Some(rest) = name.strip_prefix("Object_Call_") {
            if let Some((arg_part, ret)) = rest.split_once("__") {
                if arg_part.is_empty() && ret == "void" {
                    return Some(EXT_EVCALL);
                }
            }
        }
    }
    match (module, name) {
        ("env", "log") | ("env", "Log") => Some(EXT_LOG),
        ("env", "set_inner_text") | ("env", "Object_Call_string_string") => Some(EXT_SET_TEXT),
        ("env", "set_visible") => Some(EXT_SET_VISIBLE),
        ("env", "fetch") | ("env", "Object_Call_string") | ("env", "kernel_fetch") => {
            Some(EXT_FETCH)
        }
        ("env", "await") => Some(EXT_AWAIT),
        ("env", "throw") => Some(EXT_THROW),
        ("env", "catch") => Some(EXT_CATCH),
        // M3d libwasm handle-ABI bridge — the shipped LDC/libwasm cell's
        // imports adapt onto the `__dom`/`__dom_str` tree (`Lw*`/`Domt*`).
        ("env", "setProperty") => Some(EXT_SETPROP),
        ("env", "createElement") => Some(EXT_CREATEEL),
        ("env", "appendChild") => Some(EXT_APPEND),
        ("env", "libwasm_await_supported") => Some(EXT_AWAIT_SUP),
        ("env", "libwasm_await__void") => Some(EXT_AWAIT_VOID),
        ("env", "libwasm_await_value") => Some(EXT_AWAIT_VAL),
        ("env", "getRoot") => Some(EXT_GETROOT),
        ("env", "add_event_listener") => Some(EXT_ADDLSN),
        ("env", "libwasm_removeObject") => Some(EXT_RMOBJ),
        ("env", "libwasm_add__string") => Some(EXT_ADDSTR),
        _ => None,
    }
}

/// Map an f32/f64 arithmetic or unary wasm opcode to the record `a`/`b`:
/// `a` = RISC-V OP-FP `funct7` (bit0 = fmt, set for f64), `b` =
/// `funct3 | mode<<4` (mode 0=binary, 1=unary-sqrt, 2=abs, 3=neg).
/// Returns `None` for the round-to-integral ops (0x8d..=0x90, 0x9b..=0x9e) —
/// RISC-V F has no single rounding op and the shipped cell does not use them.
fn fp_alu_rec(op: u8) -> Option<(u32, u32)> {
    let d = u32::from(op >= 0x99); // f64 row → funct7 low bit
    let (f7, f3, mode) = match op {
        0x8b | 0x99 => (0, 0, 2),    // abs  (int bit-op; fmt rides in `a`)
        0x8c | 0x9a => (0, 0, 3),    // neg
        0x91 | 0x9f => (0x2c, 0, 1), // sqrt
        0x92 | 0xa0 => (0x00, 0, 0), // add
        0x93 | 0xa1 => (0x04, 0, 0), // sub
        0x94 | 0xa2 => (0x08, 0, 0), // mul
        0x95 | 0xa3 => (0x0c, 0, 0), // div
        0x96 | 0xa4 => (0x14, 0, 0), // min
        0x97 | 0xa5 => (0x14, 1, 0), // max
        0x98 | 0xa6 => (0x10, 0, 0), // copysign
        _ => return None,
    };
    Some((f7 + d, f3 | (mode << 4)))
}

/// Map an f32/f64 compare opcode to `a`/`b`: `a` = 0x50|fmt, `b` =
/// `funct3 | swap<<4 | invert<<5`. feq f3=2, flt f3=1, fle f3=0; gt/ge swap the
/// operands onto flt/fle; ne inverts feq.
fn fp_cmp_rec(op: u8) -> Option<(u32, u32)> {
    let d = u32::from(op >= 0x61);
    let rel = if op < 0x61 { op - 0x5b } else { op - 0x61 };
    let (f3, swap, inv) = match rel {
        0 => (2, 0, 0), // eq
        1 => (2, 0, 1), // ne
        2 => (1, 0, 0), // lt
        3 => (1, 1, 0), // gt
        4 => (0, 0, 0), // le
        5 => (0, 1, 0), // ge
        _ => return None,
    };
    Some((0x50 + d, f3 | (swap << 4) | (inv << 5)))
}

/// Map an int↔float↔float conversion opcode to `a` = `funct7 | (rs2sel<<8)`.
/// Direction and width are implicit in funct7/rs2sel, decoded by the handler.
fn fp_cvt_rec(op: u8) -> u32 {
    let (f7, rs2) = match op {
        0xa8 => (0x60, 0), // i32.trunc_f32_s → fcvt.w.s
        0xa9 => (0x60, 1), // i32.trunc_f32_u → fcvt.wu.s
        0xaa => (0x61, 0), // i32.trunc_f64_s → fcvt.w.d
        0xab => (0x61, 1), // i32.trunc_f64_u → fcvt.wu.d
        0xae => (0x60, 2), // i64.trunc_f32_s → fcvt.l.s
        0xaf => (0x60, 3), // i64.trunc_f32_u → fcvt.lu.s
        0xb0 => (0x61, 2), // i64.trunc_f64_s → fcvt.l.d
        0xb1 => (0x61, 3), // i64.trunc_f64_u → fcvt.lu.d
        0xb2 => (0x68, 0), // f32.convert_i32_s → fcvt.s.w
        0xb3 => (0x68, 1), // f32.convert_i32_u → fcvt.s.wu
        0xb4 => (0x68, 2), // f32.convert_i64_s → fcvt.s.l
        0xb5 => (0x68, 3), // f32.convert_i64_u → fcvt.s.lu
        0xb6 => (0x20, 1), // f32.demote_f64    → fcvt.s.d
        0xb7 => (0x69, 0), // f64.convert_i32_s → fcvt.d.w
        0xb8 => (0x69, 1), // f64.convert_i32_u → fcvt.d.wu
        0xb9 => (0x69, 2), // f64.convert_i64_s → fcvt.d.l
        0xba => (0x69, 3), // f64.convert_i64_u → fcvt.d.lu
        0xbb => (0x21, 0), // f64.promote_f32   → fcvt.d.s
        // SaturatingTrunc (0xbc..) and the 0xa8..0xbb range collapse here; the
        // trap on non-fcvt rows keeps us honest.
        _ => return u32::MAX,
    };
    f7 | (rs2 << 8)
}

/// Predecode `wasm` into the `__jit_in` image. Fails closed on any bound the
/// guest side cannot honor (func/global/local/record/mem caps).
/// Lower one defined body (`m.bodies[i]`, func index `fidx`) into its
/// normalized record list — the same shaping `encode` applies: the fidx-68
/// `Static_Call`/`console` DIAG stub, `lower_fn`, a balanced-control check, and
/// a guaranteed terminal `R_RET`. Shared by `encode` (which packs the records
/// into the wire image) and [`op_coverage`] (which analyzes them), so the gate
/// reports on exactly the stream the guest translates.
fn lower_one(m: &crate::binary::Module, i: usize, fidx: u32) -> Result<FnEnc, String> {
    let nfuncs = (m.imports.len() + m.bodies.len()) as u32;
    let body = &m.bodies[i];
    let mut f = FnEnc {
        recs: Vec::new(),
        ctrls: Vec::new(),
    };
    // DIAG: neutralize the JS-interop `Static_Call`/`console` stub (funcidx
    // 68 = `[Unreachable]`) so a `console.error`/`info` log is a silent
    // no-op instead of a trap — lets the parse-error path proceed.
    if fidx == 68
        && body.len() == 2
        && matches!(body[0], Instr::Unreachable)
        && matches!(body[1], Instr::End)
    {
        f.push(R_RET, 0, 0);
        return Ok(f);
    }
    lower_fn(
        body,
        &m.imports,
        &m.types,
        nfuncs,
        m.mem_pages,
        m.max_mem_pages,
        fidx,
        &mut f,
    );
    if !f.ctrls.is_empty() {
        return Err(format!("jcode: func {fidx} unbalanced control flow"));
    }
    // Guarantee a terminal RET — an `end` already emits one when the ctrl
    // stack is empty, but a body may end in JMP/RET already.
    if f.recs.last().map(|r| r.op) != Some(R_RET) {
        f.push(R_RET, 0, 0);
    }
    Ok(f)
}

/// One blocking trap inside a reachable function — an op-coverage gap. If
/// control reaches it, that func dies mid-run; this is the Stage-3 preflight
/// gate's reason to exist (the plan: "report which reachable funcs contain ops
/// jitr can't lower … never let `_start` die mid-run on a TRAP record").
#[derive(Debug, Clone)]
pub struct OpGap {
    /// Function index (`>= nimports` is a defined body; `< nimports` cannot
    /// carry a trap record — imports have no body).
    pub fidx: u32,
    /// `R_TRAP.a` — the trap code: `TRAP_UNSUP` (op not lowered),
    /// `TRAP_EXT` (import with no `jit_ext_tab` slot), `TRAP_BADFUNC` (call to
    /// an out-of-range funcidx).
    pub code: u32,
    /// `R_TRAP.b` — the diagnostic payload: the wasm opcode for `TRAP_UNSUP`,
    /// the callee funcidx for `TRAP_EXT`/`TRAP_BADFUNC`.
    pub orig: u64,
}

impl OpGap {
    /// A short human description of the gap's class, for the report.
    pub fn describe(&self) -> String {
        let what = match self.code {
            TRAP_UNSUP => match self.orig {
                0x200..=0x2ff => format!("uncaught throw tag {}", self.orig & 0xff),
                0x300..=0x3ff => format!("rethrow out-of-function depth {}", self.orig & 0xff),
                0x500 => "try_table/throw_ref (wasm-eh)".into(),
                0x600 => "throw outside a try (no handler)".into(),
                0xfc => "bulk-memory init/table op".into(),
                0x100..=0x1ff => format!("convert op 0x{:02x}", self.orig & 0xff),
                _ => format!("wasm opcode 0x{:02x}", self.orig),
            },
            TRAP_EXT => format!("unmapped env import (callee fidx {})", self.orig),
            TRAP_BADFUNC => format!("call to out-of-range funcidx {}", self.orig),
            other => format!("trap code {other}"),
        };
        format!("fidx {}: {what}", self.fidx)
    }
}

/// Reachability-scoped op-coverage report — the Stage-3 preflight gate.
///
/// `encode` lowers every unhandled wasm op to an `R_TRAP` record so a module
/// always *translates*; whether that's *safe* depends on whether the trap sits
/// in code the guest can actually enter. This report walks the call graph from
/// the reachable roots — the `_start` export, every func-kind export (a
/// listener delegate / `jsCallback` is `JitCall`-ed back in, not reached by
/// `_start`'s own `call` graph), and every element-table func (the funcref set
/// a `call_indirect` or a `ref.func` index can name — the `add_event_listener`
/// delegate funcidx is exactly one of these) — and lists the blocking traps
/// inside that set. [`OpCoverage::clean`] ⇒ `libwasm_await_supported` may be 1
/// without `_start` dying on a trap record.
pub struct OpCoverage {
    /// Total funcs (imports + defined bodies).
    pub funcs: u32,
    /// Funcs reachable from the root set.
    pub reachable: u32,
    /// Blocking traps (`TRAP_UNSUP`/`TRAP_EXT`/`TRAP_BADFUNC`) in reachable
    /// funcs — each is a `funcidx` that could trap at run time.
    pub gaps: Vec<OpGap>,
    /// Reachable `TRAP_UNREACH`/`TRAP_XLATE`/other codes — a legitimate wasm
    /// `unreachable` or a translation-internal marker, not a coverage gap.
    /// Listed for audit; they do not fail `clean()`.
    pub benign: Vec<OpGap>,
}

impl OpCoverage {
    /// True when no reachable func contains a blocking trap record.
    pub fn clean(&self) -> bool {
        self.gaps.is_empty()
    }
}

/// Mark `fidx` reachable and push it for traversal (bounded to `nfuncs`).
fn cover_mark(fidx: u32, nfuncs: u32, reachable: &mut [bool], stack: &mut Vec<u32>) {
    let i = fidx as usize;
    if i < nfuncs as usize && !reachable[i] {
        reachable[i] = true;
        stack.push(fidx);
    }
}

/// Build the reachability-scoped op-coverage report for `wasm`. Decodes and
/// lowers every defined body (via [`lower_one`], so the records match what
/// `encode` packs), walks direct `R_CALL` edges from the entry set plus the
/// element-table funcs a `R_CALLI`/`ref.func` index can name, then classifies
/// each `R_TRAP` in reachable code as a coverage [`OpGap`] or a benign marker.
/// Pure analysis — does not change what `encode` emits.
pub fn op_coverage(wasm: &[u8]) -> Result<OpCoverage, String> {
    let m = decode(wasm)?;
    let nimports = m.imports.len() as u32;
    let nfuncs = nimports + m.bodies.len() as u32;
    let mut fns: Vec<FnEnc> = Vec::with_capacity(m.bodies.len());
    for i in 0..m.bodies.len() {
        fns.push(lower_one(&m, i, nimports + i as u32)?);
    }
    let mut reachable = vec![false; nfuncs as usize];
    let mut stack: Vec<u32> = Vec::new();
    // Roots: `_start` + every exported func (JitCall re-entries like the
    // delegate/`jsCallback`) + every element-table func (call_indirect /
    // ref.func targets — the add_event_listener delegate funcidx lives here).
    for e in &m.exports {
        if e.kind == 0 {
            cover_mark(e.idx, nfuncs, &mut reachable, &mut stack);
        }
    }
    for el in &m.elements {
        for &fidx in &el.funcs {
            cover_mark(fidx, nfuncs, &mut reachable, &mut stack);
        }
    }
    while let Some(fidx) = stack.pop() {
        if fidx < nimports {
            continue; // imports carry no body to traverse
        }
        let f = &fns[(fidx - nimports) as usize];
        for r in &f.recs {
            if r.op == R_CALL {
                cover_mark(r.a, nfuncs, &mut reachable, &mut stack);
            }
        }
    }
    let mut gaps = Vec::new();
    let mut benign = Vec::new();
    for (i, f) in fns.iter().enumerate() {
        let fidx = nimports + i as u32;
        if !reachable[fidx as usize] {
            continue;
        }
        for r in &f.recs {
            if r.op != R_TRAP {
                continue;
            }
            let gap = OpGap {
                fidx,
                code: r.a,
                orig: r.b,
            };
            match r.a {
                TRAP_UNSUP | TRAP_EXT | TRAP_BADFUNC => gaps.push(gap),
                _ => benign.push(gap),
            }
        }
    }
    Ok(OpCoverage {
        funcs: nfuncs,
        reachable: reachable.iter().filter(|&&b| b).count() as u32,
        gaps,
        benign,
    })
}

pub fn encode(wasm: &[u8]) -> Result<Vec<u8>, String> {
    let m = decode(wasm)?;
    let nimports = m.imports.len() as u32;
    let nfuncs = nimports + m.bodies.len() as u32;
    if nfuncs as usize > MAX_JIT_FUNCS {
        return Err(format!(
            "jcode: {nfuncs} funcs exceeds guest jit bound {MAX_JIT_FUNCS}"
        ));
    }
    if m.globals.len() > MAX_JIT_GLOBALS {
        return Err(format!("jcode: {} globals exceeds bound", m.globals.len()));
    }
    if m.mem_pages > MAX_JIT_MEM_PAGES {
        return Err(format!(
            "jcode: {} mem pages exceeds bound {MAX_JIT_MEM_PAGES}",
            m.mem_pages
        ));
    }
    if !m.has_memory && m.mem_pages != 0 {
        return Err("jcode: mem_pages without memory section".into());
    }
    let entry = m
        .exports
        .iter()
        .find(|e| e.kind == 0 && e.name == "_start")
        .map(|e| e.idx)
        .unwrap_or(u32::MAX);
    if entry == u32::MAX {
        return Err("jcode: no _start export".into());
    }
    if entry < nimports {
        return Err("jcode: _start is imported".into());
    }

    // Lower each defined body; count records for the global table.
    let mut fhdrs: Vec<[u32; 6]> = Vec::with_capacity(nfuncs as usize);
    let mut recs: Vec<Rec> = Vec::new();
    for _ in 0..nimports {
        fhdrs.push([0, 0, 0, 0, 0, FHDR_F_IMPORT]);
    }
    for i in 0..m.bodies.len() {
        let fidx = nimports as usize + i;
        let ty = &m.types[m.func_types[i] as usize];
        let nparams = ty.params.len() as u32;
        for p in &ty.params {
            vt_wt(*p)?;
        }
        for r in &ty.results {
            vt_wt(*r)?;
        }
        let nlocals = nparams + m.locals.get(i).copied().unwrap_or(0);
        if nlocals as usize > MAX_JIT_LOCALS {
            return Err(format!("jcode: func {fidx} locals {nlocals} exceeds bound"));
        }
        if ty.results.len() > 4 {
            return Err("jcode: >4 results is M3".into());
        }
        let bc_off = recs.len() as u32;
        let f = lower_one(&m, i, fidx as u32)?;
        let bc_len = f.recs.len() as u32;
        recs.extend(f.recs);
        if recs.len() > MAX_JIT_RECORDS {
            return Err(format!(
                "jcode: {} records exceeds bound {MAX_JIT_RECORDS}",
                recs.len()
            ));
        }
        fhdrs.push([bc_off, bc_len, nparams, nlocals, ty.results.len() as u32, 0]);
    }

    // Data image: active segments applied at their static offsets.
    let mem_len = (m.mem_pages as usize) * 65536;
    let mut data = vec![0u8; 0];
    if mem_len > 0 {
        let mut img = vec![0u8; mem_len];
        for seg in &m.data_segments {
            if !seg.active {
                continue;
            }
            let off = seg.offset as usize;
            if off + seg.bytes.len() > img.len() {
                return Err("jcode: data segment out of memory".into());
            }
            img[off..off + seg.bytes.len()].copy_from_slice(&seg.bytes);
        }
        // Trim trailing zeros — the BSS is already zeroed.
        let mut end = img.len();
        while end > 0 && img[end - 1] == 0 {
            end -= 1;
        }
        data = img[..end].to_vec();
    }

    let mut out = Vec::with_capacity(HDR_BYTES + fhdrs.len() * FHDR_BYTES + recs.len() * REC_BYTES);
    let w32 = |o: &mut Vec<u8>, v: u32| o.extend_from_slice(&v.to_le_bytes());
    // `OFF_MEM_PAGES` carries the *usable* page bound — the cell's grow cap
    // (`max_mem_pages`, or `MAX_JIT_MEM_PAGES` when the cell declares no max,
    // matching the interpreter's `reserve_asyncify_scratch` ceiling) — not the
    // declared minimum. `memory.size` reports it, so `WasmAllocator.end`
    // covers the cell's full heap and `memory.grow` never has to fire into
    // the `__kget`/asyncify tail that sits past the usable region. `mem_pages`
    // alone leaves the cell a ~1.4KiB heap, and `WasmAllocator.grow` extends
    // `end` unconditionally — spilling into the tail and clobbering the
    // awaited response pool.
    let usable_pages = m
        .mem_pages
        .max(m.max_mem_pages.unwrap_or(256));
    w32(&mut out, MAGIC);
    w32(&mut out, nfuncs);
    w32(&mut out, nimports);
    w32(&mut out, entry);
    w32(&mut out, usable_pages);
    w32(&mut out, m.globals.len() as u32);
    w32(&mut out, recs.len() as u32);
    w32(&mut out, data.len() as u32);
    for h in &fhdrs {
        for v in h {
            w32(&mut out, *v);
        }
    }
    for r in &recs {
        w32(&mut out, r.op);
        w32(&mut out, r.a);
        out.extend_from_slice(&r.b.to_le_bytes());
    }
    for g in &m.globals {
        out.extend_from_slice(&(g.value as u64).to_le_bytes());
    }
    out.extend_from_slice(&data);

    // ---- M3 trailer: call_indirect sig + funcref tables --------------------
    // `meta_offset` is `data_off + data_len` aligned to 8; the guest reads
    // `n_sig`/`n_table` there, then `sig[]` and `tbl[]`.
    while out.len() % 8 != 0 {
        out.push(0);
    }
    // sig[fidx] = typeidx (imports first, then defined funcs).
    let mut sig: Vec<u32> = Vec::with_capacity(nfuncs as usize);
    for im in &m.imports {
        sig.push(im.typeidx);
    }
    for t in &m.func_types {
        sig.push(*t);
    }
    // Funcref table: size = max(table.min, max(elem.offset + elem.funcs.len())).
    let mut n_table = m.tables.iter().map(|t| t.min).max().unwrap_or(0);
    for e in &m.elements {
        n_table = n_table.max(e.offset.max(0) as u32 + e.funcs.len() as u32);
    }
    let mut tbl = vec![-1i64; n_table as usize];
    for e in &m.elements {
        let base = e.offset.max(0) as usize;
        for (j, fidx) in e.funcs.iter().enumerate() {
            if base + j < tbl.len() {
                tbl[base + j] = i64::from(*fidx);
            }
        }
    }
    w32(&mut out, TMETA_MAGIC);
    w32(&mut out, n_table);
    for s in &sig {
        w32(&mut out, *s);
    }
    while out.len() % 8 != 0 {
        out.push(0);
    }
    for t in &tbl {
        out.extend_from_slice(&t.to_le_bytes());
    }

    // ---- AX trailer: asyncify/listener funcidx table -----------------------
    // The guest re-enters cell functions by index via `JitCall` — for input-
    // event listener dispatch and for the asyncify rewind that resumes an
    // awaited `_start`. Slots follow `jfmt::AX_*`; `u32::MAX` = not exported.
    use g6b_asm::jfmt::{
        AMETA_MAGIC, AX_ALLOC_STR, AX_COUNT, AX_DATA_GLOB, AX_GET_STATE, AX_JSCB, AX_JSCB0,
        AX_START, AX_START_REWIND, AX_START_UNWIND, AX_STATE_GLOB, AX_STOP_REWIND,
        AX_STOP_UNWIND,
    };
    const AX_NAMES: [(&str, u32); 9] = [
        ("_start", AX_START),
        ("asyncify_get_state", AX_GET_STATE),
        ("asyncify_start_unwind", AX_START_UNWIND),
        ("asyncify_stop_unwind", AX_STOP_UNWIND),
        ("asyncify_start_rewind", AX_START_REWIND),
        ("asyncify_stop_rewind", AX_STOP_REWIND),
        ("jsCallback", AX_JSCB),
        ("jsCallback0", AX_JSCB0),
        ("allocString", AX_ALLOC_STR),
    ];
    let mut axv = [u32::MAX; AX_COUNT as usize];
    for (name, slot) in AX_NAMES {
        if let Some(e) = m.exports.iter().find(|e| e.kind == 0 && e.name == name) {
            axv[slot as usize] = e.idx;
        }
    }
    // `__asyncify_state`/`__asyncify_data` global indices — the guest
    // `LwAwaitVoid`/`jit_after` drive writes them directly mid-run. Parsed from
    // the asyncify bodies like `Asyncify::new` (`u32::MAX` = MVP cell, no
    // asyncify — the await path then fails closed on a null promise).
    if let Ok(ax) = crate::asyncify::Asyncify::new(&m) {
        axv[AX_STATE_GLOB as usize] = ax.state_global;
        axv[AX_DATA_GLOB as usize] = ax.data_global;
    }
    w32(&mut out, AMETA_MAGIC);
    w32(&mut out, AX_COUNT);
    for v in axv {
        w32(&mut out, v);
    }
    Ok(out)
}

/// Where the data image begins inside `__jit_in` — guest memcpy source.
pub fn data_offset(img: &[u8]) -> Option<(u64, u64)> {
    if img.len() < HDR_BYTES || u32::from_le_bytes(img[0..4].try_into().ok()?) != MAGIC {
        return None;
    }
    let nfuncs = u32::from_le_bytes(img[4..8].try_into().ok()?) as u64;
    let nrecords = u32::from_le_bytes(img[24..28].try_into().ok()?) as u64;
    let glob_len = u32::from_le_bytes(img[20..24].try_into().ok()?) as u64;
    let data_len = u32::from_le_bytes(img[28..32].try_into().ok()?) as u64;
    let off =
        HDR_BYTES as u64 + nfuncs * FHDR_BYTES as u64 + nrecords * REC_BYTES as u64 + glob_len * 8;
    Some((off, data_len))
}

/// Bounded M1 smoke cell: `_start ()->i32` runs a real loop (backward `br_if`),
/// a direct `call`, a store to linear memory, and returns the sum.
///
/// ```wat
/// (func $add2 (param i32) (result i32) local.get 0 i32.const 2 i32.add)
/// (func $_start (result i32) (local i32 i32)
///   i32.const 0 local.set 0
///   i32.const 7 local.set 1
///   loop local.get 0 local.get 1 i32.add local.set 0
///        local.get 1 i32.const 1 i32.sub local.tee 1
///        br_if $loop end
///   i32.const 0 local.get 0 i32.store   ;; mem[0] = 28
///   local.get 0 call $add2)             ;; → 30
/// ```
pub fn test_module() -> Vec<u8> {
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 2);
    types.extend_from_slice(&[0x60, 0, 1, 0x7f]); // ()->i32
    types.extend_from_slice(&[0x60, 1, 0x7f, 1, 0x7f]); // (i32)->i32
    section(&mut out, 1, &types);

    let mut funcs = Vec::new();
    push_uleb(&mut funcs, 2);
    push_uleb(&mut funcs, 1); // func0 add2 : type1
    push_uleb(&mut funcs, 0); // func1 _start: type0
    section(&mut out, 3, &funcs);

    let mut memory = Vec::new();
    push_uleb(&mut memory, 1);
    memory.push(0x00);
    memory.push(0x01);
    section(&mut out, 5, &memory);

    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.push(0x02);
    push_uleb(&mut exports, 0);
    put_name(&mut exports, "_start");
    exports.push(0x00);
    push_uleb(&mut exports, 1);
    section(&mut out, 7, &exports);

    // func0 add2: local.get 0; i32.const 2; i32.add; end
    let mut b0 = Vec::new();
    push_uleb(&mut b0, 0);
    b0.extend_from_slice(&[0x20, 0x00, 0x41, 0x02, 0x6a, 0x0b]);
    // func1 _start
    let mut b1 = Vec::new();
    push_uleb(&mut b1, 1); // one local group
    push_uleb(&mut b1, 2); // count 2
    b1.push(0x7f); // i32
    b1.extend_from_slice(&[
        0x41, 0x00, 0x21, 0x00, // i32.const 0; local.set 0
        0x41, 0x07, 0x21, 0x01, // i32.const 7; local.set 1
        0x03, 0x40, // loop (void)
        0x20, 0x00, 0x20, 0x01, 0x6a, 0x21, 0x00, // acc += n
        0x20, 0x01, 0x41, 0x01, 0x6b, 0x22, 0x01, // n--
        0x0d, 0x00, // br_if 0
        0x0b, // end
        0x41, 0x00, 0x20, 0x00, 0x36, 0x02, 0x00, // i32.store align=2 off=0
        0x20, 0x00, 0x10, 0x00, // local.get 0; call 0
        0x0b,
    ]);
    let mut code = Vec::new();
    push_uleb(&mut code, 2);
    push_uleb(&mut code, b0.len() as u32);
    code.extend_from_slice(&b0);
    push_uleb(&mut code, b1.len() as u32);
    code.extend_from_slice(&b1);
    section(&mut out, 10, &code);
    out
}

/// M3 smoke cell: exercises `call_indirect` (table[0]=func0), `i32.clz`,
/// `i32.ctz`, `i32.popcnt`, `i32.extend8_s`, `br_table`, `memory.fill` and
/// `memory.copy`. `_start` returns 272 when every op lowers+executes right:
/// 105 +28 +3 +4 −1 +7 +63 +63.
///
/// ```wat
/// (func $addH (param i32) (result i32) local.get 0 i32.const 100 i32.add)
/// (table 1 funcref) (elem (i32.const 0) $addH)
/// (memory 1)
/// (func $_start (result i32)
///   i32.const 5 i32.const 0 call_indirect   ;; func0(5) = 105
///   i32.const 8 i32.clz i32.add           ;; +28 = 133
///   i32.const 8 i32.ctz i32.add           ;; +3  = 136
///   i32.const 15 i32.popcnt i32.add       ;; +4  = 140
///   i32.const 255 i32.extend8_s i32.add   ;; −1  = 139
///   block block i32.const 1 br_table 0 1 end i32.const 63 return end
///   i32.const 7 i32.add                   ;; idx1 → default → +7 = 146
///   i32.const 0 i32.const 63 i32.const 4 memory.fill
///   i32.const 0 i32.load8_u i32.add       ;; +63 = 209
///   i32.const 8 i32.const 0 i32.const 4 memory.copy
///   i32.const 8 i32.load8_u i32.add       ;; +63 = 272
/// )
/// ```
#[cfg(test)]
pub fn test_module_m3() -> Vec<u8> {
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    // types: t0 (i32)->i32, t1 ()->i32
    let mut types = Vec::new();
    push_uleb(&mut types, 2);
    types.extend_from_slice(&[0x60, 1, 0x7f, 1, 0x7f]);
    types.extend_from_slice(&[0x60, 0, 1, 0x7f]);
    section(&mut out, 1, &types);
    // funcs: f0=t0, f1=t1
    section(&mut out, 3, &[2, 0, 1]);
    // table: 1 funcref table, min 1
    section(&mut out, 4, &[1, 0x70, 0x00, 0x01]);
    // memory: 1 page
    section(&mut out, 5, &[1, 0x00, 0x01]);
    // exports: memory + _start(func1)
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.push(0x02);
    push_uleb(&mut exports, 0);
    put_name(&mut exports, "_start");
    exports.push(0x00);
    push_uleb(&mut exports, 1);
    section(&mut out, 7, &exports);
    // element: active table0 off=i32.const0 funcs=[0]
    section(&mut out, 9, &[1, 0x00, 0x41, 0x00, 0x0b, 0x01, 0x00]);
    // code
    let b0 = [0x00, 0x20, 0x00, 0x41, 0x0a, 0x6a, 0x0b]; // addH: lget0; +10; add
    let b1 = [
        0x00, // locals
        0x41, 0x05, // i32.const 5
        0x41, 0x00, // i32.const 0
        0x11, 0x00, 0x00, // call_indirect type0 table0 → 105
        0x41, 0x08, 0x67, 0x6a, // i32.const 8; clz → +28
        0x41, 0x08, 0x68, 0x6a, // i32.const 8; ctz → +3
        0x41, 0x0f, 0x69, 0x6a, // i32.const 15; popcnt → +4
        0x41, 0xff, 0x01, 0xc0, 0x6a, // i32.const 255; extend8_s → −1
        0x02, 0x40, // block $done
        0x02, 0x40, // block $default
        0x41, 0x01, // i32.const 1
        0x0e, 0x01, 0x00, 0x01, // br_table [0] default 1 → depth1
        0x0b, // end $default
        0x41, 0x3f, 0x0f, // i32.const 63; return (idx0 path)
        0x0b, // end $done
        0x41, 0x07, 0x6a, // i32.const 7; add → +7
        0x41, 0x00, 0x41, 0x3f, 0x41, 0x04, 0xfc, 0x0b, 0x00, // memory.fill 0,63,4
        0x41, 0x00, 0x2d, 0x00, 0x00, 0x6a, // i32.load8_u(0) → +63
        0x41, 0x08, 0x41, 0x00, 0x41, 0x04, 0xfc, 0x0a, 0x00, 0x00, // memory.copy
        0x41, 0x08, 0x2d, 0x00, 0x00, 0x6a, // i32.load8_u(8) → +63
        0x0b,
    ];
    let mut code = Vec::new();
    push_uleb(&mut code, 2);
    push_uleb(&mut code, b0.len() as u32);
    code.extend_from_slice(&b0);
    push_uleb(&mut code, b1.len() as u32);
    code.extend_from_slice(&b1);
    section(&mut out, 10, &code);
    out
}

/// Listener re-entry cell. `_start` builds a `<button id="x">` under the root
/// and registers `add_event_listener("x","keydown",$delegate)` — the real
/// `Listener::Wasm` lane, where `cb` is a function index `LwAddLsn` biases into
/// `N_LISTEN >= 0x100`. `$delegate(ev)` then `appendChild(getRoot(),
/// createElement(button))`, so a keydown dispatched to the focused node
/// re-enters the cell through `JitCall` and grows `__dom` (root+button → +1).
///
/// ```wat
/// (import "env" "getRoot" (func $getRoot (result i32)))            ;; f0
/// (import "env" "createElement" (func $createEl (param i32) (result i32))) ;; f1
/// (import "env" "appendChild" (func $append (param i32 i32)))      ;; f2
/// (import "env" "setProperty" (func $setProp (param i32 x5)))      ;; f3
/// (import "env" "add_event_listener" (func $addLsn (param i32 x6)));; f4
/// (memory 1)
/// (func $delegate (param i32)                                     ;; f5
///   call $getRoot i32.const 14 call $createEl call $append)
/// (func $_start (local i32)                                       ;; f6
///   i32.const 14 call $createEl local.set 0          ;; el = <button>
///   local.get 0 i32.const 2 i32.const ID i32.const 1 i32.const X call $setProp ;; el.id="x"
///   call $getRoot local.get 0 call $append          ;; root.appendChild(el)
///   i32.const X i32.const 1 i32.const KD i32.const 7 i32.const 5 i32.const 0
///   call $addLsn)                                  ;; add_event_listener("x","keydown",$delegate)
/// ```
#[cfg(test)]
pub fn test_module_delegate() -> Vec<u8> {
    test_module_delegate_ev(b"keydown")
}

/// Same cell as [`test_module_delegate`] but the listener is registered for a
/// different event type — `b"click"` wires the `EV_CLICK`/`DomtPtr` lane, so a
/// real tablet `BTN_LEFT` press re-enters `$delegate`. The event string is the
/// tail of the `__wasm_mem` pool (id@0x10, x@0x12, ev@0x13).
#[cfg(test)]
pub fn test_module_delegate_ev(ev: &[u8]) -> Vec<u8> {
    // `__wasm_mem` string pool (data segment): "id"@0x10, "x"@0x12, ev@0x13.
    const ID: u8 = 0x10;
    const X: u8 = 0x12;
    const KD: u8 = 0x13;
    let tylen = ev.len() as u8;
    const ORD: u8 = 14; // libwasm NodeType::button
    const DELEGATE: u8 = 5; // $delegate func index (imports 0..=4 first)
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();

    // types: t0 ()->i32 · t1 (i32)->i32 · t2 (i32,i32)->() · t3 (i32 x5)->()
    //        t4 (i32 x6)->() · t5 (i32)->() · t6 ()->()
    let mut types = Vec::new();
    push_uleb(&mut types, 7);
    types.extend_from_slice(&[0x60, 0x00, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x02, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x05, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x06, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x00, 0x00]);
    section(&mut out, 1, &types);

    // imports: env.{getRoot,createElement,appendChild,setProperty,add_event_listener}
    let mut imps = Vec::new();
    push_uleb(&mut imps, 5);
    for (name, ty) in [
        ("getRoot", 0u8),
        ("createElement", 1),
        ("appendChild", 2),
        ("setProperty", 3),
        ("add_event_listener", 4),
    ] {
        put_name(&mut imps, "env");
        put_name(&mut imps, name);
        imps.push(0x00); // func
        imps.push(ty);
    }
    section(&mut out, 2, &imps);

    // funcs: $delegate(t5) → idx5, $_start(t6) → idx6
    section(&mut out, 3, &[2, 0x05, 0x06]);
    // memory: min 1 page
    section(&mut out, 5, &[1, 0x00, 0x01]);

    // exports: memory(0), _start(func 6)
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.extend_from_slice(&[0x02, 0x00]);
    put_name(&mut exports, "_start");
    exports.extend_from_slice(&[0x00, 0x06]);
    section(&mut out, 7, &exports);

    // $delegate(ev:i32): appendChild(getRoot(), createElement(ORD))
    let mut bdel = vec![0x00]; // 0 local groups
    bdel.extend_from_slice(&[
        0x10, 0x00, // call $getRoot
        0x41, ORD,  // i32.const ORD
        0x10, 0x01, // call $createElement
        0x10, 0x02, // call $appendChild
        0x0b,
    ]);
    // $_start(): local0 = el handle
    let mut bst = vec![0x01, 0x01, 0x7f]; // 1 local group, count1, i32
    bst.extend_from_slice(&[
        0x41, ORD, 0x10, 0x01, 0x21, 0x00, // el = createElement(ORD); local.set 0
        0x20, 0x00,                       // local.get 0  (el handle)
        0x41, 0x02, 0x41, ID,             //   namelen=2  nameptr=ID   ("id")
        0x41, 0x01, 0x41, X,              //   vallen=1   valptr=X    ("x")
        0x10, 0x03,                       // setProperty(el,"id","x") — len-first ABI
        0x10, 0x00, 0x20, 0x00, 0x10, 0x02, // appendChild(getRoot(), el)
        0x41, X, 0x41, 0x01,              // tptr=X  tlen=1   ("x")     ptr-first ABI
        0x41, KD, 0x41, tylen,            // typtr=KD tylen (the event name)
        0x41, DELEGATE,                   // cb = $delegate funcidx 5
        0x41, 0x00,                       // capture = 0
        0x10, 0x04,                       // add_event_listener("x",<ev>,5,0)
        0x0b,
    ]);
    let mut code = Vec::new();
    push_uleb(&mut code, 2);
    push_uleb(&mut code, bdel.len() as u32);
    code.extend_from_slice(&bdel);
    push_uleb(&mut code, bst.len() as u32);
    code.extend_from_slice(&bst);
    section(&mut out, 10, &code);

    // data @0x10: "id" "x" <ev> packed contiguously
    let mut data = Vec::new();
    push_uleb(&mut data, 1);
    data.extend_from_slice(&[0x00, 0x41, 0x10, 0x0b]); // active mem0, off=i32.const 0x10
    let mut body = b"idx".to_vec(); // id@0x10, x@0x12, ev@0x13
    body.extend_from_slice(ev);
    push_uleb(&mut data, body.len() as u32);
    data.extend_from_slice(&body);
    section(&mut out, 11, &data);
    out
}

/// Click delegate that *reads the event object*. `_start` builds
/// `root + <button id="x">` and registers `add_event_listener("x","click",
/// $delegate)`. `$delegate(ev)` exercises the `Object_Getter__*`/`Object_Call`
/// bridge (`LwEvGet`/`LwEvCall`): it reads `clientX`, `target`, calls
/// `preventDefault`, reads `defaultPrevented`, and `appendChild`s a node for
/// each result that came back nonzero — so `__dom` grows only when the bridge
/// actually populated `__ev_obj` and the write-back round-tripped.
#[cfg(test)]
pub fn test_module_evget() -> Vec<u8> {
    // `__wasm_mem` pool (data @0x10). Every name offset stays < 0x40 so each
    // `i32.const <off>` arg is a single signed-LEB byte (offsets ≥ 0x40 need a
    // two-byte encoding this builder doesn't emit). id@0x10 x@0x12 click@0x13
    // clientX@0x18 target@0x1f defaultPrevented@0x25 preventDefault@0x35.
    const ID: u8 = 0x10;
    const X: u8 = 0x12;
    const EV: u8 = 0x13; // "click"
    const CX: u8 = 0x18; // "clientX"
    const TG: u8 = 0x1f; // "target"
    const DP: u8 = 0x25; // "defaultPrevented" (getter)
    const PD: u8 = 0x35; // "preventDefault" (method)
    const ORD: u8 = 14; // NodeType::button
    const DELEGATE: u8 = 9; // $delegate funcidx (9 imports 0..=8 first)
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();

    // t0 ()->i32 · t1 (i32)->i32 · t2 (i32,i32)->() · t3 (i32x5)->()
    // t4 (i32x6)->() · t5 (i32)->() · t6 ()->()
    // t7 (i32,i32,i32)->i32 (getters) · t8 (i32,i32,i32)->() (void call)
    let mut types = Vec::new();
    push_uleb(&mut types, 9);
    types.extend_from_slice(&[0x60, 0x00, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x02, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x05, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x06, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x00, 0x00]);
    types.extend_from_slice(&[0x60, 0x03, 0x7f, 0x7f, 0x7f, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x03, 0x7f, 0x7f, 0x7f, 0x00]);
    section(&mut out, 1, &types);

    let mut imps = Vec::new();
    push_uleb(&mut imps, 9);
    for (name, ty) in [
        ("getRoot", 0u8),
        ("createElement", 1),
        ("appendChild", 2),
        ("setProperty", 3),
        ("add_event_listener", 4),
        ("Object_Getter__int", 7),
        ("Object_Getter__Handle", 7),
        ("Object_Call___void", 8),
        ("Object_Getter__bool", 7),
    ] {
        put_name(&mut imps, "env");
        put_name(&mut imps, name);
        imps.push(0x00);
        imps.push(ty);
    }
    section(&mut out, 2, &imps);

    section(&mut out, 3, &[2, 0x05, 0x06]); // $delegate(t5)=9, $_start(t6)=10
    section(&mut out, 5, &[1, 0x00, 0x01]); // memory min 1 page

    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.extend_from_slice(&[0x02, 0x00]);
    put_name(&mut exports, "_start");
    exports.extend_from_slice(&[0x00, 0x0a]);
    section(&mut out, 7, &exports);

    // $delegate(ev:i32): locals cx=1 tgt=2 dp=3. Appends one node iff the
    // bridge returned *correct* values — `clientX>=200` (the real scaled px),
    // `target!=0` (a real node handle), and `defaultPrevented` after
    // `preventDefault()` (the write-back round-trip). A bridge that returns 0
    // appends nothing, so `__dom` growth is the discriminator.
    let mut bdel = vec![0x01, 0x03, 0x7f]; // 1 group, 3 i32 locals
    bdel.extend_from_slice(&[
        // cx = ev.clientX  → Object_Getter__int(ev, 7, CX)
        0x20, 0x00, 0x41, 0x07, 0x41, CX, 0x10, 0x05, 0x21, 0x01,
        // tgt = ev.target → Object_Getter__Handle(ev, 6, TG)
        0x20, 0x00, 0x41, 0x06, 0x41, TG, 0x10, 0x06, 0x21, 0x02,
        // ev.preventDefault() → Object_Call___void(ev, 14, PD)
        0x20, 0x00, 0x41, 0x0e, 0x41, PD, 0x10, 0x07,
        // dp = ev.defaultPrevented → Object_Getter__bool(ev, 16, DP)
        0x20, 0x00, 0x41, 0x10, 0x41, DP, 0x10, 0x08, 0x21, 0x03,
        // pred = (cx >= 200) && (tgt != 0) && dp
        0x20, 0x01, 0x41, 0xC8, 0x01, 0x4e, // local.get cx; i32.const 200; i32.ge_s
        0x20, 0x02, 0x41, 0x00, 0x47, //       local.get tgt; i32.const 0; i32.ne
        0x71, //                             i32.and
        0x20, 0x03, 0x71, //                 local.get dp; i32.and
        0x04, 0x40, //                       if (void)
        0x10, 0x00, 0x41, ORD, 0x10, 0x01, 0x10, 0x02, // appendChild(getRoot(),createElement(ORD))
        0x0b, // end if
        0x0b, // end func
    ]);

    // $_start(): build + register, identical to the click-delegate cell.
    let mut bst = vec![0x01, 0x01, 0x7f];
    bst.extend_from_slice(&[
        0x41, ORD, 0x10, 0x01, 0x21, 0x00, // el = createElement(ORD)
        0x20, 0x00, 0x41, 0x02, 0x41, ID, 0x41, 0x01, 0x41, X, 0x10, 0x03, // setProperty(el,"id","x")
        0x10, 0x00, 0x20, 0x00, 0x10, 0x02, // appendChild(getRoot(), el)
        0x41, X, 0x41, 0x01, // tptr=X tlen=1
        0x41, EV, 0x41, 0x05, // typtr=EV tylen=5 ("click")
        0x41, DELEGATE, // cb = $delegate funcidx 9
        0x41, 0x00, // capture=0
        0x10, 0x04, // add_event_listener("x","click",9,0)
        0x0b,
    ]);

    let mut code = Vec::new();
    push_uleb(&mut code, 2);
    push_uleb(&mut code, bdel.len() as u32);
    code.extend_from_slice(&bdel);
    push_uleb(&mut code, bst.len() as u32);
    code.extend_from_slice(&bst);
    section(&mut out, 10, &code);

    // data @0x10: pack the pool strings at their declared offsets (end 0x43).
    let mut body = vec![0u8; 0x43 - 0x10];
    let put = |body: &mut Vec<u8>, off: u8, s: &str| {
        body[(off as usize) - 0x10..(off as usize) - 0x10 + s.len()].copy_from_slice(s.as_bytes());
    };
    put(&mut body, ID, "id");
    put(&mut body, X, "x");
    put(&mut body, EV, "click");
    put(&mut body, CX, "clientX");
    put(&mut body, TG, "target");
    put(&mut body, DP, "defaultPrevented");
    put(&mut body, PD, "preventDefault");
    let mut data = Vec::new();
    push_uleb(&mut data, 1);
    data.extend_from_slice(&[0x00, 0x41, 0x10, 0x0b]); // active mem0, off=i32.const 0x10
    push_uleb(&mut data, body.len() as u32);
    data.extend_from_slice(&body);
    section(&mut out, 11, &data);
    out
}

fn push_uleb(out: &mut Vec<u8>, v: u32) {
    let mut v = v;
    loop {
        let b = (v & 0x7f) as u8;
        v >>= 7;
        if v == 0 {
            out.push(b);
            return;
        }
        out.push(b | 0x80);
    }
}

fn section(out: &mut Vec<u8>, id: u8, payload: &[u8]) {
    out.push(id);
    push_uleb(out, payload.len() as u32);
    out.extend_from_slice(payload);
}

fn put_name(out: &mut Vec<u8>, s: &str) {
    push_uleb(out, s.len() as u32);
    out.extend_from_slice(s.as_bytes());
}

/// Predecode `wasm` and install the image into a module whose guest-JIT
/// substrate is already attached (`g6b_asm::analyze` under
/// `kernel.wasm.guest_jit`). This is the host-side half of the guest JIT —
/// the encoded records, not the wasm bytes, are what the payload carries.
pub fn install_guest(m: &mut g6b_asm::Module, wasm: &[u8]) -> Result<(), String> {
    let img = encode(wasm)?;
    g6b_asm::jitr::set_image(m, &img)
}

/// The wasm cell `jit_cell` selects: "test" is the bounded smoke cell;
/// "delegate"/"delegate-click" are the keydown/click listener re-entry cells
/// ([`delegate_key_cell`]/[`delegate_click_cell`]); "" or "auto" is the shipped
/// browser cell (LDC/libwasm when present, else MVP).
pub fn cell_bytes(spec: &g6b_spec::BoardSpec) -> Vec<u8> {
    match spec.kernel.wasm.jit_cell.as_str() {
        "test" => test_module(),
        "delegate" => delegate_key_cell(),
        "delegate-click" => delegate_click_cell(),
        _ => {
            let b = if g6b_asm::BIOS_UI_LIBWASM.starts_with(b"\0asm\x01") {
                g6b_asm::BIOS_UI_LIBWASM
            } else {
                g6b_asm::BIOS_UI_WASM
            };
            b.to_vec()
        }
    }
}

/// Bootable listener re-entry cell for a real input lane (`jit_cell="delegate"`
/// registers `keydown`, `"delegate-click"` registers `click`). `_start` gives the
/// root an id, sets `innerText="READY"` (so the initial `DomtRaster` paint is
/// non-empty — a bare element tree has no text and renders only the dark page
/// bg), and registers `add_event_listener("r",<ev>,$delegate)` **on the root**:
/// for `keydown` the root is the default `H_FOCUS` (node idx 0), so a queued key
/// dispatches to the funcidx listener with no `DomtFocus`; for `click` the root
/// is laid out to fill the display, so `DomtPtr`→`DomtHit` resolves any tablet
/// `ABS_X/ABS_Y`+`BTN_LEFT` press to it with no focus or aiming at a child rect.
/// `$delegate(ev)` appends a `<button>` whose `innerText="K"` — each input event
/// therefore adds one visible text row (`DomtText` sets `F_TEXT|F_DIRTY`, the
/// `trap_timer` raster draws the glyph), so successive events stack `K` rows and
/// the scanout grows measurably per re-entry. This is the QEMU counterpart of the
/// `test_module_delegate` exec cell.
///
/// ```wat
/// (import "env" "getRoot" (func $getRoot (result i32)))            ;; f0
/// (import "env" "createElement" (func $createEl (param i32) (result i32))) ;; f1
/// (import "env" "appendChild" (func $append (param i32 i32)))      ;; f2
/// (import "env" "setProperty" (func $setProp (param i32 x5)))      ;; f3
/// (import "env" "add_event_listener" (func $addLsn (param i32 x6)));; f4
/// (memory 1)
/// (func $delegate (param i32) (local i32)                         ;; f5
///   i32.const 14 call $createEl local.set 1         ;; el = <button>
///   local.get 1 i32.const 9 i32.const IT i32.const 1 i32.const KK call $setProp ;; el.innerText="K"
///   call $getRoot local.get 1 call $append)       ;; root.appendChild(el)
/// (func $_start (local i32)                                       ;; f6
///   call $getRoot local.set 0                       ;; root
///   local.get 0 i32.const 2 i32.const ID i32.const 1 i32.const R call $setProp ;; root.id="r"
///   local.get 0 i32.const 9 i32.const IT i32.const 5 i32.const RDY call $setProp ;; root.innerText="READY"
///   i32.const R i32.const 1 i32.const EV i32.const <evlen> i32.const 5 i32.const 0
///   call $addLsn)                                  ;; add_event_listener("r",<ev>,$delegate)
/// ```
fn delegate_cell(ev: &[u8]) -> Vec<u8> {
    // `__wasm_mem` pool (data @0x10): "id" "r" <ev> "innerText" "K" "READY"
    // packed contiguously; every offset must stay < 0x40 for the 1-byte
    // `i32.const` the bodies emit (keydown → 0x10..0x28, click → 0x10..0x26).
    let strings: [&[u8]; 6] = [b"id", b"r", ev, b"innerText", b"K", b"READY"];
    let mut o = [0u8; 6];
    let mut at = 0x10u8;
    for (i, s) in strings.iter().enumerate() {
        o[i] = at;
        at = at.wrapping_add(s.len() as u8);
    }
    assert!(at <= 0x40, "delegate pool must stay under the 1B-i32.const bound");
    let (id, r, evp, it, kk, rdy) = (o[0], o[1], o[2], o[3], o[4], o[5]);
    let evlen = ev.len() as u8;
    const ORD: u8 = 14; // libwasm NodeType::button
    const DELEGATE: u8 = 5; // $delegate func index (imports 0..=4 first)
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();

    // t0 ()->i32 · t1 (i32)->i32 · t2 (i32,i32)->() · t3 (i32x5)->()
    //        t4 (i32x6)->() · t5 (i32,i32)->() local· t6 ()->()
    let mut types = Vec::new();
    push_uleb(&mut types, 7);
    types.extend_from_slice(&[0x60, 0x00, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x02, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x05, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x06, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x00, 0x00]);
    section(&mut out, 1, &types);

    // imports: env.{getRoot,createElement,appendChild,setProperty,add_event_listener}
    let mut imps = Vec::new();
    push_uleb(&mut imps, 5);
    for (name, ty) in [
        ("getRoot", 0u8),
        ("createElement", 1),
        ("appendChild", 2),
        ("setProperty", 3),
        ("add_event_listener", 4),
    ] {
        put_name(&mut imps, "env");
        put_name(&mut imps, name);
        imps.push(0x00); // func
        imps.push(ty);
    }
    section(&mut out, 2, &imps);

    section(&mut out, 3, &[2, 0x05, 0x06]); // $delegate(t5)=5, $_start(t6)=6
    section(&mut out, 5, &[1, 0x00, 0x01]); // memory min 1 page

    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.extend_from_slice(&[0x02, 0x00]);
    put_name(&mut exports, "_start");
    exports.extend_from_slice(&[0x00, 0x06]);
    section(&mut out, 7, &exports);

    // $delegate(ev:i32)(local i32): el=<button>; el.innerText="K"; append to root.
    let mut bdel = vec![0x01, 0x01, 0x7f]; // 1 local group, count1, i32 (local1=el)
    bdel.extend_from_slice(&[
        0x41, ORD, 0x10, 0x01, 0x21, 0x01, // el = createElement(ORD); local.set 1
        0x20, 0x01, // local.get 1 (el)
        0x41, 0x09, 0x41, it, //   namelen=9 nameptr=it  ("innerText")
        0x41, 0x01, 0x41, kk, //   vallen=1  valptr=kk   ("K")
        0x10, 0x03, // setProperty(el,"innerText","K") — len-first ABI
        0x10, 0x00, 0x20, 0x01, 0x10, 0x02, // appendChild(getRoot(), el)
        0x0b,
    ]);
    // $_start(): local0 = root handle.
    let mut bst = vec![0x01, 0x01, 0x7f]; // 1 local group, count1, i32
    bst.extend_from_slice(&[
        0x10, 0x00, 0x21, 0x00, // root = getRoot(); local.set 0
        0x20, 0x00,             // local.get 0 (root)
        0x41, 0x02, 0x41, id,   //   namelen=2 nameptr=id  ("id")
        0x41, 0x01, 0x41, r,    //   vallen=1  valptr=r    ("r")
        0x10, 0x03,             // setProperty(root,"id","r") — len-first ABI
        0x20, 0x00,             // local.get 0 (root)
        0x41, 0x09, 0x41, it,   //   namelen=9 nameptr=it  ("innerText")
        0x41, 0x05, 0x41, rdy,  //   vallen=5  valptr=rdy  ("READY")
        0x10, 0x03,             // setProperty(root,"innerText","READY")
        0x41, r, 0x41, 0x01,    // tptr=r tlen=1           ("r")   ptr-first ABI
        0x41, evp, 0x41, evlen, // typtr=evp tylen=evlen  (<ev>)
        0x41, DELEGATE,         // cb = $delegate funcidx 5
        0x41, 0x00,             // capture = 0
        0x10, 0x04,             // add_event_listener("r",<ev>,5,0)
        0x0b,
    ]);
    let mut code = Vec::new();
    push_uleb(&mut code, 2);
    push_uleb(&mut code, bdel.len() as u32);
    code.extend_from_slice(&bdel);
    push_uleb(&mut code, bst.len() as u32);
    code.extend_from_slice(&bst);
    section(&mut out, 10, &code);

    // data @0x10: "id" "r" <ev> "innerText" "K" "READY" packed contiguously.
    let mut data = Vec::new();
    push_uleb(&mut data, 1);
    data.extend_from_slice(&[0x00, 0x41, 0x10, 0x0b]); // active mem0, off=i32.const 0x10
    let mut body = Vec::new();
    for s in strings {
        body.extend_from_slice(s);
    }
    push_uleb(&mut data, body.len() as u32);
    data.extend_from_slice(&body);
    section(&mut out, 11, &data);
    out
}

/// `jit_cell="delegate"` — the keydown-lane re-entry cell ([`delegate_cell`]).
pub fn delegate_key_cell() -> Vec<u8> {
    delegate_cell(b"keydown")
}

/// `jit_cell="delegate-click"` — the pointer-lane re-entry cell: a `click`
/// listener on the full-display root, so any tablet press re-enters `$delegate`.
pub fn delegate_click_cell() -> Vec<u8> {
    delegate_cell(b"click")
}

/// Cross-function-EH cell: a `throw`er callee whose exception escapes into the
/// caller `_start`'s `try`/`catch_all` — the caught handler yields 777 (0x309).
/// ```wat
/// (tag $e (type $void))
/// (func $thrower (type $void) throw $e)
/// (func $_start (type $ret) (result i32)
///   try (result i32)  call $thrower  i32.const 0  catch_all  i32.const 777  end)
/// ```
#[cfg(test)]
pub fn test_module_eh() -> Vec<u8> {
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 2);
    types.extend_from_slice(&[0x60, 0, 1, 0x7f]); // t0 ()->i32
    types.extend_from_slice(&[0x60, 0, 0]);        // t1 ()->()
    section(&mut out, 1, &types);
    section(&mut out, 3, &[2, 1, 0]); // f0=t1 thrower, f1=t0 _start
    section(&mut out, 5, &[1, 0x00, 0x01]); // memory 1 page
    section(&mut out, 13, &[1, 0x00, 1]);   // 1 tag, attr 0, typeidx 1 (()->())
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.push(0x02);
    push_uleb(&mut exports, 0);
    put_name(&mut exports, "_start");
    exports.push(0x00);
    push_uleb(&mut exports, 1);
    section(&mut out, 7, &exports);
    let b0 = [0x00, 0x08, 0x00, 0x0b]; // thrower: throw tag0; end
    let b1 = [
        0x00,               // locals=0
        0x06, 0x7f,         // try (result i32)
        0x10, 0x00,         //   call 0 (thrower)
        0x41, 0x00,         //   i32.const 0   (unreached)
        0x19,               // catch_all
        0x41, 0x89, 0x06,   //   i32.const 777
        0x0b,               // end try
        0x0b,               // end func
    ];
    let mut code = Vec::new();
    push_uleb(&mut code, 2);
    push_uleb(&mut code, b0.len() as u32);
    code.extend_from_slice(&b0);
    push_uleb(&mut code, b1.len() as u32);
    code.extend_from_slice(&b1);
    section(&mut out, 10, &code);
    out
}

/// Uncaught variant: `_start` itself `throw`s tag0 with no enclosing try — the
/// exception escapes the top frame and must surface as `WASM-JIT-TRAP` TRAP_EXC.
#[cfg(test)]
pub fn test_module_eh_uncaught() -> Vec<u8> {
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 1);
    types.extend_from_slice(&[0x60, 0, 1, 0x7f]); // t0 ()->i32
    section(&mut out, 1, &types);
    section(&mut out, 3, &[1, 0]); // f0=t0 _start
    section(&mut out, 5, &[1, 0x00, 0x01]);
    section(&mut out, 13, &[1, 0x00, 0]); // 1 tag, typeidx 0 (()->i32 — any sig ok)
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.push(0x02);
    push_uleb(&mut exports, 0);
    put_name(&mut exports, "_start");
    exports.push(0x00);
    push_uleb(&mut exports, 0);
    section(&mut out, 7, &exports);
    // _start: throw tag0; i32.const 0 (unreached); end
    let b0 = [0x00, 0x08, 0x00, 0x41, 0x00, 0x0b];
    let mut code = Vec::new();
    push_uleb(&mut code, 1);
    push_uleb(&mut code, b0.len() as u32);
    code.extend_from_slice(&b0);
    section(&mut out, 10, &code);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_module_encodes() {
        let img = encode(&test_module()).expect("test cell encodes");
        assert_eq!(&img[..4], &MAGIC.to_le_bytes());
        let (off, len) = data_offset(&img).unwrap();
        assert_eq!(len, 0, "test cell has no data segments");
        // The M3 trailer follows the data region: `meta_offset` = the data end
        // 8-aligned, carrying the call_indirect sig + funcref tables.
        let meta = g6b_asm::jfmt::meta_offset(&img).expect("m3 trailer");
        assert_eq!(meta, off);
        assert_eq!(
            &img[meta as usize..meta as usize + 4],
            &g6b_asm::jfmt::TMETA_MAGIC.to_le_bytes()
        );
    }

    #[test]
    fn test_module_lowers_loop() {
        let img = encode(&test_module()).expect("encode");
        let nfuncs = u32::from_le_bytes(img[4..8].try_into().unwrap());
        let nrecords = u32::from_le_bytes(img[24..28].try_into().unwrap()) as usize;
        assert_eq!(nfuncs, 2);
        // _start func hdr = index 1.
        let hoff = HDR_BYTES + FHDR_BYTES;
        let bc_off = u32::from_le_bytes(img[hoff..hoff + 4].try_into().unwrap()) as usize;
        let bc_len = u32::from_le_bytes(img[hoff + 4..hoff + 8].try_into().unwrap()) as usize;
        let rbase = HDR_BYTES + nfuncs as usize * FHDR_BYTES;
        let ops: Vec<u32> = (0..nrecords)
            .map(|i| {
                u32::from_le_bytes(img[rbase + i * 16..rbase + i * 16 + 4].try_into().unwrap())
            })
            .collect();
        // Backward branch must exist and point inside the loop.
        let jnz = ops.iter().position(|o| *o == R_JNZ).expect("loop br_if");
        let tgt = u32::from_le_bytes(
            img[rbase + jnz * 16 + 4..rbase + jnz * 16 + 8]
                .try_into()
                .unwrap(),
        ) as usize;
        assert!(tgt >= bc_off && tgt < bc_off + bc_len);
        assert!(tgt < jnz, "loop branch is backward");
        assert!(ops.contains(&R_CALL));
        assert!(ops.contains(&R_STORE));
    }

    /// M1: the guest JIT translates the bounded test cell into executable
    /// RISC-V in `__jit_code`, fences, enters it, and `_start` returns 30
    /// (loop sum 7..1 = 28 through add2's +2). Evidence markers go to UART.
    #[test]
    fn guest_jit_executes_test_cell() {
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},"wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"test"}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let mut m = g6b_asm::analyze::kstart(&spec);
        install_guest(&mut m, &cell_bytes(&spec)).expect("test cell installs");
        let s = g6b_asm::exec::run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(
            s.console.contains("WASM-JIT-F 0000000000000002"),
            "func count marker: {}",
            s.console
        );
        assert!(
            s.console.contains("WASM-JIT 000000000000001e"),
            "_start() == 30: {}",
            s.console
        );
        assert!(!s.console.contains("WASM-JIT-NOIMG"), "{}", s.console);
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
    }

    /// Build a 2-func module: func0 `$addH(i32)->i32` in table[0] (for
    /// call_indirect), `_start ()->i32` = `body`. Returns the guest result.
    fn run_m3_body(body: &[u8]) -> u64 {
        let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
        let mut types = Vec::new();
        push_uleb(&mut types, 2);
        types.extend_from_slice(&[0x60, 1, 0x7f, 1, 0x7f]);
        types.extend_from_slice(&[0x60, 0, 1, 0x7f]);
        section(&mut out, 1, &types);
        section(&mut out, 3, &[2, 0, 1]);
        section(&mut out, 4, &[1, 0x70, 0x00, 0x01]);
        section(&mut out, 5, &[1, 0x00, 0x01]);
        let mut exports = Vec::new();
        push_uleb(&mut exports, 2);
        put_name(&mut exports, "memory");
        exports.push(0x02);
        push_uleb(&mut exports, 0);
        put_name(&mut exports, "_start");
        exports.push(0x00);
        push_uleb(&mut exports, 1);
        section(&mut out, 7, &exports);
        section(&mut out, 9, &[1, 0x00, 0x41, 0x00, 0x0b, 0x01, 0x00]);
        let b0 = [0x00, 0x20, 0x00, 0x41, 0x0a, 0x6a, 0x0b]; // func0 = arg+10
        let mut b1 = vec![0x00];
        b1.extend_from_slice(body);
        b1.push(0x0b);
        let mut code = Vec::new();
        push_uleb(&mut code, 2);
        push_uleb(&mut code, b0.len() as u32);
        code.extend_from_slice(&b0);
        push_uleb(&mut code, b1.len() as u32);
        code.extend_from_slice(&b1);
        section(&mut out, 10, &code);

        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},"wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"test"}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let mut m = g6b_asm::analyze::kstart(&spec);
        install_guest(&mut m, &out).expect("cell installs");
        let s = g6b_asm::exec::run_module(&spec, &m, 0x8020_0000).unwrap();
        for line in s.console.lines() {
            if let Some(hex) = line.strip_prefix("WASM-JIT ") {
                return u64::from_str_radix(hex.trim(), 16).unwrap_or(u64::MAX);
            }
        }
        panic!("no WASM-JIT result: {}", s.console);
    }

    /// Cross-function unwind: a callee `throw` escapes its own frame and is
    /// caught by the caller `_start`'s `try`/`catch_all`, yielding 777 — no trap.
    #[test]
    fn guest_jit_cross_func_throw() {
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},"wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"test"}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let mut m = g6b_asm::analyze::kstart(&spec);
        install_guest(&mut m, &test_module_eh()).expect("eh cell installs");
        let s = g6b_asm::exec::run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(
            !s.console.contains("WASM-JIT-TRAP"),
            "throw escaped uncaught / {}",
            s.console
        );
        let mut got = None;
        for line in s.console.lines() {
            if let Some(hex) = line.strip_prefix("WASM-JIT ") {
                got = Some(u64::from_str_radix(hex.trim(), 16).unwrap_or(u64::MAX));
            }
        }
        assert_eq!(got, Some(0x309), "catch did not yield 777: {}", s.console);
    }

    /// Uncaught `throw` at the top frame → `WASM-JIT-TRAP` TRAP_EXC (11).
    #[test]
    fn guest_jit_uncaught_throw() {
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},"wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"test"}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let mut m = g6b_asm::analyze::kstart(&spec);
        install_guest(&mut m, &test_module_eh_uncaught()).expect("eh cell installs");
        let s = g6b_asm::exec::run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(
            s.console.contains("WASM-JIT-TRAP 000000000000000b"),
            "uncaught throw → TRAP_EXC(11): {}",
            s.console
        );
        assert!(!s.console.contains("TRAP-"), "machine fault: {}", s.console);
    }

    /// Host-side check: the M3 trailer carries sig[funcidx→typeidx] and the
    /// funcref table that call_indirect reads.
    #[test]
    fn m3_trailer_layout() {
        let img = encode(&test_module_m3()).expect("encode");
        let meta = g6b_asm::jfmt::meta_offset(&img).expect("trailer present");
        let m = &img[meta as usize..];
        let magic = u32::from_le_bytes(m[0..4].try_into().unwrap());
        assert_eq!(magic, g6b_asm::jfmt::TMETA_MAGIC);
        let ntable = u32::from_le_bytes(m[4..8].try_into().unwrap());
        assert_eq!(ntable, 1);
        let sig0 = u32::from_le_bytes(m[8..12].try_into().unwrap());
        let sig1 = u32::from_le_bytes(m[12..16].try_into().unwrap());
        assert_eq!((sig0, sig1), (0, 1), "func0:type0 func1:type1");
        let tbl = i64::from_le_bytes(m[16..24].try_into().unwrap());
        assert_eq!(tbl, 0, "tbl[0] = funcidx 0");
    }

    /// Bisect probe for the M3 ops — each asserts independently.
    #[test]
    fn m3_ops_bisect() {
        // call_indirect: func0(5) = 5+10 = 15
        assert_eq!(run_m3_body(&[0x41, 0x05, 0x41, 0x00, 0x11, 0x00, 0x00]), 15);
        // clz(8)=28, ctz(8)=3, popcnt(15)=4, extend8_s(255)=-1
        assert_eq!(run_m3_body(&[0x41, 0x08, 0x67]), 28);
        assert_eq!(run_m3_body(&[0x41, 0x08, 0x68]), 3);
        assert_eq!(run_m3_body(&[0x41, 0x0f, 0x69]), 4);
        assert_eq!(
            run_m3_body(&[0x41, 0xff, 0x01, 0xc0]),
            u64::MAX // -1 sign-extended to 64-bit
        );
        // br_table idx1 → default → i32.const 7
        assert_eq!(
            run_m3_body(&[
                0x02, 0x40, 0x02, 0x40, 0x41, 0x01, 0x0e, 0x01, 0x00, 0x01, 0x0b, 0x41, 0x3f, 0x0f,
                0x0b, 0x41, 0x07,
            ]),
            7
        );
        // memory.fill 0,63,4 then load8_u(0)=63
        assert_eq!(
            run_m3_body(&[
                0x41, 0x00, 0x41, 0x3f, 0x41, 0x04, 0xfc, 0x0b, 0x00, 0x41, 0x00, 0x2d, 0x00, 0x00,
            ]),
            63
        );
        // memory.copy 8<-0,4 then load8_u(8)=63
        assert_eq!(
            run_m3_body(&[
                0x41, 0x00, 0x41, 0x3f, 0x41, 0x04, 0xfc, 0x0b, 0x00, 0x41, 0x08, 0x41, 0x00, 0x41,
                0x04, 0xfc, 0x0a, 0x00, 0x00, 0x41, 0x08, 0x2d, 0x00, 0x00,
            ]),
            63
        );
    }

    /// M3b: the guest-JIT FPU. Each body leaves an i32 on the stack (via a
    /// compare or a trunc), exercising f32 arith/cmp/cvt/abs/neg/load/store.
    #[test]
    fn m3_fp_bisect() {
        // f32.add(1.5,2.5)=4.0 ; f32.eq(4.0)=1
        assert_eq!(
            run_m3_body(&[
                0x43, 0x00, 0x00, 0xc0, 0x3f, 0x43, 0x00, 0x00, 0x20, 0x40, 0x92, 0x43, 0x00, 0x00,
                0x80, 0x40, 0x5b,
            ]),
            1
        );
        // f32.gt(3,2)=1 ; f32.lt(3,2)=0
        assert_eq!(
            run_m3_body(&[0x43, 0x00, 0x00, 0x40, 0x40, 0x43, 0x00, 0x00, 0x00, 0x40, 0x5e]),
            1
        );
        assert_eq!(
            run_m3_body(&[0x43, 0x00, 0x00, 0x40, 0x40, 0x43, 0x00, 0x00, 0x00, 0x40, 0x5d]),
            0
        );
        // f32.div(9,3)=3 → trunc_s 3 ; f32.mul(2.5,4)=10 → 10 ; sub(5,1.5)=3.5→3
        assert_eq!(
            run_m3_body(&[0x43, 0x00, 0x00, 0x10, 0x41, 0x43, 0x00, 0x00, 0x40, 0x40, 0x95, 0xa8,]),
            3
        );
        assert_eq!(
            run_m3_body(&[0x43, 0x00, 0x00, 0x20, 0x40, 0x43, 0x00, 0x00, 0x80, 0x40, 0x94, 0xa8,]),
            10
        );
        assert_eq!(
            run_m3_body(&[0x43, 0x00, 0x00, 0xa0, 0x40, 0x43, 0x00, 0x00, 0xc0, 0x3f, 0x93, 0xa8,]),
            3
        );
        // f32.convert_i32_u(7)=7.0 → trunc_u 7
        assert_eq!(run_m3_body(&[0x41, 0x07, 0xb3, 0xa9]), 7);
        // f32.abs(-2.5)=2.5 → 2 ; f32.neg(2.5)=-2.5 → trunc_s -2
        assert_eq!(run_m3_body(&[0x43, 0x00, 0x00, 0x20, 0xc0, 0x8b, 0xa9]), 2);
        assert_eq!(
            run_m3_body(&[0x43, 0x00, 0x00, 0x20, 0x40, 0x8c, 0xa8]),
            (-2i64) as u64
        );
        // f32 store/load round-trip through memory: store 4.5, load, trunc → 4
        assert_eq!(
            run_m3_body(&[
                0x41, 0x00, 0x43, 0x00, 0x00, 0x90, 0x40, 0x38, 0x02, 0x00, 0x41, 0x00, 0x2a, 0x02,
                0x00, 0xa8,
            ]),
            4
        );
    }

    /// Profile the shipped libwasm cell: does it encode within the raised
    /// bounds, and how many records (and residual TRAPs) does it carry?
    #[test]
    fn shipped_cell_profile() {
        let cell = g6b_asm::BIOS_UI_LIBWASM;
        if !cell.starts_with(b"\0asm\x01") {
            eprintln!("libwasm cell not built — skipping");
            return;
        }
        // Dump the import table and which map to a known EXT_ trampoline.
        if let Ok(m) = decode(cell) {
            eprintln!("imports ({}):", m.imports.len());
            for (i, imp) in m.imports.iter().enumerate() {
                let mapped = ext_id(&imp.module, &imp.name)
                    .map(|e| format!("EXT#{e}"))
                    .unwrap_or_else(|| "UNMAPPED".into());
                let ty = &m.types[imp.typeidx as usize];
                eprintln!(
                    "  [{}] {}::{}{:?}->{:?} -> {}",
                    i, imp.module, imp.name, ty.params, ty.results, mapped
                );
            }
        }
        match encode(cell) {
            Ok(img) => {
                let nfuncs = u32::from_le_bytes(img[4..8].try_into().unwrap());
                let nrecords = u32::from_le_bytes(img[24..28].try_into().unwrap()) as usize;
                let rbase = HDR_BYTES + nfuncs as usize * FHDR_BYTES;
                let mut traps = 0usize;
                let mut trap_kinds: std::collections::BTreeMap<u32, usize> =
                    std::collections::BTreeMap::new();
                let mut ext_calls: std::collections::BTreeMap<u32, usize> =
                    std::collections::BTreeMap::new();
                for i in 0..nrecords {
                    let op = u32::from_le_bytes(
                        img[rbase + i * 16..rbase + i * 16 + 4].try_into().unwrap(),
                    );
                    if op == R_EXT {
                        let e = u32::from_le_bytes(
                            img[rbase + i * 16 + 4..rbase + i * 16 + 8]
                                .try_into()
                                .unwrap(),
                        );
                        *ext_calls.entry(e).or_default() += 1;
                    }
                    if op == R_TRAP {
                        traps += 1;
                        let code = u32::from_le_bytes(
                            img[rbase + i * 16 + 4..rbase + i * 16 + 8]
                                .try_into()
                                .unwrap(),
                        );
                        let aux = u64::from_le_bytes(
                            img[rbase + i * 16 + 8..rbase + i * 16 + 16]
                                .try_into()
                                .unwrap(),
                        );
                        *trap_kinds.entry(code).or_default() += 1;
                        if code == TRAP_UNSUP {
                            eprintln!("  UNSUP aux=0x{aux:x} @rec{i}");
                        }
                    }
                }
                eprintln!(
                    "cell: funcs={} records={} traps={} kinds={:?} ext={:?} img={}B",
                    nfuncs,
                    nrecords,
                    traps,
                    trap_kinds,
                    ext_calls,
                    img.len()
                );
            }
            Err(e) => eprintln!("cell encode FAILED: {e}"),
        }
    }

    /// M3a: the guest JIT lowers+runs call_indirect (table), br_table, clz,
    /// ctz, popcnt, extend8_s, memory.fill and memory.copy. `_start` == 182.
    #[test]
    fn guest_jit_executes_m3_cell() {
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},"wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"test"}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let mut m = g6b_asm::analyze::kstart(&spec);
        install_guest(&mut m, &test_module_m3()).expect("m3 cell installs");
        let s = g6b_asm::exec::run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(
            s.console.contains("WASM-JIT 00000000000000b6"),
            "_start() == 182: {}",
            s.console
        );
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
    }

    /// M3d gate: the shipped ~204KB LDC/libwasm cell translates and runs
    /// `_start` in the guest JIT — every `env.*` import lowers to a real
    /// `Lw*`/`Domt*`/`Wasm*` routine (no `TRAP_EXT`), so `_start` builds the
    /// `__dom` tree it then paints into `__scan_fb` via `DomtRaster`. This is
    /// the full-cell execution gate: translation completes (252 funcs),
    /// `_start` returns (the `WASM-JIT` result marker), the run is fault-free,
    /// and the DOM the cell built produces real pixels — not the `DomtBoot`
    /// demo fallback (`DomtBoot` is idempotent and skips once the cell has
    /// appended a child under root, so the demo `0x1e3a5a` signature stays
    /// absent).
    /// Stage-3 preflight gate: `op_coverage` walks the shipped cell's reachable
    /// set and reports every blocking trap. The contract is now *strict*: with
    /// cross-function wasm-EH lowered (`R_THROW` unwinds to a caller `catch`,
    /// `R_EXCCHK` after each call, `R_EXCCLR` at each handler head), every
    /// reachable op lowers — including the cold `throw`-to-caller lane. Any gap
    /// — an unlowered opcode (`TRAP_UNSUP` with a real op), an unmapped `env`
    /// import (`TRAP_EXT`), or an out-of-range call (`TRAP_BADFUNC`) in
    /// reachable code — fails this test loudly, which is the point of the gate.
    #[test]
    fn shipped_cell_op_coverage_report() {
        let wasm = g6b_asm::BIOS_UI_LIBWASM;
        if !wasm.starts_with(b"\0asm\x01") {
            return; // cell not built on this host
        }
        let cov = op_coverage(wasm).expect("op_coverage decodes+lowers");
        for g in &cov.gaps {
            eprintln!("  GAP {}", g.describe());
        }
        assert!(
            cov.reachable > 0,
            "op_coverage found no reachable funcs ({} funcs)",
            cov.funcs
        );
        // Strict: the whole reachable set lowers with no trapping gap. The
        // cross-function `throw` lane is now implemented (`guest_jit_cross_
        // func_throw` exercises callee-throw → caller-catch end to end), so
        // `clean()` must hold — a regression here is a real reachable gap.
        assert!(
            cov.clean(),
            "reachable coverage gap(s): {:?}",
            cov.gaps.iter().map(OpGap::describe).collect::<Vec<_>>()
        );
    }

    #[test]
    fn guest_jit_executes_shipped_cell() {
        let wasm = g6b_asm::BIOS_UI_LIBWASM;
        if !wasm.starts_with(b"\0asm\x01") {
            return; // cell not built on this host
        }
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},
 "gr":{"enable":true,"w":640,"h":480,"colors":32,"backend":"virtio-gpu"},
 "wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"auto"}},
"uncore":{"clint":true,"plic":true},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let mut m = g6b_asm::analyze::kstart(&spec);
        install_guest(&mut m, wasm).expect("shipped cell installs");
        // The cell's `libwasm_await_supported` lane is live, so it issues real
        // `fetch("/bios/menu/<id>")`/`/bios/store` calls. Bake the same
        // `{url→body}` table the ELF payload carries (`kget_pack`) so the
        // guest `KernelGet` resolves each to the `items[]` row JSON.
        m.kget = g6b_asm::kget::build(&[
            ("/bios/menu/main".into(), "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into()),
            ("/bios/menu/cpu".into(), "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into()),
            ("/bios/menu/memory".into(), "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into()),
            ("/bios/menu/uncore".into(), "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into()),
            ("/bios/menu/devices".into(), "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into()),
            ("/bios/menu/boot".into(), "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into()),
            ("/bios/menu/settings".into(), "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into()),
            ("/bios/store".into(), "[]".into()),
        ]).unwrap();
        let s = g6b_asm::exec::run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(
            s.console.contains("WASM-JIT-F 00000000000000fc"),
            "252 funcs translated: {}",
            s.console
        );
        // _start returns → the WASM-JIT result marker; no translation/EXT trap.
        assert!(
            s.console.contains("WASM-JIT "),
            "_start completed: {}",
            s.console
        );
        assert!(
            !s.console.contains("WASM-JIT-TRAP"),
            "no jit trap: {}",
            s.console
        );
        assert!(!s.console.contains("TRAP-"), "no guest trap: {}", s.console);
        assert_eq!(s.faults, 0, "fault-free run: {}", s.console);
        // The cell built a real DOM → DomtRaster painted it into __scan_fb.
        // `demo` is the DomtBoot fallback signature — 0 proves the cell (not
        // the demo) populated the tree.
        let live = s
            .scan_fb
            .chunks_exact(4)
            .filter(|p| **p != [0, 0, 0, 0])
            .count();
        let demo = s
            .scan_fb
            .chunks_exact(4)
            .filter(|p| **p == 0x001e_3a5au32.to_le_bytes())
            .count();
        assert!(live > 0, "cell DOM painted into __scan_fb: {}", s.console);
        assert_eq!(demo, 0, "DomtBoot demo stayed unseeded: {}", s.console);
        eprintln!(
            "domt: next={} live={} listen={} ids={}",
            s.domt_next, s.domt_live, s.domt_listen, s.domt_ids
        );
        // The cell built more than the lone root: getRoot→createElement→
        // appendChild→setProperty all ran through the handle-ABI bridge.
        assert!(s.domt_next > 1, "cell allocated DOM nodes: {}", s.domt_next);
        assert_eq!(
            s.domt_live, s.domt_next,
            "every allocated node is live (none tombstoned/free)"
        );
        // `setProperty(el,"id",..)` populated `__dom_id` (used by
        // `add_event_listener` target resolution).
        assert!(s.domt_ids > 0, "cell set element ids: {}", s.domt_ids);
        // `add_event_listener("tab-*"/"refresh","click")` resolved each id to a
        // node and set its `N_LEV` mask — the source wires exactly 8 listeners
        // (7 nav tabs + refresh) during the initial render.
        assert_eq!(
            s.domt_listen, 8,
            "add_event_listener id→node registered the 8 wired listeners"
        );
        for (i, tag, par, x, y, w, h, tlen, text) in &s.domt_nodes {
            eprintln!(
                "  node {i:3} tag={tag:3} par={par:3} rect=({x},{y},{w}x{h}) tlen={tlen} '{text}'"
            );
        }
    }

    // ---- Stage 3a/3b: JitCall re-entrant invoke ------------------------------
    use g6b_asm::encode::{A0, A1, A2, A6, A7, RA, S0, S1, S2, SBI_PUTCHAR, T0, T2, X0};
    use g6b_asm::jfmt::{AX_GET_STATE, AX_START_UNWIND};
    use g6b_asm::{Addr, Op};

    fn put_str_ops(s: &str) -> Vec<Op> {
        s.bytes()
            .flat_map(|b| {
                [
                    Op::Li {
                        rd: A0,
                        imm: i64::from(b),
                    },
                    Op::Li {
                        rd: A7,
                        imm: SBI_PUTCHAR,
                    },
                    Op::Ecall,
                ]
            })
            .collect()
    }

    /// Print `T0` as 16 hex digits via the shared `hexdig` table.
    fn hex_t0_ops(lbl: &str) -> Vec<Op> {
        vec![
            Op::Li { rd: A2, imm: 16 },
            Op::Label(lbl.into()),
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
                to: lbl.into(),
            },
        ]
    }

    /// `JitCall` re-enters a translated cell function: after `_start`, the probe
    /// resolves `asyncify_get_state`'s funcidx through `JitAx`, invokes it (0 →
    /// NORMAL), then `asyncify_start_unwind` + a second `get_state` round-trip
    /// proves args pass and the asyncify global mutates (1 → UNWINDING). This is
    /// the substrate input listeners and the await rewind are built on.
    #[test]
    fn guest_jit_jitcall_reenters_cell_fn() {
        let wasm = g6b_asm::BIOS_UI_LIBWASM;
        if !wasm.starts_with(b"\0asm\x01") {
            return; // cell not built on this host
        }
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},
 "gr":{"enable":true,"w":640,"h":480,"colors":32,"backend":"virtio-gpu"},
 "wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"auto"}},
"uncore":{"clint":true,"plic":true},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let mut m = g6b_asm::analyze::kstart(&spec);
        install_guest(&mut m, wasm).expect("shipped cell installs");
        m.kget = g6b_asm::kget::build(&[
            ("/bios/menu/main".into(), "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into()),
            ("/bios/menu/cpu".into(), "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into()),
            ("/bios/menu/memory".into(), "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into()),
            ("/bios/menu/uncore".into(), "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into()),
            ("/bios/menu/devices".into(), "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into()),
            ("/bios/menu/boot".into(), "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into()),
            ("/bios/menu/settings".into(), "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into()),
            ("/bios/store".into(), "[]".into()),
        ]).unwrap();

        // Probe spliced after `jal JitRun`: JitAx + JitCall round-trip.
        let mut probe = vec![
            // s0 = JitAx(AX_GET_STATE)
            Op::Li {
                rd: A0,
                imm: i64::from(AX_GET_STATE),
            },
            Op::Jal {
                rd: RA,
                to: "JitAx".into(),
            },
            Op::Addi {
                rd: S0,
                rs: A0,
                imm: 0,
            },
            Op::Addi {
                rd: T0,
                rs: S0,
                imm: 0,
            },
        ];
        probe.extend(put_str_ops("AXS"));
        probe.extend(hex_t0_ops("jc_hex0"));
        probe.extend([
            // s1 = JitCall(s0, 0)  → asyncify_get_state() == 0
            Op::Addi {
                rd: A0,
                rs: S0,
                imm: 0,
            },
            Op::Addi {
                rd: A1,
                rs: X0,
                imm: 0,
            },
            Op::Jal {
                rd: RA,
                to: "JitCall".into(),
            },
            Op::Addi {
                rd: S1,
                rs: A0,
                imm: 0,
            },
            Op::Addi {
                rd: T0,
                rs: S1,
                imm: 0,
            },
        ]);
        probe.extend(put_str_ops(" GS"));
        probe.extend(hex_t0_ops("jc_hex1"));
        probe.extend([
            // s2 = JitAx(AX_START_UNWIND); JitCall(s2, 1, scratch)
            Op::Li {
                rd: A0,
                imm: i64::from(AX_START_UNWIND),
            },
            Op::Jal {
                rd: RA,
                to: "JitAx".into(),
            },
            Op::Addi {
                rd: S2,
                rs: A0,
                imm: 0,
            },
            Op::Addi {
                rd: T0,
                rs: S2,
                imm: 0,
            },
        ]);
        probe.extend(put_str_ops(" UW"));
        probe.extend(hex_t0_ops("jc_hex2"));
        probe.extend([
            Op::Addi {
                rd: A0,
                rs: S2,
                imm: 0,
            },
            Op::Addi {
                rd: A1,
                rs: X0,
                imm: 1,
            },
            Op::Li {
                rd: A2,
                imm: 0x10ff00, // asyncify data buf — scratch in the free heap
            },
            Op::Jal {
                rd: RA,
                to: "JitCall".into(),
            },
            // re-read state: JitCall(s0, 0) == UNWINDING(1)
            Op::Addi {
                rd: A0,
                rs: S0,
                imm: 0,
            },
            Op::Addi {
                rd: A1,
                rs: X0,
                imm: 0,
            },
            Op::Jal {
                rd: RA,
                to: "JitCall".into(),
            },
            Op::Addi {
                rd: S1,
                rs: A0,
                imm: 0,
            },
            Op::Addi {
                rd: T0,
                rs: S1,
                imm: 0,
            },
        ]);
        probe.extend(put_str_ops(" RS"));
        probe.extend(hex_t0_ops("jc_hex3"));
        probe.extend(put_str_ops("\n"));

        // splice the probe immediately after `jal JitRun`
        let mut placed = false;
        for n in &mut m.nodes {
            if let Some(pos) = n
                .ops
                .iter()
                .position(|o| matches!(o, Op::Jal { to, .. } if to == "JitRun"))
            {
                n.ops.splice(pos + 1..pos + 1, probe);
                placed = true;
                break;
            }
        }
        assert!(placed, "no JitRun call site to splice after");

        let s = g6b_asm::exec::run_module(&spec, &m, 0x8020_0000).unwrap();
        eprintln!("{}", s.console);
        assert!(!s.console.contains("WASM-JIT-TRAP"), "{}", s.console);
        assert_eq!(s.faults, 0, "fault-free: {}", s.console);
        // asyncify_get_state funcidx resolved (251), then 0 → NORMAL, then the
        // start_unwind+get_state round-trip → 1 → UNWINDING.
        assert!(s.console.contains("AXS00000000000000fb"), "{}", s.console);
        assert!(s.console.contains("GS0000000000000000"), "{}", s.console);
        assert!(s.console.contains("UW00000000000000f7"), "{}", s.console);
        assert!(s.console.contains("RS0000000000000001"), "{}", s.console);
    }

    /// Listener re-entry on a real input event. The delegate cell's `_start`
    /// registers `add_event_listener("x","keydown",$delegate)` — `cb` is a real
    /// funcidx, which `LwAddLsn` biases into the reserved `N_LISTEN >= 0x100`
    /// band. A queued `INP_KQ` keydown dispatched through `DomtKey` sees that
    /// band on the focused node, populates `__ev_obj`, and re-enters the cell
    /// via `JitCall($delegate, [ev])`. `$delegate` `appendChild`s a node, so a
    /// key press provably grew `__dom` (the re-entry mutation).
    #[test]
    fn guest_jit_listener_reenters_cell_on_key() {
        use g6b_asm::encode::{A0, RA, T0, T1, X0};
        use g6b_asm::vio::{DOMT_SEEN_OFF, INP_KQ_HEAD, INP_KQ_OFF, VIO_KEY_ENTER};
        use g6b_asm::{Addr, Op};

        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},
 "gr":{"enable":true,"w":640,"h":480,"colors":16,"backend":"virtio-gpu"},
 "wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"test"}},
"uncore":{"clint":true,"plic":true},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let mut m = g6b_asm::analyze::kstart(&spec);
        install_guest(&mut m, &test_module_delegate()).expect("delegate cell installs");
        // `_start` built root + `<button id="x">` (__dom idx 0,1) and put a
        // keydown listener on idx1. Focus idx1 (the BIOS owns focus; a real
        // pointer hit-test would set it) and queue a KEY_ENTER press, drained
        // through `DomtKey` — spliced *after* `jal JitRun` so `_start` has run
        // and the listener is registered. The later canned burst keys then
        // re-enter the cell through the real `trap_inp` → `DomtKey` path too.
        let mut placed = false;
        for n in &mut m.nodes {
            if let Some(pos) = n
                .ops
                .iter()
                .position(|o| matches!(o, Op::Jal { to, .. } if to == "JitRun"))
            {
                let ops = vec![
                    Op::Li { rd: A0, imm: 1 },
                    Op::Jal { rd: RA, to: "DomtFocus".into() },
                    Op::La { rd: T0, addr: Addr::VioBss },
                    Op::Li { rd: T1, imm: (VIO_KEY_ENTER << 8) | 1 },
                    Op::Sw { rs2: T1, rs1: T0, off: INP_KQ_OFF },
                    Op::Li { rd: T1, imm: 1 },
                    Op::Sw { rs2: T1, rs1: T0, off: INP_KQ_HEAD },
                    Op::Sw { rs2: X0, rs1: T0, off: DOMT_SEEN_OFF },
                    Op::Jal { rd: RA, to: "DomtKey".into() },
                ];
                n.ops.splice(pos + 1..pos + 1, ops);
                placed = true;
                break;
            }
        }
        assert!(placed, "no JitRun call site to splice after");
        let s = g6b_asm::exec::run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
        assert!(!s.console.contains("WASM-JIT-TRAP"), "{}", s.console);
        assert_eq!(s.faults, 0, "fault-free: {}", s.console);
        // `add_event_listener` ran: the button carries an id and an event mask.
        assert!(s.domt_ids >= 1, "button id interned: {}", s.console);
        assert!(s.domt_listen >= 1, "button keydown listener: {}", s.console);
        // Re-entry: the delegate appended a node, so `__dom` grew past the
        // initial root+button (the canned burst keys each re-enter too).
        assert!(
            s.domt_live >= 3,
            "JitCall→delegate appended a node (live={}): {}",
            s.domt_live,
            s.console
        );
    }

    /// The bootable `delegate_key_cell` (`jit_cell="delegate"`) registers its
    /// `keydown` listener on the **root** — the default `H_FOCUS` (idx 0) — so a
    /// queued key press dispatches via `DomtKey`→`JitCall` with no `DomtFocus`
    /// call. This is exactly what a real virtio-keyboard press drives on QEMU.
    #[test]
    fn guest_jit_delegate_cell_key_reenters_root() {
        use g6b_asm::encode::{RA, T0, T1, X0};
        use g6b_asm::vio::{DOMT_SEEN_OFF, INP_KQ_HEAD, INP_KQ_OFF, VIO_KEY_ENTER};
        use g6b_asm::{Addr, Op};

        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},
 "gr":{"enable":true,"w":640,"h":480,"colors":16,"backend":"virtio-gpu"},
 "wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"delegate"}},
"uncore":{"clint":true,"plic":true},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        // `cell_bytes` selects the delegate cell for "delegate".
        assert_eq!(cell_bytes(&spec), delegate_key_cell());
        let mut m = g6b_asm::analyze::kstart(&spec);
        install_guest(&mut m, &delegate_key_cell()).expect("delegate cell installs");
        // `_start` set root.id="r", appended a `<button>`, and put a keydown
        // funcidx listener on the root (default H_FOCUS). Queue a KEY_ENTER
        // press and drain it through `DomtKey` — *no* `DomtFocus`, relying on
        // the root being the focused node — spliced after `jal JitRun`.
        let mut placed = false;
        for n in &mut m.nodes {
            if let Some(pos) = n
                .ops
                .iter()
                .position(|o| matches!(o, Op::Jal { to, .. } if to == "JitRun"))
            {
                let ops = vec![
                    Op::La { rd: T0, addr: Addr::VioBss },
                    Op::Li { rd: T1, imm: (VIO_KEY_ENTER << 8) | 1 },
                    Op::Sw { rs2: T1, rs1: T0, off: INP_KQ_OFF },
                    Op::Li { rd: T1, imm: 1 },
                    Op::Sw { rs2: T1, rs1: T0, off: INP_KQ_HEAD },
                    Op::Sw { rs2: X0, rs1: T0, off: DOMT_SEEN_OFF },
                    Op::Jal { rd: RA, to: "DomtKey".into() },
                ];
                n.ops.splice(pos + 1..pos + 1, ops);
                placed = true;
                break;
            }
        }
        assert!(placed, "no JitRun call site to splice after");
        let s = g6b_asm::exec::run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
        assert!(!s.console.contains("WASM-JIT-TRAP"), "{}", s.console);
        assert_eq!(s.faults, 0, "fault-free: {}", s.console);
        // `add_event_listener` ran on the root (id interned + event mask set).
        assert!(s.domt_ids >= 1, "root id interned: {}", s.console);
        assert!(s.domt_listen >= 1, "root keydown listener: {}", s.console);
        // Re-entry: the delegate `setProperty(root,"innerText","KEYHIT")` set the
        // root's text *and* appended a node, so `__dom` grew past the initial
        // root+button (the canned burst keys each re-enter too).
        assert!(
            s.domt_live >= 3,
            "root-focused keydown JitCall→delegate appended a node (live={}): {}",
            s.domt_live,
            s.console
        );
    }

    /// The pointer-lane counterpart of `guest_jit_delegate_cell_key_reenters_root`:
    /// `jit_cell="delegate-click"` registers `add_event_listener("r","click",_)`
    /// on the root, which `DomtLayout` lays out to the full display — so *any*
    /// tablet `ABS_X`/`ABS_Y`+`BTN_LEFT` press `DomtHit`s it with no aiming at a
    /// child rect. A canned `host_inp_tab_kick` poke at the screen centre runs the
    /// real `trap_tab`→`TabDrain`→`DomtPtr`→`JitCall` path; `$delegate` appends a
    /// node, so `__dom` grows past the initial root.
    #[test]
    fn guest_jit_delegate_cell_click_reenters_root() {
        use g6b_asm::encode::RA;
        use g6b_asm::exec::{run_module_web_feed, GuestWebPresent, WebFeed};
        use g6b_asm::Op;

        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},
 "gr":{"enable":true,"w":640,"h":480,"colors":16,"backend":"virtio-gpu"},
 "wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"delegate-click"}},
"uncore":{"clint":true,"plic":true},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        // `cell_bytes` selects the click-delegate cell for "delegate-click".
        assert_eq!(cell_bytes(&spec), delegate_click_cell());
        let mut m = g6b_asm::analyze::kstart(&spec);
        install_guest(&mut m, &delegate_click_cell()).expect("delegate-click cell installs");
        // Lay out `__dom` right after `JitRun` so the root has its full-display
        // rect before the first tablet IRQ (the timer tick would lay it out
        // eventually — the splice makes the ordering deterministic).
        let mut placed = false;
        for n in &mut m.nodes {
            if let Some(pos) = n
                .ops
                .iter()
                .position(|o| matches!(o, Op::Jal { to, .. } if to == "JitRun"))
            {
                n.ops
                    .splice(pos + 1..pos + 1, vec![Op::Jal { rd: RA, to: "DomtLayout".into() }]);
                placed = true;
                break;
            }
        }
        assert!(placed, "no JitRun call site to splice after");

        // A single tablet poke at the display centre — the root covers the whole
        // extent, so `DomtHit` resolves it without reading a child rect first.
        struct CenterClick;
        impl WebFeed for CenterClick {
            fn initial(&mut self) -> Option<GuestWebPresent> {
                None
            }
            fn on_guest_ui(&mut self) -> Option<GuestWebPresent> {
                None
            }
            fn hint_abs(&self) -> Option<(u32, u32)> {
                Some((0x4000, 0x4000)) // ~centre of the 0..=0x7fff tablet extent
            }
        }
        let mut feed = CenterClick;
        let s = run_module_web_feed(&spec, &m, 0x8020_0000, 0, &mut feed).unwrap();
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
        assert!(!s.console.contains("WASM-JIT-TRAP"), "{}", s.console);
        assert_eq!(s.faults, 0, "fault-free: {}", s.console);
        assert!(s.domt_ids >= 1, "root id interned: {}", s.console);
        assert!(s.domt_listen >= 1, "root click listener: {}", s.console);
        // Re-entry: the click `DomtHit` the root and `$delegate` appended a node,
        // so `__dom` grew past the initial root.
        assert!(
            s.domt_live >= 2,
            "tablet click→JitCall→delegate appended a node (live={}): {}",
            s.domt_live,
            s.console
        );
    }

    /// Listener re-entry on a real *pointer* event — the `DomtPtr`/`EV_CLICK`
    /// lane. The delegate cell registers `add_event_listener("x","click",_)`.
    /// A probe run lays out `__dom` and reads the `<button>`'s rect; the real
    /// run then feeds the canned tablet `ABS_X`/`ABS_Y`/`BTN_LEFT` poke at the
    /// button's centre (`WebFeed::hint_abs`), so a *real* `trap_tab` →
    /// `TabDrain` latches `PTR_CLICK`, `DomtPtr` scales ABS→display-px,
    /// `DomtHit`s the button and `JitCall`s `$delegate` — which `appendChild`s.
    /// `__dom` growth proves the pointer press re-entered the cell.
    #[test]
    fn guest_jit_listener_reenters_cell_on_click() {
        use g6b_asm::encode::RA;
        use g6b_asm::exec::{run_module, run_module_web_feed, GuestWebPresent, WebFeed};
        use g6b_asm::Op;

        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},
 "gr":{"enable":true,"w":640,"h":480,"colors":16,"backend":"virtio-gpu"},
 "wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"test"}},
"uncore":{"clint":true,"plic":true},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();

        // Splice `jal DomtLayout` right after `jal JitRun` so the button has a
        // laid-out rect before the first tablet IRQ can arrive (the timer tick
        // would lay it out eventually, but the canned poke lands on the first
        // guest Halt — the splice makes the ordering deterministic).
        let build = |m: &mut g6b_asm::Module| {
            install_guest(m, &test_module_delegate_ev(b"click"))
                .expect("click-delegate cell installs");
            let mut placed = false;
            for n in &mut m.nodes {
                if let Some(pos) = n
                    .ops
                    .iter()
                    .position(|o| matches!(o, Op::Jal { to, .. } if to == "JitRun"))
                {
                    n.ops
                        .splice(pos + 1..pos + 1, vec![Op::Jal { rd: RA, to: "DomtLayout".into() }]);
                    placed = true;
                    break;
                }
            }
            assert!(placed, "no JitRun call site to splice after");
        };

        // Phase 1 — probe: lay out `__dom` and read the `<button>`'s display-px
        // rect (the non-root node, `parent == 0`). The stray (0,0) canned poke
        // misses it, so `__dom` stays root+button.
        let mut probe = g6b_asm::analyze::kstart(&spec);
        build(&mut probe);
        let sp = run_module(&spec, &probe, 0x8020_0000).unwrap();
        assert!(!sp.console.contains("TRAP-"), "{}", sp.console);
        let btn = sp
            .domt_nodes
            .iter()
            .find(|n| n.0 != 0)
            .expect("a non-root button node is laid out");
        let (bx, by, bw, bh) = (btn.3, btn.4, btn.5, btn.6);
        assert!(bw > 0 && bh > 0, "button has a laid-out rect: {:?}", btn);
        // Button centre in display px → tablet units (`0..=0x7fff` over the
        // `DISP_SEL` extent). `DomtPtr` scales `abs * disp >> 15`, so invert it.
        let (dw, dh) = (640u32, 480u32);
        let abs_x = (bx + bw / 2) * 0x8000 / dw;
        let abs_y = (by + bh / 2) * 0x8000 / dh;

        // Phase 2 — real click: the canned tablet poke delivers the ABS pair +
        // BTN_LEFT press at the button's centre through `trap_tab`.
        struct ClickFeed {
            x: u32,
            y: u32,
        }
        impl WebFeed for ClickFeed {
            fn initial(&mut self) -> Option<GuestWebPresent> {
                None
            }
            fn on_guest_ui(&mut self) -> Option<GuestWebPresent> {
                None
            }
            fn hint_abs(&self) -> Option<(u32, u32)> {
                Some((self.x, self.y))
            }
        }
        let mut feed = ClickFeed { x: abs_x, y: abs_y };
        let mut m = g6b_asm::analyze::kstart(&spec);
        build(&mut m);
        let s = run_module_web_feed(&spec, &m, 0x8020_0000, 0, &mut feed).unwrap();
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
        assert!(!s.console.contains("WASM-JIT-TRAP"), "{}", s.console);
        assert_eq!(s.faults, 0, "fault-free: {}", s.console);
        assert!(s.domt_listen >= 1, "button click listener: {}", s.console);
        // Re-entry: the click hit the button and `$delegate` appended a node,
        // so `__dom` grew past the initial root+button.
        assert!(
            s.domt_live >= 3,
            "tablet click→JitCall→delegate appended a node (live={}): {}",
            s.domt_live,
            s.console
        );
    }

    /// The `__ev_obj` event-property bridge. The evget delegate reads
    /// `clientX`/`target` through `Object_Getter__*` (`LwEvGet`), calls
    /// `preventDefault` (`Object_Call___void` → `LwEvCall`), and reads back
    /// `defaultPrevented` — appending a node iff all three returned correct
    /// values. A real tablet `BTN_LEFT` press fills `__ev_obj` and re-enters
    /// the delegate; `__dom` growth proves the property bridge worked.
    #[test]
    fn guest_jit_listener_reads_event_props() {
        use g6b_asm::encode::RA;
        use g6b_asm::exec::{run_module, run_module_web_feed, GuestWebPresent, WebFeed};
        use g6b_asm::Op;

        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},
 "gr":{"enable":true,"w":640,"h":480,"colors":16,"backend":"virtio-gpu"},
 "wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"test"}},
"uncore":{"clint":true,"plic":true},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();

        // Same `DomtLayout` splice — deterministic laid-out rect before the
        // canned tablet poke arrives on the first guest Halt.
        let build = |m: &mut g6b_asm::Module| {
            install_guest(m, &test_module_evget()).expect("evget cell installs");
            for n in &mut m.nodes {
                if let Some(pos) = n
                    .ops
                    .iter()
                    .position(|o| matches!(o, Op::Jal { to, .. } if to == "JitRun"))
                {
                    n.ops
                        .splice(pos + 1..pos + 1, vec![Op::Jal { rd: RA, to: "DomtLayout".into() }]);
                    return;
                }
            }
            panic!("no JitRun call site to splice after");
        };

        // Phase 1 — probe for the button rect (same as the click test).
        let mut probe = g6b_asm::analyze::kstart(&spec);
        build(&mut probe);
        let sp = run_module(&spec, &probe, 0x8020_0000).unwrap();
        assert!(!sp.console.contains("TRAP-"), "{}", sp.console);
        let btn = sp
            .domt_nodes
            .iter()
            .find(|n| n.0 != 0)
            .expect("a non-root button node is laid out");
        let (bx, by, bw, bh) = (btn.3, btn.4, btn.5, btn.6);
        assert!(bw > 0 && bh > 0, "button has a laid-out rect: {:?}", btn);
        let (dw, dh) = (640u32, 480u32);
        let abs_x = (bx + bw / 2) * 0x8000 / dw;
        let abs_y = (by + bh / 2) * 0x8000 / dh;
        // The button centre lands at clientX≈bx+bw/2>200 — the delegate's
        // `clientX>=200` arm sees the real scaled px, not a fabricated pass.
        assert!(bx + bw / 2 >= 200, "clientX arm meaningful: {:?}", btn);

        // Phase 2 — real click delivers ABS pair + BTN_LEFT through trap_tab.
        struct ClickFeed {
            x: u32,
            y: u32,
        }
        impl WebFeed for ClickFeed {
            fn initial(&mut self) -> Option<GuestWebPresent> {
                None
            }
            fn on_guest_ui(&mut self) -> Option<GuestWebPresent> {
                None
            }
            fn hint_abs(&self) -> Option<(u32, u32)> {
                Some((self.x, self.y))
            }
        }
        let mut feed = ClickFeed { x: abs_x, y: abs_y };
        let mut m = g6b_asm::analyze::kstart(&spec);
        build(&mut m);
        let s = run_module_web_feed(&spec, &m, 0x8020_0000, 0, &mut feed).unwrap();
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
        assert!(!s.console.contains("WASM-JIT-TRAP"), "{}", s.console);
        assert_eq!(s.faults, 0, "fault-free: {}", s.console);
        assert!(s.domt_listen >= 1, "button click listener: {}", s.console);
        // The delegate appended iff clientX>=200 && target!=0 && defaultPrevented
        // — i.e. the getter bridge returned correct values and the
        // preventDefault write-back round-tripped. root+button+appended = 3.
        assert!(
            s.domt_live >= 3,
            "event-property bridge read ev fields → delegate appended (live={}): {}",
            s.domt_live,
            s.console
        );
    }
}

