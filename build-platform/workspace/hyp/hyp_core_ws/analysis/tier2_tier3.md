# T2 (16–32 FO4) and T3 (8–16 FO4) — split decisions (8-FO4 budget)

<!-- hyp8-status -->
> **Status: indicative, subject to further information.** Goal: **8 FO4 per
> cycle (5 GHz nameplate at `fo4_ps = 20`, margin 0.2)**. Every FO4 figure,
> stage count and kernel size here is a hypothesis read from the original RTL,
> the prior boards and the sv-timing reports (`reports/board.md`,
> `cut_surface.md`, `bottlenecks.md`, `carry_over.md`, `propagation.md`,
> `refusals.md`); the fresh 8-FO4 board's deciding value `D` is in
> `analysis/cut-ledger.md` and `analysis/coverage.md`. The cut-minimization
> protocol (`analysis/cut_minimization.md`) takes precedence over any planned
> cut listed below. Nothing here has been linted, simulated or measured on a
> board; a rewritten file may follow this analysis, the emitted sv-timing file
> (as-is or adapted), or the original RTL, as `coverage.md` records.


Every row is a rewritten file in the hyp tree. Columns: worst chain (from the original RTL and the board), callers that see the change, the split, latency effect, kill identity, new file. The final membership comes from `reports/board.md` (fresh emit); rows for modules the board puts in another tier move with them.

## Tier 2 — restructure or 2–3 stage split

| Module | Worst chain | Callers affected | Split | Latency | Kill | File |
|---|---|---|---|---|---|---|
| `rr_arb_tree` (vendor) | request tree → grant → data mux | AXI adapter arbitration, cache ports | `g6lc_hyp_rr_arb`: registered grant (request this cycle, grant next), data mux after the grant register; `LockIn` semantics kept | +1 arbitration | handshake | `core/hyp_cells/g6lc_hyp_rr_arb.sv` |
| `trigger_module` | address/data match over triggers → `dcsr` action | commit/debug | match stage (reads the registered `*_q` trigger records — a CSR write to a trigger register is visible to matching +1 cycle later, safe because trigger CSR writes serialize the pipe ahead of any fetched use), action stage | +1 fire, +1 CSR→match visibility (debug semantics allow) | — | `core/trigger_module.sv` |
| `g6lc_mmu` | see `t1_rest.md` TLB group | LSU/frontend | wrapper around the 3-stage TLBs; `lsu_exception_ptw_o` ownership kept | +2 | registered walk owner | `core/g6lc_mmu/g6lc_mmu.sv` |
| `ras` | push/pop + checkpoint merge | frontend override | epoch-keyed speculative stack; restore registered | override path | epoch | `core/frontend/ras.sv` |
| `wt_dcache_mem` | tag read → compare → way select → data align → byte merge with `wbuffer_data_o` | `wt_dcache_ctrl`, load unit | tag compare stage, way/data stage (+`DcacheHitExtra`=2), byte merge reads the exported pending record | +2 hit | — | `core/cache_subsystem/wt_dcache_mem.sv` |
| `g6lc_prf` | read mux (PRF_N:1 × ports) + write-through bypass | IRO operand read, PRF mirror | 2-step read (bank then select), registered write with bypass compare at the second step | +1 operand read (inside the IQ payload stage) | WB gate on the registered cancel mask | `core/ooo/g6lc_prf.sv` |
| `axi_adapter`, `axi_adapter_arbiter`, `axi_shim` | request assembly (address/size/strobe), FSM, arbitration | cache subsystem ↔ AXI | registered request assembly (packet), elastic valid/ready on the AXI side (already the protocol), arbiter via `g6lc_hyp_rr_arb` | +1 request | handshake | `core/cache_subsystem/axi_adapter.sv`, `core/axi_shim.sv` |
| `cache_ctrl`, `miss_handler`, `tag_cmp`, `std_nbdcache` (if instantiated; WT config → NOT-IN-HYP8 expected) | — | — | copy or rewrite per the board | — | — | — |
| `ex_stage` | FLU merge (T1 in `execute.md`) | — | — | — | — | — |
| `commit_stage` | commit decision: exception/interrupt/CSR/fence/AMO/store commit in one cycle on `commit_instr_i` | scoreboard (ack), CSR, store buffer, controller, RVFI | consumes the registered commit bundle; decision at t+1, side effects at t+1/t+2 (CSR 2 cycles); `commit_ack` to the scoreboard registered; interrupt injection from the registered `irq_ctrl` | +1 commit | drop/replay as today | `core/commit_stage.sv` |
| `instr_decoder` (fetch_B) / `compressed_decoder` | decode group (`t1_rest.md`) | — | — | — | — | — |
| `g6lc_regfile_fpga` / `g6lc_regfile_ff` (in-order file; under OoO the PRF is the file — confirm instantiation) | read mux | IRO | registered read | +1 | — | `core/g6lc_regfile_ff.sv` |
| `csr_buffer` | two-entry per-tid address table (OoO), credit | IRO (CSR credit), commit | lookup registered; credit from registered counts | +1 | commit frees | `core/csr_buffer.sv` |
| `mult` | owner table + serdiv/multiplier mux | WB lane | owner table over 8-stage multiplier; serdiv result on its own lane | — | cancel suppression | `core/mult.sv` |
| `wt_dcache_ctrl` | FSM (IDLE/READ_WAIT/…) + hazard vs write buffer + tag result | load/store ports | FSM +2 for the hit latency; hazard compare against the exported pending record | +2 | — | `core/cache_subsystem/wt_dcache_ctrl.sv` |
| `g6lc_issue_barrier` | fence/barrier readiness over live masks | IQ legality | registered masks (conservative) | +1 | — | `core/ooo/g6lc_issue_barrier.sv` |
| `g6lc_loop_buffer` | hit detect + inject | frontend FTQ pop | registered hit, inject the cycle after | +1 inject | epoch | `core/frontend/g6lc_loop_buffer.sv` |
| `g6lc_bp_loop`, `g6lc_bp_ghist`, `bht2lvl`, `g6lc_bp_tage*`, `g6lc_bp_statcor`, `g6lc_bp_ittage` | index/hash → table read → vote; update merge | frontend override #2 | index stage, read/vote stage, registered verdict; update from the resolve record | override path (2 cycles) | epoch | `core/frontend/*.sv` |
| `lsu_bypass` | pre-grant queue + cancel retention + forward merge | load/store units | queue with registered pop; forward from `stb_fwd` response | +1 | tombstones as today | `core/lsu_bypass.sv` |
| `g6lc_rat` | map arrays | rename | late write + read bypass | — | restore | `core/ooo/g6lc_rat.sv` |
| `load_store_unit`, `store_unit` | AGU add + translation handoff + LSQ live updates | LSQ event register, store buffer insert | AGU low/high staggered add (2 stages), event handoff registered; store data path registered | +1 AGU | cancel by tid | `core/load_store_unit.sv`, `core/store_unit.sv` |
| `fpu_wrap`, `fpnew_noncomp`, `pa_fpu_dp` | see `t1_rest.md` | — | parameters | — | — | `core/fpu_wrap.sv` |
| `pmp`, `pmp_entry`, `pmp_data_if` | range compares (NAPOT/TOR) × 8 entries → allow | MMU/PTW/LSU | registered compare, allow next cycle (TLB T3 step) | +1 | — | `core/pmp/*.sv` |
| `g6lc_ftq` | push/pop/flush | frontend | epoch per entry | — | epoch | `core/frontend/g6lc_ftq.sv` |

## Tier 3 — one or two registered boundaries

| Module | Boundary | Latency | File |
|---|---|---|---|
| `zcmt_decoder` | table lookup registered | +1 (decode group) | `core/zcmt_decoder.sv` |
| `exp_backoff` | counter compare registered | — | `core/cache_subsystem/…` |
| `bht`, `btb` | index/read registered (override stage) | override path | `core/frontend/bht.sv`, `btb.sv` |
| `g6lc_smt_pc_bank`, `g6lc_thread_select` | drained-handoff seam; registered switch decision | +1 switch | `core/smt/*.sv` |
| `instr_scan` | predecode stage (frontend response) | +1 | `core/fetch_B/instr_scan.sv` |
| `g6lc_regfile` | registered read | +1 | `core/g6lc_regfile_ff.sv` |
| `acc_dispatcher` | accelerator request/response registers (CVXIF/accelerator off in hyp8: copy unless the board says otherwise) | — | — |
| `raw_checker` | hazard compare registered | +1 (in-order path only) | `core/raw_checker.sv` |
| `g6lc_rvfi_probes` | re-anchored to the commit bundle | +1 | `core/g6lc_rvfi_probes.sv` |
| `g6lc_memdep` | query registered (dispatch stage), train from the registered violation | +1 query | `core/ooo/g6lc_memdep.sv` |
| `g6lc_fdip` | epoch-aware flush, registered prefetch decision | — | `core/frontend/g6lc_fdip.sv` |
| `fifo_v3`/`g6lc_fifo_v3` → `g6lc_hyp_fifo` | registered `full/empty` (counts), data registered on push | +1 pop visibility | `core/hyp_cells/g6lc_hyp_fifo.sv` |
| `lzc`, `popcount` → `g6lc_hyp_lzc`, `g6lc_hyp_popcount` | split tree with a middle register where width > 32 | +1 | `core/hyp_cells/*.sv` |
| `amo_buffer`, `alu_wrapper`, `g6lc_way_predictor`, `g6lc_inval_retain` | one registered boundary at the output | +1 | per file |
| `fpnew_classifier`, `fpnew_opgroup_fmt_slice` | parameters (`fpu_wrap`) | — | — |
