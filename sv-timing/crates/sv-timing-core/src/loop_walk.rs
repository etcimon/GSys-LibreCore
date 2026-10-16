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
        }
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
