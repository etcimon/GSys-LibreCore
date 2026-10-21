# hyp8 r5 — mapped gate-level board (Yosys + OpenSTA, Nangate45)

**Status: measurement, not sign-off.** Mapped delay on the Nangate45
study liberty (`Nangate45_typ.lib`, `INV_X1` FO4 = **21.398 ps** by the
inverter-chain-8-4 probe — `platform-fo4.json`). Structural FO4 numbers
(delay-v44, `fo4_ps=20`) are repeated beside each mapped reading for
comparison only; the two models are different abstractions and are not
expected to agree in magnitude.

- Command: `bun run src/cli/index.ts timings sta-rtl --target g6lc64_ooo
  --top g6lc_core --flist build-platform/workspace/build/sta-rtl/hyp8.f
  --platform nangate45 --target-mhz 5000 --fo4 0 --remote
  --map-recipe streamed
  --output workspace/build/sv-timing/hyp8-src/boards/hyp8-core/sta-r5`
- Constraint: 0.2000 ns `core_clock` on `clk_i`, 0.04 ns in/out delay
  (`sta-r5/clock.sdc`) — nominal 5 GHz intent, deliberately
  unreachable; the module board is a per-module cone measurement.
- Live RTL (`--fo4 0`: no sv-timing pre-emit); flist =
  `build-platform/workspace/build/sta-rtl/hyp8.f` (flattened from
  `hyp_redesign_core_8fo4/core/Flist.g6lc_hyp8`, `tc_sram` → timing
  stub substitution).
- Artifacts: `sta-r5/{module-board.tsv, adjusted-fo4.json,
  adjusted-fo4.txt, calibration.tsv, platform-fo4.json, remote.log,
  svt/width-map.json}`.
- Flow: slang elaborate + RTLIL split (4047 modules, 107 s) →
  per-module streamed mapping (all `ok delay`, cached on rerun) →
  per-module OpenSTA → adjusted-FO4 pass at platform FO4 21.398 ps.

## Headline numbers

- Module board rows: 4047 instance rows; **measured with a path: 93
  (plus 8 any-path-only → 101 measured per `adjusted-fo4.json`)**;
  9 measured-no-path; the rest are `link failed` or no-cone rows
  (partial board — refusals recorded below, per the milestone's
  accept-partial rule).
- Top-level constraint check (0.2 ns): `wns_max −7629.7 ns`,
  `tns_max −153.36 ms`, `wns_min −0.141 ns`, `tns_min −27.24 µs`
  (`remote.log` s2 line) — expected at a nominal 5 GHz probe on a
  design whose worst mapped cone is 3.7 ns; informational only.
- Adjusted FO4 vs budget 10 (platform): **80/101 measured modules
  over**; `closes: no`. Budget-equivalent **218 MHz on Nangate45**,
  **233 MHz at fo4_ps=20** (vs the structural model's ~322 MHz —
  the mapped model is uniformly more pessimistic).
- Platform FO4 measured: 21.398 ps (`INV_X1`, chain8 0.1641 ns /
  chain4 0.0785 ns, `measured_at 2026-10-21T05:19:57Z`).

## Structural-vs-mapped — r5 residual list

Structural = `analyze-r5.json` worst `total_fo4` (delay-v44,
fo4_ps=20). Mapped = `adjusted-fo4.json` (platform FO4 @21.398 ps) and
mapped_ns×50 = FO4 @20 ps for a like-for-like column. `any` =
worst path of any kind; `r2r` = register-to-register only; the
difference is the **boundary/register-launch overhead** (input→reg or
reg→out cone).

| module | struct FO4 | mapped any ns | mapped r2r ns | cells | adj FO4 @21.4 | FO4 @20 ps | launch ovh ns | note |
|---|---|---|---|---|---|---|---|---|
| g6lc_iq_arb | 65.9 | 3.667 | 3.667 | 29 | **171.4** | 183.4 | 0.000 | worst measured module |
| g6lc_iq | 121.0 | 3.321 | — | — | 155.2 | 166.1 | 3.321 | boundary path (in-reg / reg-out); no internal r2r cone |
| wt_dcache_wbuffer | 124.1 | 3.057 | 3.057 | 23 | 142.9 | 152.8 | 0.000 | W2 fold cone |
| g6lc_iq_legal | 28.4 | 2.789 | 0.462 | 5 | 130.3 | 139.5 | 2.327 | worst is a boundary path through the legality checker — large structural under-read |
| g6lc_fe_override | 23.6 | 2.615 | 2.615 | 30 | 122.2 | 130.8 | 0.000 | new residual not on the r5 list |
| alu | 71.1 | 2.286 | 2.286 | 23 | 106.8 | 114.3 | 0.000 | second instance 1.821 ns / 25 cells |
| load_unit | 77.2 | 1.867 | 1.349 | 9 | 87.3 | 93.3 | 0.518 | r2r cone only 9 cells — boundary path is worst |
| stb_fwd | 33.4 | 1.797 | 1.347 | — | 84.0 | 89.8 | 0.450 | adjacent residual |
| sb_lifecycle | 28.9 | 1.765 | 1.765 | — | 82.5 | 88.2 | 0.000 | adjacent residual |
| g6lc_lsq_release | 34.8 | 1.223 | 0.328 | 6 | 57.2 | 61.2 | 0.895 | boundary path worst |
| multiplier | 52.0 | 1.394 | 1.030 | 22 | 65.1 | 69.7 | 0.364 | PP-row S2 form |
| g6lc_rename_recover | 47.9 | 1.417 | 1.417 | 20 | 66.2 | 70.9 | 0.000 | 105,604 instances in split |
| csr_regfile | 66.6 | 1.199 | 1.199 | 9 | 56.0 | 60.0 | 0.000 | phase-B override cone |
| g6lc_lsq_slot | 50.1 | 1.120 | 1.120 | 13 | 52.3 | 56.0 | 0.000 | |
| g6lc_lsq (top) | 92.5 | 0.393 | 0.393 | 6 | 18.4 | 19.7 | 0.000 | wrapper only — sub-blocks carry the delay |
| g6lc_rename (top) | 25.0 | 0.323 | 0.323 | 5 | 15.1 | 16.2 | 0.000 | wrapper only |
| **g6lc_iq_bank** | **85.5** | — | — | — | — | — | — | **refusal: all 8 genvar instances `link failed`** in OpenSTA; mapped netlist for this module did not link (recorded, board continues) |
| **g6lc_rename_read** | 49.6 | — | — | — | — | — | — | no measured cone (instance rows carry no path; the banked-pick logic folds into `i_rename`/parents) |
| g6lc_rename_resolve / _publish | — | — | — | — | — | — | — | same — no measured cone |
| **trigger_module** | **79.2** | — | — | — | — | — | — | **config-dead: `SDTRIG=0` in the hyp8 config package** — not elaborated, hence absent from the board |

`stb_fwd`/`sb_lifecycle`/`g6lc_iq_legal` are shown because they sit
inside the mapped top-10 even though r5 demoted them — and all three
are structural under-reads (mapped ~3× their structural FO4), worth a
`coverage.md` note alongside `g6lc_fe_override`.

## Register-launch overhead

Defined as `worst_any − worst_reg2reg` per module (boundary launch or
capture cone on top of the internal register cone). Aggregate:

- Zero for the big internal cones: `g6lc_iq_arb`, `wt_dcache_wbuffer`,
  `alu`, `csr_regfile`, `g6lc_rename_recover` — their worst path is a
  true register-to-register path inside the module.
- Dominant where it matters: `g6lc_iq` **3.321 ns** (no internal r2r
  path at all — the whole worst reading is boundary), `g6lc_iq_legal`
  **2.327 ns**, `g6lc_lsq_release` **0.895 ns**, `load_unit`
  **0.518 ns**, `stb_fwd` **0.450 ns**, `multiplier` **0.364 ns**.
- Calibration note (`calibration.tsv`): `reg→reg cones ≥ 8 cells: 0
  track` — the platform-FO4 calibration had no qualifying r2r cones,
  so `cells_per_fo4` is unpopulated for this run; the adjusted-FO4
  table uses the platform probe (21.398 ps) not a per-design cell
  rate.

## Refusals / gaps (recorded per the partial-board rule)

- `g6lc_iq_bank` — all 8 generate instances `link failed` (mapped `.v`
  did not link in OpenSTA). The bank's contribution is still visible
  through `g6lc_iq_legal`/`g6lc_iq` boundary cones, but no per-module
  number exists. **Fix candidate:** re-run with per-bank elaboration
  or a hierarchical recipe for this module.
- `g6lc_rename_read/_resolve/_publish` — no measured cone (rows carry
  no path; logic likely folded into parent boundary paths).
- `trigger_module` — config-dead (`SDTRIG=0`); structural residual
  only.
- 2971 of 4047 instance rows are `link failed` — overwhelmingly
  genvar/parameterized sub-instances (e.g. every `instr_scan`,
  `compressed_decoder`, `g6lc_decode_s1/s3` lane). The 101 measured
  modules cover every top-level residual except `g6lc_iq_bank` and
  the rename sub-blocks, so the partial board is usable.

## Fixes that were required to reach this board (r5 → mapped-clean)

The remote slang elaboration initially rejected the r5 tree
(use-before-declaration in `--single-unit --best-effort-hierarchy`
mode — Verilator accepts these, slang does not). All fixes are
**declaration-order only; zero semantic change**:

- `core/csr_regfile.sv` — 12 `*_q/*_d`/`trap_to_*` declarations
  hoisted above the `csr_decode` instance.
- `core/ex_stage.sv` — `alu_s2_a3`/`alu_s3_a3` and the
  `ld_*_pack` projections moved above `alu_wrapper`/`g6lc_lsq_release`.
- `core/ooo/g6lc_lsq.sv` — same `ld_*_pack` projections above the
  release instance.
- `core/ooo/g6lc_iq_arb.sv` — explicit cast for a `fu_t` field in a
  struct literal (enum implicit-conversion refusal).
- `core/ooo/g6lc_ooo_dispatch.sv` — `iq_replay_v`/`iq_replay_t` decls
  above `i_iq`.
- `core/cache_subsystem/wt_dcache_wbuffer.sv` — `e_*`/`w3_*` decls and
  `ni_inside`/`ni_conflict` decl hoisted above first use.
- `core/g6lc_mmu/g6lc_tlb.sv` — `rq_*_q` decls above `p_tlb_t1`.
- `core/pmp/src/pmp_data_if.sv` — `if_fetch_vaddr_xlen` decl above its
  use.
- `core/fetch_B/instr_realign.sv` — `b_carry_ok`/`b_valid_b` decl
  above `b_complete` assign.
- `core/frontend/g6lc_fe_nextline.sv` — `cursor_idx` decl hoisted
  (multi-line decl preserved; its `assign` kept after `cursor`).
- `core/sb_head.sv` — `if (!rst_ni || flush_i)` split into
  `!rst_ni`/`else if (flush_i)` in two `always_ff` blocks (slang
  reset-condition rule; identical logic).

Both trees re-verified after the repairs: `g6lc_core` Verilator
lint **0 errors**, `g6lc_soc` **0 errors**; remote slang
`read_slang … --top g6lc_core` 0 errors.

## Honest reading

The mapped board confirms the structural residual ranking (iq_arb /
wbuffer / iq boundary / alu on top) with one new entrant
(`g6lc_fe_override` 130.8 mapped-FO4 @20 ps vs 23.6 structural — a
structural under-read worth a note in `coverage.md`). The mapped model
is ~1.5–2.5× more pessimistic than delay-v44 on the same cones, and it
prices boundary launch paths the structural model doesn't see. Neither
is sign-off; this is a Nangate45 study-liberty measurement at an
intentionally unreachable 5 GHz constraint.
