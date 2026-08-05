// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Version strings for report headers and cache keys.

/// Crate / package version (keep in sync with workspace).
pub const PACKAGE_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Timing IR schema version (bump on breaking IR changes).
pub const IR_VERSION: &str = "ir-v0";

/// Measurement semantics version.
///
/// Identifies **how** delay is computed, independent of the cost table:
///
/// | Value | Meaning |
/// |---|---|
/// | `legacy-sum` | pre-P14: source-order chaining, summed expression trees, width-blind |
/// | `delay-v1` | P14: def-use DAG longest path, expression critical chain, width-scaled |
///
/// Reports must surface this so a number produced by one scheme is never compared
/// with the other. See `architecture/OPTIMIZATION-LEVELS.md` §1.
pub const MEASUREMENT_VERSION: &str = "delay-v1";

/// Hint for which upstream pin the vendored tree should track (see tools/sv-parser.rev).
pub const PARSER_PIN_HINT: &str = "v0.13.5";
