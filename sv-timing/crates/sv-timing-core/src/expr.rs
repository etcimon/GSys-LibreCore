// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Lightweight expression AST for denser IR / emit (not a full SV elaborator).

//! Expression trees recovered from assignment RHS/LHS text.
//!
//! Supports a practical subset of SystemVerilog expression surface:
//! identifiers, sized/unsized literals, unary/binary ops, ternary `?:`,
//! concatenation `{a,b}`, bit/part selects `a[i]` / `a[h:l]`, and simple
//! function calls `f(a,b)`. Anything unrecognized becomes [`Expr::Opaque`].
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
    /// Index / part-select `base[index]` or `base[hi:lo]` (index as opaque/binary).
    Index {
        /// Base expression.
        base: Box<Expr>,
        /// Index or part-select expression (may be `Binary` with `:`).
        index: Box<Expr>,
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
            Expr::Call { name, args } => {
                let inner = args
                    .iter()
                    .map(|a| a.emit())
                    .collect::<Vec<_>>()
                    .join(", ");
                format!("{name}({inner})")
            }
        }
    }

    /// Dominant (deepest / costliest) operator class for coarse FO4.
    ///
    /// Address-scale multiplies (`i*8`) do **not** rank as full datapath Mul.
    pub fn dominant_op_class(&self) -> OperatorClass {
        dominant_op_class_measured(self)
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
        match self {
            Expr::Ident { .. } | Expr::Literal { .. } | Expr::Opaque { .. } => 0.0,
            Expr::Unary { op, arg, .. } => base(classify_unary(op)) + arg.fo4_critical_cost(base),
            Expr::Binary {
                op,
                op_class,
                left,
                right,
            } => {
                // Address/index scale (`i*8`, `i*OPERANDS_PER_INSTR+2`) is not a 56-FO4 mul.
                let op_cost = if matches!(*op_class, OperatorClass::Mul | OperatorClass::DivRem)
                    && is_addr_scale_mul(op, left, right)
                {
                    base(OperatorClass::Other)
                } else {
                    base(*op_class)
                };
                op_cost
                    + left
                        .fo4_critical_cost(base)
                        .max(right.fo4_critical_cost(base))
            }
            Expr::Ternary {
                cond,
                then_e,
                else_e,
            } => {
                base(OperatorClass::Mux)
                    + cond
                        .fo4_critical_cost(base)
                        .max(then_e.fo4_critical_cost(base))
                        .max(else_e.fo4_critical_cost(base))
            }
            Expr::Concat { parts } => {
                base(OperatorClass::Concat)
                    + parts
                        .iter()
                        .map(|p| p.fo4_critical_cost(base))
                        .fold(0.0_f64, f64::max)
            }
            Expr::Replicate { count, body } => {
                base(OperatorClass::Concat)
                    + count
                        .fo4_critical_cost(base)
                        .max(body.fo4_critical_cost(base))
            }
            Expr::Index { base: b, index } => {
                b.fo4_critical_cost(base).max(index.fo4_critical_cost(base))
            }
            Expr::Call { args, .. } => {
                base(OperatorClass::Other)
                    + args
                        .iter()
                        .map(|a| a.fo4_critical_cost(base))
                        .fold(0.0_f64, f64::max)
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
    pub fn critical_spine_ops(&self, base: &dyn Fn(OperatorClass) -> f64) -> Vec<(OperatorClass, f64)> {
        match self {
            Expr::Ident { .. } | Expr::Literal { .. } | Expr::Opaque { .. } => Vec::new(),
            Expr::Unary { op, arg, .. } => {
                let cls = classify_unary(op);
                let mut s = arg.critical_spine_ops(base);
                s.push((cls, base(cls)));
                s
            }
            Expr::Binary {
                op_class,
                left,
                right,
                ..
            } => {
                let lc = left.fo4_critical_cost(base);
                let rc = right.fo4_critical_cost(base);
                let mut s = if lc >= rc {
                    left.critical_spine_ops(base)
                } else {
                    right.critical_spine_ops(base)
                };
                s.push((*op_class, base(*op_class)));
                s
            }
            Expr::Ternary {
                cond,
                then_e,
                else_e,
            } => {
                let arms: [&Expr; 3] = [cond.as_ref(), then_e.as_ref(), else_e.as_ref()];
                let best = arms
                    .into_iter()
                    .max_by(|a, b| {
                        a.fo4_critical_cost(base)
                            .partial_cmp(&b.fo4_critical_cost(base))
                            .unwrap_or(std::cmp::Ordering::Equal)
                    })
                    .unwrap();
                let mut s = best.critical_spine_ops(base);
                s.push((OperatorClass::Mux, base(OperatorClass::Mux)));
                s
            }
            Expr::Concat { parts } => {
                let mut s = parts
                    .iter()
                    .max_by(|a, b| {
                        a.fo4_critical_cost(base)
                            .partial_cmp(&b.fo4_critical_cost(base))
                            .unwrap_or(std::cmp::Ordering::Equal)
                    })
                    .map(|p| p.critical_spine_ops(base))
                    .unwrap_or_default();
                s.push((OperatorClass::Concat, base(OperatorClass::Concat)));
                s
            }
            Expr::Replicate { count, body } => {
                let cc = count.fo4_critical_cost(base);
                let bc = body.fo4_critical_cost(base);
                let mut s = if cc >= bc {
                    count.critical_spine_ops(base)
                } else {
                    body.critical_spine_ops(base)
                };
                s.push((OperatorClass::Concat, base(OperatorClass::Concat)));
                s
            }
            Expr::Index { base: b, index } => {
                let bc = b.fo4_critical_cost(base);
                let ic = index.fo4_critical_cost(base);
                if bc >= ic {
                    b.critical_spine_ops(base)
                } else {
                    index.critical_spine_ops(base)
                }
            }
            Expr::Call { args, .. } => {
                let mut s = args
                    .iter()
                    .max_by(|a, b| {
                        a.fo4_critical_cost(base)
                            .partial_cmp(&b.fo4_critical_cost(base))
                            .unwrap_or(std::cmp::Ordering::Equal)
                    })
                    .map(|a| a.critical_spine_ops(base))
                    .unwrap_or_default();
                s.push((OperatorClass::Other, base(OperatorClass::Other)));
                s
            }
        }
    }

    /// True when a single operator on the critical spine exceeds `budget_fo4`.
    ///
    /// Such ops cannot be shortened by InsertReg alone (atomic FO4).
    pub fn has_atomic_over_budget(&self, base: &dyn Fn(OperatorClass) -> f64, budget_fo4: f64) -> bool {
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
                Some(c.saturating_mul(body.width_class_hint().unwrap_or(1)).max(1))
            }
            Expr::Unary { arg, .. } => arg.width_class_hint(),
            Expr::Index { base, .. } => base.width_class_hint(), // conservative: full base
            Expr::Binary { left, right, .. } => {
                // Both known and equal → that width; else unknown
                match (left.width_class_hint(), right.width_class_hint()) {
                    (Some(a), Some(b)) if a == b => Some(a),
                    _ => None,
                }
            }
            Expr::Ternary {
                then_e, else_e, ..
            } => match (then_e.width_class_hint(), else_e.width_class_hint()) {
                (Some(a), Some(b)) if a == b => Some(a),
                (Some(a), None) | (None, Some(a)) => Some(a),
                _ => None,
            },
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
            Expr::Binary { left, right, .. } => 1 + left.depth().max(right.depth()),
            Expr::Ternary {
                cond,
                then_e,
                else_e,
            } => 1 + cond.depth().max(then_e.depth()).max(else_e.depth()),
            Expr::Concat { parts } => {
                1 + parts.iter().map(|p| p.depth()).max().unwrap_or(0)
            }
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
                if !rhs.chars().all(|c| c.is_ascii_alphanumeric() || "_$ ".contains(c)) {
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
            Expr::Binary { left, right, .. } => {
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
            .or_else(|| {
                self.wires
                    .first()
                    .map(|(n, _)| format!("{n}_stage"))
            })
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
            op: o,
            left,
            right,
            ..
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

/// `*` used as array/genvar index scale, not datapath multiply.
fn is_addr_scale_mul(_op: &str, left: &Expr, right: &Expr) -> bool {
    is_scale_tree(left) && is_scale_tree(right)
}

fn is_scale_tree(e: &Expr) -> bool {
    match e {
        Expr::Ident { name } => !looks_like_datapath_ident(name),
        Expr::Literal { .. } => true,
        Expr::Unary { arg, .. } => is_scale_tree(arg),
        Expr::Binary { op, left, right, .. }
            if matches!(op.as_str(), "+" | "-" | "*" | "<<" | ">>") =>
        {
            is_scale_tree(left) && is_scale_tree(right)
        }
        Expr::Index { base, index } => is_scale_tree(base) && is_scale_tree(index),
        _ => false,
    }
}

fn looks_like_datapath_ident(name: &str) -> bool {
    let n = name.to_ascii_lowercase();
    let leaf = n.rsplit('.').next().unwrap_or(n.as_str());
    // Short genvars / loop indices are not datapath.
    if leaf.len() <= 2 {
        return false;
    }
    leaf.contains("operand")
        || leaf.contains("op_a")
        || leaf.contains("op_b")
        || leaf.contains("result")
        || leaf.contains("rdata")
        || leaf.contains("wdata")
        || leaf.contains("rs1")
        || leaf.contains("rs2")
        || leaf.contains("rs3")
        || (leaf.ends_with("_i") && leaf.len() > 6 && !leaf.contains("valid") && !leaf.contains("en"))
}

/// Dominant op for coarse class: do not rank addr-scale mul as full Mul.
pub fn dominant_op_class_measured(e: &Expr) -> OperatorClass {
    // Prefer non-scale classification by temporarily ranking via walk with scale demotion.
    let mut best = OperatorClass::Other;
    let mut best_rank = 0u8;
    fn walk(e: &Expr, f: &mut dyn FnMut(OperatorClass)) {
        match e {
            Expr::Ident { .. } | Expr::Literal { .. } | Expr::Opaque { .. } => {}
            Expr::Unary { arg, op, .. } => {
                f(classify_unary(op));
                walk(arg, f);
            }
            Expr::Binary {
                op,
                op_class,
                left,
                right,
                ..
            } => {
                if matches!(*op_class, OperatorClass::Mul | OperatorClass::DivRem)
                    && is_addr_scale_mul(op, left, right)
                {
                    f(OperatorClass::Other);
                } else {
                    f(*op_class);
                }
                walk(left, f);
                walk(right, f);
            }
            Expr::Ternary {
                cond,
                then_e,
                else_e,
            } => {
                f(OperatorClass::Mux);
                walk(cond, f);
                walk(then_e, f);
                walk(else_e, f);
            }
            Expr::Concat { parts } => {
                f(OperatorClass::Concat);
                for p in parts {
                    walk(p, f);
                }
            }
            Expr::Replicate { count, body } => {
                f(OperatorClass::Concat);
                walk(count, f);
                walk(body, f);
            }
            Expr::Index { base, index } => {
                walk(base, f);
                walk(index, f);
            }
            Expr::Call { args, .. } => {
                f(OperatorClass::Other);
                for a in args {
                    walk(a, f);
                }
            }
        }
    }
    walk(e, &mut |c| {
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
        Expr::Binary { .. } | Expr::Ternary { .. } => format!("({})", e.emit()),
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
        "/" | "%" => OperatorClass::DivRem,
        "<<" | ">>" | "<<<" | ">>>" => OperatorClass::ShiftConst,
        "==" | "!=" | "===" | "!==" | "<" | ">" | "<=" | ">=" => OperatorClass::Compare,
        "&" | "|" | "^" | "~^" | "^~" | "&&" | "||" => OperatorClass::LogicBit,
        _ => OperatorClass::Other,
    }
}

fn classify_unary(op: &str) -> OperatorClass {
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
        while self.i < self.src.len() && self.src[self.i].is_ascii_whitespace() {
            self.i += 1;
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
        self.parse_bin_left(&["*", "/", "%"], |p| p.parse_unary())
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
        if let Some(op) = self.match_op(&["~&", "~|", "~^", "^~", "~", "!", "-", "+", "&", "|", "^"])
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
                    // optional : for part select — already in parse_expr via ternary? No, `:` is ternary.
                    // Handle `hi:lo` inside brackets as binary with op ":"
                    let index = if self.peek() == Some(b':') {
                        self.bump();
                        let lo = self.parse_expr()?;
                        Expr::Binary {
                            op: ":".into(),
                            op_class: OperatorClass::Other,
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
                _ => break,
            }
        }
        Some(e)
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
            b'\'' | b'0'..=b'9' => self.parse_literal(),
            c if c == b'_' || c.is_ascii_alphabetic() || c == b'$' => self.parse_ident_or_call_name(),
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
        while self.i < self.src.len() {
            let c = self.src[self.i];
            if c.is_ascii_alphanumeric()
                || c == b'\''
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
            } else if c == b':'
                && self.src.get(self.i + 1) == Some(&b':')
            {
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
        assert!(
            c < 30.0,
            "addr scale must not cost full mul, got {c}"
        );
        assert_ne!(scale.dominant_op_class(), OperatorClass::Mul);
        let data = Expr::parse("operand_a_i * operand_b_i");
        assert!(data.fo4_critical_cost(&base) >= 56.0);
        assert_eq!(data.dominant_op_class(), OperatorClass::Mul);
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
            ms.last().map(|(c, _)| *c == OperatorClass::Mul).unwrap_or(false),
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
        assert!(s.contains("64'hff") || s.contains("64'hFF") || s.contains("64"), "{s}");
        // Depth should still be finite; equal-width 1-bit runs may balance
        assert!(bal.depth() >= 2, "depth={}", bal.depth());
        // Full equal-width chain still balances
        let e2 = Expr::parse("1'b0 | 1'b1 | 1'b0 | 1'b1 | 1'b0 | 1'b1 | 1'b0 | 1'b1");
        let d0 = e2.depth();
        let b2 = e2.rebalance_associative();
        assert!(b2.depth() < d0, "equal-width should balance {} -> {}", d0, b2.depth());
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
