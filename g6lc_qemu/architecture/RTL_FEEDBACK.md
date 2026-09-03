# RTL_FEEDBACK — findings that flow back into the design

Index: [`README.md`](README.md). Invariants: [`../AGENTS.md`](../AGENTS.md).
Contracts are named by **pin id** from [`../pins.toml`](../pins.toml), never by external path.

---

## 1. Why this ledger exists

This package reads the design and refuses to guess. Every refusal is information: if the emulator
cannot answer a question from the design's own files, then **no consumer of those files can** — not a
driver author, not a firmware engineer, not a second emulator. The refusal is a finding about the
design's published surface, not a limitation to be worked around locally.

Without somewhere to put them, those findings get "fixed" the wrong way — a literal in an emitter, a
default that looks derived — and the divergence surfaces months later as a phantom RTL bug.

So the rule is:

> A constant the design does not publish is recorded here as an **ask on the design**, and left
> visibly unresolved in the code. It is never quietly defaulted.

Each ask states what unblocks when it lands, so the design side can judge priority against the
emulator work it gates rather than against an abstract tidiness argument.

## 2. Open asks on the design

| # | Finding | Design-side ask | Pin | Blocks |
|---|---|---|---|---|
| **F1** | The island's MMIO **placement** is decided in the address decode (RTL), while the capability *offsets* are published in a package. The emulator ingests offsets and cannot resolve bases. | Publish the island register-map placement as localparams beside the existing capability offsets: capability window base, descriptor latch base, and the control/status/doorbell/completion/queue-region/counter offsets. | `contracts.ai_island_cap` | A guest cannot address the island. The pushed path (`AI_BRIDGE.md` §2) is end-to-end exercisable only against a model that states the bases. |
| **F2** | The accepted **descriptor version** is validated in RTL but never published as a named constant, so nothing can be compared against. | Publish the accepted descriptor version in the descriptor package. | `contracts.ai_island_mmio` | `FALLBACK_DESC_VERSION` in the device model, and any honest "bad version" reporting. |
| **F15** | `ai.poll` needs three distinguishable answers — *not finished*, *finished with status S*, and *rejected* — but the package publishes only completion **statuses**, which by definition exist only once an entry is done. There is no published encoding for "still pending", and none for "the ring was full so nothing was queued". The emulator therefore names its own `POLL_PENDING` (`0xffff_ffff`) once, shared by the generated in-target device and the native VM, and returns `0` on a full ring so the two are distinguishable. Both are emulator conventions that a real driver would not know. | Publish the `ai.poll` return contract: the value (or status code) meaning *not yet complete*, and what `ai.enq` returns when the ring cannot accept the descriptor. | `contracts.ai_isa` | Any in-guest driver that must busy-wait correctly, and any claim that a B1/B3 poll result matches hardware. Today a guest that treats a full-ring return as a valid ticket would poll a ticket that was never allocated. |
| **F3** | Two capability words are **packed encodings** (tile dimensions; data-type grant bits) whose bit layout lives only in RTL comments. The `DtypeMask` value is a cap-window parameter, not a config-package field, and `block_mnk` is a concatenation of `$clog2` calls inside the case arm. | Publish the shift/width of each packed subfield as localparams, and move `DtypeMask` into `ai_island_cfg_t` or a named package constant. | `contracts.ai_island_cap` | `dtype_mask`, `block_mnk`, `dram_gbps` and `queues` are now sourced by reading the cap-window module, which is fragile because the packings are `always_comb` expressions and `DtypeMask` may be overridden at instantiation. The guest-visible window is complete, but a design-side localparam is needed for each packed word. |
| **F4** | The descriptor is latched through a **word-indexed window**, so a host image and the device agree only if both use the same base *and* the same word ordering. `g6q-diag` now validates the ordering: it parses `bits_to_desc`, `desc_to_bits`, and the `desc_t` struct byte-offset comments and reports a conflict if they disagree. The emulator currently assumes the `+0xNN` comments are byte offsets and `bits_to_desc[high:low]/8` gives the field offset. | Confirm that descriptor field offsets are byte offsets into the latch window, or publish the word map. | `contracts.ai_island_mmio` | Byte-for-byte agreement between the native device, the generated device model, and a host-packed image. |
| **F5** | The **data-type selector is a packed subfield of the descriptor flag word**, and its position is published nowhere — it exists only as a shift and mask agreed by convention. | Publish the shift and width of the data-type selector (and any other flag subfields) as localparams. | `contracts.ai_island_mmio` | `g6q-diag` now parses the comment and the `desc_prio`/`desc_irq` helpers in `g6lc_ai_desc_pkg.sv` into `AiDescLayout.flags_layout`; `g6q-emit-qemu` emits `G6LC_AI_DTYPE_SHIFT`/`MASK` from the ingested layout and requires it for descriptor decode; `TensorArtifact`/`TensorTrace` carry `flags_layout` so D2 decoding uses the ingested layout and the `g6q_core` fallback constants have been removed. |
| **F7** | The **capability-window layout published in the plan of record disagrees with the shipped RTL** from offset `0x14` onward. `scaling-100tops.md` §8 documents `0x14` = DRAM bandwidth, `0x18` = dtype/element-width mask, `0x1C` = {queue count, QoS count}; the shipped `g6lc_ai_cap_window.sv` decodes `0x14` = packed `block_mnk`, `0x18` = {nameplate, measured} DRAM, `0x1C` = {queue_depth, queues}, `0x20` = QoS, `0x24` = quantum, `0x28` = dtype mask. A host partitioner written against §8 would read the tile geometry as a bandwidth number and the bandwidth as a dtype mask. The emulator ingests the RTL `CAP_OFF_*` names, so it is aligned with silicon and can act as referee. | Correct §8 of `scaling-100tops.md` to the shipped word map (or move the RTL to the documented one) and state which is normative. | `contracts.ai_island_cap` | Any host that discovers geometry from the document rather than from the ingested model. The bug is silent: every word reads back plausibly. |
| **F8** | The capability word at `0x04` is documented as **"cluster count present / cluster count enabled"** (two fields), but the RTL emits a single `32'(IslandCfg.Clusters)`. `scaling-100tops.md` §7 and §10 both require per-cluster clock/power gating to be *discoverable* so a defective or unpowered cluster degrades throughput visibly. With one field, software cannot tell a 8-cluster part with 2 gated off from a 6-cluster part. | Split `0x04` into present/enabled halves, or publish an enabled-cluster bitmap word. | `contracts.ai_island_cap` | Honest per-cluster attribution in the tensor artifact, and dispatch that targets only *enabled* clusters (F6 becomes ambiguous without it). Also gates the §12 `TOPS/W` metric, which is per-SKU and therefore per-enabled-cluster. |
| **F9** | The island publishes **measured** PMU counters — R beats, W beats, active cycles and sustained GB/s×1000 — but only as comments in the `g6lc_ai_island_top.sv` register map (`0x180`–`0x18C`). They are not localparams, so the emulator cannot ingest their offsets and cannot line its own modelled bound up against the design's measurements. `AiIslandConfig::pmu_offsets` and the `PMU_OFF_*` reader now exist, and `g6q-vm/src/device.rs` maps them: on `queue_qfence` the device computes modelled beat counts, a bound cycle count from `g6q-diag::roofline`, and a modelled milli-GB/s figure (`bytes * ClockKhz / cycles / 1000`); these are returned by `MmioDevice::load` when the address matches a published offset. The **emulator side of the comparison is ready**; `AiIslandConfig::pmu_offsets` stays empty against the live package. | Publish the PMU register offsets as localparams beside `CAP_OFF_*`, and state the units of each (beats, cycles, milli-GB/s). | `contracts.ai_island_cap` | The whole performance-feedback loop: the §12 acceptance metrics (`BW_measured` ≥ 80% of nameplate, `TOPS_sustained@AI`) are RTL-measured, while the roofline bound is modelled. Without ingested offsets the two can only be compared by hand, as §3.1 does. |
| **F12** | The GEMM unit **bounds every dimension by the accumulator tile** — `m, n, k ∈ [1, MaxDim]`, checked in `g6lc_ai_gemm_seq.sv` `ST_CHK` and rejected with an error status — but nothing states that limit as a descriptor-level contract. It is discoverable only indirectly, by reading `CAP_OFF_BLOCK_MNK` and knowing that the packed `log2` tile dimensions double as the maximum shape. Consequently the plan's own acceptance gate, `M = N = K = 4096` (§12), **cannot be submitted as one descriptor**: it exceeds the live limit 16× per dimension and needs host-side blocking into 16³ pieces. `g6q-diag::roofline` now reports `shape_fits_blocking` so a bound never silently describes work the contract would refuse. | State in `isa-encoding.md` §7 that each dimension is bounded by the corresponding capability tile, and say whether hardware or software owns blocking beyond it. If hardware is meant to stream, `ST_CHK` is the wrong check. | `contracts.ai_island_mmio` | Every §12 metric measured on a shape larger than the tile, and the PyTorch partitioner's tiling decision — which currently has no published limit to tile against. |
| **F13** | The plan's bandwidth derivation (§4, `bytes/MAC = 2/T`) **counts input bytes only**, and at the shapes this engine accepts the omission inverts the conclusion. With `s32` accumulators the C writeback is `4·m·n`, which at `m = n = k = T` is **twice** the input traffic — so total traffic is 3× the §4 figure and true arithmetic intensity is a third of it (42 rather than 128 MAC/byte at `T = 256`). §4's model is sound for a large-`K` streaming reduction, where the writeback amortises as `4/K`; it is optimistic for a whole-matrix-resident engine, which is what `g6lc_ai_gemm_seq.sv` implements (load all A, load all B, MAC, store C). | Extend §4 with the writeback term and state the `K` at which it becomes negligible, or state that §4 describes only the streaming regime. | `contracts.ai_island_cap` | Any bandwidth sizing done from §4 at small `K`. The 391 GB/s figure for `T = 256` is an input-only number; with the writeback the same row asks for materially more. |
| **F11** | The island's **DRAM class is unpublished** (`DramGBps = 0`, "not measured (I3)"), so no roofline can be computed for the live part: `g6q-diag::roofline` returns the MAC bound but reports the bandwidth bound and machine balance as unresolved. The emulator now ingests `measured_dram_gbps_x1000` and the cap window publishes the measured half at `0x18`, so the **emulator side of the loop is closed**; the RTL still needs to drive that value from a real measurement. | Populate `DramGBps` with the measured sustained figure once I3 lands, or drive `dram_gbps_meas_x1000_i` from the measured PMU so the cap window returns a non-zero measured half. | `contracts.ai_island_cap` | Every bandwidth-side number: `balance_mac_per_byte`, `dram_bound_cycles`, `bound_cycles`, and any statement about whether a shape is compute- or bandwidth-bound. Until then the emulator can only bound the arithmetic, which is the half that is *not* in question. |
| **F10** | The descriptor `flags` word carries **four distinct arithmetic-type subfields** — `dtype[9:8]`, `accmode[11:10]`, `ew[13:12]`, `sp24[14]` per `isa-encoding.md` §7 — but `g6lc_ai_desc_pkg.sv` publishes accessors only for `desc_prio` and `desc_irq`. The single comment `flags[13:8] type fields (dtype/accmode/ew/sp24)` both **understates the span** (`sp24` at bit 14 is outside it) and **conflates three fields into one**. Reading it as a data type yields a plausible-looking wrong value: an INT4 request (`ew=01`) reads back as `dtype = 16`. `g6q-diag` now prefers per-field accessors and, when only the comment exists, marks the span `dtype_combined` so no backend reports the blob as a type. | Publish `desc_dtype`, `desc_accmode`, `desc_ew` and `desc_sp24` accessors (or localparam shift/width pairs) in the descriptor package, matching §7. | `contracts.ai_island_mmio` | **The 100-TOPS effective-throughput story.** `scaling-100tops.md` §2 reports dense INT8 and effective INT4 2:4 as two separate numbers, and §9 defect 1 exists precisely so INT4 is requestable at all. While `ew` and `sp24` are unresolved the emulator cannot express a sub-byte or sparse request, the PyTorch bridge cannot ask for one, and no D2 counter may apply a sub-byte or sparsity multiplier. Note the engine also does not yet *consume* these fields (`DtypeMask = 0x0001`, s8 dense only), so publishing them is the first step, not the last. |
| **F6** | The **cluster that executes a descriptor** is not exposed to software. `Clusters` is published as a SKU capability, but no field or queue mapping says which cluster a submission targets, so a tensor event cannot label its cluster. `g6q-core` `AiIslandConfig` now carries `queue_cluster_map`; `g6q-diag/ai_cfg.rs` parses it from a `QueueClusterMap` struct field or top-level localparam; `g6q-vm` `read_descriptor_event` first uses a `cluster` descriptor field, then the `queue_cluster_map`, and only leaves `cluster` unresolved (0) when neither source is published. | Publish either a `cluster` field in the descriptor, a queue-to-cluster map, or a CSR that returns the dispatch target. | `contracts.ai_island_mmio` | Per-cluster tensor event attribution, queue-to-cluster validation, and PyTorch-side comparison of cluster-parallel results. |

|| **F14** | The cap window's **measured DRAM half is only 16 bits** (`meas_milli[31:16]`) and is saturated to `0xFFFF`. If the units are genuinely 1/1000 GB/s, the largest representable value is 65.535 GB/s — far below the 400 GB/s target and the live nameplate `DramGBps = 0`. The live `g6lc_ai_cap_window.sv` saturates `dram_gbps_meas_x1000_i > 32'h0000_FFFF` to `16'hFFFF`, so a 400 GB/s measurement would read back as 65.535 GB/s (or as a saturated flag, depending on interpretation). | Clarify the units and range of `meas_milli` and either widen the field, change the unit, or document that `0xFFFF` means "at or above the 16-bit maximum" so software does not treat it as a precise 65.535 GB/s. | `contracts.ai_island_cap` | The measured-vs-nameplate comparison in the roofline and the host-visible `CAP_OFF_DRAM_GBPS` word. A saturated 16-bit field cannot distinguish a 70 GB/s measurement from a 400 GB/s one. |

**Status discipline:** an ask stays here until the design publishes the constant *or* the ask is
withdrawn with a reason. Removing a row because the emulator worked around it locally is the failure
this file prevents.

### 2.1 Emulator vs design (F1–F15, 2026-09)

None of F1–F15 is **closed on the design**. Several are **handled on the emulator**: ingest,
validate, or refuse, without guessing. Live `out/ai_soc_model.json` is one target, not a pin.

| Ask | Emulator | Design (2026-09 I3–F1 pass) | Typical live model |
|---|---|---|---|
| **F1** placement | Ingests `CAP_BASE`/`DESC_BASE`/`AI_*` **and the control surface** `REG_OFF_{CTL,STATUS,DOORBELL,CPL,QUEUE}` → `AiIslandConfig::reg_offsets`; `control_surface_resolved()` separates *addressable* from *operable* | **Published** `AI_CAP_BASE=0x4000_0000`, `AI_DESC_BASE=0x4000_0140`, `CAP_BASE=0`, `DESC_BASE=0x140`, plus `REG_OFF_*` | guest-addressable **and operable** on B3 |
| **F2** desc version | Prefers `DESC_VERSION` | **Published** `DESC_VERSION` (= `ContractVersion`) | 1 |
| **F3** packed cap words | Parses cap-window `dtype_mask`/`block_mnk`/`dram_gbps`/`queues` | **Published** `CAP_BLOCK_*_SHIFT`, `AiIslandDtypeMask` | ingest RTL |
| **F4** word order | `g6q-diag` cross-checks `bits_to_desc` / comments | Byte offsets in `desc_t` comments | packer uses those offsets |
| **F5** flags dtype/irq | `flags_layout` ingested | **Published** `FLAG_*_SHIFT/WIDTH` + accessors | `irq_bit=2`, `dtype_shift=8` |
| **F6** cluster | `QueueClusterMap` | **Published** `QueueClusterMap '{0,0}` (both queues, cluster 0) | map `[0,0]` |
| **F7** §8 vs RTL | Ingests RTL `CAP_OFF_*` | **Closed in the doc** — §8 is the shipped map | no silent wrong discovery |
| **F8** clusters enabled | Split word + bitmap | **Published** `0x04` present/enabled + `CAP_OFF_CLUSTER_EN` | present=1, enabled=1, bitmap=1 |
| **F9** PMU offsets | Reader + B3 modelled PMU ready | **Published** `PMU_OFF_{R_BEATS,W_BEATS,CYCLES,GBPS_X1000}` | `0x180–0x18C` |
| **F10** `ew`/`sp24` | Accessors when published | **Published** `desc_dtype`/`accmode`/`ew`/`sp24` | engine still s8-dense only |
| **F11** measured DRAM | Roofline refuses BW bound if unpublished | **I3-lite:** 8 GB/s NoC; Cas=0 default; opt-in `G6LC_AI_DRAM_TIMING` Cas=14 still class 0. Class-1 19 GB/s / LiteDRAM unsynced | I1-lite can close a roofline against 8 GB/s |
| **F12** MaxDim | `shape_fits_blocking` | **Published** in `isa-encoding.md` §7; SW owns tiling; `ai_gemm_tile_2x2_smoke`; C packed `ldc=n` | 256³ fits; 4096³ does not |
| **F13** writeback | Roofline uses `max(compulsory,tiled)+4mn` | **Published** in `scaling-100tops.md` §4 | intensity 42 vs 128 at T=256 |
| **F14** 16-bit meas | Saturate like RTL `0xFFFF` | **Published:** packed half saturates; `CAP_OFF_DRAM_MEAS_X1000` is 32-bit | 400 GB/s readable at `0x2C` |
| **F15** poll pending | Emulator `0xffff_ffff` / ring-full `0` | **Published live RTL:** `POLL_PENDING=0`, `POLL_OK=1`, `POLL_ERR=2`, `ENQ_FULL=all-ones` (`g6lc_ai_instr_pkg`). Emulator pending value is not hardware. | B1 poll matches T0 |

SoC snapshot (SMT2, QEMU firmware, OoO, H, RVV, stream): [`../../architecture/current-stage.md`](../../architecture/current-stage.md).

### 2.2 Reader defects found by pointing the ingest at the live packages (2026-09)

The rows above said "published". They were — but the *reader* could not read them, so every
one of those closures was theoretical. Pointing `parse_ai_island_cfg_pkg` /
`parse_ai_desc_pkg` / `parse_cap_window_*` at the live tree found four defects with a
single shape: **the design names its constants, and the reader only understood numerals.**

| Defect | Symptom | Fix |
|---|---|---|
| SKU literals refer to named constants (`AI_DRAM_CHAN_SHIFT_DEFAULT`, `AI_MAX_AR_OUT_LIVE`, `AI_DRAM_SIM_AXI`) | `parse_ai_island_cfg_pkg` returned `Err("bad integer: AIDRAMCHANSHIFTDEFAULT")` — **the entire island model was missing**, not one field | `collect_symbols` builds a symbol table from the package's own `localparam` scalars; an unresolved identifier is an error, never a zero |
| Capability-window case labels are symbolic (`CAP_OFF_DRAM_GBPS[15:2]:`) | packed `dram_gbps` / `queues` words silently unsourced | `parse_case_cap_name` reads the label as the capability's own name; the numeric form stays as a fallback |
| `block_mnk` is a shift-OR of `CAP_BLOCK_*_SHIFT`, and `DtypeMask` defaults to `AiIslandDtypeMask` | recovered from an `always_comb` expression and an overridable module parameter, or not at all | both are localparams now, so `ai_cfg.rs` reads them from the **package** and the cap-window parse is the fallback |
| Flag accessors index by constant (`d.flags[FLAG_DTYPE_SHIFT +: FLAG_DTYPE_WIDTH]`) | `flags_layout` came back `None`, so `dtype`/`ew`/`sp24` were unresolved despite being published | `parse_flag_localparam` prefers `FLAG_*_SHIFT`/`_WIDTH`; the range-parsing accessor path stays as a fallback |

**The lesson is a reader-side one and it generalises:** a package that graduates from literals
to named constants looks *more* published to a human and *less* published to an ingest. A
closure claimed on the design side is not closed until something reads it, which is why the
live-file tests now assert the published state rather than asserting its absence.

### 2.3 A derived placement that collided with a published one

`AiRegMap::from_desc_layout` placed the status register at `desc_base + desc_bytes`, i.e.
`0x140 + 0x40 = 0x180` on the reference package — which is exactly `PMU_OFF_R_BEATS`. A
guest reading status got a beat counter, and a guest writing status poked the PMU window.
Nothing failed loudly, because both are plausible 32-bit values.

`AiRegMap::from_model` now takes the control surface from `REG_OFF_*` and only falls back to
the derived placement when the design publishes none. The two are distinguished by
`status_packed`, because the published register is packed (`busy | last_status << 16`) while
the derived fallback is a bare status code — reporting the packed layout for an offset the
design never named would be an invention of the same kind.

**Standing ask (unchanged):** `0x110` done-ticket, `0x114` done-status and `0x118`/`0x11C`
`desc_ptr` are still register-map comments rather than localparams. They are the remaining
quarter of F1; the doorbell-and-claim path does not need them, the DMA-fetch path does.

## 3. What the asks unblock, in dependency order

```text
F1 placement ────► guest-addressable island ────► pushed path end-to-end
   │                                                   │
   │                                                   ▼
   └──► generated device model agrees with B3    remote route carries submissions
F2 version ──────► honest bad-version reporting
F3 packing ──────► complete capability window ──► one guest binary across parts
F4 word map ─────► host image == device == emitted model
F5 flag packing ─► ingested dtype instead of a shared Rust constant
F6 cluster dispatch ─► per-cluster tensor events and queue validation
F7 cap doc vs RTL ─► a host may discover geometry from the document at all
F8 clusters enabled ─► per-cluster attribution ──► F6 is unambiguous
F9 PMU offsets ──► modelled D2 estimate can be diffed against RTL measurement
F10 arith subfields ─► sub-byte / sparse work is expressible ──► effective-TOPS
                       accounting (scaling-100tops.md §2) is possible at all
F11 measured DRAM ─► the bandwidth half of the roofline exists ──► "compute-bound"
                     or "bandwidth-bound" becomes a statement rather than a guess
F14 measured range ──► the cap window can report a 400 GB/s measurement without saturating
F12 shape limit ──► a host knows when to tile ──► the §12 4096³ gate is runnable
F13 writeback term ─► bandwidth sizing at small K is not 3x optimistic
```

### 3.1 Why F10 and F9 gate the 100-TOPS programme

The island's stated target is 100 × 10¹² dense INT8 ops/s, with sub-byte and 2:4-sparse modes
reported **separately** rather than folded into the headline (`scaling-100tops.md` §2). That makes two
of the asks above load-bearing rather than tidiness:

- **F10 decides whether the second number can exist.** Effective INT4 2:4 throughput is a function of
  `ew` and `sp24`. Both currently live in bits the design does not name, inside a comment span that
  also holds `dtype` and `accmode`. Until they are published, a request for sub-byte work is
  indistinguishable from a mis-set `dtype`, so the emulator refuses to model it — which is correct,
  and is also why the number cannot be quoted.
- **F9 decides whether any modelled number can be checked.** The acceptance metrics are *measured*
  quantities (`BW_measured`, `TOPS_sustained@AI`). The emulator's D2 layer produces *modelled* ones.
  A modelled number that is never diffed against the measurement is not feedback; it is decoration.

The live geometry makes the size of the gap concrete. `AiIslandLatencyDefault` is one cluster at 256
MAC/cycle and 1 GHz, i.e. **0.512 TOPS** by the §2 definition; the §5.1 throughput SKU is 8 clusters ×
4096 MAC/cycle at 1.5 GHz, i.e. **98.3 TOPS** — a **192×** gap, of which 128× is MAC width and 1.5× is
clock. The published `256³` directed result of **83,705 cycles** against an ideal of 65,536
(`16,777,216` MAC ÷ 256 MAC/cycle) is **78% MAC utilisation**, so roughly 18,000 cycles are
sequencing and memory rather than arithmetic. Those overhead cycles do **not** shrink when the array
widens: at the 8192 MAC/cycle latency-SKU target the same GEMM needs only 2,048 MAC cycles, so on
today's memory path utilisation would fall to about 10%. That is exactly the failure mode
`scaling-100tops.md` §11 orders the track to make structurally impossible ("growing the MAC array
ahead of the memory system produces a part that cannot reach its own peak") — and it is a prediction
the emulator can state, and F9 is what lets the RTL contradict it.

`g6q-diag::roofline` computes all of the above from the ingested configuration, and its tests pin the
plan's own worked numbers so the model tracks the design rather than a retyped table: the 8-cluster
SKU comes out at 98.3 TOPS with a machine balance of ~123 MAC/byte (§4 says ~125), the `T = 512` row
is compute-bound, the `T = 128` row is bandwidth-bound (§4 asks 781 GB/s for it), and the arithmetic
intensity of a `T`-blocked GEMM is `T / 2` regardless of shape. Against the live configuration the
same module reports the MAC bound and **refuses** the bandwidth bound when no measured value is
supplied, because F11 leaves `DramGBps` at zero. If a measured `measured_dram_gbps_x1000` is supplied,
the roofline closes and the cap window publishes it in the upper 16 bits of `CAP_OFF_DRAM_GBPS` —
but F14 notes that the 16-bit half saturates at 65.535 GB/s (in 1/1000 units), so the 400 GB/s target
cannot be reported precisely through that field.

| Quantity | Live config | Throughput SKU (§5.1) |
|---|---|---|
| MAC/cycle | 256 | 32 768 |
| Peak, §2 definition | 0.512 TOPS | 98.3 TOPS |
| Blocking `T` | 256 | 512 |
| Input-only intensity (§4's number) | 128 MAC/byte | 256 MAC/byte |
| Intensity incl. `s32` writeback (F13) | **42 MAC/byte** at `256³` | — |
| Machine balance | **unresolved** (F11) | ~123 MAC/byte |
| Max submittable shape (F12) | 256 per dimension | 512 per dimension |
| `256³` MAC bound | 65 536 cycles | — |
| `256³` measured (design side) | 83 705 cycles → **78%** | — |

### 3.2 What reading the GEMM unit changed about the model

The first version of the roofline applied §4's `2 / T` directly. Reading
`g6lc_ai_gemm_seq.sv` showed that this is right only at the one shape it was first tested on,
and the module now carries a corrected model. The correction is recorded because it is a
statement about the *design*, not only about the emulator:

| | §4's model | `g6lc_ai_gemm_seq.sv` as built |
|---|---|---|
| Dataflow | `T × T` output block, streaming the reduction | load **all** of A, then **all** of B, MAC, store C |
| Valid shape range | any `m, n, k` | `m, n, k ≤ MaxDim` only (F12) |
| Input bytes | `macs · 2 / T` | `m·k + k·n`, each operand read once |
| Writeback | not counted | `4 · m · n`, i.e. 2× the inputs at `m = n = k = T` (F13) |

The two agree exactly at `m = n = k = T`, which is why a maximal-shape test cannot distinguish
them. They diverge in both directions: below `T` the `2 / T` figure is *lower* than the bytes
the operands themselves occupy, and above `T` the resident schedule cannot run at all. The
module therefore reports `max(compulsory_read, tiled_read) + writeback`, which needs no
dataflow assumption and is correct at both ends.

**The consequence for the climb to 100 TOPS is not the array width.** The measured `256³` point
spends 22% of its cycles outside the MAC array, and the traffic it generates is dominated by the
`s32` writeback rather than by operand reads. Both of those are memory-system properties. Widening
`MacsPerCycle` from 256 toward the 8192 latency-SKU target shrinks only the 78% that is already
arithmetic, so on today's load/store path it would move utilisation to roughly 10% and leave the
delivered throughput almost unchanged. The optimisation that pays is in `ST_LA`/`ST_LB`/`ST_STC`
and the burst behaviour around them — which is the order `scaling-100tops.md` §11 already
prescribes (I3 before I2), now with a number attached.

F1 is load-bearing: until it lands, every other accelerator result is against a model that states
its own bases rather than against the design's. Note that the B2 plugin now *gates itself* on F1:
with the placement unresolved it emits an access stream rather than a submission stream, because
decoding against a guessed base would produce plausible-looking wrong tensor events.

### 3.3 How this should progress toward 100 TOPS (and what must stay off that path)

The island track in `scaling-100tops.md` §11 is still the order: **measure I3 bandwidth before I2
clusters**. The emulator must not grow a second MAC/byte model in Python (`AI_BRIDGE.md` limit 2);
`g6q-diag::roofline` is the bound. virt_ai_card + EDK2 ESP is **layout agreement**, not I3.

**On the 100-TOPS path (change set: island + host push):**

1. Keep the §2 headline (dense INT8, no INT4/sparsity folded in). F10 is what would allow a
   *second* effective-TOPS number, not a rewrite of the first.
2. Size from F13 (writeback) and F12 (tile, do not submit 4096³ as one descriptor).
3. Close F11/F9/F14 so `BW_measured` and `TOPS_sustained@AI` can be diffed against D2, not guessed.
4. Publish F8 then replicate clusters (I2) behind the same DESC/doorbell ABI (F6).
5. Publish F1 so B1 guests map the island; pin `ai_host_transport` only then. Until that pin, do
   not fuse QEMU GPEX (root complex) with virt_ai_card (endpoint).

**Off the island critical path (separate change sets — `current-stage.md` §2):**

| Change set | Relation to 100 TOPS |
|---|---|
| SMT2 / soft-ladder / R3b Image | Host Linux workers need two honest harts (SL-C). Not MAC width. |
| QEMU U-Boot/EDK2 | Firmware hypothesis for the card's own Linux. Never Variane evidence. |
| Full OoO + multi-issue packages | Control-plane IPC. `OoOEn=0` stays identity. Do not put island knobs in `cva6_cfg_t` (§8). |
| Multi-core `NrCores` | Independent of cluster count (SMT cap `S≤8`, `CVA6_MAX_SMT_HARTS=2`). |
| Hypervisor / KVM | Needed for a server SKU, not for island TOPS. |
| Stream plane `g6lc64_stream8` | Orthogonal envelope until FDT trusted; do not merge with smt2 DI. |
| RVV / Ara | Core-attached memcpy/math. Do **not** widen `AiTileM/N/K=8` with island TOPS. |

The live 0.512 TOPS fixture versus the ~98.3 TOPS plan is a **192×** MAC×clock gap. Growing
`MacsPerCycle` without I3 (F11) is the §11 failure mode the emulator already predicts (~10%
utilisation if the 256³ memory path is unchanged).

## 4. Using the emulator to debug cluster bring-up

This is the other direction of the same loop, and it is the reason the speed difference matters.

| Instrument | What it answers | Where it is defined |
|---|---|---|
| B3 native run | does the queue/descriptor sequence behave as the ISA says? | [`EMIT.md`](EMIT.md), [`DESIGN.md`](DESIGN.md) §3 |
| B1+B2 full system | does a real driver and firmware drive it correctly? | [`EMIT.md`](EMIT.md) |
| D1 tandem + checkpoint | *which instruction* first diverges from a reference or a captured trace | [`DIAG.md`](DIAG.md) |
| D2 tensor counters | how much work was submitted, and did it complete | [`DIAG.md`](DIAG.md) §4.1 |
| tensor artifact | the descriptor/MMIO event stream, comparable across routes | [`AI_BRIDGE.md`](AI_BRIDGE.md) §5 |

The workflow that pays for itself:

1. Reproduce the failure on the **fastest instrument that can still exhibit it** — usually B3, then
   B1 if firmware or a driver is implicated.
2. If a reference exists, run **D1 tandem** and take the *first* divergence, not the symptom.
3. Export a **checkpoint** near the divergence so a cycle-exact simulator resumes there instead of
   re-running the boot.
4. Compare the **tensor artifact** between a known-good and a failing run with
   `ai_tensor_bridge.py compare`, which reports first divergence rather than a wall of differences.

Two honesty constraints on anything this produces:

- results are a **hypothesis and a checkpoint**, never verification evidence
  ([`../AGENTS.md`](../AGENTS.md) directive 8);
- only the faithful machine profile may be cited; a deviated or virt run is stamped and quarantined
  ([`DESIGN.md`](DESIGN.md) §4).

### 4.1 A live case the emulator is the right instrument for

The design's own two-thread firmware bring-up does not currently complete its platform
initialisation: the reported hart count never reaches the expected total, so the topology is not
trustable. Under RTL simulation that failure costs a long run per attempt; on B1 it is orders of
magnitude cheaper, and D1 gives the first divergent instruction rather than a hang.

Two invariants this package therefore enforces on anything it emits, so the emulator cannot mask the
defect it is being used to find:

- the number of processor nodes in the emitted tree equals the total logical hart count, and
- the firmware's reported hart count equals that same total before any topology claim is trusted.

An emulator that happily booted a tree those two rules reject would be actively harmful here.

## 5. Aggregation policy

Findings batch into change sets rather than landing one commit at a time, because a single finding
usually touches the reader, the IR, the schema, a device or emitter, and a document — and a partial
landing leaves the IR and the schema disagreeing.

A change set is ready when:

- [ ] the reader resolves the new field, and reports it **unresolved** when absent;
- [ ] the IR and `schemas/*.json` both carry it (the schema is `additionalProperties: false`, so
      omitting it makes previously-valid models invalid);
- [ ] no consumer defaults it silently; degradation is visible at the CLI or in the report;
- [ ] a test asserts the *absent* case as well as the present one;
- [ ] a test pins the design's published name set, so a newly added name surfaces as a tracked gap
      instead of silently disappearing;
- [ ] the architecture document and [`../AGENTS-todo.md`](../AGENTS-todo.md) are updated in the same
      pass;
- [ ] `python tools/g6q.py check` is green.

The name-set test is the one most often skipped and the most valuable: a capability or field the
design adds and this package ignores becomes a guest-visible zero, and zero is usually a legal value,
so nothing looks wrong anywhere.
