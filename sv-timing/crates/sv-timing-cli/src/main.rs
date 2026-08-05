// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// sv-timing CLI — project-independent compile-to-timing front end.
// JSON contracts consumed by TypeScript package js/ (@sv-timing/js).

#![forbid(unsafe_code)]

use std::path::PathBuf;
use std::process::ExitCode;

use clap::{Args, Parser, Subcommand};
use sv_timing_cache::{
    analyze_with_cache, CacheConfig, CacheCounts, TimingCache, CRC_ALGO, CACHE_SCHEMA_VERSION,
};
use sv_timing_core::{
    analyze_files, banner, build_relocation_plan, debug_snapshot_pass, frequency_closure,
    load_filelist_default, load_fo4_v1_default, path_class_summary, rank_paths_by_slack,
    resolve_opt, sta_hints_from_design, CacheMode, CutStrategy, DebugOptions, FileList,
    LowerOptions, NameTable, OptEffort, OptLevel, OptOptions, OptOverrides, ParamMap,
    ParseOptions, TimingDesign, TimingTarget, IR_VERSION, MEASUREMENT_VERSION, PARSER_PIN_HINT,
};
// build_relocation_plan used for analyze + correct residual plan
use sv_timing_emit::{
    emit_project_autocorrect, integrity_reparse_ex, min_density_score_for_trace, DensityReport,
    EmitPolicy, ProjectEmitOptions, ProjectLayout,
};
use sv_timing_transform::{run_correct_passes, PassContext, PassPolicy};

#[derive(Parser, Debug)]
#[command(
    name = "sv-timing",
    version,
    about = "Compile SystemVerilog sources to a timing-oriented IR (structural FO4 estimates, not STA)"
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

/// Optimization level + the ten dials (shared by `analyze` and `correct`).
///
/// A level is only a preset; every dial can be overridden explicitly and the resolved
/// set is echoed in the banner and the JSON `opt` block.
/// See `architecture/OPTIMIZATION-LEVELS.md` §3–§4.
#[derive(Args, Debug, Clone, Default)]
struct OptArgs {
    /// Optimization level preset: 0|1|2|3|s|z (e.g. `-O3`, `--opt-level s`).
    #[arg(long = "opt-level", short = 'O')]
    opt_level: Option<String>,
    /// Dial 1 — transform iterations.
    #[arg(long = "opt-max-passes")]
    opt_max_passes: Option<u32>,
    /// Dial 2 — work items applied per pass.
    #[arg(long = "opt-worklist-width")]
    opt_worklist_width: Option<usize>,
    /// Dial 3 — mid-node | cost-balanced | budget-fit.
    #[arg(long = "opt-cut-strategy")]
    opt_cut_strategy: Option<String>,
    /// Dial 4 — multi-cut depth per region.
    #[arg(long = "opt-max-stages-per-region")]
    opt_max_stages_per_region: Option<u32>,
    /// Dial 5 — reject edits below this predicted FO4 gain.
    #[arg(long = "opt-min-gain-fo4")]
    opt_min_gain_fo4: Option<f64>,
    /// Dial 6 — stop when worst slack reaches this (may be negative).
    #[arg(long = "opt-slack-target-fo4")]
    opt_slack_target_fo4: Option<f64>,
    /// Dial 7 — penalty per added flop when ordering candidates.
    #[arg(long = "opt-area-weight")]
    opt_area_weight: Option<f64>,
    /// Dial 8 — allow equivalence-unverified algebraic reshaping (reserved).
    #[arg(long = "opt-allow-reassoc", default_value_t = false)]
    opt_allow_reassoc: bool,
    /// Dial 9 — analysis depth: fast | balanced | thorough.
    #[arg(long = "opt-effort")]
    opt_effort: Option<String>,
    /// Dial 10a — parallel degree (reserved; P16).
    #[arg(long = "opt-jobs")]
    opt_jobs: Option<usize>,
    /// Dial 10b — cache tier: off | ir | unit | full.
    #[arg(long = "opt-cache-mode")]
    opt_cache_mode: Option<String>,
}

impl OptArgs {
    /// Resolve level + overrides, defaulting to `-O2`.
    ///
    /// `legacy_max_passes` carries the deprecated `--max-passes` flag; the explicit
    /// `--opt-max-passes` dial wins when both are given.
    fn resolve(&self, legacy_max_passes: Option<u32>) -> Result<OptOptions, String> {
        let level = match &self.opt_level {
            Some(s) => OptLevel::parse(s)
                .ok_or_else(|| format!("bad --opt-level '{s}' (expected 0|1|2|3|s|z)"))?,
            None => OptLevel::O2,
        };
        let cut_strategy = match &self.opt_cut_strategy {
            Some(s) => {
                Some(CutStrategy::parse(s).ok_or_else(|| format!("bad --opt-cut-strategy '{s}'"))?)
            }
            None => None,
        };
        let effort = match &self.opt_effort {
            Some(s) => Some(OptEffort::parse(s).ok_or_else(|| format!("bad --opt-effort '{s}'"))?),
            None => None,
        };
        let cache_mode = match &self.opt_cache_mode {
            Some(s) => {
                Some(CacheMode::parse(s).ok_or_else(|| format!("bad --opt-cache-mode '{s}'"))?)
            }
            None => None,
        };
        let ov = OptOverrides {
            max_passes: self.opt_max_passes.or(legacy_max_passes),
            worklist_width: self.opt_worklist_width,
            cut_strategy,
            max_stages_per_region: self.opt_max_stages_per_region,
            min_gain_fo4: self.opt_min_gain_fo4,
            slack_target_fo4: self.opt_slack_target_fo4,
            area_weight: self.opt_area_weight,
            allow_reassoc: self.opt_allow_reassoc.then_some(true),
            effort,
            jobs: self.opt_jobs,
            cache_mode,
        };
        Ok(resolve_opt(level, &ov))
    }
}

/// JSON view of the resolved dials (additive `opt` block in analyze / correct results).
fn opt_to_json(opt: &OptOptions) -> serde_json::Value {
    serde_json::json!({
        "level": opt.level.as_str(),
        "digest": opt.digest(),
        "measurement": MEASUREMENT_VERSION,
        "dials": {
            "max_passes": opt.max_passes,
            "worklist_width": opt.worklist_width,
            "cut_strategy": opt.cut_strategy.as_str(),
            "max_stages_per_region": opt.max_stages_per_region,
            "min_gain_fo4": opt.min_gain_fo4,
            "slack_target_fo4": opt.slack_target_fo4,
            "area_weight": opt.area_weight,
            "allow_reassoc": opt.allow_reassoc,
            "effort": opt.effort.as_str(),
            "jobs": opt.jobs,
            "cache_mode": opt.cache_mode.as_str(),
        },
    })
}

#[derive(Subcommand, Debug)]
enum Commands {
    /// Print package / version banner and optional cache status.
    Status {
        /// SQLite cache path (optional).
        #[arg(long)]
        cache: Option<PathBuf>,
        /// Write structured JSON (for TypeScript clients).
        #[arg(long)]
        json_out: Option<PathBuf>,
    },
    /// Parse + lower IR + rank paths / opportunities.
    Analyze {
        /// Source files (repeatable).
        #[arg(long = "file", short = 'f')]
        files: Vec<PathBuf>,
        /// File list (one path per line; # comments allowed).
        #[arg(long = "files-from")]
        files_from: Option<PathBuf>,
        /// Include directories.
        #[arg(long = "incdir", short = 'I')]
        incdirs: Vec<PathBuf>,
        /// Defines NAME or NAME=VAL.
        #[arg(long = "define", short = 'D')]
        defines: Vec<String>,
        /// Module roots to report (required unless --all-modules).
        #[arg(long = "modules")]
        modules: Option<String>,
        /// Analyze all modules found (explicit opt-in).
        #[arg(long = "all-modules")]
        all_modules: bool,
        /// Target frequency MHz (default 1000).
        #[arg(long = "target-mhz", default_value_t = 1000.0)]
        target_mhz: f64,
        /// FO4 picoseconds (default 20).
        #[arg(long = "fo4-ps", default_value_t = 20.0)]
        fo4_ps: f64,
        /// Budget margin 0..1 (default 0.2).
        #[arg(long = "budget-margin", default_value_t = 0.2)]
        budget_margin: f64,
        /// SQLite IR cache path (CRC-32C + design/module blobs). Enables hit on re-analyze.
        #[arg(long = "cache")]
        cache: Option<PathBuf>,
        /// Write JSON report path (schema analyze-result.v0/v1 + IR fields).
        #[arg(long = "json-out")]
        json_out: Option<PathBuf>,
        /// Host param / cfg map JSON (`{"CVA6Cfg.XLEN":64,…}`).
        #[arg(long = "param-map")]
        param_map: Option<PathBuf>,
        /// Alias for `--param-map` (structured cfg snapshot).
        #[arg(long = "cfg-snapshot")]
        cfg_snapshot: Option<PathBuf>,
        /// Inject common XLEN keys into the param map.
        #[arg(long = "assume-xlen")]
        assume_xlen: Option<u32>,
        /// Package mode: `off` (default) or `packages` (denser package surface).
        #[arg(long = "package-mode", default_value = "off")]
        package_mode: String,
        /// Skip files the parser rejects instead of failing the run (reported, never silent).
        #[arg(long = "allow-parse-errors", default_value_t = false)]
        allow_parse_errors: bool,
        /// Optimization level + dials (analysis dials apply here).
        #[command(flatten)]
        opt: OptArgs,
    },
    /// Auto-correct: analyze sources then multi-pass transform (dry-run by default).
    Correct {
        /// Source files (repeatable).
        #[arg(long = "file", short = 'f')]
        files: Vec<PathBuf>,
        /// Portable filelist (.f): paths, +incdir+, +define+, nested -f (see PROJECT-AUTOCORRECT).
        #[arg(long = "files-from")]
        files_from: Option<PathBuf>,
        /// Include directories (merged with filelist +incdir+).
        #[arg(long = "incdir", short = 'I')]
        incdirs: Vec<PathBuf>,
        /// Defines NAME or NAME=VAL (merged with filelist +define+).
        #[arg(long = "define", short = 'D')]
        defines: Vec<String>,
        /// Module allowlist (comma-separated). Also used as lower filter.
        #[arg(long = "modules-allow", default_value = "")]
        modules_allow: String,
        /// Alias for modules-allow / analyze module filter.
        #[arg(long = "modules")]
        modules: Option<String>,
        /// Correct all modules found in the file list (multi-module project mode).
        #[arg(long = "all-modules", default_value_t = false)]
        all_modules: bool,
        /// Target MHz for budget (default 2500 to surface opportunities on small fixtures).
        #[arg(long = "target-mhz", default_value_t = 2500.0)]
        target_mhz: f64,
        /// FO4 picoseconds.
        #[arg(long = "fo4-ps", default_value_t = 20.0)]
        fo4_ps: f64,
        /// Budget margin.
        #[arg(long = "budget-margin", default_value_t = 0.2)]
        budget_margin: f64,
        /// Allow latency-changing InsertReg.
        #[arg(long = "allow-latency", default_value_t = false)]
        allow_latency: bool,
        /// Assume posedge clk when GateInfo missing (with --allow-latency).
        #[arg(long = "assume-clk", default_value_t = false)]
        assume_clk: bool,
        /// Max correct passes (deprecated alias of `--opt-max-passes`).
        #[arg(long = "max-passes")]
        max_passes: Option<u32>,
        /// Dry-run (default true unless --emit).
        #[arg(long = "dry-run", default_value_t = true)]
        dry_run: bool,
        /// Actually emit corrected SV into --out-dir / --emit-dir.
        #[arg(long = "emit", default_value_t = false)]
        emit: bool,
        /// Project output directory (corrected tree + svt_corrected.f + manifest).
        /// Alias of --emit-dir; preferred name for multi-file projects.
        #[arg(long = "out-dir")]
        out_dir: Option<PathBuf>,
        /// Emit directory (legacy alias for --out-dir).
        #[arg(long = "emit-dir")]
        emit_dir: Option<PathBuf>,
        /// Preserve relative paths under out-dir (default). Use with multi-file projects.
        #[arg(long = "preserve-rel", default_value_t = true)]
        preserve_rel: bool,
        /// Also emit unchanged sources as passthrough __svt copies.
        #[arg(long = "emit-unchanged", default_value_t = false)]
        emit_unchanged: bool,
        /// Richer emit: origin RHS cut feeds + continuous rewrite/sinks (default lean zero feeds).
        #[arg(long = "real-cut-feeds", default_value_t = false)]
        real_cut_feeds: bool,
        /// Emit BalanceMux structural snippets + origin RHS rewrite (default credit-only).
        #[arg(long = "emit-balance-mux-rtl", default_value_t = false)]
        emit_balance_mux_rtl: bool,
        /// Write CorrectResult JSON for TypeScript.
        #[arg(long = "json-out")]
        json_out: Option<PathBuf>,
        /// Host param / cfg map JSON.
        #[arg(long = "param-map")]
        param_map: Option<PathBuf>,
        /// Alias for `--param-map`.
        #[arg(long = "cfg-snapshot")]
        cfg_snapshot: Option<PathBuf>,
        /// Inject common XLEN keys into the param map.
        #[arg(long = "assume-xlen")]
        assume_xlen: Option<u32>,
        /// Package mode: `off` or `packages`.
        #[arg(long = "package-mode", default_value = "off")]
        package_mode: String,
        /// Skip input files the parser rejects (integrity reparse of emitted SV stays strict).
        #[arg(long = "allow-parse-errors", default_value_t = false)]
        allow_parse_errors: bool,
        /// Optimization level + the ten dials.
        #[command(flatten)]
        opt: OptArgs,
    },
    /// Export debug bundle (IR / paths / names) for TypeScript and agents.
    DebugExport {
        /// Output directory for snapshot files.
        #[arg(long = "out-dir")]
        out_dir: PathBuf,
        /// Snapshot tag subdirectory.
        #[arg(long = "tag", default_value = "debug")]
        tag: String,
        /// Write DebugExportResult JSON.
        #[arg(long = "json-out")]
        json_out: Option<PathBuf>,
        /// Optional file list to lower for a real IR snapshot.
        #[arg(long = "files-from")]
        files_from: Option<PathBuf>,
        /// Modules filter for lower.
        #[arg(long = "modules")]
        modules: Option<String>,
        /// Include directories for parse.
        #[arg(long = "incdir", short = 'I')]
        incdirs: Vec<PathBuf>,
    },
}

/// Load a portable filelist into a [`FileList`] (paths +incdir+ +define+ nested -f).
fn load_project_inputs(
    files: Vec<PathBuf>,
    files_from: Option<PathBuf>,
    extra_incdirs: Vec<PathBuf>,
    extra_defines: Vec<String>,
) -> Result<FileList, String> {
    let mut fl = FileList::new();
    if let Some(ff) = files_from {
        let loaded = load_filelist_default(&ff).map_err(|e| e.to_string())?;
        fl.extend(loaded);
    }
    fl.push_files(files);
    for d in extra_incdirs {
        if !fl.incdirs.iter().any(|x| x == &d) {
            fl.incdirs.push(d);
        }
    }
    for d in &extra_defines {
        if let Some((n, v)) = d.split_once('=') {
            fl.defines.push((n.to_string(), Some(v.to_string())));
        } else {
            fl.defines.push((d.clone(), None));
        }
    }
    Ok(fl)
}

/// Legacy helper: path-only list (analyze / debug-export).
fn load_files_from(path: &PathBuf) -> Result<Vec<PathBuf>, String> {
    let fl = load_filelist_default(path).map_err(|e| e.to_string())?;
    Ok(fl.files)
}

fn write_json(path: &PathBuf, value: &serde_json::Value) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let body = serde_json::to_vec_pretty(value).map_err(|e| e.to_string())?;
    std::fs::write(path, body).map_err(|e| e.to_string())
}

fn parse_module_list(s: &str) -> Vec<String> {
    s.split(',')
        .map(|x| x.trim().to_string())
        .filter(|x| !x.is_empty())
        .collect()
}

fn design_to_analyze_json(
    design: &TimingDesign,
    files: &[(String, usize)],
    modules_requested: serde_json::Value,
    target_mhz: f64,
    fo4_ps: f64,
    budget_margin: f64,
) -> serde_json::Value {
    let ranked = rank_paths_by_slack(&design.paths, &design.target);
    let closure = frequency_closure(design);
    let paths_json: Vec<serde_json::Value> = ranked
        .primary
        .iter()
        .chain(ranked.multi_cycle.iter())
        .map(|p| {
            serde_json::json!({
                "path_id": p.id,
                "module_id": p.module,
                "path_kind": format!("{:?}", p.path_kind).to_ascii_lowercase(),
                "startpoint": p.startpoint,
                "endpoint": p.endpoint,
                "total_fo4": p.total_fo4,
                "total_fo4_raw": p.total_fo4_raw,
                "path_class": p.path_class,
                "class_note": p.class_note,
                "slack_fo4": p.slack_fo4,
                "max_freq_mhz": p.max_freq_mhz,
                "closes": p.slack_fo4 >= 0.0,
                "multi_cycle": p.multi_cycle,
                "node_count": p.nodes.len(),
                "primary_loc": {
                    "file": p.primary_loc.file,
                    "start_line": p.primary_loc.start_line,
                    "start_col": p.primary_loc.start_col,
                    "end_line": p.primary_loc.end_line,
                    "end_col": p.primary_loc.end_col,
                }
            })
        })
        .collect();

    let modules_json: Vec<serde_json::Value> = design
        .modules
        .values()
        .map(|m| {
            let regions: Vec<serde_json::Value> = m
                .regions
                .values()
                .map(|r| {
                    serde_json::json!({
                        "id": r.id,
                        "kind": format!("{:?}", r.kind).to_ascii_lowercase(),
                        "label": r.label,
                        "clock_name": r.gate.clock_name,
                        "clock_edge": r.gate.edge.map(|e| format!("{:?}", e).to_ascii_lowercase()),
                        "reset_name": r.gate.reset_name,
                        "reset_edge": r.gate.reset_edge.map(|e| format!("{:?}", e).to_ascii_lowercase()),
                        "async_reset": r.gate.reset.as_ref().map(|x| x.asynchronous),
                        "node_count": r.nodes.len(),
                    })
                })
                .collect();
            let parameters: Vec<serde_json::Value> = m
                .parameters
                .iter()
                .map(|p| {
                    serde_json::json!({
                        "name": p.name,
                        "is_type_parameter": p.is_type_parameter,
                        "type_ref": p.type_ref,
                        "default_expr": p.default_expr,
                    })
                })
                .collect();
            let ports: Vec<serde_json::Value> = m
                .ports
                .iter()
                .map(|p| {
                    serde_json::json!({
                        "name": p.name,
                        "direction": p.direction,
                        "type_name": p.type_name,
                        "packed_dims": p.packed_dims,
                        "uses_hierarchical": p.uses_hierarchical,
                    })
                })
                .collect();
            let gen_loops: Vec<serde_json::Value> = m
                .gen_loops
                .iter()
                .map(|g| {
                    serde_json::json!({
                        "genvar": g.genvar,
                        "bound_hint": g.bound_hint,
                        "label": g.label,
                        "body_assign_count": g.body_assign_count,
                        "loc": {
                            "file": g.loc.file,
                            "start_line": g.loc.start_line,
                        }
                    })
                })
                .collect();
            let instances: Vec<serde_json::Value> = m
                .instances
                .iter()
                .map(|i| {
                    serde_json::json!({
                        "instance_name": i.instance_name,
                        "child_type": i.child_type,
                        "child_module_id": i.child_module,
                        "connections": i.connections.iter().map(|c| {
                            serde_json::json!({ "formal": c.formal, "actual": c.actual })
                        }).collect::<Vec<_>>(),
                    })
                })
                .collect();
            serde_json::json!({
                "id": m.id,
                "name": m.name,
                "file": m.file,
                "node_count": m.nodes.len(),
                "region_count": m.regions.len(),
                "localparams": m.localparams,
                "parameters": parameters,
                "ports": ports,
                "gen_loops": gen_loops,
                "functions": m.functions,
                "package_imports": m.package_imports,
                "instances": instances,
                "regions": regions,
            })
        })
        .collect();

    let packages_json: Vec<serde_json::Value> = design
        .packages
        .values()
        .map(|p| {
            serde_json::json!({
                "name": p.name,
                "file": p.file,
                "localparams": p.localparams,
                "functions": p.functions,
                "typedefs": p.typedefs,
            })
        })
        .collect();

    let instances_json: Vec<serde_json::Value> = design
        .instances
        .iter()
        .map(|i| {
            serde_json::json!({
                "parent_module": i.parent_name,
                "parent_module_id": i.parent_module,
                "instance_name": i.instance_name,
                "child_type": i.child_type,
                "child_module_id": i.child_module,
                "connections": i.connections.iter().map(|c| {
                    serde_json::json!({ "formal": c.formal, "actual": c.actual })
                }).collect::<Vec<_>>(),
                "loc": {
                    "file": i.loc.file,
                    "start_line": i.loc.start_line,
                }
            })
        })
        .collect();

    let cross_paths_json: Vec<serde_json::Value> = design
        .cross_module_paths
        .iter()
        .map(|p| {
            serde_json::json!({
                "path_id": p.id,
                "parent_module": p.parent_module,
                "instance_name": p.instance_name,
                "child_module": p.child_module,
                "child_path_id": p.child_path_id,
                "parent_path_id": p.parent_path_id,
                "total_fo4": p.total_fo4,
                "slack_fo4": p.slack_fo4,
                "max_freq_mhz": p.max_freq_mhz,
                "startpoint": p.startpoint,
                "endpoint": p.endpoint,
                "rationale": p.rationale,
                "stitch_kind": p.stitch_kind,
                "bridge_nets": p.bridge_nets,
                "via_ports": p.via_ports,
            })
        })
        .collect();

    let opportunities: Vec<serde_json::Value> = design
        .opportunities
        .iter()
        .map(|o| {
            serde_json::json!({
                "kind": match o.kind {
                    sv_timing_core::OpportunityKind::InsertReg => "insert_reg",
                    sv_timing_core::OpportunityKind::SplitAssign => "split_assign",
                    sv_timing_core::OpportunityKind::BalanceMux => "balance_mux",
                },
                "path_id": o.path_id,
                "estimated_fo4_before": o.estimated_fo4_before,
                "estimated_fo4_after": o.estimated_fo4_after,
                "rationale": o.rationale,
                "changes_latency": o.changes_latency,
                "requires_clock_in_scope": o.requires_clock_in_scope,
                "loc": {
                    "file": o.loc.file,
                    "start_line": o.loc.start_line,
                    "start_col": o.loc.start_col,
                    "end_line": o.loc.end_line,
                    "end_col": o.loc.end_col,
                }
            })
        })
        .collect();

    let files_json: Vec<serde_json::Value> = files
        .iter()
        .map(|(p, len)| {
            serde_json::json!({
                "path": p,
                "parse_ok": true,
                "byte_len": len,
            })
        })
        .collect();

    let sta_hints: Vec<serde_json::Value> = sta_hints_from_design(design, 8)
        .into_iter()
        .map(|h| {
            serde_json::json!({
                "path_id": h.path_id,
                "kind": h.kind,
                "from": h.from,
                "to": h.to,
                "through": h.through,
                "structural_fo4": h.structural_fo4,
                "structural_slack_fo4": h.structural_slack_fo4,
                "loc": {
                    "file": h.loc.file,
                    "start_line": h.loc.start_line,
                    "start_col": h.loc.start_col,
                },
                "comment": h.comment,
                "sdc_comment": format!(
                    "# sv-timing path_id={} fo4={:.1} slack={:.1} — NOT set_max_delay\n# report_timing -from {{{}}} -to {{{}}}{}",
                    h.path_id,
                    h.structural_fo4,
                    h.structural_slack_fo4,
                    h.from,
                    h.to,
                    if h.through.is_empty() {
                        String::new()
                    } else {
                        format!(" -through {{{}}}", h.through.join(" "))
                    }
                ),
            })
        })
        .collect();

    serde_json::json!({
        "schema_version": "0",
        "disclaimer": "structural FO4 from lower_to_ir — not STA sign-off",
        "banner": banner(),
        "target_mhz": target_mhz,
        "fo4_ps": fo4_ps,
        "budget_margin": budget_margin,
        "budget_fo4": design.target.budget_fo4,
        "files": files_json,
        "modules_requested": modules_requested,
        "ast": {
            "kind": "timing_ir_v0",
            "files_parsed": files.len(),
            "module_count": design.modules.len(),
            "path_count": design.paths.len(),
            "instance_count": design.instances.len(),
            "cross_module_path_count": design.cross_module_paths.len(),
            "opportunity_count": design.opportunities.len(),
            "sta_hint_count": sta_hints.len(),
            "note": "CST lowered to operator regions + FO4-ranked paths + P2 instance graph + sta_hints"
        },
        "modules": modules_json,
        "packages": packages_json,
        "instances": instances_json,
        "cross_module_paths": cross_paths_json,
        "paths": paths_json,
        "path_class_summary": path_class_summary(design),
        "path_exceptions": design.path_exceptions,
        "relocation_plan": build_relocation_plan(design),
        "opportunities": opportunities,
        "sta_hints": sta_hints,
        "frequency_closure": {
            "target_mhz": closure.target_mhz,
            "budget_fo4": closure.budget_fo4,
            "closes": closure.closes,
            "worst_path_id": closure.worst_path_id,
            "worst_slack_fo4": closure.worst_slack_fo4,
            "worst_path_fo4": closure.worst_path_fo4,
            "worst_startpoint": closure.worst_startpoint,
            "worst_endpoint": closure.worst_endpoint,
            "worst_path_kind": closure.worst_path_kind,
            "max_freq_mhz": closure.max_freq_mhz,
            "failing_paths": closure.failing_paths,
            "reg_to_reg_paths": closure.reg_to_reg_paths,
        },
        "param_map_keys": design.param_map_keys,
        "package_mode": design.package_mode,
        "versions": {
            "ir": IR_VERSION,
            "parser_pin": PARSER_PIN_HINT,
            "cost_model": design.versions.cost_model,
            "measurement": MEASUREMENT_VERSION,
            "package": env!("CARGO_PKG_VERSION"),
        }
    })
}

fn package_mode_on(s: &str) -> bool {
    matches!(s.trim().to_ascii_lowercase().as_str(), "packages" | "on" | "true" | "1")
}

fn build_param_map(
    param_map: Option<PathBuf>,
    cfg_snapshot: Option<PathBuf>,
    assume_xlen: Option<u32>,
) -> Result<ParamMap, String> {
    let mut map = ParamMap::new();
    let path = param_map.or(cfg_snapshot);
    if let Some(p) = path {
        map = ParamMap::load_path(&p).map_err(|e| e.to_string())?;
    }
    if let Some(x) = assume_xlen {
        map = map.with_assume_xlen(x);
    }
    Ok(map)
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match cli.command {
        Commands::Status { cache, json_out } => {
            println!("{}", banner());
            println!("ir_version={IR_VERSION}");
            println!("crc_algo={CRC_ALGO}");
            println!("cache_schema={CACHE_SCHEMA_VERSION}");
            let mut counts: Option<CacheCounts> = None;
            let mut cache_path_s: Option<String> = None;
            if let Some(c) = &cache {
                println!("cache={}", c.display());
                cache_path_s = Some(c.display().to_string());
                match TimingCache::open(CacheConfig::at(c)) {
                    Ok(db) => match db.counts() {
                        Ok(ct) => {
                            println!(
                                "cache_counts files={} modules={} designs={} runs={}",
                                ct.files, ct.modules, ct.designs, ct.runs
                            );
                            counts = Some(ct);
                        }
                        Err(e) => eprintln!("warning: cache counts: {e}"),
                    },
                    Err(e) => eprintln!("warning: open cache: {e}"),
                }
            } else {
                println!("cache=(none; pass --cache PATH to inspect)");
            }
            if let Some(out) = json_out {
                let body = serde_json::json!({
                    "schema_version": "0",
                    "banner": banner(),
                    "ir_version": IR_VERSION,
                    "crc_algo": CRC_ALGO,
                    "cache_schema": CACHE_SCHEMA_VERSION,
                    "cache": cache_path_s,
                    "cache_counts": counts,
                });
                if let Err(e) = write_json(&out, &body) {
                    eprintln!("error: {e}");
                    return ExitCode::from(1);
                }
                println!("json_out={}", out.display());
            }
            ExitCode::SUCCESS
        }
        Commands::Analyze {
            files,
            files_from,
            incdirs,
            defines,
            modules,
            all_modules,
            target_mhz,
            fo4_ps,
            budget_margin,
            cache,
            json_out,
            param_map,
            cfg_snapshot,
            assume_xlen,
            package_mode,
            allow_parse_errors,
            opt,
        } => {
            let opt = match opt.resolve(None) {
                Ok(o) => o,
                Err(e) => {
                    eprintln!("error: {e}");
                    return ExitCode::from(2);
                }
            };
            if !all_modules && modules.as_ref().map(|s| s.trim().is_empty()).unwrap_or(true) {
                eprintln!(
                    "error: analyze requires --modules <a,b> or --all-modules (see AGENTS.md / DESIGN.md KD17)"
                );
                return ExitCode::from(2);
            }
            let project = match load_project_inputs(files, files_from, incdirs, defines) {
                Ok(p) => p,
                Err(e) => {
                    eprintln!("error: {e}");
                    return ExitCode::from(1);
                }
            };
            let paths = project.files.clone();
            if paths.is_empty() {
                eprintln!("error: no input files (use --file / --files-from)");
                return ExitCode::from(2);
            }

            let parse_opts = ParseOptions {
                include_paths: project.incdirs.clone(),
                defines: project.defines_for_parse(),
                ignore_include_error: false,
                // Dial 10a: parallel file parse.
                jobs: opt.jobs,
                allow_parse_errors,
            };

            let module_filter = if all_modules {
                Vec::new()
            } else {
                parse_module_list(modules.as_deref().unwrap_or(""))
            };

            let mut lower = LowerOptions {
                target: TimingTarget::new(target_mhz, fo4_ps, budget_margin),
                cost_model: load_fo4_v1_default(),
                module_filter: module_filter.clone(),
                param_map: match build_param_map(param_map, cfg_snapshot, assume_xlen) {
                    Ok(m) => m,
                    Err(e) => {
                        eprintln!("error: {e}");
                        return ExitCode::from(1);
                    }
                },
                package_mode: package_mode_on(&package_mode),
                opt: opt.clone(),
            };
            // Keep fo4_ps override on model id only; table values from fo4-v1.
            lower.cost_model.id = "fo4-v1".into();

            // Dial 10b: `off` bypasses SQLite entirely.
            let cache = cache.filter(|_| opt.cache_mode.uses_sqlite());
            let analyzed = if let Some(cache_path) = cache {
                let mut db = match TimingCache::open(CacheConfig::at(&cache_path)) {
                    Ok(c) => c,
                    Err(e) => {
                        eprintln!("error open cache: {e}");
                        return ExitCode::from(1);
                    }
                };
                match analyze_with_cache(&paths, &parse_opts, &lower, &mut db) {
                    Ok(cached) => {
                        println!(
                            "  cache design_hit={} files_stable={} files_changed={} pp={}",
                            cached.stats.design_hit,
                            cached.stats.files_content_stable,
                            cached.stats.files_changed,
                            &cached.stats.pp_fingerprint[..12.min(cached.stats.pp_fingerprint.len())]
                        );
                        Ok((cached.output, Some(cached.stats), cached.from_cache))
                    }
                    Err(e) => Err(e),
                }
            } else {
                analyze_files(&paths, &parse_opts, &lower).map(|o| (o, None, false))
            };

            match analyzed {
                Ok((out, cache_stats, from_cache)) => {
                    println!("{}", banner());
                    println!("opt={}", opt.summary());
                    println!("target_mhz={target_mhz}");
                    println!("from_cache={from_cache}");
                    println!("modules={}", out.design.modules.len());
                    println!("paths={}", out.design.paths.len());
                    println!("opportunities={}", out.design.opportunities.len());
                    if !out.skipped_files.is_empty() {
                        println!(
                            "skipped_files={} (parse errors; reading covers the rest)",
                            out.skipped_files.len()
                        );
                        for s in &out.skipped_files {
                            println!("  skip {}", s.path.display());
                        }
                    }
                    for m in out.design.modules.values() {
                        println!(
                            "  module {} nodes={} regions={}",
                            m.name,
                            m.nodes.len(),
                            m.regions.len()
                        );
                    }
                    let modules_requested: serde_json::Value = if all_modules {
                        serde_json::json!("*")
                    } else {
                        serde_json::json!(module_filter)
                    };
                    let file_meta: Vec<(String, usize)> = paths
                        .iter()
                        .filter_map(|p| {
                            std::fs::metadata(p)
                                .ok()
                                .map(|m| (p.display().to_string(), m.len() as usize))
                        })
                        .collect();

                    if let Some(jpath) = json_out {
                        let mut body = design_to_analyze_json(
                            &out.design,
                            &file_meta,
                            modules_requested,
                            target_mhz,
                            fo4_ps,
                            budget_margin,
                        );
                        if let Some(o) = body.as_object_mut() {
                            o.insert("opt".into(), opt_to_json(&opt));
                            o.insert(
                                "skipped_files".into(),
                                serde_json::json!(out
                                    .skipped_files
                                    .iter()
                                    .map(|s| serde_json::json!({
                                        "path": s.path.display().to_string(),
                                        "message": s.message,
                                    }))
                                    .collect::<Vec<_>>()),
                            );
                        }
                        if let Some(st) = cache_stats {
                            if let Some(o) = body.as_object_mut() {
                                o.insert(
                                    "cache".into(),
                                    serde_json::json!({
                                        "from_cache": from_cache,
                                        "design_hit": st.design_hit,
                                        "module_hits": st.module_hits,
                                        "module_misses": st.module_misses,
                                        "files_content_stable": st.files_content_stable,
                                        "files_changed": st.files_changed,
                                        "pp_fingerprint": st.pp_fingerprint,
                                        "design_key": st.design_key,
                                        "crc_algo": CRC_ALGO,
                                    }),
                                );
                            }
                        }
                        if let Err(e) = write_json(&jpath, &body) {
                            eprintln!("error writing {}: {e}", jpath.display());
                            return ExitCode::from(1);
                        }
                        println!("json_out={}", jpath.display());
                    }
                    ExitCode::SUCCESS
                }
                Err(e) => {
                    eprintln!("error: {e}");
                    ExitCode::from(1)
                }
            }
        }
        Commands::Correct {
            files,
            files_from,
            incdirs,
            defines,
            modules_allow,
            modules,
            all_modules,
            target_mhz,
            fo4_ps,
            budget_margin,
            allow_latency,
            assume_clk,
            max_passes,
            dry_run,
            emit,
            out_dir,
            emit_dir,
            preserve_rel,
            emit_unchanged,
            real_cut_feeds,
            emit_balance_mux_rtl,
            json_out,
            param_map,
            cfg_snapshot,
            assume_xlen,
            package_mode,
            allow_parse_errors,
            opt,
        } => {
            let opt = match opt.resolve(max_passes) {
                Ok(o) => o,
                Err(e) => {
                    eprintln!("error: {e}");
                    return ExitCode::from(2);
                }
            };
            let mut allow = parse_module_list(&modules_allow);
            if allow.is_empty() {
                if let Some(m) = &modules {
                    allow = parse_module_list(m);
                }
            }
            let dry = if emit { false } else { dry_run };
            // Resolve output directory: --out-dir preferred, else --emit-dir
            let emit_root = out_dir.or(emit_dir);
            println!("{}", banner());
            println!("opt={}", opt.summary());
            println!(
                "correct dry_run={dry} allow_latency={allow_latency} assume_clk={assume_clk} target_mhz={target_mhz} all_modules={all_modules}"
            );
            if !allow_latency && opt.allows_new_state() {
                println!(
                    "  note: {} would pipeline, but --allow-latency is absent \u{2192} latency-neutral only",
                    opt.level.as_str()
                );
            }

            // Project inputs: filelist + CLI files / incdir / define
            let project = match load_project_inputs(files, files_from, incdirs, defines) {
                Ok(p) => p,
                Err(e) => {
                    eprintln!("error: {e}");
                    return ExitCode::from(1);
                }
            };
            let paths = project.files.clone();

            // --all-modules: empty allow filter means lower keeps every module; correct allow
            // is filled after analyze from discovered module names.
            let mut policy = PassPolicy::from_opt(
                opt.clone(),
                if all_modules { Vec::new() } else { allow.clone() },
                allow_latency,
            );
            if all_modules {
                // Allowlist is filled after analyze discovers module names.
                policy.correct_enabled = opt.max_passes > 0;
                policy.correct_allow_modules = Vec::new();
            }

            let (design, names, source_pairs, allow) = if paths.is_empty()
                || (!all_modules && allow.is_empty())
            {
                let target = TimingTarget::new(target_mhz, fo4_ps, budget_margin);
                (
                    TimingDesign::empty(target),
                    NameTable::new(),
                    Vec::new(),
                    allow,
                )
            } else {
                let parse_opts = ParseOptions {
                    include_paths: project.incdirs.clone(),
                    defines: project.defines_for_parse(),
                    ignore_include_error: false,
                    jobs: opt.jobs,
                    allow_parse_errors,
                };
                let module_filter = if all_modules {
                    Vec::new()
                } else {
                    allow.clone()
                };
                let mut lower = LowerOptions {
                    target: TimingTarget::new(target_mhz, fo4_ps, budget_margin),
                    cost_model: load_fo4_v1_default(),
                    module_filter,
                    param_map: match build_param_map(param_map, cfg_snapshot, assume_xlen) {
                        Ok(m) => m,
                        Err(e) => {
                            eprintln!("error: {e}");
                            return ExitCode::from(1);
                        }
                    },
                    package_mode: package_mode_on(&package_mode),
                    opt: opt.clone(),
                };
                lower.cost_model.id = "fo4-v1".into();
                match analyze_files(&paths, &parse_opts, &lower) {
                    Ok(out) => {
                        println!(
                            "  analyzed modules={} paths={} opportunities={} files={}",
                            out.design.modules.len(),
                            out.design.paths.len(),
                            out.design.opportunities.len(),
                            paths.len()
                        );
                        for m in out.design.modules.values() {
                            println!(
                                "    module {} file={} nodes={}",
                                m.name,
                                m.file,
                                m.nodes.len()
                            );
                        }
                        let mut sources = Vec::new();
                        for p in &paths {
                            if let Ok(text) = std::fs::read_to_string(p) {
                                sources.push((p.clone(), text));
                            }
                        }
                        let allow_resolved = if all_modules {
                            out.design
                                .modules
                                .values()
                                .map(|m| m.name.clone())
                                .collect()
                        } else {
                            allow
                        };
                        (out.design, out.names, sources, allow_resolved)
                    }
                    Err(e) => {
                        eprintln!("error: {e}");
                        return ExitCode::from(1);
                    }
                }
            };

            // Re-apply allowlist on policy after all-modules resolve
            // (`policy` is already `mut`; a rebinding here is redundant.)
            if all_modules {
                policy.correct_allow_modules = allow.clone();
                policy.correct_enabled = !allow.is_empty();
            }

            let mut ctx = PassContext::new(design, names, policy);
            ctx.assume_clk = assume_clk;
            ctx.cost_model = load_fo4_v1_default();
            let fo4_before = ctx
                .design
                .paths
                .iter()
                .map(|p| p.total_fo4)
                .fold(0.0_f64, f64::max);

            let ctx = match run_correct_passes(ctx) {
                Ok(c) => c,
                Err(e) => {
                    eprintln!("error: {e}");
                    return ExitCode::from(1);
                }
            };

            let fo4_after = ctx
                .design
                .paths
                .iter()
                .map(|p| p.total_fo4)
                .fold(0.0_f64, f64::max);

            // Post-correct re-analyze gate (IR): frequency_closure on transformed design.
            let post_closure = frequency_closure(&ctx.design);
            println!(
                "  post_closure closes={} worst={} -> {} slack={:.1} max_mhz={:.1}",
                post_closure.closes,
                post_closure.worst_startpoint,
                post_closure.worst_endpoint,
                post_closure.worst_slack_fo4,
                post_closure.max_freq_mhz
            );

            let edits: Vec<serde_json::Value> = ctx
                .trace
                .records
                .iter()
                .map(|r| {
                    serde_json::json!({
                        "id": r.id,
                        "kind": format!("{:?}", r.kind).to_ascii_lowercase(),
                        "origin": {
                            "file": r.origin.file,
                            "start_line": r.origin.start_line,
                            "start_col": r.origin.start_col,
                            "end_line": r.origin.end_line,
                            "end_col": r.origin.end_col,
                        },
                        "path_id": r.path_id,
                        "node_id": r.node_id,
                        "new_name": r.new_name,
                        "fo4_before": r.fo4_before,
                        "fo4_after": r.fo4_after,
                        "rationale": r.rationale,
                    })
                })
                .collect();

            let mut integrity = serde_json::json!({
                "reparse_ok": true,
                "structural_ok": true,
                "messages": Vec::<String>::new(),
            });
            // Emit reparse may fail on host macros in full monorepo trees; still
            // record FO4 JSON. Hard-fail only when !allow_parse_errors.
            let mut integrity_hard_fail = false;
            let mut emit_dir_s: Option<String> = None;
            let mut filelist_s: Option<String> = None;
            let mut manifest_s: Option<String> = None;
            let mut project_entries: Vec<serde_json::Value> = Vec::new();
            let mut density = DensityReport::default();
            let mut post_analyze_json: Option<serde_json::Value> = None;

            if !dry && !source_pairs.is_empty() && !ctx.trace.records.is_empty() {
                let dir =
                    emit_root.unwrap_or_else(|| PathBuf::from(".sv-timing-out/corrected"));
                let emit_policy = EmitPolicy {
                    tool: "sv-timing".into(),
                    run_id: "correct".into(),
                    origin_comments: true,
                };
                // Multi-file projects (package + module): always passthrough unchanged
                // sources so imports/localparams still resolve under out-dir.
                let emit_all = emit_unchanged || source_pairs.len() > 1;
                if real_cut_feeds || emit_balance_mux_rtl {
                    println!(
                        "  emit richer: real_cut_feeds={real_cut_feeds} emit_balance_mux_rtl={emit_balance_mux_rtl}"
                    );
                }
                let proj_opts = ProjectEmitOptions {
                    out_dir: dir.clone(),
                    layout: if preserve_rel {
                        ProjectLayout::PreserveRel
                    } else {
                        ProjectLayout::Flat
                    },
                    source_root: None, // inferred inside emit_project_autocorrect
                    write_filelist: true,
                    write_manifest: true,
                    generated_subdir: "generated".into(),
                    emit_unchanged: emit_all,
                    real_cut_feeds,
                    emit_balance_mux_rtl,
                };
                match emit_project_autocorrect(
                    &source_pairs,
                    &ctx.trace,
                    &emit_policy,
                    proj_opts,
                ) {
                    Ok(proj) => {
                        println!("out_dir={}", proj.out_dir);
                        if let Some(fl) = &proj.filelist_path {
                            println!("  filelist={fl}");
                            filelist_s = Some(fl.clone());
                        }
                        if let Some(mp) = &proj.manifest_path {
                            println!("  manifest={mp}");
                            manifest_s = Some(mp.clone());
                        }
                        for w in &proj.written {
                            println!("  wrote {w}");
                        }
                        for e in &proj.entries {
                            project_entries.push(serde_json::json!({
                                "source": e.source,
                                "emit_rel": e.emit_rel,
                                "edit_count": e.edit_count,
                                "is_new": e.is_new,
                                "modules": e.modules,
                            }));
                        }
                        // Density: first corrected (non-new) auto-correct region
                        for f in proj.tree.files.values() {
                            if let Some(region) =
                                f.text.split("BEGIN sv-timing auto-correct").nth(1)
                            {
                                density = DensityReport::from_sv_fragment(region);
                                break;
                            }
                        }
                        // Map emit rel path → original source for preexisting-parse soft.
                        let origin_map: std::collections::BTreeMap<String, PathBuf> = proj
                            .entries
                            .iter()
                            .filter(|e| !e.source.is_empty())
                            .map(|e| (e.emit_rel.clone(), PathBuf::from(&e.source)))
                            .collect();
                        let rep = integrity_reparse_ex(
                            &proj.tree,
                            &ParseOptions {
                                include_paths: project.incdirs.clone(),
                                defines: project.defines_for_parse(),
                                ignore_include_error: false,
                                jobs: opt.jobs,
                                // Emitted SV must parse: integrity is never lenient.
                                allow_parse_errors: false,
                            },
                            Some(&origin_map),
                        );
                        integrity = serde_json::json!({
                            "reparse_ok": rep.reparse_ok,
                            "structural_ok": rep.structural_ok,
                            "joint_ok": rep.joint_ok,
                            "context_soft": rep.context_soft,
                            "messages": rep.messages,
                            // Soft when parse-errors allowed OR when only define/include
                            // context gaps remain on passthrough after edited syntax ok.
                            "soft": (!rep.reparse_ok && allow_parse_errors)
                                || (rep.reparse_ok && rep.context_soft && !rep.joint_ok),
                        });
                        if !rep.reparse_ok {
                            eprintln!(
                                "{}: emitted SV failed reparse",
                                if allow_parse_errors {
                                    "warning"
                                } else {
                                    "error"
                                }
                            );
                            for m in &rep.messages {
                                eprintln!("  integrity: {m}");
                            }
                            if allow_parse_errors {
                                eprintln!(
                                    "  note: --allow-parse-errors: FO4/report still written; emit is review-only"
                                );
                            } else {
                                integrity_hard_fail = true;
                            }
                        } else if rep.context_soft && !rep.joint_ok {
                            eprintln!(
                                "note: emit integrity: edited syntax ok; joint/context soft (defines/includes)"
                            );
                            for m in rep.messages.iter().take(8) {
                                eprintln!("  integrity: {m}");
                            }
                        }
                        // Post-correct re-analyze of first rewritten source (not generated stubs)
                        if rep.reparse_ok {
                        if let Some(first_entry) = proj.entries.iter().find(|e| !e.is_new) {
                            let first = PathBuf::from(&first_entry.emit_path);
                            if first.is_file() {
                                let mut lower = LowerOptions {
                                    target: TimingTarget::new(target_mhz, fo4_ps, budget_margin),
                                    cost_model: load_fo4_v1_default(),
                                    module_filter: allow.clone(),
                                    param_map: ParamMap::new(),
                                    package_mode: false,
                                    opt: opt.clone(),
                                };
                                lower.cost_model.id = "fo4-v1".into();
                                if let Ok(post) = analyze_files(
                                    &[first.clone()],
                                    &ParseOptions::default(),
                                    &lower,
                                ) {
                                    let file_meta = vec![(
                                        first.display().to_string(),
                                        std::fs::metadata(&first)
                                            .map(|m| m.len() as usize)
                                            .unwrap_or(0),
                                    )];
                                    post_analyze_json = Some(design_to_analyze_json(
                                        &post.design,
                                        &file_meta,
                                        serde_json::json!(allow.clone()),
                                        target_mhz,
                                        fo4_ps,
                                        budget_margin,
                                    ));
                                    let pc = frequency_closure(&post.design);
                                    println!(
                                        "  post_analyze_sv closes={} max_mhz={:.1} paths={}",
                                        pc.closes,
                                        pc.max_freq_mhz,
                                        post.design.paths.len()
                                    );
                                }
                            }
                        }
                        } // end if rep.reparse_ok post-analyze
                        emit_dir_s = Some(proj.out_dir);
                    }
                    Err(e) => {
                        eprintln!("error emit: {e}");
                        return ExitCode::from(1);
                    }
                }
            } else if !dry {
                if let Some(dir) = emit_root {
                    let _ = std::fs::create_dir_all(&dir);
                    emit_dir_s = Some(dir.display().to_string());
                }
            } else if !ctx.trace.records.is_empty() {
                // Dry-run density estimate from synthetic dense block text
                let policy = EmitPolicy::default();
                let dummy = "module x;\nendmodule\n";
                let text = sv_timing_emit::apply_edits_to_source(dummy, &ctx.trace, &policy);
                if let Some(region) = text.split("BEGIN sv-timing auto-correct").nth(1) {
                    density = DensityReport::from_sv_fragment(region);
                }
            }

            let min_dens = min_density_score_for_trace(&ctx.trace);
            let density_ok = ctx.trace.records.is_empty() || density.score() >= min_dens;

            let note = if allow.is_empty() {
                "correct: empty modules-allow — no transforms (connection OK)".to_string()
            } else if paths.is_empty() {
                "correct: no source files — skipped analyze (pass --files-from)".to_string()
            } else if dry {
                format!(
                    "correct: dry-run done; edits={} max_path_fo4 {:.1}->{:.1} post_closes={} dens={}",
                    ctx.trace.records.len(),
                    fo4_before,
                    fo4_after,
                    post_closure.closes,
                    density.score()
                )
            } else {
                format!(
                    "correct: emit done; edits={} max_path_fo4 {:.1}->{:.1} post_closes={} dens={}",
                    ctx.trace.records.len(),
                    fo4_before,
                    fo4_after,
                    post_closure.closes,
                    density.score()
                )
            };

            if let Some(out) = json_out {
                let body = serde_json::json!({
                    "schema_version": "0",
                    "disclaimer": "auto-correct multi-pass on analyzed IR — structural FO4 only",
                    "dry_run": dry,
                    "allow_latency": allow_latency,
                    "modules_allowlist": allow,
                    "all_modules": all_modules,
                    "input_files": paths.iter().map(|p| p.display().to_string()).collect::<Vec<_>>(),
                    "edits": edits,
                    "emit_dir": emit_dir_s,
                    "out_dir": emit_dir_s,
                    "filelist": filelist_s,
                    "manifest": manifest_s,
                    "project_entries": project_entries,
                    "max_path_fo4_before": fo4_before,
                    "max_path_fo4_after": fo4_after,
                    "post_closure": {
                        "target_mhz": post_closure.target_mhz,
                        "budget_fo4": post_closure.budget_fo4,
                        "closes": post_closure.closes,
                        "worst_path_id": post_closure.worst_path_id,
                        "worst_slack_fo4": post_closure.worst_slack_fo4,
                        "worst_path_fo4": post_closure.worst_path_fo4,
                        "worst_startpoint": post_closure.worst_startpoint,
                        "worst_endpoint": post_closure.worst_endpoint,
                        "worst_path_kind": post_closure.worst_path_kind,
                        "max_freq_mhz": post_closure.max_freq_mhz,
                        "failing_paths": post_closure.failing_paths,
                        "reg_to_reg_paths": post_closure.reg_to_reg_paths,
                    },
                    "post_analyze": post_analyze_json,
                    "density": {
                        "score": density.score(),
                        "min_required": min_dens,
                        "ok": density_ok,
                        "dense_lines": density.dense_lines,
                        "parameters": density.parameters,
                        "assignments": density.assignments,
                        "predicates": density.predicates,
                        "begin_end": density.begin_end,
                        "ternaries": density.ternaries,
                        "always_blocks": density.always_blocks,
                        "moved_locals": density.moved_locals,
                    },
                    "note": note,
                    "integrity": integrity,
                    "opt": opt_to_json(&opt),
                    "path_class_summary": path_class_summary(&ctx.design),
                    "path_exceptions": &ctx.design.path_exceptions,
                    "relocation_plan": ctx
                        .relocation
                        .clone()
                        .unwrap_or_else(|| build_relocation_plan(&ctx.design)),
                });
                if let Err(e) = write_json(&out, &body) {
                    eprintln!("error: {e}");
                    return ExitCode::from(1);
                }
                println!("json_out={}", out.display());
            }
            println!("{note}");
            if integrity_hard_fail {
                ExitCode::from(1)
            } else {
                ExitCode::SUCCESS
            }
        }
        Commands::DebugExport {
            out_dir,
            tag,
            json_out,
            files_from,
            modules,
            incdirs,
        } => {
            if let Err(e) = std::fs::create_dir_all(&out_dir) {
                eprintln!("error: {e}");
                return ExitCode::from(1);
            }

            let (design, names, note) = if let Some(ff) = files_from {
                match load_files_from(&ff) {
                    Ok(paths) => {
                        let parse_opts = ParseOptions {
                            include_paths: incdirs,
                            defines: vec![],
                            ignore_include_error: false,
                            jobs: None,
                            allow_parse_errors: false,
                        };
                        let filter = modules
                            .as_ref()
                            .map(|s| parse_module_list(s))
                            .unwrap_or_default();
                        let lower = LowerOptions {
                            target: TimingTarget::new(1000.0, 20.0, 0.2),
                            cost_model: load_fo4_v1_default(),
                            module_filter: filter,
                            param_map: ParamMap::new(),
                            package_mode: false,
                            opt: OptOptions::default(),
                        };
                        match analyze_files(&paths, &parse_opts, &lower) {
                            Ok(out) => (
                                out.design,
                                out.names,
                                format!("lowered IR from {}", paths.len()),
                            ),
                            Err(e) => {
                                eprintln!("error: {e}");
                                return ExitCode::from(1);
                            }
                        }
                    }
                    Err(e) => {
                        eprintln!("error: {e}");
                        return ExitCode::from(1);
                    }
                }
            } else {
                (
                    TimingDesign::empty(TimingTarget::new(1000.0, 20.0, 0.2)),
                    NameTable::new(),
                    "empty IR snapshot".into(),
                )
            };

            let ranked = rank_paths_by_slack(&design.paths, &design.target);
            let snap = match debug_snapshot_pass(
                &out_dir,
                &tag,
                &design,
                &ranked,
                &names,
                &DebugOptions::default(),
            ) {
                Ok(s) => s,
                Err(e) => {
                    eprintln!("error: {e}");
                    return ExitCode::from(1);
                }
            };

            let files: Vec<String> = snap
                .files
                .iter()
                .map(|p| p.display().to_string())
                .collect();
            let dir = out_dir.join(&tag);
            println!("{}", banner());
            println!("debug-export dir={}", dir.display());
            for f in &files {
                println!("  {f}");
            }

            let meta_path = json_out.unwrap_or_else(|| out_dir.join("debug-export.json"));
            let body = serde_json::json!({
                "schema_version": "0",
                "tag": tag,
                "dir": dir.display().to_string(),
                "files": files,
                "modules": modules,
                "note": note,
                "path_count": design.paths.len(),
                "module_count": design.modules.len(),
            });
            if let Err(e) = write_json(&meta_path, &body) {
                eprintln!("error: {e}");
                return ExitCode::from(1);
            }
            println!("json_out={}", meta_path.display());
            ExitCode::SUCCESS
        }
    }
}
