// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Operand width inference and normalized FO4 width scaling.
//!
//! `fo4-v1` table values are the cost **at the reference width 32**
//! (`architecture/OPTIMIZATION-LEVELS.md` §1.1(2), `DESIGN.md` §3). Until this
//! module existed every node carried `width: 1, width_defaulted: true` and a
//! 4-bit FIFO pointer increment was billed like a 32-bit adder — the whole 10
//! FO4 budget — while a 64-bit datapath add was billed the same 10.
//!
//! Scaling laws (measured 2026-10-16 on Nangate45 with the fork's `sta`,
//! structure-preserving ABC `&nf -D`; ratios against the 32-bit cell):
//!
//! | Class | Law | Measured w=4/8/16/32/64 |
//! |---|---|---|
//! | `add_sub`, `compare`, `shift_var` | `log2(max(w,2)) / log2(32)` | `<`: 0.41/0.52/0.92/1.0/1.09 — `<<`: 0.45/0.68/0.81/1.0/1.19 — law: 0.4/0.6/0.8/1.0/1.2 |
//! | `mul`, `div_rem` | `w / 32` | `*`: 0.15/0.37/0.62/1.0 — the planned `(w/32)²` is area-like and rejected |
//! | `logic_bit`, `mux`, `priority_mux`, `concat`, `shift_const`, `other` | `1` | `&`: flat at every width |
//!
//! Adders came out log-depth only under the delay-oriented ABC script
//! (0.617/0.770 ns at 32/64 bits); Yosys's default liberty script collapses the
//! Brent–Kung carry tree to ripple (0.905/1.786 ns). The model assumes the
//! former — a mapping flow that produces ripple carries misses it, and that is
//! the flow's defect, not a reason to bill a 4-bit counter as 32 bits.
//!
//! Every scaled cost is floored at `logic_bit`. A node whose width cannot be
//! resolved keeps the reference-width cost (`width_defaulted: true`), so an
//! unknown is never cheaper than before.
//!
//! Context rules (IEEE 1800-2017 §11.6, §11.8): arithmetic is costed at the
//! max of the LHS width and its operand widths; a relational / equality
//! operator is self-determined by its operands, never by the (1-bit) LHS.

use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};

use crate::expr::{Expr, PartSelectKind};
use crate::ir::{DeclSite, ModulePort, OperatorClass, TimingModule, TimingPackage};

/// The width the `fo4-v1` table values are quoted at.
pub const REF_WIDTH: u32 = 32;

/// Multiplier applied to a class's reference-width cost for `width`.
pub fn width_factor(class: OperatorClass, width: Option<u32>) -> f64 {
    let Some(w) = width else {
        return 1.0;
    };
    match class {
        OperatorClass::AddSub | OperatorClass::Compare | OperatorClass::ShiftVar => {
            (f64::from(w.max(2))).log2() / f64::from(REF_WIDTH).log2()
        }
        OperatorClass::Mul | OperatorClass::DivRem => f64::from(w.max(1)) / f64::from(REF_WIDTH),
        _ => 1.0,
    }
}

/// Per-node widths: the arithmetic context and the comparison operand width.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct NodeWidths {
    /// `max(lhs, arithmetic operands)` — None when nothing resolved.
    pub arith: Option<u32>,
    /// Widest resolved operand of a relational / equality operator.
    pub compare: Option<u32>,
}

impl NodeWidths {
    /// Width to scale `class` with. A Compare-billed incrementer (`x + 1`,
    /// `billed_binary_class`) has no relational operands; it spans the
    /// arithmetic context, so Compare falls back to `arith` when no relational
    /// operand was seen.
    pub fn for_class(&self, class: OperatorClass) -> Option<u32> {
        match class {
            OperatorClass::Compare => self.compare.or(self.arith),
            OperatorClass::AddSub
            | OperatorClass::ShiftVar
            | OperatorClass::Mul
            | OperatorClass::DivRem => self.arith,
            _ => None,
        }
    }
}

/// Dimensions of a declared signal: packed dims outer→inner (bits each) and
/// the number of unpacked dims.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Dims {
    packed: Vec<u32>,
    unpacked: usize,
}

impl Dims {
    fn bits(&self) -> u32 {
        self.packed
            .iter()
            .copied()
            .fold(1u32, |a, b| a.saturating_mul(b))
    }
    /// One `[i]` applied: strips an unpacked dim first, else the outer packed dim.
    fn indexed(&self) -> Dims {
        if self.unpacked > 0 {
            return Dims {
                packed: self.packed.clone(),
                unpacked: self.unpacked - 1,
            };
        }
        if self.packed.len() > 1 {
            return Dims {
                packed: self.packed[1..].to_vec(),
                unpacked: 0,
            };
        }
        Dims {
            packed: vec![1],
            unpacked: 0,
        }
    }
}

/// Width/constant resolver for one module.
pub struct WidthResolver<'a> {
    packages: &'a BTreeMap<String, TimingPackage>,
    param_ints: &'a BTreeMap<String, i64>,
    decls: &'a [DeclSite],
    ports: &'a [ModulePort],
    const_exprs: &'a BTreeMap<String, String>,
    typedef_texts: &'a BTreeMap<String, String>,
    package_imports: &'a [String],
    /// Elaborated widths for this module (`--width-map`), when supplied.
    elaborated: Option<&'a BTreeMap<String, u32>>,
    consts: RefCell<BTreeMap<String, Option<i64>>>,
    visiting: RefCell<BTreeSet<String>>,
}

const MAX_DEPTH: u32 = 12;

impl<'a> WidthResolver<'a> {
    /// Resolver over `module`'s declarations with the design's packages and
    /// the host param-map integers as outer constant scopes.
    pub fn new(
        module: &'a TimingModule,
        packages: &'a BTreeMap<String, TimingPackage>,
        param_ints: &'a BTreeMap<String, i64>,
    ) -> Self {
        Self::from_parts(
            packages,
            param_ints,
            &module.decls,
            &module.ports,
            &module.const_exprs,
            &module.typedef_texts,
            &module.package_imports,
            None,
        )
    }

    /// Split-borrow constructor (the caller may hold `&mut module.nodes`).
    pub fn from_parts(
        packages: &'a BTreeMap<String, TimingPackage>,
        param_ints: &'a BTreeMap<String, i64>,
        decls: &'a [DeclSite],
        ports: &'a [ModulePort],
        const_exprs: &'a BTreeMap<String, String>,
        typedef_texts: &'a BTreeMap<String, String>,
        package_imports: &'a [String],
        elaborated: Option<&'a BTreeMap<String, u32>>,
    ) -> Self {
        Self {
            packages,
            param_ints,
            decls,
            ports,
            const_exprs,
            typedef_texts,
            package_imports,
            elaborated,
            consts: RefCell::new(BTreeMap::new()),
            visiting: RefCell::new(BTreeSet::new()),
        }
    }

    fn imported_packages(&self) -> impl Iterator<Item = &'a TimingPackage> + '_ {
        self.package_imports.iter().filter_map(move |imp| {
            let key = imp.split("::").next().unwrap_or(imp);
            self.packages.get(key)
        })
    }

    /// Integer value of a parameter / localparam / param-map key.
    ///
    /// `pkg::NAME` resolves in that package; `Cfg.FIELD` resolves through the
    /// param-map (`CVA6Cfg.XLEN`), then by its last member as a bare name.
    pub fn const_value(&self, name: &str) -> Option<i64> {
        if let Some(v) = self.consts.borrow().get(name) {
            return *v;
        }
        if !self.visiting.borrow_mut().insert(name.to_string()) {
            return None;
        }
        let v = self.const_value_uncached(name);
        self.visiting.borrow_mut().remove(name);
        self.consts.borrow_mut().insert(name.to_string(), v);
        v
    }

    fn const_value_uncached(&self, name: &str) -> Option<i64> {
        if let Some(v) = self.param_ints.get(name) {
            return Some(*v);
        }
        if let Some((pkg, member)) = name.rsplit_once("::") {
            if let Some(p) = self.packages.get(pkg) {
                if let Some(text) = p.const_exprs.get(member) {
                    return self.eval_text(text);
                }
            }
            if let Some(v) = self.param_ints.get(member) {
                return Some(*v);
            }
            return None;
        }
        if name.contains('.') {
            // `Cfg.FIELD` not in the param-map: the last member alone.
            let member = name.rsplit('.').next().unwrap_or(name);
            return self.param_ints.get(member).copied();
        }
        if let Some(text) = self.const_exprs.get(name) {
            if let Some(v) = self.eval_text(text) {
                return Some(v);
            }
        }
        for p in self.imported_packages() {
            if let Some(text) = p.const_exprs.get(name) {
                if let Some(v) = self.eval_text(text) {
                    return Some(v);
                }
            }
        }
        None
    }
    /// A guard (an `if` predicate or an LHS index) is live when it reads at
    /// least one signal: a genvar index (`row[k]`), a parameter condition
    /// (`if (CVA6Cfg.RVA)`) or a constant expression is elaboration-time and
    /// costs nothing (delay-v37).
    pub fn guard_is_live(&self, text: &str) -> bool {
        if self.eval_text(text).is_some() {
            return false;
        }
        let ex = Expr::parse(text);
        let mut live = false;
        ex.walk_idents(&mut |s| {
            let base = s.split(['[', '.']).next().unwrap_or(s);
            if !base.is_empty() && !self.is_const_name(base) {
                live = true;
            }
        });
        live
    }

    /// Evaluate an elaboration-constant expression text.
    pub fn eval_text(&self, text: &str) -> Option<i64> {
        let ex = Expr::parse(text.trim());
        if ex.is_opaque() {
            return parse_sv_int(text.trim()).map(|(_, v)| v);
        }
        self.eval(&ex, 0)
    }

    fn eval(&self, e: &Expr, depth: u32) -> Option<i64> {
        if depth > MAX_DEPTH {
            return None;
        }
        match e {
            Expr::Literal { text } => parse_sv_int(text).map(|(_, v)| v),
            Expr::Ident { name } => self.const_value(name),
            Expr::Unary { op, arg } => {
                let v = self.eval(arg, depth + 1)?;
                match op.as_str() {
                    "-" => v.checked_neg(),
                    "+" => Some(v),
                    "!" => Some(i64::from(v == 0)),
                    "~" => Some(!v),
                    _ => None,
                }
            }
            Expr::Binary {
                op, left, right, ..
            } => {
                let l = self.eval(left, depth + 1)?;
                let r = self.eval(right, depth + 1)?;
                match op.as_str() {
                    "+" => l.checked_add(r),
                    "-" => l.checked_sub(r),
                    "*" => l.checked_mul(r),
                    "/" => (r != 0).then(|| l / r),
                    "%" => (r != 0).then(|| l % r),
                    "**" => u32::try_from(r).ok().and_then(|p| l.checked_pow(p)),
                    "<<" => u32::try_from(r).ok().and_then(|s| l.checked_shl(s)),
                    ">>" | ">>>" => u32::try_from(r).ok().and_then(|s| l.checked_shr(s)),
                    "<" => Some(i64::from(l < r)),
                    ">" => Some(i64::from(l > r)),
                    "<=" => Some(i64::from(l <= r)),
                    ">=" => Some(i64::from(l >= r)),
                    "==" => Some(i64::from(l == r)),
                    "!=" => Some(i64::from(l != r)),
                    "&&" => Some(i64::from(l != 0 && r != 0)),
                    "||" => Some(i64::from(l != 0 || r != 0)),
                    "&" => Some(l & r),
                    "|" => Some(l | r),
                    "^" => Some(l ^ r),
                    _ => None,
                }
            }
            Expr::Ternary {
                cond,
                then_e,
                else_e,
            } => {
                let c = self.eval(cond, depth + 1)?;
                if c != 0 {
                    self.eval(then_e, depth + 1)
                } else {
                    self.eval(else_e, depth + 1)
                }
            }
            Expr::Call { name, args } => match (name.as_str(), args.as_slice()) {
                ("$clog2", [a]) => {
                    let v = self.eval(a, depth + 1)?;
                    Some(clog2(v))
                }
                ("$bits", [a]) => self.expr_width(a).map(i64::from),
                _ => None,
            },
            _ => None,
        }
    }

    /// Bits of a declaration type text (`logic [N-1:0][7:0]`, `int`, `idx_t`,
    /// `pkg::word_t`, `enum logic [1:0] {…}`). Struct bodies are unresolved.
    pub fn type_bits(&self, type_text: &str) -> Option<u32> {
        self.type_dims(type_text, 0).map(|d| d.bits())
    }

    fn type_dims(&self, type_text: &str, depth: u32) -> Option<Dims> {
        if depth > MAX_DEPTH {
            return None;
        }
        let text = type_text.trim();
        if text.is_empty() {
            return None;
        }
        // enum base: `enum logic [1:0] {A, B}` → `logic [1:0]`; bare `enum {…}` is int.
        if let Some(rest) = text.strip_prefix("enum") {
            let head = rest.split('{').next().unwrap_or("").trim();
            if head.is_empty() {
                return Some(Dims {
                    packed: vec![32],
                    unpacked: 0,
                });
            }
            return self.type_dims(head, depth + 1);
        }
        if text.starts_with("struct") || text.starts_with("union") {
            return None;
        }
        let (head, dims_text) = split_dims(text);
        let mut words: Vec<&str> = head
            .split_whitespace()
            .filter(|w| {
                !matches!(
                    *w,
                    "signed" | "unsigned" | "var" | "automatic" | "const" | "static"
                )
            })
            .collect();
        if words.is_empty() {
            // A bare dimension on an implicit `logic`.
            words.push("logic");
        }
        let base = words[0];
        let packed_here = self.dims_list(&dims_text)?;
        let base_dims = match base {
            "logic" | "bit" | "reg" | "wire" | "tri" => Dims {
                packed: vec![],
                unpacked: 0,
            },
            "int" | "integer" => Dims {
                packed: vec![32],
                unpacked: 0,
            },
            "longint" | "time" => Dims {
                packed: vec![64],
                unpacked: 0,
            },
            "shortint" => Dims {
                packed: vec![16],
                unpacked: 0,
            },
            "byte" => Dims {
                packed: vec![8],
                unpacked: 0,
            },
            "genvar" | "real" | "string" | "void" => return None,
            other => {
                let text = self.typedef_text(other)?;
                self.type_dims(&text, depth + 1)?
            }
        };
        let mut packed = packed_here;
        packed.extend(base_dims.packed);
        if packed.is_empty() {
            packed.push(1);
        }
        Some(Dims {
            packed,
            unpacked: base_dims.unpacked,
        })
    }

    fn typedef_text(&self, name: &str) -> Option<String> {
        if let Some((pkg, member)) = name.rsplit_once("::") {
            return self.packages.get(pkg)?.typedef_texts.get(member).cloned();
        }
        if let Some(t) = self.typedef_texts.get(name) {
            return Some(t.clone());
        }
        for p in self.imported_packages() {
            if let Some(t) = p.typedef_texts.get(name) {
                return Some(t.clone());
            }
        }
        None
    }

    /// `[a:b][c:d]` → bits per dim, outer→inner. Empty text → empty list.
    fn dims_list(&self, dims_text: &str) -> Option<Vec<u32>> {
        let mut out = Vec::new();
        for dim in split_brackets(dims_text) {
            let dim = dim.trim();
            if dim.is_empty() {
                return None;
            }
            if let Some((l, r)) = split_top_level_colon(dim) {
                let l = self.eval_text(l)?;
                let r = self.eval_text(r)?;
                out.push(u32::try_from((l - r).abs() + 1).ok()?);
            } else {
                // `[N]` as a size (unpacked-style): N elements.
                let n = self.eval_text(dim)?;
                out.push(u32::try_from(n.max(1)).ok()?);
            }
        }
        Some(out)
    }

    /// Parameter / localparam / genvar / loop-variable names.
    /// Parameters, localparams, genvars and unrolled loop variables.
    pub fn is_const_name(&self, name: &str) -> bool {
        if self.const_exprs.contains_key(name) || self.param_ints.contains_key(name) {
            return true;
        }
        if self
            .decls
            .iter()
            .any(|d| d.name == name && (d.loop_var || d.type_name == "genvar"))
        {
            return true;
        }
        self.imported_packages()
            .any(|p| p.const_exprs.contains_key(name))
    }

    fn decl_dims(&self, name: &str) -> Option<Dims> {
        let decl = self
            .decls
            .iter()
            .filter(|d| d.name == name)
            .min_by_key(|d| d.scope.is_some() as u8)?;
        let type_text = format!("{} {}", decl.type_name, decl.packed_text);
        let mut dims = self.type_dims(&type_text, 0)?;
        dims.unpacked += split_brackets(&decl.unpacked_text).len();
        Some(dims)
    }

    fn port_dims(&self, name: &str) -> Option<Dims> {
        let port = self.ports.iter().find(|p| p.name == name)?;
        let base = port.type_name.as_deref().unwrap_or("logic");
        let dims = port.dimension_text.as_deref().unwrap_or("");
        self.type_dims(&format!("{base} {dims}"), 0)
    }

    fn signal_dims(&self, name: &str) -> Option<Dims> {
        if let Some(d) = self.decl_dims(name).or_else(|| self.port_dims(name)) {
            return Some(d);
        }
        // Source could not size it (constant function in a localparam): the
        // elaborated map can, for packed signals. An unpacked array is
        // lowered to a memory or a flattened wire there, so its entry is not
        // an element width — leave those unresolved.
        let bits = *self.elaborated?.get(name)?;
        let has_unpacked = self
            .decls
            .iter()
            .any(|d| d.name == name && !d.unpacked_text.trim().is_empty());
        if has_unpacked || bits == 0 {
            return None;
        }
        Some(Dims {
            packed: vec![bits],
            unpacked: 0,
        })
    }

    fn expr_dims(&self, e: &Expr, depth: u32) -> Option<Dims> {
        if depth > MAX_DEPTH {
            return None;
        }
        match e {
            Expr::Ident { name } => {
                if name.contains('.') || name.contains("::") {
                    return None;
                }
                // Parameters, localparams and unrolled loop variables are
                // constants: they fold into the operator, they do not set the
                // operand width (`TRANS_ID_BITS'(k)` with `int k` is not 32 bits).
                if self.is_const_name(name) {
                    return None;
                }
                self.signal_dims(name)
            }
            Expr::Literal { text } => parse_sv_int(text).and_then(|(w, _)| w).map(|w| Dims {
                packed: vec![w],
                unpacked: 0,
            }),
            Expr::Index { base, index } => {
                if let Expr::PartSelect { kind, left, right } = index.as_ref() {
                    let bits = match kind {
                        PartSelectKind::FixedRange => {
                            let l = self.eval(left, depth + 1)?;
                            let r = self.eval(right, depth + 1)?;
                            u32::try_from((l - r).abs() + 1).ok()?
                        }
                        PartSelectKind::IndexedPlus | PartSelectKind::IndexedMinus => {
                            u32::try_from(self.eval(right, depth + 1)?).ok()?
                        }
                    };
                    return Some(Dims {
                        packed: vec![bits],
                        unpacked: 0,
                    });
                }
                Some(self.expr_dims(base, depth + 1)?.indexed())
            }
            Expr::Concat { parts } => {
                let mut bits = 0u32;
                for p in parts {
                    bits = bits.saturating_add(self.expr_dims(p, depth + 1)?.bits());
                }
                Some(Dims {
                    packed: vec![bits],
                    unpacked: 0,
                })
            }
            Expr::Replicate { count, body } => {
                let n = u32::try_from(self.eval(count, depth + 1)?).ok()?;
                let b = self.expr_dims(body, depth + 1)?.bits();
                Some(Dims {
                    packed: vec![n.saturating_mul(b)],
                    unpacked: 0,
                })
            }
            Expr::Unary { op, arg } => match op.as_str() {
                "-" | "+" | "~" => self.expr_dims(arg, depth + 1),
                _ => Some(Dims {
                    packed: vec![1],
                    unpacked: 0,
                }),
            },
            Expr::Binary {
                op_class,
                left,
                right,
                ..
            } => match op_class {
                OperatorClass::Compare => Some(Dims {
                    packed: vec![1],
                    unpacked: 0,
                }),
                OperatorClass::ShiftConst | OperatorClass::ShiftVar => {
                    self.expr_dims(left, depth + 1)
                }
                _ => {
                    let l = self.expr_dims(left, depth + 1);
                    let r = self.expr_dims(right, depth + 1);
                    match (l, r) {
                        (Some(l), Some(r)) => Some(if l.bits() >= r.bits() { l } else { r }),
                        (Some(x), None) | (None, Some(x)) => Some(x),
                        (None, None) => None,
                    }
                }
            },
            Expr::Ternary { then_e, else_e, .. } => {
                let t = self.expr_dims(then_e, depth + 1);
                let f = self.expr_dims(else_e, depth + 1);
                match (t, f) {
                    (Some(t), Some(f)) => Some(if t.bits() >= f.bits() { t } else { f }),
                    (Some(x), None) | (None, Some(x)) => Some(x),
                    (None, None) => None,
                }
            }
            Expr::Call { name, args } => match (name.as_str(), args.as_slice()) {
                ("$signed" | "$unsigned", [a]) => self.expr_dims(a, depth + 1),
                _ => None,
            },
            Expr::PartSelect { .. } | Expr::Opaque { .. } => None,
        }
    }

    /// Bits of an expression (declared LHS, selected slice, concat, …).
    pub fn expr_width(&self, e: &Expr) -> Option<u32> {
        self.expr_dims(e, 0).map(|d| d.bits())
    }

    /// Arithmetic context width and comparison operand width for one node.
    pub fn node_widths(&self, lhs: Option<&Expr>, rhs: Option<&Expr>) -> NodeWidths {
        let mut out = NodeWidths {
            arith: lhs.and_then(|l| self.expr_width(l)),
            compare: None,
        };
        if let Some(r) = rhs {
            self.scan_operands(r, &mut out, 0);
        }
        out
    }

    fn scan_operands(&self, e: &Expr, out: &mut NodeWidths, depth: u32) {
        if depth > MAX_DEPTH {
            return;
        }
        let bump = |slot: &mut Option<u32>, w: Option<u32>| {
            if let Some(w) = w {
                *slot = Some(slot.map_or(w, |s| s.max(w)));
            }
        };
        match e {
            Expr::Binary {
                op_class,
                left,
                right,
                ..
            } => {
                match op_class {
                    OperatorClass::Compare => {
                        bump(&mut out.compare, self.expr_width(left));
                        bump(&mut out.compare, self.expr_width(right));
                    }
                    OperatorClass::AddSub
                    | OperatorClass::Mul
                    | OperatorClass::DivRem
                    | OperatorClass::ShiftVar
                    | OperatorClass::ShiftConst => {
                        bump(&mut out.arith, self.expr_width(left));
                        if !matches!(
                            op_class,
                            OperatorClass::ShiftVar | OperatorClass::ShiftConst
                        ) {
                            bump(&mut out.arith, self.expr_width(right));
                        }
                    }
                    _ => {}
                }
                self.scan_operands(left, out, depth + 1);
                self.scan_operands(right, out, depth + 1);
            }
            Expr::Unary { arg, .. } => self.scan_operands(arg, out, depth + 1),
            Expr::Ternary {
                cond,
                then_e,
                else_e,
            } => {
                self.scan_operands(cond, out, depth + 1);
                self.scan_operands(then_e, out, depth + 1);
                self.scan_operands(else_e, out, depth + 1);
            }
            Expr::Concat { parts } => {
                for p in parts {
                    self.scan_operands(p, out, depth + 1);
                }
            }
            Expr::Replicate { body, .. } => self.scan_operands(body, out, depth + 1),
            Expr::Index { base, index } => {
                self.scan_operands(base, out, depth + 1);
                self.scan_operands(index, out, depth + 1);
            }
            Expr::Call { args, .. } => {
                for a in args {
                    self.scan_operands(a, out, depth + 1);
                }
            }
            Expr::PartSelect { left, right, .. } => {
                self.scan_operands(left, out, depth + 1);
                self.scan_operands(right, out, depth + 1);
            }
            Expr::Ident { .. } | Expr::Literal { .. } | Expr::Opaque { .. } => {}
        }
    }
}

fn clog2(v: i64) -> i64 {
    if v <= 1 {
        return 0;
    }
    let mut n = 0i64;
    let mut x = (v - 1) as u64;
    while x > 0 {
        x >>= 1;
        n += 1;
    }
    n
}

/// `(size, value)` of a SystemVerilog integer literal: `12`, `8'd12`,
/// `'h1f`, `4'b1010`, `32'hdead_beef`. Size is None when unsized.
pub fn parse_sv_int(text: &str) -> Option<(Option<u32>, i64)> {
    let t: String = text.chars().filter(|c| *c != '_').collect();
    let t = t.trim();
    if t.is_empty() {
        return None;
    }
    let Some(apos) = t.find('\'') else {
        return t.parse::<i64>().ok().map(|v| (None, v));
    };
    let size = t[..apos].trim();
    let size = if size.is_empty() {
        None
    } else {
        Some(size.parse::<u32>().ok()?)
    };
    let mut rest = &t[apos + 1..];
    if let Some(r) = rest.strip_prefix(['s', 'S']) {
        rest = r;
    }
    let (radix, digits) = match rest.chars().next()? {
        'd' | 'D' => (10, &rest[1..]),
        'h' | 'H' => (16, &rest[1..]),
        'b' | 'B' => (2, &rest[1..]),
        'o' | 'O' => (8, &rest[1..]),
        _ => return None,
    };
    let digits = digits.trim();
    if digits.is_empty() || digits.contains(['x', 'X', 'z', 'Z', '?']) {
        return None;
    }
    i64::from_str_radix(digits, radix).ok().map(|v| (size, v))
}

/// `logic [A:B][C:D]` → (`logic`, `[A:B][C:D]`).
fn split_dims(text: &str) -> (String, String) {
    let mut head = String::new();
    let mut dims = String::new();
    let mut depth = 0i32;
    for c in text.chars() {
        if c == '[' {
            depth += 1;
        }
        if depth > 0 {
            dims.push(c);
        } else {
            head.push(c);
        }
        if c == ']' {
            depth -= 1;
        }
    }
    (head, dims)
}

/// `[a][b:c]` → `["a", "b:c"]` (top-level bracket groups).
fn split_brackets(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut depth = 0i32;
    for c in text.chars() {
        match c {
            '[' => {
                if depth > 0 {
                    cur.push(c);
                }
                depth += 1;
            }
            ']' => {
                depth -= 1;
                if depth == 0 {
                    out.push(std::mem::take(&mut cur));
                } else {
                    cur.push(c);
                }
            }
            _ if depth > 0 => cur.push(c),
            _ => {}
        }
    }
    out
}

/// `a:b` at bracket/paren depth 0 (a ternary `c ? x : y` is not a range).
fn split_top_level_colon(text: &str) -> Option<(&str, &str)> {
    let mut depth = 0i32;
    let mut question = 0i32;
    let bytes = text.as_bytes();
    for (i, c) in text.char_indices() {
        // `pkg::NAME` scope operator, not a range separator.
        let scope_colon =
            c == ':' && (bytes.get(i + 1) == Some(&b':') || (i > 0 && bytes[i - 1] == b':'));
        match c {
            '(' | '[' | '{' => depth += 1,
            ')' | ']' | '}' => depth -= 1,
            '?' if depth == 0 => question += 1,
            ':' if depth == 0 && !scope_colon => {
                if question > 0 {
                    question -= 1;
                } else {
                    return Some((&text[..i], &text[i + 1..]));
                }
            }
            _ => {}
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::loc::SourceLoc;

    fn decl(name: &str, ty: &str, packed: &str, unpacked: &str) -> DeclSite {
        DeclSite {
            name: name.into(),
            type_name: ty.into(),
            packed_text: packed.into(),
            unpacked_text: unpacked.into(),
            loc: SourceLoc::file_start("t.sv"),
            block_local: false,
            scope: None,
            loop_var: false,
        }
    }

    fn port(name: &str, ty: Option<&str>, dims: Option<&str>) -> ModulePort {
        ModulePort {
            name: name.into(),
            direction: "input".into(),
            type_name: ty.map(Into::into),
            packed_dims: None,
            uses_hierarchical: false,
            dimension_text: dims.map(Into::into),
        }
    }

    struct Fixture {
        packages: BTreeMap<String, TimingPackage>,
        ints: BTreeMap<String, i64>,
        decls: Vec<DeclSite>,
        ports: Vec<ModulePort>,
        consts: BTreeMap<String, String>,
        typedefs: BTreeMap<String, String>,
        imports: Vec<String>,
        elaborated: BTreeMap<String, u32>,
    }

    impl Fixture {
        fn resolver(&self) -> WidthResolver<'_> {
            WidthResolver::from_parts(
                &self.packages,
                &self.ints,
                &self.decls,
                &self.ports,
                &self.consts,
                &self.typedefs,
                &self.imports,
                Some(&self.elaborated),
            )
        }
    }

    fn fixture() -> Fixture {
        let mut packages = BTreeMap::new();
        packages.insert(
            "riscv".to_string(),
            TimingPackage {
                name: "riscv".into(),
                file: "riscv_pkg.sv".into(),
                localparams: vec!["VLEN".into()],
                functions: vec![],
                function_bodies: vec![],
                typedefs: vec!["xlen_t".into()],
                const_exprs: BTreeMap::from([("VLEN".to_string(), "39".to_string())]),
                typedef_texts: BTreeMap::from([(
                    "xlen_t".to_string(),
                    "logic [XLEN-1:0]".to_string(),
                )]),
                loc: SourceLoc::file_start("riscv_pkg.sv"),
            },
        );
        Fixture {
            packages,
            ints: BTreeMap::from([("CVA6Cfg.XLEN".to_string(), 64), ("XLEN".to_string(), 64)]),
            decls: vec![
                decl("idx_q", "fifo_idx_t", "", ""),
                decl("count", "logic", "[3:0]", ""),
                decl("mem", "logic", "[7:0]", "[DEPTH-1:0]"),
                decl("word", "xlen_t", "", ""),
                decl("two_d", "logic", "[NrFifo-1:0][IdxW-1:0]", ""),
                decl("flag", "logic", "", ""),
                decl("state", "state_e", "", ""),
                DeclSite {
                    loop_var: true,
                    ..decl("k", "int", "", "")
                },
            ],
            ports: vec![
                port(
                    "instr_i",
                    Some("logic"),
                    Some("[CVA6Cfg.INSTR_PER_FETCH-1:0][31:0]"),
                ),
                port("addr_i", Some("logic"), Some("[riscv::VLEN-1:0]")),
                port("valid_i", Some("logic"), None),
            ],
            consts: BTreeMap::from([
                ("DEPTH".to_string(), "8".to_string()),
                ("IdxW".to_string(), "$clog2(DEPTH)".to_string()),
                ("NrFifo".to_string(), "CVA6Cfg.INSTR_PER_FETCH".to_string()),
            ]),
            typedefs: BTreeMap::from([
                ("fifo_idx_t".to_string(), "logic [IdxW-1:0]".to_string()),
                (
                    "state_e".to_string(),
                    "enum logic [1:0] {IDLE, BUSY}".to_string(),
                ),
            ]),
            imports: vec!["riscv::*".into()],
            elaborated: BTreeMap::from([
                ("two_d".to_string(), 8u32),
                ("mem".to_string(), 64u32),
                ("count".to_string(), 32u32),
            ]),
        }
    }

    #[test]
    fn literals_parse_with_size_and_radix() {
        assert_eq!(parse_sv_int("12"), Some((None, 12)));
        assert_eq!(parse_sv_int("8'd12"), Some((Some(8), 12)));
        assert_eq!(parse_sv_int("'h1f"), Some((None, 31)));
        assert_eq!(parse_sv_int("4'b1010"), Some((Some(4), 10)));
        assert_eq!(parse_sv_int("32'hdead_beef"), Some((Some(32), 0xdead_beef)));
        assert_eq!(parse_sv_int("4'bx"), None);
        assert_eq!(parse_sv_int("foo"), None);
    }

    #[test]
    fn constants_resolve_through_module_package_and_param_map() {
        let f = fixture();
        let r = f.resolver();
        assert_eq!(r.const_value("DEPTH"), Some(8));
        assert_eq!(r.const_value("IdxW"), Some(3));
        assert_eq!(r.const_value("CVA6Cfg.XLEN"), Some(64));
        assert_eq!(r.const_value("riscv::VLEN"), Some(39));
        assert_eq!(
            r.const_value("VLEN"),
            Some(39),
            "imported package localparam"
        );
        assert_eq!(
            r.const_value("CVA6Cfg.INSTR_PER_FETCH"),
            None,
            "not in the map"
        );
        assert_eq!(r.eval_text("(DEPTH > 1) ? $clog2(DEPTH) : 1"), Some(3));
        assert_eq!(r.eval_text("2**IdxW - 1"), Some(7));
    }

    #[test]
    fn declared_widths_follow_typedefs_dims_and_selects() {
        let f = fixture();
        let r = f.resolver();
        let w = |s: &str| r.expr_width(&Expr::parse(s));
        assert_eq!(w("idx_q"), Some(3), "typedef over $clog2 localparam");
        assert_eq!(w("count"), Some(4));
        assert_eq!(w("mem[3]"), Some(8), "unpacked element");
        assert_eq!(w("mem"), Some(8), "element width of an unpacked array");
        assert_eq!(w("word"), Some(64), "package typedef over the param-map");
        assert_eq!(w("addr_i"), Some(39), "port dims through a package scope");
        // `two_d` cannot be sized from source (NrFifo is an unmapped Cfg
        // field) — the elaborated map supplies it. `count` is sized from source
        // (4), so the map's 32 is not consulted; `mem` is unpacked, so the
        // map's flattened 64 is refused.
        assert_eq!(w("two_d"), Some(8), "elaborated width map fills the gap");
        assert_eq!(w("instr_i"), None, "unresolved outer dim stays unknown");
        assert_eq!(w("count[2:0]"), Some(3));
        assert_eq!(w("word[idx_q +: 8]"), Some(8));
        assert_eq!(w("count[1]"), Some(1));
        assert_eq!(w("{count, idx_q}"), Some(7));
        assert_eq!(w("{4{flag}}"), Some(4));
        assert_eq!(w("state"), Some(2), "enum base vector");
        assert_eq!(w("valid_i"), Some(1));
        assert_eq!(w("count + 1'b1"), Some(4));
        assert_eq!(w("count == 4'd3"), Some(1));
    }

    #[test]
    fn node_widths_separate_arithmetic_context_from_compare_operands() {
        let f = fixture();
        let r = f.resolver();
        // `flag = (word + 1) > count`: the add is a 64-bit context even though
        // the LHS is 1 bit; the compare is 64 bits by its wider operand.
        let nw = r.node_widths(
            Some(&Expr::parse("flag")),
            Some(&Expr::parse("(word + 1) > count")),
        );
        assert_eq!(nw.arith, Some(64));
        assert_eq!(nw.compare, Some(64));
        // `idx_d = idx_q + fifo_idx_t'(shamt)`: 3-bit context, no compare.
        let nw = r.node_widths(
            Some(&Expr::parse("idx_q")),
            Some(&Expr::parse("idx_q + count")),
        );
        assert_eq!(nw.arith, Some(4), "max(lhs 3, operand 4)");
        assert_eq!(nw.compare, None);
        // Nothing resolvable keeps the reference width.
        let nw = r.node_widths(
            Some(&Expr::parse("unknown_lhs")),
            Some(&Expr::parse("x + y")),
        );
        assert_eq!(nw, NodeWidths::default());
        // An elaborated-map signal indexed once: 8-bit packed, one bit selected.
        let nw = r.node_widths(Some(&Expr::parse("two_d[0]")), Some(&Expr::parse("x + y")));
        assert_eq!(nw.arith, Some(1));
        // scoreboard `commit_pointer_q[0] + TRANS_ID_BITS'(k)`: the unrolled
        // `int k` and the localparam DEPTH are constants, not 32-bit operands.
        let nw = r.node_widths(
            Some(&Expr::parse("idx_q")),
            Some(&Expr::parse("idx_q + k + DEPTH")),
        );
        assert_eq!(nw.arith, Some(3));
    }

    #[test]
    fn width_factor_is_unity_at_reference_and_floors_narrow_ops() {
        assert_eq!(width_factor(OperatorClass::AddSub, Some(32)), 1.0);
        assert_eq!(width_factor(OperatorClass::AddSub, None), 1.0);
        assert!((width_factor(OperatorClass::AddSub, Some(4)) - 0.4).abs() < 1e-9);
        assert!((width_factor(OperatorClass::Compare, Some(64)) - 1.2).abs() < 1e-9);
        assert!(
            (width_factor(OperatorClass::ShiftVar, Some(1)) - 0.2).abs() < 1e-9,
            "max(w,2)"
        );
        assert_eq!(width_factor(OperatorClass::Mul, Some(16)), 0.5);
        assert_eq!(width_factor(OperatorClass::DivRem, Some(64)), 2.0);
        assert_eq!(width_factor(OperatorClass::LogicBit, Some(64)), 1.0);
        assert_eq!(width_factor(OperatorClass::Mux, Some(4)), 1.0);
    }
}
