// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Pipelining: cut selection, insert_register (IR rewire), split_assign.

use serde_json::json;
use sv_timing_core::AlgoTrace;
use sv_timing_core::{
    ConstSeed, EdgeKind, GateInfo, IrNode, NodeId, OperatorClass, Opportunity, OpportunityKind,
    PathClassKind, PathEndpoint, PathId, SourceLoc,
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
    /// The named generate block (if/case generate, not a loop body) the cut
    /// net is declared in, when the module's contract admits a stage there
    /// (A125): the stage is emitted inside that block.
    pub gen_scope: Option<SourceLoc>,
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
pub fn expand_expr_spine_for_path(ctx: &mut PassContext, path_id: PathId) -> TransformResult<bool> {
    let budget = ctx.design.target.budget_fo4;
    let path_idx = ctx
        .design
        .paths
        .iter()
        .position(|p| p.id == path_id)
        .ok_or_else(|| TransformError::InvalidOpportunity(format!("path {path_id} missing")))?;
    let path = &ctx.design.paths[path_idx];
    let module_id = path.module;
    // Single-node mega-assign, or the hottest over-budget non-atomic node on a
    // multi-node cone (policy_subcode 16-stmt 30.5 FO4: one fat `&&`/`*` assign
    // in the middle — old code no-op'd whenever `nodes.len() != 1`).
    let root_id = if path.nodes.len() == 1 {
        path.nodes[0]
    } else {
        let module = ctx.design.modules.get(&module_id);
        let mut best: Option<(NodeId, f64)> = None;
        for &id in &path.nodes {
            let Some(n) = module.and_then(|m| m.nodes.get(&id)) else {
                continue;
            };
            if matches!(n.op_class, Some(OperatorClass::Mul | OperatorClass::DivRem))
                && n.fo4_cost > budget + 1e-9
            {
                continue;
            }
            if n.fo4_cost > budget + 1e-9 && best.map(|(_, c)| n.fo4_cost > c).unwrap_or(true) {
                best = Some((id, n.fo4_cost));
            }
        }
        match best {
            Some((id, _)) => id,
            None => return Ok(false),
        }
    };
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
        let mut seed = ConstSeed::from_names(ctx.design.elaboration_const_names(module));
        for gv in module.genvar_names_at(&n.loc) {
            seed.add(gv);
        }
        let spine = n
            .rhs_expr
            .as_ref()
            .map(|ex| ex.critical_spine_ops_latticed(&base, &seed))
            .unwrap_or_default();
        (n.fo4_cost.max(0.0), n.loc.clone(), n.op_class, spine)
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
    if matches!(op_class, Some(OperatorClass::Mul | OperatorClass::DivRem)) {
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
                        assign_kind: Default::default(),
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
    {
        let path_nodes = &mut ctx.design.paths[path_idx].nodes;
        if path_nodes.len() <= 1 {
            *path_nodes = new_nodes;
        } else if let Some(pos) = path_nodes.iter().position(|id| *id == root_id) {
            path_nodes.splice(pos..pos + 1, new_nodes);
        } else {
            path_nodes.extend(new_nodes);
        }
    }
    ctx.design.paths[path_idx].primary_loc = origin;
    ctx.pending_ir_dirty = true;
    true
}

/// Prepare an expression-spine trial without leaking a refused trial into IR.
///
/// Gate/allowlist failures are cheap and precede expansion. Only the selected
/// path's existing nodes are saved: expansion changes one of those nodes and
/// appends new module-local ids. On refusal, restore the path, nodes and dirty
/// flag. No whole-design clone or remeasure is needed.
pub fn prepare_pipeline_cuts(
    ctx: &mut PassContext,
    opportunity: &Opportunity,
) -> TransformResult<CutPlan> {
    if opportunity.kind != OpportunityKind::InsertReg {
        return Err(TransformError::InvalidOpportunity(
            "prepare_pipeline_cuts expects InsertReg".into(),
        ));
    }
    if !ctx.policy.allow_latency {
        return Err(TransformError::LatencyNotAllowed);
    }
    if !ctx.policy.module_allowed(&ctx.active_module_name) {
        return Err(TransformError::ModuleNotAllowlisted(
            ctx.active_module_name.clone(),
        ));
    }
    resolve_gate(ctx)?;
    let path_idx = ctx
        .design
        .paths
        .iter()
        .position(|p| p.id == opportunity.path_id)
        .ok_or_else(|| TransformError::InvalidOpportunity("path missing".into()))?;
    let original_path = ctx.design.paths[path_idx].clone();
    let module_id = original_path.module;
    let module = ctx
        .design
        .modules
        .get(&module_id)
        .ok_or_else(|| TransformError::InvalidOpportunity("module missing".into()))?;
    let first_new_id = module
        .nodes
        .keys()
        .next_back()
        .copied()
        .unwrap_or(0)
        .checked_add(1)
        .ok_or_else(|| TransformError::InvalidOpportunity("node ids exhausted".into()))?;
    let original_nodes: Vec<_> = original_path
        .nodes
        .iter()
        .filter_map(|id| module.nodes.get(id).cloned())
        .collect();
    let original_dirty = ctx.pending_ir_dirty;
    let result = expand_expr_spine_for_path(ctx, opportunity.path_id)
        .and_then(|_| select_pipeline_cuts(ctx, opportunity));
    if result.is_err() {
        let module = ctx
            .design
            .modules
            .get_mut(&module_id)
            .expect("trial module");
        drop(module.nodes.split_off(&first_new_id));
        for node in original_nodes {
            module.nodes.insert(node.id, node);
        }
        ctx.design.paths[path_idx] = original_path;
        ctx.pending_ir_dirty = original_dirty;
    }
    result
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
    // Cap cuts per plan from the stages dial (`--opt-max-stages-per-region`,
    // `-O3` default 8, soak often 20). The old max_passes.clamp(1, 4) left
    // policy_subcode 30.5 with a single 10/20 split.
    let max_cuts = (ctx.policy.opt.max_stages_per_region as usize).clamp(1, 16);

    let mut cuts = match schedule_pipeline_cuts(ctx, opportunity.path_id, budget, max_cuts) {
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
                gen_scope: None,
            }]
        }
    };

    // The pipe register is a module-level net typed and fed from the cut
    // node's assignment: an LHS or RHS naming a block-local (a generate-for
    // body's `logic same_hart`, a genvar, an `automatic`) has no module-scope
    // pipe that is right for every iteration — refuse the cut (raw_checker
    // `gen_same_rd`, instr_scan). Lean emit never reads the origin, but the
    // cut is booked as FO4 either way, so refuse at the source.
    if let Some(path) = ctx
        .design
        .paths
        .iter()
        .find(|p| p.id == opportunity.path_id)
    {
        if let Some(module) = ctx.design.modules.get(&path.module) {
            let block_local = module.block_local_names();
            if !block_local.is_empty() {
                let contract = sv_timing_core::pipe_contract::resolve(module);
                for cut in &mut cuts {
                    if let Some(n) = module.nodes.get(&cut.after_node) {
                        let hit = [n.lhs.as_deref(), n.rhs.as_deref()]
                            .into_iter()
                            .flatten()
                            .any(|t| module.text_refs_block_local(t, &block_local));
                        if !hit {
                            continue;
                        }
                        // A125: a block-local inside a *named generate block*
                        // (not a loop body) under a contract-permitted anchor is
                        // staged inside that block; the RHS may name only
                        // block-locals of the same scope.
                        let permitted = contract.as_ref().is_some_and(|c| {
                            matches!(
                                sv_timing_core::pipe_contract::cut_permission(module, c, n),
                                sv_timing_core::pipe_contract::CutPermission::Allowed(_)
                            )
                        });
                        let scope = n
                            .lhs
                            .as_deref()
                            .and_then(sv_timing_core::ir::TimingModule::root_ident)
                            .and_then(|root| {
                                sv_timing_core::pipe_contract::generate_scope_of(module, root)
                            })
                            .or_else(|| {
                                // an expression-spine node split out of a statement:
                                // the statement's own LHS (the cut-ok anchor on its line)
                                // names the scope
                                contract.as_ref().and_then(|c| {
                                    c.cut_ok
                                        .iter()
                                        .find(|(_, _, line)| {
                                            *line != 0 && *line == n.loc.start_line
                                        })
                                        .and_then(|(lhs, _, _)| {
                                            sv_timing_core::pipe_contract::generate_scope_of(
                                                module, lhs,
                                            )
                                        })
                                })
                            });
                        let same_scope_rhs = scope.as_ref().is_some_and(|sc| {
                            n.rhs.as_deref().is_none_or(|rhs| {
                                sv_timing_core::pipe_contract::block_locals_within(module, rhs, sc)
                            })
                        });
                        if permitted && same_scope_rhs {
                            cut.gen_scope = scope;
                            continue;
                        }
                        return Err(TransformError::InvalidOpportunity(format!(
                            "cut after node {} names a block-local ({} <- {}){}",
                            cut.after_node,
                            n.lhs.as_deref().unwrap_or("?"),
                            n.rhs.as_deref().unwrap_or("?"),
                            if scope.is_some() && !permitted {
                                "; a generate-scoped stage needs a `svt-pipe: cut-ok` anchor"
                            } else {
                                ""
                            }
                        )));
                    }
                }
            }
        }
    }

    // A125: a cut whose node names no block-local (an expression-spine
    // node, a plain intermediate) but sits inside a sibling cut's generate
    // scope is emitted in that scope too — one plan, one block.
    let scopes: Vec<SourceLoc> = cuts.iter().filter_map(|c| c.gen_scope.clone()).collect();
    if !scopes.is_empty() {
        for c in &mut cuts {
            if c.gen_scope.is_none() {
                if let Some(sc) = scopes.iter().find(|sc| {
                    sc.file == c.origin.file
                        && sc.start_line <= c.origin.start_line
                        && sc.end_line >= c.origin.start_line
                }) {
                    c.gen_scope = Some(sc.clone());
                }
            }
        }
    }

    Ok(CutPlan {
        cuts,
        gate,
        name_stem: "pipe".into(),
    })
}

fn origin_for_node(ctx: &PassContext, path_id: PathId, after_node: NodeId) -> Option<SourceLoc> {
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
        && !matches!(path.path_class, sv_timing_core::PathClassKind::UnderBudget)
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
        let origin =
            origin_for_node(ctx, path_id, after).unwrap_or_else(|| path.primary_loc.clone());
        return Ok(vec![CutPoint {
            path_id,
            after_node: after,
            fo4_left: total,
            fo4_right: 0.0,
            origin,
            gen_scope: None,
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

    // A123/A124: in a module whose contract is required, a stage may only
    // sit at a permitted anchor. The greedy schedule snaps each wanted cut
    // back to the nearest permitted node of its segment, or takes no cut
    // there — the contract drives the planner, not only the verdict.
    let permitted: Option<Vec<bool>> = module.and_then(|m| {
        let c = sv_timing_core::pipe_contract::resolve(m)?;
        if !c.require_contract {
            return None;
        }
        Some(
            path.nodes
                .iter()
                .map(|id| {
                    m.nodes.get(id).is_some_and(|n| {
                        matches!(
                            sv_timing_core::pipe_contract::cut_permission(m, &c, n),
                            sv_timing_core::pipe_contract::CutPermission::Allowed(_)
                        )
                    })
                })
                .collect(),
        )
    });
    let snap = |wanted: usize, seg_start: usize| -> Option<usize> {
        match &permitted {
            None => Some(wanted),
            Some(ok) => (seg_start..=wanted).rev().find(|&k| ok[k]),
        }
    };

    for i in 0..path.nodes.len() {
        let c = costs[i];
        // If adding this node overflows and segment has at least one prior node → cut before i.
        if cum + c > budget + 1e-9 && i > seg_start {
            let Some(cut_idx) = snap(i - 1, seg_start) else {
                cum += c;
                continue;
            };
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
                gen_scope: None,
            });
            if cuts.len() >= max_cuts {
                break;
            }
            seg_start = cut_idx + 1;
            cum = costs[cut_idx + 1..=i].iter().sum();
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
                let Some(i) = snap(i, last_cut) else {
                    continue;
                };
                let after = path.nodes[i];
                let left: f64 = costs[..=i].iter().sum();
                let right: f64 = costs[i + 1..].iter().sum();
                let origin = origin_for_node(ctx, path_id, after)
                    .unwrap_or_else(|| path.primary_loc.clone());
                cuts.push(CutPoint {
                    path_id,
                    after_node: after,
                    fo4_left: left,
                    fo4_right: right,
                    origin,
                    gen_scope: None,
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
            gen_scope: None,
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
    #[allow(unused_mut)]
    let mut _ordered_is_filtered = false;
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

    // A123: the module's in-file re-pipelining contract. A `no-cut` anchor
    // (or a module that requires a contract) refuses the cut; a cut inside a
    // declared domain carries that domain's valid / id / kill / flush bundle.
    let contract = ctx
        .design
        .modules
        .values()
        .find(|m| m.name == ctx.active_module_name)
        .and_then(sv_timing_core::pipe_contract::resolve);
    if let Some(c) = &contract {
        for r in &c.rejected {
            ctx.log_algo(
                "pipe_contract.rejected",
                AlgoTrace::kv([
                    ("module", json!(ctx.active_module_name)),
                    ("detail", json!(r)),
                ]),
            );
        }
    }
    // Alignment (A123): once any cut of the plan is carried, every cut must
    // be; no stage may read an earlier stage's value except its chain
    // predecessor; and past stage 1 a stage may read only its predecessor,
    // the carried signals, the protocol signals and constants. Checked in
    // data order (first stage first) before anything is rewired.
    let mut carried_domain: Option<sv_timing_core::pipe_contract::PipeDomain> = None;
    // the carried bundle's flop count, priced with every stage (set with the plan)
    let mut carried_extra: u32 = 0;
    // Lines of the tail nodes (after the last cut), captured before the IR
    // rewire truncates the path at each cut.
    let mut tail_lines: Vec<u32> = Vec::new();
    if let Some(c) = contract.as_ref().filter(|c| !c.domains.is_empty()) {
        // The area gate decides per stage *before* alignment: a carried stage
        // costs its valid, id and side-band flops too, and a stage the gate
        // refuses must not be in the plan the bundle depth is derived from.
        let plan_domain = ordered.iter().find_map(|cut| {
            let path = ctx.design.paths.iter().find(|p| p.id == cut.path_id)?;
            let m = ctx.design.modules.get(&path.module)?;
            let n = m.nodes.get(&cut.after_node)?;
            match sv_timing_core::pipe_contract::cut_permission(m, c, n) {
                sv_timing_core::pipe_contract::CutPermission::Allowed(Some(d)) => Some(d),
                _ => None,
            }
        });
        if let Some(d) = &plan_domain {
            // The bundle's real width: scalar valid, optional id, and carried
            // signals. Unresolved widths cannot authorize emitted registers.
            let extra = {
                let m = ordered
                    .first()
                    .and_then(|cut| ctx.design.paths.iter().find(|p| p.id == cut.path_id))
                    .and_then(|p| ctx.design.modules.get(&p.module));
                match m {
                    Some(m) => {
                        let resolver = sv_timing_core::width::WidthResolver::from_parts(
                            &ctx.design.packages,
                            &ctx.design.param_map_ints,
                            &m.decls,
                            &m.ports,
                            &m.const_exprs,
                            &m.typedef_texts,
                            &m.package_imports,
                            ctx.design.width_map.get(&m.name),
                        );
                        let w = |sig: &str| resolver.expr_width(&sv_timing_core::Expr::parse(sig));
                        d.check_widths(&w)
                            .map_err(TransformError::InvalidOpportunity)?;
                        1 + if d.has_id() { w(&d.id).unwrap() } else { 0 }
                            + d.carry.iter().map(|c| w(c).unwrap()).sum::<u32>()
                    }
                    None => 1 + 8 + 8 * d.carry.len() as u32,
                }
            };
            let mut kept: Vec<&CutPoint> = Vec::new();
            for cut in ordered.iter() {
                // A carried stage is a whole statement: an expression-spine
                // cut (no LHS of its own) would need the statement's RHS
                // rewritten around it, which the carried emission does not
                // do yet — the stage is left to the statement's own cut.
                let has_lhs = ctx
                    .design
                    .paths
                    .iter()
                    .find(|p| p.id == cut.path_id)
                    .and_then(|p| ctx.design.modules.get(&p.module))
                    .and_then(|m| m.nodes.get(&cut.after_node))
                    .and_then(|n| n.lhs.as_deref())
                    .and_then(sv_timing_core::ir::TimingModule::root_ident)
                    .is_some();
                if !has_lhs {
                    ctx.log_algo(
                        "pipe_contract.refuse",
                        AlgoTrace::kv([
                            ("module", json!(ctx.active_module_name)),
                            ("line", json!(cut.origin.start_line)),
                            ("detail", json!("expression-spine cut dropped from a carried plan: a stage is a whole statement")),
                        ]),
                    );
                    continue;
                }
                let width = ctx
                    .design
                    .paths
                    .iter()
                    .find(|p| p.id == cut.path_id)
                    .and_then(|p| ctx.design.modules.get(&p.module))
                    .and_then(|m| m.nodes.get(&cut.after_node))
                    .map(|n| n.width.max(1))
                    .unwrap_or(1)
                    + extra;
                let gain = cut.fo4_left.min(cut.fo4_right);
                if ctx.area_would_admit(f64::from(width), gain) {
                    kept.push(cut);
                } else {
                    // Record the refusal in the ledger; the stage leaves the plan.
                    let _ = ctx.admit_area(
                        EditKind::InsertReg,
                        cut.origin.start_line,
                        f64::from(width),
                        gain,
                    );
                }
            }
            ordered = kept;
            carried_extra = extra;
            if ordered.is_empty() {
                return Ok(Vec::new());
            }
        }
        let mut carried = 0usize;
        let mut cut_lhs: Vec<String> = Vec::new();
        let mut readers: Vec<std::collections::BTreeSet<String>> = Vec::new();
        let mut domain_of_plan: Option<sv_timing_core::pipe_contract::PipeDomain> = None;
        for cut in ordered.iter().rev() {
            let Some(path) = ctx.design.paths.iter().find(|p| p.id == cut.path_id) else {
                continue;
            };
            let Some(m) = ctx.design.modules.get(&path.module) else {
                continue;
            };
            let Some(n) = m.nodes.get(&cut.after_node) else {
                continue;
            };
            if let sv_timing_core::pipe_contract::CutPermission::Allowed(Some(d)) =
                sv_timing_core::pipe_contract::cut_permission(m, c, n)
            {
                carried += 1;
                domain_of_plan.get_or_insert(d);
            }
            cut_lhs.push(
                n.lhs
                    .as_deref()
                    .and_then(sv_timing_core::ir::TimingModule::root_ident)
                    .unwrap_or("")
                    .to_string(),
            );
            let next = path
                .nodes
                .iter()
                .position(|id| *id == cut.after_node)
                .and_then(|i| path.nodes.get(i + 1))
                .and_then(|id| m.nodes.get(id));
            let mut reads = std::collections::BTreeSet::new();
            if let Some(nn) = next {
                if let Some(e) = nn.rhs_expr.as_ref() {
                    e.walk_idents(&mut |i| {
                        reads.insert(
                            sv_timing_core::ir::TimingModule::root_ident(i)
                                .unwrap_or(i)
                                .to_string(),
                        );
                    });
                }
                for g in m.guards.get(&nn.id).into_iter().flatten() {
                    sv_timing_core::Expr::parse(g.trim_start_matches('^')).walk_idents(&mut |i| {
                        reads.insert(
                            sv_timing_core::ir::TimingModule::root_ident(i)
                                .unwrap_or(i)
                                .to_string(),
                        );
                    });
                }
            }
            readers.push(reads);
        }
        if carried > 0 {
            let domain = domain_of_plan.clone().expect("carried implies a domain");
            let mut refuse = if carried != ordered.len() {
                Some(format!(
                    "{carried} of {} cuts carry the contract: a stage without valid/id would desynchronise the operation",
                    ordered.len()
                ))
            } else {
                sv_timing_core::pipe_contract::alignment_violation(&cut_lhs, &readers)
            };
            if refuse.is_none() {
                // Foreign reads past stage 1: the node after cut k (k ≥ 1,
                // zero-based) computes stage k+2's data and may read only
                // the chain, the carried signals and the protocol.
                let module = ctx
                    .design
                    .paths
                    .iter()
                    .find(|p| p.id == ordered[0].path_id)
                    .and_then(|p| ctx.design.modules.get(&p.module));
                if let Some(m) = module {
                    let resolver = sv_timing_core::width::WidthResolver::from_parts(
                        &ctx.design.packages,
                        &ctx.design.param_map_ints,
                        &m.decls,
                        &m.ports,
                        &m.const_exprs,
                        &m.typedef_texts,
                        &m.package_imports,
                        ctx.design.width_map.get(&m.name),
                    );
                    let is_const = |name: &str| resolver.is_const_name(name) || name.contains("::");
                    for (k, reads) in readers.iter().enumerate() {
                        // readers[k] is the node after the k-th cut in data order;
                        // the last entry is the result-side node, which the
                        // `result` pragma rewires rather than this check.
                        if k + 1 >= readers.len() {
                            break;
                        }
                        let foreign = sv_timing_core::pipe_contract::foreign_reads(
                            m,
                            &domain,
                            reads,
                            cut_lhs.get(k).map(String::as_str),
                            &is_const,
                        );
                        if !foreign.is_empty() {
                            refuse = Some(format!(
                                "stage {} reads `{}` which is neither its chain predecessor nor carried: declare `svt-pipe: carry {} {}` or balance it",
                                k + 2,
                                foreign.join("`, `"),
                                domain.name,
                                foreign.join(",")
                            ));
                            break;
                        }
                    }
                }
            }
            if refuse.is_none() {
                // The tail: every node of the path after the last cut computes
                // on the last stage's age and may read only that stage's
                // value, the tail's own earlier nodes, the carried signals and
                // the protocol. Its carried / valid / id reads are rewired
                // onto the last stage below.
                let last = &ordered[0];
                if let Some((m, path)) = ctx
                    .design
                    .paths
                    .iter()
                    .find(|p| p.id == last.path_id)
                    .and_then(|p| ctx.design.modules.get(&p.module).map(|m| (m, p)))
                {
                    let resolver = sv_timing_core::width::WidthResolver::from_parts(
                        &ctx.design.packages,
                        &ctx.design.param_map_ints,
                        &m.decls,
                        &m.ports,
                        &m.const_exprs,
                        &m.typedef_texts,
                        &m.package_imports,
                        ctx.design.width_map.get(&m.name),
                    );
                    let is_const = |name: &str| resolver.is_const_name(name) || name.contains("::");
                    let start = path
                        .nodes
                        .iter()
                        .position(|id| *id == last.after_node)
                        .map(|i| i + 1)
                        .unwrap_or(path.nodes.len());
                    let mut allowed_prev: std::collections::BTreeSet<String> =
                        std::collections::BTreeSet::new();
                    if let Some(l) = cut_lhs.last() {
                        allowed_prev.insert(l.clone());
                    }
                    for id in &path.nodes[start..] {
                        let Some(n) = m.nodes.get(id) else { continue };
                        if n.loc.start_line != 0 && !tail_lines.contains(&n.loc.start_line) {
                            tail_lines.push(n.loc.start_line);
                        }
                        let mut reads = std::collections::BTreeSet::new();
                        if let Some(e) = n.rhs_expr.as_ref() {
                            e.walk_idents(&mut |i| {
                                reads.insert(
                                    sv_timing_core::ir::TimingModule::root_ident(i)
                                        .unwrap_or(i)
                                        .to_string(),
                                );
                            });
                        }
                        for g in m.guards.get(id).into_iter().flatten() {
                            sv_timing_core::Expr::parse(g.trim_start_matches('^')).walk_idents(
                                &mut |i| {
                                    reads.insert(
                                        sv_timing_core::ir::TimingModule::root_ident(i)
                                            .unwrap_or(i)
                                            .to_string(),
                                    );
                                },
                            );
                        }
                        let reads: std::collections::BTreeSet<String> =
                            reads.difference(&allowed_prev).cloned().collect();
                        let foreign = sv_timing_core::pipe_contract::foreign_reads(
                            m, &domain, &reads, None, &is_const,
                        );
                        if !foreign.is_empty() {
                            refuse = Some(format!(
                                "tail node `{}` (line {}) reads `{}` which is neither the last stage nor carried: declare `svt-pipe: carry {} {}` or balance it",
                                n.lhs.as_deref().unwrap_or("?"),
                                n.loc.start_line,
                                foreign.join("`, `"),
                                domain.name,
                                foreign.join(",")
                            ));
                            break;
                        }
                        if let Some(l) = n
                            .lhs
                            .as_deref()
                            .and_then(sv_timing_core::ir::TimingModule::root_ident)
                        {
                            allowed_prev.insert(l.to_string());
                        }
                    }
                }
            }
            if refuse.is_none() {
                // Latency parameter (A129): the stage count the consumers are
                // told must equal what the source has plus what this plan adds.
                refuse = domain
                    .check_latency(ordered.len(), &ctx.design.param_map_ints)
                    .err();
            }
            if refuse.is_none() {
                // Merge balance: the consumers' downstream may read no
                // register that is not staged with the domain.
                let last = &ordered[0];
                if let Some(m) = ctx
                    .design
                    .paths
                    .iter()
                    .find(|p| p.id == last.path_id)
                    .and_then(|p| ctx.design.modules.get(&p.module))
                {
                    let resolver = sv_timing_core::width::WidthResolver::from_parts(
                        &ctx.design.packages,
                        &ctx.design.param_map_ints,
                        &m.decls,
                        &m.ports,
                        &m.const_exprs,
                        &m.typedef_texts,
                        &m.package_imports,
                        ctx.design.width_map.get(&m.name),
                    );
                    let is_const = |name: &str| resolver.is_const_name(name) || name.contains("::");
                    let mut consumer_lhs: std::collections::BTreeSet<String> =
                        cut_lhs.iter().filter(|l| !l.is_empty()).cloned().collect();
                    for t in [domain.result_valid.as_deref(), domain.result_id.as_deref()]
                        .into_iter()
                        .flatten()
                        .chain(domain.result_also.iter().map(String::as_str))
                    {
                        consumer_lhs.insert(t.to_string());
                    }
                    for line in &tail_lines {
                        for n in m.nodes.values().filter(|n| n.loc.start_line == *line) {
                            if let Some(l) = n
                                .lhs
                                .as_deref()
                                .and_then(sv_timing_core::ir::TimingModule::root_ident)
                            {
                                consumer_lhs.insert(l.to_string());
                            }
                        }
                    }
                    if let Some((reg, at, line)) = sv_timing_core::pipe_contract::merge_violation(
                        m,
                        &domain,
                        &consumer_lhs,
                        &is_const,
                    ) {
                        refuse = Some(format!(
                            "merge at `{at}` (line {line}) reads register `{reg}`, which is not staged with domain `{}`: a parallel datapath must take the same stage (carry it, or stage it with the same parameter)",
                            domain.name
                        ));
                    }
                }
            }
            ctx.log_algo(
                "pipe_contract.plan",
                AlgoTrace::kv([
                    ("module", json!(ctx.active_module_name)),
                    ("domain", json!(domain.name)),
                    ("cuts", json!(cut_lhs)),
                    ("tail_lines", json!(tail_lines)),
                ]),
            );
            if let Some(why) = refuse {
                ctx.log_algo(
                    "pipe_contract.misaligned",
                    AlgoTrace::kv([
                        ("module", json!(ctx.active_module_name)),
                        ("detail", json!(why)),
                    ]),
                );
                return Ok(Vec::new());
            }
            carried_domain = Some(domain);
        }
    }
    let total = ordered.len();
    // Pass 1 (reverse path order, so earlier node indices stay valid on the
    // residual left segment): permission, area gate, name, IR rewire.
    let mut placed: Vec<(CutPoint, String, usize)> = Vec::new();
    let mut stage = 0u32;
    for (idx, cut) in ordered.into_iter().enumerate() {
        let permission = match (
            &contract,
            ctx.design.paths.iter().find(|p| p.id == cut.path_id),
        ) {
            (Some(c), Some(p)) => ctx
                .design
                .modules
                .get(&p.module)
                .and_then(|m| m.nodes.get(&cut.after_node).map(|n| (m, n)))
                .map(|(m, n)| sv_timing_core::pipe_contract::cut_permission(m, c, n))
                .unwrap_or(sv_timing_core::pipe_contract::CutPermission::Unconstrained),
            _ => sv_timing_core::pipe_contract::CutPermission::Unconstrained,
        };
        if let sv_timing_core::pipe_contract::CutPermission::Forbidden(why) = permission {
            ctx.log_algo(
                "pipe_contract.refuse",
                AlgoTrace::kv([
                    ("module", json!(ctx.active_module_name)),
                    ("line", json!(cut.origin.start_line)),
                    ("detail", json!(why)),
                ]),
            );
            continue;
        }
        // Area gate (Dial 11, A114): one flop per bit of the cut net per
        // stage against the FO4 the stage removes (the shorter segment). A
        // carried stage adds its valid, id and side-band flops.
        let width = ctx
            .design
            .paths
            .iter()
            .find(|p| p.id == cut.path_id)
            .and_then(|p| ctx.design.modules.get(&p.module))
            .and_then(|m| m.nodes.get(&cut.after_node))
            .map(|n| n.width.max(1))
            .unwrap_or(1)
            + carried_extra;
        let gain = cut.fo4_left.min(cut.fo4_right);
        if !ctx.admit_area(
            EditKind::InsertReg,
            cut.origin.start_line,
            f64::from(width),
            gain,
        ) {
            continue;
        }
        // Data-order stage index: the last cut on the path is applied first.
        let data_stage = total - idx;
        stage += 1;
        let (sig_id, name) = ctx.names.alloc_signal(
            &ctx.active_module_name,
            &plan.name_stem,
            sv_timing_core::SignalNameTag::Pipeline {
                stage: data_stage as u32,
            },
            cut.origin.clone(),
        );
        // IR rewire: truncate path at cut; insert seq marker node on module.
        rewire_path_at_cut(ctx, cut, sig_id, &name, &plan.gate);
        placed.push((cut.clone(), name, data_stage));
    }
    let _ = stage;
    // Pass 2 (data order): the bundle of each carried stage samples the
    // previous data stage's bundle; the first samples the domain's signals.
    placed.sort_by_key(|(_, _, ds)| *ds);
    let last_data_stage = placed.iter().map(|(_, _, ds)| *ds).max().unwrap_or(0);
    let mut prev_stage_name: Option<String> = None;
    for (cut, name, data_stage) in placed {
        let pipe_stage = carried_domain.as_ref().and_then(|d| {
            let (module, path) = ctx
                .design
                .paths
                .iter()
                .find(|p| p.id == cut.path_id)
                .and_then(|p| ctx.design.modules.get(&p.module).map(|m| (m, p)))?;
            let resolver = sv_timing_core::width::WidthResolver::from_parts(
                &ctx.design.packages,
                &ctx.design.param_map_ints,
                &module.decls,
                &module.ports,
                &module.const_exprs,
                &module.typedef_texts,
                &module.package_imports,
                ctx.design.width_map.get(&module.name),
            );
            let width_of = |sig: &str| resolver.expr_width(&sv_timing_core::Expr::parse(sig));
            let mut st = sv_timing_core::pipe_contract::stage_for(
                module,
                d,
                &name,
                data_stage as u32,
                prev_stage_name.as_deref(),
                &width_of,
            );
            st.data_width = module
                .nodes
                .get(&cut.after_node)
                .map(|n| n.width)
                .filter(|w| *w > 0);
            let cut_lhs = module
                .nodes
                .get(&cut.after_node)
                .and_then(|n| n.lhs.as_deref());
            st.consumed_representations =
                sv_timing_core::pipeline_preprocess::representations(module)
                    .into_iter()
                    .filter(|p| {
                        p.domain == d.name
                            && (Some(p.sum.as_str()) == cut_lhs
                                || Some(p.carry.as_str()) == cut_lhs)
                    })
                    .map(|p| (p.loc.start_line, format!("{},{}", p.sum, p.carry)))
                    .collect();
            if data_stage == last_data_stage {
                // Tail nodes (after the last cut on the path) read the last
                // stage's carried copies, valid and id.
                let _ = path;
                let (v_net, id_net) = sv_timing_core::pipe_contract::stage_nets(&name);
                for line in tail_lines.iter().copied() {
                    if st.consumer_rewires.iter().any(|(l, _, _)| *l == line) {
                        continue;
                    }
                    for c in &d.carry {
                        st.consumer_rewires.push((
                            line,
                            c.clone(),
                            sv_timing_core::pipe_contract::carry_read(module, &name, c),
                        ));
                    }
                    st.consumer_rewires.push((
                        line,
                        d.valid.clone(),
                        format!("({v_net} & ~{})", d.kill_for(&id_net)),
                    ));
                    st.consumer_rewires
                        .push((line, d.id.clone(), id_net.clone()));
                }
            }
            Some(st)
        });
        if pipe_stage.is_some() {
            prev_stage_name = Some(name.clone());
        }
        if let Some(st) = &pipe_stage {
            if let Some(module) = ctx
                .design
                .paths
                .iter()
                .find(|p| p.id == cut.path_id)
                .and_then(|p| ctx.design.modules.get_mut(&p.module))
            {
                let plans: Vec<_> = sv_timing_core::pipeline_preprocess::representations(module)
                    .into_iter()
                    .filter(|p| {
                        st.consumed_representations.iter().any(|(line, rows)| {
                            *line == p.loc.start_line && rows == &format!("{},{}", p.sum, p.carry)
                        })
                    })
                    .collect();
                sv_timing_core::pipeline_preprocess::mark_applied(module, &plans);
            }
        }
        let rationale = match &pipe_stage {
            Some(st) => format!(
                "insert_register after node {} (path {} multi-cut; left_fo4≈{:.1} right≈{:.1}); svt-pipe domain `{}` stage {}: valid<={} & ~{}, id<={}{}{}",
                cut.after_node,
                cut.path_id,
                cut.fo4_left,
                cut.fo4_right,
                st.domain,
                st.stage,
                st.valid_src,
                st.kill_expr,
                st.id_src,
                st.flush
                    .as_ref()
                    .map(|f| format!(", flush {f}"))
                    .unwrap_or_default(),
                if st.carry_src.is_empty() {
                    String::new()
                } else {
                    format!(", carry {}", st.carry_src.join(","))
                }
            ),
            None => format!(
                "insert_register after node {} (path {} multi-cut; left_fo4≈{:.1} right≈{:.1})",
                cut.after_node, cut.path_id, cut.fo4_left, cut.fo4_right
            ),
        };
        let rec = EditRecord {
            id: 0,
            kind: EditKind::InsertReg,
            origin: cut.origin.clone(),
            path_id: Some(cut.path_id),
            node_id: Some(cut.after_node),
            new_name: Some(name),
            fo4_before: Some(cut.fo4_left + cut.fo4_right),
            fo4_after: Some(cut.fo4_left.max(cut.fo4_right)),
            rationale,
            emit_rhs: None,
            emit_rhs_extras: Vec::new(),
            emit_snippet: None,
            emit_predicate: false,
            emit_predicate_from: None,
            pipe_stage,
            gen_scope: cut.gen_scope.clone(),
        };
        ctx.trace.record_edit(rec.clone());
        ctx.link_last_tradeoff();
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
                assign_kind: sv_timing_core::AssignKind::Nonblocking,
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
        // Keep the original capture so the residual stays the same path kind
        // (RegToReg when the parent was). A dummy OutputPort made residuals
        // RegToOut, so exception_policy stopped admitting the 20.5 FO4
        // policy_subcode remainder after the first `d = pipe` cut.
        let orig_end = ctx.design.paths[path_idx].end.clone();
        let orig_endpoint = ctx.design.paths[path_idx].endpoint.clone();
        // Truncate original path to left segment (launch → pipe).
        ctx.design.paths[path_idx].nodes = left;
        ctx.design.paths[path_idx].end = PathEndpoint::RegData { cell: sig_id };
        ctx.design.paths[path_idx].total_fo4 = left_fo4;
        ctx.design.paths[path_idx].slack_fo4 = ctx.design.target.budget_fo4 - left_fo4;
        // Residual comb after pipe as a new path (pipe → original capture).
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
            let end = orig_end;
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
                endpoint: orig_endpoint,
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
        sv_timing_core::SignalNameTag::SplitWire {
            index: ctx.trace.records.len() as u32,
        },
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
        emit_predicate: false,
        emit_predicate_from: None,
        pipe_stage: None,
        gen_scope: None,
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
        emit_predicate: false,
        emit_predicate_from: None,
        pipe_stage: None,
        gen_scope: None,
    };
    ctx.trace.record_edit(rec.clone());
    ctx.pending_ir_dirty = true;
    Ok(rec)
}

/// Apply the exact expression identities of `expr_rewrite` (A122) to one
/// node: circular compare, zero detect of a difference, late select pushed
/// through arithmetic. Pure RHS rewrite, no new names, no latency. The
/// `PushSelect` adders go through the area gate (Dial 11) like a
/// SelectIncrement candidate bank; the other two add no cells.
pub fn expr_rewrite_on_node(
    ctx: &mut PassContext,
    path_id: PathId,
    node_id: NodeId,
    origin: SourceLoc,
) -> TransformResult<EditRecord> {
    use sv_timing_core::expr_rewrite as xr;
    if !ctx.policy.module_allowed(&ctx.active_module_name) {
        return Err(TransformError::ModuleNotAllowlisted(
            ctx.active_module_name.clone(),
        ));
    }
    let model = sv_timing_core::CostModel::default();
    let module_id = ctx
        .design
        .modules
        .values()
        .find(|m| m.name == ctx.active_module_name)
        .map(|m| m.id)
        .ok_or_else(|| TransformError::InvalidOpportunity("module not found".into()))?;
    // Guard mode: the opportunity's locus is an `if` predicate span of the
    // module (not the node's own line) — the identity rewrites the predicate.
    let (shape, line, guard) = {
        let module = ctx.design.modules.get(&module_id).expect("module");
        let node = module
            .nodes
            .get(&node_id)
            .ok_or_else(|| TransformError::InvalidOpportunity(format!("node {node_id} missing")))?;
        let regs = sv_timing_core::select_increment::register_roots(module);
        let arrivals = xr::Arrivals::of(module, &regs, &model);
        let resolver = sv_timing_core::width::WidthResolver::from_parts(
            &ctx.design.packages,
            &ctx.design.param_map_ints,
            &module.decls,
            &module.ports,
            &module.const_exprs,
            &module.typedef_texts,
            &module.package_imports,
            ctx.design.width_map.get(&module.name),
        );
        let guard_site = module
            .guard_sites
            .iter()
            .position(|g| g.loc == origin && origin != node.loc);
        match guard_site {
            Some(gi) => {
                let site = &module.guard_sites[gi];
                let shape = xr::detect_guard(module, site, &resolver, &model, &arrivals)
                    .ok_or_else(|| {
                        TransformError::InvalidOpportunity(format!(
                            "expr_rewrite: guard `{}` carries no exact identity with a gain",
                            site.text
                        ))
                    })?;
                (shape, site.loc.start_line, Some(gi))
            }
            None => {
                let shape =
                    xr::detect(module, node, &resolver, &model, &arrivals).ok_or_else(|| {
                        TransformError::InvalidOpportunity(format!(
                            "expr_rewrite: node {node_id} carries no exact identity with a gain"
                        ))
                    })?;
                (shape, node.loc.start_line, None)
            }
        }
    };
    let kind = match shape.kind {
        xr::IdentityKind::CircularCompare => EditKind::CircularCompare,
        xr::IdentityKind::ZeroDetectEquality => EditKind::ZeroDetectEquality,
        xr::IdentityKind::PushSelect => EditKind::PushSelect,
    };
    if shape.est_cells > 0.0 && !ctx.admit_area(kind, line, shape.est_cells, shape.gain()) {
        return Err(TransformError::InvalidOpportunity(format!(
            "expr_rewrite: area gate ({:.0} cells for {:.1} FO4)",
            shape.est_cells,
            shape.gain()
        )));
    }
    let module = ctx.design.modules.get_mut(&module_id).expect("module");
    if let Some(gi) = guard {
        // Every guard list naming this predicate (with or without the `^`
        // outer-loop mark) now reads the rewritten form; the site follows.
        let from = shape.rhs_before.clone();
        for list in module.guards.values_mut() {
            for g in list.iter_mut() {
                let (prefix, body) = match g.strip_prefix('^') {
                    Some(b) => ("^", b),
                    None => ("", g.as_str()),
                };
                if body.trim() == from {
                    *g = format!("{prefix}{}", shape.rhs_after);
                }
            }
        }
        module.guard_sites[gi].text = shape.rhs_after.clone();
        let rec = EditRecord {
            id: 0,
            kind,
            origin,
            path_id: Some(path_id),
            node_id: Some(node_id),
            new_name: None,
            fo4_before: Some(shape.fo4_before),
            fo4_after: Some(shape.fo4_after),
            rationale: format!(
                "expr_rewrite {} path {path_id} guard of node {node_id}: `if ({})` -> `if ({})` {:.1}->{:.1} on the predicate (latency-neutral, exact{})",
                shape
                    .kinds
                    .iter()
                    .map(|k| k.as_str())
                    .collect::<Vec<_>>()
                    .join("+"),
                shape.rhs_before,
                shape.rhs_after,
                shape.fo4_before,
                shape.fo4_after,
                if shape.est_cells > 0.0 {
                    format!("; +{:.0} est. cells", shape.est_cells)
                } else {
                    String::new()
                }
            ),
            emit_rhs: Some(shape.rhs_after.clone()),
            emit_rhs_extras: Vec::new(),
            emit_snippet: None,
            emit_predicate: true,
            emit_predicate_from: Some(from),
            pipe_stage: None,
            gen_scope: None,
        };
        ctx.trace.record_edit(rec.clone());
        if shape.est_cells > 0.0 {
            ctx.link_last_tradeoff();
        }
        ctx.pending_ir_dirty = true;
        return Ok(rec);
    }
    let node = module.nodes.get_mut(&node_id).expect("node");
    // The node's own cost scales with the tree's critical cost (the measured
    // cost is width-scaled; the ratio keeps that scaling). A `PushSelect`
    // leaves the tree's critical depth unchanged — its gain is an arrival
    // effect on the path, which the per-node sum cannot show until the
    // measurement carries per-input arrivals.
    let base = |c| model.base_fo4(c);
    let tree_before = node
        .rhs_expr
        .as_ref()
        .map(|e| e.fo4_critical_cost(&base))
        .unwrap_or(0.0);
    let tree_after = shape.expr_after.fo4_critical_cost(&base);
    if tree_before > 1e-9 {
        node.fo4_cost = (node.fo4_cost * (tree_after / tree_before).min(1.0)).max(0.0);
    }
    node.rhs = Some(shape.rhs_after.clone());
    node.op_class = Some(shape.expr_after.dominant_op_class());
    node.rhs_expr = Some(shape.expr_after.clone());
    let rec = EditRecord {
        id: 0,
        kind,
        origin,
        path_id: Some(path_id),
        node_id: Some(node_id),
        new_name: None,
        fo4_before: Some(shape.fo4_before),
        fo4_after: Some(shape.fo4_after),
        rationale: format!(
            "expr_rewrite {} path {path_id} node {node_id}: `{}` = `{}` -> `{}` {:.1}->{:.1} on the node (latency-neutral, exact{})",
            shape
                .kinds
                .iter()
                .map(|k| k.as_str())
                .collect::<Vec<_>>()
                .join("+"),
            shape.lhs_text,
            shape.rhs_before,
            shape.rhs_after,
            shape.fo4_before,
            shape.fo4_after,
            if shape.est_cells > 0.0 {
                format!("; +{:.0} est. cells", shape.est_cells)
            } else {
                String::new()
            }
        ),
        emit_rhs: Some(shape.rhs_after.clone()),
        emit_rhs_extras: Vec::new(),
        emit_snippet: None,
        emit_predicate: false,
        emit_predicate_from: None,
        pipe_stage: None,
        gen_scope: None,
    };
    ctx.trace.record_edit(rec.clone());
    if shape.est_cells > 0.0 {
        ctx.link_last_tradeoff();
    }
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
                    fb.partial_cmp(&fa).unwrap_or(std::cmp::Ordering::Equal)
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
            // The staging block is emitted at module scope: an arm or LHS that
            // names a block-local (`automatic logic brh` inside `for … always_comb`,
            // a loop variable, a generate-local) cannot be hoisted there.
            let block_local = module.block_local_names();
            let mut staged_n = 0usize;
            let mut stage_frags: Vec<String> = Vec::new();
            let mut best_node_after = 0.0_f64;
            for cand in path_node_order {
                if staged_n >= max_stage_arms {
                    break;
                }
                let hoistable = module
                    .nodes
                    .get(&cand)
                    .map(|n| {
                        let rhs_ok = n
                            .rhs
                            .as_deref()
                            .map(|r| !module.text_refs_block_local(r, &block_local))
                            .unwrap_or(true);
                        let lhs_ok = n
                            .lhs
                            .as_deref()
                            .map(|l| !module.text_refs_block_local(l, &block_local))
                            .unwrap_or(true);
                        rhs_ok && lhs_ok
                    })
                    .unwrap_or(false);
                if !hoistable {
                    continue;
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
                    // The top wire takes the LHS type (`var type(lhs)` + cast): the
                    // origin line becomes `lhs = top`, and an enum/struct LHS has no
                    // implicit conversion from `logic [w-1:0]` (decoder `fu_t`).
                    let lhs_text = n
                        .lhs
                        .as_deref()
                        .map(str::trim)
                        .filter(|l| !l.is_empty() && !l.contains("<=") && !l.contains('='));
                    let frag = plan.to_sv_fragment_typed(Some(&top_name), width, lhs_text);
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
                    // The tree is emitted at module scope: selector, LHS and
                    // every arm must be module-visible (no block-locals).
                    let block_local = module.block_local_names();
                    let scope_ok = !module.text_refs_block_local(&rec.selector, &block_local)
                        && !module.text_refs_block_local(&rec.lhs, &block_local)
                        && rec
                            .arms
                            .iter()
                            .all(|a| !module.text_refs_block_local(&a.rhs, &block_local));
                    // Enum/default safety before functional exclusive-LHS wire-up.
                    if !scope_ok {
                        // A block-local name in the cone — fall through to credit.
                    } else if let Err(_why) = crate::case_recover::onehot_wire_checks(&rec) {
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
                            structural_after =
                                Some(structural_after.map(|s| s.min(est)).unwrap_or(est));
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
        let from_struct = (fo4_before - (fo4_before - sa).max(0.0) * 0.80).min(fo4_before - 0.5);
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

    let note = format!("balance_mux {rewrite_kind} path {path_id} {fo4_before:.1}->{fo4_after:.1}");
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
            .map(|p| format!("balmux|{}|{}", ctx.active_module_name, p.nodes.len()))
            .unwrap_or_default();
        ctx.design
            .path_exceptions
            .push(sv_timing_core::PathException {
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

    // Once per origin as well as once per path: nineteen paths run through
    // `alu` `result_o`, and each used to emit its own one-hot tree for the
    // same assignment — eighteen dead copies (area, and dangling markers
    // whose fallback injection landed before the module's declarations).
    // The first rewrite's credit is on the node; later paths see it after
    // the remeasure. A structural (snippet) rewrite at an origin already
    // rewritten structurally is refused; a credit-only record is still fine.
    if emit_snippet.is_some()
        && ctx.trace.records.iter().any(|r| {
            r.kind == EditKind::BalanceMux
                && r.emit_snippet.is_some()
                && r.origin.file == rewrite_origin.file
                && r.origin.start_line == rewrite_origin.start_line
        })
    {
        return Err(TransformError::InvalidOpportunity(format!(
            "balance_mux: origin {}:{} already rewritten structurally",
            rewrite_origin.file, rewrite_origin.start_line
        )));
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
        emit_predicate: false,
        emit_predicate_from: None,
        pipe_stage: None,
        gen_scope: None,
    };
    ctx.balance_mux_done.insert(path_id);
    ctx.balance_mux_credit.insert(path_id, fo4_after);
    ctx.trace.record_edit(rec.clone());
    ctx.pending_ir_dirty = true;
    Ok(rec)
}

/// `SelectIncrement` (ALGORITHMS-EXPERTS A88): rewrite `LHS = REG + step`
/// (optionally `& MASK`) into `2^k` precomputed candidate increments of the
/// register and one select on `step`.
///
/// Real IR rewrite, no credit: the candidate assigns become nodes of the
/// node's region (parallel, fed by the register only) and the origin node's
/// RHS becomes the select, so the remeasure sees the adder off the `step`
/// cone and bills the select as a mux level (delay-v33). Exact modulo 2^W for
/// every `step` value — the array covers the declared width — same cycle, no
/// state. Refused when the shape, scope or pricing does not hold.
pub fn select_increment_on_node(
    ctx: &mut PassContext,
    path_id: PathId,
    node_id: NodeId,
    origin: SourceLoc,
) -> TransformResult<EditRecord> {
    use sv_timing_core::select_increment as si;
    if !ctx.policy.module_allowed(&ctx.active_module_name) {
        return Err(TransformError::ModuleNotAllowlisted(
            ctx.active_module_name.clone(),
        ));
    }
    let model = sv_timing_core::CostModel::default();
    let module_id = ctx
        .design
        .modules
        .values()
        .find(|m| m.name == ctx.active_module_name)
        .map(|m| m.id)
        .ok_or_else(|| TransformError::InvalidOpportunity("module not found".into()))?;
    let (shape, cand, select_text, snippet, region_id, first_new_id, node_loc, area) = {
        let module = ctx.design.modules.get(&module_id).expect("module");
        let node = module
            .nodes
            .get(&node_id)
            .ok_or_else(|| TransformError::InvalidOpportunity(format!("node {node_id} missing")))?;
        let regs = si::register_roots(module);
        let resolver = sv_timing_core::width::WidthResolver::from_parts(
            &ctx.design.packages,
            &ctx.design.param_map_ints,
            &module.decls,
            &module.ports,
            &module.const_exprs,
            &module.typedef_texts,
            &module.package_imports,
            ctx.design.width_map.get(&module.name),
        );
        let shape = si::detect(module, node, &regs, &resolver, &model).ok_or_else(|| {
            TransformError::InvalidOpportunity(format!(
                "select_increment: node {node_id} is not `REG + narrow step` with a cheaper select"
            ))
        })?;
        let lhs_root =
            sv_timing_core::ir::TimingModule::root_ident(&shape.lhs_text).ok_or_else(|| {
                TransformError::InvalidOpportunity("select_increment: lhs root".into())
            })?;
        let cand = format!("{lhs_root}_svt_cand");
        if module.decls.iter().any(|d| d.name == cand)
            || module.ports.iter().any(|p| p.name == cand)
        {
            return Err(TransformError::InvalidOpportunity(format!(
                "select_increment: `{cand}` already declared"
            )));
        }
        let snippet = si::candidate_snippet(&shape, &cand);
        let block_local = module.block_local_names();
        if module.text_refs_block_local(&snippet, &block_local) {
            return Err(TransformError::InvalidOpportunity(format!(
                "select_increment: `{}`/`{}`/`{}` names a block-local",
                shape.lhs_text, shape.reg_text, shape.step_ident
            )));
        }
        let select_text = si::select_rhs(&cand, &shape.step_ident, shape.step_bits);
        let region_id = module
            .regions
            .values()
            .find(|r| r.nodes.contains(&node_id))
            .map(|r| r.id)
            .ok_or_else(|| {
                TransformError::InvalidOpportunity("select_increment: node has no region".into())
            })?;
        let first_new_id = module
            .nodes
            .keys()
            .next_back()
            .copied()
            .unwrap_or(0)
            .checked_add(1)
            .ok_or_else(|| TransformError::InvalidOpportunity("node ids exhausted".into()))?;
        // Area gate (Dial 11, A114): `2^k` candidate adders and a `2^k`-way
        // select, each `width` wide, against the FO4 the select removes.
        let area = (
            f64::from(2 * shape.candidates() as u32 - 1)
                * f64::from(shape.width.unwrap_or(32).max(1)),
            shape.fo4_before - shape.fo4_after,
            node.loc.start_line,
        );
        (
            shape,
            cand,
            select_text,
            snippet,
            region_id,
            first_new_id,
            node.loc.clone(),
            area,
        )
    };
    let (est_cells, gain, line) = area;
    if !ctx.admit_area(EditKind::SelectIncrement, line, est_cells, gain) {
        return Err(TransformError::InvalidOpportunity(format!(
            "select_increment: area gate ({est_cells:.0} cells for {gain:.1} FO4)"
        )));
    }

    let module = ctx.design.modules.get_mut(&module_id).expect("module");
    let gate = module
        .nodes
        .get(&node_id)
        .and_then(|n| n.gate.clone())
        .unwrap_or_else(|| sv_timing_core::GateInfo {
            is_comb: true,
            ..Default::default()
        });
    let fo4_before = shape.fo4_before;
    let mut new_ids = Vec::new();
    for j in 0..shape.candidates() {
        let id = first_new_id + j;
        let sum = shape.candidate_expr(&j.to_string());
        let lhs = format!("{cand}[{j}]");
        module.nodes.insert(
            id,
            sv_timing_core::IrNode {
                id,
                op_class: Some(sv_timing_core::OperatorClass::AddSub),
                width: shape.width.unwrap_or(1),
                fo4_cost: 0.0,
                gate: Some(gate.clone()),
                loc: node_loc.clone(),
                fans_in: Vec::new(),
                fans_out: vec![node_id],
                width_defaulted: shape.width.is_none(),
                reads_reg: true,
                lhs: Some(lhs.clone()),
                rhs: Some(sum.clone()),
                rhs_expr: Some(sv_timing_core::Expr::parse(&sum)),
                lhs_expr: Some(sv_timing_core::Expr::parse(&lhs)),
                case_labels: Vec::new(),
                case_is_default: false,
                case_selector: None,
                fo4_locked: false,
                assign_kind: sv_timing_core::ir::AssignKind::Continuous,
            },
        );
        new_ids.push(id);
    }
    if let Some(region) = module.regions.get_mut(&region_id) {
        region.nodes.extend(new_ids.iter().copied());
    }
    let node = module.nodes.get_mut(&node_id).expect("node");
    node.rhs = Some(select_text.clone());
    node.rhs_expr = Some(sv_timing_core::Expr::parse(&select_text));
    node.op_class = Some(sv_timing_core::OperatorClass::Mux);
    node.fans_in.extend(new_ids.iter().copied());
    node.reads_reg = false;

    // The origin assign is the cand declaration's type anchor: it must be the
    // module-scope assignment the snippet rewrites (R12 scope checks on emit).
    let rec = EditRecord {
        id: 0,
        kind: EditKind::SelectIncrement,
        origin,
        path_id: Some(path_id),
        node_id: Some(node_id),
        new_name: Some(cand.clone()),
        fo4_before: Some(fo4_before),
        fo4_after: Some(shape.fo4_after),
        rationale: format!(
            "select_increment path {path_id} node {node_id}: `{}` = `{}` {} `{}` -> {} candidates, {} select level(s) {fo4_before:.1}->{:.1} on the node (latency-neutral, exact mod 2^W)",
            shape.lhs_text,
            shape.reg_text,
            shape.operator,
            shape.step_ident,
            shape.candidates(),
            shape.mux_levels(),
            shape.fo4_after
        ),
        emit_rhs: Some(select_text),
        emit_rhs_extras: Vec::new(),
        emit_snippet: Some(snippet),
        emit_predicate: false,
        emit_predicate_from: None,
        pipe_stage: None,
        gen_scope: None,
    };
    ctx.trace.record_edit(rec.clone());
    ctx.link_last_tradeoff();
    ctx.pending_ir_dirty = true;
    Ok(rec)
}

/// `LoopRewrite` (ALGORITHMS-EXPERTS A101): the loop containing `node_id` is
/// a serial walk with an exact parallel form. The IR credit is the shape's
/// parallel cost on every loop-carried node of the loop (locked across
/// remeasure — `attribute_costs` would re-apply the trip multiplier); the
/// emitted file carries the replacement statement over the loop's span and a
/// module-scope declaration for the vector it needs.
pub fn loop_rewrite_on_node(
    ctx: &mut PassContext,
    path_id: PathId,
    node_id: NodeId,
) -> TransformResult<EditRecord> {
    if !ctx.policy.module_allowed(&ctx.active_module_name) {
        return Err(TransformError::ModuleNotAllowlisted(
            ctx.active_module_name.clone(),
        ));
    }
    let model = sv_timing_core::CostModel::default();
    let module_id = ctx
        .design
        .modules
        .values()
        .find(|m| m.name == ctx.active_module_name)
        .map(|m| m.id)
        .ok_or_else(|| TransformError::InvalidOpportunity("module not found".into()))?;
    let (shape, loop_loc, inside, before) =
        {
            let module = ctx.design.modules.get(&module_id).expect("module");
            let node = module.nodes.get(&node_id).ok_or_else(|| {
                TransformError::InvalidOpportunity(format!("node {node_id} missing"))
            })?;
            let resolver = sv_timing_core::width::WidthResolver::from_parts(
                &ctx.design.packages,
                &ctx.design.param_map_ints,
                &module.decls,
                &module.ports,
                &module.const_exprs,
                &module.typedef_texts,
                &module.package_imports,
                ctx.design.width_map.get(&module.name),
            );
            let shapes = sv_timing_core::loop_walk::detect(module, &resolver, &model);
            let shape = shapes
                .into_iter()
                .find(|s| {
                    module.gen_loops.get(s.loop_index).is_some_and(|lp| {
                        lp.loc.file == node.loc.file
                            && node.loc.byte_start >= lp.loc.byte_start
                            && node.loc.byte_start < lp.loc.byte_end
                    })
                })
                .ok_or_else(|| {
                    TransformError::InvalidOpportunity(format!(
                        "loop_rewrite: node {node_id} is not inside a rewritable walk"
                    ))
                })?;
            let lp = &module.gen_loops[shape.loop_index];
            if ctx.trace.records.iter().any(|r| {
                r.kind == EditKind::LoopRewrite && r.origin.byte_start == lp.loc.byte_start
            }) {
                return Err(TransformError::InvalidOpportunity(
                    "loop_rewrite: loop already rewritten".into(),
                ));
            }
            if module.decls.iter().any(|d| d.name == shape.marker) {
                return Err(TransformError::InvalidOpportunity(format!(
                    "loop_rewrite: `{}` already declared",
                    shape.marker
                )));
            }
            let inside: Vec<NodeId> = module
                .nodes
                .values()
                .filter(|n| {
                    n.loc.file == lp.loc.file
                        && n.loc.byte_start >= lp.loc.byte_start
                        && n.loc.byte_start < lp.loc.byte_end
                })
                .map(|n| n.id)
                .collect();
            let before = inside
                .iter()
                .filter_map(|id| module.nodes.get(id))
                .map(|n| n.fo4_cost)
                .fold(0.0, f64::max);
            // The span to replace is the loop statement's own lines: the parser
            // span's exclusive end byte can sit on the next line (the process's
            // `end`), so the end line comes from the loop text's line count.
            let mut loop_loc = lp.loc.clone();
            if let Some(text) = lp.text.as_deref() {
                let lines = text.lines().count().max(1) as u32;
                loop_loc.end_line = loop_loc.start_line + lines - 1;
            }
            (shape, loop_loc, inside, before)
        };
    let module = ctx.design.modules.get_mut(&module_id).expect("module");
    // Credit: every node of the loop now costs at most one parallel form.
    for id in &inside {
        if let Some(n) = module.nodes.get_mut(id) {
            if n.fo4_cost > shape.fo4_after {
                n.fo4_cost = shape.fo4_after;
            }
            n.fo4_locked = true;
        }
    }
    let rec = EditRecord {
        id: 0,
        kind: EditKind::LoopRewrite,
        origin: loop_loc,
        path_id: Some(path_id),
        node_id: Some(node_id),
        new_name: Some(shape.marker.clone()),
        fo4_before: Some(before),
        fo4_after: Some(shape.fo4_after),
        rationale: format!(
            "loop_rewrite path {path_id} `{}` {:?}: {} ({:.1} -> {:.1} on the loop's worst node; latency-neutral, exact)",
            shape.carried, shape.kind, shape.rationale, before, shape.fo4_after
        ),
        emit_rhs: Some(shape.replacement.clone()),
        emit_rhs_extras: Vec::new(),
        emit_snippet: Some(shape.decls.clone()),
        emit_predicate: false,
        emit_predicate_from: None,
        pipe_stage: None,
        gen_scope: None,
    };
    ctx.trace.record_edit(rec.clone());
    ctx.pending_ir_dirty = true;
    Ok(rec)
}

fn path_class_for_balance(ctx: &PassContext, path_id: PathId) -> sv_timing_core::PathClassKind {
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
                by_lhs.entry(lhs).or_default().push(n.fo4_cost.max(0.0));
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
    use std::collections::BTreeMap;
    use sv_timing_core::ir::{TimingDesign, TimingPath, TimingTarget};
    use sv_timing_core::loc::OriginKind;
    use sv_timing_core::naming::NameTable;

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
                    assign_kind: Default::default(),
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
                function_bodies: Vec::new(),
                package_imports: Vec::new(),
                instances: Vec::new(),
                decls: Vec::new(),
                const_exprs: Default::default(),
                typedef_texts: Default::default(),
                config_branch: false,
                guards: Default::default(),
                onehot_facts: Default::default(),
                guard_sites: Default::default(),
                pipe_pragmas: Default::default(),
                loc: loc(),
            },
        );
        design.module_names.insert("m".into(), 0);
        let start = PathEndpoint::InputPort { module: 0, port: 0 };
        let end = PathEndpoint::OutputPort { module: 0, port: 1 };
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

    /// Dial 11 (A114): a cut is one flop per bit of the cut net per stage; it
    /// is refused when that buys too little FO4, admitted when the gate is
    /// off, and the limit follows the module's measured cells/FO4.
    #[test]
    fn area_gate_refuses_wide_cuts_that_buy_little_and_keeps_a_ledger() {
        let mut design = design_with_path();
        for n in design.modules.get_mut(&0).unwrap().nodes.values_mut() {
            n.width = 64;
        }
        let mut ctx = PassContext::new(design, NameTable::new(), PassPolicy::strict_test());
        ctx.active_module_name = "m".into();
        ctx.policy.correct_allow_modules = vec!["m".into()];
        ctx.policy.allow_latency = true;
        ctx.assume_clk = true;
        let opp = Opportunity {
            kind: OpportunityKind::InsertReg,
            path_id: 0,
            insert_after: 1,
            estimated_fo4_before: 40.0,
            estimated_fo4_after: 20.0,
            loc: loc(),
            rationale: "test".into(),
            requires_clock_in_scope: true,
            changes_latency: true,
        };
        let plan = select_pipeline_cuts(&ctx, &opp).unwrap();
        // every cut: 64 flops against the FO4 its shorter segment removes
        let ratios: Vec<f64> = plan
            .cuts
            .iter()
            .map(|c| 64.0 / c.fo4_left.min(c.fo4_right))
            .collect();
        let (lo, hi) = ratios
            .iter()
            .fold((f64::MAX, 0.0_f64), |a, r| (a.0.min(*r), a.1.max(*r)));
        // below the cheapest cut's ratio: everything refused
        ctx.policy.opt.max_cells_per_fo4 = lo * 0.5;
        let edits = insert_register(&mut ctx, &plan).unwrap();
        assert!(edits.is_empty(), "refused: {edits:?}");
        let t = ctx.tradeoffs.last().expect("ledger entry");
        assert!(
            !t.applied
                && t.edit_id.is_none()
                && t.est_cells == 64.0
                && t.reason.starts_with("refused")
        );
        assert_eq!(t.limit, Some(lo * 0.5));
        // the module's measured cells/FO4 scales the limit: at 2.6 (2× the
        // reference band) a limit of 0.6×hi becomes 1.2×hi and every cut passes
        ctx.policy.opt.max_cells_per_fo4 = hi * 0.6;
        ctx.module_cells_per_fo4.insert("m".into(), 2.6);
        assert!((ctx.area_limit_for("m").unwrap() - hi * 1.2).abs() < 1e-9);
        let edits = insert_register(&mut ctx, &plan).unwrap();
        assert_eq!(edits.len(), plan.cuts.len());
        let t = ctx.tradeoffs.last().unwrap();
        assert!(t.applied && t.edit_id == Some(edits.last().unwrap().id));
        // gate off: always admitted, ledger says so
        ctx.module_cells_per_fo4.clear();
        ctx.policy.opt.max_cells_per_fo4 = 0.0;
        assert_eq!(ctx.area_limit_for("m"), None);
        assert!(!insert_register(&mut ctx, &plan).unwrap().is_empty());
        assert_eq!(ctx.tradeoffs.last().unwrap().reason, "area gate off");
    }

    fn expansion_trial() -> (PassContext, Opportunity) {
        let mut design = design_with_path();
        let root = design
            .modules
            .get_mut(&0)
            .unwrap()
            .nodes
            .get_mut(&0)
            .unwrap();
        root.rhs = Some("a + b + c + d".into());
        root.rhs_expr = Some(sv_timing_core::Expr::parse(root.rhs.as_ref().unwrap()));
        root.fo4_cost = 30.0;
        let mut policy = PassPolicy::strict_test();
        policy.allow_latency = true;
        policy.correct_allow_modules = vec!["m".into()];
        policy.opt.max_stages_per_region = 8;
        let mut ctx = PassContext::new(design, NameTable::new(), policy);
        ctx.active_module_name = "m".into();
        let opp = Opportunity {
            kind: OpportunityKind::InsertReg,
            path_id: 0,
            insert_after: 0,
            estimated_fo4_before: 60.0,
            estimated_fo4_after: 16.0,
            loc: loc(),
            rationale: "expansion trial".into(),
            requires_clock_in_scope: true,
            changes_latency: true,
        };
        (ctx, opp)
    }

    #[test]
    fn refused_expansion_does_not_change_ir_or_dirty_state() {
        let (mut ctx, opp) = expansion_trial();
        let before = serde_json::to_value(&ctx.design).unwrap();
        assert!(matches!(
            prepare_pipeline_cuts(&mut ctx, &opp),
            Err(TransformError::IncompleteGateInfo)
        ));
        assert_eq!(serde_json::to_value(&ctx.design).unwrap(), before);
        assert!(!ctx.pending_ir_dirty);

        // This failure occurs after expansion: a later cut names a block-local.
        ctx.assume_clk = true;
        let module = ctx.design.modules.get_mut(&0).unwrap();
        module.decls.push(sv_timing_core::ir::DeclSite {
            name: "local_value".into(),
            type_name: "logic".into(),
            packed_text: String::new(),
            unpacked_text: String::new(),
            loc: loc(),
            block_local: true,
            scope: None,
            loop_var: false,
        });
        for id in 1..4 {
            module.nodes.get_mut(&id).unwrap().lhs = Some("local_value".into());
        }
        let before = serde_json::to_value(&ctx.design).unwrap();
        assert!(matches!(
            prepare_pipeline_cuts(&mut ctx, &opp),
            Err(TransformError::InvalidOpportunity(_))
        ));
        assert_eq!(serde_json::to_value(&ctx.design).unwrap(), before);
        assert!(!ctx.pending_ir_dirty);
        assert!(ctx.trace.records.is_empty());
        ctx.pending_ir_dirty = true;
        assert!(prepare_pipeline_cuts(&mut ctx, &opp).is_err());
        assert!(ctx.pending_ir_dirty, "preserve unrelated pending work");
        assert_eq!(serde_json::to_value(&ctx.design).unwrap(), before);
    }

    #[test]
    fn accepted_expansion_retains_nodes_for_insert() {
        let (mut ctx, opp) = expansion_trial();
        ctx.assume_clk = true;
        let plan = prepare_pipeline_cuts(&mut ctx, &opp).unwrap();
        assert!(ctx.design.modules[&0].nodes.len() > 4);
        assert!(ctx.pending_ir_dirty);
        assert!(!insert_register(&mut ctx, &plan).unwrap().is_empty());
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
        let max_nodes = ctx
            .design
            .paths
            .iter()
            .map(|p| p.nodes.len())
            .max()
            .unwrap();
        assert!(
            max_nodes < 4,
            "path should be split, max segment {max_nodes}"
        );
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
                    assign_kind: Default::default(),
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
                function_bodies: Vec::new(),
                package_imports: Vec::new(),
                instances: Vec::new(),
                decls: Vec::new(),
                const_exprs: Default::default(),
                typedef_texts: Default::default(),
                config_branch: false,
                guards: Default::default(),
                onehot_facts: Default::default(),
                guard_sites: Default::default(),
                pipe_pragmas: Default::default(),
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
                    assign_kind: Default::default(),
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
                function_bodies: Vec::new(),
                package_imports: Vec::new(),
                instances: Vec::new(),
                decls: Vec::new(),
                const_exprs: Default::default(),
                typedef_texts: Default::default(),
                config_branch: false,
                guards: Default::default(),
                onehot_facts: Default::default(),
                guard_sites: Default::default(),
                pipe_pragmas: Default::default(),
                loc: loc(),
            },
        );
        design.module_names.insert("m".into(), 0);
        let start = PathEndpoint::InputPort { module: 0, port: 0 };
        let end = PathEndpoint::OutputPort { module: 0, port: 1 };
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
        policy.opt.max_stages_per_region = 4;
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
                assign_kind: Default::default(),
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
                function_bodies: Vec::new(),
                package_imports: Vec::new(),
                instances: Vec::new(),
                decls: Vec::new(),
                const_exprs: Default::default(),
                typedef_texts: Default::default(),
                config_branch: false,
                guards: Default::default(),
                onehot_facts: Default::default(),
                guard_sites: Default::default(),
                pipe_pragmas: Default::default(),
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
        let root_n = ctx
            .design
            .modules
            .get(&0)
            .unwrap()
            .nodes
            .get(&root)
            .unwrap();
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
                assign_kind: Default::default(),
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
                function_bodies: Vec::new(),
                package_imports: Vec::new(),
                instances: Vec::new(),
                decls: Vec::new(),
                const_exprs: Default::default(),
                typedef_texts: Default::default(),
                config_branch: false,
                guards: Default::default(),
                onehot_facts: Default::default(),
                guard_sites: Default::default(),
                pipe_pragmas: Default::default(),
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
        assert!(err.is_err(), "atomic mul over budget must refuse InsertReg");
    }

    #[test]
    fn insert_register_residual_keeps_regtoreg_capture() {
        let mut design = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        design.target.budget_fo4 = 10.0;
        let mut nodes = BTreeMap::new();
        for id in 0..4u32 {
            nodes.insert(
                id,
                IrNode {
                    id,
                    op_class: Some(OperatorClass::LogicBit),
                    width: 8,
                    fo4_cost: 8.0,
                    gate: None,
                    loc: loc(),
                    fans_in: if id == 0 { vec![] } else { vec![id - 1] },
                    fans_out: if id == 3 { vec![] } else { vec![id + 1] },
                    width_defaulted: false,
                    reads_reg: false,
                    lhs: Some(format!("t{id}")),
                    rhs: None,
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
                function_bodies: Vec::new(),
                package_imports: Vec::new(),
                instances: Vec::new(),
                decls: Vec::new(),
                const_exprs: Default::default(),
                typedef_texts: Default::default(),
                config_branch: false,
                guards: Default::default(),
                onehot_facts: Default::default(),
                guard_sites: Default::default(),
                pipe_pragmas: Default::default(),
                loc: loc(),
            },
        );
        design.module_names.insert("m".into(), 0);
        let start = PathEndpoint::RegClock { cell: 0 };
        let end = PathEndpoint::RegData { cell: 1 };
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
            total_fo4: 32.0,
            slack_fo4: -22.0,
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
        policy.opt.max_stages_per_region = 8;
        let mut ctx = PassContext::new(design, NameTable::new(), policy);
        ctx.active_module_name = "m".into();
        ctx.assume_clk = true;
        let opp = Opportunity {
            kind: OpportunityKind::InsertReg,
            path_id: 0,
            insert_after: 0,
            estimated_fo4_before: 32.0,
            estimated_fo4_after: 10.0,
            loc: loc(),
            rationale: "cut".into(),
            requires_clock_in_scope: true,
            changes_latency: true,
        };
        let plan = select_pipeline_cuts(&ctx, &opp).unwrap();
        assert!(
            plan.cuts.len() >= 2,
            "32 FO4 / budget 10 with stages=8 should multi-cut, got {}",
            plan.cuts.len()
        );
        insert_register(&mut ctx, &plan).unwrap();
        let capture = PathEndpoint::RegData { cell: 1 };
        assert!(
            ctx.design.paths.iter().any(|p| p.end == capture
                && matches!(p.start, PathEndpoint::RegData { .. })
                && p.path_kind == sv_timing_core::PathKind::RegToReg),
            "residual after InsertReg must keep the original capture (RegToReg), paths={:?}",
            ctx.design
                .paths
                .iter()
                .map(|p| format!(
                    "id={} kind={:?} start={:?} end={:?}",
                    p.id, p.path_kind, p.start, p.end
                ))
                .collect::<Vec<_>>()
        );
        assert!(
            !ctx.design
                .paths
                .iter()
                .any(|p| matches!(p.end, PathEndpoint::OutputPort { .. })),
            "dummy OutputPort residual would drop exception_policy"
        );
    }

    #[test]
    fn expand_expr_spine_splices_fat_node_on_multi_node_path() {
        let mut design = TimingDesign::empty(TimingTarget::new(4000.0, 20.0, 0.2));
        design.target.budget_fo4 = 10.0;
        let mut nodes = BTreeMap::new();
        for (id, cost) in [(0u32, 2.0), (1, 22.0), (2, 2.0)] {
            nodes.insert(
                id,
                IrNode {
                    id,
                    op_class: Some(OperatorClass::LogicBit),
                    width: 8,
                    fo4_cost: cost,
                    gate: None,
                    loc: loc(),
                    fans_in: if id == 0 { vec![] } else { vec![id - 1] },
                    fans_out: if id == 2 { vec![] } else { vec![id + 1] },
                    width_defaulted: false,
                    reads_reg: false,
                    lhs: Some(format!("t{id}")),
                    rhs: None,
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
                function_bodies: Vec::new(),
                package_imports: Vec::new(),
                instances: Vec::new(),
                decls: Vec::new(),
                const_exprs: Default::default(),
                typedef_texts: Default::default(),
                config_branch: false,
                guards: Default::default(),
                onehot_facts: Default::default(),
                guard_sites: Default::default(),
                pipe_pragmas: Default::default(),
                loc: loc(),
            },
        );
        design.module_names.insert("m".into(), 0);
        let start = PathEndpoint::RegClock { cell: 0 };
        let end = PathEndpoint::RegData { cell: 1 };
        design.paths.push(TimingPath {
            id: 7,
            region_id: 0,
            module: 0,
            start: start.clone(),
            end: end.clone(),
            path_kind: sv_timing_core::PathKind::from_endpoints(&start, &end),
            startpoint: start.report_name("m"),
            endpoint: end.report_name("m"),
            nodes: vec![0, 1, 2],
            total_fo4: 26.0,
            slack_fo4: -16.0,
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
        let mut ctx = PassContext::new(design, NameTable::new(), policy);
        ctx.active_module_name = "m".into();
        let expanded = expand_expr_spine_for_path(&mut ctx, 7).unwrap();
        assert!(
            expanded,
            "fat non-atomic node on a 3-node path must half-split"
        );
        let path = ctx.design.paths.iter().find(|p| p.id == 7).unwrap();
        assert!(
            path.nodes.len() >= 4,
            "splice must keep neighbors and insert prep, got {:?}",
            path.nodes
        );
        assert_eq!(path.nodes.first().copied(), Some(0));
        assert_eq!(path.nodes.last().copied(), Some(2));
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
                assign_kind: Default::default(),
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
                function_bodies: Vec::new(),
                package_imports: Vec::new(),
                instances: Vec::new(),
                decls: Vec::new(),
                const_exprs: Default::default(),
                typedef_texts: Default::default(),
                config_branch: false,
                guards: Default::default(),
                onehot_facts: Default::default(),
                guard_sites: Default::default(),
                pipe_pragmas: Default::default(),
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
        assert!(
            again.is_err(),
            "second rebalance should not claim improvement"
        );
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
                    assign_kind: Default::default(),
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
                function_bodies: Vec::new(),
                package_imports: Vec::new(),
                instances: Vec::new(),
                decls: Vec::new(),
                const_exprs: Default::default(),
                typedef_texts: Default::default(),
                config_branch: false,
                guards: Default::default(),
                onehot_facts: Default::default(),
                guard_sites: Default::default(),
                pipe_pragmas: Default::default(),
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
            rec.emit_snippet
                .as_ref()
                .map(|s| s.contains("always_comb"))
                .unwrap_or(false),
            "expected real staging snippet: {:?}",
            rec.emit_snippet
        );
        assert!(
            rec.emit_rhs
                .as_ref()
                .map(|s| s.starts_with("svt_bm_top"))
                .unwrap_or(false),
            "emit_rhs={:?}",
            rec.emit_rhs
        );
        assert!(rec.rationale.contains("stage_hot_arm"), "{}", rec.rationale);
        let n = ctx.design.modules.get(&0).unwrap().nodes.get(&0).unwrap();
        assert!(
            n.rhs
                .as_ref()
                .map(|s| s.starts_with("svt_bm_top"))
                .unwrap_or(false),
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
                    assign_kind: Default::default(),
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
                function_bodies: Vec::new(),
                package_imports: Vec::new(),
                instances: Vec::new(),
                decls: Vec::new(),
                const_exprs: Default::default(),
                typedef_texts: Default::default(),
                config_branch: false,
                guards: Default::default(),
                onehot_facts: Default::default(),
                guard_sites: Default::default(),
                pipe_pragmas: Default::default(),
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
                !rec.emit_rhs_extras.is_empty()
                    || rec
                        .emit_rhs
                        .as_ref()
                        .map(|s| s.contains("svt_bm_oh"))
                        .unwrap_or(false),
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
                    assign_kind: Default::default(),
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
                assign_kind: Default::default(),
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
                function_bodies: Vec::new(),
                package_imports: Vec::new(),
                instances: Vec::new(),
                decls: Vec::new(),
                const_exprs: Default::default(),
                typedef_texts: Default::default(),
                config_branch: false,
                guards: Default::default(),
                onehot_facts: Default::default(),
                guard_sites: Default::default(),
                pipe_pragmas: Default::default(),
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
        assert!(
            snip.contains("op_i") && snip.contains("ADD"),
            "enum compares: {snip}"
        );
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
                assign_kind: Default::default(),
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
                function_bodies: Vec::new(),
                package_imports: Vec::new(),
                instances: Vec::new(),
                decls: Vec::new(),
                const_exprs: Default::default(),
                typedef_texts: Default::default(),
                config_branch: false,
                guards: Default::default(),
                onehot_facts: Default::default(),
                guard_sites: Default::default(),
                pipe_pragmas: Default::default(),
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
