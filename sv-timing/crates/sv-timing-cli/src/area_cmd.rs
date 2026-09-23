// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// `sv-timing area`. Reads the timing IR. Does not call correct.

//! Area subcommand. Output paths stay under the process working directory.

use std::path::{Path, PathBuf};
use std::process::ExitCode;

use sv_timing_area::{
    area_key, attribute_with, default_area_v1_embedded, load_opt_root, load_opt_task,
    may_store_area_report, order_module_rows, report_json, AreaKeyParts, AsmMarks, Inclusion,
    MARKS_MODEL,
};
use sv_timing_cache::{analyze_with_cache, CacheConfig, CanonPath, TimingCache};
use sv_timing_core::{
    analyze_files, LowerOptions, ParamMap, ParseOptions, TimingDesign, TimingTarget, IR_VERSION,
    MEASUREMENT_VERSION, PATH_CLASS_DETECTOR_VERSION,
};

const AREA_TABLE: &[u8] = include_bytes!("../../../resources/area-v1.toml");

/// Inputs already checked by the CLI parser.
pub(crate) struct AreaRun {
    /// Source files.
    pub files: Vec<PathBuf>,
    /// Include directories.
    pub incdirs: Vec<PathBuf>,
    /// Defines.
    pub defines: Vec<(String, Option<String>)>,
    /// Empty means every module.
    pub module_filter: Vec<String>,
    /// Analyze default, not the correct default.
    pub target_mhz: f64,
    /// FO4 picoseconds.
    pub fo4_ps: f64,
    /// Budget margin.
    pub budget_margin: f64,
    /// Cache path already contained under the cwd.
    pub cache: Option<PathBuf>,
    /// JSON path already contained under the cwd.
    pub json_out: Option<PathBuf>,
    /// Param map for the first analyze.
    pub param_map: ParamMap,
    /// Optional second analyze.
    pub compare_map: Option<ParamMap>,
    /// `--inclusion` values.
    pub inclusion: Vec<String>,
    /// `--config-overlay` values.
    pub config_overlay: Vec<String>,
    /// Exit 4 on failure counters.
    pub strict_attribution: bool,
    /// Rank and tree cap. The CLI default is 20.
    pub top: usize,
    /// `area`, `perf`, or `perf-per-area`.
    pub metric: String,
    /// Second inclusion. Same design, different filter.
    pub compare_inclusion: Option<String>,
    /// Skip design and area cache lookups.
    pub force: bool,
    /// Area table id. Only `area-v1` is packaged.
    pub area_model: String,
    /// One optimization task directory.
    pub opt_task: Option<PathBuf>,
    /// Directory of optimization task folders.
    pub opt_root: Option<PathBuf>,
    /// Package lowering.
    pub package_mode: bool,
    /// Skip rejected files.
    pub allow_parse_errors: bool,
}

/// Reject `..` and any path that is not the cwd or a descendant of it.
pub(crate) fn contain_output(path: &Path) -> Result<PathBuf, String> {
    let raw = path.to_string_lossy();
    if raw.split(['/', '\\']).any(|segment| segment == "..") {
        return Err(format!("output path contains ..: {raw}"));
    }
    let cwd = std::env::current_dir().map_err(|err| err.to_string())?;
    let absolute = if path.is_absolute() {
        path.to_path_buf()
    } else {
        cwd.join(path)
    };
    let cwd_canon = CanonPath::new(&cwd.to_string_lossy());
    let requested = CanonPath::new(&absolute.to_string_lossy());
    if !path_inside(&cwd_canon, &requested) {
        return Err(format!(
            "output path is outside the working directory: {}",
            requested.as_str()
        ));
    }
    Ok(absolute)
}

fn path_inside(cwd: &CanonPath, requested: &CanonPath) -> bool {
    let root = cwd.as_str();
    let path = requested.as_str();
    if root == "/" {
        return path.starts_with('/');
    }
    path == root || path.starts_with(&format!("{root}/"))
}

/// Run one area report. Timing rewrite is not invoked.
pub(crate) fn run(args: AreaRun) -> ExitCode {
    let mut inclusion = Inclusion::all();
    for flag in &args.inclusion {
        if let Err(err) = inclusion.parse_flag(flag) {
            eprintln!("error: inclusion {flag}: {err:?}");
            return ExitCode::from(2);
        }
    }
    for overlay in &args.config_overlay {
        if let Err(err) = inclusion.parse_overlay(overlay) {
            eprintln!("error: config-overlay {overlay}: {err:?}");
            return ExitCode::from(2);
        }
    }

    let parse = ParseOptions {
        include_paths: args.incdirs.clone(),
        defines: args.defines.clone(),
        ignore_include_error: false,
        jobs: None,
        allow_parse_errors: args.allow_parse_errors,
    };
    let mut lower = LowerOptions {
        target: TimingTarget::new(args.target_mhz, args.fo4_ps, args.budget_margin),
        cost_model: sv_timing_core::load_fo4_v1_default(),
        module_filter: args.module_filter.clone(),
        param_map: args.param_map.clone(),
        package_mode: args.package_mode,
        ..LowerOptions::default()
    };
    lower.cost_model.id = "fo4-v1".into();

    if args.area_model != "area-v1" {
        eprintln!("error: unknown area model {}", args.area_model);
        return ExitCode::from(2);
    }
    if args.compare_inclusion.is_some() && args.compare_map.is_some() {
        eprintln!("error: compare-inclusion and compare-param-map are separate runs");
        return ExitCode::from(2);
    }
    let (design, design_key, design_hit) = match analyze(
        &args.files,
        &parse,
        &lower,
        args.cache.as_deref(),
        args.force,
    ) {
        Ok(value) => value,
        Err(err) => {
            eprintln!("error: {err}");
            return ExitCode::from(1);
        }
    };
    let design_cache = if design_hit { "hit" } else { "miss" };

    let path_class = PATH_CLASS_DETECTOR_VERSION.to_string();
    let model = default_area_v1_embedded();
    let report = match attribute_with(&design, &model, &args.param_map, &inclusion, args.top) {
        Ok(report) => report,
        Err(err) => {
            eprintln!("error: {err:?}");
            return ExitCode::from(2);
        }
    };
    let key = area_key(&key_parts(
        &design,
        &design_key,
        &inclusion.canonical(),
        &args.param_map.value_canonical(),
        path_class.as_str(),
        args.fo4_ps,
        args.budget_margin,
        args.target_mhz,
    ));
    let mut report = report;
    if let Err(err) = order_module_rows(&mut report.modules, &args.metric, report.metrics.perf_mhz)
    {
        eprintln!("error: {err}");
        return ExitCode::from(2);
    }
    if args.opt_task.is_some() && args.opt_root.is_some() {
        eprintln!("error: pass opt-task or opt-root, not both");
        return ExitCode::from(2);
    }
    if let Some(task) = &args.opt_task {
        match load_opt_task(task) {
            Ok(task) => {
                report.marks = AsmMarks {
                    model: MARKS_MODEL,
                    basis: "asm_cycle_count",
                    measured: task.measured,
                    tasks: vec![task],
                };
            }
            Err(err) => {
                eprintln!("error: {err}");
                return ExitCode::from(2);
            }
        }
    } else if let Some(root) = &args.opt_root {
        match load_opt_root(root) {
            Ok(marks) => report.marks = marks,
            Err(err) => {
                eprintln!("error: {err}");
                return ExitCode::from(2);
            }
        }
    }
    let mut body = report_json(&report, &design, &model, &design_key, &key);

    if let Some(compare_map) = &args.compare_map {
        let mut second = lower.clone();
        second.param_map = compare_map.clone();
        let (design_b, design_key_b, _) = match analyze(
            &args.files,
            &parse,
            &second,
            args.cache.as_deref(),
            args.force,
        ) {
            Ok(value) => value,
            Err(err) => {
                eprintln!("error: {err}");
                return ExitCode::from(1);
            }
        };
        let report_b = match attribute_with(&design_b, &model, compare_map, &inclusion, args.top) {
            Ok(report) => report,
            Err(err) => {
                eprintln!("error: {err:?}");
                return ExitCode::from(2);
            }
        };
        let key_b = area_key(&key_parts(
            &design_b,
            &design_key_b,
            &inclusion.canonical(),
            &compare_map.value_canonical(),
            path_class.as_str(),
            args.fo4_ps,
            args.budget_margin,
            args.target_mhz,
        ));
        body["compare"] = compare_json(&report, &report_b);
        if let Some(cache) = args.cache.as_deref() {
            if let Err(code) = store_report(
                cache,
                &design_b,
                &design_key_b,
                &key_b,
                &report_json(&report_b, &design_b, &model, &design_key_b, &key_b),
            ) {
                return code;
            }
        }
    } else if let Some(spec) = &args.compare_inclusion {
        let mut other = Inclusion::all();
        if let Err(err) = other.parse_flag(spec) {
            eprintln!("error: compare-inclusion {spec}: {err:?}");
            return ExitCode::from(2);
        }
        let report_b = match attribute_with(&design, &model, &args.param_map, &other, args.top) {
            Ok(report) => report,
            Err(err) => {
                eprintln!("error: {err:?}");
                return ExitCode::from(2);
            }
        };
        body["compare"] = compare_json(&report, &report_b);
    }

    let stored = if args.force {
        "miss".to_string()
    } else if let Some(cache) = args.cache.as_deref() {
        match store_report(cache, &design, &design_key, &key, &body) {
            Ok(status) => status,
            Err(code) => return code,
        }
    } else {
        "off".to_string()
    };
    eprintln!(
        "area_cache={stored} design_cache={design_cache} nodes={} gaps={} area_key={}",
        report.rank_exclusive_area.len(),
        report.attribution_gaps(),
        key.chars().take(12).collect::<String>()
    );

    println!(
        "gaps width={} loops={} opaque={} calls={} storage={} params={} config={} cross={} fields={} attribution={}",
        report.n_width_defaulted,
        report.n_generate_unresolved,
        report.n_opaque_child,
        report.n_body_unlowered,
        report.n_storage_unrecorded,
        report.n_instance_params_unrecorded,
        report.n_config_unresolved,
        report.n_cross_path_unresolved,
        report.n_field_absent,
        report.attribution_gaps()
    );

    if let Some(path) = &args.json_out {
        if let Err(err) = write_json(path, &body) {
            eprintln!("error: {err}");
            return ExitCode::from(1);
        }
    } else {
        println!("{body}");
    }

    if args.strict_attribution && report.attribution_gaps() > 0 {
        return ExitCode::from(4);
    }
    ExitCode::SUCCESS
}

fn analyze(
    files: &[PathBuf],
    parse: &ParseOptions,
    lower: &LowerOptions,
    cache: Option<&Path>,
    force: bool,
) -> Result<(TimingDesign, String, bool), String> {
    if force || cache.is_none() {
        let out = analyze_files(files, parse, lower).map_err(|err| err.to_string())?;
        return Ok((out.design, String::new(), false));
    }
    if let Some(path) = cache {
        let mut db = TimingCache::open(CacheConfig::at(path)).map_err(|err| err.to_string())?;
        let cached =
            analyze_with_cache(files, parse, lower, &mut db).map_err(|err| err.to_string())?;
        let hit = cached.stats.design_hit;
        let key = cached.stats.design_key.clone();
        Ok((cached.output.design, key, hit))
    } else {
        let out = analyze_files(files, parse, lower).map_err(|err| err.to_string())?;
        Ok((out.design, String::new(), false))
    }
}

fn store_report(
    cache: &Path,
    design: &TimingDesign,
    design_key: &str,
    area_key: &str,
    body: &serde_json::Value,
) -> Result<String, ExitCode> {
    if design_key.is_empty() {
        return Ok("skip".to_string());
    }
    if !may_store_area_report(1, 1, &design.emitted_lower_fields) {
        eprintln!("area_cache=refuse");
        return Err(ExitCode::from(1));
    }
    let bytes = match serde_json::to_vec(body) {
        Ok(bytes) => bytes,
        Err(err) => {
            eprintln!("error: {err}");
            return Err(ExitCode::from(1));
        }
    };
    let db = match TimingCache::open(CacheConfig::at(cache)) {
        Ok(db) => db,
        Err(err) => {
            eprintln!("error open cache: {err}");
            return Err(ExitCode::from(1));
        }
    };
    match db.get_area_report(design_key, area_key) {
        Ok(Some(_)) => return Ok("hit".to_string()),
        Ok(None) => {}
        Err(err) => {
            eprintln!("error: {err}");
            return Err(ExitCode::from(1));
        }
    }
    if let Err(err) = db.put_area_report(design_key, area_key, &bytes) {
        eprintln!("error: {err}");
        return Err(ExitCode::from(1));
    }
    Ok("miss".to_string())
}

fn key_parts<'a>(
    design: &'a TimingDesign,
    design_key: &'a str,
    inclusion: &'a str,
    param_values: &'a str,
    path_class: &'a str,
    fo4_ps: f64,
    margin: f64,
    target_mhz: f64,
) -> AreaKeyParts<'a> {
    AreaKeyParts {
        area_model: "area-v1",
        area_schema: "1",
        area_table: AREA_TABLE,
        cost_model: &design.versions.cost_model,
        decls: 1,
        design_key,
        fn_bodies: 1,
        fo4_ps,
        inclusion,
        ir: IR_VERSION,
        margin,
        measurement: MEASUREMENT_VERSION,
        param_values,
        path_class,
        target_mhz,
        marks_model: MARKS_MODEL,
    }
}

fn compare_json(
    before: &sv_timing_area::AreaReport,
    after: &sv_timing_area::AreaReport,
) -> serde_json::Value {
    let delta_area = pair_delta(before.metrics.area_au, after.metrics.area_au);
    let delta_delay = pair_delta(before.metrics.delay_fo4, after.metrics.delay_fo4);
    let tag = if before.primary_path_id != after.primary_path_id {
        Some("delay_moved")
    } else {
        match delta_delay {
            Some(delta) if delta.abs() < 1e-9 => Some("area_without_delay_change"),
            _ => None,
        }
    };
    serde_json::json!({
        "delta_area_au": delta_area,
        "delta_delay_fo4": delta_delay,
        "perf_mhz_before": before.metrics.perf_mhz,
        "perf_mhz_after": after.metrics.perf_mhz,
        "perf_per_area_before": before.metrics.perf_per_area,
        "perf_per_area_after": after.metrics.perf_per_area,
        "tag": tag,
    })
}

fn pair_delta(before: Option<f64>, after: Option<f64>) -> Option<f64> {
    Some(after? - before?)
}

fn write_json(path: &Path, value: &serde_json::Value) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent).map_err(|err| err.to_string())?;
        }
    }
    let body = serde_json::to_vec_pretty(value).map_err(|err| err.to_string())?;
    std::fs::write(path, body).map_err(|err| err.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use clap::Parser;

    #[test]
    fn slash_boundary_and_root() {
        let cwd = CanonPath::new("/work/sv");
        assert!(path_inside(&cwd, &CanonPath::new("/work/sv")));
        assert!(path_inside(&cwd, &CanonPath::new("/work/sv/out")));
        assert!(!path_inside(&cwd, &CanonPath::new("/work/sv-timing/out")));
        let root = CanonPath::new("/");
        assert!(path_inside(&root, &CanonPath::new("/tmp/ir.sqlite")));
    }

    #[test]
    fn dotdot_is_rejected() {
        let err = contain_output(Path::new("out/../secret.json")).unwrap_err();
        assert!(err.contains(".."), "{err}");
    }

    #[test]
    fn area_defaults_match_analyze() {
        let cli =
            crate::Cli::try_parse_from(["sv-timing", "area", "--all-modules", "--file", "a.sv"])
                .expect("parse");
        match cli.command {
            crate::Commands::Area {
                target_mhz,
                fo4_ps,
                budget_margin,
                strict_attribution,
                top,
                ..
            } => {
                assert_eq!(target_mhz, 1000.0);
                assert_eq!(fo4_ps, 20.0);
                assert_eq!(budget_margin, 0.2);
                assert!(!strict_attribution);
                assert_eq!(top, 20);
            }
            other => panic!("expected area, got {other:?}"),
        }
    }

    #[test]
    fn area_command_writes_a_report_for_the_case_fixture() {
        let fixture =
            PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../fixtures/exclusive_case_mux.sv");
        let json_out = PathBuf::from("area-cli-test.json");
        let cache = PathBuf::from("area-cli-test.sqlite");
        let _ = std::fs::remove_file(&json_out);
        let _ = std::fs::remove_file(&cache);
        let code = run(AreaRun {
            files: vec![fixture],
            incdirs: Vec::new(),
            defines: Vec::new(),
            module_filter: Vec::new(),
            target_mhz: 1000.0,
            fo4_ps: 20.0,
            budget_margin: 0.2,
            cache: Some(contain_output(&cache).unwrap()),
            json_out: Some(contain_output(&json_out).unwrap()),
            param_map: ParamMap::new(),
            compare_map: None,
            inclusion: Vec::new(),
            config_overlay: Vec::new(),
            strict_attribution: false,
            top: 20,
            metric: "area".into(),
            compare_inclusion: None,
            force: false,
            area_model: "area-v1".into(),
            opt_task: None,
            opt_root: None,
            package_mode: false,
            allow_parse_errors: false,
        });
        assert_eq!(code, ExitCode::SUCCESS);
        let body: serde_json::Value =
            serde_json::from_slice(&std::fs::read(&json_out).unwrap()).unwrap();
        assert_eq!(body["schema_version"], "1");
        assert_eq!(body["metrics"]["perf_basis"], "primary_path");
        assert!(body["metrics"]["perf_mhz"].is_number());
        assert!(body["compare"].is_null());
        let _ = std::fs::remove_file(&json_out);
        let _ = std::fs::remove_file(&cache);
    }
}
