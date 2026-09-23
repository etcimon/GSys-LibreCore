// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Dimension text to a bit count. Struct types stay unresolved.

//! One width rule: integer `[hi:lo]`, or `[IDENT-1:0]` with an integer default.
//! `[IDENT-1:1]` stays unresolved.

use std::collections::BTreeMap;

/// Bit width of dimension source text.
///
/// Empty text is a scalar, 1 bit. Several ranges multiply. Any range this
/// rule does not recognize makes the whole text unresolved.
pub fn bit_width(text: &str, defaults: &BTreeMap<String, i64>) -> Option<u32> {
    let text = text.trim();
    if text.is_empty() {
        return Some(1);
    }
    let mut product = 1u32;
    let mut saw = false;
    let bytes = text.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] != b'[' {
            i += 1;
            continue;
        }
        let start = i + 1;
        let end = text[start..].find(']')? + start;
        saw = true;
        let width = range_width(text[start..end].trim(), defaults)?;
        product = product.checked_mul(width)?;
        i = end + 1;
    }
    if saw {
        Some(product)
    } else {
        None
    }
}

fn range_width(body: &str, defaults: &BTreeMap<String, i64>) -> Option<u32> {
    let (hi, lo) = body.split_once(':')?;
    let hi = hi.trim().replace(' ', "");
    let lo = lo.trim().replace(' ', "");
    if let (Ok(high), Ok(low)) = (hi.parse::<i64>(), lo.parse::<i64>()) {
        let span = high.abs_diff(low) + 1;
        return u32::try_from(span).ok();
    }
    if lo == "0" {
        let name = hi.strip_suffix("-1")?.trim();
        let value = *defaults.get(name)?;
        if value >= 1 {
            return u32::try_from(value).ok();
        }
    }
    None
}

/// `logic`, `bit`, `reg`, and `wire` take the dimension rule. Other types do not.
pub fn builtin_net(type_name: &str) -> bool {
    matches!(type_name, "logic" | "bit" | "reg" | "wire")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn defaults() -> BTreeMap<String, i64> {
        BTreeMap::from([("DEPTH".into(), 48), ("WIDTH".into(), 64)])
    }

    #[test]
    fn integer_range_and_ident_minus_one_to_zero() {
        let map = defaults();
        assert_eq!(bit_width("[63:0]", &map), Some(64));
        assert_eq!(bit_width("[DEPTH-1:0][WIDTH-1:0]", &map), Some(48 * 64));
        assert_eq!(bit_width("[DEPTH-1:1]", &map), None);
        assert_eq!(bit_width("", &map), Some(1));
    }
}
