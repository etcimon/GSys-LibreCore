// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai island tile bank — PDK-swap seam via tc_sram.
//
// Dual-port Latency=0 (same pattern as core g6lc_ai_acc_bank):
//   port 0: read (combo) OR second write when w2_req (I3-lite B drain)
//   port 1: primary write
//
// r_req and w2_req are mutually exclusive (caller). Used for I1 A/B staging
// (int8) and C accumulator (int32). CVA6_TECH_OPT maps to foundry macros.

module g6lc_ai_tile_sram #(
    parameter int unsigned NumWords  = 64,
    parameter int unsigned DataWidth = 8,
    parameter              ImplKey   = "g6lc_ai_tile",
    // DEPENDENT
    parameter int unsigned AddrWidth = (NumWords > 1) ? $clog2(NumWords) : 1,
    parameter int unsigned BeWidth   = (DataWidth + 7) / 8
) (
    input  logic                 clk_i,
    input  logic                 rst_ni,
    // DFT: reserved for MBIST/ATPG at the PDK-mapped macro
    input  logic                 testmode_i,
    // Read port (port 0 when not dual-writing)
    input  logic                 r_req_i,
    input  logic [AddrWidth-1:0] r_addr_i,
    output logic [DataWidth-1:0] r_data_o,
    // Primary write port (port 1)
    input  logic                 w_req_i,
    input  logic [AddrWidth-1:0] w_addr_i,
    input  logic [DataWidth-1:0] w_data_i,
    // Optional second write on port 0 (I3-lite: B same-bank dual drain)
    input  logic                 w2_req_i,
    input  logic [AddrWidth-1:0] w2_addr_i,
    input  logic [DataWidth-1:0] w2_data_i
);

  logic [1:0]                 req;
  logic [1:0]                 we;
  logic [1:0][AddrWidth-1:0]  addr;
  logic [1:0][DataWidth-1:0]  wdata;
  logic [1:0][BeWidth-1:0]    be;
  logic [1:0][DataWidth-1:0]  rdata;

  // Port 0: read if r_req, else second write if w2_req
  assign req[0]   = r_req_i | w2_req_i;
  assign we[0]    = w2_req_i;
  assign addr[0]  = w2_req_i ? w2_addr_i : r_addr_i;
  assign wdata[0] = w2_data_i;
  assign be[0]    = w2_req_i ? '1 : '0;
  assign r_data_o = rdata[0];

  assign req[1]   = w_req_i;
  assign we[1]    = w_req_i;
  assign addr[1]  = w_addr_i;
  assign wdata[1] = w_data_i;
  assign be[1]    = '1;  // full-word writes

  // SimInit "none": Verilator rejects BLKLOOPINIT on large zero-init arrays
  // (AccTile>=32 => C bank 1024xi32). GEMM always writes tiles before read.
  tc_sram #(
      .NumWords   (NumWords),
      .DataWidth  (DataWidth),
      .ByteWidth  (8),
      .NumPorts   (2),
      .Latency    (0),
      .SimInit    ("none"),
      .PrintSimCfg(1'b0),
      .ImplKey    (ImplKey)
  ) i_sram (
      .clk_i  (clk_i),
      .rst_ni (rst_ni),
      .req_i  (req),
      .we_i   (we),
      .addr_i (addr),
      .wdata_i(wdata),
      .be_i   (be),
      .rdata_o(rdata)
  );

  // verilator lint_off UNUSEDSIGNAL
  logic _dft_touch;
  assign _dft_touch = testmode_i;
  // verilator lint_on UNUSEDSIGNAL

endmodule
