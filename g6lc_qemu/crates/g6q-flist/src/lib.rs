// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! `g6q-flist` — filelist expansion and **compiled-membership** facts.
//!
//! This crate answers the question the configuration cannot: *what is actually compiled
//! into the elaborated design?* A configuration bit that enables a unit whose source is
//! not in the manifest means the design has a stub, and an emulator that executes the
//! feature anyway is lying about the design under test
//! ([`architecture/INGEST.md`] §3).
//!
//! The grammar is the common EDA `.f` convention: file paths, `#` and `//` comments,
//! `+incdir+`, `+define+`, and nested `-f` / `-F` includes with cycle guarding.
//! Variables expand from an **explicit** map supplied by the caller — no project variable
//! name is baked in, which is what lets the package run against any tree.
//!
//! `tools/flist_expand.py` implements the same grammar and serves as an executable
//! specification; the two are kept in agreement by the shared test cases below.
//!
//! [`architecture/INGEST.md`]: ../../../architecture/INGEST.md

#![forbid(unsafe_code)]

use std::collections::{BTreeMap, BTreeSet};
use std::fmt;
use std::path::{Path, PathBuf};

/// Failure modes of expansion.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FlistError {
    /// A referenced filelist does not exist.
    Missing(PathBuf),
    /// A `-f` / `-F` token had no operand.
    DanglingInclude(PathBuf),
    /// A `${VAR}` had no binding and strict expansion was requested.
    UndefinedVariable(String),
    /// The filelist could not be read.
    Io(String),
}

impl fmt::Display for FlistError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            FlistError::Missing(p) => write!(f, "filelist not found: {}", p.display()),
            FlistError::DanglingInclude(p) => {
                write!(f, "{}: dangling -f/-F with no operand", p.display())
            }
            FlistError::UndefinedVariable(v) => write!(f, "undefined variable ${{{v}}}"),
            FlistError::Io(m) => write!(f, "io error: {m}"),
        }
    }
}

impl std::error::Error for FlistError {}

/// The result of expanding a filelist.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Expansion {
    /// Source files, in first-seen order, de-duplicated.
    pub files: Vec<String>,
    /// Include directories, in first-seen order.
    pub incdirs: Vec<String>,
    /// `+define+` tokens in effect.
    pub defines: Vec<String>,
}

impl Expansion {
    /// Whether a `+define+` token is set.
    pub fn has_define(&self, name: &str) -> bool {
        self.defines
            .iter()
            .any(|d| d == name || d.starts_with(&format!("{name}=")))
    }

    /// Whether any compiled file path contains `needle`.
    ///
    /// Deliberately a substring test on a normalised path: manifests reference files by
    /// many different relative prefixes, and the question being asked is "is this unit in
    /// the build", not "is this exact path in the build".
    pub fn contains_path(&self, needle: &str) -> bool {
        let needle = needle.replace('\\', "/");
        self.files.iter().any(|f| f.contains(&needle))
    }

    /// How many source files are compiled.
    pub fn file_count(&self) -> usize {
        self.files.len()
    }
}

/// Whether a named unit is compiled, and on what evidence.
///
/// This is the shape ingest hands to the conformance report: a boolean is not enough,
/// because "not present" needs to be explainable.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Membership {
    /// Unit name, e.g. `"vector"`.
    pub unit: String,
    /// Whether the implementing source is in the compiled set.
    pub present: bool,
    /// Human-readable justification.
    pub evidence: String,
}

/// Query whether a unit is compiled, given the path fragments that would prove it.
///
/// `implementing` are fragments whose presence proves the real unit is compiled;
/// `stub_markers` are fragments whose presence *instead* indicates a placeholder. A stub
/// marker never makes `present` true, which is the whole point.
pub fn membership(
    exp: &Expansion,
    unit: &str,
    implementing: &[&str],
    stub_markers: &[&str],
) -> Membership {
    if let Some(hit) = implementing.iter().find(|p| exp.contains_path(p)) {
        return Membership {
            unit: unit.to_string(),
            present: true,
            evidence: format!("implementing source in the compiled set: {hit}"),
        };
    }
    if let Some(hit) = stub_markers.iter().find(|p| exp.contains_path(p)) {
        return Membership {
            unit: unit.to_string(),
            present: false,
            evidence: format!("only a stub is compiled: {hit}"),
        };
    }
    Membership {
        unit: unit.to_string(),
        present: false,
        evidence: "no implementing source in the compiled set".to_string(),
    }
}

/// Expand a filelist into files, include directories and defines.
///
/// `vars` binds `${NAME}` / `$NAME` occurrences. With `strict`, an unbound variable is an
/// error rather than being left in place — a path containing a literal `${...}` would
/// otherwise silently fail to match anything later.
pub fn expand(
    entry: &Path,
    vars: &BTreeMap<String, String>,
    strict: bool,
) -> Result<Expansion, FlistError> {
    let mut acc = Expansion::default();
    let mut visited = BTreeSet::new();
    expand_into(entry, vars, strict, &mut acc, &mut visited)?;
    Ok(acc)
}

fn expand_into(
    entry: &Path,
    vars: &BTreeMap<String, String>,
    strict: bool,
    acc: &mut Expansion,
    visited: &mut BTreeSet<PathBuf>,
) -> Result<(), FlistError> {
    let entry = entry.canonicalize().unwrap_or_else(|_| entry.to_path_buf());
    if !visited.insert(entry.clone()) {
        return Ok(()); // cycle guard
    }
    if !entry.is_file() {
        return Err(FlistError::Missing(entry));
    }
    let text = std::fs::read_to_string(&entry).map_err(|e| FlistError::Io(e.to_string()))?;
    let base = entry.parent().unwrap_or(Path::new(".")).to_path_buf();

    let mut tokens: Vec<String> = Vec::new();
    for raw in text.lines() {
        let line = strip_comment(raw);
        for tok in line.split_whitespace() {
            tokens.push(tok.to_string());
        }
    }

    let mut i = 0;
    while i < tokens.len() {
        let tok = expand_vars(&tokens[i], vars, strict)?;
        if tok == "-f" || tok == "-F" {
            let Some(next) = tokens.get(i + 1) else {
                return Err(FlistError::DanglingInclude(entry));
            };
            let nested = expand_vars(next, vars, strict)?;
            let npath = join(&base, &nested);
            expand_into(&npath, vars, strict, acc, visited)?;
            i += 2;
            continue;
        }
        if let Some(rest) = tok.strip_prefix("+incdir+") {
            for d in rest.split('+').filter(|s| !s.is_empty()) {
                let p = norm(&join(&base, d));
                if !acc.incdirs.contains(&p) {
                    acc.incdirs.push(p);
                }
            }
        } else if let Some(rest) = tok.strip_prefix("+define+") {
            for d in rest.split('+').filter(|s| !s.is_empty()) {
                let d = d.to_string();
                if !acc.defines.contains(&d) {
                    acc.defines.push(d);
                }
            }
        } else if tok.starts_with('-') || tok.starts_with('+') {
            // Unknown switch: ignored, not an error. Manifests carry simulator-specific
            // flags that mean nothing here, and failing on them would make the reader
            // useless against real trees.
        } else {
            let p = norm(&join(&base, &tok));
            if !acc.files.contains(&p) {
                acc.files.push(p);
            }
        }
        i += 1;
    }
    Ok(())
}

fn strip_comment(line: &str) -> &str {
    let line = match line.find("//") {
        Some(i) => &line[..i],
        None => line,
    };
    if line.trim_start().starts_with('#') {
        return "";
    }
    line
}

/// Whether a filelist entry should be treated as absolute.
///
/// [`Path::is_absolute`] is host-dependent, and that is the wrong semantics here: a
/// manifest written on Linux routinely contains POSIX absolute paths such as
/// `/opt/design/core/top.sv`, and on Windows [`Path::is_absolute`] reports those as
/// *relative* because they lack a drive letter. Joining them onto the manifest's own
/// directory then produces a path that matches nothing, and every membership query
/// silently returns false — a failure mode that looks like a design fact.
///
/// So absoluteness is judged portably: a leading separator, or a `C:`-style prefix, or
/// a UNC path.
fn is_absolute_portable(value: &str) -> bool {
    let b = value.as_bytes();
    match b.first() {
        Some(b'/') | Some(b'\\') => true,
        Some(c) if c.is_ascii_alphabetic() => {
            matches!(b.get(1), Some(b':')) && matches!(b.get(2), Some(b'/') | Some(b'\\'))
        }
        _ => false,
    }
}

fn join(base: &Path, value: &str) -> PathBuf {
    if is_absolute_portable(value) {
        PathBuf::from(value)
    } else {
        base.join(value)
    }
}

/// Normalise a path for comparison and reporting: forward slashes, and no Windows
/// verbatim (`\\?\`) prefix, which [`Path::canonicalize`] adds and which would otherwise
/// leak into every emitted artifact and golden fixture.
fn norm(p: &Path) -> String {
    let s = p.to_string_lossy().replace('\\', "/");
    s.strip_prefix("//?/").map_or(s.clone(), str::to_string)
}

fn expand_vars(
    token: &str,
    vars: &BTreeMap<String, String>,
    strict: bool,
) -> Result<String, FlistError> {
    let bytes: Vec<char> = token.chars().collect();
    let mut out = String::with_capacity(token.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] != '$' {
            out.push(bytes[i]);
            i += 1;
            continue;
        }
        let (name, next) = if bytes.get(i + 1) == Some(&'{') {
            let mut j = i + 2;
            let mut name = String::new();
            while j < bytes.len() && bytes[j] != '}' {
                name.push(bytes[j]);
                j += 1;
            }
            (name, j + 1) // skip '}'
        } else {
            let mut j = i + 1;
            let mut name = String::new();
            while j < bytes.len() && (bytes[j].is_alphanumeric() || bytes[j] == '_') {
                name.push(bytes[j]);
                j += 1;
            }
            (name, j)
        };
        if name.is_empty() {
            out.push('$');
            i += 1;
            continue;
        }
        match vars.get(&name) {
            Some(v) => out.push_str(v),
            None if strict => return Err(FlistError::UndefinedVariable(name)),
            None => {
                out.push_str(&token[i..next.min(token.len())]);
            }
        }
        i = next;
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn vars(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    /// Build the same two-file fixture `tools/flist_expand.py --selftest` uses, so the
    /// Rust and Python implementations are pinned to one another.
    fn fixture(dir: &Path) {
        fs::write(
            dir.join("top.f"),
            "// top filelist\n\
             +incdir+${ROOT}/include\n\
             +define+FEATURE_B\n\
             ${ROOT}/a.sv\n\
             -f nested.f\n\
             # a full-line comment\n\
             ${ROOT}/c.sv   // trailing comment\n",
        )
        .unwrap();
        fs::write(
            dir.join("nested.f"),
            "${ROOT}/b.sv\n-f top.f          // cycle: must be ignored\n",
        )
        .unwrap();
    }

    fn tmpdir(tag: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("g6q-flist-{tag}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&d);
        fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn expands_files_incdirs_defines_and_guards_cycles() {
        let d = tmpdir("basic");
        fixture(&d);
        let exp = expand(&d.join("top.f"), &vars(&[("ROOT", "/abs/proj")]), true).unwrap();
        assert_eq!(
            exp.files,
            ["/abs/proj/a.sv", "/abs/proj/b.sv", "/abs/proj/c.sv"]
        );
        assert_eq!(exp.incdirs, ["/abs/proj/include"]);
        assert_eq!(exp.defines, ["FEATURE_B"]);
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn strict_mode_rejects_an_unbound_variable() {
        let d = tmpdir("strict");
        fixture(&d);
        let err = expand(&d.join("top.f"), &BTreeMap::new(), true).unwrap_err();
        assert!(
            matches!(err, FlistError::UndefinedVariable(ref v) if v == "ROOT"),
            "{err}"
        );
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn lenient_mode_leaves_an_unbound_variable_in_place() {
        let d = tmpdir("lenient");
        fixture(&d);
        let exp = expand(&d.join("top.f"), &BTreeMap::new(), false).unwrap();
        assert!(
            exp.files.iter().any(|f| f.contains("${ROOT}")),
            "{:?}",
            exp.files
        );
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn posix_absolute_paths_are_absolute_on_every_host() {
        // A manifest written on Linux carries POSIX absolute paths. Path::is_absolute
        // calls those relative on Windows, which would silently break every membership
        // query, so absoluteness is judged portably.
        assert!(is_absolute_portable("/opt/design/core/top.sv"));
        assert!(is_absolute_portable("\\\\server\\share\\top.sv"));
        assert!(is_absolute_portable("C:/design/top.sv"));
        assert!(is_absolute_portable("c:\\design\\top.sv"));
        assert!(!is_absolute_portable("core/top.sv"));
        assert!(!is_absolute_portable("./top.sv"));
        assert!(!is_absolute_portable("C:top.sv"));
    }

    #[test]
    fn windows_verbatim_prefixes_do_not_leak_into_output() {
        // canonicalize() produces \\?\C:\... on Windows; that must never reach a golden
        // fixture or an emitted artifact.
        assert_eq!(norm(Path::new(r"\\?\C:\design\top.sv")), "C:/design/top.sv");
        assert_eq!(norm(Path::new("/design/top.sv")), "/design/top.sv");
    }

    #[test]
    fn relative_entries_resolve_against_the_listing_file() {
        let d = tmpdir("relative");
        fs::write(d.join("top.f"), "core/top.sv\n").unwrap();
        let exp = expand(&d.join("top.f"), &BTreeMap::new(), true).unwrap();
        assert_eq!(exp.files.len(), 1);
        assert!(exp.files[0].ends_with("core/top.sv"), "{:?}", exp.files);
        assert!(!exp.files[0].contains("//?/"), "{:?}", exp.files);
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn a_missing_filelist_is_an_error() {
        let d = tmpdir("missing");
        let err = expand(&d.join("nope.f"), &BTreeMap::new(), true).unwrap_err();
        assert!(matches!(err, FlistError::Missing(_)), "{err}");
        let _ = fs::remove_dir_all(&d);
    }

    #[test]
    fn define_and_path_queries() {
        let exp = Expansion {
            files: vec![
                "/p/core/unit/impl.sv".into(),
                "/p/core/stub_decoder.sv".into(),
            ],
            incdirs: vec![],
            defines: vec!["SUPPLY_B".into(), "WIDTH=4".into()],
        };
        assert!(exp.has_define("SUPPLY_B"));
        assert!(exp.has_define("WIDTH"));
        assert!(!exp.has_define("SUPPLY_A"));
        assert!(exp.contains_path("core/unit/"));
        assert!(!exp.contains_path("core/other/"));
        assert_eq!(exp.file_count(), 2);
    }

    #[test]
    fn membership_prefers_implementation_and_reports_stubs() {
        let real = Expansion {
            files: vec!["/p/vector/unit_top.sv".into()],
            ..Expansion::default()
        };
        let m = membership(
            &real,
            "vector",
            &["vector/unit_top.sv"],
            &["stub_decoder.sv"],
        );
        assert!(m.present);

        let stubbed = Expansion {
            files: vec!["/p/core/stub_decoder.sv".into()],
            ..Expansion::default()
        };
        let m = membership(
            &stubbed,
            "vector",
            &["vector/unit_top.sv"],
            &["stub_decoder.sv"],
        );
        assert!(!m.present, "a stub must never count as present");
        assert!(m.evidence.contains("stub"), "{}", m.evidence);

        let neither = Expansion::default();
        let m = membership(
            &neither,
            "vector",
            &["vector/unit_top.sv"],
            &["stub_decoder.sv"],
        );
        assert!(!m.present);
        assert!(
            m.evidence.contains("no implementing source"),
            "{}",
            m.evidence
        );
    }
}
