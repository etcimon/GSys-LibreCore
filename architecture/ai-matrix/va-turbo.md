# V/A-Turbo — Virtual Analog Turbo

Compartment for per-job **precision and lane-group selection** in the GSys
LibreCore AI island. It is the only policy feature that may change arithmetic,
so it is isolated behind its own gate, its own verification mode and its own
promotion evidence.

**Status: default-off config gate, host bank generator and bounded SV recipe
selection are implemented. No GEMM datapath consumes the new recipe plans; no
throughput, approximation-quality or physical-area gain is claimed.**

The name is descriptive of the intent — trading numeric precision for parallel
throughput the way an analog multiplier trades precision for density — but the
measured study behind it (§4) *rejected* the literal analog-imitating
multipliers. What survives is precision narrowing. The name is kept because the
compartment is what the project refers to; the mechanism inside it is what
measurement supports, not what the name suggests.

## 1. Why a separate compartment

Every other policy output is advisory or restrictive: at worst it wastes cycles.
V/A-Turbo can change results. That single property justifies the separation:

- it cannot be reached by enabling steering, benefit or sub-codes;
- it needs a verification mode that checks **error bounds** rather than the
  bit-exact digests every existing island measurement relies on;
- it must never be promoted on throughput evidence alone — accuracy evidence is
  co-required.

## 2. Interfaces

### 2.1 Config gate — implemented, default off

`config_pkg::ai_cfg_t.VaTurboEn`, defaulted `1'b0` in
`g6lc64_ai_config_pkg.sv`, with legality asserts in `check_cfg`:

| Requirement | Reason |
|---|---|
| `VaTurboEn` requires `PolicySubcodeEn` | the sub-code word carries its selection |
| `VaTurboEn` requires `IslandFpEn` | the measured-best step is FP16 |

The chain is therefore `VaTurboEn -> PolicySubcodeEn -> PolicyBenefitEn ->
PolicyCodecEn -> matrix plane + T2 queue`. The gate exists to keep an
arithmetic-changing feature unreachable, not to switch it on.

### 2.2 Runtime parameter — planned, not implemented

One `va_turbo_level` field, an **error budget** rather than an opaque
aggressiveness dial, so the runtime knob has the same units as the promotion
gate. The ladder is **geometric**: 100 ppm, doubling per step, saturating at
100%.

| Level | Budget | Meaning |
|---|--:|---|
| `0` | 0 | off — exact path, bit-identical to `VaTurboEn=0` |
| `1` | 100 ppm | tightest expressible budget |
| `5` | 1,600 ppm | admits FP16 at `kappa = 1` |
| `8` | 12,800 ppm | admits BF16 and INT8 at `kappa = 1` |
| `15` | 1,000,000 ppm | saturated (100%) |

**A linear ladder was wrong and is retracted.** The first revision made this
linear in sixteenths of a percentage point (625 ppm per step, 9,375 ppm at level
15). That is a *range* error, not a tuning choice: useful budgets span from
FP16's ~1,000 ppm to a logarithmic multiply's 250,000 ppm, so a 625-ppm step
spends all fifteen codes inside the first decade and cannot express the rest at
all. Measured INT8 error (18,527 ppm) fell outside the entire old range, which
made the **encoding**, not the arithmetic, the blocker. Doubling steps put fine
resolution where fine budgets live and coarse resolution where only coarse
budgets are plausible, at the same 4 bits.

`error_bound_q4` is the caller's own bound expressed as an index on this same
ladder, rounded up, so it compares directly against the authorised level.

`0` must be bit-exact, not approximately exact: that is what makes the feature
safely shippable-but-disabled. Plumbing (aicfg field or MMIO, PMU readback of
the level actually applied) is unimplemented.

### 2.3 Sub-code word — repurposed, not widened

The SV research request uses `{bank[1:0], subcode[2:0]}` for a 32-recipe namespace.
The bank is separate context: three bits alone cannot identify 32 independent
recipes. The frozen policy group remains unchanged. The existing topology
subcode evaluator has not been replaced or repurposed; it remains a comparator
for later experiments. No descriptor, MMIO or ISA ABI was changed in this pass.

`va_turbo_select` decodes a request into a bounded execution plan, not an
arithmetic result. The previous host-generated three-entry precision bank is a
separate artifact and must not be loaded as this recipe namespace without an
explicit adapter.

## 3. The heuristic bank

8 entries fill one 3-bit sub-code word; 32 covers four groups' worth. The bank
is **generated from measurement**, not authored:

```
policy_approx.py --emit-bank N --error-budget-percent B --bank-lanes L
```

Each candidate `(precision, groups)` carries its own measured p95 tile error;
entries outside the budget are refused, as are precision classes the accuracy
study found dominated.

**A short bank is reported short.** Padding it to reach 8 or 32 with unmeasured
topologies would be the "stub that looks like a capability" failure mode this
project refuses elsewhere.

### Bank as measured today (64 lanes, 2% budget, per-tile k=16)

| Index | Precision | groups_log2 | Concurrency | p95 error | Gain per 1% error |
|--:|---|--:|--:|--:|--:|
| 0 | FP32 | 0 | 1x | 0% (lossless — model is FP32) | — |
| 1 | FP16 | 1 | 2x | `0.0296%` | **67.6** |
| 2 | INT8 | 2 | 4x | `1.4892%` | 2.7 |

**3 of 8 requested entries are admitted.** Excluded by measurement: BF16 (10x
the FP16 error at identical `k_bytes`), FP8 E4M3/E5M2 (3.3x/6.5x the INT8 error
at identical `k_bytes`), INT4 (~25% tile error), and both approximate-multiplier
topologies (they buy no concurrency at all).

### How the bank legitimately grows to 8..32

Not by adding topologies, but by adding **contexts**, because `groups =
L / k_bytes` and `k_bytes = k x bytes`:

- **tile-k classes.** S0 measured error only at `k=16`. Since `k_bytes` scales
  with `k`, each tile-k class gives a distinct group count per precision, so
  `3 precisions x 4 tile-k classes = 12` legitimate entries.
- **lane provisions.** A bank targeting 32 and 64 lanes doubles that again.

Both need the accuracy harness re-run per tile-k, which is a `--tile-k` option
away and needs no RTL. Until then, claiming 8 entries would be inventing 5.

## 4. Evidence this rests on

| Claim | Source | Status |
|---|---|---|
| usable lanes = `k_bytes` | `run-gemm-ksweep.sh`, 6/6 predictions | **measured** |
| surplus lanes idle, so gang-width choice is worth `+0.0%` | same sweep | **measured** |
| precision narrowing therefore buys `2x` groups per halving | derived from the rule | **derived** |
| per-precision tile error | `policy_approx.py` on real pinned-model tensors | **measured (proxy)** |
| groups convert to throughput | — | **assumed; the gating unknown** |

The last row is the load-bearing assumption, shared with the cluster case. No
concurrency measurement exists, so the entire performance side of V/A-Turbo is
unproven even though its accuracy side is measured.

## 5. Reuse of the existing sub-code control path

V/A-Turbo adds no new control discipline. It reuses what the sub-code work
already built and verified:

- **moving opportunity window** with warm-up before any commit;
- **hysteresis and cooldown**, so a selection cannot oscillate per job;
- **feature-hash silence**, so repeated identical metadata re-decides nothing;
- **paired evidence with explicit taxes** in the evidence ledger;
- **PMU observability** of the code actually applied;
- **default-off gating** with fail-closed unsupported formats.

The window's rejection rule gains one clause: a candidate is dropped if measured
**accuracy** degrades, not only if cycles regress. That makes the ratio, rather
than throughput, the retained quantity.

## 6. Verification plan

The hard part is that approximation breaks the invariant every existing island
measurement depends on.

| Mode | Check |
|---|---|
| `VaTurboEn=0` or `level=0` | **bit-exact**: digests identical to today; existing suites unchanged |
| `level>0` | **error-bounded**: result within the admitted entry's measured budget against an exact reference |

Additional required coverage: level `0` equivalence; each bank entry's decode;
refusal of an entry outside the budget; fail-closed on unsupported formats;
no latches and bounded depth in any new logic; and PMU reporting the applied
level so software cannot be silently downgraded.

## 7. Promotion gates

All four, or it stays off:

1. concurrency measured, not assumed (per-group accumulators exist and scale);
2. paired **throughput and accuracy** evidence on held-out captures;
3. gain-per-error above an explicit threshold, with the threshold recorded;
4. accuracy validated beyond the tile proxy — the current metric is Frobenius
   error on one small model and one prompt, which is not a model-quality result.

## 8. Implemented SV recipe calculations

`corev_apu/ai_island/include/g6lc_ai_policy_pkg.sv` now provides
`va_turbo_request_t`, `va_turbo_plan_t` and the pure combinational
`va_turbo_select(cfg, request, lane_bytes, min_group_bytes, max_groups, consumer_mask)`.
The namespace matches the proposed four-bank catalog; only the following ten
recipes have implemented selection predicates. Every other ID returns
`supported=0`, `apply=0`, native-format fallback, and no action flags.

| ID | Selection calculation | Necessary metadata |
|--:|---|---|
| 0 | Native exact fallback | Valid native job; never asserts `apply` |
| 2 | Skip proven integer-zero products | Full-domain zero proof; floating zero skipping is forbidden |
| 4 | FP32-to-FP16 plan | Approved accuracy bound and representable range |
| 5 | FP32-to-BF16 plan | Approved accuracy bound and representable range |
| 6 | FP32-to-scaled-INT8 plan | Approved bound, safe range and valid scale metadata |
| 9 | Two outputs sharing A | Two columns and sufficient independent bank/accumulator capacity |
| 10 | Four outputs sharing A | Four columns and sufficient capacity; otherwise fallback, not a silent downgrade |
| 11 | Pack independent jobs | Explicit independence and ready-job count |
| 13 | Occupancy-based output grouping | Prefer rows for TALL or N=1, otherwise columns; return tail count |
| 16 | Reuse resident operands | Caller-validated A/B tensor identity, version and residency |

The equations replace speculative constants:

- `row_bytes = ceil(K * element_bits / 8)`; INT4 uses `(K+1)>>1`, other
  formats use shifts. Odd packed tails cannot underallocate a group.
- For powers of two `G=2..32`, choose the largest permitted G such that
  `lane_bytes/G >= max(row_bytes, min_group_bytes)` and G does not exceed
  configured group capacity, ready work, free accumulators or bank capacity.
- The loop is fixed at five comparisons; division by G is a shift. M/N/K are
  limited to 1..256, lane-byte provisioning to powers of two in 8..256, and
  minimum group width is a provisioned power of two of at least eight bytes.
- Tail outputs are `work_count & (G-1)`. They remain work to execute, not work
  silently dropped by the plan. A full-row-per-group fit is conservative; it is
  not a proof that smaller multi-cycle groups would be slower.

`PeLanes` in this model controls byte-lane provisioning. A group estimate does
not prove enough physical arithmetic or SRAM ports exist for concurrent outputs.
The caller must provide actual bank and accumulator capacities; no group count
here is a measured speedup.

### Eligibility is not execution permission

`supported` means the selection rule is implemented. `eligible` means the
metadata and resource predicates pass. `apply` additionally requires all of:

1. `VaTurboEn` and its subcode/benefit/codec/float gates, plus the matrix plane
   and at least one queue (the same prerequisites `check_cfg` enforces, checked
   again here so a hand-built `ai_cfg_t` cannot bypass them);
2. runtime enable and nonzero level;
3. the recipe bit in a **compiled-consumer mask**;
4. the recipe bit in the caller's approved-profile mask;
5. `window_valid` from the opportunity-window owner.

When permission is absent, the action fields remain zero and `target_numfmt`
remains the native input format, even when `eligible=1`. There is no production
call site or nonzero production consumer mask yet.

Conversion predicates compare an externally supplied `error_bound_q4` against
`level` in sixteenths of a percentage point. Bounds must be rounded upward by
the provider. This is an admission-contract check, not an on-chip measurement
of accuracy: a tile p95 observation is not a universal error bound. Profile
approval must cover the actual source format, range, scaling, operation and
context. BF16 remains a candidate because one small FP32-model capture does not
prove it globally dominated by FP16.

The current four-bit level reaches only 15/16 percent. The older host bank
example at 2 percent therefore cannot automatically authorise INT8 here.

The caller must invalidate the window on profile, bank, level, tensor identity,
format or context changes. This combinational function holds no state and does
not implement hysteresis, hash caching or evidence authentication itself. It
preserves the existing window controller for later integration rather than
claiming that control is already wired.

### Verification and integration scope

The existing subcode TB now runs 18,473 swept cases plus directed checks:
8 format encodings, K=1..256, bank capacity=0..8, odd tails, TALL layout,
independent-job and accumulator limits, all 32 IDs, inclusive error bounds,
missing scale/range/accuracy evidence, stale windows and off/approval/consumer
gates. The first remote run failed before the new API existed; after implementation,
all five cache-off and five cache-on parameter profiles pass and retain original
steering-output equivalence. The runner requires a `VA_HEURISTICS PASS` marker.

Evidence: `ai-policy-subcode-20260907T012755Z-43d44da4f6cb`, `status=PASS` with
the identical `VA_HEURISTICS PASS sweep_checks=18473` marker in all ten profiles;
the unchanged codec suite also passes
(`ai-policy-codec-20260907T012056Z-4686d331a62b`).
Local explicit Yosys synthesis of the externally driven selector at
64 lane-bytes / eight-byte minimum / eight groups reports **3,685 generic cells,
zero sequential cells and zero latches**. The disabled wrapper reports zero
cells and constant-zero outputs. Artifact:
`ai-policy-subcode-synth-20260907T022507Z-edf4e2c3949f`. Two earlier builds
measured 518 and 540 cells, before the matrix-plane/queue prerequisites and then
the §9 arithmetic and bound tables were added; both figures are superseded. The
growth from 540 to 3,685 is the cost of the 32-recipe arithmetic table, the ppm
bound tables, the flatness-parameterised quantisation bound and the wider plan
word - still combinational and stateless, but no
longer negligible, and it must be budgeted against the consumer's timing path
when one exists.
These are isolated generic-cell results, not technology area or STA. The selector
adds no sequential search, clock, reset, memory array or changes to the GEMM
critical path because it is not connected there. Integration must budget its
combinational delay and actual conversion/reuse/grouping costs. No new formal
proof is claimed. Existing package/TB flists already include the changed files;
no sources or licence annotations were added.

## 9. Arithmetic and error bounds for all 32 recipes

All 32 IDs now carry **specified arithmetic**, so `supported` no longer means
"this slot is defined" but "a selection predicate exists". Each recipe declares a
bound *kind*, because relative and absolute error are not interchangeable:

| Kind | Meaning | Bound reference |
|---|---|---|
| `EXACT` | reorganises work, arithmetic untouched | identically zero |
| `REL` | perturbs each product by a relative factor | per-product relative |
| `FULL` | integer quantisation, whose per-element error is **absolute** | full scale `K x max|a| x max|b|` |
| `NONE` | unspecified | unusable, bounds to 100% |

`FULL` exists because a quantised small element can be perturbed by 100%, so no
relative per-product bound exists for integer formats. Treating the two kinds
alike would understate integer error badly.

### Derived per-product bounds

With `u = 2^-(p+1)` for `p` explicit mantissa bits, a product of two rounded
operands carries `(1+u)^2 - 1 = 2u + u^2`:

| Arithmetic | Derivation | eps (ppm) |
|---|---|--:|
| FP16 | `u = 2^-11` | 977 |
| BF16 | `u = 2^-8` | 7,828 |
| FP8 E4M3 | `u = 2^-4` | 128,906 |
| FP8 E5M2 | `u = 2^-3` | 265,625 |
| INT8, 127 levels | `(fa+fb)/254 + 1/254^2`, full scale | 7,892 |
| INT4, 7 levels | `(fa+fb)/14 + 1/196`, full scale | 147,961 |
| Mitchell `(1+ma)(1+mb) ~= 1+ma+mb` | `sup ma*mb/((1+ma)(1+mb)) = 1/4` | 250,000 |

The Mitchell figure is the supremum of **this** formulation. The textbook 11.1%
belongs to the log-domain formulation and is not interchangeable with it.

Recipes whose correction terms can only *reduce* error (21, 27, 28, 30, 31)
deliberately report the **uncorrected** supremum, so the analytic bound stays
conservative rather than encoding an unmeasured improvement factor.

### Bound composition, and why kappa is an input

For exact accumulation and per-product relative error `eps`,
`|sum p' - sum p| <= eps * sum|p|`, so relative to `|sum p|` the bound is
`eps * kappa` with `kappa = sum|p| / |sum p| >= 1` absorbing cancellation.
`kappa` is **data dependent**, so it is a required input: defaulting it to 1
would silently assume no cancellation. A missing or sub-unity `kappa` fails
closed.

The runtime level is an error budget on the geometric ladder of §2.2 (100 ppm
doubling per step). Admission requires **both** the
analytic bound and the caller's independently supplied bound to fit the budget:
the analytic bound cannot see the data, and a measured bound is only as good as
its sample.

### Measured validation, and two findings that matter

`policy_approx.py` now measures `kappa` on the real pinned-model tiles and checks
the analytic bound against observed error. Artifact:
`policy-approx-bounds.json`.

**Finding 1 - a per-element bound is vacuous.** Worst-case per-element `kappa`
reaches **47,637** (relative) and **639,792** (full scale) on these tiles,
because single output elements nearly cancel. Every candidate's bound then
saturates to 100% and "the bound holds" becomes trivially true — a vacuous pass,
not validation. A bound and its observation must be taken at the same
granularity. Against the Frobenius-matched `kappa` (**3.292** relative,
**85.681** full scale) the comparison is meaningful:

| Candidate | Kind | eps ppm | Bound ppm | Observed ppm | Holds | Slack |
|---|---|--:|--:|--:|---|--:|
| FP16 | rel | 977 | 3,217 | 339 | yes | 9.48x |
| BF16 | rel | 7,828 | 25,772 | 4,179 | yes | 6.17x |
| FP8 E4M3 | rel | 128,906 | 424,397 | 51,936 | yes | 8.17x |
| FP8 E5M2 | rel | 265,625 | 874,517 | 100,704 | yes | 8.68x |
| INT8 | full | 7,887 | 675,768 | 18,527 | yes | 36.47x |
| INT4 | full | 147,908 | 1,000,000 | 302,839 | yes | 3.30x |
| Mantissa 10/8/6/4/2 bits | rel | 977..265,625 | 3,217..874,517 | 511..205,650 | yes | 3.65-6.29x |
| Mitchell | rel | 250,000 | 823,074 | 136,859 | yes | 6.01x |

**12 of 12 hold**, with 3.3x-36.5x slack, so the composition is sound and
conservative.

**Finding 2 (fixed) - the level ladder could not express what INT8 needs.** With
the measured `kappa`, INT8's sound bound is `675,768` ppm and even its *observed*
error is `18,527` ppm, while the old linear ladder topped out at 9,375 ppm. INT8
was unreachable at any level, so the encoding was the blocker rather than the
arithmetic. That is what the geometric ladder in §2.2 fixes: **every declared
`eps` is now expressible**, and the test suite asserts exactly that for all 32
recipes rather than leaving it to inspection.

**Finding 3 - the remaining conservatism is concentrated in the `FULL` kind.**
With the ladder in place, the measured gap between the level the analytic bound
demands and the level a tight bound would demand is the tuning target:

| Candidate | Kind | Level the analytic bound needs | Level if the bound were tight | Slack |
|---|---|--:|--:|--:|
| FP16 | rel | 7 | 3 | 9.5x |
| BF16 | rel | 10 | 7 | 6.2x |
| Mantissa 8 bits | rel | 9 | 7 | 3.9x |
| Mantissa 4 bits | rel | 13 | 11 | 3.6x |
| FP8 E4M3 | rel | 14 | 11 | 8.2x |
| Mitchell | rel | 15 | 12 | 6.0x |
| **INT8** | **full** | **13 (41% budget, was 14)** | **9 (2.5%)** | **16.8x, was 36.5x** |
| INT4 | full | 15 | 13 | 3.3x |

The `REL` kinds sit at 3.6x-9.5x, which is the ordinary price of a worst-case
bound. `INT8` at **36.5x** is the outlier, because the `FULL` reference
`K x max|a| x max|b|` is doubly pessimistic: it assumes every element hits worst
case *and* that the result norm is small against that product. Authorising level
14 would mean permitting 82% error to admit a recipe whose real error is 1.85%,
which no one should sign.

**Finding 4 - two of my own `FULL` constants were unsound.** The literals 7,887
and 147,908 ppm were *understated* against the exact values 7,889.52 and
147,959.18, so they were bounds that could be exceeded. They are corrected, and
every division in the quantisation bound now rounds **up**: a bound rounded down
is not a bound. The suite asserts the rounding direction rather than only the
values.

### The flatness tightening, measured

The `FULL` reference no longer hardcodes "every element sits at the maximum". It
takes the operand **flatness** `fa = sum|a| / (K x max|a|)` in `(0,1]`, so

```
|sum(a'b' - ab)| <= K*A*B * [ (fa + fb)/(2L) + 1/(4L^2) ]
```

with `L` the positive level count (127 for INT8, 7 for INT4). An absent or
out-of-range flatness falls back to the worst case `fa + fb = 2`, never to
something optimistic.

Measured on the real tiles, `fa + fb = 0.920` against a worst case of 2.0, which
tightens the `FULL` kinds by **2.17x**: INT8's bound drops from 675,768 to
**310,931 ppm**, its slack from 36.5x to **16.8x**, and its required level from
14 to **13**.

**That is real but insufficient, and it settles the design question.** Level 13
still means authorising 41% error to admit a recipe whose real error is 1.85%. A
worst-case full-scale guarantee and a usable INT8 path are simply incompatible on
real data, because the remaining conservatism is error *cancellation* across the
reduction, which a worst-case bound may not assume away.

So the trade is made **explicit and auditable** instead of being resolved by
quietly loosening the bound. `worst_case_waived` lets an approver waive the
analytic gate; the caller's measured bound still applies, and the plan reports
`bound_waived` so an **empirical** promise never becomes indistinguishable from a
**proven** one. The suite checks that a waiver cannot bypass the measured bound,
the accuracy evidence or `kappa`, and that an exact recipe never reports one.

## 10. Not implemented

Per-group arithmetic/accumulators, operand converters, exact-zero and residency
proof producers, descriptor/MMIO runtime plumbing, applied-plan PMU readback and
window-to-request wiring remain open. Reserved recipes (including logarithmic
products, residual correction and outlier streams) remain disabled. There is no
new numerical approximation or measured MAC/s improvement in this increment.
