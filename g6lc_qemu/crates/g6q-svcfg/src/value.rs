// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Configuration values and the expression forms that produce them.
//!
//! A survey of the real target packages this reader is written against found exactly
//! **five** expression forms inside a configuration struct literal, and no arithmetic:
//!
//! | Form | Example | Becomes |
//! |---|---|---|
//! | cast | `unsigned'(8)`, `bit'(1)`, `int'(16)`, `1024'({…})` | the cast operand |
//! | sized literal | `1'b1`, `32'd16`, `64'h8000_0000` | [`Value::Bool`] / [`Value::Int`] |
//! | scoped enum | `config_pkg::TAGE_LITE` | [`Value::Enum`] |
//! | aggregate | `{64{64'h0}}`, `{64'h8000_0000, 64'h0}` | [`Value::List`] |
//! | identifier | `CVA6ConfigXlen`, `ai_cfg` | the referent |
//!
//! Arithmetic is therefore **not** implemented. That is a deliberate limit, not an
//! oversight: an expression the reader does not understand becomes
//! [`Value::Unresolved`] carrying its own source text, so a future package that
//! introduces arithmetic shows up as a visible unresolved field rather than as a wrong
//! number. Adding evaluation later is a small, deliberate change; silently guessing is
//! not recoverable.

use std::collections::BTreeMap;
use std::fmt;

/// A configuration field value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Value {
    /// A boolean flag, from `1'b1` / `1'b0` or a `bit'(…)` cast of 0/1.
    Bool(bool),
    /// An integer.
    Int(i64),
    /// A symbolic enum member, carried **by name**. A renumbered enum must not silently
    /// change meaning, so the numeric value is never resolved here.
    Enum(String),
    /// A nested struct literal.
    Struct(BTreeMap<String, Value>),
    /// A concatenation or replication, e.g. a packed list of region base addresses.
    List(Vec<Value>),
    /// The reader could not determine the value. Carries the original source text.
    ///
    /// This is never a silent default. Whether it *blocks* anything depends on whether a
    /// consumer actually reads the field: an unresolved field nobody uses is harmless
    /// and is simply carried, while an unresolved field backing a capability produces an
    /// `unresolved` conformance verdict.
    Unresolved(String),
}

impl Value {
    /// Interpret as a boolean, accepting `0` / `1` integers.
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

    /// The enum member name, if this is one.
    pub fn as_enum(&self) -> Option<&str> {
        match self {
            Value::Enum(s) => Some(s.as_str()),
            _ => None,
        }
    }

    /// The nested struct, if this is one.
    pub fn as_struct(&self) -> Option<&BTreeMap<String, Value>> {
        match self {
            Value::Struct(m) => Some(m),
            _ => None,
        }
    }

    /// Whether the reader failed to determine this value.
    pub fn is_unresolved(&self) -> bool {
        matches!(self, Value::Unresolved(_))
    }

    /// A short, stable rendering for reports.
    pub fn describe(&self) -> String {
        match self {
            Value::Bool(b) => b.to_string(),
            Value::Int(i) => i.to_string(),
            Value::Enum(s) => s.clone(),
            Value::Struct(m) => format!("{{{} fields}}", m.len()),
            Value::List(v) => format!("[{} items]", v.len()),
            Value::Unresolved(t) => format!("<unresolved: {t}>"),
        }
    }
}

impl fmt::Display for Value {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.describe())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bool_accepts_integer_forms() {
        assert_eq!(Value::Bool(true).as_bool(), Some(true));
        assert_eq!(Value::Int(0).as_bool(), Some(false));
        assert_eq!(Value::Int(3).as_bool(), Some(true));
        assert_eq!(Value::Enum("X".into()).as_bool(), None);
    }

    #[test]
    fn enum_members_are_not_numbers() {
        // Carried by name so a renumbered enum cannot silently change meaning.
        let v = Value::Enum("TAGE_LITE".into());
        assert_eq!(v.as_enum(), Some("TAGE_LITE"));
        assert_eq!(v.as_int(), None);
    }

    #[test]
    fn unresolved_keeps_its_source_text() {
        let v = Value::Unresolved("Foo * 2".into());
        assert!(v.is_unresolved());
        assert!(v.describe().contains("Foo * 2"));
    }

    #[test]
    fn describe_is_stable_for_containers() {
        assert_eq!(Value::List(vec![Value::Int(1)]).describe(), "[1 items]");
        let mut m = BTreeMap::new();
        m.insert("a".to_string(), Value::Int(1));
        assert_eq!(Value::Struct(m).describe(), "{1 fields}");
    }
}
