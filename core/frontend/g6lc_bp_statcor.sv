// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Versions of this file released before 2026-08-05 were additionally available
// under Apache-2.0 WITH SHL-2.1; that grant is irrevocable for those versions.
//
// U1 statistical corrector (lite): a small PC-indexed, PC-tagged outcome table
// that can override a valid TAGE/base prediction at strong confidence. Trained
// on resolve.
//
// T21 (2026-10-10): entries carry a partial tag of the branch address above
// the index bits. An override needs a tag hit: with 64 untagged rows over a
// 100 KB firmware every row was shared by dozens of branches and a saturated
// counter forced its direction onto every one of them (T18 moved the victims
// around by indexing per slot; it could not remove the aliasing). Training on
// a tag miss takes the row over only while its counter is weak; a strongly
// biased owner decays one step instead, so a rare alias cannot evict it.

module g6lc_bp_statcor
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type bht_update_t = logic,
    parameter int unsigned NR_ENTRIES = 64,
    parameter int unsigned TAG_BITS = 8
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
  localparam int unsigned TAG_LSB = OFFSET + IDX_W;

  if (IDX_W <= ROW_W) begin : gen_err_statcor_geometry
    $error("g6lc_bp_statcor: NR_ENTRIES must exceed INSTR_PER_FETCH so every slot owns a counter");
  end
  if (TAG_BITS == 0 || TAG_LSB + TAG_BITS > CVA6Cfg.VLEN) begin : gen_err_statcor_tag
    $error("g6lc_bp_statcor: TAG_BITS must be 1..VLEN-OFFSET-IDX_W");
  end

  // Unsigned 3-bit taken-outcome counter; reset is neutral. valid + tag own
  // the row.
  logic [NR_ENTRIES-1:0][2:0] w_d, w_q;
  logic [NR_ENTRIES-1:0][TAG_BITS-1:0] tag_d, tag_q;
  logic [NR_ENTRIES-1:0] v_d, v_q;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0][IDX_W-1:0] idx;
  logic [IDX_W-1:0] uidx;
  logic [TAG_BITS-1:0] utag, ptag;

  // T18: index per SLOT with that slot's own address bits, the same bits the
  // resolving branch trains with (uidx). The tag is the address above the
  // index; every slot of an aligned window shares it.
  assign uidx = bht_update_i.pc[OFFSET+:IDX_W];
  assign utag = bht_update_i.pc[TAG_LSB+:TAG_BITS];
  assign ptag = vpc_i[TAG_LSB+:TAG_BITS];

  for (genvar i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin : gen_sc
    if (ROW_W == 0) begin : gen_idx_single
      assign idx[i] = vpc_i[OFFSET+:IDX_W];
    end else begin : gen_idx_slot
      assign idx[i] = {vpc_i[OFFSET+ROW_W+:(IDX_W-ROW_W)], ROW_W'(i)};
    end
    always_comb begin
      pred_o[i] = pred_i[i];
      // Strong absolute bias overrides direction only for valid predictions
      // and only for the branch that owns the row.
      if (pred_i[i].valid && v_q[idx[i]] && tag_q[idx[i]] == ptag) begin
        if (w_q[idx[i]] < 3'b010) pred_o[i].taken = 1'b0;
        else if (w_q[idx[i]] > 3'b101) pred_o[i].taken = 1'b1;
      end
    end
  end

  always_comb begin
    w_d   = w_q;
    tag_d = tag_q;
    v_d   = v_q;
    if (bht_update_i.valid) begin
      if (v_q[uidx] && tag_q[uidx] == utag) begin
        // Owner: train toward the absolute outcome.
        if (bht_update_i.taken) begin
          if (w_q[uidx] != 3'b111) w_d[uidx] = w_q[uidx] + 3'b001;
        end else begin
          if (w_q[uidx] != 3'b000) w_d[uidx] = w_q[uidx] - 3'b001;
        end
      end else if (!v_q[uidx] || (w_q[uidx] >= 3'b011 && w_q[uidx] <= 3'b101)) begin
        // Free or weakly held row: take it over, one step from neutral.
        v_d[uidx]   = 1'b1;
        tag_d[uidx] = utag;
        w_d[uidx]   = bht_update_i.taken ? 3'b101 : 3'b011;
      end else begin
        // Strongly held by another branch: decay toward neutral.
        w_d[uidx] = (w_q[uidx] > 3'b100) ? w_q[uidx] - 3'b001 : w_q[uidx] + 3'b001;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      w_q   <= '{default: 3'b100};
      tag_q <= '0;
      v_q   <= '0;
    end else if (flush_i) begin
      w_q   <= '{default: 3'b100};
      tag_q <= '0;
      v_q   <= '0;
    end else begin
      w_q   <= w_d;
      tag_q <= tag_d;
      v_q   <= v_d;
    end
  end

endmodule
