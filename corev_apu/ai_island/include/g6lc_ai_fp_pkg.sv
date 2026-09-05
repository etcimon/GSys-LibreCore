// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

package g6lc_ai_fp_pkg;
  typedef struct packed {
    logic [31:0] value;
    logic snan;
    logic valid;
  } fp_widen_t;

  function automatic fp_widen_t fp_widen_narrow(
      input logic [15:0] raw,
      input int unsigned exp_bits,
      input int unsigned man_bits,
      input int unsigned bias,
      input logic finite_e4m3
  );
    fp_widen_t widened;
    logic sign_bit;
    logic [31:0] fraction;
    logic [31:0] normalized;
    int unsigned exponent;
    int unsigned max_exponent;
    int unsigned leading;
    int unsigned fp32_exponent;
    widened = '0;
    widened.valid = 1'b1;
    sign_bit = raw[exp_bits + man_bits];
    fraction = 32'(raw) & ((32'd1 << man_bits) - 32'd1);
    max_exponent = (32'd1 << exp_bits) - 32'd1;
    exponent = (32'(raw) >> man_bits) & max_exponent;
    leading = 0;
    normalized = 0;
    fp32_exponent = 0;
    if (exponent == max_exponent && (!finite_e4m3 || fraction == 32'd7)) begin
      if (fraction == 0 && !finite_e4m3) begin
        widened.value = {sign_bit, 8'hff, 23'd0};
      end else begin
        widened.value = 32'h7fc00000;
        widened.snan = !finite_e4m3 && !fraction[man_bits - 1];
      end
    end else if (exponent == 0 && fraction == 0) begin
      widened.value = {sign_bit, 31'd0};
    end else begin
      if (exponent == 0) begin
        for (int unsigned i = 0; i < 10; i++) begin
          if (fraction[i]) leading = i;
        end
        fp32_exponent = 32'd128 - bias - man_bits + leading;
        normalized = fraction << (32'd23 - leading);
      end else begin
        fp32_exponent = exponent + 32'd127 - bias;
        normalized = fraction << (32'd23 - man_bits);
      end
      widened.value = {sign_bit, 8'(fp32_exponent), normalized[22:0]};
    end
    return widened;
  endfunction

  function automatic fp_widen_t fp_widen(input logic [31:0] raw, input logic [2:0] numfmt);
    fp_widen_t widened;
    widened = '0;
    case (numfmt)
      3'(config_pkg::AI_FMT_FP8_E4M3):
        widened = fp_widen_narrow({8'd0, raw[7:0]}, 4, 3, 7, 1'b1);
      3'(config_pkg::AI_FMT_FP8_E5M2):
        widened = fp_widen_narrow({8'd0, raw[7:0]}, 5, 2, 15, 1'b0);
      3'(config_pkg::AI_FMT_FP16):
        widened = fp_widen_narrow(raw[15:0], 5, 10, 15, 1'b0);
      3'(config_pkg::AI_FMT_BF16):
        widened = '{value: {raw[15:0], 16'd0}, snan: 1'b0, valid: 1'b1};
      3'(config_pkg::AI_FMT_FP32):
        widened = '{value: raw, snan: 1'b0, valid: 1'b1};
      default: widened = '0;
    endcase
    return widened;
  endfunction
endpackage
