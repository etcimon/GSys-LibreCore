// hyp8 provenance: ADAPTED (sv-timing emit at the 8-FO4 budget; P1/P2 lookup
// staging and the registered update record added for Hyp8)
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
//
// hyp8 staging (override path, rank 4): same contract as the rest of the
// fabric — P1 registers the per-slot index and the window tag at the stage-B
// edge; P2 reads the rows and registers the compare facts {hit, strong-lo,
// strong-hi}; the override merge in front of cf_select is a thin comb pass.
// bht_update_i is the registered resolve record (resolve+1); index/tag are
// raw PC slices (recompute-free — no folded hash to carry).

module g6lc_bp_statcor
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter type bht_update_t = logic,
    parameter int unsigned NR_ENTRIES = 64,
    parameter int unsigned TAG_BITS = 8
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,
    input  logic                    flush_i,
    input  logic [G6LCCfg.VLEN-1:0] vpc_i,
    // hyp8: registered update record (resolve+1).
    input  bht_update_t             bht_update_i,
    input  bht_prediction_t [G6LCCfg.INSTR_PER_FETCH-1:0] pred_i,
    output bht_prediction_t [G6LCCfg.INSTR_PER_FETCH-1:0] pred_o
);

  // A139 design proposal; vocabulary: architecture/RTL-PIPELINE-PLANS.md.
  // svt-plan: begin g6lc_bp_statcor status=proposal target=10-adjusted-FO4
  // svt-plan: cone training is already row-local; remaining candidates are
  // lookup tag/weight selection and update/decay distribution.
  // svt-plan: reshape bank lookup, compute local hit/weight candidates,
  // then merge before correction; localize decay/update enables per bank.
  // svt-plan: boundary optional local lookup -> correction decision;
  // keep training independent, using latest row state for every saturation update.
  // svt-plan: carry query PC/slot, base prediction, hart/history/fetch
  // epoch through correction; flush invalidates pending correction and training.
  // svt-plan: effect bounds lookup mux fan-in; no claimed gain for redoing
  // the existing per-row update transformation.
  // svt-plan: cost candidate registers and late-correction latency; preserve
  // tag collision/takeover and update-versus-decay priority.
  // svt-plan: limit a correction arriving after fetch must use the frontend
  // correction protocol rather than overwrite a newer window's prediction.
  // svt-plan: end
  // Re-pipelining contract (sv-timing A128; 60.9 adjusted FO4 on the
  // Nangate45 board): statistical corrector: table update state.
  // svt-pipe: require-contract
  // svt-pipe: protocol sc valid=flush_i
  // svt-pipe: no-cut on=tag_q
  // svt-pipe: cycle sc q=tag_q d=pred_o hold=flush_i steps=1
  // A134: each row prepares its own next counter/tag state, selected by the
  // update index. This removes the indexed read -> train -> indexed write
  // feedback chain without delaying training or changing prediction latency.

  localparam int unsigned OFFSET = G6LCCfg.RVC == 1'b1 ? 1 : 2;
  localparam int unsigned IDX_W = (NR_ENTRIES <= 1) ? 1 : $clog2(NR_ENTRIES);
  // Slot bits of an instruction address inside the fetch window: slot i of
  // the window at vpc_i sits at address {vpc_i[..], i}, exactly as the BHT
  // rows are addressed.
  localparam int unsigned ROW_W = (G6LCCfg.INSTR_PER_FETCH > 1) ? $clog2(G6LCCfg.INSTR_PER_FETCH) : 0;
  localparam int unsigned TAG_LSB = OFFSET + IDX_W;

  if (IDX_W <= ROW_W) begin : gen_err_statcor_geometry
    $error("g6lc_bp_statcor: NR_ENTRIES must exceed INSTR_PER_FETCH so every slot owns a counter");
  end
  if (TAG_BITS == 0 || TAG_LSB + TAG_BITS > G6LCCfg.VLEN) begin : gen_err_statcor_tag
    $error("g6lc_bp_statcor: TAG_BITS must be 1..VLEN-OFFSET-IDX_W");
  end

  // Unsigned 3-bit taken-outcome counter; reset is neutral. valid + tag own
  // the row.
  logic [NR_ENTRIES-1:0][2:0] w_d, w_q;
  logic [NR_ENTRIES-1:0][TAG_BITS-1:0] tag_d, tag_q;
  logic [NR_ENTRIES-1:0] v_d, v_q;
  // hyp8 P1 comb hash + its registers.
  logic [G6LCCfg.INSTR_PER_FETCH-1:0][IDX_W-1:0] idx_c, idx_q;
  logic [IDX_W-1:0] uidx;
  logic [TAG_BITS-1:0] utag, ptag_c;
  logic [TAG_BITS-1:0] ptag_q;

  // T18: index per SLOT with that slot's own address bits, the same bits the
  // resolving branch trains with (uidx). The tag is the address above the
  // index; every slot of an aligned window shares it.
  assign uidx   = bht_update_i.pc[OFFSET+:IDX_W];
  assign utag   = bht_update_i.pc[TAG_LSB+:TAG_BITS];
  assign ptag_c = vpc_i[TAG_LSB+:TAG_BITS];

  for (genvar i = 0; i < G6LCCfg.INSTR_PER_FETCH; i++) begin : gen_sc_idx
    if (ROW_W == 0) begin : gen_idx_single
      assign idx_c[i] = vpc_i[OFFSET+:IDX_W];
    end else begin : gen_idx_slot
      assign idx_c[i] = {vpc_i[OFFSET+ROW_W+:(IDX_W-ROW_W)], ROW_W'(i)};
    end
  end

  // hyp8 P1 registers (advisory data — epoch-deadened downstream, no flush).
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      idx_q  <= '0;
      ptag_q <= '0;
    end else begin
      idx_q  <= idx_c;
      ptag_q <= ptag_c;
    end
  end

  // hyp8 P2: row read + tag compare + confidence weight off the P1 registers,
  // registered as the per-slot override facts.
  logic [G6LCCfg.INSTR_PER_FETCH-1:0] sc_hit_c, sc_lo_c, sc_hi_c;
  logic [G6LCCfg.INSTR_PER_FETCH-1:0] sc_hit_q, sc_lo_q, sc_hi_q;
  for (genvar i = 0; i < G6LCCfg.INSTR_PER_FETCH; i++) begin : gen_sc_facts
    assign sc_hit_c[i] = v_q[idx_q[i]] && (tag_q[idx_q[i]] == ptag_q);
    assign sc_lo_c[i]  = (w_q[idx_q[i]] < 3'b010);
    assign sc_hi_c[i]  = (w_q[idx_q[i]] > 3'b101);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      sc_hit_q <= '0;
      sc_lo_q  <= '0;
      sc_hi_q  <= '0;
    end else begin
      sc_hit_q <= sc_hit_c;
      sc_lo_q  <= sc_lo_c;
      sc_hi_q  <= sc_hi_c;
    end
  end

  // Strong absolute bias overrides direction only for valid predictions
  // and only for the branch that owns the row. Reference policy verbatim —
  // now a thin comb merge off the registered facts.
  for (genvar i = 0; i < G6LCCfg.INSTR_PER_FETCH; i++) begin : gen_sc
    always_comb begin
      pred_o[i] = pred_i[i];
      if (pred_i[i].valid && sc_hit_q[i]) begin
        if (sc_lo_q[i]) pred_o[i].taken = 1'b0;
        else if (sc_hi_q[i]) pred_o[i].taken = 1'b1;
      end
    end
  end

  always_comb begin
    w_d   = w_q;
    tag_d = tag_q;
    v_d   = v_q;
    for (int unsigned row = 0; row < NR_ENTRIES; row++) begin
      if (bht_update_i.valid && uidx == IDX_W'(row)) begin
        if (v_q[row] && tag_q[row] == utag) begin
          // Owner: train toward the absolute outcome.
          if (bht_update_i.taken) begin
            if (w_q[row] != 3'b111) w_d[row] = w_q[row] + 3'b001;
          end else begin
            if (w_q[row] != 3'b000) w_d[row] = w_q[row] - 3'b001;
          end
        end else if (!v_q[row] || (w_q[row] >= 3'b011 && w_q[row] <= 3'b101)) begin
          // Free or weakly held row: take it over, one step from neutral.
          v_d[row]   = 1'b1;
          tag_d[row] = utag;
          w_d[row]   = bht_update_i.taken ? 3'b101 : 3'b011;
        end else begin
          // Strongly held by another branch: decay toward neutral.
          w_d[row] = (w_q[row] > 3'b100) ? w_q[row] - 3'b001 : w_q[row] + 3'b001;
        end
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
