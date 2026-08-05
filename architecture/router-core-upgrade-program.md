# CVA6V-EC — low-power OpenWRT router core: 8-upgrade program

**Scaffold document — no RTL here.** This file follows the `architecture/` scaffold contract
(`architecture/README.md`): nothing in this tree is referenced by `core/Flist.cva6`,
`core/Flist.cva6_gate`, any `verif/` flist, or any `pd/` script. It is `.md`, therefore out of
licensing scope per `AGENTS.md` §0.4. It is the **plan of record** that the RTL passes execute
against; every implementation pass must cite the upgrade number it is advancing.

Read first: `AGENTS.md` §0 (SoC/tape-out prime directive), `AGENTS-coding-philosophy.md`,
`AGENTS-configuration.md`, and the domain playbooks in `agents/guides/`.

---

## 0. What this program is

A **hardware-efficiency-ranked** set of eight core upgrades that turn CVA6 into a
**low-power, Linux/OpenWRT router-class core** — best achievable benchmark per watt in a small
form factor, with an experimental/debuggable development posture — while keeping every addition
optional through `config_pkg::cva6_cfg_t` so existing targets elaborate byte-identically.

It includes a **staged path to multi-issue out-of-order execution**, deliberately placed where the
efficiency analysis (§3) puts it rather than at the front, and split so that the *efficient* part of
OoO (memory-level parallelism) lands early and cheaply, and the *expensive* part (full rename +
ROB + dynamic scheduling) lands last behind its own config gate.

---

## 1. The target: what an OpenWRT router core actually runs

Design decisions below are driven by the workload, not by generic SPEC-style reasoning.

| Workload property (OpenWRT / Linux netdev path) | Microarchitectural consequence |
|---|---|
| Softirq/NAPI packet loop: `netif_receive_skb` → bridge/`nftables`/conntrack → route → xmit | Very large **instruction footprint** (hundreds of KB of kernel text) → L1-I misses dominate front-end stalls |
| Indirect dispatch everywhere: netfilter hook arrays, `ndo_*` ops, protocol demux | **Indirect-branch** mispredicts are the #1 control-flow cost; a BTB alone cannot predict them |
| Hash-table / LPM-trie / `skb` pointer chasing | Latency-bound loads with low ILP → **memory-level parallelism (MLP)** is worth more than issue width |
| `memcpy`/`memset`/`skb` zeroing, checksums | `Zicboz` (cbo.zero), `Zbb`, wide store path |
| WireGuard (ChaCha20-Poly1305) / IPsec (AES-GCM) | `Zkn` scalar crypto + `Zbkc` clmul (CRC) — already present as `ZKN`/`RVB` config bits |
| High interrupt rate, timer-driven | **`Sstc`** removes an SBI ecall per timer program; interrupt-entry latency matters |
| Multi-queue NIC + RPS/RSS steering | Thread-level parallelism (SMT2, then 2 cores) beats single-thread width |
| Always-on, fanless, USB/PoE powered | **Static + dynamic power is the binding constraint**, not peak IPC |
| Developers must profile it (`perf`, `ftrace`, gdb) | **`Sscofpmf`** + a `riscv,pmu` DT node + RVFI/trace are features, not nice-to-haves |

### 1.1 Locked configuration profile (the "router profile")

A new per-target package is proposed: `core/include/cv64a6_router_config_pkg.sv`
(name follows the existing `cv64a6_*` convention in `core/include/`).

| Axis | Value | Rationale |
|---|---|---|
| ISA | RV64 `IMAFDC` + `RVB` + `ZKN` + `RVZiCbom` | 64-bit Linux; `B` for bit/byte munging; `ZKN` covers `Zbkc` clmul (CRC32) and AES/SHA for WireGuard/IPsec |
| Privilege / MMU | M+S+U, `Sv39`, `MmuPresent`, PMP + `Smepmp` | OpenWRT userspace + secure boot posture |
| Issue | `SuperscalarEn=1`, `NrIssuePorts=2`, `NrCommitPorts=2`, `NrALUs=2`, `ALUBypass=1` | 2-wide in-order is the perf/W sweet spot before OoO |
| D$ | `DCacheType = HPDCACHE_WT` | Non-blocking with MSHRs + the existing stride prefetcher at `core/cache_subsystem/hpdcache/rtl/src/hwpf_stride/`; write-through keeps the multi-core coherence story simple (§U6) |
| I$ / D$ geometry | 32 KiB / 4-way / 64 B lines both | 64 B aligns with `Zic64b` and the L2 line (§U6) |
| NoC | `NOC_TYPE_AXI4_ATOP` | L2 attaches at the AXI seam, not inside `core/` |
| Frequency / power target | **Fill in `AGENTS-configuration.md` §6.1 before the first synthesis gate** | Every timing claim below is relative to that row; it is currently `<project fills>` |

> **Action item (blocking for §7 synthesis gates):** `AGENTS-configuration.md` §6.1 is still a
> template. The router program needs at minimum: target frequency + sign-off corner, core voltage,
> core power budget, process node/PDK, and SRAM compiler latency. Until those are filled, "closes
> timing" cannot be asserted, only "no new long combinational path was introduced".

---

## 2. The efficiency metric

Every upgrade is scored on **Δperformance / Δpower** at iso-frequency, with Δarea as a tiebreaker,
because a fanless router is power-bound and area-bound long before it is IPC-bound.

```
efficiency index = (1 + ΔIPC_router) / (1 + Δcore_power)
```

- `> 1.15` — **buy immediately** (pays for itself in perf/W)
- `1.00 – 1.15` — buy when the perf is needed
- `< 1.00` — **costs perf/W**; only justified in a development/experimental config, never in the
  shipping low-power profile

Figures below are drawn from the published literature for the named technique and from CVA6's own
structure; they are **design targets to be validated on-silicon-model**, not measurements. Each one
becomes a PMU-measurable acceptance criterion in §7.

| Technique (prior art) | Reported / expected Δperf | Δpower · Δarea | Index | Where it lands |
|---|---|---|---|---|
| TAGE-SC-L / ITTAGE tagged prediction (Seznec) | +6–12% IPC on branchy kernel code; indirect MPKI −40–70% | +1–2% power, ~8–20 KiB SRAM | **~1.08** | U1 |
| Fetch-directed I-prefetch, FDIP (Reinman et al.) | +5–15% on large-I-footprint kernels | ~+1% power (prefetch is cheap; it *replaces* stalls) | **~1.10** | U2 |
| Loop buffer / L0 fetch (ubiquitous in low-power cores) | ~0% perf | **−5–15% front-end energy** | **>1.15** | U2 |
| Way prediction / phased tag-data access (Inoue, Powell) | ~0–1% perf loss | **−20–30% L1 dynamic energy** | **>1.20** | U3 |
| Non-blocking L1 + MSHR depth + stride prefetch (already in HPDCACHE) | +10–20% on pointer chasing | ~+2% power | **~1.12** | U3 |
| **Slice-out-of-order (Load Slice Core, Carlson et al. ISCA'15; Freeway)** | **+50–55% over in-order** | **+15% area/power** | **≈1.33** | **U4 — best OoO-class index in the set** |
| Full 2-wide OoO (rename + ROB + LSQ + wakeup/select) | +60–100% over in-order | **+150–250% power/area** | **≈0.7–0.8** | U5 — production path, config-gated |
| SMT2 on an in-order/slice core | +30–50% *throughput* on packet workloads | +5–10% area/power | **~1.25** | U6 |
| Dual core + shared L2 | ~+1.9× throughput | ~+2× power (but enables lower V/f per core) | ~0.95 raw, **>1.0 with DVFS** | U6 |
| `Sstc`, `Sscofpmf`, `Zicboz`, `Zawrs`, `Svpbmt` | Removes SBI round-trips, speeds `skb` zeroing, cheap idle | **Negligible area/power** | **≫1.2** | U7 |
| Hierarchical clock gating + activity counters | 0% perf | −10–20% dynamic power | **>1.2** | U8 |

**The headline conclusion, stated honestly:** for this target, **full OoO is the *worst* perf/W
item in the set** and the *only* one with an index below 1.0. It is still included — the user
asked for it and it is the right choice for a development/benchmark-chasing configuration — but it
is sequenced last, isolated behind `OoOEn`, and the *efficient 80%* of its benefit (MLP from
decoupled memory slices) is harvested three upgrades earlier in U4 at one-tenth the cost.

---

## 3. The eight upgrades and their dependency order

```
            U7 spec bundle ──────────────┐  (independent, land early: cheap + high value)
            U8 observability/power ──┐   │
                                     v   v
U1 prediction fabric ──> U2 decoupled front-end ──> U4 slice-OoO (MLP) ──> U5 full OoO
        │                         │                        │                    ^
        └───── checkpoint/restore ┴────────────────────────┴────────────────────┘
                                              U3 energy-first L1 ──> U6 L2 + SMT2 + dual core
```

| # | Upgrade | Nature | Efficiency index | Risk | Blocking prerequisites |
|---|---|---|---|---|---|
| **U1** | Prediction fabric: TAGE-SC-lite, ITTAGE, loop predictor, RAS hardening, **branch checkpointing** | In-core, frontend | ~1.08 | Med | — |
| **U2** | Decoupled front-end: FTQ, FDIP I-prefetch, loop buffer | In-core, frontend | ~1.10 (loop buffer >1.15) | Med-High | U1 (FTQ consumes predictions) |
| **U3** | Energy-first L1: way prediction, MSHR/MLP sizing, `Zicboz`/`Zicbop`, RRIP | In-core, cache | >1.15 | Med | — |
| **U4** | **Slice-out-of-order MLP engine** (LSC-style A/B queues + slice table) | In-core, issue/LSU | **≈1.33** | High | U1 (recovery), U3 (non-blocking D$) |
| **U5** | **Full multi-issue OoO**: rename + PRF + ROB + LSQ + wakeup/select | In-core, whole backend | ≈0.75 | **Very high** | U1, U3, U4 |
| **U6** | L2 + thread scaling: SMT2 → coherent dual core | SoC integration + in-core hart state | ~1.25 (SMT2) | High | U3 |
| **U7** | RISC-V spec bundle for Linux/OpenWRT + `.dts` | Spec-anchored, ISA-visible | ≫1.2 | Low-Med | — |
| **U8** | Observability, debug and power management | Cross-cutting | >1.2 | Low | — |

**Recommended execution order** (efficiency-first, de-risking measurement before optimisation):

`U8ᵃ → U7ᵃ → U1 → U3 → U2 → U4 → U7ᵇ → U6 → U5`

where `U8ᵃ` = PMU events + counters only (so every later change is *measurable*), `U7ᵃ` = `Sstc` +
`Sscofpmf` + `Zihintpause` (cheap, unblocks Linux `perf`), `U7ᵇ` = `Zicboz`/`Zicbop`/`Svpbmt`/`Zawrs`
(needed by U3/U6). **You cannot claim a perf/W win you cannot measure — that is why U8ᵃ is first.**

### Execution status (codebase, master)

| Item | Status | Notes |
|------|--------|-------|
| U8ᵃ PMU width | **done** | 8-bit mhpmevent selectors |
| U7ᵃ Sstc / Sscofpmf / Zihintpause | **done** | config-gated; primary Linux target on |
| U1 prediction fabric | **done** | TAGE_LITE + ckpt/gshare/… |
| U3 energy-first L1 | **done** | MRU way-pred, RRIP/DRRIP (HPDCACHE) |
| U2 FTQ / FDIP / loop buffer | **done** | sequential loop inject |
| U4 slice-OoO | **done (off)** | `SliceOoOEn=0` identity |
| Multi-issue width 2–8 | **done** | precursor to U5; dual-issue path green |
| U7ᵇ Zicboz / Zicbop / Svpbmt / Zawrs | **done (partial depth)** | see `agents/spec` CVA6 status lines |
| U7ᶜ full `cbo.zero` line | **done** | multi-beat expand in `store_unit` (`CBOZ_EXPAND`) |
| U6.0 L2 | **done (off)** | `corev_apu/l2_cache/`, `L2En=0` default |
| U6.1 SMT2 | **done (fine)** | PC/CSR/RF/RAS/GHR banks; IF-only switch drain; `smt2` pkg + bring-up notes |
| U6.2 multi-core | **partial→integrated** | cluster+HPDC/WT inv+CLINT×N in harness; PLIC multi-context + `.dts` remain |
| U9.0–U9.2 Hypervisor Sstc×H | **done** | vstimecmp/STCE/VSTIP/htimedelta + VS litmus + virtual-instr STCE |
| U10 server math profile | **C-light done** | `g6lc64_server_math{,_v}`; HPDCACHE+HWPF+L2 auto; `server-math-tests`; Ara open |
| U5 full OoO | **production (gated)** | multi-port rename, cancel-mask recovery, PRF+WB bypass IRO, LSQ CAM/STL; L3+PF |

Spec/architecture docs and `AGENTS-specs-to-impl.md` / `AGENTS-specs-coverage.md` must stay aligned with this table.

---

## 4. Upgrade specifications

Each upgrade below is written to the `AGENTS.md` §0.2 carry-over checklist. Module lists follow the
"keep modules small" rule: no new module should exceed ~300 lines or own more than one clearly named
responsibility.

### U1 — Prediction fabric (TAGE-SC-lite + ITTAGE + loop + checkpointing)

**Intent.** Replace the single-predictor selection in `core/frontend/frontend.sv:514-542` with a
composable *fabric* that keeps the **exact existing port contract** — `bht_prediction_o` /
`btb_prediction_o` arrays at `core/frontend/frontend.sv:139-143` — so the classification stage
(`210-221`) and the priority/selection logic (`236-294`) are **not touched**. This is the seam the
branch-prediction playbook mandates (`agents/guides/AGENTS-branch-prediction.md` §4).

**New modules** (all in `core/frontend/`, all `CVA6Cfg`-parameterised):

| Module | Responsibility | ~Size |
|---|---|---|
| `g6lc_bp_ghist.sv` | Global history register + **folded (CSR) history** registers, one per table geometry; speculative update + checkpoint/restore port | 120 |
| `g6lc_bp_tage_table.sv` | One tagged component: tag + 3-bit ctr + useful bit; `tc_sram` or flop array selected by `CVA6Cfg.TechnoCut`/`FpgaEn` | 180 |
| `g6lc_bp_tage.sv` | Component array, provider/altpred select, allocation-on-mispredict, periodic useful-bit decay | 250 |
| `g6lc_bp_statcor.sv` | Statistical corrector (small perceptron over provider confidence) — optional, `BPStatCorEn` | 150 |
| `g6lc_bp_loop.sv` | Loop predictor (trip-count) for `for`-style packet loops | 140 |
| `g6lc_bp_ittage.sv` | Indirect target predictor (tagged, target-storing) — the netfilter/`ndo_*` dispatch win | 260 |
| `g6lc_bp_top.sv` | Fabric wrapper: instantiates the enabled predictors, arbitrates, exposes today's `bht`/`btb` port shape | 200 |
| `g6lc_bp_ckpt.sv` | Prediction checkpoint FIFO (GHR + folded hist + RAS top pointer) indexed by branch tag; **prerequisite for U4/U5** | 160 |

**Config surface** (`core/include/config_pkg.sv`):

- extend `bp_type_t` (`config_pkg.sv:39-42`) with `GSHARE`, `TAGE_LITE`;
- add `BPTageTables`, `BPTageTableEntries[]`, `BPTageTagBits`, `BPGhistLen`, `BPLoopEn`,
  `BPIndirectEn`, `BPIndirectEntries`, `BPStatCorEn`, `BPCkptDepth`;
- `check_cfg` (`config_pkg.sv:446-463`) additions: each table size 0 or power-of-two;
  `BPGhistLen ≤ 64`; `BPTageTables ≤ 8`; `BPIndirectEn → BTBEntries > 0`;
  `BPCkptDepth ≥ NrScoreboardEntries` when `SpeculativeSb`.

**Timing.** Read is F0-indexed / F1-consumed, matching today's `btb_q`/`bht_q` registration at
`core/frontend/frontend.sv:463-465`. The new critical path is *tag compare → provider priority mux →
taken mux*. Mitigations, all mandatory: (a) **folded history registers** so index/tag hashes are one
XOR level, never a combinational fold of a 64-bit GHR; (b) provider priority encode is a **balanced
tree**, not a linear priority chain (`AGENTS-configuration.md` §2.1); (c) allocation/decay logic is
in the *update* path (F-independent), never in the read path; (d) if the provider mux does not close,
the fallback is a registered provider select with the base predictor supplying cycle-0 — a known,
documented 1-cycle-later override.

**Reset.** Async active-low only. **Do not reset large tables with a single-cycle broadcast** — the
existing `bht.sv:105-125` flop-array reset loop is acceptable at 1 K entries but does not scale to a
16 KiB TAGE. New tables use a **reset/flush FSM** that walks the array (one row per cycle, gated by
`flush_bp_i`), with a `bp_init_done` output that forces `valid=0` predictions while walking. This
removes a giant reset tree and keeps the arrays `tc_sram`-compatible.

**Bus / integration.** None new — the fabric sits entirely inside `frontend.sv`. `flush_bp_i`,
`debug_mode_i`, and the `resolved_branch_i` training path (`frontend.sv:324-341`) are reused verbatim.

**Synthesis constraints.** Tables ≥ 1 KiB instantiate through `tc_sram`
(`vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv`), never raw flops; SRAM chip-enables
are gated with `tc_clk_gating` so unused components burn no read energy on a base-predictor hit.
Give the fabric its own hierarchy level (`g6lc_bp_top`) for floorplanning next to the I$.

**DFT.** `testmode_i` threaded to every `tc_sram`/ICG; the reset FSM must be scan-observable
(no self-clearing state outside the scan chain).

**Observability.** New PMU events in `core/perf_counters.sv` (extend the `mhpmevent_q` case at
`perf_counters.sv:105-137`, which currently ends at `5'b10110` — the encoding space is nearly full,
so U8 must widen `mhpmevent` to 8 bits *before* U1 lands its events): TAGE provider hit, altpred
override, allocation failure, indirect hit/mispredict, loop-exit mispredict, checkpoint overflow.

**`.dts`.** None. Branch prediction is not device-tree visible
(`agents/guides/AGENTS-branch-prediction.md` §5).

**Verification.** Directed: a trace-driven predictor TB replaying branch traces (from `perf-model/`)
against a Python golden model; formal: *transparency* property — `assert property (bp_prediction
does not affect commit-visible state)` expressed as "for any predictor output, the RVFI retire
stream is identical to a `BPType=BHT` run" (equivalence by simulation), plus SVA on RAS
push/pop-only-when-consumed (`frontend.sv:261,290`) and checkpoint LIFO integrity.

**Risk.** Medium. Contained; the fallback is `BPType=BHT` which is bit-identical to today.

---

### U2 — Decoupled front-end (FTQ + FDIP instruction prefetch + loop buffer)

**Intent.** The kernel network path thrashes a 32 KiB I$. Decouple prediction from fetch with a
**fetch target queue**, then use the queue's run-ahead to **prefetch** I$ lines before the demand
fetch needs them (FDIP), and serve tight loops from a tiny **loop buffer** so the I$ can be fully
clock-gated. This is the single largest *front-end* perf/W lever for router firmware.

**New modules** (`core/frontend/`):

| Module | Responsibility | ~Size |
|---|---|---|
| `g6lc_ftq.sv` | Fetch-target queue: holds predicted fetch blocks between `g6lc_bp_top` and the I$ request port; flushable in one cycle | 220 |
| `g6lc_fdip.sv` | Walks FTQ entries ahead of demand fetch, emits **prefetch** requests; PMA-filtered | 200 |
| `g6lc_loop_buffer.sv` | Detects short backward-taken loops, captures the body, replays it with I$ requests suppressed | 240 |

**Config surface.** `FtqDepth` (0 = disabled → today's direct path), `FdipEn`, `FdipDistance`,
`LoopBufEn`, `LoopBufEntries`. `check_cfg`: `FdipEn → FtqDepth ≥ 2`; `LoopBufEntries` power-of-two;
`FtqDepth = 0 → FdipEn = 0 && LoopBufEn = 0`.

**Timing.** The FTQ *shortens* the critical path (prediction no longer feeds the I$ address mux
combinationally). The risk moves to the flush path: `is_mispredict` (`frontend.sv:308`) must clear
the FTQ, the FDIP walker, and the loop buffer in the *same* cycle it kills `kill_s1/kill_s2`
(`frontend.sv:318-321`). That is a fan-out, not a depth, problem — budget it explicitly.

**Reset.** Async active-low; FTQ pointers to 0; loop buffer invalid. No new clock, no new reset domain.

**Bus integration — the hard invariants.**
1. Prefetch requests use the **existing** `icache_dreq_o` port through a **strict-priority
   arbiter**: demand fetch always wins; a prefetch in flight is droppable, never blocking.
2. Prefetch addresses must pass `config_pkg::is_inside_execute_regions()`
   (`config_pkg.sv:481-493`) and must **never** target a non-idempotent region
   (`is_inside_nonidempotent_regions()`, `config_pkg.sv:472-479`) — speculatively reading MMIO is a
   functional bug, not a performance issue.
3. A prefetch must never raise an exception or a page-table walk that is architecturally visible;
   on TLB miss the prefetch is **dropped**, never queued.
4. `icache_dreq_o.spec` (`frontend.sv:330`) must be asserted for prefetch traffic.

**Synthesis.** Loop buffer is a small flop array (it is read every cycle — SRAM would cost more than
it saves); FTQ is a `cva6_fifo_v3`-style structure reusing the existing FIFO with `testmode_i`.

**Observability.** PMU: FTQ occupancy-full, prefetch issued / useful / late / dropped-by-PMA, loop
buffer hit rate, I$ clock-gated cycles. **Prefetch *accuracy* must be a counter** — an inaccurate
prefetcher is a pure power loss and you must be able to prove it is not.

**`.dts`.** None.

**Verification.** Directed tests for: mispredict during prefetch run-ahead; loop buffer + `fence.i`
(self-modifying code must invalidate the loop buffer — `#ext:zifencei`, see
`agents/spec/riscv-spec-I-4.1-zifencei.html`); prefetch into a PMA-illegal region must be suppressed
(formal property, and this is the single most important assertion in U2); debug-mode entry with a
full FTQ. Formal: FTQ never emits a fetch address that was not produced by the predictor for a
non-flushed path.

**Risk.** Medium-high — this is a structural change to `frontend.sv`, the one file U1 promised not to
touch. Mitigation: `FtqDepth=0` must synthesise to today's netlist exactly, and that equivalence is a
gate.

---

### U3 — Energy-first L1 memory (way prediction, MLP, CBO)

**Intent.** Two independent wins: (a) **cut L1 dynamic energy** with way prediction / phased access —
a pure power win with no architectural effect; (b) **raise MLP** so pointer-chasing route lookups
overlap, which is what actually limits router throughput.

**New modules.**

| Module | Location | Responsibility | ~Size |
|---|---|---|---|
| `g6lc_way_predictor.sv` | `core/cache_subsystem/` | PC/vaddr-indexed MRU way prediction; predicted-way-only data-array read, full lookup on miss | 190 |
| `g6lc_rrip_repl.sv` | `core/cache_subsystem/` | RRIP/DRRIP replacement policy (replaces pseudo-LRU) for scan-resistant `skb` streaming | 170 |

Plus configuration-level work: enable and size the **existing** HPDCACHE stride prefetcher
(`core/cache_subsystem/hpdcache/rtl/src/hwpf_stride/`) and its MSHR depth, rather than writing a new
prefetcher — reuse over invention.

**Config surface.** `WayPredEn`, `WayPredEntries`, `ReplPolicy` (`PLRU`/`RRIP`/`DRRIP`),
`HwPrefetchEn`, `HwPrefetchStreams`, `DcacheMshrDepth`. `check_cfg`: `WayPredEn → DcacheSetAssoc > 1`;
`HwPrefetchEn → DCacheType inside {HPDCACHE_*}`; MSHR depth ≤ `DCACHE_MAX_TX`.

**Timing.** Way prediction *shortens* the data-array path (fewer bitlines) but adds a **way-mispredict
replay** path — a 1-cycle penalty that must be handled by the existing LSU replay mechanism, not by a
new stall wire into the pipeline. The correctness invariant is absolute and formally checkable:
`way_pred_hit → returned_data == full_lookup_data`; a way mispredict may only cost cycles.

**Reset.** Way-predictor table cleared on reset and on `flush_i`; RRIP counters to the "distant"
re-reference value on reset.

**Bus.** No new ports. Prefetch traffic must respect PMA non-idempotent regions (same rule as U2) and
must be droppable under back-pressure.

**Synthesis.** Way-predictor table via `tc_sram` when > 256 entries; per-way data-array chip enables
gated with `tc_clk_gating` — **this gating is where the energy saving physically comes from**, so it
must be a functional ICG (`IS_FUNCTIONAL=1`), not a power-only one.

**Observability.** PMU: way-pred hit/miss, replay cycles, MSHR occupancy histogram bucket, prefetch
useful/useless, RRIP eviction of never-reused lines.

**`.dts`.** `i-cache-*` / `d-cache-*` CPU-node properties stay in sync with `Icache*`/`Dcache*`
(`agents/guides/AGENTS-l2l3-cache.md` §6). `riscv,cbom-block-size` / `riscv,cboz-block-size` land with
U7.

**Verification.** Formal equivalence of way-predicted vs. full lookup (the property above) is the
gate. Directed: way-mispredict under back-to-back loads; RRIP with a streaming `memcpy` that must not
evict the working set; prefetch + `fence`/`cbo.inval` interaction.

**Risk.** Medium; the way-prediction property makes it formally containable.

---

### U4 — Slice-out-of-order MLP engine  *(the efficient part of OoO)*

**Intent.** This is the **highest-efficiency-index upgrade in the program** and the reason full OoO
can wait. The Load Slice Core insight (Carlson et al., ISCA 2015; refined by Freeway) is that most of
OoO's benefit on memory-bound code comes from letting **address-generating instruction slices** run
ahead of the main instruction stream — *not* from full dynamic scheduling. Two in-order queues plus a
small backward-dependency table deliver ~50% of an OoO uplift for ~15% of its area and power.

For a router core chasing hash buckets and trie nodes, this is precisely the right trade.

**How it maps onto CVA6.** CVA6 already has the two halves of the mechanism: `core/scoreboard.sv`
tracks in-flight instructions with a `cancelled` bit and a `SpeculativeSb` mode
(`config_pkg.sv:286`), and `core/issue_read_operands.sv` already performs operand read/forwarding.
U4 adds a *steering* layer in front of them; it does **not** rewrite them.

**New modules** (`core/`):

| Module | Responsibility | ~Size |
|---|---|---|
| `g6lc_slice_ist.sv` | Instruction Slice Table: PC-indexed, learns (over iterations) which instructions belong to an address-generating backward slice | 200 |
| `g6lc_slice_steer.sv` | Decode/dispatch-time steering: slice instructions → A-queue, everything else → B-queue | 160 |
| `g6lc_slice_iq.sv` | One in-order issue queue instance (instantiated twice: A-IQ, B-IQ), with bypass/ready tracking | 240 |
| `g6lc_slice_rmt.sv` | Register-dependency tracking between the two queues (a *bypass* table, not a renamer) | 180 |

**Config surface.** `SliceOoOEn`, `SliceIstEntries`, `SliceAiqDepth`, `SliceBiqDepth`,
`SliceMaxRunahead`. `check_cfg`: `SliceOoOEn → SpeculativeSb && BPCkptDepth ≥ SliceAiqDepth`;
`SliceOoOEn → DCacheType inside {HPDCACHE_*}` (needs a non-blocking D$ to be worth anything);
`SliceOoOEn && OoOEn` is **illegal** (mutually exclusive, like `CvxifEn`/`EnableAccelerator` at
`core/cva6.sv:850-852`).

**Timing.** No new long path in EX: steering happens at decode/dispatch and is a table lookup +
2:1 demux. The queues are FIFOs, not CAMs — **there is no wakeup/select loop**, which is exactly why
this is cheap. That property must be preserved in review: *if anyone proposes an associative search
in the A-IQ, U4 has become U5 and must be re-costed.*

**Reset / recovery.** The IST is a hint structure: it may be cleared at any time with no correctness
effect (a very useful formal property). Queue flush reuses `core/controller.sv` fan-out; the
checkpoint FIFO from U1 (`g6lc_bp_ckpt.sv`) supplies frontend restore.

**Bus.** None new. Increased MLP raises AXI outstanding-transaction pressure → `MaxOutstandingStores`
and MSHR depth (U3) must be re-tuned together, and the AXI ID width checked
(`AGENTS-configuration.md` §3.2).

**Synthesis.** IST via `tc_sram` if > 256 entries; queues via the existing `cva6_fifo_v3.sv` pattern
with `testmode_i` (`core/cva6_fifo_v3.sv:29`).

**Observability.** PMU: A-IQ run-ahead distance histogram, slice-table hit rate, MLP achieved
(concurrent misses), B-IQ stall cycles. RVFI must still retire strictly in order — that is the
top-level correctness statement.

**`.dts`.** None (microarchitectural).

**Verification.** The correctness contract is that **U4 changes only timing, never results**. The
gate is an RVFI trace-equivalence run: identical retire stream with `SliceOoOEn` 0 vs 1 across the
full compliance regression. Formal: in-order retire; no store leaves `core/store_buffer.sv` before
commit; IST-clear at any cycle is behaviour-preserving.

**Risk.** High, but *bounded* — no renaming, no ROB, no associative wakeup, and a trivially provable
"hint-only" structure.

---

### U5 — Full multi-issue out-of-order  *(production path; config-gated)*

**Intent.** Maximum single-thread performance for the development/benchmark configuration. Included
because it was explicitly requested; sequenced last because its efficiency index (~0.75) is the only
one below 1.0 in the program, and because `AGENTS.md` §0.3 names over-scoped OoO as a 3–10× cost
driver. **Lean router profiles may keep `OoOEn = 0` (identity); server / high-perf production profiles enable `OoOEn = 1`.**

**Sub-phases** (each is its own change set, each individually verified — never one mega-commit):

| Phase | Content | New modules | Gate before proceeding |
|---|---|---|---|
| **U5.0** | Recovery hardening: precise rollback for loads, stores, CSR ops, CVXIF; branch checkpoint restore from U1 | — (hardens `core/scoreboard.sv`, `core/controller.sv`) | Formal: precise-trap property under arbitrary flush injection |
| **U5.1** | Rename + physical register file | `g6lc_rename.sv`, `g6lc_rat.sv` (+ checkpointed map), `g6lc_freelist.sv`, `g6lc_prf.sv` | Formal: RAT/free-list consistency across mispredict + exception |
| **U5.2** | Reorder buffer | `g6lc_rob.sv`, `g6lc_rob_alloc.sv`, `g6lc_rob_commit.sv` (evolve, do not delete, `core/scoreboard.sv`) | RVFI in-order retire under random stalls |
| **U5.3** | Issue queue + wakeup/select | `g6lc_iq.sv`, `cva6_wakeup.sv`, `cva6_select.sv` | **Synthesis gate: the wakeup→select→bypass loop is the frequency-limiting path.** If it misses target frequency, the design must pipeline select (2-cycle issue) rather than lower the clock |
| **U5.4** | Out-of-order LSU | `g6lc_lsq.sv`, `cva6_ldq.sv`, `cva6_stq.sv`, `g6lc_memdep.sv` (store-set memory-dependence predictor) | RVWMO litmus suite green; LR/SC reservation survives arbitrary misspeculation |
| **U5.5** | Widen to 2–3 issue | scale `NrIssuePorts`/`NrALUs`/`NrWbPorts` | Full regression + gate-level |

**Config surface.** `OoOEn`, `RobEntries`, `PrfEntries`, `IqEntries`, `LsqLoadEntries`,
`LsqStoreEntries`, `MemDepPredEn`, `OoORetireWidth`. `check_cfg`: `OoOEn → !SliceOoOEn`;
`PrfEntries > 32 + RobEntries` sanity; `OoOEn → SpeculativeSb`; `OoOEn → BPCkptDepth ≥ RobEntries`.
**`OoOEn = 0` must produce a netlist identical to the pre-U5 core** — that equivalence is a hard gate
on every U5 sub-phase.

**Timing.** Two known frequency killers, both must be planned for at U5.1: (1) the **wakeup/select
loop** (broadcast tag compare → grant → bypass) — mitigate with a small IQ, banked select, and a
pipelined-select fallback; (2) the **PRF read + bypass mux** — mitigate by floorplanning the PRF
adjacent to EX and by registering the bypass network. Both are called out in
`architecture/Architecture-research-todo-drafts.md` §2.7 and stay true.

**Power.** OoO's cost is mostly the CAMs and the PRF ports. Required mitigations for even the
production profile: clock-gate the IQ per entry, disable rename/ROB clocking entirely when
`OoOEn=0` is compiled in but idle, and keep the ROB a RAM-backed circular buffer rather than a
flop array.

**Observability.** PMU: ROB full, IQ full, rename stall, LSQ replay, memory-dependence mispredict,
mispredict penalty in cycles. RVFI must expose ROB index and physical tags
(`core/cva6_rvfi_probes.sv`).

**`.dts`.** None directly; but if `OoOEn` changes cache/timing-visible behaviour it must not alter
any DT property — verify.

**Risk. Very high.** Explicit statement for the record: U5 is a multi-quarter effort with its own
micro-architecture specification and verification plan, and it must not begin until U1, U3 and U4
are regression-green. It is included in this program as a *planned, gated capability*, not as work
to be attempted in the same pass as U1–U4.

---

### U6 — L2 cache, SMT2, and coherent dual core

**Intent.** Throughput scaling for multi-queue NIC steering, at better perf/W than widening a single
thread. Three phases, increasing risk.

**U6.0 — Memory-side L2 (single core).** Per `agents/guides/AGENTS-l2l3-cache.md` §4, this is an
*integration* task in `corev_apu/`, **not** an edit to any `core/cache_subsystem/` L1 file.
New modules under `corev_apu/l2_cache/`: `g6lc_l2_top.sv`, `g6lc_l2_tag.sv` (`tc_sram`),
`g6lc_l2_data.sv` (`tc_sram`), `g6lc_l2_mshr.sv`, `cva6_l2_axi_slave.sv`, `cva6_l2_axi_master.sv`.
Line size **must** equal `DcacheLineWidth` and 64 B (`Zic64b`). CBO operations (`#cmo`) must reach
the L2 end-to-end.
`.dts`: an `l2-cache` node with `cache-level = <2>`, `cache-block-size = <64>`, `cache-size`,
`cache-sets`, plus `next-level-cache = <&l2>` on the CPU node — values must equal the instantiated
parameters (this is the most common integration bug per the playbook §7).

**U6.1 — SMT2 (experimental).** Replicate architectural state, share the pipeline. Staged so the
first commit is behaviourally inert: **thread-tag the pipeline first** (`hart_id` threaded through
fetch → scoreboard → commit → CSR with `NrHarts=1` byte-identical), then replicate
(`g6lc_hart_state.sv`, banked `core/ariane_regfile_ff.sv`, banked CSRs, per-hart RAS/GHR in U1's
fabric), then add `g6lc_thread_select.sv` (switch-on-D$-miss policy first, round-robin second).
Config: `NrHarts` (SMT per core, ≤`CVA6_MAX_SMT_HARTS`), `SmtPolicy`, `SmtFetchQuantum`.
`check_cfg`: `NrHarts` in range; `NrHarts > 1 → RVS && MmuPresent`.

**U6.2 — Coherent multi-core (2–8, not dual-only).** `NrCores` ∈ {1..`CVA6_MAX_CORES`} (default
max 8; `` `define CVA6_MAX_CORES N ``). Coherence matches write-through D$: inclusive L2 +
**invalidation/snoop** into L1 (OpenPiton L15 path already accepts inv,
`core/cache_subsystem/wt_l15_adapter.sv`). RTL: `corev_apu/coherence/` —
`g6lc_snoop_filter.sv`, `g6lc_inval_bus.sv`, `g6lc_coherence_hub.sv` (N×AXI → L2, SF-guided inv,
AXI RR+starve, inv coalesce). CLINT/PLIC already take `NR_CORES`; set equal to `NrCores`.
`.dts`: N `cpu@` nodes, PLIC contexts, CLINT extents. See `architecture/remaining-upgrade-sequence.md`
for hypervisor (RVH) and AVX-like/`memcpy` (RVV vs CBO) sequencing after multi-core.

**Timing / CDC.** No new clock domains in any phase. If the L2 runs at a divided clock, that is a
**CDC boundary requiring explicit documentation and synchronizers** per `AGENTS-configuration.md`
§1 — do not introduce it implicitly.

**Verification.** U6.0: cache-coherency and CBO directed tests, DMA-vs-cache tests. U6.1/U6.2: RVWMO
litmus tests become the highest-risk item (`AGENTS-specs-coverage.md` already flags RVWMO as
"limited test"); add an SMP Linux boot to the build-platform suite.

**Risk.** U6.0 medium, U6.1 high, U6.2 high.

---

### U7 — RISC-V spec bundle for Linux/OpenWRT (with `.dts` accuracy)

**Intent.** The highest efficiency index in the program: a handful of small, ISA-visible features
that remove software overhead and unlock kernel functionality at near-zero area.

**Ground truth from the RTL** (verified, not assumed): `core/include/riscv_pkg.sv:131-136` declares
the `menvcfg` fields with explicit comments — `stce` *"not implemented - requires Sctc extension"*,
`pbmte` *"not implemented - requires Svpbmt extension"*, `cbze` *"not implemented - requires Zicboz
extension"*. `core/csr_regfile.sv:1695-1708` implements only `FIOM` and the CBIE/CBCFE bits. There is
**no `stimecmp`, no `scountovf`, no `Zawrs`, no `Svinval`, no `Smstateen`** anywhere in `core/`.

> **Traceability discrepancy to fix (standing discipline #5):**
> `architecture/Architecture-research-todo-drafts.md` §3.2 lists `Sstc` as *"Implemented (limited
> test)"*. The RTL says otherwise. `AGENTS-specs-to-impl.md` and `AGENTS-specs-coverage.md` must be
> corrected to `absent` before U7 starts, so the coverage docs stay honest.

| Priority | Extension | Why it matters for OpenWRT | RTL scope | `.dts` / discovery |
|---|---|---|---|---|
| **1** | **`Sstc`** (`stimecmp`, `vstimecmp`) | Removes an SBI `ecall` per timer reprogram — thousands/s under NAPI | 2 CSRs + comparator + STIP generation in `core/csr_regfile.sv`; `menvcfg.STCE` (`riscv_pkg.sv:796`). **Blocked on an SoC signal — see §4.U7.1** | `riscv,isa-extensions` += `sstc`; needs OpenSBI ≥ 1.0 and Linux `RISCV_SSTC` |
| **2** | **`Sscofpmf`** (`scountovf`, `mhpmeventN.OF`, LCOFI) | Makes `perf record/stat` work — directly serves core-debuggability | `core/perf_counters.sv` + `core/csr_regfile.sv` overflow/interrupt | `riscv,pmu` node with `riscv,event-to-mhpmevent` mapping — must match the U8 event encoding exactly |
| **3** | **`Zicboz`** (+ finish `Zicbom`, add `Zicbop`) | `cbo.zero` for `skb`/page zeroing; `prefetch.*` hints pair with U3 | Decoder + LSU op; `menvcfg.CBZE` bit already reserved | `riscv,cboz-block-size = <64>`, `riscv,cbom-block-size = <64>` |
| **4** | **`Svpbmt`** | Correct device-memory typing for MMU-mapped NIC/PHY registers | PTE bits 62:61 in `core/cva6_mmu/`, `menvcfg.PBMTE` | `riscv,isa-extensions` += `svpbmt` |
| **5** | **`Zawrs`** (`wrs.nto`/`wrs.sto`) | Low-power spin-wait; pairs with U6 SMP | Decoder + a stall/wake path off the reservation | `riscv,isa-extensions` += `zawrs` |
| **6** | **`Zihintpause`** | Trivial; used by kernel spin loops | Decode `PAUSE` as a hinted `fence` | `zihintpause` |
| **7** | **`Smstateen`** | Required once new state (`vstimecmp`, CVXIF state) exists | `mstateen0/hstateen0` CSRs | `smstateen` |
| **8** | **`Svinval`** | Fine-grained TLB shootdown; matters only after U6.2 | `sinval.vma` etc. in `core/cva6_mmu/` | `svinval` |

#### U7.1 — `Sstc` has an SoC-integration prerequisite (verified, not assumed)

`Sstc` cannot be implemented inside `core/` alone. The comparison `time >= stimecmp` needs the
**`mtime` value**, and the core does not have it:

- `core/cva6.sv:332` receives only `time_irq_i` — a level from the CLINT, not a counter value.
- `riscv::CSR_TIME` is declared in `core/include/riscv_pkg.sv:664` but **`csr_regfile.sv` never
  decodes it**; `rdtime` traps and is emulated by M-mode/OpenSBI today.
- `mtime`/`mtimecmp` live in `corev_apu/clint/clint.sv`.

Two routes, and the choice must be made before the RTL pass starts:

| Route | Change | Cost | Notes |
|---|---|---|---|
| **A — bring `mtime` into the core** (recommended, and what Rocket/other cores do) | New `input logic [63:0] rtc_time_i` on `core/cva6.sv`, threaded to `csr_regfile`; driven from `corev_apu/clint/clint.sv` through `corev_apu/src/ariane.sv`, the FPGA/Altera tops and `corev_apu/tb/ariane_testharness.sv` | One new 64-bit top-level port + ~6 integration files | Also finally enables a real `rdtime`, removing the SBI trap on **every** `rdtime` — a second, independent Linux win |
| **B — compare in the CLINT** | `stimecmp` still a CSR in the hart, but exported to the CLINT which returns a second interrupt line | Avoids the 64-bit port but adds a CSR-value output + a new IRQ line, and splits architectural state across the SoC boundary | Rejected unless the 64-bit port is unacceptable for the pad/floorplan budget |

Route A must be config-gated (`Sstc` in `cva6_cfg_t`) so targets without a CLINT-sourced time value
tie the port off and elaborate unchanged. Timing note: `time >= stimecmp` is a 64-bit comparator
feeding an interrupt-pending bit — not on a fetch/execute path, but it must be **registered**, never
combinationally forwarded into the trap-taking decision.

**Already present — do not re-implement:** `RVB` (bitmanip), `ZKN` (scalar crypto incl. `Zbkc`
clmul for CRC32), `RVZiCbom`, `Svnapot` (`SvnapotEn`), `Zicntr`/`Zihpm`, Sv39, PMP.

**`.dts` accuracy procedure.** Every row above is device-tree visible, so
`AGENTS-dts-validation.md` applies: run `build-platform/scripts/fetch-linux-dts.{sh,ps1}`, diff the
proposed node/property against the upstream Linux binding, and update the cross-reference row. The
`riscv,isa` string, `riscv,isa-extensions` list, `misa`, and the config package must agree —
three-way, every time.

**Verification.** Compliance/ACT tests per extension; a Linux boot with `perf stat` producing
non-zero counters is the acceptance test for `Sscofpmf`; an OpenSBI boot log showing `sstc` detected
is the acceptance test for `Sstc`.

**Risk.** Low-to-medium each; these are small, well-specified, individually testable changes — ideal
first RTL passes.

---

### U8 — Observability, debug, and power management

**Intent.** Make the core measurable and make it idle cheaply. This upgrade is what makes the other
seven *provable*, and it is what "software engineers who can debug the core" actually experience.

**U8ᵃ (lands first, before U1).**
- **Widen the PMU event encoding.** `core/perf_counters.sv:105-137` uses a 5-bit `mhpmevent_q` and
  already consumes up to `5'b10110`. The program adds ≥ 25 new events; widen to 8 bits and
  restructure the mux as a *grouped* selector (front-end / cache / issue / thread groups) so the
  case statement does not become a 256-way flat mux on a timing path.
- Add the U1–U6 event set incrementally, each event landing with its feature.
- Publish the event numbering in a single table that the `riscv,pmu` DT node (U7) mirrors.

**U8ᵇ (power).**
- `cva6_clk_gate_ctrl.sv`: hierarchical, per-unit functional clock gating (FPU, MULT/DIV, predictor
  tables, L2 banks, idle hart in SMT) built strictly on `tc_clk_gating`
  (`vendor/pulp-platform/tech_cells_generic/src/rtl/tc_clk.sv:31-49`) with `testmode_i` bypass — the
  *only* sanctioned latch in the design lives there and no new one may appear.
- WFI deepening: retention-friendly quiescence, `Zawrs`-aware idle (U7), and a documented wake
  latency.
- `cva6_activity_monitor.sv`: toggle/activity counters for FPGA-based perf/W bring-up.

**U8ᶜ (debug).** Keep `core/trigger_module.sv` triggers functional across every new speculative
structure; extend `core/cva6_rvfi_probes.sv` for FTQ/slice/ROB state; ensure a halt request drains
prefetch and loop-buffer state deterministically.

**Config surface.** `PerfEventWidth`, `PerfCounterNum`, `ClkGateGranularity`, `ActivityMonEn`,
`WfiRetentionEn`.

**`.dts`.** The `riscv,pmu` node (with `riscv,event-to-mhpmevent` / `riscv,event-to-mhpmcounters`)
is the deliverable that makes Linux `perf` work; it must be generated from the same table as the RTL
encoding, never hand-maintained twice.

**Risk.** Low. Highest ratio of developer value to engineering cost in the program.

---

## 5. Per-change verification gate

`AGENTS.md` §0.2 plus the user requirement that **lint, formal, simulation and synthesis run after
every consecutive change**. The gate below is mandatory per commit, not per upgrade.

| Stage | Tool | Command (target) | Pass criterion |
|---|---|---|---|
| **Lint** | Verilator `--lint-only` | `cva6-build verify --lint` | **No new warnings** vs. the per-target baseline in `.config.ts` (`verify.warningBaseline`) |
| **Elab** | `slang` (strict full SystemVerilog) | same command | Clean elaboration for **every** target in `verify.targets`, minimal configs included |
| **Formal** | SymbiYosys | `cva6-build verify --formal` | Each upgrade's named properties proven, or bounded to a stated depth |
| **Sim** | Verilator + Spike, `verif/regress` | `cva6-build verify --sim` | Compliance regression green; RVFI trace equivalence where an upgrade claims transparency |
| **Synth** | Yosys + `yosys-slang` (smoke); DC for sign-off | `cva6-build verify --synth` | Elaborates to generic gates, `check -assert` clean; no new inferred latch |

`cva6-build verify` with no flag runs every stage enabled in `verify.stages`. Each commit message
carries the `AGENTS-configuration.md` §6.3 **SoC impact** block, filled in.

### 5.1 Gate status (measured 2026-07-24)

The gate is **live**. OSS CAD Suite 2026-07-24 is extracted into the gitignored
`build-platform/workspace/tooling/oss-cad-suite/`; Verilator, slang, Yosys+yosys-slang, SymbiYosys
and Icarus all resolve.

| Stage | `cv64a6_imafdc_sv39` | `cv32a65x` | Wall time |
|---|---|---|---|
| Lint (Verilator) | 482 warnings — **baseline** | 138 warnings — **baseline** | ~5 s / ~3 s |
| Elab (slang) | clean | clean | <0.5 s |
| Synth (Yosys+slang) | pass, 31 warnings | pass, 5 warnings | ~88 s / ~26 s |
| Formal | no tasks yet | — | — |
| Sim | skipped — no `bash`/riscv-gcc/spike on this host | skipped | — |

Three things had to be fixed to get there, all recorded so they are not rediscovered:

1. **Nested submodules were missing.** `core/cvfpu/src/fpu_div_sqrt_mvp` and
   `core/cvfpu/src/common_cells` were uninitialised, which blocks *any* full-core elaboration.
2. **`core/Flist.cva6` nesting is not portable.** Verilator does not treat a Windows drive-letter
   path inside a nested `-F` command file as absolute, so every hpdcache source resolved to a
   doubled path. The platform now flattens the manifest itself (one flat command file, absolute
   POSIX paths) rather than depending on each tool's `-F` semantics.
3. **An absolute zero-warning rule is not achievable** on this codebase — the vendored cvfpu and
   cache IP carry ~480 accepted warnings (WIDTHEXPAND 207, ASCRANGE 101, WIDTHTRUNC 72, SELRANGE 61,
   LATCH 38). The gate therefore enforces **no regression against a recorded baseline**, and the
   baseline is ratcheted down whenever a change removes warnings.

> **Honest caveat:** the sim stage is the one gate stage still unproven on this host. It needs
> `bash` (Git-Bash), a RISC-V GCC and Spike. Until it runs, no upgrade may claim a measured IPC or
> perf/W number — only that it lints, elaborates and synthesises.

---

## 6. Open decisions (needed before RTL starts)

1. **Fill `AGENTS-configuration.md` §6.1** — frequency, corner, voltage, power budget, node, SRAM
   latency. Without these, no timing or power claim in this document is checkable. **Still open, and
   it is the single largest blocker to calling any upgrade "done" rather than "lints and synthesises".**
2. ~~Toolchain provisioning~~ — **done**, see §5.1.
3. **Confirm the shipping vs. experimental split** — proposal: shipping router profile
   (`cv64a6_router_config_pkg.sv`) = U1, U2, U3, U4, U6.0, U7, U8 with `OoOEn=0`; experimental
   profile (`cv64a6_router_ooo_config_pkg.sv`) = adds U5 and U6.1/U6.2.
4. ~~Correct the `Sstc` coverage discrepancy~~ — **done**: `Sstc` and `Sscofpmf` are now recorded as
   `absent` in `AGENTS-specs-to-impl.md`, `AGENTS-specs-coverage.md` and
   `architecture/Architecture-research-todo-drafts.md` §3.2.
5. ~~Widen the PMU event field (U8ᵃ) before U1~~ — **done**: `mhpmeventN` is an 8-bit WARL selector
   split group/index (`core/include/ariane_pkg.sv`), group 0 bit-identical to the legacy encoding,
   groups 1–7 reserved for U1–U6 (`core/perf_counters.sv`).
6. **Choose the `Sstc` integration route (A or B, §4.U7.1)** — route A adds a 64-bit `mtime` input to
   `core/cva6.sv` and touches ~6 SoC files, but also unlocks a real in-core `rdtime`. This decision
   gates the U7ᵃ RTL pass.
7. **Get the sim stage running** — `bash` + RISC-V GCC + Spike on this host, so the gate can prove
   behaviour and not just structure.

---

## 7. Relationship to the rest of the repo

- Domain playbooks: `agents/guides/AGENTS-branch-prediction.md`, `-speculation.md`, `-l2l3-cache.md`,
  `-ram-memory.md`, `-soc-readiness.md`.
- Extension points: `architecture/branch-prediction/`, `speculative-execution/`, `multi-threading/`,
  `multi-core/`, `l2-l3-cache/`, `spec-extensions/`, `out-of-order/`.
- Prior research: `architecture/Architecture-research-todo-drafts.md` (the M1-class / OoO roadmap
  this program refines and re-prioritises for a power-bound router target).
- Traceability: `AGENTS-specs-to-impl.md`, `AGENTS-specs-to-tests.md`, `AGENTS-specs-coverage.md`.
- Device tree: `AGENTS-dts-validation.md`.
- Build/test/synthesis orchestration: `build-platform/`.
