// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Line-buffer AXI read in front of the 640x480 scanner. HdmiEn=0 is quiet.
// One packed r5g6b5 pattern must survive the burst and come out in order.

`timescale 1ns/1ps

module tb_g6lc_hdmi_linebuf;
  localparam int unsigned HAct = 640;
  localparam int unsigned VAct = 480;
  localparam int unsigned NPix = HAct * VAct;
  localparam int unsigned HTotal = 800;
  localparam int unsigned VTotal = 525;
  localparam logic [31:0] Base = 32'h0000_1000;

  logic clk = 0, rst_ni = 0;
  always #5 clk = ~clk;

  logic        run, fb_re, ar_valid, ar_ready, r_valid, r_ready, r_last;
  logic [31:0] fb_addr, ar_addr;
  logic [15:0] fb_x, fb_y, fb_data;
  logic [7:0]  ar_len;
  logic [2:0]  ar_size;
  logic [1:0]  ar_burst;
  logic [63:0] r_data;
  logic        hs, vs, de, off_ar, saw_burst;
  logic [7:0]  r, g, b;
  logic [15:0] mem [0:NPix-1];

  logic        busy_q;
  logic [31:0] cur_q;
  logic [8:0]  left_q;
  logic        rv_q;
  logic [63:0] rd_q;
  logic        rl_q;

  int errors = 0, checks = 0, de_count = 0, seen = 0, x, y;

  function automatic logic [15:0] pix(input int px, input int py);
    return {py[4:0], px[5:0], py[4:0]};
  endfunction
  function automatic logic [7:0] exp5(input logic [4:0] c);
    return {c, c[4:2]};
  endfunction
  function automatic logic [7:0] exp6(input logic [5:0] c);
    return {c, c[5:4]};
  endfunction

  g6lc_hdmi_scanout #(.HdmiEn(1'b1)) i_scan (
    .clk_i(clk), .rst_ni, .run_i(run),
    .fb_re_o(fb_re), .fb_addr_o(fb_addr), .fb_x_o(fb_x), .fb_y_o(fb_y),
    .fb_rdata_i(fb_data),
    .hs_o(hs), .vs_o(vs), .de_o(de),
    .r_o(r), .g_o(g), .b_o(b)
  );
  g6lc_hdmi_linebuf #(.HdmiEn(1'b1)) i_lb (
    .clk_i(clk), .rst_ni, .base_i(Base), .run_o(run),
    .fb_re_i(fb_re), .fb_x_i(fb_x), .fb_y_i(fb_y), .fb_rdata_o(fb_data),
    .ar_valid_o(ar_valid), .ar_ready_i(ar_ready), .ar_addr_o(ar_addr),
    .ar_len_o(ar_len), .ar_size_o(ar_size), .ar_burst_o(ar_burst),
    .r_valid_i(rv_q), .r_ready_o(r_ready), .r_data_i(rd_q), .r_last_i(rl_q)
  );
  g6lc_hdmi_linebuf #(.HdmiEn(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .base_i(Base), .run_o(),
    .fb_re_i(1'b0), .fb_x_i('0), .fb_y_i('0), .fb_rdata_o(),
    .ar_valid_o(off_ar), .ar_ready_i(1'b1), .ar_addr_o(),
    .ar_len_o(), .ar_size_o(), .ar_burst_o(),
    .r_valid_i(1'b0), .r_ready_o(), .r_data_i('0), .r_last_i(1'b0)
  );
  assign ar_ready = !busy_q;
  assign r_valid  = rv_q;
  assign r_data   = rd_q;
  assign r_last   = rl_q;

  function automatic logic [63:0] beat_at(input int byte_addr);
    int pix_i;
    pix_i = (byte_addr - int'(Base)) >> 1;
    return {mem[pix_i + 3], mem[pix_i + 2], mem[pix_i + 1], mem[pix_i]};
  endfunction

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      busy_q <= 1'b0;
      cur_q  <= '0;
      left_q <= '0;
      rv_q   <= 1'b0;
      rd_q   <= '0;
      rl_q   <= 1'b0;
    end else begin
      if (!busy_q && ar_valid && ar_ready) begin
        busy_q <= 1'b1;
        cur_q  <= ar_addr;
        left_q <= {1'b0, ar_len} + 9'd1;
      end
      if (busy_q && (!rv_q || r_ready)) begin
        rv_q <= 1'b1;
        rd_q <= beat_at(int'(cur_q));
        rl_q <= (left_q == 9'd1);
        cur_q <= cur_q + 32'd8;
        if (left_q == 9'd1) begin
          busy_q <= 1'b0;
          left_q <= '0;
        end else
          left_q <= left_q - 9'd1;
      end else if (rv_q && r_ready)
        rv_q <= 1'b0;
    end
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s", name);
    end
  endtask

  initial begin
    int px, py, guard;
    logic [15:0] expix;
    for (py = 0; py < VAct; py++)
      for (px = 0; px < HAct; px++)
        mem[py * HAct + px] = pix(px, py);
    repeat (4) @(posedge clk);
    rst_ni = 1'b1;
    repeat (8) @(posedge clk);
    #1;
    check("linebuf off issues no AR", off_ar === 1'b0);
    saw_burst = 1'b0;
    de_count = 0;
    seen = 0;
    x = 0;
    y = 0;
    for (guard = 0; guard < (HTotal * (VTotal + 2)); guard++) begin
      @(posedge clk);
      #1;
      if (ar_valid && ar_ready && ar_len == 8'd159 && ar_size == 3'd3 &&
          ar_burst == 2'b01)
        saw_burst = 1'b1;
      if (!run)
        continue;
      if (de) begin
        de_count++;
        expix = pix(x, y);
        if (r !== exp5(expix[15:11]) || g !== exp6(expix[10:5]) ||
            b !== exp5(expix[4:0])) begin
          if (seen < 4)
            $display("FAIL pixel x=%0d y=%0d r=%02x g=%02x b=%02x", x, y, r, g, b);
          seen++;
        end
        if (x == HAct - 1) begin
          x = 0;
          y++;
        end else
          x++;
      end
      if (de_count == NPix)
        break;
    end
    checks++;
    if (de_count != NPix) begin
      errors++;
      $display("FAIL de_count=%0d", de_count);
    end
    checks++;
    if (seen != 0) begin
      errors++;
      $display("FAIL mismatches=%0d", seen);
    end
    check("burst is one line", saw_burst === 1'b1);
    if (errors != 0)
      $fatal(1, "hdmi linebuf errors=%0d checks=%0d", errors, checks);
    $display("PASS tb_g6lc_hdmi_linebuf checks=%0d pixels=%0d errors=0",
             checks, NPix);
    $finish;
  end
endmodule
