// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// 10× shift of one TMDS symbol. clk_i is the bit clock. load_i is a single
// cycle pulse, once per symbol, with the 10-bit words stable. Bit 0 of each
// word is sent on the load cycle, then bits 1..9. Single-ended bits, not the
// differential pair. HdmiEn=0 holds the pins at zero.

module g6lc_hdmi_ser #(
  parameter bit HdmiEn = 1'b0
) (
  input  logic       clk_i,
  input  logic       rst_ni,
  input  logic       load_i,
  input  logic [9:0] r_i,
  input  logic [9:0] g_i,
  input  logic [9:0] b_i,
  output logic       r_o,
  output logic       g_o,
  output logic       b_o
);
  if (!HdmiEn) begin : gen_off
    assign r_o = 1'b0;
    assign g_o = 1'b0;
    assign b_o = 1'b0;
    logic unused;
    assign unused = clk_i | rst_ni | load_i | (|r_i) | (|g_i) | (|b_i);
  end else begin : gen_on
    logic [9:0] r_sh, g_sh, b_sh;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        r_sh <= '0;
        g_sh <= '0;
        b_sh <= '0;
        r_o  <= 1'b0;
        g_o  <= 1'b0;
        b_o  <= 1'b0;
      end else if (load_i) begin
        r_o  <= r_i[0];
        g_o  <= g_i[0];
        b_o  <= b_i[0];
        r_sh <= {1'b0, r_i[9:1]};
        g_sh <= {1'b0, g_i[9:1]};
        b_sh <= {1'b0, b_i[9:1]};
      end else begin
        r_o  <= r_sh[0];
        g_o  <= g_sh[0];
        b_o  <= b_sh[0];
        r_sh <= {1'b0, r_sh[9:1]};
        g_sh <= {1'b0, g_sh[9:1]};
        b_sh <= {1'b0, b_sh[9:1]};
      end
    end
  end
endmodule
