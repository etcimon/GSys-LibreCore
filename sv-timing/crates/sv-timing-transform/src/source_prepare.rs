// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Materialize checked pragma plans in a review-only source tree. Callers must
//! reparse these files before ordinary transforms; coordinates belong to these
//! real prepared buffers, never to an imaginary edit of the original file.

use crate::{EditKind, EditRecord, EditTrace, PassPolicy};
use serde::Serialize;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use sv_timing_core::{row_local::RowLocalPlan, TimingDesign};

/// Prepared input files and their original-source provenance.
#[derive(Debug, Default, Serialize)]
pub struct PreparedSources {
    /// Sources for the next parse. Unmodified inputs retain their paths.
    #[serde(skip)]
    pub sources: Vec<(PathBuf, String)>,
    /// Prepared path -> original logical path for output layout.
    pub origins: BTreeMap<PathBuf, PathBuf>,
    /// Actual preprocessing edits, at original source locations.
    pub trace: EditTrace,
}

/// Apply checked plans without touching originals. No-op unless structural
/// correction and module allowlisting are enabled. This function awards no
/// FO4 credit; the caller measures the reparsed prepared program.
pub fn prepare(
    design: &TimingDesign,
    sources: &[(PathBuf, String)],
    policy: &PassPolicy,
    out_dir: &Path,
) -> Result<PreparedSources, String> {
    let mut result = PreparedSources {
        sources: sources.to_vec(),
        ..Default::default()
    };
    if !policy.correct_enabled || !policy.emit_structural {
        return Ok(result);
    }
    let mut by_file: BTreeMap<String, Vec<RowLocalPlan>> = BTreeMap::new();
    for m in design.modules.values() {
        if !policy.module_allowed(&m.name)
            || policy
                .refuse_path_prefixes
                .iter()
                .any(|p| m.file.replace('\\', "/").starts_with(&p.replace('\\', "/")))
        {
            continue;
        }
        if sv_timing_core::pipe_contract::resolve(m).is_some_and(|c| !c.rejected.is_empty()) {
            continue;
        }
        for plan in sv_timing_core::row_local::plans(m) {
            by_file
                .entry(m.file.replace('\\', "/"))
                .or_default()
                .push(plan);
        }
    }
    // Validate every planned file before writing any prepared source.
    let mut prepared = Vec::new();
    for (slot, (path, text)) in sources.iter().enumerate() {
        let Some(plans) = by_file.get(&path.to_string_lossy().replace('\\', "/")) else {
            continue;
        };
        if text.contains("`include") {
            return Err(format!(
                "{}: row-local preparation does not relocate local includes",
                path.display()
            ));
        }
        let mut edits = Vec::new();
        for p in plans {
            let span = p.origin.byte_start as usize..p.origin.byte_end as usize;
            if text.get(span.clone()) != Some(p.expected.as_str()) {
                return Err(format!(
                    "{}: row-local source changed after analysis",
                    p.origin.display()
                ));
            }
            let directive = p.directive.byte_start as usize..p.directive.byte_end as usize;
            let words: Vec<_> = text
                .get(directive.clone())
                .unwrap_or("")
                .strip_prefix("//")
                .unwrap_or("")
                .trim()
                .strip_prefix("svt-pipe:")
                .unwrap_or("")
                .split_whitespace()
                .map(|w| w.trim_end_matches(',').to_string())
                .collect();
            if words != p.directive_tokens {
                return Err(format!(
                    "{}: row-local authorization changed after analysis",
                    p.directive.display()
                ));
            }
            edits.push((span, p.replacement.clone()));
            edits.push((directive, p.receipt.clone()));
        }
        edits.sort_by_key(|(r, _)| r.start);
        if edits.windows(2).any(|w| w[0].0.end > w[1].0.start) {
            return Err(format!(
                "{}: overlapping row-local preparations",
                path.display()
            ));
        }
        let mut rewritten = text.clone();
        for (span, replacement) in edits.into_iter().rev() {
            rewritten.replace_range(span, &replacement);
        }
        prepared.push((slot, rewritten, plans));
    }
    for (slot, text, plans) in prepared {
        let original = &sources[slot].0;
        let dir = out_dir.join("_prepared").join(format!("{slot:04}"));
        std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        let dest = dir.join(original.file_name().ok_or("source has no filename")?);
        let actual_dest = if dest.exists() {
            dest.canonicalize()
        } else {
            dir.canonicalize()
                .map(|d| d.join(original.file_name().unwrap()))
        }
        .map_err(|e| e.to_string())?;
        if original.canonicalize().map_err(|e| e.to_string())? == actual_dest {
            return Err("prepared output must not overwrite its source".into());
        }
        std::fs::write(&dest, &text).map_err(|e| e.to_string())?;
        result.origins.insert(dest.clone(), original.clone());
        result.sources[slot] = (dest, text);
        for p in plans {
            result.trace.record_edit(EditRecord {
                id: 0, kind: EditKind::RowLocal, origin: p.origin.clone(), path_id: None, node_id: None,
                new_name: None, fo4_before: None, fo4_after: None,
                rationale: format!("row-local {}: {} rows (limit {}), index {}; prepared source must be reparsed; no latency or timing credit",
                                   p.name, p.rows, p.max_rows, p.index),
                emit_rhs: None, emit_rhs_extras: Vec::new(), emit_snippet: None,
                emit_predicate: false, emit_predicate_from: None, pipe_stage: None, gen_scope: None,
            });
        }
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use sv_timing_core::{analyze_files, LowerOptions, OptLevel, OptOptions, ParseOptions};
    #[test]
    fn prepared_sources_are_real_reparsed_inputs_and_leave_originals_untouched() {
        let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures/auto_correct/row_local.sv");
        let text = std::fs::read_to_string(&path).unwrap();
        let input = vec![(path.clone(), text.clone())];
        let out = analyze_files(
            &[path.clone()],
            &ParseOptions::default(),
            &LowerOptions::default(),
        )
        .unwrap();
        let dir = std::env::temp_dir().join(format!("svt_prepare_{}", std::process::id()));
        let policy = PassPolicy::from_opt(
            OptOptions::preset(OptLevel::O3),
            vec!["row_local".into()],
            false,
        );
        let p = prepare(&out.design, &input, &policy, &dir).unwrap();
        assert_eq!(p.trace.records.len(), 1);
        assert_eq!(p.origins.len(), 1);
        assert_eq!(std::fs::read_to_string(path).unwrap(), text);
        assert!(p.sources[0].1.contains("row-local-applied train"));
        assert!(
            p.sources[0].1.contains("row-local owner"),
            "unallowlisted sibling unchanged"
        );
        let parsed = analyze_files(
            &[p.sources[0].0.clone()],
            &ParseOptions::default(),
            &LowerOptions::default(),
        )
        .unwrap();
        let m = parsed
            .design
            .modules
            .values()
            .find(|m| m.name == "row_local")
            .unwrap();
        assert!(sv_timing_core::row_local::plans(m).is_empty());
        assert!(m.gen_loops.iter().any(|l| l.genvar == "__svt_row_train"));
        let again = prepare(&parsed.design, &p.sources, &policy, &dir.join("again")).unwrap();
        assert!(again.trace.records.is_empty());
        assert!(prepare(
            &out.design,
            &[(input[0].0.clone(), text.replace("8'hff", "8'hfe"))],
            &policy,
            &dir
        )
        .is_err());
        let refused = prepare(&out.design, &input, &PassPolicy::default(), &dir).unwrap();
        assert!(refused.trace.records.is_empty());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
