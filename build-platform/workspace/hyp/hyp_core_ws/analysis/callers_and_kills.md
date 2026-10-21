# Cross-module ledger: ports that gain latency, their callers, and the kill identities every new stage joins

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


## A. Ports that gain latency in hyp8 (and what each caller does about it)

| Producer port | Added cycles | Callers (module.reader, kind) | Adaptation |
|---|---|---|---|
| `g6lc_iq.issue_valid_o/issue_sbe_o/issue_prd_o` | +1 (registered candidate) | `g6lc_ooo_dispatch` (payload read, PRF read), `issue_read_operands` (FU dispatch, `issue_ack`) | ack addresses the registered candidate; held until acked or killed; operand read is a stage anyway |
| `g6lc_rename.prs*/prd*/rs*_ready/ckpt_id` | +2 (R1/R2; publish R3) | `g6lc_ooo_dispatch` (IQ dispatch write, ROB/LSQ alloc, `tid_*` tables, memdep query) | dispatch consumes a registered group; `can_go` re-evaluated at publish from registered counts; the scoreboard slot (tid) was fixed at `issue_instr` time so the group's identity is stable |
| `scoreboard.commit_instr_o/drop/replay` → `commit_ack_i` | +1 (bundle) | `commit_stage`, `csr_regfile` (2 more), `store_buffer.commit`, `g6lc_lsq.commit_st/ld`, `g6lc_ooo_dispatch` (free/map/ckpt retire), `controller` (flush requests), `g6lc_rvfi_probes`, `perf_counters` | all read the bundle; side effects at t+1 (CSR t+2); the frontend redirect record takes trap/eret vectors |
| `scoreboard.cancelled_mask_o` | +1 (registered branch) | IQ (already registered, A112), LSQ (event registers carry ids; the mask is read at the slot write), PRF write gate (registered mask + registered-branch window), ROB, owner tables (`mult`, `fpu_wrap`), `lsu_bypass` pre-grant | every consumer compares a *registered* record against the mask; a WB landing in the resolve cycle for a to-be-cancelled op is dropped at the scoreboard capture (the capture is one cycle later than the WB) |
| `branch_unit.resolved_branch_o` | +2 | `controller` (flush_unissued/kill), `frontend` (redirect record), `scoreboard` (cancel), `g6lc_ooo_dispatch.mispredict_i/level` (rename restore), `g6lc_bp_*` training | all see it 2 cycles later; the `misp_outranked` ordering holds because the arch redirect is also through a registered record and is older by construction |
| `alu`/FU results → WB lanes | +1 (ALU 2-stage; staggered low half +0 for add/logic dependents) | scoreboard WB capture, PRF write, IQ wake (speculative countdown replaces the WB tag for fixed-latency classes), IRO bypass | lanes replace the FLU bus; IQ class table |
| `multiplier` | +4 (`MultStages` 8) | scoreboard/IQ/`mult` owner table | parameter co-emitted (`MultStagesOverride`) |
| `g6lc_lsq.stl_stall_o/stl_forward_o/mem_violation_*` | +3 | `load_unit` (publish gate `ld_checked`), `scoreboard` (cancel+replay), `g6lc_memdep` (train), IQ (`replay`) | load issues speculatively and publishes on `ld_checked`; violation replays as today plus the IQ re-arm |
| `store_buffer` forward | +3 (F1–F3 request/response) | `load_unit`/`lsu_bypass` | request at the load address, response merged at publish |
| `store_buffer.ready_o`, `commit_ready_o` | +1 | `store_unit`, `commit_stage` | handshakes |
| `wt_dcache_wbuffer.data_gnt` | +1 | `wt_dcache_ctrl`/store unit | handshake |
| `wt_dcache_wbuffer.wbuffer_data_o` | +0 visibility (pending record exported) | `wt_dcache_mem` byte merge, `wt_dcache_ctrl` hazard | both read DEPTH+1 entries |
| `wt_dcache_mem.rd_hit_oh_o/rd_data_o` | +2 (`DcacheHitExtra`) | `wt_dcache_ctrl` FSM, `load_unit` response | FSM states added; load unit L3/L4 |
| `wt_dcache_missunit.mem_data_o` | +1 (elastic port stage; already landed by the tool) | `wt_axi_adapter` request FIFO | absorbed by the FIFO (ready/valid) |
| `g6lc_icache` response | +1 | frontend response stage (token match) | token |
| `frontend` next-PC / FTQ push | restructured (line predictor) | `g6lc_icache` request (FTQ head), `instr_queue` | token/epoch |
| `instr_queue.fetch_entry_o` | elastic | `id_stage` | valid/ready |
| decode entry → scoreboard allocation | +2 | scoreboard `decoded_instr_*` | handshake unchanged in shape |
| `g6lc_tlb/shared_tlb` translation | +2 | load/store units, frontend, PTW | `LoadUseExtra`; walk owner record |
| `csr_regfile.csr_rdata_o/exception` | +1 after the op is presented | `commit_stage` | holds the CSR op 2 cycles |
| `csr_regfile.irq_ctrl_o`, trap vectors | +1 | commit / frontend redirect record | asynchronous events tolerate it |
| `g6lc_prf` read | +1 (2-step) | IRO (inside the payload stage) | — |
| `g6lc_hyp_rr_arb` grant, `g6lc_hyp_fifo` flags | +1 | AXI adapters, cache ports | handshakes |

## B. Kill identities and the stages that join them

| Identity (contract §3) | Source | New stages that must honour it | Rule |
|---|---|---|---|
| `cancelled_mask[tid]` (branch mispredict; sticky per slot + window) | scoreboard `sb_cancel` (registered branch) | IQ bank entries and arb candidates; IQ xbar wake records (a wake from a cancelled producer is harmless: it only sets `rdy`, the consumer itself is cancelled or will see the real WB); LSQ event/candidate/verdict registers; load unit L1–L5 (drop publish); store buffer speculative entries (verdict as today); WB lane records; scoreboard WB records; ROB completion records; rename groups in flight (via `flush_unissued`/mispredict, see below); PRF write gate | a record carries its tid; compare at the point where it would change architectural or wake state; never at every pipeline register |
| `flush_i` (exception, fence, CSR side effect, WFI) | controller (from the commit bundle, +1) | every pipeline register in the backend (IQ, rename R1–R3, dispatch group, LSQ pipeline, load/store stages, A1/A2/B1/B2, WB lanes, scoreboard records, commit bundle in flight); frontend (all), decode D1–D3; **not** LSU tombstones, committed store queue, write-buffer pending record (committed data) | clear; the controller's drain count = deepest stage count so a flush completes before refetch resumes |
| `flush_unissued_i` (mispredict: unissued work) | controller | decode D1–D3, scoreboard allocation, rename R1–R3, dispatch group | block allocation / kill groups not yet published; return free-list picks and checkpoint reservations exactly once |
| mispredict (`mispredict_i`, level) | dispatch from the registered `resolved_branch` | rename recover (`recovering_q` +1), bp_ckpt restore, frontend redirect record, RAS restore | older redirect in the gap wins by age (A147 invariant) |
| fetch token (2-bit) + **epoch** (new, `FeEpochBits`) | frontend | I$ request/response stages, FTQ entries, FDIP, `instr_queue` entries, realign/scan stages, override stages | a response is taken only on token match (as today); an entry/stage is dropped when its epoch is older than the current epoch after an override or redirect |
| replay (memory-order violation / `lu_replay`) | LSQ verdict (+3), load unit | scoreboard (`cancelled + replay` as today), **IQ re-arm** (new: `replay_o` tid → entries woken speculatively from that load, transitively through `spec_src`) | the replayed load's dependents are not cancelled (they stay in the window) — they are re-armed and wait for the real WB |
| `ld_checked` (new, M8) | LSQ publish | scoreboard commit bundle (a load without `checked` is not committable), load unit publish | conservative |
| non-idempotent device load at the head | load unit | unchanged rule on registered `no_st_pending`/`wbuffer_not_ni` | — |
| commit drop/replay | scoreboard bundle | commit_stage, RVFI | as today, one cycle later |
| hart handoff (drained) | thread select | unchanged (`ooo_drained_o` from registered empties) | — |
| CDC seam (APU) | `g6lc_hart.sv` | AXI `axi_cdc` on the core master; two-flop syncs on irq/ipi/timer/debug | same clock in the draft |

## C. Cut ledger (draft; finalized from `reports/board.md`)

REDESIGN-T1 (full files in this directory): g6lc_lsq, wt_dcache_wbuffer, g6lc_iq, scoreboard, g6lc_rename, csr_regfile, frontend, multiplier, fpu_wrap (+fpnew parameters), store_buffer, instr_queue, load_unit, decoder/macro_decoder/id_stage/instr_realign, g6lc_bp_ckpt/g6lc_freelist/g6lc_bp_gshare, issue_read_operands, g6lc_tlb/g6lc_shared_tlb/g6lc_ptw, branch_unit/alu/ex_stage, g6lc_rob/g6lc_ooo_dispatch, serdiv/g6lc_icache/wt_dcache_missunit.
REDESIGN-T2/T3: `tier2_tier3.md`.
COPY: modules the board puts at ≤ 8 (expected: controller [ADAPT drain], issue_stage, wt_dcache wrapper, g6lc_bp_top wrapper, shift_reg, lfsr*, stream_mux/demux, g6lc_hart_state, cvxif_* drivers, config packages, everything not instantiated by hyp8). `g6lc_core.sv` ADAPT (HypCfg threading, new seams).
