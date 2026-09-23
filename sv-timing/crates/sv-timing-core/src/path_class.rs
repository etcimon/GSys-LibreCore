// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Post-emptive FO4 path classification: exclusive-case re-cost, atomic gates,
// and cheap under-budget short-circuit so later algorithms stay simple.

//! Path classification and bottleneck exceptions.
//!
//! After raw path FO4 is attributed (sum of node critical FO4), high-FO4 paths
//! are scanned with **expensive** pattern detectors. Matches become
//! [`PathException`] records: FO4 may be adjusted (e.g. exclusive `unique case`
//! arms → max-arm + mux, not sum-of-arms). Paths already under budget are
//! labeled [`PathClassKind::UnderBudget`] with **no** expensive scan.
//!
//! Cached analyze stores exceptions with the design blob and in a dedicated
//! `path_class` table so subsequent hits can skip re-detection when the path
//! signature is unchanged.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::ir::{NodeId, OperatorClass, PathId, TimingDesign};
use crate::measure::CostModel;
use crate::parallel_timing::ParallelScratch;
use crate::ref_order::{ident_base, RefOrderTree};

/// Coarse path class used by measure, suggest, correct, and cache.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PathClassKind {
    /// Ordinary combinational chain — raw sum FO4 is trusted.
    #[default]
    Plain,
    /// Already ≤ budget after raw sum; skip expensive detectors.
    UnderBudget,
    /// Tagged multi-cycle (serdiv, etc.); excluded from primary ranking.
    MultiCycleTagged,
    /// Shared LHS / exclusive case-arm sum inflated FO4; adjusted to max+mux.
    ExclusiveCaseMux,
    /// Shared LHS if/else-style; adjusted with priority-mux levels.
    ExclusiveIfChain,
    /// Many distinct LHS chained only by statement order (always_comb fanout);
    /// adjusted to max(per-LHS) + bundle overhead — not sum of all assigns.
    IndependentLhsBundle,
    /// Dense always_comb / FSM with many small ops (few recoverable multi-LHS);
    /// adjusted to max_node + control mux/wire tax — not serial sum.
    DenseControlCone,
    /// Single Mul/DivRem (or dominant) exceeds budget — cannot InsertReg away.
    AtomicOverBudget,
}

/// Detector pipeline version — bump when adding detectors so plain cache hits re-scan.
pub const PATH_CLASS_DETECTOR_VERSION: u32 = 24;

impl PathClassKind {
    /// True when InsertReg multi-cut is a poor first tool.
    pub fn discourages_insert_reg(self) -> bool {
        matches!(
            self,
            PathClassKind::ExclusiveCaseMux
                | PathClassKind::ExclusiveIfChain
                | PathClassKind::IndependentLhsBundle
                | PathClassKind::DenseControlCone
                | PathClassKind::AtomicOverBudget
                | PathClassKind::MultiCycleTagged
                | PathClassKind::UnderBudget
        )
    }

    /// True when only cheap algorithms should run (no pattern re-scan needed).
    pub fn is_simple(self) -> bool {
        matches!(
            self,
            PathClassKind::Plain | PathClassKind::UnderBudget | PathClassKind::MultiCycleTagged
        )
    }
}

/// One detector attempt (for diagnostics + cache).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PatternAttempt {
    /// Detector name.
    pub detector: String,
    /// Whether it fired and produced a candidate adjustment.
    pub matched: bool,
    /// Candidate adjusted FO4 when matched.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub candidate_fo4: Option<f64>,
    /// Short note.
    pub note: String,
}

/// Recorded exception / classification for one path (post-emptive).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PathException {
    /// Path id.
    pub path_id: PathId,
    /// Module name (when known).
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub module_name: String,
    /// Final class.
    pub path_class: PathClassKind,
    /// FO4 before adjustment (raw sum).
    pub raw_fo4: f64,
    /// FO4 after adjustment (equals raw when Plain / UnderBudget).
    pub adjusted_fo4: f64,
    /// 0..1 confidence in the adjustment.
    pub confidence: f64,
    /// Human evidence.
    pub evidence: String,
    /// Detectors tried (including non-matches) for high-FO4 paths.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub attempted: Vec<PatternAttempt>,
    /// Stable signature for cache reuse (module/region/node shape).
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub signature: String,
}

/// Optional cache-supplied hint: re-apply without re-running all detectors.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct PathClassHint {
    /// Path signature ([`path_signature`]).
    pub signature: String,
    /// Cached class.
    pub path_class: PathClassKind,
    /// Cached raw FO4 when stored (informational).
    pub raw_fo4: f64,
    /// Cached adjusted FO4 formula result (or prior adjusted).
    pub adjusted_fo4: f64,
    /// Confidence.
    pub confidence: f64,
    /// Evidence string.
    pub evidence: String,
}

/// Build a stable signature for a path's structural shape (not FO4 numbers).
pub fn path_signature(
    module_name: &str,
    region_id: u32,
    node_ids: &[NodeId],
    lhs_histogram: &BTreeMap<String, usize>,
) -> String {
    let mut parts: Vec<String> = lhs_histogram
        .iter()
        .map(|(l, n)| format!("{l}:{n}"))
        .collect();
    parts.sort();
    format!(
        "v{}|{}|r{}|n{}|{}",
        PATH_CLASS_DETECTOR_VERSION,
        module_name,
        region_id,
        node_ids.len(),
        parts.join(",")
    )
}

/// Attribute path classes: cheap under-budget short-circuit + expensive bottleneck detectors.
///
/// `hints` (from cache) let matching signatures skip multi-detector search and re-apply
/// the known class/adjustment ratio or absolute adjusted FO4.
pub fn classify_and_adjust_paths(
    design: &mut TimingDesign,
    model: &CostModel,
    hints: Option<&BTreeMap<String, PathClassHint>>,
) {
    design.path_exceptions.clear();
    let budget = design.target.budget_fo4;
    let fo4_ps = design.target.fo4_ps;
    let margin = design.target.budget_margin;
    let mod_names: BTreeMap<u32, String> = design
        .modules
        .iter()
        .map(|(id, m)| (*id, m.name.clone()))
        .collect();

    // Collect exceptions then apply — need immutable module borrow for scan.
    let mut updates: Vec<(usize, PathException)> = Vec::new();

    for (idx, path) in design.paths.iter().enumerate() {
        let mod_name = mod_names.get(&path.module).cloned().unwrap_or_default();
        let module = design.modules.get(&path.module);
        let lhs_hist = lhs_histogram(module, &path.nodes);
        let sig = path_signature(&mod_name, path.region_id, &path.nodes, &lhs_hist);
        let raw = path.total_fo4;

        // --- cheap exits (simplify algorithms outside exceptions) ---
        if path.multi_cycle {
            // Soft atomic multi-cycle: keep AtomicOverBudget identity for reports.
            if let Some((adj, conf, ev)) =
                try_atomic_over_budget(module, &path.nodes, raw, budget, model)
            {
                updates.push((
                    idx,
                    PathException {
                        path_id: path.id,
                        module_name: mod_name,
                        path_class: PathClassKind::AtomicOverBudget,
                        raw_fo4: raw,
                        adjusted_fo4: adj,
                        confidence: conf,
                        evidence: format!("{ev}; soft multi_cycle screening (atomic > budget)"),
                        attempted: vec![PatternAttempt {
                            detector: "atomic_over_budget".into(),
                            matched: true,
                            candidate_fo4: Some(adj),
                            note: "already multi_cycle; retain atomic class".into(),
                        }],
                        signature: sig,
                    },
                ));
            } else {
                // Still run exclusive/dense so iterative FPU FSMs (control_mvp 714
                // nodes) report max-arm FO4 instead of the statement-order serial
                // sum. Class stays MultiCycleTagged — InsertReg stays off.
                let (adj, conf, ev, attempted) =
                    deflate_or_raw(module, &path.nodes, raw, budget, model);
                updates.push((
                    idx,
                    PathException {
                        path_id: path.id,
                        module_name: mod_name,
                        path_class: PathClassKind::MultiCycleTagged,
                        raw_fo4: raw,
                        adjusted_fo4: adj,
                        confidence: conf,
                        evidence: format!("multi_cycle tag; {ev}"),
                        attempted,
                        signature: sig,
                    },
                ));
            }
            continue;
        }
        if raw <= budget + 1e-9 {
            updates.push((
                idx,
                PathException {
                    path_id: path.id,
                    module_name: mod_name,
                    path_class: PathClassKind::UnderBudget,
                    raw_fo4: raw,
                    adjusted_fo4: raw,
                    confidence: 1.0,
                    evidence: format!("raw {raw:.1} ≤ budget {budget:.1} — cheap path"),
                    attempted: Vec::new(),
                    signature: sig,
                },
            ));
            continue;
        }

        // --- cache hint reuse (never freeze Plain: new detectors must re-scan) ---
        if let Some(h) = hints.and_then(|m| m.get(&sig)) {
            let reusable = !matches!(
                h.path_class,
                PathClassKind::Plain | PathClassKind::UnderBudget
            ) && (h.adjusted_fo4 + 1e-9 < raw
                || matches!(h.path_class, PathClassKind::AtomicOverBudget));
            if reusable
                && module
                    .is_some_and(|m| classification_scratch(m, &path.nodes, budget).procedural_ok)
            {
                // Scale if node FO4 changed proportionally; else use absolute if close.
                let adjusted = if matches!(h.path_class, PathClassKind::AtomicOverBudget) {
                    // Operator cost (or prior merged companion), not the
                    // statement-order serial sum of the enclosing always_comb.
                    h.adjusted_fo4.clamp(0.0, raw)
                } else if h.raw_fo4 > 1e-9 {
                    let ratio = h.adjusted_fo4 / h.raw_fo4;
                    (raw * ratio).clamp(0.0, raw)
                } else {
                    h.adjusted_fo4.min(raw)
                };
                updates.push((
                    idx,
                    PathException {
                        path_id: path.id,
                        module_name: mod_name,
                        path_class: h.path_class,
                        raw_fo4: raw,
                        adjusted_fo4: adjusted,
                        confidence: h.confidence * 0.95,
                        evidence: format!("cache-hint: {}", h.evidence),
                        attempted: vec![PatternAttempt {
                            detector: "cache_hint".into(),
                            matched: true,
                            candidate_fo4: Some(adjusted),
                            note: "reused path_class from cache".into(),
                        }],
                        signature: sig,
                    },
                ));
                continue;
            }
            // Plain / stale hints: fall through to expensive detectors.
        }

        // --- expensive detectors (high FO4 only) ---
        let (best, attempted) =
            scan_deflate_detectors(module, &path.nodes, raw, budget, model, true);

        if let Some((class, mut adj, conf, mut ev)) = best {
            if class != PathClassKind::AtomicOverBudget {
                if let Some((nid, cost, cls, peel)) =
                    p4_peel_amount(module, &path.nodes, budget, adj)
                {
                    adj = (adj - peel).max(0.0);
                    ev = format!(
                        "{ev}; P4 remainder − atomic {cls:?} node {nid} fo4≈{cost:.1} peel={peel:.1} is T3"
                    );
                }
            }
            updates.push((
                idx,
                PathException {
                    path_id: path.id,
                    module_name: mod_name,
                    path_class: class,
                    raw_fo4: raw,
                    adjusted_fo4: adj,
                    confidence: conf,
                    evidence: ev,
                    attempted,
                    signature: sig,
                },
            ));
        } else {
            // P4: keep the path cuttable, but do not let the T3 atomic node's
            // FO4 set the remainder cost (pe_dot 333 included a 130 DivRem).
            let (adj, evidence) = if let Some((nid, cost, cls, peel)) =
                p4_peel_amount(module, &path.nodes, budget, raw)
            {
                let rem = (raw - peel).max(0.0);
                (
                    rem,
                    format!(
                        "P4 remainder; atomic {cls:?} node {nid} fo4≈{cost:.1} peel={peel:.1} is T3, remainder {rem:.1} cuttable"
                    ),
                )
            } else if let Some((nid, cost, cls)) =
                hottest_over_budget_atomic(module, &path.nodes, budget)
            {
                (
                    raw,
                    format!(
                        "P4 remainder; atomic {cls:?} node {nid} fo4≈{cost:.1} is T3, remainder {raw:.1} cuttable"
                    ),
                )
            } else {
                (
                    raw,
                    "over-budget plain path — no exclusive/atomic exception".into(),
                )
            };
            updates.push((
                idx,
                PathException {
                    path_id: path.id,
                    module_name: mod_name,
                    path_class: PathClassKind::Plain,
                    raw_fo4: raw,
                    adjusted_fo4: adj,
                    confidence: 0.7,
                    evidence,
                    attempted,
                    signature: sig,
                },
            ));
        }
    }

    // Apply updates onto paths + design.path_exceptions
    for (idx, ex) in updates {
        if let Some(path) = design.paths.get_mut(idx) {
            if (ex.adjusted_fo4 - ex.raw_fo4).abs() > 1e-6 {
                path.total_fo4_raw = Some(ex.raw_fo4);
                path.total_fo4 = ex.adjusted_fo4;
            } else {
                path.total_fo4_raw = None;
                // keep total_fo4 as raw
            }
            path.path_class = ex.path_class;
            path.class_note = Some(ex.evidence.clone());
            // Soft multi-cycle: atomic mul/div cannot meet single-cycle FO4 budget;
            // exclude from primary closure ranking (screening only — not STA).
            if ex.path_class == PathClassKind::AtomicOverBudget && !path.multi_cycle {
                path.multi_cycle = true;
                path.class_note = Some(format!(
                    "{}; soft multi_cycle screening (atomic > budget)",
                    ex.evidence
                ));
            }
            path.slack_fo4 = budget - path.total_fo4;
            path.max_freq_mhz =
                crate::measure::max_freq_mhz_for_path(path.total_fo4, fo4_ps, margin);
        }
        design.path_exceptions.push(ex);
    }
}

fn pick_better(
    cur: Option<(PathClassKind, f64, f64, String)>,
    cand: (PathClassKind, f64, f64, String),
) -> Option<(PathClassKind, f64, f64, String)> {
    match cur {
        None => Some(cand),
        Some(c) => {
            // Atomic class must win (InsertReg cannot cut a mul/div) but the
            // adjusted FO4 is max(operator, companion exclusive/dense/bundle)
            // — not the statement-order serial sum of the enclosing FSM.
            // full_core g6lc_ai_exec was 545 FO4 raw on `default: state_d`
            // because 235 next-state assigns were summed around a 56 FO4 Mul.
            use PathClassKind::AtomicOverBudget;
            if cand.0 == AtomicOverBudget || c.0 == AtomicOverBudget {
                let (atom, other) = if cand.0 == AtomicOverBudget {
                    (cand, c)
                } else {
                    (c, cand)
                };
                let adj = atom.1.max(other.1);
                return Some((
                    AtomicOverBudget,
                    adj,
                    atom.2.max(other.2),
                    format!("{}; companion {}", atom.3, other.3),
                ));
            }
            // Prefer lower adjusted FO4; tie-break higher confidence.
            if cand.1 + 1e-9 < c.1 || ((cand.1 - c.1).abs() < 1e-9 && cand.2 > c.2) {
                Some(cand)
            } else {
                Some(c)
            }
        }
    }
}

fn lhs_histogram(
    module: Option<&crate::ir::TimingModule>,
    nodes: &[NodeId],
) -> BTreeMap<String, usize> {
    let mut h = BTreeMap::new();
    let Some(m) = module else {
        return h;
    };
    for id in nodes {
        if let Some(n) = m.nodes.get(id) {
            if let Some(ref lhs) = n.lhs {
                let key = lhs_base(lhs.trim());
                if !key.is_empty() {
                    *h.entry(key).or_insert(0) += 1;
                }
            }
        }
    }
    h
}

/// P4 remainder: subtract the T3 atomic when it should not set the path FO4.
///
/// Keep a short serial mul chain (`gemm_span` 56/68, leftover 12 < 56) so
/// InsertReg still sees the operator. Subtract when:
/// - it owns the cone (`hpdcache` 120/125), or
/// - another copy sits beside it (`hpdcache` 3-node 120+120+1), or
/// - the cone is wide (`nodes >= 8`, `pe_dot` / `policy_subcode`).
const P4_ATOMIC_DOMINANCE: f64 = 0.90;

fn p4_subtract_dominating_atomic(n_nodes: usize, adj: f64, cost: f64) -> bool {
    if n_nodes <= 1 || adj <= 1e-9 {
        return false;
    }
    let rem = (adj - cost).max(0.0);
    cost / adj >= P4_ATOMIC_DOMINANCE || rem + 1e-9 >= cost || n_nodes >= 8
}

/// FO4 to peel from a cuttable remainder: the hottest T3 node, plus every
/// other over-budget DivRem (hpdcache `way / Cfg` and `way % Cfg` as twins).
/// Real serial muls (`gemm_span`) do not qualify, so they are not peeled.
fn p4_peel_amount(
    module: Option<&crate::ir::TimingModule>,
    nodes: &[NodeId],
    budget: f64,
    adj: f64,
) -> Option<(NodeId, f64, OperatorClass, f64)> {
    let (nid, cost, cls) = hottest_over_budget_atomic(module, nodes, budget)?;
    if !p4_subtract_dominating_atomic(nodes.len(), adj, cost) {
        return None;
    }
    let mut peel = cost;
    if let Some(m) = module {
        for id in nodes {
            if *id == nid {
                continue;
            }
            let Some(n) = m.nodes.get(id) else {
                continue;
            };
            if n.op_class == Some(OperatorClass::DivRem) && n.fo4_cost > budget + 1e-9 {
                peel += n.fo4_cost;
            }
        }
    }
    Some((nid, cost, cls, peel))
}

fn hottest_over_budget_atomic(
    module: Option<&crate::ir::TimingModule>,
    nodes: &[NodeId],
    budget: f64,
) -> Option<(NodeId, f64, OperatorClass)> {
    let m = module?;
    let mut worst: Option<(NodeId, f64, OperatorClass)> = None;
    for id in nodes {
        let n = m.nodes.get(id)?;
        let cls = n.op_class?;
        if !matches!(cls, OperatorClass::Mul | OperatorClass::DivRem) {
            continue;
        }
        if n.fo4_cost > budget + 1e-9 && worst.map(|(_, c, _)| n.fo4_cost > c).unwrap_or(true) {
            worst = Some((*id, n.fo4_cost, cls));
        }
    }
    worst
}

fn try_atomic_over_budget(
    module: Option<&crate::ir::TimingModule>,
    nodes: &[NodeId],
    _raw: f64,
    budget: f64,
    model: &CostModel,
) -> Option<(f64, f64, String)> {
    let (nid, cost, cls) = hottest_over_budget_atomic(module, nodes, budget)?;
    // PASS-STRATEGY P4: atomicity is a node property. A 117-node path with one
    // over-budget operator is mostly ordinary logic — do not brand the whole
    // path atomic (that suppressed remainder cuts on cache_ctrl / wt_axi_adapter
    // in audit-strict-v4). Single-node cones stay AtomicOverBudget (P3/P8).
    if nodes.len() > 1 {
        return None;
    }
    // Adjusted FO4 is the operator, not the enclosing always_comb serial sum.
    // Class still discourages InsertReg; T3 stage count uses this cost.
    Some((
        cost,
        0.95,
        format!(
            "atomic {cls:?} node {nid} fo4≈{cost:.1} > budget {budget:.1} (model base mul={:.1})",
            model.mul
        ),
    ))
}

fn classification_scratch(
    module: &crate::ir::TimingModule,
    nodes: &[NodeId],
    budget: f64,
) -> ParallelScratch {
    let mut scratch = ParallelScratch::schedule(module, nodes, budget, &BTreeMap::new());
    if scratch.procedural_ok && scratch.dep_edges > 0 {
        let sequential_nodes: std::collections::BTreeSet<_> = module
            .regions
            .values()
            .filter(|region| region.kind == crate::ir::RegionKind::AlwaysFf)
            .flat_map(|region| region.nodes.iter().copied())
            .collect();
        if !sequential_nodes.is_empty() {
            let tree = RefOrderTree::from_nodes(module, nodes);
            if tree
                .edges
                .iter()
                .any(|edge| sequential_nodes.contains(&nodes[edge.from_stmt as usize]))
            {
                scratch.procedural_ok = false;
            }
        }
    }
    scratch
}

/// Many distinct LHS in one always_comb: IR chains them in source order, but
/// silicon evaluates independent assigns in parallel. Cost ≈ max(per-LHS FO4)
/// + small bundle/wiring overhead.
///
/// Per-LHS cost: max write FO4; if a field is written ≥3 times, add log-mux
/// select (case/if overwrite). Paths with **one** LHS holding ≥50% of writes
/// are left to [`try_exclusive_shared_lhs`] (pure result mux).
fn try_independent_lhs_bundle(
    module: Option<&crate::ir::TimingModule>,
    nodes: &[NodeId],
    raw: f64,
    budget: f64,
    model: &CostModel,
) -> Option<(f64, f64, String)> {
    let m = module?;
    if nodes.len() < 6 {
        return None;
    }
    let mut by_lhs_cost: BTreeMap<String, f64> = BTreeMap::new();
    let mut by_lhs_writes: BTreeMap<String, usize> = BTreeMap::new();
    let mut no_lhs = 0.0_f64;
    let mut with_lhs = 0usize;
    for id in nodes {
        let Some(n) = m.nodes.get(id) else {
            continue;
        };
        match n.lhs.as_ref().map(|s| lhs_base(s.trim())) {
            Some(lhs) if !lhs.is_empty() => {
                let e = by_lhs_cost.entry(lhs.clone()).or_insert(0.0);
                *e = e.max(n.fo4_cost.max(0.0));
                *by_lhs_writes.entry(lhs).or_insert(0) += 1;
                with_lhs += 1;
            }
            _ => no_lhs += n.fo4_cost.max(0.0),
        }
    }
    let n_lhs = by_lhs_cost.len();
    if n_lhs < 4 {
        return None;
    }
    // Pure exclusive result-mux: one LHS owns most writes → exclusive detector.
    let max_writes = by_lhs_writes.values().copied().max().unwrap_or(0);
    if max_writes >= 3 && (max_writes as f64) >= (with_lhs as f64) * 0.5 {
        return None;
    }
    if (with_lhs as f64) < (nodes.len() as f64) * 0.5 {
        return None;
    }
    let tree = RefOrderTree::from_nodes(m, nodes);
    let next_state = is_sequential_next_state_bundle(&by_lhs_cost, Some(&tree));
    // Per-field cost. Next-state `_d` overwrites are exclusive flop-D arms,
    // not a log2 mux stacked on max_field (prefetcher pf_addr_d 10+log2(7)*2.5=17).
    let mut field_costs: Vec<f64> = Vec::new();
    for (lhs, &base) in &by_lhs_cost {
        let w = *by_lhs_writes.get(lhs).unwrap_or(&1) as f64;
        let c = if !next_state && w >= 3.0 {
            base + model.mux * w.log2().max(1.0)
        } else {
            base
        };
        field_costs.push(c);
    }
    let max_field = field_costs.iter().copied().fold(0.0_f64, f64::max);
    let sum_fields: f64 = field_costs.iter().sum();
    if max_field >= raw * 0.55 {
        return None;
    }
    // Timing basis: independent writes share a time slot (ASAP max), so the
    // scratchboard makespan replaces max_field when the ref-tree is parallel.
    // Independent flop D pins do not share a wire tree.
    let scratch = classification_scratch(m, nodes, budget);
    if !scratch.procedural_ok {
        return None;
    }
    let wire = if next_state {
        0.0
    } else {
        model.other * (n_lhs as f64).log2().max(1.0) * 2.0
    };
    // Next-state `_d` fields are independent flop D pins. Makespan through
    // shared temps / ident_base-collapsed struct writes is not the capture
    // delay (coherence_hub 67-node 30 FO4 makespan vs max_field 10).
    let core = if next_state {
        max_field
    } else {
        scratch.makespan_fo4.max(max_field)
    };
    let adjusted = core + wire + no_lhs.min(raw * 0.15) * 0.5;
    let adjusted = adjusted.clamp(0.0, raw);
    if adjusted >= raw * 0.85 {
        return None;
    }
    let conf = (0.5 + 0.04 * (n_lhs as f64).min(10.0)).min(0.88);
    let wo = tree.write_only_lhs(by_lhs_cost.keys());
    Some((
        adjusted,
        conf,
        format!(
            "independent-LHS bundle lhs={n_lhs} writes={with_lhs} max_writes={max_writes} max_field={max_field:.1} sum_fields={sum_fields:.1} makespan={:.1} cycles={} wire={wire:.1} next_state={next_state} write_only={wo} depth={} calls={} procedural_ok={} raw={raw:.1}→{adjusted:.1}",
            scratch.makespan_fo4,
            scratch.cycle_count,
            tree.procedural_depth(),
            tree.calls.len(),
            tree.procedural_ok
        ),
    ))
}

/// Plain comb whose statement-order sum is a ghost: ASAP makespan on the
/// ref-tree is the delay. Timing basis: M = max_s C(s), C(s)=S(s)+L(s),
/// S(s)=max producer completions (0 if independent).
fn try_parallel_timing(
    module: Option<&crate::ir::TimingModule>,
    nodes: &[NodeId],
    raw: f64,
    budget: f64,
) -> Option<(f64, f64, String)> {
    let m = module?;
    if nodes.len() < 4 {
        return None;
    }
    let scratch = classification_scratch(m, nodes, budget);
    if !scratch.procedural_ok {
        return None;
    }
    let adj = scratch.makespan_fo4;
    if adj < 1e-9 || adj >= raw * 0.85 {
        return None;
    }
    let n_lhs = {
        let mut s = BTreeMap::new();
        for id in nodes {
            if let Some(n) = m.nodes.get(id) {
                if let Some(ref l) = n.lhs {
                    let b = ident_base(l);
                    if !b.is_empty() {
                        *s.entry(b).or_insert(0u32) += 1;
                    }
                }
            }
        }
        s.len()
    };
    let conf = 0.7;
    Some((
        adj,
        conf,
        format!(
            "parallel-timing makespan={adj:.1} cycles={} deps={} lhs={n_lhs} vars_ready={} fns={} raw={raw:.1}→{adj:.1}",
            scratch.cycle_count,
            scratch.dep_edges,
            scratch.var_ready_fo4.len(),
            scratch.functions.len()
        ),
    ))
}

/// True when the exclusive LHS is a flop D/Q capture (`foo_d`, `aw_wait_q`).
///
/// `_q` is *not* in [`lhs_is_next_state`]: tagging gemm always_ff `_q` NBAs as
/// a next-state bundle would skip IndependentLhsBundle-skip-on-compose and
/// starve S4 InsertReg. Exclusive of a single `_q` result is still a flop D.
fn lhs_is_flop_capture(lhs: &str) -> bool {
    lhs_is_next_state(lhs) || {
        let ident = lhs
            .split('[')
            .next()
            .unwrap_or(lhs)
            .trim()
            .rsplit('.')
            .next()
            .unwrap_or(lhs);
        ident.ends_with("_q")
    }
}

/// True when an assignment LHS is sequential next-state (`foo_d`, `bar_n[3:0]`).
fn lhs_is_next_state(lhs: &str) -> bool {
    let ident = lhs
        .split('[')
        .next()
        .unwrap_or(lhs)
        .trim()
        .trim_end_matches(|c: char| c == ' ' || c == '\t');
    let ident = ident.rsplit('.').next().unwrap_or(ident);
    ident.ends_with("_d")
        || ident.ends_with("_n")
        || ident.ends_with("_ns")
        || ident.ends_with("_nxt")
        || ident.ends_with("_next")
}

fn sequential_next_state_frac(by_lhs: &BTreeMap<String, f64>) -> f64 {
    if by_lhs.is_empty() {
        return 0.0;
    }
    let n = by_lhs.len() as f64;
    let ns = by_lhs.keys().filter(|k| lhs_is_next_state(k)).count() as f64;
    ns / n
}

/// Combo FSM with a handful of `_d` flops plus many 1-bit ports (`axi_req_o.*`).
/// Frac 0.6 missed axi_adapter (8 next-state vs 50 LHS). Four `_d` fields is enough.
/// The reference-ordering tree treats write-only vars (no forward read) as parallel.
fn is_sequential_next_state_bundle(
    by_lhs: &BTreeMap<String, f64>,
    tree: Option<&RefOrderTree>,
) -> bool {
    let ns = by_lhs.keys().filter(|k| lhs_is_next_state(k)).count();
    let wo = tree.map(|t| t.write_only_lhs(by_lhs.keys())).unwrap_or(0);
    let parallel = tree
        .map(|t| t.procedural_depth() == 0 && by_lhs.len() >= 4)
        .unwrap_or(false);
    ns >= 4 || wo >= 4 || sequential_next_state_frac(by_lhs) >= 0.6 || parallel
}

/// Strip bit/part selects so `rdata[31:0]` groups with `rdata` (clint MMIO mux).
fn lhs_base(lhs: &str) -> String {
    ident_base(lhs)
}

/// True when path nodes come from two or more regions (P5 compose).
fn path_spans_multiple_regions(module: Option<&crate::ir::TimingModule>, nodes: &[NodeId]) -> bool {
    let Some(m) = module else {
        return false;
    };
    if nodes.len() < 2 || m.regions.len() < 2 {
        return false;
    }
    let mut regs = std::collections::BTreeSet::new();
    for (&rid, region) in &m.regions {
        if nodes.iter().any(|id| region.nodes.contains(id)) {
            regs.insert(rid);
            if regs.len() >= 2 {
                return true;
            }
        }
    }
    false
}

/// True when a composed path is a next-state / write-only FSM, not a serial
/// named-temp datapath. IndependentLhsBundle is the right deflation there.
fn composed_is_next_state_fsm(module: Option<&crate::ir::TimingModule>, nodes: &[NodeId]) -> bool {
    let Some(m) = module else {
        return false;
    };
    let mut by_lhs: BTreeMap<String, f64> = BTreeMap::new();
    for id in nodes {
        let Some(n) = m.nodes.get(id) else {
            continue;
        };
        if let Some(lhs) = n.lhs.as_ref().map(|s| lhs_base(s.trim())) {
            if !lhs.is_empty() {
                let e = by_lhs.entry(lhs).or_insert(0.0);
                *e = e.max(n.fo4_cost.max(0.0));
            }
        }
    }
    if by_lhs.len() < 4 {
        return false;
    }
    let tree = RefOrderTree::from_nodes(m, nodes);
    is_sequential_next_state_bundle(&by_lhs, Some(&tree))
}

fn deflate_or_raw(
    module: Option<&crate::ir::TimingModule>,
    nodes: &[NodeId],
    raw: f64,
    budget: f64,
    model: &CostModel,
) -> (f64, f64, String, Vec<PatternAttempt>) {
    let (best, attempted) = scan_deflate_detectors(module, nodes, raw, budget, model, false);
    match best {
        Some((_, adj, conf, ev)) => (adj, conf, ev, attempted),
        None => (raw, 1.0, "no exclusive/dense deflation".into(), attempted),
    }
}

fn scan_deflate_detectors(
    module: Option<&crate::ir::TimingModule>,
    nodes: &[NodeId],
    raw: f64,
    budget: f64,
    model: &CostModel,
    include_atomic: bool,
) -> (
    Option<(PathClassKind, f64, f64, String)>,
    Vec<PatternAttempt>,
) {
    let mut attempted = Vec::new();
    let mut best: Option<(PathClassKind, f64, f64, String)> = None;
    // P5 compose wires assign/comb fragments. Independent-LHS bundle on that
    // blob treated gemm as parallel fields and refused InsertReg. Exclusive
    // case / dense / parallel-timing still apply (csr_regfile 370, decoder 428).
    let composed = path_spans_multiple_regions(module, nodes);
    if composed {
        attempted.push(PatternAttempt {
            detector: "p5_composed_cone".into(),
            matched: true,
            candidate_fo4: None,
            note: "P5 composed cone — exclusive/dense/parallel-timing; IndependentLhsBundle only if next-state FSM".into(),
        });
    }

    if include_atomic {
        if let Some((adj, conf, ev)) = try_atomic_over_budget(module, nodes, raw, budget, model) {
            attempted.push(PatternAttempt {
                detector: "atomic_over_budget".into(),
                matched: true,
                candidate_fo4: Some(adj),
                note: ev.clone(),
            });
            best = Some((PathClassKind::AtomicOverBudget, adj, conf, ev));
        } else {
            attempted.push(PatternAttempt {
                detector: "atomic_over_budget".into(),
                matched: false,
                candidate_fo4: None,
                note: "no Mul/DivRem node alone over budget".into(),
            });
        }
    }

    if let Some((adj, conf, ev)) =
        try_exclusive_shared_lhs(module, nodes, raw, model, /*priority=*/ false)
    {
        attempted.push(PatternAttempt {
            detector: "exclusive_case_mux".into(),
            matched: true,
            candidate_fo4: Some(adj),
            note: ev.clone(),
        });
        best = pick_better(best, (PathClassKind::ExclusiveCaseMux, adj, conf, ev));
    } else {
        attempted.push(PatternAttempt {
            detector: "exclusive_case_mux".into(),
            matched: false,
            candidate_fo4: None,
            note: "no dominant shared-LHS arm sum".into(),
        });
    }

    if let Some((adj, conf, ev)) =
        try_exclusive_shared_lhs(module, nodes, raw, model, /*priority=*/ true)
    {
        attempted.push(PatternAttempt {
            detector: "exclusive_if_chain".into(),
            matched: true,
            candidate_fo4: Some(adj),
            note: ev.clone(),
        });
        best = pick_better(best, (PathClassKind::ExclusiveIfChain, adj, conf, ev));
    } else {
        attempted.push(PatternAttempt {
            detector: "exclusive_if_chain".into(),
            matched: false,
            candidate_fo4: None,
            note: "no if-chain exclusive pattern".into(),
        });
    }

    // Skip IndependentLhsBundle on composed *serial datapath* (gemm named
    // temps) so InsertReg still sees Plain. Next-state FSMs composed across
    // assign/comb fragments (coherence_hub) must still bundle: sibling `_d`
    // fields are parallel flop D pins, not a gemm mul chain.
    let skip_bundle = composed && !composed_is_next_state_fsm(module, nodes);
    if skip_bundle {
        attempted.push(PatternAttempt {
            detector: "independent_lhs_bundle".into(),
            matched: false,
            candidate_fo4: None,
            note: "skipped on P5 composed cone (gemm serial chain)".into(),
        });
    } else if let Some((adj, conf, ev)) =
        try_independent_lhs_bundle(module, nodes, raw, budget, model)
    {
        attempted.push(PatternAttempt {
            detector: "independent_lhs_bundle".into(),
            matched: true,
            candidate_fo4: Some(adj),
            note: ev.clone(),
        });
        best = pick_better(best, (PathClassKind::IndependentLhsBundle, adj, conf, ev));
    } else {
        attempted.push(PatternAttempt {
            detector: "independent_lhs_bundle".into(),
            matched: false,
            candidate_fo4: None,
            note: "not a multi-LHS statement-order bundle".into(),
        });
    }

    if let Some((adj, conf, ev)) = try_dense_control_cone(module, nodes, raw, budget, model) {
        attempted.push(PatternAttempt {
            detector: "dense_control_cone".into(),
            matched: true,
            candidate_fo4: Some(adj),
            note: ev.clone(),
        });
        best = pick_better(best, (PathClassKind::DenseControlCone, adj, conf, ev));
    } else {
        attempted.push(PatternAttempt {
            detector: "dense_control_cone".into(),
            matched: false,
            candidate_fo4: None,
            note: "not a dense small-op control cone".into(),
        });
    }

    // Parallel-timing scratchboard: statement-order *sum* is not silicon delay.
    // ASAP on the ref-tree is the FO4 we trust for *plain* comb that exclusive /
    // bundle / dense did not claim. Exclusive arms are not all live — never steal.
    if best.is_none() {
        if let Some((adj, conf, ev)) = try_parallel_timing(module, nodes, raw, budget) {
            attempted.push(PatternAttempt {
                detector: "parallel_timing".into(),
                matched: true,
                candidate_fo4: Some(adj),
                note: ev.clone(),
            });
            // Composed cones keep Plain so InsertReg still sees CombDatapath
            // (IndependentLhsBundle is ExclusiveMux lane). Serial gemm makespan
            // ≈ raw and does not match; parallel CSR/decoder still deflate.
            let class = if composed {
                PathClassKind::Plain
            } else if ev.contains("lhs=") {
                PathClassKind::IndependentLhsBundle
            } else {
                PathClassKind::DenseControlCone
            };
            best = Some((class, adj, conf, ev));
        } else {
            attempted.push(PatternAttempt {
                detector: "parallel_timing".into(),
                matched: false,
                candidate_fo4: None,
                note: "makespan not below serial sum".into(),
            });
        }
    }

    (best, attempted)
}

/// Dense always_comb / FSM: many modest nodes chained by IR statement order.
/// Real critical path ≈ max op + control mux depth, not sum of all statements.
///
/// Pure shared-LHS exclusive result muxes are **not** handled here — they belong
/// to [`try_exclusive_shared_lhs`] (max-arm + log select, not node-count wire tax).
fn try_dense_control_cone(
    module: Option<&crate::ir::TimingModule>,
    nodes: &[NodeId],
    raw: f64,
    budget: f64,
    model: &CostModel,
) -> Option<(f64, f64, String)> {
    let m = module?;
    let n = nodes.len();
    if n < 16 {
        return None;
    }
    let mut costs: Vec<f64> = Vec::new();
    let mut with_lhs = 0usize;
    let mut by_lhs_cost: BTreeMap<String, f64> = BTreeMap::new();
    let mut by_lhs_writes: BTreeMap<String, usize> = BTreeMap::new();
    for id in nodes {
        let Some(nd) = m.nodes.get(id) else {
            continue;
        };
        let c = nd.fo4_cost.max(0.0);
        costs.push(c);
        if let Some(lhs) = nd.lhs.as_ref().map(|s| lhs_base(s.trim())) {
            if !lhs.is_empty() {
                with_lhs += 1;
                *by_lhs_writes.entry(lhs.clone()).or_insert(0) += 1;
                *by_lhs_cost.entry(lhs).or_insert(0.0) += c;
            }
        }
    }
    if costs.len() < 16 {
        return None;
    }
    // Hand off to exclusive only when it would actually match: ≥3 arms on one
    // LHS **and** those arms dominate raw FO4 (sparse FSM LHS stays dense).
    if let Some((dom_lhs, &writes)) = by_lhs_writes.iter().max_by_key(|(_, w)| *w) {
        let arm_sum = by_lhs_cost.get(dom_lhs).copied().unwrap_or(0.0);
        if writes >= 3 && arm_sum >= raw * 0.45 {
            return None;
        }
    }
    let max_n = costs.iter().copied().fold(0.0_f64, f64::max);
    // Single heavy op path — not this pattern
    if max_n >= raw * 0.45 {
        return None;
    }
    // Hand off to atomic / multi_cycle when the worst node is Mul/DivRem over
    // a typical single-cycle budget (~16–32 FO4). Dense must not deflate those.
    for id in nodes {
        if let Some(nd) = m.nodes.get(id) {
            if matches!(
                nd.op_class,
                Some(OperatorClass::Mul) | Some(OperatorClass::DivRem)
            ) && nd.fo4_cost >= 40.0
            {
                return None;
            }
        }
    }
    let avg = raw / (costs.len() as f64);
    // Average node should be modest (control compares / assigns), not wide ALU mul
    if avg > 12.0 {
        return None;
    }
    // Prefer cases where LHS recovery is sparse (binary-op heavy FSM extract)
    // or mixed — but independent_lhs already handled rich multi-LHS.
    let n_f = costs.len() as f64;
    let tree = RefOrderTree::from_nodes(m, nodes);
    let next_state = is_sequential_next_state_bundle(&by_lhs_cost, Some(&tree));
    // Timing basis: dense FSM delay is ASAP makespan (parallel next-state) plus
    // a small select/wire tax — not the serial sum of every statement.
    let scratch = classification_scratch(m, nodes, budget);
    if !scratch.procedural_ok {
        return None;
    }
    let select = if next_state {
        0.0
    } else {
        model.mux * n_f.log2().max(2.0)
    };
    let wire = if next_state {
        0.0
    } else {
        model.other * n_f.log2().max(1.0)
    };
    let core = if next_state {
        max_n
    } else {
        scratch.makespan_fo4.max(max_n)
    };
    let adjusted = core + select + wire;
    let adjusted = adjusted.clamp(0.0, raw);
    if adjusted >= raw * 0.88 {
        return None;
    }
    let conf = (0.52 + 0.02 * (n_f / 10.0).min(4.0)).min(0.85);
    Some((
        adjusted,
        conf,
        format!(
            "dense control cone nodes={} with_lhs={with_lhs} max_node={max_n:.1} avg={avg:.1} makespan={:.1} cycles={} select={select:.1} wire={wire:.1} next_state={next_state} raw={raw:.1}→{adjusted:.1}",
            costs.len(),
            scratch.makespan_fo4,
            scratch.cycle_count
        ),
    ))
}

/// Shared-LHS exclusive arms: cost ≈ max(arm) + mux_tree + residual non-arm FO4.
fn try_exclusive_shared_lhs(
    module: Option<&crate::ir::TimingModule>,
    nodes: &[NodeId],
    raw: f64,
    model: &CostModel,
    priority: bool,
) -> Option<(f64, f64, String)> {
    let m = module?;
    // 2-node flop-D leftovers (l2_mshr waiter shift + nwait on `mem_d`) were
    // Plain-sum 20 because the old floor was 4 nodes / 3 arms.
    if nodes.len() < 2 {
        return None;
    }
    // Group FO4 by LHS
    let mut by_lhs: BTreeMap<String, Vec<f64>> = BTreeMap::new();
    let mut uncategorized = 0.0_f64;
    for id in nodes {
        let Some(n) = m.nodes.get(id) else {
            continue;
        };
        match n.lhs.as_ref().map(|s| lhs_base(s.trim())) {
            Some(lhs) if !lhs.is_empty() => {
                by_lhs.entry(lhs).or_default().push(n.fo4_cost.max(0.0));
            }
            _ => uncategorized += n.fo4_cost.max(0.0),
        }
    }
    let (lhs, arms) = by_lhs
        .iter()
        .max_by_key(|(_, v)| v.len())
        .map(|(k, v)| (k.clone(), v.clone()))?;
    let flop_capture = lhs_is_flop_capture(&lhs);
    if arms.len() < 3 && !(flop_capture && arms.len() >= 2) {
        return None;
    }
    let arm_sum: f64 = arms.iter().sum();
    if arm_sum < raw * 0.45 {
        return None; // not dominant
    }
    let max_arm = arms.iter().copied().fold(0.0_f64, f64::max);
    let n = arms.len() as f64;
    // Flop D / Q capture (`_d` / `_q`): the unique-case *is* the D pin mux.
    // Charging max_arm + mux + leftover put dram_timing `aw_wait_q` at 15.6
    // and dm_mem `rdata_d` at 12.5 with max_arm already at budget 10.
    let mux = if flop_capture {
        0.0
    } else if priority {
        model.priority_mux_per_level * n
    } else {
        // Unique-case is one-hot AND-OR of the selected arm, not a log2(n)
        // 2:1 tree stacked on max_arm. `log2(7)*2.5 ≈ 7` left timer / l2_mshr
        // exclusive residuals at 18 FO4 with max_arm already at budget 10.
        model.mux
    };
    // Non-dominant LHS (temps like rolw/bit_indx) feed *some* exclusive arms in
    // parallel with other arms — not a serial residual of (raw − Σ arm FO4).
    let mut other_field_max = 0.0_f64;
    for (k, costs) in &by_lhs {
        if k == &lhs {
            continue;
        }
        let m = costs.iter().copied().fold(0.0_f64, f64::max);
        other_field_max = other_field_max.max(m);
    }
    let dominance = if raw > 1e-9 {
        (arm_sum / raw).clamp(0.0, 1.0)
    } else {
        0.0
    };
    // Sibling exclusive fields are parallel flop D pins, not concat onto result.
    let prep_arm = if flop_capture {
        other_field_max
    } else if other_field_max > 0.0 {
        other_field_max + model.concat
    } else {
        0.0
    };
    let critical_arm = max_arm.max(prep_arm);
    let uncat = if flop_capture {
        0.0
    } else {
        uncategorized.min(raw * 0.08) * 0.15
    };
    // Prep is already max'd with the hot arm. A (raw − Σ arm) leftover is a
    // serial ghost (dram_timing leftover 2.6 on dominance 0.48).
    let leftover = 0.0;
    let adjusted = critical_arm + mux + uncat + leftover;
    let adjusted = adjusted.clamp(0.0, raw);
    if adjusted >= raw * 0.92 {
        return None; // no meaningful reduction
    }
    let conf = (0.55 + 0.08 * n.min(6.0)).min(0.92);
    let kind = if priority {
        "priority-if exclusive"
    } else {
        "unique-case exclusive"
    };
    Some((
        adjusted,
        conf,
        format!(
            "{kind} lhs=`{lhs}` arms={} max_arm={max_arm:.1} crit={critical_arm:.1} mux={mux:.1} prep_arm={prep_arm:.1} leftover={leftover:.1} dom={dominance:.2} raw={raw:.1}→{adjusted:.1}",
            arms.len()
        ),
    ))
}

/// Summary counts for cache / dashboard.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PathClassSummary {
    /// Counts by class name.
    pub counts: BTreeMap<String, u32>,
    /// Exceptions that adjusted FO4.
    pub adjusted_paths: u32,
    /// Max raw FO4 seen.
    pub max_raw_fo4: f64,
    /// Max adjusted FO4 seen.
    pub max_adjusted_fo4: f64,
}

/// Build summary from design exceptions (after classify).
pub fn path_class_summary(design: &TimingDesign) -> PathClassSummary {
    let mut s = PathClassSummary::default();
    for ex in &design.path_exceptions {
        let key = format!("{:?}", ex.path_class);
        *s.counts.entry(key).or_insert(0) += 1;
        if (ex.adjusted_fo4 - ex.raw_fo4).abs() > 1e-6 {
            s.adjusted_paths += 1;
        }
        s.max_raw_fo4 = s.max_raw_fo4.max(ex.raw_fo4);
        s.max_adjusted_fo4 = s.max_adjusted_fo4.max(ex.adjusted_fo4);
    }
    // Also count paths without exception row (shouldn't happen post-classify)
    if design.path_exceptions.is_empty() {
        for p in &design.paths {
            let key = format!("{:?}", p.path_class);
            *s.counts.entry(key).or_insert(0) += 1;
            s.max_raw_fo4 = s.max_raw_fo4.max(p.total_fo4_raw.unwrap_or(p.total_fo4));
            s.max_adjusted_fo4 = s.max_adjusted_fo4.max(p.total_fo4);
        }
    }
    s
}

/// Hints map from design exceptions (for re-analyze / next run).
pub fn hints_from_exceptions(exceptions: &[PathException]) -> BTreeMap<String, PathClassHint> {
    let mut m = BTreeMap::new();
    for ex in exceptions {
        if ex.signature.is_empty() {
            continue;
        }
        m.insert(
            ex.signature.clone(),
            PathClassHint {
                signature: ex.signature.clone(),
                path_class: ex.path_class,
                raw_fo4: ex.raw_fo4,
                adjusted_fo4: ex.adjusted_fo4,
                confidence: ex.confidence,
                evidence: ex.evidence.clone(),
            },
        );
    }
    m
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ir::{IrNode, PathEndpoint, PathKind, TimingModule, TimingPath, TimingTarget};
    use crate::loc::{OriginKind, SourceLoc};
    use std::collections::BTreeMap as Map;

    fn loc() -> SourceLoc {
        SourceLoc {
            file: "t.sv".into(),
            start_line: 1,
            start_col: 1,
            end_line: 1,
            end_col: 2,
            byte_start: 0,
            byte_end: 1,
            origin: OriginKind::UserFile,
        }
    }

    fn make_exclusive_design() -> TimingDesign {
        let mut design = TimingDesign::empty(TimingTarget::new(1250.0, 20.0, 0.2));
        // budget ≈ 32
        let mut nodes = Map::new();
        // 8 exclusive arms writing result_o, each ~40 FO4 → raw sum 320
        for i in 0..8u32 {
            nodes.insert(
                i,
                IrNode {
                    id: i,
                    op_class: Some(OperatorClass::AddSub),
                    width: 64,
                    fo4_cost: 40.0,
                    gate: None,
                    loc: loc(),
                    fans_in: if i == 0 { vec![] } else { vec![i - 1] },
                    fans_out: vec![],
                    width_defaulted: true,
                    reads_reg: false,
                    lhs: Some("result_o".into()),
                    rhs: Some(format!("arm_{i}")),
                    lhs_expr: None,
                    rhs_expr: None,
                    case_labels: Vec::new(),
                    case_is_default: false,
                    case_selector: None,
                    fo4_locked: false,
                    assign_kind: Default::default(),
                },
            );
        }
        design.modules.insert(
            0,
            TimingModule {
                id: 0,
                name: "alu".into(),
                file: "alu.sv".into(),
                nodes,
                regions: Map::new(),
                localparams: vec![],
                parameters: vec![],
                ports: vec![],
                gen_loops: vec![],
                functions: vec![],
                function_bodies: Vec::new(),
                package_imports: vec![],
                instances: vec![],
                decls: Vec::new(),
                config_branch: false,
                loc: loc(),
            },
        );
        design.module_names.insert("alu".into(), 0);
        let start = PathEndpoint::InputPort { module: 0, port: 0 };
        let end = PathEndpoint::OutputPort { module: 0, port: 1 };
        design.paths.push(TimingPath {
            id: 41,
            region_id: 0,
            module: 0,
            start: start.clone(),
            end: end.clone(),
            path_kind: PathKind::from_endpoints(&start, &end),
            startpoint: start.report_name("alu"),
            endpoint: end.report_name("alu"),
            nodes: (0..8).collect(),
            total_fo4: 320.0,
            slack_fo4: -288.0,
            max_freq_mhz: 100.0,
            primary_loc: loc(),
            multi_cycle: false,
            path_class: PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: None,
        });
        design
    }

    fn make_scratch_design(is_comb: bool) -> TimingDesign {
        let mut design = make_exclusive_design();
        design.target = TimingTarget::new(4000.0, 20.0, 0.2);
        let module = design.modules.get_mut(&0).unwrap();
        let template = module.nodes[&0].clone();
        module.nodes.clear();
        for id in 0..20 {
            let mut node = template.clone();
            node.id = id;
            node.fo4_cost = 4.0;
            node.lhs = Some(format!("value_{id}"));
            node.rhs = Some(if id == 1 {
                "value_0 + b".into()
            } else {
                format!("input_{id} + a")
            });
            node.gate = Some(crate::ir::GateInfo {
                is_comb,
                ..crate::ir::GateInfo::default()
            });
            node.fans_in.clear();
            module.nodes.insert(id, node);
        }
        design.paths[0].nodes = (0..20).collect();
        design.paths[0].total_fo4 = 80.0;
        design.paths[0].slack_fo4 = -70.0;
        design
    }

    #[test]
    fn independent_bundle_requires_verified_scratch() {
        for is_comb in [false, true] {
            let design = make_scratch_design(is_comb);
            let result = try_independent_lhs_bundle(
                design.modules.get(&0),
                &design.paths[0].nodes,
                80.0,
                10.0,
                &CostModel::default(),
            );
            assert_eq!(result.is_some(), is_comb, "{result:?}");
        }
    }

    #[test]
    fn dense_control_requires_verified_scratch() {
        for is_comb in [false, true] {
            let design = make_scratch_design(is_comb);
            let result = try_dense_control_cone(
                design.modules.get(&0),
                &design.paths[0].nodes,
                80.0,
                10.0,
                &CostModel::default(),
            );
            assert_eq!(result.is_some(), is_comb, "{result:?}");
        }
    }

    #[test]
    fn unverified_scratch_cannot_reuse_cached_deflation() {
        let mut design = make_scratch_design(true);
        let model = CostModel::default();
        classify_and_adjust_paths(&mut design, &model, None);
        assert!(design.paths[0].total_fo4 < 80.0);
        let hints = hints_from_exceptions(&design.path_exceptions);
        design
            .modules
            .get_mut(&0)
            .unwrap()
            .nodes
            .get_mut(&0)
            .unwrap()
            .gate
            .as_mut()
            .unwrap()
            .is_comb = false;
        design.paths[0].total_fo4 = 80.0;
        design.paths[0].total_fo4_raw = None;
        design.paths[0].path_class = PathClassKind::Plain;
        classify_and_adjust_paths(&mut design, &model, Some(&hints));
        assert_eq!(design.paths[0].total_fo4, 80.0);
        assert_eq!(design.paths[0].slack_fo4, -70.0);
        assert_eq!(design.paths[0].path_class, PathClassKind::Plain);
    }

    #[test]
    fn sequential_region_refusal_survives_missing_per_node_gates() {
        for cached in [false, true] {
            let mut design = make_scratch_design(true);
            let model = CostModel::default();
            classify_and_adjust_paths(&mut design, &model, None);
            let hints = hints_from_exceptions(&design.path_exceptions);
            let module = design.modules.get_mut(&0).unwrap();
            for node in module.nodes.values_mut() {
                node.gate = None;
            }
            module.regions.insert(
                0,
                crate::ir::CombRegion {
                    id: 0,
                    module: 0,
                    kind: crate::ir::RegionKind::AlwaysFf,
                    label: None,
                    gate: crate::ir::GateInfo {
                        is_comb: false,
                        ..crate::ir::GateInfo::default()
                    },
                    nodes: (0..20).collect(),
                    total_fo4: 80.0,
                    loc_span: loc(),
                    multi_cycle: false,
                },
            );
            let scratch = ParallelScratch::schedule_for_region(
                module,
                &module.regions[&0],
                &design.target,
                &BTreeMap::new(),
            );
            assert!(!scratch.procedural_ok);
            design.paths[0].total_fo4 = 80.0;
            design.paths[0].total_fo4_raw = None;
            design.paths[0].path_class = PathClassKind::Plain;
            classify_and_adjust_paths(&mut design, &model, cached.then_some(&hints));
            assert_eq!(design.paths[0].total_fo4, 80.0);
            assert_eq!(design.paths[0].path_class, PathClassKind::Plain);
        }
    }

    #[test]
    fn exclusive_case_reduces_sum_of_arms() {
        let mut d = make_exclusive_design();
        let model = CostModel::default();
        classify_and_adjust_paths(&mut d, &model, None);
        let p = &d.paths[0];
        assert!(
            p.total_fo4 < 100.0,
            "exclusive adjust should crush 320 FO4 sum, got {}",
            p.total_fo4
        );
        assert_eq!(p.path_class, PathClassKind::ExclusiveCaseMux);
        assert!(p.total_fo4_raw.unwrap_or(0.0) > 300.0);
        assert!(!d.path_exceptions.is_empty());
        assert!(d.path_exceptions[0].attempted.len() >= 2);
    }

    #[test]
    fn exclusive_parallel_prep_lhs_not_serial_residual() {
        // ALU-shaped: many result_o arms + a few prep temps (rolw/bit_indx).
        // Prep must not re-inflate via (raw − arm_sum)*0.25.
        let mut design = TimingDesign::empty(TimingTarget::new(1250.0, 20.0, 0.2));
        let mut nodes = Map::new();
        for i in 0..16u32 {
            nodes.insert(
                i,
                IrNode {
                    id: i,
                    op_class: Some(OperatorClass::AddSub),
                    width: 64,
                    fo4_cost: 20.0,
                    gate: None,
                    loc: loc(),
                    fans_in: if i == 0 { vec![] } else { vec![i - 1] },
                    fans_out: vec![],
                    width_defaulted: true,
                    reads_reg: false,
                    lhs: Some("result_o".into()),
                    rhs: Some(format!("arm_{i}")),
                    lhs_expr: None,
                    rhs_expr: None,
                    case_labels: Vec::new(),
                    case_is_default: false,
                    case_selector: None,
                    fo4_locked: false,
                    assign_kind: Default::default(),
                },
            );
        }
        // Parallel prep temps (not exclusive arms).
        for (i, name, cost) in [(16u32, "rolw", 12.0), (17, "bit_indx", 8.0)] {
            nodes.insert(
                i,
                IrNode {
                    id: i,
                    op_class: Some(OperatorClass::ShiftVar),
                    width: 64,
                    fo4_cost: cost,
                    gate: None,
                    loc: loc(),
                    fans_in: vec![0],
                    fans_out: vec![],
                    width_defaulted: true,
                    reads_reg: false,
                    lhs: Some(name.into()),
                    rhs: Some(name.into()),
                    lhs_expr: None,
                    rhs_expr: None,
                    case_labels: Vec::new(),
                    case_is_default: false,
                    case_selector: None,
                    fo4_locked: false,
                    assign_kind: Default::default(),
                },
            );
        }
        design.modules.insert(
            0,
            TimingModule {
                id: 0,
                name: "alu".into(),
                file: "alu.sv".into(),
                nodes,
                regions: Map::new(),
                localparams: vec![],
                parameters: vec![],
                ports: vec![],
                gen_loops: vec![],
                functions: vec![],
                function_bodies: Vec::new(),
                package_imports: vec![],
                instances: vec![],
                decls: Vec::new(),
                config_branch: false,
                loc: loc(),
            },
        );
        design.module_names.insert("alu".into(), 0);
        let start = PathEndpoint::InputPort { module: 0, port: 0 };
        let end = PathEndpoint::OutputPort { module: 0, port: 1 };
        // raw = 16*20 + 12 + 8 = 340
        design.paths.push(TimingPath {
            id: 7,
            region_id: 0,
            module: 0,
            start: start.clone(),
            end: end.clone(),
            path_kind: PathKind::from_endpoints(&start, &end),
            startpoint: "alu.in0".into(),
            endpoint: "alu.out0".into(),
            nodes: (0..18).collect(),
            total_fo4: 340.0,
            slack_fo4: -308.0,
            max_freq_mhz: 100.0,
            primary_loc: loc(),
            multi_cycle: false,
            path_class: PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: None,
        });
        let model = CostModel::default();
        classify_and_adjust_paths(&mut design, &model, None);
        let p = &design.paths[0];
        assert_eq!(p.path_class, PathClassKind::ExclusiveCaseMux);
        // max(max_arm=20, prep_arm) + unique-case mux (not log2(n)*mux)
        assert!(
            p.total_fo4 < 30.0,
            "parallel prep must max with hot arm, not re-inflate, got {}",
            p.total_fo4
        );
        // Dense must not steal exclusive-shaped result mux
        assert!(
            !design.path_exceptions[0]
                .attempted
                .iter()
                .any(|a| a.detector == "dense_control_cone" && a.matched),
            "dense should refuse exclusive-shaped path: {:?}",
            design.path_exceptions[0].attempted
        );
    }

    #[test]
    fn under_budget_skips_expensive_detectors() {
        let mut d = make_exclusive_design();
        d.paths[0].total_fo4 = 10.0;
        d.paths[0].nodes = vec![0];
        let model = CostModel::default();
        classify_and_adjust_paths(&mut d, &model, None);
        assert_eq!(d.paths[0].path_class, PathClassKind::UnderBudget);
        assert!(d.path_exceptions[0].attempted.is_empty());
    }

    #[test]
    fn cache_hint_skips_detectors() {
        let mut d = make_exclusive_design();
        let model = CostModel::default();
        classify_and_adjust_paths(&mut d, &model, None);
        let hints = hints_from_exceptions(&d.path_exceptions);
        // Reset path to raw sum as if remeasure
        d.paths[0].total_fo4 = 320.0;
        d.paths[0].path_class = PathClassKind::Plain;
        d.paths[0].total_fo4_raw = None;
        d.path_exceptions.clear();
        classify_and_adjust_paths(&mut d, &model, Some(&hints));
        assert_eq!(d.paths[0].path_class, PathClassKind::ExclusiveCaseMux);
        assert!(
            d.path_exceptions[0]
                .attempted
                .iter()
                .any(|a| a.detector == "cache_hint"),
            "{:?}",
            d.path_exceptions[0].attempted
        );
        assert!(d.paths[0].total_fo4 < 100.0);
    }

    #[test]
    fn dense_control_cone_deflates_fsm_sum() {
        let mut design = TimingDesign::empty(TimingTarget::new(1250.0, 20.0, 0.2));
        let mut nodes = Map::new();
        // 24 small compare/assign ops ~3 FO4 each → raw 72; max ~3 → dense control
        for i in 0..24u32 {
            nodes.insert(
                i,
                IrNode {
                    id: i,
                    op_class: Some(OperatorClass::Compare),
                    width: 4,
                    fo4_cost: 3.0,
                    gate: None,
                    loc: loc(),
                    fans_in: if i == 0 { vec![] } else { vec![i - 1] },
                    fans_out: vec![],
                    width_defaulted: true,
                    reads_reg: false,
                    lhs: if i % 5 == 0 {
                        Some("state_d".into())
                    } else {
                        None
                    },
                    rhs: Some(format!("c{i}")),
                    lhs_expr: None,
                    rhs_expr: None,
                    case_labels: Vec::new(),
                    case_is_default: false,
                    case_selector: None,
                    fo4_locked: false,
                    assign_kind: Default::default(),
                },
            );
        }
        design.modules.insert(
            0,
            TimingModule {
                id: 0,
                name: "load_unit".into(),
                file: "l.sv".into(),
                nodes,
                regions: Map::new(),
                localparams: vec![],
                parameters: vec![],
                ports: vec![],
                gen_loops: vec![],
                functions: vec![],
                function_bodies: Vec::new(),
                package_imports: vec![],
                instances: vec![],
                decls: Vec::new(),
                config_branch: false,
                loc: loc(),
            },
        );
        design.module_names.insert("load_unit".into(), 0);
        let start = PathEndpoint::InputPort { module: 0, port: 0 };
        let end = PathEndpoint::OutputPort { module: 0, port: 1 };
        design.paths.push(TimingPath {
            id: 141,
            region_id: 0,
            module: 0,
            start: start.clone(),
            end: end.clone(),
            path_kind: PathKind::from_endpoints(&start, &end),
            startpoint: "load_unit.in0".into(),
            endpoint: "load_unit.out0".into(),
            nodes: (0..24).collect(),
            total_fo4: 72.0,
            slack_fo4: -40.0,
            max_freq_mhz: 400.0,
            primary_loc: loc(),
            multi_cycle: false,
            path_class: PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: None,
        });
        classify_and_adjust_paths(&mut design, &CostModel::default(), None);
        let p = &design.paths[0];
        assert_eq!(p.path_class, PathClassKind::DenseControlCone);
        assert!(
            p.total_fo4 < 32.0,
            "dense control should screen under 32 FO4 budget, got {}",
            p.total_fo4
        );
    }

    #[test]
    fn independent_lhs_bundle_deflates_statement_order_sum() {
        let mut design = TimingDesign::empty(TimingTarget::new(1250.0, 20.0, 0.2));
        let mut nodes = Map::new();
        // 8 independent field assigns, 12 FO4 each → raw 96; parallel max ≈ 12 + wire
        for i in 0..8u32 {
            nodes.insert(
                i,
                IrNode {
                    id: i,
                    op_class: Some(OperatorClass::AddSub),
                    width: 64,
                    fo4_cost: 12.0,
                    gate: None,
                    loc: loc(),
                    fans_in: if i == 0 { vec![] } else { vec![i - 1] },
                    fans_out: vec![],
                    width_defaulted: true,
                    reads_reg: false,
                    lhs: Some(format!("resolved_branch_o.field_{i}")),
                    rhs: Some(format!("expr_{i}")),
                    lhs_expr: None,
                    rhs_expr: None,
                    case_labels: Vec::new(),
                    case_is_default: false,
                    case_selector: None,
                    fo4_locked: false,
                    assign_kind: Default::default(),
                },
            );
        }
        design.modules.insert(
            0,
            TimingModule {
                id: 0,
                name: "branch_unit".into(),
                file: "b.sv".into(),
                nodes,
                regions: Map::new(),
                localparams: vec![],
                parameters: vec![],
                ports: vec![],
                gen_loops: vec![],
                functions: vec![],
                function_bodies: Vec::new(),
                package_imports: vec![],
                instances: vec![],
                decls: Vec::new(),
                config_branch: false,
                loc: loc(),
            },
        );
        design.module_names.insert("branch_unit".into(), 0);
        let start = PathEndpoint::InputPort { module: 0, port: 0 };
        let end = PathEndpoint::OutputPort { module: 0, port: 1 };
        design.paths.push(TimingPath {
            id: 104,
            region_id: 0,
            module: 0,
            start: start.clone(),
            end: end.clone(),
            path_kind: PathKind::from_endpoints(&start, &end),
            startpoint: "branch_unit.in0".into(),
            endpoint: "branch_unit.out0".into(),
            nodes: (0..8).collect(),
            total_fo4: 96.0,
            slack_fo4: -64.0,
            max_freq_mhz: 400.0,
            primary_loc: loc(),
            multi_cycle: false,
            path_class: PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: None,
        });
        classify_and_adjust_paths(&mut design, &CostModel::default(), None);
        let p = &design.paths[0];
        assert_eq!(p.path_class, PathClassKind::IndependentLhsBundle);
        assert!(
            p.total_fo4 < 40.0,
            "bundle should collapse ~96 FO4 serial sum, got {}",
            p.total_fo4
        );
    }

    #[test]
    fn sequential_next_state_bundle_drops_log_mux_tax() {
        let mut design = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        // budget ≈ 10 FO4. 8 next-state `_d` fields at 10 FO4 each → raw 80.
        // Old wire tax 2*other*log2(8) ≈ 6 kept the cone ~16–19 FO4 (axi_adapter).
        let mut nodes = Map::new();
        for i in 0..8u32 {
            nodes.insert(
                i,
                IrNode {
                    id: i,
                    op_class: Some(OperatorClass::AddSub),
                    width: 32,
                    fo4_cost: 10.0,
                    gate: None,
                    loc: loc(),
                    fans_in: if i == 0 { vec![] } else { vec![i - 1] },
                    fans_out: vec![],
                    width_defaulted: true,
                    reads_reg: false,
                    lhs: Some(format!("field_{i}_d")),
                    rhs: Some(format!("expr_{i}")),
                    lhs_expr: None,
                    rhs_expr: None,
                    case_labels: Vec::new(),
                    case_is_default: false,
                    case_selector: None,
                    fo4_locked: false,
                    assign_kind: Default::default(),
                },
            );
        }
        design.modules.insert(
            0,
            TimingModule {
                id: 0,
                name: "axi_adapter".into(),
                file: "axi_adapter.sv".into(),
                nodes,
                regions: Map::new(),
                localparams: vec![],
                parameters: vec![],
                ports: vec![],
                gen_loops: vec![],
                functions: vec![],
                function_bodies: Vec::new(),
                package_imports: vec![],
                instances: vec![],
                decls: Vec::new(),
                config_branch: false,
                loc: loc(),
            },
        );
        design.module_names.insert("axi_adapter".into(), 0);
        let start = PathEndpoint::InputPort { module: 0, port: 0 };
        let end = PathEndpoint::OutputPort { module: 0, port: 1 };
        design.paths.push(TimingPath {
            id: 3951,
            region_id: 0,
            module: 0,
            start: start.clone(),
            end: end.clone(),
            path_kind: PathKind::from_endpoints(&start, &end),
            startpoint: "axi_adapter.in0".into(),
            endpoint: "axi_adapter.out0".into(),
            nodes: (0..8).collect(),
            total_fo4: 80.0,
            slack_fo4: -70.0,
            max_freq_mhz: 400.0,
            primary_loc: loc(),
            multi_cycle: false,
            path_class: PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: None,
        });
        classify_and_adjust_paths(&mut design, &CostModel::default(), None);
        let p = &design.paths[0];
        assert_eq!(p.path_class, PathClassKind::IndependentLhsBundle);
        assert!(
            p.total_fo4 <= 10.5,
            "next-state bundle should be max_field with no wire tax, got {}",
            p.total_fo4
        );
        assert!(
            p.class_note
                .as_deref()
                .is_some_and(|n| n.contains("next_state=true")),
            "note={:?}",
            p.class_note
        );
        assert!(p.path_class.discourages_insert_reg());
    }

    #[test]
    fn next_state_multi_write_field_is_max_not_log_mux() {
        // server_prefetcher: 7 exclusive overwrites of pf_addr_d at 10 FO4
        // used to bill 10 + log2(7)*2.5 = 17.
        let mut design = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        let mut nodes = Map::new();
        let mut id = 0u32;
        // Three exclusive overwrites (w>=3 trips the old log-mux). Keep the
        // field below 50% of writes so exclusive does not steal the bundle.
        for _ in 0..3u32 {
            nodes.insert(
                id,
                IrNode {
                    id,
                    op_class: Some(OperatorClass::AddSub),
                    width: 64,
                    fo4_cost: 10.0,
                    gate: None,
                    loc: loc(),
                    fans_in: vec![],
                    fans_out: vec![],
                    width_defaulted: true,
                    reads_reg: false,
                    lhs: Some("pf_addr_d".into()),
                    rhs: Some("demand_line + stride".into()),
                    lhs_expr: None,
                    rhs_expr: None,
                    case_labels: Vec::new(),
                    case_is_default: false,
                    case_selector: None,
                    fo4_locked: false,
                    assign_kind: Default::default(),
                },
            );
            id += 1;
        }
        for f in 1..7u32 {
            for _ in 0..2u32 {
                nodes.insert(
                    id,
                    IrNode {
                        id,
                        op_class: Some(OperatorClass::Other),
                        width: 1,
                        fo4_cost: 8.0,
                        gate: None,
                        loc: loc(),
                        fans_in: vec![],
                        fans_out: vec![],
                        width_defaulted: true,
                        reads_reg: false,
                        lhs: Some(format!("field_{f}_d")),
                        rhs: Some("x".into()),
                        lhs_expr: None,
                        rhs_expr: None,
                        case_labels: Vec::new(),
                        case_is_default: false,
                        case_selector: None,
                        fo4_locked: false,
                        assign_kind: Default::default(),
                    },
                );
                id += 1;
            }
        }
        let n_nodes = id;
        design.modules.insert(
            0,
            TimingModule {
                id: 0,
                name: "g6lc_server_prefetcher".into(),
                file: "pf.sv".into(),
                nodes,
                regions: Map::new(),
                localparams: vec![],
                parameters: vec![],
                ports: vec![],
                gen_loops: vec![],
                functions: vec![],
                function_bodies: Vec::new(),
                package_imports: vec![],
                instances: vec![],
                decls: Vec::new(),
                config_branch: false,
                loc: loc(),
            },
        );
        design
            .module_names
            .insert("g6lc_server_prefetcher".into(), 0);
        let start = PathEndpoint::RegClock { cell: 0 };
        let end = PathEndpoint::RegData { cell: 1 };
        design.paths.push(TimingPath {
            id: 1,
            region_id: 0,
            module: 0,
            start: start.clone(),
            end: end.clone(),
            path_kind: PathKind::from_endpoints(&start, &end),
            startpoint: "pf.reg0/CP".into(),
            endpoint: "pf.reg1/D".into(),
            nodes: (0..n_nodes).collect(),
            total_fo4: 126.0,
            slack_fo4: -96.0,
            max_freq_mhz: 400.0,
            primary_loc: loc(),
            multi_cycle: false,
            path_class: PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: None,
        });
        classify_and_adjust_paths(&mut design, &CostModel::default(), None);
        let p = &design.paths[0];
        assert_eq!(p.path_class, PathClassKind::IndependentLhsBundle);
        assert!(
            p.total_fo4 <= 10.5,
            "next-state multi-write field must not add log2 mux, got {} note={:?}",
            p.total_fo4,
            p.class_note
        );
    }

    #[test]
    fn exclusive_flop_capture_is_max_arm_not_mux_plus_leftover() {
        // dram_timing `aw_wait_q` / dm_mem `rdata_d`: unique-case flop D.
        let mut design = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        let mut nodes = Map::new();
        for i in 0..4u32 {
            nodes.insert(
                i,
                IrNode {
                    id: i,
                    op_class: Some(OperatorClass::AddSub),
                    width: 32,
                    fo4_cost: 10.0,
                    gate: None,
                    loc: loc(),
                    fans_in: vec![],
                    fans_out: vec![],
                    width_defaulted: true,
                    reads_reg: false,
                    lhs: Some("aw_wait_q".into()),
                    rhs: Some(format!("arm_{i}")),
                    lhs_expr: None,
                    rhs_expr: None,
                    case_labels: Vec::new(),
                    case_is_default: false,
                    case_selector: None,
                    fo4_locked: false,
                    assign_kind: Default::default(),
                },
            );
        }
        for i in 4..8u32 {
            nodes.insert(
                i,
                IrNode {
                    id: i,
                    op_class: Some(OperatorClass::AddSub),
                    width: 32,
                    fo4_cost: 8.0,
                    gate: None,
                    loc: loc(),
                    fans_in: vec![],
                    fans_out: vec![],
                    width_defaulted: true,
                    reads_reg: false,
                    lhs: Some(format!("other_{i}_q")),
                    rhs: Some("sib".into()),
                    lhs_expr: None,
                    rhs_expr: None,
                    case_labels: Vec::new(),
                    case_is_default: false,
                    case_selector: None,
                    fo4_locked: false,
                    assign_kind: Default::default(),
                },
            );
        }
        design.modules.insert(
            0,
            TimingModule {
                id: 0,
                name: "g6lc_ai_dram_timing".into(),
                file: "dram.sv".into(),
                nodes,
                regions: Map::new(),
                localparams: vec![],
                parameters: vec![],
                ports: vec![],
                gen_loops: vec![],
                functions: vec![],
                function_bodies: Vec::new(),
                package_imports: vec![],
                instances: vec![],
                decls: Vec::new(),
                config_branch: false,
                loc: loc(),
            },
        );
        design.module_names.insert("g6lc_ai_dram_timing".into(), 0);
        let start = PathEndpoint::RegClock { cell: 0 };
        let end = PathEndpoint::RegData { cell: 1 };
        design.paths.push(TimingPath {
            id: 1,
            region_id: 0,
            module: 0,
            start: start.clone(),
            end: end.clone(),
            path_kind: PathKind::from_endpoints(&start, &end),
            startpoint: "dram.reg0/CP".into(),
            endpoint: "dram.reg1/D".into(),
            nodes: (0..8).collect(),
            total_fo4: 72.0,
            slack_fo4: -62.0,
            max_freq_mhz: 400.0,
            primary_loc: loc(),
            multi_cycle: false,
            path_class: PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: None,
        });
        classify_and_adjust_paths(&mut design, &CostModel::default(), None);
        let p = &design.paths[0];
        assert_eq!(p.path_class, PathClassKind::ExclusiveCaseMux);
        assert!(
            p.total_fo4 <= 10.5,
            "flop-capture exclusive should be max_arm, got {} note={:?}",
            p.total_fo4,
            p.class_note
        );
    }

    #[test]
    fn exclusive_flop_capture_two_arms_is_max_not_sum() {
        // l2_mshr: waiter shift + nwait decrement both write `mem_d` (2-node
        // Plain 20). Exclusive used to require 3 arms / 4 nodes.
        let mut design = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        let mut nodes = Map::new();
        for (i, rhs) in [
            (0u32, "mem_q[idx].waiters[w+1]"),
            (1u32, "mem_q[idx].nwait - 1'b1"),
        ] {
            nodes.insert(
                i,
                IrNode {
                    id: i,
                    op_class: Some(OperatorClass::AddSub),
                    width: 32,
                    fo4_cost: 10.0,
                    gate: None,
                    loc: loc(),
                    fans_in: vec![],
                    fans_out: vec![],
                    width_defaulted: true,
                    reads_reg: false,
                    lhs: Some(if i == 0 {
                        "mem_d[idx].waiters[w]".into()
                    } else {
                        "mem_d[idx].nwait".into()
                    }),
                    rhs: Some(rhs.into()),
                    lhs_expr: None,
                    rhs_expr: None,
                    case_labels: Vec::new(),
                    case_is_default: false,
                    case_selector: None,
                    fo4_locked: false,
                    assign_kind: Default::default(),
                },
            );
        }
        design.modules.insert(
            0,
            TimingModule {
                id: 0,
                name: "g6lc_l2_mshr".into(),
                file: "mshr.sv".into(),
                nodes,
                regions: Map::new(),
                localparams: vec![],
                parameters: vec![],
                ports: vec![],
                gen_loops: vec![],
                functions: vec![],
                function_bodies: Vec::new(),
                package_imports: vec![],
                instances: vec![],
                decls: Vec::new(),
                config_branch: false,
                loc: loc(),
            },
        );
        design.module_names.insert("g6lc_l2_mshr".into(), 0);
        let start = PathEndpoint::RegClock { cell: 0 };
        let end = PathEndpoint::RegData { cell: 1 };
        design.paths.push(TimingPath {
            id: 1,
            region_id: 0,
            module: 0,
            start: start.clone(),
            end: end.clone(),
            path_kind: PathKind::from_endpoints(&start, &end),
            startpoint: "mshr.reg0/CP".into(),
            endpoint: "mshr.reg1/D".into(),
            nodes: vec![0, 1],
            total_fo4: 20.0,
            slack_fo4: -10.0,
            max_freq_mhz: 2000.0,
            primary_loc: loc(),
            multi_cycle: false,
            path_class: PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: None,
        });
        classify_and_adjust_paths(&mut design, &CostModel::default(), None);
        let p = &design.paths[0];
        assert_eq!(p.path_class, PathClassKind::ExclusiveCaseMux);
        assert!(
            p.total_fo4 <= 10.5,
            "2-arm mem_d capture should be max_arm, got {} note={:?}",
            p.total_fo4,
            p.class_note
        );
    }

    #[test]
    fn always_ff_nba_bundle_deflates_q_on_rhs_serial_sum() {
        // g6lc_ai_gemm_seq always_ff: sibling NBAs (some reading Q) were a
        // 144-node Plain serial sum because NBA→later-read poisoned
        // procedural_ok. IEEE NBA schedule: those reads are Q, not combo.
        let mut design = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        let seq_gate = crate::ir::GateInfo {
            is_comb: false,
            ..crate::ir::GateInfo::default()
        };
        let mut nodes = Map::new();
        for i in 0..8u32 {
            nodes.insert(
                i,
                IrNode {
                    id: i,
                    op_class: Some(OperatorClass::AddSub),
                    width: 32,
                    fo4_cost: 12.0,
                    gate: Some(seq_gate.clone()),
                    loc: loc(),
                    fans_in: if i == 0 { vec![] } else { vec![i - 1] },
                    fans_out: vec![],
                    width_defaulted: true,
                    reads_reg: true,
                    lhs: Some(format!("field_{i}_q")),
                    rhs: Some(if i == 0 {
                        "d_i".into()
                    } else {
                        format!("field_{}_q + 1", i - 1)
                    }),
                    lhs_expr: None,
                    rhs_expr: None,
                    case_labels: Vec::new(),
                    case_is_default: false,
                    case_selector: None,
                    fo4_locked: false,
                    assign_kind: crate::ir::AssignKind::Nonblocking,
                },
            );
        }
        let mut regions = Map::new();
        regions.insert(
            0,
            crate::ir::CombRegion {
                id: 0,
                module: 0,
                kind: crate::ir::RegionKind::AlwaysFf,
                label: None,
                gate: seq_gate,
                nodes: (0..8).collect(),
                total_fo4: 96.0,
                loc_span: loc(),
                multi_cycle: false,
            },
        );
        design.modules.insert(
            0,
            TimingModule {
                id: 0,
                name: "g6lc_ai_gemm_seq".into(),
                file: "gemm.sv".into(),
                nodes,
                regions,
                localparams: vec![],
                parameters: vec![],
                ports: vec![],
                gen_loops: vec![],
                functions: vec![],
                function_bodies: Vec::new(),
                package_imports: vec![],
                instances: vec![],
                decls: Vec::new(),
                config_branch: false,
                loc: loc(),
            },
        );
        design.module_names.insert("g6lc_ai_gemm_seq".into(), 0);
        let start = PathEndpoint::RegClock { cell: 0 };
        let end = PathEndpoint::RegData { cell: 1 };
        design.paths.push(TimingPath {
            id: 3131,
            region_id: 0,
            module: 0,
            start: start.clone(),
            end: end.clone(),
            path_kind: PathKind::from_endpoints(&start, &end),
            startpoint: "g6lc_ai_gemm_seq.reg0/CP".into(),
            endpoint: "g6lc_ai_gemm_seq.reg1/D".into(),
            nodes: (0..8).collect(),
            total_fo4: 96.0,
            slack_fo4: -86.0,
            max_freq_mhz: 247.0,
            primary_loc: loc(),
            multi_cycle: false,
            path_class: PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: None,
        });
        classify_and_adjust_paths(&mut design, &CostModel::default(), None);
        let p = &design.paths[0];
        assert_ne!(
            p.path_class,
            PathClassKind::Plain,
            "always_ff NBA siblings must not stay serial Plain: class={:?} note={:?}",
            p.path_class,
            p.class_note
        );
        assert!(
            p.total_fo4 < 40.0,
            "144-node-shaped NBA bundle should collapse ~96 FO4 serial sum, got {} class={:?} note={:?}",
            p.total_fo4,
            p.path_class,
            p.class_note
        );
        assert!(p.path_class.discourages_insert_reg());
    }

    #[test]
    fn composed_next_state_fsm_bundles_to_max_field_not_makespan() {
        // coherence_hub: P5 compose + `_d` fields. Shared winner temps serialize
        // the scratchboard makespan (~3× max_field) but each flop D is one field.
        let mut design = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        let mut nodes = Map::new();
        for i in 0..8u32 {
            nodes.insert(
                i,
                IrNode {
                    id: i,
                    op_class: Some(OperatorClass::AddSub),
                    width: 32,
                    fo4_cost: 10.0,
                    gate: None,
                    loc: loc(),
                    fans_in: if i == 0 { vec![] } else { vec![i - 1] },
                    fans_out: vec![],
                    width_defaulted: true,
                    reads_reg: false,
                    lhs: Some(format!("field_{i}_d")),
                    rhs: Some(if i == 0 {
                        "a_i + b_i".into()
                    } else {
                        format!("field_{}_d + 1", i - 1)
                    }),
                    lhs_expr: None,
                    rhs_expr: None,
                    case_labels: Vec::new(),
                    case_is_default: false,
                    case_selector: None,
                    fo4_locked: false,
                    assign_kind: crate::ir::AssignKind::Blocking,
                },
            );
        }
        let mut regions = Map::new();
        regions.insert(
            0,
            crate::ir::CombRegion {
                id: 0,
                module: 0,
                kind: crate::ir::RegionKind::ContAssign,
                label: None,
                gate: crate::ir::GateInfo {
                    is_comb: true,
                    ..crate::ir::GateInfo::default()
                },
                nodes: (0..4).collect(),
                total_fo4: 40.0,
                loc_span: loc(),
                multi_cycle: false,
            },
        );
        regions.insert(
            1,
            crate::ir::CombRegion {
                id: 1,
                module: 0,
                kind: crate::ir::RegionKind::AlwaysComb,
                label: None,
                gate: crate::ir::GateInfo {
                    is_comb: true,
                    ..crate::ir::GateInfo::default()
                },
                nodes: (4..8).collect(),
                total_fo4: 40.0,
                loc_span: loc(),
                multi_cycle: false,
            },
        );
        design.modules.insert(
            0,
            TimingModule {
                id: 0,
                name: "g6lc_coherence_hub".into(),
                file: "hub.sv".into(),
                nodes,
                regions,
                localparams: vec![],
                parameters: vec![],
                ports: vec![],
                gen_loops: vec![],
                functions: vec![],
                function_bodies: Vec::new(),
                package_imports: vec![],
                instances: vec![],
                decls: Vec::new(),
                config_branch: false,
                loc: loc(),
            },
        );
        design.module_names.insert("g6lc_coherence_hub".into(), 0);
        let start = PathEndpoint::RegClock { cell: 0 };
        let end = PathEndpoint::RegData { cell: 1 };
        design.paths.push(TimingPath {
            id: 3635,
            region_id: 1,
            module: 0,
            start: start.clone(),
            end: end.clone(),
            path_kind: PathKind::from_endpoints(&start, &end),
            startpoint: "g6lc_coherence_hub.reg0/CP".into(),
            endpoint: "g6lc_coherence_hub.reg1/D".into(),
            nodes: (0..8).collect(),
            total_fo4: 80.0,
            slack_fo4: -70.0,
            max_freq_mhz: 400.0,
            primary_loc: loc(),
            multi_cycle: false,
            path_class: PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: None,
        });
        classify_and_adjust_paths(&mut design, &CostModel::default(), None);
        let p = &design.paths[0];
        assert_eq!(
            p.path_class,
            PathClassKind::IndependentLhsBundle,
            "composed next-state must bundle, got {:?} note={:?}",
            p.path_class,
            p.class_note
        );
        assert!(
            p.total_fo4 <= 10.5,
            "next-state capture is max_field not makespan, got {} note={:?}",
            p.total_fo4,
            p.class_note
        );
        assert!(p.path_class.discourages_insert_reg());
    }

    #[test]
    fn mixed_next_state_and_ports_still_drops_wire_tax() {
        // axi_adapter: 6 `_d` flops + many `axi_req_o.*` ports. Frac 0.6 missed this.
        let mut design = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        let mut nodes = Map::new();
        for i in 0..6u32 {
            nodes.insert(
                i,
                IrNode {
                    id: i,
                    op_class: Some(OperatorClass::AddSub),
                    width: 32,
                    fo4_cost: 10.0,
                    gate: None,
                    loc: loc(),
                    fans_in: vec![],
                    fans_out: vec![],
                    width_defaulted: true,
                    reads_reg: false,
                    lhs: Some(format!("field_{i}_d")),
                    rhs: Some("x".into()),
                    lhs_expr: None,
                    rhs_expr: None,
                    case_labels: Vec::new(),
                    case_is_default: false,
                    case_selector: None,
                    fo4_locked: false,
                    assign_kind: Default::default(),
                },
            );
        }
        for i in 6..26u32 {
            nodes.insert(
                i,
                IrNode {
                    id: i,
                    op_class: Some(OperatorClass::Other),
                    width: 1,
                    fo4_cost: 1.0,
                    gate: None,
                    loc: loc(),
                    fans_in: vec![],
                    fans_out: vec![],
                    width_defaulted: true,
                    reads_reg: false,
                    lhs: Some(format!("axi_req_o.w{i}")),
                    rhs: Some("1'b0".into()),
                    lhs_expr: None,
                    rhs_expr: None,
                    case_labels: Vec::new(),
                    case_is_default: false,
                    case_selector: None,
                    fo4_locked: false,
                    assign_kind: Default::default(),
                },
            );
        }
        design.modules.insert(
            0,
            TimingModule {
                id: 0,
                name: "axi_adapter".into(),
                file: "axi_adapter.sv".into(),
                nodes,
                regions: Map::new(),
                localparams: vec![],
                parameters: vec![],
                ports: vec![],
                gen_loops: vec![],
                functions: vec![],
                function_bodies: Vec::new(),
                package_imports: vec![],
                instances: vec![],
                decls: Vec::new(),
                config_branch: false,
                loc: loc(),
            },
        );
        design.module_names.insert("axi_adapter".into(), 0);
        let start = PathEndpoint::InputPort { module: 0, port: 0 };
        let end = PathEndpoint::OutputPort { module: 0, port: 1 };
        design.paths.push(TimingPath {
            id: 1,
            region_id: 0,
            module: 0,
            start: start.clone(),
            end: end.clone(),
            path_kind: PathKind::from_endpoints(&start, &end),
            startpoint: "axi_adapter.in0".into(),
            endpoint: "axi_adapter.out0".into(),
            nodes: (0..26).collect(),
            total_fo4: 80.0,
            slack_fo4: -70.0,
            max_freq_mhz: 400.0,
            primary_loc: loc(),
            multi_cycle: false,
            path_class: PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: None,
        });
        classify_and_adjust_paths(&mut design, &CostModel::default(), None);
        let p = &design.paths[0];
        assert!(
            p.class_note
                .as_deref()
                .is_some_and(|n| n.contains("next_state=true")),
            "note={:?}",
            p.class_note
        );
        assert!(
            p.total_fo4 <= 16.0,
            "mixed _d + ports should drop wire tax, got {}",
            p.total_fo4
        );
    }

    #[test]
    fn sliced_lhs_groups_as_exclusive_mux() {
        // clint rdata / rdata[31:0] / rdata[63:32] are one result mux.
        let mut design = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        let mut nodes = Map::new();
        let slices = [
            "rdata",
            "rdata[31:0]",
            "rdata[63:32]",
            "rdata",
            "rdata[31:0]",
            "rdata[63:32]",
        ];
        for (i, lhs) in slices.iter().enumerate() {
            let i = i as u32;
            nodes.insert(
                i,
                IrNode {
                    id: i,
                    op_class: Some(OperatorClass::Other),
                    width: 64,
                    fo4_cost: 20.0,
                    gate: None,
                    loc: loc(),
                    fans_in: vec![],
                    fans_out: vec![],
                    width_defaulted: true,
                    reads_reg: false,
                    lhs: Some((*lhs).into()),
                    rhs: Some("mtime_q".into()),
                    lhs_expr: None,
                    rhs_expr: None,
                    case_labels: vec![format!("{i}")],
                    case_is_default: false,
                    case_selector: Some("register_address".into()),
                    fo4_locked: false,
                    assign_kind: Default::default(),
                },
            );
        }
        design.modules.insert(
            0,
            TimingModule {
                id: 0,
                name: "clint".into(),
                file: "clint.sv".into(),
                nodes,
                regions: Map::new(),
                localparams: vec![],
                parameters: vec![],
                ports: vec![],
                gen_loops: vec![],
                functions: vec![],
                function_bodies: Vec::new(),
                package_imports: vec![],
                instances: vec![],
                decls: Vec::new(),
                config_branch: false,
                loc: loc(),
            },
        );
        design.module_names.insert("clint".into(), 0);
        let start = PathEndpoint::InputPort { module: 0, port: 0 };
        let end = PathEndpoint::OutputPort { module: 0, port: 1 };
        design.paths.push(TimingPath {
            id: 1,
            region_id: 0,
            module: 0,
            start: start.clone(),
            end: end.clone(),
            path_kind: PathKind::from_endpoints(&start, &end),
            startpoint: "clint.in0".into(),
            endpoint: "clint.out0".into(),
            nodes: (0..6).collect(),
            total_fo4: 120.0,
            slack_fo4: -110.0,
            max_freq_mhz: 300.0,
            primary_loc: loc(),
            multi_cycle: false,
            path_class: PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: None,
        });
        classify_and_adjust_paths(&mut design, &CostModel::default(), None);
        let p = &design.paths[0];
        assert_eq!(p.path_class, PathClassKind::ExclusiveCaseMux);
        assert!(
            p.total_fo4 < 40.0,
            "sliced rdata mux should be max-arm, got {}",
            p.total_fo4
        );
    }

    #[test]
    fn multi_cycle_tagged_still_deflates_exclusive() {
        let mut design = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        let mut nodes = Map::new();
        for i in 0..8u32 {
            nodes.insert(
                i,
                IrNode {
                    id: i,
                    op_class: Some(OperatorClass::Other),
                    width: 32,
                    fo4_cost: 10.0,
                    gate: None,
                    loc: loc(),
                    fans_in: vec![],
                    fans_out: vec![],
                    width_defaulted: true,
                    reads_reg: false,
                    lhs: Some("qt_next".into()),
                    rhs: Some("x".into()),
                    lhs_expr: None,
                    rhs_expr: None,
                    case_labels: vec![format!("{i}")],
                    case_is_default: false,
                    case_selector: Some("state_q".into()),
                    fo4_locked: false,
                    assign_kind: Default::default(),
                },
            );
        }
        design.modules.insert(
            0,
            TimingModule {
                id: 0,
                name: "control_mvp".into(),
                file: "control_mvp.sv".into(),
                nodes,
                regions: Map::new(),
                localparams: vec![],
                parameters: vec![],
                ports: vec![],
                gen_loops: vec![],
                functions: vec![],
                function_bodies: Vec::new(),
                package_imports: vec![],
                instances: vec![],
                decls: Vec::new(),
                config_branch: false,
                loc: loc(),
            },
        );
        design.module_names.insert("control_mvp".into(), 0);
        let start = PathEndpoint::InputPort { module: 0, port: 0 };
        let end = PathEndpoint::OutputPort { module: 0, port: 1 };
        design.paths.push(TimingPath {
            id: 1,
            region_id: 0,
            module: 0,
            start: start.clone(),
            end: end.clone(),
            path_kind: PathKind::from_endpoints(&start, &end),
            startpoint: "control_mvp.in0".into(),
            endpoint: "control_mvp.out0".into(),
            nodes: (0..8).collect(),
            total_fo4: 80.0,
            slack_fo4: -70.0,
            max_freq_mhz: 400.0,
            primary_loc: loc(),
            multi_cycle: true,
            path_class: PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: None,
        });
        classify_and_adjust_paths(&mut design, &CostModel::default(), None);
        let p = &design.paths[0];
        assert_eq!(p.path_class, PathClassKind::MultiCycleTagged);
        assert!(
            p.total_fo4 < 30.0,
            "tagged FPU FSM must still deflate serial 80, got {}",
            p.total_fo4
        );
        assert!(p.multi_cycle);
    }

    #[test]
    fn atomic_mul_flags_discourages_insert() {
        let mut design = TimingDesign::empty(TimingTarget::new(1250.0, 20.0, 0.2));
        let mut nodes = Map::new();
        nodes.insert(
            0,
            IrNode {
                id: 0,
                op_class: Some(OperatorClass::Mul),
                width: 64,
                fo4_cost: 56.0,
                gate: None,
                loc: loc(),
                fans_in: vec![],
                fans_out: vec![],
                width_defaulted: true,
                reads_reg: false,
                lhs: Some("mult_result_d".into()),
                rhs: Some("a*b".into()),
                lhs_expr: None,
                rhs_expr: None,
                case_labels: Vec::new(),
                case_is_default: false,
                case_selector: None,
                fo4_locked: false,
                assign_kind: Default::default(),
            },
        );
        design.modules.insert(
            0,
            TimingModule {
                id: 0,
                name: "multiplier".into(),
                file: "m.sv".into(),
                nodes,
                regions: Map::new(),
                localparams: vec![],
                parameters: vec![],
                ports: vec![],
                gen_loops: vec![],
                functions: vec![],
                function_bodies: Vec::new(),
                package_imports: vec![],
                instances: vec![],
                decls: Vec::new(),
                config_branch: false,
                loc: loc(),
            },
        );
        design.module_names.insert("multiplier".into(), 0);
        let start = PathEndpoint::InputPort { module: 0, port: 0 };
        let end = PathEndpoint::OutputPort { module: 0, port: 1 };
        design.paths.push(TimingPath {
            id: 1,
            region_id: 0,
            module: 0,
            start: start.clone(),
            end: end.clone(),
            path_kind: PathKind::from_endpoints(&start, &end),
            startpoint: "multiplier.in0".into(),
            endpoint: "multiplier.out0".into(),
            nodes: vec![0],
            total_fo4: 56.0,
            slack_fo4: -24.0,
            max_freq_mhz: 500.0,
            primary_loc: loc(),
            multi_cycle: false,
            path_class: PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: None,
        });
        classify_and_adjust_paths(&mut design, &CostModel::default(), None);
        assert_eq!(design.paths[0].path_class, PathClassKind::AtomicOverBudget);
        assert!(design.paths[0].path_class.discourages_insert_reg());
        assert!(
            design.paths[0].multi_cycle,
            "atomic over budget soft multi_cycle for screening"
        );
    }

    #[test]
    fn atomic_preferred_over_dense_deflation() {
        // te_reg-style: many small nodes + one heavy DivRem — dense must not win.
        let mut design = TimingDesign::empty(TimingTarget::new(2500.0, 20.0, 0.2));
        let mut nodes = Map::new();
        let mut ids = Vec::new();
        for i in 0..20u32 {
            nodes.insert(
                i,
                IrNode {
                    id: i,
                    op_class: Some(if i == 0 {
                        OperatorClass::DivRem
                    } else {
                        OperatorClass::LogicBit
                    }),
                    width: 32,
                    fo4_cost: if i == 0 { 120.0 } else { 3.0 },
                    gate: None,
                    loc: loc(),
                    fans_in: vec![],
                    fans_out: vec![],
                    width_defaulted: true,
                    reads_reg: false,
                    lhs: Some(format!("w{i}")),
                    rhs: Some("x".into()),
                    lhs_expr: None,
                    rhs_expr: None,
                    case_labels: Vec::new(),
                    case_is_default: false,
                    case_selector: None,
                    fo4_locked: false,
                    assign_kind: Default::default(),
                },
            );
            ids.push(i);
        }
        design.modules.insert(
            0,
            TimingModule {
                id: 0,
                name: "te_reg".into(),
                file: "te_reg.sv".into(),
                nodes,
                regions: Map::new(),
                localparams: vec![],
                parameters: vec![],
                ports: vec![],
                gen_loops: vec![],
                functions: vec![],
                function_bodies: Vec::new(),
                package_imports: vec![],
                instances: vec![],
                decls: Vec::new(),
                config_branch: false,
                loc: loc(),
            },
        );
        design.module_names.insert("te_reg".into(), 0);
        let start = PathEndpoint::InputPort { module: 0, port: 0 };
        let end = PathEndpoint::OutputPort { module: 0, port: 1 };
        let raw = 120.0 + 19.0 * 3.0;
        design.paths.push(TimingPath {
            id: 611,
            region_id: 0,
            module: 0,
            start: start.clone(),
            end: end.clone(),
            path_kind: PathKind::from_endpoints(&start, &end),
            startpoint: "te_reg.reg0/CP".into(),
            endpoint: "te_reg.reg1/D".into(),
            nodes: ids,
            total_fo4: raw,
            slack_fo4: -raw,
            max_freq_mhz: 100.0,
            primary_loc: loc(),
            multi_cycle: false,
            path_class: PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: None,
        });
        classify_and_adjust_paths(&mut design, &CostModel::default(), None);
        // P4 (audit-strict-v4 cache_ctrl 117 nodes): one DivRem does not brand
        // the whole 20-node cone atomic — remainder stays cuttable.
        assert_ne!(
            design.paths[0].path_class,
            PathClassKind::AtomicOverBudget,
            "note={}",
            design.paths[0].class_note.as_deref().unwrap_or("")
        );
        assert!(
            design.paths[0].total_fo4 <= 125.0,
            "bundle/parallel deflate, not the 177 serial sum, got {}",
            design.paths[0].total_fo4
        );
    }

    #[test]
    fn atomic_in_exclusive_fsm_is_operator_not_serial_sum() {
        // g6lc_ai_exec-style: unique-case next-state with a 56 FO4 mul in one arm.
        let mut design = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        let mut nodes = Map::new();
        for i in 0..12u32 {
            nodes.insert(
                i,
                IrNode {
                    id: i,
                    op_class: Some(if i == 3 {
                        OperatorClass::Mul
                    } else {
                        OperatorClass::Other
                    }),
                    width: 32,
                    fo4_cost: if i == 3 { 56.0 } else { 2.0 },
                    gate: None,
                    loc: loc(),
                    fans_in: vec![],
                    fans_out: vec![],
                    width_defaulted: true,
                    reads_reg: false,
                    lhs: Some("state_d".into()),
                    rhs: Some(if i == 3 {
                        "a * b".into()
                    } else {
                        "ST_IDLE".into()
                    }),
                    lhs_expr: None,
                    rhs_expr: None,
                    case_labels: vec![format!("{i}")],
                    case_is_default: i == 11,
                    case_selector: Some("state_q".into()),
                    fo4_locked: false,
                    assign_kind: Default::default(),
                },
            );
        }
        design.modules.insert(
            0,
            TimingModule {
                id: 0,
                name: "g6lc_ai_exec".into(),
                file: "g6lc_ai_exec.sv".into(),
                nodes,
                regions: Map::new(),
                localparams: vec![],
                parameters: vec![],
                ports: vec![],
                gen_loops: vec![],
                functions: vec![],
                function_bodies: Vec::new(),
                package_imports: vec![],
                instances: vec![],
                decls: Vec::new(),
                config_branch: false,
                loc: loc(),
            },
        );
        design.module_names.insert("g6lc_ai_exec".into(), 0);
        let start = PathEndpoint::InputPort { module: 0, port: 0 };
        let end = PathEndpoint::OutputPort { module: 0, port: 1 };
        let raw = 56.0 + 11.0 * 2.0;
        design.paths.push(TimingPath {
            id: 1,
            region_id: 0,
            module: 0,
            start: start.clone(),
            end: end.clone(),
            path_kind: PathKind::from_endpoints(&start, &end),
            startpoint: "g6lc_ai_exec.in0".into(),
            endpoint: "g6lc_ai_exec.out0".into(),
            nodes: (0..12).collect(),
            total_fo4: raw,
            slack_fo4: -raw,
            max_freq_mhz: 100.0,
            primary_loc: loc(),
            multi_cycle: false,
            path_class: PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: None,
        });
        classify_and_adjust_paths(&mut design, &CostModel::default(), None);
        let p = &design.paths[0];
        // P4: a 12-node exclusive FSM is not path-atomic because one node is a mul.
        assert_ne!(
            p.path_class,
            PathClassKind::AtomicOverBudget,
            "remainder must stay cuttable: {:?}",
            p.path_class
        );
        assert!(
            p.total_fo4 < 70.0,
            "FSM+mul must not keep serial {raw}, got {}",
            p.total_fo4
        );
    }

    #[test]
    fn p4_remainder_notes_atomic_node_and_stays_cuttable() {
        let mut design = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        let mut nodes = Map::new();
        nodes.insert(
            0,
            IrNode {
                id: 0,
                op_class: Some(OperatorClass::Mul),
                width: 32,
                fo4_cost: 56.0,
                gate: None,
                loc: loc(),
                fans_in: vec![],
                fans_out: vec![1],
                width_defaulted: true,
                reads_reg: false,
                lhs: Some("prod".into()),
                rhs: Some("a * b".into()),
                lhs_expr: None,
                rhs_expr: None,
                case_labels: Vec::new(),
                case_is_default: false,
                case_selector: None,
                fo4_locked: false,
                assign_kind: Default::default(),
            },
        );
        nodes.insert(
            1,
            IrNode {
                id: 1,
                op_class: Some(OperatorClass::AddSub),
                width: 32,
                fo4_cost: 10.0,
                gate: None,
                loc: loc(),
                fans_in: vec![0],
                fans_out: vec![2],
                width_defaulted: true,
                reads_reg: false,
                lhs: Some("acc".into()),
                rhs: Some("prod + c".into()),
                lhs_expr: None,
                rhs_expr: None,
                case_labels: Vec::new(),
                case_is_default: false,
                case_selector: None,
                fo4_locked: false,
                assign_kind: Default::default(),
            },
        );
        nodes.insert(
            2,
            IrNode {
                id: 2,
                op_class: Some(OperatorClass::ShiftConst),
                width: 32,
                fo4_cost: 2.0,
                gate: None,
                loc: loc(),
                fans_in: vec![1],
                fans_out: vec![],
                width_defaulted: true,
                reads_reg: false,
                lhs: Some("c_span".into()),
                rhs: Some("acc << 2".into()),
                lhs_expr: None,
                rhs_expr: None,
                case_labels: Vec::new(),
                case_is_default: false,
                case_selector: None,
                fo4_locked: false,
                assign_kind: Default::default(),
            },
        );
        design.modules.insert(
            0,
            TimingModule {
                id: 0,
                name: "gemm_span".into(),
                file: "gemm_span.sv".into(),
                nodes,
                regions: Map::new(),
                localparams: vec![],
                parameters: vec![],
                ports: vec![],
                gen_loops: vec![],
                functions: vec![],
                function_bodies: Vec::new(),
                package_imports: vec![],
                instances: vec![],
                decls: Vec::new(),
                config_branch: false,
                loc: loc(),
            },
        );
        let start = PathEndpoint::RegClock { cell: 0 };
        let end = PathEndpoint::RegData { cell: 1 };
        design.paths.push(TimingPath {
            id: 0,
            region_id: 0,
            module: 0,
            start: start.clone(),
            end: end.clone(),
            path_kind: PathKind::from_endpoints(&start, &end),
            startpoint: "gemm_span.reg0/CP".into(),
            endpoint: "gemm_span.reg1/D".into(),
            nodes: vec![0, 1, 2],
            total_fo4: 68.0,
            slack_fo4: -58.0,
            max_freq_mhz: 100.0,
            primary_loc: loc(),
            multi_cycle: false,
            path_class: PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: None,
        });
        classify_and_adjust_paths(&mut design, &CostModel::default(), None);
        let p = &design.paths[0];
        assert_ne!(p.path_class, PathClassKind::AtomicOverBudget);
        assert!(
            crate::pass_strategy::admits_insert_reg(p),
            "P4 remainder must admit InsertReg class={:?} mc={} n={}",
            p.path_class,
            p.multi_cycle,
            p.nodes.len()
        );
        let note = p.class_note.as_deref().unwrap_or("");
        assert!(
            note.contains("P4 remainder") && note.contains("T3"),
            "expected P4 T3 remainder note, got {note}"
        );
        // Short serial mul chain keeps the operator in the period (gemm_span).
        assert!(
            p.total_fo4 > 50.0,
            "3-node mul chain must keep the 56 FO4 mul, got {}",
            p.total_fo4
        );
    }

    #[test]
    fn p4_remainder_subtracts_when_atomic_dominates_small_bundle() {
        // hpdcache_memctrl :472 — 6-node IndependentLhsBundle at 125 FO4 whose
        // max field is a 120 DivRem (`way % dataWaysPerRamWord`). Dominance
        // (120/125 ≥ 0.90) subtracts; gemm_span (56/68) does not.
        let mut design = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        let mut nodes = Map::new();
        for i in 0..6u32 {
            let is_div = i == 0;
            nodes.insert(
                i,
                IrNode {
                    id: i,
                    op_class: Some(if is_div {
                        OperatorClass::DivRem
                    } else {
                        OperatorClass::Other
                    }),
                    width: 32,
                    fo4_cost: if is_div { 120.0 } else { 1.0 },
                    gate: None,
                    loc: loc(),
                    fans_in: if i == 0 { vec![] } else { vec![i - 1] },
                    fans_out: if i == 5 { vec![] } else { vec![i + 1] },
                    width_defaulted: true,
                    reads_reg: false,
                    lhs: Some(format!("f{i}")),
                    rhs: Some(if is_div {
                        "way % HPDcacheCfg.u.dataWaysPerRamWord".into()
                    } else {
                        format!("f{}", i - 1)
                    }),
                    lhs_expr: None,
                    rhs_expr: None,
                    case_labels: Vec::new(),
                    case_is_default: false,
                    case_selector: None,
                    fo4_locked: false,
                    assign_kind: Default::default(),
                },
            );
        }
        design.modules.insert(
            0,
            TimingModule {
                id: 0,
                name: "hpdcache_memctrl".into(),
                file: "hpdcache_memctrl.sv".into(),
                nodes,
                regions: Map::new(),
                localparams: vec![],
                parameters: vec![],
                ports: vec![],
                gen_loops: vec![],
                functions: vec![],
                function_bodies: Vec::new(),
                package_imports: vec![],
                instances: vec![],
                decls: Vec::new(),
                config_branch: false,
                loc: loc(),
            },
        );
        let start = PathEndpoint::RegClock { cell: 0 };
        let end = PathEndpoint::RegData { cell: 1 };
        design.paths.push(TimingPath {
            id: 0,
            region_id: 0,
            module: 0,
            start: start.clone(),
            end: end.clone(),
            path_kind: PathKind::from_endpoints(&start, &end),
            startpoint: "hpdcache_memctrl.reg0/CP".into(),
            endpoint: "hpdcache_memctrl.reg1/D".into(),
            nodes: vec![0, 1, 2, 3, 4, 5],
            total_fo4: 125.0,
            slack_fo4: -115.0,
            max_freq_mhz: 100.0,
            primary_loc: loc(),
            multi_cycle: false,
            path_class: PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: None,
        });
        classify_and_adjust_paths(&mut design, &CostModel::default(), None);
        let p = &design.paths[0];
        assert_ne!(p.path_class, PathClassKind::AtomicOverBudget);
        assert!(
            p.total_fo4 < 20.0,
            "dominated 120 DivRem must leave a small remainder, got {}",
            p.total_fo4
        );
        let note = p.class_note.as_deref().unwrap_or("");
        assert!(
            note.contains("P4 remainder") && note.contains("T3"),
            "expected P4 T3 remainder note, got {note}"
        );
    }

    #[test]
    fn p4_remainder_subtracts_twin_atomics_in_short_cone() {
        // hpdcache_memctrl :472 — `way / Cfg` and `way % Cfg` as two 120 FO4
        // DivRems plus a wire (241). Dominance is 120/241 ≈ 0.50, but leftover
        // 121 ≥ 120 so P4 still peels one copy. gemm_span leftover 12 < 56 keeps.
        let mut design = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        let mut nodes = Map::new();
        for (i, (cls, cost, lhs, rhs)) in [
            (
                OperatorClass::DivRem,
                120.0,
                "ram_y",
                "way / HPDcacheCfg.u.dataWaysPerRamWord",
            ),
            (
                OperatorClass::DivRem,
                120.0,
                "ram_w",
                "way % HPDcacheCfg.u.dataWaysPerRamWord",
            ),
            (OperatorClass::Other, 1.0, "sel", "ram_w"),
        ]
        .into_iter()
        .enumerate()
        {
            let i = i as u32;
            nodes.insert(
                i,
                IrNode {
                    id: i,
                    op_class: Some(cls),
                    width: 32,
                    fo4_cost: cost,
                    gate: None,
                    loc: loc(),
                    fans_in: if i == 0 { vec![] } else { vec![i - 1] },
                    fans_out: if i == 2 { vec![] } else { vec![i + 1] },
                    width_defaulted: true,
                    reads_reg: false,
                    lhs: Some(lhs.into()),
                    rhs: Some(rhs.into()),
                    lhs_expr: None,
                    rhs_expr: None,
                    case_labels: Vec::new(),
                    case_is_default: false,
                    case_selector: None,
                    fo4_locked: false,
                    assign_kind: Default::default(),
                },
            );
        }
        design.modules.insert(
            0,
            TimingModule {
                id: 0,
                name: "hpdcache_memctrl".into(),
                file: "hpdcache_memctrl.sv".into(),
                nodes,
                regions: Map::new(),
                localparams: vec![],
                parameters: vec![],
                ports: vec![],
                gen_loops: vec![],
                functions: vec![],
                function_bodies: Vec::new(),
                package_imports: vec![],
                instances: vec![],
                decls: Vec::new(),
                config_branch: false,
                loc: loc(),
            },
        );
        let start = PathEndpoint::RegClock { cell: 0 };
        let end = PathEndpoint::RegData { cell: 1 };
        design.paths.push(TimingPath {
            id: 0,
            region_id: 0,
            module: 0,
            start: start.clone(),
            end: end.clone(),
            path_kind: PathKind::from_endpoints(&start, &end),
            startpoint: "hpdcache_memctrl.reg0/CP".into(),
            endpoint: "hpdcache_memctrl.reg1/D".into(),
            nodes: vec![0, 1, 2],
            total_fo4: 241.0,
            slack_fo4: -231.0,
            max_freq_mhz: 100.0,
            primary_loc: loc(),
            multi_cycle: false,
            path_class: PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: None,
        });
        classify_and_adjust_paths(&mut design, &CostModel::default(), None);
        let p = &design.paths[0];
        assert_ne!(p.path_class, PathClassKind::AtomicOverBudget);
        assert!(
            p.total_fo4 < 10.0,
            "twin 120 DivRems must both peel, got {}",
            p.total_fo4
        );
    }

    #[test]
    fn composed_exclusive_cone_still_deflates() {
        let mut design = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        let mut nodes = Map::new();
        for i in 0..8u32 {
            nodes.insert(
                i,
                IrNode {
                    id: i,
                    op_class: Some(OperatorClass::AddSub),
                    width: 64,
                    fo4_cost: 40.0,
                    gate: None,
                    loc: loc(),
                    fans_in: if i == 0 { vec![] } else { vec![i - 1] },
                    fans_out: vec![],
                    width_defaulted: true,
                    reads_reg: false,
                    lhs: Some("result_o".into()),
                    rhs: Some(format!("arm_{i}")),
                    lhs_expr: None,
                    rhs_expr: None,
                    case_labels: vec![format!("{i}")],
                    case_is_default: false,
                    case_selector: Some("sel".into()),
                    fo4_locked: false,
                    assign_kind: Default::default(),
                },
            );
        }
        let mut regions = Map::new();
        regions.insert(
            0,
            crate::ir::CombRegion {
                id: 0,
                module: 0,
                kind: crate::ir::RegionKind::ContAssign,
                label: None,
                gate: crate::ir::GateInfo {
                    is_comb: true,
                    ..crate::ir::GateInfo::default()
                },
                nodes: (0..4).collect(),
                total_fo4: 160.0,
                loc_span: loc(),
                multi_cycle: false,
            },
        );
        regions.insert(
            1,
            crate::ir::CombRegion {
                id: 1,
                module: 0,
                kind: crate::ir::RegionKind::AlwaysComb,
                label: None,
                gate: crate::ir::GateInfo {
                    is_comb: true,
                    ..crate::ir::GateInfo::default()
                },
                nodes: (4..8).collect(),
                total_fo4: 160.0,
                loc_span: loc(),
                multi_cycle: false,
            },
        );
        design.modules.insert(
            0,
            TimingModule {
                id: 0,
                name: "csr_regfile".into(),
                file: "csr_regfile.sv".into(),
                nodes,
                regions,
                localparams: vec![],
                parameters: vec![],
                ports: vec![],
                gen_loops: vec![],
                functions: vec![],
                function_bodies: Vec::new(),
                package_imports: vec![],
                instances: vec![],
                decls: Vec::new(),
                config_branch: false,
                loc: loc(),
            },
        );
        let start = PathEndpoint::RegClock { cell: 0 };
        let end = PathEndpoint::RegData { cell: 1 };
        design.paths.push(TimingPath {
            id: 0,
            region_id: 0,
            module: 0,
            start: start.clone(),
            end: end.clone(),
            path_kind: PathKind::from_endpoints(&start, &end),
            startpoint: "csr_regfile.reg0/CP".into(),
            endpoint: "csr_regfile.reg1/D".into(),
            nodes: (0..8).collect(),
            total_fo4: 320.0,
            slack_fo4: -310.0,
            max_freq_mhz: 100.0,
            primary_loc: loc(),
            multi_cycle: false,
            path_class: PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: None,
        });
        classify_and_adjust_paths(&mut design, &CostModel::default(), None);
        let p = &design.paths[0];
        assert_eq!(
            p.path_class,
            PathClassKind::ExclusiveCaseMux,
            "composed exclusive must still deflate: {:?} {}",
            p.path_class,
            p.class_note.as_deref().unwrap_or("")
        );
        assert!(
            p.total_fo4 < 80.0,
            "exclusive max-arm, not 320 serial, got {}",
            p.total_fo4
        );
    }
}
