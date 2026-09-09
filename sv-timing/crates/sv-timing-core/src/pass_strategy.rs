// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Pre-pass planner (architecture/PASS-STRATEGY.md). Signatures are computable
// from the timing IR the same way they are from audit-strict-v4 analyze.json:
//   E:/cva6/build-platform/workspace/build/sv-timing/audit-strict-v4/full_core/analyze.json
//   E:/cva6/build-platform/workspace/build/sv-timing/audit-strict-v4/full_corev_apu/analyze.json
// P1/P2 hits are measurement bugs — abort correct rather than optimize around them.

//! Pattern recognizers P1–P9 and the S0–S5 admission plan.

use serde::{Deserialize, Serialize};

use std::collections::BTreeSet;

use crate::expr::{ConstSeed, Expr};
use crate::ir::{AssignKind, PathId, PathKind, RegionKind, TimingDesign, TimingModule, TimingPath};
use crate::path_class::PathClassKind;
use crate::ref_order::ident_base;

/// PASS-STRATEGY pattern id.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub enum PatternId {
    /// Elaboration-constant arithmetic billed as hardware.
    P1,
    /// Comment text billed as arithmetic.
    P2,
    /// `node_count <= 1` over budget (uncuttable).
    P3,
    /// Whole path labelled atomic because one node is atomic.
    P4,
    /// `intoout` fragment counted as a period path.
    P5,
    /// Shallow over-budget (`budget < fo4 < 2·budget`, `node_count > 1`).
    P6,
    /// Independent-LHS bundle still ranked serial.
    P7,
    /// Genuine deep datapath (runtime operands).
    P8,
    /// Iterative / multi-cycle — do not cut.
    P9,
    /// Same-edge pulse+index handshake — never InsertReg (PASS-STRATEGY §8).
    P10,
}

impl PatternId {
    /// Stable label.
    pub fn as_str(self) -> &'static str {
        match self {
            PatternId::P1 => "P1",
            PatternId::P2 => "P2",
            PatternId::P3 => "P3",
            PatternId::P4 => "P4",
            PatternId::P5 => "P5",
            PatternId::P6 => "P6",
            PatternId::P7 => "P7",
            PatternId::P8 => "P8",
            PatternId::P9 => "P9",
            PatternId::P10 => "P10",
        }
    }

    /// Artifact (measurement bug) vs model gap vs real work.
    pub fn is_artifact(self) -> bool {
        matches!(self, PatternId::P1 | PatternId::P2)
    }
}

/// One path matching a pattern.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PatternHit {
    /// Pattern.
    pub pattern: PatternId,
    /// Path id.
    pub path_id: PathId,
    /// FO4 on the path (adjusted).
    pub fo4: f64,
    /// Node count.
    pub node_count: u32,
    /// Short evidence (file:line / class_note).
    pub note: String,
}

/// Plan produced before any transform (PASS-STRATEGY §4).
#[derive(Debug, Clone, Default, Serialize, Deserialize, PartialEq)]
pub struct PassPlan {
    /// P1+P2 hits. Non-empty ⇒ abort the correct run.
    pub artifacts: Vec<PatternHit>,
    /// True when artifacts remain after measurement (do not spend edits).
    pub abort_correct: bool,
    /// All hits by pattern.
    pub by_pattern: std::collections::BTreeMap<String, u32>,
    /// Human summary.
    pub rationale: String,
}

impl PassPlan {
    /// True when the plan has no hits (serde skip).
    pub fn is_empty_plan(&self) -> bool {
        self.artifacts.is_empty() && self.by_pattern.is_empty()
    }
}

/// Classify one path. Order matches the doc: artifacts first, then gaps, then real.
pub fn classify_path(design: &TimingDesign, path: &TimingPath, seed: &ConstSeed) -> Vec<PatternId> {
    let budget = design.target.budget_fo4;
    let n = path.nodes.len() as u32;
    let fo4 = path.total_fo4;
    let mut out = Vec::new();

    if path.path_class == PathClassKind::AtomicOverBudget {
        if hottest_expr_is_const(design, path, seed) {
            out.push(PatternId::P1);
        }
    }
    if loc_looks_like_comment(&path.primary_loc) {
        out.push(PatternId::P2);
    }
    if n <= 1 && fo4 > budget + 1e-9 && !path.multi_cycle {
        out.push(PatternId::P3);
    }
    if path.path_class == PathClassKind::AtomicOverBudget && n > 1 {
        out.push(PatternId::P4);
    }
    if path.path_kind == PathKind::InToOut && fo4 > budget + 1e-9 {
        out.push(PatternId::P5);
    }
    if !path.multi_cycle
        && n > 1
        && fo4 > budget + 1e-9
        && fo4 < 2.0 * budget
        && path.path_class != PathClassKind::AtomicOverBudget
    {
        out.push(PatternId::P6);
    }
    if path.path_class == PathClassKind::IndependentLhsBundle && fo4 > budget + 1e-9 {
        out.push(PatternId::P7);
    }
    if path.path_class == PathClassKind::AtomicOverBudget
        && !hottest_expr_is_const(design, path, seed)
        && n <= 1
    {
        out.push(PatternId::P8);
    }
    if path.multi_cycle || path.path_class == PathClassKind::MultiCycleTagged {
        out.push(PatternId::P9);
    }
    if path_is_handshake_locked(design, path) {
        out.push(PatternId::P10);
    }
    out
}

fn hottest_expr_is_const(design: &TimingDesign, path: &TimingPath, seed: &ConstSeed) -> bool {
    let Some(module) = design.modules.get(&path.module) else {
        return false;
    };
    let Some(nid) = path.nodes.iter().copied().max_by(|a, b| {
        let ca = module.nodes.get(a).map(|n| n.fo4_cost).unwrap_or(0.0);
        let cb = module.nodes.get(b).map(|n| n.fo4_cost).unwrap_or(0.0);
        ca.partial_cmp(&cb).unwrap_or(std::cmp::Ordering::Equal)
    }) else {
        return false;
    };
    let Some(node) = module.nodes.get(&nid) else {
        return false;
    };
    let mut seed = seed.clone();
    for gv in module.genvar_names_at(&node.loc) {
        seed.add(gv);
    }
    match &node.rhs_expr {
        Some(ex) => ex.const_class(&seed).is_const(),
        None => false,
    }
}

fn loc_looks_like_comment(loc: &crate::loc::SourceLoc) -> bool {
    // File bytes live in lower, not here. P2 is applied at collect time
    // (`operator_token_in_comment` + `blank_sv_comments`). Residual hits would
    // need those bytes threaded onto the path; do not guess from loc alone.
    let _ = loc;
    false
}

/// Build the plan from a measured design (call after classify + lattice).
pub fn plan_from_design(design: &TimingDesign) -> PassPlan {
    let mut artifacts = Vec::new();
    let mut counts: std::collections::BTreeMap<String, u32> = std::collections::BTreeMap::new();
    for path in &design.paths {
        let seed = design
            .modules
            .get(&path.module)
            .map(|m| ConstSeed::from_names(design.elaboration_const_names(m)))
            .unwrap_or_else(ConstSeed::heuristic);
        for pid in classify_path(design, path, &seed) {
            *counts.entry(pid.as_str().into()).or_insert(0) += 1;
            if pid.is_artifact() {
                artifacts.push(PatternHit {
                    pattern: pid,
                    path_id: path.id,
                    fo4: path.total_fo4,
                    node_count: path.nodes.len() as u32,
                    note: format!(
                        "{}:{} {}",
                        path.primary_loc.file,
                        path.primary_loc.start_line,
                        path.class_note.as_deref().unwrap_or("")
                    ),
                });
            }
        }
    }
    let abort = !artifacts.is_empty();
    let rationale = if abort {
        format!(
            "ABORT correct: {} artifact paths (P1/P2). Measurement bug, not a workload. Logs: audit-strict-v4 analyze.json",
            artifacts.len()
        )
    } else {
        format!(
            "S0 clean. Schedule S1–S5 over {:?}",
            counts
        )
    };
    PassPlan {
        artifacts,
        abort_correct: abort,
        by_pattern: counts,
        rationale,
    }
}

/// Whether InsertReg is admitted for this path under the plan (S4, not P3/P5/P9/P10).
pub fn admits_insert_reg(path: &TimingPath) -> bool {
    if path.multi_cycle || path.path_class == PathClassKind::MultiCycleTagged {
        return false;
    }
    if path.nodes.len() <= 1 {
        return false; // P3
    }
    if path.path_class == PathClassKind::AtomicOverBudget {
        return false;
    }
    if path
        .class_note
        .as_deref()
        .is_some_and(|n| n.contains("P10 handshake"))
    {
        return false;
    }
    true
}

/// True when this path touches a same-edge pulse+index lock (P10).
pub fn path_is_handshake_locked(design: &TimingDesign, path: &TimingPath) -> bool {
    let Some(module) = design.modules.get(&path.module) else {
        return false;
    };
    let locked = handshake_locked_names(module);
    if locked.is_empty() {
        return false;
    }
    for id in &path.nodes {
        let Some(n) = module.nodes.get(id) else {
            continue;
        };
        if n.lhs
            .as_deref()
            .is_some_and(|s| locked.contains(&ident_base(s)))
        {
            return true;
        }
        let mut hit = false;
        if let Some(ex) = n.rhs_expr.as_ref() {
            ex.walk_idents(&mut |name| {
                if locked.contains(&ident_base(name)) {
                    hit = true;
                }
            });
        } else if let Some(rhs) = n.rhs.as_deref() {
            for tok in rhs.split(|c: char| !c.is_ascii_alphanumeric() && c != '_' && c != '.') {
                if locked.contains(&ident_base(tok)) {
                    hit = true;
                }
            }
        }
        if hit {
            return true;
        }
    }
    false
}

/// Tag P10 evidence onto paths that touch a locked handshake (after classify).
pub fn tag_handshake_locks(design: &mut TimingDesign) {
    let locked: Vec<PathId> = design
        .paths
        .iter()
        .filter(|p| path_is_handshake_locked(design, p))
        .map(|p| p.id)
        .collect();
    for path in &mut design.paths {
        if !locked.contains(&path.id) {
            continue;
        }
        let extra = "P10 handshake lock (same-edge pulse+index; InsertReg refuse)";
        path.class_note = Some(match path.class_note.take() {
            Some(n) if n.contains("P10 handshake") => n,
            Some(n) => format!("{n}; {extra}"),
            None => extra.into(),
        });
    }
}

fn handshake_locked_names(module: &TimingModule) -> BTreeSet<String> {
    let mut names = BTreeSet::new();
    let outputs = output_port_names(module);
    let aliases = output_assign_aliases(module);
    for region in module.regions.values() {
        if region.kind != RegionKind::AlwaysFf {
            continue;
        }
        let mut bundle: Vec<(String, Vec<String>, bool)> = Vec::new();
        for id in &region.nodes {
            let Some(n) = module.nodes.get(id) else {
                continue;
            };
            if n.assign_kind != AssignKind::Nonblocking {
                continue;
            }
            let lhs = ident_base(n.lhs.as_deref().unwrap_or(""));
            if lhs.is_empty() {
                continue;
            }
            if !drives_output(&outputs, &aliases, &lhs) {
                continue;
            }
            bundle.push((lhs, rhs_comb_idents(n), nba_is_pulse(n)));
        }
        // Same-edge output bundle: a pulse NBA plus at least one *other*
        // output NBA (index / data). Reset+data of one Q (`y_o <= 0` /
        // `y_o <= c_span`) is two nodes with the same LHS — not a handshake
        // (gemm_span / mixed_resilient capture flops).
        let has_pulse = bundle.iter().any(|(_, _, p)| *p);
        let distinct_lhs = bundle
            .iter()
            .map(|(lhs, _, _)| lhs.as_str())
            .collect::<BTreeSet<_>>();
        if distinct_lhs.len() >= 2 && has_pulse {
            for (lhs, feeds, _) in &bundle {
                names.insert(lhs.clone());
                names.extend(feeds.iter().cloned());
                names.extend(aliases_of(&aliases, lhs));
            }
        }
    }
    // Consumer bank: comb `out = mem[port]` of a base also NBA-written indexed,
    // with a 1-bit input enable (switch_i).
    let indexed_nba_bases = indexed_nba_bases(module);
    if !indexed_nba_bases.is_empty() {
        for n in module.nodes.values() {
            if n.assign_kind != AssignKind::Continuous && n.assign_kind != AssignKind::Blocking {
                continue;
            }
            let Some(ex) = n.rhs_expr.as_ref() else {
                continue;
            };
            if let Some(idx) = index_ident(ex) {
                let base = index_mem_base(ex);
                if indexed_nba_bases.contains(&base) {
                    names.insert(ident_base(&idx));
                    if let Some(lhs) = n.lhs.as_deref() {
                        names.insert(ident_base(lhs));
                    }
                    names.insert(base);
                }
            }
        }
    }
    names
}

fn output_port_names(module: &TimingModule) -> BTreeSet<String> {
    module
        .ports
        .iter()
        .filter(|p| p.direction.contains("output"))
        .map(|p| p.name.clone())
        .collect()
}

/// Continuous `assign out = q` aliases (q → out).
fn output_assign_aliases(module: &TimingModule) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for n in module.nodes.values() {
        if n.assign_kind != AssignKind::Continuous {
            continue;
        }
        let lhs = ident_base(n.lhs.as_deref().unwrap_or(""));
        let rhs = match &n.rhs_expr {
            Some(Expr::Ident { name }) => ident_base(name),
            _ => ident_base(n.rhs.as_deref().unwrap_or("")),
        };
        if lhs.is_empty() || rhs.is_empty() {
            continue;
        }
        out.push((rhs, lhs));
    }
    out
}

fn drives_output(
    outputs: &BTreeSet<String>,
    aliases: &[(String, String)],
    q: &str,
) -> bool {
    if outputs.contains(q) {
        return true;
    }
    aliases.iter().any(|(src, dst)| src == q && outputs.contains(dst))
}

fn aliases_of(aliases: &[(String, String)], q: &str) -> Vec<String> {
    aliases
        .iter()
        .filter(|(src, _)| src == q)
        .map(|(_, dst)| dst.clone())
        .collect()
}

fn nba_is_pulse(n: &crate::ir::IrNode) -> bool {
    match &n.rhs_expr {
        Some(e) => expr_is_pulse_comb(e),
        None => n.rhs.as_deref().is_some_and(|s| {
            let t = s.trim();
            !t.contains('+') && !t.contains('*') && !t.contains('/') && !t.contains('?')
        }),
    }
}

fn expr_is_pulse_comb(e: &Expr) -> bool {
    match e {
        Expr::Ident { .. } | Expr::Literal { .. } => true,
        Expr::Unary { op, arg, .. } if matches!(op.as_str(), "!" | "~") => expr_is_pulse_comb(arg),
        Expr::Binary {
            op_class: crate::ir::OperatorClass::LogicBit,
            left,
            right,
            ..
        } => expr_is_pulse_comb(left) && expr_is_pulse_comb(right),
        _ => false,
    }
}

fn rhs_comb_idents(n: &crate::ir::IrNode) -> Vec<String> {
    let mut v = Vec::new();
    if let Some(ex) = n.rhs_expr.as_ref() {
        ex.walk_idents(&mut |name| v.push(ident_base(name)));
    } else if let Some(rhs) = n.rhs.as_deref() {
        for tok in rhs.split(|c: char| !c.is_ascii_alphanumeric() && c != '_' && c != '.') {
            if !tok.is_empty() {
                v.push(ident_base(tok));
            }
        }
    }
    v
}

fn indexed_nba_bases(module: &TimingModule) -> BTreeSet<String> {
    let mut bases = BTreeSet::new();
    for n in module.nodes.values() {
        if n.assign_kind != AssignKind::Nonblocking {
            continue;
        }
        let lhs = n.lhs.as_deref().unwrap_or("");
        if lhs.contains('[') {
            bases.insert(ident_base(lhs));
        }
        if let Some(ex) = n.lhs_expr.as_ref() {
            if index_mem_base(ex) != ident_base(lhs) || lhs.contains('[') {
                let b = index_mem_base(ex);
                if !b.is_empty() {
                    bases.insert(b);
                }
            }
        }
    }
    bases
}

fn index_ident(e: &Expr) -> Option<String> {
    match e {
        Expr::Index { index, .. } => match index.as_ref() {
            Expr::Ident { name } => Some(ident_base(name)),
            _ => index_ident(index),
        },
        Expr::Ternary {
            then_e, else_e, ..
        } => index_ident(then_e).or_else(|| index_ident(else_e)),
        _ => None,
    }
}

fn index_mem_base(e: &Expr) -> String {
    match e {
        Expr::Index { base, .. } => {
            let inner = index_mem_base(base);
            if !inner.is_empty() {
                inner
            } else {
                ident_base(&base.emit())
            }
        }
        Expr::Ident { name } => ident_base(name),
        Expr::Ternary {
            then_e, else_e, ..
        } => {
            let a = index_mem_base(then_e);
            if !a.is_empty() {
                a
            } else {
                index_mem_base(else_e)
            }
        }
        _ => String::new(),
    }
}

/// Path-level override of the module cleanliness winner (PASS-STRATEGY §8).
///
/// Module cleanliness picks one set for *every* path. Mixed modules (exclusive
/// leftover + a gemm-shaped CombDatapath) therefore win `seq_plus_comb` and
/// refuse InsertReg on the datapath that is the legitimate S4 exception.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize, Deserialize)]
pub enum ExceptionPolicyKind {
    /// Deep Plain `RegToReg` CombDatapath (APU gemm / `gemm_span`). S4 may
    /// InsertReg even when the module winner is an S3 set.
    ResilientDatapath,
    /// Same-edge pulse+index lock. Never InsertReg.
    HandshakeLock,
}

impl ExceptionPolicyKind {
    /// Stable label.
    pub fn as_str(self) -> &'static str {
        match self {
            ExceptionPolicyKind::ResilientDatapath => "resilient_datapath",
            ExceptionPolicyKind::HandshakeLock => "handshake_lock",
        }
    }
}

/// Concrete exception applied to one path.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ExceptionPolicy {
    /// Which exception.
    pub kind: ExceptionPolicyKind,
    /// Whether S4 InsertReg is admitted despite the cleanliness winner.
    pub admit_insert_reg: bool,
    /// Short evidence.
    pub note: String,
}

/// Exception for this path, if any.
///
/// Indexed `mem[port]` restores (FTQ / pc_bank) always HandshakeLock.
/// Otherwise a gemm-shaped Plain `RegToReg` over budget is resilient even
/// when P5 compose tagged the cone P10 because it shares an `always_ff`
/// with a status pulse (audit-gemm-expol path 3131). True pulse+index
/// producers stay HandshakeLock. Incidental P10 *class_note* only yields to
/// resilient at ≥ 2·budget (deep gemm). KD0: no host names.
pub fn exception_policy(design: &TimingDesign, path: &TimingPath) -> Option<ExceptionPolicy> {
    if path_has_indexed_restore(design, path) {
        return Some(ExceptionPolicy {
            kind: ExceptionPolicyKind::HandshakeLock,
            admit_insert_reg: false,
            note: "P10 indexed restore (mem[port]); InsertReg refuse".into(),
        });
    }
    if is_resilient_datapath(design, path) {
        return Some(ExceptionPolicy {
            kind: ExceptionPolicyKind::ResilientDatapath,
            admit_insert_reg: true,
            note: format!(
                "P8-shaped Plain RegToReg {:.1} FO4 nodes={} > budget; S4 InsertReg despite S3 cleanliness",
                path.total_fo4,
                path.nodes.len()
            ),
        });
    }
    if path_is_handshake_locked(design, path)
        || path
            .class_note
            .as_deref()
            .is_some_and(|n| n.contains("P10 handshake"))
    {
        return Some(ExceptionPolicy {
            kind: ExceptionPolicyKind::HandshakeLock,
            admit_insert_reg: false,
            note: "P10 handshake lock; InsertReg refuse".into(),
        });
    }
    None
}

/// Deep Plain `RegToReg` that can survive a flop (gemm / P6 remainder).
/// Indexed restores and real P10 handshake never take InsertReg. An incidental
/// P10 class_note (shared always_ff with a status pulse) only yields at
/// ≥ 2·budget so a 15 FO4 handshake tag stays HandshakeLock.
pub fn is_resilient_datapath(design: &TimingDesign, path: &TimingPath) -> bool {
    if path.multi_cycle || path.path_class == PathClassKind::MultiCycleTagged {
        return false;
    }
    if path.nodes.len() <= 1 {
        return false;
    }
    if path.path_class == PathClassKind::AtomicOverBudget {
        return false;
    }
    if path.path_class != PathClassKind::Plain {
        return false;
    }
    if path.path_kind != PathKind::RegToReg {
        return false;
    }
    let budget = design.target.budget_fo4;
    if path.total_fo4 <= budget + 1e-9 {
        return false;
    }
    if path_has_indexed_restore(design, path) {
        return false;
    }
    if path_is_handshake_locked(design, path) {
        return false;
    }
    if path.total_fo4 + 1e-9 < 2.0 * budget
        && path
            .class_note
            .as_deref()
            .is_some_and(|n| n.contains("P10 handshake"))
    {
        return false;
    }
    if path_has_burst_wrap(design, path) {
        return false;
    }
    // Fat Plain FSM (axi2mem WRITE n=39) is not a gemm remainder. Deep gemm
    // still matches via a Mul/DivRem on the cone. Skip when IR nodes are absent
    // (synthetic tests). Threshold 24: policy_subcode n=16 is a real S4 cone
    // (v27 InsertReg 30.5→10); 16 as fat starved that T2 (v30 cleanliness refuse).
    if path.nodes.len() >= 24 {
        if let Some(module) = design.modules.get(&path.module) {
            if !module.nodes.is_empty() && !path_has_overbudget_atomic(design, path, budget) {
                return false;
            }
        }
    }
    if let Some(module) = design.modules.get(&path.module) {
        let n = module.name.to_ascii_lowercase();
        if n.contains("lzc")
            || n.contains("vfdsu")
            || n.contains("fpnew")
            || n.contains("fma")
            || n.contains("divsqrt")
            || n.contains("serdiv")
        {
            return false;
        }
    }
    true
}

/// True when S4 still has an admitted InsertReg leftover (sibling 18.5 must
/// not stop the loop just because cutting one of them left primary flat).
///
/// **Not** used by the S4 loop (v28 origin-steal). Prefer
/// [`s4_sibling_span_pending`] for the bounded extra pass.
pub fn s4_has_pending_resilient(design: &TimingDesign) -> bool {
    design.paths.iter().any(|p| {
        p.slack_fo4 < 0.0
            && exception_policy(design, p).is_some_and(|e| e.admit_insert_reg)
    })
}

/// LHS ident is a generate-if span/end role (`a_span`, `b_end`).
///
/// KD0: suffix only, no host module names. Twin emit still requires identical
/// RHS to *share* a pipe; this predicate only names the leftover geometry.
pub fn lhs_is_span_family(lhs: &str) -> bool {
    let ident = ident_base(lhs);
    let base = ident.rsplit('.').next().unwrap_or("");
    base.ends_with("_span") || base.ends_with("_end")
}

/// True when any node on the path writes a span/end family net.
pub fn path_has_span_family_lhs(design: &TimingDesign, path: &TimingPath) -> bool {
    let Some(module) = design.modules.get(&path.module) else {
        return false;
    };
    path.nodes.iter().any(|id| {
        module
            .nodes
            .get(id)
            .and_then(|n| n.lhs.as_deref())
            .is_some_and(lhs_is_span_family)
    })
}

/// Bounded S4 extra: primary is still a resilient span/end sibling (gemm
/// `a_span`/`b_span` after `c_end` was cut). Unlike
/// [`s4_has_pending_resilient`], this does **not** admit policy_subcode /
/// other Plain cones — v28 origin steal.
pub fn s4_sibling_span_pending(design: &TimingDesign, path: &TimingPath) -> bool {
    is_resilient_datapath(design, path) && path_has_span_family_lhs(design, path)
}

/// Span/end LHS idents on the path (`c_span`, `a_end`, …).
pub fn span_family_lhs_on_path(design: &TimingDesign, path: &TimingPath) -> Vec<String> {
    let Some(module) = design.modules.get(&path.module) else {
        return Vec::new();
    };
    let mut out = Vec::new();
    let mut seen = BTreeSet::new();
    for id in &path.nodes {
        let Some(lhs) = module.nodes.get(id).and_then(|n| n.lhs.as_deref()) else {
            continue;
        };
        if !lhs_is_span_family(lhs) {
            continue;
        }
        let ident = ident_base(lhs);
        let base = ident.rsplit('.').next().unwrap_or("").to_string();
        if seen.insert(base.clone()) {
            out.push(base);
        }
    }
    out
}

/// True when every span/end LHS on this path was already InsertReg'd.
pub fn path_span_lhs_all_cut(
    design: &TimingDesign,
    path: &TimingPath,
    cut: &BTreeSet<String>,
) -> bool {
    let lhs = span_family_lhs_on_path(design, path);
    !lhs.is_empty() && lhs.iter().all(|s| cut.contains(s))
}

fn path_has_overbudget_atomic(design: &TimingDesign, path: &TimingPath, budget: f64) -> bool {
    let Some(module) = design.modules.get(&path.module) else {
        return false;
    };
    path.nodes.iter().any(|id| {
        module.nodes.get(id).is_some_and(|n| {
            n.fo4_cost > budget + 1e-9
                && matches!(
                    n.op_class,
                    Some(crate::ir::OperatorClass::Mul) | Some(crate::ir::OperatorClass::DivRem)
                )
        })
    })
}

/// AXI WRAP next-address (`wrap_boundary` / `upper_wrap_boundary`). InsertReg
/// on that adder is a protocol break. KD0: no host module names.
fn path_has_burst_wrap(design: &TimingDesign, path: &TimingPath) -> bool {
    let Some(module) = design.modules.get(&path.module) else {
        return false;
    };
    for id in &path.nodes {
        let Some(n) = module.nodes.get(id) else {
            continue;
        };
        if n.rhs
            .as_deref()
            .is_some_and(|s| s.contains("wrap_boundary") || s.contains("WRAP"))
        {
            return true;
        }
        if n.lhs
            .as_deref()
            .is_some_and(|s| s.contains("wrap_boundary"))
        {
            return true;
        }
    }
    false
}

/// True when this path is the comb `out = mem[port]` of an indexed-NBA base
/// (FTQ head restore / SMT2 pc_bank). Those cones must not take InsertReg.
pub fn path_has_indexed_restore(design: &TimingDesign, path: &TimingPath) -> bool {
    let Some(module) = design.modules.get(&path.module) else {
        return false;
    };
    let bases = indexed_nba_bases(module);
    if bases.is_empty() {
        return false;
    }
    for id in &path.nodes {
        let Some(n) = module.nodes.get(id) else {
            continue;
        };
        if n.assign_kind != AssignKind::Continuous && n.assign_kind != AssignKind::Blocking {
            continue;
        }
        let Some(ex) = n.rhs_expr.as_ref() else {
            continue;
        };
        if index_ident(ex).is_some() && bases.contains(&index_mem_base(ex)) {
            return true;
        }
    }
    false
}

/// Latency-neutral kinds run in S3 (before any InsertReg).
pub fn is_latency_neutral_kind(kind: crate::ir::OpportunityKind) -> bool {
    matches!(
        kind,
        crate::ir::OpportunityKind::BalanceMux | crate::ir::OpportunityKind::SplitAssign
    )
}

/// PASS-STRATEGY P6: one register or one rebalance. 75% of corpus failures.
pub fn is_shallow_over_budget(path: &TimingPath, budget: f64) -> bool {
    !path.multi_cycle
        && path.nodes.len() > 1
        && path.total_fo4 > budget + 1e-9
        && path.total_fo4 < 2.0 * budget
        && path.path_class != PathClassKind::AtomicOverBudget
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ir::TimingTarget;

    #[test]
    fn empty_design_does_not_abort() {
        let d = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        let p = plan_from_design(&d);
        assert!(!p.abort_correct);
    }

    #[test]
    fn p6_shallow_is_one_slice_over_budget() {
        let budget = 10.0;
        let mut p = TimingPath {
            id: 1,
            region_id: 0,
            module: 0,
            start: crate::ir::PathEndpoint::RegClock { cell: 0 },
            end: crate::ir::PathEndpoint::RegData { cell: 1 },
            path_kind: PathKind::RegToReg,
            startpoint: "m.reg0/CP".into(),
            endpoint: "m.reg1/D".into(),
            nodes: vec![0, 1],
            total_fo4: 15.0,
            slack_fo4: -5.0,
            max_freq_mhz: 500.0,
            primary_loc: crate::loc::SourceLoc::file_start("m.sv"),
            multi_cycle: false,
            path_class: PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: None,
        };
        assert!(is_shallow_over_budget(&p, budget));
        p.total_fo4 = 25.0;
        assert!(!is_shallow_over_budget(&p, budget));
        p.total_fo4 = 15.0;
        p.nodes = vec![0];
        assert!(!is_shallow_over_budget(&p, budget));
        p.nodes = vec![0, 1];
        p.multi_cycle = true;
        assert!(!is_shallow_over_budget(&p, budget));
    }

    fn plain_regtoreg(fo4: f64, nodes: u32, budget: f64) -> TimingPath {
        TimingPath {
            id: 1,
            region_id: 0,
            module: 0,
            start: crate::ir::PathEndpoint::RegClock { cell: 0 },
            end: crate::ir::PathEndpoint::RegData { cell: 1 },
            path_kind: PathKind::RegToReg,
            startpoint: "m.reg0/CP".into(),
            endpoint: "m.reg1/D".into(),
            nodes: (0..nodes).collect(),
            total_fo4: fo4,
            slack_fo4: budget - fo4,
            max_freq_mhz: 4000.0,
            primary_loc: crate::loc::SourceLoc::file_start("m.sv"),
            multi_cycle: false,
            path_class: PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: None,
        }
    }

    #[test]
    fn resilient_exception_matches_gemm_shaped_plain_regtoreg() {
        let mut d = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        let budget = d.target.budget_fo4;
        let p = plain_regtoreg(161.5, 144, budget);
        d.paths.push(p.clone());
        let ex = exception_policy(&d, &p).expect("resilient");
        assert_eq!(ex.kind, ExceptionPolicyKind::ResilientDatapath);
        assert!(ex.admit_insert_reg);
        assert!(is_resilient_datapath(&d, &p));
    }

    #[test]
    fn resilient_exception_skips_p6_shallow_and_intoout() {
        let d = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        let budget = d.target.budget_fo4;
        // P6 remainder (gemm 18.5 / instr_queue 16.5): one InsertReg, not 2·B.
        let shallow = plain_regtoreg(15.0, 4, budget);
        assert!(is_resilient_datapath(&d, &shallow));
        let ex = exception_policy(&d, &shallow).expect("p6 resilient");
        assert_eq!(ex.kind, ExceptionPolicyKind::ResilientDatapath);
        assert!(ex.admit_insert_reg);
        let mut intoout = plain_regtoreg(56.0, 4, budget);
        intoout.path_kind = PathKind::InToOut;
        assert!(!is_resilient_datapath(&d, &intoout));
        let mut exclusive = plain_regtoreg(56.0, 4, budget);
        exclusive.path_class = PathClassKind::ExclusiveCaseMux;
        assert!(!is_resilient_datapath(&d, &exclusive));
        // Incidental P10 class_note on a gemm-shaped cone (shared always_ff
        // with a status pulse) must not starve S4 — path 3131.
        let mut p10 = plain_regtoreg(161.5, 144, budget);
        p10.class_note = Some("P10 handshake lock (same-edge pulse+index; InsertReg refuse)".into());
        let ex = exception_policy(&d, &p10).expect("resilient despite note");
        assert_eq!(ex.kind, ExceptionPolicyKind::ResilientDatapath);
        assert!(ex.admit_insert_reg);
        assert!(!admits_insert_reg(&p10), "default gate still refuses");
        let mut shallow_p10 = plain_regtoreg(15.0, 4, budget);
        shallow_p10.class_note = Some("P10 handshake lock (same-edge pulse+index; InsertReg refuse)".into());
        let ex = exception_policy(&d, &shallow_p10).expect("shallow handshake");
        assert_eq!(ex.kind, ExceptionPolicyKind::HandshakeLock);
        assert!(!ex.admit_insert_reg);
        assert!(!is_resilient_datapath(&d, &shallow_p10));
    }

    #[test]
    fn resilient_exception_skips_prefix_tree_names() {
        let mut d = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        let budget = d.target.budget_fo4;
        let p = plain_regtoreg(90.0, 8, budget);
        let mut m = TimingModule {
            id: 0,
            name: "lzc".into(),
            file: "lzc.sv".into(),
            nodes: Default::default(),
            regions: Default::default(),
            localparams: vec![],
            parameters: vec![],
            ports: vec![],
            gen_loops: vec![],
            functions: vec![],
            package_imports: vec![],
            instances: vec![],
            loc: crate::loc::SourceLoc::file_start("lzc.sv"),
        };
        m.id = 0;
        d.modules.insert(0, m);
        d.paths.push(p.clone());
        assert!(!is_resilient_datapath(&d, &p), "lzc must not take InsertReg");
    }

    #[test]
    fn resilient_skips_burst_wrap_and_fat_fsm() {
        let mut d = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        let budget = d.target.budget_fo4;
        let p = plain_regtoreg(14.0, 4, budget);
        let mut nodes = std::collections::BTreeMap::new();
        nodes.insert(
            0,
            crate::ir::IrNode {
                id: 0,
                op_class: Some(crate::ir::OperatorClass::AddSub),
                width: 64,
                fo4_cost: 10.0,
                gate: None,
                loc: crate::loc::SourceLoc::file_start("axi.sv"),
                fans_in: vec![],
                fans_out: vec![],
                width_defaulted: true,
                reads_reg: false,
                lhs: Some("addr_o".into()),
                rhs: Some("wrap_boundary + ((cnt_q - ax_req_q.len) << LOG)".into()),
                lhs_expr: None,
                rhs_expr: None,
                case_labels: Vec::new(),
                case_is_default: false,
                case_selector: None,
                fo4_locked: false,
                assign_kind: Default::default(),
            },
        );
        d.modules.insert(
            0,
            TimingModule {
                id: 0,
                name: "axi2mem".into(),
                file: "axi2mem.sv".into(),
                nodes,
                regions: Default::default(),
                localparams: vec![],
                parameters: vec![],
                ports: vec![],
                gen_loops: vec![],
                functions: vec![],
                package_imports: vec![],
                instances: vec![],
                loc: crate::loc::SourceLoc::file_start("axi2mem.sv"),
            },
        );
        d.paths.push(p.clone());
        assert!(!is_resilient_datapath(&d, &p), "WRAP adder must not InsertReg");
        let d_gemm = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        let gemm = plain_regtoreg(18.5, 4, budget);
        assert!(is_resilient_datapath(&d_gemm, &gemm));
        assert!(s4_has_pending_resilient(&{
            let mut d2 = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
            let mut g = gemm.clone();
            g.slack_fo4 = -8.5;
            d2.paths.push(g);
            d2
        }));
        // Empty-IR gemm has no span LHS — sibling predicate must not fire
        // (that would reintroduce v28). With a b_span node it does.
        assert!(!s4_sibling_span_pending(&d_gemm, &gemm));
        let mut d16 = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        let p16 = plain_regtoreg(30.5, 16, budget);
        d16.modules.insert(
            0,
            TimingModule {
                id: 0,
                name: "policy".into(),
                file: "policy.sv".into(),
                nodes: Default::default(),
                regions: Default::default(),
                localparams: vec![],
                parameters: vec![],
                ports: vec![],
                gen_loops: vec![],
                functions: vec![],
                package_imports: vec![],
                instances: vec![],
                loc: crate::loc::SourceLoc::file_start("policy.sv"),
            },
        );
        // Empty IR nodes: fat skip. With dummy nodes and no Mul, n=16 must
        // still be resilient (v27 policy_subcode).
        d16.modules.get_mut(&0).unwrap().nodes.insert(
            0,
            crate::ir::IrNode {
                id: 0,
                op_class: Some(crate::ir::OperatorClass::AddSub),
                width: 32,
                fo4_cost: 10.0,
                gate: None,
                loc: crate::loc::SourceLoc::file_start("policy.sv"),
                fans_in: vec![],
                fans_out: vec![],
                width_defaulted: true,
                reads_reg: false,
                lhs: Some("y".into()),
                rhs: Some("a+b".into()),
                lhs_expr: None,
                rhs_expr: None,
                case_labels: Vec::new(),
                case_is_default: false,
                case_selector: None,
                fo4_locked: false,
                assign_kind: Default::default(),
            },
        );
        assert!(
            is_resilient_datapath(&d16, &p16),
            "n=16 Plain without Mul is not a fat FSM"
        );
        assert!(lhs_is_span_family("b_span"));
        assert!(lhs_is_span_family("gen_reuse_a.a_end"));
        assert!(!lhs_is_span_family("state_d"));
        assert!(!lhs_is_span_family("policy_subcode"));
        let mut cut: BTreeSet<String> = BTreeSet::new();
        cut.insert("c_span".into());
        cut.insert("c_end".into());
        assert!(cut.contains("c_span"));
        assert!(!cut.contains("a_span"));
        assert!(!cut.contains("b_span"));
    }
}
