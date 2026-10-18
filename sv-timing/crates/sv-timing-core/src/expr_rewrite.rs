// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Exact expression identities abstracted from measured hand rewrites
//! (ALGORITHMS-EXPERTS A122). Each one removes a carry chain from a cone
//! without new state, ports or latency, and is a pure RHS rewrite the
//! emitter writes back onto the origin assignment.
//!
//! | identity | from | to | exactness condition |
//! |---|---|---|---|
//! | `CircularCompare` | `(a - h) < (b - h)` | `(a < b) ^ (a < h) ^ (b < h)` | `a`, `b`, `h` unsigned; equal widths, or extension-stable operands |
//! | `ZeroDetectEquality` | `(a - b) == 0`, `!(a - b)`, `~\|(a - b)` | `a == b` (and `!=` / `\|` forms) | `a`, `b` extension-stable |
//! | `PushSelect` | `(c ? x : y) + z` | `c ? (x + z) : (y + z)` | always exact; applied only when `c` arrives later than the data |
//!
//! *Circular ordering.* Ring-buffer age tests subtract a head pointer from
//! two tags and compare the modular distances: two carry chains before the
//! comparator. For unsigned `W`-bit values the distance order equals the
//! parity of three plain comparisons — the derivation walks the four
//! placements of `a`, `b` relative to `h` on the ring. Signed operands rotate
//! the ring differently and are refused.
//!
//! *Zero detect of a difference.* `a - b == 0` is `a == b` when both sides
//! are evaluated in the same context width; the subtraction's carry chain
//! is replaced by XOR + reduce. Operands that themselves wrap (`a + c`) could
//! wrap at a different width once the unsized `0` leaves the context, so only
//! extension-stable operands (identifiers, selects, concatenations, literals)
//! qualify.
//!
//! *Push a late select through arithmetic.* `(c ? x : y) + z` serialises
//! the select before the adder; `c ? (x + z) : (y + z)` runs the adders off
//! the critical path and ends in the mux. Exact for any width and sign (the
//! whole expression's context decides both forms alike). It costs one extra
//! adder per additional arm and is only worth it when the condition arrives
//! late, so the gain is computed with structural arrivals and the area gate
//! (Dial 11) prices it.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

use crate::expr::{classify_binary_op, Expr};
use crate::ir::{AssignKind, IrNode, OperatorClass, TimingModule};
use crate::measure::CostModel;
use crate::width::WidthResolver;

/// Which identity fired.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum IdentityKind {
    /// Modular-distance compare → parity of three plain compares.
    CircularCompare,
    /// Zero detect of a difference → equality compare.
    ZeroDetectEquality,
    /// Late select pushed through add/sub (one adder per extra arm).
    PushSelect,
}

impl IdentityKind {
    /// Snake-case name for ledgers.
    pub fn as_str(self) -> &'static str {
        match self {
            IdentityKind::CircularCompare => "circular_compare",
            IdentityKind::ZeroDetectEquality => "zero_detect_equality",
            IdentityKind::PushSelect => "push_select",
        }
    }
}

/// One node's rewritten RHS and its pricing.
#[derive(Debug, Clone, PartialEq)]
pub struct IdentityShape {
    /// Leading identity (the ledger's kind); every applied one is in `kinds`.
    pub kind: IdentityKind,
    /// All identities applied inside the RHS, in application order.
    pub kinds: Vec<IdentityKind>,
    /// Assignment LHS as written.
    pub lhs_text: String,
    /// Original RHS text.
    pub rhs_before: String,
    /// Rewritten RHS text (`Expr::emit`, fully parenthesised).
    pub rhs_after: String,
    /// Rewritten tree.
    pub expr_after: Expr,
    /// Structural FO4 of the node before (arrival-aware for `PushSelect`).
    pub fo4_before: f64,
    /// Structural FO4 of the node after.
    pub fo4_after: f64,
    /// Preliminary extra cells (`PushSelect`: extra adders × width); 0 otherwise.
    pub est_cells: f64,
}

impl IdentityShape {
    /// Estimated FO4 gain on the node (never negative).
    pub fn gain(&self) -> f64 {
        (self.fo4_before - self.fo4_after).max(0.0)
    }
}

/// Structural arrival per identifier root inside one module: registers,
/// ports and constants arrive at 0; a combinationally defined name arrives
/// at its definition's cost plus the latest of its reads. Cycles are cut at
/// the back edge. An estimate for ordering decisions, not a timing report.
#[derive(Debug, Clone, Default)]
pub struct Arrivals {
    map: BTreeMap<String, f64>,
}

impl Arrivals {
    /// Compute for `module`; `regs` are its register roots.
    pub fn of(module: &TimingModule, regs: &BTreeSet<String>, model: &CostModel) -> Self {
        let mut defs: BTreeMap<&str, Vec<&IrNode>> = BTreeMap::new();
        for n in module.nodes.values() {
            if !n.assign_kind.is_comb_def() {
                continue;
            }
            if let Some(root) = n.lhs.as_deref().and_then(TimingModule::root_ident) {
                if !regs.contains(root) {
                    defs.entry(root).or_default().push(n);
                }
            }
        }
        let mut out = Arrivals::default();
        let mut visiting = BTreeSet::new();
        let names: Vec<&str> = defs.keys().copied().collect();
        for name in names {
            Self::arrival_of(name, &defs, &mut out.map, &mut visiting, model, 0);
        }
        out
    }

    fn arrival_of(
        name: &str,
        defs: &BTreeMap<&str, Vec<&IrNode>>,
        memo: &mut BTreeMap<String, f64>,
        visiting: &mut BTreeSet<String>,
        model: &CostModel,
        depth: u32,
    ) -> f64 {
        if let Some(v) = memo.get(name) {
            return *v;
        }
        let Some(nodes) = defs.get(name) else {
            return 0.0;
        };
        if depth > 64 || !visiting.insert(name.to_string()) {
            return 0.0;
        }
        let mut worst = 0.0f64;
        for n in nodes {
            let mut reads = 0.0f64;
            if let Some(e) = &n.rhs_expr {
                let mut idents = Vec::new();
                e.walk_idents(&mut |id| idents.push(id.to_string()));
                for id in idents {
                    let root = TimingModule::root_ident(&id).unwrap_or(id.as_str());
                    reads = reads.max(Self::arrival_of(
                        root,
                        defs,
                        memo,
                        visiting,
                        model,
                        depth + 1,
                    ));
                }
            }
            let own = if n.fo4_cost > 0.0 {
                n.fo4_cost
            } else {
                n.rhs_expr
                    .as_ref()
                    .map(|e| e.fo4_critical_cost(&|c| model.base_fo4(c)))
                    .unwrap_or(0.0)
            };
            worst = worst.max(reads + own);
        }
        visiting.remove(name);
        memo.insert(name.to_string(), worst);
        worst
    }

    /// Arrival of an identifier (its root), 0 when unknown.
    pub fn get(&self, ident: &str) -> f64 {
        let root = TimingModule::root_ident(ident).unwrap_or(ident);
        self.map.get(root).copied().unwrap_or(0.0)
    }

    /// Arrival-aware critical cost of an expression: every leaf starts at
    /// its own arrival and operators add their class cost on the way up.
    pub fn cost(&self, e: &Expr, model: &CostModel) -> f64 {
        let base = |c| model.base_fo4(c);
        match e {
            Expr::Ident { name } => self.get(name),
            Expr::Literal { .. } => 0.0,
            Expr::Opaque { text } => {
                let mut worst = 0.0f64;
                Expr::parse(text).walk_idents(&mut |id| worst = worst.max(self.get(id)));
                worst
            }
            Expr::Unary { op, arg } => {
                self.cost(arg, model) + base(crate::expr::classify_unary(op))
            }
            Expr::Binary {
                op_class,
                left,
                right,
                ..
            } => self.cost(left, model).max(self.cost(right, model)) + base(*op_class),
            Expr::Ternary {
                cond,
                then_e,
                else_e,
            } => {
                self.cost(cond, model)
                    .max(self.cost(then_e, model))
                    .max(self.cost(else_e, model))
                    + base(OperatorClass::Mux)
            }
            Expr::Concat { parts } => parts
                .iter()
                .map(|p| self.cost(p, model))
                .fold(0.0, f64::max),
            Expr::Replicate { body, .. } => self.cost(body, model),
            Expr::Index { base: b, index } => self
                .cost(b, model)
                .max(self.cost(index, model) + base(OperatorClass::Mux)),
            Expr::PartSelect { left, right, .. } => {
                self.cost(left, model).max(self.cost(right, model))
            }
            Expr::Call { args, .. } => {
                args.iter().map(|a| self.cost(a, model)).fold(0.0, f64::max)
                    + base(OperatorClass::Other)
            }
        }
    }
}

/// Signedness of an expression's leaves as declared in the module:
/// `Some(true)` when every leaf is unsigned, `Some(false)` when one is
/// signed, `None` when a leaf's type cannot be read (refuse).
fn leaves_unsigned(e: &Expr, module: &TimingModule, resolver: &WidthResolver<'_>) -> Option<bool> {
    let mut verdict = Some(true);
    let mut check = |name: &str| {
        if verdict != Some(true) {
            return;
        }
        verdict = ident_unsigned(name, module, resolver);
    };
    let mut signed_literal = false;
    walk_leaves(e, &mut check, &mut |lit| {
        if lit.contains("'s") || lit.contains("'S") {
            signed_literal = true;
        }
    });
    if signed_literal {
        return Some(false);
    }
    verdict
}

fn walk_leaves(e: &Expr, on_ident: &mut dyn FnMut(&str), on_literal: &mut dyn FnMut(&str)) {
    match e {
        Expr::Ident { name } => on_ident(name),
        Expr::Literal { text } => on_literal(text),
        Expr::Opaque { .. } => on_ident("\u{0}opaque"),
        Expr::Unary { arg, .. } => walk_leaves(arg, on_ident, on_literal),
        Expr::Binary { left, right, .. } | Expr::PartSelect { left, right, .. } => {
            walk_leaves(left, on_ident, on_literal);
            walk_leaves(right, on_ident, on_literal);
        }
        Expr::Ternary {
            cond,
            then_e,
            else_e,
        } => {
            walk_leaves(cond, on_ident, on_literal);
            walk_leaves(then_e, on_ident, on_literal);
            walk_leaves(else_e, on_ident, on_literal);
        }
        Expr::Concat { parts } => parts
            .iter()
            .for_each(|p| walk_leaves(p, on_ident, on_literal)),
        Expr::Replicate { body, .. } => walk_leaves(body, on_ident, on_literal),
        Expr::Index { base, index } => {
            // The index selects; its own signedness does not enter the value.
            walk_leaves(base, on_ident, on_literal);
            let _ = index;
        }
        Expr::Call { name, args } => {
            if name == "$unsigned" {
                return;
            }
            if name == "$signed" {
                on_ident("\u{0}signed");
                return;
            }
            args.iter()
                .for_each(|a| walk_leaves(a, on_ident, on_literal));
        }
    }
}

const SIGNED_TYPES: [&str; 6] = ["int", "integer", "byte", "shortint", "longint", "real"];

fn type_text_unsigned(type_name: &str, dims: &str, module: &TimingModule) -> Option<bool> {
    let t = type_name.trim();
    if t.is_empty() {
        return None;
    }
    let combined = format!("{t} {dims}");
    if combined.contains("unsigned") {
        return Some(true);
    }
    if combined.contains("signed") {
        return Some(false);
    }
    let t = t.split_whitespace().next().unwrap_or(t);
    if SIGNED_TYPES.contains(&t) {
        return Some(false);
    }
    if matches!(t, "logic" | "bit" | "reg" | "wire") {
        return Some(true);
    }
    // A typedef: read its text (a packed vector or struct of unsigned members).
    let key = t.rsplit("::").next().unwrap_or(t);
    let text = module.typedef_texts.get(key)?;
    if text.contains("signed") && !text.contains("unsigned") {
        return Some(false);
    }
    if SIGNED_TYPES.iter().any(|s| {
        text.split(|c: char| !c.is_alphanumeric() && c != '_')
            .any(|w| w == *s)
    }) {
        return Some(false);
    }
    if text.contains("logic") || text.contains("bit") || text.contains("enum") {
        return Some(true);
    }
    None
}

fn ident_unsigned(name: &str, module: &TimingModule, resolver: &WidthResolver<'_>) -> Option<bool> {
    if name.starts_with('\u{0}') {
        return if name == "\u{0}signed" {
            Some(false)
        } else {
            None
        };
    }
    let root = TimingModule::root_ident(name).unwrap_or(name);
    if resolver.is_const_name(root) || name.contains("::") {
        // Parameters / package constants: unsigned unless declared otherwise
        // is not knowable from here; treat integer-typed ones as unknown.
        return resolver.const_value(name).map(|v| v >= 0);
    }
    if let Some(d) = module.decls.iter().find(|d| d.name == root) {
        return type_text_unsigned(&d.type_name, &d.packed_text, module);
    }
    if let Some(p) = module.ports.iter().find(|p| p.name == root) {
        return type_text_unsigned(
            p.type_name.as_deref().unwrap_or("logic"),
            p.packed_dims.as_deref().unwrap_or(""),
            module,
        );
    }
    None
}

/// An operand whose value does not depend on the width it is evaluated in:
/// no arithmetic or shift anywhere inside it.
fn extension_stable(e: &Expr) -> bool {
    match e {
        Expr::Ident { .. } | Expr::Literal { .. } => true,
        Expr::Opaque { .. } => false,
        Expr::Unary { op, arg } => {
            matches!(
                op.as_str(),
                "~" | "!" | "&" | "|" | "^" | "~&" | "~|" | "~^" | "^~"
            ) && extension_stable(arg)
        }
        Expr::Binary {
            op_class,
            left,
            right,
            ..
        } => {
            matches!(
                op_class,
                OperatorClass::LogicBit | OperatorClass::Compare | OperatorClass::Concat
            ) && extension_stable(left)
                && extension_stable(right)
        }
        Expr::Ternary {
            cond,
            then_e,
            else_e,
        } => extension_stable(cond) && extension_stable(then_e) && extension_stable(else_e),
        Expr::Concat { parts } => parts.iter().all(extension_stable),
        Expr::Replicate { body, .. } => extension_stable(body),
        Expr::Index { base, .. } => extension_stable(base),
        Expr::PartSelect { left, .. } => extension_stable(left),
        Expr::Call { name, args } => {
            matches!(name.as_str(), "$unsigned" | "$signed") && args.iter().all(extension_stable)
        }
    }
}

fn is_zero(e: &Expr) -> bool {
    match e {
        Expr::Literal { text } => {
            let t = text.replace('_', "");
            if t == "'0" {
                return true;
            }
            match crate::width::parse_sv_int(&t) {
                Some((_, v)) => v == 0,
                None => false,
            }
        }
        Expr::Replicate { body, .. } => is_zero(body),
        Expr::Concat { parts } => !parts.is_empty() && parts.iter().all(is_zero),
        _ => false,
    }
}

fn bin(op: &str, left: Expr, right: Expr) -> Expr {
    Expr::Binary {
        op: op.to_string(),
        op_class: classify_binary_op(op),
        left: Box::new(left),
        right: Box::new(right),
    }
}

fn sub_parts(e: &Expr) -> Option<(&Expr, &Expr)> {
    match e {
        Expr::Binary {
            op, left, right, ..
        } if op == "-" => Some((left, right)),
        _ => None,
    }
}

/// Context the identities need from the enclosing module.
struct Ctx<'a> {
    module: &'a TimingModule,
    resolver: &'a WidthResolver<'a>,
    arrivals: &'a Arrivals,
    model: &'a CostModel,
    /// Width of the node's result (for the `PushSelect` cell estimate).
    node_width: Option<u32>,
}

fn circular_compare(e: &Expr, cx: &Ctx<'_>) -> Option<Expr> {
    let Expr::Binary {
        op, left, right, ..
    } = e
    else {
        return None;
    };
    if !matches!(op.as_str(), "<" | "<=" | ">" | ">=") {
        return None;
    }
    let (a, h1) = sub_parts(left)?;
    let (b, h2) = sub_parts(right)?;
    if h1 != h2 {
        return None;
    }
    let h = h1;
    for part in [a, b, h] {
        if leaves_unsigned(part, cx.module, cx.resolver) != Some(true) {
            return None;
        }
    }
    let widths = [a, b, h].map(|p| cx.resolver.expr_width(p));
    let equal_widths = widths[0].is_some() && widths.iter().all(|w| *w == widths[0]);
    if !equal_widths && !(extension_stable(a) && extension_stable(b) && extension_stable(h)) {
        return None;
    }
    let ab = bin(op, a.clone(), b.clone());
    let ah = bin("<", a.clone(), h.clone());
    let bh = bin("<", b.clone(), h.clone());
    Some(bin("^", bin("^", ab, ah), bh))
}

fn zero_detect_equality(e: &Expr) -> Option<Expr> {
    let (diff, equal) = match e {
        Expr::Binary {
            op, left, right, ..
        } if matches!(op.as_str(), "==" | "!=") => {
            if is_zero(right) && sub_parts(left).is_some() {
                (&**left, op == "==")
            } else if is_zero(left) && sub_parts(right).is_some() {
                (&**right, op == "==")
            } else {
                return None;
            }
        }
        Expr::Unary { op, arg }
            if matches!(op.as_str(), "!" | "~|") && sub_parts(arg).is_some() =>
        {
            (&**arg, true)
        }
        Expr::Unary { op, arg } if op == "|" && sub_parts(arg).is_some() => (&**arg, false),
        _ => return None,
    };
    let (a, b) = sub_parts(diff)?;
    if !(extension_stable(a) && extension_stable(b)) {
        return None;
    }
    Some(bin(if equal { "==" } else { "!=" }, a.clone(), b.clone()))
}

/// Arms of a (possibly nested, ≤ 4 arms) ternary, as (conditions path, arm).
fn ternary_arms(e: &Expr) -> usize {
    match e {
        Expr::Ternary { then_e, else_e, .. } => ternary_arms(then_e) + ternary_arms(else_e),
        _ => 1,
    }
}

fn map_arms(e: &Expr, f: &dyn Fn(&Expr) -> Expr) -> Expr {
    match e {
        Expr::Ternary {
            cond,
            then_e,
            else_e,
        } => Expr::Ternary {
            cond: cond.clone(),
            then_e: Box::new(map_arms(then_e, f)),
            else_e: Box::new(map_arms(else_e, f)),
        },
        other => f(other),
    }
}

fn push_select(e: &Expr, cx: &Ctx<'_>) -> Option<(Expr, f64)> {
    let Expr::Binary {
        op, left, right, ..
    } = e
    else {
        return None;
    };
    if !matches!(op.as_str(), "+" | "-") {
        return None;
    }
    let (sel, other, sel_left) = match (&**left, &**right) {
        (t @ Expr::Ternary { .. }, o) => (t, o, true),
        (o, t @ Expr::Ternary { .. }) => (t, o, false),
        _ => return None,
    };
    let arms = ternary_arms(sel);
    if !(2..=4).contains(&arms) || matches!(other, Expr::Ternary { .. }) {
        return None;
    }
    let pushed = map_arms(sel, &|arm| {
        if sel_left {
            bin(op, arm.clone(), other.clone())
        } else {
            bin(op, other.clone(), arm.clone())
        }
    });
    let before = cx.arrivals.cost(e, cx.model);
    let after = cx.arrivals.cost(&pushed, cx.model);
    if after + 1e-6 >= before {
        return None;
    }
    let width = cx
        .resolver
        .expr_width(e)
        .or(cx.node_width)
        .unwrap_or(32)
        .max(1);
    let est_cells = f64::from((arms - 1) as u32) * f64::from(width);
    Some((pushed, est_cells))
}

/// Rewrite every identity inside `e`, bottom-up. Returns the new tree, the
/// identities applied and the extra cells they cost.
fn rewrite(e: &Expr, cx: &Ctx<'_>, applied: &mut Vec<IdentityKind>, cells: &mut f64) -> Expr {
    let rebuilt = match e {
        Expr::Unary { op, arg } => Expr::Unary {
            op: op.clone(),
            arg: Box::new(rewrite(arg, cx, applied, cells)),
        },
        Expr::Binary {
            op,
            op_class,
            left,
            right,
        } => Expr::Binary {
            op: op.clone(),
            op_class: *op_class,
            left: Box::new(rewrite(left, cx, applied, cells)),
            right: Box::new(rewrite(right, cx, applied, cells)),
        },
        Expr::Ternary {
            cond,
            then_e,
            else_e,
        } => Expr::Ternary {
            cond: Box::new(rewrite(cond, cx, applied, cells)),
            then_e: Box::new(rewrite(then_e, cx, applied, cells)),
            else_e: Box::new(rewrite(else_e, cx, applied, cells)),
        },
        Expr::Concat { parts } => Expr::Concat {
            parts: parts
                .iter()
                .map(|p| rewrite(p, cx, applied, cells))
                .collect(),
        },
        Expr::Index { base, index } => Expr::Index {
            base: Box::new(rewrite(base, cx, applied, cells)),
            index: Box::new(rewrite(index, cx, applied, cells)),
        },
        other => other.clone(),
    };
    if let Some(r) = circular_compare(&rebuilt, cx) {
        applied.push(IdentityKind::CircularCompare);
        return r;
    }
    if let Some(r) = zero_detect_equality(&rebuilt) {
        applied.push(IdentityKind::ZeroDetectEquality);
        return r;
    }
    if let Some((r, c)) = push_select(&rebuilt, cx) {
        applied.push(IdentityKind::PushSelect);
        *cells += c;
        return r;
    }
    rebuilt
}

/// Recognize and price the identities on one combinational assignment.
///
/// Refuses when the RHS carries casts, comments, strings or macros (the
/// rewrite re-emits the whole RHS from the tree, which does not keep them),
/// when the tree does not round-trip, or when nothing applies.
pub fn detect(
    module: &TimingModule,
    node: &IrNode,
    resolver: &WidthResolver<'_>,
    model: &CostModel,
    arrivals: &Arrivals,
) -> Option<IdentityShape> {
    if !matches!(
        node.assign_kind,
        AssignKind::Continuous | AssignKind::Blocking
    ) {
        return None;
    }
    let lhs_text = node.lhs.as_deref()?.trim().to_string();
    let rhs_text = node.rhs.as_deref()?.trim();
    if !rhs_text.is_ascii()
        || rhs_text.contains(['"', '\\', '`'])
        || rhs_text.contains("//")
        || rhs_text.contains("/*")
        || rhs_text.contains("'(")
    {
        return None;
    }
    let rhs = node.rhs_expr.as_ref()?;
    if rhs.is_opaque() || contains_opaque(rhs) {
        return None;
    }
    // Round trip: the tree must describe the text it was parsed from.
    if Expr::parse(&rhs.emit()) != *rhs {
        return None;
    }
    let cx = Ctx {
        module,
        resolver,
        arrivals,
        model,
        node_width: resolver.expr_width(rhs).or(if node.width_defaulted {
            None
        } else {
            Some(node.width)
        }),
    };
    let mut applied = Vec::new();
    let mut cells = 0.0;
    let after = rewrite(rhs, &cx, &mut applied, &mut cells);
    let kind = *applied.first()?;
    let fo4_before = arrivals.cost(rhs, model);
    let fo4_after = arrivals.cost(&after, model);
    if fo4_after + 1e-6 >= fo4_before {
        return None;
    }
    let rhs_after = after.emit();
    if Expr::parse(&rhs_after) != after {
        return None;
    }
    Some(IdentityShape {
        kind,
        kinds: applied,
        lhs_text,
        rhs_before: rhs_text.to_string(),
        rhs_after,
        expr_after: after,
        fo4_before,
        fo4_after,
        est_cells: cells,
    })
}

/// Recognize and price the identities on one `if` predicate (A122): the
/// comparisons of this codebase mostly guard assignments rather than feed an
/// RHS. The shape's `lhs_text` is `if` and `rhs_*` hold the predicate text.
/// Only a single-line predicate is offered (the emitter replaces its span
/// in place and keeps every other line number).
pub fn detect_guard(
    module: &TimingModule,
    site: &crate::ir::GuardSite,
    resolver: &WidthResolver<'_>,
    model: &CostModel,
    arrivals: &Arrivals,
) -> Option<IdentityShape> {
    if site.loc.start_line == 0 || site.loc.end_line != site.loc.start_line {
        return None;
    }
    let text = site.text.trim();
    if !text.is_ascii()
        || text.contains(['"', '\\', '`'])
        || text.contains("//")
        || text.contains("/*")
        || text.contains("'(")
    {
        return None;
    }
    let e = Expr::parse(text);
    if e.is_opaque() || contains_opaque(&e) || Expr::parse(&e.emit()) != e {
        return None;
    }
    let cx = Ctx {
        module,
        resolver,
        arrivals,
        model,
        node_width: resolver.expr_width(&e),
    };
    let mut applied = Vec::new();
    let mut cells = 0.0;
    let after = rewrite(&e, &cx, &mut applied, &mut cells);
    let kind = *applied.first()?;
    let fo4_before = arrivals.cost(&e, model);
    let fo4_after = arrivals.cost(&after, model);
    if fo4_after + 1e-6 >= fo4_before {
        return None;
    }
    let rhs_after = after.emit();
    if Expr::parse(&rhs_after) != after {
        return None;
    }
    Some(IdentityShape {
        kind,
        kinds: applied,
        lhs_text: "if".into(),
        rhs_before: text.to_string(),
        rhs_after,
        expr_after: after,
        fo4_before,
        fo4_after,
        est_cells: cells,
    })
}

fn contains_opaque(e: &Expr) -> bool {
    let mut found = false;
    fn walk(e: &Expr, found: &mut bool) {
        match e {
            Expr::Opaque { .. } => *found = true,
            Expr::Unary { arg, .. } => walk(arg, found),
            Expr::Binary { left, right, .. } | Expr::PartSelect { left, right, .. } => {
                walk(left, found);
                walk(right, found);
            }
            Expr::Ternary {
                cond,
                then_e,
                else_e,
            } => {
                walk(cond, found);
                walk(then_e, found);
                walk(else_e, found);
            }
            Expr::Concat { parts } => parts.iter().for_each(|p| walk(p, found)),
            Expr::Replicate { count, body } => {
                walk(count, found);
                walk(body, found);
            }
            Expr::Index { base, index } => {
                walk(base, found);
                walk(index, found);
            }
            Expr::Call { args, .. } => args.iter().for_each(|a| walk(a, found)),
            Expr::Ident { .. } | Expr::Literal { .. } => {}
        }
    }
    walk(e, &mut found);
    found
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ir::DeclSite;
    use crate::loc::SourceLoc;

    fn decl(name: &str, ty: &str, packed: &str) -> DeclSite {
        DeclSite {
            name: name.into(),
            type_name: ty.into(),
            packed_text: packed.into(),
            unpacked_text: String::new(),
            loc: SourceLoc::file_start("m.sv"),
            block_local: false,
            scope: None,
            loop_var: false,
        }
    }

    fn module_with(
        decls: Vec<DeclSite>,
        nodes: Vec<(&str, &str, AssignKind, f64)>,
    ) -> TimingModule {
        let mut m = TimingModule {
            id: 0,
            name: "m".into(),
            file: "m.sv".into(),
            nodes: BTreeMap::new(),
            regions: BTreeMap::new(),
            localparams: vec![],
            parameters: vec![],
            ports: vec![],
            gen_loops: vec![],
            functions: vec![],
            function_bodies: vec![],
            package_imports: vec![],
            instances: vec![],
            decls,
            const_exprs: Default::default(),
            typedef_texts: Default::default(),
            config_branch: false,
            guards: Default::default(),
            onehot_facts: Default::default(),
            guard_sites: Default::default(),
            loc: SourceLoc::file_start("m.sv"),
        };
        for (i, (lhs, rhs, kind, cost)) in nodes.into_iter().enumerate() {
            let id = i as u32;
            m.nodes.insert(
                id,
                IrNode {
                    id,
                    op_class: None,
                    width: 1,
                    fo4_cost: cost,
                    gate: None,
                    loc: SourceLoc::file_start("m.sv"),
                    fans_in: vec![],
                    fans_out: vec![],
                    width_defaulted: true,
                    reads_reg: false,
                    lhs: Some(lhs.into()),
                    rhs: Some(rhs.into()),
                    rhs_expr: Some(Expr::parse(rhs)),
                    lhs_expr: Some(Expr::parse(lhs)),
                    case_labels: vec![],
                    case_is_default: false,
                    case_selector: None,
                    fo4_locked: false,
                    assign_kind: kind,
                },
            );
        }
        m
    }

    fn resolver<'a>(
        m: &'a TimingModule,
        pk: &'a BTreeMap<String, crate::ir::TimingPackage>,
        pi: &'a BTreeMap<String, i64>,
    ) -> WidthResolver<'a> {
        WidthResolver::new(m, pk, pi)
    }

    #[test]
    fn circular_compare_is_three_plain_compares_for_unsigned_tags() {
        let m = module_with(
            vec![
                decl("a", "logic", "[3:0]"),
                decl("b", "logic", "[3:0]"),
                decl("h", "logic", "[3:0]"),
            ],
            vec![("older", "(a - h) < (b - h)", AssignKind::Continuous, 0.0)],
        );
        let (pk, pi) = (BTreeMap::new(), BTreeMap::new());
        let r = resolver(&m, &pk, &pi);
        let model = CostModel::default();
        let arr = Arrivals::of(&m, &BTreeSet::new(), &model);
        let s = detect(&m, &m.nodes[&0], &r, &model, &arr).expect("shape");
        assert_eq!(s.kind, IdentityKind::CircularCompare);
        assert_eq!(s.rhs_after, "((a < b) ^ (a < h)) ^ (b < h)");
        assert!(s.gain() > 0.0 && s.est_cells == 0.0);
        // exhaustive truth check of the identity at 4 bits
        for a in 0u32..16 {
            for b in 0u32..16 {
                for h in 0u32..16 {
                    let lhs = (a.wrapping_sub(h) & 15) < (b.wrapping_sub(h) & 15);
                    let rhs = (a < b) ^ (a < h) ^ (b < h);
                    assert_eq!(lhs, rhs, "a={a} b={b} h={h}");
                    let le = (a.wrapping_sub(h) & 15) <= (b.wrapping_sub(h) & 15);
                    assert_eq!(le, (a <= b) ^ (a < h) ^ (b < h));
                }
            }
        }
    }

    #[test]
    fn circular_compare_refuses_signed_and_wrapping_operands() {
        let m = module_with(
            vec![
                decl("a", "logic signed", "[3:0]"),
                decl("b", "logic", "[3:0]"),
                decl("h", "logic", "[3:0]"),
            ],
            vec![("older", "(a - h) < (b - h)", AssignKind::Continuous, 0.0)],
        );
        let (pk, pi) = (BTreeMap::new(), BTreeMap::new());
        let model = CostModel::default();
        assert!(detect(
            &m,
            &m.nodes[&0],
            &resolver(&m, &pk, &pi),
            &model,
            &Arrivals::default()
        )
        .is_none());
        // unequal widths with arithmetic inside an operand: a different wrap
        let m = module_with(
            vec![
                decl("a", "logic", "[3:0]"),
                decl("b", "logic", "[3:0]"),
                decl("h", "logic", "[7:0]"),
            ],
            vec![(
                "older",
                "(a + 1 - h) < (b - h)",
                AssignKind::Continuous,
                0.0,
            )],
        );
        assert!(detect(
            &m,
            &m.nodes[&0],
            &resolver(&m, &pk, &pi),
            &model,
            &Arrivals::default()
        )
        .is_none());
        // unknown leaf type
        let m = module_with(
            vec![],
            vec![("older", "(a - h) < (b - h)", AssignKind::Continuous, 0.0)],
        );
        assert!(detect(
            &m,
            &m.nodes[&0],
            &resolver(&m, &pk, &pi),
            &model,
            &Arrivals::default()
        )
        .is_none());
    }

    #[test]
    fn zero_detect_forms_become_equality() {
        let cases = [
            ("(a - b) == 0", "a == b"),
            ("(a - b) != '0", "a != b"),
            ("0 == (a - b)", "a == b"),
            ("!(a - b)", "a == b"),
            ("~|(a - b)", "a == b"),
            ("|(a - b)", "a != b"),
            ("((a - b) == 0) & en", "(a == b) & en"),
            ("|(a - (b ^ {8'b0, c}))", "a != (b ^ {8'b0, c})"),
        ];
        let (pk, pi) = (BTreeMap::new(), BTreeMap::new());
        let model = CostModel::default();
        for (from, to) in cases {
            let m = module_with(
                vec![decl("a", "logic", "[7:0]"), decl("b", "logic", "[7:0]")],
                vec![("eq", from, AssignKind::Blocking, 0.0)],
            );
            let s = detect(
                &m,
                &m.nodes[&0],
                &resolver(&m, &pk, &pi),
                &model,
                &Arrivals::default(),
            )
            .unwrap_or_else(|| panic!("{from}"));
            assert_eq!(s.kind, IdentityKind::ZeroDetectEquality);
            assert_eq!(s.rhs_after, to, "{from}");
        }
        // an operand that wraps itself is left alone; so is `a + b == 0`
        for from in ["(a + c - b) == 0", "(a + b) == 0", "(a - b) == 1"] {
            let m = module_with(vec![], vec![("eq", from, AssignKind::Blocking, 0.0)]);
            assert!(
                detect(
                    &m,
                    &m.nodes[&0],
                    &resolver(&m, &pk, &pi),
                    &model,
                    &Arrivals::default()
                )
                .is_none(),
                "{from}"
            );
        }
    }

    #[test]
    fn push_select_fires_only_for_a_late_condition_and_prices_the_extra_adder() {
        let (pk, pi) = (BTreeMap::new(), BTreeMap::new());
        let model = CostModel::default();
        // `taken` is a deep comb cone; pc/imm_a/imm_b are flops (arrival 0)
        let m = module_with(
            vec![
                decl("pc", "logic", "[63:0]"),
                decl("imm_a", "logic", "[63:0]"),
                decl("imm_b", "logic", "[63:0]"),
                decl("taken", "logic", ""),
            ],
            vec![
                (
                    "taken",
                    "(x0 & x1) | (x2 & x3) | (x4 == x5)",
                    AssignKind::Continuous,
                    9.0,
                ),
                (
                    "tgt",
                    "pc + (taken ? imm_a : imm_b)",
                    AssignKind::Continuous,
                    0.0,
                ),
            ],
        );
        let regs: BTreeSet<String> = ["pc", "imm_a", "imm_b"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        let arr = Arrivals::of(&m, &regs, &model);
        assert!(arr.get("taken") >= 9.0);
        let s = detect(&m, &m.nodes[&1], &resolver(&m, &pk, &pi), &model, &arr).expect("shape");
        assert_eq!(s.kind, IdentityKind::PushSelect);
        assert_eq!(s.rhs_after, "taken ? (pc + imm_a) : (pc + imm_b)");
        assert_eq!(s.est_cells, 64.0);
        assert!(s.gain() > 0.0);
        // an early condition: nothing to gain, nothing rewritten
        let m2 = module_with(
            vec![
                decl("pc", "logic", "[63:0]"),
                decl("imm_a", "logic", "[63:0]"),
                decl("imm_b", "logic", "[63:0]"),
                decl("taken", "logic", ""),
            ],
            vec![(
                "tgt",
                "pc + (taken ? imm_a : imm_b)",
                AssignKind::Continuous,
                0.0,
            )],
        );
        let regs2: BTreeSet<String> = ["pc", "imm_a", "imm_b", "taken"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        assert!(detect(
            &m2,
            &m2.nodes[&0],
            &resolver(&m2, &pk, &pi),
            &model,
            &Arrivals::of(&m2, &regs2, &model)
        )
        .is_none());
    }

    #[test]
    fn casts_comments_and_opaque_text_are_refused() {
        let (pk, pi) = (BTreeMap::new(), BTreeMap::new());
        let model = CostModel::default();
        for from in [
            "4'(a - h) < 4'(b - h)",
            "(a - b) == 0 /* c */",
            "(a - b) == `ZERO",
        ] {
            let m = module_with(
                vec![
                    decl("a", "logic", "[3:0]"),
                    decl("b", "logic", "[3:0]"),
                    decl("h", "logic", "[3:0]"),
                ],
                vec![("y", from, AssignKind::Continuous, 0.0)],
            );
            assert!(
                detect(
                    &m,
                    &m.nodes[&0],
                    &resolver(&m, &pk, &pi),
                    &model,
                    &Arrivals::default()
                )
                .is_none(),
                "{from}"
            );
        }
    }
}
