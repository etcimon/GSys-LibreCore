// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! `g6q-core` — the intermediate representation shared by every backend.
//!
//! The package's architecture rests on one constraint: **ingest produces a
//! [`TargetModel`], and everything downstream reads only that**. No emitter, virtual
//! machine or diagnosis model opens a design file, and none of them contains a design
//! constant. This crate defines that model, the conformance vocabulary that makes it
//! honest, and the canonical JSON encoder that makes it reproducible.
//!
//! # Stage
//!
//! Q0 — the skeleton plus the invariants that are expensive to retrofit later:
//!
//! * the machine [`Profile`] and the `faithful` flag, so a deviated or virtio-extended
//!   machine can never be quoted as a hardware result;
//! * [`conform`], the verdict logic, which is the package's first-class output;
//! * canonical [`json`] rendering, so `gen --check` can assert that a model still
//!   produces the expected tree.
//!
//! Ingest fills the model in at Q1.

#![forbid(unsafe_code)]

pub mod conform;
pub mod json;
pub mod model;
pub mod pmu;

pub use conform::{Inputs, Report, Row, Verdict};
pub use json::Json;
pub use model::{Isa, Peripheral, Profile, Provenance, Soc, TargetModel, SCHEMA_VERSION};
pub use pmu::{parse_pmu_table, PmuEvent, PmuTable};

/// Stage marker for the package as a whole.
///
/// Surfaced by the command-line tool so that output is never mistaken for a more complete
/// implementation than exists.
pub const STAGE: &str = "Q0";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn re_exports_are_wired() {
        let m = TargetModel::new("t");
        assert_eq!(m.profile, Profile::Soc);
        assert_eq!(SCHEMA_VERSION, "2");
        assert_eq!(STAGE, "Q0");
    }

    #[test]
    fn a_model_with_a_blocking_row_fails_strict_conformance() {
        let mut m = TargetModel::new("t");
        m.conformance
            .push(Row::classify("vector", Inputs::new(true, false, true)));
        assert!(!m.conformance.passes_strict());
        assert_eq!(m.conformance.blocking().len(), 1);
    }
}
