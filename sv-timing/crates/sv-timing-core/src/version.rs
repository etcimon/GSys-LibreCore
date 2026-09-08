// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Version strings for report headers and cache keys.

/// Crate / package version (keep in sync with workspace).
pub const PACKAGE_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Timing IR schema version (bump on breaking IR changes).
pub const IR_VERSION: &str = "ir-v1";

/// Measurement semantics version.
///
/// Identifies **how** delay is computed, independent of the cost table:
///
/// | Value | Meaning |
/// |---|---|
/// | `legacy-sum` | pre-P14: source-order chaining, summed expression trees, width-blind |
/// | `delay-v1` | P14: def-use DAG longest path, expression critical chain, width-scaled |
/// | `delay-v2` | source origins mapped through the CST; runtime `*` `/` `%` no longer discounted by identifier name; failing-path coverage required before a cleanliness candidate is feasible; ambiguous sequential dependencies left uncertified |
/// | `delay-v3` | `// synthesis translate_off` regions are excluded from measurement (they are not in the synthesized design) |
/// | `delay-v4` | fixed `[msb:lsb]` part-select bounds cost nothing: IEEE 1800 §11.5.1 makes them constant expressions, so parameter arithmetic in a slice bound is elaboration-time, not a divider |
///
/// Reports must surface this so a number produced by one scheme is never compared
/// with the other. See `architecture/OPTIMIZATION-LEVELS.md` §1.
pub const MEASUREMENT_VERSION: &str = "delay-v4";

/// Hint for which upstream pin the vendored tree should track (see tools/sv-parser.rev).
pub const PARSER_PIN_HINT: &str = "v0.13.5";
