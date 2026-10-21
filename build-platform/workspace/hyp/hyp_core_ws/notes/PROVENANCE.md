# PROVENANCE — hyp8 redesign workspace

## What the trees are

- `hyp_redesign_core_8fo4/` — the G6LC core redesign tree (identity-free):
  every module instantiated in the `g6lc_core` cone that exceeded the 8-FO4
  budget was REWRITTEN, ADAPTED, or kept AS-IS per `notes/decisions.md`;
  top: `g6lc_core` (`core/Flist.g6lc_hyp8`).
- `hyp_redesign_corev_apu_8fo4/` — the APU/SoC redesign tree: the core tree
  mirrored plus the SoC integration plane; top: `g6lc_soc`
  (`Flist.hyp8_apu`, last row), a synthesizable SoC (hart + axi_cdc seam,
  axi_xbar CUT_ALL_PORTS, CLINT, PLIC, debug module + JTAG, bootrom, UART,
  timer, exported DRAM AXI master) with the `g6lc_soc` package's memory map
  and interrupt IDs unchanged.
- `hyp_core_ws/` — this identity-free workspace: `analysis/` (ledgers,
  coverage, cut minimization), `notes/` (decisions, boot hazards), `tools/`
  (materialize/rename/render/check scripts).

Run provenance (commands, budgets, edit counts, exclusion lists, upstream
file mapping) is kept in the provenance workspace outside this tree:
`<repo>/build-platform/workspace/build/sv-timing/hyp8-src`
(emits under `emit/core-8fo4` and `emit/apu-8fo4`, boards under `reports/`).
This tree is deliberately free of upstream names; `tools/` derive every path.
Bring-up rounds add `boards/hyp8-core/analyze-r{1,2,3,4,5}.json` +
`emit/hyp8-core-r{1,2,3,4,5}` (568 latency-neutral edits in r3; 272 in
r4; 275 in r5) beside the base emits; mode counts are unchanged by the
r3/r4/r5 structural passes (every reworked file was already
ADAPTED/REWRITTEN). The r4 board ran under the exact hyp8 parameter map
(`inputs/param-map-hyp8.json`) with config-dead generate branches made
resolvable by inline field expressions. The r5 round implemented the
seven step-4-deferred items (iq_bank registered wakeup CAM, iq_arb age
matrix, rename_recover slot_of_level table, wbuffer W3 split, alu A3 /
LAT_ALU_FULL→3, csr_regfile two-phase writer, load_unit one-hot FSM);
each keeps a `translate_off` reference cone or an equivalence assertion,
and the contract changes are recorded as BU5 decisions rows and
boot-hazards H33–H39. One-off transformation helpers
(`split_csr_update.py`, `lu_onehot.py`) sit at the
`hyp_redesign_core_8fo4/` tree root; they are scaffolding, not shipped
RTL, and are not on any flist.

## Budget

8 FO4 per cycle — 5 GHz nameplate at `fo4_ps = 20`, margin 0.2
(`BUDGET = 8.0` in `tools/render_reports.py`). `min_cuts_est = ceil(D/8) - 1`.
Tier: COPY D<=8, T3 <=16, T2 <=32, T1 else.

## Groups and file counts per mode (from `analysis/coverage.md`)

| group | scope | AS-IS | ADAPTED | REWRITTEN |
|---|---|---|---|---|
| timing-correction base | emitted sv-timing files, provenance | (emit copies) | | |
| fifo/arbiter + frontend 2 | fifo_v3/hyp_fifo, rr arbiter, frontend stages | | x | x |
| decode 3 | id_stage split D1/D2/D3 | | x | x |
| OoO backend 4-5 | rename, IQ, dispatch, scoreboard, ROB, issue_read_operands | | x | x |
| exec 6-7 | alu, branch, ex_stage, mult, serdiv, aes, fpu_wrap, regfile | x (fpnew) | x | x |
| LSU + caches/MMU 8-9 | lsq, load/store units, store buffer, wbuffer, dcache, icache, adapters, TLB/MMU/PTW/PMP | x | x | x |
| CSR/observability/top 10 | csr_regfile split, controller drain, perf_counters, rvfi, fifo wrapper, g6lc_core, vendor FPU | x | x | x |
| Phase 4 APU/SoC | g6lc_soc, axi_cdc seam, bridges, PLIC/CLINT/timer/DM/bootrom cuts, UART residue | x | x | x |

Mode roll-up over the 111 coverage rows: **REWRITTEN 25, ADAPTED 55,
AS-IS 31** (a row may cover several files, e.g. the csr_* split, fpnew
group, slib_* UART cells). The open-items pass moved the four
predictor-interior rows (bp_tage/bp_ittage/bp_statcor/bp_loop) and
dm_csrs from AS-IS residue to ADAPTED.

## Verification status

**None.** No lint, no simulation, no STA, no synthesis, no boot has been run
on the hyp8 trees. What exists: text-only structural checks
(`tools/struct_check.py` — 618 instantiations, 1 stale upstream-parity TB
port pair; `tools/flist_check.py` — 307/480 rows resolve, 0 unresolved,
0 duplicate providers), the identity grep (empty), UTF-8 and
begin/end-balance scans. Every FO4 figure is the emit's structural or
adjusted estimate; nothing is measured silicon.

## Open questions roll-up (all groups)

- Replay merge semantics: dispatch ORs LSQ wait/violation and load-unit
  miss replays through a pending-TID mask with bank-wide re-arm — exact
  same-cycle source collisions may collapse (recorded choice, H3/H5/H21).
- Perf-event pulse semantics: `hyp_wb_reserve_stall` counts the
  reservation cycle, not the later grant; `hyp_fe_override{1,2}` count
  the override-fire cycle (H27 note).
- `commit_bundle_valid` not passed to `g6lc_rvfi_probes` (module derives
  liveness from `commit_instr_i` internally).
- `g6lc_hyp_lfsr` CipherLayers path unsupported (translate_off fatal; no
  consumer).
- APU verif TBs stale vs renamed ports/`_old` wrappers (TB-side only).
- dm_csrs now registers the DMI request decode (+1 response latency,
  `req_q`/`req_v_q`); dm_mem registers the slave request bundle (+1
  window latency, bridge `RD_LAT=4`). dmi_jtag/dmi_jtag_tap interior
  reg→reg residuals remain — serial JTAG clock domain, pending STA.
- UART/slib_* intoout/intoreg structural residuals — baud-class serial
  datapath behind the registered APB bridge; pending STA.
- `axi_adapter_arbiter`/`miss_handler`/`std_cache_subsystem` are
  emit-syntactic reachables but generate-dead under the WT g6lc64_ooo
  config — not in the live cone.
- hart `axi_cdc` src/dst resets share `rst_ni` in this draft (H13; reset
  ordering to be proven when the clocks actually differ).
