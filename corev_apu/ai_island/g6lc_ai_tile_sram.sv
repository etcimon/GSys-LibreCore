// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai island tile bank — PDK-swap seam via tc_sram.
//
// Multi-port Latency=0 (same pattern as core g6lc_ai_acc_bank):
//   port 0: read (combo) OR second write when w2_req (I3 B drain)
//   port 1: primary write
//   port 2/3 (NumPorts=4): optional w3/w4 same-bank multi-drain (I3 B quad)
//
// r_req and w2_req are mutually exclusive (caller). Used for I1 A/B staging
// (int8) and C accumulator (int32). CVA6_TECH_OPT maps to foundry macros.

module g6lc_ai_tile_sram #(
    parameter int unsigned NumWords  = 64,
    parameter int unsigned DataWidth = 8,
    parameter int unsigned NumPorts  = 2,  // 2 (A/C) or 4 (B quad-drain)
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
    // Optional second write on port 0 (I3: B same-bank multi drain)
    input  logic                 w2_req_i,
    input  logic [AddrWidth-1:0] w2_addr_i,
    input  logic [DataWidth-1:0] w2_data_i,
    // Optional third/fourth write (NumPorts=4 only; tie off otherwise)
    input  logic                 w3_req_i,
    input  logic [AddrWidth-1:0] w3_addr_i,
    input  logic [DataWidth-1:0] w3_data_i,
    input  logic                 w4_req_i,
    input  logic [AddrWidth-1:0] w4_addr_i,
    input  logic [DataWidth-1:0] w4_data_i
);

  // Port 0: read if r_req, else second write if w2_req
  // Port 1: primary write
  // Port 2/3: w3/w4 when NumPorts==4

  if (NumPorts == 2) begin : gen_2p
    logic [1:0]                 req;
    logic [1:0]                 we;
    logic [1:0][AddrWidth-1:0]  addr;
    logic [1:0][DataWidth-1:0]  wdata;
    logic [1:0][BeWidth-1:0]    be;
    logic [1:0][DataWidth-1:0]  rdata;

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
    assign be[1]    = '1;

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

    // Tie-off unused w3/w4 in 2-port mode (still on port list)
    // verilator lint_off UNUSEDSIGNAL
    logic _w34_touch;
    assign _w34_touch = w3_req_i | w4_req_i | (|w3_addr_i) | (|w4_addr_i)
                      | (|w3_data_i) | (|w4_data_i);
    // verilator lint_on UNUSEDSIGNAL
  end else begin : gen_4p
    logic [3:0]                 req;
    logic [3:0]                 we;
    logic [3:0][AddrWidth-1:0]  addr;
    logic [3:0][DataWidth-1:0]  wdata;
    logic [3:0][BeWidth-1:0]    be;
    logic [3:0][DataWidth-1:0]  rdata;

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
    assign be[1]    = '1;

    assign req[2]   = w3_req_i;
    assign we[2]    = w3_req_i;
    assign addr[2]  = w3_addr_i;
    assign wdata[2] = w3_data_i;
    assign be[2]    = w3_req_i ? '1 : '0;

    assign req[3]   = w4_req_i;
    assign we[3]    = w4_req_i;
    assign addr[3]  = w4_addr_i;
    assign wdata[3] = w4_data_i;
    assign be[3]    = w4_req_i ? '1 : '0;

    tc_sram #(
        .NumWords   (NumWords),
        .DataWidth  (DataWidth),
        .ByteWidth  (8),
        .NumPorts   (4),
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
  end

  // verilator lint_off UNUSEDSIGNAL
  logic _dft_touch;
  assign _dft_touch = testmode_i;
  // verilator lint_on UNUSEDSIGNAL

  // Elaboration guard
  // pragma translate_off
  initial begin
    assert (NumPorts == 2 || NumPorts == 4)
      else $error("g6lc_ai_tile_sram: NumPorts must be 2 or 4");
  end
  // pragma translate_on

endmodule
