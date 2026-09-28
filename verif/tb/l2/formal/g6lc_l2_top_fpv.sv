// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Bounded formal harness for g6lc_l2_top (T9b posted writes).
//
//   P3  the request FSM never waits in S_BYPASS_B for a posted write —
//       posted writes leave after their last W beat and the tracker owns
//       the B channel; only blocking (ATOP/lock/FILL_ID-alias) writes may
//       wait there. FORMAL_MUT_P3 (applied to a generated RTL copy by
//       gen_support.py) drops the S_IDLE guard as the negative control.
//
// Reduced geometry keeps the proof bounded; AXI inputs are free variables
// so the solver explores every legal (and illegal) stimulus sequence —
// the property must hold either way.

module g6lc_l2_top_fpv
  import g6lc_l2_pkg::*;
  import g6lc_l2_tb_pkg::*;
(
    input  logic  clk_i,
    input  logic  rst_ni,
    input  req_t  slv_req_i,
    output resp_t slv_resp_o,
    input  resp_t mst_resp_i,
    output req_t  mst_req_o
);
  g6lc_l2_top #(
      .Enable        (1'b1),
      .BYTE_SIZE     (128),
      .SET_ASSOC     (2),
      .LINE_WIDTH    (128),
      .MSHR_DEPTH    (2),
      .DATA_BANKS    (2),
      .POSTED_WRITES (1'b1),
      .WTRK_DEPTH    (4),
      .RDTRK_DEPTH   (4),
      .AXI_ADDR_WIDTH (AW),
      .AXI_DATA_WIDTH (DW),
      .AXI_ID_WIDTH   (IDW),
      .AXI_USER_WIDTH (UW),
      .axi_req_t      (req_t),
      .axi_resp_t     (resp_t)
  ) dut (
      .clk_i,
      .rst_ni,
      .slv_req_i,
      .slv_resp_o,
      .mst_req_o,
      .mst_resp_i,
      .l2_hit_o            (),
      .l2_miss_o           (),
      .l2_bypass_o         (),
      .l2_mshr_full_o      (),
      .l2_bank_conflict_o  (),
      .l2_selfinv_hit_o    (),
      .l2_wupdate_o        (),
      .l2_wtrk_full_o      (),
      .l2_wtrk_line_hold_o (),
      .l2_hold_r1_o        (),
      .l2_hold_r1_wu_o     (),
      .l2_hold_r2_o        (),
      .l2_posted_o         (),
      .l2_rdtrk_o          (),
      .l2_posted_hold_o    (),
      .l2_evict_valid_o    (),
      .l2_evict_addr_o     (),
      .l2_evict_ready_i    (1'b1),
      .l2_back_inval_valid_i (1'b0),
      .l2_back_inval_addr_i  ('0),
      .l2_back_inval_ready_o (),
      .l2_write_idle_o       ()
  );

  // Start in reset so the unconstrained register initial state is forced
  // to the reset state (otherwise step-0 states are unreachable junk).
  logic f_past_valid = 1'b0;
  always @(posedge clk_i) f_past_valid <= 1'b1;
  always @(posedge clk_i) assume (f_past_valid || !rst_ni);

  // P3: state_q == S_BYPASS_B (enum ordinal 10) is only legal for a
  // blocking write — wr_posted_q set means the in-flight write took the
  // posted path and must have returned to S_IDLE after its last W beat.
  always @(posedge clk_i) begin
    if (rst_ni)
      assert (!(dut.gen_l2.state_q == 4'ha && dut.gen_l2.wr_posted_q));  // S_BYPASS_B
  end

endmodule
