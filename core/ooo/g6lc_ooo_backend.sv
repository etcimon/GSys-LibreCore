// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U5 production OoO backend bundle (RAT + freelist + PRF + ROB).
// Instantiated only when CVA6Cfg.OoOEn==1. Not yet in the critical
// issue/commit path — identity pipeline remains scoreboard-based until
// U5.1–U5.2 wire-up. Exists so sizing/synthesis/area loops can run early.

module g6lc_ooo_backend
  import g6lc_ooo_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type entry_t = logic
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,
    // Minimal probe ports for future wiring / formal
    input  logic             alloc_i,
    input  logic [4:0]       rd_i,
    input  logic [4:0]       rs1_i,
    input  logic [4:0]       rs2_i,
    output logic             freelist_empty_o,
    output logic             rob_full_o
);

  localparam int unsigned ROB_N = (CVA6Cfg.RobEntries == 0) ? CVA6Cfg.NR_SB_ENTRIES
                                                            : CVA6Cfg.RobEntries;
  localparam int unsigned PRF_N = (CVA6Cfg.PrfEntries == 0) ? (32 + ROB_N + 8)
                                                            : CVA6Cfg.PrfEntries;
  localparam int unsigned PRF_W = ooo_prf_w(PRF_N);
  localparam int unsigned ROB_W = ooo_rob_w(ROB_N);
  localparam int unsigned CKPT  = (CVA6Cfg.BPCkptDepth == 0) ? 8 : CVA6Cfg.BPCkptDepth;

  logic [PRF_W-1:0] prs1, prs2, prd_old, alloc_prd;
  logic [PRF_W-1:0] free_prd;
  logic free_en;

  g6lc_freelist #(
      .PRF_ENTRIES(PRF_N),
      .PRF_W      (PRF_W)
  ) i_fl (
      .clk_i,
      .rst_ni,
      .flush_i,
      .alloc_i,
      .alloc_prd_o(alloc_prd),
      .empty_o    (freelist_empty_o),
      .free_i     (free_en),
      .free_prd_i (free_prd)
  );

  g6lc_rat #(
      .NR_ARCH   (32),
      .PRF_W     (PRF_W),
      .CKPT_DEPTH(CKPT)
  ) i_rat (
      .clk_i,
      .rst_ni,
      .flush_i,
      .rs1_i,
      .rs2_i,
      .rd_i,
      .prs1_o   (prs1),
      .prs2_o   (prs2),
      .prd_old_o(prd_old),
      .alloc_i,
      .alloc_prd_i(alloc_prd),
      .ckpt_push_i   (1'b0),
      .ckpt_restore_i(1'b0),
      .ckpt_empty_o  ()
  );

  // PRF held for area/timing probing; ports idle until U5.1 wire-up
  logic [CVA6Cfg.NrIssuePorts*2-1:0][PRF_W-1:0] raddr;
  logic [CVA6Cfg.NrIssuePorts*2-1:0][CVA6Cfg.XLEN-1:0] rdata;
  assign raddr = '0;

  g6lc_prf #(
      .DATA_WIDTH (CVA6Cfg.XLEN),
      .PRF_ENTRIES(PRF_N),
      .NR_READ    (CVA6Cfg.NrIssuePorts * 2),
      .NR_WRITE   (CVA6Cfg.NrWbPorts),
      .PRF_W      (PRF_W)
  ) i_prf (
      .clk_i,
      .rst_ni,
      .raddr_i(raddr),
      .rdata_o(rdata),
      .waddr_i('0),
      .wdata_i('0),
      .we_i   ('0)
  );

  g6lc_rob #(
      .ROB_ENTRIES(ROB_N),
      .ROB_W      (ROB_W),
      .NR_ALLOC   (CVA6Cfg.NrIssuePorts),
      .NR_RETIRE  (CVA6Cfg.NrCommitPorts),
      .NR_COMPLETE(CVA6Cfg.NrWbPorts),
      .TID_W      (CVA6Cfg.TRANS_ID_BITS),
      .NR_SB      (CVA6Cfg.NR_SB_ENTRIES),
      .entry_t    (entry_t)
  ) i_rob (
      .clk_i,
      .rst_ni,
      .flush_i,
      .cancelled_mask_i('0),
      .alloc_valid_i ('0),
      .alloc_entry_i ('0),
      .alloc_tid_i   ('0),
      .alloc_id_o    (),
      .full_o        (rob_full_o),
      .complete_valid_i('0),
      .complete_tid_i  ('0),
      .complete_exc_i  ('0),
      .retire_valid_o(),
      .retire_entry_o(),
      .retire_id_o   (),
      .retire_ack_i  ('0)
  );

  // Free old mapping when we would retire (stub: free on alloc of same rd for now)
  assign free_en  = alloc_i && (rd_i != 5'd0);
  assign free_prd = prd_old;

  // Keep unused nets from being optimized in a way that drops hierarchy intent
  logic _unused;
  assign _unused = |prs1 | |prs2 | |rdata;

endmodule
