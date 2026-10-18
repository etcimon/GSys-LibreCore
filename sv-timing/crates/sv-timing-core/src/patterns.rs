// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Statement-level mechanisms behind the measured hand rewrites that are not
//! yet automatic transforms (ALGORITHMS-EXPERTS A122). They are *reported*
//! wherever they occur so a campaign can see the codebase-wide applicability
//! of each generic form before an emitter exists for it.
//!
//! | pattern | hand instance | generic form |
//! |---|---|---|
//! | `IndexedWriteReadBypass` | rename A118 (`busy_d[tag] = 1; … busy_d[rs]`) | read the register and bypass on `rs == tag && we` |
//! | `OneHotEncodeDecode` | rename A120 (`idx = enc(x & -x); mem[idx] <= v`) | write under the one-hot directly |
//!
//! A same-cycle write into a `_d` array followed by an indexed read of that
//! array puts an index decode, the array's write muxes and a read mux in
//! series on the reader's cone. The exact bypass is a compare and one mux:
//! `r = (ridx == widx && w_en) ? v : X_q[ridx]`, when the write is the only
//! one in the block (several writes compose in program order, each a bypass
//! level; the detector reports the count). The emitter does not write this
//! form yet: the write's enable is the conjunction of its guards and the
//! value may be a struct field update — both need the statement rewriter.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::expr::Expr;
use crate::ir::{AssignKind, RegionKind, TimingModule};

/// Which mechanism was recognised.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PatternKind {
    /// Same-cycle indexed write then indexed read of one combinational array.
    IndexedWriteReadBypass,
    /// A one-hot selection (isolate-lowest-set-bit) re-encoded to an index
    /// that is then decoded again by an indexed write.
    OneHotEncodeDecode,
}

/// One site, by module and source lines.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PatternSite {
    /// Mechanism.
    pub kind: PatternKind,
    /// Module name.
    pub module: String,
    /// The array / vector involved (root identifier).
    pub subject: String,
    /// Line of the write (or encode) statement.
    pub write_line: u32,
    /// Line of the read (or decode) statement.
    pub read_line: u32,
    /// Writes to the subject in the same block (bypass levels an exact rewrite needs).
    pub writes_in_block: u32,
    /// Human note: the generic form and what blocks emission.
    pub note: String,
}

/// Identifiers that are constants at elaboration: loop variables of
/// unrolled `for`s, genvars, parameters / localparams. An index made only
/// of these is a static select, not a decode on the cone.
fn elab_const(module: &TimingModule, name: &str) -> bool {
    let root = TimingModule::root_ident(name).unwrap_or(name);
    module.decls.iter().any(|d| d.name == root && d.loop_var)
        || module.gen_loops.iter().any(|g| g.genvar == root)
        || module.localparams.iter().any(|p| p == root)
        || module.parameters.iter().any(|p| p.name == root)
        || module.const_exprs.contains_key(root)
        || name.contains("::")
}

fn index_is_runtime(module: &TimingModule, index: &Expr) -> bool {
    let mut runtime = false;
    index.walk_idents(&mut |id| {
        if !elab_const(module, id) {
            runtime = true;
        }
    });
    runtime
}

fn runtime_index(module: &TimingModule, e: &Expr) -> Option<String> {
    let mut out = None;
    let mut cur = e;
    while let Expr::Index { base, index } = cur {
        if !matches!(**index, Expr::Literal { .. } | Expr::PartSelect { .. })
            && index_is_runtime(module, index)
        {
            out = Some(index.emit());
        }
        cur = base;
    }
    out
}

fn lhs_runtime_write(module: &TimingModule, lhs: &Expr) -> Option<(String, String)> {
    // `X[idx]`, `X[idx].field`, `X[idx][j]` — the root and the first runtime index.
    let mut cur = lhs;
    loop {
        match cur {
            Expr::Index { base, .. } => {
                if let Some(ix) = runtime_index(module, cur) {
                    let mut root = &**base;
                    while let Expr::Index { base: b, .. } = root {
                        root = b;
                    }
                    if let Expr::Ident { name } = root {
                        let root_name = TimingModule::root_ident(name).unwrap_or(name).to_string();
                        return Some((root_name, ix));
                    }
                }
                cur = base;
            }
            Expr::Ident { .. } => return None,
            _ => return None,
        }
    }
}

fn reads_indexed(module: &TimingModule, e: &Expr, subject: &str) -> Option<String> {
    let mut found = None;
    fn walk(module: &TimingModule, e: &Expr, subject: &str, found: &mut Option<String>) {
        if found.is_some() {
            return;
        }
        match e {
            Expr::Index { base, index } => {
                let mut root = &**base;
                while let Expr::Index { base: b, .. } = root {
                    root = b;
                }
                if let Expr::Ident { name } = root {
                    if TimingModule::root_ident(name).unwrap_or(name) == subject
                        && index_is_runtime(module, index)
                    {
                        *found = Some(index.emit());
                        return;
                    }
                }
                walk(module, base, subject, found);
                walk(module, index, subject, found);
            }
            Expr::Unary { arg, .. } => walk(module, arg, subject, found),
            Expr::Binary { left, right, .. } | Expr::PartSelect { left, right, .. } => {
                walk(module, left, subject, found);
                walk(module, right, subject, found);
            }
            Expr::Ternary {
                cond,
                then_e,
                else_e,
            } => {
                walk(module, cond, subject, found);
                walk(module, then_e, subject, found);
                walk(module, else_e, subject, found);
            }
            Expr::Concat { parts } => parts.iter().for_each(|p| walk(module, p, subject, found)),
            Expr::Replicate { count, body } => {
                walk(module, count, subject, found);
                walk(module, body, subject, found);
            }
            Expr::Call { args, .. } => args.iter().for_each(|a| walk(module, a, subject, found)),
            Expr::Ident { .. } | Expr::Literal { .. } | Expr::Opaque { .. } => {}
        }
    }
    walk(module, e, subject, &mut found);
    found
}

/// Same-cycle indexed write → indexed read sites of `module`'s comb blocks.
pub fn write_read_bypass_sites(module: &TimingModule) -> Vec<PatternSite> {
    let regs = crate::select_increment::register_roots(module);
    let mut out = Vec::new();
    for region in module.regions.values() {
        if region.kind != RegionKind::AlwaysComb {
            continue;
        }
        // writes in statement order: subject -> (first write line, count, index text)
        let mut writes: BTreeMap<String, (u32, u32, String)> = BTreeMap::new();
        let mut reported: BTreeMap<String, ()> = BTreeMap::new();
        for id in &region.nodes {
            let Some(n) = module.nodes.get(id) else {
                continue;
            };
            if !matches!(
                n.assign_kind,
                AssignKind::Blocking | AssignKind::BlockingCompound
            ) {
                continue;
            }
            // a read of an already-written subject (RHS or guards), before any new write counts
            let mut read_hits: Vec<(String, String)> = Vec::new();
            if let Some(rhs) = &n.rhs_expr {
                for (subject, _) in writes.iter() {
                    if let Some(ix) = reads_indexed(module, rhs, subject) {
                        read_hits.push((subject.clone(), ix));
                    }
                }
            }
            if let Some(gs) = module.guards.get(id) {
                for g in gs {
                    let e = Expr::parse(g.trim_start_matches('^'));
                    for (subject, _) in writes.iter() {
                        if let Some(ix) = reads_indexed(module, &e, subject) {
                            read_hits.push((subject.clone(), ix));
                        }
                    }
                }
            }
            for (subject, ridx) in read_hits {
                if reported.contains_key(&subject) {
                    continue;
                }
                let (wline, count, widx) = writes[&subject].clone();
                reported.insert(subject.clone(), ());
                out.push(PatternSite {
                    kind: PatternKind::IndexedWriteReadBypass,
                    module: module.name.clone(),
                    subject: subject.clone(),
                    write_line: wline,
                    read_line: n.loc.start_line,
                    writes_in_block: count,
                    note: format!(
                        "read `{subject}[{ridx}]` after write `{subject}[{widx}]` in one block: exact form reads the register and bypasses on `{ridx} == {widx}` under the write's guards ({count} write(s) → {count} bypass level(s)); emission pending (statement rewriter)"
                    ),
                });
            }
            if let Some(lhs) = &n.lhs_expr {
                if let Some((subject, idx)) = lhs_runtime_write(module, lhs) {
                    if regs.contains(&subject) {
                        continue;
                    }
                    let e = writes.entry(subject).or_insert((n.loc.start_line, 0, idx));
                    e.1 += 1;
                }
            }
        }
    }
    out
}

/// One-hot encode → decode sites: a comb node `x & (~x + 1)` / `x & -x`
/// (isolate lowest set bit) whose result is re-encoded (`for … if (sel[i]) idx = i`
/// cannot be seen per node; the encoder is recognised as a node reading the
/// one-hot vector with a `$clog2`/loop-shaped RHS is out of reach) — this
/// detector therefore reports the isolate site and every indexed write whose
/// index is a comb name derived from it in the same module.
pub fn onehot_encode_decode_sites(module: &TimingModule) -> Vec<PatternSite> {
    let mut onehots: Vec<(String, u32)> = Vec::new();
    for n in module.nodes.values() {
        if !n.assign_kind.is_comb_def() {
            continue;
        }
        let Some(rhs) = &n.rhs_expr else { continue };
        if let Expr::Binary {
            op, left, right, ..
        } = rhs
        {
            if op == "&" {
                let isolate = |a: &Expr, b: &Expr| -> bool {
                    match b {
                        Expr::Unary { op, arg } if op == "-" => **arg == *a,
                        Expr::Binary {
                            op, left, right, ..
                        } if op == "+" => {
                            matches!(&**left, Expr::Unary { op, arg } if op == "~" && **arg == *a)
                                && matches!(&**right, Expr::Literal { text } if text.trim_end_matches("'b1").trim_end_matches("'d1") == "1" || text == "1" || text.ends_with("'b1") || text.ends_with("'d1"))
                        }
                        _ => false,
                    }
                };
                if isolate(left, right) || isolate(right, left) {
                    if let Some(root) = n.lhs.as_deref().and_then(TimingModule::root_ident) {
                        onehots.push((root.to_string(), n.loc.start_line));
                    }
                }
            }
        }
    }
    if onehots.is_empty() {
        return Vec::new();
    }
    // comb names whose RHS reads a one-hot (an encoder output candidate)
    let mut derived: BTreeMap<String, (String, u32)> = BTreeMap::new();
    for n in module.nodes.values() {
        if !n.assign_kind.is_comb_def() {
            continue;
        }
        let (Some(lhs), Some(rhs)) = (n.lhs.as_deref(), &n.rhs_expr) else {
            continue;
        };
        let Some(root) = TimingModule::root_ident(lhs) else {
            continue;
        };
        let mut hit = None;
        let mut look = |id: &str| {
            let r = TimingModule::root_ident(id).unwrap_or(id);
            if let Some((oh, line)) = onehots.iter().find(|(o, _)| o == r) {
                hit = Some((oh.clone(), *line));
            }
        };
        rhs.walk_idents(&mut look);
        // an encoder loop reads the one-hot in its guard (`if (pick[i]) idx = i`)
        for g in module.guards.get(&n.id).into_iter().flatten() {
            Expr::parse(g.trim_start_matches('^')).walk_idents(&mut look);
        }
        if let Some(h) = hit {
            if !onehots.iter().any(|(o, _)| o == root) {
                derived.entry(root.to_string()).or_insert(h);
            }
        }
    }
    let mut out = Vec::new();
    for n in module.nodes.values() {
        let Some(lhs) = &n.lhs_expr else { continue };
        let Some((subject, idx)) = lhs_runtime_write(module, lhs) else {
            continue;
        };
        let idx_root = TimingModule::root_ident(&idx).unwrap_or(&idx).to_string();
        if let Some((onehot, oline)) = derived.get(&idx_root) {
            out.push(PatternSite {
                kind: PatternKind::OneHotEncodeDecode,
                module: module.name.clone(),
                subject: subject.clone(),
                write_line: *oline,
                read_line: n.loc.start_line,
                writes_in_block: 1,
                note: format!(
                    "`{subject}[{idx}]` is written under an index derived from the one-hot `{onehot}` (isolate-lowest-set-bit): exact form writes `for i: if ({onehot}[i]) {subject}[i]` and keeps the encoded tag only where a binary value is consumed; emission pending"
                ),
            });
        }
    }
    out
}

/// Every reported site of `module`, both kinds.
pub fn sites(module: &TimingModule) -> Vec<PatternSite> {
    let mut v = write_read_bypass_sites(module);
    v.extend(onehot_encode_decode_sites(module));
    v
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{analyze_files, LowerOptions, ParseOptions};

    fn analyze(text: &str) -> TimingModule {
        let dir = std::env::temp_dir().join(format!(
            "svt_patterns_{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("p.sv");
        std::fs::write(&p, text).unwrap();
        let out = analyze_files(&[p], &ParseOptions::default(), &LowerOptions::default()).unwrap();
        let m = out.design.modules.values().next().unwrap().clone();
        let _ = std::fs::remove_dir_all(dir);
        m
    }

    #[test]
    fn same_block_indexed_write_then_read_is_reported_once_with_its_write_count() {
        let m = analyze(
            "module p(input logic clk_i, input logic [2:0] wi, ri, wi2, input logic we, v, output logic r);
               logic [7:0] busy_q, busy_d;
               always_comb begin
                 busy_d = busy_q;
                 if (we) busy_d[wi] = 1'b1;
                 busy_d[wi2] = 1'b0;
                 r = busy_d[ri];
               end
               always_ff @(posedge clk_i) busy_q <= busy_d;
             endmodule",
        );
        let s = write_read_bypass_sites(&m);
        assert_eq!(s.len(), 1, "{s:?}");
        assert_eq!(s[0].kind, PatternKind::IndexedWriteReadBypass);
        assert_eq!(s[0].subject, "busy_d");
        assert_eq!(s[0].writes_in_block, 2);
        assert!(s[0].read_line > s[0].write_line);
        assert!(s[0].note.contains("ri == wi"));
    }

    #[test]
    fn constant_indices_registers_and_reads_before_writes_are_not_sites() {
        let m = analyze(
            "module p(input logic clk_i, input logic [2:0] wi, ri, output logic r, s);
               logic [7:0] busy_q, busy_d, other_d;
               always_comb begin
                 busy_d = busy_q;
                 r = busy_d[ri];        // read before the write: no bypass needed
                 busy_d[wi] = 1'b1;
                 other_d = '0;
                 other_d[3] = 1'b1;     // constant index
                 s = other_d[ri];
               end
               always_ff @(posedge clk_i) busy_q <= busy_d;
             endmodule",
        );
        assert!(write_read_bypass_sites(&m).is_empty());
    }

    #[test]
    fn loop_variable_and_genvar_indices_are_static_selects_not_sites() {
        let m = analyze(
            "module p(input logic clk_i, input logic [3:0][7:0] a_q, output logic [3:0][7:0] o);
               logic [3:0][7:0] g;
               always_comb begin
                 for (int k = 0; k < 4; k++) g[k] = a_q[k] ^ 8'h5a;
                 for (int s = 0; s < 4; s++) o[s] = g[3 - s];
               end
             endmodule",
        );
        assert!(write_read_bypass_sites(&m).is_empty());
    }

    #[test]
    fn isolate_lowest_set_bit_feeding_an_indexed_write_is_reported() {
        let m = analyze(
            "module p(input logic clk_i, input logic [7:0] free_q, input logic [3:0] v, output logic [3:0] o);
               logic [7:0] pick;
               logic [2:0] idx;
               logic [7:0][3:0] mem_q;
               assign pick = free_q & (~free_q + 1'b1);
               always_comb begin
                 idx = '0;
                 for (int i = 0; i < 8; i++) if (pick[i]) idx = 3'(i);
               end
               always_ff @(posedge clk_i) mem_q[idx] <= v;
               assign o = mem_q[0];
             endmodule",
        );
        let s = onehot_encode_decode_sites(&m);
        assert_eq!(s.len(), 1, "{s:?}");
        assert_eq!(s[0].kind, PatternKind::OneHotEncodeDecode);
        assert_eq!(s[0].subject, "mem_q");
        assert!(s[0].note.contains("pick[i]"));
    }
}
