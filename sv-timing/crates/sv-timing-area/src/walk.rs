// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Exclusive and inclusive structural area over a TimingDesign.
// Does not write fo4_cost and does not elaborate procedural ifs.

//! Area walk. Operator width is 1 until source dimension text is recorded.
//! Loops count as one copy. Instance rollup reads `TimingDesign.instances` only.

use std::collections::{BTreeMap, BTreeSet, HashSet};

use sv_timing_core::{
    billed_binary_class, classify_unary, extend_seed_auto_const, max_freq_mhz_for_path,
    user_function_op_class, ConstSeed, Expr, IrNode, ModuleId, OperatorClass, ParamMap, PathKind,
    TimingDesign, TimingModule, TimingPath,
};

use crate::inclusion::{file_name, glob_match, Inclusion};
use crate::marks::AsmMarks;
use crate::model::AreaModel;
use crate::width::{bit_width, builtin_net};

const OPERATOR_WIDTH: u32 = 1;

/// How primary structural frequency was chosen.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PerfBasis {
    /// No admitted node and no storage.
    Empty,
    /// Worst primary register-to-register path.
    RegToReg,
    /// Worst other primary path.
    PrimaryPath,
    /// Only multi-cycle paths. Primary frequency is absent.
    MulticycleOnly,
    /// No path. Max node FO4.
    NodeDepth,
}

/// One module row after the instance-forest rollup.
#[derive(Debug, Clone, PartialEq)]
pub struct ModuleRow {
    /// Module name.
    pub name: String,
    /// Regions, case surcharges, and local operators. No child instances.
    pub exclusive_au: f64,
    /// Exclusive plus rule-2 children.
    pub inclusive_au: f64,
    /// `root`, `child`, or `unbound`.
    pub role: &'static str,
    /// Basis of this module's own paths. `multicycle_only` when every path is multi-cycle.
    pub perf_basis: &'static str,
    /// Max primary-path FO4 in this module. `0` when it has no primary path.
    pub delay_fo4: f64,
    /// Max of this module's delay and the inclusive delay of rule-2 children.
    pub inclusive_delay_fo4: f64,
    /// Rollup tags (`opaque_child`, `config_unresolved`, …).
    pub tags: Vec<String>,
}

/// One case group. The surcharge is not copied onto each arm.
#[derive(Debug, Clone, PartialEq)]
pub struct CaseGroup {
    /// Module name.
    pub module: String,
    /// Case selector text.
    pub selector: String,
    /// Shared LHS. Empty when the arm has no LHS.
    pub lhs: String,
    /// Labeled arms plus the default item when present.
    pub n_arms: u32,
    /// `mux * width * ceil(log2(max(n_arms, 2)))` at the width in force.
    pub surcharge_au: f64,
    /// Bit width used for the surcharge.
    pub width_bits: u32,
    /// Billed class of each arm's root operator, in node-id order.
    pub arm_classes: Vec<OperatorClass>,
}

/// Area, primary delay, and frequency for one inclusion.
#[derive(Debug, Clone, PartialEq)]
pub struct Metrics {
    /// Inclusive area. `None` when the inclusion is empty.
    pub area_au: Option<f64>,
    /// Primary path FO4. `None` when there is no primary path.
    pub delay_fo4: Option<f64>,
    /// Primary structural MHz. `None` when unbounded or empty.
    pub perf_mhz: Option<f64>,
    /// `perf_mhz / area_au` when both are finite and area is positive.
    pub perf_per_area: Option<f64>,
    /// `finite`, `unbounded`, or `empty`.
    pub perf_state: &'static str,
    /// Why performance/area is null. `None` when the ratio is finite.
    pub null_reason: Option<&'static str>,
}

/// One ranked node. Tie-break is file, line, node id, module name.
#[derive(Debug, Clone, PartialEq)]
pub struct RankRow {
    /// Module name.
    pub module: String,
    /// Node id.
    pub node_id: u32,
    /// Source file.
    pub file: String,
    /// 1-based line.
    pub line: u32,
    /// Exclusive area.
    pub exclusive_au: f64,
    /// Node `fo4_cost`.
    pub delay_fo4: f64,
    /// `fo4_cost` when this node is on the worst primary path, otherwise 0.
    pub critical_contribution_fo4: f64,
}

/// Result of [`attribute`]. Placeholder weights make `*_au` non-normative.
#[derive(Debug, Clone, PartialEq)]
pub struct AreaReport {
    /// `instance_forest`.
    pub rollup: &'static str,
    /// Module rows.
    pub modules: Vec<ModuleRow>,
    /// Case groups.
    pub case_groups: Vec<CaseGroup>,
    /// Sum of root inclusives plus each unbound type's exclusive area once.
    pub design_inclusive_au: f64,
    /// True when any selected instance still has `param_override_present = None`.
    pub field_absent: bool,
    /// Operators billed at width 1.
    pub n_width_defaulted: u32,
    /// Generate and procedural loops. Each counts as one copy.
    pub n_generate_unresolved: u32,
    /// Instances whose child type is not in the design.
    pub n_opaque_child: u32,
    /// Calls with no lowered body.
    pub n_body_unlowered: u32,
    /// Decls whose storage width did not resolve.
    pub n_storage_unrecorded: u32,
    /// Instances with `#(...)`. Policy. Not part of [`AreaReport::attribution_gaps`].
    pub n_instance_params_unrecorded: u32,
    /// Overlay keys that selected no const ternary.
    pub n_config_unresolved: u32,
    /// Cross-module paths whose local path id is missing or not in the design.
    pub n_cross_path_unresolved: u32,
    /// Selected instances whose override flag was absent from the blob.
    pub n_field_absent: u32,
    /// Primary basis.
    pub perf_basis: PerfBasis,
    /// Id of the worst primary path. Absent for `multicycle_only`, `node_depth`, and `empty`.
    pub primary_path_id: Option<u32>,
    /// Primary structural MHz. Absent when unbounded or empty.
    pub perf_mhz: Option<f64>,
    /// Multi-cycle structural MHz when a multi-cycle path exists.
    pub perf_multicycle_mhz: Option<f64>,
    /// Area of nodes that are not on the worst primary path.
    /// `None` when the basis is empty.
    pub off_path_area_au: Option<f64>,
    /// Canonical inclusion text. Empty when no filter was set.
    pub inclusion: String,
    /// The three FO4 metrics.
    pub metrics: Metrics,
    /// Assembly-task marks. Empty until a task folder is attached.
    pub marks: AsmMarks,
    /// Hottest exclusive area, capped by [`AreaReport::top`].
    pub rank_exclusive_area: Vec<RankRow>,
    /// Cap for rank lists and the serialized module tree.
    pub top: usize,
    /// Nodes on the worst primary path. Empty for `multicycle_only` and `empty`.
    pub on_path: Vec<RankRow>,
}

impl AreaReport {
    /// Failed overlay keys, missing cross-path ids, and absent lower fields.
    pub fn attribution_gaps(&self) -> u32 {
        self.n_config_unresolved + self.n_cross_path_unresolved + self.n_field_absent
    }
}

/// Walk the whole design. Does not mutate it.
pub fn attribute(design: &TimingDesign, area: &AreaModel, params: &ParamMap) -> AreaReport {
    attribute_with(design, area, params, &Inclusion::all(), 20)
        .expect("the empty inclusion is valid")
}

/// Walk `design` under `inclusion`. Does not mutate the design or its FO4.
pub fn attribute_with(
    design: &TimingDesign,
    area: &AreaModel,
    params: &ParamMap,
    inclusion: &Inclusion,
    top: usize,
) -> Result<AreaReport, crate::inclusion::InclusionError> {
    if inclusion.conflicts() {
        return Err(crate::inclusion::InclusionError::AllWithFilter);
    }
    let mut params = params.clone();
    for (key, value) in &inclusion.config {
        params.insert(key.clone(), value.clone());
    }
    let params = &params;
    let mut exclusives: BTreeMap<ModuleId, f64> = BTreeMap::new();
    let mut case_groups = Vec::new();
    let mut n_width_defaulted = 0u32;
    let mut n_body_unlowered = 0u32;
    let mut n_generate_unresolved = 0u32;
    let mut n_storage_unresolved = 0u32;
    let mut node_area: BTreeMap<(ModuleId, u32), f64> = BTreeMap::new();

    for module in design.modules.values() {
        if !module_selected(inclusion, design, module) {
            continue;
        }
        n_generate_unresolved += module.gen_loops.len() as u32;
        let (exclusive, groups, width_ops, calls, unresolved, areas) =
            module_exclusive(design, module, area, params, inclusion);
        n_storage_unresolved += unresolved;
        exclusives.insert(module.id, exclusive);
        n_width_defaulted += width_ops;
        n_body_unlowered += calls;
        for (id, au) in areas {
            node_area.insert((module.id, id), au);
        }
        case_groups.extend(groups);
    }

    let mut n_field_absent = 0u32;
    let mut n_instance_params_unrecorded = 0u32;
    let mut n_opaque_child = 0u32;
    let mut unbound: BTreeSet<ModuleId> = BTreeSet::new();
    let mut rule2_children: BTreeSet<ModuleId> = BTreeSet::new();
    let mut tags_by_module: BTreeMap<ModuleId, Vec<String>> = BTreeMap::new();

    for inst in &design.instances {
        let Some(parent) = design.modules.get(&inst.parent_module) else {
            continue;
        };
        if !module_selected(inclusion, design, parent)
            || !instance_selected(inclusion, design, inst)
        {
            continue;
        }
        match (inst.child_module, inst.param_override_present) {
            (None, _) => {
                n_opaque_child += 1;
                tags_by_module
                    .entry(inst.parent_module)
                    .or_default()
                    .push(format!("opaque_child={}", inst.instance_name));
            }
            (Some(_), None) => {
                n_field_absent += 1;
                tags_by_module
                    .entry(inst.parent_module)
                    .or_default()
                    .push("instance_params=field_absent".into());
            }
            (Some(child), Some(true)) => {
                n_instance_params_unrecorded += 1;
                unbound.insert(child);
                tags_by_module
                    .entry(inst.parent_module)
                    .or_default()
                    .push("instance_params=unrecorded".into());
            }
            (Some(child), Some(false)) => {
                rule2_children.insert(child);
            }
        }
    }

    let mut inclusive: BTreeMap<ModuleId, f64> = BTreeMap::new();
    let mut recursive_ids: BTreeSet<ModuleId> = BTreeSet::new();
    for id in design.modules.keys().copied() {
        let mut stack = Vec::new();
        let _ = inclusive_of(
            id,
            design,
            inclusion,
            &exclusives,
            &mut inclusive,
            &mut stack,
            &mut recursive_ids,
        );
    }
    for id in recursive_ids {
        tags_by_module
            .entry(id)
            .or_default()
            .push("recursive_instance".into());
    }

    let mut modules = Vec::new();
    let mut design_inclusive = 0.0;
    for module in design.modules.values() {
        if !module_selected(inclusion, design, module)
            && !rule2_children.contains(&module.id)
            && !unbound.contains(&module.id)
        {
            continue;
        }
        let child_only = rule2_children.contains(&module.id) || unbound.contains(&module.id);
        let role = if unbound.contains(&module.id) && !rule2_children.contains(&module.id) {
            "unbound"
        } else if child_only {
            "child"
        } else {
            "root"
        };
        let mut tags = tags_by_module.remove(&module.id).unwrap_or_default();
        tags.extend(storage_tags(module));
        if !module.gen_loops.is_empty() {
            tags.push("generate_unresolved".into());
        }
        if module.config_branch {
            tags.push("config_unresolved".into());
        }
        if module_overlay_selected(design, module, params, inclusion) {
            tags.push("area_arm_selected".into());
            tags.push("delay_not_respecialized".into());
        }
        let row = ModuleRow {
            name: module.name.clone(),
            exclusive_au: exclusives.get(&module.id).copied().unwrap_or(0.0),
            inclusive_au: inclusive.get(&module.id).copied().unwrap_or(0.0),
            role,
            perf_basis: module_perf_basis(design, module.id),
            delay_fo4: module_delay(design, module.id),
            inclusive_delay_fo4: 0.0,
            tags,
        };
        if role == "root" {
            design_inclusive += row.inclusive_au;
        }
        modules.push(row);
    }
    for id in &unbound {
        if !rule2_children.contains(id) {
            design_inclusive += exclusives.get(id).copied().unwrap_or(0.0);
        }
    }
    let mut delay_memo = BTreeMap::new();
    let mut delay_stack = Vec::new();
    for module in &mut modules {
        let Some(id) = design.module_names.get(&module.name).copied() else {
            continue;
        };
        module.inclusive_delay_fo4 =
            inclusive_delay(id, design, inclusion, &mut delay_memo, &mut delay_stack);
    }
    modules.sort_by(|a, b| a.name.cmp(&b.name));

    let perf = performance(design, &node_area, inclusion, top);
    let report = AreaReport {
        rollup: "instance_forest",
        modules,
        case_groups,
        design_inclusive_au: design_inclusive,
        field_absent: n_field_absent > 0,
        n_width_defaulted,
        n_generate_unresolved,
        n_opaque_child,
        n_body_unlowered,
        n_storage_unrecorded: n_storage_unresolved,
        n_instance_params_unrecorded,
        n_config_unresolved: failed_overlays(design, params, inclusion),
        n_cross_path_unresolved: cross_paths_unresolved(design, inclusion),
        n_field_absent,
        perf_basis: perf.basis,
        primary_path_id: perf.primary_path_id,
        perf_mhz: perf.mhz,
        perf_multicycle_mhz: perf.multicycle_mhz,
        off_path_area_au: perf.off_path_au,
        inclusion: inclusion.canonical(),
        metrics: metrics_for(design_inclusive, perf.basis, perf.primary_c, perf.mhz),
        marks: AsmMarks::unmeasured(),
        rank_exclusive_area: rank_nodes(
            design,
            &node_area,
            &on_path_keys(&perf.on_path),
            Some(area),
            top,
        ),
        top,
        on_path: perf.on_path,
    };
    Ok(report)
}

fn module_exclusive(
    design: &TimingDesign,
    module: &TimingModule,
    area: &AreaModel,
    params: &ParamMap,
    inclusion: &Inclusion,
) -> (f64, Vec<CaseGroup>, u32, u32, u32, Vec<(u32, f64)>) {
    let defaults = parameter_defaults(module);
    let widths = signal_widths(module, &defaults);
    let bodies = function_body_areas(design, module, area, params);
    let mut node_au: BTreeMap<u32, f64> = BTreeMap::new();
    let mut node_class: BTreeMap<u32, OperatorClass> = BTreeMap::new();
    let mut node_width: BTreeMap<u32, u32> = BTreeMap::new();
    let mut width_ops = 0u32;
    let mut calls = 0u32;
    for node in module.nodes.values() {
        if !node_kept(inclusion, design, module, node.id) {
            continue;
        }
        let seed = seed_for(design, module, node);
        let resolved = node
            .rhs_expr
            .as_ref()
            .and_then(|expr| expr_signal_width(expr, &widths));
        let width = resolved.unwrap_or(OPERATOR_WIDTH);
        let walked = node_expr_area(node, area, params, &seed, width, &bodies);
        node_au.insert(node.id, walked.point);
        node_width.insert(node.id, width);
        if let Some(class) = walked.root_class {
            node_class.insert(node.id, class);
        }
        if resolved.is_none() {
            width_ops += walked.operators;
        }
        calls += walked.unlowered_calls;
    }

    let mut in_region: HashSet<u32> = HashSet::new();
    let mut exclusive = 0.0;
    let mut groups = Vec::new();
    for region in module.regions.values() {
        for id in &region.nodes {
            in_region.insert(*id);
            exclusive += node_au.get(id).copied().unwrap_or(0.0);
        }
        let region_groups = case_groups_for(
            module,
            &region.nodes,
            &node_au,
            &node_class,
            &node_width,
            area,
        );
        for group in &region_groups {
            exclusive += group.surcharge_au;
        }
        groups.extend(region_groups);
    }
    let mut loose = Vec::new();
    for id in module.nodes.keys() {
        if !in_region.contains(id) {
            exclusive += node_au.get(id).copied().unwrap_or(0.0);
            loose.push(*id);
        }
    }
    if !loose.is_empty() {
        let loose_groups =
            case_groups_for(module, &loose, &node_au, &node_class, &node_width, area);
        for group in &loose_groups {
            exclusive += group.surcharge_au;
        }
        groups.extend(loose_groups);
    }
    exclusive += storage_area(module, area, &defaults);
    let unresolved = unresolved_storage(module, &defaults);
    let areas = node_au.into_iter().collect();
    (exclusive, groups, width_ops, calls, unresolved, areas)
}

fn case_groups_for(
    module: &TimingModule,
    node_ids: &[u32],
    node_au: &BTreeMap<u32, f64>,
    node_class: &BTreeMap<u32, OperatorClass>,
    node_width: &BTreeMap<u32, u32>,
    area: &AreaModel,
) -> Vec<CaseGroup> {
    let _ = node_au;
    let mut buckets: BTreeMap<(String, String), Vec<u32>> = BTreeMap::new();
    for id in node_ids {
        if !node_au.contains_key(id) {
            continue;
        }
        let Some(node) = module.nodes.get(id) else {
            continue;
        };
        let Some(selector) = node.case_selector.as_ref() else {
            continue;
        };
        if selector.is_empty() && node.case_labels.is_empty() && !node.case_is_default {
            continue;
        }
        let lhs = node.lhs.clone().unwrap_or_default();
        buckets
            .entry((selector.clone(), lhs))
            .or_default()
            .push(*id);
    }
    let mut groups = Vec::new();
    for ((selector, lhs), ids) in buckets {
        let mut labels = BTreeSet::new();
        let mut has_default = false;
        let mut arm_classes = Vec::new();
        for id in &ids {
            let Some(node) = module.nodes.get(id) else {
                continue;
            };
            for label in &node.case_labels {
                labels.insert(label.clone());
            }
            if node.case_is_default {
                has_default = true;
            }
            if let Some(class) = node_class.get(id) {
                arm_classes.push(*class);
            }
        }
        let n_arms = labels.len() as u32 + u32::from(has_default);
        if n_arms == 0 {
            continue;
        }
        let arms = n_arms.max(2);
        let width_bits = ids
            .iter()
            .filter_map(|id| node_width.get(id).copied())
            .max()
            .unwrap_or(OPERATOR_WIDTH);
        let surcharge = area.mux * f64::from(width_bits) * f64::from(ceil_log2(arms));
        groups.push(CaseGroup {
            module: module.name.clone(),
            selector,
            lhs,
            n_arms,
            surcharge_au: surcharge,
            width_bits,
            arm_classes,
        });
    }
    groups
}

fn inclusive_of(
    id: ModuleId,
    design: &TimingDesign,
    inclusion: &Inclusion,
    exclusives: &BTreeMap<ModuleId, f64>,
    memo: &mut BTreeMap<ModuleId, f64>,
    stack: &mut Vec<ModuleId>,
    recursive_ids: &mut BTreeSet<ModuleId>,
) -> f64 {
    if let Some(au) = memo.get(&id) {
        return *au;
    }
    if stack.contains(&id) {
        recursive_ids.insert(id);
        return exclusives.get(&id).copied().unwrap_or(0.0);
    }
    stack.push(id);
    let mut total = exclusives.get(&id).copied().unwrap_or(0.0);
    for inst in design
        .instances
        .iter()
        .filter(|inst| inst.parent_module == id)
    {
        if inst.param_override_present != Some(false) || !instance_selected(inclusion, design, inst)
        {
            continue;
        }
        let Some(parent) = design.modules.get(&id) else {
            continue;
        };
        if !module_selected(inclusion, design, parent) {
            continue;
        }
        let Some(child) = inst.child_module else {
            continue;
        };
        total += inclusive_of(
            child,
            design,
            inclusion,
            exclusives,
            memo,
            stack,
            recursive_ids,
        );
    }
    stack.pop();
    memo.insert(id, total);
    total
}

struct PerfOut {
    basis: PerfBasis,
    mhz: Option<f64>,
    multicycle_mhz: Option<f64>,
    off_path_au: Option<f64>,
    primary_c: Option<f64>,
    on_path: Vec<RankRow>,
    primary_path_id: Option<u32>,
}

fn performance(
    design: &TimingDesign,
    node_area: &BTreeMap<(ModuleId, u32), f64>,
    inclusion: &Inclusion,
    top: usize,
) -> PerfOut {
    if node_area.is_empty() {
        return PerfOut {
            basis: PerfBasis::Empty,
            mhz: None,
            multicycle_mhz: None,
            off_path_au: None,
            primary_c: None,
            on_path: Vec::new(),
            primary_path_id: None,
        };
    }
    let admitted = |path: &&TimingPath| {
        path_matches(inclusion, path)
            && path
                .nodes
                .iter()
                .all(|id| node_area.contains_key(&(path.module, *id)))
    };
    let primary_reg = design
        .paths
        .iter()
        .filter(|p| !p.multi_cycle && p.path_kind == PathKind::RegToReg)
        .filter(admitted);
    let primary_other = design
        .paths
        .iter()
        .filter(|p| !p.multi_cycle && p.path_kind != PathKind::RegToReg)
        .filter(admitted);
    let multi = design
        .paths
        .iter()
        .filter(|p| p.multi_cycle)
        .filter(admitted);
    let bridged = design
        .cross_module_paths
        .iter()
        .filter(|p| {
            p.stitch_kind == "port_bridged"
                && inclusion.path_classes.is_empty()
                && inclusion.path_kinds.is_empty()
        })
        .map(|p| p.total_fo4);

    let reg_max = max_path(primary_reg);
    let other_path = max_path(primary_other);
    let bridge_max = bridged.fold(None, |acc: Option<f64>, cost| {
        Some(acc.map_or(cost, |prev| prev.max(cost)))
    });
    let other_max = match (other_path.map(|(cost, _)| cost), bridge_max) {
        (Some(cost), Some(bridge)) => Some(cost.max(bridge)),
        (Some(cost), None) => Some(cost),
        (None, bridge) => bridge,
    };
    let mc_max = max_path(multi);

    let (basis, primary_c, on_path) = if let Some((c, path)) = reg_max {
        (PerfBasis::RegToReg, Some(c), Some(path))
    } else if let Some(c) = other_max {
        (PerfBasis::PrimaryPath, Some(c), None)
    } else if mc_max.is_some() {
        (PerfBasis::MulticycleOnly, None, None)
    } else if !node_area.is_empty() {
        let c = node_area
            .keys()
            .filter_map(|(mid, id)| design.modules.get(mid)?.nodes.get(id).map(|n| n.fo4_cost))
            .fold(0.0, f64::max);
        (PerfBasis::NodeDepth, Some(c), None)
    } else {
        (PerfBasis::Empty, None, None)
    };

    let fo4_ps = design.target.fo4_ps;
    let margin = design.target.budget_margin;
    let mhz = primary_c.and_then(|c| mhz_of(c, fo4_ps, margin));
    let multicycle_mhz = mc_max.and_then(|(c, _)| mhz_of(c, fo4_ps, margin));
    let off_path_au = match basis {
        PerfBasis::Empty => None,
        PerfBasis::MulticycleOnly => Some(node_area.values().sum()),
        PerfBasis::RegToReg => {
            let on = on_path.map(|p| path_node_set(p)).unwrap_or_default();
            Some(off_path_sum(node_area, &on))
        }
        PerfBasis::PrimaryPath | PerfBasis::NodeDepth => Some(node_area.values().sum()),
    };
    let primary_path_id = match basis {
        PerfBasis::RegToReg => reg_max.map(|(_, path)| path.id),
        PerfBasis::PrimaryPath => other_path
            .filter(|(cost, _)| bridge_max.is_none_or(|bridge| *cost >= bridge))
            .map(|(_, path)| path.id),
        PerfBasis::MulticycleOnly | PerfBasis::NodeDepth | PerfBasis::Empty => None,
    };
    let on_rows = if matches!(basis, PerfBasis::MulticycleOnly | PerfBasis::Empty) {
        Vec::new()
    } else if let Some(path) = on_path {
        rank_nodes(
            design,
            &path_area(node_area, path),
            &HashSet::new(),
            None,
            top,
        )
    } else {
        Vec::new()
    };
    PerfOut {
        basis,
        mhz,
        multicycle_mhz,
        off_path_au,
        primary_c,
        on_path: on_rows,
        primary_path_id,
    }
}

/// Reorder module rows for `--metric`. `area` is exclusive area, hottest first.
/// `perf` is module delay. `perf-per-area` is smallest finite ratio first.
pub fn order_module_rows(
    rows: &mut [ModuleRow],
    metric: &str,
    perf_mhz: Option<f64>,
) -> Result<(), &'static str> {
    match metric {
        "area" => rows.sort_by(|a, b| {
            b.exclusive_au
                .total_cmp(&a.exclusive_au)
                .then_with(|| a.name.cmp(&b.name))
        }),
        "perf" => rows.sort_by(|a, b| {
            b.delay_fo4
                .total_cmp(&a.delay_fo4)
                .then_with(|| a.name.cmp(&b.name))
        }),
        "perf-per-area" => rows.sort_by(|a, b| {
            match (pa_ratio(a, perf_mhz), pa_ratio(b, perf_mhz)) {
                (Some(left), Some(right)) => left.total_cmp(&right),
                (Some(_), None) => std::cmp::Ordering::Less,
                (None, Some(_)) => std::cmp::Ordering::Greater,
                (None, None) => std::cmp::Ordering::Equal,
            }
            .then_with(|| a.name.cmp(&b.name))
        }),
        _ => return Err("metric must be area, perf, or perf-per-area"),
    }
    Ok(())
}

fn pa_ratio(row: &ModuleRow, perf_mhz: Option<f64>) -> Option<f64> {
    let mhz = perf_mhz?;
    if row.exclusive_au > 0.0 {
        Some(mhz / row.exclusive_au)
    } else {
        None
    }
}

fn max_path<'a>(paths: impl Iterator<Item = &'a TimingPath>) -> Option<(f64, &'a TimingPath)> {
    paths
        .max_by(|a, b| a.total_fo4.total_cmp(&b.total_fo4))
        .map(|p| (p.total_fo4, p))
}

fn mhz_of(cost: f64, fo4_ps: f64, margin: f64) -> Option<f64> {
    if cost > 0.0 && fo4_ps > 0.0 && margin < 1.0 {
        Some(max_freq_mhz_for_path(cost, fo4_ps, margin))
    } else {
        None
    }
}

fn path_node_set(path: &TimingPath) -> HashSet<(ModuleId, u32)> {
    path.nodes.iter().map(|id| (path.module, *id)).collect()
}

fn off_path_sum(node_area: &BTreeMap<(ModuleId, u32), f64>, on: &HashSet<(ModuleId, u32)>) -> f64 {
    node_area
        .iter()
        .filter(|(key, _)| !on.contains(key))
        .map(|(_, au)| *au)
        .sum()
}

fn metrics_for(
    area_au: f64,
    basis: PerfBasis,
    primary_c: Option<f64>,
    perf_mhz: Option<f64>,
) -> Metrics {
    if basis == PerfBasis::Empty {
        return Metrics {
            area_au: None,
            delay_fo4: None,
            perf_mhz: None,
            perf_per_area: None,
            perf_state: "empty",
            null_reason: Some("empty_inclusion"),
        };
    }
    if basis == PerfBasis::MulticycleOnly {
        return Metrics {
            area_au: Some(area_au),
            delay_fo4: None,
            perf_mhz: None,
            perf_per_area: None,
            perf_state: "unbounded",
            null_reason: Some("no_primary_path"),
        };
    }
    let delay = primary_c.filter(|c| *c > 0.0);
    let (perf_state, null_reason, ratio) = if area_au == 0.0 {
        (
            if perf_mhz.is_some() {
                "finite"
            } else {
                "unbounded"
            },
            Some("zero_area"),
            None,
        )
    } else if let Some(mhz) = perf_mhz {
        ("finite", None, Some(mhz / area_au))
    } else {
        ("unbounded", Some("zero_delay"), None)
    };
    Metrics {
        area_au: Some(area_au),
        delay_fo4: delay,
        perf_mhz,
        perf_per_area: ratio,
        perf_state,
        null_reason,
    }
}

fn rank_nodes(
    design: &TimingDesign,
    node_area: &BTreeMap<(ModuleId, u32), f64>,
    on_path: &HashSet<(String, u32)>,
    area: Option<&AreaModel>,
    top: usize,
) -> Vec<RankRow> {
    let mut rows = Vec::new();
    for ((mid, id), au) in node_area {
        let Some(module) = design.modules.get(mid) else {
            continue;
        };
        let Some(node) = module.nodes.get(id) else {
            continue;
        };
        let critical = if on_path.contains(&(module.name.clone(), *id)) {
            node.fo4_cost
        } else {
            0.0
        };
        rows.push(RankRow {
            module: module.name.clone(),
            node_id: *id,
            file: node.loc.file.clone(),
            line: node.loc.start_line,
            exclusive_au: *au,
            delay_fo4: node.fo4_cost,
            critical_contribution_fo4: critical,
        });
    }
    if let Some(area) = area {
        rows.extend(storage_rank_rows(design, area));
    }
    rows.sort_by(|a, b| {
        b.exclusive_au
            .total_cmp(&a.exclusive_au)
            .then_with(|| a.file.cmp(&b.file))
            .then_with(|| a.line.cmp(&b.line))
            .then_with(|| a.node_id.cmp(&b.node_id))
            .then_with(|| a.module.cmp(&b.module))
    });
    rows.truncate(top);
    rows
}

fn on_path_keys(rows: &[RankRow]) -> HashSet<(String, u32)> {
    rows.iter()
        .map(|row| (row.module.clone(), row.node_id))
        .collect()
}

fn storage_rank_rows(design: &TimingDesign, area: &AreaModel) -> Vec<RankRow> {
    let mut rows = Vec::new();
    for module in design.modules.values() {
        let defaults = parameter_defaults(module);
        for decl in &module.decls {
            let Some(bits) = storage_bits(decl, &defaults) else {
                continue;
            };
            rows.push(RankRow {
                module: module.name.clone(),
                node_id: 0,
                file: decl.loc.file.clone(),
                line: decl.loc.start_line,
                exclusive_au: f64::from(bits) * area.flop,
                delay_fo4: 0.0,
                critical_contribution_fo4: 0.0,
            });
        }
    }
    rows
}

fn storage_tags(module: &TimingModule) -> Vec<String> {
    let defaults = parameter_defaults(module);
    let mut tags = Vec::new();
    let mut bits = 0u32;
    let mut unresolved = false;
    for decl in &module.decls {
        if !builtin_net(&decl.type_name) {
            tags.push("storage_width_unresolved".into());
            continue;
        }
        match storage_bits(decl, &defaults) {
            Some(width) => bits += width,
            None => unresolved = true,
        }
    }
    if unresolved {
        tags.push("storage_unrecorded".into());
    }
    if bits > 0 {
        tags.push(format!("storage_bits={bits}"));
    }
    tags
}

fn module_perf_basis(design: &TimingDesign, module: ModuleId) -> &'static str {
    let mut primary = false;
    let mut multi = false;
    let mut reg = false;
    for path in design.paths.iter().filter(|path| path.module == module) {
        if path.multi_cycle {
            multi = true;
        } else {
            primary = true;
            if path.path_kind == PathKind::RegToReg {
                reg = true;
            }
        }
    }
    if !primary && multi {
        "multicycle_only"
    } else if reg {
        "reg_to_reg"
    } else if primary {
        "primary_path"
    } else {
        "node_depth"
    }
}

fn path_area(
    node_area: &BTreeMap<(ModuleId, u32), f64>,
    path: &TimingPath,
) -> BTreeMap<(ModuleId, u32), f64> {
    path.nodes
        .iter()
        .filter_map(|id| {
            let key = (path.module, *id);
            node_area.get(&key).copied().map(|au| (key, au))
        })
        .collect()
}

fn module_selected(inclusion: &Inclusion, design: &TimingDesign, module: &TimingModule) -> bool {
    if !names_ok(inclusion, &module.name, file_name(&module.file), None) {
        return false;
    }
    if inclusion.subtrees.is_empty() {
        return true;
    }
    if inclusion.subtrees.iter().any(|name| name == &module.name) {
        return true;
    }
    design.instances.iter().any(|inst| {
        inst.child_module == Some(module.id)
            && inclusion
                .subtrees
                .iter()
                .any(|name| name == &format!("{}.{}", inst.parent_name, inst.instance_name))
    })
}

fn instance_selected(
    inclusion: &Inclusion,
    design: &TimingDesign,
    inst: &sv_timing_core::ModuleInstance,
) -> bool {
    let Some(child_id) = inst.child_module else {
        return names_ok(
            inclusion,
            &inst.child_type,
            "",
            Some(&format!("{}.{}", inst.parent_name, inst.instance_name)),
        ) && subtree_has_instance(inclusion, inst);
    };
    let Some(child) = design.modules.get(&child_id) else {
        return false;
    };
    let key = format!("{}.{}", inst.parent_name, inst.instance_name);
    names_ok(inclusion, &child.name, file_name(&child.file), Some(&key))
        && subtree_has_instance(inclusion, inst)
}

fn subtree_has_instance(inclusion: &Inclusion, inst: &sv_timing_core::ModuleInstance) -> bool {
    if inclusion.subtrees.is_empty() {
        return true;
    }
    let key = format!("{}.{}", inst.parent_name, inst.instance_name);
    inclusion
        .subtrees
        .iter()
        .any(|name| name == &key || name == &inst.child_type)
}

fn names_ok(inclusion: &Inclusion, module: &str, file: &str, instance: Option<&str>) -> bool {
    let mut keys = vec![module, file];
    if let Some(instance) = instance {
        keys.push(instance);
    }
    if !inclusion.allow.is_empty()
        && !inclusion
            .allow
            .iter()
            .any(|glob| keys.iter().any(|key| glob_match(glob, key)))
    {
        return false;
    }
    !inclusion
        .deny
        .iter()
        .any(|glob| keys.iter().any(|key| glob_match(glob, key)))
}

fn node_kept(
    inclusion: &Inclusion,
    design: &TimingDesign,
    module: &TimingModule,
    node_id: u32,
) -> bool {
    if !module_selected(inclusion, design, module) {
        return false;
    }
    if inclusion.path_classes.is_empty() && inclusion.path_kinds.is_empty() {
        return true;
    }
    design.paths.iter().any(|path| {
        path.module == module.id && path.nodes.contains(&node_id) && path_matches(inclusion, path)
    })
}

fn path_matches(inclusion: &Inclusion, path: &TimingPath) -> bool {
    (inclusion.path_classes.is_empty() || inclusion.path_classes.contains(&path.path_class))
        && (inclusion.path_kinds.is_empty() || inclusion.path_kinds.contains(&path.path_kind))
}

fn cross_paths_unresolved(design: &TimingDesign, inclusion: &Inclusion) -> u32 {
    design
        .cross_module_paths
        .iter()
        .filter(|cross| {
            match design
                .modules
                .values()
                .find(|module| module.name == cross.parent_module)
            {
                Some(parent) if !module_selected(inclusion, design, parent) => return false,
                Some(_) | None => {}
            }
            path_id_missing(design, cross.child_path_id)
                || path_id_missing(design, cross.parent_path_id)
        })
        .count() as u32
}

fn path_id_missing(design: &TimingDesign, id: Option<u32>) -> bool {
    match id {
        None => true,
        Some(id) => !design.paths.iter().any(|path| path.id == id),
    }
}

fn inclusive_delay(
    id: ModuleId,
    design: &TimingDesign,
    inclusion: &Inclusion,
    memo: &mut BTreeMap<ModuleId, f64>,
    stack: &mut Vec<ModuleId>,
) -> f64 {
    if let Some(delay) = memo.get(&id) {
        return *delay;
    }
    let own = module_delay(design, id);
    if stack.contains(&id) {
        return own;
    }
    stack.push(id);
    let mut total = own;
    for inst in design
        .instances
        .iter()
        .filter(|inst| inst.parent_module == id)
    {
        if inst.param_override_present != Some(false) || !instance_selected(inclusion, design, inst)
        {
            continue;
        }
        let Some(parent) = design.modules.get(&id) else {
            continue;
        };
        if !module_selected(inclusion, design, parent) {
            continue;
        }
        let Some(child) = inst.child_module else {
            continue;
        };
        total = total.max(inclusive_delay(child, design, inclusion, memo, stack));
    }
    stack.pop();
    memo.insert(id, total);
    total
}

fn module_delay(design: &TimingDesign, module: ModuleId) -> f64 {
    design
        .paths
        .iter()
        .filter(|path| path.module == module && !path.multi_cycle)
        .map(|path| path.total_fo4)
        .fold(0.0, f64::max)
}

fn module_overlay_selected(
    design: &TimingDesign,
    module: &TimingModule,
    params: &ParamMap,
    inclusion: &Inclusion,
) -> bool {
    inclusion.config.keys().any(|key| {
        module.nodes.values().any(|node| {
            let seed = seed_for(design, module, node);
            expr_selects(node.rhs_expr.as_ref(), key, &seed, params)
        })
    })
}

fn failed_overlays(design: &TimingDesign, params: &ParamMap, inclusion: &Inclusion) -> u32 {
    inclusion
        .config
        .keys()
        .filter(|key| !overlay_hits(design, params, key))
        .count() as u32
}

fn overlay_hits(design: &TimingDesign, params: &ParamMap, key: &str) -> bool {
    for module in design.modules.values() {
        for node in module.nodes.values() {
            let seed = seed_for(design, module, node);
            if expr_selects(node.rhs_expr.as_ref(), key, &seed, params) {
                return true;
            }
        }
    }
    false
}

fn expr_selects(expr: Option<&Expr>, key: &str, seed: &ConstSeed, params: &ParamMap) -> bool {
    let Some(expr) = expr else {
        return false;
    };
    match expr {
        Expr::Ternary {
            cond,
            then_e,
            else_e,
        } => {
            let selected = matches!(cond.as_ref(), Expr::Ident { name } if name == key)
                && cond.const_class(seed).is_const()
                && resolved_condition(cond, params).is_some();
            selected
                || expr_selects(Some(cond), key, seed, params)
                || expr_selects(Some(then_e), key, seed, params)
                || expr_selects(Some(else_e), key, seed, params)
        }
        Expr::Unary { arg, .. } => expr_selects(Some(arg), key, seed, params),
        Expr::Binary { left, right, .. }
        | Expr::Index {
            base: left,
            index: right,
        } => {
            expr_selects(Some(left), key, seed, params)
                || expr_selects(Some(right), key, seed, params)
        }
        Expr::PartSelect { left, right, .. } => {
            expr_selects(Some(left), key, seed, params)
                || expr_selects(Some(right), key, seed, params)
        }
        Expr::Concat { parts } => parts
            .iter()
            .any(|part| expr_selects(Some(part), key, seed, params)),
        Expr::Replicate { count, body } => {
            expr_selects(Some(count), key, seed, params)
                || expr_selects(Some(body), key, seed, params)
        }
        Expr::Call { args, .. } => args
            .iter()
            .any(|arg| expr_selects(Some(arg), key, seed, params)),
        Expr::Ident { .. } | Expr::Literal { .. } | Expr::Opaque { .. } => false,
    }
}

fn function_body_areas(
    design: &TimingDesign,
    module: &TimingModule,
    area: &AreaModel,
    params: &ParamMap,
) -> BTreeMap<String, f64> {
    let empty = BTreeMap::new();
    let mut map = BTreeMap::new();
    let package_bodies = design
        .packages
        .values()
        .flat_map(|pkg| pkg.function_bodies.iter());
    for body in module.function_bodies.iter().chain(package_bodies) {
        if body.return_expr.is_empty() {
            continue;
        }
        let defaults: BTreeMap<String, i64> = body.constants.iter().cloned().collect();
        let width = bit_width(&body.return_dimension, &defaults).unwrap_or(OPERATOR_WIDTH);
        let expr = Expr::parse(&body.return_expr);
        let seed = ConstSeed::heuristic();
        let walked = expr_area(&expr, area, params, &seed, width, &empty);
        map.insert(body.name.clone(), walked.point);
    }
    map
}

fn parameter_defaults(module: &TimingModule) -> BTreeMap<String, i64> {
    let mut defaults = BTreeMap::new();
    for param in &module.parameters {
        if let Some(text) = &param.default_text {
            if let Ok(value) = text.parse::<i64>() {
                defaults.insert(param.name.clone(), value);
            }
        }
    }
    defaults
}

fn signal_widths(module: &TimingModule, defaults: &BTreeMap<String, i64>) -> BTreeMap<String, u32> {
    let mut widths = BTreeMap::new();
    for port in &module.ports {
        let Some(type_name) = &port.type_name else {
            continue;
        };
        if !builtin_net(type_name) {
            continue;
        }
        let Some(text) = &port.dimension_text else {
            widths.insert(port.name.clone(), 1);
            continue;
        };
        if let Some(width) = bit_width(text, defaults) {
            widths.insert(port.name.clone(), width);
        }
    }
    for decl in &module.decls {
        if !builtin_net(&decl.type_name) {
            continue;
        }
        if let Some(width) = bit_width(&decl.packed_text, defaults) {
            widths.insert(decl.name.clone(), width);
        }
    }
    widths
}

fn expr_signal_width(expr: &Expr, widths: &BTreeMap<String, u32>) -> Option<u32> {
    let mut found = None;
    fn walk(expr: &Expr, widths: &BTreeMap<String, u32>, found: &mut Option<u32>) {
        if let Expr::Ident { name } = expr {
            if let Some(width) = widths.get(name) {
                *found = Some(found.unwrap_or(0).max(*width));
            }
        }
        match expr {
            Expr::Unary { arg, .. } => walk(arg, widths, found),
            Expr::Binary { left, right, .. }
            | Expr::Index {
                base: left,
                index: right,
            } => {
                walk(left, widths, found);
                walk(right, widths, found);
            }
            Expr::PartSelect { left, right, .. } => {
                walk(left, widths, found);
                walk(right, widths, found);
            }
            Expr::Ternary {
                cond,
                then_e,
                else_e,
            } => {
                walk(cond, widths, found);
                walk(then_e, widths, found);
                walk(else_e, widths, found);
            }
            Expr::Concat { parts } => {
                for part in parts {
                    walk(part, widths, found);
                }
            }
            Expr::Replicate { count, body } => {
                walk(count, widths, found);
                walk(body, widths, found);
            }
            Expr::Call { args, .. } => {
                for arg in args {
                    walk(arg, widths, found);
                }
            }
            Expr::Ident { .. } | Expr::Literal { .. } | Expr::Opaque { .. } => {}
        }
    }
    walk(expr, widths, &mut found);
    found
}

fn storage_area(module: &TimingModule, area: &AreaModel, defaults: &BTreeMap<String, i64>) -> f64 {
    let mut total = 0.0;
    for decl in &module.decls {
        if let Some(bits) = storage_bits(decl, defaults) {
            total += f64::from(bits) * area.flop;
        }
    }
    total
}

fn unresolved_storage(module: &TimingModule, defaults: &BTreeMap<String, i64>) -> u32 {
    module
        .decls
        .iter()
        .filter(|decl| storage_bits(decl, defaults).is_none())
        .count() as u32
}

fn storage_bits(decl: &sv_timing_core::DeclSite, defaults: &BTreeMap<String, i64>) -> Option<u32> {
    if !builtin_net(&decl.type_name) {
        return None;
    }
    let packed = bit_width(&decl.packed_text, defaults)?;
    let unpacked = bit_width(&decl.unpacked_text, defaults)?;
    packed.checked_mul(unpacked)
}

fn seed_for(design: &TimingDesign, module: &TimingModule, node: &IrNode) -> ConstSeed {
    let mut seed = ConstSeed::from_names(design.elaboration_const_names(module));
    extend_seed_auto_const(module, &mut seed);
    let b = node.loc.byte_start;
    for gen in &module.gen_loops {
        if gen.loc.byte_end > gen.loc.byte_start && b >= gen.loc.byte_start && b < gen.loc.byte_end
        {
            seed.add(gen.genvar.clone());
        }
    }
    seed
}

struct Walked {
    point: f64,
    operators: u32,
    unlowered_calls: u32,
    root_class: Option<OperatorClass>,
}

fn node_expr_area(
    node: &IrNode,
    area: &AreaModel,
    params: &ParamMap,
    seed: &ConstSeed,
    width: u32,
    bodies: &BTreeMap<String, f64>,
) -> Walked {
    if let Some(expr) = &node.rhs_expr {
        let walked = expr_area(expr, area, params, seed, width, bodies);
        return Walked {
            point: walked.point,
            operators: walked.operators,
            unlowered_calls: walked.unlowered_calls,
            root_class: walked.root_class,
        };
    }
    if let Some(class) = node.op_class {
        return Walked {
            point: area.operator_area(class, width),
            operators: 1,
            unlowered_calls: 0,
            root_class: Some(class),
        };
    }
    Walked {
        point: 0.0,
        operators: 0,
        unlowered_calls: 0,
        root_class: None,
    }
}

struct ExprWalk {
    point: f64,
    lo: f64,
    hi: f64,
    upper: bool,
    operators: u32,
    unlowered_calls: u32,
    root_class: Option<OperatorClass>,
}

fn expr_zero() -> ExprWalk {
    ExprWalk {
        point: 0.0,
        lo: 0.0,
        hi: 0.0,
        upper: false,
        operators: 0,
        unlowered_calls: 0,
        root_class: None,
    }
}

fn expr_area(
    expr: &Expr,
    area: &AreaModel,
    params: &ParamMap,
    seed: &ConstSeed,
    width: u32,
    bodies: &BTreeMap<String, f64>,
) -> ExprWalk {
    if expr.const_class(seed).is_const() && !is_unknown_const_ternary(expr, seed, params) {
        return expr_zero();
    }
    match expr {
        Expr::Ident { .. } | Expr::Literal { .. } | Expr::Opaque { .. } => expr_zero(),
        Expr::Unary { op, arg } => {
            let child = expr_area(arg, area, params, seed, width, bodies);
            let class = classify_unary(op);
            add_base(child, area.operator_area(class, width), Some(class))
        }
        Expr::Binary {
            op,
            op_class,
            left,
            right,
        } => {
            let class = billed_binary_class(op, *op_class, left, right, seed);
            let l = expr_area(left, area, params, seed, width, bodies);
            let r = expr_area(right, area, params, seed, width, bodies);
            add_base(
                add_walk(l, r),
                area.operator_area(class, width),
                Some(class),
            )
        }
        Expr::Ternary {
            cond,
            then_e,
            else_e,
        } => {
            if cond.const_class(seed).is_const() {
                if let Some(live_then) = resolved_condition(cond, params) {
                    let live = if live_then { then_e } else { else_e };
                    return expr_area(live, area, params, seed, width, bodies);
                }
                let then_w = expr_area(then_e, area, params, seed, width, bodies);
                let else_w = expr_area(else_e, area, params, seed, width, bodies);
                return ExprWalk {
                    point: then_w.point.max(else_w.point),
                    lo: then_w.lo.min(else_w.lo),
                    hi: then_w.hi.max(else_w.hi),
                    upper: true,
                    operators: then_w.operators.max(else_w.operators),
                    unlowered_calls: then_w.unlowered_calls.max(else_w.unlowered_calls),
                    root_class: None,
                };
            }
            let c = expr_area(cond, area, params, seed, width, bodies);
            let t = expr_area(then_e, area, params, seed, width, bodies);
            let e = expr_area(else_e, area, params, seed, width, bodies);
            add_base(
                add_walk(add_walk(c, t), e),
                area.operator_area(OperatorClass::Mux, width),
                Some(OperatorClass::Mux),
            )
        }
        Expr::Concat { parts } => {
            let mut acc = expr_zero();
            for part in parts {
                acc = add_walk(acc, expr_area(part, area, params, seed, width, bodies));
            }
            add_base(
                acc,
                area.operator_area(OperatorClass::Concat, width),
                Some(OperatorClass::Concat),
            )
        }
        Expr::Replicate { count, body } => {
            let body_w = expr_area(body, area, params, seed, width, bodies);
            let copies = literal_u32(count).unwrap_or(1);
            scale_walk(body_w, f64::from(copies))
        }
        Expr::Index { base, index }
        | Expr::PartSelect {
            left: base,
            right: index,
            ..
        } => add_walk(
            expr_area(base, area, params, seed, width, bodies),
            expr_area(index, area, params, seed, width, bodies),
        ),
        Expr::Call { name, args } => {
            let mut acc = expr_zero();
            for arg in args {
                acc = add_walk(acc, expr_area(arg, area, params, seed, width, bodies));
            }
            if let Some(body) = bodies.get(name.as_str()) {
                acc.point += *body;
                acc.lo += *body;
                acc.hi += *body;
                acc
            } else {
                let class = user_function_op_class(name, args.len());
                let mut walked = add_base(acc, area.operator_area(class, width), Some(class));
                walked.unlowered_calls += 1;
                walked
            }
        }
    }
}

fn is_unknown_const_ternary(expr: &Expr, seed: &ConstSeed, params: &ParamMap) -> bool {
    let Expr::Ternary { cond, .. } = expr else {
        return false;
    };
    cond.const_class(seed).is_const() && resolved_condition(cond, params).is_none()
}

fn resolved_condition(cond: &Expr, params: &ParamMap) -> Option<bool> {
    match cond {
        Expr::Ident { name } => match params.get_u32(name) {
            Some(0) => Some(false),
            Some(1) => Some(true),
            _ => None,
        },
        Expr::Literal { text } => literal_bit(text),
        _ => None,
    }
}

fn literal_bit(text: &str) -> Option<bool> {
    let t = text.trim();
    if t == "0" || t.ends_with("'b0") || t.ends_with("'d0") {
        Some(false)
    } else if t == "1" || t.ends_with("'b1") || t.ends_with("'d1") {
        Some(true)
    } else {
        None
    }
}

fn literal_u32(expr: &Expr) -> Option<u32> {
    let Expr::Literal { text } = expr else {
        return None;
    };
    text.trim().parse().ok()
}

fn add_walk(a: ExprWalk, b: ExprWalk) -> ExprWalk {
    ExprWalk {
        point: a.point + b.point,
        lo: a.lo + b.lo,
        hi: a.hi + b.hi,
        upper: a.upper || b.upper,
        operators: a.operators + b.operators,
        unlowered_calls: a.unlowered_calls + b.unlowered_calls,
        root_class: a.root_class.or(b.root_class),
    }
}

fn add_base(mut walk: ExprWalk, base: f64, class: Option<OperatorClass>) -> ExprWalk {
    walk.point += base;
    walk.lo += base;
    walk.hi += base;
    walk.operators += 1;
    walk.root_class = class;
    walk
}

fn scale_walk(mut walk: ExprWalk, copies: f64) -> ExprWalk {
    walk.point *= copies;
    walk.lo *= copies;
    walk.hi *= copies;
    walk.operators = ((walk.operators as f64) * copies) as u32;
    walk
}

fn ceil_log2(n: u32) -> u32 {
    let mut v = 0u32;
    let mut x = 1u32;
    while x < n {
        x <<= 1;
        v += 1;
        if x == 0 {
            break;
        }
    }
    v
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;
    use sv_timing_core::{
        analyze_files, AssignKind, CrossModulePath, GenerateLoop, LowerOptions, ModuleInstance,
        ParseOptions, PathEndpoint, SourceLoc, TimingTarget,
    };

    fn loc() -> SourceLoc {
        SourceLoc::file_start("t.sv")
    }

    fn node(id: u32, expr: Expr) -> IrNode {
        IrNode {
            id,
            op_class: None,
            width: 1,
            fo4_cost: 3.0,
            gate: None,
            loc: loc(),
            fans_in: Vec::new(),
            fans_out: Vec::new(),
            width_defaulted: true,
            reads_reg: false,
            lhs: None,
            rhs: None,
            rhs_expr: Some(expr),
            lhs_expr: None,
            case_labels: Vec::new(),
            case_is_default: false,
            case_selector: None,
            fo4_locked: false,
            assign_kind: AssignKind::Blocking,
        }
    }

    fn seed_empty() -> ConstSeed {
        ConstSeed::from_names(["EN"])
    }

    #[test]
    fn const_arm_keeps_live_side_only() {
        let area = crate::default_area_v1_embedded();
        let expr = Expr::Ternary {
            cond: Box::new(Expr::Ident { name: "EN".into() }),
            then_e: Box::new(Expr::Binary {
                op: "+".into(),
                op_class: OperatorClass::AddSub,
                left: Box::new(Expr::Ident { name: "a".into() }),
                right: Box::new(Expr::Ident { name: "b".into() }),
            }),
            else_e: Box::new(Expr::Binary {
                op: "*".into(),
                op_class: OperatorClass::Mul,
                left: Box::new(Expr::Ident { name: "a".into() }),
                right: Box::new(Expr::Ident { name: "b".into() }),
            }),
        };
        let mut params = ParamMap::new();
        params.insert("EN", serde_json::json!(1));
        let seed = seed_empty();
        let live = expr_area(&expr, &area, &params, &seed, 1, &BTreeMap::new());
        assert_eq!(live.root_class, Some(OperatorClass::AddSub));
        params.insert("EN", serde_json::json!(0));
        let dead = expr_area(&expr, &area, &params, &seed, 1, &BTreeMap::new());
        assert_eq!(dead.root_class, Some(OperatorClass::Mul));
    }

    fn expr_arm_then(expr: &Expr) -> &Expr {
        match expr {
            Expr::Ternary { then_e, .. } => then_e,
            _ => unreachable!(),
        }
    }

    fn expr_arm_else(expr: &Expr) -> &Expr {
        match expr {
            Expr::Ternary { else_e, .. } => else_e,
            _ => unreachable!(),
        }
    }

    #[test]
    fn unknown_const_uses_upper_arm() {
        let area = crate::default_area_v1_embedded();
        let expr = Expr::Ternary {
            cond: Box::new(Expr::Ident { name: "EN".into() }),
            then_e: Box::new(Expr::Binary {
                op: "&".into(),
                op_class: OperatorClass::LogicBit,
                left: Box::new(Expr::Ident { name: "a".into() }),
                right: Box::new(Expr::Ident { name: "b".into() }),
            }),
            else_e: Box::new(Expr::Binary {
                op: "+".into(),
                op_class: OperatorClass::AddSub,
                left: Box::new(Expr::Ident { name: "a".into() }),
                right: Box::new(Expr::Ident { name: "b".into() }),
            }),
        };
        let params = ParamMap::new();
        let walked = expr_area(&expr, &area, &params, &seed_empty(), 1, &BTreeMap::new());
        let then_point = expr_area(
            expr_arm_then(&expr),
            &area,
            &params,
            &seed_empty(),
            1,
            &BTreeMap::new(),
        )
        .point;
        let else_point = expr_area(
            expr_arm_else(&expr),
            &area,
            &params,
            &seed_empty(),
            1,
            &BTreeMap::new(),
        )
        .point;
        assert!(walked.upper);
        assert_eq!(walked.point, then_point.max(else_point));
        assert_eq!(walked.lo, then_point.min(else_point));
    }

    #[test]
    fn rule2_child_is_not_also_a_root() {
        let area = crate::default_area_v1_embedded();
        let mut design = TimingDesign::empty(TimingTarget::new(1000.0, 20.0, 0.2));
        design.modules.insert(0, empty_module(0, "parent"));
        design.modules.insert(1, empty_module(1, "child"));
        design.module_names.insert("parent".into(), 0);
        design.module_names.insert("child".into(), 1);
        design.modules.get_mut(&0).unwrap().nodes.insert(
            1,
            node(
                1,
                Expr::Binary {
                    op: "+".into(),
                    op_class: OperatorClass::AddSub,
                    left: Box::new(Expr::Ident { name: "a".into() }),
                    right: Box::new(Expr::Ident { name: "b".into() }),
                },
            ),
        );
        design.instances.push(ModuleInstance {
            parent_module: 0,
            parent_name: "parent".into(),
            instance_name: "u_child".into(),
            child_type: "child".into(),
            child_module: Some(1),
            connections: Vec::new(),
            loc: loc(),
            param_override_present: Some(false),
        });
        let report = attribute(&design, &area, &ParamMap::new());
        let parent = report.modules.iter().find(|m| m.name == "parent").unwrap();
        let child = report.modules.iter().find(|m| m.name == "child").unwrap();
        assert_eq!(parent.role, "root");
        assert_eq!(child.role, "child");
        assert!(parent.inclusive_au >= parent.exclusive_au);
        assert!(!report.field_absent);
    }

    #[test]
    fn child_percent_is_its_share_of_the_parent() {
        let area = crate::default_area_v1_embedded();
        let mut design = TimingDesign::empty(TimingTarget::new(1000.0, 20.0, 0.2));
        let mut parent = empty_module(0, "parent");
        parent.nodes.insert(1, node(1, add_expr()));
        let mut child = empty_module(1, "child");
        child.nodes.insert(2, node(2, add_expr()));
        design.modules.insert(0, parent);
        design.modules.insert(1, child);
        design.module_names.insert("parent".into(), 0);
        design.module_names.insert("child".into(), 1);
        design
            .instances
            .push(instance(0, "u_child", 1, Some(false)));
        design
            .paths
            .push(sample_path(1, PathKind::RegToReg, vec![1], 4.0, false));
        design
            .paths
            .push(sample_path(2, PathKind::RegToReg, vec![2], 12.0, false));
        design.paths[1].module = 1;
        let report = attribute(&design, &area, &ParamMap::new());
        let value = crate::report_json(&report, &design, &area, "", "");
        let tree = value["tree"].as_array().unwrap();
        let parent = tree.iter().find(|row| row["name"] == "parent").unwrap();
        assert!(parent["parent_percent"].is_null());
        assert_eq!(parent["exclusive_delay_fo4"], 4.0);
        assert_eq!(parent["inclusive_delay_fo4"], 12.0);
        let nested = parent["children"].as_array().unwrap();
        assert_eq!(nested.len(), 1);
        assert_eq!(nested[0]["instance"], "u_child");
        assert_eq!(nested[0]["name"], "child");
        assert_eq!(nested[0]["exclusive_delay_fo4"], 12.0);
        let parent_au = parent["inclusive_au"].as_f64().unwrap();
        let child_au = nested[0]["inclusive_au"].as_f64().unwrap();
        assert!(parent_au > child_au && child_au > 0.0);
        let percent = nested[0]["parent_percent"].as_f64().unwrap();
        assert!((percent - 100.0 * child_au / parent_au).abs() < 1e-9);
        let empty = TimingDesign::empty(TimingTarget::new(1000.0, 20.0, 0.2));
        let mut bare = empty;
        bare.modules.insert(0, empty_module(0, "parent"));
        bare.modules.insert(1, empty_module(1, "child"));
        bare.module_names.insert("parent".into(), 0);
        bare.module_names.insert("child".into(), 1);
        bare.instances.push(instance(0, "u_child", 1, Some(false)));
        let zero = attribute(&bare, &area, &ParamMap::new());
        let zero_json = crate::report_json(&zero, &bare, &area, "", "");
        let zero_parent = zero_json["tree"]
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["name"] == "parent")
            .unwrap();
        assert!(zero_parent["children"][0]["parent_percent"].is_null());
    }

    #[test]
    fn hash_override_is_unbound_and_absent_is_not_false() {
        let area = crate::default_area_v1_embedded();
        let mut design = TimingDesign::empty(TimingTarget::new(1000.0, 20.0, 0.2));
        design.modules.insert(0, empty_module(0, "parent"));
        design.modules.insert(1, empty_module(1, "leaf"));
        design.module_names.insert("parent".into(), 0);
        design.module_names.insert("leaf".into(), 1);
        design.instances.push(instance(0, "u_hash", 1, Some(true)));
        design.instances.push(instance(0, "u_old", 1, None));
        let report = attribute(&design, &area, &ParamMap::new());
        let parent = report.modules.iter().find(|m| m.name == "parent").unwrap();
        let leaf = report.modules.iter().find(|m| m.name == "leaf").unwrap();
        assert_eq!(leaf.role, "unbound");
        assert!(parent
            .tags
            .iter()
            .any(|t| t == "instance_params=unrecorded"));
        assert!(parent
            .tags
            .iter()
            .any(|t| t == "instance_params=field_absent"));
        assert!(report.field_absent);
        assert_eq!(report.n_instance_params_unrecorded, 1);
        assert_eq!(report.n_field_absent, 1);
        assert_eq!(report.attribution_gaps(), 1);
        assert_eq!(parent.inclusive_au, parent.exclusive_au);
    }

    #[test]
    fn strict_gaps_count_missing_path_ids_and_not_loops() {
        let area = crate::default_area_v1_embedded();
        let mut design = TimingDesign::empty(TimingTarget::new(1000.0, 20.0, 0.2));
        let mut parent = empty_module(0, "parent");
        parent.gen_loops.push(GenerateLoop {
            genvar: "i".into(),
            bound_hint: None,
            label: None,
            loc: loc(),
            body_assign_count: 1,
        });
        parent.nodes.insert(1, node(1, add_expr()));
        design.modules.insert(0, parent);
        design.module_names.insert("parent".into(), 0);
        design
            .paths
            .push(sample_path(7, PathKind::RegToReg, vec![1], 4.0, false));
        design.cross_module_paths.push(cross_path(0, None, None));
        design
            .cross_module_paths
            .push(cross_path(1, Some(7), Some(7)));
        design
            .cross_module_paths
            .push(cross_path(2, Some(99), Some(7)));
        let report = attribute(&design, &area, &ParamMap::new());
        assert_eq!(report.n_generate_unresolved, 1);
        assert_eq!(report.n_cross_path_unresolved, 2);
        assert_eq!(report.n_instance_params_unrecorded, 0);
        assert_eq!(report.n_field_absent, 0);
        assert_eq!(report.attribution_gaps(), 2);
        let value = crate::report_json(&report, &design, &area, "", "");
        assert_eq!(value["gaps"]["n_cross_path_unresolved"], 2);
        assert_eq!(value["gaps"]["n_field_absent"], 0);
        assert_eq!(value["gaps"]["attribution_gaps"], 2);
        assert_eq!(value["gaps"]["n_generate_unresolved"], 1);
    }

    #[test]
    fn exclusive_case_fixture_counts_arms_once() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures/exclusive_case_mux.sv");
        let parsed = analyze_files(
            &[fixture],
            &ParseOptions::default(),
            &LowerOptions::default(),
        )
        .expect("lower fixture");
        let before: Vec<f64> = parsed.design.paths.iter().map(|p| p.total_fo4).collect();
        let area = crate::default_area_v1_embedded();
        let report = attribute(&parsed.design, &area, &ParamMap::new());
        let after: Vec<f64> = parsed.design.paths.iter().map(|p| p.total_fo4).collect();
        assert_eq!(before, after);
        let group = report
            .case_groups
            .iter()
            .find(|g| g.n_arms == 6)
            .expect("six-arm case");
        assert_eq!(group.width_bits, 64);
        assert_eq!(
            group.surcharge_au,
            area.mux * f64::from(group.width_bits) * f64::from(ceil_log2(6))
        );
        let adds = group
            .arm_classes
            .iter()
            .filter(|c| **c == OperatorClass::AddSub)
            .count();
        let logics = group
            .arm_classes
            .iter()
            .filter(|c| **c == OperatorClass::LogicBit)
            .count();
        assert_eq!(adds, 2);
        assert_eq!(logics, 3);
        let capped = attribute_with(
            &parsed.design,
            &area,
            &ParamMap::new(),
            &Inclusion::all(),
            1,
        )
        .unwrap();
        assert_eq!(capped.top, 1);
        assert!(capped.rank_exclusive_area.len() <= 1);
        let value = crate::report_json(&capped, &parsed.design, &area, "", "");
        assert!(value["tree"].as_array().unwrap().len() <= 1);
        assert!(value["rank_exclusive_area"].as_array().unwrap().len() <= 1);
    }

    #[test]
    fn packed_bank_is_48_by_64_and_user_type_stays_unresolved() {
        let fixture =
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/packed_bank.sv");
        let parsed = analyze_files(
            &[fixture.clone()],
            &ParseOptions::default(),
            &LowerOptions::default(),
        )
        .expect("lower bank");
        let module = parsed
            .design
            .modules
            .values()
            .find(|module| module.name == "packed_bank")
            .expect("module");
        let depth = module
            .parameters
            .iter()
            .find(|param| param.name == "DEPTH")
            .expect("DEPTH");
        let width = module
            .parameters
            .iter()
            .find(|param| param.name == "WIDTH")
            .expect("WIDTH");
        assert_eq!(depth.default_text.as_deref(), Some("48"));
        assert_eq!(width.default_text.as_deref(), Some("64"));
        let mem = module
            .decls
            .iter()
            .find(|decl| decl.name == "mem")
            .expect("mem");
        assert_eq!(mem.packed_text.replace(' ', ""), "[DEPTH-1:0][WIDTH-1:0]");
        let names: Vec<(&str, &str, &str)> = module
            .decls
            .iter()
            .map(|decl| {
                (
                    decl.name.as_str(),
                    decl.type_name.as_str(),
                    decl.packed_text.as_str(),
                )
            })
            .collect();
        let flop = module
            .decls
            .iter()
            .find(|decl| decl.name == "flop_q")
            .unwrap_or_else(|| {
                let instances: Vec<(&str, &str)> = module
                    .instances
                    .iter()
                    .map(|inst| (inst.instance_name.as_str(), inst.child_type.as_str()))
                    .collect();
                panic!("decls {names:?} instances {instances:?}")
            });
        assert_eq!(flop.type_name, "slot_t");
        let area = crate::default_area_v1_embedded();
        let report = attribute(&parsed.design, &area, &ParamMap::new());
        let row = report
            .modules
            .iter()
            .find(|row| row.name == "packed_bank")
            .unwrap();
        let bits = 48u32 * 64;
        assert_eq!(
            row.exclusive_au,
            f64::from(bits) * area.flop,
            "type {} packed {:?} unresolved {}",
            mem.type_name,
            mem.packed_text,
            report.n_storage_unrecorded
        );
        assert_eq!(report.n_storage_unrecorded, 1);
    }

    #[test]
    fn package_function_body_adds_area_and_leaves_delay() {
        let root =
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/cva6_style");
        let parse = ParseOptions {
            include_paths: vec![root.clone()],
            ..ParseOptions::default()
        };
        let parsed = analyze_files(
            &[
                root.join("cva6_style_pkg.sv"),
                root.join("cva6_style_unit.sv"),
            ],
            &parse,
            &LowerOptions::default(),
        )
        .expect("lower cva6_style");
        let package = parsed
            .design
            .packages
            .get("cva6_style_pkg")
            .expect("package");
        let add = package
            .function_bodies
            .iter()
            .find(|body| body.name == "pkg_add")
            .expect("pkg_add");
        assert_eq!(add.return_expr.replace(' ', ""), "a+b");
        assert_eq!(add.return_dimension, "[PKG_WIDTH-1:0]");
        assert!(add
            .constants
            .iter()
            .any(|(name, value)| name == "PKG_WIDTH" && *value == 16));
        let mux = package
            .function_bodies
            .iter()
            .find(|body| body.name == "pkg_mux")
            .expect("pkg_mux");
        assert!(mux.return_expr.contains('?'));
        let before: Vec<f64> = parsed
            .design
            .paths
            .iter()
            .map(|path| path.total_fo4)
            .collect();
        let area = crate::default_area_v1_embedded();
        let with = attribute(&parsed.design, &area, &ParamMap::new());
        let mut cleared = parsed.design.clone();
        for package in cleared.packages.values_mut() {
            package.function_bodies.clear();
        }
        let without = attribute(&cleared, &area, &ParamMap::new());
        let with_au = with
            .modules
            .iter()
            .find(|row| row.name == "cva6_style_unit")
            .unwrap()
            .exclusive_au;
        let without_au = without
            .modules
            .iter()
            .find(|row| row.name == "cva6_style_unit")
            .unwrap()
            .exclusive_au;
        let width = 16.0;
        let expected = without_au + width * (area.add_sub + area.mux - 2.0 * area.other);
        assert!(
            (with_au - expected).abs() < 1e-6,
            "with {with_au} without {without_au} expected {expected}"
        );
        let after: Vec<f64> = parsed
            .design
            .paths
            .iter()
            .map(|path| path.total_fo4)
            .collect();
        assert_eq!(before, after);
    }

    #[test]
    fn procedural_if_stays_config_unresolved() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures/procedural_if.sv");
        let parsed = analyze_files(
            &[fixture],
            &ParseOptions::default(),
            &LowerOptions::default(),
        )
        .expect("lower procedural_if");
        let before: Vec<f64> = parsed
            .design
            .paths
            .iter()
            .map(|path| path.total_fo4)
            .collect();
        let procedural = parsed
            .design
            .modules
            .values()
            .find(|module| module.name == "procedural_if")
            .expect("procedural_if");
        let generated = parsed
            .design
            .modules
            .values()
            .find(|module| module.name == "gen_if")
            .expect("gen_if");
        assert!(procedural.config_branch);
        assert!(generated.config_branch);
        let mut params = ParamMap::new();
        params.insert("EN", serde_json::json!(1));
        let area = crate::default_area_v1_embedded();
        let report = attribute(&parsed.design, &area, &params);
        let after: Vec<f64> = parsed
            .design
            .paths
            .iter()
            .map(|path| path.total_fo4)
            .collect();
        assert_eq!(before, after);
        assert_eq!(report.n_config_unresolved, 0);
        for name in ["procedural_if", "gen_if"] {
            let row = report.modules.iter().find(|row| row.name == name).unwrap();
            assert!(
                row.tags.iter().any(|tag| tag == "config_unresolved"),
                "{name}"
            );
        }
        let ops: Vec<&str> = procedural
            .nodes
            .values()
            .filter_map(|node| match node.rhs_expr.as_ref() {
                Some(Expr::Binary { op, .. }) => Some(op.as_str()),
                _ => None,
            })
            .collect();
        assert!(ops.contains(&"+"), "{ops:?}");
        assert!(ops.contains(&"-"), "{ops:?}");
    }

    #[test]
    fn function_return_width_ignores_argument_ranges() {
        let fixture = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures/fn_return_width.sv");
        let mut lower = LowerOptions::default();
        lower.package_mode = true;
        let parsed = analyze_files(&[fixture], &ParseOptions::default(), &lower).expect("lower");
        let body = parsed
            .design
            .packages
            .values()
            .flat_map(|pkg| pkg.function_bodies.iter())
            .find(|body| body.name == "line_base")
            .expect("line_base");
        assert_eq!(body.return_dimension, "[63:0]");
        assert_eq!(body.return_expr.replace(' ', ""), "base<<sh");
        let area = crate::default_area_v1_embedded();
        let report = attribute(&parsed.design, &area, &ParamMap::new());
        let row = report
            .modules
            .iter()
            .find(|row| row.name == "inv_adapter")
            .unwrap();
        assert_eq!(row.exclusive_au, f64::from(64) * area.shift_var);
    }

    #[test]
    fn metric_orders_area_then_name() {
        let mut rows = vec![
            module_row("b", 1.0, 9.0),
            module_row("a", 4.0, 1.0),
            module_row("c", 0.0, 3.0),
        ];
        order_module_rows(&mut rows, "area", Some(100.0)).unwrap();
        assert_eq!(rows[0].name, "a");
        assert_eq!(rows[1].name, "b");
        order_module_rows(&mut rows, "perf", Some(100.0)).unwrap();
        assert_eq!(rows[0].name, "b");
        order_module_rows(&mut rows, "perf-per-area", Some(100.0)).unwrap();
        assert_eq!(rows[0].name, "a");
        assert_eq!(rows.last().unwrap().name, "c");
        assert!(order_module_rows(&mut rows, "latency", None).is_err());
    }

    #[test]
    fn bank_area_dominates_off_the_adder_path() {
        let fixture =
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/area_rank.sv");
        let parsed = analyze_files(
            &[fixture],
            &ParseOptions::default(),
            &LowerOptions::default(),
        )
        .expect("lower area_rank");
        let area = crate::default_area_v1_embedded();
        let report = attribute(&parsed.design, &area, &ParamMap::new());
        let bits = 32u32 * 64;
        let bank_au = f64::from(bits) * area.flop;
        let bank = report
            .rank_exclusive_area
            .iter()
            .find(|row| row.delay_fo4 == 0.0 && row.exclusive_au == bank_au)
            .expect("storage row");
        let hottest_node = report
            .rank_exclusive_area
            .iter()
            .filter(|row| row.delay_fo4 > 0.0)
            .map(|row| row.exclusive_au)
            .fold(0.0, f64::max);
        assert!(bank.exclusive_au > hottest_node);
        assert_eq!(bank.critical_contribution_fo4, 0.0);
        let row = report
            .modules
            .iter()
            .find(|row| row.name == "area_rank")
            .expect("module row");
        assert!(row.tags.iter().any(|tag| tag == "storage_bits=2048"));
        assert_eq!(row.perf_basis, "reg_to_reg");
        let value = crate::report_json(&report, &parsed.design, &area, "", "");
        let ranked = value["rank_exclusive_area"].as_array().expect("rank");
        let json_bank = ranked
            .iter()
            .find(|row| row["exclusive_au"].as_f64() == Some(bank_au))
            .expect("json storage row");
        assert_eq!(json_bank["critical_contribution_fo4"], 0.0);
        assert!(value["path_classes"].is_array());
    }

    #[test]
    fn multicycle_only_has_no_primary_mhz() {
        let area = crate::default_area_v1_embedded();
        let mut design = TimingDesign::empty(TimingTarget::new(1000.0, 20.0, 0.2));
        let mut module = empty_module(0, "serdiv");
        module.nodes.insert(
            1,
            node(
                1,
                Expr::Binary {
                    op: "+".into(),
                    op_class: OperatorClass::AddSub,
                    left: Box::new(Expr::Ident { name: "a".into() }),
                    right: Box::new(Expr::Ident { name: "b".into() }),
                },
            ),
        );
        design.modules.insert(0, module);
        design.module_names.insert("serdiv".into(), 0);
        design.paths.push(TimingPath {
            id: 0,
            region_id: 0,
            module: 0,
            start: PathEndpoint::RegClock { cell: 0 },
            end: PathEndpoint::RegData { cell: 1 },
            path_kind: PathKind::RegToReg,
            startpoint: "serdiv.reg0/CP".into(),
            endpoint: "serdiv.reg1/D".into(),
            nodes: vec![1],
            total_fo4: 10.0,
            slack_fo4: 0.0,
            max_freq_mhz: 0.0,
            primary_loc: loc(),
            multi_cycle: true,
            path_class: Default::default(),
            total_fo4_raw: None,
            class_note: None,
        });
        let report = attribute(&design, &area, &ParamMap::new());
        assert_eq!(report.perf_basis, PerfBasis::MulticycleOnly);
        assert!(report.perf_mhz.is_none());
        assert!(report.perf_multicycle_mhz.is_some());
        assert_eq!(
            report.perf_multicycle_mhz,
            Some(max_freq_mhz_for_path(10.0, 20.0, 0.2))
        );
        assert!(report.off_path_area_au.unwrap() > 0.0);
        assert!(report.on_path.is_empty());
        assert_eq!(report.metrics.null_reason, Some("no_primary_path"));
        assert!(report.metrics.perf_per_area.is_none());
    }

    #[test]
    fn deny_drops_the_child_from_parent_area_and_from_delay() {
        let area = crate::default_area_v1_embedded();
        let mut design = TimingDesign::empty(TimingTarget::new(1000.0, 20.0, 0.2));
        let mut parent = empty_module(0, "parent");
        parent.nodes.insert(1, node(1, add_expr()));
        let mut child = empty_module(1, "child");
        child.nodes.insert(2, node(2, add_expr()));
        design.modules.insert(0, parent);
        design.modules.insert(1, child);
        design.module_names.insert("parent".into(), 0);
        design.module_names.insert("child".into(), 1);
        design
            .instances
            .push(instance(0, "u_child", 1, Some(false)));
        design.paths.push(TimingPath {
            id: 0,
            region_id: 0,
            module: 1,
            start: PathEndpoint::InputPort { module: 1, port: 0 },
            end: PathEndpoint::OutputPort { module: 1, port: 1 },
            path_kind: PathKind::InToOut,
            startpoint: "child.in".into(),
            endpoint: "child.out".into(),
            nodes: vec![2],
            total_fo4: 40.0,
            slack_fo4: 0.0,
            max_freq_mhz: 0.0,
            primary_loc: loc(),
            multi_cycle: false,
            path_class: Default::default(),
            total_fo4_raw: None,
            class_note: None,
        });
        let mut inclusion = Inclusion::all();
        inclusion.parse_flag("deny:child").unwrap();
        let report = attribute_with(&design, &area, &ParamMap::new(), &inclusion, 20).unwrap();
        let parent = report
            .modules
            .iter()
            .find(|row| row.name == "parent")
            .unwrap();
        assert!(report.modules.iter().all(|row| row.name != "child"));
        assert_eq!(parent.inclusive_au, parent.exclusive_au);
        assert_ne!(report.metrics.delay_fo4, Some(40.0));
    }

    #[test]
    fn path_kind_does_not_let_another_path_set_delay() {
        let area = crate::default_area_v1_embedded();
        let mut design = TimingDesign::empty(TimingTarget::new(1000.0, 20.0, 0.2));
        let mut module = empty_module(0, "alu");
        module.nodes.insert(1, node(1, add_expr()));
        module.nodes.insert(2, node(2, add_expr()));
        design.modules.insert(0, module);
        design.module_names.insert("alu".into(), 0);
        design
            .paths
            .push(sample_path(0, PathKind::RegToReg, vec![1], 10.0, false));
        design
            .paths
            .push(sample_path(1, PathKind::InToOut, vec![2], 80.0, false));
        let mut inclusion = Inclusion::all();
        inclusion.parse_flag("path-kind:reg_to_reg").unwrap();
        let report = attribute_with(&design, &area, &ParamMap::new(), &inclusion, 20).unwrap();
        assert_eq!(report.perf_basis, PerfBasis::RegToReg);
        assert_eq!(report.metrics.delay_fo4, Some(10.0));
        assert!(report.metrics.perf_per_area.is_some());
    }

    #[test]
    fn overlay_miss_increments_only_the_failed_key() {
        let area = crate::default_area_v1_embedded();
        let mut design = TimingDesign::empty(TimingTarget::new(1000.0, 20.0, 0.2));
        let mut module = empty_module(0, "unit");
        module.nodes.insert(
            1,
            node(
                1,
                Expr::Ternary {
                    cond: Box::new(Expr::Ident { name: "EN".into() }),
                    then_e: Box::new(add_expr()),
                    else_e: Box::new(Expr::Ident { name: "a".into() }),
                },
            ),
        );
        design.modules.insert(0, module);
        design.module_names.insert("unit".into(), 0);
        let mut hit = Inclusion::all();
        hit.parse_overlay("EN=1").unwrap();
        let before: Vec<f64> = design.paths.iter().map(|path| path.total_fo4).collect();
        let selected = attribute_with(&design, &area, &ParamMap::new(), &hit, 20).unwrap();
        let after: Vec<f64> = design.paths.iter().map(|path| path.total_fo4).collect();
        assert_eq!(before, after);
        assert_eq!(selected.n_config_unresolved, 0);
        let unit = selected
            .modules
            .iter()
            .find(|row| row.name == "unit")
            .unwrap();
        assert!(unit.tags.iter().any(|tag| tag == "area_arm_selected"));
        assert!(unit.tags.iter().any(|tag| tag == "delay_not_respecialized"));
        let hinted = crate::report_json(&selected, &design, &area, "", "");
        let hints = hinted["hints"].as_array().unwrap();
        assert!(hints.iter().any(|hint| hint["module"] == "unit"));
        let mut miss = Inclusion::all();
        miss.parse_overlay("MISSING=1").unwrap();
        let failed = attribute_with(&design, &area, &ParamMap::new(), &miss, 20).unwrap();
        assert_eq!(failed.n_config_unresolved, 1);
    }

    fn add_expr() -> Expr {
        Expr::Binary {
            op: "+".into(),
            op_class: OperatorClass::AddSub,
            left: Box::new(Expr::Ident { name: "a".into() }),
            right: Box::new(Expr::Ident { name: "b".into() }),
        }
    }

    fn sample_path(id: u32, kind: PathKind, nodes: Vec<u32>, fo4: f64, multi: bool) -> TimingPath {
        TimingPath {
            id,
            region_id: 0,
            module: 0,
            start: PathEndpoint::RegClock { cell: 0 },
            end: PathEndpoint::RegData { cell: 1 },
            path_kind: kind,
            startpoint: "s".into(),
            endpoint: "e".into(),
            nodes,
            total_fo4: fo4,
            slack_fo4: 0.0,
            max_freq_mhz: 0.0,
            primary_loc: loc(),
            multi_cycle: multi,
            path_class: Default::default(),
            total_fo4_raw: None,
            class_note: None,
        }
    }

    fn module_row(name: &str, exclusive: f64, delay: f64) -> ModuleRow {
        ModuleRow {
            name: name.into(),
            exclusive_au: exclusive,
            inclusive_au: exclusive,
            role: "root",
            perf_basis: "reg_to_reg",
            delay_fo4: delay,
            inclusive_delay_fo4: delay,
            tags: Vec::new(),
        }
    }

    fn empty_module(id: u32, name: &str) -> TimingModule {
        TimingModule {
            id,
            name: name.into(),
            file: "t.sv".into(),
            nodes: BTreeMap::new(),
            regions: BTreeMap::new(),
            localparams: vec!["EN".into()],
            parameters: Vec::new(),
            ports: Vec::new(),
            gen_loops: Vec::new(),
            functions: Vec::new(),
            function_bodies: Vec::new(),
            package_imports: Vec::new(),
            instances: Vec::new(),
            decls: Vec::new(),
            config_branch: false,
            loc: loc(),
        }
    }

    fn cross_path(id: u32, child: Option<u32>, parent: Option<u32>) -> CrossModulePath {
        CrossModulePath {
            id,
            parent_module: "parent".into(),
            instance_name: "u_child".into(),
            child_module: "child".into(),
            child_path_id: child,
            parent_path_id: parent,
            total_fo4: 1.0,
            slack_fo4: 0.0,
            max_freq_mhz: 0.0,
            startpoint: "s".into(),
            endpoint: "e".into(),
            rationale: String::new(),
            stitch_kind: "port_bridged".into(),
            bridge_nets: Vec::new(),
            via_ports: Vec::new(),
        }
    }

    fn instance(parent: u32, name: &str, child: u32, over: Option<bool>) -> ModuleInstance {
        ModuleInstance {
            parent_module: parent,
            parent_name: "parent".into(),
            instance_name: name.into(),
            child_type: "leaf".into(),
            child_module: Some(child),
            connections: Vec::new(),
            loc: loc(),
            param_override_present: over,
        }
    }
}
