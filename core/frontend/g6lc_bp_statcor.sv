// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Versions of this file released before 2026-08-05 were additionally available
// under Apache-2.0 WITH SHL-2.1; that grant is irrevocable for those versions.
//
// U1 statistical corrector (lite): a small PC-indexed confidence table that can
// invert a weak TAGE/base prediction. Trained on resolve.

module g6lc_bp_statcor
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type bht_update_t = logic,
    parameter int unsigned NR_ENTRIES = 64
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,
    input  logic                    flush_i,
    input  logic [CVA6Cfg.VLEN-1:0] vpc_i,
    input  bht_update_t             bht_update_i,
    input  bht_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0] pred_i,
    output bht_prediction_t [CVA6Cfg.INSTR_PER_FETCH-1:0] pred_o
);

  localparam int unsigned OFFSET = CVA6Cfg.RVC == 1'b1 ? 1 : 2;
  localparam int unsigned IDX_W = (NR_ENTRIES <= 1) ? 1 : $clog2(NR_ENTRIES);

  // Signed-ish 3-bit weight: MSB means "invert"
  logic [NR_ENTRIES-1:0][2:0] w_d, w_q;
  logic [IDX_W-1:0] idx, uidx;

  assign idx  = vpc_i[OFFSET+:IDX_W];
  assign uidx = bht_update_i.pc[OFFSET+:IDX_W];

  for (genvar i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin : gen_sc
    always_comb begin
      pred_o[i] = pred_i[i];
      // Invert when weight is strongly negative (ctr < 2) and pred valid
      if (pred_i[i].valid && w_q[idx] < 3'b010) begin
        pred_o[i].taken = ~pred_i[i].taken;
      end
    end
  end

  always_comb begin
    w_d = w_q;
    if (bht_update_i.valid) begin
      // Train toward correct absolute outcome: if taken, raise weight; else lower
      if (bht_update_i.taken) begin
        if (w_q[uidx] != 3'b111) w_d[uidx] = w_q[uidx] + 3'b001;
      end else begin
        if (w_q[uidx] != 3'b000) w_d[uidx] = w_q[uidx] - 3'b001;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) w_q <= '{default: 3'b100};
    else if (flush_i) w_q <= '{default: 3'b100};
    else w_q <= w_d;
  end

endmodule
