# Scaling `Xg6lcai` to the 100-TOPS class — sizing model and consequent decisions

**Status:** plan of record (P0 docs) · **Parent:** [`README.md`](README.md) · **Contract:**
[`isa-encoding.md`](isa-encoding.md) · **Transport:** [`../uncore/pcie-endpoint.md`](../uncore/pcie-endpoint.md)
**Licensing:** tier T doc (MIT, no inline header). It describes silicon that is tier **P case 2** and
still blocked by **AI-0**.

> **Why this document exists.** `README.md` sizes a *seam*. It does not size a *machine*. A review of
> a 100-TOPS target showed that the interesting decisions at that scale are not seam decisions at all,
> and that three of them change what P1–P6 should build. Those decisions are recorded here and
> back-referenced from the scaffold.

## Table of contents
1. Verdict on the 100-TOPS proposal
2. Definition of the number (do this before any RTL)
3. The two-plane split — the load-bearing restructure
4. Sizing model: bandwidth first, then MACs
5. The batch-1 trap, and the staged SKU decision (**AI-S1, closed**)
6. On-die SRAM: 8–32 MB, not 32–128 MB
7. Clusters and the NoC cut line; chiplets deferred
8. Where the scaling knobs live (**not** in `cva6_cfg_t`)
9. Contract consequences (INT4, self-describing descriptors, QoS)
10. Power, thermal and the card envelope
11. Island track I0–I4 and how it interleaves with P0–P6
12. Acceptance metrics

---

## 1. Verdict on the 100-TOPS proposal

The reviewed draft is **directionally correct on three points, premature on three, and silent on the
three that actually decide the product.**

| Draft claim | Verdict |
|---|---|
| Memory system first, MAC count second | **Adopt.** Quantified in §4; it is the whole design. |
| T2 is the mandatory spine, scale queues/depth | **Adopt.** Already the `README.md` §2.1 conclusion; §3 here makes it structural. |
| LibreCore is control and locality, not the datapath | **Adopt.** Formalised as the two-plane split (§3). |
| "Seam: option D" for the 100-TOPS SKU | **Reject.** At 100 TOPS essentially no work crosses a core seam. Option D is a *small-SKU and latency* feature, not a scaling one (§3). This removes **AI-2** from the card's critical path. |
| 2×50 or 4×25 TOPS chiplets | **Defer behind a gate.** The island is well under reticle; chiplets buy yield above ~300 mm², at the cost of D2D PHY (NDA → tier P case 1), substrate and KGD test. Replicate clusters on one die and *place the cut line* instead (§7). |
| Add `AiPeArrays` / `AiMacsPerCycle` / `AiL2TileBytes` to the config | **Reject as written.** Those are uncore parameters; putting them in `cva6_cfg_t` taxes ~24 core packages with fields no core module reads. Separate island package + MMIO capability registers (§8). |
| On-die SRAM 32–128 MB | **Reject as a default.** That figure is a weight-resident (batch-1 decode) machine, a different product. A DRAM-fed tiled GEMM closes at 8–32 MB (§6). |
| — | **Missing: arithmetic intensity.** Peak TOPS is meaningless without the intensity at which it is claimed. §4/§5. |
| — | **Missing: INT4 does not fit the frozen `aicfg`.** `dtype[13:12]` is fully allocated; INT4 has no encoding. §9. |
| — | **Missing: the T2 descriptor is not self-describing.** It inherits dtype from a mutable CSR, which is a race for a µs–ms asynchronous engine. §9. |

## 2. Definition of the number

**Freeze this before any island RTL exists.** Every downstream figure depends on it.

> **`Xg6lcai` 100 TOPS ≙ 100 × 10¹² dense INT8 operations per second, peak, counting one
> multiply-accumulate as two operations, with no sparsity and no INT4 multiplier applied.**

Consequences of that definition:

- **Peak MAC rate = 50 × 10¹² MAC/s.** Required MACs per cycle:

  | Clock | MAC/cycle for 100 TOPS |
  |---|---|
  | 1.0 GHz | 50 000 |
  | 1.25 GHz | 40 000 |
  | 1.5 GHz | 33 334 |
  | 2.0 GHz | 25 000 |

- **Sparsity and INT4 are reported separately**, never folded into the headline. A 2:4-structured
  sparse INT4 part would be "100 TOPS dense INT8 / 400 TOPS effective INT4 2:4" — two numbers, both
  honest. Collapsing them is the "peak theater" the draft correctly warns about.
- **Sustained is a measured quantity, not a claim.** See §12.

## 3. The two-plane split (load-bearing)

`README.md` §1 presents T0/T1/T2 as three tiers of *one* unit. At 1–5 TOPS that is true. At 100 TOPS
it is false and misleading: T0/T1 and T2 become **different silicon, on different sides of the core
boundary, with different clocks, verification and sizing knobs.**

| | **Core-attached plane** (T0 + T1) | **Island plane** (T2) |
|---|---|---|
| Location | `core/` at the CVXIF (B) or accelerator (D) seam | `corev_apu/` — a device on the fabric |
| Size | **fixed and small**: one 8×8×8 INT8 tile unit, ~0.1–0.3 TOPS | scaled: N clusters, ~100 TOPS |
| Sized by | `ai_cfg_t` in `cva6_cfg_t` | island package + MMIO caps (§8) |
| Reached by | custom-2 instructions, precise traps | descriptor rings, doorbell, completion IRQ |
| Scales with | nothing — it is a latency device | clusters × MAC/cluster × f |
| Verified by | directed tests + RVFI + compliance | ring/DMA formal, GEMM golden, QoS soak |

**The core-attached tile geometry (`AiTileM/N/K = 8`) must not grow with the TOPS target.** Its job is
sampling, MoE routing, small/dynamic shapes and requant fusion — work whose *latency* matters and
whose *throughput* does not. Growing it lengthens `ex_stage`-adjacent cones and buys nothing.

**Therefore the seam decision is decoupled from the TOPS target.** The card SKU can ship on **seam B**
because ~99.7% of its arithmetic never crosses a core seam. Option D stays on the roadmap for the
small/embedded SKU (native `ai.ldt` without a DMA engine) and for T1 latency, but it is **no longer a
prerequisite for 100 TOPS** — which takes **AI-2** (`g6lc64_server_math_v` superscalar/RVV assert
violation) off the card's critical path.

## 4. Sizing model: bandwidth first, then MACs

For a tiled GEMM holding a **T × T** output block on chip while streaming the reduction dimension,
per output block: `2·T·K` input bytes for `T²·K` MACs, so

> **DRAM bytes per MAC = 2 / T** — and **required bandwidth = (2 / T) × MAC-rate.**

At the 50 × 10¹² MAC/s of §2:

| On-chip blocking `T` | Bytes/MAC | Required DRAM BW | Accumulator SRAM (`T²·4 B`) |
|---|---|---|---|
| 128 | 0.0156 | **781 GB/s** | 64 KB |
| 256 | 0.0078 | **391 GB/s** | 256 KB |
| 512 | 0.0039 | **195 GB/s** | 1 MB |
| 1024 | 0.0020 | **98 GB/s** | 4 MB |

This is the derivation behind the draft's "≥200–400 GB/s": it is the `T = 256…512` row, and it is a
*consequence* of the blocking factor, not an independent choice. **Pick `T` and the DRAM class
together; anything else produces a machine that cannot reach its own peak.**

### 4.1 `T` is a property of the accumulator SRAM, not of the PE array

The most likely implementation error here is equating `T` with a physical array dimension. It is not.
The PE array supplies a **MAC rate**; the accumulator SRAM supplies a **blocking factor**. An array of
32 768 MACs time-multiplexes over a `512 × 512` output block held in 1 MB of accumulator SRAM, and the
bandwidth in the table above follows from the **512**, not from the array shape.

Two consequences, and they are what make a staged programme viable:

- **`T` and the DRAM class are fixed once, at I1, and held constant across SKUs.** Only cluster count
  varies. A SKU change never re-opens the memory system or the accumulator design.
- **Bandwidth demand scales linearly with MAC rate at constant `T`.** Doubling clusters doubles required
  bandwidth; it does not change the blocking strategy, the staging buffers or the software's tiling.

Corollary: clusters must **cooperate** on a shared output block, broadcasting operands over the NoC. If
each cluster instead blocks independently at its own `64 × 64`, the effective `T` collapses to 64 and
the requirement jumps to ~1.6 TB/s — an unbuildable machine from a locally reasonable-looking choice.

**Machine balance** — the single number to design against:

> balance = MAC-rate / DRAM-BW = 50 × 10¹² / 400 × 10⁹ ≈ **125 MAC per byte**.

Every kernel with arithmetic intensity below 125 MAC/byte is bandwidth-bound on this part, full stop.

Reference memory options for the 391 GB/s row: 2 × LPDDR5X-8533 ×128 (≈273 GB/s, short), 3 × (≈410 GB/s,
adequate), or 1 HBM2E stack (≈460 GB/s) — noting that HBM implies an interposer, i.e. it re-imports the
advanced-packaging cost that §7 defers.

## 5. The batch-1 trap

Take a decoder-only LLM with `W` bytes of INT8 weights. Generating one token touches every weight once:
`W` MACs against `W` bytes — **arithmetic intensity ≈ 1 MAC/byte**, versus a machine balance of 125.

At 400 GB/s and `W` = 8 GB: 20 ms/token → **50 tok/s, consuming 0.4 × 10¹² MAC/s = 0.8 TOPS.**

> **Batch-1 LLM decode needs ~1 TOPS, not 100. Saturating a 100 TOPS / 400 GB/s part requires a batch
> of ≈125.**

This is the most important finding in this document, and it cuts against the product story:

- The card's actual differentiators — one address space, no host round-trip, Linux and irregular
  fallback next to the matrix unit — matter **most** in exactly the low-intensity regime where the TOPS
  number is irrelevant.
- 100 TOPS pays off in **prefill, batched serving, convnets and re-ranking** — the regime where a GPU
  is already strong and sells on raw peak.

| SKU | Optimise | Consequence |
|---|---|---|
| **Latency / decode** | DRAM bandwidth and SRAM residency; ~5–20 TOPS is ample | cheap die, plays to the card's real strength |
| **Throughput / serving** | 100 TOPS dense INT8, batch ≥ 128 | AI-dominated die, must fund 400 GB/s, competes head-on with discrete accelerators |

Committing to 100 TOPS *without* funding ≥400 GB/s produces a part that is slower than a 20-TOPS part
on every real workload while costing more area and power than both.

### 5.1 Decision: both, staged — latency SKU first (AI-S1, closed)

**Build the latency/decode SKU first; reach the throughput SKU by replicating clusters behind the same
NoC cut line.** The two SKUs share one cluster design, one memory system, one capability window and one
software stack; they differ only in cluster count and package.

This is not merely a tolerable compromise — **it is the cheaper order**, for a reason that falls out of
§4.1:

| | Latency SKU | Throughput SKU |
|---|---|---|
| Clusters × 64² PEs | 1–2 | 8 |
| MAC/cycle | 4 096–8 192 | 32 768 |
| Peak @ 1.5 GHz | **12–25 TOPS** | **98 TOPS** |
| GEMM bandwidth demand at `T = 512` | 24–48 GB/s | **195 GB/s** |
| Bandwidth actually provisioned | **~400 GB/s** — set by §5 weight streaming, not by GEMM | ~400 GB/s, unchanged |

> **The memory system the latency SKU must buy anyway (~400 GB/s, driven by batch-1 weight streaming)
> already covers the 100-TOPS SKU's 195 GB/s GEMM demand at `T = 512`.** The expensive, long-lead,
> hardest-to-change subsystem is therefore built and measured first, against the workload that stresses
> it hardest; adding compute afterwards is cluster replication, which is the cheap and repeatable part.

This also inverts the usual risk: the standard failure mode (§11) is growing the MAC array ahead of the
memory system. Staging in this order makes that mistake structurally impossible.

**Binding conditions on the staged plan** — without these it degenerates into two separate designs:

1. `T`, the accumulator geometry and the DRAM class are frozen at **I1** and are SKU-invariant (§4.1).
2. The cluster is the **only** unit of replication, and the NoC cut line is defined at I1, not I2 (§7).
3. The capability window ships in **I1**, populated even for a one-cluster part, so no software ever
   observes a SKU difference except as numbers it already reads (§8).
4. Cluster-cooperative blocking is designed in from the first cluster; independent per-cluster blocking
   is a bandwidth trap (§4.1) that cannot be retrofitted.
5. Both SKUs are quoted with §12 metrics. The latency SKU reports `tok/s @ batch=1`; it must **not** be
   marketed on a TOPS number it does not target.

## 6. On-die SRAM: 8–32 MB, not 32–128 MB

Working set for the DRAM-fed design of §4 at `T = 512`, `K`-step 256, double-buffered:

| Structure | Bytes |
|---|---|
| Accumulators (s32, `T²`) | 1 MB |
| A tile, double-buffered (`T·K`, 2×) | 256 KB |
| B tile, double-buffered (`K·T`, 2×) | 256 KB |
| Requant scale/zero-point tables | ≪ 1 MB |
| **Per-island working set** | **≈ 2 MB** |

Even with per-cluster replication and generous staging, **8–32 MB (1–4 MB per cluster across 8
clusters) closes the design with margin.**

The draft's 32–128 MB is not a bigger version of this machine — it is the *weight-resident* machine
from §5's latency SKU, where SRAM replaces DRAM bandwidth. That is a legitimate product, and possibly
the better one, but it must be chosen deliberately: 128 MB of SRAM is a die-area and cost decision of
the same magnitude as the entire MAC array.

## 7. Clusters and the NoC cut line; chiplets deferred

**Reference organisation** (one credible 100-TOPS point, to be replaced by synthesis data):

- 8 clusters × 64 × 64 INT8 PEs = 32 768 MAC/cycle; at 1.5 GHz → **98.3 TOPS**.
- Each cluster: private A/B staging SRAM, private accumulator bank, local sequencer, one NoC port.
- Clusters are **identical and independently clock-gated / power-gated**; a defective or unpowered
  cluster degrades throughput linearly and is discoverable through the MMIO capability register (§8).
- 64 × 64 keeps each cluster's timing problem local and its floorplan a tile — the reason to prefer
  8 × 64² over 2 × 128², despite identical MAC counts.

**Chiplets: deferred behind an explicit gate, not rejected.** The reasoning the draft skips:

| Chiplets buy | Chiplets cost |
|---|---|
| Yield on large die | D2D PHY (UCIe/BoW) IP — typically NDA, i.e. **tier P case 1**, and a new CDC/AC-coupling problem |
| Mixing process nodes | Package substrate or interposer, KGD test flow, thermal/mechanical redesign |
| SKU scaling by die count | A second, harder timing and power-integrity closure across the D2D link |

A ~100-TOPS island in a 7 nm-class process is plausibly 50–150 mm² — comfortably monolithic. **Gate:
revisit chiplets when (a) the estimated island die exceeds ~300 mm², or (b) a second SKU wants ≥2× the
compute of the first.** Until then the modularity is real but on-die: **the NoC boundary around a
cluster group is frozen at I1 as the future die-cut line**, so a later split is a packaging change
rather than a re-architecture.

Under the staged plan (§5.1) that boundary does triple duty: it is the SKU scaling unit, the power-gate
domain, and the eventual die cut. Getting it wrong at I1 is the one decision that is expensive to
reverse later.

## 8. Where the scaling knobs live

**Decision: island sizing does not enter `cva6_cfg_t`.**

`config_pkg::ai_cfg_t` is a *core* structure, replicated by named literal in ~24 config packages and
consumed by core modules. Adding `PeArrays` / `MacsPerCycle` / `L2TileBytes` there would tax every
package with fields no core module reads, for a block that lives in `corev_apu/`. Instead:

| Parameter class | Home | Rationale |
|---|---|---|
| Seam, tile geometry, accumulator banks, ring count/depth, op-group gates | `config_pkg::ai_cfg_t` (**unchanged**) | the core genuinely decodes and traps on these |
| Clusters, MACs/cluster, per-cluster SRAM, NoC width, DRAM channels, QoS classes | **new** `corev_apu/include/g6lc_ai_island_cfg_pkg.sv` (tier **R** — interface stays open) | uncore parameters, one SoC package, zero core churn |
| Runtime discovery of the above | **MMIO capability window** in the island (BAR0 / fabric-mapped), plus the `g6lc,ai-matrix` DTS node | software must never recompile per SKU |

The capability window is what lets the PyTorch partitioner cost a kernel on an unknown part:

| Offset | Field |
|---|---|
| `0x00` | capability version, must match `aicfg.version` |
| `0x04` | cluster count present / cluster count enabled |
| `0x08` | MACs per cycle per cluster |
| `0x0C` | island clock, kHz |
| `0x10` | SRAM bytes per cluster |
| `0x14` | peak DRAM bandwidth, MB/s (measured at bring-up, not nameplate) |
| `0x18` | supported dtype/element-width mask (§9) |
| `0x1C` | queue count, QoS class count |

**This keeps the frozen ISA contract invariant.** `ai.setcfg` continues to describe only the
*core-attached* plane; island geometry is never expressed in a CSR. That is the property that lets one
binary run on the 5-TOPS and 100-TOPS SKUs.

## 9. Contract consequences

Three defects in [`isa-encoding.md`](isa-encoding.md) surface only at this scale. All three are fixed
in place: the document is **unratified and no implementation exists**, so these are pre-implementation
corrections, not version bumps.

1. **INT4 has no encoding.** `aicfg.dtype[13:12]` is fully allocated to the four signedness
   combinations. INT4 — the draft's main "effective TOPS" lever — could not be requested at all.
   *Fix:* allocate `aicfg[21:20]` as `ew` (element width) out of previously reserved space; `00` = 8-bit
   is the value a version-1 part reads back, so old software and new hardware interoperate by
   construction. Structured 2:4 sparsity gets `aicfg[22]` on the same basis.
2. **The T2 descriptor is not self-describing.** It carries `m/n/k` and pointers but takes dtype and
   accumulate mode from `aicfg` — a CSR that the submitting thread may rewrite while a millisecond-long
   descriptor is in flight, and that has no defined value at all for a host-side PCIe doorbell
   submission. *Fix:* dtype, accmode, element width and sparsity move into reserved bits of the
   descriptor `flags` word, and the engine is forbidden from reading `aicfg`.
3. **No QoS or preemption contract.** At 100 TOPS one descriptor can own the island for milliseconds.
   With multiple tenants holding doorbell pages, that is an unbounded latency channel and a
   denial-of-service vector. *Fix:* a priority class in `flags`, a normative bounded work quantum,
   restartability at a reduction-block boundary, and a per-descriptor watchdog.

## 10. Power, thermal and the card envelope

Order-of-magnitude only — **every figure below must be replaced by synthesis and memory-vendor data at
I3/I4; none of it is measured.**

| Contributor | Estimate at 100 TOPS |
|---|---|
| MAC arrays (≈0.2 pJ/MAC, 7 nm class) | ~10 W |
| On-die SRAM + NoC + sequencing (2–3× compute) | ~20–30 W |
| DRAM at 400 GB/s (≈6 pJ/bit, LPDDR5X class) | ~19 W |
| LibreCore harts, uncore, PCIe | ~10–20 W |
| **Card total** | **~60–80 W typical, 100–150 W peak** |

Consequences for [`../uncore/pcie-endpoint.md`](../uncore/pcie-endpoint.md):

- **The 75 W slot budget is not sufficient.** Plan a 150 W-class card: ×16 slot plus one 8-pin aux, and
  a boot-time power-budget negotiation that keeps the card inside 75 W until aux power is confirmed.
- A **power-capping loop is mandatory, not an optimisation**: island DVFS or cluster clock-throttling
  driven by a thermal sensor, with an MSI on threshold crossing and a documented sustained-vs-burst
  clock. A 100-TOPS part with no cap either exceeds its envelope or silently misses its number.
- Per-cluster power gating is required to make the low-load case (§5's decode regime) cheap.

## 11. Island track I0–I4

The core track **P0–P6 in `README.md` §8 is unchanged.** Island work runs as a parallel track so the
existing numbering and its gates stay stable.

Sequenced for the staged decision of §5.1: the memory system is built and measured **before** the array
is widened, so I3 moves ahead of the multi-cluster step.

| # | Deliverable | Gate | Depends on |
|---|---|---|---|
| **I0** | This document: TOPS definition, bandwidth model, plane split, staged SKU decision | docs only | — (done) |
| **I1** | **One** island cluster: PE array, banked staging + accumulator SRAM via `tc_sram`, local sequencer, capability window. **Freezes `T`, accumulator geometry, DRAM class and the NoC cut line for both SKUs.** | GEMM bit-exact vs the §3.5 rounding rule; synth smoke + FO4; area/power recorded; capability window correct on a one-cluster part | P3 (T2 spine), **AI-0** |
| **I3** | Memory system: DRAM controller class, prefetch/staging, measured bandwidth into the capability register | measured sustained ≥ 80% of nameplate; `tok/s @ batch=1` on a real quantised model | I1 |
| **—** | **Latency SKU tapes out here** (1–2 clusters, ~12–25 TOPS) | §12 metrics, latency column | I3, I4 |
| **I2** | NoC + N clusters + per-cluster clock/power gating + QoS arbitration | ≥60% of peak on `M=N=K=4096`; QoS soak with two tenants; **no change to `T`, the memory system or the software stack** | I3 |
| **I4** | Physical: floorplan islands, UPF power domains, thermal sensor + capping loop, STA | full-chip STA closes; power cap demonstrated | I1 (latency SKU), re-run after I2 |

**Ordering rule, from §4 and §5.1:** the bandwidth target is fixed and *measured* before the cluster
count grows. Growing the MAC array ahead of the memory system produces a part that cannot reach its own
peak — the single most common failure mode for this class of design, and the one the staged order makes
structurally impossible.

**Regression gate on staging:** every I2 change must leave the I1/I3 latency-SKU results bit-identical
and its measured bandwidth unchanged. If widening the array perturbs either, the cluster boundary
leaked and the two SKUs have started to diverge.

## 12. Acceptance metrics

Replace "100 TOPS" with these in every gate and every datasheet:

| Metric | Definition | Floor |
|---|---|---|
| `TOPS_peak` | §2 definition | as specified |
| `TOPS_sustained@AI` | measured, at a **stated** arithmetic intensity, over ≥1 s | ≥60% of peak at AI ≥ 128 |
| `SKU` | latency (1–2 clusters) or throughput (8 clusters) — §5.1 | stated on every figure |
| `BW_measured` | achieved DRAM bandwidth on a streaming GEMM | ≥80% of nameplate |
| `tok/s @ batch=1` | the §5 regime, reported **separately** and never converted to TOPS | reported, not floored |
| `TOPS/W` | `TOPS_sustained` over card power at the cap | reported per SKU |
| `p99 descriptor latency` under 2 tenants | QoS proof from I2 | bounded by the work quantum |

A number that is not one of these does not appear in a review.

## Open first

| Layer | Path |
|---|---|
| Seam and tiers | [`README.md`](README.md) |
| Frozen contract | [`isa-encoding.md`](isa-encoding.md) |
| Transport / card | [`../uncore/pcie-endpoint.md`](../uncore/pcie-endpoint.md) |
| SoC readiness gates | `agents/guides/AGENTS-soc-readiness.md` |
| Licensing (island is tier P case 2) | `AGENTS-licensing.md` · `.licensing-tiers` |
