// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// Testharness exclusive-monitor write path. pulp axi_riscv_lrsc allows at
// most one write outstanding (W_FORWARD until B), so wrap NrAwSlots=8 is
// not visible above this adapter. AXI_MAX_WRITE_TXNS=dram_aw_out is AMO
// w_cnt headroom only. Live dram_aw_out stays 1. Not LiteDRAM. Not 400.

`timescale 1ns/1ps
`include "axi/assign.svh"

module tb_g6lc_ai_atomics_aw;
  import g6lc_ai_island_cfg_pkg::*;

  localparam int unsigned ID_W   = 6;
  localparam int unsigned ADDR_W = 64;
  localparam int unsigned DATA_W = 64;
  localparam int unsigned AW_OUT = AI_MAX_AR_OUT_DRAM;

  logic clk, rst_ni, drain;
  int unsigned errors, cycles;

  AXI_BUS #(
      .AXI_ADDR_WIDTH ( ADDR_W ),
      .AXI_DATA_WIDTH ( DATA_W ),
      .AXI_ID_WIDTH   ( ID_W   ),
      .AXI_USER_WIDTH ( 1      )
  ) slv();

  AXI_BUS #(
      .AXI_ADDR_WIDTH ( ADDR_W ),
      .AXI_DATA_WIDTH ( DATA_W ),
      .AXI_ID_WIDTH   ( ID_W   ),
      .AXI_USER_WIDTH ( 1      )
  ) mem();

  axi_riscv_atomics_wrap #(
      .AXI_ADDR_WIDTH     ( ADDR_W ),
      .AXI_DATA_WIDTH     ( DATA_W ),
      .AXI_ID_WIDTH       ( ID_W   ),
      .AXI_USER_WIDTH     ( 1      ),
      .AXI_MAX_WRITE_TXNS ( AW_OUT ),
      .RISCV_WORD_WIDTH   ( 64     )
  ) i_atomics (
      .clk_i  ( clk ),
      .rst_ni ( rst_ni ),
      .slv    ( slv ),
      .mst    ( mem )
  );

  // Dummy DRAM: accept AW always; stall W/B until `drain` so w_cnt
  // (AW minus W-last) fills AXI_MAX_WRITE_TXNS.
  logic [3:0] npend;
  logic [ID_W-1:0] bidq [0:15];
  logic [3:0] qh, qt;
  wire aw_hs = mem.aw_valid && mem.aw_ready;
  wire w_hs  = mem.w_valid && mem.w_ready && mem.w_last;
  wire b_hs  = mem.b_valid && mem.b_ready;

  assign mem.aw_ready = 1'b1;
  assign mem.w_ready  = drain;
  assign mem.ar_ready = 1'b1;
  assign mem.r_valid  = 1'b0;
  assign mem.r_data   = '0;
  assign mem.r_resp   = '0;
  assign mem.r_last   = 1'b1;
  assign mem.r_id     = '0;
  assign mem.r_user   = '0;
  assign mem.b_valid  = drain && (npend != 0); // npend = W-last minus B
  assign mem.b_id     = bidq[qh];
  assign mem.b_resp   = 2'b00;
  assign mem.b_user   = '0;

  initial clk = 0;
  always #5 clk = ~clk;

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      npend <= '0;
      qh    <= '0;
      qt    <= '0;
    end else begin
      if (aw_hs) begin
        bidq[qt] <= mem.aw_id;
        qt       <= qt + 4'd1;
      end
      if (b_hs)
        qh <= qh + 4'd1;
      unique case ({w_hs, b_hs})
        2'b10: npend <= npend + 4'd1;
        2'b01: npend <= npend - 4'd1;
        default: ;
      endcase
    end
  end

  task automatic idle_m;
    slv.aw_valid = 1'b0;
    slv.w_valid  = 1'b0;
    slv.ar_valid = 1'b0;
    slv.b_ready  = 1'b1;
    slv.r_ready  = 1'b1;
    slv.aw_id    = '0;
    slv.aw_addr  = '0;
    slv.aw_len   = '0;
    slv.aw_size  = 3'd3;
    slv.aw_burst = 2'b01;
    slv.aw_lock  = 1'b0;
    slv.aw_cache = '0;
    slv.aw_prot  = '0;
    slv.aw_qos   = '0;
    slv.aw_region= '0;
    slv.aw_atop  = '0;
    slv.aw_user  = '0;
    slv.w_data   = '0;
    slv.w_strb   = 8'hFF;
    slv.w_last   = 1'b1;
    slv.w_user   = '0;
    slv.ar_id    = '0;
    slv.ar_addr  = '0;
    slv.ar_len   = '0;
    slv.ar_size  = 3'd3;
    slv.ar_burst = 2'b01;
    slv.ar_lock  = 1'b0;
    slv.ar_cache = '0;
    slv.ar_prot  = '0;
    slv.ar_qos   = '0;
    slv.ar_region= '0;
    slv.ar_user  = '0;
  endtask

  task automatic tick;
    @(posedge clk);
    cycles++;
  endtask

  task automatic hs_aw(input int unsigned lim);
    int unsigned tlim;
    tlim = cycles + lim;
    #0;
    while (!slv.aw_ready && cycles < tlim) tick;
    if (!slv.aw_ready) begin
      $error("timeout AW id=%h", slv.aw_id);
      errors++;
    end else
      tick;
    slv.aw_valid = 1'b0;
  endtask

  task automatic hs_w(input int unsigned lim);
    int unsigned tlim;
    tlim = cycles + lim;
    #0;
    while (!slv.w_ready && cycles < tlim) tick;
    if (!slv.w_ready) begin
      $error("timeout W");
      errors++;
    end else
      tick;
    slv.w_valid = 1'b0;
  endtask

  task automatic issue_aw(
      input logic [ID_W-1:0]   id,
      input logic [ADDR_W-1:0] addr
  );
    slv.aw_id    = id;
    slv.aw_addr  = addr;
    slv.aw_len   = '0;
    slv.aw_valid = 1'b1;
    hs_aw(400);
  endtask

  initial begin
    errors = 0;
    cycles = 0;
    rst_ni = 1'b0;
    drain  = 1'b0;
    idle_m();
    repeat (8) tick;
    rst_ni = 1'b1;
    repeat (8) tick;

    if (dram_aw_out(AiIslandDdr4Bringup) != unsigned'(AW_OUT)) begin
      $error("CLASS1 dram_aw_out");
      errors++;
    end
    if (dram_aw_out(AiIslandLatencyDefault) != unsigned'(1)) begin
      $error("live dram_aw_out must stay 1");
      errors++;
    end

    slv.b_ready = 1'b1;
    issue_aw(ID_W'(1), 64'h8000_1000);
    slv.aw_id    = ID_W'(2);
    slv.aw_addr  = 64'h8000_1008;
    slv.aw_len   = '0;
    slv.aw_valid = 1'b1;
    begin
      int unsigned k;
      for (k = 0; k < 16; k++) begin
        #0;
        if (slv.aw_ready) begin
          $error("2nd AW ready while LRSC still in first write");
          errors++;
        end
        tick;
      end
    end
    slv.aw_valid = 1'b0;
    drain        = 1'b1;
    slv.w_data   = 64'h1;
    slv.w_strb   = 8'hFF;
    slv.w_last   = 1'b1;
    slv.w_valid  = 1'b1;
    hs_w(400);
    begin
      int unsigned tlim;
      tlim = cycles + 400;
      #0;
      while (!slv.b_valid && cycles < tlim) tick;
      if (!slv.b_valid || slv.b_id !== ID_W'(1)) begin
        $error("B0 id=%h", slv.b_id);
        errors++;
      end
      tick;
    end
    issue_aw(ID_W'(2), 64'h8000_1008);
    slv.w_data  = 64'h2;
    slv.w_strb  = 8'hFF;
    slv.w_last  = 1'b1;
    slv.w_valid = 1'b1;
    hs_w(400);
    begin
      int unsigned tlim;
      tlim = cycles + 400;
      #0;
      while (!slv.b_valid && cycles < tlim) tick;
      if (!slv.b_valid || slv.b_id !== ID_W'(2)) begin
        $error("B1 id=%h", slv.b_id);
        errors++;
      end
      tick;
    end

    if (errors == 0) $display("PASS g6lc_ai_atomics_aw lrsc1 cycles=%0d", cycles);
    else begin
      $display("FAIL g6lc_ai_atomics_aw errors=%0d", errors);
      $fatal(1);
    end
    $finish;
  end
endmodule
