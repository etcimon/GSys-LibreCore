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
  // Generic block-floating dot-product helpers (F2–F5)
  //
  // These decompose FP8/FP16/BF16/FP32 into a fixed-point integer representation
  //   value = (-1)^sign * mantissa * 2^exponent
  // where mantissa already includes the implicit leading bit and the
  // mantissa-width scale has been absorbed into the exponent. This makes the
  // product and the BFP alignment integer-only.
  //
  // FP_DOT_MAXW is sized to hold a Lanes=256 dot product of two FP32 values
  // with the most-negative block exponent: product_mantissa (48 bits) plus the
  // worst-case exponent spread (about 552 for FP32/BF16) plus lane headroom.
  // This is a synthesis/area choice, not a throughput or STA claim.
  // ---------------------------------------------------------------------------

  localparam int unsigned FP_DOT_MAXW = 640;

  typedef struct packed {
    logic        sign;
    logic [31:0] mant;          // integer significand with implicit bit
    logic signed [15:0] exp;    // exponent of mantissa * 2^exp
    logic        is_nan;
    logic        is_inf;
    logic        is_zero;
  } fp_dot_value_t;

  typedef struct packed {
    logic        sign;
    logic [63:0] mant;          // product mantissa (max 24*24 for FP32)
    logic signed [15:0] exp;    // product exponent
    logic        is_nan;
    logic        is_inf;
    logic        is_zero;
  } fp_dot_product_t;

  function automatic fp_dot_value_t fp_dot_decode_value(
      input logic [31:0] raw,
      input logic [2:0]  numfmt
  );
    fp_dot_value_t d;
    int unsigned exp_bits, man_bits, bias;
    logic        has_inf;
    logic [7:0]  max_exp;
    logic [22:0] max_man;
    logic [7:0]  exp_enc;
    logic [22:0] man_enc;
    d = '0;
    has_inf = 1'b1;
    max_exp = 8'd0;
    max_man = 23'd0;
    exp_enc = 8'd0;
    man_enc = 23'd0;

    case (numfmt)
      3'(config_pkg::AI_FMT_FP8_E4M3): begin
        exp_bits = 4; man_bits = 3; bias = 7; has_inf = 1'b0;
        max_exp  = 8'd15;
        max_man  = 23'd7;
      end
      3'(config_pkg::AI_FMT_FP8_E5M2): begin
        exp_bits = 5; man_bits = 2; bias = 15; has_inf = 1'b1;
        max_exp  = 8'd31;
        max_man  = 23'd3;
      end
      3'(config_pkg::AI_FMT_FP16): begin
        exp_bits = 5; man_bits = 10; bias = 15; has_inf = 1'b1;
        max_exp  = 8'd31;
        max_man  = 23'd1023;
      end
      3'(config_pkg::AI_FMT_BF16): begin
        exp_bits = 8; man_bits = 7; bias = 127; has_inf = 1'b1;
        max_exp  = 8'd255;
        max_man  = 23'd127;
      end
      3'(config_pkg::AI_FMT_FP32): begin
        exp_bits = 8; man_bits = 23; bias = 127; has_inf = 1'b1;
        max_exp  = 8'd255;
        max_man  = 23'h7fffff;
      end
      default: begin
        // Unsupported format: poison the value so the product is not finite.
        d.is_nan = 1'b1;
        return d;
      end
    endcase

    d.sign = raw[exp_bits + man_bits];
    exp_enc = 8'((raw >> man_bits) & ((32'd1 << exp_bits) - 32'd1));
    man_enc = 23'(raw        & ((32'd1 << man_bits) - 32'd1));

    if (exp_enc == 8'd0 && man_enc == 23'd0) begin
      d.is_zero = 1'b1;
    end else if (has_inf && (exp_enc == max_exp)) begin
      if (man_enc == 23'd0)
        d.is_inf = 1'b1;
      else
        d.is_nan = 1'b1;
    end else if (!has_inf && (exp_enc == max_exp) && (man_enc == max_man)) begin
      // E4M3: only the all-ones pattern at the top exponent is NaN.
      d.is_nan = 1'b1;
    end else begin
      d.is_zero = 1'b0;
      d.is_nan  = 1'b0;
      d.is_inf  = 1'b0;
      if (exp_enc == 8'd0) begin
        // Subnormal: exponent field is 1-bias, mantissa has no implicit 1.
        d.mant = 32'(man_enc);
        d.exp  = 16'(1 - int'(bias) - int'(man_bits));
      end else begin
        // Normal: exp field - bias, mantissa is 1.man
        d.mant = 32'((32'd1 << man_bits) + 32'(man_enc));
        d.exp  = 16'(int'(exp_enc) - int'(bias) - int'(man_bits));
      end
    end
    return d;
  endfunction

  function automatic fp_dot_product_t fp_dot_product(
      input fp_dot_value_t a,
      input fp_dot_value_t b
  );
    fp_dot_product_t p;
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
      p.mant    = 64'(a.mant[23:0] * b.mant[23:0]);
      p.is_nan  = 1'b0;
      p.is_inf  = 1'b0;
      p.is_zero = 1'b0;
    end
    return p;
  endfunction

  // Align a finite floating product's signed mantissa to the block exponent.
  // Returns an FP_DOT_MAXW-bit signed integer ready for the reduction tree.
  function automatic logic signed [FP_DOT_MAXW-1:0] fp_dot_product_aligned(
      input fp_dot_product_t prod,
      input logic signed [15:0] block_exp
  );
    logic signed [FP_DOT_MAXW-1:0] aligned = FP_DOT_MAXW'(0);
    if (!prod.is_nan && !prod.is_inf && !prod.is_zero) begin
      logic signed [63:0]  sm;
      int                    shift;
      sm    = prod.sign ? (~$signed(prod.mant) + 64'sd1) : $signed(prod.mant);
      shift = int'(prod.exp) - int'(block_exp);
      if (shift >= 0 && shift < FP_DOT_MAXW)
        aligned = {{(FP_DOT_MAXW-64){sm[63]}}, sm} << shift;
      else
        aligned = FP_DOT_MAXW'(0);
    end
    return aligned;
  endfunction

  // Convert a fixed-point integer (mant * 2^exp) to IEEE 754 binary32.
  // Used at the end of the BFP dot product. Uses round-to-nearest-even.
  // Returns {flags[4:0], result[31:0]} so the result and flags are a single
  // pure return value, avoiding output-argument loops in synthesis.
  function automatic logic [36:0] bfp_mant_exp_to_fp32(
      input logic                          sign,
      input logic signed [FP_DOT_MAXW-1:0] mant,
      input logic signed [15:0]            exp
  );
    logic [FP_DOT_MAXW-1:0] abs_m, abs_m_rounded;
    logic [7:0]             exp_field;
    logic [22:0]            man_field;
    logic [31:0]            result;
    logic [4:0]             flags;
    logic                   round_up;
    int                     msb;
    int                     shift;
    int                     msb_eff;
    logic [24:0]            m24, m24_rounded, m24_final;
    logic [24:0]            m_sub, m_sub_rounded;
    logic [FP_DOT_MAXW-1:0] discarded;
    logic                   guard, sticky;

    flags  = 5'd0;
    result = 32'd0;
    if (mant == FP_DOT_MAXW'(0)) begin
      // Signed zero: only sign matters when mantissa is zero.
      return {flags, sign, 31'd0};
    end

    abs_m = mant[FP_DOT_MAXW-1] ? -mant : mant;

    // Find MSB position (floor(log2(abs_m))) using $clog2 and a power-of-2
    // correction, avoiding self-referential loops in the priority encoder.
    msb = $clog2(abs_m) - ((abs_m != FP_DOT_MAXW'(0) &&
                            (abs_m & (abs_m - FP_DOT_MAXW'(1))) != FP_DOT_MAXW'(0)) ? 1 : 0);

    // If the true exponent is too large for finite FP32, return Inf.
    if (msb + int'(exp) > 127) begin
      flags[2] = 1'b1; // overflow
      return {flags, sign, 8'hff, 23'd0};
    end

    // Subnormal? (< smallest normal 2^-126)
    if (msb + int'(exp) < -126) begin
      shift = -int'(exp) - 149;
      if (shift <= 0) begin
        abs_m_rounded = abs_m << (-shift);
        if (abs_m_rounded >= (FP_DOT_MAXW'(1) << 23)) begin
          man_field = 23'(abs_m_rounded - (FP_DOT_MAXW'(1) << 23));
          return {flags, sign, 8'd1, man_field};
        end
        flags[0] = 1'b0;  // exact
        return {flags, sign, 8'd0, 23'(abs_m_rounded)};
      end else begin
        if (shift >= FP_DOT_MAXW) begin
          m_sub  = 25'd0;
          guard  = 1'b0;
          sticky = 1'b0;
        end else begin
          m_sub     = 25'(abs_m >> shift);
          discarded = (abs_m & ((FP_DOT_MAXW'(1) << shift) - FP_DOT_MAXW'(1)));
          guard     = ((abs_m >> (shift - 1)) & FP_DOT_MAXW'(1)) != FP_DOT_MAXW'(0);
          if (shift > 1)
            sticky = (abs_m & ((FP_DOT_MAXW'(1) << (shift - 1)) - FP_DOT_MAXW'(1))) != FP_DOT_MAXW'(0);
          else
            sticky = 1'b0;
        end
        flags[0] = (guard || sticky) ? 1'b1 : 1'b0;  // inexact if any discarded bit
        round_up = guard && (sticky || m_sub[0]);
        m_sub_rounded = round_up ? m_sub + 25'd1 : m_sub;
        if (m_sub_rounded == 25'h0800000) begin
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
        m24    = 25'(abs_m);
        guard  = 1'b0;
        sticky = 1'b0;
      end else if (shift >= FP_DOT_MAXW) begin
        m24    = 25'd0;
        guard  = 1'b0;
        sticky = 1'b0;
      end else begin
        m24       = 25'(abs_m >> shift);
        discarded = (abs_m & ((FP_DOT_MAXW'(1) << shift) - FP_DOT_MAXW'(1)));
        guard     = ((abs_m >> (shift - 1)) & FP_DOT_MAXW'(1)) != FP_DOT_MAXW'(0);
        if (shift > 1)
          sticky = (abs_m & ((FP_DOT_MAXW'(1) << (shift - 1)) - FP_DOT_MAXW'(1))) != FP_DOT_MAXW'(0);
        else
          sticky = 1'b0;
      end
      flags[0] = (guard || sticky) ? 1'b1 : 1'b0;  // inexact if any discarded bit
      round_up = guard && (sticky || m24[0]);
      m24_rounded = round_up ? m24 + 25'd1 : m24;
      if (m24_rounded == 25'h1000000) begin
        m24_final = 25'h0800000;
        msb_eff   = msb + 1;
      end else begin
        m24_final = m24_rounded;
        msb_eff   = msb;
      end
      man_field = m24_final[22:0];
    end else begin
      // msb < 23: value is small but msb+exp >= -126, so it is normal with
      // trailing zeros in the mantissa. No rounding needed.
      m24       = 25'(abs_m << (23 - msb));
      m24_final = m24;
      msb_eff   = msb;
      flags[0]  = 1'b0;  // exact
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

  // RNE FP32 addition, used by the GEMM accumulator for multi-step float tiles.
  // Decodes both operands, aligns to the larger exponent, adds the integer
  // mantissas, and normalises/rounds with bfp_mant_exp_to_fp32.
  // Returns {flags[4:0], result[31:0]} with flags layout matching pe_dot_float.
  function automatic logic [36:0] fp32_add(
      input logic [31:0] a,
      input logic [31:0] b
  );
    fp_dot_value_t da, db;
    logic signed [FP_DOT_MAXW-1:0] ma, mb, msum;
    logic signed [15:0] exp_c;
    logic               sign_c;
    logic [36:0]        res;
    da = fp_dot_decode_value(a, 3'(config_pkg::AI_FMT_FP32));
    db = fp_dot_decode_value(b, 3'(config_pkg::AI_FMT_FP32));

    // NaN propagation and infinities
    if (da.is_nan || db.is_nan)
      return {5'b10000, 32'h7fc00000};
    if (da.is_inf && db.is_inf) begin
      if (da.sign != db.sign)
        return {5'b10000, 32'h7fc00000};
      return {5'b00100, {da.sign, 8'hff, 23'd0}};
    end
    if (da.is_inf) return {5'b00100, {da.sign, 8'hff, 23'd0}};
    if (db.is_inf) return {5'b00100, {db.sign, 8'hff, 23'd0}};

    // Zeros: sign is negative only if both are negative zero.
    if (da.is_zero && db.is_zero)
      return {5'd0, {da.sign & db.sign, 31'd0}};

    // Normal/subnormal finite values.  da.exp/db.exp are such that
    // value = (-1)^sign * mant * 2^exp.  Align the smaller to the larger exp.
    exp_c = (da.exp > db.exp) ? da.exp : db.exp;

    ma = da.sign ? -$signed({{(FP_DOT_MAXW-32){1'b0}}, da.mant})
                 :  $signed({{(FP_DOT_MAXW-32){1'b0}}, da.mant});
    mb = db.sign ? -$signed({{(FP_DOT_MAXW-32){1'b0}}, db.mant})
                 :  $signed({{(FP_DOT_MAXW-32){1'b0}}, db.mant});

    if (da.exp < exp_c) ma = ma >>> (exp_c - da.exp);
    if (db.exp < exp_c) mb = mb >>> (exp_c - db.exp);

    msum  = ma + mb;
    sign_c = msum[FP_DOT_MAXW-1];
    res   = bfp_mant_exp_to_fp32(sign_c, msum, exp_c);
    return res;
  endfunction
endpackage
