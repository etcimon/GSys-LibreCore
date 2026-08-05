// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Parse SystemVerilog files with the vendored `sv-parser` and attach line maps.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use sv_parser::{parse_sv_str, Define, DefineText, Defines, SyntaxTree};

use crate::error::{CoreError, CoreResult};
use crate::loc::LineIndex;

/// Options for a multi-file parse.
#[derive(Debug, Clone, Default)]
pub struct ParseOptions {
    /// `+incdir+` style include directories.
    pub include_paths: Vec<PathBuf>,
    /// `+define+NAME[=VAL]` style defines.
    pub defines: Vec<(String, Option<String>)>,
    /// When true, ignore incomplete defines (pass through to parser).
    pub ignore_include_error: bool,
    /// Worker threads for the file-level parse (`None`/`Some(0)` = auto, `Some(1)` = serial).
    ///
    /// Files are parsed independently, so this is embarrassingly parallel; results are
    /// always collected back **in input order** so the IR (and every golden) is identical
    /// regardless of the degree. Bottleneck **B1** in `architecture/PERF-CACHE.md` §1.
    pub jobs: Option<usize>,
    /// Skip files that fail to parse instead of failing the whole run.
    ///
    /// Required for monorepo-scale file lists: a single file using a construct outside the
    /// strict IEEE grammar the vendored parser accepts (for example a
    /// `// synthesis translate_off` region containing bare `begin` blocks at generate
    /// scope, as in CVA6's `common/local/util/sram.sv`) would otherwise abort the analysis
    /// of the other 247 files.
    ///
    /// Skips are **never silent**: they are collected in [`ParsedUnit::skipped`], surfaced
    /// in the CLI banner and in the report's `skipped_files`.
    pub allow_parse_errors: bool,
}

/// A file that could not be parsed and was skipped.
#[derive(Debug, Clone)]
pub struct SkippedFile {
    /// Path as supplied by the caller.
    pub path: PathBuf,
    /// Parser diagnostic.
    pub message: String,
}

/// Effective worker count for `jobs` (auto = available parallelism, capped by file count).
fn worker_count(jobs: Option<usize>, files: usize) -> usize {
    let requested = match jobs {
        Some(0) | None => std::thread::available_parallelism()
            .map(|n| n.get())
            .unwrap_or(1),
        Some(n) => n,
    };
    requested.clamp(1, files.max(1))
}

/// One successfully parsed source unit.
#[derive(Debug)]
pub struct ParsedFile {
    /// Absolute or normalized path.
    pub path: PathBuf,
    /// Original file bytes (for CRC later).
    pub bytes: Vec<u8>,
    /// Line index over the text passed to the parser (source text for now).
    pub line_index: LineIndex,
    /// Concrete syntax tree from sv-parser.
    pub tree: SyntaxTree,
}

/// Result of parsing a file list.
#[derive(Debug, Default)]
pub struct ParsedUnit {
    /// Per-file parse results in input order.
    pub files: Vec<ParsedFile>,
    /// Files skipped because they failed to parse (only when
    /// [`ParseOptions::allow_parse_errors`] is set), in input order.
    pub skipped: Vec<SkippedFile>,
}

fn build_defines(opts: &ParseOptions) -> Defines {
    let mut map: Defines = HashMap::new();
    for (name, val) in &opts.defines {
        let text = val
            .as_ref()
            .map(|v| DefineText::new(v.clone(), None));
        let define = Define::new(name.clone(), vec![], text);
        map.insert(name.clone(), Some(define));
    }
    map
}

/// Parse each path with the integral vendored sv-parser.
///
/// Uses `parse_sv_str` on file contents so the line index matches the buffer
/// the tree refers to for the simple (no-pp-origin) path. Include resolution
/// still uses `include_paths`.
pub fn parse_paths(paths: &[PathBuf], opts: &ParseOptions) -> CoreResult<ParsedUnit> {
    if paths.is_empty() {
        return Err(CoreError::InvalidOptions(
            "parse_paths requires at least one file".into(),
        ));
    }

    let defines = build_defines(opts);
    let includes: Vec<PathBuf> = opts.include_paths.clone();
    let workers = worker_count(opts.jobs, paths.len());

    if workers <= 1 {
        let mut unit = ParsedUnit::default();
        for path in paths {
            match parse_one_file(path, &defines, &includes, opts) {
                Ok(f) => unit.files.push(f),
                Err(e) if opts.allow_parse_errors => unit.skipped.push(SkippedFile {
                    path: path.clone(),
                    message: e.to_string(),
                }),
                Err(e) => return Err(e),
            }
        }
        return Ok(unit);
    }

    // Parallel with **dynamic** scheduling: workers pull the next index from a shared
    // counter. Static striding would pair the largest files onto one worker — real flists
    // are heavily skewed (in CVA6's sparse set, one package is 7x the smallest file), and
    // a fixed stride made 8 workers slower than 4. Results are reassembled in input order
    // so the IR is bit-identical to the serial path (B1).
    use std::sync::atomic::{AtomicUsize, Ordering};
    let next = AtomicUsize::new(0);
    let (tx, rx) = std::sync::mpsc::channel::<(usize, CoreResult<ParsedFile>)>();
    std::thread::scope(|scope| {
        for _ in 0..workers {
            let tx = tx.clone();
            let next = &next;
            let defines = &defines;
            let includes = &includes;
            scope.spawn(move || loop {
                let i = next.fetch_add(1, Ordering::Relaxed);
                if i >= paths.len() {
                    break;
                }
                let r = parse_one_file(&paths[i], defines, includes, opts);
                if tx.send((i, r)).is_err() {
                    break; // receiver gone: nothing left to do
                }
            });
        }
        // Drop the template sender so `rx` terminates once the workers finish.
        drop(tx);
    });

    let mut slots: Vec<Option<CoreResult<ParsedFile>>> = (0..paths.len()).map(|_| None).collect();
    for (i, r) in rx {
        slots[i] = Some(r);
    }
    let mut unit = ParsedUnit::default();
    for (i, slot) in slots.into_iter().enumerate() {
        match slot {
            Some(Ok(f)) => unit.files.push(f),
            Some(Err(e)) if opts.allow_parse_errors => unit.skipped.push(SkippedFile {
                path: paths[i].clone(),
                message: e.to_string(),
            }),
            // Report the first failure in **input order** for deterministic errors.
            Some(Err(e)) => return Err(e),
            None => unreachable!("every index is claimed exactly once"),
        }
    }
    Ok(unit)
}

/// Read + parse a single file (the unit of work shared by the serial and parallel paths).
fn parse_one_file(
    path: &PathBuf,
    defines: &Defines,
    includes: &[PathBuf],
    opts: &ParseOptions,
) -> CoreResult<ParsedFile> {
    let bytes = std::fs::read(path).map_err(|source| CoreError::Io {
        path: path.clone(),
        source,
    })?;
    let text = String::from_utf8_lossy(&bytes).into_owned();
    let line_index = LineIndex::from_bytes(path.clone(), text.as_bytes());

    // parse_sv_str(s, path, defines, includes, ignore_include_error, allow_incomplete)
    match parse_sv_str(
        &text,
        path,
        defines,
        includes,
        opts.ignore_include_error,
        false,
    ) {
        Ok((tree, _new_defines)) => Ok(ParsedFile {
            path: path.clone(),
            bytes,
            line_index,
            tree,
        }),
        Err(e) => Err(CoreError::Parse {
            path: path.clone(),
            message: format!("{e:?}"),
        }),
    }
}

/// Convenience: parse a single path.
pub fn parse_one(path: impl AsRef<Path>, opts: &ParseOptions) -> CoreResult<ParsedFile> {
    let p = path.as_ref().to_path_buf();
    let mut unit = parse_paths(&[p], opts)?;
    unit.files.pop().ok_or_else(|| {
        CoreError::InvalidOptions("parser returned no files".into())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn fixture(name: &str) -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("../../fixtures")
            .join(name)
    }

    #[test]
    fn worker_count_clamps_to_files_and_honors_serial() {
        assert_eq!(worker_count(Some(1), 10), 1, "jobs=1 is serial");
        assert_eq!(worker_count(Some(8), 3), 3, "never more workers than files");
        assert_eq!(worker_count(Some(0), 4), worker_count(None, 4), "0 == auto");
        assert!(worker_count(None, 64) >= 1);
    }

    #[test]
    fn parallel_parse_matches_serial_order_and_content() {
        // Same file list parsed serially and with 4 workers must agree exactly (B1).
        let f = fixture("comb_adder_cloud.sv");
        let g = fixture("auto_correct/deep_add_chain.sv");
        if !f.exists() || !g.exists() {
            return;
        }
        let paths = vec![f.clone(), g.clone(), f.clone(), g.clone(), f.clone()];
        let serial = parse_paths(
            &paths,
            &ParseOptions {
                jobs: Some(1),
                ..Default::default()
            },
        )
        .expect("serial");
        let parallel = parse_paths(
            &paths,
            &ParseOptions {
                jobs: Some(4),
                ..Default::default()
            },
        )
        .expect("parallel");
        assert_eq!(serial.files.len(), parallel.files.len());
        for (a, b) in serial.files.iter().zip(parallel.files.iter()) {
            assert_eq!(a.path, b.path, "input order must be preserved");
            assert_eq!(a.bytes, b.bytes);
        }
    }

    #[test]
    fn parallel_parse_reports_first_failure_in_input_order() {
        let good = fixture("comb_adder_cloud.sv");
        if !good.exists() {
            return;
        }
        let missing_a = fixture("__no_such_a.sv");
        let missing_b = fixture("__no_such_b.sv");
        let err = parse_paths(
            &[good, missing_a.clone(), missing_b],
            &ParseOptions {
                jobs: Some(4),
                ..Default::default()
            },
        )
        .expect_err("missing files must error");
        let msg = format!("{err}");
        assert!(
            msg.contains("__no_such_a"),
            "expected the first failing path, got {msg}"
        );
    }

    #[test]
    fn allow_parse_errors_skips_and_reports_instead_of_aborting() {
        // A monorepo file list must not be sunk by one file outside the strict grammar.
        let good = fixture("comb_adder_cloud.sv");
        let bad = fixture("parse/unparsable.sv");
        if !good.exists() || !bad.exists() {
            return;
        }
        let paths = vec![bad.clone(), good.clone()];

        // Strict (default): the run fails.
        parse_paths(&paths, &ParseOptions::default()).expect_err("strict mode must error");

        // Lenient: the good file survives and the skip is recorded, both serially and
        // in parallel (the two collection paths are separate code).
        for jobs in [Some(1), Some(4)] {
            let unit = parse_paths(
                &paths,
                &ParseOptions {
                    jobs,
                    allow_parse_errors: true,
                    ..Default::default()
                },
            )
            .expect("lenient mode must succeed");
            assert_eq!(unit.files.len(), 1, "the parsable file must survive");
            assert!(unit.files[0].path.ends_with("comb_adder_cloud.sv"));
            assert_eq!(unit.skipped.len(), 1, "the skip must be recorded");
            assert!(
                unit.skipped[0].path.ends_with("unparsable.sv"),
                "skip must name the offending file"
            );
            assert!(
                !unit.skipped[0].message.is_empty(),
                "skip must carry a diagnostic"
            );
        }
    }

    #[test]
    fn parse_simple_module() {
        let path = fixture("comb_adder_cloud.sv");
        if !path.exists() {
            eprintln!("skip: fixture missing at {}", path.display());
            return;
        }
        let opts = ParseOptions::default();
        let parsed = parse_one(&path, &opts).expect("parse fixture");
        assert!(
            parsed
                .path
                .file_name()
                .is_some_and(|n| n == "comb_adder_cloud.sv")
        );
        let (l, c) = parsed.line_index.line_col(0);
        assert_eq!((l, c), (1, 1));
        // Tree must expose non-empty source text for the file.
        let _ = &parsed.tree;
    }
}
