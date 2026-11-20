// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Command sequence for g6lc_apu_qrypool.  Does not elaborate the
// raster, the shader wave, or the executor.
`timescale 1ns/1ps
module tb_g6lc_apu_qrypool;
  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic        req;
  logic [2:0]  op;
  logic [7:0]  qtype;
  logic [31:0] mask, flags;
  logic [15:0] index, count;
  logic [31:0] sub, dst_off, extent;
  logic [63:0] stride;
  logic [127:0] stat;
  logic        err, nrdy;
  logic [4:0]  nw;
  logic [9:0][31:0] rec;
  logic [15:0][31:0] dst;
  int checks = 0, fails = 0;
  logic saw_err, saw_nrdy;

  g6lc_apu_qrypool dut (
    .clk_i(clk), .rst_ni(rst_n), .req_i(req), .op_i(op),
    .qtype_i(qtype), .mask_i(mask), .index_i(index), .count_i(count),
    .flags_i(flags), .sub_i(sub), .dst_off_i(dst_off),
    .stride_i(stride), .extent_i(extent), .stat_i(stat),
    .err_o(err), .nrdy_o(nrdy), .nw_o(nw), .rec_o(rec), .dst_o(dst));

  function automatic logic [127:0] bus(
      input logic [31:0] fs, input logic [31:0] occ,
      input logic [31:0] prim, input logic [31:0] vtx);
    bus = {fs, occ, prim, vtx};
  endfunction

  task automatic cmd(input logic [2:0] cop, input logic [7:0] ct,
                     input logic [31:0] cm, input logic [15:0] ci,
                     input logic [15:0] cn, input logic [31:0] cf,
                     input logic [127:0] cs);
    op = cop; qtype = ct; mask = cm; index = ci; count = cn;
    flags = cf; stat = cs; req = 1'b1;
    #1 begin saw_err = err; saw_nrdy = nrdy; end
    @(posedge clk);
    @(negedge clk);
    req = 1'b0;
  endtask

  task automatic want(input string name, input logic eerr,
                      input logic [4:0] enw, input logic [31:0] w0,
                      input logic [31:0] w1, input logic [31:0] w2,
                      input logic [31:0] w3);
    checks++;
    if (saw_err != eerr || nw != enw || rec[0] != w0 || rec[1] != w1 ||
        rec[2] != w2 || rec[3] != w3) begin
      fails++;
      $display("FAIL %s err=%0d nw=%0d rec=%08x %08x %08x %08x",
               name, err, nw, rec[0], rec[1], rec[2], rec[3]);
    end
  endtask

  initial begin
    req = 0; op = 0; qtype = 0; mask = 0; index = 0; count = 0;
    flags = 0; stat = 0; sub = 0; dst_off = 0; stride = 0;
    extent = 32'h1000;
    rst_n = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    @(negedge clk);

    // Reset the pool, then an unread occlusion slot copies as zero.
    cmd(3'd0, 8'd0, 32'h0, 16'd0, 16'd8, 32'h0, 128'h0);
    want("reset", 1'b0, 5'd0, 32'd0, 32'd0, 32'd0, 32'd0);
    cmd(3'd4, 8'd0, 32'h0, 16'd0, 16'd1, 32'h0, 128'h0);
    want("unread", 1'b0, 5'd1, 32'd0, 32'd0, 32'd0, 32'd0);

    // Occlusion window: samples 3 -> 10.
    cmd(3'd2, 8'd0, 32'h0, 16'd0, 16'd0, 32'h1,
        bus(32'd0, 32'd3, 32'd0, 32'd0));
    want("begin", 1'b0, 5'd0, 32'd0, 32'd0, 32'd0, 32'd0);
    cmd(3'd2, 8'd0, 32'h0, 16'd0, 16'd0, 32'h0,
        bus(32'd0, 32'd10, 32'd0, 32'd0));
    want("double-begin", 1'b1, 5'd0, 32'd0, 32'd0, 32'd0, 32'd0);
    cmd(3'd3, 8'd0, 32'h0, 16'd0, 16'd0, 32'h0,
        bus(32'd0, 32'd10, 32'd1, 32'd4));
    want("end", 1'b0, 5'd0, 32'd0, 32'd0, 32'd0, 32'd0);
    cmd(3'd4, 8'd0, 32'h0, 16'd0, 16'd1, 32'h9, 128'h0);
    want("occ-copy", 1'b0, 5'd4, 32'd7, 32'd0, 32'd1, 32'd0);

    // A second index can be open while the first result stays put.
    cmd(3'd2, 8'd0, 32'h0, 16'd1, 16'd0, 32'h0,
        bus(32'd1, 32'd10, 32'd1, 32'd4));
    cmd(3'd3, 8'd0, 32'h0, 16'd1, 16'd0, 32'h0,
        bus(32'd1, 32'd12, 32'd1, 32'd4));
    cmd(3'd4, 8'd0, 32'h0, 16'd0, 16'd1, 32'h0, 128'h0);
    want("occ-kept", 1'b0, 5'd1, 32'd7, 32'd0, 32'd0, 32'd0);
    cmd(3'd4, 8'd0, 32'h0, 16'd1, 16'd1, 32'h0, 128'h0);
    want("occ-2", 1'b0, 5'd1, 32'd2, 32'd0, 32'd0, 32'd0);

    // Statistics mask 0x87, then a fragment-only mask on another slot.
    cmd(3'd2, 8'd1, 32'h87, 16'd2, 16'd0, 32'h0,
        bus(32'd1, 32'd0, 32'd4, 32'd5));
    cmd(3'd3, 8'd1, 32'h87, 16'd2, 16'd0, 32'h0,
        bus(32'd9, 32'd0, 32'd8, 32'd7));
    cmd(3'd4, 8'd1, 32'h87, 16'd2, 16'd1, 32'h0, 128'h0);
    want("stats", 1'b0, 5'd4, 32'd2, 32'd4, 32'd2, 32'd8);

    cmd(3'd2, 8'd1, 32'h80, 16'd3, 16'd0, 32'h0,
        bus(32'd9, 32'd0, 32'd8, 32'd7));
    cmd(3'd3, 8'd1, 32'h80, 16'd3, 16'd0, 32'h0,
        bus(32'd14, 32'd0, 32'd8, 32'd7));
    cmd(3'd4, 8'd1, 32'h80, 16'd3, 16'd1, 32'h0, 128'h0);
    want("fs-only", 1'b0, 5'd1, 32'd5, 32'd0, 32'd0, 32'd0);

    // Timestamp write is a defined zero and does not open a window.
    cmd(3'd1, 8'd2, 32'h0, 16'd4, 16'd0, 32'h0, 128'h0);
    cmd(3'd4, 8'd2, 32'h0, 16'd4, 16'd1, 32'h8, 128'h0);
    want("timestamp", 1'b0, 5'd2, 32'd0, 32'd1, 32'd0, 32'd0);
    cmd(3'd3, 8'd2, 32'h0, 16'd4, 16'd0, 32'h0, 128'h0);
    want("ts-end", 1'b0, 5'd0, 32'd0, 32'd0, 32'd0, 32'd0);

    // Refusals leave the published occlusion result alone.
    cmd(3'd3, 8'd0, 32'h0, 16'd5, 16'd0, 32'h0, 128'h0);
    want("end-none", 1'b1, 5'd0, 32'd0, 32'd0, 32'd0, 32'd0);
    cmd(3'd2, 8'd0, 32'h0, 16'd0, 16'd0, 32'd2, 128'h0);
    want("bad-flag", 1'b1, 5'd0, 32'd0, 32'd0, 32'd0, 32'd0);
    cmd(3'd1, 8'd0, 32'h0, 16'd0, 16'd0, 32'h0, 128'h0);
    want("ts-on-occ", 1'b1, 5'd0, 32'd0, 32'd0, 32'd0, 32'd0);
    cmd(3'd4, 8'd0, 32'h0, 16'd8, 16'd1, 32'h0, 128'h0);
    want("oob", 1'b1, 5'd0, 32'd0, 32'd0, 32'd0, 32'd0);
    cmd(3'd0, 8'd0, 32'h0, 16'd0, 16'd1, 32'h0, 128'h0);
    cmd(3'd4, 8'd0, 32'h0, 16'd0, 16'd1, 32'h8, 128'h0);
    want("reset-slot", 1'b0, 5'd2, 32'd0, 32'd0, 32'd0, 32'd0);

    // Range copy, stride padding, host not-ready, and the refusals
    // the single-slot cases above do not reach.
    cmd(3'd0, 8'd0, 32'h0, 16'd0, 16'd8, 32'h0, 128'h0);
    cmd(3'd2, 8'd0, 32'h0, 16'd0, 16'd0, 32'h0,
        bus(32'd0, 32'd3, 32'd0, 32'd0));
    cmd(3'd3, 8'd0, 32'h0, 16'd0, 16'd0, 32'h0,
        bus(32'd0, 32'd10, 32'd0, 32'd0));
    stride = 64'd16;
    cmd(3'd4, 8'd0, 32'h0, 16'd0, 16'd2, 32'h1, 128'h0);
    checks++;
    if (saw_err || saw_nrdy || dst[0] != 32'd7 || dst[1] != 32'd0 ||
        dst[2] != 32'd0 || dst[3] != 32'd0 || dst[4] != 32'd0 ||
        dst[5] != 32'd0) begin
      fails++;
      $display("FAIL stride dst=%08x %08x %08x %08x %08x %08x err=%0d nrdy=%0d",
               dst[0], dst[1], dst[2], dst[3], dst[4], dst[5],
               saw_err, saw_nrdy);
    end
    extent = 32'd8;
    cmd(3'd4, 8'd0, 32'h0, 16'd0, 16'd2, 32'h1, 128'h0);
    checks++;
    if (!saw_err || dst[0] != 32'd7 || dst[4] != 32'd0) begin
      fails++;
      $display("FAIL extent-refuse err=%0d dst0=%08x", saw_err, dst[0]);
    end
    extent = 32'h1000;
    count = 0;
    cmd(3'd4, 8'd0, 32'h0, 16'd0, 16'd0, 32'h1, 128'h0);
    checks++;
    if (saw_err || nw != 5'd0 || dst[0] != 32'd7) begin
      fails++;
      $display("FAIL empty-copy err=%0d nw=%0d dst0=%08x", saw_err, nw, dst[0]);
    end
    dst_off = 32'd1;
    cmd(3'd4, 8'd0, 32'h0, 16'd0, 16'd1, 32'h1, 128'h0);
    checks++;
    if (!saw_err || dst[0] != 32'd7) begin
      fails++;
      $display("FAIL align err=%0d", saw_err);
    end
    dst_off = 0;
    cmd(3'd4, 8'd0, 32'h0, 16'd1, 16'd1, 32'h1, 128'h0);
    checks++;
    if (saw_err || saw_nrdy || dst[0] != 32'd0 || dst[1] != 32'd0) begin
      fails++;
      $display("FAIL unavail-copy dst=%08x %08x err=%0d nrdy=%0d",
               dst[0], dst[1], saw_err, saw_nrdy);
    end
    cmd(3'd5, 8'd0, 32'h0, 16'd0, 16'd2, 32'h1, 128'h0);
    checks++;
    if (saw_err || !saw_nrdy || dst[0] != 32'd7 || dst[4] != 32'd0) begin
      fails++;
      $display("FAIL host-nrdy err=%0d nrdy=%0d dst0=%08x dst4=%08x",
               saw_err, saw_nrdy, dst[0], dst[4]);
    end
    cmd(3'd5, 8'd0, 32'h0, 16'd0, 16'd2, 32'h3, 128'h0);
    checks++;
    if (saw_err || !saw_nrdy || dst[0] != 32'd7) begin
      fails++;
      $display("FAIL host-wait err=%0d nrdy=%0d", saw_err, saw_nrdy);
    end
    cmd(3'd5, 8'd0, 32'h0, 16'd0, 16'd1, 32'h0, 128'h0);
    checks++;
    if (!saw_err || dst[0] != 32'd7) begin
      fails++;
      $display("FAIL host-32 err=%0d", saw_err);
    end
    cmd(3'd4, 8'd0, 32'h0, 16'd0, 16'd1, 32'h2, 128'h0);
    checks++;
    if (!saw_err) begin
      fails++;
      $display("FAIL copy-wait");
    end
    cmd(3'd4, 8'd0, 32'h0, 16'd0, 16'd1, 32'h10, 128'h0);
    checks++;
    if (!saw_err) begin
      fails++;
      $display("FAIL copy-partial");
    end
    cmd(3'd2, 8'd1, 32'h97, 16'd6, 16'd0, 32'h0, 128'h0);
    checks++;
    if (!saw_err) begin
      fails++;
      $display("FAIL mask-outside");
    end
    cmd(3'd2, 8'd0, 32'h1, 16'd6, 16'd0, 32'h0, 128'h0);
    checks++;
    if (!saw_err) begin
      fails++;
      $display("FAIL mask-on-occ");
    end
    sub = 32'd1;
    cmd(3'd2, 8'd0, 32'h0, 16'd6, 16'd0, 32'h0, 128'h0);
    checks++;
    if (!saw_err) begin
      fails++;
      $display("FAIL indexed");
    end
    sub = 0;
    cmd(3'd2, 8'd0, 32'h0, 16'd6, 16'd0, 32'h0,
        bus(32'd0, 32'd1, 32'd0, 32'd0));
    cmd(3'd6, 8'd0, 32'h0, 16'd0, 16'd0, 32'h0, 128'h0);
    checks++;
    if (!saw_err) begin
      fails++;
      $display("FAIL submit-open");
    end
    cmd(3'd4, 8'd0, 32'h0, 16'd6, 16'd1, 32'h0, 128'h0);
    checks++;
    if (saw_err || rec[0] != 32'd0) begin
      fails++;
      $display("FAIL submit-published rec=%08x err=%0d", rec[0], saw_err);
    end
    cmd(3'd0, 8'd0, 32'h0, 16'd0, 16'd0, 32'h0, 128'h0);
    cmd(3'd4, 8'd0, 32'h0, 16'd0, 16'd1, 32'h0, 128'h0);
    checks++;
    if (saw_err || rec[0] != 32'd7) begin
      fails++;
      $display("FAIL empty-reset rec=%08x", rec[0]);
    end

    // Plant a zero image, then refuse footprints whose 32-bit sum wraps.
    stride = 64'h0;
    dst_off = 32'h0;
    extent = 32'h1000;
    cmd(3'd4, 8'd0, 32'h0, 16'd1, 16'd1, 32'h1, 128'h0);
    checks++;
    if (saw_err || dst[0] != 32'd0 || dst[1] != 32'd0) begin
      fails++;
      $display("FAIL sentinel dst=%08x %08x err=%0d", dst[0], dst[1], saw_err);
    end
    stride = 64'hFFFFFFF4;
    dst_off = 32'd16;
    extent = 32'd64;
    cmd(3'd4, 8'd0, 32'h0, 16'd0, 16'd2, 32'h0, 128'h0);
    checks++;
    if (!saw_err || dst[0] != 32'd0 || dst[1] != 32'd0 || dst[4] != 32'd0) begin
      fails++;
      $display("FAIL span-wrap32 err=%0d dst=%08x %08x %08x",
               saw_err, dst[0], dst[1], dst[4]);
    end
    stride = 64'hFFFFFFF8;
    dst_off = 32'h0;
    extent = 32'h1000;
    cmd(3'd4, 8'd0, 32'h0, 16'd0, 16'd2, 32'h1, 128'h0);
    checks++;
    if (!saw_err || dst[0] != 32'd0 || dst[1] != 32'd0) begin
      fails++;
      $display("FAIL span-wrap64 err=%0d dst=%08x %08x",
               saw_err, dst[0], dst[1]);
    end
    // Both refusals must leave the published occlusion slot readable.
    stride = 64'h0;
    dst_off = 32'h0;
    extent = 32'h1000;
    cmd(3'd4, 8'd0, 32'h0, 16'd0, 16'd1, 32'h0, 128'h0);
    checks++;
    if (saw_err || rec[0] != 32'd7 || dst[0] != 32'd7) begin
      fails++;
      $display("FAIL wrap-kept rec=%08x dst=%08x err=%0d",
               rec[0], dst[0], saw_err);
    end

    // Statistics mask 0 is legal and still publishes availability.
    stride = 64'h0;
    dst_off = 32'h0;
    extent = 32'h1000;
    cmd(3'd2, 8'd1, 32'h0, 16'd5, 16'd0, 32'h0, 128'h0);
    cmd(3'd3, 8'd1, 32'h0, 16'd5, 16'd0, 32'h0, 128'h0);
    cmd(3'd4, 8'd1, 32'h0, 16'd5, 16'd1, 32'h8, 128'h0);
    checks++;
    if (saw_err || saw_nrdy || nw != 5'd1 || rec[0] != 32'd1 ||
        dst[0] != 32'd1) begin
      fails++;
      $display("FAIL stats0-av err=%0d nrdy=%0d nw=%0d rec=%08x dst=%08x",
               saw_err, saw_nrdy, nw, rec[0], dst[0]);
    end
    cmd(3'd5, 8'd1, 32'h0, 16'd5, 16'd1, 32'h9, 128'h0);
    checks++;
    if (saw_err || saw_nrdy || nw != 5'd2 || rec[0] != 32'd1 ||
        rec[1] != 32'd0 || dst[0] != 32'd1 || dst[1] != 32'd0) begin
      fails++;
      $display("FAIL stats0-host err=%0d nrdy=%0d nw=%0d rec=%08x %08x dst=%08x %08x",
               saw_err, saw_nrdy, nw, rec[0], rec[1], dst[0], dst[1]);
    end

    if (fails == 0)
      $display("PASS tb_g6lc_apu_qrypool checks=%0d", checks);
    else
      $display("FAIL tb_g6lc_apu_qrypool checks=%0d fails=%0d",
               checks, fails);
    $finish;
  end
endmodule
