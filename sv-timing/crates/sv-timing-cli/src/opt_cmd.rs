// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Score optimization task folders. Does not analyze RTL and does not rewrite it.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::process::ExitCode;

use sv_timing_area::{
    append_change, cycles_from_log, load_opt_root, load_opt_task, snapshot_from_area_report,
    AsmMarks, MARKS_MODEL,
};

use crate::area_cmd::contain_output;

/// Arguments for appending one measured RTL snapshot.
pub struct RecordArgs {
    /// Task directory.
    pub task: Option<PathBuf>,
    /// Snapshot name.
    pub change: Option<String>,
    /// `key=value` configuration entries.
    pub config: Vec<String>,
    /// `test-id=cycles` results.
    pub cycles: Vec<String>,
    /// Soak log of cycle counts. Explicit `--cycles` entries override it.
    pub cycles_file: Option<PathBuf>,
    /// Module names to copy from the area report.
    pub modules: Vec<String>,
    /// Area report for this snapshot.
    pub area_report: Option<PathBuf>,
    /// Replace an example series.
    pub replace_example: bool,
}

/// Append one snapshot, then print the task decision.
pub fn record(args: RecordArgs) -> ExitCode {
    let Some(task) = args.task else {
        eprintln!("error: --record needs --task");
        return ExitCode::from(2);
    };
    let Some(change) = args.change else {
        eprintln!("error: --record needs --change");
        return ExitCode::from(2);
    };
    let config = match pairs(&args.config, "config") {
        Ok(map) => map,
        Err(err) => {
            eprintln!("error: {err}");
            return ExitCode::from(2);
        }
    };
    let mut cycles = if let Some(path) = &args.cycles_file {
        let bytes = match std::fs::read(path) {
            Ok(bytes) => bytes,
            Err(err) => {
                eprintln!("error: {err}");
                return ExitCode::from(2);
            }
        };
        match cycles_from_log(&bytes) {
            Ok(cycles) => cycles,
            Err(err) => {
                eprintln!("error: {err}");
                return ExitCode::from(2);
            }
        }
    } else {
        BTreeMap::new()
    };
    let cycle_text = match pairs(&args.cycles, "cycles") {
        Ok(map) => map,
        Err(err) => {
            eprintln!("error: {err}");
            return ExitCode::from(2);
        }
    };
    for (id, text) in cycle_text {
        let Ok(count) = text.parse::<u64>() else {
            eprintln!("error: cycles for {id} are not an integer");
            return ExitCode::from(2);
        };
        cycles.insert(id, count);
    }
    let (area_au, modules) = if let Some(path) = &args.area_report {
        let bytes = match std::fs::read(path) {
            Ok(bytes) => bytes,
            Err(err) => {
                eprintln!("error: {err}");
                return ExitCode::from(2);
            }
        };
        match snapshot_from_area_report(&bytes, &args.modules) {
            Ok(snapshot) => (Some(snapshot.0), snapshot.1),
            Err(err) => {
                eprintln!("error: {err}");
                return ExitCode::from(2);
            }
        }
    } else if !args.modules.is_empty() {
        eprintln!("error: --module needs --area-report");
        return ExitCode::from(2);
    } else {
        (None, BTreeMap::new())
    };
    if let Err(err) = append_change(
        &task,
        &change,
        &config,
        area_au,
        &modules,
        &cycles,
        args.replace_example,
    ) {
        eprintln!("error: {err}");
        return ExitCode::from(2);
    }
    match load_opt_task(&task) {
        Ok(scored) => {
            print_marks(&AsmMarks {
                model: MARKS_MODEL,
                basis: "asm_cycle_count",
                measured: scored.measured,
                tasks: vec![scored],
            });
            ExitCode::SUCCESS
        }
        Err(err) => {
            eprintln!("error: {err}");
            ExitCode::from(2)
        }
    }
}

fn pairs(items: &[String], label: &str) -> Result<BTreeMap<String, String>, String> {
    let mut map = BTreeMap::new();
    for item in items {
        let Some((key, value)) = item.split_once('=') else {
            return Err(format!("{label} entry {item} needs key=value"));
        };
        if key.is_empty() {
            return Err(format!("{label} entry {item} has an empty key"));
        }
        map.insert(key.to_string(), value.to_string());
    }
    Ok(map)
}

/// Print the decision table for one task or every task under a root.
pub fn run(task: Option<PathBuf>, root: Option<PathBuf>, json_out: Option<PathBuf>) -> ExitCode {
    if task.is_some() && root.is_some() {
        eprintln!("error: pass --task or --root, not both");
        return ExitCode::from(2);
    }
    let marks = if let Some(task) = task {
        match load_opt_task(&task) {
            Ok(scored) => AsmMarks {
                model: sv_timing_area::MARKS_MODEL,
                basis: "asm_cycle_count",
                measured: scored.measured,
                tasks: vec![scored],
            },
            Err(err) => {
                eprintln!("error: {err}");
                return ExitCode::from(2);
            }
        }
    } else if let Some(root) = root {
        match load_opt_root(&root) {
            Ok(marks) => marks,
            Err(err) => {
                eprintln!("error: {err}");
                return ExitCode::from(2);
            }
        }
    } else {
        eprintln!("error: pass --task or --root");
        return ExitCode::from(2);
    };
    print_marks(&marks);
    if let Some(path) = json_out {
        let path = match contain_output(&path) {
            Ok(path) => path,
            Err(err) => {
                eprintln!("error: {err}");
                return ExitCode::from(2);
            }
        };
        if let Some(parent) = path.parent() {
            if !parent.as_os_str().is_empty() && std::fs::create_dir_all(parent).is_err() {
                eprintln!("error: cannot create {}", parent.display());
                return ExitCode::from(1);
            }
        }
        let body = serde_json::to_vec_pretty(&marks.to_json()).unwrap_or_default();
        if std::fs::write(&path, body).is_err() {
            eprintln!("error: cannot write {}", path.display());
            return ExitCode::from(1);
        }
    }
    ExitCode::SUCCESS
}

fn print_marks(marks: &AsmMarks) {
    if marks.tasks.is_empty() {
        println!("tasks=0 measured=false");
        return;
    }
    for task in &marks.tasks {
        println!(
            "task {} measured={} example={}",
            task.id, task.measured, task.example
        );
        println!("  {}", task.summary);
        if task.groups.is_empty() {
            println!("  unmeasured");
        }
        for group in &task.groups {
            println!("  config {}", group.config);
            for change in &group.changes {
                let area = change
                    .area_delta
                    .map(|delta| format!("{delta}"))
                    .unwrap_or_else(|| "-".into());
                let snapshot = change
                    .area_au
                    .map(|value| format!("{value}"))
                    .unwrap_or_else(|| "-".into());
                println!(
                    "    {} decision={} area={} area_delta={}",
                    change.change, change.decision, snapshot, area
                );
                for (name, delta) in &change.module_deltas {
                    println!("      module {name} delta={delta}");
                }
                for test in &change.tests {
                    let cycles = test
                        .cycles
                        .map(|count| count.to_string())
                        .unwrap_or_else(|| "-".into());
                    let benefit = test
                        .benefit
                        .map(|value| format!("{value:.4}"))
                        .unwrap_or_else(|| "-".into());
                    println!(
                        "      {} lane={} cycles={} benefit={}",
                        test.id, test.lane, cycles, benefit
                    );
                }
            }
        }
    }
}
