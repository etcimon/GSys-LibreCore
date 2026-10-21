// hyp8 provenance: ADAPTED (sv-timing emit at the 8-FO4 budget; P1/P2 lookup
// staging and the registered update record added for Hyp8)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Versions of this file released before 2026-08-05 were additionally available
// under Apache-2.0 WITH SHL-2.1; that grant is irrevocable for those versions.
//
// U1 loop (trip-count) predictor: remembers short backward branches that
// iterate N times then fall through. Overrides direction when confident.
//
// hyp8 staging (override path, rank 4):
//   P1 registers the lookup index and the window tag (full PC) at the
//   stage-B edge; P2 reads the selected row and splits the compare stage
//   (tag match + confidence) from the direction decision — both registered
//   as the {hit, dir} facts. The output merge in front of cf_select is then
//   a thin comb override, and the confidence/trip update on the resolve
//   side consumes the already-registered update record (the "update stage"
//   of the compare/update split). Table geometry, loop policy, takeover and
//   saturation rules are unchanged.

module g6lc_bp_loop
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter type bht_update_t = logic,
    parameter int unsigned NR_ENTRIES = 16
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,
    input  logic                    flush_i,
    input  logic [G6LCCfg.VLEN-1:0] vpc_i,
    // hyp8: registered update record (resolve+1, aligned with the checkpoint
    // entry read in g6lc_bp_top).
    input  bht_update_t             bht_update_i,
    // Base prediction in; possibly overridden out (thin comb merge at the
    // stage-S cycle off the registered P2 facts).
    input  bht_prediction_t [G6LCCfg.INSTR_PER_FETCH-1:0] pred_i,
    output bht_prediction_t [G6LCCfg.INSTR_PER_FETCH-1:0] pred_o
);

  // A139 design proposal; vocabulary: architecture/RTL-PIPELINE-PLANS.md.
  // svt-plan: begin g6lc_bp_loop status=proposal target=10-adjusted-FO4
  // svt-plan: cone indexed counter/tag read -> trip/confidence update ->
  // indexed write; prediction uses a separate selected-row read.
  // svt-plan: reshape compute each row's training next value locally,
  // then gate by uidx; preserve valid/tag takeover and saturation priorities.
  // svt-plan: boundary optional training address/outcome capture -> local
  // update; never pipeline a stale whole-row value over consecutive updates.
  // svt-plan: carry PC/tag, taken, valid and flush epoch; same-row updates
  // read the latest state or forward the prior pending update.
  // svt-plan: effect removes selected-row read mux from the write feedback;
  // bounded row banking reduces update-enable fanout if replication grows.
  // svt-plan: cost local update logic or a training register; learning delay
  // changes prediction timing, while immediate row-local form adds no interface cycle.
  // svt-plan: limit predictor read mux/tag compare remains; a lookup stage
  // must join frontend late-correction tokens, not return a previous PC's prediction.
  // svt-plan: end
  // Re-pipelining contract (sv-timing A128; 54.5 adjusted FO4 on the
  // Nangate45 board): loop predictor: table update state.
  // svt-pipe: require-contract
  // svt-pipe: protocol lp valid=flush_i
  // svt-pipe: no-cut on=mem_q
  // svt-pipe: cycle lp q=mem_q d=pred_o hold=flush_i steps=1

  localparam int unsigned OFFSET = G6LCCfg.RVC == 1'b1 ? 1 : 2;
  localparam int unsigned IDX_W = (NR_ENTRIES <= 1) ? 1 : $clog2(NR_ENTRIES);

  typedef struct packed {
    logic                    valid;
    logic [G6LCCfg.VLEN-1:0] tag;       // full PC for safety at small N
    logic [7:0]              trip;      // learned iteration count
    logic [7:0]              conf_cnt;  // current iteration within loop
    logic [1:0]              conf;      // confidence
  } loop_entry_t;

  loop_entry_t [NR_ENTRIES-1:0] mem_d, mem_q;
  logic [IDX_W-1:0] idx, uidx;

  // hyp8 P1: the lookup index and the window tag, registered at the stage-B
  // edge. Advisory data — killed windows are deadened downstream by the
  // epoch check, so no flush is applied to these registers.
  logic [IDX_W-1:0]        idx_q;
  logic [G6LCCfg.VLEN-1:0] vpc_q;

  assign idx  = vpc_i[OFFSET+:IDX_W];
  assign uidx = bht_update_i.pc[OFFSET+:IDX_W];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      idx_q <= '0;
      vpc_q <= '0;
    end else begin
      idx_q <= idx;
      vpc_q <= vpc_i;
    end
  end

  // hyp8 P2: the selected-row read and the compare stage (tag match +
  // confidence) run off the P1 registers; the {hit, dir} facts are the
  // registered verdict. The output merge at stage S is a thin comb override.
  loop_entry_t rd_row;
  assign rd_row = mem_q[idx_q];

  logic hit_q, dir_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      hit_q <= 1'b0;
      dir_q <= 1'b0;
    end else begin
      hit_q <= rd_row.valid && (rd_row.tag == vpc_q) && rd_row.conf[1];
      dir_q <= (rd_row.conf_cnt < rd_row.trip);
    end
  end

  // Prediction: if tag matches and confident, take while conf_cnt < trip.
  // Reference policy verbatim — the override owns slot 0 only.
  always_comb begin
    pred_o = pred_i;
    if (hit_q) begin
      pred_o[0].valid = 1'b1;
      pred_o[0].taken = dir_q;
    end
  end

  // A140: row-local training (the A135 emitted form, now in the shipped RTL).
  // Every row computes its own trained value from its registered entry and
  // the update, then the row selected by uidx takes it. The indexed read ->
  // compare/increment -> indexed write-decode dependency is gone; the write
  // select is a one-hot decode of uidx against a prepared row value. Same
  // next state as the indexed form for every row (matched-state equivalence
  // at 16/32 rows; A135 placed 1.911 -> 1.410 ns for the emitted copy).
  // hyp8: bht_update_i is the registered resolve record (resolve+1), so this
  // whole block is now register-sourced.
  // svt-pipe: row-local-applied train index=uidx rows=NR_ENTRIES banks=mem_q:mem_d max-rows=32
  // Per row, constant index. The tag compare is two 32-bit compares
  // (hyp8 VLEN is 64). 0 hold, 1 still-in-loop, 2 learn exit, 3 allocate.
  // The selected uidx row takes the trained value; the others hold.
  for (genvar r = 0; r < NR_ENTRIES; r++) begin : gen_train
    logic        hit_lo, hit_hi, hit_tag, same_trip, wr_row;
    logic [1:0]  tr_sel;
    logic        vld_n;
    logic [63:0] tag_n;
    logic [7:0]  cnt_n, trip_n;
    logic [1:0]  conf_n;
    assign hit_lo    = mem_q[r].tag[31:0] == bht_update_i.pc[31:0];
    assign hit_hi    = mem_q[r].tag[63:32] == bht_update_i.pc[63:32];
    assign hit_tag   = mem_q[r].valid && hit_lo && hit_hi;
    assign same_trip = mem_q[r].conf_cnt == mem_q[r].trip;
    always_comb begin
      if (hit_tag && bht_update_i.taken) tr_sel = 2'd1;
      else if (hit_tag)                  tr_sel = 2'd2;
      else if (bht_update_i.taken)       tr_sel = 2'd3;
      else                               tr_sel = 2'd0;
    end
    always_comb begin
      unique case (tr_sel)
        2'd1:    cnt_n = mem_q[r].conf_cnt + 8'd1;
        2'd2:    cnt_n = '0;
        2'd3:    cnt_n = 8'd1;
        default: cnt_n = mem_q[r].conf_cnt;
      endcase
    end
    always_comb begin
      unique case (tr_sel)
        2'd2:    trip_n = same_trip ? mem_q[r].trip : mem_q[r].conf_cnt;
        2'd3:    trip_n = 8'd1;
        default: trip_n = mem_q[r].trip;
      endcase
    end
    always_comb begin
      unique case (tr_sel)
        2'd2: begin
          if (same_trip)
            conf_n = (mem_q[r].conf == 2'b11) ? mem_q[r].conf : (mem_q[r].conf + 2'b01);
          else
            conf_n = (mem_q[r].conf == 2'b00) ? mem_q[r].conf : (mem_q[r].conf - 2'b01);
        end
        2'd3:    conf_n = 2'b01;
        default: conf_n = mem_q[r].conf;
      endcase
    end
    always_comb begin
      unique case (tr_sel)
        2'd3:    vld_n = 1'b1;
        default: vld_n = mem_q[r].valid;
      endcase
    end
    always_comb begin
      unique case (tr_sel)
        2'd3:    tag_n = bht_update_i.pc[63:0];
        default: tag_n = mem_q[r].tag[63:0];
      endcase
    end
    assign wr_row = bht_update_i.valid && (uidx == IDX_W'(r));
    assign mem_d[r].valid        = wr_row ? vld_n : mem_q[r].valid;
    assign mem_d[r].conf_cnt     = wr_row ? cnt_n : mem_q[r].conf_cnt;
    assign mem_d[r].trip         = wr_row ? trip_n : mem_q[r].trip;
    assign mem_d[r].conf         = wr_row ? conf_n : mem_q[r].conf;
    assign mem_d[r].tag[31:0]    = wr_row ? tag_n[31:0] : mem_q[r].tag[31:0];
    assign mem_d[r].tag[63:32]   = wr_row ? tag_n[63:32] : mem_q[r].tag[63:32];
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
