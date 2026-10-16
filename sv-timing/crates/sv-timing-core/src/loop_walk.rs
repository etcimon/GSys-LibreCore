// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Loop-walk shapes: procedural `for` loops whose body carries a value from
// one iteration to the next (a pointer, a "found" flag, a running count) and
// which synthesis therefore unrolls into a serial chain. Each shape has an
// exact parallel form of lower depth and lower area (ALGORITHMS-EXPERTS A101).

//! Detection and exact replacement of serial loop walks.
//!
//! The three shapes, measured on the LibreCore OoO core (A98–A100):
//!
//! | shape | before | after | exactness condition |
//! |---|---|---|---|
//! | **FindFirst** `for i: if (v[i] && pick == 0) pick = i` | N-deep priority chain | lowest-set-bit isolate + OR-encode | lower bound ≥ 1, or a `found` flag guards the write |
//! | **CondCount** `for i: if (cond_i) cnt = cnt + 1` | N-deep incrementer chain | `cnt + $countones(vec)` | `cnt` wide enough for N (declared width known) |
//! | **RingWalk** `cid = a; for k < N: if (cid == b) break; body(cid); cid++` | N-deep compare/decode chain | per-slot interval membership | `N == 2**width(cid)` |
//!
//! Detection is textual over the loop's own source (`GenerateLoop::text`):
//! the shapes are idioms, their surface form is regular, and the lowerer does
//! not represent `if` conditions or `break` as IR nodes. Replacement text is
//! one statement that fits the loop's line span (other edits in the file keep
//! their line numbers); the vectors it needs are declared at module scope by a
//! snippet injected before the enclosing process.

use crate::ir::{GenerateLoop, TimingModule};
use crate::width::WidthResolver;
use crate::CostModel;

/// Which walk a loop is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LoopWalkKind {
    /// Priority scan for the lowest set bit.
    FindFirst,
    /// Conditional running count.
    CondCount,
    /// Pointer walk from `a` to `b` on a power-of-two ring.
    RingWalk,
    /// Stream compaction: `for k: if (keep_k) { out[dst] = f(k); dst++ }`.
    StreamCompact,
    /// One-hot select: `for e: if (G[e]) { x = y(e); … }` with `G` asserted
    /// one-hot by the module → AND-OR accumulate (invariant-tagged).
    OneHotSelect,
}

/// One detected walk with its exact replacement.
#[derive(Debug, Clone)]
pub struct LoopWalkShape {
    /// Shape.
    pub kind: LoopWalkKind,
    /// Index of the loop in `module.gen_loops`.
    pub loop_index: usize,
    /// Trip count.
    pub trips: u32,
    /// Replacement statement for the loop's source span (one logical statement,
    /// possibly several lines; the emitter fits it to the span).
    pub replacement: String,
    /// Module-scope declarations the replacement needs (empty when none).
    pub decls: String,
    /// Marker identifier present in `replacement`, used to place `decls`
    /// before the enclosing process.
    pub marker: String,
    /// Loop-carried variable the walk is about (`pick`, `cnt`, `cid`).
    pub carried: String,
    /// Structural FO4 of one parallel form (what the rewritten loop costs).
    pub fo4_after: f64,
    /// Human rationale.
    pub rationale: String,
}

/// Detect every rewritable walk in a module.
pub fn detect(
    module: &TimingModule,
    widths: &WidthResolver<'_>,
    model: &CostModel,
) -> Vec<LoopWalkShape> {
    let mut out = Vec::new();
    for (idx, lp) in module.gen_loops.iter().enumerate() {
        if !lp.procedural || lp.in_function {
            continue;
        }
        let (Some(text), Some(cond)) = (lp.text.as_deref(), lp.cond_text.as_deref()) else {
            continue;
        };
        let Some((lo, n)) = trip_bounds(&lp.genvar, lp.init_text.as_deref(), cond, widths) else {
            continue;
        };
        if n < 2 || n > 4096 {
            continue;
        }
        let Some(body) = loop_body(text) else {
            continue;
        };
        let body = normalize_ws(&body);
        if let Some(s) = find_first(idx, lp, &body, lo, n, widths, model) {
            out.push(s);
            continue;
        }
        if let Some(s) = cond_count(idx, lp, &body, lo, n, widths, model) {
            out.push(s);
            continue;
        }
        if let Some(s) = ring_walk(idx, lp, &body, lo, n, widths, model) {
            out.push(s);
            continue;
        }
        if let Some(s) = stream_compact(idx, lp, &body, lo, n, widths, model) {
            out.push(s);
            continue;
        }
        if let Some(s) = one_hot_select(idx, lp, &body, lo, n, &module.onehot_facts, model) {
            out.push(s);
        }
    }
    out
}

// ------------------------------------------------------------- OneHotSelect

/// `for e: if (G[e]) begin X1 = Y1(e); … Xm = Ym(e); end` where the module
/// asserts `$onehot0(G)` (or `$onehot(G)`) and every `Xi` is set to zero
/// before the loop: a priority chain of N muxes that is, by the design's own
/// invariant, a one-hot select. Rewritten to the AND-OR accumulate
/// `Xi = Xi | (G[e] ? Yi(e) : '0)` — log₂N depth, no priority — exact
/// whenever the assertion holds (invariant-tagged; the rationale names it).
/// `Xi` must be a plain name or indexed by something other than `e`, and no
/// `Yi` may read an `Xj`.
fn one_hot_select(
    idx: usize,
    lp: &GenerateLoop,
    body: &str,
    lo: u32,
    n: u32,
    facts: &[String],
    model: &CostModel,
) -> Option<LoopWalkShape> {
    if facts.is_empty() {
        return None;
    }
    let e = lp.genvar.as_str();
    let (cond, cbody) = split_if(body)?;
    // the guard is `<base>[e]`
    let base = cond.trim().strip_suffix(&format!("[{e}]"))?.trim();
    if base.is_empty() || base.contains("&&") || base.contains("||") || base.contains(' ') {
        return None;
    }
    let base_norm: String = base.split_whitespace().collect();
    if !facts.iter().any(|f| *f == base_norm) {
        return None;
    }
    let stmts = split_statements(&cbody);
    if stmts.is_empty() {
        return None;
    }
    let mut assigns: Vec<(String, String)> = Vec::new();
    for st in &stmts {
        let (l, r) = st.split_once('=')?;
        let l = l.trim();
        let r = r.trim();
        if r.starts_with('=') || l.ends_with('<') || l.ends_with('!') || l.ends_with('>') {
            return None;
        }
        // LHS: ident, or ident[idx] with idx not the loop var
        let root: String = l
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
            .collect();
        // `ident` or `ident[...][...]`: nothing but bracket groups after the root
        let mut rest = &l[root.len()..];
        let mut ok = !root.is_empty();
        while ok && !rest.is_empty() {
            if !rest.starts_with('[') {
                ok = false;
                break;
            }
            let Some(close) = rest.find(']') else {
                ok = false;
                break;
            };
            rest = &rest[close + 1..];
        }
        if !ok {
            return None;
        }
        if bracket_inners_text(l)
            .iter()
            .any(|ix| idents(ix).iter().any(|t| t == e))
            || l.contains('.')
        {
            return None;
        }
        assigns.push((l.to_string(), r.to_string()));
    }
    let lhs_roots: Vec<String> = assigns
        .iter()
        .map(|(l, _)| {
            l.chars()
                .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
                .collect()
        })
        .collect();
    for (_, r) in &assigns {
        if idents(r).iter().any(|t| lhs_roots.iter().any(|x| x == t)) {
            return None;
        }
    }
    // zero-init before the loop: `X = '0;` for the root (whole array) or the exact LHS
    let pre = normalize_ws(lp.pre_text.as_deref()?);
    for (l, _) in &assigns {
        let root: String = l
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
            .collect();
        let zero_whole =
            pre.contains(&format!("{root} = '0;")) || pre.contains(&format!("{root} = 0;"));
        let zero_exact = pre.contains(&format!("{l} = '0;")) || pre.contains(&format!("{l} = 0;"));
        if !(zero_whole || zero_exact) {
            return None;
        }
    }
    let first = lhs_roots[0].clone();
    let mut rep = String::new();
    rep.push_str(&format!(
        "begin : {first}_svt_ohs
"
    ));
    rep.push_str(&format!(
        "  for (int unsigned {e} = {lo}; {e} < {n}; {e}++) begin
"
    ));
    for (l, r) in &assigns {
        rep.push_str(&format!(
            "    {l} = {l} | (({cond}) ? ({r}) : '0);
"
        ));
    }
    rep.push_str(
        "  end
end",
    );
    let levels = f64::from(n.next_power_of_two().trailing_zeros().max(1));
    let fo4_after = model.mux + model.logic_bit * levels;
    Some(LoopWalkShape {
        kind: LoopWalkKind::OneHotSelect,
        loop_index: idx,
        trips: n - lo,
        replacement: rep,
        decls: String::new(),
        marker: format!("{first}_svt_ohs"),
        carried: first,
        fo4_after,
        rationale: format!(
            "one-hot select over {} entries ({} outputs) → AND-OR accumulate; exact under the module's `$onehot0({base_norm})` assertion (invariant-tagged)",
            n - lo,
            assigns.len()
        ),
    })
}

fn bracket_inners_text(tok: &str) -> Vec<String> {
    let b = tok.as_bytes();
    let mut out = Vec::new();
    let mut i = 0usize;
    while i < b.len() {
        if b[i] == b'[' {
            let start = i + 1;
            let mut depth = 1i32;
            let mut j = start;
            while j < b.len() && depth > 0 {
                match b[j] {
                    b'[' => depth += 1,
                    b']' => depth -= 1,
                    _ => {}
                }
                j += 1;
            }
            if depth == 0 {
                out.push(tok[start..j - 1].to_string());
                i = j;
                continue;
            }
            break;
        }
        i += 1;
    }
    out
}

/// `k = A; k < N` → `(A, N)`; `<=` → `N + 1`.
fn trip_bounds(
    var: &str,
    init: Option<&str>,
    cond: &str,
    widths: &WidthResolver<'_>,
) -> Option<(u32, u32)> {
    let cond = cond.trim();
    let (lhs, rhs, inclusive) = if let Some((l, r)) = cond.split_once("<=") {
        (l, r, true)
    } else if let Some((l, r)) = cond.split_once('<') {
        (l, r, false)
    } else {
        return None;
    };
    if lhs.trim() != var {
        return None;
    }
    let bound = widths.eval_text(rhs.trim())? + i64::from(inclusive);
    let start = match init {
        Some(t) => widths.eval_text(t.trim())?,
        None => 0,
    };
    if start < 0 || bound <= start {
        return None;
    }
    Some((u32::try_from(start).ok()?, u32::try_from(bound).ok()?))
}

/// The statement after the `for (...)` header, without an enclosing
/// `begin … end` pair.
fn loop_body(text: &str) -> Option<String> {
    let open = text.find('(')?;
    let mut depth = 0i32;
    let mut close = None;
    for (i, c) in text[open..].char_indices() {
        match c {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if depth == 0 {
                    close = Some(open + i);
                    break;
                }
            }
            _ => {}
        }
    }
    let body = text[close? + 1..].trim();
    let body = body.strip_suffix(';').map(str::trim).unwrap_or(body);
    let body = if let Some(inner) = body.strip_prefix("begin") {
        let inner = inner.trim_start();
        // optional block label
        let inner = inner.strip_prefix(':').map(|r| {
            let r = r.trim_start();
            let end = r
                .find(|c: char| !(c.is_alphanumeric() || c == '_'))
                .unwrap_or(r.len());
            r[end..].trim_start()
        });
        let inner = inner.unwrap_or(body.strip_prefix("begin").unwrap_or(body));
        inner.strip_suffix("end").map(str::trim).unwrap_or(inner)
    } else {
        body
    };
    Some(body.to_string())
}

fn normalize_ws(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut prev_space = false;
    for c in s.chars() {
        if c.is_whitespace() {
            if !prev_space {
                out.push(' ');
            }
            prev_space = true;
        } else {
            out.push(c);
            prev_space = false;
        }
    }
    out.trim().to_string()
}

fn is_ident(s: &str) -> bool {
    let mut it = s.chars();
    matches!(it.next(), Some(c) if c.is_ascii_alphabetic() || c == '_')
        && it.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// Identifiers of a text, in order (keywords included; callers filter).
fn idents(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let b = text.as_bytes();
    let mut i = 0;
    while i < b.len() {
        if b[i].is_ascii_alphabetic() || b[i] == b'_' {
            let s = i;
            while i < b.len() && (b[i].is_ascii_alphanumeric() || b[i] == b'_') {
                i += 1;
            }
            out.push(text[s..i].to_string());
        } else if b[i].is_ascii_digit() {
            while i < b.len() && (b[i].is_ascii_alphanumeric() || b[i] == b'\'' || b[i] == b'_') {
                i += 1;
            }
        } else {
            i += 1;
        }
    }
    out
}

/// Replace whole-word `from` with `to`.
fn replace_ident(text: &str, from: &str, to: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let b = text.as_bytes();
    let mut i = 0;
    while i < b.len() {
        if b[i].is_ascii_alphabetic() || b[i] == b'_' {
            let s = i;
            while i < b.len() && (b[i].is_ascii_alphanumeric() || b[i] == b'_' || b[i] == b'$') {
                i += 1;
            }
            let w = &text[s..i];
            out.push_str(if w == from { to } else { w });
        } else {
            out.push(b[i] as char);
            i += 1;
        }
    }
    out
}

/// Strip an optional cast `X'(` … `)` around an expression text; returns the
/// inner text and the cast prefix (`X'`) when present.
fn split_cast(expr: &str) -> (Option<String>, String) {
    let e = expr.trim();
    if let Some(p) = e.find("'(") {
        if e.ends_with(')') {
            let prefix = &e[..p];
            let inner = &e[p + 2..e.len() - 1];
            if is_ident(prefix.trim())
                || prefix.trim().chars().all(|c| c.is_ascii_digit())
                || prefix.trim().starts_with("$bits(")
            {
                return (
                    Some(format!("{}'", prefix.trim())),
                    inner.trim().to_string(),
                );
            }
        }
    }
    (None, e.to_string())
}

fn declared_width(widths: &WidthResolver<'_>, name: &str) -> Option<u32> {
    widths.expr_width(&crate::expr::Expr::parse(name))
}

/// `pick`'s cast for the index: the declared cast if the source used one,
/// else `W'` from the declared width, else none (`int` accumulates).
fn index_cast(src_cast: Option<&str>, widths: &WidthResolver<'_>, lhs: &str) -> String {
    if let Some(c) = src_cast {
        return c.to_string();
    }
    match declared_width(widths, lhs) {
        Some(w) => format!("{w}'"),
        None => String::new(),
    }
}

// ---------------------------------------------------------------- FindFirst

/// `if (V[i] && P == '0) P = X'(i);` (lo ≥ 1) or
/// `if (V[i] && !F) begin F = 1'b1; P = X'(i); end` (any lo; the two
/// assignments in either order; `F` may also be the only assignment).
fn find_first(
    idx: usize,
    lp: &GenerateLoop,
    body: &str,
    lo: u32,
    n: u32,
    widths: &WidthResolver<'_>,
    model: &CostModel,
) -> Option<LoopWalkShape> {
    let i = lp.genvar.as_str();
    let rest = body.strip_prefix("if (")?;
    let close = matching_paren(rest)?;
    let cond = &rest[..close];
    let then = rest[close + 1..].trim();
    // cond: `V[i] && GUARD` where GUARD is `P == '0` or `!F`
    let (vec_part, guard) = cond.split_once(" && ")?;
    let vec_part = vec_part.trim();
    let vec = vec_part.strip_suffix(&format!("[{i}]"))?;
    if !is_ident(vec) {
        return None;
    }
    let guard = guard.trim();
    let (flag, pick_guard) = if let Some(f) = guard.strip_prefix('!') {
        (Some(f.trim()), None)
    } else if let Some((p, z)) = guard.split_once(" == ") {
        if z.trim() == "'0" || z.trim() == "0" {
            (None, Some(p.trim()))
        } else {
            return None;
        }
    } else {
        return None;
    };
    // then: statements
    let stmts: Vec<&str> = {
        let t = then.strip_prefix("begin").map(str::trim).unwrap_or(then);
        let t = t.strip_suffix("end").map(str::trim).unwrap_or(t);
        t.split(';')
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .collect()
    };
    if stmts.is_empty() || stmts.len() > 2 {
        return None;
    }
    let mut pick: Option<(String, Option<String>)> = None; // (lhs, cast)
    let mut sets_flag = false;
    for st in &stmts {
        let (lhs, rhs) = st.split_once('=')?;
        let lhs = lhs.trim();
        let rhs = rhs.trim();
        if Some(lhs) == flag && (rhs == "1'b1" || rhs == "1") {
            sets_flag = true;
            continue;
        }
        let (cast, inner) = split_cast(rhs);
        if inner != i || !is_ident(lhs) {
            return None;
        }
        pick = Some((lhs.to_string(), cast));
    }
    if let Some(f) = flag {
        if !sets_flag {
            return None;
        }
        if let Some((p, _)) = &pick {
            if p == f {
                return None;
            }
        }
    } else {
        let (p, _) = pick.as_ref()?;
        if Some(p.as_str()) != pick_guard {
            return None;
        }
        if lo == 0 {
            // `pick == 0` after selecting bit 0 keeps scanning: not a find-first.
            return None;
        }
    }
    // The vector must be at least N bits wide.
    if declared_width(widths, vec).is_some_and(|w| w < n) {
        return None;
    }
    let carried = pick
        .as_ref()
        .map(|(p, _)| p.clone())
        .or_else(|| flag.map(str::to_string))?;
    let low = format!("{carried}_svt_low");
    let mut rep = String::new();
    let guard_text = match flag {
        Some(f) => format!("!{f}"),
        None => format!("{carried} == '0"),
    };
    rep.push_str(&format!("if ({guard_text}) begin : {carried}_svt_ff\n"));
    if lo == 0 {
        rep.push_str(&format!("  {low} = {vec} & (~{vec} + 1'b1);\n"));
    } else {
        // mask off bits below lo, then isolate the lowest set bit
        rep.push_str(&format!(
            "  {low} = {vec} & ~{n}'(({n}'(1) << {lo}) - 1'b1);\n  {low} = {low} & (~{low} + 1'b1);\n"
        ));
    }
    if let Some((p, cast)) = &pick {
        let c = index_cast(cast.as_deref(), widths, p);
        rep.push_str(&format!(
            "  for (int unsigned {i} = {lo}; {i} < {n}; {i}++) if ({low}[{i}]) {p} = {p} | {c}({i});\n"
        ));
    }
    if let Some(f) = flag {
        rep.push_str(&format!("  {f} = |{low};\n"));
    }
    rep.push_str("end");
    let decls = format!("  logic [{}:0] {low};\n", n - 1);
    // One incrementer over N bits plus an OR tree of log2(N) levels.
    let fo4_after = model.scaled_fo4(crate::OperatorClass::Compare, Some(n))
        + model.logic_bit * f64::from(n.next_power_of_two().trailing_zeros().max(1))
        + model.logic_bit;
    Some(LoopWalkShape {
        kind: LoopWalkKind::FindFirst,
        loop_index: idx,
        trips: n - lo,
        replacement: rep,
        decls,
        marker: low,
        carried,
        fo4_after,
        rationale: format!(
            "find-first scan over `{vec}` ({} iterations) → lowest-set-bit isolate + OR-encode (exact)",
            n - lo
        ),
    })
}

fn matching_paren(s: &str) -> Option<usize> {
    let mut depth = 1i32;
    for (i, c) in s.char_indices() {
        match c {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if depth == 0 {
                    return Some(i);
                }
            }
            _ => {}
        }
    }
    None
}

// ---------------------------------------------------------------- CondCount

/// `if (COND) C = C + 1'b1;` → `C = C + W'($countones(vec))` with
/// `vec[i] = COND`. COND may use the loop variable freely; it must not assign.
fn cond_count(
    idx: usize,
    lp: &GenerateLoop,
    body: &str,
    lo: u32,
    n: u32,
    widths: &WidthResolver<'_>,
    model: &CostModel,
) -> Option<LoopWalkShape> {
    let i = lp.genvar.as_str();
    let rest = body.strip_prefix("if (")?;
    let close = matching_paren(rest)?;
    let cond = rest[..close].trim();
    let then = rest[close + 1..].trim();
    let then = then.strip_prefix("begin").map(str::trim).unwrap_or(then);
    let then = then.strip_suffix("end").map(str::trim).unwrap_or(then);
    let then = then.strip_suffix(';').map(str::trim).unwrap_or(then);
    if then.contains(';') {
        return None;
    }
    let (lhs, rhs) = then.split_once('=')?;
    let cnt = lhs.trim();
    if !is_ident(cnt) {
        return None;
    }
    let rhs = rhs.trim();
    let one_forms = [
        format!("{cnt} + 1'b1"),
        format!("{cnt} + 1"),
        format!("{cnt} + 1'd1"),
    ];
    if !one_forms.iter().any(|f| f == rhs) {
        return None;
    }
    // COND must read the loop var and must not read the count (that would be
    // a dependence the popcount cannot express).
    let ids = idents(cond);
    if !ids.iter().any(|s| s == i) || ids.iter().any(|s| s == cnt) {
        return None;
    }
    let w = declared_width(widths, cnt)?;
    if (1u64 << w.min(63)) <= u64::from(n - lo) {
        return None; // the count could not hold N: not a popcount shape
    }
    let vec = format!("{cnt}_svt_vec");
    let mut rep = String::new();
    rep.push_str(&format!("begin : {cnt}_svt_cnt\n  {vec} = '0;\n"));
    rep.push_str(&format!(
        "  for (int unsigned {i} = {lo}; {i} < {n}; {i}++) {vec}[{i}] = ({cond});\n"
    ));
    rep.push_str(&format!("  {cnt} = {cnt} + {w}'($countones({vec}));\nend"));
    let decls = format!("  logic [{}:0] {vec};\n", n - 1);
    // popcount tree (log2 N adder levels, CSA) + one final add of width w
    let levels = f64::from(n.next_power_of_two().trailing_zeros().max(1));
    let fo4_after = model.scaled_fo4(crate::OperatorClass::AddSub, Some(w)) + 1.5 * levels;
    Some(LoopWalkShape {
        kind: LoopWalkKind::CondCount,
        loop_index: idx,
        trips: n - lo,
        replacement: rep,
        decls,
        marker: vec,
        carried: cnt.to_string(),
        fo4_after,
        rationale: format!(
            "conditional running count `{cnt}` over {} iterations → popcount of the verdict vector (exact)",
            n - lo
        ),
    })
}

// ---------------------------------------------------------------- RingWalk

/// `CID = A;` before the loop; body `if (CID == B) break; BODY; CID = CID +
/// 1'b1;` → per-slot membership of `[A, B)` on the ring. Exact when
/// `N == 2**width(CID)`.
fn ring_walk(
    idx: usize,
    lp: &GenerateLoop,
    body: &str,
    lo: u32,
    n: u32,
    widths: &WidthResolver<'_>,
    model: &CostModel,
) -> Option<LoopWalkShape> {
    if lo != 0 {
        return None;
    }
    let k = lp.genvar.as_str();
    let rest = body.strip_prefix("if (")?;
    let close = matching_paren(rest)?;
    let cond = rest[..close].trim();
    let (cid, b) = cond.split_once(" == ")?;
    let cid = cid.trim();
    let b = b.trim();
    if !is_ident(cid) {
        return None;
    }
    let after = rest[close + 1..].trim();
    let after = after.strip_prefix("break;")?.trim();
    let step = format!("{cid} = {cid} + 1'b1;");
    let inner = after.strip_suffix(&step)?.trim();
    // The body must not assign cid, break, or use the loop variable.
    let inner_ids = idents(inner);
    if inner.contains("break") || inner_ids.iter().any(|s| s == k) {
        return None;
    }
    for st in inner.split(';') {
        if let Some((lhs, _)) = st.split_once('=') {
            let lhs = lhs.trim().trim_end_matches(['<', '>', '!']);
            let root: String = lhs
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
                .collect();
            if root == cid {
                return None;
            }
            // assignments to anything read by the bounds break invariance
            if idents(b).iter().any(|s| *s == root) {
                return None;
            }
        }
    }
    // Seed: last statement before the loop assigns cid.
    let pre = lp.pre_text.as_deref()?;
    let pre = normalize_ws(pre);
    let seed_stmt = pre.rsplit(';').nth(1)?.trim(); // the statement before the trailing fragment
    let (seed_lhs, a) = seed_stmt.split_once('=')?;
    if seed_lhs.trim() != cid {
        return None;
    }
    let a = a.trim();
    if idents(a).iter().any(|s| s == cid) {
        return None;
    }
    let w = declared_width(widths, cid)?;
    if w == 0 || w > 31 || (1u32 << w) != n {
        return None;
    }
    let win = format!("{cid}_svt_win");
    let j = format!("{cid}_svt_i");
    let body_j = replace_ident(inner, cid, &format!("{w}'({j})"));
    let mut rep = String::new();
    rep.push_str(&format!("begin : {cid}_svt_ring\n"));
    rep.push_str(&format!(
        "  for (int unsigned {j} = 0; {j} < {n}; {j}++) {win}[{j}] = (({a}) != ({b})) && ((({b}) > ({a})) ? ({w}'({j}) >= ({a}) && {w}'({j}) < ({b})) : ({w}'({j}) >= ({a}) || {w}'({j}) < ({b})));\n"
    ));
    let body_j = body_j.trim().trim_end_matches(';').to_string();
    rep.push_str(&format!(
        "  for (int unsigned {j} = 0; {j} < {n}; {j}++) if ({win}[{j}]) begin {body_j}; end\n"
    ));
    rep.push_str(&format!("  {cid} = {b};\nend"));
    let decls = format!("  logic [{}:0] {win};\n", n - 1);
    // two compares of width w and a mux, in parallel per slot
    let fo4_after =
        model.scaled_fo4(crate::OperatorClass::Compare, Some(w)) + model.mux + model.logic_bit;
    Some(LoopWalkShape {
        kind: LoopWalkKind::RingWalk,
        loop_index: idx,
        trips: n,
        replacement: rep,
        decls,
        marker: win,
        carried: cid.to_string(),
        fo4_after,
        rationale: format!(
            "ring walk `{cid}` from `{a}` to `{b}` ({n} slots) → per-slot interval membership (exact for N == 2**{w})"
        ),
    })
}

// ------------------------------------------------------------ StreamCompact

/// Split a statement list text at top-level `;` (brackets, parens and
/// `begin … end` blocks kept whole).
fn split_statements(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut depth = 0i32;
    let mut block = 0i32;
    let mut cur = String::new();
    let mut i = 0usize;
    let b = text.as_bytes();
    while i < b.len() {
        let c = b[i] as char;
        if c.is_ascii_alphabetic() || c == '_' {
            let start = i;
            while i < b.len() && ((b[i] as char).is_ascii_alphanumeric() || b[i] == b'_') {
                i += 1;
            }
            let w = &text[start..i];
            if w == "begin" {
                block += 1;
            } else if w == "end" {
                block -= 1;
                cur.push_str(w);
                if block == 0 && depth == 0 {
                    out.push(cur.trim().to_string());
                    cur.clear();
                }
                continue;
            }
            cur.push_str(w);
            continue;
        }
        match c {
            '(' | '[' | '{' => depth += 1,
            ')' | ']' | '}' => depth -= 1,
            _ => {}
        }
        if c == ';' && depth == 0 && block == 0 {
            out.push(cur.trim().to_string());
            cur.clear();
        } else {
            cur.push(c);
        }
        i += 1;
    }
    if !cur.trim().is_empty() {
        out.push(cur.trim().to_string());
    }
    out.into_iter().filter(|s| !s.is_empty()).collect()
}

/// `if (COND) BODY` → `(COND, BODY)` for a statement whose body is the rest
/// (a `begin … end` block has its delimiters stripped).
fn split_if(stmt: &str) -> Option<(String, String)> {
    let rest = stmt.trim().strip_prefix("if (")?;
    let close = matching_paren(rest)?;
    let cond = rest[..close].trim().to_string();
    let body = rest[close + 1..].trim();
    let body = body.strip_prefix("begin").map(str::trim).unwrap_or(body);
    let body = body.strip_suffix("end").map(str::trim).unwrap_or(body);
    Some((cond, body.to_string()))
}

/// Stream compaction. Loop body (after `for (k …)`), with optional outer
/// guard and per-iteration temps:
///
/// ```text
/// [if (G) begin]  [T = e(k); …]  if (C) begin  OUT1[dst] = R1; … OUTm[dst] = Rm;
///                                               dst = dst + 1'b1; [cnt = cnt + 1'b1;] end  [end]
/// ```
///
/// `dst` runs 0.. over the kept iterations, so `OUTi[dst] = Ri` is a gather:
/// `keep[k] = G && C`, `pos[k] = $countones(keep[k-1:0])` (independent
/// popcounts, log depth, not a running sum), and `OUTi[j] = Ri(k)` for the one
/// `k` with `keep[k] && pos[k] == j`. `dst` and every count advance by
/// `$countones(keep)`. Exact when `dst`/counts are not read in `G`, `T`, `C`,
/// `Ri`, and no `OUTi` is read in the loop (the temps `T` are recomputed per
/// `k` in the gather).
fn stream_compact(
    idx: usize,
    lp: &GenerateLoop,
    body: &str,
    lo: u32,
    n: u32,
    widths: &WidthResolver<'_>,
    model: &CostModel,
) -> Option<LoopWalkShape> {
    if lo != 0 || n > 64 {
        return None;
    }
    let k = lp.genvar.as_str();
    // optional outer guard
    // An outer `if (G)` wraps the compaction when its body still holds an `if`.
    let (outer, inner_text) = match split_if(body) {
        Some((g, b)) if split_statements(&b).iter().any(|s| s.starts_with("if (")) => (Some(g), b),
        _ => (None, body.to_string()),
    };
    let stmts = split_statements(&inner_text);
    // prelude temps then one `if (C) begin … end`
    let mut prelude: Vec<(String, String)> = Vec::new();
    let mut compact: Option<(String, String)> = None;
    for st in &stmts {
        if st.starts_with("if (") {
            if compact.is_some() {
                return None; // two conditionals: not this shape
            }
            compact = Some(split_if(st)?);
        } else if compact.is_none() {
            let (l, r) = st.split_once('=')?;
            let l = l.trim();
            if !is_ident(l) || r.trim_start().starts_with('=') {
                return None;
            }
            prelude.push((l.to_string(), r.trim().to_string()));
        } else {
            return None; // statements after the compaction block
        }
    }
    let (cond, cbody) = compact?;
    let cstmts = split_statements(&cbody);
    let mut outs: Vec<(String, String, String)> = Vec::new(); // (out, index var, rhs)
    let mut counts: Vec<String> = Vec::new();
    for st in &cstmts {
        let (l, r) = st.split_once('=')?;
        let l = l.trim();
        let r = r.trim();
        if let Some(open) = l.find('[') {
            let base = &l[..open];
            let ix = l[open + 1..].strip_suffix(']')?.trim();
            if !is_ident(base) || !is_ident(ix) {
                return None;
            }
            outs.push((base.to_string(), ix.to_string(), r.to_string()));
        } else if is_ident(l)
            && (r == format!("{l} + 1'b1") || r == format!("{l} + 1") || r == format!("{l} + 1'd1"))
        {
            counts.push(l.to_string());
        } else {
            return None;
        }
    }
    if outs.is_empty() || counts.is_empty() {
        return None;
    }
    let dst = outs[0].1.clone();
    if !outs.iter().all(|(_, ix, _)| *ix == dst) || !counts.contains(&dst) {
        return None;
    }
    // Exactness: counts not read anywhere in the body; outputs not read.
    let reads_any =
        |text: &str, names: &[String]| idents(text).iter().any(|t| names.iter().any(|n| n == t));
    let all_text = format!(
        "{} {} {} {}",
        outer.as_deref().unwrap_or(""),
        prelude
            .iter()
            .map(|(_, r)| r.clone())
            .collect::<Vec<_>>()
            .join(" "),
        cond,
        outs.iter()
            .map(|(_, _, r)| r.clone())
            .collect::<Vec<_>>()
            .join(" ")
    );
    if reads_any(&all_text, &counts) {
        return None;
    }
    let out_names: Vec<String> = outs.iter().map(|(o, _, _)| o.clone()).collect();
    if reads_any(&all_text, &out_names) {
        return None;
    }
    // the temps must not read the loop's outputs or counts either (covered) and
    // prelude LHS must not be an output
    if prelude
        .iter()
        .any(|(l, _)| out_names.contains(l) || counts.contains(l))
    {
        return None;
    }
    // `dst` is usually a block-local automatic the module-scope resolver does
    // not see; the count update is cast to the bits of 0..=n and truncates on
    // assignment exactly as the repeated `+ 1'b1` did (mod 2^width).
    let pw_bits = (n + 1).next_power_of_two().trailing_zeros().max(1);
    // The count is cast to at least the bits of 0..=n (a narrower resolved
    // width would truncate the popcount itself); the assignment then wraps
    // modulo the LHS width exactly as the repeated `+ 1'b1` did.
    let w = declared_width(widths, &dst).unwrap_or(pw_bits).max(pw_bits);
    // `dst` must enter the loop at zero (the statement before the loop):
    // the gather compares ranks with absolute slots.
    let pre = normalize_ws(lp.pre_text.as_deref()?);
    if !(pre.contains(&format!("{dst} = '0;")) || pre.contains(&format!("{dst} = 0;"))) {
        return None;
    }
    let keep = format!("{dst}_svt_keep");
    let pos = format!("{dst}_svt_pos");
    let j = format!("{dst}_svt_j");
    let kk = format!("{dst}_svt_k");
    let pw = (n + 1).next_power_of_two().trailing_zeros().max(1); // bits for 0..=n
    let prelude_text = |var: &str| -> String {
        prelude
            .iter()
            .map(|(l, r)| format!("{l} = {}; ", replace_ident(r, k, var)))
            .collect::<Vec<_>>()
            .join("")
    };
    let full_cond = match &outer {
        Some(g) => format!("({g}) && ({cond})"),
        None => cond.clone(),
    };
    let mut rep = String::new();
    rep.push_str(&format!("begin : {dst}_svt_compact\n"));
    rep.push_str(&format!("  {keep} = '0;\n"));
    rep.push_str(&format!(
        "  for (int unsigned {kk} = 0; {kk} < {n}; {kk}++) begin {}{keep}[{kk}] = {}; end\n",
        prelude_text(&kk),
        replace_ident(&full_cond, k, &kk)
    ));
    rep.push_str(&format!(
        "  for (int unsigned {kk} = 0; {kk} < {n}; {kk}++) {pos}[{kk}] = {pw}'($countones({keep} & (({n}'(1) << {kk}) - 1'b1)));\n"
    ));
    rep.push_str(&format!(
        "  for (int unsigned {j} = 0; {j} < {n}; {j}++) for (int unsigned {kk} = 0; {kk} < {n}; {kk}++) begin {}if ({keep}[{kk}] && {pos}[{kk}] == {pw}'({j})) begin ",
        prelude_text(&kk)
    ));
    for (o, _, r) in &outs {
        rep.push_str(&format!("{o}[{j}] = {}; ", replace_ident(r, k, &kk)));
    }
    rep.push_str("end end\n");
    for c in &counts {
        rep.push_str(&format!("  {c} = {c} + {w}'($countones({keep}));\n"));
    }
    rep.push_str("end");
    let decls = format!(
        "  logic [{}:0] {keep};\n  logic [{}:0][{}:0] {pos};\n",
        n - 1,
        n - 1,
        pw - 1
    );
    // keep: one guard level; pos: popcount tree; gather: compare + AND-OR over n
    let levels = f64::from(n.next_power_of_two().trailing_zeros().max(1));
    let fo4_after = model.logic_bit
        + 1.5 * levels
        + model.scaled_fo4(crate::OperatorClass::Compare, Some(pw))
        + model.mux
        + model.logic_bit * levels;
    Some(LoopWalkShape {
        kind: LoopWalkKind::StreamCompact,
        loop_index: idx,
        trips: n,
        replacement: rep,
        decls,
        marker: keep,
        carried: dst,
        fo4_after,
        rationale: format!(
            "stream compaction over {n} slots ({} outputs) → keep vector, prefix popcounts, one-hot gather (exact)",
            outs.len()
        ),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn body_of(text: &str) -> String {
        normalize_ws(&loop_body(text).unwrap())
    }

    /// Convenience: resolver for a module of a design.
    pub(crate) fn resolver_for<'a>(
        design: &'a crate::TimingDesign,
        m: &'a TimingModule,
    ) -> WidthResolver<'a> {
        WidthResolver::from_parts(
            &design.packages,
            &design.param_map_ints,
            &m.decls,
            &m.ports,
            &m.const_exprs,
            &m.typedef_texts,
            &m.package_imports,
            design.width_map.get(&m.name),
        )
    }

    #[test]
    fn fixture_yields_the_four_walks_and_spares_the_parallel_module() {
        let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures/auto_correct/loop_walks.sv");
        let lower = crate::LowerOptions {
            target: crate::TimingTarget::new(4000.0, 20.0, 0.2),
            cost_model: crate::default_fo4_v1_embedded(),
            ..Default::default()
        };
        let out = crate::analyze_files(&[path], &crate::ParseOptions::default(), &lower)
            .expect("analyze");
        let model = CostModel::default();
        let walks = out
            .design
            .modules
            .values()
            .find(|m| m.name == "loop_walks")
            .expect("module");
        // `input logic [31:0] free_i, hit_i, ok_i`: every name of the list is
        // 32 bits (port-list inheritance; `hit_i` used to be 1 bit).
        assert_eq!(
            declared_width(&resolver_for(&out.design, walks), "hit_i"),
            Some(32)
        );
        let shapes = detect(walks, &resolver_for(&out.design, walks), &model);
        let kinds: Vec<(LoopWalkKind, &str)> = shapes
            .iter()
            .map(|s| (s.kind, s.carried.as_str()))
            .collect();
        assert_eq!(
            kinds,
            vec![
                (LoopWalkKind::FindFirst, "pick_d"),
                (LoopWalkKind::FindFirst, "found_d"),
                (LoopWalkKind::CondCount, "cnt_d"),
                (LoopWalkKind::RingWalk, "cid"),
            ],
            "{shapes:#?}"
        );
        let ff = &shapes[0];
        assert!(
            ff.replacement
                .contains("pick_d_svt_low = free_i & ~32'((32'(1) << 1) - 1'b1);"),
            "{}",
            ff.replacement
        );
        assert!(
            ff.replacement.contains("pick_d = pick_d | 5'(i);"),
            "{}",
            ff.replacement
        );
        assert_eq!(ff.decls.trim(), "logic [31:0] pick_d_svt_low;");
        let fl = &shapes[1];
        assert!(
            fl.replacement
                .contains("found_d_svt_low = hit_i & (~hit_i + 1'b1);"),
            "{}",
            fl.replacement
        );
        assert!(
            fl.replacement.contains("found_d = |found_d_svt_low;"),
            "{}",
            fl.replacement
        );
        let cc = &shapes[2];
        assert!(
            cc.replacement
                .contains("cnt_d_svt_vec[k] = (ok_i[k] && hit_i[k]);"),
            "{}",
            cc.replacement
        );
        assert!(
            cc.replacement
                .contains("cnt_d = cnt_d + 5'($countones(cnt_d_svt_vec));"),
            "{}",
            cc.replacement
        );
        let rw = &shapes[3];
        assert!(
            rw.replacement
                .contains("cid_svt_win[cid_svt_i] = ((after_i) != (ip_i))"),
            "{}",
            rw.replacement
        );
        assert!(rw.replacement.contains("if (cid_svt_win[cid_svt_i]) begin if (ok_i[5'(cid_svt_i)]) mask_d[5'(cid_svt_i)] = 1'b1; end"), "{}", rw.replacement);
        assert!(
            rw.replacement.ends_with(
                "  cid = ip_i;
end"
            ),
            "{}",
            rw.replacement
        );
        // Each parallel form is a few levels; the walks they replace are
        // 31-32 serial copies (delay-v35 bills them at trips x body).
        for s in &shapes {
            assert!(s.fo4_after < 13.0, "{:?} {}", s.kind, s.fo4_after);
        }
        // Low FO4 is not lost: the parallel module has no walk to rewrite.
        let par = out
            .design
            .modules
            .values()
            .find(|m| m.name == "loop_walks_parallel")
            .expect("module");
        assert!(detect(par, &resolver_for(&out.design, par), &model).is_empty());
    }

    /// A103: the store buffer's cancel squash is a stream compaction — an
    /// outer window guard, a per-iteration `src` temp, a keep condition, two
    /// gathered outputs at `dst`, and two counts. Replacement: keep vector,
    /// prefix popcounts, one-hot gather, counts advanced by the popcount.
    #[test]
    fn fixture_stream_compaction_is_detected_with_outer_guard_and_temps() {
        let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures/auto_correct/stream_compact.sv");
        let lower = crate::LowerOptions {
            target: crate::TimingTarget::new(4000.0, 20.0, 0.2),
            cost_model: crate::default_fo4_v1_embedded(),
            ..Default::default()
        };
        let out = crate::analyze_files(&[path], &crate::ParseOptions::default(), &lower)
            .expect("analyze");
        let m = out.design.modules.values().next().expect("module");
        let shapes = detect(m, &resolver_for(&out.design, m), &CostModel::default());
        let sc = shapes
            .iter()
            .find(|s| s.kind == LoopWalkKind::StreamCompact)
            .unwrap_or_else(|| panic!("no StreamCompact in {shapes:#?}"));
        assert_eq!(sc.carried, "dst");
        let r = &sc.replacement;
        assert!(r.contains("dst_svt_keep[dst_svt_k] = (k < unsigned'(cnt_i)) && (valid_i[src] && !cancel_i[src]);".replace("k <", "dst_svt_k <").as_str()), "{r}");
        assert!(r.contains("src = rd_ptr_i + $clog2(N)'(dst_svt_k);"), "{r}");
        assert!(r.contains("dst_svt_pos[dst_svt_k] = 4'($countones(dst_svt_keep & ((8'(1) << dst_svt_k) - 1'b1)));"), "{r}");
        assert!(r.contains("if (dst_svt_keep[dst_svt_k] && dst_svt_pos[dst_svt_k] == 4'(dst_svt_j)) begin a_addr[dst_svt_j] = addr_i[src]; a_data[dst_svt_j] = data_i[src]; end"), "{r}");
        assert!(
            r.contains("dst = dst + 4'($countones(dst_svt_keep));"),
            "{r}"
        );
        assert!(
            r.contains("live = live + 4'($countones(dst_svt_keep));"),
            "{r}"
        );
        assert!(
            sc.decls.contains("logic [7:0] dst_svt_keep;"),
            "{}",
            sc.decls
        );
        assert!(
            sc.decls.contains("logic [7:0][3:0] dst_svt_pos;"),
            "{}",
            sc.decls
        );
    }

    /// A104: the issue-queue select under an asserted `$onehot0(grant_i[p])`
    /// becomes an AND-OR accumulate; the priority select over `prio_i` (no
    /// assertion) is left alone.
    #[test]
    fn fixture_onehot_select_fires_only_under_the_assertion() {
        let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures/auto_correct/onehot_select.sv");
        let lower = crate::LowerOptions {
            target: crate::TimingTarget::new(4000.0, 20.0, 0.2),
            cost_model: crate::default_fo4_v1_embedded(),
            ..Default::default()
        };
        let out = crate::analyze_files(&[path], &crate::ParseOptions::default(), &lower)
            .expect("analyze");
        let m = out.design.modules.values().next().expect("module");
        assert_eq!(
            m.onehot_facts,
            vec!["grant_i[p]".to_string()],
            "{:?}",
            m.onehot_facts
        );
        let shapes = detect(m, &resolver_for(&out.design, m), &CostModel::default());
        let ohs: Vec<&LoopWalkShape> = shapes
            .iter()
            .filter(|s| s.kind == LoopWalkKind::OneHotSelect)
            .collect();
        assert_eq!(ohs.len(), 1, "{shapes:#?}");
        let r = &ohs[0].replacement;
        assert!(
            r.contains("sbe_d[p] = sbe_d[p] | ((grant_i[p][e]) ? (q_i[e]) : '0);"),
            "{r}"
        );
        assert!(
            r.contains("slot_d[p] = slot_d[p] | ((grant_i[p][e]) ? ($clog2(N)'(e)) : '0);"),
            "{r}"
        );
        assert!(
            ohs[0].rationale.contains("$onehot0(grant_i[p])"),
            "{}",
            ohs[0].rationale
        );
        assert!(ohs[0].decls.is_empty());
        // the prio loop has no fact: no OneHotSelect, and no other shape either
        assert!(
            shapes.iter().all(|s| s.kind == LoopWalkKind::OneHotSelect),
            "{shapes:#?}"
        );
    }

    #[test]
    fn loop_body_strips_header_and_block() {
        assert_eq!(
            body_of("for (int unsigned i = 1; i < N; i++) begin if (a) b = 1; end"),
            "if (a) b = 1;"
        );
        assert_eq!(
            body_of("for (int i = 0; i < 4; i++) x[i] = y[i];"),
            "x[i] = y[i]"
        );
        assert_eq!(
            body_of("for (int i = 0; i < 4; i++) begin : lbl\n  x = 1;\nend"),
            "x = 1;"
        );
    }

    #[test]
    fn replace_ident_is_whole_word() {
        assert_eq!(
            replace_ident("cid + cid_x[cid]", "cid", "j"),
            "j + cid_x[j]"
        );
    }

    #[test]
    fn split_cast_recognises_width_and_type_casts() {
        assert_eq!(split_cast("PRF_W'(i)"), (Some("PRF_W'".into()), "i".into()));
        assert_eq!(split_cast("5'(k)"), (Some("5'".into()), "k".into()));
        assert_eq!(split_cast("i"), (None, "i".into()));
    }
}
