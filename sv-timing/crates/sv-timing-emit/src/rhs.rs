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

/// True when RHS still contains another `ident =` at depth 0.
///
/// HPDcache AMO uses comma-separated continuous assigns:
/// `assign ugt = (a > b), sgt = (c > d), sum = c + d;`
/// Recovering from the `sgt` line yields rhs `(c > d), sum = c + d`. Rewriting
/// that as `sgt = pipe` / `assign pipe_c = (…, sum = …)` is illegal SV
/// (`audit-remain-v37-full-core` hpdcache_amo parse).
fn rhs_is_comma_assign_list(rhs: &str) -> bool {
    let b = rhs.as_bytes();
    let mut depth = 0i32;
    let mut i = 0usize;
    while i < b.len() {
        match b[i] {
            b'(' | b'{' | b'[' => depth += 1,
            b')' | b'}' | b']' => depth = (depth - 1).max(0),
            b',' if depth == 0 => {
                let rest = rhs[i + 1..].trim_start();
                if let Some((lhs, _, _)) = parse_assign_line(rest) {
                    if !lhs.is_empty() {
                        return true;
                    }
                }
                // `ident =` even without a leading `assign`.
                let ident: String = rest
                    .chars()
                    .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
                    .collect();
                let after = rest[ident.len()..].trim_start();
                if !ident.is_empty() && after.starts_with('=') && !after.starts_with("==") {
                    return true;
                }
            }
            _ => {}
        }
        i += 1;
    }
    false
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

fn line_looks_like_assign(source: &str, line: u32) -> bool {
    if line_is_continuous_assign(source, line) {
        return true;
    }
    let Some(raw) = source_line(source, line) else {
        return false;
    };
    parse_assign_line(raw).is_some()
}

/// Pin rewrite to a real assign in `[start, end]` and detect `assign`.
///
/// IR origin can land on a blank/`end` line immediately before a continuous
/// `assign` (`instr_queue` `idx_is_d`, `te_branch_map` `map_o`). Treating that
/// as procedural emits illegal module-scope `lhs = pipe` (audit-gemm-expol5).
fn cut_rewrite_anchor(source: &str, start: u32, end: u32) -> (u32, bool) {
    let end = end.max(start);
    let continuous = (start..=end).any(|ln| line_is_continuous_assign(source, ln));
    let line = (start..=end)
        .find(|&ln| line_looks_like_assign(source, ln))
        .unwrap_or(start);
    (line, continuous)
}

/// Base identifier of an lvalue (`foo[3:0]` → `foo`, `pkg::x` → last segment).
fn lhs_base_ident(lhs: &str) -> &str {
    let s = lhs.trim();
    let s = s.split('[').next().unwrap_or(s).trim();
    s.rsplit("::").next().unwrap_or(s).trim()
}

fn norm_expr(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// True when rewriting this procedural line to `lhs = pipe` would drop `if`/`for`.
fn procedural_cut_is_unsafe(line: &str, lhs: &str) -> bool {
    if has_free_gen_index(lhs) {
        return true;
    }
    let t = strip_line_comment(line).trim();
    let t = strip_case_item_labels(t).trim();
    let lower = t.to_ascii_lowercase();
    lower.starts_with("if ")
        || lower.starts_with("if(")
        || lower.starts_with("else")
        || lower.starts_with("for ")
        || lower.starts_with("for(")
        || lower.starts_with("while ")
        || lower.starts_with("while(")
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

/// 1-based start line of the `always_*` / `assign` that contains `origin_line`.
///
/// BalanceMux wires must be injected here (not at the module's first process):
/// gemm declares `pe_float_en` after an early `always_comb`, and the hot NBA
/// lives in a later `always_ff` (`audit-remain-v21b` demoted the snippet).
pub fn enclosing_process_start_line(source: &str, origin_line: u32) -> u32 {
    if origin_line == 0 {
        return 1;
    }
    let mut last_proc = origin_line;
    for (i, raw) in source.lines().enumerate() {
        let ln = (i + 1) as u32;
        let t = strip_line_comment(raw).trim();
        let lower = t.to_ascii_lowercase();
        if lower.starts_with("always_comb")
            || lower.starts_with("always_ff")
            || lower.starts_with("always_latch")
            || lower.starts_with("always ")
            || lower.starts_with("always@")
            || lower.starts_with("always @")
            || lower.starts_with("assign ")
            || lower.starts_with("assign\t")
        {
            last_proc = ln;
        }
        if ln == origin_line {
            return last_proc;
        }
    }
    origin_line
}

fn line_to_byte_offset(source: &str, line: u32) -> usize {
    let mut off = 0usize;
    for (i, l) in source.lines().enumerate() {
        if (i + 1) as u32 >= line.max(1) {
            return off;
        }
        off += l.len() + 1;
    }
    off
}

/// Unified R12 gate: snippet is safe to inject at the origin process **and**
/// to use for origin RHS rewrite. Keep demotion and rewrite in lockstep.
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
    let inject_at = enclosing_process_start_line(source, origin_line);
    if snippet_refs_late_declared_local(source, t, inject_at) {
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

/// True when snippet references idents declared only after `inject_before_line`.
///
/// Shared with dense inject demotion so BalanceMux RHS rewrite and snippet
/// inject stay aligned (R12). `inject_before_line` is the enclosing process
/// of the origin (not the module's first process).
pub fn snippet_refs_late_declared_local(
    source: &str,
    snippet: &str,
    inject_before_line: u32,
) -> bool {
    let inject_off = line_to_byte_offset(source, inject_before_line.max(1));
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
                    if toks.iter().any(|tok| *tok == id) && off >= inject_off {
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
                if rhs_structurally_complete(&rhs)
                    && !rhs_is_comma_assign_list(&rhs)
                    && lhs_ok
                    && !claimed_lhs.contains(&lhs)
                {
                    for ln in origin_line..=end {
                        claimed_lines.insert(ln);
                    }
                    claimed_lhs.insert(lhs.clone());
                    let (line, continuous) = cut_rewrite_anchor(source, origin_line, end);
                    claimed = Some(CutAssign {
                        line,
                        end_line: end,
                        lhs,
                        rhs,
                        nonblocking: nba,
                        pipe_name: pipe.clone(),
                        edit_id: r.id,
                        continuous,
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
                if !rhs_structurally_complete(&rhs) || rhs_is_comma_assign_list(&rhs) {
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
                let (line, continuous) = cut_rewrite_anchor(source, line_no, end);
                claimed = Some(CutAssign {
                    line,
                    end_line: end,
                    lhs,
                    rhs,
                    nonblocking: nba,
                    pipe_name: pipe.clone(),
                    edit_id: r.id,
                    continuous,
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

/// LHS ident is a generate-if span/end role (`a_span`, `b_end`).
///
/// KD0: suffix only. Twin copy (identical LHS **and** RHS) is separate;
/// this names the leftover geometry that needs its own pipe.
fn lhs_is_span_family_ident(lhs: &str) -> bool {
    let base = lhs_base_ident(lhs);
    let base = base.rsplit('.').next().unwrap_or(base);
    base.ends_with("_span") || base.ends_with("_end")
}

fn lex_sv_line_tokens(t: &str) -> Vec<String> {
    let mut out = Vec::new();
    let b = t.as_bytes();
    let mut i = 0usize;
    while i < b.len() {
        let c = b[i] as char;
        if c.is_ascii_whitespace() {
            i += 1;
            continue;
        }
        if c.is_ascii_alphabetic() || c == '_' {
            let s = i;
            i += 1;
            while i < b.len() {
                let d = b[i] as char;
                if d.is_ascii_alphanumeric() || d == '_' {
                    i += 1;
                } else {
                    break;
                }
            }
            out.push(t[s..i].to_string());
            continue;
        }
        out.push(c.to_string());
        i += 1;
    }
    out
}

fn tok_is(tok: &str, kw: &str) -> bool {
    tok.eq_ignore_ascii_case(kw)
}

/// Named `if` / `else` generate-if ranges (`if (En) begin : gen_reuse_a`).
///
/// Keyword `generate`/`endgenerate` is **not** required (CVA6-style implicit
/// generate). Used to pair sibling span/end assigns that twin-copy cannot
/// share a pipe with because their RHS differ.
fn named_generate_if_blocks(source: &str) -> Vec<(u32, u32, String)> {
    let mut blocks = Vec::new();
    let mut stack: Vec<(String, u32, i32)> = Vec::new(); // name, start, depth after begin
    let mut depth: i32 = 0;
    let mut pending_if = false;
    for (i, raw) in source.lines().enumerate() {
        let ln = (i + 1) as u32;
        let t = strip_line_comment(raw).trim();
        if t.is_empty() {
            continue;
        }
        let toks = lex_sv_line_tokens(t);
        let mut j = 0usize;
        while j < toks.len() {
            let tok = &toks[j];
            if tok_is(tok, "if") || tok_is(tok, "else") {
                pending_if = true;
                j += 1;
                continue;
            }
            if tok_is(tok, "begin") {
                depth += 1;
                let mut name: Option<String> = None;
                if j + 2 < toks.len() && toks[j + 1] == ":" {
                    let n = &toks[j + 2];
                    if n.chars().next().is_some_and(|c| c.is_ascii_alphabetic() || c == '_') {
                        name = Some(n.clone());
                    }
                }
                if pending_if {
                    if let Some(n) = name {
                        stack.push((n, ln, depth));
                    }
                    pending_if = false;
                }
                j += 1;
                continue;
            }
            if tok_is(tok, "end") {
                depth = (depth - 1).max(0);
                while stack.last().is_some_and(|s| s.2 > depth) {
                    let (n, start, _) = stack.pop().unwrap();
                    blocks.push((start, ln, n));
                }
                j += 1;
                continue;
            }
            if tok == ";" {
                pending_if = false;
            }
            j += 1;
        }
        if t.ends_with(';') && !t.to_ascii_lowercase().contains("begin") {
            pending_if = false;
        }
    }
    blocks
}

fn line_in_named_if(blocks: &[(u32, u32, String)], line: u32) -> bool {
    blocks.iter().any(|(s, e, _)| line >= *s && line <= *e)
}

fn sanitize_pipe_ident(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        if c.is_ascii_alphanumeric() || c == '_' {
            out.push(c);
        } else {
            out.push('_');
        }
    }
    if out.is_empty() {
        "x".into()
    } else {
        out
    }
}

/// Split `fat * … + tail` at the last depth-0 `+` so the sibling extra can
/// use a prep pipe (mux/shift/mul) then an add pipe (AddSub = budget).
///
/// gemm leftover after A: `32'(n-1) * fmt_row_bytes(…) + k_bytes` is Mux 2.5
/// + AddSub 10 = 12.5 in one feed. `{1'b0, pa_q} + span` has no `*` on the
/// left and is left as a single add (already 10).
fn is_simple_ident(s: &str) -> bool {
    let s = s.trim();
    if s.is_empty() {
        return false;
    }
    let mut chars = s.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    if !(first.is_ascii_alphabetic() || first == '_') {
        return false;
    }
    chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// Ports / flop Qs are already sequential; combo helpers like `k_bytes` are not.
fn ident_already_sequential(s: &str) -> bool {
    let s = s.trim();
    s.ends_with("_q")
        || s.ends_with("_i")
        || s.ends_with("_n")
        || s.ends_with("_d")
        || s.ends_with("_qi")
}

fn split_trailing_star_add(rhs: &str) -> Option<(String, String)> {
    let t = rhs.trim();
    // One layer of wrapping parens so `(A * B + C)` still splits.
    let s = if t.starts_with('(') && t.ends_with(')') {
        let inner = t[1..t.len() - 1].trim();
        if rhs_structurally_complete(inner) {
            inner
        } else {
            t
        }
    } else {
        t
    };
    let b = s.as_bytes();
    let mut depth = 0i32;
    let mut last_plus: Option<usize> = None;
    let mut i = 0usize;
    while i < b.len() {
        match b[i] {
            b'(' | b'{' | b'[' => depth += 1,
            b')' | b'}' | b']' => depth = (depth - 1).max(0),
            b'+' if depth == 0 => last_plus = Some(i),
            _ => {}
        }
        i += 1;
    }
    let idx = last_plus?;
    let left = s[..idx].trim();
    let right = s[idx + 1..].trim().trim_end_matches(';').trim();
    if left.is_empty() || right.is_empty() {
        return None;
    }
    if !left.contains('*') {
        return None;
    }
    if !rhs_structurally_complete(left) || !rhs_structurally_complete(right) {
        return None;
    }
    Some((left.to_string(), right.to_string()))
}

fn subst_ident_tokens(text: &str, map: &std::collections::BTreeMap<String, String>) -> String {
    if map.is_empty() {
        return text.to_string();
    }
    let mut out = String::with_capacity(text.len() + 8);
    let b = text.as_bytes();
    let mut i = 0usize;
    while i < b.len() {
        let c = b[i] as char;
        if c.is_ascii_alphabetic() || c == '_' {
            let s = i;
            i += 1;
            while i < b.len() {
                let d = b[i] as char;
                if d.is_ascii_alphanumeric() || d == '_' {
                    i += 1;
                } else {
                    break;
                }
            }
            let tok = &text[s..i];
            if let Some(rep) = map.get(tok) {
                out.push_str(rep);
            } else {
                out.push_str(tok);
            }
        } else {
            out.push(c);
            i += 1;
        }
    }
    out
}

/// Extra InsertReg cuts for uncut sibling generate-if `*_span`/`*_end` assigns.
///
/// Twin copy requires identical LHS **and** RHS (`c_span` twins). gemm
/// `a_span`/`b_span` have different RHS (`m`/`lda` vs `n`/`ldb`) and are not
/// IR paths during correct, so S4 never sees them. When a span-family cut
/// already exists inside a named generate-if, rewrite the uncut siblings in
/// those named blocks onto **their own** pipes (not a shared twin pipe).
///
/// Origin rewrite is in-place (`assign lhs = extra_pipe`); dense feeds use
/// the original RHS. Cap 8. Does not re-cut a seed LHS (`c_span`/`c_end`).
pub fn sibling_span_extra_cuts(source: &str, cuts: &[CutAssign]) -> Vec<CutAssign> {
    const CAP: usize = 8;
    let seeds: Vec<&CutAssign> = cuts
        .iter()
        .filter(|c| {
            c.continuous && c.line > 0 && !c.lhs.is_empty() && lhs_is_span_family_ident(&c.lhs)
        })
        .collect();
    if seeds.is_empty() {
        return Vec::new();
    }
    let blocks = named_generate_if_blocks(source);
    if blocks.is_empty() {
        return Vec::new();
    }
    let seed_in_named = seeds
        .iter()
        .any(|c| (c.line..=c.end_line.max(c.line)).any(|ln| line_in_named_if(&blocks, ln)));
    if !seed_in_named {
        return Vec::new();
    }

    let seed_lhs: std::collections::BTreeSet<String> = seeds
        .iter()
        .map(|c| lhs_base_ident(&c.lhs).to_string())
        .collect();
    let mut claimed_lines: std::collections::BTreeSet<u32> = std::collections::BTreeSet::new();
    for c in cuts.iter().filter(|c| c.line > 0) {
        for ln in c.line..=c.end_line.max(c.line) {
            claimed_lines.insert(ln);
        }
    }
    let mut used_pipes: std::collections::BTreeSet<String> =
        cuts.iter().map(|c| c.pipe_name.clone()).collect();
    let line_count = source.lines().count() as u32;

    let mut found: Vec<(u32, u32, String, String)> = Vec::new(); // line, end, lhs, rhs
    let mut seen_lhs: std::collections::BTreeSet<String> = seed_lhs.clone();
    for ln in 1..=line_count {
        if claimed_lines.contains(&ln) {
            continue;
        }
        if !line_is_continuous_assign(source, ln) {
            continue;
        }
        if !line_in_named_if(&blocks, ln) {
            continue;
        }
        let Some((lhs, rhs, _, end)) = parse_assign_multiline(source, ln, 8) else {
            continue;
        };
        if !lhs_is_span_family_ident(&lhs) {
            continue;
        }
        let base = lhs_base_ident(&lhs).to_string();
        if seed_lhs.contains(&base) || seen_lhs.contains(&base) {
            continue;
        }
        if has_free_gen_index(&lhs) || !lhs_is_module_level_net(source, &lhs) {
            continue;
        }
        if !rhs_structurally_complete(&rhs) {
            continue;
        }
        seen_lhs.insert(base);
        for n in ln..=end.max(ln) {
            claimed_lines.insert(n);
        }
        found.push((ln, end.max(ln), lhs, rhs));
    }
    // `_span` before `_end` so end feeds can sample the sibling span pipe.
    found.sort_by(|a, b| {
        let a_span = lhs_base_ident(&a.2).ends_with("_span");
        let b_span = lhs_base_ident(&b.2).ends_with("_span");
        b_span.cmp(&a_span).then(a.0.cmp(&b.0))
    });

    let mut pipe_by_lhs: std::collections::BTreeMap<String, String> = std::collections::BTreeMap::new();
    for c in &seeds {
        pipe_by_lhs.insert(lhs_base_ident(&c.lhs).to_string(), c.pipe_name.clone());
    }
    let mut out = Vec::new();
    for (line, end_line, lhs, rhs) in found {
        if out.len() >= CAP {
            break;
        }
        let base = lhs_base_ident(&lhs).to_string();
        let mut pipe = format!("pipe_svt_sib_{}_{}", sanitize_pipe_ident(&base), line);
        let mut n = 2u32;
        while used_pipes.contains(&pipe) {
            pipe = format!(
                "pipe_svt_sib_{}_{}_{}",
                sanitize_pipe_ident(&base),
                line,
                n
            );
            n += 1;
        }
        used_pipes.insert(pipe.clone());
        let feed = subst_ident_tokens(&rhs, &pipe_by_lhs);
        if let Some((left, right)) = split_trailing_star_add(&feed) {
            let mut prep = format!("{pipe}_p");
            let mut n = 2u32;
            while used_pipes.contains(&prep) {
                prep = format!("{pipe}_p{n}");
                n += 1;
            }
            used_pipes.insert(prep.clone());
            out.push(CutAssign {
                line: 0,
                end_line: 0,
                lhs: String::new(),
                rhs: left,
                nonblocking: false,
                pipe_name: prep.clone(),
                edit_id: 10_000 + out.len() as u32,
                continuous: false,
            });
            // Combo tails (`k_bytes = fmt_row_bytes(k_q)`) are Mux 2.5; adding
            // them to prep Q is 12.5. Sample the ident so the add is Q+Q = 10.
            let add_rhs = if is_simple_ident(&right) && !ident_already_sequential(&right) {
                let mut tail = format!("{pipe}_t");
                let mut n = 2u32;
                while used_pipes.contains(&tail) {
                    tail = format!("{pipe}_t{n}");
                    n += 1;
                }
                used_pipes.insert(tail.clone());
                out.push(CutAssign {
                    line: 0,
                    end_line: 0,
                    lhs: String::new(),
                    rhs: right.clone(),
                    nonblocking: false,
                    pipe_name: tail.clone(),
                    edit_id: 10_000 + out.len() as u32,
                    continuous: false,
                });
                format!("{prep} + {tail}")
            } else {
                format!("{prep} + {right}")
            };
            pipe_by_lhs.insert(base, pipe.clone());
            out.push(CutAssign {
                line,
                end_line,
                lhs,
                rhs: add_rhs,
                nonblocking: false,
                pipe_name: pipe,
                edit_id: 10_000 + out.len() as u32,
                continuous: true,
            });
        } else {
            pipe_by_lhs.insert(base, pipe.clone());
            out.push(CutAssign {
                line,
                end_line,
                lhs,
                rhs: feed,
                nonblocking: false,
                pipe_name: pipe,
                edit_id: 10_000 + out.len() as u32,
                continuous: true,
            });
        }
    }
    out
}

fn ident_tokens_in(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let b = text.as_bytes();
    let mut i = 0usize;
    while i < b.len() {
        let c = b[i] as char;
        if c.is_ascii_alphabetic() || c == '_' {
            let s = i;
            i += 1;
            while i < b.len() {
                let d = b[i] as char;
                if d.is_ascii_alphanumeric() || d == '_' {
                    i += 1;
                } else {
                    break;
                }
            }
            out.push(text[s..i].to_string());
            continue;
        }
        i += 1;
    }
    out
}

fn collect_continuous_assigns(
    source: &str,
) -> std::collections::BTreeMap<String, (u32, u32, String)> {
    let mut map = std::collections::BTreeMap::new();
    let line_count = source.lines().count() as u32;
    let mut claimed = std::collections::BTreeSet::new();
    for ln in 1..=line_count {
        if claimed.contains(&ln) || !line_is_continuous_assign(source, ln) {
            continue;
        }
        let Some((lhs, rhs, _, end)) = parse_assign_multiline(source, ln, 8) else {
            continue;
        };
        let base = lhs_base_ident(&lhs).to_string();
        if base.is_empty() || map.contains_key(&base) {
            continue;
        }
        for n in ln..=end.max(ln) {
            claimed.insert(n);
        }
        map.insert(base, (ln, end.max(ln), rhs));
    }
    map
}

/// Uncut combo assign sandwiched between two InsertReg cuts (VII.E).
///
/// `instr_queue` leftover: `lo_partial` and `push_instr_fifo` are cut,
/// `push_instr` in between is live and becomes the 15.5 feed into the
/// fifo pipe. Extra-cut that sandwich and one hop of its combo producers
/// (`fifo_pos`, `instr_overflow`, `slot0_pos`) so the remainder feed is
/// a mux of pipe Qs, not a 9-node cone. In-place rewrite; does not recut
/// claimed lines (F2). Cap 4. Span-family leftovers stay with sibling extras.
pub fn remainder_sandwich_extra_cuts(source: &str, cuts: &[CutAssign]) -> Vec<CutAssign> {
    const CAP: usize = 4;
    let cut_lhs: std::collections::BTreeSet<String> = cuts
        .iter()
        .filter(|c| !c.lhs.is_empty())
        .map(|c| lhs_base_ident(&c.lhs).to_string())
        .collect();
    if cut_lhs.is_empty() {
        return Vec::new();
    }
    let assigns = collect_continuous_assigns(source);
    let mut claimed_lines: std::collections::BTreeSet<u32> = std::collections::BTreeSet::new();
    for c in cuts.iter().filter(|c| c.line > 0) {
        for ln in c.line..=c.end_line.max(c.line) {
            claimed_lines.insert(ln);
        }
    }
    let mut used_pipes: std::collections::BTreeSet<String> =
        cuts.iter().map(|c| c.pipe_name.clone()).collect();
    let mut claimed_lhs = cut_lhs.clone();

    let mut sandwiches: Vec<(String, u32, u32, String)> = Vec::new();
    for c in cuts {
        if c.rhs.is_empty() {
            continue;
        }
        for tok in ident_tokens_in(&c.rhs) {
            if claimed_lhs.contains(&tok) || lhs_is_span_family_ident(&tok) {
                continue;
            }
            if ident_already_sequential(&tok) {
                continue;
            }
            let Some((line, end, rhs)) = assigns.get(&tok) else {
                continue;
            };
            if claimed_lines.contains(line) || line_inside_generate(source, *line) {
                continue;
            }
            if !ident_tokens_in(rhs).iter().any(|t| cut_lhs.contains(t)) {
                continue;
            }
            if has_free_gen_index(&tok) || !lhs_is_module_level_net(source, &tok) {
                continue;
            }
            if !rhs_structurally_complete(rhs) {
                continue;
            }
            claimed_lhs.insert(tok.clone());
            sandwiches.push((tok, *line, *end, rhs.clone()));
        }
    }

    // Hop-2: combo producers on a sandwich RHS (fifo_pos / instr_overflow).
    let mut hop2: Vec<(String, u32, u32, String)> = Vec::new();
    for (_, _, _, rhs) in &sandwiches {
        for tok in ident_tokens_in(rhs) {
            if claimed_lhs.contains(&tok) || lhs_is_span_family_ident(&tok) {
                continue;
            }
            if ident_already_sequential(&tok) {
                continue;
            }
            let Some((line, end, prod_rhs)) = assigns.get(&tok) else {
                continue;
            };
            if claimed_lines.contains(line) || line_inside_generate(source, *line) {
                continue;
            }
            if has_free_gen_index(&tok) || !lhs_is_module_level_net(source, &tok) {
                continue;
            }
            if !rhs_structurally_complete(prod_rhs) {
                continue;
            }
            claimed_lhs.insert(tok.clone());
            hop2.push((tok, *line, *end, prod_rhs.clone()));
        }
    }

    let mut pipe_by_lhs: std::collections::BTreeMap<String, String> = cuts
        .iter()
        .filter(|c| !c.lhs.is_empty())
        .map(|c| (lhs_base_ident(&c.lhs).to_string(), c.pipe_name.clone()))
        .collect();
    let mut out = Vec::new();
    for (lhs, line, end_line, rhs) in hop2.into_iter().chain(sandwiches.into_iter()) {
        if out.len() >= CAP {
            break;
        }
        let mut pipe = format!("pipe_svt_rem_{}_{}", sanitize_pipe_ident(&lhs), line);
        let mut n = 2u32;
        while used_pipes.contains(&pipe) {
            pipe = format!(
                "pipe_svt_rem_{}_{}_{}",
                sanitize_pipe_ident(&lhs),
                line,
                n
            );
            n += 1;
        }
        used_pipes.insert(pipe.clone());
        let feed = subst_ident_tokens(&rhs, &pipe_by_lhs);
        pipe_by_lhs.insert(lhs.clone(), pipe.clone());
        for n in line..=end_line {
            claimed_lines.insert(n);
        }
        out.push(CutAssign {
            line,
            end_line,
            lhs,
            rhs: feed,
            nonblocking: false,
            pipe_name: pipe,
            edit_id: 20_000 + out.len() as u32,
            continuous: true,
        });
    }
    out
}

/// Count `&&` / `||` (not bitwise `&` / `|`).
fn count_bool_binops(rhs: &str) -> usize {
    let b = rhs.as_bytes();
    let mut n = 0usize;
    let mut i = 0usize;
    while i + 1 < b.len() {
        if (b[i] == b'&' && b[i + 1] == b'&') || (b[i] == b'|' && b[i + 1] == b'|') {
            n += 1;
            i += 2;
            continue;
        }
        i += 1;
    }
    n
}

/// True when `rhs[i]` is unary `|` (`|vec`), not bitwise `a | b` or `||`.
///
/// `|| |is_branch` (space before unary `|`) is unary. `cache_wren | inv_en`
/// is binary — the previous non-ws is an ident. v40 treated the latter as
/// three reduces and deleted the `|` operators (`vld_we` / `if_ready`).
fn is_unary_or_bar(b: &[u8], i: usize) -> bool {
    if i + 1 < b.len() && b[i + 1] == b'|' {
        return false;
    }
    if i > 0 && b[i - 1] == b'|' {
        return false;
    }
    let mut k = i;
    while k > 0 {
        k -= 1;
        if (b[k] as char).is_ascii_whitespace() {
            continue;
        }
        let ch = b[k] as char;
        if ch == '|' && k > 0 && b[k - 1] == b'|' {
            return true;
        }
        if ch.is_ascii_alphanumeric() || ch == '_' || ch == ')' || ch == ']' || ch == '}' || ch == '\''
        {
            return false;
        }
        return true;
    }
    true
}

/// Unary or-reductions `|ident` in `rhs` (not `||`, not bitwise `|`).
fn unary_or_reduces(rhs: &str) -> Vec<(usize, usize, String)> {
    let b = rhs.as_bytes();
    let mut out = Vec::new();
    let mut i = 0usize;
    while i < b.len() {
        if b[i] == b'|' && is_unary_or_bar(b, i) && i + 1 < b.len() {
            let mut j = i + 1;
            while j < b.len() && (b[j] as char).is_ascii_whitespace() {
                j += 1;
            }
            if j < b.len() {
                let c = b[j] as char;
                if c.is_ascii_alphabetic() || c == '_' {
                    let s = j;
                    j += 1;
                    while j < b.len() {
                        let d = b[j] as char;
                        if d.is_ascii_alphanumeric() || d == '_' {
                            j += 1;
                        } else {
                            break;
                        }
                    }
                    out.push((i, j, rhs[s..j].to_string()));
                    i = j;
                    continue;
                }
            }
        }
        i += 1;
    }
    out
}

/// Prep pipes for `|vec` reductions in a mixed boolean cone.
///
/// Frontend 13: `spec_d = (q && !r || |is_branch || |is_return || |is_jalr) && !f`
/// (several 1-bit reduces). wt_dcache 12: `fixup_rd_req = (st==PEND) && !hit
/// && !(|tocheck) && !en_q && !en_q1` (one reduce in a wide AND). Pipelining
/// the 1-bit reduce (not the `_d` / req itself) leaves Q-logic under budget.
/// Needs ≥2 `&&`/`||` when there is only one reduce so a handshake
/// `assign req_o = |vec && ack` is not extra-cycled. Cap 4 reduces / assign,
/// 4 assigns / file. Skip `_o` ports and `[i]` lvalues.
pub fn or_reduce_prep_cuts(
    source: &str,
    cuts: &[CutAssign],
) -> (Vec<CutAssign>, std::collections::BTreeMap<u32, (String, String)>) {
    const ASSIGN_CAP: usize = 4;
    let mut preps = Vec::new();
    let mut rewrites: std::collections::BTreeMap<u32, (String, String)> =
        std::collections::BTreeMap::new();
    let mut claimed: std::collections::BTreeSet<u32> = cuts
        .iter()
        .filter(|c| c.line > 0)
        .flat_map(|c| c.line..=c.end_line.max(c.line))
        .collect();
    let mut used: std::collections::BTreeSet<String> =
        cuts.iter().map(|c| c.pipe_name.clone()).collect();
    let mut n_assigns = 0usize;
    let line_count = source.lines().count() as u32;
    for ln in 1..=line_count {
        if n_assigns >= ASSIGN_CAP {
            break;
        }
        if claimed.contains(&ln) || !line_is_continuous_assign(source, ln) {
            continue;
        }
        let Some((lhs, rhs, _, end)) = parse_assign_multiline(source, ln, 8) else {
            continue;
        };
        let base = lhs_base_ident(&lhs);
        // Generate-if locals (wt_dcache `gen_fixup_queue`) may sample a
        // module-scope 1-bit reduce pipe. Skip generate-for `[i]` lvalues.
        if base.ends_with("_o") || has_free_gen_index(&lhs) || lhs.contains('[') {
            continue;
        }
        if rhs_is_comma_assign_list(&rhs) {
            continue;
        }
        let reduces = unary_or_reduces(&rhs);
        if reduces.is_empty() {
            continue;
        }
        if reduces.len() < 2 && count_bool_binops(&rhs) < 2 {
            continue;
        }
        if reduces
            .iter()
            .any(|(_, _, ident)| !lhs_is_module_level_net(source, ident) || has_free_gen_index(ident))
        {
            continue;
        }
        let mut new_rhs = rhs.clone();
        // Replace from the end so offsets stay valid.
        for (start, stop, ident) in reduces.iter().rev().take(4) {
            let mut pipe = format!("pipe_svt_red_{}_{}", sanitize_pipe_ident(ident), ln);
            let mut n = 2u32;
            while used.contains(&pipe) {
                pipe = format!(
                    "pipe_svt_red_{}_{}_{}",
                    sanitize_pipe_ident(ident),
                    ln,
                    n
                );
                n += 1;
            }
            used.insert(pipe.clone());
            preps.push(CutAssign {
                line: 0,
                end_line: 0,
                lhs: String::new(),
                rhs: format!("|{ident}"),
                nonblocking: false,
                pipe_name: pipe.clone(),
                edit_id: 30_000 + preps.len() as u32,
                continuous: false,
            });
            new_rhs.replace_range(*start..*stop, &pipe);
        }
        if new_rhs == rhs {
            continue;
        }
        n_assigns += 1;
        for n in ln..=end.max(ln) {
            claimed.insert(n);
        }
        rewrites.insert(ln, (lhs, new_rhs));
        for n in ln + 1..=end.max(ln) {
            rewrites.entry(n).or_insert_with(|| (String::new(), String::new()));
        }
    }
    (preps, rewrites)
}

/// Sibling span extras (VII.A) plus sandwich remainder extras (VII.E)
/// plus or-reduce prep pipes.
pub fn all_emit_extra_cuts(source: &str, cuts: &[CutAssign]) -> Vec<CutAssign> {
    let mut out = sibling_span_extra_cuts(source, cuts);
    let mut seen: std::collections::BTreeSet<String> = out
        .iter()
        .filter(|c| !c.lhs.is_empty())
        .map(|c| lhs_base_ident(&c.lhs).to_string())
        .collect();
    for extra in remainder_sandwich_extra_cuts(source, cuts) {
        let base = if extra.lhs.is_empty() {
            String::new()
        } else {
            lhs_base_ident(&extra.lhs).to_string()
        };
        if !base.is_empty() && !seen.insert(base) {
            continue;
        }
        out.push(extra);
    }
    let (preps, _) = or_reduce_prep_cuts(source, cuts);
    out.extend(preps);
    out
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
    // Twin generate locals (`gen_reuse_a` / `gen_reuse_b` both `assign c_span = mul`)
    // share an lhs *name* but are distinct nets. claimed_lhs in cut_assigns keeps
    // one pipe; rewrite every other identical continuous assign onto that pipe
    // (audit-gemm-expol3 left gen_reuse_b live → post_analyze 161.5).
    // Different-RHS siblings (`a_span` vs `b_span`) get **their own** pipes via
    // [`sibling_span_extra_cuts`] (emit-side A) — never share the twin pipe.
    let mut twin_line: std::collections::BTreeMap<u32, &CutAssign> =
        std::collections::BTreeMap::new();
    let line_count = source.lines().count() as u32;
    for ln in 1..=line_count {
        if line_to_cut.contains_key(&ln) || twin_line.contains_key(&ln) {
            continue;
        }
        if !line_is_continuous_assign(source, ln) {
            continue;
        }
        let Some((lhs, rhs, _, end)) = parse_assign_multiline(source, ln, 8) else {
            continue;
        };
        let Some(cut) = cuts.iter().find(|c| {
            c.continuous
                && c.line > 0
                && lhs_base_ident(&c.lhs) == lhs_base_ident(&lhs)
                && norm_expr(&c.rhs) == norm_expr(&rhs)
        }) else {
            continue;
        };
        for n in ln..=end.max(ln) {
            twin_line.entry(n).or_insert(cut);
        }
    }
    let extras = all_emit_extra_cuts(source, cuts);
    let (_, reduce_rw) = or_reduce_prep_cuts(source, cuts);
    let mut sibling_line: std::collections::BTreeMap<u32, &CutAssign> =
        std::collections::BTreeMap::new();
    for extra in &extras {
        if extra.line == 0 {
            continue;
        }
        for n in extra.line..=extra.end_line.max(extra.line) {
            if line_to_cut.contains_key(&n) || twin_line.contains_key(&n) {
                continue;
            }
            sibling_line.entry(n).or_insert(extra);
        }
    }

    let lines: Vec<&str> = source.lines().collect();
    let mut out = String::with_capacity(source.len() + 64 * cuts.len());
    for (i, line) in lines.iter().enumerate() {
        let line_no = (i + 1) as u32;
        if let Some(cut) = line_to_cut.get(&line_no) {
            // Procedural always_ff / always_comb: `--real-cut-feeds` rewrites
            // a simple assign/NBA to sample the pipe (audit-gemm-expol4 path
            // 3131 origin is `always_ff` :1859). Unsafe control tails (bare
            // `if`/`for` on the same line, generate index) keep the origin.
            let t = strip_line_comment(line).trim();
            let line_is_assign_kw =
                t.starts_with("assign ") || t.starts_with("assign\t");
            if !cut.continuous && !line_is_assign_kw {
                let indent: String = line.chars().take_while(|c| c.is_whitespace()).collect();
                if line_no == cut.line {
                    if procedural_cut_is_unsafe(line, &cut.lhs) {
                        out.push_str(&indent);
                        out.push_str(&format!(
                            "// sv-timing: cut #{} note (procedural origin kept; lean pipe)\n",
                            cut.edit_id
                        ));
                        out.push_str(line);
                        out.push('\n');
                    } else {
                        let labels = case_item_label_prefix(line);
                        let op = if cut.nonblocking { " <= " } else { " = " };
                        out.push_str(&indent);
                        out.push_str("// sv-timing: cut #");
                        out.push_str(&cut.edit_id.to_string());
                        out.push_str(" moved ");
                        out.push_str(&cut.lhs);
                        out.push_str(" <- (");
                        out.push_str(&cut.rhs);
                        out.push_str(") via ");
                        out.push_str(&cut.pipe_name);
                        out.push_str(" (procedural)\n");
                        out.push_str(&indent);
                        out.push_str(&labels);
                        out.push_str(&cut.lhs);
                        out.push_str(op);
                        out.push_str(&cut.pipe_name);
                        out.push_str(";\n");
                    }
                } else if is_case_label_only_line(line) {
                    out.push_str(line);
                    out.push('\n');
                } else {
                    out.push_str(&indent);
                    out.push_str("// sv-timing: (cut #");
                    out.push_str(&cut.edit_id.to_string());
                    out.push_str(" continuation) ");
                    out.push_str(line.trim());
                    out.push('\n');
                }
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
        } else if let Some(cut) = twin_line.get(&line_no) {
            let indent: String = line.chars().take_while(|c| c.is_whitespace()).collect();
            if line_is_continuous_assign(source, line_no) {
                let lhs = parse_assign_multiline(source, line_no, 8)
                    .map(|(l, _, _, _)| l)
                    .unwrap_or_else(|| cut.lhs.clone());
                out.push_str(&indent);
                out.push_str("// sv-timing: cut #");
                out.push_str(&cut.edit_id.to_string());
                out.push_str(" twin moved ");
                out.push_str(&lhs);
                out.push_str(" <- (");
                out.push_str(&cut.rhs);
                out.push_str(") via ");
                out.push_str(&cut.pipe_name);
                out.push_str("\n");
                out.push_str(&indent);
                out.push_str("assign ");
                out.push_str(&lhs);
                out.push_str(" = ");
                out.push_str(&cut.pipe_name);
                out.push_str(";\n");
            } else if is_case_label_only_line(line) {
                out.push_str(line);
                out.push('\n');
            } else {
                out.push_str(&indent);
                out.push_str("// sv-timing: (cut #");
                out.push_str(&cut.edit_id.to_string());
                out.push_str(" twin continuation) ");
                out.push_str(line.trim());
                out.push('\n');
            }
        } else if let Some(cut) = sibling_line.get(&line_no) {
            let indent: String = line.chars().take_while(|c| c.is_whitespace()).collect();
            if line_is_continuous_assign(source, line_no) {
                let lhs = parse_assign_multiline(source, line_no, 8)
                    .map(|(l, _, _, _)| l)
                    .unwrap_or_else(|| cut.lhs.clone());
                out.push_str(&indent);
                out.push_str("// sv-timing: cut #");
                out.push_str(&cut.edit_id.to_string());
                if lhs_is_span_family_ident(&lhs) {
                    out.push_str(" sibling span moved ");
                } else {
                    out.push_str(" remainder moved ");
                }
                out.push_str(&lhs);
                out.push_str(" <- (");
                out.push_str(&cut.rhs);
                out.push_str(") via ");
                out.push_str(&cut.pipe_name);
                out.push_str("\n");
                out.push_str(&indent);
                out.push_str("assign ");
                out.push_str(&lhs);
                out.push_str(" = ");
                out.push_str(&cut.pipe_name);
                out.push_str(";\n");
            } else if is_case_label_only_line(line) {
                out.push_str(line);
                out.push('\n');
            } else {
                out.push_str(&indent);
                out.push_str("// sv-timing: (cut #");
                out.push_str(&cut.edit_id.to_string());
                out.push_str(" sibling span continuation) ");
                out.push_str(line.trim());
                out.push('\n');
            }
        } else if let Some((lhs, new_rhs)) = reduce_rw.get(&line_no) {
            let indent: String = line.chars().take_while(|c| c.is_whitespace()).collect();
            if lhs.is_empty() {
                out.push_str(&indent);
                out.push_str("// sv-timing: (or-reduce continuation) ");
                out.push_str(line.trim());
                out.push('\n');
            } else {
                out.push_str(&indent);
                out.push_str("// sv-timing: or-reduce preps for ");
                out.push_str(lhs);
                out.push_str("\n");
                out.push_str(&indent);
                out.push_str("assign ");
                out.push_str(lhs);
                out.push_str(" = ");
                out.push_str(new_rhs);
                out.push_str(";\n");
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
                    // Keep `assign` on continuous origins. Dropping it made
                    // `te_packet_emitter` `assign address_off = …` a module-scope
                    // blocking assign (`audit-remain-v21` integrity Parse).
                    let keep_assign = line_is_continuous_assign(source, body_start);
                    let assign_kw = if keep_assign { "assign " } else { "" };
                    out.push_str(&indent);
                    out.push_str(&format!(
                        "{case_prefix}{assign_kw}{lhs} {op} {new_rhs}; // sv-timing: BalanceMux/rebalance #{edit_id} RHS rewrite\n"
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
    fn balance_mux_rhs_rewrite_keeps_assign_keyword() {
        let src = r#"module te (
    input logic [7:0] keep_bits_i,
    output logic [3:0] address_off
);
    assign address_off = (keep_bits_i + 7)>>3;
endmodule
"#;
        let snippet = "  logic [64-1:0] svt_bm_top;\n  always_comb begin : svt_bm_top_stage\n    svt_bm_top = keep_bits_i + 7;\n  end\n";
        let mut trace = EditTrace::new();
        trace.record_edit(EditRecord {
            id: 7,
            kind: EditKind::BalanceMux,
            origin: test_loc("te.sv", 5),
            path_id: Some(1),
            node_id: Some(0),
            new_name: Some("svt_bm_top".into()),
            fo4_before: Some(22.0),
            fo4_after: Some(10.0),
            rationale: "stage".into(),
            emit_rhs: Some("svt_bm_top".into()),
            emit_rhs_extras: Vec::new(),
            emit_snippet: Some(snippet.into()),
        });
        let out = rewrite_origin_rhs_replaces(src, &trace);
        assert!(
            out.contains("assign address_off = svt_bm_top;"),
            "continuous BalanceMux rewrite must keep assign, got:\n{out}"
        );
        assert!(
            !out.lines().any(|l| {
                let t = l.trim();
                t.starts_with("address_off =") && !t.starts_with("assign ")
            }),
            "bare module-scope blocking assign is illegal:\n{out}"
        );
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
        assert!(
            rewritten.contains("moved t1") && rewritten.contains("t1 = t0_svt_p1"),
            "real-cut-feeds must rewrite procedural origin: {rewritten}"
        );
        assert!(
            !rewritten.contains("t1 = t0 + c_i"),
            "live add must leave the always_comb: {rewritten}"
        );
        assert!(rewritten.contains("t0 = a_i + b_i;")); // other lines intact
        let sinks = sink_assigns_sv(&cuts);
        assert!(
            !sinks.contains("assign t1 = t0_svt_p1"),
            "no continuous sink for procedural origin"
        );
    }

    #[test]
    fn rewrite_procedural_nba_samples_pipe() {
        let src = include_str!("../../../fixtures/auto_correct/proc_nba_span.sv");
        let line = src
            .lines()
            .position(|l| l.contains("y_o <=") && l.contains('*'))
            .expect("y_o nba mul") as u32
            + 1;
        let mut tr = EditTrace::new();
        tr.record_edit(EditRecord {
            id: 0,
            kind: EditKind::InsertReg,
            origin: test_loc("proc_nba_span.sv", line),
            path_id: Some(0),
            node_id: Some(1),
            new_name: Some("pipe_svt_p1".into()),
            fo4_before: Some(68.0),
            fo4_after: Some(10.0),
            rationale: "nba cut".into(),
            emit_rhs: None,
            emit_rhs_extras: Vec::new(),
            emit_snippet: None,
        });
        tr.records[0].id = 0;
        tr.records[0].new_name = Some("pipe_svt_p1".into());
        let cuts = cut_assigns_from_source(src, &tr);
        assert_eq!(cuts.len(), 1);
        assert_eq!(cuts[0].lhs, "y_o");
        assert!(cuts[0].nonblocking);
        assert!(!cuts[0].continuous);
        let rewritten = rewrite_origin_assigns(src, &cuts);
        assert!(
            rewritten.contains("moved y_o") && rewritten.contains("y_o <= pipe_svt_p1"),
            "{rewritten}"
        );
        let live_mul = rewritten.lines().any(|l| {
            let t = l.trim();
            t.contains("y_o <=") && t.contains("*") && !t.starts_with("//")
        });
        assert!(!live_mul, "live mul NBA left in always_ff:\n{rewritten}");
    }

    #[test]
    fn multiline_nba_empty_first_rhs_samples_pipe() {
        // gemm `ar_slot_q[ridx].row <=\n  row + 1;` — first line has empty RHS so
        // parse_assign_line fails; rewrite must still emit `lhs <= pipe` (expol6).
        let src = r#"module m;
  logic clk_i, rst_ni;
  logic [31:0] y_o, a, b;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) y_o <= '0;
    else begin
      y_o <=
          a * b + 32'd1;
    end
  end
endmodule
"#;
        let line = src
            .lines()
            .position(|l| l.contains("y_o <=") && !l.contains("'0"))
            .expect("nba") as u32
            + 1;
        let mut tr = EditTrace::new();
        tr.record_edit(EditRecord {
            id: 0,
            kind: EditKind::InsertReg,
            origin: test_loc("m.sv", line),
            path_id: Some(0),
            node_id: Some(1),
            new_name: Some("pipe_svt_p1".into()),
            fo4_before: Some(56.0),
            fo4_after: Some(10.0),
            rationale: "cut".into(),
            emit_rhs: None,
            emit_rhs_extras: Vec::new(),
            emit_snippet: None,
        });
        tr.records[0].id = 0;
        tr.records[0].new_name = Some("pipe_svt_p1".into());
        let cuts = cut_assigns_from_source(src, &tr);
        assert_eq!(cuts.len(), 1);
        assert!(!cuts[0].continuous);
        assert_eq!(cuts[0].lhs, "y_o");
        let rewritten = rewrite_origin_assigns(src, &cuts);
        assert!(
            rewritten.contains("y_o <= pipe_svt_p1"),
            "first line must sample pipe:\n{rewritten}"
        );
        let dangling = rewritten.lines().any(|l| {
            let t = l.trim();
            t.ends_with("<=") && !t.starts_with("//")
        });
        assert!(!dangling, "dangling NBA with no RHS:\n{rewritten}");
        let live_mul = rewritten.lines().any(|l| {
            let t = l.trim();
            t.contains('*') && !t.starts_with("//")
        });
        assert!(!live_mul, "live mul continuation:\n{rewritten}");
    }

    #[test]
    fn blank_line_origin_keeps_continuous_assign() {
        // instr_queue / te_branch_map: IR loc on the blank line before `assign`.
        let src = r#"module m;
  logic [3:0] idx_is_d, idx_is_q, shamt, push_seq_d, push_seq_q, IdxMask;
  always_comb begin
    shamt = '0;
  end

  assign idx_is_d = (idx_is_q + shamt) & IdxMask;
  assign push_seq_d = push_seq_q + shamt;
endmodule
"#;
        let assign_line = src
            .lines()
            .position(|l| l.contains("assign idx_is_d"))
            .expect("assign") as u32
            + 1;
        let origin = assign_line - 1;
        let mut tr = EditTrace::new();
        tr.record_edit(EditRecord {
            id: 0,
            kind: EditKind::InsertReg,
            origin: test_loc("m.sv", origin),
            path_id: Some(0),
            node_id: Some(1),
            new_name: Some("pipe_svt_p1".into()),
            fo4_before: Some(20.0),
            fo4_after: Some(10.0),
            rationale: "cut".into(),
            emit_rhs: None,
            emit_rhs_extras: Vec::new(),
            emit_snippet: None,
        });
        tr.records[0].id = 0;
        tr.records[0].new_name = Some("pipe_svt_p1".into());
        let cuts = cut_assigns_from_source(src, &tr);
        assert_eq!(cuts.len(), 1);
        assert!(
            cuts[0].continuous,
            "blank-before-assign must stay continuous: {cuts:?}"
        );
        assert_eq!(cuts[0].lhs, "idx_is_d");
        let rewritten = rewrite_origin_assigns(src, &cuts);
        let bare = rewritten.lines().any(|l| {
            let t = l.trim();
            !t.starts_with("//") && t.starts_with("idx_is_d =") && !t.starts_with("assign")
        });
        assert!(
            !bare,
            "illegal module-scope blocking assign:\n{rewritten}"
        );
        assert!(
            rewritten.contains("moved idx_is_d"),
            "expected origin rewrite:\n{rewritten}"
        );
        let live = rewritten.lines().any(|l| {
            let t = l.trim();
            t.starts_with("assign idx_is_d") && t.contains("IdxMask") && !t.starts_with("//")
        });
        assert!(!live, "live assign idx_is_d left:\n{rewritten}");
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

    #[test]
    fn twin_generate_c_span_rewrites_both_assigns() {
        let src = include_str!("../../../fixtures/auto_correct/twin_generate_span.sv");
        let line = src
            .lines()
            .position(|l| l.contains("assign c_span"))
            .expect("first c_span") as u32
            + 1;
        let mut tr = EditTrace::new();
        tr.record_edit(EditRecord {
            id: 0,
            kind: EditKind::InsertReg,
            origin: test_loc("twin_generate_span.sv", line),
            path_id: Some(0),
            node_id: Some(1),
            new_name: Some("pipe_svt_p1".into()),
            fo4_before: Some(56.0),
            fo4_after: Some(10.0),
            rationale: "c_span cut".into(),
            emit_rhs: None,
            emit_rhs_extras: Vec::new(),
            emit_snippet: None,
        });
        tr.records[0].id = 0;
        tr.records[0].new_name = Some("pipe_svt_p1".into());
        let cuts = cut_assigns_from_source(src, &tr);
        assert_eq!(cuts.len(), 1, "one pipe for identical rhs");
        assert_eq!(cuts[0].lhs, "c_span");
        let rewritten = rewrite_origin_assigns(src, &cuts);
        let live_mul = rewritten.lines().any(|l| {
            let t = l.trim();
            t.starts_with("assign c_span") && t.contains("<<") && !t.starts_with("//")
        });
        assert!(!live_mul, "twin generate left a live c_span mul:\n{rewritten}");
        assert!(
            rewritten.contains("twin moved c_span"),
            "expected twin origin rewrite:\n{rewritten}"
        );
        assert!(
            rewritten.contains("assign c_span = pipe_svt_p1"),
            "twin must sample the shared pipe:\n{rewritten}"
        );
        assert_eq!(
            rewritten.matches("assign c_span = pipe_svt_p1").count(),
            1,
            "exactly one in-place twin sink (claimed line still uses module sink):\n{rewritten}"
        );
        let extras = sibling_span_extra_cuts(src, &cuts);
        assert!(
            extras.is_empty(),
            "identical-RHS twins must not grow extra pipes: {extras:?}"
        );
    }

    #[test]
    fn sibling_span_extra_cuts_uncut_spans_own_pipes() {
        let src = include_str!("../../../fixtures/auto_correct/sibling_span.sv");
        let line = src
            .lines()
            .position(|l| l.contains("assign a_span"))
            .expect("a_span") as u32
            + 1;
        let mut tr = EditTrace::new();
        tr.record_edit(EditRecord {
            id: 0,
            kind: EditKind::InsertReg,
            origin: test_loc("sibling_span.sv", line),
            path_id: Some(0),
            node_id: Some(1),
            new_name: Some("pipe_svt_p1".into()),
            fo4_before: Some(18.5),
            fo4_after: Some(10.0),
            rationale: "a_span cut".into(),
            emit_rhs: None,
            emit_rhs_extras: Vec::new(),
            emit_snippet: None,
        });
        tr.records[0].id = 0;
        tr.records[0].new_name = Some("pipe_svt_p1".into());
        let cuts = cut_assigns_from_source(src, &tr);
        assert_eq!(cuts.len(), 1);
        assert_eq!(cuts[0].lhs, "a_span");
        let extras = sibling_span_extra_cuts(src, &cuts);
        let extra_lhs: Vec<&str> = extras.iter().map(|c| c.lhs.as_str()).collect();
        assert!(
            extra_lhs.contains(&"b_span"),
            "expected uncut b_span extra, got {extra_lhs:?}"
        );
        assert!(
            extra_lhs.contains(&"a_end") && extra_lhs.contains(&"b_end"),
            "expected uncut *_end extras, got {extra_lhs:?}"
        );
        assert!(
            !extra_lhs.contains(&"a_span"),
            "must not re-cut claimed a_span: {extra_lhs:?}"
        );
        let extra_pipes: std::collections::BTreeSet<&str> =
            extras.iter().map(|c| c.pipe_name.as_str()).collect();
        assert_eq!(extra_pipes.len(), extras.len(), "unique sibling pipes");
        assert!(!extra_pipes.contains("pipe_svt_p1"));
        let rewritten = rewrite_origin_assigns(src, &cuts);
        assert!(
            rewritten.contains("sibling span moved"),
            "expected sibling origin rewrite:\n{rewritten}"
        );
        let live_b = rewritten.lines().any(|l| {
            let t = l.trim();
            t.starts_with("assign b_span") && t.contains("p_q") && !t.starts_with("//")
        });
        assert!(!live_b, "b_span combo left live:\n{rewritten}");
        assert!(
            extras.iter().any(|c| rewritten.contains(&format!(
                "assign b_span = {}",
                c.pipe_name
            ))),
            "b_span must sample its own pipe:\n{rewritten}"
        );
        assert!(
            !rewritten.contains("assign b_span = pipe_svt_p1"),
            "different-RHS sibling must not share the twin pipe:\n{rewritten}"
        );
    }

    #[test]
    fn sibling_span_star_add_feed_splits_prep_pipe() {
        let src = r#"
module sibling_span_scale (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic [31:0] x_q, y_q, p_q, q_q, pa_q, pb_q, k_bytes,
    output logic [31:0] ya_o, yb_o
);
  localparam bit ReuseAEn = 1'b1;
  localparam bit ReuseBEn = 1'b1;
  logic [31:0] a_span, a_end, b_span, b_end;
  if (ReuseAEn) begin : gen_reuse_a
    assign a_span = x_q * y_q + pa_q;
    assign a_end = pa_q + a_span;
  end
  if (ReuseBEn) begin : gen_reuse_b
    assign b_span = p_q * q_q + k_bytes;
    assign b_end = pb_q + b_span;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) ya_o <= '0;
    else         ya_o <= a_end;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) yb_o <= '0;
    else         yb_o <= b_end;
  end
endmodule
"#;
        let line = src
            .lines()
            .position(|l| l.contains("assign a_span"))
            .expect("a_span") as u32
            + 1;
        let mut tr = EditTrace::new();
        tr.record_edit(EditRecord {
            id: 0,
            kind: EditKind::InsertReg,
            origin: test_loc("sibling_span_scale.sv", line),
            path_id: Some(0),
            node_id: Some(1),
            new_name: Some("pipe_svt_p1".into()),
            fo4_before: Some(12.5),
            fo4_after: Some(10.0),
            rationale: "a_span cut".into(),
            emit_rhs: None,
            emit_rhs_extras: Vec::new(),
            emit_snippet: None,
        });
        tr.records[0].id = 0;
        tr.records[0].new_name = Some("pipe_svt_p1".into());
        let cuts = cut_assigns_from_source(src, &tr);
        let extras = sibling_span_extra_cuts(src, &cuts);
        let b_span = extras
            .iter()
            .find(|c| c.lhs == "b_span")
            .expect("b_span extra");
        assert!(
            b_span.rhs.contains(" + "),
            "b_span feed should be prep + tail, got {}",
            b_span.rhs
        );
        assert!(
            !b_span.rhs.contains('*'),
            "mul must live in the prep pipe, not the add pipe: {}",
            b_span.rhs
        );
        assert!(
            !b_span.rhs.contains("k_bytes"),
            "combo tail k_bytes must be sampled, not added live: {}",
            b_span.rhs
        );
        let prep = extras.iter().find(|c| {
            c.line == 0 && c.lhs.is_empty() && c.rhs.contains('*') && !c.rhs.contains(" + ")
        });
        assert!(
            prep.is_some(),
            "expected prep extra for p_q * q_q, extras={extras:?}"
        );
        let prep = prep.unwrap();
        let tail = extras.iter().find(|c| {
            c.line == 0 && c.lhs.is_empty() && c.rhs.trim() == "k_bytes"
        });
        assert!(
            tail.is_some(),
            "expected tail sample extra for k_bytes, extras={extras:?}"
        );
        let tail = tail.unwrap();
        assert!(
            b_span.rhs.contains(&prep.pipe_name) && b_span.rhs.contains(&tail.pipe_name),
            "add pipe must sample prep Q and tail Q: {} vs {} / {}",
            b_span.rhs,
            prep.pipe_name,
            tail.pipe_name
        );
        let rewritten = rewrite_origin_assigns(src, &cuts);
        assert!(
            rewritten.contains(&format!("assign b_span = {}", b_span.pipe_name)),
            "b_span must sample the add pipe:\n{rewritten}"
        );
    }

    #[test]
    fn queue_remainder_sandwich_cuts_mid_not_claimed() {
        let src = include_str!("../../../fixtures/auto_correct/queue_remainder.sv");
        let line_a = src
            .lines()
            .position(|l| l.contains("assign a ="))
            .expect("a") as u32
            + 1;
        let line_b = src
            .lines()
            .position(|l| l.contains("assign b ="))
            .expect("b") as u32
            + 1;
        let mut tr = EditTrace::new();
        for (id, line, name) in [
            (0u32, line_a, "pipe_svt_p1"),
            (1u32, line_b, "pipe_svt_p2"),
        ] {
            tr.record_edit(EditRecord {
                id,
                kind: EditKind::InsertReg,
                origin: test_loc("queue_remainder.sv", line),
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
        tr.records[0].id = 0;
        tr.records[0].new_name = Some("pipe_svt_p1".into());
        tr.records[1].id = 1;
        tr.records[1].new_name = Some("pipe_svt_p2".into());
        let cuts = cut_assigns_from_source(src, &tr);
        assert_eq!(cuts.len(), 2);
        let extras = remainder_sandwich_extra_cuts(src, &cuts);
        assert!(
            extras.iter().any(|c| c.lhs == "mid"),
            "expected sandwich extra on mid, got {extras:?}"
        );
        assert!(
            extras.iter().all(|c| c.lhs != "a" && c.lhs != "b"),
            "must not recut claimed a/b: {extras:?}"
        );
        let rewritten = rewrite_origin_assigns(src, &cuts);
        assert!(
            rewritten.contains("remainder moved"),
            "expected remainder origin rewrite:\n{rewritten}"
        );
        let live_mid = rewritten.lines().any(|l| {
            let t = l.trim();
            t.starts_with("assign mid") && t.contains("p_q") && !t.starts_with("//")
        });
        assert!(!live_mid, "mid combo left live:\n{rewritten}");
        assert!(
            !rewritten.contains("assign mid = pipe_svt_p1")
                && !rewritten.contains("assign mid = pipe_svt_p2"),
            "mid must use its own remainder pipe:\n{rewritten}"
        );
    }

    #[test]
    fn comma_assign_list_is_not_rewritten() {
        let src = r#"
module amo_comma (
    input  logic [63:0] ld_data, st_data,
    output logic        ugt, sgt,
    output logic [63:0] sum
);
    assign ugt = (ld_data > st_data),
           sgt = (ld_data > st_data),
           sum =  ld_data + st_data;
endmodule
"#;
        let line = src
            .lines()
            .position(|l| l.contains("sgt ="))
            .expect("sgt") as u32
            + 1;
        let mut tr = EditTrace::new();
        tr.record_edit(EditRecord {
            id: 0,
            kind: EditKind::InsertReg,
            origin: test_loc("amo_comma.sv", line),
            path_id: Some(0),
            node_id: Some(1),
            new_name: Some("pipe_svt_p1".into()),
            fo4_before: Some(12.0),
            fo4_after: Some(10.0),
            rationale: "sgt cut".into(),
            emit_rhs: None,
            emit_rhs_extras: Vec::new(),
            emit_snippet: None,
        });
        tr.records[0].id = 0;
        tr.records[0].new_name = Some("pipe_svt_p1".into());
        let cuts = cut_assigns_from_source(src, &tr);
        assert!(
            cuts.iter().all(|c| c.line == 0 || !c.rhs.contains("sum =")),
            "comma-list tail must not become a cut rhs: {cuts:?}"
        );
        let rewritten = rewrite_origin_assigns(src, &cuts);
        assert!(
            rewritten.contains("sgt = (ld_data > st_data)"),
            "origin comma-list must stay: {rewritten}"
        );
        assert!(
            !rewritten.contains("sgt = pipe_svt_p1"),
            "must not rewrite comma-list lvalue as pipe sample:\n{rewritten}"
        );
    }

    #[test]
    fn or_reduce_preps_on_next_state_d() {
        let src = r#"
module fe_spec (
    input  logic clk_i, rst_ni, flush_i, resolved,
    input  logic [3:0] is_branch, is_return, is_jalr,
    output logic spec_q
);
  logic spec_d;
  logic [31:0] t0, t1;
  assign t0 = 32'd1;
  assign spec_d = (spec_q && !resolved || |is_branch || |is_return || |is_jalr) && !flush_i;
  assign t1 = t0 + 32'd1;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) spec_q <= 1'b0;
    else         spec_q <= spec_d;
  end
endmodule
"#;
        let line_t1 = src
            .lines()
            .position(|l| l.contains("assign t1"))
            .expect("t1") as u32
            + 1;
        let mut tr = EditTrace::new();
        tr.record_edit(EditRecord {
            id: 0,
            kind: EditKind::InsertReg,
            origin: test_loc("fe_spec.sv", line_t1),
            path_id: Some(0),
            node_id: Some(1),
            new_name: Some("pipe_svt_p1".into()),
            fo4_before: Some(12.0),
            fo4_after: Some(10.0),
            rationale: "t1".into(),
            emit_rhs: None,
            emit_rhs_extras: Vec::new(),
            emit_snippet: None,
        });
        tr.records[0].id = 0;
        tr.records[0].new_name = Some("pipe_svt_p1".into());
        let cuts = cut_assigns_from_source(src, &tr);
        let extras = all_emit_extra_cuts(src, &cuts);
        let reds: Vec<&str> = extras
            .iter()
            .filter(|c| c.pipe_name.contains("pipe_svt_red_"))
            .map(|c| c.rhs.as_str())
            .collect();
        assert!(
            reds.iter().any(|r| *r == "|is_branch")
                && reds.iter().any(|r| *r == "|is_return")
                && reds.iter().any(|r| *r == "|is_jalr"),
            "expected three or-reduce preps, got {reds:?} extras={extras:?}"
        );
        let rewritten = rewrite_origin_assigns(src, &cuts);
        assert!(
            rewritten.contains("or-reduce preps for spec_d"),
            "expected or-reduce rewrite:\n{rewritten}"
        );
        let live = rewritten.lines().any(|l| {
            let t = l.trim();
            t.starts_with("assign spec_d") && t.contains("|is_branch") && !t.starts_with("//")
        });
        assert!(!live, "live |is_branch left on spec_d:\n{rewritten}");
        assert!(
            rewritten.contains("assign spec_d") && rewritten.contains("pipe_svt_red_is_branch"),
            "spec_d must sample reduce pipes:\n{rewritten}"
        );
    }

    #[test]
    fn or_reduce_preps_mixed_single_reduce() {
        let src = r#"
module wbuf_fixup (
    input  logic clk_i, rst_ni,
    input  logic [7:0] tocheck,
    input  logic hit_q, en_q, en_q1,
    input  logic [1:0] state_q,
    output logic req_o, miss_req_o
);
  logic req, t1;
  assign t1 = 1'b1;
  assign req = (state_q == 2'd1) && !hit_q && !(|tocheck) && !en_q && !en_q1;
  assign miss_req_o = (|tocheck) && en_q;
  assign req_o = req;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) ;
    else         ;
  end
endmodule
"#;
        let line_t1 = src
            .lines()
            .position(|l| l.contains("assign t1"))
            .expect("t1") as u32
            + 1;
        let mut tr = EditTrace::new();
        tr.record_edit(EditRecord {
            id: 0,
            kind: EditKind::InsertReg,
            origin: test_loc("wbuf_fixup.sv", line_t1),
            path_id: Some(0),
            node_id: Some(1),
            new_name: Some("pipe_svt_p1".into()),
            fo4_before: Some(12.0),
            fo4_after: Some(10.0),
            rationale: "t1".into(),
            emit_rhs: None,
            emit_rhs_extras: Vec::new(),
            emit_snippet: None,
        });
        tr.records[0].id = 0;
        tr.records[0].new_name = Some("pipe_svt_p1".into());
        let cuts = cut_assigns_from_source(src, &tr);
        let extras = all_emit_extra_cuts(src, &cuts);
        let reds: Vec<&str> = extras
            .iter()
            .filter(|c| c.pipe_name.contains("pipe_svt_red_"))
            .map(|c| c.rhs.as_str())
            .collect();
        assert_eq!(reds, vec!["|tocheck"], "mixed AND cone: {reds:?} extras={extras:?}");
        let rewritten = rewrite_origin_assigns(src, &cuts);
        assert!(
            rewritten.contains("or-reduce preps for req"),
            "expected mixed or-reduce rewrite:\n{rewritten}"
        );
        let live = rewritten.lines().any(|l| {
            let t = l.trim();
            t.starts_with("assign req") && t.contains("|tocheck") && !t.starts_with("//")
        });
        assert!(!live, "live |tocheck left on req:\n{rewritten}");
        assert!(
            rewritten.contains("pipe_svt_red_tocheck"),
            "req must sample reduce pipe:\n{rewritten}"
        );
        let live_port = rewritten.lines().any(|l| {
            let t = l.trim();
            t.starts_with("assign miss_req_o") && t.contains("pipe_svt_red") && !t.starts_with("//")
        });
        assert!(!live_port, "must not extra-cycle _o handshake:\n{rewritten}");
    }

    #[test]
    fn binary_or_is_not_unary_reduce() {
        let src = r#"
module icache_we (
    input  logic clk_i, rst_ni, cache_wren, inv_en, flush_en, en_q, hit_q,
    input  logic [7:0] tocheck,
    output logic we, req
);
  logic t1;
  assign t1 = 1'b1;
  assign we = (cache_wren | inv_en | flush_en);
  assign req = (en_q == 1'b1) && !hit_q && !(|tocheck) && !en_q && !flush_en;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) ;
    else         ;
  end
endmodule
"#;
        let line_t1 = src
            .lines()
            .position(|l| l.contains("assign t1"))
            .expect("t1") as u32
            + 1;
        let mut tr = EditTrace::new();
        tr.record_edit(EditRecord {
            id: 0,
            kind: EditKind::InsertReg,
            origin: test_loc("icache_we.sv", line_t1),
            path_id: Some(0),
            node_id: Some(1),
            new_name: Some("pipe_svt_p1".into()),
            fo4_before: Some(12.0),
            fo4_after: Some(10.0),
            rationale: "t1".into(),
            emit_rhs: None,
            emit_rhs_extras: Vec::new(),
            emit_snippet: None,
        });
        tr.records[0].id = 0;
        tr.records[0].new_name = Some("pipe_svt_p1".into());
        let cuts = cut_assigns_from_source(src, &tr);
        let extras = all_emit_extra_cuts(src, &cuts);
        let reds: Vec<&str> = extras
            .iter()
            .filter(|c| c.pipe_name.contains("pipe_svt_red_"))
            .map(|c| c.rhs.as_str())
            .collect();
        assert!(
            !reds.iter().any(|r| r.contains("inv_en") || r.contains("flush_en") || r.contains("cache_wren")),
            "bitwise | must not become or-reduce: {reds:?}"
        );
        assert_eq!(reds, vec!["|tocheck"], "only unary |tocheck: {reds:?}");
        let rewritten = rewrite_origin_assigns(src, &cuts);
        assert!(
            rewritten.contains("assign we = (cache_wren | inv_en | flush_en)"),
            "we bitwise or must stay:\n{rewritten}"
        );
        assert!(
            !rewritten.contains("assign we = (cache_wren pipe_svt_red"),
            "must not delete bitwise |:\n{rewritten}"
        );
    }

    #[test]
    fn or_reduce_preps_inside_generate_if() {
        let src = r#"
module wbuf_gen (
    input  logic clk_i, rst_ni,
    input  logic [7:0] tocheck,
    input  logic hit_q, en_q, en_q1,
    input  logic [1:0] state_q
);
  logic t1, req;
  assign t1 = 1'b1;
  generate
    if (1) begin : gen_fixup_queue
      assign req = (state_q == 2'd1) && !hit_q && !(|tocheck) && !en_q && !en_q1;
    end
  endgenerate
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) ;
    else         ;
  end
endmodule
"#;
        let line_t1 = src
            .lines()
            .position(|l| l.contains("assign t1"))
            .expect("t1") as u32
            + 1;
        let mut tr = EditTrace::new();
        tr.record_edit(EditRecord {
            id: 0,
            kind: EditKind::InsertReg,
            origin: test_loc("wbuf_gen.sv", line_t1),
            path_id: Some(0),
            node_id: Some(1),
            new_name: Some("pipe_svt_p1".into()),
            fo4_before: Some(12.0),
            fo4_after: Some(10.0),
            rationale: "t1".into(),
            emit_rhs: None,
            emit_rhs_extras: Vec::new(),
            emit_snippet: None,
        });
        tr.records[0].id = 0;
        tr.records[0].new_name = Some("pipe_svt_p1".into());
        let cuts = cut_assigns_from_source(src, &tr);
        let extras = all_emit_extra_cuts(src, &cuts);
        let reds: Vec<&str> = extras
            .iter()
            .filter(|c| c.pipe_name.contains("pipe_svt_red_"))
            .map(|c| c.rhs.as_str())
            .collect();
        assert_eq!(reds, vec!["|tocheck"], "generate-if mixed cone: {reds:?}");
        let rewritten = rewrite_origin_assigns(src, &cuts);
        assert!(
            rewritten.contains("or-reduce preps for req"),
            "expected generate-if or-reduce rewrite:\n{rewritten}"
        );
        let live = rewritten.lines().any(|l| {
            let t = l.trim();
            t.starts_with("assign req") && t.contains("|tocheck") && !t.starts_with("//")
        });
        assert!(!live, "live |tocheck left on generate-if req:\n{rewritten}");
    }
}
