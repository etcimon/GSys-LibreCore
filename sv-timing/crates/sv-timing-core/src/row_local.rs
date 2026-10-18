// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Checked source preparation for explicitly bounded, row-local table updates.
//! Plans are derived from CST statement spans and IR writes, never from a
//! timing score or a module-name heuristic. Applying a plan requires reparse.

use crate::{AssignKind, Expr, OriginKind, PipePragma, RegionKind, SourceLoc, TimingModule};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

/// A latency-neutral source normalization, prepared before ordinary transforms.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RowLocalPlan {
    /// Owning module.
    pub module: String,
    /// Authored strategy name.
    pub name: String,
    /// Stable unsigned selector.
    pub index: String,
    /// Elaboration expression retained in the generated loop.
    pub rows_expr: String,
    /// Rows in the analyzed specialization.
    pub rows: u32,
    /// Explicit replication limit.
    pub max_rows: u32,
    /// Original directive.
    pub directive: SourceLoc,
    /// Canonical directive tokens for stale-authorization checking.
    pub directive_tokens: Vec<String>,
    /// Original conditional-statement span.
    pub origin: SourceLoc,
    /// Exact original bytes; emission refuses stale inputs.
    pub expected: String,
    /// Generated statement, to be reparsed before further transformations.
    pub replacement: String,
    /// Source receipt replacing the executable directive.
    pub receipt: String,
}

#[derive(Debug, Clone)]
struct Token {
    text: String,
    start: usize,
    end: usize,
}

// Tokens retain original byte spans; comments are ignored, not rewritten.
// Strings, escaped identifiers, macros and calls are outside this first rule.
fn tokens(text: &str) -> Result<Vec<Token>, String> {
    let b = text.as_bytes();
    let mut i = 0;
    let mut out = Vec::new();
    while i < b.len() {
        if b[i].is_ascii_whitespace() {
            i += 1;
            continue;
        }
        if b[i..].starts_with(b"//") {
            while i < b.len() && b[i] != b'\n' {
                i += 1;
            }
            continue;
        }
        if b[i..].starts_with(b"/*") {
            let n = text[i + 2..].find("*/").ok_or("unterminated comment")?;
            i += n + 4;
            continue;
        }
        let start = i;
        if matches!(b[i], b'`' | b'"' | b'\\' | b'$' | b'@' | b'#') || !b[i].is_ascii() {
            return Err("row-local refuses macros, strings, calls or timing controls".into());
        }
        if b[i].is_ascii_alphabetic() || b[i] == b'_' {
            i += 1;
            while i < b.len() && (b[i].is_ascii_alphanumeric() || b[i] == b'_') {
                i += 1;
            }
        } else if b[i].is_ascii_digit() || b[i] == b'\'' {
            i += 1;
            while i < b.len()
                && (b[i].is_ascii_alphanumeric() || matches!(b[i], b'_' | b'\'' | b'?'))
            {
                i += 1;
            }
        } else {
            let len = [
                "===", "!==", ">>>", "<<<", "==", "!=", "<=", ">=", "&&", "||", "<<", ">>", "+=",
                "-=", "*=", "/=", "++", "--", "::", "+:", "-:",
            ]
            .iter()
            .find(|op| text[i..].starts_with(**op))
            .map_or(1, |op| op.len());
            i += len;
        }
        out.push(Token {
            text: text[start..i].into(),
            start,
            end: i,
        });
    }
    Ok(out)
}

fn ident(text: &str) -> bool {
    text.as_bytes()
        .first()
        .is_some_and(|b| b.is_ascii_alphabetic() || *b == b'_')
        && text.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
}

fn root_reads(e: &Expr, out: &mut Vec<String>) -> bool {
    match e {
        Expr::Ident { name } => {
            out.push(TimingModule::root_ident(name).unwrap_or(name).into());
            true
        }
        Expr::Literal { .. } => true,
        Expr::Unary { arg, .. } => root_reads(arg, out),
        Expr::Binary { left, right, .. } | Expr::PartSelect { left, right, .. } => {
            root_reads(left, out) && root_reads(right, out)
        }
        Expr::Index { base, index } => root_reads(base, out) && root_reads(index, out),
        Expr::Ternary {
            cond,
            then_e,
            else_e,
        } => root_reads(cond, out) && root_reads(then_e, out) && root_reads(else_e, out),
        _ => false,
    }
}

fn stable_index(
    m: &TimingModule,
    name: &str,
    forbidden: &BTreeSet<String>,
    seen: &mut BTreeSet<String>,
) -> bool {
    if forbidden.contains(name) || !seen.insert(name.into()) {
        return false;
    }
    if m.ports
        .iter()
        .any(|p| p.name == name && p.direction == "input")
        || m.const_exprs.contains_key(name)
    {
        seen.remove(name);
        return true;
    }
    let writers: Vec<_> = m
        .nodes
        .values()
        .filter(|n| n.lhs.as_deref().and_then(TimingModule::root_ident) == Some(name))
        .collect();
    if !writers.is_empty()
        && writers
            .iter()
            .all(|n| n.assign_kind == AssignKind::Nonblocking)
    {
        seen.remove(name);
        return true;
    }
    if writers.len() != 1 || writers[0].assign_kind != AssignKind::Continuous {
        return false;
    }
    let mut reads = Vec::new();
    if !writers[0]
        .rhs_expr
        .as_ref()
        .is_some_and(|e| root_reads(e, &mut reads))
    {
        return false;
    }
    let ok = reads.iter().all(|r| stable_index(m, r, forbidden, seen));
    seen.remove(name);
    ok
}

/// Compile one directive into a checked plan. This changes no executable IR.
pub fn compile(
    m: &TimingModule,
    p: &PipePragma,
    widths: &crate::width::WidthResolver<'_>,
) -> Result<RowLocalPlan, String> {
    let arg = |key: &str| {
        p.args
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.as_str())
    };
    if p.args.len() != 4
        || !p.words.is_empty()
        || p.args
            .iter()
            .any(|(k, _)| !matches!(k.as_str(), "index" | "rows" | "banks" | "max-rows"))
    {
        return Err(
            "row-local needs <name> index=<net> rows=<parameter> banks=<q:d,...> max-rows=<limit>"
                .into(),
        );
    }
    let (Some(name), Some(index), Some(rows_expr), Some(banks), Some(limit)) = (
        p.domain.as_deref(),
        arg("index"),
        arg("rows"),
        arg("banks"),
        arg("max-rows"),
    ) else {
        return Err("incomplete row-local directive".into());
    };
    if !ident(name) || !ident(index) || !ident(rows_expr) {
        return Err("row-local names must be simple identifiers".into());
    }
    let max_rows = limit
        .parse::<u32>()
        .ok()
        .filter(|n| *n > 0 && *n <= 256)
        .ok_or("max-rows must be an explicit limit in 1..256")?;
    if !m.const_exprs.contains_key(rows_expr) {
        return Err("rows must name a declared elaboration constant".into());
    }
    let rows = widths
        .const_value(rows_expr)
        .and_then(|v| u32::try_from(v).ok())
        .filter(|n| *n > 0 && *n <= max_rows)
        .ok_or("row count is unresolved or exceeds max-rows")?;
    let index_ty = m
        .decls
        .iter()
        .find(|d| d.name == index && !d.block_local)
        .map(|d| d.type_name.as_str())
        .or_else(|| {
            m.ports
                .iter()
                .find(|q| q.name == index)
                .and_then(|q| q.type_name.as_deref())
        })
        .ok_or("unbound index")?;
    // Port lowering drops signedness; require the source declaration to be
    // unsigned explicitly. A signed selector would not enumerate 0..rows-1.
    let declared_signed = m
        .source_decl_text(index)
        .is_some_and(|t| t.contains("signed"));
    if !matches!(index_ty.trim(), "logic" | "bit" | "wire" | "reg")
        || declared_signed
        || widths.expr_width(&Expr::parse(index)).is_none()
    {
        return Err("index must have a resolved unsigned integral type".into());
    }
    let mut reads = BTreeSet::new();
    let mut writes = BTreeSet::new();
    for pair in banks.split(',') {
        let (q, d) = pair.split_once(':').ok_or("banks must contain q:d pairs")?;
        if !ident(q)
            || !ident(d)
            || q == d
            || !reads.insert(q.to_string())
            || !writes.insert(d.to_string())
        {
            return Err("bank pairs must have distinct, unambiguous names".into());
        }
        let qd = m
            .decls
            .iter()
            .find(|x| x.name == q && !x.block_local)
            .ok_or("unbound bank source")?;
        let dd = m
            .decls
            .iter()
            .find(|x| x.name == d && !x.block_local)
            .ok_or("unbound bank destination")?;
        let compact = |s: &str| s.chars().filter(|c| !c.is_whitespace()).collect::<String>();
        if !qd.unpacked_text.is_empty()
            || !dd.unpacked_text.is_empty()
            || compact(&qd.packed_text) != compact(&dd.packed_text)
            || qd.type_name != dd.type_name
            || !compact(&qd.packed_text).starts_with(&format!("[{rows_expr}-1:0]"))
        {
            return Err("bank pair requires matching packed array types with [rows-1:0] as its first dimension".into());
        }
        let producers: Vec<_> = m
            .nodes
            .values()
            .filter(|n| n.lhs.as_deref().and_then(TimingModule::root_ident) == Some(q))
            .collect();
        if producers.is_empty()
            || producers
                .iter()
                .any(|n| n.assign_kind != AssignKind::Nonblocking)
            || !producers
                .iter()
                .any(|n| n.rhs.as_deref().is_some_and(|s| s.trim() == d))
        {
            return Err(
                "row-local supports registered tables with an explicit q <= d capture".into(),
            );
        }
    }
    if !reads.is_disjoint(&writes) || writes.contains(index) {
        return Err("overlapping bank/index roles".into());
    }
    if !stable_index(m, index, &writes, &mut BTreeSet::new()) {
        return Err(
            "index depends on mutable next-state, a hidden call or ambiguous driver".into(),
        );
    }
    let stmt = m
        .guard_sites
        .iter()
        .filter_map(|g| g.statement.as_ref())
        .filter(|s| s.loc.start_line > p.loc.start_line && s.loc.start_line <= p.loc.start_line + 3)
        .min_by_key(|s| s.loc.byte_start)
        .ok_or("row-local must directly precede a conditional statement")?;
    if stmt.loc.origin != OriginKind::UserFile || stmt.loc.file != m.file {
        return Err("row-local needs an original-source statement".into());
    }
    // The CST span of a conditional ends at its last consumed token; a
    // trailing block `end` can be the enclosing process's, whose ownership
    // a textual span cannot prove. Use the balanced statement prefix only.
    let all = tokens(&stmt.text)?;
    let mut depth = 0i32;
    let mut cut = None;
    for (i, t) in all.iter().enumerate() {
        if t.text == "begin" {
            depth += 1;
        } else if t.text == "end" {
            depth -= 1;
            if depth < 0 {
                cut = Some(i);
                break;
            }
        }
    }
    let ts: Vec<Token> = match cut {
        Some(i) => all[..i].to_vec(),
        None => all.clone(),
    };
    let Some(last) = ts.last() else {
        return Err("empty conditional statement".into());
    };
    let text_len = last.end;
    let stmt_text = stmt.text[..text_len].to_string();
    let mut stmt_loc = stmt.loc.clone();
    stmt_loc.byte_end = stmt_loc.byte_start + text_len as u32;
    if stmt_text.trim_end().len() != stmt_text.len() {
        return Err("statement span must end on a token".into());
    }
    if !stmt_text.ends_with("end") && !stmt_text.ends_with(';') {
        return Err("row-local statement must end with `end` or `;`".into());
    }
    if m.decls.iter().any(|d| {
        d.loc.file == stmt_loc.file
            && d.loc.byte_start >= stmt_loc.byte_start
            && d.loc.byte_start < stmt_loc.byte_end
    }) {
        return Err("row-local does not duplicate block-local declarations".into());
    }
    let blocked = [
        "for",
        "foreach",
        "while",
        "repeat",
        "forever",
        "case",
        "casex",
        "casez",
        "return",
        "break",
        "continue",
        "automatic",
        "logic",
        "bit",
        "reg",
        "wire",
        "int",
        "integer",
        "fork",
        "join",
        "wait",
        "new",
        "disable",
        "force",
        "release",
    ];
    let mut depth = 0i32;
    for (i, t) in ts.iter().enumerate() {
        if blocked.contains(&t.text.as_str())
            || ["+=", "-=", "*=", "/=", "++", "--"].contains(&t.text.as_str())
            || (ident(&t.text) && ts.get(i + 1).is_some_and(|t| t.text == "(") && t.text != "if")
            || (["begin", "end"].contains(&t.text.as_str())
                && ts.get(i + 1).is_some_and(|t| t.text == ":"))
        {
            return Err(format!(
                "unsupported row-local statement token `{}`",
                t.text
            ));
        }
        if t.text == "begin" {
            depth += 1;
        }
        if t.text == "end" {
            depth -= 1;
        }
        if depth < 0 {
            return Err("conditional source span includes an enclosing block".into());
        }
    }
    if depth != 0 {
        return Err("conditional source span is incomplete".into());
    }
    let inside: Vec<_> = m
        .nodes
        .values()
        .filter(|n| {
            n.loc.file == stmt_loc.file
                && n.loc.byte_start >= stmt_loc.byte_start
                && n.loc.byte_start < stmt_loc.byte_end
                && n.lhs.is_some()
        })
        .collect();
    if inside.is_empty() || ts.iter().filter(|t| t.text == "=").count() != inside.len() {
        return Err("statement write footprint does not match the lowered IR".into());
    }
    // Region loc_span denotes its header, not the whole process body.
    // Membership in one combinational region is the ownership evidence.
    if !m
        .regions
        .values()
        .any(|r| r.kind == RegionKind::AlwaysComb && inside.iter().all(|n| r.nodes.contains(&n.id)))
    {
        return Err("row-local statement must belong to one always_comb".into());
    }
    for n in inside {
        let lhs = tokens(n.lhs.as_deref().unwrap())?;
        if n.assign_kind != AssignKind::Blocking
            || lhs.len() < 4
            || !writes.contains(&lhs[0].text)
            || lhs[1].text != "["
            || lhs[2].text != index
            || lhs[3].text != "]"
        {
            return Err("row-local may write only declared destination[index] fields".into());
        }
    }
    let mut variable = format!("__svt_row_{name}");
    while m.decls.iter().any(|d| d.name == variable)
        || m.ports.iter().any(|d| d.name == variable)
        || m.const_exprs.contains_key(&variable)
        || all.iter().any(|t| t.text == variable)
    {
        variable.push('_');
    }
    let banks: BTreeSet<_> = reads.union(&writes).cloned().collect();
    let mut replacements = Vec::new();
    for (i, t) in ts.iter().enumerate() {
        if !banks.contains(&t.text) || (i > 0 && matches!(ts[i - 1].text.as_str(), "." | "::")) {
            continue;
        }
        if ts.get(i + 1).is_none_or(|t| t.text != "[")
            || ts.get(i + 2).is_none_or(|t| t.text != index)
            || ts.get(i + 3).is_none_or(|t| t.text != "]")
        {
            return Err(
                "every declared bank reference in the statement must use the selected index".into(),
            );
        }
        replacements.push((ts[i + 2].start, ts[i + 2].end));
    }
    let mut body = stmt_text.clone();
    for (lo, hi) in replacements.into_iter().rev() {
        body.replace_range(lo..hi, &variable);
    }
    let replacement = format!(
        "for (int unsigned {variable} = 0; {variable} < {rows_expr}; {variable}++) begin\n\
         if ({index} == {variable}) begin\n{body}\nend\nend\n"
    );
    Ok(RowLocalPlan {
        module: m.name.clone(),
        name: name.into(),
        index: index.into(),
        rows_expr: rows_expr.into(),
        rows,
        max_rows,
        directive: p.loc.clone(),
        origin: stmt_loc,
        expected: stmt_text,
        directive_tokens: std::iter::once("row-local".into())
            .chain(std::iter::once(name.into()))
            .chain(p.args.iter().map(|(k, v)| format!("{k}={v}")))
            .collect(),
        replacement,
        receipt: format!("// svt-pipe: row-local-applied {name} rows={rows_expr} index={index}"),
    })
}

/// Plans present in the initial IR, not yet emitted or physically qualified.
pub fn plans(m: &TimingModule) -> Vec<RowLocalPlan> {
    m.pipe_pragmas
        .iter()
        .filter(|p| p.derived && p.kind == "row-local-ready")
        .filter_map(|p| p.row_local.clone())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{analyze_files, LowerOptions, ParseOptions};
    const SOURCE: &str = include_str!("../../../fixtures/auto_correct/row_local.sv");

    fn analyze(text: &str) -> crate::TimingDesign {
        static NEXT: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let path = std::env::temp_dir().join(format!(
            "svt_row_{}_{}.sv",
            std::process::id(),
            NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        ));
        std::fs::write(&path, text).unwrap();
        let out = analyze_files(
            &[path.clone()],
            &ParseOptions::default(),
            &LowerOptions::default(),
        )
        .unwrap();
        std::fs::remove_file(path).unwrap();
        out.design
    }
    fn first(d: &crate::TimingDesign) -> &TimingModule {
        d.modules.values().find(|m| m.name == "row_local").unwrap()
    }
    #[test]
    fn vector_and_struct_banks_prepare_without_timing_credit() {
        let d = analyze(SOURCE);
        for m in d.modules.values() {
            let ps = plans(m);
            assert_eq!(ps.len(), 1, "{:?}", crate::pipe_contract::resolve(m));
            assert!(ps[0].replacement.contains("__svt_row_"));
            assert!(ps[0].expected.starts_with("if"));
            assert!(crate::pipe_contract::resolve(m)
                .unwrap()
                .rejected
                .is_empty());
        }
        let p = &plans(first(&d))[0];
        assert!(p.replacement.contains("// A comment containing q[uidx]"));
        assert!(p.replacement.contains("q[__svt_row_train]"));
        let plain = analyze(
            &SOURCE
                .lines()
                .filter(|l| !l.contains("svt-pipe: row-local"))
                .collect::<Vec<_>>()
                .join("\n"),
        );
        let costs = |m: &TimingModule| {
            m.nodes
                .values()
                .map(|n| (n.lhs.clone(), n.rhs.clone(), n.width, n.fo4_cost))
                .collect::<Vec<_>>()
        };
        assert_eq!(costs(first(&d)), costs(first(&plain)));
    }
    #[test]
    fn numeric_uses_of_index_keep_their_original_width() {
        let d = analyze(&SOURCE.replace("if (q[uidx] != 8'hff)", "if (uidx + 3'd1 != 3'd0)"));
        let p = &plans(first(&d))[0];
        assert!(p.replacement.contains("uidx + 3'd1"));
        assert!(p.replacement.contains("q[__svt_row_train]"));
    }
    #[test]
    fn unsafe_footprints_and_replication_are_refused() {
        for source in [
            SOURCE.replace("max-rows=16", "max-rows=4"),
            SOURCE.replace(
                "input logic [$clog2(N)-1:0]",
                "input logic signed [$clog2(N)-1:0]",
            ),
            SOURCE.replace("d[uidx] = q[uidx] + 8'd1", "result_o = q[uidx] + 8'd1"),
            SOURCE.replace("d[uidx] = q[uidx] + 8'd1", "d[uidx] = q[ridx] + 8'd1"),
            SOURCE.replace("d[uidx] = q[uidx] + 8'd1", "d[uidx] = bump(q[uidx])"),
            SOURCE.replace("d[uidx] = q[uidx] + 8'd1", "d[uidx] += 8'd1"),
        ] {
            let d = analyze(&source);
            assert!(plans(first(&d)).is_empty(), "{source}");
            assert!(!crate::pipe_contract::resolve(first(&d))
                .unwrap()
                .rejected
                .is_empty());
        }
    }
    #[test]
    fn mutable_index_and_macro_body_are_not_rewritten() {
        let source = SOURCE.replace("uidx, ridx", "uidx_in, ridx").replace(
            "logic [N-1:0][7:0] q, d;",
            "logic [N-1:0][7:0] q, d;\nlogic [$clog2(N)-1:0] uidx;\nassign uidx = d[0];",
        );
        assert!(plans(first(&analyze(&source))).is_empty());
        let source = format!(
            "`define BUMP(x) ((x)+8'd1)\n{}",
            SOURCE.replace("q[uidx] + 8'd1", "`BUMP(q[uidx])")
        );
        assert!(plans(first(&analyze(&source))).is_empty());
    }
}
