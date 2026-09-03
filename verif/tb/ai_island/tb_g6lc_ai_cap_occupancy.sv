// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// S5: SoC occupancy words (0x50/0x70) plus DTS↔CAP DRAM discovery
// (0x34 class, 0x38 channels+shift, 0x18 nameplate). Live DTS is class 0
// N=1 shift 6. Not Variane.

`timescale 1ns/1ps

module tb_g6lc_ai_cap_occupancy
  import g6lc_ai_island_cfg_pkg::*;
;
  logic        clk, rst_ni, req, we, rvalid, rvalid_d2;
  logic [15:0] addr;
  logic [31:0] wdata, rdata, rdata_d2;
  logic [AI_DRAM_MAX_CHANNELS-1:0][31:0] ch_r, ch_w;
  int unsigned errors, cycles, i;

  g6lc_ai_cap_window i_cap (
      .clk_i   ( clk ),
      .rst_ni  ( rst_ni ),
      .req_i   ( req ),
      .we_i    ( we ),
      .addr_i  ( addr ),
      .wdata_i ( wdata ),
      .dram_gbps_meas_x1000_i ( 32'd0 ),
      .dram_init_done_i ( 1'b1 ),
      .ch_r_beats_i ( ch_r ),
      .ch_w_beats_i ( ch_w ),
      .rdata_o ( rdata ),
      .rvalid_o( rvalid )
  );

  g6lc_ai_cap_window #(
      .IslandCfg ( AiIslandDdr4x2Bringup )
  ) i_cap_d2 (
      .clk_i   ( clk ),
      .rst_ni  ( rst_ni ),
      .req_i   ( req ),
      .we_i    ( we ),
      .addr_i  ( addr ),
      .wdata_i ( wdata ),
      .dram_gbps_meas_x1000_i ( 32'd0 ),
      .dram_init_done_i ( 1'b0 ),
      .ch_r_beats_i ( ch_r ),
      .ch_w_beats_i ( ch_w ),
      .rdata_o ( rdata_d2 ),
      .rvalid_o( rvalid_d2 )
  );

  initial clk = 0;
  always #5 clk = ~clk;

  task automatic tick;
    @(posedge clk);
    cycles++;
    req <= 1'b0;
    we  <= 1'b0;
  endtask

  task automatic cap_read(input logic [15:0] a, output logic [31:0] d);
    @(negedge clk);
    req  <= 1'b1;
    we   <= 1'b0;
    addr <= a;
    @(posedge clk);
    cycles++;
    @(posedge clk);
    cycles++;
    d = rdata;
    @(negedge clk);
    req <= 1'b0;
  endtask

  initial begin
    logic [31:0] r;
    errors = 0;
    cycles = 0;
    req = 0; we = 0; addr = 0; wdata = 0;
    ch_r = '0;
    ch_w = '0;
    rst_ni = 0;
    repeat (4) tick;
    rst_ni = 1;
    repeat (2) tick;

    for (i = 0; i < AI_DRAM_MAX_CHANNELS; i++) begin
      ch_r[i] = 32'hC0DE_0000 + 32'(i);
      ch_w[i] = 32'hBEEF_1000 + 32'(i);
    end
    tick;

    cap_read(CAP_OFF_DRAM_STATUS, r);
    if (r[0] !== 1'b1) begin
      $error("status init_done"); errors++;
    end

    cap_read(CAP_OFF_DRAM_GBPS, r);
    if (r[15:0] != 16'(AiIslandLatencyDefault.DramGBps)) begin
      $error("aggregate nameplate must stay at 0x18"); errors++;
    end

    for (i = 0; i < AI_DRAM_MAX_CHANNELS; i++) begin
      cap_read(CAP_OFF_DRAM_CH_R + 16'(i * 4), r);
      if (r !== (32'hC0DE_0000 + 32'(i))) begin
        $error("CH_R[%0d] exp=%h got=%h", i, 32'hC0DE_0000 + 32'(i), r);
        errors++;
      end
      cap_read(CAP_OFF_DRAM_CH_W + 16'(i * 4), r);
      if (r !== (32'hBEEF_1000 + 32'(i))) begin
        $error("CH_W[%0d] exp=%h got=%h", i, 32'hBEEF_1000 + 32'(i), r);
        errors++;
      end
    end

    cap_read(16'h006C, r);
    if (r !== 32'hC0DE_0007) begin
      $error("ch7 R alias 0x6C"); errors++;
    end
    cap_read(16'h0090, r);
    if (r !== 32'h0) begin
      $error("0x90 must stay unused, got=%h", r); errors++;
    end

    // Live DTS ariane-ai.dts: class 0, 8 GB/s, 1 channel, shift 6.
    cap_read(CAP_OFF_DRAM_CLASS, r);
    if (r !== 32'(AI_DRAM_SIM_AXI)) begin
      $error("DTS class exp=0 got=%0d", r); errors++;
    end
    cap_read(CAP_OFF_DRAM_CHANS, r);
    if (r[15:0] !== 16'(AiIslandLatencyDefault.DramChannels) ||
        r[23:16] !== 8'(AiIslandLatencyDefault.DramChanShift)) begin
      $error("DTS channels/shift exp=1/6 got count=%0d shift=%0d",
             r[15:0], r[23:16]); errors++;
    end
    cap_read(CAP_OFF_DRAM_GBPS, r);
    if (r[15:0] !== 16'd8) begin
      $error("DTS gbps exp=8 got=%0d", r[15:0]); errors++;
    end

    // CLASS1 N=2 bringup CAP (one memory@; firmware reads 0x38, not N DT banks).
    begin
      logic [31:0] d2;
      @(negedge clk);
      req  <= 1'b1;
      we   <= 1'b0;
      addr <= CAP_OFF_DRAM_CHANS;
      @(posedge clk); cycles++;
      @(posedge clk); cycles++;
      d2 = rdata_d2;
      @(negedge clk);
      req <= 1'b0;
      if (!rvalid_d2) begin
        $error("N=2 CAP 0x38 rvalid"); errors++;
      end
      if (d2[15:0] !== 16'd2 || d2[23:16] !== 8'(AI_DRAM_CHAN_SHIFT_DEFAULT)) begin
        $error("N=2 CAP 0x38 exp count=2 shift=6 got %h", d2); errors++;
      end
      @(negedge clk);
      req  <= 1'b1;
      addr <= CAP_OFF_DRAM_CLASS;
      @(posedge clk); cycles++;
      @(posedge clk); cycles++;
      d2 = rdata_d2;
      @(negedge clk);
      req <= 1'b0;
      if (d2 !== 32'(AI_DRAM_DDR4)) begin
        $error("N=2 CAP class exp=1 got=%0d", d2); errors++;
      end
      @(negedge clk);
      req  <= 1'b1;
      addr <= CAP_OFF_DRAM_STATUS;
      @(posedge clk); cycles++;
      @(posedge clk); cycles++;
      d2 = rdata_d2;
      @(negedge clk);
      req <= 1'b0;
      if (d2[0] !== 1'b0) begin
        $error("N=2 CAP init_done must be 0 until wrap"); errors++;
      end
    end

    if (errors == 0)
      $display("PASS g6lc_ai_cap_occupancy cycles=%0d", cycles);
    else begin
      $display("FAIL g6lc_ai_cap_occupancy errors=%0d", errors);
      $fatal(1);
    end
    $finish;
  end
endmodule
