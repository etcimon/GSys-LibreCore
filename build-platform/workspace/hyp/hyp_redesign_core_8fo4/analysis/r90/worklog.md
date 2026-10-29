# r89/r90 -- six-cone reductions under delay-v49 (boards of record r88 -> r90)

Instrument: `sv-timing` delay-v49 (r86 worklog items 1-6), map
`analysis/r88-param-map.json`, flist `analysis/timing/hyp8-core.f`,
`board.sh <tag> [module,...]`. Boards: `analysis/timing/boards/r88-all`
(before), `r89-all` (after handoff A), `r90-all` (after all six).

| module | r88 | r90 | kind / line now | what moved it |
|---|---:|---:|---|---|
| g6lc_ai_exec | 90.4 | 79.5 | in->reg L814 (dot4 one-cycle datapath, user's r27 row tree) | requant round step: bump as an add operand + ST_RQ_R split in two phases (+1 cycle per requant element); MMA lane product as one exact 9x9 Baugh-Wooley row set + csa3 tree (mac_prod_q node 82.6 -> 25.4); fixes F17 |
| serdiv | 73.1 | 55.3 | reg->reg L197 (`add_out` NORM arm + enable select) | digit step as one 65-bit subtract (carry-select pair + 64-bit borrow select 13.1+24.0 -> 12.5); fixes F18 |
| g6lc_lsq | 54.5 | 36.8 | in->out L350 (`ld_free_o + 1'b1` serial count, independent-lhs bundle) | `lane_be` as a 32-entry constant table, event byte-enables hoisted out of the guarded (u,v) scan (the file's own `s_be[s]` pattern) |
| g6lc_shared_tlb | 39.3 | 29.8 | reg->reg L518 | flush walk / tag update constant-gated on `UseSharedTlb` (hyp8: 0); one-hot registered flush kind for the match select (UseSharedTlb=1 map: live arm 52.4, `analysis/r90/param-map-sharedtlb1.json`) |
| load_unit | 54.5 | 47.1 | reg->reg L1462 (`ex_pub -> a_expub -> a_data -> a_drn -> ldbuf_rindex -> ldbuf_valid_d`) | `ex_pend_slot_live`: the `ex_pub` flushed_d reduction applied to the pending-record push (valid slot: `!flush_i && !flushed_q && !cancelled_mask_i[tid]`; LDBUF_FALLTHROUGH keeps the full form) |
| g6lc_rename_read | 54.1 | 51.0 | in->out L220 (`taken_lt -> lone_p 32.0 -> alloc_do -> lane_o.prd`) | `ckpt_slot`/`do_ckpt`/`br_over` at LVL_W+2 bits, modulo as a slice for power-of-two CKPT_PER_HART (A140); `ckpt_slot_n` with the old function as a translate_off reference |

All six changes are exact (same cycle behaviour, same ports) except the
requant phase split (+1 cycle per element, `valid_o` only in ST_DONE)
and the two bug fixes below. Every change carries a `translate_off`
identity/reference assertion in the RTL.

## Functional findings (both fixed in this pass)

- **F17 g6lc_ai_exec U8xU8**: `32'(signed'(16'(a*b)))` sign-extended
  products >= 32768 (200*200 -> -25536); the reference
  `core/cvxif_g6lc_ai/g6lc_ai_exec.sv:573` is exact (`32'(mac_au*mac_bu)`).
  Leaf `tb_g6lc_ai_exec_dot` new case `mma_u8 F17 255x255`: FAIL on the
  untouched tree (`analysis/r90/ai-exec-pre.log`), PASS after
  (`PASS tb_g6lc_ai_exec_dot checks=452`, incl. -128x-128 and -128x127).
- **F18 serdiv**: `lzc_b_full = (lzc_b_q == $clog2(WIDTH)'(WIDTH))`
  compares a 6-bit count with 6'(64) == 0, so it fired for ANY divisor
  whose lzc input has bit 63 set: udiv/urem with b >= 2^63 took the
  "b == -1" early-out (quotient a, remainder 0). The hyp8 group-7 NORM
  staging introduced it; upstream reads the lzc empty flag directly.
  Fix: `lzc_b_empty_q` registered at accept. New leaf
  `verif/tb/core/tb_g6lc_hyp8_serdiv.sv` (20k random+directed txns,
  RISC-V oracle, ~1.5k mid-flight flushes, `lat_sum`):
  `HYP8_SERDIV_PASS n=20000 flushes=1521 lat_sum=63764`; the production
  `core/serdiv.sv` passes the same bench (`n=20000 flushes=1153
  lat_sum=43188`, one NORM cycle less per op); the untouched hyp8 tree
  fails it (`SERDIV_MIS ... opc=0 got=a want=0`). The sidekick's first
  reading "the leaf is broken at baseline" was a tb defect (unsigned
  ternary context made `sa / sb` unsigned; wrong accept protocol); fixed
  in the tb before concluding.

## Gates run

- load_unit: `run_hyp8_mem_local.sh` plain `HYP8_MEMORY_PASS checked=160`,
  deep (`-DG6LC_HYP8_DEEP`) `HYP8_MEMORY_PASS checked=160`,
  `expend pushed=3 presented=4`; no assertion fired.
- serdiv: `analysis/r90/run_hyp8_serdiv_local.sh` -> PASS above.
- g6lc_ai_exec: `analysis/r90/run_hyp8_ai_exec_local.sh` -> exec_dot PASS
  452 checks (post) / FAIL F17 (pre). `tb_g6lc_ai_enq_ready` stops at the
  hyp8 geometry assertion (`g6lc_ai_exec.sv:101`) identically pre and
  post -- that leaf drives a non-hyp8 AiCfg; recorded, not worked around.
- g6lc_rename_read: `tb_g6lc_review_rename` asserts `RENAME_NO_ALLOC`
  at scenario 0 identically pre/post (pre-existing tb-vs-tree
  mismatch); `tb_g6lc_review_ckpt`/`ckptrand` do not build under stock
  Verilator 5.020 (parser bug on `x.field=` in `configuration()`).
  Functional coverage therefore rests on the inline `p_ckpt_eq`
  reference assert under the remote smokes.
- g6lc_lsq: `tb_g6lc_hyp8_lsq` fatals in `g6lc_lsq_reduce`'s
  `g6lc_lsq_red_age_miter` identically pre/post (pre-existing r53-B6
  oracle divergence); `lane_be_tab_chk` (all 32 slots) fired nothing.
- g6lc_shared_tlb: no leaf on this tree; the full-flist build is the
  gate; `flush_kind_onehot_chk` added (the sidekick's first one-hot had
  the gvma > vvma > sfence priority reversed against the FSM -- fixed in
  review).
- Remote batch (`hyp8-r90-closure` / `hyp8-integration-r90` /
  `hyp8-r90-smokes`): see `analysis/r90/remote-gate.md`.

## Countercases / not done

- serdiv (b) "pre-negated +/-a load at accept": under the delay-v49 load
  law every 64-bit 2:1 select costs >= 23.5, so moving the NORM arm to
  the accept cycle trades one select on the recurrence for two on the
  in->reg accept path (~53 vs 55.3) -- NULL, not built. The serdiv floor
  under this law is adder (12.5) + enable select (23.5) + launch.
- g6lc_lsq next row: `ld_free_o`/`st_free_o` as serial `+ 1'b1` counts
  (32.8) -- a `$countones` rewrite is the obvious exact follow-up.
- g6lc_ai_exec next row: the dot4 one-cycle datapath (rs 18.1 + ps 17.0
  + 4-way sum 13.0 + result select 23.5); a stage there changes the
  CVXIF one-cycle contract of DOT4 -- the user's call.
- `g6lc_rename_recover.sv:123` has its own 32-bit `ckpt_slot` copy.
- `tb_g6lc_ai_enq_ready`, `tb_g6lc_review_rename`, `tb_g6lc_hyp8_lsq`
  baseline failures are pre-existing and recorded, not fixed here.

## Remote batch gate (see `remote-gate.md`)

`hyp8-integration-r90c`: build_complete rc=0 (352 s), model sha
`48eebd37aabb5109c043ad57c5b6e3776ced3b53891f00450ec2180689d4da8d`, lint
scalar/smt2 rc=0 with 0 %Error (729 files). `hyp8-r90-smokes-b`: 7/7 PASS,
cycle-identical to r84 (`685/1011/492/2364/2199/1231/671`). Environment
note for the next pass: the closure's `tb/tests/h34_shift_dep.S` /
`h33_st_fwd.S` had lived in the deleted `workspace/build/sv-timing/hyp8-src`
tree and were restored from the `hyp8-integration-r46a` pull;
`run_hyp8_integration.py`'s `TEST_DIR` still points at the deleted path, and
`HYP8_ALLOW_OVERLAP`/`HYP8_INT_TAG` must be forwarded with the proxy's
`--env` (the first smokes dispatch ran against the stale default tag).
