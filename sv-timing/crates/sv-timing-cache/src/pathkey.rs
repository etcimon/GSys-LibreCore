// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Canonical path keys: normalize once, then index — instead of O(N^2) fuzzy compares.

//! Path identity for cache reconciliation.
//!
//! The cache must decide "is this stored path the same file as that digest path?" for
//! paths that arrive from three places with different spellings: the caller's argv, the
//! `files` / `file_modules` tables, and `TimingModule::file`. The original implementation
//! answered it with a two-way `ends_with` on freshly lowercased copies of both strings,
//! which allocated twice per comparison inside nested loops (bottleneck **B2** in
//! `architecture/PERF-CACHE.md` §1) and could also match `alu.sv` against `my_alu.sv`.
//!
//! This module normalizes every path **once** into a [`CanonPath`] and resolves lookups
//! through hash maps:
//!
//! 1. exact canonical match, then
//! 2. unique **file-name** match (exact name equality — no suffix fuzz), then
//! 3. unique canonical *suffix* match, only when exactly one candidate qualifies.
//!
//! Steps 2–3 preserve the old tolerance for relative vs absolute spellings while removing
//! both the quadratic allocation and the false-positive class.

use std::collections::HashMap;

/// A path normalized for comparison: `/` separators, no `\\?\` prefix, case-folded.
///
/// Case folding is unconditional so a cache written on Windows stays usable when the same
/// tree is analyzed from a case-insensitive mount; SystemVerilog file names that differ
/// only by case are pathological and are reported as ambiguous rather than guessed.
#[derive(Debug, Clone, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct CanonPath(String);

impl CanonPath {
    /// Normalize a path string.
    pub fn new(path: &str) -> Self {
        let t = path.trim();
        let t = t.strip_prefix(r"\\?\").unwrap_or(t);
        let mut out = String::with_capacity(t.len());
        for ch in t.chars() {
            out.push(match ch {
                '\\' => '/',
                c => c.to_ascii_lowercase(),
            });
        }
        // Collapse duplicated separators (`a//b` == `a/b`) and drop a trailing one.
        while out.contains("//") {
            out = out.replace("//", "/");
        }
        if out.len() > 1 && out.ends_with('/') {
            out.pop();
        }
        CanonPath(out)
    }

    /// Normalized text.
    pub fn as_str(&self) -> &str {
        &self.0
    }

    /// Final path component (file name) of the normalized path.
    pub fn file_name(&self) -> &str {
        match self.0.rfind('/') {
            Some(i) => &self.0[i + 1..],
            None => &self.0,
        }
    }
}

/// Index over a set of known paths, supporting tolerant single-pass lookup.
#[derive(Debug, Default)]
pub struct PathIndex {
    canon: Vec<CanonPath>,
    by_canon: HashMap<String, usize>,
    by_name: HashMap<String, Vec<usize>>,
}

impl PathIndex {
    /// Build an index from path strings; positions match the input order.
    pub fn build<I, S>(paths: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: AsRef<str>,
    {
        let mut idx = PathIndex::default();
        for (i, p) in paths.into_iter().enumerate() {
            let c = CanonPath::new(p.as_ref());
            idx.by_canon.entry(c.as_str().to_string()).or_insert(i);
            idx.by_name
                .entry(c.file_name().to_string())
                .or_default()
                .push(i);
            idx.canon.push(c);
        }
        idx
    }

    /// Number of indexed paths.
    pub fn len(&self) -> usize {
        self.canon.len()
    }

    /// Whether the index is empty.
    pub fn is_empty(&self) -> bool {
        self.canon.is_empty()
    }

    /// Canonical form of the entry at `i`.
    pub fn canon_at(&self, i: usize) -> Option<&CanonPath> {
        self.canon.get(i)
    }

    /// Resolve `query` to an indexed position.
    ///
    /// Exact canonical match wins; then a unique file-name match; then a unique
    /// suffix match. Ambiguous cases return `None` (the caller then treats the file as
    /// new, which is always safe — it means "reparse", never "reuse a stale blob").
    pub fn find(&self, query: &str) -> Option<usize> {
        let q = CanonPath::new(query);
        if let Some(&i) = self.by_canon.get(q.as_str()) {
            return Some(i);
        }
        if let Some(cands) = self.by_name.get(q.file_name()) {
            if cands.len() == 1 {
                return Some(cands[0]);
            }
            // Several files share a name: require a unique suffix relationship.
            let mut hit = None;
            for &i in cands {
                let c = &self.canon[i];
                if suffix_related(c.as_str(), q.as_str()) {
                    if hit.is_some() {
                        return None; // ambiguous
                    }
                    hit = Some(i);
                }
            }
            return hit;
        }
        None
    }

    /// Whether `query` resolves to any indexed path.
    pub fn contains(&self, query: &str) -> bool {
        self.find(query).is_some()
    }
}

/// One canonical path is a path-boundary suffix of the other.
///
/// Boundary-aware so `.../alu.sv` never matches `.../my_alu.sv`.
fn suffix_related(a: &str, b: &str) -> bool {
    if a == b {
        return true;
    }
    let (long, short) = if a.len() >= b.len() { (a, b) } else { (b, a) };
    if !long.ends_with(short) {
        return false;
    }
    let boundary = long.len() - short.len();
    boundary == 0 || long.as_bytes()[boundary - 1] == b'/'
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn canon_normalizes_separators_case_and_verbatim_prefix() {
        let a = CanonPath::new(r"\\?\E:\cva6\Core\Alu.sv");
        assert_eq!(a.as_str(), "e:/cva6/core/alu.sv");
        assert_eq!(a.file_name(), "alu.sv");
        assert_eq!(CanonPath::new("a//b///c.sv").as_str(), "a/b/c.sv");
        assert_eq!(CanonPath::new("dir/").as_str(), "dir");
    }

    #[test]
    fn exact_and_relative_spellings_resolve() {
        let idx = PathIndex::build(["E:/cva6/core/alu.sv", "E:/cva6/core/mult.sv"]);
        assert_eq!(idx.find("e:\\cva6\\core\\alu.sv"), Some(0));
        // Relative spelling of the same file (old two-way ends_with behavior).
        assert_eq!(idx.find("core/alu.sv"), Some(0));
        assert_eq!(idx.find("mult.sv"), Some(1));
        assert!(idx.contains("alu.sv"));
    }

    #[test]
    fn suffix_match_respects_path_boundaries() {
        // The old `ends_with` fuzz matched these; a boundary-aware suffix must not.
        let idx = PathIndex::build(["E:/cva6/core/my_alu.sv"]);
        assert_eq!(idx.find("core/alu.sv"), None, "my_alu.sv must not match alu.sv");
        assert_eq!(idx.find("my_alu.sv"), Some(0));
        assert!(suffix_related("e:/x/alu.sv", "alu.sv"));
        assert!(!suffix_related("e:/x/my_alu.sv", "alu.sv"));
    }

    #[test]
    fn ambiguous_same_name_files_are_not_guessed() {
        let idx = PathIndex::build(["a/pkg/cfg.sv", "b/pkg/cfg.sv"]);
        // Same basename in two trees: only a distinguishing suffix resolves.
        assert_eq!(idx.find("cfg.sv"), None, "ambiguous name must not resolve");
        assert_eq!(idx.find("a/pkg/cfg.sv"), Some(0));
        assert_eq!(idx.find("b/pkg/cfg.sv"), Some(1));
    }

    #[test]
    fn index_reports_size_and_canon() {
        let idx = PathIndex::build(["x/a.sv", "x/b.sv"]);
        assert_eq!(idx.len(), 2);
        assert!(!idx.is_empty());
        assert_eq!(idx.canon_at(1).map(|c| c.file_name()), Some("b.sv"));
        assert!(PathIndex::build(Vec::<String>::new()).is_empty());
    }
}
