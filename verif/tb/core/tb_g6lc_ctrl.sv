// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// T6b-3 exit leaf: the U6.1 fine-grain switch override must never degrade a
// commit-level flush. Two geometries share one stimulus: MIXED (NrHarts=2,
// SmtDrainedHandoff=0) keeps the full flush standing when eret_i (or any
// commit_flush source) coincides with smt_switch_i; DRAINED (NrHarts=2,
// SmtDrainedHandoff=1) is required to stay bit-identical to the pre-fix
// behaviour (override applies, flush_id/flush_ex drop).
module tb_g6lc_ctrl;
  function automatic config_pkg::cva6_cfg_t cfg(input bit drained);
    config_pkg::cva6_cfg_t c = config_pkg::cva6_cfg_empty;
    c.XLEN = 64;
    c.VLEN = 64;
    c.NrHarts = 2;
    c.NrCommitPorts = 2;
    c.SmtDrainedHandoff = drained;
    return c;
  endfunction

  typedef struct packed {
    logic        valid;
    logic [63:0] pc;
    logic [63:0] target_address;
    logic        is_mispredict;
    logic        is_taken;
    ariane_pkg::cf_t cf_type;
    logic        hart_id;
    logic        ckpt_restore;
    logic [7:0]  trans_id;
  } bp_resolve_t;

  logic clk = 0, rst_n = 0;
  // Shared stimulus
  logic eret = 0, ex_valid = 0, dbg_pc = 0, sw = 0;
  logic flush_csr = 0, fence_i = 0, fence_i_i = 0;
  logic sfence_vma = 0, hfence_vvma = 0, hfence_gvma = 0;
  logic flush_commit = 0, flush_acc = 0;
  logic m_fid, m_fex, m_fif, m_uniss, m_fbp, m_spc;
  logic d_fid, d_fex, d_fif, d_uniss, d_fbp, d_spc;

  controller #(.CVA6Cfg(cfg(0)), .bp_resolve_t(bp_resolve_t)) mixed (
    .clk_i(clk), .rst_ni(rst_n), .v_i(1'b0),
    .set_pc_commit_o(m_spc), .flush_if_o(m_fif),
    .flush_unissued_instr_o(m_uniss), .flush_id_o(m_fid),
    .flush_ex_o(m_fex), .flush_bp_o(m_fbp),
    .flush_icache_o(), .flush_dcache_o(), .flush_dcache_ack_i(1'b0),
    .flush_tlb_o(), .flush_tlb_vvma_o(), .flush_tlb_gvma_o(),
    .halt_csr_i(1'b0), .halt_acc_i(1'b0), .halt_frontend_o(), .halt_o(),
    .eret_i(eret), .ex_valid_i(ex_valid), .set_debug_pc_i(dbg_pc),
    .resolved_branch_i('0), .flush_csr_i(flush_csr),
    .fence_i_i(fence_i_i), .fence_i(fence_i),
    .sfence_vma_i(sfence_vma), .hfence_vvma_i(hfence_vvma),
    .hfence_gvma_i(hfence_gvma), .flush_commit_i(flush_commit),
    .replay_i(1'b0), .mem_replay_pc_o(), .flush_acc_i(flush_acc),
    .smt_switch_i(sw), .drain_force_i(1'b0)
  );

  controller #(.CVA6Cfg(cfg(1)), .bp_resolve_t(bp_resolve_t)) drained (
    .clk_i(clk), .rst_ni(rst_n), .v_i(1'b0),
    .set_pc_commit_o(d_spc), .flush_if_o(d_fif),
    .flush_unissued_instr_o(d_uniss), .flush_id_o(d_fid),
    .flush_ex_o(d_fex), .flush_bp_o(d_fbp),
    .flush_icache_o(), .flush_dcache_o(), .flush_dcache_ack_i(1'b0),
    .flush_tlb_o(), .flush_tlb_vvma_o(), .flush_tlb_gvma_o(),
    .halt_csr_i(1'b0), .halt_acc_i(1'b0), .halt_frontend_o(), .halt_o(),
    .eret_i(eret), .ex_valid_i(ex_valid), .set_debug_pc_i(dbg_pc),
    .resolved_branch_i('0), .flush_csr_i(flush_csr),
    .fence_i_i(fence_i_i), .fence_i(fence_i),
    .sfence_vma_i(sfence_vma), .hfence_vvma_i(hfence_vvma),
    .hfence_gvma_i(hfence_gvma), .flush_commit_i(flush_commit),
    .replay_i(1'b0), .mem_replay_pc_o(), .flush_acc_i(flush_acc),
    .smt_switch_i(sw), .drain_force_i(1'b0)
  );

  // flush_ctrl is purely combinational; a short settle is enough.
  task automatic settle;
    #2;
  endtask

  bit negative;

  initial begin
    negative = $test$plusargs("oracle_negative");
    rst_n = 1;

    // A: plain switch, no commit-level event — the override still applies
    //    under mixed residency (regression: gate did not widen the guard).
    sw = 1; settle();
    if (negative ? (m_fid | m_fex) : !(m_fif && m_uniss && !m_fid && !m_fex))
      $fatal(1, "CTRL_SWITCH_PLAIN mixed fif=%b uniss=%b fid=%b fex=%b",
             m_fif, m_uniss, m_fid, m_fex);
    sw = 0; settle();

    // B: eret_i && smt_switch_i same cycle — the duplicate-mret window.
    //    MIXED: the full flush must stand. +oracle_negative inverts.
    sw = 1; eret = 1; settle();
    if (negative ? (m_fid && m_fex) : !(m_fif && m_uniss && m_fid && m_fex))
      $fatal(1, "CTRL_SWITCH_ERET mixed fif=%b uniss=%b fid=%b fex=%b",
             m_fif, m_uniss, m_fid, m_fex);
    //    DRAINED: pre-fix behaviour is the contract — override applies.
    if (!(d_fif && d_uniss && !d_fid && !d_fex))
      $fatal(1, "CTRL_SWITCH_DRAINED fif=%b uniss=%b fid=%b fex=%b",
             d_fif, d_uniss, d_fid, d_fex);
    sw = 0; eret = 0; settle();

    // C: second commit_flush source — flush_csr_i && switch keeps the kill.
    sw = 1; flush_csr = 1; settle();
    if (negative ? (m_fid && m_fex) : !(m_fif && m_uniss && m_fid && m_fex))
      $fatal(1, "CTRL_SWITCH_CSR mixed fif=%b uniss=%b fid=%b fex=%b",
             m_fif, m_uniss, m_fid, m_fex);
    sw = 0; flush_csr = 0; settle();

    // D: fence.i && switch — commit-level source with icache side outputs.
    sw = 1; fence_i_i = 1; settle();
    if (negative ? (m_fid && m_fex) : !(m_fif && m_uniss && m_fid && m_fex))
      $fatal(1, "CTRL_SWITCH_FENCEI mixed fif=%b uniss=%b fid=%b fex=%b",
             m_fif, m_uniss, m_fid, m_fex);
    sw = 0; fence_i_i = 0; settle();

    // E: eret without a switch — the guard must not gate a normal eret flush.
    eret = 1; settle();
    if (!(m_fif && m_uniss && m_fid && m_fex && m_fbp))
      $fatal(1, "CTRL_ERET_PLAIN fif=%b uniss=%b fid=%b fex=%b fbp=%b",
             m_fif, m_uniss, m_fid, m_fex, m_fbp);
    eret = 0; settle();

    // F: a mispredict is NOT commit_flush — a coincident switch still takes
    //    the override (only flush_unissued/flush_if were raised anyway).
    sw = 1; settle();
    if (!(m_fif && m_uniss && !m_fid && !m_fex))
      $fatal(1, "CTRL_SWITCH_OVERRIDDEN fif=%b uniss=%b fid=%b fex=%b",
             m_fif, m_uniss, m_fid, m_fex);
    sw = 0; settle();

    $display("CTRL_BANK_PASS");
    $finish;
  end
endmodule
