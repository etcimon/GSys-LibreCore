// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Isolated hyp8 g6lc_rvfi leaf verifying N1 & N2 fixes:
//   S1 (N1): commit_ack=1 with commit_drop=1 suppresses BOTH rvfi_instr_o.valid
//            AND rvfi_to_iti_o.valid (zero phantom wrong-path ITI records).
//   S2 (N2): AMO_LRD dispatched on STORE path reports mem_rmask=8'hff and
//            mem_wmask=8'h00 (zero phantom store, complete LR read visibility).
//   S3 (N2): Idle lsu_ctrl_valid=0 carrying stale STORE fu/be/tid does NOT
//            pollute a reallocated ALU instruction's mem_wmask/mem_rmask.
//
// Review mutations (each must fail):
//   -DG6LC_MUT_RVFI_DROP_ITI    -> fails S1_DROP_SUPPRESSES_ITI
//   -DG6LC_MUT_RVFI_NO_LR_RMASK -> fails S2_LR_RMASK_SET
//
// PASS token: PASS tb_g6lc_rvfi_n1n2_hyp8
`include "rvfi_types.svh"

module tb_g6lc_rvfi_n1n2_hyp8;
  import g6lc_core_pkg::*;
  localparam config_pkg::g6lc_cfg_t C =
      build_config_pkg::build_config(g6lc_config_pkg::g6lc_cfg);
  localparam int unsigned NC = C.NrCommitPorts;

  typedef `RVFI_INSTR_T(C) rvfi_instr_t;
  typedef `RVFI_CSR_ELMT_T(C) rvfi_csr_elmt_t;
  typedef `RVFI_CSR_T(C, rvfi_csr_elmt_t) rvfi_csr_t;
  typedef `RVFI_PROBES_INSTR_T(C) rvfi_probes_instr_t;
  typedef `RVFI_PROBES_CSR_T(C) rvfi_probes_csr_t;
  typedef struct packed {
    rvfi_probes_csr_t   csr;
    rvfi_probes_instr_t instr;
  } rvfi_probes_t;
  typedef `RVFI_TO_ITI_T(C) rvfi_to_iti_t;

  logic clk = 0, rst_n = 0;
  int checked = 0;
  always #5 clk = ~clk;
  task tick(); @(posedge clk); #1; endtask
  task check(input logic cond, input string name);
    checked++;
    if (!cond) begin
      $display("FAIL %s", name);
      $fatal(1, "tb_g6lc_rvfi_n1n2_hyp8");
    end
  endtask

  rvfi_probes_t          probes = '0;
  rvfi_instr_t [NC-1:0]  rvfi_instr;
  rvfi_csr_t             rvfi_csr;
  logic [NC-1:0][7:0]    rvfi_hart;
  rvfi_to_iti_t          rvfi_iti;

  g6lc_rvfi #(
      .G6LCCfg            (C),
      .rvfi_instr_t       (rvfi_instr_t),
      .rvfi_csr_t         (rvfi_csr_t),
      .rvfi_probes_instr_t(rvfi_probes_instr_t),
      .rvfi_probes_csr_t  (rvfi_probes_csr_t),
      .rvfi_probes_t      (rvfi_probes_t),
      .rvfi_to_iti_t      (rvfi_to_iti_t)
  ) dut (
      .clk_i        (clk),
      .rst_ni       (rst_n),
      .rvfi_probes_i(probes),
      .rvfi_instr_o (rvfi_instr),
      .rvfi_hart_o  (rvfi_hart),
      .rvfi_csr_o   (rvfi_csr),
      .rvfi_to_iti_o(rvfi_iti)
  );

  initial begin
    repeat (3) tick();
    rst_n = 1'b1;
    tick();

    // ---- S1 (N1): Wrong-path drop on port 1 (commit_ack=1, commit_drop=1) ----
    probes = '0;
    probes.instr.commit_ack[1]         = 1'b1;
    probes.instr.commit_drop[1]        = 1'b1;
    probes.instr.commit_instr_valid[1] = 1'b1;
    probes.instr.commit_instr_pc[1]    = 64'h8000_0100;
    probes.instr.commit_pointer[1]     = 5'd3;
    tick();
    probes = '0;
    check(rvfi_instr[1].valid === 1'b0, "S1_DROP_SUPPRESSES_RVFI");
    check(rvfi_iti.valid[1]   === 1'b0, "S1_DROP_SUPPRESSES_ITI");

    // ---- S2 (N2): AMO_LRD dispatched on STORE path -> mem_rmask=ff, mem_wmask=00 ----
    probes = '0;
    probes.instr.decoded_instr_valid[0] = 1'b1;
    probes.instr.decoded_instr_ack[0]   = 1'b1;
    probes.instr.issue_pointer[0]       = 5'd5;
    probes.instr.instruction[0]         = 32'h1607_b52f; // lr.d.aqrl x10,(x15)
    tick();
    probes = '0;
    probes.instr.lsu_ctrl_valid    = 1'b1;
    probes.instr.lsu_ctrl_fu       = STORE;
    probes.instr.lsu_ctrl_op       = AMO_LRD;
    probes.instr.lsu_ctrl_be       = 8'hff;
    probes.instr.lsu_ctrl_vaddr    = 64'h8004_6088;
    probes.instr.lsu_ctrl_trans_id = 5'd5;
    tick();
    probes = '0;
    probes.instr.commit_ack[0]         = 1'b1;
    probes.instr.commit_instr_valid[0] = 1'b1;
    probes.instr.commit_instr_op[0]    = AMO_LRD;
    probes.instr.commit_pointer[0]     = 5'd5;
    tick();
    probes = '0;
    check(rvfi_instr[0].valid     === 1'b1,          "S2_LR_VALID");
    check(rvfi_instr[0].mem_rmask === 8'hff,         "S2_LR_RMASK_SET");
    check(rvfi_instr[0].mem_wmask === 8'h00,         "S2_LR_WMASK_ZERO");
    check(rvfi_instr[0].mem_addr  === 64'h8004_6088, "S2_LR_ADDR");

    // ---- S3 (N2): Idle lsu_ctrl_valid=0 stale STORE must NOT pollute reallocated tid 5 ----
    probes = '0;
    probes.instr.decoded_instr_valid[0] = 1'b1;
    probes.instr.decoded_instr_ack[0]   = 1'b1;
    probes.instr.issue_pointer[0]       = 5'd5;
    probes.instr.instruction[0]         = 32'h0000_0013; // nop
    tick();
    probes = '0;
    probes.instr.lsu_ctrl_valid    = 1'b0; // IDLE!
    probes.instr.lsu_ctrl_fu       = STORE;
    probes.instr.lsu_ctrl_op       = SD;
    probes.instr.lsu_ctrl_be       = 8'hff;
    probes.instr.lsu_ctrl_vaddr    = 64'hdead_beef_0000;
    probes.instr.lsu_ctrl_trans_id = 5'd5;
    tick();
    probes = '0;
    probes.instr.commit_ack[0]         = 1'b1;
    probes.instr.commit_instr_valid[0] = 1'b1;
    probes.instr.commit_instr_op[0]    = ADD;
    probes.instr.commit_pointer[0]     = 5'd5;
    tick();
    probes = '0;
    check(rvfi_instr[0].valid     === 1'b1,  "S3_ALU_VALID");
    check(rvfi_instr[0].mem_wmask === 8'h00, "S3_IDLE_LSU_NO_WMASK");
    check(rvfi_instr[0].mem_rmask === 8'h00, "S3_IDLE_LSU_NO_RMASK");

    $display("PASS tb_g6lc_rvfi_n1n2_hyp8 checked=%0d", checked);
    $finish;
  end
endmodule
