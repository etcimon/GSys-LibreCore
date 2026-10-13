# Guide: OoO core + L2/L3 — measured bottleneck map and the aggregated update plan (T26)

Evaluation of the `g6lc64_ooo_server` implementation (4 cores × SMT2, 4-issue OoO with FP,
HPDCACHE WT L1, write-update L2, inclusive L3, `COH_FILTERED` hub) for cycle and area levers,
done the way `AGENTS-verilator-performance.md` §7 demands: **instrument, measure, then infer the
large updates from the measurement** — not from the shape of the structures. Read `../../AGENTS.md`
first; the OoO architecture of record is `core/ooo/AGENTS-ooo-contract.md` / `AGENTS-ooo-plan.md`,
the cache hierarchy `AGENTS-l2l3-cache.md`.

## 1. Instruments (what was added, where, how to run)

| instrument | where | output | run |
|---|---|---|---|
| **Retire-stall census** `+stall_census` | `core/cva6.sv` `gen_stall_census` (sim-only, `OoOEn`) | per head hart: retired by unit class, `empty` (scoreboard empty = frontend), `notissued` (head still in the IQ: operands/port), `inflight` (head issued, result pending — memory/FP/MUL latency), `held` (valid but not retired: store buffer, exception, CSR, halt); memory: L1 misses issued, dcache requests/grants, MSHR occupancy histogram, `mshr_full`/`rtab_full`/`wbuf_full`/`ldbuf_full` cycles; `[stall-census] periodic` every 2 M cycles and `final` | any model, `+stall_census` (allowlisted in `g6lc_tb.cpp`) |
| **Hub AW-hold split** | `corev_apu/tb/ariane_testharness.sv` `[mc_hub]` (hierarchical reads of `gen_hub.i_hub.gen_cluster`) | `aw_fire`/`ar_fire` counts; `hub_aw_hold_other` split into `wbusy` (W of the previous AW still in flight), `inv_adm`, `mem_nready`, `rr_loss` | multi-core models, printed at final with `[mc_cache]` |
| DRAM latency | `-GDramLatency=N` (compile-time; `corev_apu/tb/g6lc_tb_dram_latency.sv`: pipelined, holds only the first R beat / the B, Depth 32) | `dram_latency=N` in `[mc_cache]` | a second model build per latency |
| Per-module area | yosys `read_slang --best-effort-hierarchy … ; proc; opt_clean; stat` on `cva6` (`t21/q-synth-stat.sh`, `q-synth-stat4.sh` parser) | local generic cells per module + inclusive per instance | ≈ 50 min on the builder |

Existing probes used alongside: `+smt_stats` (`[smt-drain]`), `[ckpt] final` (branch resolution and
mispredicts), `[mc_cache]` (L2/L3/hub counters), `[hpd-phantom]`/`[hpd-zombie]`.

Models: `ooocoh-t26-ooo-census-build2` (`g6lc64_ooo`, 1 thread), `ooocoh-t26-server-census-mt4-build3`
(server, `DramLatency=0`), `ooocoh-t26-server-census-lat120-mt4-build2` (server, `DramLatency=120`);
fork `453031b66`, split `.vlt`, `-O2`, no PGO (measurement models). Workloads: the T21i strict 8-hart
OpenSBI firmware (`fw_payload.elf`), first 2 M cycles with `+rvfi_notrace`; the single-core OoO
probes. The full-boot census on the latency-0 model is detached as
`prof-census-ooocoh-t26-server-census-mt4-build3-full` (≈ 3 h; its `[stall-census] final` lines are
the full-boot attribution — append them here when harvested).

## 2. What was measured

### 2.1 Boot core, first 2 M cycles of the OpenSBI boot (core 0 = boot hart 0 + sibling hart 1)

| | `DramLatency=0` | `DramLatency=120` |
|---|---:|---:|
| hart 0 retired / IPC | 802,074 / **0.401** | 200,310 / **0.100** |
| hart 0 `empty` (frontend) cycles | 98,459 (flush 9,259) | **995,997** (50 % of the window) |
| hart 0 `inflight ld` (head = load executing) | 147,602 | **525,969** |
| hart 0 `inflight st` / `held st_sb` | 23,538 / 0 | 8,303 / 1,319 |
| hart 0 `notissued` (operands) | 18,732 | 6,357 |
| L1D misses issued / dcache req → grant | 417 / 297,800 → 294,774 | 238 / 90,797 → **76,597** |
| `rtab_full` / `wbuf_full` cycles | 287 / 0 | **15,687 / 40,366** |
| MSHR occupancy ≥ 2 (cycles) | 171 | 1,201 |
| hart 1 (sibling, spinning before HSM parks it) | 542 k retired, IPC 0.27, head in `MUL` 277 k cycles | 485 k, 0.27 |
| `[smt-drain]` switches / drain cycles | 18,518 / **795,123** (`wait_sb` 735 k) | 5,334 / **1,652,339** (`wait_st` 975 k, max 2,906) |
| L2 hit / miss / bypass(writes) | 535 / 249 / 42,295 | 384 / 189 / 12,583 |
| hub `aw_fire` / `ar_fire` | 42,263 / 816 | 12,549 / 607 |
| hub `aw_hold_other` → `wbusy` | 78,283 → **77,873** | 893,114 → **892,708** (45 % of the window) |
| branch / ret / jmp mispredicts (`[ckpt]`) | 1,494 / 15 / 599 of 156 k / 11 k / 17 k resolves | 458 / 8 / 116 |

Full 33 M-cycle boot (`ooocoh-t25-server-hpgo-osbi-48M`, latency 0, from the existing probes):
hart 0 retired 29.97 M in 32.87 M cycles (IPC 0.91 once the sibling is parked); 63 k mispredicts
in 4.46 M resolves (br 1.3 %, ret 0.85 %, jmp 2.4 %, ≈ 4 % of cycles at a 20-cycle penalty);
`[smt-drain]` 942 k cycles (2.9 %, 89 % of it `wait_sb`); `[mc_cache]` l2_bypass **1,647,904**
writes for 9,733 cacheable reads, `l3_wupd 1,603,034` (every store reaches DRAM),
`hub_aw_hold_other` **2,931,954** cycles (9 %), `hub_aw_sc_collide` 1.74 M.

### 2.2 Single core `g6lc64_ooo` (WT L1), the OoO probes

| probe | cycles | IPC | dominant head state |
|---|---:|---:|---|
| FP stage 1 (fdiv/fsqrt + mispredicted branches) | 2,654 | 0.59 | `inflight fpu` 1,011 (the iterative DIVSQRT unit, by design), `empty` 346 |
| `ooo_mem_dep` | 1,059 | 0.42 | `empty` 372, `inflight ld` 119 |
| `ooo_ilp_chain` | 1,153 | 0.45 | `empty` 390, `inflight ld` 113 |
| `ooo_wrongpath_replay` | 10,651 | 0.31 | `inflight mul` 3,619 (serial divider), `inflight ld` 1,612, `held st_sb` 678, `empty` 840 |

The short probes are startup-dominated (`empty` = the first I$ fills); they qualify the probe, they
do not rank levers.

### 2.3 Area — `g6lc64_ooo_server` core, yosys generic cells (306,676 local; `stat` before mapping,
so control-heavy logic is over-weighted against wide datapaths — proportions, not µm²)

| module | cells | share | shape |
|---|---:|---:|---|
| `g6lc_iq` (IQ, 48 entries) | **68,729** | 22.4 % | `$logic_and` 18,690, `$mux` 21,326, `$lt/le/ge/gt` 7,081, `$eq` 6,600 — the 48×64 `ooo_age_older` store-age gate, the 48×48 age matrix ×4 ports, the 48×4-WB×5-tag wake CAM |
| `scoreboard` (64-entry in-order ring kept as the OoO ROB) | 28,342 | 9.2 % | `$mux` 22,234: the sbe bundle muxes |
| `g6lc_rename` | 28,099 | 9.2 % | 4,800 flops: map tables + checkpoints |
| `g6lc_lsq` | 21,324 | 7.0 % | `$mux` 10,710, `$eq` 1,456 |
| `issue_read_operands` | 15,680 | 5.1 % | `$eq` 3,495: RAW checkers ×4 ports |
| `store_buffer` | 12,839 | 4.2 % | 16-entry CAM |
| `cva6_tlb` ×2 (32-entry fully associative I/D) | 22,290 | 7.3 % | |
| `decoder` ×4 | 14,044 | 4.6 % | |
| `hpdcache_ctrl_pe` | 10,726 | 3.5 % | the HPDCACHE pipeline priority encoder |
| `aes` | 9,109 | 3.0 % | Zk unit (config) |
| `g6lc_rob` | 7,645 | 2.5 % | |
| `csr_regfile` ×2 (banked per hart) | 7,100 | 2.3 % | |
| TAGE (3 tables + base + ckpt) | ≈ 8,300 | 2.7 % | |

The OoO backend (IQ + scoreboard + rename + LSQ + ROB + read-operands + store buffer) is
**≈ 60 %** of the core's generic cells; the whole frontend/predictor ≈ 4 %.

## 3. The mechanisms behind the numbers (read in the source, not guessed)

1. **The store path is write-through to DRAM with a store-MLP cap of 4, through single-transaction
   FSMs.** HPDCACHE WT → wbuf (16) → hub → L2 → L3 → DRAM; `L2WriteUpdateEn` merges the write into a
   resident line but still forwards it (`l2_wupd == l3_wupd == l2_bypass` ≈ every store). The hub
   admits one write at a time per W phase (`aw_grant` requires `!w_busy_q`,
   `corev_apu/coherence/g6lc_coherence_hub.sv:586`, "W has no id") and holds at most
   `CohMaxOutstanding = 4` AW slots until B; the L2 and L3 (`corev_apu/l2_cache/g6lc_l2_top.sv`,
   one `state_q` per engine) accept W only in `S_BYPASS_W` after their own downstream AW handshake, and
   their posted-write trackers hold 4 entries until the DRAM B. With B at 0 cycles this costs
   1.8 hold cycles per store (`wbusy` 77,873 / 42,263 AWs); with B at 120 cycles it is **71 cycles
   per store** (892,708 / 12,549): the cluster sustains one store per ≈ 160 cycles, the wbuf fills
   (40 k cycles), loads behind pending stores replay (`rtab_full` 15.7 k, `dc_req − dc_gnt` 14 k),
   and a drained SMT switch waits for the stores to leave (`wait_st` 975 k). The IPC collapse from
   0.40 to 0.10 is this path first, the I-fetch path second.
2. **Instruction fetch has no latency tolerance beyond `FdipDistance=2`.** `empty` is 50 % of the
   latency-120 window; the I$ misses straight to DRAM (the L2 prefetcher is off, the "server
   prefetcher" sits *below* the L3 — `g6lc_cluster.sv:700`, `up_req_i(l3_mst_req)` — so nothing it
   fetches is installed anywhere a core can hit).
3. **The L1D is not the limiter in this phase**: 417 misses in 2 M cycles, MSHR occupancy almost
   never above 1, `mshr_full` 0. The 32-entry MSHR (16 sets × 2 ways) and the 4-entry replay table
   only matter once the store path is unblocked (then `rtab_full` is the next signal to watch).
4. **The drained SMT handoff multiplies memory stalls.** Every quantum switch (`SmtFetchQuantum
   128`) drains the scoreboard (`wait_sb`) and the store path (`wait_st`); while the sibling spins
   before HSM parks it, 40 % (latency 0) to 83 % (latency 120) of the early window is drain; over the
   full boot 2.9 %.
5. **Branch prediction is not a first-order item** (≈ 4 % of the full boot) — T21–T23 already took
   it there; the T23 base-row hash and ITTAGE/GHR experiments stay recorded as not adopted.
6. **IQ area is dominated by O(DEPTH × ROB) and O(DEPTH²) compare arrays** that a sequence-number
   or a ready-bit formulation makes O(DEPTH): the store-age gate evaluates
   `ooo_age_older(s, trans_id, commit_ptr)` for 48 entries × 64 stores every cycle
   (`core/ooo/g6lc_iq.sv:241`); the wake-up compares 48 × 4 WB ports × 5 tags per cycle
   (`g6lc_iq.sv:127`); the oldest-first grant transposes a 48×48 matrix per port.

## 4. The aggregated updates, ranked by the measurement

Each row: the change, the mechanism it removes, the number that predicts its ceiling, the cost, the
verification it must carry. **Order matters**: 1–3 are the memory-side updates without which the
backend levers measure nothing under realistic DRAM latency; 4 is independent; 5–6 are area.

| # | update | removes | ceiling from §2 | cost / risk | verification |
|---|---|---|---|---|---|
| 1 | **Write-back L2** (`L2WriteBackEn`): dirty bit per line, write-allocate on the WT stream, B returned at the L2 on tracker admission, eviction writeback engine, CMO/ATOP/exclusive on dirty lines, L3 stays inclusive of L2 tags | the DRAM B from the store path; ≈ 10× the DRAM write traffic (1.6 M store writes → L2 evictions); half the hub traffic | at latency 120: `empty`-independent part of the 0.40 → 0.10 collapse (`wbusy` 45 %, `inflight ld` 26 %, drain 83 %) — the order of **2–3× on the boot core** under real latency; ≈ 0 at latency 0 | the largest change: new engine, coherence proof that a dirty L2 line still obeys the hub's write-update/inval rules (ordering rules 1–6 of `architecture/l2-l3-cache/ewt-caching.md`), `tc_sram` dirty array; weeks | bounded formal on the dirty FSM (`core/ooo/formal` style), the three `COH_FILTERED` directed tests, `mc_l3_evict_inclusion`, the strict boot at latency 0 **and 120**, anchors byte-identical at latency 0 |
| 1a | **Interim: early B + deep trackers** — L2 returns B when the posted write is admitted (tracker ≥ 32, `CohMaxOutstanding` ≥ 16, hub slots freed on the L2's B), the DRAM B only retires the tracker | the B latency from the store path without dirty state | same ceiling for throughput; traffic unchanged | small; needs the same-line read-after-posted-write hold (`line_hold`) proven for the longer window | directed `mc_l2_write_read`, the ordering formal, boot at 120 |
| 2 | **Hub W-order FIFO**: AW accepted without `w_busy`; a per-slot FIFO of W owners keeps W beats in AW order to the L2 | 1.8 cycles per store at latency 0, the W serialisation across cores | `hub_aw_hold_other` 78 k of 2 M (4 %) at latency 0; after #1 the residual | one FIFO + the W mux; `coh_split_conflict` assertion already guards W/AW ownership | hub formal (`g6lc_coherence_hub` bounded proofs), the coherence directed set |
| 3 | **Non-blocking L2/L3 engine**: split the single `state_q` into a read pipeline (tag → hit/serve) and a write path (tracker-driven), so a blocked write never holds reads and a miss never holds writes; keep the MSHR/fill side | the FSM coupling that turns the store cap into a load stall | `inflight ld` 526 k vs 148 k between the two latencies, net of #1 | the L2 is 2.2 k lines with the T8–T10 ordering rules in one case statement; do it after #1 so the write path is simpler | the T8/T9 directed set, `l2_trace` equivalence review, synth smoke of `g6lc_l2_top_lint_top` |
| 4 | **Instruction-side latency tolerance**: `FdipDistance` 2 → 8 (measure), L2 stream prefetch trained on I-side misses (`L2PrefetchEn=1`, the T9h/T10b prefetcher exists, +0.3 % cost measured), move/duplicate the server prefetcher **above** the L3 so its fills land in the LLC, or delete it | `empty` 50 % at latency 120 | up to the `empty` share once #1 lifts the store path (the I-fetch misses are the 995 k) | config + the T9h prefetcher; the below-L3 prefetcher is dead weight today | `[stall-census] empty` at 120 before/after; boot cycle count; `l2_pf_useful` |
| 5 | **SMT policy without the drain tax**: no quantum switch while the sibling retires nothing useful (spin/wfi hint — `switch_on_starve` exists), quantum 128 → 512 measured, and long-term an interleaved (non-drained) handoff | `drain_cyc` 795 k / 1.65 M of the early 2 M window, 942 k of the full boot | 2.9 % of the boot at latency 0, far more at 120 until #1 lands | policy knobs are cheap; interleaving is the T10/T13 contract rewrite | `+smt_stats` drain census, the mixed-residency battery |
| 6 | **IQ area: O(DEPTH) formulations** — store sequence numbers (a load records the youngest older store's SSN at dispatch; gate = `oldest_unresolved_ssn ≤ my_ssn`, one compare per entry), ready-bit table for wake-up (PRF-indexed bits set at writeback, two reads per entry instead of 20 tag compares), age matrix kept | 48×64 `ooo_age_older` (≈ 12 k compare cells), the 48×20 CAM | IQ 68.7 k → an estimated ≈ 35 k generic cells (−11 % core); timing: the gate's 64-wide OR-of-compares becomes one compare | moderate; the SSN wraps with the ring — same circular-compare care as `ooo_age_older`; IPC-neutral by construction | `tb_g6lc_iq_store_age` leaf (positive/negative/mutation), IQ bounded formal, the probe battery cycle-identical |
| 7 | **Scoreboard/ROB consolidation**: the 64-entry in-order `scoreboard` (28 k) and `g6lc_rob` (7.6 k) both exist on the OoO path; a single ROB with the sbe bundle stored once | duplicated state and the `$mux` 22 k read network | up to ≈ 20–25 k cells (−7 %) | architectural (the contract file names the scoreboard ring as the window); the T9f/T21 recovery semantics live in it | the full OoO battery; formal of the recovery marks |
| 8 | **TLB geometry**: 32-entry fully associative I/D TLBs (22 k cells) with a 128-entry shared L2 TLB already present → 16-entry L1 TLBs | ≈ 11 k cells (−3.6 %) | small IPC risk: the census does not yet count TLB misses — add it first | config + the `SharedTlbDepth` path | the MMU directed set, boot cycles |
| 9 | **`aes` optional on the server package** (9.1 k, 3 %) | | | config only (Zk discovery string) | ISA string + Linux `/proc/cpuinfo` alignment |

Not levers (measured): the L1D MSHR depth and replay table at latency 0; branch prediction beyond
T21–T23; the HPDCACHE software-programmed hardware prefetchers (nothing programs them during boot —
they are a Linux-driver feature, not a boot lever).

## 5. Instrumentation still owed before 1/3/4 are built

- `empty` split: I$ miss outstanding vs redirect/decode bubble (`i_frontend` icache miss valid) —
  decides between #4's prefetch distance and a wider decode/FTQ.
- Dispatch stall split: IQ full vs ROB full vs LSQ full vs rename free-list empty (`i_iq.full_o`,
  `i_rob`, `i_lsq`, `i_rename`) — decides the IQ 48 → 32 question of #6 and LSQ sizing.
- TLB miss count and PTW cycles at the head (#8).
- L2/L3 engine occupancy: cycles in each `state_q` and the write-tracker occupancy histogram
  (`g6lc_l2_top` `[l2_trace]` has the events; a census is cheaper) — the before/after for #1/#3.
- The full-boot census at latency 0 (detached, see §1) and a 10 M-cycle census at latency 120 once
  #1a or #1 exists.

## 6. Status

Instruments landed and lint-clean on `g6lc64_ooo_server` and `g6lc64_ooo` (`stall_census`,
`[mc_hub]`); measurements of §2 recorded with their models; no RTL of §4 built yet. The next
implementation step is #1a (early B + deep trackers) because it is small, it is the measurement that
tells whether #1's full write-back L2 is needed for the boot or only for DRAM traffic, and every
other memory lever is invisible until the store path is unblocked.
