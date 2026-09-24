// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Default-off HDMI scanout for a Linux simple-framebuffer. One mode:
// 640x480, r5g6b5, stride 1280. Pixel clock is clk_i (25.175 MHz at the
// board). The framebuffer port is one 16-bit read per active pixel, one
// cycle later. HdmiEn=0 ties the pins off and elaborates no counters.
// Not virtio-gpu, not a shader, not ai_island, not a board PHY.

module g6lc_hdmi_scanout #(
  parameter bit          HdmiEn = 1'b0,
  parameter int unsigned HAct   = 640,
  parameter int unsigned HFp    = 16,
  parameter int unsigned HSyncW = 96,
  parameter int unsigned HBp    = 48,
  parameter int unsigned VAct   = 480,
  parameter int unsigned VFp    = 10,
  parameter int unsigned VSyncW = 2,
  parameter int unsigned VBp    = 33
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        run_i,
  output logic        fb_re_o,
  output logic [31:0] fb_addr_o,
  output logic [15:0] fb_x_o,
  output logic [15:0] fb_y_o,
  input  logic [15:0] fb_rdata_i,
  output logic        hs_o,
  output logic        vs_o,
  output logic        de_o,
  output logic [7:0]  r_o,
  output logic [7:0]  g_o,
  output logic [7:0]  b_o
);
  localparam int unsigned HTotal = HAct + HFp + HSyncW + HBp;
  localparam int unsigned VTotal = VAct + VFp + VSyncW + VBp;

  if (!HdmiEn) begin : gen_off
    assign fb_re_o   = 1'b0;
    assign fb_addr_o = '0;
    assign fb_x_o    = '0;
    assign fb_y_o    = '0;
    assign hs_o      = 1'b0;
    assign vs_o      = 1'b0;
    assign de_o      = 1'b0;
    assign r_o       = '0;
    assign g_o       = '0;
    assign b_o       = '0;
    logic unused;
    assign unused = clk_i | rst_ni | run_i | (|fb_rdata_i);
  end else begin : gen_on
    logic [$clog2(HTotal)-1:0] h_q;
    logic [$clog2(VTotal)-1:0] v_q;
    logic de_d, hs_d, vs_d;
    logic de_q, hs_q, vs_q;
    logic [15:0] pix_q;

    wire h_act = (h_q < HAct);
    wire v_act = (v_q < VAct);
    wire de_w  = run_i && h_act && v_act;
    wire hs_w  = (h_q >= (HAct + HFp)) && (h_q < (HAct + HFp + HSyncW));
    wire vs_w  = (v_q >= (VAct + VFp)) && (v_q < (VAct + VFp + VSyncW));
    wire [31:0] pix_i = (32'(v_q) * HAct) + 32'(h_q);

    function automatic logic [7:0] exp5(input logic [4:0] c);
      return {c, c[4:2]};
    endfunction
    function automatic logic [7:0] exp6(input logic [5:0] c);
      return {c, c[5:4]};
    endfunction

    assign fb_re_o   = de_w;
    assign fb_addr_o = pix_i << 1;
    assign fb_x_o    = 16'(h_q);
    assign fb_y_o    = 16'(v_q);
    assign de_o      = de_q;
    assign hs_o      = hs_q;
    assign vs_o      = vs_q;
    assign r_o       = de_q ? exp5(pix_q[15:11]) : 8'h00;
    assign g_o       = de_q ? exp6(pix_q[10:5])  : 8'h00;
    assign b_o       = de_q ? exp5(pix_q[4:0])   : 8'h00;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        h_q   <= '0;
        v_q   <= '0;
        de_d  <= 1'b0;
        hs_d  <= 1'b0;
        vs_d  <= 1'b0;
        de_q  <= 1'b0;
        hs_q  <= 1'b0;
        vs_q  <= 1'b0;
        pix_q <= '0;
      end else begin
        de_d  <= de_w;
        hs_d  <= hs_w;
        vs_d  <= vs_w;
        de_q  <= de_d;
        hs_q  <= hs_d;
        vs_q  <= vs_d;
        pix_q <= fb_rdata_i;
        if (run_i) begin
          if (h_q == HTotal - 1) begin
            h_q <= '0;
            v_q <= (v_q == VTotal - 1) ? '0 : v_q + 1'b1;
          end else begin
            h_q <= h_q + 1'b1;
          end
        end
      end
    end
  end
endmodule
