// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Video-only TMDS symbols for one pixel clock. Channel 0 is blue, 1 is
// green, 2 is red. Blanking carries HSYNC/VSYNC. The eight characters
// before a video line are the video preamble (CTL0=1), then two video
// guard characters, then the active pixels. No audio or data island.
// The 10× shift is g6lc_hdmi_ser. HdmiEn=0 drives the symbols to zero.

module g6lc_hdmi_tmds #(
  parameter bit HdmiEn = 1'b0
) (
  input  logic       clk_i,
  input  logic       rst_ni,
  input  logic       de_i,
  input  logic       hs_i,
  input  logic       vs_i,
  input  logic [7:0] r_i,
  input  logic [7:0] g_i,
  input  logic [7:0] b_i,
  output logic [9:0] r_o,
  output logic [9:0] g_o,
  output logic [9:0] b_o
);
  function automatic logic [9:0] tmds_ctrl(input logic d1, input logic d0);
    case ({d1, d0})
      2'b00: return 10'b1101010100;
      2'b01: return 10'b0010101011;
      2'b10: return 10'b0101010100;
      default: return 10'b1010101011;
    endcase
  endfunction

  // {next disparity, 10-bit symbol}. Disparity is a signed 8-bit count.
  function automatic logic [17:0] tmds_video(
    input logic [7:0] d,
    input logic signed [7:0] cnt
  );
    logic [8:0] q_m;
    logic [9:0] q;
    logic signed [7:0] n0, n1, cnt_n;
    logic [7:0] cnt_bits;
    n1 = 8'sd0;
    for (int i = 0; i < 8; i++) n1 = n1 + d[i];
    q_m[0] = d[0];
    if (n1 > 8'sd4 || (n1 == 8'sd4 && d[0] == 1'b0)) begin
      q_m[8] = 1'b0;
      for (int i = 1; i < 8; i++) q_m[i] = q_m[i-1] ~^ d[i];
    end else begin
      q_m[8] = 1'b1;
      for (int i = 1; i < 8; i++) q_m[i] = q_m[i-1] ^ d[i];
    end
    n1 = 8'sd0;
    for (int i = 0; i < 8; i++) n1 = n1 + q_m[i];
    n0 = 8'sd8 - n1;
    if (cnt == 0 || n1 == n0) begin
      q[9] = ~q_m[8];
      q[8] = q_m[8];
      if (q_m[8]) begin
        q[7:0] = q_m[7:0];
        cnt_n = cnt + (n1 - n0);
      end else begin
        q[7:0] = ~q_m[7:0];
        cnt_n = cnt + (n0 - n1);
      end
    end else if ((cnt > 0 && n1 > n0) || (cnt < 0 && n1 < n0)) begin
      q[9] = 1'b1;
      q[8] = q_m[8];
      q[7:0] = ~q_m[7:0];
      cnt_n = cnt + (q_m[8] ? 8'sd2 : 8'sd0) + (n0 - n1);
    end else begin
      q[9] = 1'b0;
      q[8] = q_m[8];
      q[7:0] = q_m[7:0];
      cnt_n = cnt - (q_m[8] ? 8'sd0 : 8'sd2) + (n1 - n0);
    end
    cnt_bits = cnt_n;
    return {cnt_bits, q};
  endfunction

  if (!HdmiEn) begin : gen_off
    assign r_o = '0;
    assign g_o = '0;
    assign b_o = '0;
    logic unused;
    assign unused = clk_i | rst_ni | de_i | hs_i | vs_i | (|r_i) | (|g_i) | (|b_i);
  end else begin : gen_on
    // Slot 0 is the newest sample. Slot 9 is the character being emitted,
    // so the ten cycles before a video line are eight preamble + two guard.
    logic [10:0] de_h, hs_h, vs_h;
    logic [87:0] r_h, g_h, b_h;
    logic signed [7:0] cnt_r, cnt_g, cnt_b;

    wire video = de_h[9];
    wire guard = !de_h[9] && (de_h[7] || de_h[8]);
    wire pre   = !de_h[9] && !de_h[7] && !de_h[8] && (|de_h[6:0] || de_i);
    wire [7:0] r_pix = r_h[79:72];
    wire [7:0] g_pix = g_h[79:72];
    wire [7:0] b_pix = b_h[79:72];
    wire [17:0] er = tmds_video(r_pix, cnt_r);
    wire [17:0] eg = tmds_video(g_pix, cnt_g);
    wire [17:0] eb = tmds_video(b_pix, cnt_b);

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        de_h  <= '0;
        hs_h  <= '0;
        vs_h  <= '0;
        r_h   <= '0;
        g_h   <= '0;
        b_h   <= '0;
        cnt_r <= '0;
        cnt_g <= '0;
        cnt_b <= '0;
        r_o   <= '0;
        g_o   <= '0;
        b_o   <= '0;
      end else begin
        de_h <= {de_h[9:0], de_i};
        hs_h <= {hs_h[9:0], hs_i};
        vs_h <= {vs_h[9:0], vs_i};
        r_h  <= {r_h[79:0], r_i};
        g_h  <= {g_h[79:0], g_i};
        b_h  <= {b_h[79:0], b_i};
        if (video) begin
          r_o   <= er[9:0];
          g_o   <= eg[9:0];
          b_o   <= eb[9:0];
          cnt_r <= er[17:10];
          cnt_g <= eg[17:10];
          cnt_b <= eb[17:10];
        end else begin
          cnt_r <= '0;
          cnt_g <= '0;
          cnt_b <= '0;
          if (guard) begin
            r_o <= 10'b1011001100;
            g_o <= 10'b0100110011;
            b_o <= 10'b1011001100;
          end else if (pre) begin
            r_o <= tmds_ctrl(1'b0, 1'b0);
            g_o <= tmds_ctrl(1'b0, 1'b1);
            b_o <= tmds_ctrl(vs_h[9], hs_h[9]);
          end else begin
            r_o <= tmds_ctrl(1'b0, 1'b0);
            g_o <= tmds_ctrl(1'b0, 1'b0);
            b_o <= tmds_ctrl(vs_h[9], hs_h[9]);
          end
        end
      end
    end
  end
endmodule
