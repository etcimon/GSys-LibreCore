# Approximation as a measured trade-off (V/A-Turbo, host side)

Implemented by [`python/ai_tensor/va_turbo.py`](../python/ai_tensor/va_turbo.py); tested by
`python/tests/test_va_turbo.py`.

Approximation used to be a **blocker**: a recipe was either bit-exact or it was refused. That
framing hid the only question a framework user actually has — *how much accuracy does this
throughput cost on my tensors?* This module answers that question, from Python, on the caller's
own data, and refuses nothing merely for being inexact.

It also refuses to pretend. **The island RTL has no approximate execution consumer.** Every
approximate number here is a host emulation used to *predict* quality; see §5.

---

## 1. Two axes, never mixed

| Axis | Quantity | Where it comes from |
|---|---|---|
| **Throughput** | predicted cycles per job → speedup | MEASURED RTL simulation (§2), plus a separate k_bytes traffic **model** |
| **Quality** | `rel_fro_error`, `sqnr_db`, `cosine`, `max_abs_error`, `ppm` | the recipe's arithmetic **emulated on the caller's real torch tensors**, scored against the FP32 reference |

The two are reported as separate fields of separate objects (`Speedup`, `Quality`) and are
combined only where the caller asks for it (`pareto`, `autotune`). Recipe 19 exists in the
catalog specifically to keep them visibly independent: it pays INT8's error while keeping
FP32's operand traffic, so it is a pure loss and the frontier drops it.

Within the throughput axis there are *also* two numbers, and they are never averaged:

| Estimate | INT8 | INT4 | Meaning |
|---|--:|--:|---|
| `cycle_speedup` (measured) | 3.54x | 6.14x | 669 / measured cycles |
| `traffic_speedup` (model) | 4.00x | 8.00x | FP32 bytes/element ÷ recipe bytes/element |

The model overpredicts because it cannot see the fixed per-job transaction cost or the
one-element-per-cycle retire bound. Quoting the model as a measurement would be fabrication;
`traffic_provenance="model_from_k_bytes"` says which one it is.

---

## 2. Provenance of every number

All cycle counts: RTL simulation of `g6lc_ai_gemm_seq` at **m=n=8, k=16, PeLanes=8, NCH=1, one
engine, class-0 SRAM memory model, VA_TURBO=1**. Verilator cycles are a **traffic/latency
proxy** — not silicon, not MAC/s, not a real DRAM controller's queueing. Evidence:
`remote-runs/ai-gemm-reuse-20260907T133950Z-9edd1ab08350`; per-job cycles are the `cold_prime`
field of the `REUSE … eng=1 concurrent=0` lines (that line's `baseline` covers 2 batches), and
the residency matrix is the `DUAL` lines.

### 2.0 Measured, and what "measured" was checked against

All seven numeric formats are measured at this shape. BF16 and FP8 E5M2 were first carried
as `inferred_from_k_bytes` from their equal-traffic twins; re-reading the cited log showed
the harness does exercise and fully check them (`signed=1`, the fixture that verifies every
`C` element against an independent reference), so both were promoted to `measured`. The
inferred values had agreed exactly with the measurements, which is a useful check on the
equal-traffic rule but is not a reason to keep quoting a derived number once a measured one
exists.

`INFERRED_TRAFFIC_TWIN` is therefore **empty today**, and that is a result rather than dead
code: it is the machinery that must flag a format the moment one is added, or the shape,
lane count or memory class changes and something is not re-measured. A test injects an entry
so the path cannot rot while unused.

### 2.1 Per-job cycles

| Format | numfmt | bytes/element | cycles | Provenance |
|---|--:|--:|--:|---|
| INT8 | 0 | 1 | 189 | **measured** |
| INT4 | 1 | 0.5 | 109 | **measured** |
| FP8 E4M3 | 3 | 1 | 189 | **measured** |
| FP16 | 5 | 2 | 349 | **measured** |
| FP32 | 7 | 4 | 669 | **measured** (the baseline denominator) |
| BF16 | 6 | 2 | 349 | **measured** |
| FP8 E5M2 | 4 | 1 | 189 | **measured** |

Nothing is inferred today (§2.0). The rule the mechanism would apply is the measured lane
rule: a dot consumes `k_bytes`, so two formats with equal bytes per element issue the same
operand beats — which is why E4M3/E5M2 both land on 189 and FP16/BF16 both on 349, now
confirmed by measuring all four rather than deriving two of them. Were a format to go
unmeasured, the flag propagates all the way out: `CycleEstimate.provenance` →
`Speedup.inferred_from_k_bytes` → `Plan.inferred_from_k_bytes` → `as_dict()`, so a derived
number can never be quoted as a measured one.

### 2.2 Residency matrix (recipe 16)

| Format | none | A | B | both |
|---|--:|--:|--:|--:|
| INT8 | 189 | 164 | 164 | **139** (1.359x) |
| FP32 | 669 | 596 | 596 | **523** (1.279x) |

**Measured for INT8 and FP32 only.** Every other format at `residency != "none"` returns
`provenance="unavailable"` and `cycles=None`. It is not interpolated, and a plan without cycle
data is excluded from `autotune` with the reason recorded, never ranked on a guess.

### 2.3 Analytic bounds

`Recipe.eps_ppm` is the worst-case per-product bound from `va-turbo.md` §9 (FP16 977, BF16 7,828,
E4M3 128,907, E5M2 265,625, INT8 7,892, INT4 147,961, Mitchell 250,000, truncation from the RTL
table). It is at `kappa = 1` and is **not** the measured error on the caller's tensors; the
`Quality` numbers are.

---

## 3. The geometric ladder

`budget_ppm(level)` mirrors `g6lc_ai_policy_pkg::va_turbo_budget_ppm` exactly:

| Level | 0 | 1 | 5 | 8 | 14 | 15 |
|---|--:|--:|--:|--:|--:|--:|
| ppm | 0 (off) | 100 | 1,600 | 12,800 | 819,200 | 1,000,000 (saturated) |

`error_budget_level(ppm)` is the inverse, rounded **up** — the RTL's `error_bound_q4` convention,
so a Python-side choice is expressible in the hardware's own budget encoding. It **fails closed**:
negative, nonfinite or above-100% inputs raise instead of saturating into level 15, because
saturating turns "I cannot express this bound" into "admitted at 100%", which is the defect
`va-turbo.md` §9 records and withdraws. Level 0 is *off*, not "a very small budget".

A linear ladder was tried and retracted: 625 ppm per step spends all fifteen codes inside the
first decade and cannot express a logarithmic multiply's 250,000 ppm at all.

---

## 4. Quality on the caller's tensors

`emulate(a, b, recipe)` applies the recipe's arithmetic to FP32 torch tensors:

| Recipe kernel | Emulation |
|---|---|
| storage narrowing (FP16, BF16) | real `.to(dtype)` round trip |
| FP8 E4M3 / E5M2 | per-tensor scaled `.to(dtype)` round trip (unscaled FP8 would be scored on its exponent range, not its precision) |
| INT8 / INT4 | symmetric per-tensor scale-and-round, 127 / 7 levels |
| mantissa truncation (recipe 21) | bit masking of the FP32 operands |
| Mitchell (recipe 27) | logarithmic multiply, `(1+ma)(1+mb) ≈ 1+ma+mb` |

Both the candidate and the FP32 reference accumulate in **float64**, which is a *proxy* for the
RTL's exact 640-bit integer block reduction — the same caveat `verif/tb/ai_island/policy_approx.py`
carries. Using it on both sides means `native-fp32` scores exactly zero and every other figure is
the recipe's own arithmetic error rather than accumulator noise.

`quality()` **fails closed**: a nonfinite operand, reference, result or metric yields
`status != None` with `rel_fro_error = inf` and `sqnr_db = -inf`. A nonfinite never scores as
good, never enters the Pareto frontier and never wins an `autotune`.

`autotune(...)` takes `max_rel_error_ppm` / `min_sqnr_db` / `min_speedup` (at least one; with
none it would silently mean "give me INT4") and returns the best admissible plan, or a
`NoCandidate` object listing why each candidate lost.

**Which axis it optimises follows which axis the caller constrained**, because the other one
is what they left free:

| Constraint given | Free axis | Objective |
|---|---|---|
| `max_rel_error_ppm` and/or `min_sqnr_db` | speed | maximise `cycle_speedup` |
| `min_speedup` alone | accuracy | **maximise quality** among those that reach it |
| both kinds | — | maximise `cycle_speedup`, the quality floor being explicit |

The middle row is not a detail. Maximising speed under a bare `min_speedup=3.0` returns INT4
at ~190,000 ppm when INT8 at ~9,000 ppm also cleared the bar — spending accuracy the caller
never offered. A test pins both objectives against the recipe set rather than against a
recipe name, so the property survives a change of fixture. `NoCandidate` is **not** an exception and
**not** a silent fallback to native — native would satisfy the accuracy half of an impossible
request perfectly, which is exactly why returning it would be a wrong answer dressed as a right
one.

Measured ordering on a well-conditioned 32x64 @ 64x32 fixture (seed 1234), which the tests pin:

| Recipe | ppm | SQNR | level | speedup |
|---|--:|--:|--:|--:|
| native / resident | 0 | ∞ | 0 | 1.000x / 1.279x |
| FP16 | 302 | 70.4 dB | 3 | 1.917x |
| truncate-10 | 778 | 62.2 dB | 4 | 1.000x |
| BF16 | 2,362 | 52.5 dB | 6 | 1.917x |
| INT8 | 12,685 | 37.9 dB | 8 | 3.540x |
| FP8 E4M3 | 38,260 | 28.4 dB | 10 | 3.540x |
| FP8 E5M2 | 79,041 | 22.0 dB | 11 | 3.540x |
| Mitchell | 95,895 | 20.4 dB | 11 | 1.000x |
| INT4 | 230,158 | 12.8 dB | 13 | 6.138x |

---

## 5. The hardware-execution gate

Every returned plan carries `executable_on_hardware: bool` and a `why` string.

| Class | Recipes | `executable_on_hardware` |
|---|---|---|
| `exact-native` | 0 | **True** — the datapath the island runs today |
| `exact-residency` | 16 | **True**, with a caveat: wired to real GEMM execution in the *verification harness*; production `g6lc_ai_island_top` ties runtime reuse off and invalidation on until an ownership/epoch ABI exists, and `reuse_b_i` is permission, not coherence |
| `emulated-only` | every approximate recipe | **False** |

It is False for **every** approximate recipe because `va_turbo_select` produces selection
metadata only: there is no production call site and no nonzero consumer mask. So the speedup
attached to an approximate plan is what that format's operand traffic costs today — *what such a
consumer would be worth* — not a measurement of approximate hardware, because none exists.

Choosing an approximate recipe from this API means choosing a **prediction**. The tests assert
the flag and the wording for every recipe so the API cannot drift into implying otherwise.

---

## 6. Recipe id map

Read from `corev_apu/ai_island/include/g6lc_ai_policy_pkg.sv` (`va_turbo_arith`) and
`architecture/ai-matrix/va-turbo.md` §8/§9. **Read, never imported** — KD0 independence
(`AGENTS.md` §1) means `ai-tensor` must work standalone.

| Recipe | id | Note |
|---|--:|---|
| `native-fp32` | 0 | exact native fallback |
| `resident-ab-fp32` | 16 | reuse resident A/B; exact |
| `convert-fp16` / `convert-bf16` | 18 | `approx_param` 0 / 1; recipes 4 / 5 are the fixed-target twins |
| `convert-int8` | 20 | INT8 quantisation that narrows storage |
| `quantise-int8-in-place` | 19 | same quantisation, no narrowing |
| `convert-fp8-e4m3` | 7 | carries the E4M3 epsilon (precision code 3) |
| `convert-fp8-e5m2` | **None** | **uncertain**: no id in `va_turbo_arith` carries the E5M2 epsilon; left unset rather than guessed |
| `convert-int4` | 29 | the only FULL / `quant_levels=7` slot that narrows storage |
| `truncate-mantissa-*` | 21 | `approx_param` = retained mantissa bits |
| `mitchell` | 27 | 28 carries **identical** arithmetic metadata and the RTL does not specify how its correction differs, so 28 is not separately emulated |

---

## 7. What this does not claim

- Not a model-quality result. The metric is tile/tensor-level Frobenius error on the caller's
  operands, exactly as `policy_approx.py` warns; it is not perplexity and not accuracy.
- Not silicon. Cycles are Verilator against a class-0 SRAM model on one shape.
- Not the RTL accumulation contract. float64 accumulation is a proxy for the block-floating
  640-bit integer reduction.
- Not a promotion. `va-turbo.md` §7 requires four gates; this module supplies the *paired
  throughput and accuracy evidence* for one shape, on host emulation, and nothing else.
