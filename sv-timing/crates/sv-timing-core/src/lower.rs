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
    CombRegion, CrossModulePath, EdgeKind, GateInfo, GenerateLoop, IrNode, ModuleId, ModuleInstance,
    ModulePort, NodeId, OperatorClass, PathEndpoint, PathId, PortConnection, RegionId, RegionKind,
    ResetInfo, TimingDesign, TimingModule, TimingPackage, TimingPath, TimingTarget, TypedParameter,
};
use crate::loc::{LineIndex, OriginKind, SourceLoc};
use crate::measure::{
    attribute_costs, max_freq_mhz_for_path, CostModel,
};
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
pub fn analyze_files(paths: &[std::path::PathBuf], parse: &ParseOptions, lower: &LowerOptions) -> CoreResult<AnalyzeOutput> {
    let unit = parse_paths(paths, parse)?;
    let mut out = lower_unit(&unit, lower)?;
    out.skipped_files = unit.skipped.clone();
    Ok(out)
}

/// Lower an already-parsed unit.
pub fn lower_unit(unit: &ParsedUnit, opts: &LowerOptions) -> CoreResult<AnalyzeOutput> {
    let mut design = TimingDesign::empty(opts.target.clone());
    design.param_map_keys = opts.param_map.keys();
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
    // Refresh primary_loc only — do **not** re-sum FO4 here (would wipe exclusive-case
    // adjustments applied inside attribute_costs / classify_and_adjust_paths).
    for path in &mut design.paths {
        if let Some(module) = design.modules.get(&path.module) {
            if let Some(last) = path.nodes.last().and_then(|id| module.nodes.get(id)) {
                path.primary_loc = last.loc.clone();
            }
        }
    }
    resolve_instance_child_ids(&mut design);
    stitch_cross_module_paths(&mut design, &mut next_path);
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
            let via: Vec<String> = bridges
                .iter()
                .map(|(f, a)| format!("{f}={a}"))
                .collect();
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
}

/// Intermediate region extract before IR materialization.
struct RegionExtract {
    kind: RegionKind,
    loc: SourceLoc,
    label: Option<String>,
    gate: GateInfo,
    ops: Vec<OpExtract>,
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
            if let Some(tp) = extract_package(tree, li, &path_str, pkg) {
                names.reserve(&tp.name, &tp.name);
                design.packages.insert(tp.name.clone(), tp);
            }
        }
    }

    // Collect module name + a span of interest by walking once.
    let mut modules_found: Vec<(String, SourceLoc)> = Vec::new();
    for node in tree {
        match node {
            RefNode::ModuleDeclarationAnsi(x) => {
                if let Some(name) = module_name(tree, unwrap_node!(x, ModuleIdentifier)) {
                    let loc = first_locate_loc(tree, li, &path_str, x);
                    modules_found.push((name, loc));
                }
            }
            RefNode::ModuleDeclarationNonansi(x) => {
                if let Some(name) = module_name(tree, unwrap_node!(x, ModuleIdentifier)) {
                    let loc = first_locate_loc(tree, li, &path_str, x);
                    modules_found.push((name, loc));
                }
            }
            _ => {}
        }
    }

    // If no modules, synthesize a file-scoped pseudo-module for operator discovery.
    if modules_found.is_empty() && design.packages.is_empty() {
        modules_found.push((
            format!("_file_{}", sanitize_stem(&path_str)),
            SourceLoc::file_start(&file.path),
        ));
    }

    // File-level localparams / functions / imports shared into each module in this file (v1).
    let file_localparams = collect_localparam_names(tree);
    let file_functions = collect_function_names(tree);
    let file_imports = collect_package_imports(tree);

    // Prefer one-module-per-file attribution for instances (typical RTL layout).
    let parent_for_instances: Option<(String, /* mid filled later */ ())> =
        if modules_found.len() == 1 {
            Some((modules_found[0].0.clone(), ()))
        } else {
            None
        };
    let mut pending_file_instances: Option<Vec<ModuleInstance>> = None;

    for (mod_name, mod_loc) in modules_found {
        if !opts.module_filter.is_empty() && !opts.module_filter.iter().any(|m| m == &mod_name) {
            continue;
        }
        names.reserve(&mod_name, &mod_name);
        let mid = *next_module;
        *next_module += 1;

        let parameters = collect_typed_parameters(tree);
        let ports = collect_module_ports(tree);
        let gen_loops = collect_genvar_loops(tree, li, &path_str);

        let mut module = TimingModule {
            id: mid,
            name: mod_name.clone(),
            file: path_str.clone(),
            nodes: BTreeMap::new(),
            regions: BTreeMap::new(),
            localparams: file_localparams.clone(),
            parameters,
            ports,
            gen_loops,
            functions: file_functions.clone(),
            package_imports: file_imports.clone(),
            instances: Vec::new(),
            loc: mod_loc,
        };

        // Instance graph: when the file has a single module, attach all instantiations
        // to it (covers project_mini / typical CVA6 one-module files).
        if parent_for_instances
            .as_ref()
            .map(|(n, _)| n == &mod_name)
            .unwrap_or(false)
        {
            let insts = collect_module_instances(tree, li, &path_str, mid, &mod_name);
            module.instances = insts.clone();
            pending_file_instances = Some(insts);
        }

        let mut region_ops: Vec<RegionExtract> = Vec::new();

        for node in tree {
            match node {
                RefNode::AlwaysConstruct(x) => {
                    let kind = match &x.nodes.0 {
                        sv_parser::AlwaysKeyword::AlwaysComb(_) => RegionKind::AlwaysComb,
                        sv_parser::AlwaysKeyword::AlwaysFf(_) => RegionKind::AlwaysFf,
                        sv_parser::AlwaysKeyword::AlwaysLatch(_) => RegionKind::AlwaysComb,
                        sv_parser::AlwaysKeyword::Always(_) => RegionKind::AlwaysComb,
                    };
                    let region_loc = first_locate_loc(tree, li, &path_str, x);
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

        // Fallback: whole-file binary ops as one always_comb region.
        if region_ops.is_empty() {
            let ops = collect_ops_and_assigns(tree, li, &path_str, &file.bytes, tree);
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
                let op_class = rhs_expr
                    .as_ref()
                    .map(|e| e.dominant_op_class())
                    .filter(|c| *c != OperatorClass::Other)
                    .unwrap_or(op.op_class);
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
                    },
                );
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
        if let Some(insts) = pending_file_instances.take() {
            design.instances.extend(insts);
        }
    }

    Ok(())
}

/// Collect `type inst (.formal(actual), …);` module instantiations in a syntax tree.
fn collect_module_instances(
    tree: &SyntaxTree,
    li: &LineIndex,
    path_str: &str,
    parent_id: ModuleId,
    parent_name: &str,
) -> Vec<ModuleInstance> {
    let mut out = Vec::new();
    for node in tree {
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

fn port_connections_of(tree: &SyntaxTree, hier: &sv_parser::HierarchicalInstance) -> Vec<PortConnection> {
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
    pkg: &sv_parser::PackageDeclaration,
) -> Option<TimingPackage> {
    let name = module_name(tree, unwrap_node!(pkg, PackageIdentifier))?;
    let loc = first_locate_loc(tree, li, path_str, pkg);
    Some(TimingPackage {
        name,
        file: path_str.into(),
        localparams: collect_localparam_names_in(tree, pkg),
        functions: collect_function_names_in(tree, pkg),
        typedefs: collect_typedef_names_in(tree, pkg),
        loc,
    })
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
fn collect_typed_parameters(tree: &SyntaxTree) -> Vec<TypedParameter> {
    let mut out = Vec::new();
    let mut seen = std::collections::BTreeSet::new();

    for node in tree {
        match node {
            RefNode::ParameterDeclarationParam(p) => {
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
                            if let Some(s) =
                                identifier_str(tree, RefNode::ParameterIdentifier(pi))
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
                    let tpath: Vec<String> =
                        type_ids.into_iter().filter(|t| t != &name).collect();
                    let type_ref = scoped_path(&tpath);
                    let default_expr = scoped_path(&default_ids);
                    if seen.insert(name.clone()) {
                        out.push(TypedParameter {
                            name,
                            is_type_parameter: false,
                            type_ref,
                            default_expr,
                        });
                    }
                }
            }
            RefNode::ParameterDeclarationType(p) => {
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
                            default_expr: scoped_path(&default_tokens)
                                .or_else(|| {
                                    if default_tokens.is_empty() {
                                        None
                                    } else {
                                        Some(default_tokens.join("::"))
                                    }
                                }),
                        });
                    }
                }
            }
            _ => {}
        }
    }
    out
}

/// Port list: direction + type + optional hierarchical packed dims (`root.member`).
fn collect_module_ports(tree: &SyntaxTree) -> Vec<ModulePort> {
    let mut ports = Vec::new();
    let mut seen = std::collections::BTreeSet::new();

    for node in tree {
        if let RefNode::AnsiPortDeclaration(port) = node {
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

            if let Some(n) = name {
                if seen.insert(n.clone()) {
                    ports.push(ModulePort {
                        name: n,
                        direction,
                        type_name,
                        packed_dims: dims,
                        uses_hierarchical,
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

/// `for (genvar i = 0; i < root.member; i++)` — bound via hierarchical `root.member`.
fn collect_genvar_loops(
    tree: &SyntaxTree,
    li: &LineIndex,
    path_str: &str,
) -> Vec<GenerateLoop> {
    let mut loops = Vec::new();
    for node in tree {
        if let RefNode::LoopGenerateConstruct(lg) = node {
            let loc = first_locate_loc(tree, li, path_str, lg);
            let mut genvar = "i".to_string();
            let mut label: Option<String> = None;
            let mut body_assign_count = 0u32;
            let mut idents: Vec<String> = Vec::new();

            for n in lg {
                match n {
                    RefNode::GenvarIdentifier(g) => {
                        if let Some(s) = identifier_str(tree, RefNode::GenvarIdentifier(g)) {
                            genvar = s.clone();
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
                        if let Some(s) =
                            identifier_str(tree, RefNode::GenerateBlockIdentifier(g))
                        {
                            if s != genvar {
                                label = Some(s);
                            }
                        }
                    }
                    RefNode::GenerateBlock(gb) => {
                        if label.is_none() {
                            for b in gb {
                                if let RefNode::GenerateBlockIdentifier(g) = b {
                                    if let Some(s) = identifier_str(
                                        tree,
                                        RefNode::GenerateBlockIdentifier(g),
                                    ) {
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
            });
        }
    }
    loops
}

fn collect_localparam_names(tree: &SyntaxTree) -> Vec<String> {
    collect_localparam_names_in(tree, tree)
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

fn collect_function_names(tree: &SyntaxTree) -> Vec<String> {
    collect_function_names_in(tree, tree)
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

fn collect_package_imports(tree: &SyntaxTree) -> Vec<String> {
    let mut names = Vec::new();
    for node in tree {
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
    let mut ops = Vec::new();
    let mut assigns: Vec<OpExtract> = Vec::new();

    // Pass 1: CaseItem-aware assigns (labels + selector from CST, not source scan).
    let case_meta =
        collect_case_assign_meta(tree, line_index, path_str, bytes, nodes.iter().cloned());

    for node in nodes {
        match node {
            RefNode::BinaryOperator(bin) => {
                let sym = tree.get_str(&bin.nodes.0).unwrap_or("");
                let class = classify_binary(sym);
                let loc = locate_to_source(line_index, path_str, &bin.nodes.0.nodes.0);
                ops.push(OpExtract {
                    op_class: class,
                    loc,
                    lhs: None,
                    rhs: None,
                    case_labels: Vec::new(),
                    case_is_default: false,
                    case_selector: None,
                });
            }
            RefNode::NetAssignment(na) => {
                if let Some(a) = assign_lhs_rhs(tree, line_index, path_str, bytes, na) {
                    assigns.push(a);
                }
            }
            RefNode::VariableAssignment(va) => {
                if let Some(a) = assign_lhs_rhs(tree, line_index, path_str, bytes, va) {
                    assigns.push(a);
                }
            }
            RefNode::BlockingAssignment(ba) => {
                if let Some(a) = assign_lhs_rhs(tree, line_index, path_str, bytes, ba) {
                    assigns.push(a);
                }
            }
            RefNode::NonblockingAssignment(nba) => {
                if let Some(a) = assign_lhs_rhs(tree, line_index, path_str, bytes, nba) {
                    assigns.push(a);
                }
            }
            _ => {}
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
                    } else if rhs.contains('*') {
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
    bytes: &[u8],
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
        let s = s as usize;
        let e = (e as usize).min(bytes.len());
        if s < e {
            let t = String::from_utf8_lossy(&bytes[s..e]).trim().to_string();
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
    bytes: &[u8],
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
        let s = s as usize;
        let e = (e as usize).min(bytes.len());
        if s < e {
            let t = String::from_utf8_lossy(&bytes[s..e]).trim().to_string();
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
                if let Some(a) = assign_lhs_rhs(tree, line_index, path_str, bytes, na) {
                    assigns.push(a);
                }
            }
            RefNode::VariableAssignment(va) => {
                if let Some(a) = assign_lhs_rhs(tree, line_index, path_str, bytes, va) {
                    assigns.push(a);
                }
            }
            RefNode::BlockingAssignment(ba) => {
                if let Some(a) = assign_lhs_rhs(tree, line_index, path_str, bytes, ba) {
                    assigns.push(a);
                }
            }
            RefNode::NonblockingAssignment(nba) => {
                if let Some(a) = assign_lhs_rhs(tree, line_index, path_str, bytes, nba) {
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
) -> Option<OpExtract>
where
    T: IntoIterator<Item = RefNode<'a>> + Copy,
{
    let loc = first_locate_loc(tree, line_index, path_str, root);
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
        let s = s as usize;
        let e = (e as usize).min(bytes.len());
        if s < e {
            let text = String::from_utf8_lossy(&bytes[s..e]);
            split_assign_text(&text)
        } else {
            (None, None)
        }
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
    })
}

fn split_assign_text(text: &str) -> (Option<String>, Option<String>) {
    let t = text.trim().trim_end_matches(';').trim();
    // NBA first
    if let Some((l, r)) = t.split_once("<=") {
        return (
            Some(l.trim().to_string()),
            Some(r.trim().to_string()),
        );
    }
    if let Some((l, r)) = t.split_once('=') {
        // avoid == 
        if !l.ends_with('=') && !l.ends_with('!') && !l.ends_with('<') && !l.ends_with('>') {
            return (
                Some(l.trim().to_string()),
                Some(r.trim().to_string()),
            );
        }
    }
    (None, Some(t.to_string()))
}

fn classify_binary(sym: &str) -> OperatorClass {
    match sym.trim() {
        "+" | "-" => OperatorClass::AddSub,
        "*" => OperatorClass::Mul,
        "/" | "%" => OperatorClass::DivRem,
        "<<" | ">>" | "<<<" | ">>>" => OperatorClass::ShiftConst,
        "==" | "!=" | "===" | "!==" | "<" | ">" | "<=" | ">=" => OperatorClass::Compare,
        "&" | "|" | "^" | "~^" | "^~" | "&&" | "||" => OperatorClass::LogicBit,
        "?" => OperatorClass::Mux,
        _ => OperatorClass::Other,
    }
}

fn first_locate_loc<'a, T>(
    _tree: &'a SyntaxTree,
    line_index: &LineIndex,
    path_str: &str,
    root: T,
) -> SourceLoc
where
    T: IntoIterator<Item = RefNode<'a>>,
{
    for node in root {
        if let RefNode::Locate(loc) = node {
            return locate_to_source(line_index, path_str, loc);
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

fn locate_to_source(line_index: &LineIndex, path_str: &str, loc: &Locate) -> SourceLoc {
    // Prefer origin map from preprocessor when available (via line_index path).
    let start = loc.offset as u32;
    let end = (loc.offset + loc.len) as u32;
    let mut s = line_index.span(start, end, OriginKind::UserFile);
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
        assert!(out.design.modules.values().any(|m| m.name == "comb_adder_cloud"));
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
            out.design
                .packages
                .values()
                .any(|p| !p.typedefs.is_empty()),
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
                    && p.type_ref.as_ref().map(|t| t.contains("::")).unwrap_or(false)
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
            p.localparams.iter().any(|n| n.contains("PKG_DEPTH") || n == "PKG_DEPTH"),
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
            ff.gate.reset.as_ref().map(|r| r.asynchronous).unwrap_or(false),
            "async reset expected"
        );

        let comb = m
            .regions
            .values()
            .find(|r| r.kind == RegionKind::AlwaysComb && r.label.as_deref() == Some("comb_datapath"));
        assert!(comb.is_some(), "expected named always_comb begin : comb_datapath");
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
            bridged.bridge_nets.iter().any(|n| n.contains("y_leaf") || n == "y_leaf_o"),
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
            labeled.iter().any(|n| n.case_labels.iter().any(|l| l == "ADD")),
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
                .map(|n| (n.lhs.clone(), n.case_labels.clone(), n.case_selector.clone()))
                .collect::<Vec<_>>()
        );
        assert!(
            labeled.iter().any(|n| n.case_labels.iter().any(|l| l == "ROL")),
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
        let with_expr: Vec<_> = m
            .nodes
            .values()
            .filter(|n| n.rhs_expr.is_some())
            .collect();
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
}
