// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Recover unique-case item labels and selector from source for BalanceMux
// hierarchical / one-hot select-tree rewrites.

//! Case-label recovery for BalanceMux hierarchical / one-hot rewrites.
//!
//! Prefer **IR fields** populated by lower from CST `CaseItem` (`case_labels`,
//! `case_is_default`, `case_selector`). Fall back to line-oriented source scan
//! when lower did not attach labels (older IR / partial parse).

use std::collections::BTreeMap;
use std::fs;
use std::path::Path;

use sv_timing_core::{IrNode, NodeId};

/// One exclusive case arm recovered from source + IR.
#[derive(Debug, Clone)]
pub struct RecoveredCaseArm {
    /// IR node id when known.
    pub node_id: NodeId,
    /// Case item labels (`ADD`, `SUB`, …); empty for unlabeled / default body.
    pub labels: Vec<String>,
    /// RHS expression text.
    pub rhs: String,
    /// FO4 of the IR node (for ranking).
    pub fo4: f64,
    /// Origin line of the assign.
    pub line: u32,
    /// True when this is a `default:` arm.
    pub is_default: bool,
}

/// Recovered exclusive case context for hierarchical BalanceMux.
#[derive(Debug, Clone)]
pub struct RecoveredExclusiveCase {
    /// Case expression / selector (`fu_data_i.operation`).
    pub selector: String,
    /// Dominant LHS (`result_o`).
    pub lhs: String,
    /// Recovered arms (non-default preferred).
    pub arms: Vec<RecoveredCaseArm>,
    /// Source file path.
    pub file: String,
}

/// Load source lines for a path (cached via map).
pub fn load_source_lines<'a>(
    cache: &'a mut BTreeMap<String, Vec<String>>,
    file: &str,
) -> Option<&'a [String]> {
    if !cache.contains_key(file) {
        let p = Path::new(file);
        if !p.is_file() {
            return None;
        }
        let text = fs::read_to_string(p).ok()?;
        let lines: Vec<String> = text.lines().map(|s| s.to_string()).collect();
        cache.insert(file.to_string(), lines);
    }
    cache.get(file).map(|v| v.as_slice())
}

/// Recover case labels for an assignment at `loc` by scanning previous lines.
///
/// Handles:
/// - `LABEL: result_o = …`
/// - `L1, L2, L3: result_o = …`
/// - Multi-line: labels on prior line, assign on next
pub fn recover_case_labels_at(lines: &[String], assign_line_1based: u32) -> (Vec<String>, bool) {
    if assign_line_1based == 0 || lines.is_empty() {
        return (Vec::new(), false);
    }
    let idx = (assign_line_1based as usize).saturating_sub(1);
    if idx >= lines.len() {
        return (Vec::new(), false);
    }
    // Same-line labels: `ADD, SUB: result_o = …`
    let same = strip_comment(&lines[idx]);
    if let Some((labs, is_def)) = parse_case_label_prefix(same) {
        if !labs.is_empty() || is_def {
            return (labs, is_def);
        }
    }
    // Walk upward for a pure label line / default
    let mut i = idx;
    while i > 0 {
        i -= 1;
        let t = strip_comment(&lines[i]).trim().to_string();
        if t.is_empty() {
            continue;
        }
        // Stop at case/endcase/begin/end/if
        let lower = t.to_ascii_lowercase();
        if lower.starts_with("unique case")
            || lower.starts_with("case ")
            || lower.starts_with("case(")
            || lower == "endcase"
            || lower == "end"
            || lower.starts_with("end ")
            || lower.starts_with("always")
            || lower.starts_with("if ")
            || lower.starts_with("if(")
        {
            break;
        }
        if let Some((labs, is_def)) = parse_case_label_line(&t) {
            return (labs, is_def);
        }
        // Another assign without labels — stop
        if t.contains('=') && !t.contains("==") {
            break;
        }
    }
    (Vec::new(), false)
}

/// Recover selector expression from nearest `unique case (…)` / `case (…)` above line.
pub fn recover_case_selector(lines: &[String], assign_line_1based: u32) -> Option<String> {
    if assign_line_1based == 0 {
        return None;
    }
    let idx = (assign_line_1based as usize).saturating_sub(1);
    let mut i = idx.min(lines.len().saturating_sub(1)) + 1;
    while i > 0 {
        i -= 1;
        let t = strip_comment(&lines[i]);
        let lower = t.to_ascii_lowercase();
        if let Some(rest) = lower
            .find("unique case")
            .map(|p| &t[p + "unique case".len()..])
            .or_else(|| {
                // plain case — avoid "endcase"
                if lower.trim_start().starts_with("case") && !lower.contains("endcase") {
                    let p = lower.find("case")?;
                    Some(&t[p + 4..])
                } else {
                    None
                }
            })
        {
            if let Some(sel) = extract_paren_expr(rest) {
                return Some(sel);
            }
            // multi-line: case (\n expr \n)
            if rest.trim().starts_with('(') || rest.trim().is_empty() {
                if let Some(sel) = extract_paren_from_lines(lines, i) {
                    return Some(sel);
                }
            }
        }
        if lower.contains("endcase") {
            break;
        }
    }
    None
}

/// Build recovered exclusive-case context for a dominant LHS on a path.
pub fn recover_exclusive_case(
    nodes: &BTreeMap<NodeId, IrNode>,
    path_nodes: &[NodeId],
    dominant_lhs: &str,
    source_cache: &mut BTreeMap<String, Vec<String>>,
) -> Option<RecoveredExclusiveCase> {
    let mut arms: Vec<RecoveredCaseArm> = Vec::new();
    let mut file: Option<String> = None;
    let mut selector: Option<String> = None;

    for id in path_nodes {
        let n = nodes.get(id)?;
        let lhs = n.lhs.as_ref()?.trim();
        if lhs != dominant_lhs {
            continue;
        }
        let rhs = n.rhs.as_ref()?.trim();
        if rhs.is_empty() {
            continue;
        }
        // Skip pure zero init often used before case: result_o = '0
        if is_zero_init(rhs) {
            continue;
        }
        let f = n.loc.file.clone();
        if f.is_empty() {
            continue;
        }

        // Prefer IR CaseItem labels (from lower); fall back to source scan.
        let (labels, is_default) = if !n.case_labels.is_empty() || n.case_is_default {
            (n.case_labels.clone(), n.case_is_default)
        } else if let Some(lines) = load_source_lines(source_cache, &f) {
            recover_case_labels_at(lines, n.loc.start_line)
        } else {
            (Vec::new(), false)
        };

        if selector.is_none() {
            if let Some(sel) = n.case_selector.as_ref().filter(|s| !s.is_empty()) {
                selector = Some(sel.clone());
            } else if let Some(lines) = load_source_lines(source_cache, &f) {
                selector = recover_case_selector(lines, n.loc.start_line);
            }
        }
        file.get_or_insert(f);
        arms.push(RecoveredCaseArm {
            node_id: *id,
            labels,
            rhs: rhs.to_string(),
            fo4: n.fo4_cost.max(0.0),
            line: n.loc.start_line,
            is_default,
        });
    }

    if arms.len() < 4 {
        return None;
    }
    // Prefer arms that have labels for one-hot
    let labeled = arms.iter().filter(|a| !a.labels.is_empty() && !a.is_default).count();
    if labeled < 3 {
        return None;
    }
    let selector = selector.unwrap_or_else(|| "/*unknown_sel*/1'b0".into());
    if selector.contains("unknown_sel") {
        return None;
    }
    Some(RecoveredExclusiveCase {
        selector,
        lhs: dominant_lhs.to_string(),
        arms,
        file: file.unwrap_or_default(),
    })
}

/// Enum / default safety checks before wiring one-hot top into exclusive LHS.
///
/// Returns `Ok(())` when the selector is usable and **at least 3** labeled arms
/// have simple enum-like idents **and** one-hot-safe RHS. Arms with `$clog2` /
/// complex RHS are skipped by [`emit_onehot_or_tree`] — they must not fail the
/// whole exclusive case (real `alu.sv` mixes simple ADD/OR arms with CLZ).
pub fn onehot_wire_checks(recovered: &RecoveredExclusiveCase) -> Result<(), String> {
    let sel = recovered.selector.trim();
    if sel.is_empty() || sel.contains("unknown_sel") {
        return Err("selector missing".into());
    }
    // Refuse selectors that look like full statements / macros.
    if sel.contains(';') || sel.contains('=') || sel.len() > 120 {
        return Err(format!("selector not safe for wire-up: {sel}"));
    }
    let mut usable = 0usize;
    let mut skipped_unsafe = 0usize;
    let mut bad_label: Option<String> = None;
    for arm in &recovered.arms {
        if arm.is_default || arm.labels.is_empty() {
            continue;
        }
        let mut labs_ok = true;
        for lab in &arm.labels {
            if !is_simple_ident(lab) {
                labs_ok = false;
                bad_label = Some(lab.clone());
                break;
            }
        }
        if !labs_ok {
            continue;
        }
        if rhs_safe_for_onehot(&arm.rhs) {
            usable += 1;
        } else {
            skipped_unsafe += 1;
        }
    }
    if usable < 3 {
        let extra = bad_label
            .map(|l| format!("; bad label e.g. `{l}`"))
            .unwrap_or_default();
        return Err(format!(
            "need >=3 one-hot-safe labeled arms, usable={usable} skipped_unsafe={skipped_unsafe}{extra}"
        ));
    }
    let _ = skipped_unsafe;
    Ok(())
}

/// Origins to rewrite to `svt_bm_oh_p{path_id}_top` for a functional exclusive LHS.
///
/// Only **one-hot-safe** labeled arms (same filter as [`emit_onehot_or_tree`]) are
/// rewritten so multi-line `$clog2` arms keep their original body (no orphan
/// ternary continuations). Default empty bodies (`default: ;`) are left alone.
pub fn onehot_lhs_rewrites(
    recovered: &RecoveredExclusiveCase,
    nodes: &BTreeMap<NodeId, IrNode>,
    top_name: &str,
) -> Vec<(sv_timing_core::SourceLoc, String)> {
    let mut out = Vec::new();
    for arm in &recovered.arms {
        if arm.is_default || arm.labels.is_empty() {
            continue;
        }
        if !rhs_safe_for_onehot(&arm.rhs) {
            continue;
        }
        if let Some(n) = nodes.get(&arm.node_id) {
            if n.loc.start_line == 0 {
                continue;
            }
            // Multi-line assign span so continuations are commented out.
            out.push((n.loc.clone(), top_name.to_string()));
        }
    }
    out
}

/// Emit one-hot AND-OR balanced select tree for recovered exclusive arms.
///
/// Each labeled arm becomes `({W{sel}}) & rhs` style compare-mux, then a
/// balanced binary OR reduction (log₂ depth). Default arms are omitted
/// (zero-init of the tree covers them).
pub fn emit_onehot_or_tree(
    recovered: &RecoveredExclusiveCase,
    path_id: u32,
    data_width: u32,
) -> Option<String> {
    let w = if data_width < 2 { 64 } else { data_width.min(128) };
    let mut labeled: Vec<&RecoveredCaseArm> = recovered
        .arms
        .iter()
        .filter(|a| !a.is_default && !a.labels.is_empty())
        .collect();
    if labeled.len() < 3 {
        return None;
    }
    // Cap arms for emit hygiene
    labeled.sort_by(|a, b| {
        b.fo4
            .partial_cmp(&a.fo4)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    if labeled.len() > 16 {
        labeled.truncate(16);
    }
    // Prefer simple RHS for safety (idents / simple expr without case labels)
    let usable: Vec<&RecoveredCaseArm> = labeled
        .into_iter()
        .filter(|a| rhs_safe_for_onehot(&a.rhs))
        .collect();
    if usable.len() < 3 {
        return None;
    }

    let prefix = format!("svt_bm_oh_p{path_id}");
    let sel = &recovered.selector;
    let mut b = String::new();
    b.push_str("  // --- BalanceMux one-hot AND-OR select tree (latency-neutral) ---\n");
    b.push_str(&format!(
        "  // exclusive lhs=`{}` selector=`{}` arms={}\n",
        recovered.lhs,
        sel,
        usable.len()
    ));
    b.push_str(
        "  // Parallel arm eval + balanced OR reduction (unique-case / one-hot style).\n",
    );

    // Arm wires
    for (i, _) in usable.iter().enumerate() {
        b.push_str(&format!("  logic [{w}-1:0] {prefix}_a{i};\n"));
    }
    // OR tree wires
    let n_or_levels = usable.len().next_power_of_two().trailing_zeros() as usize;
    let mut level_count = usable.len();
    let mut or_names: Vec<Vec<String>> = Vec::new();
    // level 0 = arms
    or_names.push((0..usable.len()).map(|i| format!("{prefix}_a{i}")).collect());
    let mut lvl = 0usize;
    while level_count > 1 {
        lvl += 1;
        let prev = level_count;
        let next = (prev + 1) / 2;
        let mut names = Vec::new();
        for i in 0..next {
            let name = format!("{prefix}_or_l{lvl}_{i}");
            b.push_str(&format!("  logic [{w}-1:0] {name};\n"));
            names.push(name);
        }
        or_names.push(names);
        level_count = next;
    }
    let top = or_names
        .last()
        .and_then(|v| v.first())
        .cloned()
        .unwrap_or_else(|| format!("{prefix}_a0"));
    b.push_str(&format!("  logic [{w}-1:0] {prefix}_top;\n"));

    // Arm eval
    b.push_str(&format!("  always_comb begin : {prefix}_arms\n"));
    for (i, arm) in usable.iter().enumerate() {
        let cond = labels_to_compare(sel, &arm.labels);
        let rhs = paren_if_needed_rhs(&arm.rhs);
        b.push_str(&format!(
            "    {prefix}_a{i} = ({cond}) ? {rhs} : '0;\n"
        ));
    }
    b.push_str("  end\n");

    // Balanced OR tree
    b.push_str(&format!("  always_comb begin : {prefix}_or_tree\n"));
    for lvl in 1..or_names.len() {
        let prev = &or_names[lvl - 1];
        let cur = &or_names[lvl];
        for (i, name) in cur.iter().enumerate() {
            let left = &prev[i * 2];
            if i * 2 + 1 < prev.len() {
                let right = &prev[i * 2 + 1];
                b.push_str(&format!("    {name} = {left} | {right};\n"));
            } else {
                b.push_str(&format!("    {name} = {left};\n"));
            }
        }
    }
    b.push_str(&format!("    {prefix}_top = {top};\n"));
    b.push_str("  end\n");
    b.push_str(&format!(
        "  // exclusive lhs `{}` ← `{prefix}_top` (origin arms rewritten when wire-up enabled)\n",
        recovered.lhs
    ));
    let _ = n_or_levels;
    Some(b)
}

/// Dominant exclusive LHS among path nodes (most writes).
pub fn dominant_exclusive_lhs(
    nodes: &BTreeMap<NodeId, IrNode>,
    path_nodes: &[NodeId],
) -> Option<String> {
    let mut counts: BTreeMap<String, usize> = BTreeMap::new();
    for id in path_nodes {
        if let Some(n) = nodes.get(id) {
            if let Some(lhs) = n.lhs.as_ref().map(|s| s.trim().to_string()) {
                if !lhs.is_empty() {
                    *counts.entry(lhs).or_insert(0) += 1;
                }
            }
        }
    }
    counts
        .into_iter()
        .max_by_key(|(_, c)| *c)
        .filter(|(_, c)| *c >= 4)
        .map(|(l, _)| l)
}

fn strip_comment(line: &str) -> &str {
    if let Some(i) = line.find("//") {
        &line[..i]
    } else {
        line
    }
}

fn parse_case_label_prefix(line: &str) -> Option<(Vec<String>, bool)> {
    let t = line.trim();
    // Find colon not part of ?:
    if t.contains('?') {
        return None;
    }
    let colon = t.find(':')?;
    let before = t[..colon].trim();
    let after = t[colon + 1..].trim();
    // after should look like assign if labels on same line
    if !after.is_empty() && !after.contains('=') {
        return None;
    }
    parse_labels_blob(before)
}

fn parse_case_label_line(line: &str) -> Option<(Vec<String>, bool)> {
    let t = line.trim().trim_end_matches(':').trim();
    if t.is_empty() {
        return None;
    }
    // Pure label line ends with : already stripped
    let lower = t.to_ascii_lowercase();
    if lower == "default" {
        return Some((Vec::new(), true));
    }
    // Must not be an assign
    if t.contains('=') {
        return None;
    }
    parse_labels_blob(t)
}

fn parse_labels_blob(before: &str) -> Option<(Vec<String>, bool)> {
    let lower = before.to_ascii_lowercase();
    if lower == "default" {
        return Some((Vec::new(), true));
    }
    // Labels: IDENT (, IDENT)*
    let mut labs = Vec::new();
    for part in before.split(',') {
        let p = part.trim();
        if p.is_empty() {
            continue;
        }
        if !is_simple_ident(p) {
            return None;
        }
        labs.push(p.to_string());
    }
    if labs.is_empty() {
        return None;
    }
    Some((labs, false))
}

fn is_simple_ident(s: &str) -> bool {
    let mut chars = s.chars();
    match chars.next() {
        Some(c) if c.is_ascii_alphabetic() || c == '_' => {}
        _ => return false,
    }
    chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

fn extract_paren_expr(s: &str) -> Option<String> {
    let s = s.trim();
    let start = s.find('(')?;
    let mut depth = 0i32;
    for (i, c) in s[start..].char_indices() {
        match c {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if depth == 0 {
                    let inner = s[start + 1..start + i].trim();
                    if !inner.is_empty() {
                        return Some(inner.to_string());
                    }
                    return None;
                }
            }
            _ => {}
        }
    }
    None
}

fn extract_paren_from_lines(lines: &[String], case_line_idx: usize) -> Option<String> {
    let mut buf = String::new();
    for line in lines.iter().skip(case_line_idx).take(6) {
        buf.push(' ');
        buf.push_str(strip_comment(line));
        if let Some(sel) = extract_paren_expr(&buf) {
            return Some(sel);
        }
    }
    None
}

fn is_zero_init(rhs: &str) -> bool {
    let t = rhs.trim().trim_end_matches(';').trim();
    matches!(t, "'0" | "0" | "'b0" | "1'b0" | "{default: '0}" | "{default:'0}")
}

fn rhs_safe_for_onehot(rhs: &str) -> bool {
    let t = rhs.trim();
    if t.is_empty() || t.len() > 120 {
        return false;
    }
    // Avoid nested case / multi-stmt / macros with $
    if t.contains("case") || t.contains(';') {
        return false;
    }
    // Allow $clog2 in concat-heavy arms? Safer to skip $ for one-hot emit.
    if t.contains('$') {
        return false;
    }
    true
}

fn labels_to_compare(sel: &str, labels: &[String]) -> String {
    labels
        .iter()
        .map(|l| format!("({sel}) == ({l})"))
        .collect::<Vec<_>>()
        .join(" || ")
}

fn paren_if_needed_rhs(rhs: &str) -> String {
    let t = rhs.trim().trim_end_matches(';').trim();
    if t.contains('?') || t.contains('|') || t.contains('&') || t.contains('+') {
        format!("({t})")
    } else {
        t.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn recover_labels_same_line() {
        let lines = vec![
            "    unique case (fu_data_i.operation)".into(),
            "      ADD, SUB: result_o = adder_result;".into(),
            "    endcase".into(),
        ];
        let (labs, def) = recover_case_labels_at(&lines, 2);
        assert!(!def);
        assert_eq!(labs, vec!["ADD".to_string(), "SUB".to_string()]);
    }

    #[test]
    fn recover_labels_prior_line() {
        let lines = vec![
            "    unique case (op)".into(),
            "      ROL:".into(),
            "        result_o = a << b | a >> c;".into(),
            "    endcase".into(),
        ];
        let (labs, def) = recover_case_labels_at(&lines, 3);
        assert!(!def);
        assert_eq!(labs, vec!["ROL".to_string()]);
    }

    #[test]
    fn recover_selector() {
        let lines = vec![
            "    unique case (fu_data_i.operation)".into(),
            "      ADD: result_o = x;".into(),
            "    endcase".into(),
        ];
        let sel = recover_case_selector(&lines, 2).unwrap();
        assert!(sel.contains("fu_data_i.operation"), "{sel}");
    }

    #[test]
    fn onehot_emit_has_or_tree() {
        let rec = RecoveredExclusiveCase {
            selector: "op".into(),
            lhs: "result_o".into(),
            file: "t.sv".into(),
            arms: (0..4)
                .map(|i| RecoveredCaseArm {
                    node_id: i,
                    labels: vec![format!("L{i}")],
                    rhs: format!("arm{i}"),
                    fo4: 10.0 - i as f64,
                    line: 10 + i,
                    is_default: false,
                })
                .collect(),
        };
        let sv = emit_onehot_or_tree(&rec, 41, 64).unwrap();
        assert!(sv.contains("always_comb"));
        assert!(sv.contains("svt_bm_oh_p41_a0"));
        assert!(sv.contains("|"));
        assert!(sv.contains("op") && sv.contains("L0"));
        assert!(sv.contains("svt_bm_oh_p41_top"));
        assert!(onehot_wire_checks(&rec).is_ok());
    }

    #[test]
    fn onehot_wire_checks_reject_bad_label() {
        let rec = RecoveredExclusiveCase {
            selector: "op".into(),
            lhs: "result_o".into(),
            file: "t.sv".into(),
            arms: (0..4)
                .map(|i| RecoveredCaseArm {
                    node_id: i,
                    labels: vec![if i == 0 {
                        "4'h1".into()
                    } else {
                        format!("L{i}")
                    }],
                    rhs: format!("arm{i}"),
                    fo4: 5.0,
                    line: 10 + i,
                    is_default: false,
                })
                .collect(),
        };
        // Only 3 usable idents if first label is bad → still fails if usable < 3
        // (here only L1,L2,L3 = 3 usable → ok). Force all bad:
        let rec_all_bad = RecoveredExclusiveCase {
            selector: "op".into(),
            lhs: "result_o".into(),
            file: "t.sv".into(),
            arms: (0..4)
                .map(|i| RecoveredCaseArm {
                    node_id: i,
                    labels: vec![format!("4'h{i}")],
                    rhs: format!("arm{i}"),
                    fo4: 5.0,
                    line: 10 + i,
                    is_default: false,
                })
                .collect(),
        };
        assert!(onehot_wire_checks(&rec_all_bad).is_err());
        let _ = rec;
    }

    #[test]
    fn onehot_wire_checks_allows_mix_with_clog2_arms() {
        // alu-like: most arms simple, one arm has $clog2
        let mut arms: Vec<RecoveredCaseArm> = (0..4)
            .map(|i| RecoveredCaseArm {
                node_id: i,
                labels: vec![format!("L{i}")],
                rhs: format!("arm{i}"),
                fo4: 5.0,
                line: 10 + i,
                is_default: false,
            })
            .collect();
        arms.push(RecoveredCaseArm {
            node_id: 99,
            labels: vec!["CLZ".into()],
            rhs: "(lz) ? $clog2(XLEN) : 0".into(),
            fo4: 8.0,
            line: 50,
            is_default: false,
        });
        let rec = RecoveredExclusiveCase {
            selector: "fu_data_i.operation".into(),
            lhs: "result_o".into(),
            file: "alu.sv".into(),
            arms,
        };
        assert!(onehot_wire_checks(&rec).is_ok(), "mixed $clog2 should not fail");
    }
}
