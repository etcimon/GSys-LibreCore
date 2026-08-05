// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Pass context, policy, and multi-pass driver.

use std::collections::{BTreeMap, BTreeSet};

use thiserror::Error;

use sv_timing_core::{
    attribute_costs, build_relocation_plan, rank_paths_by_slack, remeasure_path_slacks,
    suggest_opportunities, CostModel, GateInfo, NameTable, OpportunityKind, PathId, RankedPaths,
    RelocationPlan, TimingDesign,
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
        }
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

    ctx.measure();
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
    // Paths already tried without gain this session — skip so residual work continues.
    let mut skipped: std::collections::BTreeSet<sv_timing_core::PathId> =
        std::collections::BTreeSet::new();
    // Successful applies per path (cap re-entry so prep_stage cannot thrash).
    let mut applied_count: std::collections::BTreeMap<sv_timing_core::PathId, u32> =
        std::collections::BTreeMap::new();
    let mut idle_streak = 0u32;
    for _ in 0..ctx.policy.max_passes {
        ctx.pass_index += 1;
        let work = order_worklist_with_plan(
            &ctx.ranked,
            &ctx.design.opportunities,
            &ctx.policy.worklist,
            ctx.relocation.as_ref(),
        );

        // Module-diverse batch: apply up to batch_size paths from *distinct*
        // modules before remeasure so full-core coverage scales with √modules
        // instead of 1-path-per-remeasure thrash on a single FPU tree.
        let mut batch: Vec<crate::worklist::WorkItem> = Vec::new();
        let mut batch_mods: BTreeSet<String> = BTreeSet::new();
        let mut deferred_same_mod: Vec<crate::worklist::WorkItem> = Vec::new();
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
            if batch.len() >= batch_size {
                break;
            }
        }
        // Fill remaining batch slots with same-module residual if diversity exhausted.
        for w in deferred_same_mod {
            if batch.len() >= batch_size {
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
            let applied = apply_work_item(&mut ctx, &item)?;

            if !applied {
                skipped.insert(item.path_id);
                continue;
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
            if idle_streak >= idle_limit {
                break;
            }
            // Mark first batch member skipped already; continue residual set.
            continue;
        }
        idle_streak = 0;

        ctx.measure();
        if ctx
            .ranked
            .primary
            .first()
            .map(|p| p.slack_fo4 >= 0.0)
            .unwrap_or(true)
        {
            break;
        }
    }
    Ok(ctx)
}

/// Apply one worklist item (relocation-first transform cascade).
fn apply_work_item(
    ctx: &mut PassContext,
    item: &crate::worklist::WorkItem,
) -> TransformResult<bool> {
    let mut did = false;
    let Some(opp) = item.opportunity.clone() else {
        return Ok(false);
    };
    let origin = opp.loc.clone();
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

    let insert_preferred =
        reloc_id.contains("insert_reg") || opp.kind == OpportunityKind::InsertReg;
    let balance_preferred =
        reloc_id.contains("balance") || opp.kind == OpportunityKind::BalanceMux;

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
    if !did && ctx.policy.allow_latency && !path_mc {
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
                Err(TransformError::IncompleteGateInfo)
                | Err(TransformError::LatencyNotAllowed) => {}
                Err(TransformError::InvalidOpportunity(_)) => {}
                Err(e) => return Err(e),
            }
        }
    }
    Ok(did)
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
}
