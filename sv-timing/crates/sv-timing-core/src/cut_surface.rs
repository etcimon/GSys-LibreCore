// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Cut surface of the over-budget cones (A149): which procedural loops hold
//! them, and what a loop-to-generate refactor would have to preserve.
//!
//! A stage register needs a legal home. Inside a procedural `for` in an
//! `always_comb` there is none: the loop's `automatic` locals are not module
//! nets and one iteration may read what the previous one wrote. This report
//! names, per loop, the block-locals a stage would have to hoist, the
//! loop-carried names that forbid independent per-iteration blocks, and the
//! writes outside the loop that the single-process rule would turn into a
//! second driver. It is a feasibility reading for a source refactor; it
//! performs none and awards no FO4.

use serde::Serialize;
use std::collections::BTreeSet;

use crate::ir::{TimingDesign, TimingModule};

/// One procedural loop that contains part of an over-budget cone.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct LoopSurface {
    /// Module name.
    pub module: String,
    /// Loop variable.
    pub var: String,
    /// Loop span: first line.
    pub start_line: u32,
    /// Loop span: last line.
    pub end_line: u32,
    /// Worst over-budget path FO4 whose node sits in this loop.
    pub worst_fo4: f64,
    /// Block-local names the body references (would need hoisting to
    /// per-iteration nets).
    pub block_locals: Vec<String>,
    /// LHS roots written in the body under the loop variable's index.
    pub indexed_writes: Vec<String>,
    /// Names written in the body and also read without that index, or
    /// written without it: iteration order matters.
    pub loop_carried: Vec<String>,
    /// Indexed-write roots also written outside the loop (defaults): a
    /// generate split would create a second always_comb driver.
    pub outside_writers: Vec<String>,
    /// `expandable` or the first obstacle.
    pub verdict: String,
}

fn idents(text: &str) -> Vec<(String, usize)> {
    let b = text.as_bytes();
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        if b[i].is_ascii_alphabetic() || b[i] == b'_' {
            let s = i;
            while i < b.len() && (b[i].is_ascii_alphanumeric() || b[i] == b'_') {
                i += 1;
            }
            out.push((text[s..i].to_string(), s));
        } else if b[i] == b'/' && i + 1 < b.len() && b[i + 1] == b'/' {
            while i < b.len() && b[i] != b'\n' {
                i += 1;
            }
        } else {
            i += 1;
        }
    }
    out
}

/// `name[ <index> ]` immediately after the identifier; `None` when unindexed.
fn index_after(text: &str, at: usize) -> Option<String> {
    let rest = text[at..].trim_start();
    if !rest.starts_with('[') {
        return None;
    }
    let mut depth = 0i32;
    for (k, c) in rest.char_indices() {
        match c {
            '[' => depth += 1,
            ']' => {
                depth -= 1;
                if depth == 0 {
                    return Some(rest[1..k].trim().to_string());
                }
            }
            _ => {}
        }
    }
    None
}

/// Writes in `body`: `(root, index text or None)` for every blocking `=` and
/// statement-level non-blocking `<=` that is not a comparison.
fn writes(body: &str) -> Vec<(String, Option<String>)> {
    let mut out = Vec::new();
    for line in body.lines() {
        let t = line.split("//").next().unwrap_or("");
        let b = t.as_bytes();
        let mut depth = 0i32;
        let mut k = 0;
        while k < b.len() {
            match b[k] {
                b'(' => depth += 1,
                b')' => depth -= 1,
                b'=' => {
                    let prev = if k > 0 { b[k - 1] } else { b' ' };
                    let next = b.get(k + 1).copied().unwrap_or(b' ');
                    let compare = next == b'='
                        || matches!(prev, b'!' | b'>' | b'=')
                        || (prev == b'<' && depth > 0);
                    if compare {
                        // skip the whole operator
                        while k + 1 < b.len() && b[k + 1] == b'=' {
                            k += 1;
                        }
                    } else {
                        let before = t[..k].trim_end_matches('<').trim_end();
                        let start = before
                            .rfind(|c: char| c == ';' || c == ')' || c == '{')
                            .map(|p| p + 1)
                            .unwrap_or(0);
                        let lhs = before[start..].trim();
                        let lhs = lhs
                            .rsplit(|c: char| c.is_whitespace())
                            .next()
                            .unwrap_or(lhs);
                        if let Some((name, at)) = idents(lhs).into_iter().next() {
                            out.push((name.clone(), index_after(lhs, at + name.len())));
                        }
                    }
                }
                _ => {}
            }
            k += 1;
        }
    }
    out
}

/// Loop surfaces for every over-budget, single-cycle path of the design.
pub fn loop_surfaces(design: &TimingDesign) -> Vec<LoopSurface> {
    let budget = design.target.budget_fo4;
    let mut out: Vec<LoopSurface> = Vec::new();
    for (mid, module) in &design.modules {
        let locals = module.block_local_names();
        for g in module
            .gen_loops
            .iter()
            .filter(|g| g.procedural && !g.in_function)
        {
            let worst = design
                .paths
                .iter()
                .filter(|p| p.module == *mid && !p.multi_cycle && p.total_fo4 > budget + 1e-6)
                .filter(|p| {
                    p.nodes.iter().any(|id| {
                        module.nodes.get(id).is_some_and(|n| {
                            n.loc.file == g.loc.file
                                && n.loc.start_line >= g.loc.start_line
                                && n.loc.start_line <= g.loc.end_line
                        })
                    })
                })
                .map(|p| p.total_fo4)
                .fold(0.0, f64::max);
            if worst <= 0.0 {
                continue;
            }
            let body = g.text.as_deref().unwrap_or("");
            let body_idents: BTreeSet<String> = idents(body).into_iter().map(|(n, _)| n).collect();
            let block_locals: Vec<String> = body_idents
                .iter()
                .filter(|n| locals.contains(*n) && **n != g.genvar)
                .cloned()
                .collect();
            let ws = writes(body);
            let mut indexed_writes: BTreeSet<String> = BTreeSet::new();
            let mut loop_carried: BTreeSet<String> = BTreeSet::new();
            for (name, idx) in &ws {
                match idx {
                    Some(i) if i == &g.genvar => {
                        indexed_writes.insert(name.clone());
                    }
                    _ if locals.contains(name) => {}
                    _ => {
                        loop_carried.insert(name.clone());
                    }
                }
            }
            // A root written under the loop index and read elsewhere in the
            // body without exactly that index depends on another iteration.
            for (name, at) in idents(body) {
                if !indexed_writes.contains(&name) {
                    continue;
                }
                let idx = index_after(body, at + name.len());
                if idx.as_deref() != Some(g.genvar.as_str()) {
                    loop_carried.insert(name.clone());
                }
            }
            let outside_writers: Vec<String> = indexed_writes
                .iter()
                .filter(|w| {
                    module.nodes.values().any(|n| {
                        n.lhs.as_deref().and_then(TimingModule::root_ident) == Some(w.as_str())
                            && (n.loc.start_line < g.loc.start_line
                                || n.loc.start_line > g.loc.end_line)
                    })
                })
                .cloned()
                .collect();
            let verdict = if indexed_writes.is_empty() {
                "no per-iteration write: nothing to expand".to_string()
            } else if !loop_carried.is_empty() {
                format!(
                    "loop-carried: {} read or written across iterations; iterations are not independent",
                    loop_carried.iter().cloned().collect::<Vec<_>>().join(", ")
                )
            } else if !outside_writers.is_empty() {
                format!(
                    "default outside the loop: {} also written elsewhere; a generate split would add a second driver",
                    outside_writers.join(", ")
                )
            } else if !block_locals.is_empty() {
                format!(
                    "expandable with hoisting: {} become per-iteration nets",
                    block_locals.join(", ")
                )
            } else {
                "expandable".to_string()
            };
            out.push(LoopSurface {
                module: module.name.clone(),
                var: g.genvar.clone(),
                start_line: g.loc.start_line,
                end_line: g.loc.end_line,
                worst_fo4: worst,
                block_locals,
                indexed_writes: indexed_writes.into_iter().collect(),
                loop_carried: loop_carried.into_iter().collect(),
                outside_writers,
                verdict,
            });
        }
    }
    out.sort_by(|a, b| b.worst_fo4.total_cmp(&a.worst_fo4));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn writes_and_indices_are_read_from_the_body() {
        let body = "for (int unsigned g = 0; g < N; g++) begin\n  slot = find(g);\n  q_d[g].valid = 1'b0;\n  if (grant[g] == 1'b1) acc = acc + q[g];\n  y[g] <= z;\nend";
        let w = writes(body);
        assert!(w.contains(&("slot".to_string(), None)));
        assert!(w.contains(&("q_d".to_string(), Some("g".to_string()))));
        assert!(w.contains(&("acc".to_string(), None)));
        assert!(w.contains(&("y".to_string(), Some("g".to_string()))));
        assert!(
            !w.iter().any(|(n, _)| n == "grant"),
            "a comparison is not a write: {w:?}"
        );
    }
}
