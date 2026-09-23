// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Optimization tasks. Performance is an assembly soak's cycle count.
// Area is the structural area report for that same RTL snapshot.

//! One folder per optimization task.
//!
//! A task names the assembly tests that can move, the configurations those
//! tests care about, and a series of RTL changes. Each change records the
//! soak cycle count and the structural area of that snapshot. The first
//! change in a configuration is the baseline. A later change's benefit is
//! `(baseline_cycles - cycles) / baseline_cycles`. Positive means the RTL
//! got faster. Area delta is the silicon change under the same weight table.

use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

use serde_json::{json, Value};

/// Report id.
pub const MARKS_MODEL: &str = "area-asm-marks-v1";

/// One assembly test a task uses to measure a configuration.
#[derive(Debug, Clone, PartialEq)]
pub struct TaskTest {
    /// Stable id. Soak logs use this string.
    pub id: String,
    /// `cpu`, `graphics`, `ai`, or `coherence`.
    pub lane: String,
    /// Payload operations the assembly performs. Not a cycle count.
    pub work: u64,
    /// Configuration names this test is allowed to speak for.
    pub configs: Vec<String>,
    /// Path of the assembly, relative to the task folder.
    pub asm: String,
}

/// One RTL snapshot inside a task.
#[derive(Debug, Clone, PartialEq)]
pub struct ChangePoint {
    /// Name of this development step.
    pub change: String,
    /// Configuration values for this soak, such as `coherence=on`.
    pub config: BTreeMap<String, String>,
    /// Structural area of this RTL snapshot, when an area report was recorded.
    pub area_au: Option<f64>,
    /// Exclusive area of named modules in that snapshot.
    pub modules: BTreeMap<String, f64>,
    /// Cycle counts keyed by test id.
    pub cycles: BTreeMap<String, u64>,
}

/// Scored view of one task folder.
#[derive(Debug, Clone, PartialEq)]
pub struct TaskScore {
    /// Folder name.
    pub id: String,
    /// What decision this folder is for.
    pub summary: String,
    /// True when the checked-in series is an illustration, not a soak.
    pub example: bool,
    /// True when at least one change recorded a cycle count.
    pub measured: bool,
    /// Tests this task can move.
    pub tests: Vec<TaskTest>,
    /// Changes grouped by configuration text, in file order.
    pub groups: Vec<ConfigGroup>,
    /// Test ids in the series that this task does not declare.
    pub unknown_tests: Vec<String>,
}

/// One configuration, with the RTL changes measured on it.
#[derive(Debug, Clone, PartialEq)]
pub struct ConfigGroup {
    /// Sorted `key=value` pairs joined by commas.
    pub config: String,
    /// Changes in the order the series listed them.
    pub changes: Vec<ScoredChange>,
}

/// One RTL change on one configuration.
#[derive(Debug, Clone, PartialEq)]
pub struct ScoredChange {
    /// Change name.
    pub change: String,
    /// Structural area of this snapshot.
    pub area_au: Option<f64>,
    /// Area minus the first change's area. Absent when either side omitted area.
    pub area_delta: Option<f64>,
    /// Exclusive-area change for each module present on both snapshots.
    pub module_deltas: BTreeMap<String, f64>,
    /// Per-test cycle results.
    pub tests: Vec<ScoredTest>,
    /// `faster_same_area`, `faster_more_area`, `slower`, `same`, or `unmeasured`.
    pub decision: &'static str,
}

/// One assembly result inside a change.
#[derive(Debug, Clone, PartialEq)]
pub struct ScoredTest {
    /// Test id.
    pub id: String,
    /// Lane copied from the task.
    pub lane: String,
    /// Configurations this test speaks for.
    pub configs: Vec<String>,
    /// Payload work.
    pub work: u64,
    /// Measured cycles. Absent when this change did not record the test.
    pub cycles: Option<u64>,
    /// `100 * work / cycles` when cycles were recorded.
    pub mark: Option<f64>,
    /// Cycle reduction against the first change of this configuration.
    pub benefit: Option<f64>,
    /// `unmeasured` when cycles are missing.
    pub null_reason: Option<&'static str>,
}

/// Marks block stored on an area report.
#[derive(Debug, Clone, PartialEq)]
pub struct AsmMarks {
    /// `area-asm-marks-v1`.
    pub model: &'static str,
    /// `asm_cycle_count`.
    pub basis: &'static str,
    /// True when a task series contained a cycle count.
    pub measured: bool,
    /// Scored task folders. Empty until a task is supplied.
    pub tasks: Vec<TaskScore>,
}

impl AsmMarks {
    /// No task folder was supplied.
    pub fn unmeasured() -> Self {
        Self {
            model: MARKS_MODEL,
            basis: "asm_cycle_count",
            measured: false,
            tasks: Vec::new(),
        }
    }

    /// JSON object for the area report.
    pub fn to_json(&self) -> Value {
        json!({
            "model": self.model,
            "basis": self.basis,
            "measured": self.measured,
            "note": "Performance is assembly soak cycles. Area is the structural area of that RTL snapshot. A positive benefit is fewer cycles than the first change of the same configuration.",
            "tasks": self.tasks.iter().map(task_json).collect::<Vec<_>>(),
        })
    }
}

/// Load every `task.json` directory under `root`, in name order.
pub fn load_opt_root(root: &Path) -> Result<AsmMarks, String> {
    let mut dirs = Vec::new();
    let entries = fs::read_dir(root).map_err(|err| format!("read {}: {err}", root.display()))?;
    for entry in entries {
        let entry = entry.map_err(|err| err.to_string())?;
        let path = entry.path();
        if path.is_dir() && path.join("task.json").is_file() {
            dirs.push(path);
        }
    }
    dirs.sort();
    let mut tasks = Vec::new();
    for dir in dirs {
        tasks.push(load_opt_task(&dir)?);
    }
    let measured = tasks.iter().any(|task| task.measured);
    Ok(AsmMarks {
        model: MARKS_MODEL,
        basis: "asm_cycle_count",
        measured,
        tasks,
    })
}

/// Read design area and the exclusive area of the named modules from an area report.
pub fn snapshot_from_area_report(
    bytes: &[u8],
    modules: &[String],
) -> Result<(f64, BTreeMap<String, f64>), String> {
    let value: Value =
        serde_json::from_slice(bytes).map_err(|err| format!("area report: {err}"))?;
    let area = value
        .pointer("/metrics/area_au")
        .and_then(Value::as_f64)
        .ok_or("area report has no metrics.area_au")?;
    let mut found = BTreeMap::new();
    if let Some(tree) = value.get("tree").and_then(Value::as_array) {
        collect_exclusive(tree, &mut found);
    }
    let mut selected = BTreeMap::new();
    for name in modules {
        let Some(area) = found.get(name) else {
            return Err(format!("area report has no module {name}"));
        };
        selected.insert(name.clone(), *area);
    }
    Ok((area, selected))
}

/// Read cycle counts from a soak log.
///
/// A JSON object with a `tests` array is accepted. Otherwise each non-comment
/// line is `test-id=cycles` or `test-id cycles`.
pub fn cycles_from_log(bytes: &[u8]) -> Result<BTreeMap<String, u64>, String> {
    if let Ok(value) = serde_json::from_slice::<Value>(bytes) {
        if value.get("tests").is_some() || value.get("series").is_some() {
            let point = if let Some(series) = value.get("series").and_then(Value::as_array) {
                series.last().ok_or("cycles log series is empty")?
            } else {
                &value
            };
            return Ok(parse_point(point)?.cycles);
        }
    }
    let text = std::str::from_utf8(bytes).map_err(|err| format!("cycles log: {err}"))?;
    let mut cycles = BTreeMap::new();
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let (id, count) = line
            .split_once(['=', ' '])
            .ok_or_else(|| format!("cycles line {line} needs id and cycles"))?;
        let count = count
            .trim()
            .parse::<u64>()
            .map_err(|_| format!("cycles for {id} are not an integer"))?;
        if count == 0 {
            return Err(format!("test {id} has zero cycles"));
        }
        cycles.insert(id.trim().to_string(), count);
    }
    Ok(cycles)
}

/// Append one RTL snapshot to `series.json`. An example series is left unchanged
/// unless `replace_example` is set, in which case the example points are dropped.
pub fn append_change(
    dir: &Path,
    change: &str,
    config: &BTreeMap<String, String>,
    area_au: Option<f64>,
    modules: &BTreeMap<String, f64>,
    cycles: &BTreeMap<String, u64>,
    replace_example: bool,
) -> Result<(), String> {
    if change.is_empty() {
        return Err("change name is empty".into());
    }
    let spec = parse_task(&fs::read(dir.join("task.json")).map_err(|err| err.to_string())?)?;
    for id in cycles.keys() {
        if !spec.tests.iter().any(|test| &test.id == id) {
            return Err(format!("cycle id {id} is not a test in this task"));
        }
        if cycles[id] == 0 {
            return Err(format!("test {id} has zero cycles"));
        }
    }
    let series_path = dir.join("series.json");
    let existing = if series_path.is_file() {
        fs::read(&series_path).map_err(|err| err.to_string())?
    } else {
        Vec::new()
    };
    let example = series_example_flag(&existing);
    if example && !replace_example {
        return Err(
            "series.json is an example. Pass --replace-example to start a measured series.".into(),
        );
    }
    let mut points = if existing.is_empty() || (example && replace_example) {
        Vec::new()
    } else {
        parse_series(&existing)?
    };
    points.push(ChangePoint {
        change: change.to_string(),
        config: config.clone(),
        area_au,
        modules: modules.clone(),
        cycles: cycles.clone(),
    });
    let body = serde_json::to_vec_pretty(&series_value(&points))
        .map_err(|err| format!("encode series: {err}"))?;
    fs::write(&series_path, body).map_err(|err| format!("write {}: {err}", series_path.display()))
}

fn collect_exclusive(rows: &[Value], found: &mut BTreeMap<String, f64>) {
    for row in rows {
        if let (Some(name), Some(area)) = (
            row.get("name").and_then(Value::as_str),
            row.get("exclusive_au").and_then(Value::as_f64),
        ) {
            found.entry(name.to_string()).or_insert(area);
        }
        if let Some(children) = row.get("children").and_then(Value::as_array) {
            collect_exclusive(children, found);
        }
    }
}

fn series_value(points: &[ChangePoint]) -> Value {
    json!({
        "example": false,
        "series": points.iter().map(|point| json!({
            "change": point.change,
            "config": point.config,
            "area_au": point.area_au,
            "modules": point.modules,
            "tests": point.cycles.iter().map(|(id, cycles)| json!({
                "id": id,
                "cycles": cycles,
            })).collect::<Vec<_>>(),
        })).collect::<Vec<_>>(),
    })
}

/// Load one task directory.
pub fn load_opt_task(dir: &Path) -> Result<TaskScore, String> {
    let task_path = dir.join("task.json");
    let bytes =
        fs::read(&task_path).map_err(|err| format!("read {}: {err}", task_path.display()))?;
    let spec = parse_task(&bytes)?;
    let series_path = dir.join("series.json");
    let points = if series_path.is_file() {
        let bytes = fs::read(&series_path)
            .map_err(|err| format!("read {}: {err}", series_path.display()))?;
        parse_series(&bytes)?
    } else {
        Vec::new()
    };
    let example =
        series_path.is_file() && series_example_flag(&fs::read(&series_path).unwrap_or_default());
    Ok(score_task(&spec, &points, example))
}

/// Score a parsed task against an ordered series of RTL snapshots.
pub fn score_task(spec: &TaskSpec, points: &[ChangePoint], example: bool) -> TaskScore {
    let mut unknown = Vec::new();
    for point in points {
        for id in point.cycles.keys() {
            if !spec.tests.iter().any(|test| &test.id == id) && !unknown.contains(id) {
                unknown.push(id.clone());
            }
        }
    }
    let mut order: Vec<String> = Vec::new();
    let mut buckets: BTreeMap<String, Vec<&ChangePoint>> = BTreeMap::new();
    for point in points {
        let key = config_text(&point.config);
        if !buckets.contains_key(&key) {
            order.push(key.clone());
        }
        buckets.entry(key).or_default().push(point);
    }
    let mut groups = Vec::new();
    for key in order {
        let column = buckets.remove(&key).unwrap_or_default();
        groups.push(score_group(&key, &spec.tests, &column));
    }
    let measured = groups.iter().any(|group| {
        group
            .changes
            .iter()
            .any(|change| change.tests.iter().any(|test| test.cycles.is_some()))
    });
    TaskScore {
        id: spec.id.clone(),
        summary: spec.summary.clone(),
        example,
        measured,
        tests: spec.tests.clone(),
        groups,
        unknown_tests: unknown,
    }
}

/// Task file before scoring.
#[derive(Debug, Clone, PartialEq)]
pub struct TaskSpec {
    /// Task id.
    pub id: String,
    /// Decision the folder exists to make.
    pub summary: String,
    /// Assembly tests.
    pub tests: Vec<TaskTest>,
}

fn score_group(config: &str, tests: &[TaskTest], points: &[&ChangePoint]) -> ConfigGroup {
    let baseline_cycles: Vec<Option<u64>> = tests
        .iter()
        .map(|test| {
            points
                .first()
                .and_then(|point| point.cycles.get(&test.id).copied())
        })
        .collect();
    let baseline_area = points.first().and_then(|point| point.area_au);
    let mut changes = Vec::new();
    for point in points {
        let mut scored = Vec::new();
        let mut any_cycles = false;
        let mut any_faster = false;
        let mut any_slower = false;
        for (test, base_cycles) in tests.iter().zip(baseline_cycles.iter()) {
            let cycles = point.cycles.get(&test.id).copied();
            let (mark, benefit, reason) = match (cycles, base_cycles) {
                (Some(0), _) => (None, None, Some("unmeasured")),
                (Some(cycles), Some(base)) if *base > 0 => {
                    any_cycles = true;
                    let benefit = (*base as f64 - cycles as f64) / *base as f64;
                    if benefit > 1e-9 {
                        any_faster = true;
                    } else if benefit < -1e-9 {
                        any_slower = true;
                    }
                    (
                        Some(100.0 * test.work as f64 / cycles as f64),
                        Some(benefit),
                        None,
                    )
                }
                (Some(cycles), _) => {
                    any_cycles = true;
                    (Some(100.0 * test.work as f64 / cycles as f64), None, None)
                }
                (None, _) => (None, None, Some("unmeasured")),
            };
            scored.push(ScoredTest {
                id: test.id.clone(),
                lane: test.lane.clone(),
                configs: test.configs.clone(),
                work: test.work,
                cycles,
                mark,
                benefit,
                null_reason: reason,
            });
        }
        let area_delta = match (point.area_au, baseline_area) {
            (Some(area), Some(base)) => Some(area - base),
            _ => None,
        };
        let mut module_deltas = BTreeMap::new();
        if let Some(baseline) = points.first() {
            for (name, area) in &point.modules {
                if let Some(before) = baseline.modules.get(name) {
                    module_deltas.insert(name.clone(), area - before);
                }
            }
        }
        let decision = if !any_cycles {
            "unmeasured"
        } else if any_slower && !any_faster {
            "slower"
        } else if any_faster {
            match area_delta {
                Some(delta) if delta > 1e-9 => "faster_more_area",
                Some(delta) if delta < -1e-9 => "faster_less_area",
                _ => "faster_same_area",
            }
        } else {
            "same"
        };
        changes.push(ScoredChange {
            change: point.change.clone(),
            area_au: point.area_au,
            area_delta,
            module_deltas,
            tests: scored,
            decision,
        });
    }
    ConfigGroup {
        config: config.to_string(),
        changes,
    }
}

fn parse_task(bytes: &[u8]) -> Result<TaskSpec, String> {
    let value: Value = serde_json::from_slice(bytes).map_err(|err| format!("task.json: {err}"))?;
    let id = value
        .get("id")
        .and_then(Value::as_str)
        .ok_or("task.json needs id")?
        .to_string();
    let summary = value
        .get("summary")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let tests_v = value
        .get("tests")
        .and_then(Value::as_array)
        .ok_or("task.json needs tests")?;
    let mut tests = Vec::new();
    for test in tests_v {
        let id = test
            .get("id")
            .and_then(Value::as_str)
            .ok_or("test needs id")?
            .to_string();
        let lane = test
            .get("lane")
            .and_then(Value::as_str)
            .unwrap_or("cpu")
            .to_string();
        let work = test
            .get("work")
            .and_then(Value::as_u64)
            .ok_or("test needs work")?;
        let asm = test
            .get("asm")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let configs = test
            .get("configs")
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_string)
                    .collect()
            })
            .unwrap_or_default();
        tests.push(TaskTest {
            id,
            lane,
            work,
            configs,
            asm,
        });
    }
    Ok(TaskSpec { id, summary, tests })
}

fn parse_series(bytes: &[u8]) -> Result<Vec<ChangePoint>, String> {
    let value: Value =
        serde_json::from_slice(bytes).map_err(|err| format!("series.json: {err}"))?;
    let points = if let Some(series) = value.get("series").and_then(Value::as_array) {
        series
    } else {
        return Ok(vec![parse_point(&value)?]);
    };
    points.iter().map(parse_point).collect()
}

fn parse_point(value: &Value) -> Result<ChangePoint, String> {
    let change = value
        .get("change")
        .and_then(Value::as_str)
        .or_else(|| value.get("rtl").and_then(Value::as_str))
        .unwrap_or("change")
        .to_string();
    let mut config = BTreeMap::new();
    if let Some(map) = value.get("config").and_then(Value::as_object) {
        for (key, item) in map {
            let text = match item {
                Value::String(text) => text.clone(),
                Value::Number(number) => number.to_string(),
                Value::Bool(flag) => flag.to_string(),
                _ => return Err(format!("config {key} must be a string or number")),
            };
            config.insert(key.clone(), text);
        }
    }
    let area_au = value.get("area_au").and_then(Value::as_f64);
    let mut modules = BTreeMap::new();
    if let Some(map) = value.get("modules").and_then(Value::as_object) {
        for (key, item) in map {
            let area = item.as_f64().ok_or_else(|| format!("module {key} area"))?;
            modules.insert(key.clone(), area);
        }
    }
    let mut cycles = BTreeMap::new();
    if let Some(tests) = value.get("tests").and_then(Value::as_array) {
        for test in tests {
            let id = test
                .get("id")
                .and_then(Value::as_str)
                .ok_or("series test needs id")?;
            let count = test
                .get("cycles")
                .and_then(Value::as_u64)
                .ok_or("series test needs cycles")?;
            if count == 0 {
                return Err(format!("test {id} has zero cycles"));
            }
            cycles.insert(id.to_string(), count);
        }
    }
    Ok(ChangePoint {
        change,
        config,
        area_au,
        modules,
        cycles,
    })
}

fn series_example_flag(bytes: &[u8]) -> bool {
    serde_json::from_slice::<Value>(bytes)
        .ok()
        .and_then(|value| value.get("example").and_then(Value::as_bool))
        .unwrap_or(false)
}

fn config_text(config: &BTreeMap<String, String>) -> String {
    config
        .iter()
        .map(|(key, value)| format!("{key}={value}"))
        .collect::<Vec<_>>()
        .join(",")
}

fn task_json(task: &TaskScore) -> Value {
    json!({
        "id": task.id,
        "summary": task.summary,
        "example": task.example,
        "measured": task.measured,
        "unknown_tests": task.unknown_tests,
        "tests": task.tests.iter().map(|test| json!({
            "id": test.id,
            "lane": test.lane,
            "work": test.work,
            "configs": test.configs,
            "asm": test.asm,
        })).collect::<Vec<_>>(),
        "groups": task.groups.iter().map(|group| json!({
            "config": group.config,
            "changes": group.changes.iter().map(|change| json!({
                "change": change.change,
                "area_au": change.area_au,
                "area_delta": change.area_delta,
                "module_deltas": change.module_deltas,
                "decision": change.decision,
                "tests": change.tests.iter().map(|test| json!({
                    "id": test.id,
                    "lane": test.lane,
                    "configs": test.configs,
                    "work": test.work,
                    "cycles": test.cycles,
                    "mark": test.mark,
                    "benefit": test.benefit,
                    "null_reason": test.null_reason,
                })).collect::<Vec<_>>(),
            })).collect::<Vec<_>>(),
        })).collect::<Vec<_>>(),
    })
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::fs;
    use std::path::PathBuf;

    use super::*;

    fn fixture(name: &str) -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures/opt-tasks")
            .join(name)
    }

    #[test]
    fn coherence_task_shows_a_faster_path_that_uses_more_area() {
        let task = load_opt_task(&fixture("coherence-shared-line")).expect("task");
        assert!(task.example);
        assert!(task.measured);
        let group = task
            .groups
            .iter()
            .find(|group| group.config.contains("coherence=on"))
            .expect("config");
        assert_eq!(group.changes.len(), 2);
        assert_eq!(group.changes[0].decision, "same");
        let next = &group.changes[1];
        assert_eq!(next.change, "snoop-filter");
        assert_eq!(next.decision, "faster_more_area");
        assert_eq!(next.area_delta, Some(120.0));
        assert_eq!(next.module_deltas.get("coherence"), Some(&120.0));
        let coherence = next
            .tests
            .iter()
            .find(|test| test.id == "coherence_shared_line")
            .unwrap();
        assert_eq!(coherence.cycles, Some(1200));
        assert!((coherence.benefit.unwrap() - 0.4).abs() < 1e-9);
        let cpu = next.tests.iter().find(|test| test.id == "cpu_ilp").unwrap();
        assert_eq!(cpu.benefit, Some(0.0));
        assert!(coherence.configs.iter().any(|name| name == "coherence"));
    }

    #[test]
    fn open_task_stays_unmeasured() {
        let task = load_opt_task(&fixture("issue-width")).expect("task");
        assert!(!task.measured);
        assert!(task.groups.is_empty());
    }

    #[test]
    fn cycles_log_accepts_lines_and_json() {
        let lines = cycles_from_log(b"# soak\ncpu_ilp 400\ncoherence_shared_line=1200\n").unwrap();
        assert_eq!(lines["cpu_ilp"], 400);
        assert_eq!(lines["coherence_shared_line"], 1200);
        let json = cycles_from_log(br#"{"tests":[{"id":"cpu_ilp","cycles":200}]}"#).unwrap();
        assert_eq!(json["cpu_ilp"], 200);
    }

    #[test]
    fn record_appends_area_and_cycles_for_a_later_change() {
        let dir = std::env::temp_dir().join(format!("svt_opt_rec_{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            dir.join("task.json"),
            r#"{"id":"rec","summary":"wider issue","tests":[{"id":"cpu_ilp","lane":"cpu","work":64,"configs":["issue"],"asm":"asm/cpu_ilp.S"}]}"#,
        )
        .unwrap();
        let report = br#"{"metrics":{"area_au":500},"tree":[{"name":"alu","exclusive_au":40,"children":[{"name":"nested","exclusive_au":3}]}]}"#;
        let (area, modules) =
            snapshot_from_area_report(report, &["alu".into(), "nested".into()]).unwrap();
        assert_eq!(area, 500.0);
        assert_eq!(modules["nested"], 3.0);
        let mut config = BTreeMap::new();
        config.insert("issue".into(), "2".into());
        let mut cycles = BTreeMap::new();
        cycles.insert("cpu_ilp".into(), 400);
        append_change(
            &dir,
            "baseline",
            &config,
            Some(area),
            &modules,
            &cycles,
            false,
        )
        .unwrap();
        cycles.insert("cpu_ilp".into(), 200);
        append_change(
            &dir,
            "wider-issue",
            &config,
            Some(area),
            &modules,
            &cycles,
            false,
        )
        .unwrap();
        let task = load_opt_task(&dir).unwrap();
        assert!(!task.example);
        let change = &task.groups[0].changes[1];
        assert_eq!(change.decision, "faster_same_area");
        assert_eq!(change.area_delta, Some(0.0));
        assert!((change.tests[0].benefit.unwrap() - 0.5).abs() < 1e-9);
        fs::write(dir.join("series.json"), r#"{"example":true,"series":[]}"#).unwrap();
        let err = append_change(
            &dir,
            "again",
            &config,
            None,
            &BTreeMap::new(),
            &cycles,
            false,
        )
        .unwrap_err();
        assert!(err.contains("example"), "{err}");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn root_lists_tasks_in_name_order() {
        let marks = load_opt_root(&fixture("")).expect("root");
        let ids: Vec<_> = marks.tasks.iter().map(|task| task.id.as_str()).collect();
        assert_eq!(ids, ["coherence-shared-line", "issue-width"]);
        assert!(marks.measured);
    }
}
