// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Unit bench for g6lc_apu_qrydelta.  Does not elaborate the raster,
// the shader wave, or the executor.
`timescale 1ns/1ps
module tb_g6lc_apu_qrydelta;
  logic [7:0]        qtype;
  logic [31:0]       mask, flags;
  logic              slot_avail;
  logic [127:0]      now, base;
  logic [3:0]        n;
  logic [3:0][31:0]  delta;
  logic [4:0]        nw;
  logic [9:0][31:0]  rec;
  int checks = 0, fails = 0;

  g6lc_apu_qrydelta dut (
    .qtype_i(qtype), .mask_i(mask), .now_i(now), .base_i(base),
    .slot_avail_i(slot_avail), .flags_i(flags),
    .use_stored_i(1'b0), .stored_n_i(4'd0), .stored_i('{default: '0}),
    .n_o(n), .delta_o(delta), .nw_o(nw), .rec_o(rec));

  function automatic logic [127:0] bus(
      input logic [31:0] fs, input logic [31:0] occ,
      input logic [31:0] prim, input logic [31:0] vtx);
    bus = {fs, occ, prim, vtx};
  endfunction

  task automatic check(input string name, input logic [3:0] en,
                        input logic [31:0] e0, input logic [31:0] e1,
                        input logic [31:0] e2, input logic [31:0] e3);
    checks++;
    if (n != en || delta[0] != e0 || delta[1] != e1 ||
        delta[2] != e2 || delta[3] != e3) begin
      fails++;
      $display("FAIL %s n=%0d d=%08x %08x %08x %08x",
               name, n, delta[0], delta[1], delta[2], delta[3]);
    end
  endtask

  task automatic check_rec(input string name, input logic [4:0] enw,
                           input logic [31:0] w0, input logic [31:0] w1,
                           input logic [31:0] w2, input logic [31:0] w3);
    checks++;
    if (nw != enw || rec[0] != w0 || rec[1] != w1 ||
        rec[2] != w2 || rec[3] != w3) begin
      fails++;
      $display("FAIL %s nw=%0d rec=%08x %08x %08x %08x",
               name, nw, rec[0], rec[1], rec[2], rec[3]);
    end
  endtask

  initial begin
    // Assignments before the first delay are not seen by always_comb.
    // Apply the occlusion stimulus after that slot.
    slot_avail = 1'b0;
    flags = 32'h0;
    qtype = 8'd9;
    mask = 32'h0;
    base = '0;
    now = '0;
    #1;
    slot_avail = 1'b1;
    qtype = 8'd0;
    base = bus(32'd1, 32'd3, 32'd4, 32'd5);
    now  = bus(32'd9, 32'd10, 32'd8, 32'd7);
    #1 check("occ", 4'd1, 32'd7, 32'd0, 32'd0, 32'd0);

    qtype = 8'd1; mask = 32'h87;
    #1 check("stats87", 4'd4, 32'd2, 32'd4, 32'd2, 32'd8);

    mask = 32'h80;
    #1 check("fs-only", 4'd1, 32'd8, 32'd0, 32'd0, 32'd0);

    mask = 32'h05;
    #1 check("vtx-and-vs", 4'd2, 32'd2, 32'd2, 32'd0, 32'd0);

    mask = 32'h78;
    #1 check("refused-bits", 4'd0, 32'd0, 32'd0, 32'd0, 32'd0);

    qtype = 8'd2; mask = 32'h87;
    now = bus(32'hffff_ffff, 32'hffff_ffff, 32'hffff_ffff, 32'hffff_ffff);
    #1 check("timestamp", 4'd1, 32'd0, 32'd0, 32'd0, 32'd0);

    qtype = 8'd1; mask = 32'h01;
    base = bus(32'd0, 32'd0, 32'd0, 32'hffff_fffe);
    now  = bus(32'd0, 32'd0, 32'd0, 32'd1);
    #1 check("wrap", 4'd1, 32'd3, 32'd0, 32'd0, 32'd0);

    qtype = 8'd9;
    #1 check("unknown", 4'd0, 32'd0, 32'd0, 32'd0, 32'd0);
    #1 check_rec("unknown-rec", 5'd0, 32'd0, 32'd0, 32'd0, 32'd0);

    // Restore the occlusion window and pack copy records.
    qtype = 8'd0; mask = 32'h0; flags = 32'h0; slot_avail = 1'b1;
    base = bus(32'd1, 32'd3, 32'd4, 32'd5);
    now  = bus(32'd9, 32'd10, 32'd8, 32'd7);
    #1 check_rec("occ32", 5'd1, 32'd7, 32'd0, 32'd0, 32'd0);

    flags = 32'h9; // 64-bit plus availability
    #1 check_rec("occ64-av", 5'd4, 32'd7, 32'd0, 32'd1, 32'd0);

    slot_avail = 1'b0;
    flags = 32'h8;
    #1 check_rec("occ-unavail", 5'd2, 32'd0, 32'd0, 32'd0, 32'd0);

    qtype = 8'd1; mask = 32'h87; flags = 32'h0; slot_avail = 1'b1;
    #1 check_rec("stats32", 5'd4, 32'd2, 32'd4, 32'd2, 32'd8);

    qtype = 8'd2; mask = 32'h0; flags = 32'h9; slot_avail = 1'b1;
    now = bus(32'hffff_ffff, 32'hffff_ffff, 32'hffff_ffff, 32'hffff_ffff);
    #1 check_rec("ts64-av", 5'd4, 32'd0, 32'd0, 32'd1, 32'd0);

    // A statistics mask of 0 has no counters. Availability is still one word.
    qtype = 8'd1; mask = 32'h0; flags = 32'h8; slot_avail = 1'b1;
    #1 check_rec("stats0-av", 5'd1, 32'd1, 32'd0, 32'd0, 32'd0);

    if (fails == 0)
      $display("PASS tb_g6lc_apu_qrydelta checks=%0d", checks);
    else
      $display("FAIL tb_g6lc_apu_qrydelta checks=%0d fails=%0d",
               checks, fails);
    $finish;
  end
endmodule
