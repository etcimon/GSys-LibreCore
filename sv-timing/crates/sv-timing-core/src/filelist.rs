// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Project-independent simple filelist (.f) reader for multi-file analyze/correct.
// Not a Bender / FuseSoC / host edaEnv expander — only portable line-oriented lists.

//! Simple SystemVerilog **filelist** (`.f`) support used by the CLI and library.
//!
//! Hosts with recursive EDA flists (`-F`, Bender, FuseSoC) should expand those
//! externally and pass a flat list or a portable `.f` this module understands.
//!
//! Supported directives (project-agnostic):
//! - blank lines and `#` / `//` comments
//! - source paths (`.sv`, `.svh`, `.v`, any path)
//! - `+incdir+path` (repeatable; `+` separates multiple dirs)
//! - `+define+NAME` / `+define+NAME=VAL`
//! - nested `-f path` / `-F path` (recursive, cycle-guarded)
//! - relative paths resolved against the **listing file’s directory**

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use crate::error::{CoreError, CoreResult};

/// Resolved multi-file project inputs from one or more filelists / CLI paths.
#[derive(Debug, Clone, Default)]
pub struct FileList {
    /// Ordered source files to parse (deduped, first-seen order).
    pub files: Vec<PathBuf>,
    /// Include directories from `+incdir+` (deduped).
    pub incdirs: Vec<PathBuf>,
    /// Defines as `(name, optional value)`.
    pub defines: Vec<(String, Option<String>)>,
    /// Nested filelist paths that were expanded (for cache fingerprints later).
    pub nested_lists: Vec<PathBuf>,
}

impl FileList {
    /// Empty list.
    pub fn new() -> Self {
        Self::default()
    }

    /// Merge another list (files append with dedupe; incdirs/defines extend).
    pub fn extend(&mut self, other: FileList) {
        let mut seen: BTreeSet<String> = self
            .files
            .iter()
            .map(|p| normalize_key(p))
            .collect();
        for f in other.files {
            let k = normalize_key(&f);
            if seen.insert(k) {
                self.files.push(f);
            }
        }
        for d in other.incdirs {
            if !self.incdirs.iter().any(|x| paths_eq(x, &d)) {
                self.incdirs.push(d);
            }
        }
        for def in other.defines {
            if !self
                .defines
                .iter()
                .any(|(n, v)| n == &def.0 && v == &def.1)
            {
                self.defines.push(def);
            }
        }
        for n in other.nested_lists {
            if !self.nested_lists.iter().any(|x| paths_eq(x, &n)) {
                self.nested_lists.push(n);
            }
        }
    }

    /// Append explicit CLI `--file` paths (resolved vs CWD if relative).
    pub fn push_files<I, P>(&mut self, paths: I)
    where
        I: IntoIterator<Item = P>,
        P: AsRef<Path>,
    {
        let mut seen: BTreeSet<String> = self.files.iter().map(|p| normalize_key(p)).collect();
        for p in paths {
            let p = p.as_ref().to_path_buf();
            let k = normalize_key(&p);
            if seen.insert(k) {
                self.files.push(p);
            }
        }
    }

    /// Convert defines to `ParseOptions` shape.
    pub fn defines_for_parse(&self) -> Vec<(String, Option<String>)> {
        self.defines.clone()
    }
}

/// Options when loading a filelist.
#[derive(Debug, Clone)]
pub struct FileListOptions {
    /// Maximum nested `-f` / `-F` depth (default 32).
    pub max_nest_depth: u32,
    /// If true, missing nested list is an error (default true).
    pub strict_nested: bool,
}

impl Default for FileListOptions {
    fn default() -> Self {
        Self {
            max_nest_depth: 32,
            strict_nested: true,
        }
    }
}

/// Load a simple `.f` / filelist path into a [`FileList`].
pub fn load_filelist(path: impl AsRef<Path>, opts: &FileListOptions) -> CoreResult<FileList> {
    let path = path.as_ref();
    let mut visiting = BTreeSet::new();
    load_filelist_rec(path, opts, 0, &mut visiting)
}

/// Convenience: load filelist with default options.
pub fn load_filelist_default(path: impl AsRef<Path>) -> CoreResult<FileList> {
    load_filelist(path, &FileListOptions::default())
}

/// Write a portable corrected project filelist under an emit root.
///
/// Paths are written relative to `list_path`'s parent when possible so the list
/// is relocatable with the emit tree.
pub fn write_filelist(
    list_path: impl AsRef<Path>,
    files: &[PathBuf],
    incdirs: &[PathBuf],
    header_comment: &str,
) -> CoreResult<()> {
    let list_path = list_path.as_ref();
    if let Some(parent) = list_path.parent() {
        std::fs::create_dir_all(parent).map_err(|source| CoreError::Io {
            path: parent.to_path_buf(),
            source,
        })?;
    }
    let base = list_path
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."));
    let mut body = String::new();
    body.push_str("# sv-timing generated filelist — do not hand-edit without review\n");
    if !header_comment.is_empty() {
        for line in header_comment.lines() {
            body.push_str("# ");
            body.push_str(line);
            body.push('\n');
        }
    }
    for d in incdirs {
        let rel = path_relative_display(d, &base);
        body.push_str("+incdir+");
        body.push_str(&rel);
        body.push('\n');
    }
    for f in files {
        let rel = path_relative_display(f, &base);
        body.push_str(&rel);
        body.push('\n');
    }
    std::fs::write(list_path, body).map_err(|source| CoreError::Io {
        path: list_path.to_path_buf(),
        source,
    })?;
    Ok(())
}

fn load_filelist_rec(
    path: &Path,
    opts: &FileListOptions,
    depth: u32,
    visiting: &mut BTreeSet<String>,
) -> CoreResult<FileList> {
    if depth > opts.max_nest_depth {
        return Err(CoreError::InvalidOptions(format!(
            "filelist nest depth exceeded (max {}) at {}",
            opts.max_nest_depth,
            path.display()
        )));
    }
    let key = normalize_key(path);
    if !visiting.insert(key.clone()) {
        return Err(CoreError::InvalidOptions(format!(
            "filelist cycle detected at {}",
            path.display()
        )));
    }

    let text = std::fs::read_to_string(path).map_err(|source| CoreError::Io {
        path: path.to_path_buf(),
        source,
    })?;
    let base = path
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."));

    let mut out = FileList::new();
    out.nested_lists.push(path.to_path_buf());

    for raw in text.lines() {
        let line = strip_comment(raw).trim();
        if line.is_empty() {
            continue;
        }
        if let Some(rest) = line.strip_prefix("+incdir+") {
            for part in rest.split('+').filter(|s| !s.is_empty()) {
                out.incdirs.push(resolve_against(&base, part));
            }
            continue;
        }
        if let Some(rest) = line.strip_prefix("+define+") {
            // +define+A+B=1 style: multiple defines separated by +
            for part in rest.split('+').filter(|s| !s.is_empty()) {
                if let Some((n, v)) = part.split_once('=') {
                    out.defines.push((n.to_string(), Some(v.to_string())));
                } else {
                    out.defines.push((part.to_string(), None));
                }
            }
            continue;
        }
        // Nested lists: -f path  or  -F path  (optional space)
        if let Some(nested) = parse_nested_flag(line) {
            let nested_path = resolve_against(&base, nested);
            match load_filelist_rec(&nested_path, opts, depth + 1, visiting) {
                Ok(sub) => out.extend(sub),
                Err(e) if !opts.strict_nested => {
                    // Soft: skip missing nested when non-strict
                    let _ = e;
                }
                Err(e) => {
                    visiting.remove(&key);
                    return Err(e);
                }
            }
            continue;
        }
        // Bare path
        out.files.push(resolve_against(&base, line));
    }

    visiting.remove(&key);
    Ok(out)
}

fn parse_nested_flag(line: &str) -> Option<&str> {
    let line = line.trim();
    for flag in ["-f ", "-F ", "-f\t", "-F\t"] {
        if let Some(rest) = line.strip_prefix(flag) {
            let rest = rest.trim();
            if !rest.is_empty() {
                return Some(rest);
            }
        }
    }
    // -fpath (no space) rare but seen
    for flag in ["-f", "-F"] {
        if line.starts_with(flag) && line.len() > flag.len() {
            let c = line.as_bytes()[flag.len()];
            if c != b' ' && c != b'\t' && c != b'-' {
                return Some(line[flag.len()..].trim());
            }
        }
    }
    None
}

fn strip_comment(line: &str) -> &str {
    let mut s = line;
    if let Some(i) = s.find("//") {
        s = &s[..i];
    }
    if let Some(i) = s.find('#') {
        // Only treat # as comment when not mid-token (simple: whole-line style)
        // Keep # inside paths unlikely; strip from first #
        s = &s[..i];
    }
    s
}

fn resolve_against(base: &Path, p: &str) -> PathBuf {
    let pb = PathBuf::from(p);
    if pb.is_absolute() {
        pb
    } else {
        base.join(pb)
    }
}

fn normalize_key(p: &Path) -> String {
    // Case-fold on Windows-ish comparison without requiring canonicalize.
    let s = p.to_string_lossy().replace('\\', "/");
    if cfg!(windows) {
        s.to_ascii_lowercase()
    } else {
        s
    }
}

fn paths_eq(a: &Path, b: &Path) -> bool {
    normalize_key(a) == normalize_key(b)
}

fn path_relative_display(path: &Path, base: &Path) -> String {
    pathdiff_simple(path, base).unwrap_or_else(|| path.display().to_string().replace('\\', "/"))
}

/// Minimal relative path (no external crate).
fn pathdiff_simple(path: &Path, base: &Path) -> Option<String> {
    let path_c = std::fs::canonicalize(path).ok();
    let base_c = std::fs::canonicalize(base).ok();
    let (path_s, base_s) = match (path_c, base_c) {
        (Some(p), Some(b)) => (p, b),
        _ => {
            // Fallback: if path is under base as string prefix
            let ps = path.to_string_lossy().replace('\\', "/");
            let bs = base.to_string_lossy().replace('\\', "/");
            if let Some(rest) = ps.strip_prefix(&bs) {
                let rest = rest.trim_start_matches('/');
                return Some(if rest.is_empty() {
                    ".".into()
                } else {
                    rest.to_string()
                });
            }
            return Some(ps);
        }
    };
    let mut path_comp: Vec<_> = path_s.components().collect();
    let mut base_comp: Vec<_> = base_s.components().collect();
    while !path_comp.is_empty() && !base_comp.is_empty() && path_comp[0] == base_comp[0] {
        path_comp.remove(0);
        base_comp.remove(0);
    }
    let mut out = PathBuf::new();
    for _ in &base_comp {
        out.push("..");
    }
    for c in path_comp {
        out.push(c);
    }
    Some(out.to_string_lossy().replace('\\', "/"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    #[test]
    fn load_simple_paths_and_incdir() {
        let dir = tempfile_dir("svt_fl_simple");
        let fl = dir.join("list.f");
        let sv = dir.join("a.sv");
        std::fs::write(&sv, "module a; endmodule\n").unwrap();
        let mut f = std::fs::File::create(&fl).unwrap();
        writeln!(f, "# comment").unwrap();
        writeln!(f, "+incdir+inc").unwrap();
        writeln!(f, "+define+FOO=1").unwrap();
        writeln!(f, "a.sv").unwrap();
        writeln!(f, "// trailing").unwrap();
        let list = load_filelist_default(&fl).expect("load");
        assert_eq!(list.files.len(), 1);
        assert!(list.files[0].ends_with("a.sv"));
        assert_eq!(list.incdirs.len(), 1);
        assert_eq!(list.defines.len(), 1);
        assert_eq!(list.defines[0].0, "FOO");
        assert_eq!(list.defines[0].1.as_deref(), Some("1"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn nested_f_expands() {
        let dir = tempfile_dir("svt_fl_nest");
        let leaf = dir.join("leaf.f");
        let top = dir.join("top.f");
        let sv = dir.join("b.sv");
        std::fs::write(&sv, "module b; endmodule\n").unwrap();
        std::fs::write(&leaf, "b.sv\n").unwrap();
        std::fs::write(&top, format!("-f {}\n", leaf.file_name().unwrap().to_string_lossy())).unwrap();
        let list = load_filelist_default(&top).expect("load");
        assert_eq!(list.files.len(), 1);
        assert!(list.files[0].ends_with("b.sv"));
        assert!(list.nested_lists.len() >= 2);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn write_filelist_roundtrip_paths() {
        let dir = tempfile_dir("svt_fl_write");
        let out = dir.join("out.f");
        let a = dir.join("x__svt.sv");
        std::fs::write(&a, "module x; endmodule\n").unwrap();
        write_filelist(&out, &[a.clone()], &[], "test run").expect("write");
        let text = std::fs::read_to_string(&out).unwrap();
        assert!(text.contains("x__svt.sv") || text.contains("x__svt"));
        assert!(text.contains("sv-timing generated"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn tempfile_dir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!(
            "{tag}_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_millis()
        ));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }
}
