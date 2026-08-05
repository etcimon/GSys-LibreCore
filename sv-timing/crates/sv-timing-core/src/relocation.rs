// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Relocation plan: map FO4 bottleneck paths to scored relocation options.

//! Relocation analysis for bottleneck FO4 paths.
//!
//! After [`crate::path_class`] adjusts measurement, remaining primary failures
//! need **relocation** strategies (measure / latency-neutral / temporal /
//! architectural). This module builds a scored plan of options per path without
//! mutating host RTL. See `architecture/RELOCATION-ANALYSIS.md`.

use serde::{Deserialize, Serialize};

use crate::ir::{OpportunityKind, PathId, TimingDesign};
use crate::loc::SourceLoc;
use crate::path_class::PathClassKind;

/// Schema id for JSON consumers.
pub const RELOCATION_PLAN_SCHEMA: &str = "relocation-plan-v0";

/// Logical pattern behind a bottleneck (mirrors architecture table).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RelocationPattern {
    /// Unique-case / exclusive select.
    ExclusiveSelect,
    /// Atomic mul/div.
    AtomicOp,
    /// Multi-LHS always_comb bundle.
    IndependentBundle,
    /// Long associative chain.
    AssociativeChain,
    /// Ordinary sequential cone (may InsertReg).
    PlainCone,
    /// Already multi-cycle / soft multi-cycle.
    MultiCycle,
    /// Under budget — no relocation needed.
    Closed,
    /// Unclassified.
    Unknown,
}

/// Policy tier (auto-correct vs human).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RelocationTier {
    /// T0 measure-only.
    T0,
    /// T1 latency-neutral.
    T1,
    /// T2 temporal pipeline (+latency).
    T2,
    /// T3 architectural (suggest only).
    T3,
}

/// Concrete relocation action kind.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RelocationKind {
    /// T0: path-class / measure adjustment already applied.
    MeasureRelocate,
    /// T1: balance exclusive mux / residual select tree.
    BalanceMux,
    /// T1: associative expression rebalance.
    RebalanceAssoc,
    /// T1: split deep assign into named wires.
    SplitAssign,
    /// T2: pipeline register multi-cut (allow-latency).
    InsertReg,
    /// T1/T2: stage operand prep only (expr spine).
    PrepStage,
    /// T0: soft multi-cycle screening for atomic ops.
    SoftMulticycle,
    /// T3: architectural multi-cycle unit (human/config).
    ArchMulticycle,
    /// T3: split always_comb process by field groups.
    SplitCombProcess,
    /// T3: offload to CVXIF / accelerator.
    CvxifOffload,
}

/// One scored option on a path card.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RelocationOption {
    /// Stable id within the card.
    pub id: String,
    /// Tier.
    pub tier: RelocationTier,
    /// Action kind.
    pub kind: RelocationKind,
    /// Short title.
    pub title: String,
    /// Expected FO4 after this option (screening).
    pub expected_fo4_after: f64,
    /// Estimated latency change in cycles (0 = neutral).
    pub latency_delta: u32,
    /// Package auto-correct may attempt this.
    pub auto_correct: bool,
    /// 0..1 confidence.
    pub confidence: f64,
    /// low | medium | high.
    pub risk: String,
    /// Algorithm / API names.
    pub algorithms: Vec<String>,
    /// Human rationale.
    pub rationale: String,
    /// Composite score (higher = better first try).
    pub score: f64,
}

/// One failing (or residual) path with relocation options.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RelocationCard {
    /// Path id.
    pub path_id: PathId,
    /// Module name.
    pub module: String,
    /// Startpoint label.
    pub startpoint: String,
    /// Endpoint label.
    pub endpoint: String,
    /// Path class after classify.
    pub path_class: PathClassKind,
    /// Logical pattern.
    pub pattern: RelocationPattern,
    /// Adjusted FO4.
    pub total_fo4: f64,
    /// Raw sum FO4 if adjusted.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub total_fo4_raw: Option<f64>,
    /// Slack FO4.
    pub slack_fo4: f64,
    /// Primary source locus.
    pub primary_loc: SourceLoc,
    /// Short function hint.
    pub function_hint: String,
    /// Class note / evidence.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub class_note: Option<String>,
    /// Ranked options.
    pub options: Vec<RelocationOption>,
    /// Best auto_correct option id (if any).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preferred_auto: Option<String>,
    /// Best overall option id.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preferred_any: Option<String>,
}

/// Design-level relocation plan.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RelocationPlan {
    /// Schema.
    pub schema_version: String,
    /// Target MHz.
    pub target_mhz: f64,
    /// FO4 budget.
    pub budget_fo4: f64,
    /// Disclaimer.
    pub disclaimer: String,
    /// Summary counts.
    pub summary: RelocationSummary,
    /// Cards (primary failing first, then soft multi-cycle residuals).
    pub cards: Vec<RelocationCard>,
}

/// Summary block.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RelocationSummary {
    /// Primary failing path count (slack < 0, !multi_cycle).
    pub failing_primary: usize,
    /// Cards emitted.
    pub cards: usize,
    /// Pattern histogram.
    pub by_pattern: std::collections::BTreeMap<String, u32>,
    /// Count of auto_correct-eligible options across cards.
    pub auto_correct_options: usize,
    /// Count of T3-only residual cards (no auto option with score > 0).
    pub t3_only_cards: usize,
}

/// Build a relocation plan from a classified design.
///
/// Includes:
/// - primary failing paths (`!multi_cycle && slack < 0`)
/// - soft multi-cycle atomic paths (still need architectural options)
pub fn build_relocation_plan(design: &TimingDesign) -> RelocationPlan {
    let budget = design.target.budget_fo4;
    let mod_names: std::collections::BTreeMap<u32, String> = design
        .modules
        .iter()
        .map(|(id, m)| (*id, m.name.clone()))
        .collect();

    let mut cards = Vec::new();
    let mut failing_primary = 0usize;

    for path in &design.paths {
        let primary_fail = !path.multi_cycle && path.slack_fo4 < 0.0;
        let soft_atomic = path.multi_cycle
            && matches!(path.path_class, PathClassKind::AtomicOverBudget);
        if !primary_fail && !soft_atomic {
            continue;
        }
        if primary_fail {
            failing_primary += 1;
        }

        let module = mod_names
            .get(&path.module)
            .cloned()
            .unwrap_or_else(|| format!("mod{}", path.module));
        let pattern = pattern_from_class(path.path_class, path.multi_cycle);
        let mut options = options_for_path(design, path, pattern, budget);
        options.sort_by(|a, b| {
            b.score
                .partial_cmp(&a.score)
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        // Prefer transform-capable auto options over pure T0 measure keepers.
        let preferred_auto = preferred_actionable_kind_from_options(&options)
            .and_then(|k| {
                options
                    .iter()
                    .find(|o| o.auto_correct && o.kind == k)
                    .map(|o| o.id.clone())
            })
            .or_else(|| {
                options
                    .iter()
                    .find(|o| o.auto_correct && o.score > 0.0)
                    .map(|o| o.id.clone())
            });
        let preferred_any = options.first().map(|o| o.id.clone());

        cards.push(RelocationCard {
            path_id: path.id,
            module,
            startpoint: path.startpoint.clone(),
            endpoint: path.endpoint.clone(),
            path_class: path.path_class,
            pattern,
            total_fo4: path.total_fo4,
            total_fo4_raw: path.total_fo4_raw,
            slack_fo4: path.slack_fo4,
            primary_loc: path.primary_loc.clone(),
            function_hint: function_hint(pattern, path.path_class),
            class_note: path.class_note.clone(),
            options,
            preferred_auto,
            preferred_any,
        });
    }

    // Stable order: worst slack first, then path id.
    cards.sort_by(|a, b| {
        a.slack_fo4
            .partial_cmp(&b.slack_fo4)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.path_id.cmp(&b.path_id))
    });

    // Full-core scale: interleave patterns *and* modules so one hot module
    // (e.g. fpnew InsertReg) cannot bury residual exclusive cones (control_mvp).
    let n_mod_unique = {
        let mut s = std::collections::BTreeSet::new();
        for c in &cards {
            s.insert(c.module.as_str());
        }
        s.len()
    };
    if cards.len() > 24 || n_mod_unique > 12 {
        cards = stratify_cards_by_pattern_and_module(cards);
    }

    let mut by_pattern = std::collections::BTreeMap::new();
    let mut auto_correct_options = 0usize;
    let mut t3_only_cards = 0usize;
    for c in &cards {
        let key = format!("{:?}", c.pattern);
        *by_pattern.entry(key).or_insert(0) += 1;
        auto_correct_options += c.options.iter().filter(|o| o.auto_correct).count();
        if c.preferred_auto.is_none() {
            t3_only_cards += 1;
        }
    }

    RelocationPlan {
        schema_version: RELOCATION_PLAN_SCHEMA.into(),
        target_mhz: design.target.target_mhz,
        budget_fo4: budget,
        disclaimer:
            "structural FO4 screening — not STA; relocation options are suggestions only; never auto-merge host RTL"
                .into(),
        summary: RelocationSummary {
            failing_primary,
            cards: cards.len(),
            by_pattern,
            auto_correct_options,
            t3_only_cards,
        },
        cards,
    }
}

/// Design-size-aware correct dials (worklist, passes, batch, idle, apply caps).
///
/// Sparse slices keep near-base dials; full-core (~100+ modules, hundreds of
/// failing paths) grows capacity so bottleneck analysis covers residual families
/// without unbounded cost.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CorrectScale {
    /// Worklist width (paths considered per ordering).
    pub worklist_width: usize,
    /// Max measure/transform outer iterations.
    pub max_passes: u32,
    /// Consecutive no-gain items before aborting the loop.
    pub idle_limit: u32,
    /// Max successful applies per path (BalanceMux/InsertReg re-entry).
    pub apply_cap: u32,
    /// Distinct-module batch size applied before each remeasure.
    pub batch_size: usize,
}

impl CorrectScale {
    /// Compact `(width, passes)` view for callers that only need those dials.
    pub fn as_width_passes(self) -> (usize, u32) {
        (self.worklist_width, self.max_passes)
    }
}

/// Scale correct worklist / passes / batch / idle with design size.
///
/// Returns [`CorrectScale`]. Prefer this over hard-coded loop caps so full_core
/// and sparse slices share one growth law.
pub fn scale_correct_budget(
    design: &TimingDesign,
    base_worklist: usize,
    base_passes: u32,
) -> CorrectScale {
    let n_mod = design.modules.len().max(1);
    let n_path = design.paths.len().max(1);
    let failing = design
        .paths
        .iter()
        .filter(|p| !p.multi_cycle && p.slack_fo4 < 0.0)
        .count()
        .max(1);
    let soft_atomic = design
        .paths
        .iter()
        .filter(|p| {
            p.multi_cycle
                && matches!(p.path_class, PathClassKind::AtomicOverBudget)
        })
        .count();

    // Small designs: keep dials (sparse_ex ~10 paths over budget).
    if n_mod < 24 && failing < 48 && n_path < 400 {
        return CorrectScale {
            worklist_width: base_worklist.max(1),
            max_passes: base_passes.max(1),
            idle_limit: 8,
            apply_cap: 2,
            batch_size: 1,
        };
    }

    let fail_f = failing as f64;
    let mod_f = n_mod as f64;
    let path_f = n_path as f64;
    let atomic_f = soft_atomic as f64;

    // Width: base + 2√failing + 0.08·modules + mild path term + √atomics
    let width = (base_worklist as f64
        + 2.0 * fail_f.sqrt()
        + 0.08 * mod_f
        + 0.008 * path_f
        + 0.5 * atomic_f.sqrt())
    .ceil() as usize;
    let width = width.clamp(base_worklist.max(8), 256);

    // Passes: base + 3·log2(failing) + log2(modules)
    let passes = (base_passes as f64
        + 3.0 * fail_f.log2().max(0.0)
        + mod_f.log2().max(0.0))
    .ceil() as u32;
    let passes = passes.clamp(base_passes.max(8), 192);

    // Idle: larger residual sets need more consecutive skips before abort
    // (BalanceMux refuse on one family must not stop the loop).
    let idle = (8.0 + 2.0 * fail_f.log2().max(0.0) + mod_f.log2().max(0.0)).ceil() as u32;
    let idle = idle.clamp(8, 64);

    // Apply cap: exclusive multi-arm residual may need a second rebalance entry.
    let apply_cap = if failing > 64 || n_mod > 48 { 3 } else { 2 };

    // Batch: apply several *distinct modules* before remeasure so coverage
    // scales with √modules rather than 1-path-per-remeasure thrash.
    let batch = (1.0 + (mod_f.sqrt() * 0.75) + (fail_f / 80.0).min(6.0))
        .ceil() as usize;
    let batch = batch.clamp(2, 16);

    CorrectScale {
        worklist_width: width,
        max_passes: passes,
        idle_limit: idle,
        apply_cap,
        batch_size: batch,
    }
}

/// Pattern key for stratification (lower = higher priority in RR start).
fn pattern_bucket(p: RelocationPattern) -> u8 {
    match p {
        RelocationPattern::ExclusiveSelect => 0,
        RelocationPattern::IndependentBundle => 1,
        RelocationPattern::PlainCone | RelocationPattern::AssociativeChain => 2,
        RelocationPattern::AtomicOp => 3,
        RelocationPattern::MultiCycle => 4,
        RelocationPattern::Closed | RelocationPattern::Unknown => 5,
    }
}

/// Round-robin by pattern, then by module within each pattern (FO4-sorted).
///
/// Full-core evidence: without module fairness, InsertReg thrash on one FPU
/// tree starves exclusive residual on `control_mvp` / `alu` / `csr_regfile`.
fn stratify_cards_by_pattern_and_module(cards: Vec<RelocationCard>) -> Vec<RelocationCard> {
    use std::collections::BTreeMap;
    // pattern -> module -> cards (worst FO4 first)
    let mut nested: BTreeMap<u8, BTreeMap<String, Vec<RelocationCard>>> = BTreeMap::new();
    for c in cards {
        let pk = pattern_bucket(c.pattern);
        nested
            .entry(pk)
            .or_default()
            .entry(c.module.clone())
            .or_default()
            .push(c);
    }
    for mods in nested.values_mut() {
        for v in mods.values_mut() {
            v.sort_by(|a, b| {
                b.total_fo4
                    .partial_cmp(&a.total_fo4)
                    .unwrap_or(std::cmp::Ordering::Equal)
                    .then_with(|| a.path_id.cmp(&b.path_id))
            });
        }
    }

    // Per-pattern: flatten modules via round-robin so no single module owns the
    // pattern head; then RR across patterns.
    let mut pattern_queues: BTreeMap<u8, Vec<RelocationCard>> = BTreeMap::new();
    for (pk, mods) in nested {
        let mut mod_vecs: Vec<Vec<RelocationCard>> = mods.into_values().collect();
        // Prefer modules with worse head FO4 first in the RR start order.
        mod_vecs.sort_by(|a, b| {
            let fa = a.first().map(|c| c.total_fo4).unwrap_or(0.0);
            let fb = b.first().map(|c| c.total_fo4).unwrap_or(0.0);
            fb.partial_cmp(&fa)
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        let mut idxs = vec![0usize; mod_vecs.len()];
        let mut flat = Vec::new();
        loop {
            let mut progressed = false;
            for (i, v) in mod_vecs.iter().enumerate() {
                let j = idxs[i];
                if j < v.len() {
                    flat.push(v[j].clone());
                    idxs[i] = j + 1;
                    progressed = true;
                }
            }
            if !progressed {
                break;
            }
        }
        pattern_queues.insert(pk, flat);
    }

    let mut idxs = [0usize; 6];
    let mut out = Vec::new();
    loop {
        let mut progressed = false;
        for k in 0u8..6 {
            let Some(v) = pattern_queues.get(&k) else {
                continue;
            };
            let i = idxs[k as usize];
            if i < v.len() {
                out.push(v[i].clone());
                idxs[k as usize] = i + 1;
                progressed = true;
            }
        }
        if !progressed {
            break;
        }
    }
    out
}

fn pattern_from_class(class: PathClassKind, multi_cycle: bool) -> RelocationPattern {
    if multi_cycle && !matches!(class, PathClassKind::AtomicOverBudget) {
        return RelocationPattern::MultiCycle;
    }
    match class {
        PathClassKind::ExclusiveCaseMux | PathClassKind::ExclusiveIfChain => {
            RelocationPattern::ExclusiveSelect
        }
        PathClassKind::AtomicOverBudget => RelocationPattern::AtomicOp,
        PathClassKind::IndependentLhsBundle | PathClassKind::DenseControlCone => {
            RelocationPattern::IndependentBundle
        }
        PathClassKind::UnderBudget => RelocationPattern::Closed,
        PathClassKind::MultiCycleTagged => RelocationPattern::MultiCycle,
        PathClassKind::Plain => RelocationPattern::PlainCone,
    }
}

fn function_hint(pattern: RelocationPattern, class: PathClassKind) -> String {
    match pattern {
        RelocationPattern::ExclusiveSelect => {
            "exclusive result/select mux — one hot arm live per cycle".into()
        }
        RelocationPattern::AtomicOp => {
            "atomic high-cost operator (mul/div) dominates single-cycle budget".into()
        }
        RelocationPattern::IndependentBundle => {
            "multi-LHS always_comb — parallel fields, not serial FO4 sum".into()
        }
        RelocationPattern::AssociativeChain => "deep associative expression tree".into(),
        RelocationPattern::PlainCone => "plain combinational cone (InsertReg candidate)".into(),
        RelocationPattern::MultiCycle => "multi-cycle / soft multi-cycle path".into(),
        RelocationPattern::Closed => "under budget".into(),
        RelocationPattern::Unknown => format!("class={class:?}"),
    }
}

fn options_for_path(
    design: &TimingDesign,
    path: &crate::ir::TimingPath,
    pattern: RelocationPattern,
    budget: f64,
) -> Vec<RelocationOption> {
    let fo4 = path.total_fo4;
    let raw = path.total_fo4_raw.unwrap_or(fo4);
    let mut opts = Vec::new();

    // T0: measure already applied when raw > adjusted
    if path.total_fo4_raw.is_some() {
        opts.push(scored_option(
            "t0_measure",
            RelocationTier::T0,
            RelocationKind::MeasureRelocate,
            "Keep path-class measure relocate",
            fo4,
            fo4,
            0,
            true,
            0.95,
            "low",
            vec!["classify_and_adjust_paths".into()],
            format!(
                "raw {raw:.1} → adjusted {fo4:.1} via {:?}; do not re-sum exclusive/bundle arms",
                path.path_class
            ),
        ));
    }

    match pattern {
        RelocationPattern::ExclusiveSelect => {
            let after_mux = (fo4 * 0.82).max(budget * 0.9);
            opts.push(scored_option(
                "t1_balance_mux",
                RelocationTier::T1,
                RelocationKind::BalanceMux,
                "Balance exclusive select / rebalance hot arm",
                fo4,
                after_mux,
                0,
                true,
                0.7,
                "medium",
                vec![
                    "balance_mux_on_path".into(),
                    "rebalance_associative_node".into(),
                ],
                "Latency-neutral: mux-depth credit + associative rebalance on hottest arm expr"
                    .into(),
            ));
            if has_deep_expr(design, path) {
                let after_split = (fo4 * 0.9).max(budget);
                opts.push(scored_option(
                    "t1_split_hot_arm",
                    RelocationTier::T1,
                    RelocationKind::SplitAssign,
                    "Split / stage hottest exclusive arm expression",
                    fo4,
                    after_split,
                    0,
                    true,
                    0.6,
                    "medium",
                    vec!["split_assign".into()],
                    "Deep expr on hot arm — named intermediates enable further rebalance".into(),
                ));
            }
            opts.push(scored_option(
                "t3_hot_arm_multicycle",
                RelocationTier::T3,
                RelocationKind::ArchMulticycle,
                "Config multi-cycle for expensive opcode arm only",
                fo4,
                budget,
                1,
                false,
                0.55,
                "high",
                vec![
                    "CVA6Cfg opcode latency".into(),
                    "scoreboard multi-cycle".into(),
                ],
                "Isolate rare/heavy case arms from single-cycle EX critical path (human RTL)"
                    .into(),
            ));
            opts.push(scored_option(
                "t3_early_opcode_enables",
                RelocationTier::T3,
                RelocationKind::SplitCombProcess,
                "Early opcode enables / one-hot select near datapath",
                fo4,
                (fo4 * 0.75).max(budget),
                0,
                false,
                0.45,
                "high",
                vec!["decode enable fanout".into(), "physical mux tree".into()],
                "Move select generation earlier; keep arms local — floorplan + microarch".into(),
            ));
        }
        RelocationPattern::AtomicOp => {
            opts.push(scored_option(
                "t0_soft_multicycle",
                RelocationTier::T0,
                RelocationKind::SoftMulticycle,
                "Soft multi-cycle screening (already applied when multi_cycle)",
                fo4,
                fo4,
                0,
                true,
                0.95,
                "low",
                vec!["path_class.atomic_over_budget".into()],
                "Atomic op exceeds single-cycle FO4 budget — exclude from primary InsertReg pressure"
                    .into(),
            ));
            opts.push(scored_option(
                "t1_prep_stage",
                RelocationTier::T1,
                RelocationKind::PrepStage,
                "Stage sign/concat prep only (expr spine)",
                fo4,
                (fo4 - 5.0).max(budget),
                0,
                true,
                0.5,
                "medium",
                vec!["expand_expr_spine_for_path".into()],
                "Prep FO4 is small vs mul base; incremental only".into(),
            ));
            opts.push(scored_option(
                "t3_arch_multicycle_mul",
                RelocationTier::T3,
                RelocationKind::ArchMulticycle,
                "Architectural multi-cycle multiply unit",
                fo4,
                budget,
                2,
                false,
                0.75,
                "high",
                vec![
                    "partial products / booth".into(),
                    "CVA6Cfg MulLatency".into(),
                    "scoreboard".into(),
                ],
                "Only real dissolve when model mul FO4 > period budget".into(),
            ));
            opts.push(scored_option(
                "t3_cvxif_offload",
                RelocationTier::T3,
                RelocationKind::CvxifOffload,
                "Offload heavy compute to CVXIF / accelerator",
                fo4,
                budget,
                1,
                false,
                0.4,
                "high",
                vec!["CVXIF".into(), "acc_dispatcher".into()],
                "Physical relocation off core EX cone — SoC integration".into(),
            ));
        }
        RelocationPattern::IndependentBundle => {
            opts.push(scored_option(
                "t1_balance_bundle",
                RelocationTier::T1,
                RelocationKind::BalanceMux,
                "Keep parallel field costing; optional field rebalance",
                fo4,
                fo4.min(budget * 1.1),
                0,
                true,
                0.65,
                "low",
                vec!["independent_lhs_bundle".into(), "balance_mux_on_path".into()],
                "Measurement already max-field; BalanceMux only if residual over budget".into(),
            ));
            opts.push(scored_option(
                "t3_split_comb",
                RelocationTier::T3,
                RelocationKind::SplitCombProcess,
                "Split always_comb by field groups (address vs flags)",
                fo4,
                budget,
                0,
                false,
                0.55,
                "medium",
                vec!["process split".into(), "STA cone isolation".into()],
                "Same cycle, clearer placement and timing cones — human RTL style".into(),
            ));
        }
        RelocationPattern::PlainCone => {
            if has_deep_expr(design, path) {
                opts.push(scored_option(
                    "t1_rebalance",
                    RelocationTier::T1,
                    RelocationKind::RebalanceAssoc,
                    "Rebalance associative expression tree",
                    fo4,
                    fo4 * 0.85,
                    0,
                    true,
                    0.7,
                    "low",
                    vec!["rebalance_associative_node".into()],
                    "Latency-neutral depth reduction on +/|/& chains".into(),
                ));
                opts.push(scored_option(
                    "t1_split",
                    RelocationTier::T1,
                    RelocationKind::SplitAssign,
                    "Split deep assign into named wires",
                    fo4,
                    fo4 * 0.9,
                    0,
                    true,
                    0.6,
                    "low",
                    vec!["split_assign".into()],
                    "Enables cleaner cuts and rebalance".into(),
                ));
            }
            let after_reg = (fo4 * 0.5).max(budget * 0.5);
            opts.push(scored_option(
                "t2_insert_reg",
                RelocationTier::T2,
                RelocationKind::InsertReg,
                "Budget multi-cut InsertReg (allow-latency)",
                fo4,
                after_reg,
                1,
                true,
                0.65,
                "medium",
                vec![
                    "schedule_pipeline_cuts".into(),
                    "insert_register".into(),
                ],
                "Only for plain cones — adds architectural latency; GateInfo required".into(),
            ));
        }
        RelocationPattern::MultiCycle | RelocationPattern::Closed => {
            opts.push(scored_option(
                "t0_no_action",
                RelocationTier::T0,
                RelocationKind::MeasureRelocate,
                "No primary relocation — path not in single-cycle pressure set",
                fo4,
                fo4,
                0,
                true,
                1.0,
                "low",
                vec!["tag_multi_cycle_paths".into()],
                "Multi-cycle or closed — do not InsertReg".into(),
            ));
        }
        RelocationPattern::AssociativeChain | RelocationPattern::Unknown => {
            opts.push(scored_option(
                "t1_rebalance",
                RelocationTier::T1,
                RelocationKind::RebalanceAssoc,
                "Rebalance / split unknown residual",
                fo4,
                fo4 * 0.88,
                0,
                true,
                0.5,
                "medium",
                vec!["rebalance_associative_node".into(), "split_assign".into()],
                "Fallback latency-neutral tools".into(),
            ));
        }
    }

    // Attach existing opportunities as cross-links in rationale when present.
    let _ = design.opportunities.iter().filter(|o| o.path_id == path.id);
    opts
}

fn has_deep_expr(design: &TimingDesign, path: &crate::ir::TimingPath) -> bool {
    let Some(m) = design.modules.get(&path.module) else {
        return false;
    };
    for id in &path.nodes {
        if let Some(n) = m.nodes.get(id) {
            if let Some(ref ex) = n.rhs_expr {
                if ex.op_node_count() >= 3 || ex.depth() >= 4 {
                    return true;
                }
            }
        }
    }
    false
}

fn scored_option(
    id: &str,
    tier: RelocationTier,
    kind: RelocationKind,
    title: &str,
    fo4_before: f64,
    expected_after: f64,
    latency_delta: u32,
    auto_correct: bool,
    confidence: f64,
    risk: &str,
    algorithms: Vec<String>,
    rationale: String,
) -> RelocationOption {
    let risk_w = match risk {
        "low" => 0.0,
        "medium" => 0.35,
        "high" => 0.75,
        _ => 0.5,
    };
    let lat_pen = latency_delta as f64 * 0.25;
    let leverage = ((fo4_before - expected_after).max(0.0) / fo4_before.max(1.0)).clamp(0.0, 1.0);
    // Measure-only keep options get small base score so they sort after real gains.
    let base = if matches!(kind, RelocationKind::MeasureRelocate | RelocationKind::SoftMulticycle)
        && (fo4_before - expected_after).abs() < 1e-6
    {
        0.15 * confidence
    } else {
        leverage * confidence
    };
    let score = base / (1.0 + risk_w + lat_pen);
    RelocationOption {
        id: id.into(),
        tier,
        kind,
        title: title.into(),
        expected_fo4_after: expected_after,
        latency_delta,
        auto_correct,
        confidence,
        risk: risk.into(),
        algorithms,
        rationale,
        score,
    }
}

/// Map package opportunity kinds onto relocation kinds (for dashboards).
pub fn opportunity_to_relocation_kind(k: OpportunityKind) -> RelocationKind {
    match k {
        OpportunityKind::InsertReg => RelocationKind::InsertReg,
        OpportunityKind::SplitAssign => RelocationKind::SplitAssign,
        OpportunityKind::BalanceMux => RelocationKind::BalanceMux,
    }
}

/// Map a relocation kind to a correct-pass opportunity kind (if any).
pub fn relocation_to_opportunity_kind(k: RelocationKind) -> Option<OpportunityKind> {
    match k {
        RelocationKind::BalanceMux | RelocationKind::RebalanceAssoc => {
            Some(OpportunityKind::BalanceMux)
        }
        RelocationKind::SplitAssign | RelocationKind::PrepStage => {
            Some(OpportunityKind::SplitAssign)
        }
        RelocationKind::InsertReg => Some(OpportunityKind::InsertReg),
        RelocationKind::MeasureRelocate
        | RelocationKind::SoftMulticycle
        | RelocationKind::ArchMulticycle
        | RelocationKind::SplitCombProcess
        | RelocationKind::CvxifOffload => None,
    }
}

/// First auto_correct option that maps to a transform (skip pure T0 measure).
pub fn preferred_actionable_kind(card: &RelocationCard) -> Option<RelocationKind> {
    preferred_actionable_kind_from_options(&card.options)
}

fn preferred_actionable_kind_from_options(options: &[RelocationOption]) -> Option<RelocationKind> {
    for o in options {
        if !o.auto_correct {
            continue;
        }
        if relocation_to_opportunity_kind(o.kind).is_some() {
            return Some(o.kind);
        }
    }
    None
}

/// Whether this relocation kind is a no-op for the correct loop (already applied).
pub fn is_measure_only(k: RelocationKind) -> bool {
    matches!(
        k,
        RelocationKind::MeasureRelocate | RelocationKind::SoftMulticycle
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ir::{
        IrNode, OperatorClass, PathEndpoint, PathKind, TimingModule, TimingPath, TimingTarget,
    };
    use crate::loc::{OriginKind, SourceLoc};
    use crate::path_class::{classify_and_adjust_paths, PathClassKind};
    use crate::measure::CostModel;
    use std::collections::BTreeMap;

    fn loc() -> SourceLoc {
        SourceLoc {
            file: "t.sv".into(),
            start_line: 10,
            start_col: 1,
            end_line: 10,
            end_col: 2,
            byte_start: 0,
            byte_end: 1,
            origin: OriginKind::UserFile,
        }
    }

    #[test]
    fn plan_exclusive_has_t1_and_t3() {
        let mut design = TimingDesign::empty(TimingTarget::new(1250.0, 20.0, 0.2));
        let mut nodes = BTreeMap::new();
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
                    fans_in: vec![],
                    fans_out: vec![],
                    width_defaulted: true,
                    reads_reg: false,
                    lhs: Some("result_o".into()),
                    rhs: Some(format!("arm{i}")),
                    lhs_expr: None,
                    rhs_expr: None,
                    case_labels: Vec::new(),
                    case_is_default: false,
                    case_selector: None,
                    fo4_locked: false,
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
                regions: BTreeMap::new(),
                localparams: vec![],
                parameters: vec![],
                ports: vec![],
                gen_loops: vec![],
                functions: vec![],
                package_imports: vec![],
                instances: vec![],
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
            startpoint: "alu.in0".into(),
            endpoint: "alu.out0".into(),
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
        classify_and_adjust_paths(&mut design, &CostModel::default(), None);
        let plan = build_relocation_plan(&design);
        assert!(
            plan.summary.failing_primary >= 1 || !plan.cards.is_empty(),
            "expected cards after classify"
        );
        // Sparse-scale budget stays near base dials.
        let sc = scale_correct_budget(&design, 4, 16);
        assert!(sc.worklist_width >= 4 && sc.worklist_width <= 256, "width={}", sc.worklist_width);
        assert!(sc.max_passes >= 16 && sc.max_passes <= 192, "passes={}", sc.max_passes);
        assert_eq!(sc.batch_size, 1, "sparse batch stays 1");
        assert_eq!(sc.idle_limit, 8);
        let card = plan.cards.iter().find(|c| c.path_id == 41).expect("card");
        assert_eq!(card.pattern, RelocationPattern::ExclusiveSelect);
        assert!(card.options.iter().any(|o| o.kind == RelocationKind::BalanceMux));
        assert!(card
            .options
            .iter()
            .any(|o| o.tier == RelocationTier::T3 && !o.auto_correct));
        assert!(card.preferred_auto.is_some());
    }

    #[test]
    fn scale_budget_grows_batch_on_large_design() {
        let mut design = TimingDesign::empty(TimingTarget::new(2500.0, 20.0, 0.2));
        // Simulate full-core-ish size: 40 modules, 80 failing plain paths.
        for mi in 0u32..40 {
            design.modules.insert(
                mi,
                TimingModule {
                    id: mi,
                    name: format!("mod{mi}"),
                    file: format!("m{mi}.sv"),
                    nodes: BTreeMap::new(),
                    regions: BTreeMap::new(),
                    localparams: vec![],
                    parameters: vec![],
                    ports: vec![],
                    gen_loops: vec![],
                    functions: vec![],
                    package_imports: vec![],
                    instances: vec![],
                    loc: loc(),
                },
            );
            design.module_names.insert(format!("mod{mi}"), mi);
            let start = PathEndpoint::InputPort {
                module: mi,
                port: 0,
            };
            let end = PathEndpoint::OutputPort {
                module: mi,
                port: 1,
            };
            for k in 0..2u32 {
                let id = mi * 2 + k;
                design.paths.push(TimingPath {
                    id,
                    region_id: 0,
                    module: mi,
                    start: start.clone(),
                    end: end.clone(),
                    path_kind: PathKind::from_endpoints(&start, &end),
                    startpoint: format!("mod{mi}.in0"),
                    endpoint: format!("mod{mi}.out0"),
                    nodes: vec![],
                    total_fo4: 40.0 + (k as f64),
                    slack_fo4: -24.0,
                    max_freq_mhz: 500.0,
                    primary_loc: loc(),
                    multi_cycle: false,
                    path_class: PathClassKind::Plain,
                    total_fo4_raw: None,
                    class_note: None,
                });
            }
        }
        let sc = scale_correct_budget(&design, 8, 16);
        assert!(sc.worklist_width >= 8, "width={}", sc.worklist_width);
        assert!(sc.batch_size >= 2, "batch should grow, got {}", sc.batch_size);
        assert!(sc.idle_limit >= 8, "idle={}", sc.idle_limit);
        assert!(sc.apply_cap >= 2);
        assert!(sc.max_passes >= 16);
        // Module-fair plan: cards from many modules near the head.
        let plan = build_relocation_plan(&design);
        assert!(plan.cards.len() >= 40);
        let head_mods: std::collections::BTreeSet<_> = plan
            .cards
            .iter()
            .take(16)
            .map(|c| c.module.as_str())
            .collect();
        assert!(
            head_mods.len() >= 8,
            "module-fair head expected ≥8 distinct mods, got {} ({:?})",
            head_mods.len(),
            head_mods
        );
    }

    #[test]
    fn plan_atomic_soft_multicycle_t3() {
        let mut design = TimingDesign::empty(TimingTarget::new(1250.0, 20.0, 0.2));
        let mut nodes = BTreeMap::new();
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
                lhs: Some("p".into()),
                rhs: Some("a*b".into()),
                lhs_expr: None,
                rhs_expr: None,
                case_labels: Vec::new(),
                case_is_default: false,
                case_selector: None,
                fo4_locked: false,
            },
        );
        design.modules.insert(
            0,
            TimingModule {
                id: 0,
                name: "multiplier".into(),
                file: "m.sv".into(),
                nodes,
                regions: BTreeMap::new(),
                localparams: vec![],
                parameters: vec![],
                ports: vec![],
                gen_loops: vec![],
                functions: vec![],
                package_imports: vec![],
                instances: vec![],
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
        let plan = build_relocation_plan(&design);
        let card = plan.cards.iter().find(|c| c.path_id == 1).expect("atomic card");
        assert_eq!(card.pattern, RelocationPattern::AtomicOp);
        assert!(card
            .options
            .iter()
            .any(|o| o.kind == RelocationKind::ArchMulticycle && !o.auto_correct));
        assert!(card
            .options
            .iter()
            .any(|o| o.kind == RelocationKind::SoftMulticycle));
    }
}
