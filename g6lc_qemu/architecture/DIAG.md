# DIAG — diagnosis tiers D1 and D2

Index: [`README.md`](README.md) · Crate: `g6q-diag` (plus the emitted trace / microarchitecture /
counter plugins for the QEMU path).

**Two tiers, one front end, never the same run.**

| | **D1 tandem** | **D2 microarchitectural** |
|---|---|---|
| Question | is the emulator telling the truth, and where did two implementations first disagree? | how does this configuration behave structurally? |
| Cost | ~1.2–2× the functional path | 10–50× |
| Output | commit-record trace, divergence report, checkpoint | counters, structure hit/miss and occupancy |
| Acceptance | **equality** with a reference | **correlation** with RTL, with error bars |
| Flag | `--diag d1` (implied by `--tandem`) | `--diag d2` |

`--diag full` runs both. It exists for a single reproduction, not for a suite.

---

## 1. Determinism is a precondition

Non-negotiable for anything feeding either tier:

| Source of non-determinism | Handling |
|---|---|
| Timer counter and interrupts | fixed retired-instructions-per-tick ratio; never host wall clock |
| Software interrupts / inter-processor interrupts | delivered at fixed `(hart, instret)` boundaries |
| External interrupts (console, device completion, virtio) | recorded on capture, replayed by index |
| Console input, network, block I/O | `--record` / `--replay` |
| Multi-threaded translation interleaving | tandem pins a deterministic round-robin quantum |
| Host entropy | seeded from the model revision |

A non-deterministic oracle is not an oracle. `--tandem` and `--record` imply `--deterministic`.

---

## 2. D1 — tandem

### 2.1 Record format

An RVFI-shaped commit record per retired instruction per hart: ordering index, instruction word, trap
and cause, halt, interrupt flag, privilege mode, source and destination register addresses and data,
program counter before and after, memory address / read mask / write mask / read data / write data,
and the control-and-status register bundle the design exposes on its trace interface — including any
vendor CSRs.

**The layout is consumed by pin** (`../pins.toml`, `contracts.trace_record`). Adopting the design
project's existing record shape rather than inventing one is what lets this package slot into an
existing tandem flow as an additional participant instead of forming a separate universe.

The generated B2 trace plugin (`g6lc-<target>.so`) produces the same `RecordFile` object.  QEMU
records are ordered by `order`, carry the machine profile in `header.profile`, and are written
numerically so they load without a custom parser.  When `run --backend qemu --record FILE` is used,
the CLI automatically loads the plugin with a `trace=` argument, copies the temporary plugin output
to `FILE` after QEMU exits, and removes the temporary file.

### 2.2 Divergence bisection

```
g6q tandem --tandem <reference> --tandem-ref <path> --stop-on-divergence
```

1. run both sides in lockstep, indexed per hart;
2. on the first differing field, emit a divergence record: the two structs side by side, differing
   fields highlighted, N instructions of context, the guest symbol when symbols are available, and the
   conformance rows relevant to the differing field;
3. exit non-zero with `divergence.json`.

The value is the **index**. A long RTL soak that ends in a hang yields a stuck program counter and a
log; a lockstep run yields the instruction at which truth was lost.

### 2.3 Checkpoints and the hand-off

```text
  run  --deterministic --record run.rec            [seconds–minutes]
       │ divergence or hang at retired-instruction N
       ▼
  diag --replay run.rec --checkpoint-at instret=N-100000 --checkpoint-out ckpt/
       │
       ▼
  cycle-exact simulator resumes the last ~100k instructions   [minutes, not hours]
```

The checkpoint carries per-hart architectural state (integer and floating-point registers, the full
CSR file, privilege and translation state), the guest memory image, device state (timer compare
values, interrupt-controller pending/enable/claim, console FIFOs, accelerator control and queue
state), and the pending-interrupt schedule from the record file.

This converts a blind multi-hour soak into a targeted window. It is a **triage** mechanism: the
resumed cycle-exact run produces the finding; the emulator produced the pointer.

**Checkpoints are faithful-profile only.** A virt-profile checkpoint contains device state with no
hardware counterpart and cannot be resumed.

### 2.4 RTL/RVFI text trace ingestion

The CVA6 `rvfi_tracer` writes `trace_rvfi_hart_<hart>.dasm` with one line per retired instruction:

```text
core   0: 0x1000 (0x00000293) DASM(0x00000293)
3 0x1000 (0x00000293) x5 0x0000000000000001
```

`g6q-diag/src/rvfi.rs` parses this text, maps exception names to `mcause` values, and derives
`pc_wdata` from the next record's `pc_rdata` (the last record uses `pc + instruction size`, with
`halt` set for `wfi`/`ebreak`).  It produces the same `CommitRecord` vector used by the tandem
path, so `tandem --under-test trace_rvfi_hart_0.dasm --reference qemu.json` can compare RTL against
QEMU without an intermediate conversion step.

Because the dasm format omits `pc_wdata`, source register values, and the CSR bundle, the comparison
is a structural one: it validates PC, instruction word, privilege mode, destination register writes
and the trap cause.  Full RVFI parity (memory masks/data, source registers, CSRs) requires either an
extended dasm format or a structured RVFI dump from the simulator.

---

## 3. D2 — microarchitectural models

D2 models **exactly the structures the configuration parameterises**, at the sizes the target actually
configures — not idealised structures, and not the RTL.

| Modelled | Sized by |
|---|---|
| Branch target buffer, history table, tagged predictor components, loop predictor, indirect predictor, statistical corrector | the predictor type and each table's entry / history / tag width fields |
| Return address stack | its depth field |
| Fetch queue, prefetch run-ahead, loop buffer occupancy | their depth and enable fields |
| Instruction, data and shared translation buffers | their entry counts and the shared-TLB flag |
| L1 instruction and data caches, second and third level caches | geometry, replacement policy, way-prediction, miss-handling depth, prefetcher streams |
| Scoreboard, issue and commit occupancy | scoreboard entries, issue and commit port counts, bypass flags |
| Store and load buffers | outstanding-store and load-buffer limits, write-buffer depth |
| Thread select | threads per core, policy, quantum, starvation limit |
| Coherence traffic | core count, coherence policy, snoop-filter size |

**What D2 deliberately does not model:** the pipeline. No stage timing, no out-of-order scheduling, no
recovery latency. Those are *cycle* questions owned by an RTL simulator. D2 reports structure hit/miss
and occupancy — the quantities that guide sizing decisions and that a functional emulator can supply
honestly.

---

## 4. Counters

The design's performance-counter module packs event selectors as `{group, index}`. D2 emits **that
table**, ingested per [`INGEST.md`](INGEST.md) §5, so:

- a guest reading the counters under the emulator gets values comparable with the same guest on RTL or
  hardware;
- the generated device-tree performance-monitor mapping is built from the same table, so the guest
  kernel's profiler sees consistent events;
- counter-overflow semantics (overflow flag, per-privilege inhibit bits, the overflow-status CSR and
  the overflow interrupt) are modelled, because a profiler exercises them immediately and a wrong
  overflow path looks like a kernel bug;
- an event added to the design's counter module appears here without an edit.

### 4.2 Microarchitectural structure counters

`g6q-diag::uarch::structure_counters` reads the `uarch.raw` map produced by ingest and emits
`Counter` values for the structures listed in §3: BTB/BHT/RAS, fetch and issue queues, scoreboard,
load/store buffers, cache sizes and TLB depths. The counter names are stable (`uarch.btb.entries`,
`uarch.l1d.size_bytes`, `uarch.scoreboard.entries`, etc.); the values are the design's own
configured or derived scalars. A field the design leaves at `0` to mean "infer" is skipped rather
than reported as zero.

All structure-size counters are `Fidelity::Exact` for the configured geometry. A counter the
emulator derives from these later (hit rates, occupancy, stall indicators) is `Modelled` or `Weak`.

### 4.3 AI-island analytic bound (roofline)

`g6q-diag::roofline` is the one place the package produces a *performance* number, and it does so
without simulating time. It applies the bandwidth model of the design's own scaling plan to the
**ingested** island geometry: given a GEMM shape plus the published cluster count, MAC rate, blocking
factor, clock and DRAM class, it states the two bounds the shape cannot beat and which one binds.

| Quantity | Derivation | Fidelity |
|---|---|---|
| `ai.roofline.mac_bound_cycles` | `m·n·k / (clusters × macs_per_cycle)` | `Modelled` |
| `ai.roofline.blocking_t` | `min(acc_tile_m, acc_tile_n)` — the accumulator's output block, **not** a PE array dimension | `Modelled` |
| `ai.roofline.dram_read_bytes` | `max(m·k + k·n, macs × 2 / T)` — the compulsory-read floor or the tiled re-read model, whichever is larger | `Modelled` |
| `ai.roofline.dram_write_bytes` | `4 · m · n`, the `s32` accumulator writeback the plan's derivation omits | `Modelled` |
| `ai.roofline.intensity_mac_per_byte` | `macs / total bytes`, so it accounts for the writeback and the small-shape floor | `Modelled` |
| `ai.roofline.tiled_input_intensity_mac_per_byte` | `T / 2` — the input-only figure the plan reasons with, kept for comparison | `Modelled` |
| `ai.roofline.shape_fits_blocking` | whether every dimension is within its accumulator tile; beyond that the descriptor is rejected and software must tile | `Modelled` |
| `ai.roofline.balance_mac_per_byte` | MAC-rate ÷ DRAM-bandwidth; every kernel below this is bandwidth-bound | `Modelled` |
| `ai.roofline.peak_ops_per_sec` | `clusters × macs_per_cycle × 2 × clock` — dense, peak, no sparsity or sub-byte multiplier | `Modelled` |

**The read model takes the larger of two figures, and that is load-bearing.** The compulsory floor
`m·k + k·n` is what the operands themselves occupy, with no dataflow assumption in it. The tiled
figure `macs × 2 / T` is the plan's re-read model. Below `T` the tiled figure falls *under* the
floor, which would understate a small shape; above `T` the floor understates the re-reads. The two
coincide exactly at `m = n = k = T`, so a bound tested only at the maximal shape cannot tell them
apart — [`RTL_FEEDBACK.md`](RTL_FEEDBACK.md) §3.2 records why that matters here.

Four rules keep it a bound rather than a claim:

1. **Nothing here is `Exact`.** The geometry is the design's and the arithmetic is exact, but the
   value is a ceiling, so every counter is `Modelled` and therefore not comparable for equality with
   hardware. A test asserts that for every counter the module emits.
2. **An unmeasured DRAM class produces no bandwidth bound.** The live configuration publishes
   `DramGBps = 0` ("not measured"), so `dram_bound_cycles` and `balance_mac_per_byte` are absent —
   not zero, not infinite, and not omitted silently. A part whose memory system is unmeasured has no
   computable roofline, which is precisely why the design's own track measures bandwidth before it
   adds clusters. If a `measured_dram_gbps_x1000` value is supplied, it takes precedence over the
   nameplate and the bandwidth bound closes; the cap window publishes this value in the upper 16 bits
   of `CAP_OFF_DRAM_GBPS` (saturated to `0xFFFF`, which is F14's range limit).
3. **Utilisation requires a measurement the package cannot produce.**
   `Roofline::utilisation_percent` takes a measured cycle count from the design side — an RTL
   testbench or the island's PMU counters, whose offsets are ingested into
   `AiIslandConfig::pmu_offsets` when published (ask F9). The package has no way to invent one, so a
   utilisation figure can never be self-referential.
4. **A bound for an unsubmittable shape is labelled as such.** The descriptor contract bounds each
   dimension by its accumulator tile, so `shape_fits_blocking` travels with every result. Without it
   a caller could compute a confident bound for work the island would reject (ask F12).

The shape-independent rows (blocking factor, intensity, balance, peak) are properties of the part
rather than of a kernel, so they are emitted alongside the other island counters with no shape
argument. The shape-dependent rows need an explicit `m, n, k`.

**Why this belongs in a diagnostic package at all.** The island's stated target is two orders of
magnitude above the live configuration, and the documented failure mode for that climb is widening
the MAC array ahead of the memory system. That mistake is invisible in a functional model — every
descriptor still completes with `ST_OK` — and immediate in a bound. Deriving the bound from ingested
values rather than from numbers retyped out of the plan is what makes it track the design.
[`RTL_FEEDBACK.md`](RTL_FEEDBACK.md) §3.1 works the current numbers through.

### 4.1 AI tensor and queue events

The AI-island is a D2 source, not a D1 architectural path.  Its `AiTensorEvent`s are emitted from:

1. the B3 native VM `AiIsland` device when the guest executes `ai.enq` with a descriptor pointer:
   the device reads the descriptor image from guest memory using the ingested `desc_layout` and
   derives `dtype` from `flags` using `flags_layout`;
2. the B2 QEMU plugin when it observes stores into the descriptor latch window;
3. either backend when a queue ring entry is enqueued; `ai.qfence` in B3 marks the in-flight
   descriptors done and writes the packed completion word to each `ptr_done` in guest memory using
   the ingested `make_completion` layout. A completed `ai.poll` in B3 also writes that word back to
   `ptr_done` so the guest-visible value is consistent even if `ai.qfence` and `ai.poll` are retired
   separately.

A tensor event carries the descriptor address, dimensions, data type, input/output pointers,
ticket, completion status and the operation class.  It is written to a `tensor.json` stream that is
separate from the commit-record trace so the two can be compared, replayed and bisected
independently.

D2 counters sized from `g6lc_ai_island_cfg_pkg.sv`:

| Counter | Derivation | Fidelity |
|---|---|---|
| `ai.tensor.ops` | one per submitted descriptor | exact (counted at submission) |
| `ai.tensor.completes` | events with `done = true` | exact in B3 at artifact close; approximate in B2 (qfence and ptr_done store heuristics) |
| `ai.tensor.bytes` | A/B/C buffer sizes from descriptor `m`, `n`, `k`, `ld_ab` and `dtype` width | modelled — guest may touch only part of the declared buffers |
| `ai.tensor.macs` | `m * n * k` for GEMM/CONV-like ops; `0` for layout/prefetch | modelled — assumes dense, full-tile execution |
| `ai.tensor.queue_entries` | total events in the stream | exact at artifact close; approximate in the plugin (memory accesses only) |
| `ai.pmu.r_beats` | AXI read beats for the last completed event (64-bit data width) | modelled from the event shape; B3 stores the per-event value, B2 stores it when it can correlate a completion |
| `ai.pmu.w_beats` | AXI write beats for the last completed event (s32 accumulator writeback, 64-bit data width) | modelled from the event shape |
| `ai.pmu.cycles` | bound cycle count for the last completed event | modelled from `g6q-diag::roofline::gemm` |
| `ai.pmu.gbps_x1000` | sustained DRAM bandwidth in 1/1000 GB/s for the last completed event | modelled from `bytes * ClockKhz / cycles / 1000`; becomes `measured` when the design publishes and drives the PMU registers |

These are **synthetic** efficiency signals, not verification evidence.

---

## 5. Error bars — state these every time

| Quantity | Status |
|---|---|
| Architectural state, traps, CSR values, memory contents | **exact** — a divergence is a bug in one of the two implementations |
| Retired-instruction counts; counts of architectural events (loads, stores, branches, calls, returns, exceptions) | **exact** |
| Structure hit/miss (predictors, TLBs, caches) | **modelled** — same geometry and policy, but no pipeline timing, no speculative-path pollution, no wrong-path fetches. Expect the shape to match and the absolute rate to differ. |
| Occupancy and stall events | **weakly modelled** — indicative only |
| Cycles, IPC, anything latency-derived | **not modelled**. The cycle counter under the emulator is synthetic and is labelled as such in every dump. |

Acceptance for D2 is **trend correlation** with an RTL run on the same workload: same ranking of hot
spots, same order of magnitude. A D2 report that states a cycle count is a reporting defect.

---

## 6. Evidence discipline

> Diagnosis output — including a clean tandem run and a plausible counter profile — is **never**
> citable as verification evidence. Where this package sits inside a verification project, that
> project's own harness remains the sole source of green. This tool produces a **hypothesis and a
> checkpoint**.

Mechanically: every JSON result carries `"evidence": false`, and every human-readable report ends with
a pointer to the host project's harness of record. Making that annoying to remove is the point.
