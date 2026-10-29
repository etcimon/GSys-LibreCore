# r86-r88 -- measurement environment rebuilt, analyzer truth (delay-v49), six-cone census

Scope: the six delay-v48 rows the user named (g6lc_ai_exec :479, serdiv,
g6lc_lsq, g6lc_shared_tlb, load_unit, g6lc_rename_read). No RTL in this
pass; the pass re-establishes an honest instrument first (E6 package-first,
RT-H1 "dump the chain before believing the number").

## r86 -- environment loss and rebuild

- `build-platform/workspace/build/sv-timing/hyp8-src/` (flist, param
  maps, boards, `ir_hot_nodes.py`, `clock_board.py`, `clock_exclude.txt`)
  and `sv-timing/target/` were deleted after commit 00f4d33b9 (the
  workspace dir is gitignored). Rebuilt in a TRACKED location:
  `analysis/timing/{hyp8-core.f, board.sh, path_dump.py, ir_hot_nodes.py,
  top_table.py, boards/}` (boards keep `.log`, census `.txt`, `*-top.txt`;
  `*.ir.json` / `*-all.json` are gitignored, tens of MB). `hyp8-core.f`
  entries are relative to the flist directory (the analyzer resolves
  `--files-from` entries against the list's directory, not cwd).
- `r86-all` (delay-v48, r84 map) reproduced the r85 board of record:
  g6lc_ai_exec 75.0 (:479), serdiv 73.1 (69.3 in r85 -- sv-parser bump
  d0545d5 / rebuild), g6lc_lsq 65.0, g6lc_shared_tlb 55.2, load_unit 53.5
  (L626), g6lc_rename_read 54.1. The user's da09b4c89 r27/r28 edits to
  g6lc_ai_exec did not move its :479 row (that cone is the requant
  round/clamp chain, not the products they rewrote).
- Caller facts that change how the ranking is read (hyp8 profile):
  `G6LCCfg.CvxifEn=0` (g6lc_ai_exec not instantiated), `UseSharedTlb=0`
  (the shared-TLB tag-compare arm is dead; the flush walk logic is live
  but functionally unused), `CohPolicy=2` (`PHYS_VALIDATE` is 0 -- the
  g6lc_lsq phys-validate scan is dead). Only serdiv, load_unit and
  g6lc_rename_read are live clock rows for hyp8; the other three were
  still reduced as asked, as modules.

## r87/r88 -- analyzer defects found by probing (all fixed, delay-v49)

Probe file `tmp/svt_probe/probe.sv` (18 one-node shapes) + the real top
chains. Each defect has a fixture and a test in `sv-timing-core`.

1. Register-only cones vanished: region paths were pruned by their
   stale default InToOut kind before the retag (`y_d = ~y_q + a_i` had
   NO reg->reg path; `--keep-dead-nodes` showed 13.0). Fixture
   `reg_only_cone.sv`.
2. Procedural `if (<const>) ... else` arms were billed
   (`if (!G6LCCfg.UseSharedTlb)` else-arm = the 55.2 row). Fixture
   `if_const_arm.sv`. shared_tlb 55.2 -> 39.3.
3. `pkg::ENUM` and bound struct fields did not resolve in const_value
   (`PHYS_VALIDATE = G6LCCfg.CohPolicy == config_pkg::COH_OOO`).
   Fixtures `pkg_enum_fold.sv`, `pkg_struct_field_fold.sv` (exact lsq
   shape).
4. A folded sub-expression still created dependency edges: the r82
   walk only folded top-level ternaries, so `PHYS_VALIDATE && !flush_i
   && (|eq)` kept the 65.0 lsq cone alive. `walk_read_idents` now
   recurses; a constant sub-tree reads nothing. g6lc_lsq 65.0 -> 54.5
   (new live row L531, the vv_* query-event update).
5. Statement-order fallback in dep-chain mode: a node with no
   dependency edge inherited the previous statement's cone
   (`mma_n_d = mma_n_q + 1` chained onto the requant write; serdiv
   `b_reg_en = 1'b1` onto `a_reg_en`). Fixture `stmt_order_no_chain.sv`;
   the `fn_prefix_or_inline_gather` golden (29..38) was this artefact and
   is now 14..19.
6. Replicated selects `{W{s}} & x` paid no fanout while `s ? a : b`
   paid W loads (+21 at W=64). Non-constant replications now pay W
   loads; constant replications (`{{HW{1'b0}},1'b1}`) are wires (the
   sidekick's first version over-charged serdiv `hi_diff_b0` 13.1->23.2;
   fixed before the board). Fixture `rep_select_loads.sv`.

Param-map truth (E1 map identity): `r84-param-map.json` carried
`G6LCCfg.NonIdemPotenceEn=1`; the elaborated map
(`elaborated-scalar-param-map.json`, 282 keys) says 0 (lengths are
zero). All other overlapping keys agree. `r88-param-map.json` = r84 map
with that key corrected; `board.sh` uses it. Effect: `stall_ni` (22.6,
the r79 dead-predicate over-read) folds and leaves the load_unit row.

## r88 board of record (delay-v49, r88 map, 283 modules, 12632 paths)

| module | r86 (v48) | r88 (v49) | kind | line | what the row is |
|---|---:|---:|---|---|---|
| g6lc_ai_exec | 75.0 | 90.4 | reg->reg | :479 | requant round/negate/zp/clamp/tile-write chain; +15.4 is the `rq_adj` replicate masks now paying their loads |
| serdiv | 73.1 | 73.1 | reg->reg | :199 | `hi_diff_b0 13.1 -> step_diff 24.0 (64-bit select) -> add_out 31.8 (NORM negate + two 64-bit selects) -> op_a_d` |
| g6lc_lsq | 65.0 | 54.5 | in->reg | :531 | `lane_be` barrel (26.5) under the vv_* query-event guards (20.5) |
| g6lc_shared_tlb | 55.2 | 39.3 | reg->reg | :793 | SFENCE flush walk: tag match -> `sfence_match_way` -> kind select -> `shared_tag_valid_d` clear |
| load_unit | 53.5 | 54.5 | reg->reg | :626 | `st_fwd_covers -> data_req -> ldbuf_w -> lu_cancel_new -> new_hit -> flushed_d -> ex_pend_set -> pend_d` (same real cone as r85) |
| g6lc_rename_read | 54.1 | 54.1 | in->out | :292 | `ckpt_slot()` at 32-bit int width (46.6 of it) |

Model facts measured on the probe (delay-v49): 64-bit incrementer 5.8,
32-bit add 10.0, 48-bit add 12.2, 48-bit compare 5.5, 64:1 byte index
12.3, 512:1 byte index 26.0, 8x8 multiply 44.8 (16-bit) / 56.0 (32-bit
context), 2:1 64-bit mux with a bare 1-bit select 23.5 (= 2.5 + 21.0 of
select loads under the unbuffered delay-v43 load law), 48-bit replicated
AND mask 16.4, `({64{s}}&a)|({64{!s}}&b)` 6.0 (128 loads cross the cap
and switch to the buffered law -- a cliff, recorded as an open model
item). Consequence for the 8 FO4 objective: under this load law every
64-bit 2:1 select is >= 23.5 FO4, so no 64-bit datapath can read under
8; the structural comparisons stay valid same-instrument, the absolute
distance to 8 is a calibration question for the host (unbuffered vs
repaired-netlist law), not an RTL one.

## Settled RTL program (r89/r90), one exact change per cone first

- load_unit: `ex_pend_set` reads the next-cycle flush vector; the file's
  own `ex_pub` precedent (L1437) shows the reduction for a valid slot
  (`!flush_i && !flushed_q && !cancelled_mask_i[tid]`; new_hit
  unreachable, hold covered). Keeps the LDBUF_FALLTHROUGH form.
- g6lc_rename_read: `ckpt_slot` / `do_ckpt` / `br_over` at LVL_W+2 bits,
  modulo as a slice when CKPT_PER_HART is a power of two (A140).
- g6lc_lsq: `lane_be` as a 32-entry constant table and hoisted out of the
  guarded pair scan (the file's own L1183 `s_be[s]` pattern, A135).
- serdiv: plain 65-bit subtract for the digit step (the model bills the
  64-bit adder ~14 vs carry-select 13.1 + 24.0 select) and the +/-a load
  moved from NORM to the accept cycle so the recurrence mux has one arm.
- g6lc_ai_exec: `rq_bump` as an add operand (not a 48-bit select), the
  clamp compares in parallel, ST_RQ_R split into two phases (+1 cycle per
  requant element), and the MMA lane product as the user's r27/r28
  row/CSA form (9x9 signed, exact for all four dtypes -- note F17 below).
- g6lc_shared_tlb: constant-gate the flush walk / tag update on
  `UseSharedTlb`; one-hot registered flush kind for the match select.

F17 (functional finding, g6lc_ai_exec): the hyp8 U8xU8 MMA lane product
is `32'(signed'(16'(...)))` -- products >= 32768 (e.g. 200x200) are
sign-extended negative, while the reference `core/cvxif_g6lc_ai/
g6lc_ai_exec.sv:573` computes `32'(mac_au * mac_bu)` exactly. The exact
9x9 form fixes it; the exec leaf gets a 255x255 case.
