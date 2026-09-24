// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_cover;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  logic clk = 0, rst_ni = 0, req_v = 0, req_rdy, frag_v, frag_r = 0;
  logic off_rdy, off_v;
  apu_cover_req_t req;
  apu_cover_frag_t frag, off_frag, snap;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  localparam logic [31:0] Sentinel = 32'hA5A5_00C0;

  g6lc_apu_cover #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .req_valid_i(req_v), .req_ready_o(req_rdy), .req_i(req),
    .frag_valid_o(frag_v), .frag_ready_i(frag_r), .frag_o(frag)
  );
  g6lc_apu_cover_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .req_valid_i(req_v), .req_ready_o(off_rdy), .req_i(req),
    .frag_valid_o(off_v), .frag_ready_i(frag_r), .frag_o(off_frag)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "cover timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_frag !== '0)
      $fatal(1, "disabled cover active");
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask

  task automatic ask(
    input logic signed [15:0] x0, y0, x1, y1, x2, y2, px, py,
    input logic [31:0] color,
    input logic covered,
    input logic signed [47:0] w0, w1, w2, area,
    input string name
  );
    @(negedge clk);
    while (!req_rdy) @(negedge clk);
    cases++;
    req = '0;
    req.v0.x = x0; req.v0.y = y0;
    req.v1.x = x1; req.v1.y = y1;
    req.v2.x = x2; req.v2.y = y2;
    req.sample.x = px; req.sample.y = py;
    req.color = color;
    req_v = 1;
    @(posedge clk); @(negedge clk); req_v = 0;
    while (!frag_v) @(negedge clk);
    snap = frag;
    check($sformatf("%s covered", name), frag.covered == covered);
    check($sformatf("%s w0", name), frag.w0 == w0);
    check($sformatf("%s w1", name), frag.w1 == w1);
    check($sformatf("%s w2", name), frag.w2 == w2);
    check($sformatf("%s area", name), frag.area == area);
    check($sformatf("%s color", name), frag.color == color);
    check($sformatf("%s sum", name), frag.w0 + frag.w1 + frag.w2 == frag.area);
    req.sample.x = px + 16'sd3;
    req_v = 1;
    @(posedge clk);
    check({name, " latched"}, frag_v && !req_rdy && frag == snap);
    @(negedge clk); req_v = 0;
    frag_r = 1;
    @(posedge clk); @(negedge clk); frag_r = 0;
    while (frag_v) @(negedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    logic covered_in, covered_out;
    logic [31:0] color_in, color_out;
    req = '0;
    @(negedge clk); rst_ni = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && req_rdy == 1'b1);
    check("profiles keep cover off", !ApuOff.CoverEn && !ApuHarness.CoverEn &&
          !ApuP1Transport.CoverEn);
    cfg = ApuP1Transport;
    cfg.CoverEn = 1'b1;
    check("cover does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.CoverEn = 1'b1;
    check("cover does not legalize virgl", !apu_cfg_legal(cfg) &&
          !apu_cfg_legal(ApuBadVirglGrant));

    ask(16'sd0, 16'sd0, 16'sd4, 16'sd0, 16'sd0, 16'sd4, 16'sd1, 16'sd1,
        Sentinel, 1'b1, 48'sd8, 48'sd4, 48'sd4, 48'sd16, "inside");
    covered_in = snap.covered;
    color_in = snap.color;
    ask(16'sd0, 16'sd0, 16'sd1, 16'sd0, 16'sd0, 16'sd4, 16'sd1, 16'sd1,
        Sentinel, 1'b0, -48'sd1, 48'sd4, 48'sd1, 48'sd4, "moved");
    covered_out = snap.covered;
    color_out = snap.color;
    check("coverage flips", covered_in == 1'b1 && covered_out == 1'b0);
    check("color unchanged", color_in == color_out && color_in == Sentinel);

    ask(16'sd0, 16'sd0, 16'sd4, 16'sd0, 16'sd0, 16'sd4, 16'sd0, 16'sd2,
        Sentinel, 1'b1, 48'sd8, 48'sd0, 48'sd8, 48'sd16, "left");
    ask(16'sd0, 16'sd0, 16'sd4, 16'sd0, 16'sd0, 16'sd4, 16'sd2, 16'sd0,
        Sentinel, 1'b0, 48'sd8, 48'sd8, 48'sd0, 48'sd16, "bottom");
    ask(16'sd0, 16'sd0, 16'sd4, 16'sd0, 16'sd0, 16'sd4, 16'sd2, 16'sd2,
        Sentinel, 1'b0, 48'sd0, 48'sd8, 48'sd8, 48'sd16, "diagonal");
    ask(16'sd0, 16'sd0, 16'sd0, 16'sd4, 16'sd4, 16'sd0, 16'sd1, 16'sd1,
        Sentinel, 1'b1, -48'sd8, -48'sd4, -48'sd4, -48'sd16, "cw");
    ask(16'sd0, 16'sd0, 16'sd0, 16'sd0, 16'sd0, 16'sd4, 16'sd1, 16'sd1,
        Sentinel, 1'b0, -48'sd4, 48'sd4, 48'sd0, 48'sd0, "degenerate");
    ask(-16'sd2, -16'sd2, 16'sd2, -16'sd2, -16'sd2, 16'sd2, -16'sd1, -16'sd1,
        Sentinel, 1'b1, 48'sd8, 48'sd4, 48'sd4, 48'sd16, "negative");
    ask(16'sd0, 16'sd0, 16'sd30000, 16'sd0, 16'sd0, 16'sd30000, 16'sd1, 16'sd1,
        Sentinel, 1'b1, 48'sd899940000, 48'sd30000, 48'sd30000, 48'sd900000000,
        "wide");

    if (errors != 0) $fatal(1, "APU cover errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_cover cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
