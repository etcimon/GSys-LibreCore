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

use crate::binary::{decode, FuncType, Import, Instr, Tag, TryTableCatch, ValType};

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
    /// backpatched when the end is seen. `height` is the operand cell count
    /// from `s11` on entry; `results` is 0 or 1.
    Fwd {
        patch: Vec<usize>,
        height: u32,
        results: u32,
    },
    /// `loop`: `br` targets the record right after the `loop` opcode.
    Loop {
        start: u32,
        height: u32,
        results: u32,
    },
    /// `if`: the `JZ` to the else/end target, plus its own `Fwd` list for `br`.
    If {
        jz: usize,
        patch: Vec<usize>,
        height: u32,
        results: u32,
    },
    /// Legacy `try`: `patch` collects the forward refs that resolve to `end`
    /// (`br`-outs plus the JMP-over-handler each `catch` emits); `throws` are
    /// `throw`/`rethrow` forward-refs patched to the first handler entry at the
    /// first `catch`. `seen_catch` stops later `catch` arms from re-patching.
    /// `height` is snapshotted at `try` so `R_EXCCLR` can restore `s10`.
    /// `catch_nparams` is the payload count of the current catch (0 for
    /// `catch_all`) so `rethrow` can restash on escape. `catch_tag` is the
    /// tag of that catch (`u32::MAX` = `catch_all`) so `rethrow` can select
    /// a `try_table` dest.
    Try {
        patch: Vec<usize>,
        throws: Vec<usize>,
        seen_catch: bool,
        height: u32,
        results: u32,
        catch_nparams: u32,
        catch_tag: u32,
    },
    /// `try_table`: body is a forward block; `throw` emits `R_EXCCLR` at the
    /// dest frame's height then `br` (depth = label + 1 + frames between throw
    /// and this table). Label 0 is the parent, not the table. `throws` are
    /// post-call `R_EXCCHK` records (one per clause, in clause order per call)
    /// patched to skip-over landing pads. `catch_dest` is
    /// `(label, nparams, match_tag)` per executable clause (`match_tag` =
    /// `u64::MAX` for `catch_all`).
    TryTable {
        patch: Vec<usize>,
        catches: Vec<TryTableCatch>,
        height: u32,
        results: u32,
        throws: Vec<usize>,
        catch_dest: Vec<(u32, u32, u64)>,
    },
}

struct FnEnc {
    recs: Vec<Rec>,
    ctrls: Vec<Ctrl>,
    /// Operand + local cell count from `s11`. Starts at `nlocals` (the
    /// prologue leaves `s10 = s11 + nlocals*8`).
    height: u32,
    /// `R_CALL` record indices emitted while a `try`/`try_table` is live —
    /// sealed after the whole module is lowered if the callee can reach await.
    try_calls: Vec<usize>,
    /// `R_CALLI` record indices emitted while a `try`/`try_table` is live.
    try_calli: Vec<usize>,
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
    fn adj(&mut self, d: i32) {
        if d >= 0 {
            self.height = self.height.saturating_add(d as u32);
        } else {
            self.height = self.height.saturating_sub((-d) as u32);
        }
    }
    /// `catch`/`catch_all` head: JMP over the handler, then `R_EXCCLR` with
    /// the enclosing try's snapshotted height and the tag's payload count.
    fn catch_head(&mut self, nparams: u32, tag: u32) {
        let r = self.push(R_JMP, u32::MAX, 0);
        let height = match self.ctrls.last() {
            Some(Ctrl::Try { height, .. }) => *height,
            _ => self.height,
        };
        let handler_at = self.push(R_EXCCLR, height, u64::from(nparams)) as u32;
        self.height = height + nparams;
        match self.ctrls.last_mut() {
            Some(Ctrl::Try {
                patch,
                throws,
                seen_catch,
                catch_nparams,
                catch_tag,
                ..
            }) => {
                patch.push(r);
                *catch_nparams = nparams;
                *catch_tag = tag;
                if !*seen_catch {
                    for h in throws.drain(..) {
                        self.recs[h].a = handler_at;
                    }
                    *seen_catch = true;
                }
            }
            _ => {
                self.trap(TRAP_XLATE, 0x07);
            }
        }
    }
    /// Emit a post-`call`/`call_indirect` exception check — the landing pad a
    /// callee's `R_THROW` returns into. Inside a `try` *body* the record is
    /// queued into that try's `throws` so the first `catch` backpatches `a` to
    /// the handler; a call inside a `catch` (`seen_catch`) routes to the next
    /// enclosing try (its own protection is already consumed). Inside a
    /// `try_table` one `R_EXCCHK` is emitted per clause (bit 32 of `b` chains
    /// a tagged miss to the next check) and patched to an `R_EXCCLR`+`R_JMP`
    /// pad at `end`. No enclosing handler keeps `a` = u32::MAX → propagate.
    fn excchk(&mut self) {
        let mut try_i = None;
        let mut table_i = None;
        let mut table_dests: Option<Vec<(u32, u32, u64)>> = None;
        for (i, c) in self.ctrls.iter().enumerate().rev() {
            match c {
                Ctrl::Try { seen_catch, .. } if !*seen_catch => {
                    try_i = Some(i);
                    break;
                }
                Ctrl::Try { .. } => {}
                Ctrl::TryTable { catch_dest, .. } if !catch_dest.is_empty() => {
                    table_i = Some(i);
                    table_dests = Some(catch_dest.clone());
                    break;
                }
                Ctrl::TryTable { .. } => {}
                _ => {}
            }
        }
        if let Some(i) = try_i {
            let r = self.push(R_EXCCHK, u32::MAX, 0);
            if let Ctrl::Try { throws, .. } = &mut self.ctrls[i] {
                throws.push(r);
            }
            return;
        }
        if let (Some(i), Some(dests)) = (table_i, table_dests) {
            let n = dests.len();
            let mut recs = Vec::with_capacity(n);
            for (j, &(_, _, tag)) in dests.iter().enumerate() {
                let b = if tag == u64::MAX {
                    u64::MAX
                } else if j + 1 < n {
                    tag | EXCCHK_CHAIN
                } else {
                    tag
                };
                recs.push(self.push(R_EXCCHK, u32::MAX, b));
            }
            if let Ctrl::TryTable { throws, .. } = &mut self.ctrls[i] {
                throws.extend(recs);
            }
            return;
        }
        self.push(R_EXCCHK, u32::MAX, 0);
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
            Ctrl::Loop { start, .. } => Some(*start),
            _ => None,
        };
        let r = self.push(op, loop_start.unwrap_or(u32::MAX), 0);
        if loop_start.is_none() {
            match &mut self.ctrls[i] {
                Ctrl::Fwd { patch, .. }
                | Ctrl::If { patch, .. }
                | Ctrl::Try { patch, .. }
                | Ctrl::TryTable { patch, .. } => patch.push(r),
                _ => {}
            }
        }
    }
    /// Land a `try_table` catch dest. `CATCH_DEST_REF` synthesizes an exnref
    /// handle; `CATCH_DEST_PAY` also copies the tag payload (`catch_ref`).
    /// `from_stack` is a local `throw` (payload still on the wasm stack);
    /// cross-function pads stash via `R_THROW` already and keep `OFF_EXCTAG`.
    fn emit_catch_land(&mut self, dest_h: u32, nparams: u32, tag: u64, from_stack: bool) {
        if nparams & CATCH_DEST_REF != 0 {
            let pay = nparams & 0xff;
            let with_pay = nparams & CATCH_DEST_PAY != 0;
            if from_stack {
                self.push(R_EXNREF, pay, tag);
                let copy = if with_pay { pay + 1 } else { 1 };
                self.push(R_EXCCLR, dest_h, u64::from(copy));
            } else if with_pay {
                self.push(R_EXCCLR, dest_h, u64::from(pay));
                self.push(R_EXNREF, 0, u64::MAX);
            } else {
                self.push(R_EXCCLR, dest_h, 0);
                self.push(R_EXNREF, 0, u64::MAX);
            }
        } else {
            self.push(R_EXCCLR, dest_h, u64::from(nparams));
        }
    }
    fn end(&mut self) {
        let target = self.at();
        match self.ctrls.pop() {
            Some(Ctrl::If {
                jz,
                patch,
                height,
                results,
            }) => {
                // An `if` with no `else` leaves its `jz` still pointing at the
                // u32::MAX sentinel — resolve it to `end` so `if (0)` skips the
                // then-body. `else_` already patched it when an else existed.
                if self.recs[jz].a == u32::MAX {
                    self.recs[jz].a = target;
                }
                for r in patch {
                    self.recs[r].a = target;
                }
                self.height = height + results;
            }
            Some(Ctrl::Fwd {
                patch,
                height,
                results,
            })
            | Some(Ctrl::Try {
                patch,
                height,
                results,
                ..
            }) => {
                for r in patch {
                    self.recs[r].a = target;
                }
                self.height = height + results;
            }
            Some(Ctrl::TryTable {
                patch,
                height,
                results,
                throws,
                catch_dest,
                ..
            }) => {
                // One off-fallthrough pad per clause so a callee `R_THROW` can
                // `R_EXCCHK` into `R_EXCCLR`+`R_JMP` dest. Body exits skip the
                // pads. `throws` is clause-major per call (n checks × calls).
                if throws.is_empty() || catch_dest.is_empty() {
                    for r in patch {
                        self.recs[r].a = target;
                    }
                    self.height = height + results;
                } else {
                    let skip_jmp = self.push(R_JMP, u32::MAX, 0);
                    let nctrl = self.ctrls.len();
                    let n = catch_dest.len();
                    let mut landings = Vec::with_capacity(n);
                    for &(label, nparams, _) in &catch_dest {
                        landings.push(self.at());
                        let dest_h = if (label as usize) < nctrl {
                            ctrl_height(&self.ctrls[nctrl - 1 - label as usize])
                        } else {
                            height
                        };
                        self.emit_catch_land(dest_h, nparams, u64::MAX, false);
                        self.br(label, false);
                    }
                    for (i, t) in throws.iter().enumerate() {
                        self.recs[*t].a = landings[i % n];
                    }
                    let skip = self.at();
                    self.recs[skip_jmp].a = skip;
                    for r in patch {
                        self.recs[r].a = skip;
                    }
                    self.height = height + results;
                }
            }
            Some(Ctrl::Loop {
                height, results, ..
            }) => {
                // `end` of a loop just falls through — `br` already points up.
                self.height = height + results;
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
            Some(Ctrl::If { jz, height, .. }) => {
                self.recs[*jz].a = target;
                self.height = *height;
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
    fn if_(&mut self, results: u32) {
        self.adj(-1); // pop the condition
        let height = self.height;
        let jz = self.push(R_JZ, u32::MAX, 0);
        self.ctrls.push(Ctrl::If {
            jz,
            patch: vec![],
            height,
            results,
        });
    }
}

fn nres(ty: Option<ValType>) -> u32 {
    u32::from(ty.is_some())
}

fn tag_nparams(tags: &[Tag], types: &[FuncType], tag: u32) -> u32 {
    tags.get(tag as usize)
        .and_then(|t| types.get(t.typeidx as usize))
        .map(|ty| ty.params.len() as u32)
        .unwrap_or(0)
        .min(MAX_EXCPAY)
}

fn call_delta(fidx: u32, imports: &[Import], types: &[FuncType], func_types: &[u32]) -> i32 {
    let ty = if (fidx as usize) < imports.len() {
        types.get(imports[fidx as usize].typeidx as usize)
    } else {
        let body = fidx as usize - imports.len();
        func_types.get(body).and_then(|&ti| types.get(ti as usize))
    };
    match ty {
        Some(t) => t.results.len() as i32 - t.params.len() as i32,
        None => 0,
    }
}

fn stack_delta(
    ins: &Instr,
    imports: &[Import],
    types: &[FuncType],
    func_types: &[u32],
    tags: &[Tag],
) -> i32 {
    match ins {
        Instr::I32Const(_)
        | Instr::I64Const(_)
        | Instr::F32Const(_)
        | Instr::F64Const(_)
        | Instr::LocalGet(_)
        | Instr::GlobalGet(_)
        | Instr::MemorySize
        | Instr::TableGet(_)
        | Instr::TableSize(_) => 1,
        Instr::Drop
        | Instr::LocalSet(_)
        | Instr::GlobalSet(_)
        | Instr::BrIf(_)
        | Instr::BrTable { .. }
        | Instr::ThrowRef => -1,
        Instr::Select => -2,
        Instr::I32Add
        | Instr::I32Sub
        | Instr::I32Mul
        | Instr::I32DivS
        | Instr::I32DivU
        | Instr::I32RemS
        | Instr::I32RemU
        | Instr::I32And
        | Instr::I32Or
        | Instr::I32Xor
        | Instr::I32Shl
        | Instr::I32ShrS
        | Instr::I32ShrU
        | Instr::I32Rotl
        | Instr::I32Rotr
        | Instr::I32Eq
        | Instr::I32Ne
        | Instr::I32LtS
        | Instr::I32LtU
        | Instr::I32GtS
        | Instr::I32GtU
        | Instr::I32LeS
        | Instr::I32LeU
        | Instr::I32GeS
        | Instr::I32GeU => -1,
        Instr::I32Eqz | Instr::LocalTee(_) | Instr::I32Load { .. } => 0,
        Instr::I32Load8S { .. }
        | Instr::I32Load8U { .. }
        | Instr::I32Load16S { .. }
        | Instr::I32Load16U { .. }
        | Instr::I64Load { .. }
        | Instr::I64Load8S { .. }
        | Instr::I64Load8U { .. }
        | Instr::I64Load16S { .. }
        | Instr::I64Load16U { .. }
        | Instr::I64Load32S { .. }
        | Instr::I64Load32U { .. }
        | Instr::F32Load { .. }
        | Instr::F64Load { .. }
        | Instr::Convert(_)
        | Instr::SaturatingTrunc(_)
        | Instr::MemoryGrow => 0,
        Instr::I32Store { .. }
        | Instr::I32Store8 { .. }
        | Instr::I32Store16 { .. }
        | Instr::I64Store { .. }
        | Instr::I64Store8 { .. }
        | Instr::I64Store16 { .. }
        | Instr::I64Store32 { .. }
        | Instr::F32Store { .. }
        | Instr::F64Store { .. }
        | Instr::TableSet(_) => -2,
        Instr::MemoryCopy
        | Instr::MemoryFill
        | Instr::MemoryInit(_)
        | Instr::TableCopy { .. }
        | Instr::TableFill(_)
        | Instr::TableInit { .. } => -3,
        Instr::TableGrow(_) => 0,
        Instr::Numeric(op) => numeric_delta(*op),
        Instr::Call(fidx) => call_delta(*fidx, imports, types, func_types),
        Instr::CallIndirect { typeidx, .. } => match types.get(*typeidx as usize) {
            Some(t) => t.results.len() as i32 - t.params.len() as i32 - 1,
            None => -1,
        },
        Instr::Throw(t) => -(tag_nparams(tags, types, *t) as i32),
        Instr::Block(_)
        | Instr::Loop(_)
        | Instr::If(_)
        | Instr::Else
        | Instr::End
        | Instr::Br(_)
        | Instr::Try(_)
        | Instr::Catch(_)
        | Instr::CatchAll
        | Instr::Delegate(_)
        | Instr::TryTable { .. }
        | Instr::Nop
        | Instr::Unreachable
        | Instr::Return
        | Instr::Rethrow(_)
        | Instr::DataDrop(_)
        | Instr::ElemDrop(_)
        | Instr::Unsupported(_) => 0,
    }
}

fn numeric_delta(op: u8) -> i32 {
    match op {
        0x45 | 0x50 => 0,                              // eqz
        0x46..=0x4f | 0x51..=0x5a | 0x5b..=0x66 => -1, // cmp
        0x67..=0x69 | 0x79..=0x7b => 0,                // clz/ctz/popcnt
        0x6a..=0x78 | 0x7c..=0x8a => -1,               // i32/i64 bin
        0x8b..=0x91 | 0x99..=0x9f => 0,                // f32/f64 unary
        0x92..=0x98 | 0xa0..=0xa6 => -1,               // f32/f64 bin
        _ => 0,
    }
}

fn ctrl_height(c: &Ctrl) -> u32 {
    match c {
        Ctrl::Fwd { height, .. }
        | Ctrl::Loop { height, .. }
        | Ctrl::If { height, .. }
        | Ctrl::Try { height, .. }
        | Ctrl::TryTable { height, .. } => *height,
    }
}

/// OR into a `try_table` dest `nparams` so the landing synthesizes an
/// exnref handle (`catch_all_ref` / `catch_ref`) instead of only the tag
/// payload.
const CATCH_DEST_REF: u32 = 1 << 8;
/// With `CATCH_DEST_REF`, also copy the tag payload onto the dest
/// (`catch_ref`: payload then exnref). `catch_all_ref` omits this.
const CATCH_DEST_PAY: u32 = 1 << 9;

/// Executable `try_table` catch clauses for cross-function landing pads, in
/// table order.
fn try_table_catches(
    catches: &[TryTableCatch],
    tags: &[Tag],
    types: &[FuncType],
) -> Vec<(u32, u32, u64)> {
    let mut out = Vec::new();
    for c in catches {
        match c {
            TryTableCatch::Catch { tag, label } => {
                out.push((*label, tag_nparams(tags, types, *tag), u64::from(*tag)));
            }
            TryTableCatch::CatchAll { label } => out.push((*label, 0, u64::MAX)),
            TryTableCatch::CatchAllRef { label } => {
                out.push((*label, CATCH_DEST_REF, u64::MAX));
            }
            TryTableCatch::CatchRef { tag, label } => {
                out.push((
                    *label,
                    CATCH_DEST_REF | CATCH_DEST_PAY | tag_nparams(tags, types, *tag),
                    u64::from(*tag),
                ));
            }
        }
    }
    out
}

/// True when a `try`/`try_table` is on the control stack — `await` must not
/// sit in that region (asyncify rewind is not an EH landing pad).
fn in_eh_try(f: &FnEnc) -> bool {
    f.ctrls
        .iter()
        .any(|c| matches!(c, Ctrl::Try { .. } | Ctrl::TryTable { .. }))
}

/// After every body is lowered: a `try`/`try_table` that `call`s a function
/// which can reach `await` (directly or via other calls) is fail-closed.
/// Direct import-await inside a try is already a 0x700 trap at the `R_EXT`
/// site; this pass covers `try { call $awaiter }`. `call_indirect` inside a
/// try is fail-closed when **any** funcref-table function can reach await
/// (table-conservative; not a per-index proof).
fn seal_await_in_try(fns: &mut [FnEnc], nimports: u32, nfuncs: u32, table: &[u32]) {
    let n = nfuncs as usize;
    let mut callers: Vec<Vec<u32>> = vec![Vec::new(); n];
    let mut reaches = vec![false; n];
    let mut stack = Vec::new();
    for (i, f) in fns.iter().enumerate() {
        let fidx = nimports + i as u32;
        for r in &f.recs {
            if r.op == R_CALL && (r.a as usize) < n {
                callers[r.a as usize].push(fidx);
            }
            if r.op == R_EXT
                && (r.a == EXT_AWAIT || r.a == EXT_AWAIT_VOID)
                && !reaches[fidx as usize]
            {
                reaches[fidx as usize] = true;
                stack.push(fidx);
            }
        }
    }
    while let Some(fidx) = stack.pop() {
        for &c in &callers[fidx as usize] {
            if !reaches[c as usize] {
                reaches[c as usize] = true;
                stack.push(c);
            }
        }
    }
    let table_can_await = table.iter().any(|&fidx| {
        let i = fidx as usize;
        i < n && reaches[i]
    });
    for f in fns.iter_mut() {
        for &ri in &f.try_calls {
            if f.recs[ri].op != R_CALL {
                continue;
            }
            let callee = f.recs[ri].a as usize;
            if callee < n && reaches[callee] {
                f.recs[ri].op = R_TRAP;
                f.recs[ri].a = TRAP_UNSUP;
                f.recs[ri].b = 0x700;
            }
        }
        if table_can_await {
            for &ri in &f.try_calli {
                if f.recs[ri].op == R_CALLI {
                    f.recs[ri].op = R_TRAP;
                    f.recs[ri].a = TRAP_UNSUP;
                    f.recs[ri].b = 0x700;
                }
            }
        }
    }
}

/// Catch dest for `throw $tag` inside `try_table`: `(br_label, payload_slots)`.
/// `catch_all` has 0 payload slots. `CATCH_DEST_REF` marks an exnref dest;
/// `CATCH_DEST_PAY` also copies the tag payload (`catch_ref`). Labels do
/// not count the table (0 = parent).
fn try_table_catch_dest(
    catches: &[TryTableCatch],
    tag: u32,
    tags: &[Tag],
    types: &[FuncType],
) -> Option<(u32, u32)> {
    for c in catches {
        match c {
            TryTableCatch::Catch { tag: t, label } if *t == tag => {
                return Some((*label, tag_nparams(tags, types, *t)));
            }
            TryTableCatch::CatchAll { label } => return Some((*label, 0)),
            TryTableCatch::CatchAllRef { label } => {
                return Some((*label, CATCH_DEST_REF | tag_nparams(tags, types, tag)));
            }
            TryTableCatch::CatchRef { tag: t, label } if *t == tag => {
                return Some((
                    *label,
                    CATCH_DEST_REF | CATCH_DEST_PAY | tag_nparams(tags, types, *t),
                ));
            }
            TryTableCatch::CatchRef { .. } | TryTableCatch::Catch { .. } => {}
        }
    }
    None
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
#[allow(clippy::too_many_arguments)]
fn lower_fn(
    instrs: &[Instr],
    imports: &[Import],
    types: &[FuncType],
    func_types: &[u32],
    tags: &[Tag],
    nfuncs: u32,
    m_mem_pages: u32,
    m_max_pages: Option<u32>,
    cur_fidx: u32,
    f: &mut FnEnc,
) {
    for ins in instrs {
        match ins.clone() {
            Instr::Nop => {
                f.push(R_NOP, 0, 0);
            }
            Instr::End => f.end(),
            Instr::Block(ty) => f.ctrls.push(Ctrl::Fwd {
                patch: vec![],
                height: f.height,
                results: nres(ty),
            }),
            Instr::Loop(ty) => f.ctrls.push(Ctrl::Loop {
                start: f.at(),
                height: f.height,
                results: nres(ty),
            }),
            Instr::If(ty) => f.if_(nres(ty)),
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
                            // Rewind is not a landing pad: `await` inside
                            // `try`/`try_table` is fail-closed on the guest
                            // JIT (printer rule; host interp may still
                            // exercise the Binaryen-fork path).
                            if matches!(e, EXT_AWAIT | EXT_AWAIT_VOID) && in_eh_try(f) {
                                f.trap(TRAP_UNSUP, 0x700);
                            } else {
                                // `b` = arity | has_result<<8 so `jit_h_ext`
                                // marshals exactly the wasm-declared params
                                // and pushes a0 only for a value-returning
                                // import (void calls leave no dead slot).
                                let ty = &types[im.typeidx as usize];
                                let b = ty.params.len() as u64
                                    | (u64::from(!ty.results.is_empty() as u32) << 8);
                                f.push(R_EXT, e, b);
                            }
                        }
                        None => f.trap(TRAP_EXT, fidx as u64),
                    }
                } else if fidx < nfuncs {
                    let ri = f.push(R_CALL, fidx, 0);
                    if in_eh_try(f) {
                        f.try_calls.push(ri);
                    }
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
                let ri = f.push(R_CALLI, typeidx, u64::from(tableidx));
                if in_eh_try(f) {
                    f.try_calli.push(ri);
                }
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
            // innermost enclosing try's first `catch` backpatches. `R_EXCCLR`
            // restores `s10` to the snapshotted try height so leftover try-body
            // values do not become the catch result (`catch_all` drops the
            // payload; tagged catch copies `b` payload cells onto that height).
            Instr::Try(ty) => f.ctrls.push(Ctrl::Try {
                patch: vec![],
                throws: vec![],
                seen_catch: false,
                height: f.height,
                results: nres(ty),
                catch_nparams: 0,
                catch_tag: u32::MAX,
            }),
            Instr::Catch(tag) => f.catch_head(tag_nparams(tags, types, tag), tag),
            Instr::CatchAll => f.catch_head(0, u32::MAX),
            Instr::Delegate(l) => {
                // ends the try with no handler; its `br`-outs resolve to the
                // record right after the delegate, and pending `throw`s forward
                // to the enclosing try `l` (or propagate out → trap).
                let target = f.at();
                let mut pending = vec![];
                match f.ctrls.pop() {
                    Some(Ctrl::Try {
                        patch,
                        throws,
                        height,
                        results,
                        ..
                    }) => {
                        for r in patch {
                            f.recs[r].a = target;
                        }
                        pending = throws;
                        f.height = height + results;
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
                                f.recs[h].a = if f.recs[h].b == u64::MAX {
                                    0
                                } else {
                                    tag_nparams(tags, types, f.recs[h].b as u32)
                                };
                            }
                        }
                    }
                }
            }
            Instr::Throw(t) => {
                // `try_table` catch dests are `br` labels that do not count the
                // table itself (label 0 = parent). Restore the dest frame's
                // operand height before the jump so leftover try-body values
                // (and `catch_all`'s discarded payload) do not survive.
                let mut table_depth: Option<u32> = None;
                let mut try_idx: Option<usize> = None;
                let n = f.ctrls.len();
                for (idx, c) in f.ctrls.iter().enumerate().rev() {
                    match c {
                        Ctrl::TryTable { catches, .. } => {
                            if let Some((label, nparams)) =
                                try_table_catch_dest(catches, t, tags, types)
                            {
                                let depth = (n - 1 - idx) as u32 + label + 1;
                                if (depth as usize) < n {
                                    let height = ctrl_height(&f.ctrls[n - 1 - depth as usize]);
                                    f.emit_catch_land(height, nparams, u64::from(t), true);
                                }
                                table_depth = Some(depth);
                                break;
                            }
                        }
                        Ctrl::Try { .. } => {
                            try_idx = Some(idx);
                            break;
                        }
                        _ => {}
                    }
                }
                if let Some(depth) = table_depth {
                    f.br(depth, false);
                } else if let Some(idx) = try_idx {
                    let r = f.push(R_JMP, u32::MAX, u64::from(t));
                    if let Ctrl::Try { throws, .. } = &mut f.ctrls[idx] {
                        throws.push(r);
                    }
                } else {
                    let r = f.push(R_JMP, u32::MAX, u64::from(t));
                    f.recs[r].op = R_THROW;
                    f.recs[r].a = tag_nparams(tags, types, t);
                }
            }
            Instr::Rethrow(l) => {
                // `rethrow l` rethrows the exception caught by the try at
                // depth `l` (0 = current catch). That try already consumed its
                // handler, so search *outside* it for the next `try` catch or
                // a `try_table` dest; otherwise escape with R_THROW (b=MAX
                // keeps OFF_EXCTAG, a = catch payload count).
                let n = f.ctrls.len();
                let mut nparams = 0u32;
                let mut catch_tag = u32::MAX;
                let mut outer_try: Option<usize> = None;
                let mut outer_table: Option<usize> = None;
                if (l as usize) < n {
                    let i = n - 1 - l as usize;
                    if let Ctrl::Try {
                        catch_nparams,
                        catch_tag: t,
                        ..
                    } = &f.ctrls[i]
                    {
                        nparams = *catch_nparams;
                        catch_tag = *t;
                    }
                    for idx in (0..i).rev() {
                        match &f.ctrls[idx] {
                            Ctrl::Try { seen_catch, .. } if !*seen_catch => {
                                outer_try = Some(idx);
                                break;
                            }
                            Ctrl::TryTable { catches, .. } => {
                                if try_table_catch_dest(catches, catch_tag, tags, types).is_some() {
                                    outer_table = Some(idx);
                                    break;
                                }
                            }
                            _ => {}
                        }
                    }
                }
                if let Some(idx) = outer_try {
                    let r = f.push(R_JMP, u32::MAX, u64::MAX);
                    if let Ctrl::Try { throws, .. } = &mut f.ctrls[idx] {
                        throws.push(r);
                    }
                } else if let Some(idx) = outer_table {
                    let catches = match &f.ctrls[idx] {
                        Ctrl::TryTable { catches, .. } => catches.clone(),
                        _ => Vec::new(),
                    };
                    if let Some((label, np)) =
                        try_table_catch_dest(&catches, catch_tag, tags, types)
                    {
                        let n = f.ctrls.len();
                        let depth = (n - 1 - idx) as u32 + label + 1;
                        if (depth as usize) < n {
                            let height = ctrl_height(&f.ctrls[n - 1 - depth as usize]);
                            let tag = if catch_tag == u32::MAX {
                                u64::MAX
                            } else {
                                u64::from(catch_tag)
                            };
                            f.emit_catch_land(height, np, tag, true);
                        }
                        f.br(depth, false);
                    } else {
                        let r = f.push(R_JMP, u32::MAX, u64::MAX);
                        f.recs[r].op = R_THROW;
                        f.recs[r].a = nparams;
                    }
                } else {
                    let r = f.push(R_JMP, u32::MAX, u64::MAX);
                    f.recs[r].op = R_THROW;
                    f.recs[r].a = nparams;
                }
            }
            Instr::TryTable { result, catches } => {
                let catch_dest = try_table_catches(&catches, tags, types);
                f.ctrls.push(Ctrl::TryTable {
                    patch: vec![],
                    catches,
                    height: f.height,
                    results: nres(result),
                    throws: vec![],
                    catch_dest,
                });
            }
            Instr::ThrowRef => {
                // Pop the exnref, set EXC/EXCTAG, then the same post-call
                // EXCCHK chain an enclosing `try`/`try_table` already uses.
                f.push(R_EXNREF, u32::MAX, 0);
                f.excchk();
            }
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
        f.adj(stack_delta(ins, imports, types, func_types, tags));
    }
}

/// The `env.*` import → trampoline id. The table must match `jit_ext_tab`.
fn ext_id(module: &str, name: &str) -> Option<u32> {
    if module == "env" {
        // `Object_Getter__<kind>` is a name-encoded libwasm property getter,
        // not a fixed import. The i32-returning kinds route onto the
        // `__ev_obj` bridge (`LwEvGet`); `string` is `LwEvGetStr`;
        // `OptionalHandle`/`Uint` is `LwEvGetOpt`; `float` is `LwEvGetF`;
        // `double` is `LwEvGetD`; remaining Optional kinds have typed srets.
        if let Some(kind) = name.strip_prefix("Object_Getter__") {
            return match kind {
                "int" | "uint" | "ushort" | "bool" | "Handle" => Some(EXT_EVGET),
                "string" => Some(EXT_EVGETSTR),
                "OptionalHandle" | "OptionalUint" => Some(EXT_EVGETOPT),
                "float" => Some(EXT_EVGETF),
                "double" => Some(EXT_EVGETD),
                "OptionalString" => Some(EXT_EVGETOPTS),
                "OptionalBool" => Some(EXT_EVGETOPTB),
                "OptionalDouble" => Some(EXT_EVGETOPTD),
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
        ("env", "libwasm_await_failed") => Some(EXT_AWAIT_FAIL),
        ("env", "libwasm_await_error") => Some(EXT_AWAIT_ERR),
        ("env", "libasync_promise_all__promise") => Some(EXT_PROM_ALL),
        ("env", "libasync_promise_any__promise") => Some(EXT_PROM_ANY),
        ("env", "libasync_promise_allsettled__promise") => Some(EXT_PROM_ALLS),
        ("env", "libwasm_add__ints") => Some(EXT_ADDINTS),
        ("env", "libwasm_note_await_ok") => Some(EXT_NOTEFUL),
        ("env", "libwasm_note_await_fail") => Some(EXT_NOTEREJ),
        ("env", "getRoot") => Some(EXT_GETROOT),
        ("env", "add_event_listener") => Some(EXT_ADDLSN),
        ("env", "remove_event_listener") | ("env", "removeEventListener") => Some(EXT_RMLSN),
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
    let nparams = m
        .types
        .get(m.func_types.get(i).copied().unwrap_or(0) as usize)
        .map(|t| t.params.len() as u32)
        .unwrap_or(0);
    let nlocals = nparams + m.locals.get(i).copied().unwrap_or(0);
    let mut f = FnEnc {
        recs: Vec::new(),
        ctrls: Vec::new(),
        height: nlocals,
        try_calls: Vec::new(),
        try_calli: Vec::new(),
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
        &m.func_types,
        &m.tags,
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
                0x500 => "catch_ref (exnref payload+ref)".into(),
                0x600 => "throw outside a try (no handler)".into(),
                0x700 => "await inside try/try_table (rewind is not a landing pad)".into(),
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
    let table: Vec<u32> = m
        .elements
        .iter()
        .flat_map(|el| el.funcs.iter().copied())
        .collect();
    seal_await_in_try(&mut fns, nimports, nfuncs, &table);
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
    let mut fns: Vec<FnEnc> = Vec::with_capacity(m.bodies.len());
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
        fns.push(lower_one(&m, i, fidx as u32)?);
    }
    let table: Vec<u32> = m
        .elements
        .iter()
        .flat_map(|el| el.funcs.iter().copied())
        .collect();
    seal_await_in_try(&mut fns, nimports, nfuncs, &table);
    for (i, f) in fns.into_iter().enumerate() {
        let ty = &m.types[m.func_types[i] as usize];
        let nparams = ty.params.len() as u32;
        let nlocals = nparams + m.locals.get(i).copied().unwrap_or(0);
        let bc_off = recs.len() as u32;
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
    let usable_pages = m.mem_pages.max(m.max_mem_pages.unwrap_or(256));
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
        AX_START, AX_START_REWIND, AX_START_UNWIND, AX_STATE_GLOB, AX_STOP_REWIND, AX_STOP_UNWIND,
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
        0x41, ORD, // i32.const ORD
        0x10, 0x01, // call $createElement
        0x10, 0x02, // call $appendChild
        0x0b,
    ]);
    // $_start(): local0 = el handle
    let mut bst = vec![0x01, 0x01, 0x7f]; // 1 local group, count1, i32
    bst.extend_from_slice(&[
        0x41, ORD, 0x10, 0x01, 0x21, 0x00, // el = createElement(ORD); local.set 0
        0x20, 0x00, // local.get 0  (el handle)
        0x41, 0x02, 0x41, ID, //   namelen=2  nameptr=ID   ("id")
        0x41, 0x01, 0x41, X, //   vallen=1   valptr=X    ("x")
        0x10, 0x03, // setProperty(el,"id","x") — len-first ABI
        0x10, 0x00, 0x20, 0x00, 0x10, 0x02, // appendChild(getRoot(), el)
        0x41, X, 0x41, 0x01, // tptr=X  tlen=1   ("x")     ptr-first ABI
        0x41, KD, 0x41, tylen, // typtr=KD tylen (the event name)
        0x41, DELEGATE, // cb = $delegate funcidx 5
        0x41, 0x00, // capture = 0
        0x10, 0x04, // add_event_listener("x",<ev>,5,0)
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
        0x10, 0x00, 0x41, ORD, 0x10, 0x01, 0x10,
        0x02, // appendChild(getRoot(),createElement(ORD))
        0x0b, // end if
        0x0b, // end func
    ]);

    // $_start(): build + register, identical to the click-delegate cell.
    let mut bst = vec![0x01, 0x01, 0x7f];
    bst.extend_from_slice(&[
        0x41, ORD, 0x10, 0x01, 0x21, 0x00, // el = createElement(ORD)
        0x20, 0x00, 0x41, 0x02, 0x41, ID, 0x41, 0x01, 0x41, X, 0x10,
        0x03, // setProperty(el,"id","x")
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

/// Delegate that reads a UTF-8 event field through `Object_Getter__string`.
/// `_start` builds `root + <button id="x">` and registers
/// `add_event_listener("x", <ev>, $delegate)`. `$delegate(ev)` writes the
/// named property into a D `{len,ptr}` at wasm off `0x08` and `appendChild`s
/// iff `len == 5` — `"click"` for `type` on a click, `"Enter"` for `code` on
/// KEY_ENTER. Empty/unknown/`Unidentified`(13)/`KeyA`(4) leave `__dom` ungrown.
#[cfg(test)]
pub fn test_module_evstr(ev: &[u8], prop: &[u8]) -> Vec<u8> {
    const ID: u8 = 0x10;
    const X: u8 = 0x12;
    const EV: u8 = 0x13;
    let prop_off = EV + ev.len() as u8;
    const SRET: u8 = 0x08;
    const ORD: u8 = 14;
    const DELEGATE: u8 = 6; // imports 0..=5 first
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();

    // t0 ()->i32 · t1 (i32)->i32 · t2 (i32,i32)->() · t3 (i32x5)->()
    // t4 (i32x6)->() · t5 (i32)->() · t6 ()->() · t7 (i32x4)->() sret getter
    let mut types = Vec::new();
    push_uleb(&mut types, 8);
    types.extend_from_slice(&[0x60, 0x00, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x02, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x05, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x06, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x00, 0x00]);
    types.extend_from_slice(&[0x60, 0x04, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    section(&mut out, 1, &types);

    let mut imps = Vec::new();
    push_uleb(&mut imps, 6);
    for (name, ty) in [
        ("getRoot", 0u8),
        ("createElement", 1),
        ("appendChild", 2),
        ("setProperty", 3),
        ("add_event_listener", 4),
        ("Object_Getter__string", 7),
    ] {
        put_name(&mut imps, "env");
        put_name(&mut imps, name);
        imps.push(0x00);
        imps.push(ty);
    }
    section(&mut out, 2, &imps);

    section(&mut out, 3, &[2, 0x05, 0x06]); // $delegate(t5)=6, $_start(t6)=7
    section(&mut out, 5, &[1, 0x00, 0x01]);

    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.extend_from_slice(&[0x02, 0x00]);
    put_name(&mut exports, "_start");
    exports.extend_from_slice(&[0x00, 0x07]);
    section(&mut out, 7, &exports);

    let plen = prop.len() as u8;
    let elen = ev.len() as u8;
    let mut bdel = vec![0x01, 0x01, 0x7f]; // local 1 = sret len
    bdel.extend_from_slice(&[
        // Object_Getter__string(SRET, ev, plen, prop_off)
        0x41, SRET, 0x20, 0x00, 0x41, plen, 0x41, prop_off, 0x10, 0x05,
        // len = i32.load(SRET)
        0x41, SRET, 0x28, 0x02, 0x00, 0x21, 0x01,
        // if len == 5 appendChild(getRoot(), createElement(ORD))
        0x20, 0x01, 0x41, 0x05, 0x46, 0x04, 0x40, 0x10, 0x00, 0x41, ORD, 0x10, 0x01, 0x10, 0x02,
        0x0b, 0x0b,
    ]);

    let mut bst = vec![0x01, 0x01, 0x7f];
    bst.extend_from_slice(&[
        0x41, ORD, 0x10, 0x01, 0x21, 0x00, // el = createElement(ORD)
        0x20, 0x00, 0x41, 0x02, 0x41, ID, 0x41, 0x01, 0x41, X, 0x10,
        0x03, // setProperty(el,"id","x")
        0x10, 0x00, 0x20, 0x00, 0x10, 0x02, // appendChild(getRoot(), el)
        0x41, X, 0x41, 0x01, // tptr=X tlen=1
        0x41, EV, 0x41, elen, // typtr=EV tylen
        0x41, DELEGATE, 0x41, 0x00, 0x10, 0x04, // add_event_listener
        0x0b,
    ]);

    let mut code = Vec::new();
    push_uleb(&mut code, 2);
    push_uleb(&mut code, bdel.len() as u32);
    code.extend_from_slice(&bdel);
    push_uleb(&mut code, bst.len() as u32);
    code.extend_from_slice(&bst);
    section(&mut out, 10, &code);

    let end = prop_off as usize + prop.len();
    let mut body = vec![0u8; end - 0x10];
    let put = |body: &mut Vec<u8>, off: u8, s: &[u8]| {
        body[(off as usize) - 0x10..(off as usize) - 0x10 + s.len()].copy_from_slice(s);
    };
    put(&mut body, ID, b"id");
    put(&mut body, X, b"x");
    put(&mut body, EV, ev);
    put(&mut body, prop_off, prop);
    let mut data = Vec::new();
    push_uleb(&mut data, 1);
    data.extend_from_slice(&[0x00, 0x41, 0x10, 0x0b]);
    push_uleb(&mut data, body.len() as u32);
    data.extend_from_slice(&body);
    section(&mut out, 11, &data);
    out
}

/// Parent-listener cell: `_start` ids the root `"r"`, appends `<button id="x">`,
/// and registers `add_event_listener("r","click",$delegate,capture)`. The
/// button has no listener. `$delegate` appends iff `eventPhase` equals the
/// expected phase (`1` capturing, `3` bubbling) — so a click on the button
/// only grows `__dom` when the ancestor walk ran.
#[cfg(test)]
pub fn test_module_phase(capture: bool) -> Vec<u8> {
    const ID: u8 = 0x10;
    const R: u8 = 0x12;
    const X: u8 = 0x13;
    const EV: u8 = 0x14;
    const PH: u8 = 0x19;
    const ORD: u8 = 14;
    const DELEGATE: u8 = 6;
    let cap = if capture { 1u8 } else { 0 };
    let want = if capture { 1u8 } else { 3 };
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();

    let mut types = Vec::new();
    push_uleb(&mut types, 8);
    types.extend_from_slice(&[0x60, 0x00, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x02, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x05, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x06, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x00, 0x00]);
    types.extend_from_slice(&[0x60, 0x03, 0x7f, 0x7f, 0x7f, 0x01, 0x7f]);
    section(&mut out, 1, &types);

    let mut imps = Vec::new();
    push_uleb(&mut imps, 6);
    for (name, ty) in [
        ("getRoot", 0u8),
        ("createElement", 1),
        ("appendChild", 2),
        ("setProperty", 3),
        ("add_event_listener", 4),
        ("Object_Getter__int", 7),
    ] {
        put_name(&mut imps, "env");
        put_name(&mut imps, name);
        imps.push(0x00);
        imps.push(ty);
    }
    section(&mut out, 2, &imps);

    section(&mut out, 3, &[2, 0x05, 0x06]);
    section(&mut out, 5, &[1, 0x00, 0x01]);

    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.extend_from_slice(&[0x02, 0x00]);
    put_name(&mut exports, "_start");
    exports.extend_from_slice(&[0x00, 0x07]);
    section(&mut out, 7, &exports);

    let mut bdel = vec![0x01, 0x01, 0x7f];
    bdel.extend_from_slice(&[
        // phase = Object_Getter__int(ev, 10, PH)
        0x20, 0x00, 0x41, 0x0a, 0x41, PH, 0x10, 0x05, 0x21, 0x01,
        // if phase == want append
        0x20, 0x01, 0x41, want, 0x46, 0x04, 0x40, 0x10, 0x00, 0x41, ORD, 0x10, 0x01, 0x10, 0x02,
        0x0b, 0x0b,
    ]);

    let mut bst = vec![0x01, 0x01, 0x7f];
    bst.extend_from_slice(&[
        // setProperty(getRoot(),"id","r")
        0x10, 0x00, 0x41, 0x02, 0x41, ID, 0x41, 0x01, 0x41, R, 0x10, 0x03,
        // el = createElement(ORD); setProperty(el,"id","x"); appendChild(root, el)
        0x41, ORD, 0x10, 0x01, 0x21, 0x00, 0x20, 0x00, 0x41, 0x02, 0x41, ID, 0x41, 0x01, 0x41, X,
        0x10, 0x03, 0x10, 0x00, 0x20, 0x00, 0x10, 0x02,
        // add_event_listener("r","click",$delegate,capture)
        0x41, R, 0x41, 0x01, 0x41, EV, 0x41, 0x05, 0x41, DELEGATE, 0x41, cap, 0x10, 0x04, 0x0b,
    ]);

    let mut code = Vec::new();
    push_uleb(&mut code, 2);
    push_uleb(&mut code, bdel.len() as u32);
    code.extend_from_slice(&bdel);
    push_uleb(&mut code, bst.len() as u32);
    code.extend_from_slice(&bst);
    section(&mut out, 10, &code);

    let mut body = vec![0u8; 0x23 - 0x10];
    let put = |body: &mut Vec<u8>, off: u8, s: &[u8]| {
        body[(off as usize) - 0x10..(off as usize) - 0x10 + s.len()].copy_from_slice(s);
    };
    put(&mut body, ID, b"id");
    put(&mut body, R, b"r");
    put(&mut body, X, b"x");
    put(&mut body, EV, b"click");
    put(&mut body, PH, b"eventPhase");
    let mut data = Vec::new();
    push_uleb(&mut data, 1);
    data.extend_from_slice(&[0x00, 0x41, 0x10, 0x0b]);
    push_uleb(&mut data, body.len() as u32);
    data.extend_from_slice(&body);
    section(&mut out, 11, &data);
    out
}

/// Two listeners on the root: capture `$cap` and bubble `$bub`. A click on
/// the child button grows `__dom` twice (live ≥ 4) only when both records
/// fire — a one-slot overwrite would keep only the second registration.
#[cfg(test)]
pub fn test_module_two_lsn() -> Vec<u8> {
    const ID: u8 = 0x10;
    const R: u8 = 0x12;
    const X: u8 = 0x13;
    const EV: u8 = 0x14;
    const PH: u8 = 0x19;
    const ORD: u8 = 14;
    const CAP: u8 = 6;
    const BUB: u8 = 7;
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();

    let mut types = Vec::new();
    push_uleb(&mut types, 8);
    types.extend_from_slice(&[0x60, 0x00, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x02, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x05, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x06, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x00, 0x00]);
    types.extend_from_slice(&[0x60, 0x03, 0x7f, 0x7f, 0x7f, 0x01, 0x7f]);
    section(&mut out, 1, &types);

    let mut imps = Vec::new();
    push_uleb(&mut imps, 6);
    for (name, ty) in [
        ("getRoot", 0u8),
        ("createElement", 1),
        ("appendChild", 2),
        ("setProperty", 3),
        ("add_event_listener", 4),
        ("Object_Getter__int", 7),
    ] {
        put_name(&mut imps, "env");
        put_name(&mut imps, name);
        imps.push(0x00);
        imps.push(ty);
    }
    section(&mut out, 2, &imps);

    section(&mut out, 3, &[3, 0x05, 0x05, 0x06]); // $cap, $bub, $_start
    section(&mut out, 5, &[1, 0x00, 0x01]);

    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.extend_from_slice(&[0x02, 0x00]);
    put_name(&mut exports, "_start");
    exports.extend_from_slice(&[0x00, 0x08]);
    section(&mut out, 7, &exports);

    let del = |want: u8| -> Vec<u8> {
        let mut b = vec![0x01, 0x01, 0x7f];
        b.extend_from_slice(&[
            0x20, 0x00, 0x41, 0x0a, 0x41, PH, 0x10, 0x05, 0x21, 0x01, 0x20, 0x01, 0x41, want, 0x46,
            0x04, 0x40, 0x10, 0x00, 0x41, ORD, 0x10, 0x01, 0x10, 0x02, 0x0b, 0x0b,
        ]);
        b
    };
    let bcap = del(1);
    let bbub = del(3);

    let mut bst = vec![0x01, 0x01, 0x7f];
    bst.extend_from_slice(&[
        0x10, 0x00, 0x41, 0x02, 0x41, ID, 0x41, 0x01, 0x41, R, 0x10, 0x03, 0x41, ORD, 0x10, 0x01,
        0x21, 0x00, 0x20, 0x00, 0x41, 0x02, 0x41, ID, 0x41, 0x01, 0x41, X, 0x10, 0x03, 0x10, 0x00,
        0x20, 0x00, 0x10, 0x02, 0x41, R, 0x41, 0x01, 0x41, EV, 0x41, 0x05, 0x41, CAP, 0x41, 0x01,
        0x10, 0x04, 0x41, R, 0x41, 0x01, 0x41, EV, 0x41, 0x05, 0x41, BUB, 0x41, 0x00, 0x10, 0x04,
        0x0b,
    ]);

    let mut code = Vec::new();
    push_uleb(&mut code, 3);
    push_uleb(&mut code, bcap.len() as u32);
    code.extend_from_slice(&bcap);
    push_uleb(&mut code, bbub.len() as u32);
    code.extend_from_slice(&bbub);
    push_uleb(&mut code, bst.len() as u32);
    code.extend_from_slice(&bst);
    section(&mut out, 10, &code);

    let mut body = vec![0u8; 0x23 - 0x10];
    let put = |body: &mut Vec<u8>, off: u8, s: &[u8]| {
        body[(off as usize) - 0x10..(off as usize) - 0x10 + s.len()].copy_from_slice(s);
    };
    put(&mut body, ID, b"id");
    put(&mut body, R, b"r");
    put(&mut body, X, b"x");
    put(&mut body, EV, b"click");
    put(&mut body, PH, b"eventPhase");
    let mut data = Vec::new();
    push_uleb(&mut data, 1);
    data.extend_from_slice(&[0x00, 0x41, 0x10, 0x0b]);
    push_uleb(&mut data, body.len() as u32);
    data.extend_from_slice(&body);
    section(&mut out, 11, &data);
    out
}

/// Button keydown listener with `once` (a5=2). `$delegate` always appends.
#[cfg(test)]
pub fn test_module_once() -> Vec<u8> {
    const ID: u8 = 0x10;
    const X: u8 = 0x12;
    const EV: u8 = 0x13;
    const ORD: u8 = 14;
    const DELEGATE: u8 = 5;
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
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
        imps.push(0x00);
        imps.push(ty);
    }
    section(&mut out, 2, &imps);
    section(&mut out, 3, &[2, 0x05, 0x06]);
    section(&mut out, 5, &[1, 0x00, 0x01]);
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.extend_from_slice(&[0x02, 0x00]);
    put_name(&mut exports, "_start");
    exports.extend_from_slice(&[0x00, 0x06]);
    section(&mut out, 7, &exports);
    let mut bdel = vec![0x00];
    bdel.extend_from_slice(&[0x10, 0x00, 0x41, ORD, 0x10, 0x01, 0x10, 0x02, 0x0b]);
    let mut bst = vec![0x01, 0x01, 0x7f];
    bst.extend_from_slice(&[
        0x41, ORD, 0x10, 0x01, 0x21, 0x00, 0x20, 0x00, 0x41, 0x02, 0x41, ID, 0x41, 0x01, 0x41, X,
        0x10, 0x03, 0x10, 0x00, 0x20, 0x00, 0x10, 0x02, 0x41, X, 0x41, 0x01, 0x41, EV, 0x41, 0x07,
        0x41, DELEGATE, 0x41, 0x02, 0x10, 0x04, 0x0b,
    ]);
    let mut code = Vec::new();
    push_uleb(&mut code, 2);
    push_uleb(&mut code, bdel.len() as u32);
    code.extend_from_slice(&bdel);
    push_uleb(&mut code, bst.len() as u32);
    code.extend_from_slice(&bst);
    section(&mut out, 10, &code);
    let mut data = Vec::new();
    push_uleb(&mut data, 1);
    data.extend_from_slice(&[0x00, 0x41, 0x10, 0x0b]);
    let mut body = b"idx".to_vec();
    body.extend_from_slice(b"keydown");
    push_uleb(&mut data, body.len() as u32);
    data.extend_from_slice(&body);
    section(&mut out, 11, &data);
    out
}

/// Click listener with `passive` (a5=4). `$delegate` preventDefaults and
/// appends iff `defaultPrevented` stayed 0.
#[cfg(test)]
pub fn test_module_passive() -> Vec<u8> {
    const ID: u8 = 0x10;
    const X: u8 = 0x12;
    const EV: u8 = 0x13;
    const DP: u8 = 0x18;
    const PD: u8 = 0x28;
    const ORD: u8 = 14;
    const DELEGATE: u8 = 7;
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 9);
    types.extend_from_slice(&[0x60, 0x00, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x02, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x05, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x06, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x00, 0x00]);
    types.extend_from_slice(&[0x60, 0x03, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x03, 0x7f, 0x7f, 0x7f, 0x01, 0x7f]);
    section(&mut out, 1, &types);
    let mut imps = Vec::new();
    push_uleb(&mut imps, 7);
    for (name, ty) in [
        ("getRoot", 0u8),
        ("createElement", 1),
        ("appendChild", 2),
        ("setProperty", 3),
        ("add_event_listener", 4),
        ("Object_Call___void", 7),
        ("Object_Getter__bool", 8),
    ] {
        put_name(&mut imps, "env");
        put_name(&mut imps, name);
        imps.push(0x00);
        imps.push(ty);
    }
    section(&mut out, 2, &imps);
    section(&mut out, 3, &[2, 0x05, 0x06]);
    section(&mut out, 5, &[1, 0x00, 0x01]);
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.extend_from_slice(&[0x02, 0x00]);
    put_name(&mut exports, "_start");
    exports.extend_from_slice(&[0x00, 0x08]);
    section(&mut out, 7, &exports);
    let mut bdel = vec![0x01, 0x01, 0x7f];
    bdel.extend_from_slice(&[
        // preventDefault()
        0x20, 0x00, 0x41, 0x0e, 0x41, PD, 0x10, 0x05, // dp = defaultPrevented
        0x20, 0x00, 0x41, 0x10, 0x41, DP, 0x10, 0x06, 0x21, 0x01, // if dp==0 append
        0x20, 0x01, 0x45, 0x04, 0x40, 0x10, 0x00, 0x41, ORD, 0x10, 0x01, 0x10, 0x02, 0x0b, 0x0b,
    ]);
    let mut bst = vec![0x01, 0x01, 0x7f];
    bst.extend_from_slice(&[
        0x41, ORD, 0x10, 0x01, 0x21, 0x00, 0x20, 0x00, 0x41, 0x02, 0x41, ID, 0x41, 0x01, 0x41, X,
        0x10, 0x03, 0x10, 0x00, 0x20, 0x00, 0x10, 0x02, 0x41, X, 0x41, 0x01, 0x41, EV, 0x41, 0x05,
        0x41, DELEGATE, 0x41, 0x04, 0x10, 0x04, 0x0b,
    ]);
    let mut code = Vec::new();
    push_uleb(&mut code, 2);
    push_uleb(&mut code, bdel.len() as u32);
    code.extend_from_slice(&bdel);
    push_uleb(&mut code, bst.len() as u32);
    code.extend_from_slice(&bst);
    section(&mut out, 10, &code);
    let mut body = vec![0u8; 0x36 - 0x10];
    let put = |body: &mut Vec<u8>, off: u8, s: &str| {
        body[(off as usize) - 0x10..(off as usize) - 0x10 + s.len()].copy_from_slice(s.as_bytes());
    };
    put(&mut body, ID, "id");
    put(&mut body, X, "x");
    put(&mut body, EV, "click");
    put(&mut body, DP, "defaultPrevented");
    put(&mut body, PD, "preventDefault");
    let mut data = Vec::new();
    push_uleb(&mut data, 1);
    data.extend_from_slice(&[0x00, 0x41, 0x10, 0x0b]);
    push_uleb(&mut data, body.len() as u32);
    data.extend_from_slice(&body);
    section(&mut out, 11, &data);
    out
}

/// Registers a click listener then immediately `remove_event_listener`s it.
/// A later click must not append.
#[cfg(test)]
pub fn test_module_rmlsn() -> Vec<u8> {
    const ID: u8 = 0x10;
    const X: u8 = 0x12;
    const EV: u8 = 0x13;
    const ORD: u8 = 14;
    const DELEGATE: u8 = 6;
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
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
    let mut imps = Vec::new();
    push_uleb(&mut imps, 6);
    for (name, ty) in [
        ("getRoot", 0u8),
        ("createElement", 1),
        ("appendChild", 2),
        ("setProperty", 3),
        ("add_event_listener", 4),
        ("remove_event_listener", 5),
    ] {
        put_name(&mut imps, "env");
        put_name(&mut imps, name);
        imps.push(0x00);
        imps.push(ty);
    }
    section(&mut out, 2, &imps);
    section(&mut out, 3, &[2, 0x05, 0x06]);
    section(&mut out, 5, &[1, 0x00, 0x01]);
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.extend_from_slice(&[0x02, 0x00]);
    put_name(&mut exports, "_start");
    exports.extend_from_slice(&[0x00, 0x07]);
    section(&mut out, 7, &exports);
    let mut bdel = vec![0x00];
    bdel.extend_from_slice(&[0x10, 0x00, 0x41, ORD, 0x10, 0x01, 0x10, 0x02, 0x0b]);
    let mut bst = vec![0x01, 0x01, 0x7f];
    bst.extend_from_slice(&[
        0x41, ORD, 0x10, 0x01, 0x21, 0x00, 0x20, 0x00, 0x41, 0x02, 0x41, ID, 0x41, 0x01, 0x41, X,
        0x10, 0x03, 0x10, 0x00, 0x20, 0x00, 0x10, 0x02, 0x41, X, 0x41, 0x01, 0x41, EV, 0x41, 0x05,
        0x41, DELEGATE, 0x41, 0x00, 0x10, 0x04, 0x41, DELEGATE, 0x10, 0x05, 0x0b,
    ]);
    let mut code = Vec::new();
    push_uleb(&mut code, 2);
    push_uleb(&mut code, bdel.len() as u32);
    code.extend_from_slice(&bdel);
    push_uleb(&mut code, bst.len() as u32);
    code.extend_from_slice(&bst);
    section(&mut out, 10, &code);
    let mut data = Vec::new();
    push_uleb(&mut data, 1);
    data.extend_from_slice(&[0x00, 0x41, 0x10, 0x0b]);
    let mut body = b"idx".to_vec();
    body.extend_from_slice(b"click");
    push_uleb(&mut data, body.len() as u32);
    data.extend_from_slice(&body);
    section(&mut out, 11, &data);
    out
}

/// OptionalUint `clientX` (defined, ≥200) and OptionalHandle `relatedTarget`
/// (defined=0). Appends iff both conditions hold.
#[cfg(test)]
pub fn test_module_optional() -> Vec<u8> {
    const ID: u8 = 0x10;
    const X: u8 = 0x12;
    const EV: u8 = 0x13;
    const CX: u8 = 0x18;
    const RT: u8 = 0x1f;
    const SRET_CX: u8 = 0x08;
    const SRET_RT: u8 = 0x00;
    const ORD: u8 = 14;
    const DELEGATE: u8 = 6;
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 8);
    types.extend_from_slice(&[0x60, 0x00, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x02, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x05, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x06, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x00, 0x00]);
    types.extend_from_slice(&[0x60, 0x04, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    section(&mut out, 1, &types);
    let mut imps = Vec::new();
    push_uleb(&mut imps, 6);
    for (name, ty) in [
        ("getRoot", 0u8),
        ("createElement", 1),
        ("appendChild", 2),
        ("setProperty", 3),
        ("add_event_listener", 4),
        ("Object_Getter__OptionalUint", 7),
    ] {
        put_name(&mut imps, "env");
        put_name(&mut imps, name);
        imps.push(0x00);
        imps.push(ty);
    }
    section(&mut out, 2, &imps);
    section(&mut out, 3, &[2, 0x05, 0x06]);
    section(&mut out, 5, &[1, 0x00, 0x01]);
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.extend_from_slice(&[0x02, 0x00]);
    put_name(&mut exports, "_start");
    exports.extend_from_slice(&[0x00, 0x07]);
    section(&mut out, 7, &exports);
    let mut bdel = vec![0x01, 0x01, 0x7f];
    bdel.extend_from_slice(&[
        // OptionalUint(sret_cx, ev, 7, CX)
        0x41, SRET_CX, 0x20, 0x00, 0x41, 0x07, 0x41, CX, 0x10, 0x05,
        // local1 = defined(cx)
        0x41, 0x0c, 0x2d, 0x00, 0x00, 0x21, 0x01,
        // OptionalUint(sret_rt, ev, 13, RT) — relatedTarget as uint-layout none
        0x41, SRET_RT, 0x20, 0x00, 0x41, 0x0d, 0x41, RT, 0x10, 0x05,
        // if defined(cx) && i32.load(cx)>=200 && !defined(rt)
        0x20, 0x01, 0x41, SRET_CX, 0x28, 0x02, 0x00, 0x41, 0xc8, 0x01, 0x4e, 0x71, 0x41, 0x04, 0x2d,
        0x00, 0x00, 0x45, 0x71, 0x04, 0x40, 0x10, 0x00, 0x41, ORD, 0x10, 0x01, 0x10, 0x02, 0x0b,
        0x0b,
    ]);
    let mut bst = vec![0x01, 0x01, 0x7f];
    bst.extend_from_slice(&[
        0x41, ORD, 0x10, 0x01, 0x21, 0x00, 0x20, 0x00, 0x41, 0x02, 0x41, ID, 0x41, 0x01, 0x41, X,
        0x10, 0x03, 0x10, 0x00, 0x20, 0x00, 0x10, 0x02, 0x41, X, 0x41, 0x01, 0x41, EV, 0x41, 0x05,
        0x41, DELEGATE, 0x41, 0x00, 0x10, 0x04, 0x0b,
    ]);
    let mut code = Vec::new();
    push_uleb(&mut code, 2);
    push_uleb(&mut code, bdel.len() as u32);
    code.extend_from_slice(&bdel);
    push_uleb(&mut code, bst.len() as u32);
    code.extend_from_slice(&bst);
    section(&mut out, 10, &code);
    let mut body = vec![0u8; 0x2c - 0x10];
    let put = |body: &mut Vec<u8>, off: u8, s: &str| {
        body[(off as usize) - 0x10..(off as usize) - 0x10 + s.len()].copy_from_slice(s.as_bytes());
    };
    put(&mut body, ID, "id");
    put(&mut body, X, "x");
    put(&mut body, EV, "click");
    put(&mut body, CX, "clientX");
    put(&mut body, RT, "relatedTarget");
    let mut data = Vec::new();
    push_uleb(&mut data, 1);
    data.extend_from_slice(&[0x00, 0x41, 0x10, 0x0b]);
    push_uleb(&mut data, body.len() as u32);
    data.extend_from_slice(&body);
    section(&mut out, 11, &data);
    out
}

/// `Object_Getter__float` of `clientX` ≥ 200.0.
#[cfg(test)]
pub fn test_module_float() -> Vec<u8> {
    const ID: u8 = 0x10;
    const X: u8 = 0x12;
    const EV: u8 = 0x13;
    const CX: u8 = 0x18;
    const ORD: u8 = 14;
    const DELEGATE: u8 = 6;
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 8);
    types.extend_from_slice(&[0x60, 0x00, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x02, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x05, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x06, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x00, 0x00]);
    types.extend_from_slice(&[0x60, 0x03, 0x7f, 0x7f, 0x7f, 0x01, 0x7d]);
    section(&mut out, 1, &types);
    let mut imps = Vec::new();
    push_uleb(&mut imps, 6);
    for (name, ty) in [
        ("getRoot", 0u8),
        ("createElement", 1),
        ("appendChild", 2),
        ("setProperty", 3),
        ("add_event_listener", 4),
        ("Object_Getter__float", 7),
    ] {
        put_name(&mut imps, "env");
        put_name(&mut imps, name);
        imps.push(0x00);
        imps.push(ty);
    }
    section(&mut out, 2, &imps);
    section(&mut out, 3, &[2, 0x05, 0x06]);
    section(&mut out, 5, &[1, 0x00, 0x01]);
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.extend_from_slice(&[0x02, 0x00]);
    put_name(&mut exports, "_start");
    exports.extend_from_slice(&[0x00, 0x07]);
    section(&mut out, 7, &exports);
    let mut bdel = vec![0x00];
    bdel.extend_from_slice(&[
        0x20, 0x00, 0x41, 0x07, 0x41, CX, 0x10, 0x05, 0x43, 0x00, 0x00, 0x48, 0x43, 0x60, 0x04,
        0x40, 0x10, 0x00, 0x41, ORD, 0x10, 0x01, 0x10, 0x02, 0x0b, 0x0b,
    ]);
    let mut bst = vec![0x01, 0x01, 0x7f];
    bst.extend_from_slice(&[
        0x41, ORD, 0x10, 0x01, 0x21, 0x00, 0x20, 0x00, 0x41, 0x02, 0x41, ID, 0x41, 0x01, 0x41, X,
        0x10, 0x03, 0x10, 0x00, 0x20, 0x00, 0x10, 0x02, 0x41, X, 0x41, 0x01, 0x41, EV, 0x41, 0x05,
        0x41, DELEGATE, 0x41, 0x00, 0x10, 0x04, 0x0b,
    ]);
    let mut code = Vec::new();
    push_uleb(&mut code, 2);
    push_uleb(&mut code, bdel.len() as u32);
    code.extend_from_slice(&bdel);
    push_uleb(&mut code, bst.len() as u32);
    code.extend_from_slice(&bst);
    section(&mut out, 10, &code);
    let mut body = vec![0u8; 0x1f - 0x10];
    let put = |body: &mut Vec<u8>, off: u8, s: &str| {
        body[(off as usize) - 0x10..(off as usize) - 0x10 + s.len()].copy_from_slice(s.as_bytes());
    };
    put(&mut body, ID, "id");
    put(&mut body, X, "x");
    put(&mut body, EV, "click");
    put(&mut body, CX, "clientX");
    let mut data = Vec::new();
    push_uleb(&mut data, 1);
    data.extend_from_slice(&[0x00, 0x41, 0x10, 0x0b]);
    push_uleb(&mut data, body.len() as u32);
    data.extend_from_slice(&body);
    section(&mut out, 11, &data);
    out
}

/// `Object_Getter__int` of `button` equals `want` (DOM 0/1/2, not Linux BTN_*).
#[cfg(test)]
pub fn test_module_button_eq(want: u8) -> Vec<u8> {
    const ID: u8 = 0x10;
    const X: u8 = 0x12;
    const EV: u8 = 0x13;
    const BTN: u8 = 0x18;
    const ORD: u8 = 14;
    const DELEGATE: u8 = 6;
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 8);
    types.extend_from_slice(&[0x60, 0x00, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x02, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x05, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x06, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x00, 0x00]);
    types.extend_from_slice(&[0x60, 0x03, 0x7f, 0x7f, 0x7f, 0x01, 0x7f]);
    section(&mut out, 1, &types);
    let mut imps = Vec::new();
    push_uleb(&mut imps, 6);
    for (name, ty) in [
        ("getRoot", 0u8),
        ("createElement", 1),
        ("appendChild", 2),
        ("setProperty", 3),
        ("add_event_listener", 4),
        ("Object_Getter__int", 7),
    ] {
        put_name(&mut imps, "env");
        put_name(&mut imps, name);
        imps.push(0x00);
        imps.push(ty);
    }
    section(&mut out, 2, &imps);
    section(&mut out, 3, &[2, 0x05, 0x06]);
    section(&mut out, 5, &[1, 0x00, 0x01]);
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.extend_from_slice(&[0x02, 0x00]);
    put_name(&mut exports, "_start");
    exports.extend_from_slice(&[0x00, 0x07]);
    section(&mut out, 7, &exports);
    let mut bdel = vec![0x00];
    bdel.extend_from_slice(&[
        0x20, 0x00, 0x41, 0x06, 0x41, BTN, 0x10, 0x05, 0x41, want, 0x46, 0x04, 0x40, 0x10, 0x00,
        0x41, ORD, 0x10, 0x01, 0x10, 0x02, 0x0b, 0x0b,
    ]);
    let mut bst = vec![0x01, 0x01, 0x7f];
    bst.extend_from_slice(&[
        0x41, ORD, 0x10, 0x01, 0x21, 0x00, 0x20, 0x00, 0x41, 0x02, 0x41, ID, 0x41, 0x01, 0x41, X,
        0x10, 0x03, 0x10, 0x00, 0x20, 0x00, 0x10, 0x02, 0x41, X, 0x41, 0x01, 0x41, EV, 0x41, 0x05,
        0x41, DELEGATE, 0x41, 0x00, 0x10, 0x04, 0x0b,
    ]);
    let mut code = Vec::new();
    push_uleb(&mut code, 2);
    push_uleb(&mut code, bdel.len() as u32);
    code.extend_from_slice(&bdel);
    push_uleb(&mut code, bst.len() as u32);
    code.extend_from_slice(&bst);
    section(&mut out, 10, &code);
    let mut body = vec![0u8; 0x1e - 0x10];
    let put = |body: &mut Vec<u8>, off: u8, s: &str| {
        body[(off as usize) - 0x10..(off as usize) - 0x10 + s.len()].copy_from_slice(s.as_bytes());
    };
    put(&mut body, ID, "id");
    put(&mut body, X, "x");
    put(&mut body, EV, "click");
    put(&mut body, BTN, "button");
    let mut data = Vec::new();
    push_uleb(&mut data, 1);
    data.extend_from_slice(&[0x00, 0x41, 0x10, 0x0b]);
    push_uleb(&mut data, body.len() as u32);
    data.extend_from_slice(&body);
    section(&mut out, 11, &data);
    out
}

/// `Object_Getter__bool` of `shiftKey` is true.
#[cfg(test)]
pub fn test_module_shiftkey() -> Vec<u8> {
    const ID: u8 = 0x10;
    const X: u8 = 0x12;
    const EV: u8 = 0x13;
    const SK: u8 = 0x18;
    const ORD: u8 = 14;
    const DELEGATE: u8 = 6;
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 8);
    types.extend_from_slice(&[0x60, 0x00, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x02, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x05, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x06, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x00, 0x00]);
    types.extend_from_slice(&[0x60, 0x03, 0x7f, 0x7f, 0x7f, 0x01, 0x7f]);
    section(&mut out, 1, &types);
    let mut imps = Vec::new();
    push_uleb(&mut imps, 6);
    for (name, ty) in [
        ("getRoot", 0u8),
        ("createElement", 1),
        ("appendChild", 2),
        ("setProperty", 3),
        ("add_event_listener", 4),
        ("Object_Getter__bool", 7),
    ] {
        put_name(&mut imps, "env");
        put_name(&mut imps, name);
        imps.push(0x00);
        imps.push(ty);
    }
    section(&mut out, 2, &imps);
    section(&mut out, 3, &[2, 0x05, 0x06]);
    section(&mut out, 5, &[1, 0x00, 0x01]);
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.extend_from_slice(&[0x02, 0x00]);
    put_name(&mut exports, "_start");
    exports.extend_from_slice(&[0x00, 0x07]);
    section(&mut out, 7, &exports);
    let mut bdel = vec![0x00];
    bdel.extend_from_slice(&[
        0x20, 0x00, 0x41, 0x08, 0x41, SK, 0x10, 0x05, 0x04, 0x40, 0x10, 0x00, 0x41, ORD, 0x10,
        0x01, 0x10, 0x02, 0x0b, 0x0b,
    ]);
    let mut bst = vec![0x01, 0x01, 0x7f];
    bst.extend_from_slice(&[
        0x41, ORD, 0x10, 0x01, 0x21, 0x00, 0x20, 0x00, 0x41, 0x02, 0x41, ID, 0x41, 0x01, 0x41, X,
        0x10, 0x03, 0x10, 0x00, 0x20, 0x00, 0x10, 0x02, 0x41, X, 0x41, 0x01, 0x41, EV, 0x41, 0x05,
        0x41, DELEGATE, 0x41, 0x00, 0x10, 0x04, 0x0b,
    ]);
    let mut code = Vec::new();
    push_uleb(&mut code, 2);
    push_uleb(&mut code, bdel.len() as u32);
    code.extend_from_slice(&bdel);
    push_uleb(&mut code, bst.len() as u32);
    code.extend_from_slice(&bst);
    section(&mut out, 10, &code);
    let mut body = vec![0u8; 0x20 - 0x10];
    let put = |body: &mut Vec<u8>, off: u8, s: &str| {
        body[(off as usize) - 0x10..(off as usize) - 0x10 + s.len()].copy_from_slice(s.as_bytes());
    };
    put(&mut body, ID, "id");
    put(&mut body, X, "x");
    put(&mut body, EV, "click");
    put(&mut body, SK, "shiftKey");
    let mut data = Vec::new();
    push_uleb(&mut data, 1);
    data.extend_from_slice(&[0x00, 0x41, 0x10, 0x0b]);
    push_uleb(&mut data, body.len() as u32);
    data.extend_from_slice(&body);
    section(&mut out, 11, &data);
    out
}

/// `<input id="x">` with optional `type=password` and `value`.
#[cfg(test)]
pub fn test_module_password_input(password: bool, value: &str) -> Vec<u8> {
    const ID: u8 = 0x10;
    const X: u8 = 0x12;
    const TY: u8 = 0x13;
    const PW: u8 = 0x17;
    const VL: u8 = 0x1f;
    const VAL: u8 = 0x24;
    const TX: u8 = 0x2c;
    const ORD: u8 = 49; // NodeType::input
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 5);
    types.extend_from_slice(&[0x60, 0x00, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x02, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x05, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x00, 0x00]);
    section(&mut out, 1, &types);
    let mut imps = Vec::new();
    push_uleb(&mut imps, 4);
    for (name, ty) in [
        ("getRoot", 0u8),
        ("createElement", 1),
        ("appendChild", 2),
        ("setProperty", 3),
    ] {
        put_name(&mut imps, "env");
        put_name(&mut imps, name);
        imps.push(0x00);
        imps.push(ty);
    }
    section(&mut out, 2, &imps);
    section(&mut out, 3, &[1, 0x04]); // $_start t4 → func 4
    section(&mut out, 5, &[1, 0x00, 0x01]);
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.extend_from_slice(&[0x02, 0x00]);
    put_name(&mut exports, "_start");
    exports.extend_from_slice(&[0x00, 0x04]);
    section(&mut out, 7, &exports);
    let mut bst = vec![0x01, 0x01, 0x7f];
    bst.extend_from_slice(&[
        0x41, ORD, 0x10, 0x01, 0x21, 0x00, // el = createElement(input)
        0x20, 0x00, 0x41, 0x02, 0x41, ID, 0x41, 0x01, 0x41, X, 0x10, 0x03, // id="x"
    ]);
    if password {
        bst.extend_from_slice(&[
            0x20, 0x00, 0x41, 0x04, 0x41, TY, 0x41, 0x08, 0x41, PW, 0x10, 0x03,
        ]);
    } else {
        bst.extend_from_slice(&[
            0x20, 0x00, 0x41, 0x04, 0x41, TY, 0x41, 0x04, 0x41, TX, 0x10, 0x03,
        ]);
    }
    if !value.is_empty() {
        bst.extend_from_slice(&[
            0x20,
            0x00,
            0x41,
            0x05,
            0x41,
            VL,
            0x41,
            value.len() as u8,
            0x41,
            VAL,
            0x10,
            0x03,
        ]);
    }
    bst.extend_from_slice(&[
        0x10, 0x00, 0x20, 0x00, 0x10, 0x02, // appendChild(root, el)
        0x0b,
    ]);
    let mut code = Vec::new();
    push_uleb(&mut code, 1);
    push_uleb(&mut code, bst.len() as u32);
    code.extend_from_slice(&bst);
    section(&mut out, 10, &code);
    let mut body = vec![0u8; 0x30 - 0x10];
    let put = |body: &mut Vec<u8>, off: u8, s: &str| {
        body[(off as usize) - 0x10..(off as usize) - 0x10 + s.len()].copy_from_slice(s.as_bytes());
    };
    put(&mut body, ID, "id");
    put(&mut body, X, "x");
    put(&mut body, TY, "type");
    put(&mut body, PW, "password");
    put(&mut body, TX, "text");
    put(&mut body, VL, "value");
    if !value.is_empty() {
        put(&mut body, VAL, value);
    }
    let mut data = Vec::new();
    push_uleb(&mut data, 1);
    data.extend_from_slice(&[0x00, 0x41, 0x10, 0x0b]);
    push_uleb(&mut data, body.len() as u32);
    data.extend_from_slice(&body);
    section(&mut out, 11, &data);
    out
}

/// `Object_Getter__double` of `clientX` ≥ 200.0.
#[cfg(test)]
pub fn test_module_double() -> Vec<u8> {
    const ID: u8 = 0x10;
    const X: u8 = 0x12;
    const EV: u8 = 0x13;
    const CX: u8 = 0x18;
    const ORD: u8 = 14;
    const DELEGATE: u8 = 6;
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 8);
    types.extend_from_slice(&[0x60, 0x00, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x02, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x05, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x06, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x00, 0x00]);
    types.extend_from_slice(&[0x60, 0x03, 0x7f, 0x7f, 0x7f, 0x01, 0x7c]);
    section(&mut out, 1, &types);
    let mut imps = Vec::new();
    push_uleb(&mut imps, 6);
    for (name, ty) in [
        ("getRoot", 0u8),
        ("createElement", 1),
        ("appendChild", 2),
        ("setProperty", 3),
        ("add_event_listener", 4),
        ("Object_Getter__double", 7),
    ] {
        put_name(&mut imps, "env");
        put_name(&mut imps, name);
        imps.push(0x00);
        imps.push(ty);
    }
    section(&mut out, 2, &imps);
    section(&mut out, 3, &[2, 0x05, 0x06]);
    section(&mut out, 5, &[1, 0x00, 0x01]);
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.extend_from_slice(&[0x02, 0x00]);
    put_name(&mut exports, "_start");
    exports.extend_from_slice(&[0x00, 0x07]);
    section(&mut out, 7, &exports);
    let mut bdel = vec![0x00];
    bdel.extend_from_slice(&[
        0x20, 0x00, 0x41, 0x07, 0x41, CX, 0x10, 0x05, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x69, 0x40, 0x66, 0x04, 0x40, 0x10, 0x00, 0x41, ORD, 0x10, 0x01, 0x10, 0x02, 0x0b, 0x0b,
    ]);
    let mut bst = vec![0x01, 0x01, 0x7f];
    bst.extend_from_slice(&[
        0x41, ORD, 0x10, 0x01, 0x21, 0x00, 0x20, 0x00, 0x41, 0x02, 0x41, ID, 0x41, 0x01, 0x41, X,
        0x10, 0x03, 0x10, 0x00, 0x20, 0x00, 0x10, 0x02, 0x41, X, 0x41, 0x01, 0x41, EV, 0x41, 0x05,
        0x41, DELEGATE, 0x41, 0x00, 0x10, 0x04, 0x0b,
    ]);
    let mut code = Vec::new();
    push_uleb(&mut code, 2);
    push_uleb(&mut code, bdel.len() as u32);
    code.extend_from_slice(&bdel);
    push_uleb(&mut code, bst.len() as u32);
    code.extend_from_slice(&bst);
    section(&mut out, 10, &code);
    let mut body = vec![0u8; 0x1f - 0x10];
    let put = |body: &mut Vec<u8>, off: u8, s: &str| {
        body[(off as usize) - 0x10..(off as usize) - 0x10 + s.len()].copy_from_slice(s.as_bytes());
    };
    put(&mut body, ID, "id");
    put(&mut body, X, "x");
    put(&mut body, EV, "click");
    put(&mut body, CX, "clientX");
    let mut data = Vec::new();
    push_uleb(&mut data, 1);
    data.extend_from_slice(&[0x00, 0x41, 0x10, 0x0b]);
    push_uleb(&mut data, body.len() as u32);
    data.extend_from_slice(&body);
    section(&mut out, 11, &data);
    out
}

/// `Object_Getter__double` of `timeStamp` > 0.0 (csr time at fill).
#[cfg(test)]
pub fn test_module_timestamp() -> Vec<u8> {
    const ID: u8 = 0x10;
    const X: u8 = 0x12;
    const EV: u8 = 0x13;
    const TS: u8 = 0x18;
    const ORD: u8 = 14;
    const DELEGATE: u8 = 6;
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 8);
    types.extend_from_slice(&[0x60, 0x00, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x02, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x05, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x06, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x00, 0x00]);
    types.extend_from_slice(&[0x60, 0x03, 0x7f, 0x7f, 0x7f, 0x01, 0x7c]);
    section(&mut out, 1, &types);
    let mut imps = Vec::new();
    push_uleb(&mut imps, 6);
    for (name, ty) in [
        ("getRoot", 0u8),
        ("createElement", 1),
        ("appendChild", 2),
        ("setProperty", 3),
        ("add_event_listener", 4),
        ("Object_Getter__double", 7),
    ] {
        put_name(&mut imps, "env");
        put_name(&mut imps, name);
        imps.push(0x00);
        imps.push(ty);
    }
    section(&mut out, 2, &imps);
    section(&mut out, 3, &[2, 0x05, 0x06]);
    section(&mut out, 5, &[1, 0x00, 0x01]);
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.extend_from_slice(&[0x02, 0x00]);
    put_name(&mut exports, "_start");
    exports.extend_from_slice(&[0x00, 0x07]);
    section(&mut out, 7, &exports);
    let mut bdel = vec![0x00];
    bdel.extend_from_slice(&[
        0x20, 0x00, 0x41, 0x09, 0x41, TS, 0x10, 0x05, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x64, 0x04, 0x40, 0x10, 0x00, 0x41, ORD, 0x10, 0x01, 0x10, 0x02, 0x0b, 0x0b,
    ]);
    let mut bst = vec![0x01, 0x01, 0x7f];
    bst.extend_from_slice(&[
        0x41, ORD, 0x10, 0x01, 0x21, 0x00, 0x20, 0x00, 0x41, 0x02, 0x41, ID, 0x41, 0x01, 0x41, X,
        0x10, 0x03, 0x10, 0x00, 0x20, 0x00, 0x10, 0x02, 0x41, X, 0x41, 0x01, 0x41, EV, 0x41, 0x05,
        0x41, DELEGATE, 0x41, 0x00, 0x10, 0x04, 0x0b,
    ]);
    let mut code = Vec::new();
    push_uleb(&mut code, 2);
    push_uleb(&mut code, bdel.len() as u32);
    code.extend_from_slice(&bdel);
    push_uleb(&mut code, bst.len() as u32);
    code.extend_from_slice(&bst);
    section(&mut out, 10, &code);
    let mut body = vec![0u8; 0x21 - 0x10];
    let put = |body: &mut Vec<u8>, off: u8, s: &str| {
        body[(off as usize) - 0x10..(off as usize) - 0x10 + s.len()].copy_from_slice(s.as_bytes());
    };
    put(&mut body, ID, "id");
    put(&mut body, X, "x");
    put(&mut body, EV, "click");
    put(&mut body, TS, "timeStamp");
    let mut data = Vec::new();
    push_uleb(&mut data, 1);
    data.extend_from_slice(&[0x00, 0x41, 0x10, 0x0b]);
    push_uleb(&mut data, body.len() as u32);
    data.extend_from_slice(&body);
    section(&mut out, 11, &data);
    out
}

/// `Object_Getter__uint` of `deltaMode` == 1 (`DOM_DELTA_LINE`) on wheel.
#[cfg(test)]
pub fn test_module_delta_mode() -> Vec<u8> {
    const ID: u8 = 0x10;
    const X: u8 = 0x12;
    const EV: u8 = 0x13;
    const DM: u8 = 0x18;
    const ORD: u8 = 14;
    const DELEGATE: u8 = 6;
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 8);
    types.extend_from_slice(&[0x60, 0x00, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x02, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x05, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x06, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x00, 0x00]);
    types.extend_from_slice(&[0x60, 0x03, 0x7f, 0x7f, 0x7f, 0x01, 0x7f]);
    section(&mut out, 1, &types);
    let mut imps = Vec::new();
    push_uleb(&mut imps, 6);
    for (name, ty) in [
        ("getRoot", 0u8),
        ("createElement", 1),
        ("appendChild", 2),
        ("setProperty", 3),
        ("add_event_listener", 4),
        ("Object_Getter__uint", 7),
    ] {
        put_name(&mut imps, "env");
        put_name(&mut imps, name);
        imps.push(0x00);
        imps.push(ty);
    }
    section(&mut out, 2, &imps);
    section(&mut out, 3, &[2, 0x05, 0x06]);
    section(&mut out, 5, &[1, 0x00, 0x01]);
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.extend_from_slice(&[0x02, 0x00]);
    put_name(&mut exports, "_start");
    exports.extend_from_slice(&[0x00, 0x07]);
    section(&mut out, 7, &exports);
    let mut bdel = vec![0x00];
    bdel.extend_from_slice(&[
        0x20, 0x00, 0x41, 0x09, 0x41, DM, 0x10, 0x05, 0x41, 0x01, 0x46, 0x04, 0x40, 0x10, 0x00,
        0x41, ORD, 0x10, 0x01, 0x10, 0x02, 0x0b, 0x0b,
    ]);
    let mut bst = vec![0x01, 0x01, 0x7f];
    bst.extend_from_slice(&[
        0x41, ORD, 0x10, 0x01, 0x21, 0x00, 0x20, 0x00, 0x41, 0x02, 0x41, ID, 0x41, 0x01, 0x41, X,
        0x10, 0x03, 0x10, 0x00, 0x20, 0x00, 0x10, 0x02, 0x41, X, 0x41, 0x01, 0x41, EV, 0x41, 0x05,
        0x41, DELEGATE, 0x41, 0x00, 0x10, 0x04, 0x0b,
    ]);
    let mut code = Vec::new();
    push_uleb(&mut code, 2);
    push_uleb(&mut code, bdel.len() as u32);
    code.extend_from_slice(&bdel);
    push_uleb(&mut code, bst.len() as u32);
    code.extend_from_slice(&bst);
    section(&mut out, 10, &code);
    let mut body = vec![0u8; 0x21 - 0x10];
    let put = |body: &mut Vec<u8>, off: u8, s: &str| {
        body[(off as usize) - 0x10..(off as usize) - 0x10 + s.len()].copy_from_slice(s.as_bytes());
    };
    put(&mut body, ID, "id");
    put(&mut body, X, "x");
    put(&mut body, EV, "wheel");
    put(&mut body, DM, "deltaMode");
    let mut data = Vec::new();
    push_uleb(&mut data, 1);
    data.extend_from_slice(&[0x00, 0x41, 0x10, 0x0b]);
    push_uleb(&mut data, body.len() as u32);
    data.extend_from_slice(&body);
    section(&mut out, 11, &data);
    out
}

/// OptionalString `type` is defined and len==5 (`"click"`).
#[cfg(test)]
pub fn test_module_optional_string() -> Vec<u8> {
    const ID: u8 = 0x10;
    const X: u8 = 0x12;
    const EV: u8 = 0x13;
    const TY: u8 = 0x18;
    const SRET: u8 = 0x08;
    const ORD: u8 = 14;
    const DELEGATE: u8 = 6;
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 8);
    types.extend_from_slice(&[0x60, 0x00, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x02, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x05, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x06, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x00, 0x00]);
    types.extend_from_slice(&[0x60, 0x04, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    section(&mut out, 1, &types);
    let mut imps = Vec::new();
    push_uleb(&mut imps, 6);
    for (name, ty) in [
        ("getRoot", 0u8),
        ("createElement", 1),
        ("appendChild", 2),
        ("setProperty", 3),
        ("add_event_listener", 4),
        ("Object_Getter__OptionalString", 7),
    ] {
        put_name(&mut imps, "env");
        put_name(&mut imps, name);
        imps.push(0x00);
        imps.push(ty);
    }
    section(&mut out, 2, &imps);
    section(&mut out, 3, &[2, 0x05, 0x06]);
    section(&mut out, 5, &[1, 0x00, 0x01]);
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.extend_from_slice(&[0x02, 0x00]);
    put_name(&mut exports, "_start");
    exports.extend_from_slice(&[0x00, 0x07]);
    section(&mut out, 7, &exports);
    let mut bdel = vec![0x01, 0x01, 0x7f];
    bdel.extend_from_slice(&[
        0x41, SRET, 0x20, 0x00, 0x41, 0x04, 0x41, TY, 0x10, 0x05, 0x41, SRET, 0x28, 0x02, 0x00,
        0x21, 0x01, 0x20, 0x01, 0x41, 0x05, 0x46, 0x41, SRET, 0x41, 0x08, 0x6a, 0x2d, 0x00, 0x00,
        0x41, 0x01, 0x46, 0x71, 0x04, 0x40, 0x10, 0x00, 0x41, ORD, 0x10, 0x01, 0x10, 0x02, 0x0b,
        0x0b,
    ]);
    let mut bst = vec![0x01, 0x01, 0x7f];
    bst.extend_from_slice(&[
        0x41, ORD, 0x10, 0x01, 0x21, 0x00, 0x20, 0x00, 0x41, 0x02, 0x41, ID, 0x41, 0x01, 0x41, X,
        0x10, 0x03, 0x10, 0x00, 0x20, 0x00, 0x10, 0x02, 0x41, X, 0x41, 0x01, 0x41, EV, 0x41, 0x05,
        0x41, DELEGATE, 0x41, 0x00, 0x10, 0x04, 0x0b,
    ]);
    let mut code = Vec::new();
    push_uleb(&mut code, 2);
    push_uleb(&mut code, bdel.len() as u32);
    code.extend_from_slice(&bdel);
    push_uleb(&mut code, bst.len() as u32);
    code.extend_from_slice(&bst);
    section(&mut out, 10, &code);
    let mut body = vec![0u8; 0x1c - 0x10];
    let put = |body: &mut Vec<u8>, off: u8, s: &str| {
        body[(off as usize) - 0x10..(off as usize) - 0x10 + s.len()].copy_from_slice(s.as_bytes());
    };
    put(&mut body, ID, "id");
    put(&mut body, X, "x");
    put(&mut body, EV, "click");
    put(&mut body, TY, "type");
    let mut data = Vec::new();
    push_uleb(&mut data, 1);
    data.extend_from_slice(&[0x00, 0x41, 0x10, 0x0b]);
    push_uleb(&mut data, body.len() as u32);
    data.extend_from_slice(&body);
    section(&mut out, 11, &data);
    out
}

/// OptionalBool `bubbles` defined=1 value=1, OptionalDouble `clientX` defined
/// and ≥ 200.0.
#[cfg(test)]
pub fn test_module_optional_bool_double() -> Vec<u8> {
    const ID: u8 = 0x10;
    const X: u8 = 0x12;
    const EV: u8 = 0x13;
    const BUB: u8 = 0x18;
    const CX: u8 = 0x1f;
    const SRET_B: u8 = 0x00;
    const SRET_D: u8 = 0x28;
    const ORD: u8 = 14;
    const DELEGATE: u8 = 7;
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 9);
    types.extend_from_slice(&[0x60, 0x00, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x01, 0x7f]);
    types.extend_from_slice(&[0x60, 0x02, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x05, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x06, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x01, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x00, 0x00]);
    types.extend_from_slice(&[0x60, 0x04, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    types.extend_from_slice(&[0x60, 0x04, 0x7f, 0x7f, 0x7f, 0x7f, 0x00]);
    section(&mut out, 1, &types);
    let mut imps = Vec::new();
    push_uleb(&mut imps, 7);
    for (name, ty) in [
        ("getRoot", 0u8),
        ("createElement", 1),
        ("appendChild", 2),
        ("setProperty", 3),
        ("add_event_listener", 4),
        ("Object_Getter__OptionalBool", 7),
        ("Object_Getter__OptionalDouble", 8),
    ] {
        put_name(&mut imps, "env");
        put_name(&mut imps, name);
        imps.push(0x00);
        imps.push(ty);
    }
    section(&mut out, 2, &imps);
    section(&mut out, 3, &[2, 0x05, 0x06]);
    section(&mut out, 5, &[1, 0x00, 0x01]);
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.extend_from_slice(&[0x02, 0x00]);
    put_name(&mut exports, "_start");
    exports.extend_from_slice(&[0x00, 0x08]);
    section(&mut out, 7, &exports);
    let mut bdel = vec![0x01, 0x01, 0x7f];
    bdel.extend_from_slice(&[
        // OptionalBool(sret_b, ev, 7, BUB)
        0x41, SRET_B, 0x20, 0x00, 0x41, 0x07, 0x41, BUB, 0x10, 0x05,
        // OptionalDouble(sret_d, ev, 7, CX)
        0x41, SRET_D, 0x20, 0x00, 0x41, 0x07, 0x41, CX, 0x10, 0x06,
        // defined(b) && value(b) && defined(d) && f64.load(d) >= 200.0
        0x41, SRET_B, 0x2d, 0x00, 0x01, 0x41, SRET_B, 0x2d, 0x00, 0x00, 0x71, 0x41, SRET_D, 0x2d,
        0x00, 0x08, 0x71, 0x41, SRET_D, 0x2b, 0x03, 0x00, 0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
        0x69, 0x40, 0x66, 0x71, 0x04, 0x40, 0x10, 0x00, 0x41, ORD, 0x10, 0x01, 0x10, 0x02, 0x0b,
        0x0b,
    ]);
    let mut bst = vec![0x01, 0x01, 0x7f];
    bst.extend_from_slice(&[
        0x41, ORD, 0x10, 0x01, 0x21, 0x00, 0x20, 0x00, 0x41, 0x02, 0x41, ID, 0x41, 0x01, 0x41, X,
        0x10, 0x03, 0x10, 0x00, 0x20, 0x00, 0x10, 0x02, 0x41, X, 0x41, 0x01, 0x41, EV, 0x41, 0x05,
        0x41, DELEGATE, 0x41, 0x00, 0x10, 0x04, 0x0b,
    ]);
    let mut code = Vec::new();
    push_uleb(&mut code, 2);
    push_uleb(&mut code, bdel.len() as u32);
    code.extend_from_slice(&bdel);
    push_uleb(&mut code, bst.len() as u32);
    code.extend_from_slice(&bst);
    section(&mut out, 10, &code);
    let mut body = vec![0u8; 0x26 - 0x10];
    let put = |body: &mut Vec<u8>, off: u8, s: &str| {
        body[(off as usize) - 0x10..(off as usize) - 0x10 + s.len()].copy_from_slice(s.as_bytes());
    };
    put(&mut body, ID, "id");
    put(&mut body, X, "x");
    put(&mut body, EV, "click");
    put(&mut body, BUB, "bubbles");
    put(&mut body, CX, "clientX");
    let mut data = Vec::new();
    push_uleb(&mut data, 1);
    data.extend_from_slice(&[0x00, 0x41, 0x10, 0x0b]);
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
    let coverage = op_coverage(wasm)?;
    if !coverage.clean() {
        return Err(format!(
            "guest JIT preflight: {} reachable gap(s): {}",
            coverage.gaps.len(),
            coverage
                .gaps
                .iter()
                .take(8)
                .map(OpGap::describe)
                .collect::<Vec<_>>()
                .join("; ")
        ));
    }
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
    assert!(
        at <= 0x40,
        "delegate pool must stay under the 1B-i32.const bound"
    );
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
        0x20, 0x00, // local.get 0 (root)
        0x41, 0x02, 0x41, id, //   namelen=2 nameptr=id  ("id")
        0x41, 0x01, 0x41, r, //   vallen=1  valptr=r    ("r")
        0x10, 0x03, // setProperty(root,"id","r") — len-first ABI
        0x20, 0x00, // local.get 0 (root)
        0x41, 0x09, 0x41, it, //   namelen=9 nameptr=it  ("innerText")
        0x41, 0x05, 0x41, rdy, //   vallen=5  valptr=rdy  ("READY")
        0x10, 0x03, // setProperty(root,"innerText","READY")
        0x41, r, 0x41, 0x01, // tptr=r tlen=1           ("r")   ptr-first ABI
        0x41, evp, 0x41, evlen, // typtr=evp tylen=evlen  (<ev>)
        0x41, DELEGATE, // cb = $delegate funcidx 5
        0x41, 0x00, // capture = 0
        0x10, 0x04, // add_event_listener("r",<ev>,5,0)
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
    types.extend_from_slice(&[0x60, 0, 0]); // t1 ()->()
    section(&mut out, 1, &types);
    section(&mut out, 3, &[2, 1, 0]); // f0=t1 thrower, f1=t0 _start
    section(&mut out, 5, &[1, 0x00, 0x01]); // memory 1 page
    section(&mut out, 13, &[1, 0x00, 1]); // 1 tag, attr 0, typeidx 1 (()->())
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
        0x00, // locals=0
        0x06, 0x7f, // try (result i32)
        0x10, 0x00, //   call 0 (thrower)
        0x41, 0x00, //   i32.const 0   (unreached)
        0x19, // catch_all
        0x41, 0x89, 0x06, //   i32.const 777
        0x0b, // end try
        0x0b, // end func
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

/// Two-cell tagged throw: callee pushes 3 then 4; caller `catch $e` adds them.
/// ```wat
/// (tag $e (param i32 i32))
/// (func $thrower i32.const 3 i32.const 4 throw $e)
/// (func $_start (result i32)
///   try (result i32) call $thrower i32.const 0
///   catch $e i32.add end)
/// ```
#[cfg(test)]
pub fn test_module_eh_payload2() -> Vec<u8> {
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 3);
    types.extend_from_slice(&[0x60, 0, 1, 0x7f]); // t0 ()->i32
    types.extend_from_slice(&[0x60, 0, 0]); // t1 ()->()
    types.extend_from_slice(&[0x60, 2, 0x7f, 0x7f, 0]); // t2 (i32,i32)->()
    section(&mut out, 1, &types);
    section(&mut out, 3, &[2, 1, 0]);
    section(&mut out, 5, &[1, 0x00, 0x01]);
    section(&mut out, 13, &[1, 0x00, 2]); // tag typeidx 2
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.push(0x02);
    push_uleb(&mut exports, 0);
    put_name(&mut exports, "_start");
    exports.push(0x00);
    push_uleb(&mut exports, 1);
    section(&mut out, 7, &exports);
    let b0 = [0x00, 0x41, 0x03, 0x41, 0x04, 0x08, 0x00, 0x0b]; // 3, 4, throw
    let b1 = [
        0x00, // locals
        0x06, 0x7f, // try (result i32)
        0x10, 0x00, //   call 0
        0x41, 0x00, //   i32.const 0
        0x07, 0x00, // catch 0
        0x6a, //   i32.add
        0x0b, // end try
        0x0b, // end func
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

/// Nested `rethrow 0` in the same function: inner catch rethrows into the
/// outer `catch $e`, which yields the payload 7.
#[cfg(test)]
pub fn test_module_eh_rethrow_nested() -> Vec<u8> {
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 2);
    types.extend_from_slice(&[0x60, 0, 1, 0x7f]);
    types.extend_from_slice(&[0x60, 1, 0x7f, 0]);
    section(&mut out, 1, &types);
    section(&mut out, 3, &[1, 0]);
    section(&mut out, 5, &[1, 0x00, 0x01]);
    section(&mut out, 13, &[1, 0x00, 1]);
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.push(0x02);
    push_uleb(&mut exports, 0);
    put_name(&mut exports, "_start");
    exports.push(0x00);
    push_uleb(&mut exports, 0);
    section(&mut out, 7, &exports);
    let b0 = [
        0x00, // locals
        0x06, 0x7f, // try (result i32)
        0x06, 0x40, //   try (empty)
        0x41, 0x07, //     i32.const 7
        0x08, 0x00, //     throw 0
        0x07, 0x00, //   catch 0
        0x09, 0x00, //     rethrow 0
        0x0b, //   end inner
        0x41, 0x00, //   i32.const 0
        0x07, 0x00, // catch 0
        0x0b, // end outer
        0x0b,
    ];
    let mut code = Vec::new();
    push_uleb(&mut code, 1);
    push_uleb(&mut code, b0.len() as u32);
    code.extend_from_slice(&b0);
    section(&mut out, 10, &code);
    out
}

/// Cross-function `rethrow`: callee catches then `rethrow 0`; caller catch
/// must see payload 7.
#[cfg(test)]
pub fn test_module_eh_rethrow_escape() -> Vec<u8> {
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 3);
    types.extend_from_slice(&[0x60, 0, 1, 0x7f]);
    types.extend_from_slice(&[0x60, 0, 0]);
    types.extend_from_slice(&[0x60, 1, 0x7f, 0]);
    section(&mut out, 1, &types);
    section(&mut out, 3, &[2, 1, 0]);
    section(&mut out, 5, &[1, 0x00, 0x01]);
    section(&mut out, 13, &[1, 0x00, 2]);
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.push(0x02);
    push_uleb(&mut exports, 0);
    put_name(&mut exports, "_start");
    exports.push(0x00);
    push_uleb(&mut exports, 1);
    section(&mut out, 7, &exports);
    let b0 = [
        0x00, // inner: try { const 7; throw } catch { rethrow 0 }
        0x06, 0x40, 0x41, 0x07, 0x08, 0x00, 0x07, 0x00, 0x09, 0x00, 0x0b, 0x0b,
    ];
    let b1 = [
        0x00, // _start
        0x06, 0x7f, // try (result i32)
        0x10, 0x00, //   call 0
        0x41, 0x00, //   i32.const 0
        0x07, 0x00, // catch 0
        0x0b, 0x0b,
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

/// `rethrow 0` into an enclosing `try_table` catch dest: payload 7.
/// ```wat
/// (tag $e (param i32))
/// (func $_start (result i32)
///   (block (result i32)
///     (try_table (catch $e 0)
///       try
///         i32.const 7 throw $e
///       catch $e
///         rethrow 0
///       end
///       unreachable)))
/// ```
#[cfg(test)]
pub fn test_module_eh_rethrow_try_table() -> Vec<u8> {
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 2);
    types.extend_from_slice(&[0x60, 0, 1, 0x7f]);
    types.extend_from_slice(&[0x60, 1, 0x7f, 0]);
    section(&mut out, 1, &types);
    section(&mut out, 3, &[1, 0]);
    section(&mut out, 5, &[1, 0x00, 0x01]);
    section(&mut out, 13, &[1, 0x00, 1]);
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.push(0x02);
    push_uleb(&mut exports, 0);
    put_name(&mut exports, "_start");
    exports.push(0x00);
    push_uleb(&mut exports, 0);
    section(&mut out, 7, &exports);
    let b0 = [
        0x00, // locals
        0x02, 0x7f, // block (result i32)
        0x1f, 0x40, //   try_table empty
        0x01, //   1 catch
        0x00, 0x00, 0x00, //   catch tag0 label0
        0x06, 0x40, //     try empty
        0x41, 0x07, //       i32.const 7
        0x08, 0x00, //       throw 0
        0x07, 0x00, //     catch 0
        0x09, 0x00, //       rethrow 0
        0x0b, //     end try
        0x0b, //   end try_table
        0x00, // unreachable
        0x0b, // end block
        0x0b,
    ];
    let mut code = Vec::new();
    push_uleb(&mut code, 1);
    push_uleb(&mut code, b0.len() as u32);
    code.extend_from_slice(&b0);
    section(&mut out, 10, &code);
    out
}

/// Same-function `catch_all_ref` + `throw_ref`: local throw 7 is packaged as
/// an exnref, then `throw_ref` rethrows into the outer `catch $e` dest.
/// ```wat
/// (tag $e (param i32))
/// (func $_start (result i32)
///   (block (result i32)
///     (try_table (catch $e 0)
///       (block (result i32)
///         (try_table (catch_all_ref 0)
///           i32.const 7 throw $e)
///         unreachable)
///       throw_ref unreachable)))
/// ```
#[cfg(test)]
pub fn test_module_eh_catch_all_ref() -> Vec<u8> {
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 2);
    types.extend_from_slice(&[0x60, 0, 1, 0x7f]);
    types.extend_from_slice(&[0x60, 1, 0x7f, 0]);
    section(&mut out, 1, &types);
    section(&mut out, 3, &[1, 0]);
    section(&mut out, 5, &[1, 0x00, 0x01]);
    section(&mut out, 13, &[1, 0x00, 1]);
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.push(0x02);
    push_uleb(&mut exports, 0);
    put_name(&mut exports, "_start");
    exports.push(0x00);
    push_uleb(&mut exports, 0);
    section(&mut out, 7, &exports);
    let b0 = [
        0x00, // locals
        0x02, 0x7f, // block (result i32)
        0x1f, 0x40, //   try_table empty
        0x01, //   1 catch
        0x00, 0x00, 0x00, //   catch tag0 label0
        0x02, 0x7f, //     block (result i32)  dest of catch_all_ref
        0x1f, 0x40, //       try_table empty
        0x01, //       1 catch
        0x03, 0x00, //       catch_all_ref label0
        0x41, 0x07, //         i32.const 7
        0x08, 0x00, //         throw 0
        0x0b, //       end try_table
        0x00, //       unreachable (fallthrough)
        0x0b, //     end inner block — exnref result
        0x0a, //     throw_ref
        0x00, //     unreachable
        0x0b, //   end try_table
        0x00, // unreachable
        0x0b, // end outer block
        0x0b,
    ];
    let mut code = Vec::new();
    push_uleb(&mut code, 1);
    push_uleb(&mut code, b0.len() as u32);
    code.extend_from_slice(&b0);
    section(&mut out, 10, &code);
    out
}

/// Cross-function throw into `catch_all_ref`, then `throw_ref` into `catch $e`.
/// ```wat
/// (tag $e (param i32))
/// (func $thrower i32.const 7 throw $e)
/// (func $_start (result i32)
///   (block (result i32)
///     (try_table (catch $e 0)
///       (block (result i32)
///         (try_table (catch_all_ref 0)
///           (call $thrower) unreachable)
///         unreachable)
///       throw_ref unreachable)))
/// ```
#[cfg(test)]
pub fn test_module_eh_catch_all_ref_cross() -> Vec<u8> {
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 3);
    types.extend_from_slice(&[0x60, 0, 1, 0x7f]); // t0 ()->i32
    types.extend_from_slice(&[0x60, 0, 0]); // t1 ()->()
    types.extend_from_slice(&[0x60, 1, 0x7f, 0]); // t2 (i32)->()
    section(&mut out, 1, &types);
    section(&mut out, 3, &[2, 1, 0]); // f0=t1 thrower, f1=t0 _start
    section(&mut out, 5, &[1, 0x00, 0x01]);
    section(&mut out, 13, &[1, 0x00, 2]);
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.push(0x02);
    push_uleb(&mut exports, 0);
    put_name(&mut exports, "_start");
    exports.push(0x00);
    push_uleb(&mut exports, 1);
    section(&mut out, 7, &exports);
    let b0 = [0x00, 0x41, 0x07, 0x08, 0x00, 0x0b];
    let b1 = [
        0x00, // locals
        0x02, 0x7f, // block (result i32)
        0x1f, 0x40, //   try_table empty
        0x01, //   1 catch
        0x00, 0x00, 0x00, //   catch tag0 label0
        0x02, 0x7f, //     block (result i32)  dest of catch_all_ref
        0x1f, 0x40, //       try_table empty
        0x01, //       1 catch
        0x03, 0x00, //       catch_all_ref label0
        0x10, 0x00, //         call 0
        0x00, //         unreachable
        0x0b, //       end try_table
        0x00, //       unreachable (fallthrough)
        0x0b, //     end inner block — exnref result
        0x0a, //     throw_ref
        0x00, //     unreachable
        0x0b, //   end try_table
        0x00, // unreachable
        0x0b, // end outer block
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

/// Same-function `catch_ref` + `throw_ref`: dest gets payload 7 plus exnref;
/// `throw_ref` rethrows into the outer `catch $e`.
/// ```wat
/// (tag $e (param i32))
/// (func $_start (result i32)
///   (block (result i32)
///     (try_table (catch $e 0)
///       (block (result i32)
///         (try_table (catch_ref $e 0)
///           i32.const 7 throw $e)
///         unreachable)
///       throw_ref unreachable)))
/// ```
#[cfg(test)]
pub fn test_module_eh_catch_ref() -> Vec<u8> {
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 2);
    types.extend_from_slice(&[0x60, 0, 1, 0x7f]);
    types.extend_from_slice(&[0x60, 1, 0x7f, 0]);
    section(&mut out, 1, &types);
    section(&mut out, 3, &[1, 0]);
    section(&mut out, 5, &[1, 0x00, 0x01]);
    section(&mut out, 13, &[1, 0x00, 1]);
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.push(0x02);
    push_uleb(&mut exports, 0);
    put_name(&mut exports, "_start");
    exports.push(0x00);
    push_uleb(&mut exports, 0);
    section(&mut out, 7, &exports);
    let b0 = [
        0x00, // locals
        0x02, 0x7f, // block (result i32)
        0x1f, 0x40, //   try_table empty
        0x01, //   1 catch
        0x00, 0x00, 0x00, //   catch tag0 label0
        0x02, 0x7f, //     block (result i32)  dest of catch_ref
        0x1f, 0x40, //       try_table empty
        0x01, //       1 catch
        0x01, 0x00, 0x00, //       catch_ref tag0 label0
        0x41, 0x07, //         i32.const 7
        0x08, 0x00, //         throw 0
        0x0b, //       end try_table
        0x00, //       unreachable
        0x0b, //     end inner block
        0x0a, //     throw_ref
        0x00, //     unreachable
        0x0b, //   end try_table
        0x00, // unreachable
        0x0b, // end outer block
        0x0b,
    ];
    let mut code = Vec::new();
    push_uleb(&mut code, 1);
    push_uleb(&mut code, b0.len() as u32);
    code.extend_from_slice(&b0);
    section(&mut out, 10, &code);
    out
}

/// `catch_ref` dest top cell is the exnref handle (tag+1 = 1), not payload 7.
/// ```wat
/// (tag $e (param i32))
/// (func $_start (result i32)
///   (block (result i32)
///     (try_table (catch_ref $e 0)
///       i32.const 7 throw $e)
///     unreachable))
/// ```
#[cfg(test)]
pub fn test_module_eh_catch_ref_handle() -> Vec<u8> {
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 2);
    types.extend_from_slice(&[0x60, 0, 1, 0x7f]);
    types.extend_from_slice(&[0x60, 1, 0x7f, 0]);
    section(&mut out, 1, &types);
    section(&mut out, 3, &[1, 0]);
    section(&mut out, 5, &[1, 0x00, 0x01]);
    section(&mut out, 13, &[1, 0x00, 1]);
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.push(0x02);
    push_uleb(&mut exports, 0);
    put_name(&mut exports, "_start");
    exports.push(0x00);
    push_uleb(&mut exports, 0);
    section(&mut out, 7, &exports);
    let b0 = [
        0x00, // locals
        0x02, 0x7f, // block (result i32)
        0x1f, 0x40, //   try_table empty
        0x01, //   1 catch
        0x01, 0x00, 0x00, //   catch_ref tag0 label0
        0x41, 0x07, //     i32.const 7
        0x08, 0x00, //     throw 0
        0x0b, //   end try_table
        0x00, //   unreachable
        0x0b, // end block
        0x0b,
    ];
    let mut code = Vec::new();
    push_uleb(&mut code, 1);
    push_uleb(&mut code, b0.len() as u32);
    code.extend_from_slice(&b0);
    section(&mut out, 10, &code);
    out
}

/// `catch_ref $e0` misses a void `$e1` throw; `catch_all` yields 777.
/// ```wat
/// (tag $e0 (param i32)) (tag $e1)
/// (func $thrower throw $e1)
/// (func $_start (result i32)
///   (block (result i32)
///     (block
///       (try_table (catch_ref $e0 1) (catch_all 0)
///         (call $thrower))
///       unreachable)
///     i32.const 777))
/// ```
#[cfg(test)]
pub fn test_module_eh_catch_ref_miss() -> Vec<u8> {
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 3);
    types.extend_from_slice(&[0x60, 0, 1, 0x7f]);
    types.extend_from_slice(&[0x60, 0, 0]);
    types.extend_from_slice(&[0x60, 1, 0x7f, 0]);
    section(&mut out, 1, &types);
    section(&mut out, 3, &[2, 1, 0]);
    section(&mut out, 5, &[1, 0x00, 0x01]);
    section(&mut out, 13, &[2, 0x00, 2, 0x00, 1]);
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.push(0x02);
    push_uleb(&mut exports, 0);
    put_name(&mut exports, "_start");
    exports.push(0x00);
    push_uleb(&mut exports, 1);
    section(&mut out, 7, &exports);
    let b0 = [0x00, 0x08, 0x01, 0x0b]; // throw tag1
    let b1 = [
        0x00, // locals
        0x02, 0x7f, // block (result i32)
        0x02, 0x40, //   block (empty)
        0x1f, 0x40, //     try_table
        0x02, //     2 catches
        0x01, 0x00, 0x01, //     catch_ref tag0 label1
        0x02, 0x00, //     catch_all label0
        0x10, 0x00, //     call 0
        0x0b, //     end try_table
        0x00, //     unreachable
        0x0b, //   end inner
        0x41, 0x89, 0x06, //   i32.const 777
        0x0b, // end outer
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

/// `libwasm_await__void` inside a legacy `try` — rewind is not a landing pad.
/// Guest JIT must fail-closed (coverage gap 0x700), not park inside the try.
#[cfg(test)]
pub fn test_module_await_in_try() -> Vec<u8> {
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 2);
    types.extend_from_slice(&[0x60, 0, 1, 0x7f]); // t0 ()->i32
    types.extend_from_slice(&[0x60, 1, 0x7f, 0]); // t1 (i32)->()
    section(&mut out, 1, &types);
    let mut imps = Vec::new();
    push_uleb(&mut imps, 1);
    put_name(&mut imps, "env");
    put_name(&mut imps, "libwasm_await__void");
    imps.push(0x00);
    imps.push(1);
    section(&mut out, 2, &imps);
    section(&mut out, 3, &[1, 0]); // _start t0
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
    let b0 = [
        0x00, // locals
        0x06, 0x7f, // try (result i32)
        0x41, 0x00, //   i32.const 0
        0x10, 0x00, //   call 0 await
        0x41, 0x01, //   i32.const 1
        0x19, // catch_all
        0x41, 0x89, 0x06, //   i32.const 777
        0x0b, // end try
        0x0b,
    ];
    let mut code = Vec::new();
    push_uleb(&mut code, 1);
    push_uleb(&mut code, b0.len() as u32);
    code.extend_from_slice(&b0);
    section(&mut out, 10, &code);
    out
}

/// `try { call $awaiter }` — `$awaiter` reaches `libwasm_await__void`.
/// Guest JIT must fail-closed at the call site (0x700).
#[cfg(test)]
pub fn test_module_await_via_call() -> Vec<u8> {
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 3);
    types.extend_from_slice(&[0x60, 0, 1, 0x7f]); // t0 ()->i32
    types.extend_from_slice(&[0x60, 1, 0x7f, 0]); // t1 (i32)->()
    types.extend_from_slice(&[0x60, 0, 0]); // t2 ()->()
    section(&mut out, 1, &types);
    let mut imps = Vec::new();
    push_uleb(&mut imps, 1);
    put_name(&mut imps, "env");
    put_name(&mut imps, "libwasm_await__void");
    imps.push(0x00);
    imps.push(1);
    section(&mut out, 2, &imps);
    section(&mut out, 3, &[2, 2, 0]); // f1=awaiter t2, f2=_start t0
    section(&mut out, 5, &[1, 0x00, 0x01]);
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.push(0x02);
    push_uleb(&mut exports, 0);
    put_name(&mut exports, "_start");
    exports.push(0x00);
    push_uleb(&mut exports, 2);
    section(&mut out, 7, &exports);
    let b0 = [0x00, 0x41, 0x00, 0x10, 0x00, 0x0b]; // awaiter: const 0; call await
    let b1 = [
        0x00, // locals
        0x06, 0x7f, // try (result i32)
        0x10, 0x01, //   call awaiter
        0x41, 0x01, //   i32.const 1
        0x19, // catch_all
        0x41, 0x89, 0x06, //   i32.const 777
        0x0b, // end try
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

/// `try { call_indirect }` with an awaiter in the funcref table.
#[cfg(test)]
pub fn test_module_await_via_calli() -> Vec<u8> {
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 3);
    types.extend_from_slice(&[0x60, 0, 1, 0x7f]); // t0 ()->i32
    types.extend_from_slice(&[0x60, 1, 0x7f, 0]); // t1 (i32)->()
    types.extend_from_slice(&[0x60, 0, 0]); // t2 ()->()
    section(&mut out, 1, &types);
    let mut imps = Vec::new();
    push_uleb(&mut imps, 1);
    put_name(&mut imps, "env");
    put_name(&mut imps, "libwasm_await__void");
    imps.push(0x00);
    imps.push(1);
    section(&mut out, 2, &imps);
    section(&mut out, 3, &[2, 2, 0]); // awaiter t2, _start t0
    section(&mut out, 4, &[1, 0x70, 0x00, 0x01]);
    section(&mut out, 5, &[1, 0x00, 0x01]);
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.push(0x02);
    push_uleb(&mut exports, 0);
    put_name(&mut exports, "_start");
    exports.push(0x00);
    push_uleb(&mut exports, 2);
    section(&mut out, 7, &exports);
    section(&mut out, 9, &[1, 0x00, 0x41, 0x00, 0x0b, 0x01, 0x01]); // table[0]=awaiter
    let b0 = [0x00, 0x41, 0x00, 0x10, 0x00, 0x0b];
    let b1 = [
        0x00, // locals
        0x06, 0x7f, // try (result i32)
        0x41, 0x00, //   i32.const 0
        0x11, 0x02, 0x00, //   call_indirect t2 table0
        0x41, 0x01, //   i32.const 1
        0x19, // catch_all
        0x41, 0x89, 0x06, //   i32.const 777
        0x0b, 0x0b,
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

/// `try { call_indirect }` whose table only holds a non-awaiter — must stay clean.
#[cfg(test)]
pub fn test_module_calli_in_try_no_await() -> Vec<u8> {
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 2);
    types.extend_from_slice(&[0x60, 1, 0x7f, 1, 0x7f]); // t0 (i32)->i32
    types.extend_from_slice(&[0x60, 0, 1, 0x7f]); // t1 ()->i32
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
    let b0 = [0x00, 0x20, 0x00, 0x41, 0x0a, 0x6a, 0x0b]; // arg+10
    let b1 = [
        0x00, // locals
        0x06, 0x7f, // try (result i32)
        0x41, 0x05, //   i32.const 5
        0x41, 0x00, //   i32.const 0
        0x11, 0x00, 0x00, //   call_indirect t0
        0x19, // catch_all
        0x41, 0x89, 0x06, //   777
        0x0b, 0x0b,
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

/// Cross-function throw into `try_table` `catch_all`: callee `throw` is caught
/// by the caller's table dest (parent empty block), then `_start` yields 777.
/// ```wat
/// (tag $e)
/// (func $thrower throw $e)
/// (func $_start (result i32)
///   (block
///     (try_table (catch_all 0)
///       (call $thrower) unreachable)
///     )
///   i32.const 777)
/// ```
#[cfg(test)]
pub fn test_module_eh_try_table() -> Vec<u8> {
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 2);
    types.extend_from_slice(&[0x60, 0, 1, 0x7f]); // t0 ()->i32
    types.extend_from_slice(&[0x60, 0, 0]); // t1 ()->()
    section(&mut out, 1, &types);
    section(&mut out, 3, &[2, 1, 0]); // f0=t1 thrower, f1=t0 _start
    section(&mut out, 5, &[1, 0x00, 0x01]);
    section(&mut out, 13, &[1, 0x00, 1]); // tag typeidx 1 (()->())
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
        0x00, // locals
        0x02, 0x40, // block (empty)
        0x1f, 0x40, //   try_table (empty)
        0x01, //   1 catch
        0x02, 0x00, //   catch_all label0
        0x10, 0x00, //   call 0
        0x00, //   unreachable
        0x0b, //   end try_table
        0x0b, // end block
        0x41, 0x89, 0x06, // i32.const 777
        0x0b, // end func
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

/// Cross-function tagged throw: callee pushes 7 then `throw $e`; caller
/// `try_table (catch $e 0)` must return 7, not a wiped frame.
/// ```wat
/// (tag $e (param i32))
/// (func $thrower i32.const 7 throw $e)
/// (func $_start (result i32)
///   (block (result i32)
///     (try_table (catch $e 0)
///       (call $thrower) unreachable)))
/// ```
#[cfg(test)]
pub fn test_module_eh_try_table_payload() -> Vec<u8> {
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 3);
    types.extend_from_slice(&[0x60, 0, 1, 0x7f]); // t0 ()->i32
    types.extend_from_slice(&[0x60, 0, 0]); // t1 ()->()
    types.extend_from_slice(&[0x60, 1, 0x7f, 0]); // t2 (i32)->()
    section(&mut out, 1, &types);
    section(&mut out, 3, &[2, 1, 0]); // f0=t1 thrower, f1=t0 _start
    section(&mut out, 5, &[1, 0x00, 0x01]);
    section(&mut out, 13, &[1, 0x00, 2]); // tag typeidx 2 (param i32)
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.push(0x02);
    push_uleb(&mut exports, 0);
    put_name(&mut exports, "_start");
    exports.push(0x00);
    push_uleb(&mut exports, 1);
    section(&mut out, 7, &exports);
    let b0 = [0x00, 0x41, 0x07, 0x08, 0x00, 0x0b]; // const 7; throw 0
    let b1 = [
        0x00, // locals
        0x02, 0x7f, // block (result i32)
        0x1f, 0x40, //   try_table (empty)
        0x01, //   1 catch
        0x00, 0x00, 0x00, //   catch tag0 label0
        0x10, 0x00, //   call 0
        0x0b, //   end try_table
        0x00, // unreachable
        0x0b, // end block
        0x0b, // end func
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

/// Multi-clause `try_table`: `catch $e0` then `catch_all`. Callee throws the
/// void tag `$e1` so the first clause misses and `catch_all` yields 777.
/// ```wat
/// (tag $e0 (param i32)) (tag $e1)
/// (func $thrower throw $e1)
/// (func $_start (result i32)
///   (block (result i32)
///     (block
///       (try_table (catch $e0 1) (catch_all 0)
///         (call $thrower))
///       unreachable)
///     i32.const 777))
/// ```
#[cfg(test)]
pub fn test_module_eh_try_table_multi_miss() -> Vec<u8> {
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 3);
    types.extend_from_slice(&[0x60, 0, 1, 0x7f]);
    types.extend_from_slice(&[0x60, 0, 0]);
    types.extend_from_slice(&[0x60, 1, 0x7f, 0]);
    section(&mut out, 1, &types);
    section(&mut out, 3, &[2, 1, 0]);
    section(&mut out, 5, &[1, 0x00, 0x01]);
    section(&mut out, 13, &[2, 0x00, 2, 0x00, 1]); // tag0 (i32), tag1 (void)
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.push(0x02);
    push_uleb(&mut exports, 0);
    put_name(&mut exports, "_start");
    exports.push(0x00);
    push_uleb(&mut exports, 1);
    section(&mut out, 7, &exports);
    let b0 = [0x00, 0x08, 0x01, 0x0b]; // throw tag1
    let b1 = [
        0x00, // locals
        0x02, 0x7f, // block (result i32)
        0x02, 0x40, //   block (empty)
        0x1f, 0x40, //     try_table
        0x02, //     2 catches
        0x00, 0x00, 0x01, //     catch tag0 label1
        0x02, 0x00, //     catch_all label0
        0x10, 0x00, //     call 0
        0x0b, //     end try_table
        0x00, //     unreachable
        0x0b, //   end inner
        0x41, 0x89, 0x06, //   i32.const 777
        0x0b, // end outer
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

/// Same table as [`test_module_eh_try_table_multi_miss`], but the callee
/// throws `$e0` with payload 7 — the first clause must win, not `catch_all`.
#[cfg(test)]
pub fn test_module_eh_try_table_multi_hit() -> Vec<u8> {
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 3);
    types.extend_from_slice(&[0x60, 0, 1, 0x7f]);
    types.extend_from_slice(&[0x60, 0, 0]);
    types.extend_from_slice(&[0x60, 1, 0x7f, 0]);
    section(&mut out, 1, &types);
    section(&mut out, 3, &[2, 1, 0]);
    section(&mut out, 5, &[1, 0x00, 0x01]);
    section(&mut out, 13, &[2, 0x00, 2, 0x00, 1]);
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.push(0x02);
    push_uleb(&mut exports, 0);
    put_name(&mut exports, "_start");
    exports.push(0x00);
    push_uleb(&mut exports, 1);
    section(&mut out, 7, &exports);
    let b0 = [0x00, 0x41, 0x07, 0x08, 0x00, 0x0b]; // const 7; throw tag0
    let b1 = [
        0x00, 0x02, 0x7f, // block (result i32)
        0x02, 0x40, //   block (empty)
        0x1f, 0x40, //     try_table
        0x02, 0x00, 0x00, 0x01, //     catch tag0 label1
        0x02, 0x00, //     catch_all label0
        0x10, 0x00, 0x0b, 0x00, 0x0b, 0x41, 0x89,
        0x06, //   i32.const 777 (unreached if $e0 hits)
        0x0b, 0x0b,
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

/// `try_table` catch dest: throw i32 7 lands on the parent block.
/// ```wat
/// (tag $e (param i32))
/// (func $_start (result i32)
///   (block (result i32)
///     (try_table (catch $e 0)
///       (i32.const 7) (throw $e))
///     unreachable))
/// ```
#[cfg(test)]
pub fn test_module_try_table() -> Vec<u8> {
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 2);
    types.extend_from_slice(&[0x60, 0, 1, 0x7f]);
    types.extend_from_slice(&[0x60, 1, 0x7f, 0]);
    section(&mut out, 1, &types);
    section(&mut out, 3, &[1, 0]);
    section(&mut out, 5, &[1, 0x00, 0x01]);
    section(&mut out, 13, &[1, 0x00, 1]);
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.push(0x02);
    push_uleb(&mut exports, 0);
    put_name(&mut exports, "_start");
    exports.push(0x00);
    push_uleb(&mut exports, 0);
    section(&mut out, 7, &exports);
    let b0 = [
        0x00, // locals
        0x02, 0x7f, // block (result i32)
        0x1f, 0x40, // try_table (empty type)
        0x01, // 1 catch
        0x00, 0x00, 0x00, // catch tag0 label0
        0x41, 0x07, // i32.const 7
        0x08, 0x00, // throw 0
        0x0b, // end try_table
        0x00, // unreachable
        0x0b, // end block
        0x0b, // end func
    ];
    let mut code = Vec::new();
    push_uleb(&mut code, 1);
    push_uleb(&mut code, b0.len() as u32);
    code.extend_from_slice(&b0);
    section(&mut out, 10, &code);
    out
}

/// `try_table` `catch_all` dest must restore vsp: leftover 99 must not become
/// the result. `_start` pushes 1, throws 99 inside `try_table`, catch dest is
/// the parent empty block.
/// ```wat
/// (tag $e (param i32))
/// (func $_start (result i32)
///   i32.const 1
///   (block
///     (try_table (catch_all 0)
///       (i32.const 99) (throw $e))
///     unreachable))
/// ```
#[cfg(test)]
pub fn test_module_try_table_catch_all_vsp() -> Vec<u8> {
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 2);
    types.extend_from_slice(&[0x60, 0, 1, 0x7f]);
    types.extend_from_slice(&[0x60, 1, 0x7f, 0]);
    section(&mut out, 1, &types);
    section(&mut out, 3, &[1, 0]);
    section(&mut out, 5, &[1, 0x00, 0x01]);
    section(&mut out, 13, &[1, 0x00, 1]);
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.push(0x02);
    push_uleb(&mut exports, 0);
    put_name(&mut exports, "_start");
    exports.push(0x00);
    push_uleb(&mut exports, 0);
    section(&mut out, 7, &exports);
    let b0 = [
        0x00, // locals
        0x41, 0x01, // i32.const 1
        0x02, 0x40, // block (empty)
        0x1f, 0x40, //   try_table (empty type)
        0x01, //   1 catch
        0x02, 0x00, //   catch_all label0
        0x41, 0x63, //   i32.const 99
        0x08, 0x00, //   throw 0
        0x0b, //   end try_table
        0x00, //   unreachable
        0x0b, // end block
        0x0b, // end func
    ];
    let mut code = Vec::new();
    push_uleb(&mut code, 1);
    push_uleb(&mut code, b0.len() as u32);
    code.extend_from_slice(&b0);
    section(&mut out, 10, &code);
    out
}

/// catch_all must restore vsp: leftover throw payload 99 must not become the
/// result. `_start` pushes 1, throws 99 inside `try`, `catch_all` drops it.
/// ```wat
/// (tag $e (param i32))
/// (func $_start (result i32)
///   i32.const 1
///   try
///     i32.const 99
///     throw $e
///   catch_all
///   end)
/// ```
#[cfg(test)]
pub fn test_module_eh_vsp() -> Vec<u8> {
    let mut out = b"\0asm\x01\x00\x00\x00".to_vec();
    let mut types = Vec::new();
    push_uleb(&mut types, 2);
    types.extend_from_slice(&[0x60, 0, 1, 0x7f]); // t0 ()->i32
    types.extend_from_slice(&[0x60, 1, 0x7f, 0]); // t1 (i32)->()
    section(&mut out, 1, &types);
    section(&mut out, 3, &[1, 0]);
    section(&mut out, 5, &[1, 0x00, 0x01]);
    section(&mut out, 13, &[1, 0x00, 1]); // tag typeidx 1 (param i32)
    let mut exports = Vec::new();
    push_uleb(&mut exports, 2);
    put_name(&mut exports, "memory");
    exports.push(0x02);
    push_uleb(&mut exports, 0);
    put_name(&mut exports, "_start");
    exports.push(0x00);
    push_uleb(&mut exports, 0);
    section(&mut out, 7, &exports);
    let b0 = [
        0x00, // locals
        0x41, 0x01, // i32.const 1
        0x06, 0x40, // try (empty)
        0x41, 0x63, //   i32.const 99
        0x08, 0x00, //   throw 0
        0x19, // catch_all
        0x0b, // end try
        0x0b, // end func
    ];
    let mut code = Vec::new();
    push_uleb(&mut code, 1);
    push_uleb(&mut code, b0.len() as u32);
    code.extend_from_slice(&b0);
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

    /// Cross-function unwind into `try_table` `catch_all`: callee `throw` is
    /// caught by the caller's table dest, yielding 777 — no trap.
    #[test]
    fn guest_jit_cross_func_throw_try_table() {
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},"wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"test"}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let mut m = g6b_asm::analyze::kstart(&spec);
        install_guest(&mut m, &test_module_eh_try_table()).expect("try_table eh cell installs");
        let s = g6b_asm::exec::run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(
            !s.console.contains("WASM-JIT-TRAP"),
            "try_table throw escaped uncaught / {}",
            s.console
        );
        let mut got = None;
        for line in s.console.lines() {
            if let Some(hex) = line.strip_prefix("WASM-JIT ") {
                got = Some(u64::from_str_radix(hex.trim(), 16).unwrap_or(u64::MAX));
            }
        }
        assert_eq!(
            got,
            Some(0x309),
            "try_table catch_all did not yield 777: {}",
            s.console
        );
    }

    /// Cross-function tagged throw: callee `i32.const 7; throw` returns 7,
    /// not a folded-away payload.
    #[test]
    fn guest_jit_cross_func_throw_payload() {
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},"wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"test"}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let mut m = g6b_asm::analyze::kstart(&spec);
        install_guest(&mut m, &test_module_eh_try_table_payload())
            .expect("try_table payload cell installs");
        let s = g6b_asm::exec::run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(
            !s.console.contains("WASM-JIT-TRAP"),
            "tagged throw escaped uncaught / {}",
            s.console
        );
        let mut got = None;
        for line in s.console.lines() {
            if let Some(hex) = line.strip_prefix("WASM-JIT ") {
                got = Some(u64::from_str_radix(hex.trim(), 16).unwrap_or(u64::MAX));
            }
        }
        assert_eq!(
            got,
            Some(7),
            "cross-func tagged throw dropped payload: {}",
            s.console
        );
    }

    /// Two-cell tagged throw: callee pushes 3 then 4; catch adds them to 7.
    #[test]
    fn guest_jit_cross_func_throw_payload2() {
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},"wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"test"}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let mut m = g6b_asm::analyze::kstart(&spec);
        install_guest(&mut m, &test_module_eh_payload2()).expect("payload2 cell installs");
        let s = g6b_asm::exec::run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(
            !s.console.contains("WASM-JIT-TRAP"),
            "two-cell throw escaped uncaught / {}",
            s.console
        );
        let mut got = None;
        for line in s.console.lines() {
            if let Some(hex) = line.strip_prefix("WASM-JIT ") {
                got = Some(u64::from_str_radix(hex.trim(), 16).unwrap_or(u64::MAX));
            }
        }
        assert_eq!(
            got,
            Some(7),
            "two-cell payload 3+4 did not add to 7: {}",
            s.console
        );
    }

    /// Nested `rethrow 0` lands on the outer catch with payload 7.
    #[test]
    fn guest_jit_rethrow_nested() {
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},"wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"test"}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let mut m = g6b_asm::analyze::kstart(&spec);
        install_guest(&mut m, &test_module_eh_rethrow_nested()).expect("rethrow nested installs");
        let s = g6b_asm::exec::run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(
            !s.console.contains("WASM-JIT-TRAP"),
            "nested rethrow escaped / {}",
            s.console
        );
        let mut got = None;
        for line in s.console.lines() {
            if let Some(hex) = line.strip_prefix("WASM-JIT ") {
                got = Some(u64::from_str_radix(hex.trim(), 16).unwrap_or(u64::MAX));
            }
        }
        assert_eq!(got, Some(7), "nested rethrow payload: {}", s.console);
    }

    /// Cross-function `rethrow 0`: callee catch restashes payload 7 for caller.
    #[test]
    fn guest_jit_rethrow_escape() {
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},"wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"test"}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let mut m = g6b_asm::analyze::kstart(&spec);
        install_guest(&mut m, &test_module_eh_rethrow_escape()).expect("rethrow escape installs");
        let s = g6b_asm::exec::run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(
            !s.console.contains("WASM-JIT-TRAP"),
            "escape rethrow uncaught / {}",
            s.console
        );
        let mut got = None;
        for line in s.console.lines() {
            if let Some(hex) = line.strip_prefix("WASM-JIT ") {
                got = Some(u64::from_str_radix(hex.trim(), 16).unwrap_or(u64::MAX));
            }
        }
        assert_eq!(got, Some(7), "escape rethrow payload: {}", s.console);
    }

    /// `rethrow 0` into an enclosing `try_table` catch dest returns 7.
    #[test]
    fn guest_jit_rethrow_try_table() {
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},"wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"test"}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let mut m = g6b_asm::analyze::kstart(&spec);
        install_guest(&mut m, &test_module_eh_rethrow_try_table())
            .expect("rethrow try_table installs");
        let s = g6b_asm::exec::run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(
            !s.console.contains("WASM-JIT-TRAP"),
            "rethrow try_table escaped / {}",
            s.console
        );
        let mut got = None;
        for line in s.console.lines() {
            if let Some(hex) = line.strip_prefix("WASM-JIT ") {
                got = Some(u64::from_str_radix(hex.trim(), 16).unwrap_or(u64::MAX));
            }
        }
        assert_eq!(got, Some(7), "rethrow try_table payload: {}", s.console);
    }

    /// Local `catch_all_ref` + `throw_ref` keeps payload 7 on the outer catch.
    #[test]
    fn guest_jit_catch_all_ref_throw_ref() {
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},"wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"test"}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let mut m = g6b_asm::analyze::kstart(&spec);
        install_guest(&mut m, &test_module_eh_catch_all_ref())
            .expect("catch_all_ref cell installs");
        let s = g6b_asm::exec::run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(
            !s.console.contains("WASM-JIT-TRAP"),
            "catch_all_ref throw_ref escaped / {}",
            s.console
        );
        let mut got = None;
        for line in s.console.lines() {
            if let Some(hex) = line.strip_prefix("WASM-JIT ") {
                got = Some(u64::from_str_radix(hex.trim(), 16).unwrap_or(u64::MAX));
            }
        }
        assert_eq!(
            got,
            Some(7),
            "catch_all_ref throw_ref payload: {}",
            s.console
        );
    }

    /// Cross-function throw into `catch_all_ref`, then `throw_ref` returns 7.
    #[test]
    fn guest_jit_cross_func_catch_all_ref_throw_ref() {
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},"wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"test"}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let mut m = g6b_asm::analyze::kstart(&spec);
        install_guest(&mut m, &test_module_eh_catch_all_ref_cross())
            .expect("cross catch_all_ref cell installs");
        let s = g6b_asm::exec::run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(
            !s.console.contains("WASM-JIT-TRAP"),
            "cross catch_all_ref throw_ref escaped / {}",
            s.console
        );
        let mut got = None;
        for line in s.console.lines() {
            if let Some(hex) = line.strip_prefix("WASM-JIT ") {
                got = Some(u64::from_str_radix(hex.trim(), 16).unwrap_or(u64::MAX));
            }
        }
        assert_eq!(
            got,
            Some(7),
            "cross catch_all_ref throw_ref payload: {}",
            s.console
        );
    }

    /// Local `catch_ref` dest is payload plus exnref; `throw_ref` returns 7.
    #[test]
    fn guest_jit_catch_ref_throw_ref() {
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},"wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"test"}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let mut m = g6b_asm::analyze::kstart(&spec);
        install_guest(&mut m, &test_module_eh_catch_ref()).expect("catch_ref cell installs");
        let s = g6b_asm::exec::run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(
            !s.console.contains("WASM-JIT-TRAP"),
            "catch_ref throw_ref escaped / {}",
            s.console
        );
        let mut got = None;
        for line in s.console.lines() {
            if let Some(hex) = line.strip_prefix("WASM-JIT ") {
                got = Some(u64::from_str_radix(hex.trim(), 16).unwrap_or(u64::MAX));
            }
        }
        assert_eq!(got, Some(7), "catch_ref throw_ref payload: {}", s.console);
    }

    /// `catch_ref` dest top cell is the exnref handle (1), not payload 7.
    #[test]
    fn guest_jit_catch_ref_exnref_is_nonzero() {
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},"wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"test"}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let mut m = g6b_asm::analyze::kstart(&spec);
        install_guest(&mut m, &test_module_eh_catch_ref_handle())
            .expect("catch_ref handle cell installs");
        let s = g6b_asm::exec::run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(
            !s.console.contains("WASM-JIT-TRAP"),
            "catch_ref handle escaped / {}",
            s.console
        );
        let mut got = None;
        for line in s.console.lines() {
            if let Some(hex) = line.strip_prefix("WASM-JIT ") {
                got = Some(u64::from_str_radix(hex.trim(), 16).unwrap_or(u64::MAX));
            }
        }
        assert_eq!(
            got,
            Some(1),
            "catch_ref dest top should be exnref handle 1, not payload: {}",
            s.console
        );
    }

    /// `catch_ref $e0` misses void `$e1`; `catch_all` yields 777.
    #[test]
    fn guest_jit_catch_ref_miss_falls_to_catch_all() {
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},"wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"test"}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let mut m = g6b_asm::analyze::kstart(&spec);
        install_guest(&mut m, &test_module_eh_catch_ref_miss())
            .expect("catch_ref miss cell installs");
        let s = g6b_asm::exec::run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(
            !s.console.contains("WASM-JIT-TRAP"),
            "catch_all after catch_ref miss escaped / {}",
            s.console
        );
        let mut got = None;
        for line in s.console.lines() {
            if let Some(hex) = line.strip_prefix("WASM-JIT ") {
                got = Some(u64::from_str_radix(hex.trim(), 16).unwrap_or(u64::MAX));
            }
        }
        assert_eq!(
            got,
            Some(0x309),
            "catch_ref miss did not reach catch_all 777: {}",
            s.console
        );
    }

    /// Local `catch_ref` EXCCLR copies payload+handle (b=2).
    #[test]
    fn catch_ref_excclear_copies_payload_and_handle() {
        let img = encode(&test_module_eh_catch_ref_handle()).expect("catch_ref handle encodes");
        let nfuncs = u32::from_le_bytes(img[4..8].try_into().unwrap()) as usize;
        let nrecords = u32::from_le_bytes(img[24..28].try_into().unwrap()) as usize;
        let rbase = HDR_BYTES + nfuncs * FHDR_BYTES;
        let mut found = None;
        for i in 0..nrecords {
            let op =
                u32::from_le_bytes(img[rbase + i * 16..rbase + i * 16 + 4].try_into().unwrap());
            if op == R_EXCCLR {
                let b = u64::from_le_bytes(
                    img[rbase + i * 16 + 8..rbase + i * 16 + 16]
                        .try_into()
                        .unwrap(),
                );
                found = Some(b);
            }
        }
        assert_eq!(
            found,
            Some(2),
            "catch_ref EXCCLR should copy payload+handle (b=2)"
        );
    }

    /// Direct `libwasm_await__void` inside `try` is a reachable coverage gap.
    #[test]
    fn await_inside_try_is_a_coverage_gap() {
        let wasm = test_module_await_in_try();
        let cov = op_coverage(&wasm).expect("await-in-try encodes");
        assert!(
            !cov.clean(),
            "await inside try must not look clean: {:?}",
            cov.gaps.iter().map(OpGap::describe).collect::<Vec<_>>()
        );
        assert!(
            cov.gaps
                .iter()
                .any(|g| g.code == TRAP_UNSUP && g.orig == 0x700),
            "expected 0x700 await-in-try gap, got {:?}",
            cov.gaps.iter().map(OpGap::describe).collect::<Vec<_>>()
        );
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},"wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"test"}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let mut m = g6b_asm::analyze::kstart(&spec);
        let err = install_guest(&mut m, &wasm).expect_err("await-in-try must not install");
        assert!(
            err.contains("await inside try"),
            "preflight should name the gap: {err}"
        );
    }

    /// `try { call $awaiter }` is the same gap when await is in the callee.
    #[test]
    fn await_via_call_from_try_is_a_coverage_gap() {
        let wasm = test_module_await_via_call();
        let cov = op_coverage(&wasm).expect("await-via-call encodes");
        assert!(
            !cov.clean(),
            "try calling an awaiter must not look clean: {:?}",
            cov.gaps.iter().map(OpGap::describe).collect::<Vec<_>>()
        );
        assert!(
            cov.gaps
                .iter()
                .any(|g| g.code == TRAP_UNSUP && g.orig == 0x700),
            "expected 0x700 callee-await gap, got {:?}",
            cov.gaps.iter().map(OpGap::describe).collect::<Vec<_>>()
        );
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},"wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"test"}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let mut m = g6b_asm::analyze::kstart(&spec);
        let err = install_guest(&mut m, &wasm).expect_err("callee-await from try must not install");
        assert!(
            err.contains("await inside try"),
            "preflight should name the gap: {err}"
        );
    }

    /// `try { call_indirect }` with an awaiter in the table is the same gap.
    #[test]
    fn await_via_calli_from_try_is_a_coverage_gap() {
        let wasm = test_module_await_via_calli();
        let cov = op_coverage(&wasm).expect("await-via-calli encodes");
        assert!(
            !cov.clean(),
            "try call_indirect to an awaiter must not look clean: {:?}",
            cov.gaps.iter().map(OpGap::describe).collect::<Vec<_>>()
        );
        assert!(
            cov.gaps
                .iter()
                .any(|g| g.code == TRAP_UNSUP && g.orig == 0x700),
            "expected 0x700 call_indirect-await gap, got {:?}",
            cov.gaps.iter().map(OpGap::describe).collect::<Vec<_>>()
        );
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},"wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"test"}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let mut m = g6b_asm::analyze::kstart(&spec);
        let err = install_guest(&mut m, &wasm).expect_err("calli-await from try must not install");
        assert!(
            err.contains("await inside try"),
            "preflight should name the gap: {err}"
        );
    }

    /// `try { call_indirect }` to a non-awaiter stays installable.
    #[test]
    fn calli_in_try_without_awaiter_is_clean() {
        let wasm = test_module_calli_in_try_no_await();
        let cov = op_coverage(&wasm).expect("calli-in-try encodes");
        assert!(
            cov.clean(),
            "try call_indirect to a non-awaiter must stay clean: {:?}",
            cov.gaps.iter().map(OpGap::describe).collect::<Vec<_>>()
        );
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},"wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"test"}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let mut m = g6b_asm::analyze::kstart(&spec);
        install_guest(&mut m, &wasm).expect("non-awaiter calli in try installs");
    }

    /// Multi-clause `try_table`: a miss on `catch $e0` falls through to
    /// `catch_all` instead of propagating.
    #[test]
    fn guest_jit_cross_func_throw_try_table_multi_miss() {
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},"wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"test"}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let mut m = g6b_asm::analyze::kstart(&spec);
        install_guest(&mut m, &test_module_eh_try_table_multi_miss())
            .expect("multi-miss cell installs");
        let s = g6b_asm::exec::run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(
            !s.console.contains("WASM-JIT-TRAP"),
            "catch_all after tagged miss escaped / {}",
            s.console
        );
        let mut got = None;
        for line in s.console.lines() {
            if let Some(hex) = line.strip_prefix("WASM-JIT ") {
                got = Some(u64::from_str_radix(hex.trim(), 16).unwrap_or(u64::MAX));
            }
        }
        assert_eq!(
            got,
            Some(0x309),
            "tagged miss did not reach catch_all 777: {}",
            s.console
        );
    }

    /// Multi-clause `try_table`: matching `catch $e0` wins over a later
    /// `catch_all` (payload 7, not 777).
    #[test]
    fn guest_jit_cross_func_throw_try_table_multi_hit() {
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},"wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"test"}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let mut m = g6b_asm::analyze::kstart(&spec);
        install_guest(&mut m, &test_module_eh_try_table_multi_hit())
            .expect("multi-hit cell installs");
        let s = g6b_asm::exec::run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(
            !s.console.contains("WASM-JIT-TRAP"),
            "tagged hit escaped / {}",
            s.console
        );
        let mut got = None;
        for line in s.console.lines() {
            if let Some(hex) = line.strip_prefix("WASM-JIT ") {
                got = Some(u64::from_str_radix(hex.trim(), 16).unwrap_or(u64::MAX));
            }
        }
        assert_eq!(
            got,
            Some(7),
            "first-clause hit lost to catch_all: {}",
            s.console
        );
    }

    /// `try_table` catch dest: throw 7 returns 7 (not TRAP_UNSUP).
    #[test]
    fn guest_jit_try_table_catch() {
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},"wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"test"}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let mut m = g6b_asm::analyze::kstart(&spec);
        install_guest(&mut m, &test_module_try_table()).expect("try_table cell installs");
        let s = g6b_asm::exec::run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(
            !s.console.contains("WASM-JIT-TRAP"),
            "try_table throw was not caught: {}",
            s.console
        );
        let mut got = None;
        for line in s.console.lines() {
            if let Some(hex) = line.strip_prefix("WASM-JIT ") {
                got = Some(u64::from_str_radix(hex.trim(), 16).unwrap_or(u64::MAX));
            }
        }
        assert_eq!(got, Some(7), "try_table catch dest payload: {}", s.console);
    }

    /// `try_table` catch_all dest records EXCCLR at the parent block height.
    #[test]
    fn try_table_catch_all_excclear_records_dest_height() {
        let img = encode(&test_module_try_table_catch_all_vsp()).expect("try_table vsp encodes");
        let nfuncs = u32::from_le_bytes(img[4..8].try_into().unwrap()) as usize;
        let nrecords = u32::from_le_bytes(img[24..28].try_into().unwrap()) as usize;
        let rbase = HDR_BYTES + nfuncs * FHDR_BYTES;
        let mut found = None;
        for i in 0..nrecords {
            let op =
                u32::from_le_bytes(img[rbase + i * 16..rbase + i * 16 + 4].try_into().unwrap());
            if op == R_EXCCLR {
                let a = u32::from_le_bytes(
                    img[rbase + i * 16 + 4..rbase + i * 16 + 8]
                        .try_into()
                        .unwrap(),
                );
                let b = u64::from_le_bytes(
                    img[rbase + i * 16 + 8..rbase + i * 16 + 16]
                        .try_into()
                        .unwrap(),
                );
                found = Some((a, b));
            }
        }
        assert_eq!(
            found,
            Some((1, 0)),
            "try_table catch_all EXCCLR should be dest height=1 nparams=0"
        );
    }

    /// `try_table` catch_all dest restores vsp: leftover 99 must not be returned.
    #[test]
    fn guest_jit_try_table_catch_all_restores_vsp() {
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},"wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"test"}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let mut m = g6b_asm::analyze::kstart(&spec);
        install_guest(&mut m, &test_module_try_table_catch_all_vsp())
            .expect("try_table vsp cell installs");
        let s = g6b_asm::exec::run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(
            !s.console.contains("WASM-JIT-TRAP"),
            "try_table catch_all throw was not caught: {}",
            s.console
        );
        let mut got = None;
        for line in s.console.lines() {
            if let Some(hex) = line.strip_prefix("WASM-JIT ") {
                got = Some(u64::from_str_radix(hex.trim(), 16).unwrap_or(u64::MAX));
            }
        }
        assert_eq!(
            got,
            Some(1),
            "try_table catch_all left throw payload on the stack: {}",
            s.console
        );
    }

    /// `R_EXCCLR.a` is the try height (1 = the `i32.const 1` below the try);
    /// `b` is 0 for `catch_all`.
    #[test]
    fn catch_all_excclear_records_try_height() {
        let img = encode(&test_module_eh_vsp()).expect("vsp cell encodes");
        let nfuncs = u32::from_le_bytes(img[4..8].try_into().unwrap()) as usize;
        let nrecords = u32::from_le_bytes(img[24..28].try_into().unwrap()) as usize;
        let rbase = HDR_BYTES + nfuncs * FHDR_BYTES;
        let mut found = None;
        for i in 0..nrecords {
            let op =
                u32::from_le_bytes(img[rbase + i * 16..rbase + i * 16 + 4].try_into().unwrap());
            if op == R_EXCCLR {
                let a = u32::from_le_bytes(
                    img[rbase + i * 16 + 4..rbase + i * 16 + 8]
                        .try_into()
                        .unwrap(),
                );
                let b = u64::from_le_bytes(
                    img[rbase + i * 16 + 8..rbase + i * 16 + 16]
                        .try_into()
                        .unwrap(),
                );
                found = Some((a, b));
            }
        }
        assert_eq!(
            found,
            Some((1, 0)),
            "catch_all EXCCLR should be height=1 nparams=0"
        );
    }

    /// catch_all restores vsp: leftover throw payload 99 must not be returned.
    #[test]
    fn guest_jit_catch_all_restores_vsp() {
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},
"kernel":{"cli":{"enable":false},"wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"test"}},
"holyc":{"dual_band":{"tcp":{"enable":false}}}}"#,
        )
        .unwrap();
        let mut m = g6b_asm::analyze::kstart(&spec);
        install_guest(&mut m, &test_module_eh_vsp()).expect("vsp cell installs");
        let s = g6b_asm::exec::run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(
            !s.console.contains("WASM-JIT-TRAP"),
            "catch_all throw was not caught: {}",
            s.console
        );
        let mut got = None;
        for line in s.console.lines() {
            if let Some(hex) = line.strip_prefix("WASM-JIT ") {
                got = Some(u64::from_str_radix(hex.trim(), 16).unwrap_or(u64::MAX));
            }
        }
        assert_eq!(
            got,
            Some(1),
            "catch_all left throw payload on the stack: {}",
            s.console
        );
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
            (
                "/bios/menu/main".into(),
                "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into(),
            ),
            (
                "/bios/menu/cpu".into(),
                "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into(),
            ),
            (
                "/bios/menu/memory".into(),
                "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into(),
            ),
            (
                "/bios/menu/uncore".into(),
                "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into(),
            ),
            (
                "/bios/menu/devices".into(),
                "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into(),
            ),
            (
                "/bios/menu/boot".into(),
                "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into(),
            ),
            (
                "/bios/menu/settings".into(),
                "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into(),
            ),
            ("/bios/store".into(), "[]".into()),
        ])
        .unwrap();
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

    #[test]
    fn guest_install_rejects_reachable_missing_import() {
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"kernel":{"wasm":{"enable":true,"jit":true,"guest_jit":true}}}"#,
        ).unwrap();
        let mut module = g6b_asm::analyze::kstart(&spec);
        let mut wasm = delegate_key_cell();
        let at = wasm.windows(7).position(|w| w == b"getRoot").unwrap();
        wasm[at..at + 7].copy_from_slice(b"badRoot");
        assert!(!op_coverage(&wasm).unwrap().clean());
        assert!(install_guest(&mut module, &wasm).is_err());
        assert!(module.jit_in.is_empty());
    }

    #[test]
    fn guest_jit_jitcall_preserves_four_arguments() {
        use g6b_asm::encode::{A3, A4, A5};
        let spec = g6b_spec::BoardSpec::from_json_str(
            r#"{"schema_version":1,"isa":{"xlen":64},"kernel":{"cli":{"enable":false},"wasm":{"enable":true,"jit":true,"guest_jit":true,"jit_cell":"test"}}}"#,
        ).unwrap();
        let mut wasm = b"\0asm\x01\0\0\0".to_vec();
        section(
            &mut wasm,
            1,
            &[
                2, 0x60, 0, 1, 0x7f, 0x60, 4, 0x7f, 0x7f, 0x7f, 0x7f, 1, 0x7f,
            ],
        );
        section(&mut wasm, 3, &[2, 0, 1]);
        section(&mut wasm, 5, &[1, 0, 1]);
        let mut exports = vec![2];
        put_name(&mut exports, "_start");
        exports.extend_from_slice(&[0, 0]);
        put_name(&mut exports, "callback");
        exports.extend_from_slice(&[0, 1]);
        section(&mut wasm, 7, &exports);
        let start = [0, 0x41, 0, 0x0b];
        let callback = [
            0, 0x20, 0, 0x41, 10, 0x6c, 0x20, 1, 0x6a, 0x41, 10, 0x6c, 0x20, 2, 0x6a, 0x41, 10,
            0x6c, 0x20, 3, 0x6a, 0x0b,
        ];
        let mut code = vec![2, start.len() as u8];
        code.extend_from_slice(&start);
        code.push(callback.len() as u8);
        code.extend_from_slice(&callback);
        section(&mut wasm, 10, &code);
        let mut module = g6b_asm::analyze::kstart(&spec);
        install_guest(&mut module, &wasm).unwrap();
        let mut probe = put_str_ops("ARGS=");
        for (rd, imm) in [(A0, 1), (A1, 4), (A2, 1), (A3, 2), (A4, 3), (A5, 4)] {
            probe.push(Op::Li { rd, imm });
        }
        probe.extend([
            Op::Jal {
                rd: RA,
                to: "JitCall".into(),
            },
            Op::Addi {
                rd: T0,
                rs: A0,
                imm: 0,
            },
        ]);
        probe.extend(hex_t0_ops("args_hex"));
        probe.extend(put_str_ops("\n"));
        for (i, (fidx, nargs)) in [(1, 5), (2, 0), (256, 0), (-1, 0)].into_iter().enumerate() {
            probe.extend(put_str_ops(&format!("BAD{i}=")));
            probe.extend([
                Op::Li { rd: A0, imm: fidx },
                Op::Li { rd: A1, imm: nargs },
                Op::Jal {
                    rd: RA,
                    to: "JitCall".into(),
                },
                Op::Addi {
                    rd: T0,
                    rs: A0,
                    imm: 0,
                },
            ]);
            probe.extend(hex_t0_ops(&format!("bad{i}_hex")));
            probe.extend(put_str_ops("\n"));
        }
        let node = module
            .nodes
            .iter_mut()
            .find(|n| {
                n.ops
                    .iter()
                    .any(|o| matches!(o, Op::Jal { to, .. } if to == "JitRun"))
            })
            .unwrap();
        let at = node
            .ops
            .iter()
            .position(|o| matches!(o, Op::Jal { to, .. } if to == "JitRun"))
            .unwrap()
            + 1;
        node.ops.splice(at..at, probe);
        let smoke = g6b_asm::exec::run_module(&spec, &module, 0x8020_0000).unwrap();
        assert_eq!(smoke.faults, 0);
        assert!(
            smoke.console.contains("ARGS=00000000000004d2"),
            "{}",
            smoke.console
        );
        for i in 0..4 {
            assert!(
                smoke.console.contains(&format!("BAD{i}=ffffffffffffffff")),
                "{}",
                smoke.console
            );
        }
        assert!(!smoke.console.contains("TRAP-"));
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
            (
                "/bios/menu/main".into(),
                "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into(),
            ),
            (
                "/bios/menu/cpu".into(),
                "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into(),
            ),
            (
                "/bios/menu/memory".into(),
                "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into(),
            ),
            (
                "/bios/menu/uncore".into(),
                "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into(),
            ),
            (
                "/bios/menu/devices".into(),
                "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into(),
            ),
            (
                "/bios/menu/boot".into(),
                "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into(),
            ),
            (
                "/bios/menu/settings".into(),
                "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into(),
            ),
            ("/bios/store".into(), "[]".into()),
        ])
        .unwrap();

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
                    Op::Jal {
                        rd: RA,
                        to: "DomtFocus".into(),
                    },
                    Op::La {
                        rd: T0,
                        addr: Addr::VioBss,
                    },
                    Op::Li {
                        rd: T1,
                        imm: (VIO_KEY_ENTER << 8) | 1,
                    },
                    Op::Sw {
                        rs2: T1,
                        rs1: T0,
                        off: INP_KQ_OFF,
                    },
                    Op::Li { rd: T1, imm: 1 },
                    Op::Sw {
                        rs2: T1,
                        rs1: T0,
                        off: INP_KQ_HEAD,
                    },
                    Op::Sw {
                        rs2: X0,
                        rs1: T0,
                        off: DOMT_SEEN_OFF,
                    },
                    Op::Jal {
                        rd: RA,
                        to: "DomtKey".into(),
                    },
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
                    Op::La {
                        rd: T0,
                        addr: Addr::VioBss,
                    },
                    Op::Li {
                        rd: T1,
                        imm: (VIO_KEY_ENTER << 8) | 1,
                    },
                    Op::Sw {
                        rs2: T1,
                        rs1: T0,
                        off: INP_KQ_OFF,
                    },
                    Op::Li { rd: T1, imm: 1 },
                    Op::Sw {
                        rs2: T1,
                        rs1: T0,
                        off: INP_KQ_HEAD,
                    },
                    Op::Sw {
                        rs2: X0,
                        rs1: T0,
                        off: DOMT_SEEN_OFF,
                    },
                    Op::Jal {
                        rd: RA,
                        to: "DomtKey".into(),
                    },
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
                n.ops.splice(
                    pos + 1..pos + 1,
                    vec![Op::Jal {
                        rd: RA,
                        to: "DomtLayout".into(),
                    }],
                );
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

    /// `__prom` rejection surface — the guest-side correlate of the
    /// interpreter's `libwasm_await_failed`/`_error` (the reject→catch gate).
    /// `LwFetch` on a url absent from `__kget` returns a `PROM_ST_PEND` record
    /// (the fetch is in-flight; `PromDrain` re-runs `KernelGet` on the stored
    /// url and rejects at `PR_BUDGET`=0). After the forced drain the record is
    /// `PROM_ST_REJ` (the failing url as the reason); `libwasm_await__void`
    /// flags it so `libwasm_await_failed` returns 1 and `libwasm_await_error`
    /// writes the reason span. A known `/bios/*` url fulfils (`PROM_ST_FUL`)
    /// for contrast. The probe runs after `JitRun` so the table is live.
    #[test]
    fn guest_jit_fetch_reject_sets_await_failed() {
        use g6b_asm::domt::{PROM_ST_FUL, PROM_ST_REJ, PR_STATE, P_AFAIL};
        use g6b_asm::encode::{A0, A1, RA, S0, T0, T1, T2};
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
        m.kget = g6b_asm::kget::build(&[(
            "/bios/menu/main".into(),
            "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into(),
        )])
        .unwrap();

        // __wasm_mem scratch (the free-heap offset the asyncify probe uses).
        const URL: i64 = 0x10_ff00;
        const OUT: i64 = 0x10_fd00;
        let mut probe: Vec<Op> = Vec::new();
        // Write "/no" at __wasm_mem[URL].
        probe.extend([
            Op::La {
                rd: T1,
                addr: Addr::WasmMem,
            },
            Op::Li { rd: T2, imm: URL },
            Op::Add {
                rd: T1,
                rs1: T1,
                rs2: T2,
            },
        ]);
        for (i, b) in b"/no".iter().enumerate() {
            probe.extend([
                Op::Li {
                    rd: T2,
                    imm: i64::from(*b),
                },
                Op::Sb {
                    rs2: T2,
                    rs1: T1,
                    off: i as i32,
                },
            ]);
        }
        probe.extend(put_str_ops(" BAD"));
        // s0 = LwFetch(URL, 3) — a missing url → PENDING promise (the host
        // `PromDrain` poll settles it; `__kget` is the route cache).
        probe.extend([
            Op::Li { rd: A0, imm: URL },
            Op::Li { rd: A1, imm: 3 },
            Op::Jal {
                rd: RA,
                to: "LwFetch".into(),
            },
            Op::Addi {
                rd: S0,
                rs: A0,
                imm: 0,
            },
        ]);
        // t0 = PromGet(s0).state — expect PROM_ST_PEND (pending until drained).
        probe.extend([
            Op::Addi {
                rd: A0,
                rs: S0,
                imm: 0,
            },
            Op::Jal {
                rd: RA,
                to: "PromGet".into(),
            },
            Op::Lw {
                rd: T0,
                rs: A0,
                off: PR_STATE,
            },
        ]);
        probe.extend(put_str_ops(" RS"));
        probe.extend(hex_t0_ops("pr_hex0"));
        // Force the poll window shut (PR_BUDGET=1) then PromDrain → the miss
        // settles REJ, so the await below takes the rejected path (not the
        // pending suspend arm).
        probe.extend([
            Op::Addi {
                rd: A0,
                rs: S0,
                imm: 0,
            },
            Op::Jal {
                rd: RA,
                to: "PromGet".into(),
            },
            Op::Li { rd: T2, imm: 1 },
            Op::Sw {
                rs2: T2,
                rs1: A0,
                off: g6b_asm::domt::PR_BUDGET,
            },
            Op::Jal {
                rd: RA,
                to: "PromDrain".into(),
            },
        ]);
        // t0 = PromGet(s0).state — expect PROM_ST_REJ after the drain.
        probe.extend([
            Op::Addi {
                rd: A0,
                rs: S0,
                imm: 0,
            },
            Op::Jal {
                rd: RA,
                to: "PromGet".into(),
            },
            Op::Lw {
                rd: T0,
                rs: A0,
                off: PR_STATE,
            },
        ]);
        probe.extend(put_str_ops(" RD"));
        probe.extend(hex_t0_ops("pr_hex0b"));
        // LwAwaitVoid(s0) → afail=1 ; then LwAwaitFail → a0.
        probe.extend([
            Op::Addi {
                rd: A0,
                rs: S0,
                imm: 0,
            },
            Op::Jal {
                rd: RA,
                to: "LwAwaitVoid".into(),
            },
            Op::Jal {
                rd: RA,
                to: "LwAwaitFail".into(),
            },
            Op::Addi {
                rd: T0,
                rs: A0,
                imm: 0,
            },
        ]);
        probe.extend(put_str_ops(" AF"));
        probe.extend(hex_t0_ops("pr_hex1"));
        // LwAwaitErr(OUT) writes {len=3,ptr=URL}; read len back → t0.
        probe.extend([
            Op::Li { rd: A0, imm: OUT },
            Op::Jal {
                rd: RA,
                to: "LwAwaitErr".into(),
            },
            Op::La {
                rd: T1,
                addr: Addr::WasmMem,
            },
            Op::Li { rd: T2, imm: OUT },
            Op::Add {
                rd: T1,
                rs1: T1,
                rs2: T2,
            },
            Op::Lw {
                rd: T0,
                rs: T1,
                off: 0,
            },
        ]);
        probe.extend(put_str_ops(" EL"));
        probe.extend(hex_t0_ops("pr_hex2"));
        // Contrast: a known url fulfils — PromGet(handle).state == PROM_ST_FUL.
        probe.extend([
            Op::La {
                rd: T1,
                addr: Addr::WasmMem,
            },
            Op::Li { rd: T2, imm: URL },
            Op::Add {
                rd: T1,
                rs1: T1,
                rs2: T2,
            },
        ]);
        for (i, b) in b"/bios/menu/main".iter().enumerate() {
            probe.extend([
                Op::Li {
                    rd: T2,
                    imm: i64::from(*b),
                },
                Op::Sb {
                    rs2: T2,
                    rs1: T1,
                    off: i as i32,
                },
            ]);
        }
        probe.extend(put_str_ops(" OK"));
        probe.extend([
            Op::Li { rd: A0, imm: URL },
            Op::Li { rd: A1, imm: 15 },
            Op::Jal {
                rd: RA,
                to: "LwFetch".into(),
            },
            Op::Addi {
                rd: S0,
                rs: A0,
                imm: 0,
            },
            Op::Addi {
                rd: A0,
                rs: S0,
                imm: 0,
            },
            Op::Jal {
                rd: RA,
                to: "PromGet".into(),
            },
            Op::Lw {
                rd: T0,
                rs: A0,
                off: PR_STATE,
            },
        ]);
        probe.extend(put_str_ops(" FS"));
        probe.extend(hex_t0_ops("pr_hex3"));
        // note_await round-trip on the fulfilled handle s0: note_await_fail
        // flags afail=1, note_await_ok clears it — the host-recorded outcome
        // `libwasm_await_failed` then reports.
        probe.extend([
            Op::Addi {
                rd: A0,
                rs: S0,
                imm: 0,
            },
            Op::Jal {
                rd: RA,
                to: "LwNoteRej".into(),
            },
            Op::Jal {
                rd: RA,
                to: "LwAwaitFail".into(),
            },
            Op::Addi {
                rd: T0,
                rs: A0,
                imm: 0,
            },
        ]);
        probe.extend(put_str_ops(" NR"));
        probe.extend(hex_t0_ops("pr_hex4"));
        probe.extend([
            Op::Addi {
                rd: A0,
                rs: S0,
                imm: 0,
            },
            Op::Jal {
                rd: RA,
                to: "LwNoteFul".into(),
            },
            Op::Jal {
                rd: RA,
                to: "LwAwaitFail".into(),
            },
            Op::Addi {
                rd: T0,
                rs: A0,
                imm: 0,
            },
        ]);
        probe.extend(put_str_ops(" NF"));
        probe.extend(hex_t0_ops("pr_hex5"));
        probe.extend(put_str_ops("\n"));

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
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
        assert!(!s.console.contains("WASM-JIT-TRAP"), "{}", s.console);
        assert_eq!(s.faults, 0, "fault-free: {}", s.console);
        let want = format!("RS{:016x}", g6b_asm::domt::PROM_ST_PEND);
        assert!(s.console.contains(&want), "pending state: {}", s.console);
        let want = format!("RD{:016x}", PROM_ST_REJ);
        assert!(
            s.console.contains(&want),
            "rejected after drain: {}",
            s.console
        );
        assert!(
            s.console.contains("AF0000000000000001"),
            "afail=1: {}",
            s.console
        );
        assert!(
            s.console.contains("EL0000000000000003"),
            "reason len=3: {}",
            s.console
        );
        let ful = format!("FS{:016x}", PROM_ST_FUL);
        assert!(s.console.contains(&ful), "fulfilled state: {}", s.console);
        assert!(
            s.console.contains("NR0000000000000001"),
            "note_await_fail → afail=1: {}",
            s.console
        );
        assert!(
            s.console.contains("NF0000000000000000"),
            "note_await_ok → afail=0: {}",
            s.console
        );
        let _ = (P_AFAIL, A0, A1, RA, S0, T0, T1, T2); // silence unused-import lint
    }

    /// End-to-end pending→suspend→settle→resume on the *real* shipped cell.
    /// `/bios/menu/main` is left out of `__kget`, so its `fetch` returns a
    /// `PROM_ST_PEND` record; the cell's `await` then parks `_start`
    /// (`LwAwaitVoid`→`P_ASUSP` + asyncify unwind, `jit_after` arms the rewind
    /// and drops to `jit_result`). The probe (foreground, after `JitRun`) caps
    /// the record's `PR_BUDGET` so the one boot timer tick's `trap_timer` →
    /// `PromDrain` settles it (reject) → `P_RESUME` → `JitCall(_start)` rewinds
    /// into the await continuation.
    ///
    /// Proof of resume: the console prints `v1s0` (await(1) armed the unwind in
    /// `NORMAL`) then `WASM-JIT 0` — `jit_after` parking early on the pending
    /// record. Only *after* that park does `v1s2` appear — `await(1)` re-invoked
    /// with `__asyncify_state==REWINDING`, i.e. the `JitCall` rewind re-call —
    /// followed by the cell's own rejection-handling output. `v1s2` can only be
    /// emitted by the resumed `_start`; in the all-fulfilled baseline it never
    /// appears after the (final) `WASM-JIT` marker.
    #[test]
    fn guest_jit_pending_await_suspends_then_resumes() {
        pending_await_resume(false, false);
    }

    /// `PromCtx(1)` parks the await on table slot 1; header `P_ASUSP` (slot 0)
    /// stays 0 so two contexts cannot alias the one image-global suspend.
    #[test]
    fn guest_jit_ctx1_suspend_does_not_alias_slot0() {
        use g6b_asm::domt::{PCTX_ASUSP, PROM_CTX_OFF, PROM_CTX_STRIDE, P_ASUSP};
        use g6b_asm::encode::{A1, T1};

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
        install_guest(&mut m, &test_module_delegate()).expect("cell installs");
        const URL: i64 = 0x10_fe00;
        let mut probe = vec![
            Op::La {
                rd: T1,
                addr: Addr::WasmMem,
            },
            Op::Li { rd: T2, imm: URL },
            Op::Add {
                rd: T1,
                rs1: T1,
                rs2: T2,
            },
        ];
        for (i, b) in b"/no".iter().enumerate() {
            probe.extend([
                Op::Li {
                    rd: T2,
                    imm: i64::from(*b),
                },
                Op::Sb {
                    rs2: T2,
                    rs1: T1,
                    off: i as i32,
                },
            ]);
        }
        probe.extend([
            Op::Li { rd: A0, imm: 1 },
            Op::Jal {
                rd: RA,
                to: "PromCtx".into(),
            },
            Op::Li { rd: A0, imm: URL },
            Op::Li { rd: A1, imm: 3 },
            Op::Jal {
                rd: RA,
                to: "LwFetch".into(),
            },
            Op::Jal {
                rd: RA,
                to: "LwAwaitVoid".into(),
            },
        ]);
        probe.extend(put_str_ops("C0="));
        probe.extend([
            Op::La {
                rd: T0,
                addr: Addr::Prom,
            },
            Op::Lw {
                rd: T0,
                rs: T0,
                off: P_ASUSP,
            },
        ]);
        probe.extend(hex_t0_ops("ctx0_asusp"));
        probe.extend(put_str_ops(" C1="));
        probe.extend([
            Op::La {
                rd: T0,
                addr: Addr::Prom,
            },
            Op::Li {
                rd: T1,
                imm: i64::from(PROM_CTX_OFF + PROM_CTX_STRIDE),
            },
            Op::Add {
                rd: T0,
                rs1: T0,
                rs2: T1,
            },
            Op::Lw {
                rd: T0,
                rs: T0,
                off: PCTX_ASUSP,
            },
        ]);
        probe.extend(hex_t0_ops("ctx1_asusp"));
        probe.extend(put_str_ops("\n"));
        for n in &mut m.nodes {
            if let Some(pos) = n
                .ops
                .iter()
                .position(|o| matches!(o, Op::Jal { to, .. } if to == "JitRun"))
            {
                n.ops.splice(pos + 1..pos + 1, probe);
                break;
            }
        }
        let s = g6b_asm::exec::run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
        assert_eq!(s.faults, 0, "{}", s.console);
        assert!(
            s.console.contains("C0=0000000000000000"),
            "slot 0 must stay empty:\n{}",
            s.console
        );
        let c1 = s.console.split("C1=").nth(1).unwrap_or("");
        let c1 = &c1[..16.min(c1.len())];
        assert_ne!(
            c1, "0000000000000000",
            "ctx1 must hold the await:\n{}",
            s.console
        );
    }

    /// `PromCtx` spills/fills the `__jit` EH bank so slot 1 cannot see
    /// slot 0's in-flight exception.
    #[test]
    fn guest_jit_promctx_isolates_exc_bank() {
        use g6b_asm::encode::{A0, RA, T0, T1};
        use g6b_asm::jitr::OFF_EXC;
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
        install_guest(&mut m, &test_module_delegate()).expect("cell installs");
        let jit_exc = |rd| {
            vec![
                Op::La {
                    rd,
                    addr: Addr::JitHdr,
                },
                Op::Li {
                    rd: T1,
                    imm: i64::from(OFF_EXC),
                },
                Op::Add {
                    rd,
                    rs1: rd,
                    rs2: T1,
                },
            ]
        };
        let mut probe = jit_exc(T0);
        probe.extend([
            Op::Li { rd: T1, imm: 1 },
            Op::Sd {
                rs2: T1,
                rs1: T0,
                off: 0,
            },
            Op::Li { rd: T1, imm: 7 },
            Op::Sd {
                rs2: T1,
                rs1: T0,
                off: 8,
            },
            Op::Li { rd: T1, imm: 99 },
            Op::Sd {
                rs2: T1,
                rs1: T0,
                off: 16,
            },
            Op::Li { rd: A0, imm: 1 },
            Op::Jal {
                rd: RA,
                to: "PromCtx".into(),
            },
        ]);
        probe.extend(put_str_ops("E1="));
        probe.extend(jit_exc(T0));
        probe.push(Op::Ld {
            rd: T0,
            rs: T0,
            off: 0,
        });
        probe.extend(hex_t0_ops("exc1"));
        probe.extend([
            Op::Li { rd: A0, imm: 0 },
            Op::Jal {
                rd: RA,
                to: "PromCtx".into(),
            },
        ]);
        probe.extend(put_str_ops(" T0="));
        probe.extend(jit_exc(T0));
        probe.push(Op::Ld {
            rd: T0,
            rs: T0,
            off: 8,
        });
        probe.extend(hex_t0_ops("tag0"));
        probe.extend(put_str_ops(" P0="));
        probe.extend(jit_exc(T0));
        probe.push(Op::Ld {
            rd: T0,
            rs: T0,
            off: 16,
        });
        probe.extend(hex_t0_ops("pay0"));
        probe.extend(put_str_ops("\n"));
        for n in &mut m.nodes {
            if let Some(pos) = n
                .ops
                .iter()
                .position(|o| matches!(o, Op::Jal { to, .. } if to == "JitRun"))
            {
                n.ops.splice(pos + 1..pos + 1, probe);
                break;
            }
        }
        let s = g6b_asm::exec::run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
        assert_eq!(s.faults, 0, "{}", s.console);
        assert!(
            s.console.contains("E1=0000000000000000"),
            "slot 1 must not see slot 0 EXC:\n{}",
            s.console
        );
        assert!(
            s.console.contains("T0=0000000000000007"),
            "slot 0 EXCTAG restored:\n{}",
            s.console
        );
        assert!(
            s.console.contains("P0=0000000000000063"),
            "slot 0 EXCPAY restored:\n{}",
            s.console
        );
    }

    /// Outermost user `JitCall` restores the caller's EH bank after the
    /// nested invoke (listeners must not clobber `EXCPAY`).
    #[test]
    fn guest_jit_jitcall_restores_exc_bank() {
        use g6b_asm::encode::{A0, A1, RA, T0, T1};
        use g6b_asm::jfmt::OFF_ENTRY;
        use g6b_asm::jitr::OFF_EXC;
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
        install_guest(&mut m, &test_module_eh()).expect("eh cell installs");
        let jit_exc = |rd| {
            vec![
                Op::La {
                    rd,
                    addr: Addr::JitHdr,
                },
                Op::Li {
                    rd: T1,
                    imm: i64::from(OFF_EXC),
                },
                Op::Add {
                    rd,
                    rs1: rd,
                    rs2: T1,
                },
            ]
        };
        let mut probe = jit_exc(T0);
        probe.extend([
            Op::Li { rd: T1, imm: 1 },
            Op::Sd {
                rs2: T1,
                rs1: T0,
                off: 0,
            },
            Op::Li { rd: T1, imm: 7 },
            Op::Sd {
                rs2: T1,
                rs1: T0,
                off: 8,
            },
            Op::Li { rd: T1, imm: 99 },
            Op::Sd {
                rs2: T1,
                rs1: T0,
                off: 16,
            },
            Op::La {
                rd: A0,
                addr: Addr::JitIn,
            },
            Op::Lw {
                rd: A0,
                rs: A0,
                off: OFF_ENTRY as i32,
            },
            Op::Li { rd: A1, imm: 0 },
            Op::Jal {
                rd: RA,
                to: "JitCall".into(),
            },
        ]);
        probe.extend(put_str_ops("T0="));
        probe.extend(jit_exc(T0));
        probe.push(Op::Ld {
            rd: T0,
            rs: T0,
            off: 8,
        });
        probe.extend(hex_t0_ops("jc_tag"));
        probe.extend(put_str_ops(" P0="));
        probe.extend(jit_exc(T0));
        probe.push(Op::Ld {
            rd: T0,
            rs: T0,
            off: 16,
        });
        probe.extend(hex_t0_ops("jc_pay"));
        probe.extend(put_str_ops("\n"));
        for n in &mut m.nodes {
            if let Some(pos) = n
                .ops
                .iter()
                .position(|o| matches!(o, Op::Jal { to, .. } if to == "JitRun"))
            {
                n.ops.splice(pos + 1..pos + 1, probe);
                break;
            }
        }
        let s = g6b_asm::exec::run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
        assert_eq!(s.faults, 0, "{}", s.console);
        assert!(
            s.console.contains("T0=0000000000000007"),
            "JitCall must restore caller EXCTAG:\n{}",
            s.console
        );
        assert!(
            s.console.contains("P0=0000000000000063"),
            "JitCall must restore caller EXCPAY:\n{}",
            s.console
        );
    }

    #[test]
    fn guest_jit_late_fulfillment_finishes_subsequent_awaits() {
        pending_await_resume(true, false);
    }

    #[test]
    fn guest_jit_resumed_call_can_suspend_again() {
        pending_await_resume(true, true);
    }

    fn pending_await_resume(fulfill: bool, twice: bool) {
        use g6b_asm::domt::P_ASUSP;
        use g6b_asm::encode::{A0, RA, T0, T1, T2};
        use g6b_asm::{Addr, Op};

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
        // Bake every route EXCEPT the first-fetched menu — its `fetch` pends.
        m.kget = g6b_asm::kget::build(&[
            (
                "/bios/menu/cpu".into(),
                "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into(),
            ),
            (
                "/bios/menu/memory".into(),
                "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into(),
            ),
            (
                "/bios/menu/uncore".into(),
                "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into(),
            ),
            (
                "/bios/menu/devices".into(),
                "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into(),
            ),
            (
                "/bios/menu/boot".into(),
                "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into(),
            ),
            (
                "/bios/menu/settings".into(),
                "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into(),
            ),
            ("/bios/store".into(), "[]".into()),
        ])
        .unwrap();

        if twice {
            let url_off = u32::from_le_bytes(m.kget[16..20].try_into().unwrap()) as usize;
            m.kget[url_off + 11] = b'X';
        }

        // Probe (foreground, after JitRun): the cell is suspended on the pending
        // `main` fetch — `P_ASUSP` holds its handle. Cap that record's
        // `PR_BUDGET` to 1 so the boot timer tick's `PromDrain` rejects it.
        let mut probe = vec![
            Op::La {
                rd: T0,
                addr: Addr::Prom,
            },
            Op::Lw {
                rd: A0,
                rs: T0,
                off: P_ASUSP,
            },
            Op::Jal {
                rd: RA,
                to: "PromGet".into(),
            }, // a0 = suspended rec|0
            Op::Beq {
                rs1: A0,
                rs2: X0,
                to: "pd_probe_done".into(),
            },
            Op::Li { rd: T2, imm: 1 },
            Op::Sw {
                rs2: T2,
                rs1: A0,
                off: g6b_asm::domt::PR_BUDGET,
            },
            Op::Label("pd_probe_done".into()),
        ];
        if fulfill {
            let body_off = u32::from_le_bytes(m.kget[24..28].try_into().unwrap());
            let body_len = u32::from_le_bytes(m.kget[28..32].try_into().unwrap());
            let at = probe.len() - 1;
            let settle = [
                Op::Li {
                    rd: T2,
                    imm: i64::from(body_off),
                },
                Op::Sw {
                    rs2: T2,
                    rs1: A0,
                    off: g6b_asm::domt::PR_VOFF,
                },
                Op::Li {
                    rd: T2,
                    imm: i64::from(body_len),
                },
                Op::Sw {
                    rs2: T2,
                    rs1: A0,
                    off: g6b_asm::domt::PR_VLEN,
                },
                Op::Li {
                    rd: T2,
                    imm: g6b_asm::domt::PROM_ST_FUL,
                },
                Op::Sw {
                    rs2: T2,
                    rs1: A0,
                    off: g6b_asm::domt::PR_STATE,
                },
            ];
            probe.splice(at..at, settle.clone());
            if twice {
                let at = probe.len() - 1;
                let mut again = vec![
                    Op::Jal {
                        rd: RA,
                        to: "PromDrain".into(),
                    },
                    Op::La {
                        rd: T0,
                        addr: Addr::Prom,
                    },
                    Op::Sw {
                        rs2: X0,
                        rs1: T0,
                        off: g6b_asm::domt::P_RESUME,
                    },
                    Op::Jal {
                        rd: RA,
                        to: "JitResume".into(),
                    },
                ];
                again.extend(put_str_ops("SUSPENDED="));
                again.extend([
                    Op::La {
                        rd: T0,
                        addr: Addr::Prom,
                    },
                    Op::Lw {
                        rd: T0,
                        rs: T0,
                        off: P_ASUSP,
                    },
                ]);
                again.extend(hex_t0_ops("second_suspend_hex"));
                again.extend([
                    Op::La {
                        rd: T0,
                        addr: Addr::Prom,
                    },
                    Op::Lw {
                        rd: A0,
                        rs: T0,
                        off: P_ASUSP,
                    },
                    Op::Jal {
                        rd: RA,
                        to: "PromGet".into(),
                    },
                    Op::Beq {
                        rs1: A0,
                        rs2: X0,
                        to: "pd_probe_done".into(),
                    },
                ]);
                again.extend(settle);
                probe.splice(at..at, again);
            }
        }

        let mut placed = false;
        for n in &mut m.nodes {
            if let Some(pos) = n
                .ops
                .iter()
                .position(|o| matches!(o, Op::Jal { to, .. } if to == "JitRun"))
            {
                n.ops.splice(pos + 1..pos + 1, probe.clone());
                placed = true;
                break;
            }
        }
        assert!(placed, "no JitRun call site to splice after");
        let s = g6b_asm::exec::run_module(&spec, &m, 0x8020_0000).unwrap();
        eprintln!("=== SUSPEND/RESUME CONSOLE ===\n{}", s.console);
        // Suspend: await(1) armed the unwind in NORMAL (`v1s0`), then `jit_after`
        // parked on the still-pending record and `JitRun` returned (`WASM-JIT 0`).
        assert!(s.console.contains("v1s0"), "suspend:\n{}", s.console);
        // Resume: a timer tick drained the record (budget expiry → reject),
        // raised `P_RESUME`, and the foreground `JitCall` rewound `_start` — the
        // `v1s2` re-call of await(1) in REWINDING only runs post-park.
        let parked = s.console.find("WASM-JIT 0").expect("jit_after parked");
        if fulfill {
            assert!(
                s.console[parked..].contains("v8s2"),
                "resume must finish subsequent awaits: {}",
                s.console
            );
            assert!(s.domt_live > 56, "late results must populate DOM rows");
        }
        if twice {
            assert!(
                s.console.contains("SUSPENDED=0000000000000002"),
                "{}",
                s.console
            );
        }
        assert!(
            s.console[parked..].contains("v1s2"),
            "resumed into the await continuation (rewind re-call):\n{}",
            s.console
        );
        assert_eq!(s.faults, 0, "fault-free: {}", s.console);
        let _ = (A0, RA, T0, T1, T2);
    }

    /// `libasync_promise_*` combinators over a `__prom` i32-array — the
    /// guest-side `Promise.all`/`any`/`allSettled`. `LwAddInts` wraps a
    /// `__wasm_mem` i32 span as a `PROM_K_IARR` handle; the combinators then
    /// aggregate the input records' settle states into a fresh promise:
    /// all→FUL unless one input REJ; any→FUL on the first FUL else REJ;
    /// allSettled→FUL once every input settled (mixed ful+rej still fulfils).
    #[test]
    fn guest_jit_promise_combinators() {
        use g6b_asm::domt::{PROM_ST_FUL, PROM_ST_REJ, PR_STATE};
        use g6b_asm::encode::{A0, A1, RA, S0, S1, S2, T0, T1, T2};
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
        m.kget = g6b_asm::kget::build(&[(
            "/bios/menu/main".into(),
            "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into(),
        )])
        .unwrap();

        const G: i64 = 0x10_ff00; // good url
        const B: i64 = 0x10_fe00; // bad url
        const ARR: i64 = 0x10_fc00; // i32 handle array
        let wstr = |probe: &mut Vec<Op>, off: i64, s: &[u8]| {
            probe.extend([
                Op::La {
                    rd: T1,
                    addr: Addr::WasmMem,
                },
                Op::Li { rd: T2, imm: off },
                Op::Add {
                    rd: T1,
                    rs1: T1,
                    rs2: T2,
                },
            ]);
            for (i, b) in s.iter().enumerate() {
                probe.extend([
                    Op::Li {
                        rd: T2,
                        imm: i64::from(*b),
                    },
                    Op::Sb {
                        rs2: T2,
                        rs1: T1,
                        off: i as i32,
                    },
                ]);
            }
        };
        let mut probe: Vec<Op> = Vec::new();
        wstr(&mut probe, G, b"/bios/menu/main");
        wstr(&mut probe, B, b"/no");
        // s0 = LwFetch(G) → fulfilled ; s1 = LwFetch(B) → pending, then
        // drained to rejected (PR_BUDGET=1 → the miss fails closed on the poll).
        probe.extend([
            Op::Li { rd: A0, imm: G },
            Op::Li { rd: A1, imm: 15 },
            Op::Jal {
                rd: RA,
                to: "LwFetch".into(),
            },
            Op::Addi {
                rd: S0,
                rs: A0,
                imm: 0,
            },
            Op::Li { rd: A0, imm: B },
            Op::Li { rd: A1, imm: 3 },
            Op::Jal {
                rd: RA,
                to: "LwFetch".into(),
            },
            Op::Addi {
                rd: S1,
                rs: A0,
                imm: 0,
            },
            // s1's record: budget=1 then PromDrain → REJ
            Op::Addi {
                rd: A0,
                rs: S1,
                imm: 0,
            },
            Op::Jal {
                rd: RA,
                to: "PromGet".into(),
            },
            Op::Li { rd: T2, imm: 1 },
            Op::Sw {
                rs2: T2,
                rs1: A0,
                off: g6b_asm::domt::PR_BUDGET,
            },
            Op::Jal {
                rd: RA,
                to: "PromDrain".into(),
            },
        ]);
        // Write an i32 array and combin over it. `mkarr(off, [regs])` stores
        // each handle then `LwAddInts(len, off)` → s2 = array handle.
        let mkarr = |probe: &mut Vec<Op>, off: i64, elems: &[u32]| {
            probe.extend([
                Op::La {
                    rd: T1,
                    addr: Addr::WasmMem,
                },
                Op::Li { rd: T2, imm: off },
                Op::Add {
                    rd: T1,
                    rs1: T1,
                    rs2: T2,
                },
            ]);
            for (i, r) in elems.iter().enumerate() {
                probe.push(Op::Sw {
                    rs2: *r,
                    rs1: T1,
                    off: (i * 4) as i32,
                });
            }
            probe.extend([
                Op::Li {
                    rd: A0,
                    imm: elems.len() as i64,
                },
                Op::Li { rd: A1, imm: off },
                Op::Jal {
                    rd: RA,
                    to: "LwAddInts".into(),
                },
                Op::Addi {
                    rd: S2,
                    rs: A0,
                    imm: 0,
                },
            ]);
        };
        // cmb(label) → s2 = array, call combinator → PromGet.state → hex.
        let cmb = |probe: &mut Vec<Op>, tag: &str, to: &str, hexn: &str| {
            probe.extend([
                Op::Addi {
                    rd: A0,
                    rs: S2,
                    imm: 0,
                },
                Op::Jal {
                    rd: RA,
                    to: to.into(),
                },
                Op::Jal {
                    rd: RA,
                    to: "PromGet".into(),
                },
                Op::Lw {
                    rd: T0,
                    rs: A0,
                    off: PR_STATE,
                },
            ]);
            probe.extend(put_str_ops(tag));
            probe.extend(hex_t0_ops(hexn));
        };
        // all([ful,ful]) → FUL
        mkarr(&mut probe, ARR, &[S0, S0]);
        cmb(&mut probe, " A1=", "LwPromAll", "pc_a1");
        // all([ful,rej]) → REJ
        mkarr(&mut probe, ARR + 0x20, &[S0, S1]);
        cmb(&mut probe, " A2=", "LwPromAll", "pc_a2");
        // any([rej,rej]) → REJ
        mkarr(&mut probe, ARR + 0x40, &[S1, S1]);
        cmb(&mut probe, " A3=", "LwPromAny", "pc_a3");
        // any([rej,ful]) → FUL
        mkarr(&mut probe, ARR + 0x60, &[S1, S0]);
        cmb(&mut probe, " A4=", "LwPromAny", "pc_a4");
        // allsettled([ful,rej]) → FUL
        mkarr(&mut probe, ARR + 0x80, &[S0, S1]);
        cmb(&mut probe, " A5=", "LwPromAlls", "pc_a5");
        probe.extend(put_str_ops("\n"));

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
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
        assert!(!s.console.contains("WASM-JIT-TRAP"), "{}", s.console);
        assert_eq!(s.faults, 0, "fault-free: {}", s.console);
        let ful = format!("{:016x}", PROM_ST_FUL);
        let rej = format!("{:016x}", PROM_ST_REJ);
        assert!(
            s.console.contains(&format!("A1={}", ful)),
            "all(ful,ful)→FUL: {}",
            s.console
        );
        assert!(
            s.console.contains(&format!("A2={}", rej)),
            "all(ful,rej)→REJ: {}",
            s.console
        );
        assert!(
            s.console.contains(&format!("A3={}", rej)),
            "any(rej,rej)→REJ: {}",
            s.console
        );
        assert!(
            s.console.contains(&format!("A4={}", ful)),
            "any(rej,ful)→FUL: {}",
            s.console
        );
        assert!(
            s.console.contains(&format!("A5={}", ful)),
            "alls(ful,rej)→FUL: {}",
            s.console
        );
        let _ = (A0, A1, RA, S0, S1, S2, T0, T1, T2);
    }

    /// `PromDrain` settles a pending `__prom` fetch record — the drain half of
    /// the suspend/resume lane. The probe allocs a record, points its
    /// `PR_AOFF`/`PR_ALEN` at a live `__kget` url, leaves it `PROM_ST_PEND`,
    /// and calls `PromDrain`: the record's `KernelGet` lands → `PROM_ST_FUL`
    /// with the body span. A second record on a missing url stays pending until
    /// `PR_BUDGET` lapses — here budgeted to drain-reject on the same pass.
    #[test]
    fn guest_jit_prom_drain_settles_pending() {
        use g6b_asm::domt::{PROM_ST_FUL, PROM_ST_PEND, PROM_ST_REJ, PR_ALEN, PR_AOFF, PR_STATE};
        use g6b_asm::encode::{A0, RA, S0, S1, T0, T1, T2};
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
        m.kget = g6b_asm::kget::build(&[(
            "/bios/menu/main".into(),
            "[{\"id\":\"a\",\"label\":\"b\",\"value\":\"c\",\"writable\":false}]".into(),
        )])
        .unwrap();

        const G: i64 = 0x10_ff00; // good url
        const B: i64 = 0x10_fe00; // missing url
        let mut probe: Vec<Op> = Vec::new();
        for (off, s) in [(G, &b"/bios/menu/main"[..]), (B, &b"/no"[..])] {
            probe.extend([
                Op::La {
                    rd: T1,
                    addr: Addr::WasmMem,
                },
                Op::Li { rd: T2, imm: off },
                Op::Add {
                    rd: T1,
                    rs1: T1,
                    rs2: T2,
                },
            ]);
            for (i, b) in s.iter().enumerate() {
                probe.extend([
                    Op::Li {
                        rd: T2,
                        imm: i64::from(*b),
                    },
                    Op::Sb {
                        rs2: T2,
                        rs1: T1,
                        off: i as i32,
                    },
                ]);
            }
        }
        // s0 = PromAlloc() — a pending fetch record; point its url at G.
        // s1 = PromAlloc() — a second pending record; point its url at B.
        for (sreg, url, ulen) in [(S0, G, 15i64), (S1, B, 3i64)] {
            probe.extend([
                Op::Jal {
                    rd: RA,
                    to: "PromAlloc".into(),
                },
                Op::Addi {
                    rd: sreg,
                    rs: A0,
                    imm: 0,
                },
                Op::Addi {
                    rd: A0,
                    rs: sreg,
                    imm: 0,
                },
                Op::Jal {
                    rd: RA,
                    to: "PromGet".into(),
                },
                // rec = a0: AOFF=url, ALEN=url_len, STATE=PEND, BUDGET=1
                Op::Li { rd: T2, imm: url },
                Op::Sw {
                    rs2: T2,
                    rs1: A0,
                    off: PR_AOFF,
                },
                Op::Li { rd: T2, imm: ulen },
                Op::Sw {
                    rs2: T2,
                    rs1: A0,
                    off: PR_ALEN,
                },
                Op::Li {
                    rd: T2,
                    imm: PROM_ST_PEND,
                },
                Op::Sw {
                    rs2: T2,
                    rs1: A0,
                    off: PR_STATE,
                },
                Op::Li { rd: T2, imm: 1 },
                Op::Sw {
                    rs2: T2,
                    rs1: A0,
                    off: g6b_asm::domt::PR_BUDGET,
                },
            ]);
        }
        // PromDrain: s0's url resolves → FUL; s1's misses with budget 1 → REJ.
        probe.push(Op::Jal {
            rd: RA,
            to: "PromDrain".into(),
        });
        // Read both records' states.
        for (sreg, tag, hexn) in [(S0, " P0=", "pd_h0"), (S1, " P1=", "pd_h1")] {
            probe.extend([
                Op::Addi {
                    rd: A0,
                    rs: sreg,
                    imm: 0,
                },
                Op::Jal {
                    rd: RA,
                    to: "PromGet".into(),
                },
                Op::Lw {
                    rd: T0,
                    rs: A0,
                    off: PR_STATE,
                },
            ]);
            probe.extend(put_str_ops(tag));
            probe.extend(hex_t0_ops(hexn));
        }
        probe.extend(put_str_ops("\n"));

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
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
        assert!(!s.console.contains("WASM-JIT-TRAP"), "{}", s.console);
        assert_eq!(s.faults, 0, "fault-free: {}", s.console);
        assert!(
            s.console.contains(&format!("P0={:016x}", PROM_ST_FUL)),
            "pending good-url fetch fulfilled: {}",
            s.console
        );
        assert!(
            s.console.contains(&format!("P1={:016x}", PROM_ST_REJ)),
            "pending missing-url fetch rejected on budget: {}",
            s.console
        );
        let _ = (
            PR_AOFF,
            PR_ALEN,
            PR_STATE,
            PROM_ST_PEND,
            A0,
            RA,
            S0,
            S1,
            T0,
            T1,
            T2,
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
                    n.ops.splice(
                        pos + 1..pos + 1,
                        vec![Op::Jal {
                            rd: RA,
                            to: "DomtLayout".into(),
                        }],
                    );
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
                    n.ops.splice(
                        pos + 1..pos + 1,
                        vec![Op::Jal {
                            rd: RA,
                            to: "DomtLayout".into(),
                        }],
                    );
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

    /// UTF-8 `Object_Getter__string` for `type` on a real click. The evstr
    /// delegate appends iff the sret `{len,ptr}` reports len==5 (`"click"`).
    /// Empty/unknown leave `__dom` at root+button.
    #[test]
    fn guest_jit_listener_reads_event_type_string() {
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

        let build = |m: &mut g6b_asm::Module| {
            install_guest(m, &test_module_evstr(b"click", b"type"))
                .expect("evstr click cell installs");
            for n in &mut m.nodes {
                if let Some(pos) = n
                    .ops
                    .iter()
                    .position(|o| matches!(o, Op::Jal { to, .. } if to == "JitRun"))
                {
                    n.ops.splice(
                        pos + 1..pos + 1,
                        vec![Op::Jal {
                            rd: RA,
                            to: "DomtLayout".into(),
                        }],
                    );
                    return;
                }
            }
            panic!("no JitRun call site to splice after");
        };

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
        assert!(
            s.domt_live >= 3,
            "string type getter wrote \"click\" (len=5) → delegate appended (live={}): {}",
            s.domt_live,
            s.console
        );
    }

    /// UTF-8 `Object_Getter__string` for KeyboardEvent.code on KEY_ENTER.
    /// `code` is `"Enter"` (len 5), never the Linux keycode integer 28.
    #[test]
    fn guest_jit_listener_reads_event_code_string() {
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
        install_guest(&mut m, &test_module_evstr(b"keydown", b"code"))
            .expect("evstr key cell installs");
        let mut placed = false;
        for n in &mut m.nodes {
            if let Some(pos) = n
                .ops
                .iter()
                .position(|o| matches!(o, Op::Jal { to, .. } if to == "JitRun"))
            {
                let ops = vec![
                    Op::Li { rd: A0, imm: 1 },
                    Op::Jal {
                        rd: RA,
                        to: "DomtFocus".into(),
                    },
                    Op::La {
                        rd: T0,
                        addr: Addr::VioBss,
                    },
                    Op::Li {
                        rd: T1,
                        imm: (VIO_KEY_ENTER << 8) | 1,
                    },
                    Op::Sw {
                        rs2: T1,
                        rs1: T0,
                        off: INP_KQ_OFF,
                    },
                    Op::Li { rd: T1, imm: 1 },
                    Op::Sw {
                        rs2: T1,
                        rs1: T0,
                        off: INP_KQ_HEAD,
                    },
                    Op::Sw {
                        rs2: X0,
                        rs1: T0,
                        off: DOMT_SEEN_OFF,
                    },
                    Op::Jal {
                        rd: RA,
                        to: "DomtKey".into(),
                    },
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
        assert!(s.domt_listen >= 1, "button keydown listener: {}", s.console);
        assert!(
            s.domt_live >= 3,
            "string code getter wrote \"Enter\" (len=5, not Linux 28) → appended (live={}): {}",
            s.domt_live,
            s.console
        );
    }

    fn click_wasm_grows(wasm: &[u8], min_live: u32, why: &str) {
        let _ = click_wasm_grows_m(wasm, min_live, why, 0);
    }

    fn click_wasm_grows_m(wasm: &[u8], min_live: u32, why: &str, mods: u8) -> g6b_asm::exec::Smoke {
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

        let build = |m: &mut g6b_asm::Module| {
            install_guest(m, wasm).expect("cell installs");
            for n in &mut m.nodes {
                if let Some(pos) = n
                    .ops
                    .iter()
                    .position(|o| matches!(o, Op::Jal { to, .. } if to == "JitRun"))
                {
                    n.ops.splice(
                        pos + 1..pos + 1,
                        vec![Op::Jal {
                            rd: RA,
                            to: "DomtLayout".into(),
                        }],
                    );
                    return;
                }
            }
            panic!("no JitRun call site to splice after");
        };

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
        let abs_x = (bx + bw / 2) * 0x8000 / 640;
        let abs_y = (by + bh / 2) * 0x8000 / 480;

        struct ClickFeed {
            x: u32,
            y: u32,
            mods: u8,
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
            fn hint_mods(&self) -> Option<u8> {
                (self.mods != 0).then_some(self.mods)
            }
        }
        let mut feed = ClickFeed {
            x: abs_x,
            y: abs_y,
            mods,
        };
        let mut m = g6b_asm::analyze::kstart(&spec);
        build(&mut m);
        let s = run_module_web_feed(&spec, &m, 0x8020_0000, 0, &mut feed).unwrap();
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
        assert!(!s.console.contains("WASM-JIT-TRAP"), "{}", s.console);
        assert_eq!(s.faults, 0, "fault-free: {}", s.console);
        assert!(
            s.domt_live >= min_live,
            "{why} (live={}): {}",
            s.domt_live,
            s.console
        );
        s
    }

    /// Click the child button; root capture listener sees `eventPhase==1`.
    #[test]
    fn guest_jit_click_capture_on_parent() {
        click_wasm_grows(
            &test_module_phase(true),
            3,
            "parent capture walk wrote eventPhase=1 → appended",
        );
    }

    /// Click the child button; root bubble listener sees `eventPhase==3`.
    #[test]
    fn guest_jit_click_bubble_on_parent() {
        click_wasm_grows(
            &test_module_phase(false),
            3,
            "parent bubble walk wrote eventPhase=3 → appended",
        );
    }

    /// Capture and bubble listeners on the same parent both fire (two records).
    #[test]
    fn guest_jit_two_listeners_on_parent() {
        click_wasm_grows(
            &test_module_two_lsn(),
            4,
            "capture+bubble records both fired → two appends",
        );
    }

    /// `once` (a5=2): two KEY_ENTER presses append only once.
    #[test]
    fn guest_jit_once_listener_fires_once() {
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
        install_guest(&mut m, &test_module_once()).expect("once cell installs");
        let mut placed = false;
        for n in &mut m.nodes {
            if let Some(pos) = n
                .ops
                .iter()
                .position(|o| matches!(o, Op::Jal { to, .. } if to == "JitRun"))
            {
                let enter = (VIO_KEY_ENTER << 8) | 1;
                let ops = vec![
                    Op::Li { rd: A0, imm: 1 },
                    Op::Jal {
                        rd: RA,
                        to: "DomtFocus".into(),
                    },
                    Op::La {
                        rd: T0,
                        addr: Addr::VioBss,
                    },
                    Op::Li { rd: T1, imm: enter },
                    Op::Sw {
                        rs2: T1,
                        rs1: T0,
                        off: INP_KQ_OFF,
                    },
                    Op::Sw {
                        rs2: T1,
                        rs1: T0,
                        off: INP_KQ_OFF + 4,
                    },
                    Op::Li { rd: T1, imm: 2 },
                    Op::Sw {
                        rs2: T1,
                        rs1: T0,
                        off: INP_KQ_HEAD,
                    },
                    Op::Sw {
                        rs2: X0,
                        rs1: T0,
                        off: DOMT_SEEN_OFF,
                    },
                    Op::Jal {
                        rd: RA,
                        to: "DomtKey".into(),
                    },
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
        assert_eq!(
            s.domt_live, 3,
            "once listener appended once for two keydowns (live={}): {}",
            s.domt_live, s.console
        );
    }

    /// `passive` (a5=4): preventDefault does not set defaultPrevented → append.
    #[test]
    fn guest_jit_passive_prevent_default_is_noop() {
        click_wasm_grows(
            &test_module_passive(),
            3,
            "passive preventDefault left defaultPrevented=0 → appended",
        );
    }

    /// `remove_event_listener` tombs the record; a later click does not append.
    #[test]
    fn guest_jit_remove_event_listener() {
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
        let build = |m: &mut g6b_asm::Module| {
            install_guest(m, &test_module_rmlsn()).expect("rmlsn cell installs");
            for n in &mut m.nodes {
                if let Some(pos) = n
                    .ops
                    .iter()
                    .position(|o| matches!(o, Op::Jal { to, .. } if to == "JitRun"))
                {
                    n.ops.splice(
                        pos + 1..pos + 1,
                        vec![Op::Jal {
                            rd: RA,
                            to: "DomtLayout".into(),
                        }],
                    );
                    return;
                }
            }
            panic!("no JitRun call site to splice after");
        };
        let mut probe = g6b_asm::analyze::kstart(&spec);
        build(&mut probe);
        let sp = run_module(&spec, &probe, 0x8020_0000).unwrap();
        assert!(!sp.console.contains("TRAP-"), "{}", sp.console);
        let btn = sp
            .domt_nodes
            .iter()
            .find(|n| n.0 != 0)
            .expect("button laid out");
        let abs_x = (btn.3 + btn.5 / 2) * 0x8000 / 640;
        let abs_y = (btn.4 + btn.6 / 2) * 0x8000 / 480;
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
        assert_eq!(s.faults, 0, "{}", s.console);
        assert_eq!(
            s.domt_live, 2,
            "removed listener must not append (live={}): {}",
            s.domt_live, s.console
        );
    }

    /// OptionalUint `clientX` is defined and ≥200; Optional `relatedTarget` is
    /// defined=0. Both must hold for the append.
    #[test]
    fn guest_jit_optional_event_getters() {
        click_wasm_grows(
            &test_module_optional(),
            3,
            "OptionalUint clientX defined≥200 and relatedTarget none → appended",
        );
    }

    /// `Object_Getter__float` of `clientX` compared as f32 ≥ 200.0.
    #[test]
    fn guest_jit_float_event_getter() {
        click_wasm_grows(&test_module_float(), 3, "float clientX >= 200.0 → appended");
    }

    /// `Object_Getter__double` of `clientX` compared as f64 ≥ 200.0.
    #[test]
    fn guest_jit_double_event_getter() {
        click_wasm_grows(
            &test_module_double(),
            3,
            "double clientX >= 200.0 → appended",
        );
    }

    /// `Object_Getter__double` of `timeStamp` > 0 (csr time at fill).
    #[test]
    fn guest_jit_timestamp_event_getter() {
        click_wasm_grows(
            &test_module_timestamp(),
            3,
            "double timeStamp > 0 → appended",
        );
    }

    /// Wheel `deltaMode` is `DOM_DELTA_LINE` (1); virtio REL_WHEEL is a detent.
    #[test]
    fn guest_jit_wheel_delta_mode_is_line() {
        ptr_wasm_grows(
            &test_module_delta_mode(),
            3,
            "uint deltaMode == 1 → appended",
            true,
            false,
            Some(-3),
        );
    }

    /// OptionalString `type` is defined and `"click"` (len 5).
    #[test]
    fn guest_jit_optional_string_event_getter() {
        click_wasm_grows(
            &test_module_optional_string(),
            3,
            "OptionalString type defined click → appended",
        );
    }

    /// OptionalBool `bubbles` defined=1 and OptionalDouble `clientX` ≥ 200.0.
    #[test]
    fn guest_jit_optional_bool_double_event_getters() {
        click_wasm_grows(
            &test_module_optional_bool_double(),
            3,
            "OptionalBool bubbles and OptionalDouble clientX → appended",
        );
    }

    /// REL_X/Y from the origin (tablet units) to the button centre, no BTN.
    /// `TabDrain` clamp-adds into `PTR_X`/`PTR_Y` and latches `PTR_MOVE`;
    /// `DomtPtr` dispatches `mousemove` and `$delegate` appends.
    #[test]
    fn guest_jit_mousemove_via_rel() {
        ptr_wasm_grows(
            &test_module_delegate_ev(b"mousemove"),
            3,
            "REL_X/Y → mousemove → appended",
            false,
            true,
            None,
        );
    }

    /// First pointer enter: `PTR_HOVER` starts at NONE, REL to the button
    /// fires `mouseover` (no prior hover to leave).
    #[test]
    fn guest_jit_mouseover_first_enter() {
        ptr_wasm_grows(
            &test_module_delegate_ev(b"mouseover"),
            3,
            "PTR_HOVER NONE → mouseover first enter → appended",
            false,
            true,
            None,
        );
    }

    /// Wheel at the button centre: `hint_abs` + `hint_wheel`, no BTN.
    #[test]
    fn guest_jit_wheel_at_button() {
        ptr_wasm_grows(
            &test_module_delegate_ev(b"wheel"),
            3,
            "hint_abs+hint_wheel no BTN → wheel → appended",
            true,
            false,
            Some(-3),
        );
    }

    fn ptr_wasm_grows(
        wasm: &[u8],
        min_live: u32,
        why: &str,
        use_abs: bool,
        use_rel: bool,
        wheel: Option<i32>,
    ) {
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

        let build = |m: &mut g6b_asm::Module| {
            install_guest(m, wasm).expect("cell installs");
            for n in &mut m.nodes {
                if let Some(pos) = n
                    .ops
                    .iter()
                    .position(|o| matches!(o, Op::Jal { to, .. } if to == "JitRun"))
                {
                    n.ops.splice(
                        pos + 1..pos + 1,
                        vec![Op::Jal {
                            rd: RA,
                            to: "DomtLayout".into(),
                        }],
                    );
                    return;
                }
            }
            panic!("no JitRun call site to splice after");
        };

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
        let abs_x = (bx + bw / 2) * 0x8000 / 640;
        let abs_y = (by + bh / 2) * 0x8000 / 480;

        struct PtrFeed {
            abs: Option<(u32, u32)>,
            rel: Option<(i32, i32)>,
            wheel: Option<i32>,
        }
        impl WebFeed for PtrFeed {
            fn initial(&mut self) -> Option<GuestWebPresent> {
                None
            }
            fn on_guest_ui(&mut self) -> Option<GuestWebPresent> {
                None
            }
            fn hint_abs(&self) -> Option<(u32, u32)> {
                self.abs
            }
            fn hint_rel(&self) -> Option<(i32, i32)> {
                self.rel
            }
            fn hint_wheel(&self) -> Option<i32> {
                self.wheel
            }
        }
        let mut feed = PtrFeed {
            abs: if use_abs { Some((abs_x, abs_y)) } else { None },
            rel: if use_rel {
                Some((abs_x as i32, abs_y as i32))
            } else {
                None
            },
            wheel,
        };
        let mut m = g6b_asm::analyze::kstart(&spec);
        build(&mut m);
        let s = run_module_web_feed(&spec, &m, 0x8020_0000, 0, &mut feed).unwrap();
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
        assert!(!s.console.contains("WASM-JIT-TRAP"), "{}", s.console);
        assert_eq!(s.faults, 0, "fault-free: {}", s.console);
        assert!(
            s.domt_live >= min_live,
            "{why} (live={}): {}",
            s.domt_live,
            s.console
        );
    }

    /// RFB PointerEvent (type 5, left down) at the button centre, through
    /// `PtrNorm` scale/clip → tablet ABS+BTN → `TabDrain`/`DomtPtr`.
    #[test]
    fn guest_jit_rfb_pointer_clicks_button() {
        remote_ptr_wasm_grows(
            &test_module_delegate_ev(b"click"),
            3,
            "RFB PointerEvent left-down → click → appended",
            RemotePtr::RfbClick,
        );
    }

    /// Browser-KVM wheel at the button centre, no BTN.
    #[test]
    fn guest_jit_kvm_wheel_at_button() {
        remote_ptr_wasm_grows(
            &test_module_delegate_ev(b"wheel"),
            3,
            "KVM wheel at button → wheel → appended",
            RemotePtr::KvmWheel(-3),
        );
    }

    /// DOM `button` is 0 for left, not Linux `BTN_LEFT` (0x110).
    #[test]
    fn guest_jit_click_button_is_zero() {
        click_wasm_grows(
            &test_module_button_eq(0),
            3,
            "DOM button==0 on left click → appended",
        );
    }

    /// RFB right-down (mask bit 2) → DOM `button==2`.
    #[test]
    fn guest_jit_rfb_right_button_is_two() {
        remote_ptr_wasm_grows(
            &test_module_button_eq(2),
            3,
            "RFB right → button==2 → appended",
            RemotePtr::RfbRight,
        );
    }

    /// KEY_LEFTSHIFT then click → `shiftKey` is true.
    #[test]
    fn guest_jit_shift_click_shiftkey() {
        let _ = click_wasm_grows_m(
            &test_module_shiftkey(),
            3,
            "shift+click → shiftKey → appended",
            g6b_asm::vio::MOD_SHIFT as u8,
        );
    }

    /// Click moves `H_FOCUS` from the root onto the button.
    #[test]
    fn guest_jit_click_focuses_button() {
        let s = click_wasm_grows_m(
            &test_module_delegate_ev(b"click"),
            3,
            "click → focus button",
            0,
        );
        let btn = s.domt_nodes.iter().find(|n| n.0 != 0).expect("button node");
        assert_eq!(
            s.domt_focus, btn.0,
            "H_FOCUS should be the clicked button (focus={}, btn={:?}): {}",
            s.domt_focus, btn, s.console
        );
    }

    fn password_run(wasm: &[u8], focus: bool, raster: bool) -> g6b_asm::exec::Smoke {
        use g6b_asm::encode::{A0, RA};
        use g6b_asm::exec::run_module;
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
        let mut m = g6b_asm::analyze::kstart(&spec);
        install_guest(&mut m, wasm).expect("cell installs");
        for n in &mut m.nodes {
            if let Some(pos) = n
                .ops
                .iter()
                .position(|o| matches!(o, Op::Jal { to, .. } if to == "JitRun"))
            {
                let mut extra = Vec::new();
                if focus {
                    extra.extend([
                        Op::Li { rd: A0, imm: 1 },
                        Op::Jal {
                            rd: RA,
                            to: "DomtFocus".into(),
                        },
                    ]);
                }
                extra.push(Op::Jal {
                    rd: RA,
                    to: "DomtLayout".into(),
                });
                if raster {
                    extra.push(Op::Jal {
                        rd: RA,
                        to: "DomtRaster".into(),
                    });
                }
                n.ops.splice(pos + 1..pos + 1, extra);
                break;
            }
        }
        let s = run_module(&spec, &m, 0x8020_0000).unwrap();
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
        assert_eq!(s.faults, 0, "{}", s.console);
        s
    }

    /// `type=password` keeps the real value in `__dom_str` and sets `F_PASSWORD`.
    #[test]
    fn guest_jit_password_keeps_value() {
        let s = password_run(&test_module_password_input(true, "ab"), false, false);
        let n = s.domt_nodes.iter().find(|n| n.0 != 0).expect("input node");
        assert!(
            n.8.starts_with("ab "),
            "stored value must stay plaintext: {:?}",
            n
        );
        assert!(
            n.8.contains("flags=") && n.8.contains("flags=0x"),
            "flags dumped: {:?}",
            n
        );
        let flags =
            n.8.rsplit("flags=")
                .next()
                .and_then(|h| u32::from_str_radix(h.trim_start_matches("0x"), 16).ok())
                .unwrap_or(0);
        assert_eq!(
            flags & g6b_asm::domt::F_PASSWORD as u32,
            g6b_asm::domt::F_PASSWORD as u32,
            "F_PASSWORD set: {:?}",
            n
        );
    }

    /// Password raster paints `*`, not the stored letters.
    #[test]
    fn guest_jit_password_masks_raster() {
        let plain = password_run(&test_module_password_input(false, "ab"), false, true);
        let secret = password_run(&test_module_password_input(true, "ab"), false, true);
        assert!(
            !plain.scan_fb.is_empty() && !secret.scan_fb.is_empty(),
            "both runs must raster"
        );
        assert_ne!(
            plain.scan_fb, secret.scan_fb,
            "password glyphs must differ from plaintext"
        );
        let n = secret.domt_nodes.iter().find(|n| n.0 != 0).expect("input");
        assert!(n.8.starts_with("ab "), "value still ab: {:?}", n);
    }

    /// Focused password field: canned KEY_A appends 'a'.
    #[test]
    fn guest_jit_password_types_a() {
        let s = password_run(&test_module_password_input(true, ""), true, false);
        let n = s.domt_nodes.iter().find(|n| n.0 != 0).expect("input node");
        assert!(
            n.8.starts_with("a "),
            "KEY_A default action appends 'a': {:?}",
            n
        );
    }

    fn flags_of(n: &g6b_asm::exec::DomtNodeRow) -> u32 {
        n.8.rsplit("flags=")
            .next()
            .and_then(|h| u32::from_str_radix(h.trim_start_matches("0x"), 16).ok())
            .unwrap_or(0)
    }

    fn password_edit(
        wasm: &[u8],
        value: &str,
        password: bool,
        mods: u8,
        key: Option<(u16, u32)>,
        keys: Option<&'static [(u16, u32)]>,
    ) -> g6b_asm::exec::Smoke {
        use g6b_asm::encode::{A0, RA};
        use g6b_asm::exec::{run_module_web_feed, GuestWebPresent, WebFeed};
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
        let mut m = g6b_asm::analyze::kstart(&spec);
        install_guest(&mut m, wasm).expect("cell installs");
        for n in &mut m.nodes {
            if let Some(pos) = n
                .ops
                .iter()
                .position(|o| matches!(o, Op::Jal { to, .. } if to == "JitRun"))
            {
                n.ops.splice(
                    pos + 1..pos + 1,
                    [
                        Op::Li { rd: A0, imm: 1 },
                        Op::Jal {
                            rd: RA,
                            to: "DomtFocus".into(),
                        },
                        Op::Jal {
                            rd: RA,
                            to: "DomtLayout".into(),
                        },
                    ],
                );
                break;
            }
        }
        struct KeyFeed {
            mods: u8,
            key: Option<(u16, u32)>,
            keys: Option<&'static [(u16, u32)]>,
        }
        impl WebFeed for KeyFeed {
            fn initial(&mut self) -> Option<GuestWebPresent> {
                None
            }
            fn on_guest_ui(&mut self) -> Option<GuestWebPresent> {
                None
            }
            fn hint_mods(&self) -> Option<u8> {
                if self.mods == 0 {
                    None
                } else {
                    Some(self.mods)
                }
            }
            fn hint_key(&self) -> Option<(u16, u32)> {
                self.key
            }
            fn hint_keys(&self) -> Option<&'static [(u16, u32)]> {
                self.keys
            }
        }
        let mut feed = KeyFeed { mods, key, keys };
        let s = run_module_web_feed(&spec, &m, 0x8020_0000, 0, &mut feed).unwrap();
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
        assert_eq!(s.faults, 0, "{}", s.console);
        let _ = value;
        let _ = password;
        s
    }

    /// `type=text` takes the same KEY_A default action, unmasked.
    #[test]
    fn guest_jit_text_types_a() {
        let s = password_edit(
            &test_module_password_input(false, ""),
            "",
            false,
            0,
            None,
            None,
        );
        let n = s.domt_nodes.iter().find(|n| n.0 != 0).expect("input node");
        assert!(
            n.8.starts_with("a "),
            "type=text KEY_A appends 'a': {:?}",
            n
        );
        let flags = flags_of(n);
        assert_eq!(
            flags & g6b_asm::domt::F_EDITABLE as u32,
            g6b_asm::domt::F_EDITABLE as u32,
            "F_EDITABLE: {:?}",
            n
        );
        assert_eq!(
            flags & g6b_asm::domt::F_PASSWORD as u32,
            0,
            "not password: {:?}",
            n
        );
    }

    /// KEY_B through the US keymap appends 'b'.
    #[test]
    fn guest_jit_password_types_b() {
        let s = password_edit(
            &test_module_password_input(true, ""),
            "",
            true,
            0,
            Some((g6b_asm::vio::VIO_KEY_B as u16, 1)),
            None,
        );
        let n = s.domt_nodes.iter().find(|n| n.0 != 0).expect("input node");
        assert!(n.8.starts_with("b "), "KEY_B appends 'b': {:?}", n);
    }

    /// Backspace deletes the last character.
    #[test]
    fn guest_jit_password_backspace() {
        let s = password_edit(
            &test_module_password_input(true, "ab"),
            "ab",
            true,
            0,
            Some((g6b_asm::vio::VIO_KEY_BACKSPACE as u16, 1)),
            None,
        );
        let n = s.domt_nodes.iter().find(|n| n.0 != 0).expect("input node");
        assert!(n.8.starts_with("a "), "backspace leaves 'a': {:?}", n);
        assert!(
            !n.8.starts_with("ab "),
            "must not keep both letters: {:?}",
            n
        );
    }

    /// Shift+KEY_A appends 'A'.
    #[test]
    fn guest_jit_password_shift_a() {
        let s = password_edit(
            &test_module_password_input(true, ""),
            "",
            true,
            g6b_asm::vio::MOD_SHIFT as u8,
            Some((g6b_asm::vio::VIO_KEY_A as u16, 1)),
            None,
        );
        let n = s.domt_nodes.iter().find(|n| n.0 != 0).expect("input node");
        assert!(n.8.starts_with("A "), "shift+A appends 'A': {:?}", n);
    }

    /// Left then KEY_C inserts in the middle: "ab" → "acb".
    #[test]
    fn guest_jit_text_caret_insert() {
        let s = password_edit(
            &test_module_password_input(false, "ab"),
            "ab",
            false,
            0,
            None,
            Some(&[
                (g6b_asm::vio::VIO_KEY_LEFT as u16, 1),
                (g6b_asm::vio::VIO_KEY_C as u16, 1),
            ]),
        );
        let n = s.domt_nodes.iter().find(|n| n.0 != 0).expect("input node");
        assert!(
            n.8.starts_with("acb "),
            "LEFT then C inserts in the middle: {:?}",
            n
        );
    }

    /// Left then backspace deletes the first character: "ab" → "b".
    #[test]
    fn guest_jit_text_caret_backspace() {
        let s = password_edit(
            &test_module_password_input(false, "ab"),
            "ab",
            false,
            0,
            None,
            Some(&[
                (g6b_asm::vio::VIO_KEY_LEFT as u16, 1),
                (g6b_asm::vio::VIO_KEY_BACKSPACE as u16, 1),
            ]),
        );
        let n = s.domt_nodes.iter().find(|n| n.0 != 0).expect("input node");
        assert!(
            n.8.starts_with("b "),
            "LEFT then backspace deletes the first letter: {:?}",
            n
        );
        assert!(!n.8.starts_with("ab "), "must not keep 'ab': {:?}", n);
    }

    /// Shift+Left selects the last character; KEY_C replaces it: "ab" → "ac".
    #[test]
    fn guest_jit_text_select_replace() {
        let s = password_edit(
            &test_module_password_input(false, "ab"),
            "ab",
            false,
            0,
            None,
            Some(&[
                (g6b_asm::vio::VIO_KEY_LEFTSHIFT as u16, 1),
                (g6b_asm::vio::VIO_KEY_LEFT as u16, 1),
                (g6b_asm::vio::VIO_KEY_LEFTSHIFT as u16, 0),
                (g6b_asm::vio::VIO_KEY_C as u16, 1),
            ]),
        );
        let n = s.domt_nodes.iter().find(|n| n.0 != 0).expect("input node");
        assert!(
            n.8.starts_with("ac "),
            "shift+LEFT then C replaces the selection: {:?}",
            n
        );
        assert!(
            !n.8.starts_with("acb "),
            "must not insert beside the selection: {:?}",
            n
        );
    }

    /// Shift+Left then backspace deletes the selection: "ab" → "a".
    #[test]
    fn guest_jit_text_select_backspace() {
        let s = password_edit(
            &test_module_password_input(false, "ab"),
            "ab",
            false,
            0,
            None,
            Some(&[
                (g6b_asm::vio::VIO_KEY_LEFTSHIFT as u16, 1),
                (g6b_asm::vio::VIO_KEY_LEFT as u16, 1),
                (g6b_asm::vio::VIO_KEY_LEFTSHIFT as u16, 0),
                (g6b_asm::vio::VIO_KEY_BACKSPACE as u16, 1),
            ]),
        );
        let n = s.domt_nodes.iter().find(|n| n.0 != 0).expect("input node");
        assert!(
            n.8.starts_with("a "),
            "shift+LEFT then backspace deletes the selection: {:?}",
            n
        );
        assert!(!n.8.starts_with("ab "), "must not keep 'ab': {:?}", n);
    }

    enum RemotePtr {
        RfbClick,
        RfbRight,
        KvmWheel(i32),
    }

    fn remote_ptr_wasm_grows(wasm: &[u8], min_live: u32, why: &str, poke: RemotePtr) {
        use g6b_asm::encode::RA;
        use g6b_asm::exec::{run_module, run_module_web_feed, GuestWebPresent, WebFeed};
        use g6b_asm::ptr::{encode_rfb_pointer, KvmPointer, RFB_BTN_LEFT};
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

        let build = |m: &mut g6b_asm::Module| {
            install_guest(m, wasm).expect("cell installs");
            for n in &mut m.nodes {
                if let Some(pos) = n
                    .ops
                    .iter()
                    .position(|o| matches!(o, Op::Jal { to, .. } if to == "JitRun"))
                {
                    n.ops.splice(
                        pos + 1..pos + 1,
                        vec![Op::Jal {
                            rd: RA,
                            to: "DomtLayout".into(),
                        }],
                    );
                    return;
                }
            }
            panic!("no JitRun call site to splice after");
        };

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
        let cx = bx + bw / 2;
        let cy = by + bh / 2;

        struct RemoteFeed {
            rfb: Option<[u8; 6]>,
            kvm: Option<KvmPointer>,
        }
        impl WebFeed for RemoteFeed {
            fn initial(&mut self) -> Option<GuestWebPresent> {
                None
            }
            fn on_guest_ui(&mut self) -> Option<GuestWebPresent> {
                None
            }
            fn hint_rfb(&self) -> Option<[u8; 6]> {
                self.rfb
            }
            fn hint_kvm(&self) -> Option<KvmPointer> {
                self.kvm
            }
        }
        let mut feed = match poke {
            RemotePtr::RfbClick => RemoteFeed {
                rfb: Some(encode_rfb_pointer(cx as u16, cy as u16, RFB_BTN_LEFT)),
                kvm: None,
            },
            RemotePtr::RfbRight => RemoteFeed {
                rfb: Some(encode_rfb_pointer(
                    cx as u16,
                    cy as u16,
                    g6b_asm::ptr::RFB_BTN_RIGHT,
                )),
                kvm: None,
            },
            RemotePtr::KvmWheel(w) => RemoteFeed {
                rfb: None,
                kvm: Some(KvmPointer {
                    x: cx as i32,
                    y: cy as i32,
                    buttons: 0,
                    wheel: w,
                }),
            },
        };
        let mut m = g6b_asm::analyze::kstart(&spec);
        build(&mut m);
        let s = run_module_web_feed(&spec, &m, 0x8020_0000, 0, &mut feed).unwrap();
        assert!(!s.console.contains("TRAP-"), "{}", s.console);
        assert!(!s.console.contains("WASM-JIT-TRAP"), "{}", s.console);
        assert_eq!(s.faults, 0, "fault-free: {}", s.console);
        assert!(
            s.domt_live >= min_live,
            "{why} (live={}): {}",
            s.domt_live,
            s.console
        );
    }
}
