// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! `SelectIncrement` shape detection (ALGORITHMS-EXPERTS A88).
//!
//! A register plus a narrow runtime step at the end of a control cone —
//! `seq_d = seq_q + 16'(step)`, `idx_d = (idx_q + step) & MASK` — puts the
//! adder's carry chain *after* the cone that computes `step`. Every candidate
//! sum is a constant-offset increment of the register alone, available at the
//! clock edge, so the cone can end in a select instead:
//!
//! ```text
//! cand[j] = (REG_q + j) & MASK      for j in 0 .. 2^k      (parallel, off-path)
//! LHS     = cand[step]                                      (one select)
//! ```
//!
//! Exact modulo 2^W for every value of `step` (the candidate array covers the
//! declared width `k` of `step`, never an assumed range), same cycle, no new
//! state. Cost: `2^k` incrementers of `W` bits; gain on the cone:
//! `AddSub(W) - ceil(k/2) * mux` (one 4:1 level per two index bits).
//!
//! This module only recognizes the shape and prices it; the transform crate
//! rewrites the IR and the emitter writes the SV (`EditKind::SelectIncrement`).

use std::collections::BTreeSet;

use crate::expr::Expr;
use crate::ir::{AssignKind, IrNode, OperatorClass, RegionKind, TimingModule};
use crate::measure::CostModel;
use crate::width::WidthResolver;

/// Largest step width the transform accepts (`2^k` candidates).
pub const MAX_STEP_BITS: u32 = 4;
/// Area guard: candidates × width in bits.
pub const MAX_CANDIDATE_BITS: u32 = 512;

/// A recognized `REG + step` node.
#[derive(Debug, Clone, PartialEq)]
pub struct SelectIncrementShape {
    /// Register operand as written (`seq_q`, `commit_pointer_q[0]`).
    pub reg_text: String,
    /// Step operand (a module-scope identifier).
    pub step_ident: String,
    /// Declared width of the step (`k`); candidates = `2^k`.
    pub step_bits: u32,
    /// `& MASK` applied to the sum, when present (constant text).
    pub mask_text: Option<String>,
    /// Assignment LHS as written.
    pub lhs_text: String,
    /// Result width when resolved (for the area guard and the estimate).
    pub width: Option<u32>,
    /// Structural FO4 of the node before (the adder).
    pub fo4_before: f64,
    /// Structural FO4 of the node after (the select, plus the mask gate).
    pub fo4_after: f64,
}

impl SelectIncrementShape {
    /// Number of candidates.
    pub fn candidates(&self) -> u32 {
        1u32 << self.step_bits
    }
    /// 4:1 levels of the final select.
    pub fn mux_levels(&self) -> u32 {
        self.step_bits.div_ceil(2)
    }
    /// Estimated FO4 gain on the node (never negative).
    pub fn gain(&self) -> f64 {
        (self.fo4_before - self.fo4_after).max(0.0)
    }
}

/// Register names of a module: roots of every non-blocking LHS in an
/// `always_ff` region (the flops a transform may read at the clock edge).
pub fn register_roots(module: &TimingModule) -> BTreeSet<String> {
    let mut regs = BTreeSet::new();
    for region in module.regions.values() {
        if region.kind != RegionKind::AlwaysFf {
            continue;
        }
        for id in &region.nodes {
            let Some(n) = module.nodes.get(id) else {
                continue;
            };
            if n.assign_kind != AssignKind::Nonblocking {
                continue;
            }
            if let Some(root) = n.lhs.as_deref().and_then(TimingModule::root_ident) {
                regs.insert(root.to_string());
            }
        }
    }
    regs
}

/// Recognize `LHS = REG + step` / `LHS = (REG + step) & MASK` on a
/// combinational assignment (`assign` or blocking inside `always_comb`).
///
/// `regs` is [`register_roots`]; `resolver` sizes the step and the result.
/// Returns `None` when the shape does not match, the step is not a bare
/// module-scope identifier of known width `1..=MAX_STEP_BITS`, the area guard
/// trips, or the select would not be cheaper than the adder.
pub fn detect(
    module: &TimingModule,
    node: &IrNode,
    regs: &BTreeSet<String>,
    resolver: &WidthResolver<'_>,
    model: &CostModel,
) -> Option<SelectIncrementShape> {
    if !matches!(
        node.assign_kind,
        AssignKind::Continuous | AssignKind::Blocking
    ) {
        return None;
    }
    let lhs_text = node.lhs.as_deref()?.trim().to_string();
    let lhs_root = TimingModule::root_ident(&lhs_text)?;
    let block_local = module.block_local_names();
    if block_local.contains(lhs_root) {
        return None;
    }
    let rhs = node.rhs_expr.as_ref()?;
    // Optional `& MASK` with a constant mask.
    let (sum, mask_text) = match rhs {
        Expr::Binary {
            op,
            op_class: OperatorClass::LogicBit,
            left,
            right,
        } if op == "&" => {
            if is_const_leaf(right) {
                (left.as_ref(), Some(right.emit()))
            } else if is_const_leaf(left) {
                (right.as_ref(), Some(left.emit()))
            } else {
                return None;
            }
        }
        other => (other, None),
    };
    let Expr::Binary {
        op,
        op_class: OperatorClass::AddSub,
        left,
        right,
    } = sum
    else {
        return None;
    };
    if op != "+" {
        return None;
    }
    // One side is a register read, the other a bare runtime identifier.
    let (reg, step) = if is_register_read(left, regs) && step_ident(right).is_some() {
        (left.as_ref(), right.as_ref())
    } else if is_register_read(right, regs) && step_ident(left).is_some() {
        (right.as_ref(), left.as_ref())
    } else {
        return None;
    };
    let step_name = step_ident(step)?;
    if block_local.contains(step_name) || regs.contains(step_name) {
        // A register step is already stable at the edge: nothing to move.
        return None;
    }
    let reg_text = reg.emit();
    let reg_root = TimingModule::root_ident(&reg_text)?;
    if block_local.contains(reg_root) {
        return None;
    }
    let step_bits = resolver.expr_width(step)?;
    if step_bits == 0 || step_bits > MAX_STEP_BITS {
        return None;
    }
    let width = resolver
        .expr_width(node.lhs_expr.as_ref()?)
        .or_else(|| resolver.expr_width(reg));
    if let Some(w) = width {
        if (1u32 << step_bits).saturating_mul(w) > MAX_CANDIDATE_BITS {
            return None;
        }
    }
    let fo4_before = node.fo4_cost;
    let fo4_after = f64::from(step_bits.div_ceil(2)) * model.mux
        + if mask_text.is_some() {
            model.logic_bit
        } else {
            0.0
        };
    if fo4_after + 0.5 > fo4_before {
        return None;
    }
    Some(SelectIncrementShape {
        reg_text,
        step_ident: step_name.to_string(),
        step_bits,
        mask_text,
        lhs_text,
        width,
        fo4_before,
        fo4_after,
    })
}

fn is_const_leaf(e: &Expr) -> bool {
    matches!(e, Expr::Literal { .. })
        || matches!(e, Expr::Ident { name } if looks_like_constant_name(name))
}

/// `IdxMask`, `MASK`, `pkg::CONST`, `Cfg.FIELD` — a constant by spelling or
/// scope (the lattice seed is module-aware; here a conservative syntactic test
/// keeps the detector free of the seed plumbing).
fn looks_like_constant_name(name: &str) -> bool {
    if name.contains("::") || name.contains('.') {
        return true;
    }
    let first = name.chars().next().unwrap_or('a');
    first.is_ascii_uppercase()
}

/// `reg_q` or `reg_q[CONST]` with `reg_q` a register root.
fn is_register_read(e: &Expr, regs: &BTreeSet<String>) -> bool {
    match e {
        Expr::Ident { name } => TimingModule::root_ident(name).is_some_and(|r| regs.contains(r)),
        Expr::Index { base, index } => {
            matches!(base.as_ref(), Expr::Ident { .. })
                && is_const_leaf(index)
                && is_register_read(base, regs)
        }
        _ => false,
    }
}

fn step_ident(e: &Expr) -> Option<&str> {
    match e {
        Expr::Ident { name } if !name.contains('.') && !name.contains("::") => Some(name.as_str()),
        _ => None,
    }
}

/// Replacement RHS: `cand[step]` for k <= 2, a 2:1 over two 4:1 selects for
/// k = 3..4 (so the structural model and the netlist agree on two levels).
pub fn select_rhs(cand: &str, step: &str, step_bits: u32) -> String {
    if step_bits <= 2 {
        return format!("{cand}[{step}]");
    }
    let low = step_bits - 1;
    let lo_sel = format!("{step}[{}:0]", low - 1);
    format!("({step}[{low}] ? {cand}[{{1'b1, {lo_sel}}}] : {cand}[{{1'b0, {lo_sel}}}])")
}

/// Module-scope snippet declaring and driving the candidates.
///
/// `type(<lhs>)` keeps the element type (typedef, enum, packed) and the cast
/// truncates the genvar sum to the result width: exact modulo 2^W.
pub fn candidate_snippet(shape: &SelectIncrementShape, cand: &str) -> String {
    let n = shape.candidates();
    let masked = match &shape.mask_text {
        Some(m) => format!("(({} + svt_j) & {m})", shape.reg_text),
        None => format!("({} + svt_j)", shape.reg_text),
    };
    let lhs = &shape.lhs_text;
    format!(
        "  // sv-timing select_increment: `{lhs} = {reg} + {step}` -> {n} precomputed\n  // increments of the register (off the `{step}` cone) and one select.\n  var type({lhs}) {cand} [0:{last}];\n  for (genvar svt_j = 0; svt_j < {n}; svt_j++) begin : gen_{cand}\n    assign {cand}[svt_j] = type({lhs})'({masked});\n  end\n",
        reg = shape.reg_text,
        step = shape.step_ident,
        last = n - 1,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ir::DeclSite;
    use crate::loc::SourceLoc;
    use std::collections::BTreeMap;

    fn decl(name: &str, ty: &str, packed: &str) -> DeclSite {
        DeclSite {
            name: name.into(),
            type_name: ty.into(),
            packed_text: packed.into(),
            unpacked_text: String::new(),
            loc: SourceLoc::file_start("t.sv"),
            block_local: false,
            scope: None,
            loop_var: false,
        }
    }

    fn node(lhs: &str, rhs: &str, kind: AssignKind, cost: f64) -> IrNode {
        IrNode {
            id: 1,
            op_class: Some(OperatorClass::AddSub),
            width: 16,
            fo4_cost: cost,
            gate: None,
            loc: SourceLoc::file_start("t.sv"),
            fans_in: vec![],
            fans_out: vec![],
            width_defaulted: false,
            reads_reg: true,
            lhs: Some(lhs.into()),
            rhs: Some(rhs.into()),
            rhs_expr: Some(Expr::parse(rhs)),
            lhs_expr: Some(Expr::parse(lhs)),
            case_labels: vec![],
            case_is_default: false,
            case_selector: None,
            fo4_locked: false,
            assign_kind: kind,
        }
    }

    struct Env {
        packages: BTreeMap<String, crate::ir::TimingPackage>,
        ints: BTreeMap<String, i64>,
        decls: Vec<DeclSite>,
        ports: Vec<crate::ir::ModulePort>,
        consts: BTreeMap<String, String>,
        typedefs: BTreeMap<String, String>,
        imports: Vec<String>,
    }

    fn env() -> Env {
        Env {
            packages: BTreeMap::new(),
            ints: BTreeMap::new(),
            decls: vec![
                decl("seq_q", "logic", "[15:0]"),
                decl("seq_d", "logic", "[15:0]"),
                decl("step", "logic", "[2:0]"),
                decl("wide_step", "logic", "[7:0]"),
                decl("idx_q", "idx_t", ""),
                decl("idx_d", "idx_t", ""),
                decl("wrap_q", "logic", "[15:0]"),
                decl("wrap_d", "logic", "[15:0]"),
                decl("other_q", "logic", "[15:0]"),
            ],
            ports: vec![],
            consts: BTreeMap::new(),
            typedefs: BTreeMap::from([("idx_t".to_string(), "logic [1:0]".to_string())]),
            imports: vec![],
        }
    }

    fn module_with_regs() -> TimingModule {
        let mut m = TimingModule {
            id: 0,
            name: "t".into(),
            file: "t.sv".into(),
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
            decls: Vec::new(),
            const_exprs: Default::default(),
            typedef_texts: Default::default(),
            config_branch: false,
            guards: Default::default(),
            onehot_facts: Default::default(),
            loc: SourceLoc::file_start("t.sv"),
        };
        let mut ff = node("seq_q", "seq_d", AssignKind::Nonblocking, 0.0);
        ff.id = 10;
        m.nodes.insert(10, ff);
        let mut ff2 = node("idx_q", "idx_d", AssignKind::Nonblocking, 0.0);
        ff2.id = 11;
        m.nodes.insert(11, ff2);
        let mut ff3 = node("other_q", "x", AssignKind::Nonblocking, 0.0);
        ff3.id = 12;
        m.nodes.insert(12, ff3);
        let mut ff4 = node("wrap_q", "wrap_d", AssignKind::Nonblocking, 0.0);
        ff4.id = 13;
        m.nodes.insert(13, ff4);
        m.regions.insert(
            0,
            crate::ir::CombRegion {
                id: 0,
                module: 0,
                kind: RegionKind::AlwaysFf,
                label: None,
                gate: Default::default(),
                nodes: vec![10, 11, 12, 13],
                total_fo4: 0.0,
                loc_span: SourceLoc::file_start("t.sv"),
                multi_cycle: false,
            },
        );
        m
    }

    #[test]
    fn detects_register_plus_narrow_step_and_prices_the_select() {
        let e = env();
        let r = WidthResolver::from_parts(
            &e.packages,
            &e.ints,
            &e.decls,
            &e.ports,
            &e.consts,
            &e.typedefs,
            &e.imports,
            None,
        );
        let m = module_with_regs();
        let regs = register_roots(&m);
        assert!(regs.contains("seq_q") && regs.contains("idx_q"));
        let model = CostModel::default();
        let n = node("seq_d", "seq_q + 16'(step)", AssignKind::Continuous, 8.0);
        let s = detect(&m, &n, &regs, &r, &model).expect("shape");
        assert_eq!(s.reg_text, "seq_q");
        assert_eq!(s.step_ident, "step");
        assert_eq!(s.step_bits, 3);
        assert_eq!(s.candidates(), 8);
        assert_eq!(s.mux_levels(), 2);
        assert_eq!(s.width, Some(16));
        assert!(
            (s.fo4_after - 5.0).abs() < 1e-9,
            "two 4:1 levels: {}",
            s.fo4_after
        );
        assert!((s.gain() - 3.0).abs() < 1e-9);
        // Masked form keeps the mask inside the candidates (one extra gate).
        let n2 = node(
            "wrap_d",
            "(wrap_q + 16'(step)) & WrapMask",
            AssignKind::Continuous,
            8.0,
        );
        let s2 = detect(&m, &n2, &regs, &r, &model).expect("masked shape");
        assert_eq!(s2.mask_text.as_deref(), Some("WrapMask"));
        assert_eq!(s2.width, Some(16));
        assert!((s2.fo4_after - 6.0).abs() < 1e-9, "{}", s2.fo4_after);
        let snip = candidate_snippet(&s2, "wrap_d_svt_cand");
        assert!(
            snip.contains("var type(wrap_d) wrap_d_svt_cand [0:7];"),
            "{snip}"
        );
        assert!(
            snip.contains(
                "assign wrap_d_svt_cand[svt_j] = type(wrap_d)'(((wrap_q + svt_j) & WrapMask));"
            ),
            "{snip}"
        );
        // A 2-bit index add is cheaper than any select: no shape.
        let n3 = node(
            "idx_d",
            "(idx_q + idx_t'(step)) & IdxMask",
            AssignKind::Continuous,
            3.0,
        );
        assert!(detect(&m, &n3, &regs, &r, &model).is_none());
        assert_eq!(
            select_rhs("c", "step", 3),
            "(step[2] ? c[{1'b1, step[1:0]}] : c[{1'b0, step[1:0]}])"
        );
        assert_eq!(select_rhs("c", "s2", 2), "c[s2]");
    }

    #[test]
    fn refuses_wide_steps_register_steps_and_non_increment_shapes() {
        let e = env();
        let r = WidthResolver::from_parts(
            &e.packages,
            &e.ints,
            &e.decls,
            &e.ports,
            &e.consts,
            &e.typedefs,
            &e.imports,
            None,
        );
        let m = module_with_regs();
        let regs = register_roots(&m);
        let model = CostModel::default();
        // 8-bit step: 256 candidates, over the guard.
        assert!(detect(
            &m,
            &node("seq_d", "seq_q + wide_step", AssignKind::Continuous, 8.0),
            &regs,
            &r,
            &model
        )
        .is_none());
        // Register + register: both stable at the edge, nothing to move.
        assert!(detect(
            &m,
            &node("seq_d", "seq_q + other_q", AssignKind::Continuous, 8.0),
            &regs,
            &r,
            &model
        )
        .is_none());
        // Subtraction / non-register operand / NBA target.
        assert!(detect(
            &m,
            &node("seq_d", "seq_q - step", AssignKind::Continuous, 8.0),
            &regs,
            &r,
            &model
        )
        .is_none());
        assert!(detect(
            &m,
            &node("seq_d", "seq_d + step", AssignKind::Continuous, 8.0),
            &regs,
            &r,
            &model
        )
        .is_none());
        assert!(detect(
            &m,
            &node("seq_q", "seq_q + step", AssignKind::Nonblocking, 8.0),
            &regs,
            &r,
            &model
        )
        .is_none());
        // No gain: a 2-bit add (floored at 1 FO4) is cheaper than a select.
        assert!(detect(
            &m,
            &node("idx_d", "idx_q + step", AssignKind::Continuous, 1.0),
            &regs,
            &r,
            &model
        )
        .is_none());
    }
}
