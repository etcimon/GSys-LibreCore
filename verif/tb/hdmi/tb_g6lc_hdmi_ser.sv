// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// The 10× shift of the TMDS words. Bit 0 leaves first. The words come from
// the framebuffer through the line buffer and the symbol encoder. HdmiEn=0
// stays at zero. Not a differential PHY.

`timescale 1ns/1ps

module tb_g6lc_hdmi_ser;
  localparam int unsigned HAct = 640;
  localparam int unsigned VAct = 480;
  localparam int unsigned NPix = HAct * VAct;
  localparam int unsigned HTotal = 800;
  localparam int unsigned VTotal = 525;
  localparam logic [31:0] Base = 32'h0000_1000;

  logic clk_bit = 0, clk_pix = 0, rst_ni = 0;
  always #5 clk_bit = ~clk_bit;
  initial begin
    clk_pix = 1'b0;
    #6;
    forever #50 clk_pix = ~clk_pix;
  end

  logic        run, fb_re, ar_valid, ar_ready, r_ready, de, hs, vs;
  logic [31:0] fb_addr, ar_addr;
  logic [15:0] fb_x, fb_y, fb_data;
  logic [7:0]  ar_len, r, g, b;
  logic [2:0]  ar_size;
  logic [1:0]  ar_burst;
  logic [9:0]  tr, tg, tb;
  logic        sr, sg, sb, zr, zg, zb;
  logic        pix_d, load;
  logic [15:0] mem [0:NPix-1];

  logic        busy_q, rv_q, rl_q;
  logic [31:0] cur_q;
  logic [8:0]  left_q;
  logic [63:0] rd_q;
  int de_count = 0;

  int errors = 0, checks = 0;
  int bad = 0, early = 0, gap = 0, words = 0, saw = 0, off_bad = 0;

  g6lc_hdmi_scanout #(.HdmiEn(1'b1)) i_scan (
    .clk_i(clk_pix), .rst_ni, .run_i(run),
    .fb_re_o(fb_re), .fb_addr_o(fb_addr), .fb_x_o(fb_x), .fb_y_o(fb_y),
    .fb_rdata_i(fb_data),
    .hs_o(hs), .vs_o(vs), .de_o(de),
    .r_o(r), .g_o(g), .b_o(b)
  );
  g6lc_hdmi_linebuf #(.HdmiEn(1'b1)) i_lb (
    .clk_i(clk_pix), .rst_ni, .base_i(Base), .run_o(run),
    .fb_re_i(fb_re), .fb_x_i(fb_x), .fb_y_i(fb_y), .fb_rdata_o(fb_data),
    .ar_valid_o(ar_valid), .ar_ready_i(ar_ready), .ar_addr_o(ar_addr),
    .ar_len_o(ar_len), .ar_size_o(ar_size), .ar_burst_o(ar_burst),
    .r_valid_i(rv_q), .r_ready_o(r_ready), .r_data_i(rd_q), .r_last_i(rl_q)
  );
  g6lc_hdmi_tmds #(.HdmiEn(1'b1)) i_tmds (
    .clk_i(clk_pix), .rst_ni,
    .de_i(de), .hs_i(hs), .vs_i(vs),
    .r_i(r), .g_i(g), .b_i(b),
    .r_o(tr), .g_o(tg), .b_o(tb)
  );
  g6lc_hdmi_ser #(.HdmiEn(1'b1)) i_ser (
    .clk_i(clk_bit), .rst_ni, .load_i(load),
    .r_i(tr), .g_i(tg), .b_i(tb),
    .r_o(sr), .g_o(sg), .b_o(sb)
  );
  g6lc_hdmi_ser #(.HdmiEn(1'b0)) i_off (
    .clk_i(clk_bit), .rst_ni, .load_i(load),
    .r_i(tr), .g_i(tg), .b_i(tb),
    .r_o(zr), .g_o(zg), .b_o(zb)
  );
  assign ar_ready = !busy_q;

  // Load is the bit-clock cycle that sees a rising pixel clock.
  // The detector keeps running through reset so the first pulse is real.
  always_ff @(posedge clk_bit) begin
    pix_d <= clk_pix;
    load  <= clk_pix & ~pix_d;
  end

  always_ff @(posedge clk_pix or negedge rst_ni) begin
    if (!rst_ni) de_count <= 0;
    else if (de) de_count <= de_count + 1;
  end

  function automatic logic [63:0] beat_at(input int byte_addr);
    int pix_i;
    pix_i = (byte_addr - int'(Base)) >> 1;
    return {mem[pix_i + 3], mem[pix_i + 2], mem[pix_i + 1], mem[pix_i]};
  endfunction

  always_ff @(posedge clk_pix or negedge rst_ni) begin
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

  task automatic take(input logic [9:0] exp_r, input logic [9:0] exp_g,
                      input logic [9:0] exp_b, input logic [9:0] got_r,
                      input logic [9:0] got_g, input logic [9:0] got_b);
    if (got_r !== exp_r || got_g !== exp_g || got_b !== exp_b) begin
      if (bad < 4)
        $display("FAIL word exp %03x %03x %03x got %03x %03x %03x",
                 exp_r, exp_g, exp_b, got_r, got_g, got_b);
      bad++;
    end
    words++;
    if (exp_r == 10'h100 && exp_g == 10'h100 && exp_b == 10'h100)
      saw++;
  endtask

  initial begin
    int px, py, guard, extra, bit_n;
    logic armed, cap_load;
    logic [9:0] cap_r, cap_g, cap_b;
    logic [9:0] exp_r, exp_g, exp_b;
    logic [9:0] got_r, got_g, got_b;
    for (py = 0; py < VAct; py++)
      for (px = 0; px < HAct; px++)
        mem[py * HAct + px] = {py[4:0], px[5:0], py[4:0]};
    repeat (80) @(posedge clk_bit);
    rst_ni = 1'b1;
    armed = 1'b0;
    bit_n = 0;
    extra = 0;
    got_r = '0;
    got_g = '0;
    got_b = '0;
    for (guard = 0; guard < (10 * HTotal * (VTotal + 4)); guard++) begin
      cap_load = load;
      cap_r = tr;
      cap_g = tg;
      cap_b = tb;
      @(posedge clk_bit);
      #1;
      if (zr !== 1'b0 || zg !== 1'b0 || zb !== 1'b0)
        off_bad++;
      if (cap_load) begin
        if (armed) begin
          if (bit_n != 10) early++;
          else take(exp_r, exp_g, exp_b, got_r, got_g, got_b);
        end
        exp_r = cap_r;
        exp_g = cap_g;
        exp_b = cap_b;
        armed = 1'b1;
        bit_n = 1;
        got_r = {9'b0, sr};
        got_g = {9'b0, sg};
        got_b = {9'b0, sb};
      end else if (armed && bit_n == 10) begin
        gap++;
      end else if (armed) begin
        got_r[bit_n] = sr;
        got_g[bit_n] = sg;
        got_b[bit_n] = sb;
        bit_n++;
      end
      if (de_count >= NPix)
        extra++;
      if (de_count >= NPix && extra > 400 && !cap_load && bit_n == 10)
        break;
    end
    if (armed && bit_n == 10)
      take(exp_r, exp_g, exp_b, got_r, got_g, got_b);
    check("serializer off stays 0", off_bad == 0);
    check("frame reached the scanner", de_count == NPix);
    check("serial words match", bad == 0 && early == 0 && gap == 0);
    check("bit 0 of the first pixel went first", saw >= 1 && words >= NPix);
    if (errors != 0)
      $fatal(1, "hdmi ser errors=%0d checks=%0d bad=%0d early=%0d gap=%0d words=%0d",
             errors, checks, bad, early, gap, words);
    $display("PASS tb_g6lc_hdmi_ser checks=%0d pixels=%0d words=%0d errors=0",
             checks, NPix, words);
    $finish;
  end
endmodule
