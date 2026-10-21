// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Measure / rank paths — “timing valgrind” style ordering (worst first).

//! Structural cost attribution and ranking.
//! See `architecture/AUTO-CORRECT-CORE-API.md` §3.2.

use std::collections::{BTreeMap, BTreeSet};

use crate::expr::{ConstSeed, Expr};
use crate::ir::{
    CombRegion, IrNode, LineCost, ModuleId, NodeId, OperatorClass, Opportunity, OpportunityKind,
    PathEndpoint, PathKind, RegionKind, RegionReport, TimingDesign, TimingModule, TimingPath,
    TimingTarget,
};
use crate::loc::SourceLoc;
use crate::ref_order::ident_base;

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
    /// delay-v43 load term: FO4 per unit load beyond
    /// [`Self::load_reference_fanout`] on an unbuffered driver (logical
    /// effort `g/5` for an average mapped gate, g ≈ 1.75). 0 disables it.
    pub load_per_fanout: f64,
    /// Fanout the operator costs already assume (the FO4 definition).
    pub load_reference_fanout: f64,
    /// Largest fanout the module board times unbuffered; above it the board
    /// drops the driver and a repaired netlist buffers it (log4 stages).
    pub load_fanout_cap: f64,
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
            load_per_fanout: 0.35,
            load_reference_fanout: 4.0,
            load_fanout_cap: 64.0,
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

    /// Reference-width cost scaled to `width` (`crate::width::width_factor`),
    /// floored at `logic_bit`. `None` width = reference width (unchanged).
    pub fn scaled_fo4(&self, class: OperatorClass, width: Option<u32>) -> f64 {
        let base = self.base_fo4(class);
        let scaled = base * crate::width::width_factor(class, width);
        if width.is_some() {
            scaled.max(self.logic_bit)
        } else {
            base
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
    // Compile representation obligations into the initial IR before any
    // timing/path/opportunity pass consumes the contracts. Rebuild derived
    // facts on re-attribution, including designs rehydrated from module cache.
    crate::pipeline_preprocess::prepare_design(design);
    design.versions.cost_model = model.id.clone();
    // Width inference reads packages / param-map while nodes are mutated.
    let packages = design.packages.clone();
    let param_ints = design.param_map_ints.clone();
    let width_map = design.width_map.clone();
    let seeds: BTreeMap<crate::ir::ModuleId, ConstSeed> = design
        .modules
        .iter()
        .map(|(id, m)| {
            (
                *id,
                ConstSeed::from_names(design.elaboration_const_names(m)),
            )
        })
        .collect();
    for module in design.modules.values_mut() {
        let mut base_seed = seeds
            .get(&module.id)
            .cloned()
            .unwrap_or_else(ConstSeed::heuristic);
        crate::ref_order::extend_seed_auto_const(module, &mut base_seed);
        let gen_spans: Vec<(u32, u32, String)> = module
            .gen_loops
            .iter()
            .filter(|g| {
                g.loc.origin == crate::loc::OriginKind::UserFile
                    && g.loc.file == module.file
                    && g.loc.byte_end > g.loc.byte_start
            })
            .map(|g| (g.loc.byte_start, g.loc.byte_end, g.genvar.clone()))
            .collect();
        let widths = crate::width::WidthResolver::from_parts(
            &packages,
            &param_ints,
            &module.decls,
            &module.ports,
            &module.const_exprs,
            &module.typedef_texts,
            &module.package_imports,
            width_map.get(&module.name),
        );
        // delay-v35: a procedural `for` whose body assigns a variable it also
        // reads (`cid = cid + 1`, `found |= hit[i]`, `rank++`) unrolls into a
        // chain of trip-count copies; one body copy is what the node measured.
        let carried = loop_carried_multipliers(module, &widths);
        // delay-v36: a find-first scan's chain lives in its `if` guard
        // (`v[i] && pick == 0`), which the lowerer does not bill; the picked
        // constant costs 0. Give the scan's carried nodes a per-iteration floor
        // of a compare and a gate so the chain is on the board (A101).
        let scan_floor = find_first_floors(module, &widths, &model);
        // A procedural loop whose bound evaluates to zero trips (`for (p = 2;
        // p < NrIssuePorts; …)` at two ports) is dead: its nodes are no
        // logic at all (delay-v37).
        let dead = dead_loop_nodes(module, &widths);
        // delay-v38: a user function's body costs what its statements cost
        // (serial, loops by trip count), charged at the call site instead of
        // the one gate a `Call` was.
        let fn_costs = function_body_costs(module, &packages, &widths, &model);
        // delay-v37: a guarded assignment is a mux on its guards — the
        // compare in `if (sel == 3'd5) y = a` and the one select level are
        // on y's path, and a dynamically indexed LHS decodes its index.
        // Only guards that read a signal: a genvar index or a parameter `if`
        // is elaboration-time.
        let guards_by_node: BTreeMap<NodeId, Vec<String>> = module
            .guards
            .iter()
            .map(|(id, gs)| {
                (
                    *id,
                    gs.iter()
                        .filter(|g| widths.guard_is_live(g.strip_prefix('^').unwrap_or(g)))
                        .cloned()
                        .collect::<Vec<_>>(),
                )
            })
            .filter(|(_, gs)| !gs.is_empty())
            .collect();
        // A guard that evaluates to a constant zero (`if (CVA6Cfg.NrHarts > 1)`
        // at one hart) is elaboration-time dead code: synthesis removes the
        // body, and so does the board (delay-v38).
        let dead_guarded: BTreeSet<NodeId> = module
            .guards
            .iter()
            .filter(|(_, gs)| {
                gs.iter()
                    .any(|g| widths.eval_text(g.strip_prefix('^').unwrap_or(g)) == Some(0))
            })
            .map(|(id, _)| *id)
            .collect();
        for node in module.nodes.values_mut() {
            if dead.contains(&node.id) || dead_guarded.contains(&node.id) {
                node.fo4_cost = 0.0;
                continue;
            }
            // Spine expand / half-split lock residual segment FO4 across remeasure.
            if node.fo4_locked {
                continue;
            }
            // Width-scaled table (OPTIMIZATION-LEVELS §1.1(2)): arithmetic at
            // max(LHS, operands), compares at their operands, unknown = ref.
            let nw = widths.node_widths(node.lhs_expr.as_ref(), node.rhs_expr.as_ref());
            if let Some(w) = nw.arith {
                node.width = w;
                node.width_defaulted = false;
            } else {
                node.width = 1;
                node.width_defaulted = true;
            }
            let base = |c: OperatorClass| model.scaled_fo4(c, nw.for_class(c));
            let mut seed = base_seed.clone();
            let b = node.loc.byte_start;
            for (s, e, gv) in &gen_spans {
                if node.loc.origin == crate::loc::OriginKind::UserFile
                    && node.loc.file == module.file
                    && b >= *s
                    && b < *e
                {
                    seed.add(gv.clone());
                }
            }
            // Guard cost (delay-v37): the deepest predicate / index expression,
            // width-scaled on its own operands, plus one select level and a
            // log2 level per additional guard.
            // A guard whose identifiers are all in the constant seed (the
            // genvars in scope here) is elaboration-time: `row[k]` under
            // `for (genvar k …)` is one wire, not a decoder.
            // Inner guards (inside the node's loop, or no loop) scale with the
            // trip count like the body; outer guards (`^`, the `if` wraps the
            // loop) are one select added after it.
            let (guard_cost, outer_guard_cost): (Option<f64>, Option<f64>) = {
                let live: Vec<&String> = guards_by_node
                    .get(&node.id)
                    .map(|gs| {
                        gs.iter()
                            .filter(|g| {
                                let ex = Expr::parse(g.strip_prefix('^').unwrap_or(g));
                                let mut live = false;
                                ex.walk_idents(&mut |s| {
                                    let b = s.split(['[', '.']).next().unwrap_or(s);
                                    if !b.is_empty() && !seed.names.contains(b) {
                                        live = true;
                                    }
                                });
                                live
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                let cost_of = |gs: &[&String]| -> Option<f64> {
                    if gs.is_empty() {
                        return None;
                    }
                    let mut worst = 0.0_f64;
                    for g in gs {
                        let ex = Expr::parse(g.strip_prefix('^').unwrap_or(g));
                        if !ex.is_opaque() {
                            let gw = widths.node_widths(None, Some(&ex));
                            let gbase = |c: OperatorClass| model.scaled_fo4(c, gw.for_class(c));
                            worst = worst.max(ex.fo4_critical_cost_latticed(&gbase, &seed));
                        }
                    }
                    let levels = (gs.len() as f64).log2().ceil().max(0.0);
                    Some(worst + model.logic_bit * levels)
                };
                let inner: Vec<&String> = live
                    .iter()
                    .copied()
                    .filter(|g| !g.starts_with('^'))
                    .collect();
                let outer: Vec<&String> = live
                    .iter()
                    .copied()
                    .filter(|g| g.starts_with('^'))
                    .collect();
                (cost_of(&inner), cost_of(&outer))
            };
            if let Some(ref ex) = node.rhs_expr {
                // A parsed tree is authoritative, including 0 FO4 (P1 lattice /
                // LRM-constant part-selects). Falling back when `c == 0` re-billed
                // `v[HYP_EXT*2:0]` as Mul from a string `*` heuristic — the residual
                // MMU `atomic_over_budget` 56 FO4 nodes. Opaque (parse failed)
                // still falls through to `op_class`.
                if !ex.is_opaque() {
                    node.fo4_cost = ex.fo4_critical_cost_latticed(&base, &seed);
                    node.op_class = Some(ex.dominant_op_class_latticed(&seed));
                    // delay-v38: a runtime index selects among 2^k entries —
                    // ceil(k/2) 4:1 levels, not one. The expression bill
                    // charged one `mux` per index; add the deeper levels of the
                    // widest index once (critical-path approximation).
                    node.fo4_cost += extra_select_levels(ex, &widths, &seed) * model.mux;
                    node.fo4_cost += call_body_extra(ex, &fn_costs, &model);
                    if let Some(gc) = guard_cost {
                        node.fo4_cost =
                            node.fo4_cost.max(gc) + guard_level(&carried, node.id, &model);
                    }
                    if let Some(floor) = scan_floor.get(&node.id) {
                        node.fo4_cost = node.fo4_cost.max(*floor);
                    }
                    if let Some(bill) = carried.get(&node.id) {
                        node.fo4_cost = carry_cost(node.fo4_cost, bill, &model);
                    }
                    if let Some(oc) = outer_guard_cost {
                        node.fo4_cost = node.fo4_cost.max(oc) + model.mux;
                    }
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
                    node.fo4_cost = model.scaled_fo4(c, nw.for_class(c));
                }
            }
            if let Some(gc) = guard_cost {
                node.fo4_cost = node.fo4_cost.max(gc) + guard_level(&carried, node.id, &model);
            }
            if let Some(floor) = scan_floor.get(&node.id) {
                node.fo4_cost = node.fo4_cost.max(*floor);
            }
            if let Some(bill) = carried.get(&node.id) {
                node.fo4_cost = carry_cost(node.fo4_cost, bill, &model);
            }
            if let Some(oc) = outer_guard_cost {
                node.fo4_cost = node.fo4_cost.max(oc) + model.mux;
            }
        }
        // delay-v43: unbuffered output / select-broadcast load (crate::load).
        // Locked nodes keep their cost across remeasure, so they neither pay
        // nor load (adding to them would accumulate).
        let skip: BTreeSet<NodeId> = module
            .nodes
            .values()
            .filter(|n| n.fo4_locked || dead.contains(&n.id) || dead_guarded.contains(&n.id))
            .map(|n| n.id)
            .collect();
        let loads = crate::load::node_loads(module, &widths, model, &skip);
        for (id, extra) in loads.extra {
            if let Some(n) = module.nodes.get_mut(&id) {
                n.fo4_cost += extra;
            }
        }
        module.launch_fo4 = loads.launch;
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
            // Path nodes are ordered along one timing path → sum of node
            // critical FO4 (plus a late register launch, delay-v43).
            path.total_fo4 = chain_fo4(module, &path.nodes);
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
    crate::pass_strategy::tag_handshake_locks(design);
    crate::parallel_timing::fill_design_parallel_timing(design);
    crate::cleanliness::fill_design_cleanliness(design);
    refresh_primary_locs(design);
    design.pass_plan = crate::pass_strategy::plan_from_design(design);
}

/// FO4 of a node chain: the latency sum, or later when a register output a
/// node reads arrives after everything before it (delay-v43 launch load,
/// [`TimingModule::launch_fo4`]): `max_i(launch_i + Σ_{j≥i} cost_j)`.
pub fn chain_fo4(module: &TimingModule, nodes: &[NodeId]) -> f64 {
    let mut suffix = 0.0_f64;
    let mut best = 0.0_f64;
    for id in nodes.iter().rev() {
        suffix += module
            .nodes
            .get(id)
            .map(|n| n.fo4_cost.max(0.0))
            .unwrap_or(0.0);
        let launch = module.launch_fo4.get(id).copied().unwrap_or(0.0);
        best = best.max(suffix + launch);
    }
    best.max(suffix)
}

/// Point `primary_loc` at the highest-FO4 node on each path.
///
/// Lowering used to keep the **last** statement in the region, so soak traces
/// blamed `default: state_d = ST_IDLE` for a 56 FO4 MMA multiply and
/// `early_out_valid_o` for the fpnew FMA product.
pub fn refresh_primary_locs(design: &mut TimingDesign) {
    for path in &mut design.paths {
        let Some(module) = design.modules.get(&path.module) else {
            continue;
        };
        let mut best_cost = f64::NEG_INFINITY;
        let mut best_loc: Option<crate::loc::SourceLoc> = None;
        for id in &path.nodes {
            let Some(n) = module.nodes.get(id) else {
                continue;
            };
            let c = n.fo4_cost;
            let atomic = matches!(
                n.op_class,
                Some(OperatorClass::Mul) | Some(OperatorClass::DivRem)
            );
            let take = c > best_cost + 1e-9 || ((c - best_cost).abs() < 1e-9 && atomic);
            if take {
                best_cost = c;
                best_loc = Some(n.loc.clone());
            }
        }
        if let Some(loc) = best_loc {
            path.primary_loc = loc;
        }
    }
}

/// PASS-STRATEGY P5 / P14 M1: compose combinational assign chains into
/// launch→capture paths. Each continuous-assign / always_comb region is still
/// a fragment (`intoout`); this adds the flop-to-flop (or in→reg / reg→out)
/// cone that actually has to fit the period.
pub fn compose_reg_to_reg_paths(design: &mut TimingDesign) {
    let mids: Vec<ModuleId> = design.modules.keys().copied().collect();
    for mid in mids {
        compose_module_paths(design, mid);
    }
}

fn compose_module_paths(design: &mut TimingDesign, mid: ModuleId) {
    let Some(module) = design.modules.get(&mid) else {
        return;
    };
    let bindings = crate::ref_order::BindingIndex::new(module);
    let mut seq_lhs: BTreeSet<String> = BTreeSet::new();
    let mut seq_reads: BTreeSet<String> = BTreeSet::new();
    let mut comb_ids: BTreeSet<NodeId> = BTreeSet::new();
    let mut region_of: BTreeMap<NodeId, crate::ir::RegionId> = BTreeMap::new();
    for region in module.regions.values() {
        for &nid in &region.nodes {
            region_of.insert(nid, region.id);
            let Some(n) = module.nodes.get(&nid) else {
                continue;
            };
            match region.kind {
                RegionKind::AlwaysFf => {
                    if n.assign_kind.is_seq_def() {
                        if let Some(lhs) = n.lhs.as_deref() {
                            let b = bindings.key(&ident_base(lhs), &n.loc);
                            if !b.is_empty() {
                                seq_lhs.insert(b);
                            }
                        }
                        for s in node_read_symbols(n) {
                            seq_reads.insert(bindings.key(&s, &n.loc));
                        }
                    } else if n.assign_kind.is_comb_def() {
                        // Blocking temp in always_ff is combo, not a flop.
                        comb_ids.insert(nid);
                    }
                }
                RegionKind::AlwaysComb | RegionKind::ContAssign => {
                    comb_ids.insert(nid);
                }
            }
        }
    }
    if comb_ids.is_empty() {
        return;
    }
    // Every comb def per key with its region and source position.
    let mut comb_defs: BTreeMap<String, Vec<(crate::ir::RegionId, u32, NodeId)>> = BTreeMap::new();
    for &nid in &comb_ids {
        if let Some(n) = module.nodes.get(&nid) {
            if let Some(lhs) = &n.lhs {
                let b = bindings.key(&ident_base(lhs), &n.loc);
                if !b.is_empty() {
                    let region = region_of.get(&nid).copied().unwrap_or(0);
                    comb_defs
                        .entry(b)
                        .or_default()
                        .push((region, n.loc.byte_start, nid));
                }
            }
        }
    }
    let procedural: BTreeSet<crate::ir::RegionId> = module
        .regions
        .values()
        .filter(|r| r.kind != RegionKind::ContAssign)
        .map(|r| r.id)
        .collect();
    // delay-v43: whole/field relations (`byp_d` read, `byp_d.be` written).
    let mut defs_by_root: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for k in comb_defs.keys() {
        if let Some(root) = crate::ref_order::dep_root(k) {
            defs_by_root.entry(root).or_default().push(k.clone());
        }
    }
    // delay-v44: reaching definitions. Another region contributes its final
    // value (its last write); inside the reader's own procedural block only
    // the latest write *before* the read reaches it. A later write of the
    // same block (the rename's mispredict repair of `free_d`, written after
    // the allocation picks read it) is not a fan-in of the read.
    let related_defs = |r: &str, reader: NodeId, reader_pos: u32| -> Vec<NodeId> {
        let reader_region = region_of.get(&reader).copied();
        let mut out = Vec::new();
        let Some(keys) = crate::ref_order::dep_root(r).and_then(|root| defs_by_root.get(&root))
        else {
            return out;
        };
        for k in keys.iter().filter(|k| crate::ref_order::dep_related(k, r)) {
            let Some(defs) = comb_defs.get(k) else {
                continue;
            };
            let mut best: BTreeMap<crate::ir::RegionId, (u32, NodeId)> = BTreeMap::new();
            for &(region, pos, nid) in defs {
                if Some(region) == reader_region
                    && procedural.contains(&region)
                    && pos >= reader_pos
                {
                    continue;
                }
                let e = best.entry(region).or_insert((pos, nid));
                if pos >= e.0 {
                    *e = (pos, nid);
                }
            }
            out.extend(best.values().map(|(_, nid)| *nid));
        }
        out
    };
    let by_root = |set: &BTreeSet<String>| -> BTreeMap<String, Vec<String>> {
        let mut m: BTreeMap<String, Vec<String>> = BTreeMap::new();
        for k in set {
            if let Some(root) = crate::ref_order::dep_root(k) {
                m.entry(root).or_default().push(k.clone());
            }
        }
        m
    };
    let related_in = |set: &BTreeMap<String, Vec<String>>, key: &str| -> bool {
        crate::ref_order::dep_root(key)
            .and_then(|root| set.get(&root))
            .is_some_and(|v| v.iter().any(|k| crate::ref_order::dep_related(k, key)))
    };
    let outputs: BTreeSet<String> = module
        .ports
        .iter()
        .filter(|p| p.direction == "output" || p.direction == "inout")
        .map(|p| ident_base(&p.name))
        .collect();
    let seq_lhs_roots = by_root(&seq_lhs);
    let seq_reads_roots = by_root(&seq_reads);
    let outputs_roots = by_root(&outputs);

    let mut edges: Vec<(NodeId, NodeId)> = Vec::new();
    let mut reads_reg: Vec<NodeId> = Vec::new();
    let mut sinks: Vec<NodeId> = Vec::new();
    for &nid in &comb_ids {
        let Some(n) = module.nodes.get(&nid) else {
            continue;
        };
        let reads: BTreeSet<_> = node_read_symbols_with_guards(module, n)
            .into_iter()
            .map(|s| bindings.key(&s, &n.loc))
            .collect();
        let mut hits_seq = false;
        for r in &reads {
            if related_in(&seq_lhs_roots, r) {
                hits_seq = true;
            }
            for src in related_defs(r, nid, n.loc.byte_start) {
                if src != nid && !edges.contains(&(src, nid)) {
                    edges.push((src, nid));
                }
            }
        }
        if hits_seq {
            reads_reg.push(nid);
        }
        let lhs = n
            .lhs
            .as_deref()
            .map(|s| bindings.key(&ident_base(s), &n.loc))
            .unwrap_or_default();
        if !lhs.is_empty()
            && (related_in(&seq_reads_roots, &lhs) || related_in(&outputs_roots, &lhs))
        {
            sinks.push(nid);
        }
    }
    if sinks.is_empty() {
        return;
    }

    drop(bindings);
    if let Some(module) = design.modules.get_mut(&mid) {
        for (src, dst) in &edges {
            if let Some(n) = module.nodes.get_mut(src) {
                if !n.fans_out.contains(dst) {
                    n.fans_out.push(*dst);
                }
            }
            if let Some(n) = module.nodes.get_mut(dst) {
                if !n.fans_in.contains(src) {
                    n.fans_in.push(*src);
                }
            }
        }
        for id in &reads_reg {
            if let Some(n) = module.nodes.get_mut(id) {
                n.reads_reg = true;
            }
        }
    }

    let Some(module) = design.modules.get(&mid) else {
        return;
    };
    let bindings = crate::ref_order::BindingIndex::new(module);
    let existing: BTreeSet<Vec<NodeId>> = design
        .paths
        .iter()
        .filter(|p| p.module == mid)
        .map(|p| p.nodes.clone())
        .collect();
    let mut next_id = design.paths.iter().map(|p| p.id).max().unwrap_or(0);
    let mod_name = module.name.clone();
    let mut new_paths: Vec<TimingPath> = Vec::new();
    // delay-v43: a composed cone whose node list equals a region path (one
    // `assign x_d = f(y_q)`) re-tags that path's endpoints instead of being
    // dropped; the region default is in→out and hid the reg→reg kind.
    let mut retag: Vec<(Vec<NodeId>, PathEndpoint, PathEndpoint)> = Vec::new();
    for sink in sinks {
        let nodes = longest_comb_path(module, &comb_ids, sink);
        if nodes.is_empty() {
            continue;
        }
        if existing.contains(&nodes) {
            let launch = nodes
                .iter()
                .any(|id| module.nodes.get(id).is_some_and(|n| n.reads_reg));
            let capture = module
                .nodes
                .get(&sink)
                .and_then(|n| {
                    n.lhs
                        .as_deref()
                        .map(|s| bindings.key(&ident_base(s), &n.loc))
                })
                .is_some_and(|lhs| related_in(&seq_reads_roots, &lhs));
            if launch || capture {
                let start = if launch {
                    PathEndpoint::RegClock { cell: 0 }
                } else {
                    PathEndpoint::InputPort {
                        module: mid,
                        port: 0,
                    }
                };
                let end = if capture {
                    PathEndpoint::RegData { cell: 1 }
                } else {
                    PathEndpoint::OutputPort {
                        module: mid,
                        port: 0,
                    }
                };
                retag.push((nodes, start, end));
            }
            continue;
        }
        let launch = nodes
            .iter()
            .any(|id| module.nodes.get(id).map(|n| n.reads_reg).unwrap_or(false));
        let lhs = module
            .nodes
            .get(&sink)
            .and_then(|n| {
                n.lhs
                    .as_deref()
                    .map(|s| bindings.key(&ident_base(s), &n.loc))
            })
            .unwrap_or_default();
        let capture = related_in(&seq_reads_roots, &lhs);
        let start = if launch {
            PathEndpoint::RegClock { cell: 0 }
        } else {
            PathEndpoint::InputPort {
                module: mid,
                port: 0,
            }
        };
        let end = if capture {
            PathEndpoint::RegData { cell: 1 }
        } else {
            PathEndpoint::OutputPort {
                module: mid,
                port: 0,
            }
        };
        let path_kind = PathKind::from_endpoints(&start, &end);
        let total_fo4 = chain_fo4(module, &nodes);
        next_id += 1;
        let region_id = region_of.get(&sink).copied().unwrap_or(0);
        let primary = module
            .nodes
            .get(&sink)
            .map(|n| n.loc.clone())
            .unwrap_or_else(|| SourceLoc::file_start(&module.file));
        new_paths.push(TimingPath {
            id: next_id,
            region_id,
            module: mid,
            start: start.clone(),
            end: end.clone(),
            path_kind,
            startpoint: start.report_name(&mod_name),
            endpoint: end.report_name(&mod_name),
            nodes,
            total_fo4,
            slack_fo4: 0.0,
            max_freq_mhz: 0.0,
            primary_loc: primary,
            multi_cycle: false,
            path_class: crate::path_class::PathClassKind::Plain,
            total_fo4_raw: None,
            class_note: Some("P5 composed launch-capture".into()),
            stage_start: None,
            stage_end: None,
        });
    }
    for path in design.paths.iter_mut().filter(|p| p.module == mid) {
        if let Some((_, start, end)) = retag.iter().find(|(n, _, _)| *n == path.nodes) {
            if path.path_kind == PathKind::InToOut {
                path.start = start.clone();
                path.end = end.clone();
                path.path_kind = PathKind::from_endpoints(start, end);
                path.startpoint = start.report_name(&mod_name);
                path.endpoint = end.report_name(&mod_name);
            }
        }
    }
    design.paths.extend(new_paths);
}

/// Reads of a node including its guards (delay-v37): the `if` predicates it
/// sits under and the index expressions of its LHS. `if (grant[g])
/// q[slot_entry[g]].valid = 0` reads `grant` and `slot_entry` — without them
/// the select cone never reaches the queue's next state.
fn node_read_symbols_with_guards(module: &TimingModule, n: &IrNode) -> BTreeSet<String> {
    let mut out = node_read_symbols(n);
    if let Some(gs) = module.guards.get(&n.id) {
        for g in gs {
            let g = g.strip_prefix('^').unwrap_or(g);
            for tok in ident_tokens(g) {
                let b = ident_base(&tok);
                if !b.is_empty() && looks_like_net(&b) {
                    out.insert(b);
                }
            }
            Expr::parse(g).walk_idents(&mut |s| {
                let b = ident_base(s);
                if !b.is_empty() && looks_like_net(&b) {
                    out.insert(b);
                }
            });
        }
    }
    out
}

fn node_read_symbols(n: &IrNode) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    let mut add = |s: &str| {
        let b = ident_base(s);
        if !b.is_empty() && looks_like_net(&b) {
            out.insert(b);
        }
    };
    if let Some(ex) = &n.rhs_expr {
        ex.walk_idents(&mut |s| add(s));
    }
    if let Some(rhs) = &n.rhs {
        Expr::parse(rhs).walk_idents(&mut |s| add(s));
        for tok in ident_tokens(rhs) {
            add(&tok);
        }
    }
    out
}

fn looks_like_net(s: &str) -> bool {
    !matches!(
        s,
        "if" | "else"
            | "begin"
            | "end"
            | "logic"
            | "wire"
            | "reg"
            | "assign"
            | "posedge"
            | "negedge"
            | "or"
            | "and"
    )
}

fn ident_tokens(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    for c in s.chars() {
        if c.is_ascii_alphanumeric() || c == '_' {
            cur.push(c);
        } else if !cur.is_empty() {
            if cur
                .chars()
                .next()
                .is_some_and(|x| x.is_ascii_alphabetic() || x == '_')
            {
                out.push(std::mem::take(&mut cur));
            } else {
                cur.clear();
            }
        }
    }
    if !cur.is_empty()
        && cur
            .chars()
            .next()
            .is_some_and(|x| x.is_ascii_alphabetic() || x == '_')
    {
        out.push(cur);
    }
    out
}

fn longest_comb_path(module: &TimingModule, comb: &BTreeSet<NodeId>, sink: NodeId) -> Vec<NodeId> {
    let mut best_pred: BTreeMap<NodeId, Option<NodeId>> = BTreeMap::new();
    let mut best_cost: BTreeMap<NodeId, f64> = BTreeMap::new();
    fn dfs(
        module: &TimingModule,
        comb: &BTreeSet<NodeId>,
        id: NodeId,
        visiting: &mut BTreeSet<NodeId>,
        best_pred: &mut BTreeMap<NodeId, Option<NodeId>>,
        best_cost: &mut BTreeMap<NodeId, f64>,
    ) -> f64 {
        if let Some(&c) = best_cost.get(&id) {
            return c;
        }
        if !visiting.insert(id) {
            return 0.0;
        }
        let self_c = module
            .nodes
            .get(&id)
            .map(|n| n.fo4_cost.max(0.0))
            .unwrap_or(0.0);
        let mut pred = None;
        let mut pred_c = 0.0_f64;
        if let Some(n) = module.nodes.get(&id) {
            for &p in &n.fans_in {
                if !comb.contains(&p) {
                    continue;
                }
                let c = dfs(module, comb, p, visiting, best_pred, best_cost);
                if c > pred_c + 1e-12 {
                    pred_c = c;
                    pred = Some(p);
                }
            }
        }
        visiting.remove(&id);
        let launch = module.launch_fo4.get(&id).copied().unwrap_or(0.0);
        let total = self_c + pred_c.max(launch);
        best_pred.insert(id, pred);
        best_cost.insert(id, total);
        total
    }
    let mut visiting = BTreeSet::new();
    dfs(
        module,
        comb,
        sink,
        &mut visiting,
        &mut best_pred,
        &mut best_cost,
    );
    let mut chain = Vec::new();
    let mut cur = Some(sink);
    let mut guard = 0u32;
    while let Some(id) = cur {
        chain.push(id);
        cur = best_pred.get(&id).copied().flatten();
        guard += 1;
        if guard > 4096 {
            break;
        }
    }
    chain.reverse();
    chain
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
    /// Failing `intoout` fragments (PASS-STRATEGY P5). Not period paths.
    #[serde(default)]
    pub intoout_failing: usize,
    /// Failing flop-to-flop paths used for `closes`.
    #[serde(default)]
    pub regtoreg_failing: usize,
    /// Modules in the file list that the elaborated design (`--width-map`)
    /// does not instantiate; their paths are excluded above. Empty without a map.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub uninstantiated_modules: Vec<String>,
}

/// Loop-carried accumulators of procedural `for` loops: node id → trip count.
///
/// For every procedural loop with a resolvable header (`k = A; k < N` /
/// `k <= N`), a node inside the loop whose LHS root (not the loop variable)
/// is also read by a node inside the same loop is one iteration of a serial
/// chain that synthesis unrolls `N − A` times (the scoreboard cancel-range
/// walk `cid = cid + 1` under `if (cid == ip) break` maps to a 436-cell
/// chain). The multiplier is capped at 64; loops whose bound the width
/// resolver cannot evaluate are left alone (unknown must not inflate).
/// How a loop-carried node is billed (delay-v37).
#[derive(Debug, Clone, Copy)]
struct CarryBill {
    /// Copies in series (trip count, or log2 for a balanced bitwise accumulate).
    mult: u32,
    /// The previous iteration's value enters only through the `if` guard
    /// (`if (!placed && !v[i]) placed = 1`): the serial step is one gate per
    /// iteration, the body's own cost is paid once.
    via_guard_only: bool,
    /// A bitwise/logical self-accumulate (`x = x | v`): under a guard it is
    /// `x | (g & v)` — the guard is one gate, not a select level.
    assoc: bool,
}

fn loop_carried_multipliers(
    module: &TimingModule,
    widths: &crate::width::WidthResolver<'_>,
) -> BTreeMap<NodeId, CarryBill> {
    let mut out: BTreeMap<NodeId, CarryBill> = BTreeMap::new();
    for lp in module.gen_loops.iter().filter(|g| g.procedural) {
        if lp.loc.origin != crate::loc::OriginKind::UserFile || lp.loc.byte_end <= lp.loc.byte_start
        {
            continue;
        }
        let Some(cond) = lp.cond_text.as_deref() else {
            continue;
        };
        let Some(trips) = loop_trip_count(&lp.genvar, lp.init_text.as_deref(), cond, widths) else {
            continue;
        };
        if trips <= 1 {
            continue;
        }
        let inside: Vec<&IrNode> = module
            .nodes
            .values()
            .filter(|n| {
                n.loc.origin == crate::loc::OriginKind::UserFile
                    && n.loc.file == lp.loc.file
                    && n.loc.byte_start >= lp.loc.byte_start
                    && n.loc.byte_start < lp.loc.byte_end
            })
            .collect();
        // Loop-carried = read before any write of the same iteration (the
        // previous iteration's value), or the first write reads itself.
        // A temp written then read inside one iteration (`rslot = base + i;
        // … mem_q[rslot]`) is not a chain.
        // Field granularity (delay-v37): `q_wake[e].rs1_rdy = 1` under
        // `if (q_wake[e].rs1 == wb[w])` writes one member and reads another
        // of the same struct array — no dependence between iterations (yosys
        // sees per-bit nets). Keys are root + member chain with indices
        // stripped (`q_wake.rs1_rdy`); a read of a prefix (`q_wake`,
        // `q_wake.sbe`) or an extension of the written key depends on it.
        let mut first_write: BTreeMap<String, (String, u32)> = BTreeMap::new();
        for n in &inside {
            if let Some(lhs) = n.lhs.as_deref() {
                let key = field_key(lhs);
                let root = TimingModule::root_ident(lhs).unwrap_or("").to_string();
                let e = first_write.entry(key).or_insert((root, n.loc.byte_start));
                e.1 = e.1.min(n.loc.byte_start);
            }
        }
        let dep = |read: &str, write: &str| -> bool {
            read == write
                || write.starts_with(&format!("{read}."))
                || read.starts_with(&format!("{write}."))
        };
        // `x[i].f` written and `x[i].g` read in the same iteration touch one
        // element: the loop variable in both first indices means no carry.
        let genvar = lp.genvar.as_str();
        let indexed_by_genvar = |tok: &str| -> bool {
            bracket_inners(tok)
                .first()
                .is_some_and(|ix| ix.trim() == genvar)
        };
        let write_idx_genvar: BTreeMap<String, bool> = inside
            .iter()
            .filter_map(|n| {
                n.lhs
                    .as_deref()
                    .map(|l| (field_key(l), indexed_by_genvar(l)))
            })
            .collect();
        // key → the read was through the guard only (never the RHS)
        let mut carried_keys: BTreeMap<String, bool> = BTreeMap::new();
        for n in &inside {
            let mut reads: Vec<(String, bool, String)> = Vec::new(); // (key, via_guard, token)
            if let Some(rhs) = n.rhs.as_deref() {
                for tok in field_tokens(rhs) {
                    reads.push((field_key(&tok), false, tok));
                }
            }
            if let Some(gs) = module.guards.get(&n.id) {
                for g in gs {
                    for tok in field_tokens(g.strip_prefix('^').unwrap_or(g)) {
                        reads.push((field_key(&tok), true, tok));
                    }
                }
            }
            let own_key = n.lhs.as_deref().map(field_key);
            for (r, via_guard, tok) in &reads {
                for (wkey, (root, fw)) in &first_write {
                    if root == &lp.genvar || !dep(r, wkey) {
                        continue;
                    }
                    if write_idx_genvar.get(wkey).copied().unwrap_or(false)
                        && indexed_by_genvar(tok)
                    {
                        continue;
                    }
                    let own_first_write =
                        own_key.as_deref() == Some(wkey.as_str()) && n.loc.byte_start == *fw;
                    if n.loc.byte_start < *fw || own_first_write {
                        let e = carried_keys.entry(wkey.clone()).or_insert(true);
                        *e = *e && *via_guard;
                    }
                }
            }
        }
        // A pure bitwise/logical self-accumulate (`acc = acc | x`, `any &&=
        // hit`) is an AND/OR tree ABC balances to log depth. An arithmetic
        // self-accumulate (`cid = cid + 1`, `cnt = cnt - y`) is not: each
        // step's carry depends on the previous sum, and the mapped fixture of
        // the scoreboard range walk kept all 32 steps serial under the
        // delay-oriented script (144 cells, 14.7 ns). Any other loop-carried
        // update (a compare/mux/priority chain such as `idx = hit[k] ? k :
        // idx`) stays serial too and costs every iteration.
        let depth = u32::try_from(usize::BITS - (trips as usize - 1).leading_zeros())
            .unwrap_or(1)
            .max(1);
        for n in &inside {
            let Some(root) = n.lhs.as_deref().and_then(TimingModule::root_ident) else {
                continue;
            };
            let key = n.lhs.as_deref().map(field_key).unwrap_or_default();
            let Some(&via_guard_only) = carried_keys.get(&key) else {
                continue;
            };
            let assoc = n
                .rhs_expr
                .as_ref()
                .is_some_and(|e| is_assoc_self_update(e, root));
            let mult = if assoc { depth } else { trips };
            let e = out.entry(n.id).or_insert(CarryBill {
                mult: 1,
                via_guard_only: true,
                assoc: true,
            });
            e.mult = e.mult.saturating_mul(mult).min(64);
            e.via_guard_only = e.via_guard_only && via_guard_only;
            e.assoc = e.assoc && assoc;
        }
    }
    out
}

/// `x OP t` / `t OP x` with OP bitwise or logical — and the same under a
/// select, `c ? x OP t : x` (the carry-less multiply's `clmul_d = b[i] ?
/// clmul_d ^ (a << i) : clmul_d`): `c ? x ^ t : x` is `x ^ (t & {c})`, an
/// XOR tree synthesis balances to log depth, not a 64-deep mux chain
/// (delay-v39).
fn is_assoc_self_update(e: &Expr, root: &str) -> bool {
    match e {
        Expr::Binary {
            op, left, right, ..
        } => {
            matches!(op.as_str(), "|" | "&" | "^" | "||" | "&&")
                && (expr_root_is(left, root) || expr_root_is(right, root))
        }
        Expr::Ternary { then_e, else_e, .. } => {
            // one arm holds, the other accumulates
            (expr_root_is(else_e, root) && is_assoc_self_update(then_e, root))
                || (expr_root_is(then_e, root) && is_assoc_self_update(else_e, root))
        }
        _ => false,
    }
}

/// Identifier references with their index/member text intact
/// (`a[i].x + mem[k].sbe.valid` → `a[i].x`, `mem[k].sbe.valid`).
fn field_tokens(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let b = text.as_bytes();
    let mut i = 0usize;
    while i < b.len() {
        if b[i].is_ascii_alphabetic() || b[i] == b'_' {
            let start = i;
            while i < b.len() && (b[i].is_ascii_alphanumeric() || b[i] == b'_') {
                i += 1;
            }
            loop {
                if i < b.len() && b[i] == b'[' {
                    let mut depth = 0i32;
                    while i < b.len() {
                        match b[i] {
                            b'[' => depth += 1,
                            b']' => {
                                depth -= 1;
                                if depth == 0 {
                                    i += 1;
                                    break;
                                }
                            }
                            _ => {}
                        }
                        i += 1;
                    }
                } else if i + 1 < b.len()
                    && b[i] == b'.'
                    && (b[i + 1].is_ascii_alphabetic() || b[i + 1] == b'_')
                {
                    i += 1;
                    while i < b.len() && (b[i].is_ascii_alphanumeric() || b[i] == b'_') {
                        i += 1;
                    }
                } else {
                    break;
                }
            }
            let tok = text[start..i].to_string();
            // `pkg::f(x)`: the function name is not a net (`is_amo =
            // … ariane_pkg::is_amo(op)` read itself and became a 16-copy
            // chain); a token followed by `(` is a call, one preceded by
            // `::` is package-qualified.
            let mut k = i;
            while k < b.len() && (b[k] == b' ' || b[k] == 9) {
                k += 1;
            }
            let is_call = k < b.len() && b[k] == b'(';
            let pkg_qualified = start >= 2 && &b[start - 2..start] == b"::";
            if !is_call
                && !pkg_qualified
                && looks_like_net(tok.split(['[', '.']).next().unwrap_or(&tok))
            {
                for inner in bracket_inners(&tok) {
                    out.extend(field_tokens(&inner));
                }
                out.push(tok);
            } else if is_call || pkg_qualified {
                for inner in bracket_inners(&tok) {
                    out.extend(field_tokens(&inner));
                }
            }
        } else if b[i].is_ascii_digit() {
            while i < b.len() && (b[i].is_ascii_alphanumeric() || b[i] == b'\'' || b[i] == b'_') {
                i += 1;
            }
        } else {
            i += 1;
        }
    }
    out
}

/// Per-iteration floor for the carried nodes of find-first scans: the guard
/// (`v[i] && pick == 0` / `&& !found`) is a compare on the carried value and a
/// gate, serial across iterations. `loop_carried_multipliers` then applies
/// the trip count. Nodes assigning the scan's variables inside the loop.
fn find_first_floors(
    module: &TimingModule,
    widths: &crate::width::WidthResolver<'_>,
    model: &CostModel,
) -> BTreeMap<NodeId, f64> {
    let mut out = BTreeMap::new();
    let shapes = crate::loop_walk::detect(module, widths, model);
    for shape in shapes
        .iter()
        .filter(|s| s.kind == crate::loop_walk::LoopWalkKind::FindFirst)
    {
        let Some(lp) = module.gen_loops.get(shape.loop_index) else {
            continue;
        };
        let floor = model.logic_bit * 2.0;
        for n in module.nodes.values() {
            let inside = n.loc.origin == crate::loc::OriginKind::UserFile
                && n.loc.file == lp.loc.file
                && n.loc.byte_start >= lp.loc.byte_start
                && n.loc.byte_start < lp.loc.byte_end;
            if !inside {
                continue;
            }
            if n.lhs.as_deref().and_then(TimingModule::root_ident) == Some(shape.carried.as_str()) {
                out.insert(n.id, floor);
            }
        }
    }
    out
}

/// Serial cost of a function body's statements (delay-v38). Assignments cost
/// their RHS at the reference width; a statement under `if (c)` adds the
/// guard and one select level (one gate for a bitwise self-accumulate); a
/// `for` with a resolvable bound multiplies its body by the trip count — by
/// `log2` for a bitwise self-accumulate (`idx = idx | i`), the encode of a
/// one-hot. A `case` is a table (delay-v43); anything unparsable costs
/// nothing (the return expression still does). Functions in packages are
/// included. A call inside a body bills its callee (delay-v43: the AES S-box
/// is three layered calls), resolved over a few rounds so nesting composes.
fn function_body_costs(
    module: &TimingModule,
    packages: &BTreeMap<String, crate::ir::TimingPackage>,
    widths: &crate::width::WidthResolver<'_>,
    model: &CostModel,
) -> BTreeMap<String, f64> {
    let bodies: Vec<&crate::ir::FunctionBody> = module
        .function_bodies
        .iter()
        .chain(packages.values().flat_map(|p| p.function_bodies.iter()))
        .filter(|fb| !fb.body_text.is_empty())
        .collect();
    let mut out: BTreeMap<String, f64> = BTreeMap::new();
    for _round in 0..4 {
        let mut next: BTreeMap<String, f64> = BTreeMap::new();
        for fb in &bodies {
            let c = function_text_cost(&fb.body_text, widths, model, &out);
            if c > 0.0 {
                let e = next.entry(fb.name.clone()).or_insert(0.0_f64);
                *e = e.max(c);
            }
        }
        let stable = next == out;
        out = next;
        if stable {
            break;
        }
    }
    out
}

fn function_text_cost(
    text: &str,
    widths: &crate::width::WidthResolver<'_>,
    model: &CostModel,
    fns: &BTreeMap<String, f64>,
) -> f64 {
    // header `function … ;` up to the first `;` after the closing paren of the
    // port list; body up to `endfunction`
    let t = crate::loop_walk::normalize_ws(text);
    let Some(end) = t.rfind("endfunction") else {
        return 0.0;
    };
    let head_end = match t.find(')') {
        Some(i) => t[i..].find(';').map(|j| i + j + 1).unwrap_or(0),
        None => 0,
    };
    if head_end == 0 || head_end >= end {
        return 0.0;
    }
    let body = &t[head_end..end];
    statements_cost(body, widths, model, fns, 0)
}

/// An expression's critical cost inside a function body, its calls billed
/// at their callees' known costs.
fn body_expr_cost(
    e: &Expr,
    base: &dyn Fn(OperatorClass) -> f64,
    seed: &crate::expr::ConstSeed,
    fns: &BTreeMap<String, f64>,
    model: &CostModel,
) -> f64 {
    if e.is_opaque() {
        return 0.0;
    }
    e.fo4_critical_cost_latticed(base, seed) + call_body_extra(e, fns, model)
}

fn statements_cost(
    body: &str,
    widths: &crate::width::WidthResolver<'_>,
    model: &CostModel,
    fns: &BTreeMap<String, f64>,
    depth: u32,
) -> f64 {
    if depth > 4 {
        return 0.0;
    }
    let base = |c: OperatorClass| model.scaled_fo4(c, None);
    let seed = crate::expr::ConstSeed::heuristic();
    // ASAP over the statement list: a statement starts when the last write
    // of anything it reads is done (independent statements overlap — the
    // 64 `out[Perm[k]] = in[k]` of a permutation are wiring, not a chain).
    let mut arrival: BTreeMap<String, f64> = BTreeMap::new();
    let mut worst = 0.0_f64;
    let roots = |text: &str| -> Vec<String> {
        ident_tokens(text)
            .into_iter()
            .map(|s| ident_base(&s))
            .filter(|s| !s.is_empty())
            .collect()
    };
    let place =
        |reads: &[String], writes: &[String], own: f64, arrival: &mut BTreeMap<String, f64>| {
            let start = reads
                .iter()
                .filter_map(|r| arrival.get(r).copied())
                .fold(0.0_f64, f64::max);
            let done = start + own;
            for w in writes {
                let e = arrival.entry(w.clone()).or_insert(0.0);
                *e = e.max(done);
            }
            done
        };
    // delay-v43: a `case` inside a function body is a table — a mux tree of
    // ceil(log2(arms)) levels over its selector (4:1 cells, like a runtime
    // index), plus the deepest arm. The S-box / mix-column tables of the AES
    // unit cost nothing before (statement splitting saw constant assigns).
    let (body, cases) = take_case_blocks(body);
    for (sel, items) in &cases {
        let sel_c = body_expr_cost(&Expr::parse(sel), &base, &seed, fns, model);
        let arms = crate::loop_walk::split_statements(items);
        let mut arm_c = 0.0_f64;
        let mut writes: Vec<String> = Vec::new();
        for arm in &arms {
            let body = strip_case_label(arm);
            arm_c = arm_c.max(statements_cost(body, widths, model, fns, depth + 1));
            if let Some((l, _)) = body.split_once('=') {
                let w = ident_base(l.trim());
                if !w.is_empty() && !writes.contains(&w) {
                    writes.push(w);
                }
            }
        }
        let levels = (arms.len().max(2) as f64).log2().ceil();
        let own = sel_c + arm_c + model.mux * (levels / 2.0).ceil();
        worst = worst.max(place(&roots(sel), &writes, own, &mut arrival));
    }
    for st in crate::loop_walk::split_statements(&body) {
        let st = st.trim();
        if st.starts_with("for (") {
            let Some(hdr_end) = st.find(')') else {
                continue;
            };
            let header = &st[5..hdr_end];
            let parts: Vec<&str> = header.split(';').collect();
            if parts.len() < 2 {
                continue;
            }
            let init = parts[0].rsplit('=').next().map(str::trim).unwrap_or("0");
            let cond = parts[1].trim();
            let (var, bound, inclusive) = if let Some((l, r)) = cond.split_once("<=") {
                (l.trim(), r.trim(), true)
            } else if let Some((l, r)) = cond.split_once('<') {
                (l.trim(), r.trim(), false)
            } else {
                continue;
            };
            let (Some(lo), Some(hi)) = (widths.eval_text(init), widths.eval_text(bound)) else {
                continue;
            };
            let trips = (hi - lo + i64::from(inclusive)).max(0) as u32;
            if trips == 0 {
                continue;
            }
            let inner = crate::loop_walk::loop_body(st).unwrap_or_default();
            // Iterations are independent when every write is indexed by the
            // loop variable (`data[b*8 +: 8] = …`): × 1. A linear update
            // (`x = x | …`, `x = x ^ …`, a flag set under a guard, a
            // shift-xor `state = {state[..], fb}`) is balanced by synthesis:
            // × log2(trips). Anything else carried (`cid = cid + 1`)
            // repeats per trip.
            let stmts = crate::loop_walk::split_statements(&inner);
            let writes_unindexed: Vec<&String> =
                stmts.iter().filter(|st| !lhs_indexed_by(st, var)).collect();
            let per = statements_cost(&inner, widths, model, fns, depth + 1);
            let levels = f64::from(trips.next_power_of_two().trailing_zeros().max(1));
            // A linear update's copies are parallel except for the
            // OR/AND/XOR tree that joins them: the body once plus a gate per
            // tree level — not the body per level (the eight 64-bit
            // compares of a window hit test run side by side).
            let own = if writes_unindexed.is_empty() {
                per
            } else if writes_unindexed.iter().all(|st| is_linear_update(st)) {
                per + model.logic_bit * (levels - 1.0).max(0.0)
            } else {
                per * f64::from(trips)
            };
            let writes: Vec<String> = stmts
                .iter()
                .filter_map(|s| {
                    let b = crate::loop_walk::split_if(s)
                        .map(|(_, b)| b)
                        .unwrap_or_else(|| s.clone());
                    b.split_once('=').map(|(l, _)| ident_base(l.trim()))
                })
                .filter(|s| !s.is_empty())
                .collect();
            let reads = roots(&inner);
            worst = worst.max(place(&reads, &writes, own, &mut arrival));
        } else if let Some((cond, inner)) = crate::loop_walk::split_if(st) {
            let gc = body_expr_cost(&Expr::parse(&cond), &base, &seed, fns, model);
            let ic = statements_cost(&inner, widths, model, fns, depth + 1);
            let assoc = crate::loop_walk::split_statements(&inner)
                .iter()
                .all(|st| is_bitwise_accumulate(st));
            let own = gc.max(ic) + if assoc { model.logic_bit } else { model.mux };
            let writes: Vec<String> = crate::loop_walk::split_statements(&inner)
                .iter()
                .filter_map(|s| s.split_once('=').map(|(l, _)| ident_base(l.trim())))
                .filter(|s| !s.is_empty())
                .collect();
            let mut reads = roots(&cond);
            reads.extend(roots(&inner));
            worst = worst.max(place(&reads, &writes, own, &mut arrival));
        } else if let Some(rest) = st.strip_prefix("return ") {
            let own = body_expr_cost(&Expr::parse(rest), &base, &seed, fns, model);
            worst = worst.max(place(&roots(rest), &[], own, &mut arrival));
        } else if let Some((l, r)) = st.split_once('=') {
            if r.starts_with('=') || l.ends_with('<') || l.ends_with('>') || l.ends_with('!') {
                continue;
            }
            // declarations with initialisers (`logic [N-1:0] x = …`) count their RHS too
            let own = body_expr_cost(&Expr::parse(r.trim()), &base, &seed, fns, model);
            let lhs_root = ident_base(l.trim().rsplit(' ').next().unwrap_or(l.trim()));
            worst = worst.max(place(&roots(r), &[lhs_root], own, &mut arrival));
        }
    }
    worst
}

/// Remove every top-level `case (sel) … endcase` from a statement-list text,
/// returning the rest and each block's `(selector, items)`.
fn take_case_blocks(body: &str) -> (String, Vec<(String, String)>) {
    let mut rest = String::with_capacity(body.len());
    let mut out = Vec::new();
    let b = body.as_bytes();
    let word_at = |i: usize| -> Option<(usize, &str)> {
        if !(b[i].is_ascii_alphabetic() || b[i] == b'_') {
            return None;
        }
        if i > 0 && (b[i - 1].is_ascii_alphanumeric() || b[i - 1] == b'_') {
            return None;
        }
        let mut j = i;
        while j < b.len() && (b[j].is_ascii_alphanumeric() || b[j] == b'_') {
            j += 1;
        }
        Some((j, &body[i..j]))
    };
    let mut i = 0usize;
    let mut copied = 0usize;
    while i < b.len() {
        let Some((j, w)) = word_at(i) else {
            i += 1;
            continue;
        };
        if !matches!(w, "case" | "casez" | "casex") {
            i = j;
            continue;
        }
        // selector in parentheses
        let Some(open) = body[j..].find('(').map(|o| j + o) else {
            break;
        };
        if !body[j..open].trim().is_empty() {
            i = j;
            continue;
        }
        let mut depth = 0i32;
        let mut close = None;
        for (k, c) in body[open..].char_indices() {
            match c {
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if depth == 0 {
                        close = Some(open + k);
                        break;
                    }
                }
                _ => {}
            }
        }
        let Some(close) = close else {
            break;
        };
        // matching endcase (nested cases counted)
        let mut nest = 1i32;
        let mut k = close + 1;
        let mut end = None;
        while k < b.len() {
            if let Some((kj, kw)) = word_at(k) {
                match kw {
                    "case" | "casez" | "casex" => nest += 1,
                    "endcase" => {
                        nest -= 1;
                        if nest == 0 {
                            end = Some((k, kj));
                            break;
                        }
                    }
                    _ => {}
                }
                k = kj;
            } else {
                k += 1;
            }
        }
        let Some((end_start, end_stop)) = end else {
            break;
        };
        rest.push_str(&body[copied..i]);
        out.push((
            body[open + 1..close].trim().to_string(),
            body[close + 1..end_start].trim().to_string(),
        ));
        copied = end_stop;
        i = end_stop;
    }
    rest.push_str(&body[copied..]);
    (rest, out)
}

/// `8'h3c: s = 8'hd1` → `s = 8'hd1`; `default: …` likewise.
fn strip_case_label(arm: &str) -> &str {
    let b = arm.as_bytes();
    let mut depth = 0i32;
    for i in 0..b.len() {
        match b[i] {
            b'(' | b'[' | b'{' => depth += 1,
            b')' | b']' | b'}' => depth -= 1,
            b':' if depth == 0 && b.get(i + 1) != Some(&b':') && (i == 0 || b[i - 1] != b':') => {
                return arm[i + 1..].trim();
            }
            b'=' if depth == 0 => return arm,
            _ => {}
        }
    }
    arm
}

/// The statement's LHS carries the loop variable in an index (`x[i]`,
/// `d[i*8 +: 8]`): one element per iteration.
fn lhs_indexed_by(stmt: &str, var: &str) -> bool {
    let inner = crate::loop_walk::split_if(stmt)
        .map(|(_, b)| b)
        .unwrap_or_else(|| stmt.to_string());
    let Some((l, _)) = inner.split_once('=') else {
        return true; // not a write
    };
    let l = l.trim();
    if l.is_empty() || l.ends_with('<') || l.ends_with('>') || l.ends_with('!') {
        return true;
    }
    let Some(open) = l.find('[') else {
        return false;
    };
    let idx = &l[open..];
    idx.split(|c: char| !(c.is_ascii_alphanumeric() || c == '_'))
        .any(|w| w == var)
}

/// A linear update of the LHS: `x = x | …`, `x = x ^ …`, `x = {x[..], f}` —
/// no arithmetic, compare or select outside index brackets. Synthesis
/// balances these to log depth (XOR/OR trees, shift-xor networks).
fn is_linear_update(stmt: &str) -> bool {
    if is_bitwise_accumulate(stmt) {
        return true;
    }
    let inner = crate::loop_walk::split_if(stmt)
        .map(|(_, b)| b)
        .unwrap_or_else(|| stmt.to_string());
    let Some((l, r)) = inner.split_once('=') else {
        return false;
    };
    let l = l.trim();
    let r = r.trim();
    if r.starts_with('=') {
        return false;
    }
    // a flag set/cleared under a guard (`if (hit) found = 1'b1`) is
    // `found | hit` / `found & ~miss`: an OR/AND tree over the copies
    if r.chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '\'' || c == '_')
        && !r.contains(l)
    {
        return true;
    }
    if !r.contains(l) {
        return false;
    }
    // strip index brackets, then refuse arithmetic / compare / select
    let mut depth = 0i32;
    let mut outside = String::new();
    for c in r.chars() {
        match c {
            '[' => depth += 1,
            ']' => depth -= 1,
            _ if depth == 0 => outside.push(c),
            _ => {}
        }
    }
    !outside.contains(['+', '-', '*', '/', '%', '<', '>', '?'])
        && !outside.contains("==")
        && !outside.contains("!=")
}

/// `[if (…)] x = x | …` / `& …` / `^ …`.
fn is_bitwise_accumulate(stmt: &str) -> bool {
    let inner = crate::loop_walk::split_if(stmt)
        .map(|(_, b)| b)
        .unwrap_or_else(|| stmt.to_string());
    let Some((l, r)) = inner.split_once('=') else {
        return false;
    };
    let l = l.trim();
    let r = r.trim().trim_end_matches(';').trim();
    if l.is_empty() {
        return false;
    }
    let accumulates = |t: &str| {
        t.strip_prefix(l).is_some_and(|rest| {
            let rest = rest.trim_start();
            rest.starts_with('|') || rest.starts_with('&') || rest.starts_with('^')
        })
    };
    if accumulates(r) {
        return true;
    }
    // `c ? x OP t : x` (or the arms swapped): a guarded accumulate as a select
    if let Some((_, arms)) = r.split_once('?') {
        if let Some((a, b)) = split_top_level_colon(arms) {
            let (a, b) = (a.trim(), b.trim());
            return (b == l && accumulates(a)) || (a == l && accumulates(b));
        }
    }
    false
}

/// Split `a : b` at the first top-level `:` (not inside brackets).
fn split_top_level_colon(t: &str) -> Option<(&str, &str)> {
    let mut depth = 0i32;
    for (i, c) in t.char_indices() {
        match c {
            '(' | '[' | '{' => depth += 1,
            ')' | ']' | '}' => depth -= 1,
            ':' if depth == 0 => return Some((&t[..i], &t[i + 1..])),
            _ => {}
        }
    }
    None
}

/// The costliest user-function body called in an expression, less the one
/// `Other` gate the expression bill already charged for the call.
fn call_body_extra(ex: &Expr, fn_costs: &BTreeMap<String, f64>, model: &CostModel) -> f64 {
    if fn_costs.is_empty() {
        return 0.0;
    }
    let mut names = Vec::new();
    ex.call_names(&mut names);
    let mut worst = 0.0_f64;
    for n in names {
        let short = n.rsplit("::").next().unwrap_or(n);
        if let Some(c) = fn_costs.get(short).or_else(|| fn_costs.get(n)) {
            worst = worst.max(*c);
        }
    }
    (worst - model.scaled_fo4(OperatorClass::Other, None)).max(0.0)
}

/// Levels beyond the one already billed for the widest runtime index of an
/// expression: a k-bit index is `ceil(k/2)` 4:1 mux levels (`mem_q[slot]`
/// over 32 entries is three, not one).
fn extra_select_levels(
    ex: &Expr,
    widths: &crate::width::WidthResolver<'_>,
    seed: &crate::expr::ConstSeed,
) -> f64 {
    let mut idx = Vec::new();
    ex.runtime_indices(seed, &mut idx);
    let mut worst = 0u32;
    for i in idx {
        let w = widths.node_widths(None, Some(i));
        if let Some(k) = w.arith.or(w.for_class(OperatorClass::Compare)) {
            worst = worst.max(k);
        }
    }
    if worst <= 2 {
        0.0
    } else {
        f64::from(worst.div_ceil(2) - 1)
    }
}

/// Nodes inside procedural loops that unroll to zero iterations.
fn dead_loop_nodes(
    module: &TimingModule,
    widths: &crate::width::WidthResolver<'_>,
) -> BTreeSet<NodeId> {
    let mut out = BTreeSet::new();
    for lp in module.gen_loops.iter().filter(|g| g.procedural) {
        if lp.loc.origin != crate::loc::OriginKind::UserFile || lp.loc.byte_end <= lp.loc.byte_start
        {
            continue;
        }
        let Some(cond) = lp.cond_text.as_deref() else {
            continue;
        };
        if loop_trip_count(&lp.genvar, lp.init_text.as_deref(), cond, widths) != Some(0) {
            continue;
        }
        for n in module.nodes.values() {
            if n.loc.origin == crate::loc::OriginKind::UserFile
                && n.loc.file == lp.loc.file
                && n.loc.byte_start >= lp.loc.byte_start
                && n.loc.byte_start < lp.loc.byte_end
            {
                out.insert(n.id);
            }
        }
    }
    out
}

/// The level a guard adds: a select (`mux`) for a plain guarded write, one
/// gate (`logic_bit`) for a guarded bitwise self-accumulate (`x | (g & v)`).
fn guard_level(carried: &BTreeMap<NodeId, CarryBill>, id: NodeId, model: &CostModel) -> f64 {
    match carried.get(&id) {
        Some(b) if b.assoc && !b.via_guard_only => model.logic_bit,
        _ => model.mux,
    }
}

/// A carried node's cost: through the RHS, every copy repeats the body
/// (`cid = cid + 1`: trips × body); through the guard alone, the serial step
/// is one gate per copy (`if (!placed && …) placed = 1`: the `!placed` AND
/// chain) and the body is paid once.
fn carry_cost(body: f64, bill: &CarryBill, model: &CostModel) -> f64 {
    if bill.via_guard_only {
        body + model.logic_bit * f64::from(bill.mult.saturating_sub(1))
    } else {
        body * f64::from(bill.mult)
    }
}

/// `q_wake[e].rs1_rdy` → `q_wake.rs1_rdy`: root and member chain, indices
/// and part-selects stripped.
fn field_key(text: &str) -> String {
    let mut out = String::new();
    let b = text.as_bytes();
    let mut i = 0usize;
    let mut depth = 0i32;
    while i < b.len() {
        let c = b[i];
        match c {
            b'[' => depth += 1,
            b']' => depth -= 1,
            _ if depth == 0 => {
                if c.is_ascii_alphanumeric() || c == b'_' || c == b'.' || c == b'$' {
                    out.push(c as char);
                } else if !out.is_empty() {
                    break;
                }
            }
            _ => {}
        }
        i += 1;
    }
    out.trim_matches('.').to_string()
}

fn bracket_inners(tok: &str) -> Vec<String> {
    let b = tok.as_bytes();
    let mut out = Vec::new();
    let mut i = 0usize;
    while i < b.len() {
        if b[i] == b'[' {
            let start = i + 1;
            let mut depth = 1i32;
            let mut j = start;
            while j < b.len() && depth > 0 {
                match b[j] {
                    b'[' => depth += 1,
                    b']' => depth -= 1,
                    _ => {}
                }
                j += 1;
            }
            if depth == 0 {
                out.push(tok[start..j - 1].to_string());
                i = j;
                continue;
            }
            break;
        }
        i += 1;
    }
    out
}

fn expr_root_is(e: &crate::expr::Expr, root: &str) -> bool {
    match e {
        crate::expr::Expr::Ident { name } => TimingModule::root_ident(name) == Some(root),
        crate::expr::Expr::Index { base, .. } => expr_root_is(base, root),
        _ => false,
    }
}

/// `k = A; k < N` → `N − A` (`<=` → `N − A + 1`); `None` when either side
/// does not evaluate to an elaboration constant.
fn loop_trip_count(
    var: &str,
    init: Option<&str>,
    cond: &str,
    widths: &crate::width::WidthResolver<'_>,
) -> Option<u32> {
    let cond = cond.trim();
    let (lhs, rhs, inclusive) = if let Some((l, r)) = cond.split_once("<=") {
        (l, r, true)
    } else if let Some((l, r)) = cond.split_once('<') {
        (l, r, false)
    } else {
        return None;
    };
    if lhs.trim() != var {
        return None;
    }
    let bound = widths.eval_text(rhs.trim())?;
    let start = match init {
        Some(t) => widths.eval_text(t.trim())?,
        None => 0,
    };
    let n = bound - start + i64::from(inclusive);
    (n > 0).then_some(u32::try_from(n).unwrap_or(u32::MAX))
}

/// Compute frequency-closure report from ranked paths.
///
/// With an elaborated width map (`design.width_map`), only modules the
/// elaborator instantiated count: a file list carries every module a *family*
/// of configs can use (`fpnew_fma_multi` is in the list and not in
/// `g6lc64_ooo`), and a dead module's cone is not this target's period.
pub fn frequency_closure(design: &TimingDesign) -> FrequencyClosure {
    let ranked = rank_paths_by_slack(&design.paths, &design.target);
    let mut uninstantiated: Vec<String> = Vec::new();
    let live: Option<std::collections::BTreeSet<ModuleId>> = if design.width_map.is_empty() {
        None
    } else {
        let mut set = std::collections::BTreeSet::new();
        for (id, m) in &design.modules {
            if design.width_map.contains_key(&m.name) {
                set.insert(*id);
            } else {
                uninstantiated.push(m.name.clone());
            }
        }
        Some(set)
    };
    let primary: Vec<&TimingPath> = ranked
        .primary
        .iter()
        .filter(|p| live.as_ref().is_none_or(|l| l.contains(&p.module)))
        .collect();
    let reg_to_reg = primary
        .iter()
        .filter(|p| p.path_kind == crate::ir::PathKind::RegToReg)
        .count();
    let failing = primary.iter().filter(|p| p.slack_fo4 < 0.0).count();
    let intoout_failing = primary
        .iter()
        .filter(|p| p.slack_fo4 < 0.0 && p.path_kind == crate::ir::PathKind::InToOut)
        .count();
    let regtoreg_failing = primary
        .iter()
        .filter(|p| p.slack_fo4 < 0.0 && p.path_kind == crate::ir::PathKind::RegToReg)
        .count();
    let worst = primary
        .iter()
        .find(|p| p.path_kind == crate::ir::PathKind::RegToReg)
        .or_else(|| primary.first())
        .copied();
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
        // P5: `intoout` fragments do not decide period closure. A fragment
        // under budget says nothing; a fragment over budget is still reported
        // in `intoout_failing` but `closes` follows flop-to-flop paths.
        closes: regtoreg_failing == 0 && reg_to_reg > 0,
        max_freq_mhz: worst
            .map(|p| p.max_freq_mhz)
            .unwrap_or(design.target.target_mhz),
        failing_paths: failing,
        reg_to_reg_paths: reg_to_reg,
        intoout_failing,
        regtoreg_failing,
        uninstantiated_modules: uninstantiated,
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
            .then_with(|| {
                b.total_fo4
                    .partial_cmp(&a.total_fo4)
                    .unwrap_or(std::cmp::Ordering::Equal)
            })
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
        // Large mul-only clouds in *mul*/*fpnew* units (iterative array). A
        // named datapath assign chain (gemm c_span) is P8, not multi-cycle.
        let budget = design.target.budget_fo4;
        let mul_heavy = path.nodes.iter().any(|id| {
            module
                .nodes
                .get(id)
                .map(|n| {
                    n.op_class == Some(OperatorClass::Mul) && n.fo4_cost >= (budget * 2.0).max(50.0)
                })
                .unwrap_or(false)
        });
        if mul_heavy && (nlow.contains("mul") || nlow.contains("mult") || nlow.contains("fpnew")) {
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
        // Iterative SRT / C910 / PULP FPU control — not single-cycle EX.
        // Trace: 181 InsertRegs on `ct_vfdsu_srt_radix16_with_sqrt` at 4 GHz.
        || n.contains("vfdsu")
        || n.contains("fdsu")
        || n.contains("srt_radix")
        || n.contains("control_mvp")
        || n.contains("preprocess_mvp")
        || n.contains("iteration_div")
        || n.contains("nrbd_nrsc")
        // Memory macros / wrappers — not single-cycle EX pressure
        || n.contains("tc_sram")
        || n.contains("syncdpram")
        || n.contains("asyncdpram")
        || n.contains("syncthreeport")
        || n.contains("asyncthreeport")
        || (n.contains("sram") && (n.contains("wrapper") || n.contains("cache")))
        || n == "sram"
        || n.ends_with("_ram")
        || n.ends_with("_sva")
        || n.contains("_sva")
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
    let model = CostModel::default();
    // SelectIncrement (A88) needs widths and the module's register set.
    let mut reg_cache: BTreeMap<ModuleId, std::collections::BTreeSet<String>> = BTreeMap::new();
    let mut arrival_cache: BTreeMap<ModuleId, crate::expr_rewrite::Arrivals> = BTreeMap::new();
    let mut loop_shapes: BTreeMap<ModuleId, Vec<crate::loop_walk::LoopWalkShape>> = BTreeMap::new();
    for path in &design.paths {
        if path.multi_cycle || path.slack_fo4 >= 0.0 {
            continue;
        }
        if path.nodes.is_empty() {
            continue;
        }
        let module = design.modules.get(&path.module);
        // ExprRewrite (A122): exact identities on one node — circular compare,
        // zero detect of a difference, a late select pushed through
        // arithmetic. Pure RHS rewrites; the transform re-detects and prices.
        // Offered before the single-node guard: an identity needs no interior.
        if let Some(m) = module {
            let regs = reg_cache
                .entry(m.id)
                .or_insert_with(|| crate::select_increment::register_roots(m));
            let arrivals = arrival_cache
                .entry(m.id)
                .or_insert_with(|| crate::expr_rewrite::Arrivals::of(m, regs, &model));
            let resolver = crate::width::WidthResolver::from_parts(
                &design.packages,
                &design.param_map_ints,
                &m.decls,
                &m.ports,
                &m.const_exprs,
                &m.typedef_texts,
                &m.package_imports,
                design.width_map.get(&m.name),
            );
            // The `if` predicates guarding a node of the path: an identity on
            // one is offered with the predicate's own span as its locus.
            let mut guard_sites_seen: std::collections::BTreeSet<(u32, u32)> =
                std::collections::BTreeSet::new();
            for id in &path.nodes {
                for g in m.guards.get(id).into_iter().flatten() {
                    let text = g.trim_start_matches('^').trim();
                    for site in m.guard_sites.iter().filter(|s| s.text.trim() == text) {
                        if !guard_sites_seen.insert((site.loc.start_line, site.loc.byte_start)) {
                            continue;
                        }
                        let Some(shape) =
                            crate::expr_rewrite::detect_guard(m, site, &resolver, &model, arrivals)
                        else {
                            continue;
                        };
                        out.push(Opportunity {
                            kind: OpportunityKind::ExprRewrite,
                            path_id: path.id,
                            insert_after: *id,
                            estimated_fo4_before: path.total_fo4,
                            estimated_fo4_after: (path.total_fo4 - shape.gain()).max(0.0),
                            loc: site.loc.clone(),
                            rationale: format!(
                                "path {} expr_rewrite {} on guard of node {id}: `if ({})` -> `if ({})` (guard {:.1}->{:.1} FO4{}; no latency)",
                                path.id,
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
                                    format!(", +{:.0} est. cells", shape.est_cells)
                                } else {
                                    String::new()
                                }
                            ),
                            requires_clock_in_scope: false,
                            changes_latency: false,
                        });
                    }
                }
            }
            for id in &path.nodes {
                let Some(n) = m.nodes.get(id) else { continue };
                let Some(shape) = crate::expr_rewrite::detect(m, n, &resolver, &model, arrivals)
                else {
                    continue;
                };
                out.push(Opportunity {
                    kind: OpportunityKind::ExprRewrite,
                    path_id: path.id,
                    insert_after: *id,
                    estimated_fo4_before: path.total_fo4,
                    estimated_fo4_after: (path.total_fo4 - shape.gain()).max(0.0),
                    loc: n.loc.clone(),
                    rationale: format!(
                        "path {} expr_rewrite {} on node {id}: `{}` = `{}` -> `{}` (node {:.1}->{:.1} FO4{}; no latency)",
                        path.id,
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
                            format!(", +{:.0} est. cells", shape.est_cells)
                        } else {
                            String::new()
                        }
                    ),
                    requires_clock_in_scope: false,
                    changes_latency: false,
                });
            }
        }

        // PASS-STRATEGY P3: a single-node path has no interior to cut.
        if path.nodes.len() <= 1 {
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
        if module.is_some_and(|m| {
            path.nodes
                .iter()
                .filter_map(|id| m.nodes.get(id))
                .any(|n| n.assign_kind == crate::ir::AssignKind::BlockingCompound)
        }) {
            // Measure the read/modify/write dependency, but do not authorize
            // a source rewrite until compound origins have explicit support.
            continue;
        }

        // SelectIncrement: `REG + narrow step` at the end of a cone — exact,
        // latency-neutral, the adder leaves the critical path (A88). Any class
        // that reaches here may carry one; the detector prices the select.
        if let Some(m) = module {
            let regs = reg_cache
                .entry(m.id)
                .or_insert_with(|| crate::select_increment::register_roots(m));
            if !regs.is_empty() {
                let resolver = crate::width::WidthResolver::from_parts(
                    &design.packages,
                    &design.param_map_ints,
                    &m.decls,
                    &m.ports,
                    &m.const_exprs,
                    &m.typedef_texts,
                    &m.package_imports,
                    design.width_map.get(&m.name),
                );
                for id in &path.nodes {
                    let Some(n) = m.nodes.get(id) else { continue };
                    let Some(shape) =
                        crate::select_increment::detect(m, n, regs, &resolver, &model)
                    else {
                        continue;
                    };
                    out.push(Opportunity {
                        kind: OpportunityKind::SelectIncrement,
                        path_id: path.id,
                        insert_after: *id,
                        estimated_fo4_before: path.total_fo4,
                        estimated_fo4_after: (path.total_fo4 - shape.gain()).max(0.0),
                        loc: n.loc.clone(),
                        rationale: format!(
                            "path {} select_increment on node {id}: `{}` = `{}` {} `{}` ({} candidates, {} select level(s); no latency)",
                            path.id,
                            shape.lhs_text,
                            shape.reg_text,
                            shape.operator,
                            shape.step_ident,
                            shape.candidates(),
                            shape.mux_levels()
                        ),
                        requires_clock_in_scope: false,
                        changes_latency: false,
                    });
                }
            }
        }

        // LoopRewrite (A101): a path through a serial loop walk gets the walk's
        // exact parallel form offered first. The opportunity names a node of
        // the path inside the loop; the transform re-detects the shape.
        if let Some(m) = module {
            let shapes = loop_shapes.entry(m.id).or_insert_with(|| {
                let resolver = crate::width::WidthResolver::from_parts(
                    &design.packages,
                    &design.param_map_ints,
                    &m.decls,
                    &m.ports,
                    &m.const_exprs,
                    &m.typedef_texts,
                    &m.package_imports,
                    design.width_map.get(&m.name),
                );
                crate::loop_walk::detect(m, &resolver, &model)
            });
            for shape in shapes.iter() {
                let Some(lp) = m.gen_loops.get(shape.loop_index) else {
                    continue;
                };
                let inside = path.nodes.iter().find(|id| {
                    m.nodes.get(id).is_some_and(|n| {
                        n.loc.origin == crate::loc::OriginKind::UserFile
                            && n.loc.file == lp.loc.file
                            && n.loc.byte_start >= lp.loc.byte_start
                            && n.loc.byte_start < lp.loc.byte_end
                    })
                });
                let Some(node_id) = inside else {
                    continue;
                };
                out.push(Opportunity {
                    kind: OpportunityKind::LoopRewrite,
                    path_id: path.id,
                    insert_after: *node_id,
                    estimated_fo4_before: path.total_fo4,
                    estimated_fo4_after: (path.total_fo4 / f64::from(shape.trips.max(1))
                        + shape.fo4_after)
                        .max(0.0),
                    loc: lp.loc.clone(),
                    rationale: format!("path {} loop_rewrite: {}", path.id, shape.rationale),
                    requires_clock_in_scope: false,
                    changes_latency: false,
                });
            }
        }

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

        // InsertReg only for plain comb datapath. Exclusive/atomic/FPU/SVA
        // lanes never get a spray-on flop (4 GHz: 181 InsertRegs on vfdsu).
        // An over-budget cycle cone is the exception: the long next-state
        // and dense bundles are the paths the budget-fit cuts are for.
        let cycle_cone = crate::pass_strategy::over_budget_cycle_cone(path);
        if exclusive && !cycle_cone {
            continue;
        }
        if !crate::cone_lane::cone_lane(design, path).allows_insert_reg() && !cycle_cone {
            continue;
        }
        if !crate::pass_strategy::admits_insert_reg(path) {
            continue;
        }
        // Timing basis §5: InsertReg only on the scratchboard's just-in-time
        // cycle boundaries (critical ops whose ASAP end crosses k·B), not a
        // mid-path index. Prefer the kept region scratch (always_ff stays
        // clock-aware: bars are that clock's period). Fall back to a mid cut
        // if the board has no bar.
        let budget = design.target.budget_fo4;
        let empty = std::collections::BTreeMap::new();
        let jit: Vec<u32> = if let Some(m) = module {
            let computed;
            let scratch = if let Some(s) = design
                .parallel_timing
                .get(&m.name)
                .and_then(|b| b.scratch_for_region(path.region_id))
            {
                s
            } else {
                computed = if let Some(reg) = m.regions.get(&path.region_id) {
                    crate::parallel_timing::ParallelScratch::schedule_for_region(
                        m,
                        reg,
                        &design.target,
                        &empty,
                    )
                } else {
                    crate::parallel_timing::ParallelScratch::schedule(
                        m,
                        &path.nodes,
                        budget,
                        &empty,
                    )
                };
                &computed
            };
            if !scratch.procedural_ok {
                continue;
            }
            scratch
                .jit_cuts_on_clock()
                .into_iter()
                .filter(|nid| path.nodes.contains(nid))
                .collect()
        } else {
            Vec::new()
        };
        let cut_nodes: Vec<u32> = if jit.is_empty() {
            let cut_idx = if path.nodes.len() == 1 {
                0
            } else {
                path.nodes.len() / 2 - 1
            };
            vec![path.nodes[cut_idx]]
        } else {
            jit
        };
        for after in cut_nodes {
            let loc = design
                .modules
                .get(&path.module)
                .and_then(|m| m.nodes.get(&after))
                .map(|n| n.loc.clone())
                .unwrap_or_else(|| path.primary_loc.clone());
            let after_est = (path.total_fo4 - budget).max(budget);
            out.push(Opportunity {
                kind: OpportunityKind::InsertReg,
                path_id: path.id,
                insert_after: after,
                estimated_fo4_before: path.total_fo4,
                estimated_fo4_after: after_est,
                loc,
                rationale: format!(
                    "path {} JIT cut after node {after} (scratchboard cycle bar; slack {:.1} FO4)",
                    path.id, path.slack_fo4
                ),
                requires_clock_in_scope: true,
                changes_latency: true,
            });
        }
    }
    // A149 M12: a register on an elastic output port cuts the cross-module
    // path the port is part of; the module's own paths do not show the gain.
    out.extend(crate::pipe_contract::port_stage_opportunities(design));
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
    crate::pipeline_preprocess::prepare_design(design);
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
            path.total_fo4 = chain_fo4(module, &path.nodes);
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
    let hint_ref = if hints.is_empty() { None } else { Some(&hints) };
    crate::path_class::classify_and_adjust_paths(design, &model, hint_ref);
    crate::pass_strategy::tag_handshake_locks(design);
    crate::parallel_timing::fill_design_parallel_timing(design);
    crate::cleanliness::fill_design_cleanliness(design);
    refresh_primary_locs(design);
    design.pass_plan = crate::pass_strategy::plan_from_design(design);
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
        let start = PathEndpoint::InputPort { module: 0, port: 0 };
        let end = PathEndpoint::OutputPort { module: 0, port: 1 };
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
            stage_start: None,
            stage_end: None,
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
            start: crate::ir::PathEndpoint::InputPort { module: 0, port: 0 },
            end: crate::ir::PathEndpoint::OutputPort { module: 0, port: 0 },
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
            stage_start: None,
            stage_end: None,
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
        assert!(module_looks_multi_cycle("ct_vfdsu_srt_radix16_with_sqrt"));
        assert!(module_looks_multi_cycle("control_mvp"));
        assert!(module_looks_multi_cycle("pa_fdsu_ctrl"));
        assert!(!module_looks_multi_cycle("alu"));
        assert!(!module_looks_multi_cycle("multiplier"));
        assert!(!module_looks_multi_cycle("fpnew_fma"));
        assert!(module_looks_multi_cycle("dm_top_sva"));
    }

    fn opportunity_design(process: &str) -> TimingDesign {
        let text = format!(
            "module opportunity_test(input logic clk_i, input logic [31:0] a, b, c, output logic [31:0] q, r);\n{process} begin\nq = a + b;\nr = q + c;\nend\nendmodule\n"
        );
        let path = std::path::PathBuf::from("opportunity_test.sv");
        let defines: sv_parser::Defines = Default::default();
        let (tree, _) = sv_parser::parse_sv_str(
            &text,
            &path,
            &defines,
            &[] as &[std::path::PathBuf],
            false,
            false,
        )
        .expect("parse opportunity source");
        let file = crate::parse::ParsedFile {
            path: path.clone(),
            bytes: text.as_bytes().to_vec(),
            line_index: crate::loc::LineIndex::from_bytes(path, text.as_bytes()),
            tree,
        };
        let mut design = crate::lower::lower_unit(
            &crate::parse::ParsedUnit {
                files: vec![file],
                skipped: vec![],
            },
            &crate::lower::LowerOptions {
                target: TimingTarget::new(4000.0, 20.0, 0.2),
                ..crate::lower::LowerOptions::default()
            },
        )
        .expect("lower opportunity source")
        .design;
        for path in &mut design.paths {
            path.path_class = crate::path_class::PathClassKind::Plain;
        }
        design
    }

    #[test]
    fn unverified_sequential_scratch_never_falls_back_to_midpoint_cut() {
        for fallback in 0..3 {
            let mut design = opportunity_design("always_ff @(posedge clk_i)");
            assert!(design.paths.iter().any(|p| p.slack_fo4 < 0.0));
            assert!(!design.parallel_timing["opportunity_test"].procedural_ok);
            if fallback >= 1 {
                design.parallel_timing.clear();
            }
            if fallback == 2 {
                for module in design.modules.values_mut() {
                    module.regions.clear();
                }
            }
            assert!(
                suggest_opportunities(&design)
                    .iter()
                    .all(|op| op.kind != OpportunityKind::InsertReg),
                "unverified scratch with fallback mode {fallback} must not yield InsertReg"
            );
        }
    }

    #[test]
    fn cached_unverified_comb_scratch_never_falls_back_to_midpoint_cut() {
        let mut design = opportunity_design("always_comb");
        assert!(suggest_opportunities(&design)
            .iter()
            .any(|op| op.kind == OpportunityKind::InsertReg));
        for board in design.parallel_timing.values_mut() {
            board.procedural_ok = false;
            for scratch in board.regions.values_mut() {
                scratch.procedural_ok = false;
            }
        }
        assert!(suggest_opportunities(&design)
            .iter()
            .all(|op| op.kind != OpportunityKind::InsertReg));
    }

    #[test]
    fn verified_comb_scratch_still_allows_insert_reg_with_or_without_cached_board() {
        let mut design = opportunity_design("always_comb");
        for cached in [true, false] {
            if !cached {
                design.parallel_timing.clear();
            }
            assert!(suggest_opportunities(&design)
                .iter()
                .any(|op| op.kind == OpportunityKind::InsertReg));
        }
    }

    #[test]
    fn suggest_opportunities_skips_multi_cycle() {
        let mut design = TimingDesign::empty(TimingTarget::new(1250.0, 20.0, 0.2));
        let mut p = sample_path(1, -100.0, 200.0);
        p.multi_cycle = true;
        p.nodes = vec![1];
        design.paths.push(p);
        let ops = suggest_opportunities(&design);
        assert!(
            ops.is_empty(),
            "multi_cycle paths must not yield insert/split ops"
        );
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

    #[test]
    fn primary_loc_is_hottest_node_not_last_statement() {
        use crate::ir::{IrNode, TimingModule};
        use std::collections::BTreeMap as Map;
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
                loc: loc(340),
                fans_in: vec![],
                fans_out: vec![],
                width_defaulted: true,
                reads_reg: false,
                lhs: Some("acc_d".into()),
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
                op_class: Some(OperatorClass::Other),
                width: 1,
                fo4_cost: 1.0,
                gate: None,
                loc: loc(680),
                fans_in: vec![],
                fans_out: vec![],
                width_defaulted: true,
                reads_reg: false,
                lhs: Some("state_d".into()),
                rhs: Some("ST_IDLE".into()),
                lhs_expr: None,
                rhs_expr: None,
                case_labels: Vec::new(),
                case_is_default: true,
                case_selector: None,
                fo4_locked: false,
                assign_kind: Default::default(),
            },
        );
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
                const_exprs: Default::default(),
                typedef_texts: Default::default(),
                config_branch: false,
                guards: Default::default(),
                onehot_facts: Default::default(),
                guard_sites: Default::default(),
                decl_texts: Default::default(),
                pipe_pragmas: Default::default(),
            stage_decls: Default::default(),
                branch_arms: Default::default(),
                launch_fo4: Default::default(),
                loc: loc(1),
            },
        );
        let mut p = sample_path(1, -47.0, 57.0);
        p.nodes = vec![0, 1];
        p.primary_loc = loc(680);
        p.module = 0;
        design.paths.push(p);
        refresh_primary_locs(&mut design);
        assert_eq!(
            design.paths[0].primary_loc.start_line, 340,
            "must blame the mul, not default: state_d"
        );
    }

    #[test]
    fn gemm_span_composes_reg_to_reg_mul_chain() {
        let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures/auto_correct/gemm_span.sv");
        if !path.exists() {
            return;
        }
        let mut lower = crate::lower::LowerOptions {
            target: TimingTarget::new(4000.0, 20.0, 0.2),
            cost_model: crate::cost_table::default_fo4_v1_embedded(),
            module_filter: vec!["gemm_span".into()],
            ..Default::default()
        };
        lower.cost_model.id = "fo4-v1".into();
        let out = crate::lower::analyze_files(&[path], &crate::ParseOptions::default(), &lower)
            .expect("analyze");
        let composed: Vec<_> = out
            .design
            .paths
            .iter()
            .filter(|p| {
                matches!(
                    p.path_kind,
                    PathKind::RegToReg | PathKind::InToReg | PathKind::RegToOut
                ) && p.nodes.len() > 1
            })
            .collect();
        assert!(
            !composed.is_empty(),
            "expected P5 composed RegToReg on gemm_span; paths={:?}",
            out.design
                .paths
                .iter()
                .map(|p| format!(
                    "id={} kind={:?} fo4={:.1} nodes={} note={:?}",
                    p.id,
                    p.path_kind,
                    p.total_fo4,
                    p.nodes.len(),
                    p.class_note
                ))
                .collect::<Vec<_>>()
        );
        let best = composed
            .iter()
            .max_by(|a, b| {
                let ar = a.total_fo4_raw.unwrap_or(a.total_fo4);
                let br = b.total_fo4_raw.unwrap_or(b.total_fo4);
                ar.partial_cmp(&br).unwrap()
            })
            .unwrap();
        assert!(
            best.nodes.len() > 1,
            "composed path must chain assigns, nodes={}",
            best.nodes.len()
        );
        let raw = best.total_fo4_raw.unwrap_or(best.total_fo4);
        assert!(
            raw > 50.0,
            "composed cone still contains the mul in raw FO4, raw={raw} adj={}",
            best.total_fo4
        );
        assert_ne!(
            best.path_class,
            crate::path_class::PathClassKind::IndependentLhsBundle,
            "gemm serial chain must not be an independent-LHS bundle: {:?}",
            best.class_note
        );
    }
}
