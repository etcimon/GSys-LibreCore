// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Simulation reference for the float codes. Width selects the decode.
// E4M3 and E5M2 share the 8-bit path. FP16 and BF16 share the 16-bit path.
// Products accumulate in binary32.
//
// `real` is not a synthesizable MAC. Callers instantiate this only behind
// FP_REAL_MODEL. The live island does not instantiate it. A mask bit that
// names a float format is not this module.

module g6lc_ai_fp_dot;
  function automatic real pow2(input int e);
    real r;
    int i;
    r = 1.0;
    if (e >= 0) begin
      for (i = 0; i < e; i++) r = r * 2.0;
    end else begin
      for (i = 0; i < -e; i++) r = r / 2.0;
    end
    return r;
  endfunction

  function automatic real unpack_f32(input int unsigned bits);
    int exp, man;
    real mag;
    exp = (bits >> 23) & 32'hff;
    man = bits & 32'h7fffff;
    if (exp == 0)
      mag = (real'(man) / 8388608.0) * pow2(1 - 127);
    else
      mag = (1.0 + real'(man) / 8388608.0) * pow2(exp - 127);
    return bits[31] ? -mag : mag;
  endfunction

  function automatic int unsigned pack_f32(input real x);
    int exp, i;
    real mag, norm;
    int unsigned man, sign;
    if (x == 0.0) return 0;
    sign = x < 0.0;
    mag = sign ? -x : x;
    exp = 0;
    norm = mag;
    for (i = 0; i < 128 && norm >= 2.0; i++) begin
      norm = norm / 2.0;
      exp++;
    end
    for (i = 0; i < 148 && norm < 1.0; i++) begin
      norm = norm * 2.0;
      exp--;
    end
    man = $rtoi((norm - 1.0) * 8388608.0);
    return (sign << 31) | ((exp + 127) << 23) | (man & 32'h7fffff);
  endfunction

  function automatic real widen(input int unsigned fmt, input int unsigned bits);
    int unsigned exp_bits, man_bits, bias, exp_mask, man_mask, exp, man, sign;
    real mag;
    if (fmt == 6) return unpack_f32(bits << 16); // BF16
    if (fmt == 7 || fmt == 0) return unpack_f32(bits);
    case (fmt)
      3: begin exp_bits = 4; man_bits = 3; bias = 7; end
      4: begin exp_bits = 5; man_bits = 2; bias = 15; end
      default: begin exp_bits = 5; man_bits = 10; bias = 15; end // FP16
    endcase
    exp_mask = (32'h1 << exp_bits) - 1;
    man_mask = (32'h1 << man_bits) - 1;
    sign = (bits >> (exp_bits + man_bits)) & 32'h1;
    exp  = (bits >> man_bits) & exp_mask;
    man  = bits & man_mask;
    if (exp == 0)
      mag = real'(man) / real'(32'h1 << man_bits) * pow2(1 - int'(bias));
    else
      mag = (1.0 + real'(man) / real'(32'h1 << man_bits)) * pow2(int'(exp) - int'(bias));
    return sign != 0 ? -mag : mag;
  endfunction

  function automatic int unsigned dot2(
      input int unsigned fmt,
      input int unsigned a0, input int unsigned a1,
      input int unsigned b0, input int unsigned b1
  );
    real acc;
    acc = widen(fmt, a0) * widen(fmt, b0) + widen(fmt, a1) * widen(fmt, b1);
    return pack_f32(acc);
  endfunction

  // One product added to a binary32 accumulator word.
  function automatic int unsigned mac(
      input int unsigned fmt,
      input int unsigned acc,
      input int unsigned a,
      input int unsigned b
  );
    return pack_f32(unpack_f32(acc) + widen(fmt, a) * widen(fmt, b));
  endfunction
endmodule
