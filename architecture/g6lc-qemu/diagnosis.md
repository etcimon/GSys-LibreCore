# `g6lc_qemu` — the diagnosis layer (D1 tandem, D2 microarchitectural)

Parent: [`README.md`](README.md) · Backends: [`backends.md`](backends.md).
Package implementation: `g6lc_qemu/crates/g6q-diag` (+ emitted `g6lc_rvfi.c`, `g6lc_uarch.c`,
`g6lc_pmu.c` plugins for the QEMU path).

**Two tiers, one front end, never the same run.** D1 answers *"is this emulator telling the truth
about the architecture?"* and, by extension, *"where did the RTL and the reference first disagree?"*
D2 answers *"how does this configuration behave microarchitecturally?"* Conflating them produces a
run that is both slow and untrustworthy.

| | **D1 tandem** | **D2 microarchitectural** |
|---|---|---|
| Question | correctness / divergence | behaviour / counters |
| Cost | ~1.2–2× the functional path | 10–50× |
| Output | `st_rvfi` trace, divergence report, checkpoint | PMU counters, structure hit/miss profiles |
| Backends | B3 (native) and B2 `g6lc_rvfi.c` | B2 `g6lc_uarch.c` + `g6lc_pmu.c`, B3 |
| Accepts | equality with a reference | **correlation** with Verilator, with error bars |
| Selected by | `--diag d1` (`--tandem …`) | `--diag d2` |

`--diag full` runs both and is expected to be slow; it exists for a single reproduction, not for a
suite.

---

## 1. Why `st_rvfi` and not a new format

The repository already has a lingua franca for architectural commit records:

- `core/cva6_rvfi.sv` builds `rvfi_instr_t` + `rvfi_csr_t` from the core (including `aicfg` /
  `aistatus` when `AiCfg.MatrixEn`, via `CONNECT_RVFI_SAME`).
- `corev_apu/tb/common/spike.sv` marshals those into `st_rvfi` and calls
  `rvfi_spike_step(core, reference_model)` / `rvfi_compare(core, reference_model)`.
- The DPI side is `verif/core-v-verif/vendor/riscv/riscv-isa-sim/riscv/riscv_dpi.cc`
  (`spike_step_struct`, `spike_get_csr` / `spike_put_csr`).

Adopting `st_rvfi` means the emulator **slots into the existing tandem infrastructure as a third leg**
instead of forming a separate universe:

```text
                     ┌──────────── st_rvfi ────────────┐
   Verilator RTL ────┤                                 ├──── Spike (reference)
   (evidence)        └──────────── st_rvfi ────────────┘
                                    │
                              g6lc_qemu (B3 / B2 plugin)
```

Three usable pairings fall out for free: emulator↔Spike (validates the emulator), emulator↔Verilator
(finds RTL bugs at ~10⁴× the rate), and emulator-as-reference (because unlike Spike it knows the
`ariane_soc_pkg` map, the island MMIO, the LibreCore CSR set and the PMU groups).

**Contract:** the record layout is consumed by pin, not re-derived. `pins.toml` records the
`st_rvfi` revision; a layout change bumps the pin deliberately.

---

## 2. D1 — the tandem tier

### 2.1 What is emitted

Per retired instruction, per hart: `order`, `insn`, `trap`+`cause`, `halt`, `intr`, `mode`, `ixl`,
`rs1/rs2` addr+data, `rd` addr+data, `pc_rdata`/`pc_wdata`, `mem_addr`/`rmask`/`wmask`/`rdata`/`wdata`,
plus the CSR bundle (`mstatus`, `mcause`, `mepc`, `mtvec`, `misa`, `mtval`, `mideleg`, `medeleg`,
`satp`, `mie`/`mip`, the S-mode set, `pmpcfg*`/`pmpaddr*`, `minstret`/`mcycle`, and — when live —
`aicfg`/`aistatus`, `vstimecmp`/`htimedelta`).

### 2.2 Divergence bisection

`g6q tandem --tandem spike|verilator --tandem-ref PATH --stop-on-divergence`:

1. run both sides in lockstep, indexed by `order` / `instret` per hart;
2. on the first differing field, emit a **divergence record** — the two `st_rvfi` structs side by
   side, the differing fields highlighted, the surrounding N instructions of context, the guest
   symbol (from `--kernel`/`--fw` symbols when available), and the `TargetModel` capability rows
   relevant to the differing field;
3. exit non-zero with a machine-readable `divergence.json`.

The value is the *index*: today a 200 M-cycle Verilator soak that ends in a hang gives you a `hangpc`
and a log. A lockstep run gives you the instruction where truth was lost.

### 2.3 Determinism is a precondition

Non-negotiable for anything feeding D1 (`--deterministic`, implied by `--tandem`):

| Source of non-determinism | Handling |
|---|---|
| `mtime` / timer interrupts | fixed instructions-per-tick ratio (`--icount`-equivalent), never host wall clock |
| CLINT software IRQ / IPI | delivered at fixed `(hart, instret)` boundaries |
| PLIC external IRQ (UART, island `AI_DONE`, virtio) | recorded on capture, replayed by index |
| Console input, network, block I/O | `--record FILE` / `--replay FILE` |
| MTTCG thread interleaving | tandem runs single-threaded per hart with a deterministic round-robin quantum; `--smp >1` with `--tandem` requires `--deterministic` and pins the quantum |
| Host RNG / ASLR-ish state | seeded from the model rev |

Without this the emulator is not an oracle, it is a second opinion.

---

## 3. D2 — the microarchitectural tier

D2 models **exactly the structures `cva6_cfg_t` parameterises**, at the sizes the target actually
configures. Not idealised structures, and not the RTL — *the configured shape*.

| Modelled | Driven by | Diagnoses |
|---|---|---|
| BTB, BHT/gshare, TAGE-lite components, loop predictor, ITTAGE indirect, statistical corrector | `BTBEntries`, `BHTEntries`, `BHTHist`, `BPType`, `BPGhistLen`, `BPTageTables`, `BPTageTableEntries`, `BPTageTagBits`, `BPLoopEn`, `BPIndirectEn`, `BPIndirectEntries`, `BPStatCorEn` | mispredict hot spots; predictor sizing |
| RAS | `RASDepth` | overflow from deep call chains (OpenSBI / FDT walks are a known offender) |
| FTQ / FDIP / loop buffer occupancy | `FtqDepth`, `FdipEn`, `FdipDistance`, `LoopBufEn`, `LoopBufEntries` | fetch starvation |
| I-TLB, D-TLB, shared TLB | `InstrTlbEntries`, `DataTlbEntries`, `UseSharedTlb`, `SharedTlbDepth` | TLB thrash during boot / page-table churn |
| L1I, L1D/HPDCACHE (repl policy, way-pred), L2, L3 | `ReplPolicy`, `WayPredEn`, `WayPredEntries`, `DcacheMshrDepth`, `HwPrefetchEn`, `HwPrefetchStreams`, `L2*`, `L3*` | miss rate, conflict sets, MSHR pressure |
| Scoreboard / issue / commit occupancy | `NrScoreboardEntries`, `NrIssuePorts`, `NrCommitPorts`, `SuperscalarEn`, `ALUBypass` | issue stalls, dual-issue utilisation |
| Store buffer / load buffer | `MaxOutstandingStores`, `NrLoadBufEntries`, `WtDcacheWbufDepth`, `DeepSpecEn` | STQ pressure |
| SMT thread select | `NrHarts`, `SmtPolicy`, `SmtFetchQuantum`, `SmtStarveLimit` | thread starvation, quantum effects |
| Coherence traffic | `NrCores`, `CohPolicy`, `SnoopFilterEn`, `SnoopFilterEntries` | snoop pressure |

**What D2 deliberately does not model:** the pipeline itself. There is no attempt to reproduce
`cva6.sv`'s stage timing, OoO scheduling (`OoOEn`), slice steering (`SliceOoOEn`), or FSE recovery
latency. Those are *cycle* questions and Verilator owns them. D2 reports structure hit/miss and
occupancy, which are the quantities that actually guide sizing decisions and that a functional
emulator can supply honestly.

---

## 4. Checkpoints and the Verilator hand-off

The highest-value feature for the current workflow, and the reason D1 is worth building before D2.

```text
  g6q run --backend rust --deterministic --record run.rec ...        [seconds–minutes]
      │  divergence / hang detected at instret N
      ▼
  g6q diag --replay run.rec --checkpoint-at instret=N-100000 --checkpoint-out ckpt/
      │
      ▼
  Verilator resume from ckpt/ for the last ~100 k instructions       [minutes, not hours]
```

The checkpoint carries: architectural state per hart (GPRs, FPRs, full CSR file, `mstatus`/`satp`/
privilege/`V`), guest DRAM image, device state (CLINT `mtime`/`mtimecmp`, PLIC pending/enable/claim,
UART FIFOs, island CTL/queue/CPL state), and the pending-IRQ schedule from the record file.

Against today's baseline — I4dp Linux boots capped at **200 M cycles** on the remote builder
(`../multi-threading/testharness-proxy.md`) — this converts a blind multi-hour soak into a targeted
window. It is explicitly a *triage* mechanism: the resumed Verilator run is what produces evidence,
not the emulator.

**Constraint to respect:** checkpoint export is `g6lc-soc` only. A `g6lc-virt` checkpoint contains
device state that has no RTL counterpart and cannot be resumed.

---

## 5. PMU: the same numbers on both sides

`core/perf_counters.sv` packs event selectors as `{group[7:5], idx[4:0]}`
(`ariane_pkg::MHPMEventGrpWidth=3`, `MHPMEventIdxWidth=5`). D2 emits **the same table**, ingested by
[`generator.md`](generator.md) §2.4:

| Group | Events |
|---|---|
| **0** legacy (idx 1–22) | L1 I$/D$ miss, ITLB/DTLB miss, load, store, exception, eret, branch, **mispredict**, branch exception, call, return, SB full, IF empty, L1 I$/D$ access, eviction, I-TLB flush, integer, FP, pipeline bubbles |
| **1** OoO / MLP | rename+ROB backpressure, IQ/issue stall, mispredict, load, store, LSQ stall, STL forward, rename stall |
| **2** server memory | L3 miss, L3 hit, PF issue, PF train, L2 miss |
| **3** FSE | mispredict, spec cancel, window full, issue bubble, load pressure, store pressure |
| **4** `MHPMGrpAI` | `ai_op`, `ai_mma`, `ai_post`, `ai_t0`, `ai_busy` (gated on `AiCfg.MatrixEn`) |

Consequences that make this worth doing properly:

- A guest reading `mhpmcounterN` under the emulator gets numbers **directly comparable** to the same
  guest on Verilator or FPGA.
- The DTS `riscv,pmu` `riscv,event-to-mhpmevent` map (already present in `ariane-ai.dts`) is generated
  from the same table, so Linux `perf` sees consistent events.
- `Sscofpmf` semantics are modelled: `mhpmeventN[63]` OF, `[62]` MINH, `[61]` SINH, `[60]` UINH,
  `scountovf`, and the LCOFI overflow interrupt — because `perf record` will exercise them
  immediately and a wrong overflow path looks like a kernel bug.
- Because the table is *derived*, a new PMU event added to `perf_counters.sv` (as `AGENTS.md` §0.2
  requires for every new feature) appears in the emulator without an edit here.

---

## 6. Error bars (say these out loud, every time)

| Quantity | Status |
|---|---|
| Architectural state, traps, CSR values, memory contents | **exact** — divergence is a bug in one of the two sides |
| Instruction counts (`minstret`), event *counts* of architectural events (loads, stores, branches, calls, returns, exceptions) | **exact** |
| Structure hit/miss (BP, TLB, cache) | **modelled** — same geometry and policy, but no pipeline timing, no speculative-path pollution, no wrong-path fetches. Expect the *shape* to match and the absolute rate to differ. |
| Occupancy / stall events (SB full, IQ stall, bubbles) | **weakly modelled** — indicative only |
| Cycles (`mcycle`), IPC, anything latency-derived | **not modelled**. `mcycle` under the emulator is a synthetic count and is labelled as such in every dump. |

Acceptance criterion for D2, stated in [`staging.md`](staging.md) Q7: **trend correlation** with a
Verilator run on the same workload — same ranking of hot spots, same order of magnitude — never
equality. A D2 report that claims a cycle count is a defect in the reporting, not a win.

---

## 7. Evidence discipline

Repeated from [`README.md`](README.md) §6 because this is the document where it is most likely to be
forgotten:

> `g6lc_qemu` output — including a clean tandem run, a green capability matrix and a plausible PMU
> profile — is **never** citable as a soak, peel, pin or Linux-cap result.
> `architecture/multi-threading/testharness-proxy.md` §1 governs: one toolchain, evidence on the
> builder, classify from the log. This tool produces a **hypothesis and a checkpoint**.

Practically: `g6q` writes `"evidence": false` into every JSON result, and the human-readable footer of
every report ends with the proxy pointer. Making that annoying to remove is the point.
