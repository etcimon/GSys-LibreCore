// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Order work like a timing profiler: worst slack first, stable ties.
//! Optionally driven by [`RelocationPlan`] preferred actionable options.

use std::collections::BTreeSet;

use sv_timing_core::{
    measure::RankedPaths, preferred_actionable_kind, relocation_to_opportunity_kind, Opportunity,
    OpportunityKind, PathId, RelocationPlan, TimingPath,
};

/// Policy for building a worklist from ranked paths.
#[derive(Debug, Clone)]
pub struct WorklistPolicy {
    /// Max items to consider this pass.
    pub max_items: usize,
    /// Skip multi-cycle.
    pub skip_multi_cycle: bool,
    /// Prefer relocation-plan card order and actionable kinds when present.
    pub use_relocation_plan: bool,
}

impl Default for WorklistPolicy {
    fn default() -> Self {
        Self {
            max_items: 32,
            skip_multi_cycle: true,
            use_relocation_plan: true,
        }
    }
}

/// One unit of work for a correct pass.
#[derive(Debug, Clone)]
pub struct WorkItem {
    /// Path id.
    pub path_id: PathId,
    /// Slack FO4.
    pub slack_fo4: f64,
    /// Total FO4.
    pub total_fo4: f64,
    /// Optional opportunity attached.
    pub opportunity: Option<Opportunity>,
    /// Primary location file for stable sort.
    pub file: String,
    /// Primary location line.
    pub line: u32,
    /// Relocation option id that selected this work (if any).
    pub relocation_option_id: Option<String>,
}

/// Convert ranked paths (+ optional opportunities) into a deterministic worklist.
pub fn order_worklist(
    ranked: &RankedPaths,
    opportunities: &[Opportunity],
    policy: &WorklistPolicy,
) -> Vec<WorkItem> {
    order_worklist_with_plan(ranked, opportunities, policy, None)
}

/// Like [`order_worklist`], optionally prioritizing [`RelocationPlan`] cards.
///
/// **Large bottlenecks first:** cards already score worst FO4 first. Primary
/// failing paths are enqueued with preferred_auto transforms. Soft multi-cycle
/// **atomic** cards stay out of InsertReg thrash but still get **PrepStage**
/// (expr-spine) when that is the preferred T1 option — otherwise the biggest
/// FO4 cards never participate in correct.
pub fn order_worklist_with_plan(
    ranked: &RankedPaths,
    opportunities: &[Opportunity],
    policy: &WorklistPolicy,
    plan: Option<&RelocationPlan>,
) -> Vec<WorkItem> {
    let primary_by_id: std::collections::BTreeMap<PathId, &TimingPath> =
        ranked.primary.iter().map(|p| (p.id, p)).collect();
    let multi_by_id: std::collections::BTreeMap<PathId, &TimingPath> =
        ranked.multi_cycle.iter().map(|p| (p.id, p)).collect();

    let mut items: Vec<WorkItem> = Vec::new();
    let mut seen: BTreeSet<PathId> = BTreeSet::new();
    let mut soft_atomic_prep: Vec<WorkItem> = Vec::new();

    if policy.use_relocation_plan {
        if let Some(plan) = plan {
            for card in &plan.cards {
                if seen.contains(&card.path_id) {
                    continue;
                }
                // Primary single-cycle failing paths (large plain / exclusive / bundle).
                if let Some(p) = primary_by_id.get(&card.path_id).copied() {
                    if !p.multi_cycle {
                        let (opportunity, opt_id) =
                            pick_opportunity_for_card(card, p, opportunities);
                        if opportunity.is_none()
                            && preferred_actionable_kind(card).is_none()
                            && p.slack_fo4 < 0.0
                        {
                            let fallback = pick_opportunity_default(p, opportunities);
                            if fallback.is_none() {
                                continue;
                            }
                            items.push(WorkItem {
                                path_id: p.id,
                                slack_fo4: p.slack_fo4,
                                total_fo4: p.total_fo4,
                                opportunity: fallback,
                                file: p.primary_loc.file.clone(),
                                line: p.primary_loc.start_line,
                                relocation_option_id: opt_id,
                            });
                            seen.insert(p.id);
                            continue;
                        }
                        items.push(WorkItem {
                            path_id: p.id,
                            slack_fo4: p.slack_fo4,
                            total_fo4: p.total_fo4,
                            opportunity,
                            file: p.primary_loc.file.clone(),
                            line: p.primary_loc.start_line,
                            relocation_option_id: opt_id,
                        });
                        seen.insert(p.id);
                        continue;
                    }
                }
                // Soft multi-cycle atomics: queue PrepStage only (append after primary).
                if let Some(p) = multi_by_id.get(&card.path_id).copied() {
                    if !p.multi_cycle {
                        continue;
                    }
                    let want = preferred_actionable_kind(card);
                    if !matches!(
                        want,
                        Some(sv_timing_core::RelocationKind::PrepStage)
                            | Some(sv_timing_core::RelocationKind::SplitAssign)
                            | Some(sv_timing_core::RelocationKind::RebalanceAssoc)
                    ) {
                        continue;
                    }
                    let (opportunity, opt_id) =
                        pick_opportunity_for_card(card, p, opportunities);
                    if opportunity.is_none() {
                        continue;
                    }
                    soft_atomic_prep.push(WorkItem {
                        path_id: p.id,
                        slack_fo4: p.slack_fo4,
                        total_fo4: p.total_fo4,
                        opportunity,
                        file: p.primary_loc.file.clone(),
                        line: p.primary_loc.start_line,
                        relocation_option_id: opt_id,
                    });
                    seen.insert(p.id);
                }
            }
        }
    }

    // Remaining primary paths (not in plan or plan disabled).
    for p in &ranked.primary {
        if seen.contains(&p.id) {
            continue;
        }
        items.push(path_to_item(p, opportunities));
        seen.insert(p.id);
    }

    if !policy.skip_multi_cycle {
        for p in &ranked.multi_cycle {
            if seen.contains(&p.id) {
                continue;
            }
            items.push(path_to_item(p, opportunities));
        }
    }

    // Card order already worst-first; re-sort non-card-stable: keep card prefix order
    // by sorting only when no plan, else preserve items order for card section then
    // sort the suffix... Simpler: if plan used, don't re-sort entire list — card
    // order is intentional; sort only items after cards by slack.
    if plan.is_none() || !policy.use_relocation_plan {
        items.sort_by(|a, b| {
            a.slack_fo4
                .partial_cmp(&b.slack_fo4)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a.file.cmp(&b.file))
                .then_with(|| a.line.cmp(&b.line))
                .then_with(|| a.path_id.cmp(&b.path_id))
        });
    } else {
        // Stable secondary sort by slack within equal slack only — preserve card priority:
        // assign rank from card index.
        let card_rank: std::collections::BTreeMap<PathId, usize> = plan
            .map(|pl| {
                pl.cards
                    .iter()
                    .enumerate()
                    .map(|(i, c)| (c.path_id, i))
                    .collect()
            })
            .unwrap_or_default();
        items.sort_by(|a, b| {
            let ra = card_rank.get(&a.path_id).copied().unwrap_or(10_000);
            let rb = card_rank.get(&b.path_id).copied().unwrap_or(10_000);
            ra.cmp(&rb)
                .then_with(|| {
                    a.slack_fo4
                        .partial_cmp(&b.slack_fo4)
                        .unwrap_or(std::cmp::Ordering::Equal)
                })
                .then_with(|| a.path_id.cmp(&b.path_id))
        });
    }

    // Cap from policy (already design-scaled in run_correct_passes). Soft-atomic
    // PrepStage fills a scaled tail so large atomics get spine staging without
    // starving primary BalanceMux / InsertReg work.
    let cap = policy.max_items.max(1);
    let prep_slots = if soft_atomic_prep.is_empty() {
        0
    } else {
        // ~√n_atomic prep slots, at least 2, at most 1/4 of cap.
        let n = soft_atomic_prep.len() as f64;
        ((n.sqrt().ceil() as usize).max(2)).min(cap / 4).max(1)
    };
    let primary_cap = cap.saturating_sub(prep_slots).max(policy.max_items.min(cap));
    items.truncate(primary_cap);
    let room = cap.saturating_sub(items.len());
    items.extend(soft_atomic_prep.into_iter().take(room));
    items
}

fn pick_opportunity_for_card(
    card: &sv_timing_core::RelocationCard,
    path: &TimingPath,
    opportunities: &[Opportunity],
) -> (Option<Opportunity>, Option<String>) {
    for opt in &card.options {
        if !opt.auto_correct {
            continue;
        }
        let Some(want) = relocation_to_opportunity_kind(opt.kind) else {
            continue;
        };
        if let Some(o) = opportunities
            .iter()
            .find(|o| o.path_id == path.id && o.kind == want)
        {
            return (Some(o.clone()), Some(opt.id.clone()));
        }
        // Synthesize opportunity so BalanceMux/Split still run when suggest missed.
        let node = path.nodes.last().copied().unwrap_or(0);
        let synth = Opportunity {
            kind: want,
            path_id: path.id,
            insert_after: node,
            estimated_fo4_before: path.total_fo4,
            estimated_fo4_after: opt.expected_fo4_after,
            loc: path.primary_loc.clone(),
            rationale: format!(
                "relocation {} → {:?} (synthesized from plan)",
                opt.id, want
            ),
            requires_clock_in_scope: matches!(want, OpportunityKind::InsertReg),
            changes_latency: matches!(want, OpportunityKind::InsertReg),
        };
        return (Some(synth), Some(opt.id.clone()));
    }
    (
        pick_opportunity_default(path, opportunities),
        card.preferred_auto.clone(),
    )
}

fn pick_opportunity_default(p: &TimingPath, opportunities: &[Opportunity]) -> Option<Opportunity> {
    opportunities
        .iter()
        .filter(|o| o.path_id == p.id)
        .min_by_key(|o| match o.kind {
            OpportunityKind::BalanceMux => 0u8,
            OpportunityKind::SplitAssign => 1,
            OpportunityKind::InsertReg => 2,
        })
        .cloned()
}

fn path_to_item(p: &TimingPath, opportunities: &[Opportunity]) -> WorkItem {
    WorkItem {
        path_id: p.id,
        slack_fo4: p.slack_fo4,
        total_fo4: p.total_fo4,
        opportunity: pick_opportunity_default(p, opportunities),
        file: p.primary_loc.file.clone(),
        line: p.primary_loc.start_line,
        relocation_option_id: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sv_timing_core::ir::PathEndpoint;
    use sv_timing_core::loc::{OriginKind, SourceLoc};
    use sv_timing_core::ir::{IrNode, OperatorClass, PathKind, TimingModule};
    use sv_timing_core::{
        build_relocation_plan, classify_and_adjust_paths, CostModel, PathClassKind, TimingDesign,
        TimingTarget,
    };
    use std::collections::BTreeMap;

    fn path(id: PathId, slack: f64, file: &str, line: u32) -> TimingPath {
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
            path_kind: PathKind::from_endpoints(&start, &end),
            startpoint: start.report_name("m"),
            endpoint: end.report_name("m"),
            nodes: vec![],
            total_fo4: 50.0,
            slack_fo4: slack,
            max_freq_mhz: 500.0,
            primary_loc: SourceLoc {
                file: file.into(),
                start_line: line,
                start_col: 1,
                end_line: line,
                end_col: 1,
                byte_start: 0,
                byte_end: 0,
                origin: OriginKind::UserFile,
            },
            multi_cycle: false,
            path_class: PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: None,
        }
    }

    #[test]
    fn order_worklist_stable() {
        let ranked = RankedPaths {
            primary: vec![path(2, -1.0, "b.sv", 2), path(1, -1.0, "a.sv", 1)],
            multi_cycle: vec![],
        };
        let w1 = order_worklist(&ranked, &[], &WorklistPolicy::default());
        let w2 = order_worklist(&ranked, &[], &WorklistPolicy::default());
        let ids1: Vec<_> = w1.iter().map(|w| w.path_id).collect();
        let ids2: Vec<_> = w2.iter().map(|w| w.path_id).collect();
        assert_eq!(ids1, ids2);
        assert_eq!(ids1[0], 1);
    }

    #[test]
    fn worklist_prefers_relocation_balance_mux() {
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
                    loc: path(0, 0.0, "t.sv", 1).primary_loc.clone(),
                    fans_in: vec![],
                    fans_out: vec![],
                    width_defaulted: true,
                    reads_reg: false,
                    lhs: Some("result_o".into()),
                    rhs: Some(format!("a{i}")),
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
                loc: path(0, 0.0, "t.sv", 1).primary_loc.clone(),
            },
        );
        design.module_names.insert("alu".into(), 0);
        let mut p = path(41, -20.0, "alu.sv", 100);
        p.nodes = (0..8).collect();
        p.total_fo4 = 320.0;
        p.module = 0;
        design.paths.push(p.clone());
        classify_and_adjust_paths(&mut design, &CostModel::default(), None);
        // refresh path from design after classify
        let p = design.paths.iter().find(|x| x.id == 41).unwrap().clone();
        let plan = build_relocation_plan(&design);
        let ranked = RankedPaths {
            primary: vec![p.clone()],
            multi_cycle: vec![],
        };
        let opps = sv_timing_core::suggest_opportunities(&design);
        let work = order_worklist_with_plan(
            &ranked,
            &opps,
            &WorklistPolicy::default(),
            Some(&plan),
        );
        assert!(!work.is_empty());
        let w = &work[0];
        assert_eq!(w.path_id, 41);
        let opp = w.opportunity.as_ref().expect("opp");
        assert!(
            matches!(
                opp.kind,
                OpportunityKind::BalanceMux | OpportunityKind::SplitAssign
            ),
            "expected balance/split from relocation, got {:?}",
            opp.kind
        );
        assert!(
            w.relocation_option_id.is_some(),
            "should record relocation option id"
        );
    }
}
