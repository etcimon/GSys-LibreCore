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

  localparam int unsigned OFFSET   = CVA6Cfg.RVC == 1'b1 ? 1 : 2;
  localparam int unsigned IDX_W    = (NR_ENTRIES <= 1) ? 1 : $clog2(NR_ENTRIES);
  localparam int unsigned COL_BITS = (CVA6Cfg.INSTR_PER_FETCH <= 1) ? 0 : $clog2(CVA6Cfg.INSTR_PER_FETCH);

  typedef struct packed {
    logic                    valid;
    logic [CVA6Cfg.VLEN-1:0] tag;       // full PC for safety at small N
    logic [7:0]              trip;      // learned iteration count
    logic [7:0]              conf_cnt;  // current iteration within loop
    logic [1:0]              conf;      // confidence
  } loop_entry_t;

  loop_entry_t [NR_ENTRIES-1:0] mem_d, mem_q;
  logic [IDX_W-1:0] uidx;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0][CVA6Cfg.VLEN-1:0] slot_pc;
  logic [CVA6Cfg.INSTR_PER_FETCH-1:0][IDX_W-1:0]        slot_idx;

  assign uidx = bht_update_i.pc[OFFSET+:IDX_W];
  for (genvar i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin : gen_slot_pc
    if (COL_BITS == 0) begin : gen_sp_single
      assign slot_pc[i] = vpc_i;
    end else begin : gen_sp_col
      assign slot_pc[i] = {vpc_i[CVA6Cfg.VLEN-1:OFFSET+COL_BITS], COL_BITS'(i), {OFFSET{1'b0}}};
    end
    assign slot_idx[i] = slot_pc[i][OFFSET+:IDX_W];
  end

  // Prediction: per-slot column match (T21e parity) with saturated trip guard
  always_comb begin
    pred_o = pred_i;
    for (int unsigned i = 0; i < CVA6Cfg.INSTR_PER_FETCH; i++) begin
      if (mem_q[slot_idx[i]].valid && mem_q[slot_idx[i]].tag == slot_pc[i] &&
          mem_q[slot_idx[i]].conf[1] &&
          (mem_q[slot_idx[i]].trip != 8'd0) && (mem_q[slot_idx[i]].trip != 8'hFF)) begin
        pred_o[i].valid = 1'b1;
        pred_o[i].taken = (mem_q[slot_idx[i]].conf_cnt < mem_q[slot_idx[i]].trip);
      end
    end
  end

  // A140: row-local training (the A135 emitted form, now in the shipped RTL).
  // Every row computes its own trained value from its registered entry and
  // the update, then the row selected by uidx takes it. The indexed read ->
  // compare/increment -> indexed write-decode dependency is gone; the write
  // select is a one-hot decode of uidx against a prepared row value. Same
  // next state as the indexed form for every row (matched-state equivalence
  // at 16/32 rows; A135 placed 1.911 -> 1.410 ns for the emitted copy).
  // svt-pipe: row-local-applied train index=uidx rows=NR_ENTRIES banks=mem_q:mem_d max-rows=32
  loop_entry_t [NR_ENTRIES-1:0] mem_train;
  always_comb begin
    for (int unsigned r = 0; r < NR_ENTRIES; r++) begin
      mem_train[r] = mem_q[r];
      if (mem_q[r].valid && mem_q[r].tag == bht_update_i.pc) begin
        if (bht_update_i.taken) begin
          // Still in loop (saturate at 8'hFF so >255-iter loops never wrap to 0)
          mem_train[r].conf_cnt = (mem_q[r].conf_cnt == 8'hFF) ? 8'hFF : (mem_q[r].conf_cnt + 8'd1);
        end else begin
          // Exit: learn trip count
          if (mem_q[r].conf_cnt == mem_q[r].trip) begin
            if (mem_q[r].conf != 2'b11) mem_train[r].conf = mem_q[r].conf + 2'b01;
          end else begin
            mem_train[r].trip = mem_q[r].conf_cnt;
            if (mem_q[r].conf != 2'b00) mem_train[r].conf = mem_q[r].conf - 2'b01;
          end
          mem_train[r].conf_cnt = '0;
        end
      end else if (bht_update_i.taken) begin
        // Allocate / replace
        mem_train[r].valid    = 1'b1;
        mem_train[r].tag      = bht_update_i.pc;
        mem_train[r].trip     = 8'd1;
        mem_train[r].conf_cnt = 8'd1;
        mem_train[r].conf     = 2'b01;
      end
    end
  end

  always_comb begin
    mem_d = mem_q;
    if (bht_update_i.valid) begin
      for (int unsigned r = 0; r < NR_ENTRIES; r++)
        if (uidx == IDX_W'(r)) mem_d[r] = mem_train[r];
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
