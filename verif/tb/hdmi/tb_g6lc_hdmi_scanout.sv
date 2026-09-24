// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Pixel-order contract for g6lc_hdmi_scanout. HdmiEn=0 stays quiet.
// HdmiEn=1 scans a packed r5g6b5 buffer in line order. A second pattern
// must change the active pixels. Not a board PHY and not 3D.

`timescale 1ns/1ps

module tb_g6lc_hdmi_scanout;
  localparam int unsigned HAct = 640;
  localparam int unsigned VAct = 480;
  localparam int unsigned NPix = HAct * VAct;
  localparam int unsigned HTotal = 800;
  localparam int unsigned VTotal = 525;

  logic clk = 0, rst_ni = 0;
  always #5 clk = ~clk;

  logic        off_re, on_re;
  logic [31:0] off_addr, on_addr;
  logic [15:0] rdata;
  logic        off_hs, off_vs, off_de, on_hs, on_vs, on_de;
  logic [7:0]  off_r, off_g, off_b, on_r, on_g, on_b;
  logic [15:0] mem [0:NPix-1];
  logic [15:0] held;
  int errors = 0, checks = 0, de_count = 0, hs_count = 0, seen = 0;
  int x, y;
  logic pattern;

  function automatic logic [15:0] pix(input int px, input int py, input logic inv);
    logic [15:0] p;
    p = {py[4:0], px[5:0], py[4:0]};
    return inv ? ~p : p;
  endfunction
  function automatic logic [7:0] exp5(input logic [4:0] c);
    return {c, c[4:2]};
  endfunction
  function automatic logic [7:0] exp6(input logic [5:0] c);
    return {c, c[5:4]};
  endfunction

  g6lc_hdmi_scanout #(.HdmiEn(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .run_i(1'b1),
    .fb_re_o(off_re), .fb_addr_o(off_addr), .fb_x_o(), .fb_y_o(),
    .fb_rdata_i(16'hffff),
    .hs_o(off_hs), .vs_o(off_vs), .de_o(off_de),
    .r_o(off_r), .g_o(off_g), .b_o(off_b)
  );
  g6lc_hdmi_scanout #(.HdmiEn(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .run_i(1'b1),
    .fb_re_o(on_re), .fb_addr_o(on_addr), .fb_x_o(), .fb_y_o(),
    .fb_rdata_i(rdata),
    .hs_o(on_hs), .vs_o(on_vs), .de_o(on_de),
    .r_o(on_r), .g_o(on_g), .b_o(on_b)
  );

  always_ff @(posedge clk) begin
    if (on_re && on_addr[0] == 1'b0 && on_addr[31:1] < NPix)
      held <= mem[on_addr[31:1]];
  end
  assign rdata = held;

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s", name);
    end
  endtask

  task automatic load(input logic inv);
    int i, px, py;
    for (py = 0; py < VAct; py++)
      for (px = 0; px < HAct; px++)
        mem[py * HAct + px] = pix(px, py, inv);
  endtask

  task automatic frame(input logic inv);
    int guard;
    logic [15:0] expix;
    rst_ni = 1'b0;
    repeat (2) @(posedge clk);
    rst_ni = 1'b1;
    de_count = 0;
    hs_count = 0;
    seen = 0;
    x = 0;
    y = 0;
    for (guard = 0; guard < (HTotal * VTotal); guard++) begin
      @(posedge clk);
      #1;
      if (on_de) begin
        de_count++;
        expix = pix(x, y, inv);
        if (on_r !== exp5(expix[15:11]) ||
            on_g !== exp6(expix[10:5]) ||
            on_b !== exp5(expix[4:0])) begin
          if (seen < 4) begin
            errors++;
            $display("FAIL pixel x=%0d y=%0d r=%02x g=%02x b=%02x",
                     x, y, on_r, on_g, on_b);
          end
          seen++;
        end
        if (x == HAct - 1) begin
          x = 0;
          y++;
        end else
          x++;
      end
      if (on_hs)
        hs_count++;
    end
    checks++;
    if (de_count != NPix) begin
      errors++;
      $display("FAIL de_count=%0d", de_count);
    end
    checks++;
    if (hs_count != 96 * VTotal) begin
      errors++;
      $display("FAIL hs_count=%0d", hs_count);
    end
    checks++;
    if (seen != 0) begin
      errors++;
      $display("FAIL mismatches=%0d", seen);
    end
  endtask

  initial begin
    load(1'b0);
    pattern = 0;
    repeat (8) @(posedge clk);
    rst_ni = 1'b1;
    repeat (20) @(posedge clk);
    check("hdmi off stays quiet",
          off_re === 0 && off_de === 0 && off_hs === 0 && off_vs === 0 &&
          off_r === 0 && off_g === 0 && off_b === 0);
    frame(1'b0);
    check("first and last pixel addresses differ",
          mem[0] != mem[NPix-1]);
    load(1'b1);
    rst_ni = 1'b0;
    repeat (4) @(posedge clk);
    rst_ni = 1'b1;
    frame(1'b1);
    if (errors != 0)
      $fatal(1, "hdmi scanout errors=%0d checks=%0d", errors, checks);
    $display("PASS tb_g6lc_hdmi_scanout checks=%0d pixels=%0d errors=0",
             checks, NPix);
    $finish;
  end
endmodule
