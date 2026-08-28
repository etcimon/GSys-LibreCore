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
/// `OP_*`, `ST_*` and `DescBytes` naming used by the package, and the `bits_to_desc`
/// function body to recover field bit ranges.
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
    let needle = format!("function automatic desc_t {name}");
    let start = text.find(&needle)?;
    let after_sig = text[start..]
        .find('(')
        .and_then(|_| text[start..].find(';'))?;
    let body_start = start + after_sig + 1;
    let mut depth = 0;
    let mut out = String::new();
    for c in text[body_start..].chars() {
        match c {
            'b' => {
                // cheap begin/end tracking
                if text[body_start..body_start + out.len() + 1].ends_with("begin") {
                    depth += 1;
                }
            }
            'd' => {
                if depth > 0 && text[body_start..body_start + out.len() + 1].ends_with("end") {
                    depth -= 1;
                    if depth == 0 {
                        break;
                    }
                }
            }
            _ => {}
        }
        out.push(c);
    }
    Some(out)
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
    }
}
