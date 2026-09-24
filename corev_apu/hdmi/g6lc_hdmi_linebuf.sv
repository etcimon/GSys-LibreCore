// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Two RGB565 lines in front of g6lc_hdmi_scanout. One line is shown while
// the other is filled by a single 64-bit INCR burst (160 beats, stride
// 1280). Each beat writes four lanes, one address each, so a line is
// stored before the scanner needs the next one. The scanner is held until
// line 0 is in. HdmiEn=0 issues no AR. Not a shader, not ai_island, not a TMDS PHY.

module g6lc_hdmi_linebuf #(
  parameter bit          HdmiEn = 1'b0,
  parameter int unsigned HAct   = 640,
  parameter int unsigned VAct   = 480,
  parameter int unsigned Stride = 1280
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic [31:0] base_i,
  output logic        run_o,
  input  logic        fb_re_i,
  input  logic [15:0] fb_x_i,
  input  logic [15:0] fb_y_i,
  output logic [15:0] fb_rdata_o,
  output logic        ar_valid_o,
  input  logic        ar_ready_i,
  output logic [31:0] ar_addr_o,
  output logic [7:0]  ar_len_o,
  output logic [2:0]  ar_size_o,
  output logic [1:0]  ar_burst_o,
  input  logic        r_valid_i,
  output logic        r_ready_o,
  input  logic [63:0] r_data_i,
  input  logic        r_last_i
);
  localparam int unsigned Beats = HAct / 4;

  if (!HdmiEn) begin : gen_off
    assign run_o      = 1'b0;
    assign fb_rdata_o = '0;
    assign ar_valid_o = 1'b0;
    assign ar_addr_o  = '0;
    assign ar_len_o   = '0;
    assign ar_size_o  = '0;
    assign ar_burst_o = '0;
    assign r_ready_o  = 1'b0;
    logic unused;
    assign unused = clk_i | rst_ni | (|base_i) | fb_re_i | (|fb_x_i) |
                    (|fb_y_i) | ar_ready_i | r_valid_i | (|r_data_i) | r_last_i;
  end else begin : gen_on
    // Lane k holds pixels x where x[1:0] == k. One write per lane per beat.
    // Depth is 256, not 160: a non-power-of-two array leaves the upper
    // read-mux addresses undriven, and check -assert rejects them. Beats
    // still occupy 0..159.
    localparam int unsigned LaneN = 256;
    logic [15:0] b0_0 [0:LaneN-1];
    logic [15:0] b0_1 [0:LaneN-1];
    logic [15:0] b0_2 [0:LaneN-1];
    logic [15:0] b0_3 [0:LaneN-1];
    logic [15:0] b1_0 [0:LaneN-1];
    logic [15:0] b1_1 [0:LaneN-1];
    logic [15:0] b1_2 [0:LaneN-1];
    logic [15:0] b1_3 [0:LaneN-1];
    logic [15:0] line0_q, line1_q;
    logic        valid0_q, valid1_q;
    logic        fetch_q, armed_q, which_q, run_q;
    logic [15:0] fetch_line_q;
    logic [7:0]  beat_q;
    logic [15:0] rdata_q;

    wire overwrite_ok = !which_q ? (!valid0_q || (run_q && fb_y_i > line0_q))
                                 : (!valid1_q || (run_q && fb_y_i > line1_q));
    wire [7:0] pixw = fb_x_i[9:2];

    assign run_o      = run_q;
    assign fb_rdata_o = rdata_q;
    assign ar_valid_o = fetch_q && !armed_q;
    assign ar_addr_o  = base_i + (32'(fetch_line_q) * Stride);
    assign ar_len_o   = 8'(Beats - 1);
    assign ar_size_o  = 3'd3;
    assign ar_burst_o = 2'b01;
    assign r_ready_o  = fetch_q && armed_q;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        valid0_q     <= 1'b0;
        valid1_q     <= 1'b0;
        line0_q      <= '0;
        line1_q      <= '0;
        fetch_q      <= 1'b0;
        armed_q      <= 1'b0;
        which_q      <= 1'b0;
        fetch_line_q <= '0;
        beat_q       <= '0;
        rdata_q      <= '0;
        run_q        <= 1'b0;
      end else begin
        if (!fetch_q && fetch_line_q < VAct && overwrite_ok)
          fetch_q <= 1'b1;
        if (fetch_q && !armed_q && ar_ready_i)
          armed_q <= 1'b1;
        if (fb_re_i) begin
          if (valid0_q && line0_q == fb_y_i) begin
            unique case (fb_x_i[1:0])
              2'd0: rdata_q <= b0_0[pixw];
              2'd1: rdata_q <= b0_1[pixw];
              2'd2: rdata_q <= b0_2[pixw];
              default: rdata_q <= b0_3[pixw];
            endcase
          end else if (valid1_q && line1_q == fb_y_i) begin
            unique case (fb_x_i[1:0])
              2'd0: rdata_q <= b1_0[pixw];
              2'd1: rdata_q <= b1_1[pixw];
              2'd2: rdata_q <= b1_2[pixw];
              default: rdata_q <= b1_3[pixw];
            endcase
          end
        end
        if (fetch_q && armed_q && r_valid_i) begin
          if (!which_q) begin
            b0_0[beat_q] <= r_data_i[15:0];
            b0_1[beat_q] <= r_data_i[31:16];
            b0_2[beat_q] <= r_data_i[47:32];
            b0_3[beat_q] <= r_data_i[63:48];
          end else begin
            b1_0[beat_q] <= r_data_i[15:0];
            b1_1[beat_q] <= r_data_i[31:16];
            b1_2[beat_q] <= r_data_i[47:32];
            b1_3[beat_q] <= r_data_i[63:48];
          end
          if (r_last_i) begin
            fetch_q  <= 1'b0;
            armed_q  <= 1'b0;
            beat_q   <= '0;
            if (!which_q) begin
              valid0_q <= 1'b1;
              line0_q  <= fetch_line_q;
            end else begin
              valid1_q <= 1'b1;
              line1_q  <= fetch_line_q;
            end
            if (fetch_line_q == 16'd0)
              run_q <= 1'b1;
            fetch_line_q <= fetch_line_q + 16'd1;
            which_q      <= ~which_q;
          end else
            beat_q <= beat_q + 8'd1;
        end
      end
    end
  end
endmodule
