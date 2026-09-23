// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Inclusion grammar. Kinds AND together. Values inside one kind OR together.

//! Filters over a timing design. `all` is the default empty inclusion.
//! Combining the `all` flag with any other kind is an error.

use std::collections::BTreeMap;

use serde_json::Value;
use sv_timing_core::{PathClassKind, PathKind};

/// One inclusion. Empty lists mean that kind does not filter.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Inclusion {
    /// Module names or `parent.instance` keys. Empty admits every module.
    pub subtrees: Vec<String>,
    /// Path-class filter. Empty admits every class.
    pub path_classes: Vec<PathClassKind>,
    /// Path-kind filter. Empty admits every kind.
    pub path_kinds: Vec<PathKind>,
    /// Area-only ternary overlay. Does not change FO4.
    pub config: BTreeMap<String, Value>,
    /// Globs. Empty admits every name that deny does not drop.
    pub allow: Vec<String>,
    /// Globs applied after allow.
    pub deny: Vec<String>,
    /// True when the caller passed the `all` flag.
    pub explicit_all: bool,
}

/// A flag this parser rejects.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum InclusionError {
    /// `all` was combined with another kind.
    AllWithFilter,
    /// The flag did not match the grammar.
    BadFlag(String),
    /// Path class or path kind text is not in the enum.
    BadKind(String),
    /// `--config-overlay` had no `=`.
    BadOverlay(String),
}

impl Inclusion {
    /// No filter. Same as omitting every flag.
    pub fn all() -> Self {
        Self::default()
    }

    /// True when `all` was requested together with another kind.
    pub fn conflicts(&self) -> bool {
        self.explicit_all
            && !(self.subtrees.is_empty()
                && self.path_classes.is_empty()
                && self.path_kinds.is_empty()
                && self.config.is_empty()
                && self.allow.is_empty()
                && self.deny.is_empty())
    }

    /// Parse one `--inclusion` value. `all` or `kind:value`.
    pub fn parse_flag(&mut self, spec: &str) -> Result<(), InclusionError> {
        let spec = spec.trim();
        if spec == "all" {
            self.explicit_all = true;
            if self.conflicts() {
                return Err(InclusionError::AllWithFilter);
            }
            return Ok(());
        }
        let Some((kind, value)) = spec.split_once(':') else {
            return Err(InclusionError::BadFlag(spec.to_string()));
        };
        if value.is_empty() {
            return Err(InclusionError::BadFlag(spec.to_string()));
        }
        match kind {
            "subtree" => self.subtrees.push(value.to_string()),
            "path-class" => self.path_classes.push(
                parse_class(value).ok_or_else(|| InclusionError::BadKind(value.to_string()))?,
            ),
            "path-kind" => self
                .path_kinds
                .push(parse_kind(value).ok_or_else(|| InclusionError::BadKind(value.to_string()))?),
            "allow" => self.allow.push(value.to_string()),
            "deny" => self.deny.push(value.to_string()),
            _ => return Err(InclusionError::BadFlag(spec.to_string())),
        }
        if self.explicit_all {
            return Err(InclusionError::AllWithFilter);
        }
        Ok(())
    }

    /// Parse `KEY=VALUE`, splitting on the first `=`.
    pub fn parse_overlay(&mut self, spec: &str) -> Result<(), InclusionError> {
        let Some((key, value)) = spec.split_once('=') else {
            return Err(InclusionError::BadOverlay(spec.to_string()));
        };
        if key.is_empty() {
            return Err(InclusionError::BadOverlay(spec.to_string()));
        }
        self.config.insert(key.to_string(), overlay_value(value));
        if self.explicit_all {
            return Err(InclusionError::AllWithFilter);
        }
        Ok(())
    }

    /// Sorted canonical text. Empty kinds are omitted.
    pub fn canonical(&self) -> String {
        let mut lines = Vec::new();
        for glob in sorted(&self.allow) {
            lines.push(format!("allow={glob}"));
        }
        for (key, value) in &self.config {
            lines.push(format!(
                "config={key}={}",
                serde_json::to_string(value).unwrap_or_default()
            ));
        }
        for glob in sorted(&self.deny) {
            lines.push(format!("deny={glob}"));
        }
        for class in self.path_classes.iter().filter_map(|c| snake_class(*c)) {
            lines.push(format!("path-class={class}"));
        }
        for kind in self.path_kinds.iter().filter_map(|k| snake_kind(*k)) {
            lines.push(format!("path-kind={kind}"));
        }
        for name in sorted(&self.subtrees) {
            lines.push(format!("subtree={name}"));
        }
        lines.sort();
        lines.join("\n")
    }
}

/// Full-string glob. `*` does not cross `/`. There is no `**`.
pub fn glob_match(pattern: &str, text: &str) -> bool {
    fn rec(pattern: &[u8], text: &[u8]) -> bool {
        match (pattern.first(), text.first()) {
            (None, None) => true,
            (Some(b'*'), _) => {
                rec(&pattern[1..], text)
                    || (text.first().is_some_and(|c| *c != b'/') && rec(pattern, &text[1..]))
            }
            (Some(b'?'), Some(c)) if *c != b'/' => rec(&pattern[1..], &text[1..]),
            (Some(a), Some(b)) if a == b => rec(&pattern[1..], &text[1..]),
            _ => false,
        }
    }
    rec(pattern.as_bytes(), text.as_bytes())
}

/// File name, ignoring directories. Both separators count.
pub fn file_name(path: &str) -> &str {
    path.rsplit(['/', '\\']).next().unwrap_or(path)
}

fn sorted(items: &[String]) -> Vec<&String> {
    let mut items: Vec<&String> = items.iter().collect();
    items.sort();
    items
}

fn overlay_value(text: &str) -> Value {
    if let Ok(value) = serde_json::from_str::<Value>(text) {
        if value.is_number() || value.is_boolean() || value.is_null() {
            return value;
        }
    }
    Value::String(text.to_string())
}

fn parse_class(text: &str) -> Option<PathClassKind> {
    serde_json::from_value(Value::String(text.to_string())).ok()
}

fn parse_kind(text: &str) -> Option<PathKind> {
    serde_json::from_value(Value::String(text.to_string())).ok()
}

fn snake_class(class: PathClassKind) -> Option<&'static str> {
    Some(match class {
        PathClassKind::Plain => "plain",
        PathClassKind::UnderBudget => "under_budget",
        PathClassKind::MultiCycleTagged => "multi_cycle_tagged",
        PathClassKind::ExclusiveCaseMux => "exclusive_case_mux",
        PathClassKind::ExclusiveIfChain => "exclusive_if_chain",
        PathClassKind::IndependentLhsBundle => "independent_lhs_bundle",
        PathClassKind::DenseControlCone => "dense_control_cone",
        PathClassKind::AtomicOverBudget => "atomic_over_budget",
    })
}

fn snake_kind(kind: PathKind) -> Option<&'static str> {
    Some(match kind {
        PathKind::InToOut => "in_to_out",
        PathKind::RegToReg => "reg_to_reg",
        PathKind::InToReg => "in_to_reg",
        PathKind::RegToOut => "reg_to_out",
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canonical_sorts_kinds_and_rejects_all_with_a_filter() {
        let mut inclusion = Inclusion::all();
        inclusion.parse_flag("subtree:leaf").unwrap();
        inclusion.parse_flag("subtree:top").unwrap();
        inclusion.parse_flag("deny:skip").unwrap();
        inclusion.parse_overlay("EN=1").unwrap();
        inclusion.parse_overlay("MODE=fast").unwrap();
        let text = inclusion.canonical();
        assert!(text.find("config=").unwrap() < text.find("deny=").unwrap());
        assert!(text.find("deny=").unwrap() < text.find("subtree=").unwrap());
        assert!(text.contains("subtree=leaf"));
        assert!(text.contains("subtree=top"));
        assert!(inclusion.parse_flag("all").is_err());
    }

    #[test]
    fn star_does_not_cross_a_slash() {
        assert!(glob_match("a*", "alu"));
        assert!(!glob_match("a*", "a/lu"));
        assert!(glob_match("u_?", "u_x"));
        assert!(!glob_match("**", "a/b"));
    }
}
