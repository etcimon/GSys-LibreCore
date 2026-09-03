// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! AI descriptor package (`g6lc_ai_desc_pkg.sv`) reader.
//!
//! The package defines the 64-byte Xg6lcai T2 descriptor: op codes, status codes,
//! and the packed layout of `desc_t`.  This module extracts those values and offsets
//! from the SystemVerilog source rather than duplicating them in Rust.
//!
//! Layout is derived from the `bits_to_desc` (or `desc_to_bits`) assignment map:
//! each `d.<field> = b[<high>:<low>];` entry gives the bit range, from which the byte
//! offset and width are computed.  Local parameters for op/status/DescBytes are read
//! from `localparam` declarations.

pub use g6q_core::model::{AiDescLayout, DescField};

/// Parse an AI descriptor package from source text.
///
/// This is intentionally narrow: it reads `localparam` scalars that match the
/// `OP_*`, `ST_*` and `DescBytes` naming used by the package, the `bits_to_desc`
/// function body to recover field bit ranges, and `make_completion` to recover the
/// completion word layout.
///
/// It also validates the descriptor word order. When the package publishes both
/// `bits_to_desc` and `desc_to_bits`, they must agree. When the `desc_t` struct carries
/// byte-offset comments like `// +0x08`, those offsets must match the bit-derived layout.
/// A mismatch is reported as an error rather than silently accepted, so a drift between
/// the packed function and the struct comments surfaces as an unresolved model.
pub fn parse_ai_desc_pkg(text: &str) -> Result<AiDescLayout, String> {
    let mut layout = AiDescLayout::default();
    let cleaned = strip_sv_comments(text);

    // First pass: localparam constants.
    for line in cleaned.split(';') {
        let line = line.trim();
        if let Some((name, value)) = parse_localparam(line) {
            let name = name.to_ascii_uppercase();
            if name == "DESCBYTES" || name == "DESC_BYTES" {
                layout.desc_bytes = value as u64;
            } else if name == "DESC_VERSION" || name == "DESCVERSION" || name == "DESC_VER" {
                layout.version = Some(value as u64);
            } else if name.starts_with("OP_") {
                layout.ops.insert(name, value as u64);
            } else if name.starts_with("ST_") {
                layout.statuses.insert(name, value as u64);
            }
        }
    }

    // Second pass: bit range map in bits_to_desc / desc_to_bits.
    // Find the function body and then the assignment block between `begin` and `end`.
    let func_body = extract_function_body(&cleaned, "bits_to_desc")
        .or_else(|| extract_function_body(&cleaned, "desc_to_bits"))
        .unwrap_or_default();

    for stmt in func_body.split(';') {
        if let Some((field, high, low)) = parse_assignment_range(stmt) {
            let size = (high - low + 1) / 8;
            let offset = low / 8;
            layout.fields.insert(
                field.to_string(),
                DescField {
                    offset,
                    size,
                    bit_low: low,
                    bit_high: high,
                },
            );
        }
    }

    // Third pass: cross-check bits_to_desc against desc_to_bits and desc_t offsets.
    validate_word_order(text, &layout)?;

    // Fourth pass: packed flags layout from helper functions and comments.
    // Use the raw text: `strip_sv_comments` removes the `//` lines we need.
    layout.flags_layout = parse_flags_layout(text);

    // Fifth pass: completion word layout from make_completion.
    if let Some(body) = extract_function_body(&cleaned, "make_completion") {
        layout.completion = parse_completion_layout(&body);
    }

    Ok(layout)
}

fn strip_sv_comments(text: &str) -> String {
    // Remove // comments and /* */ blocks.
    let mut out = String::new();
    let mut chars = text.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '/' && chars.peek() == Some(&'/') {
            chars.next();
            while chars.next().is_some_and(|x| x != '\n') {}
            out.push('\n');
        } else if c == '/' && chars.peek() == Some(&'*') {
            chars.next();
            let mut prev = ' ';
            for x in chars.by_ref() {
                if prev == '*' && x == '/' {
                    break;
                }
                prev = x;
            }
        } else {
            out.push(c);
        }
    }
    out
}

fn parse_localparam(line: &str) -> Option<(&str, i64)> {
    // localparam [logic [15:0]] Name = value;
    let mut words = line.split_whitespace().peekable();
    if words.next().is_none_or(|w| w != "localparam") {
        return None;
    }
    // Skip type/width tokens until we hit the name.
    let mut name = None;
    for w in words.by_ref() {
        if w == "=" {
            break;
        }
        if !w.starts_with('[')
            && !w.ends_with(']')
            && w != "int"
            && w != "unsigned"
            && w != "logic"
            && w != "integer"
        {
            name = Some(w.trim());
        }
    }
    let name = name?;
    let value = words.next()?;
    Some((name, parse_sv_int(value)?))
}

fn parse_sv_int(s: &str) -> Option<i64> {
    let s = s.trim();
    if let Some(v) = s.strip_prefix("0x").or_else(|| s.strip_prefix("0X")) {
        return i64::from_str_radix(v, 16).ok();
    }
    if let Some(v) = s
        .strip_prefix("16'd")
        .or_else(|| s.strip_prefix("32'd"))
        .or_else(|| s.strip_prefix("64'd"))
    {
        return v.parse().ok();
    }
    if let Some(v) = s
        .strip_prefix("16'h")
        .or_else(|| s.strip_prefix("32'h"))
        .or_else(|| s.strip_prefix("64'h"))
    {
        return i64::from_str_radix(v.trim(), 16).ok();
    }
    if let Some(p) = s.find('\'') {
        let _ = s[..p].parse::<usize>().ok()?;
        let rest = &s[p + 1..];
        if let Some(v) = rest.strip_prefix('d') {
            return v.parse().ok();
        } else if let Some(v) = rest.strip_prefix('h') {
            return i64::from_str_radix(v.trim(), 16).ok();
        } else if let Some(v) = rest.strip_prefix('b') {
            return i64::from_str_radix(v.trim(), 2).ok();
        }
    }
    s.parse().ok()
}

fn extract_function_body(text: &str, name: &str) -> Option<String> {
    // Walk "function automatic" declarations and return the full text of the one
    // whose name appears just before the opening '(' (signature and body). This lets
    // callers recover parameter widths from the signature as well as the return value.
    let mut start = 0;
    let needle = "function automatic";
    while let Some(pos) = text[start..].find(needle) {
        let after = start + pos + needle.len();
        let rest = &text[after..];
        if let Some(paren) = rest.find('(') {
            let sig = &rest[..paren];
            let tokens: Vec<_> = sig.split_whitespace().collect();
            if let Some(last) = tokens.last() {
                let found = last.trim_end_matches(';');
                if found == name {
                    let func_start = start + pos;
                    if let Some(end) = text[func_start..].find("endfunction") {
                        return Some(
                            text[func_start..func_start + end + "endfunction".len()]
                                .trim()
                                .to_string(),
                        );
                    }
                }
            }
        }
        start = after;
    }
    None
}

fn parse_assignment_range(stmt: &str) -> Option<(&str, u64, u64)> {
    // d.<field> = b[<high>:<low>];
    let stmt = stmt.trim();
    let field_start = stmt.find("d.")? + 2;
    let eq_pos = stmt.find('=')?;
    let field = stmt[field_start..eq_pos].trim();
    let bracket_start = stmt.find('[')?;
    let bracket_end = stmt.find(']')?;
    let range = &stmt[bracket_start + 1..bracket_end];
    let (high, low) = range.split_once(':')?;
    let high = high.trim().parse().ok()?;
    let low = low.trim().parse().ok()?;
    Some((field, high, low))
}

/// Parse `b[<high>:<low>] = d.<field>;` assignments from `desc_to_bits`.
fn parse_desc_to_bits(stmt: &str) -> Option<(String, (u64, u64))> {
    let stmt = stmt.trim();
    let bracket_start = stmt.find('[')?;
    let bracket_end = stmt.find(']')?;
    let range = &stmt[bracket_start + 1..bracket_end];
    let (high, low) = range.split_once(':')?;
    let high = high.trim().parse().ok()?;
    let low = low.trim().parse().ok()?;
    let eq_pos = stmt.find('=')?;
    let field = stmt[eq_pos + 1..]
        .trim()
        .trim_start_matches("d.")
        .trim_end_matches(';');
    Some((field.to_string(), (high, low)))
}

/// Extract byte offsets from `desc_t` field comments like `// +0x08`.
fn parse_desc_t_offsets(text: &str) -> Option<std::collections::BTreeMap<String, (u64, u64)>> {
    let start = text.find("typedef struct packed")?;
    let rest = &text[start..];
    let end = rest.find("} desc_t;")?;
    let body = &rest[..end];
    let mut offsets = std::collections::BTreeMap::new();
    for line in body.lines() {
        let line = line.trim();
        if !line.starts_with("logic [") {
            continue;
        }
        let bracket_open = line.find('[')?;
        let bracket_close = line.find(']')?;
        let range = &line[bracket_open + 1..bracket_close];
        let (high, low) = range.split_once(':')?;
        let high = high.trim().parse::<u64>().ok()?;
        let low = low.trim().parse::<u64>().ok()?;
        let size = (high.max(low) - high.min(low) + 1) / 8;

        let after = &line[bracket_close + 1..].trim();
        let name = after.split_whitespace().next()?.trim_end_matches(';');

        let comment_start = line.find("//")?;
        let comment = &line[comment_start + 2..];
        let offset = parse_offset_comment(comment)?;
        offsets.insert(name.to_string(), (offset, size));
    }
    Some(offsets)
}

fn parse_offset_comment(s: &str) -> Option<u64> {
    let s = s.trim();
    if let Some(v) = s.strip_prefix("+0x").or_else(|| s.strip_prefix("+ 0x")) {
        let end = v.find(|c: char| !c.is_ascii_hexdigit()).unwrap_or(v.len());
        return u64::from_str_radix(&v[..end], 16).ok();
    }
    if let Some(v) = s.strip_prefix('+') {
        let v = v.trim();
        let end = v.find(|c: char| !c.is_ascii_digit()).unwrap_or(v.len());
        return v[..end].parse().ok();
    }
    None
}

/// Validate the descriptor layout against the package's own `desc_t` comments and the
/// round-trip between `bits_to_desc` and `desc_to_bits`.
fn validate_word_order(text: &str, layout: &AiDescLayout) -> Result<(), String> {
    // Cross-check bits_to_desc against desc_to_bits when both are present.
    if let (Some(bits_to_desc), Some(desc_to_bits)) = (
        extract_function_body(text, "bits_to_desc"),
        extract_function_body(text, "desc_to_bits"),
    ) {
        let to_desc: std::collections::BTreeMap<String, (u64, u64)> = bits_to_desc
            .split(';')
            .filter_map(parse_assignment_range)
            .map(|(f, h, l)| (f.to_string(), (h, l)))
            .collect();
        let to_bits: std::collections::BTreeMap<String, (u64, u64)> = desc_to_bits
            .split(';')
            .filter_map(parse_desc_to_bits)
            .collect();
        for (field, (high, low)) in &to_desc {
            if let Some((h, l)) = to_bits.get(field) {
                if h != high || l != low {
                    return Err(format!(
                        "descriptor word-order conflict: field `{field}` is {high}:{low} in bits_to_desc but {h}:{l} in desc_to_bits"
                    ));
                }
            }
        }
    }

    // Cross-check the bit-derived layout against the desc_t byte-offset comments.
    if let Some(offsets) = parse_desc_t_offsets(text) {
        for (name, field) in &layout.fields {
            if let Some((offset, size)) = offsets.get(name) {
                if field.offset != *offset || field.size != *size {
                    return Err(format!(
                        "descriptor byte-offset conflict: field `{name}` is offset {} size {} from bit ranges, but the desc_t comment says offset {offset} size {size}",
                        field.offset, field.size
                    ));
                }
            }
        }
    }

    Ok(())
}

/// Parse `make_completion` parameter widths from its signature text.
fn parse_function_params(text: &str) -> std::collections::BTreeMap<String, u64> {
    let mut out = std::collections::BTreeMap::new();
    let Some(paren_open) = text.find('(') else {
        return out;
    };
    let Some(paren_close) = text.find(')') else {
        return out;
    };
    let decl = &text[paren_open + 1..paren_close];
    for param in decl.split(',') {
        let param = param.trim();
        // input logic [31:0] ticket
        let Some(bracket_open) = param.find('[') else {
            continue;
        };
        let Some(bracket_close) = param.find(']') else {
            continue;
        };
        let range = &param[bracket_open + 1..bracket_close];
        let Some((high, low)) = range.split_once(':') else {
            continue;
        };
        let Ok(high) = high.trim().parse::<u64>() else {
            continue;
        };
        let Ok(low) = low.trim().parse::<u64>() else {
            continue;
        };
        let width = high.max(low) - high.min(low) + 1;
        if let Some(name) = param[bracket_close + 1..].split_whitespace().next() {
            out.insert(name.trim().to_string(), width);
        }
    }
    out
}

/// Width of a concatenation element: a sized literal like `16'h0` or a named parameter.
fn element_width(elem: &str, params: &std::collections::BTreeMap<String, u64>) -> Option<u64> {
    let elem = elem.trim();
    if let Some(apo) = elem.find('\'') {
        // Sized literal: the part before the apostrophe is the bit width.
        let prefix = &elem[..apo].trim();
        if prefix.is_empty() {
            // Unsized literal ('0) has no known width.
            return None;
        }
        return prefix.parse().ok();
    }
    params.get(elem).copied()
}

/// Parse the `return { ... };` statement inside `make_completion`.
///
/// SystemVerilog concatenation lists elements from MSB to LSB, so the first element
/// occupies the highest bit range. The total width is the sum of element widths.
fn parse_completion_layout(body: &str) -> Option<g6q_core::model::CompletionLayout> {
    let stmt = body
        .split(';')
        .map(str::trim)
        .find(|s| s.starts_with("return"))?;
    let open = stmt.find('{')?;
    let close = stmt.rfind('}')?;
    let inner = &stmt[open + 1..close];
    let elements: Vec<_> = inner.split(',').map(str::trim).collect();

    // The body text starts with the function signature (return type and inputs), so we
    // can recover the parameter widths from the text before the first semicolon.
    let params = parse_function_params(body);

    let mut total = 0u64;
    let mut widths = Vec::with_capacity(elements.len());
    for elem in &elements {
        let w = element_width(elem, &params)?;
        widths.push(w);
        total += w;
    }

    let mut high = total.saturating_sub(1);
    let mut layout = g6q_core::model::CompletionLayout::default();
    for (elem, width) in elements.iter().zip(widths.iter()) {
        let low = high.saturating_sub(*width - 1);
        if *elem == "ticket" {
            layout.ticket_bit_low = low;
            layout.ticket_bit_high = high;
        } else if *elem == "status" {
            layout.status_bit_low = low;
            layout.status_bit_high = high;
        }
        high = low.saturating_sub(1);
    }

    Some(layout)
}

/// Parse the packed `flags` word layout.
///
/// The reference package does not publish localparams for these subfields, but it does expose
/// `desc_prio` (`d.flags[19:16]`) and `desc_irq` (`d.flags[2]`) helper functions, and a comment
/// that says `flags[13:8] type fields (dtype/...)`.  This function recovers what it can; fields
/// not found are left at zero and the layout is still returned so consumers can tell the package
/// was at least examined.
///
/// The arithmetic-type subfields are read from per-field accessors when the package publishes
/// them (`desc_dtype`, `desc_accmode`, `desc_ew`, `desc_sp24`). **An accessor always wins over
/// the comment**, because the comment states one combined span for several ABI fields and
/// extracting it as a data type yields a plausible-looking wrong value. When only the comment
/// exists, `dtype_combined` records that the recovered span is a blob.
fn parse_flags_layout(text: &str) -> Option<g6q_core::model::DescFlagsLayout> {
    use g6q_core::model::FlagField;

    let mut layout = g6q_core::model::DescFlagsLayout::default();
    let mut found = false;

    // Named `FLAG_*_SHIFT` / `FLAG_*_WIDTH` localparams are the published form, and they
    // are preferred over reading an accessor body: an accessor that indexes by constant
    // (`d.flags[FLAG_DTYPE_SHIFT +: FLAG_DTYPE_WIDTH]`) carries no literal range at all,
    // so a range-only reader sees a package that publishes nothing.
    let shift = |n: &str| parse_flag_localparam(text, n);
    let field_from_params = |base: &str| -> Option<FlagField> {
        let s = shift(&format!("FLAG_{base}_SHIFT"))?;
        let w = shift(&format!("FLAG_{base}_WIDTH"))?;
        Some(FlagField::from_range(s + w.saturating_sub(1), s))
    };

    if let (Some(s), Some(w)) = (shift("FLAG_PRIO_SHIFT"), shift("FLAG_PRIO_WIDTH")) {
        layout.priority_shift = s;
        layout.priority_mask = (1u32 << w) - 1;
        found = true;
    }
    if let Some(b) = shift("FLAG_IRQ_SHIFT") {
        layout.irq_bit = b;
        found = true;
    }

    // Helper functions `desc_prio` and `desc_irq` return explicit bit ranges.
    if !found {
        if let Some(body) = extract_function_body(text, "desc_prio") {
            if let Some((_, high, low)) = body.split(';').find_map(parse_return_range) {
                layout.priority_shift = low;
                layout.priority_mask = (1u32 << (high - low + 1)) - 1;
                found = true;
            }
        }
        if let Some(body) = extract_function_body(text, "desc_irq") {
            if let Some(bit) = body.split(';').find_map(parse_return_bit) {
                layout.irq_bit = bit;
                found = true;
            }
        }
    }

    // Per-field arithmetic-type accessors, when the package publishes them.
    let field_from_fn = |name: &str| -> Option<FlagField> {
        let short = name.strip_prefix("desc_").unwrap_or(name).to_uppercase();
        if let Some(f) = field_from_params(&short) {
            return Some(f);
        }
        let body = extract_function_body(text, name)?;
        let (_, high, low) = body.split(';').find_map(parse_return_range)?;
        Some(FlagField::from_range(high, low))
    };

    if let Some(f) = field_from_fn("desc_dtype") {
        layout.dtype_shift = f.shift;
        layout.dtype_mask = f.mask;
        layout.dtype_combined = false;
        found = true;
    } else if let Some((high, low)) = parse_dtype_comment(text) {
        // Fallback: a combined `flags[hi:lo] type fields` comment. Recorded as combined so
        // no consumer reports the blob as a data type.
        layout.dtype_shift = low;
        layout.dtype_mask = (1u32 << (high - low + 1)) - 1;
        layout.dtype_combined = true;
        found = true;
    }

    if let Some(f) = field_from_fn("desc_accmode") {
        layout.accmode = Some(f);
        found = true;
    }
    if let Some(f) = field_from_fn("desc_ew") {
        layout.ew = Some(f);
        found = true;
    }
    if let Some(bit) = shift("FLAG_SP24_SHIFT") {
        layout.sp24_bit = Some(bit);
        found = true;
    } else if let Some(body) = extract_function_body(text, "desc_sp24") {
        if let Some(bit) = body.split(';').find_map(parse_return_bit) {
            layout.sp24_bit = Some(bit);
            found = true;
        }
    }

    if found {
        Some(layout)
    } else {
        None
    }
}

/// Read a `localparam int unsigned FLAG_<NAME> = <n>;` value from the descriptor package.
///
/// Deliberately narrow: only a plain decimal or hex literal is accepted, because a flag
/// position recovered from anything more elaborate would be a guess about the ABI.
fn parse_flag_localparam(text: &str, name: &str) -> Option<u32> {
    // Line-oriented on purpose. Splitting on `;` would fold a preceding `//` comment into
    // the statement, and the live package puts one immediately above the flag block --
    // which silently hid the first constant of the group.
    for line in text.lines() {
        let stmt = line.split("//").next().unwrap_or(line).trim();
        let stmt = stmt.trim_end_matches(';').trim();
        if !stmt.starts_with("localparam") || !stmt.contains(name) {
            continue;
        }
        let (lhs, rhs) = stmt.split_once('=')?;
        let decl = lhs
            .split(|c: char| !(c.is_alphanumeric() || c == '_'))
            .filter(|t| !t.is_empty())
            .next_back()?;
        if decl != name {
            continue;
        }
        let v = rhs.trim().trim_end_matches(';').trim();
        let v = v.rsplit_once('\'').map_or(v, |(_, r)| r);
        let (radix, digits) = match v.strip_prefix(['h', 'H']) {
            Some(d) => (16, d),
            None => (10, v.strip_prefix(['d', 'D']).unwrap_or(v)),
        };
        return u32::from_str_radix(&digits.replace('_', ""), radix).ok();
    }
    None
}

fn parse_return_range(stmt: &str) -> Option<(&str, u32, u32)> {
    // `return d.flags[19:16];`
    let stmt = stmt.trim();
    if !stmt.starts_with("return") {
        return None;
    }
    let bracket_open = stmt.find('[')?;
    let bracket_close = stmt.find(']')?;
    let range = &stmt[bracket_open + 1..bracket_close];
    let (high, low) = range.split_once(':')?;
    let high = high.trim().parse::<u32>().ok()?;
    let low = low.trim().parse::<u32>().ok()?;
    Some(("", high, low))
}

fn parse_return_bit(stmt: &str) -> Option<u32> {
    // `return d.flags[2];`
    let stmt = stmt.trim();
    if !stmt.starts_with("return") {
        return None;
    }
    let bracket_open = stmt.find('[')?;
    let bracket_close = stmt.find(']')?;
    stmt[bracket_open + 1..bracket_close]
        .trim()
        .parse::<u32>()
        .ok()
}

fn parse_dtype_comment(text: &str) -> Option<(u32, u32)> {
    // `// flags[19:16] priority, flags[13:8] type fields (dtype/...)`
    // We want the `type fields` range. A line may contain multiple `flags[...]`
    // clauses, so test the text immediately after each closing `]`.
    for line in text.lines() {
        let mut search = 0;
        while let Some(start) = line[search..].find("flags[") {
            let start = search + start;
            let close = line[start..].find(']')?;
            let close = start + close;
            let range = &line[start + 6..close];
            if let Some((high, low)) = range.split_once(':') {
                let high = high.trim().parse::<u32>().ok()?;
                let low = low.trim().parse::<u32>().ok()?;
                let after = &line[close + 1..];
                let after = if let Some(next) = after.find("flags[") {
                    &after[..next]
                } else {
                    after
                };
                if after.contains("type") || after.contains("dtype") {
                    return Some((high, low));
                }
            }
            search = close + 1;
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_reference_package() {
        let text = r#"
package g6lc_ai_desc_pkg;
  localparam int unsigned DescBytes  = 64;
  localparam logic [15:0] OP_GEMM    = 16'd1;
  localparam logic [15:0] OP_CONV2D  = 16'd2;
  localparam logic [15:0] ST_OK      = 16'd0;
  localparam logic [15:0] ST_ERR     = 16'd1;

  typedef struct packed {
    logic [63:0] ptr_done;
    logic [63:0] ptr_scale;
    logic [63:0] ptr_c;
    logic [63:0] ptr_b;
    logic [63:0] ptr_a;
    logic [31:0] ld_ab;
    logic [31:0] k;
    logic [31:0] n;
    logic [31:0] m;
    logic [31:0] flags;
    logic [15:0] op;
    logic [15:0] version;
  } desc_t;

  function automatic desc_t bits_to_desc(input desc_bits_t b);
    desc_t d;
    d.version   = b[15:0];
    d.op        = b[31:16];
    d.flags     = b[63:32];
    d.m         = b[95:64];
    d.n         = b[127:96];
    d.k         = b[159:128];
    d.ld_ab     = b[191:160];
    d.ptr_a     = b[255:192];
    d.ptr_b     = b[319:256];
    d.ptr_c     = b[383:320];
    d.ptr_scale = b[447:384];
    d.ptr_done  = b[511:448];
    return d;
  endfunction

  // flags[19:16] priority, flags[13:8] type fields (dtype/accmode/ew/sp24)
  function automatic logic [3:0] desc_prio(input desc_t d);
    return d.flags[19:16];
  endfunction

  function automatic logic desc_irq(input desc_t d);
    return d.flags[2];
  endfunction

  function automatic logic [63:0] make_completion(
      input logic [31:0] ticket, input logic [15:0] status
  );
    return {16'h0, status, ticket};
  endfunction
endpackage
"#;
        let layout = parse_ai_desc_pkg(text).unwrap();
        assert_eq!(layout.desc_bytes, 64);
        assert_eq!(layout.op("OP_GEMM"), Some(1));
        assert_eq!(layout.op("OP_CONV2D"), Some(2));
        assert_eq!(layout.status("ST_OK"), Some(0));
        assert_eq!(layout.status("ST_ERR"), Some(1));
        assert_eq!(layout.offset("version"), Some(0));
        assert_eq!(layout.offset("op"), Some(2));
        assert_eq!(layout.offset("flags"), Some(4));
        assert_eq!(layout.offset("m"), Some(8));
        assert_eq!(layout.offset("n"), Some(12));
        assert_eq!(layout.offset("k"), Some(16));
        assert_eq!(layout.offset("ld_ab"), Some(20));
        assert_eq!(layout.offset("ptr_a"), Some(24));
        assert_eq!(layout.offset("ptr_b"), Some(32));
        assert_eq!(layout.offset("ptr_c"), Some(40));
        assert_eq!(layout.offset("ptr_scale"), Some(48));
        assert_eq!(layout.offset("ptr_done"), Some(56));

        let c = layout.completion.unwrap();
        assert_eq!(c.ticket_bit_low, 0);
        assert_eq!(c.ticket_bit_high, 31);
        assert_eq!(c.status_bit_low, 32);
        assert_eq!(c.status_bit_high, 47);

        let f = layout.flags_layout.unwrap();
        assert_eq!(f.dtype_shift, 8);
        assert_eq!(f.dtype_mask, 0x3f);
        assert_eq!(f.priority_shift, 16);
        assert_eq!(f.priority_mask, 0x0f);
        assert_eq!(f.irq_bit, 2);
        // The reference package publishes only a *combined* type-field comment, so the
        // arithmetic-type subfields stay unresolved and the span is marked as a blob.
        assert!(f.dtype_combined, "a comment span is not a data type");
        assert_eq!(f.accmode, None);
        assert_eq!(f.ew, None);
        assert_eq!(f.sp24_bit, None);
        assert!(!f.arith_type_resolved());
    }

    /// Per-field accessors resolve the arithmetic-type subfields individually.
    ///
    /// This is the shape the descriptor ABI actually defines (`isa-encoding.md` §7:
    /// `dtype[9:8]`, `accmode[11:10]`, `ew[13:12]`, `sp24[14]`). Until the design publishes
    /// them, `ew` and `sp24` are invisible and sub-byte / sparse work cannot be requested.
    #[test]
    fn per_field_accessors_resolve_arith_type_and_beat_the_comment() {
        let text = r#"
package g6lc_ai_desc_pkg;
  localparam int unsigned DescBytes = 64;
  localparam logic [15:0] OP_GEMM   = 16'd1;
  localparam logic [15:0] ST_OK     = 16'd0;

  typedef struct packed {
    logic [63:0] ptr_done;
    logic [63:0] ptr_scale;
    logic [63:0] ptr_c;
    logic [63:0] ptr_b;
    logic [63:0] ptr_a;
    logic [31:0] ld_ab;
    logic [31:0] k;
    logic [31:0] n;
    logic [31:0] m;
    logic [31:0] flags;
    logic [15:0] op;
    logic [15:0] version;
  } desc_t;

  function automatic desc_t bits_to_desc(input desc_bits_t b);
    desc_t d;
    d.version   = b[15:0];
    d.op        = b[31:16];
    d.flags     = b[63:32];
    d.m         = b[95:64];
    d.n         = b[127:96];
    d.k         = b[159:128];
    d.ld_ab     = b[191:160];
    d.ptr_a     = b[255:192];
    d.ptr_b     = b[319:256];
    d.ptr_c     = b[383:320];
    d.ptr_scale = b[447:384];
    d.ptr_done  = b[511:448];
    return d;
  endfunction

  // A stale combined comment is still present: flags[13:8] type fields (dtype/accmode/ew)
  function automatic logic [1:0] desc_dtype(input desc_t d);
    return d.flags[9:8];
  endfunction

  function automatic logic [1:0] desc_accmode(input desc_t d);
    return d.flags[11:10];
  endfunction

  function automatic logic [1:0] desc_ew(input desc_t d);
    return d.flags[13:12];
  endfunction

  function automatic logic desc_sp24(input desc_t d);
    return d.flags[14];
  endfunction

  function automatic logic [3:0] desc_prio(input desc_t d);
    return d.flags[19:16];
  endfunction

  function automatic logic desc_irq(input desc_t d);
    return d.flags[2];
  endfunction

  function automatic logic [63:0] make_completion(
      input logic [31:0] ticket, input logic [15:0] status
  );
    return {16'h0, status, ticket};
  endfunction
endpackage
"#;
        let layout = parse_ai_desc_pkg(text).unwrap();
        let f = layout.flags_layout.unwrap();

        // The accessor wins over the comment: dtype is the narrow 2-bit field, not the blob.
        assert_eq!(f.dtype_shift, 8);
        assert_eq!(f.dtype_mask, 0x3, "accessor must beat the combined comment");
        assert!(!f.dtype_combined);

        assert_eq!(f.accmode.unwrap().shift, 10);
        assert_eq!(f.accmode.unwrap().mask, 0x3);
        assert_eq!(f.ew.unwrap().shift, 12);
        assert_eq!(f.ew.unwrap().mask, 0x3);
        assert_eq!(f.sp24_bit, Some(14));
        assert!(f.arith_type_resolved());

        // A descriptor asking for 4-bit elements is now distinguishable from INT8.
        // flags = ew(01) << 12 = 0x1000; the combined-comment reading would have called
        // this "dtype = 16", which is a plausible-looking wrong answer.
        let flags = 0x1000u32;
        assert_eq!(f.ew.unwrap().extract(flags), 1, "ew = 01 is 4-bit");
        assert_eq!((flags >> f.dtype_shift) & f.dtype_mask, 0, "dtype stays 00");
    }

    /// The live design package now publishes every `flags` subfield as a localparam.
    ///
    /// F5 and F10 are closed on the design: `dtype`, `accmode`, `ew` and `sp24` are named
    /// separately instead of sharing one comment span, so a sub-byte or sparse request is
    /// expressible rather than indistinguishable from a mis-set `dtype`.
    #[test]
    fn the_real_desc_package_publishes_every_flag_subfield() {
        let path = std::path::Path::new(r"E:/cva6/corev_apu/ai_island/include/g6lc_ai_desc_pkg.sv");
        if !path.exists() {
            return;
        }
        let text = std::fs::read_to_string(path).unwrap();
        let layout = parse_ai_desc_pkg(&text).unwrap();
        let f = layout
            .flags_layout
            .expect("FLAG_*_SHIFT localparams are published");
        assert_eq!(f.irq_bit, 2);
        assert_eq!(f.priority_shift, 16);
        assert_eq!(f.priority_mask, 0x0f);
        assert!(
            f.arith_type_resolved(),
            "desc_dtype/accmode/ew/sp24 are published; F10 is closed on the design"
        );
        assert!(!f.dtype_combined, "dtype must not be read as a blob");
        assert_eq!(f.dtype_shift, 8);
        assert_eq!(f.dtype_mask, 0x3);
        assert_eq!(f.ew.unwrap().shift, 12);
        assert_eq!(f.sp24_bit, Some(14));
    }

    #[test]
    fn validates_word_order_against_desc_t_comments_and_desc_to_bits() {
        let text = r#"
package g6lc_ai_desc_pkg;
  localparam int unsigned DescBytes  = 64;
  localparam logic [15:0] OP_GEMM    = 16'd1;
  localparam logic [15:0] ST_OK      = 16'd0;

  typedef struct packed {
    logic [63:0] ptr_done;     // +0x38
    logic [63:0] ptr_scale;    // +0x30
    logic [63:0] ptr_c;        // +0x28
    logic [63:0] ptr_b;        // +0x20
    logic [63:0] ptr_a;        // +0x18
    logic [31:0] ld_ab;        // +0x14
    logic [31:0] k;            // +0x10
    logic [31:0] n;            // +0x0C
    logic [31:0] m;            // +0x08
    logic [31:0] flags;        // +0x04
    logic [15:0] op;           // +0x02
    logic [15:0] version;      // +0x00
  } desc_t;

  function automatic desc_t bits_to_desc(input desc_bits_t b);
    desc_t d;
    d.version   = b[15:0];
    d.op        = b[31:16];
    d.flags     = b[63:32];
    d.m         = b[95:64];
    d.n         = b[127:96];
    d.k         = b[159:128];
    d.ld_ab     = b[191:160];
    d.ptr_a     = b[255:192];
    d.ptr_b     = b[319:256];
    d.ptr_c     = b[383:320];
    d.ptr_scale = b[447:384];
    d.ptr_done  = b[511:448];
    return d;
  endfunction

  function automatic desc_bits_t desc_to_bits(input desc_t d);
    desc_bits_t b;
    b = '0;
    b[15:0]    = d.version;
    b[31:16]   = d.op;
    b[63:32]   = d.flags;
    b[95:64]   = d.m;
    b[127:96]  = d.n;
    b[159:128] = d.k;
    b[191:160] = d.ld_ab;
    b[255:192] = d.ptr_a;
    b[319:256] = d.ptr_b;
    b[383:320] = d.ptr_c;
    b[447:384] = d.ptr_scale;
    b[511:448] = d.ptr_done;
    return b;
  endfunction

  function automatic logic [63:0] make_completion(
      input logic [31:0] ticket, input logic [15:0] status
  );
    return {16'h0, status, ticket};
  endfunction
endpackage
"#;
        let layout = parse_ai_desc_pkg(text).unwrap();
        assert_eq!(layout.offset("ptr_done"), Some(56));
        assert_eq!(layout.offset("version"), Some(0));
    }

    #[test]
    fn rejects_desc_t_comment_mismatch() {
        let text = r#"
package g6lc_ai_desc_pkg;
  localparam int unsigned DescBytes  = 64;

  typedef struct packed {
    logic [15:0] version;      // +0x02
  } desc_t;

  function automatic desc_t bits_to_desc(input desc_bits_t b);
    desc_t d;
    d.version = b[15:0];
    return d;
  endfunction
endpackage
"#;
        let err = parse_ai_desc_pkg(text).unwrap_err();
        assert!(err.contains("byte-offset conflict"), "{err}");
    }

    #[test]
    fn rejects_bits_to_desc_desc_to_bits_mismatch() {
        let text = r#"
package g6lc_ai_desc_pkg;
  localparam int unsigned DescBytes  = 64;

  typedef struct packed {
    logic [15:0] version;
  } desc_t;

  function automatic desc_t bits_to_desc(input desc_bits_t b);
    desc_t d;
    d.version = b[15:0];
    return d;
  endfunction

  function automatic desc_bits_t desc_to_bits(input desc_t d);
    desc_bits_t b;
    b = '0;
    b[31:16] = d.version;
    return b;
  endfunction
endpackage
"#;
        let err = parse_ai_desc_pkg(text).unwrap_err();
        assert!(err.contains("word-order conflict"), "{err}");
    }
}
