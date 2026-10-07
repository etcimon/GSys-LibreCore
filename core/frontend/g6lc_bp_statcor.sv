// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Versions of this file released before 2026-08-05 were additionally available
// under Apache-2.0 WITH SHL-2.1; that grant is irrevocable for those versions.
//
// U1 statistical corrector (lite): a small PC-indexed outcome table that can
// override a valid TAGE/base prediction at strong confidence. Trained on resolve.

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
  // Slot bits of an instruction address inside the fetch window: slot i of
  // the window at vpc_i sits at address {vpc_i[..], i}, exactly as the BHT
  // rows are addressed.
  localparam int unsigned ROW_W = (CVA6Cfg.INSTR_PER_FETCH > 1) ? $clog2(CVA6Cfg.INSTR_PER_FETCH) : 0;

  if (IDX_W <= ROW_W) begin : gen_err_statcor_geometry
    $error("g6lc_bp_statcor: NR_ENTRIES must exceed INSTR_PER_FETCH so every slot owns a counter");
  end

  // Unsigned 3-bit taken-outcome counter; reset is neutral.
  logic [NR_ENTRIES-1:0][2:0] w_d, w_q;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0][IDX_W-1:0] idx;
  logic [IDX_W-1:0] uidx;

  // T18: index per SLOT with that slot's own address bits, the same bits the
  // resolving branch trains with (uidx). Indexing every slot with the window
  // base aliased all slots of a window onto one counter that another
  // branch had trained: a saturated taken bne at fdt_next_node forced a
  // never-taken bltu in a neighbouring window taken on every libfdt call
  // (8-16-cycle refetch each), and the victim could never retrain its
  // own counter.
  assign uidx = bht_update_i.pc[OFFSET+:IDX_W];

  for (genvar i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin : gen_sc
    if (ROW_W == 0) begin : gen_idx_single
      assign idx[i] = vpc_i[OFFSET+:IDX_W];
    end else begin : gen_idx_slot
      assign idx[i] = {vpc_i[OFFSET+ROW_W+:(IDX_W-ROW_W)], ROW_W'(i)};
    end
    always_comb begin
      pred_o[i] = pred_i[i];
      // Strong absolute bias overrides direction only for valid predictions.
      if (pred_i[i].valid && w_q[idx[i]] < 3'b010) begin
        pred_o[i].taken = 1'b0;
      end else if (pred_i[i].valid && w_q[idx[i]] > 3'b101) begin
        pred_o[i].taken = 1'b1;
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
