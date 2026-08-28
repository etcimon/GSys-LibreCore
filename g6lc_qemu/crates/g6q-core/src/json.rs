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

    /// Look up a key in an object. Returns `Json::Null` if the value is not an object
    /// or the key is absent.
    pub fn get(&self, key: &str) -> &Self {
        match self {
            Json::Obj(m) => m.get(key).unwrap_or(&Json::Null),
            _ => &Json::Null,
        }
    }

    /// Whether this is an empty array or object.
    pub fn is_empty(&self) -> bool {
        match self {
            Json::Arr(v) => v.is_empty(),
            Json::Obj(m) => m.is_empty(),
            _ => false,
        }
    }

    /// If this is an array, return its items.
    pub fn as_array(&self) -> Option<&[Self]> {
        match self {
            Json::Arr(v) => Some(v),
            _ => None,
        }
    }

    /// If this is `null`, return true.
    pub fn is_null(&self) -> bool {
        matches!(self, Json::Null)
    }

    /// If this is a string, return its value.
    pub fn as_string(&self) -> Option<&str> {
        match self {
            Json::Str(s) => Some(s),
            _ => None,
        }
    }

    /// Parse a JSON text into a [`Json`] value.
    ///
    /// This is a small, zero-dependency parser sufficient for the package's own
    /// canonical output. It handles objects, arrays, strings, integers, booleans
    /// and `null`. Floats and escapes beyond the basic control characters are not
    /// supported because the model never emits them.
    pub fn parse(s: &str) -> Result<Self, String> {
        let mut p = Parser { src: s, pos: 0 };
        p.skip_ws();
        let v = p.value()?;
        p.skip_ws();
        if p.pos != p.src.len() {
            return Err(format!("trailing JSON at offset {}", p.pos));
        }
        Ok(v)
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

#[allow(clippy::needless_lifetimes)]
struct Parser<'a> {
    src: &'a str,
    pos: usize,
}

#[allow(clippy::needless_lifetimes)]
impl<'a> Parser<'a> {
    fn peek(&self) -> Option<char> {
        self.src[self.pos..].chars().next()
    }

    fn advance(&mut self) -> Option<char> {
        let ch = self.peek()?;
        self.pos += ch.len_utf8();
        Some(ch)
    }

    fn skip_ws(&mut self) {
        while let Some(c) = self.peek() {
            if c.is_whitespace() {
                self.advance();
            } else {
                break;
            }
        }
    }

    fn expect(&mut self, ch: char) -> Result<(), String> {
        match self.peek() {
            Some(c) if c == ch => {
                self.advance();
                Ok(())
            }
            _ => Err(format!("expected `{ch}` at offset {}", self.pos)),
        }
    }

    fn value(&mut self) -> Result<Json, String> {
        self.skip_ws();
        match self.peek() {
            Some('{') => self.object(),
            Some('[') => self.array(),
            Some('"') => self.string(),
            Some('t') | Some('f') => self.bool(),
            Some('n') => self.null(),
            Some(c) if c == '-' || c.is_ascii_digit() => self.number(),
            _ => Err(format!("unexpected JSON at offset {}", self.pos)),
        }
    }

    fn object(&mut self) -> Result<Json, String> {
        self.expect('{')?;
        let mut map = BTreeMap::new();
        self.skip_ws();
        if self.peek() == Some('}') {
            self.advance();
            return Ok(Json::Obj(map));
        }
        loop {
            self.skip_ws();
            let Json::Str(key) = self.string()? else {
                return Err("object key must be a string".to_string());
            };
            self.skip_ws();
            self.expect(':')?;
            let val = self.value()?;
            map.insert(key, val);
            self.skip_ws();
            match self.peek() {
                Some(',') => {
                    self.advance();
                    continue;
                }
                Some('}') => {
                    self.advance();
                    break;
                }
                _ => return Err(format!("expected `,` or `}}` at offset {}", self.pos)),
            }
        }
        Ok(Json::Obj(map))
    }

    fn array(&mut self) -> Result<Json, String> {
        self.expect('[')?;
        let mut items = Vec::new();
        self.skip_ws();
        if self.peek() == Some(']') {
            self.advance();
            return Ok(Json::Arr(items));
        }
        loop {
            items.push(self.value()?);
            self.skip_ws();
            match self.peek() {
                Some(',') => {
                    self.advance();
                    continue;
                }
                Some(']') => {
                    self.advance();
                    break;
                }
                _ => return Err(format!("expected `,` or `]` at offset {}", self.pos)),
            }
        }
        Ok(Json::Arr(items))
    }

    fn string(&mut self) -> Result<Json, String> {
        self.expect('"')?;
        let mut out = String::new();
        loop {
            match self.advance() {
                Some('"') => return Ok(Json::Str(out)),
                Some('\\') => match self.advance() {
                    Some('"') => out.push('"'),
                    Some('\\') => out.push('\\'),
                    Some('/') => out.push('/'),
                    Some('b') => out.push('\u{0008}'),
                    Some('f') => out.push('\u{000c}'),
                    Some('n') => out.push('\n'),
                    Some('r') => out.push('\r'),
                    Some('t') => out.push('\t'),
                    Some('u') => {
                        let mut code = String::new();
                        for _ in 0..4 {
                            if let Some(c) = self.advance() {
                                code.push(c);
                            } else {
                                return Err("truncated \\u escape".to_string());
                            }
                        }
                        let n = u32::from_str_radix(&code, 16)
                            .map_err(|_| format!("bad \\u escape `{code}`"))?;
                        if let Some(c) = char::from_u32(n) {
                            out.push(c);
                        } else {
                            return Err(format!("invalid unicode scalar {n}"));
                        }
                    }
                    other => return Err(format!("bad escape `\\{other:?}`")),
                },
                Some(c) => out.push(c),
                None => return Err("unterminated string".to_string()),
            }
        }
    }

    fn bool(&mut self) -> Result<Json, String> {
        if self.src[self.pos..].starts_with("true") {
            self.pos += 4;
            Ok(Json::Bool(true))
        } else if self.src[self.pos..].starts_with("false") {
            self.pos += 5;
            Ok(Json::Bool(false))
        } else {
            Err(format!("bad boolean at offset {}", self.pos))
        }
    }

    fn null(&mut self) -> Result<Json, String> {
        if self.src[self.pos..].starts_with("null") {
            self.pos += 4;
            Ok(Json::Null)
        } else {
            Err(format!("bad null at offset {}", self.pos))
        }
    }

    fn number(&mut self) -> Result<Json, String> {
        let start = self.pos;
        if self.peek() == Some('-') {
            self.advance();
        }
        while let Some(c) = self.peek() {
            if c.is_ascii_digit() {
                self.advance();
            } else {
                break;
            }
        }
        let text = &self.src[start..self.pos];
        text.parse::<i64>()
            .map(Json::Int)
            .map_err(|_| format!("bad integer `{text}`"))
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

    #[test]
    fn parse_round_trips_canonical_output() {
        let j = Json::obj([
            ("order", Json::Int(0)),
            ("hart", Json::Int(0)),
            ("pc_rdata", Json::Int(0x8000_0000i64)),
            ("pc_wdata", Json::Int(0x8000_0004i64)),
            ("insn", Json::Int(0xdead_beefi64)),
            ("trap", Json::Bool(false)),
            ("rd_addr", Json::Int(0)),
            ("rd_wdata", Json::Int(0)),
        ]);
        let text = j.to_pretty();
        let parsed = Json::parse(&text).unwrap();
        assert_eq!(parsed, j);
    }
}
