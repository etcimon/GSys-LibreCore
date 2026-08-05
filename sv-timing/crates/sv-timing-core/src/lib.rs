// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// sv-timing-core — project-independent timing IR foundation.
// Depends only on the in-tree vendored sv-parser (path), not host monorepos.

#![deny(missing_docs)]
#![forbid(unsafe_code)]
// `sv_parser::SyntaxTree` is an enormous mutually-recursive enum; proving auto traits
// (`Send`) for it during the parallel parse (B1) exceeds the default limit.
#![recursion_limit = "1024"]

//! # sv-timing-core
//!
//! Parse SystemVerilog via the integral vendored `sv-parser`, adapt locations
//! to `file:line:column`, lower toward a timing IR, measure/rank paths, and
//! export debug snapshots used by multi-pass auto-correct.
//!
//! This crate has **no** knowledge of monorepo hosts, flists, or project packages.
//! Multi-pass transform orchestration lives in `sv-timing-transform`; emission in
//! `sv-timing-emit`. See `architecture/AUTO-CORRECT-CORE-API.md`.

pub mod cost_table;
pub mod debug_export;
pub mod error;
pub mod expr;
pub mod filelist;
pub mod ir;
pub mod loc;
pub mod lower;
pub mod measure;
pub mod naming;
pub mod opt;
pub mod param_map;
pub mod parse;
pub mod path_class;
pub mod relocation;
pub mod version;

pub use cost_table::{
    default_fo4_v1_embedded, load_cost_model_path, load_fo4_v1_default, parse_fo4_toml,
};
pub use debug_export::{
    debug_dump_ir_json, debug_dump_name_table, debug_dump_paths_csv, debug_snapshot_pass,
    DebugExport, DebugOptions,
};
pub use error::{CoreError, CoreResult};
pub use expr::{classify_binary_op, Expr, ExprStagePlan};
pub use filelist::{
    load_filelist, load_filelist_default, write_filelist, FileList, FileListOptions,
};
pub use ir::*;
pub use loc::{OriginKind, SourceLoc};
pub use lower::{analyze_files, lower_unit, AnalyzeOutput, LowerOptions};
pub use measure::{
    attribute_costs, frequency_closure, line_cost_map, max_freq_mhz_for_path, rank_paths_by_slack,
    rank_regions_by_cost, remeasure_path_slacks, remeasure_path_slacks_with_hints,
    sta_hints_from_design, suggest_opportunities, tag_multi_cycle_paths, CostModel,
    FrequencyClosure, RankedPaths, StaHint,
};
pub use path_class::{
    classify_and_adjust_paths, hints_from_exceptions, path_class_summary, path_signature,
    PathClassHint, PathClassKind, PathClassSummary, PathException, PatternAttempt,
    PATH_CLASS_DETECTOR_VERSION,
};
pub use relocation::{
    build_relocation_plan, is_measure_only, opportunity_to_relocation_kind,
    preferred_actionable_kind, relocation_to_opportunity_kind, scale_correct_budget,
    CorrectScale, RelocationCard, RelocationKind, RelocationOption, RelocationPattern,
    RelocationPlan, RelocationSummary, RelocationTier, RELOCATION_PLAN_SCHEMA,
};
pub use naming::{
    mangle_identifier, MangleStyle, NameKind, NameOrigin, NamePolicy, NameTable, SignalNameTag,
};
pub use opt::{
    resolve as resolve_opt, CacheMode, CutStrategy, OptEffort, OptLevel, OptOptions, OptOverrides,
};
pub use param_map::ParamMap;
pub use parse::{parse_one, parse_paths, ParseOptions, ParsedFile, ParsedUnit};
pub use version::{IR_VERSION, MEASUREMENT_VERSION, PACKAGE_VERSION, PARSER_PIN_HINT};

/// Library identity for report banners.
pub fn banner() -> String {
    format!(
        "sv-timing-core {PACKAGE_VERSION} ir={IR_VERSION} measurement={MEASUREMENT_VERSION} \
         parser_pin={PARSER_PIN_HINT}"
    )
}
