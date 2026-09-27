// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// DramClass=2 must refuse elaboration. The $error in g6lc_ai_dram_backend
// is the pass. Reaching the fatal means a PHY was elaborated instead.

module tb_g6lc_ai_dram_class2;
  localparam int unsigned AW = 64;
  localparam int unsigned DW = 64;
  localparam int unsigned IW = 4;
  localparam int unsigned UW = 1;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  AXI_BUS #(
    .AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW),
    .AXI_ID_WIDTH(IW), .AXI_USER_WIDTH(UW)
  ) mem ();

  logic init_done;
  logic [7:0][31:0] ch_r, ch_w;

  g6lc_ai_dram_backend #(
    .DramClass(g6lc_ai_island_cfg_pkg::AI_DRAM_LPDDR5),
    .AXI_ID_WIDTH(IW), .AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW),
    .AXI_USER_WIDTH(UW), .NUM_WORDS(1024), .NrChannels(1)
  ) i_backend (
    .clk_i(clk), .rst_ni(rst_n), .rst_sram_ni(rst_n), .testmode_i(1'b0),
    .slave(mem), .init_done_o(init_done),
    .ch_r_beats_o(ch_r), .ch_w_beats_o(ch_w)
  );

  initial begin
    repeat (4) @(posedge clk);
    $fatal(1, "class 2 elaborated without the PHY error");
  end
endmodule
