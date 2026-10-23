// hyp8 provenance: REWRITTEN (registered cross-bank wakeup interconnect)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_iq_xbar -- registered cross-bank wake-tag interconnect
// (analysis/g6lc_iq.md). Every bank's producer broadcasts (up to NTAKE per
// cycle, one per take port) are captured into a register stage and
// redistributed to every bank, so a cross-bank consumer sees the tag one
// cycle after the producer is taken (+1 wakeup latency across banks; the
// same-bank local copy is combinational inside g6lc_iq_bank). A broadcast
// whose producer gets cancelled is harmless: the tag only ever sets rdy,
// and a cancelled op's late result can never complete because the WB-side
// gates (dispatch wb_value_valid, PRF write enable) already mask the tid.

module g6lc_iq_xbar #(
    parameter int unsigned BANKS  = 8,
    parameter int unsigned NTAKE  = 2,
    parameter int unsigned PRF_W  = 6,
    parameter int unsigned FPRF_W = 1,
    parameter int unsigned TID_W  = 5,
    // Countdown width shared with g6lc_iq's WAKE_W derivation.
    parameter int unsigned WAKE_W = 3
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,
    // Per-bank broadcast records (per take port).
    input  logic [BANKS-1:0][NTAKE-1:0]            b_v_i,
    input  logic [BANKS-1:0][NTAKE-1:0][PRF_W-1:0]  b_prd_i,
    input  logic [BANKS-1:0][NTAKE-1:0][FPRF_W-1:0] b_fprd_i,
    input  logic [BANKS-1:0][NTAKE-1:0]            b_fp_i,
    input  logic [BANKS-1:0][NTAKE-1:0][WAKE_W-1:0] b_cnt_i,
    // hyp8 g7: producer identity + class for the ptid forward and the
    // low-producer consumer-class gate.
    input  logic [BANKS-1:0][NTAKE-1:0][TID_W-1:0] b_tid_i,
    input  logic [BANKS-1:0][NTAKE-1:0]            b_alu_i,
    input  logic [BANKS-1:0][NTAKE-1:0]            b_lo_i,
    // Flattened registered broadcast bus every bank snoops.
    output logic [BANKS*NTAKE-1:0]                 xw_v_o,
    output logic [BANKS*NTAKE-1:0][PRF_W-1:0]      xw_prd_o,
    output logic [BANKS*NTAKE-1:0][FPRF_W-1:0]     xw_fprd_o,
    output logic [BANKS*NTAKE-1:0]                 xw_fp_o,
    output logic [BANKS*NTAKE-1:0][WAKE_W-1:0]     xw_cnt_o,
    output logic [BANKS*NTAKE-1:0][TID_W-1:0]      xw_tid_o,
    output logic [BANKS*NTAKE-1:0]                 xw_alu_o,
    output logic [BANKS*NTAKE-1:0]                 xw_lo_o
);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      xw_v_o <= '0;
      xw_prd_o <= '0;
      xw_fprd_o <= '0;
      xw_fp_o <= '0;
      xw_cnt_o <= '0;
      xw_tid_o <= '0;
      xw_alu_o <= '0;
      xw_lo_o <= '0;
    end else if (flush_i) begin
      xw_v_o <= '0;
    end else begin
      xw_v_o    <= b_v_i;
      xw_prd_o  <= b_prd_i;
      xw_fprd_o <= b_fprd_i;
      xw_fp_o   <= b_fp_i;
      xw_cnt_o  <= b_cnt_i;
      xw_tid_o  <= b_tid_i;
      xw_alu_o  <= b_alu_i;
      xw_lo_o   <= b_lo_i;
    end
  end

endmodule
