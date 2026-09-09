// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Pass context, policy, and multi-pass driver.

use std::collections::{BTreeMap, BTreeSet};

use thiserror::Error;

use serde_json::{json, Map, Value};

use sv_timing_core::{
    admits_insert_reg, attribute_costs, build_relocation_plan, cone_lane, exception_policy,
    is_latency_neutral_kind, is_shallow_over_budget, path_span_lhs_all_cut, plan_from_design,
    rank_paths_by_slack, remeasure_path_slacks, s4_sibling_span_pending, span_family_lhs_on_path,
    suggest_opportunities, AlgoTrace, ConeLane, CostModel, GateInfo, NameTable, Opportunity,
    OpportunityKind, PathId, RankedPaths, RelocationPlan, TimingDesign, TimingPath,
};

use crate::edit::EditTrace;
use crate::pipeline::{insert_register, select_pipeline_cuts, split_assign};
use crate::worklist::{order_worklist_with_plan, WorklistPolicy};

/// Transform error.
#[derive(Debug, Error)]
pub enum TransformError {
    /// Module not on allowlist.
    #[error("module not allowlisted: {0}")]
    ModuleNotAllowlisted(String),
    /// InsertReg without --allow-latency.
    #[error("latency-changing transform requires allow_latency")]
    LatencyNotAllowed,
    /// Missing clock/edge for new flop.
    #[error("incomplete GateInfo (need clock + edge)")]
    IncompleteGateInfo,
    /// Bad opportunity kind / args.
    #[error("invalid opportunity: {0}")]
    InvalidOpportunity(String),
    /// Max passes exhausted.
    #[error("max passes reached ({0})")]
    MaxPasses(u32),
}

/// Result alias.
pub type TransformResult<T> = Result<T, TransformError>;

/// Policy gates for auto-correct (mirrors DESIGN.md).
#[derive(Debug, Clone)]
pub struct PassPolicy {
    /// Master enable.
    pub correct_enabled: bool,
    /// Module allowlist (empty ⇒ refuse all).
    pub correct_allow_modules: Vec<String>,
    /// Allow InsertReg.
    pub allow_latency: bool,
    /// Max measure/transform iterations (mirrors `opt.max_passes`).
    pub max_passes: u32,
    /// Refuse path prefixes (normalized `/`).
    pub refuse_path_prefixes: Vec<String>,
    /// Worklist size.
    pub worklist: WorklistPolicy,
    /// Resolved optimization dials (`-O` surface).
    pub opt: sv_timing_core::OptOptions,
    /// Credit IR FO4 / rewire paths only when emit will actually rewrite origin
    /// (`--real-cut-feeds` / `--emit-balance-mux-rtl`). Lean soak emit is a
    /// zero-feed sidecar — PASS-STRATEGY: do not book 304.5→96.5 that the
    /// emitted SV does not contain.
    pub emit_structural: bool,
}

impl Default for PassPolicy {
    fn default() -> Self {
        Self {
            correct_enabled: false,
            correct_allow_modules: Vec::new(),
            allow_latency: false,
            max_passes: 8,
            refuse_path_prefixes: Vec::new(),
            worklist: WorklistPolicy::default(),
            opt: sv_timing_core::OptOptions::default(),
            emit_structural: true,
        }
    }
}

impl PassPolicy {
    /// Strict unit-test policy (disabled correct, empty allowlist).
    pub fn strict_test() -> Self {
        Self::default()
    }

    /// Build a policy from resolved dials, keeping safety gates explicit.
    ///
    /// `max_passes` and the worklist width come from the dials; the allowlist and
    /// `allow_latency` must still be supplied by the caller (a level never grants them).
    pub fn from_opt(
        opt: sv_timing_core::OptOptions,
        allow_modules: Vec<String>,
        allow_latency: bool,
    ) -> Self {
        Self {
            correct_enabled: !allow_modules.is_empty() && opt.max_passes > 0,
            correct_allow_modules: allow_modules,
            allow_latency,
            max_passes: opt.max_passes,
            refuse_path_prefixes: Vec::new(),
            worklist: WorklistPolicy {
                max_items: opt.worklist_width.max(1),
                skip_multi_cycle: true,
                use_relocation_plan: true,
            },
            opt,
            // Library default: tests exercise IR rewires. CLI overwrites from
            // `--real-cut-feeds` / `--emit-balance-mux-rtl` (lean soak = false).
            emit_structural: true,
        }
    }

    /// Apply dials onto an existing policy (keeps gates as configured).
    pub fn with_opt(mut self, opt: sv_timing_core::OptOptions) -> Self {
        self.max_passes = opt.max_passes;
        self.worklist.max_items = opt.worklist_width.max(1);
        self.opt = opt;
        self
    }

    /// Whether module name is allowlisted.
    pub fn module_allowed(&self, name: &str) -> bool {
        !self.correct_allow_modules.is_empty()
            && self.correct_allow_modules.iter().any(|m| m == name)
    }
}

/// Shared bag for multi-pass algorithms.
#[derive(Debug)]
pub struct PassContext {
    /// Timing design IR.
    pub design: TimingDesign,
    /// Name allocator.
    pub names: NameTable,
    /// Edit history.
    pub trace: EditTrace,
    /// Policy.
    pub policy: PassPolicy,
    /// Cost model.
    pub cost_model: CostModel,
    /// Last ranked paths.
    pub ranked: RankedPaths,
    /// Active module for naming scope.
    pub active_module_name: String,
    /// Default gate for InsertReg when region gate incomplete (tests / host inject).
    pub default_gate: Option<GateInfo>,
    /// When true, synthesize a posedge clk gate if none provided (CLI `--assume-clk`).
    pub assume_clk: bool,
    /// IR needs remeasure.
    pub pending_ir_dirty: bool,
    /// Pass counter.
    pub pass_index: u32,
    /// Latest relocation plan (drives worklist preferred_auto).
    pub relocation: Option<RelocationPlan>,
    /// Paths that already received BalanceMux credit (once per correct run).
    pub balance_mux_done: BTreeSet<PathId>,
    /// Sticky BalanceMux adjusted FO4 (remeasure / attribute_costs must not undo).
    pub balance_mux_credit: BTreeMap<PathId, f64>,
    /// Optional JSONL algorithm trace (`--trace-log`).
    pub algo_trace: AlgoTrace,
    /// InsertReg applies per module this run (cap spray on one FPU tree).
    pub insert_reg_by_module: BTreeMap<String, u32>,
}

impl PassContext {
    /// New context after analyze.
    pub fn new(design: TimingDesign, names: NameTable, policy: PassPolicy) -> Self {
        let active = policy
            .correct_allow_modules
            .first()
            .cloned()
            .or_else(|| design.modules.values().next().map(|m| m.name.clone()))
            .unwrap_or_default();
        Self {
            design,
            names,
            trace: EditTrace::new(),
            policy,
            cost_model: CostModel::default(),
            ranked: RankedPaths::default(),
            active_module_name: active,
            default_gate: None,
            assume_clk: false,
            pending_ir_dirty: false,
            pass_index: 0,
            balance_mux_done: BTreeSet::new(),
            balance_mux_credit: BTreeMap::new(),
            relocation: None,
            algo_trace: AlgoTrace::disabled(),
            insert_reg_by_module: BTreeMap::new(),
        }
    }

    /// Attach a JSONL algorithm tracer.
    pub fn with_algo_trace(mut self, trace: AlgoTrace) -> Self {
        self.algo_trace = trace;
        self
    }

    fn log_algo(&self, kind: &str, fields: Map<String, Value>) {
        self.algo_trace.emit(kind, self.pass_index, fields);
    }

    fn log_measure(&self, tag: &str) {
        if !self.algo_trace.is_enabled() {
            return;
        }
        let failing = self
            .design
            .paths
            .iter()
            .filter(|p| !p.multi_cycle && p.slack_fo4 < 0.0)
            .count();
        let primary_fo4 = self.ranked.primary.first().map(|p| p.total_fo4);
        let worst_all = self
            .design
            .paths
            .iter()
            .map(|p| p.total_fo4)
            .fold(0.0_f64, f64::max);
        let mut by_class: BTreeMap<String, u32> = BTreeMap::new();
        for p in &self.design.paths {
            *by_class.entry(format!("{:?}", p.path_class)).or_insert(0) += 1;
        }
        let mut fields = AlgoTrace::kv([
            ("tag", json!(tag)),
            ("modules", json!(self.design.modules.len())),
            ("paths", json!(self.design.paths.len())),
            ("failing_primary", json!(failing)),
            ("primary_fo4", json!(primary_fo4)),
            ("worst_all_fo4", json!(worst_all)),
            ("budget_fo4", json!(self.design.target.budget_fo4)),
            ("by_class", json!(by_class)),
        ]);
        if let Some(plan) = &self.relocation {
            fields.insert("reloc_cards".into(), json!(plan.summary.cards));
            fields.insert(
                "reloc_t3_only".into(),
                json!(plan.summary.t3_only_cards),
            );
            fields.insert(
                "reloc_by_pattern".into(),
                json!(plan.summary.by_pattern),
            );
        }
        self.log_algo("measure", fields);
    }

    /// Measure: attribute costs, rank, opportunities, relocation plan.
    pub fn measure(&mut self) {
        attribute_costs(&mut self.design, &self.cost_model);
        remeasure_path_slacks(&mut self.design);
        // Re-apply sticky BalanceMux credits wiped by full re-attribute/classify.
        self.reapply_balance_mux_credits();
        self.design.opportunities = suggest_opportunities(&self.design);
        self.ranked = rank_paths_by_slack(&self.design.paths, &self.design.target);
        self.relocation = Some(build_relocation_plan(&self.design));
        self.pending_ir_dirty = false;
        self.log_measure("after_attribute");
    }

    /// Keep once-applied BalanceMux FO4 across measure cycles.
    fn reapply_balance_mux_credits(&mut self) {
        if self.balance_mux_credit.is_empty() {
            return;
        }
        let budget = self.design.target.budget_fo4;
        let fo4_ps = self.design.target.fo4_ps;
        let margin = self.design.target.budget_margin;
        for (pid, &credited) in &self.balance_mux_credit {
            if let Some(path) = self.design.paths.iter_mut().find(|p| p.id == *pid) {
                // Only improve (never inflate) relative to fresh classify.
                if credited + 1e-9 < path.total_fo4 {
                    path.total_fo4 = credited;
                    path.slack_fo4 = budget - credited;
                    path.max_freq_mhz =
                        sv_timing_core::max_freq_mhz_for_path(credited, fo4_ps, margin);
                    let note = format!(
                        "balance_mux sticky credit → {credited:.1} FO4; {}",
                        path.class_note.clone().unwrap_or_default()
                    );
                    path.class_note = Some(note);
                }
            }
            for ex in &mut self.design.path_exceptions {
                if ex.path_id == *pid && credited + 1e-9 < ex.adjusted_fo4 {
                    ex.adjusted_fo4 = credited;
                }
            }
        }
    }
}

/// Run bounded correct loop on an **already-analyzed** design.
///
/// Per pass: measure → relocation plan → worklist (preferred_auto) →
/// BalanceMux / Split / InsertReg → remeasure.
pub fn run_correct_passes(mut ctx: PassContext) -> TransformResult<PassContext> {
    if !ctx.policy.correct_enabled {
        return Ok(ctx);
    }
    if ctx.policy.correct_allow_modules.is_empty() {
        return Ok(ctx);
    }

    // Keep only allowlisted modules' paths/opportunities influence via active name.
    if ctx.active_module_name.is_empty() {
        ctx.active_module_name = ctx
            .policy
            .correct_allow_modules
            .first()
            .cloned()
            .unwrap_or_default();
    }

    ctx.algo_trace.emit(
        "run.start",
        0,
        AlgoTrace::kv([
            ("target_mhz", json!(ctx.design.target.target_mhz)),
            ("budget_fo4", json!(ctx.design.target.budget_fo4)),
            ("fo4_ps", json!(ctx.design.target.fo4_ps)),
            ("allow_latency", json!(ctx.policy.allow_latency)),
            ("emit_structural", json!(ctx.policy.emit_structural)),
            ("opt", json!(ctx.policy.opt.summary())),
            ("allow_modules", json!(ctx.policy.correct_allow_modules.len())),
        ]),
    );
    ctx.measure();
    let plan = plan_from_design(&ctx.design);
    ctx.design.pass_plan = plan.clone();
    ctx.algo_trace.emit(
        "pass_plan",
        0,
        AlgoTrace::kv([
            ("abort", json!(plan.abort_correct)),
            ("artifacts", json!(plan.artifacts.len())),
            ("by_pattern", json!(plan.by_pattern)),
            ("rationale", json!(plan.rationale)),
        ]),
    );
    if plan.abort_correct {
        // PASS-STRATEGY §4: artifacts are a measurement bug. Do not spend
        // InsertReg/BalanceMux on logic that does not exist (audit-strict-v4
        // spent hundreds of edits for a 0.0 emitted delta).
        ctx.algo_trace.emit(
            "run.stop",
            0,
            AlgoTrace::kv([("reason", json!("artifacts_p1_p2"))]),
        );
        return Ok(ctx);
    }
    // Per-module algorithm-set cleanliness (always_ff / always_comb density,
    // timing pass/fail, aggressiveness penalty). Factorize still runs for
    // always_ff — it is review-only and keeps the clock-aware scratch.
    if ctx.algo_trace.is_enabled() {
        let picks: Vec<Value> = ctx
            .design
            .module_cleanliness
            .values()
            .take(24)
            .map(|s| {
                json!({
                    "module": s.module,
                    "set": s.chosen.as_str(),
                    "C": s.cleanliness,
                    "pass": s.timing_pass,
                    "D_ff": s.always_ff_density,
                    "D_comb": s.always_comb_density,
                })
            })
            .collect();
        ctx.algo_trace.emit(
            "cleanliness",
            0,
            AlgoTrace::kv([
                ("modules", json!(ctx.design.module_cleanliness.len())),
                ("picks", json!(picks)),
            ]),
        );
    }
    // Clock-aware always_ff factorize: ParallelScratch cycle bars on clk_i
    // produce review-only SV comments + OpenSTA report_timing seeds.
    crate::factor_always_ff::factor_always_ff_regions(&mut ctx);
    // Scale worklist / passes / batch / idle with design size (full-core soaks).
    let scale = sv_timing_core::scale_correct_budget(
        &ctx.design,
        ctx.policy.worklist.max_items,
        ctx.policy.max_passes,
    );
    ctx.policy.worklist.max_items = scale.worklist_width;
    ctx.policy.max_passes = scale.max_passes;
    let idle_limit = scale.idle_limit;
    let apply_cap_default = scale.apply_cap;
    let batch_size = scale.batch_size.max(1);
    ctx.algo_trace.emit(
        "scale",
        0,
        AlgoTrace::kv([
            ("worklist_width", json!(scale.worklist_width)),
            ("max_passes", json!(scale.max_passes)),
            ("idle_limit", json!(idle_limit)),
            ("apply_cap", json!(apply_cap_default)),
            ("batch_size", json!(batch_size)),
        ]),
    );
    // Paths already tried without gain this session — skip so residual work continues.
    let mut skipped: std::collections::BTreeSet<sv_timing_core::PathId> =
        std::collections::BTreeSet::new();
    let mut refuse_by_reason: BTreeMap<String, u32> = BTreeMap::new();
    let mut refuse_by_class: BTreeMap<String, u32> = BTreeMap::new();
    // Successful applies per path (cap re-entry so prep_stage cannot thrash).
    let mut applied_count: std::collections::BTreeMap<sv_timing_core::PathId, u32> =
        std::collections::BTreeMap::new();
    let mut idle_streak = 0u32;
    // PASS-STRATEGY §5–§6: S3 latency-neutral to fixpoint, then S4 InsertReg.
    // Stop a stage after 2 consecutive passes with Δprimary < min_gain (the
    // audit-strict-v4 full_core run applied 192 edits while primary stayed flat).
    let mut stage_s4 = false;
    let mut flat_streak = 0u32;
    let mut last_primary = ctx
        .ranked
        .primary
        .first()
        .map(|p| p.total_fo4)
        .unwrap_or(0.0);
    let min_gain = ctx.policy.opt.min_gain_fo4.max(0.5);
    // Uncut generate-if `*_span`/`*_end` after 2-flat (gemm a_span/b_span).
    // v29 re-cut c_span/c_end; skip those idents. Extra passes InsertReg only
    // uncut spans so policy_subcode keeps its diverse T2 (v29 starved it).
    let mut cut_span_lhs: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let mut sibling_extra = 0u32;
    let mut extra_uncut_span = false;
    const SIBLING_EXTRA_CAP: u32 = 2;
    // PASS-STRATEGY §6.2: S3 must not consume S4's budget.
    let stage_budget = (ctx.policy.max_passes / 2).max(1);
    let mut stage_passes = 0u32;
    ctx.log_algo(
        "scale.stages",
        AlgoTrace::kv([("stage_budget", json!(stage_budget))]),
    );
    for _ in 0..ctx.policy.max_passes {
        ctx.pass_index += 1;
        stage_passes += 1;
        ctx.log_algo(
            "pass.start",
            AlgoTrace::kv([
                ("idle_streak", json!(idle_streak)),
                ("skipped", json!(skipped.len())),
                ("edits", json!(ctx.trace.records.len())),
                ("stage_s4", json!(stage_s4)),
                ("stage_passes", json!(stage_passes)),
            ]),
        );
        let work = order_worklist_with_plan(
            &ctx.ranked,
            &ctx.design.opportunities,
            &ctx.policy.worklist,
            ctx.relocation.as_ref(),
        );
        let mut work: Vec<_> = work
            .into_iter()
            .filter_map(|mut w| {
                let Some(opp) = w.opportunity.as_ref() else {
                    return None;
                };
                // Lean sidecar does not rewrite origin. Skip every IR FO4
                // mutation (InsertReg, BalanceMux, SplitAssign, rebalance).
                if !ctx.policy.emit_structural {
                    return None;
                }
                if stage_s4 {
                    let path = ctx.design.paths.iter().find(|p| p.id == w.path_id)?;
                    // Resilient datapath may still carry a P10 class_note from
                    // sharing an always_ff with a status pulse (gemm 144-node).
                    // Exception policy decides; admits_insert_reg is the default.
                    let resilient = exception_policy(&ctx.design, path)
                        .is_some_and(|e| e.admit_insert_reg);
                    if !resilient && !admits_insert_reg(path) {
                        return None;
                    }
                    if opp.kind == OpportunityKind::InsertReg || resilient {
                        let mod_name = ctx
                            .design
                            .modules
                            .get(&path.module)
                            .map(|m| m.name.as_str())
                            .unwrap_or("");
                        let empty = BTreeSet::new();
                        let cut = cut_span_lhs.get(mod_name).unwrap_or(&empty);
                        if path_span_lhs_all_cut(&ctx.design, path, cut) {
                            return None;
                        }
                        if extra_uncut_span && !s4_sibling_span_pending(&ctx.design, path)
                        {
                            return None;
                        }
                        if opp.kind != OpportunityKind::InsertReg {
                            w.opportunity = Some(insert_reg_for_path(&ctx.design, path));
                            w.relocation_option_id = Some("t2_insert_reg".into());
                        }
                        return Some(w);
                    }
                    return None;
                }
                is_latency_neutral_kind(opp.kind).then_some(w)
            })
            .collect();
        if stage_s4 {
            // Resilient P8-shaped cones (gemm) may have been T1-first in the
            // relocation card and truncated off the worklist. Re-attach them.
            let have: BTreeSet<PathId> = work.iter().map(|w| w.path_id).collect();
            for p in &ctx.design.paths {
                if have.contains(&p.id) || p.slack_fo4 >= 0.0 {
                    continue;
                }
                if !exception_policy(&ctx.design, p).is_some_and(|e| e.admit_insert_reg) {
                    continue;
                }
                let mod_name = ctx
                    .design
                    .modules
                    .get(&p.module)
                    .map(|m| m.name.as_str())
                    .unwrap_or("");
                let empty = BTreeSet::new();
                let cut = cut_span_lhs.get(mod_name).unwrap_or(&empty);
                if path_span_lhs_all_cut(&ctx.design, p, cut) {
                    continue;
                }
                if extra_uncut_span && !s4_sibling_span_pending(&ctx.design, p) {
                    continue;
                }
                work.push(crate::worklist::WorkItem {
                    path_id: p.id,
                    slack_fo4: p.slack_fo4,
                    total_fo4: p.total_fo4,
                    opportunity: Some(insert_reg_for_path(&ctx.design, p)),
                    file: p.primary_loc.file.clone(),
                    line: p.primary_loc.start_line,
                    relocation_option_id: Some("t2_insert_reg".into()),
                });
            }
            // Resilient exceptions first (the APU gemm 161.5 cone), then P6
            // shallow, then remaining monsters. audit-gemm-rcf S4 sorted
            // shallow-first and never reached the 144-node primary.
            let budget = ctx.design.target.budget_fo4;
            work.sort_by(|a, b| {
                let resilient = |id| {
                    ctx.design
                        .paths
                        .iter()
                        .find(|p| p.id == id)
                        .is_some_and(|p| {
                            exception_policy(&ctx.design, p).is_some_and(|e| e.admit_insert_reg)
                        })
                };
                let shallow = |id| {
                    ctx.design
                        .paths
                        .iter()
                        .find(|p| p.id == id)
                        .map(|p| is_shallow_over_budget(p, budget))
                        .unwrap_or(false)
                };
                match (resilient(a.path_id), resilient(b.path_id)) {
                    (true, false) => std::cmp::Ordering::Less,
                    (false, true) => std::cmp::Ordering::Greater,
                    _ => match (shallow(a.path_id), shallow(b.path_id)) {
                        (true, false) => std::cmp::Ordering::Less,
                        (false, true) => std::cmp::Ordering::Greater,
                        _ => a
                            .slack_fo4
                            .partial_cmp(&b.slack_fo4)
                            .unwrap_or(std::cmp::Ordering::Equal)
                            .then(a.path_id.cmp(&b.path_id)),
                    },
                }
            });
        }
        if work.is_empty() && !stage_s4 && ctx.policy.allow_latency {
            if !ctx.policy.emit_structural {
                ctx.log_algo(
                    "run.stop",
                    AlgoTrace::kv([("reason", json!("lean_emit_skip_s4"))]),
                );
                break;
            }
            stage_s4 = true;
            stage_passes = 0;
            flat_streak = 0;
            ctx.log_algo(
                "stage.s4",
                AlgoTrace::kv([("reason", json!("s3_empty"))]),
            );
            continue;
        }
        if ctx.algo_trace.is_enabled() {
            let preview: Vec<Value> = work
                .iter()
                .take(16)
                .map(|w| {
                    json!({
                        "path_id": w.path_id,
                        "fo4": w.total_fo4,
                        "slack": w.slack_fo4,
                        "reloc": w.relocation_option_id,
                        "opp": w.opportunity.as_ref().map(|o| format!("{:?}", o.kind)),
                    })
                })
                .collect();
            ctx.log_algo(
                "worklist",
                AlgoTrace::kv([
                    ("items", json!(work.len())),
                    ("preview", json!(preview)),
                ]),
            );
        }

        // Module-diverse batch: apply up to batch_size paths from *distinct*
        // modules before remeasure so full-core coverage scales with √modules
        // instead of 1-path-per-remeasure thrash on a single FPU tree.
        let mut batch: Vec<crate::worklist::WorkItem> = Vec::new();
        let mut batch_mods: BTreeSet<String> = BTreeSet::new();
        let mut deferred_same_mod: Vec<crate::worklist::WorkItem> = Vec::new();
        let apply_batch = if extra_uncut_span { 1 } else { batch_size };
        for w in work {
            if w.opportunity.is_none() || skipped.contains(&w.path_id) {
                continue;
            }
            let mod_name = ctx
                .design
                .paths
                .iter()
                .find(|p| p.id == w.path_id)
                .and_then(|p| ctx.design.modules.get(&p.module))
                .map(|m| m.name.clone())
                .unwrap_or_default();
            if !mod_name.is_empty()
                && !ctx.policy.module_allowed(&mod_name)
                && !ctx.policy.module_allowed(&ctx.active_module_name)
            {
                skipped.insert(w.path_id);
                continue;
            }
            // Cleanliness winner gates transforms: InsertReg only if the
            // module picked jit/multi-cut; exclusive/ff-factor stay always_*.
            // Resilient datapath (gemm-shaped Plain RegToReg > budget) is
            // a path-level exception: S4 InsertReg is admitted even when the
            // mixed-module winner is seq_plus_comb / comb_exclusive.
            if let Some(opp) = w.opportunity.as_ref() {
                if let Some(sol) = ctx.design.module_cleanliness.get(&mod_name) {
                    if !sol.allows_opportunity(opp.kind) {
                        let path = ctx.design.paths.iter().find(|p| p.id == w.path_id);
                        let ex = path.and_then(|p| exception_policy(&ctx.design, p));
                        let admit_ex = opp.kind == OpportunityKind::InsertReg
                            && ex.as_ref().is_some_and(|e| e.admit_insert_reg);
                        if !admit_ex {
                            skipped.insert(w.path_id);
                            *refuse_by_reason
                                .entry("cleanliness_set".into())
                                .or_insert(0) += 1;
                            let class = path
                                .map(|p| format!("{:?}", p.path_class))
                                .unwrap_or_else(|| "unknown".into());
                            *refuse_by_class.entry(class.clone()).or_insert(0) += 1;
                            ctx.algo_trace.emit_path(
                                "refuse",
                                ctx.pass_index,
                                Some(w.path_id),
                                Some(mod_name.clone()),
                                AlgoTrace::kv([
                                    ("applied", json!(false)),
                                    ("reason", json!("cleanliness_set")),
                                    ("set", json!(sol.chosen.as_str())),
                                    ("class", json!(class)),
                                    ("opp", json!(format!("{:?}", opp.kind))),
                                ]),
                            );
                            continue;
                        }
                        ctx.algo_trace.emit_path(
                            "exception",
                            ctx.pass_index,
                            Some(w.path_id),
                            Some(mod_name.clone()),
                            AlgoTrace::kv([
                                ("policy", json!(ex.as_ref().map(|e| e.kind.as_str()))),
                                ("set", json!(sol.chosen.as_str())),
                                ("opp", json!(format!("{:?}", opp.kind))),
                                ("note", json!(ex.as_ref().map(|e| e.note.clone()))),
                            ]),
                        );
                    }
                }
            }
            if batch_mods.contains(&mod_name) {
                if deferred_same_mod.len() < batch_size {
                    deferred_same_mod.push(w);
                }
                continue;
            }
            if !mod_name.is_empty() {
                batch_mods.insert(mod_name);
            }
            batch.push(w);
            if batch.len() >= apply_batch {
                break;
            }
        }
        // Fill remaining batch slots with same-module residual if diversity exhausted.
        for w in deferred_same_mod {
            if batch.len() >= apply_batch {
                break;
            }
            if skipped.contains(&w.path_id) {
                continue;
            }
            batch.push(w);
        }
        if batch.is_empty() {
            break;
        }

        let mut any_applied = false;
        for item in batch {
            // Resolve module name for this path.
            if let Some(path) = ctx.design.paths.iter().find(|p| p.id == item.path_id) {
                if let Some(m) = ctx.design.modules.get(&path.module) {
                    if ctx.policy.module_allowed(&m.name) {
                        ctx.active_module_name = m.name.clone();
                    }
                }
            }

            // Relocation-first: honor preferred_auto option, then latency-neutral,
            // then InsertReg. Large atomic bottlenecks use PrepStage (expr spine)
            // even when soft multi_cycle (never InsertReg on those).
            let fo4_before = ctx
                .design
                .paths
                .iter()
                .find(|p| p.id == item.path_id)
                .map(|p| p.total_fo4);
            let module_name = ctx
                .design
                .paths
                .iter()
                .find(|p| p.id == item.path_id)
                .and_then(|p| ctx.design.modules.get(&p.module))
                .map(|m| m.name.clone());
            let class = ctx
                .design
                .paths
                .iter()
                .find(|p| p.id == item.path_id)
                .map(|p| format!("{:?}", p.path_class));
            let (applied, refuse_reason) = apply_work_item(&mut ctx, &item)?;
            let apply_kind = ctx
                .trace
                .records
                .last()
                .map(|r| format!("{:?}", r.kind).to_lowercase());
            let fo4_after = ctx
                .design
                .paths
                .iter()
                .find(|p| p.id == item.path_id)
                .map(|p| p.total_fo4);
            ctx.algo_trace.emit_path(
                if applied { "apply" } else { "refuse" },
                ctx.pass_index,
                Some(item.path_id),
                module_name.clone(),
                AlgoTrace::kv([
                    ("applied", json!(applied)),
                    ("reloc", json!(item.relocation_option_id)),
                    ("class", json!(class)),
                    ("fo4_before", json!(fo4_before)),
                    ("fo4_after", json!(fo4_after)),
                    ("edit_kind", json!(apply_kind)),
                    ("opp", json!(item.opportunity.as_ref().map(|o| format!("{:?}", o.kind)))),
                    ("reason", json!(refuse_reason)),
                ]),
            );

            if !applied {
                skipped.insert(item.path_id);
                let reason = refuse_reason.unwrap_or("unspecified");
                *refuse_by_reason.entry(reason.into()).or_insert(0) += 1;
                *refuse_by_class
                    .entry(class.clone().unwrap_or_else(|| "unknown".into()))
                    .or_insert(0) += 1;
                continue;
            }
            if apply_kind.as_deref() == Some("insertreg") {
                if let Some(m) = module_name.as_ref() {
                    *ctx.insert_reg_by_module.entry(m.clone()).or_insert(0) += 1;
                    if let Some(path) = ctx.design.paths.iter().find(|p| p.id == item.path_id)
                    {
                        let names = span_family_lhs_on_path(&ctx.design, path);
                        if !names.is_empty() {
                            cut_span_lhs.entry(m.clone()).or_default().extend(names);
                        }
                    }
                }
            }
            any_applied = true;
            let n = applied_count.entry(item.path_id).or_insert(0);
            *n += 1;
            // PrepStage once; exclusive/plain may re-enter up to design-scaled cap.
            let cap = if item
                .relocation_option_id
                .as_deref()
                .map(|s| s.contains("prep_stage") || s.contains("t1_prep"))
                .unwrap_or(false)
            {
                1
            } else {
                apply_cap_default
            };
            if *n >= cap {
                skipped.insert(item.path_id);
            }
        }

        if !any_applied {
            idle_streak += 1;
            ctx.log_algo(
                "pass.idle",
                AlgoTrace::kv([
                    ("idle_streak", json!(idle_streak)),
                    ("idle_limit", json!(idle_limit)),
                ]),
            );
            if idle_streak >= idle_limit {
                ctx.log_algo("run.stop", AlgoTrace::kv([("reason", json!("idle_limit"))]));
                break;
            }
            // Mark first batch member skipped already; continue residual set.
            continue;
        }
        idle_streak = 0;

        ctx.measure();
        let now_primary = ctx
            .ranked
            .primary
            .first()
            .map(|p| p.total_fo4)
            .unwrap_or(0.0);
        if (last_primary - now_primary).abs() < min_gain {
            flat_streak += 1;
        } else {
            flat_streak = 0;
            extra_uncut_span = false;
        }
        last_primary = now_primary;
        ctx.log_algo(
            "measure",
            AlgoTrace::kv([
                ("primary_fo4", json!(now_primary)),
                ("flat_streak", json!(flat_streak)),
                ("stage_s4", json!(stage_s4)),
            ]),
        );
        if ctx
            .ranked
            .primary
            .first()
            .map(|p| p.slack_fo4 >= 0.0)
            .unwrap_or(true)
        {
            ctx.log_algo(
                "run.stop",
                AlgoTrace::kv([("reason", json!("primary_closed"))]),
            );
            break;
        }
        if flat_streak >= 2 {
            if !stage_s4 && ctx.policy.allow_latency && ctx.policy.emit_structural {
                stage_s4 = true;
                stage_passes = 0;
                flat_streak = 0;
                ctx.log_algo(
                    "stage.s4",
                    AlgoTrace::kv([("reason", json!("s3_fixpoint"))]),
                );
                continue;
            }
            let stop = if !stage_s4 && !ctx.policy.emit_structural {
                "lean_emit_skip_s4"
            } else {
                "fixpoint"
            };
            // After diverse S4 2-flat: ranked.primary.first is often the T3
            // mul 74.5 (v31), not emit 18.5 a_span. Scan for an uncut
            // resilient span/end leftover instead.
            let uncut = ctx.ranked.primary.iter().any(|p| {
                if p.slack_fo4 >= 0.0 {
                    return false;
                }
                let mod_name = ctx
                    .design
                    .modules
                    .get(&p.module)
                    .map(|m| m.name.as_str())
                    .unwrap_or("");
                let empty = BTreeSet::new();
                let cut = cut_span_lhs.get(mod_name).unwrap_or(&empty);
                s4_sibling_span_pending(&ctx.design, p)
                    && !path_span_lhs_all_cut(&ctx.design, p, cut)
            });
            if stage_s4
                && sibling_extra < SIBLING_EXTRA_CAP
                && ctx.policy.emit_structural
                && uncut
            {
                sibling_extra += 1;
                extra_uncut_span = true;
                flat_streak = 0;
                ctx.log_algo(
                    "stage.s4",
                    AlgoTrace::kv([
                        ("reason", json!("uncut_sibling_span")),
                        ("extra", json!(sibling_extra)),
                    ]),
                );
                continue;
            }
            ctx.log_algo("run.stop", AlgoTrace::kv([("reason", json!(stop))]));
            break;
        }
        if stage_passes >= stage_budget {
            if !stage_s4 && ctx.policy.allow_latency && ctx.policy.emit_structural {
                stage_s4 = true;
                stage_passes = 0;
                flat_streak = 0;
                ctx.log_algo(
                    "stage.s4",
                    AlgoTrace::kv([("reason", json!("stage_budget"))]),
                );
                continue;
            }
            ctx.log_algo(
                "run.stop",
                AlgoTrace::kv([("reason", json!("stage_budget"))]),
            );
            break;
        }
    }
    // PASS-STRATEGY S5: T3 asks (P8 deep datapath / P9 iterative) — report only.
    let t3 = ctx.relocation.as_ref().map(|r| r.summary.t3_only_cards).unwrap_or(0);
    let p8 = ctx
        .design
        .paths
        .iter()
        .filter(|p| {
            p.path_class == sv_timing_core::PathClassKind::AtomicOverBudget && !p.multi_cycle
                || p.class_note
                    .as_deref()
                    .is_some_and(|s| s.contains("P4 remainder") || s.contains("P8"))
        })
        .count();
    let p9 = ctx
        .design
        .paths
        .iter()
        .filter(|p| {
            p.multi_cycle || p.path_class == sv_timing_core::PathClassKind::MultiCycleTagged
        })
        .count();
    ctx.log_algo(
        "stage.s5",
        AlgoTrace::kv([
            ("t3_only_cards", json!(t3)),
            ("p8_or_remainder", json!(p8)),
            ("p9_iterative", json!(p9)),
        ]),
    );
    ctx.algo_trace.emit(
        "run.end",
        ctx.pass_index,
        AlgoTrace::kv([
            ("edits", json!(ctx.trace.records.len())),
            ("passes", json!(ctx.pass_index)),
            ("refuse_by_reason", json!(refuse_by_reason)),
            ("refuse_by_class", json!(refuse_by_class)),
            ("t3_only_cards", json!(t3)),
        ]),
    );
    Ok(ctx)
}

/// S4 opportunity for a resilient datapath: reuse a suggested InsertReg, else
/// synthesize a mid-cone cut (relocation T1-first cards never attach one).
fn insert_reg_for_path(design: &TimingDesign, path: &TimingPath) -> Opportunity {
    if let Some(o) = design
        .opportunities
        .iter()
        .find(|o| o.path_id == path.id && o.kind == OpportunityKind::InsertReg)
    {
        return o.clone();
    }
    let cut = if path.nodes.len() <= 1 {
        path.nodes.first().copied().unwrap_or(0)
    } else {
        path.nodes[path.nodes.len() / 2 - 1]
    };
    let budget = design.target.budget_fo4;
    Opportunity {
        kind: OpportunityKind::InsertReg,
        path_id: path.id,
        insert_after: cut,
        estimated_fo4_before: path.total_fo4,
        estimated_fo4_after: (path.total_fo4 * 0.5).max(budget),
        loc: path.primary_loc.clone(),
        rationale: "exception_policy resilient_datapath → InsertReg".into(),
        requires_clock_in_scope: true,
        changes_latency: true,
    }
}

/// Apply one worklist item (relocation-first transform cascade).
fn apply_work_item(
    ctx: &mut PassContext,
    item: &crate::worklist::WorkItem,
) -> TransformResult<(bool, Option<&'static str>)> {
    let mut did = false;
    let Some(opp) = item.opportunity.clone() else {
        return Ok((false, Some("no_opportunity")));
    };
    let origin = opp.loc.clone();
    if origin.origin != sv_timing_core::OriginKind::UserFile {
        return Ok((false, Some("origin_not_user_file")));
    }
    let node = opp.insert_after;
    let reloc_id = item.relocation_option_id.as_deref().unwrap_or("");
    let path_mc = ctx
        .design
        .paths
        .iter()
        .find(|p| p.id == opp.path_id)
        .map(|p| p.multi_cycle)
        .unwrap_or(false);
    let path_class = ctx
        .design
        .paths
        .iter()
        .find(|p| p.id == opp.path_id)
        .map(|p| p.path_class);
    let lane = ctx
        .design
        .paths
        .iter()
        .find(|p| p.id == opp.path_id)
        .map(|p| cone_lane(&ctx.design, p))
        .unwrap_or(ConeLane::CombDatapath);

    let insert_preferred =
        reloc_id.contains("insert_reg") || opp.kind == OpportunityKind::InsertReg;
    let balance_preferred =
        reloc_id.contains("balance") || opp.kind == OpportunityKind::BalanceMux;
    let admit_ex = ctx
        .design
        .paths
        .iter()
        .find(|p| p.id == opp.path_id)
        .and_then(|p| exception_policy(&ctx.design, p))
        .is_some_and(|e| e.admit_insert_reg);

    // Lean emit (soak default): sidecar pipes / credit comments do not rewrite
    // the measured assign. Refuse every IR FO4 mutation so post_closure cannot
    // claim a cut the emitted file does not contain (audit-strict-v4 gemm
    // 304.5 vs IR 96.5). InsertReg, BalanceMux, SplitAssign, rebalance, prep.
    if !ctx.policy.emit_structural {
        return Ok((false, Some("lean_emit_no_origin_rewrite")));
    }

    // 0) PrepStage from relocation (atomic / deep expr) — before anything else.
    let prep_requested = !insert_preferred
        && (reloc_id.contains("prep_stage")
            || reloc_id.contains("t1_prep")
            || (opp.kind == OpportunityKind::SplitAssign && opp.rationale.contains("prep")));
    if prep_requested {
        match crate::pipeline::expand_expr_spine_for_path(ctx, opp.path_id) {
            Ok(true) => {
                did = true;
                if let Some(last) = ctx.trace.records.last_mut() {
                    last.rationale = format!(
                        "relocation {reloc_id} prep_stage expand_expr_spine path {} (latency-neutral)",
                        opp.path_id
                    );
                } else if let Some(path) =
                    ctx.design.paths.iter_mut().find(|p| p.id == opp.path_id)
                {
                    let note = format!(
                        "relocation {reloc_id} prep_stage spine expand; {}",
                        path.class_note.clone().unwrap_or_default()
                    );
                    path.class_note = Some(note);
                }
            }
            Ok(false) => {}
            Err(_) => {}
        }
    }

    let exclusive_shape = matches!(
        path_class,
        Some(
            sv_timing_core::PathClassKind::ExclusiveCaseMux
                | sv_timing_core::PathClassKind::ExclusiveIfChain
                | sv_timing_core::PathClassKind::IndependentLhsBundle
                | sv_timing_core::PathClassKind::DenseControlCone
        )
    );
    // 1) BalanceMux first on exclusive/bundle residuals. Full-core evidence:
    // rebalance_associative can "succeed" (depth −1) and consume the apply slot
    // while leaving exclusive residual ~46 FO4 — starving stage/onehot.
    if !did
        && !insert_preferred
        && (balance_preferred || exclusive_shape)
    {
        if crate::pipeline::balance_mux_on_path(ctx, opp.path_id, node, origin.clone()).is_ok()
        {
            did = true;
            if let Some(last) = ctx.trace.records.last_mut() {
                if !reloc_id.is_empty() {
                    last.rationale = format!("relocation {reloc_id}; {}", last.rationale);
                }
            }
        }
    }
    // 2) Associative rebalance (plain cones / BalanceMux miss).
    if !did
        && !insert_preferred
        && crate::pipeline::rebalance_associative_node(
            ctx,
            node,
            origin.clone(),
            Some(opp.path_id),
        )
        .is_ok()
    {
        did = true;
        if let Some(last) = ctx.trace.records.last_mut() {
            if !reloc_id.is_empty() {
                last.rationale = format!("relocation {reloc_id}; {}", last.rationale);
            }
        }
    }
    if !did
        && !insert_preferred
        && (!ctx.policy.allow_latency
            || opp.kind == OpportunityKind::SplitAssign
            || opp.kind == OpportunityKind::BalanceMux)
    {
        if split_assign(ctx, node, origin.clone(), "split").is_ok() {
            did = true;
            if let Some(last) = ctx.trace.records.last_mut() {
                if !reloc_id.is_empty() {
                    last.rationale = format!("relocation {reloc_id}; {}", last.rationale);
                }
            }
        }
    }
    // 4) InsertReg when allow_latency — never on soft multi-cycle atomics.
    // Cap per module so one iterative FPU tree cannot absorb hundreds of cuts
    // (full_core @ 4 GHz: 181 InsertRegs on ct_vfdsu_srt_radix16_with_sqrt).
    let insert_cap = ctx.policy.opt.max_stages_per_region.max(2);
    let insert_used = ctx
        .insert_reg_by_module
        .get(&ctx.active_module_name)
        .copied()
        .unwrap_or(0);
    if !did
        && ctx.policy.allow_latency
        && !path_mc
        && insert_used < insert_cap
        && (lane.allows_insert_reg() || admit_ex)
    {
        let ins = ctx
            .design
            .opportunities
            .iter()
            .find(|o| o.path_id == opp.path_id && o.kind == OpportunityKind::InsertReg)
            .cloned()
            .or_else(|| {
                if opp.kind == OpportunityKind::InsertReg {
                    Some(opp.clone())
                } else {
                    None
                }
            });
        if let Some(ins_opp) = ins {
            let _ = crate::pipeline::expand_expr_spine_for_path(ctx, ins_opp.path_id);
            match select_pipeline_cuts(ctx, &ins_opp) {
                Ok(plan) => {
                    insert_register(ctx, &plan)?;
                    did = true;
                    if let Some(last) = ctx.trace.records.last_mut() {
                        if !reloc_id.is_empty() {
                            last.rationale =
                                format!("relocation {reloc_id}; {}", last.rationale);
                        }
                    }
                }
                Err(TransformError::IncompleteGateInfo) => {
                    return Ok((false, Some("incomplete_gate")));
                }
                Err(TransformError::LatencyNotAllowed) => {
                    return Ok((false, Some("latency_not_allowed")));
                }
                Err(TransformError::InvalidOpportunity(_)) => {
                    return Ok((false, Some("cut_schedule")));
                }
                Err(e) => return Err(e),
            }
        }
    }
    if did {
        return Ok((true, None));
    }
    let reason = if insert_preferred && !ctx.policy.allow_latency {
        "latency_not_allowed"
    } else if insert_preferred && path_mc {
        "multi_cycle"
    } else if insert_preferred && !lane.allows_insert_reg() && !admit_ex {
        "lane_forbids_insert_reg"
    } else if insert_preferred && insert_used >= insert_cap {
        "insert_cap"
    } else {
        "no_transform_matched"
    };
    Ok((false, Some(reason)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use sv_timing_core::{
        analyze_files, default_fo4_v1_embedded, LowerOptions, ParseOptions, TimingTarget,
    };
    use std::path::PathBuf;

    #[test]
    fn correct_from_analyze_deep_add_chain() {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures/auto_correct/deep_add_chain.sv");
        if !path.exists() {
            return;
        }
        let mut lower = LowerOptions {
            target: TimingTarget::new(3000.0, 20.0, 0.2), // tight budget → opportunities
            cost_model: default_fo4_v1_embedded(),
            module_filter: vec!["deep_add_chain".into()],
            ..Default::default()
        };
        lower.cost_model.id = "fo4-v1".into();
        let out = analyze_files(&[path], &ParseOptions::default(), &lower).expect("analyze");
        assert!(!out.design.paths.is_empty());

        let mut policy = PassPolicy::default();
        policy.correct_enabled = true;
        policy.correct_allow_modules = vec!["deep_add_chain".into()];
        policy.allow_latency = true;
        policy.max_passes = 2;

        let mut ctx = PassContext::new(out.design, out.names, policy);
        ctx.assume_clk = true;
        ctx.cost_model = default_fo4_v1_embedded();
        let before = ctx.design.paths.iter().map(|p| p.total_fo4).fold(0.0, f64::max);
        let ctx = run_correct_passes(ctx).expect("correct");
        assert!(
            !ctx.trace.records.is_empty(),
            "expected at least one edit on over-budget design"
        );
        let after = ctx.design.paths.iter().map(|p| p.total_fo4).fold(0.0, f64::max);
        // After split, no segment should exceed the original full-path FO4.
        assert!(after <= before + 1e-6, "before={before} after={after}");
    }

    #[test]
    fn algo_trace_records_run_and_measure() {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures/auto_correct/deep_add_chain.sv");
        if !path.exists() {
            return;
        }
        let mut lower = LowerOptions {
            target: TimingTarget::new(3000.0, 20.0, 0.2),
            cost_model: default_fo4_v1_embedded(),
            module_filter: vec!["deep_add_chain".into()],
            ..Default::default()
        };
        lower.cost_model.id = "fo4-v1".into();
        let out = analyze_files(&[path], &ParseOptions::default(), &lower).expect("analyze");
        let mut policy = PassPolicy::default();
        policy.correct_enabled = true;
        policy.correct_allow_modules = vec!["deep_add_chain".into()];
        policy.allow_latency = true;
        policy.max_passes = 2;
        let dir = std::env::temp_dir().join(format!(
            "svt-pass-trace-{}",
            std::process::id()
        ));
        let _ = std::fs::create_dir_all(&dir);
        let logp = dir.join("algo-trace.jsonl");
        let tracer = AlgoTrace::to_file(&logp).expect("trace file");
        let mut ctx = PassContext::new(out.design, out.names, policy).with_algo_trace(tracer);
        ctx.assume_clk = true;
        ctx.cost_model = default_fo4_v1_embedded();
        let _ = run_correct_passes(ctx).expect("correct");
        let text = std::fs::read_to_string(&logp).expect("read trace");
        assert!(text.contains("\"kind\":\"run.start\""), "{text}");
        assert!(text.contains("\"kind\":\"measure\""), "{text}");
        assert!(text.contains("\"kind\":\"run.end\"") || text.contains("\"kind\":\"run.stop\""), "{text}");
        assert!(
            text.contains("refuse_by_reason") || text.contains("\"kind\":\"run.stop\""),
            "PASS-STRATEGY §6.4: run.end should count refuses: {text}"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn emit_structural_false_refuses_insert_reg_and_balance_mux() {
        // Lean soak emit (R12e) does not rewrite origin assigns. InsertReg /
        // BalanceMux must not book IR FO4 the sidecar will not contain
        // (audit-strict-v4 APU 304.5 → IR 96.5 on an unchanged c_span).
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures/auto_correct/deep_add_chain.sv");
        if !path.exists() {
            return;
        }
        let mut lower = LowerOptions {
            target: TimingTarget::new(3000.0, 20.0, 0.2),
            cost_model: default_fo4_v1_embedded(),
            module_filter: vec!["deep_add_chain".into()],
            ..Default::default()
        };
        lower.cost_model.id = "fo4-v1".into();
        let out = analyze_files(&[path], &ParseOptions::default(), &lower).expect("analyze");
        let mut policy = PassPolicy::default();
        policy.correct_enabled = true;
        policy.correct_allow_modules = vec!["deep_add_chain".into()];
        policy.allow_latency = true;
        policy.max_passes = 4;
        policy.emit_structural = false;

        let mut ctx = PassContext::new(out.design, out.names, policy);
        ctx.assume_clk = true;
        ctx.cost_model = default_fo4_v1_embedded();
        let ctx = run_correct_passes(ctx).expect("correct");
        let banned: Vec<_> = ctx
            .trace
            .records
            .iter()
            .filter(|r| {
                !matches!(r.kind, crate::edit::EditKind::Annotate)
            })
            .map(|r| format!("{:?}", r.kind))
            .collect();
        assert!(
            banned.is_empty(),
            "lean emit credited IR-mutating kinds: {banned:?}"
        );
    }

    #[test]
    fn apply_work_item_refuses_insert_reg_when_not_emit_structural() {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures/auto_correct/deep_add_chain.sv");
        if !path.exists() {
            return;
        }
        let mut lower = LowerOptions {
            target: TimingTarget::new(3000.0, 20.0, 0.2),
            cost_model: default_fo4_v1_embedded(),
            module_filter: vec!["deep_add_chain".into()],
            ..Default::default()
        };
        lower.cost_model.id = "fo4-v1".into();
        let out = analyze_files(&[path], &ParseOptions::default(), &lower).expect("analyze");
        let mut policy = PassPolicy::default();
        policy.correct_enabled = true;
        policy.correct_allow_modules = vec!["deep_add_chain".into()];
        policy.allow_latency = true;
        policy.emit_structural = false;
        let mut ctx = PassContext::new(out.design, out.names, policy);
        ctx.assume_clk = true;
        ctx.cost_model = default_fo4_v1_embedded();
        let opp = ctx
            .design
            .opportunities
            .iter()
            .find(|o| o.kind == OpportunityKind::InsertReg)
            .cloned()
            .unwrap_or_else(|| {
                let p = ctx.design.paths.first().expect("analyzed path");
                sv_timing_core::Opportunity {
                    kind: OpportunityKind::InsertReg,
                    path_id: p.id,
                    insert_after: p.nodes.first().copied().unwrap_or(0),
                    estimated_fo4_before: p.total_fo4,
                    estimated_fo4_after: p.total_fo4 * 0.5,
                    loc: p.primary_loc.clone(),
                    rationale: "lean-emit refuse".into(),
                    requires_clock_in_scope: true,
                    changes_latency: true,
                }
            });
        let item = crate::worklist::WorkItem {
            path_id: opp.path_id,
            slack_fo4: -1.0,
            total_fo4: opp.estimated_fo4_before,
            opportunity: Some(opp),
            file: "deep_add_chain.sv".into(),
            line: 1,
            relocation_option_id: Some("insert_reg".into()),
        };
        let (applied, reason) = apply_work_item(&mut ctx, &item).expect("apply");
        assert!(!applied, "InsertReg must refuse when emit_structural=false");
        assert_eq!(reason, Some("lean_emit_no_origin_rewrite"));
        assert!(
            ctx.trace.records.is_empty(),
            "lean refuse must not leave InsertReg edits"
        );
    }

    #[test]
    fn sibling_span_extra_cuts_uncut_spans_not_recut() {
        // Two generate-if spans with different RHS. Extra S4 must cut both
        // without looping forever (already-cut LHS are skipped).
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures/auto_correct/sibling_span.sv");
        if !path.exists() {
            return;
        }
        let mut lower = LowerOptions {
            target: TimingTarget::new(4000.0, 20.0, 0.2),
            cost_model: default_fo4_v1_embedded(),
            module_filter: vec!["sibling_span".into()],
            ..Default::default()
        };
        lower.cost_model.id = "fo4-v1".into();
        let out = analyze_files(&[path], &ParseOptions::default(), &lower).expect("analyze");
        let mut policy = PassPolicy::from_opt(
            sv_timing_core::OptOptions::preset(sv_timing_core::OptLevel::O3),
            vec!["sibling_span".into()],
            true,
        );
        policy.emit_structural = true;
        let mut ctx = PassContext::new(out.design, out.names, policy);
        ctx.assume_clk = true;
        ctx.cost_model = default_fo4_v1_embedded();
        let ctx = run_correct_passes(ctx).expect("correct");
        let n_insert = ctx
            .trace
            .records
            .iter()
            .filter(|r| matches!(r.kind, crate::edit::EditKind::InsertReg))
            .count();
        assert!(
            n_insert >= 2,
            "expected uncut sibling-span InsertRegs, got {n_insert}"
        );
        assert!(
            n_insert <= 4,
            "must not re-cut the same span origins, got {n_insert}"
        );
    }
}
