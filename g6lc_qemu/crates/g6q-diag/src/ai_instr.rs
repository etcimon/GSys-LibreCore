// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! AI instruction package (`g6lc_ai_instr_pkg.sv`) reader.
//!
//! Extracts the custom-2 opcode, the queue CSRs, and the match values for the queue
//! instructions (`ai.enq`, `ai.poll`, `ai.qfence`) from the design's own package.

pub use g6q_core::model::AiInstrSet;

/// Parse an AI instruction package and return the derived `AiInstrSet`.
pub fn parse_ai_instr_pkg(text: &str) -> Result<AiInstrSet, String> {
    let cleaned = strip_sv_comments(text);

    let mut set = AiInstrSet::default();

    for stmt in cleaned.split(';') {
        let stmt = stmt.trim();
        if let Some((name, value)) = parse_localparam(stmt) {
            match name.as_str() {
                "OpcodeCustom2" => set.opcode_custom2 = value as u32,
                "MaskF7F3Op" => set.mask_f7f3op = value as u32,
                "CSR_AIQBASE" => set.csr_aiqbase = value as u16,
                "CSR_AIQCTL" => set.csr_aiqctl = value as u16,
                "CSR_AIQHEAD" => set.csr_aiqhead = value as u16,
                _ => {}
            }
        }
    }

    let array_body = extract_copro_array(&cleaned).unwrap_or_default();
    let opcode_custom2 = set.opcode_custom2;
    for entry in split_top_level(&array_body, ',') {
        if let Some((opname, f7, f3)) = parse_copro_entry(&entry, opcode_custom2) {
            let m = mk_match(f7, f3, opcode_custom2);
            match opname.as_str() {
                "AI_ENQ" => set.match_enq = m,
                "AI_POLL" => set.match_poll = m,
                "AI_QFENCE" => set.match_qfence = m,
                _ => {}
            }
        }
    }

    Ok(set)
}

fn strip_sv_comments(text: &str) -> String {
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

fn parse_localparam(line: &str) -> Option<(String, i64)> {
    let line = line.trim();
    let rest = line.strip_prefix("localparam")?;
    if !rest.starts_with(char::is_whitespace) {
        return None;
    }
    let rest = rest.trim_start();
    let (lhs, value) = split_top_level_assign(rest)?;
    // The name is the last whitespace-separated word on the left; strip any
    // trailing type bracket like `logic [6:0]` by taking the last identifier.
    let name = lhs
        .split(|c: char| !(c.is_alphanumeric() || c == '_'))
        .filter(|t| !t.is_empty())
        .next_back()?
        .to_string();
    let v = eval_field(value)?;
    Some((name, v))
}

fn split_top_level_assign(s: &str) -> Option<(&str, &str)> {
    let b: Vec<char> = s.chars().collect();
    let mut depth = 0i32;
    for (i, c) in b.iter().enumerate() {
        match c {
            '{' | '(' | '[' => depth += 1,
            '}' | ')' | ']' => depth -= 1,
            '=' if depth == 0 => {
                let byte = s.char_indices().nth(i)?.0;
                return Some((&s[..byte], &s[byte + 1..]));
            }
            _ => {}
        }
    }
    None
}

fn parse_sized_literal(raw: &str) -> Option<i64> {
    let raw = raw.trim();
    let (width, rest) = raw.split_once('\'')?;
    let width: usize = width.trim().parse().ok()?;
    let mut chars = rest.chars();
    let base = chars.next()?;
    let digits: String = chars.collect::<String>().replace('_', "");
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
    let v = u128::from_str_radix(&digits, radix).ok()?;
    if width > 64 || v > i64::MAX as u128 {
        return None;
    }
    Some(v as i64)
}

fn eval_field(raw: &str) -> Option<i64> {
    let raw = raw.trim().trim_end_matches(';');
    parse_sized_literal(raw)
}

fn extract_copro_array(text: &str) -> Option<String> {
    let needle = "copro_issue_resp_t CoproInstr[NbInstr]";
    let start = text.find(needle)?;
    let after = &text[start..];
    let eq = after.find('=')?;
    let body_start = start + eq + 1;
    let mut depth = 0;
    let mut out = String::new();
    let mut in_str = false;
    for c in text[body_start..].chars() {
        match c {
            '{' => {
                depth += 1;
                if depth == 1 {
                    continue;
                }
            }
            '}' => {
                depth -= 1;
                if depth == 0 {
                    break;
                }
            }
            '"' => in_str = !in_str,
            _ => {}
        }
        out.push(c);
    }
    Some(out)
}

fn split_top_level(s: &str, sep: char) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut depth = 0i32;
    for c in s.chars() {
        match c {
            '{' | '(' | '[' => {
                depth += 1;
                cur.push(c);
            }
            '}' | ')' | ']' => {
                depth -= 1;
                cur.push(c);
            }
            c if c == sep && depth == 0 => out.push(std::mem::take(&mut cur)),
            _ => cur.push(c),
        }
    }
    if !cur.trim().is_empty() {
        out.push(cur);
    }
    out
}

fn parse_copro_entry(entry: &str, _opcode_custom2: u32) -> Option<(String, u8, u8)> {
    let entry = entry.trim();
    if !entry.contains("mk_instr") {
        return None;
    }
    let f7 = extract_mk_arg(entry, 0)?;
    let f3 = extract_mk_arg(entry, 1)?;
    let op = entry
        .lines()
        .filter_map(|l| {
            let l = l.trim();
            l.strip_prefix("opcode:").map(str::trim).map(str::to_string)
        })
        .next_back()?;
    Some((op, f7, f3))
}

fn extract_mk_arg(entry: &str, idx: usize) -> Option<u8> {
    let s = entry.find("mk_instr(")?;
    let close = entry[s..].find(')')?;
    let inner = &entry[s + 9..s + close];
    let arg = split_top_level(inner, ',').get(idx)?.trim().to_string();
    Some(parse_sized_literal(&arg)? as u8)
}

fn mk_match(f7: u8, f3: u8, opcode: u32) -> u32 {
    ((f7 as u32) << 25) | ((f3 as u32) << 12) | opcode
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_reference_instr_package() {
        let text = r#"
package g6lc_ai_instr_pkg;
  localparam logic [6:0] OpcodeCustom2 = 7'b1011011;
  localparam logic [11:0] CSR_AIQBASE = 12'h5C0;
  localparam logic [11:0] CSR_AIQCTL  = 12'h5C1;
  localparam logic [11:0] CSR_AIQHEAD = 12'h5C2;
  localparam logic [31:0] MaskF7F3Op =
      32'b1111111_00000_00000_111_00000_1111111;

  function automatic logic [31:0] mk_instr(input logic [6:0] f, input logic [2:0] g);
    return {f, 5'b0, 5'b0, g, 5'b0, OpcodeCustom2};
  endfunction

  parameter int unsigned NbInstr = 3;
  parameter copro_issue_resp_t CoproInstr[NbInstr] = '{
      '{
          instr: mk_instr(7'b0000000, 3'b101),
          mask: MaskF7F3Op,
          resp: '{accept: 1'b1, writeback: 1'b1, register_read: 3'b001},
          opcode: AI_ENQ
      },
      '{
          instr: mk_instr(7'b0000001, 3'b101),
          mask: MaskF7F3Op,
          resp: '{accept: 1'b1, writeback: 1'b1, register_read: 3'b001},
          opcode: AI_POLL
      },
      '{
          instr: mk_instr(7'b0000010, 3'b101),
          mask: MaskF7F3Op,
          resp: '{accept: 1'b1, writeback: 1'b0, register_read: 3'b000},
          opcode: AI_QFENCE
      }
  };
endpackage
"#;
        let set = parse_ai_instr_pkg(text).unwrap();
        assert_eq!(set.opcode_custom2, 0x5B);
        assert_eq!(set.csr_aiqbase, 0x5C0);
        assert_eq!(set.csr_aiqctl, 0x5C1);
        assert_eq!(set.csr_aiqhead, 0x5C2);
        assert_eq!(set.mask_f7f3op, 0xFE00707F);
        assert_eq!(set.match_enq, 0x0000505B);
        assert_eq!(set.match_poll, 0x0200505B);
        assert_eq!(set.match_qfence, 0x0400505B);
    }

    #[test]
    fn parses_real_ai_instr_pkg_if_present() {
        let path = std::path::Path::new(r"E:/cva6/core/cvxif_g6lc_ai/include/g6lc_ai_instr_pkg.sv");
        if !path.exists() {
            return;
        }
        let text = std::fs::read_to_string(path).unwrap();
        let set = parse_ai_instr_pkg(&text).unwrap();
        assert_eq!(set.opcode_custom2, 0x5B);
        assert_eq!(set.csr_aiqbase, 0x5C0);
        assert!(set.match_enq != 0);
    }
}
