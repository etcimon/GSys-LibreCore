// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! `g6q-svcfg` — the configuration-package reader.
//!
//! The inputs are a small number of stylistically uniform SystemVerilog package files:
//! `localparam` scalars and one named struct literal per target. A full SystemVerilog
//! parser is a large dependency for that job, so this reader is **deliberately narrow**
//! ([`architecture/INGEST.md`] §2).
//!
//! The property that makes a narrow reader safe is that **it fails loudly**. Anything it
//! cannot resolve becomes [`Value::Unresolved`] rather than a default, and strict
//! conformance treats that as fatal. A reader that guesses is worse than one that stops,
//! because a guessed configuration produces a *plausible* wrong emulator.
//!
//! # Stage
//!
//! Q0 provides the value model, the tokenizer for struct-literal members, and the
//! `unresolved` discipline. Q1 adds parameter resolution, enum handling, arithmetic and
//! the legality validator; if the narrow approach proves brittle the recorded escalation
//! is to vendor a full parser rather than accumulate special cases.
//!
//! [`architecture/INGEST.md`]: ../../../architecture/INGEST.md

#![forbid(unsafe_code)]

use std::collections::BTreeMap;
use std::fmt;

/// A configuration field value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Value {
    /// A boolean flag (`1'b1`, `1`, `0`).
    Bool(bool),
    /// An integer.
    Int(i64),
    /// A symbolic enum member, carried by name rather than by numeric value so that a
    /// renumbered enum cannot silently change meaning.
    Enum(String),
    /// A nested struct literal.
    Struct(BTreeMap<String, Value>),
    /// The reader could not determine the value. Never a silent default.
    Unresolved(String),
}

impl Value {
    /// Interpret as a boolean where the source may have used `0` / `1`.
    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Value::Bool(b) => Some(*b),
            Value::Int(0) => Some(false),
            Value::Int(_) => Some(true),
            _ => None,
        }
    }

    /// Interpret as an integer.
    pub fn as_int(&self) -> Option<i64> {
        match self {
            Value::Int(i) => Some(*i),
            Value::Bool(b) => Some(*b as i64),
            _ => None,
        }
    }

    /// Whether this value blocks strict conformance.
    pub fn is_unresolved(&self) -> bool {
        matches!(self, Value::Unresolved(_))
    }
}

impl fmt::Display for Value {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Value::Bool(b) => write!(f, "{b}"),
            Value::Int(i) => write!(f, "{i}"),
            Value::Enum(s) => write!(f, "{s}"),
            Value::Struct(_) => write!(f, "<struct>"),
            Value::Unresolved(why) => write!(f, "<unresolved: {why}>"),
        }
    }
}

/// A resolved configuration: field name to value, in canonical order.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Config {
    /// Fields, sorted by name.
    pub fields: BTreeMap<String, Value>,
}

impl Config {
    /// An empty configuration.
    pub fn new() -> Self {
        Self::default()
    }

    /// Insert a field.
    pub fn set(&mut self, name: impl Into<String>, value: Value) {
        self.fields.insert(name.into(), value);
    }

    /// Look up a field.
    pub fn get(&self, name: &str) -> Option<&Value> {
        self.fields.get(name)
    }

    /// A field's boolean interpretation, or `false` when absent.
    ///
    /// Absent is *not* the same as unresolved: a field the design does not have is
    /// legitimately off, whereas a field the reader could not parse is reported by
    /// [`Config::unresolved`].
    pub fn flag(&self, name: &str) -> bool {
        self.get(name).and_then(Value::as_bool).unwrap_or(false)
    }

    /// A field's integer interpretation, or `default` when absent.
    pub fn int_or(&self, name: &str, default: i64) -> i64 {
        self.get(name).and_then(Value::as_int).unwrap_or(default)
    }

    /// Every field the reader could not determine.
    pub fn unresolved(&self) -> Vec<&str> {
        self.fields
            .iter()
            .filter(|(_, v)| v.is_unresolved())
            .map(|(k, _)| k.as_str())
            .collect()
    }
}

/// Parse the members of a named struct literal body.
///
/// Accepts the `Field: value,` form used by configuration packages. Values that are not
/// obviously an integer, a sized literal, a boolean or an identifier become
/// [`Value::Unresolved`] carrying the original text, so nothing is lost and nothing is
/// guessed.
///
/// Q1 extends this with parameter substitution and arithmetic; the shape of the output
/// does not change.
pub fn parse_struct_members(body: &str) -> Config {
    let mut cfg = Config::new();
    for member in split_members(body) {
        let Some((name, raw)) = member.split_once(':') else {
            continue;
        };
        let name = name.trim();
        let raw = raw.trim();
        if name.is_empty() || raw.is_empty() {
            continue;
        }
        cfg.set(name, parse_value(raw));
    }
    cfg
}

/// Split a struct-literal body on top-level commas, respecting nesting and comments.
fn split_members(body: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut depth = 0i32;
    let mut chars = body.chars().peekable();
    while let Some(c) = chars.next() {
        // Strip `//` line comments.
        if c == '/' && chars.peek() == Some(&'/') {
            for n in chars.by_ref() {
                if n == '\n' {
                    break;
                }
            }
            cur.push('\n');
            continue;
        }
        match c {
            '{' | '(' | '[' => {
                depth += 1;
                cur.push(c);
            }
            '}' | ')' | ']' => {
                depth -= 1;
                cur.push(c);
            }
            ',' if depth == 0 => {
                out.push(std::mem::take(&mut cur));
            }
            _ => cur.push(c),
        }
    }
    if !cur.trim().is_empty() {
        out.push(cur);
    }
    out.into_iter().filter(|m| !m.trim().is_empty()).collect()
}

fn parse_value(raw: &str) -> Value {
    let raw = raw.trim();

    if let Some(v) = parse_sized_literal(raw) {
        return v;
    }
    if raw == "'0" {
        return Value::Int(0);
    }
    if raw == "'1" {
        return Value::Int(-1);
    }
    if let Ok(i) = raw.replace('_', "").parse::<i64>() {
        return Value::Int(i);
    }
    if let Some(hex) = raw.strip_prefix("0x").or_else(|| raw.strip_prefix("0X")) {
        if let Ok(i) = i64::from_str_radix(&hex.replace('_', ""), 16) {
            return Value::Int(i);
        }
    }
    if raw.starts_with('{') {
        return Value::Struct(parse_struct_members(raw.trim_matches(['{', '}']).trim()).fields);
    }
    if is_identifier(raw) {
        return Value::Enum(raw.to_string());
    }
    Value::Unresolved(raw.to_string())
}

/// Parse `<width>'<base><digits>`, e.g. `1'b1`, `32'd16`, `64'h8000_0000`.
fn parse_sized_literal(raw: &str) -> Option<Value> {
    let (_, rest) = raw.split_once('\'')?;
    let mut it = rest.chars();
    let base = it.next()?;
    let digits: String = it.collect::<String>().replace('_', "");
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
    let v = i64::from_str_radix(&digits, radix).ok()?;
    if radix == 2 && digits.len() == 1 {
        return Some(Value::Bool(v != 0));
    }
    Some(Value::Int(v))
}

fn is_identifier(s: &str) -> bool {
    let mut chars = s.chars();
    match chars.next() {
        Some(c) if c.is_ascii_alphabetic() || c == '_' => {}
        _ => return false,
    }
    chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sized_literals_resolve() {
        assert_eq!(parse_value("1'b1"), Value::Bool(true));
        assert_eq!(parse_value("1'b0"), Value::Bool(false));
        assert_eq!(parse_value("32'd16"), Value::Int(16));
        assert_eq!(parse_value("64'h8000_0000"), Value::Int(0x8000_0000));
    }

    #[test]
    fn plain_and_hex_integers_resolve() {
        assert_eq!(parse_value("64"), Value::Int(64));
        assert_eq!(parse_value("0x40"), Value::Int(0x40));
        assert_eq!(parse_value("'0"), Value::Int(0));
    }

    #[test]
    fn enum_members_keep_their_name() {
        // Carried by name: a renumbered enum must not silently change meaning.
        assert_eq!(parse_value("GSHARE"), Value::Enum("GSHARE".into()));
    }

    #[test]
    fn anything_unrecognised_is_unresolved_not_defaulted() {
        let v = parse_value("SomeParam * 2 + 1");
        assert!(v.is_unresolved(), "{v:?}");
        match v {
            Value::Unresolved(text) => assert!(text.contains('*')),
            other => panic!("expected Unresolved, got {other:?}"),
        }
    }

    #[test]
    fn struct_members_parse_with_comments_and_nesting() {
        let body = "\
            XLEN: 64,            // register width\n\
            RVC: 1'b1,\n\
            BPType: TAGE_LITE,\n\
            BTBEntries: 32,\n\
            AiCfg: { MatrixEn: 1'b1, TileM: 8 },\n\
            Weird: FOO * BAR,\n";
        let cfg = parse_struct_members(body);

        assert_eq!(cfg.int_or("XLEN", 0), 64);
        assert!(cfg.flag("RVC"));
        assert_eq!(cfg.get("BPType"), Some(&Value::Enum("TAGE_LITE".into())));
        assert_eq!(cfg.int_or("BTBEntries", 0), 32);

        match cfg.get("AiCfg") {
            Some(Value::Struct(inner)) => {
                assert_eq!(inner.get("TileM"), Some(&Value::Int(8)));
                assert_eq!(inner.get("MatrixEn"), Some(&Value::Bool(true)));
            }
            other => panic!("nested struct not parsed: {other:?}"),
        }

        assert_eq!(cfg.unresolved(), vec!["Weird"]);
    }

    #[test]
    fn absent_is_off_but_unresolved_is_reported() {
        let mut cfg = Config::new();
        cfg.set("Present", Value::Bool(true));
        cfg.set("Broken", Value::Unresolved("??".into()));

        assert!(cfg.flag("Present"));
        assert!(
            !cfg.flag("NeverHeardOf"),
            "an absent field is legitimately off"
        );
        assert_eq!(cfg.unresolved(), vec!["Broken"]);
        assert_eq!(cfg.int_or("NeverHeardOf", 7), 7);
    }

    #[test]
    fn field_order_is_canonical() {
        let cfg = parse_struct_members("Zulu: 1, Alpha: 2, Mike: 3,");
        let names: Vec<_> = cfg.fields.keys().cloned().collect();
        assert_eq!(names, ["Alpha", "Mike", "Zulu"]);
    }
}
