// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Packed r5g6b5 in a DRAM model must leave the TMDS symbol stream in order:
// video preamble, video guard, then pixels that decode to that line.
// HdmiEn=0 stays at zero. Not a serializer and not a board PHY.

`timescale 1ns/1ps

module tb_g6lc_hdmi_tmds;
  localparam int unsigned HAct = 640;
  localparam int unsigned VAct = 480;
  localparam int unsigned NPix = HAct * VAct;
  localparam int unsigned HTotal = 800;
  localparam int unsigned VTotal = 525;
  localparam logic [31:0] Base = 32'h0000_1000;
  localparam logic [9:0] CTRL00 = 10'b1101010100;
  localparam logic [9:0] CTRL01 = 10'b0010101011;
  localparam logic [9:0] CTRL10 = 10'b0101010100;
  localparam logic [9:0] CTRL11 = 10'b1010101011;
  localparam logic [9:0] GUARD_RB = 10'b1011001100;
  localparam logic [9:0] GUARD_G  = 10'b0100110011;

  logic clk = 0, rst_ni = 0;
  always #5 clk = ~clk;

  logic        run, fb_re, ar_valid, ar_ready, r_ready;
  logic [31:0] fb_addr, ar_addr;
  logic [15:0] fb_x, fb_y, fb_data;
  logic [7:0]  ar_len;
  logic [2:0]  ar_size;
  logic [1:0]  ar_burst;
  logic        hs, vs, de;
  logic [7:0]  r, g, b;
  logic [9:0]  tr, tg, tb, or_, og, ob;
  logic [15:0] mem [0:NPix-1];

  logic        busy_q, rv_q, rl_q;
  logic [31:0] cur_q;
  logic [8:0]  left_q;
  logic [63:0] rd_q;

  logic [10:0] de_s, hs_s, vs_s;
  logic [7:0]  r_s [0:10];
  logic [7:0]  g_s [0:10];
  logic [7:0]  b_s [0:10];

  int errors = 0, checks = 0, seen = 0, off_bad = 0;
  int video_n = 0, pre_n = 0, guard_n = 0, hs_n = 0;

  localparam logic [9:0] VEC_R [0:15] = '{
    10'h100, 10'h3ff, 10'h100, 10'h3ff, 10'h100, 10'h3ff, 10'h100, 10'h3ff,
    10'h100, 10'h100, 10'h3ff, 10'h100, 10'h3ff, 10'h100, 10'h3ff, 10'h100
  };
  localparam logic [9:0] VEC_G [0:15] = '{
    10'h100, 10'h1fc, 10'h1f8, 10'h3fb, 10'h1f0, 10'h10c, 10'h108, 10'h1f4,
    10'h31f, 10'h11c, 10'h118, 10'h1e4, 10'h3ef, 10'h313, 10'h1e8, 10'h241
  };
  localparam logic [9:0] VEC_B [0:15] = '{
    10'h100, 10'h3ff, 10'h100, 10'h3ff, 10'h100, 10'h3ff, 10'h100, 10'h3ff,
    10'h100, 10'h100, 10'h3ff, 10'h100, 10'h3ff, 10'h100, 10'h3ff, 10'h100
  };

  function automatic logic [15:0] pix(input int px, input int py);
    return {py[4:0], px[5:0], py[4:0]};
  endfunction
  function automatic logic [7:0] exp5(input logic [4:0] c);
    return {c, c[4:2]};
  endfunction
  function automatic logic [7:0] exp6(input logic [5:0] c);
    return {c, c[5:4]};
  endfunction
  function automatic logic [9:0] ctrl_of(input logic d1, input logic d0);
    case ({d1, d0})
      2'b00: return CTRL00;
      2'b01: return CTRL01;
      2'b10: return CTRL10;
      default: return CTRL11;
    endcase
  endfunction
  function automatic logic [7:0] tmds_dec(input logic [9:0] s);
    logic [7:0] qm, o;
    qm = s[9] ? ~s[7:0] : s[7:0];
    o[0] = qm[0];
    for (int i = 1; i < 8; i++)
      o[i] = s[8] ? (qm[i] ^ qm[i-1]) : ~(qm[i] ^ qm[i-1]);
    return o;
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
  g6lc_hdmi_tmds #(.HdmiEn(1'b1)) i_tmds (
    .clk_i(clk), .rst_ni,
    .de_i(de), .hs_i(hs), .vs_i(vs),
    .r_i(r), .g_i(g), .b_i(b),
    .r_o(tr), .g_o(tg), .b_o(tb)
  );
  g6lc_hdmi_tmds #(.HdmiEn(1'b0)) i_off (
    .clk_i(clk), .rst_ni,
    .de_i(de), .hs_i(hs), .vs_i(vs),
    .r_i(r), .g_i(g), .b_i(b),
    .r_o(or_), .g_o(og), .b_o(ob)
  );
  assign ar_ready = !busy_q;

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

  task automatic note(input string name);
    if (seen < 4) $display("FAIL %s r=%03x g=%03x b=%03x", name, tr, tg, tb);
    seen++;
  endtask

  initial begin
    int px, py, guard;
    logic cap_de, cap_hs, cap_vs;
    logic [7:0] cap_r, cap_g, cap_b;
    logic video, guardb, pre;
    logic [7:0] er, eg, eb;
    for (py = 0; py < VAct; py++)
      for (px = 0; px < HAct; px++)
        mem[py * HAct + px] = pix(px, py);
    for (px = 0; px < 11; px++) begin
      r_s[px] = '0;
      g_s[px] = '0;
      b_s[px] = '0;
    end
    de_s = '0;
    hs_s = '0;
    vs_s = '0;
    repeat (4) @(posedge clk);
    rst_ni = 1'b1;
    for (guard = 0; guard < (HTotal * (VTotal + 2)); guard++) begin
      cap_de = de;
      cap_hs = hs;
      cap_vs = vs;
      cap_r = r;
      cap_g = g;
      cap_b = b;
      video = de_s[9];
      guardb = !de_s[9] && (de_s[7] || de_s[8]);
      pre = !de_s[9] && !de_s[7] && !de_s[8] && (|de_s[6:0] || cap_de);
      @(posedge clk);
      #1;
      if (or_ !== 10'h000 || og !== 10'h000 || ob !== 10'h000)
        off_bad++;
      if (video) begin
        video_n++;
        er = tmds_dec(tr);
        eg = tmds_dec(tg);
        eb = tmds_dec(tb);
        if (er !== r_s[9] || eg !== g_s[9] || eb !== b_s[9])
          note("pixel");
        if (video_n <= 16 &&
            (tr !== VEC_R[video_n-1] || tg !== VEC_G[video_n-1] ||
             tb !== VEC_B[video_n-1]))
          note("vector");
      end else if (guardb) begin
        guard_n++;
        if (tr !== GUARD_RB || tg !== GUARD_G || tb !== GUARD_RB)
          note("guard");
      end else if (pre) begin
        pre_n++;
        if (tr !== CTRL00 || tg !== CTRL01 || tb !== ctrl_of(vs_s[9], hs_s[9]))
          note("preamble");
      end else begin
        if (tr !== CTRL00 || tg !== CTRL00 || tb !== ctrl_of(vs_s[9], hs_s[9]))
          note("control");
        if (hs_s[9] && !vs_s[9])
          hs_n++;
      end
      for (px = 10; px > 0; px--) begin
        r_s[px] = r_s[px-1];
        g_s[px] = g_s[px-1];
        b_s[px] = b_s[px-1];
      end
      r_s[0] = cap_r;
      g_s[0] = cap_g;
      b_s[0] = cap_b;
      de_s = {de_s[9:0], cap_de};
      hs_s = {hs_s[9:0], cap_hs};
      vs_s = {vs_s[9:0], cap_vs};
      if (video_n == NPix)
        break;
    end
    check("tmds off stays 0", off_bad == 0);
    checks++;
    if (video_n != NPix) begin
      errors++;
      $display("FAIL video_n=%0d", video_n);
    end
    checks++;
    if (seen != 0) begin
      errors++;
      $display("FAIL mismatches=%0d", seen);
    end
    check("preamble before each line", pre_n == VAct * 8);
    check("guard before each line", guard_n == VAct * 2);
    check("hsync control symbols", hs_n == 479 * 96);
    if (errors != 0)
      $fatal(1, "hdmi tmds errors=%0d checks=%0d", errors, checks);
    $display("PASS tb_g6lc_hdmi_tmds checks=%0d pixels=%0d errors=0",
             checks, NPix);
    $finish;
  end
endmodule
