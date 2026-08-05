# Emit vs baseline isolation (2026-08-04)

## Verdict
**OpenSBI hang is NOT caused by the 2.5 GHz full_core emit overlay.**
Non-emit `cv64a6_server_math` reproduces the identical `CVA6_MC_PC_PROBE` signature.

## Comparison (fw_payload, +time_out=100000, +tohost_addr=0x80041730)

| Probe | emit 2.5GHz | non-emit baseline |
|-------|-------------|-------------------|
| @100 | both @ bootrom 0x10020 | same |
| @500+ | c0@0x80000084 pend0=1 ic0=3 l2st=4 l2a=0x80000080 ar_ot=1 ar0=ar1=0 | **identical** |
| result | timeout | timeout |

Harnesses:
- emit: `work-ver-emit-2p5/Variane_testharness` (13:37)
- baseline: `work-ver/Variane_testharness` (18:39 rebuild)

## Emit overlay analysis
- 94 replaced modules; hang-path `g6lc_icache*`, `axi_arbiter` are mostly **dead SVT stubs** (lean-zero pipes, no functional rewire).
- **Real** emit damage: `cva6_hpdcache_if_adapter__svt.sv` **deletes entire AMOCAS.D/CASD FSM** (−173 lines) — Zacas.D risk later, **not** this early I$ hang.
- L2 / hub / prefetcher are **not** in emit overlay (corev_apu).

## Hang mechanics
- `l2st=4` = `S_MISS_AR` (L2 waiting for `mst_resp_i.ar_ready` on line fill).
- c0 reached OpenSBI DRAM (`npc=0x80000084`) then stuck mid-fetch (`l2a=0x80000080`).
- Hub `ar_ot=1` (one outstanding AR); core AR valids 0 at sample.

## Historical SUCCESS context
- Prior `fw_payload` SUCCESS ~6.5M was on **`cv64a6_smt2`** (dual-hart SMT), not multi-core `server_math` (NrCores=2 + L2 + hub).
- `mini_tohost` SUCCESS @359 on **both** emit and baseline (DRAM path can work for tiny ELFs).

## Next fix path (not emit)
1. Fix multi-core L2 `S_MISS_AR` stall / DRAM `ar_ready` path (hub OT + L2 miss fill + axi2mem).
2. Extend `CVA6_MC_PC_PROBE` with L2 mst AR valid/ready + mem-side OT.
3. Optionally re-test OpenSBI on `cv64a6_smt2` to reconfirm historical green path.
4. Before reusing full_core emit for Zacas, restore CASD in if_adapter emit (or exclude that module from overlay).

Logs:
- monorepo-soak/emit-opensbi-mc-pc-probe.log
- monorepo-soak/baseline-opensbi-mc-pc-probe.log
- monorepo-soak/emit-2p5ghz-opensbi-mc-20260804-133937.log
