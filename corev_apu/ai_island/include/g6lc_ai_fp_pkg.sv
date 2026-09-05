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
  // ---------------------------------------------------------------------------
  // FP8 block-floating-point dot product helpers (F2)
  //
  // These decompose FP8 into a fixed-point integer representation
  //   value = (-1)^sign * mantissa * 2^exponent
  // where mantissa already includes the implicit leading bit and the
  // mantissa-width scale has been absorbed into the exponent. This makes the
  // product and the BFP alignment integer-only.
  // ---------------------------------------------------------------------------

  typedef struct packed {
    logic        sign;
    logic [15:0] mant;   // integer significand with implicit bit
    logic signed [15:0] exp;   // exponent of mantissa*2^exp
    logic        is_nan;
    logic        is_inf;
    logic        is_zero;
  } fp8_value_t;

  typedef struct packed {
    logic        sign;
    logic [31:0] mant;   // product mantissa (max 14*14 for E4M3, 7*7 for E5M2)
    logic signed [15:0] exp;   // product exponent
    logic        is_nan;
    logic        is_inf;
    logic        is_zero;
  } fp8_product_t;

  function automatic fp8_value_t fp8_decode_value(
      input logic [7:0] raw,
      input logic [2:0] numfmt
  );
    fp8_value_t d;
    int unsigned exp_bits, man_bits, bias;
    logic [4:0]  max_exp;
    logic [2:0]  max_man;
    logic [4:0]  exp_enc;
    logic [2:0]  man_enc;
    d = '0;
    d.sign = raw[7];
    if (numfmt == 3'(config_pkg::AI_FMT_FP8_E4M3)) begin
      exp_bits = 4; man_bits = 3; bias = 7; max_exp = 5'd15; max_man = 3'd7;
      exp_enc  = {1'b0, raw[6:3]};
      man_enc  = raw[2:0];
    end else begin
      exp_bits = 5; man_bits = 2; bias = 15; max_exp = 5'd31; max_man = 3'd3;
      exp_enc  = raw[6:2];
      man_enc  = {1'b0, raw[1:0]};
    end

    if (exp_enc == 5'd0 && man_enc == 3'd0) begin
      d.is_zero = 1'b1;
      d.mant    = 16'd0;
      d.exp     = 16'd0;
    end else if (exp_enc == max_exp && man_enc == max_man) begin
      // E4M3: 0x7f is the only NaN. E5M2: 0x7f/0xff are NaN.
      d.is_nan  = 1'b1;
      d.mant    = 16'd0;
      d.exp     = 16'd0;
    end else if (numfmt == 3'(config_pkg::AI_FMT_FP8_E5M2) && exp_enc == 5'd31 && man_enc == 3'd0) begin
      d.is_inf  = 1'b1;
      d.mant    = 16'd0;
      d.exp     = 16'd0;
    end else begin
      d.is_zero = 1'b0;
      d.is_nan  = 1'b0;
      d.is_inf  = 1'b0;
      if (exp_enc == 5'd0) begin
        // subnormal: exponent field is 1-bias, mantissa has no implicit 1
        d.mant = 16'(man_enc);
        d.exp  = 16'(1 - int'(bias) - int'(man_bits));
      end else begin
        // normal: exp field - bias, mantissa is 1.man
        d.mant = 16'((1 << man_bits) + {29'd0, man_enc});
        d.exp  = 16'(int'(exp_enc) - int'(bias) - int'(man_bits));
      end
    end
    return d;
  endfunction

  function automatic fp8_product_t fp8_product(
      input fp8_value_t a,
      input fp8_value_t b
  );
    fp8_product_t p;
    p = '0;
    if (a.is_nan || b.is_nan) begin
      p.is_nan = 1'b1;
    end else if ((a.is_inf && b.is_zero) || (b.is_inf && a.is_zero)) begin
      p.is_nan = 1'b1;
    end else if (a.is_inf || b.is_inf) begin
      p.is_inf = 1'b1;
      p.sign   = a.sign ^ b.sign;
    end else if (a.is_zero || b.is_zero) begin
      p.is_zero = 1'b1;
      p.sign    = a.sign ^ b.sign;  // signed zero preserved
    end else begin
      p.sign    = a.sign ^ b.sign;
      p.exp     = a.exp + b.exp;
      p.mant    = 32'(a.mant) * 32'(b.mant);
      p.is_nan  = 1'b0;
      p.is_inf  = 1'b0;
      p.is_zero = 1'b0;
    end
    return p;
  endfunction

  // Align a finite FP8 product's signed mantissa to the block exponent.
  // Returns a 128-bit signed integer ready for the reduction tree.
  function automatic logic signed [127:0] fp8_product_aligned(
      input fp8_product_t prod,
      input logic signed [15:0] block_exp
  );
    logic signed [127:0] aligned = 128'd0;
    if (!prod.is_nan && !prod.is_inf && !prod.is_zero) begin
      logic signed [31:0]  sm;
      int                    shift;
      sm    = prod.sign ? -$signed(prod.mant) : $signed(prod.mant);
      shift = int'(prod.exp) - int'(block_exp);
      if (shift >= 0 && shift < 128) aligned = {{96{sm[31]}}, sm} << shift;
      else aligned = 128'd0;
    end
    return aligned;
  endfunction

  // Convert a fixed-point integer (mant * 2^exp) to IEEE 754 binary32.
  // Used at the end of the BFP dot product. Uses round-to-nearest-even.
  // Returns {flags[4:0], result[31:0]} so the result and flags are a single
  // pure return value, avoiding output-argument loops in synthesis.
  function automatic logic [36:0] bfp_mant_exp_to_fp32(
      input logic        sign,
      input logic signed [127:0] mant,
      input logic signed [15:0]  exp
  );
    logic [127:0] abs_m, abs_m_rounded;
    logic [7:0]   exp_field;
    logic [22:0]  man_field;
    logic [31:0]  result;
    logic [4:0]   flags;
    logic         round_up;
    int           msb;
    int           shift;
    int           msb_eff;
    logic [24:0]  m24, m24_rounded, m24_final;
    logic [24:0]  m_sub, m_sub_rounded;
    logic [127:0] discarded;
    logic         guard, sticky;
    flags = 5'd0;
    result = 32'd0;
    if (mant == 128'd0) begin
      // Signed zero: only sign matters when mantissa is zero.
      return {flags, sign, 31'd0};
    end
    abs_m = mant[127] ? -mant : mant;

    // Find MSB position (floor(log2(abs_m))) using $clog2 and a power-of-2
    // correction, avoiding self-referential loops in the priority encoder.
    msb = $clog2(abs_m) - ((abs_m != 0 && (abs_m & (abs_m - 128'd1)) != 128'd0) ? 1 : 0);

    // FP32 unbiased exponent = msb + int'(exp)
    // (abs_m * 2^exp = 2^msb * (abs_m/2^msb) * 2^exp)
    // Biased exponent = msb + int'(exp) + 127
    //
    // If the true exponent is too small for even a subnormal, return signed 0.
    if (msb + int'(exp) < -149) begin
      flags[1] = 1'b1; // underflow
      return {flags, sign, 31'd0};
    end

    // If the true exponent is >= 128 (too large for finite FP32), return Inf.
    if (msb + int'(exp) > 127) begin
      flags[2] = 1'b1; // overflow
      return {flags, sign, 8'hff, 23'd0};
    end

    // Subnormal? (< smallest normal 2^-126)
    if (msb + int'(exp) < -126) begin
      // Subnormal: result = m * 2^(-149), where m is 23 bits (no implicit 1).
      // m = abs_m * 2^(exp + 149)
      // For msb + int'(exp) < -126, exp + 149 < 23 - msb.
      shift = -int'(exp) - 149;
      if (shift <= 0) begin
        // exp + 149 >= 0: shift left; no rounding needed, result fits in 24 bits.
        abs_m_rounded = abs_m << (-shift);
        if (abs_m_rounded >= 128'd1 << 23) begin
          // Crossed into normal range due to exact integer scaling (e.g. 2^-126 boundary)
          man_field = 23'(abs_m_rounded - (128'd1 << 23));
          return {flags, sign, 8'd1, man_field};
        end
        flags[0] = 1'b0;  // exact
        return {flags, sign, 8'd0, 23'(abs_m_rounded)};
      end else begin
        // exp + 149 < 0: shift right with RNE
        if (shift >= 128) begin
          m_sub = 25'd0;
          guard = 1'b0;
          sticky = 1'b0;
        end else begin
          m_sub = 25'(abs_m >> shift);
          discarded = (abs_m & ((128'd1 << shift) - 128'd1));
          guard = ((abs_m >> (shift - 1)) & 128'd1) != 128'd0;
          if (shift > 1) sticky = (abs_m & ((128'd1 << (shift - 1)) - 128'd1)) != 128'd0;
          else sticky = 1'b0;
        end
        flags[0] = (guard || sticky) ? 1'b1 : 1'b0;  // inexact if any discarded bit
        round_up = guard && (sticky || m_sub[0]);
        m_sub_rounded = round_up ? m_sub + 25'd1 : m_sub;
        if (m_sub_rounded == 25'h0800000) begin
          // rounded up to smallest normal
          flags[1] = 1'b0;
          return {flags, sign, 8'd1, 23'd0};
        end
        if (m_sub_rounded == 25'd0 && (guard || sticky)) flags[1] = 1'b1; // underflow to 0
        return {flags, sign, 8'd0, m_sub_rounded[22:0]};
      end
    end

    // Normal number: round abs_m to 24 bits, then build {sign, exp, mant}
    if (msb >= 23) begin
      shift = msb - 23;
      if (shift == 0) begin
        // msb == 23: abs_m fits in 24 bits exactly; no rounding needed
        m24 = 25'(abs_m);
        guard = 1'b0;
        sticky = 1'b0;
      end else if (shift >= 128) begin
        m24 = 25'd0;
        guard = 1'b0;
        sticky = 1'b0;
      end else begin
        m24 = 25'(abs_m >> shift);
        discarded = (abs_m & ((128'd1 << shift) - 128'd1));
        guard = ((abs_m >> (shift - 1)) & 128'd1) != 128'd0;
        if (shift > 1) sticky = (abs_m & ((128'd1 << (shift - 1)) - 128'd1)) != 128'd0;
        else sticky = 1'b0;
      end
      flags[0] = (guard || sticky) ? 1'b1 : 1'b0;  // inexact if any discarded bit
      round_up = guard && (sticky || m24[0]);
      m24_rounded = round_up ? m24 + 25'd1 : m24;
      if (m24_rounded == 25'h1000000) begin
        m24_final = 25'h0800000;
        msb_eff = msb + 1;
      end else begin
        m24_final = m24_rounded;
        msb_eff = msb;
      end
      man_field = m24_final[22:0];
    end else begin
      // msb < 23: value is small but msb+exp >= -126, so it is normal with
      // trailing zeros in the mantissa. No rounding needed.
      m24 = 25'(abs_m << (23 - msb));
      m24_final = m24;
      msb_eff = msb;
      flags[0] = 1'b0;  // exact
      man_field = m24_final[22:0];
    end

    exp_field = 8'(msb_eff + int'(exp) + 127);
    // After possible msb increment, re-check overflow
    if (msb_eff + int'(exp) > 127) begin
      flags[2] = 1'b1;
      return {flags, sign, 8'hff, 23'd0};
    end
    result = {sign, exp_field, man_field};
    return {flags, result};
  endfunction
endpackage
