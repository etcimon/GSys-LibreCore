// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// Standalone class-1 LiteDRAM wrap smoke.
// ID_W=6 matches testharness IdWidthSlave (cluster + island DMA).
// CORE_ID = {2'b00,4'h1}  ISL_ID = {2'b10,4'h1}  (xbar prepends master index in MSBs).
// Default NrArSlots/NrAwSlots=8: eight AR + eight AW live, 9th backpressure.
// Needs +define+G6LC_HAVE_LITEDRAM and generated litedram_core.v.
// Not a Variane cookie. Not 400 GB/s.

`timescale 1ns/1ps
`include "axi/assign.svh"

module tb_g6lc_ai_litedram_wrap;
  localparam int unsigned ID_W   = 6;
  localparam int unsigned ADDR_W = 64;
  localparam int unsigned DATA_W = 64;
  localparam logic [ID_W-1:0] CORE_ID = 6'h01;
  localparam logic [ID_W-1:0] ISL_ID  = 6'h21;

  logic clk, rst_ni, init_done;
  int unsigned errors, cycles;

  AXI_BUS #(
      .AXI_ADDR_WIDTH ( ADDR_W ),
      .AXI_DATA_WIDTH ( DATA_W ),
      .AXI_ID_WIDTH   ( ID_W   ),
      .AXI_USER_WIDTH ( 1      )
  ) dram();

  g6lc_ai_litedram_wrap #(
      .AXI_ADDR_WIDTH ( ADDR_W ),
      .AXI_DATA_WIDTH ( DATA_W ),
      .AXI_ID_WIDTH   ( ID_W   ),
      .ForceInitDone  ( 1'b1 )
  ) i_dut (
      .clk_i      ( clk ),
      .rst_ni     ( rst_ni ),
      .slave      ( dram ),
      .init_done_o( init_done ),
      .pl_req_i   ( 1'b0 ),
      .pl_gnt_o   ( ),
      .pl_na_i    ( '0 ),
      .pl_data_i  ( '0 ),
      .pl_be_i    ( '0 ),
      .pl_idle_o  ( )
  );

  initial clk = 0;
  always #5 clk = ~clk;

  task automatic idle_m;
    dram.aw_valid = 1'b0;
    dram.w_valid  = 1'b0;
    dram.ar_valid = 1'b0;
    dram.b_ready  = 1'b1;
    dram.r_ready  = 1'b1;
    dram.aw_id    = '0;
    dram.aw_addr  = '0;
    dram.aw_len   = '0;
    dram.aw_size  = 3'd3;
    dram.aw_burst = 2'b01;
    dram.aw_lock  = 1'b0;
    dram.aw_cache = '0;
    dram.aw_prot  = '0;
    dram.aw_qos   = '0;
    dram.aw_region= '0;
    dram.aw_atop  = '0;
    dram.aw_user  = '0;
    dram.w_data   = '0;
    dram.w_strb   = '0;
    dram.w_last   = 1'b1;
    dram.w_user   = '0;
    dram.ar_id    = '0;
    dram.ar_addr  = '0;
    dram.ar_len   = '0;
    dram.ar_size  = 3'd3;
    dram.ar_burst = 2'b01;
    dram.ar_lock  = 1'b0;
    dram.ar_cache = '0;
    dram.ar_prot  = '0;
    dram.ar_qos   = '0;
    dram.ar_region= '0;
    dram.ar_user  = '0;
  endtask

  task automatic tick;
    @(posedge clk);
    cycles++;
  endtask

  // Combo-settle, wait until the slave is ready, then one handshake posedge.
  // Do not sample ready after that edge (fill/qn NBA can drop it).
  task automatic hs_aw_w(input int unsigned lim);
    int unsigned tlim;
    tlim = cycles + lim;
    #0;
    while (!(dram.aw_ready && dram.w_ready) && cycles < tlim) tick;
    if (!(dram.aw_ready && dram.w_ready)) begin
      $error("timeout AW/W id=%h addr=%h", dram.aw_id, dram.aw_addr);
      errors++;
    end else
      tick;
    dram.aw_valid = 1'b0;
    dram.w_valid  = 1'b0;
  endtask

  task automatic hs_aw(input int unsigned lim);
    int unsigned tlim;
    tlim = cycles + lim;
    #0;
    while (!dram.aw_ready && cycles < tlim) tick;
    if (!dram.aw_ready) begin
      $error("timeout AW");
      errors++;
    end else
      tick;
    dram.aw_valid = 1'b0;
  endtask

  task automatic hs_w(input int unsigned lim);
    int unsigned tlim;
    tlim = cycles + lim;
    #0;
    while (!dram.w_ready && cycles < tlim) tick;
    if (!dram.w_ready) begin
      $error("timeout W");
      errors++;
    end else
      tick;
  endtask

  task automatic hs_ar(input int unsigned lim);
    int unsigned tlim;
    tlim = cycles + lim;
    #0;
    while (!dram.ar_ready && cycles < tlim) tick;
    if (!dram.ar_ready) begin
      $error("timeout AR");
      errors++;
    end else
      tick;
    dram.ar_valid = 1'b0;
  endtask

  task automatic wait_b(input logic [ID_W-1:0] id, input int unsigned lim);
    int unsigned tlim;
    tlim = cycles + lim;
    #0;
    while (!dram.b_valid && cycles < tlim) tick;
    if (!dram.b_valid) begin
      $error("timeout B id=%h", id);
      errors++;
    end else if (dram.b_id !== id) begin
      $error("B id mismatch exp=%h got=%h", id, dram.b_id);
      errors++;
    end
    tick;
  endtask

  task automatic wait_b_resp(
      input logic [ID_W-1:0] id,
      input int unsigned     lim,
      input logic [1:0]      resp
  );
    int unsigned tlim;
    tlim = cycles + lim;
    #0;
    while (!dram.b_valid && cycles < tlim) tick;
    if (!dram.b_valid) begin
      $error("timeout B id=%h", id);
      errors++;
    end else begin
      if (dram.b_id !== id) begin
        $error("B id mismatch exp=%h got=%h", id, dram.b_id);
        errors++;
      end
      if (dram.b_resp !== resp) begin
        $error("B resp mismatch id=%h exp=%h got=%h", id, resp, dram.b_resp);
        errors++;
      end
    end
    tick;
  endtask

  task automatic wr_beat(
      input logic [ID_W-1:0]   id,
      input logic [ADDR_W-1:0] addr,
      input logic [DATA_W-1:0] data
  );
    dram.aw_id    = id;
    dram.aw_addr  = addr;
    dram.aw_len   = '0;
    dram.aw_size  = 3'd3;
    dram.aw_burst = 2'b01;
    dram.aw_valid = 1'b1;
    dram.w_data   = data;
    dram.w_strb   = 8'hFF;
    dram.w_last   = 1'b1;
    dram.w_valid  = 1'b1;
    hs_aw_w(40000);
    wait_b(id, 60000);
  endtask

  // Core WT-class narrow store (size 0/1/2, optional FIXED).
  task automatic wr_sz(
      input logic [ID_W-1:0]   id,
      input logic [ADDR_W-1:0] addr,
      input logic [2:0]        sz,
      input logic [1:0]        burst,
      input logic [7:0]        strb,
      input logic [DATA_W-1:0] data
  );
    dram.aw_id    = id;
    dram.aw_addr  = addr;
    dram.aw_len   = '0;
    dram.aw_size  = sz;
    dram.aw_burst = burst;
    dram.aw_valid = 1'b1;
    dram.w_data   = data;
    dram.w_strb   = strb;
    dram.w_last   = 1'b1;
    dram.w_valid  = 1'b1;
    hs_aw_w(40000);
    wait_b(id, 60000);
    dram.aw_size  = 3'd3;
    dram.aw_burst = 2'b01;
    dram.w_strb   = 8'hFF;
  endtask

  task automatic issue_sz(
      input logic [ID_W-1:0]   id,
      input logic [ADDR_W-1:0] addr,
      input logic [2:0]        sz,
      input logic [7:0]        strb,
      input logic [DATA_W-1:0] data
  );
    dram.aw_id    = id;
    dram.aw_addr  = addr;
    dram.aw_len   = '0;
    dram.aw_size  = sz;
    dram.aw_burst = 2'b01;
    dram.aw_valid = 1'b1;
    dram.w_data   = data;
    dram.w_strb   = strb;
    dram.w_last   = 1'b1;
    dram.w_valid  = 1'b1;
    hs_aw_w(40000);
    dram.aw_size  = 3'd3;
    dram.w_strb   = 8'hFF;
  endtask

  task automatic issue_aw_w(
      input logic [ID_W-1:0]   id,
      input logic [ADDR_W-1:0] addr,
      input logic [DATA_W-1:0] data
  );
    dram.aw_id    = id;
    dram.aw_addr  = addr;
    dram.aw_len   = '0;
    dram.aw_valid = 1'b1;
    dram.w_data   = data;
    dram.w_strb   = 8'hFF;
    dram.w_last   = 1'b1;
    dram.w_valid  = 1'b1;
    hs_aw_w(40000);
  endtask

  task automatic issue_ar(
      input logic [ID_W-1:0]   id,
      input logic [ADDR_W-1:0] addr,
      input logic [7:0]        len
  );
    dram.ar_id    = id;
    dram.ar_addr  = addr;
    dram.ar_len   = len;
    dram.ar_size  = 3'd3;
    dram.ar_burst = 2'b01;
    dram.ar_valid = 1'b1;
    hs_ar(80000);
    dram.ar_len   = '0;
  endtask

  task automatic collect_r_pair(
      input logic [DATA_W-1:0] exp_c,
      input logic [DATA_W-1:0] exp_i
  );
    logic got_c, got_i;
    got_c = 1'b0;
    got_i = 1'b0;
    begin
      int unsigned tlim;
      tlim = cycles + 100000;
      while ((!(got_c && got_i)) && cycles < tlim) begin
        #0;
        if (dram.r_valid) begin
          if (dram.r_id == CORE_ID) begin
            if (got_c) begin
              $error("extra CORE R in pair");
              errors++;
            end else if (dram.r_data !== exp_c) begin
              $error("pair CORE R exp=%h got=%h", exp_c, dram.r_data);
              errors++;
            end else if (dram.r_last !== 1'b1) begin
              $error("pair CORE R last");
              errors++;
            end
            got_c = 1'b1;
          end else if (dram.r_id == ISL_ID) begin
            if (got_i) begin
              $error("extra ISL R in pair");
              errors++;
            end else if (dram.r_data !== exp_i) begin
              $error("pair ISL R exp=%h got=%h", exp_i, dram.r_data);
              errors++;
            end else if (dram.r_last !== 1'b1) begin
              $error("pair ISL R last");
              errors++;
            end
            got_i = 1'b1;
          end else begin
            $error("unexpected R id=%h", dram.r_id);
            errors++;
          end
        end
        tick;
      end
    end
    if (!(got_c && got_i)) begin
      $error("timeout dual AR c=%0d i=%0d", got_c, got_i);
      errors++;
    end
  endtask

  task automatic collect_r_nbeats_pair(input int unsigned nbeats);
    int unsigned c_n, i_n;
    logic [DATA_W-1:0] exp;
    c_n = 0;
    i_n = 0;
    begin
      int unsigned tlim;
      tlim = cycles + 150000;
      while ((c_n < nbeats || i_n < nbeats) && cycles < tlim) begin
        #0;
        if (dram.r_valid) begin
          if (dram.r_id == CORE_ID) begin
            exp = {32'hC0DE_0000, 16'(CORE_ID), 16'(c_n)};
            if (c_n >= nbeats) begin
              $error("extra CORE nbeat R");
              errors++;
            end else begin
              if (dram.r_data !== exp) begin
                $error("dual 16B CORE beat=%0d exp=%h got=%h", c_n, exp, dram.r_data);
                errors++;
              end
              if (dram.r_last !== (c_n == nbeats - 1)) begin
                $error("dual 16B CORE last beat=%0d", c_n);
                errors++;
              end
              c_n++;
            end
          end else if (dram.r_id == ISL_ID) begin
            exp = {32'hC0DE_0000, 16'(ISL_ID), 16'(i_n)};
            if (i_n >= nbeats) begin
              $error("extra ISL nbeat R");
              errors++;
            end else begin
              if (dram.r_data !== exp) begin
                $error("dual 16B ISL beat=%0d exp=%h got=%h", i_n, exp, dram.r_data);
                errors++;
              end
              if (dram.r_last !== (i_n == nbeats - 1)) begin
                $error("dual 16B ISL last beat=%0d", i_n);
                errors++;
              end
              i_n++;
            end
          end else begin
            $error("unexpected nbeat R id=%h", dram.r_id);
            errors++;
          end
        end
        tick;
      end
    end
    if (c_n < nbeats || i_n < nbeats) begin
      $error("timeout dual 16B AR c=%0d i=%0d", c_n, i_n);
      errors++;
    end
  endtask

  task automatic collect_b_pair;
    logic got_c, got_i;
    got_c = 1'b0;
    got_i = 1'b0;
    begin
      int unsigned tlim;
      tlim = cycles + 80000;
      while ((!(got_c && got_i)) && cycles < tlim) begin
      if (dram.b_valid) begin
        if (dram.b_id == CORE_ID) got_c = 1'b1;
        else if (dram.b_id == ISL_ID) got_i = 1'b1;
        else begin
          $error("unexpected B id=%h", dram.b_id);
          errors++;
        end
      end
      tick;
      end
    end
    if (!(got_c && got_i)) begin
      $error("timeout concurrent B c=%0d i=%0d", got_c, got_i);
      errors++;
    end
  endtask

  task automatic rd_beat(
      input logic [ID_W-1:0]   id,
      input logic [ADDR_W-1:0] addr,
      input logic [DATA_W-1:0] exp
  );
    dram.ar_id    = id;
    dram.ar_addr  = addr;
    dram.ar_len   = '0;
    dram.ar_valid = 1'b1;
    hs_ar(80000);
    begin
      int unsigned tlim;
      tlim = cycles + 100000;
      #0;
      while (!dram.r_valid && cycles < tlim) tick;
    end
    if (!dram.r_valid) begin
      $error("timeout R id=%h", id);
      errors++;
    end else begin
      if (dram.r_id !== id) begin
        $error("R id mismatch exp=%h got=%h", id, dram.r_id);
        errors++;
      end
      if (dram.r_data !== exp) begin
        $error("R data mismatch addr=%h exp=%h got=%h", addr, exp, dram.r_data);
        errors++;
      end
    end
    tick;
  endtask

  // Multi-beat WRAP/FIXED: handshake, drain W, expect SLVERR, no native write.
  task automatic wr_bad_burst(
      input logic [ID_W-1:0]   id,
      input logic [ADDR_W-1:0] addr,
      input logic [1:0]        burst,
      input logic [7:0]        len,
      input logic [DATA_W-1:0] data
  );
    int unsigned beat;
    int unsigned nbeats;
    nbeats = unsigned'(len) + 1;
    dram.aw_id    = id;
    dram.aw_addr  = addr;
    dram.aw_len   = len;
    dram.aw_size  = 3'd3;
    dram.aw_burst = burst;
    dram.aw_valid = 1'b1;
    hs_aw(40000);
    for (beat = 0; beat < nbeats; beat++) begin
      dram.w_data  = data;
      dram.w_strb  = 8'hFF;
      dram.w_last  = (beat == nbeats - 1);
      dram.w_valid = 1'b1;
      hs_w(80000);
    end
    dram.w_valid  = 1'b0;
    dram.w_last   = 1'b1;
    dram.aw_burst = 2'b01;
    dram.aw_len   = '0;
    wait_b_resp(id, 100000, 2'b10);
  endtask

  task automatic rd_bad_burst(
      input logic [ID_W-1:0]   id,
      input logic [ADDR_W-1:0] addr,
      input logic [1:0]        burst,
      input logic [7:0]        len
  );
    int unsigned beat;
    int unsigned nbeats;
    nbeats = unsigned'(len) + 1;
    dram.ar_id    = id;
    dram.ar_addr  = addr;
    dram.ar_len   = len;
    dram.ar_size  = 3'd3;
    dram.ar_burst = burst;
    dram.ar_valid = 1'b1;
    hs_ar(80000);
    for (beat = 0; beat < nbeats; beat++) begin
      begin
        int unsigned tlim;
        tlim = cycles + 40000;
        #0;
        while (!dram.r_valid && cycles < tlim) tick;
      end
      if (!dram.r_valid) begin
        $error("timeout SLVERR R beat=%0d", beat);
        errors++;
      end else begin
        if (dram.r_id !== id) begin
          $error("SLVERR R id mismatch beat=%0d exp=%h got=%h", beat, id, dram.r_id);
          errors++;
        end
        if (dram.r_resp !== 2'b10) begin
          $error("SLVERR R resp mismatch beat=%0d got=%h", beat, dram.r_resp);
          errors++;
        end
        if (dram.r_last !== (beat == nbeats - 1)) begin
          $error("SLVERR R last mismatch beat=%0d", beat);
          errors++;
        end
      end
      tick;
    end
    dram.ar_burst = 2'b01;
    dram.ar_len   = '0;
  endtask

  task automatic wr_line64(
      input logic [ID_W-1:0]   id,
      input logic [ADDR_W-1:0] addr
  );
    int unsigned beat;
    dram.aw_id    = id;
    dram.aw_addr  = addr;
    dram.aw_len   = 8'd7;
    dram.aw_valid = 1'b1;
    hs_aw(40000);
    for (beat = 0; beat < 8; beat++) begin
      dram.w_data  = {32'hC0DE_0000, 16'(id), 16'(beat)};
      dram.w_strb  = 8'hFF;
      dram.w_last  = (beat == 7);
      dram.w_valid = 1'b1;
      hs_w(80000);
    end
    dram.w_valid = 1'b0;
    dram.w_last  = 1'b1;
    wait_b(id, 100000);
  endtask

  task automatic rd_line64(
      input logic [ID_W-1:0]   id,
      input logic [ADDR_W-1:0] addr
  );
    int unsigned beat;
    logic [DATA_W-1:0] exp;
    dram.ar_id    = id;
    dram.ar_addr  = addr;
    dram.ar_len   = 8'd7;
    dram.ar_valid = 1'b1;
    hs_ar(80000);
    for (beat = 0; beat < 8; beat++) begin
      begin
        int unsigned tlim;
        tlim = cycles + 120000;
        #0;
        while (!dram.r_valid && cycles < tlim) tick;
      end
      exp = {32'hC0DE_0000, 16'(id), 16'(beat)};
      if (!dram.r_valid) begin
        $error("timeout line R beat=%0d", beat);
        errors++;
      end else begin
        if (dram.r_id !== id) begin
          $error("line R id mismatch beat=%0d exp=%h got=%h", beat, id, dram.r_id);
          errors++;
        end
        if (dram.r_data !== exp) begin
          $error("line R data mismatch beat=%0d exp=%h got=%h", beat, exp, dram.r_data);
          errors++;
        end
        if (dram.r_last !== (beat == 7)) begin
          $error("line R last mismatch beat=%0d", beat);
          errors++;
        end
      end
      tick;
    end
  endtask

  // L1 I$/D$ fill is 16 B (line width 128) = 2×64-bit INCR. nbeats=4 starts
  // at sl=2 to straddle two native 32 B words (take() remainder).
  task automatic wr_nbeats(
      input logic [ID_W-1:0]   id,
      input logic [ADDR_W-1:0] addr,
      input int unsigned       nbeats
  );
    int unsigned beat;
    dram.aw_id    = id;
    dram.aw_addr  = addr;
    dram.aw_len   = 8'(nbeats - 1);
    dram.aw_size  = 3'd3;
    dram.aw_burst = 2'b01;
    dram.aw_valid = 1'b1;
    hs_aw(40000);
    for (beat = 0; beat < nbeats; beat++) begin
      dram.w_data  = {32'hC0DE_0000, 16'(id), 16'(beat)};
      dram.w_strb  = 8'hFF;
      dram.w_last  = (beat == nbeats - 1);
      dram.w_valid = 1'b1;
      hs_w(80000);
    end
    dram.w_valid = 1'b0;
    dram.w_last  = 1'b1;
    dram.aw_len  = '0;
    wait_b(id, 100000);
  endtask

  task automatic rd_nbeats(
      input logic [ID_W-1:0]   id,
      input logic [ADDR_W-1:0] addr,
      input int unsigned       nbeats
  );
    int unsigned beat;
    logic [DATA_W-1:0] exp;
    dram.ar_id    = id;
    dram.ar_addr  = addr;
    dram.ar_len   = 8'(nbeats - 1);
    dram.ar_size  = 3'd3;
    dram.ar_burst = 2'b01;
    dram.ar_valid = 1'b1;
    hs_ar(80000);
    for (beat = 0; beat < nbeats; beat++) begin
      begin
        int unsigned tlim;
        tlim = cycles + 120000;
        #0;
        while (!dram.r_valid && cycles < tlim) tick;
      end
      exp = {32'hC0DE_0000, 16'(id), 16'(beat)};
      if (!dram.r_valid) begin
        $error("timeout nbeat R beat=%0d addr=%h", beat, addr);
        errors++;
      end else begin
        if (dram.r_id !== id) begin
          $error("nbeat R id mismatch beat=%0d exp=%h got=%h", beat, id, dram.r_id);
          errors++;
        end
        if (dram.r_data !== exp) begin
          $error("nbeat R data mismatch beat=%0d addr=%h exp=%h got=%h",
                 beat, addr, exp, dram.r_data);
          errors++;
        end
        if (dram.r_last !== (beat == nbeats - 1)) begin
          $error("nbeat R last mismatch beat=%0d addr=%h", beat, addr);
          errors++;
        end
      end
      tick;
    end
    dram.ar_len = '0;
  endtask

  // NC D$ load: AR size 0/1/2, one beat. Full 64-bit slot, valid lanes by addr.
  task automatic rd_sz(
      input logic [ID_W-1:0]   id,
      input logic [ADDR_W-1:0] addr,
      input logic [2:0]        sz,
      input logic [DATA_W-1:0] exp
  );
    dram.ar_id    = id;
    dram.ar_addr  = addr;
    dram.ar_len   = '0;
    dram.ar_size  = sz;
    dram.ar_burst = 2'b01;
    dram.ar_valid = 1'b1;
    hs_ar(80000);
    begin
      int unsigned tlim;
      tlim = cycles + 100000;
      #0;
      while (!dram.r_valid && cycles < tlim) tick;
    end
    if (!dram.r_valid) begin
      $error("timeout R sz=%0d id=%h", sz, id);
      errors++;
    end else begin
      if (dram.r_id !== id) begin
        $error("R sz id mismatch exp=%h got=%h", id, dram.r_id);
        errors++;
      end
      if (dram.r_data !== exp) begin
        $error("R sz data mismatch addr=%h sz=%0d exp=%h got=%h",
               addr, sz, exp, dram.r_data);
        errors++;
      end
      if (dram.r_resp !== 2'b00) begin
        $error("R sz resp mismatch got=%h", dram.r_resp);
        errors++;
      end
    end
    tick;
    dram.ar_size = 3'd3;
  endtask

  initial begin
    errors = 0;
    cycles = 0;
    rst_ni = 1'b0;
    idle_m();
    repeat (8) tick;
    rst_ni = 1'b1;
    repeat (32) tick;

    if (!init_done) begin
      $error("ForceInitDone should pin init_done");
      errors++;
    end

    // Cluster-like ID, DRAMBase alias.
    wr_beat(CORE_ID, 64'h8000_0000, 64'hA5A5_A5A5_A5A5_A5A5);
    rd_beat(CORE_ID, 64'h8000_0000, 64'hA5A5_A5A5_A5A5_A5A5);

    // Island DMA-like ID, different beat (same 64 B stripe).
    wr_beat(ISL_ID, 64'h8000_0008, 64'hB6B6_B6B6_B6B6_B6B6);
    rd_beat(ISL_ID, 64'h8000_0008, 64'hB6B6_B6B6_B6B6_B6B6);
    rd_beat(CORE_ID, 64'h8000_0000, 64'hA5A5_A5A5_A5A5_A5A5);

    // L2-class 64 B INCR fill (must not straddle default stripe).
    wr_line64(CORE_ID, 64'h8000_0040);
    rd_line64(CORE_ID, 64'h8000_0040);

    // Core-class narrow INCR/FIXED (WT byte/half/word). Must not stall aw_ready.
    wr_sz(CORE_ID, 64'h8000_0080, 3'd0, 2'b01, 8'h01, 64'h0000_0000_0000_00AB);
    rd_beat(CORE_ID, 64'h8000_0080, 64'h0000_0000_0000_00AB);
    wr_sz(CORE_ID, 64'h8000_0088, 3'd1, 2'b01, 8'h03, 64'h0000_0000_0000_CDEF);
    rd_beat(CORE_ID, 64'h8000_0088, 64'h0000_0000_0000_CDEF);
    wr_sz(CORE_ID, 64'h8000_0090, 3'd2, 2'b01, 8'h0F, 64'h0000_0000_1234_5678);
    rd_beat(CORE_ID, 64'h8000_0090, 64'h0000_0000_1234_5678);
    wr_sz(CORE_ID, 64'h8000_0098, 3'd0, 2'b00, 8'h01, 64'h0000_0000_0000_00EF);
    rd_beat(CORE_ID, 64'h8000_0098, 64'h0000_0000_0000_00EF);

    // ST.B after SD in the same 8 B (native byte-enable merge).
    wr_beat(CORE_ID, 64'h8000_00A0, 64'hA5A5_A5A5_A5A5_A5A5);
    wr_sz(CORE_ID, 64'h8000_00A0, 3'd0, 2'b01, 8'h01, 64'h0000_0000_0000_0011);
    rd_beat(CORE_ID, 64'h8000_00A0, 64'hA5A5_A5A5_A5A5_A511);
    wr_sz(CORE_ID, 64'h8000_00A1, 3'd0, 2'b01, 8'h02, 64'h0000_0000_0000_2200);
    rd_beat(CORE_ID, 64'h8000_00A0, 64'hA5A5_A5A5_A5A5_2211);
    // ST.H at +2 (bytes 2–3) after SD+ST.B merge.
    wr_sz(CORE_ID, 64'h8000_00A2, 3'd1, 2'b01, 8'h0C, 64'h0000_0000_3344_0000);
    rd_beat(CORE_ID, 64'h8000_00A0, 64'hA5A5_A5A5_3344_2211);

    // Single-beat WRAP is INCR len=0 (legal). Multi-beat WRAP must SLVERR
    // without stalling aw_ready and without a native write.
    wr_sz(CORE_ID, 64'h8000_00E0, 3'd3, 2'b10, 8'hFF, 64'hE0E0_E0E0_E0E0_E0E0);
    rd_beat(CORE_ID, 64'h8000_00E0, 64'hE0E0_E0E0_E0E0_E0E0);
    wr_beat(CORE_ID, 64'h8000_00D0, 64'h1111_1111_1111_1111);
    wr_bad_burst(CORE_ID, 64'h8000_00D0, 2'b10, 8'd1, 64'hDEAD_BEEF_DEAD_BEEF);
    rd_beat(CORE_ID, 64'h8000_00D0, 64'h1111_1111_1111_1111);
    rd_bad_burst(CORE_ID, 64'h8000_00D0, 2'b10, 8'd1);
    rd_beat(CORE_ID, 64'h8000_00D0, 64'h1111_1111_1111_1111);

    // L1 I$/D$ 16 B INCR (line width 128). Aligned + offset 16 (slots 2–3).
    wr_nbeats(CORE_ID, 64'h8000_0100, 2);
    rd_nbeats(CORE_ID, 64'h8000_0100, 2);
    wr_nbeats(CORE_ID, 64'h8000_0110, 2);
    rd_nbeats(CORE_ID, 64'h8000_0110, 2);
    // 32 B starting at sl=2 straddles two native words.
    wr_nbeats(CORE_ID, 64'h8000_0130, 4);
    rd_nbeats(CORE_ID, 64'h8000_0130, 4);

    // ST.W at +4 (bytes 4–7) after a full SD.
    wr_beat(CORE_ID, 64'h8000_00F0, 64'hAABB_CCDD_EEFF_0011);
    wr_sz(CORE_ID, 64'h8000_00F4, 3'd2, 2'b01, 8'hF0, 64'h9988_7766_0000_0000);
    rd_beat(CORE_ID, 64'h8000_00F0, 64'h9988_7766_EEFF_0011);

    // NC D$ load: AR size 0/1/2, one beat, full slot (valid lanes by addr).
    rd_sz(CORE_ID, 64'h8000_0080, 3'd0, 64'h0000_0000_0000_00AB);
    rd_sz(CORE_ID, 64'h8000_0088, 3'd1, 64'h0000_0000_0000_CDEF);
    rd_sz(CORE_ID, 64'h8000_0090, 3'd2, 64'h0000_0000_1234_5678);

    // AR while B is outstanding (store WT + miss fill). Data must be visible.
    dram.b_ready = 1'b0;
    issue_aw_w(CORE_ID, 64'h8000_0200, 64'hFEED_FACE_CAFE_F00D);
    dram.ar_id    = CORE_ID;
    dram.ar_addr  = 64'h8000_0200;
    dram.ar_len   = '0;
    dram.ar_size  = 3'd3;
    dram.ar_burst = 2'b01;
    dram.ar_valid = 1'b1;
    hs_ar(80000);
    begin
      int unsigned tlim;
      tlim = cycles + 100000;
      #0;
      while (!dram.r_valid && cycles < tlim) tick;
    end
    if (!dram.r_valid) begin
      $error("timeout R-while-B");
      errors++;
    end else if (dram.r_data !== 64'hFEED_FACE_CAFE_F00D) begin
      $error("R-while-B data exp=FEEDFACECAFEF00D got=%h", dram.r_data);
      errors++;
    end
    tick;
    dram.b_ready = 1'b1;
    wait_b(CORE_ID, 60000);

    // Two outstanding AR (I$ + D$ miss / L2 MSHR). Hold r_ready until both
    // accepted so both wrap slots are live.
    wr_beat(CORE_ID, 64'h8000_0300, 64'h1111_2222_3333_4444);
    wr_beat(ISL_ID,  64'h8000_0308, 64'h5555_6666_7777_8888);
    dram.r_ready = 1'b0;
    issue_ar(CORE_ID, 64'h8000_0300, 8'd0);
    issue_ar(ISL_ID,  64'h8000_0308, 8'd0);
    dram.r_ready = 1'b1;
    collect_r_pair(64'h1111_2222_3333_4444, 64'h5555_6666_7777_8888);

    wr_nbeats(CORE_ID, 64'h8000_0320, 2);
    wr_nbeats(ISL_ID,  64'h8000_0340, 2);
    dram.r_ready = 1'b0;
    issue_ar(CORE_ID, 64'h8000_0320, 8'd1);
    issue_ar(ISL_ID,  64'h8000_0340, 8'd1);
    dram.r_ready = 1'b1;
    collect_r_nbeats_pair(2);

    // L2 two-MSHR: two outstanding 64 B INCR fills.
    wr_nbeats(CORE_ID, 64'h8000_0400, 8);
    wr_nbeats(ISL_ID,  64'h8000_0440, 8);
    dram.r_ready = 1'b0;
    issue_ar(CORE_ID, 64'h8000_0400, 8'd7);
    issue_ar(ISL_ID,  64'h8000_0440, 8'd7);
    dram.r_ready = 1'b1;
    collect_r_nbeats_pair(8);

    // Mixed AW+AR two IDs (core WT store + island/I$ fill).
    dram.b_ready = 1'b0;
    issue_aw_w(CORE_ID, 64'h8000_0500, 64'hA0A0_A0A0_A0A0_A0A0);
    issue_ar(ISL_ID, 64'h8000_0308, 8'd0);
    begin
      int unsigned tlim;
      tlim = cycles + 100000;
      #0;
      while (!dram.r_valid && cycles < tlim) tick;
    end
    if (!dram.r_valid) begin
      $error("timeout mixed AR");
      errors++;
    end else if (dram.r_id !== ISL_ID) begin
      $error("mixed AR id exp=%h got=%h", ISL_ID, dram.r_id);
      errors++;
    end else if (dram.r_data !== 64'h5555_6666_7777_8888) begin
      $error("mixed AR data got=%h", dram.r_data);
      errors++;
    end
    tick;
    dram.b_ready = 1'b1;
    wait_b(CORE_ID, 60000);
    rd_beat(CORE_ID, 64'h8000_0500, 64'hA0A0_A0A0_A0A0_A0A0);

    // Eight outstanding AR (MaxAROut=8 / L2 MSHR). 9th backpressures.
    begin
      int unsigned s;
      logic [7:0] got;
      logic [ID_W-1:0] aid;
      logic [63:0] aaddr, adata;
      for (s = 0; s < 8; s++) begin
        aid   = ID_W'(s);
        aaddr = 64'h8000_0700 + (64'(s) << 3);
        adata = 64'h7000_0000_0000_0000 | 64'(s);
        wr_beat(aid, aaddr, adata);
      end
      dram.r_ready = 1'b0;
      for (s = 0; s < 8; s++) begin
        aid   = ID_W'(s);
        aaddr = 64'h8000_0700 + (64'(s) << 3);
        issue_ar(aid, aaddr, 8'd0);
      end
      dram.ar_id    = ID_W'(8);
      dram.ar_addr  = 64'h8000_0740;
      dram.ar_len   = '0;
      dram.ar_valid = 1'b1;
      begin
        int unsigned k;
        for (k = 0; k < 16; k++) begin
          #0;
          if (dram.ar_ready) begin
            $error("9th AR ready with 8 slots live");
            errors++;
          end
          tick;
        end
      end
      dram.ar_valid = 1'b0;
      dram.r_ready  = 1'b1;
      got = '0;
      begin
        int unsigned tlim;
        tlim = cycles + 200000;
        while ((got != 8'hFF) && cycles < tlim) begin
          #0;
          if (dram.r_valid) begin
            s = int'(dram.r_id);
            if (s > 7) begin
              $error("AR8 unexpected id=%h", dram.r_id);
              errors++;
            end else if (got[s]) begin
              $error("AR8 extra R id=%0d", s);
              errors++;
            end else if (dram.r_data !== (64'h7000_0000_0000_0000 | 64'(s))) begin
              $error("AR8 data id=%0d got=%h", s, dram.r_data);
              errors++;
            end else
              got[s] = 1'b1;
          end
          tick;
        end
        if (got != 8'hFF) begin
          $error("AR8 timeout got=%b", got);
          errors++;
        end
      end
    end

    // Eight outstanding AW (MaxAROut=8 / NrCores + island DMA). 9th
    // backpressures. 32 B stride so each write is its own native word.
    begin
      int unsigned s;
      logic [7:0] got;
      logic [ID_W-1:0] aid;
      logic [63:0] aaddr, adata;
      dram.b_ready = 1'b0;
      for (s = 0; s < 8; s++) begin
        aid   = ID_W'(s);
        aaddr = 64'h8000_0800 + (64'(s) << 5);
        adata = 64'h8000_0000_0000_0000 | 64'(s);
        issue_aw_w(aid, aaddr, adata);
      end
      dram.aw_id    = ID_W'(8);
      dram.aw_addr  = 64'h8000_0900;
      dram.aw_len   = '0;
      dram.aw_valid = 1'b1;
      dram.w_data   = 64'hDEAD_BEEF_DEAD_BEEF;
      dram.w_strb   = 8'hFF;
      dram.w_last   = 1'b1;
      dram.w_valid  = 1'b1;
      begin
        int unsigned k;
        for (k = 0; k < 16; k++) begin
          #0;
          if (dram.aw_ready) begin
            $error("9th AW ready with 8 slots live");
            errors++;
          end
          tick;
        end
      end
      dram.aw_valid = 1'b0;
      dram.w_valid  = 1'b0;
      dram.b_ready  = 1'b1;
      got = '0;
      begin
        int unsigned tlim;
        tlim = cycles + 200000;
        while ((got != 8'hFF) && cycles < tlim) begin
          #0;
          if (dram.b_valid) begin
            s = int'(dram.b_id);
            if (s > 7) begin
              $error("AW8 unexpected B id=%h", dram.b_id);
              errors++;
            end else if (got[s]) begin
              $error("AW8 extra B id=%0d", s);
              errors++;
            end else if (dram.b_resp !== 2'b00) begin
              $error("AW8 B resp id=%0d got=%h", s, dram.b_resp);
              errors++;
            end else
              got[s] = 1'b1;
          end
          tick;
        end
        if (got != 8'hFF) begin
          $error("AW8 timeout got=%b", got);
          errors++;
        end
      end
      for (s = 0; s < 8; s++) begin
        aid   = ID_W'(s);
        aaddr = 64'h8000_0800 + (64'(s) << 5);
        adata = 64'h8000_0000_0000_0000 | 64'(s);
        rd_beat(aid, aaddr, adata);
      end
    end

    // Two IDs in flight on ONE PHY (slot table + LiteDRAM BID).
    dram.b_ready = 1'b0;
    issue_aw_w(CORE_ID, 64'h8000_0010, 64'hC1C1_C1C1_C1C1_C1C1);
    issue_aw_w(ISL_ID,  64'h8000_0018, 64'hD2D2_D2D2_D2D2_D2D2);
    dram.b_ready = 1'b1;
    collect_b_pair();
    rd_beat(CORE_ID, 64'h8000_0010, 64'hC1C1_C1C1_C1C1_C1C1);
    rd_beat(ISL_ID,  64'h8000_0018, 64'hD2D2_D2D2_D2D2_D2D2);

    // Two narrow IDs in flight (cluster ST.B + island ST.B).
    dram.b_ready = 1'b0;
    issue_sz(CORE_ID, 64'h8000_00C0, 3'd0, 8'h01, 64'h0000_0000_0000_0033);
    issue_sz(ISL_ID,  64'h8000_00C8, 3'd0, 8'h01, 64'h0000_0000_0000_0044);
    dram.b_ready = 1'b1;
    collect_b_pair();
    rd_beat(CORE_ID, 64'h8000_00C0, 64'h0000_0000_0000_0033);
    rd_beat(ISL_ID,  64'h8000_00C8, 64'h0000_0000_0000_0044);

    if (errors == 0) $display("PASS g6lc_ai_litedram_wrap id6 ar8 aw8 cycles=%0d", cycles);
    else begin
      $display("FAIL g6lc_ai_litedram_wrap errors=%0d", errors);
      $fatal(1);
    end
    $finish;
  end
endmodule
