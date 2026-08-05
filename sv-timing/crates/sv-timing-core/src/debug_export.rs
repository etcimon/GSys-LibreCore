// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// AST / IR / edit-trace debug exports for multi-pass diagnosis.

//! Debug dump helpers used by analyze, correct, and integrity tests.
//! See `architecture/AUTO-CORRECT-CORE-API.md` §3.10.

use std::fs;
use std::path::{Path, PathBuf};

use crate::error::{CoreError, CoreResult};
use crate::ir::TimingDesign;
use crate::measure::RankedPaths;
use crate::naming::NameTable;

/// Options for a full debug bundle.
#[derive(Debug, Clone)]
pub struct DebugOptions {
    /// Write IR JSON.
    pub ir_json: bool,
    /// Write paths CSV.
    pub paths_csv: bool,
    /// Write name table JSON.
    pub names_json: bool,
}

impl Default for DebugOptions {
    fn default() -> Self {
        Self {
            ir_json: true,
            paths_csv: true,
            names_json: true,
        }
    }
}

/// Paths written by a debug export.
#[derive(Debug, Clone, Default)]
pub struct DebugExport {
    /// Files created.
    pub files: Vec<PathBuf>,
}

/// Dump timing IR as pretty JSON.
pub fn debug_dump_ir_json(design: &TimingDesign, path: impl AsRef<Path>) -> CoreResult<()> {
    let path = path.as_ref();
    let body = serde_json::to_vec_pretty(design).map_err(|e| CoreError::InvalidOptions(e.to_string()))?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|source| CoreError::Io {
            path: parent.to_path_buf(),
            source,
        })?;
    }
    fs::write(path, body).map_err(|source| CoreError::Io {
        path: path.to_path_buf(),
        source,
    })
}

/// Dump ranked paths as CSV (worst first).
pub fn debug_dump_paths_csv(ranked: &RankedPaths, path: impl AsRef<Path>) -> CoreResult<()> {
    let path = path.as_ref();
    let mut out = String::from("path_id,module,total_fo4,slack_fo4,multi_cycle,file,line\n");
    for p in ranked.primary.iter().chain(ranked.multi_cycle.iter()) {
        out.push_str(&format!(
            "{},{},{:.3},{:.3},{},{},{}\n",
            p.id,
            p.module,
            p.total_fo4,
            p.slack_fo4,
            p.multi_cycle as u8,
            p.primary_loc.file,
            p.primary_loc.start_line
        ));
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|source| CoreError::Io {
            path: parent.to_path_buf(),
            source,
        })?;
    }
    fs::write(path, out).map_err(|source| CoreError::Io {
        path: path.to_path_buf(),
        source,
    })
}

/// Dump name table (allocated names + origins) as JSON lines summary.
pub fn debug_dump_name_table(names: &NameTable, path: impl AsRef<Path>) -> CoreResult<()> {
    let path = path.as_ref();
    // Minimal stable JSON: policy + count
    let body = serde_json::json!({
        "tool_prefix": names.policy.tool_prefix,
        "file_suffix": names.policy.file_suffix,
        "note": "full signal map available via demangle_trace API",
    });
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|source| CoreError::Io {
            path: parent.to_path_buf(),
            source,
        })?;
    }
    fs::write(path, serde_json::to_vec_pretty(&body).unwrap()).map_err(|source| CoreError::Io {
        path: path.to_path_buf(),
        source,
    })
}

/// Write a snapshot directory with IR / paths / names.
pub fn debug_snapshot_pass(
    dir: impl AsRef<Path>,
    tag: &str,
    design: &TimingDesign,
    ranked: &RankedPaths,
    names: &NameTable,
    opts: &DebugOptions,
) -> CoreResult<DebugExport> {
    let dir = dir.as_ref().join(tag);
    fs::create_dir_all(&dir).map_err(|source| CoreError::Io {
        path: dir.clone(),
        source,
    })?;
    let mut exp = DebugExport::default();
    if opts.ir_json {
        let p = dir.join("ir.json");
        debug_dump_ir_json(design, &p)?;
        exp.files.push(p);
    }
    if opts.paths_csv {
        let p = dir.join("paths.csv");
        debug_dump_paths_csv(ranked, &p)?;
        exp.files.push(p);
    }
    if opts.names_json {
        let p = dir.join("names.json");
        debug_dump_name_table(names, &p)?;
        exp.files.push(p);
    }
    Ok(exp)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ir::TimingTarget;
    use crate::measure::RankedPaths;

    #[test]
    fn debug_snapshot_creates_files() {
        let dir = std::env::temp_dir().join("sv-timing-debug-test");
        let _ = fs::remove_dir_all(&dir);
        let design = TimingDesign::empty(TimingTarget::new(1000.0, 20.0, 0.2));
        let ranked = RankedPaths::default();
        let names = NameTable::new();
        let exp = debug_snapshot_pass(&dir, "pass0", &design, &ranked, &names, &DebugOptions::default())
            .expect("snapshot");
        assert_eq!(exp.files.len(), 3);
        for f in &exp.files {
            assert!(f.is_file(), "missing {}", f.display());
        }
    }
}
