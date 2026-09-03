// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// g6lc_axi_lrsc: eight regular AR/AW live, 9th backpressure; LR/SC snoop.
// Not Variane. Not 400 GB/s.

`timescale 1ns/1ps
`include "axi/assign.svh"

module tb_g6lc_axi_lrsc;
  localparam int unsigned ID_W   = 6;
  localparam int unsigned ADDR_W = 64;
  localparam int unsigned DATA_W = 64;
  localparam int unsigned MAX    = 8;

  logic clk, rst_ni, r_go, b_go;
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

`ifdef G6LC_TB_ATOMICS_WRAP
  g6lc_axi_atomics_wrap #(
      .AXI_ADDR_WIDTH     ( ADDR_W ),
      .AXI_DATA_WIDTH     ( DATA_W ),
      .AXI_ID_WIDTH       ( ID_W   ),
      .AXI_MAX_WRITE_TXNS ( MAX    ),
      .RISCV_WORD_WIDTH   ( 64     )
  ) i_dut (
      .clk_i  ( clk ),
      .rst_ni ( rst_ni ),
      .slv    ( slv ),
      .mst    ( mem )
  );
`else
  g6lc_axi_lrsc #(
      .AXI_ADDR_WIDTH ( ADDR_W ),
      .AXI_DATA_WIDTH ( DATA_W ),
      .AXI_ID_WIDTH   ( ID_W   ),
      .MaxOut         ( MAX    )
  ) i_dut (
      .clk_i  ( clk ),
      .rst_ni ( rst_ni ),
      .slv    ( slv ),
      .mst    ( mem )
  );
`endif

  logic [3:0] nr, nw;
  logic [ID_W-1:0] ridq [0:15], widq [0:15];
  logic [3:0] rqh, rqt, wqh, wqt;
  int unsigned nstore;

  wire ar_hs = mem.ar_valid && mem.ar_ready;
  wire aw_hs = mem.aw_valid && mem.aw_ready;
  wire w_hs  = mem.w_valid && mem.w_ready && mem.w_last;
  wire r_hs  = mem.r_valid && mem.r_ready;
  wire b_hs  = mem.b_valid && mem.b_ready;

  assign mem.aw_ready = 1'b1;
  assign mem.w_ready  = 1'b1;
  assign mem.ar_ready = 1'b1;
  assign mem.r_valid  = r_go && (nr != 0);
  assign mem.r_id     = ridq[rqh];
  assign mem.r_data   = 64'hA5A5_0000_0000_0000 | 64'(ridq[rqh]);
  assign mem.r_resp   = 2'b00;
  assign mem.r_last   = 1'b1;
  assign mem.r_user   = '0;
  assign mem.b_valid  = b_go && (nw != 0);
  assign mem.b_id     = widq[wqh];
  assign mem.b_resp   = 2'b00;
  assign mem.b_user   = '0;

  initial clk = 0;
  always #5 clk = ~clk;

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      nr <= '0; nw <= '0;
      rqh <= '0; rqt <= '0; wqh <= '0; wqt <= '0;
      nstore <= 0;
    end else begin
      if (ar_hs) begin
        ridq[rqt] <= mem.ar_id;
        rqt <= rqt + 4'd1;
      end
      if (r_hs) rqh <= rqh + 4'd1;
      unique case ({ar_hs, r_hs})
        2'b10: nr <= nr + 4'd1;
        2'b01: nr <= nr - 4'd1;
        default: ;
      endcase
      if (aw_hs) begin
        widq[wqt] <= mem.aw_id;
        wqt <= wqt + 4'd1;
        nstore <= nstore + 1;
      end
      if (b_hs) wqh <= wqh + 4'd1;
      unique case ({w_hs, b_hs})
        2'b10: nw <= nw + 4'd1;
        2'b01: nw <= nw - 4'd1;
        default: ;
      endcase
    end
  end

  task automatic idle_m;
    slv.aw_valid = 1'b0; slv.w_valid = 1'b0; slv.ar_valid = 1'b0;
    slv.b_ready = 1'b1; slv.r_ready = 1'b1;
    slv.aw_id = '0; slv.aw_addr = '0; slv.aw_len = '0;
    slv.aw_size = 3'd3; slv.aw_burst = 2'b01; slv.aw_lock = 1'b0;
    slv.aw_cache = '0; slv.aw_prot = '0; slv.aw_qos = '0;
    slv.aw_region = '0; slv.aw_atop = '0; slv.aw_user = '0;
    slv.w_data = '0; slv.w_strb = 8'hFF; slv.w_last = 1'b1; slv.w_user = '0;
    slv.ar_id = '0; slv.ar_addr = '0; slv.ar_len = '0;
    slv.ar_size = 3'd3; slv.ar_burst = 2'b01; slv.ar_lock = 1'b0;
    slv.ar_cache = '0; slv.ar_prot = '0; slv.ar_qos = '0;
    slv.ar_region = '0; slv.ar_user = '0;
  endtask

  task automatic tick;
    @(posedge clk);
    cycles++;
  endtask

  task automatic hs_ar(input int unsigned lim);
    int unsigned tlim;
    tlim = cycles + lim;
    #0;
    while (!slv.ar_ready && cycles < tlim) tick;
    if (!slv.ar_ready) begin $error("timeout AR"); errors++; end
    else tick;
    slv.ar_valid = 1'b0; slv.ar_lock = 1'b0;
  endtask

  task automatic hs_aw(input int unsigned lim);
    int unsigned tlim;
    tlim = cycles + lim;
    #0;
    while (!slv.aw_ready && cycles < tlim) tick;
    if (!slv.aw_ready) begin $error("timeout AW"); errors++; end
    else tick;
    slv.aw_valid = 1'b0; slv.aw_lock = 1'b0;
  endtask

  task automatic hs_w(input int unsigned lim);
    int unsigned tlim;
    tlim = cycles + lim;
    #0;
    while (!slv.w_ready && cycles < tlim) tick;
    if (!slv.w_ready) begin $error("timeout W"); errors++; end
    else tick;
    slv.w_valid = 1'b0;
  endtask

  task automatic issue_ar(input logic [ID_W-1:0] id, input logic [63:0] addr, input logic lock);
    slv.ar_id = id; slv.ar_addr = addr; slv.ar_len = '0;
    slv.ar_lock = lock; slv.ar_valid = 1'b1;
    hs_ar(400);
  endtask

  task automatic issue_aw_w(
      input logic [ID_W-1:0] id, input logic [63:0] addr,
      input logic [63:0] data, input logic lock
  );
    slv.aw_id = id; slv.aw_addr = addr; slv.aw_len = '0;
    slv.aw_lock = lock; slv.aw_valid = 1'b1;
    hs_aw(400);
    slv.w_data = data; slv.w_strb = 8'hFF; slv.w_last = 1'b1; slv.w_valid = 1'b1;
    hs_w(400);
  endtask

  initial begin
    errors = 0; cycles = 0; rst_ni = 1'b0; r_go = 1'b0; b_go = 1'b0;
    idle_m();
    repeat (4) tick;
    rst_ni = 1'b1;
    repeat (4) tick;

    // Eight regular AR, 9th backpressure.
    slv.r_ready = 1'b0;
    begin
      int unsigned s;
      for (s = 0; s < MAX; s++)
        issue_ar(ID_W'(s), 64'h8000_2000 + (64'(s) << 3), 1'b0);
    end
`ifndef G6LC_TB_ATOMICS_WRAP
    repeat (4) tick;
    slv.ar_id = ID_W'(MAX); slv.ar_addr = 64'h8000_2100; slv.ar_valid = 1'b1;
    begin
      int unsigned k;
      for (k = 0; k < 16; k++) begin
        #0;
        if (slv.ar_ready) begin $error("9th AR ready"); errors++; end
        tick;
      end
    end
    slv.ar_valid = 1'b0;
`endif
    slv.r_ready = 1'b1; r_go = 1'b1;
    begin
      logic [7:0] got;
      int unsigned tlim, s;
      got = '0; tlim = cycles + 400;
      while ((got != 8'hFF) && cycles < tlim) begin
        #0;
        if (slv.r_valid) begin
          s = int'(slv.r_id);
          if (s > 7) begin $error("R id=%h", slv.r_id); errors++; end
          else got[s] = 1'b1;
        end
        tick;
      end
      if (got != 8'hFF) begin $error("R timeout got=%b", got); errors++; end
    end
    r_go = 1'b0;

    // Eight regular AW, 9th backpressure.
    slv.b_ready = 1'b0;
    begin
      int unsigned s;
      for (s = 0; s < MAX; s++)
        issue_aw_w(ID_W'(s), 64'h8000_3000 + (64'(s) << 3), 64'(s), 1'b0);
    end
`ifndef G6LC_TB_ATOMICS_WRAP
    repeat (4) tick;
    slv.aw_id = ID_W'(MAX); slv.aw_addr = 64'h8000_3100; slv.aw_valid = 1'b1;
    slv.w_valid = 1'b1; slv.w_last = 1'b1;
    begin
      int unsigned k;
      for (k = 0; k < 16; k++) begin
        #0;
        if (slv.aw_ready) begin $error("9th AW ready"); errors++; end
        tick;
      end
    end
    slv.aw_valid = 1'b0; slv.w_valid = 1'b0;
`endif
    slv.b_ready = 1'b1; b_go = 1'b1;
    begin
      logic [7:0] got;
      int unsigned tlim, s;
      got = '0; tlim = cycles + 400;
      while ((got != 8'hFF) && cycles < tlim) begin
        #0;
        if (slv.b_valid) begin
          s = int'(slv.b_id);
          if (s > 7) begin $error("B id=%h", slv.b_id); errors++; end
          else got[s] = 1'b1;
        end
        tick;
      end
      if (got != 8'hFF) begin $error("B timeout got=%b", got); errors++; end
    end

    // Drain leftover slv B after eight AW, then LR/SC (lrsc now sits
    // above AMOS so AxLOCK is visible).
    begin
      int unsigned idle;
      idle = 0;
      while (idle < 16) begin
        #0;
        if (slv.b_valid) idle = 0;
        else idle++;
        tick;
      end
    end

    begin
      int unsigned stores0;
      stores0 = nstore;
      r_go = 1'b1;
      issue_ar(6'h11, 64'h8000_4000, 1'b1);
      begin
        int unsigned tlim;
        tlim = cycles + 400;
        #0; while (!slv.r_valid && cycles < tlim) tick;
        if (!slv.r_valid || slv.r_resp !== 2'b01) begin
          $error("LR resp=%h", slv.r_resp); errors++;
        end
        tick;
      end
      repeat (8) tick;
      issue_aw_w(6'h11, 64'h8000_4000, 64'h1111, 1'b1);
      begin
        int unsigned tlim;
        tlim = cycles + 400;
        #0;
        while ((!(slv.b_valid && slv.b_id == 6'h11)) && cycles < tlim) tick;
        if (!slv.b_valid || slv.b_id !== 6'h11 || slv.b_resp !== 2'b01) begin
          $error("SC ok id=%h resp=%h", slv.b_id, slv.b_resp); errors++;
        end
        tick;
      end
      if (nstore != stores0 + 1) begin
        $error("SC success must store"); errors++;
      end
    end

    // Split-ID LR/SC: HPDCACHE LDEX uses the read ID space, STEX uses
    // uncached-write id='1. Reservation is address-only.
    begin
      int unsigned stores0;
      stores0 = nstore;
      r_go = 1'b1;
      issue_ar(6'h05, 64'h8000_6000, 1'b1);
      begin
        int unsigned tlim;
        tlim = cycles + 400;
        #0; while (!slv.r_valid && cycles < tlim) tick;
        if (!slv.r_valid || slv.r_resp !== 2'b01) begin
          $error("split LR resp=%h", slv.r_resp); errors++;
        end
        tick;
      end
      issue_aw_w(6'h3F, 64'h8000_6000, 64'h3333, 1'b1);
      begin
        int unsigned tlim;
        tlim = cycles + 400;
        #0;
        while ((!(slv.b_valid && slv.b_id == 6'h3F)) && cycles < tlim) tick;
        if (!slv.b_valid || slv.b_id !== 6'h3F || slv.b_resp !== 2'b01) begin
          $error("split SC id=%h resp=%h", slv.b_id, slv.b_resp); errors++;
        end
        tick;
      end
      if (nstore != stores0 + 1) begin
        $error("split SC must store"); errors++;
      end
    end

    // LR + intervening store + SC fail (no downstream write).
    begin
      int unsigned stores0;
      stores0 = nstore;
      issue_ar(6'h22, 64'h8000_5000, 1'b1);
      begin
        int unsigned tlim;
        tlim = cycles + 400;
        #0; while (!slv.r_valid && cycles < tlim) tick;
        tick;
      end
      issue_aw_w(6'h03, 64'h8000_5000, 64'hBEEF, 1'b0);
      begin
        int unsigned tlim;
        tlim = cycles + 400;
        #0; while (!slv.b_valid && cycles < tlim) tick;
        tick;
      end
      issue_aw_w(6'h22, 64'h8000_5000, 64'h2222, 1'b1);
      begin
        int unsigned tlim;
        tlim = cycles + 400;
        #0; while ((!(slv.b_valid && slv.b_id == 6'h22)) && cycles < tlim) tick;
        if (!slv.b_valid || slv.b_id !== 6'h22 || slv.b_resp !== 2'b00) begin
          $error("SC fail id=%h resp=%h", slv.b_id, slv.b_resp); errors++;
        end
        tick;
      end
      if (nstore != stores0 + 1) begin
        $error("SC fail must not store nstore=%0d", nstore); errors++;
      end
    end

    if (errors == 0)
`ifdef G6LC_TB_ATOMICS_WRAP
      $display("PASS g6lc_axi_atomics_wrap ar8 aw8 cycles=%0d", cycles);
`else
      $display("PASS g6lc_axi_lrsc ar8 aw8 cycles=%0d", cycles);
`endif
    else begin
      $display("FAIL g6lc_axi_lrsc errors=%0d", errors);
      $fatal(1);
    end
    $finish;
  end
endmodule
