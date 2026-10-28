# AI island + Xg6lcai (ai-matrix) FO4 program — rewrite and measurement plan

## r31–r39 queue

Nine consecutive single-module tasks with owner paths, mechanisms and
gates: [nine-module-r31-plan.md](nine-module-r31-plan.md).

## r30 plan — subcode

Nine path families with owners and mechanisms, caller contract and impact:
[subcode-r30-plan.md](subcode-r30-plan.md).

## r28 — exec requant

exec **62.55→26.07** (wired-row carry-save product, parallel polarities);
island maximum desc_engine 63.35. See [worst-modules-r28.md](worst-modules-r28.md).

## r27 — exec

dot4 products **56.0→22.4** (row trees, landed); requant carry-save
countercase (80.5) reverted; exec maximum 62.55. See
[worst-modules-r27.md](worst-modules-r27.md).

## r26 — landed from the worst-five plan

codec **59.30→39.40**, inval_queue 52.25→46.54, subcode 62.24→60.34; island
maximum desc_engine 63.35. See [worst-modules-r26.md](worst-modules-r26.md).

## r26 plan — worst five, callers and mechanisms

Analysis only: [worst-five-r26-plan.md](worst-five-r26-plan.md) maps each
module's execution paths, caller contract, the transform per path and its
latency/throughput/verification impact, plus the over-budget path counts
that define the remaining distance to 8 FO4.

## r25 — subcode COST stage

subcode **78.92→62.24**; island maximum desc_engine 63.35. See
[worst-modules-r25.md](worst-modules-r25.md).

## r24 — worst non-GEMM modules

pe_dot **128.37→45.80**, codec **85.80→59.30**, subcode 80.26→78.92 by
exact operator narrowing; exec unchanged (attempt reverted). See
[worst-modules-r24.md](worst-modules-r24.md).

## r23 — carried receive facts, static bank-write routing

Frozen board GEMM **55.80→48.70** including a registered operand-bank read
stage; FP stages 46.25/37.70; store plan 28.50. Remote gates pass (DPF=0
golden 1394→1401). Remaining owners: the accumulate-mode seed read on the
latency-0 C bank and the receive count select. See [gemm-windows-r23.md](gemm-windows-r23.md).

## r22 — interleaved two-set accumulator, two-stage FP adder

Matched frozen board: GEMM **61.50→55.80**; FP align/norm stages
**37.70 / 46.25** (was one 75.00 cycle); store plan 28.50; span 18.30.
Dependent FP additions are two cycles apart by construction; issue rate is
unchanged for n ≥ 2·cols_eff. Focused remote gates pass.
See [gemm-windows-r22.md](gemm-windows-r22.md).

## r21 — sign-magnitude FP, commit token, registered sequencer facts

Matched frozen board: GEMM **73.50→61.50**, FP **94.93→75.00**, store plan
**39.80→28.50**; span 18.30. The FP leaf stays a one-cycle recurrence with
parallel magnitude sums; C publication and credit follow a commit token one
edge after the last partial. Focused remote gates pass with the extended FP
corner miter. Rejected: an LB-side B-skip decision (PMU phase contract).
See [gemm-windows-r21.md](gemm-windows-r21.md).

## r20 — load-terminal facts and constant operand layouts

Matched delay-v45 board: GEMM **98.00→73.50 FO4**. FP remains **94.93**,
store-plan 39.80 and span 18.30. No MAC cycle added; matched DPF=0 golden
remains 1344 cycles. Isolated remote backend, accumulation, signed/protocol,
reuse, stripe, cluster and wide checks pass, with old-expression comparisons.
Generic lint/synth still fail the hyp configuration lookup. See
[gemm-windows-r20.md](gemm-windows-r20.md) for snapshots, hashes and caveats.

## r19 follow-up — internal stitch audit

The fresh full IR reproduces r19, but the internal 132.75/114.50/111.25 rows
all append operand-gather path 1297 to unrelated child outputs. These are
module-path summaries, not connected timing paths or reliable upper bounds.
The 92.95 region is operand-format gathering, not AR presentation.
See [gemm-internal-stitches-r19.md](gemm-internal-stitches-r19.md).

Next candidates: prepared load-terminal facts, constant operand wiring,
parallel FP rounding, C publication from the existing accumulator register,
and bounded store geometry/prepared B successors. Arithmetic identities have
bounded witnesses; none is an implemented or measured r20 gain.

## r19 — GEMM functional windows implemented

Final `analyze-ai-hyp-r19`: GEMM **119.50→98.00 FO4**, with new FP32,
residency-span and C-store-plan leaves at **94.93 / 18.30 / 39.80**.
The existing iterative multiplier is 20.00 and is now included in the
timing closure. Matching baseline: `r19-before-complete`.
Dispatch→GEMM improves 153.80→127.25; top→GEMM 157.05→130.50.
New internal stitches remain over budget (up to 132.75).

Backend, accumulate, signed/backpressure, 100k FP value/flag comparisons,
reuse slots, single/two/four clusters, 128/512-bit stores and NCH=1/2 stripe
checks pass. Canonical lint/synth remains blocked on the hyp config lookup.
The additional preparation and W-beat startup latency is explicit. Independent
fetch/retire cursors permit full-rate W refill; MAC recurrence latency is
preserved. See [gemm-functional-r19.md](gemm-functional-r19.md)
for ownership, transform derivations, commands, hashes and readiness limits.

## r18 — current worst two reduced

Fresh `analyze-ai-hyp-r18-before` selected GEMM and cluster dispatch.
Final `analyze-ai-hyp-r18`: **172.2→119.5** and **150.5→34.3** structural FO4.
Seed capture uses the existing sum window; dispatch owns a staged descriptor
prologue. Caller stitches dispatch→GEMM and top→dispatch improve to
153.8 / 71.85; top→direct GEMM stays 157.05.

Assertion-enabled backend and 112 accumulate checks pass in each DPF=0/2
profile. Single/two/four-cluster mathematical goldens pass all three shapes.
The old integer column-slice counterexample is fixed (C-bank shift/add
precedence). Seed-product and load-completion joins now retain either arrival
order. The aggregate host verify attempt failed on configuration/tool setup.

Details, exact commands, source hashes, latency tradeoffs, warnings and
remaining qualification limits: [worst-two-r18.md](worst-two-r18.md).
This supersedes older board/status paragraphs below; 8-FO4 closure remains open.

## r17 — policy caller split implemented

The wrapper now owns request capture and coherent codec/topology publication;
new topology and PMU publisher leaves implement the arithmetic and completion
joins. Slot values retain four bits, flush kills pipeline tokens, and the
island gates admission so its request pulse cannot be lost. The default
service product is removed by the proved bound; a bounded exact shift/add
fallback preserves custom parameters. Balanced selection uses fifteen
constant candidates and registered tournament levels.

Board `analyze-ai-hyp-r17`: steer 165.0→27.25 FO4; topology 27.8; publisher
8.0; codec/subcode remain 85.8/80.3; island_top remains 43.9.
Strict focused lint and the policy pipeline contract bench pass (5,568
topology checks, 23 publications, 29 cancellations, three PMU orderings).
Full hyp island DMA smoke passes GEMM and policy snapshots. Details, source
contracts and limits are in `policy-steer-caller-split.md` and the r17 log.
These are structural results, not whole-island 8-FO4 or STA closure.

## r16 update — GEMM implementation and policy caller analysis

`g6lc_ai_gemm_seq` now uses a hand-written functional control split, with
independent AR, R/bank-write, C-store, MAC and job-state owners. Three AXI
boundaries use five independent spill channels (AR, AW/W, R/B), controlled
by `AxiCuts` (default enabled). A local five-step operand-burst preparation
window holds one plan until AR acceptance; allocation and receive metadata
remain owned by the sequencer. The previous control is available only under
`G6LC_AI_GEMM_LEGACY_CONTROL` for ablation, with snapshots in `analysis/tools/zips`.

Fresh full board: `analyze-ai-hyp-r16.json`. GEMM's reported intoout maximum
fell from 171.15 to 119.5 and regtoout from 170.3 to 20.25, but regtoreg is
172.2 (previous 170.3). **The module maximum did not improve.** Its leading
dependency now includes the C seed-read / FP accumulator path. The C-store
arithmetic has been separated from channel/control logic; a dedicated
registered store planner and a staged receive decoder are still open.

The final `nch=1,dpf=0` backend golden passes: 1041 cycles, 28 AR,
106 R beats, 16 golden C checks, four equivalence counters at 1034.
The earlier split-plus-cuts snapshot also passed at 934 cycles before the
operand planner was added. Historical unsplit baseline: 956 cycles.
No multichannel, pipelined-dot, multicluster, full-island or formal
qualification is implied by this focused run. Verilator reported no new
sequencer latch/multiple-driver errors; pre-existing comb PE latch warnings
remain in this source closure.

The requested policy analysis is in
[`policy-steer-caller-split.md`](policy-steer-caller-split.md). It identifies
the telemetry caller contract, four-bit slot truncation, missing alignment
of the codec work pulse with topology, a parameter-proven removal of the
service multiplier, and a 15-candidate parallel alternative to the serial
balanced-shape calculation. Policy RTL is unchanged; those are proposed
transforms, with mathematical checks rather than post-rewrite timing claims.

Correction to earlier seam prose: final8 and r16 both report policy stitches
156.84 / 177.64 / 181.18 FO4, **not all <=40**. Their broad bridge lists include
unconnected formals, so use source-verified caller connections alongside
these structural estimates. No physical 8-FO4 closure is claimed.

Lead-authored 2026-10-26. Scope: every `g6lc_ai_*` module — the SoC island
(`corev_apu/ai_island/`, `corev_apu/src/g6lc_ai_dram_*`, `corev_apu/include/g6lc_ai_island_cfg_pkg.sv`)
and the core-side CVXIF ai-matrix unit (`core/cvxif_g6lc_ai/`). Method and honesty gate as
`execution-path-plan.md` §5/§5b and `r69-fo4-program.md`: structural FO4 (delay-v44) at the
8.0-FO4 budget (5 GHz nameplate, fo4_ps=20, margin 0.2) is a **screening objective, never a
physical claim**; adjusted/structural is ~3× on Nangate45 (A121/A146). Rank 0 = representation
only (no cycle, no contract; verified by an in-DUT equivalence reference + the module's bench);
rank 1 = a register whose both-end ownership is written first (latency table + bench + golden);
rank 2 = caller contract change with a config knob.

## 0. Trees, board of record, procedure

- **Tree of record = the hyp workspace** (user decision 2026-10-26, superseding the first draft's
  production-tree choice): `hyp_redesign_corev_apu_8fo4/corev_apu/{ai_island/, src/g6lc_ai_*.sv,
  include/g6lc_ai_island_cfg_pkg.sv}` and `hyp_redesign_core_8fo4/core/cvxif_g6lc_ai/` — the
  sv-timing output trees, exactly as the core program works in `hyp_redesign_core_8fo4/`. The
  production tree (`corev_apu/`, `core/`) is the functional reference and is not edited here.
  State of the hyp copies at program start: a 2026-10-20 sv-timing emit (`hyp8 provenance`
  header) plus manual rework — `g6lc_ai_exec` already carries a parallel dot4 (A1) and the
  ST_RQ/RQ_S/RQ_R requant split (A4); `pe_dot.sv` carries balance_mux credit comments — but
  functionally behind production (strip-CR deltas: gemm_seq 886 lines incl. r68 `DotPipeInt`,
  island_top 444, pe_dot_float_pipe 325, policy_subcode 236, cluster_dispatch 214, exec 477) and
  missing `g6lc_ai_fp_mac/fp_dot/cluster_set/cluster_tile`. `analysis/ai-tree-drift.md` records the
  per-file classification; production-only features are ported into hyp only when an item needs
  them (r68 `DotPipeInt` is ported in batch 1), each port named in the log.
- **Board of record:** `build/sv-timing/hyp8-src/boards/ai-island/analyze-ai-hyp-r0.{json,cmd,log}`
  on `inputs/ai-island-hyp.f` (`inputs/gen_ai_island_f.py --tree hyp`); the production-tree board
  `analyze-ai-r0` (`inputs/ai-island.f`) stays as the reference reading (§1 numbers). APU map
  `inputs/apu-compile/param-map.json`, `--all-modules --stages`. Per-item boards: same argv with
  `--modules <name>` → `boards/ai-island/analyze-ai-hyp-r<N>-<item>.json`; the batch-end board
  re-runs `--all-modules`. Tools: `inputs/clock_board.py`, `inputs/path_census.py`,
  `inputs/ir_hot_nodes.py` (with `--ir-out`).
- **Benches on the hyp tree:** the `verif/tb/ai_island/run-*.sh` scripts take
  `G6LC_AI_RTL_DIR` / `G6LC_AI_INC_DIR` / `G6LC_AI_SRC_DIR` (and the cvxif dir) overrides pointing at
  the hyp copies; unset = production, byte-identical behaviour. A hyp-tree bench failure at
  program start is a finding recorded in the drift file, not patched silently.
- **Keep/revert rule:** keep when the module's non-multicycle max falls and no module on the board
  rises; a rise anywhere, or a null (< 1 FO4), is a recorded countercase and a byte-exact revert.
- **Model-truth check (P6):** when a number collapses under a pure representation rewrite with no
  logic change (function inlining, loop guard removal, constant-index arrays), record it as a
  model over-read AND keep the explicit form — "write the depth you mean" (A140) is the RTL we
  want synthesis to see anyway. The pre-rewrite form stays under `translate_off` as the reference
  of an every-cycle equivalence assertion with a fire counter, plus one named mutant per item.
  **P6 finding (ai-hyp-r4 E2c):** delay-v44 composes every non-blocking write of one monolithic
  `always_ff` as a serial statement chain regardless of disjoint guards (island_top's 1047.9 was
  ~60 NBA writes × 3.5–28 FO4; node walk in the APU log). The physical truth is each register's
  own guard + data mux. Therefore the first rank-0 move on every remaining module is "one
  `always_ff` per register group / one `always_comb` per output family" (E2c: 719.1 → 63.5; the
  hoist form D6: 230.6 → 171.2), and an sv-timing fixture is owed for the composition rule.
  References/miters live in their own `translate_off` blocks, never inside a measured block
  (D4: a miter's temporaries inflated the LHS bundle +3.2 until moved).
- **Live-arm discipline:** the default SKU (`AiIslandLatencyDefault`, `AiCfgIsland`) has
  Clusters=1, DramChannels=1, CommandDepth=0, Policy*En=0, VaTurboEn=0, IslandFpEn=1, and the
  CVXIF unit (`g6lc_ai_exec`) is elaborated only under `g6lc64_ai*` core configs. Modules outside
  the default SKU (cluster_dispatch, policy_*, dram_backend/channels/join, cmd_fifo) are program
  items because other shipped SKUs instantiate them, but they rank after the default-SKU setters.
- **Verification surfaces** (Verilator, `verif/tb/ai_island/run-*.sh`; the r68 pipe used the local
  5.020): `run-pe-dot-pipe.sh` (vs comb oracle, Lanes 1/4/16/256), `run-pe-dot-float-pipe.sh`,
  `run-gemm-backend.sh` (goldens, nch=1,2,4,8; `dpf=0,1,2`), `run-gemm-wide.sh`, `run-gemm-stripe.sh`,
  `run-desc-island.sh`, `run-ai-island-dma.sh`, `run-inval-queue.sh`, `run-cluster-dispatch.sh`,
  `run-ai-island-policy-walk.sh`, `run-store-align.sh`, `run-cap-occupancy.sh`,
  `run-island-clusters-lint.sh`; core side `verif/regress/ai-matrix-directed.sh` +
  `ai-config-smoke.sh` (the 10/10 `ai-matrix-veri` set) and `verif/tb/core/run-iq-cvxif-head.sh`.
  Every landed item names the bench(es) that gate it and their pass line.
- Hygiene (r63 lesson): preserve each file's line endings and non-ASCII comment bytes; SPDX
  headers unchanged (tier R); no sim-only construct outside `translate_off`; `always_ff`/
  `always_comb` split; no new latch/clock/reset.

## 1. Census — `analyze-ai-r0` (module max, non-multicycle; what the IR says sets it)

| # | Module | FO4 | Kind / class | Mechanism (IR hot node) | SKU |
|---|---|---|---|---|---|
| 1 | `g6lc_ai_island_top` | 1047.9 | reg→reg plain, 108 nodes, :1325 | the monolithic `always_ff` priority chain — every `else if` predicate (cmd_dispatch → dma_quiet → …, `ai_queue_decode` with a `*32` and a `-`/`>>`, 64-bit `!= '0`) is billed in series into `fetch_*_q`; hottest single node only 34.5 | default |
| 2 | `g6lc_ai_gemm_seq` | 347.6 / 305.6 | bundle 115 LHS :1684; plain :763 | :763 `ai_flat_pitch_shift` 31-iteration loop-carried scan (295); :1684 AR issue chain `beat_align(a_ar_cur)`→`beats_for_rem`→`cap_beats_to_stripe`→`elems_for_burst` (170.5) where `a_ar_cur = pa + ar_i*stride + ar_t` (runtime 32×32 mul); `wbeat_at/wbeat_words` lane placement loops (147–165); `c_bank_addr` `i*KPerBank` (81–91); `lc_beats_q` `m_q*n_q` (89) | default |
| 3 | `g6lc_ai_exec` (ai-matrix) | 283.0 | bundle, max_field 280.5 :401/:407/:413 | `dot4_s8/u8` function: 4 serial (mul + add) in a loop-carried accumulate; ST_MMA K-loop 8 serial MACs (71.5 each); requant `s32×s16` (72.6); `c_elem = m*TileN + n` (27.6) | `g6lc64_ai*` |
| 4 | `g6lc_ai_policy_steer` | 178.0 | reg→out plain :163 | `policy_topology(...)` package function evaluated combinationally into `topology_o` | VaTurbo / Policy SKUs |
| 5 | `g6lc_ai_cluster_dispatch` | 150.5 | bundle :126 | `slice_cols(n)` = `/ Clusters` (constant divisor billed as div_rem 120) at job latch; `e_pb[c] = pb + col0*row_bytes_b` runtime mul (79) | Clusters>1 |
| 6 | `g6lc_ai_policy_codec` | 149.5 | dense control cone :106 | `policy_sparse_residue(sample)` (43.5) + `policy_encode` + state chain in one cycle | Policy SKUs |
| 7 | `g6lc_ai_pe_dot` (comb) | 128.4 | in→out exclusive :131 | 8×8 mul + 9-level 32-bit tree in one cycle — superseded by `g6lc_ai_pe_dot_pipe` when `DotPipeInt` | default when DotPipeInt=0 |
| 8 | `g6lc_ai_desc_engine` | 111.9 | bundle :178, fns=4 | `ai_operand_span` (68-bit mul) → `ai_bus_len` → `check_len_o` in the CHK_A/B state | default |
| 9 | `g6lc_ai_policy_subcode` | 96.4 | bundle :136 | sub-code evaluation chain | Policy SKUs |
| 10 | `g6lc_ai_inval_queue` | 52.3 | reg→out plain :85 | `aw_last_byte = addr + ((len+1) << size) - 1` → line1 − line0 → `tail_same` compare chain | DmaInvalEn (default) |
| 11 | `g6lc_ai_island_top` | 50.9 | exclusive 42 arms :1518 | `rdata_n` read mux with `ai_queue_decode` arithmetic in the arm select | default |
| 12 | `g6lc_ai_pe_dot_float_pipe` | 50.8 / 47.8 | in→reg :104; reg→reg :379 | S1 decode+`fp_dot_product` (mantissa mul) in one cycle; final `bfp_mant_exp_to_fp32` normalize behind the last tree level | default (IslandFpEn) |
| 13 | `g6lc_ai_pe_dot_float` (comb) | 47.1 | in→out :157 | comb float dot — superseded by the pipe | DotPipe=0 arm |
| 14 | `g6lc_ai_pe_dot_pipe` | 45.4 / 31.2 | bundle :128; exclusive :187 | M1 8×4 mul billed as an atomic 13-bit multiplier (41) behind the INT4 unpack mux; tree level: padded array + `if (i<N)` guard + copy loop (prep_arm 22.8) | default (DotPipeInt) |
| 15 | `g6lc_ai_cap_window` | 40.0 | exclusive 29 arms :82 | capability read mux | default |
| 16 | `g6lc_ai_desc_fetch` | 33.0 | bundle :137 | beat counter / word placement | default |
| 17 | `g6lc_ai_desc_engine` | 32.9 | bundle :324 | state machine next-state bundle | default |
| 18 | `g6lc_ai_pmu_rate` | 28.9 / 27.0 | bundle :1703; plain :1645 | rate arithmetic (`bytes*ClockKhz/cycles`) — check whether a divider survives | default |
| 19 | `g6lc_ai_dram_backend` | 27.5 | exclusive :62 | `ch_w_q` update | DramChannels>1 |
| 20 | `g6lc_ai_fp_mac` | 26.5 | in→out :53 | scalar FP MAC decode | bench/legacy |
| 21 | `g6lc_ai_dram_timing` | 24.3 | bundle :104 | timing counters | timing_en |
| 22 | `g6lc_ai_addr_check` | 20.0 | in→out :89 | 64-bit `base <= addr && addr+len <= limit` | default |
| 23 | `g6lc_ai_tile_sram` | 19.0 | in→out :117 | bank select | default |

Vendor modules on the board (`rr_arb_tree` 34.3, `axi_atop_filter` 28.7, `fifo_v3` 10.7) are
tier U — not edited; they are the island's floor once the `g6lc_ai_*` setters are below them.

## 2. Items, by module (design settled by the lead; implementation per batch)

### A. `g6lc_ai_exec` — ai-matrix CVXIF execute (283.0)

- **A1 (rank 0) dot4 as a product array + balanced tree.** One shared 4-product array for
  `AI_DOT4_S8 / AI_DOT4_U8 / AI_DOT4A_S8`: operands widened to 9-bit signed with the sign slot
  selected by opcode (`{sgn ? a[7] : 1'b0, a}`), four independent `logic signed [17:0] p[i]`
  products in their own `always_comb` statements, sum `(p0+p1)+(p2+p3)` (+ `registers_i[2][31:0]`
  as a fifth leaf for DOT4A, zero otherwise) — one 5-operand tree, result sign-extended to XLEN.
  Reference: the three old functions under `translate_off`, assertion `g6lc_ai_dot4_eq` fired
  every cycle the opcode is live; mutant `G6LC_MUT_AI_DOT4_SERIAL`. Expected 280.5 → ~56–60
  (one 9×9 product ≈ 36 + 5-operand CPA ≈ 16).
- **A2 (rank 0) ST_MMA K-reduction as parallel products + tree.** The `for kk` loop-carried
  `mac_sum` (8 serial MACs) becomes 8 independent products `mac_p[kk]` (operand sign slots from
  `mma_dtype_q`, product zeroed when `kk >= mma_K_q`) and one 9-operand tree
  (`mac_p[0..7] + mac_old` folded for `accmode != 00`), saturation (`2'b10`) on the 33-bit result
  as today. `mac_a_elem/mac_b_elem` are constants per kk once `TileN` is a power of two (assert
  at elaboration; `mma_m_q * TileN` → `mma_m_q << $clog2(TileN)`).
  **c_elem** (`mma_m_q*TileN + mma_n_q`) becomes a running counter `mma_cnt_q` (+1 per step,
  cleared with `mma_m/n`): (m,n) iterate row-major, so the count equals the product by induction —
  reference assertion `g6lc_ai_celem_eq`. Expected 283 → ~75 (products ~36 ∥, 9-operand tree ~22,
  saturate ~12).
- **A3 (rank 1, after A2 is measured) MMA two-stage MAC.** If A2 leaves the module ≥ 60, pipeline
  ST_MMA: stage P registers the 8 products (+ `acc_r_data` read issued for the element), stage S
  sums, saturates and writes the bank; the (m,n) iterator runs one step ahead so throughput stays
  one element per cycle and only the MMA latency grows by one cycle (busy_o already covers the
  multi-cycle). Ownership: `p_valid_q`, `p_elem_q`, `p_acc_q`, `p_mode_q` carried with the
  products; the ST_DONE transition waits for the last S write (`!p_valid_q`). Bench: the
  ai-matrix directed set (MMA goldens) + `ai-config-smoke`.
- **A4 (rank 1) requant two sub-cycles per element.** ST_RQ gains `rq_phase_q`: phase 0 registers
  `prod_q = aval * sc` (the 48-bit product alone, ≈ 64 FO4 as a multiplier operator — and the
  honest residual of this module: a 32×16 multiply is atomic in the model), phase 1 does the
  round/shift/clamp and the tile write. Requant latency per tile doubles (+64 cycles at 8×8);
  recorded in the latency table. Alternative kept as a countercase candidate: a shift-add
  sequential multiplier (16 cycles/element) — only if the whole-module clock must drop below the
  multiplier operator, which the default program does not require (see §4).
- **A5 (rank 0)** `setcfg`/`grant_setcfg` clamps, `poll_status`, `acc_r_req` exclusive arms are
  ≤ 12 FO4 already — no edit.

### B. `g6lc_ai_pe_dot_pipe` — the live INT8/INT4 MAC cell (45.4 / 31.2)

- **B1 (rank 0, latency-neutral) write the multiplier depth.** M1 becomes the operand unpack +
  partial-product rows: per slot `pp_lo[r] = b[r] ? (a << r) : 0` for r=0..3 (13-bit, sign-extended
  a), `pp_hi[r]` likewise for the signed nibble with the Baugh-Wooley sign row — registered as
  rows (AND level only, ~2 FO4 behind the unpack mux). M2 = two 4-operand sums (`p_lo`, `p_hi`;
  model ≈ 7.4 + 4.5 = 12) registered. M3 = `p = p_lo + (p_hi <<< 4)` masked by valid (16-bit add
  ≈ 8). Tree levels unchanged in count; **O2 is dropped** so LATENCY = 3 + LEVELS + 1 =
  LEVELS + 4 (the float-pipe contract and the sequencer's metadata pipe are unchanged — assert
  as today). Equivalence: the old two-multiplier M1/M2 form under `translate_off` computes
  `p_ref[s]` from the same registered operands and asserts `m3_q[s] == p_ref` every cycle
  (`g6lc_ai_pp_eq`); mutant `G6LC_MUT_AI_PP_SIGNROW` drops the sign row (INT8 negative × negative
  fails `run-pe-dot-pipe.sh`).
- **B2 (rank 0) tree levels as exact-width generate arrays.** Each `gen_lvl[l]` declares
  `logic signed [15+l:0] lvl_q [P2 >> l]` and reads `gen_lvl[l-1].lvl_q` directly (level 1 reads
  M3) — no WMAX-padded array, no `if (i < N)` guard, no copy loop. Expected 31.2 → ≈ 9–10 (the
  add alone). Bench: `run-pe-dot-pipe.sh` (Lanes 1/4/16/256), `run-gemm-backend.sh dpf=2`.
- **B3 (config)** `DotPipeInt` default: the comb `g6lc_ai_pe_dot` (128.4) stays as the oracle
  and the `DotPipeInt=0` arm; the live SKU selects the pipe (confirm `IslandCfg`/`gemm_seq`
  default and add it to `clock_exclude` as a non-live arm once confirmed).

### C. `g6lc_ai_pe_dot_float_pipe` (50.8 / 47.8) and `g6lc_ai_pe_dot_float` (47.1)

- **C1 (rank 1, internal)** split S1: register the decoded operands (`dec_a/dec_b` + fmt_ok +
  valid) in S1a, do `fp_dot_product` (mantissa multiply, exponent add, specials) in S1b; drop one
  of the existing alignment/output registers so LATENCY stays `$clog2(Lanes)+5` (the int pipe
  asserts equality). If no register can be dropped without changing the valid_o timing, the
  latency constant moves in both pipes and in `gemm_seq`'s metadata pipe together (one commit,
  one golden run) — rank 1 with the sequencer as the second owner.
- **C2 (rank 0)** the final `bfp_mant_exp_to_fp32` normalize: a leading-zero count written as a
  log-depth tree (common_cells `lzc` or an explicit function) and a single variable shift; the
  special-case select (`red_nan/inf/fin`) moved in front of the normalize as a late-select
  (A118) so the normalize cone is not serial with the 3-arm priority.
- **C3** the comb `g6lc_ai_pe_dot_float` stays the oracle (non-live arm).

### D. `g6lc_ai_gemm_seq` — the sequencer (347.6 / 305.6)

- **D1 (rank 0)** `ai_flat_pitch_shift` as a log-depth form: `row_words <= 1 ? 0 : 32 − clz(row_words − 1)`
  with a balanced `clz` written as a tree function in the cfg package (the package is the single
  statement the formal props are about — keep the loop form as the `translate_off` reference and
  assert equality in `gemm_seq` where `pitch_sh_c` is formed). 295 → ≈ 15. Also applies to any
  other `for s < 31` scan in the package (`ai_flat_*`).
- **D2 (rank 0, registered cursors = A134)** replace the multiplied address functions on the
  receive/issue/store cursors by cursor registers maintained at the index registers' update edges:
  `a_cur_q`, `b_cur_q`, `a_ar_cur_q`, `b_ar_cur_q`, `c_store_addr_q`, plus row-base registers
  (`a_row_base_q = pa + i*stride` advanced by `+stride` when `i` increments, reset to `pa` at job
  start) so every cursor is `row_base + t` (one 64-bit add) or an incremental `+step`. Each index
  write site (`i_q/t_q/j_q/ar_i_q/ar_t_q/ar_j_q/stc_i_q/stc_j_q`) gets the matching cursor write;
  the old functions stay under `translate_off` as every-cycle miters (`a_cur_q == a_addr(...)`,
  …) with fire counters. Same for `c_bank_addr(i, j)` → `i*KPerBank` (KPerBank is a parameter; if
  it is a power of two use the shift, else a `c_row_word_q` register advanced by `+KPerBank`) and
  `lc_beats_q`'s `m_q*n_q` (job-constant: computed once at start by a 32-cycle shift-add
  accumulator in the job prologue — the sequencer already has a start→first-AR gap; record the
  added cycles; alternative if the prologue has no slack: keep the multiplier registered on its
  own and accept the operator floor for that one register).
- **D3 (rank 1) one-cycle-ahead AR candidate.** After D2 the AR chain is `addr = row_base + ar_t`
  → `beats_for_rem` → `cap_beats_to_stripe` → `elems_for_burst` → `ar_t + elems >= k_bytes`. Register
  the candidate `{ar_addr, ar_len, ar_elems, ar_row_last}` for the current `(ar_i_q, ar_t_q)` one
  cycle after those registers change (`ar_cand_valid_q`), and offer `ar_valid` only when the
  candidate is valid. Throughput: at most one AR per two cycles per engine — never the limiter
  for bursts ≥ 2 beats (`MaxBurstBeats` default and `k_bytes ≥ 16` on the goldens; record the
  k=8 corner in the bench's cycle counts). Both A and B AR paths. `k_rem_q = k_bytes − ar_t_q`
  maintained incrementally. Equivalence: the registered candidate equals the live function of the
  same cursor values (miter under `translate_off`).
- **D4 (rank 0)** `wbeat_at` / `wbeat_words`: the per-byte placement loops (`at = lane + i`,
  dynamic `b.data[8*at +: 8]`) become one barrel shift of the payload and of the strobe by
  `lane*8` / `lane` (`shift_var` ≈ 14 at 64 bits) — exact for the aligned pairs the comment
  describes; reference loop under `translate_off`.
- **D5 (rank 0)** `cap_beats_to_stripe/cap_nbeats_to_stripe/cap_c_nbeats`: `dram_beats_in_stripe`
  has a `/ beat_bytes` arm behind a power-of-two test — make the shift the only form (assert
  power-of-two at elaboration) and compute the stripe remainder as `~addr[shift-1:0] + 1` style
  mask arithmetic (no 32-bit subtract on a runtime address); `NrChannels == 1` → constant 255 arm
  is already exclusive (default SKU).
- **D6** the 115-LHS `always_comb` (:1684 bundle) — after D1–D5 re-measure; if the makespan is
  still the bundle floor, split the block per output family (AR issue / R receive / store) so each
  LHS bills alone (the r69 P4 conclusion for decode_s3) — representation only.

### E. `g6lc_ai_island_top` (1047.9 / 50.9 / 48.6)

- **E1 (rank 0)** queue decode as constant compares: `ai_queue_decode` keeps its signature but is
  rewritten as a generate-friendly form — hit/q/word from `addr[15:5]` matched against the
  constant window of each queue (`REG_OFF_QUEUE` for q0; `REG_OFF_QUEUE_TAIL + (q−1)*32` is a
  constant per q under a `for q < nqueues` with `nqueues` a parameter → the loop is elaboration-
  constant; the `*`/`-`/`>>` on the runtime address disappear). Reference under `translate_off`.
- **E2 (rank 0)** the fetch/submit `always_ff` block (L1260–1415) split into per-register-group
  blocks fed by named, mutually exclusive predicate wires computed once in an `always_comb`
  (`fetch_arm_cmd_ok / fetch_arm_cmd_refuse / fetch_arm_sb / fetch_arm_sb_refuse / fetch_arm_db_ok /
  fetch_arm_db_refuse`, each already containing the negation of the earlier arms so the `if/else if`
  becomes a `unique case (1'b1)` over one-hot arms — `g6lc_ai_fetch_arm_oh` asserts `$onehot0`).
  `fetch_error_fire/fetch_refuse_fire` sums narrowed to `CplCountW+3` bits (five 1-bit terms +
  `cpl_count`). The MMIO write decode (`addr_i == 16'h0100 …`) becomes a one-hot address class
  vector formed once and shared with `rdata_n`.
- **E3 (rank 0)** `rdata_n` 42/48-arm read mux (:1518): the address-class one-hot from E2 drives
  a masked-OR gather (A104) instead of a priority `case`; the queue-slot read uses E1's decode.
- **E4** `sb_imm_submit`, `dma_quiet`, `cmd_dispatch` cones (≤ 26 FO4) — covered by E2's shared
  predicates; measured together.

### F. Policy blocks (Policy SKUs): `g6lc_ai_policy_steer` 178, `policy_codec` 149.5, `policy_subcode` 96.4

- **F1 (rank 1)** `topology_o` registered (`topology_q <= policy_topology(...)` when `code_o` or
  the metadata changes; `topology_valid_q`) — the consumer is `gemm_seq` at job start: the one-
  cycle delay is absorbed by issuing the steer one cycle before the job (check the handshake in
  `island_top` L938–1046 and the `tb_g6lc_ai_policy_steer` expectations; if the bench samples
  `topology_o` the same cycle, the bench is updated with the latency table, not the contract).
- **F2 (rank 1, internal)** codec pipeline: features stage (`policy_bucket`, `sparse_residue`)
  registered → encode/vote stage. The `accept = valid_i && ready_o` handshake keeps one sample per
  cycle; prediction output moves one cycle (advisory path).
- **F3 (rank 0)** `policy_sparse_residue` / `policy_encode` / `policy_topology` package functions:
  census of their operators (`ir_hot_nodes`), then the same moves (loops → trees, products by
  constants → shift-adds). Measured per function on the steer/codec boards.

### G. Default-SKU control modules

- **G1 (rank 0)** `g6lc_ai_desc_engine` :178 `check_len_o`: the span (`ai_operand_span`, a 68-bit
  product of `rows−1 × stride_bytes`) is a per-descriptor constant — compute it once when the
  descriptor is latched (a `ST_SPAN` prologue state or a registered `span_a_q/span_b_q/span_c_q`
  formed in the cycle after `desc_q` loads; the engine has ≥ 1 cycle between latch and CHK_A), and
  present `check_len_o` from the register (rank 1 only if the extra state is needed; latency
  recorded). `ai_bus_len`'s `/`? — check; make it a shift.
- **G2 (rank 0)** `g6lc_ai_inval_queue` :85: `aw_last_byte` from `((len+1) << size) − 1` is
  `(len << size) | ((1 << size) − 1)` (no adder before the shift); `aw_nlines` compares on the
  line fields only; `tail_same` reads a registered `tail_line_q/tail_nlines_q/tail_nb_q` copy of
  the tail entry (written at push) instead of the dynamic `q_q[tail_idx]` read (A134).
- **G3 (rank 0)** `g6lc_ai_cap_window` :82 `rdata_n` 29 arms → one-hot class + masked OR (A104).
- **G4 (rank 0)** `g6lc_ai_desc_fetch` :137 / `g6lc_ai_desc_engine` :324 next-state bundles:
  exclusive arms with parallel values (A22); decodes at the source.
- **G5 (rank 0/1)** `g6lc_ai_pmu_rate` :1703/:1645: census first — if a divider forms the
  milli-GB/s figure, it becomes a sequential (one bit per cycle) divider after job done (the PMU
  value is read by software long after `gemm_done`; `pmu_rate_valid` already exists).
- **G6 (rank 0)** `g6lc_ai_addr_check` :89: `base_i <= addr && (addr + len − 1) <= limit` → the
  carry-out formulation (`addr + len` computed once as a 65-bit sum shared by both compares) —
  census says 20.0 = two 64-bit operations in series; expect ≈ 13.
- **G7** `g6lc_ai_tile_sram` 19.0, `g6lc_ai_dram_timing` 24.3, `g6lc_ai_dram_backend` 27.5,
  `g6lc_ai_fp_mac` 26.5: census then A22/A135 forms; `fp_mac` is bench/legacy — lowest.

### H. `g6lc_ai_cluster_dispatch` (Clusters>1 SKUs, 150.5)

- **H1 (rank 1)** job prologue FSM replacing the one-cycle `start_q`: cycle 1 `slice_q` (Clusters
  is a power of two by the island assertion → `>> $clog2(Clusters)` + align mask, no divider);
  cycles 2..C+1 `e_pb_q[c] = e_pb_q[c−1] + slice_rb_q`, `e_pc_q[c] = e_pc_q[c−1] + (slice_q << 2)`,
  `e_n_q[c]`, `e_active_q[c]` — one adder each per cycle; `slice_rb_q = slice_q × row_bytes_b` by
  a 32-cycle shift-add accumulator (first), so the engines start `34 + Clusters` cycles after
  `start_i` instead of 1. Latency table entry; `run-cluster-dispatch.sh` cycle counts re-baselined.
  Alternative (countercase candidate): keep the one multiplier registered and accept the operator
  floor for the dispatch.

## 3. Batches (development-efficiency order; one measurement per item, one bench gate per batch)

1. **Batch 1 — datapath cells + exec:** B1, B2, (B3 confirm); A1, A2, then A3/A4 by measurement.
   Benches: `run-pe-dot-pipe.sh`, `run-gemm-backend.sh dpf=2`, `ai-matrix-directed.sh`,
   `ai-config-smoke.sh`.
2. **Batch 2 — sequencer rank 0:** D1, D4, D5, D2 (cursors), D6. Benches: `run-gemm-backend.sh`
   (nch 1/2/4/8, dpf 0/1/2), `run-gemm-wide.sh`, `run-gemm-stripe.sh`, `run-store-align.sh`,
   formal `g6lc_ai_gemm_flat.sby` if the package function changes (D1).
3. **Batch 3 — island top + control:** E1–E3, G1–G4, G6. Benches: `run-desc-island.sh`,
   `run-ai-island-dma.sh`, `run-inval-queue.sh`, `run-cap-occupancy.sh`, `run-island-wide.sh`.
4. **Batch 4 — rank 1:** D3 (AR candidate), C1/C2, A3/A4 if not landed, G5. Benches as above plus
   `run-pe-dot-float-pipe.sh`.
5. **Batch 5 — other SKUs:** F1–F3, H1, G7. Benches: `run-ai-island-policy-walk.sh`,
   `run-cluster-dispatch.sh`, `run-dram-*.sh`.
6. **Close:** `analyze-ai-r<final>` all-modules board, hyp8 APU overlay mirror + flists,
   `AI-ISLAND-TIMING.md` §0 table rewritten from the boards (structural, not STA), todo paragraph.

## 4. What this program can and cannot reach (honesty gate)

Every multiplier the model sees is an atomic operator ≥ 33 FO4 (8×8) — the island's MAC cells
reach the budget only by writing the partial-product depth explicitly (B1), which is also the
form synthesis builds. Control modules can reach the 8–16 range by representation alone (E, G).
The sequencer's address arithmetic reaches ~10–20 by registered cursors (D2) and the AR
candidate stage (D3). `g6lc_ai_exec`'s requant multiplier and `cluster_dispatch`'s slice product
remain operator-floored unless made sequential (A4/H1 alternatives) — recorded, not implied.
None of this is STA; the paired Nangate45 reading (`adjusted`) is owed for retained items before
any frequency is quoted.

## §5 Results (ai-hyp program, final board analyze-ai-hyp-final2)

Structural delay-v44 FO4, 8.0 budget, 5 GHz target, hyp tree of record
(`hyp_redesign_corev_apu_8fo4` + `hyp_redesign_core_8fo4/cvxif_g6lc_ai`).
Boards under `boards/ai-island/`; argv of record
`analyze-ai-hyp-final2.cmd` (same as r0). "r0" = pre-program module max.

| module | r0 | final | delta | status |
|---|---|---|---|---|
| g6lc_ai_island_top | 1047.9 | **51.8** | −996 | E2+E2c+E4 landed; E2b/E1 neutral-kept; limiter `independent_lhs_bundle` :1857 (open) |
| g6lc_ai_policy_steer | 178.0 | **178.0** | 0 | F1 topology register OPEN |
| g6lc_ai_gemm_seq | 171.2 | **171.2** | 0 | D6 landed; D2b, D3/D3b reverted; AR arithmetic open |
| g6lc_ai_cluster_dispatch | 150.5 | **150.5** | 0 | H1 prologue FSM OPEN |
| g6lc_ai_policy_codec | 149.7 | **113.6** | −36.1 | r6 family split KEPT (policy-walk PASS) |
| g6lc_ai_pe_dot | 128.4 | **128.4** | 0 | open |
| g6lc_ai_desc_engine | 111.8 | **111.8** | 0 | G1 reverted; ST_SPAN sub-FSM owed |
| g6lc_ai_policy_subcode | 96.4 | **96.4** | 0 | open |
| g6lc_ai_inval_queue | 52.3 | **52.3** | 0 | G2 reverted (`tail_eq` caught real divergence) |
| g6lc_ai_pe_dot_float_pipe | 50.8 | **50.8** | 0 | C2 kept (fp_pkg or-fold); C1 reverted (fmt-3 gate) |
| g6lc_ai_pe_dot_float | 47.1 | **47.1** | 0 | open |
| g6lc_ai_cap_window | 40.0 | **40.0** | 0 | open |
| g6lc_ai_exec | ~35 | **31.6** | ↓ | B1+DotPipeInt landed |
| g6lc_ai_desc_fetch | 33.0 | **29.5** | −3.5 | G4 r_lane hoist landed |
| g6lc_ai_pmu_rate | 28.9 | **28.9** | 0 | G5 no-op (already sequential divider) |
| g6lc_ai_dram_backend | 27.5 | **27.5** | 0 | open |
| g6lc_ai_fp_mac | 26.5 | **26.5** | 0 | open |
| g6lc_ai_dram_timing | 24.3 | **24.3** | 0 | open |
| g6lc_ai_mul_seq | 20.0 | **20.0** | 0 | WA/WB form kept (leaf PASS 10/10) |
| g6lc_ai_addr_check | 20.0 | **8.5** | −11.5 | G6 65-bit shared end65 landed |
| g6lc_ai_tile_sram | 19.0 | **19.0** | 0 | — |
| g6lc_ai_dram_channels | 16.3 | **16.3** | 0 | — |
| g6lc_ai_island_apb | 14.4 | **14.4** | 0 | — |
| g6lc_ai_pe_dot_pipe | ~45 | **14.8** | ↓ | B1/B2 DotPipeInt landed |
| g6lc_ai_dram_join | 13.5 | **13.5** | 0 | — |
| g6lc_ai_enq_arb | 13.5 | **13.5** | 0 | — |
| g6lc_ai_cmd_fifo / cpl_fifo | 13.0 | **13.0** | 0 | — |
| g6lc_ai_mem_store | 11.5 | **11.5** | 0 | — |
| g6lc_ai_coprocessor | 9.3 | **9.3** | 0 | — |
| g6lc_ai_dram_timing L | — | — | — | see dram_backend |
| g6lc_ai_acc_bank / axi_cut / litedram_wrap | <2 | <2 | — | trivial |

### Gates of record (all PASS on the hyp tree)
- `PASS tb_g6lc_ai_gemm_backend nch=1-8 dpf=0,1,2` (956/1563/1638/1788)
- `PASS tb_g6lc_ai_desc_island` + `run-desc-island` (9 equiv counters @5096)
- `PASS run-island-wide`, `PASS run-inval-queue` (+oracle neg +mutant)
- `PASS tb_g6lc_ai_island_dma` (`eq checked=239`)
- `PASS pe_dot_float_pipe Lanes=8 checks=5028 latency=7` (`fpipe_eq 5055`)
- `[ai-island-policy-walk] PASS` + DMA 7339 cycles (`tree_eq 7329`)
- `PASS tb_g6lc_ai_mul_seq` 10/10; formal `g6lc_ai_gemm_flat_hyp.sby` 3/3
- store-align / gemm-wide / gemm-stripe PASS

### Rules added this program
- **P6 / rank-0**: one `always_ff` per register group; one `always_comb`
  per output family — the analyzer composes a monolithic block's
  statements as a serial chain (E2c: 719.1→63.5 on that diagnosis alone).
- **Lint-before-board**: `verilator --lint-only` the touched module BEFORE
  taking a board (sv-timing's parser accepted a type Verilator rejects).
- **Float-pipe gate**: `run-gemm-backend.sh` dpf=1 gates ANY
  `pe_dot_float_pipe` change (C1's Lanes=8 leaf passed while fmt-3 broke).

## §6 r7 program — caller-purposed segments, stages and windows (lead, 2026-10-27)

Caller map from `analyze-ai-hyp-final2.json` `instances` + `cross_module_paths` (port-bridged
stitches, upper bounds): `cluster_dispatch.i_eng:gemm_seq` 321.6 via `ready/done/err` →
`cluster_dispatch.reg1/D`; `island_top.i_policy_steer` 229.8 via `ready/work_valid/code`;
`policy_steer.i_subcode` 228.5 and `.i_codec` 227.8 via `ready/busy/valid/code`;
`island_top.i_gemm:gemm_seq` 223.0 via `ready/done/err`; `gemm_seq.i_pe_float(_pipe)` 218/217 via
`sum_o/flags_o/valid_o`; `gemm_seq.i_lc_mul` 191.2; `gemm_seq.i_tile_{a,b,c}` 190.2 via `r_data_o`
(tile read data runs combinationally to gemm_seq outputs); `i_pe_int_pipe` 183.3. Every one of
these is a child output consumed in a caller control/data cone in the same cycle. The island is
latency-tolerant at every one of these seams (job events, advisory policy, burst planning), so the
rank-1 move is uniform: **outputs are flops at module boundaries whose callers consume them in
a cone**, and the deep internal chains become **planner pipelines / multi-cycle windows** owned by
a segment module named for its caller purpose. Development-efficiency rules for this phase:
protocol changes are gated by the existing goldens only (gemm-backend 12 configs, desc-island,
policy-walk, inval-queue, cluster-dispatch, pe_dot leaves) — no new miters for rank-1 items, one
handshake-invariant assertion per changed seam instead; lint-before-board; one board per item.

| # | segment (purpose) | module(s) | design | rank | gate |
|---|---|---|---|---|---|
| R1 | job-event ports | `gemm_seq` `ready_o/done_o/err_o`, `cluster_dispatch` same, `desc_engine` `busy_o/last_status_o/wr_start_o/gemm_start_o/gemm_*_o`, `policy_steer` `ready_o/work_valid_o/code_o/topology_o` (= F1), `policy_codec`/`policy_subcode` `ready_o/busy_o/valid_o/code_o` | registered outputs (`*_q`), pulses as one-cycle-delayed pulses, `ready` as registered state; each valid/ready pair checked for same-cycle dependence (producer must sample ready at the edge it asserts valid; if a pair is combinationally coupled, keep that one ready combinational and register the rest) | 1 | goldens |
| R2 | AR burst planner | new `g6lc_ai_gemm_arplan.sv` (one instance per operand A/B) | owns the issue cursors (`ar_i/ar_t` for A, `ar_j/ar_t` for B); 3-stage pipeline S1 `{rem, lane, align_addr, stripe_room}` → S2 `{beats_for_rem, cap}` → S3 `{elems, row_last, next cursor}`; plans the next burst from its own S3 (`t+elems`, row advance) into a depth-2 candidate FIFO; gemm_seq's issue arm pops candidates (`addr,len,lane,elems,row_last`) | 1/2 | gemm-backend 12, gemm-stripe |
| R3 | C-store planner | `gemm_seq` store arm | same shape: S1 `{c_store_addr, nbeats, stripe cap}` → S2 `{wbeat data/strb placement}` registered ahead of AW/W; W data from the registered beat | 1 | gemm-backend 12, store-align |
| R4 | descriptor spans | `desc_engine` | **ST_SPAN** state between PARSE and CHK_A: first SPAN cycle (`prev_state_q != ST_SPAN`) kicks the three `g6lc_ai_mul_seq` (WA=32,WB=64 ×2; 32×32) from `desc_q` (valid since PARSE); sticky `*_seen_q` set by `done_o`, cleared on IDLE; SPAN→CHK_A when all seen; `span_*_q` latched at each done from `product_o` with the functions' saturation; CHK states read registers; translate_off `assert (check_len_o == f(desc_q))` in each CHK state with a counter | 1 | desc-island |
| R5 | policy windows | `policy_codec`, `policy_subcode`, `policy_steer` | codec: stage registers between the three r6 families (features → encode/vote → decodes), `ready_o` low for the 3-cycle window; subcode: same stage split by its own LHS families; steer: `policy_topology` as a multi-cycle evaluator (one `always_ff` FSM stepping the function's arithmetic over N cycles, `topology_valid_q`) | 2 | policy-walk |
| R6 | AW acceptance stage | `inval_queue` | register AW fields on accept (`aw_hold_o` while the stage is occupied), compute `aw_line0/1`, `nlines`, `tail_same` from the registered fields next cycle, push then | 1 | inval-queue |
| R7 | MMIO read/write classes | `cap_window` `rdata_n` (A104 one-hot masked-OR), `island_top` :1857 bundle (P6 split per register group / output family) | 0 | desc-island, island-wide |
| R8 | float cell stage | `pe_dot_float_pipe` S1 decode → product split with **LATENCY+1 in both pipes and gemm_seq's metadata pipe in one commit** (int pipe regains O2) | 1 | gemm-backend dpf=1,2 |
| R9 | dispatch prologue | `cluster_dispatch` H1 (program §2.H) | 1 | cluster-dispatch |
| R10 | requant window | `exec` ST_RQ round/clamp as one more phase (`rq_adj` 31.6) | 1 | exec_dot leaf |

Order: R1 → R7 → R4 → R2 → R3 → R5 → R6 → R8 → R9 → R10 (value per effort; R1 first because it
removes every port-bridged stitch at once and makes the per-module numbers the real numbers).

## Results — ai-hyp program through r7 (structural delay-v44, 8.0 FO4 budget, 5 GHz)

Boards: `boards/ai-island/analyze-ai-r0.json` (r0) /
`analyze-ai-hyp-final2.json` / `analyze-ai-hyp-final3.json` (r7 state).
Gates as logged in `analysis/implementation-log.md` `## ai-hyp-*`.

| module | r0 | final2 | final3 | §6 status |
|---|---|---|---|---|
| `g6lc_ai_policy_steer` | 178.0 | 178.0 | 184.0 | R1 landed (topology_q); R5 steer evaluator open |
| `g6lc_ai_gemm_seq` | 347.6 | 171.2 | 171.2 | R1 landed; R2 deferred (arplan written) |
| `g6lc_ai_cluster_dispatch` | 150.5 | 150.5 | 150.5 | R1 landed; R9 open |
| `g6lc_ai_pe_dot` | 128.4 | 128.4 | 128.4 | superseded by DotPipeInt |
| `g6lc_ai_policy_subcode` | 96.4 | 96.4 | 96.4 | R1 landed; R5 subcode open |
| `g6lc_ai_policy_codec` | 149.5 | 113.6 | 85.8 | r6 split + R5 window landed |
| `g6lc_ai_desc_engine` | 111.9 | 111.8 | 63.3 | R1 + R4 ST_SPAN landed |
| `g6lc_ai_exec` | 283.0 | 62.6 | 62.6 | landed (DotPipeInt + phase work); R10 open |
| `g6lc_ai_inval_queue` | 52.3 | 52.3 | 52.3 | G2 reverted; R6 open |
| `g6lc_ai_pe_dot_float_pipe` | 50.8 | 50.8 | 50.8 | C2 kept; C1 reverted; R8 open |
| `g6lc_ai_pe_dot_float` | 47.1 | 47.1 | 47.1 | open |
| `g6lc_ai_island_top` | 1047.9 | 51.8 | 43.9 | E-series + R7 splits landed; `rcls` mux open |
| `g6lc_ai_cap_window` | 40.0 | 40.0 | 40.6 | R7 A104 landed; occupancy idx limiter |
| `g6lc_ai_desc_fetch` | 33.0 | 29.5 | 29.5 | G4 landed |
| `g6lc_ai_pmu_rate` | 28.9 | 28.9 | 28.9 | already sequential (G5 no-op) |
| `g6lc_ai_dram_backend` | 27.5 | 27.5 | 27.5 | open |
| `g6lc_ai_fp_mac` | 26.5 | 26.5 | 26.5 | open |
| `g6lc_ai_dram_timing` | 24.3 | 24.3 | 24.3 | open |
| `g6lc_ai_mul_seq` | — | 20.0 | 20.0 | landed (WA/WB form) |
| `g6lc_ai_tile_sram` | 19.0 | 19.0 | 19.0 | — |
| `g6lc_ai_dram_channels` | 16.3 | 16.3 | 16.3 | — |
| `g6lc_ai_pe_dot_pipe` | 45.4 | 14.8 | 14.8 | landed (DotPipeInt) |
| `g6lc_ai_island_apb` | 14.4 | 14.4 | 14.4 | — |
| `g6lc_ai_enq_arb` | 13.5 | 13.5 | 13.5 | — |
| `g6lc_ai_dram_join` | 13.5 | 13.5 | 13.5 | — |
| `g6lc_ai_cpl_fifo` | 13.0 | 13.0 | 13.0 | — |
| `g6lc_ai_cmd_fifo` | 13.0 | 13.0 | 13.0 | — |
| `g6lc_ai_mem_store` | 11.5 | 11.5 | 11.5 | — |
| `g6lc_ai_coprocessor` | 9.3 | 9.3 | 9.3 | — |
| `g6lc_ai_addr_check` | 20.0 | 8.5 | 8.5 | G6 landed |
| `g6lc_ai_acc_bank` | 1.0 | 1.0 | 1.0 | — |
| `g6lc_ai_litedram_wrap` | — | 0.0 | 0.0 | — |
| `g6lc_ai_axi_cut` | — | 0.0 | 0.0 | — |

§6 rows: R1 landed · R2 designed/deferred (module written, wiring
deferred) · R3 open · R4 landed · R5 landed (codec; steer/subcode
designs remain) · R6 open · R7 landed · R8/R9/R10 open.

### §5 addendum — final4 (ai-hyp-r8, 2026-10-27)

Board `analyze-ai-hyp-final4`. Changes vs final3: policy_steer 184.0 → 165.0 (A134 evaluator, policy-walk PASS). R2 wiring reverted after the `ar=8` stall (planner module kept at 100.0, not instantiated); subcode COMPARE2 null reverted. Open: R2 integration, R3, subcode P6 split, R6, R8, R9, R10 — see `implementation-log.md` `## ai-hyp-r8 — close`.

### §5 addendum — final5 (ai-hyp-r9, 2026-10-27)

Board `analyze-ai-hyp-final5`. vs final4: policy_subcode 96.4 → 80.3 (P6 split, policy-walk PASS); R2 planner integration landed and was lost again (no snapshot of the green r2c file) — gemm_seq back at 171.2, arplan staged at 140.0; full history and the re-land recipe in `implementation-log.md` `## ai-hyp-r9 — close`. Open: R2 re-land, R3, R6, R8, R9, R10.

## ai-hyp-r10 (final6) — module summary

| module | r0 | final5 | final6 | r10 note |
|---|---|---|---|---|
| g6lc_ai_policy_steer | 178.0 | 165.0 | 165.0 | A134 evaluator kept |
| g6lc_ai_gemm_seq | 347.6 | 170.3 | 171.2 | R2 reverted (consumer-side) |
| g6lc_ai_cluster_dispatch | 150.5 | 150.5 | 150.5 | H1 open |
| g6lc_ai_gemm_arplan | -- | -- | 140.0 | uninstantiated (R2 reverted) |
| g6lc_ai_pe_dot | 128.4 | 128.4 | 128.4 | superseded |
| g6lc_ai_policy_subcode | 96.4 | 80.3 | 80.3 | P6 split kept |
| g6lc_ai_desc_engine | 111.9 | 63.3 | 63.3 | R1+R4 kept |
| g6lc_ai_inval_queue | 52.3 | 52.3 | 52.3 | R6 open |
| g6lc_ai_pe_dot_float_pipe | 50.8 | 50.8 | 50.8 | R8 open |
| g6lc_ai_island_top | 1047.9 | 43.9 | 43.9 | R7 kept |
| g6lc_ai_cap_window | 40.0 | 40.6 | 40.6 | R7 kept |
| g6lc_ai_exec | 283.0 | 62.6 | 31.6 | earlier |
| (rest <=29.5) | | | | |

r10: R2 re-land attempt -- miters silent (plan values correct), golden
`exp=16,16 got 0` persists; the fault is downstream (the receive/MAC
consumer assumed `ar_*_pre` timing). Reverted to the pre-r10r2 zips.
`analyze-ai-hyp-final6.json` is the board-of-record.

## §8 Method carry-over to the core program (r76, lead)

The core pass `hyp_redesign_core_8fo4/analysis/r76-program.md` adopts this
document's §0/§5/§6 rules as its method of record (rank classes, keep/revert,
lint-before-board, P6, caller-purposed stages, zip-before-edit). Results that
feed back into this program's card: the P6 bundle class is resolved by the
one-hot presentation form, not by a stage (`load_unit` 41.0 → 37.2 vs the
registered record 47.0, reverted); a correctness gate must be formed from a
registered/port superset of the deep decode (F15b); and an oracle's field
provenance is checked before any datapath is blamed (F14 was the RVFI
`mem_paddr` bus, not DRAM/atomics). Open island items (R2 consumer, R3, R6,
R8, H1, R10, the gemm_seq per-family split) are unchanged by r76.
