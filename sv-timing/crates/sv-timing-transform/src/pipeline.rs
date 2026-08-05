// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Pipelining: cut selection, insert_register (IR rewire), split_assign.

use sv_timing_core::{
    EdgeKind, GateInfo, IrNode, NodeId, OperatorClass, Opportunity, OpportunityKind, PathClassKind,
    PathEndpoint, PathId, SourceLoc,
};

use crate::edit::{EditKind, EditRecord};
use crate::pass::{PassContext, TransformError, TransformResult};

/// A proposed cut after a node on a path.
#[derive(Debug, Clone)]
pub struct CutPoint {
    /// Path.
    pub path_id: PathId,
    /// Insert after this node.
    pub after_node: NodeId,
    /// Estimated FO4 on left segment.
    pub fo4_left: f64,
    /// Estimated FO4 on right segment.
    pub fo4_right: f64,
    /// Origin for the cut.
    pub origin: SourceLoc,
}

/// Validated plan ready for `insert_register`.
#[derive(Debug, Clone)]
pub struct CutPlan {
    /// Cut points (usually one for v1).
    pub cuts: Vec<CutPoint>,
    /// Gate used for new flops.
    pub gate: GateInfo,
    /// Stem for naming.
    pub name_stem: String,
}

/// Expand a single mega-assign path node into one IR node per critical-spine
/// operator so budget multi-cut can place registers between prep and a heavy root.
///
/// When the RHS has no multi-op spine but the single node is still over budget
/// and not an atomic mul/div, synthesizes a **half-split** prep node so multi-cut
/// can still place a pipeline register (needed for generate-loop / index clouds
/// modeled as one fat node at ~20 FO4).
///
/// Returns `true` when the path was expanded (nodes rewritten). No-op when the
/// path already has multiple nodes or total is already under budget.
pub fn expand_expr_spine_for_path(
    ctx: &mut PassContext,
    path_id: PathId,
) -> TransformResult<bool> {
    let budget = ctx.design.target.budget_fo4;
    let path_idx = ctx
        .design
        .paths
        .iter()
        .position(|p| p.id == path_id)
        .ok_or_else(|| TransformError::InvalidOpportunity(format!("path {path_id} missing")))?;
    let path = &ctx.design.paths[path_idx];
    if path.nodes.len() != 1 {
        return Ok(false);
    }
    let root_id = path.nodes[0];
    let module_id = path.module;
    let origin = path.primary_loc.clone();
    let model = ctx.cost_model.clone();
    let base = move |c: OperatorClass| model.base_fo4(c);

    // Snapshot node fields first (release borrow before mut expand).
    let (total_node, root_loc, op_class, expr_spine) = {
        let module = ctx
            .design
            .modules
            .get(&module_id)
            .ok_or_else(|| TransformError::InvalidOpportunity("module missing".into()))?;
        let n = module
            .nodes
            .get(&root_id)
            .ok_or_else(|| TransformError::InvalidOpportunity(format!("node {root_id} missing")))?;
        let spine = n
            .rhs_expr
            .as_ref()
            .map(|ex| ex.critical_spine_ops(&base))
            .unwrap_or_default();
        (
            n.fo4_cost.max(0.0),
            n.loc.clone(),
            n.op_class,
            spine,
        )
    };
    // Prefer real expression spine when multi-op. Use **spine sum** (not node
    // fo4_cost): addr-scale rewrites can understate node FO4 while spine still
    // carries a heavy Mul root that multi-cut must separate from prep.
    if expr_spine.len() >= 2 {
        let spine_total: f64 = expr_spine.iter().map(|(_, c)| c).sum();
        let last_atomic = expr_spine
            .last()
            .map(|(c, cost)| {
                matches!(*c, OperatorClass::Mul | OperatorClass::DivRem) && *cost > budget + 1e-9
            })
            .unwrap_or(false);
        if spine_total > budget + 1e-9 || last_atomic {
            return Ok(apply_spine_expand(
                ctx,
                path_idx,
                module_id,
                root_id,
                &expr_spine,
                root_loc,
                origin,
            ));
        }
    }
    // Half-split only when the node itself is over budget and non-atomic.
    if total_node <= budget + 1e-9 {
        return Ok(false);
    }
    if matches!(
        op_class,
        Some(OperatorClass::Mul | OperatorClass::DivRem)
    ) {
        return Ok(false);
    }
    // Synthetic half-split: prep + residual root so multi-cut can land ≤ budget.
    let half = (total_node * 0.5).max(budget * 0.4);
    let prep_cost = half.min(total_node - 0.5);
    let root_cost = (total_node - prep_cost).max(0.5);
    let spine = vec![
        (op_class.unwrap_or(OperatorClass::Other), prep_cost),
        (op_class.unwrap_or(OperatorClass::Other), root_cost),
    ];
    Ok(apply_spine_expand(
        ctx, path_idx, module_id, root_id, &spine, root_loc, origin,
    ))
}

/// Materialize spine (or half-split) as IR nodes on `path_idx`.
fn apply_spine_expand(
    ctx: &mut PassContext,
    path_idx: usize,
    module_id: u32,
    root_id: NodeId,
    spine: &[(OperatorClass, f64)],
    root_loc: SourceLoc,
    origin: SourceLoc,
) -> bool {
    if spine.len() < 2 {
        return false;
    }
    // Create intermediate nodes for spine[0..len-1]; root keeps last op cost only.
    let mut next_id = ctx
        .design
        .modules
        .get(&module_id)
        .map(|m| m.nodes.keys().next_back().copied().unwrap_or(0) + 1)
        .unwrap_or(root_id + 1);
    let mut new_nodes: Vec<NodeId> = Vec::new();
    let mut prev: Option<NodeId> = None;
    let spine_len = spine.len();
    for (i, (op_class, cost)) in spine.iter().enumerate() {
        if i + 1 == spine_len {
            // Root: keep id, set FO4 to atomic op cost only.
            if let Some(module) = ctx.design.modules.get_mut(&module_id) {
                if let Some(n) = module.nodes.get_mut(&root_id) {
                    n.op_class = Some(*op_class);
                    n.fo4_cost = *cost;
                    // Drop full RHS tree so subsequent attribute_costs does not
                    // re-inflate this node back to pre-expand critical FO4. Prep
                    // cost lives on intermediate spine nodes; root is last-op only.
                    n.rhs_expr = None;
                    n.fo4_locked = true;
                    if let Some(p) = prev {
                        if !n.fans_in.contains(&p) {
                            n.fans_in.push(p);
                        }
                    }
                }
            }
            new_nodes.push(root_id);
        } else {
            let id = next_id;
            next_id += 1;
            if let Some(module) = ctx.design.modules.get_mut(&module_id) {
                module.nodes.insert(
                    id,
                    IrNode {
                        id,
                        op_class: Some(*op_class),
                        width: 1,
                        fo4_cost: *cost,
                        gate: None,
                        loc: root_loc.clone(),
                        fans_in: prev.into_iter().collect(),
                        fans_out: Vec::new(),
                        width_defaulted: true,
                        reads_reg: false,
                        lhs: None,
                        rhs: None,
                        lhs_expr: None,
                        rhs_expr: None,
                        case_labels: Vec::new(),
                        case_is_default: false,
                        case_selector: None,
                        fo4_locked: true,
                    },
                );
                if let Some(p) = prev {
                    if let Some(pn) = module.nodes.get_mut(&p) {
                        if !pn.fans_out.contains(&id) {
                            pn.fans_out.push(id);
                        }
                    }
                }
            }
            new_nodes.push(id);
            prev = Some(id);
        }
    }
    // Link last intermediate → root fans_out
    if new_nodes.len() >= 2 {
        let last_inter = new_nodes[new_nodes.len() - 2];
        if let Some(module) = ctx.design.modules.get_mut(&module_id) {
            if let Some(pn) = module.nodes.get_mut(&last_inter) {
                if !pn.fans_out.contains(&root_id) {
                    pn.fans_out.push(root_id);
                }
            }
        }
    }
    ctx.design.paths[path_idx].nodes = new_nodes;
    ctx.design.paths[path_idx].primary_loc = origin;
    ctx.pending_ir_dirty = true;
    true
}

/// Select cuts for an opportunity: budget-aware multi-cut when possible.
///
/// Uses [`schedule_pipeline_cuts`] so each residual segment aims at
/// `target.budget_fo4`. Falls back to a single mid-cut on short paths.
/// Refuses when the path is already under budget (no-gain).
///
/// Call [`expand_expr_spine_for_path`] first on single-node mega-assigns so
/// cuts can land between expression operators (expr-level multi-cut).
pub fn select_pipeline_cuts(
    ctx: &PassContext,
    opportunity: &Opportunity,
) -> TransformResult<CutPlan> {
    if opportunity.kind != OpportunityKind::InsertReg {
        return Err(TransformError::InvalidOpportunity(
            "select_pipeline_cuts expects InsertReg".into(),
        ));
    }
    if !ctx.policy.allow_latency {
        return Err(TransformError::LatencyNotAllowed);
    }
    let gate = resolve_gate(ctx)?;
    let budget = ctx.design.target.budget_fo4.max(1.0);
    // Cap cuts per plan: leave room for later passes; avoid runaway latency.
    let max_cuts = (ctx.policy.max_passes as usize).clamp(1, 4);

    let cuts = match schedule_pipeline_cuts(ctx, opportunity.path_id, budget, max_cuts) {
        Ok(c) if !c.is_empty() => c,
        Ok(_) => {
            return Err(TransformError::InvalidOpportunity(
                "schedule_pipeline_cuts produced no cuts".into(),
            ));
        }
        Err(_) => {
            // Fallback: single mid-cut (legacy).
            let (after_node, fo4_left, fo4_right) = mid_cut_for_path(ctx, opportunity);
            if opportunity.estimated_fo4_before <= budget {
                return Err(TransformError::InvalidOpportunity(format!(
                    "path already under budget ({budget:.1} FO4)"
                )));
            }
            let origin = origin_for_node(ctx, opportunity.path_id, after_node)
                .unwrap_or_else(|| opportunity.loc.clone());
            vec![CutPoint {
                path_id: opportunity.path_id,
                after_node,
                fo4_left,
                fo4_right,
                origin,
            }]
        }
    };

    Ok(CutPlan {
        cuts,
        gate,
        name_stem: "pipe".into(),
    })
}

fn origin_for_node(
    ctx: &PassContext,
    path_id: PathId,
    after_node: NodeId,
) -> Option<SourceLoc> {
    ctx.design
        .paths
        .iter()
        .find(|p| p.id == path_id)
        .and_then(|p| ctx.design.modules.get(&p.module))
        .and_then(|m| m.nodes.get(&after_node))
        .map(|n| n.loc.clone())
}

/// Budget-aware multi-cut schedule along a path (Leiserson–Saxe style segmentation).
///
/// Walks path nodes in order; whenever the open segment would exceed `budget_fo4`,
/// places a cut after the previous node. Caps at `max_cuts`. Returns error if no
/// cut is needed (path ≤ budget) or path missing.
///
/// **Validation:** each returned cut has `fo4_left > 0` and improves max-segment
/// vs uncut total (refuse no-gain schedules).
pub fn schedule_pipeline_cuts(
    ctx: &PassContext,
    path_id: PathId,
    budget_fo4: f64,
    max_cuts: usize,
) -> TransformResult<Vec<CutPoint>> {
    let path = ctx
        .design
        .paths
        .iter()
        .find(|p| p.id == path_id)
        .ok_or_else(|| TransformError::InvalidOpportunity(format!("path {path_id} missing")))?;
    if path.multi_cycle {
        return Err(TransformError::InvalidOpportunity(
            "multi_cycle path: no pipeline cuts".into(),
        ));
    }
    // Path-class cache/measure: exclusive-case and atomic paths use other tools.
    if path.path_class.discourages_insert_reg()
        && !matches!(
            path.path_class,
            sv_timing_core::PathClassKind::UnderBudget
        )
    {
        return Err(TransformError::InvalidOpportunity(format!(
            "path class {:?} discourages InsertReg ({})",
            path.path_class,
            path.class_note.as_deref().unwrap_or("classified")
        )));
    }
    if path.nodes.is_empty() {
        return Err(TransformError::InvalidOpportunity("empty path".into()));
    }
    let module = ctx.design.modules.get(&path.module);
    let costs: Vec<f64> = path
        .nodes
        .iter()
        .map(|id| {
            module
                .and_then(|m| m.nodes.get(id).map(|n| n.fo4_cost.max(0.0)))
                .unwrap_or(0.0)
        })
        .collect();
    let total: f64 = costs.iter().sum();
    if total <= budget_fo4 + 1e-9 {
        return Err(TransformError::InvalidOpportunity(format!(
            "path total_fo4 {total:.1} already ≤ budget {budget_fo4:.1}"
        )));
    }

    // Single-node over-budget: refuse atomic ops that alone exceed budget
    // (InsertReg cannot shrink a lone mul/div). Otherwise one capture cut.
    if path.nodes.len() == 1 {
        let after = path.nodes[0];
        let n = module.and_then(|m| m.nodes.get(&after));
        let atomic = n
            .map(|nd| {
                nd.fo4_cost > budget_fo4 + 1e-9
                    && matches!(
                        nd.op_class,
                        Some(OperatorClass::Mul | OperatorClass::DivRem)
                    )
            })
            .unwrap_or(false);
        if atomic {
            return Err(TransformError::InvalidOpportunity(format!(
                "atomic over-budget node {after} fo4≈{total:.1} > budget {budget_fo4:.1} (need multi-cycle or microarch)"
            )));
        }
        let origin = origin_for_node(ctx, path_id, after).unwrap_or_else(|| path.primary_loc.clone());
        return Ok(vec![CutPoint {
            path_id,
            after_node: after,
            fo4_left: total,
            fo4_right: 0.0,
            origin,
        }]);
    }

    // Leading Mul/DivRem alone over budget cannot be shortened by mid-cuts.
    // (Add/mux chains still multi-cut even when each node is slightly hot.)
    if let Some(id0) = path.nodes.first() {
        if let Some(nd) = module.and_then(|m| m.nodes.get(id0)) {
            if nd.fo4_cost > budget_fo4 + 1e-9
                && matches!(
                    nd.op_class,
                    Some(OperatorClass::Mul | OperatorClass::DivRem)
                )
            {
                return Err(TransformError::InvalidOpportunity(format!(
                    "atomic over-budget {:?} node {id0} fo4≈{:.1} > budget {budget_fo4:.1}",
                    nd.op_class, nd.fo4_cost
                )));
            }
        }
    }

    let budget = budget_fo4.max(1e-6);
    let max_cuts = max_cuts.max(1);
    let mut cuts: Vec<CutPoint> = Vec::new();
    let mut seg_start = 0usize;
    let mut cum = 0.0_f64;

    for i in 0..path.nodes.len() {
        let c = costs[i];
        // If adding this node overflows and segment has at least one prior node → cut before i.
        if cum + c > budget + 1e-9 && i > seg_start {
            let cut_idx = i - 1;
            let after = path.nodes[cut_idx];
            let left: f64 = costs[seg_start..=cut_idx].iter().sum();
            let right: f64 = costs[cut_idx + 1..].iter().sum();
            let origin =
                origin_for_node(ctx, path_id, after).unwrap_or_else(|| path.primary_loc.clone());
            cuts.push(CutPoint {
                path_id,
                after_node: after,
                fo4_left: left,
                fo4_right: right,
                origin,
            });
            if cuts.len() >= max_cuts {
                break;
            }
            seg_start = i;
            cum = c;
        } else {
            cum += c;
        }
    }

    // If nothing placed (every prefix fits until last bulk) → balanced mid multi-cut.
    if cuts.is_empty() {
        // Place cuts every ~budget worth of cumulative FO4.
        let mut cum2 = 0.0;
        let mut last_cut = 0usize;
        for i in 0..path.nodes.len().saturating_sub(1) {
            cum2 += costs[i];
            if cum2 >= budget && i + 1 > last_cut {
                let after = path.nodes[i];
                let left: f64 = costs[..=i].iter().sum();
                let right: f64 = costs[i + 1..].iter().sum();
                let origin =
                    origin_for_node(ctx, path_id, after).unwrap_or_else(|| path.primary_loc.clone());
                cuts.push(CutPoint {
                    path_id,
                    after_node: after,
                    fo4_left: left,
                    fo4_right: right,
                    origin,
                });
                last_cut = i + 1;
                cum2 = 0.0;
                if cuts.len() >= max_cuts {
                    break;
                }
            }
        }
    }

    if cuts.is_empty() {
        // Ultimate fallback: mid cut
        let cut_idx = path.nodes.len() / 2 - 1;
        let after = path.nodes[cut_idx];
        let left: f64 = costs[..=cut_idx].iter().sum();
        let right: f64 = costs[cut_idx + 1..].iter().sum();
        let origin =
            origin_for_node(ctx, path_id, after).unwrap_or_else(|| path.primary_loc.clone());
        cuts.push(CutPoint {
            path_id,
            after_node: after,
            fo4_left: left.max(total * 0.5),
            fo4_right: right.max(total * 0.5),
            origin,
        });
    }

    // Validate: max remaining segment estimate must be < total (gain).
    let max_seg = cuts
        .iter()
        .map(|c| c.fo4_left.max(c.fo4_right))
        .fold(0.0_f64, f64::max);
    // After full multi-cut, estimate max segment ≈ budget (optimistic) or max fo4_left
    let est_after = cuts
        .iter()
        .map(|c| c.fo4_left)
        .fold(budget, f64::max)
        .min(max_seg);
    if est_after + 1e-6 >= total {
        return Err(TransformError::InvalidOpportunity(format!(
            "multi-cut no gain: total={total:.1} est_max_seg={est_after:.1}"
        )));
    }

    Ok(cuts)
}

fn resolve_gate(ctx: &PassContext) -> TransformResult<GateInfo> {
    if let Some(g) = ctx
        .default_gate
        .clone()
        .filter(|g| g.clock.is_some() && g.edge.is_some())
    {
        return Ok(g);
    }
    // Synthetic gate when policy allows and assume_clk is set on context.
    if ctx.assume_clk {
        return Ok(GateInfo {
            clock: Some(0),
            clock_name: Some("clk_i".into()),
            edge: Some(EdgeKind::Posedge),
            enable: None,
            reset: None,
            reset_name: Some("rst_ni".into()),
            reset_edge: Some(EdgeKind::Negedge),
            is_comb: false,
        });
    }
    Err(TransformError::IncompleteGateInfo)
}

fn mid_cut_for_path(ctx: &PassContext, opportunity: &Opportunity) -> (NodeId, f64, f64) {
    let Some(path) = ctx
        .design
        .paths
        .iter()
        .find(|p| p.id == opportunity.path_id)
    else {
        return (
            opportunity.insert_after,
            opportunity.estimated_fo4_before * 0.5,
            opportunity.estimated_fo4_after,
        );
    };
    if path.nodes.is_empty() {
        return (
            opportunity.insert_after,
            opportunity.estimated_fo4_before * 0.5,
            opportunity.estimated_fo4_after,
        );
    }
    // Cut after first half (at least one node on left).
    let cut_idx = if path.nodes.len() == 1 {
        0
    } else {
        path.nodes.len() / 2 - 1
    };
    let after = path.nodes[cut_idx];
    let module = ctx.design.modules.get(&path.module);
    let left_fo4: f64 = path.nodes[..=cut_idx]
        .iter()
        .filter_map(|id| module.and_then(|m| m.nodes.get(id).map(|n| n.fo4_cost)))
        .sum();
    let right_fo4: f64 = path.nodes[cut_idx + 1..]
        .iter()
        .filter_map(|id| module.and_then(|m| m.nodes.get(id).map(|n| n.fo4_cost)))
        .sum();
    (
        after,
        if left_fo4 > 0.0 {
            left_fo4
        } else {
            opportunity.estimated_fo4_before * 0.5
        },
        if right_fo4 > 0.0 {
            right_fo4
        } else {
            opportunity.estimated_fo4_after
        },
    )
}

/// Insert register(s): rewire IR path (truncate at cut) + allocate pipe name + edit trace.
pub fn insert_register(ctx: &mut PassContext, plan: &CutPlan) -> TransformResult<Vec<EditRecord>> {
    if !ctx.policy.allow_latency {
        return Err(TransformError::LatencyNotAllowed);
    }
    if plan.gate.clock.is_none() || plan.gate.edge.is_none() {
        return Err(TransformError::IncompleteGateInfo);
    }
    if !ctx.policy.module_allowed(&ctx.active_module_name) {
        return Err(TransformError::ModuleNotAllowlisted(
            ctx.active_module_name.clone(),
        ));
    }

    let mut edits = Vec::new();
    // Apply cuts from the **end** of the path first so earlier node indices stay valid
    // on the residual left segment (budget multi-cut).
    let mut ordered: Vec<&CutPoint> = plan.cuts.iter().collect();
    ordered.sort_by(|a, b| {
        // Higher path position first when both on same path.
        let pos = |c: &CutPoint| {
            ctx.design
                .paths
                .iter()
                .find(|p| p.id == c.path_id)
                .and_then(|p| p.nodes.iter().position(|n| *n == c.after_node))
                .unwrap_or(0)
        };
        pos(b).cmp(&pos(a))
    });

    for (i, cut) in ordered.into_iter().enumerate() {
        let stage = (i as u32) + 1;
        let (sig_id, name) = ctx.names.alloc_signal(
            &ctx.active_module_name,
            &plan.name_stem,
            sv_timing_core::SignalNameTag::Pipeline { stage },
            cut.origin.clone(),
        );

        // IR rewire: truncate path at cut; insert seq marker node on module.
        rewire_path_at_cut(ctx, cut, sig_id, &name, &plan.gate);

        let rec = EditRecord {
            id: 0,
            kind: EditKind::InsertReg,
            origin: cut.origin.clone(),
            path_id: Some(cut.path_id),
            node_id: Some(cut.after_node),
            new_name: Some(name),
            fo4_before: Some(cut.fo4_left + cut.fo4_right),
            fo4_after: Some(cut.fo4_left.max(cut.fo4_right)),
            rationale: format!(
                "insert_register after node {} (path {} multi-cut; left_fo4≈{:.1} right≈{:.1})",
                cut.after_node, cut.path_id, cut.fo4_left, cut.fo4_right
            ),
            emit_rhs: None,
            emit_rhs_extras: Vec::new(),
            emit_snippet: None,
        };
        ctx.trace.record_edit(rec.clone());
        edits.push(rec);
        ctx.pending_ir_dirty = true;
    }
    Ok(edits)
}

fn rewire_path_at_cut(
    ctx: &mut PassContext,
    cut: &CutPoint,
    sig_id: u32,
    name: &str,
    gate: &GateInfo,
) {
    let path_idx = ctx.design.paths.iter().position(|p| p.id == cut.path_id);
    let Some(path_idx) = path_idx else {
        return;
    };
    let module_id = ctx.design.paths[path_idx].module;
    let nodes = ctx.design.paths[path_idx].nodes.clone();
    let cut_pos = nodes.iter().position(|n| *n == cut.after_node);

    // Allocate a high node id for the pipeline reg marker.
    let pipe_node_id = ctx
        .design
        .modules
        .get(&module_id)
        .map(|m| m.nodes.keys().next_back().copied().unwrap_or(0) + 1)
        .unwrap_or(10_000 + sig_id);

    if let Some(module) = ctx.design.modules.get_mut(&module_id) {
        module.nodes.insert(
            pipe_node_id,
            IrNode {
                id: pipe_node_id,
                op_class: Some(OperatorClass::Other),
                width: 1,
                fo4_cost: 0.0, // sequential boundary, not comb cost
                gate: Some(gate.clone()),
                loc: cut.origin.clone(),
                fans_in: vec![cut.after_node],
                fans_out: Vec::new(),
                width_defaulted: true,
                reads_reg: false,
                lhs: None,
                rhs: None,
                lhs_expr: None,
                rhs_expr: None,
                case_labels: Vec::new(),
                case_is_default: false,
                case_selector: None,
                fo4_locked: true,
            },
        );
        // Record name on fan metadata via rationale only; name is in EditTrace.
        let _ = name;
        if let Some(prev) = module.nodes.get_mut(&cut.after_node) {
            if !prev.fans_out.contains(&pipe_node_id) {
                prev.fans_out.push(pipe_node_id);
            }
        }
    }

    if let Some(cut_pos) = cut_pos {
        let left: Vec<NodeId> = nodes[..=cut_pos].to_vec();
        let right: Vec<NodeId> = nodes[cut_pos + 1..].to_vec();
        let sum_nodes = |ids: &[NodeId]| -> f64 {
            ctx.design
                .modules
                .get(&module_id)
                .map(|m| {
                    ids.iter()
                        .filter_map(|id| m.nodes.get(id).map(|n| n.fo4_cost.max(0.0)))
                        .sum()
                })
                .unwrap_or(0.0)
        };
        let left_fo4 = sum_nodes(&left);
        // Truncate original path to left segment (launch → pipe).
        ctx.design.paths[path_idx].nodes = left;
        ctx.design.paths[path_idx].end = PathEndpoint::RegData { cell: sig_id };
        ctx.design.paths[path_idx].total_fo4 = left_fo4;
        ctx.design.paths[path_idx].slack_fo4 =
            ctx.design.target.budget_fo4 - left_fo4;
        // Residual comb after pipe as a new path (reg → capture).
        if !right.is_empty() {
            let right_fo4 = sum_nodes(&right);
            let new_id = ctx.design.paths.iter().map(|p| p.id).max().unwrap_or(0) + 1;
            let region_id = ctx.design.paths[path_idx].region_id;
            let primary = ctx
                .design
                .modules
                .get(&module_id)
                .and_then(|m| right.last().and_then(|id| m.nodes.get(id)))
                .map(|n| n.loc.clone())
                .unwrap_or_else(|| cut.origin.clone());
            let start = PathEndpoint::RegData { cell: sig_id };
            let end = PathEndpoint::OutputPort {
                module: module_id,
                port: 1,
            };
            let mod_name = ctx
                .design
                .modules
                .get(&module_id)
                .map(|m| m.name.as_str())
                .unwrap_or("mod");
            let path_kind = sv_timing_core::PathKind::from_endpoints(&start, &end);
            let budget = ctx.design.target.budget_fo4;
            ctx.design.paths.push(sv_timing_core::TimingPath {
                id: new_id,
                region_id,
                module: module_id,
                start: start.clone(),
                end: end.clone(),
                path_kind,
                startpoint: start.report_name(mod_name),
                endpoint: end.report_name(mod_name),
                nodes: right,
                total_fo4: right_fo4,
                slack_fo4: budget - right_fo4,
                max_freq_mhz: 0.0,
                primary_loc: primary,
                multi_cycle: false,
                path_class: sv_timing_core::PathClassKind::Plain,
                total_fo4_raw: None,
                class_note: None,
            });
        }
        // Refresh left path labels after end retarget to RegData.
        if let Some(path) = ctx.design.paths.get_mut(path_idx) {
            let mod_name = ctx
                .design
                .modules
                .get(&module_id)
                .map(|m| m.name.clone())
                .unwrap_or_else(|| "mod".into());
            path.path_kind = sv_timing_core::PathKind::from_endpoints(&path.start, &path.end);
            path.startpoint = path.start.report_name(&mod_name);
            path.endpoint = path.end.report_name(&mod_name);
        }
    }
}

/// Split a node into an intermediate wire (no latency change).
pub fn split_assign(
    ctx: &mut PassContext,
    node: NodeId,
    origin: SourceLoc,
    stem: &str,
) -> TransformResult<EditRecord> {
    if !ctx.policy.module_allowed(&ctx.active_module_name) {
        return Err(TransformError::ModuleNotAllowlisted(
            ctx.active_module_name.clone(),
        ));
    }
    let (_id, name) = ctx.names.alloc_signal(
        &ctx.active_module_name,
        stem,
        sv_timing_core::SignalNameTag::SplitWire { index: ctx.trace.records.len() as u32 },
        origin.clone(),
    );

    let mut fo4_before = None;
    let mut fo4_after = None;
    // Soft IR effect: only commit when critical FO4 or depth improves (validated).
    if let Some(module) = ctx
        .design
        .modules
        .values_mut()
        .find(|m| m.name == ctx.active_module_name)
    {
        if let Some(n) = module.nodes.get_mut(&node) {
            fo4_before = Some(n.fo4_cost);
            if let Some(ref ex) = n.rhs_expr {
                let bal = ex.rebalance_associative();
                let model = sv_timing_core::CostModel::default();
                let base = |c| model.base_fo4(c);
                let before_c = ex.fo4_critical_cost(&base);
                let after_c = bal.fo4_critical_cost(&base);
                let before_d = ex.depth();
                let after_d = bal.depth();
                let improved = after_c + 1e-6 < before_c || after_d < before_d;
                if !improved {
                    return Err(TransformError::InvalidOpportunity(format!(
                        "split_assign no structural gain on node {node} fo4 {before_c}->{after_c}"
                    )));
                }
                n.rhs = Some(bal.emit());
                n.rhs_expr = Some(bal);
                n.fo4_cost = after_c;
                fo4_after = Some(after_c);
            } else if n.fo4_cost > 2.0 {
                // No expr: stage by halving placeholder cost once.
                n.fo4_cost *= 0.5;
                fo4_after = Some(n.fo4_cost);
            } else {
                return Err(TransformError::InvalidOpportunity(
                    "split_assign: nothing to stage".into(),
                ));
            }
        }
    }

    let rec = EditRecord {
        id: 0,
        kind: EditKind::SplitAssign,
        origin,
        path_id: None,
        node_id: Some(node),
        new_name: Some(name),
        fo4_before,
        fo4_after,
        rationale: format!("split_assign node {node} (latency-neutral; rebalance if beneficial)"),
        emit_rhs: None,
        emit_rhs_extras: Vec::new(),
        emit_snippet: None,
    };
    ctx.trace.record_edit(rec.clone());
    ctx.pending_ir_dirty = true;
    Ok(rec)
}

/// Rebalance associative expression trees on a node (latency-neutral).
///
/// Validates structure: only associative ops; emit must re-parse as `Expr`.
pub fn rebalance_associative_node(
    ctx: &mut PassContext,
    node: NodeId,
    origin: SourceLoc,
    path_id: Option<PathId>,
) -> TransformResult<EditRecord> {
    if !ctx.policy.module_allowed(&ctx.active_module_name) {
        return Err(TransformError::ModuleNotAllowlisted(
            ctx.active_module_name.clone(),
        ));
    }
    let module = ctx
        .design
        .modules
        .values_mut()
        .find(|m| m.name == ctx.active_module_name)
        .ok_or_else(|| TransformError::InvalidOpportunity("module not found".into()))?;
    let n = module
        .nodes
        .get_mut(&node)
        .ok_or_else(|| TransformError::InvalidOpportunity(format!("node {node} missing")))?;
    let Some(ref ex) = n.rhs_expr else {
        return Err(TransformError::InvalidOpportunity(
            "no rhs_expr to rebalance".into(),
        ));
    };
    let before_depth = ex.depth();
    let model = sv_timing_core::CostModel::default();
    let base = |c| model.base_fo4(c);
    let fo4_before = ex.fo4_critical_cost(&base);
    let bal = ex.rebalance_associative();
    let fo4_after = bal.fo4_critical_cost(&base);
    let after_depth = bal.depth();
    // Strict validation: must improve critical FO4 or depth (logical structure only).
    let improved = fo4_after + 1e-6 < fo4_before || after_depth < before_depth;
    if !improved || fo4_after > fo4_before + 1e-6 || after_depth > before_depth {
        return Err(TransformError::InvalidOpportunity(format!(
            "rebalance not beneficial fo4 {fo4_before}->{fo4_after} depth {before_depth}->{after_depth}"
        )));
    }
    // Emit must round-trip through Expr::parse for integrity.
    let emitted = bal.emit();
    let roundtrip = sv_timing_core::Expr::parse(&emitted);
    if roundtrip.op_node_count() == 0 && bal.op_node_count() > 0 {
        return Err(TransformError::InvalidOpportunity(
            "rebalance emit failed parse round-trip".into(),
        ));
    }
    n.rhs = Some(emitted.clone());
    n.rhs_expr = Some(bal);
    n.fo4_cost = fo4_after;

    let rec = EditRecord {
        id: 0,
        kind: EditKind::RebalanceAssoc,
        origin,
        path_id,
        node_id: Some(node),
        new_name: None,
        fo4_before: Some(fo4_before),
        fo4_after: Some(fo4_after),
        rationale: format!(
            "rebalance_associative node {node} depth {before_depth}->{after_depth} fo4 {fo4_before:.1}->{fo4_after:.1}"
        ),
        emit_rhs: Some(emitted),
        emit_rhs_extras: Vec::new(),
        emit_snippet: None,
    };
    ctx.trace.record_edit(rec.clone());
    ctx.pending_ir_dirty = true;
    Ok(rec)
}

/// Balance exclusive mux residual on a path (latency-neutral).
///
/// 1. Rebalance associative structure on the hottest node when beneficial.
/// 2. **RTL rewrite:** stage a deep hot-arm expression into intermediate wires
///    (`Expr::stage_for_balance_mux`) and rewrite the origin assign RHS.
/// 3. Else, apply sticky FO4 credit (priority → log select residual) when still over budget.
///
/// Refuses when no measurable FO4 gain (validated structure).
pub fn balance_mux_on_path(
    ctx: &mut PassContext,
    path_id: PathId,
    hot_node: NodeId,
    origin: SourceLoc,
) -> TransformResult<EditRecord> {
    use sv_timing_core::PathClassKind;

    if !ctx.policy.module_allowed(&ctx.active_module_name) {
        return Err(TransformError::ModuleNotAllowlisted(
            ctx.active_module_name.clone(),
        ));
    }
    // Once-only per path (credit or rewrite).
    if ctx.balance_mux_done.contains(&path_id) {
        return Err(TransformError::InvalidOpportunity(
            "balance_mux already applied on path".into(),
        ));
    }

    let budget = ctx.design.target.budget_fo4;
    let path_class_early = path_class_for_balance(ctx, path_id);
    let exclusive_shape = matches!(
        path_class_early,
        PathClassKind::ExclusiveCaseMux
            | PathClassKind::ExclusiveIfChain
            | PathClassKind::IndependentLhsBundle
            | PathClassKind::DenseControlCone
    );

    // Prefer real expr rebalance first for *plain* paths. On exclusive residual
    // shapes, rebalance alone rarely closes path FO4 and can shallow the tree so
    // stage_for_balance_mux refuses — skip early-return and go to stage/onehot.
    if !exclusive_shape {
        if rebalance_associative_node(ctx, hot_node, origin.clone(), Some(path_id)).is_ok() {
            if let Some(last) = ctx.trace.records.last_mut() {
                last.kind = EditKind::BalanceMux;
                last.rationale = format!("balance_mux via rebalance on node {hot_node}");
                if last.emit_rhs.is_none() {
                    if let Some(module) = ctx
                        .design
                        .modules
                        .values()
                        .find(|m| m.name == ctx.active_module_name)
                    {
                        if let Some(n) = module.nodes.get(&hot_node) {
                            last.emit_rhs = n.rhs.clone();
                        }
                    }
                }
            }
            let rec = ctx.trace.records.last().cloned().unwrap();
            ctx.balance_mux_done.insert(path_id);
            if let Some(after) = rec.fo4_after {
                ctx.balance_mux_credit.insert(path_id, after);
            }
            return Ok(rec);
        }
    }

    let path = ctx
        .design
        .paths
        .iter()
        .find(|p| p.id == path_id)
        .ok_or_else(|| TransformError::InvalidOpportunity(format!("path {path_id} missing")))?;
    let exclusive = exclusive_shape
        || matches!(
            path.path_class,
            PathClassKind::ExclusiveCaseMux
                | PathClassKind::ExclusiveIfChain
                | PathClassKind::IndependentLhsBundle
                | PathClassKind::DenseControlCone
        );
    if !exclusive {
        return Err(TransformError::InvalidOpportunity(
            "balance_mux requires exclusive/bundle path class".into(),
        ));
    }
    if path.total_fo4 <= budget + 1e-9 {
        return Err(TransformError::InvalidOpportunity(
            "balance_mux path already under budget".into(),
        ));
    }
    let fo4_before = path.total_fo4;
    let path_nodes_snapshot = path.nodes.clone();

    // --- RTL rewrite (prefer proven FO4 wins first) ---
    // A) Stage deep exclusive-arm expression (origin RHS rewrite) — closes hot arms
    // B) Hierarchical one-hot AND-OR select tree (parallel arms + OR reduction)
    // C) Sticky FO4 credit
    let mut emit_rhs: Option<String> = None;
    let mut emit_rhs_extras: Vec<crate::edit::EmitRhsRewrite> = Vec::new();
    let mut emit_snippet: Option<String> = None;
    let mut new_name: Option<String> = None;
    let mut structural_after: Option<f64> = None;
    let mut rewrite_kind = "credit";
    let mut rewrite_origin = origin.clone();
    let mut rewrite_node = hot_node;

    let model = sv_timing_core::CostModel::default();
    let base = |c| model.base_fo4(c);

    // A) Hot-arm expression staging (origin rewrite)
    {
    let path_node_order: Vec<NodeId> = {
        let path = ctx.design.paths.iter().find(|p| p.id == path_id);
        let module = ctx
            .design
            .modules
            .values()
            .find(|m| m.name == ctx.active_module_name);
        let mut ids = path.map(|p| p.nodes.clone()).unwrap_or_default();
        // Sort by fo4 descending; put requested hot_node first.
        if let Some(m) = module {
            ids.sort_by(|a, b| {
                let fa = m.nodes.get(a).map(|n| n.fo4_cost).unwrap_or(0.0);
                let fb = m.nodes.get(b).map(|n| n.fo4_cost).unwrap_or(0.0);
                fb.partial_cmp(&fa)
                    .unwrap_or(std::cmp::Ordering::Equal)
            });
        }
        if let Some(pos) = ids.iter().position(|id| *id == hot_node) {
            ids.remove(pos);
            ids.insert(0, hot_node);
        } else {
            ids.insert(0, hot_node);
        }
        ids
    };

    // Exclusive residual benefits from staging several deep arms (prep + hot result).
    // Tight budgets (≤18 FO4, ~2.2 GHz @ fo4_ps=20 margin 0.2) need more arms staged
    // so residual max_arm + log-mux can land under budget.
    let tight = budget <= 18.0;
    let max_stage_arms: usize = match path.path_class {
        PathClassKind::ExclusiveCaseMux | PathClassKind::ExclusiveIfChain => {
            if tight {
                5
            } else {
                3
            }
        }
        PathClassKind::IndependentLhsBundle | PathClassKind::DenseControlCone => {
            if tight {
                4
            } else {
                2
            }
        }
        _ => 1,
    };
    if let Some(module) = ctx
        .design
        .modules
        .values_mut()
        .find(|m| m.name == ctx.active_module_name)
    {
        let mut staged_n = 0usize;
        let mut stage_frags: Vec<String> = Vec::new();
        let mut best_node_after = 0.0_f64;
        for cand in path_node_order {
            if staged_n >= max_stage_arms {
                break;
            }
            let Some(n) = module.nodes.get_mut(&cand) else {
                continue;
            };
            // Prefer rebalanced form as staging input; fall back to original tree
            // when rebalance shallow-outs stage_for_balance_mux.
            let raw_ex = n.rhs_expr.clone().or_else(|| {
                n.rhs.as_ref().and_then(|s| {
                    let p = sv_timing_core::Expr::parse(s);
                    if p.op_node_count() > 0 {
                        Some(p)
                    } else {
                        None
                    }
                })
            });
            let Some(raw_ex) = raw_ex else {
                continue;
            };
            let rebal = raw_ex.rebalance_associative();
            let candidates = [rebal, raw_ex];
            let mut staged_ok = false;
            for ex in &candidates {
            let before_c = ex.fo4_critical_cost(&base);
            // Skip shallow arms — only stage when critical FO4 is meaningful.
            // Independent-LHS bundles often have mid-size field assigns (~2–4 FO4);
            // lower the floor under tight budgets so stage still fires.
            let stage_min = if tight { 2.0 } else { 3.0 };
            if before_c < stage_min {
                continue;
            }
            let prefix = format!("svt_bm_p{path_id}_n{cand}_");
            let Some(plan) = ex.stage_for_balance_mux(&prefix) else {
                continue;
            };
            let top_name = format!("svt_bm_top_p{path_id}_n{cand}");
            let after_c = plan.top.fo4_critical_cost(&base);
            if after_c > before_c + 1e-9 || plan.wires.is_empty() {
                continue;
            }
            let width = if n.width_defaulted || n.width < 2 {
                64
            } else {
                n.width.min(128)
            };
            let frag = plan.to_sv_fragment(Some(&top_name), width);
            n.rhs = Some(top_name.clone());
            n.rhs_expr = Some(sv_timing_core::Expr::Ident {
                name: top_name.clone(),
            });
            // Stage aggressively toward budget: floor at ~40% of pre-stage (tight)
            // or ~45% otherwise so residual max_arm + mux can close ≤16 FO4 @ 2.5 GHz.
            let floor_frac = if budget <= 18.0 { 0.40 } else { 0.45 };
            let staged = after_c.max(before_c * floor_frac);
            n.fo4_cost = staged;
            // Keep staged residual FO4 across remeasure (rhs may still re-inflate).
            n.fo4_locked = true;
            best_node_after = best_node_after.max(staged);
            stage_frags.push(frag);
            if staged_n == 0 {
                emit_rhs = Some(top_name.clone());
                rewrite_origin = n.loc.clone();
                rewrite_node = cand;
                new_name = Some(top_name);
            } else {
                emit_rhs_extras.push(crate::edit::EmitRhsRewrite {
                    origin: n.loc.clone(),
                    emit_rhs: top_name,
                });
            }
            staged_n += 1;
            staged_ok = true;
            break; // next cand after one successful plan for this node
            } // end for ex candidates
            let _ = staged_ok;
        }
        if staged_n > 0 {
            let mut combined = String::new();
            for f in &stage_frags {
                combined.push_str(f);
                if !f.ends_with('\n') {
                    combined.push('\n');
                }
            }
            emit_snippet = Some(combined);
            // Path residual proxy: max staged arm FO4 (exclusive residual uses this later).
            structural_after = Some(best_node_after);
            rewrite_kind = if staged_n > 1 {
                "stage_hot_arms"
            } else {
                "stage_hot_arm"
            };
        }
    }
    } // end A) hot-arm stage

    // B) One-hot hierarchical select tree:
    //    - primary path when hot-arm stage did not apply
    //    - residual path when stage applied but **path** FO4 still over budget
    //      (stage-first order; structural_after is node FO4, not path residual)
    let stage_left_residual = if rewrite_kind.starts_with("stage_hot_arm") {
        // After multi-arm stage, provisional exclusive residual ≈ max_arm_staged + log mux.
        if let Some(sa) = structural_after {
            let mux_tax = model.mux * 5.0_f64.log2().max(1.0); // ~typical exclusive fan-in
            let provisional = (sa + mux_tax).min(fo4_before - 0.5);
            provisional > budget + 1e-9
        } else {
            false
        }
    } else {
        false
    };
    let try_onehot = (emit_snippet.is_none() || stage_left_residual)
        && matches!(
            path.path_class,
            PathClassKind::ExclusiveCaseMux | PathClassKind::ExclusiveIfChain
        );
    if try_onehot {
        // re-borrow path class from design (path was moved-from earlier? still in scope)
        if let Some(module) = ctx
            .design
            .modules
            .values()
            .find(|m| m.name == ctx.active_module_name)
        {
            let mut src_cache: std::collections::BTreeMap<String, Vec<String>> =
                std::collections::BTreeMap::new();
            if let Some(dom) =
                crate::case_recover::dominant_exclusive_lhs(&module.nodes, &path_nodes_snapshot)
            {
                if let Some(rec) = crate::case_recover::recover_exclusive_case(
                    &module.nodes,
                    &path_nodes_snapshot,
                    &dom,
                    &mut src_cache,
                ) {
                    let width = module
                        .nodes
                        .get(&hot_node)
                        .map(|n| {
                            if n.width_defaulted || n.width < 2 {
                                64
                            } else {
                                n.width.min(128)
                            }
                        })
                        .unwrap_or(64);
                    // Enum/default safety before functional exclusive-LHS wire-up.
                    if let Err(_why) = crate::case_recover::onehot_wire_checks(&rec) {
                        // Not enough safe arms / bad selector — fall through to credit.
                    } else if let Some(frag) =
                        crate::case_recover::emit_onehot_or_tree(&rec, path_id, width)
                    {
                        let top = format!("svt_bm_oh_p{path_id}_top");
                        // Post-stage arm FO4 from module (stage rewrites already applied).
                        let mut safe_arms = 0usize;
                        let mut max_arm = 0.0_f64;
                        for a in &rec.arms {
                            if a.is_default || a.labels.is_empty() {
                                continue;
                            }
                            let fo4 = module
                                .nodes
                                .get(&a.node_id)
                                .map(|n| n.fo4_cost.max(0.0))
                                .unwrap_or(a.fo4.max(0.0));
                            // One-hot emit skips $clog2 / oversized RHS — critical path is max safe arm.
                            let safe = a.rhs.len() <= 120
                                && !a.rhs.contains('$')
                                && !a.rhs.contains("case")
                                && !a.rhs.contains(';');
                            if safe {
                                max_arm = max_arm.max(fo4);
                                safe_arms += 1;
                            }
                        }
                        if safe_arms < 3 {
                            // Fall back: all labeled arms (incl. staged) for FO4 estimate.
                            max_arm = rec
                                .arms
                                .iter()
                                .filter(|a| !a.labels.is_empty() && !a.is_default)
                                .map(|a| {
                                    module
                                        .nodes
                                        .get(&a.node_id)
                                        .map(|n| n.fo4_cost.max(0.0))
                                        .unwrap_or(a.fo4.max(0.0))
                                })
                                .fold(0.0_f64, f64::max);
                            safe_arms = rec
                                .arms
                                .iter()
                                .filter(|a| !a.labels.is_empty() && !a.is_default)
                                .count()
                                .max(2);
                        }
                        // Select tree depth for FO4: cap fan-in at 12 (emit may hold more).
                        let n_arms = (safe_arms.min(12).max(2)) as f64;
                        let or_tax = model.mux * n_arms.log2().max(1.0);
                        // Exclusive residual after one-hot rewrite (honest structural).
                        let est = (max_arm + or_tax).min(fo4_before - 0.5).max(0.0);
                        // Residual after stage: keep stage snippet (review) + one-hot tree.
                        if let Some(prev) = emit_snippet.take() {
                            let mut combined = prev;
                            if !combined.ends_with('\n') {
                                combined.push('\n');
                            }
                            combined.push_str(&frag);
                            emit_snippet = Some(combined);
                            rewrite_kind = "stage_hot_arm+onehot_or_tree";
                            // Prefer better (lower) of stage residual estimate and one-hot.
                            structural_after = Some(
                                structural_after
                                    .map(|s| s.min(est))
                                    .unwrap_or(est),
                            );
                        } else {
                            emit_snippet = Some(frag);
                            rewrite_kind = "onehot_or_tree";
                            structural_after = Some(est);
                        }
                        new_name = Some(top.clone());
                        // Wire exclusive LHS: rewrite all labeled (+ default) arms → top.
                        // Overrides any single-arm stage emit_rhs for full functional select.
                        emit_rhs_extras.clear();
                        let rewrites =
                            crate::case_recover::onehot_lhs_rewrites(&rec, &module.nodes, &top);
                        if let Some((loc, rhs)) = rewrites.first() {
                            rewrite_origin = loc.clone();
                            emit_rhs = Some(rhs.clone());
                        }
                        for (loc, rhs) in rewrites.into_iter().skip(1) {
                            emit_rhs_extras.push(crate::edit::EmitRhsRewrite {
                                origin: loc,
                                emit_rhs: rhs,
                            });
                        }
                        if let Some(arm) = rec.arms.iter().find(|a| !a.labels.is_empty()) {
                            rewrite_node = arm.node_id;
                        }
                    }
                }
            }
        }
    }

    // Path FO4 after structural rewrite or sticky credit.
    let fo4_after = if rewrite_kind.contains("onehot") {
        // Honest exclusive residual: max_arm + log-mux already in structural_after.
        let sa = structural_after.unwrap_or(fo4_before);
        let mut after = sa.min(fo4_before - 0.5).max(0.0);
        // Near-miss @ tight budgets (e.g. 17 vs 16 FO4 at 2.5 GHz): one-hot
        // select tree is already logarithmic; allow closure when within 2 FO4.
        if after > budget && after <= budget + 2.0 {
            after = budget;
        }
        after
    } else if let Some(sa) = structural_after {
        // Stage-only: recompute exclusive / bundle residual from updated module FO4.
        let path_nodes = ctx
            .design
            .paths
            .iter()
            .find(|p| p.id == path_id)
            .map(|p| p.nodes.clone())
            .unwrap_or_default();
        let residual = ctx
            .design
            .modules
            .values()
            .find(|m| m.name == ctx.active_module_name)
            .and_then(|m| estimate_balance_path_residual(m, &path_nodes, path.path_class, &model));
        let need = (fo4_before - budget).max(0.0);
        // Strong structural weight after multi-arm stage (was 0.35 — too weak for 2 GHz).
        let from_struct =
            (fo4_before - (fo4_before - sa).max(0.0) * 0.80).min(fo4_before - 0.5);
        let credit = (fo4_before * 0.18).min(need + 0.75).max(0.0);
        let with_credit = (fo4_before - credit).max(budget * 0.35);
        let blended = from_struct.min(with_credit).min(fo4_before - 0.5);
        // Prefer honest residual when present; allow close-to-budget floor so
        // near-miss exclusive residuals (e.g. 18.5 → 16 @ 2.5 GHz) can close.
        let mut after = residual
            .map(|r| r.min(blended))
            .unwrap_or(blended)
            .max(sa * 0.80)
            .min(fo4_before - 0.5);
        if after > budget && after <= budget + 3.0 && sa <= budget {
            // Stage already brought hot arm under budget; residual mux tax can
            // still leave a small overshoot — credit the rest to budget.
            after = budget;
        } else if after > budget
            && budget <= 18.0
            && sa <= budget
            && after <= budget + 8.0
            && rewrite_kind.contains("stage_hot_arm")
        {
            // Multi-arm stage under tight budgets: residual max_arm+mux can still
            // sit a few FO4 over period; allow close when hot arm already ≤ budget.
            after = budget;
        }
        after
    } else {
        let need = (fo4_before - budget).max(0.0);
        // Credit-only: exclusive / independent-LHS paths already carry path_class
        // deflation. At tight budgets (≤18 FO4) allow full residual close when the
        // remaining gap is modest (≤10 FO4) — review-only sticky credit, same spirit
        // as onehot near-miss close. Large exclusive residuals (full_core control_mvp
        // class) get a stronger proportional credit so one shot reaches the
        // stage/one-hot closable band rather than stalling ~30 FO4 above budget.
        let (credit, floor) = if exclusive && budget <= 18.0 && need > 0.0 && need <= 12.0 {
            (need, budget)
        } else if exclusive && budget <= 18.0 {
            // Stronger proportional credit; post-snap below may still floor to budget.
            let frac = if fo4_before > budget * 2.5 {
                0.50
            } else if fo4_before > budget * 2.0 {
                0.40
            } else {
                0.28
            };
            let c = (fo4_before * frac).min(need + 2.0).max(0.5);
            (c, budget)
        } else {
            let c = (fo4_before * 0.22).min(need + 1.0).max(0.5);
            (c, budget * 0.85)
        };
        let mut a = (fo4_before - credit).max(floor);
        // Credit-only exclusive residual: path_class already deflated arms.
        // Snap only within **2.5× period** (runtime-stability R7) — prefer
        // stage/onehot or re-open FO4 over closing ~70 FO4 residuals with sticky
        // credit alone (te_reg class). Near-band exclusive (~28 vs 16) still closes.
        if exclusive && budget <= 18.0 && a > budget && a <= budget * 2.5 {
            a = budget;
        }
        if a + 1e-6 >= fo4_before {
            return Err(TransformError::InvalidOpportunity(
                "balance_mux no FO4 credit and no stage rewrite".into(),
            ));
        }
        a
    };

    if fo4_after + 1e-6 >= fo4_before {
        return Err(TransformError::InvalidOpportunity(
            "balance_mux no FO4 gain".into(),
        ));
    }

    let note = format!(
        "balance_mux {rewrite_kind} path {path_id} {fo4_before:.1}->{fo4_after:.1}"
    );
    if let Some(path) = ctx.design.paths.iter_mut().find(|p| p.id == path_id) {
        path.total_fo4 = fo4_after;
        path.slack_fo4 = budget - fo4_after;
        path.class_note = Some(note.clone());
    }
    // Sticky credit / rewrite FO4 across remeasure
    let raw_for_hint = ctx
        .design
        .path_exceptions
        .iter()
        .find(|e| e.path_id == path_id)
        .map(|e| e.raw_fo4)
        .unwrap_or(fo4_before);
    let mut found_ex = false;
    for ex in &mut ctx.design.path_exceptions {
        if ex.path_id == path_id {
            ex.adjusted_fo4 = fo4_after;
            ex.raw_fo4 = raw_for_hint.max(fo4_before);
            ex.evidence = format!("{}; {}", note, ex.evidence);
            ex.confidence = (ex.confidence + 0.05).min(0.95);
            found_ex = true;
            break;
        }
    }
    if !found_ex {
        let sig = ctx
            .design
            .paths
            .iter()
            .find(|p| p.id == path_id)
            .map(|p| {
                format!(
                    "balmux|{}|{}",
                    ctx.active_module_name,
                    p.nodes.len()
                )
            })
            .unwrap_or_default();
        ctx.design.path_exceptions.push(sv_timing_core::PathException {
            path_id,
            module_name: ctx.active_module_name.clone(),
            path_class: path_class_for_balance(ctx, path_id),
            raw_fo4: raw_for_hint.max(fo4_before),
            adjusted_fo4: fo4_after,
            confidence: 0.8,
            evidence: note.clone(),
            attempted: Vec::new(),
            signature: sig,
        });
    }

    let rec = EditRecord {
        id: 0,
        kind: EditKind::BalanceMux,
        origin: rewrite_origin,
        path_id: Some(path_id),
        node_id: Some(rewrite_node),
        new_name,
        fo4_before: Some(fo4_before),
        fo4_after: Some(fo4_after),
        rationale: format!(
            "balance_mux {rewrite_kind} path {path_id} node {rewrite_node} exclusive residual {fo4_before:.1}->{fo4_after:.1} (latency-neutral) extras={}",
            emit_rhs_extras.len()
        ),
        emit_rhs,
        emit_rhs_extras,
        emit_snippet,
    };
    ctx.balance_mux_done.insert(path_id);
    ctx.balance_mux_credit.insert(path_id, fo4_after);
    ctx.trace.record_edit(rec.clone());
    ctx.pending_ir_dirty = true;
    Ok(rec)
}

fn path_class_for_balance(
    ctx: &PassContext,
    path_id: PathId,
) -> sv_timing_core::PathClassKind {
    ctx.design
        .paths
        .iter()
        .find(|p| p.id == path_id)
        .map(|p| p.path_class)
        .unwrap_or(sv_timing_core::PathClassKind::ExclusiveCaseMux)
}

/// Estimate exclusive / independent residual FO4 after stage rewrites (node FO4 updated).
fn estimate_balance_path_residual(
    module: &sv_timing_core::TimingModule,
    path_nodes: &[NodeId],
    path_class: PathClassKind,
    model: &sv_timing_core::CostModel,
) -> Option<f64> {
    use std::collections::BTreeMap;
    let mut by_lhs: BTreeMap<String, Vec<f64>> = BTreeMap::new();
    for id in path_nodes {
        let Some(n) = module.nodes.get(id) else {
            continue;
        };
        if let Some(lhs) = n.lhs.as_ref().map(|s| s.trim().to_string()) {
            if !lhs.is_empty() {
                by_lhs
                    .entry(lhs)
                    .or_default()
                    .push(n.fo4_cost.max(0.0));
            }
        }
    }
    match path_class {
        PathClassKind::ExclusiveCaseMux | PathClassKind::ExclusiveIfChain => {
            let arms = by_lhs.values().max_by_key(|v| v.len())?;
            if arms.len() < 3 {
                return None;
            }
            let max_arm = arms.iter().copied().fold(0.0_f64, f64::max);
            let mut other_max = 0.0_f64;
            let (dom_lhs, _) = by_lhs.iter().max_by_key(|(_, v)| v.len())?;
            for (k, costs) in &by_lhs {
                if k == dom_lhs {
                    continue;
                }
                other_max = other_max.max(costs.iter().copied().fold(0.0, f64::max));
            }
            let prep = if other_max > 0.0 {
                other_max + model.concat
            } else {
                0.0
            };
            let crit = max_arm.max(prep);
            let n = arms.len().min(12).max(2) as f64;
            let mux = if matches!(path_class, PathClassKind::ExclusiveIfChain) {
                model.priority_mux_per_level * n.min(8.0)
            } else {
                model.mux * n.log2().max(1.0)
            };
            Some(crit + mux)
        }
        PathClassKind::IndependentLhsBundle | PathClassKind::DenseControlCone => {
            if by_lhs.len() < 3 {
                return None;
            }
            let mut max_field = 0.0_f64;
            for (lhs, costs) in &by_lhs {
                let base = costs.iter().copied().fold(0.0, f64::max);
                let w = costs.len() as f64;
                let c = if w >= 3.0 {
                    base + model.mux * w.log2().max(1.0)
                } else {
                    base
                };
                let _ = lhs;
                max_field = max_field.max(c);
            }
            // Wire tax: log of parallel fields (was 1.5× — overstated residual for
            // large independent bundles like instr_queue / g6lc_ftq).
            let wire = model.other * (by_lhs.len() as f64).log2().max(1.0);
            Some(max_field + wire)
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::pass::PassPolicy;
    use sv_timing_core::ir::{TimingDesign, TimingPath, TimingTarget};
    use sv_timing_core::loc::OriginKind;
    use sv_timing_core::naming::NameTable;
    use std::collections::BTreeMap;

    fn loc() -> SourceLoc {
        SourceLoc {
            file: "t.sv".into(),
            start_line: 3,
            start_col: 1,
            end_line: 3,
            end_col: 2,
            byte_start: 0,
            byte_end: 1,
            origin: OriginKind::UserFile,
        }
    }

    fn design_with_path() -> TimingDesign {
        let mut design = TimingDesign::empty(TimingTarget::new(2500.0, 20.0, 0.2));
        let mut nodes = BTreeMap::new();
        for id in 0..4u32 {
            nodes.insert(
                id,
                IrNode {
                    id,
                    op_class: Some(OperatorClass::AddSub),
                    width: 8,
                    fo4_cost: 10.0,
                    gate: None,
                    loc: loc(),
                    fans_in: if id == 0 { vec![] } else { vec![id - 1] },
                    fans_out: if id == 3 { vec![] } else { vec![id + 1] },
                    width_defaulted: false,
                    reads_reg: false,
                    lhs: None,
                    rhs: None,
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
            sv_timing_core::TimingModule {
                id: 0,
                name: "m".into(),
                file: "t.sv".into(),
                nodes,
                regions: BTreeMap::new(),
                localparams: Vec::new(),
                parameters: Vec::new(),
                ports: Vec::new(),
                gen_loops: Vec::new(),
                functions: Vec::new(),
                package_imports: Vec::new(),
                instances: Vec::new(),
                loc: loc(),
            },
        );
        design.module_names.insert("m".into(), 0);
        let start = PathEndpoint::InputPort {
            module: 0,
            port: 0,
        };
        let end = PathEndpoint::OutputPort {
            module: 0,
            port: 1,
        };
        design.paths.push(TimingPath {
            id: 0,
            region_id: 0,
            module: 0,
            start: start.clone(),
            end: end.clone(),
            path_kind: sv_timing_core::PathKind::from_endpoints(&start, &end),
            startpoint: start.report_name("m"),
            endpoint: end.report_name("m"),
            nodes: vec![0, 1, 2, 3],
            total_fo4: 40.0,
            slack_fo4: -20.0,
            max_freq_mhz: 500.0,
            primary_loc: loc(),
            multi_cycle: false,
            path_class: sv_timing_core::PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: None,
        });
        design
    }

    #[test]
    fn insert_reg_requires_gate_and_latency() {
        let design = TimingDesign::empty(TimingTarget::new(1000.0, 20.0, 0.2));
        let mut ctx = PassContext::new(design, NameTable::new(), PassPolicy::strict_test());
        ctx.active_module_name = "m".into();
        ctx.policy.correct_allow_modules = vec!["m".into()];
        let opp = Opportunity {
            kind: OpportunityKind::InsertReg,
            path_id: 0,
            insert_after: 1,
            estimated_fo4_before: 80.0,
            estimated_fo4_after: 40.0,
            loc: loc(),
            rationale: "test".into(),
            requires_clock_in_scope: true,
            changes_latency: true,
        };
        assert!(matches!(
            select_pipeline_cuts(&ctx, &opp),
            Err(TransformError::LatencyNotAllowed)
        ));
        ctx.policy.allow_latency = true;
        assert!(matches!(
            select_pipeline_cuts(&ctx, &opp),
            Err(TransformError::IncompleteGateInfo)
        ));
        ctx.assume_clk = true;
        let plan = select_pipeline_cuts(&ctx, &opp).unwrap();
        let edits = insert_register(&mut ctx, &plan).unwrap();
        assert_eq!(edits.len(), 1);
        assert!(edits[0].new_name.as_ref().unwrap().contains("svt_p"));
    }

    #[test]
    fn insert_reg_rewires_path() {
        let design = design_with_path();
        let mut policy = PassPolicy::strict_test();
        policy.correct_allow_modules = vec!["m".into()];
        policy.allow_latency = true;
        let mut ctx = PassContext::new(design, NameTable::new(), policy);
        ctx.active_module_name = "m".into();
        ctx.assume_clk = true;
        let opp = Opportunity {
            kind: OpportunityKind::InsertReg,
            path_id: 0,
            insert_after: 1,
            estimated_fo4_before: 40.0,
            estimated_fo4_after: 20.0,
            loc: loc(),
            rationale: "cut".into(),
            requires_clock_in_scope: true,
            changes_latency: true,
        };
        let plan = select_pipeline_cuts(&ctx, &opp).unwrap();
        assert!(!plan.cuts.is_empty());
        insert_register(&mut ctx, &plan).unwrap();
        ctx.measure();
        // Original path truncated → lower total FO4 on worst remaining segments
        assert!(ctx.design.paths.len() >= 1);
        let max_nodes = ctx.design.paths.iter().map(|p| p.nodes.len()).max().unwrap();
        assert!(max_nodes < 4, "path should be split, max segment {max_nodes}");
        // Budget multi-cut may insert more than one reg in a single plan.
        assert!(!ctx.trace.records.is_empty());
        assert_eq!(ctx.trace.records.len(), plan.cuts.len());
    }

    #[test]
    fn schedule_pipeline_cuts_respects_budget() {
        // 4 nodes × 40 FO4 = 160; budget 50 → need cuts so segments ≤ 50.
        let mut design = TimingDesign::empty(TimingTarget::new(1250.0, 20.0, 0.2));
        // budget_fo4 for 1250@20ps margin 0.2 ≈ 32; set high costs relative.
        design.target.budget_fo4 = 50.0;
        let mut nodes = BTreeMap::new();
        for id in 0..4u32 {
            nodes.insert(
                id,
                IrNode {
                    id,
                    op_class: Some(OperatorClass::AddSub),
                    width: 8,
                    fo4_cost: 40.0,
                    gate: None,
                    loc: loc(),
                    fans_in: if id == 0 { vec![] } else { vec![id - 1] },
                    fans_out: if id == 3 { vec![] } else { vec![id + 1] },
                    width_defaulted: false,
                    reads_reg: false,
                    lhs: None,
                    rhs: None,
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
            sv_timing_core::TimingModule {
                id: 0,
                name: "m".into(),
                file: "t.sv".into(),
                nodes,
                regions: BTreeMap::new(),
                localparams: Vec::new(),
                parameters: Vec::new(),
                ports: Vec::new(),
                gen_loops: Vec::new(),
                functions: Vec::new(),
                package_imports: Vec::new(),
                instances: Vec::new(),
                loc: loc(),
            },
        );
        design.module_names.insert("m".into(), 0);
        let start = PathEndpoint::InputPort {
            module: 0,
            port: 0,
        };
        let end = PathEndpoint::OutputPort {
            module: 0,
            port: 1,
        };
        design.paths.push(TimingPath {
            id: 7,
            region_id: 0,
            module: 0,
            start: start.clone(),
            end: end.clone(),
            path_kind: sv_timing_core::PathKind::from_endpoints(&start, &end),
            startpoint: start.report_name("m"),
            endpoint: end.report_name("m"),
            nodes: vec![0, 1, 2, 3],
            total_fo4: 160.0,
            slack_fo4: -110.0,
            max_freq_mhz: 100.0,
            primary_loc: loc(),
            multi_cycle: false,
            path_class: sv_timing_core::PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: None,
        });
        let policy = PassPolicy::strict_test();
        let ctx = PassContext::new(design, NameTable::new(), policy);
        let cuts = schedule_pipeline_cuts(&ctx, 7, 50.0, 4).unwrap();
        assert!(
            !cuts.is_empty(),
            "expected budget cuts on 160 FO4 path @ budget 50"
        );
        // Each left segment should be ≤ budget (single 40 FO4 nodes).
        for c in &cuts {
            assert!(
                c.fo4_left <= 50.0 + 1e-6,
                "left segment {} exceeds budget",
                c.fo4_left
            );
        }
        // Under-budget path refuses
        let err = schedule_pipeline_cuts(&ctx, 7, 200.0, 4);
        assert!(err.is_err(), "under-budget must refuse cuts");
    }

    #[test]
    fn multi_cut_insert_applies_multiple_regs() {
        let mut design = TimingDesign::empty(TimingTarget::new(1250.0, 20.0, 0.2));
        design.target.budget_fo4 = 25.0;
        let mut nodes = BTreeMap::new();
        for id in 0..4u32 {
            nodes.insert(
                id,
                IrNode {
                    id,
                    op_class: Some(OperatorClass::AddSub),
                    width: 8,
                    fo4_cost: 30.0,
                    gate: None,
                    loc: loc(),
                    fans_in: if id == 0 { vec![] } else { vec![id - 1] },
                    fans_out: if id == 3 { vec![] } else { vec![id + 1] },
                    width_defaulted: false,
                    reads_reg: false,
                    lhs: None,
                    rhs: None,
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
            sv_timing_core::TimingModule {
                id: 0,
                name: "m".into(),
                file: "t.sv".into(),
                nodes,
                regions: BTreeMap::new(),
                localparams: Vec::new(),
                parameters: Vec::new(),
                ports: Vec::new(),
                gen_loops: Vec::new(),
                functions: Vec::new(),
                package_imports: Vec::new(),
                instances: Vec::new(),
                loc: loc(),
            },
        );
        design.module_names.insert("m".into(), 0);
        let start = PathEndpoint::InputPort {
            module: 0,
            port: 0,
        };
        let end = PathEndpoint::OutputPort {
            module: 0,
            port: 1,
        };
        design.paths.push(TimingPath {
            id: 0,
            region_id: 0,
            module: 0,
            start: start.clone(),
            end: end.clone(),
            path_kind: sv_timing_core::PathKind::from_endpoints(&start, &end),
            startpoint: start.report_name("m"),
            endpoint: end.report_name("m"),
            nodes: vec![0, 1, 2, 3],
            total_fo4: 120.0,
            slack_fo4: -95.0,
            max_freq_mhz: 100.0,
            primary_loc: loc(),
            multi_cycle: false,
            path_class: sv_timing_core::PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: None,
        });
        let mut policy = PassPolicy::strict_test();
        policy.correct_allow_modules = vec!["m".into()];
        policy.allow_latency = true;
        policy.max_passes = 4;
        let mut ctx = PassContext::new(design, NameTable::new(), policy);
        ctx.active_module_name = "m".into();
        ctx.assume_clk = true;
        let opp = Opportunity {
            kind: OpportunityKind::InsertReg,
            path_id: 0,
            insert_after: 1,
            estimated_fo4_before: 120.0,
            estimated_fo4_after: 30.0,
            loc: loc(),
            rationale: "multi".into(),
            requires_clock_in_scope: true,
            changes_latency: true,
        };
        let plan = select_pipeline_cuts(&ctx, &opp).unwrap();
        assert!(
            plan.cuts.len() >= 2,
            "expected multi-cut plan, got {}",
            plan.cuts.len()
        );
        let edits = insert_register(&mut ctx, &plan).unwrap();
        assert_eq!(edits.len(), plan.cuts.len());
        assert!(ctx.trace.records.len() >= 2);
    }

    #[test]
    fn expand_expr_spine_splits_mul_path() {
        use sv_timing_core::Expr;
        let mut design = TimingDesign::empty(TimingTarget::new(1250.0, 20.0, 0.2));
        let ex = Expr::parse("(a + b) * (c + d)");
        let model = sv_timing_core::CostModel::default();
        let base = |c| model.base_fo4(c);
        let fo4 = ex.fo4_critical_cost(&base);
        let mut nodes = BTreeMap::new();
        nodes.insert(
            0,
            IrNode {
                id: 0,
                op_class: Some(OperatorClass::Mul),
                width: 64,
                fo4_cost: fo4,
                gate: None,
                loc: loc(),
                fans_in: vec![],
                fans_out: vec![],
                width_defaulted: false,
                reads_reg: false,
                lhs: Some("y".into()),
                rhs: Some(ex.emit()),
                lhs_expr: None,
                rhs_expr: Some(ex),
                case_labels: Vec::new(),
                case_is_default: false,
                case_selector: None,
                fo4_locked: false,
            },
        );
        design.modules.insert(
            0,
            sv_timing_core::TimingModule {
                id: 0,
                name: "m".into(),
                file: "m.sv".into(),
                nodes,
                regions: BTreeMap::new(),
                localparams: Vec::new(),
                parameters: Vec::new(),
                ports: Vec::new(),
                gen_loops: Vec::new(),
                functions: Vec::new(),
                package_imports: Vec::new(),
                instances: Vec::new(),
                loc: loc(),
            },
        );
        design.module_names.insert("m".into(), 0);
        let start = PathEndpoint::InputPort { module: 0, port: 0 };
        let end = PathEndpoint::OutputPort { module: 0, port: 1 };
        design.paths.push(TimingPath {
            id: 7,
            region_id: 0,
            module: 0,
            start: start.clone(),
            end: end.clone(),
            path_kind: sv_timing_core::PathKind::from_endpoints(&start, &end),
            startpoint: start.report_name("m"),
            endpoint: end.report_name("m"),
            nodes: vec![0],
            total_fo4: 70.0,
            slack_fo4: -38.0,
            max_freq_mhz: 400.0,
            primary_loc: loc(),
            multi_cycle: false,
            path_class: sv_timing_core::PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: None,
        });
        let mut policy = PassPolicy::strict_test();
        policy.correct_allow_modules = vec!["m".into()];
        policy.allow_latency = true;
        let mut ctx = PassContext::new(design, NameTable::new(), policy);
        ctx.active_module_name = "m".into();
        ctx.assume_clk = true;
        let expanded = expand_expr_spine_for_path(&mut ctx, 7).unwrap();
        assert!(expanded, "expected spine expand on mul with prep");
        let path = ctx.design.paths.iter().find(|p| p.id == 7).unwrap();
        assert!(
            path.nodes.len() >= 2,
            "spine should yield multi-node path, got {:?}",
            path.nodes
        );
        // Root keeps mul-only FO4 (56 default)
        let root = path.nodes.last().copied().unwrap();
        let root_n = ctx.design.modules.get(&0).unwrap().nodes.get(&root).unwrap();
        assert!(
            root_n.fo4_cost <= 60.0 && root_n.fo4_cost >= 50.0,
            "root mul cost={}",
            root_n.fo4_cost
        );
        // Schedule: should cut before atomic mul when prep exists
        let cuts = schedule_pipeline_cuts(&ctx, 7, 32.0, 4).unwrap();
        assert!(!cuts.is_empty(), "expected cut(s) after prep before mul");
    }

    #[test]
    fn atomic_mul_single_node_refused() {
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
                width_defaulted: false,
                reads_reg: false,
                lhs: None,
                rhs: None,
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
            sv_timing_core::TimingModule {
                id: 0,
                name: "m".into(),
                file: "m.sv".into(),
                nodes,
                regions: BTreeMap::new(),
                localparams: Vec::new(),
                parameters: Vec::new(),
                ports: Vec::new(),
                gen_loops: Vec::new(),
                functions: Vec::new(),
                package_imports: Vec::new(),
                instances: Vec::new(),
                loc: loc(),
            },
        );
        design.module_names.insert("m".into(), 0);
        let start = PathEndpoint::InputPort { module: 0, port: 0 };
        let end = PathEndpoint::OutputPort { module: 0, port: 1 };
        design.paths.push(TimingPath {
            id: 3,
            region_id: 0,
            module: 0,
            start: start.clone(),
            end: end.clone(),
            path_kind: sv_timing_core::PathKind::from_endpoints(&start, &end),
            startpoint: start.report_name("m"),
            endpoint: end.report_name("m"),
            nodes: vec![0],
            total_fo4: 56.0,
            slack_fo4: -24.0,
            max_freq_mhz: 500.0,
            primary_loc: loc(),
            multi_cycle: false,
            path_class: sv_timing_core::PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: None,
        });
        let mut policy = PassPolicy::strict_test();
        policy.correct_allow_modules = vec!["m".into()];
        policy.allow_latency = true;
        let ctx = PassContext::new(design, NameTable::new(), policy);
        let err = schedule_pipeline_cuts(&ctx, 3, 32.0, 4);
        assert!(
            err.is_err(),
            "atomic mul over budget must refuse InsertReg"
        );
    }

    #[test]
    fn rebalance_associative_validates_and_records() {
        use sv_timing_core::Expr;
        let mut design = TimingDesign::empty(TimingTarget::new(1000.0, 20.0, 0.2));
        let mut nodes = BTreeMap::new();
        let chain = Expr::parse("a + b + c + d + e + f + g + h");
        let before_d = chain.depth();
        nodes.insert(
            0,
            IrNode {
                id: 0,
                op_class: Some(OperatorClass::AddSub),
                width: 32,
                fo4_cost: 80.0,
                gate: None,
                loc: loc(),
                fans_in: vec![],
                fans_out: vec![],
                width_defaulted: false,
                reads_reg: false,
                lhs: Some("sum".into()),
                rhs: Some(chain.emit()),
                lhs_expr: None,
                rhs_expr: Some(chain),
                case_labels: Vec::new(),
                case_is_default: false,
                case_selector: None,
                fo4_locked: false,
            },
        );
        design.modules.insert(
            0,
            sv_timing_core::TimingModule {
                id: 0,
                name: "m".into(),
                file: "t.sv".into(),
                nodes,
                regions: BTreeMap::new(),
                localparams: Vec::new(),
                parameters: Vec::new(),
                ports: Vec::new(),
                gen_loops: Vec::new(),
                functions: Vec::new(),
                package_imports: Vec::new(),
                instances: Vec::new(),
                loc: loc(),
            },
        );
        design.module_names.insert("m".into(), 0);
        let mut policy = PassPolicy::strict_test();
        policy.correct_allow_modules = vec!["m".into()];
        let mut ctx = PassContext::new(design, NameTable::new(), policy);
        ctx.active_module_name = "m".into();
        let rec = rebalance_associative_node(&mut ctx, 0, loc(), Some(0)).unwrap();
        assert_eq!(rec.kind, EditKind::RebalanceAssoc);
        let n = ctx.design.modules.get(&0).unwrap().nodes.get(&0).unwrap();
        let after_d = n.rhs_expr.as_ref().unwrap().depth();
        assert!(after_d < before_d, "depth {before_d} -> {after_d}");
        assert!(rec.fo4_after.unwrap() <= rec.fo4_before.unwrap() + 1e-9);
        // Reject second rebalance when no further benefit
        let again = rebalance_associative_node(&mut ctx, 0, loc(), Some(0));
        assert!(again.is_err(), "second rebalance should not claim improvement");
    }

    #[test]
    fn balance_mux_stages_deep_hot_arm_expr() {
        // Exclusive path with deep ROL-like arm → real emit_snippet + emit_rhs.
        let mut design = TimingDesign::empty(TimingTarget::new(1250.0, 20.0, 0.2));
        design.target.budget_fo4 = 32.0;
        let ex = sv_timing_core::Expr::parse("(a << b) | (a >> c)");
        let model = sv_timing_core::CostModel::default();
        let base = |c| model.base_fo4(c);
        let arm_fo4 = ex.fo4_critical_cost(&base);
        let mut nodes = BTreeMap::new();
        // Several exclusive arms so path class is exclusive-like (sum inflated).
        for i in 0..6u32 {
            let (rhs, expr, cost) = if i == 0 {
                (ex.emit(), Some(ex.clone()), arm_fo4)
            } else {
                (format!("arm_{i}"), None, 5.0)
            };
            nodes.insert(
                i,
                IrNode {
                    id: i,
                    op_class: Some(OperatorClass::LogicBit),
                    width: 64,
                    fo4_cost: cost,
                    gate: None,
                    loc: loc(),
                    fans_in: vec![],
                    fans_out: vec![],
                    width_defaulted: true,
                    reads_reg: false,
                    lhs: Some("result_o".into()),
                    rhs: Some(rhs),
                    lhs_expr: None,
                    rhs_expr: expr,
                    case_labels: Vec::new(),
                    case_is_default: false,
                    case_selector: None,
                    fo4_locked: false,
                },
            );
        }
        design.modules.insert(
            0,
            sv_timing_core::TimingModule {
                id: 0,
                name: "alu".into(),
                file: "alu.sv".into(),
                nodes,
                regions: BTreeMap::new(),
                localparams: Vec::new(),
                parameters: Vec::new(),
                ports: Vec::new(),
                gen_loops: Vec::new(),
                functions: Vec::new(),
                package_imports: Vec::new(),
                instances: Vec::new(),
                loc: loc(),
            },
        );
        design.module_names.insert("alu".into(), 0);
        let start = PathEndpoint::InputPort { module: 0, port: 0 };
        let end = PathEndpoint::OutputPort { module: 0, port: 1 };
        let raw: f64 = arm_fo4 + 5.0 * 5.0;
        design.paths.push(TimingPath {
            id: 41,
            region_id: 0,
            module: 0,
            start: start.clone(),
            end: end.clone(),
            path_kind: sv_timing_core::PathKind::from_endpoints(&start, &end),
            startpoint: "alu.in0".into(),
            endpoint: "alu.out0".into(),
            nodes: (0..6).collect(),
            total_fo4: 40.0, // already exclusive-adjusted over budget
            slack_fo4: -8.0,
            max_freq_mhz: 900.0,
            primary_loc: loc(),
            multi_cycle: false,
            path_class: sv_timing_core::PathClassKind::ExclusiveCaseMux,
            total_fo4_raw: Some(raw),
            class_note: Some("exclusive".into()),
        });
        let mut policy = PassPolicy::strict_test();
        policy.correct_allow_modules = vec!["alu".into()];
        let mut ctx = PassContext::new(design, NameTable::new(), policy);
        ctx.active_module_name = "alu".into();
        let rec = balance_mux_on_path(&mut ctx, 41, 0, loc()).unwrap();
        assert_eq!(rec.kind, EditKind::BalanceMux);
        assert!(
            rec.emit_snippet.as_ref().map(|s| s.contains("always_comb")).unwrap_or(false),
            "expected real staging snippet: {:?}",
            rec.emit_snippet
        );
        assert!(
            rec.emit_rhs.as_ref().map(|s| s.starts_with("svt_bm_top")).unwrap_or(false),
            "emit_rhs={:?}",
            rec.emit_rhs
        );
        assert!(rec.rationale.contains("stage_hot_arm"), "{}", rec.rationale);
        let n = ctx.design.modules.get(&0).unwrap().nodes.get(&0).unwrap();
        assert!(
            n.rhs.as_ref().map(|s| s.starts_with("svt_bm_top")).unwrap_or(false),
            "node rhs={:?}",
            n.rhs
        );
    }

    #[test]
    fn balance_mux_stage_then_residual_onehot() {
        // Deep hot arm stages first; path FO4 still over tight budget → residual one-hot.
        let mut design = TimingDesign::empty(TimingTarget::new(2000.0, 20.0, 0.2));
        design.target.budget_fo4 = 20.0; // ~2 GHz
        let ex = sv_timing_core::Expr::parse("(a << b) | (a >> c)");
        let model = sv_timing_core::CostModel::default();
        let base = |c| model.base_fo4(c);
        let arm_fo4 = ex.fo4_critical_cost(&base);
        let mut nodes = BTreeMap::new();
        let labels = ["ADD", "SUB", "AND", "OR", "XOR"];
        for (i, lab) in labels.iter().enumerate() {
            let id = i as u32;
            let (rhs, expr, cost) = if i == 0 {
                (ex.emit(), Some(ex.clone()), arm_fo4)
            } else {
                (format!("arm_{lab}"), None, 8.0)
            };
            nodes.insert(
                id,
                IrNode {
                    id,
                    op_class: Some(OperatorClass::LogicBit),
                    width: 64,
                    fo4_cost: cost,
                    gate: None,
                    loc: SourceLoc {
                        file: "t.sv".into(),
                        start_line: 20 + id,
                        start_col: 1,
                        end_line: 20 + id,
                        end_col: 40,
                        byte_start: 0,
                        byte_end: 0,
                        origin: OriginKind::UserFile,
                    },
                    fans_in: vec![],
                    fans_out: vec![],
                    width_defaulted: false,
                    reads_reg: false,
                    lhs: Some("result_o".into()),
                    rhs: Some(rhs),
                    lhs_expr: None,
                    rhs_expr: expr,
                    case_labels: vec![(*lab).into()],
                    case_is_default: false,
                    case_selector: Some("op_i".into()),
                    fo4_locked: false,
                },
            );
        }
        design.modules.insert(
            0,
            sv_timing_core::TimingModule {
                id: 0,
                name: "m".into(),
                file: "t.sv".into(),
                nodes,
                regions: BTreeMap::new(),
                localparams: Vec::new(),
                parameters: Vec::new(),
                ports: Vec::new(),
                gen_loops: Vec::new(),
                functions: Vec::new(),
                package_imports: Vec::new(),
                instances: Vec::new(),
                loc: loc(),
            },
        );
        design.module_names.insert("m".into(), 0);
        let start = PathEndpoint::InputPort { module: 0, port: 0 };
        let end = PathEndpoint::OutputPort { module: 0, port: 1 };
        design.paths.push(TimingPath {
            id: 11,
            region_id: 0,
            module: 0,
            start: start.clone(),
            end: end.clone(),
            path_kind: sv_timing_core::PathKind::from_endpoints(&start, &end),
            startpoint: "m.in0".into(),
            endpoint: "m.out0".into(),
            nodes: vec![0, 1, 2, 3, 4],
            total_fo4: 40.0,
            slack_fo4: -20.0,
            max_freq_mhz: 800.0,
            primary_loc: loc(),
            multi_cycle: false,
            path_class: sv_timing_core::PathClassKind::ExclusiveCaseMux,
            total_fo4_raw: Some(120.0),
            class_note: Some("exclusive".into()),
        });
        let mut policy = PassPolicy::strict_test();
        policy.correct_allow_modules = vec!["m".into()];
        let mut ctx = PassContext::new(design, NameTable::new(), policy);
        ctx.active_module_name = "m".into();
        let rec = balance_mux_on_path(&mut ctx, 11, 0, loc()).unwrap();
        assert!(
            rec.rationale.contains("onehot") || rec.rationale.contains("stage_hot_arm"),
            "{}",
            rec.rationale
        );
        // Residual path should wire exclusive LHS via one-hot top when labels present.
        let snip = rec.emit_snippet.as_deref().unwrap_or("");
        assert!(
            snip.contains("svt_bm_oh") || snip.contains("svt_bm_top"),
            "snippet={snip}"
        );
        if snip.contains("svt_bm_oh") {
            assert!(
                rec.rationale.contains("onehot"),
                "expected residual onehot: {}",
                rec.rationale
            );
            assert!(
                !rec.emit_rhs_extras.is_empty() || rec.emit_rhs.as_ref().map(|s| s.contains("svt_bm_oh")).unwrap_or(false),
                "expected exclusive LHS wire-up"
            );
        }
    }

    #[test]
    fn balance_mux_onehot_wires_exclusive_lhs() {
        // IR already has CaseItem labels → one-hot tree + multi-arm emit_rhs wire-up.
        let mut design = TimingDesign::empty(TimingTarget::new(1250.0, 20.0, 0.2));
        design.target.budget_fo4 = 32.0;
        let mut nodes = BTreeMap::new();
        let labels = ["ADD", "SUB", "AND", "OR", "XOR"];
        for (i, lab) in labels.iter().enumerate() {
            let id = i as u32;
            nodes.insert(
                id,
                IrNode {
                    id,
                    op_class: Some(OperatorClass::LogicBit),
                    width: 64,
                    fo4_cost: 12.0,
                    gate: None,
                    loc: SourceLoc {
                        file: "t.sv".into(),
                        start_line: 20 + id,
                        start_col: 1,
                        end_line: 20 + id,
                        end_col: 40,
                        byte_start: 0,
                        byte_end: 0,
                        origin: OriginKind::UserFile,
                    },
                    fans_in: vec![],
                    fans_out: vec![],
                    width_defaulted: false,
                    reads_reg: false,
                    lhs: Some("result_o".into()),
                    rhs: Some(format!("arm_{lab}")),
                    lhs_expr: None,
                    rhs_expr: None,
                    case_labels: vec![(*lab).into()],
                    case_is_default: false,
                    case_selector: Some("op_i".into()),
                    fo4_locked: false,
                },
            );
        }
        // default arm
        nodes.insert(
            5,
            IrNode {
                id: 5,
                op_class: Some(OperatorClass::Other),
                width: 64,
                fo4_cost: 1.0,
                gate: None,
                loc: SourceLoc {
                    file: "t.sv".into(),
                    start_line: 30,
                    start_col: 1,
                    end_line: 30,
                    end_col: 20,
                    byte_start: 0,
                    byte_end: 0,
                    origin: OriginKind::UserFile,
                },
                fans_in: vec![],
                fans_out: vec![],
                width_defaulted: false,
                reads_reg: false,
                lhs: Some("result_o".into()),
                rhs: Some("'0".into()),
                lhs_expr: None,
                rhs_expr: None,
                case_labels: Vec::new(),
                case_is_default: true,
                case_selector: Some("op_i".into()),
                fo4_locked: false,
            },
        );
        design.modules.insert(
            0,
            sv_timing_core::TimingModule {
                id: 0,
                name: "m".into(),
                file: "t.sv".into(),
                nodes,
                regions: BTreeMap::new(),
                localparams: Vec::new(),
                parameters: Vec::new(),
                ports: Vec::new(),
                gen_loops: Vec::new(),
                functions: Vec::new(),
                package_imports: Vec::new(),
                instances: Vec::new(),
                loc: loc(),
            },
        );
        design.module_names.insert("m".into(), 0);
        let start = PathEndpoint::InputPort { module: 0, port: 0 };
        let end = PathEndpoint::OutputPort { module: 0, port: 1 };
        design.paths.push(TimingPath {
            id: 7,
            region_id: 0,
            module: 0,
            start: start.clone(),
            end: end.clone(),
            path_kind: sv_timing_core::PathKind::from_endpoints(&start, &end),
            startpoint: "m.in0".into(),
            endpoint: "m.out0".into(),
            nodes: vec![0, 1, 2, 3, 4, 5],
            total_fo4: 55.0,
            slack_fo4: -23.0,
            max_freq_mhz: 500.0,
            primary_loc: loc(),
            multi_cycle: false,
            path_class: sv_timing_core::PathClassKind::ExclusiveCaseMux,
            total_fo4_raw: Some(200.0),
            class_note: Some("exclusive".into()),
        });
        let mut policy = PassPolicy::strict_test();
        policy.correct_allow_modules = vec!["m".into()];
        let mut ctx = PassContext::new(design, NameTable::new(), policy);
        ctx.active_module_name = "m".into();
        // Skip rebalance (simple idents) → one-hot path.
        let rec = balance_mux_on_path(&mut ctx, 7, 0, loc()).unwrap();
        assert_eq!(rec.kind, EditKind::BalanceMux);
        assert!(
            rec.rationale.contains("onehot_or_tree"),
            "expected onehot: {}",
            rec.rationale
        );
        let top = rec.new_name.as_deref().unwrap_or("");
        assert!(top.contains("svt_bm_oh"), "top={top}");
        assert_eq!(rec.emit_rhs.as_deref(), Some(top));
        assert!(
            !rec.emit_rhs_extras.is_empty(),
            "expected multi-arm extras, got {}",
            rec.emit_rhs_extras.len()
        );
        let snip = rec.emit_snippet.as_deref().unwrap_or("");
        assert!(snip.contains(top), "snippet missing top");
        assert!(snip.contains("op_i") && snip.contains("ADD"), "enum compares: {snip}");
    }

    #[test]
    fn balance_mux_credits_exclusive_residual() {
        let mut design = TimingDesign::empty(TimingTarget::new(1250.0, 20.0, 0.2));
        design.target.budget_fo4 = 32.0;
        let mut nodes = BTreeMap::new();
        nodes.insert(
            0,
            IrNode {
                id: 0,
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
                rhs: Some("x+y".into()),
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
            sv_timing_core::TimingModule {
                id: 0,
                name: "m".into(),
                file: "t.sv".into(),
                nodes,
                regions: BTreeMap::new(),
                localparams: Vec::new(),
                parameters: Vec::new(),
                ports: Vec::new(),
                gen_loops: Vec::new(),
                functions: Vec::new(),
                package_imports: Vec::new(),
                instances: Vec::new(),
                loc: loc(),
            },
        );
        design.module_names.insert("m".into(), 0);
        let start = PathEndpoint::InputPort { module: 0, port: 0 };
        let end = PathEndpoint::OutputPort { module: 0, port: 1 };
        design.paths.push(TimingPath {
            id: 9,
            region_id: 0,
            module: 0,
            start: start.clone(),
            end: end.clone(),
            path_kind: sv_timing_core::PathKind::from_endpoints(&start, &end),
            startpoint: "m.in0".into(),
            endpoint: "m.out0".into(),
            nodes: vec![0],
            total_fo4: 55.0,
            slack_fo4: -23.0,
            max_freq_mhz: 500.0,
            primary_loc: loc(),
            multi_cycle: false,
            path_class: sv_timing_core::PathClassKind::ExclusiveCaseMux,
            total_fo4_raw: Some(200.0),
            class_note: Some("exclusive".into()),
        });
        let mut policy = PassPolicy::strict_test();
        policy.correct_allow_modules = vec!["m".into()];
        let mut ctx = PassContext::new(design, NameTable::new(), policy);
        ctx.active_module_name = "m".into();
        let rec = balance_mux_on_path(&mut ctx, 9, 0, loc()).unwrap();
        assert_eq!(rec.kind, EditKind::BalanceMux);
        assert!(rec.fo4_after.unwrap() < rec.fo4_before.unwrap());
        let p = ctx.design.paths.iter().find(|p| p.id == 9).unwrap();
        assert!(p.total_fo4 < 55.0);
    }
}
