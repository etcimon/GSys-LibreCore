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
