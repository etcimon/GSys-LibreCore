// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! A minimal, canonical JSON writer.
//!
//! The package declares no external dependencies (see `AGENTS.md` §3), so serialisation
//! is hand-rolled. That is not a hardship here: the requirement is a *canonical* encoder
//! — sorted keys, normalised numbers, no timestamps — so that re-running the generator on
//! unchanged inputs produces a byte-identical document and `gen --check` is a usable CI
//! gate ([`architecture/IR.md`] §2).
//!
//! Addresses and sizes are deliberately emitted as strings: a JSON number cannot carry a
//! 64-bit address without loss in consumers that parse into a double.
//!
//! [`architecture/IR.md`]: ../../../architecture/IR.md

use std::collections::BTreeMap;
use std::fmt::Write as _;

/// A JSON value.
///
/// Objects use a [`BTreeMap`] so key order is canonical by construction rather than by
/// convention.
#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    /// JSON `null`.
    Null,
    /// JSON `true` / `false`.
    Bool(bool),
    /// A signed integer. Floats are deliberately unsupported: nothing in the model needs
    /// one, and excluding them removes a whole class of non-canonical output.
    Int(i64),
    /// A string.
    Str(String),
    /// An ordered array.
    Arr(Vec<Json>),
    /// An object with canonically ordered keys.
    Obj(BTreeMap<String, Json>),
}

impl Json {
    /// Build an object from an iterator of pairs.
    pub fn obj<I, K>(pairs: I) -> Self
    where
        I: IntoIterator<Item = (K, Json)>,
        K: Into<String>,
    {
        Json::Obj(pairs.into_iter().map(|(k, v)| (k.into(), v)).collect())
    }

    /// Build a string value.
    pub fn str(s: impl Into<String>) -> Self {
        Json::Str(s.into())
    }

    /// Build an array value.
    pub fn arr<I: IntoIterator<Item = Json>>(items: I) -> Self {
        Json::Arr(items.into_iter().collect())
    }

    /// Format a `u64` as a lowercase `0x`-prefixed string, the canonical form for every
    /// address and size in the model.
    pub fn addr(value: u64) -> Self {
        Json::Str(format!("{value:#x}"))
    }

    /// Serialise with two-space indentation and a trailing newline.
    pub fn to_pretty(&self) -> String {
        let mut out = String::new();
        self.write(&mut out, 0);
        out.push('\n');
        out
    }

    fn write(&self, out: &mut String, indent: usize) {
        let pad = "  ".repeat(indent);
        let pad_inner = "  ".repeat(indent + 1);
        match self {
            Json::Null => out.push_str("null"),
            Json::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
            Json::Int(i) => {
                let _ = write!(out, "{i}");
            }
            Json::Str(s) => escape_into(s, out),
            Json::Arr(items) if items.is_empty() => out.push_str("[]"),
            Json::Arr(items) => {
                out.push_str("[\n");
                for (i, item) in items.iter().enumerate() {
                    out.push_str(&pad_inner);
                    item.write(out, indent + 1);
                    if i + 1 < items.len() {
                        out.push(',');
                    }
                    out.push('\n');
                }
                out.push_str(&pad);
                out.push(']');
            }
            Json::Obj(map) if map.is_empty() => out.push_str("{}"),
            Json::Obj(map) => {
                out.push_str("{\n");
                let len = map.len();
                for (i, (k, v)) in map.iter().enumerate() {
                    out.push_str(&pad_inner);
                    escape_into(k, out);
                    out.push_str(": ");
                    v.write(out, indent + 1);
                    if i + 1 < len {
                        out.push(',');
                    }
                    out.push('\n');
                }
                out.push_str(&pad);
                out.push('}');
            }
        }
    }
}

fn escape_into(s: &str, out: &mut String) {
    out.push('"');
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scalars_render() {
        assert_eq!(Json::Null.to_pretty().trim(), "null");
        assert_eq!(Json::Bool(true).to_pretty().trim(), "true");
        assert_eq!(Json::Int(-7).to_pretty().trim(), "-7");
        assert_eq!(Json::str("hi").to_pretty().trim(), "\"hi\"");
    }

    #[test]
    fn addresses_are_lowercase_hex_strings() {
        assert_eq!(Json::addr(0x8000_0000).to_pretty().trim(), "\"0x80000000\"");
        assert_eq!(Json::addr(0).to_pretty().trim(), "\"0x0\"");
    }

    #[test]
    fn object_keys_are_canonically_ordered() {
        // Inserted out of order; must serialise sorted.
        let j = Json::obj([
            ("zulu", Json::Int(1)),
            ("alpha", Json::Int(2)),
            ("mike", Json::Int(3)),
        ]);
        let text = j.to_pretty();
        let a = text.find("alpha").expect("alpha present");
        let m = text.find("mike").expect("mike present");
        let z = text.find("zulu").expect("zulu present");
        assert!(a < m && m < z, "keys not sorted: {text}");
    }

    #[test]
    fn output_is_deterministic() {
        let build = || {
            Json::obj([
                ("b", Json::arr([Json::Int(1), Json::Int(2)])),
                ("a", Json::str("x")),
            ])
        };
        assert_eq!(build().to_pretty(), build().to_pretty());
    }

    #[test]
    fn strings_are_escaped() {
        let j = Json::str("a\"b\\c\nd\te");
        assert_eq!(j.to_pretty().trim(), r#""a\"b\\c\nd\te""#);
    }

    #[test]
    fn empty_containers_are_compact() {
        assert_eq!(Json::arr([]).to_pretty().trim(), "[]");
        assert_eq!(Json::obj([] as [(&str, Json); 0]).to_pretty().trim(), "{}");
    }
}
