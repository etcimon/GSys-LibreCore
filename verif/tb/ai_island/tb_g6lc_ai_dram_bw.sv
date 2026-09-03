// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// Directed class-1 LiteDRAM --sim stream bandwidth (not Variane, not 400 GB/s).
// Native 256-bit user port: g6lc_ai_litedram_wrap packs 4 AXI beats / native
// cmd and always accepts rdata (LiteDRAM crossbar does not backpressure).
// Directed stream is 256-beat INCR (N=1, no stripe).

`timescale 1ns/1ps
`include "axi/assign.svh"

module tb_g6lc_ai_dram_bw;
  localparam int unsigned ID_W   = 4;
  localparam int unsigned ADDR_W = 64;
  localparam int unsigned DATA_W = 64;
  localparam int unsigned LEN    = 255;         // 256 beats = 2 KiB (N=1, no stripe cap)
  localparam int unsigned NBEAT  = LEN + 1;
  localparam int unsigned NBURST = 8;           // 16 KiB window
  localparam int unsigned TOTAL  = NBEAT * NBURST;
  localparam int unsigned MAXINF = 8;
  localparam int unsigned TO     = 200000;
  localparam int unsigned FABRIC_MILLI = 8000;  // 8 GB/s
  localparam int unsigned GATE_MILLI   = 6400;  // 80% of fabric
  localparam logic [63:0] BASE = 64'h8000_0000;

  logic clk, rst_ni, init_done;
  int unsigned errors, cycles, beats, t0, t1, milli, pct;
  int unsigned next_wr, inflight, burst_done;

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

  task automatic tick;
    @(posedge clk);
    cycles++;
  endtask

  task automatic idle_m;
    dram.aw_valid = 1'b0;
    dram.w_valid  = 1'b0;
    dram.ar_valid = 1'b0;
    dram.b_ready  = 1'b1;
    dram.r_ready  = 1'b1;
    dram.aw_id    = '0;
    dram.aw_addr  = '0;
    dram.aw_len   = 8'(LEN);
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
    dram.w_strb   = 8'hFF;
    dram.w_last   = 1'b1;
    dram.w_user   = '0;
    dram.ar_id    = '0;
    dram.ar_addr  = '0;
    dram.ar_len   = 8'(LEN);
    dram.ar_size  = 3'd3;
    dram.ar_burst = 2'b01;
    dram.ar_lock  = 1'b0;
    dram.ar_cache = '0;
    dram.ar_prot  = '0;
    dram.ar_qos   = '0;
    dram.ar_region= '0;
    dram.ar_user  = '0;
  endtask

  task automatic wr_burst(input int unsigned idx);
    int unsigned beat;
    dram.aw_id    = 4'd1;
    dram.aw_addr  = BASE + (64'(idx) * 64'(NBEAT * 8));
    dram.aw_len   = 8'(LEN);
    dram.aw_valid = 1'b1;
    begin
      int unsigned tlim;
      tlim = cycles + TO;
      while (!dram.aw_ready && cycles < tlim) tick;
    end
    if (!dram.aw_ready) begin
      $error("timeout AW idx=%0d", idx);
      errors++;
    end
    tick;
    dram.aw_valid = 1'b0;
    for (beat = 0; beat < NBEAT; beat++) begin
      dram.w_data  = {32'(idx), 32'(beat)};
      dram.w_strb  = 8'hFF;
      dram.w_last  = (beat == NBEAT - 1);
      dram.w_valid = 1'b1;
      begin
        int unsigned tlim;
        tlim = cycles + TO;
        while (!dram.w_ready && cycles < tlim) tick;
      end
      if (!dram.w_ready) begin
        $error("timeout W idx=%0d beat=%0d", idx, beat);
        errors++;
      end
      tick;
    end
    dram.w_valid = 1'b0;
    dram.w_last  = 1'b1;
    begin
      int unsigned tlim;
      tlim = cycles + TO;
      while (!dram.b_valid && cycles < tlim) tick;
    end
    if (!dram.b_valid) begin
      $error("timeout B idx=%0d", idx);
      errors++;
    end
    tick;
  endtask

  initial begin
    errors = 0;
    cycles = 0;
    beats = 0;
    milli = 0;
    pct = 0;
    next_wr = 0;
    inflight = 0;
    burst_done = 0;
    rst_ni = 1'b0;
    idle_m();
    repeat (8) tick;
    rst_ni = 1'b1;
    idle_m();
    repeat (32) tick;

    if (!init_done) begin
      $error("init_done");
      errors++;
    end

    for (int unsigned i = 0; i < NBURST; i++)
      wr_burst(i);

    t0 = cycles;
    while ((burst_done < NBURST) && cycles < (t0 + TO)) begin
      if ((inflight < MAXINF) && (next_wr < NBURST)) begin
        dram.ar_id   = 4'(1 + (next_wr % MAXINF));
        dram.ar_addr = BASE + (64'(next_wr) * 64'(NBEAT * 8));
        dram.ar_len  = 8'(LEN);
        dram.ar_valid = 1'b1;
      end else
        dram.ar_valid = 1'b0;

      tick;

      if (dram.ar_valid && dram.ar_ready) begin
        next_wr++;
        inflight++;
      end
      if (dram.r_valid && dram.r_ready) begin
        beats++;
        if (dram.r_last) begin
          inflight--;
          burst_done++;
        end
      end
    end
    dram.ar_valid = 1'b0;
    t1 = cycles;

    if (beats != TOTAL) begin
      $display("stall r0v=%0d r0bi=%0d r0inf=%0d r1v=%0d r1bi=%0d r1inf=%0d mc=%0d dc=%0d ev=%0d el=%0d nwb=%0d nrv=%0d nrr=%0d ncv=%0d ncr=%0d qn=%0d/%0d",
               i_dut.r0v, i_dut.r0bi, i_dut.r0inf, i_dut.r1v, i_dut.r1bi, i_dut.r1inf,
               i_dut.mc, i_dut.dc, i_dut.ev, i_dut.el, i_dut.nwb,
               i_dut.n_r_valid, i_dut.n_r_ready, i_dut.n_cmd_valid, i_dut.n_cmd_ready,
               i_dut.w0qn, i_dut.w1qn);
      $error("beat count exp=%0d got=%0d inflight=%0d burst_done=%0d",
             TOTAL, beats, inflight, burst_done);
      errors++;
    end
    if (t1 <= t0) begin
      $error("empty measurement window");
      errors++;
    end else begin
      milli = (beats * FABRIC_MILLI) / (t1 - t0);
      pct   = (milli * 100) / FABRIC_MILLI;
      $display("g6lc_ai_dram_bw beats=%0d cy=%0d milli=%0d pct=%0d of fabric 8 GB/s",
               beats, t1 - t0, milli, pct);
      if (milli == 0) begin
        $error("zero measured bandwidth");
        errors++;
      end else if (milli < GATE_MILLI)
        $display("GATE open: class-1 --sim %0d milli-GB/s < %0d (80%% of min(19,8))",
                 milli, GATE_MILLI);
      else
        $display("GATE closed: class-1 --sim %0d milli-GB/s ≥ %0d (80%% of min(19,8))",
                 milli, GATE_MILLI);
    end

    if (errors == 0)
      $display("PASS g6lc_ai_dram_bw beats=%0d cy=%0d milli=%0d pct=%0d --sim",
               beats, t1 - t0, milli, pct);
    else begin
      $display("FAIL g6lc_ai_dram_bw errors=%0d milli=%0d", errors, milli);
      $fatal(1);
    end
    $finish;
  end
endmodule
