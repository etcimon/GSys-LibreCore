# T1 remaining modules — compact analyses (8-FO4 budget)

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


Each section: state/paths (from the original RTL), callers, separation into kernels (≤ 8 FO4, single-cycle) and stages, latency/throughput target, decision. Full-template files exist for `g6lc_iq`, `g6lc_lsq`, `scoreboard`, `g6lc_rename`, `frontend`, `wt_dcache_wbuffer`, `store_buffer`, `execute` (alu/branch/ex_stage/issue_read_operands/multiplier/mult), `csr_regfile`.

## load_unit (70.2 structural)

- **State/paths**: request FSM (IDLE → WAIT_GNT → SEND_TAG → WAIT_PAGE_OFFSET / WAIT_TRANSLATION / ABORT…), `load_data_q` response path (sign/zero extension, byte select by `address_offset`), tombstone table for killed tags (contract §1 LSU tombstones), non-idempotent head rule (§3: under OoO waits for `dcache_wbuffer_not_ni` and the *committed* store queue only), `lu_replay` to the scoreboard (T33: a load parked on a speculative store). Chains: translation result + PMP + store-buffer forward verdict + LSQ `stl_stall` → request/kill decision in one cycle; response: `rvalid` → byte select → extension → `result_o` + `ex_o`.
- **Callers**: `load_store_unit` (handshake), `wt_dcache` req port (valid/gnt, tag phase), `store_buffer` forward (now 3-cycle request/response), `g6lc_lsq` verdict (`ld_checked`, 3 cycles), MMU (`translation_valid`), scoreboard WB lane, `lu_replay`.
- **Separation**: L1 request issue (address/PMP/translation ready → `req`, 6 FO4 kernel-free), L2 tag phase (`tag_valid`, kill decision from registered translation exception — `ex_ptw` rule), L3 response wait (tombstones by tag), L4 data align (byte select 8:1 ≈ 3 FO4 + sign extension 3 FO4), L5 publish: AND of (data ready, `ld_checked`, forward merge from `stb_fwd` result) → WB lane; a load whose verdict is *wait/violation* is **replayed** (re-arm in the IQ via `replay`, result dropped) instead of stalling the pipe.
- **Latency/throughput**: load-use = D$ (today 2 + `DcacheHitExtra` 2) + publish 1 → +3 vs today in the hit case; throughput 1 load/cycle in flight per port (as the cache allows). The non-idempotent head rule unchanged (registered masks, conservative).
- **Decision**: `core/load_unit.sv` rewritten (ports + `ld_checked_i`, `fwd_req_o/fwd_rsp_i` to the store buffer, `replay_o`); `HypCfg.LoadUseExtra`. Kill: tag tombstones as today; `cancelled_mask` drops the publish; `flush` clears L1–L5 but tombstones stay.

## decode group — decoder (63.2), macro_decoder (52.9), id_stage (58.2), instr_realign (58.8), compressed_decoder (T2), instr_scan (T3), zcmt_decoder (T3)

- **Paths**: `instr_realign` (fetch block → instruction boundaries, carry-half handling) → `instr_scan` (class/length/immediate predecode for the predictor) → `instr_queue` → `id_stage`: `compressed_decoder` (16→32) → `macro_decoder` (push/pop macro expansion, Zcmp) → `zcmt_decoder` → `decoder` (full control word: fu/op/rs/rd/imm/exception/privilege legality from `priv_lvl`, `fs`, `vs`, `tvm/tw/tsr`, `debug_mode`) → `issue_entry_o` (the scoreboard entry). All combinational in→out today; one register at id→issue.
- **Callers**: scoreboard allocation (`decoded_instr_*`), the frontend (realign/scan are in the response path — see `frontend.md`), CSR legality inputs (registered state).
- **Separation**: D1 compressed expand + macro/zcmt sequencing (8 FO4), D2 opcode class + rs/rd/imm extraction (6 FO4), D3 control word + legality (privilege checks are compares against registered CSR state; 8 FO4) → registered entry. `instr_realign` as two response stages (boundary/carry-half, then alignment of ≤ 2 lanes); `instr_scan` one stage.
- **Latency/throughput**: decode +2 (front-end depth; cost in mispredict penalty only), 2 instructions/cycle sustained (as today); macro expansion stalls the lane as today.
- **Decision**: `core/id_stage.sv`, `decoder.sv`, `macro_decoder.sv`, `compressed_decoder.sv`, `zcmt_decoder.sv`, `fetch_B/instr_realign.sv`, `instr_scan.sv` rewritten as the staged forms; `HypCfg.DecodeStages` (1|3). Kill: `flush_i` clears D1–D3; the frontend epoch kill applies to realign/scan stages.

## g6lc_bp_ckpt (61.8), g6lc_freelist (60.6), g6lc_bp_gshare (49.0), ras (T2), g6lc_rat (T2)

- `g6lc_bp_ckpt`: checkpoint ring of predictor/RAS state captured per branch, restored on mispredict keyed by the branch's level (`tid_ckpt`); the 61.8 cone is the restore select + merge with same-cycle pushes. Separation: capture (stage), restore as a registered select (+1, inside the +2 resolve), epoch-keyed for the frontend overrides. Decision: rewritten; `HypCfg.FeEpochBits`.
- `g6lc_freelist`: PRF-wide lowest-free isolate (incrementer over 72–104 bits) + multi-port free. Separation: banked (2 banks per class, each half-pool; lane p picks from bank p), registered counts (`stall_o` from counts), free writes by id. Decision: rewritten as `g6lc_freelist.sv` (banked); `HypCfg.FreelistBanks`.
- `g6lc_bp_gshare`: index = hash(PC, ghist) → counter read → prediction; the 49 cone is hash + read + update merge. Separation: index registered (lookup is an override stage in the new frontend), update from the resolve record. Decision: rewritten (2 stages).
- `ras` (T2): speculative push/pop keyed by epoch with checkpoint; `g6lc_rat` (T2): late write + read bypass (see `g6lc_rename.md`).

## g6lc_tlb (55.5), g6lc_shared_tlb (43.5), g6lc_ptw (51.4), g6lc_mmu (T2), pmp (T3)

- **Paths**: TLB: tag compare (VPN, ASID, VMID, page-size masks for 4K/2M/1G) × entries → hit one-hot → PTE select → permission check (`priv_lvl`, `sum/mxr`, access type) → `translation_valid`/exception; PLRU update. Shared TLB: arbitration between I/D misses, hit path, refill from the PTW. PTW: walk FSM, address formation (`satp.ppn` + VPN slice × 8, a shift/add), PMP check per level, exception by level. MMU: wraps both, `lsu_exception_ptw_o` ownership (contract §3 T10g/N1d finding: a PTW fault belongs to the active walk, never to a DTLB-hit load in SEND_TAG).
- **Callers**: `load_unit`/`store_unit` (translation_valid, exception), frontend (I-side), PMP (`pmpcfg/pmpaddr` registered), `csr_regfile` (`satp`, enables).
- **Separation**: T1 tag compare (16–32 entries × 27-bit compare with masks ≈ 5 FO4) → hit one-hot registered; T2 PTE select (one-hot AND-OR, 3 FO4) + permission (3 FO4) → registered `translation_valid`; T3 PMP check (address range compares, registered). PTW: address formation split (shift + add as two steps), one state per cycle as today. Shared TLB arbitration registered.
- **Latency/throughput**: translation +2 on a hit (absorbed in `LoadUseExtra`/fetch depth); PTW walk latency +1 per level (PMP step). Throughput unchanged (one translation per port per cycle).
- **Decision**: all four rewritten; `HypCfg.TlbStages` (1|3). Kill: the N1d rule kept — the PTW exception record carries the walk owner; the load unit's tag kill reads the registered `ex_ptw`.

## g6lc_rob (49.2), g6lc_ooo_dispatch (36 structural / 100.8 adjusted)

- `g6lc_rob`: completion-by-tid shadow (`complete_valid_i` → entry done), retire by tid (frees by tid, not position), head re-anchor (A136 lowest-set form). Separation: completion from the registered WB records (scoreboard capture), retire from the commit bundle, head as 2-step lowest-set. Decision: rewritten; not the commit authority (unchanged).
- `g6lc_ooo_dispatch`: the container: `can_go` (registered counts only), `tid_*` side tables (prd/old/ckpt/is_st/is_fpr/fprd/fold/late_result) written at dispatch and read at WB/commit (`wb_prd = tid_prd_q[wb_id]`, `commit_prd = tid_prd_q[commit tid]`), PRF read for the IRO operands (`issue_op_*`), WB value gating (`wb_value_valid` = `!exc && !cancelled && class`), free/map commit events, memdep query, AGU/store-data live updates into the LSQ. The 100.8 adjusted cone: `tid_is_fpr_d → issue_valid_o` — the side-table write merges with the IQ grant through the FP read-port gate (`fp_port_sel`).
  - Separation: dispatch group register (from rename publish), table writes (stage), **IQ grant → payload read (registered) → PRF read (2 steps) → `issue_op_*`** — the FP read-port gate becomes a reservation in the IQ arbiter (an FP op is granted only when its read ports are free that cycle), WB gating from the registered WB lane records, commit events from the bundle.
  - Decision: rewritten as `g6lc_ooo_dispatch.sv` with the same ports plus the hyp8 seams (`replay`, `ld_checked`, lanes); the IQ/rename/LSQ/PRF/ROB/memdep instances follow their own files.

## serdiv (49.5), g6lc_icache (45.5), wt_dcache_missunit (44.5 → 36.9 with the packetized request), g6lc_rrip_repl (T2), aes (T2)

- `serdiv`: iterative radix-2 divider; the 49.5 cone is the quotient-digit select + subtract + shift per step. Separation: one registered step added in the compare/subtract (2 cycles per digit at 8 FO4 would double latency — instead keep 1 digit/cycle with a 32-bit split subtract: low half this cycle, high half next, pipelined across digits (carry registered)). Decision: rewritten; latency +1 overall; owner table (`mult.sv`) unchanged.
- `g6lc_icache`: tag compare + way select + data align in the response; token echo. Separation: tag compare (stage), way select + data (stage), response register → +1 behind the token (the frontend takes a response only on token match). Decision: rewritten.
- `wt_dcache_missunit`: FSM + MSHR + AMO handling + request packet (`mem_req_c`, now a port stage lands by protocol). Separation: keep the packetized elastic request stage (the emitted stage as the template); FSM next-state split (collision checks `mshr_rdrd_collision`, `amoResult` formation as registered steps). Decision: rewritten around the emit's structure; `mem_data_o` elastic.
- `g6lc_rrip_repl`, `aes`: T2 — replacement vector update registered; AES round split (SubBytes/ShiftRows stage, MixColumns/AddRoundKey stage).

## fpu_wrap (T2) and fpnew_* (parameters)

- `fpu_wrap`: operand marshalling + FPnew instantiation with `LAT_COMP_*`/`LAT_DIVSQRT`/`LAT_NONCOMP`/`LAT_CONV` and `PipeConfig: DISTRIBUTED`; owner table per tid (cancelled result suppression). Decision: rewritten wrapper with `HypCfg.FpuLatOverride` → FMA 8, NONCOMP 3, CONV 4, DIVSQRT iterative; `fpnew_*` vendor files untouched; the IQ latency class table reads the same values (FP ops are non-speculative wake if the latency is variable — DIVSQRT).
