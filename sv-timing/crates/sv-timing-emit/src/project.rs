// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Multi-file / multi-module project emission under a caller-chosen output directory.

//! Project-level emit: map multi-file sources + edit traces into an **output
//! directory tree**, optional **new module files**, and a portable **`.f` filelist**.
//!
//! See `architecture/PROJECT-AUTOCORRECT.md`.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use sv_timing_core::{
    write_filelist, CoreError, CoreResult, NameTable, SourceLoc, TimingDesign,
};
use sv_timing_transform::EditTrace;

use crate::dense::dense_options_from_source;
use crate::{
    apply_edits_to_source_dense, machine_header, EmitPolicy, EmitTree, FileRole,
};

/// How relative paths are laid out under the emit root.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProjectLayout {
    /// Flat: `{stem}__svt.sv` at emit root (legacy single-file behavior).
    Flat,
    /// Preserve parent directory names under emit root when a common base is known.
    #[default]
    PreserveRel,
}

/// Options for multi-file project auto-correct emission.
#[derive(Debug, Clone)]
pub struct ProjectEmitOptions {
    /// Output directory root (CLI `--out-dir` / `--emit-dir`).
    pub out_dir: PathBuf,
    /// Layout policy for corrected sources.
    pub layout: ProjectLayout,
    /// Optional common source root for relative path stripping (project base).
    pub source_root: Option<PathBuf>,
    /// Write `svt_corrected.f` under `out_dir`.
    pub write_filelist: bool,
    /// Write `svt_emit_manifest.json` under `out_dir`.
    pub write_manifest: bool,
    /// Subdirectory for brand-new modules (not rewrites of inputs).
    pub generated_subdir: String,
    /// Also emit unchanged inputs as passthrough `__svt` copies (default false:
    /// only files touched by edits + new modules).
    pub emit_unchanged: bool,
    /// Opt-in richer emit: cut feeds use origin RHS + continuous origin rewrite/sinks
    /// (default false = lean zero-feed FO4 sidecar; see RUNTIME-STABILITY R12e).
    pub real_cut_feeds: bool,
    /// Opt-in BalanceMux structural snippet RTL + origin RHS rewrite (default false).
    pub emit_balance_mux_rtl: bool,
}

impl Default for ProjectEmitOptions {
    fn default() -> Self {
        Self {
            out_dir: PathBuf::from(".sv-timing-out/corrected"),
            layout: ProjectLayout::PreserveRel,
            source_root: None,
            write_filelist: true,
            write_manifest: true,
            generated_subdir: "generated".into(),
            emit_unchanged: false,
            real_cut_feeds: false,
            emit_balance_mux_rtl: false,
        }
    }
}

/// One entry in the emit manifest (source → output mapping).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EmitManifestEntry {
    /// Original source path (empty for brand-new modules).
    pub source: String,
    /// Relative path under emit root.
    pub emit_rel: String,
    /// Absolute or resolved emit path.
    pub emit_path: String,
    /// Role string.
    pub role: String,
    /// Number of edit records applied to this file.
    pub edit_count: u32,
    /// True if this file was created (not a rewrite of an input).
    pub is_new: bool,
    /// Module names primarily associated (best-effort).
    pub modules: Vec<String>,
}

/// Full project emit result (tree + sidecar metadata).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectEmitResult {
    /// Emit root.
    pub out_dir: String,
    /// Logical tree before write (also used for integrity reparse).
    #[serde(skip)]
    pub tree: EmitTree,
    /// Manifest entries.
    pub entries: Vec<EmitManifestEntry>,
    /// Path to written filelist if any.
    pub filelist_path: Option<String>,
    /// Path to written manifest if any.
    pub manifest_path: Option<String>,
    /// Paths written to disk (after [`write_project_emit`]).
    pub written: Vec<String>,
}

/// Filter edit records whose origin file matches `source_path`.
///
/// Basename match is **exact** `file_name()` equality only — never
/// `ends_with("alu.sv")` on `copro_alu.sv` (runtime stability R6).
pub fn edits_for_source(trace: &EditTrace, source_path: &Path) -> EditTrace {
    let src_norm = normalize_path_key(source_path);
    let src_base = source_path
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_default();
    let mut out = EditTrace::new();
    for r in &trace.records {
        let of = normalize_path_key(Path::new(&r.origin.file));
        let origin_base = Path::new(&r.origin.file)
            .file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_default();
        // Exact basename only (copro_alu.sv ≠ alu.sv).
        let base_match = !src_base.is_empty() && origin_base == src_base;
        // Full path: equality or path-suffix of the *full* normalized key
        // (e.g. `core/alu.sv` matches `/repo/core/alu.sv`), not bare basename.
        let full_match = !of.is_empty()
            && !src_norm.is_empty()
            && (of == src_norm
                || (src_norm.len() > origin_base.len()
                    && (of.ends_with(&src_norm) || src_norm.ends_with(&of))));
        if full_match || base_match {
            out.records.push(r.clone());
        }
    }
    out
}

/// Infer a common source root from a set of absolute-ish paths (longest common parent).
pub fn infer_source_root(paths: &[PathBuf]) -> Option<PathBuf> {
    if paths.is_empty() {
        return None;
    }
    let comps: Vec<Vec<std::path::Component>> = paths
        .iter()
        .map(|p| p.components().collect())
        .collect();
    if comps.len() == 1 {
        return paths[0].parent().map(|p| p.to_path_buf());
    }
    let mut common = Vec::new();
    let min_len = comps.iter().map(|c| c.len()).min().unwrap_or(0);
    for i in 0..min_len {
        let c0 = comps[0][i];
        if comps.iter().all(|c| c[i] == c0) {
            common.push(c0);
        } else {
            break;
        }
    }
    if common.is_empty() {
        return None;
    }
    // Drop the last component if it looks like a shared filename (shouldn't for dirs)
    let mut root = PathBuf::new();
    for c in common {
        root.push(c);
    }
    // If root is a file path equal to one of the inputs, use parent
    if paths.iter().any(|p| p == &root) {
        return root.parent().map(|p| p.to_path_buf());
    }
    Some(root)
}

/// Build emit relative path for a source under project options.
pub fn emit_rel_for_source(source: &Path, opts: &ProjectEmitOptions) -> PathBuf {
    let stem = source
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "module".into());
    let file_name = format!("{stem}__svt.sv");
    match opts.layout {
        ProjectLayout::Flat => PathBuf::from(file_name),
        ProjectLayout::PreserveRel => {
            if let Some(root) = &opts.source_root {
                if let Ok(rel) = source.strip_prefix(root) {
                    let mut out = PathBuf::new();
                    if let Some(parent) = rel.parent() {
                        if parent.as_os_str().len() > 0 {
                            out.push(parent);
                        }
                    }
                    out.push(file_name);
                    return out;
                }
            }
            // Fallback: use immediate parent dir name to avoid total flat collision
            if let Some(parent) = source.parent().and_then(|p| p.file_name()) {
                PathBuf::from(parent).join(file_name)
            } else {
                PathBuf::from(file_name)
            }
        }
    }
}

/// Synthesize a full project emit tree from multi-file sources + edit trace.
///
/// - Each input with matching edits (or `emit_unchanged`) becomes a corrected file.
/// - New modules listed in `new_modules` (name + optional origin) become files under
///   `generated_subdir/`.
/// - Per-file edit filtering ensures multi-module correct does not inject every
///   edit into every source.
pub fn synthesize_project(
    sources: &[(PathBuf, String)],
    trace: &EditTrace,
    policy: &EmitPolicy,
    opts: &ProjectEmitOptions,
    new_modules: &[(String, Option<SourceLoc>)],
) -> ProjectEmitResult {
    let mut tree = EmitTree::new();
    let mut entries = Vec::new();
    let mut used_rel: BTreeSet<String> = BTreeSet::new();

    for (path, src) in sources {
        let file_trace = edits_for_source(trace, path);
        if file_trace.records.is_empty() && !opts.emit_unchanged {
            continue;
        }
        let mut rel = emit_rel_for_source(path, opts);
        // Collision guard
        let key0 = rel.to_string_lossy().replace('\\', "/");
        if used_rel.contains(&key0) {
            let stem = path
                .file_stem()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_else(|| "mod".into());
            rel = PathBuf::from(format!("dup/{stem}__svt.sv"));
        }
        used_rel.insert(rel.to_string_lossy().replace('\\', "/"));

        let mut dense = dense_options_from_source(src);
        dense.real_cut_feeds = opts.real_cut_feeds;
        dense.emit_balance_mux_rtl = opts.emit_balance_mux_rtl;
        let text = if file_trace.records.is_empty() {
            let mut t = machine_header(&policy.tool, &policy.run_id);
            t.push_str(src);
            if !src.ends_with('\n') {
                t.push('\n');
            }
            t
        } else {
            apply_edits_to_source_dense(src, &file_trace, policy, &dense)
        };

        let rel_s = rel.to_string_lossy().replace('\\', "/");
        tree.add_file(rel.clone(), FileRole::Module, text);
        entries.push(EmitManifestEntry {
            source: path.display().to_string(),
            emit_rel: rel_s.clone(),
            emit_path: opts.out_dir.join(&rel).display().to_string(),
            role: "module".into(),
            edit_count: file_trace.records.len() as u32,
            is_new: false,
            modules: Vec::new(),
        });
    }

    // Brand-new modules (hierarchy expand / extracted pipeline stages as modules)
    for (mod_name, origin) in new_modules {
        let file_stem = format!("{mod_name}__svt");
        let rel = PathBuf::from(&opts.generated_subdir).join(format!("{file_stem}.sv"));
        let rel_s = rel.to_string_lossy().replace('\\', "/");
        if used_rel.contains(&rel_s) {
            continue;
        }
        used_rel.insert(rel_s.clone());
        // Prefer a real IR-shaped module when callers pass origin-only names:
        // build a minimal TimingModule and run synthesize_module (full ports/always).
        let mut text = {
            use sv_timing_core::{
                ModulePort, RegionKind, TimingModule as Tm, CombRegion, GateInfo, EdgeKind,
                ResetInfo, SourceLoc as Sl,
            };
            use std::collections::BTreeMap;
            let loc = origin.clone().unwrap_or_else(|| Sl {
                file: String::new(),
                start_line: 1,
                start_col: 1,
                end_line: 1,
                end_col: 1,
                byte_start: 0,
                byte_end: 0,
                origin: sv_timing_core::OriginKind::Unknown,
            });
            let mut tm = Tm {
                id: 0,
                name: mod_name.clone(),
                file: String::new(),
                nodes: BTreeMap::new(),
                regions: BTreeMap::new(),
                localparams: Vec::new(),
                parameters: Vec::new(),
                ports: vec![
                    ModulePort {
                        name: "clk_i".into(),
                        direction: "input".into(),
                        type_name: Some("logic".into()),
                        packed_dims: None,
                        uses_hierarchical: false,
                    },
                    ModulePort {
                        name: "rst_ni".into(),
                        direction: "input".into(),
                        type_name: Some("logic".into()),
                        packed_dims: None,
                        uses_hierarchical: false,
                    },
                    ModulePort {
                        name: "d_i".into(),
                        direction: "input".into(),
                        type_name: Some("logic".into()),
                        packed_dims: Some("[63:0]".into()),
                        uses_hierarchical: false,
                    },
                    ModulePort {
                        name: "q_o".into(),
                        direction: "output".into(),
                        type_name: Some("logic".into()),
                        packed_dims: Some("[63:0]".into()),
                        uses_hierarchical: false,
                    },
                ],
                gen_loops: Vec::new(),
                functions: Vec::new(),
                package_imports: Vec::new(),
                instances: Vec::new(),
                loc: loc.clone(),
            };
            tm.regions.insert(
                0,
                CombRegion {
                    id: 0,
                    module: 0,
                    kind: RegionKind::AlwaysFf,
                    label: Some("pipe".into()),
                    gate: GateInfo {
                        clock: None,
                        clock_name: Some("clk_i".into()),
                        edge: Some(EdgeKind::Posedge),
                        enable: None,
                        reset: Some(ResetInfo {
                            signal: None,
                            active_low: true,
                            asynchronous: true,
                        }),
                        reset_name: Some("rst_ni".into()),
                        reset_edge: Some(EdgeKind::Negedge),
                        is_comb: false,
                    },
                    nodes: Vec::new(),
                    total_fo4: 0.0,
                    loc_span: loc,
                    multi_cycle: false,
                },
            );
            crate::synthesize_module(&tm, policy)
        };
        // Tag as expansion so reviewers see intent
        if !text.contains("new module") {
            text = text.replacen(
                "synthesize_module from IR",
                "new module synthesized for auto-correct expansion",
                1,
            );
        }
        tree.add_file(rel.clone(), FileRole::Module, text);
        entries.push(EmitManifestEntry {
            source: String::new(),
            emit_rel: rel_s.clone(),
            emit_path: opts.out_dir.join(&rel).display().to_string(),
            role: "generated_module".into(),
            edit_count: 0,
            is_new: true,
            modules: vec![mod_name.clone()],
        });
    }

    ProjectEmitResult {
        out_dir: opts.out_dir.display().to_string(),
        tree,
        entries,
        filelist_path: None,
        manifest_path: None,
        written: Vec::new(),
    }
}

/// Collect new module names from a [`NameTable`] (allocated modules not in design inputs).
pub fn new_modules_from_names(names: &NameTable, design: &TimingDesign) -> Vec<(String, Option<SourceLoc>)> {
    let existing: BTreeSet<String> = design.modules.values().map(|m| m.name.clone()).collect();
    // NameTable does not expose modules map publicly — use demangle is incomplete.
    // For now: no automatic pull; callers pass explicit new modules.
    // Keep hook for future when NameTable gains iterators.
    let _ = (names, existing);
    Vec::new()
}

/// Explicit new modules discovered from edit rationale / new_name prefixes (best-effort).
///
/// When transforms start allocating expanded modules (`*_svt_x*`), their names can be
/// listed here so emit creates `generated/*.sv` files.
pub fn new_modules_from_trace(trace: &EditTrace) -> Vec<(String, Option<SourceLoc>)> {
    let mut out = Vec::new();
    let mut seen = BTreeSet::new();
    for r in &trace.records {
        // Convention: rationale starts with "new_module:" or new_name looks like expanded module
        if let Some(name) = &r.new_name {
            if name.contains("_svt_x") && seen.insert(name.clone()) {
                out.push((name.clone(), Some(r.origin.clone())));
            }
        }
        if let Some(rest) = r.rationale.strip_prefix("new_module:") {
            let name = rest.trim().to_string();
            if !name.is_empty() && seen.insert(name.clone()) {
                out.push((name, Some(r.origin.clone())));
            }
        }
    }
    out
}

/// Write project tree + optional filelist + manifest under `opts.out_dir`.
pub fn write_project_emit(
    mut result: ProjectEmitResult,
    opts: &ProjectEmitOptions,
) -> CoreResult<ProjectEmitResult> {
    use crate::write_emit_tree;

    // Safety: refuse writing when out_dir is empty
    if opts.out_dir.as_os_str().is_empty() {
        return Err(CoreError::InvalidOptions(
            "project emit requires a non-empty out_dir".into(),
        ));
    }

    let written = write_emit_tree(&result.tree, &opts.out_dir)?;
    result.written = written
        .iter()
        .map(|p| p.display().to_string())
        .collect();

    // Update emit_path on entries to real paths when possible
    let mut by_rel: BTreeMap<String, PathBuf> = BTreeMap::new();
    for w in &written {
        if let Ok(rel) = w.strip_prefix(&opts.out_dir) {
            by_rel.insert(rel.to_string_lossy().replace('\\', "/"), w.clone());
        }
    }
    for e in &mut result.entries {
        if let Some(p) = by_rel.get(&e.emit_rel) {
            e.emit_path = p.display().to_string();
        }
    }

    if opts.write_filelist {
        let fl = opts.out_dir.join("svt_corrected.f");
        let files: Vec<PathBuf> = result
            .entries
            .iter()
            .map(|e| opts.out_dir.join(&e.emit_rel))
            .collect();
        write_filelist(
            &fl,
            &files,
            &[],
            "auto-correct project emit — review before use in host builds",
        )?;
        result.filelist_path = Some(fl.display().to_string());
    }

    if opts.write_manifest {
        let mp = opts.out_dir.join("svt_emit_manifest.json");
        let body = serde_json::json!({
            "schema_version": "0",
            "out_dir": result.out_dir,
            "filelist": result.filelist_path,
            "entries": result.entries,
        });
        if let Some(parent) = mp.parent() {
            std::fs::create_dir_all(parent).map_err(|source| CoreError::Io {
                path: parent.to_path_buf(),
                source,
            })?;
        }
        std::fs::write(&mp, serde_json::to_vec_pretty(&body).unwrap_or_default()).map_err(
            |source| CoreError::Io {
                path: mp.clone(),
                source,
            },
        )?;
        result.manifest_path = Some(mp.display().to_string());
    }

    Ok(result)
}

/// High-level: synthesize + write multi-file project under `out_dir`.
pub fn emit_project_autocorrect(
    sources: &[(PathBuf, String)],
    trace: &EditTrace,
    policy: &EmitPolicy,
    mut opts: ProjectEmitOptions,
) -> CoreResult<ProjectEmitResult> {
    if opts.source_root.is_none() {
        let paths: Vec<PathBuf> = sources.iter().map(|(p, _)| p.clone()).collect();
        opts.source_root = infer_source_root(&paths);
    }
    let new_mods = new_modules_from_trace(trace);
    let result = synthesize_project(sources, trace, policy, &opts, &new_mods);
    write_project_emit(result, &opts)
}

fn normalize_path_key(p: &Path) -> String {
    let s = p.to_string_lossy().replace('\\', "/");
    if cfg!(windows) {
        s.to_ascii_lowercase()
    } else {
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sv_timing_core::loc::{OriginKind, SourceLoc};
    use sv_timing_transform::{EditKind, EditRecord, EditTrace};

    fn loc(file: &str) -> SourceLoc {
        SourceLoc {
            file: file.into(),
            start_line: 1,
            start_col: 1,
            end_line: 1,
            end_col: 1,
            byte_start: 0,
            byte_end: 0,
            origin: OriginKind::UserFile,
        }
    }

    #[test]
    fn per_file_edit_filter_isolates_modules() {
        let mut tr = EditTrace::new();
        tr.record_edit(EditRecord {
            id: 0,
            kind: EditKind::InsertReg,
            origin: loc("leaf.sv"),
            path_id: Some(0),
            node_id: Some(1),
            new_name: Some("pipe_a".into()),
            fo4_before: Some(40.0),
            fo4_after: Some(20.0),
            rationale: "cut leaf".into(),
            emit_rhs: None,
            emit_rhs_extras: Vec::new(),
            emit_snippet: None,
        });
        tr.record_edit(EditRecord {
            id: 1,
            kind: EditKind::InsertReg,
            origin: loc("mid.sv"),
            path_id: Some(1),
            node_id: Some(2),
            new_name: Some("pipe_b".into()),
            fo4_before: Some(40.0),
            fo4_after: Some(20.0),
            rationale: "cut mid".into(),
            emit_rhs: None,
            emit_rhs_extras: Vec::new(),
            emit_snippet: None,
        });
        let leaf = edits_for_source(&tr, Path::new("leaf.sv"));
        assert_eq!(leaf.records.len(), 1);
        assert_eq!(leaf.records[0].new_name.as_deref(), Some("pipe_a"));
        let mid = edits_for_source(&tr, Path::new("/proj/rtl/mid.sv"));
        assert_eq!(mid.records.len(), 1);
        assert_eq!(mid.records[0].new_name.as_deref(), Some("pipe_b"));
        // Suffix trap: copro_alu.sv must not match alu.sv
        tr.record_edit(EditRecord {
            id: 2,
            kind: EditKind::InsertReg,
            origin: loc("copro_alu.sv"),
            path_id: Some(2),
            node_id: Some(3),
            new_name: Some("pipe_c".into()),
            fo4_before: Some(40.0),
            fo4_after: Some(20.0),
            rationale: "cut copro".into(),
            emit_rhs: None,
            emit_rhs_extras: Vec::new(),
            emit_snippet: None,
        });
        let alu = edits_for_source(&tr, Path::new("/mnt/e/cva6/core/alu.sv"));
        assert!(
            alu.records.is_empty(),
            "copro_alu must not densify alu: {:?}",
            alu.records.iter().map(|r| &r.origin.file).collect::<Vec<_>>()
        );
        let copro = edits_for_source(&tr, Path::new("/mnt/e/cva6/core/cvxif_example/copro_alu.sv"));
        assert_eq!(copro.records.len(), 1);
    }

    #[test]
    fn project_emit_creates_filelist_and_new_module() {
        let dir = std::env::temp_dir().join(format!(
            "svt_proj_{}",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_millis()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        let src_a = "module leaf(input logic [7:0] a, output logic [7:0] y);\n  always_comb y = a + a + a + a;\nendmodule\n";
        let mut tr = EditTrace::new();
        tr.record_edit(EditRecord {
            id: 0,
            kind: EditKind::InsertReg,
            origin: loc("leaf.sv"),
            path_id: Some(0),
            node_id: Some(1),
            new_name: Some("pipe_svt_p1".into()),
            fo4_before: Some(20.0),
            fo4_after: Some(10.0),
            rationale: "cut".into(),
            emit_rhs: None,
            emit_rhs_extras: Vec::new(),
            emit_snippet: None,
        });
        tr.record_edit(EditRecord {
            id: 1,
            kind: EditKind::Annotate,
            origin: loc("leaf.sv"),
            path_id: None,
            node_id: None,
            new_name: Some("helper_svt_x0".into()),
            fo4_before: None,
            fo4_after: None,
            rationale: "new_module:helper_svt_x0".into(),
            emit_rhs: None,
            emit_rhs_extras: Vec::new(),
            emit_snippet: None,
        });
        let sources = vec![(PathBuf::from("leaf.sv"), src_a.to_string())];
        let policy = EmitPolicy::default();
        let opts = ProjectEmitOptions {
            out_dir: dir.clone(),
            layout: ProjectLayout::Flat,
            source_root: None,
            write_filelist: true,
            write_manifest: true,
            generated_subdir: "generated".into(),
            emit_unchanged: false,
            ..Default::default()
        };
        let result = emit_project_autocorrect(&sources, &tr, &policy, opts).expect("emit");
        assert!(result.filelist_path.is_some());
        assert!(result.manifest_path.is_some());
        assert!(result.entries.iter().any(|e| e.is_new));
        assert!(result.entries.iter().any(|e| !e.is_new && e.edit_count >= 1));
        let fl = std::fs::read_to_string(result.filelist_path.as_ref().unwrap()).unwrap();
        assert!(fl.contains("__svt.sv") || fl.contains("leaf"));
        let gen = dir.join("generated").join("helper_svt_x0__svt.sv");
        assert!(gen.is_file(), "expected new module file {gen:?}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn multi_source_does_not_cross_contaminate() {
        let leaf_src = "module leaf;\nendmodule\n";
        let mid_src = "module mid;\nendmodule\n";
        let mut tr = EditTrace::new();
        tr.record_edit(EditRecord {
            id: 0,
            kind: EditKind::InsertReg,
            origin: loc("leaf.sv"),
            path_id: Some(0),
            node_id: Some(1),
            new_name: Some("only_leaf".into()),
            fo4_before: Some(10.0),
            fo4_after: Some(5.0),
            rationale: "cut".into(),
            emit_rhs: None,
            emit_rhs_extras: Vec::new(),
            emit_snippet: None,
        });
        let sources = vec![
            (PathBuf::from("leaf.sv"), leaf_src.to_string()),
            (PathBuf::from("mid.sv"), mid_src.to_string()),
        ];
        let policy = EmitPolicy::default();
        let opts = ProjectEmitOptions {
            out_dir: PathBuf::from("/tmp/unused"),
            layout: ProjectLayout::Flat,
            ..Default::default()
        };
        let result = synthesize_project(&sources, &tr, &policy, &opts, &[]);
        // Only leaf should appear (mid has no edits, emit_unchanged=false)
        assert_eq!(result.entries.len(), 1);
        assert!(result.entries[0].source.contains("leaf"));
        let text = result.tree.files.values().next().unwrap().text.as_str();
        assert!(text.contains("only_leaf"));
        assert!(!text.contains("module mid"));
    }
}
