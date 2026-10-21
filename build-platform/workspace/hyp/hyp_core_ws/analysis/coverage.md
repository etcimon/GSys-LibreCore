# coverage.md — redesign modules → analysis sections (fresh 8-FO4 board)

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

Provenance mode per rewritten file is decided in Phase 3 and recorded in `notes/decisions.md`: **AS-IS** (the emitted sv-timing file copied; closing modules), **ADAPTED** (the emitted file is the base, local edits for new latencies/seams — logic of the original RTL preserved verbatim where untouched), **REWRITTEN** (new file; the original RTL is the functional reference, the emit indicates where sv-timing found chains/refusals).

| module | decision | D | basis | min_cuts_est | analysis | section / note | mode |
|---|---|---|---|---|---|---|---|
| wt_dcache_wbuffer | REDESIGN-T1 | 137.1 | adjusted | 17 | wt_dcache_wbuffer.md |  | REWRITTEN (W1 match / W2 decision+select / W3 coalesce+write / 2-step drain; wbuffer_data_o exports the W3 record as youngest pending entry; registered data_gnt; pending-wtag evict hold) |
| frontend | REDESIGN-T1 | 128.2 | adjusted | 16 | frontend.md |  | REWRITTEN (+meta_d/rl2 staging; +hyp_fe_override{1,2}_o pulse exports) |
| g6lc_rename | REDESIGN-T1 | 115.1 | adjusted | 14 | g6lc_rename.md |  | REWRITTEN (R1 read / R2 resolve / R3 publish + state-recover; RenameStages==1 not reachable here; r4: FL_BANKS-banked free-list picks in R1; r5: recover = push-time slot_of_level table + one-hot restore select) |
| g6lc_iq | REDESIGN-T1 | 112.3 | adjusted | 14 | g6lc_iq.md |  | REWRITTEN (banked: bank/xbar/legal/arb/payload + wrapper; r5: bank SEL = registered wakeup CAM rsX_rdy/rsX_spec + LAT_ALU_LOW narrow bypass + countdown -1, arb = registered older_q age matrix + AND/OR tournament) |
| g6lc_lsq | REDESIGN-T1 | 104.2 | adjusted | 13 | g6lc_lsq.md |  | REWRITTEN (event/slot/cam_bank/age/reduce/verdict/release + wrapper; +ld_checked_o, +replay_valid_o/tid_o firing on violation AND load wait verdicts — speculative-wakeup re-arm) |
| multiplier | REDESIGN-T1 | 101.9 | adjusted | 12 | execute.md | multiplier | REWRITTEN (8 stages: operand-cond / 4x CSA compressor / 2x split-32 CPA / result+flags; trans_id+cancel tracked; r4: explicit 65-row AND partial products replace the atomic tile `*`, LPS=3) |
| scoreboard | REDESIGN-T1 | 101.2 | adjusted | 12 | scoreboard.md |  | REWRITTEN (wrapper + sb_lifecycle/sb_cancel/sb_head/sb_commit_bundle; +ld_checked_i, +commit_bundle_valid_o) |
| g6lc_ooo_dispatch | REDESIGN-T1 | 100.8 | adjusted | 12 | t1_rest.md | g6lc_rob (49.2), g6lc_ooo_dispatch | ADAPTED (registered rename group + staged issue/PRF-read seam; replay merge = OR + pending-TID mask, LSQ wait/violation and LSU-miss sources, bank-wide re-arm) |
| fpnew_cast_multi | REDESIGN-T1 | 91.6 | structural | 11 | t1_rest.md | fpu_wrap (T2) and fpnew_* (parameters) | AS-IS (latency via fpu_wrap PipeConfig/Latency parameters; vendor file untouched) |
| fpnew_fma | REDESIGN-T1 | 91.5 | structural | 11 | t1_rest.md | fpu_wrap (T2) and fpnew_* (parameters) | AS-IS (latency via fpu_wrap PipeConfig/Latency parameters; vendor file untouched) |
| alu | REDESIGN-T1 | 90.5 | adjusted | 11 | execute.md | alu | REWRITTEN (A1/A2/A3 staggered: A3 = shifter-2 + compare finalize + result mux for LAT_ALU_FULL; AluStages==3 semantics; alu_fwd_low_o + tid taps; AluStages==1 keeps the comb original) |
| store_buffer | REDESIGN-T1 | 90.1 | adjusted | 11 | store_buffer.md |  | REWRITTEN (stb_insert S1/S2, stb_fwd F1-F3, stb_commit, stb_drain + wrapper; +fwd_req_i/fwd_rsp_o) |
| csr_regfile | REDESIGN-T1 | 84.9 | adjusted | 10 | csr_regfile.md |  | REWRITTEN (banked C1 decode -> C2 read -> C3 write pipeline; csr_decode/csr_read/csr_write + csr_trap/csr_irq/csr_counters; csr_rdata_valid_o +1; r5: two-phase writer, 15 address-exclusive csr_wr_* phase-A blocks + phase-B overrides, csr_update_ref under translate_off) |
| aes | REDESIGN-T1 | 83.7 | adjusted | 10 | t1_rest.md | serdiv … aes | ADAPTED (round split: SubBytes/ShiftRows | MixColumns/AddRoundKey; result_o +1) |
| g6lc_loop_buffer | REDESIGN-T1 | 75.6 | adjusted | 9 | tier2_tier3.md | g6lc_loop_buffer | ADAPTED |
| g6lc_bp_ckpt | REDESIGN-T1 | 73.3 | adjusted | 9 | t1_rest.md | g6lc_bp_ckpt | ADAPTED |
| g6lc_rob | REDESIGN-T1 | 69.8 | adjusted | 8 | t1_rest.md | g6lc_rob | ADAPTED (2-step head re-anchor) |
| branch_unit | REDESIGN-T1 | 67.7 | adjusted | 8 | execute.md | branch_unit | REWRITTEN (B1/B2 target stagger; resolved_branch_o/branch_exception_o registered B2 outputs) |
| issue_read_operands | REDESIGN-T1 | 66.8 | adjusted | 8 | execute.md | issue_read_operands | ADAPTED (I1 operand read || wb_reserve slot check, I2 bypass select; alu_fwd selects; CSR credit + CVXIF port-0 verbatim; +hyp_wb_reserve_stall_o from g6lc_iq_arb) |
| g6lc_prf | REDESIGN-T1 | 65.2 | adjusted | 8 | tier2_tier3.md | g6lc_prf | ADAPTED (2-step registered read + write-record bypass) |
| serdiv | REDESIGN-T1 | 63.3 | adjusted | 7 | t1_rest.md | serdiv | ADAPTED (one registered quotient-digit select/subtract per cycle; split 32/32 carry across digits) |
| decoder | REDESIGN-T1 | 63.2 | structural | 7 | t1_rest.md | decode group | REWRITTEN (comb s1->s2->s3 composition, exact ports) |
| instr_queue | REDESIGN-T1 | 62.7 | adjusted | 7 | frontend.md | instr_queue (elastic) | REWRITTEN |
| wt_dcache_mem | REDESIGN-T1 | 61.5 | adjusted | 7 | tier2_tier3.md | wt_dcache_mem | ADAPTED (tag-compare -> way/data +2 hit staging, DcacheHitExtra=2 — the accepted rank-5 class; byte-wise balanced forward merge over DEPTH+1) |
| store_unit | REDESIGN-T1 | 60.7 | adjusted | 7 | tier2_tier3.md | load_store_unit, store_unit | ADAPTED (low/high staggered AGU feeding the LSQ event record; registered store-data path) |
| wt_dcache_missunit | REDESIGN-T1 | 59.9 | adjusted | 7 | t1_rest.md | wt_dcache_missunit | REWRITTEN (emit packetized mem_req_c/mem_req_valid_c kept; registered AMO_RESULT step; mshr_rdrd_collision staged; AMO depth-1 preserved) |
| load_unit | REDESIGN-T1 | 59.3 | adjusted | 7 | t1_rest.md | load_unit | REWRITTEN (L1 request / L2 tag / L3 tombstone wait / L4 align / L5 publish; +ld_checked_i, +fwd_req_o/fwd_rsp_i, +replay_o/replay_tid_o; r5: 10-bit one-hot FSM with translate_off encoded reference + $onehot assert) |
| perf_counters | REDESIGN-T1 | 55.7 | adjusted | 6 | coverage.md | gap: perf_counters — counters/events split low/high with registered carry; event OR trees registered (value path, rank 4) | ADAPTED (staged event OR-trees; low/high counter split with registered carry; 4 hyp_* event inputs all live: iq_replay, fe_override{1,2} from frontend pulses, wb_reserve_stall from g6lc_iq_arb) |
| g6lc_regfile | REDESIGN-T1 | 54.3 | adjusted | 6 | tier2_tier3.md | g6lc_regfile | ADAPTED (registered read address on ff and fpga variants; ports identical) |
| g6lc_fifo_v3 | REDESIGN-T1 | 54.3 | adjusted | 6 | tier2_tier3.md | fifo_v3/g6lc_fifo_v3 → g6lc_hyp_fifo | REWRITTEN (thin wrapper over g6lc_hyp_fifo; identical ports, parameters forwarded; no instantiation changes) |
| g6lc_mmu | REDESIGN-T1 | 53.6 | adjusted | 6 | t1_rest.md | g6lc_tlb … g6lc_mmu | ADAPTED (+HypCfg; STLB_DLY verdict-aligned request bundle into the shared TLB; kills on TLB flush) |
| g6lc_tlb | REDESIGN-T1 | 52.7 | adjusted | 6 | t1_rest.md | g6lc_tlb | ADAPTED (TlbStages>=2: T1 registered request, T2 registered hit/PTE/gpaddr verdict; flush kills in-flight) |
| g6lc_bp_loop | REDESIGN-T1 | 52.5 | adjusted | 6 | tier2_tier3.md | g6lc_bp_loop | ADAPTED (loop-count compare/read stage split from the confidence-update stage; registered update record) |
| g6lc_icache | REDESIGN-T1 | 51.9 | adjusted | 6 | t1_rest.md | g6lc_icache | ADAPTED (READ_V response stage; hit data/user/ex captured behind the 2-bit fetch token) |
| instr_realign | REDESIGN-T1 | 50.8 | adjusted | 6 | t1_rest.md | decode group (instr_realign) | REWRITTEN |
| g6lc_core | REDESIGN-T1 | 48.2 | adjusted | 6 | coverage.md | gap: g6lc_core top — wiring only; its own paths are glue muxes (RVFI/perf/debug fan-in) → register the observer fan-in (rank 4); threads HypCfg and the new seams | REWRITTEN (generated top; HypCfg threaded into 8 instances; all new seams wired; stale emit debug hierarchies rewritten to exported seams or guarded) |
| g6lc_memdep | REDESIGN-T1 | 47.9 | adjusted | 5 | tier2_tier3.md | g6lc_memdep | ADAPTED (registered dispatch query + registered train) |
| fpu_wrap | REDESIGN-T1 | 47.3 | adjusted | 5 | t1_rest.md | fpu_wrap | ADAPTED (HypCfg.FpuLatOverride: FMA 8 / noncomp 3 / conv 4; PipeConfig DISTRIBUTED; fpnew vendor files untouched) |
| ex_stage | REDESIGN-T1 | 42.8 | adjusted | 5 | execute.md | ex_stage | ADAPTED (per-FU registered lane records on existing NrWbPorts; wb_reserve-driven FLU sharing; tid taps for IRO forwarding) |
| commit_stage | REDESIGN-T1 | 41.8 | adjusted | 5 | tier2_tier3.md | commit_stage | ADAPTED (consumes scoreboard commit bundle; 2-state CSR-op hold for registered csr_rdata; ack registered) |
| g6lc_ptw | REDESIGN-T1 | 41.6 | adjusted | 5 | t1_rest.md | g6lc_ptw | ADAPTED (registered-boundary PMP; concat address formation kept — shift/select then issue already one state/cycle) |
| ras | REDESIGN-T1 | 39.1 | adjusted | 4 | tier2_tier3.md | ras | ADAPTED |
| g6lc_bp_statcor | REDESIGN-T1 | 33.7 | adjusted | 4 | tier2_tier3.md | g6lc_bp_* | ADAPTED (P1 staged prediction path; registered update record; geometry/policy unchanged) |
| g6lc_bp_ittage | REDESIGN-T1 | 32.9 | adjusted | 4 | tier2_tier3.md | g6lc_bp_* | ADAPTED (P1 index/tag registers; P2 read/verdict; ckpt-token training; geometry/policy unchanged) |
| lsu_bypass | REDESIGN-T1 | 32.3 | adjusted | 4 | tier2_tier3.md | lsu_bypass | ADAPTED (registered pop; forward merge from the F3 response) |
| csr_buffer | REDESIGN-T2 | 30.6 | adjusted | 3 | tier2_tier3.md | csr_buffer | ADAPTED (per-tid address table lookup registered; credit from registered counts) |
| wt_axi_adapter | REDESIGN-T2 | 29.8 | adjusted | 3 | tier2_tier3.md | axi_adapter … | ADAPTED (arb -> g6lc_hyp_rr_arb_tree; request assembly registered inside i_axi_shim; alloc-attr snapshotted at the capture edge) |
| g6lc_bp_tage | REDESIGN-T2 | 29.2 | adjusted | 3 | tier2_tier3.md | g6lc_bp_* | ADAPTED (P1 folded-hash/index/tag registers; P2 read/hit-compare/provider-vote; registered verdict; lk_index_o/lk_tag_o tokens carried through the ckpt record so training reuses the lookup hash; geometry/allocation/tie rules unchanged) |
| wt_dcache_ctrl | REDESIGN-T2 | 26.1 | structural | 3 | tier2_tier3.md | wt_dcache_ctrl | ADAPTED (+2 FSM states for the delayed hit verdict; request metadata capture; sticky write/refill collision) |
| mult | REDESIGN-T2 | 25.1 | adjusted | 3 | execute.md | mult.sv owner table | ADAPTED (owner table over the 8-stage multiplier; serdiv result on its own record) |
| g6lc_way_predictor | REDESIGN-T2 | 23.2 | adjusted | 2 | tier2_tier3.md | g6lc_way_predictor | ADAPTED (registered lookup output; update/flush preserved) |
| fpnew_noncomp | REDESIGN-T2 | 22.5 | structural | 2 | tier2_tier3.md | fpnew_noncomp (parameters) | AS-IS (latency via fpu_wrap PipeConfig/Latency parameters; vendor file untouched) |
| exp_backoff | REDESIGN-T2 | 21.6 | adjusted | 2 | tier2_tier3.md | exp_backoff | REWRITTEN as core/hyp_cells/g6lc_hyp_exp_backoff.sv (vendor exp_backoff replaced; registered is_zero boundary) |
| compressed_decoder | REDESIGN-T2 | 21.6 | structural | 2 | t1_rest.md | decode group | ADAPTED (verbatim case; residual ~21.6-FO4 cone open item) |
| fpnew_opgroup_multifmt_slice | REDESIGN-T2 | 21.5 | structural | 2 | t1_rest.md | fpnew_* (parameters) | AS-IS (latency via fpu_wrap PipeConfig/Latency parameters; vendor file untouched) |
| g6lc_ftq | REDESIGN-T2 | 19.8 | adjusted | 2 | tier2_tier3.md | g6lc_ftq | ADAPTED |
| rr_arb_tree | REDESIGN-T2 | 19.0 | adjusted | 2 | tier2_tier3.md | rr_arb_tree | REWRITTEN as core/hyp_cells/g6lc_hyp_rr_arb_tree.sv; selected arbiters switched; vendor rr_arb_tree.sv stays flisted for pending cvfpu files |
| pmp_entry | REDESIGN-T2 | 18.1 | structural | 2 | tier2_tier3.md | pmp | ADAPTED (conf formation vs dynamic compare split; compares run on pmp registered request boundary) |
| fpnew_opgroup_fmt_slice | REDESIGN-T2 | 18.0 | structural | 2 | tier2_tier3.md | fpnew_* (parameters) | AS-IS (latency via fpu_wrap PipeConfig/Latency parameters; vendor file untouched) |
| pmp | REDESIGN-T2 | 17.5 | structural | 2 | tier2_tier3.md | pmp | ADAPTED (clk/rst added; request fields registered at the boundary — TOR/NAPOT verdict the cycle after, H15) |
| instr_scan | REDESIGN-T3 | 15.0 | structural | 1 | tier2_tier3.md | instr_scan | ADAPTED |
| fpnew_classifier | REDESIGN-T3 | 14.7 | structural | 1 | tier2_tier3.md | fpnew_classifier | AS-IS (latency via fpu_wrap PipeConfig/Latency parameters; vendor file untouched) |
| g6lc_bp_ghist | REDESIGN-T3 | 14.5 | adjusted | 1 | tier2_tier3.md | g6lc_bp_* | AS-IS — lookup staged at the response boundary (stage-B mid-pipe, verdict captured into stage-L); internal cone cut deferred |
| raw_checker | REDESIGN-T3 | 14.4 | structural | 1 | tier2_tier3.md | raw_checker | ADAPTED (registered compare) |
| g6lc_shared_tlb | REDESIGN-T3 | 13.9 | adjusted | 1 | t1_rest.md | g6lc_shared_tlb | ADAPTED (accept->RAM->compare T1/T2 shape kept; hit verdict stays comb-aligned with the pulsed access for the PTW) |
| axi_shim | REDESIGN-T3 | 13.7 | adjusted | 1 | tier2_tier3.md | axi_shim | ADAPTED (elastic AR slot; registered AW/W payload capture; rd_gnt = AR handshake event preserved) |
| g6lc_rvfi_probes | REDESIGN-T3 | 12.0 | structural | 1 | tier2_tier3.md | g6lc_rvfi_probes | ADAPTED (re-anchored to the commit bundle +1; two-step CSR read — retirement order, post-write CSR values; clk_i/rst_ni added) |
| id_stage | REDESIGN-T3 | 10.9 | adjusted | 1 | t1_rest.md | decode group | ADAPTED (HypCfg.DecodeStages==3: D1/D2 regs + s1/s2/s3; ==1 unchanged) |
| fpnew_top | REDESIGN-T3 | 10.8 | adjusted | 1 | t1_rest.md | fpnew_* (parameters) | AS-IS (latency via fpu_wrap PipeConfig/Latency parameters; vendor file untouched) |
| g6lc_bp_tage_table | REDESIGN-T3 | 10.6 | structural | 1 | tier2_tier3.md | g6lc_bp_* | AS-IS — lookup staged at the response boundary (stage-B mid-pipe, verdict captured into stage-L); internal cone cut deferred |
| g6lc_fdip | REDESIGN-T3 | 10.1 | adjusted | 1 | tier2_tier3.md | g6lc_fdip | ADAPTED |
| lfsr | REDESIGN-T3 | 9.9 | adjusted | 1 | coverage.md | gap: lfsr — a T3 vendor cell; g6lc_hyp_lfsr with the feedback XOR tree registered once (rank 4) | REWRITTEN as core/hyp_cells/g6lc_hyp_lfsr.sv (out_o is the registered state; cipher layers unsupported) |
| pmp_data_if | REDESIGN-T3 | 9.2 | adjusted | 1 | tier2_tier3.md | pmp | ADAPTED (req2 verdict-alignment stage + registered fetch areq record; lsu_valid_o +2 total, H15) |
| wt_dcache | REDESIGN-T3 | 9.2 | adjusted | 1 | coverage.md | gap: wt_dcache wrapper — T3 at 9.2: the port muxing between ctrl/missunit/wbuffer; one registered boundary on the response mux (rank 2: the response is already registered in wt_dcache_mem) | ADAPTED (one registered boundary on the response mux) |
| lzc | REDESIGN-T3 | 8.8 | structural | 1 | tier2_tier3.md | lzc/popcount | REWRITTEN as core/hyp_cells/g6lc_hyp_lzc.sv (comb drop-in); all non-vendor sites renamed; vendor lzc.sv stays flisted for pending cvfpu files |
| controller | REDESIGN-T3 | 8.5 | adjusted | 1 | coverage.md | gap: controller — T3 at 8.5 (COPY→ADAPT in the plan): the flush/drain decision; counted drain for the deeper pipes, flush request registered from the commit bundle (rank 2) | ADAPTED (counted drain DRAIN_CYCLES = max(DecodeStages+2, RenameStages+1, AluStages+2, 3, DcacheHitExtra+3, CsrReadStages+1) = 5 @Hyp8; CSR side-effect flush consumed registered) |

## Gaps filled here (indicative one-liners)

- **perf_counters**: gap: perf_counters — counters/events split low/high with registered carry; event OR trees registered (value path, rank 4)
- **g6lc_core**: gap: g6lc_core top — wiring only; its own paths are glue muxes (RVFI/perf/debug fan-in) → register the observer fan-in (rank 4); threads HypCfg and the new seams
- **lfsr**: gap: lfsr — a T3 vendor cell; g6lc_hyp_lfsr with the feedback XOR tree registered once (rank 4)
- **wt_dcache**: gap: wt_dcache wrapper — T3 at 9.2: the port muxing between ctrl/missunit/wbuffer; one registered boundary on the response mux (rank 2: the response is already registered in wt_dcache_mem)
- **controller**: gap: controller — T3 at 8.5 (COPY→ADAPT in the plan): the flush/drain decision; counted drain for the deeper pipes, flush request registered from the commit bundle (rank 2)

- analysis files stamped this run: (none, already stamped)

## APU cone (Phase 4 — root `g6lc_soc`, `analysis/cut-ledger.apu.md`)

| module | decision | D | basis | min_cuts_est | analysis | section / note | mode |
|---|---|---|---|---|---|---|---|
| g6lc_soc | new top | -- | -- | -- | decisions.md P4 | SoC integration | REWRITTEN (new; testbench-harness structure minus sim-only; xbar CUT_ALL_PORTS; exported DRAM AXI) |
| g6lc_hart | wrapper | -- | -- | -- | decisions.md P4 | hart | ADAPTED (axi_cdc seam clk_core->clk_uncore + two-flop irq/ipi/time_irq/debug_req syncs; HypCfg) |
| axi_cdc (+_src/_dst, cdc_fifo_gray, binary_to_gray, gray_to_binary) | vendor copy | -- | -- | -- | decisions.md P4 | CDC seam | AS-IS (vendor verbatim, copied into APU third_party) |
| g6lc_axi2mem_reg | new cell | -- | -- | -- | decisions.md P4 | registered AXI->simple-mem bridge | REWRITTEN (new; RD_LAT param; ROM port RD_LAT=3, Debug port RD_LAT=4 for the registered dm_mem decode) |
| g6lc_axi2apb_reg | new cell | -- | -- | -- | decisions.md P4 | registered AXI->APB bridge | REWRITTEN (new; PLIC/UART/timer) |
| dm_mem | REDESIGN-T1 | 54.8 | structural | 6 | decisions.md P4 | debug module | ADAPTED (dm_top boundary + registered request bundle req_q/we_q/addr_q/wdata_q/be_q inside; decode and response +1; window behind g6lc_axi2mem_reg RD_LAT=4) |
| axi_demux | REDESIGN-T1 | 34.2 | structural | 4 | decisions.md P4 | xbar | AS-IS (vendor; boundary cut = xbar CUT_ALL_PORTS spill registers) |
| slib_fifo | REDESIGN-T1 | 33.1 | structural | 4 | decisions.md P4 | UART | AS-IS residue (baud-class serial datapath; APB boundary registered by g6lc_axi2apb_reg) |
| axi_adapter | REDESIGN-T1 | 32.5 | structural | 4 | tier2_tier3.md | DM bus master | ADAPTED (group-9 request capture; valid/ready unchanged) |
| axi_adapter_arbiter | REDESIGN-T2 | 31.5 | structural | 3 | decisions.md P4 | std-cache path | AS-IS — emit-syntactic reachable only; generate-dead under the WT g6lc64_ooo config |
| bootrom | REDESIGN-T2 | 30.0 | structural | 3 | decisions.md P4 | ROM | ADAPTED (+1 banked read stage; bridge RD_LAT=3) |
| uart_receiver | REDESIGN-T2 | 28.2 | structural | 3 | decisions.md P4 | UART | AS-IS residue |
| apb_uart | REDESIGN-T2 | 26.2 | structural | 3 | decisions.md P4 | UART | AS-IS residue |
| dmi_jtag | REDESIGN-T2 | 23.8 | structural | 2 | decisions.md P4 | DTM | AS-IS residue (dmi_cdc + dm_top spill regs cover the channel boundary; tck-side interior) |
| dm_csrs | REDESIGN-T2 | 21.2 | structural | 2 | decisions.md P4 | debug module | ADAPTED (registered DMI request decode: req_q/req_v_q capture at accept, decode + response push +1; accept gated ~full & ~req_v_q; valid/ready protocol preserved; dm_top spills also on the channel) |
| dmi_jtag_tap | REDESIGN-T2 | 21.0 | structural | 2 | decisions.md P4 | JTAG TAP | AS-IS residue |
| timer | REDESIGN-T2 | 19.1 | structural | 2 | decisions.md P4 | timer | ADAPTED (registered irq output) |
| uart_baudgen | REDESIGN-T2 | 18.0 | structural | 2 | decisions.md P4 | UART | AS-IS residue |
| uart_interrupt | REDESIGN-T2 | 17.4 | structural | 2 | decisions.md P4 | UART | AS-IS residue |
| rv_plic_target | REDESIGN-T2 | 17.0 | structural | 2 | decisions.md P4 | PLIC | ADAPTED (4 registered group winners + registered final winner) |
| axi2apb_64_32 | COPY-NOT-INSTANTIATED | 33.9 | structural | 4 | decisions.md P4 | replaced by g6lc_axi2apb_reg in the SoC cone | AS-IS (out of the g6lc_soc cone) |
| axi2mem | COPY-NOT-INSTANTIATED | 55.5 | structural | 6 | decisions.md P4 | replaced by g6lc_axi2mem_reg; the ADAPTED file is retained out-of-cone | ADAPTED (out of the g6lc_soc cone) |
| plic_top | REDESIGN-T3 | 14.1 | structural | 1 | decisions.md P4 | PLIC | AS-IS (request path behind g6lc_axi2apb_reg + apb_to_reg; interior residue) |
| slib_counter | REDESIGN-T3 | 13.6 | structural | 1 | decisions.md P4 | UART | AS-IS residue |
| apb_timer | REDESIGN-T3 | 13.5 | structural | 1 | decisions.md P4 | timer wrapper | ADAPTED (registered response + one wait state) |
| slib_input_filter | REDESIGN-T3 | 12.1 | structural | 1 | decisions.md P4 | UART | AS-IS residue |
| uart_transmitter | REDESIGN-T3 | 10.9 | structural | 1 | decisions.md P4 | UART | AS-IS residue |
| fifo_v3 | REDESIGN-T3 | 10.7 | structural | 1 | decisions.md P4 | vendor cell (dmi paths) | AS-IS (vendor; channel boundaries spill-registered) |
| slib_clock_div / slib_mv_filter | REDESIGN-T3 | 10.2 | structural | 1 | decisions.md P4 | UART | AS-IS residue |
| axi_mux | REDESIGN-T3 | 9.3 | structural | 1 | decisions.md P4 | xbar | AS-IS (vendor; CUT_ALL_PORTS spill registers) |
| rstgen_bypass | REDESIGN-T3 | 9.1 | structural | 1 | decisions.md P4 | reset gen | AS-IS (vendor leaf inside rstgen) |
| clint (+ clint_sync/_wedge) | COPY | 7.3 | structural | 0 | decisions.md P4 | CLINT | ADAPTED (registered timer-compare verdict, +1 MTIP) |
| rv_plic_gateway | COPY | 7.5 | structural | 0 | decisions.md P4 | PLIC | AS-IS |
| dm_sba | COPY | 7.5 | structural | 0 | decisions.md P4 | debug module | AS-IS |
| axi_xbar / axi_demux_id_counters / axi_err_slv / spill_register(+_flushable) / stream_register / cdc_2phase(_src/_dst) / sync / rstgen | COPY | <=8 | structural | 0 | decisions.md P4 | vendor cells | AS-IS |
