// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Cut-site RHS extraction and origin-line rewrite for pipeline inserts.

//! When auto-correct inserts a pipeline stage at `file:line`, recover the
//! original assignment (`lhs = rhs` / `lhs <= rhs`) so emit can:
//! 1. Feed `pipe_c` from the real **rhs** (not zero).
//! 2. Rewrite the origin line to `lhs = pipe` so the late cloud samples the reg.

use sv_timing_core::SourceLoc;
use sv_timing_transform::{EditKind, EditRecord, EditTrace};

/// One recovered assignment at a cut site.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CutAssign {
    /// 1-based start line in the source unit (origin rewrite).
    pub line: u32,
    /// 1-based end line inclusive (multi-line assigns). Equal to `line` for single-line.
    pub end_line: u32,
    /// Left-hand side (trimmed).
    pub lhs: String,
    /// Right-hand side expression (trimmed, no trailing `;`).
    pub rhs: String,
    /// True if original used nonblocking `<=`.
    pub nonblocking: bool,
    /// Pipeline register name from the edit (`new_name`).
    pub pipe_name: String,
    /// Edit id.
    pub edit_id: u32,
    /// True when origin was a continuous `assign` (safe to rewrite + sink).
    pub continuous: bool,
}

/// Extract `lhs`/`rhs` from a single SV assignment line.
///
/// Handles case items like `ADD, SUB: result_o = adder_result;` by stripping
/// case labels so sinks emit `assign result_o = pipe` (not illegal `assign ADD, SUB: …`).
pub fn parse_assign_line(line: &str) -> Option<(String, String, bool)> {
    let t = strip_line_comment(line).trim();
    if t.is_empty() || t.starts_with("//") {
        return None;
    }
    // Skip declarations: `logic … =`
    let lower = t.to_ascii_lowercase();
    if lower.starts_with("logic ")
        || lower.starts_with("wire ")
        || lower.starts_with("reg ")
        || lower.starts_with("assign ")
        || lower.starts_with("input ")
        || lower.starts_with("output ")
        || lower.starts_with("parameter")
        || lower.starts_with("localparam")
    {
        // Continuous assign: `assign lhs = rhs;`
        if let Some(rest) = t.strip_prefix("assign ").or_else(|| t.strip_prefix("assign\t")) {
            return parse_lhs_rhs(rest.trim(), false);
        }
        return None;
    }
    // Case item: `LABEL, LABEL: lhs = rhs` (not ternary `cond ? a : b`)
    let t = strip_case_item_labels(t);
    if let Some((l, r)) = split_once_op(t, "<=") {
        let l = sanitize_lhs(&l)?;
        return Some((l, trim_semi(&r), true));
    }
    if let Some((l, r)) = split_once_op(t, "=") {
        // Avoid `==`, `!=`, `<=` already handled, `>=`
        let l = sanitize_lhs(&l)?;
        return Some((l, trim_semi(&r), false));
    }
    None
}

/// If `line` is a same-line case item (`ADD, SUB: result_o = …`), return
/// `"ADD, SUB: "` (including trailing space). Empty when labels are on a prior
/// line only or the line is a plain assign.
pub fn case_item_label_prefix(line: &str) -> String {
    let raw = strip_line_comment(line);
    let t = raw.trim();
    let stripped = strip_case_item_labels(t);
    if stripped == t || stripped.is_empty() {
        return String::new();
    }
    // Prefix is everything before the assign body (labels + colon).
    if let Some(pos) = t.find(stripped) {
        if pos > 0 {
            return t[..pos].trim_end().to_string() + " ";
        }
    }
    // Fallback: up through first colon when strip removed labels.
    if let Some(colon) = t.find(':') {
        let before = t[..colon].trim();
        if looks_like_case_labels(before) {
            return format!("{before}: ");
        }
    }
    String::new()
}

/// Strip `CASELABELS:` prefix when it looks like a case item (not a ternary).
fn strip_case_item_labels(s: &str) -> &str {
    // Find a colon that is not the `:` of `?:` and is followed by an assignment.
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'?' {
            // Ternary — do not strip any later colon as case label on this line alone.
            return s;
        }
        if bytes[i] == b':' {
            let before = s[..i].trim();
            let after = s[i + 1..].trim_start();
            if looks_like_case_labels(before) && (after.contains('=') || after.is_empty()) {
                return if after.is_empty() { "" } else { after };
            }
        }
        i += 1;
    }
    s
}

fn looks_like_case_labels(s: &str) -> bool {
    if s.is_empty() {
        return false;
    }
    // Identifiers, commas, whitespace only (e.g. `ADD, SUB, ADDUW` or `CLZ, CTZ`).
    s.chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == ',' || c.is_whitespace())
        && s.chars().any(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// Reject LHS that is not a simple lvalue (case labels, `if` stmts, etc.).
fn sanitize_lhs(lhs: &str) -> Option<String> {
    let l = lhs.trim();
    if l.is_empty() {
        return None;
    }
    // Must not contain commas or bare case-label lists
    if l.contains(',') || l.contains(':') {
        return None;
    }
    // Reject control keywords / statements glued into LHS
    let first = l.split(|c: char| c == '.' || c == '[' || c == ' ' || c == '(')
        .next()
        .unwrap_or("");
    let fl = first.to_ascii_lowercase();
    if matches!(
        fl.as_str(),
        "if" | "for"
            | "while"
            | "unique"
            | "priority"
            | "case"
            | "casex"
            | "casez"
            | "end"
            | "else"
            | "always"
            | "always_comb"
            | "always_ff"
            | "begin"
            | "assign"
            | "return"
    ) {
        return None;
    }
    // No spaces or call-like parens in a clean lvalue
    if l.contains(' ') || l.contains('(') {
        return None;
    }
    Some(l.to_string())
}

/// True if RHS has balanced `()`/`{}`/`[]` and balanced ternary `?`/`:`.
///
/// Ternary colons are counted only at nesting depth 0 for `()`/`{}`/`[]` so that
/// bit-selects like `instr_i[6:5]` and replication `{N{e}}` do not false-complete
/// a multi-line ternary whose false arm is on the next line (frontend `rvc_imm_o`).
///
/// Also rejects an **empty false arm** after the last ternary colon (`… ? a :` with
/// `mask_q` on the next source line) — common in CVA6 continuous assigns
/// (`exp_backoff` mask_d/cnt_d). Balanced `?`/`: ` counts alone are not enough.
pub fn rhs_structurally_complete(rhs: &str) -> bool {
    let mut par = 0i32;
    let mut brace = 0i32;
    let mut brack = 0i32;
    let mut q = 0i32;
    let mut colon_tern = 0i32;
    let mut last_tern_colon: Option<usize> = None;
    let b = rhs.as_bytes();
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'(' => par += 1,
            b')' => par -= 1,
            b'{' => brace += 1,
            b'}' => brace -= 1,
            b'[' => brack += 1,
            b']' => brack -= 1,
            b'?' => {
                // Nested `?` only counts as ternary when not inside bit-select brackets.
                // Count at any paren depth so wrapped feeds `((cond) ? a : b)` still match.
                if brack == 0 {
                    q += 1;
                }
            }
            b':' => {
                // Ternary arm separator: unmatched `?`, not inside bit-select `[]`
                // or braces. Allow inside outer `()` so full-paren feeds work.
                if q > colon_tern && brace == 0 && brack == 0 {
                    colon_tern += 1;
                    last_tern_colon = Some(i);
                }
            }
            _ => {}
        }
        if par < 0 || brace < 0 || brack < 0 {
            return false;
        }
        i += 1;
    }
    if !(par == 0 && brace == 0 && brack == 0 && q == colon_tern) {
        return false;
    }
    // Empty false arm: after last ternary `:`, only whitespace / closing parens.
    if let Some(pos) = last_tern_colon {
        let after = rhs[pos + 1..].trim();
        let only_closers = after.chars().all(|c| c == ')' || c == '}' || c.is_whitespace());
        if after.is_empty() || only_closers {
            return false;
        }
    }
    // Trailing binary op (`… + )` from multi-line add cut mid-expression).
    if trailing_incomplete_operator(rhs) {
        return false;
    }
    true
}

/// True when RHS ends with a binary/ternary operator (optionally wrapped in closers).
fn trailing_incomplete_operator(rhs: &str) -> bool {
    let mut s = rhs.trim().trim_end_matches(';').trim_end();
    while let Some(next) = s
        .strip_suffix(')')
        .or_else(|| s.strip_suffix(']'))
        .or_else(|| s.strip_suffix('}'))
    {
        s = next.trim_end();
    }
    if s.is_empty() {
        return true;
    }
    if s.ends_with("&&")
        || s.ends_with("||")
        || s.ends_with("<<")
        || s.ends_with(">>")
        || s.ends_with("==")
        || s.ends_with("!=")
        || s.ends_with("<=")
        || s.ends_with(">=")
        || s.ends_with("===")
        || s.ends_with("!==")
    {
        return true;
    }
    matches!(
        s.as_bytes()[s.len() - 1] as char,
        '+' | '-' | '*' | '/' | '%' | '&' | '|' | '^' | '?' | ':' | ','
    )
}

/// Recover assignment spanning multiple lines (case label on one line, body on next).
pub fn parse_assign_multiline(source: &str, start_line_1based: u32, max_extra: u32) -> Option<(String, String, bool, u32)> {
    // Returns (lhs, rhs, nba, end_line)
    let mut acc = String::new();
    let mut end = start_line_1based;
    let mut saw_semi = false;
    for k in 0..=max_extra {
        let line_no = start_line_1based + k;
        let Some(raw) = source_line(source, line_no) else {
            break;
        };
        let stripped = strip_line_comment(raw).trim();
        if stripped.contains(';') {
            saw_semi = true;
        }
        if k > 0 {
            acc.push(' ');
        }
        acc.push_str(stripped);
        end = line_no;
        if let Some((lhs, rhs, nba)) = parse_assign_line(&acc) {
            if rhs_structurally_complete(&rhs) {
                // Structurally complete is not enough: frontend multi-line AND
                // (`rvc_branch_o = (a|b)\n & (c);`) is complete after line 1's
                // parens but still continues. Prefer waiting for `;`, or ensure
                // the next line is not an expression continuation.
                if saw_semi {
                    return Some((lhs, rhs, nba, end));
                }
                let next = source_line(source, line_no + 1).unwrap_or("");
                // Never pull the next case item into this assign's span.
                if is_case_label_only_line(next) {
                    return Some((lhs, rhs, nba, end));
                }
                if !looks_like_expr_continuation(next) {
                    return Some((lhs, rhs, nba, end));
                }
                // else keep accumulating continuation line(s)
            }
            // Keep accumulating if incomplete ternary / parens / multi-line ops
        }
        // Stop before swallowing the next case label into an incomplete RHS.
        let next = source_line(source, line_no + 1).unwrap_or("");
        if is_case_label_only_line(next) {
            break;
        }
    }
    // Do not return incomplete RHS — callers must keep scanning or skip the cut.
    if let Some((l, r, n)) = parse_assign_line(&acc) {
        if rhs_structurally_complete(&r) {
            return Some((l, r, n, end));
        }
    }
    None
}

/// True when a following source line continues a multi-line expression.
fn looks_like_expr_continuation(line: &str) -> bool {
    let t = strip_line_comment(line).trim();
    if t.is_empty() {
        return false;
    }
    // Binary / ternary continuations common in CVA6 continuous assigns.
    // Also parenthesized / unary continuations (e.g. `jump_taken = a ||\n  (b && c);`).
    t.starts_with("&&")
        || t.starts_with("||")
        || t.starts_with("<<")
        || t.starts_with(">>")
        || t.starts_with("==")
        || t.starts_with("!=")
        || t.starts_with("<=")
        || t.starts_with(">=")
        || t.starts_with('&')
        || t.starts_with('|')
        || t.starts_with('^')
        || t.starts_with('+')
        || t.starts_with('-')
        || t.starts_with('*')
        || t.starts_with('/')
        || t.starts_with('%')
        || t.starts_with('?')
        || t.starts_with(':')
        || t.starts_with(',')
        || t.starts_with(')')
        || t.starts_with('}')
        || t.starts_with('(')
        || t.starts_with('{')
        || t.starts_with('!')
        || t.starts_with('~')
        || t.starts_with('$') // `$signed(...)` continuations on next line
}

fn parse_lhs_rhs(s: &str, nba: bool) -> Option<(String, String, bool)> {
    if let Some((l, r)) = split_once_op(s, if nba { "<=" } else { "=" }) {
        Some((l, trim_semi(&r), nba))
    } else {
        None
    }
}

fn split_once_op(s: &str, op: &str) -> Option<(String, String)> {
    // Find op not part of ==, !=, <=, >=, === when op is "="
    let bytes = s.as_bytes();
    let opb = op.as_bytes();
    let mut i = 0;
    while i + opb.len() <= bytes.len() {
        if &bytes[i..i + opb.len()] == opb {
            let prev = if i > 0 { bytes[i - 1] as char } else { ' ' };
            let next = bytes.get(i + opb.len()).map(|c| *c as char).unwrap_or(' ');
            if op == "=" {
                if prev == '!' || prev == '<' || prev == '>' || prev == '=' || next == '=' {
                    i += 1;
                    continue;
                }
            }
            if op == "<=" && next == '=' {
                i += 1;
                continue;
            }
            let lhs = s[..i].trim().to_string();
            let rhs = s[i + opb.len()..].trim().to_string();
            if !lhs.is_empty() && !rhs.is_empty() {
                return Some((lhs, rhs));
            }
        }
        i += 1;
    }
    None
}

fn trim_semi(s: &str) -> String {
    s.trim()
        .trim_end_matches(';')
        .trim()
        .to_string()
}

fn strip_line_comment(line: &str) -> &str {
    if let Some(i) = line.find("//") {
        &line[..i]
    } else {
        line
    }
}

/// Source line 1-based.
pub fn source_line(source: &str, line_1based: u32) -> Option<&str> {
    if line_1based == 0 {
        return None;
    }
    source.lines().nth((line_1based - 1) as usize)
}

/// True when 1-based `line` sits inside a `generate`…`endgenerate` region.
///
/// Crude nesting count (ignores strings/comments edge cases). Module-scope
/// generate-if/for without the keyword (CVA6 `if (CVA6Cfg.ZKN) begin` + genvar)
/// are covered separately by free-gen-index refusal on the cut LHS/RHS (R12).
pub fn line_inside_generate(source: &str, line: u32) -> bool {
    if line == 0 {
        return false;
    }
    let mut depth: i32 = 0;
    for (i, raw) in source.lines().enumerate() {
        let ln = (i + 1) as u32;
        let t = strip_line_comment(raw).trim();
        let lower = t.to_ascii_lowercase();
        if lower == "generate"
            || lower.starts_with("generate ")
            || lower.starts_with("generate\t")
        {
            depth += 1;
        }
        if lower == "endgenerate"
            || lower.starts_with("endgenerate ")
            || lower.starts_with("endgenerate;")
            || lower.starts_with("endgenerate\t")
        {
            depth = (depth - 1).max(0);
        }
        if ln == line {
            return depth > 0;
        }
    }
    false
}

/// True when `line` is a continuous `assign` statement.
fn line_is_continuous_assign(source: &str, line: u32) -> bool {
    let Some(raw) = source_line(source, line) else {
        return false;
    };
    let t = strip_line_comment(raw).trim();
    t.starts_with("assign ") || t.starts_with("assign\t")
}

/// Base identifier of an lvalue (`foo[3:0]` → `foo`, `pkg::x` → last segment).
fn lhs_base_ident(lhs: &str) -> &str {
    let s = lhs.trim();
    let s = s.split('[').next().unwrap_or(s).trim();
    s.rsplit("::").next().unwrap_or(s).trim()
}

/// True when `lhs` is safe to drive from a module-scope continuous sink.
///
/// Returns **false** only when we positively see an `automatic` decl of the base
/// name (always_comb/function local). Unknown / module-level logic/ports → true
/// (fixtures may omit full decls).
fn lhs_is_module_level_net(source: &str, lhs: &str) -> bool {
    let base = lhs_base_ident(lhs);
    if base.is_empty() {
        return false;
    }
    for line in source.lines() {
        let t = strip_line_comment(line).trim();
        let lower = t.to_ascii_lowercase();
        if lower.starts_with("automatic ") && t.contains(base) {
            let toks: Vec<&str> = t
                .split(|c: char| !c.is_ascii_alphanumeric() && c != '_')
                .filter(|s| !s.is_empty())
                .collect();
            if toks.iter().any(|tok| *tok == base) {
                return false;
            }
        }
    }
    true
}

/// Unified R12 gate: snippet is safe to inject early **and** to use for origin
/// RHS rewrite. Keep demotion and rewrite in lockstep.
pub fn balance_mux_snippet_safe(source: &str, snippet: &str, origin_line: u32) -> bool {
    let t = snippet.trim();
    if t.is_empty() {
        return false;
    }
    if has_free_gen_index(t) {
        return false;
    }
    if line_inside_generate(source, origin_line) {
        return false;
    }
    if snippet_has_generate_local_param(t) {
        return false;
    }
    if snippet_refs_late_declared_local(source, t) {
        return false;
    }
    true
}

/// Generate-scoped localparam names illegal at module-scope inject.
pub fn snippet_has_generate_local_param(text: &str) -> bool {
    let bytes = text.as_bytes();
    let mut i = 0usize;
    while i < bytes.len() {
        let c = bytes[i] as char;
        if c.is_ascii_alphabetic() || c == '_' {
            let start = i;
            i += 1;
            while i < bytes.len() {
                let d = bytes[i] as char;
                if d.is_ascii_alphanumeric() || d == '_' {
                    i += 1;
                } else {
                    break;
                }
            }
            let tok = &text[start..i];
            if matches!(
                tok,
                "EXP_BITS"
                    | "MAN_BITS"
                    | "INT_BITS"
                    | "FP_WIDTH"
                    | "INT_WIDTH"
                    | "NUM_FP_STICKY"
                    | "NUM_INT_STICKY"
                    | "BIAS"
                    | "PRECISION"
            ) {
                return true;
            }
        } else {
            i += 1;
        }
    }
    false
}

/// True when snippet references idents declared only after the first process.
///
/// Shared with dense early-inject demotion so BalanceMux RHS rewrite and
/// snippet inject stay aligned (R12).
pub fn snippet_refs_late_declared_local(source: &str, snippet: &str) -> bool {
    let first_proc = {
        let lower = source.to_ascii_lowercase();
        let mut best = source.len();
        for key in [
            "always_comb",
            "always_ff",
            "always_latch",
            "always @",
            "always@",
            "\nassign ",
            "\n  assign ",
        ] {
            if let Some(i) = lower.find(key) {
                if let Some(mod_i) = lower.find("module ") {
                    if i > mod_i {
                        best = best.min(i);
                    }
                }
            }
        }
        best
    };
    let bytes = snippet.as_bytes();
    let mut i = 0usize;
    while i < bytes.len() {
        let c = bytes[i] as char;
        if c.is_ascii_alphabetic() || c == '_' {
            let start = i;
            i += 1;
            while i < bytes.len() {
                let d = bytes[i] as char;
                if d.is_ascii_alphanumeric() || d == '_' {
                    i += 1;
                } else {
                    break;
                }
            }
            let id = &snippet[start..i];
            if id.starts_with("svt_") || id.starts_with("SVT_") {
                continue;
            }
            if matches!(
                id,
                "logic" | "wire" | "reg" | "assign" | "always_comb" | "always_ff" | "begin"
                    | "end" | "if" | "else" | "input" | "output" | "module" | "parameter"
                    | "localparam" | "signed" | "unsigned" | "int" | "bit"
            ) {
                continue;
            }
            // Find first logic/wire/reg decl of this ident
            let mut off = 0usize;
            for line in source.lines() {
                let t = line.trim();
                if (t.starts_with("logic ") || t.starts_with("wire ") || t.starts_with("reg "))
                    && t.contains(id)
                {
                    let toks: Vec<&str> = t
                        .split(|c: char| !c.is_ascii_alphanumeric() && c != '_')
                        .filter(|s| !s.is_empty())
                        .collect();
                    if toks.iter().any(|tok| *tok == id) && off > first_proc {
                        return true;
                    }
                }
                off += line.len() + 1;
            }
        } else {
            i += 1;
        }
    }
    false
}

/// True when text likely references free generate-loop indices (module-scope illegal).
pub fn has_free_gen_index(text: &str) -> bool {
    let bytes = text.as_bytes();
    let mut i = 0usize;
    while i < bytes.len() {
        let c = bytes[i] as char;
        if c.is_ascii_alphabetic() || c == '_' {
            let start = i;
            i += 1;
            while i < bytes.len() {
                let d = bytes[i] as char;
                if d.is_ascii_alphanumeric() || d == '_' {
                    i += 1;
                } else {
                    break;
                }
            }
            let tok = &text[start..i];
            if matches!(
                tok,
                "i" | "j"
                    | "k"
                    | "m"
                    | "n"
                    | "q" // xperm / nibble genvars (alu ZKN)
                    | "ii"
                    | "jj"
                    | "fmt"
                    | "ifmt"
                    | "lane"
                    | "lvl"
                    | "gen"
                    | "gi"
                    | "gj"
            ) {
                return true;
            }
        } else {
            i += 1;
        }
    }
    false
}

/// Build cut assigns for InsertReg edits with **unique** origin lines.
///
/// Rules (multi-cut):
/// 1. First edit that claims a source line gets that line's `lhs`/`rhs` (origin rewrite + feed).
/// 2. Later edits on an already-claimed line **chain**: `rhs = previous_pipe` (no second rewrite).
/// 3. If the origin line is not an assign, scan nearby lines (±radius) for an unclaimed assign.
/// 4. Else chain to previous pipe if any; otherwise skip (dense emit uses placeholder/chain).
/// 5. **R12:** origins inside `generate` do not claim (chain/zero feed) — locals are not
///    visible at module-scope dense inject.
pub fn cut_assigns_from_source(source: &str, trace: &EditTrace) -> Vec<CutAssign> {
    // Radius 8: multi-line nested ternaries (exp_backoff mask_d is 3 lines;
    // some CSR/decoder cases need more headroom than 6).
    cut_assigns_from_source_ex(source, trace, 8)
}

/// Same as [`cut_assigns_from_source`] with explicit nearby-line search radius.
pub fn cut_assigns_from_source_ex(
    source: &str,
    trace: &EditTrace,
    nearby_radius: u32,
) -> Vec<CutAssign> {
    let mut out = Vec::new();
    let mut claimed_lines: std::collections::BTreeSet<u32> = std::collections::BTreeSet::new();
    let mut claimed_lhs: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    let mut prev_pipe: Option<String> = None;

    let line_count = source.lines().count() as u32;

    for r in &trace.records {
        if r.kind != EditKind::InsertReg {
            continue;
        }
        let Some(pipe) = r.new_name.as_ref() else {
            continue;
        };

        // --- try exclusive claim on origin line (multi-line case bodies OK) ---
        // R12: refuse generate / free-gen / automatic lhs. Both continuous and
        // procedural assigns may claim for feeds; origin rewrite+sink only for
        // continuous (see rewrite_origin_assigns / sink_assigns_sv).
        let mut claimed: Option<CutAssign> = None;
        let origin_line = r.origin.start_line;
        let origin_in_gen = line_inside_generate(source, origin_line);
        if origin_line > 0 && !origin_in_gen && !claimed_lines.contains(&origin_line) {
            if let Some((lhs, rhs, nba, end)) =
                parse_assign_multiline(source, origin_line, 8)
            {
                let lhs_ok =
                    !has_free_gen_index(&lhs) && lhs_is_module_level_net(source, &lhs);
                if rhs_structurally_complete(&rhs) && lhs_ok && !claimed_lhs.contains(&lhs) {
                    for ln in origin_line..=end {
                        claimed_lines.insert(ln);
                    }
                    claimed_lhs.insert(lhs.clone());
                    claimed = Some(CutAssign {
                        line: origin_line,
                        end_line: end,
                        lhs,
                        rhs,
                        nonblocking: nba,
                        pipe_name: pipe.clone(),
                        edit_id: r.id,
                        continuous: line_is_continuous_assign(source, origin_line),
                    });
                }
            }
        }

        // --- nearby unclaimed assign (distinct cut sites when IR nodes share a line) ---
        if claimed.is_none() && origin_line > 0 && !origin_in_gen {
            let lo = origin_line.saturating_sub(nearby_radius).max(1);
            let hi = (origin_line + nearby_radius).min(line_count.max(1));
            // Prefer lines farther from already-claimed, scan outward
            let mut candidates: Vec<u32> = (lo..=hi).filter(|l| *l != origin_line).collect();
            candidates.sort_by_key(|l| origin_line.abs_diff(*l));
            for line_no in candidates {
                if claimed_lines.contains(&line_no) || line_inside_generate(source, line_no) {
                    continue;
                }
                let Some((lhs, rhs, nba, end)) =
                    parse_assign_multiline(source, line_no, 8)
                else {
                    continue;
                };
                if !rhs_structurally_complete(&rhs) {
                    continue;
                }
                if has_free_gen_index(&lhs) || !lhs_is_module_level_net(source, &lhs) {
                    continue;
                }
                if claimed_lhs.contains(&lhs) {
                    continue;
                }
                for ln in line_no..=end {
                    claimed_lines.insert(ln);
                }
                claimed_lhs.insert(lhs.clone());
                claimed = Some(CutAssign {
                    line: line_no,
                    end_line: end,
                    lhs,
                    rhs,
                    nonblocking: nba,
                    pipe_name: pipe.clone(),
                    edit_id: r.id,
                    continuous: line_is_continuous_assign(source, line_no),
                });
                break;
            }
        }

        // --- chain to previous pipe (shared origin or no assign nearby) ---
        if claimed.is_none() {
            if let Some(prev) = prev_pipe.clone() {
                claimed = Some(CutAssign {
                    line: 0, // no origin rewrite
                    end_line: 0,
                    lhs: String::new(), // no sink
                    rhs: prev,
                    nonblocking: false,
                    pipe_name: pipe.clone(),
                    edit_id: r.id,
                    continuous: false,
                });
            }
        }

        if let Some(c) = claimed {
            prev_pipe = Some(c.pipe_name.clone());
            out.push(c);
        } else {
            prev_pipe = Some(pipe.clone());
        }
    }
    out
}

/// Feed expression for the first pipeline stage: prefer first cut's rhs.
pub fn primary_feed_expr(cuts: &[CutAssign]) -> Option<String> {
    cuts.first().map(|c| c.rhs.clone())
}

/// Comment-out origin assignment lines (avoid use-before-declare of pipe regs).
///
/// `lhs = rhs` → `// sv-timing: cut #id moved lhs ← (rhs) via pipe`
///
/// Late sampling is emitted **after** pipe declarations as
/// `assign lhs = pipe;` (see dense block “cut sinks”).
pub fn rewrite_origin_assigns(source: &str, cuts: &[CutAssign]) -> String {
    if cuts.is_empty() {
        return source.to_string();
    }
    // Cuts with line > 0 rewrite origin; multi-line assigns claim [line, end_line].
    let mut line_to_cut: std::collections::BTreeMap<u32, &CutAssign> =
        std::collections::BTreeMap::new();
    for c in cuts.iter().filter(|c| c.line > 0) {
        let end = c.end_line.max(c.line);
        for ln in c.line..=end {
            line_to_cut.entry(ln).or_insert(c);
        }
    }

    let lines: Vec<&str> = source.lines().collect();
    let mut out = String::with_capacity(source.len() + 64 * cuts.len());
    for (i, line) in lines.iter().enumerate() {
        let line_no = (i + 1) as u32;
        if let Some(cut) = line_to_cut.get(&line_no) {
            // R12d: only rewrite continuous-assign cuts. Procedural always_comb
            // bodies are kept intact (pipe still stages with zero feed).
            if !cut.continuous {
                if line_no == cut.line {
                    let indent: String = line.chars().take_while(|c| c.is_whitespace()).collect();
                    out.push_str(&indent);
                    out.push_str(&format!(
                        "// sv-timing: cut #{} note (procedural origin kept; lean pipe)\n",
                        cut.edit_id
                    ));
                }
                out.push_str(line);
                out.push('\n');
                continue;
            }
            let indent: String = line
                .chars()
                .take_while(|c| c.is_whitespace())
                .collect();
            if line_no == cut.line {
                // If this was the sole statement of an `if/else` without `begin`,
                // leave a null statement so the control construct stays legal.
                if needs_null_stmt_after_control(&lines, i) {
                    out.push_str(&indent);
                    out.push_str("; // sv-timing: null stmt (cut body)\n");
                }
                // Continuous `assign` origins stay comment-only; dense sinks drive lhs.
                // Full cut comment on the first line only.
                out.push_str(&indent);
                out.push_str("// sv-timing: cut #");
                out.push_str(&cut.edit_id.to_string());
                out.push_str(" moved ");
                out.push_str(&cut.lhs);
                out.push_str(" <- (");
                out.push_str(&cut.rhs);
                out.push_str(") via ");
                out.push_str(&cut.pipe_name);
                out.push_str(" (declared below)\n");
            } else if is_case_label_only_line(line) {
                // Do not comment case labels if multi-line cut span over-reached.
                out.push_str(line);
                out.push('\n');
            } else {
                // Continuation lines of multi-line assign — keep commented out.
                out.push_str(&indent);
                out.push_str("// sv-timing: (cut #");
                out.push_str(&cut.edit_id.to_string());
                out.push_str(" continuation) ");
                out.push_str(line.trim());
                out.push('\n');
            }
        } else {
            out.push_str(line);
            out.push('\n');
        }
    }
    if !source.ends_with('\n') && out.ends_with('\n') {
        out.pop();
    }
    out
}

/// Rewrite origin assign RHS for BalanceMux / rebalance edits that carry `emit_rhs`.
///
/// Keeps the original LHS and operator (`=` / `<=`); replaces only the RHS text.
/// Multi-line assigns: rewrites the first line and comments continuations.
/// Also applies [`EditRecord::emit_rhs_extras`] (exclusive one-hot multi-arm wire-up).
pub fn rewrite_origin_rhs_replaces(source: &str, trace: &EditTrace) -> String {
    let mut replaces: Vec<(u32, u32, String, u32)> = Vec::new(); // start, end, new_rhs, edit_id
    for r in &trace.records {
        if !matches!(
            r.kind,
            EditKind::BalanceMux | EditKind::RebalanceAssoc
        ) {
            continue;
        }
        // R12: only rewrite origin when a **safe** structural snippet will be
        // injected (same gate as dense early inject).
        let has_safe_snippet = r
            .emit_snippet
            .as_ref()
            .map(|s| balance_mux_snippet_safe(source, s, r.origin.start_line))
            .unwrap_or(false);
        if !has_safe_snippet {
            continue;
        }
        if let Some(new_rhs) = r.emit_rhs.as_ref() {
            if r.origin.start_line != 0 {
                let end = r.origin.end_line.max(r.origin.start_line);
                replaces.push((r.origin.start_line, end, new_rhs.clone(), r.id));
            }
        }
        for ex in &r.emit_rhs_extras {
            if ex.origin.start_line == 0 {
                continue;
            }
            if line_inside_generate(source, ex.origin.start_line) {
                continue;
            }
            let end = ex.origin.end_line.max(ex.origin.start_line);
            replaces.push((ex.origin.start_line, end, ex.emit_rhs.clone(), r.id));
        }
    }
    if replaces.is_empty() {
        return source.to_string();
    }
    // Expand each rewrite span using multi-line assign recovery so ternary
    // continuations (and similar) are claimed even when origin end_line is short.
    let mut expanded: Vec<(u32, u32, String, u32)> = Vec::new();
    for (start, end, new_rhs, edit_id) in &replaces {
        let span_end = parse_assign_multiline(source, *start, 6)
            .map(|(_, _, _, e)| e)
            .unwrap_or(*end)
            .max(*end)
            .max(*start);
        expanded.push((*start, span_end, new_rhs.clone(), *edit_id));
    }
    // First claim wins per line
    let mut line_map: std::collections::BTreeMap<u32, (u32, u32, String, u32)> =
        std::collections::BTreeMap::new();
    for r in &expanded {
        for ln in r.0..=r.1 {
            line_map.entry(ln).or_insert_with(|| r.clone());
        }
    }
    let lines: Vec<&str> = source.lines().collect();
    let mut out = String::with_capacity(source.len() + 64);
    for (i, line) in lines.iter().enumerate() {
        let line_no = (i + 1) as u32;
        if let Some(rep) = line_map.get(&line_no) {
            let (start, end, new_rhs, edit_id) = rep;
            let indent: String = line.chars().take_while(|c| c.is_whitespace()).collect();
            let start_line_txt = source_line(source, *start).unwrap_or("");
            let start_is_labels_only = is_case_label_only_line(start_line_txt);
            if line_no == *start && start_is_labels_only {
                // Keep `ROL:` / `ROR, RORI:` on its own line; rewrite the body next.
                out.push_str(line);
                out.push('\n');
            } else if line_no == *start
                || (start_is_labels_only && line_no == start + 1 && line_no <= *end)
            {
                // Body line (or same-line labels+assign): rewrite RHS, preserve prefix.
                let body_start = if start_is_labels_only && line_no != *start {
                    line_no
                } else {
                    *start
                };
                if let Some((lhs, _old_rhs, nba, _)) =
                    parse_assign_multiline(source, body_start, 6)
                {
                    let op = if nba { "<=" } else { "=" };
                    let case_prefix = case_item_label_prefix(line);
                    out.push_str(&indent);
                    out.push_str(&format!(
                        "{case_prefix}{lhs} {op} {new_rhs}; // sv-timing: BalanceMux/rebalance #{edit_id} RHS rewrite\n"
                    ));
                } else {
                    out.push_str(line);
                    out.push('\n');
                }
            } else if line_no <= *end {
                // Never comment out a pure case-label line — over-long multi-line
                // spans (max_extra expansion) must not swallow the next case item.
                if is_case_label_only_line(line) {
                    out.push_str(line);
                    out.push('\n');
                } else {
                    out.push_str(&indent);
                    out.push_str("// sv-timing: (RHS rewrite continuation removed) ");
                    out.push_str(line.trim());
                    out.push('\n');
                }
            } else {
                out.push_str(line);
                out.push('\n');
            }
        } else {
            out.push_str(line);
            out.push('\n');
        }
    }
    if !source.ends_with('\n') && out.ends_with('\n') {
        out.pop();
    }
    out
}

/// True when a source line is only case item labels (`ROL:` / `ROR, RORI:`) with no assign.
fn is_case_label_only_line(line: &str) -> bool {
    let t = strip_line_comment(line).trim();
    if t.is_empty() {
        return false;
    }
    // Ends with `:` and has no `=` on the line.
    if !t.ends_with(':') || t.contains('=') {
        return false;
    }
    let before = t.trim_end_matches(':').trim();
    looks_like_case_labels(before)
}

/// True when commenting-out `lines[idx]` would leave a bare `if/else` without a body.
fn needs_null_stmt_after_control(lines: &[&str], idx: usize) -> bool {
    // Walk upward past blanks/comments for a control-header line ending in `)`.
    let mut j = idx;
    while j > 0 {
        j -= 1;
        let t = strip_line_comment(lines[j]).trim();
        if t.is_empty() {
            continue;
        }
        if t.starts_with("//") {
            continue;
        }
        // Multi-line if condition: last line often just `)` or `) begin` is absent.
        let lower = t.to_ascii_lowercase();
        let is_if_header = lower.starts_with("if ")
            || lower.starts_with("if(")
            || lower.starts_with("else if")
            || lower == "else"
            || (t.ends_with(')') && !t.ends_with("begin") && !t.contains(';'));
        if is_if_header && !t.ends_with("begin") && !t.ends_with('{') {
            return true;
        }
        // Hit another statement — not a bare control body.
        return false;
    }
    false
}

/// Continuous assigns that drive original lhs from pipe Q (after decls).
pub fn sink_assigns_sv(cuts: &[CutAssign]) -> String {
    if cuts.is_empty() {
        return String::new();
    }
    let mut b = String::new();
    b.push_str("  // --- cut sinks: original lhs samples pipe Q (post-declare) ---\n");
    // One sink per non-empty lhs (first exclusive claim wins)
    let mut seen_lhs = std::collections::BTreeSet::new();
    for c in cuts {
        if c.lhs.is_empty() || c.line == 0 {
            continue; // chain-only cut
        }
        if !c.continuous {
            // Procedural origin kept in place — no module-scope continuous sink.
            continue;
        }
        if !seen_lhs.insert(c.lhs.clone()) {
            continue;
        }
        // Final safety: never emit case-label garbage as continuous assign.
        if c.lhs.contains(',') || c.lhs.contains(':') {
            continue;
        }
        // R12: genvar-indexed sinks (`fmt_uf_after_round[fmt]`) are illegal at module end.
        if has_free_gen_index(&c.lhs) {
            b.push_str(&format!(
                "  // R12: skip sink {} = {} (generate index in lhs)\n",
                c.lhs, c.pipe_name
            ));
            continue;
        }
        if !rhs_structurally_complete(&c.rhs) {
            // Incomplete feed — still sink lhs from pipe, comment incomplete was-
            b.push_str(&format!(
                "  assign {} = {}; // was (incomplete expr — feed in _c may be placeholder)\n",
                c.lhs, c.pipe_name
            ));
            continue;
        }
        b.push_str(&format!(
            "  assign {} = {}; // was ({})\n",
            c.lhs, c.pipe_name, c.rhs
        ));
    }
    b
}

/// Annotate edit records with feed metadata for JSON (optional display).
pub fn feed_notes_for_json(cuts: &[CutAssign]) -> Vec<serde_json::Value> {
    cuts.iter()
        .map(|c| {
            serde_json::json!({
                "edit_id": c.edit_id,
                "line": c.line,
                "lhs": c.lhs,
                "rhs": c.rhs,
                "pipe": c.pipe_name,
                "feed": format!("{}_c = {}", c.pipe_name, c.rhs),
            })
        })
        .collect()
}

/// True if any InsertReg still lacks a recoverable assign at origin (placeholder feed).
pub fn unresolved_insert_regs(trace: &EditTrace, cuts: &[CutAssign]) -> Vec<u32> {
    let resolved: std::collections::BTreeSet<u32> = cuts.iter().map(|c| c.edit_id).collect();
    trace
        .records
        .iter()
        .filter(|r| r.kind == EditKind::InsertReg && r.new_name.is_some())
        .filter(|r| !resolved.contains(&r.id))
        .map(|r| r.id)
        .collect()
}

/// Helper for tests: apply cuts for a single synthetic edit.
pub fn cut_from_record(source: &str, rec: &EditRecord) -> Option<CutAssign> {
    let mut t = EditTrace::new();
    t.record_edit(rec.clone());
    // record_edit overwrites id — restore
    if let Some(r) = t.records.last_mut() {
        r.id = rec.id;
    }
    cut_assigns_from_source(source, &t).into_iter().next()
}

/// Location helper for tests.
pub fn test_loc(file: &str, line: u32) -> SourceLoc {
    SourceLoc {
        file: file.into(),
        start_line: line,
        start_col: 1,
        end_line: line,
        end_col: 1,
        byte_start: 0,
        byte_end: 0,
        origin: sv_timing_core::OriginKind::UserFile,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sv_timing_transform::{EditKind, EditRecord, EditTrace};

    #[test]
    fn parse_blocking_and_nba() {
        let (l, r, nba) = parse_assign_line("    t1 = t0 + c_i;").unwrap();
        assert_eq!(l, "t1");
        assert_eq!(r, "t0 + c_i");
        assert!(!nba);
        let (l, r, nba) = parse_assign_line("      y_o <= acc;").unwrap();
        assert_eq!(l, "y_o");
        assert_eq!(r, "acc");
        assert!(nba);
    }

    #[test]
    fn parse_skips_compare() {
        assert!(parse_assign_line("    if (a == b) begin").is_none());
    }

    #[test]
    fn case_item_label_prefix_preserved() {
        let p = case_item_label_prefix("        ADDW, SUBW: result_o = adder_result;");
        assert!(p.contains("ADDW") && p.contains("SUBW") && p.contains(':'), "p={p}");
        assert!(case_item_label_prefix("        result_o = x;").is_empty());
    }

    #[test]
    fn parse_case_item_strips_labels() {
        let (l, r, nba) =
            parse_assign_line("        BCLR, BCLRI: result_o = operand_a & ~bit_indx;").unwrap();
        assert_eq!(l, "result_o");
        assert_eq!(r, "operand_a & ~bit_indx");
        assert!(!nba);
        let (l, r, _) = parse_assign_line("        ADD, SUB, ADDUW: result_o = adder_result;").unwrap();
        assert_eq!(l, "result_o");
        assert_eq!(r, "adder_result");
        // Sink must never look like case labels
        let cuts = [CutAssign {
            line: 10,
            end_line: 10,
            lhs: "result_o".into(),
            rhs: "adder_result".into(),
            nonblocking: false,
            pipe_name: "pipe_svt_p1".into(),
            edit_id: 0,
            continuous: true,
        }];
        let sinks = sink_assigns_sv(&cuts);
        assert!(sinks.contains("assign result_o = pipe_svt_p1"));
        assert!(!sinks.contains("assign ADD"));
    }

    #[test]
    fn multiline_case_ternary_complete() {
        let src = r#"
        unique case (op)
        CLZ, CTZ:
        result_o = (lz_tz_empty) ? ({{XLEN{1'b0}}, lz_tz_count} + 1)
            : {{XLEN{1'b0}}, lz_tz_count};
        endcase
"#;
        let (lhs, rhs, _, _) = parse_assign_multiline(src, 3, 4).unwrap();
        assert_eq!(lhs, "result_o");
        assert!(rhs_structurally_complete(&rhs), "rhs={rhs}");
        assert!(rhs.contains('?'));
        assert!(rhs.contains(':'));
    }

    #[test]
    fn incomplete_ternary_rejected() {
        assert!(!rhs_structurally_complete(
            "((lz_tz_empty) ? ({{XLEN{1'b0}}, lz_tz_count} + 1))"
        ));
    }

    #[test]
    fn trailing_binary_op_incomplete() {
        assert!(!rhs_structurally_complete(
            "{1'b0,total_qt_rt_30[28:4]} +"
        ));
        assert!(!rhs_structurally_complete(
            "((ex3_rst_eq_1) ? {3'b0,{23{1'b1}}} : {1'b0,total_qt_rt_30[28:4]} +)"
        ));
        assert!(rhs_structurally_complete(
            "(ex3_rst_eq_1) ? {3'b0,{23{1'b1}}} : {1'b0,total_qt_rt_30[28:4]} + 1'b1"
        ));
    }

    #[test]
    fn empty_false_arm_multiline_ternary_incomplete() {
        // exp_backoff mask_d after 2 of 3 lines — must keep scanning for mask_q.
        let partial = "(clr_i) ? '0 : (set_i) ? {{(WIDTH-MaxExp){1'b0}},mask_q[MaxExp-2:0], 1'b1} :";
        assert!(
            !rhs_structurally_complete(partial),
            "empty false arm must be incomplete"
        );
        let full = concat!(
            "(clr_i) ? '0 : (set_i) ? {{(WIDTH-MaxExp){1'b0}},mask_q[MaxExp-2:0], 1'b1} :",
            " mask_q"
        );
        assert!(rhs_structurally_complete(full), "full={full}");

        let src = r#"module m;
  assign mask_d = (clr_i) ? '0                                :
                  (set_i) ? {{(WIDTH-MaxExp){1'b0}},mask_q[MaxExp-2:0], 1'b1} :
                            mask_q;
endmodule
"#;
        let (lhs, rhs, _, end) = parse_assign_multiline(src, 2, 8).unwrap();
        assert_eq!(lhs, "mask_d");
        assert_eq!(end, 4, "must include mask_q arm");
        assert!(rhs.contains("mask_q"), "rhs={rhs}");
        assert!(rhs_structurally_complete(&rhs));
    }

    #[test]
    fn multiline_and_continuation_claims_end_line() {
        // instr_scan rvc_branch_o / rvc_return style
        let src = r#"module m;
  assign rvc_branch_o = ((instr_i[15:13] == riscv::OpcodeC1Beqz) | (instr_i[15:13] == riscv::OpcodeC1Bnez))
                        & (instr_i[1:0] == riscv::OpcodeC1);
  assign rvc_return_o = ((instr_i[11:7] == 5'd1) | (instr_i[11:7] == 5'd5)) & rvc_jr_o;
endmodule
"#;
        let (lhs, rhs, _, end) = parse_assign_multiline(src, 2, 4).unwrap();
        assert_eq!(lhs, "rvc_branch_o");
        assert_eq!(end, 3, "must include `& (instr_i[1:0]…)` continuation");
        assert!(rhs.contains("& (instr_i[1:0]"), "rhs={rhs}");
        assert!(rhs_structurally_complete(&rhs));

        let mut tr = EditTrace::new();
        tr.record_edit(EditRecord {
            id: 0,
            kind: EditKind::InsertReg,
            origin: test_loc("m.sv", 2),
            path_id: Some(0),
            node_id: Some(1),
            new_name: Some("pipe_svt_p1_1".into()),
            fo4_before: Some(20.0),
            fo4_after: Some(10.0),
            rationale: "cut".into(),
            emit_rhs: None,
            emit_rhs_extras: Vec::new(),
            emit_snippet: None,
        });
        let cuts = cut_assigns_from_source(src, &tr);
        assert_eq!(cuts.len(), 1);
        assert_eq!(cuts[0].end_line, 3);
        let rewritten = rewrite_origin_assigns(src, &cuts);
        assert!(
            !rewritten.lines().any(|l| {
                let t = l.trim();
                t.starts_with('&') && !t.starts_with("//")
            }),
            "continuation must be commented, got:\n{rewritten}"
        );
        assert!(rewritten.contains("continuation"));
    }

    #[test]
    fn incomplete_ternary_with_bit_selects_not_false_complete() {
        // Frontend instr_scan rvc_imm_o first line only — bit-select `:` must not
        // count as the ternary false-arm separator.
        let first = "(instr_i[14]) ? {{56+CVA6Cfg.VLEN-64{instr_i[12]}}, instr_i[6:5], instr_i[2], instr_i[11:10], instr_i[4:3], 1'b0}";
        assert!(
            !rhs_structurally_complete(first),
            "first line alone must be incomplete"
        );
        let full = concat!(
            "(instr_i[14]) ? {{56+CVA6Cfg.VLEN-64{instr_i[12]}}, instr_i[6:5], instr_i[2], instr_i[11:10], instr_i[4:3], 1'b0}",
            " : {{53+CVA6Cfg.VLEN-64{instr_i[12]}}, instr_i[8], instr_i[10:9], instr_i[6], instr_i[7], instr_i[2], instr_i[11], instr_i[5:3], 1'b0}"
        );
        assert!(rhs_structurally_complete(full), "full multi-line ternary");

        let src = r#"module m;
  assign rvc_imm_o    = (instr_i[14]) ? {{56+CVA6Cfg.VLEN-64{instr_i[12]}}, instr_i[6:5], instr_i[2], instr_i[11:10], instr_i[4:3], 1'b0}
                                       : {{53+CVA6Cfg.VLEN-64{instr_i[12]}}, instr_i[8], instr_i[10:9], instr_i[6], instr_i[7], instr_i[2], instr_i[11], instr_i[5:3], 1'b0};
endmodule
"#;
        let (lhs, rhs, _, end) = parse_assign_multiline(src, 2, 4).unwrap();
        assert_eq!(lhs, "rvc_imm_o");
        assert_eq!(end, 3, "must span both ternary arms");
        assert!(rhs_structurally_complete(&rhs), "rhs={rhs}");
        assert!(rhs.contains('?') && rhs.contains("instr_i[8]"));
    }

    #[test]
    fn parse_rejects_if_statement_as_assign() {
        assert!(parse_assign_line(
            "        if (fu_data_i.operation == SLLIUW && CVA6Cfg.IS_XLEN64) result_o = x;"
        )
        .is_none());
    }

    /// Multi-line continuous assign (multiplier-style `$signed(...) * $signed(...)`)
    /// must claim end_line and comment every continuation so reparse stays clean.
    #[test]
    fn multiline_signed_mul_rewrite_comments_continuations() {
        let src = r#"module m;
  assign mult_result_d = $signed(
      {operand_a_i[XLEN-1] & sign_a, operand_a_i}
  ) * $signed(
      {operand_b_i[XLEN-1] & sign_b, operand_b_i}
  );
  assign operator_d = operation_i;
endmodule
"#;
        let (lhs, rhs, nba, end) = parse_assign_multiline(src, 2, 6).unwrap();
        assert_eq!(lhs, "mult_result_d");
        assert!(!nba);
        assert_eq!(end, 6, "must span full multi-line assign");
        assert!(rhs_structurally_complete(&rhs), "rhs={rhs}");
        assert!(rhs.contains("$signed") && rhs.contains('*'));

        let mut tr = EditTrace::new();
        tr.record_edit(EditRecord {
            id: 0,
            kind: EditKind::InsertReg,
            origin: test_loc("m.sv", 2),
            path_id: Some(0),
            node_id: Some(1),
            new_name: Some("pipe_svt_p1_4".into()),
            fo4_before: Some(100.0),
            fo4_after: Some(40.0),
            rationale: "mul cut".into(),
            emit_rhs: None,
            emit_rhs_extras: Vec::new(),
            emit_snippet: None,
        });
        if let Some(r) = tr.records.last_mut() {
            r.id = 16;
        }
        let cuts = cut_assigns_from_source(src, &tr);
        assert_eq!(cuts.len(), 1);
        assert_eq!(cuts[0].end_line, 6);
        assert_eq!(cuts[0].lhs, "mult_result_d");
        let rewritten = rewrite_origin_assigns(src, &cuts);
        // No bare continuation tokens left live
        for line in rewritten.lines() {
            let t = line.trim();
            if t.starts_with("//") || t.is_empty() {
                continue;
            }
            assert!(
                !t.starts_with(") * $signed")
                    && !t.starts_with("{operand_a_i")
                    && !t.starts_with("{operand_b_i")
                    && t != ");",
                "orphan multi-line residue: {t}"
            );
        }
        assert!(rewritten.contains("moved mult_result_d"));
        assert!(rewritten.contains("continuation"));
        // Unrelated assign intact
        assert!(rewritten.contains("assign operator_d = operation_i;"));
        let sinks = sink_assigns_sv(&cuts);
        assert!(sinks.contains("assign mult_result_d = pipe_svt_p1_4"));
    }

    #[test]
    fn rewrite_deep_add_chain_line() {
        let src = include_str!("../../../fixtures/auto_correct/deep_add_chain.sv");
        let mut tr = EditTrace::new();
        tr.record_edit(EditRecord {
            id: 0,
            kind: EditKind::InsertReg,
            origin: test_loc("deep_add_chain.sv", 17), // t1 = t0 + c_i
            path_id: Some(0),
            node_id: Some(1),
            new_name: Some("t0_svt_p1".into()),
            fo4_before: Some(30.0),
            fo4_after: Some(15.0),
            rationale: "cut".into(),
            emit_rhs: None,
            emit_rhs_extras: Vec::new(),
            emit_snippet: None,
        });
        let cuts = cut_assigns_from_source(src, &tr);
        assert_eq!(cuts.len(), 1);
        assert_eq!(cuts[0].lhs, "t1");
        assert_eq!(cuts[0].rhs, "t0 + c_i");
        assert!(!cuts[0].continuous, "always_comb body is procedural");
        let rewritten = rewrite_origin_assigns(src, &cuts);
        // R12d: procedural origins kept; annotated only (no continuous sink).
        assert!(
            rewritten.contains("procedural origin kept") || rewritten.contains("t1 = t0 + c_i"),
            "{rewritten}"
        );
        assert!(rewritten.contains("t0 = a_i + b_i;")); // other lines intact
        let sinks = sink_assigns_sv(&cuts);
        assert!(
            !sinks.contains("assign t1 = t0_svt_p1"),
            "no continuous sink for procedural origin"
        );
    }

    #[test]
    fn multi_cut_unique_lines_then_chain() {
        let src = include_str!("../../../fixtures/auto_correct/deep_add_chain.sv");
        // Two edits claim the same origin line → first owns line, second chains.
        let mut tr = EditTrace::new();
        tr.record_edit(EditRecord {
            id: 0,
            kind: EditKind::InsertReg,
            origin: test_loc("deep_add_chain.sv", 18), // t2 = t1 + d_i
            path_id: Some(0),
            node_id: Some(1),
            new_name: Some("pipe_a".into()),
            fo4_before: Some(30.0),
            fo4_after: Some(15.0),
            rationale: "cut a".into(),
            emit_rhs: None,
            emit_rhs_extras: Vec::new(),
            emit_snippet: None,
        });
        tr.record_edit(EditRecord {
            id: 1,
            kind: EditKind::InsertReg,
            origin: test_loc("deep_add_chain.sv", 18), // same line
            path_id: Some(0),
            node_id: Some(2),
            new_name: Some("pipe_b".into()),
            fo4_before: Some(15.0),
            fo4_after: Some(8.0),
            rationale: "cut b".into(),
            emit_rhs: None,
            emit_rhs_extras: Vec::new(),
            emit_snippet: None,
        });
        // Force ids (record_edit renumbers)
        tr.records[0].id = 0;
        tr.records[1].id = 1;
        tr.records[0].new_name = Some("pipe_a".into());
        tr.records[1].new_name = Some("pipe_b".into());

        let cuts = cut_assigns_from_source(src, &tr);
        assert_eq!(cuts.len(), 2);
        // First: real assign on line 18 (or nearby distinct)
        assert_eq!(cuts[0].pipe_name, "pipe_a");
        assert!(cuts[0].line > 0, "first cut should own a source line");
        assert!(!cuts[0].rhs.is_empty());
        // Second: either nearby distinct assign or chain from pipe_a
        assert_eq!(cuts[1].pipe_name, "pipe_b");
        if cuts[1].line == 0 {
            assert_eq!(cuts[1].rhs, "pipe_a", "chain feed must be previous pipe");
            assert!(cuts[1].lhs.is_empty());
        } else {
            assert_ne!(
                cuts[1].line, cuts[0].line,
                "nearby claim must be a different line"
            );
            assert_ne!(cuts[1].lhs, cuts[0].lhs);
        }
        // Procedural origins: kept with note (R12d lean).
        let rewritten = rewrite_origin_assigns(src, &cuts);
        let notes = rewritten.matches("procedural origin kept").count()
            + rewritten.matches("moved ").count();
        assert!(notes >= 1, "expected cut annotation, got:\n{rewritten}");
    }

    #[test]
    fn multi_cut_nearby_distinct_assigns() {
        let src = include_str!("../../../fixtures/auto_correct/deep_add_chain.sv");
        let mut tr = EditTrace::new();
        // Origins on consecutive assign lines → two exclusive claims
        for (id, line, name) in [
            (0u32, 16u32, "p0"),
            (1, 17, "p1"),
            (2, 18, "p2"),
        ] {
            tr.record_edit(EditRecord {
                id,
                kind: EditKind::InsertReg,
                origin: test_loc("deep_add_chain.sv", line),
                path_id: Some(0),
                node_id: Some(id),
                new_name: Some(name.into()),
                fo4_before: Some(20.0),
                fo4_after: Some(10.0),
                rationale: "cut".into(),
                emit_rhs: None,
                emit_rhs_extras: Vec::new(),
                emit_snippet: None,
            });
        }
        for (i, r) in tr.records.iter_mut().enumerate() {
            r.id = i as u32;
            r.new_name = Some(format!("p{i}"));
            r.origin.start_line = 16 + i as u32;
        }
        let cuts = cut_assigns_from_source(src, &tr);
        assert_eq!(cuts.len(), 3);
        let lines: Vec<u32> = cuts.iter().map(|c| c.line).collect();
        assert_eq!(lines, vec![16, 17, 18]);
        let rhss: Vec<&str> = cuts.iter().map(|c| c.rhs.as_str()).collect();
        assert_eq!(rhss[0], "a_i + b_i");
        assert_eq!(rhss[1], "t0 + c_i");
        assert_eq!(rhss[2], "t1 + d_i");
        // Procedural always_comb origins → no continuous sinks (R12d).
        let sinks = sink_assigns_sv(&cuts);
        assert!(
            !sinks.contains("assign t0 = p0"),
            "procedural origins must not get continuous sinks"
        );
        assert!(cuts.iter().all(|c| !c.continuous));
    }
}
