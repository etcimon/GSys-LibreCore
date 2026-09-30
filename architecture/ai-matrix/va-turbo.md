# V/A-Turbo — Virtual Analog Turbo

> **Timing companion:** [`AI-ISLAND-TIMING.md`](AI-ISLAND-TIMING.md) separates the
> core CVXIF datapath from the SoC island and records the current timing-evidence limits.
> Earlier FO4 rankings and idealized stage counts are not physical closure evidence.
> This document covers *throughput*; any actual pipeline change must revalidate latency,
> arithmetic behavior and output retirement together.

Compartment for per-job **precision and lane-group selection** in the GSys
LibreCore AI island. It is the only policy feature that may change arithmetic,
so it is isolated behind its own gate, its own verification mode and its own
promotion evidence.

**Status: exact operand reuse is on the directed test config
`AiCfgVaTurboTest` only. The live `g6lc64` `ai_cfg` keeps `VaTurboEn` at 0.
No approximate arithmetic, model-quality gain, physical-area gain, or silicon
throughput is claimed. A VA level does not scale the dense peak.**

The September 2026 record of the host paths is [`log-2026-09.md`](log-2026-09.md).

## Completion path

This track is parallel to the 100 TOPS order in
[`scaling-100tops.md`](scaling-100tops.md). It does not move the 48× gap, and
it does not start I2 or class 2.

| Step | State | What completion means |
|---|---|---|
| 1. Test config | Done | `AiCfgVaTurboTest` sets `VaTurboEn` with the policy chain and `IslandFpEn`. Directed `run-desc-reuse` elaborates it at 8 MAC/cycle and tile 1024×512×16. |
| 2. Exact reuse | Done on that island | Flags bit 15 and bit 23 skip a matching B or A. M-split reuses B, N-split reuses A, K-split does not. A repeated panel can hit. Keys include pointer, shape, leading dimension, format, and epoch. Overlap, a GEMM error, or a C-store error drops residency. A completion-beat error does not. The host simulator, the soft island, QEMU, and the virtual card do the same when reuse is enabled, and leave it off by default, so a flag alone does not change a product. A hit multiplies the resident bytes. |
| 3. Host schedule | Done for the test geometry | `plan_gemm_s8_va_turbo_test` refuses the live 512-MAC tile and then enables exact reuse on the directed device. A 16×8×8 run skips B on the second panel and C stays all 8s. An 8×8×16 K-split reads both operands and C stays all 16s. An 8×16×8 N-split skips A and C stays all 8s. The default stream stays on the 1024×512×512 box, does not ask for reuse, and does not enable it. `run_gemm_s8_auto` on the directed tile uses the named-panel schedule when an adjacent tile can skip, and stays on that ordinary stream for a K-split or any other capability record. Python `Device.gemm_s8` does the same: a device that publishes its own capability record wins over a host caps override. Python `run_va_turbo_test_s8` follows the same three shapes and the same refusal. `torch_ops.gemm_s8` enables that same exact reuse only when the device caps are the directed tile and two adjacent tiles can skip A or B. A one-row N-split hits A. An M-split such as 16×8×8 hits B. A K-split such as 1×256×256 has no adjacent hit, so reuse stays off. The Rust schedule and `run_va_turbo_test_s8` do the same: reuse is enabled only when a planned tile carries a skip flag, and the 8×8×16 K-split leaves the switch clear, reads both operands, and keeps C all 16s. The soft island does the same when its CAP record is the directed tile. Its default 512-MAC CAP refuses the schedule. The local virtual card and the TCP card agent do the same when the card CAP is that directed tile, and a default 512-MAC card refuses the schedule. A TCP hello that reports 512 MAC/cycle stays on the exact GEMM even if the host asked for the directed tile. The qemu-uio guest driver does the same when the capability window is that directed tile. A window that is not that tile stays on one exact GEMM, including when the host caps were overridden. The native soft island does the same when it is constructed as that directed tile. Its default 512-MAC CAP refuses the schedule, including when the host caps name the directed tile. The native simulator does the same: constructing it with that directed tile runs the schedule, and its default 512-MAC configuration refuses it even if the host caps are overwritten afterward. The QEMU guest model does the same when its capability record is that directed tile, and a 512-MAC model refuses the schedule. Ringing that schedule through the island doorbell does the same: reuse is enabled only when a tile can skip, and the product is read back from guest memory. A live 512-MAC device stays off, and the applied level stays 0. A named recipe on that call is refused while the known witnesses are not all passed, so the default product stays the exact integer GEMM. The result names the shape choice and reports the carried port: the live 64-bit fabric is 8 bytes/cycle and is not promoted. `fed` is this device's own MAC count against that width and the 8-byte control beats. One cluster of 512 is fed. Eight clusters of 4096 on the same 64-bit fabric are not. A native-format call reports the same fields and does not enable reuse. `reuse_blocked` is `live-caps` on the live package, `shape` when the shape is not a decode or its transpose, and `native-call` for one native GEMM. `promotion_missing` stays the known witness list. A one-row decode nominates resident B, and an N-split of that row hits A: `shape_reuse_b` stays true and `hit_a` records the skip. The live call hits neither operand. NumPy and TensorFlow use the same INT8 call. `run_high_level_s8` calls `Device.gemm_s8`, so PyTorch, NumPy, and TensorFlow share that one auto decision. On the directed tile a 16×8×8 started at ticket 5 finishes at ticket 6 with B skipped and C all 8s. An 8×8×16 K-split stays the caller's ticket, one ordinary tile, reuse off, and `reuse_blocked` is `shape`. |
| 4. Completion status | Done | The DMA word keeps the GEMM status. The FIFO and the status register follow the write response. Host `DmaThenClaim` returns the FIFO. |
| 5. Ownership and epoch | Epoch register and host lease done | `REG_OFF_REUSE_EPOCH` (`0x0F00`) reaches `gemm_seq` only when `VaTurboEn` is set. A new epoch misses, the same epoch hits; returning to an older epoch misses with one resident slot and hits while that epoch's panel is still resident with `ReuseBSlots >= 2` (epochs are monotonic by contract, so the caller never relies on either). `ReuseLease::invalidate` is how the caller advances that register after a writer touches A or B. Hardware does not snoop the writer. Live packages still drive epoch 0 because `VaTurboEn` is clear. |
| 6. Error budget | Ladder checked, request stored, not applied | `va_turbo_budget_ppm` matches the policy-package ladder. `va_turbo_compose_ppm` is `(eps * kappa_q8 + 255) >> 8` and fails closed when kappa is below 1 or the bound exceeds 100%. FP16 at kappa 1 fits level 5 and does not fit level 1. A level above 0 also needs a measured ppm: the documented INT8 tile error of 18,527 ppm does not fit level 8 (12,800) and does fit level 9 (25,600). `va_turbo_applied_level` still returns 0. The test schedule refuses level 8 for the documented 18,527 ppm INT8 figure and accepts level 9 only as a budget; the product stays the exact 8s. A level-9 plan for that 8×8×8 job has the same tile and descriptor fields as level 0. The request is stored at `0x0F04` and the completion PMU at `0x0F08` reports applied level 0. |
| 7. Live promotion | Locked off | `g6lc64` `ai_cfg.VaTurboEn` is 0. `AiCfgVaTurboTest.VaTurboEn` is 1. Ingest fails if those two bits swap. Copying the bit onto the live package still waits for an error-bound check that may change a product, which does not exist yet. It is not the next 100 TOPS item. |

Optimization adjustments stay on step 1's geometry. They do not widen
`AI_LIVE_MACS` and they do not change the live nameplate.

### Optimization selection

The host choice follows the shape. Selecting it does not enable reuse on a
device and does not change a product.

1. **Resident B.** `m <= 1`, `n >= 2`, `k >= 2` is decode. The choice is
   recipe 16 with `reuse_b`. `large_decode` means B is at least 99% of the
   reads. 1×256×256 is 996 per mille. The 91.5× row below is a model
   ceiling, not the value this choice returns.
2. **Resident A.** `n <= 1`, `m >= 2`, `k >= 2` is tall. The choice is the
   same recipe with `reuse_a`. 256×1×256 is the large case for A.
   `reuse_a` and `reuse_b` are never both set. A merely wide or tall
   prefill, and an 8×8 square, select nothing.
3. **Withheld VA-Turbo.** Fifteen non-exact ids stay unselected.
   `admit_withheld` lists an id only when the five permission predicates
   hold and the recipe's analytic bound fits the level. At level 9 with
   the documented 18,527 ppm measurement, recipe 4 can be listed and
   recipe 27 cannot. Listing an id does not arm the evidence window.
   `apply` stays false until a measured error bound exists. Live
   `VaTurboEn` stays off.
4. **Left out of this choice.** Prefetch depth stays advice. The subcode
   cache stays off. Lane groups, converters, and approximate consumers
   are not selected here. A K-split still does not reuse; this record is
   a whole-shape choice and does not override a tile whose K origin changed.
5. **MAC rate.** The live sketch is 1 × 512 MAC/cycle × 2 GHz:
   1.024 × 10¹² MAC/s, 2.048 INT8 TOPS, 4.096 INT4 TOPS, 2.048 FP8
   TFLOPS, 1.024 FP16/BF16 TFLOPS, and 0.512 FP32 TFLOPS. The throughput
   sketch is 8 × 4096 × 1.5 GHz and is 48× the live rate in every format
   the sketch can express, 98.3 INT8 TOPS at the top. A decode choice and
   a VA level do not multiply it. The carried width is the narrower of
   the island DMA and the fabric, so a 512-bit island DMA on the 64-bit
   fabric is still 8 bytes/cycle and the live MAC count stays frozen.
   Descriptor, C, and completion beats stay 8 bytes on that fabric.
   A carried port wider than 8 bytes/cycle is the gate that may raise
   the MAC count; class 2 and I2 stay behind that gate.

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
`AiCfgVaTurboTest` is the directed-test config that does set the bit, for
exact operand reuse only. `g6lc64_ai_config_pkg`'s `ai_cfg` stays off.
There is no error-budget level on that test config, so it does not scale
the dense peak. Host `plan_gemm_s8_va_turbo_test` is the schedule for
that island's geometry, 8 MAC/cycle and tile 1024×512×16. It refuses
the live 512-MAC tile. A 16×8×8 all-ones product is two 8×8 panels,
the second requests resident B, and every result is 8. On
`AiCfgVaTurboTest` that second panel issues no B read, and the first
and last C pairs are 8. An 8×8×16
product splits in K, requests no reuse, and every result is 16. On
`AiCfgVaTurboTest` each of those panels has leading dimension 16 and
K offset 0 then 8. The second panel reads B, and each panel's first
and last C pairs are 8. Repeating the second panel then skips B. An 8×16×8 product is
two panels along N. The host result is 8, and the second panel
requests resident A. On `AiCfgVaTurboTest` that panel issues no A
read, and its first and last C pairs are 8.
The default stream stays on the live box.

### 2.2 Runtime parameter — ladder checked, not applied

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
safely shippable-but-disabled. `va_turbo_budget_ppm` and
`va_turbo_error_bound_q4` are that ladder. `va_turbo_applied_level` returns
0 for every code, so the MAC path is unchanged.

`REG_OFF_VA_TURBO_LEVEL` (`0x0F04`) stores the request in bits `[3:0]`.
Bits `[11:8]` are the applied level and read as 0. `PMU_OFF_VA_TURBO_LEVEL`
(`0x0F08`) copies that word when a GEMM completes, so a later write does not
rewrite the job that already finished. `gemm_seq` does not read either
register. On `AiCfgVaTurboTest`, a request of 9 (a write of `32'h109`, which
also sets bit 8) reads back `32'h9`, the PMU word stays 0 until the next
job, and a 2×2×1 all-ones product is still 1. The live package is unchanged.
The virtual card stores that request in side state at the same offset
inside the 4 KiB window. A write of
`0x0F04` clears the card's evidence-window bit, including a rewrite of the
same nibble. The card's PMU copy stays with the job that finished, and a
2×2 product stays `[[19, 22], [43, 50]]`.

### 2.3 Sub-code word — repurposed, not widened

The SV research request uses `{bank[1:0], subcode[2:0]}` for a 32-recipe namespace.
The bank is separate context: three bits alone cannot identify 32 independent
recipes. The frozen policy group remains unchanged. The existing topology
subcode evaluator has not been replaced or repurposed; it remains a comparator
for later experiments. The descriptor and the ISA were not widened.

`REG_OFF_VA_TURBO_RECIPE` (`0x0F0C`) stores `{bank, subcode}` in bits `[4:0]`.
Bits `[12:8]` are the applied id and read as 0. `PMU_OFF_VA_TURBO_RECIPE`
(`0x0F10`) copies that word when a GEMM completes. `gemm_seq` does not read
either register and does not call `va_turbo_select`. On `AiCfgVaTurboTest`,
a write of `32'h110` (id 16, with bit 8 set) reads back `32'h10`. The PMU
word stays 0 until the next job, and a 2×2×1 all-ones product is still 1.

`REG_OFF_VA_TURBO_WINDOW` (`0x0F14`) is the caller's claim that this
level, recipe, and epoch still match the evidence. A write to any of
those three registers clears the bit. `PMU_OFF_VA_TURBO_WINDOW`
(`0x0F18`) copies it when a GEMM completes. The claim does not change
the product: with the bit set, the same 2×2×1 all-ones job is still 1.
Tensor identity, numeric format, and the approval profile are not in
the register map. The host `EvidenceWindow` records them and clears
its claim when any of them changes. A level the budget rejects cannot
arm that claim: level 8 with the documented 18,527 ppm figure stays
unarmed, and level 9 may be armed while the product stays exact. A
recipe whose own analytic bound does not fit the level stays unarmed
too: recipe 27 at 250,000 ppm does not fit level 9, and exact recipe 16
still may.

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

The host `PromotionGates.ready` is that conjunction. The documented
18,527 ppm figure satisfies none of the four. A ready report does not
write `g6lc64` `VaTurboEn`; that bit stays `bit'(0)`. A randomly
initialised Hugging Face BERT layer can match the exact GEMM path and
still leaves `beyond_tile_proxy` clear: one untrained layer is not
held-out model quality. Reusing that layer's query weight matches the
first product and misses a mutated weight. `va_turbo_en_allowed` is
true only when that exact reuse holds and all four gates are ready.
With reuse shown, the witnesses are concurrency `failed` (lane groups
do not add MAC/s), and held-out evidence, a gain threshold, and
beyond-tile accuracy `absent`. A passed witness with no source is
dropped. Marking lane groups as passed concurrency stays `failed`.
Marking the random BERT layer as beyond-tile accuracy stays `absent`.
Checking the four boxes without those witnesses does not allow the
bit. A witness set that is all `passed`, each with its own source,
allows the host decision and still does not write `VaTurboEn`. The
live bit stays `bit'(0)`.

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
call site or nonzero production consumer mask yet. The host `permission`
report takes each config-chain bit separately, so a live package, the
directed test config, or a chain with one gate clear can all be evaluated.
`permitted` is the conjunction of the five predicates, for any recipe id
in `0..31`. `apply` stays false, so recipe 16 with the directed chain,
level 9, both mask bits, and a window is permitted and still not applied.
The report is not the class-eligibility body inside `va_turbo_select`.
The host `decode` names all 32 ids. Every action field on that record
stays clear, including `apply`, reuse, convert, and approximate products.
An id above 31 is unsupported and still has no actions.

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
the C writes remain, so it becomes pure compute plus output traffic. The live
sequencer accepts a **1024×512×512** box on a 512-wide MAC issue. The VA
panels are **512×512×k**, **512×256×k**, and **1024×128×k**, with `k ≤ 512`.
One issue covers 512 elements of K. A full 512×512 output is 262144 MAC
issues, and each half panel is 131072. At `k = 512` the square operands are
262144 INT8 bytes each; the 1024-row A panel is 524288 bytes and its 128-row
B panel is 65536 bytes; the 256-column B panel is 131072 bytes. Flags bit 15
(`reuse_b`) and bit 23 (`reuse_a`) request that skip, and only when
`VaTurboEn` is set. The live package leaves `VaTurboEn` clear, so those bits
are ignored and every panel is fetched. The 1.36× figure in the table is the 8×8×16 harness. The panel byte
counts are the schedule of the 512-wide issue. The default host stream
still cuts at the device box, so a shape that fits stays one descriptor.
`va_panels` selects the named panel with the fewest descriptors, then
the most exact panels, then the wider N. A second M tile of that cut
sets `flags[15]` (`reuse_b`); a second N tile sets `flags[23]`
(`reuse_a`). The live island ignores both while `VaTurboEn` is 0, and
the result C is the same either way. A directed backend run with
`ReuseAEn`/`ReuseBEn` set (not `AiIslandLatencyDefault`) checks the
keys at these widths: N is in the B key and M is in the A key, a
second M tile can hit B, a second N tile can hit A, and holding
invalidate produces no hit. Epoch is in that key on the same backend:
epoch 1 misses a resident 0, the same epoch hits and reads fewer beats,
and returning to 0 misses again. `REG_OFF_REUSE_EPOCH` (`0x0F00`)
forwards that value only when `VaTurboEn` is set. Live packages still
drive epoch 0. The block is inside the 4 KiB SoC window. A guest store
at `0x2200` does not reach the island. The soft-island register bus
reads and writes `0x0F00`.
A write clears the evidence-window bit, including a rewrite of the same
epoch, and that rewrite keeps the resident key. QEMU uses the ingested
name `reuse_epoch`. A store through that parsed map clears the window
the same way, and the completion PMU copies the cleared bit. A guest
doorbell on the 4 KiB window stores the level, the recipe, and the
epoch. The level store leaves a resident 1×1 product at 2. A recipe
store of `32'h110` reads back `16`, clears the window again, including
a rewrite of the same id, and the next doorbell still returns 2.
Arming the window and ringing again still returns 2, and the completion
copy at `0x0F18` is 1. The epoch store clears the live window and leaves
that copy at 1 until the miss, which returns 9 and copies 0. A C that starts on a
resident operand does not skip, drops the key, and the next disjoint
job misses; the job after that hits. That C pair is still the all-ones
dot. `run-desc-reuse.sh` is a directed island with `VaTurboEn` set
(8 MAC/cycle, AccTile 1024×512×16, not `AiIslandLatencyDefault`):
latched flag bit 23 skips A at m=1024, flag bit 15 skips B at n=512,
both bits together issue no operand read, and n=128 does not hit a
resident 512. K is in that key: a resident k=16 B still yields 16, and
the same flag with k=8 reads B again. A moved B pointer, an A
pointer moved by 32 bytes, and a changed lda or ldb read that operand
again, and the next job with the new key skips it. The moved A is
ones against B byte 0x21, so the dot is 264. A SLVERR on one B beat
returns `ST_ERR` and drops the key; the next reuse request reads B
and yields 264, and the job after that skips B. A SLVERR on the C
store does the same after a hit that did not read B. A SLVERR on the
A read of a job that was eligible to skip B cancels that skip, returns
`ST_ERR`, and the next reuse request reads B again. The job after
that reload skips B and the product stays 264. When both operands
are already resident, a SLVERR on the C store reads neither operand,
returns `ST_ERR`, and the next job with both flags reads both again;
the job after that skips both and stays at 264. A B-read SLVERR
after A has already been skipped does not read A, returns `ST_ERR`,
and drops A; the next request reads A again, and the job after that
reload skips A and stays at 264. A SLVERR on the completion word,
after GEMM has already skipped A and written C, returns `ST_ERR` and
leaves A resident: the next request still skips A and stays at 264.
The stored completion word is still status 0 with ticket 42; the
sticky descriptor status is `ST_ERR`. Host `DmaThenClaim` returns the FIFO status even when the stored
word still says 0 or was discarded. The word is observed, and it is
not the result. The sim, the MMIO model, and the virtual card post
that same pair: the word keeps the GEMM status, and a failed
completion beat changes only the FIFO. A GEMM failure is the other
way around: the C-store error on ticket 36 stores status 1 in that
word, and the sticky status is `ST_ERR` as well.
Odd `n = 3`
stores single 32-bit words: `C[0][2]` is 1, and a taller M with that
N skips B while the tail stays 1. Format is in the key: the same bytes as INT4 yield
20 and skip on the next INT4 job, and switching back to INT8 reads
again and yields 8712. The host stream leaves both flags clear on a K
split: 1×1×513 is two tiles, and 1×1×1024 is two tiles of k=512 whose
pointers move by 512 while lda and ldb stay 1024. Note the
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

## 19. The approximate-arithmetic family, measured on the right axis

Truncation (21/25/30/31) and Mitchell (27/28) measure **exactly 1.000x** in cycles,
which is why earlier passes set them aside. That measurement is correct and the
conclusion drawn from it was too strong: they are cycle-neutral *by construction*
-- they change no operand byte and no reduction step -- so **cycles are the wrong
instrument**. Their only path to throughput is **area -> lanes -> steps**.

So the question is what area they could recover. Isolated synthesis of
`g6lc_ai_pe_dot` answers it:

| Lanes | dot cells | per lane | share of the 7,530-cell engine |
|---|--:|--:|--:|
| 4 | 2,868 | 717 | 38% |
| 8 | **5,867** | 733 | **78%** |
| 16 | 11,834 | 740 | 157% |

**The engine is essentially all multiplier**, at a near-constant ~735 cells per
lane. The area target is large, not marginal -- the opposite of what
"cycle-neutral" might suggest.

Because the array is linear and dominant, a constant-area budget buys lanes in
proportion, and lanes reduce `steps` until `lanes >= row_bytes`:

| Multiplier shrink | Lanes | FP32 cycles | Speedup |
|---|--:|--:|--:|
| 1x | 8 | 668 | 1.00x |
| 2x | 16 | 412 | 1.62x |
| 4x | 32 | 284 | 2.35x |
| **8x** | **64** | **220** | **3.04x** |
| 16x | 64 | 220 | 3.04x (capped) |

### The verdict, and the niche that survives

The trade has a **hard ceiling of 3.04x** for FP32 at k=16, it needs an **8x**
smaller multiplier to reach it, and it stops dead at the lane optimum -- measured:
32 -> 64 lanes gave FP16 exactly nothing.

Against that, on the same engine and shape:

| Strategy | Speedup | Error | Area |
|---|--:|--:|---|
| lossless narrow FP32 -> BF16 | 1.92x | ~0 ppm | **frees** area |
| lossless narrow FP32 -> INT8 | **3.54x** | **0 ppm** (exact) | **frees** area |
| truncate-10 + 8x-smaller multiplier | 3.04x | 1,953 ppm | constant |
| Mitchell + 8x-smaller multiplier | 3.04x | 250,000 ppm | constant |

So narrowing **dominates** wherever the data permits it: more speedup, no error,
and it *reduces* area instead of merely re-spending it. But the niche does not
vanish. Narrowing needs the values to fit the target's **range**, and truncation
does not: it drops mantissa bits while keeping the FP32 exponent. `truncate-10` at
1,953 ppm is **4x more accurate than BF16** (7,828) *while preserving FP32 range* --
a point on the ladder no conversion recipe covers.

There is also a structural tension worth naming: narrowing reduces `row_bytes`,
which *lowers* the lane optimum and leaves a big array over-provisioned;
truncation keeps `row_bytes` and makes each lane cheaper instead. They are two
routes to the same goal -- more effective MACs per unit area -- and which one
applies is decided by whether the data can be narrowed, not by preference.

### The shrink factor, measured -- and it closes the family

`R` was an assumption in everything above. It is now measured, on the FLOAT lane,
which is the one that matters: truncation and Mitchell are floating-point
approximations, while the 78% figure above is the *integer* dot. The float product
is one 24x24 multiply per lane (`g6lc_ai_fp_pkg.sv:215`), so truncating to `keep`
explicit mantissa bits makes it `(keep+1)` squared. Masking the decoded mantissas
ahead of the **same package function** the datapath calls:

| keep | mantissa | cells | shrink vs exact |
|--:|---|--:|--:|
| 23 (exact FP32) | 24x24 | 4,094 | 1.00x |
| **10** (`truncate-10`) | 11x11 | **1,257** | **3.26x** |
| 4 (`truncate-4`) | 5x5 | 665 | 6.16x |
| 1 | 2x2 | 558 | 7.34x |

Those are **upper bounds**, and the distinction decides the recipe. Only the product
path shrinks; the 640-bit alignment and the reduction tree do not. With `X`
non-shrinking cells per lane the achievable factor is `(4094 + X)/(1257 + X)`:

| X | 0 | 2,000 | 4,094 | 8,000 |
|---|--:|--:|--:|--:|
| R | 3.26x | 1.87x | 1.53x | 1.31x |

`X` could not be measured: synthesising the whole float dot **stalls ABC on the
640-bit alignment cone** (>14 minutes at 4% CPU), the same pathology that excluded
the request-side composition top from the synthesis gate. So the bound is reported
and the point value is not invented.

**The conclusion.** The area->lanes ladder needs `R >= 8` to reach its 3.04x
ceiling. Even at the impossible `X = 0`, `truncate-10` gives 3.26x, which the
measured lane sweep turns into roughly **2.0-2.35x** -- and any real alignment cost
pushes it lower. Against that, lossless narrowing to INT8 is **3.540x at zero error
and it frees area rather than re-spending it**.

So the approximate-arithmetic family **cannot beat narrowing even on its own best
route**. That is now a measurement rather than an argument, and the niche is exactly
what it was: data whose *range* forbids conversion, where `truncate-10` at 1,953 ppm
is still 4x more accurate than BF16 with FP32 range preserved.

## 18. The cycle model, validated out of sample — and what it says to measure next

`cycles = steps + beta(fmt)*read_beats + c` was fitted on the
`tb_g6lc_ai_gemm_concurrent` residency sweeps at **PeLanes=8**. The
`ai-gemm-codec-basis` runs already on disk are an independent test of it: a
different testbench (`tb_g6lc_ai_gemm_backend` `+measure`), **four** lane counts
and five shape classes.

**The beat formula is exact on 140/140 points**:
`read_beats = ceil(m*row_bytes/8) + ceil(n*row_bytes/8)`, every format, every
shape, every lane count.

**Beta is exact and lane-independent.** Solving `beta = (cycles - steps - c)/beats`
at all 16 (format x lane) points of the 8x8x16 job:

| Format | 8 lanes | 16 | 32 | 64 | solved beta | spread |
|---|--:|--:|--:|--:|--:|--:|
| INT8 | 188 | 124 | 124 | 124 | 1.562500 | **0** |
| INT4 | 108 | 108 | 108 | 108 | 2.125000 | **0** |
| FP16 | 348 | 220 | 156 | 156 | 1.281250 | **0** |
| FP32 | 668 | 412 | 284 | 220 | 1.140625 | **0** |

Those are the same four constants the 8-lane fit produced, to the digit, from a
harness the fit never saw. The two testbenches differ by **exactly one cycle** in
the additive constant (11 for `gemm_concurrent`, 10 for `gemm_backend`) and not at
all in `beta` -- so the constant is per-harness overhead and `beta` is the machine.

### k>16 collapses the model: `beta` is `row_bytes`, not format

`+measure_k` existed in the testbench and had never been run -- reaching k=64 needs
`MaxDim >= 64` and no runner exposed it. Driving it (integer formats, nch=1, ar=2,
m=n=8, PeLanes=8) breaks the per-format `beta` table:

| Format | k | row_bytes | cycles | per-format beta | per-`row_bytes` |
|---|--:|--:|--:|--:|--:|
| INT8 | 32 | 32 | 348 | +18 | **0** |
| INT4 | 32 | 16 | 188 | +18 | **0** |
| INT8 | 64 | 64 | 668 | +54 | **0** |
| INT4 | 64 | 32 | 348 | +54 | **0** |

At k=16 `row_bytes` and format are in 1:1 correspondence, so the two tables were
indistinguishable -- **the same trap as "twice the element width in lanes"**. The
cross-check is unambiguous: **INT8 at k=32 and FP16 at k=16 both have
`row_bytes = 32` and both measure exactly 348 cycles.** The numeric format does not
enter the model at all.

And `beta = 1 + 9/row_bytes` exactly at every point, which expands
`beta * beats` into `beats + 9*(m+n)/8`. So the whole model reduces to

```
cycles = ceil(steps + read_beats + 1.125 * operand_rows) + c
steps        = m*n*ceil(row_bytes/lanes)
read_beats   = ceil(m*row_bytes/8) + ceil(n*row_bytes/8)   (0 for a resident operand)
operand_rows = m + n                                       (0 for a resident operand)
```

**one cycle per read beat plus 9/8 cycles per operand row**, with a single fitted
constant instead of four per-format ones. It is exact on **49 measured points**: seven
formats at k=16, the full residency matrix, sixteen lane-sweep points, four k>16
points and sixteen decode points. The four `beta` values are now consequences.

A pre-existing gotcha found on the way: `$test$plusargs("measure")` **prefix-matches**
`+measure_k`, so asking for the k sweep silently runs the shape sweep too. Harmless
here (the shape sweep is idempotent) but it means the k lines appear after a full
`+measure` block.

### The lane rule is now derived rather than tabulated

`steps` bottoms out when `ceil(row_bytes/lanes) == 1`, so the optimum is simply

```
optimal_lanes = row_bytes = k * bytes_per_element
```

which reproduces all four measured saturation points (INT4 8, INT8 16, FP16 32,
FP32 64). §"Lane grouping" records the rule as "twice the element width in lanes"
with a warning that the fit is k=16-specific; this is that rule's general form, and
at k=16 `row_bytes` simply happens to equal twice the element width. It predicts the
optimum **moves with k** -- INT4 8 -> 16 -> 32 and INT8 16 -> 32 -> 64 as k goes
16 -> 32 -> 64 -- which is exactly what the `+measure_k` sweep was written to test.
**No `k>16` data exists on disk**, so that remains a prediction shared by the model
and the testbench comment, and `+measure_k` is the run that settles it.

### The priority INVERTS between prefill and decode

`steps` scales with `m*n` and `beats` with `m+n`, so the shape decides the lever.
At each shape's own optimal lane count, FP32:

| Shape | steps | beats | traffic | B share | resident_B | resident_both |
|---|--:|--:|--:|--:|--:|--:|
| prefill 8x8x16 | 64 | 128 | 66% | 50% | 1.49x | 2.95x |
| prefill 16x16x16 | 256 | 256 | 52% | 50% | 1.35x | 2.09x |
| prefill 256x256x256 | 65,536 | 65,536 | 53% | 50% | 1.36x | 2.14x |
| **decode 1x16x16** | 16 | 136 | **85%** | **94%** | **5.04x** | 6.75x |
| **decode 1x256x256** | 256 | 32,896 | **99%** | **100%** | **91.5x** | 141x |

The host `select_workload` chooses exact resident B for this decode shape
and exact resident A for the transposed shape. `large_decode` is this
1×256 row. The 91.5× figure stays a model ceiling. The choice does not
apply a recipe.

At m=1 the weight matrix B is essentially **all** of the traffic, re-read for every
token, so the measured 1.279x came from a square tile -- the *least* favourable
shape for residency. A square tile at its own optimal lane count is exactly
balanced (`steps == beats`, because `steps/beats = 4n/lanes` and `lanes = k*bytes`
gives 1 at `n == k`), which is why residency caps near 2x there.

### Measured: decode residency, and the ceiling that reconciles the numbers

`tb_g6lc_ai_gemm_concurrent` now runs a `DECODE` experiment (m=1) alongside the
square `DUAL` one, so both appear in the same run:

| Format | shape | cold | resident B | resident both |
|---|---|--:|--:|--:|
| FP32 | square 8x8 | 669 | 596 = **1.1225x** | 523 = **1.2792x** |
| FP32 | **decode 1x8** | 158 | 85 = **1.859x** | 75 = **2.107x** |
| INT8 | square 8x8 | 189 | 164 = 1.1524x | 139 = 1.3597x |
| INT8 | **decode 1x8** | 56 | 31 = **1.806x** | 27 = **2.074x** |
| FP16 | decode 1x8 | 90 | 49 = 1.837x | 43 = 2.093x |
| INT4 | decode 1x8 | 39 | 22 = 1.773x | 19 = 2.053x |

So the direction is confirmed -- decode residency is **1.53-1.66x larger** than the
square tile's -- and two of my earlier statements need correcting.

**Correction 1: the model needed a ceil.** Every square-tile point has an integral
`beta*beats`, so it was invisible that the work terms must be rounded UP. At m=1
every fractional case landed on `.125` and measured exactly one cycle higher: a
partial beat costs a whole cycle. With `ceil(steps + beta*beats) + 11` the model is
exact on all 16 new decode points -- out-of-sample at a new *shape*, not just new
beat counts.

**Correction 2: "the largest opportunity in the catalog" was overstated.** At 8
lanes the decode gain **saturates near 2x**, and the cap is `steps + c`, not
traffic: for INT4 the additive constant alone is 58% of the resident-both time,
which is why INT4 has the *worst* decode ratio (1.773x) despite B being the same
8/9 of its traffic. Resident-A is worth almost nothing at decode (1.068x), so at
m=1 "residency" effectively means "resident B".

The two figures are reconciled by a closed form. At m=1 both `steps` and `beats`
grow linearly in n, so the ratio **converges** rather than diverging:

```
decode resident-B ceiling  =  1 + beta * (row_bytes/8) / ceil(row_bytes/lanes)
```

| Format | at 8 lanes | measured (n=8) | at 64 lanes |
|---|--:|--:|--:|
| FP32 | 2.14x | 1.859x | **10.12x** |
| INT8 | 2.56x | 1.806x | 4.12x |
| INT4 | 3.12x | 1.773x | 3.12x (already 1 step/elem) |

The ceiling **rises as lanes shrink the step term**, which is why the same
mechanism gives ~2.1x on the 8-lane test corner and a far larger figure on the
shipped 256-lane SKU, where `ceil(row_bytes/lanes) == 1` for every format at
k <= 256. B's share itself is `n/(m+n)` and nothing else -- measured identically
at 888/1000 for all four formats, because `row_bytes` and `beta` cancel, so it is a
property of the shape alone.

### n=16, now measured -- and a residual worth keeping

The blocker was the harness's fixed 512 B B sub-slot, which correctly refused FP32
at n=16, k=16 (it needs 1,024 B). Deriving the slots from the geometry lifts that
without moving anything at the default: each region keeps a 512 B floor, so
`OFF_B`/`OFF_C`/`SLOT` come out `0x200`/`0x400`/`0x600` exactly as before and every
multi-engine address is unchanged (verified -- the default run is byte-identical).

| Format | cold | resident B | resident both | B share |
|---|--:|--:|--:|--:|
| INT8 | 100 | 51 = 1.961x | 47 = 2.128x | 941 |
| INT4 | 67 | 34 = 1.971x | 31 = 2.161x | 941 |
| FP16 | 166 | 85 = 1.953x | 79 = 2.101x | 941 |
| **FP32** | **298** | **153 = 1.948x** | **143 = 2.084x** | **941** |

Against predictions of **1.980x / 2.122x** -- right to ~1.6% -- and B's share came
out `941/1000`, exactly `n/(m+n) = 16/17`.

### The residual: a precise law, and three refuted mechanisms

n = 8/16/24/32 x four formats x four residency states is 64 measured points. The
term is **exactly linear, format-independent, and a function of n ALONE**:

| B state | residual |
|---|---|
| streams (cold, warm_A) | `0.375 * (n - 8)` |
| resident (warm_B, both) | `0.5 * (n - 8)` |

It is zero at n=8, which is also **why the square 8x8 tile fits the base model
exactly** -- the square tile never violated the law, it sits at the law's root. With
the correction applied the model is exact on all 64 points.

Three structural explanations were tested and **all three are refuted**, which is
most of what is now known about it:

* **Not C write beats.** The first reading was `0.75 * (w_beats - 4)`, which fits
  perfectly at m=1 -- because `w_beats == n/2` there. Sweeping m at fixed n=32
  breaks it: `w_beats` grows **32x** (16 -> 512) while the residual stays at +9/+12.
* **Not hiding behind compute.** The same sweep grows `steps` 32x (256 -> 8,192)
  with the A-resident residuals pinned at exactly +9/+12.
* **Not C bank conflicts.** C is banked by `j % PeLanes`, so a column collision must
  vanish once `PeLanes >= n`. Measured at PeLanes 8/16/32 with n=32, the residual is
  +9/+12 at **every** one, including `PeLanes == n`.

| probe | steps | w_beats | cold | warm_A | warm_B | both |
|---|--:|--:|--:|--:|--:|--:|
| m=1, 8 lanes | 256 | 16 | +9 | +9 | +12 | +12 |
| m=8 | 2,048 | 128 | +9 | +9 | +12 | +12 |
| m=16 | 4,096 | 256 | +8 | +9 | +11 | +12 |
| m=32 | 8,192 | 512 | +6 | +9 | +9 | +12 |
| m=1, 16 lanes | 128 | 16 | +9 | +9 | +12 | +12 |
| m=1, 32 lanes | 64 | 16 | +9 | +9 | +12 | +12 |

What survives is the law plus one suggestive pattern: the two states whose **A
operand streams** (cold, warm_B) fall below the law at large m (+9 -> +6, +12 -> +9),
while the A-resident states stay exactly on it. So A read traffic hides part of it.
Naming the term needs RTL instrumentation -- a stall counter -- rather than more
black-box sweeps, so it stays empirical and out of the base model.

### The ratio converges, as the ceiling required

| n | cold | resident B | ratio | resident both | ratio |
|--:|--:|--:|--:|--:|--:|
| 8 | 158 | 85 | 1.859x | 75 | 2.107x |
| 16 | 298 | 153 | 1.948x | 143 | 2.084x |
| 24 | 438 | 221 | 1.982x | 211 | 2.076x |
| 32 | 578 | 289 | **2.000x** | 279 | 2.072x |

Resident-B climbs with diminishing steps toward the closed-form ceiling of
**2.141x**, approached from below exactly as predicted. Resident-both goes the
*other* way and settles near 2.07x, because once no operand reads remain the ratio
is set by `steps + c` rather than by traffic -- the same cap that makes INT4 the
worst decode case.

**A pre-existing assumption the axis exposed.** `JOB_N` below 8 fails, and
confusingly: `JOB_N=4` reports a golden mismatch at `C row0 col4`, a column the
nominal tile does not have. The directed suites perturb the shape with *literals*
(`n = 6, 7`, `m = 4`, `k = 8`) to test which fields are part of the reuse key, and
several deliberately do not re-stage the operands -- so they rely on the nominal
staging already covering the larger shape. At the 8x8 default, B rows 4 and 5 exist
because eight were staged. Below it they do not. The axis is now bounded at
`JOB_M, JOB_N >= 8` and `JOB_K >= 16` with that reason, rather than letting a
smaller geometry produce a mismatch that reads like an RTL bug.

`run-gemm-concurrent.sh` now takes `JOB_M`/`JOB_N`/`JOB_K`, so the geometry axis is
no longer manual-invocation only, and it rejects `JOB_K % 16 != 0` while INT4 is in
the format tables -- the guard for the latent row-stride bug below.

**Latent bug found while probing that point:** at `JOB_N=16, JOB_K=8` the harness
sets `lda = ldb = k`, giving INT4 a 4-byte row stride, and the loader does not read
non-8-byte-aligned rows back correctly. All-ones fixtures pass (uniform data cannot
detect a shifted read); the first *signed* INT4 tile fails golden. Guarded rather
than papered over, and recorded as a real constraint on the new geometry axis.

## 17. The retire ceiling: lanes and C ports are one joint requirement

Three measurements each looked like an independent dead end:

* INT4 gained **0%** past 8 lanes, and INT8/FP8 nothing past 16;
* 16 -> 32 lanes was **byte-identical** for INT8 at the reference shape;
* grouping (recipes 9-15) produced **no** speedup at all.

They are not three failures. They are one mechanism seen from three sides, and the
cycle model states it in a line: `steps = m*n*ceil(row_bytes/lanes)`, whose floor
is `m*n` because the RTL writes one C element on its last reduction step through a
single `c_w_req` port. **One C port retires one element per cycle, whatever the
lane count.** Therefore

* more **lanes** stop helping the moment `row_bytes <= lanes` (retire-bound);
* more **C ports** cannot help while `groups == 1`, because two ports need two
  dots to have finished in the same cycle;
* and `groups > 1` exists only when `lanes > row_bytes` -- which is precisely what
  **narrowing manufactures**.

So testing either lever alone had to measure nothing. Doubling from the shipped
8 lanes / 1 port:

| Format | row_bytes | steps | groups | bound by | lanes only | ports only | both |
|---|--:|--:|--:|---|--:|--:|--:|
| FP32 | 64 | 512 | 1 | lanes | 1.620x | **1.000x** | 1.620x |
| FP16 | 32 | 256 | 1 | lanes | 1.579x | **1.000x** | 1.579x |
| INT8 | 16 | 128 | 1 | lanes | 1.512x | **1.000x** | 1.512x |
| INT4 | 8 | 64 | 1 | **retire** | **1.000x** | **1.000x** | 1.416x |

The INT4 row is the measured refutation reproduced by the model: at 8 lanes it is
already retire-bound, so lanes alone buy exactly nothing.

### What C-port widening is actually worth, and for whom

At 64 lanes -- FP32's measured optimum -- the picture separates cleanly:

| Format | groups | all ports | cycles |
|---|--:|--:|---|
| FP32 | **1** | **1.000x** | 221 -> 221 |
| INT8 | 4 | **1.623x** | 125 -> 77 |
| INT4 | 8 | **2.057x** | 109 -> 53 |

**FP32 gains nothing from any number of C ports**, because at 64 lanes it uses all
64 and has one group. That is the control which proves the mechanism rather than
merely fitting it.

So C-port widening is **not a general throughput lever**: it is the second half of
narrowing's. Build it only jointly with lanes, only for narrowed formats, and only
up to the group count -- ports beyond `groups` are pure area, which is the same
trap the 16 -> 32 lane experiment already fell into from the other direction.

These are **projections** from a model fitted at 8 lanes and k=16; no RTL has more
than one C write port, and `ai_tensor.pipeline` labels every such figure
`modeled`. The independent lane-provisioning runs are consistent with the step term
(FP32 measured up to +320% at 64 lanes on 16x16, against an 8x step reduction the
model predicts before traffic), but the joint lanes+ports configuration has never
been built and its 2.06x is a prediction, not a result.

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
and production residency/accuracy proof producers remain open. A level request
may be stored at `0x0F04`. The applied level in that word and at `0x0F08`
stays 0. A recipe id may be stored at `0x0F0C`. The applied id in that word
and at `0x0F10` stays 0. `gemm_seq` does not call `va_turbo_select`.
A window claim at `0x0F14` clears when the epoch, level, or recipe is
written. It does not apply a recipe.
Approximate arithmetic consumers and production multi-cluster support remain
disabled. The host decode keeps every action field clear and does not
select lane groups, floating reductions, converters, proof producers,
approximate consumers, or multi-cluster by default. Each is a setting
and defaults off. Lane groups do not add MAC/s. Approximate consumers
apply only when every promotion gate is present, and that report still
does not write `VaTurboEn`. A port setting promotes only when its
fabric carries more than 8 bytes/cycle. The live setting is 512 onto
64 and is not promoted, so the live MAC count stays 512. A 256-bit
fabric on that island DMA carries 32 bytes/cycle and may use the
configured MAC count in the sketch. On a promoted 256-bit fabric,
4 clusters of 2048 MAC/cycle at 2 GHz sketch to 32.768 INT8 TOPS,
65.536 INT4 TOPS, and 8.192 FP32 TFLOPS. The same features on the
live 64-bit fabric stay 2.048 INT8 TOPS. Descriptor, C, and completion
beats stay 8 bytes either way. That 4×2048 array on 32 bytes/cycle
is 256 MAC/byte, four times the live 64 MAC/byte, so the sketch is
still port-bound: it needs 128 bytes/cycle to keep the live intensity.
The 8×4096 sketch needs 512 bytes/cycle, a 4096-bit fabric, to hold
64 MAC/byte on the data port. Descriptor, C, and completion stay 8
bytes, so that same array is 4096 MAC/byte on the control path and is
not fed. Those beats are a setting that defaults to 8 bytes. The same
array is fed only when that setting is also 512 bytes/cycle. At the
sketch clock of 1.5 GHz the class-0 nameplate truncates to 1 GHz, so
both of those 512-byte paths publish 512 GB/s, not 768. That demand
is 512 GB/s. Class 0 covers it. Class 2 stays 400 and does not.
A claimed rate has to equal the class formula: 16 matches live class
0, and 400 does not. Class 2 may claim 400 only when that is not also
the class-0 nameplate. Covering 512 GB/s with DDR4-2400×64 takes 27
channels of 19 GB/s; 26 do not. The live class stays 0 and the live
channel count stays 1. Lane groups, reductions, converters,
and proof producers do not change the rate. The 100 TOPS gap remains
that live 8-byte port. A VA level does not scale it. The resident-B
experiment is not model inference or silicon MAC/s.
