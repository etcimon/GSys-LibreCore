// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Versions of this file released before 2026-08-05 were additionally available
// under Apache-2.0 WITH SHL-2.1; that grant is irrevocable for those versions.
//
// U1 loop (trip-count) predictor: remembers short backward branches that
// iterate N times then fall through. Overrides direction when confident.

module g6lc_bp_loop
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type bht_update_t = logic,
    parameter int unsigned NR_ENTRIES = 16
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,
    input  logic                    flush_i,
    input  logic [CVA6Cfg.VLEN-1:0] vpc_i,
    input  bht_update_t             bht_update_i,
    // Base prediction in; possibly overridden out
    input  bht_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0] pred_i,
    output bht_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0] pred_o
);

  localparam int unsigned OFFSET = CVA6Cfg.RVC == 1'b1 ? 1 : 2;
  localparam int unsigned IDX_W = (NR_ENTRIES <= 1) ? 1 : $clog2(NR_ENTRIES);

  typedef struct packed {
    logic                    valid;
    logic [CVA6Cfg.VLEN-1:0] tag;       // full PC for safety at small N
    logic [7:0]              trip;      // learned iteration count
    logic [7:0]              conf_cnt;  // current iteration within loop
    logic [1:0]              conf;      // confidence
  } loop_entry_t;

  loop_entry_t [NR_ENTRIES-1:0] mem_d, mem_q;
  logic [IDX_W-1:0] idx, uidx;

  assign idx  = vpc_i[OFFSET+:IDX_W];
  assign uidx = bht_update_i.pc[OFFSET+:IDX_W];

  // Prediction: if tag matches and confident, take while conf_cnt < trip
  always_comb begin
    pred_o = pred_i;
    if (mem_q[idx].valid && mem_q[idx].tag == vpc_i && mem_q[idx].conf[1]) begin
      pred_o[0].valid = 1'b1;
      pred_o[0].taken = (mem_q[idx].conf_cnt < mem_q[idx].trip);
    end
  end

  always_comb begin
    mem_d = mem_q;
    if (bht_update_i.valid) begin
      if (mem_q[uidx].valid && mem_q[uidx].tag == bht_update_i.pc) begin
        if (bht_update_i.taken) begin
          // Still in loop
          mem_d[uidx].conf_cnt = mem_q[uidx].conf_cnt + 8'd1;
        end else begin
          // Exit: learn trip count
          if (mem_q[uidx].conf_cnt == mem_q[uidx].trip) begin
            if (mem_q[uidx].conf != 2'b11) mem_d[uidx].conf = mem_q[uidx].conf + 2'b01;
          end else begin
            mem_d[uidx].trip = mem_q[uidx].conf_cnt;
            if (mem_q[uidx].conf != 2'b00) mem_d[uidx].conf = mem_q[uidx].conf - 2'b01;
          end
          mem_d[uidx].conf_cnt = '0;
        end
      end else if (bht_update_i.taken) begin
        // Allocate / replace
        mem_d[uidx].valid    = 1'b1;
        mem_d[uidx].tag      = bht_update_i.pc;
        mem_d[uidx].trip     = 8'd1;
        mem_d[uidx].conf_cnt = 8'd1;
        mem_d[uidx].conf     = 2'b01;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) mem_q <= '0;
    else if (flush_i) begin
      for (int unsigned i = 0; i < NR_ENTRIES; i++) begin
        mem_q[i].valid    <= 1'b0;
        mem_q[i].conf_cnt <= '0;
      end
    end else mem_q <= mem_d;
  end

endmodule
