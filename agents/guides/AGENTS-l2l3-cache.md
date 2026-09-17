# Guide: L2/L3 Cache (and the L1 subsystem)

Feature-addition playbook for the cache hierarchy. Read `../../AGENTS.md` first. Spec summaries live
in `../spec/` (see `../spec/INDEX.md`).

## Table of contents
1. Spec grounding
2. Code map (`file:line`)
3. Config knobs
4. The L2/L3 reality (integration, not in-core edit)
5. Feature-addition playbook
6. `.dts` linkage
7. Invariants and pitfalls

## 1. Spec grounding
Caches are microarchitectural but bounded by normative memory behavior: `specs/riscv-spec.html#memorymodel`
(3.1 RVWMO — the ordering any cache must preserve), `#pma` (3.6 — cacheable / coherent / idempotent
attributes per region), `#ext:zic64b` (4.15 — 64-byte naturally-aligned blocks), `#cmo` (4.20 —
CBO.clean/flush/inval/zero), the I/D coherence extension `Ziccid` (`#_ziccid_extension_for_instructiondata_coherence_and_consistency`),
`Svpbmt` (`#ext:svpbmt`, page-based memory types), and `Ssqosid` (`#ssqosid`, cache QoS).
Sub-files: `../spec/riscv-spec-I-3.1-rvwmo.html`, `-II-3.6-pma.html`, `-I-4.15-zic64b.html`, `-I-4.20-cmo.html`.

## 2. Code map
- L1 instruction cache: `core/cache_subsystem/g6lc_icache.sv` (+ `cva6_icache_axi_wrapper.sv`).
- L1 data cache (write-through, OpenPiton-compatible): `core/cache_subsystem/wt_dcache.sv` and `wt_dcache_{ctrl,mem,missunit,wbuffer}.sv`.
- L1 data cache (high-performance): `core/cache_subsystem/hpdcache/` + `cva6_hpdcache_subsystem.sv`, `cva6_hpdcache_wrapper.sv`, `cva6_hpdcache_if_adapter.sv`.
- L1 data cache (standard write-back, deprecated): `core/cache_subsystem/std_nbdcache.sv`, `std_cache_subsystem.sv`, `miss_handler.sv`.
- Memory-side adapters (the L2 attach points): `core/cache_subsystem/axi_adapter.sv`, `wt_axi_adapter.sv`, `wt_l15_adapter.sv`, `cva6_hpdcache_subsystem_l15_adapter.sv`, `cva6_hpdcache_subsystem_axi_arbiter.sv`.
- Structural selection: `core/cva6.sv:1400-1449` (`gen_cache_wt` -> `wt_cache_subsystem`), `1450-1515` (`gen_cache_hpd` -> `cva6_hpdcache_subsystem`), `1516+` (`gen_cache_wb` -> `std_cache_subsystem`); all bind `i_cache_subsystem`.

## 3. Config knobs (`core/include/config_pkg.sv`)
- `cache_type_t` enum `30-36`; concrete `DCacheType` `186`.
- I$ geometry `Icache{ByteSize,SetAssoc,LineWidth}` `180-184`; D$ geometry `Dcache{ByteSize,SetAssoc,LineWidth}` `190-194`.
- Coherence policy `DcacheFlushOnFence` `213`, `DcacheFlushOnFenceI` `214`, `DcacheInvalidateOnFlush` `215` (rationale, incl. `RVZiCbom` tradeoff, `195-212`).
- `WtDcacheWbufDepth` `219`; memory bus `Axi{Addr,Data,Id,User}Width` `168-176`.
- Region legality: `check_cfg` `451-453` (`NrCachedRegionRules`, `NrExecuteRegionRules`, `NrNonIdempotentRules` <= `NrMaxRules`).

## 4. The L2/L3 reality
There is **no in-core L2 or L3**. The core exposes L1 (I$ + D$) that terminates at either an AXI
master (`NOC_TYPE_AXI4_ATOP`) or an OpenPiton L15 port (`NOC_TYPE_L15_*`). Consequently "adding an
L2/L3" is an *integration* task at the memory-side boundary, not an edit to an L1 file. Two routes
exist: the AXI route inserts an AXI-to-AXI L2 cache between the core's master
(`core/cache_subsystem/axi_adapter.sv` or `wt_axi_adapter.sv`) and main memory, instantiated at the
SoC level in `corev_apu/`; the OpenPiton route reuses `core/cache_subsystem/wt_l15_adapter.sv`, which
already hands cache lines to an external L1.5/L2.

### Current memory-side experiment

`g6lc_l2_top.RR_EN` is driven by default-off `L2RoundRobinEn` through both
config structs, `build_config` and `g6lc_cluster`. All target defaults remain
off; L3 still uses legacy replacement. Metadata uses `tc_sram`, read alongside
AR acceptance, with invalid-first installs initializing state after tag reset.
No new hit-path stage, clock/reset domain, cache geometry, DTS or ISA exposure.
The serialized top does not yet provide MSHR concurrency merely because the
MSHR leaf has several entries. Bank mapping is `(set * ways + way) % banks`.

`verif/tb/l2/run-l2-tb.sh` provides isolated simulation, config and synthesis
diagnostics from fresh copied inputs; the proxy's `l2-leaf` command runs the
same snapshot remotely without shared-repo sync/cleanup. The runner always
includes the bypass/ATOP follow-ups. It retains an adversarial workload where
RR regresses. The earlier stalled-bypass failure is repaired by preserving
slave ready in S_BYPASS_R and retiring AR credit only on an accepted final R;
local and pinned remote leaf suites pass for both policies, including synthetic
ATOP response timing and the existing early-short-last fill guard.
See `architecture/l2-l3-cache/README.md` for measured counts, SRAM timing/reset
contract, DFT/STA gaps and promotion blockers. Do not infer SMT stability,
nonblocking operation or production-geometry equivalence from simulation.
An independent policy model now checks every lookup/install/victim and requires
all RR victim ways to be observed. `L2TB_MODE=equiv` separately proves small
RR-off fixtures against a pinned pre-RR engine with only the bypass fix applied;
its hit-output mutation must fail. Default proof geometry is 512 B/four ways
(`memory_map`, 120 seconds). Larger geometries use `L2TB_EQ_MEM=bbox` (controller/port; tag/data/mshr
blackboxed) which proved 4 KiB, 16 KiB and 256 KiB/eight-way RR-off with
zero unproven points; hit-output inversion fails. Mapped flop-tag now
PASSes 1/2/4/8 KiB (8 KiB 86023/0 at 490 s). Collect 4 KiB PASSes 13828/0
(275 s). 1 KiB mapped hit-inversion leaves `hit_o` unproven. `+amo-arith` is a real ADD/SWAP/CAS.W + LR/SC leaf control, not a
substitute for cluster `qual-stream8-minis` or SMT cookie soaks. Isolated
overlays may change only `L2RoundRobinEn`. Isolated stream8 RR-on
checked-work (`iso-stream8-rr1`) is a functional envelope (154,170
cycles, `tohost=1`), not promotion. Isolated SMT2 RR-on
(`iso-smt2-rr1`) livelocks N=1 checked-work in verify at 2M cy
(I=2 fetch dual-issues the loop addis). Isolated stream8 RR-on AMOCAS
W/D/Q + 512 B stream_plane and all-set `mini_l2_hot_scan.S` (384,179 cy)
match RR-off cycles exactly (0 delta). Leaf A/B: RR-on 27,604 vs RR-off
31,108 cy (`hot_scan` better, `protected_hot` worse); not a core win.
Generic synth: +1 `$mem_v2` and +24 cells when RR is on (not STA).
8-way leaf mix ~0.7% (hot_scan win cancelled by protected_hot). Best
P0–P4: keep RR off. Keep `l2-leaf --mode sim|units|synth` and `l2-equiv`
as separate lanes. `L2TB_MODE=units` (proxy
`l2-leaf --mode units`) covers MSHR merge/full/waiter and data-array bank
conflict on the leaves; serialized-top zero counts remain not passes.
See the cache architecture record for exact proof scope and hashes.

### Invalidation admission follow-up (2026-09-16)

The live invalidation leaf now accepts only when every target has room or a
retainable matching tail. A sole entry being popped cannot absorb a new command;
admission and update share that predicate. Five N/depth combinations, negative
controls and local eight-step formal checks pass through `run_inval_review.py`.
See `architecture/multi-core/README.md` for exact scope and generic-cell costs.
No state, reset, clock, DTS or PMU selector changes; the consumer-ready eligibility
cone still needs physical timing qualification. Held AR/AW owner/ID reservation and phantom read credit are subsequently repaired
with scoped directed/formal checks. Producer invalidation retention/visibility,
inclusive-source acknowledgment and source-bound full-platform verification
remain open. A passing leaf is not full multicore coherence or a fresh SMT2 pass.

### Serialized MSHR sizing (2026-09-16)

The existing leaf now has opt-in MSHR occupancy/port tracing and a parameterized
static fixture. `run_l2_size_review.py` compares depths16/8/4/2 with matched cache,
policy and service: all checked cycles/traffic are identical. Depth2 removes874
sequential cells versus16 in both measured fixtures, with21.04%/14.29% generic
cell reductions at their stated small/full-map versus data-macro-excluded scope.
Two-step occupancy induction supports the single-live observation, not full data
or production-geometry equivalence. Subsequent real 256 KiB/eight-way/four-bank checks and matched SMT2/stream8
integrations pass without cycle/trace changes. Those two packages now explicitly
select depth 2; generic inference and other packages remain unchanged. Production-
shaped incremental area is recorded separately with fixed tag/data storage excluded.
Keep the generic MSHR capability intact and coherence/physical/platform gates open.
See `architecture/l2-l3-cache/README.md` for exact counts and open promotion gates.

## 5. Feature-addition playbook
Choose the route by `NOCType`. For an AXI L2, add the L2 module (a separate IP) in `corev_apu/`,
wire it between the core AXI master and the memory `corev_apu/axi_mem_if/`, and preserve
`Axi*Width`. Keep the block size consistent with `Zic64b` (64 bytes) so `Dcache*LineWidth` and the
L2 line match, and keep CBO (`#cmo`) semantics end-to-end so `CBO.flush/clean/inval` reach the L2.
Coherence with DMA/other harts is governed today by `DcacheFlushOnFence*`/`DcacheInvalidateOnFlush`
or by `RVZiCbom`; an L2 must not weaken the RVWMO guarantees those provide. Expose the new level to
software through the device tree (below). No `core/` L1 file needs editing for a memory-side L2.

## 6. `.dts` linkage
L1 is described on the CPU node via `i-cache-size`/`i-cache-block-size`/`i-cache-sets` and the `d-`
equivalents (mapped from `Icache*`/`Dcache*`). An added L2 is a separate node referenced by
`next-level-cache = <&l2>`, with an `l2-cache { compatible; cache-level = <2>; cache-size;
cache-block-size = <64>; cache-sets; }` block whose parameters must equal the instantiated L2 in
`corev_apu/`. Block size must be 64 bytes when `Zic64b` is present (`#ext:zic64b`).

## 7. Invariants and pitfalls
The write-back `std_*` subsystem is deprecated — prefer `WT` or `HPDCACHE_*`. The coherence knobs
(`213-215`) trade performance for DMA correctness; the in-source rationale (`195-212`) recommends
`RVZiCbom`/CBO instead on uniprocessor or non-coherent SoCs. Any L2 must honor `#pma` region
attributes (non-idempotent MMIO must remain uncached) and `#memorymodel` ordering; mismatched line
sizes between `Dcache*LineWidth`, the L2, and `Zic64b` are the most common integration bug.
