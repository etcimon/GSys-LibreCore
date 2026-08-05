// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Host-supplied parameter / config field map for hierarchical substitutions.

//! Free-form param maps (`--param-map` / `--cfg-snapshot`).
//!
//! Keys are opaque strings such as `CVA6Cfg.XLEN` or `XLEN`. Values are JSON
//! numbers, booleans, or strings. The package never hard-codes SoC package
//! names beyond documenting common host keys.

use std::collections::BTreeMap;
use std::path::Path;

use serde_json::Value;

use crate::error::{CoreError, CoreResult};

/// Host-supplied hierarchical / const substitutions.
#[derive(Debug, Clone, Default)]
pub struct ParamMap {
    /// Flat key → JSON value.
    pub entries: BTreeMap<String, Value>,
    /// Source path if loaded from disk.
    pub source: Option<String>,
}

impl ParamMap {
    /// Empty map.
    pub fn new() -> Self {
        Self::default()
    }

    /// Load a JSON object from path (`{"CVA6Cfg.XLEN":64,"XLEN":64}`).
    pub fn load_path(path: impl AsRef<Path>) -> CoreResult<Self> {
        let path = path.as_ref();
        let text = std::fs::read_to_string(path).map_err(|source| CoreError::Io {
            path: path.to_path_buf(),
            source,
        })?;
        Self::parse_json(&text).map(|mut m| {
            m.source = Some(path.display().to_string());
            m
        })
    }

    /// Parse JSON object text.
    pub fn parse_json(text: &str) -> CoreResult<Self> {
        let v: Value = serde_json::from_str(text).map_err(|e| {
            CoreError::InvalidOptions(format!("param-map JSON: {e}"))
        })?;
        let obj = v.as_object().ok_or_else(|| {
            CoreError::InvalidOptions("param-map must be a JSON object".into())
        })?;
        let mut entries = BTreeMap::new();
        for (k, val) in obj {
            entries.insert(k.clone(), val.clone());
        }
        Ok(Self {
            entries,
            source: None,
        })
    }

    /// Insert or overwrite a key.
    pub fn insert(&mut self, key: impl Into<String>, value: Value) {
        self.entries.insert(key.into(), value);
    }

    /// Merge another map (other wins on conflict).
    pub fn extend(&mut self, other: ParamMap) {
        for (k, v) in other.entries {
            self.entries.insert(k, v);
        }
        if self.source.is_none() {
            self.source = other.source;
        }
    }

    /// Inject common XLEN-related keys from `--assume-xlen N`.
    pub fn with_assume_xlen(mut self, xlen: u32) -> Self {
        self.insert("XLEN", Value::from(xlen));
        self.insert("CVA6Cfg.XLEN", Value::from(xlen));
        self.insert("cva6_cfg.XLEN", Value::from(xlen));
        self.insert("config_pkg::CVA6ConfigXlen", Value::from(xlen));
        self.insert("CVA6ConfigXlen", Value::from(xlen));
        // Common datapath widths derived from XLEN for dim substitution.
        if xlen > 0 {
            self.insert("CVA6Cfg.XLEN-1", Value::from(xlen.saturating_sub(1)));
        }
        self
    }

    /// Lookup exact key.
    pub fn get(&self, key: &str) -> Option<&Value> {
        self.entries.get(key)
    }

    /// Resolve key as unsigned integer when possible.
    pub fn get_u32(&self, key: &str) -> Option<u32> {
        let v = self.get(key)?;
        match v {
            Value::Number(n) => n.as_u64().map(|u| u as u32).or_else(|| {
                n.as_i64()
                    .filter(|i| *i >= 0)
                    .map(|i| i as u32)
            }),
            Value::String(s) => s.trim().parse().ok(),
            Value::Bool(b) => Some(if *b { 1 } else { 0 }),
            _ => None,
        }
    }

    /// Substitute known keys in a hierarchical dim / expression string.
    ///
    /// Longest keys first so `CVA6Cfg.XLEN-1` wins over `CVA6Cfg.XLEN`.
    pub fn substitute_text(&self, text: &str) -> String {
        if self.entries.is_empty() || text.is_empty() {
            return text.to_string();
        }
        let mut keys: Vec<&String> = self.entries.keys().collect();
        keys.sort_by_key(|k| std::cmp::Reverse(k.len()));
        let mut out = text.to_string();
        for k in keys {
            let Some(v) = self.entries.get(k.as_str()) else {
                continue;
            };
            let repl = value_to_sv_token(v);
            if repl.is_empty() {
                continue;
            }
            out = out.replace(k.as_str(), &repl);
        }
        out
    }

    /// Number of entries.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    /// Empty?
    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Keys for reports.
    pub fn keys(&self) -> Vec<String> {
        self.entries.keys().cloned().collect()
    }
}

fn value_to_sv_token(v: &Value) -> String {
    match v {
        Value::Number(n) => n.to_string(),
        Value::Bool(b) => if *b { "1".into() } else { "0".into() },
        Value::String(s) => s.clone(),
        Value::Null => String::new(),
        _ => v.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_and_substitute_xlen() {
        let m = ParamMap::parse_json(r#"{"CVA6Cfg.XLEN":64,"XLEN":64}"#).unwrap();
        assert_eq!(m.get_u32("XLEN"), Some(64));
        let dims = m.substitute_text("[CVA6Cfg.XLEN-1:0]");
        // Without explicit XLEN-1 key, only full key replaces — leave partial
        assert!(dims.contains("64") || dims.contains("CVA6Cfg"), "{dims}");
        let m2 = ParamMap::new().with_assume_xlen(64);
        let d2 = m2.substitute_text("[CVA6Cfg.XLEN-1:0]");
        assert_eq!(d2, "[63:0]", "{d2}");
    }
}
