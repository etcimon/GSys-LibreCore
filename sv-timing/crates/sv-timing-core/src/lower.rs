// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Lower parsed CST → TimingDesign IR (modules, always regions, operators).

//! CST → timing IR. See `architecture/AUTO-CORRECT-CORE-API.md` §3.1.

use std::collections::BTreeMap;
use std::path::Path;

use sv_parser::{unwrap_node, Locate, RefNode, SyntaxTree};

use crate::error::CoreResult;
use crate::expr::Expr;
use crate::ir::{
    AssignKind, CombRegion, CrossModulePath, DeclSite, EdgeKind, FunctionBody, GateInfo,
    GenerateLoop, IrNode, ModuleId, ModuleInstance, ModulePort, NodeId, OperatorClass,
    PathEndpoint, PathId, PortConnection, RegionId, RegionKind, ResetInfo, TimingDesign,
    TimingModule, TimingPackage, TimingPath, TimingTarget, TypedParameter,
};
use crate::loc::{LineIndex, OriginKind, SourceLoc};
use crate::measure::{attribute_costs, max_freq_mhz_for_path, CostModel};
use crate::naming::NameTable;
use crate::param_map::ParamMap;
use crate::parse::{parse_paths, ParseOptions, ParsedFile, ParsedUnit};

/// Options for lowering.
#[derive(Debug, Clone)]
pub struct LowerOptions {
    /// Timing target.
    pub target: TimingTarget,
    /// Cost model.
    pub cost_model: CostModel,
    /// Only lower these module names; empty = all.
    pub module_filter: Vec<String>,
    /// Host-supplied hierarchical / const substitutions (`--param-map`).
    pub param_map: ParamMap,
    /// When true, prefer denser package/param surface notes (packages always parsed).
    pub package_mode: bool,
    /// Resolved optimization dials. Only the **analysis** dials matter here
    /// (effort / cache_mode); transform dials are read by `sv-timing-transform`.
    /// See `architecture/OPTIMIZATION-LEVELS.md`.
    pub opt: crate::opt::OptOptions,
}

impl Default for LowerOptions {
    fn default() -> Self {
        Self {
            target: TimingTarget::new(1000.0, 20.0, 0.2),
            cost_model: CostModel::default(),
            module_filter: Vec::new(),
            param_map: ParamMap::new(),
            package_mode: false,
            opt: crate::opt::OptOptions::default(),
        }
    }
}

/// Result of analyze: design + name table reserved with source ids.
#[derive(Debug)]
pub struct AnalyzeOutput {
    /// Timing IR.
    pub design: TimingDesign,
    /// Name table with source names reserved.
    pub names: NameTable,
    /// Files skipped by the parser (see [`crate::parse::ParseOptions::allow_parse_errors`]).
    ///
    /// Always reported, never silent: a reading taken over a partial file set must say so.
    pub skipped_files: Vec<crate::parse::SkippedFile>,
}

/// Parse paths and lower to IR (full analyze pipeline through opportunities).
pub fn analyze_files(
    paths: &[std::path::PathBuf],
    parse: &ParseOptions,
    lower: &LowerOptions,
) -> CoreResult<AnalyzeOutput> {
    let unit = parse_paths(paths, parse)?;
    let mut out = lower_unit(&unit, lower)?;
    out.skipped_files = unit.skipped.clone();
    Ok(out)
}

/// Lower an already-parsed unit.
pub fn lower_unit(unit: &ParsedUnit, opts: &LowerOptions) -> CoreResult<AnalyzeOutput> {
    let mut design = TimingDesign::empty(opts.target.clone());
    design.param_map_keys = opts.param_map.keys();
    design.param_map_ints = opts.param_map.int_entries();
    design.width_map = opts.param_map.width_map.clone();
    design.package_mode = opts.package_mode;
    let mut names = NameTable::new();
    let mut next_module: ModuleId = 0;
    let mut next_node: NodeId = 0;
    let mut next_region: RegionId = 0;
    let mut next_path: PathId = 0;

    for file in &unit.files {
        lower_file(
            file,
            opts,
            &mut design,
            &mut names,
            &mut next_module,
            &mut next_node,
            &mut next_region,
            &mut next_path,
        )?;
    }

    // Apply host param-map to hierarchical port dims / type strings.
    apply_param_map_to_design(&mut design, &opts.param_map);

    attribute_costs(&mut design, &opts.cost_model);
    // Hottest node, not the last statement in the always_comb (that was
    // `default: state_d = ST_IDLE` on g6lc_ai_exec / gemm_seq / fpnew_fma).
    crate::measure::refresh_primary_locs(&mut design);
    resolve_instance_child_ids(&mut design);
    stitch_cross_module_paths(&mut design, &mut next_path);
    // P5: compose assign fragments into launch→capture cones, then
    // remeasure so InsertReg sees flop-to-flop paths (gemm_span / gemm_seq).
    crate::measure::compose_reg_to_reg_paths(&mut design);
    // Cross-module paths need classification; local paths already classified.
    crate::measure::remeasure_path_slacks(&mut design);
    design.versions.cost_model = opts.cost_model.id.clone();

    Ok(AnalyzeOutput {
        design,
        names,
        skipped_files: Vec::new(),
    })
}

/// Substitute host param-map into port dims / type refs (generic string replace).
fn apply_param_map_to_design(design: &mut TimingDesign, map: &ParamMap) {
    if map.is_empty() {
        return;
    }
    for module in design.modules.values_mut() {
        for p in &mut module.ports {
            if let Some(d) = &p.packed_dims {
                p.packed_dims = Some(map.substitute_text(d));
            }
            if let Some(t) = &p.type_name {
                p.type_name = Some(map.substitute_text(t));
            }
        }
        for par in &mut module.parameters {
            if let Some(t) = &par.type_ref {
                par.type_ref = Some(map.substitute_text(t));
            }
            if let Some(d) = &par.default_expr {
                par.default_expr = Some(map.substitute_text(d));
            }
        }
        for g in &mut module.gen_loops {
            if let Some(b) = &g.bound_hint {
                g.bound_hint = Some(map.substitute_text(b));
            }
        }
    }
}

/// Fill `child_module` on every instance when the type is known in the design.
fn resolve_instance_child_ids(design: &mut TimingDesign) {
    let name_map = design.module_names.clone();
    for inst in &mut design.instances {
        inst.child_module = name_map.get(&inst.child_type).copied();
    }
    // Mirror onto parent modules
    for module in design.modules.values_mut() {
        for inst in &mut module.instances {
            inst.child_module = name_map.get(&inst.child_type).copied();
        }
    }
}

/// Build hierarchical paths: prefer port-bridged stitch, else series upper-bound.
fn stitch_cross_module_paths(design: &mut TimingDesign, next_path: &mut PathId) {
    design.cross_module_paths.clear();
    let budget = design.target.budget_fo4;
    let fo4_ps = design.target.fo4_ps;
    let margin = design.target.budget_margin;

    // Precompute worst path per module id
    let mut worst: BTreeMap<ModuleId, TimingPath> = BTreeMap::new();
    for path in &design.paths {
        if path.multi_cycle {
            continue;
        }
        match worst.get(&path.module) {
            None => {
                worst.insert(path.module, path.clone());
            }
            Some(cur) => {
                if path.slack_fo4 < cur.slack_fo4
                    || (path.slack_fo4 == cur.slack_fo4 && path.total_fo4 > cur.total_fo4)
                {
                    worst.insert(path.module, path.clone());
                }
            }
        }
    }

    // Child output port names by module id (for bridge detection)
    let child_outputs: BTreeMap<ModuleId, Vec<String>> = design
        .modules
        .iter()
        .map(|(id, m)| {
            let outs = m
                .ports
                .iter()
                .filter(|p| p.direction == "output")
                .map(|p| p.name.clone())
                .collect();
            (*id, outs)
        })
        .collect();
    let parent_inputs: BTreeMap<ModuleId, Vec<String>> = design
        .modules
        .iter()
        .map(|(id, m)| {
            let ins = m
                .ports
                .iter()
                .filter(|p| p.direction == "input")
                .map(|p| p.name.clone())
                .collect();
            (*id, ins)
        })
        .collect();

    let instances = design.instances.clone();
    for inst in instances {
        let Some(child_id) = inst.child_module else {
            continue;
        };
        let child_path = worst.get(&child_id).cloned();
        let parent_path = worst.get(&inst.parent_module).cloned();
        if child_path.is_none() && parent_path.is_none() {
            continue;
        }

        // Port-bridge: connections whose formal is a child output.
        let outs = child_outputs.get(&child_id).cloned().unwrap_or_default();
        let mut bridges: Vec<(String, String)> = Vec::new(); // (formal, actual)
        for c in &inst.connections {
            if outs.iter().any(|o| o == &c.formal) {
                bridges.push((c.formal.clone(), c.actual.clone()));
            }
        }
        // Also note parent inputs that match an actual (net feeds parent I/O path)
        let pins = parent_inputs
            .get(&inst.parent_module)
            .cloned()
            .unwrap_or_default();
        let bridged_to_parent_io: Vec<(String, String)> = bridges
            .iter()
            .filter(|(_, actual)| pins.iter().any(|p| p == actual))
            .cloned()
            .collect();

        let (stitch_kind, via_ports, bridge_nets, rationale_extra) = if !bridges.is_empty() {
            let via: Vec<String> = bridges.iter().map(|(f, a)| format!("{f}={a}")).collect();
            let nets: Vec<String> = bridges.iter().map(|(_, a)| a.clone()).collect();
            let extra = if bridged_to_parent_io.is_empty() {
                "child output(s) driven onto parent nets"
            } else {
                "child output(s) feed parent primary input(s)"
            };
            ("port_bridged".to_string(), via, nets, extra)
        } else {
            (
                "series_upper_bound".to_string(),
                Vec::new(),
                Vec::new(),
                "no child-output connections recovered; series FO4 only",
            )
        };

        let c_fo4 = child_path.as_ref().map(|p| p.total_fo4).unwrap_or(0.0);
        let p_fo4 = parent_path.as_ref().map(|p| p.total_fo4).unwrap_or(0.0);
        let total = c_fo4 + p_fo4;
        let slack = budget - total;
        let max_mhz = max_freq_mhz_for_path(total, fo4_ps, margin);

        let bridge_label = if bridge_nets.is_empty() {
            String::new()
        } else {
            format!(" via {}", bridge_nets.join(","))
        };
        let startpoint = child_path
            .as_ref()
            .map(|p| {
                format!(
                    "{}.{}::{}{}",
                    inst.parent_name, inst.instance_name, p.startpoint, bridge_label
                )
            })
            .unwrap_or_else(|| {
                format!(
                    "{}.{}::{}{}",
                    inst.parent_name, inst.instance_name, inst.child_type, bridge_label
                )
            });
        let endpoint = parent_path
            .as_ref()
            .map(|p| p.endpoint.clone())
            .unwrap_or_else(|| inst.parent_name.clone());
        let id = *next_path;
        *next_path += 1;
        design.cross_module_paths.push(CrossModulePath {
            id,
            parent_module: inst.parent_name.clone(),
            instance_name: inst.instance_name.clone(),
            child_module: inst.child_type.clone(),
            child_path_id: child_path.as_ref().map(|p| p.id),
            parent_path_id: parent_path.as_ref().map(|p| p.id),
            total_fo4: total,
            slack_fo4: slack,
            max_freq_mhz: max_mhz,
            startpoint,
            endpoint,
            rationale: format!(
                "instance {}.{}:{} {stitch_kind} (child {:.1} + parent {:.1} FO4; {rationale_extra})",
                inst.parent_name, inst.instance_name, inst.child_type, c_fo4, p_fo4
            ),
            stitch_kind,
            bridge_nets,
            via_ports,
        });
    }
}

/// One operator / assignment recovered from a region.
struct OpExtract {
    op_class: OperatorClass,
    loc: SourceLoc,
    lhs: Option<String>,
    rhs: Option<String>,
    /// Case-item labels when assign is under a case arm (from CST).
    case_labels: Vec<String>,
    case_is_default: bool,
    case_selector: Option<String>,
    assign_kind: AssignKind,
    /// Predicates of the enclosing `if`s (within the block) and the index
    /// expressions of a dynamically indexed LHS — reads and a mux (delay-v37).
    guards: Vec<String>,
}

/// Intermediate region extract before IR materialization.
struct RegionExtract {
    kind: RegionKind,
    loc: SourceLoc,
    label: Option<String>,
    gate: GateInfo,
    ops: Vec<OpExtract>,
}

/// One module's CST slice (PERF-CACHE B3). `RefNode` is not a lazy cursor.
struct ModuleScope<'a> {
    name: String,
    loc: SourceLoc,
    nodes: Vec<RefNode<'a>>,
}

fn lower_file(
    file: &ParsedFile,
    opts: &LowerOptions,
    design: &mut TimingDesign,
    names: &mut NameTable,
    next_module: &mut ModuleId,
    next_node: &mut NodeId,
    next_region: &mut RegionId,
    next_path: &mut PathId,
) -> CoreResult<()> {
    let tree = &file.tree;
    let path_str = file.path.display().to_string();
    let li = &file.line_index;

    // Packages first (localparams + functions) — independent of module filter.
    for node in tree {
        if let RefNode::PackageDeclaration(pkg) = node {
            if let Some(tp) = extract_package(tree, li, &path_str, &file.bytes, pkg) {
                names.reserve(&tp.name, &tp.name);
                design.packages.insert(tp.name.clone(), tp);
            }
        }
    }

    let mut scopes = collect_module_scopes(tree, li, &path_str);
    // If no modules, synthesize a file-scoped pseudo-module for operator discovery.
    if scopes.is_empty() && design.packages.is_empty() {
        scopes.push(ModuleScope {
            name: format!("_file_{}", sanitize_stem(&path_str)),
            loc: SourceLoc::file_start(&file.path),
            nodes: tree.into_iter().collect(),
        });
    }

    for scope in scopes {
        let mod_name = scope.name.clone();
        let mod_loc = scope.loc.clone();
        if !opts.module_filter.is_empty() && !opts.module_filter.iter().any(|m| m == &mod_name) {
            continue;
        }
        names.reserve(&mod_name, &mod_name);
        let mid = *next_module;
        *next_module += 1;

        let parameters = collect_typed_parameters_in(tree, scope.nodes.iter().cloned());
        let ports = collect_module_ports_in(tree, scope.nodes.iter().cloned());
        let decls = collect_decl_sites(tree, li, &path_str, scope.nodes.iter().cloned());
        let fn_spans = collect_function_spans_in(tree, li, &path_str, scope.nodes.iter().cloned());
        let mut gen_loops = collect_genvar_loops_in(
            tree,
            li,
            &path_str,
            &file.bytes,
            scope.nodes.iter().cloned(),
        );
        for g in &mut gen_loops {
            g.in_function = g.loc.origin == OriginKind::UserFile
                && fn_spans.iter().any(|f| {
                    f.origin == OriginKind::UserFile
                        && f.file == g.loc.file
                        && g.loc.byte_start >= f.byte_start
                        && g.loc.byte_end <= f.byte_end
                });
        }
        let insts = collect_module_instances_in(
            tree,
            li,
            &path_str,
            mid,
            &mod_name,
            scope.nodes.iter().cloned(),
        );

        let mut module = TimingModule {
            id: mid,
            name: mod_name.clone(),
            file: path_str.clone(),
            nodes: BTreeMap::new(),
            regions: BTreeMap::new(),
            localparams: collect_localparam_names_in(tree, scope.nodes.iter().cloned()),
            parameters,
            ports,
            gen_loops,
            functions: collect_function_names_in(tree, scope.nodes.iter().cloned()),
            function_bodies: collect_function_bodies(
                tree,
                &file.bytes,
                scope.nodes.iter().cloned(),
            ),
            package_imports: collect_package_imports_in(tree, scope.nodes.iter().cloned()),
            instances: insts.clone(),
            decls,
            const_exprs: collect_const_exprs_in(tree, scope.nodes.iter().cloned()),
            typedef_texts: collect_typedef_texts_in(tree, scope.nodes.iter().cloned()),
            config_branch: module_has_config_branch(scope.nodes.iter().cloned()),
            guards: Default::default(),
            onehot_facts: collect_onehot_facts(
                &file.bytes,
                &scope.loc,
                &scope_end_byte(tree, li, &path_str, scope.nodes.iter().cloned()),
            ),
            guard_sites: collect_guard_sites(
                tree,
                li,
                &path_str,
                &file.bytes,
                scope.nodes.iter().cloned(),
            ),
            decl_texts: collect_decl_texts(
                tree,
                li,
                &path_str,
                &file.bytes,
                scope.nodes.iter().cloned(),
            ),
            pipe_pragmas: collect_pipe_pragmas(
                &file.bytes,
                &path_str,
                &scope.loc,
                &scope_end_byte(tree, li, &path_str, scope.nodes.iter().cloned()),
            ),
            loc: mod_loc,
        };
        let dead_generate = constant_generate_dead_spans(
            tree,
            li,
            &path_str,
            &scope.nodes,
            &module,
            &design.param_map_ints,
        );
        let is_dead = |loc: &SourceLoc| {
            loc.origin == OriginKind::UserFile
                && loc.file == path_str
                && loc_in_spans(loc, &dead_generate)
        };
        module.gen_loops.retain(|g| !is_dead(&g.loc));
        module.instances.retain(|i| !is_dead(&i.loc));
        design.instances.extend(module.instances.iter().cloned());

        let mut region_ops: Vec<RegionExtract> = Vec::new();

        for node in scope.nodes.iter().cloned() {
            match node {
                RefNode::AlwaysConstruct(x) => {
                    let kind = match &x.nodes.0 {
                        sv_parser::AlwaysKeyword::AlwaysComb(_) => RegionKind::AlwaysComb,
                        sv_parser::AlwaysKeyword::AlwaysFf(_) => RegionKind::AlwaysFf,
                        sv_parser::AlwaysKeyword::AlwaysLatch(_) => RegionKind::AlwaysComb,
                        sv_parser::AlwaysKeyword::Always(_) => RegionKind::AlwaysComb,
                    };
                    let region_loc = first_locate_loc(tree, li, &path_str, x);
                    if is_dead(&region_loc) {
                        continue;
                    }
                    let mut gate = extract_gate_from_always(tree, x);
                    gate.is_comb = kind != RegionKind::AlwaysFf;
                    let label = first_named_begin_label(tree, x);
                    let ops = collect_ops_and_assigns(tree, li, &path_str, &file.bytes, x);
                    // Keep always_ff even with no binary ops (NBA-only register regions).
                    if !ops.is_empty() || kind == RegionKind::AlwaysFf {
                        region_ops.push(RegionExtract {
                            kind,
                            loc: region_loc,
                            label,
                            gate,
                            ops,
                        });
                    }
                }
                RefNode::ContinuousAssign(x) => {
                    let region_loc = first_locate_loc(tree, li, &path_str, x);
                    if is_dead(&region_loc) {
                        continue;
                    }
                    let ops = collect_ops_and_assigns(tree, li, &path_str, &file.bytes, x);
                    if !ops.is_empty() {
                        region_ops.push(RegionExtract {
                            kind: RegionKind::ContAssign,
                            loc: region_loc,
                            label: None,
                            gate: GateInfo {
                                is_comb: true,
                                ..Default::default()
                            },
                            ops,
                        });
                    }
                }
                _ => {}
            }
        }

        // Fallback: this module's CST slice, not the whole file.
        if region_ops.is_empty() {
            let mut ops = collect_ops_and_assigns(
                tree,
                li,
                &path_str,
                &file.bytes,
                scope.nodes.iter().cloned(),
            );
            ops.retain(|op| !is_dead(&op.loc));
            if !ops.is_empty() {
                region_ops.push(RegionExtract {
                    kind: RegionKind::AlwaysComb,
                    loc: SourceLoc::file_start(&file.path),
                    label: None,
                    gate: GateInfo {
                        is_comb: true,
                        ..Default::default()
                    },
                    ops,
                });
            }
        }

        for reg in region_ops {
            let rid = *next_region;
            *next_region += 1;
            let mut node_ids = Vec::new();
            let mut prev: Option<NodeId> = None;
            for op in &reg.ops {
                let nid = *next_node;
                *next_node += 1;
                let mut fans_in = Vec::new();
                if let Some(p) = prev {
                    fans_in.push(p);
                    if let Some(pn) = module.nodes.get_mut(&p) {
                        pn.fans_out.push(nid);
                    }
                }
                let lhs_expr = op.lhs.as_ref().map(|s| Expr::parse(s));
                let rhs_expr = op.rhs.as_ref().map(|s| Expr::parse(s));
                // Trust a parsed tree, including Other (P1 Const∘Const / wire
                // slice). Discarding Other used to restore the string-heuristic
                // Mul/DivRem from `*` `/` `%` inside `[msb:lsb]` / replication.
                let op_class = match rhs_expr.as_ref() {
                    Some(e) if !e.is_opaque() => e.dominant_op_class(),
                    _ => op.op_class,
                };
                module.nodes.insert(
                    nid,
                    IrNode {
                        id: nid,
                        op_class: Some(op_class),
                        width: 1,
                        fo4_cost: 0.0,
                        gate: Some(reg.gate.clone()),
                        loc: op.loc.clone(),
                        fans_in,
                        fans_out: Vec::new(),
                        width_defaulted: true,
                        reads_reg: false,
                        lhs: op.lhs.clone(),
                        rhs: op.rhs.clone(),
                        lhs_expr,
                        rhs_expr,
                        case_labels: op.case_labels.clone(),
                        case_is_default: op.case_is_default,
                        case_selector: op.case_selector.clone(),
                        fo4_locked: false,
                        assign_kind: op.assign_kind,
                    },
                );
                if !op.guards.is_empty() {
                    module.guards.insert(nid, op.guards.clone());
                }
                node_ids.push(nid);
                prev = Some(nid);
            }
            // always_ff with only NBA may have empty ops — still record the region.
            if node_ids.is_empty() && reg.kind == RegionKind::AlwaysFf {
                let nid = *next_node;
                *next_node += 1;
                module.nodes.insert(
                    nid,
                    IrNode {
                        id: nid,
                        op_class: Some(OperatorClass::Other),
                        width: 1,
                        fo4_cost: 0.0,
                        gate: Some(reg.gate.clone()),
                        loc: reg.loc.clone(),
                        fans_in: Vec::new(),
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
                        fo4_locked: false,
                        assign_kind: AssignKind::Unknown,
                    },
                );
                node_ids.push(nid);
            }
            if node_ids.is_empty() {
                continue;
            }
            module.regions.insert(
                rid,
                CombRegion {
                    id: rid,
                    module: mid,
                    kind: reg.kind,
                    label: reg.label.clone(),
                    gate: reg.gate.clone(),
                    nodes: node_ids.clone(),
                    total_fo4: 0.0,
                    loc_span: reg.loc.clone(),
                    multi_cycle: false,
                },
            );

            let pid = *next_path;
            *next_path += 1;
            let primary = module
                .nodes
                .get(node_ids.last().unwrap())
                .map(|n| n.loc.clone())
                .unwrap_or_else(|| reg.loc.clone());
            let (start, end) = endpoints_for_region(reg.kind, mid);
            let path_kind = crate::ir::PathKind::from_endpoints(&start, &end);
            let startpoint = start.report_name(&mod_name);
            let endpoint = end.report_name(&mod_name);
            design.paths.push(TimingPath {
                id: pid,
                region_id: rid,
                module: mid,
                start,
                end,
                path_kind,
                startpoint,
                endpoint,
                nodes: node_ids,
                total_fo4: 0.0,
                slack_fo4: 0.0,
                max_freq_mhz: 0.0,
                primary_loc: primary,
                multi_cycle: false,
                path_class: crate::path_class::PathClassKind::Plain,
                total_fo4_raw: None,
                class_note: None,
            });
        }

        design.module_names.insert(mod_name.clone(), mid);
        design.modules.insert(mid, module);
    }

    Ok(())
}

fn collect_module_scopes<'a>(
    tree: &'a SyntaxTree,
    li: &LineIndex,
    path_str: &str,
) -> Vec<ModuleScope<'a>> {
    let mut out = Vec::new();
    for node in tree {
        match node {
            RefNode::ModuleDeclarationAnsi(x) => {
                if let Some(name) = module_name(tree, unwrap_node!(x, ModuleIdentifier)) {
                    let loc = first_locate_loc(tree, li, path_str, x);
                    out.push(ModuleScope {
                        name,
                        loc,
                        nodes: x.into_iter().collect(),
                    });
                }
            }
            RefNode::ModuleDeclarationNonansi(x) => {
                if let Some(name) = module_name(tree, unwrap_node!(x, ModuleIdentifier)) {
                    let loc = first_locate_loc(tree, li, path_str, x);
                    out.push(ModuleScope {
                        name,
                        loc,
                        nodes: x.into_iter().collect(),
                    });
                }
            }
            _ => {}
        }
    }
    out
}

fn collect_module_instances_in<'a, T>(
    tree: &'a SyntaxTree,
    li: &LineIndex,
    path_str: &str,
    parent_id: ModuleId,
    parent_name: &str,
    root: T,
) -> Vec<ModuleInstance>
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    let mut out = Vec::new();
    for node in root {
        let RefNode::ModuleInstantiation(mi) = node else {
            continue;
        };
        let child_type = match module_name(tree, unwrap_node!(mi, ModuleIdentifier)) {
            Some(n) => n,
            None => continue,
        };
        // Skip self-recursive weirdness / empty
        if child_type.is_empty() {
            continue;
        }
        let loc = first_locate_loc(tree, li, path_str, mi);
        // List of hierarchical instances: mi.nodes.2
        let list = &mi.nodes.2;
        for hier in list.contents() {
            let inst_name = instance_name_of(tree, hier).unwrap_or_else(|| "_anon".into());
            let connections = port_connections_of(tree, hier);
            out.push(ModuleInstance {
                parent_module: parent_id,
                parent_name: parent_name.to_string(),
                instance_name: inst_name,
                child_type: child_type.clone(),
                child_module: None,
                connections,
                loc: loc.clone(),
                param_override_present: Some(mi.nodes.1.is_some()),
            });
        }
    }
    out
}

fn instance_name_of(tree: &SyntaxTree, hier: &sv_parser::HierarchicalInstance) -> Option<String> {
    // NameOfInstance → InstanceIdentifier
    for node in hier {
        if let RefNode::InstanceIdentifier(id) = node {
            return identifier_str(tree, RefNode::InstanceIdentifier(id));
        }
    }
    None
}

fn port_connections_of(
    tree: &SyntaxTree,
    hier: &sv_parser::HierarchicalInstance,
) -> Vec<PortConnection> {
    let mut conns = Vec::new();
    for node in hier {
        if let RefNode::NamedPortConnectionIdentifier(npc) = node {
            // formal = PortIdentifier; actual = first ident in optional expression
            let formal = first_ident_named(tree, &npc.nodes.2).unwrap_or_else(|| "_".into());
            let actual = npc
                .nodes
                .3
                .as_ref()
                .and_then(|paren| paren.nodes.1.as_ref())
                .and_then(|expr| first_simple_ident_in(tree, expr))
                .unwrap_or_else(|| formal.clone());
            conns.push(PortConnection { formal, actual });
        }
    }
    conns
}

fn first_ident_named<'a, T>(tree: &'a SyntaxTree, root: T) -> Option<String>
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    first_simple_ident_in(tree, root)
}

fn extract_package(
    tree: &SyntaxTree,
    li: &LineIndex,
    path_str: &str,
    bytes: &[u8],
    pkg: &sv_parser::PackageDeclaration,
) -> Option<TimingPackage> {
    let name = module_name(tree, unwrap_node!(pkg, PackageIdentifier))?;
    let loc = first_locate_loc(tree, li, path_str, pkg);
    Some(TimingPackage {
        name,
        file: path_str.into(),
        localparams: collect_localparam_names_in(tree, pkg),
        functions: collect_function_names_in(tree, pkg),
        function_bodies: collect_function_bodies(tree, bytes, pkg),
        typedefs: collect_typedef_names_in(tree, pkg),
        const_exprs: collect_const_exprs_in(tree, pkg),
        typedef_texts: collect_typedef_texts_in(tree, pkg),
        loc,
    })
}

/// `parameter` / `localparam` assignments: name → value expression text
/// (preprocessed frame, `SyntaxTree::get_str`). First declaration wins.
fn collect_const_exprs_in<'a, T>(tree: &'a SyntaxTree, root: T) -> BTreeMap<String, String>
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    let mut out = BTreeMap::new();
    for node in root {
        if let RefNode::ParamAssignment(pa) = node {
            let Some(name) = identifier_str(tree, RefNode::ParameterIdentifier(&pa.nodes.0)) else {
                continue;
            };
            let Some((_, expr)) = pa.nodes.2.as_ref() else {
                continue;
            };
            if let Some(text) = node_text(tree, expr) {
                out.entry(name).or_insert(text);
            }
        }
    }
    out
}

/// A localparam accepted for reachability (not heuristic width inference).
struct GenerateConst {
    expr: Expr,
    loc: SourceLoc,
    scope: Option<(u32, u32)>,
}

/// Prove a small integer subset without borrowing WidthResolver's default
/// parameters or width-insensitive arithmetic. Localparam int arithmetic is
/// evaluated in its 32-bit context and every intermediate must fit a positive
/// signed int32. Condition arithmetic without that context is left unknown.
fn generate_const_value(
    expr: &Expr,
    at: u32,
    int_context: bool,
    locals: &BTreeMap<String, GenerateConst>,
    declared: &std::collections::BTreeSet<String>,
    host: &BTreeMap<String, i64>,
    depth: u32,
) -> Option<i64> {
    if depth > 12 {
        return None;
    }
    let eval =
        |e: &Expr, wide| generate_const_value(e, at, wide, locals, declared, host, depth + 1);
    let value = match expr {
        Expr::Literal { text } => {
            let t = text.trim().replace('_', "");
            match t.as_str() {
                "'0" | "1'b0" => Some(0),
                "1'b1" => Some(1),
                _ => t.parse::<i64>().ok(),
            }
        }
        Expr::Ident { name } => {
            if let Some(c) = locals.get(name) {
                if c.scope.is_some_and(|(lo, hi)| at < lo || at >= hi) {
                    return None;
                }
                generate_const_value(
                    &c.expr,
                    c.loc.byte_start,
                    true,
                    locals,
                    declared,
                    host,
                    depth + 1,
                )
            } else if !declared.contains(name) {
                // Exact keys only. No last-member fallback from Cfg.FIELD
                // to FIELD, and no guessing from parameter defaults.
                host.get(name).copied()
            } else {
                None
            }
        }
        Expr::Unary { op, arg } if op == "!" => eval(arg, false).map(|v| i64::from(v == 0)),
        Expr::Ternary {
            cond,
            then_e,
            else_e,
        } if int_context => {
            // Both arms must be in the bounded, nonnegative int subset.
            // This handles slice-count localparams without guessing widths
            // or signed extensions from an unsupported unselected arm.
            let c = eval(cond, false)?;
            let yes = eval(then_e, true)?;
            let no = eval(else_e, true)?;
            Some(if c != 0 { yes } else { no })
        }
        Expr::Binary {
            op, left, right, ..
        } => {
            let arithmetic = matches!(op.as_str(), "+" | "-" | "*" | "/" | "%");
            if arithmetic && !int_context {
                return None;
            }
            let l = eval(left, arithmetic)?;
            let r = eval(right, arithmetic)?;
            match op.as_str() {
                "+" => l.checked_add(r),
                "-" => l.checked_sub(r),
                "*" => l.checked_mul(r),
                "/" if r != 0 => l.checked_div(r),
                "%" if r != 0 => l.checked_rem(r),
                "==" => Some(i64::from(l == r)),
                "!=" => Some(i64::from(l != r)),
                "<" => Some(i64::from(l < r)),
                "<=" => Some(i64::from(l <= r)),
                ">" => Some(i64::from(l > r)),
                ">=" => Some(i64::from(l >= r)),
                "&&" => Some(i64::from(l != 0 && r != 0)),
                "||" => Some(i64::from(l != 0 || r != 0)),
                _ => None,
            }
        }
        _ => None,
    }?;
    (0..=i64::from(i32::MAX)).contains(&value).then_some(value)
}

/// Known-dead source ranges of conditional generate constructs. Width facts
/// alone cannot prove reachability: an elaborated width map merges multiple
/// specializations. Only explicit values and safe local constants qualify.
fn constant_generate_dead_spans(
    tree: &SyntaxTree,
    li: &LineIndex,
    path: &str,
    nodes: &[RefNode<'_>],
    module: &TimingModule,
    host: &BTreeMap<String, i64>,
) -> Vec<(u32, u32)> {
    use std::collections::BTreeSet;
    let mut definitions: BTreeMap<String, BTreeSet<(u32, u32)>> = BTreeMap::new();
    let mut scopes = Vec::new();
    let mut unresolved_scope = false;
    for node in nodes {
        let span = match node {
            RefNode::GenerateBlock(b) => origin_byte_span(tree, li, *b),
            RefNode::SeqBlock(b) => origin_byte_span(tree, li, *b),
            RefNode::FunctionDeclaration(b) => origin_byte_span(tree, li, *b),
            RefNode::TaskDeclaration(b) => origin_byte_span(tree, li, *b),
            _ => None,
        };
        if let Some(span) = span {
            scopes.push(span);
        } else if matches!(
            node,
            RefNode::GenerateBlock(_)
                | RefNode::SeqBlock(_)
                | RefNode::FunctionDeclaration(_)
                | RefNode::TaskDeclaration(_)
        ) {
            unresolved_scope = true;
        }
        if let RefNode::ParamAssignment(pa) = node {
            if let Some(name) = identifier_str(tree, RefNode::ParameterIdentifier(&pa.nodes.0)) {
                definitions
                    .entry(name)
                    .or_default()
                    .insert(origin_byte_span(tree, li, *pa).unwrap_or((u32::MAX, u32::MAX)));
            }
        }
    }
    // A host key cannot turn a port, variable or genvar into an elaboration
    // parameter. Blocking a shadowed spelling globally is conservative.
    let runtime_names: BTreeSet<_> = module
        .ports
        .iter()
        .map(|p| p.name.clone())
        .chain(module.decls.iter().map(|d| d.name.clone()))
        .chain(module.gen_loops.iter().map(|g| g.genvar.clone()))
        .collect();
    let declared: BTreeSet<_> = definitions
        .keys()
        .cloned()
        .chain(runtime_names.iter().cloned())
        .collect();
    let host: BTreeMap<_, _> = host
        .iter()
        .filter(|(name, _)| {
            !TimingModule::root_ident(name).is_some_and(|root| runtime_names.contains(root))
        })
        .map(|(k, v)| (k.clone(), *v))
        .collect();
    let mut locals = BTreeMap::new();
    for node in nodes {
        let RefNode::LocalParameterDeclaration(sv_parser::LocalParameterDeclaration::Param(p)) =
            node
        else {
            continue;
        };
        let ty = node_text(tree, &p.nodes.1).unwrap_or_default();
        let ty = ty.split_whitespace().collect::<Vec<_>>().join(" ");
        if unresolved_scope || !matches!(ty.as_str(), "int" | "int unsigned" | "int signed") {
            continue;
        }
        for item in &p.nodes.2 {
            let RefNode::ParamAssignment(pa) = item else {
                continue;
            };
            let Some(name) = identifier_str(tree, RefNode::ParameterIdentifier(&pa.nodes.0)) else {
                continue;
            };
            if !pa.nodes.1.is_empty()
                || runtime_names.contains(&name)
                || definitions.get(&name).is_none_or(|d| d.len() != 1)
            {
                continue;
            }
            let loc = loop_source_span(tree, li, path, pa);
            let Some((_, rhs)) = &pa.nodes.2 else {
                continue;
            };
            let Some(text) = node_text(tree, rhs) else {
                continue;
            };
            if loc.origin != OriginKind::UserFile {
                continue;
            }
            let scope = scopes
                .iter()
                .copied()
                .filter(|(lo, hi)| *lo <= loc.byte_start && loc.byte_start < *hi)
                .min_by_key(|(lo, hi)| hi - lo);
            locals.insert(
                name,
                GenerateConst {
                    expr: Expr::parse(&text),
                    loc,
                    scope,
                },
            );
        }
    }
    let mut dead = Vec::new();
    for node in nodes {
        let RefNode::IfGenerateConstruct(g) = node else {
            continue;
        };
        let cond = &g.nodes.1.nodes.1;
        let Some((at, _)) = origin_byte_span(tree, li, cond) else {
            continue;
        };
        let Some(text) = node_text(tree, cond) else {
            continue;
        };
        let Some(value) =
            generate_const_value(&Expr::parse(&text), at, false, &locals, &declared, &host, 0)
        else {
            continue;
        };
        let inactive = if value == 0 {
            Some(&g.nodes.2)
        } else {
            g.nodes.3.as_ref().map(|(_, block)| block)
        };
        if let Some(span) = inactive.and_then(|b| origin_byte_span(tree, li, b)) {
            dead.push(span);
        }
    }
    dead
}

/// `typedef <data_type> <name>;`: name → data-type text (`logic [IdxW-1:0]`,
/// `enum logic [1:0] {…}`, `struct packed {…}`). Width inference reads the
/// base vector type; struct bodies stay unresolved.
fn collect_typedef_texts_in<'a, T>(tree: &'a SyntaxTree, root: T) -> BTreeMap<String, String>
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    let mut out = BTreeMap::new();
    for node in root {
        if let RefNode::TypeDeclarationDataType(td) = node {
            let Some(name) = identifier_str(tree, RefNode::TypeIdentifier(&td.nodes.2)) else {
                continue;
            };
            let mut text = node_text(tree, &td.nodes.1).unwrap_or_default();
            for dim in &td.nodes.3 {
                if let Some(d) = node_text(tree, dim) {
                    text.push(' ');
                    text.push_str(&d);
                }
            }
            if !text.is_empty() {
                out.entry(name).or_insert(text);
            }
        }
    }
    out
}

/// Typedef / struct type names under a package or module.
fn collect_typedef_names_in<'a, T>(tree: &'a SyntaxTree, root: T) -> Vec<String>
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    let mut names = Vec::new();
    for node in root {
        // TypeIdentifier after typedef keyword often appears as TypeIdentifier / ClassIdentifier
        if let RefNode::TypeIdentifier(t) = node {
            if let Some(s) = identifier_str(tree, RefNode::TypeIdentifier(t)) {
                if !names.contains(&s) {
                    names.push(s);
                }
            }
        }
    }
    names
}

/// Format `left::right` when two scope tokens are present (generic package/class path).
fn scoped_path(tokens: &[String]) -> Option<String> {
    let mut t: Vec<String> = tokens.to_vec();
    t.dedup();
    match t.as_slice() {
        [] => None,
        [a] => Some(a.clone()),
        [a, b] => Some(format!("{a}::{b}")),
        xs => Some(format!("{}::{}", xs[0], xs[xs.len() - 1])),
    }
}

/// Format hierarchical `root.member` (left of `.` is any parameter/struct root).
fn hierarchical_path(root: &str, member: &str) -> String {
    format!("{root}.{member}")
}

/// `parameter scope::type_t Name = scope::default` and `parameter type T = …`.
///
/// Scope pieces come from AST `PackageScope` / `ClassType` / type identifiers
/// (anything that appears as the left of `::`), never a hard-coded package list.
fn collect_typed_parameters_in<'a, T>(tree: &'a SyntaxTree, root: T) -> Vec<TypedParameter>
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    let mut out = Vec::new();
    let mut seen = std::collections::BTreeSet::new();

    for node in root {
        match node {
            RefNode::ParameterDeclarationParam(p) => {
                let default_text = integer_after_eq(tree.get_str(p));
                let mut param_ids: Vec<String> = Vec::new();
                let mut type_ids: Vec<String> = Vec::new();
                let mut default_ids: Vec<String> = Vec::new();
                let mut saw_eq = false;
                for n in p {
                    if let RefNode::Symbol(sym) = n {
                        if tree
                            .get_str(&sym.nodes.0)
                            .map(|t| t.trim() == "=")
                            .unwrap_or(false)
                        {
                            saw_eq = true;
                            continue;
                        }
                    }
                    match n {
                        RefNode::ParameterIdentifier(pi) => {
                            if let Some(s) = identifier_str(tree, RefNode::ParameterIdentifier(pi))
                            {
                                if !saw_eq {
                                    param_ids.push(s);
                                } else {
                                    default_ids.push(s);
                                }
                            }
                        }
                        // Left of `::` and type names: structural scopes, not project names.
                        RefNode::TypeIdentifier(t) => {
                            if let Some(s) = identifier_str(tree, RefNode::TypeIdentifier(t)) {
                                if !saw_eq {
                                    type_ids.push(s);
                                } else {
                                    default_ids.push(s);
                                }
                            }
                        }
                        RefNode::ClassType(_) | RefNode::PackageScope(_) => {
                            if let Some(s) = first_simple_ident_in(tree, n) {
                                if !saw_eq {
                                    type_ids.push(s);
                                } else {
                                    default_ids.push(s);
                                }
                            }
                        }
                        other => {
                            // Only accept extra idents that are already in a scope node path
                            // when walking PackageScope children as plain identifiers.
                            if let Some(s) = identifier_str(tree, other) {
                                // Skip bare keywords masquerading as idents
                                if s == "parameter" || s == "localparam" || s == "type" {
                                    continue;
                                }
                                // Prefer not to invent type path from random idents; only
                                // fill if PackageScope already contributed at least one token
                                // or ParameterIdentifier is empty so far.
                                if !saw_eq && !type_ids.is_empty() && param_ids.is_empty() {
                                    // still in type region before name
                                    if !type_ids.contains(&s) {
                                        type_ids.push(s);
                                    }
                                } else if saw_eq && !default_ids.is_empty() {
                                    if !default_ids.contains(&s) {
                                        default_ids.push(s);
                                    }
                                }
                            }
                        }
                    }
                }
                let name = param_ids.last().cloned();
                if let Some(name) = name {
                    let tpath: Vec<String> = type_ids.into_iter().filter(|t| t != &name).collect();
                    let type_ref = scoped_path(&tpath);
                    let default_expr = scoped_path(&default_ids);
                    if seen.insert(name.clone()) {
                        out.push(TypedParameter {
                            name,
                            is_type_parameter: false,
                            type_ref,
                            default_expr,
                            default_text,
                        });
                    }
                }
            }
            RefNode::ParameterDeclarationType(p) => {
                let default_text = integer_after_eq(tree.get_str(p));
                // parameter type T = default (default may be scope::type)
                let mut names = Vec::new();
                let mut default_tokens = Vec::new();
                let mut saw_eq = false;
                for n in p {
                    if let RefNode::Symbol(sym) = n {
                        if tree
                            .get_str(&sym.nodes.0)
                            .map(|s| s.trim() == "=")
                            .unwrap_or(false)
                        {
                            saw_eq = true;
                            continue;
                        }
                    }
                    match n {
                        RefNode::ClassType(_) | RefNode::PackageScope(_) if saw_eq => {
                            if let Some(s) = first_simple_ident_in(tree, n) {
                                default_tokens.push(s);
                            }
                        }
                        _ => {
                            if let Some(s) = identifier_str(tree, n) {
                                if s == "parameter" || s == "type" {
                                    continue;
                                }
                                if !saw_eq {
                                    names.push(s);
                                } else {
                                    default_tokens.push(s);
                                }
                            }
                        }
                    }
                }
                // Type-parameter name is typically the last id before `=`
                if let Some(name) = names.last() {
                    if seen.insert(name.clone()) {
                        out.push(TypedParameter {
                            name: name.clone(),
                            is_type_parameter: true,
                            type_ref: None,
                            default_expr: scoped_path(&default_tokens).or_else(|| {
                                if default_tokens.is_empty() {
                                    None
                                } else {
                                    Some(default_tokens.join("::"))
                                }
                            }),
                            default_text,
                        });
                    }
                }
            }
            _ => {}
        }
    }
    out
}

fn type_before_name(text: &str, var_name: &str) -> Option<String> {
    let mut outside = String::new();
    let mut depth = 0i32;
    for ch in text.chars() {
        match ch {
            '[' => depth += 1,
            ']' => depth -= 1,
            _ if depth == 0 => outside.push(ch),
            _ => {}
        }
    }
    let idents: Vec<&str> = outside
        .split(|c: char| !c.is_ascii_alphanumeric() && c != '_')
        .filter(|token| !token.is_empty())
        .collect();
    let pos = idents.iter().position(|token| *token == var_name)?;
    if pos == 0 {
        return None;
    }
    let candidate = idents[pos - 1];
    if candidate == "var" {
        return None;
    }
    Some(candidate.to_string())
}

/// Integer default after `=` in a parameter declaration. Reads the node's
/// own (preprocessed) text through `SyntaxTree::get_str`: parser offsets
/// address the preprocessed buffer, not the original bytes, and the two drift
/// apart after a string literal followed by a quoting comment, an `ifdef`, or
/// a macro (`stream_arbiter` shifts by 22 bytes after `ARBITER = "rr" // "rr"`).
fn integer_after_eq(text: Option<&str>) -> Option<String> {
    let text = text?.trim();
    let rhs = text.split_once('=')?.1;
    let rhs = rhs.trim().trim_end_matches([';', ',']).trim();
    if rhs.parse::<i64>().is_ok() {
        Some(rhs.to_string())
    } else {
        None
    }
}

/// Trimmed preprocessed text of a CST node (`SyntaxTree::get_str`), the
/// frame the parser's offsets actually address. Prefer this over slicing the
/// original bytes at `locate_byte_span` offsets.
fn node_text<'a, T: Into<sv_parser::RefNodes<'a>>>(tree: &SyntaxTree, node: T) -> Option<String> {
    let text = tree.get_str(node)?.trim().to_string();
    if text.is_empty() {
        None
    } else {
        Some(text)
    }
}

fn packed_dimension_text<'a, T>(tree: &'a SyntaxTree, root: T) -> Option<String>
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    let mut parts = Vec::new();
    for node in root {
        if let RefNode::PackedDimension(dim) = node {
            if let Some(text) = node_text(tree, dim) {
                parts.push(text);
            }
        }
    }
    if parts.is_empty() {
        None
    } else {
        Some(parts.join(""))
    }
}

fn unpacked_dimension_text<'a, T>(tree: &'a SyntaxTree, root: T) -> String
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    let mut parts = Vec::new();
    for node in root {
        if let RefNode::UnpackedDimension(dim) = node {
            if let Some(text) = node_text(tree, dim) {
                parts.push(text);
            }
        }
    }
    parts.join("")
}

fn module_has_config_branch<'a, T>(root: T) -> bool
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    root.into_iter().any(|node| {
        matches!(
            node,
            RefNode::ConditionalStatement(_) | RefNode::IfGenerateConstruct(_)
        )
    })
}

fn collect_decl_sites<'a, T>(
    tree: &'a SyntaxTree,
    li: &LineIndex,
    path_str: &str,
    root: T,
) -> Vec<DeclSite>
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    let mut out = Vec::new();
    // Pass 1: names declared below module scope. `root` is a flat walk, so a
    // declaration inside a `begin … end`, a function/task body or a generate
    // block is visited again here from its enclosing construct; the emit side
    // must not hoist a reference to one of these to module level
    // (perf_counters `automatic logic brh` inside `for … always_comb`).
    let mut block_local: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    // Block-local nets have no DataDeclaration site; they get one below.
    let mut local_nets: Vec<(String, SourceLoc)> = Vec::new();
    let mut scopes = Vec::new();
    let mut unresolved_scope = false;
    let mut nested: Vec<RefNode<'a>> = Vec::new();
    for node in root {
        nested.push(node.clone());
        let scope = match &node {
            RefNode::SeqBlock(b) => Some(loop_source_span(tree, li, path_str, *b)),
            RefNode::GenerateBlock(b) => Some(loop_source_span(tree, li, path_str, *b)),
            RefNode::FunctionDeclaration(b) => Some(loop_source_span(tree, li, path_str, *b)),
            RefNode::TaskDeclaration(b) => Some(loop_source_span(tree, li, path_str, *b)),
            RefNode::LoopStatementFor(b) => Some(loop_source_span(tree, li, path_str, *b)),
            _ => None,
        };
        if let Some(scope) = scope {
            if scope.origin == OriginKind::UserFile && scope.byte_end > scope.byte_start {
                scopes.push(scope);
            } else {
                unresolved_scope = true;
            }
        }
        let inner: Vec<RefNode<'a>> = match &node {
            RefNode::SeqBlock(b) => (*b).into_iter().collect(),
            RefNode::FunctionDeclaration(f) => (*f).into_iter().collect(),
            RefNode::TaskDeclaration(t) => (*t).into_iter().collect(),
            RefNode::GenerateBlock(g) => (*g).into_iter().collect(),
            RefNode::ForVariableDeclaration(fv) => (*fv).into_iter().collect(),
            _ => continue,
        };
        // Every declared name inside the construct: `VariableIdentifier`
        // (data declarations, loop variables — declaration sites only) and the
        // nets of a `NetDeclaration` (`wire cmo_req = …` inside a generate-if;
        // a bare `NetIdentifier` would also match an `assign` LHS reference).
        for n in inner {
            match n {
                RefNode::VariableIdentifier(id) => {
                    if let Some(name) = identifier_str(tree, RefNode::VariableIdentifier(id)) {
                        block_local.insert(name);
                    }
                }
                RefNode::NetDeclaration(nd) => {
                    let loc = first_locate_loc(tree, li, path_str, nd);
                    for d in nd {
                        if let RefNode::NetIdentifier(id) = d {
                            if let Some(name) = identifier_str(tree, RefNode::NetIdentifier(id)) {
                                block_local.insert(name.clone());
                                local_nets.push((name, loc.clone()));
                            }
                        }
                    }
                }
                _ => {}
            }
        }
    }
    // Pass 2: the declaration sites, flagged against pass 1. A `for` loop
    // variable is a declaration site too (type `int`/`genvar`, no packed dims).
    for node in nested {
        if let RefNode::ForVariableDeclaration(fv) = &node {
            let loc = first_locate_loc(tree, li, path_str, *fv);
            for child in *fv {
                if let RefNode::VariableIdentifier(id) = child {
                    if let Some(name) = identifier_str(tree, RefNode::VariableIdentifier(id)) {
                        out.push(DeclSite {
                            name,
                            type_name: "int".to_string(),
                            packed_text: String::new(),
                            unpacked_text: String::new(),
                            loc: loc.clone(),
                            block_local: true,
                            scope: None,
                            loop_var: true,
                        });
                    }
                }
            }
            continue;
        }
        let RefNode::DataDeclaration(decl) = node else {
            continue;
        };
        let sv_parser::DataDeclaration::Variable(var) = decl else {
            continue;
        };
        let var = var.as_ref();
        let loc = first_locate_loc(tree, li, path_str, var);
        let data_type = &var.nodes.3;
        let assignments = &var.nodes.4;
        let mut type_name = String::new();
        for child in data_type {
            if let RefNode::TypeIdentifier(id) = child {
                if let Some(name) = identifier_str(tree, RefNode::TypeIdentifier(id)) {
                    type_name = name;
                    break;
                }
            }
            if type_name.is_empty() {
                if let Some(name) = identifier_str(tree, child) {
                    if matches!(name.as_str(), "logic" | "bit" | "reg" | "wire") {
                        type_name = name;
                    }
                }
            }
        }
        let mut names = Vec::new();
        for child in assignments {
            if let RefNode::VariableIdentifier(id) = child {
                if let Some(name) = identifier_str(tree, RefNode::VariableIdentifier(id)) {
                    names.push(name);
                }
            }
        }
        if let Some(text) = node_text(tree, var) {
            if let Some(name) = names.first() {
                if let Some(found) = type_before_name(&text, name) {
                    type_name = found;
                }
            }
        }
        if type_name.is_empty() {
            type_name = "logic".to_string();
        }
        let packed = packed_dimension_text(tree, data_type).unwrap_or_default();
        let unpacked = unpacked_dimension_text(tree, assignments);
        for name in names {
            let is_local = block_local.contains(&name);
            out.push(DeclSite {
                name,
                type_name: type_name.clone(),
                packed_text: packed.clone(),
                unpacked_text: unpacked.clone(),
                loc: loc.clone(),
                block_local: is_local,
                scope: None,
                loop_var: false,
            });
        }
    }
    for (name, loc) in local_nets {
        if !out.iter().any(|d| d.name == name && d.loc == loc) {
            out.push(DeclSite {
                name,
                type_name: "wire".to_string(),
                packed_text: String::new(),
                unpacked_text: String::new(),
                loc,
                block_local: true,
                scope: None,
                loop_var: false,
            });
        }
    }
    for decl in &mut out {
        if decl.loc.origin == OriginKind::UserFile {
            decl.scope = scopes
                .iter()
                .filter(|s| {
                    s.file == decl.loc.file
                        && s.byte_start <= decl.loc.byte_start
                        && decl.loc.byte_start < s.byte_end
                })
                .min_by_key(|s| s.byte_end - s.byte_start)
                .cloned();
            // A module declaration must not inherit the block-local flag just
            // because a different block declares a variable of the same name.
            decl.block_local = decl.scope.is_some() || (unresolved_scope && decl.block_local);
        }
    }
    out
}

/// Port list: direction + type + optional hierarchical packed dims (`root.member`).
fn collect_module_ports_in<'a, T>(tree: &'a SyntaxTree, root: T) -> Vec<ModulePort>
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    let mut ports: Vec<ModulePort> = Vec::new();
    let mut seen = std::collections::BTreeSet::new();

    for node in root {
        if let RefNode::AnsiPortDeclaration(port) = node {
            let mut dimension_text = packed_dimension_text(tree, port);
            let mut direction = "unknown".to_string();
            let mut type_name: Option<String> = None;
            let mut name: Option<String> = None;
            // Identifiers that appear in the port but are neither type nor port name
            // (candidates for hierarchical dimension roots/members).
            let mut other_idents: Vec<String> = Vec::new();

            for n in port {
                match n {
                    RefNode::PortDirection(d) => {
                        if let Some(s) = tree_keyword_or_ident(tree, RefNode::PortDirection(d)) {
                            direction = s;
                        }
                    }
                    RefNode::InputDeclaration(_) => direction = "input".into(),
                    RefNode::OutputDeclaration(_) => direction = "output".into(),
                    RefNode::InoutDeclaration(_) => direction = "inout".into(),
                    RefNode::PortIdentifier(p) => {
                        if let Some(s) = identifier_str(tree, RefNode::PortIdentifier(p)) {
                            name = Some(s);
                        }
                    }
                    RefNode::TypeIdentifier(t) => {
                        if let Some(s) = identifier_str(tree, RefNode::TypeIdentifier(t)) {
                            type_name = Some(s);
                        }
                    }
                    RefNode::IntegerVectorType(_) | RefNode::IntegerAtomType(_) => {
                        if type_name.is_none() {
                            type_name = Some("logic".into());
                        }
                    }
                    other => {
                        if let Some(s) = identifier_str(tree, other) {
                            let is_builtin =
                                s == "logic" || s == "wire" || s == "reg" || s == "bit";
                            if is_builtin {
                                if type_name.is_none() {
                                    type_name = Some(s);
                                }
                            } else if type_name.as_ref() != Some(&s)
                                && name.as_ref() != Some(&s)
                                && !other_idents.contains(&s)
                            {
                                other_idents.push(s);
                            } else if type_name.is_none() && s.ends_with("_t") {
                                // typedef-like type name when TypeIdentifier not surfaced
                                type_name = Some(s);
                            }
                        }
                    }
                }
            }

            // Drop type/port names that were also seen as bare identifiers.
            if let Some(ref n) = name {
                other_idents.retain(|s| s != n);
            }
            if let Some(ref t) = type_name {
                other_idents.retain(|s| s != t);
            }

            // Hierarchical / param-sized dims: any leftover idents after removing
            // port + type names (e.g. root.member or WIDTH).
            let uses_hierarchical = !other_idents.is_empty();
            let dims = if other_idents.len() >= 2 {
                Some(format!(
                    "[{}-1:0]",
                    hierarchical_path(&other_idents[0], &other_idents[1])
                ))
            } else if other_idents.len() == 1 {
                Some(format!("[{}.*]", other_idents[0]))
            } else {
                None
            };

            // `input logic [31:0] a, b, c`: the grammar gives `b` and `c` their
            // own AnsiPortDeclaration with no direction, type or dimension —
            // they inherit the previous port's (IEEE 1800-2017 §23.2.2.3).
            // Without this `b` and `c` were 1 bit wide to width inference.
            let bare = direction == "unknown"
                && type_name.is_none()
                && dimension_text.is_none()
                && dims.is_none();
            if bare {
                if let Some(prev) = ports.last() {
                    direction = prev.direction.clone();
                    type_name = prev.type_name.clone();
                    dimension_text = prev.dimension_text.clone();
                }
            }
            let (dims, uses_hierarchical) = if bare {
                ports
                    .last()
                    .map(|p| (p.packed_dims.clone(), p.uses_hierarchical))
                    .unwrap_or((dims, uses_hierarchical))
            } else {
                (dims, uses_hierarchical)
            };

            if let Some(n) = name {
                if seen.insert(n.clone()) {
                    ports.push(ModulePort {
                        name: n,
                        direction,
                        type_name,
                        packed_dims: dims,
                        uses_hierarchical,
                        dimension_text,
                    });
                }
            }
        }
    }
    ports
}

fn tree_keyword_or_ident(tree: &SyntaxTree, node: RefNode<'_>) -> Option<String> {
    for n in node {
        if let RefNode::Keyword(k) = n {
            if let Some(s) = tree.get_str(&k.nodes.0) {
                return Some(s.trim().to_string());
            }
        }
        if let Some(s) = identifier_str(tree, n) {
            return Some(s);
        }
    }
    None
}

/// Last origin byte of a module scope (its `endmodule`), for text scans.
fn scope_end_byte<'a, T>(tree: &'a SyntaxTree, li: &LineIndex, path_str: &str, root: T) -> u32
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    let mut end = 0u32;
    for node in root {
        if let RefNode::Locate(l) = node {
            if let Some((p, start)) = tree.get_origin(l) {
                if p == &li.path {
                    end = end.max((start + l.len) as u32);
                }
            }
        }
    }
    let _ = path_str;
    end
}

/// Arguments of every `$onehot0(…)` / `$onehot(…)` in the module's source
/// span, whitespace-normalized (`grant[p]`).
/// `// svt-pipe: <kind> [domain] key=value … word …` pragmas inside the
/// module span (A123). Textual, like the `$onehot` facts: the pragma is a
/// comment, so the parser never sees it, and its location is the comment
/// line itself (the anchor of `cut-ok` / `no-cut` is the next statement).
fn collect_pipe_pragmas(
    bytes: &[u8],
    path_str: &str,
    start: &SourceLoc,
    end: &u32,
) -> Vec<crate::ir::PipePragma> {
    let lo = start.byte_start as usize;
    let hi = (*end as usize).max(lo).min(bytes.len());
    let text = String::from_utf8_lossy(&bytes[lo..hi]);
    let line_base = start.start_line;
    let mut out = Vec::new();
    let mut offset = lo;
    for (i, line) in text.split_inclusive('\n').enumerate() {
        let line_no = line_base + i as u32;
        let line_start = offset;
        offset += line.len();
        let Some(ci) = line.find("//") else { continue };
        let body = line[ci + 2..].trim();
        let Some(rest) = body.strip_prefix("svt-pipe:") else {
            continue;
        };
        let mut words = rest.split_whitespace();
        let Some(kind) = words.next() else { continue };
        let takes_domain = matches!(
            kind,
            "protocol"
                | "carry"
                | "result"
                | "cut-ok"
                | "latency"
                | "representation"
                | "row-local"
                | "row-local-applied"
        );
        let mut domain = None;
        let mut args = Vec::new();
        let mut bare = Vec::new();
        for w in words {
            if let Some((k, v)) = w.split_once('=') {
                args.push((k.to_string(), v.trim_end_matches(',').to_string()));
            } else if takes_domain && domain.is_none() {
                domain = Some(w.trim_end_matches(',').to_string());
            } else {
                for part in w.split(',') {
                    if !part.is_empty() {
                        bare.push(part.to_string());
                    }
                }
            }
        }
        let trimmed_len = line.trim_end_matches(['\n', '\r']).len();
        let end_byte = line_start + trimmed_len;
        out.push(crate::ir::PipePragma {
            row_local: None,
            derived: false,
            kind: if matches!(kind, "representation" | "row-local") && !line[..ci].trim().is_empty()
            {
                "invalid-inline-pipeline-directive".into()
            } else {
                kind.to_string()
            },
            domain,
            args,
            words: bare,
            loc: SourceLoc {
                file: path_str.to_string(),
                start_line: line_no,
                start_col: (ci + 1) as u32,
                end_line: line_no,
                end_col: (trimmed_len + 1) as u32,
                byte_start: (line_start + ci) as u32,
                byte_end: end_byte as u32,
                origin: OriginKind::UserFile,
            },
        });
    }
    out
}

fn collect_onehot_facts(bytes: &[u8], start: &SourceLoc, end: &u32) -> Vec<String> {
    let lo = start.byte_start as usize;
    let hi = (*end as usize).max(lo).min(bytes.len());
    let text = String::from_utf8_lossy(&bytes[lo..hi]);
    let mut out = Vec::new();
    for key in ["$onehot0(", "$onehot("] {
        let mut from = 0usize;
        while let Some(i) = text[from..].find(key) {
            let open = from + i + key.len();
            let mut depth = 1i32;
            let mut j = open;
            let b = text.as_bytes();
            while j < b.len() && depth > 0 {
                match b[j] {
                    b'(' => depth += 1,
                    b')' => depth -= 1,
                    _ => {}
                }
                j += 1;
            }
            if depth == 0 {
                let arg: String = text[open..j - 1]
                    .split_whitespace()
                    .collect::<Vec<_>>()
                    .join("");
                if !arg.is_empty() && !out.contains(&arg) {
                    out.push(arg);
                }
            }
            from = j.max(open);
        }
    }
    out
}

/// Source spans of function and task bodies in a scope.
fn collect_function_spans_in<'a, T>(
    tree: &'a SyntaxTree,
    li: &LineIndex,
    path_str: &str,
    root: T,
) -> Vec<SourceLoc>
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    let mut out = Vec::new();
    for node in root {
        match node {
            RefNode::FunctionDeclaration(f) => out.push(loop_source_span(tree, li, path_str, f)),
            RefNode::TaskDeclaration(t) => out.push(loop_source_span(tree, li, path_str, t)),
            _ => {}
        }
    }
    out
}

/// `for (genvar i = 0; i < root.member; i++)` — bound via hierarchical `root.member`.
fn collect_genvar_loops_in<'a, T>(
    tree: &'a SyntaxTree,
    li: &LineIndex,
    path_str: &str,
    bytes: &[u8],
    root: T,
) -> Vec<GenerateLoop>
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    let mut loops = Vec::new();
    for node in root {
        if let RefNode::LoopGenerateConstruct(lg) = node {
            let loc = loop_source_span(tree, li, path_str, lg);
            let mut genvar = "i".to_string();
            let mut saw_own_genvar = false;
            let mut label: Option<String> = None;
            let mut body_assign_count = 0u32;
            let mut idents: Vec<String> = Vec::new();

            for n in lg {
                match n {
                    RefNode::GenvarIdentifier(g) => {
                        if let Some(s) = identifier_str(tree, RefNode::GenvarIdentifier(g)) {
                            // Nested generate-for walks inner genvars too; the
                            // first identifier is this loop's own genvar.
                            if !saw_own_genvar {
                                genvar = s.clone();
                                saw_own_genvar = true;
                            }
                            idents.push(s);
                        }
                    }
                    RefNode::SeqBlock(seq) => {
                        if let Some((_, block_id)) = &seq.nodes.1 {
                            for b in block_id {
                                if let Some(s) = identifier_str(tree, b) {
                                    label = Some(s);
                                    break;
                                }
                            }
                        }
                    }
                    RefNode::GenerateBlockIdentifier(g) => {
                        if let Some(s) = identifier_str(tree, RefNode::GenerateBlockIdentifier(g)) {
                            if s != genvar {
                                label = Some(s);
                            }
                        }
                    }
                    RefNode::GenerateBlock(gb) => {
                        if label.is_none() {
                            for b in gb {
                                if let RefNode::GenerateBlockIdentifier(g) = b {
                                    if let Some(s) =
                                        identifier_str(tree, RefNode::GenerateBlockIdentifier(g))
                                    {
                                        if s != genvar {
                                            label = Some(s);
                                            break;
                                        }
                                    }
                                }
                            }
                        }
                    }
                    RefNode::ContinuousAssign(_) => body_assign_count += 1,
                    RefNode::BlockingAssignment(_) | RefNode::NonblockingAssignment(_) => {
                        body_assign_count += 1;
                    }
                    _ => {
                        if let Some(s) = identifier_str(tree, n) {
                            idents.push(s);
                        }
                    }
                }
            }

            // Bound: first hierarchical pair (root, member) excluding the genvar itself.
            // Models `param.field` / `struct.member` generically (left of `.`).
            let bound_hint = idents
                .windows(2)
                .find(|w| w[0] != genvar && w[1] != genvar && w[0] != w[1])
                .map(|w| hierarchical_path(&w[0], &w[1]));

            // Drop label if it collides with hierarchical root (mis-detect).
            let label = label.filter(|l| {
                !bound_hint
                    .as_ref()
                    .map(|b| b.starts_with(&format!("{l}.")))
                    .unwrap_or(false)
                    || !idents.first().map(|s| s == l).unwrap_or(false)
            });

            loops.push(GenerateLoop {
                genvar,
                bound_hint,
                label,
                loc,
                body_assign_count,
                procedural: false,
                init_text: None,
                cond_text: None,
                text: None,
                pre_text: None,
                in_function: false,
            });
        }
        // always_comb `for (int unsigned w = 0; w < Cfg.N; w++)` unrolls;
        // `w` is elaboration-constant in each body copy (hpdcache_mshr hit_comb).
        if let RefNode::LoopStatementFor(lf) = node {
            let loc = loop_source_span(tree, li, path_str, lf);
            let mut idx = String::new();
            let mut saw = false;
            let mut body_assign_count = 0u32;
            // Header texts for the trip count (`k = 0; k < N`).
            let header = &lf.nodes.1.nodes.1;
            let cond_text = header.2.as_ref().and_then(|c| node_text(tree, c));
            let init_text = header.0.as_ref().and_then(|init| {
                node_text(tree, init)
                    .and_then(|t| t.rsplit_once('=').map(|(_, v)| v.trim().to_string()))
            });
            // The loop's own text and the 4 KiB before it (the walk's `cid =
            // start;` seed, a select's `out = '0` inits) for the loop-walk
            // detector.
            let text = node_text(tree, lf);
            let pre_text = if loc.origin == OriginKind::UserFile && loc.byte_start > 0 {
                let start = loc.byte_start.saturating_sub(4096) as usize;
                bytes
                    .get(start..loc.byte_start as usize)
                    .map(|b| String::from_utf8_lossy(b).into_owned())
            } else {
                None
            };
            for n in lf {
                match n {
                    RefNode::VariableIdentifier(v) => {
                        if !saw {
                            if let Some(s) = identifier_str(tree, RefNode::VariableIdentifier(v)) {
                                idx = s;
                                saw = true;
                            }
                        }
                    }
                    RefNode::BlockingAssignment(_)
                    | RefNode::NonblockingAssignment(_)
                    | RefNode::NetAssignment(_)
                    | RefNode::VariableAssignment(_) => {
                        body_assign_count += 1;
                    }
                    _ => {}
                }
            }
            if saw {
                loops.push(GenerateLoop {
                    genvar: idx,
                    bound_hint: None,
                    label: None,
                    loc,
                    body_assign_count,
                    procedural: true,
                    init_text,
                    cond_text,
                    text,
                    pre_text,
                    in_function: false,
                });
            }
        }
    }
    loops
}

/// Loop containment is compared with assignment locations in original-source
/// coordinates. Parser byte offsets instead address preprocessed text: a
/// removed `ifdef` or an expanded macro before a loop shifts that interval.
/// Map both boundary tokens, rather than marking raw parser offsets UserFile.
/// Unknown/include boundaries get an empty interval so they cannot certify a
/// runtime identifier as a genvar by accidental numeric overlap.
fn loop_source_span<'a, T>(
    tree: &'a SyntaxTree,
    li: &LineIndex,
    path_str: &str,
    root: T,
) -> SourceLoc
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    let mut first = None;
    let mut last = None;
    for node in root {
        if let RefNode::Locate(loc) = node {
            if loc.len > 0 {
                first.get_or_insert(loc);
                last = Some(loc);
            }
        }
    }
    if let (Some(first), Some(last)) = (first, last) {
        if let (Some((fpath, start)), Some((lpath, stop))) =
            (tree.get_origin(first), tree.get_origin(last))
        {
            if fpath == &li.path && lpath == &li.path && stop >= start {
                return li.span(start as u32, (stop + last.len) as u32, OriginKind::UserFile);
            }
        }
    }
    let mut unknown = SourceLoc::file_start(path_str);
    unknown.origin = OriginKind::Unknown;
    unknown
}

fn collect_localparam_names_in<'a, T>(tree: &'a SyntaxTree, root: T) -> Vec<String>
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    let mut names = Vec::new();
    for node in root {
        if let RefNode::ListOfParamAssignments(list) = node {
            for n in list {
                if let Some(id) = unwrap_node!(n, ParameterIdentifier, Identifier) {
                    if let Some(s) = identifier_str(tree, id) {
                        if !names.contains(&s) {
                            names.push(s);
                        }
                    }
                }
            }
        }
        // Also catch bare ParameterIdentifier under LocalParameterDeclaration walks
        if let RefNode::ParameterIdentifier(p) = node {
            if let Some(s) = identifier_str(tree, RefNode::ParameterIdentifier(p)) {
                if !names.contains(&s) {
                    names.push(s);
                }
            }
        }
    }
    names
}

fn collect_function_bodies<'a, T>(tree: &'a SyntaxTree, bytes: &[u8], root: T) -> Vec<FunctionBody>
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    let constants = integer_bindings(&String::from_utf8_lossy(bytes));
    let mut out = Vec::new();
    let mut seen = std::collections::BTreeSet::new();
    for node in root {
        let RefNode::FunctionDeclaration(func) = node else {
            continue;
        };
        let Some(name) = function_decl_name(tree, func) else {
            continue;
        };
        if !seen.insert(name.clone()) {
            continue;
        }
        let text = node_text(tree, func).unwrap_or_default();
        out.push(FunctionBody {
            name,
            return_expr: return_expr_text(&text).unwrap_or_default(),
            return_dimension: return_dimension_text(tree, func),
            constants: constants.clone(),
            body_text: text,
        });
    }
    out
}

fn return_dimension_text<'a, T>(tree: &'a SyntaxTree, root: T) -> String
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    let mut name_at: Option<u32> = None;
    let mut dims = Vec::new();
    for node in root {
        match node {
            RefNode::FunctionIdentifier(id) => {
                if name_at.is_none() {
                    name_at = locate_byte_span(id).map(|(start, _)| start);
                }
            }
            RefNode::PackedDimension(dim) => {
                if let Some((start, _)) = locate_byte_span(dim) {
                    if let Some(text) = node_text(tree, dim) {
                        dims.push((start, text));
                    }
                }
            }
            _ => {}
        }
    }
    let Some(name_at) = name_at else {
        return String::new();
    };
    dims.sort_by_key(|(start, _)| *start);
    dims.into_iter()
        .filter(|(start, _)| *start < name_at)
        .map(|(_, text)| text)
        .collect()
}

fn function_decl_name<'a, T>(tree: &'a SyntaxTree, func: T) -> Option<String>
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    for node in func {
        if let RefNode::FunctionIdentifier(id) = node {
            return identifier_str(tree, RefNode::FunctionIdentifier(id));
        }
    }
    None
}

fn return_expr_text(text: &str) -> Option<String> {
    let rest = text.split("return").nth(1)?;
    let expr = rest.split(';').next()?.trim();
    if expr.is_empty() {
        None
    } else {
        Some(expr.to_string())
    }
}

fn integer_bindings(text: &str) -> Vec<(String, i64)> {
    let mut out = Vec::new();
    for stmt in text.split(';') {
        let Some((lhs, rhs)) = stmt.rsplit_once('=') else {
            continue;
        };
        let rhs = rhs.trim().trim_end_matches([';', ',']).trim();
        let Ok(value) = rhs.parse::<i64>() else {
            continue;
        };
        let Some(name) = lhs.split_whitespace().last() else {
            continue;
        };
        let name = name.trim_matches(|ch: char| !ch.is_ascii_alphanumeric() && ch != '_');
        if name.is_empty()
            || !name
                .chars()
                .next()
                .is_some_and(|ch| ch.is_ascii_alphabetic())
        {
            continue;
        }
        out.push((name.to_string(), value));
    }
    out
}

fn collect_function_names_in<'a, T>(tree: &'a SyntaxTree, root: T) -> Vec<String>
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    let mut names = Vec::new();
    for node in root {
        if let RefNode::FunctionIdentifier(f) = node {
            if let Some(s) = identifier_str(tree, RefNode::FunctionIdentifier(f)) {
                if !names.contains(&s) {
                    names.push(s);
                }
            }
        }
    }
    names
}

fn collect_package_imports_in<'a, T>(tree: &'a SyntaxTree, root: T) -> Vec<String>
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    let mut names = Vec::new();
    for node in root {
        if let RefNode::PackageIdentifier(p) = node {
            if let Some(s) = identifier_str(tree, RefNode::PackageIdentifier(p)) {
                // Heuristic: package identifiers near import appear in import items;
                // also includes package declaration name — de-dupe later.
                if !names.contains(&s) {
                    names.push(s);
                }
            }
        }
    }
    names
}

fn identifier_str(tree: &SyntaxTree, node: RefNode<'_>) -> Option<String> {
    let loc = get_identifier(node)?;
    tree.get_str(&loc).map(|s| s.to_string())
}

/// Extract `posedge clk` / `negedge rst` from always_ff sensitivity.
fn extract_gate_from_always(tree: &SyntaxTree, always: &sv_parser::AlwaysConstruct) -> GateInfo {
    let mut gate = GateInfo::default();
    for node in always {
        if let RefNode::EventExpressionExpression(ev) = node {
            // nodes: (Option<EdgeIdentifier>, Expression, Option<…>)
            let edge = match &ev.nodes.0 {
                Some(sv_parser::EdgeIdentifier::Posedge(_)) => Some(EdgeKind::Posedge),
                Some(sv_parser::EdgeIdentifier::Negedge(_)) => Some(EdgeKind::Negedge),
                Some(sv_parser::EdgeIdentifier::Edge(_)) => Some(EdgeKind::Level),
                None => None,
            };
            let name = first_simple_ident_in(tree, &ev.nodes.1);
            match edge {
                Some(EdgeKind::Posedge) => {
                    if gate.clock_name.is_none() {
                        gate.clock_name = name;
                        gate.edge = Some(EdgeKind::Posedge);
                    }
                }
                Some(EdgeKind::Negedge) => {
                    // CVA6 style: async active-low reset on negedge
                    if gate.reset_name.is_none() {
                        gate.reset_name = name;
                        gate.reset_edge = Some(EdgeKind::Negedge);
                        gate.reset = Some(ResetInfo {
                            signal: None,
                            active_low: true,
                            asynchronous: true,
                        });
                    } else if gate.clock_name.is_none() {
                        gate.clock_name = name;
                        gate.edge = Some(EdgeKind::Negedge);
                    }
                }
                _ => {
                    if gate.clock_name.is_none() {
                        gate.clock_name = name;
                    }
                }
            }
        }
    }
    gate
}

fn first_simple_ident_in<'a, T>(tree: &'a SyntaxTree, root: T) -> Option<String>
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    for node in root {
        if let Some(s) = identifier_str(tree, node) {
            return Some(s);
        }
    }
    None
}

/// First `begin : label` under this always (CVA6 `begin : regs` / `ldbuf_ff`).
fn first_named_begin_label<'a, T>(tree: &'a SyntaxTree, root: T) -> Option<String>
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    for node in root {
        if let RefNode::SeqBlock(seq) = node {
            // nodes.1 = Option<(Symbol /*:*/, BlockIdentifier)>
            if let Some((_, block_id)) = &seq.nodes.1 {
                for n in block_id {
                    if let Some(s) = identifier_str(tree, n) {
                        return Some(s);
                    }
                }
            }
        }
    }
    None
}

/// Map region kind → STA-like startpoint/endpoint for frequency closure.
fn endpoints_for_region(kind: RegionKind, mid: ModuleId) -> (PathEndpoint, PathEndpoint) {
    match kind {
        // Comb cloud: treat as virtual reg→reg when between flops is unknown;
        // use in→out so I/O budget still applies; host can re-tag later.
        RegionKind::AlwaysComb | RegionKind::ContAssign => (
            PathEndpoint::InputPort {
                module: mid,
                port: 0,
            },
            PathEndpoint::OutputPort {
                module: mid,
                port: 0,
            },
        ),
        // always_ff body: launch clock → capture D (reg→reg core of Fmax).
        RegionKind::AlwaysFf => (
            PathEndpoint::RegClock { cell: 0 },
            PathEndpoint::RegData { cell: 1 },
        ),
    }
}

fn module_name(tree: &SyntaxTree, id_node: Option<RefNode<'_>>) -> Option<String> {
    let id = id_node?;
    let loc = get_identifier(id)?;
    tree.get_str(&loc).map(|s| s.to_string())
}

fn get_identifier(node: RefNode<'_>) -> Option<Locate> {
    match unwrap_node!(node, SimpleIdentifier, EscapedIdentifier) {
        Some(RefNode::SimpleIdentifier(x)) => Some(x.nodes.0),
        Some(RefNode::EscapedIdentifier(x)) => Some(x.nodes.0),
        _ => None,
    }
}

/// Collect binary ops **and** assignment LHS/RHS text for expression-accurate emit.
fn collect_ops_and_assigns<'a, T>(
    tree: &'a SyntaxTree,
    line_index: &LineIndex,
    path_str: &str,
    bytes: &[u8],
    root: T,
) -> Vec<OpExtract>
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    let nodes: Vec<RefNode<'a>> = root.into_iter().collect();
    let nodes_for_guards: Vec<RefNode<'a>> = nodes.clone();
    let mut ops = Vec::new();
    let mut assigns: Vec<OpExtract> = Vec::new();

    // Pass 1: CaseItem-aware assigns (labels + selector from CST, not source scan).
    let case_meta =
        collect_case_assign_meta(tree, line_index, path_str, bytes, nodes.iter().cloned());
    // IEEE 1800: packed/unpacked dimensions, case-item labels, fixed part-select
    // bounds, indexed-select widths, and replication counts are constant
    // expressions. Do not bill their `/` `*` `%` as datapath (PASS-STRATEGY P1).
    let lrm_spans = lrm_constant_spans(tree, line_index, nodes.iter().cloned());

    for node in nodes {
        match node {
            RefNode::BinaryOperator(bin) => {
                let sym = tree.get_str(&bin.nodes.0).unwrap_or("");
                let loc = locate_to_source(tree, line_index, path_str, &bin.nodes.0.nodes.0);
                if operator_token_in_comment(bytes, &loc) || loc_in_spans(&loc, &lrm_spans) {
                    continue;
                }
                let class = classify_binary(sym);
                ops.push(OpExtract {
                    op_class: class,
                    loc,
                    lhs: None,
                    rhs: None,
                    case_labels: Vec::new(),
                    case_is_default: false,
                    case_selector: None,
                    assign_kind: AssignKind::Unknown,
                    guards: Vec::new(),
                });
            }
            RefNode::NetAssignment(na) => {
                if let Some(a) = assign_lhs_rhs(
                    tree,
                    line_index,
                    path_str,
                    bytes,
                    na,
                    AssignKind::Continuous,
                ) {
                    assigns.push(a);
                }
            }
            RefNode::VariableAssignment(va) => {
                if let Some(a) =
                    assign_lhs_rhs(tree, line_index, path_str, bytes, va, AssignKind::Blocking)
                {
                    assigns.push(a);
                }
            }
            RefNode::BlockingAssignment(ba) => {
                if let Some(a) =
                    assign_lhs_rhs(tree, line_index, path_str, bytes, ba, AssignKind::Blocking)
                {
                    assigns.push(a);
                }
            }
            RefNode::NonblockingAssignment(nba) => {
                if let Some(a) = assign_lhs_rhs(
                    tree,
                    line_index,
                    path_str,
                    bytes,
                    nba,
                    AssignKind::Nonblocking,
                ) {
                    assigns.push(a);
                }
            }
            _ => {}
        }
    }

    // delay-v37: `if` predicates enclosing each assign (by body span) and the
    // LHS's dynamic index expressions are the assign's guards.
    let loop_spans: Vec<SourceLoc> = nodes_for_guards
        .iter()
        .filter_map(|n| match n {
            RefNode::LoopStatementFor(lf) => {
                let sp = loop_source_span(tree, line_index, path_str, *lf);
                (sp.origin == OriginKind::UserFile).then_some(sp)
            }
            _ => None,
        })
        .collect();
    let guard_spans = collect_if_guard_spans(tree, line_index, path_str, bytes, nodes_for_guards);
    for a in &mut assigns {
        if a.loc.origin != OriginKind::UserFile {
            continue;
        }
        // The innermost loop around the assign: a guard whose body contains
        // that whole loop is decided once, above the unrolled copies, and is
        // marked `^` so the trip multiplier does not scale it.
        let inner_loop = loop_spans
            .iter()
            .filter(|l| {
                l.file == a.loc.file
                    && a.loc.byte_start >= l.byte_start
                    && a.loc.byte_start < l.byte_end
            })
            .min_by_key(|l| l.byte_end - l.byte_start);
        for (span, preds) in &guard_spans {
            if span.file == a.loc.file
                && a.loc.byte_start >= span.byte_start
                && a.loc.byte_start < span.byte_end
            {
                let outer = inner_loop.is_some_and(|l| {
                    span.byte_start <= l.byte_start && span.byte_end >= l.byte_end
                });
                for pr in preds {
                    let g = if outer { format!("^{pr}") } else { pr.clone() };
                    if !a.guards.contains(&g) {
                        a.guards.push(g);
                    }
                }
            }
        }
        if let Some(lhs) = a.lhs.as_deref() {
            for ix in lhs_dynamic_indices(lhs) {
                if !a.guards.contains(&ix) {
                    a.guards.push(ix);
                }
            }
        }
    }

    // Merge CaseItem meta onto assigns by start_line (+ optional lhs match).
    if !case_meta.is_empty() {
        for a in &mut assigns {
            if let Some(meta) = case_meta.get(&a.loc.start_line) {
                a.case_labels = meta.labels.clone();
                a.case_is_default = meta.is_default;
                a.case_selector = meta.selector.clone();
            }
        }
    }

    // Prefer assignment-level extracts (carry LHS/RHS). When only binary ops
    // exist without assign wrappers, keep the op list.
    if !assigns.is_empty() {
        for a in &mut assigns {
            if a.op_class == OperatorClass::Other {
                if let Some(ref rhs) = a.rhs {
                    if rhs.contains('+') || rhs.contains('-') {
                        a.op_class = OperatorClass::AddSub;
                    } else if rhs_has_mul_not_pow(rhs) {
                        a.op_class = OperatorClass::Mul;
                    } else if rhs.contains('?') {
                        a.op_class = OperatorClass::Mux;
                    } else if rhs.contains("&&") || rhs.contains("||") || rhs.contains('&') {
                        a.op_class = OperatorClass::LogicBit;
                    }
                }
            }
        }
        return assigns;
    }
    ops
}

/// `if (p0) S0 else if (p1) S1 else S2` → `(span(S0), [p0])`, `(span(S1),
/// [p0, p1])`, `(span(S2), [p0, p1])`: an assign inside a body is guarded by
/// every predicate decided on the way to it (the else branches read the same
/// predicates). Nested conditionals contribute their own entries; the assign
/// collects the union.
/// Declaration source text per name, only for files that author a
/// source-preparation directive (the texts are otherwise unused).
fn collect_decl_texts<'a, T>(
    tree: &'a SyntaxTree,
    li: &LineIndex,
    path_str: &str,
    bytes: &[u8],
    root: T,
) -> BTreeMap<String, String>
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    let mut out = BTreeMap::new();
    let wanted = String::from_utf8_lossy(bytes).lines().any(|line| {
        line.split_once("svt-pipe:")
            .is_some_and(|(_, rest)| rest.split_whitespace().next() == Some("row-local"))
    });
    if !wanted {
        return out;
    }
    for node in root {
        let (loc, names): (SourceLoc, Vec<String>) = match node {
            RefNode::AnsiPortDeclaration(p) => (
                loop_source_span(tree, li, path_str, p),
                p.into_iter()
                    .filter_map(|n| match n {
                        RefNode::PortIdentifier(id) => {
                            identifier_str(tree, RefNode::PortIdentifier(id))
                        }
                        _ => None,
                    })
                    .collect(),
            ),
            RefNode::DataDeclaration(d) => (
                loop_source_span(tree, li, path_str, d),
                d.into_iter()
                    .filter_map(|n| match n {
                        RefNode::VariableIdentifier(id) => {
                            identifier_str(tree, RefNode::VariableIdentifier(id))
                        }
                        _ => None,
                    })
                    .collect(),
            ),
            _ => continue,
        };
        if loc.origin != OriginKind::UserFile {
            continue;
        }
        let Some(text) = bytes
            .get(loc.byte_start as usize..loc.byte_end as usize)
            .and_then(|b| std::str::from_utf8(b).ok())
        else {
            continue;
        };
        for name in names {
            out.entry(name).or_insert_with(|| text.to_string());
        }
    }
    out
}

/// Every `if` / `else if` predicate in `root` with the span of the
/// expression inside its parentheses (A122 guard rewrites).
fn collect_guard_sites<'a, T>(
    tree: &'a SyntaxTree,
    li: &LineIndex,
    path_str: &str,
    bytes: &[u8],
    root: T,
) -> Vec<crate::ir::GuardSite>
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    // Full statement text is only needed by authored source-preparation rules.
    // Avoid retaining nested body copies on ordinary large RTL files.
    let capture_statements = String::from_utf8_lossy(bytes).lines().any(|line| {
        line.split_once("svt-pipe:")
            .is_some_and(|(_, rest)| rest.split_whitespace().next() == Some("row-local"))
    });
    let mut out = Vec::new();
    let mut push = |text: Option<String>, loc: SourceLoc, statement| {
        if let Some(t) = text {
            if loc.origin == OriginKind::UserFile && !t.is_empty() {
                out.push(crate::ir::GuardSite {
                    text: t,
                    loc,
                    statement,
                });
            }
        }
    };
    for node in root {
        if let RefNode::ConditionalStatement(cs) = node {
            let statement = if capture_statements {
                let statement_loc = loop_source_span(tree, li, path_str, cs);
                if statement_loc.origin == OriginKind::UserFile {
                    bytes
                        .get(statement_loc.byte_start as usize..statement_loc.byte_end as usize)
                        .and_then(|b| std::str::from_utf8(b).ok())
                        .map(|text| crate::ir::SourceStatement {
                            loc: statement_loc,
                            text: text.into(),
                        })
                } else {
                    None
                }
            } else {
                None
            };
            push(
                node_text(tree, &cs.nodes.2.nodes.1).map(|t| t.trim().to_string()),
                loop_source_span(tree, li, path_str, &cs.nodes.2.nodes.1),
                statement,
            );
            for (_, _, pred, _) in &cs.nodes.4 {
                push(
                    node_text(tree, &pred.nodes.1).map(|t| t.trim().to_string()),
                    loop_source_span(tree, li, path_str, &pred.nodes.1),
                    None,
                );
            }
        }
    }
    out
}

fn collect_if_guard_spans<'a, T>(
    tree: &'a SyntaxTree,
    li: &LineIndex,
    path_str: &str,
    _bytes: &[u8],
    root: T,
) -> Vec<(SourceLoc, Vec<String>)>
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    let mut out = Vec::new();
    for node in root {
        if let RefNode::ConditionalStatement(cs) = node {
            let mut preds: Vec<String> = Vec::new();
            let p0 = node_text(tree, &cs.nodes.2.nodes.1).map(|t| t.trim().to_string());
            if let Some(p) = p0 {
                preds.push(p);
            }
            let span0 = loop_source_span(tree, li, path_str, &cs.nodes.3);
            if span0.origin == OriginKind::UserFile {
                out.push((span0, preds.clone()));
            }
            for (_, _, pred, body) in &cs.nodes.4 {
                if let Some(p) = node_text(tree, &pred.nodes.1).map(|t| t.trim().to_string()) {
                    preds.push(p);
                }
                let sp = loop_source_span(tree, li, path_str, body);
                if sp.origin == OriginKind::UserFile {
                    out.push((sp, preds.clone()));
                }
            }
            if let Some((_, body)) = &cs.nodes.5 {
                let sp = loop_source_span(tree, li, path_str, body);
                if sp.origin == OriginKind::UserFile {
                    out.push((sp, preds.clone()));
                }
            }
        }
    }
    out
}

/// Index expressions of an LHS that are not constants: `q[slot_entry[g]].valid`
/// → `["slot_entry[g]"]`; `mask[cid]` → `["cid"]`; `x[3]`, `x[i]` with a
/// genvar/loop var are constants to the unrolled logic and are skipped by the
/// reader (they resolve to no net). Nested brackets are kept whole.
fn lhs_dynamic_indices(lhs: &str) -> Vec<String> {
    let b = lhs.as_bytes();
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
                let inner = lhs[start..j - 1].trim();
                // part selects `[7:0]`, `[i+:8]` are constant bounds; a bare
                // number is constant.
                let constant = inner.is_empty()
                    || inner.contains(':')
                    || inner.contains("+:")
                    || inner.contains("-:")
                    || inner
                        .chars()
                        .all(|c| c.is_ascii_digit() || c == '\'' || c == '_');
                if !constant && inner.chars().any(|c| c.is_ascii_alphabetic()) {
                    out.push(inner.to_string());
                }
                i = j;
                continue;
            }
            break;
        }
        i += 1;
    }
    out
}

/// Meta recovered from a CST CaseItem for assigns in its body.
#[derive(Debug, Clone)]
struct CaseAssignMeta {
    labels: Vec<String>,
    is_default: bool,
    selector: Option<String>,
}

/// Walk CaseStatement CST and map assign start_line → case arm meta.
fn collect_case_assign_meta<'a, T>(
    tree: &'a SyntaxTree,
    line_index: &LineIndex,
    path_str: &str,
    bytes: &[u8],
    root: T,
) -> BTreeMap<u32, CaseAssignMeta>
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    let mut out: BTreeMap<u32, CaseAssignMeta> = BTreeMap::new();
    for node in root {
        match node {
            RefNode::CaseStatementNormal(cs) => {
                // nodes: (unique?, case_kw, Paren<CaseExpression>, first CaseItem, rest, endcase)
                let selector = case_expression_text(tree, bytes, &cs.nodes.2.nodes.1);
                merge_case_item_meta(
                    tree,
                    line_index,
                    path_str,
                    bytes,
                    &cs.nodes.3,
                    selector.as_deref(),
                    &mut out,
                );
                for item in &cs.nodes.4 {
                    merge_case_item_meta(
                        tree,
                        line_index,
                        path_str,
                        bytes,
                        item,
                        selector.as_deref(),
                        &mut out,
                    );
                }
            }
            // Matches / Inside: no simple enum label list; skip.
            _ => {}
        }
    }
    out
}

fn case_expression_text(
    tree: &SyntaxTree,
    _bytes: &[u8],
    expr: &sv_parser::CaseExpression,
) -> Option<String> {
    // Prefer raw source span of the case expression.
    let mut start: Option<u32> = None;
    let mut end: Option<u32> = None;
    for node in expr {
        if let RefNode::Locate(l) = node {
            let s = l.offset as u32;
            let e = (l.offset + l.len) as u32;
            start = Some(start.map_or(s, |x| x.min(s)));
            end = Some(end.map_or(e, |x| x.max(e)));
        }
    }
    if let (Some(s), Some(e)) = (start, end) {
        let span = Locate {
            offset: s as usize,
            line: 0,
            len: (e - s) as usize,
        };
        if let Some(text) = tree.get_str(&span) {
            let t = text.trim().to_string();
            if !t.is_empty() {
                return Some(t);
            }
        }
    }
    for node in expr {
        if let RefNode::Locate(l) = node {
            if let Some(s) = tree.get_str(l) {
                let t = s.trim();
                if !t.is_empty() && t != "(" && t != ")" {
                    return Some(t.to_string());
                }
            }
        }
    }
    None
}

fn merge_case_item_meta(
    tree: &SyntaxTree,
    line_index: &LineIndex,
    path_str: &str,
    bytes: &[u8],
    item: &sv_parser::CaseItem,
    selector: Option<&str>,
    out: &mut BTreeMap<u32, CaseAssignMeta>,
) {
    let (labels, is_default) = match item {
        sv_parser::CaseItem::NonDefault(nd) => {
            let labs = case_item_labels(tree, bytes, &nd.nodes.0);
            (labs, false)
        }
        sv_parser::CaseItem::Default(_) => (Vec::new(), true),
    };
    let assigns: Vec<OpExtract> = match item {
        sv_parser::CaseItem::NonDefault(nd) => {
            collect_assigns_only(tree, line_index, path_str, bytes, nd.as_ref())
        }
        sv_parser::CaseItem::Default(d) => {
            collect_assigns_only(tree, line_index, path_str, bytes, d.as_ref())
        }
    };
    for a in assigns {
        out.insert(
            a.loc.start_line,
            CaseAssignMeta {
                labels: labels.clone(),
                is_default,
                selector: selector.map(|s| s.to_string()),
            },
        );
    }
}

fn case_item_labels(
    tree: &SyntaxTree,
    bytes: &[u8],
    list: &sv_parser::List<sv_parser::Symbol, sv_parser::CaseItemExpression>,
) -> Vec<String> {
    let mut labs = Vec::new();
    for cie in list.contents() {
        if let Some(t) = case_item_expression_text(tree, bytes, cie) {
            labs.push(t);
        }
    }
    labs
}

fn case_item_expression_text(
    tree: &SyntaxTree,
    _bytes: &[u8],
    cie: &sv_parser::CaseItemExpression,
) -> Option<String> {
    let mut start: Option<u32> = None;
    let mut end: Option<u32> = None;
    for node in cie {
        if let RefNode::Locate(l) = node {
            let s = l.offset as u32;
            let e = (l.offset + l.len) as u32;
            start = Some(start.map_or(s, |x| x.min(s)));
            end = Some(end.map_or(e, |x| x.max(e)));
        }
    }
    if let (Some(s), Some(e)) = (start, end) {
        let span = Locate {
            offset: s as usize,
            line: 0,
            len: (e - s) as usize,
        };
        if let Some(text) = tree.get_str(&span) {
            let t = text.trim().to_string();
            if !t.is_empty() {
                return Some(t);
            }
        }
    }
    for node in cie {
        if let RefNode::Locate(l) = node {
            if let Some(s) = tree.get_str(l) {
                let t = s.trim();
                if !t.is_empty() {
                    return Some(t.to_string());
                }
            }
        }
    }
    None
}

fn collect_assigns_only<'a, T>(
    tree: &'a SyntaxTree,
    line_index: &LineIndex,
    path_str: &str,
    bytes: &[u8],
    root: T,
) -> Vec<OpExtract>
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    let mut assigns = Vec::new();
    for node in root {
        match node {
            RefNode::NetAssignment(na) => {
                if let Some(a) = assign_lhs_rhs(
                    tree,
                    line_index,
                    path_str,
                    bytes,
                    na,
                    AssignKind::Continuous,
                ) {
                    assigns.push(a);
                }
            }
            RefNode::VariableAssignment(va) => {
                if let Some(a) =
                    assign_lhs_rhs(tree, line_index, path_str, bytes, va, AssignKind::Blocking)
                {
                    assigns.push(a);
                }
            }
            RefNode::BlockingAssignment(ba) => {
                if let Some(a) =
                    assign_lhs_rhs(tree, line_index, path_str, bytes, ba, AssignKind::Blocking)
                {
                    assigns.push(a);
                }
            }
            RefNode::NonblockingAssignment(nba) => {
                if let Some(a) = assign_lhs_rhs(
                    tree,
                    line_index,
                    path_str,
                    bytes,
                    nba,
                    AssignKind::Nonblocking,
                ) {
                    assigns.push(a);
                }
            }
            _ => {}
        }
    }
    assigns
}

/// Best-effort LHS/RHS from an assignment-like node via raw source bytes.
fn assign_lhs_rhs<'a, T>(
    tree: &'a SyntaxTree,
    line_index: &LineIndex,
    path_str: &str,
    bytes: &[u8],
    root: T,
    assign_kind: AssignKind,
) -> Option<OpExtract>
where
    T: IntoIterator<Item = RefNode<'a>> + Copy,
{
    let mut loc = first_locate_loc(tree, line_index, path_str, root);
    let mut assign_kind = assign_kind;
    let mut start: Option<u32> = None;
    let mut end: Option<u32> = None;
    for node in root {
        if let RefNode::Locate(l) = node {
            let s = l.offset as u32;
            let e = (l.offset + l.len) as u32;
            start = Some(start.map_or(s, |x| x.min(s)));
            end = Some(end.map_or(e, |x| x.max(e)));
        }
    }
    let (lhs, rhs) = if let (Some(s), Some(e)) = (start, end) {
        let span = Locate {
            offset: s as usize,
            line: 0,
            len: (e - s) as usize,
        };
        let text = tree.get_str(&span)?;
        let clean = blank_sv_comments(text);
        if assign_kind == AssignKind::Blocking && compound_assign_parts(&clean).is_some() {
            assign_kind = AssignKind::BlockingCompound;
        }
        let source_start = loc.byte_start as usize;
        if loc.origin == OriginKind::UserFile
            && bytes.get(source_start..source_start + text.len()) != Some(text.as_bytes())
        {
            loc.origin = OriginKind::ExpandedMacro;
        }
        let (lhs, rhs) = split_assign_text(&clean);
        (
            lhs.map(|s| blank_sv_comments(&s)),
            rhs.map(|s| blank_sv_comments(&s)),
        )
    } else {
        (None, None)
    };
    if lhs.is_none() && rhs.is_none() {
        return None;
    }
    Some(OpExtract {
        op_class: OperatorClass::Other,
        loc,
        lhs,
        rhs,
        case_labels: Vec::new(),
        case_is_default: false,
        case_selector: None,
        assign_kind,
        guards: Vec::new(),
    })
}

fn split_assign_text(text: &str) -> (Option<String>, Option<String>) {
    let t = text.trim().trim_end_matches(';').trim();
    if let Some((lhs, op, rhs)) = compound_assign_parts(t) {
        return (Some(lhs.to_string()), Some(format!("{lhs} {op} ({rhs})")));
    }
    // NBA first
    if let Some((l, r)) = t.split_once("<=") {
        return (Some(l.trim().to_string()), Some(r.trim().to_string()));
    }
    if let Some((l, r)) = t.split_once('=') {
        // avoid ==
        if !l.ends_with('=') && !l.ends_with('!') && !l.ends_with('<') && !l.ends_with('>') {
            return (Some(l.trim().to_string()), Some(r.trim().to_string()));
        }
    }
    (None, Some(t.to_string()))
}

/// Recover a compound operator immediately before the assignment's `=`.
/// Keep the original source intact; only the measurement RHS is expanded.
fn compound_assign_parts(text: &str) -> Option<(&str, &str, &str)> {
    let t = text.trim().trim_end_matches(';').trim();
    let mut depth = 0i32;
    let equal = t.char_indices().find_map(|(i, c)| {
        match c {
            '(' | '[' | '{' => depth += 1,
            ')' | ']' | '}' => depth -= 1,
            '=' if depth == 0 => return Some(i),
            _ => {}
        }
        None
    })?;
    let (left, right) = (&t[..equal], &t[equal + 1..]);
    if right.starts_with('=') {
        return None;
    }
    let left = left.trim_end();
    for op in [
        "<<<", ">>>", "<<", ">>", "+", "-", "*", "/", "%", "&", "|", "^",
    ] {
        if let Some(lhs) = left.strip_suffix(op) {
            let lhs = lhs.trim();
            if !lhs.is_empty() {
                return Some((lhs, op, right.trim()));
            }
        }
    }
    None
}

/// True when a CST operator token sits inside a `//` / `/*` comment.
///
/// PASS-STRATEGY P2: skip **every** operator in comments, not only `/` and `*`.
/// `te_priority.sv:139` billed 56 FO4 on `/*|| (` (`||` and `*` inside a block
/// comment); `cva6_shared_tlb.sv:260` billed 136 FO4 on a trailing `//`
/// continuation. Restricting the skip to slash tokens left those interiors live.
///
/// Spans are in **original-source** coordinates (through `get_origin`), the
/// same frame `locate_to_source` gives operator tokens. Raw parser offsets
/// address preprocessed text, which the preprocessor shifts (comments,
/// `ifdef`, macros) — a header comment alone was enough to leave every
/// `[N-1:0]` port range billed as a 10 FO4 adder in instance-only wrappers
/// (`stream_arbiter`: three port dims → a 30 FO4 "path").
fn lrm_constant_spans<'a, T>(tree: &'a SyntaxTree, li: &LineIndex, root: T) -> Vec<(u32, u32)>
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    let mut out = Vec::new();
    for node in root {
        let span = match node {
            RefNode::PackedDimension(x) => origin_byte_span(tree, li, x),
            RefNode::PackedDimensionRange(x) => origin_byte_span(tree, li, x),
            RefNode::UnpackedDimension(x) => origin_byte_span(tree, li, x),
            RefNode::UnpackedDimensionRange(x) => origin_byte_span(tree, li, x),
            RefNode::CaseItemExpression(x) => origin_byte_span(tree, li, x),
            // `[msb:lsb]` / constant `+:`/`-:` — both sides are constant expressions.
            RefNode::ConstantRange(x) => origin_byte_span(tree, li, x),
            RefNode::ConstantIndexedRange(x) => origin_byte_span(tree, li, x),
            // Indexed `[base +: width]` / `[base -: width]`: width only (base may be runtime).
            RefNode::IndexedRange(x) => origin_byte_span(tree, li, &x.nodes.2),
            // `{count{body}}`: count is LRM-constant; body may be datapath.
            RefNode::MultipleConcatenation(x) => origin_byte_span(tree, li, &x.nodes.0.nodes.1 .0),
            RefNode::ConstantMultipleConcatenation(x) => {
                origin_byte_span(tree, li, &x.nodes.0.nodes.1 .0)
            }
            // Generate-for header (init / condition / step) is elaboration-constant.
            RefNode::GenvarInitialization(x) => origin_byte_span(tree, li, x),
            RefNode::GenvarExpression(x) => origin_byte_span(tree, li, x),
            RefNode::GenvarIteration(x) => origin_byte_span(tree, li, x),
            // if-generate / case-generate conditions, not the body.
            RefNode::IfGenerateConstruct(x) => origin_byte_span(tree, li, &x.nodes.1.nodes.1),
            RefNode::CaseGenerateConstruct(x) => origin_byte_span(tree, li, &x.nodes.1.nodes.1),
            // Parameter / localparam defaults and typedef bodies are elaboration
            // constants (IEEE 1800-2017 §6.20, §6.18), never datapath.
            RefNode::ParameterDeclaration(x) => origin_byte_span(tree, li, x),
            RefNode::LocalParameterDeclaration(x) => origin_byte_span(tree, li, x),
            RefNode::ParameterPortList(x) => origin_byte_span(tree, li, x),
            RefNode::TypeDeclaration(x) => origin_byte_span(tree, li, x),
            _ => None,
        };
        if let Some(s) = span {
            out.push(s);
        }
    }
    out
}

/// First/last token of `root` mapped to original-source byte offsets. `None`
/// when either boundary comes from an include or a macro (the caller then
/// leaves the operator billed, the conservative direction).
fn origin_byte_span<'a, T>(tree: &'a SyntaxTree, li: &LineIndex, root: T) -> Option<(u32, u32)>
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    let mut first = None;
    let mut last = None;
    for node in root {
        if let RefNode::Locate(loc) = node {
            if loc.len > 0 {
                first.get_or_insert(loc);
                last = Some(loc);
            }
        }
    }
    let (first, last) = (first?, last?);
    let (fpath, start) = tree.get_origin(first)?;
    let (lpath, stop) = tree.get_origin(last)?;
    if fpath != &li.path || lpath != &li.path || stop < start {
        return None;
    }
    Some((start as u32, (stop + last.len) as u32))
}

fn locate_byte_span<'a, T>(root: T) -> Option<(u32, u32)>
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    let mut start: Option<u32> = None;
    let mut end: Option<u32> = None;
    for node in root {
        if let RefNode::Locate(l) = node {
            let s = l.offset as u32;
            let e = (l.offset + l.len) as u32;
            start = Some(start.map_or(s, |x| x.min(s)));
            end = Some(end.map_or(e, |x| x.max(e)));
        }
    }
    Some((start?, end?))
}

fn loc_in_spans(loc: &SourceLoc, spans: &[(u32, u32)]) -> bool {
    let i = loc.byte_start;
    spans.iter().any(|&(s, e)| i >= s && i < e)
}

fn operator_token_in_comment(bytes: &[u8], loc: &SourceLoc) -> bool {
    let i = loc.byte_start as usize;
    if i >= bytes.len() {
        return false;
    }
    byte_offset_in_comment(bytes, i)
}

/// Replace `//` / `/* */` interiors with spaces (newlines kept) so Expr parse
/// and `rhs_has_mul_not_pow` cannot see comment operators.
fn blank_sv_comments(text: &str) -> String {
    let b = text.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut in_line = false;
    let mut in_block = false;
    let mut in_string = false;
    let mut k = 0usize;
    while k < b.len() {
        let c = b[k];
        let n = b.get(k + 1).copied();
        if in_line {
            if c == b'\n' {
                in_line = false;
                out.push(c);
            } else {
                out.push(b' ');
            }
            k += 1;
            continue;
        }
        if in_block {
            if c == b'*' && n == Some(b'/') {
                in_block = false;
                out.push(b' ');
                out.push(b' ');
                k += 2;
                continue;
            }
            out.push(if c == b'\n' { b'\n' } else { b' ' });
            k += 1;
            continue;
        }
        if in_string {
            out.push(c);
            if c == b'\\' {
                if let Some(nx) = n {
                    out.push(nx);
                    k += 2;
                    continue;
                }
            }
            if c == b'"' {
                in_string = false;
            }
            k += 1;
            continue;
        }
        if c == b'/' && n == Some(b'/') {
            in_line = true;
            out.push(b' ');
            out.push(b' ');
            k += 2;
            continue;
        }
        if c == b'/' && n == Some(b'*') {
            in_block = true;
            out.push(b' ');
            out.push(b' ');
            k += 2;
            continue;
        }
        if c == b'"' {
            in_string = true;
        }
        out.push(c);
        k += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Comment/string-aware scan from the start of `bytes` up to `i`.
fn byte_offset_in_comment(bytes: &[u8], i: usize) -> bool {
    let mut in_line = false;
    let mut in_block = false;
    let mut in_string = false;
    let mut in_char = false;
    let mut k = 0usize;
    while k < i && k < bytes.len() {
        let c = bytes[k];
        let n = bytes.get(k + 1).copied();
        if in_line {
            if c == b'\n' {
                in_line = false;
            }
            k += 1;
            continue;
        }
        if in_block {
            if c == b'*' && n == Some(b'/') {
                in_block = false;
                k += 2;
                continue;
            }
            k += 1;
            continue;
        }
        if in_string {
            if c == b'\\' {
                k += 2;
                continue;
            }
            if c == b'"' {
                in_string = false;
            }
            k += 1;
            continue;
        }
        if in_char {
            if c == b'\\' {
                k += 2;
                continue;
            }
            if c == b'\'' {
                in_char = false;
            }
            k += 1;
            continue;
        }
        if c == b'/' && n == Some(b'/') {
            in_line = true;
            k += 2;
            continue;
        }
        if c == b'/' && n == Some(b'*') {
            in_block = true;
            k += 2;
            continue;
        }
        if c == b'"' {
            in_string = true;
            k += 1;
            continue;
        }
        k += 1;
    }
    in_line || in_block
}

/// True when RHS has a datapath `*`, not `**` power or `*'` sized-cast.
fn rhs_has_mul_not_pow(rhs: &str) -> bool {
    let b = rhs.as_bytes();
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'*' {
            let prev = if i > 0 { b[i - 1] } else { 0 };
            let next = b.get(i + 1).copied().unwrap_or(0);
            if prev != b'*' && next != b'*' && next != b'\'' {
                return true;
            }
            if next == b'*' || next == b'\'' {
                i += 1;
            }
        }
        i += 1;
    }
    false
}

fn classify_binary(sym: &str) -> OperatorClass {
    match sym.trim() {
        "+" | "-" => OperatorClass::AddSub,
        "*" => OperatorClass::Mul,
        "**" => OperatorClass::ShiftConst,
        "/" | "%" => OperatorClass::DivRem,
        "<<" | ">>" | "<<<" | ">>>" => OperatorClass::ShiftConst,
        "==" | "!=" | "===" | "!==" | "<" | ">" | "<=" | ">=" => OperatorClass::Compare,
        "&" | "|" | "^" | "~^" | "^~" | "&&" | "||" => OperatorClass::LogicBit,
        "?" => OperatorClass::Mux,
        _ => OperatorClass::Other,
    }
}

fn first_locate_loc<'a, T>(
    tree: &'a SyntaxTree,
    line_index: &LineIndex,
    path_str: &str,
    root: T,
) -> SourceLoc
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    for node in root {
        if let RefNode::Locate(loc) = node {
            return locate_to_source(tree, line_index, path_str, loc);
        }
    }
    SourceLoc {
        file: path_str.into(),
        start_line: 1,
        start_col: 1,
        end_line: 1,
        end_col: 1,
        byte_start: 0,
        byte_end: 0,
        origin: OriginKind::UserFile,
    }
}

fn locate_to_source(
    tree: &SyntaxTree,
    line_index: &LineIndex,
    path_str: &str,
    loc: &Locate,
) -> SourceLoc {
    // Prefer origin map from preprocessor when available (via line_index path).
    let (start, origin) = match tree.get_origin(loc) {
        Some((path, offset)) if path == &line_index.path => (offset as u32, OriginKind::UserFile),
        Some(_) => (loc.offset as u32, OriginKind::IncludeExpanded),
        None => (loc.offset as u32, OriginKind::ExpandedMacro),
    };
    let end = start.saturating_add(loc.len as u32);
    let mut s = line_index.span(start, end, origin);
    // Keep display path consistent with file path string.
    s.file = path_str.to_string();
    // sv-parser Locate.line is 1-based in preprocessed text; prefer line_index when possible.
    if s.start_line == 0 {
        s.start_line = loc.line as u32;
        s.end_line = loc.line as u32;
    }
    s
}

fn sanitize_stem(path: &str) -> String {
    Path::new(path)
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "unit".into())
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cost_table::default_fo4_v1_embedded;
    use crate::measure::rank_paths_by_slack;
    use std::path::PathBuf;

    fn fixture(name: &str) -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures")
            .join(name)
    }

    fn analyze_inline_source(text: &str) -> AnalyzeOutput {
        analyze_inline_with_options(text, &LowerOptions::default())
    }

    #[test]
    fn compound_updates_keep_the_read_dependency_and_refuse_automatic_rewrites() {
        for op in ["+", "|"] {
            let source = |update: &str| {
                format!(
                    "module m(input logic clk_i, input logic [7:0] a, output logic [7:0] q);
                 logic [7:0] acc;
                 always_comb begin
                   acc='0;
                   for(int i=0;i<8;i++) begin {update} end
                 end
                 always_ff @(posedge clk_i) q<=acc;
                 endmodule"
                )
            };
            let plain = analyze_inline_source(&source(&format!("acc = acc {op} a;")));
            let compound = analyze_inline_source(&source(&format!("acc {op}= a;")));
            let p = plain
                .design
                .modules
                .values()
                .next()
                .unwrap()
                .nodes
                .values()
                .find(|n| {
                    n.lhs.as_deref() == Some("acc")
                        && n.rhs.as_deref().is_some_and(|r| r.contains("acc"))
                })
                .unwrap();
            let c = compound
                .design
                .modules
                .values()
                .next()
                .unwrap()
                .nodes
                .values()
                .find(|n| n.assign_kind == AssignKind::BlockingCompound)
                .unwrap();
            assert_eq!(c.lhs.as_deref(), Some("acc"));
            assert!(c.rhs.as_deref().unwrap().contains("acc"));
            assert!(c.assign_kind.is_comb_def());
            assert!(
                (p.fo4_cost - c.fo4_cost).abs() < 1e-9,
                "{} vs {}",
                p.fo4_cost,
                c.fo4_cost
            );
            assert!(!compound.design.opportunities.iter().any(|o| {
                compound
                    .design
                    .paths
                    .iter()
                    .any(|p| p.id == o.path_id && p.nodes.contains(&c.id))
            }));
        }
        assert_eq!(
            compound_assign_parts("a[i==j]<<=b;"),
            Some(("a[i==j]", "<<", "b"))
        );
        assert!(compound_assign_parts("q <= a;").is_none());
        let with_comment = analyze_inline_source(
            "module m(input logic a, output logic q);
             always_comb begin q='0; q /* note: x = y */ |= a; end
             endmodule",
        );
        assert!(with_comment
            .design
            .modules
            .values()
            .next()
            .unwrap()
            .nodes
            .values()
            .any(
                |n| n.lhs.as_deref() == Some("q") && n.assign_kind == AssignKind::BlockingCompound
            ));
    }

    fn analyze_inline_with_options(text: &str, options: &LowerOptions) -> AnalyzeOutput {
        let path = PathBuf::from("origin_test.sv");
        let defines: sv_parser::Defines = Default::default();
        let (tree, _) =
            sv_parser::parse_sv_str(text, &path, &defines, &[] as &[PathBuf], false, false)
                .expect("parse inline source");
        let file = ParsedFile {
            path: path.clone(),
            bytes: text.as_bytes().to_vec(),
            line_index: LineIndex::from_bytes(path, text.as_bytes()),
            tree,
        };
        lower_unit(
            &ParsedUnit {
                files: vec![file],
                skipped: vec![],
            },
            options,
        )
        .expect("lower inline source")
    }

    #[test]
    fn generate_reachability_requires_explicit_facts_and_keeps_unknown_branches() {
        let src = r#"
package cfg_pkg;
  typedef struct packed { int unsigned XLEN; } cfg_t;
endpackage
module m #(parameter cfg_pkg::cfg_t Cfg = '{XLEN:64})
          (input logic [31:0] a,b, output logic [31:0] y);
  if (Cfg.XLEN > 0) begin : active
    localparam int unsigned NS = Cfg.XLEN / 16;
    if (NS == 4) begin : four
      assign y = a + b;
    end else if (NS == 2) begin : two
      assign y = a * b;
    end else begin : other
      always_comb begin
        y = a / b;
        for (int i=0;i<16;i++) y = y + b;
      end
    end
  end else begin : zero
    assign y = a - b;
  end
endmodule
"#;
        let unknown = analyze_inline_source(src);
        let unknown_m = unknown.design.modules.values().next().unwrap();
        assert!(unknown_m
            .nodes
            .values()
            .any(|n| n.rhs.as_deref() == Some("a / b")));
        let mut opts = LowerOptions::default();
        opts.param_map.insert("Cfg.XLEN", serde_json::json!(64));
        let known = analyze_inline_with_options(src, &opts);
        let m = known.design.modules.values().next().unwrap();
        let rhs: Vec<_> = m.nodes.values().filter_map(|n| n.rhs.as_deref()).collect();
        assert_eq!(rhs, vec!["a + b"], "{rhs:?}");
        assert!(
            m.gen_loops.is_empty(),
            "dead fallback's loop must not survive"
        );
        opts.param_map.insert("Cfg.XLEN", serde_json::json!(32));
        let other = analyze_inline_with_options(src, &opts);
        let rhs: Vec<_> = other
            .design
            .modules
            .values()
            .next()
            .unwrap()
            .nodes
            .values()
            .filter_map(|n| n.rhs.as_deref())
            .collect();
        assert_eq!(rhs, vec!["a * b"], "{rhs:?}");
    }

    #[test]
    fn generate_reachability_resolves_conditional_slice_count() {
        let src = r#"
package cfg_pkg;
  typedef struct packed { int unsigned XLEN; int unsigned Stages; } cfg_t;
endpackage
module m #(parameter cfg_pkg::cfg_t Cfg = '{64,3})
          (input logic [31:0] a,b, output logic [31:0] y);
  localparam int unsigned SB = Cfg.Stages > 2 ? 8 : 16;
  localparam int unsigned NS = Cfg.XLEN / SB;
  if (NS == 8) assign y = a + b;
  else if (NS == 4) assign y = a * b;
  else assign y = a / b;
endmodule
"#;
        let mut opts = LowerOptions::default();
        opts.param_map.insert("Cfg.XLEN", serde_json::json!(64));
        for (stages, expected) in [(3, "a + b"), (2, "a * b")] {
            opts.param_map
                .insert("Cfg.Stages", serde_json::json!(stages));
            let out = analyze_inline_with_options(src, &opts);
            let m = out.design.modules.values().next().unwrap();
            let rhs: Vec<_> = m.nodes.values().filter_map(|n| n.rhs.as_deref()).collect();
            assert_eq!(rhs, vec![expected]);
        }
        let unknown = analyze_inline_source(src);
        assert!(unknown
            .design
            .modules
            .values()
            .next()
            .unwrap()
            .nodes
            .values()
            .any(|n| n.rhs.as_deref() == Some("a / b")));
    }

    #[test]
    fn generate_reachability_refuses_truncation_defaults_and_shadowing() {
        for decl in [
            "parameter int N=4;",
            "localparam logic [1:0] N=4;",
            "localparam int unsigned N=2147483647+1;",
            "localparam int N=-1;",
            "localparam int N=1 ? 4 : 2147483647+1;",
            "localparam int N=1/0;",
            "localparam int N=1'bx;",
        ] {
            let src = format!(
                "module m(input logic a,b, output logic y); {decl}
                 if (N==4) assign y=a; else assign y=b; endmodule"
            );
            let out = analyze_inline_source(&src);
            let m = out.design.modules.values().next().unwrap();
            assert_eq!(
                m.nodes
                    .values()
                    .filter(|n| n.lhs.as_deref() == Some("y"))
                    .count(),
                2,
                "{decl}"
            );
        }
        let shadowed = r#"
module m #(parameter int MODE=0)(input logic a,b,output logic y);
 if (MODE) begin:g
   localparam int N=4;
   if(N==4) assign y=a; else assign y=b;
 end else begin:h
   localparam int N=2;
   if(N==4) assign y=a; else assign y=b;
 end
endmodule
"#;
        let out = analyze_inline_source(shadowed);
        let m = out.design.modules.values().next().unwrap();
        assert_eq!(
            m.nodes
                .values()
                .filter(|n| n.lhs.as_deref() == Some("y"))
                .count(),
            4
        );
        let narrow = "module m(input logic a,b,output logic y);
            if ((1'b1 + 1'b1) == 1'b0) assign y=a; else assign y=b;
            endmodule";
        let out = analyze_inline_source(narrow);
        assert_eq!(
            out.design
                .modules
                .values()
                .next()
                .unwrap()
                .nodes
                .values()
                .filter(|n| n.lhs.as_deref() == Some("y"))
                .count(),
            2
        );
        let runtime = "module m(input logic cfg,a,b,output logic y);
            if (cfg) assign y=a; else assign y=b; endmodule";
        let mut opts = LowerOptions::default();
        opts.param_map.insert("cfg", serde_json::json!(0));
        let out = analyze_inline_with_options(runtime, &opts);
        assert_eq!(
            out.design
                .modules
                .values()
                .next()
                .unwrap()
                .nodes
                .values()
                .filter(|n| n.lhs.as_deref() == Some("y"))
                .count(),
            2
        );
    }

    #[test]
    fn dead_generate_does_not_reappear_through_fallback_or_instance_stitch() {
        let src = r#"
module child(input logic a,output logic y); assign y=~a; endmodule
module m(input logic clk,a,output logic q,y);
 if (0) begin:gone
   child u(.a(a),.y(y));
   always_ff @(posedge clk) q<=a;
 end
endmodule
"#;
        let out = analyze_inline_source(src);
        let m = out.design.modules.values().find(|m| m.name == "m").unwrap();
        assert!(m.nodes.is_empty(), "{:?}", m.nodes);
        assert!(m.regions.is_empty());
        assert!(m.instances.is_empty());
        assert!(!out.design.instances.iter().any(|i| i.parent_name == "m"));
    }

    /// multiplier A115 shape: a `logic` *array* declared inside a conditional
    /// generate block, written by a nested genvar loop and read in a nested
    /// generate-if; a hoisted feed must not name it (`term`, A116 emit).
    #[test]
    fn decl_sites_flag_generate_block_arrays_as_local() {
        let text = concat!(
            "module gen_arr(input logic [63:0] a, output logic [63:0] y);
",
            "localparam int unsigned NS = 4;
",
            "if (NS > 1) begin : gen_two
",
            "  logic signed [65:0] term[NS];
",
            "  for (genvar k = 0; k < NS; k++) begin : gen_term
",
            "    assign term[k] = 66'(a) <<< (16 * k);
",
            "  end
",
            "  if (NS == 4) begin : gen_sum4
",
            "    assign y = 64'((term[0] + term[1]) + (term[2] + term[3]));
",
            "  end
",
            "end else begin : gen_one
",
            "  assign y = a;
",
            "end
",
            "endmodule
",
        );
        let out = analyze_inline_source(text);
        let module = out
            .design
            .modules
            .values()
            .find(|m| m.name == "gen_arr")
            .unwrap();
        let term = module.decls.iter().find(|d| d.name == "term");
        assert_eq!(
            term.map(|d| d.block_local),
            Some(true),
            "{:?}",
            module.decls
        );
        let set = module.block_local_names();
        assert!(module.text_refs_block_local("(term[0] + term[1]) + (term[2] + term[3])", &set));
    }

    #[test]
    fn decl_sites_flag_block_locals_and_loop_variables() {
        // perf_counters shape: `automatic logic brh` inside `for … always_comb`,
        // `h` the loop variable; wt_dcache shape: `wire cmo_req` under a
        // generate-if. `ev`, `gated` and `y` are module-level. An emitted
        // module-scope snippet may name the latter three only.
        let text = concat!(
            "module origin_test(input logic [1:0] x, input logic [3:0] hid, output logic [1:0] y);\n",
            "logic [1:0] ev;\n",
            "logic gated;\n",
            "always_comb begin\n",
            "  ev = '0;\n",
            "  for (int unsigned h = 0; h < 2; h++) begin\n",
            "    automatic logic brh = (hid == 4'(h));\n",
            "    ev[h] = x[h] & brh;\n",
            "  end\n",
            "end\n",
            "if (1) begin : gen_cmo\n",
            "  wire cmo_req = x[0] & hid[0];\n",
            "  assign gated = cmo_req;\n",
            "end\n",
            "assign y = ev;\n",
            "endmodule\n",
        );
        let out = analyze_inline_source(text);
        let module = out
            .design
            .modules
            .values()
            .find(|m| m.name == "origin_test")
            .unwrap();
        let local = |name: &str| {
            module
                .decls
                .iter()
                .find(|d| d.name == name)
                .map(|d| d.block_local)
        };
        assert_eq!(
            local("brh"),
            Some(true),
            "automatic inside the block is local"
        );
        assert_eq!(local("h"), Some(true), "for loop variable is local");
        assert_eq!(local("ev"), Some(false), "module-level variable is visible");
        let set = module.block_local_names();
        assert!(
            set.contains("brh") && set.contains("h") && !set.contains("ev"),
            "{set:?}"
        );
        assert!(set.contains("cmo_req"), "generate-local net: {set:?}");
        assert!(!set.contains("gated"), "{set:?}");
        assert!(module.text_refs_block_local("&brh", &set));
        assert!(module.text_refs_block_local("ev[h]", &set));
        assert!(module.text_refs_block_local("a && !cmo_req", &set));
        assert!(!module.text_refs_block_local("x[1] & ev[0]", &set));
        assert!(!module.text_refs_block_local("pkg::BRH", &set));
        assert!(!module.text_refs_block_local("pkg::brh", &set));
        assert!(!module.text_refs_block_local("request.brh", &set));
        assert!(!module.text_refs_block_local("request . brh", &set));
        assert!(module.text_refs_block_local("brh.member", &set));
        assert!(module.text_refs_block_local("pkg::fn(brh)", &set));
        assert!(module.text_refs_block_local("data[brh:0]", &set));
        assert!(module.text_refs_block_local("brh'(data)", &set));
    }

    #[test]
    fn preprocessing_preserves_assignment_text_and_original_anchor() {
        let text = "`ifdef OMITTED\n////////////////////////////\nwire unused;\n`endif\nmodule origin_test(input logic [31:0] a, b, output logic [31:0] y);\nassign y = a / b;\nendmodule\n";
        let out = analyze_inline_source(text);
        let module = out
            .design
            .modules
            .values()
            .find(|m| m.name == "origin_test")
            .unwrap();
        let node = module
            .nodes
            .values()
            .find(|n| n.lhs.as_deref() == Some("y"))
            .expect("assignment must survive preprocessing");
        assert_eq!(node.rhs.as_deref(), Some("a / b"));
        assert_eq!(node.op_class, Some(OperatorClass::DivRem));
        assert_eq!(node.loc.start_line, 6);
        assert!(text[node.loc.byte_start as usize..].starts_with('y'));
    }

    #[test]
    fn port_dims_and_parameters_are_not_datapath_after_a_header_comment() {
        // stream_arbiter shape: `[N-1:0]` port ranges, a localparam, and only
        // an instance (no always/assign) behind a string-default parameter
        // whose trailing comment quotes strings. The preprocessor shifts its
        // output by 22 bytes after that line, so raw parser offsets no longer
        // address the source: the fallback scan used to bill three 10 FO4
        // adders for the port dims. Spans are compared in origin coordinates.
        let text = concat!(
            "// Copyright 2018 ETH Zurich and University of Bologna.\n",
            "// Licensed under Solderpad 0.51; see the License for details.\n",
            "module wrap #(parameter int unsigned N = 2, parameter int W = N * 8,\n",
            "    parameter           ARBITER = \"rr\"    // \"rr\" or \"prio\"\n",
            ") (\n",
            "  input  logic [N-1:0]   valid_i,\n",
            "  input  logic [W-1:0]   data_i [N-1:0],\n",
            "  output logic [N-1:0]   ready_o,\n",
            "  output logic [W/2-1:0] data_o\n",
            ");\n",
            "  localparam int unsigned IDX_W = (N > 1) ? $clog2(N) : 1;\n",
            "  typedef logic [IDX_W-1:0] idx_t;\n",
            "  leaf #(.N(N), .W(W)) i_leaf (.valid_i, .data_i, .ready_o, .data_o);\n",
            "endmodule\n",
            "module leaf #(parameter int unsigned N = 2, parameter int W = 16) (\n",
            "  input  logic [N-1:0]   valid_i,\n",
            "  input  logic [W-1:0]   data_i [N-1:0],\n",
            "  output logic [N-1:0]   ready_o,\n",
            "  output logic [W/2-1:0] data_o\n",
            ");\n",
            "  assign ready_o = valid_i;\n",
            "  assign data_o = data_i[0][W/2-1:0] + data_i[1][W/2-1:0];\n",
            "endmodule\n",
        );
        let out = analyze_inline_source(text);
        let wrap = out
            .design
            .modules
            .values()
            .find(|m| m.name == "wrap")
            .expect("wrap module");
        assert!(
            wrap.nodes.is_empty(),
            "instance-only wrapper must have no datapath nodes, got {:?}",
            wrap.nodes
                .values()
                .map(|n| (&n.op_class, &n.loc.start_line))
                .collect::<Vec<_>>()
        );
        assert!(
            !out.design.paths.iter().any(|p| p.module == wrap.id),
            "no timing path may start in the wrapper's port/parameter constants"
        );
        let leaf = out
            .design
            .modules
            .values()
            .find(|m| m.name == "leaf")
            .expect("leaf module");
        // The leaf keeps its real adder: constant part-selects are not the datapath.
        assert!(
            leaf.nodes
                .values()
                .any(|n| n.op_class == Some(OperatorClass::AddSub)),
            "leaf adder must still be lowered"
        );
    }

    #[test]
    fn composed_paths_respect_local_shadowing_and_keep_global_connections() {
        let text = concat!(
            "module origin_test(input logic clk, input logic [31:0] a,b,c,\n",
            "output logic [31:0] y,z,outside,q);\n",
            "logic [31:0] tmp;\n",
            "assign tmp = a * b;\n",
            "always_comb begin : first\n",
            "  logic [31:0] tmp;\n",
            "  tmp = a + b;\n",
            "  y = tmp ^ c;\n",
            "end\n",
            "always_comb begin : second\n",
            "  logic [31:0] tmp;\n",
            "  tmp = a - c;\n",
            "  z = tmp ^ b;\n",
            "end\n",
            "assign outside = tmp;\n",
            "always_ff @(posedge clk) q <= y;\n",
            "endmodule\n",
        );
        let out = analyze_inline_source(text);
        let m = out.design.modules.values().next().unwrap();
        let find = |rhs: &str| {
            m.nodes
                .values()
                .find(|n| n.rhs.as_deref() == Some(rhs))
                .unwrap()
        };
        let global = find("a * b");
        let first = find("a + b");
        let second = find("a - c");
        let y = find("tmp ^ c");
        let z = find("tmp ^ b");
        let outside = m
            .nodes
            .values()
            .find(|n| n.lhs.as_deref() == Some("outside"))
            .unwrap();
        assert!(y.fans_in.contains(&first.id));
        assert!(!y.fans_in.contains(&second.id) && !y.fans_in.contains(&global.id));
        assert!(z.fans_in.contains(&second.id));
        assert!(!z.fans_in.contains(&first.id) && !z.fans_in.contains(&global.id));
        assert!(outside.fans_in.contains(&global.id));
        assert!(!outside.fans_in.contains(&second.id));
        let declarations: Vec<_> = m.decls.iter().filter(|d| d.name == "tmp").collect();
        assert_eq!(declarations.len(), 3);
        assert_eq!(declarations.iter().filter(|d| d.block_local).count(), 2);
        let nodes: Vec<_> = m.nodes.keys().copied().collect();
        let tree = crate::ref_order::RefOrderTree::from_nodes(m, &nodes);
        let linked = |from, to| {
            tree.edges
                .iter()
                .any(|e| nodes[e.from_stmt as usize] == from && nodes[e.to_stmt as usize] == to)
        };
        assert!(linked(first.id, y.id));
        assert!(linked(second.id, z.id));
        assert!(linked(global.id, outside.id));
        assert!(!linked(second.id, outside.id));
    }

    #[test]
    fn loop_constant_scope_uses_original_coordinates_after_preprocessing() {
        let body = concat!(
            "module origin_test(input logic [31:0] a, k, output logic [31:0] y);\n",
            "wire [31:0] row [0:1];\n",
            "for (genvar k = 0; k < 2; k++) begin : cells\n",
            "  assign row[k] = a + k;\n",
            "end\n",
            "assign y = a * k;\n",
            "endmodule\n",
        );
        let source = format!(
            "`ifdef REMOVED\n{}\n`endif\n{body}",
            "// padding\n".repeat(80)
        );
        for text in [body.to_string(), source] {
            let out = analyze_inline_source(&text);
            let m = out.design.modules.values().next().unwrap();
            let inside = m
                .nodes
                .values()
                .find(|n| n.lhs.as_deref() == Some("row[k]"))
                .unwrap();
            let outside = m
                .nodes
                .values()
                .find(|n| n.lhs.as_deref() == Some("y"))
                .unwrap();
            assert_eq!(m.genvar_names_at(&inside.loc), vec!["k"]);
            assert!(m.genvar_names_at(&outside.loc).is_empty());
            let mut unresolved = inside.loc.clone();
            unresolved.origin = OriginKind::IncludeExpanded;
            assert!(m.genvar_names_at(&unresolved).is_empty());
            let mut different_file = inside.loc.clone();
            different_file.file = "other.sv".into();
            assert!(m.genvar_names_at(&different_file).is_empty());
            // `a + k` with genvar `k`: a constant-offset incrementer (Compare
            // class, delay-v32), not the 10 FO4 CPA and not a 1 FO4 gate.
            assert_eq!(inside.fo4_cost, CostModel::default().compare);
            assert_eq!(outside.fo4_cost, CostModel::default().mul);
        }
    }

    /// delay-v35: the scoreboard cancel-range walk — a procedural `for` whose
    /// body reads and re-assigns `cid` — unrolls into NR_SB_ENTRIES serial
    /// copies; the structural cost of the loop-carried node is trip × body.
    /// A body node that only reads the loop variable is one copy.
    #[test]
    fn loop_carried_accumulator_costs_trip_count_times_body() {
        let text = concat!(
            "module m (input logic [4:0] after_i, ip_i, input logic [31:0] ok_i,
",
            "          input logic bmiss_i, output logic [31:0] mask_o, output logic [31:0] copy_o);
",
            "  localparam int unsigned N = 32;
",
            "  always_comb begin
",
            "    logic [4:0] cid;
",
            "    mask_o = '0;
",
            "    cid = after_i;
",
            "    for (int unsigned k = 0; k < N; k++) begin
",
            "      if (cid == ip_i) break;
",
            "      if (ok_i[cid]) mask_o[cid] = 1'b1;
",
            "      cid = cid + 1'b1;
",
            "    end
",
            "    for (int unsigned i = 0; i < N; i++) copy_o[i] = ok_i[i] & bmiss_i;
",
            "  end
",
            "endmodule
",
        );
        let out = analyze_inline_source(text);
        let m = out.design.modules.values().next().unwrap();
        let lp: Vec<_> = m.gen_loops.iter().filter(|g| g.procedural).collect();
        assert_eq!(lp.len(), 2, "{:?}", m.gen_loops);
        assert_eq!(lp[0].cond_text.as_deref(), Some("k < N"));
        assert_eq!(lp[0].init_text.as_deref(), Some("0"));
        let find = |lhs: &str, rhs_frag: &str| {
            m.nodes
                .values()
                .find(|n| {
                    n.lhs.as_deref() == Some(lhs)
                        && n.rhs.as_deref().is_some_and(|r| r.contains(rhs_frag))
                })
                .unwrap_or_else(|| panic!("node {lhs} = …{rhs_frag}…"))
        };
        let step = find("cid", "cid + 1'b1");
        let copy = find("copy_o[i]", "ok_i[i] & bmiss_i");
        let model = CostModel::default();
        // `cid + 1'b1` is a 5-bit incrementer (Compare class, log2-scaled);
        // an arithmetic self-accumulate stays serial in the mapped netlist
        // (scoreboard range walk: 32 steps, 144 cells, 14.7 ns), so the chain
        // is 32 copies. The mask write it feeds is one copy and inherits the
        // chain through the def-use path.
        let one = model.scaled_fo4(OperatorClass::Compare, Some(5));
        assert!(
            (step.fo4_cost - 32.0 * one).abs() < 1e-6,
            "arithmetic loop-carried step must cost trips × body: {} vs {}",
            step.fo4_cost,
            32.0 * one
        );
        // A bitwise self-accumulate is a balanced tree: log2(32) = 5 copies.
        let text_or = concat!(
            "module m3 (input logic [31:0] hit_i, output logic any_o);
",
            "  always_comb begin
",
            "    any_o = 1'b0;
",
            "    for (int unsigned k = 0; k < 32; k++) any_o = any_o | hit_i[k];
",
            "  end
",
            "endmodule
",
        );
        let out3 = analyze_inline_source(text_or);
        let m3 = out3.design.modules.values().next().unwrap();
        let acc = m3
            .nodes
            .values()
            .find(|n| n.rhs.as_deref() == Some("any_o | hit_i[k]"))
            .expect("or accumulate");
        assert!(
            (acc.fo4_cost - 5.0 * model.logic_bit).abs() < 1e-6,
            "{}",
            acc.fo4_cost
        );
        // The same accumulate written as a select — `c ? x ^ t : x` is
        // `x ^ (t & {c})` — is still a balanced XOR tree (the carry-less
        // multiply's 64-trip loop read 416 FO4 as a mux chain, delay-v39).
        let text_sel = concat!(
            "module m4 (input logic [63:0] a_i, b_i, output logic [63:0] clmul_o);
",
            "  always_comb begin
",
            "    clmul_o = '0;
",
            "    for (int i = 0; i < 64; i++) clmul_o = (|((b_i >> i) & 1)) ? clmul_o ^ (a_i << i) : clmul_o;
",
            "  end
",
            "endmodule
",
        );
        let out4 = analyze_inline_source(text_sel);
        let m4 = out4.design.modules.values().next().unwrap();
        let sel = m4
            .nodes
            .values()
            .find(|n| {
                n.rhs
                    .as_deref()
                    .is_some_and(|r| r.contains("clmul_o ^ (a_i << i)"))
            })
            .expect("select accumulate");
        // log2(64) = 6 copies of (shift, xor, select) — well under the 64
        // copies of the serial reading (416 FO4 on the multiplier)
        assert!(
            sel.fo4_cost < 6.0 * (model.shift_const + model.logic_bit + model.mux) + 8.0,
            "a guarded XOR accumulate as a select is log depth, not 64 copies: {}",
            sel.fo4_cost
        );
        // A non-associative loop-carried update (a priority mux chain) stays
        // serial: trips × body. (`if (cond) x = const` carries its cost in the
        // condition, which this model does not yet bill — see AGENTS-todo.)
        let text2 = concat!(
            "module m2 (input logic [31:0] hit_i, output logic [4:0] idx_o);
",
            "  always_comb begin
",
            "    idx_o = '0;
",
            "    for (int unsigned k = 0; k < 32; k++) idx_o = hit_i[k] ? 5'(k) : idx_o;
",
            "  end
",
            "endmodule
",
        );
        let out2 = analyze_inline_source(text2);
        let m2 = out2.design.modules.values().next().unwrap();
        let pick = m2
            .nodes
            .values()
            .find(|n| n.rhs.as_deref().is_some_and(|r| r.contains("hit_i[k] ?")))
            .expect("priority pick inside the loop");
        assert!(
            (pick.fo4_cost - 32.0 * model.mux).abs() < 1e-6,
            "serial priority chain must cost trips × mux: {}",
            pick.fo4_cost
        );
        assert!(
            (copy.fo4_cost - model.logic_bit).abs() < 1e-6,
            "a body node that only reads the loop var is one copy: {}",
            copy.fo4_cost
        );
    }

    #[test]
    fn procedural_loop_scope_survives_macro_expansion_before_loop() {
        let source = concat!(
            "`define DECL wire padding_a; wire padding_b; wire padding_c;\n",
            "module origin_test(input logic [31:0] a, output logic [31:0] y);\n",
            "`DECL\n",
            "always_comb begin\n",
            "  y = '0;\n",
            "  for (int k = 0; k < 2; k++) begin\n",
            "    y = a + k;\n",
            "  end\n",
            "end\n",
            "endmodule\n",
        );
        let out = analyze_inline_source(source);
        let m = out.design.modules.values().next().unwrap();
        let inside = m
            .nodes
            .values()
            .find(|n| n.rhs.as_deref() == Some("a + k"))
            .unwrap();
        assert_eq!(m.genvar_names_at(&inside.loc), vec!["k"]);
        assert_eq!(
            inside.fo4_cost,
            CostModel::default().compare,
            "incrementer class"
        );
    }

    #[test]
    fn macro_expansion_supplies_rhs_without_claiming_editable_origin() {
        let text = "`define OP a * b\nmodule origin_test(input logic [31:0] a, b, output logic [31:0] y);\nassign y = `OP;\nendmodule\n";
        let out = analyze_inline_source(text);
        let module = out
            .design
            .modules
            .values()
            .find(|m| m.name == "origin_test")
            .unwrap();
        let node = module
            .nodes
            .values()
            .find(|n| n.lhs.as_deref() == Some("y"))
            .expect("macro assignment");
        assert_eq!(node.rhs.as_deref(), Some("a * b"));
        assert_eq!(node.op_class, Some(OperatorClass::Mul));
        assert_ne!(node.loc.origin, OriginKind::UserFile);
    }

    #[test]
    fn lower_comb_adder_cloud() {
        let path = fixture("comb_adder_cloud.sv");
        if !path.exists() {
            return;
        }
        let mut opts = LowerOptions::default();
        opts.cost_model = default_fo4_v1_embedded();
        opts.module_filter = vec!["comb_adder_cloud".into()];
        let out = analyze_files(&[path], &ParseOptions::default(), &opts).expect("analyze");
        assert!(out
            .design
            .modules
            .values()
            .any(|m| m.name == "comb_adder_cloud"));
        assert!(
            !out.design.paths.is_empty(),
            "expected at least one path from + operators"
        );
        let ranked = rank_paths_by_slack(&out.design.paths, &out.design.target);
        assert!(!ranked.primary.is_empty());
        // Two adds in always_comb → FO4 ~ 20
        let p0 = &ranked.primary[0];
        assert!(
            p0.total_fo4 >= 10.0,
            "expected add costs, got {}",
            p0.total_fo4
        );
        assert!(
            !out.design.opportunities.is_empty() || p0.slack_fo4 >= 0.0,
            "either opportunity or positive slack"
        );
    }

    #[test]
    fn part_select_and_repl_const_arith_are_not_datapath() {
        let path = fixture("parse/part_select_const_arith.sv");
        if !path.exists() {
            return;
        }
        let mut opts = LowerOptions::default();
        opts.cost_model = default_fo4_v1_embedded();
        opts.target = crate::ir::TimingTarget::new(4000.0, 20.0, 0.2);
        opts.module_filter = vec!["part_select_const_arith".into()];
        let out = analyze_files(&[path], &ParseOptions::default(), &opts).expect("analyze");
        let m = out
            .design
            .modules
            .values()
            .find(|m| m.name == "part_select_const_arith")
            .expect("part_select_const_arith");
        let lhs_of = |want: &str| {
            m.nodes
                .values()
                .find(|n| n.lhs.as_deref().is_some_and(|s| s.contains(want)))
                .unwrap_or_else(|| panic!("missing lhs {want}"))
        };
        let slice = lhs_of("slice_o");
        assert!(
            slice.fo4_cost < 2.0,
            "HYP_EXT*2 slice billed {} class {:?} rhs={:?}",
            slice.fo4_cost,
            slice.op_class,
            slice.rhs
        );
        assert_ne!(slice.op_class, Some(OperatorClass::Mul));
        assert_ne!(slice.op_class, Some(OperatorClass::DivRem));
        let repl = lhs_of("repl_o");
        assert_ne!(
            repl.op_class,
            Some(OperatorClass::DivRem),
            "replication count /% billed as DivRem rhs={:?}",
            repl.rhs
        );
        assert_ne!(repl.op_class, Some(OperatorClass::Mul));
        let prod = lhs_of("prod_o");
        assert_eq!(prod.op_class, Some(OperatorClass::Mul));
        assert!(
            prod.fo4_cost >= 50.0,
            "real mul under-counted {}",
            prod.fo4_cost
        );
        let idx = lhs_of("idx_o");
        assert_eq!(idx.op_class, Some(OperatorClass::Mul));
        assert!(
            idx.fo4_cost >= 50.0,
            "runtime bit-select index under-counted {}",
            idx.fo4_cost
        );
    }

    /// delay-v37 guards. The issue-queue shape: a select cone computes
    /// `grant`/`slot`, and the queue's next state only depends on it through
    /// `if (grant && ack) q_after[slot].valid = 0`. Without guards the
    /// register-to-register path through the select never existed (g6lc_iq:
    /// 0.0 FO4 structural vs 47 mapped cells). The guard is a read (the path
    /// links) and a mux on the compare; a genvar index and a parameter `if`
    /// are elaboration-time and cost nothing.
    #[test]
    fn if_guards_and_lhs_indices_are_reads_and_cost_a_mux() {
        let text = concat!(
            "module iqg #(parameter bit EN = 1'b1) (\n",
            "    input logic clk_i, rst_ni, ack_i,\n",
            "    input logic [3:0] rdy_i,\n",
            "    output logic [3:0] valid_o\n",
            ");\n",
            "  logic [3:0] valid_q, valid_d, grant;\n",
            "  logic [1:0] slot;\n",
            "  logic any;\n",
            "  wire [1:0] row [0:3];\n",
            "  always_comb begin\n",
            "    grant = valid_q & rdy_i & ~(valid_q & rdy_i) + 4'd1;\n",
            "    slot = '0;\n",
            "    for (int unsigned e = 0; e < 4; e++) if (grant[e]) slot = slot | 2'(e);\n",
            "    any = |grant;\n",
            "    valid_d = valid_q;\n",
            "    if (any && ack_i) valid_d[slot] = 1'b0;\n",
            "    if (EN) valid_d[0] = valid_d[0] | rdy_i[0];\n",
            "  end\n",
            "  for (genvar k = 0; k < 4; k++) begin : g\n",
            "    assign row[k] = valid_q[k] ? 2'd1 : 2'd0;\n",
            "  end\n",
            "  always_ff @(posedge clk_i or negedge rst_ni) begin\n",
            "    if (!rst_ni) valid_q <= '0; else valid_q <= valid_d;\n",
            "  end\n",
            "  assign valid_o = valid_q;\n",
            "endmodule\n"
        );
        let out = analyze_inline_source(text);
        let m = out.design.modules.values().next().unwrap();
        let node_at = |lhs: &str| {
            m.nodes
                .values()
                .find(|n| n.lhs.as_deref() == Some(lhs))
                .unwrap_or_else(|| panic!("missing {lhs}"))
        };
        let guarded = node_at("valid_d[slot]");
        let gs = m.guards.get(&guarded.id).expect("guards recorded");
        assert!(gs.iter().any(|g| g == "any && ack_i"), "{gs:?}");
        assert!(gs.iter().any(|g| g == "slot"), "{gs:?}");
        // The guarded write reads the select cone: `slot`'s node is a fan-in.
        let slot_node = m
            .nodes
            .values()
            .filter(|n| n.lhs.as_deref() == Some("slot"))
            .max_by_key(|n| n.loc.start_line)
            .unwrap();
        assert!(
            guarded.fans_in.contains(&slot_node.id),
            "guarded write must read `slot`: fans_in={:?}",
            guarded.fans_in
        );
        // and costs a mux on top of the guard (the 1-bit guard itself is cheap).
        let model = CostModel::default();
        assert!(guarded.fo4_cost >= model.mux, "{}", guarded.fo4_cost);
        // The register-to-register path now runs through the select cone.
        let mid = m.id;
        let worst = out
            .design
            .paths
            .iter()
            .filter(|p| p.module == mid && p.path_kind == crate::ir::PathKind::RegToReg)
            .map(|p| p.total_fo4)
            .fold(0.0, f64::max);
        assert!(
            worst > 5.0,
            "select cone must be on the reg-to-reg path: {worst}"
        );
        // Elaboration-time guards cost nothing: `if (EN)` (parameter) and `row[k]` (genvar).
        let en_guarded = node_at("valid_d[0]");
        assert!(
            m.guards
                .get(&en_guarded.id)
                .is_none_or(|g| g.iter().all(|x| x == "EN")),
            "{:?}",
            m.guards.get(&en_guarded.id)
        );
        assert!(
            en_guarded.fo4_cost < model.mux + 1.0,
            "{}",
            en_guarded.fo4_cost
        );
        let row = node_at("row[k]");
        assert!(
            row.fo4_cost <= model.mux + 0.01,
            "genvar index is a wire: {}",
            row.fo4_cost
        );
    }

    #[test]
    fn genvar_arith_inside_generate_is_not_datapath() {
        let path = fixture("parse/genvar_lattice.sv");
        if !path.exists() {
            return;
        }
        let mut opts = LowerOptions::default();
        opts.cost_model = default_fo4_v1_embedded();
        opts.target = crate::ir::TimingTarget::new(4000.0, 20.0, 0.2);
        opts.module_filter = vec!["genvar_lattice".into()];
        let out = analyze_files(&[path], &ParseOptions::default(), &opts).expect("analyze");
        let m = out
            .design
            .modules
            .values()
            .find(|m| m.name == "genvar_lattice")
            .expect("genvar_lattice");
        assert!(
            m.gen_loops
                .iter()
                .any(|g| g.genvar == "i" && g.loc.byte_end > g.loc.byte_start),
            "expected generate-loop span for i, got {:?}",
            m.gen_loops
        );
        let lhs_of = |want: &str| {
            m.nodes
                .values()
                .find(|n| n.lhs.as_deref().is_some_and(|s| s.contains(want)))
                .unwrap_or_else(|| panic!("missing lhs {want}"))
        };
        let cell = lhs_of("cells");
        assert!(
            cell.fo4_cost < 2.0,
            "WIDTH * genvar i billed {} class {:?} rhs={:?}",
            cell.fo4_cost,
            cell.op_class,
            cell.rhs
        );
        assert_ne!(cell.op_class, Some(OperatorClass::Mul));
        assert_ne!(cell.op_class, Some(OperatorClass::DivRem));
        let prod = lhs_of("p_o");
        assert_eq!(prod.op_class, Some(OperatorClass::Mul));
        assert!(
            prod.fo4_cost >= 50.0,
            "runtime a * idx under-counted {}",
            prod.fo4_cost
        );
    }

    #[test]
    fn multi_module_file_scopes_ports_regions_and_instances() {
        let path = fixture("measure/two_modules.sv");
        if !path.exists() {
            return;
        }
        let mut opts = LowerOptions::default();
        opts.cost_model = default_fo4_v1_embedded();
        let out = analyze_files(&[path], &ParseOptions::default(), &opts).expect("analyze");
        let leaf = out
            .design
            .modules
            .values()
            .find(|m| m.name == "leaf_a")
            .expect("leaf_a");
        let holder = out
            .design
            .modules
            .values()
            .find(|m| m.name == "holder_b")
            .expect("holder_b");
        let leaf_ports: Vec<&str> = leaf.ports.iter().map(|p| p.name.as_str()).collect();
        let holder_ports: Vec<&str> = holder.ports.iter().map(|p| p.name.as_str()).collect();
        assert!(leaf_ports.contains(&"a_i"), "leaf ports={leaf_ports:?}");
        assert!(leaf_ports.contains(&"y_o"), "leaf ports={leaf_ports:?}");
        assert!(
            !leaf_ports.iter().any(|p| *p == "p_i" || *p == "q_o"),
            "leaf_a inherited holder_b ports: {leaf_ports:?}"
        );
        assert!(
            holder_ports.contains(&"p_i"),
            "holder ports={holder_ports:?}"
        );
        assert!(
            !holder_ports
                .iter()
                .any(|p| *p == "a_i" || *p == "b_i" || *p == "y_o"),
            "holder_b inherited leaf_a ports: {holder_ports:?}"
        );
        let leaf_params: Vec<&str> = leaf.parameters.iter().map(|p| p.name.as_str()).collect();
        let holder_params: Vec<&str> = holder.parameters.iter().map(|p| p.name.as_str()).collect();
        assert!(
            leaf_params.iter().any(|n| *n == "WIDTH_A"),
            "leaf params={leaf_params:?}"
        );
        assert!(
            !leaf_params.iter().any(|n| *n == "WIDTH_B"),
            "leaf_a inherited WIDTH_B: {leaf_params:?}"
        );
        assert!(
            holder_params.iter().any(|n| *n == "WIDTH_B"),
            "holder params={holder_params:?}"
        );
        assert_eq!(
            leaf.regions.len(),
            1,
            "leaf_a regions={} (union would be 2)",
            leaf.regions.len()
        );
        assert_eq!(
            holder.regions.len(),
            1,
            "holder_b regions={} (union would be 2)",
            holder.regions.len()
        );
        assert!(
            leaf.instances.is_empty(),
            "leaf_a must not own i_leaf: {:?}",
            leaf.instances
        );
        assert!(
            holder
                .instances
                .iter()
                .any(|i| i.instance_name == "i_leaf" && i.child_type == "leaf_a"),
            "i_leaf must belong to holder_b: {:?}",
            holder.instances
        );
    }

    #[test]
    fn mixed_case_localparam_arith_is_not_datapath() {
        let path = fixture("parse/param_lattice.sv");
        if !path.exists() {
            return;
        }
        let mut opts = LowerOptions::default();
        opts.cost_model = default_fo4_v1_embedded();
        opts.target = crate::ir::TimingTarget::new(4000.0, 20.0, 0.2);
        opts.module_filter = vec!["param_lattice".into()];
        let out = analyze_files(&[path], &ParseOptions::default(), &opts).expect("analyze");
        let m = out
            .design
            .modules
            .values()
            .find(|m| m.name == "param_lattice")
            .expect("param_lattice");
        assert!(
            m.localparams.iter().any(|n| n == "VpnLen"),
            "expected VpnLen localparam, got {:?}",
            m.localparams
        );
        let lhs_of = |want: &str| {
            m.nodes
                .values()
                .find(|n| n.lhs.as_deref().is_some_and(|s| s.contains(want)))
                .unwrap_or_else(|| panic!("missing lhs {want}"))
        };
        let w = lhs_of("w_o");
        assert!(
            w.fo4_cost < 2.0,
            "VpnLen/PtLevels billed {} class {:?} rhs={:?}",
            w.fo4_cost,
            w.op_class,
            w.rhs
        );
        assert_ne!(w.op_class, Some(OperatorClass::Mul));
        assert_ne!(w.op_class, Some(OperatorClass::DivRem));
        let p = lhs_of("p_o");
        assert_eq!(p.op_class, Some(OperatorClass::Mul));
        assert!(p.fo4_cost >= 50.0, "real mul under-counted {}", p.fo4_cost);
    }

    #[test]
    fn packed_dims_and_case_labels_are_not_datapath() {
        let path = fixture("parse/packed_dim_lrm.sv");
        if !path.exists() {
            return;
        }
        let mut opts = LowerOptions::default();
        opts.cost_model = default_fo4_v1_embedded();
        opts.module_filter = vec!["packed_dim_lrm".into()];
        let out = analyze_files(&[path], &ParseOptions::default(), &opts).expect("analyze");
        let m = out
            .design
            .modules
            .values()
            .find(|m| m.name == "packed_dim_lrm")
            .expect("packed_dim_lrm");
        for n in m.nodes.values() {
            assert_ne!(
                n.op_class,
                Some(OperatorClass::DivRem),
                "packed-dim/case-label / billed as DivRem at {}:{} rhs={:?}",
                n.loc.start_line,
                n.loc.start_col,
                n.rhs
            );
            assert_ne!(
                n.op_class,
                Some(OperatorClass::Mul),
                "packed-dim * billed as Mul at {}:{}",
                n.loc.start_line,
                n.loc.start_col
            );
        }
    }

    #[test]
    fn nba_vs_blocking_temps_are_not_flops() {
        let path = fixture("measure/nba_vs_blocking.sv");
        if !path.exists() {
            return;
        }
        let mut opts = LowerOptions::default();
        opts.cost_model = default_fo4_v1_embedded();
        opts.module_filter = vec!["nba_vs_blocking".into()];
        let out = analyze_files(&[path], &ParseOptions::default(), &opts).expect("analyze");
        let m = out
            .design
            .modules
            .values()
            .find(|m| m.name == "nba_vs_blocking")
            .expect("nba_vs_blocking");
        let mut saw_block = false;
        let mut saw_nba = false;
        for n in m.nodes.values() {
            let lhs = n.lhs.as_deref().map(crate::ref_order::ident_base);
            match lhs.as_deref() {
                Some("tmp") => {
                    assert_eq!(n.assign_kind, AssignKind::Blocking, "tmp must be blocking");
                    saw_block = true;
                }
                Some("y_q") => {
                    assert_eq!(n.assign_kind, AssignKind::Nonblocking, "y_q must be NBA");
                    saw_nba = true;
                }
                Some("y_o") => {
                    assert_eq!(n.assign_kind, AssignKind::Continuous);
                }
                _ => {}
            }
        }
        assert!(saw_block && saw_nba, "expected tmp blocking and y_q NBA");
    }

    #[test]
    fn comment_interiors_are_not_arithmetic() {
        let path = fixture("parse/comment_interiors.sv");
        if !path.exists() {
            return;
        }
        let mut opts = LowerOptions::default();
        opts.cost_model = default_fo4_v1_embedded();
        opts.module_filter = vec!["comment_interiors".into()];
        let out = analyze_files(&[path], &ParseOptions::default(), &opts).expect("analyze");
        let m = out
            .design
            .modules
            .values()
            .find(|m| m.name == "comment_interiors")
            .expect("comment_interiors");
        for n in m.nodes.values() {
            assert_ne!(
                n.op_class,
                Some(OperatorClass::Mul),
                "comment * billed as Mul at {}:{} rhs={:?}",
                n.loc.start_line,
                n.loc.start_col,
                n.rhs
            );
            assert_ne!(
                n.op_class,
                Some(OperatorClass::DivRem),
                "comment / billed as DivRem at {}:{}",
                n.loc.start_line,
                n.loc.start_col
            );
            if n.loc.start_line == 16 {
                // `assign y = tc_privchange_i /*|| (a * b) / 2 */;`
                assert_ne!(
                    n.op_class,
                    Some(OperatorClass::LogicBit),
                    "comment || billed as LogicBit"
                );
            }
        }
        let y_fo4: f64 = out
            .design
            .paths
            .iter()
            .filter(|p| p.primary_loc.start_line == 16)
            .map(|p| p.total_fo4)
            .fold(0.0, f64::max);
        assert!(
            y_fo4 < 10.0,
            "te_priority-shaped assign must not keep 56 FO4 comment mul, got {y_fo4}"
        );
    }

    #[test]
    fn comment_slash_banners_are_not_divrem() {
        let path = fixture("parse/comment_slashes.sv");
        if !path.exists() {
            return;
        }
        let mut opts = LowerOptions::default();
        opts.cost_model = default_fo4_v1_embedded();
        let out = analyze_files(&[path], &ParseOptions::default(), &opts).expect("analyze");
        for n in out.design.modules.values().flat_map(|m| m.nodes.values()) {
            assert_ne!(
                n.op_class,
                Some(OperatorClass::DivRem),
                "banner // must not lower as DivRem at {}:{}",
                n.loc.file,
                n.loc.start_line
            );
        }
    }

    #[test]
    fn lower_deep_add_chain_has_mul_free_adds() {
        let path = fixture("auto_correct/deep_add_chain.sv");
        if !path.exists() {
            return;
        }
        let mut opts = LowerOptions::default();
        opts.cost_model = default_fo4_v1_embedded();
        let out = analyze_files(&[path], &ParseOptions::default(), &opts).expect("analyze");
        let adds: usize = out
            .design
            .modules
            .values()
            .flat_map(|m| m.nodes.values())
            .filter(|n| n.op_class == Some(OperatorClass::AddSub))
            .count();
        assert!(adds >= 3, "expected >=3 add ops, got {adds}");
    }

    #[test]
    fn issue_style_typed_params_ports_genvar() {
        // Fixture uses multi-package + hierarchical dims as a *generic* SV style
        // sample (not a hard dependency of the lowerer on any SoC package names).
        let cfg = fixture("issue_style/config_pkg.sv");
        let ari = fixture("issue_style/ariane_pkg.sv");
        let unit = fixture("issue_style/issue_style_unit.sv");
        if !cfg.exists() || !ari.exists() || !unit.exists() {
            return;
        }
        let parse = ParseOptions {
            include_paths: vec![fixture("issue_style")],
            ..Default::default()
        };
        let mut opts = LowerOptions::default();
        opts.cost_model = default_fo4_v1_embedded();
        opts.module_filter = vec!["issue_style_unit".into()];
        let out = analyze_files(&[cfg, ari, unit], &parse, &opts).expect("analyze issue_style");

        // At least one package with typedefs (scoped types for ports/params)
        assert!(
            out.design.packages.values().any(|p| !p.typedefs.is_empty()),
            "expected package typedefs, packages={:?}",
            out.design.packages.keys().collect::<Vec<_>>()
        );

        let m = out
            .design
            .modules
            .values()
            .find(|m| m.name == "issue_style_unit")
            .expect("module");

        assert!(
            !m.package_imports.is_empty(),
            "expected import of some package, imports={:?}",
            m.package_imports
        );

        // Value param with scoped type_ref / default (`scope::name` form)
        assert!(
            m.parameters.iter().any(|p| {
                !p.is_type_parameter
                    && p.type_ref
                        .as_ref()
                        .map(|t| t.contains("::"))
                        .unwrap_or(false)
                    && p.default_expr
                        .as_ref()
                        .map(|t| t.contains("::"))
                        .unwrap_or(false)
            }),
            "expected scoped value parameter, parameters={:?}",
            m.parameters
        );

        // Type parameters present
        assert!(
            m.parameters.iter().any(|p| p.is_type_parameter),
            "type params={:?}",
            m.parameters
        );

        // Typed port with hierarchical sizing (root.member in dims)
        let typed_hier = m.ports.iter().find(|p| {
            p.direction == "input"
                && p.type_name.as_ref().map(|t| t != "logic").unwrap_or(false)
                && p.uses_hierarchical
        });
        assert!(
            typed_hier.is_some(),
            "expected hierarchical typed input port, ports={:?}",
            m.ports
        );
        let ip = typed_hier.unwrap();
        assert!(
            ip.packed_dims
                .as_ref()
                .map(|d| d.contains('.'))
                .unwrap_or(false),
            "packed_dims should be hierarchical root.member, got {:?}",
            ip.packed_dims
        );

        // genvar loops with hierarchical bound and/or labels
        assert!(!m.gen_loops.is_empty(), "expected genvar loops");
        assert!(
            m.gen_loops.iter().any(|g| {
                g.bound_hint
                    .as_ref()
                    .map(|b| b.contains('.'))
                    .unwrap_or(false)
                    || g.label.is_some()
            }),
            "gen_loops should carry hierarchical bound or label, got {:?}",
            m.gen_loops
        );
        assert!(!out.design.paths.is_empty());
    }

    #[test]
    fn cva6_style_package_localparam_function_named_ff() {
        let pkg = fixture("cva6_style/cva6_style_pkg.sv");
        let unit = fixture("cva6_style/cva6_style_unit.sv");
        if !pkg.exists() || !unit.exists() {
            return;
        }
        let parse = ParseOptions {
            include_paths: vec![fixture("cva6_style")],
            ..Default::default()
        };
        let mut opts = LowerOptions::default();
        opts.cost_model = default_fo4_v1_embedded();
        opts.module_filter = vec!["cva6_style_unit".into()];
        let out = analyze_files(&[pkg, unit], &parse, &opts).expect("analyze cva6_style");

        // Package localparams + functions
        let p = out
            .design
            .packages
            .get("cva6_style_pkg")
            .expect("package cva6_style_pkg");
        assert!(
            p.localparams
                .iter()
                .any(|n| n.contains("PKG_DEPTH") || n == "PKG_DEPTH"),
            "pkg localparams={:?}",
            p.localparams
        );
        assert!(
            p.functions.iter().any(|n| n == "pkg_add" || n == "pkg_mux"),
            "pkg functions={:?}",
            p.functions
        );

        let m = out
            .design
            .modules
            .values()
            .find(|m| m.name == "cva6_style_unit")
            .expect("module");
        assert!(
            m.localparams
                .iter()
                .any(|n| n.contains("LDBUF") || n.contains("REQ_ID") || n.contains("FALLTHROUGH")),
            "module localparams={:?}",
            m.localparams
        );
        assert!(
            m.package_imports.iter().any(|n| n.contains("cva6_style")),
            "imports={:?}",
            m.package_imports
        );

        // Named always_ff with posedge clk + negedge rst (scoreboard/load_unit style)
        let ff = m
            .regions
            .values()
            .find(|r| r.kind == RegionKind::AlwaysFf)
            .expect("always_ff region");
        assert_eq!(ff.label.as_deref(), Some("regs"), "named begin : regs");
        assert_eq!(ff.gate.clock_name.as_deref(), Some("clk_i"));
        assert_eq!(ff.gate.edge, Some(EdgeKind::Posedge));
        assert_eq!(ff.gate.reset_name.as_deref(), Some("rst_ni"));
        assert_eq!(ff.gate.reset_edge, Some(EdgeKind::Negedge));
        assert!(
            ff.gate
                .reset
                .as_ref()
                .map(|r| r.asynchronous)
                .unwrap_or(false),
            "async reset expected"
        );

        let comb = m.regions.values().find(|r| {
            r.kind == RegionKind::AlwaysComb && r.label.as_deref() == Some("comb_datapath")
        });
        assert!(
            comb.is_some(),
            "expected named always_comb begin : comb_datapath"
        );
        assert!(!out.design.paths.is_empty());
    }

    #[test]
    fn multi_file_include_lowers_with_incdir() {
        let path = fixture("multi_file/top_with_include.sv");
        let inc = fixture("multi_file");
        if !path.exists() {
            return;
        }
        let parse = ParseOptions {
            include_paths: vec![inc],
            ..Default::default()
        };
        let mut opts = LowerOptions::default();
        opts.cost_model = default_fo4_v1_embedded();
        opts.module_filter = vec!["top_with_include".into()];
        let out = analyze_files(&[path], &parse, &opts).expect("analyze multi_file");
        assert!(out
            .design
            .modules
            .values()
            .any(|m| m.name == "top_with_include"));
        assert!(!out.design.paths.is_empty());
        let loc = &out.design.paths[0].primary_loc;
        assert!(
            loc.file.contains("top_with_include") || loc.start_line >= 1,
            "expected source loc, got {:?}",
            loc
        );
    }

    #[test]
    fn project_mini_instance_graph_and_cross_paths() {
        let top = fixture("project_mini/top.sv");
        let mid = fixture("project_mini/mid.sv");
        let leaf = fixture("project_mini/leaf.sv");
        if !top.exists() || !mid.exists() || !leaf.exists() {
            return;
        }
        let mut opts = LowerOptions::default();
        opts.cost_model = default_fo4_v1_embedded();
        opts.module_filter = vec!["proj_top".into(), "proj_mid".into(), "proj_leaf".into()];
        let out = analyze_files(&[leaf, mid, top], &ParseOptions::default(), &opts)
            .expect("analyze project_mini");
        assert!(
            out.design.instances.len() >= 2,
            "expected leaf+mid instances, got {:?}",
            out.design
                .instances
                .iter()
                .map(|i| format!("{}.{}:{}", i.parent_name, i.instance_name, i.child_type))
                .collect::<Vec<_>>()
        );
        assert!(
            out.design
                .instances
                .iter()
                .any(|i| i.instance_name == "u_leaf" && i.child_type == "proj_leaf"),
            "instances={:?}",
            out.design.instances
        );
        assert!(
            out.design
                .instances
                .iter()
                .any(|i| i.child_module.is_some()),
            "child_module ids should resolve when types are on the design"
        );
        // Cross-module series upper-bounds once children have local paths
        assert!(
            !out.design.cross_module_paths.is_empty(),
            "expected cross_module_paths, instances={:?} paths={}",
            out.design.instances.len(),
            out.design.paths.len()
        );
        // Named port connections on u_leaf
        let u_leaf = out
            .design
            .instances
            .iter()
            .find(|i| i.instance_name == "u_leaf")
            .expect("u_leaf");
        assert!(
            u_leaf.connections.iter().any(|c| c.formal == "a_i"),
            "connections={:?}",
            u_leaf.connections
        );
        // Port-bridged stitch: y_o is a child output connected to parent net
        let bridged = out
            .design
            .cross_module_paths
            .iter()
            .find(|p| p.instance_name == "u_leaf")
            .expect("cross path for u_leaf");
        assert_eq!(
            bridged.stitch_kind, "port_bridged",
            "expected port_bridged, got {} rationale={}",
            bridged.stitch_kind, bridged.rationale
        );
        assert!(
            bridged.via_ports.iter().any(|v| v.contains("y_o")),
            "via_ports={:?}",
            bridged.via_ports
        );
        assert!(
            bridged
                .bridge_nets
                .iter()
                .any(|n| n.contains("y_leaf") || n == "y_leaf_o"),
            "bridge_nets={:?}",
            bridged.bridge_nets
        );
    }

    #[test]
    fn exclusive_case_mux_lowers_case_item_labels() {
        let path = fixture("exclusive_case_mux.sv");
        if !path.exists() {
            return;
        }
        let mut opts = LowerOptions::default();
        opts.cost_model = default_fo4_v1_embedded();
        opts.module_filter = vec!["exclusive_case_mux".into()];
        let out = analyze_files(&[path], &ParseOptions::default(), &opts).expect("analyze");
        let m = out
            .design
            .modules
            .values()
            .find(|m| m.name == "exclusive_case_mux")
            .expect("module");
        let labeled: Vec<_> = m
            .nodes
            .values()
            .filter(|n| !n.case_labels.is_empty())
            .collect();
        assert!(
            labeled.len() >= 4,
            "expected CaseItem labels on exclusive arms, got labeled={} nodes={:?}",
            labeled.len(),
            m.nodes
                .values()
                .map(|n| (n.lhs.clone(), n.case_labels.clone(), n.case_is_default))
                .collect::<Vec<_>>()
        );
        assert!(
            labeled
                .iter()
                .any(|n| n.case_labels.iter().any(|l| l == "ADD")),
            "expected ADD label, labeled={:?}",
            labeled.iter().map(|n| &n.case_labels).collect::<Vec<_>>()
        );
        assert!(
            labeled
                .iter()
                .any(|n| n.case_selector.as_deref() == Some("op_i")),
            "expected selector op_i on labeled arms"
        );
        let defaults = m.nodes.values().filter(|n| n.case_is_default).count();
        assert!(
            defaults >= 1,
            "expected default case arm, defaults={defaults}"
        );
    }

    #[test]
    fn alu_nested_unique_case_lowers_labels() {
        // Mirrors core/alu.sv: always_comb → if (rvb) → unique case with multi-line ROL.
        let path = fixture("alu_nested_case.sv");
        if !path.exists() {
            return;
        }
        let mut opts = LowerOptions::default();
        opts.cost_model = default_fo4_v1_embedded();
        opts.module_filter = vec!["alu_nested_case".into()];
        let out = analyze_files(&[path], &ParseOptions::default(), &opts).expect("analyze");
        let m = out
            .design
            .modules
            .values()
            .find(|m| m.name == "alu_nested_case")
            .expect("module");
        let labeled: Vec<_> = m
            .nodes
            .values()
            .filter(|n| !n.case_labels.is_empty())
            .collect();
        assert!(
            labeled.len() >= 4,
            "nested unique case labels missing: {:?}",
            m.nodes
                .values()
                .map(|n| (
                    n.lhs.clone(),
                    n.case_labels.clone(),
                    n.case_selector.clone()
                ))
                .collect::<Vec<_>>()
        );
        assert!(
            labeled
                .iter()
                .any(|n| n.case_labels.iter().any(|l| l == "ROL")),
            "expected ROL"
        );
        assert!(
            labeled
                .iter()
                .any(|n| n.case_selector.as_deref() == Some("op")),
            "expected selector op"
        );
    }

    #[test]
    fn leaf_rhs_expr_trees_have_add_depth() {
        let path = fixture("project_mini/leaf.sv");
        if !path.exists() {
            return;
        }
        let mut opts = LowerOptions::default();
        opts.cost_model = default_fo4_v1_embedded();
        opts.module_filter = vec!["proj_leaf".into()];
        let out = analyze_files(&[path], &ParseOptions::default(), &opts).expect("analyze");
        let m = out
            .design
            .modules
            .values()
            .find(|m| m.name == "proj_leaf")
            .expect("proj_leaf");
        let with_expr: Vec<_> = m.nodes.values().filter(|n| n.rhs_expr.is_some()).collect();
        assert!(
            !with_expr.is_empty(),
            "expected rhs_expr trees on leaf assigns"
        );
        assert!(
            with_expr.iter().any(|n| {
                n.rhs_expr
                    .as_ref()
                    .map(|e| e.op_node_count() >= 1 || e.depth() >= 2)
                    .unwrap_or(false)
            }),
            "expected non-trivial expression depth, got {:?}",
            with_expr
                .iter()
                .map(|n| n.rhs_expr.as_ref().map(|e| (e.depth(), e.emit())))
                .collect::<Vec<_>>()
        );
        // Denser FO4: multi-op RHS should exceed single base add_sub when tree has 2+ ops
        let multi = with_expr.iter().find(|n| {
            n.rhs_expr
                .as_ref()
                .map(|e| e.op_node_count() >= 2)
                .unwrap_or(false)
        });
        if let Some(n) = multi {
            assert!(
                n.fo4_cost >= opts.cost_model.add_sub * 1.5,
                "expected summed FO4 for multi-op expr, got {} (base add={})",
                n.fo4_cost,
                opts.cost_model.add_sub
            );
        }
    }

    #[test]
    fn p10_handshake_switch_refuses_insert_reg() {
        let path = fixture("measure/handshake_switch.sv");
        if !path.exists() {
            return;
        }
        let mut opts = LowerOptions::default();
        opts.cost_model = default_fo4_v1_embedded();
        opts.target = crate::ir::TimingTarget::new(4000.0, 20.0, 0.2);
        opts.module_filter = vec!["handshake_switch".into(), "handshake_bank".into()];
        let out = analyze_files(&[path], &ParseOptions::default(), &opts).expect("analyze");
        let sw = out
            .design
            .modules
            .values()
            .find(|m| m.name == "handshake_switch")
            .expect("handshake_switch");
        let locked = out
            .design
            .paths
            .iter()
            .filter(|p| p.module == sw.id)
            .filter(|p| crate::pass_strategy::path_is_handshake_locked(&out.design, p))
            .count();
        assert!(
            locked > 0,
            "expected P10 lock on switch/active pair, notes {:?}",
            out.design
                .paths
                .iter()
                .filter(|p| p.module == sw.id)
                .map(|p| p.class_note.clone())
                .collect::<Vec<_>>()
        );
        for p in out.design.paths.iter().filter(|p| p.module == sw.id) {
            if crate::pass_strategy::path_is_handshake_locked(&out.design, p) {
                assert!(
                    !crate::pass_strategy::admits_insert_reg(p),
                    "P10 path must refuse InsertReg {:?}",
                    p.class_note
                );
                assert_eq!(
                    crate::cone_lane::cone_lane(&out.design, p),
                    crate::cone_lane::ConeLane::NextStateFsm
                );
            }
        }
        let bank = out
            .design
            .modules
            .values()
            .find(|m| m.name == "handshake_bank")
            .expect("handshake_bank");
        let restore_locked = out.design.paths.iter().any(|p| {
            p.module == bank.id && crate::pass_strategy::path_is_handshake_locked(&out.design, p)
        });
        assert!(
            restore_locked,
            "expected P10 lock on npc_restore_o = bank[active_hart_i]"
        );
    }

    #[test]
    fn p10_ternary_indexed_restore_refuses_insert_reg() {
        let path = fixture("measure/ternary_indexed_restore.sv");
        if !path.exists() {
            return;
        }
        let mut opts = LowerOptions::default();
        opts.cost_model = default_fo4_v1_embedded();
        opts.target = crate::ir::TimingTarget::new(4000.0, 20.0, 0.2);
        opts.module_filter = vec!["ternary_indexed_restore".into()];
        let out = analyze_files(&[path], &ParseOptions::default(), &opts).expect("analyze");
        let restore = out.design.paths.iter().any(|p| {
            crate::pass_strategy::path_has_indexed_restore(&out.design, p)
                || crate::pass_strategy::path_is_handshake_locked(&out.design, p)
        });
        assert!(
            restore,
            "ternary mem[port] must lock like inval_bus, notes {:?}",
            out.design
                .paths
                .iter()
                .map(|p| (p.path_kind, p.total_fo4, p.class_note.clone()))
                .collect::<Vec<_>>()
        );
        for p in &out.design.paths {
            if crate::pass_strategy::path_has_indexed_restore(&out.design, p) {
                let ex = crate::pass_strategy::exception_policy(&out.design, p);
                assert!(
                    ex.as_ref().is_some_and(|e| !e.admit_insert_reg),
                    "ternary restore must not be resilient {:?}",
                    ex
                );
            }
        }
    }

    #[test]
    fn always_ff_nba_bundle_does_not_serial_sum() {
        let path = fixture("measure/always_ff_nba_bundle.sv");
        if !path.exists() {
            return;
        }
        let mut opts = LowerOptions::default();
        opts.cost_model = default_fo4_v1_embedded();
        opts.target = crate::ir::TimingTarget::new(4000.0, 20.0, 0.2);
        opts.module_filter = vec!["always_ff_nba_bundle".into()];
        let out = analyze_files(&[path], &ParseOptions::default(), &opts).expect("analyze");
        let prim: f64 = out
            .design
            .paths
            .iter()
            .filter(|p| !p.multi_cycle)
            .map(|p| p.total_fo4)
            .fold(0.0, f64::max);
        assert!(
            prim < 40.0,
            "sibling always_ff NBAs must not serial-sum, primary={prim} notes={:?}",
            out.design
                .paths
                .iter()
                .filter(|p| !p.multi_cycle && p.total_fo4 > 20.0)
                .map(|p| (
                    p.path_class,
                    p.total_fo4,
                    p.class_note.clone(),
                    p.nodes.len()
                ))
                .collect::<Vec<_>>()
        );
    }

    #[test]
    fn hpdcache_generate_cfg_divrem_is_not_srt() {
        let path = fixture("parse/hpdcache_idx_mux.sv");
        if !path.exists() {
            return;
        }
        let mut opts = LowerOptions::default();
        opts.cost_model = default_fo4_v1_embedded();
        opts.target = crate::ir::TimingTarget::new(4000.0, 20.0, 0.2);
        opts.module_filter = vec!["hpdcache_idx_mux".into()];
        let out = analyze_files(&[path], &ParseOptions::default(), &opts).expect("analyze");
        let m = out
            .design
            .modules
            .values()
            .find(|m| m.name == "hpdcache_idx_mux")
            .expect("hpdcache_idx_mux");
        assert!(
            !m.gen_loops.is_empty(),
            "expected generate-for genvars on hpdcache_idx_mux"
        );
        for n in m.nodes.values() {
            assert_ne!(
                n.op_class,
                Some(OperatorClass::Mul),
                "generate * Cfg billed Mul at {}:{} rhs={:?} fo4={} genvars={:?}",
                n.loc.start_line,
                n.loc.start_col,
                n.rhs,
                n.fo4_cost,
                m.genvar_names_at(&n.loc)
            );
            assert_ne!(
                n.op_class,
                Some(OperatorClass::DivRem),
                "generate %/ / Cfg billed DivRem at {}:{} rhs={:?} fo4={}",
                n.loc.start_line,
                n.loc.start_col,
                n.rhs,
                n.fo4_cost
            );
            assert!(
                n.fo4_cost < 20.0,
                "generate mux node {} FO4 at {}:{} rhs={:?}",
                n.fo4_cost,
                n.loc.start_line,
                n.loc.start_col,
                n.rhs
            );
        }
        for p in out.design.paths.iter().filter(|p| p.module == m.id) {
            assert_ne!(
                p.path_class,
                crate::path_class::PathClassKind::AtomicOverBudget,
                "generate mux path atomic fo4={} note={:?}",
                p.total_fo4,
                p.class_note
            );
        }
    }

    #[test]
    fn comb_for_index_times_localparam_is_not_mul() {
        let path = fixture("parse/comb_for_scale.sv");
        if !path.exists() {
            return;
        }
        let mut opts = LowerOptions::default();
        opts.cost_model = default_fo4_v1_embedded();
        opts.target = crate::ir::TimingTarget::new(4000.0, 20.0, 0.2);
        opts.module_filter = vec!["comb_for_scale".into()];
        let out = analyze_files(&[path], &ParseOptions::default(), &opts).expect("analyze");
        let m = out
            .design
            .modules
            .values()
            .find(|m| m.name == "comb_for_scale")
            .expect("comb_for_scale");
        assert!(
            m.gen_loops.iter().any(|g| g.genvar == "w"),
            "expected comb-for index w, got {:?}",
            m.gen_loops
                .iter()
                .map(|g| g.genvar.as_str())
                .collect::<Vec<_>>()
        );
        for n in m.nodes.values() {
            assert_ne!(
                n.op_class,
                Some(OperatorClass::Mul),
                "w*SETS billed Mul at {}:{} rhs={:?} fo4={} genvars={:?}",
                n.loc.start_line,
                n.loc.start_col,
                n.rhs,
                n.fo4_cost,
                m.genvar_names_at(&n.loc)
            );
        }
        for p in out.design.paths.iter().filter(|p| p.module == m.id) {
            assert_ne!(
                p.path_class,
                crate::path_class::PathClassKind::AtomicOverBudget,
                "comb-for path atomic fo4={} note={:?}",
                p.total_fo4,
                p.class_note
            );
            assert!(
                p.total_fo4 < 30.0,
                "comb-for primary {} note={:?}",
                p.total_fo4,
                p.class_note
            );
        }
    }

    #[test]
    fn lzc_tree_is_not_a_90_fo4_serial_wall() {
        let path = fixture("parse/lzc_tree.sv");
        if !path.exists() {
            return;
        }
        let mut opts = LowerOptions::default();
        opts.cost_model = default_fo4_v1_embedded();
        opts.target = crate::ir::TimingTarget::new(4000.0, 20.0, 0.2);
        opts.module_filter = vec!["lzc_tree".into()];
        let out = analyze_files(&[path], &ParseOptions::default(), &opts).expect("analyze");
        let m = out
            .design
            .modules
            .values()
            .find(|m| m.name == "lzc_tree")
            .expect("lzc_tree");
        let worst = out
            .design
            .paths
            .iter()
            .filter(|p| p.module == m.id)
            .map(|p| p.total_fo4)
            .fold(0.0_f64, f64::max);
        assert!(
            worst < 40.0,
            "lzc tree primary {worst} (serial generate sum?); paths {:?}",
            out.design
                .paths
                .iter()
                .filter(|p| p.module == m.id)
                .map(|p| (
                    p.total_fo4,
                    p.nodes.len(),
                    p.path_class,
                    p.class_note.clone()
                ))
                .collect::<Vec<_>>()
        );
        for p in out.design.paths.iter().filter(|p| p.module == m.id) {
            assert_ne!(
                crate::cone_lane::cone_lane(&out.design, p),
                crate::cone_lane::ConeLane::CombDatapath,
                "lzc is a function tree; InsertReg would add consumer latency"
            );
        }
    }
}
