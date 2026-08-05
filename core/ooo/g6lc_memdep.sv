// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U5.4 / FSE S3 store-set memory dependence predictor.
// - Trains on store dispatch (multi-port)
// - Trains load PCs when LSQ observes dependence (older store / STL stall)
// - Flushes on full flush or mispredict (caller ORs mispredict into flush_i)
// When enable_i=0 (MemDepPredEn=0 and not forced by OoO), never stalls.

module g6lc_memdep #(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter int unsigned NR_SETS  = 64,
    parameter int unsigned NR_TRAIN = 2
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,
    input  logic enable_i,
    // Train: store dispatch
    input  logic [NR_TRAIN-1:0]                    st_valid_i,
    input  logic [NR_TRAIN-1:0][CVA6Cfg.VLEN-1:0]  st_pc_i,
    // Query: load about to issue
    input  logic                     ld_query_i,
    input  logic [CVA6Cfg.VLEN-1:0]  ld_pc_i,
    // Observed dependence this cycle (older store pending && stl_stall)
    input  logic                     dep_observe_i,
    input  logic                     older_store_pending_i,
    output logic                     stall_o,
    output logic                     predict_o
);

  localparam int unsigned SW = (NR_SETS <= 1) ? 1 : $clog2(NR_SETS);

  logic [NR_SETS-1:0] set_valid_q, set_valid_d;
  logic [NR_SETS-1:0][7:0] set_ssid_q, set_ssid_d;
  // Load PCs that previously collided with older stores
  logic [NR_SETS-1:0] ld_wait_q, ld_wait_d;

  function automatic logic [SW-1:0] idx(input logic [CVA6Cfg.VLEN-1:0] pc);
    return pc[2 +: SW];
  endfunction

  function automatic logic [7:0] ssid(input logic [CVA6Cfg.VLEN-1:0] pc);
    return pc[10:3] ^ pc[18:11];
  endfunction

  always_comb begin
    set_valid_d = set_valid_q;
    set_ssid_d  = set_ssid_q;
    ld_wait_d   = ld_wait_q;
    predict_o   = 1'b0;
    stall_o     = 1'b0;

    if (enable_i) begin
      for (int unsigned t = 0; t < NR_TRAIN; t++) begin
        if (st_valid_i[t]) begin
          set_valid_d[idx(st_pc_i[t])] = 1'b1;
          set_ssid_d[idx(st_pc_i[t])]  = ssid(st_pc_i[t]);
        end
      end
      // FSE S3: train load side on observed LSQ dependence
      if (dep_observe_i && ld_query_i) begin
        ld_wait_d[idx(ld_pc_i)] = 1'b1;
        set_valid_d[idx(ld_pc_i)] = 1'b1;
        set_ssid_d[idx(ld_pc_i)]  = ssid(ld_pc_i);
        for (int unsigned t = 0; t < NR_TRAIN; t++)
          if (st_valid_i[t]) set_ssid_d[idx(ld_pc_i)] = ssid(st_pc_i[t]);
      end
    end

    if (enable_i && ld_query_i && older_store_pending_i) begin
      // Classic store-set: load PC table hit with matching ssid
      if (set_valid_q[idx(ld_pc_i)] &&
          (set_ssid_q[idx(ld_pc_i)] == ssid(ld_pc_i) || ld_wait_q[idx(ld_pc_i)])) begin
        predict_o = 1'b1;
        stall_o   = 1'b1;
      end
    end

    if (flush_i) begin
      set_valid_d = '0;
      ld_wait_d   = '0;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      set_valid_q <= '0;
      set_ssid_q  <= '0;
      ld_wait_q   <= '0;
    end else begin
      set_valid_q <= set_valid_d;
      set_ssid_q  <= set_ssid_d;
      ld_wait_q   <= ld_wait_d;
    end
  end

endmodule
