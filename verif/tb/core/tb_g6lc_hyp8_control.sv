// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// hyp8 control/retirement leaf — "common-event retirement" (the
// caller-worklist retirement/CSR + IQ ownership batch).
//
// tb_g6lc_hyp8_csr exercises the REAL commit_stage + csr_buffer +
// csr_regfile seam exactly as g6lc_core wires it (csr_buffer table ->
// csr_addr_i, commit_stage csr_op_o/csr_wdata_o -> csr_regfile, the
// request/apply handshake back through csr_rdata_valid_i/csr_exception_i
// and commit_ack_o/commit_csr_o). The two-phase request is presented by
// the commit head; the response fires the NEXT cycle and the apply is
// the same commit_ack_o the scoreboard sees. Copied-source negative
// controls (mut_commit_stage_delayed, mut_csr_buffer_gated) run on
// identical stimulus so the leaf cannot silently pass if a delayed
// commit acknowledgement or the commit-gated CSR address lookup were
// ever restored.
//
// tb_g6lc_hyp8_issue exercises the REAL g6lc_iq_payload + g6lc_iq_arb +
// g6lc_flu_reserve seam: the bench emulates the banks' combinational
// candidates and drives the payload read-enable exactly as the g6lc_iq
// wrapper does (OR of the take column). Copied-source negative control
// mut_iq_payload_comb observes identical indices and must leak a reused
// slot's payload where the real registered read holds the granted row.
//
// Stimulus is driven on the clock-low phase and outputs sampled after
// the posedge (one sample point per tick, the leaf-bench discipline).

module tb_g6lc_hyp8_csr;
  import g6lc_core_pkg::*;
  `include "g6lc_core_types.svh"
  `include "rvfi_types.svh"

  function automatic config_pkg::g6lc_cfg_t configuration();
    config_pkg::g6lc_cfg_t c = config_pkg::g6lc_cfg_empty;
    c.XLEN = 64; c.VLEN = 64; c.PLEN = 56; c.GPLEN = 64; c.IS_XLEN64 = 1;
    c.NrHarts = 1;
    c.NrIssuePorts = 2; c.NrCommitPorts = 2; c.NrWbPorts = 2;
    c.NrRgprPorts = 2;
    c.NR_SB_ENTRIES = 16; c.TRANS_ID_BITS = 4;
    c.OoOEn = 1; c.SpeculativeSb = 1; c.SuperscalarEn = 1;
    c.RVS = 1; c.RVU = 1; c.RVA = 1; c.MmuPresent = 1;
    c.MODE_SV = config_pkg::ModeSv39; c.PtLevels = 3; c.VpnLen = 27;
    c.SV = 39; c.PPNW = 44; c.GPPNW = 44;
    c.ASID_WIDTH = 16; c.VMID_WIDTH = 14;
    // Derived-width fields as build_config_pkg computes them
    // (g6lc_cfg_empty leaves them 0, which silently drops satp fields).
    c.ModeW = 4; c.ASIDW = 16; c.VMIDW = 14;
    c.NrPMPEntries = 4;
    return c;
  endfunction
  // counter leaf pins the enable terms observable (the main profile
  // leaves DebugEn/PerfCounterEn off)
  function automatic config_pkg::g6lc_cfg_t counter_cfg();
    config_pkg::g6lc_cfg_t c = configuration();
    c.DebugEn = 1; c.PerfCounterEn = 1;
    return c;
  endfunction
  localparam config_pkg::g6lc_cfg_t C = configuration();
  localparam config_pkg::g6lc_cfg_t CC = counter_cfg();
  localparam g6lc_hyp_pkg::g6lc_hyp_cfg_t H = g6lc_hyp_pkg::Hyp8;

  typedef `G6LC_BRANCHPREDICT_SBE_T(C) branchpredict_sbe_t;
  typedef `G6LC_EXCEPTION_T(C)         exception_t;
  typedef `G6LC_SCOREBOARD_ENTRY_T(C)  sbe_t;
  typedef `G6LC_IRQ_CTRL_T(C)          irq_ctrl_t;
  typedef struct packed {logic[C.XLEN-7:0] base; logic[5:0] mode;} jvt_t;
  typedef `RVFI_PROBES_CSR_T(C)        rvfi_csr_t;
  // csr_buffer's fu_data_t — the buffer only reads operand_a (result),
  // operand_b[11:0] (CSR address) and trans_id.
  typedef struct packed {
    logic [C.XLEN-1:0]               operand_a;
    logic [C.XLEN-1:0]               operand_b;
    logic [C.TRANS_ID_BITS-1:0]      trans_id;
  } fu_data_t;

  localparam int NPC = C.NrCommitPorts;
  localparam int NSB = C.NR_SB_ENTRIES;
  localparam int TID = C.TRANS_ID_BITS;

  logic clk = 0, rst_n = 0, flush = 0;
  int checked = 0;
  int cycles = 0;

  // ---------------- commit head presentation (scoreboard side) ----------------
  sbe_t [NPC-1:0] ci;
  logic [NPC-1:0] ci_drop, ci_replay, bundle_v;
  logic [NPC-1:0] ack, mut_ack;
  logic           halt = 0;

  // ---------------- CSR issue-side table (csr_buffer) ----------------
  fu_data_t fud;
  logic buf_valid, buf_ready;
  logic [11:0] buf_addr, mut_buf_addr;
  logic buf_commit;
  logic [TID-1:0] buf_commit_tid;
  logic [NSB-1:0] cancel = '0;

  // ---------------- commit <-> CSR file seam ----------------
  fu_op csr_op;
  logic [C.XLEN-1:0] csr_wdata, csr_rdata;
  logic csr_rv;
  exception_t csr_ex, ex_commit;
  logic [C.VLEN-1:0] pc_commit;
  logic [NPC-1:0][4:0] waddr_o;
  logic [NPC-1:0][C.XLEN-1:0] wdata_o;
  logic [NPC-1:0] we_gpr, we_fpr;
  logic eret;
  riscv::priv_lvl_t priv_lvl;
  logic flush_csr;
  logic halt_csr;
  logic flush_commit;

  csr_buffer #(
      .G6LCCfg(C), .HypCfg(H), .fu_data_t(fu_data_t)
  ) i_buf (
      .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
      .cancelled_mask_i(cancel),
      .fu_data_i(fud), .csr_ready_o(buf_ready),
      .csr_valid_i(buf_valid), .csr_result_o(),
      .csr_commit_i(buf_commit), .csr_commit_tid_i(buf_commit_tid),
      .csr_addr_o(buf_addr));

  mut_csr_buffer_gated #(
      .G6LCCfg(C), .HypCfg(H), .fu_data_t(fu_data_t)
  ) i_mut_buf (
      .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
      .cancelled_mask_i(cancel),
      .fu_data_i(fud), .csr_ready_o(),
      .csr_valid_i(buf_valid), .csr_result_o(),
      .csr_commit_i(buf_commit), .csr_commit_tid_i(buf_commit_tid),
      .csr_addr_o(mut_buf_addr));

  commit_stage #(
      .G6LCCfg(C), .HypCfg(H), .exception_t(exception_t),
      .scoreboard_entry_t(sbe_t)
  ) i_commit (
      .clk_i(clk), .rst_ni(rst_n), .halt_i(halt),
      .flush_dcache_i(1'b0), .flush_i(flush),
      .exception_o(ex_commit), .dirty_fp_state_o(),
      .single_step_i(1'b0), .step_hart_i('0),
      .commit_instr_i(ci), .commit_drop_i(ci_drop),
      .commit_replay_i(ci_replay),
      .commit_ack_o(ack), .commit_macro_ack_o(),
      .waddr_o(waddr_o), .wdata_o(wdata_o), .we_gpr_o(we_gpr),
      .whart_o(), .we_fpr_o(we_fpr),
      .amo_resp_i('0), .pc_o(pc_commit),
      .csr_op_o(csr_op), .csr_wdata_o(csr_wdata),
      .csr_rdata_i(csr_rdata), .csr_write_fflags_o(),
      .csr_exception_i(csr_ex), .csr_rdata_valid_i(csr_rv),
      .commit_bundle_valid_i(bundle_v),
      .commit_lsu_o(), .commit_lsu_ready_i(1'b1),
      .commit_tran_id_o(buf_commit_tid), .amo_valid_commit_o(),
      .no_st_pending_i(1'b1), .commit_csr_o(buf_commit),
      .fence_i_o(), .fence_o(), .flush_commit_o(flush_commit),
      .replay_o(), .sfence_vma_o(), .hfence_vvma_o(), .hfence_gvma_o(),
      .shared_tlb_flush_busy_i(1'b0), .break_from_trigger_i(1'b0));

  mut_commit_stage_delayed #(
      .G6LCCfg(C), .HypCfg(H), .exception_t(exception_t),
      .scoreboard_entry_t(sbe_t)
  ) i_mut_commit (
      .clk_i(clk), .rst_ni(rst_n), .halt_i(halt),
      .flush_dcache_i(1'b0), .flush_i(flush),
      .exception_o(), .dirty_fp_state_o(),
      .single_step_i(1'b0), .step_hart_i('0),
      .commit_instr_i(ci), .commit_drop_i(ci_drop),
      .commit_replay_i(ci_replay),
      .commit_ack_o(mut_ack), .commit_macro_ack_o(),
      .waddr_o(), .wdata_o(), .we_gpr_o(),
      .whart_o(), .we_fpr_o(),
      .amo_resp_i('0), .pc_o(),
      .csr_op_o(), .csr_wdata_o(),
      .csr_rdata_i(csr_rdata), .csr_write_fflags_o(),
      .csr_exception_i(csr_ex), .csr_rdata_valid_i(csr_rv),
      .commit_bundle_valid_i(bundle_v),
      .commit_lsu_o(), .commit_lsu_ready_i(1'b1),
      .commit_tran_id_o(), .amo_valid_commit_o(),
      .no_st_pending_i(1'b1), .commit_csr_o(),
      .fence_i_o(), .fence_o(), .flush_commit_o(),
      .replay_o(), .sfence_vma_o(), .hfence_vvma_o(), .hfence_gvma_o(),
      .shared_tlb_flush_busy_i(1'b0), .break_from_trigger_i(1'b0));

  csr_regfile #(
      .G6LCCfg(C), .HypCfg(H), .exception_t(exception_t), .jvt_t(jvt_t),
      .irq_ctrl_t(irq_ctrl_t), .scoreboard_entry_t(sbe_t),
      .rvfi_probes_csr_t(rvfi_csr_t),
      .VmidWidth(1), .MHPMCounterNum(6), .N_Triggers(4)
  ) i_csr (
      .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
      .time_irq_i(1'b0), .rtc_time_i('0),
      .flush_o(flush_csr), .halt_csr_o(halt_csr), .wfi_wake_o(),
      .commit_instr_i(ci[0]), .commit_ack_i(ack),
      .boot_addr_i(64'h8000_0000), .hart_id_i('0),
      .ex_i(ex_commit),
      .csr_op_i(csr_op), .csr_addr_i(buf_addr),
      .csr_wdata_i(csr_wdata), .csr_rdata_o(csr_rdata),
      .csr_rdata_valid_o(csr_rv),
      .dirty_fp_state_i(1'b0), .csr_write_fflags_i(1'b0),
      .dirty_v_state_i(1'b0), .pc_i(pc_commit),
      .csr_exception_o(csr_ex), .epc_o(), .eret_o(eret),
      .trap_vector_base_o(), .priv_lvl_o(priv_lvl), .mbe_o(), .v_o(),
      .acc_fflags_ex_i('0), .acc_fflags_ex_valid_i(1'b0),
      .fs_o(), .vfs_o(), .fflags_o(), .frm_o(), .fprec_o(), .vs_o(),
      .irq_ctrl_o(), .en_translation_o(), .en_g_translation_o(),
      .en_ld_st_translation_o(), .en_ld_st_g_translation_o(),
      .ld_st_priv_lvl_o(), .ld_st_v_o(), .csr_hs_ld_st_inst_i(1'b0),
      .sum_o(), .vs_sum_o(), .mxr_o(), .vmxr_o(),
      .satp_ppn_o(), .asid_o(), .vsatp_ppn_o(), .vs_asid_o(),
      .hgatp_ppn_o(), .vmid_o(),
      .mcbie_o(), .scbie_o(), .hcbie_o(), .mcbcfe_o(), .scbcfe_o(),
      .hcbcfe_o(), .mcbze_o(), .scbze_o(), .hcbze_o(), .pbmte_o(),
      .irq_i('0), .ipi_i(1'b0), .debug_req_i(1'b0),
      .set_debug_pc_o(), .tvm_o(), .tw_o(), .vtw_o(), .tsr_o(), .hu_o(),
      .debug_mode_o(), .single_step_o(),
      .icache_en_o(), .dcache_en_o(), .acc_cons_en_o(),
      .ai_aicfg_o(), .ai_ais_o(), .ai_issue_ok_o(), .ai_q_en_o(),
      .ai_qid_o(), .dirty_ai_state_i(1'b0), .ai_setcfg_we_i(1'b0),
      .ai_setcfg_wdata_i('0),
      .perf_addr_o(), .perf_data_o(), .perf_data_i('0), .perf_we_o(),
      .scountovf_i('0), .lcofi_i(1'b0),
      .pmpcfg_o(), .pmpaddr_o(), .mcountinhibit_o(),
      .rvfi_csr_o(), .jvt_o(), .debug_from_trigger_o(),
      .vaddr_from_lsu_i('0), .orig_instr_i('0), .store_result_i('0),
      .break_from_trigger_o());

  // ------------------------- standalone counter leaf -------------------------
  logic [NPC-1:0] cnt_ack = '0;
  logic           cnt_ex = 0, cnt_dbg = 0;
  logic [31:0]    cnt_inhib = '0;
  logic [63:0]    cnt_cycle_in = '0, cnt_inst_in = '0;
  logic [63:0]    cnt_cycle_o, cnt_inst_o;

  csr_counters #(.G6LCCfg(CC)) i_cnt (
      .clk_i(clk), .rst_ni(rst_n),
      .cycle_i(cnt_cycle_in), .instret_i(cnt_inst_in),
      .commit_ack_i(cnt_ack), .ex_valid_i(cnt_ex),
      .debug_mode_i(cnt_dbg), .mcountinhibit_i(cnt_inhib),
      .cycle_o(cnt_cycle_o), .instret_o(cnt_inst_o));

  // ------------------------- stimulus -------------------------
  task automatic tick;
    clk = 1; #2; clk = 0; #2;
    cycles++;
    if (cycles > 800) $fatal(1, "tb_g6lc_hyp8_csr watchdog");
  endtask

  task automatic check(input bit ok, input string tag);
    if (!ok) $fatal(1, "%s", tag);
    checked++;
  endtask

  task automatic clear_inputs;
    ci = '{default: '0}; ci_drop = '0; ci_replay = '0; bundle_v = '0;
    fud = '0; buf_valid = 0; cancel = '0; halt = 0; flush = 0;
  endtask

  // issue-side table allocation (the buffer accepts the presented CSR's
  // {tid -> csr-address} one cycle before the commit head resolves it)
  task automatic csr_alloc(input int tid, input logic [11:0] addr,
                           input logic [C.XLEN-1:0] opa);
    fud.trans_id = TID'(tid); fud.operand_a = opa;
    fud.operand_b = C.XLEN'(addr);
    buf_valid = 1; tick(); buf_valid = 0; #2;
  endtask

  // present a CSR scoreboard head (held until it fires)
  task automatic csr_present(input int tid, input fu_op op,
                             input logic [C.XLEN-1:0] res);
    ci[0] = '0;
    ci[0].valid = 1; ci[0].fu = CSR; ci[0].op = op;
    ci[0].trans_id = TID'(tid); ci[0].result = res;
    ci[0].rd = 5'd7; ci[0].pc = 64'h8000_0100 + C.VLEN'(tid);
    bundle_v[0] = 1;
    #2;
  endtask

  task automatic csr_release;
    ci[0] = '0; bundle_v[0] = 0; #2;
  endtask

  initial begin
    clear_inputs();
    #2; tick(); tick(); rst_n = 1; #2;

    // ============ A: two-phase CSR write -> architectural apply ============
    // table credit: one free entry left after the first allocation
    csr_alloc(1, 12'h340, 64'hA5A5_0000_0000_00A5);   // MSCRATCH
    check(buf_ready, "CSRBUF_CREDIT_AFTER_ONE");
    csr_alloc(2, 12'hB00, 64'h0);                     // MCYCLE (second slot)
    check(!buf_ready, "CSRBUF_CREDIT_EXHAUSTED");
    cancel[2] = 1'b1; tick(); cancel[2] = 1'b0;       // squash frees the probe slot
    csr_present(1, CSR_WRITE, 64'hA5A5_0000_0000_00A5);
    // request cycle: the tid's address resolves combinationally BEFORE
    // any commit — the gated-lookup mutation must disagree right here.
    check(buf_addr == 12'h340, "CSR_ADDR_COMB_LOOKUP");
    check(mut_buf_addr != 12'h340, "CSR_MUT_GATED_ADDR");
    check(ack[0] == 1'b0, "CSR_NO_SAME_CYCLE_FIRE");
    tick();                                          // -> response cycle
    // response cycle: the request's completion and the fire are one
    // common event — the delayed-ack mutation must lag here.
    check(ack[0] == 1'b1, "CSR_FIRE_AT_RESPONSE");
    check(mut_ack[0] == 1'b0, "CSR_MUT_DELAYED_ACK");
    check(buf_commit == 1'b1, "CSRBUF_RELEASE_AT_FIRE");
    check(we_gpr[0] == 1'b1, "CSR_DEP_WRITE_SAME_EVENT");
    tick(); csr_release();                            // -> apply visible
    check(i_csr.mscratch_q == 64'hA5A5_0000_0000_00A5, "MSCRATCH_APPLIED");

    // ============ B: readback through the same seam ============
    csr_alloc(3, 12'h340, '0);
    csr_present(3, CSR_READ, '0);
    tick();
    check(ack[0] == 1'b1, "CSRR_FIRE_AT_RESPONSE");
    check(wdata_o[0] == 64'hA5A5_0000_0000_00A5 &&
          waddr_o[0] == 5'd7 && we_gpr[0], "CSRR_RDATA_WRITEBACK");
    tick(); csr_release();

    // ============ C: back-to-back requests, distinct lifetimes ============
    csr_alloc(4, 12'h340, '0);
    csr_present(4, CSR_WRITE, 64'h5A5A_0000_0000_005A);
    tick();
    check(ack[0] == 1'b1, "CSRW2_FIRE");
    tick(); csr_release();
    check(i_csr.mscratch_q == 64'h5A5A_0000_0000_005A, "MSCRATCH_SECOND");
    csr_alloc(5, 12'h340, '0);
    csr_present(5, CSR_WRITE, 64'hC3C3_0000_0000_00C3);
    tick();
    check(ack[0] == 1'b1, "CSRW3_FIRE");
    tick(); csr_release();
    check(i_csr.mscratch_q == 64'hC3C3_0000_0000_00C3, "MSCRATCH_THIRD");

    // ============ D: halted response — request lives, fire stalls ====
    // The request registers while unhalted; the response is then stalled
    // before the applying edge. The pending request must stay live (the
    // response is stalled, not lost), no fire and no write may occur.
    csr_alloc(6, 12'h340, '0);
    csr_present(6, CSR_WRITE, 64'hDEAD_DEAD_DEAD_DEAD);
    tick();                                  // request registers
    check(csr_rv == 1'b1, "CSR_HALTED_REQ_LIVE");
    halt = 1; #1;                            // stall the applying edge
    check(ack[0] == 1'b0, "CSR_HALTED_RESP_SUPPRESSED");
    for (int i = 0; i < 3; i++) begin
      tick();
      check(csr_rv == 1'b1 && ack[0] == 1'b0, "CSR_HALTED_RESP_HELD");
      check(i_csr.mscratch_q == 64'hC3C3_0000_0000_00C3,
            "CSR_HALTED_NO_WRITE");
    end
    halt = 0; #1;                            // seen re-arms on release
    for (int i = 0; i < 2 && !ack[0]; i++) tick();
    check(ack[0] == 1'b1, "CSR_HALTED_ACK_RESUMED");
    tick(); csr_release();                   // apply lands at this edge
    check(i_csr.mscratch_q == 64'hDEAD_DEAD_DEAD_DEAD, "CSR_HALTED_APPLIED");

    // ============ D2: a head presented only under halt never requests ====
    csr_alloc(7, 12'h340, '0);
    halt = 1;
    csr_present(7, CSR_WRITE, 64'h0BAD_0000_0000_0BAD);
    tick();
    check(csr_rv == 1'b0 && ack[0] == 1'b0, "CSR_HALT_ONLY_NO_REQ");
    tick();
    check(ack[0] == 1'b0, "CSR_HALT_ONLY_HELD");
    halt = 0; csr_release();
    cancel[7] = 1'b1; tick(); cancel[7] = 1'b0;   // killed head frees credit
    check(i_csr.mscratch_q == 64'hDEAD_DEAD_DEAD_DEAD, "CSR_HALT_ONLY_NO_WRITE");

    // ============ E: unsupported CSR — trap, no retirement ============
    csr_alloc(8, 12'h7B0, '0);                        // debug CSR, DebugEn=0
    csr_present(8, CSR_WRITE, '0);
    tick();
    check(csr_ex.valid == 1'b1, "CSR_TRAP_RAISED");
    check(ex_commit.valid == 1'b1, "CSR_TRAP_MERGED");
    check(ack[0] == 1'b0, "CSR_TRAP_NO_FIRE");
    flush = 1; tick(); flush = 0; csr_release();      // controller squash
    check(i_csr.mscratch_q == 64'hDEAD_DEAD_DEAD_DEAD, "CSR_TRAP_NO_WRITE");

    // ============ F: flush kills a pending (stalled) request ============
    // Request registers, the applying edge is stalled by halt, then a
    // flush edge drops the pending record before it can apply.
    csr_alloc(9, 12'h340, '0);
    csr_present(9, CSR_WRITE, 64'hFACE_0000_0000_FACE);
    tick();                                  // request registers
    check(csr_rv == 1'b1, "CSR_FLUSH_REQ_LIVE");
    halt = 1;
    tick();
    check(ack[0] == 1'b0 && csr_rv == 1'b1, "CSR_FLUSH_STALLED");
    csr_release();                           // withdraw the head
    flush = 1;
    tick();                                  // flush edge drops pending
    flush = 0; halt = 0;
    check(csr_rv == 1'b0, "CSR_FLUSH_RESP_GONE");
    tick();
    check(i_csr.mscratch_q == 64'hDEAD_DEAD_DEAD_DEAD, "CSR_FLUSH_NO_WRITE");
    tick();                                  // settle post-flush

    // ============ G: MRET completes like a read ============
    csr_alloc(10, 12'h000, '0);
    csr_present(10, MRET, '0);
    tick();
    check(ack[0] == 1'b1, "MRET_FIRE");
    check(eret == 1'b1, "MRET_ERET_AT_APPLY");
    tick(); csr_release();

    // ============ H: counter carry — same-cycle high-word update ============
    csr_alloc(11, 12'hB00, '0);                       // MCYCLE
    csr_present(11, CSR_WRITE, 64'h0000_0000_FFFF_FFFF);
    tick();
    check(ack[0] == 1'b1, "MCYCLE_FIRE");
    tick(); csr_release();                            // cycle_q := FFFFFFFF
    tick();                                           // +1 -> carry lands
    check(i_csr.cycle_q[63:32] == 32'h1, "MCYCLE_CARRY_HI");
    check(i_csr.cycle_q[31:0] < 32'd4, "MCYCLE_CARRY_LO");

    // ============ I: WFI completion ============
    csr_alloc(12, 12'h000, '0);
    csr_present(12, WFI, '0);
    tick();
    check(ack[0] == 1'b1, "WFI_FIRE");
    tick(); csr_release();
    check(halt_csr == 1'b1, "WFI_HALTS_CORE");

    // ============ J: standalone counter — same-cycle carry, no stale ====
    cnt_inst_in  = 64'h0000_0000_FFFF_FFFE;
    cnt_cycle_in = 64'd41;
    cnt_ack = 2'b11;                          // two retirements, one cycle
    #1;
    check(cnt_inst_o == 64'h0000_0001_0000_0000, "CNT_CARRY_SAME_CYCLE");
    check(cnt_cycle_o == 64'd42, "CNT_CYCLE_STEP");
    cnt_inst_in = 64'd7;                      // carry state must not linger
    #1;
    check(cnt_inst_o == 64'd9, "CNT_NO_STALE_CARRY");
    cnt_inhib[2] = 1'b1; cnt_inst_in = 64'd100;
    #1;
    check(cnt_inst_o == 64'd100, "CNT_INHIBIT_FREEZE");
    cnt_inhib = '0; cnt_dbg = 1'b1;
    #1;
    check(cnt_inst_o == 64'd100, "CNT_DEBUG_FREEZE");
    check(cnt_cycle_o == 64'd41, "CNT_DEBUG_CYCLE_FREEZE");
    cnt_dbg = 0; cnt_ack = '0;

    $display("HYP8_CSR_PASS checked=%0d", checked);
    $finish;
  end
endmodule


// ======================================================================
// IQ payload/arbiter + IRO-acceptance reservation leaf
// ======================================================================
module tb_g6lc_hyp8_issue;
  import g6lc_core_pkg::*;
  `include "g6lc_core_types.svh"

  function automatic config_pkg::g6lc_cfg_t configuration();
    config_pkg::g6lc_cfg_t c = config_pkg::g6lc_cfg_empty;
    c.XLEN = 64; c.VLEN = 64; c.PLEN = 56; c.GPLEN = 64; c.IS_XLEN64 = 1;
    c.NrHarts = 1; c.NrIssuePorts = 2; c.NrCommitPorts = 2;
    c.NrWbPorts = 4; c.NrRgprPorts = 4;
    c.NR_SB_ENTRIES = 16; c.TRANS_ID_BITS = 4;
    c.OoOEn = 1; c.SpeculativeSb = 1; c.SuperscalarEn = 1;
    c.MultStages = 8;
    // IRO leaf seam: operand/struct field widths (CvxifEn stays 0 -- the
    // coprocessor handshake is inert but its types must elaborate).
    c.FLen = 64; c.X_NUM_RS = 1; c.X_ID_WIDTH = 4;
    c.X_RFR_WIDTH = 64; c.X_RFW_WIDTH = 64; c.X_HARTID_WIDTH = 8;
    c.X_DUALREAD = 0; c.X_DUALWRITE = 0;
    return c;
  endfunction
  localparam config_pkg::g6lc_cfg_t C = configuration();
  localparam g6lc_hyp_pkg::g6lc_hyp_cfg_t H = g6lc_hyp_pkg::Hyp8;

  localparam int BANKS = 4, ENTRIES = 4, NPORTS = 2, PRF_W = 6;
  localparam int TIDW = C.TRANS_ID_BITS;
  localparam int NSB = C.NR_SB_ENTRIES;

  typedef `G6LC_BRANCHPREDICT_SBE_T(C) branchpredict_sbe_t;
  typedef `G6LC_EXCEPTION_T(C)         exception_t;
  typedef `G6LC_SCOREBOARD_ENTRY_T(C)  sbe_t;

  logic clk = 0, rst_n = 0, flush = 0;
  int checked = 0;
  int cycles = 0;

  // ------------------------- bank candidate emulation -------------------------
  logic [BANKS-1:0][1:0]                    cand_v = '0;
  logic [BANKS-1:0][1:0][1:0]               cand_i = '0;
  logic [BANKS-1:0][1:0][TIDW-1:0]          cand_tid = '0;
  logic [BANKS-1:0][1:0]                    cand_fp = '0;
  logic [BANKS-1:0][1:0]                    cand_spec = '0;
  logic [BANKS-1:0][1:0][1:0]               cand_spec_ab = '0;
  logic [BANKS-1:0][1:0][1:0][TIDW-1:0]     cand_ptid = '0;
  logic [BANKS-1:0][1:0]                    cand_fluin = '0;
  logic [BANKS-1:0][1:0][1:0]               cand_wbport = '0;
  logic [BANKS-1:0][1:0][4:0]               cand_wboff = '0;
  logic [BANKS-1:0][1:0][3:0]               cand_gate = '0;
  logic [BANKS-1:0][1:0]                    cand_div = '0;
  logic [BANKS-1:0][1:0]                    cand_port0 = '0;
  logic [NSB-1:0]                           cancel = '0;
  logic [TIDW-1:0]                          commit_ptr = '0;

  logic [BANKS-1:0][NPORTS-1:0]             take_v, take_cand, ack_v;
  logic [BANKS-1:0][NPORTS-1:0][1:0]        ack_idx;
  logic [NPORTS-1:0][1:0]                   pay_bank, pay_entry;
  sbe_t [NPORTS-1:0]                        pay_sbe, mut_pay_sbe;
  logic [NPORTS-1:0][31:0]                  pay_orig, mut_pay_orig;
  logic [NPORTS-1:0][PRF_W-1:0]             pay_prd, mut_pay_prd;
  sbe_t [NPORTS-1:0]                        issue_sbe;
  logic [NPORTS-1:0][31:0]                  issue_orig;
  logic [NPORTS-1:0][PRF_W-1:0]             issue_prd;
  logic [NPORTS-1:0]                        issue_v, issue_spec, issue_ack = '0;
  logic [NPORTS-1:0][1:0]                   issue_spec_ab;
  logic [NPORTS-1:0][1:0][TIDW-1:0]         issue_ptid;

  // payload write side (allocation preload)
  logic [1:0]                               wr_v = '0;
  logic [1:0][1:0]                          wr_bank = '0, wr_entry = '0;
  sbe_t [1:0]                               wr_sbe;
  logic [1:0][31:0]                         wr_orig = '0;
  logic [1:0][PRF_W-1:0]                    wr_prd = '0;

  // the wrapper's read-enable: OR of the take column (accept event)
  logic [NPORTS-1:0] pay_ren;
  for (genvar p = 0; p < NPORTS; p++) begin : g_ren
    always_comb begin
      pay_ren[p] = 1'b0;
      for (int b = 0; b < BANKS; b++) pay_ren[p] |= take_v[b][p];
    end
  end
  // the combinational-read negative control reads the index the grant
  // actually captured; the bench holds it so a reused slot is observed.
  logic [1:0] held_bank = '0, held_entry = '0;

  g6lc_iq_payload #(
      .BANKS(BANKS), .ENTRIES(ENTRIES), .PRF_W(PRF_W), .NLANES(2),
      .NPORTS(NPORTS), .scoreboard_entry_t(sbe_t)
  ) i_pay (
      .clk_i(clk), .rst_ni(rst_n),
      .wr_v_i(wr_v), .wr_bank_i(wr_bank), .wr_entry_i(wr_entry),
      .wr_sbe_i(wr_sbe), .wr_orig_i(wr_orig), .wr_prd_i(wr_prd),
      .rd_enable_i(pay_ren), .rd_bank_i(pay_bank), .rd_entry_i(pay_entry),
      .rd_sbe_o(pay_sbe), .rd_orig_o(pay_orig), .rd_prd_o(pay_prd));

  mut_iq_payload_comb #(
      .BANKS(BANKS), .ENTRIES(ENTRIES), .PRF_W(PRF_W), .NLANES(2),
      .NPORTS(NPORTS), .scoreboard_entry_t(sbe_t)
  ) i_mut_pay (
      .clk_i(clk), .rst_ni(rst_n),
      .wr_v_i(wr_v), .wr_bank_i(wr_bank), .wr_entry_i(wr_entry),
      .wr_sbe_i(wr_sbe), .wr_orig_i(wr_orig), .wr_prd_i(wr_prd),
      .rd_enable_i(pay_ren),
      .rd_bank_i({NPORTS{held_bank}}), .rd_entry_i({NPORTS{held_entry}}),
      .rd_sbe_o(mut_pay_sbe), .rd_orig_o(mut_pay_orig),
      .rd_prd_o(mut_pay_prd));

  g6lc_iq_arb #(
      .G6LCCfg(C), .BANKS(BANKS), .ENTRIES(ENTRIES), .TID_W(TIDW),
      .PRF_W(PRF_W), .NPORTS(NPORTS), .scoreboard_entry_t(sbe_t)
  ) i_arb (
      .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
      .cancelled_mask_i(cancel), .commit_ptr_i(commit_ptr),
      .cand_v_i(cand_v), .cand_i_i(cand_i), .cand_tid_i(cand_tid),
      .cand_fp_i(cand_fp), .cand_spec_i(cand_spec),
      .cand_spec_ab_i(cand_spec_ab), .cand_ptid_i(cand_ptid),
      .cand_fluin_i(cand_fluin), .cand_wbport_i(cand_wbport),
      .cand_wboff_i(cand_wboff), .cand_gate_i(cand_gate),
      .cand_div_i(cand_div), .cand_port0_i(cand_port0),
      .lsu_ready_i(1'b1), .fpu_ready_i(1'b1), .csr_ready_i(1'b1),
      .mult_ready_i(1'b1),
      .pay_bank_o(pay_bank), .pay_entry_o(pay_entry),
      .pay_sbe_i(pay_sbe), .pay_orig_i(pay_orig), .pay_prd_i(pay_prd),
      .issue_sbe_o(issue_sbe), .issue_orig_o(issue_orig),
      .issue_prd_o(issue_prd), .issue_valid_o(issue_v),
      .issue_spec_o(issue_spec), .issue_spec_ab_o(issue_spec_ab),
      .issue_ptid_o(issue_ptid), .issue_ack_i(issue_ack),
      .hyp_wb_reserve_stall_o(),
      .take_v_o(take_v), .take_cand_o(take_cand),
      .ack_v_o(ack_v), .ack_idx_o(ack_idx));

  // ------------------------- IRO-acceptance reservation -------------------------
  logic [NPORTS-1:0]            res_offer = '0, res_accept = '0;
  fu_t  [NPORTS-1:0]            res_fu = '{default: NONE};
  fu_op [NPORTS-1:0]            res_op = '{default: ADD};
  logic [NPORTS-1:0][TIDW-1:0]  res_tid = '0;
  logic [NSB-1:0]               res_sblive = '1;
  logic [C.NrWbPorts-1:0]       res_wb_v = '0;
  logic [C.NrWbPorts-1:0][TIDW-1:0] res_wb_tid = '0;
  logic [NPORTS-1:0]            res_admit;
  logic                         res_stall;

  g6lc_flu_reserve #(.G6LCCfg(C), .HypCfg(H)) i_res (
      .clk_i(clk), .rst_ni(rst_n),
      .offer_i(res_offer), .accept_i(res_accept),
      .fu_i(res_fu), .op_i(res_op), .tid_i(res_tid),
      .sb_live_i(res_sblive),
      .wb_valid_i(res_wb_v), .wb_tid_i(res_wb_tid),
      .admit_o(res_admit), .stall_o(res_stall));

  // =====================================================================
  // IRO stale-lane throttle regression (h33): the real
  // issue_read_operands. A drained lane keeps its last presented record on
  // issue_instr_i while issue_instr_valid_i drops; the in-order
  // dual-issue throttle must only apply while the older lane presents a
  // valid instruction this cycle -- the unqualified version held
  // fus_busy[1] = '1 on the stale STORE forever and port 1 could never ack.
  // =====================================================================
  localparam int HBITS = (C.NrHarts <= 1) ? 1 : $clog2(C.NrHarts);
  typedef struct packed {
    logic           valid;
    logic [C.XLEN-1:0] data;
    logic           ex_valid;
    logic [TIDW-1:0]   trans_id;
  } iro_wb_t;
  typedef struct packed {
    logic [NSB-1:0]            still_issued;
    logic [TIDW-1:0]           issue_pointer;
    iro_wb_t [C.NrWbPorts-1:0] wb;
    sbe_t    [NSB-1:0]         sbe;
  } iro_fwd_t;
  typedef struct packed {
    fu_t               fu;
    fu_op              operation;
    logic [C.XLEN-1:0] operand_a;
    logic [C.XLEN-1:0] operand_b;
    logic [C.XLEN-1:0] imm;
    logic [C.XLEN-1:0] operand_c;
    logic [C.XLEN-1:0] operand_b_hi;
    logic [C.XLEN-1:0] operand_c_hi;
    logic [TIDW-1:0]   trans_id;
    logic [HBITS-1:0]  hart;
  } iro_fud_t;
  typedef logic [(C.NrRgprPorts == 3 ? C.XLEN : C.FLen)-1:0] iro_rs3_t;
  // CVXIF struct shapes (CvxifEn=0 -- handshake inert, fields must exist).
  typedef logic [C.X_ID_WIDTH-1:0]     iro_xid_t;
  typedef logic [C.X_HARTID_WIDTH-1:0] iro_xhid_t;
  typedef struct packed {
    logic [31:0] instr; iro_xhid_t hartid; iro_xid_t id;
  } iro_xireq_t;
  typedef struct packed {
    logic                              accept;
    logic [C.X_DUALWRITE:0]            writeback;
    logic [C.X_NUM_RS+C.X_DUALREAD-1:0] register_read;
  } iro_xiresp_t;
  typedef struct packed {
    iro_xhid_t hartid; iro_xid_t id;
    logic [C.X_NUM_RS-1:0][C.X_RFR_WIDTH-1:0] rs;
    logic [C.X_NUM_RS+C.X_DUALREAD-1:0]       rs_valid;
  } iro_xreg_t;
  typedef struct packed {
    iro_xhid_t hartid; iro_xid_t id; logic commit_kill;
  } iro_xcmt_t;

  sbe_t     [NPORTS-1:0]          iro_sbe = '{default: '0};
  logic     [NPORTS-1:0][31:0]    iro_orig = '0;
  logic     [NPORTS-1:0]          iro_v = '0, iro_ack;
  iro_fwd_t                       iro_fwd = '0;
  logic                           iro_lsu_ready = 1'b1;
  logic [2:0]                     iro_lsu_count = '0;
  logic     [NPORTS-1:0]          iro_lsu_valid;

  issue_read_operands #(
      .G6LCCfg(C), .HypCfg(H),
      .branchpredict_sbe_t(branchpredict_sbe_t),
      .fu_data_t(iro_fud_t),
      .scoreboard_entry_t(sbe_t),
      .forwarding_t(iro_fwd_t),
      .writeback_t(iro_wb_t),
      .rs3_len_t(iro_rs3_t),
      .x_issue_req_t(iro_xireq_t),
      .x_issue_resp_t(iro_xiresp_t),
      .x_register_t(iro_xreg_t),
      .x_commit_t(iro_xcmt_t)
  ) i_iro (
      .clk_i(clk), .rst_ni(rst_n), .flush_i(flush), .stall_i(1'b0),
      .issue_instr_i(iro_sbe), .issue_instr_i_prev('0),
      .orig_instr_i(iro_orig),
      .issue_instr_valid_i(iro_v), .issue_ack_o(iro_ack),
      .issue_spec_ab_i('0), .issue_ptid_i('0),
      .alu_fwd_tid_i('0), .alu_fwd_qtid_i('0), .alu_fwd_rtid_i('0),
      .alu_fwd_a_o(), .alu_fwd_b_o(),
      .fwd_i(iro_fwd),
      .ooo_op_a_i('0), .ooo_op_b_i('0), .ooo_op_c_i('0),
      .ooo_op_a_valid_i('1), .ooo_op_b_valid_i('1), .ooo_op_c_valid_i('1),
      .fu_data_o(), .alu_bypass_o(),
      .rs1_forwarding_o(), .rs2_forwarding_o(),
      .pc_o(), .branch_hart_o(), .is_zcmt_o(), .is_compressed_instr_o(),
      .flu_ready_i(1'b1), .csr_ready_i(1'b1),
      .alu_valid_o(), .aes_valid_o(), .branch_valid_o(),
      .tinst_o(), .branch_predict_o(),
      .lsu_ready_i(iro_lsu_ready), .lsu_count_i(iro_lsu_count),
      .lsu_valid_o(iro_lsu_valid),
      .mult_valid_o(),
      .fpu_ready_i(1'b1), .fpu_early_valid_i(1'b0), .fpu_valid_o(),
      .fpu_fmt_o(), .fpu_rm_o(), .fpu_hart_o(),
      .alu2_valid_o(), .csr_valid_o(), .cvxif_valid_o(),
      .cvxif_ready_i(1'b0), .cvxif_off_instr_o(),
      .hart_id_i('0),
      .x_issue_ready_i(1'b0), .x_issue_resp_i('0),
      .x_issue_valid_o(), .x_issue_req_o(),
      .x_register_ready_i(1'b0), .x_register_valid_o(), .x_register_o(),
      .x_commit_valid_o(), .x_commit_o(),
      .x_transaction_accepted_o(), .x_transaction_rejected_o(),
      .x_issue_writeback_o(), .x_id_o(),
      .waddr_i('0), .wdata_i('0), .we_gpr_i('0), .whart_i('0), .we_fpr_i('0),
      .stall_issue_o(), .hyp_wb_reserve_stall_o(),
      .rvfi_rs1_o(), .rvfi_rs2_o(), .rvfi_operand_valid_o(),
      .rvfi_operand_tid_o(),
      .orig_instr_aes_bits(), .g1gq_raddr_i('0), .g1gq_rhart_i('0),
      .g1gq_rdata_o());

  // c.nop-class record: renamed ALU op with no register dependency
  // (rd/rs1/rs2 all x0), the exact shape that deadlocked h33's port 1.
  function automatic sbe_t nop_sbe(input int tid);
    sbe_t e;
    e = '0; e.valid = 1; e.trans_id = TIDW'(tid);
    e.fu = ALU; e.op = ADD;
    e.rd = '0; e.rs1 = '0; e.rs2 = '0;
    e.ooo_renamed = 1'b1;
    return e;
  endfunction

  // sample the combinational issue_ack_o; allow up to `budget` drain
  // cycles for the FLU reservation admit to open (h33 held it ~50k cycles).
  task automatic iro_expect_ack(input int port, input int budget,
                                input string tag);
    bit got;
    got = 0;
    for (int t = 0; t < budget; t++) begin
      #2;
      if (iro_ack[port]) got = 1'b1;
      else tick();
    end
    check(got, tag);
  endtask

  // ------------------------- stimulus -------------------------
  task automatic tick;
    // settle combinational candidate nets before the sampling edge
    #1; clk = 1; #2; clk = 0; #2;
    cycles++;
    if (cycles > 800) $fatal(1, "tb_g6lc_hyp8_issue watchdog");
  endtask

  task automatic check(input bit ok, input string tag);
    if (!ok) $fatal(1, "%s", tag);
    checked++;
  endtask

  function automatic sbe_t mk_sbe(input int tid);
    sbe_t e;
    e = '0; e.valid = 1; e.trans_id = TIDW'(tid);
    e.rd = REG_ADDR_SIZE'(tid + 8);
    e.fu = ALU; e.op = ADD;
    return e;
  endfunction

  task automatic preload(input int lane, input int bank, input int entry,
                         input int tid, input logic [31:0] orig,
                         input logic [PRF_W-1:0] prd);
    wr_v[lane] = 1; wr_bank[lane] = 2'(bank); wr_entry[lane] = 2'(entry);
    wr_sbe[lane] = mk_sbe(tid); wr_orig[lane] = orig;
    wr_prd[lane] = prd;
  endtask

  task automatic offer(input int bank, input int ci, input int entry,
                       input int tid, input logic p0, input logic div);
    cand_v[bank][ci] = 1; cand_i[bank][ci] = 2'(entry);
    cand_tid[bank][ci] = TIDW'(tid);
    cand_port0[bank][ci] = p0; cand_div[bank][ci] = div;
  endtask

  task automatic clear_cands;
    cand_v = '0; cand_port0 = '0; cand_div = '0;
    cand_wbport = '0; cand_wboff = '0;
  endtask

  // reservation offer probe: drive one lane for a cycle
  task automatic res_drive(input int lane, input fu_t fu, input fu_op op,
                           input int tid, input logic acc);
    res_offer[lane] = 1; res_fu[lane] = fu; res_op[lane] = op;
    res_tid[lane] = TIDW'(tid); res_accept[lane] = acc;
    #2;
  endtask

  task automatic res_idle;
    res_offer = '0; res_accept = '0; res_fu = '{default: NONE};
    res_op = '{default: ADD}; res_tid = '0; #2;
  endtask

  // drain the reservation window (RES_WIN <= 10 for MultStages=8/AluStages=3)
  task automatic res_drain;
    res_idle();
    repeat (12) tick();
  endtask

  // one accepted fixed-latency lane, then verify the window bit lands at
  // the expected 1+cycles offset
  task automatic res_probe(input fu_t fu, input fu_op op, input int tid,
                           input int exp_off, input string tag);
    res_drive(0, fu, op, tid, 1'b1);
    check(res_admit[0], {tag, "_ADMIT"});
    check(!res_stall, {tag, "_STALL"});
    tick(); res_idle();
    // the accepted bit entered reserved_next at exp_off and the capture
    // edge shifted the window down one
    check(int'(i_res.gen_reserve.reserved_q) == (1 << (exp_off - 1)),
          {tag, "_OFFSET"});
    res_drain();
  endtask

  initial begin
    // window reachability: the MultStages=8 / AluStages=3 profile yields
    // RES_WIN = 2 + max(8,3,2) = 10. The DUT's own initial asserts check
    // every supported offset fits; the MUL probe below lands at bit 9,
    // which only exists if the countdown/window width is sufficient.
    wr_sbe = '{default: '0};
    #2; tick(); tick(); rst_n = 1; #2;

    // ============ LSU grant/queue credit (lost-load regression) ============
    // Depth is 4. lsu_count_i is posts already in the queue. lsu_valid_q
    // and the cycle before it are the AGU shadow, not yet in the count.
    // A new grant is refused only when count + shadow >= 4, or when
    // lsu_ready_i is low. One strobe no longer skips the next grant
    // (that skip held a stream to one memory op every other cycle).
    // The depth-2 overwrite (hyp8-osbi-ld-diag-r1, tid 5) is the case
    // this sum still refuses. Not simulated this pass.
    iro_fwd.still_issued = '1;
    iro_v = '0; iro_lsu_ready = 1'b1; iro_lsu_count = '0; #2;

    iro_sbe[0] = mk_sbe(20);
    iro_sbe[0].fu = LOAD; iro_sbe[0].op = LD; iro_sbe[0].ooo_renamed = 1'b1;
    iro_v[0] = 1'b1;
    iro_expect_ack(0, 4, "IRO_LSU_LD1_ACK");
    tick();
    check(iro_lsu_valid[0], "IRO_LSU_VQ_PULSE1");
    // Second grant while one shadow slot is full and the queue is empty.
    iro_sbe[0] = mk_sbe(21);
    iro_sbe[0].fu = LOAD; iro_sbe[0].op = LD; iro_sbe[0].ooo_renamed = 1'b1;
    #2;
    check(iro_ack[0], "IRO_LSU_PIPE2_ACK");
    tick();
    iro_sbe[0] = mk_sbe(22);
    iro_sbe[0].fu = LOAD; iro_sbe[0].op = LD; iro_sbe[0].ooo_renamed = 1'b1;
    #2;
    check(iro_ack[0], "IRO_LSU_PIPE3_ACK");
    // Queue reports full. The next load waits even though ready was 1.
    iro_lsu_count = 3'd4; #2;
    check(!iro_ack[0], "IRO_LSU_FULL_BLOCK");
    iro_lsu_count = '0;
    iro_lsu_ready = 1'b0; #2;
    check(!iro_ack[0], "IRO_LSU_RDY_BLOCK");
    iro_lsu_ready = 1'b1; #2;
    check(iro_ack[0], "IRO_LSU_RDY_RELEASE");
    tick();
    iro_sbe[0] = mk_sbe(24);
    iro_sbe[0].fu = STORE; iro_sbe[0].op = SD; iro_sbe[0].ooo_renamed = 1'b1;
    iro_sbe[0].rd = '0;
    #2;
    check(iro_ack[0], "IRO_LSU_STORE_PIPE_ACK");
    tick();
    iro_v = '0; iro_lsu_count = '0; res_drain();
    $display("IRO_LSU_SHADOW_OK checks=%0d", checked);
    iro_fwd = '0;

    // ============ payload preload (bank,entry -> sbe) ============
    preload(0, 0, 0, 1, 32'hA0A0_0001, 6'h11);
    preload(1, 1, 1, 2, 32'hB0B0_0002, 6'h22); tick();
    preload(0, 0, 2, 3, 32'hC0C0_0003, 6'h33);
    preload(1, 2, 0, 5, 32'hD0D0_0005, 6'h55); tick();
    preload(0, 3, 3, 10, 32'hDEDE_0010, 6'h3F);
    preload(1, 2, 1, 9, 32'hF0F0_0009, 6'h09); tick();
    preload(0, 0, 3, 4, 32'hE0E0_0004, 6'h44); tick();
    wr_v = '0; #2;

    // ============ A: adjacent grants carry distinct payloads ============
    offer(0, 0, 0, 1, 0, 0);   // bank0 c0 -> entry0 (tid1, oldest)
    offer(1, 0, 1, 2, 0, 0);   // bank1 c0 -> entry1 (tid2)
    // g7 WbReserve: two takes in one cycle need disjoint future-writeback
    // slots on the shared FLU port. wb_off=0 for both means the same
    // slot -- port1 would legally defer. Give the pair the two real ALU
    // offsets (6 low / 7 full); both exit the window during section B's
    // held-check cycles where no take is evaluated.
    cand_wboff[0][0] = 5'd6;
    cand_wboff[1][0] = 5'd7;
    tick();                    // candidates captured
    tick();                    // tournament winner staged; take is this edge
    check(take_v[0][0] && !take_cand[0][0], "ARB_TAKE_P0_TID1");
    check(take_v[1][1] && !take_cand[1][1], "ARB_TAKE_P1_TID2");
    // adjacent grant on port 0: offer tid3 (bank0 c0 -> entry2)
    clear_cands();
    offer(0, 0, 2, 3, 0, 0);
    tick();                    // T1 winners present; tid3 captured
    check(issue_v[0] && issue_sbe[0].trans_id == 4'd1 &&
          issue_orig[0] == 32'hA0A0_0001 && issue_prd[0] == 6'h11,
          "ARB_PAYLOAD_TID1");
    check(issue_v[1] && issue_sbe[1].trans_id == 4'd2 &&
          issue_orig[1] == 32'hB0B0_0002 && issue_prd[1] == 6'h22,
          "ARB_PAYLOAD_TID2");
    issue_ack = 2'b11; #1;   // ack_v is a combinational echo of issue_ack
    check(ack_v[0][0] && ack_idx[0][0] == 0, "ARB_ACK_B0E0");
    check(ack_v[1][1] && ack_idx[1][1] == 1, "ARB_ACK_B1E1");
    tick();                    // port free; tid3's staged winner takes
    check(take_v[0][0] && !take_cand[0][0], "ARB_TAKE_ADJACENT");
    clear_cands();
    tick();                    // the adjacent grant presents
    issue_ack = '0;
    check(issue_v[0] && issue_sbe[0].trans_id == 4'd3 &&
          issue_orig[0] == 32'hC0C0_0003 && issue_prd[0] == 6'h33,
          "ARB_PAYLOAD_TID3");
    issue_ack = 1; tick(); issue_ack = 0; #2;   // drain tid3

    // ============ B: held record >=3 cycles, no duplicate take ============
    offer(2, 0, 0, 5, 0, 0);   // bank2 c0 -> entry0 (tid5), kept offered
    tick();                    // capture
    tick();                    // -> take on port0
    check(take_v[2][0], "ARB_TAKE_TID5");
    tick();                    // -> present
    check(issue_v[0] && issue_sbe[0].trans_id == 4'd5, "ARB_PRES_TID5");
    // hold the presentation; the stale candidate stays offered.
    for (int i = 0; i < 3; i++) begin
      tick();
      check(issue_v[0] && issue_sbe[0].trans_id == 4'd5 &&
            issue_orig[0] == 32'hD0D0_0005, "ARB_HELD_TID5");
      check(!take_v[2][0] && !take_v[2][1], "ARB_NO_DUP_TAKE");
    end
    // the emulated bank drops a granted offer once the held record's ack
    // is visible -- clear the stale offer before the ack edge
    clear_cands();
    issue_ack = 1; #1;
    check(ack_v[2][0] && ack_idx[2][0] == 2'd0, "ARB_ACK_TID5");
    tick(); issue_ack = 0; tick();

    // ============ C: serial-class candidates never take port>0 ============
    offer(0, 0, 3, 4, 1, 0);   // bank0 c0 -> entry3 (tid4, serial class)
    offer(2, 0, 1, 9, 1, 0);   // bank2 c0 -> entry1 (tid9, serial class)
                               // (a real bank offers c1 only beside c0:
                               // c1 is its second-oldest entry, never
                               // the head -- the pair merge relies on it)
    tick();                    // capture both serial offers
    tick();                    // -> port0 takes tid4 only
    check(take_v[0][0], "ARB_SERIAL_TAKE_P0");
    check(!take_v[2][1], "ARB_SERIAL_NO_P1_TAKE");
    check(!(take_v[2][0]), "ARB_SERIAL_ONE_AT_A_TIME");
    // tid4's grant is consumed -- the bank drops its offer; tid9 remains
    // offered and is eligible on port 0 only.
    cand_v[0] = '0;
    tick();                    // -> T_c2: tid4 presents; tid9 wins port0
    check(issue_v[0] && issue_sbe[0].trans_id == 4'd4, "ARB_SERIAL_PRES4");
    // tid9's serial flag keeps it off port1 even though port1 is idle;
    // it takes port0 behind tid4's pending presentation (held pres +
    // fresh win share the port, gated on pres_q only)
    check(take_v[2][0], "ARB_SERIAL_SECOND_P0");
    check(!take_v[2][1], "ARB_SERIAL_NEVER_P1");
    clear_cands();             // tid9's offer is stale after its take
    tick();                    // -> T_c3: tid4 held; tid9 waits in win_q
    check(issue_v[0] && issue_sbe[0].trans_id == 4'd4 &&
          issue_orig[0] == 32'hE0E0_0004, "ARB_SERIAL_HELD4");
    issue_ack = 1; #1;         // ack tid4's held presentation
    check(ack_v[0][0] && ack_idx[0][0] == 2'd3, "ARB_SERIAL_ACK4");
    tick(); issue_ack = 0;     // -> T_c4: tid9 presents
    check(issue_v[0] && issue_sbe[0].trans_id == 4'd9 &&
          issue_orig[0] == 32'hF0F0_0009, "ARB_SERIAL_PRES9");
    issue_ack = 1; tick(); issue_ack = 0; #2;

    // ============ D: payload snapshot vs slot reuse + mutant ============
    offer(3, 0, 3, 10, 0, 0);  // bank3 c0 -> entry3 (tid10)
    tick();                    // capture
    tick();                    // take
    check(take_v[3][0], "ARB_TAKE_TID10");
    held_bank = pay_bank[0]; held_entry = pay_entry[0];
    clear_cands();
    tick();                    // -> present (payload regs hold sbe10)
    check(issue_v[0] && issue_orig[0] == 32'hDEDE_0010, "ARB_PRES_TID10");
    // slot reuse while the presentation is held: bank3/entry3 rewritten
    preload(0, 3, 3, 15, 32'h0000_0BAD, 6'h00);
    tick(); wr_v = '0;         // -> held record; mem[3][3] now sbe15
    check(issue_v[0] && issue_sbe[0].trans_id == 4'd10 &&
          issue_orig[0] == 32'hDEDE_0010, "PAY_SNAPSHOT_HELD");
    check(pay_orig[0] == 32'hDEDE_0010, "PAY_REG_HOLDS_GRANT");
    check(mut_pay_orig[0] == 32'h0000_0BAD, "PAY_MUT_COMB_LEAK");
    issue_ack = 1; tick(); issue_ack = 0; tick();

    // ============ E: IRO-acceptance reservation distances ============
    // CSR/AES complete in 1 -> offset 2; ALU-low + branch in 2 -> 3;
    // ALU-full in AluStages=3 -> 4; MUL in MultStages=8 -> 9.
    res_probe(CSR,       CSR_READ,  1, 2, "RES_CSR");
    res_probe(AES,       ADD,       2, 2, "RES_AES");
    res_probe(CTRL_FLOW, JALR,      3, 3, "RES_BRANCH");
    res_probe(ALU,       ADD,       4, 3, "RES_ALULOW");
    res_probe(ALU,       SLL,       5, 4, "RES_ALUFULL");
    res_probe(MULT,      MUL,       6, 9, "RES_MUL");

    // consecutive CSRs complete on consecutive cycles: the next-cycle
    // offer is admitted, not a collision.
    res_drive(0, CSR, CSR_READ, 7, 1'b1); tick();
    res_drive(0, CSR, CSR_READ, 8, 1'b0);
    check(res_admit[0] && !res_stall, "RES_CSR_NO_COLLIDE");
    res_idle(); res_drain();

    // real collision: ALU ADD (offset 3) accepted at T holds bit 2 at
    // T+1 -- exactly the slot a CSR (offset 2) needs next cycle.
    res_drive(0, ALU, ADD, 9, 1'b1); tick();
    res_drive(0, CSR, CSR_READ, 10, 1'b0);
    check(!res_admit[0] && res_stall, "RES_ALU_CSR_COLLIDE");
    res_idle(); res_drain();

    // two same-cycle CSR lanes: only the first is admitted; only the
    // admitted lane accepts -- no phantom second claim lands.
    res_drive(0, CSR, CSR_READ, 11, 1'b0);
    res_drive(1, CSR, CSR_READ, 12, 1'b0);
    check(res_admit[0] && !res_admit[1], "RES_SAME_CYCLE_ONE");
    res_accept = 2'b01;
    tick(); res_idle();
    check(int'(i_res.gen_reserve.reserved_q) == (1 << 1),
          "RES_NO_PHANTOM_CLAIM");
    res_drain();

    // a stalled-before-accept offer reserves nothing.
    res_drive(0, CSR, CSR_READ, 9, 1'b0);
    check(res_admit[0], "RES_STALL_ADMIT_VISIBLE");
    for (int i = 0; i < 3; i++) begin
      tick();
      check(i_res.gen_reserve.reserved_q == '0, "RES_NO_PHANTOM");
    end
    res_idle(); res_drain();

    // divider ownership: admitted on an empty window, held until the
    // real writeback (or scoreboard reclamation) -- not a ready flag.
    res_drive(0, MULT, DIV, 10, 1'b1);
    check(res_admit[0], "RES_DIV_ADMIT");
    tick(); res_idle();
    for (int i = 0; i < 3; i++) begin
      check(i_res.gen_reserve.div_live_q, "RES_DIV_OWNED");
      res_drive(0, CSR, CSR_READ, 11, 1'b0);
      check(!res_admit[0], "RES_DIV_BLOCKS_FLU");
      res_idle(); tick();
    end
    res_wb_v[0] = 1; res_wb_tid[0] = TIDW'(10);
    tick(); res_wb_v = '0;
    res_drive(0, CSR, CSR_READ, 11, 1'b0);
    check(res_admit[0], "RES_DIV_RELEASED_BY_WB");
    res_idle(); res_drain();
    // reclamation path: the scoreboard slot dying frees the owner.
    res_drive(0, MULT, DIV, 12, 1'b1);
    check(res_admit[0], "RES_DIV2_ADMIT");
    tick(); res_idle();
    res_sblive = '1; res_sblive[12] = 1'b0;
    tick();
    check(!i_res.gen_reserve.div_live_q, "RES_DIV_RECLAIMED");
    res_sblive = '1;

    // ============ IRO stale-lane throttle (h33 regression) ============
    // The in-order dual-issue throttle keys on lane p-1's presented record
    // and must release when that lane drains. issue_instr_valid_i and the
    // record are driven exactly as the staged iss_q presents them: an
    // acked lane drops its valid bit but the record fields stay.
    iro_fwd.still_issued = '1;
    iro_v = '0; #2;

    // -- STALE_STORE: a STORE acked on port 0 leaves fu==STORE behind.
    iro_sbe[0] = mk_sbe(10);
    iro_sbe[0].fu = STORE; iro_sbe[0].op = SD; iro_sbe[0].rd = '0;
    iro_sbe[0].ooo_renamed = 1'b1;
    iro_v[0] = 1'b1; iro_v[1] = 1'b0;
    iro_expect_ack(0, 4, "IRO_STORE_P0_ACK");
    iro_v[0] = 1'b0;                        // lane drained, record retained
    iro_sbe[1] = nop_sbe(4);                // c.nop class on port 1
    iro_v[1] = 1'b1;
    iro_expect_ack(1, 4, "IRO_STALE_STORE_P1_ACK");
    iro_v[1] = 1'b0; res_drain();

    // -- STALE_ALU: same drain on an ALU record.
    iro_sbe[0] = mk_sbe(11); iro_sbe[0].ooo_renamed = 1'b1;
    iro_v[0] = 1'b1; iro_v[1] = 1'b0;
    iro_expect_ack(0, 4, "IRO_ALU_P0_ACK");
    iro_v[0] = 1'b0;
    iro_sbe[1] = nop_sbe(5);
    iro_v[1] = 1'b1;
    iro_expect_ack(1, 4, "IRO_STALE_ALU_P1_ACK");
    iro_v[1] = 1'b0; res_drain();

    // -- PAIR_ALU: positive throttle. Both lanes live ALU in the same
    //   cycle: port 1 must NOT ack that cycle (the in-order serialize is
    //   the throttle's contract), then must ack once port 0 drains even
    //   though the stale record behind it is still fu==ALU.
    iro_sbe[0] = mk_sbe(12); iro_sbe[0].ooo_renamed = 1'b1;
    iro_sbe[1] = mk_sbe(6);  iro_sbe[1].ooo_renamed = 1'b1;
    iro_v = 2'b11; #2;
    check(iro_ack[0],  "IRO_PAIR_P0_ACK");
    check(!iro_ack[1], "IRO_PAIR_P1_HELD");
    tick();                                 // port-0 accept edge
    iro_v[0] = 1'b0;
    iro_expect_ack(1, 4, "IRO_PAIR_P1_ACK_AFTER_DRAIN");
    iro_v = '0; res_drain();

    $display("HYP8_ISSUE_PASS checked=%0d", checked);
    $finish;
  end
endmodule

// ----------------------------------------------------------------------
// tb_g6lc_hyp8_dispatch -- the real g6lc_ooo_dispatch with its real
// rename/IQ/PRF/ROB/LSQ children on the actual built g6lc64_hyp8 config.
// Directed contracts:
//   A/B  a WB that lands during a consumer's rename stages must still
//        reach the consumer at IQ allocation -- allocation readiness is
//        the live busy bitmap, not the R1 snapshot (lost-wakeup fix).
//        For FADD the FP sources classify on rs2/result[4:0] while rs1
//        stays integer, so the FP dependence rides rs2 and the integer
//        boundary rides rs1.
//   C    intra-group RAW: the consumer of a same-group producer must not
//        issue before the producer's WB (fresh dest busy at alloc).
//   D    a mispredict whose checkpoint retires between select and repair
//        leaves count 0 (never an underflowed all-ones), and the ring
//        accepts another branch afterwards.
//   G    a rename publish edge coincident with a kill (flush_unissued,
//        then mispredict) while dispatch_valid_i still presents the
//        pre-flush lanes must not re-create grp_v_q: no dispatch_ack_o on
//        the following cycles, no IQ allocation, no issue accept; a fresh
//        post-kill group then acks and issues normally (kill dominates
//        publish -- the dispatch_valid_i zombie mask samples the
//        scoreboard's pre-flush presentation).
// Combinational acks (dack, issue accept) are sampled just before each
// posedge; stimulus is driven on the low phase.
module tb_g6lc_hyp8_dispatch;
  import g6lc_core_pkg::*;
  `include "g6lc_core_types.svh"
  `include "rvfi_types.svh"

  // The actual built g6lc64_hyp8 config through the same helper the core
  // uses -- not a hand-edited cfg.
  localparam config_pkg::g6lc_cfg_t C =
      build_config_pkg::build_config(g6lc_config_pkg::g6lc_cfg);
  localparam g6lc_hyp_pkg::g6lc_hyp_cfg_t H = g6lc_hyp_pkg::Hyp8;

  typedef `G6LC_BRANCHPREDICT_SBE_T(C) branchpredict_sbe_t;
  typedef `G6LC_EXCEPTION_T(C)         exception_t;
  typedef `G6LC_SCOREBOARD_ENTRY_T(C)  sbe_t;

  localparam int NP  = C.NrIssuePorts;
  localparam int NPC = C.NrCommitPorts;
  localparam int NWB = C.NrWbPorts;
  localparam int NSB = C.NR_SB_ENTRIES;
  localparam int TID = C.TRANS_ID_BITS;
  localparam int HW  = (C.NrHarts > 1) ? $clog2(C.NrHarts) : 1;

  logic clk = 0, rst_n = 0;
  int checked = 0;
  int cycles = 0;

  // ------------------------- module nets -------------------------
  logic [1:0]                 phys_v = '0;
  logic [1:0][C.PLEN-1:0]     phys_addr = '0;
  logic [1:0][TID-1:0]        phys_id = '0;
  logic [1:0][HW-1:0]         phys_hart = '0;
  logic [1:0][1:0]            phys_size = '0;
  logic [1:0]                 mod_v = '0;
  logic [1:0][C.PLEN-1:0]     mod_addr = '0;
  logic [NSB-1:0]             phys_pending, phys_replay;
  logic                       flush = 0, flush_un = 0;
  logic [NSB-1:0]             cancel = '0, sb_live = '0;
  sbe_t [NP-1:0]              dsbe;
  logic [NP-1:0][31:0]        dorig = '0;
  logic [NP-1:0]              dvalid = '0, dack;
  sbe_t [NP-1:0]              isbe;
  logic [NP-1:0][31:0]        iorig;
  logic [NP-1:0]              ivalid;
  logic [NP-1:0]              iack = '1;
  logic [NP-1:0][1:0]         ispec_ab;
  logic [NP-1:0][1:0][TID-1:0] iptid;
  logic [NP-1:0][C.XLEN-1:0]  iopa, iopb;
  logic [NP-1:0]              iopa_v, iopb_v;
  logic [NP-1:0][C.FLen-1:0]  iopc;
  logic [NP-1:0]              iopc_v;
  logic [NWB-1:0]             wb_v = '0;
  logic [NWB-1:0][TID-1:0]    wb_id = '0;
  logic [NWB-1:0][C.XLEN-1:0] wb_data = '0;
  logic [NWB-1:0]             wb_exc = '0;
  // Drive-side WB registers. A real FU writeback is a clocked source: the
  // DUT sees the tuple registers-stable for a full cycle before the edge
  // that consumes it. Driving wb_* straight from the low phase let the
  // wb_id -> tid_prd lookup land mid-eval on this generated model.
  logic [NWB-1:0]             wb_drive_v = '0;
  logic [NWB-1:0][TID-1:0]    wb_drive_id = '0;
  logic [NWB-1:0][C.XLEN-1:0] wb_drive_data = '0;
  logic [NWB-1:0]             wb_drive_exc = '0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wb_v <= '0; wb_id <= '0; wb_data <= '0; wb_exc <= '0;
    end else begin
      wb_v    <= wb_drive_v;
      wb_id   <= wb_drive_id;
      wb_data <= wb_drive_data;
      wb_exc  <= wb_drive_exc;
    end
  end
  logic [NPC-1:0]             cwe = '0;
  logic [NPC-1:0][C.XLEN-1:0] cwdata = '0;
  logic [NPC-1:0]             cack = '0;
  sbe_t [NPC-1:0]             cinstr;
  logic [TID-1:0]             cptr = '0;
  logic                       misp = 0;
  logic [TID-1:0]             misp_id = '0;
  logic                       frel, robf, iqf, drained, lsq_stl, ren_stl;
  logic                       stl_fwd, memvio, wbstall;
  logic [TID-1:0]             memvio_id;
  logic [NSB-1:0]             ldchk;
  logic                       lsu_rep = 0;
  logic [TID-1:0]             lsu_rep_tid = '0;

  g6lc_ooo_dispatch #(
      .G6LCCfg(C), .HypCfg(H), .scoreboard_entry_t(sbe_t))
  i_dispatch (
      .clk_i(clk), .rst_ni(rst_n),
      .phys_valid_i(phys_v), .phys_addr_i(phys_addr),
      .phys_id_i(phys_id), .phys_hart_i(phys_hart),
      .phys_size_i(phys_size),
      .mod_valid_i(mod_v), .mod_addr_i(mod_addr),
      .phys_pending_o(phys_pending), .phys_replay_o(phys_replay),
      .flush_i(flush), .flush_unissued_i(flush_un),
      .cancelled_mask_i(cancel), .sb_live_i(sb_live),
      .dispatch_sbe_i(dsbe), .dispatch_orig_i(dorig),
      .dispatch_valid_i(dvalid), .dispatch_ack_o(dack),
      .issue_sbe_o(isbe), .issue_orig_o(iorig),
      .issue_valid_o(ivalid), .issue_ack_i(iack),
      .issue_spec_ab_o(ispec_ab), .issue_ptid_o(iptid),
      .lsu_ready_i(1'b1), .fpu_ready_i(1'b1),
      .csr_ready_i(1'b1), .mult_ready_i(1'b1),
      .issue_op_a_o(iopa), .issue_op_b_o(iopb),
      .issue_op_a_valid_o(iopa_v), .issue_op_b_valid_o(iopb_v),
      .issue_op_c_o(iopc), .issue_op_c_valid_o(iopc_v),
      .wb_valid_i(wb_v), .wb_id_i(wb_id),
      .wb_data_i(wb_data), .wb_exc_i(wb_exc),
      .commit_we_i(cwe), .commit_wdata_i(cwdata),
      .commit_ack_i(cack), .commit_instr_i(cinstr),
      .commit_ptr_i(cptr),
      .mispredict_i(misp), .mispredict_id_i(misp_id),
      .freelist_empty_o(frel), .rob_full_o(robf), .iq_full_o(iqf),
      .ooo_drained_o(drained), .lsq_stall_o(lsq_stl),
      .rename_stall_o(ren_stl), .stl_forward_o(stl_fwd),
      .mem_violation_o(memvio), .mem_violation_id_o(memvio_id),
      .ld_checked_o(ldchk),
      .lsu_replay_i(lsu_rep), .lsu_replay_tid_i(lsu_rep_tid),
      .hyp_wb_reserve_stall_o(wbstall));

  // ---- sb_cancel unit (section L): dead-slot resolve authority --------
  // Same packed layouts as scoreboard.sv's sb_mem_t and the core's
  // bp_resolve_t; the unit is combinational so the section drives and
  // samples without a tick.
  typedef struct packed {
    logic issued;
    logic cancelled;
    logic replay;
    logic is_rd_fpr_flag;
    sbe_t sbe;
  } sbm_t;
  typedef struct packed {
    logic                    valid;
    logic [C.VLEN-1:0]       pc;
    logic [C.VLEN-1:0]       target_address;
    logic                    is_mispredict;
    logic                    is_taken;
    cf_t                     cf_type;
    logic [HW-1:0]           hart_id;
    logic                    ckpt_restore;
    logic [TID-1:0]          trans_id;
    logic                    ckpt_v;
    logic [7:0]              ckpt_idx;
    logic                    is_call;
    logic [C.VLEN-1:0]       next_pc;
  } bpr_t;

  sbm_t [NSB-1:0]  cnc_mem;
  bpr_t            cnc_res;
  logic [TID-1:0]  cnc_iptr = '0;
  logic            cnc_bmiss, cnc_spec;
  logic [NSB-1:0]  cnc_mask, cnc_kill;

  sb_cancel #(
      .G6LCCfg(C), .bp_resolve_t(bpr_t), .sb_mem_t(sbm_t))
  i_cnc (
      .resolved_branch_i (cnc_res),
      .mem_q_i           (cnc_mem),
      .issue_pointer_i   (cnc_iptr),
      .bmiss_o           (cnc_bmiss),
      .spec_cancel_o     (cnc_spec),
      .cancelled_mask_o  (cnc_mask),
      .kill_req_o        (cnc_kill));

  // ------------------------- observability -------------------------
  int                issue_cnt  [NSB];
  logic [C.XLEN-1:0] opa_last  [NSB];
  logic              opa_v_last[NSB];
  logic [C.XLEN-1:0] opb_last  [NSB];
  logic              opb_v_last[NSB];
  logic [NP-1:0]     dack_seen = '0;
  int                vio_cnt = 0;
  logic [TID-1:0]    vio_id_last = '0;

  // Acceptances are combinational and consumed at the posedge; sample
  // them just before the edge while the offers still stand.
  task automatic tick;
    #1;
    if (trace_en) begin
      $display("HYP8_DISPATCH_BOUNDARY cyc=%0d dvalid=%02b dack=%02b can_go=%0b ren_stall=%0b rob_full=%0b iq_full=%0b lsq_disp_block=%0b lsq_grp_block=%0b grp_pend=%0b ren_capture=%0b ren_pub=%0b grp_v_q=%02b grp_go=%0b iqdisp_ack=%02b grp_done=%0b ld_free=%0d st_free=%0d ld_full=%0b st_full=%0b is_ld=%02b is_st=%02b ld_alloc=%02b st_alloc=%02b ldv=%08b stv=%08b grp_sbe0_tid=%0d grp_prs1_0=%0d grp_prs2_0=%0d grp_rs1_ready_0=%0b grp_rs2_ready_0=%0b grp_rs3_ready_0=%0b tid_prd_1=%0d ren_int_busy_prd1=%0b wb_v=%04b data_wb_valid=%b data_wb_prd_0=%0d ivalid=%02b iack=%02b",
        cycles, dvalid, dack,
        i_dispatch.can_go, i_dispatch.ren_stall,
        i_dispatch.rob_full, i_dispatch.iq_full,
        i_dispatch.lsq_disp_block, i_dispatch.lsq_grp_block,
        i_dispatch.grp_pend_q,
        i_dispatch.ren_capture, i_dispatch.ren_pub, i_dispatch.grp_v_q,
        i_dispatch.grp_go, i_dispatch.iqdisp_ack, i_dispatch.grp_done,
        i_dispatch.ld_free, i_dispatch.st_free,
        i_dispatch.ld_full, i_dispatch.st_full,
        i_dispatch.is_ld, i_dispatch.is_st,
        i_dispatch.ld_alloc, i_dispatch.st_alloc,
        ~i_dispatch.i_lsq.i_slot.ld_inv, ~i_dispatch.i_lsq.i_slot.st_inv,
        i_dispatch.ren_capture, i_dispatch.ren_pub, i_dispatch.grp_v_q,
        i_dispatch.grp_go, i_dispatch.iqdisp_ack, i_dispatch.grp_done,
        i_dispatch.grp_sbe_q[0].trans_id,
        i_dispatch.grp_prs1_q[0], i_dispatch.grp_prs2_q[0],
        i_dispatch.grp_rs1_ready[0], i_dispatch.grp_rs2_ready[0],
        i_dispatch.grp_rs3_ready[0],
        i_dispatch.tid_prd_q[1],
        i_dispatch.ren_int_busy[i_dispatch.tid_prd_q[1]],
        wb_v, i_dispatch.data_wb_valid, i_dispatch.data_wb_prd[0],
        ivalid, iack);
    end
    if (memvio) begin
      vio_cnt++;
      vio_id_last = memvio_id;
    end
    for (int p = 0; p < NP; p++) begin
      if (ivalid[p] && iack[p]) begin
        issue_cnt[isbe[p].trans_id]++;
        opa_last[isbe[p].trans_id]   = iopa[p];
        opa_v_last[isbe[p].trans_id] = iopa_v[p];
        opb_last[isbe[p].trans_id]   = iopb[p];
        opb_v_last[isbe[p].trans_id] = iopb_v[p];
      end
      if (dack[p]) begin
        dack_seen[p] = 1'b1;
        // sb_live models entries once the IQ actually owns them.
        sb_live[i_dispatch.grp_sbe_q[p].trans_id] = 1'b1;
      end
    end
    clk = 1; #2; clk = 0; #2;
    cycles++;
    if (cycles > 2000) $fatal(1, "tb_g6lc_hyp8_dispatch watchdog");
  endtask

  task automatic check(input bit ok, input string tag);
    if (!ok) $fatal(1, "%s", tag);
    checked++;
  endtask

  task automatic reset_all;
    rst_n = 0; dvalid = '0; dack_seen = '0; iack = '1;
    wb_drive_v = '0; wb_drive_id = '0;
    wb_drive_data = '0; wb_drive_exc = '0;
    cwe = '0; cack = '0; misp = 0;
    flush = 0; flush_un = 0; cancel = '0; sb_live = '0;
    dsbe = '{default:'0}; cinstr = '{default:'0};
    for (int i = 0; i < NSB; i++) begin
      issue_cnt[i] = 0;
      opa_v_last[i] = 0; opa_last[i] = '0;
      opb_v_last[i] = 0; opb_last[i] = '0;
    end
    repeat (4) tick();
    rst_n = 1;
    repeat (2) tick();
  endtask

  // A single-lane group: drive lane 0, hold the offer until the group is
  // acknowledged (IQ allocation), then retire it.
  task automatic drive0(input sbe_t e, input logic [31:0] orig,
                        input string tag = "");
    dack_seen = '0;
    dsbe[0] = e; dorig[0] = orig; dvalid[0] = 1'b1;
    for (int c = 0; c < 40; c++) begin
      tick();
      if (dack_seen[0]) begin dvalid = '0; return; end
    end
    $fatal(1, "DISP_GROUP_NEVER_ACKED %s", tag);
  endtask

  // Both lanes of one group.
  task automatic drive2(input sbe_t e0, input sbe_t e1);
    dack_seen = '0;
    dsbe[0] = e0; dsbe[1] = e1; dorig[0] = 0; dorig[1] = 1;
    dvalid = '1;
    for (int c = 0; c < 40; c++) begin
      tick();
      if (&dack_seen) begin dvalid = '0; return; end
    end
    $fatal(1, "DISP_GROUP2_NEVER_ACKED");
  endtask

  // A lane-1-only group: lane 0 invalid, so the IQ steers lane 1 to the
  // first bank at or after steer+1 with a free entry.
  task automatic drive1(input sbe_t e, input logic [31:0] orig);
    dack_seen = '0;
    dsbe[1] = e; dorig[1] = orig; dvalid = 2'b10;
    for (int c = 0; c < 40; c++) begin
      #1;
      $display("D1 cyc=%0d grpv=%b go=%b iqdack=%b asgn=%0d,%0d dack=%b cap=%b pub=%b",
        cycles, i_dispatch.grp_v_q, i_dispatch.grp_go,
        i_dispatch.iqdisp_ack, i_dispatch.i_iq.asgn[0],
        i_dispatch.i_iq.asgn[1], dack, i_dispatch.ren_capture,
        i_dispatch.ren_pub);
      for (int p = 0; p < NP; p++)
        if (dack[p]) begin
          dack_seen[p] = 1'b1;
          sb_live[i_dispatch.grp_sbe_q[p].trans_id] = 1'b1;
        end
      clk = 1; #2; clk = 0; #2; cycles++;
      if (dack_seen[1]) begin dvalid = '0; return; end
    end
    $fatal(1, "DISP_LANE1_NEVER_ACKED");
  endtask

  // Live IQ entries from the banks' own free counters (they count
  // e_live | pend_busy, i.e. every committed allocation).
  function automatic int iq_occ();
    int n = 0;
    for (int b = 0; b < 8; b++)
      n += 4 - int'(i_dispatch.i_iq.bank_free[b]);
    return n;
  endfunction

  // drive2 with an all-or-nothing observer on iqdisp_ack: a strict
  // non-empty subset ack of the live group is the hyp8-osbi-scalar-r7
  // signature (bank phantom pick starved a lone requester at one free
  // entry), which then replayed the acked lane with a stale tid.
  task automatic drive2_watch(input sbe_t e0, input sbe_t e1);
    bit partial = 0;
    int occ0;
    occ0 = iq_occ();
    dack_seen = '0;
    dsbe[0] = e0; dsbe[1] = e1; dorig[0] = 0; dorig[1] = 1;
    dvalid = '1;
    for (int c = 0; c < 40; c++) begin
      #1;
      if ((i_dispatch.iqdisp_ack & i_dispatch.grp_v_q) != '0 &&
          (i_dispatch.iqdisp_ack & i_dispatch.grp_v_q) != i_dispatch.grp_v_q)
        partial = 1;
      for (int p = 0; p < NP; p++)
        if (dack[p]) begin
          dack_seen[p] = 1'b1;
          sb_live[i_dispatch.grp_sbe_q[p].trans_id] = 1'b1;
        end
      clk = 1; #2; clk = 0; #2; cycles++;
      if (&dack_seen) break;
    end
    check(!partial, "J_IQDACK_PARTIAL");
    check(&dack_seen, "J_GROUP_NEVER_ACKED");
    dvalid = '0;
    repeat (2) tick();
    check(iq_occ() - occ0 == 2, "J_ALLOC_COUNT");
  endtask

  task automatic wait_issue(input int tid, input int maxc, input string tag);
    for (int c = 0; c < maxc; c++) begin
      if (issue_cnt[tid] >= 1) return;
      tick();
    end
    $fatal(1, "%s", tag);
  endtask

  function automatic sbe_t alu_sbe(input int tid, input int rd,
                                   input int rs1, input int rs2);
    sbe_t e;
    e = '0; e.valid = 1; e.trans_id = TID'(tid);
    e.fu = ALU; e.op = ADD;
    e.rd = 5'(rd); e.rs1 = 5'(rs1); e.rs2 = 5'(rs2);
    return e;
  endfunction

  // FADD classifies its FP sources on rs2 and the result[4:0] ("rs3")
  // slot; rs1 remains an integer operand.
  function automatic sbe_t fadd_sbe(input int tid, input int rd,
                                    input int rs1, input int rs2,
                                    input int rs3);
    sbe_t e;
    e = '0; e.valid = 1; e.trans_id = TID'(tid);
    e.fu = FPU; e.op = FADD;
    e.rd = 5'(rd); e.rs1 = 5'(rs1); e.rs2 = 5'(rs2);
    e.result[4:0] = 5'(rs3);
    return e;
  endfunction

  function automatic sbe_t branch_sbe(input int tid);
    sbe_t e;
    e = '0; e.valid = 1; e.trans_id = TID'(tid);
    e.fu = CTRL_FLOW; e.op = EQ;
    e.rd = 5'd0; e.rs1 = 5'd5; e.rs2 = 5'd5;
    return e;
  endfunction

  // Store/load SBEs for the LSQ violation scenarios. The issue-side
  // AGU is vaddr = result + op_a: give op_a a producer of known value
  // (wb_once data 0) or a zero-reading source so both events land on
  // `imm`; `result` is the immediate in a real SBE.
  function automatic sbe_t store_sbe(input int tid,
                                    input logic [C.XLEN-1:0] imm,
                                    input int rs1 = 0, input int rs2 = 0);
    sbe_t e;
    e = '0; e.valid = 1; e.trans_id = TID'(tid);
    e.fu = STORE; e.op = SD;
    e.rd = 5'd0; e.rs1 = 5'(rs1); e.rs2 = 5'(rs2);
    e.result = imm;
    return e;
  endfunction

  function automatic sbe_t load_sbe(input int tid, input int rd,
                                    input logic [C.XLEN-1:0] imm);
    sbe_t e;
    e = '0; e.valid = 1; e.trans_id = TID'(tid);
    e.fu = LOAD; e.op = LD;
    e.rd = 5'(rd); e.rs1 = 5'd0; e.rs2 = 5'd0;
    e.result = imm;
    return e;
  endfunction

  // One WB beat on port 0 through the clocked adapter: the tuple launches
  // on the first tick and is consumed at the DUT on the second, with
  // ID/data registers-stable for the whole intervening cycle.
  task automatic wb_once(input int tid, input logic [C.XLEN-1:0] data);
    wb_drive_v[0] = 1'b1; wb_drive_id[0] = TID'(tid);
    wb_drive_data[0] = data;
    tick();
    wb_drive_v = '0;
    tick();
  endtask

  // Opt-in structural trace (+dispatch_trace): a boundary record per tick
  // while cycles < 80 (inside tick, at the same pre-edge sample point),
  // and a per-entry record whenever an IQ slot carrying TID 2 is visible
  // on the falling edge. Diagnostic only; no assertion or stimulus reads
  // it, and the generate indices are compile-time constants.
  bit trace_en = 0;
  initial trace_en = $test$plusargs("dispatch_trace");

  for (genvar b = 0; b < H.IqBanks; b++) begin : gen_tr_bank
    for (genvar e = 0; e < H.IqBankEntries; e++) begin : gen_tr_ent
      always @(negedge clk) begin
        if (trace_en &&
            i_dispatch.i_iq.gen_bank[b].i_bank.e_q[e].valid &&
            i_dispatch.i_iq.gen_bank[b].i_bank.e_q[e].tid == TID'(2)) begin
          $display("HYP8_DISPATCH_ENTRY cyc=%0d b=%0d e=%0d tid=%0d issued=%0b rs1_rdy=%0b rs2_rdy=%0b rs3_rdy=%0b prs1=%0d prs2=%0d legal=%0b cand_v=%02b cand_i=%b take_v=%02b aack=%02b",
            cycles, b, e,
            i_dispatch.i_iq.gen_bank[b].i_bank.e_q[e].tid,
            i_dispatch.i_iq.gen_bank[b].i_bank.e_q[e].issued,
            i_dispatch.i_iq.gen_bank[b].i_bank.e_q[e].rs1_rdy,
            i_dispatch.i_iq.gen_bank[b].i_bank.e_q[e].rs2_rdy,
            i_dispatch.i_iq.gen_bank[b].i_bank.e_q[e].rs3_rdy,
            i_dispatch.i_iq.gen_bank[b].i_bank.e_q[e].prs1,
            i_dispatch.i_iq.gen_bank[b].i_bank.e_q[e].prs2,
            i_dispatch.i_iq.legal[b][e],
            i_dispatch.i_iq.gen_bank[b].i_bank.cand_v_o,
            i_dispatch.i_iq.gen_bank[b].i_bank.cand_i_o,
            i_dispatch.i_iq.take_v[b],
            i_dispatch.i_iq.aack[b]);
        end
      end
    end
  end

  // ------------------------------------------------------------------
  initial begin
    // ---------------- A: lost wakeup during rename (integer) ---------
    reset_all();
    // Producer ALU rd=1/TID1 issues first; no WB yet.
    drive0(alu_sbe(1, 1, 5, 6), 32'hAAAA_0001);
    wait_issue(1, 30, "A_PRODUCER_NO_ISSUE");
    // Consumer rd=2/rs1=1/TID2: the capture edge lands, then ONE
    // WB(TID1) during its rename, removed before IQ allocation.
    dsbe[0] = alu_sbe(2, 2, 1, 6); dorig[0] = 32'hAAAA_0002;
    dvalid[0] = 1'b1; dack_seen = '0;
    #1;
    check(i_dispatch.ren_capture, "A_CONSUMER_NO_CAPTURE");
    tick();                                  // R1 captured this edge
    wb_once(1, 64'h12345678);                // during rename stages
    // The WB tuple was consumed at the second adapter tick, well before
    // this group can be acknowledged — the live busy read at allocation
    // is what must reflect it.
    check(!dack_seen[0], "A_WB_NOT_BEFORE_DACK");
    for (int c = 0; c < 40 && !dack_seen[0]; c++) tick();
    check(dack_seen[0], "A_CONSUMER_NO_ALLOC");
    dvalid = '0;
    wait_issue(2, 30, "A_CONSUMER_LOST_WAKEUP");
    repeat (4) tick();
    check(issue_cnt[2] == 1, "A_CONSUMER_MULTI_ISSUE");
    check(opa_v_last[2], "A_OPA_INVALID");
    check(opa_last[2] == 64'h12345678, "A_OPA_VALUE");

    // ---------------- B: same seam through the FP PRF ----------------
    reset_all();
    // Producer FADD f1 (rd=1): FP dest, sources f3/f4 via rs2/rs3.
    drive0(fadd_sbe(1, 1, 5, 3, 4), 32'hBBBB_0001);
    wait_issue(1, 30, "B_PRODUCER_NO_ISSUE");
    // Consumer FADD f2 = f1 + f4: the FP dependence rides rs2=1; rs1=1
    // exercises the integer boundary (independent, already ready).
    dsbe[0] = fadd_sbe(2, 2, 1, 1, 4); dorig[0] = 32'hBBBB_0002;
    dvalid[0] = 1'b1; dack_seen = '0;
    #1;
    check(i_dispatch.ren_capture, "B_CONSUMER_NO_CAPTURE");
    tick();
    wb_once(1, 64'h4008000000000000);
    check(!dack_seen[0], "B_WB_NOT_BEFORE_DACK");
    for (int c = 0; c < 40 && !dack_seen[0]; c++) tick();
    check(dack_seen[0], "B_CONSUMER_NO_ALLOC");
    dvalid = '0;
    wait_issue(2, 30, "B_CONSUMER_LOST_WAKEUP");
    check(opb_v_last[2], "B_OPB_INVALID");
    check(opb_last[2] == 64'h4008000000000000, "B_OPB_VALUE");

    // ---------------- C: intra-group RAW stays busy ------------------
    reset_all();
    // lane0 producer rd=3/TID3, lane1 consumer rs1=3/rd=4/TID4.
    drive2(alu_sbe(3, 3, 5, 6), alu_sbe(4, 4, 3, 6));
    wait_issue(3, 30, "C_PRODUCER_NO_ISSUE");
    // 3 cycles, no WB: the fresh physical destination must stay busy.
    for (int c = 0; c < 3; c++) tick();
    check(issue_cnt[4] == 0, "C_CONSUMER_ISSUED_PRE_WB");
    wb_once(3, 64'hBEEF);
    wait_issue(4, 30, "C_CONSUMER_NO_ISSUE");
    check(opa_v_last[4], "C_OPA_INVALID");
    check(opa_last[4] == 64'hBEEF, "C_OPA_VALUE");

    // ---------------- D: checkpoint retires between select/repair ----
    reset_all();
    drive0(branch_sbe(1), 32'hDDDD_0001);
    wait_issue(1, 30, "D_BRANCH_NO_ISSUE");
    // Prepare the WB in the adapter one tick earlier (cack/misp still 0);
    // the next tick consumes the stable WB and the commit/mispredict
    // fields in the same cycle.
    wb_drive_v[0] = 1'b1; wb_drive_id[0] = TID'(1); wb_drive_data[0] = '0;
    tick();                       // launch: wb_v takes the tuple at the edge
    wb_drive_v = '0;
    cack[0] = 1'b1; cinstr[0] = branch_sbe(1); cwe[0] = 1'b0;
    misp = 1'b1; misp_id = TID'(1);
    tick();                       // stable WB + commit/mispredict together
    cack = '0; cinstr = '{default:'0}; misp = 0;
    // Select registers this edge, repair runs next cycle -- the retire
    // in between must leave a legal count (0), never an underflowed
    // ring, and the freed capacity must accept another branch.
    for (int c = 0; c < 6; c++) tick();
    check(i_dispatch.i_rename.u_recover.ckpt_cnt_q[0] == '0,
          "D_CKPT_CNT_NONZERO");
    check(&i_dispatch.i_rename.u_recover.ckpt_cnt_q[0] != 1'b1,
          "D_CKPT_CNT_ALL_ONES");
    drive0(branch_sbe(5), 32'hDDDD_0005);
    wait_issue(5, 30, "D_BRANCH2_NO_ISSUE");

    // ------------- E: unres-tracked store still flags the load --------
    // h33-r5 regression shape: an older unresolved store in the load's
    // alloc-time tracking set; the load's own AGU event runs while the
    // store is still unresolved (the load waits on ordering, tracked);
    // when the store's AGU event later resolves it, the violation path
    // MUST name the waiting load — its LSU forward probe raced the
    // store's resolution and its captured data may be stale (the r5
    // distance-0 sd->ld committed 0 when this was suppressed).  Only
    // the dwait relationship (verdict saw the store's resolved
    // address) may suppress — the unres relationship may not.
    // The store is held issue-unready on a producer operand so the
    // arbitration order cannot let it stage ahead of the load.
    reset_all();
    vio_cnt = 0; vio_id_last = '0;
    drive0(alu_sbe(19, 5, 6, 7), 32'hE000_0019, "E_PROD");
    wait_issue(19, 30, "E_PRODUCER_NO_ISSUE");
    drive0(store_sbe(20, 64'h3000, 5), 32'hE000_0020, "E_STORE"); // rs1=5: unready
    drive0(load_sbe(21, 9, 64'h3000), 32'hE000_0021, "E_LOAD");   // rs1=0: ready
    // Only the load can present — the store waits on its operand.
    wait_issue(21, 40, "E_LOAD_NO_ISSUE");
    // The load evented while the store was unresolved; no violation may
    // fire from the load's own verdict pipeline.
    repeat (8) tick();
    check(vio_cnt == 0, "E_EARLY_VIOLATION");
    // Release the store's operand (op_a=0 -> its AGU lands on 0x3000):
    // the store's first address-resolution must flag the tracked load.
    wb_once(19, 64'h0);
    wait_issue(20, 40, "E_STORE_NO_ISSUE");
    begin
      bit e_vio = 1'b0;
      for (int c = 0; c < 16 && !e_vio; c++) begin
        tick();
        e_vio = (vio_cnt == 1);
      end
      check(e_vio, "E_UNRES_VIOLATION_MISSING");
    end
    check(vio_id_last == TID'(21), "E_VIOLATION_ID");

    // ------------- F: untracked older store still flags -------------
    // Positive control (same shape as the memory leaf's same-hart
    // check): the store's LSQ entry is allocated AFTER the load's, so
    // it was never in the load's tracked set — its address resolution
    // must still flag a memory-order violation naming the load.
    reset_all();
    vio_cnt = 0; vio_id_last = '0;
    drive0(load_sbe(31, 10, 64'h5000), 32'hF000_0031, "F_LOAD");
    iack = '1;
    wait_issue(31, 40, "F_LOAD_NO_ISSUE");
    iack = '0;
    repeat (4) tick();
    drive0(store_sbe(30, 64'h5000), 32'hF000_0030, "F_STORE");
    iack = '1;
    wait_issue(30, 40, "F_STORE_NO_ISSUE");
    iack = '0;
    begin
      bit f_vio = 1'b0;
      for (int c = 0; c < 16 && !f_vio; c++) begin
        tick();
        f_vio = (vio_cnt == 1);
      end
      check(f_vio, "F_VIOLATION_MISSING");
    end
    check(vio_id_last == TID'(31), "F_VIOLATION_ID");

    // ------------- G: publish edge coincident with flush_unissued ------
    // hyp8-osbi-scalar-r2 mechanism: the rename publish lands on the SAME
    // edge as flush_unissued_i while dispatch_valid_i still presents the
    // pre-flush lanes (the scoreboard retracts at that edge, not before),
    // so the zombie mask cannot help — the kill must dominate the grp_v_q
    // capture. With the lanes never entering grp_v_q there is no
    // dispatch_ack_o on the following cycles, no IQ allocation, and no
    // issue accept on slots the scoreboard does not present.
    reset_all();
    dsbe[0] = alu_sbe(6, 8, 5, 6); dsbe[1] = alu_sbe(7, 9, 5, 6);
    dorig[0] = 32'h6000_0006; dorig[1] = 32'h6000_0007;
    dvalid = '1; dack_seen = '0;
    begin
      bit g_pub = 1'b0;
      for (int c = 0; c < 40 && !g_pub; c++) begin
        #1;
        if (i_dispatch.ren_pub) begin
          g_pub    = 1'b1;
          flush_un = 1'b1;      // kill lands at the same posedge as publish
        end
        clk = 1; #2; clk = 0; #2; cycles++;
      end
      check(g_pub, "G_PUBLISH_NEVER");
    end
    flush_un = 1'b0;
    dvalid = '0;                // scoreboard retraction of the dead lanes
    check(i_dispatch.grp_v_q == '0, "G_ZOMBIE_CAPTURED");
    dack_seen = '0;
    repeat (8) tick();
    check(dack_seen == '0, "G_DEAD_LANE_ACKED");
    check(i_dispatch.grp_v_q == '0, "G_GRP_V_REVIVED");
    check(issue_cnt[6] == 0 && issue_cnt[7] == 0, "G_ZOMBIE_ISSUED");
    // Positive: a fresh group published after the kill acks and issues
    // normally — the kill did not wedge the dispatch pipe.
    drive2(alu_sbe(8, 10, 5, 6), alu_sbe(9, 11, 5, 6));
    wait_issue(8, 30, "G_FRESH_NO_ISSUE");

    // ------------- G2: same coincidence with mispredict ----------------
    // Same kill-dominates-publish contract through the mispredict leg; a
    // live checkpoint is required so the repair has a select target.
    reset_all();
    drive0(branch_sbe(10), 32'h6200_0010, "G2_BRANCH");
    wait_issue(10, 30, "G2_BRANCH_NO_ISSUE");
    dsbe[0] = alu_sbe(11, 8, 5, 6); dsbe[1] = alu_sbe(12, 9, 5, 6);
    dorig[0] = 32'h6200_0011; dorig[1] = 32'h6200_0012;
    dvalid = '1; dack_seen = '0;
    begin
      bit g2_pub = 1'b0;
      for (int c = 0; c < 40 && !g2_pub; c++) begin
        #1;
        if (i_dispatch.ren_pub) begin
          g2_pub  = 1'b1;
          misp    = 1'b1; misp_id = TID'(10);
        end
        clk = 1; #2; clk = 0; #2; cycles++;
      end
      check(g2_pub, "G2_PUBLISH_NEVER");
    end
    misp = 1'b0;
    dvalid = '0;
    check(i_dispatch.grp_v_q == '0, "G2_ZOMBIE_CAPTURED");
    dack_seen = '0;
    repeat (8) tick();
    check(dack_seen == '0, "G2_DEAD_LANE_ACKED");
    check(issue_cnt[11] == 0 && issue_cnt[12] == 0, "G2_ZOMBIE_ISSUED");
    drive2(alu_sbe(13, 10, 5, 6), alu_sbe(14, 11, 5, 6));
    wait_issue(13, 30, "G2_FRESH_NO_ISSUE");

    // ------------- H: flush_unissued mid-pipe kills the group ----------
    // hyp8-osbi-scalar-r6 mechanism: a standalone flush_unissued_i (wfi
    // boundary -- no mispredict) cleared grp_pend_q while the rename pipe
    // survived it (kill_all covered mispredict/flush only). The reopened
    // can_go admitted a second capture during the survivor's own publish
    // cycle -- the coincident ren_pub outranked the capture's pend set --
    // so two groups rode the pipe back-to-back and the younger published
    // on the elder's drain edge. grp_v_q re-armed against the scoreboard's
    // pre-drain window, the IQ wrote a second entry with the stale tid,
    // and the next slot's ack produced the stray issue_ack (sv:283).
    // With flush_unissued_i inside the pipe's kill set the in-flight
    // group dies with its window: it must never publish, never arm
    // grp_v_q, never ack, and never issue.
    reset_all();
    dsbe[0] = alu_sbe(15, 8, 5, 6); dorig[0] = 32'h6300_0015;
    dvalid = 2'b01; dack_seen = '0;
    begin
      bit h_cap = 1'b0;
      for (int c = 0; c < 40 && !h_cap; c++) begin
        #1;
        if (i_dispatch.ren_capture) h_cap = 1'b1;
        clk = 1; #2; clk = 0; #2; cycles++;
      end
      check(h_cap, "H_NO_CAPTURE");
    end
    dvalid = '0;
    flush_un = 1'b1;              // kill lands while the group rides r1/s2
    tick();
    flush_un = 1'b0;
    check(!i_dispatch.grp_pend_q, "H_PEND_STUCK");
    begin
      bit h_pub = 1'b0;
      for (int c = 0; c < 10; c++) begin
        #1;
        if (i_dispatch.ren_pub) h_pub = 1'b1;
        clk = 1; #2; clk = 0; #2; cycles++;
      end
      check(!h_pub, "H_ORPHAN_PUBLISHED");
    end
    check(i_dispatch.grp_v_q == '0, "H_ORPHAN_ARMED");
    check(dack_seen == '0, "H_DEAD_LANE_ACKED");
    check(issue_cnt[15] == 0, "H_ZOMBIE_ISSUED");
    // Positive: the kill does not wedge the pipe — a fresh group
    // publishes, acks, and issues normally.
    drive2(alu_sbe(16, 10, 5, 6), alu_sbe(17, 11, 5, 6));
    wait_issue(16, 30, "H_FRESH_NO_ISSUE");

    // ------------- J: phantom pick -- lone requester at one free entry -
    // hyp8-osbi-scalar-r7 mechanism: the bank alloc scan's `taken` mask
    // absorbed lane 0's lowest-free pick even when alloc_i[0]==0, so a
    // bank steered ONLY lane 1 with exactly one free entry acked nothing
    // despite group_fits. The partial iqdisp_ack held grp_v_q and
    // replayed the already-acked lane with a stale grp_tid_q (the
    // witness's scoreboard.sv:283). Bank targeting: the group captured
    // into grp_v_q at the publish edge meets the IQ one cycle later,
    // when steer_q has already advanced +NP -- a publish at steer s is
    // dispatched at s+2. A lane-1-only group at publish-steer 0 lands in
    // bank 3, so three of them leave bank 3 at exactly one free entry;
    // the closing two-lane group at dispatch-steer 2 sends lane 0 to
    // bank 2 and lane 1 alone to bank 3. The ack must cover both lanes
    // in the same cycle and allocate exactly two entries.
    reset_all();
    iack = '0;                       // nothing issues: occupancy persists
    // ROB_N = NSB = 16 live entries at most: three iterations of four
    // single-lane publishes keep 12 in flight and self-align the steer
    // (four publishes wrap it), leaving bank 3 at exactly one free for
    // the closing two-lane group (dispatch-steer 2: lane0 -> bank 2,
    // lane 1 alone -> bank 3). The poison producer first renames rd=5:
    // it issues and leaves the IQ, but with iack='0 no writeback ever
    // retires its prd, so every following alloc with rs1=5 stays
    // operand-unready and persists in its bank (a ready filler would be
    // taken by the arbiter and free its slot, as tid1 showed).
    // Poison producer (bank 2): renames rd=5, issues, leaves the IQ, and
    // -- with iack='0 -- never writes back, so prd(rs5) stays busy and
    // every following alloc with rs1=5 stays operand-unready in its bank
    // (a ready filler is taken by the arbiter and frees its slot).
    // Its publish shifts the steer by one step: lane-1-only groups then
    // land on bank 5, and the closing two-lane group (dispatch-steer 4)
    // sends lane 0 to bank 4 and lane 1 alone to bank 5.
    drive0(alu_sbe(0, 5, 3, 3), 32'h6A00_FF00);
    for (int k = 0; k < 3; k++) begin
      drive1(alu_sbe(1 + 4*k, 5, 5, 6), 32'h6A00_0000 + k);    // bank 5
      drive0(alu_sbe(2 + 4*k, 5, 5, 6), 32'h6A00_0100 + k);    // bank 6
      drive0(alu_sbe(3 + 4*k, 5, 5, 6), 32'h6A00_0200 + k);    // bank 0
      drive0(alu_sbe(4 + 4*k, 5, 5, 6), 32'h6A00_0300 + k);    // bank 2
      $display("JDBG k=%0d bf=%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d steer=%0d b5v=%b%b%b%b b5tid=%0d,%0d,%0d,%0d b5iss=%b%b%b%b",
        k,
        i_dispatch.i_iq.bank_free[0], i_dispatch.i_iq.bank_free[1],
        i_dispatch.i_iq.bank_free[2], i_dispatch.i_iq.bank_free[3],
        i_dispatch.i_iq.bank_free[4], i_dispatch.i_iq.bank_free[5],
        i_dispatch.i_iq.bank_free[6], i_dispatch.i_iq.bank_free[7],
        i_dispatch.steer_q,
        i_dispatch.i_iq.gen_bank[5].i_bank.e_q[0].valid,
        i_dispatch.i_iq.gen_bank[5].i_bank.e_q[1].valid,
        i_dispatch.i_iq.gen_bank[5].i_bank.e_q[2].valid,
        i_dispatch.i_iq.gen_bank[5].i_bank.e_q[3].valid,
        i_dispatch.i_iq.gen_bank[5].i_bank.e_q[0].tid,
        i_dispatch.i_iq.gen_bank[5].i_bank.e_q[1].tid,
        i_dispatch.i_iq.gen_bank[5].i_bank.e_q[2].tid,
        i_dispatch.i_iq.gen_bank[5].i_bank.e_q[3].tid,
        i_dispatch.i_iq.gen_bank[5].i_bank.e_q[0].issued,
        i_dispatch.i_iq.gen_bank[5].i_bank.e_q[1].issued,
        i_dispatch.i_iq.gen_bank[5].i_bank.e_q[2].issued,
        i_dispatch.i_iq.gen_bank[5].i_bank.e_q[3].issued);
    end
    check(i_dispatch.i_iq.bank_free[5] == 1, "J_FILL_B5");
    drive2_watch(alu_sbe(13, 0, 5, 6), alu_sbe(14, 0, 5, 6));
    iack = '1;

    // ------------- K: void mispredict on an empty ckpt ring ------------
    // hyp8-osbi-scalar-r9 mechanism: a branch resolve can still pulse
    // mispredict_i after an earlier unwind already emptied the hart's
    // checkpoint ring (stale in-flight resolve of a squashed branch;
    // tid_ckpt_q keeps its dead slot number until reused). The select
    // is then void -- cnt_m==0 makes sel_take=0 and the level
    // don't-care. The arithmetic reference underflows there
    // (rel = cnt-1 on an unsigned) so the equivalence assert is gated
    // on ref_take; functionally no repair may arm and the ring must
    // stay legal.
    reset_all();
    drive0(branch_sbe(1), 32'h4B00_0001);
    wait_issue(1, 30, "K_BR1_NO_ISSUE");
    drive0(branch_sbe(2), 32'h4B00_0002);
    wait_issue(2, 30, "K_BR2_NO_ISSUE");
    check(int'(i_dispatch.i_rename.u_recover.ckpt_cnt_q[0]) == 2,
          "K_TWO_CKPTS");
    // Mispredict the older branch: repair unwinds to its slot at ring
    // position 0 -> live count 0 and branch 2's ckpt popped.
    misp = 1'b1; misp_id = TID'(1);
    tick(); misp = 0;
    repeat (4) tick();
    check(i_dispatch.i_rename.u_recover.ckpt_cnt_q[0] == '0,
          "K_RING_NOT_EMPTY");
    // The squashed branch's stale resolve arrives late: dead-slot level
    // on an empty ring. Void select -- no repair armed, count unmoved.
    misp = 1'b1; misp_id = TID'(2);
    tick();
    misp = 0;
    check(i_dispatch.i_rename.u_recover.rec_v_q == 1'b0, "K_VOID_REPAIR");
    tick();
    check(i_dispatch.i_rename.u_recover.ckpt_cnt_q[0] == '0,
          "K_VOID_CNT");
    // Positive control: the next real branch still publishes/selects
    // normally after the void event.
    drive0(branch_sbe(3), 32'h4B00_0003);
    wait_issue(3, 30, "K_BR3_NO_ISSUE");
    check(int'(i_dispatch.i_rename.u_recover.ckpt_cnt_q[0]) == 1,
          "K_POST_CKPT");

    // ------------- L: dead-slot resolve authority (sb_cancel) ---------
    // hyp8-osbi-scalar-r10 mechanism: a squashed branch's registered B2
    // record can publish a mispredict AFTER its scoreboard slot already
    // retired-as-drop and freed -- commit-ack clears .cancelled together
    // with .issued, so the stale record read "not cancelled" on a dead
    // TID, passed the ex_stage cancelled-mask gate, and won the frontend
    // redirect with a dead-context target (c=967110, slot 7 freed at
    // 967109, resolve->0x80000766 at 967110). The mask itself stays
    // cancellation-only: LSU/STQ records keep tracking a tid AFTER its
    // slot commits (undrained store data), so a dead slot must NOT read
    // "cancelled" there (h33-r21 evidence: post-commit STQ entry died to
    // a ~issued mask term). Resolve authority is qualified by liveness
    // instead: bmiss_o requires .issued here, and ex_stage gates
    // br_lane_v on sb_live_i -- no dead record publishes.
    reset_all();
    cnc_mem  = '{default:'0};
    cnc_res  = '0;
    cnc_iptr = TID'(10);
    // tids 0..9 allocated
    for (int t = 0; t < 10; t++) cnc_mem[t].issued = 1'b1;
    #1;
    check(!cnc_mask[0] && !cnc_mask[9], "L_LIVE_UNMASKED");
    check(!cnc_mask[10] && !cnc_mask[NSB-1], "L_FREE_UNMASKED");
    // Live branch at tid 4 resolves mispredict: window [5,10) kills.
    cnc_res.valid         = 1'b1;
    cnc_res.is_mispredict = 1'b1;
    cnc_res.is_taken      = 1'b1;
    cnc_res.cf_type       = g6lc_core_pkg::Branch;
    cnc_res.trans_id      = TID'(4);
    cnc_res.pc            = 64'h8000_072C;
    cnc_res.target_address= 64'h8000_099C;
    #1;
    check(cnc_bmiss, "L_LIVE_BMISS");
    check(cnc_kill[5] && cnc_kill[9] && !cnc_kill[4] && !cnc_kill[10],
          "L_LIVE_WINDOW");
    check(cnc_mask[5] && cnc_mask[9] && !cnc_mask[4], "L_WINDOW_MASK");
    // Squash lands: tid 7 is sticky-cancelled (retires as drop).
    cnc_res = '0;
    cnc_mem[7].cancelled = 1'b1;
    #1;
    check(cnc_mask[7], "L_CANCEL_MASKED");
    // Commit-ack retires the drop: .issued clears WITH .cancelled. The
    // mask releases the slot too -- post-commit bookkeeping may still
    // carry its tid and must not read "cancelled".
    cnc_mem[7].issued    = 1'b0;
    cnc_mem[7].cancelled = 1'b0;
    #1;
    check(!cnc_mask[7], "L_FREED_UNMASKED");
    // The stale B2 record lands: dead-context mispredict to 0x80000766.
    // Its cancel window and sticky-kill are suppressed by .issued=0 --
    // the redirect publication is suppressed downstream in ex_stage by
    // the sb_live_i term on br_lane_v.
    cnc_res.valid          = 1'b1;
    cnc_res.is_mispredict  = 1'b1;
    cnc_res.is_taken       = 1'b1;
    cnc_res.cf_type        = g6lc_core_pkg::Branch;
    cnc_res.trans_id       = TID'(7);
    cnc_res.pc             = 64'h8000_0736;
    cnc_res.target_address = 64'h8000_0766;
    #1;
    check(!cnc_bmiss, "L_STALE_BMISS");
    check(cnc_kill == '0, "L_STALE_KILL");
    // Positive control: a live resolve still opens the window after the
    // stale record; the freed slot's position in the window still reads
    // killed (harmless -- nothing owns it -- but it must not block the
    // window itself).
    cnc_res.trans_id       = TID'(4);
    cnc_res.target_address = 64'h8000_099C;
    #1;
    check(cnc_bmiss, "L_POST_BMISS");
    check(cnc_kill[5] && cnc_kill[6] && cnc_kill[7] && cnc_kill[8] &&
          cnc_kill[9], "L_POST_WINDOW");
    check(cnc_mask[7], "L_POST_SLOT_WINDOW");

    $display("HYP8_DISPATCH_PASS checked=%0d", checked);
    $finish;
  end
endmodule

// ----------------------------------------------------------------------
// tb_g6lc_hyp8_realign -- the actual instr_realign carry bank on the
// two-hart RVC/64b hyp8 geometry. Directed stream:
//   A   three C.NOPs then a split RVI lower -> tail carry at 1006.
//   B   completes the tail AND leaves its own tail in one window -- the
//       completion+new-tail transaction the old pending record tore.
//   C   completes B's tail and leaves none -> carry drops.
//   D   a hart-1 window writes its own tail at the same edge a restore
//       re-installs hart 0's consumed prefix (write coexistence).
//   B2  B replayed under a fresh response epoch: the restored prefix
//       must complete identically (carry PC AND successor restored).
//   K/S a killed window and a stale-epoch window are inert on the bank.
//   F   a normal window with no carry interaction drops the carry.
//   G   redirect re-keying: a carry record written under epoch 3 survives
//       the bpf-kill but cannot stitch into the post-redirect (epoch 4)
//       stream — not even when the replayed window is the address
//       successor; non-successor new-epoch windows decode at their start.
//   H   same-epoch successor still stitches (positive control).
// Inputs are driven on the clock-low phase, outputs sampled after the
// edge; all expected values are literal, not derived from the DUT's
// prefix math.
module tb_g6lc_hyp8_realign;
  import g6lc_core_pkg::*;
  `include "g6lc_core_types.svh"

  // The built g6lc64_hyp8 geometry (RVC + two issue ports derives
  // FETCH_WIDTH=64 / INSTR_PER_FETCH=4, VLEN=XLEN=64) with a second
  // hart so the per-hart carry bank is exercised.
  function automatic config_pkg::g6lc_cfg_t configuration();
    config_pkg::g6lc_cfg_t c =
        build_config_pkg::build_config(g6lc_config_pkg::g6lc_cfg);
    c.NrHarts = 2;
    return c;
  endfunction
  localparam config_pkg::g6lc_cfg_t C = configuration();
  localparam g6lc_hyp_pkg::g6lc_hyp_cfg_t H = g6lc_hyp_pkg::Hyp8;

  localparam int NI = C.INSTR_PER_FETCH;
  localparam int EW = (H.FeEpochBits > 0) ? H.FeEpochBits : 1;
  localparam int HW = (C.NrHarts > 1) ? $clog2(C.NrHarts) : 1;

  logic clk = 0, rst_n = 0;
  int checked = 0;

  logic                     flush, kill, win_valid;
  logic [HW-1:0]            hart;
  logic [EW-1:0]            epoch, rsp_epoch;
  logic [C.VLEN-1:0]        win_addr;
  logic [C.FETCH_WIDTH-1:0] win_data;
  logic                     restore;
  logic [HW-1:0]            restore_hart;
  logic [C.VLEN-1:0]        restore_pc;
  logic [15:0]              restore_instr;
  logic [63:0]              restore_next;
  logic [EW-1:0]            restore_epoch;

  logic                     serving_unaligned, leftover_pending;
  logic                     leftover_valid, carry_done;
  logic [C.VLEN-1:0]        leftover_pc;
  logic                     bank_valid;
  logic [C.VLEN-1:0]        bank_pc;
  logic [NI-1:0]            out_valid;
  logic [NI-1:0][C.VLEN-1:0] out_addr, out_base, out_off;
  logic [NI-1:0][31:0]      out_instr;

  instr_realign #(
      .G6LCCfg(C),
      .HypCfg  (H)
  ) i_rl (
      .clk_i               (clk),
      .rst_ni              (rst_n),
      .flush_i             (flush),
      .kill_i              (kill),
      .hart_i              (hart),
      .epoch_i             (epoch),
      .rsp_epoch_i         (rsp_epoch),
      .valid_i             (win_valid),
      .serving_unaligned_o (serving_unaligned),
      .leftover_pending_o  (leftover_pending),
      .leftover_valid_o    (leftover_valid),
      .leftover_pc_o       (leftover_pc),
      .bank_valid_o        (bank_valid),
      .bank_pc_o           (bank_pc),
      .carry_done_o        (carry_done),
      .restore_i           (restore),
      .restore_hart_i      (restore_hart),
      .restore_pc_i        (restore_pc),
      .restore_instr_i     (restore_instr),
      .restore_next_i      (restore_next),
      .restore_epoch_i     (restore_epoch),
      .address_i           (win_addr),
      .data_i              (win_data),
      .valid_o             (out_valid),
      .addr_o              (out_addr),
      .base_o              (out_base),
      .off_o               (out_off),
      .instr_o             (out_instr));

  task automatic tick();
    #1; clk = 1; #2; clk = 0; #2;
  endtask

  task automatic check(input bit ok, input string tag);
    if (!ok) $fatal(1, "%s", tag);
    checked++;
  endtask

  // One fetch window at the accept edge; cleared on the low phase after.
  task automatic feed(input logic [63:0] pc, input logic [63:0] data,
                      input int h, input int rep, input bit k);
    win_addr = pc; win_data = data; hart = HW'(h);
    rsp_epoch = EW'(rep); win_valid = 1'b1; kill = k;
    tick();
    win_valid = 1'b0; kill = 1'b0;
  endtask

  initial begin
    rst_n = 0; flush = 0; kill = 0; win_valid = 0;
    hart = '0; epoch = '0; rsp_epoch = '0;
    restore = 0; restore_hart = '0; restore_pc = '0;
    restore_instr = '0; restore_next = '0; restore_epoch = '0;
    win_addr = '0; win_data = '0;
    repeat (4) tick();
    rst_n = 1;
    repeat (2) tick();

    // ---- A/B/C: three consecutive windows on hart 0, epoch 0 --------
    feed(64'h1000, 64'h0093_0001_0001_0001, 0, 0, 0);  // A accepted
    feed(64'h1008, 64'h0193_0020_0113_0010, 0, 0, 0);  // B accepted; A out
    // A: three C.NOPs, then the RVI lower half goes to the carry bank
    check(out_valid == NI'(4'b0111), "A_VALID");
    check(out_addr[0] == 64'h1000 && out_instr[0][15:0] == 16'h0001, "A_S0");
    check(out_addr[1] == 64'h1002 && out_instr[1][15:0] == 16'h0001, "A_S1");
    check(out_addr[2] == 64'h1004 && out_instr[2][15:0] == 16'h0001, "A_S2");
    check(!carry_done, "A_NO_DONE");
    hart = 0; #1;
    check(bank_valid && bank_pc == 64'h1006, "A_TAIL_1006");

    feed(64'h1010, 64'h0001_0001_0001_0030, 0, 0, 0);  // C accepted; B out
    // B: consumed the 1006 prefix AND left a new tail at 100e -- both
    // must land in the same bank write
    check(out_valid == NI'(4'b0011), "B_VALID");
    check(out_addr[0] == 64'h1006 && out_instr[0] == 32'h0010_0093, "B_S0");
    check(out_addr[1] == 64'h100a && out_instr[1] == 32'h0020_0113, "B_S1");
    check(carry_done, "B_DONE");
    hart = 0; #1;
    check(bank_valid && bank_pc == 64'h100e, "B_TAIL_100E");

    tick();                                           // C out
    check(out_valid == NI'(4'b1111), "C_VALID");
    check(out_addr[0] == 64'h100e && out_instr[0] == 32'h0030_0193, "C_S0");
    check(out_addr[1] == 64'h1012 && out_instr[1][15:0] == 16'h0001, "C_S1");
    check(out_addr[2] == 64'h1014 && out_instr[2][15:0] == 16'h0001, "C_S2");
    check(out_addr[3] == 64'h1016 && out_instr[3][15:0] == 16'h0001, "C_S3");
    check(carry_done, "C_DONE");
    hart = 0; #1;
    check(!bank_valid, "C_CARRY_DROPPED");

    // ---- D + restore: hart-1 tail coexists with hart-0 restore -----
    feed(64'h2000, 64'h00b3_0001_0001_0001, 1, 0, 0);  // D accepted (h1)
    // D's stage-B bank write lands at the same edge as B's delayed
    // verdict restoring hart 0's consumed prefix (0093 @ 1006, next 1008)
    restore = 1'b1; restore_hart = '0;
    restore_pc = 64'h1006; restore_instr = 16'h0093;
    restore_next = 64'h1008;
    // the replayed stream (B2) arrives under the record-bumped epoch 1
    restore_epoch = EW'(1);
    tick();
    restore = 1'b0; restore_epoch = '0;
    check(out_valid == NI'(4'b0111), "D_VALID");
    check(out_addr[0] == 64'h2000 && out_instr[0][15:0] == 16'h0001, "D_S0");
    check(out_addr[1] == 64'h2002 && out_instr[1][15:0] == 16'h0001, "D_S1");
    check(out_addr[2] == 64'h2004 && out_instr[2][15:0] == 16'h0001, "D_S2");
    hart = 0; #1;
    check(bank_valid && bank_pc == 64'h1006, "R_H0_RESTORED");
    hart = 1; #1;
    check(bank_valid && bank_pc == 64'h2006, "D_H1_TAIL");

    // ---- B2: resend B under a fresh response epoch ------------------
    epoch = 1;
    feed(64'h1008, 64'h0193_0020_0113_0010, 0, 1, 0);
    tick();
    check(out_valid == NI'(4'b0011), "B2_VALID");
    check(out_addr[0] == 64'h1006 && out_instr[0] == 32'h0010_0093, "B2_S0");
    check(out_addr[1] == 64'h100a && out_instr[1] == 32'h0020_0113, "B2_S1");
    check(carry_done, "B2_DONE");
    hart = 0; #1;
    check(bank_valid && bank_pc == 64'h100e, "B2_TAIL_100E");
    hart = 1; #1;
    check(bank_valid && bank_pc == 64'h2006, "B2_H1_SURVIVES");

    // ---- K: a killed accepted window is inert on the carry bank -----
    feed(64'h1010, 64'h0001_0001_0001_0030, 0, 1, 1);
    tick();
    check(!carry_done, "K_NO_DONE");
    hart = 0; #1;
    check(bank_valid && bank_pc == 64'h100e, "K_CARRY_KEPT");

    // ---- S: a stale-epoch window is inert and not presented ---------
    epoch = 2;
    feed(64'h1010, 64'h0001_0001_0001_0030, 0, 1, 0);   // epoch-1 rsp, stale
    tick();
    check(out_valid == '0, "S_NOT_PRESENTED");
    hart = 0; #1;
    check(bank_valid && bank_pc == 64'h100e, "S_CARRY_KEPT");

    // ---- F: a normal window with no carry drops it; hart 1 survives --
    feed(64'h3000, 64'h0001_0001_0001_0001, 0, 2, 0);
    tick();
    check(out_valid == NI'(4'b1111), "F_VALID");
    check(out_addr[0] == 64'h3000 && out_instr[0][15:0] == 16'h0001, "F_S0");
    check(!carry_done, "F_NO_DONE");
    hart = 0; #1;
    check(!bank_valid, "F_CARRY_DROPPED");
    hart = 1; #1;
    check(bank_valid && bank_pc == 64'h2006, "F_H1_SURVIVES");

    // ---- G: redirect re-keys the carry — a different-epoch record must
    //         never stitch, even when the replayed window IS the leftover
    //         successor. Kill/flush are inert on the bank (SPEC L1), so the
    //         epoch term is the stitch-time identity check.
    epoch = 3;
    feed(64'h5000, 64'h0093_0001_0001_0001, 0, 3, 0);  // tail carry @ 5006
    tick();
    check(out_valid == NI'(4'b0111), "G_VALID");
    check(out_addr[0] == 64'h5000 && out_instr[0][15:0] == 16'h0001, "G_S0");
    check(!carry_done, "G_NO_DONE");
    hart = 0; #1;
    check(bank_valid && bank_pc == 64'h5006, "G_TAIL_5006");
    // bpf-kill: the killed window is inert, the bank keeps its ep-3 record
    feed(64'h5008, 64'h0001_0001_0001_0030, 0, 3, 1);
    tick();
    hart = 0; #1;
    check(bank_valid && bank_pc == 64'h5006, "G_KILL_KEEP");
    // redirect applies: epoch bumps; the replayed successor returns under
    // epoch 4 — address is carry_pc+2 but the epoch is not, so no stitch:
    // the window decodes at its own start, slot0 at 5008.
    epoch = 4;
    feed(64'h5008, 64'h0001_0001_0001_0030, 0, 4, 0);
    tick();
    check(out_valid == NI'(4'b1111), "G_EPOCH_NO_STITCH");
    check(out_addr[0] == 64'h5008 && out_instr[0][15:0] == 16'h0030, "G_EPOCH_S0");
    check(out_addr[1] == 64'h500a && out_instr[1][15:0] == 16'h0001, "G_EPOCH_S1");
    check(!carry_done, "G_EPOCH_NO_DONE");
    // a new-epoch window that is not the leftover successor likewise
    // decodes at its own start — no consume, no stitch
    feed(64'h6000, 64'h0001_0001_0001_0001, 0, 4, 0);
    tick();
    check(out_valid == NI'(4'b1111), "G_NS_VALID");
    check(out_addr[0] == 64'h6000 && out_instr[0][15:0] == 16'h0001, "G_NS_S0");
    check(!carry_done, "G_NS_NO_DONE");

    // ---- H: same-epoch successor still stitches (positive control) ----
    feed(64'h7000, 64'h0093_0001_0001_0001, 0, 4, 0);  // tail carry @ 7006
    tick();
    hart = 0; #1;
    check(bank_valid && bank_pc == 64'h7006, "H_TAIL_7006");
    feed(64'h7008, 64'h0001_0001_0001_0030, 0, 4, 0);
    tick();
    // side-1 stitch: the completed 32-bit @7006 then the successor's three
    // own compressed instructions — four valid slots, carry consumed.
    check(out_valid == NI'(4'b1111), "H_STITCH");
    check(out_addr[0] == 64'h7006 && out_instr[0] == 32'h0030_0093, "H_S0");
    check(out_addr[1] == 64'h700a && out_instr[1][15:0] == 16'h0001, "H_S1");
    check(out_addr[2] == 64'h700c && out_instr[2][15:0] == 16'h0001, "H_S2");
    check(out_addr[3] == 64'h700e && out_instr[3][15:0] == 16'h0001, "H_S3");
    check(carry_done, "H_DONE");
    hart = 1; #1;
    check(bank_valid && bank_pc == 64'h2006, "H_H1_SURVIVES");

    $display("HYP8_REALIGN_PASS checked=%0d", checked);
    $finish;
  end
endmodule


// ---------------------------------------------------------------------------
// Line-check leaf — the real g6lc_fe_nextline + g6lc_fe_btb_check pair wired
// exactly as fetch_B/frontend.sv wires them (push records the registered
// read-ahead guess; the check decides override #1). Reproduces the diagnosed
// hyp8 mechanism: a direct-jump window (the ROM park loop's `j -4`) whose
// verdict predicts taken trains the untagged line table — a guess no tagged
// predictor can ever back (the tagged BTB only trains mispredicted JumpR).
// On the next sequential push of the block the check's unsupported-taken
// clause (`!btb_hit && taken && !ras_agree`) fired and redirected fetch to
// next_block — past the jump and into the middle of the stream. The fix:
// train_tagdom gates taken writes, so only tag-domain CF (JumpR/Return)
// verdicts/resolves leave a taken guess; direct-CF blocks stay untaken and
// are re-predicted at the verdict stage each pass.
//
//   A: untrained table  — sequential push walk produces no override
//   B: direct-CF taken train (tagdom=0) — guess stays untaken, no override,
//      fetch continues sequentially past the block (no mid-stream redirect)
//   C: tag-domain taken train (tagdom=1) — guess lands; an unbacked taken
//      guess still fires override #1, but the squelch restarts at the
//      queue frontier (the post-push successor), never a block position
//      past the queue tail — the epoch-killed in-flight windows must be
//      refetched (the real adjudication; under this config the check owns
//      no tagged BTB — TAGE_LITE + BPIndirectEn — so only RAS agreement
//      can back a guess)
//   C2: same disagreement with the frontier held behind the checked block
//      — the restart is still the frontier, not next_block
//   D: same taken guess with the RAS top agreeing — the check stays silent
//   E: an unqualified/not-taken write clears the entry (unlearn)
// ---------------------------------------------------------------------------
module tb_g6lc_hyp8_linecheck;
  import g6lc_core_pkg::*;
  `include "g6lc_core_types.svh"

  function automatic config_pkg::g6lc_cfg_t configuration();
    return build_config_pkg::build_config(g6lc_config_pkg::g6lc_cfg);
  endfunction
  localparam config_pkg::g6lc_cfg_t C = configuration();
  localparam g6lc_hyp_pkg::g6lc_hyp_cfg_t H = g6lc_hyp_pkg::Hyp8;
  localparam int EW = (H.FeEpochBits > 0) ? H.FeEpochBits : 1;

  localparam type btb_prediction_t = struct packed {
    logic                    valid;
    logic [C.VLEN-1:0]     target_address;
  };
  localparam type btb_update_t = struct packed {
    logic                    valid;
    logic [C.VLEN-1:0]     pc;
    logic [C.VLEN-1:0]     target_address;
  };
  localparam type ras_t = struct packed {
    logic                    valid;
    logic [C.VLEN-1:0]     ra;
  };

  logic clk = 0, rst_n = 0;
  int checked = 0;
  int lim = 0;

  // nextline kernel + line table
  logic               flush, red_valid, red_step, hold, advance;
  logic [C.VLEN-1:0]  boot_addr, red_pc, hold_pc;
  logic               train_valid, train_taken, train_tagdom;
  logic [C.VLEN-1:0]  train_pc, train_target;
  logic [C.VLEN-1:0]  npc, npc_d, fetch_address;
  logic               line_taken;
  logic [C.VLEN-1:0]  line_target;

  // tagged check (push side)
  logic               push_valid;
  logic [C.VLEN-1:0]  push_vaddr;
  logic [C.VLEN-1:0]  resume_pc;
  logic               ov1_valid;
  logic [C.VLEN-1:0]  ov1_pc;
  logic               otr_v, otr_taken;
  logic [C.VLEN-1:0]  otr_pc, otr_target;
  btb_update_t        btb_update;
  ras_t               ras_predict;

  g6lc_fe_nextline #(
      .G6LCCfg(C),
      .HypCfg (H)
  ) i_nl (
      .clk_i           (clk),
      .rst_ni          (rst_n),
      .flush_i         (flush),
      .boot_addr_i     (boot_addr),
      .red_valid_i     (red_valid),
      .red_pc_i        (red_pc),
      .red_step_i      (red_step),
      .hold_i          (hold),
      .hold_pc_i       (hold_pc),
      .advance_i       (advance),
      .train_valid_i   (train_valid),
      .train_pc_i      (train_pc),
      .train_taken_i   (train_taken),
      .train_target_i  (train_target),
      .train_tagdom_i  (train_tagdom),
      .npc_o           (npc),
      .npc_d_o         (npc_d),
      .fetch_address_o (fetch_address),
      .line_taken_o    (line_taken),
      .line_target_o   (line_target));

  g6lc_fe_btb_check #(
      .G6LCCfg         (C),
      .HypCfg          (H),
      .btb_update_t    (btb_update_t),
      .btb_prediction_t(btb_prediction_t),
      .ras_t           (ras_t)
  ) i_chk (
      .clk_i              (clk),
      .rst_ni             (rst_n),
      .flush_bp_i         (flush),
      .debug_mode_i       (1'b0),
      .epoch_i            (EW'(0)),
      .push_valid_i       (push_valid),
      .push_vaddr_i       (push_vaddr),
      .push_epoch_i       (EW'(0)),
      .push_line_taken_i  (line_taken),
      .push_line_target_i (line_target),
      .btb_update_i       (btb_update),
      .ras_predict_i      (ras_predict),
      .resume_pc_i        (resume_pc),
      .ov1_valid_o        (ov1_valid),
      .ov1_pc_o           (ov1_pc),
      .train_valid_o      (otr_v),
      .train_pc_o         (otr_pc),
      .train_taken_o      (otr_taken),
      .train_target_o     (otr_target));

  task automatic tick();
    #1; clk = 1; #2; clk = 0; #2;
  endtask

  task automatic check(input bit ok, input string tag);
    if (!ok) begin
      $display("CHKFAIL %s ov1=%b ov1pc=%h res=%h fa=%h lt=%b ltt=%h",
               tag, ov1_valid, ov1_pc, resume_pc, fetch_address,
               line_taken, line_target);
      $fatal(1, "%s", tag);
    end
    checked++;
  endtask

  // Present this cycle's fetch_address as an accepted push (the frontend's
  // ftq_push line) and advance the cursor; sample ov1 on the next line.
  // The queue-frontier model: an accepted contiguous push owns the whole
  // block, so the resume point becomes its successor — unless adv_resume
  // holds it back to model a lagging queue tail.
  task automatic step(input bit push, input bit adv_resume = 1'b1);
    logic [63:0] pushed;
    pushed          = fetch_address;
    // drive the post-push frontier up front: the check that consumes it
    // fires on the following cycle, by which time the register holds this
    // value (resume_d). Driving it after the edge would race Verilator's
    // comb settle inside this process.
    if (push && adv_resume) resume_pc = pushed + 64'h8;
    push_valid      = push;
    push_vaddr      = fetch_address;
    advance         = 1'b1;
    tick();
    advance         = 1'b0;
    push_valid      = 1'b0;
  endtask

  // A redirect record (verdict/override): the redirect cycle presents
  // red_pc and, like the frontend's reseed, is not pushed. The same event
  // re-keys the queue frontier to the redirect target.
  task automatic reseed(input logic [63:0] pc);
    red_valid = 1'b1; red_pc = pc; red_step = 1'b0;
    resume_pc = pc;
    tick();
    red_valid = 1'b0;
  endtask

  task automatic train(input logic [63:0] pc, input bit taken,
                       input logic [63:0] target, input bit tagdom);
    train_valid = 1'b1; train_pc = pc; train_taken = taken;
    train_target = target; train_tagdom = tagdom;
    tick();
    train_valid = 1'b0;
  endtask

  initial begin
    flush = 0; red_valid = 0; red_step = 0; hold = 0; advance = 0;
    hold_pc = '0; red_pc = '0; boot_addr = 64'h10000;
    train_valid = 0; train_taken = 0; train_tagdom = 0;
    train_pc = '0; train_target = '0;
    push_valid = 0; push_vaddr = '0; resume_pc = '0;
    btb_update = '0; ras_predict = '0;
    repeat (4) tick();
    rst_n = 1;
    repeat (2) tick();
    check(fetch_address == 64'h10000, "BOOT_10000");

    // ---- A: untrained table — walk 0x10000 .. 0x10060 pushing each block;
    //    an untrained entry reads untaken, the check never fires.
    while (fetch_address < 64'h10058 && lim < 64) begin
      step(1); check(!ov1_valid, "A_OV1"); lim++;
    end
    check(fetch_address == 64'h10058, "A_REACHED");
    step(1); check(!ov1_valid, "A_TAIL");

    // ---- B: the park-loop mechanism — a direct `j` verdict predicts
    //    0x1004c taken for the 0x10050 block, but with tagdom=0 the guess
    //    must NOT be cached. Re-entering the block pushes an untaken guess;
    //    no override, and the cursor continues sequentially to 0x10058 —
    //    never a redirect into the middle of the stream.
    train(64'h10050, 1'b1, 64'h1004c, 1'b0);   // the j -4 verdict, direct CF
    check(!ov1_valid, "B_TRAIN_QUIET");
    reseed(64'h10048);                        // verdict redirect to the loop
    check(!ov1_valid, "B_RED_QUIET");
    step(1); check(!ov1_valid, "B_P48");      // push 0x10048
    check(fetch_address == 64'h10050, "B_CURSOR");
    check(!line_taken, "B_GUESS_UNTAKEN");    // tagdom-masked: no taken guess
    step(1); check(!ov1_valid, "B_P50");      // push 0x10050 — no ov1
    check(fetch_address == 64'h10058, "B_SEQ"); // sequential, not 0x4c, not
                                                // an interior redirect
    step(1); check(!ov1_valid, "B_P58");
    step(1); check(!ov1_valid, "B_P60");

    // ---- C: a tag-domain verdict (JumpR/Return) DOES leave a taken guess;
    //    with no tagged backing the check still fires — but the squelch
    //    restarts at the queue frontier (successor of the pushed block),
    //    so the epoch-killed windows are refetched rather than skipped.
    train(64'h10050, 1'b1, 64'h1004c, 1'b1);  // tagdom=1: guess is cached
    reseed(64'h10048);
    step(1); check(!ov1_valid, "C_P48");
    check(fetch_address == 64'h10050, "C_CURSOR");
    check(line_taken && line_target == 64'h1004c, "C_GUESS_TAKEN");
    step(1);                                   // push 0x10050, steer to 0x4c
    check(ov1_valid && ov1_pc == 64'h10058, "C_OV1_RESUME");
    reseed(64'h10058);                         // apply the override redirect
    step(1);                                   // drain: the check evaluates
                                               // the 0x58 push, quiet again
    check(!ov1_valid, "C_DRAIN");

    // ---- C2: the restart is the queue frontier even when it lags the
    //    checked block — the same disagreement must resume at the last
    //    accepted tail so nothing the backend still needs is skipped.
    ras_predict = '0;
    train(64'h10050, 1'b1, 64'h1004c, 1'b1);
    reseed(64'h10048);
    step(1); check(!ov1_valid, "C2_P48");
    check(line_taken && line_target == 64'h1004c, "C2_GUESS_TAKEN");
    resume_pc = 64'h10010;                     // queue tail lags two blocks
    step(1, 1'b0);                             // push 0x10050, frontier held
    check(ov1_valid && ov1_pc == 64'h10010, "C2_OV1_LAG_RESUME");
    reseed(64'h10010);
    step(1); check(!ov1_valid, "C2_DRAIN");

    // ---- D: same taken guess with the RAS top agreeing with the target —
    //    the adjudicated (Return) path stays silent.
    ras_predict.valid = 1'b1; ras_predict.ra = 64'h1004c;
    reseed(64'h10048);
    step(1); check(!ov1_valid, "D_P48");
    check(line_taken && line_target == 64'h1004c, "D_GUESS_TAKEN");
    step(1); check(!ov1_valid, "D_P50_RAS");
    ras_predict = '0;

    // ---- E: unlearn — a not-taken write clears the entry regardless of
    //    tagdom; the block reads untaken and the walk is quiet.
    train(64'h10050, 1'b0, 64'h0, 1'b0);
    reseed(64'h10048);
    step(1); check(!ov1_valid, "E_P48");
    check(fetch_address == 64'h10050, "E_CURSOR");
    check(!line_taken, "E_GUESS_CLEARED");
    step(1); check(!ov1_valid, "E_P50");
    step(1); check(!ov1_valid, "E_DRAIN");

    $display("HYP8_LINECHECK_PASS checked=%0d", checked);
    $finish;
  end
endmodule


// ---------------------------------------------------------------------------
// Queue leaf — the real instr_queue + its g6lc_fifo_v3 helpers. One valid
// slot per packet rotates the input pointer across all four FIFOs. Every
// legal cf_t class is pushed, held two cycles with downstream not-ready, and
// must be delivered with PC / word / cf / checkpoint tag / predicted target
// intact. A cf==NoCF control word must not consume a target; two CF packets
// queued before draining must return their targets in order; an epoch bump
// must drop a stale head without delivery and the next-epoch packet must
// arrive unchanged.
// ---------------------------------------------------------------------------
module tb_g6lc_hyp8_queue;
  import g6lc_core_pkg::*;
  `include "g6lc_core_types.svh"

  // The built g6lc64_hyp8 geometry: INSTR_PER_FETCH=4 slots, NrIssue=2,
  // VLEN=XLEN=64, single hart.
  function automatic config_pkg::g6lc_cfg_t configuration();
    return build_config_pkg::build_config(g6lc_config_pkg::g6lc_cfg);
  endfunction
  localparam config_pkg::g6lc_cfg_t C = configuration();
  localparam g6lc_hyp_pkg::g6lc_hyp_cfg_t H = g6lc_hyp_pkg::Hyp8;

  localparam int NI = C.INSTR_PER_FETCH;
  localparam int NP = C.NrIssuePorts;
  localparam int EW = (H.FeEpochBits > 0) ? H.FeEpochBits : 1;
  localparam int HW = (C.NrHarts > 1) ? $clog2(C.NrHarts) : 1;

  typedef `G6LC_BRANCHPREDICT_SBE_T(C) branchpredict_sbe_t;
  typedef `G6LC_EXCEPTION_T(C)         exception_t;
  // The queue assigns only named members; keep exactly the fields it
  // writes (address / instruction / branch_predict / ex / hart_id).
  typedef struct packed {
    logic [C.VLEN-1:0]  address;
    logic [31:0]        instruction;
    branchpredict_sbe_t branch_predict;
    exception_t         ex;
    logic [HW-1:0]      hart_id;
  } fetch_entry_t;

  logic clk = 0, rst_n = 0;
  int checked = 0;

  logic                      flush;
  logic [HW-1:0]             hart;
  logic [EW-1:0]             epoch, push_epoch;
  logic [NI-1:0][31:0]       q_instr;
  logic [NI-1:0][C.VLEN-1:0] q_addr;
  logic [NI-1:0]             q_valid;
  logic                      lo_complete;
  cf_t [NI-1:0]              q_cf;
  logic [NI-1:0]             q_ckpt_v;
  logic [NI-1:0][7:0]        q_ckpt_idx;
  logic [NI-1:0]             q_call, q_ret;
  logic [C.VLEN-1:0]         predict_addr;
  frontend_exception_t       fe_ex;
  logic                      q_ready, replay;
  logic [C.VLEN-1:0]         replay_addr;
  logic [NI-1:0]             consumed;
  fetch_entry_t [NP-1:0]     fentry;
  logic [NP-1:0]             fe_valid, fe_ready;
  logic [C.NrHarts-1:0]      oldest_v;
  logic [C.NrHarts-1:0][C.VLEN-1:0] oldest_pc;

  instr_queue #(
      .G6LCCfg      (C),
      .HypCfg       (H),
      .fetch_entry_t(fetch_entry_t)
  ) i_q (
      .clk_i                (clk),
      .rst_ni               (rst_n),
      .flush_i              (flush),
      .hart_i               (hart),
      .epoch_i              (epoch),
      .push_epoch_i         (push_epoch),
      .instr_i              (q_instr),
      .addr_i               (q_addr),
      .valid_i              (q_valid),
      .leftover_complete_i  (lo_complete),
      .ready_o              (q_ready),
      .consumed_o           (consumed),
      .exception_i          (fe_ex),
      .exception_addr_i     ('0),
      .exception_gpaddr_i   ('0),
      .exception_tinst_i    ('0),
      .exception_gva_i      (1'b0),
      .predict_address_i    (predict_addr),
      .cf_type_i            (q_cf),
      .ckpt_v_i             (q_ckpt_v),
      .ckpt_idx_i           (q_ckpt_idx),
      .is_call_i            (q_call),
      .is_return_i          (q_ret),
      .replay_o             (replay),
      .replay_addr_o        (replay_addr),
      .fetch_entry_o        (fentry),
      .fetch_entry_valid_o  (fe_valid),
      .fetch_entry_ready_i  (fe_ready),
      .queue_oldest_valid_o (oldest_v),
      .queue_oldest_pc_o    (oldest_pc));

  task automatic tick();
    #1; clk = 1; #2; clk = 0; #2;
  endtask

  task automatic check(input bit ok, input string tag);
    if (!ok) $fatal(1, "%s", tag);
    checked++;
  endtask

  // One valid slot (slot 0) per packet: successive pushes rotate the input
  // pointer across the FIFOs. Push acceptance is sampled before the edge.
  task automatic push1(input logic [63:0] pc, input logic [31:0] instr,
                       input cf_t cf, input logic [7:0] tag, input bit cv,
                       input bit call, input bit ret,
                       input logic [63:0] target, input string tg);
    q_valid = '0; q_instr = '0; q_addr = '0;
    q_cf = '{default: NoCF}; q_ckpt_v = '0; q_ckpt_idx = '0;
    q_call = '0; q_ret = '0;
    q_valid[0] = 1'b1; q_instr[0] = instr; q_addr[0] = pc;
    q_cf[0] = cf; q_ckpt_v[0] = cv; q_ckpt_idx[0] = tag;
    q_call[0] = call; q_ret[0] = ret;
    predict_addr = target;
    push_epoch = epoch;
    #1;
    check(q_ready && consumed == NI'(4'b0001), {tg, "_ACCEPT"});
    tick();
    q_valid = '0;
    q_cf[0] = NoCF;
  endtask

  // Hold fetch_entry_ready low for two cycles: the head must stay presented
  // and unchanged; then accept it and require the full stored tuple.
  task automatic drain1(input logic [63:0] pc, input logic [31:0] instr,
                        input cf_t cf, input logic [7:0] tag, input bit cv,
                        input bit call, input bit ret,
                        input bit has_tgt, input logic [63:0] target,
                        input string tg);
    fe_ready = '0;
    #1;
    check(fe_valid[0], {tg, "_VALID0"});
    check(fentry[0].address == pc && fentry[0].instruction == instr,
          {tg, "_PAYLOAD"});
    check(fentry[0].branch_predict.cf == cf, {tg, "_CF"});
    check(fentry[0].branch_predict.ckpt_v == cv &&
          fentry[0].branch_predict.ckpt_idx == tag, {tg, "_CKPT"});
    check(fentry[0].branch_predict.is_call == call &&
          fentry[0].branch_predict.is_ret == ret, {tg, "_CR"});
    if (has_tgt)
      check(fentry[0].branch_predict.predict_address == target, {tg, "_TGT"});
    tick();  // first held cycle
    check(fe_valid[0] && fentry[0].address == pc &&
          fentry[0].instruction == instr &&
          fentry[0].branch_predict.cf == cf &&
          fentry[0].branch_predict.ckpt_idx == tag, {tg, "_HELD"});
    if (has_tgt)
      check(fentry[0].branch_predict.predict_address == target,
            {tg, "_TGT_HELD"});
    tick();  // second held cycle
    check(fe_valid[0] && fentry[0].address == pc, {tg, "_HELD2"});
    fe_ready[0] = 1'b1;
    tick();  // accept
    fe_ready = '0;
  endtask

  initial begin
    rst_n = 0; flush = 0; hart = '0; epoch = '0; push_epoch = '0;
    q_valid = '0; q_instr = '0; q_addr = '0;
    q_cf = '{default: NoCF}; q_ckpt_v = '0; q_ckpt_idx = '0;
    q_call = '0; q_ret = '0; lo_complete = 0;
    predict_addr = '0; fe_ex = FE_NONE; fe_ready = '0;
    repeat (4) tick();
    rst_n = 1;
    repeat (2) tick();

    // ---- every legal cf_t class, one slot per packet ----------------
    // NoCF   nop     0x00000013
    push1(64'h1000, 32'h0000_0013, NoCF, 8'h11, 1'b1, 0, 0, 64'h0, "NCF");
    drain1(64'h1000, 32'h0000_0013, NoCF, 8'h11, 1'b1, 0, 0, 0, '0, "NCF");
    // Branch  beq x0,x0,0 0x00000063
    push1(64'h1004, 32'h0000_0063, Branch, 8'h22, 1'b1, 0, 0, 64'h2000, "BR");
    drain1(64'h1004, 32'h0000_0063, Branch, 8'h22, 1'b1, 0, 0, 1, 64'h2000, "BR");
    // Jump    jal 0  0x0000006f
    push1(64'h1008, 32'h0000_006f, Jump, 8'h33, 1'b1, 0, 0, 64'h2040, "JMP");
    drain1(64'h1008, 32'h0000_006f, Jump, 8'h33, 1'b1, 0, 0, 1, 64'h2040, "JMP");
    // JumpR   jalr ra,0(t0)  0x000280e7 (a call)
    push1(64'h100c, 32'h0002_80e7, JumpR, 8'h44, 1'b1, 1, 0, 64'h2080, "JMR");
    drain1(64'h100c, 32'h0002_80e7, JumpR, 8'h44, 1'b1, 1, 0, 1, 64'h2080, "JMR");
    // Return  jalr x0,0(ra)  0x00008067
    push1(64'h1010, 32'h0000_8067, Return, 8'h55, 1'b1, 0, 1, 64'h20c0, "RET");
    drain1(64'h1010, 32'h0000_8067, Return, 8'h55, 1'b1, 0, 1, 1, 64'h20c0, "RET");

    // ---- not-predicted branch word, cf=NoCF: opcode control class must
    // survive while consuming no target slot ----------------------------
    push1(64'h1014, 32'h0000_0063, NoCF, 8'h66, 1'b0, 0, 0, 64'h0, "NBR");
    // ---- two consecutive CF packets before draining: target order ----
    push1(64'h1018, 32'h0000_006f, Jump, 8'h77, 1'b1, 0, 0, 64'h3000, "T1");
    push1(64'h101c, 32'h0000_8067, Return, 8'h88, 1'b1, 0, 1, 64'h3040, "T2");
    drain1(64'h1014, 32'h0000_0063, NoCF, 8'h66, 1'b0, 0, 0, 0, '0, "NBR");
    drain1(64'h1018, 32'h0000_006f, Jump, 8'h77, 1'b1, 0, 0, 1, 64'h3000, "T1");
    drain1(64'h101c, 32'h0000_8067, Return, 8'h88, 1'b1, 0, 1, 1, 64'h3040, "T2");

    // ---- two-orphan starvation counterexample --------------------------
    // Both CF packets are ACCEPTED under epoch 0 while downstream is held
    // off, filling the depth-2 target FIFO. A weak redirect's epoch bump
    // must NOT revoke the accepted entries: they stay live, drain in
    // order, and their pops free the target FIFO again.
    push1(64'h1020, 32'h0000_006f, Jump,   8'h99, 1'b1, 0, 0, 64'h4000, "EP0J");
    push1(64'h1024, 32'h0000_8067, Return, 8'hbb, 1'b1, 0, 1, 64'h4040, "EP0R");
    #1;
    check(!q_ready, "EP_TGT_FULL");    // 2-entry target FIFO is full
    epoch = 1;                         // weak redirect — NO flush_i
    #1;
    check(fe_valid[0] && fentry[0].address == 64'h1020 &&
          fentry[0].branch_predict.cf == Jump, "EP0_STILL_LIVE");
    drain1(64'h1020, 32'h0000_006f, Jump, 8'h99, 1'b1, 0, 0, 1, 64'h4000, "EP0J");
    drain1(64'h1024, 32'h0000_8067, Return, 8'hbb, 1'b1, 0, 1, 1, 64'h4040, "EP0R");
    #1;
    check(q_ready, "EP_RDY_RECOVERED");  // both targets popped => ready again

    // ---- unaccepted dead-epoch window -----------------------------------
    // A packet carried under the OLD epoch is filtered at acceptance:
    // nothing pushed, no replay, no entry presented, pointers untouched.
    q_valid = '0; q_instr = '0; q_addr = '0;
    q_cf = '{default: NoCF}; q_ckpt_v = '0; q_ckpt_idx = '0;
    q_call = '0; q_ret = '0;
    q_valid[0] = 1'b1; q_instr[0] = 32'h0000_006f; q_addr[0] = 64'h1028;
    q_cf[0] = Jump; q_ckpt_v[0] = 1'b1; q_ckpt_idx[0] = 8'hcc;
    predict_addr = 64'h5000;
    push_epoch = 0;                    // dead epoch vs current epoch=1
    #1;
    check(consumed == '0 && !replay, "DEAD_NOT_ACCEPTED");
    check(fe_valid == '0, "DEAD_NOT_PRESENTED");
    tick();
    q_valid = '0; q_cf[0] = NoCF;
    #1;
    check(fe_valid == '0, "DEAD_NO_ENTRY");
    // a live epoch-1 packet must deliver its exact tuple
    push1(64'h102c, 32'h0000_006f, Jump, 8'hdd, 1'b1, 0, 0, 64'h5100, "E1");
    drain1(64'h102c, 32'h0000_006f, Jump, 8'hdd, 1'b1, 0, 0, 1, 64'h5100, "E1");

    // ---- explicit architectural flush: both FIFOs clear -----------------
    push1(64'h1030, 32'h0000_006f, Jump, 8'hee, 1'b1, 0, 0, 64'h5200, "FLSH");
    fe_ready = '0;
    #1;
    check(fe_valid[0] && fentry[0].address == 64'h1030, "FLSH_PRESENTED");
    flush = 1'b1;
    tick();
    flush = 1'b0;
    #1;
    check(fe_valid == '0, "FLSH_NO_DELIVERY");
    check(q_ready, "FLSH_RDY");          // instruction AND target FIFOs clear
    // a fresh packet still delivers unchanged after the flush
    push1(64'h1034, 32'h0000_8067, Return, 8'hff, 1'b1, 0, 1, 64'h5300, "POSTF");
    drain1(64'h1034, 32'h0000_8067, Return, 8'hff, 1'b1, 0, 1, 1, 64'h5300, "POSTF");

    $display("HYP8_QUEUE_PASS checked=%0d", checked);
    $finish;
  end
endmodule


// ---------------------------------------------------------------------------
// ALU leaf — the real staggered three-stage alu (Hyp8: AluStages==3,
// AluStaggered==1) with result ownership. A packet without result ownership
// (branch compare / CSR / AES class, or a flushed cycle) must never claim
// the A3 result slot: the younger valid A2 result must still publish. A
// valid LAT_ALU_FULL op publishes at A3 with its own tid.
// ---------------------------------------------------------------------------
module tb_g6lc_hyp8_alu;
  import g6lc_core_pkg::*;
  `include "g6lc_core_types.svh"

  function automatic config_pkg::g6lc_cfg_t configuration();
    return build_config_pkg::build_config(g6lc_config_pkg::g6lc_cfg);
  endfunction
  localparam config_pkg::g6lc_cfg_t C = configuration();
  localparam g6lc_hyp_pkg::g6lc_hyp_cfg_t H = g6lc_hyp_pkg::Hyp8;
  localparam int TID = C.TRANS_ID_BITS;

  // The bench pins the activated three-stage profile (Hyp8.AluStages==3
  // per g6lc_hyp_pkg; AluStaggered==1).
  initial begin
    if (!(H.AluStages == 3 && H.AluStaggered)) $fatal(1, "ALU_CFG");
  end

  // Minimal fu_data_t: the ALU reads operand_a/operand_b/operation/
  // trans_id only.
  typedef struct packed {
    logic [C.XLEN-1:0] operand_a;
    logic [C.XLEN-1:0] operand_b;
    logic [TID-1:0]    trans_id;
    fu_op              operation;
  } fu_data_t;

  logic clk = 0, rst_n = 0;
  int checked = 0;

  fu_data_t            fud;
  logic                rv;
  logic [C.XLEN-1:0]   result, result_d;
  logic                bres;
  logic [31:0]         fwd_low;
  logic [TID-1:0]      ftid, qtid, rtid;
  logic                s2a3, s3a3;

  alu #(
      .G6LCCfg  (C),
      .HypCfg   (H),
      .HasBranch(1'b1),
      .fu_data_t(fu_data_t)
  ) i_alu (
      .clk_i           (clk),
      .rst_ni          (rst_n),
      .fu_data_i       (fud),
      .result_valid_i  (rv),
      .fu_data_cpop_i  ('0),
      .result_o        (result),
      .alu_branch_res_o(bres),
      .alu_fwd_low_o   (fwd_low),
      .alu_fwd_tid_o   (ftid),
      .alu_fwd_qtid_o  (qtid),
      .alu_fwd_rtid_o  (rtid),
      .alu_s2_a3_o     (s2a3),
      .alu_s3_a3_o     (s3a3),
      .alu_result_d_o  (result_d),
      .fwd_a_i         ('0),
      .fwd_b_i         ('0));

  task automatic tick();
    #1; clk = 1; #2; clk = 0; #2;
  endtask

  task automatic check(input bit ok, input string tag);
    if (!ok) $fatal(1, "%s", tag);
    checked++;
  endtask

  task automatic drive(input fu_op op, input logic [63:0] a,
                       input logic [63:0] b, input int tid, input bit v);
    fud.operation = op; fud.operand_a = a; fud.operand_b = b;
    fud.trans_id = TID'(tid); rv = v;
  endtask

  // Invalid-owner predecessor at c0, valid ADD at c1, bubble at c2:
  // at c3 the predecessor reaches its A3 slot but must not claim it --
  // result_o is the ADD's registered A2 result 12 with the ADD's qtid.
  task automatic invalid_pred(input fu_op pred_op,
                              input logic [63:0] pa, input logic [63:0] pb,
                              input string tg);
    drive(pred_op, pa, pb, 4, 1'b0);
    tick();                              // c1: predecessor in A1
    if (pred_op == EQ)
      check(bres == 1'b1, {tg, "_EQ_CMP"});  // EQ 5==5 compare still true
    drive(ADD, 64'd5, 64'd7, 5, 1'b1);
    tick();                              // c2: predecessor in A2 slot
    drive(ADD, '0, '0, 0, 1'b0);         // c2 drive: bubble (owner=0)
    tick();                              // c3: predecessor at A3 slot
    check(result == 64'd12, {tg, "_ADD12"});
    check(qtid == TID'(5), {tg, "_QTID"});
    check(!s3a3, {tg, "_NO_A3CLAIM"});
    // drain: bubbles until the A2 result is out of the publication window
    drive(ADD, '0, '0, 0, 1'b0);
    tick(); tick(); tick();
  endtask

  initial begin
    rst_n = 0; rv = 1'b0; fud = '0;
    repeat (4) tick();
    rst_n = 1;
    repeat (2) tick();

    // ---- invalid result-owner predecessors ----------------------------
    invalid_pred(EQ,      64'd5, 64'd5, "PE_EQ");
    invalid_pred(CSR_READ, 64'd0, 64'd0, "PE_CSR");
    invalid_pred(AES64ES, 64'd1, 64'd2, "PE_AES");
    invalid_pred(SLL,     64'd9, 64'd3, "PE_SLL");   // a3_d=72 must not leak

    // ---- valid full-class op: SLL 9<<3 publishes 72 at A3 -------------
    drive(SLL, 64'd9, 64'd3, 6, 1'b1);   // c0
    tick();                              // c1: A1
    drive(ADD, '0, '0, 0, 1'b0);         // c1 drive: bubble -- no real
    tick();                              // c2: SLL at the A2 slot
    check(s2a3, "VS_S2A3");
    drive(ADD, 64'd5, 64'd7, 7, 1'b1);   // c2 drive: valid ADD (bubble gap
    tick();                              //       keeps A2/A3 pubs distinct)
    check(result == 64'd72, "VS_RES72"); // c3: SLL publishes at A3
    check(s3a3, "VS_S3A3");
    check(rtid == TID'(6), "VS_RTID");
    tick();                              // c4: the ADD's A2 result is due
    check(result == 64'd12, "VA_RES12");
    check(qtid == TID'(7), "VA_QTID");
    check(!s3a3, "VA_NO_A3CLAIM");
    drive(ADD, '0, '0, 0, 1'b0);
    tick(); tick();

    // ---- flush-equivalent: owner=0 full-class packet then valid ADD ---
    invalid_pred(SLL, 64'd3, 64'd4, "FLSH_SLL");

    $display("HYP8_ALU_PASS checked=%0d", checked);
    $finish;
  end
endmodule

// ---------------------------------------------------------------------------
// tb_g6lc_hyp8_rom: actual g6lc_axi2mem_reg #(.RD_LAT(3)) + actual banked
// Guarded: the APU-side package types are only compiled by the rom leaf.
`ifdef G6LC_HYP8_ROM_LEAF
// bootrom — the AXI-to-two-register-ROM boundary. The legacy axi2mem sampled
// rdata_i one cycle after its combinational req, while the ROM needs three
// edges (req at edge0, addr_q edge1, bank_rdata_q edge2): the r6 diagnostic
// trace showed the AXI read for 0x10008 returning 0x10000's word.
// ---------------------------------------------------------------------------
module tb_g6lc_hyp8_rom;
  logic clk = 0, rst_n = 0;
  int checked = 0;
  always #5 clk = ~clk;
  task tick(); @(posedge clk); #1; endtask
  task check(input logic cond, input string name);
    checked++;
    if (!cond) begin
      $display("FAIL %s", name);
      $fatal(1, "tb_g6lc_hyp8_rom");
    end
  endtask

  g6lc_axi_soc::req_slv_t  req;
  g6lc_axi_soc::resp_slv_t resp;
  logic        mem_req, mem_we;
  logic [63:0] mem_addr, mem_wdata, mem_rdata;
  logic [7:0]  mem_be;

  // Same parameter as the harness instance: adapter req pulse at edge0,
  // ROM addr_q at edge1, bank data at edge2, capture sampled at edge3.
  localparam int unsigned BootromReadLatency = 3;

  g6lc_axi2mem_reg #(
      .AXI_ADDR_WIDTH (64),
      .AXI_DATA_WIDTH (64),
      .RD_LAT         (BootromReadLatency),
      .axi_req_t      (g6lc_axi_soc::req_slv_t),
      .axi_resp_t     (g6lc_axi_soc::resp_slv_t)
  ) dut_axi (
      .clk_i     (clk),
      .rst_ni    (rst_n),
      .slv_req_i (req),
      .slv_resp_o(resp),
      .req_o     (mem_req),
      .we_o      (mem_we),
      .addr_o    (mem_addr),
      .be_o      (mem_be),
      .wdata_o   (mem_wdata),
      .rdata_i   (mem_rdata)
  );

  bootrom dut_rom (
      .clk_i   (clk),
      .req_i   (mem_req),
      .addr_i  (mem_addr),
      .rdata_o (mem_rdata)
  );

  // Words 0..2 of the emit (mem[0] is the last concat entry).
  localparam logic [63:0] W0 = 64'h01f41413_00100413;
  localparam logic [63:0] W1 = 64'h00000597_f1402573;
  localparam logic [63:0] W2 = 64'h00040067_07458593;

  task send_ar(input logic [63:0] addr, input logic [7:0] len);
    req.ar       = '0;
    req.ar.addr  = addr;
    req.ar.len   = len;
    req.ar.size  = 3'd3;   // full 64-bit beat
    req.ar.burst = axi_pkg::BURST_INCR;
    req.ar_valid = 1'b1;
    @(posedge clk);
    while (!resp.ar_ready) @(posedge clk);
    #1;
    req.ar_valid = 1'b0;
  endtask

  // One R beat: wait r_valid with r_ready low, optionally hold it two more
  // cycles to prove the beat is held, then accept.
  task recv_r(input logic [63:0] exp, input logic explast,
              input bit hold2, input string tag);
    int unsigned guard;
    logic [63:0] d0;
    guard = 0;
    req.r_ready = 1'b0;
    while (!resp.r_valid) begin
      @(posedge clk);
      guard++;
      if (guard > 200) begin
        check(1'b0, {tag, "_R_TIMEOUT"});
        return;
      end
    end
    d0 = resp.r.data;
    check(resp.r.data === exp, {tag, "_DATA"});
    check(resp.r.last === explast, {tag, "_LAST"});
    check(resp.r.resp === axi_pkg::RESP_OKAY, {tag, "_RESP"});
    if (hold2) begin
      tick();
      check(resp.r_valid && resp.r.data === d0, {tag, "_HOLD1"});
      tick();
      check(resp.r_valid && resp.r.data === d0, {tag, "_HOLD2"});
    end
    req.r_ready = 1'b1;
    @(posedge clk);   // acceptance edge
    #1;
    req.r_ready = 1'b0;
  endtask

  initial begin
    req = '0;
    repeat (4) tick();
    rst_n = 1;
    repeat (2) tick();

    // ---- three single-beat reads in order ------------------------------
    send_ar(64'h0, 8'd0);
    recv_r(W0, 1'b1, 1'b1, "A0");   // hold r_ready low 2 cycles: held beat
    send_ar(64'h8, 8'd0);
    recv_r(W1, 1'b1, 1'b0, "A1");
    send_ar(64'h10, 8'd0);
    recv_r(W2, 1'b1, 1'b0, "A2");

    // ---- reverse order, back-to-back (next AR in the same task chain) --
    send_ar(64'h10, 8'd0);
    recv_r(W2, 1'b1, 1'b0, "B2");
    send_ar(64'h8, 8'd0);
    recv_r(W1, 1'b1, 1'b0, "B1");
    send_ar(64'h0, 8'd0);
    recv_r(W0, 1'b1, 1'b0, "B0");

    // ---- INCR len=1 burst at 0x0: both words, last only on beat 2 ------
    send_ar(64'h0, 8'd1);
    recv_r(W0, 1'b0, 1'b0, "C0");
    recv_r(W1, 1'b1, 1'b0, "C1");

    $display("HYP8_ROM_PASS checked=%0d", checked);
    $finish;
  end
endmodule
`endif // G6LC_HYP8_ROM_LEAF


// ---------------------------------------------------------------------------
// tb_g6lc_hyp8_pmp: actual pmp_data_if with the hyp8 config. The LSU data
// side runs DATA_VERDICT_STAGES=0 — the reference same-cycle contract
// (the staged variant mis-presented paddr/exception two cycles late,
// which the r9 diag showed as a wbuffer write with correct data/be and
// pa=0). Checks sample the outputs in the request cycle after a #1
// settle, with no clock edge between request and check.
// ---------------------------------------------------------------------------
module tb_g6lc_hyp8_pmp;
  logic clk = 0, rst_n = 0;
  int checked = 0;
  always #5 clk = ~clk;
  task tick(); @(posedge clk); #1; endtask
  task check(input logic cond, input string name);
    checked++;
    if (!cond) begin
      $display("FAIL %s", name);
      $fatal(1, "tb_g6lc_hyp8_pmp");
    end
  endtask

  function automatic config_pkg::g6lc_cfg_t configuration();
    return build_config_pkg::build_config(g6lc_config_pkg::g6lc_cfg);
  endfunction
  localparam config_pkg::g6lc_cfg_t C = configuration();
  localparam int NPE = C.NrPMPEntries;

  typedef `G6LC_EXCEPTION_T(C) exception_t;
  typedef struct packed {
    logic                    fetch_valid;
    logic [C.PLEN-1:0]       fetch_paddr;
    exception_t              fetch_exception;
  } icache_areq_t;

  icache_areq_t           areq_i, areq_o;
  logic [C.VLEN-1:0]      fet_vaddr;
  logic                   lsu_valid;
  logic [C.PLEN-1:0]      lsu_paddr, lsu_paddr_o;
  logic [C.VLEN-1:0]      lsu_vaddr;
  exception_t             lsu_ex_i, lsu_ex_o;
  logic                   lsu_is_store, lsu_valid_o;
  riscv::priv_lvl_t       priv_lvl, ld_st_priv;
  logic                   v_i, ld_st_v;
  riscv::pmpcfg_t [NPE-1:0] pmpcfg;
  logic [NPE-1:0][C.PLEN-3:0] pmpaddr;

  pmp_data_if #(
      .G6LCCfg             (C),
      .icache_areq_t       (icache_areq_t),
      .exception_t         (exception_t),
      .DATA_VERDICT_STAGES (0)
  ) dut (
      .clk_i               (clk),
      .rst_ni              (rst_n),
      .icache_areq_i       (areq_i),
      .icache_areq_o       (areq_o),
      .icache_fetch_vaddr_i(fet_vaddr),
      .lsu_valid_i         (lsu_valid),
      .lsu_paddr_i         (lsu_paddr),
      .lsu_vaddr_i         (lsu_vaddr),
      .lsu_exception_i     (lsu_ex_i),
      .lsu_is_store_i      (lsu_is_store),
      .lsu_valid_o         (lsu_valid_o),
      .lsu_paddr_o         (lsu_paddr_o),
      .lsu_exception_o     (lsu_ex_o),
      .priv_lvl_i          (priv_lvl),
      .v_i                 (v_i),
      .ld_st_priv_lvl_i    (ld_st_priv),
      .ld_st_v_i           (ld_st_v),
      .pmpcfg_i            (pmpcfg),
      .pmpaddr_i           (pmpaddr),
      .fet_pmpcfg_i        (pmpcfg),
      .fet_pmpaddr_i       (pmpaddr)
  );

  initial begin
    areq_i        = '0;
    fet_vaddr     = '0;
    lsu_valid     = 1'b0;
    lsu_paddr     = '0;
    lsu_vaddr     = '0;
    lsu_ex_i      = '0;
    lsu_is_store  = 1'b0;
    priv_lvl      = riscv::PRIV_LVL_M;
    ld_st_priv    = riscv::PRIV_LVL_M;
    v_i           = 1'b0;
    ld_st_v       = 1'b0;
    pmpcfg        = '{default: '0};
    pmpaddr       = '{default: '0};
    repeat (4) tick();
    rst_n = 1'b1;
    repeat (2) tick();

    // ---- A: all entries OFF, M-mode — pass-through, no exception ------
    lsu_valid    = 1'b1;
    lsu_is_store = 1'b1;
    lsu_paddr    = 64'h0000_0000_8000_1000;
    lsu_vaddr    = 64'h0000_0000_8000_1000;
    #1;
    check(lsu_valid_o === 1'b1, "A_VALID");
    check(lsu_paddr_o === 64'h0000_0000_8000_1000, "A_PADDR");
    check(lsu_ex_o.valid === 1'b0, "A_NOEX");

    // ---- B: entry0 NAPOT RW over 0x8000_0000/2 GiB, S-mode requester ---
    // NAPOT pmpaddr for base 0x8000_0000, size 2^31: 28 trailing ones
    // (pmp_entry derives size = trail_ones + 3 = 31):
    // (base >> 2) | (2^28 - 1) = 0x2000_0000 | 0x0FFF_FFFF.
    pmpcfg[0]  = '{locked: 1'b0, reserved: 2'b0,
                  addr_mode: riscv::NAPOT,
                  access_type: '{x: 1'b0, w: 1'b1, r: 1'b1}};
    pmpaddr[0] = 54'h2FFF_FFFF;
    ld_st_priv = riscv::PRIV_LVL_S;
    #1;

    // B1: store inside the RW region — no exception, paddr unchanged.
    lsu_valid    = 1'b1;
    lsu_is_store = 1'b1;
    lsu_paddr    = 64'h0000_0000_8000_1000;
    lsu_vaddr    = 64'h0000_0000_8000_1000;
    #1;
    check(lsu_valid_o === 1'b1, "B1_VALID");
    check(lsu_paddr_o === 64'h0000_0000_8000_1000, "B1_PADDR");
    check(lsu_ex_o.valid === 1'b0, "B1_NOEX");

    // B2: store outside any entry in S-mode — ST_ACCESS_FAULT same cycle.
    lsu_paddr = 64'h0000_0000_0000_1000;
    lsu_vaddr = 64'h0000_0000_0000_1000;
    #1;
    check(lsu_ex_o.valid === 1'b1, "B2_EXVALID");
    check(lsu_ex_o.cause === riscv::ST_ACCESS_FAULT, "B2_CAUSE");
    check(lsu_ex_o.tval === 64'h0000_0000_0000_1000, "B2_TVAL");

    // B3: load outside any entry in S-mode — LD_ACCESS_FAULT same cycle.
    lsu_is_store = 1'b0;
    #1;
    check(lsu_ex_o.valid === 1'b1, "B3_EXVALID");
    check(lsu_ex_o.cause === riscv::LD_ACCESS_FAULT, "B3_CAUSE");
    check(lsu_ex_o.tval === 64'h0000_0000_0000_1000, "B3_TVAL");

    // B4: no request — no exception regardless of the verdict.
    lsu_valid = 1'b0;
    lsu_ex_i  = '0;
    #1;
    check(lsu_valid_o === 1'b0, "B4_NOVALID");
    check(lsu_ex_o.valid === 1'b0, "B4_NOEX");

    // ---- F: fetch areq currency. if_req_q snapshots the MMU/PMA reply
    // every cycle, so it answers the PREVIOUS cycle's request. The
    // icache's READ_V W1-overlap accept chains request B into the cycle
    // right after request A's response registered; without the vaddr key
    // the standing A record presents valid for B — the observed I$ refill
    // one page down at a 4K crossing (vaq=0x80013000 -> AR=0x80012000).
    // areq_i plays the comb MMU/PMA reply for the request on the pins.
    fet_vaddr = 64'h0000_0000_8001_2ff8;
    areq_i    = '{fetch_valid: 1'b1,
                  fetch_paddr: 64'h0000_0000_8001_2ff8,
                  fetch_exception: '0};
    tick();
    // standing response for A with the request still A — presented.
    #1;
    check(areq_o.fetch_valid === 1'b1, "F_A_VALID");
    check(areq_o.fetch_paddr === 64'h0000_0000_8001_2ff8, "F_A_PADDR");
    // request moves across the 4K boundary while A's record still stands;
    // the comb reply for B is already on areq_i but must not present
    // until it registers.
    fet_vaddr = 64'h0000_0000_8001_3000;
    areq_i    = '{fetch_valid: 1'b1,
                  fetch_paddr: 64'h0000_0000_8001_3000,
                  fetch_exception: '0};
    #1;
    check(areq_o.fetch_valid === 1'b0, "F_B_STALE_SUPPRESSED");
    tick();
    #1;
    check(areq_o.fetch_valid === 1'b1, "F_B_VALID");
    check(areq_o.fetch_paddr === 64'h0000_0000_8001_3000, "F_B_PADDR");
    // same-page next window: a different fetch address is also stale —
    // identity is the full request vaddr, not just the page.
    fet_vaddr = 64'h0000_0000_8001_3010;
    areq_i    = '0;
    #1;
    check(areq_o.fetch_valid === 1'b0, "F_C_STALE_SUPPRESSED");
    tick();
    // fetch_req dropped during C: nothing registered — still invalid.
    #1;
    check(areq_o.fetch_valid === 1'b0, "F_C_NOREPLY");
    // retry of A: its response registers again and presents for A.
    fet_vaddr = 64'h0000_0000_8001_2ff8;
    areq_i    = '{fetch_valid: 1'b1,
                  fetch_paddr: 64'h0000_0000_8001_2ff8,
                  fetch_exception: '0};
    tick();
    #1;
    check(areq_o.fetch_valid === 1'b1, "F_REPLAY_VALID");
    check(areq_o.fetch_paddr === 64'h0000_0000_8001_2ff8, "F_REPLAY_PADDR");
    areq_i = '0;

    $display("HYP8_PMP_PASS checked=%0d", checked);
    $finish;
  end
endmodule

`ifdef G6LC_HYP8_DCACHE_LEAF
// ---------------------------------------------------------------------------
// tb_g6lc_hyp8_dcache: the actual wt_dcache (read ctrls, tag/data mem,
// wbuffer, missunit) behind a minimal single-outstanding memory model.
// Reproduces the h33 store->load forward pattern through the real request
// ports exactly as g6lc_core wires them: the store drives port NumPorts-1
// (the wbuffer port — the physical tag rides in address_tag, tag_valid
// never rises there), loads drive port 1 with the two-phase protocol
// (data_req + address_index until data_gnt, tag_valid + address_tag the
// cycle after).
//
// Distance d means the load's data_req is asserted d cycles after the
// cycle in which the store's data_gnt was observed (d=0: asserted
// combinationally during the gnt cycle itself). The HypCfg is Hyp8; with
// -DG6LC_HYP8_DCHX0 the identical bench builds with DcacheHitExtra=0 (the
// reference single-cycle read-ctrl arm) so both arms run the same cases.
//
// PASS token: HYP8_DCACHE_PASS
// ---------------------------------------------------------------------------
module tb_g6lc_hyp8_dcache;
  import g6lc_core_pkg::*;
  import wt_cache_pkg::*;

  localparam config_pkg::g6lc_cfg_t C =
      build_config_pkg::build_config(g6lc_config_pkg::g6lc_cfg);

`ifdef G6LC_HYP8_DCHX0
  localparam int unsigned DCHX = 0;
`else
  localparam int unsigned DCHX = 2;
`endif
  function automatic g6lc_hyp_pkg::g6lc_hyp_cfg_t leaf_hyp_cfg();
    g6lc_hyp_pkg::g6lc_hyp_cfg_t h = g6lc_hyp_pkg::Hyp8;
    h.DcacheHitExtra = DCHX;
    return h;
  endfunction
  localparam g6lc_hyp_pkg::g6lc_hyp_cfg_t HC = leaf_hyp_cfg();

  // As the LSU sees it: 0 = PTW (unused here), 1 = load unit, 2 = wbuffer.
  localparam int NumPorts = 3;
  localparam int P_LD = 1, P_ST = NumPorts - 1;

  // Same packed layout g6lc_core/wt_cache_subsystem hand wt_dcache.
  typedef struct packed {
    logic [C.DCACHE_INDEX_WIDTH-1:0] address_index;
    logic [C.DCACHE_TAG_WIDTH-1:0]   address_tag;
    logic [C.XLEN-1:0]               data_wdata;
    logic [C.DCACHE_USER_WIDTH-1:0]  data_wuser;
    logic                            data_req;
    logic                            data_we;
    logic [(C.XLEN/8)-1:0]           data_be;
    logic [1:0]                      data_size;
    logic [C.DcacheIdWidth-1:0]      data_id;
    logic                            kill_req;
    logic                            tag_valid;
    logic [7:0]                      cbo_op;
  } dcache_req_i_t;
  typedef struct packed {
    logic                                 data_gnt;
    logic                                 data_rvalid;
    logic [C.DcacheIdWidth-1:0]           data_rid;
    logic [C.XLEN-1:0]                    data_rdata;
    logic [C.DCACHE_USER_WIDTH-1:0]       data_ruser;
  } dcache_req_o_t;
  typedef struct packed {
    logic                                  vld;
    logic                                  all;
    logic [C.DCACHE_INDEX_WIDTH-1:0]       idx;
    logic [C.DCACHE_SET_ASSOC_WIDTH-1:0]   way;
  } dcache_inval_t;
  typedef struct packed {
    dcache_out_t                           rtype;
    logic [2:0]                            size;
    logic [C.DCACHE_SET_ASSOC_WIDTH-1:0]   way;
    logic [C.PLEN-1:0]                     paddr;
    logic [C.XLEN-1:0]                     data;
    logic [C.DCACHE_USER_WIDTH-1:0]        user;
    logic                                  nc;
    logic [C.MEM_TID_WIDTH-1:0]            tid;
    amo_t                                  amo_op;
  } dcache_req_t;
  typedef struct packed {
    dcache_in_t                            rtype;
    logic [C.DCACHE_LINE_WIDTH-1:0]        data;
    logic [C.DCACHE_USER_LINE_WIDTH-1:0]   user;
    dcache_inval_t                         inv;
    logic [C.MEM_TID_WIDTH-1:0]            tid;
  } dcache_rtrn_t;

  logic clk = 0, rst_n = 0;
  int checked = 0;
  always #5 clk = ~clk;
  task tick(); @(posedge clk); #1; endtask
  task check(input logic cond, input string name);
    checked++;
    if (!cond) begin
      $display("FAIL %s", name);
      $fatal(1, "tb_g6lc_hyp8_dcache");
    end
  endtask

  // --- minimal memory: one normal slot + one held-load-window slot -------
  // Ack one cycle after the request rises, return the verdict mem_lat
  // cycles after the ack. A store applies its bytes (repData64 replicates
  // sub-dword values into every lane, so lane 0 always carries the value);
  // a load's line is SNAPSHOTTED AT ACCEPT into pend_data so a refill can
  // legitimately return pre-store bytes when a store lands inside the
  // held window (the fixup-entry race the leaf exercises).
  //   mem_hold: requests accepted while it is set keep their return gated
  //             until mem_hold clears (pend_hold is captured at accept).
  //   Slot 2: while slot 1 is a held request, a second request may be
  //             accepted and completes normally -- this is how a store
  //             reaches memory (and creates a fixup entry) while a refill
  //             is in flight.
  localparam int MEM_LAT = 4;
  int unsigned  mem_lat = MEM_LAT;
  logic         mem_hold = 1'b0;
  logic         mem_req;
  logic         mem_ack = 1'b0;
  dcache_req_t  mem_d;
  logic         mem_rtrn_vld;
  dcache_rtrn_t mem_rtrn;
  // man_mode (case H): the model still accepts and ACKs memory requests
  // but its automatic returns are suppressed; the bench injects STORE_ACK
  // returns with man_vld/man_rtrn so the rtrn-gap interleave lands
  // cycle-exactly where the phantom-evict defect lived.
  logic         man_mode = 1'b0;
  logic         man_pend_v = 1'b0;
  dcache_req_t  man_pend = '0;
  logic         man_vld  = 1'b0;
  dcache_rtrn_t man_rtrn = '0;
  logic         mem_rtrn_vld_ff = 1'b0;
  dcache_rtrn_t mem_rtrn_ff = '0;
  always_comb begin
    mem_rtrn_vld = man_vld || (mem_rtrn_vld_ff && !man_mode);
    mem_rtrn     = man_vld ? man_rtrn : mem_rtrn_ff;
  end
  bit [7:0]     shadow[longint unsigned];
  localparam int LINE_B = C.DCACHE_LINE_WIDTH / 8;

  logic         mem_busy = 1'b0;
  int unsigned  mem_cnt = 0;
  dcache_req_t  pend = '0;
  logic         pend_hold = 1'b0;
  logic [C.DCACHE_LINE_WIDTH-1:0] pend_data = '0;
  logic         mem_busy2 = 1'b0;
  int unsigned  mem_cnt2 = 0;
  dcache_req_t  pend2 = '0;

  task automatic mem_capture(input dcache_req_t d);
    begin
      if (d.rtype == DCACHE_STORE_REQ)
        for (int i = 0; i < (1 << d.size); i++)
          shadow[longint'(d.paddr) + i] = d.data[i*8 +: 8];
    end
  endtask

  function automatic logic [C.DCACHE_LINE_WIDTH-1:0] mem_line(
      input logic [C.PLEN-1:0] paddr);
    logic [C.DCACHE_LINE_WIDTH-1:0] l;
    for (int i = 0; i < LINE_B; i++)
      l[i*8 +: 8] =
          shadow.exists(longint'(paddr & ~64'(LINE_B - 1)) + i)
          ? shadow[longint'(paddr & ~64'(LINE_B - 1)) + i] : 8'h0;
    return l;
  endfunction

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      mem_ack <= 1'b0; mem_rtrn_vld_ff <= 1'b0; mem_busy <= 1'b0; mem_cnt <= 0;
      mem_busy2 <= 1'b0; mem_cnt2 <= 0; pend_hold <= 1'b0;
      man_pend_v <= 1'b0; man_pend <= '0;
    end else if (man_mode) begin
      // ACK-only mode: one ACK per presented request descriptor. The
      // missunit keeps mem_req high while mem_d switches to the next
      // pending beat, so a plain level ACK double-accepts one beat (a
      // second ACK allocates a duplicate wbuffer tx slot) while an
      // edge detect on mem_req misses the follow-on descriptor.
      // No return is generated (the bench injects them); mem_capture
      // still applies store bytes so later refills carry them.
      mem_ack         <= mem_req && !(man_pend_v &&
                                       man_pend.paddr == mem_d.paddr &&
                                       man_pend.rtype == mem_d.rtype);
      mem_rtrn_vld_ff <= 1'b0;
      man_pend_v      <= mem_req;
      if (mem_req && !(man_pend_v &&
                       man_pend.paddr == mem_d.paddr &&
                       man_pend.rtype == mem_d.rtype))
        man_pend <= mem_d;
      if (mem_req) mem_capture(mem_d);
    end else begin
      mem_ack      <= 1'b0;
      mem_rtrn_vld_ff <= 1'b0;
      // ---- accepts ----------------------------------------------------
      if (mem_req && !mem_busy && !mem_rtrn_vld_ff) begin
        mem_ack   <= 1'b1;
        mem_busy  <= 1'b1;
        mem_cnt   <= mem_lat;
        pend      <= mem_d;
        pend_hold <= mem_hold;
        pend_data <= mem_line(mem_d.paddr);
        mem_capture(mem_d);
      end else if (mem_req && mem_busy && mem_cnt == 0 && pend_hold &&
                   mem_hold && !mem_busy2) begin
        // Slot 2: second request inside a held load's return window
        // (store reaching memory while a same-index refill is in flight).
        mem_ack   <= 1'b1;
        mem_busy2 <= 1'b1;
        mem_cnt2  <= mem_lat;
        pend2     <= mem_d;
        mem_capture(mem_d);
      end else if (mem_busy && mem_cnt != 0) begin
        mem_cnt <= mem_cnt - 1;
      end
      if (mem_busy2 && mem_cnt2 != 0) mem_cnt2 <= mem_cnt2 - 1;
      // ---- returns (single rtrn channel; slot 2 first) ------------------
      if (mem_busy2 && mem_cnt2 == 0) begin
        mem_busy2    <= 1'b0;
        mem_rtrn_ff     <= '0;
        mem_rtrn_ff.tid <= pend2.tid;
        mem_rtrn_ff.rtype <= (pend2.rtype == DCACHE_STORE_REQ)
                          ? DCACHE_STORE_ACK : DCACHE_LOAD_ACK;
        if (pend2.rtype != DCACHE_STORE_REQ)
          mem_rtrn_ff.data <= mem_line(pend2.paddr);
        mem_rtrn_vld_ff <= 1'b1;
      end else if (mem_busy && mem_cnt == 0 && !(pend_hold && mem_hold)) begin
        mem_busy     <= 1'b0;
        mem_rtrn_ff     <= '0;
        mem_rtrn_ff.tid <= pend.tid;
        if (pend.rtype == DCACHE_STORE_REQ) begin
          mem_rtrn_ff.rtype <= DCACHE_STORE_ACK;
        end else begin
          mem_rtrn_ff.rtype <= DCACHE_LOAD_ACK;
          mem_rtrn_ff.data  <= pend_data;
        end
        mem_rtrn_vld_ff <= 1'b1;
      end
    end
  end

  // --- DUT -------------------------------------------------------------------
  dcache_req_i_t [NumPorts-1:0] req_i;
  dcache_req_o_t [NumPorts-1:0] req_o;
  amo_req_t  amo_req = '0;
  amo_resp_t amo_resp;
  logic      wbuf_empty, wbuf_nni, dcache_miss;
  logic      pm_fx_wr, pm_fx_inv, pm_fx_full, pm_void_ack;
  int        fx_wr_pulses = 0, fx_inv_pulses = 0;

  wt_dcache #(
      .G6LCCfg        (C),
      .HypCfg         (HC),
      .dcache_req_i_t (dcache_req_i_t),
      .dcache_req_o_t (dcache_req_o_t),
      .dcache_req_t   (dcache_req_t),
      .dcache_rtrn_t  (dcache_rtrn_t),
      .NumPorts       (NumPorts),
      .RdAmoTxId      (1)
  ) dut (
      .clk_i            (clk),
      .rst_ni           (rst_n),
      .enable_i         (1'b1),
      .flush_i          (1'b0),
      .flush_ack_o      (),
      .miss_o           (dcache_miss),
      .wbuffer_empty_o  (wbuf_empty),
      .wbuffer_not_ni_o (wbuf_nni),
      .cmo_valid_o      (),
      .cmo_op_o         (),
      .cmo_addr_o       (),
      .cmo_ready_i      (1'b1),
      .cmo_done_i       (1'b0),
      .amo_req_i        (amo_req),
      .amo_resp_o       (amo_resp),
      .mbe_i            (1'b0),
      .req_ports_i      (req_i),
      .req_ports_o      (req_o),
      .miss_vld_bits_o  (),
      .pm_void_ack_o    (pm_void_ack),
      .pm_fixup_write_o (pm_fx_wr),
      .pm_fixup_inval_o (pm_fx_inv),
      .pm_fixup_full_o  (pm_fx_full),
      .mem_rtrn_vld_i   (mem_rtrn_vld),
      .mem_rtrn_i       (mem_rtrn),
      .mem_data_req_o   (mem_req),
      .mem_data_ack_i   (mem_ack),
      .mem_data_o       (mem_d)
  );

  // --- drivers ---------------------------------------------------------------
  // Continuous assigns from task-set registers: under Verilator --timing a
  // write to an unpacked-array input port made inside a timing task does not
  // propagate into the DUT, while a comb re-eval on a changed register does.
  logic [63:0] ld_paddr = '0;
  logic [1:0]  ld_size  = 2'b11;
  logic [C.DcacheIdWidth-1:0] ld_id = '0;
  logic        ld_req_v = 1'b0, ld_tv = 1'b0;
  logic [63:0] st_paddr = '0, st_wdata = '0;
  logic [7:0]  st_be    = '0;
  logic [1:0]  st_size  = 2'b11;
  logic        st_req_v = 1'b0;

  always_comb begin
    req_i = '0;
    req_i[P_LD].data_req      = ld_req_v;
    req_i[P_LD].address_index = ld_paddr[C.DCACHE_INDEX_WIDTH-1:0];
    req_i[P_LD].address_tag   =
        C.DCACHE_TAG_WIDTH'(ld_paddr >> C.DCACHE_INDEX_WIDTH);
    req_i[P_LD].data_size     = ld_size;
    req_i[P_LD].data_id       = ld_id;
    req_i[P_LD].tag_valid     = ld_tv;
    req_i[P_ST].data_req      = st_req_v || b2b_v;
    req_i[P_ST].data_we       = 1'b1;
    req_i[P_ST].address_index = b2b_v
        ? b2b_pa[b2b_idx][C.DCACHE_INDEX_WIDTH-1:0]
        : st_paddr[C.DCACHE_INDEX_WIDTH-1:0];
    req_i[P_ST].address_tag   = b2b_v
        ? C.DCACHE_TAG_WIDTH'(b2b_pa[b2b_idx] >> C.DCACHE_INDEX_WIDTH)
        : C.DCACHE_TAG_WIDTH'(st_paddr >> C.DCACHE_INDEX_WIDTH);
    req_i[P_ST].data_wdata    = b2b_v ? b2b_data[b2b_idx] : st_wdata;
    req_i[P_ST].data_be       = b2b_v ? b2b_be[b2b_idx]   : st_be;
    req_i[P_ST].data_size     = b2b_v ? b2b_size[b2b_idx] : st_size;
    req_i[P_ST].cbo_op        = 8'(CBO_NONE);
  end

  int st_count  = 0;

  // Store on the wbuffer port (registered data_gnt): hold data_req until a
  // grant is sampled at a posedge, then drop it for the next cycle. The
  // grant stays high for the whole accept cycle, so the task must not
  // sample it mid-cycle — a store asserted inside the previous grant cycle
  // would see the stale gnt and vanish before any edge (bench bug that
  // silently ate the C_COAL byte stores).
  logic st_start = 1'b0, st_busy = 1'b0, st_done = 1'b0;
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      st_busy  <= 1'b0;
      st_done  <= 1'b0;
      st_req_v <= 1'b0;
    end else begin
      st_done <= 1'b0;
      if (st_start && !st_busy) begin
        st_req_v <= 1'b1;
        st_busy  <= 1'b1;
      end else if (st_busy && req_o[P_ST].data_gnt) begin
        st_req_v <= 1'b0;
        st_busy  <= 1'b0;
        st_done  <= 1'b1;
      end
    end
  end

  // Back-to-back commit-queue producer (stb_drain head-advance semantics):
  // data_req stays asserted across the grant boundary and the request
  // fields switch to the queued store on the cycle the grant is observed.
  // This is the zero-gap re-presentation the W1 accepted-guard must
  // survive: the second request is NEW, not a re-assert of the granted
  // one (h33-r7 wedge: the second store's grant never arrived).
  logic        b2b_v    = 1'b0;
  int unsigned b2b_idx  = 0, b2b_cnt = 0;
  logic [63:0] b2b_pa   [0:3], b2b_data [0:3];
  logic [7:0]  b2b_be   [0:3];
  logic [1:0]  b2b_size [0:3];
  logic        b2b_done = 1'b0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      b2b_idx  <= 0;
      b2b_done <= 1'b0;
    end else if (!b2b_v) begin
      b2b_idx  <= 0;
      b2b_done <= 1'b0;
    end else if (req_o[P_ST].data_gnt) begin
      if (b2b_idx == b2b_cnt - 1) b2b_done <= 1'b1;
      else                        b2b_idx <= b2b_idx + 1;
    end
  end

  // Drive `cnt` queued stores through the wbuffer port with no
  // inter-request gap; b2b_done when the last one's grant is sampled.
  task automatic store_b2b(input logic [63:0] pa0, input logic [63:0] d0,
                           input logic [7:0] be0, input logic [1:0] sz0,
                           input logic [63:0] pa1, input logic [63:0] d1,
                           input logic [7:0] be1, input logic [1:0] sz1,
                           input string tag);
    int n;
    begin
      b2b_pa[0] = pa0; b2b_data[0] = d0; b2b_be[0] = be0; b2b_size[0] = sz0;
      b2b_pa[1] = pa1; b2b_data[1] = d1; b2b_be[1] = be1; b2b_size[1] = sz1;
      b2b_cnt = 2; b2b_v = 1'b1;
      tick();
      for (n = 0; n < 200 && !b2b_done; n++) tick();
      b2b_v = 1'b0;
      check(b2b_done, {tag, "_B2B_GNT"});
      st_count += 2;
    end
  endtask

  task automatic store(input logic [63:0] paddr, input logic [63:0] data,
                       input logic [7:0] be, input logic [1:0] size);
    int n;
    begin
      st_paddr = paddr; st_wdata = data; st_be = be; st_size = size;
      st_start = 1'b1;
      tick();
      st_start = 1'b0;
      for (n = 0; n < 2000 && !st_done; n++) tick();
      if (!st_done) begin
        check(1'b0, "ST_NO_GNT");
        return;
      end
      $display("  [stg] c=%0d paddr=%x be=%b data=%016x",
               mon_c, paddr, be, data);
      st_count++;
    end
  endtask

  // Load on the read port. The handshake is driven by a small registered
  // FSM (same shape as load_unit's WAIT_GNT -> TAG -> WAIT_RVALID): data_req
  // is held until a grant is sampled at an edge, dropped the following
  // cycle while tag_valid is presented, and the response captured at the
  // rvalid edge. Mid-cycle task pokes on the combinational grant moved the
  // request/tag phases off the FSM's boundaries once (phantom accept), so
  // all port transitions here are edge-synchronous.
  typedef enum logic [1:0] {LDS_IDLE, LDS_REQ, LDS_TAG, LDS_RSP} lds_e;
  lds_e ld_state = LDS_IDLE;
  logic        ld_start = 1'b0;
  logic        ld_done  = 1'b0;
  logic [63:0] ld_rdata = '0;
  logic [C.DcacheIdWidth-1:0] ld_rid = '0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ld_state <= LDS_IDLE;
      ld_req_v <= 1'b0;
      ld_tv    <= 1'b0;
      ld_done  <= 1'b0;
      ld_rdata <= '0;
      ld_rid   <= '0;
    end else begin
      unique case (ld_state)
        LDS_IDLE: if (ld_start) begin
                    ld_req_v <= 1'b1;
                    ld_done  <= 1'b0;
                    ld_state <= LDS_REQ;
                  end
        LDS_REQ:  if (req_o[P_LD].data_gnt) begin
                    ld_req_v <= 1'b0;
                    ld_tv    <= 1'b1;
                    ld_state <= LDS_TAG;
                  end
        LDS_TAG:  begin
                    ld_tv <= 1'b0;
                    if (req_o[P_LD].data_rvalid) begin
                      ld_rdata <= req_o[P_LD].data_rdata;
                      ld_rid   <= req_o[P_LD].data_rid;
                      ld_done  <= 1'b1;
                      ld_state <= LDS_IDLE;
                    end else begin
                      ld_state <= LDS_RSP;
                    end
                  end
        LDS_RSP:  if (req_o[P_LD].data_rvalid) begin
                    ld_rdata <= req_o[P_LD].data_rdata;
                    ld_rid   <= req_o[P_LD].data_rid;
                    ld_done  <= 1'b1;
                    ld_state <= LDS_IDLE;
                  end
        default: ld_state <= LDS_IDLE;
      endcase
    end
  end

  task automatic load(input logic [63:0] paddr, input logic [1:0] size,
                      input logic [C.DcacheIdWidth-1:0] id,
                      input logic [63:0] exp, input string tag);
    int n;
    begin
      ld_paddr = paddr; ld_size = size; ld_id = id;
      ld_start = 1'b1;
      tick();
      ld_start = 1'b0;
      for (n = 0; n < 2000 && !ld_done; n++) begin
        tick();
        if (n % 500 == 499)
          $display("  [waitrsp] %s n=%0d fst=%0d req=%b gnt=%b tv=%b rvld=%b rdreq=%b rdack=%b wrclv=%b mreq=%b mst=%0d wempty=%b",
                   tag, n, ld_state, ld_req_v, req_o[P_LD].data_gnt, ld_tv,
                   req_o[P_LD].data_rvalid, dut.rd_req[1], dut.rd_ack[1],
                   dut.wr_cl_vld, dut.miss_req[1],
                   dut.i_wt_dcache_missunit.state_q, wbuf_empty);
      end
      if (!ld_done) begin
        check(1'b0, {tag, "_NO_RSP"});
        ld_req_v = 1'b0;
        return;
      end
      if (ld_rdata !== exp)
        $display("  %s got=%016x exp=%016x", tag, ld_rdata, exp);
      else
        $display("  %s rdata=%016x", tag, ld_rdata);
      check(ld_rdata === exp, {tag, "_DATA"});
      check(ld_rid === id, {tag, "_RID"});
      tick();
    end
  endtask

  // Store at `paddr`, then a load of the same address whose data_req rises
  // `dist` cycles after the cycle the store's data_gnt was observed.
  task automatic store_load_dist(input logic [63:0] paddr,
                                 input logic [63:0] data, input int gap,
                                 input logic [C.DcacheIdWidth-1:0] id,
                                 input string tag);
    int n;
    begin
      store(paddr, data, 8'hff, 2'b11);
      repeat (gap) tick();
      load(paddr, 2'b11, id, data, tag);
    end
  endtask

  task automatic drain_stores(input string tag);
    int n;
    begin
      for (n = 0; n < 2000 && !wbuf_empty; n++) tick();
      check(wbuf_empty, {tag, "_DRAIN"});
    end
  endtask

  // ---- fixup-queue leaf probes (hierarchical, sim-only bench scope) -------
  function automatic logic fixup_busy();
    return !dut.i_wt_dcache_wbuffer.gen_fixup_queue.fixup_empty;
  endfunction
  function automatic int fixup_state();
    return int'(dut.i_wt_dcache_wbuffer.gen_fixup_queue.fixup_state_q);
  endfunction
  function automatic logic mshr_busy();
    return dut.i_wt_dcache_missunit.mshr_vld_q;
  endfunction

  int unsigned mshr_cnt = 0;
  int unsigned mshr_m0  = 0;
  logic        mshrv_d = 1'b0;
  always_ff @(posedge clk) begin
    if (rst_n && pm_fx_wr)  fx_wr_pulses  <= fx_wr_pulses + 1;
    if (rst_n && pm_fx_inv) fx_inv_pulses <= fx_inv_pulses + 1;
    mshrv_d <= mshr_busy();
    if (rst_n && !mshrv_d && mshr_busy()) mshr_cnt <= mshr_cnt + 1;
  end

  // Kick the load FSM without waiting for the response (the response may
  // be a held refill; completion is checked by load_wait afterwards).
  task automatic load_start(input logic [63:0] paddr,
                            input logic [C.DcacheIdWidth-1:0] id);
    begin
      ld_paddr = paddr; ld_size = 2'b11; ld_id = id;
      ld_start = 1'b1;
      tick();
      ld_start = 1'b0;
    end
  endtask

  task automatic load_wait(input logic [63:0] exp, input string tag);
    int n;
    begin
      for (n = 0; n < 2000 && !ld_done; n++) tick();
      if (!ld_done) begin
        check(1'b0, {tag, "_NO_RSP"});
        ld_req_v = 1'b0;
        return;
      end
      check(ld_rdata === exp, {tag, "_DATA"});
      check(ld_rid === ld_id, {tag, "_RID"});
      tick();
    end
  endtask

  // Wait for the store's memory accept (ack on a STORE_REQ).
  task automatic wait_store_memack(input string tag);
    int n;
    begin
      for (n = 0; n < 2000 &&
           !(mem_ack && pend.rtype == DCACHE_STORE_REQ); n++) tick();
      check(n < 2000, {tag, "_STORE_MEMACK"});
    end
  endtask

  // Wait for the memory accept of a specific store's drain request.  The
  // accepted descriptor is `pend`, captured at the ack edge.
  task automatic wait_store_memack_paddr(input logic [63:0] paddr,
                                         input string tag);
    int n;
    begin
      for (n = 0; n < 2000 &&
           !(mem_ack && pend.rtype == DCACHE_STORE_REQ &&
             pend.paddr == paddr[C.PLEN-1:0]); n++) tick();
      check(n < 2000, {tag, "_STORE_MEMACK_PADDR"});
    end
  endtask

  // Wait for the store's STORE_ACK return (the fixup push point).
  task automatic wait_store_rtrn(input string tag);
    int n;
    begin
      for (n = 0; n < 2000 &&
           !(mem_rtrn_vld && mem_rtrn.rtype == DCACHE_STORE_ACK); n++) tick();
      check(n < 2000, {tag, "_STORE_RTRN"});
    end
  endtask

  // Wait for the fixup push that follows a STORE_ACK -- the return legality
  // pipeline (rtrn snapshot -> leg_go -> leg_push_q) lands the entry a few
  // cycles after the ACK edge, so an immediate fixup_busy() sample is racy.
  task automatic wait_fixup_nonempty(input string tag);
    int n;
    begin
      for (n = 0; n < 2000 && !fixup_busy(); n++) tick();
      check(fixup_busy(), {tag, "_FIXUP_PUSH"});
    end
  endtask

  // Wait for the fixup queue to drain.
  task automatic wait_fixup_empty(input string tag);
    int n;
    begin
      for (n = 0; n < 2000 && fixup_busy(); n++) tick();
      check(!fixup_busy(), {tag, "_FIXUP_DRAIN"});
    end
  endtask

  // Wait for the missunit MSHR to go valid / idle.
  task automatic wait_mshr(input logic v, input string tag);
    int n;
    begin
      for (n = 0; n < 2000 && (mshr_busy() != v); n++) tick();
      check(mshr_busy() == v, {tag, "_MSHR"});
    end
  endtask

  // tid_of: the tx slot tracking `pa`'s word-aligned paddr (-1 when none).
  // Task (not function): this Verilator rejects a hierarchical-reference
  // function called inside a loop condition (V3Task "not underneath a
  // statement"), so callers invoke it as a statement.
  task automatic tid_of(input logic [63:0] pa, output int tid);
    begin
      tid = -1;
      for (int t = 0; t < C.DCACHE_MAX_TX; t++)
        if (dut.tx_vld[t] && dut.tx_paddr[t] == {pa[C.PLEN-1:3], 3'b000})
          tid = t;
    end
  endtask

  // man_return: one STORE_ACK return pulse through the comb mux -- pushed
  // into the wbuffer's return FIFO at the next posedge.
  task automatic man_return(input logic [C.MEM_TID_WIDTH-1:0] tid);
    begin
      man_rtrn       = '0;
      man_rtrn.rtype = DCACHE_STORE_ACK;
      man_rtrn.tid   = tid;
      man_vld        = 1'b1;
      tick();
      man_vld  = 1'b0;
      man_rtrn = '0;
    end
  endtask

  localparam logic [63:0] BASE = 64'h0000_0000_8000_1050;
  localparam logic [63:0] D0   = 64'h1122_3344_5566_7788;
  localparam logic [63:0] D1   = 64'ha5a5_c3c3_dead_beef;
  localparam logic [63:0] D2   = 64'hc001_d00d_5afe_f00d;

  // Fixup-leaf addresses: FIXA2/FIXB2 share a cache-line INDEX but carry
  // different tags (they differ above DCACHE_INDEX_WIDTH), so a refill of
  // FIXB2 holds an in-flight MSHR that matches FIXA2's fixup index
  // without resolving FIXA2's tag. FIXC is the apply-race line.
  localparam logic [63:0] FIXA = 64'h0000_0000_8000_2000;
  localparam logic [63:0] FIXA2 = 64'h0000_0000_8000_2040;
  localparam logic [63:0] FIXB2 =
      FIXA2 + (64'd1 << C.DCACHE_INDEX_WIDTH);
  localparam logic [63:0] FIXC = 64'h0000_0000_8000_2100;
  // F2's apply-race line: a fresh index no earlier scenario touches, so the
  // line is absent when the store's ACK pushes the fixup entry.
  localparam logic [63:0] FIXD = 64'h0000_0000_8000_2300;
  // Check-pipe blockers for F2: non-resident lines at fresh indices so
  // their drains never collide with the FIXD MSHR, and their own fixup
  // entries drop on the first tag miss.
  localparam logic [63:0] FIXBLK0 = 64'h0000_0000_8000_2400;
  localparam logic [63:0] FIXBLK1 = 64'h0000_0000_8000_2600;
  localparam logic [63:0] FIXBLK2 = 64'h0000_0000_8000_2800;
  localparam logic [63:0] FIXBLK3 = 64'h0000_0000_8000_2a00;
  // RTRN_GAP (case H) lines: fresh non-resident indices.
  localparam logic [63:0] GAPA = 64'h0000_0000_8000_2c00;
  localparam logic [63:0] GAPB = 64'h0000_0000_8000_2e00;
  int gap_tid_a = -1, gap_tid_b = -1, gap_n = 0;
  logic gap_ev = 1'b0;

  initial begin
    repeat (4) tick();
    rst_n = 1'b1;
    repeat (4) tick();

    // ---- A: same-word store->load forward at distances 0..4 (h33 sc1) ---
    for (int d = 0; d <= 4; d++) begin
      store_load_dist(BASE + 64'(d) * 8, D0, d, 3'(d), $sformatf("D%0d", d));
    end
    drain_stores("A");

    // ---- B: byte merge — dword store, sub-word loads (h33 sc2) ----------
    // bytes at BASE+0x40 (LE): ef be ad de c3 c3 a5 a5
    store(BASE + 64'h40, D1, 8'hff, 2'b11);
    // lbu @+0 -> byte 0 = 0xef; the port returns the enclosing dword.
    load(BASE + 64'h40, 2'b00, 3'd5, D1, "B_LB0");
    // lbu @+7 -> byte 7 = 0xa5, same dword.
    load(BASE + 64'h47, 2'b00, 3'd6, D1, "B_LB7");
    // lhu @+4 -> 0xc3c3, same dword.
    load(BASE + 64'h44, 2'b01, 3'd7, D1, "B_LH4");
    // sb 0x55 over byte 1, then a dword load must show the merge.
    store(BASE + 64'h41, 64'h0000_0000_0000_5500, 8'h02, 2'b00);
    load(BASE + 64'h40, 2'b11, 3'd0, 64'ha5a5_c3c3_dead_55ef, "B_MERGE");
    drain_stores("B");

    // ---- C: coalesce — sd, sb+1, sb+7 back-to-back, then ld (h33 sc3) ---
    store(BASE + 64'h60, 64'h1111, 8'hff, 2'b11);
    store(BASE + 64'h61, 64'h2200, 8'h02, 2'b00);
    store(BASE + 64'h67, 64'h3300_0000_0000_0000, 8'h80, 2'b00);
    load(BASE + 64'h60, 2'b11, 3'd1, 64'h3300_0000_0000_2211, "C_COAL");
    drain_stores("C");

    // ---- D: fixup entry for a non-resident line, NO refill ever ---------
    // The store drains to memory (ACK -> fixup push); the first tag-check
    // miss with no same-index MSHR must retire the entry through the
    // dead-entry path -- no array write, no invalidation, no PMU pulse.
    // The bytes are already in memory, so a later load refills them.
    store(FIXA, D0, 8'hff, 2'b11);
    wait_store_memack("D");
    wait_store_rtrn("D");           // STORE_ACK return -> fixup push
    wait_fixup_nonempty("D");       // push lands a few cycles after the ACK
    wait_fixup_empty("D");          // tag miss + no MSHR -> drop
    check(fx_wr_pulses == 0 && fx_inv_pulses == 0, "D_NO_PMU_PULSE");
    load(FIXA, 2'b11, 3'd2, D0, "D_LATER_REFILL");

    // ---- E: fixup waits on a same-index in-flight refill, then drops ----
    // Held load to FIXB (same index as FIXA, different tag): the store's
    // write reaches memory inside the held window (different line, so no
    // rdwr collision) and creates a fixup entry.  Every tag check during
    // the hold sees the same-index MSHR and retries; after release the
    // refilled tag is B's (not A's), the MSHR frees, and the entry drops.
    mem_hold = 1'b1;
    for (int i = 0; i < 8; i++)
      shadow[longint'(FIXB2) + i] = D2[i*8 +: 8];
    load_start(FIXB2, 3'd3);
    wait_mshr(1'b1, "E");
    store(FIXA2, D1, 8'hff, 2'b11);  // same index I, different line
    wait_store_rtrn("E");            // fixup entry created during the hold
    wait_fixup_nonempty("E");        // push lands after the ACK
    for (int w = 0; w < 40; w++) begin
      tick();
      check(fixup_busy(), "E_FIXUP_DROPPED_EARLY");
    end
    mem_hold = 1'b0;
    load_wait(D2, "E_HELD_LD");      // FIXB2's refill returns its snapshot
    wait_mshr(1'b0, "E");
    wait_fixup_empty("E");           // tag still misses -> drop
    load(FIXA2, 2'b11, 3'd2, D1, "E_LATER_REFILL");

    // ---- F: held same-line refill; store resolves through the L1 arm ----
    // Held load to FIXC snapshots the line BEFORE the store (pend_data at
    // accept); the same-line store is collision-masked at the missunit
    // while the refill is in flight, so its drain -- and hence its
    // STORE_ACK -- cannot arrive until the MSHR frees.  The refill's
    // wr_cl_vld then re-arms the wbuffer entry's tag check (inval clears
    // checked), the re-check completes as a tag HIT on the just-installed
    // line, and the ACK takes the leg_l1 path: the deferred bytes are
    // written into the array directly with no fixup entry at all.  The
    // fixup path stays available for the other ordering (re-check late:
    // an unchecked push that retires on the hit), so the checks below
    // only require the bytes to land and the queue to stay drained.
    for (int i = 0; i < 8; i++)
      shadow[longint'(FIXC) + i] = D2[i*8 +: 8];
    mem_hold = 1'b1;
    load_start(FIXC, 3'd4);
    wait_mshr(1'b1, "F");
    store(FIXC, D0, 8'hff, 2'b11);   // same line -> rdwr collision masked
    repeat (16) tick();
    check(!fixup_busy(), "F_FIXUP_EARLY");
    mem_hold = 1'b0;
    // The refill returns the pre-store snapshot (pend_data), but the
    // response byte-merges the still-pending same-word wbuffer entry over
    // it -- the same overlay the DcacheHitExtra==0 live path produces at the
    // wr_cl cycle. The load completes after the store entered the buffer,
    // so the coherent answer is the store's data, not the snapshot.
    load_wait(D0, "F_HELD_LD");
    wait_mshr(1'b0, "F");
    wait_store_rtrn("F");            // store drains; leg_l1 writes the array
    wait_fixup_empty("F");           // no entry expected; tolerate a late push
    drain_stores("F");               // entry evicted -> array write completed
    load(FIXC, 2'b11, 3'd5, D0, "F_POST_HIT");

    // ---- F2: fixup pushed line-absent, refill arrives before its check ---
    // The store drains and ACKs while the FIXD line is absent -> fixup
    // push.  A same-line load to the OTHER word (FIXD+8; the wbuffer hit
    // compare is word-granular) misses and takes an MSHR for the same
    // cache-line index.  Four blocker stores issued after the ACK keep
    // |tocheck and the shared check pipe loaded (wbuffer checks outrank
    // the fixup probe on the rd port) so the pushed entry's first tag read
    // happens only after the refill installs the line.  Both orderings are
    // covered: a slot-1 (held) accept leaves the MSHR in flight while the
    // fixup retries the same-index check, and a slot-2 (unheld) accept
    // returns the refill early so the check HITs the resident line --
    // either way FIXUP_RETIRE writes the store bytes (pm_fixup_write) and
    // a later load reads them back.  mshr_cnt is a cumulative allocation
    // counter, robust to the MSHR completing before a wait observes it.
    mshr_m0 = mshr_cnt;
    store(FIXD, D2, 8'hff, 2'b11);
    wait_store_memack_paddr(FIXD, "F2");
    for (int i = 0; i < 8; i++)
      shadow[longint'(FIXD + 8) + i] = 8'hab;
    mem_hold = 1'b1;                 // hold a slot-1 load return; store already acked
    wait_store_rtrn("F2");           // STORE_ACK -> fixup push (line absent)
    load_start(FIXD + 8, 3'd6);      // same line, other word: genuine miss
    store(FIXBLK0, D0, 8'hff, 2'b11);
    store(FIXBLK1, D1, 8'hff, 2'b11);
    store(FIXBLK2, D2, 8'hff, 2'b11);
    store(FIXBLK3, D0, 8'hff, 2'b11);
    wait_fixup_nonempty("F2");       // FIXD entry pushed (checked-miss ACK leg)
    mem_hold = 1'b0;
    load_wait(64'habab_abab_abab_abab, "F2_HELD_LD");  // refill word 1 = 0xab..
    drain_stores("F2");              // every store evicted -> every leg eval ran
    wait_fixup_empty("F2");          // FIXD: tag hit -> RETIRE; blockers: drop
    check(mshr_cnt > mshr_m0, "F2_MSHR");
    check(fx_wr_pulses >= 1, "F2_FIXUP_WRITE");
    load(FIXD, 2'b11, 3'd7, D2, "F2_POST_HIT");

    // ---- G: zero-gap back-to-back stores (stb_drain head advance) -------
    // The store buffer pops a commit-queue head on data_gnt and presents
    // the next head's request on the immediately following cycle --
    // data_req never drops between the two requests. The W1
    // accepted-guard must re-arm for the NEW request; held for the whole
    // data_req assertion it swallowed the second store forever (h33-r7:
    // commit-queue head pa091 waited on a gnt that could never come and
    // the parked same-lane load stayed interlocked behind it). The pair
    // below mirrors that incident: a dword store at +0xb0 coalesced by a
    // byte store at +0xb1, both granted, drained, and load-verified.
    store_b2b(BASE + 64'hb0, D0, 8'hff, 2'b11,
              BASE + 64'hb1, 64'h5a00, 8'h02, 2'b00, "G");
    drain_stores("G");
    wait_fixup_empty("G");
    // D0 with byte 1 replaced by the coalesced byte store's value.
    load(BASE + 64'hb0, 2'b11, 3'd0,
         (D0 & ~64'hff00) | 64'h5a00, "G_COAL_B2B");

    // ---- H: rtrn-gap — second STORE_ACK pushed inside the evict gap -----
    // The parked-load wedge (h33-r7, wtx ledger): return A's evict pops
    // the rtrn FIFO head while rtrn_snap_v_q is still valid for A (it
    // clears only at the evict edge).  An unmasked legality register
    // re-arms go/fire/l1 on that dying snapshot and a phantom
    // leg_push_q/drop_q two cycles later pops the NEXT return's FIFO
    // entry under A's stale id -- and the evict-priority branch blocks
    // that return's own snapshot re-capture, so its tx_stat slot is never
    // freed (tx_rdwr_collision parks every later same-line access), its
    // buffered word never leaves, and wbuffer empty never rises.  The
    // contract: a return is released only by the evict its own snapshot
    // armed -- exactly one pop per pushed id.
    //   man_mode ACKs the two drains but suppresses auto returns; B's
    //   STORE_ACK is injected on the cycle after A's evict -- the exact
    //   gap the dying snapshot hits.
    repeat (MEM_LAT + 10) tick();
    man_mode = 1'b1;
    store(GAPA, D0, 8'hff, 2'b11);
    store(GAPB, D1, 8'hff, 2'b11);
    for (gap_n = 0; gap_n < 2000; gap_n++) begin
      tid_of(GAPA, gap_tid_a); tid_of(GAPB, gap_tid_b);
      if (gap_tid_a >= 0 && gap_tid_b >= 0) gap_n = 2000;
      else tick();
    end
    check(gap_tid_a >= 0 && gap_tid_b >= 0 && gap_tid_a != gap_tid_b,
          "H_TWO_TX");
    // A's return walks push -> snapshot -> leg -> evict.
    man_return(C.MEM_TID_WIDTH'(gap_tid_a));
    gap_ev = 1'b0;
    for (gap_n = 0; gap_n < 200 && !gap_ev; gap_n++) begin
      gap_ev = dut.i_wt_dcache_wbuffer.evict;
      if (!gap_ev) tick();
    end
    check(gap_ev, "H_A_EVICT");
    tick();                          // close A's evict -> the gap cycle
    man_return(C.MEM_TID_WIDTH'(gap_tid_b));   // B pushed inside the gap
    repeat (60) tick();
    if (dut.tx_vld != '0) begin
      for (int t = 0; t < C.DCACHE_MAX_TX; t++)
        if (dut.tx_vld[t])
          $display("  [H] stuck tx slot %0d paddr=%x", t, dut.tx_paddr[t]);
      $display("  [H] snapv=%b rid=%0d empty=%b wempty=%b",
               dut.i_wt_dcache_wbuffer.rtrn_snap_v_q,
               dut.i_wt_dcache_wbuffer.rtrn_id,
               dut.i_wt_dcache_wbuffer.rtrn_empty, wbuf_empty);
    end
    check(dut.tx_vld == '0, "H_ALL_TX_FREED");
    check(wbuf_empty, "H_WBUF_DRAINED");
    wait_fixup_empty("H");
    man_mode = 1'b0;
    load(GAPB, 2'b11, 3'd1, D1, "H_POST_LD");

    // ---- every store drained out of the wbuffer -------------------------
    // The store port completes at data_gnt (wbuffer data_rvalid is '0 by
    // design, upstream included), so count grants, not rvalids.
    repeat (MEM_LAT + 20) tick();
    check(wbuf_empty, "ST_DRAIN_FINAL");
    check(!fixup_busy(), "FIXUP_DRAIN_FINAL");
    check(st_count == 22, "ST_COUNT");

    $display("HYP8_DCACHE_PASS checked=%0d dchx=%0d stores=%0d",
             checked, DCHX, st_count);
    $finish;
  end

  // Memory-side monitor: one line per request handshake / return.
  int mon_c = 0;
  always_ff @(posedge clk) begin
    mon_c <= mon_c + 1;
    if (rst_n && (mem_req || mem_ack || mem_rtrn_vld))
      $display("  [mon] c=%0d req=%b ack=%b rtrn=%b rt=%0d rrt=%0d paddr=%x data=%016x size=%0d wempty=%b",
               mon_c, mem_req, mem_ack, mem_rtrn_vld, mem_d.rtype,
               mem_rtrn.rtype, mem_d.paddr, mem_d.data, mem_d.size,
               wbuf_empty);
    if (rst_n && mem_rtrn_vld && mem_rtrn.rtype == DCACHE_LOAD_ACK)
      $display("  [msh] c=%0d load-rtrn paddr=%x pend_data=%032x sh0=%02x sh1=%02x sh8=%02x",
               mon_c, pend.paddr, pend_data,
               shadow.exists(longint'(64'h80001090)) ? shadow[64'h80001090] : 8'hee,
               shadow.exists(longint'(64'h80001091)) ? shadow[64'h80001091] : 8'hee,
               shadow.exists(longint'(64'h80001098)) ? shadow[64'h80001098] : 8'hee);
  end

  // Event trace of the load-port handshake + miss/wr_cl plumbing: one line
  // whenever any bit moves.
  logic [17:0] dbg_last = '0;
  logic [($bits(dut.wbuffer_data))-1:0] dbg_wb_last = '0;
  always_ff @(posedge clk) begin
    logic [17:0] cur;
    cur = {st_req_v, req_o[P_ST].data_gnt,
           ld_req_v, req_o[P_LD].data_gnt, ld_tv, req_o[P_LD].data_rvalid,
           dut.rd_req[1], dut.rd_ack[1], dut.wr_cl_vld,
           dut.miss_req[1], dut.miss_ack[1], dut.miss_replay[1],
           dut.miss_rtrn_vld[1], dut.i_wt_dcache_missunit.mshr_vld_q,
           3'(dut.i_wt_dcache_missunit.state_q), wbuf_empty};

    if (rst_n && (cur != dbg_last || dut.wbuffer_data !== dbg_wb_last)) begin
      $display("  [evt] c=%0d sreq=%b sgnt=%b req=%b gnt=%b tv=%b rvalid=%b rdreq=%b rdack=%b wrclv=%b mreq=%b mack=%b mrpl=%b mrtrn=%b mshrv=%b mst=%0d wempty=%b",
               mon_c, cur[17], cur[16], cur[15], cur[14], cur[13], cur[12],
               cur[11], cur[10],
               cur[9], cur[8], cur[7], cur[6], cur[5], cur[4], cur[3:1],
               cur[0]);
      // The comb *_c / wbuffer_rdata / rdata nets inside wt_dcache_mem are
      // optimizer-folded onto the output ports (under DcacheHitExtra==0 they
      // fold outright; under ==2 whether the names survive elaboration is
      // not guaranteed — dchx2-r46 lost wbuffer_rdata to the same fold), so
      // those fields read the port-level equivalents; fields with no port
      // equivalent print 0. Under DcacheHitExtra==2 the port readouts are
      // the T2-registered values, 2 cycles later than the comb internals.
      $display("  [mem] c=%0d woh=%b wbe=%b wrdata=%016x rdata=%016x rdhitc=%b vldc=%b rddata=%016x fwd=%b rdrfl=%b rflw=%016x bidx=%x boff=%x cmpen=%b cmpa=%x",
               mon_c, dut.i_wt_dcache_mem.wbuffer_hit_oh,
               dut.i_wt_dcache_mem.wbuffer_be,
               '0, '0,
               dut.rd_hit_oh[1],
               dut.rd_vld_bits[1],
               dut.rd_data[1],
               dut.wbuffer_fwd_hit,
               dut.wr_cl_vld,
               '0,
               dut.i_wt_dcache_mem.bank_idx_q,
               dut.i_wt_dcache_mem.bank_off_q,
               dut.i_wt_dcache_mem.cmp_en_q,
               '0);
      for (int i = 0; i <= C.WtDcacheWbufDepth+1; i++)
        if (|dut.wbuffer_data[i].valid)
          $display("  [wbx] c=%0d i=%0d wtag=%x v=%b d=%b tx=%b data=%016x",
                   mon_c, i, dut.wbuffer_data[i].wtag,
                   dut.wbuffer_data[i].valid, dut.wbuffer_data[i].dirty,
                   dut.wbuffer_data[i].txblock, dut.wbuffer_data[i].data);
    end
    dbg_last    <= cur;
    dbg_wb_last <= dut.wbuffer_data;
  end

  // Fixup FSM / queue occupancy trace: one line on every state or depth
  // change (state: 0=PEND 1=CHECK 2=RETIRE).
  logic [7:0] fx_last = '0;
  always_ff @(posedge clk) begin
    logic [7:0] curf;
    curf = {2'(fixup_state()), fixup_busy(),
            4'(dut.i_wt_dcache_wbuffer.gen_fixup_queue.fixup_cnt),
            mshr_busy()};
    if (rst_n && curf != fx_last)
      $display("  [fx] c=%0d st=%0d busy=%b cnt=%0d mshrv=%b",
               mon_c, curf[7:6], curf[5], curf[4:1], curf[0]);
    fx_last <= curf;
  end

  // Return-channel trace: every FIFO push, snapshot capture, and evict
  // with the snapshot id/tx state at that edge.
  always_ff @(posedge clk) begin
    if (rst_n && dut.miss_rtrn_vld[2])
      $display("  [rtrn] c=%0d push id=%0d", mon_c, dut.miss_rtrn_id);
    if (rst_n && dut.i_wt_dcache_wbuffer.evict)
      $display("  [rtrn] c=%0d evict sid=%0d stx.vld=%b stx.ptr=%0d swb.vld=%b push=%b drop=%b go=%b fire=%b l1=%b fhold=%b",
               mon_c, dut.i_wt_dcache_wbuffer.rtrn_snap_id_q,
               dut.i_wt_dcache_wbuffer.rtrn_snap_tx_q.vld,
               dut.i_wt_dcache_wbuffer.rtrn_snap_ptr_q,
               |dut.i_wt_dcache_wbuffer.rtrn_snap_wb_q.valid,
               dut.i_wt_dcache_wbuffer.leg_push_q,
               dut.i_wt_dcache_wbuffer.drop_q,
               dut.i_wt_dcache_wbuffer.leg_go_q,
               dut.i_wt_dcache_wbuffer.leg_fire_q,
               dut.i_wt_dcache_wbuffer.leg_l1_q,
               dut.i_wt_dcache_wbuffer.fixup_hold);
    if (rst_n && !dut.i_wt_dcache_wbuffer.rtrn_snap_v_q &&
        !dut.i_wt_dcache_wbuffer.rtrn_empty)
      $display("  [rtrn] c=%0d snap<- head=%0d", mon_c,
               dut.i_wt_dcache_wbuffer.rtrn_id_raw);
  end

  // Per-cycle read-port arb/capture trace while a load is in flight.
  // Same fold caveat as [mem]: comb _d internals are not guaranteed to
  // survive elaboration; the registered fields keep their direct probes.
  always_ff @(posedge clk) begin
    if (rst_n && ld_state != LDS_IDLE)
      $display("  [arb] c=%0d rdr=%b rda=%b rdix1=%x rdix2=%x rdtag1=%x sel=%x selq=%x acked=%b cmpend=%b bidxd=%x bidxq=%x boffq=%x",
               mon_c, dut.rd_req, dut.rd_ack, dut.rd_idx[1], dut.rd_idx[2],
               dut.rd_tag[1], '0,
               dut.i_wt_dcache_mem.vld_sel_q,
               '0, '0, '0,
               dut.i_wt_dcache_mem.bank_idx_q,
               dut.i_wt_dcache_mem.bank_off_q);
  end

  int wdog = 0;
  always_ff @(posedge clk) begin
    wdog <= wdog + 1;
    if (wdog > 200000) $fatal(1, "HYP8_DCACHE_TIMEOUT");
  end
endmodule
`endif // G6LC_HYP8_DCACHE_LEAF


`ifdef G6LC_HYP8_LSQ_LEAF
// ---------------------------------------------------------------------------
// tb_g6lc_hyp8_lsq: the actual g6lc_lsq (event staging, STL/vio CAM banks,
// reduce, verdict, slot arrays, release masks) driven on its own port
// surface.  Directed memory-order cases:
//   G1  load takes its verdict while an older same-word store is still
//       address-unresolved (unres-tracked, dwait empty) -> the store's
//       later first address-resolution MUST name the load
//       (mem_violation + replay, load's own verdict never violates).
//   G2a store address resolved at the verdict, data late -> the load
//       waits on dwait, ld_checked rises only after the data event, and
//       neither the data event, the commit event, nor the phys event
//       produces a violation.
//   G2b store resolved + data present at the verdict -> stl_forward with
//       the store's data; later data/commit/phys events -> no violation.
//
// Verdict/ violation outputs are registered (E->C->R->V), so each phase
// allows the pipe latency before checking.  Inputs are packed vectors
// driven through continuous assigns from task-set registers (Verilator
// --timing does not propagate mid-task writes into unpacked-array input
// ports).
//
// PASS token: HYP8_LSQ_PASS
// ---------------------------------------------------------------------------
module tb_g6lc_hyp8_lsq;
  import g6lc_core_pkg::*;

  localparam config_pkg::g6lc_cfg_t C =
      build_config_pkg::build_config(g6lc_config_pkg::g6lc_cfg);
  localparam g6lc_hyp_pkg::g6lc_hyp_cfg_t HC = g6lc_hyp_pkg::Hyp8;

  localparam int unsigned IDW = C.TRANS_ID_BITS;
  localparam int unsigned NSB = C.NR_SB_ENTRIES;
  localparam int unsigned NWB = C.NrWbPorts;
  localparam int unsigned NCP = C.NrCommitPorts;
  localparam int unsigned NLD_S = 8, NST_S = 8, NA = 2, NU = 2;

  logic clk = 0, rst_n = 0;
  int checked = 0;
  int unsigned cyc = 0;
  always #5 clk = ~clk;
  task tick(); @(posedge clk); #1; cyc++; endtask
  task check(input logic cond, input string name);
    checked++;
    if (!cond) begin
      $display("FAIL %s", name);
      $fatal(1, "tb_g6lc_hyp8_lsq");
    end
  endtask

  // --- drive registers (task-set; assembled below) -------------------------
  logic [NA-1:0]              drv_ld_alloc = '0, drv_st_alloc = '0;
  logic [NA-1:0][IDW-1:0]     drv_alloc_id = '0;
  logic [NA-1:0][C.VLEN-1:0]  drv_alloc_pc = '0;
  logic [NU-1:0]              drv_addr_v = '0, drv_addr_is_st = '0;
  logic [NU-1:0][IDW-1:0]     drv_addr_id = '0;
  logic [NU-1:0][C.PLEN-1:0]  drv_addr = '0;
  logic [NU-1:0][1:0]         drv_addr_size = '0;
  logic [NU-1:0]              drv_sdata_v = '0;
  logic [NU-1:0][IDW-1:0]     drv_sdata_id = '0;
  logic [NU-1:0][C.XLEN-1:0]  drv_sdata = '0;
  logic                       drv_ldq = 1'b0;
  logic [C.PLEN-1:0]          drv_ldq_addr = '0;
  logic [1:0]                 drv_ldq_size = '0;
  logic [IDW-1:0]             drv_ldq_id = '0;
  logic [NWB-1:0]             drv_cpl_v = '0, drv_cpl_is_st = '0;
  logic [NWB-1:0][IDW-1:0]    drv_cpl_id = '0;
  logic [NCP-1:0]             drv_cst = '0, drv_cld = '0;
  logic [NCP-1:0][IDW-1:0]    drv_cmt_id = '0;
  logic [1:0]                 drv_phys_v = '0;
  logic [1:0][C.PLEN-1:0]     drv_phys_addr = '0;
  logic [1:0][IDW-1:0]        drv_phys_id = '0;
  logic [1:0][1:0]            drv_phys_size = '0;
  logic                       drv_flush = 1'b0;
  logic [NSB-1:0]             drv_sb_live = '0, drv_canc = '0;
  logic [IDW-1:0]             drv_cptr = '0;

  // --- DUT ------------------------------------------------------------------
  logic                       lsq_ld_full, lsq_st_full;
  logic [$clog2(NLD_S+1)-1:0] lsq_ld_free;
  logic [$clog2(NST_S+1)-1:0] lsq_st_free;
  logic [NSB-1:0]             lsq_st_live, lsq_st_unres;
  logic [C.NrHarts-1:0][NSB-1:0] lsq_st_hart;
  logic                       lsq_store_pend, lsq_stl_fwd, lsq_stl_stall;
  logic [C.XLEN-1:0]          lsq_stl_data;
  logic                       lsq_busy, lsq_vio, lsq_replay;
  logic [IDW-1:0]             lsq_vio_id, lsq_replay_id;
  logic [C.VLEN-1:0]          lsq_vio_pc;
  logic [NSB-1:0]             lsq_phys_pend, lsq_phys_replay, lsq_checked;

  g6lc_lsq #(
      .G6LCCfg   (C),
      .HypCfg    (HC),
      .LD_ENTRIES(NLD_S),
      .ST_ENTRIES(NST_S),
      .NR_ALLOC  (NA),
      .NR_UPDATE (NU)
  ) dut (
      .clk_i              (clk),
      .rst_ni             (rst_n),
      .flush_i            (drv_flush),
      .cancelled_mask_i   (drv_canc),
      .sb_live_i          (drv_sb_live),
      .ld_alloc_i         (drv_ld_alloc),
      .st_alloc_i         (drv_st_alloc),
      .alloc_id_i         (drv_alloc_id),
      .alloc_hart_i       ('0),
      .alloc_pc_i         (drv_alloc_pc),
      .ld_full_o          (lsq_ld_full),
      .st_full_o          (lsq_st_full),
      .ld_free_o          (lsq_ld_free),
      .st_free_o          (lsq_st_free),
      .addr_valid_i       (drv_addr_v),
      .addr_id_i          (drv_addr_id),
      .addr_i             (drv_addr),
      .addr_is_st_i       (drv_addr_is_st),
      .addr_size_i        (drv_addr_size),
      .st_data_valid_i    (drv_sdata_v),
      .st_data_id_i       (drv_sdata_id),
      .st_data_i          (drv_sdata),
      .complete_valid_i   (drv_cpl_v),
      .complete_id_i      (drv_cpl_id),
      .complete_is_st_i   (drv_cpl_is_st),
      .commit_st_i        (drv_cst),
      .commit_id_i        (drv_cmt_id),
      .commit_ptr_i       (drv_cptr),
      .ld_query_i         (drv_ldq),
      .ld_query_addr_i    (drv_ldq_addr),
      .ld_query_size_i    (drv_ldq_size),
      .ld_query_id_i      (drv_ldq_id),
      .ld_query_hart_i    ('0),
      .st_live_mask_o     (lsq_st_live),
      .st_unresolved_mask_o(lsq_st_unres),
      .st_hart_mask_o     (lsq_st_hart),
      .store_pending_o    (lsq_store_pend),
      .stl_forward_o      (lsq_stl_fwd),
      .stl_data_o         (lsq_stl_data),
      .stl_stall_o        (lsq_stl_stall),
      .lsq_busy_o         (lsq_busy),
      .mem_violation_o    (lsq_vio),
      .mem_violation_id_o (lsq_vio_id),
      .mem_violation_pc_o (lsq_vio_pc),
      .phys_valid_i       (drv_phys_v),
      .phys_addr_i        (drv_phys_addr),
      .phys_id_i          (drv_phys_id),
      .phys_hart_i        ('0),
      .phys_size_i        (drv_phys_size),
      .commit_ld_i        (drv_cld),
      .mod_valid_i        ('0),
      .mod_addr_i         ('0),
      .phys_pending_o     (lsq_phys_pend),
      .phys_replay_o      (lsq_phys_replay),
      .ld_checked_o       (lsq_checked),
      .replay_valid_o     (lsq_replay),
      .replay_tid_o       (lsq_replay_id)
  );

  // --- event capture ---------------------------------------------------------
  int vio_cnt = 0, rpl_cnt = 0;
  int vio_base = 0, rpl_base = 0;
  logic [IDW-1:0] vio_id_last = '0, rpl_id_last = '0;
  logic [C.VLEN-1:0] vio_pc_last = '0;
  always_ff @(posedge clk) begin
    if (rst_n && lsq_vio) begin
      vio_cnt++;
      vio_id_last <= lsq_vio_id;
      vio_pc_last <= lsq_vio_pc;
    end
    if (rst_n && lsq_replay) begin
      rpl_cnt++;
      rpl_id_last <= lsq_replay_id;
    end
  end

  // --- drivers: one-cycle pulses on task-set registers ----------------------
  task automatic st_alloc(input int id);
    begin
      drv_st_alloc[0] = 1'b1; drv_alloc_id[0] = IDW'(id);
      drv_sb_live[id] = 1'b1;
      tick();
      drv_st_alloc = '0; drv_alloc_id = '0;
    end
  endtask

  task automatic ld_alloc(input int id, input logic [C.VLEN-1:0] pc);
    begin
      drv_ld_alloc[0] = 1'b1; drv_alloc_id[0] = IDW'(id);
      drv_alloc_pc[0] = pc;
      drv_sb_live[id] = 1'b1;
      tick();
      drv_ld_alloc = '0; drv_alloc_id = '0; drv_alloc_pc = '0;
    end
  endtask

  task automatic addr_ev(input int id, input logic [C.PLEN-1:0] pa,
                         input logic is_st);
    begin
      drv_addr_v[0] = 1'b1; drv_addr_id[0] = IDW'(id);
      drv_addr[0] = pa; drv_addr_is_st[0] = is_st; drv_addr_size[0] = 2'b11;
      tick();
      drv_addr_v = '0; drv_addr_id = '0; drv_addr = '0;
      drv_addr_is_st = '0; drv_addr_size = '0;
    end
  endtask

  task automatic sdata_ev(input int id, input logic [C.XLEN-1:0] d);
    begin
      drv_sdata_v[0] = 1'b1; drv_sdata_id[0] = IDW'(id); drv_sdata[0] = d;
      tick();
      drv_sdata_v = '0; drv_sdata_id = '0; drv_sdata = '0;
    end
  endtask

  // Load issue: address event and query land the same cycle (dispatch
  // agu_valid && ld_query both fire in the issue cycle).
  task automatic ld_issue(input int id, input logic [C.PLEN-1:0] pa);
    begin
      drv_addr_v[0] = 1'b1; drv_addr_id[0] = IDW'(id);
      drv_addr[0] = pa; drv_addr_is_st[0] = 1'b0; drv_addr_size[0] = 2'b11;
      drv_ldq = 1'b1; drv_ldq_addr = pa; drv_ldq_size = 2'b11;
      drv_ldq_id = IDW'(id);
      tick();
      drv_addr_v = '0; drv_addr_id = '0; drv_addr = '0;
      drv_addr_is_st = '0; drv_addr_size = '0;
      drv_ldq = 1'b0; drv_ldq_addr = '0; drv_ldq_size = '0; drv_ldq_id = '0;
    end
  endtask

  task automatic st_commit(input int id);
    begin
      drv_cst[0] = 1'b1; drv_cmt_id[0] = IDW'(id);
      tick();
      drv_cst = '0; drv_cmt_id = '0;
      drv_sb_live[id] = 1'b0;
    end
  endtask

  task automatic ld_commit(input int id);
    begin
      drv_cld[0] = 1'b1; drv_cmt_id[0] = IDW'(id);
      tick();
      drv_cld = '0; drv_cmt_id = '0;
      drv_sb_live[id] = 1'b0;
    end
  endtask

  task automatic ld_complete(input int id);
    begin
      drv_cpl_v[0] = 1'b1; drv_cpl_id[0] = IDW'(id); drv_cpl_is_st[0] = 1'b0;
      tick();
      drv_cpl_v = '0; drv_cpl_id = '0; drv_cpl_is_st = '0;
    end
  endtask

  task automatic phys_ev(input int id, input logic [C.PLEN-1:0] pa);
    begin
      drv_phys_v[0] = 1'b1; drv_phys_id[0] = IDW'(id);
      drv_phys_addr[0] = pa; drv_phys_size[0] = 2'b11;
      tick();
      drv_phys_v = '0; drv_phys_id = '0; drv_phys_addr = '0;
      drv_phys_size = '0;
    end
  endtask

  task automatic lsq_flush();
    begin
      drv_flush = 1'b1; drv_canc = '0;
      tick();
      drv_flush = 1'b0;
      repeat (2) tick();
    end
  endtask

  localparam logic [C.PLEN-1:0] A1 = C.PLEN'(64'h0000_0000_8000_3000);
  localparam logic [C.PLEN-1:0] A2 = C.PLEN'(64'h0000_0000_8000_3040);
  localparam logic [C.XLEN-1:0] SDAT = 64'h1122_3344_5566_7788;

  initial begin
    repeat (4) tick();
    rst_n = 1'b1;
    repeat (4) tick();

    // ============== G1: late address resolution MUST flag the load ========
    // Store tid 20 allocated older, address still unresolved when load
    // tid 21 verdicts -> the store's first resolution names load 21.
    st_alloc(20);
    ld_alloc(21, C.VLEN'(64'h8000_0026));
    check(lsq_st_unres[20], "G1_STORE_UNRES_TRACKED");
    ld_issue(21, A1);                    // load addr event + verdict query
    repeat (8) tick();
    check(vio_cnt == 0, "G1_EARLY_VIOLATION");   // own verdict never violates
    check(!lsq_checked[21], "G1_CHECKED_EARLY"); // unres must hold the publish
    addr_ev(20, A1, 1'b1);               // store's first address resolution
    begin
      bit v = 1'b0;
      for (int c = 0; c < 16 && !v; c++) begin
        tick();
        v = (vio_cnt == 1);
      end
      check(v, "G1_VIOLATION_MISSING");
    end
    check(vio_id_last == IDW'(21), "G1_VIOLATION_ID");
    check(rpl_cnt >= 1 && rpl_id_last == IDW'(21), "G1_REPLAY_ID");
    check(vio_pc_last === 'x || vio_pc_last == 64'h8000_0026, "G1_VIOLATION_PC");
    lsq_flush();
    // vio/rpl counters are cumulative across the whole run; each scenario
    // asserts "no violation since the last flush" against this baseline.
    vio_base = vio_cnt; rpl_base = rpl_cnt;

    // ============== G2a: resolved-at-verdict + late data -> dwait, ========
    // ============== then data/commit/phys events -> NO violation =========
    st_alloc(24);
    addr_ev(24, A2, 1'b1);               // store address resolves FIRST
    ld_alloc(25, C.VLEN'(64'h8000_0030));
    ld_issue(25, A2);                    // verdict: STL match, no data yet
    repeat (8) tick();
    check(vio_cnt == vio_base, "G2A_EARLY_VIOLATION");
    check(!lsq_checked[25], "G2A_CHECKED_EARLY");  // dwait must hold publish
    // A wait verdict pulses replay exactly once (H3 re-arm of the
    // waiting load's dependents); re-baseline so G2A_LATE_REPLAY
    // measures only the data/commit/phys events.
    check(rpl_cnt == rpl_base + 1 && rpl_id_last == IDW'(25), "G2A_WAIT_REPLAY");
    rpl_base = rpl_cnt;
    sdata_ev(24, SDAT);                    // store data lands -> dwait clears
    begin
      bit chk = 1'b0;
      for (int c = 0; c < 16 && !chk; c++) begin
        tick();
        chk = lsq_checked[25];
      end
      check(chk, "G2A_CHECKED_MISSING");
    end
    ld_complete(25);                     // publish done; entry still resident
    repeat (4) tick();
    st_commit(24);                       // commit event on the same store
    phys_ev(24, A2);                     // physical re-validation event
    repeat (8) tick();
    check(vio_cnt == vio_base, "G2A_LATE_VIOLATION");
    check(rpl_cnt == rpl_base, "G2A_LATE_REPLAY");
    ld_commit(25);                       // release the load entry by commit
    repeat (4) tick();
    lsq_flush();
    vio_base = vio_cnt; rpl_base = rpl_cnt;

    // ============== G2b: data present at verdict -> forward, then =========
    // ============== later store events -> NO violation ===================
    st_alloc(30);
    addr_ev(30, A1, 1'b1);               // resolved
    sdata_ev(30, SDAT);                    // and data already landed
    ld_alloc(31, C.VLEN'(64'h8000_0044));
    ld_issue(31, A1);                    // verdict must forward SDAT
    begin
      bit fwd = 1'b0;
      for (int c = 0; c < 16 && !fwd; c++) begin
        tick();
        fwd = lsq_stl_fwd;
      end
      check(fwd, "G2B_FORWARD_MISSING");
    end
    check(lsq_stl_data === SDAT, "G2B_FORWARD_DATA");
    sdata_ev(30, SDAT);                    // redundant data event
    st_commit(30);                       // commit
    phys_ev(30, A1);                     // phys re-validation
    repeat (8) tick();
    check(vio_cnt == vio_base, "G2B_LATE_VIOLATION");
    check(rpl_cnt == rpl_base, "G2B_LATE_REPLAY");
    ld_commit(31);
    repeat (4) tick();
    lsq_flush();

    // ============== G3: non-allocating port 0 must not phantom-claim ====
    // ============== the slot a port-1 alloc needs (ld/st, free==1) =====
    // hyp8-osbi-ld-diag-r2 (tid 21): a mixed group {p0 non-load, p1 load}
    // dispatched while the LDQ held exactly one free entry. The port-0
    // first-free pick was excluded from port 1's pool unconditionally, so
    // the load's claim saw an empty pool and was silently dropped -- no
    // entry, no verdict, and the load's completion could never publish.
    for (int i = 0; i < NLD_S - 1; i++)
      ld_alloc(10 + i, C.VLEN'(64'h8000_1000 + i * 4));
    check(lsq_ld_free == 4'(1), "G3_LD_FREE_ONE");
    drv_ld_alloc[1] = 1'b1; drv_alloc_id[1] = IDW'(17);
    drv_alloc_pc[1] = C.VLEN'(64'h8000_2000); drv_sb_live[17] = 1'b1;
    #1;
    check(dut.ld_alloc_v[1], "G3_P1_CLAIMED");
    tick();
    drv_ld_alloc = '0; drv_alloc_id = '0; drv_alloc_pc = '0;
    check(lsq_ld_free == 4'(0), "G3_LD_SLOT_TAKEN");
    // Identical mix on the store side (st_oh had the same phantom pick).
    for (int i = 0; i < NST_S - 1; i++)
      st_alloc(18 + i);
    check(lsq_st_free == 4'(1), "G3_ST_FREE_ONE");
    drv_st_alloc[1] = 1'b1; drv_alloc_id[1] = IDW'(25); drv_sb_live[25] = 1'b1;
    #1;
    tick();
    drv_st_alloc = '0; drv_alloc_id = '0;
    check(lsq_st_free == 4'(0), "G3_P1_ST_SLOT_TAKEN");
    // Positive: two live alloc ports still take distinct slots.
    lsq_flush();
    drv_ld_alloc = 2'b11;
    drv_alloc_id[0] = IDW'(26); drv_alloc_pc[0] = C.VLEN'(64'h8000_3000);
    drv_alloc_id[1] = IDW'(27); drv_alloc_pc[1] = C.VLEN'(64'h8000_3004);
    drv_sb_live[26] = 1'b1; drv_sb_live[27] = 1'b1;
    #1;
    check(dut.ld_alloc_v[0] && dut.ld_alloc_v[1], "G3_DUAL_CLAIMED");
    check(dut.ld_alloc_idx[0] != dut.ld_alloc_idx[1], "G3_DUAL_DISTINCT");
    tick();
    drv_ld_alloc = '0; drv_alloc_id = '0; drv_alloc_pc = '0;
    lsq_flush();

    $display("HYP8_LSQ_PASS checked=%0d", checked);
    $finish;
  end

  int wdog = 0;
  always_ff @(posedge clk) begin
    wdog <= wdog + 1;
    if (wdog > 200000) $fatal(1, "HYP8_LSQ_TIMEOUT");
  end
endmodule
`endif // G6LC_HYP8_LSQ_LEAF

// ---------------------------------------------------------------------------
// HYP8 controller leaf (r28): an invalid resolve record (valid=0) must raise
// no flush. A stale resolve of an already-cancelled branch still carries
// is_mispredict=1 on the bus; the ungated leg made flush_if reseed the FTQ
// with npc_q (next_block of the real redirect target) one cycle after the
// redirect's own flush+push, dropping the target instruction. A valid
// mispredict keeps the IF+unissued contract. Mutant A/B:
// G6LC_MUT_CTRL_STALE_RESOLVE restores the ungated leg.
// PASS token: HYP8_CTRL_PASS
// ---------------------------------------------------------------------------
module tb_g6lc_hyp8_ctrl;
  int checked = 0;
  task check(input logic cond, input string name);
    checked++;
    if (!cond) begin
      $display("FAIL %s", name);
      $fatal(1, "tb_g6lc_hyp8_ctrl");
    end
  endtask

  function automatic config_pkg::g6lc_cfg_t configuration();
    return build_config_pkg::build_config(g6lc_config_pkg::g6lc_cfg);
  endfunction
  localparam config_pkg::g6lc_cfg_t C = configuration();
  localparam int unsigned HART_ID_BITS =
      (C.NrHarts > 1) ? $clog2(C.NrHarts) : 1;

  typedef struct packed {
    logic                       valid;
    logic [C.VLEN-1:0]          pc;
    logic [C.VLEN-1:0]          target_address;
    logic                       is_mispredict;
    logic                       is_taken;
    g6lc_core_pkg::cf_t         cf_type;
    logic [HART_ID_BITS-1:0]    hart_id;
    logic                       ckpt_restore;
    logic [C.TRANS_ID_BITS-1:0] trans_id;
    logic                       ckpt_v;
    logic [7:0]                 ckpt_idx;
    logic                       is_call;
    logic [C.VLEN-1:0]          next_pc;
  } bp_resolve_t;

  logic        clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  bp_resolve_t res = '0;
  logic        eret = 0;
  logic        f_spc, f_fif, f_uniss, f_fid, f_fex, f_fbp;
  logic        f_fic, f_fdc, f_ftlb, f_ftlbv, f_ftlbg;
  logic        f_hf, f_halt, f_mrpc, f_drainp;
  logic [C.VLEN-1:0] f_pchold;

  controller #(
      .G6LCCfg      (C),
      .HypCfg       (g6lc_hyp_pkg::Hyp8),
      .bp_resolve_t (bp_resolve_t)
  ) dut (
      .clk_i               (clk),
      .rst_ni              (rst_n),
      .v_i                 (1'b0),
      .set_pc_commit_o     (f_spc),
      .flush_if_o          (f_fif),
      .flush_unissued_instr_o (f_uniss),
      .flush_id_o          (f_fid),
      .flush_ex_o          (f_fex),
      .flush_bp_o          (f_fbp),
      .flush_icache_o      (f_fic),
      .flush_dcache_o      (f_fdc),
      .flush_dcache_ack_i  (1'b0),
      .flush_tlb_o         (f_ftlb),
      .flush_tlb_vvma_o    (f_ftlbv),
      .flush_tlb_gvma_o    (f_ftlbg),
      .halt_csr_i          (1'b0),
      .halt_acc_i          (1'b0),
      .halt_frontend_o     (f_hf),
      .halt_o              (f_halt),
      .eret_i              (eret),
      .ex_valid_i          (1'b0),
      .set_debug_pc_i      (1'b0),
      .resolved_branch_i   (res),
      .flush_csr_i         (1'b0),
      .fence_i_i           (1'b0),
      .fence_i             (1'b0),
      .sfence_vma_i        (1'b0),
      .hfence_vvma_i       (1'b0),
      .hfence_gvma_i       (1'b0),
      .flush_commit_i      (1'b0),
      .replay_i            (1'b0),
      .mem_replay_pc_o     (f_mrpc),
      .flush_acc_i         (1'b0),
      .smt_switch_i        (1'b0),
      .drain_force_i       (1'b0),
      .pc_commit_i         ('0),
      .pc_commit_hold_o    (f_pchold),
      .drain_pending_o     (f_drainp)
  );

  task automatic settle();
    #2;
  endtask

  initial begin
    rst_n = 1;
    res = '0; settle();
    check(!f_fif && !f_uniss && !f_fid && !f_fex && !f_fbp && !f_spc,
          "CTRL_IDLE_NO_FLUSH");

    // A: stale resolve of an already-cancelled branch -- valid=0 while the
    //    is_mispredict field still reads 1 (the r28 ghost-flush signature).
    //    An invalid record must not raise any flush.
    res = '{valid: 1'b0, is_mispredict: 1'b1, is_taken: 1'b1,
            cf_type: g6lc_core_pkg::Branch, default: '0};
    settle();
    check(!f_fif && !f_uniss && !f_fid && !f_fex && !f_fbp && !f_spc,
          "CTRL_STALE_RESOLVE_NO_FLUSH");
    res = '0; settle();

    // B: a valid mispredict keeps the contract: IF + unissued only.
    res = '{valid: 1'b1, is_mispredict: 1'b1, is_taken: 1'b1,
            cf_type: g6lc_core_pkg::Branch, default: '0};
    settle();
    check(f_fif && f_uniss && !f_fid && !f_fex,
          "CTRL_VALID_MISPREDICT_FLUSH");
    res = '0; settle();

    // C: a valid predicted-correct resolve flushes nothing (under
    //    G6LC_FETCH_B the cf-unissued helper leg is compiled out).
    res = '{valid: 1'b1, is_mispredict: 1'b0, is_taken: 1'b1,
            cf_type: g6lc_core_pkg::Branch, default: '0};
    settle();
    check(!f_fif && !f_fid && !f_fex,
          "CTRL_CORRECT_RESOLVE_NO_FLUSH");
    res = '0; settle();

    // D: eret keeps its full flush (regression: the gate must not leak).
    eret = 1; settle();
    check(f_fif && f_uniss && f_fid && f_fex, "CTRL_ERET_FLUSH");
    eret = 0; settle();

    // E: invalid resolve with junk in every field still flushes nothing.
    res = '1; res.valid = 1'b0; settle();
    check(!f_fif && !f_uniss && !f_fid && !f_fex && !f_fbp,
          "CTRL_INVALID_JUNK_NO_FLUSH");
    res = '0; settle();

    $display("HYP8_CTRL_PASS checked=%0d", checked);
    $finish;
  end
endmodule
