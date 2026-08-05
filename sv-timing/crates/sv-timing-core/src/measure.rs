// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Measure / rank paths — “timing valgrind” style ordering (worst first).

//! Structural cost attribution and ranking.
//! See `architecture/AUTO-CORRECT-CORE-API.md` §3.2.

use crate::ir::{
    CombRegion, IrNode, LineCost, OperatorClass, Opportunity, OpportunityKind, RegionReport,
    TimingDesign, TimingPath, TimingTarget,
};
use crate::loc::SourceLoc;

/// Deterministic FO4 unit costs (subset of fo4-v1; full table later from toml).
#[derive(Debug, Clone)]
pub struct CostModel {
    /// Model id.
    pub id: String,
    /// Base costs by class.
    pub logic_bit: f64,
    /// Compare.
    pub compare: f64,
    /// Shift const.
    pub shift_const: f64,
    /// Shift var.
    pub shift_var: f64,
    /// Add/sub.
    pub add_sub: f64,
    /// Mul.
    pub mul: f64,
    /// Div.
    pub div_rem: f64,
    /// Mux.
    pub mux: f64,
    /// Priority mux per level.
    pub priority_mux_per_level: f64,
    /// Concat.
    pub concat: f64,
    /// Other.
    pub other: f64,
}

impl Default for CostModel {
    fn default() -> Self {
        Self {
            id: "fo4-v1".into(),
            logic_bit: 1.0,
            compare: 4.0,
            shift_const: 2.0,
            shift_var: 12.0,
            add_sub: 10.0,
            mul: 56.0,
            div_rem: 120.0,
            mux: 2.5,
            priority_mux_per_level: 3.0,
            concat: 0.5,
            other: 1.0,
        }
    }
}

impl CostModel {
    /// Base FO4 for a class (width scaling applied separately later).
    pub fn base_fo4(&self, class: OperatorClass) -> f64 {
        match class {
            OperatorClass::LogicBit => self.logic_bit,
            OperatorClass::Compare => self.compare,
            OperatorClass::ShiftConst => self.shift_const,
            OperatorClass::ShiftVar => self.shift_var,
            OperatorClass::AddSub => self.add_sub,
            OperatorClass::Mul => self.mul,
            OperatorClass::DivRem => self.div_rem,
            OperatorClass::Mux => self.mux,
            OperatorClass::PriorityMux => self.priority_mux_per_level,
            OperatorClass::Concat => self.concat,
            OperatorClass::Other => self.other,
        }
    }
}

/// Attribute FO4 costs onto all nodes and regions; refresh path slack + max_freq.
///
/// When a node has a parsed [`crate::expr::Expr`] tree, cost is the **critical
/// path** through that tree ([`Expr::fo4_critical_cost`]) so reconvergent
/// parallel arms are not over-counted (arrival-time style). Falls back to
/// `op_class` base when no tree is present.
pub fn attribute_costs(design: &mut TimingDesign, model: &CostModel) {
    design.versions.cost_model = model.id.clone();
    let base = |c: OperatorClass| model.base_fo4(c);
    for module in design.modules.values_mut() {
        for node in module.nodes.values_mut() {
            // Spine expand / half-split lock residual segment FO4 across remeasure.
            if node.fo4_locked {
                continue;
            }
            if let Some(ref ex) = node.rhs_expr {
                let c = ex.fo4_critical_cost(&base);
                if c > 0.0 {
                    node.fo4_cost = c;
                    // Align coarse class with dominant op for reports / cuts
                    node.op_class = Some(ex.dominant_op_class());
                    continue;
                }
            }
            if let Some(c) = node.op_class {
                // Bare BinaryOperator `*`/`/` without recovered RHS (common in
                // genvar index math `i*N`) must not charge full datapath mul/div.
                if matches!(c, OperatorClass::Mul | OperatorClass::DivRem)
                    && node.rhs_expr.is_none()
                    && node.lhs.is_none()
                {
                    node.fo4_cost = model.other * 2.0;
                    node.op_class = Some(OperatorClass::Other);
                } else {
                    node.fo4_cost = model.base_fo4(c);
                }
            }
        }
        for region in module.regions.values_mut() {
            region.total_fo4 = region
                .nodes
                .iter()
                .filter_map(|id| module.nodes.get(id).map(|n| n.fo4_cost))
                .sum();
        }
    }
    let budget = design.target.budget_fo4;
    let fo4_ps = design.target.fo4_ps;
    let margin = design.target.budget_margin;
    for path in &mut design.paths {
        if let Some(module) = design.modules.get(&path.module) {
            // Path nodes are ordered along one timing path → sum of node critical FO4.
            path.total_fo4 = path
                .nodes
                .iter()
                .filter_map(|id| module.nodes.get(id).map(|n| n.fo4_cost))
                .sum();
        }
        path.slack_fo4 = budget - path.total_fo4;
        path.max_freq_mhz = max_freq_mhz_for_path(path.total_fo4, fo4_ps, margin);
        // Keep path_kind / names consistent if endpoints were updated.
        path.path_kind = crate::ir::PathKind::from_endpoints(&path.start, &path.end);
        // Clear prior class until classify re-runs.
        path.path_class = crate::path_class::PathClassKind::Plain;
        path.total_fo4_raw = None;
        path.class_note = None;
    }
    tag_multi_cycle_paths(design);
    // Post-emptive exclusive-case / atomic exceptions; cheap under-budget short-circuit.
    crate::path_class::classify_and_adjust_paths(design, model, None);
}

/// Max clock (MHz) for which path cost `total_fo4` still meets margin.
///
/// `period_ns >= total_fo4 * fo4_ps / 1000 / (1 - margin)`  
/// `f_mhz = 1000 / period_ns`
pub fn max_freq_mhz_for_path(total_fo4: f64, fo4_ps: f64, margin: f64) -> f64 {
    let m = (1.0 - margin).max(1e-6);
    let fo4 = total_fo4.max(1e-9);
    let period_ns = fo4 * fo4_ps.max(1e-9) / 1000.0 / m;
    if period_ns <= 0.0 {
        return 0.0;
    }
    1000.0 / period_ns
}

/// Design-level frequency closure summary (structural, not STA).
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct FrequencyClosure {
    /// Target MHz.
    pub target_mhz: f64,
    /// FO4 budget at target.
    pub budget_fo4: f64,
    /// Worst single-cycle path id (by slack).
    pub worst_path_id: Option<u32>,
    /// Worst slack FO4.
    pub worst_slack_fo4: f64,
    /// Worst path total FO4.
    pub worst_path_fo4: f64,
    /// Worst path startpoint label.
    pub worst_startpoint: String,
    /// Worst path endpoint label.
    pub worst_endpoint: String,
    /// Path kind of the worst path.
    pub worst_path_kind: String,
    /// True if every non-multi-cycle path has slack >= 0 at target.
    pub closes: bool,
    /// Max MHz limited by the worst path (margin applied).
    pub max_freq_mhz: f64,
    /// Count of failing paths (slack < 0).
    pub failing_paths: usize,
    /// Count of reg→reg paths considered for core frequency.
    pub reg_to_reg_paths: usize,
}

/// Compute frequency-closure report from ranked paths.
pub fn frequency_closure(design: &TimingDesign) -> FrequencyClosure {
    let ranked = rank_paths_by_slack(&design.paths, &design.target);
    let reg_to_reg = ranked
        .primary
        .iter()
        .filter(|p| p.path_kind == crate::ir::PathKind::RegToReg)
        .count();
    let failing = ranked.primary.iter().filter(|p| p.slack_fo4 < 0.0).count();
    let worst = ranked.primary.first();
    FrequencyClosure {
        target_mhz: design.target.target_mhz,
        budget_fo4: design.target.budget_fo4,
        worst_path_id: worst.map(|p| p.id),
        worst_slack_fo4: worst.map(|p| p.slack_fo4).unwrap_or(0.0),
        worst_path_fo4: worst.map(|p| p.total_fo4).unwrap_or(0.0),
        worst_startpoint: worst
            .map(|p| p.startpoint.clone())
            .unwrap_or_else(|| "(none)".into()),
        worst_endpoint: worst
            .map(|p| p.endpoint.clone())
            .unwrap_or_else(|| "(none)".into()),
        worst_path_kind: worst
            .map(|p| format!("{:?}", p.path_kind).to_ascii_lowercase())
            .unwrap_or_else(|| "none".into()),
        closes: failing == 0 && !ranked.primary.is_empty(),
        max_freq_mhz: worst.map(|p| p.max_freq_mhz).unwrap_or(design.target.target_mhz),
        failing_paths: failing,
        reg_to_reg_paths: reg_to_reg,
    }
}

/// Paths ranked worst-first (ascending slack). Multi-cycle paths excluded from primary list.
#[derive(Debug, Clone, Default)]
pub struct RankedPaths {
    /// Primary worklist (single-cycle).
    pub primary: Vec<TimingPath>,
    /// Multi-cycle (informational).
    pub multi_cycle: Vec<TimingPath>,
}

/// Rank paths by slack (worst first). Deterministic tie-break: total_fo4 desc, path id.
pub fn rank_paths_by_slack(paths: &[TimingPath], _target: &TimingTarget) -> RankedPaths {
    let mut primary: Vec<TimingPath> = paths.iter().filter(|p| !p.multi_cycle).cloned().collect();
    let multi_cycle: Vec<TimingPath> = paths.iter().filter(|p| p.multi_cycle).cloned().collect();
    primary.sort_by(|a, b| {
        a.slack_fo4
            .partial_cmp(&b.slack_fo4)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| {
                b.total_fo4
                    .partial_cmp(&a.total_fo4)
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
            .then_with(|| a.id.cmp(&b.id))
    });
    RankedPaths {
        primary,
        multi_cycle,
    }
}

/// Rank regions by total FO4 descending.
pub fn rank_regions_by_cost(design: &TimingDesign, top_n: usize) -> Vec<RegionReport> {
    let mut reps: Vec<RegionReport> = Vec::new();
    for module in design.modules.values() {
        for region in module.regions.values() {
            reps.push(RegionReport {
                region_id: region.id,
                module: module.name.clone(),
                total_fo4: region.total_fo4,
                loc: region.loc_span.clone(),
            });
        }
    }
    reps.sort_by(|a, b| {
        b.total_fo4
            .partial_cmp(&a.total_fo4)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.region_id.cmp(&b.region_id))
    });
    reps.truncate(top_n);
    reps
}

/// Aggregate FO4 per file:line.
pub fn line_cost_map(design: &TimingDesign) -> Vec<LineCost> {
    use std::collections::BTreeMap;
    let mut map: BTreeMap<(String, u32), f64> = BTreeMap::new();
    for module in design.modules.values() {
        for node in module.nodes.values() {
            let key = (node.loc.file.clone(), node.loc.start_line);
            *map.entry(key).or_insert(0.0) += node.fo4_cost;
        }
    }
    map.into_iter()
        .map(|((file, line), fo4)| LineCost { file, line, fo4 })
        .collect()
}

/// Review-only STA path-group seed (not a hard SDC constraint).
///
/// See `architecture/STA-HANDOFF.md`. Hosts may render these as comments for
/// engineers; never auto-apply as `set_max_delay` without human review.
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct StaHint {
    /// Local or cross-module path id.
    pub path_id: u32,
    /// `local_path` or `cross_module`.
    pub kind: String,
    /// Suggested `-from` seed (hierarchical / module label).
    pub from: String,
    /// Suggested `-to` seed.
    pub to: String,
    /// Optional `-through` nets (bridge actuals, etc.).
    pub through: Vec<String>,
    /// Structural FO4 for this seed.
    pub structural_fo4: f64,
    /// Structural slack FO4 (negative = over budget).
    pub structural_slack_fo4: f64,
    /// Source locus for the hottest node / instance.
    pub loc: SourceLoc,
    /// Human comment for SDC / review logs.
    pub comment: String,
}

/// Build up to `top_n` STA review seeds from ranked local + cross-module paths.
pub fn sta_hints_from_design(design: &TimingDesign, top_n: usize) -> Vec<StaHint> {
    let ranked = rank_paths_by_slack(&design.paths, &design.target);
    let mut hints: Vec<StaHint> = Vec::new();

    for p in ranked.primary.iter().take(top_n.max(1)) {
        let module_name = design
            .modules
            .get(&p.module)
            .map(|m| m.name.as_str())
            .unwrap_or("?");
        hints.push(StaHint {
            path_id: p.id,
            kind: "local_path".into(),
            from: p.startpoint.clone(),
            to: p.endpoint.clone(),
            through: Vec::new(),
            structural_fo4: p.total_fo4,
            structural_slack_fo4: p.slack_fo4,
            loc: p.primary_loc.clone(),
            comment: format!(
                "sv-timing structural path in {module_name} (kind={:?}); NOT STA sign-off",
                p.path_kind
            ),
        });
    }

    // Cross-module bridges: prefer port_bridged with nets
    let mut xpaths = design.cross_module_paths.clone();
    xpaths.sort_by(|a, b| {
        a.slack_fo4
            .partial_cmp(&b.slack_fo4)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| b.total_fo4.partial_cmp(&a.total_fo4).unwrap_or(std::cmp::Ordering::Equal))
    });
    for p in xpaths.iter().take(top_n.max(1)) {
        hints.push(StaHint {
            path_id: p.id,
            kind: "cross_module".into(),
            from: p.startpoint.clone(),
            to: p.endpoint.clone(),
            through: p.bridge_nets.clone(),
            structural_fo4: p.total_fo4,
            structural_slack_fo4: p.slack_fo4,
            loc: design
                .instances
                .iter()
                .find(|i| {
                    i.instance_name == p.instance_name && i.parent_name == p.parent_module
                })
                .map(|i| i.loc.clone())
                .unwrap_or_else(|| SourceLoc {
                    file: String::new(),
                    start_line: 1,
                    start_col: 1,
                    end_line: 1,
                    end_col: 1,
                    byte_start: 0,
                    byte_end: 0,
                    origin: crate::loc::OriginKind::Unknown,
                }),
            comment: format!(
                "sv-timing {} via {}.{} ({}); bridge nets for hierarchical path groups — NOT set_max_delay",
                p.stitch_kind, p.parent_module, p.instance_name, p.rationale
            ),
        });
    }

    hints.truncate(top_n.saturating_mul(2).max(top_n));
    hints
}

/// Tag paths that are likely multi-cycle by microarchitecture (not STA).
///
/// Conservative name heuristics only — never claims silicon multicycle paths.
/// Tagged paths are skipped by default opportunity ranking / InsertReg pressure.
pub fn tag_multi_cycle_paths(design: &mut TimingDesign) {
    for path in &mut design.paths {
        if path.multi_cycle {
            continue;
        }
        let Some(module) = design.modules.get(&path.module) else {
            continue;
        };
        if module_looks_multi_cycle(&module.name) {
            path.multi_cycle = true;
            continue;
        }
        // Dominant DivRem on a long path inside a *div*/*ser* unit already covered;
        // also tag pure div_rem clouds in any module when node class is DivRem and FO4 large.
        let div_heavy = path.nodes.iter().any(|id| {
            module
                .nodes
                .get(id)
                .map(|n| n.op_class == Some(OperatorClass::DivRem) && n.fo4_cost >= 80.0)
                .unwrap_or(false)
        });
        let nlow = module.name.to_ascii_lowercase();
        if div_heavy && (nlow.contains("div") || nlow.contains("sqrt") || nlow.contains("fpnew")) {
            path.multi_cycle = true;
            continue;
        }
        // Large mul-only clouds (iterative mul / heavy array) over ~2× budget.
        let budget = design.target.budget_fo4;
        let mul_heavy = path.nodes.iter().any(|id| {
            module.nodes.get(id).map(|n| {
                n.op_class == Some(OperatorClass::Mul) && n.fo4_cost >= (budget * 2.0).max(50.0)
            }).unwrap_or(false)
        });
        if mul_heavy
            && (nlow.contains("mul")
                || nlow.contains("mult")
                || nlow.contains("fpnew")
                || path.total_fo4 >= budget * 4.0)
        {
            path.multi_cycle = true;
        }
    }
}

fn module_looks_multi_cycle(name: &str) -> bool {
    let n = name.to_ascii_lowercase();
    // Iterative / serial arithmetic
    n.contains("serdiv")
        || n.contains("serial_div")
        || n.contains("iterdiv")
        || n.contains("iter_div")
        || (n.contains("div") && n.contains("serial"))
        || n.contains("div_sqrt")
        || n.contains("norm_div")
        || n.contains("fpnew_divsqrt")
        // Memory macros / wrappers — not single-cycle EX pressure
        || n.contains("tc_sram")
        || n.contains("syncdpram")
        || n.contains("asyncdpram")
        || n.contains("syncthreeport")
        || n.contains("asyncthreeport")
        || (n.contains("sram") && (n.contains("wrapper") || n.contains("cache")))
        || n == "sram"
        || n.ends_with("_ram")
}

/// Suggest opportunities from over-budget paths.
///
/// Order of kinds (callers may filter):
/// 1. **BalanceMux** — exclusive case/if residual (latency-neutral).
/// 2. **SplitAssign** — deep expression trees (latency-neutral staging).
/// 3. **InsertReg** — mid-path cut when still failing (latency-changing).
///
/// Path classification simplifies work outside exceptions:
/// - [`PathClassKind::UnderBudget`] / multi_cycle — skipped
/// - [`PathClassKind::AtomicOverBudget`] — soft multi_cycle; no ops
/// - Exclusive / independent bundle — BalanceMux + SplitAssign; no InsertReg
/// - [`PathClassKind::Plain`] — full InsertReg + SplitAssign
pub fn suggest_opportunities(design: &TimingDesign) -> Vec<Opportunity> {
    use crate::path_class::PathClassKind;
    let mut out = Vec::new();
    for path in &design.paths {
        if path.multi_cycle || path.slack_fo4 >= 0.0 {
            continue;
        }
        if path.nodes.is_empty() {
            continue;
        }
        // Classification short-circuits (cache-backed on remeasure).
        if matches!(
            path.path_class,
            PathClassKind::UnderBudget
                | PathClassKind::MultiCycleTagged
                | PathClassKind::AtomicOverBudget
        ) {
            continue;
        }
        let exclusive = matches!(
            path.path_class,
            PathClassKind::ExclusiveCaseMux
                | PathClassKind::ExclusiveIfChain
                | PathClassKind::IndependentLhsBundle
                | PathClassKind::DenseControlCone
        );
        let module = design.modules.get(&path.module);

        // BalanceMux: exclusive residual still over budget (hottest arm / select tree).
        if exclusive {
            if let Some(m) = module {
                let mut best: Option<(u32, f64)> = None;
                for id in &path.nodes {
                    let Some(n) = m.nodes.get(id) else { continue };
                    let score = n.fo4_cost;
                    if score < 1.0 {
                        continue;
                    }
                    if best.map(|(_, s)| score > s).unwrap_or(true) {
                        best = Some((*id, score));
                    }
                }
                if let Some((nid, fo4)) = best {
                    let loc = m
                        .nodes
                        .get(&nid)
                        .map(|n| n.loc.clone())
                        .unwrap_or_else(|| path.primary_loc.clone());
                    // Latency-neutral: rebalance/mux-balance credit ~10–20% of path.
                    let after = (path.total_fo4 * 0.82).max(fo4 * 0.85);
                    out.push(Opportunity {
                        kind: OpportunityKind::BalanceMux,
                        path_id: path.id,
                        insert_after: nid,
                        estimated_fo4_before: path.total_fo4,
                        estimated_fo4_after: after.min(path.total_fo4 - 0.5),
                        loc,
                        rationale: format!(
                            "path {} class={:?} balance_mux on hottest node {nid} (no latency)",
                            path.id, path.path_class
                        ),
                        requires_clock_in_scope: false,
                        changes_latency: false,
                    });
                }
            }
        }

        // SplitAssign: hottest node with deep/wide expr (latency-neutral).
        if let Some(m) = module {
            let mut best: Option<(u32, f64, u32)> = None; // node, fo4, op_count
            for id in &path.nodes {
                let Some(n) = m.nodes.get(id) else { continue };
                let ops = n.rhs_expr.as_ref().map(|e| e.op_node_count()).unwrap_or(0);
                let depth = n.rhs_expr.as_ref().map(|e| e.depth()).unwrap_or(1);
                if ops >= 3 || depth >= 4 {
                    let score = n.fo4_cost;
                    if best.map(|(_, s, _)| score > s).unwrap_or(true) {
                        best = Some((*id, score, ops));
                    }
                }
            }
            if let Some((nid, fo4, ops)) = best {
                let loc = m
                    .nodes
                    .get(&nid)
                    .map(|n| n.loc.clone())
                    .unwrap_or_else(|| path.primary_loc.clone());
                // Estimate: splitting names does not remove FO4 alone; modest credit for
                // enabling rebalance/cuts (structural screening only).
                let after = fo4 * 0.9;
                out.push(Opportunity {
                    kind: OpportunityKind::SplitAssign,
                    path_id: path.id,
                    insert_after: nid,
                    estimated_fo4_before: path.total_fo4,
                    estimated_fo4_after: (path.total_fo4 - fo4 + after).max(0.0),
                    loc,
                    rationale: format!(
                        "path {} deep expr at node {nid} (ops={ops}); split_assign (no latency)",
                        path.id
                    ),
                    requires_clock_in_scope: false,
                    changes_latency: false,
                });
            }
        }

        // InsertReg only for plain over-budget paths (exclusive/atomic handled above).
        if exclusive {
            continue;
        }
        let cut_idx = if path.nodes.len() == 1 {
            0
        } else {
            path.nodes.len() / 2 - 1
        };
        let after = path.nodes[cut_idx];
        let loc = design
            .modules
            .get(&path.module)
            .and_then(|m| m.nodes.get(&after))
            .map(|n| n.loc.clone())
            .unwrap_or_else(|| path.primary_loc.clone());
        // Critical-chain half rather than opaque 0.5× when single-node path has expr depth.
        let after_est = if path.nodes.len() == 1 {
            if let Some(n) = module.and_then(|m| m.nodes.get(&after)) {
                if let Some(ref ex) = n.rhs_expr {
                    // Balanced half-depth heuristic after a reg cut through mid expr.
                    (ex.depth() as f64 * 0.5).max(1.0) / (ex.depth() as f64).max(1.0) * path.total_fo4
                } else {
                    path.total_fo4 * 0.5
                }
            } else {
                path.total_fo4 * 0.5
            }
        } else {
            path.total_fo4 * 0.5
        };
        out.push(Opportunity {
            kind: OpportunityKind::InsertReg,
            path_id: path.id,
            insert_after: after,
            estimated_fo4_before: path.total_fo4,
            estimated_fo4_after: after_est,
            loc,
            rationale: format!(
                "path {} slack {:.1} FO4 under budget (cut after node {after}; class=plain)",
                path.id, path.slack_fo4
            ),
            requires_clock_in_scope: true,
            changes_latency: true,
        });
    }
    out
}

/// Recompute path slacks after costs change (cheap remeasure step).
///
/// Re-sums node FO4, re-tags multi-cycle, then re-runs path classification.
/// When prior exceptions exist, their signatures become **cache hints** so
/// exclusive-case detectors are not re-scanned from scratch (simplify non-exception
/// and repeat-exception paths).
pub fn remeasure_path_slacks(design: &mut TimingDesign) {
    let from_design = crate::path_class::hints_from_exceptions(&design.path_exceptions);
    remeasure_path_slacks_with_hints(design, Some(&from_design));
}

/// Like [`remeasure_path_slacks`] with extra cache-loaded hints (signature → class).
pub fn remeasure_path_slacks_with_hints(
    design: &mut TimingDesign,
    external_hints: Option<&std::collections::BTreeMap<String, crate::path_class::PathClassHint>>,
) {
    let budget = design.target.budget_fo4;
    let fo4_ps = design.target.fo4_ps;
    let margin = design.target.budget_margin;
    let mut hints = crate::path_class::hints_from_exceptions(&design.path_exceptions);
    if let Some(ext) = external_hints {
        for (k, v) in ext {
            hints.entry(k.clone()).or_insert_with(|| v.clone());
        }
    }
    for path in &mut design.paths {
        if let Some(module) = design.modules.get(&path.module) {
            path.total_fo4 = path
                .nodes
                .iter()
                .filter_map(|id| module.nodes.get(id).map(|n| n.fo4_cost))
                .sum();
        }
        path.slack_fo4 = budget - path.total_fo4;
        path.max_freq_mhz = max_freq_mhz_for_path(path.total_fo4, fo4_ps, margin);
        path.path_kind = crate::ir::PathKind::from_endpoints(&path.start, &path.end);
        path.path_class = crate::path_class::PathClassKind::Plain;
        path.total_fo4_raw = None;
        path.class_note = None;
    }
    tag_multi_cycle_paths(design);
    let model = CostModel::default();
    let hint_ref = if hints.is_empty() {
        None
    } else {
        Some(&hints)
    };
    crate::path_class::classify_and_adjust_paths(design, &model, hint_ref);
    design.opportunities = suggest_opportunities(design);
}

/// Helper to set node cost from class (tests / synthetic IR).
pub fn apply_node_class(node: &mut IrNode, model: &CostModel) {
    if let Some(c) = node.op_class {
        node.fo4_cost = model.base_fo4(c);
    }
}

/// Sum region from nodes (tests).
pub fn region_total(region: &CombRegion, nodes: &std::collections::BTreeMap<u32, IrNode>) -> f64 {
    region
        .nodes
        .iter()
        .filter_map(|id| nodes.get(id).map(|n| n.fo4_cost))
        .sum()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ir::{PathEndpoint, PathId};
    use crate::loc::{OriginKind, SourceLoc};

    fn loc(line: u32) -> SourceLoc {
        SourceLoc {
            file: "t.sv".into(),
            start_line: line,
            start_col: 1,
            end_line: line,
            end_col: 2,
            byte_start: 0,
            byte_end: 1,
            origin: OriginKind::UserFile,
        }
    }

    fn sample_path(id: PathId, slack: f64, fo4: f64) -> TimingPath {
        let start = PathEndpoint::InputPort {
            module: 0,
            port: 0,
        };
        let end = PathEndpoint::OutputPort {
            module: 0,
            port: 1,
        };
        TimingPath {
            id,
            region_id: 0,
            module: 0,
            start: start.clone(),
            end: end.clone(),
            path_kind: crate::ir::PathKind::from_endpoints(&start, &end),
            startpoint: start.report_name("m"),
            endpoint: end.report_name("m"),
            nodes: vec![id],
            total_fo4: fo4,
            slack_fo4: slack,
            max_freq_mhz: max_freq_mhz_for_path(fo4, 20.0, 0.2),
            primary_loc: loc(id + 1),
            multi_cycle: false,
            path_class: crate::path_class::PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: None,
        }
    }

    #[test]
    fn max_freq_and_closure_basic() {
        // 40 FO4 @ 20ps, margin 0.2 → period >= 40*20/1000/0.8 = 1 ns → 1000 MHz
        let f = max_freq_mhz_for_path(40.0, 20.0, 0.2);
        assert!((f - 1000.0).abs() < 1.0, "got {f}");
    }

    #[test]
    fn sta_hints_include_local_paths() {
        let mut design = TimingDesign::empty(TimingTarget::new(1000.0, 20.0, 0.2));
        // minimal module + path via empty modules map is fine if path.module missing name
        design.paths.push(crate::ir::TimingPath {
            id: 1,
            region_id: 0,
            module: 0,
            start: crate::ir::PathEndpoint::InputPort {
                module: 0,
                port: 0,
            },
            end: crate::ir::PathEndpoint::OutputPort {
                module: 0,
                port: 0,
            },
            path_kind: crate::ir::PathKind::InToOut,
            startpoint: "m.in0".into(),
            endpoint: "m.out0".into(),
            nodes: vec![],
            total_fo4: 40.0,
            slack_fo4: -5.0,
            max_freq_mhz: 800.0,
            primary_loc: SourceLoc {
                file: "m.sv".into(),
                start_line: 10,
                start_col: 1,
                end_line: 10,
                end_col: 2,
                byte_start: 0,
                byte_end: 0,
                origin: crate::loc::OriginKind::UserFile,
            },
            multi_cycle: false,
            path_class: crate::path_class::PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: None,
        });
        let hints = sta_hints_from_design(&design, 4);
        assert!(!hints.is_empty());
        assert_eq!(hints[0].kind, "local_path");
        assert!(hints[0].comment.contains("NOT STA"));
    }

    #[test]
    fn tag_multi_cycle_serdiv_by_name() {
        assert!(module_looks_multi_cycle("serdiv"));
        assert!(module_looks_multi_cycle("Serial_Div_Unit"));
        assert!(!module_looks_multi_cycle("alu"));
        assert!(!module_looks_multi_cycle("multiplier"));
    }

    #[test]
    fn suggest_opportunities_skips_multi_cycle() {
        let mut design = TimingDesign::empty(TimingTarget::new(1250.0, 20.0, 0.2));
        let mut p = sample_path(1, -100.0, 200.0);
        p.multi_cycle = true;
        p.nodes = vec![1];
        design.paths.push(p);
        let ops = suggest_opportunities(&design);
        assert!(ops.is_empty(), "multi_cycle paths must not yield insert/split ops");
    }

    #[test]
    fn rank_paths_deterministic() {
        let paths = vec![
            sample_path(2, -5.0, 50.0),
            sample_path(1, -5.0, 60.0),
            sample_path(3, 1.0, 10.0),
        ];
        let target = TimingTarget::new(1000.0, 20.0, 0.2);
        let r1 = rank_paths_by_slack(&paths, &target);
        let r2 = rank_paths_by_slack(&paths, &target);
        let ids1: Vec<_> = r1.primary.iter().map(|p| p.id).collect();
        let ids2: Vec<_> = r2.primary.iter().map(|p| p.id).collect();
        assert_eq!(ids1, ids2);
        // Worst slack first; equal slack → higher fo4 first → id 1 before 2
        assert_eq!(ids1[0], 1);
        assert_eq!(ids1[1], 2);
        assert_eq!(ids1[2], 3);
    }
}
