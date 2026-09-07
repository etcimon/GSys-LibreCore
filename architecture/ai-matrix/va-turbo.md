# V/A-Turbo — Virtual Analog Turbo

Compartment for per-job **precision and lane-group selection** in the GSys
LibreCore AI island. It is the only policy feature that may change arithmetic,
so it is isolated behind its own gate, its own verification mode and its own
promotion evidence.

**Status: default-off config gate, host bank generator, corrected bounded SV
selection and an exact resident-B consumer are implemented. Recipe 16 is wired
to real GEMM execution in the verification harness; production runtime requests
remain tied off pending an ownership/epoch ABI. No approximate arithmetic,
model-quality gain, physical-area gain or silicon throughput is claimed.**

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
| concurrency converts to throughput, sub-linearly | `run-gemm-concurrent.sh`, 4 engines / 1 port | **measured** |
| shared weights cost the same as private weights | same harness, `shared_b` mode | **measured** |
| lane groups inside one engine convert to throughput | — | **still assumed** |

The load-bearing assumption has been narrowed, not eliminated. Concurrency itself
is now measured rather than projected (§4.1), but it was measured across *whole
engines*, and V/A-Turbo's grouping claim is about *lanes inside one engine*. The
two share the same frontend arithmetic and now the same measured tax.

### 4.1 The concurrency measurement

`verif/tb/ai_island/tb_g6lc_ai_gemm_concurrent.sv` runs N `g6lc_ai_gemm_seq`
engines through the real `axi_mux_intf` into one shared `g6lc_ai_dram_backend`,
and compares the wall cycles of N jobs run back to back against the same N jobs
started on the same cycle. Every engine computes an 8x8x16 all-ones GEMM, so the
golden C is exactly `k` and is re-checked after **both** phases: a concurrency
result that changed an output would be a bug, not a speedup.

| Format | 1 engine | 2 engines | 4 engines | 4-engine efficiency |
|---|--:|--:|--:|--:|
| INT8 | 189 cy | 1.60x | 2.08x | 52% |
| INT4 | 109 cy | 1.41x | 1.48x | 37% |
| FP16 | 349 cy | 1.63x | 2.37x | 59% |
| BF16 | 349 cy | 1.63x | 2.37x | 59% |
| FP32 | 669 cy | 1.65x | 2.43x | 61% |
| FP8 E4M3/E5M2 | 189 cy | 1.60x | 2.08x | 52% |

At `N=1` the measured speedup is exactly `1.000x` for every format, which is the
harness checking itself: the serial and concurrent paths must coincide when there
is nothing to overlap.

Three results, each of which changes the plan:

**Concurrency is real but decays with N.** Two engines keep about 80% efficiency,
four keep 37-61%. The INT8 per-engine PMU cycles inflate under four-way contention
(191 -> 345-360 in the earlier four-channel fixture), with staggered completion.
This measures whole-engine replication, not a universal tax on intra-engine
`groups = L / k_bytes`: shared operand delivery can have a different traffic and
scheduling cost.

**Channel scaling is modest on this fixture.** Four channels reduce four-engine
wall time by 0.3-4.5%, depending on format, not uniformly 1%. The shared port,
short transactions and load/compute/store scheduling constrain the result;
phase and stall counters are needed to distinguish their contributions.

**Narrow formats gain the least from engine replication** - INT4 is worst at
1.48x - because a short job cannot amortise the fixed per-job transaction cost.
This is the exact inverse of the idle-lane picture, where INT4 has the *most*
spare lanes. Both point the same way: for narrow formats the payoff is in
**lane groups sharing one frontend**, not in more engines. This measurement does
not prove that payoff, but it does put a measured price on the shared-memory tax
any such design must pay.

**Sharing only the B address saved no traffic in the original paired modes.**
The backend serves each engine's reads independently; it does not multicast.
The resident-B consumer in §10 instead avoids reloading each engine's existing
tile on later jobs. It does not eliminate the first load into each engine.

The table above is historical diagnostic evidence: all-ones operands and partial
C checking could hide misrouting and byte-bank aliasing. The strengthened harness
checks every output, poisons C between phases and includes distinct signed data.
New paired reports, not the old table, qualify the resident-B consumer.

These are Verilator cycles against the class-0 SRAM model. They are a contention
answer, not MAC/s, not silicon, and not a claim about a real DRAM controller's
queueing.

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
The namespace matches the proposed four-bank catalog. The table below lists the
original ten selection entry points, not a list of qualified execution hardware.
All 32 IDs now carry arithmetic metadata; recipe 26's unspecified bound is an
invalid sentinel. The only nonzero consumer mask in the new GEMM harness is
recipe 16 (resident B). Metadata does not establish datapath support.

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

Conversion predicates compare the caller's upward-rounded geometric ladder index
`error_bound_q4` against `level`. The maximum budget is 1,000,000 ppm; an error
estimate exceeding it is invalid for analytic admission, not clamped into it.
Every approximate recipe requires range evidence; REL recipes additionally
require `relative_domain_valid`, covering the normal-domain rounding premises.
A tile p95 observation is not a universal bound, and float64 host accumulation is
not the RTL FP32 accumulation contract. BF16 remains a candidate because one
small FP32-model capture does not establish global dominance by FP16.

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
| FP8 E4M3 | `u = 2^-4` | 128,907 |
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

### Corrected arithmetic contract and validation

The earlier `policy-approx-bounds.json` reported 12/12 sample comparisons as a
proof of sound composition. That interpretation is withdrawn. Sample success
cannot prove a bound, and the earlier implementation also floored several RNE
constants, truncated `eps*kappa`, assigned RNE bounds to truncation, and clipped
larger errors to 100%. Relative error is unbounded near cancellation; saturation
must not make an out-of-budget candidate admissible.

The corrected contract is:

- RNE bounds use the upward integer ceiling of `1e6*(2u+u^2)` for valid mantissa
  widths. Even positive errors below one ppm return one, not zero.
- Toward-zero truncation uses `1e6*(2u-u^2)`, `u=2^-p`, rounded upward. Recipes
  21/25/30/31 use this bound; recipe 26 has no established derivation and is
  analytically unavailable.
- `20'hfffff` is an **invalid/overflow sentinel**, never a numeric bound. It is
  above the maximum 1,000,000-ppm budget. Invalid precision/count/kappa and
  composed bounds above 100% return it. A waiver cannot override this refusal.
- Composition is `(eps_ppm*kappa_q8 + 255)>>8`. Provider metadata must also
  round upward and must not wrap or saturate an unrepresentable kappa into range.
- Approximation needs range evidence; REL additionally needs
  `relative_domain_valid`. Subnormal conversion, underflow, overflow and special
  values are not covered by an unchecked normal-relative-error formula.
- A finite, representable overbudget bound may still be explicitly waived, with
  `bound_waived` reported. This permits empirical admission, not a worst-case
  guarantee. Missing evidence and unsupported bounds remain refused.

`test_policy_approx.py` has 25 passing tests, including independent rational
oracles, cancellation, zero references, subnormal/overflow refusal and strict
JSON serialization. Nonfinite metrics serialize as null with explicit status;
`bound_validation.schema_version=2` separates raw bounds, Q8 RTL-helper bounds,
sample comparisons and admission. `universal_proof` is false. The FP64-reference
proxy does not model RTL FP32 accumulation. Frobenius and per-element metadata
are separate contracts, not interchangeable values.

Remote `ai-policy-subcode` first failed the new rational oracle at E4M3
(`128906` versus `128907`, run `20260907T033251Z-f86e57c24c7e`), then passed
both default/cache-default profiles (`20260907T034054Z-8edb3d5bfd7c`). The tests
sweep all precision codes and Q8 kappa values, and exercise 369 directed
admission checks. They prove these finite calculations, not arithmetic consumers
or universal model accuracy.

### Flatness with matching units

For integer quantization the absolute bound remains

```
|sum(a'b' - ab)| <= K*A*B * [ (fa + fb)/(2L) + 1/(4L^2) ]
```

The constant second term must not be multiplied by flatness. With the historical
sample statistics `fa+fb=0.9196460738857746`, `kappa=85.68121868438433`, the raw
INT8 formula gives 311,550.09 ppm. Upward metadata gives `flatness_q8=236`,
`kappa_q8=21935`, epsilon 3,647 ppm and composed bound **312,489 ppm** (level 13).
This replaces 310,931 ppm, which was not RTL-matched. The same INT4 calculation
exceeds 100% and is refused instead of being clipped to an admissible value.
These statistics do not establish that usable INT8 and worst-case guarantees
are universally incompatible; that earlier conclusion was too broad.

## 10. Exact resident-B execution consumer

`g6lc_ai_gemm_seq.ReuseBEn` is default off. The verification harness instantiates
the real recipe-16 selector with consumer mask `1<<16` and routes only
`plan.apply && plan.reuse_b` to the sequencer. No arithmetic is changed and no
new tile array or engine is added. A miss follows the existing load path; a hit
skips `ST_LB` after A has drained and enters MAC with reset cursors.

The retained key is B pointer, N, K, LDB, number format and a 32-bit epoch.
M is deliberately not part of the B key. Residency is published only after a
successful job. Reset, invalidation, AXI response errors or descriptor errors
prevent reuse. Wrapped ranges and C/B overlap refuse reuse and residency.
`pmu_reuse_b_hit_o` is sticky per job; existing read/write/cycle PMUs quantify
actual saved traffic.

**Ownership contract:** `reuse_b_i` is permission, not a coherence mechanism.
The caller must keep B immutable from its load through each accepted reuse,
advance its epoch or invalidate before any writer or ownership/context change,
and invalidate before epoch wrap/reuse. All engines holding affected B copies
must receive invalidation. Only quiescent jobs may change the backing tensor.
Hardware key comparisons do not substitute for this lease. Production
`g6lc_ai_island_top` binds presence to `AiCfg.VaTurboEn` but ties runtime reuse
off and invalidation on until a descriptor/MMIO ownership ABI exists.

A related byte-storage defect was corrected: operand rows now use
`ceil(MaxElementBytes*MaxDim/PeLanes)` words per bank, separately from C's element
row stride. `MaxElementBytes` is 1/2/4, default 4 in the standalone sequencer;
the island selects 1 without floating support and 4 with it. Wider runtime
formats fail the capacity check. This prevents FP16/FP32 rows from aliasing while
preserving the integer-only production allocation.

Timing/DFT/power: key comparisons are sampled at job acceptance, range checks
are registered in the existing check phase, and the skip is outside the MAC
arithmetic path. Metadata updates use the existing clock and active-low reset;
SRAM and testmode seams are unchanged. No new clock, latch, ISA/DTS encoding or
production format grant is added. Synthesis smoke is not STA or mapped area.

### Measured: reuse and concurrency compose

Reuse was measured at one, two and four engines on the same shared port. The
gain **grows with contention**, because the beats it removes are the scarce
resource:

| Format | reuse at 1 engine | at 2 engines | at 4 engines |
|---|--:|--:|--:|
| INT8 | 1.152x | 1.255x | **1.358x** |
| FP16 | 1.133x | 1.230x | **1.374x** |
| FP32 | 1.122x | 1.216x | **1.355x** |

Concurrency also improves once reuse has removed the weight traffic, so the two
levers multiply instead of overlapping:

| Format | 4-engine concurrency, cold | with reuse | combined serial-cold to concurrent-warm |
|---|--:|--:|--:|
| INT8 | 2.077x (51.9% of 4x) | **2.448x (61.2%)** | **2.821x** |
| FP16 | 2.374x (59.4%) | **2.879x (72.0%)** | **3.262x** |
| FP32 | 2.433x (60.8%) | **2.936x (73.4%)** | **3.296x** |

Operand read beats halve at every engine count (INT8 4-engine 256 -> 128), and
each result is still checked element by element against the independent
reference. This is one shared-port fixture with repeated same-weight jobs on the
class-0 SRAM model; it is not MAC/s, not silicon, and not model inference. The
first load into each engine is still paid, and the reported
`baseline_including_prime` keeps that cost visible.

### Opportunistic hits: throughput is linear in hit rate

Real job streams are not all-same-weight, so the 0% and 100% corners above are
not the operating point. A mixed sequence of eight jobs on one engine, where the
misses genuinely change B identity (version + epoch bumped and B restaged, so the
golden moves too), gives:

| Hit rate | INT8 speedup | INT8 read beats | FP32 speedup | FP32 read beats |
|---|--:|--:|--:|--:|
| 0/8 | 1.000x | 256 | 1.000x | 1024 |
| 2/8 | 1.034x | 224 | 1.028x | 896 |
| 4/8 | 1.070x | 192 | 1.057x | 768 |
| 6/8 | 1.110x | 160 | 1.089x | 640 |
| 7/8 | 1.130x | 144 | 1.105x | 576 |

Each hit saves exactly 25 cycles of a 189-cycle INT8 job (13.2%) and 73 of a
669-cycle FP32 job (10.9%), and read beats fall exactly linearly. Measured
speedup matches `1 / (1 - 0.132 h)` to three decimals at every point, so the
mechanism is understood rather than merely observed. The harness asserts the hit
count equals the intended count -- a hit that did not happen, or one that
happened unasked, is a bug and not a speedup -- and re-checks C after every job.

**So the headline 1.36x needs both conditions: a ~100% hit rate and multi-engine
contention.** At a realistic 50% hit rate on one engine the gain is 7%.

### Both operands resident: the best speedup per unit area measured

Resident B serves one weight tile against many activations (decode). The mirror
case -- one activation tile against many weight tiles (prefill, attention) -- is
resident A, the same recipe 16 with an independent key: `ptr_a`, `m`, `k`, `lda`,
numfmt and its own epoch, with `n` deliberately absent exactly as `m` is absent
from the B key. The two keys are independent, so a job may hit neither, either or
both. Measured on one engine, identical work, C checked element by element:

| Format | no reuse | A only | B only | **both** |
|---|--:|--:|--:|--:|
| INT8 cycles | 189 | 164 (1.152x) | 164 (1.152x) | **139 (1.359x)** |
| INT8 read beats | 32 | 16 | 16 | **0** |
| FP32 cycles | 669 | 596 (1.122x) | 596 (1.122x) | **523 (1.279x)** |
| FP32 read beats | 128 | 64 | 64 | **0** |

With both operands resident the engine issues **no operand reads at all** -- only
the C writes remain, so it becomes pure compute plus output traffic. Note the
comparison that matters: **1.359x on a single engine equals the 1.358x that
resident B alone needed four contended engines to reach**, and it gets there
without contention.

Cost, from the isolated GEMM synthesis (generic cells, zero latches in all three
configurations):

| Configuration | cells | sequential | area | speedup | return per %area |
|---|--:|--:|--:|--:|--:|
| off | 7,530 | 62 | - | - | - |
| resident B | 7,635 | 74 | +1.39% | 1.152x | 10.9x |
| **resident A+B** | **7,714** | **84** | **+2.44%** | **1.359x** | **14.7x** |
| 8 -> 16 PE lanes | 619,197 | - | +61.4% | 1.510x | 0.8x |
| 16 -> 32 PE lanes | 1,146,467 | - | +85.2% | 1.000x | 0.0x |

That is the whole argument for preferring residency over width: two orders of
magnitude better return per unit area, and it is exact. 32 directed A cases pass
(cold, warm, epoch/pointer/lda/m/k/format mismatch, `n` not part of the A key,
explicit invalidation, missing lease, A/C alias refusal, error and RRESP
recovery), and `VA_TURBO=0` reports 1.000x on all four points with no hits.

Two defects were found and fixed while landing this, both worth recording because
the harness caught them rather than the review: the A skip keyed off `cacheable_q`
which is still clear in `ST_CHK` where A decides, making the skip dead code while
the PMU still claimed a hit; and `pmu_reuse_b_hit_o` only fired on `ST_LA ->
ST_MAC`, so it under-reported precisely in the both-resident case that saves the
most traffic. Both now derive from the same term the FSM uses.

### Intra-engine lane groups: refuted, with the reason

The plan was to spend idle lanes on concurrent output groups. That cannot work in
this datapath, and the blocker is not the lanes:

- one output element is written on its last reduction step
  (`sum_last_q` drives a single `c_w_req`/`c_w_addr`/`c_w_data`), so the engine
  retires **at most one element per cycle** whatever the lane count;
- idle lanes exist exactly when `k_bytes < PeLanes`, which is exactly when a
  reduction already completes in one step, i.e. when the engine is already at
  that one-element-per-cycle ceiling.

The two conditions are mutually exclusive: every configuration with spare lanes
is already retire-bound, and every configuration with retire headroom
(`k_bytes > PeLanes`) has no spare lanes. Measured confirmation on the current
RTL: INT8 `k=16` at `PE_LANES=16` and `PE_LANES=32` are **byte-identical** (250
baseline, 200 warm, 125 cold), so the second sixteen lanes buy exactly nothing,
while 8 -> 16 lanes does pay (189 -> 125 per job).

Grouping is therefore a C-side widening -- more write ports and accumulators --
not a free use of idle lanes, and it should only be revisited if a workload shows
retire saturation with lanes simultaneously idle, which this rule forbids. The
profitable directions remain operand reuse (above) and larger `k` tiles, where
lanes genuinely bind (measured INT8 `k=64`: 668 -> 284 cycles from 8 -> 32 lanes).

Reproduce with `python -B verif/regress/ai-gemm-reuse.py --engines 4 --channels 1
--va 1`. The runner verilates and builds as separate measured steps and records
`/usr/bin/time` CPU percentages, because "it passes `-j 12`" is not evidence that
anything ran in parallel: it did not. See §12. The runner uses the remote proxy, uploads a source-hashed
snapshot, enables assertions and preserves build/simulation logs and status.
Reports pair forced reload and reuse on identical physical resources, separate
cold priming from warm operation, check all C elements and poison outputs before
execution. Signed native-format fixtures, metadata changes, permission gates,
error recovery and alias cases accompany the throughput samples.

## 16. Plan composition: the 32 recipes stack, and the cycle model says how

The recipes are not alternatives. Fitting the measured per-job cycles against
work terms decomposes them:

```
cycles ~= steps + beta(fmt)*read_beats + 11
steps   = m*n*ceil(k_bytes/PeLanes)
beta    = 1.14 (FP32)  1.28 (FP16)  1.56 (INT8)  2.13 (INT4)
```

`beta` is measured directly from the residency sweeps (FP32 669->523 over 128
beats; INT8 189->139 over 32) and the `+11` constant falls out identically for
both. It **rises** as the format narrows, because traffic hides under compute and
a narrow job has less compute to hide it under.

Which term each family touches is the entire composition rule:

| Family | `steps` | `beats` | Retirement |
|---|:-:|:-:|:-:|
| narrowing (1/3/17, 4-7, 18-20, 29) | yes | yes | - |
| residency (16, 17) | - | yes | - |
| zero-skip (2) | yes | - | - |
| grouping (9-15) | - | - | yes (blocked: one C write port) |
| approx arithmetic (21/25/27/28/30/31) | - | - | - |

### The measured stack

| Stack | Cycles | vs FP32 | Source |
|---|--:|--:|---|
| FP32 native | 669 | 1.000x | measured |
| + residency | 523 | 1.279x | measured |
| -> BF16 lossless | 349 | 1.916x | measured |
| -> INT8 lossless | 189 | 3.540x | measured |
| **-> INT8 lossless + residency** | **139** | **4.813x** | **measured** |
| -> INT4 lossless + residency | ~75 | ~8.9x | predicted |

And `3.540 x 1.359 = 4.81` exactly. Note **which** residency figure: composing
with FP32's 1.279x instead predicts 4.53x and understates the stack, because
`beta` is larger at the narrower format. Residency is worth *more* after
narrowing, so the stack is mildly super-multiplicative.

### Why a function and not a loopback sequencer

Two structural facts remove the need for one:

1. **Narrowing collapses.** Exact representability is transitive downward, so
   FP32 -> BF16 -> FP8 is identical to FP32 -> FP8. Iterating gains nothing
   beyond picking the narrowest exact target once, which `best_target()` already
   does. `va_turbo_compose(a, a) == a` is an exact law in the implementation.
2. **Every lever strictly decreases a monotone quantity** (`k_bytes`, then
   `steps`, then `beats`), so a staged pipeline terminates by construction.
   There is nothing for a cycle detector to detect.

`va_turbo_plan_t` was already resource-orthogonal, which is why recipe 17 could
hard-code lossless-narrowing + resident-B in one plan. `va_turbo_compose`
generalises that instead of adding 30 more hard-coded pairs.

### The rules it enforces

- **Orthogonal fields union**; the composed `row_bytes` is the target's.
- **Conflicts are refused, never silently resolved**: two different conversion
  targets (one operand store, one target), or two different group geometries.
- **Per-product error terms ADD.** An exact input contributes 0, which is what
  makes a lossless narrowing free to stack; an approximate stage composed with an
  exact one still pays its own term, so stacking cannot launder error.
- **The budget is re-gated from the REQUEST**, not inherited from an input plan.
  Otherwise a plan selected under a loose level would carry that level into a
  composition made under a tighter one.
- **The window is recomputed from the endpoint, never summed.** `mac_step` is a
  property of the final storage format, so summing per-stage window terms would
  charge a window that never existed. This is the one field that cannot union.

### The ordering hazard, which is why the function takes a fourth argument

Both residency keys in `g6lc_ai_gemm_seq` include the format (the
`ptr`/`n`/`k`/`ldb`/**`fmt`**/`epoch` tuple, lines 554 and 643), so a narrowing
that changes `numfmt` is a residency **miss by construction**. Composing them is
only valid when the resident tile is already stored at the target format --
convert **once** at load, then reuse across many jobs, which is exactly the
operational pattern. The default is refusal and the caller must assert otherwise;
a planner that narrowed *inside* a reuse window would silently destroy the
residency it was trying to stack with.

### Area, and what it argues for next

| Top | cells | sequential | latches |
|---|--:|--:|--:|
| one selector | 4,567 | 0 | 0 |
| two selectors + compose | 12,521 | 0 | 0 |

So composition is **~3,387 cells** -- a lower bound, since any sharing Yosys
found between the two selector instances shifts more of the total onto compose.
Combinational and stateless, and it costs **nothing** until instantiated, being a
package function.

That number is dominated by **re-deriving the error bound** (`va_turbo_bound_ppm`
and `va_turbo_accum_bound_ppm` carry 36- and 44-bit multiplies), which suggested
composing *requests* instead: advance the format and reuse flags on one request,
select again, and re-use the arithmetic in place. That was built
(`va_turbo_stack_request`) and it works -- and then measurement reversed the
recommendation twice. Both reversals are recorded below because each is a
constraint on any future planner, not a detour.

### Reversal 1: a carried epsilon must not enter the multiply

The first version carried the earlier stage's **epsilon** and summed it into
`arith.eps_ppm` before the `eps * kappa` multiply. Two things were wrong with
that, and they turned out to be the same thing:

* **Correctness.** The earlier stage's bound had *already* been scaled by its own
  kappa, so letting it through a second multiply scales that error by kappa
  twice. Conservative, since kappa >= 1, but wrong in form.
* **Cost.** A summed epsilon makes the multiplicand data-dependent, which
  de-constants the per-recipe multiply that 32 folded constants otherwise
  collapse to. ABC technology mapping stalled for **over 31 minutes at 0.1% CPU**
  on a top that had been synthesising in seconds.

The fix is to carry the finished stage's **bound** (`prior_bound_ppm`) and add it
**after** the multiply. Correct, and synthesis returned to 16s. Supporting it
costs the selector +339 cells (4,567 -> 4,906).

### Reversal 2: request-side composition is inherently serial

With that fixed, the request-side top still stalled ABC -- **>13 minutes at 1.5%
CPU against 31s** for the plan-side form. The reason is structural rather than
arithmetic: `select -> fold -> select` is **one combinational cone of roughly
twice the depth**, while plan-side composition keeps two selections **parallel**
and joins them only at the end.

| Form | cells | mapping | shape |
|---|--:|--:|---|
| plan-side (`va_turbo_compose`) | 12,975 | 31s | two parallel selections, joined |
| request-side (`va_turbo_stack_request`) | - | stalls | one serial chain, ~2x depth |

So the conclusion is the opposite of the one the first area number suggested, and
better founded: **plan-side composition is the combinational form**, and
request-side stacking belongs **behind a register or in software**, where the two
selections are separated in time. `prior_bound_ppm` is what makes that pipelined
or software form possible, and it is retained for exactly that. The request-side
top is kept for simulation and deliberately excluded from the synthesis gate,
with the reason recorded at the exclusion site.

The non-exclusive dispatch refactor is therefore **not** justified by this
measurement after all: it would only help a form that should not be
combinational.

Note also that the selector itself *shrank* 4,619 -> 4,567 cells in this pass,
because composition exposed an error in the lossless classification (below).

## 15. Lossless narrowing: an exact traffic lever, and the only one FP32 had

Bit-preserving FP32 had exactly **one** implemented speedup (recipe 16 residency,
1.279x), and the two exact levers that could have helped it -- the lossless
repack family 1/3/17 and zero-skip 2 -- were locked to integer formats by
`policy_integer_format(r.numfmt)`. That gate, not the arithmetic, was what
excluded FP32 from every exact optimisation in the catalog.

The property that actually matters is narrower: **every operand element
round-trips into a strictly narrower container exactly**. That is common in
practice -- weights trained in BF16/FP16 and widened to FP32, already-quantised
values parked in a float container, 4-bit weights held in INT8 -- and when it
holds, the products are *the same real numbers*, so the target format's
per-product epsilon does not apply at all.

### What it costs and what it buys, measured

The only difference is that the narrower format has a wider `mac_step`, so the
FP32 accumulator regroups its folds (k=16 at 8 lanes: 8 windows for FP32, 4 for
BF16). That moves the recipe from a per-**product** error site to a per-**window**
one -- the only class the windowed kappa may soundly multiply -- and makes the
bound the accumulation epsilon (**1 ppm**) instead of the storage epsilon:

| Pair | Cycles | Speedup | Worst measured | Approximate twin | Quality gain |
|---|---|--:|--:|--:|---|
| FP32 -> BF16 | 669 -> 349 | **1.917x** | 5.803 ppm | 7,828 ppm | **1,349x tighter** |
| FP32 -> FP16 | 669 -> 349 | **1.917x** | 0.323 ppm | 977 ppm | **3,025x tighter** |
| FP16 -> FP8 E4M3 | 349 -> 189 | **1.847x** | **0.000 ppm** | 128,907 ppm | exact |
| FP16 -> FP8 E5M2 | 349 -> 189 | **1.847x** | **0.000 ppm** | 265,625 ppm | exact |
| BF16 -> FP8 E4M3 | 349 -> 189 | **1.847x** | **0.000 ppm** | 128,907 ppm | exact |
| BF16 -> FP8 E5M2 | 349 -> 189 | **1.847x** | **0.000 ppm** | 265,625 ppm | exact |
| INT8 -> INT4 | 189 -> 109 | **1.734x** | **0.000 ppm** | 147,961 ppm | **bit-identical** |

Two results deserve emphasis. The 16-bit-to-8-bit rows are **exactly zero**: an
E4M3 product carries at most 8 significant bits and a window of 8 such products
still fits FP32's 24, so the accumulation is exact and both paths return the true
value. And `INT8 -> INT4` is **bit-identical by construction**, not merely
accurate: the products are the same integers, the 640-bit reduction is exact, and
the integer accumulator has no rounding site at all -- so the selector reports
`VA_ARITH_EXACT` with `eps = 0` for integer-to-integer, and `VA_ARITH_REL` with
the 1 ppm accumulation epsilon whenever a float accumulator is involved.

It is **not** bit-identical for the float pairs, and claiming that would be
wrong: regrouping is a real difference. It is just a ~1,350-3,000x smaller one
than the approximate conversion that saves the identical traffic. In one trial
the narrowed run was *more* accurate than the native FP32 run (0.000 vs 0.385
ppm) because fewer windows means fewer rounding sites.

### Witnessed in RTL, with one claim still outstanding

The GEMM harness now runs each pair twice on one engine -- same logical matrix at
the source format and at the target -- with per-element exactness **proven** on
both tiles before either run, C poisoned between them, and every C word compared:

| Pair | Cycles | Speedup | Read beats | max diff |
|---|---|--:|---|--:|
| INT8 -> INT4 | 189 -> 109 | **1.733x** | 32 -> 16 | **0** |
| FP32 -> BF16 | 669 -> 349 | **1.916x** | 128 -> 64 | **0** |
| FP32 -> FP16 | 669 -> 349 | **1.916x** | 128 -> 64 | **0** |

Cycles and beats match the predicted native figures exactly, and the byte ratio
is asserted rather than eyeballed. `INT8 -> INT4` bit-identity is now **witnessed
in hardware**, compared as raw two's-complement int32 over all 64 C words.

The float pairs came out at **0 ULP** on that fixture, which qualifies rather than
confirms the host figures: its operands are small whole numbers, so every product
and partial sum sits far inside FP32's 24-bit significand, **no fold rounds at
all**, and regrouping folds that round nothing cannot move the result. That class
is kept as the control.

### The regrouping difference, witnessed

A second data class closes it. The blocker was thought to be the harness's
integer-only operand path, but that was too pessimistic about the harness rather
than about the arithmetic: values of the form `mantissa * 2^exponent` with
**positive exponents only** are still whole numbers, and a wide enough exponent
ladder does force the accumulator to round mid-reduction. The mantissa is bounded
by the target's explicit mantissa bits (BF16 7 -> <= 127, FP16 10 -> <= 1023) so
every element stays exactly representable, and `mantissa << max_exp` is kept
inside the target's finite range (FP16: `1023 << 6` = 65,472 <= 65,504).

| Data class | Pair | max diff | Elements differing | Bit-identical |
|---|---|--:|--:|:--|
| small integer | INT8 -> INT4 | 0 | 0/64 | **yes** |
| small integer | FP32 -> BF16 | 0 | 0/64 | yes |
| small integer | FP32 -> FP16 | 0 | 0/64 | yes |
| **wide exponent** | INT8 -> INT4 | **0** | **0/64** | **yes** |
| **wide exponent** | FP32 -> BF16 | **32 ULP** | **38/64** | **no** |
| **wide exponent** | FP32 -> FP16 | **5 ULP** | **19/64** | **no** |

So the claim is now witnessed: the float pairs really are not bit-identical, and
**`INT8 -> INT4` stays bit-identical even at wide magnitudes**, which is the
strong prediction -- integer accumulation has no rounding site at any scale.

The magnitude confirms it is regrouping and not lost operand bits. 32 ULP is
<= 3.8 ppm on the worst element, whereas dropping even **one** BF16 mantissa bit
perturbs an element by 2^-8 relative, which moves a same-order C element by
>= 2^-9 = 1,953 ppm = **16,384 ULP**. The observation sits ~512x below that
floor, so the bound (256 ULP, 8x the worst observation) cleanly separates "the
accumulator regrouped" from "the operands changed" -- the only distinction this
experiment has to make.

Note the metrics differ and should not be compared directly: the host figures
(5.803 / 0.323 ppm) are Frobenius-norm ratios over the whole tile, while these are
worst-element ULP distances. Same scale, different quantity.

Because the two runs disagree by design here, this class has no single golden. It
asserts instead that neither run errored, that **no C word is still the poison
value** (so both runs wrote every element), that the difference is bounded, and
that it is nonzero somewhere. That trade -- golden checking for regrouping
observability -- applies only to this class; the small-integer class keeps full
element-by-element golden checking.

### Correction: the TARGET decides exactness, not both ends

The first version of this section required **both** source and target to be
integer for a lossless narrowing to be `VA_ARITH_EXACT`. That was wrong in the
one direction that mattered, and plan composition is what exposed it. The target
is what the accumulator sees: an INT8 job accumulates in **exact integers**, so
`FP32 -> INT8` on integer-valued data (quantised weights parked in FP32) returns
the exact dot product and was nonetheless reported as `REL` at 1 ppm. The
source's own accumulation domain is irrelevant once `lossless_proven` guarantees
the values survive the conversion -- the source run is simply not the one being
executed.

The rule is now `policy_integer_format(target)`, which takes the count of exact
pairs from 1 to **9 of the 17** (INT8 from FP32/FP16/BF16; INT4 from all six
wider formats). The other 8 land on a float target and pay the 1 ppm regrouping.
This makes the measured 4.81x stack an **exact** plan, and it made the selector
*smaller* by one comparison.

### Scope: 17 pairs, not one

Deliberately not FP32-only. Over the seven known formats there are 17 strictly
narrower ordered pairs -- FP32 to six targets, FP16 and BF16 to four each, and
INT8/E4M3/E5M2 to INT4 -- and `VA_LOSSLESS_NARROW` sweeps all 64 (src, dst)
combinations, admitting exactly those 17 as narrowings.

**Refined by an assertion firing in the GEMM harness:** "equal-width pairs are
refused" is true of the **narrowing arm only**, and the first version of this
section overstated it. Recipe 1's pre-existing integer repack arm still admits an
equal-width request on an *integer* source -- INT4 source with an INT4 target
comes back `apply=1` but with `convert=0`, `lossless_narrowed=0`,
`target_numfmt == numfmt`, `VA_ARITH_EXACT` and eps 0. That is correct and worth
having: a repack that claims no traffic saving is a legitimate exact plan, it
simply is not a narrowing. Float sources with an equal-width target are refused
outright, because the repack arm is integer-only. The harness models both arms
rather than the simpler rule.

### Area, and the performance-per-area verdict

Isolated selector synthesis, same top, package and testbench swapped as a pair:

| | cells | sequential | latches |
|---|--:|--:|--:|
| before (no lossless narrowing) | 4,002 | 0 | 0 |
| after | **4,619** | **0** | **0** |

**+617 cells (+15.4%)**, still purely combinational -- the selector adds no
state. For scale, one GEMM engine is 7,530 cells, so the delta is +8.2% of an
engine, giving **11.2x return per %area** for FP32 -> FP16 -- the same league as
residency's 14.7x, and against 0.8x for lane widening. The disabled wrapper still
synthesises to zero cells, so the default-off property is intact.

### What is still required to call this a throughput result

The throughput here needed **no new RTL datapath**, and that is the point: the
narrowed job is an ordinary native job at the target format, so its cycle count
is the already-measured native figure. Status of the four items this section
originally listed as outstanding:

1. **A producer for the proof** -- **done**, `ai_tensor.lossless.prove()` is a
   bit-pattern comparison (not a tolerance) reporting how many elements failed,
   with integrality-and-range for integer targets. `best_target()` returns the
   narrowest exact target; full-precision tensors correctly yield nothing.
2. **A consumer mask bit** -- **done in the harness** (`LOSSLESS_MASK = 1 << 1`).
   Production `g6lc_ai_island_top` still compiles no mask bit for 1/3/17, so the
   island will not act on the plan outside verification.
3. **Paired GEMM measurement** -- **done**, see the table above.
4. **ai-tensor exposure** -- **done**, `ai_tensor.lossless.plan()` reports the
   narrowest exact target with the measured native cycles and a quality column of
   ~0.007 ppm instead of the storage format's epsilon. That is the user-visible
   payoff: FP16-class speed at FP32-class accuracy, when the data permits it.

The regrouping witness is now closed too (see above), and it needed no fractional
operand path after all. What is genuinely left: a **production** consumer mask bit
(the harness has one; `g6lc_ai_island_top` compiles none, and enabling it needs a
descriptor field to carry the proof, i.e. an ABI change), and the zero-skip lever
(recipe 2), still integer-gated and the other exact FP32 opportunity this
section's argument applies to.

## 14. FP8 E5M2 was unreachable; recipe 18 code 3 now carries it

Of the seven supported storage formats, six were selectable and one was not. Bank A pins
FP16 (4), BF16 (5), INT8 (6) and FP8 E4M3 (7); recipe 18's caller-selected map covered only
FP16, BF16 and INT8. So `va_turbo_round_eps_ppm(2)` = 265,625 ppm — E5M2's two-mantissa-bit
bound — existed in the table with **nothing able to reach it**, and code `2'd3` was worse than
merely unused: `approx_param_target` returned INT8 for it while `va_turbo_arith` gave the same
code `VA_ARITH_NONE`, a target and an arithmetic that disagreed.

Code 3 now selects FP8 E5M2 in both halves, and **both** FP8 targets require `scale_valid`:
eight bits of storage cannot cover a tensor's dynamic range unscaled, whichever way the
exponent/mantissa split falls. `VA_E5M2_TARGET` pins the target map, the arithmetic, the
`row_bytes`, the scale requirement, and — by sweeping all 32 ids across all 16 parameter
values — that the epsilon is now reachable at all, so the format cannot quietly become
orphaned again.

## 13. The moving window is real, but it does not rescue the per-product term

The datapath genuinely re-centers. `g6lc_ai_pe_dot_float` is block floating
point per reduction step: it picks `block_exp` from that step's lanes only,
aligns every product into a 640-bit integer, reduces **exactly**, and rounds
once. So a dot of length K carries `2*ceil(K/mac_step) - 1` roundings -- W block
conversions plus W-1 accumulator folds, the first fold being a plain copy -- not
K roundings, and the error from those is re-centered per window rather than
carried across the boundary.

The tempting conclusion is that the element-level kappa was pessimistic and a
windowed kappa should replace it. **That conclusion is wrong, and the data says
so.** Every non-exact recipe here perturbs the *product* before it ever reaches
the reduction: storage conversion, mantissa truncation, logarithmic multiply and
integer quantisation all act on `a_i * b_i`. For a per-product perturbation

    |sum p_i (1 + e_i) - sum p_i| <= eps * sum |p_i|

is **tight**, so intra-window cancellation is not free and the element-level
kappa is the truth rather than pessimism. Substituting the windowed kappa is
measurably unsound on real tiles:

| candidate | windowed total | measured | violation |
|---|--:|--:|--:|
| INT8 | 6,419 ppm | 37,134 ppm | **5.8x over** |
| INT4 | 86,101 ppm | 332,762 ppm | **3.9x over** |

So the window may only ever **add** the post-reduction accumulation term, never
replace the per-product one. What it legitimately buys is the term the previous
report omitted entirely: at window 8 the accumulation term is 3 rounding sites
against kappa 3.04, instead of 31 sites against kappa 17.1 -- a real 5.6x
reduction *of that term*. The term is a few ppm, so it moves no level. Anyone
quoting an improvement from windowing should be quoting it about the accumulation
term only.

The selector therefore computes `bound = per_product + accumulation + floor`,
every term rounding up and overflow failing closed, and honours a claimed window
only when it equals `va_turbo_window_log2(numfmt, lanes)` -- the granularity the
datapath actually reduces exactly. A window the hardware does not implement
would *under-state* the bound here, so the match is a soundness guard, not a
formality.

### What did loosen the premises: the absolute floor

FP16 and both FP8 formats were previously refused outright as
`unqualified_arithmetic_premises`, because their operands leave the normal range
on real tiles and a pure relative model says nothing about subnormals. The fix is
the standard mixed bound, `|fl(x) - x| <= u|x| + eta/2`: supplying the absolute
floor **adds** a term, so it is sound exactly where the relative-only bound was
inapplicable. Those three formats now carry real levels:

| format | previous | now | required level | floor share |
|---|---|---|--:|--:|
| FP16 | refused | qualified | **5** | 4 ppm |
| FP8 E4M3 | refused | qualified | **13** | 59,737 ppm (**6%**, dominates) |
| FP8 E5M2 | refused | qualified | **13** | 468 ppm |

E4M3's honest bound is ~22.7% and it is the *floor*, not the mantissa, that
dominates it -- eta = 2^-9 against a per-tile max scale. That is a real result
about E4M3, not a defect in the model.

Two consequences worth stating plainly. **Every already-admitted candidate's
bound got slightly worse** (BF16 10,152 -> 10,161 ppm, INT8 510,889 -> 510,894,
Mitchell 324,219 -> 324,232), because the report now includes the FP32
accumulation term it previously listed as "not modeled". No level moves, and a
test asserts the direction so it can never silently invert. And
`mantissa_truncated:*` stays unqualified for a different reason -- its fixture
operands are not FP32-representable (`fp32_input_rounding_not_modeled`), which is
a modelling gap no additive floor excuses.

Throughput context, so the trade-off is legible: FP32 -> FP16 narrowing halves
operand read beats and is measured at 669 -> 349 cycles per job (1.92x) on the
class-0 model. FP16 now has a bound (level 5) where before it had none, so that
trade is finally *evaluable*. It is still not enabled: no approximate consumer
exists in the datapath, and these are float64 reference proxies on a seeded
fixture, not model-quality results.

### Gap closed: the 640-bit alignment drop is dead code, and now provably so

`fp_dot_product_aligned` silently returns zero when a product's alignment shift
reaches `FP_DOT_MAXW`, which would drop the **largest** term in a window -- a
wrong answer, not a rounding. Because `block_exp` is the **minimum** lane
exponent, the shift is always non-negative, and in the integer-significand
convention the product exponent spans:

| format | product exponent | spread | product bits | width needed |
|---|---|--:|--:|--:|
| FP32 | [-298, 208] | 506 | 48 | **554** |
| BF16 | [-266, 240] | 506 | 16 | 522 |
| FP16 | [-48, 10] | 58 | 22 | 80 |
| FP8 E5M2 | [-32, 26] | 58 | 6 | 64 |

With 8 bits of headroom for 256 lanes the worst case is 562 of the 640
available, so the zeroing arm is **unreachable for every supported format**. It
was unreachable before too -- but nothing checked it, so a future `MAXW`
reduction or a wider-exponent format would have reached it without a single
failing test. It is now a per-cycle simulation invariant in
`g6lc_ai_pe_dot_float`, and `pe_dot_float_main.cpp` drives the true worst-case
spread (max normal squared beside min subnormal squared in one window) for all
five float formats. 5,024 checks pass. Note that an output-only check could never
have caught a drop here: the tiny term is far below the ULP of the huge one, so
the correctly rounded answer is identical either way -- which is exactly why the
invariant belongs inside the DUT.

### Fitting complete: every format has a bound, including native FP32

Native FP32 is the one candidate the windowed kappa may legitimately multiply.
Nothing perturbs its products: both operands decode exactly, the 24-bit
significands multiply into an exact 48-bit integer, and the reduction is exact.
The only roundings are the one RNE per window and the FP32 accumulator folds --
`2W-1` sites, all **at window boundaries**. So its error site is `per_window`
and the windowed bound is sound for it, the opposite of the 12 per-product
candidates. Measured against an **exact rational** reference rather than float64:

| candidate | storage | win | W | sites | kappa_win | eps ppm | bound ppm | level | measured ppm | site |
|---|---|--:|--:|--:|--:|--:|--:|--:|--:|---|
| native FP32 | 4 | 2 | 8 | 15 | 8.007 | **1** | **10** | **1** | **0.0672** | per_window |
| FP16 | 2 | 4 | 4 | 7 | 4.921 | 977 | 2,743 | 6 | 325 | per_product |
| BF16 | 2 | 4 | 4 | 7 | 4.921 | 7,828 | 21,902 | 9 | 2,644 | per_product |
| INT8 | 1 | 8 | 2 | 3 | 3.198 | 3,124 | 123,037 | 12 | 10,490 | per_product |
| FP8 E4M3 | 1 | 8 | 2 | 3 | 3.198 | 128,907 | 380,966 | 13 | 37,550 | per_product |
| FP8 E5M2 | 1 | 8 | 2 | 3 | 3.198 | 265,625 | 743,085 | 14 | 81,940 | per_product |
| INT4 | 0.5 | 16 | 1 | 1 | 2 | 61,465 | **refused** | none | 206,600 | per_product |
| mantissa 10/8/6/4 | 4 | 2 | 8 | 15 | 8.007 | 1,953..121,094 | 5,475..338,697 | 7..13 | 852..50,740 | per_product |
| mantissa 2 | 4 | 2 | 8 | 15 | 8.007 | 437,500 | **refused** | none | 183,300 | per_product |
| Mitchell | 4 | 2 | 8 | 15 | 8.007 | 250,000 | 699,231 | 14 | 112,200 | per_product |

FP32 accumulation costs **0.0672 ppm measured against a 10 ppm bound**, i.e. it
is not the accuracy limiter at K=16 -- which is what makes the narrowing trade
worth taking on accuracy grounds. Refused cells carry a reason, never a zero.

**FP32 qualifies Frobenius-matched, not per-element, and the reason was a field
width rather than arithmetic.** The worst-ELEMENT windowed kappa is 962.3, whose
bound (962 ppm) sits inside budget level 4 -- but `kappa_window_q8` was Q8.8 in
16 bits, saturating at 255.996, so it failed closed on metadata. The field is now
24 bits (reaching 65,535.996), which costs selector wiring only. At a 1 ppm
epsilon even the widest kappa the field can hold yields 65,536 ppm, so this term
is bounded by ~6.55% by construction and can never be what refuses a plan.

A second correction, to my own RTL: `va_turbo_accum_bound_ppm` multiplied by the
site count on top of a kappa that **already sums all 2W-1 site magnitudes**,
over-stating the term by 2W-1 -- a 15x error at K=16, window 2. It now charges
`eps * kappa` once, with `sites` retained only as the validity guard, which is
the only thing it can soundly be.

One asymmetry remains and is not fixed: the measured column is now exact, while
`kappa_windowed` is still computed from float64 partial sums. The bound side is
now the weaker of the two. And the per-format ppm figures come from a seeded
FP32-resident fixture at the shipped shape, not from the pinned model snapshot,
which is not present on this host.

## 12. The build was serial, and `-j` could not fix it

The four-engine run first looked like a design problem: a 3,712 s build that hit
the timeout. Measurement showed it was **101% CPU** -- one core -- while the
command carried `-j 12`, `--build-jobs 12`, `--verilate-jobs 12` and
`MAKEFLAGS=-j12`. Three findings, in order:

1. `make` on the host parallelises correctly (36 s -> 3 s on a synthetic
   twelve-target check), so the tool was not at fault.
2. `verilated.mk` concatenates every generated `.cpp` into one `__ALL.cpp` unless
   `VM_PARALLEL_BUILDS=1`; its own comment calls that mode "not parallelizable".
   Verilator already set it here, so this was not the cause either -- but the
   variable is now passed explicitly rather than assumed.
3. The actual cause was **in the testbench**. With `--timing`, every task inlines
   into the single `initial` block, which Verilator emits as one `VlCoroutine`;
   coroutines cannot be split by `--output-split-cfuncs`. Eighteen literal
   `run_experiment` calls produced a **321,102-line function in one 27.4 MB
   translation unit**, so the build was one serial `g++` by construction.

Driving those experiments from a table -- same order, same arguments -- emits the
body once and halves the coroutine to 145,977 lines. Result:

| | before | after |
|---|--:|--:|
| 1-engine build | 215 s @ 104% | **42 s @ 148%** |
| 4-engine build | 3,712 s @ 101% | **68 s @ 168%** |
| 4-engine total | 3,740 s | **100 s** |

Verilation is 1.5-2.7 s and simulation 2-20 s, so the object build was and
remains the whole cost. CPU is 148-168% rather than ~1200% because one
translation unit still dominates; table-driving the directed cases the same way
is the next available step and is not required for correctness.

The lesson is the measurement, not the flags: a parallelism claim needs a CPU
percentage next to it.

## 11. Not implemented

Independent lane groups, compact exact floating reductions, operand converters,
production residency/accuracy proof producers, descriptor/MMIO runtime plumbing,
applied-plan PMU readback and automatic evidence-window wiring remain open.
Approximate arithmetic consumers and production multi-cluster support remain
disabled. The resident-B experiment is not model inference or silicon MAC/s.
