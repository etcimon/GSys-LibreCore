// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! PMU event table — the design's own performance-counter event matrix.
//!
//! The event selector for each counter is `{group, index}` packed into `mhpmevent`.
//! This module reads the design's own `perf_counters.sv` and `ariane_pkg.sv`
//! (the contract named by `pins.toml [contracts.pmu_events]`) and extracts the
//! group → index → symbolic name mapping. A new event added to the RTL matrix
//! appears here without an edit, provided the comment or signal naming convention
//! is preserved.

use crate::Json;
use std::collections::BTreeMap;

/// One event in the performance-counter matrix.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PmuEvent {
    /// Stable symbolic name, derived from the source comment or the probe signal.
    pub name: String,
    /// Event group (high bits of `mhpmevent`).
    pub group: u32,
    /// Index within the group (low bits of `mhpmevent`).
    pub index: u32,
    /// The packed selector a guest writes to `mhpmeventN`.
    pub mhpmevent: u32,
}

impl PmuEvent {
    /// Render as JSON.
    pub fn to_json(&self) -> Json {
        Json::obj([
            ("name", Json::str(&self.name)),
            ("group", Json::Int(self.group as i64)),
            ("index", Json::Int(self.index as i64)),
            ("mhpmevent", Json::Int(self.mhpmevent as i64)),
        ])
    }
}

/// The complete PMU event table.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct PmuTable {
    /// Number of general-purpose counters the design exposes.
    pub counter_count: u32,
    /// Width of the index field inside the selector.
    pub idx_width: u32,
    /// Width of the group field inside the selector.
    pub grp_width: u32,
    /// Events in file order.
    pub events: Vec<PmuEvent>,
    /// Group number → short tag, derived from the section comment or the
    /// `MHPMGrp*` constant name.
    pub groups: BTreeMap<u32, String>,
    /// Names the reader could not resolve, so a gap is visible rather than guessed.
    pub unresolved: Vec<String>,
}

impl PmuTable {
    /// Counter bitmap for the programmable `mhpmcounter3+` range.
    ///
    /// The design's `MHPMCounterNum` is the number of *general* counters. They
    /// start at counter index 3, so a value of `N` sets bits `3..3+N`.
    pub fn counter_mask(&self) -> u32 {
        if self.counter_count == 0 {
            0
        } else {
            let bits = (1u64 << self.counter_count) - 1;
            ((bits << 3) & 0xffff_ffff) as u32
        }
    }

    /// Render as JSON.
    pub fn to_json(&self) -> Json {
        Json::obj([
            ("counter_count", Json::Int(self.counter_count as i64)),
            ("counter_mask", Json::Int(self.counter_mask() as i64)),
            ("idx_width", Json::Int(self.idx_width as i64)),
            ("grp_width", Json::Int(self.grp_width as i64)),
            (
                "events",
                Json::arr(self.events.iter().map(PmuEvent::to_json)),
            ),
            (
                "groups",
                Json::obj(
                    self.groups
                        .iter()
                        .map(|(k, v)| (format!("{k}"), Json::str(v))),
                ),
            ),
            (
                "unresolved",
                Json::arr(self.unresolved.iter().map(Json::str)),
            ),
        ])
    }

    /// Look up an event by its stable name.
    pub fn event(&self, name: &str) -> Option<&PmuEvent> {
        self.events.iter().find(|e| e.name == name)
    }

    /// Look up an event by the `mhpmevent` selector value.
    pub fn event_by_mhpmevent(&self, mhpmevent: u32) -> Option<&PmuEvent> {
        self.events.iter().find(|e| e.mhpmevent == mhpmevent)
    }
}

/// Parse the PMU event table from the design's own source.
///
/// `perf_text` is the contents of `core/perf_counters.sv`;
/// `ariane_text` is the contents of `core/include/ariane_pkg.sv`.
/// Either may be empty, in which case the table is empty and the unresolved list
/// explains why.
pub fn parse_pmu_table(perf_text: &str, ariane_text: &str) -> PmuTable {
    let mut table = PmuTable::default();

    if ariane_text.is_empty() {
        table.unresolved.push("ariane_pkg source empty".into());
    }
    if perf_text.is_empty() {
        table.unresolved.push("perf_counters source empty".into());
    }

    let constants = parse_ariane_constants(ariane_text);
    table.counter_count = constants.get("MHPMCounterNum").copied().unwrap_or(0) as u32;
    table.idx_width = constants.get("MHPMEventIdxWidth").copied().unwrap_or(0) as u32;
    table.grp_width = constants.get("MHPMEventGrpWidth").copied().unwrap_or(0) as u32;

    let ai_index_names = parse_ai_index_names(ariane_text);
    let group_labels = parse_group_headers(perf_text);

    // Build a map from MHPMGrp* identifiers to their numeric value.
    let mut group_idents: BTreeMap<String, u32> = BTreeMap::new();
    for (name, value) in &constants {
        if name.starts_with("MHPMGrp") {
            group_idents.insert(name.clone(), *value);
        }
    }

    for line in perf_text.lines() {
        let (code, comment) = split_comment(line);
        if !code.trim_start().starts_with("event_group[") {
            continue;
        }
        let Some((group_expr, index_expr, rhs)) = parse_assignment(code) else {
            continue;
        };

        let group = resolve_group(&group_expr, &group_idents, &mut table.unresolved);
        let index = resolve_index(&index_expr, &mut table.unresolved);
        let (group, index) = match (group, index) {
            (Some(g), Some(i)) => (g, i),
            _ => continue,
        };

        let group_tag = group_tag(group, &group_expr, &group_idents, &group_labels);
        let index_name = index_name(index, &rhs, comment.as_deref(), &ai_index_names, &group_tag);
        let name = format!("{group_tag}.{index:02}_{index_name}");

        let mhpmevent = (group << table.idx_width) | index;

        // Record the group tag the first time we see it.
        table
            .groups
            .entry(group)
            .or_insert_with(|| group_tag.clone());

        table.events.push(PmuEvent {
            name,
            group,
            index,
            mhpmevent,
        });
    }

    table
}

fn split_comment(line: &str) -> (&str, Option<String>) {
    match line.find("//") {
        Some(pos) => {
            let code = &line[..pos];
            let cmt = line[pos + 2..].trim();
            let cmt = if cmt.is_empty() {
                None
            } else {
                Some(cmt.to_string())
            };
            (code, cmt)
        }
        None => (line, None),
    }
}

fn parse_assignment(code: &str) -> Option<(String, String, String)> {
    let prefix = "event_group[";
    let s = code.trim();
    if !s.starts_with(prefix) {
        return None;
    }
    let after = &s[prefix.len()..];
    let br = after.find("][")?;
    let group_expr = after[..br].trim().to_string();
    let after = &after[br + 2..];
    let idx_end = after.find(']')?;
    let index_expr = after[..idx_end].trim().to_string();
    let after = after[idx_end + 1..].trim();
    if !after.starts_with('=') {
        return None;
    }
    let after = after[1..].trim();
    let semi = after.find(';')?;
    let rhs = after[..semi].trim().to_string();
    Some((group_expr, index_expr, rhs))
}

fn resolve_group(
    expr: &str,
    idents: &BTreeMap<String, u32>,
    unresolved: &mut Vec<String>,
) -> Option<u32> {
    let expr = expr.trim();
    if let Some(v) = parse_sized_or_decimal(expr) {
        return Some(v);
    }
    if let Some(&v) = idents.get(expr) {
        return Some(v);
    }
    unresolved.push(format!("unresolved group expression: {expr}"));
    None
}

fn resolve_index(expr: &str, unresolved: &mut Vec<String>) -> Option<u32> {
    let expr = expr.trim();
    if let Some(v) = parse_sized_or_decimal(expr) {
        return Some(v);
    }
    unresolved.push(format!("unresolved index expression: {expr}"));
    None
}

fn parse_sized_or_decimal(s: &str) -> Option<u32> {
    let s = s.trim().replace('_', "");
    if let Some(rest) = s.strip_prefix("0x") {
        return u32::from_str_radix(rest, 16).ok();
    }
    // Sized literal: <width>'<base><digits>
    if let Some(quote) = s.find('\'') {
        let _width = &s[..quote];
        let rest = &s[quote + 1..];
        if rest.is_empty() {
            return None;
        }
        let base = rest.chars().next()?;
        let digits = &rest[1..];
        if digits.is_empty() {
            return None;
        }
        let radix = match base.to_ascii_lowercase() {
            'b' => 2,
            'o' => 8,
            'd' => 10,
            'h' => 16,
            _ => return None,
        };
        let digits = digits.replace('_', "");
        u32::from_str_radix(&digits, radix).ok()
    } else {
        s.parse::<u32>().ok()
    }
}

fn strip_sv_comments(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '/' && chars.peek() == Some(&'/') {
            // Drop through to end of line, but keep the newline.
            chars.next();
            for d in chars.by_ref() {
                if d == '\n' {
                    out.push('\n');
                    break;
                }
            }
        } else if c == '/' && chars.peek() == Some(&'*') {
            chars.next();
            let mut prev = ' ';
            for d in chars.by_ref() {
                if prev == '*' && d == '/' {
                    break;
                }
                prev = d;
            }
        } else if c == '"' {
            // Keep string literals verbatim so that the only semicolons we
            // split on are real statement separators.
            out.push('"');
            let mut escaped = false;
            for d in chars.by_ref() {
                out.push(d);
                if escaped {
                    escaped = false;
                } else if d == '\\' {
                    escaped = true;
                } else if d == '"' {
                    break;
                }
            }
        } else {
            out.push(c);
        }
    }
    out
}

fn localparam_statements(text: &str) -> impl Iterator<Item = &str> {
    // Find each "localparam " and return the slice up to (but not including) the next top-level ';'.
    // We preserve strings, so ';' inside a string does not terminate the statement.
    let mut out = Vec::new();
    let mut pos = 0;
    while let Some(start) = text[pos..].find("localparam ") {
        let start = pos + start;
        let mut in_string = false;
        let mut escaped = false;
        let mut bytes = 0;
        for c in text[start..].chars() {
            if in_string {
                if escaped {
                    escaped = false;
                } else if c == '\\' {
                    escaped = true;
                } else if c == '"' {
                    in_string = false;
                }
            } else if c == '"' {
                in_string = true;
            } else if c == ';' {
                break;
            }
            bytes += c.len_utf8();
        }
        out.push(&text[start..start + bytes]);
        pos = start + bytes + 1; // skip the terminating ';'
    }
    out.into_iter()
}

fn parse_ariane_constants(text: &str) -> BTreeMap<String, u32> {
    let mut out = BTreeMap::new();
    let cleaned = strip_sv_comments(text);
    for stmt in localparam_statements(&cleaned) {
        let stmt = stmt.trim();
        let rest = stmt.strip_prefix("localparam").unwrap_or(stmt).trim();
        // Find the last identifier before '='; earlier tokens are the type.
        let eq = match rest.find('=') {
            Some(i) => i,
            None => continue,
        };
        if rest.get(eq + 1..) == Some("=") {
            // skip == or ===
            continue;
        }
        let lhs = &rest[..eq].trim();
        let rhs = &rest[eq + 1..].trim();
        let name = lhs
            .split(|c: char| !(c.is_alphanumeric() || c == '_'))
            .filter(|t| !t.is_empty())
            .next_back();
        let Some(name) = name else { continue };
        if let Some(v) = parse_sized_or_decimal(rhs) {
            out.insert(name.to_string(), v);
        }
    }
    out
}

fn parse_ai_index_names(text: &str) -> BTreeMap<u32, String> {
    let mut out = BTreeMap::new();
    let lines: Vec<&str> = text.lines().collect();
    let mut in_block = false;
    for line in &lines {
        if line.contains("Indices within MHPMGrpAI") {
            in_block = true;
            continue;
        }
        if in_block {
            if !line.trim_start().starts_with("//") {
                break;
            }
            let cmt = line.trim_start().trim_start_matches("//").trim();
            if let Some((num, rest)) = cmt.split_once(':') {
                if let Ok(idx) = num.trim().parse::<u32>() {
                    out.insert(idx, rest.trim().to_string());
                }
            }
        }
    }
    out
}

fn parse_group_headers(text: &str) -> BTreeMap<u32, String> {
    let mut out = BTreeMap::new();
    for line in text.lines() {
        let s = line.trim();
        if !s.starts_with("//") {
            continue;
        }
        let cmt = s.trim_start_matches("//").trim();
        if !cmt.contains("Group") {
            continue;
        }
        // Locate the digit following "Group".
        let Some(pos) = cmt.find("Group") else {
            continue;
        };
        let after = &cmt[pos + 5..];
        let digits: String = after
            .chars()
            .skip_while(|c| !c.is_ascii_digit())
            .take_while(|c| c.is_ascii_digit())
            .collect();
        if digits.is_empty() {
            continue;
        }
        let Ok(group) = digits.parse::<u32>() else {
            continue;
        };
        // Label is between ':' and '(' on the same line.
        let rest = after[digits.len() + after.find(|c: char| c.is_ascii_digit()).unwrap_or(0)..]
            .trim_start();
        let label = if let Some(colon) = rest.find(':') {
            let label = &rest[colon + 1..];
            if let Some(paren) = label.find('(') {
                &label[..paren]
            } else {
                label
            }
        } else {
            rest
        };
        let label = label
            .trim()
            .trim_end_matches('.')
            .trim_end_matches('-')
            .trim()
            .to_string();
        if !label.is_empty() {
            out.insert(group, label);
        }
    }
    out
}

fn group_tag(
    group: u32,
    expr: &str,
    idents: &BTreeMap<String, u32>,
    labels: &BTreeMap<u32, String>,
) -> String {
    // If the expression is a named group constant, use the suffix after MHPMGrp.
    let expr = expr.trim();
    if let Some(v) = idents.get(expr) {
        if *v == group && expr.starts_with("MHPMGrp") {
            return expr["MHPMGrp".len()..].to_lowercase();
        }
    }
    if let Some(label) = labels.get(&group) {
        return normalize_tag(label);
    }
    format!("g{group}")
}

fn index_name(
    index: u32,
    rhs: &str,
    comment: Option<&str>,
    ai_index_names: &BTreeMap<u32, String>,
    group_tag: &str,
) -> String {
    // AI group uses the names in ariane_pkg when no inline comment is present.
    if group_tag == "ai" {
        if let Some(name) = ai_index_names.get(&index) {
            return normalize_tag(name);
        }
    }

    if let Some(c) = comment {
        let c = c.trim();
        if !c.is_empty() {
            return normalize_tag(c);
        }
    }

    let rhs = rhs.trim();
    if rhs == "1'b0" || rhs == "'0" || rhs == "0" {
        return "reserved".into();
    }

    // Extract the first signal-like identifier and strip the common _i suffix.
    let mut in_id = false;
    let mut start = 0usize;
    for (i, c) in rhs.char_indices() {
        if c.is_ascii_alphanumeric() || c == '_' {
            if !in_id {
                in_id = true;
                start = i;
            }
        } else if in_id {
            let id = &rhs[start..i];
            return clean_signal_name(id);
        }
    }
    if in_id {
        let id = &rhs[start..];
        return clean_signal_name(id);
    }
    "unknown".into()
}

fn clean_signal_name(s: &str) -> String {
    let s = s.trim_end_matches("_i");
    normalize_tag(s)
}

fn normalize_tag(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut prev_space = false;
    for c in s.chars() {
        if c.is_ascii_alphanumeric() || c == '_' {
            out.push(c.to_ascii_lowercase());
            prev_space = false;
        } else if (c.is_whitespace()
            || c == '/'
            || c == '-'
            || c == '.'
            || c == ','
            || c == ':'
            || c == '('
            || c == ')'
            || c == '+')
            && !out.is_empty()
            && !prev_space
        {
            out.push('_');
            prev_space = true;
        }
        // Other punctuation is dropped.
    }
    while out.ends_with('_') {
        out.pop();
    }
    if out.is_empty() {
        return "unknown".into();
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const ARIANE: &str = r#"
package ariane_pkg;
  localparam int unsigned MHPMCounterNum = 6;
  localparam int unsigned MHPMEventIdxWidth = 5;
  localparam int unsigned MHPMEventGrpWidth = 3;
  localparam int unsigned MHPMEventWidth = MHPMEventGrpWidth + MHPMEventIdxWidth;

  localparam logic [MHPMEventGrpWidth-1:0] MHPMGrpLegacy = 3'd0;
  localparam logic [MHPMEventGrpWidth-1:0] MHPMGrpAI = 3'd4;

  // Indices within MHPMGrpAI:
  //   0: AI op complete
  //   1: AI MMA complete
  //   2: AI post-op complete
endpackage
"#;

    const PERF: &str = r#"
module perf_counters;
  // --- Group 0: legacy encoding (mhpmevent[7:5] == 0) ----------------------
  event_group[MHPMGrpLegacy][5'd0]  = 1'b0;
  event_group[MHPMGrpLegacy][5'd1]  = l1_icache_miss_i;  //L1 I-Cache misses
  event_group[MHPMGrpLegacy][5'd2]  = l1_dcache_miss_i;  //L1 D-Cache misses
  event_group[MHPMGrpLegacy][5'd3]  = itlb_miss_i;       //ITLB misses

  // Group 1: U5 OoO / MLP (mhpmevent[7:5]==1). Indices stable once published.
  event_group[3'd1][5'd0] = sb_full_i | ooo_rename_stall_i | ooo_rob_full_i;  // rename/ROB backpressure
  event_group[3'd1][5'd2] = resolved_branch_i.valid && resolved_branch_i.is_mispredict;

  // Group 4: Xg6lcai AI (mhpmevent[7:5]==MHPMGrpAI). See ariane_pkg.
  event_group[MHPMGrpAI][5'd0] = ai_pmu_op_i;
  event_group[MHPMGrpAI][5'd1] = ai_pmu_mma_i;
endmodule
"#;

    #[test]
    fn parse_extracts_events_and_mhpmevent_values() {
        let table = parse_pmu_table(PERF, ARIANE);
        assert_eq!(table.counter_count, 6);
        assert_eq!(table.idx_width, 5);
        assert_eq!(table.grp_width, 3);

        assert!(table.unresolved.is_empty(), "{:?}", table.unresolved);

        let e = table
            .event("legacy.01_l1_i_cache_misses")
            .expect("legacy cache miss");
        assert_eq!(e.group, 0);
        assert_eq!(e.index, 1);
        assert_eq!(e.mhpmevent, 1);

        assert!(table.event("legacy.03_itlb_misses").is_some());

        let e = table
            .event("u5_ooo_mlp.00_rename_rob_backpressure")
            .expect("group 1");
        assert_eq!(e.group, 1);
        assert_eq!(e.mhpmevent, 0x20);

        let e = table
            .event("u5_ooo_mlp.02_resolved_branch")
            .expect("group 1 idx 2");
        assert_eq!(e.index, 2);
        assert_eq!(e.mhpmevent, 0x22);

        let e = table.event("ai.00_ai_op_complete").expect("ai op complete");
        assert_eq!(e.group, 4);
        assert_eq!(e.index, 0);
        assert_eq!(e.mhpmevent, 0x80);

        let e = table.event("ai.01_ai_mma_complete").expect("ai mma");
        assert_eq!(e.mhpmevent, 0x81);
    }

    #[test]
    fn counter_mask_has_the_programmable_counter_bits() {
        let table = parse_pmu_table(PERF, ARIANE);
        // Counters 3,4,5,6,7,8 => 0b1_1111_1000 = 0x1f8
        assert_eq!(table.counter_mask(), 0x1f8);
        assert!(table.to_json().to_pretty().contains("counter_mask"));
    }

    #[test]
    fn ariane_constants_survive_comments_and_functions() {
        // The real ariane_pkg.sv has a `return ...;` inside a function and a
        // `localparam` immediately after `endfunction`. A naive `split(';')` merges
        // those and swallows the constant. This test pins the extraction.
        let ariane = r#"
package ariane_pkg;
  /* comment with a semicolon; inside it */
  function automatic logic example();
    return 1'b1;
  endfunction

  // -------------------
  // Performance counter
  // -------------------
  localparam int unsigned MHPMCounterNum = 6;
  localparam int unsigned MHPMEventIdxWidth = 5;
  localparam int unsigned MHPMEventGrpWidth = 3;
  localparam int unsigned MHPMEventWidth = MHPMEventGrpWidth + MHPMEventIdxWidth;

  localparam string SEMICOLON_IN_STRING = "a; b";
endpackage
"#;
        let table = parse_pmu_table("localparam [2:0][4:0] event_group [2:0][31:0];", ariane);
        assert_eq!(table.counter_count, 6);
        assert_eq!(table.idx_width, 5);
        assert_eq!(table.grp_width, 3);
    }

    #[test]
    fn missing_source_is_recorded_not_panicked() {
        let table = parse_pmu_table("", "");
        assert_eq!(table.counter_count, 0);
        assert_eq!(table.events.len(), 0);
        assert_eq!(table.unresolved.len(), 2);
    }
}
