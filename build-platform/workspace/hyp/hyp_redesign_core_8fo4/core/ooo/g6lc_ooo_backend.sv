// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U5 production OoO backend bundle (RAT + freelist + PRF + ROB).
// Instantiated only when G6LCCfg.OoOEn==1. Not yet in the critical
// issue/commit path — identity pipeline remains scoreboard-based until
// U5.1–U5.2 wire-up. Exists so sizing/synthesis/area loops can run early.

module g6lc_ooo_backend
  import g6lc_ooo_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
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

  localparam int unsigned ROB_N = (G6LCCfg.RobEntries == 0) ? G6LCCfg.NR_SB_ENTRIES
                                                            : G6LCCfg.RobEntries;
  localparam int unsigned PRF_N = (G6LCCfg.PrfEntries == 0) ? (32 + ROB_N + 8)
                                                            : G6LCCfg.PrfEntries;
  localparam int unsigned PRF_W = ooo_prf_w(PRF_N);
  localparam int unsigned ROB_W = ooo_rob_w(ROB_N);
  localparam int unsigned CKPT  = (G6LCCfg.BPCkptDepth == 0) ? 8 : G6LCCfg.BPCkptDepth;

  logic [PRF_W-1:0] prs1, prs2, prd_old, alloc_prd;
  logic [PRF_W-1:0] free_prd;
  logic free_en;

  // hyp8 (group 4/5): the freelist is now the banked multi-lane cell; this
  // probe uses lane 0 / free port 0 of a single-bank configuration.
  logic [31:0] fl_avail_cnt;
  g6lc_freelist #(
      .PRF_ENTRIES(PRF_N),
      .PRF_W      (PRF_W),
      .NR_LANES   (1),
      .NR_FREE    (1),
      .BANKS      (1)
  ) i_fl (
      .clk_i,
      .rst_ni,
      .flush_i,
      .pick_req_i  (alloc_i),
      .pick_o      (alloc_prd),
      .pick_avail_o(),
      .commit_i    (alloc_i),
      .commit_prd_i(alloc_prd),
      .release_i   ('0),
      .release_prd_i('0),
      .free_i      (free_en),
      .free_prd_i  (free_prd),
      .repair_i    (1'b0),
      .repair_mask_i('0),
      .restore_i   (1'b0),
      .restore_mask_i('0),
      .avail_cnt_o (fl_avail_cnt),
      .empty_o     (freelist_empty_o)
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
  logic [G6LCCfg.NrIssuePorts*2-1:0][PRF_W-1:0] raddr;
  logic [G6LCCfg.NrIssuePorts*2-1:0][G6LCCfg.XLEN-1:0] rdata;
  assign raddr = '0;

  g6lc_prf #(
      .DATA_WIDTH (G6LCCfg.XLEN),
      .PRF_ENTRIES(PRF_N),
      .NR_READ    (G6LCCfg.NrIssuePorts * 2),
      .NR_WRITE   (G6LCCfg.NrWbPorts),
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
      .NR_ALLOC   (G6LCCfg.NrIssuePorts),
      .NR_RETIRE  (G6LCCfg.NrCommitPorts),
      .NR_COMPLETE(G6LCCfg.NrWbPorts),
      .TID_W      (G6LCCfg.TRANS_ID_BITS),
      .NR_SB      (G6LCCfg.NR_SB_ENTRIES),
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
      .empty_o       (),
      .complete_valid_i('0),
      .complete_tid_i  ('0),
      .complete_exc_i  ('0),
      .retire_valid_o(),
      .retire_entry_o(),
      .retire_id_o   (),
      .retire_ack_i  ('0),
      .retire_tid_i  ('0)
  );

  // Free old mapping when we would retire (stub: free on alloc of same rd for now)
  assign free_en  = alloc_i && (rd_i != 5'd0);
  assign free_prd = prd_old;

  // Keep unused nets from being optimized in a way that drops hierarchy intent
  logic _unused;
  assign _unused = |prs1 | |prs2 | |rdata;

endmodule
