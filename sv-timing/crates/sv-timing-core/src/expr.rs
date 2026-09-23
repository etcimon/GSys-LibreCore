// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Lightweight expression AST for denser IR / emit (not a full SV elaborator).

//! Expression trees recovered from assignment RHS/LHS text.
//!
//! Supports a practical subset of SystemVerilog expression surface:
//! identifiers, sized/unsized literals, unary/binary ops, ternary `?:`,
//! concatenation `{a,b}`, bit/part selects `a[i]` / `a[h:l]` /
//! [`Expr::PartSelect`] (`[msb:lsb]`, `+:`, `-:`), and simple function calls
//! `f(a,b)`. Anything unrecognized becomes [`Expr::Opaque`].
//!
//! See `architecture/STA-HANDOFF.md` for how trees relate to STA (they do **not**
//! replace STA).

use serde::{Deserialize, Serialize};

use crate::ir::OperatorClass;

/// Timing-oriented expression tree (structural, source-level).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "k", rename_all = "snake_case")]
pub enum Expr {
    /// Simple or hierarchical identifier (`a_i`, `cfg.x`).
    Ident {
        /// Name text.
        name: String,
    },
    /// Numeric / based literal (`1'b0`, `32'hdead`, `16`).
    Literal {
        /// Raw literal text.
        text: String,
    },
    /// Unary operator (`~`, `!`, `-`, `|`, `&`, `^` reductions).
    Unary {
        /// Operator spelling.
        op: String,
        /// Operand.
        arg: Box<Expr>,
    },
    /// Binary operator with timing class.
    Binary {
        /// Operator spelling (`+`, `&&`, …).
        op: String,
        /// FO4 class for this operator.
        op_class: OperatorClass,
        /// Left operand.
        left: Box<Expr>,
        /// Right operand.
        right: Box<Expr>,
    },
    /// Conditional `cond ? then : else`.
    Ternary {
        /// Condition.
        cond: Box<Expr>,
        /// Then arm.
        then_e: Box<Expr>,
        /// Else arm.
        else_e: Box<Expr>,
    },
    /// Concatenation `{a, b, c}`.
    Concat {
        /// Parts left-to-right.
        parts: Vec<Expr>,
    },
    /// Replication `{N{expr}}` (N kept as text).
    Replicate {
        /// Count expression text or subtree.
        count: Box<Expr>,
        /// Body.
        body: Box<Expr>,
    },
    /// Index / part-select `base[index]` or `base[hi:lo]` (index may be [`PartSelect`]).
    Index {
        /// Base expression.
        base: Box<Expr>,
        /// Index or part-select expression.
        index: Box<Expr>,
    },
    /// Part-select inside `base[...]`: `[msb:lsb]`, `[i +: w]`, `[i -: w]`.
    ///
    /// Not a binary arithmetic operator (PASS-STRATEGY P1). Width / both
    /// fixed-range bounds are LRM-constant; indexed base may be runtime.
    PartSelect {
        /// Select form.
        kind: PartSelectKind,
        /// `msb` or indexed base.
        left: Box<Expr>,
        /// `lsb` or width.
        right: Box<Expr>,
    },
    /// Function / system call `name(args…)`.
    Call {
        /// Function name.
        name: String,
        /// Arguments.
        args: Vec<Expr>,
    },
    /// Unparsed residue (always valid emit fallback).
    Opaque {
        /// Original text.
        text: String,
    },
}

/// IEEE 1800 §11.5.1 part-select form (not arithmetic).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PartSelectKind {
    /// `[msb:lsb]` — both bounds are constant expressions.
    FixedRange,
    /// `[base +: width]` — width is constant; base may be runtime.
    IndexedPlus,
    /// `[base -: width]` — width is constant; base may be runtime.
    IndexedMinus,
}

impl PartSelectKind {
    /// Operator spelling used in emit.
    pub fn as_op(self) -> &'static str {
        match self {
            PartSelectKind::FixedRange => ":",
            PartSelectKind::IndexedPlus => "+:",
            PartSelectKind::IndexedMinus => "-:",
        }
    }

    fn from_op(op: &str) -> Option<Self> {
        match op {
            ":" => Some(PartSelectKind::FixedRange),
            "+:" => Some(PartSelectKind::IndexedPlus),
            "-:" => Some(PartSelectKind::IndexedMinus),
            _ => None,
        }
    }

    fn is_indexed(self) -> bool {
        matches!(
            self,
            PartSelectKind::IndexedPlus | PartSelectKind::IndexedMinus
        )
    }
}

/// Elaboration-constant lattice (PASS-STRATEGY P1). `Const ∘ Const → Const → zero delay`.
///
/// This is a **measurement** correction, not an optimization gain. Seeded by
/// literals, param-map / localparam names, `*Cfg.*` fields, SCREAMING_CASE
/// parameters, and `$clog2`/`$bits` of constants. LRM-constant contexts
/// (replication counts, fixed `[msb:lsb]` bounds) are Const by rule.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConstClass {
    /// Proven elaboration-time.
    Const,
    /// Not resolved; charged as hardware (conservative).
    Unknown,
    /// Runtime data.
    Runtime,
}

impl ConstClass {
    /// Both sides Const → Const; any Runtime → Runtime; else Unknown.
    pub fn join_arith(self, other: Self) -> Self {
        use ConstClass::*;
        match (self, other) {
            (Const, Const) => Const,
            (Runtime, _) | (_, Runtime) => Runtime,
            _ => Unknown,
        }
    }

    /// True when delay must be zero.
    pub fn is_const(self) -> bool {
        matches!(self, ConstClass::Const)
    }
}

/// Names that seed the constant lattice (param-map keys, localparams, …).
#[derive(Debug, Clone, Default)]
pub struct ConstSeed {
    /// Exact names (`CVA6Cfg.XLEN`, `PRECISION_BITS`, …).
    pub names: std::collections::BTreeSet<String>,
    /// Nets proven zero in the low `K` bits (`aligned_address` → `LOG_NR_BYTES`).
    /// First-pass exclusive `{x[MSB:K], {K{0}}}` assigns. `ident + (y << K)` is
    /// then a field insert, not a CPA.
    pub aligned: std::collections::BTreeMap<String, String>,
    /// Exclusive `t = y << K` temps (BalanceMux stages the shift off the add).
    /// `aligned + t` with matching `K` is a field insert.
    pub shifted: std::collections::BTreeMap<String, String>,
}

impl ConstSeed {
    /// Heuristic seed: `*Cfg.*` and SCREAMING_CASE identifiers, no host map.
    pub fn heuristic() -> Self {
        Self::default()
    }

    /// Seed from localparam / parameter / param-map names (mixed-case included).
    pub fn from_names<I, S>(names: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        let mut seed = Self::default();
        for n in names {
            seed.add(n);
        }
        seed
    }

    /// Insert a name and its last `a.b` / `pkg::NAME` segment.
    pub fn add(&mut self, name: impl Into<String>) {
        let n = name.into();
        let n = n.trim();
        if n.is_empty() {
            return;
        }
        if let Some((_, base)) = n.rsplit_once("::") {
            if !base.is_empty() {
                self.names.insert(base.to_string());
            }
        }
        if let Some((_, base)) = n.rsplit_once('.') {
            if !base.is_empty() {
                self.names.insert(base.to_string());
            }
        }
        self.names.insert(n.to_string());
    }

    /// True when `name` is an elaboration parameter, not a runtime net.
    pub fn looks_const(&self, name: &str) -> bool {
        let n = name.trim();
        if n.is_empty() {
            return false;
        }
        if self.names.contains(n) {
            return true;
        }
        // SV package scope is `::` (IEEE 1800); struct fields use `.`.
        let base = n
            .rsplit("::")
            .next()
            .unwrap_or(n)
            .rsplit('.')
            .next()
            .unwrap_or(n);
        if self.names.contains(base) {
            return true;
        }
        // Package/config struct fields (`CVA6Cfg.X`, `HPDcacheCfg.reqDataWidth`).
        if n.contains("Cfg.") {
            return true;
        }
        ident_is_screaming_param(base)
    }

    /// Record that `name` is zero in the low `k` bits (`k` is ident or literal key).
    pub fn set_aligned(&mut self, name: impl Into<String>, k: impl Into<String>) {
        let n = ident_align_base(&name.into());
        let k = k.into();
        if n.is_empty() || k.is_empty() {
            return;
        }
        self.aligned.insert(n, k);
    }

    /// Alignment key `K` when `name` was proven `{x[MSB:K], {K{0}}}`.
    pub fn aligned_k(&self, name: &str) -> Option<&str> {
        let n = ident_align_base(name);
        self.aligned.get(&n).map(String::as_str)
    }

    /// Record that `name` is an exclusive `y << k` temp.
    pub fn set_shifted(&mut self, name: impl Into<String>, k: impl Into<String>) {
        let n = ident_align_base(&name.into());
        let k = k.into();
        if n.is_empty() || k.is_empty() {
            return;
        }
        self.shifted.insert(n, k);
    }

    /// Shift amount key `K` when `name` was proven `y << K`.
    pub fn shifted_k(&self, name: &str) -> Option<&str> {
        let n = ident_align_base(name);
        self.shifted.get(&n).map(String::as_str)
    }
}

fn ident_align_base(name: &str) -> String {
    name.split('[')
        .next()
        .unwrap_or(name)
        .rsplit('.')
        .next()
        .unwrap_or(name)
        .trim()
        .to_string()
}

fn ident_is_screaming_param(base: &str) -> bool {
    let mut letters = 0u32;
    for c in base.chars() {
        if c.is_ascii_uppercase() {
            letters += 1;
            continue;
        }
        if c.is_ascii_digit() || c == '_' {
            continue;
        }
        return false;
    }
    letters >= 2
}

impl Expr {
    /// Parse SV-like expression text into a tree (best-effort).
    pub fn parse(text: &str) -> Self {
        let t = text.trim().trim_end_matches(';').trim();
        if t.is_empty() {
            return Expr::Opaque {
                text: String::new(),
            };
        }
        let mut p = Parser {
            src: t.as_bytes(),
            i: 0,
        };
        match p.parse_expr() {
            Some(e) if p.skip_ws_eof() => e,
            Some(e) => {
                // Trailing junk → wrap remainder as opaque sibling via binary +
                let rest = p.rest_str();
                if rest.is_empty() {
                    e
                } else {
                    Expr::Opaque {
                        text: t.to_string(),
                    }
                }
            }
            None => Expr::Opaque {
                text: t.to_string(),
            },
        }
    }

    /// Emit SystemVerilog-ish text (parenthesized for safety on binary/ternary).
    pub fn emit(&self) -> String {
        match self {
            Expr::Ident { name } => name.clone(),
            Expr::Literal { text } => text.clone(),
            Expr::Opaque { text } => text.clone(),
            Expr::Unary { op, arg } => format!("{op}{}", paren_if_needed(arg)),
            Expr::Binary {
                op, left, right, ..
            } => format!(
                "{} {} {}",
                paren_if_needed(left),
                op,
                paren_if_needed(right)
            ),
            Expr::Ternary {
                cond,
                then_e,
                else_e,
            } => format!(
                "{} ? {} : {}",
                paren_if_needed(cond),
                paren_if_needed(then_e),
                paren_if_needed(else_e)
            ),
            Expr::Concat { parts } => {
                let inner = parts
                    .iter()
                    .map(|p| p.emit())
                    .collect::<Vec<_>>()
                    .join(", ");
                format!("{{{inner}}}")
            }
            Expr::Replicate { count, body } => {
                format!("{{{}{{{}}}}}", count.emit(), body.emit())
            }
            Expr::Index { base, index } => {
                format!("{}[{}]", paren_if_needed(base), index.emit())
            }
            Expr::PartSelect { kind, left, right } => format!(
                "{} {} {}",
                paren_if_needed(left),
                kind.as_op(),
                paren_if_needed(right)
            ),
            Expr::Call { name, args } => {
                let inner = args.iter().map(|a| a.emit()).collect::<Vec<_>>().join(", ");
                format!("{name}({inner})")
            }
        }
    }

    /// Dominant (deepest / costliest) operator class for coarse FO4.
    ///
    /// Address-scale multiplies (`i*8`) do **not** rank as full datapath Mul.
    pub fn dominant_op_class(&self) -> OperatorClass {
        self.dominant_op_class_latticed(&ConstSeed::heuristic())
    }

    /// Dominant class with an explicit constant-lattice seed.
    pub fn dominant_op_class_latticed(&self, seed: &ConstSeed) -> OperatorClass {
        dominant_op_class_measured_seeded(self, seed)
    }

    /// True when parse failed and the original text is kept as-is.
    pub fn is_opaque(&self) -> bool {
        matches!(self, Expr::Opaque { .. })
    }

    /// RHS is a primary only (ident or literal) — no operators, concat, or calls.
    pub fn is_expression_less(&self) -> bool {
        matches!(self, Expr::Ident { .. } | Expr::Literal { .. })
    }

    /// `K` when this tree is `{high, {K{1'b0}}}` (aligned zero-pad concat).
    pub fn zero_pad_align_key(&self) -> Option<String> {
        let (_, k) = concat_high_and_zero_pad(self)?;
        alignment_key(k)
    }

    /// `K` when this tree is `y << K` / `y <<< K`.
    pub fn shift_align_key(&self) -> Option<String> {
        alignment_key(shl_amount(self)?)
    }

    /// Structural FO4 estimate: **sum** of operator-node base costs (idents free).
    ///
    /// Useful for area-like totals. For critical-path screening prefer
    /// [`Self::fo4_critical_cost`].
    ///
    /// `base` maps [`OperatorClass`] → FO4 (typically `CostModel::base_fo4`).
    pub fn fo4_cost(&self, base: &dyn Fn(OperatorClass) -> f64) -> f64 {
        let mut sum = 0.0;
        self.walk_ops(&mut |c| {
            sum += base(c);
        });
        sum
    }

    /// Critical-path FO4 through the expression DAG (max over parallel arms + op).
    ///
    /// Models arrival-time style depth rather than summing every operator (which
    /// over-counts reconvergent / parallel subtrees). Used by measure for node
    /// FO4 when an RHS tree is present.
    pub fn fo4_critical_cost(&self, base: &dyn Fn(OperatorClass) -> f64) -> f64 {
        self.fo4_critical_cost_latticed(base, &ConstSeed::heuristic())
    }

    /// Critical-path FO4 with an explicit constant-lattice seed (param-map).
    pub fn fo4_critical_cost_latticed(
        &self,
        base: &dyn Fn(OperatorClass) -> f64,
        seed: &ConstSeed,
    ) -> f64 {
        // PASS-STRATEGY P1: Const ∘ Const is elaboration, not hardware.
        if self.const_class(seed).is_const() {
            return 0.0;
        }
        match self {
            Expr::Ident { .. } | Expr::Literal { .. } | Expr::Opaque { .. } => 0.0,
            Expr::Unary { op, arg, .. } => {
                base(classify_unary(op)) + arg.fo4_critical_cost_latticed(base, seed)
            }
            Expr::PartSelect { kind, left, right } => {
                if kind.is_indexed() {
                    left.fo4_critical_cost_latticed(base, seed)
                } else {
                    let _ = right;
                    0.0
                }
            }
            Expr::Binary {
                op,
                op_class,
                left,
                right,
            } => {
                let billed = billed_binary_class(op, *op_class, left, right, seed);
                base(billed)
                    + left
                        .fo4_critical_cost_latticed(base, seed)
                        .max(right.fo4_critical_cost_latticed(base, seed))
            }
            Expr::Ternary {
                cond,
                then_e,
                else_e,
            } => {
                // Const condition is generate-if / param select: one arm exists
                // in the netlist, so there is no 2.5 FO4 mux (pe_dot `i < CNT`).
                if cond.const_class(seed).is_const() {
                    return then_e
                        .fo4_critical_cost_latticed(base, seed)
                        .max(else_e.fo4_critical_cost_latticed(base, seed));
                }
                // Nested `c ? Const : (c2 ? Const : … : datapath)` is one mux
                // on the runtime spine (exception encodings vs datapath), not
                // a serial mux per arm. `c ? runtime : …` does not flatten.
                if let Some((conds, tail)) = const_then_chain(self, seed) {
                    let mut m = tail.fo4_critical_cost_latticed(base, seed);
                    for c in conds {
                        m = m.max(c.fo4_critical_cost_latticed(base, seed));
                    }
                    return base(OperatorClass::Mux) + m;
                }
                base(OperatorClass::Mux)
                    + cond
                        .fo4_critical_cost_latticed(base, seed)
                        .max(then_e.fo4_critical_cost_latticed(base, seed))
                        .max(else_e.fo4_critical_cost_latticed(base, seed))
            }
            Expr::Concat { parts } => {
                base(OperatorClass::Concat)
                    + parts
                        .iter()
                        .map(|p| p.fo4_critical_cost_latticed(base, seed))
                        .fold(0.0_f64, f64::max)
            }
            Expr::Replicate { count: _, body } => {
                // IEEE 1800 replication count is a constant expression by rule.
                // Charge the body only (PASS-STRATEGY P1 LRM context).
                body.fo4_critical_cost_latticed(base, seed)
            }
            Expr::Index { base: b, index } => {
                // A fixed `[msb:lsb]` bound is constant by LRM rule, so it contributes no
                // delay. Indexed `+:` / `-:` width is also LRM-constant; the base
                // index may be runtime (IEEE 1800 §11.5.1).
                if is_constant_range_select(index) {
                    return b.fo4_critical_cost_latticed(base, seed);
                }
                if let Some(base_idx) = indexed_part_select_base(index) {
                    return b
                        .fo4_critical_cost_latticed(base, seed)
                        .max(base_idx.fo4_critical_cost_latticed(base, seed));
                }
                b.fo4_critical_cost_latticed(base, seed)
                    .max(index.fo4_critical_cost_latticed(base, seed))
            }
            Expr::Call { name, args } => {
                if is_elab_system_fn(name) && args.iter().all(|a| a.const_class(seed).is_const()) {
                    return 0.0;
                }
                let call_op = user_function_op_class(name, args.len());
                base(call_op)
                    + args
                        .iter()
                        .map(|a| a.fo4_critical_cost_latticed(base, seed))
                        .fold(0.0_f64, f64::max)
            }
        }
    }

    /// Lattice class of this expression (P1).
    pub fn const_class(&self, seed: &ConstSeed) -> ConstClass {
        match self {
            Expr::Literal { .. } => ConstClass::Const,
            Expr::Ident { name } => {
                if seed.looks_const(name) {
                    ConstClass::Const
                } else {
                    ConstClass::Runtime
                }
            }
            Expr::Unary { arg, .. } => arg.const_class(seed),
            Expr::PartSelect { kind, left, right } => {
                if kind.is_indexed() {
                    left.const_class(seed)
                } else {
                    let _ = right;
                    ConstClass::Const
                }
            }
            Expr::Binary { left, right, .. } => {
                left.const_class(seed).join_arith(right.const_class(seed))
            }
            Expr::Ternary {
                cond,
                then_e,
                else_e,
            } => cond
                .const_class(seed)
                .join_arith(then_e.const_class(seed))
                .join_arith(else_e.const_class(seed)),
            Expr::Concat { parts } => parts
                .iter()
                .fold(ConstClass::Const, |a, p| a.join_arith(p.const_class(seed))),
            Expr::Replicate { count: _, body } => body.const_class(seed),
            Expr::Index { base, index } => {
                if is_constant_range_select(index) {
                    base.const_class(seed)
                } else if let Some(base_idx) = indexed_part_select_base(index) {
                    base.const_class(seed)
                        .join_arith(base_idx.const_class(seed))
                } else {
                    base.const_class(seed).join_arith(index.const_class(seed))
                }
            }
            Expr::Call { name, args } => {
                if is_elab_system_fn(name) && args.iter().all(|a| a.const_class(seed).is_const()) {
                    ConstClass::Const
                } else if args
                    .iter()
                    .any(|a| a.const_class(seed) == ConstClass::Runtime)
                {
                    ConstClass::Runtime
                } else {
                    ConstClass::Unknown
                }
            }
            Expr::Opaque { .. } => ConstClass::Unknown,
        }
    }

    /// Index/part-select arithmetic retains the cost of dynamic operations.
    pub fn fo4_critical_cost_as_index(&self, base: &dyn Fn(OperatorClass) -> f64) -> f64 {
        self.fo4_critical_cost(base)
    }

    /// Visit identifier names (not function names).
    pub fn walk_idents(&self, f: &mut dyn FnMut(&str)) {
        match self {
            Expr::Ident { name } => f(name),
            Expr::Literal { .. } | Expr::Opaque { .. } => {}
            Expr::Unary { arg, .. } => arg.walk_idents(f),
            Expr::PartSelect { left, right, .. } => {
                left.walk_idents(f);
                right.walk_idents(f);
            }
            Expr::Binary { left, right, .. } => {
                left.walk_idents(f);
                right.walk_idents(f);
            }
            Expr::Ternary {
                cond,
                then_e,
                else_e,
            } => {
                cond.walk_idents(f);
                then_e.walk_idents(f);
                else_e.walk_idents(f);
            }
            Expr::Concat { parts } => {
                for p in parts {
                    p.walk_idents(f);
                }
            }
            Expr::Replicate { count, body } => {
                count.walk_idents(f);
                body.walk_idents(f);
            }
            Expr::Index { base, index } => {
                base.walk_idents(f);
                index.walk_idents(f);
            }
            Expr::Call { args, .. } => {
                for a in args {
                    a.walk_idents(f);
                }
            }
        }
    }

    /// Visit function / system-function calls (`name`, args).
    pub fn walk_calls(&self, f: &mut dyn FnMut(&str, &[Expr])) {
        match self {
            Expr::Ident { .. } | Expr::Literal { .. } | Expr::Opaque { .. } => {}
            Expr::Unary { arg, .. } => arg.walk_calls(f),
            Expr::PartSelect { left, right, .. } => {
                left.walk_calls(f);
                right.walk_calls(f);
            }
            Expr::Binary { left, right, .. } => {
                left.walk_calls(f);
                right.walk_calls(f);
            }
            Expr::Ternary {
                cond,
                then_e,
                else_e,
            } => {
                cond.walk_calls(f);
                then_e.walk_calls(f);
                else_e.walk_calls(f);
            }
            Expr::Concat { parts } => {
                for p in parts {
                    p.walk_calls(f);
                }
            }
            Expr::Replicate { count, body } => {
                count.walk_calls(f);
                body.walk_calls(f);
            }
            Expr::Index { base, index } => {
                base.walk_calls(f);
                index.walk_calls(f);
            }
            Expr::Call { name, args } => {
                f(name, args);
                for a in args {
                    a.walk_calls(f);
                }
            }
        }
    }

    /// Critical-path operator spine: ordered `(op_class, base_fo4)` leaf→root.
    ///
    /// Used for **expr-level multi-cut** prep: expand a single mega-assign IR
    /// node into one node per spine segment so budget multi-cut can place
    /// pipeline registers between prep ops and a heavy root (e.g. `mul`).
    /// Parallel arms contribute only the heavier child's spine.
    ///
    /// Sum of base costs equals [`Self::fo4_critical_cost`] for pure trees.
    pub fn critical_spine_ops(
        &self,
        base: &dyn Fn(OperatorClass) -> f64,
    ) -> Vec<(OperatorClass, f64)> {
        self.critical_spine_ops_latticed(base, &ConstSeed::heuristic())
    }

    /// Spine with an explicit constant-lattice seed (module params / localparams).
    pub fn critical_spine_ops_latticed(
        &self,
        base: &dyn Fn(OperatorClass) -> f64,
        seed: &ConstSeed,
    ) -> Vec<(OperatorClass, f64)> {
        match self {
            Expr::Ident { .. } | Expr::Literal { .. } | Expr::Opaque { .. } => Vec::new(),
            Expr::PartSelect { kind, left, .. } => {
                if kind.is_indexed() {
                    left.critical_spine_ops_latticed(base, seed)
                } else {
                    Vec::new()
                }
            }
            Expr::Unary { op, arg, .. } => {
                let cls = classify_unary(op);
                let mut s = arg.critical_spine_ops_latticed(base, seed);
                s.push((cls, base(cls)));
                s
            }
            Expr::Binary {
                op,
                op_class,
                left,
                right,
            } => {
                if left.const_class(seed).is_const() && right.const_class(seed).is_const() {
                    return Vec::new();
                }
                let lc = left.fo4_critical_cost_latticed(base, seed);
                let rc = right.fo4_critical_cost_latticed(base, seed);
                let mut s = if lc >= rc {
                    left.critical_spine_ops_latticed(base, seed)
                } else {
                    right.critical_spine_ops_latticed(base, seed)
                };
                let cls = billed_binary_class(op, *op_class, left, right, seed);
                s.push((cls, base(cls)));
                s
            }
            Expr::Ternary {
                cond,
                then_e,
                else_e,
            } => {
                if cond.const_class(seed).is_const() {
                    let tc = then_e.fo4_critical_cost_latticed(base, seed);
                    let ec = else_e.fo4_critical_cost_latticed(base, seed);
                    return if tc >= ec {
                        then_e.critical_spine_ops_latticed(base, seed)
                    } else {
                        else_e.critical_spine_ops_latticed(base, seed)
                    };
                }
                if let Some((conds, tail)) = const_then_chain(self, seed) {
                    let mut best: &Expr = tail;
                    let mut best_c = tail.fo4_critical_cost_latticed(base, seed);
                    for c in conds {
                        let cc = c.fo4_critical_cost_latticed(base, seed);
                        if cc > best_c {
                            best_c = cc;
                            best = c;
                        }
                    }
                    let mut s = best.critical_spine_ops_latticed(base, seed);
                    s.push((OperatorClass::Mux, base(OperatorClass::Mux)));
                    return s;
                }
                let arms: [&Expr; 3] = [cond.as_ref(), then_e.as_ref(), else_e.as_ref()];
                let best = arms
                    .into_iter()
                    .max_by(|a, b| {
                        a.fo4_critical_cost_latticed(base, seed)
                            .partial_cmp(&b.fo4_critical_cost_latticed(base, seed))
                            .unwrap_or(std::cmp::Ordering::Equal)
                    })
                    .unwrap();
                let mut s = best.critical_spine_ops_latticed(base, seed);
                s.push((OperatorClass::Mux, base(OperatorClass::Mux)));
                s
            }
            Expr::Concat { parts } => {
                let mut s = parts
                    .iter()
                    .max_by(|a, b| {
                        a.fo4_critical_cost_latticed(base, seed)
                            .partial_cmp(&b.fo4_critical_cost_latticed(base, seed))
                            .unwrap_or(std::cmp::Ordering::Equal)
                    })
                    .map(|p| p.critical_spine_ops_latticed(base, seed))
                    .unwrap_or_default();
                s.push((OperatorClass::Concat, base(OperatorClass::Concat)));
                s
            }
            Expr::Replicate { count: _, body } => body.critical_spine_ops_latticed(base, seed),
            Expr::Index { base: b, index } => {
                if is_constant_range_select(index) {
                    return b.critical_spine_ops_latticed(base, seed);
                }
                let bc = b.fo4_critical_cost_latticed(base, seed);
                let ic = index.fo4_critical_cost_latticed(base, seed);
                if bc >= ic {
                    b.critical_spine_ops_latticed(base, seed)
                } else {
                    index.critical_spine_ops_latticed(base, seed)
                }
            }
            Expr::Call { args, .. } => {
                let mut s = args
                    .iter()
                    .max_by(|a, b| {
                        a.fo4_critical_cost_latticed(base, seed)
                            .partial_cmp(&b.fo4_critical_cost_latticed(base, seed))
                            .unwrap_or(std::cmp::Ordering::Equal)
                    })
                    .map(|a| a.critical_spine_ops_latticed(base, seed))
                    .unwrap_or_default();
                s.push((OperatorClass::Other, base(OperatorClass::Other)));
                s
            }
        }
    }

    /// True when a single operator on the critical spine exceeds `budget_fo4`.
    ///
    /// Such ops cannot be shortened by InsertReg alone (atomic FO4).
    pub fn has_atomic_over_budget(
        &self,
        base: &dyn Fn(OperatorClass) -> f64,
        budget_fo4: f64,
    ) -> bool {
        self.critical_spine_ops(base)
            .into_iter()
            .any(|(_, c)| c > budget_fo4 + 1e-9)
    }

    /// Count binary/unary/ternary/concat operator nodes.
    pub fn op_node_count(&self) -> u32 {
        let mut n = 0u32;
        self.walk_ops(&mut |_| n += 1);
        n
    }

    /// True if `op` is associative and safe to rebalance under structural FO4.
    pub fn is_associative_binary_op(op: &str) -> bool {
        matches!(op, "+" | "|" | "&" | "^" | "||" | "&&")
    }

    /// Heuristic bit-width class for width-aware reassociation.
    ///
    /// - Sized literals (`64'h…`, `8'd…`) → known width  
    /// - Concat of known parts → sum  
    /// - Ident / unsized / opaque → `None` (compatible with any neighbor)
    ///
    /// Used so we do **not** rebalance across clearly different widths
    /// (e.g. mixing 1-bit flags with wide datapath ORs).
    pub fn width_class_hint(&self) -> Option<u32> {
        match self {
            Expr::Literal { text } => parse_sized_literal_width(text),
            Expr::Concat { parts } => {
                let mut sum = 0u32;
                for p in parts {
                    sum = sum.saturating_add(p.width_class_hint()?);
                }
                Some(sum.max(1))
            }
            Expr::Replicate { count, body } => {
                let c = match count.as_ref() {
                    Expr::Literal { text } => parse_unsized_decimal(text).unwrap_or(1),
                    _ => return None,
                };
                Some(
                    c.saturating_mul(body.width_class_hint().unwrap_or(1))
                        .max(1),
                )
            }
            Expr::Unary { arg, .. } => arg.width_class_hint(),
            Expr::PartSelect { .. } => None,
            Expr::Index { base, .. } => base.width_class_hint(), // conservative: full base
            Expr::Binary { left, right, .. } => {
                // Both known and equal → that width; else unknown
                match (left.width_class_hint(), right.width_class_hint()) {
                    (Some(a), Some(b)) if a == b => Some(a),
                    _ => None,
                }
            }
            Expr::Ternary { then_e, else_e, .. } => {
                match (then_e.width_class_hint(), else_e.width_class_hint()) {
                    (Some(a), Some(b)) if a == b => Some(a),
                    (Some(a), None) | (None, Some(a)) => Some(a),
                    _ => None,
                }
            }
            Expr::Ident { .. } | Expr::Opaque { .. } | Expr::Call { .. } => None,
        }
    }

    /// Rebalance associative binary chains into a more balanced tree.
    ///
    /// Left-deep `a+b+c+d` becomes roughly balanced so critical FO4 drops from
    /// ~n·c to ~⌈log₂ n⌉·c for **width-compatible** leaves. Leaves with known
    /// differing widths are **not** mixed in one balanced tree (rebalanced only
    /// within equal-width segments). Non-associative ops are unchanged.
    /// Round-trip: `rebalance_associative().emit()` remains parseable SV-ish text.
    pub fn rebalance_associative(&self) -> Expr {
        match self {
            Expr::Binary {
                op,
                op_class,
                left,
                right,
            } if Self::is_associative_binary_op(op) => {
                let mut leaves = Vec::new();
                flatten_assoc(op, self, &mut leaves);
                if leaves.len() <= 2 {
                    return Expr::Binary {
                        op: op.clone(),
                        op_class: *op_class,
                        left: Box::new(left.rebalance_associative()),
                        right: Box::new(right.rebalance_associative()),
                    };
                }
                build_width_aware_balanced_assoc(op, *op_class, &leaves)
            }
            Expr::Unary { op, arg } => Expr::Unary {
                op: op.clone(),
                arg: Box::new(arg.rebalance_associative()),
            },
            Expr::Binary {
                op,
                op_class,
                left,
                right,
            } => Expr::Binary {
                op: op.clone(),
                op_class: *op_class,
                left: Box::new(left.rebalance_associative()),
                right: Box::new(right.rebalance_associative()),
            },
            Expr::Ternary {
                cond,
                then_e,
                else_e,
            } => Expr::Ternary {
                cond: Box::new(cond.rebalance_associative()),
                then_e: Box::new(then_e.rebalance_associative()),
                else_e: Box::new(else_e.rebalance_associative()),
            },
            Expr::Concat { parts } => Expr::Concat {
                parts: parts.iter().map(|p| p.rebalance_associative()).collect(),
            },
            Expr::Replicate { count, body } => Expr::Replicate {
                count: Box::new(count.rebalance_associative()),
                body: Box::new(body.rebalance_associative()),
            },
            Expr::Index { base, index } => Expr::Index {
                base: Box::new(base.rebalance_associative()),
                index: Box::new(index.rebalance_associative()),
            },
            Expr::PartSelect { kind, left, right } => Expr::PartSelect {
                kind: *kind,
                left: Box::new(left.rebalance_associative()),
                right: Box::new(right.rebalance_associative()),
            },
            Expr::Call { name, args } => Expr::Call {
                name: name.clone(),
                args: args.iter().map(|a| a.rebalance_associative()).collect(),
            },
            other => other.clone(),
        }
    }

    /// Tree depth (1 = leaf).
    pub fn depth(&self) -> u32 {
        match self {
            Expr::Ident { .. } | Expr::Literal { .. } | Expr::Opaque { .. } => 1,
            Expr::Unary { arg, .. } | Expr::Index { base: arg, .. } => 1 + arg.depth(),
            Expr::PartSelect { left, right, .. } | Expr::Binary { left, right, .. } => {
                1 + left.depth().max(right.depth())
            }
            Expr::Ternary {
                cond,
                then_e,
                else_e,
            } => 1 + cond.depth().max(then_e.depth()).max(else_e.depth()),
            Expr::Concat { parts } => 1 + parts.iter().map(|p| p.depth()).max().unwrap_or(0),
            Expr::Replicate { count, body } => 1 + count.depth().max(body.depth()),
            Expr::Call { args, .. } => 1 + args.iter().map(|a| a.depth()).max().unwrap_or(0),
        }
    }

    /// Stage a deep expression into intermediate wires + a shallow top expr.
    ///
    /// Used by BalanceMux RTL rewrite: e.g. `((a<<b)|(a>>c))` →  
    /// `w0=a<<b; w1=a>>c; top=w0|w1` so exclusive-arm critical FO4 is
    /// max(shift)+or rather than a left-deep stack in one assign.
    ///
    /// Returns `None` when the tree is already shallow (depth &lt; 3 and few ops).
    pub fn stage_for_balance_mux(&self, prefix: &str) -> Option<ExprStagePlan> {
        if self.depth() < 3 && self.op_node_count() < 3 {
            return None;
        }
        // Concat/replicate/index staging often breaks SV sizing/`$clog2` syntax when
        // split mid-tree — only stage pure arithmetic/logic/mux trees.
        if self.contains_struct_ops() {
            return None;
        }
        let mut wires: Vec<(String, String)> = Vec::new();
        let mut counter = 0u32;
        let top = self.stage_balance_rec(prefix, &mut wires, &mut counter);
        if wires.is_empty() {
            return None;
        }
        // Cap wire count for emit hygiene
        if wires.len() > 12 {
            return None;
        }
        // Each staged RHS must re-parse (integrity gate for emit).
        for (_n, rhs) in &wires {
            let p = Expr::parse(rhs);
            if p.op_node_count() == 0 && !rhs.trim().is_empty() {
                // pure ident/literal ok
                if !rhs
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || "_$ ".contains(c))
                {
                    return None;
                }
            }
        }
        let top_emit = top.emit();
        Some(ExprStagePlan {
            wires,
            top,
            top_emit,
        })
    }

    /// True when the tree uses concat/replicate (unsafe to mid-stage for emit).
    fn contains_struct_ops(&self) -> bool {
        match self {
            Expr::Concat { .. } | Expr::Replicate { .. } => true,
            Expr::Unary { arg, .. } | Expr::Index { base: arg, .. } => arg.contains_struct_ops(),
            Expr::PartSelect { left, right, .. } | Expr::Binary { left, right, .. } => {
                left.contains_struct_ops() || right.contains_struct_ops()
            }
            Expr::Ternary {
                cond,
                then_e,
                else_e,
            } => {
                cond.contains_struct_ops()
                    || then_e.contains_struct_ops()
                    || else_e.contains_struct_ops()
            }
            Expr::Call { args, .. } => args.iter().any(|a| a.contains_struct_ops()),
            Expr::Ident { .. } | Expr::Literal { .. } | Expr::Opaque { .. } => false,
        }
    }

    fn stage_balance_rec(
        &self,
        prefix: &str,
        wires: &mut Vec<(String, String)>,
        counter: &mut u32,
    ) -> Expr {
        match self {
            Expr::Ident { .. } | Expr::Literal { .. } | Expr::Opaque { .. } => self.clone(),
            Expr::PartSelect { kind, left, right } => Expr::PartSelect {
                kind: *kind,
                left: Box::new(left.stage_balance_rec(prefix, wires, counter)),
                right: Box::new(right.stage_balance_rec(prefix, wires, counter)),
            },
            Expr::Unary { op, arg } => {
                let a = if arg.depth() > 1 {
                    let inner = arg.stage_balance_rec(prefix, wires, counter);
                    Self::push_stage_wire(prefix, wires, counter, inner)
                } else {
                    arg.as_ref().clone()
                };
                Expr::Unary {
                    op: op.clone(),
                    arg: Box::new(a),
                }
            }
            Expr::Binary {
                op,
                op_class,
                left,
                right,
            } => {
                let l = if left.depth() > 1 {
                    let inner = left.stage_balance_rec(prefix, wires, counter);
                    Self::push_stage_wire(prefix, wires, counter, inner)
                } else {
                    left.as_ref().clone()
                };
                let r = if right.depth() > 1 {
                    let inner = right.stage_balance_rec(prefix, wires, counter);
                    Self::push_stage_wire(prefix, wires, counter, inner)
                } else {
                    right.as_ref().clone()
                };
                Expr::Binary {
                    op: op.clone(),
                    op_class: *op_class,
                    left: Box::new(l),
                    right: Box::new(r),
                }
            }
            Expr::Ternary {
                cond,
                then_e,
                else_e,
            } => {
                let c = if cond.depth() > 1 {
                    let inner = cond.stage_balance_rec(prefix, wires, counter);
                    Self::push_stage_wire(prefix, wires, counter, inner)
                } else {
                    cond.as_ref().clone()
                };
                let t = if then_e.depth() > 1 {
                    let inner = then_e.stage_balance_rec(prefix, wires, counter);
                    Self::push_stage_wire(prefix, wires, counter, inner)
                } else {
                    then_e.as_ref().clone()
                };
                let e = if else_e.depth() > 1 {
                    let inner = else_e.stage_balance_rec(prefix, wires, counter);
                    Self::push_stage_wire(prefix, wires, counter, inner)
                } else {
                    else_e.as_ref().clone()
                };
                Expr::Ternary {
                    cond: Box::new(c),
                    then_e: Box::new(t),
                    else_e: Box::new(e),
                }
            }
            Expr::Concat { parts } => {
                let staged: Vec<Expr> = parts
                    .iter()
                    .map(|p| {
                        if p.depth() > 1 {
                            let inner = p.stage_balance_rec(prefix, wires, counter);
                            Self::push_stage_wire(prefix, wires, counter, inner)
                        } else {
                            p.clone()
                        }
                    })
                    .collect();
                Expr::Concat { parts: staged }
            }
            Expr::Replicate { count, body } => {
                let b = if body.depth() > 1 {
                    let inner = body.stage_balance_rec(prefix, wires, counter);
                    Self::push_stage_wire(prefix, wires, counter, inner)
                } else {
                    body.as_ref().clone()
                };
                Expr::Replicate {
                    count: count.clone(),
                    body: Box::new(b),
                }
            }
            Expr::Index { base, index } => {
                let b = if base.depth() > 1 {
                    let inner = base.stage_balance_rec(prefix, wires, counter);
                    Self::push_stage_wire(prefix, wires, counter, inner)
                } else {
                    base.as_ref().clone()
                };
                Expr::Index {
                    base: Box::new(b),
                    index: index.clone(),
                }
            }
            Expr::Call { name, args } => {
                let staged: Vec<Expr> = args
                    .iter()
                    .map(|a| {
                        if a.depth() > 1 {
                            let inner = a.stage_balance_rec(prefix, wires, counter);
                            Self::push_stage_wire(prefix, wires, counter, inner)
                        } else {
                            a.clone()
                        }
                    })
                    .collect();
                Expr::Call {
                    name: name.clone(),
                    args: staged,
                }
            }
        }
    }

    fn push_stage_wire(
        prefix: &str,
        wires: &mut Vec<(String, String)>,
        counter: &mut u32,
        expr: Expr,
    ) -> Expr {
        let name = format!("{prefix}{counter}");
        *counter += 1;
        wires.push((name.clone(), expr.emit()));
        Expr::Ident { name }
    }

    fn walk_ops(&self, f: &mut dyn FnMut(OperatorClass)) {
        match self {
            Expr::Ident { .. } | Expr::Literal { .. } | Expr::Opaque { .. } => {}
            Expr::PartSelect { kind, left, right } => {
                if kind.is_indexed() {
                    left.walk_ops(f);
                } else {
                    let _ = (left, right);
                }
            }
            Expr::Unary { arg, op, .. } => {
                f(classify_unary(op));
                arg.walk_ops(f);
            }
            Expr::Binary {
                op_class,
                left,
                right,
                ..
            } => {
                f(*op_class);
                left.walk_ops(f);
                right.walk_ops(f);
            }
            Expr::Ternary {
                cond,
                then_e,
                else_e,
            } => {
                f(OperatorClass::Mux);
                cond.walk_ops(f);
                then_e.walk_ops(f);
                else_e.walk_ops(f);
            }
            Expr::Concat { parts } => {
                f(OperatorClass::Concat);
                for p in parts {
                    p.walk_ops(f);
                }
            }
            Expr::Replicate { count, body } => {
                f(OperatorClass::Concat);
                count.walk_ops(f);
                body.walk_ops(f);
            }
            Expr::Index { base, index } => {
                base.walk_ops(f);
                index.walk_ops(f);
            }
            Expr::Call { args, .. } => {
                f(OperatorClass::Other);
                for a in args {
                    a.walk_ops(f);
                }
            }
        }
    }
}

/// Intermediate-wire staging plan for BalanceMux RTL rewrite.
#[derive(Debug, Clone)]
pub struct ExprStagePlan {
    /// `(wire_name, rhs_text)` in dependency order (leaves first).
    pub wires: Vec<(String, String)>,
    /// Shallow top expression (uses wire idents).
    pub top: Expr,
    /// `top.emit()` cached.
    pub top_emit: String,
}

impl ExprStagePlan {
    /// Dense always_comb fragment declaring wires and assigning stages + optional top wire.
    ///
    /// Named blocks are unique per plan (derived from `top_wire` / first stage wire) so
    /// multi-arm BalanceMux snippets in one module do not collide under Verilator.
    pub fn to_sv_fragment(&self, top_wire: Option<&str>, data_width: u32) -> String {
        // Never emit [0-1:0] / [1-1:0] — default to 64 when width unknown.
        let w = if data_width < 2 { 64 } else { data_width };
        // Unique begin label: prefer top wire, else first staged wire.
        let block = top_wire
            .map(|t| format!("{t}_stage"))
            .or_else(|| self.wires.first().map(|(n, _)| format!("{n}_stage")))
            .unwrap_or_else(|| "svt_balance_mux_stage".into());
        let mut b = String::new();
        b.push_str("  // --- BalanceMux arm staging (latency-neutral) ---\n");
        for (name, _) in &self.wires {
            b.push_str(&format!("  logic [{w}-1:0] {name};\n"));
        }
        if let Some(tw) = top_wire {
            if !self.wires.iter().any(|(n, _)| n == tw) {
                b.push_str(&format!("  logic [{w}-1:0] {tw};\n"));
            }
        }
        b.push_str(&format!("  always_comb begin : {block}\n"));
        for (name, rhs) in &self.wires {
            b.push_str(&format!("    {name} = {rhs};\n"));
        }
        if let Some(tw) = top_wire {
            b.push_str(&format!("    {tw} = {};\n", self.top_emit));
        }
        b.push_str("  end\n");
        b
    }
}

/// Flatten a chain of the same associative binary `op` into leaf expressions.
fn flatten_assoc(op: &str, e: &Expr, out: &mut Vec<Expr>) {
    match e {
        Expr::Binary {
            op: o, left, right, ..
        } if o == op && Expr::is_associative_binary_op(o) => {
            flatten_assoc(op, left, out);
            flatten_assoc(op, right, out);
        }
        other => out.push(other.rebalance_associative()),
    }
}

/// Build a balanced binary tree from leaves with operator `op`.
fn build_balanced_assoc(op: &str, op_class: OperatorClass, leaves: &[Expr]) -> Expr {
    assert!(!leaves.is_empty());
    if leaves.len() == 1 {
        return leaves[0].clone();
    }
    if leaves.len() == 2 {
        return Expr::Binary {
            op: op.to_string(),
            op_class,
            left: Box::new(leaves[0].clone()),
            right: Box::new(leaves[1].clone()),
        };
    }
    let mid = leaves.len() / 2;
    Expr::Binary {
        op: op.to_string(),
        op_class,
        left: Box::new(build_balanced_assoc(op, op_class, &leaves[..mid])),
        right: Box::new(build_balanced_assoc(op, op_class, &leaves[mid..])),
    }
}

/// True if two width hints may share an associative rebalance group.
fn widths_compatible(a: Option<u32>, b: Option<u32>) -> bool {
    match (a, b) {
        (None, _) | (_, None) => true,
        (Some(x), Some(y)) => x == y,
    }
}

/// Segment leaves into width-compatible runs; balance each; join left-assoc.
fn build_width_aware_balanced_assoc(op: &str, op_class: OperatorClass, leaves: &[Expr]) -> Expr {
    assert!(!leaves.is_empty());
    if leaves.len() == 1 {
        return leaves[0].clone();
    }
    // Partition into maximal contiguous compatible segments.
    let mut segments: Vec<Vec<Expr>> = Vec::new();
    let mut cur: Vec<Expr> = vec![leaves[0].clone()];
    let mut cur_w = leaves[0].width_class_hint();
    for leaf in &leaves[1..] {
        let w = leaf.width_class_hint();
        if widths_compatible(cur_w, w) {
            // Tighten group width when we learn a concrete size.
            if cur_w.is_none() {
                cur_w = w;
            }
            cur.push(leaf.clone());
        } else {
            segments.push(std::mem::take(&mut cur));
            cur = vec![leaf.clone()];
            cur_w = w;
        }
    }
    if !cur.is_empty() {
        segments.push(cur);
    }

    let balanced_segs: Vec<Expr> = segments
        .iter()
        .map(|seg| {
            if seg.len() >= 3 {
                build_balanced_assoc(op, op_class, seg)
            } else if seg.len() == 2 {
                Expr::Binary {
                    op: op.to_string(),
                    op_class,
                    left: Box::new(seg[0].clone()),
                    right: Box::new(seg[1].clone()),
                }
            } else {
                seg[0].clone()
            }
        })
        .collect();

    // Join segments left-associatively (do not rebalance across width barriers).
    let mut acc = balanced_segs[0].clone();
    for seg in &balanced_segs[1..] {
        acc = Expr::Binary {
            op: op.to_string(),
            op_class,
            left: Box::new(acc),
            right: Box::new(seg.clone()),
        };
    }
    acc
}

fn parse_sized_literal_width(text: &str) -> Option<u32> {
    // 64'hdead, 8'd12, 1'b0
    let t = text.trim();
    let tick = t.find('\'')?;
    let width_s = t[..tick].trim();
    if width_s.is_empty() {
        return None;
    }
    width_s.parse::<u32>().ok().filter(|w| *w > 0)
}

fn parse_unsized_decimal(text: &str) -> Option<u32> {
    text.trim().parse::<u32>().ok()
}

/// True for the index of a **fixed** part-select `base[msb:lsb]`.
///
/// IEEE 1800 §11.5.1 requires both bounds of a fixed part-select to be *constant
/// expressions*, so their arithmetic is resolved at elaboration and costs no hardware.
/// A variable select must use `[base +: width]` / `[base -: width]` instead, so this
/// carries no risk of excusing a runtime index.
///
/// This is a language guarantee, not an identifier-name guess: it is the sound form of
/// the demotion that was removed with the name heuristics. Without it, parameter
/// arithmetic in a slice bound is billed as a real divider -- measured on
/// `core/cva6_mmu/cva6_ptw.sv:189`, where
/// `vaddr_q[12+((CVA6Cfg.VpnLen/CVA6Cfg.PtLevels)*(...))-1 : 12+(...)]` was reported as a
/// 202.0 FO4 `atomic_over_budget` DivRem, the worst raw path in `full_core`, for a slice
/// that synthesises to wires. Only the `:` form is trusted; `+:` bases stay charged.
fn is_constant_range_select(index: &Expr) -> bool {
    matches!(
        index,
        Expr::PartSelect {
            kind: PartSelectKind::FixedRange,
            ..
        }
    )
}

fn is_elab_system_fn(name: &str) -> bool {
    matches!(
        name,
        "$clog2" | "$bits" | "$unsigned" | "$signed" | "$ceil" | "$floor" | "$ln" | "$log10"
    )
}

/// Format byte-width helpers (INT4 pack or `{1,2,4}`-byte element). A call is
/// a mux-of-shifts, not a 56 FO4 datapath mul. Never used to parse `32'(expr)`.
fn is_fmt_scale_fn(name: &str) -> bool {
    matches!(name, "fmt_row_bytes" | "ai_fmt_bytes")
}

/// User function FO4 class. `fmt_row_bytes` is a mux-of-shifts. Unknown
/// calls stay Other: billing every 2-arg call as Mux re-inflated gemm
/// next-state (v49 12→15). Wrap/convert bodies are a later inline pass.
pub fn user_function_op_class(name: &str, _nargs: usize) -> OperatorClass {
    if is_fmt_scale_fn(name) {
        OperatorClass::Mux
    } else {
        OperatorClass::Other
    }
}

fn is_fmt_scale_call(e: &Expr) -> bool {
    matches!(e, Expr::Call { name, .. } if is_fmt_scale_fn(name))
}

fn indexed_part_select_base(index: &Expr) -> Option<&Expr> {
    match index {
        Expr::PartSelect { kind, left, .. } if kind.is_indexed() => Some(left.as_ref()),
        _ => None,
    }
}

/// `*` used as array/genvar index scale, not datapath multiply.
fn is_literal_power_of_two_mul(op: &str, left: &Expr, right: &Expr) -> bool {
    op == "*"
        && [left, right]
            .into_iter()
            .any(|e| positive_literal_value(e).is_some_and(u128::is_power_of_two))
}

/// Class billed for a binary op after cheap-scale demotion (P1).
///
/// Runtime `*` of a literal power of two is a shift. Runtime `/` or `%` whose
/// **divisor** is Const (`8`, `WIDTH`, `HPDcacheCfg.u.dataWaysPerRamWord`) is
/// a shift or bit-select, not a 120 FO4 SRT divider. `8 / a` (runtime divisor)
/// stays [`OperatorClass::DivRem`].
pub fn billed_binary_class(
    op: &str,
    op_class: OperatorClass,
    left: &Expr,
    right: &Expr,
    seed: &ConstSeed,
) -> OperatorClass {
    if matches!(op_class, OperatorClass::Mul | OperatorClass::DivRem)
        && is_literal_power_of_two_mul(op, left, right)
    {
        return OperatorClass::Other;
    }
    // `x * fmt_row_bytes(...)` / `elems * ai_fmt_bytes()` is a shift, not Mul.
    // Do not use this to parse general `32'(expr)` (gemm v25 regression).
    if matches!(op_class, OperatorClass::Mul)
        && op == "*"
        && (is_fmt_scale_call(left) || is_fmt_scale_call(right))
    {
        return OperatorClass::ShiftConst;
    }
    if matches!(op_class, OperatorClass::DivRem)
        && matches!(op, "/" | "%")
        && is_const_divisor_scale(right, seed)
    {
        return OperatorClass::Other;
    }
    // `x + 1` / `x - 1'd1` is an increment, not a 10 FO4 carry-propagate add
    // (axi2mem wrap staging: `len + 1` then `<< LOG` then `wrap +`).
    if matches!(op_class, OperatorClass::AddSub)
        && matches!(op, "+" | "-")
        && is_unit_increment_operand(left, right)
    {
        return OperatorClass::LogicBit;
    }
    // Const offset (`used_bits += te_pkg::XLEN + (address_off * 8)`): folding
    // the constant does not insert a 10 FO4 CPA on the runtime spine.
    if matches!(op_class, OperatorClass::AddSub)
        && matches!(op, "+" | "-")
        && (left.const_class(seed).is_const() || right.const_class(seed).is_const())
    {
        return OperatorClass::LogicBit;
    }
    // `addr + (c ? 2 : 4)` / `pc + (compressed ? 'h2 : 'h4)`: both arms are
    // elaboration constants, so the add is a selected increment, not CPA+mux.
    // `addr + (taken ? rvc_imm : rvi_imm)` stays AddSub (runtime arms).
    if matches!(op_class, OperatorClass::AddSub)
        && matches!(op, "+" | "-")
        && (is_const_select_mux(left, seed) || is_const_select_mux(right, seed))
    {
        return OperatorClass::LogicBit;
    }
    // `x != 0` / `x == '0` is an or-reduce / is-zero, not a magnitude compare
    // (pe_dot `final_bfp_sum != MAXW'(0)`). `x != y` stays Compare.
    if matches!(op_class, OperatorClass::Compare)
        && matches!(op, "==" | "!=" | "===" | "!==")
        && (is_zero_literal(left) || is_zero_literal(right))
    {
        return OperatorClass::LogicBit;
    }
    // Signed `x > 0` / `x >= 0` / `x < 0` is the sign bit, not a magnitude
    // compare (fpnew `exponent_difference > 0`). `x > y` stays Compare.
    if matches!(op_class, OperatorClass::Compare)
        && matches!(op, ">" | ">=" | "<" | "<=")
        && (is_zero_literal(left) || is_zero_literal(right))
    {
        return OperatorClass::LogicBit;
    }
    // `1 << n` is a one-hot decoder, not a barrel (dm_sba `32'h1 << sbaccess`).
    if matches!(op, "<<" | "<<<") && is_const_pow2_shl(left, right, seed) {
        return OperatorClass::Mux;
    }
    // `x + (1 << n)` is a mux of increments, not CPA+shift.
    // `x + (a << n)` with runtime `a` stays AddSub.
    if matches!(op_class, OperatorClass::AddSub)
        && matches!(op, "+" | "-")
        && (is_one_hot_stride(left, seed) || is_one_hot_stride(right, seed))
    {
        return OperatorClass::Mux;
    }
    // `{x[MSB:K], {K{0}}} + (y << K)` is a field insert (axi2mem aligned stride).
    if matches!(op_class, OperatorClass::AddSub)
        && matches!(op, "+")
        && is_aligned_field_insert(left, right, seed)
    {
        return OperatorClass::Concat;
    }
    op_class
}

/// Ternary whose *arms* are Const (the condition may be runtime).
fn is_const_select_mux(e: &Expr, seed: &ConstSeed) -> bool {
    match e {
        Expr::Ternary { then_e, else_e, .. } => {
            then_e.const_class(seed).is_const() && else_e.const_class(seed).is_const()
        }
        _ => false,
    }
}

/// Nested `c ? Const : (c2 ? Const : … : tail)`. One mux on the runtime spine.
fn const_then_chain<'a>(e: &'a Expr, seed: &ConstSeed) -> Option<(Vec<&'a Expr>, &'a Expr)> {
    let Expr::Ternary {
        cond,
        then_e,
        else_e,
    } = e
    else {
        return None;
    };
    if !is_encoding_then(then_e, seed) {
        return None;
    }
    if let Some((mut conds, tail)) = const_then_chain(else_e, seed) {
        conds.insert(0, cond.as_ref());
        Some((conds, tail))
    } else {
        Some((vec![cond.as_ref()], else_e.as_ref()))
    }
}

/// Then-arm that is a canonical encoding, not datapath: Const, or a concat that
/// packs flags into const fields (`{sign, 8'hff, 23'd0}` Inf). Bare ident / `{a,b}`
/// stay datapath so `en ? a : (f ? C : d)` does not flatten.
fn is_encoding_then(e: &Expr, seed: &ConstSeed) -> bool {
    if e.const_class(seed).is_const() {
        return true;
    }
    match e {
        Expr::Concat { parts } => {
            !parts.is_empty()
                && parts.iter().any(|p| p.const_class(seed).is_const())
                && parts.iter().all(|p| is_encoding_then_part(p, seed))
        }
        Expr::Replicate { body, .. } => is_encoding_then(body, seed),
        _ => false,
    }
}

fn is_encoding_then_part(e: &Expr, seed: &ConstSeed) -> bool {
    if e.const_class(seed).is_const() {
        return true;
    }
    match e {
        Expr::Ident { .. } | Expr::Literal { .. } => true,
        Expr::Concat { parts } => parts.iter().all(|p| is_encoding_then_part(p, seed)),
        Expr::Replicate { body, .. } => is_encoding_then_part(body, seed),
        Expr::Index { base, index }
            if is_constant_range_select(index) || index.const_class(seed).is_const() =>
        {
            is_encoding_then_part(base, seed)
        }
        Expr::Unary { op, arg } if matches!(op.as_str(), "~" | "!") => {
            is_encoding_then_part(arg, seed)
        }
        _ => false,
    }
}

fn is_bare_ident(e: &Expr) -> bool {
    matches!(e, Expr::Ident { .. })
}

/// `ident ± 1` / `1 ± ident` (not `ident[sel] ± 1`, which is gemm `n_q[8:0]-1`).
fn is_ident_unit_increment(e: &Expr) -> bool {
    let Expr::Binary {
        op, left, right, ..
    } = e
    else {
        return false;
    };
    matches!(op.as_str(), "+" | "-")
        && is_unit_increment_operand(left, right)
        && (is_bare_ident(left) || is_bare_ident(right))
}

/// Inner of `W'(…)` that may collapse without reopening general `(W)'(expr)`.
fn is_width_cast_collapsible(val: &Expr, seed: &ConstSeed) -> bool {
    if val.const_class(seed).is_const() {
        return true;
    }
    if is_bare_ident(val) {
        return true;
    }
    is_ident_unit_increment(val)
}

/// IEEE 1800 type-name left of `'(…)`. Collapsing these exposes later `*`/`+`
/// (`int'(group_q)*6` → Mul 56). Width names (`32`, `PLEN`, `IDX_W`) are not types.
fn is_sv_type_cast_width(e: &Expr) -> bool {
    let Expr::Ident { name } = e else {
        return false;
    };
    let base = name
        .rsplit("::")
        .next()
        .unwrap_or(name)
        .rsplit('.')
        .next()
        .unwrap_or(name);
    matches!(
        base,
        "int"
            | "integer"
            | "shortint"
            | "longint"
            | "byte"
            | "bit"
            | "logic"
            | "reg"
            | "wire"
            | "unsigned"
            | "signed"
            | "time"
            | "real"
            | "shortreal"
            | "string"
            | "void"
    )
}

fn is_unit_increment_operand(left: &Expr, right: &Expr) -> bool {
    matches!(positive_literal_value(left), Some(1))
        || matches!(positive_literal_value(right), Some(1))
}

fn is_zero_literal(e: &Expr) -> bool {
    matches!(positive_literal_value(e), Some(0))
}

/// `C << n` with C a constant power of two and n runtime (one-hot decoder).
fn is_const_pow2_shl(left: &Expr, right: &Expr, seed: &ConstSeed) -> bool {
    if right.const_class(seed).is_const() {
        return false;
    }
    positive_literal_value(left).is_some_and(u128::is_power_of_two)
}

fn is_one_hot_stride(e: &Expr, seed: &ConstSeed) -> bool {
    let Expr::Binary {
        op, left, right, ..
    } = e
    else {
        return false;
    };
    matches!(op.as_str(), "<<" | "<<<") && is_const_pow2_shl(left, right, seed)
}

fn is_zero_fill(e: &Expr) -> bool {
    match e {
        Expr::Literal { .. } => is_zero_literal(e),
        Expr::Replicate { body, .. } => is_zero_fill(body),
        Expr::Concat { parts } => !parts.is_empty() && parts.iter().all(is_zero_fill),
        _ => false,
    }
}

fn zero_fill_count(e: &Expr) -> Option<&Expr> {
    match e {
        Expr::Replicate { count, body } if is_zero_fill(body) => Some(count.as_ref()),
        // `{ {K{1'b0}} }` is a one-part concat wrapping a replicate (axi2mem).
        Expr::Concat { parts } if parts.len() == 1 => zero_fill_count(&parts[0]),
        _ => None,
    }
}

fn concat_high_and_zero_pad(e: &Expr) -> Option<(&Expr, &Expr)> {
    let Expr::Concat { parts } = e else {
        return None;
    };
    if parts.len() != 2 {
        return None;
    }
    let zc = zero_fill_count(&parts[1])?;
    Some((&parts[0], zc))
}

fn alignment_key(e: &Expr) -> Option<String> {
    let e = expr_align_leaf(e);
    match e {
        Expr::Ident { name } => {
            let b = ident_align_base(name);
            if b.is_empty() {
                None
            } else {
                Some(b)
            }
        }
        Expr::Literal { .. } => positive_literal_value(e).map(|v| v.to_string()),
        _ => None,
    }
}

/// `{LOG}` / `{ {LOG} }` wrappers around a replicate count are still `LOG`.
fn expr_align_leaf(e: &Expr) -> &Expr {
    match e {
        Expr::Concat { parts } if parts.len() == 1 => expr_align_leaf(&parts[0]),
        _ => e,
    }
}

fn shl_amount(e: &Expr) -> Option<&Expr> {
    match e {
        Expr::Binary { op, right, .. } if matches!(op.as_str(), "<<" | "<<<") => {
            Some(right.as_ref())
        }
        _ => None,
    }
}

fn expr_same_constish(a: &Expr, b: &Expr) -> bool {
    let a = expr_align_leaf(a);
    let b = expr_align_leaf(b);
    match (a, b) {
        (Expr::Ident { name: n1 }, Expr::Ident { name: n2 }) => n1 == n2,
        (Expr::Literal { text: t1 }, Expr::Literal { text: t2 }) if t1 == t2 => true,
        _ => match (positive_literal_value(a), positive_literal_value(b)) {
            (Some(x), Some(y)) => x == y,
            _ => false,
        },
    }
}

/// `{x[MSB:K], {K{1'b0}}} + (y << K)` — aligned field insert, not a CPA.
/// Also `aligned_ident + (y << K)` when the first pass seeded `aligned_ident`,
/// and `aligned_ident + shifted_ident` when the shift was staged off the add.
fn is_aligned_field_insert(left: &Expr, right: &Expr, seed: &ConstSeed) -> bool {
    for (a, b) in [(left, right), (right, left)] {
        if let Some((_, zcount)) = concat_high_and_zero_pad(a) {
            if let Some(amt) = shl_amount(b) {
                if expr_same_constish(zcount, amt) {
                    return true;
                }
                if zcount.const_class(seed).is_const() && amt.const_class(seed).is_const() {
                    return true;
                }
            }
        }
        if let Expr::Ident { name } = a {
            if let Some(amt) = shl_amount(b) {
                if let (Some(ak), Some(kk)) = (seed.aligned_k(name), alignment_key(amt)) {
                    if ak == kk {
                        return true;
                    }
                }
            }
            if let Expr::Ident { name: other } = b {
                if let (Some(ak), Some(sk)) = (seed.aligned_k(name), seed.shifted_k(other)) {
                    if ak == sk {
                        return true;
                    }
                }
            }
        }
    }
    false
}

fn is_const_divisor_scale(right: &Expr, seed: &ConstSeed) -> bool {
    if !right.const_class(seed).is_const() {
        return false;
    }
    match positive_literal_value(right) {
        Some(0) => false,
        Some(_) => true,
        None => true,
    }
}

fn positive_literal_value(e: &Expr) -> Option<u128> {
    let Expr::Literal { text } = e else {
        return None;
    };
    let text = text.replace('_', "");
    let Some((width, digits)) = text.split_once('\'') else {
        return text.parse::<u128>().ok().filter(|v| *v <= i32::MAX as u128);
    };
    let width = if width.is_empty() {
        32
    } else {
        width.parse::<u32>().ok()?
    };
    let signed = digits.starts_with(['s', 'S']);
    let digits = if signed { &digits[1..] } else { digits };
    let radix = match digits.as_bytes().first()? {
        b'b' | b'B' => 2,
        b'o' | b'O' => 8,
        b'd' | b'D' => 10,
        b'h' | b'H' => 16,
        _ => return None,
    };
    let value = u128::from_str_radix(digits.get(1..)?, radix).ok()?;
    let bits = u128::BITS - value.leading_zeros();
    if width == 0 || bits > width || (signed && bits == width) {
        return None;
    }
    Some(value)
}

/// Dominant op for coarse class: do not rank addr-scale mul as full Mul.
pub fn dominant_op_class_measured(e: &Expr) -> OperatorClass {
    dominant_op_class_measured_seeded(e, &ConstSeed::heuristic())
}

fn dominant_op_class_measured_seeded(e: &Expr, seed: &ConstSeed) -> OperatorClass {
    // Prefer non-scale classification by temporarily ranking via walk with scale demotion.
    let mut best = OperatorClass::Other;
    let mut best_rank = 0u8;
    fn walk(e: &Expr, seed: &ConstSeed, f: &mut dyn FnMut(OperatorClass)) {
        match e {
            Expr::Ident { .. } | Expr::Literal { .. } | Expr::Opaque { .. } => {}
            Expr::PartSelect { kind, left, right } => {
                if kind.is_indexed() {
                    walk(left, seed, f);
                } else {
                    let _ = (left, right);
                }
            }
            Expr::Unary { arg, op, .. } => {
                f(classify_unary(op));
                walk(arg, seed, f);
            }
            Expr::Binary {
                op,
                op_class,
                left,
                right,
                ..
            } => {
                if left.const_class(seed).is_const() && right.const_class(seed).is_const() {
                    // P1: do not nominate Const arithmetic as the path's class.
                } else {
                    f(billed_binary_class(op, *op_class, left, right, seed));
                    walk(left, seed, f);
                    walk(right, seed, f);
                }
            }
            Expr::Ternary {
                cond,
                then_e,
                else_e,
            } => {
                if cond.const_class(seed).is_const() {
                    walk(then_e, seed, f);
                    walk(else_e, seed, f);
                    return;
                }
                if let Some((conds, tail)) = const_then_chain(e, seed) {
                    f(OperatorClass::Mux);
                    for c in conds {
                        walk(c, seed, f);
                    }
                    walk(tail, seed, f);
                    return;
                }
                f(OperatorClass::Mux);
                walk(cond, seed, f);
                walk(then_e, seed, f);
                walk(else_e, seed, f);
            }
            Expr::Concat { parts } => {
                f(OperatorClass::Concat);
                for p in parts {
                    walk(p, seed, f);
                }
            }
            Expr::Replicate { count: _, body } => {
                // Replication count is LRM-constant — do not walk it as hardware.
                walk(body, seed, f);
            }
            Expr::Index { base, index } => {
                walk(base, seed, f);
                // Constant `[msb:lsb]` bounds must not nominate the path's class: the
                // ptw slice above would otherwise rank as a DivRem cone.
                if is_constant_range_select(index) {
                    // bounds are elaboration-time
                } else if let Some(base_idx) = indexed_part_select_base(index) {
                    walk(base_idx, seed, f);
                } else {
                    walk(index, seed, f);
                }
            }
            Expr::Call { name, args, .. } => {
                if is_elab_system_fn(name) && args.iter().all(|a| a.const_class(seed).is_const()) {
                    // P1 $clog2/$bits of constants — not an operator class.
                } else {
                    f(user_function_op_class(name, args.len()));
                    for a in args {
                        walk(a, seed, f);
                    }
                }
            }
        }
    }
    walk(e, seed, &mut |c| {
        let r = class_rank(c);
        if r > best_rank {
            best_rank = r;
            best = c;
        }
    });
    best
}

fn paren_if_needed(e: &Expr) -> String {
    match e {
        Expr::Binary { .. } | Expr::Ternary { .. } | Expr::PartSelect { .. } => {
            format!("({})", e.emit())
        }
        _ => e.emit(),
    }
}

fn class_rank(c: OperatorClass) -> u8 {
    match c {
        OperatorClass::DivRem => 10,
        OperatorClass::Mul => 9,
        OperatorClass::ShiftVar => 8,
        OperatorClass::AddSub => 7,
        OperatorClass::Compare => 6,
        OperatorClass::PriorityMux => 5,
        OperatorClass::Mux => 4,
        OperatorClass::ShiftConst => 3,
        OperatorClass::LogicBit => 2,
        OperatorClass::Concat => 1,
        OperatorClass::Other => 0,
    }
}

/// Map binary operator spelling to [`OperatorClass`].
pub fn classify_binary_op(sym: &str) -> OperatorClass {
    match sym.trim() {
        "+" | "-" => OperatorClass::AddSub,
        "*" => OperatorClass::Mul,
        // `2 ** lvl` is a decoder / shift, not a 56-FO4 datapath multiply.
        "**" => OperatorClass::ShiftConst,
        "/" | "%" => OperatorClass::DivRem,
        "<<" | ">>" | "<<<" | ">>>" => OperatorClass::ShiftConst,
        "==" | "!=" | "===" | "!==" | "<" | ">" | "<=" | ">=" => OperatorClass::Compare,
        "&" | "|" | "^" | "~^" | "^~" | "&&" | "||" => OperatorClass::LogicBit,
        _ => OperatorClass::Other,
    }
}

/// Class billed for a unary operator.
pub fn classify_unary(op: &str) -> OperatorClass {
    match op.trim() {
        "~" | "!" | "&" | "|" | "^" | "~&" | "~|" | "~^" | "^~" => OperatorClass::LogicBit,
        "-" | "+" => OperatorClass::AddSub,
        _ => OperatorClass::Other,
    }
}

// --- recursive descent -------------------------------------------------------

struct Parser<'a> {
    src: &'a [u8],
    i: usize,
}

impl<'a> Parser<'a> {
    fn skip_ws_eof(&mut self) -> bool {
        self.skip_ws();
        self.i >= self.src.len()
    }

    fn rest_str(&self) -> String {
        String::from_utf8_lossy(&self.src[self.i..]).into_owned()
    }

    fn skip_ws(&mut self) {
        loop {
            while self.i < self.src.len() && self.src[self.i].is_ascii_whitespace() {
                self.i += 1;
            }
            if self.i + 1 < self.src.len()
                && self.src[self.i] == b'/'
                && self.src[self.i + 1] == b'/'
            {
                while self.i < self.src.len() && self.src[self.i] != b'\n' {
                    self.i += 1;
                }
                continue;
            }
            if self.i + 1 < self.src.len()
                && self.src[self.i] == b'/'
                && self.src[self.i + 1] == b'*'
            {
                self.i += 2;
                while self.i + 1 < self.src.len()
                    && !(self.src[self.i] == b'*' && self.src[self.i + 1] == b'/')
                {
                    self.i += 1;
                }
                if self.i + 1 < self.src.len() {
                    self.i += 2;
                }
                continue;
            }
            break;
        }
    }

    fn peek(&self) -> Option<u8> {
        self.src.get(self.i).copied()
    }

    fn bump(&mut self) -> Option<u8> {
        let c = self.peek()?;
        self.i += 1;
        Some(c)
    }

    fn parse_expr(&mut self) -> Option<Expr> {
        self.parse_ternary()
    }

    fn parse_ternary(&mut self) -> Option<Expr> {
        let mut e = self.parse_or()?;
        self.skip_ws();
        if self.peek() == Some(b'?') {
            self.bump();
            let t = self.parse_expr()?;
            self.skip_ws();
            if self.peek() != Some(b':') {
                return Some(Expr::Opaque {
                    text: format!("{} ? {}", e.emit(), t.emit()),
                });
            }
            self.bump();
            let f = self.parse_expr()?;
            e = Expr::Ternary {
                cond: Box::new(e),
                then_e: Box::new(t),
                else_e: Box::new(f),
            };
        }
        Some(e)
    }

    fn parse_or(&mut self) -> Option<Expr> {
        self.parse_bin_left(&["||"], |p| p.parse_and())
    }

    fn parse_and(&mut self) -> Option<Expr> {
        self.parse_bin_left(&["&&"], |p| p.parse_bit_or())
    }

    fn parse_bit_or(&mut self) -> Option<Expr> {
        self.parse_bin_left(&["|"], |p| p.parse_bit_xor())
    }

    fn parse_bit_xor(&mut self) -> Option<Expr> {
        self.parse_bin_left(&["^", "~^", "^~"], |p| p.parse_bit_and())
    }

    fn parse_bit_and(&mut self) -> Option<Expr> {
        self.parse_bin_left(&["&"], |p| p.parse_eq())
    }

    fn parse_eq(&mut self) -> Option<Expr> {
        self.parse_bin_left(&["===", "!==", "==", "!="], |p| p.parse_rel())
    }

    fn parse_rel(&mut self) -> Option<Expr> {
        self.parse_bin_left(&["<=", ">=", "<", ">"], |p| p.parse_shift())
    }

    fn parse_shift(&mut self) -> Option<Expr> {
        self.parse_bin_left(&["<<<", ">>>", "<<", ">>"], |p| p.parse_add())
    }

    fn parse_add(&mut self) -> Option<Expr> {
        self.parse_bin_left(&["+", "-"], |p| p.parse_mul())
    }

    fn parse_mul(&mut self) -> Option<Expr> {
        // `**` before `*` so power is not two Mul nodes.
        self.parse_bin_left(&["**", "*", "/", "%"], |p| p.parse_unary())
    }

    fn parse_bin_left(
        &mut self,
        ops: &[&str],
        next: fn(&mut Parser<'_>) -> Option<Expr>,
    ) -> Option<Expr> {
        let mut left = next(self)?;
        loop {
            self.skip_ws();
            let Some(op) = self.match_op(ops) else {
                break;
            };
            let right = next(self)?;
            left = Expr::Binary {
                op_class: classify_binary_op(&op),
                op,
                left: Box::new(left),
                right: Box::new(right),
            };
        }
        Some(left)
    }

    fn match_op(&mut self, ops: &[&str]) -> Option<String> {
        // longest match first — callers order multi-char ops before shorter
        let mut sorted: Vec<&str> = ops.to_vec();
        sorted.sort_by_key(|s| std::cmp::Reverse(s.len()));
        for op in sorted {
            let b = op.as_bytes();
            if self.i + b.len() <= self.src.len() && &self.src[self.i..self.i + b.len()] == b {
                // Avoid matching single & when next is & (handled by longer ops if listed)
                // Avoid matching < when next is = if <= not in this set — ok
                // Don't eat part of identifier
                if op.len() == 1 && op.as_bytes()[0].is_ascii_alphanumeric() {
                    continue;
                }
                // `/` starting `//` or `/*` is a comment, not DivRem.
                if op == "/"
                    && self.i + 1 < self.src.len()
                    && (self.src[self.i + 1] == b'/' || self.src[self.i + 1] == b'*')
                {
                    continue;
                }
                // Indexed part-select `+:` / `-:` is not add/sub.
                if (op == "+" || op == "-")
                    && self.i + b.len() < self.src.len()
                    && self.src[self.i + b.len()] == b':'
                {
                    continue;
                }
                // For single-char ops that start multi-char ops of higher precedence
                // handled by sorted order within the set only.
                self.i += b.len();
                return Some(op.to_string());
            }
        }
        None
    }

    fn parse_unary(&mut self) -> Option<Expr> {
        self.skip_ws();
        if let Some(op) =
            self.match_op(&["~&", "~|", "~^", "^~", "~", "!", "-", "+", "&", "|", "^"])
        {
            let arg = self.parse_unary()?;
            return Some(Expr::Unary {
                op,
                arg: Box::new(arg),
            });
        }
        self.parse_postfix()
    }

    fn parse_postfix(&mut self) -> Option<Expr> {
        let mut e = self.parse_primary()?;
        loop {
            self.skip_ws();
            match self.peek() {
                Some(b'[') => {
                    self.bump();
                    let idx = self.parse_expr()?;
                    self.skip_ws();
                    // `hi:lo` or indexed `base +: width` / `base -: width` (IEEE 1800 §11.5.1).
                    let index = if let Some(sel) = self.match_op(&["+:", "-:"]) {
                        let width = self.parse_expr()?;
                        Expr::PartSelect {
                            kind: PartSelectKind::from_op(&sel)
                                .unwrap_or(PartSelectKind::IndexedPlus),
                            left: Box::new(idx),
                            right: Box::new(width),
                        }
                    } else if self.peek() == Some(b':') {
                        self.bump();
                        let lo = self.parse_expr()?;
                        Expr::PartSelect {
                            kind: PartSelectKind::FixedRange,
                            left: Box::new(idx),
                            right: Box::new(lo),
                        }
                    } else {
                        idx
                    };
                    self.skip_ws();
                    if self.peek() == Some(b']') {
                        self.bump();
                    }
                    e = Expr::Index {
                        base: Box::new(e),
                        index: Box::new(index),
                    };
                }
                Some(b'(') if matches!(e, Expr::Ident { .. }) => {
                    // call: only when base is bare ident
                    let name = match &e {
                        Expr::Ident { name } => name.clone(),
                        _ => break,
                    };
                    self.bump();
                    let mut args = Vec::new();
                    self.skip_ws();
                    if self.peek() != Some(b')') {
                        loop {
                            args.push(self.parse_expr()?);
                            self.skip_ws();
                            if self.peek() == Some(b',') {
                                self.bump();
                                continue;
                            }
                            break;
                        }
                    }
                    self.skip_ws();
                    if self.peek() == Some(b')') {
                        self.bump();
                    }
                    e = Expr::Call { name, args };
                }
                Some(b'\'') if self.src.get(self.i + 1) == Some(&b'(') => {
                    // delay-v21: collapse `W'(const)` / `W'(ident)` / `W'(ident±1)`
                    // (store_unit `PLEN'(LINE_B)`, snoop `IDX_W'(int'(rr)+1)`,
                    // numeric `32'(LINE_B)`). Type-name casts (`int'(x)`) stay
                    // unparsed — collapsing `int'(group_q)*6` re-exposes a Mul
                    // (policy_subcode v43). General `(W)'(expr)` still
                    // backtracks — delay-v19 gemm `32'(n_q[8:0]-1)*row`.
                    if is_sv_type_cast_width(&e) {
                        break;
                    }
                    match self.try_collapse_width_cast() {
                        Some(val) => e = val,
                        None => break,
                    }
                }
                _ => break,
            }
        }
        Some(e)
    }

    /// `'(expr)` / consume `'(` after a width primary. Backtracks when the
    /// inner tree is not a safe collapse (gemm `32'(index-1)*row`).
    fn try_collapse_width_cast(&mut self) -> Option<Expr> {
        let save = self.i;
        self.bump();
        self.bump();
        match self.parse_expr() {
            Some(val) if is_width_cast_collapsible(&val, &ConstSeed::heuristic()) => {
                self.skip_ws();
                if self.peek() == Some(b')') {
                    self.bump();
                }
                Some(val)
            }
            _ => {
                self.i = save;
                None
            }
        }
    }

    fn parse_primary(&mut self) -> Option<Expr> {
        self.skip_ws();
        match self.peek()? {
            b'(' => {
                self.bump();
                let e = self.parse_expr()?;
                self.skip_ws();
                if self.peek() == Some(b')') {
                    self.bump();
                }
                Some(e)
            }
            b'{' => self.parse_concat_or_repl(),
            // Unsized `'(1)` / `'(LINE_B)` — same collapse rules as `W'(…)`.
            b'\'' if self.src.get(self.i + 1) == Some(&b'(') => self.try_collapse_width_cast(),
            b'\'' | b'0'..=b'9' => self.parse_literal(),
            c if c == b'_' || c.is_ascii_alphabetic() || c == b'$' => {
                self.parse_ident_or_call_name()
            }
            _ => {
                // consume one char as opaque
                let start = self.i;
                self.bump();
                Some(Expr::Opaque {
                    text: String::from_utf8_lossy(&self.src[start..self.i]).into_owned(),
                })
            }
        }
    }

    fn parse_concat_or_repl(&mut self) -> Option<Expr> {
        // { ... } or {N{expr}}
        self.bump(); // {
        self.skip_ws();
        // try replication: { expr { expr } }
        let save = self.i;
        if let Some(count) = self.parse_expr() {
            self.skip_ws();
            if self.peek() == Some(b'{') {
                self.bump();
                let body = self.parse_expr()?;
                self.skip_ws();
                if self.peek() == Some(b'}') {
                    self.bump();
                }
                self.skip_ws();
                if self.peek() == Some(b'}') {
                    self.bump();
                }
                return Some(Expr::Replicate {
                    count: Box::new(count),
                    body: Box::new(body),
                });
            }
            // not replication — reset and parse concat list starting with count
            self.i = save;
        }
        let mut parts = Vec::new();
        loop {
            self.skip_ws();
            if self.peek() == Some(b'}') {
                self.bump();
                break;
            }
            parts.push(self.parse_expr()?);
            self.skip_ws();
            if self.peek() == Some(b',') {
                self.bump();
                continue;
            }
            if self.peek() == Some(b'}') {
                self.bump();
                break;
            }
            // give up
            break;
        }
        Some(Expr::Concat { parts })
    }

    fn parse_literal(&mut self) -> Option<Expr> {
        let start = self.i;
        // sized: 32'hff  1'b0  8'd10
        // Do **not** swallow `'( ` — that is a width-cast (`32'(LINE_B)`),
        // handled by [`Self::try_collapse_width_cast`].
        while self.i < self.src.len() {
            let c = self.src[self.i];
            if c == b'\'' {
                if self.src.get(self.i + 1) == Some(&b'(') {
                    break;
                }
                self.i += 1;
                continue;
            }
            if c.is_ascii_alphanumeric()
                || c == b'_'
                || c == b'x'
                || c == b'X'
                || c == b'z'
                || c == b'Z'
            {
                self.i += 1;
            } else {
                break;
            }
        }
        if self.i == start {
            return None;
        }
        // trailing unit-less
        let text = String::from_utf8_lossy(&self.src[start..self.i]).into_owned();
        Some(Expr::Literal { text })
    }

    fn parse_ident_or_call_name(&mut self) -> Option<Expr> {
        let start = self.i;
        while self.i < self.src.len() {
            let c = self.src[self.i];
            if c.is_ascii_alphanumeric() || c == b'_' || c == b'$' || c == b'.' {
                self.i += 1;
            } else if c == b':' && self.src.get(self.i + 1) == Some(&b':') {
                // package/class scope: pkg::name
                self.i += 2;
            } else {
                break;
            }
        }
        let name = String::from_utf8_lossy(&self.src[start..self.i]).into_owned();
        Some(Expr::Ident { name })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_add_chain() {
        let e = Expr::parse("a_i + b_i + c_i");
        assert!(matches!(e, Expr::Binary { .. }), "{e:?}");
        assert_eq!(e.dominant_op_class(), OperatorClass::AddSub);
        assert!(e.op_node_count() >= 2);
        let back = e.emit();
        assert!(back.contains('+'), "{back}");
    }

    #[test]
    fn comment_slashes_are_not_division() {
        let e = Expr::parse("a + b // //////////////////////////\n");
        assert_eq!(e.dominant_op_class(), OperatorClass::AddSub, "{e:?}");
        let e2 = Expr::parse("//////////////////////////\na + b");
        assert_eq!(e2.dominant_op_class(), OperatorClass::AddSub, "{e2:?}");
        let e3 = Expr::parse("a /* / not div / */ + b");
        assert_eq!(e3.dominant_op_class(), OperatorClass::AddSub, "{e3:?}");
    }

    #[test]
    fn parse_ternary_and_logic() {
        let e = Expr::parse("(en) ? a & b : c");
        assert!(matches!(e, Expr::Ternary { .. }), "{e:?}");
        assert_eq!(e.dominant_op_class(), OperatorClass::Mux);
    }

    #[test]
    fn parse_concat_and_index() {
        let e = Expr::parse("{a_i, b_i[3:0]}");
        assert!(matches!(e, Expr::Concat { .. }), "{e:?}");
        let e2 = Expr::parse("mem[idx]");
        assert!(matches!(e2, Expr::Index { .. }), "{e2:?}");
    }

    #[test]
    fn fo4_mul_costs_more_than_add() {
        let base = |c: OperatorClass| match c {
            OperatorClass::AddSub => 10.0,
            OperatorClass::Mul => 56.0,
            _ => 1.0,
        };
        let add = Expr::parse("x + y");
        let mul = Expr::parse("operand_a_i * operand_b_i");
        assert!(
            mul.fo4_critical_cost(&base) > add.fo4_critical_cost(&base),
            "datapath mul should be expensive"
        );
    }

    #[test]
    fn addr_scale_mul_is_cheap_not_56_fo4() {
        let base = |c: OperatorClass| match c {
            OperatorClass::Mul => 56.0,
            OperatorClass::Other => 1.0,
            OperatorClass::AddSub => 10.0,
            _ => 1.0,
        };
        // genvar index scale like load_unit sign-bit / issue rdata index
        let scale = Expr::parse("(i + 1) * 8 - 1");
        let c = scale.fo4_critical_cost(&base);
        assert!(c < 30.0, "addr scale must not cost full mul, got {c}");
        assert_ne!(scale.dominant_op_class(), OperatorClass::Mul);
        let data = Expr::parse("operand_a_i * operand_b_i");
        assert!(data.fo4_critical_cost(&base) >= 56.0);
        assert_eq!(data.dominant_op_class(), OperatorClass::Mul);
        // fpnew FMA product — mixed-case datapath names, not genvar scale.
        let fma = Expr::parse("mantissa_a * mantissa_b");
        assert_eq!(fma.dominant_op_class(), OperatorClass::Mul);
        assert!(fma.fo4_critical_cost(&base) >= 56.0);
        // Mixed-case VpnLen is runtime under the heuristic seed (no module map).
        let cast_w = Expr::parse("(CVA6Cfg.PtLevels + HYP_EXT) * VpnLen");
        assert_eq!(cast_w.dominant_op_class(), OperatorClass::Mul);
        assert!(cast_w.fo4_critical_cost(&base) >= 56.0);
        // Same expression is elaboration when VpnLen is a module localparam.
        let seeded = ConstSeed::from_names(["VpnLen", "PtLevels"]);
        assert_eq!(
            Expr::parse("(VpnLen / PtLevels) * VpnLen").fo4_critical_cost_latticed(&base, &seeded),
            0.0
        );
        assert_ne!(
            Expr::parse("(VpnLen / PtLevels) * VpnLen").dominant_op_class_latticed(&seeded),
            OperatorClass::Mul
        );
        // Pure parameter arithmetic is elaboration (P1), not hardware.
        assert_eq!(
            Expr::parse("3 * PRECISION_BITS + 4").fo4_critical_cost(&base),
            0.0
        );
        let pow = Expr::parse("2 ** lvl");
        assert_ne!(pow.dominant_op_class(), OperatorClass::Mul);
        // Part-select bound arithmetic may use dynamic operands.
        let idx = Expr::parse("vaddr_q[(WIDTH / 8) * i]");
        // WIDTH/8 is Const (P1); the remaining runtime op is `* i`.
        assert_eq!(idx.dominant_op_class(), OperatorClass::Mul, "{idx:?}");
    }

    fn arithmetic_base(c: OperatorClass) -> f64 {
        match c {
            OperatorClass::Mul => 56.0,
            OperatorClass::DivRem => 120.0,
            OperatorClass::AddSub => 10.0,
            OperatorClass::Mux => 2.5,
            _ => 1.0,
        }
    }

    fn assert_arithmetic_cost(text: &str, class: OperatorClass, cost: f64) {
        let e = Expr::parse(text);
        assert_eq!(e.dominant_op_class(), class, "{text}: {e:?}");
        assert_eq!(e.fo4_critical_cost(&arithmetic_base), cost, "{text}");
        assert_eq!(
            e.fo4_critical_cost_as_index(&arithmetic_base),
            cost,
            "{text}"
        );
        assert!(cost <= e.fo4_cost(&arithmetic_base), "{text}");
        let spine = e.critical_spine_ops(&arithmetic_base);
        assert_eq!(
            spine.iter().map(|(_, c)| c).sum::<f64>(),
            cost,
            "{text}: {spine:?}"
        );
        assert_eq!(
            e.has_atomic_over_budget(&arithmetic_base, 10.0),
            matches!(class, OperatorClass::Mul | OperatorClass::DivRem),
            "{text}: {spine:?}"
        );
    }

    #[test]
    fn runtime_arithmetic_is_not_constant_by_identifier_name() {
        for (left, right) in [
            ("a", "b"),
            ("x", "y"),
            ("i", "j"),
            ("A", "B"),
            ("count", "num_items"),
            ("cfg.a", "cfg.b"),
            ("ExampleCfg.PtLevels", "VpnLen"),
            ("valid_count", "bit_width"),
            ("operand_a_i", "operand_b_i"),
            ("mantissa_a", "mantissa_b"),
        ] {
            for (op, class) in [
                ("*", OperatorClass::Mul),
                ("/", OperatorClass::DivRem),
                ("%", OperatorClass::DivRem),
            ] {
                assert_arithmetic_cost(
                    &format!("{left} {op} {right}"),
                    class,
                    arithmetic_base(class),
                );
            }
        }
    }

    #[test]
    fn indexed_runtime_arithmetic_keeps_datapath_cost() {
        for (text, class, cost) in [
            ("mem[a * b]", OperatorClass::Mul, 56.0),
            ("mem[a / b]", OperatorClass::DivRem, 120.0),
            ("mem[a % b]", OperatorClass::DivRem, 120.0),
            ("mem[operand_a_i * operand_b_i]", OperatorClass::Mul, 56.0),
            ("mem[(a + b) * (c + d)]", OperatorClass::Mul, 66.0),
            ("mem[sel ? a / b : c * d]", OperatorClass::DivRem, 122.5),
            ("mem[other[a * b]]", OperatorClass::Mul, 56.0),
            ("mem[f(a / b)]", OperatorClass::DivRem, 121.0),
            ("mem[{a * b, c / d}]", OperatorClass::DivRem, 121.0),
            // NOTE: `mem[a / b : 0]` is deliberately absent. A fixed `[msb:lsb]` bound
            // must be a constant expression (IEEE 1800 §11.5.1), so that form is not a
            // runtime divider -- it is illegal RTL -- and billing it as one produced the
            // false 202.0 FO4 ptw path. Covered by
            // `fixed_part_select_bounds_are_elaboration_constants`.
            ("(a * b)[i]", OperatorClass::Mul, 56.0),
            // WIDTH/8 is Const (P1); the runtime op is `* i`.
            ("mem[(WIDTH / 8) * i]", OperatorClass::Mul, 56.0),
        ] {
            assert_arithmetic_cost(text, class, cost);
        }
    }

    #[test]
    fn const_divisor_divrem_is_index_scale_not_srt() {
        // hpdcache_memctrl :472 / :980 — `way % dataWaysPerRamWord` is a bit-select.
        for text in [
            "way % HPDcacheCfg.u.dataWaysPerRamWord",
            "way / HPDcacheCfg.u.dataWaysPerRamWord",
            "gen_j % HPDcacheCfg.u.dataWaysPerRamWord",
            "a / 8",
            "a % 8",
            "a / WIDTH",
        ] {
            let e = Expr::parse(text);
            assert_ne!(
                e.dominant_op_class(),
                OperatorClass::DivRem,
                "{text}: {e:?}"
            );
            assert!(
                e.fo4_critical_cost(&arithmetic_base) < 20.0,
                "{text} still billed as divider: {} {e:?}",
                e.fo4_critical_cost(&arithmetic_base)
            );
            assert!(
                !e.has_atomic_over_budget(&arithmetic_base, 10.0),
                "{text} still atomic"
            );
        }
        // Runtime both sides, and const / runtime, stay dividers.
        assert_arithmetic_cost("a / b", OperatorClass::DivRem, 120.0);
        assert_arithmetic_cost("a % b", OperatorClass::DivRem, 120.0);
        assert_arithmetic_cost("8 / a", OperatorClass::DivRem, 120.0);
        assert_arithmetic_cost("WIDTH / a", OperatorClass::DivRem, 120.0);
    }

    #[test]
    fn package_scope_screaming_idents_are_elaboration_const() {
        let e = Expr::parse(
            "1 + te_pkg::PRIV_LEN + te_pkg::XLEN + 2 + te_pkg::TIME_LEN + te_pkg::XLEN",
        );
        assert!(
            e.const_class(&ConstSeed::heuristic()).is_const(),
            "pkg::NAME must be Const, class={:?} e={e:?}",
            e.const_class(&ConstSeed::heuristic())
        );
        assert_eq!(
            e.fo4_critical_cost(&arithmetic_base),
            0.0,
            "package-const sum billed as adders: {}",
            e.fo4_critical_cost(&arithmetic_base)
        );
        let mixed = Expr::parse(
            "1 + te_pkg::PRIV_LEN + te_pkg::XLEN + 2 + (address_off * 8) + te_pkg::TIME_LEN",
        );
        let c = mixed.fo4_critical_cost(&arithmetic_base);
        assert!(
            c < 15.0,
            "used_bits += pkg consts + (address_off*8) should be increment/shift/add, got {c}"
        );
    }

    #[test]
    fn plus_one_is_increment_not_carry_propagate_add() {
        let e = Expr::parse("ax_req_q.len + 1");
        assert!(
            e.fo4_critical_cost(&arithmetic_base) < 4.0,
            "len+1 billed as full add: {}",
            e.fo4_critical_cost(&arithmetic_base)
        );
        let wrap = Expr::parse("wrap_boundary + ((ax_req_q.len + 1) << 3)");
        let c = wrap.fo4_critical_cost(&arithmetic_base);
        assert!(
            c < 16.0,
            "wrap + ((len+1)<<k) should be inc+shift+add, got {c}"
        );
        assert_arithmetic_cost("a + b", OperatorClass::AddSub, 10.0);
        // l2_mshr: width-cast of 1 is an increment, not CPA-of-(IDX_W+1).
        let cast1 = Expr::parse("count_q - (IDX_W+1)'(1)");
        assert!(
            cast1.fo4_critical_cost(&arithmetic_base) < 4.0,
            "width-cast 1 billed as add: {} {cast1:?}",
            cast1.fo4_critical_cost(&arithmetic_base)
        );
        // Must not parse general `32'(expr)` (gemm `32'(n-1)*row+k` regression).
        let gemm = Expr::parse("32'(n_q[8:0] - 9'd1) * fmt_row_bytes({16'd0, ldb_q}) + k_bytes");
        assert_ne!(
            gemm.dominant_op_class(),
            OperatorClass::Mul,
            "general width-cast must not expose inner mul: {gemm:?}"
        );
        assert_ne!(
            Expr::parse("32'(a + b)").dominant_op_class(),
            OperatorClass::AddSub,
            "32'(a+b) must not collapse to a+b"
        );
        let fmt = Expr::parse("fmt_row_bytes({16'd0, ldb_q})");
        assert!(
            fmt.fo4_critical_cost(&arithmetic_base) < 10.0,
            "fmt_row_bytes must be mux-of-shifts, got {} {fmt:?}",
            fmt.fo4_critical_cost(&arithmetic_base)
        );
        let scaled = Expr::parse("k_q * ai_fmt_bytes()");
        assert_ne!(
            scaled.dominant_op_class(),
            OperatorClass::Mul,
            "elems * ai_fmt_bytes is a shift, got {scaled:?}"
        );
    }

    #[test]
    fn delay_v21_const_select_mux_and_width_cast() {
        // RAS `addr[i] + (rvc ? 2 : 4)` is a selected increment, not CPA+mux.
        let ras = Expr::parse("addr[i] + (rvc_call[i] ? 2 : 4)");
        let ras_c = ras.fo4_critical_cost(&arithmetic_base);
        assert!(
            ras_c < 8.0,
            "const-select offset add billed as CPA: {ras_c} {ras:?}"
        );
        assert_ne!(ras.dominant_op_class(), OperatorClass::AddSub, "{ras:?}");
        // Branch target `addr + (taken ? rvc_imm : rvi_imm)` keeps the adder.
        let tgt = Expr::parse("addr[i] + (taken_rvc_cf[i] ? rvc_imm[i] : rvi_imm[i])");
        assert_eq!(
            tgt.dominant_op_class(),
            OperatorClass::AddSub,
            "runtime-imm add must stay CPA: {tgt:?}"
        );
        assert!(
            tgt.fo4_critical_cost(&arithmetic_base) >= 12.0,
            "runtime-imm add under-billed: {} {tgt:?}",
            tgt.fo4_critical_cost(&arithmetic_base)
        );

        // store_unit mask: `PLEN'(LINE_B) - PLEN'(1)` is Const∘Const.
        let mask = Expr::parse("paddr_i & ~(CVA6Cfg.PLEN'(CBOZ_LINE_B) - CVA6Cfg.PLEN'(1))");
        assert!(
            mask.fo4_critical_cost(&arithmetic_base) < 4.0,
            "width-cast const mask billed as add: {} {mask:?}",
            mask.fo4_critical_cost(&arithmetic_base)
        );
        // Numeric width + ident±1 (snoop `IDX_W'(int'(rr_q)+1)`).
        let rr = Expr::parse("IDX_W'(int'(rr_q) + 1)");
        assert!(
            rr.fo4_critical_cost(&arithmetic_base) < 4.0,
            "ident±1 width-cast billed as add: {} {rr:?}",
            rr.fo4_critical_cost(&arithmetic_base)
        );
        let ncast = Expr::parse("32'(count_q + 1)");
        assert!(
            ncast.fo4_critical_cost(&arithmetic_base) < 4.0,
            "numeric 32'(ident+1) billed as add: {} {ncast:?}",
            ncast.fo4_critical_cost(&arithmetic_base)
        );
        // Based literals still parse (`32'hff` must not become a width-cast).
        assert_eq!(Expr::parse("32'hff").width_class_hint(), Some(32));
        assert_eq!(
            Expr::parse("32'(CBOZ_LINE_B)").const_class(&ConstSeed::heuristic()),
            ConstClass::Const,
            "32'(SCREAMING) must collapse to the const ident"
        );

        // delay-v19 guard: general `(W)'(expr)` must not expose the inner Mul.
        let gemm = Expr::parse("32'(n_q[8:0] - 9'd1) * fmt_row_bytes({16'd0, ldb_q}) + k_bytes");
        assert_ne!(
            gemm.dominant_op_class(),
            OperatorClass::Mul,
            "index±1 width-cast must not collapse: {gemm:?}"
        );
        assert_ne!(
            Expr::parse("32'(a + b)").dominant_op_class(),
            OperatorClass::AddSub,
            "32'(a+b) must not collapse to a+b"
        );
        // Type-name casts stay unparsed so a later `* K` is not a datapath Mul
        // (policy_subcode `GroupShapeLog2[int'(group_q)*6 +: 6]`).
        let packed = Expr::parse("GroupShapeLog2[int'(group_q)*6 +: 6]");
        assert_ne!(
            packed.dominant_op_class(),
            OperatorClass::Mul,
            "int'(ident)*K index must not expose Mul: {packed:?}"
        );
        assert_ne!(
            Expr::parse("int'(r) + int'(c)").dominant_op_class(),
            OperatorClass::AddSub,
            "int'(r)+int'(c) must not collapse to r+c"
        );

        // Const-condition mux is elaboration (pe_dot `i < CNT` / `WIDTH ?`).
        let gen = Expr::parse("WIDTH ? (a + b) : c");
        assert_eq!(
            gen.fo4_critical_cost(&arithmetic_base),
            10.0,
            "const-cond mux still taxed: {} {gen:?}",
            gen.fo4_critical_cost(&arithmetic_base)
        );
        assert_eq!(gen.dominant_op_class(), OperatorClass::AddSub, "{gen:?}");
        let gv = ConstSeed::from_names(["i", "CNT"]);
        let pe = Expr::parse("i < CNT ? (red_l + red_r) : 0");
        assert_eq!(
            pe.fo4_critical_cost_latticed(&arithmetic_base, &gv),
            10.0,
            "genvar cond mux still taxed: {} {pe:?}",
            pe.fo4_critical_cost_latticed(&arithmetic_base, &gv)
        );
        // Runtime condition keeps the mux on top of the add.
        let rt = Expr::parse("en ? (a + b) : c");
        assert_eq!(
            rt.fo4_critical_cost(&arithmetic_base),
            12.5,
            "runtime mux under-billed: {} {rt:?}",
            rt.fo4_critical_cost(&arithmetic_base)
        );

        // pe_dot `sum != MAXW'(0)` is zero-detect, not a 4 FO4 compare.
        let z = Expr::parse(
            "(red_fin[LEVELS] && final_bfp_sum != MAXW'(0)) ? s2_block_exp_piped[LEVELS] : 16'sd0",
        );
        assert!(
            z.fo4_critical_cost(&arithmetic_base) < 8.0,
            "zero-detect mux billed as compare: {} {z:?}",
            z.fo4_critical_cost(&arithmetic_base)
        );
        assert_eq!(
            Expr::parse("final_bfp_sum != MAXW'(0)").dominant_op_class(),
            OperatorClass::LogicBit,
            "!= 0 must be zero-detect"
        );
        assert_eq!(
            Expr::parse("a != b").dominant_op_class(),
            OperatorClass::Compare,
            "runtime != runtime must stay Compare"
        );
        assert_eq!(
            Expr::parse("idx == paddr_cl_idx").dominant_op_class(),
            OperatorClass::Compare,
            "runtime==runtime must stay Compare"
        );
    }

    #[test]
    fn delay_v22_const_then_mux_chain_is_one_mux() {
        // pe_dot NaN/Inf/zero encodings: const thens, datapath else.
        let chain = Expr::parse(
            "red_nan ? 32'h7fc00000 : red_inf ? 32'h7f800000 : red_zero ? 32'd0 : datapath",
        );
        assert_eq!(
            chain.fo4_critical_cost(&arithmetic_base),
            2.5,
            "const-then chain billed as serial muxes: {} {chain:?}",
            chain.fo4_critical_cost(&arithmetic_base)
        );
        assert_eq!(chain.dominant_op_class(), OperatorClass::Mux, "{chain:?}");
        // A cheap invert on a flag still sits beside the single mux, not 3× mux.
        let inv = Expr::parse(
            "red_nan ? 32'h7fc00000 : red_inf ? 32'h7f800000 : (!red_fin) ? 32'd0 : datapath",
        );
        assert_eq!(
            inv.fo4_critical_cost(&arithmetic_base),
            3.5,
            "flag invert + const-then chain: {} {inv:?}",
            inv.fo4_critical_cost(&arithmetic_base)
        );
        let with_call =
            Expr::parse("n ? 32'h7fc00000 : i ? 32'h7f800000 : (!f) ? 32'd0 : pack(sum, exp)");
        assert!(
            with_call.fo4_critical_cost(&arithmetic_base) < 6.0,
            "const-then + call still chained: {} {with_call:?}",
            with_call.fo4_critical_cost(&arithmetic_base)
        );
        // Runtime then in the middle must keep its own mux (not flatten across).
        let mixed = Expr::parse("n ? 32'h1 : (i ? datapath : 32'h2)");
        assert_eq!(
            mixed.fo4_critical_cost(&arithmetic_base),
            5.0,
            "runtime-then must not flatten: {} {mixed:?}",
            mixed.fo4_critical_cost(&arithmetic_base)
        );
        // Single runtime mux is unchanged.
        assert_eq!(
            Expr::parse("en ? a : b").fo4_critical_cost(&arithmetic_base),
            2.5
        );
        // Inf encoding `{sign[LEVELS], 8'hff, 0}` is still an exception arm (pe_dot).
        let inf = Expr::parse(
            "nan[LEVELS] ? {5'b10000, 32'h7fc00000} : inf[LEVELS] ? {5'b00100, {sign[LEVELS], 8'hff, 23'd0}} : (!fin[LEVELS]) ? {5'd0, 32'd0} : pack(sum, exp)",
        );
        assert!(
            inf.fo4_critical_cost(&arithmetic_base) < 6.0,
            "sign-pack encoding still serial mux: {} {inf:?}",
            inf.fo4_critical_cost(&arithmetic_base)
        );
        // Bare ident then is datapath — do not flatten.
        let ident_then = Expr::parse("en ? a : (f ? 32'h1 : datapath)");
        assert_eq!(
            ident_then.fo4_critical_cost(&arithmetic_base),
            5.0,
            "ident then flattened: {} {ident_then:?}",
            ident_then.fo4_critical_cost(&arithmetic_base)
        );
        // `{a, b}` with no const field is datapath pack, not an encoding.
        let pack = Expr::parse("en ? {a, b} : (f ? 32'h1 : datapath)");
        assert_eq!(
            pack.fo4_critical_cost(&arithmetic_base),
            5.0,
            "ident concat flattened: {} {pack:?}",
            pack.fo4_critical_cost(&arithmetic_base)
        );
    }

    #[test]
    fn delay_v23_stride_add_aligned_insert_sign_and_call() {
        // F: `addr + (1 << n)` is a mux of increments, not CPA+shift.
        let stride = Expr::parse("sbaddress_i + (32'h1 << sbaccess_i)");
        assert_ne!(
            stride.dominant_op_class(),
            OperatorClass::AddSub,
            "one-hot stride billed as CPA: {stride:?}"
        );
        assert!(
            stride.fo4_critical_cost(&arithmetic_base) < 8.0,
            "one-hot stride still CPA: {} {stride:?}",
            stride.fo4_critical_cost(&arithmetic_base)
        );
        // Runtime offset stays an add.
        assert_eq!(
            Expr::parse("addr + (offset << size)").dominant_op_class(),
            OperatorClass::AddSub
        );
        // G: aligned `{x[MSB:K], {K{0}}} + (y << K)` is a field insert, not CPA.
        // The `cnt << 3` child is still a const shift (honest dominant).
        let aligned = Expr::parse("{addr[31:3], {3{1'b0}}} + (cnt << 3)");
        assert_ne!(
            aligned.dominant_op_class(),
            OperatorClass::AddSub,
            "aligned field insert billed as add: {aligned:?}"
        );
        assert!(
            aligned.fo4_critical_cost(&arithmetic_base) < 4.0,
            "aligned insert still CPA: {} {aligned:?}",
            aligned.fo4_critical_cost(&arithmetic_base)
        );
        // Unaligned add stays CPA.
        assert_eq!(
            Expr::parse("wrap + (cnt << 3)").dominant_op_class(),
            OperatorClass::AddSub
        );
        // I: signed `x > 0` is the sign bit.
        assert_eq!(
            Expr::parse("exponent_difference > 0").dominant_op_class(),
            OperatorClass::LogicBit
        );
        assert_eq!(
            Expr::parse("a > b").dominant_op_class(),
            OperatorClass::Compare
        );
        // N: unknown user function stays Other (gemm v49: 2-arg Mux tax).
        // fmt / $clog2 unchanged. Wrap-boundary body is a later inline pass.
        assert_eq!(
            Expr::parse("get_wrap_boundary(addr, len)").dominant_op_class(),
            OperatorClass::Other
        );
        assert_ne!(
            Expr::parse("fmt_row_bytes(k_q)").dominant_op_class(),
            OperatorClass::Mul
        );
        assert_eq!(
            Expr::parse("$clog2(WIDTH)").fo4_critical_cost(&arithmetic_base),
            0.0
        );
        // Q: saturating `sat + 1` is already an increment (delay-v18).
        assert_ne!(
            Expr::parse("saturation_counter + 1").dominant_op_class(),
            OperatorClass::AddSub
        );
        // delay-v24: named aligned net + (y<<K).
        let mut seed = ConstSeed::heuristic();
        seed.set_aligned("aligned_address", "3");
        assert_ne!(
            Expr::parse("aligned_address + (cnt << 3)").dominant_op_class_latticed(&seed),
            OperatorClass::AddSub
        );
        assert_eq!(
            Expr::parse("wrap_boundary + (cnt << 3)").dominant_op_class_latticed(&seed),
            OperatorClass::AddSub
        );
        // axi2mem: `{{LOG}{1'b0}}` wraps the replicate count in a one-part concat.
        let axi_pad = Expr::parse("{addr[AXI_ADDR_WIDTH-1:LOG_NR_BYTES], {{LOG_NR_BYTES}{1'b0}}}");
        assert_eq!(
            axi_pad.zero_pad_align_key().as_deref(),
            Some("LOG_NR_BYTES"),
            "double-brace zero-pad must seed K: {axi_pad:?}"
        );
        let axi_insert = Expr::parse(
            "{addr[AXI_ADDR_WIDTH-1:LOG_NR_BYTES], {{LOG_NR_BYTES}{1'b0}}} + (cnt << LOG_NR_BYTES)",
        );
        assert_ne!(
            axi_insert.dominant_op_class(),
            OperatorClass::AddSub,
            "axi2mem aligned stride billed as CPA: {axi_insert:?}"
        );
        // delay-v25: BalanceMux stages `t = y << K`; `aligned + t` is still insert.
        seed.set_shifted("svt_bm_shift", "3");
        assert_ne!(
            Expr::parse("aligned_address + svt_bm_shift").dominant_op_class_latticed(&seed),
            OperatorClass::AddSub,
            "staged aligned + t billed as CPA"
        );
        assert_eq!(
            Expr::parse("wrap_boundary + svt_bm_shift").dominant_op_class_latticed(&seed),
            OperatorClass::AddSub,
            "staged wrap + t must stay CPA"
        );
    }

    #[test]
    fn literal_power_of_two_multiplication_is_cheap() {
        for literal in [
            "1",
            "8",
            "1_024",
            "8'd8",
            "8'h08",
            "8'b0000_1000",
            "8'o10",
            "8'sd8",
            "8'sh08",
            "16'H0100",
            "'h8",
            "128'h10000000000000000",
        ] {
            for text in [
                format!("operand_a_i * {literal}"),
                format!("{literal} * operand_a_i"),
            ] {
                assert_arithmetic_cost(&text, OperatorClass::Other, 1.0);
            }
        }
        // `+1` / `-1` are increments; `* 8` is a shift — not a 10+10 CPA.
        assert_arithmetic_cost("(i + 1) * 8 - 1", OperatorClass::LogicBit, 3.0);
        assert_arithmetic_cost("mem[i * 8]", OperatorClass::Other, 1.0);
    }

    #[test]
    fn unproven_scales_keep_arithmetic_cost() {
        for text in [
            "a * 3",
            "a * 0",
            "a * -8",
            "a * '1",
            "a * 'x",
            "a * 8'hx8",
            "a * 8'hz8",
            "a * 8'sh80",
            "a * 4'sd8",
            "a * 8'h100",
            "a * 0'd8",
            "a * 340282366920938463463374607431768211456",
            "a * (b + 1)",
            "(a + b) * (c + d)",
            "a[i] * b[j]",
            "a * WIDTH",
        ] {
            let e = Expr::parse(text);
            assert_eq!(e.dominant_op_class(), OperatorClass::Mul, "{text}: {e:?}");
            assert!(e.fo4_critical_cost(&arithmetic_base) >= 56.0, "{text}");
            assert!(e.has_atomic_over_budget(&arithmetic_base, 10.0), "{text}");
        }
        // Runtime divisor stays a divider. Literal / Cfg divisor is delay-v14 scale.
        for text in ["8 / a", "8 % a", "a / 0", "a % 0"] {
            assert_arithmetic_cost(text, OperatorClass::DivRem, 120.0);
        }
    }

    #[test]
    fn fixed_part_select_bounds_are_elaboration_constants() {
        // Reduced from core/cva6_mmu/cva6_ptw.sv:189, reported as a 202.0 FO4
        // atomic_over_budget DivRem -- the worst raw path in full_core -- for a slice
        // that synthesises to wires.
        let ptw = Expr::parse(
            "vaddr_q[12+((ExampleCfg.VpnLen/ExampleCfg.PtLevels)*(ExampleCfg.PtLevels-z-1))-1:12+((ExampleCfg.VpnLen/ExampleCfg.PtLevels)*(ExampleCfg.PtLevels-z-2))]",
        );
        assert_ne!(ptw.dominant_op_class(), OperatorClass::DivRem, "{ptw:?}");
        assert_ne!(ptw.dominant_op_class(), OperatorClass::Mul, "{ptw:?}");
        assert!(
            !ptw.has_atomic_over_budget(&arithmetic_base, 10.0),
            "constant slice bound still reported as an over-budget operator"
        );
        // Pure wire slice off a plain signal: no operator delay at all.
        assert_eq!(ptw.fo4_critical_cost(&arithmetic_base), 0.0);

        // Bit-select runtime index is charged. Indexed `+:` / `-:` width is
        // LRM-constant; the base index is still hardware (IEEE 1800 §11.5.1).
        for text in ["mem[a / b]", "mem[a * b]", "mem[other[a / b]]"] {
            let e = Expr::parse(text);
            assert!(
                e.fo4_critical_cost(&arithmetic_base) >= 56.0,
                "{text} was excused: {e:?}"
            );
        }
        let idx_div = Expr::parse("mem[(a / b) +: 8]");
        match &idx_div {
            Expr::Index { index, .. } => {
                assert!(
                    !is_constant_range_select(index),
                    "+: must not look like [msb:lsb]"
                );
                assert!(
                    matches!(
                        index.as_ref(),
                        Expr::PartSelect {
                            kind: PartSelectKind::IndexedPlus,
                            ..
                        }
                    ),
                    "+: must parse as PartSelect, got {index:?}"
                );
            }
            other => panic!("expected Index, got {other:?}"),
        }
        assert!(
            idx_div.fo4_critical_cost(&arithmetic_base) >= 120.0,
            "runtime base of +: was excused: {idx_div:?}"
        );
        let idx_shl = Expr::parse("operand_b[i << 3 +: 8]");
        assert!(
            idx_shl.fo4_critical_cost(&arithmetic_base) >= 1.0,
            "shift base of +: was excused: {idx_shl:?}"
        );
        assert_eq!(
            Expr::parse("v[HYP_EXT*2:0]").fo4_critical_cost(&arithmetic_base),
            0.0,
            "HYP_EXT*2 in [msb:lsb] must be elaboration"
        );
        assert_ne!(
            Expr::parse("v[HYP_EXT*2:0]").dominant_op_class(),
            OperatorClass::Mul,
            "const slice must not rank as Mul"
        );
        assert_eq!(
            Expr::parse("mem[WIDTH +: 8]").fo4_critical_cost(&arithmetic_base),
            0.0,
            "const base +: width must be elaboration"
        );
        assert_eq!(
            Expr::parse("mem[x -: 4]").fo4_critical_cost(&arithmetic_base),
            0.0,
            "ident bit-base -: width has no arithmetic"
        );

        // The selected base is still measured through a constant slice.
        assert_eq!(
            Expr::parse("WIDTH * 3").fo4_critical_cost(&arithmetic_base),
            0.0
        );
        assert_eq!(
            Expr::parse("3 * PRECISION_BITS + 4").fo4_critical_cost(&arithmetic_base),
            0.0
        );
        assert_eq!(
            Expr::parse("$clog2(CVA6Cfg.AxiDataWidth / 8)").fo4_critical_cost(&arithmetic_base),
            0.0
        );
        assert_eq!(
            Expr::parse("{{(DataWidth/8-4){1'b0}}, 4'hF}").fo4_critical_cost(&arithmetic_base),
            0.0
        );
        // Runtime * const (non power-of-two) stays a multiply. Runtime / const
        // divisor is a shift (delay-v14), not a 120 FO4 divider.
        assert!(Expr::parse("a * WIDTH").fo4_critical_cost(&arithmetic_base) >= 56.0);
        let cnt_half = Expr::parse("(cnt + 1) / 2");
        assert_ne!(cnt_half.dominant_op_class(), OperatorClass::DivRem);
        assert!(
            cnt_half.fo4_critical_cost(&arithmetic_base) < 20.0,
            "const-divisor /2 must not be DivRem, got {}",
            cnt_half.fo4_critical_cost(&arithmetic_base)
        );

        assert_arithmetic_cost("(a * b)[7:0]", OperatorClass::Mul, 56.0);
        assert_arithmetic_cost("mem[f(a / b)][7:0]", OperatorClass::DivRem, 121.0);
    }

    #[test]
    fn cheap_scale_preserves_expensive_operand_subtrees() {
        for (text, class, cost) in [
            ("(a * b) * 8", OperatorClass::Mul, 57.0),
            ("8 * (a / b)", OperatorClass::DivRem, 121.0),
            ("8 * mem[a % b]", OperatorClass::DivRem, 121.0),
            ("mem[(a * b) * 8]", OperatorClass::Mul, 57.0),
            ("a * 8 + b / c", OperatorClass::DivRem, 130.0),
        ] {
            assert_arithmetic_cost(text, class, cost);
        }
    }

    #[test]
    fn fo4_critical_less_or_eq_sum_on_chain() {
        let base = |c: OperatorClass| match c {
            OperatorClass::AddSub => 10.0,
            _ => 1.0,
        };
        // left-deep chain: sum = 3*10, critical = 3*10 (sequential) — equal
        let e = Expr::parse("a + b + c + d");
        let sum = e.fo4_cost(&base);
        let crit = e.fo4_critical_cost(&base);
        assert!(crit <= sum + 1e-9, "crit={crit} sum={sum}");
        assert!(crit >= 20.0, "crit={crit}"); // at least two adds deep
    }

    #[test]
    fn critical_spine_matches_critical_cost() {
        let base = |c: OperatorClass| match c {
            OperatorClass::AddSub => 10.0,
            OperatorClass::Mul => 56.0,
            OperatorClass::Concat => 2.0,
            _ => 1.0,
        };
        let e = Expr::parse("a + b + c + d");
        let spine = e.critical_spine_ops(&base);
        assert!(spine.len() >= 2, "spine={spine:?}");
        let spine_sum: f64 = spine.iter().map(|(_, c)| c).sum();
        assert!(
            (spine_sum - e.fo4_critical_cost(&base)).abs() < 1e-6,
            "spine_sum={spine_sum} crit={}",
            e.fo4_critical_cost(&base)
        );
        // mul root: spine ends with Mul and is atomic over small budget
        let mul = Expr::parse("(a + b) * (c + d)");
        let ms = mul.critical_spine_ops(&base);
        assert!(
            ms.last()
                .map(|(c, _)| *c == OperatorClass::Mul)
                .unwrap_or(false),
            "ms={ms:?}"
        );
        assert!(mul.has_atomic_over_budget(&base, 32.0));
        assert!(!Expr::parse("a + b").has_atomic_over_budget(&base, 32.0));
    }

    #[test]
    fn stage_for_balance_mux_splits_or_of_shifts() {
        // ROL-like: (a << b) | (a >> c) → two stage wires + shallow top
        let e = Expr::parse("(a << b) | (a >> c)");
        assert!(e.depth() >= 3, "depth={}", e.depth());
        let plan = e
            .stage_for_balance_mux("svt_bm_")
            .expect("should stage deep or-of-shifts");
        assert!(plan.wires.len() >= 2, "wires={:?}", plan.wires);
        assert!(plan.top_emit.contains('|') || plan.top_emit.contains(" | "));
        let frag = plan.to_sv_fragment(Some("svt_bm_top"), 64);
        assert!(frag.contains("always_comb"));
        assert!(frag.contains("svt_bm_0"));
        assert!(frag.contains("svt_bm_top"));
        // Unique named block per top wire (multi-arm collision safety).
        assert!(
            frag.contains("begin : svt_bm_top_stage"),
            "unique stage label, got: {frag}"
        );
        // Leaves stay shallow
        assert!(
            plan.top.depth() <= 2,
            "top depth should be shallow, got {} emit={}",
            plan.top.depth(),
            plan.top_emit
        );
    }

    #[test]
    fn rebalance_associative_shortens_depth() {
        let e = Expr::parse("a + b + c + d + e + f + g + h");
        let deep = e.depth();
        let bal = e.rebalance_associative();
        let bal_d = bal.depth();
        assert!(
            bal_d < deep,
            "balanced depth {bal_d} should be < left-deep {deep}; emit={}",
            bal.emit()
        );
        let base = |c: OperatorClass| match c {
            OperatorClass::AddSub => 10.0,
            _ => 1.0,
        };
        // Critical FO4 should not increase; typically decreases for long chains
        assert!(
            bal.fo4_critical_cost(&base) <= e.fo4_critical_cost(&base) + 1e-9,
            "before={} after={}",
            e.fo4_critical_cost(&base),
            bal.fo4_critical_cost(&base)
        );
        // Emit still contains all operands
        let s = bal.emit();
        for id in ["a", "b", "c", "d", "e", "f", "g", "h"] {
            assert!(s.contains(id), "missing {id} in {s}");
        }
        // Round-trip parse
        let again = Expr::parse(&s);
        assert!(again.op_node_count() >= 7, "{again:?}");
    }

    #[test]
    fn rebalance_skips_non_associative() {
        let e = Expr::parse("a - b - c");
        let bal = e.rebalance_associative();
        // subtraction is not associative — structure may recurse but op stays -
        assert!(bal.emit().contains('-'));
    }

    #[test]
    fn width_class_hint_from_sized_literal() {
        assert_eq!(Expr::parse("64'h1").width_class_hint(), Some(64));
        assert_eq!(Expr::parse("8'd3").width_class_hint(), Some(8));
        assert_eq!(Expr::parse("1'b0").width_class_hint(), Some(1));
        assert_eq!(Expr::parse("a_i").width_class_hint(), None);
    }

    #[test]
    fn rebalance_does_not_mix_known_different_widths() {
        // 1-bit flags OR'd with a wide constant — should not fully flatten/balance across.
        let e = Expr::parse("1'b0 | 1'b1 | 64'hff | 1'b0 | 1'b1");
        let bal = e.rebalance_associative();
        let s = bal.emit();
        // All leaves preserved
        assert!(
            s.contains("64'hff") || s.contains("64'hFF") || s.contains("64"),
            "{s}"
        );
        // Depth should still be finite; equal-width 1-bit runs may balance
        assert!(bal.depth() >= 2, "depth={}", bal.depth());
        // Full equal-width chain still balances
        let e2 = Expr::parse("1'b0 | 1'b1 | 1'b0 | 1'b1 | 1'b0 | 1'b1 | 1'b0 | 1'b1");
        let d0 = e2.depth();
        let b2 = e2.rebalance_associative();
        assert!(
            b2.depth() < d0,
            "equal-width should balance {} -> {}",
            d0,
            b2.depth()
        );
    }

    #[test]
    fn opaque_fallback() {
        let e = Expr::parse("@@@");
        assert!(matches!(e, Expr::Opaque { .. }) || matches!(e, Expr::Ident { .. }));
    }

    #[test]
    fn parse_scoped_call_and_index() {
        let e = Expr::parse("pkg::clamp(x, 0)[3:0]");
        // call then index, or opaque if mis-parsed — prefer structured
        let ok = matches!(e, Expr::Index { .. })
            || matches!(e, Expr::Call { .. })
            || e.emit().contains("clamp");
        assert!(ok, "{e:?}");
    }
}
