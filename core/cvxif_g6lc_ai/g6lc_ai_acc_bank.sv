// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai accumulator bank — PDK-swap seam via tc_sram.
//
// One SRAM word holds a full spatial accumulator tile (AccElems × s32).
// Dual-port Latency=0 preserves single-cycle RMW for multi-cycle MMA:
//   port 0 read  → full bank (combo)
//   port 1 write → byte-enabled element or whole-bank clear
//
// Tiles stay flops in g6lc_ai_exec (multi-read K-reduction). Island-scale
// staging SRAM lives in corev_apu (I1), not here.
//
// Timing: no combinational path through clk; Latency=0 is behavioural for the
// generic cell and maps to 1R1W macros at the PDK seam (CVA6_TECH_OPT).

module g6lc_ai_acc_bank #(
    parameter int unsigned AccCount = 4,
    parameter int unsigned AccElems = 64,
    // DEPENDENT
    parameter int unsigned DataWidth = AccElems * 32,
    parameter int unsigned AccAddrW  = (AccCount > 1) ? $clog2(AccCount) : 1,
    parameter int unsigned ElemAddrW = (AccElems > 1) ? $clog2(AccElems) : 1,
    parameter int unsigned BeWidth   = DataWidth / 8
) (
    input  logic                 clk_i,
    input  logic                 rst_ni,
    // DFT: reserved for MBIST/ATPG mux at the PDK-mapped macro; unused on
    // the behavioural tc_sram but keeps the scan seam threaded (AGENTS.md §0.2).
    input  logic                 testmode_i,
    // Read port (always combo when Latency=0)
    input  logic                 r_req_i,
    input  logic [AccAddrW-1:0]  r_acc_i,
    output logic [DataWidth-1:0] r_data_o,
    // Write port
    input  logic                 w_req_i,
    input  logic [AccAddrW-1:0]  w_acc_i,
    input  logic [DataWidth-1:0] w_data_i,
    input  logic [BeWidth-1:0]   w_be_i
);

  logic [1:0]                 req;
  logic [1:0]                 we;
  logic [1:0][AccAddrW-1:0]   addr;
  logic [1:0][DataWidth-1:0]  wdata;
  logic [1:0][BeWidth-1:0]    be;
  logic [1:0][DataWidth-1:0]  rdata;

  // Port 0: read
  assign req[0]   = r_req_i;
  assign we[0]    = 1'b0;
  assign addr[0]  = r_acc_i;
  assign wdata[0] = '0;
  assign be[0]    = '0;
  assign r_data_o = rdata[0];

  // Port 1: write
  assign req[1]   = w_req_i;
  assign we[1]    = w_req_i;
  assign addr[1]  = w_acc_i;
  assign wdata[1] = w_data_i;
  assign be[1]    = w_be_i;

  tc_sram #(
      .NumWords (AccCount),
      .DataWidth(DataWidth),
      .ByteWidth(8),
      .NumPorts (2),
      .Latency  (0),
      .SimInit  ("zeros"),
      .PrintSimCfg(1'b0),
      .ImplKey  ("g6lc_ai_acc")
  ) i_acc_sram (
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
  assign _dft_touch = testmode_i | rst_ni;
  // verilator lint_on UNUSEDSIGNAL

endmodule
