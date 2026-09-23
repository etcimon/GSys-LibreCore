// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Structural area attribution. Reads the timing IR. Does not rewrite it.

#![deny(missing_docs)]
#![forbid(unsafe_code)]

//! Hierarchical structural area over a [`sv_timing_core::TimingDesign`].
//!
//! Area weights live in `resources/area-v1.toml`. Until a mapped netlist
//! calibrates that table, the packaged numbers are a placeholder. This crate
//! does not retune FO4 and does not call the correct or emit paths.

mod inclusion;
mod key;
mod marks;
mod model;
mod report;
mod walk;
mod width;

pub use inclusion::{glob_match, Inclusion, InclusionError};
pub use key::{area_key, area_key_record, canon_f64, may_store_area_report, AreaKeyParts};
pub use marks::{
    append_change, cycles_from_log, load_opt_root, load_opt_task, score_task,
    snapshot_from_area_report, AsmMarks, TaskScore, MARKS_MODEL,
};
pub use model::{
    default_area_v1_embedded, load_area_model_path, mul_area_at_width, parse_area_toml, AreaError,
    AreaModel, AreaResult, REQUIRED_AREA_KEYS,
};
pub use report::report_json;
pub use walk::{
    attribute, attribute_with, order_module_rows, AreaReport, CaseGroup, Metrics, ModuleRow,
    PerfBasis, RankRow,
};
pub use width::{bit_width, builtin_net};
