// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// area-report.v1 JSON. Hints are not timing opportunities.

//! JSON projection of an [`crate::AreaReport`]. Cache keys may be empty until
//! the area cache stores the blob.

use serde_json::{json, Value};
use sv_timing_core::TimingDesign;

use crate::model::AreaModel;
use crate::walk::{AreaReport, PerfBasis};

/// Disclaimer printed on every area report.
pub const DISCLAIMER: &str = "Structural FO4 and structural area units. Not static timing analysis. Not a mapped cell count.";

/// Build the v1 object. `compare` is null until a second analyze is supplied.
pub fn report_json(
    report: &AreaReport,
    design: &TimingDesign,
    model: &AreaModel,
    design_key: &str,
    area_key: &str,
) -> Value {
    let target = &design.target;
    let gaps = json!({
        "n_width_defaulted": report.n_width_defaulted,
        "n_generate_unresolved": report.n_generate_unresolved,
        "n_opaque_child": report.n_opaque_child,
        "n_body_unlowered": report.n_body_unlowered,
        "n_storage_unrecorded": report.n_storage_unrecorded,
        "n_instance_params_unrecorded": report.n_instance_params_unrecorded,
        "n_config_unresolved": report.n_config_unresolved,
        "n_cross_path_unresolved": report.n_cross_path_unresolved,
        "n_field_absent": report.n_field_absent,
        "attribution_gaps": report.attribution_gaps(),
    });
    let (tree, tree_truncated) = module_tree(report, design);
    json!({
        "schema_version": "1",
        "disclaimer": DISCLAIMER,
        "area_model": model.id,
        "measurement": design.versions.measurement,
        "ir_version": design.versions.ir,
        "cost_model": design.versions.cost_model,
        "fo4_ps": target.fo4_ps,
        "budget_margin": target.budget_margin,
        "target_mhz": target.target_mhz,
        "design_key": design_key,
        "area_key": area_key,
        "inclusion": report.inclusion,
        "metrics": {
            "area_au": opt_num(report.metrics.area_au),
            "delay_fo4": opt_num(report.metrics.delay_fo4),
            "perf_mhz": opt_num(report.metrics.perf_mhz),
            "perf_per_area": opt_num(report.metrics.perf_per_area),
            "perf_basis": basis_name(report.perf_basis),
            "perf_multicycle_mhz": opt_num(report.perf_multicycle_mhz),
            "perf_state": report.metrics.perf_state,
            "null_reason": report.metrics.null_reason,
        },
        "marks": report.marks.to_json(),
        "gaps": gaps,
        "tree": tree,
        "tree_truncated": tree_truncated,
        "rank_exclusive_area": report.rank_exclusive_area.iter().map(rank_json).collect::<Vec<_>>(),
        "rank_exclusive_delay": rank_by_delay(report),
        "rank_perf_per_area": perf_rank(report),
        "off_path_area_au": opt_num(report.off_path_area_au),
        "on_path": report.on_path.iter().map(rank_json).collect::<Vec<_>>(),
        "path_classes": design
            .paths
            .iter()
            .filter_map(|path| {
                let module = design.modules.get(&path.module)?.name.clone();
                let class = serde_json::to_value(path.path_class)
                    .ok()?
                    .as_str()?
                    .to_string();
                Some(json!({ "module": module, "class": class }))
            })
            .collect::<Vec<_>>(),
        "compare": Value::Null,
        "hints": hint_rows(report, design),
        "stats": {
            "area_hit": false,
            "nodes": report.rank_exclusive_area.len(),
            "gaps": report.attribution_gaps(),
        },
    })
}

fn module_tree(report: &AreaReport, design: &TimingDesign) -> (Vec<Value>, usize) {
    let limit = report.top;
    let top_level: Vec<&crate::ModuleRow> = report
        .modules
        .iter()
        .filter(|row| row.role == "root" || row.role == "unbound")
        .collect();
    let mut truncated = top_level.len().saturating_sub(limit);
    let mut stack = Vec::new();
    let tree = top_level
        .iter()
        .take(limit)
        .map(|row| tree_row(report, design, row, None, None, &mut stack, &mut truncated))
        .collect();
    (tree, truncated)
}

fn tree_row(
    report: &AreaReport,
    design: &TimingDesign,
    row: &crate::ModuleRow,
    parent_inclusive: Option<f64>,
    instance: Option<&str>,
    stack: &mut Vec<String>,
    truncated: &mut usize,
) -> Value {
    let parent_percent = parent_share(parent_inclusive, row.inclusive_au);
    let mut children = Vec::new();
    if !stack.iter().any(|name| name == &row.name) {
        stack.push(row.name.clone());
        if let Some(id) = design.module_names.get(&row.name).copied() {
            let mut kids: Vec<_> = design
                .instances
                .iter()
                .filter(|inst| inst.parent_module == id)
                .filter(|inst| {
                    inst.child_module.is_none() || inst.param_override_present == Some(false)
                })
                .collect();
            kids.sort_by(|a, b| {
                module_order(report, instance_module_name(design, a))
                    .cmp(&module_order(report, instance_module_name(design, b)))
                    .then_with(|| a.instance_name.cmp(&b.instance_name))
            });
            *truncated += kids.len().saturating_sub(report.top);
            for inst in kids.into_iter().take(report.top) {
                children.push(instance_row(
                    report,
                    design,
                    inst,
                    row.inclusive_au,
                    stack,
                    truncated,
                ));
            }
        }
        stack.pop();
    }
    json!({
        "name": row.name,
        "instance": instance,
        "role": row.role,
        "exclusive_au": row.exclusive_au,
        "inclusive_au": row.inclusive_au,
        "exclusive_delay_fo4": row.delay_fo4,
        "inclusive_delay_fo4": row.inclusive_delay_fo4,
        "perf_basis": row.perf_basis,
        "parent_percent": parent_percent,
        "tags": row.tags,
        "children": children,
    })
}

fn instance_row(
    report: &AreaReport,
    design: &TimingDesign,
    inst: &sv_timing_core::ModuleInstance,
    parent_inclusive: f64,
    stack: &mut Vec<String>,
    truncated: &mut usize,
) -> Value {
    let Some(child_id) = inst.child_module else {
        return json!({
            "name": inst.child_type,
            "instance": inst.instance_name,
            "role": "opaque",
            "exclusive_au": 0.0,
            "inclusive_au": 0.0,
            "exclusive_delay_fo4": 0.0,
            "inclusive_delay_fo4": 0.0,
            "perf_basis": "empty",
            "parent_percent": parent_share(Some(parent_inclusive), 0.0),
            "tags": [format!("opaque_child={}", inst.instance_name)],
            "children": [],
        });
    };
    let Some(module) = design.modules.get(&child_id) else {
        return json!({
            "name": inst.child_type,
            "instance": inst.instance_name,
            "role": "opaque",
            "exclusive_au": 0.0,
            "inclusive_au": 0.0,
            "exclusive_delay_fo4": 0.0,
            "inclusive_delay_fo4": 0.0,
            "perf_basis": "empty",
            "parent_percent": parent_share(Some(parent_inclusive), 0.0),
            "tags": [format!("opaque_child={}", inst.instance_name)],
            "children": [],
        });
    };
    let Some(row) = report.modules.iter().find(|row| row.name == module.name) else {
        return json!({
            "name": module.name,
            "instance": inst.instance_name,
            "role": "child",
            "exclusive_au": 0.0,
            "inclusive_au": 0.0,
            "exclusive_delay_fo4": 0.0,
            "inclusive_delay_fo4": 0.0,
            "perf_basis": "empty",
            "parent_percent": Value::Null,
            "tags": [],
            "children": [],
        });
    };
    tree_row(
        report,
        design,
        row,
        Some(parent_inclusive),
        Some(inst.instance_name.as_str()),
        stack,
        truncated,
    )
}

fn parent_share(parent_inclusive: Option<f64>, child_inclusive: f64) -> Value {
    match parent_inclusive {
        Some(parent) if parent > 0.0 => json!(100.0 * child_inclusive / parent),
        _ => Value::Null,
    }
}

fn module_order(report: &AreaReport, name: Option<&str>) -> usize {
    let Some(name) = name else {
        return usize::MAX;
    };
    report
        .modules
        .iter()
        .position(|row| row.name == name)
        .unwrap_or(usize::MAX)
}

fn instance_module_name<'a>(
    design: &'a TimingDesign,
    inst: &'a sv_timing_core::ModuleInstance,
) -> Option<&'a str> {
    inst.child_module
        .and_then(|id| design.modules.get(&id))
        .map(|module| module.name.as_str())
}

fn hint_rows(report: &AreaReport, design: &TimingDesign) -> Vec<Value> {
    report
        .modules
        .iter()
        .filter(|row| !row.tags.is_empty())
        .map(|row| {
            let found = design
                .modules
                .values()
                .find(|module| module.name == row.name);
            json!({
                "file": found.map(|module| module.file.as_str()).unwrap_or(""),
                "line": found.map(|module| module.loc.start_line).unwrap_or(0),
                "module": row.name,
                "section": "tree",
                "exclusive_au": row.exclusive_au,
                "inclusive_au": row.inclusive_au,
                "tags": row.tags,
            })
        })
        .collect()
}

fn opt_num(value: Option<f64>) -> Value {
    value.map_or(Value::Null, |n| json!(n))
}

fn basis_name(basis: PerfBasis) -> &'static str {
    match basis {
        PerfBasis::Empty => "empty",
        PerfBasis::RegToReg => "reg_to_reg",
        PerfBasis::PrimaryPath => "primary_path",
        PerfBasis::MulticycleOnly => "multicycle_only",
        PerfBasis::NodeDepth => "node_depth",
    }
}

fn rank_json(row: &crate::RankRow) -> Value {
    json!({
        "module": row.module,
        "node_id": row.node_id,
        "file": row.file,
        "line": row.line,
        "exclusive_au": row.exclusive_au,
        "delay_fo4": row.delay_fo4,
        "critical_contribution_fo4": row.critical_contribution_fo4,
    })
}

fn rank_by_delay(report: &AreaReport) -> Vec<Value> {
    let mut rows = report.rank_exclusive_area.clone();
    rows.sort_by(|a, b| {
        b.delay_fo4
            .total_cmp(&a.delay_fo4)
            .then_with(|| a.file.cmp(&b.file))
            .then_with(|| a.line.cmp(&b.line))
            .then_with(|| a.node_id.cmp(&b.node_id))
            .then_with(|| a.module.cmp(&b.module))
    });
    rows.iter().map(rank_json).collect()
}

fn perf_rank(report: &AreaReport) -> Vec<Value> {
    let Some(mhz) = report.metrics.perf_mhz else {
        return Vec::new();
    };
    let mut rows: Vec<Value> = report
        .modules
        .iter()
        .filter(|row| row.exclusive_au > 0.0)
        .map(|row| {
            json!({
                "module": row.name,
                "perf_per_area": mhz / row.exclusive_au,
            })
        })
        .collect();
    rows.sort_by(|a, b| {
        let left = a["perf_per_area"].as_f64().unwrap_or(0.0);
        let right = b["perf_per_area"].as_f64().unwrap_or(0.0);
        left.total_cmp(&right)
            .then_with(|| a["module"].as_str().cmp(&b["module"].as_str()))
    });
    rows
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{attribute, default_area_v1_embedded};
    use sv_timing_core::{ParamMap, TimingDesign, TimingTarget};

    #[test]
    fn schema_lists_the_report_contract() {
        let text = include_str!("../../../schemas/area-report.v1.json");
        for key in [
            "schema_version",
            "off_path_area_au",
            "perf_per_area",
            "n_instance_params_unrecorded",
            "n_cross_path_unresolved",
            "n_field_absent",
            "attribution_gaps",
            "on_path",
            "path_classes",
            "asm_cycle_count",
            "compare",
            "tree_truncated",
        ] {
            assert!(text.contains(key), "schema missing {key}");
        }
    }

    #[test]
    fn empty_inclusion_json_has_null_off_path() {
        let design = TimingDesign::empty(TimingTarget::new(1000.0, 20.0, 0.2));
        let report = attribute(&design, &default_area_v1_embedded(), &ParamMap::new());
        let value = report_json(&report, &design, &default_area_v1_embedded(), "", "");
        assert_eq!(value["schema_version"], "1");
        assert!(value["off_path_area_au"].is_null());
        assert_eq!(value["metrics"]["null_reason"], "empty_inclusion");
        assert_eq!(value["marks"]["basis"], "asm_cycle_count");
        assert_eq!(value["marks"]["measured"], false);
        assert!(value["compare"].is_null());
        assert!(value["on_path"].as_array().unwrap().is_empty());
    }
}
