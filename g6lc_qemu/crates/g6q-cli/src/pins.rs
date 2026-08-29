// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Minimal TOML-section reader for `pins.toml`.
//!
//! The package deliberately has no external crate dependencies, so this is a small,
//! purpose-built parser that knows enough to read the top-level tables declared in
//! `pins.toml` (`[package]`, `[toolchain]`, `[qemu]`, `[opensbi]`, `[contracts.*]`,
//! `[dependencies]`). It does not aim to be a general TOML parser.

use std::collections::BTreeMap;
use std::path::Path;

/// A parsed `pins.toml` file: each table name maps to its key/value pairs.
#[derive(Debug, Default, Clone)]
pub struct Pins {
    /// All tables, in source order by table name (which is also insertion order here).
    pub tables: BTreeMap<String, BTreeMap<String, String>>,
}

impl Pins {
    /// Read and parse `pins.toml` from the given path.
    pub fn from_file<P: AsRef<Path>>(path: P) -> Result<Self, String> {
        let text = std::fs::read_to_string(path.as_ref())
            .map_err(|e| format!("cannot read pins.toml {}: {e}", path.as_ref().display()))?;
        Self::parse(&text)
    }

    /// Find `pins.toml` by walking up from the current directory, or from a given start.
    pub fn find(start: &Path) -> Option<std::path::PathBuf> {
        let mut here = start.to_path_buf();
        loop {
            let candidate = here.join("pins.toml");
            if candidate.is_file() {
                return Some(candidate);
            }
            if !here.pop() {
                return None;
            }
        }
    }

    /// Parse TOML text. Supports `[table]` sections, `key = value` pairs, inline comments,
    /// and string / integer / bare-word values.
    pub fn parse(text: &str) -> Result<Self, String> {
        let mut out = Self::default();
        let mut current: String = String::new();
        for (n, raw) in text.lines().enumerate() {
            let line = raw.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            if let Some(body) = line.strip_prefix('[').and_then(|s| s.strip_suffix(']')) {
                current = body.trim().to_string();
                out.tables.entry(current.clone()).or_default();
                continue;
            }
            let Some((k, v)) = line.split_once('=') else {
                return Err(format!("pins.toml parse error on line {}: {line}", n + 1));
            };
            if current.is_empty() {
                return Err(format!(
                    "pins.toml parse error on line {}: key before any [section]",
                    n + 1
                ));
            }
            let key = k.trim().to_string();
            let value = parse_value(v);
            out.tables
                .entry(current.clone())
                .or_default()
                .insert(key, value);
        }
        Ok(out)
    }

    /// Value of a key in a table, if present.
    pub fn get(&self, table: &str, key: &str) -> Option<&str> {
        self.tables.get(table)?.get(key).map(|s| s.as_str())
    }

    /// Render the pins as JSON, including package, toolchain, qemu, opensbi, and contracts.
    pub fn to_json(&self) -> g6q_core::Json {
        use g6q_core::Json;
        let mut top = Vec::new();
        for (name, rows) in &self.tables {
            let mut pairs = Vec::new();
            for (k, v) in rows {
                pairs.push((k.as_str(), Json::str(v)));
            }
            top.push((name.as_str(), Json::obj(pairs)));
        }
        Json::obj(top)
    }
}

/// Strip inline comments and surrounding quotes, then return the cleaned value.
fn parse_value(raw: &str) -> String {
    let trimmed = raw.trim();
    // Drop an inline comment preceded by at least one space.
    let no_comment = if let Some(idx) = trimmed.rfind(" #") {
        &trimmed[..idx]
    } else {
        trimmed
    };
    let no_comment = no_comment.trim();
    // Unwrap double-quoted or single-quoted strings.
    if no_comment.len() >= 2 {
        let bytes = no_comment.as_bytes();
        let first = bytes[0] as char;
        let last = bytes[bytes.len() - 1] as char;
        if (first == '"' && last == '"') || (first == '\'' && last == '\'') {
            return no_comment[1..no_comment.len() - 1].to_string();
        }
    }
    no_comment.to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_sample_pins() {
        let text = r#"
[package]
version = "0.1.0"
stage = "Q0"

[opensbi]
url = "https://example.com/opensbi.git"
ref = "v1.5"          # a comment
plugin_api = 4

[contracts.ai_isa]
path = "core/cvxif_g6lc_ai/include/g6lc_ai_instr_pkg.sv"
rev = "read-at-runtime"
"#;
        let pins = Pins::parse(text).unwrap();
        assert_eq!(pins.tables["package"]["version"], "0.1.0");
        assert_eq!(pins.tables["package"]["stage"], "Q0");
        assert_eq!(
            pins.tables["opensbi"]["url"],
            "https://example.com/opensbi.git"
        );
        assert_eq!(pins.tables["opensbi"]["ref"], "v1.5");
        assert_eq!(pins.tables["opensbi"]["plugin_api"], "4");
        assert_eq!(
            pins.tables["contracts.ai_isa"]["path"],
            "core/cvxif_g6lc_ai/include/g6lc_ai_instr_pkg.sv"
        );
    }
}
