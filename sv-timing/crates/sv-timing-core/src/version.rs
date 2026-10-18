// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

//! Version strings for report headers and cache keys.

/// Crate / package version (keep in sync with workspace).
pub const PACKAGE_VERSION: &str = env!("CARGO_PKG_VERSION");

/// Timing IR schema version (bump on breaking IR changes).
pub const IR_VERSION: &str = "ir-v3";

/// Opportunity/structural-emission semantics, independent of delay costs.
/// v1 adds typed +/- offset candidates and unsigned selector indexing.
pub const CORRECTION_VERSION: &str = "correction-v2";

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
/// | `delay-v21` | const-select offset add; numeric/`PLEN`/`IDX_W` `W'(const|ident|ident±1)` collapse (not `int'(x)`); const-condition `?:` is elaboration; `==`/`!=` vs 0 is zero-detect not Compare. Still no general `(W)'(expr)` |
/// | `delay-v22` | nested `c ? Const : (c2 ? Const : … : datapath)` is one mux on the runtime spine (NaN/Inf/zero encodings), not a serial mux chain. Concat of flags+const fields (`{sign, 8'hff, 0}`) counts as an encoding arm; bare ident / `{a,b}` do not flatten |
/// | `delay-v23` | module first-pass auto-const from the reference tree (expression-less exclusive-read assigns); `x+(1<<n)` is a mux of increments; aligned `{x,0}+(y<<K)` is concat; signed `x>0` is a sign bit. Unknown user calls stay Other (2-arg Mux tax reverted). Still no general `(W)'(expr)` |
/// | `delay-v24` | first-pass aligned-net seed: exclusive `{x[MSB:K],{K{0}}}` (and aliases) make `ident+(y<<K)` a field insert. Wrap ident from a call is not assumed aligned |
/// | `delay-v25` | exclusive `t = y << K` temps (BalanceMux shift staging) make `aligned + t` a field insert. Wrap ident + t stays CPA |
///
/// Reports must surface this so a number produced by one scheme is never compared
/// with the other. See `architecture/OPTIMIZATION-LEVELS.md` §1.
///
/// `delay-v26`: loop scope boundaries use original-source coordinates, like
/// assignment nodes, after conditional preprocessing or macro expansion.
/// This repairs constant attribution; it does not change synthesized logic.
/// `delay-v27`: private def-use keys distinguish lexical block-local bindings.
/// `delay-v28`: LRM-constant CST spans (dimensions, case labels, replication
/// counts, generate headers, parameter/typedef declarations) are compared in
/// original-source coordinates, like the operator tokens they must exclude.
/// Before this the exclusion only held when no comment/`ifdef`/macro preceded
/// the span; measurement correction, not an optimization gain.
/// `delay-v29`: width-scaled operator costs (`crate::width`): `fo4-v1` values
/// are the reference-width-32 cost; `add_sub`/`compare`/`shift_var` scale by
/// `log2(max(w,2))/5`, `mul`/`div_rem` by `w/32`, floored at `logic_bit`.
/// Widths come from declarations, typedefs, parameters, package constants and
/// the host param-map; unresolved widths keep the reference cost. Declaration
/// texts are read in the preprocessed frame (`SyntaxTree::get_str`).
/// `delay-v30`: casts `W'(e)` / `type'(e)` / `pkg::t'(e)` are transparent
/// (zero-delay resize), so a cast RHS is parsed instead of falling to the
/// string heuristic; `x * Const` is a shift-add CPA (AddSub), not a 56 FO4
/// array; `x == '0` / `'1` fill-literal compares are reduce-detects.
/// `delay-v31`: an N-operand `+`/`-` tree costs one CPA plus 1.5 FO4 per
/// extra operand (carry-save reduction, `CSA_LEVEL_LOGIC_BITS`), not N-1
/// serial CPAs; measured 0.617/0.726/0.901 ns for 2/3/5 operands at 32 bits.
/// `delay-v32`: `x ± Const` (including `± 1`) is an incrementer billed as
/// Compare (prefix-AND carry chain, log2 width-scaled), not a 1 FO4 gate;
/// `frequency_closure` counts only modules the elaborated width map
/// instantiates and lists the rest as `uninstantiated_modules`.
/// `delay-v33`: a runtime indexed select (`arr[idx]`, `v[idx +: W]`) costs one
/// mux level; constant selects stay wiring. Needed so `SelectIncrement` cannot
/// book the adder it moves behind an index as pure gain.
/// `delay-v34`: the expression grammar no longer splits `||`/`&&` (and
/// `<<`, `==`, …) into a one-byte operator plus a unary reduction; logical
/// joins are one LogicBit each. `rebalance_associative` folds
/// `|a || |b || |c` into `|{a, b, c}` (exact).
/// `delay-v35`: loop-carried accumulators of procedural `for` loops cost
/// trip-count × one body copy (the unrolled serial chain synthesis builds;
/// scoreboard `cid = cid + 1` range walk = a 436-cell netlist chain).
/// `delay-v36`: find-first scans (`for i: if (v[i] && pick == 0) pick = i`)
/// are billed — the guard's compare and gate per iteration, serial across
/// the trip count — and the loop-walk rewrite (A101) offers their exact
/// parallel form; a variable read only in a loop's `if` guard counts as
/// loop-carried.
/// `delay-v37`: guards. The `if` predicates an assignment sits under and the
/// index expressions of a dynamically indexed LHS are reads of the node (the
/// issue queue's select cone reaches `q_d` through `if (grant) q[slot].valid
/// = 0`) and cost a mux on the guard (compare + select level); the structural
/// board had no register-to-register path at all through g6lc_iq / g6lc_lsq
/// and 5× fewer cells than the netlist in scoreboard / rename / store_buffer.
/// `delay-v38`: a runtime index selects among 2^k entries — ceil(k/2) 4:1
/// levels, not one; a zero-trip loop is dead; a guard on a bitwise
/// self-accumulate is one gate (the under-read of rename / scoreboard /
/// iq against the netlist, A104).
/// `delay-v39`: a multiplier scales with log2(width) like an adder (a tree
/// multiplier is a CSA tree of depth ~log w and one adder), not linearly —
/// the 65×65 product had read 227 FO4 against a mapped depth near the
/// 64-bit target sum's (A113).
/// `delay-v40`: inactive if-generate branches are excluded before lowering
/// when explicit host facts or safe, unique localparams prove reachability.
/// Unknown conditions, parameter defaults and ambiguous origins stay live.
/// `delay-v41`: compound assignments retain their read/modify/write
/// dependency in IR. They are measured but not automatically source-rewritten.
pub const MEASUREMENT_VERSION: &str = "delay-v41";

/// Hint for which upstream pin the vendored tree should track (see tools/sv-parser.rev).
pub const PARSER_PIN_HINT: &str = "v0.13.5";
