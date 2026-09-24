// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// T6b-3 exit leaf: under mixed residency each decode lane must take the
// interrupt context (irq lines + mie/mip/delegation/privilege) of its own
// instruction's hart, not the active hart's scalar context. The
// architectural smt_mixed_probe cannot reach this seam — the window where
// a resident peer's instruction sits at a decode lane while the active hart
// has a pending enabled interrupt never materialised in 144 timer fires —
// so the isolation contract is checked here where both contexts are
// directly drivable.
// G6LC_MUT_DECODE_ACTIVE_IRQ restores the old wiring: every lane decodes
// against the active hart's context, and a peer-hart instruction vectors on
// an interrupt that is not its own.
module tb_g6lc_idstage;
  function automatic config_pkg::cva6_cfg_t cfg();
    config_pkg::cva6_cfg_t c = config_pkg::cva6_cfg_empty;
    c.XLEN = 64;
    c.VLEN = 64;
    c.PLEN = 56;
    c.GPLEN = 56;
    c.RVC = 1;
    c.NrHarts = 2;
    c.NrIssuePorts = 2;
    c.SuperscalarEn = 1;
    c.NrCommitPorts = 2;
    c.NrWbPorts = 2;
    c.NR_SB_ENTRIES = 64;
    c.TRANS_ID_BITS = 6;
    c.SmtDrainedHandoff = 0;
    return c;
  endfunction

  localparam config_pkg::cva6_cfg_t CFG = cfg();
  localparam int unsigned NH = 2;
  localparam int unsigned NIP = 2;
  localparam int unsigned NCP = 2;

  typedef struct packed {
    ariane_pkg::cf_t cf;
    logic [CFG.VLEN-1:0] predict_address;
  } branchpredict_sbe_t;
  typedef struct packed {
    logic [CFG.XLEN-1:0] cause;
    logic [CFG.XLEN-1:0] tval;
    logic [CFG.GPLEN-1:0] tval2;
    logic [31:0] tinst;
    logic gva;
    logic valid;
  } exception_t;
  typedef struct packed {
    logic [CFG.VLEN-1:0] address;
    logic [31:0] instruction;
    branchpredict_sbe_t branch_predict;
    exception_t ex;
    logic hart_id;
  } fetch_entry_t;
  typedef struct packed {
    logic [CFG.XLEN-7:0] base;
    logic [5:0] mode;
  } jvt_t;
  typedef struct packed {
    logic [CFG.XLEN-1:0] mie;
    logic [CFG.XLEN-1:0] mip;
    logic [CFG.XLEN-1:0] mideleg;
    logic [CFG.XLEN-1:0] hideleg;
    logic sie;
    logic global_enable;
  } irq_ctrl_t;
  typedef struct packed {
    logic [CFG.VLEN-1:0] pc;
    logic [CFG.TRANS_ID_BITS-1:0] trans_id;
    ariane_pkg::fu_t fu;
    ariane_pkg::fu_op op;
    logic [ariane_pkg::REG_ADDR_SIZE-1:0] rs1;
    logic [ariane_pkg::REG_ADDR_SIZE-1:0] rs2;
    logic [ariane_pkg::REG_ADDR_SIZE-1:0] rd;
    logic [CFG.XLEN-1:0] result;
    logic valid;
    logic use_imm;
    logic use_zimm;
    logic use_pc;
    exception_t ex;
    branchpredict_sbe_t bp;
    logic is_compressed;
    logic is_macro_instr;
    logic is_last_macro_instr;
    logic is_double_rd_macro_instr;
    logic vfp;
    logic is_zcmt;
    logic hart_id;
    logic [7:0] p_rs1;
    logic [7:0] p_rs2;
    logic [7:0] p_rd;
    logic [7:0] p_frs1;
    logic [7:0] p_frs2;
    logic [7:0] p_frs3;
    logic [7:0] p_frd;
    logic ooo_renamed;
  } scoreboard_entry_t;
  typedef struct packed {
    logic [CFG.XLEN-1:0] S_SW;
    logic [CFG.XLEN-1:0] VS_SW;
    logic [CFG.XLEN-1:0] M_SW;
    logic [CFG.XLEN-1:0] S_TIMER;
    logic [CFG.XLEN-1:0] VS_TIMER;
    logic [CFG.XLEN-1:0] M_TIMER;
    logic [CFG.XLEN-1:0] S_EXT;
    logic [CFG.XLEN-1:0] VS_EXT;
    logic [CFG.XLEN-1:0] M_EXT;
    logic [CFG.XLEN-1:0] HS_EXT;
    logic [CFG.XLEN-1:0] LCOF;
  } interrupts_t;
  localparam interrupts_t INTERRUPTS = '{
      S_SW: (CFG.XLEN'(1) << (CFG.XLEN - 1)) | CFG.XLEN'(riscv::IRQ_S_SOFT),
      VS_SW: (CFG.XLEN'(1) << (CFG.XLEN - 1)) | CFG.XLEN'(riscv::IRQ_VS_SOFT),
      M_SW: (CFG.XLEN'(1) << (CFG.XLEN - 1)) | CFG.XLEN'(riscv::IRQ_M_SOFT),
      S_TIMER: (CFG.XLEN'(1) << (CFG.XLEN - 1)) | CFG.XLEN'(riscv::IRQ_S_TIMER),
      VS_TIMER: (CFG.XLEN'(1) << (CFG.XLEN - 1)) | CFG.XLEN'(riscv::IRQ_VS_TIMER),
      M_TIMER: (CFG.XLEN'(1) << (CFG.XLEN - 1)) | CFG.XLEN'(riscv::IRQ_M_TIMER),
      S_EXT: (CFG.XLEN'(1) << (CFG.XLEN - 1)) | CFG.XLEN'(riscv::IRQ_S_EXT),
      VS_EXT: (CFG.XLEN'(1) << (CFG.XLEN - 1)) | CFG.XLEN'(riscv::IRQ_VS_EXT),
      M_EXT: (CFG.XLEN'(1) << (CFG.XLEN - 1)) | CFG.XLEN'(riscv::IRQ_M_EXT),
      HS_EXT: (CFG.XLEN'(1) << (CFG.XLEN - 1)) | CFG.XLEN'(riscv::IRQ_HS_EXT),
      LCOF: (CFG.XLEN'(1) << (CFG.XLEN - 1)) | CFG.XLEN'(riscv::IRQ_LCOF)
  };

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  fetch_entry_t [NIP-1:0] fe;
  logic [NIP-1:0] fe_valid, fe_ready, issue_ack;
  scoreboard_entry_t [NIP-1:0] issue_entry;
  scoreboard_entry_t [NCP-1:0] commit_instr;
  logic [NCP-1:0] commit_ack;
  logic [NIP-1:0] issue_valid;
  irq_ctrl_t irq_ctrl;
  irq_ctrl_t [NH-1:0] irq_ctrl_b;
  logic [NH-1:0][1:0] irq_b;
  riscv::priv_lvl_t [NH-1:0] priv_lvl_b;

  id_stage #(
    .CVA6Cfg(CFG),
    .branchpredict_sbe_t(branchpredict_sbe_t),
    .dcache_req_i_t(logic),
    .dcache_req_o_t(logic),
    .exception_t(exception_t),
    .fetch_entry_t(fetch_entry_t),
    .jvt_t(jvt_t),
    .irq_ctrl_t(irq_ctrl_t),
    .scoreboard_entry_t(scoreboard_entry_t),
    .interrupts_t(interrupts_t),
    .INTERRUPTS(INTERRUPTS),
    .x_compressed_req_t(logic),
    .x_compressed_resp_t(logic)
  ) dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(1'b0), .debug_req_i(1'b0),
    .fetch_entry_i(fe), .fetch_entry_valid_i(fe_valid),
    .fetch_entry_ready_o(fe_ready),
    .g1lq_v_i('0), .g1lq_rd_i('0), .g1lq_line_i('0), .g1lq_a3_i('0),
    .commit_instr_i(commit_instr), .commit_ack_i(commit_ack),
    .g1mf_v_i('0), .g1mf_rd_i('0), .g1mf_line_i('0), .g1mf_a3_i('0),
    .issue_entry_o(issue_entry), .issue_entry_o_prev(),
    .orig_instr_o(), .issue_entry_valid_o(issue_valid),
    .is_ctrl_flow_o(), .issue_instr_ack_i(issue_ack),
    .rvfi_is_compressed_o(),
    .priv_lvl_i(riscv::PRIV_LVL_M), .v_i(1'b0),
    .fs_i(riscv::Dirty), .vfs_i(riscv::Off), .frm_i('0), .vs_i(riscv::Off),
    .irq_i(2'b00), .irq_ctrl_i(irq_ctrl),
    .irq_b_i(irq_b), .irq_ctrl_b_i(irq_ctrl_b),
    .priv_lvl_b_i(priv_lvl_b), .v_b_i('0),
    .tvm_b_i('0), .tw_b_i('0), .vtw_b_i('0), .tsr_b_i('0), .hu_b_i('0),
    .debug_mode_b_i('0), .fs_b_i({NH{riscv::Dirty}}),
    .vfs_b_i({NH{riscv::Off}}), .vs_b_i({NH{riscv::Off}}),
    .frm_b_i('0),
    .mcbie_b_i('0), .scbie_b_i('0), .hcbie_b_i('0),
    .mcbcfe_b_i('0), .scbcfe_b_i('0), .hcbcfe_b_i('0),
    .mcbze_b_i('0), .scbze_b_i('0), .hcbze_b_i('0),
    .jvt_b_i('0),
    .debug_mode_i(1'b0), .tvm_i(1'b0), .tw_i(1'b0), .vtw_i(1'b0),
    .tsr_i(1'b0), .hu_i(1'b0),
    .mcbie_i('0), .scbie_i('0), .hcbie_i('0),
    .mcbcfe_i(1'b0), .scbcfe_i(1'b0), .hcbcfe_i(1'b0),
    .mcbze_i(1'b0), .scbze_i(1'b0), .hcbze_i(1'b0),
    .hart_id_i('0), .smt_hart_id_i('0),
    .smt_pause_hint_o(),
    .compressed_ready_i(1'b0), .jvt_i('0), .compressed_resp_i('0),
    .compressed_valid_o(), .compressed_req_o(),
    .debug_from_trigger_i(1'b0),
    .dcache_req_ports_i('0), .dcache_req_ports_o()
  );

  task automatic tick;
    @(posedge clk); #2;
  endtask

  task automatic settle;
    #2;
  endtask

  // Offer one instruction on lane 0, let it land in the issue register,
  // then look at issue_entry_o[0].
  task automatic offer(input logic hart, input logic [31:0] instr);
    fe = '0;
    fe_valid = '0;
    fe[0].address = 64'h8000_1000;
    fe[0].instruction = instr;
    fe[0].hart_id = hart;
    fe_valid[0] = 1'b1;
    // Wait for the ID stage to accept the entry.
    do begin
      tick();
    end while (!fe_ready[0]);
    fe_valid[0] = 1'b0;
    tick();  // issue_q now holds the decoded entry
    settle();
  endtask

  task automatic drain;
    issue_ack[0] = 1'b1;
    tick();
    issue_ack[0] = 1'b0;
    settle();
  endtask

  localparam logic [31:0] ADDI = 32'h0010_0093;  // addi x1, x0, 1
  bit negative;

  initial begin
    negative = $test$plusargs("oracle_negative");
    fe = '0; fe_valid = '0; issue_ack = '0;
    commit_instr = '0; commit_ack = '0;
    irq_ctrl = '0; irq_b = '0;
    priv_lvl_b[0] = riscv::PRIV_LVL_M;
    priv_lvl_b[1] = riscv::PRIV_LVL_M;
    rst_n = 0;
    repeat (3) @(posedge clk);
    #2 rst_n = 1;
    tick();

    // Active hart's scalar context: MTIP pending + MTIE + global enable.
    // irq_ctrl_b[0] mirrors it (hart 0's own bank); hart 1's bank is quiet.
    irq_ctrl = '0;
    irq_ctrl.mie = 64'h80;
    irq_ctrl.mip = 64'h80;
    irq_ctrl.global_enable = 1'b1;
    irq_ctrl_b[0] = irq_ctrl;
    irq_ctrl_b[1] = '0;

    // A: a hart-1 instruction at a decode lane while the ACTIVE hart's
    //    context has MTIP pending+enabled. Correct: the lane takes
    //    irq_ctrl_b[1] (quiet) — no exception. Mutant: the lane takes the
    //    scalar context — the peer vectors on hart 0's timer.
    offer(1'b1, ADDI);
    if (!issue_valid[0])
      $fatal(1, "DECODE_NOISSUE no issue slot after offer");
    if (negative ? !issue_entry[0].ex.valid : issue_entry[0].ex.valid)
      $fatal(1, "DECODE_ACTIVE_IRQ h1-entry ex.valid=%b cause=%h",
             issue_entry[0].ex.valid, issue_entry[0].ex.cause);
    drain();

    // B: same-hart control — a hart-0 instruction with hart 0's context
    //    pending must vector (per-hart delivery intact).
    offer(1'b0, ADDI);
    if (!(issue_valid[0] && issue_entry[0].ex.valid &&
          issue_entry[0].ex.cause == INTERRUPTS.M_TIMER))
      $fatal(1, "DECODE_IRQ_OWN h0-entry ex=%b cause=%h want %h",
             issue_entry[0].ex.valid, issue_entry[0].ex.cause,
             INTERRUPTS.M_TIMER);
    drain();

    // C: peer-context control — hart 1's own bank with MTIP pending: the
    //    hart-1 instruction must vector on its own interrupt.
    irq_ctrl = '0;                 // active context quiet
    irq_ctrl_b[0] = '0;
    irq_ctrl_b[1] = '0;
    irq_ctrl_b[1].mie = 64'h80;
    irq_ctrl_b[1].mip = 64'h80;
    irq_ctrl_b[1].global_enable = 1'b1;
    offer(1'b1, ADDI);
    if (!(issue_valid[0] && issue_entry[0].ex.valid &&
          issue_entry[0].ex.cause == INTERRUPTS.M_TIMER))
      $fatal(1, "DECODE_IRQ_PEER h1-entry ex=%b cause=%h want %h",
             issue_entry[0].ex.valid, issue_entry[0].ex.cause,
             INTERRUPTS.M_TIMER);
    drain();

    // D: quiet control — nothing pending anywhere, clean decode.
    irq_ctrl_b[1] = '0;
    offer(1'b1, ADDI);
    if (!(issue_valid[0] && !issue_entry[0].ex.valid))
      $fatal(1, "DECODE_QUIET h1-entry ex=%b", issue_entry[0].ex.valid);
    drain();

    $display("IDSTAGE_IRQ_PASS");
    $finish;
  end
endmodule
