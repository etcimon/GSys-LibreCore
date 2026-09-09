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
/// | `delay-v5` | PASS-STRATEGY P1 constant lattice (`Const ∘ Const → 0`) + P2 comment interiors; measurement correction, not an optimization gain |
/// | `delay-v6` | P5 compose: continuous-assign / always_comb fragments chained into launch→capture cones (`compose_reg_to_reg_paths`); measurement correction, not an optimization gain |
/// | `delay-v7` | P1 indexed part-select: parse `+:` / `-:` (width LRM-constant, base index may be runtime); no longer Opaque→0 |
/// | `delay-v8` | P1 packed/unpacked dimensions and case-item labels: BinaryOperator tokens in those CST spans are elaboration-constant, not datapath |
/// | `delay-v9` | P1 part-select AST: `Expr::PartSelect` (`[msb:lsb]` / `+:` / `-:`) instead of fake `Binary ":"` / `"+:"` |
/// | `delay-v10` | parsed RHS tree is authoritative at 0 FO4 (no string-heuristic Mul fallback); CST skip of `ConstantRange` / indexed-select width / replication count |
/// | `delay-v11` | P1 lattice seeded from module localparams / parameters / param-map / imported package names (`VpnLen`, `PtLevels`), not only SCREAMING / `*Cfg.*` |
/// | `delay-v12` | module-scoped lowering (B3): each module's CST slice owns its ports / params / regions / instances; multi-module files no longer inherit the file union |
/// | `delay-v13` | genvar is Const only inside its generate-loop span; generate-for/if/case headers are LRM-constant CST (not module-wide `i`) |
/// | `delay-v14` | runtime `/` `%` with a Const divisor (`8`, `WIDTH`, `*Cfg.*`) is a shift/bit-select, not a 120 FO4 SRT divider (`8 / a` stays DivRem) |
/// | `delay-v15` | nested generate-for records each loop's *own* genvar (not the innermost name); `gen_i * Cfg` inside the outer loop is Const∘Const |
/// | `delay-v16` | always_comb `for (int unsigned w = 0; w < N; w++)` index is Const in the body (unrolled); `w * SETS` is not a datapath Mul |
/// | `delay-v17` | NBA write→later-read in one `always_ff` is Q (IEEE NBA schedule), not a combo edge; IndependentLhsBundle can deflate sibling flops |
/// | `delay-v18` | P1 package scope `pkg::NAME` is Const (not `.`-only); `x+1` is increment not 10 FO4 add |
/// | `delay-v19` | only `(W)'(1)` is an increment; general `(W)'(v)` is not parsed (gemm `32'(n-1)*row` stays uncast) |
/// | `delay-v20` | `fmt_row_bytes` / `ai_fmt_bytes` calls are mux-of-shifts, not Mul; still no general `(W)'(v)` |
///
/// Reports must surface this so a number produced by one scheme is never compared
/// with the other. See `architecture/OPTIMIZATION-LEVELS.md` §1.
pub const MEASUREMENT_VERSION: &str = "delay-v20";

/// Hint for which upstream pin the vendored tree should track (see tools/sv-parser.rev).
pub const PARSER_PIN_HINT: &str = "v0.13.5";
