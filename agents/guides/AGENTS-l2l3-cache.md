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
