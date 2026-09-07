# V/A-Turbo — Virtual Analog Turbo

Compartment for per-job **precision and lane-group selection** in the GSys
LibreCore AI island. It is the only policy feature that may change arithmetic,
so it is isolated behind its own gate, its own verification mode and its own
promotion evidence.

**Status: specification. The config gate exists and is off. Nothing else is
implemented, no datapath consumes it, and there is no throughput claim.**

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

One `va_turbo_level` field, an **error budget in sixteenths** rather than an
opaque aggressiveness dial, so the runtime knob has the same units as the
promotion gate:

| Level | Meaning |
|---|---|
| `0` | off — exact path, bit-identical to `VaTurboEn=0` |
| `1..15` | admit bank entries whose measured p95 tile error is `<= level/16 %` |

`0` must be bit-exact, not approximately exact: that is what makes the feature
safely shippable-but-disabled. Plumbing (aicfg field or MMIO, PMU readback of
the level actually applied) is unimplemented.

### 2.3 Sub-code word — repurposed, not widened

The existing 3-bit sub-code carries a bank index instead of a candidate index.
No new field, no policy-mux change, no ABI growth. Each bank entry decodes to
`(groups_log2, precision_code)` where `precision_code` is `0=FP32, 1=FP16,
2=INT8`.

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

## 8. Not implemented

The runtime level and its plumbing; the bank in RTL; per-group accumulators and
descriptor slots; the FP16/INT8 selectable operand path; the error-bounded
verification mode; PMU readback. The config gate and the measured bank generator
are the whole of what exists.
