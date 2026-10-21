// hyp8 provenance: ADAPTED (sv-timing emit at the 8-FO4 budget)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U5.4 / FSE S3 store-set memory dependence predictor.
// - Trains on store dispatch (multi-port)
// - Trains load PCs on a real memory-order violation (train_valid_i/train_pc_i
//   carry the LSQ's violating-load report)
// - Queried at dispatch (ld_query_i/ld_pc_i); the verdict relaxes the IQ's
//   older-unresolved-store gate for the dispatched load only
// - Flushes on full flush or mispredict (caller ORs mispredict into flush_i)
// When enable_i=0 (MemDepPredEn=0 and not forced by OoO), never stalls.
//
// hyp8 (group 4/5): the dispatch-stage query is registered -- ld_query_i /
// ld_pc_i / store_pending_i are captured, the verdict lookup runs on the
// registered query, and predict_o / stall_o are registered outputs one cycle
// after the query (the verdict rides the rename R1->R2 stage into the
// dispatch group; a query answered one cycle late is conservative, it only
// stalls a load the registered state already knows about). The violation
// report is likewise registered before it trains the table -- the
// train_valid_i event keeps its identity and lands a cycle later, which is
// safe: the table is an advisory predictor, not an ordering authority.

module g6lc_memdep #(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter int unsigned NR_SETS  = 64,
    parameter int unsigned NR_TRAIN = 2
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,
    input  logic enable_i,
    // Train: store dispatch
    input  logic [NR_TRAIN-1:0]                    st_valid_i,
    input  logic [NR_TRAIN-1:0][G6LCCfg.VLEN-1:0]  st_pc_i,
    // Query: load about to dispatch (registered -- verdict next cycle)
    input  logic                     ld_query_i,
    input  logic [G6LCCfg.VLEN-1:0]  ld_pc_i,
    // Observed memory-order violation this cycle, with the violating load's PC
    // (registered -- trains the table one cycle later)
    input  logic                     train_valid_i,
    input  logic [G6LCCfg.VLEN-1:0]  train_pc_i,
    input  logic                     store_pending_i,
    output logic                     stall_o,
    output logic                     predict_o
);

  localparam int unsigned SW = (NR_SETS <= 1) ? 1 : $clog2(NR_SETS);

  logic [NR_SETS-1:0] set_valid_q, set_valid_d;
  logic [NR_SETS-1:0][7:0] set_ssid_q, set_ssid_d;
  // Load PCs that previously collided with older stores
  logic [NR_SETS-1:0] ld_wait_q, ld_wait_d;

  // hyp8: registered query + registered violation report
  logic                    ld_query_q;
  logic [G6LCCfg.VLEN-1:0] ld_pc_q;
  logic                    store_pending_q;
  logic                    train_valid_q;
  logic [G6LCCfg.VLEN-1:0] train_pc_q;

  function automatic logic [SW-1:0] idx(input logic [G6LCCfg.VLEN-1:0] pc);
    return pc[2 +: SW];
  endfunction

  function automatic logic [7:0] ssid(input logic [G6LCCfg.VLEN-1:0] pc);
    return pc[10:3] ^ pc[18:11];
  endfunction

  always_comb begin
    set_valid_d = set_valid_q;
    set_ssid_d  = set_ssid_q;
    ld_wait_d   = ld_wait_q;

    if (enable_i) begin
      for (int unsigned t = 0; t < NR_TRAIN; t++) begin
        if (st_valid_i[t]) begin
          set_valid_d[idx(st_pc_i[t])] = 1'b1;
          set_ssid_d[idx(st_pc_i[t])]  = ssid(st_pc_i[t]);
        end
      end
      // Train the load side on a real violation: the violating load's PC (not
      // whichever load happens to be querying this cycle) is marked
      // wait-on-store. hyp8: the report is the registered one.
      if (train_valid_q) begin
        ld_wait_d[idx(train_pc_q)] = 1'b1;
        set_valid_d[idx(train_pc_q)] = 1'b1;
        set_ssid_d[idx(train_pc_q)]  = ssid(train_pc_q);
        for (int unsigned t = 0; t < NR_TRAIN; t++)
          if (st_valid_i[t]) set_ssid_d[idx(train_pc_q)] = ssid(st_pc_i[t]);
      end
    end

    if (flush_i) begin
      set_valid_d = '0;
      ld_wait_d   = '0;
    end
  end

  // Registered query lookup: the verdict is captured so the consumer reads a
  // registered output the cycle after the query.
  logic predict_d, stall_d;
  always_comb begin
    predict_d = 1'b0;
    stall_d   = 1'b0;
    if (enable_i && ld_query_q && store_pending_q) begin
      // Classic store-set: load PC table hit with matching ssid
      if (set_valid_q[idx(ld_pc_q)] &&
          (set_ssid_q[idx(ld_pc_q)] == ssid(ld_pc_q) || ld_wait_q[idx(ld_pc_q)])) begin
        predict_d = 1'b1;
        stall_d   = 1'b1;
      end
    end
  end

  logic predict_q, stall_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      set_valid_q    <= '0;
      set_ssid_q     <= '0;
      ld_wait_q      <= '0;
      ld_query_q     <= 1'b0;
      ld_pc_q        <= '0;
      store_pending_q <= 1'b0;
      train_valid_q  <= 1'b0;
      train_pc_q     <= '0;
      predict_q      <= 1'b0;
      stall_q        <= 1'b0;
    end else begin
      set_valid_q     <= set_valid_d;
      set_ssid_q      <= set_ssid_d;
      ld_wait_q       <= ld_wait_d;
      ld_query_q      <= ld_query_i && !flush_i;
      ld_pc_q         <= ld_pc_i;
      store_pending_q <= store_pending_i;
      train_valid_q   <= train_valid_i && !flush_i;
      train_pc_q      <= train_pc_i;
      predict_q       <= predict_d && !flush_i;
      stall_q         <= stall_d && !flush_i;
    end
  end

  assign predict_o = predict_q;
  assign stall_o   = stall_q;

endmodule
