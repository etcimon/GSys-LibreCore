// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

package g6lc_ai_policy_pkg;
  typedef enum logic [2:0] {
    POLICY_BULK      = 3'd0,
    POLICY_WIDE      = 3'd1,
    POLICY_TALL      = 3'd2,
    POLICY_DECODE    = 3'd3,
    POLICY_ATTENTION = 3'd4,
    POLICY_ROUTED    = 3'd5,
    POLICY_SPARSE    = 3'd6,
    POLICY_MOVEMENT  = 3'd7
  } policy_code_t;

  typedef struct packed {
    logic [1:0] dataflow;
    logic [3:0] tile_m_log2;
    logic [3:0] tile_n_log2;
    logic [3:0] tile_k_log2;
    logic       sparse_check;
    logic [1:0] prefetch_depth;
  } policy_t;

  typedef struct packed {
    logic [1:0] m;
    logic [1:0] n;
    logic [1:0] k;
    logic [2:0] opcode;
    logic [1:0] balance;
    logic       sparse;
    logic       continuous;
    logic       shape_valid;
  } policy_features_t;

  typedef struct packed {
    logic valid;
    logic apply;
    logic [2:0] rows_log2;
    logic [2:0] cols_log2;
    logic [3:0] reduction_log2;
    logic [3:0] slots_log2;
    logic [2:0] element_bits_log2;
    logic [3:0] gain_16ths;
  } policy_topology_t;

  function automatic logic policy_format_known(input logic [2:0] numfmt);
    return numfmt != 3'(config_pkg::AI_FMT_SP24);
  endfunction

  function automatic logic policy_integer_format(input logic [2:0] numfmt);
    return numfmt == 3'(config_pkg::AI_FMT_INT) || numfmt == 3'(config_pkg::AI_FMT_INT4);
  endfunction

  function automatic logic [2:0] policy_element_bits_log2(input logic [2:0] numfmt);
    case (numfmt)
      3'(config_pkg::AI_FMT_INT4): return 3'd2;
      3'(config_pkg::AI_FMT_FP16), 3'(config_pkg::AI_FMT_BF16): return 3'd4;
      3'(config_pkg::AI_FMT_FP32): return 3'd5;
      default: return 3'd3;
    endcase
  endfunction

  // Lane grouping, fitted to measured RTL cycles rather than to the cost model.
  //
  // The remote provisioning basis (verif/regress/ai-gemm-codec-basis.py, run
  // ai-gemm-codec-basis-20260906T165957Z-718434a9a9d1: six provisioning points x
  // five shape classes x seven formats x every legal AR depth, digest-stable)
  // showed the best PeLanes count depends on the numeric format and NOT on the
  // matrix shape - the winning point was identical across all five shape classes
  // for every format.  Measured optima were 8 lanes for INT4, 16 for INT8 and
  // both FP8 formats, and 32 for FP16/BF16/FP32, i.e. exactly twice the element
  // width in lanes, which is what these two functions encode.
  //
  // `policy_dot_lanes_log2` is the lane count one dot product can keep busy for
  // a format.  `policy_lane_groups_log2` is how many independent lane groups a
  // provisioned array can therefore be split into: narrow formats leave lanes
  // idle (INT4 gained 0% from going past 8 lanes) and those lanes are only
  // useful as separate groups working on separate outputs, while wide formats
  // want every lane ganged onto one dot (FP32 gained up to +188.2%).
  //
  // SCOPE, important: this fit is k=16-specific.  The mechanism in
  // g6lc_ai_gemm_seq is mac_step = 2*PeLanes for INT4 and PeLanes/bytes
  // otherwise, and a reduction ends when mac_step >= k, so the lanes a dot can
  // actually use is fmt_row_bytes(k) -- the operand row in bytes -- not a
  // function of the element width alone.  At k=16 those coincide (8/16/32/64 for
  // INT4/INT8/FP16/FP32), which is why "twice the element width" reproduces the
  // measurements.  For other k it does not follow, and the whole basis was
  // measured at k=16 only because MaxDim caps k there.  Treat these functions as
  // valid at k=16 and re-derive against k_bytes before using them elsewhere; see
  // the sub-code hypothesis section in architecture/ai-matrix/README.md.
  //
  // FP32's 64-lane requirement was confirmed by a follow-up 8/32/64-lane run
  // (ai-gemm-codec-basis-20260906T172019Z): FP32 wins at 64 lanes for every
  // shape class, up to +320.0% against the shipped 8-lane provisioning on 16x16,
  // while INT4 still gains nothing past 8 and INT8/FP8 nothing past 16.  The
  // "twice the element width" rule therefore holds across the whole measured
  // range rather than being extrapolated at its top end.
  //
  // Unknown/unsupported formats fail closed to "gang everything, split nothing".
  // Both functions are pure decisions: no datapath consumes them yet, so they
  // change no behaviour on their own.
  function automatic logic [2:0] policy_dot_lanes_log2(input logic [2:0] numfmt);
    if (!policy_format_known(numfmt)) return 3'd6;
    return 3'(policy_element_bits_log2(numfmt) + 3'd1);
  endfunction

  function automatic logic [2:0] policy_lane_groups_log2(
      input logic [2:0] numfmt, input logic [2:0] lanes_log2
  );
    logic [2:0] wanted;
    wanted = policy_dot_lanes_log2(numfmt);
    return (lanes_log2 > wanted) ? 3'(lanes_log2 - wanted) : 3'd0;
  endfunction

  typedef struct packed {
    logic enable;
    logic [3:0] level;
    logic [1:0] bank;
    logic [2:0] subcode;
    policy_code_t code;
    logic [2:0] numfmt;
    logic [15:0] m, n, k;
    logic regular_layout;
    logic independent_jobs;
    logic [8:0] ready_jobs, free_accumulators, bank_groups;
    logic exact_zero_proven;
    logic lossless_proven;
    logic reuse_a_valid, reuse_b_valid;
    logic range_safe, scale_valid, accuracy_valid;
    // The caller's own (measured or proven) bound, expressed as an index on the
    // same geometric ladder as `level` and rounded UP.  Kept as a ladder index
    // rather than raw ppm so it compares directly against the authorised level.
    logic [7:0] error_bound_q4;
    // Cancellation amplification kappa in Q8 (256 = 1.0).  For a relative
    // per-product bound this is sum|a_i b_i| / |sum a_i b_i|; for a full-scale
    // bound it is K*max|a|*max|b| / |sum a_i b_i|.  Both are >= 1 and both are
    // data dependent, which is exactly why the caller must supply a measured or
    // proven value instead of the selector assuming one.
    logic kappa_valid;
    logic [15:0] kappa_q8;
    // Per-recipe arithmetic parameter; its meaning is recipe specific and
    // documented in va_turbo_arith (retained mantissa bits, block exponent
    // spread, refinement steps, or a conversion target selector).
    logic approx_param_valid;
    logic [3:0] approx_param;
    logic window_valid;
    logic [31:0] qualified_mask;
  } va_turbo_request_t;

  // How a recipe's arithmetic relates to the native result.
  typedef enum logic [1:0] {
    VA_ARITH_EXACT = 2'd0,  // bit-identical to native; no error term at all
    VA_ARITH_REL   = 2'd1,  // per-product relative bound
    VA_ARITH_FULL  = 2'd2,  // bound referenced to full scale K*max|a|*max|b|
    VA_ARITH_NONE  = 2'd3   // arithmetic not specified; unusable by construction
  } va_arith_kind_e;

  typedef struct packed {
    va_arith_kind_e kind;
    logic [19:0] eps_ppm;   // parts per million, 0 for exact
    logic needs_param;      // requires approx_param to be valid
    logic narrows_storage;  // changes k_bytes, so it can also buy grouping
  } va_turbo_arith_t;

  typedef struct packed {
    logic supported;
    logic eligible;
    logic apply;
    logic [4:0] recipe;
    logic [2:0] target_numfmt;
    logic [2:0] groups_log2;
    logic [4:0] tail_outputs;
    logic split_rows;
    logic reuse_a, reuse_b;
    logic skip_products;
    logic convert;
    // Products are approximated while storage width is unchanged, so this
    // buys multiplier cost and never buys concurrency.  Kept distinct from
    // `convert` because conflating the two is what made the first plan wrong.
    logic approx_products;
    logic arith_specified;
    va_arith_kind_e arith_kind;
    logic [19:0] eps_ppm;
    logic [19:0] bound_ppm;
    logic [19:0] budget_ppm;
    logic [18:0] row_bytes;
  } va_turbo_plan_t;

  // Conversion target for recipe 18, whose target is caller-selected because a
  // shared conversion serves several consumers that must agree on the format.
  function automatic logic [2:0] approx_param_target(input logic [3:0] approx_param);
    case (approx_param[1:0])
      2'd0: return 3'(config_pkg::AI_FMT_FP16);
      2'd1: return 3'(config_pkg::AI_FMT_BF16);
      default: return 3'(config_pkg::AI_FMT_INT);
    endcase
  endfunction

  // Relative bound, in ppm, on a product of two operands each rounded to `bits`
  // explicit mantissa bits with round-to-nearest.  Per-operand relative error is
  // u = 2^-(bits+1), so the product carries (1+u)^2 - 1 = 2u + u^2.  Tabulated
  // rather than computed because ppm of a negative power of two is not an
  // integer shift, and a silently truncated bound would be unsound.
  function automatic logic [19:0] va_turbo_round_eps_ppm(input logic [4:0] bits);
    case (bits)
      5'd0:    return 20'd1000000;  // 1.25 saturated to 100%
      5'd1:    return 20'd562500;
      5'd2:    return 20'd265625;
      5'd3:    return 20'd128906;
      5'd4:    return 20'd63477;
      5'd5:    return 20'd31494;
      5'd6:    return 20'd15686;
      5'd7:    return 20'd7828;
      5'd8:    return 20'd3910;
      5'd9:    return 20'd1954;
      5'd10:   return 20'd977;
      5'd11:   return 20'd488;
      5'd12:   return 20'd244;
      5'd13:   return 20'd122;
      5'd14:   return 20'd61;
      5'd15:   return 20'd31;
      default: return 20'd0;        // >= 16 bits rounds below 1 ppm
    endcase
  endfunction

  // Explicit mantissa bits per storage format, which is what sets the rounding
  // bound above.  INT4/INT8 have no mantissa field; their bound is a full-scale
  // quantisation bound instead and is handled separately.
  function automatic logic [4:0] va_turbo_mantissa_bits(input logic [2:0] numfmt);
    case (numfmt)
      3'(config_pkg::AI_FMT_FP32):     return 5'd23;
      3'(config_pkg::AI_FMT_FP16):     return 5'd10;
      3'(config_pkg::AI_FMT_BF16):     return 5'd7;
      3'(config_pkg::AI_FMT_FP8_E4M3): return 5'd3;
      3'(config_pkg::AI_FMT_FP8_E5M2): return 5'd2;
      default:                         return 5'd0;
    endcase
  endfunction

  // The arithmetic each recipe performs, and the bound that follows from it.
  //
  // Kinds: EXACT recipes reorganise work without touching arithmetic, so their
  // bound is identically zero and no accuracy evidence is required.  REL recipes
  // perturb each product by a relative factor.  FULL recipes (integer
  // quantisation) have an ABSOLUTE per-element error, so no relative per-product
  // bound exists - a small element can be perturbed by 100% - and the bound is
  // instead referenced to full scale K*max|a|*max|b|.  Conflating those two
  // references would understate integer error badly, which is why the kind is
  // carried explicitly rather than assumed.
  //
  // Derivations, with u = 2^-(p+1) for p explicit mantissa bits:
  //   FP16  u = 2^-11 -> 2u+u^2 =   977 ppm      BF16 u = 2^-8  -> 7,828 ppm
  //   FP8 E4M3 u = 2^-4 -> 128,906 ppm           FP8 E5M2 u = 2^-3 -> 265,625 ppm
  //   INT8 symmetric, 127 levels: |d| <= A/254, so the full-scale bound is
  //     2/254 + 1/254^2 = 7,887 ppm
  //   INT4 symmetric, 7 levels:   |d| <= A/14,   2/14 + 1/196 = 147,908 ppm
  //   Mitchell (1+ma)(1+mb) ~= 1+ma+mb has relative error ma*mb/((1+ma)(1+mb)),
  //     whose supremum as ma,mb -> 1 is 1/4 = 250,000 ppm.  Note this is the
  //     bound for THIS formulation; the textbook 11.1% figure belongs to the
  //     log-domain formulation and must not be substituted for it.
  //
  // Recipes whose correction terms can only REDUCE error (21, 27, 28, 30, 31)
  // deliberately report the uncorrected supremum, so the analytic bound stays
  // conservative instead of encoding an unmeasured improvement factor.
  //
  // approx_param meaning: retained mantissa bits (21, 25, 30, 31), block
  // exponent spread (26), conversion target 0=FP16/1=BF16/2=INT8 (18).
  function automatic va_turbo_arith_t va_turbo_arith(
      input logic [4:0] id,
      input logic [2:0] numfmt,
      input logic [3:0] approx_param
  );
    va_turbo_arith_t a;
    logic [4:0] native_bits, effective_bits;
    a = '0;
    a.kind = VA_ARITH_EXACT;
    native_bits = va_turbo_mantissa_bits(numfmt);
    case (id)
      // Bank A - representation.
      5'd0, 5'd1, 5'd2, 5'd3: a.kind = VA_ARITH_EXACT;
      5'd4: begin a.kind = VA_ARITH_REL; a.eps_ppm = va_turbo_round_eps_ppm(5'd10);
                  a.narrows_storage = 1'b1; end
      5'd5: begin a.kind = VA_ARITH_REL; a.eps_ppm = va_turbo_round_eps_ppm(5'd7);
                  a.narrows_storage = 1'b1; end
      5'd6: begin a.kind = VA_ARITH_FULL; a.eps_ppm = 20'd7887;
                  a.narrows_storage = 1'b1; end
      5'd7: begin a.kind = VA_ARITH_REL; a.eps_ppm = va_turbo_round_eps_ppm(5'd3);
                  a.narrows_storage = 1'b1; end
      // Bank B - exact concurrency and placement.
      5'd8, 5'd9, 5'd10, 5'd11, 5'd12, 5'd13, 5'd14, 5'd15: a.kind = VA_ARITH_EXACT;
      // Bank C - reuse and predictive compression.
      5'd16, 5'd17: a.kind = VA_ARITH_EXACT;
      5'd18: begin
        a.needs_param = 1'b1;
        a.narrows_storage = 1'b1;
        case (approx_param[1:0])
          2'd0: begin a.kind = VA_ARITH_REL; a.eps_ppm = va_turbo_round_eps_ppm(5'd10); end
          2'd1: begin a.kind = VA_ARITH_REL; a.eps_ppm = va_turbo_round_eps_ppm(5'd7); end
          2'd2: begin a.kind = VA_ARITH_FULL; a.eps_ppm = 20'd7887; end
          default: a.kind = VA_ARITH_NONE;
        endcase
      end
      5'd19: begin a.kind = VA_ARITH_FULL; a.eps_ppm = 20'd7887; end
      5'd20: begin a.kind = VA_ARITH_FULL; a.eps_ppm = 20'd7887;
                   a.narrows_storage = 1'b1; end
      5'd21: begin a.kind = VA_ARITH_REL; a.needs_param = 1'b1;
                   a.eps_ppm = va_turbo_round_eps_ppm({1'b0, approx_param}); end
      5'd22, 5'd23: a.kind = VA_ARITH_EXACT;
      // Bank D - approximate arithmetic.
      5'd24: a.kind = VA_ARITH_EXACT;
      5'd25: begin a.kind = VA_ARITH_REL; a.needs_param = 1'b1;
                   a.eps_ppm = va_turbo_round_eps_ppm({1'b0, approx_param}); end
      5'd26: begin
        a.kind = VA_ARITH_REL;
        a.needs_param = 1'b1;
        effective_bits = (native_bits > {1'b0, approx_param}) ?
            5'(native_bits - {1'b0, approx_param}) : 5'd0;
        a.eps_ppm = va_turbo_round_eps_ppm(effective_bits);
      end
      5'd27, 5'd28: begin a.kind = VA_ARITH_REL; a.eps_ppm = 20'd250000; end
      5'd29: begin a.kind = VA_ARITH_FULL; a.eps_ppm = 20'd147908;
                   a.narrows_storage = 1'b1; end
      5'd30, 5'd31: begin a.kind = VA_ARITH_REL; a.needs_param = 1'b1;
                          a.eps_ppm = va_turbo_round_eps_ppm({1'b0, approx_param}); end
      default: a.kind = VA_ARITH_NONE;
    endcase
    return a;
  endfunction

  // Tile bound = eps * kappa, where kappa >= 1 absorbs cancellation.  For a
  // dot product with exact accumulation and per-product relative error eps,
  // |sum p' - sum p| <= eps * sum|p|, so relative to |sum p| the bound is
  // eps * (sum|p| / |sum p|).  kappa is data dependent and therefore an input,
  // never an assumption: kappa = 1 would silently assume no cancellation.
  function automatic logic [19:0] va_turbo_bound_ppm(
      input va_turbo_arith_t a, input logic [15:0] kappa_q8
  );
    logic [35:0] scaled;
    if (a.kind == VA_ARITH_EXACT) return 20'd0;
    if (a.kind == VA_ARITH_NONE) return 20'd1000000;
    scaled = (36'(a.eps_ppm) * 36'(kappa_q8)) >> 8;
    return (scaled > 36'd1000000) ? 20'd1000000 : 20'(scaled);
  endfunction

  // Runtime level is an error budget on a GEOMETRIC ladder: 100 ppm, doubling
  // per step, saturating at 100%.
  //
  // An earlier revision made this linear in sixteenths of a percentage point,
  // which was a RANGE ERROR rather than a tuning choice.  Useful budgets span
  // from FP16's ~1,000 ppm to a logarithmic multiply's 250,000 ppm, and a
  // 625-ppm step spends all fifteen codes inside the first decade while being
  // unable to express the rest at all: measured INT8 error (18,527 ppm) fell
  // outside the entire old range, so the ENCODING was the blocker, not the
  // arithmetic.  Doubling steps put fine resolution where fine budgets live and
  // coarse resolution where only coarse budgets are plausible.
  //
  // Level 0 stays "off" with a zero budget, so no non-exact recipe can pass.
  // Whether a large budget is ACCEPTABLE is an approval question, deliberately
  // kept separate from whether it is EXPRESSIBLE.
  function automatic logic [19:0] va_turbo_budget_ppm(input logic [3:0] level);
    logic [23:0] scaled;
    if (level == 4'd0) return 20'd0;
    scaled = 24'd100 << (level - 4'd1);
    return (scaled > 24'd1000000) ? 20'd1000000 : 20'(scaled);
  endfunction

  function automatic va_turbo_plan_t va_turbo_select(
      input config_pkg::ai_cfg_t cfg,
      input va_turbo_request_t r,
      input int unsigned lane_bytes,
      input int unsigned min_group_bytes,
      input int unsigned max_groups,
      input logic [31:0] consumer_mask
  );
    va_turbo_plan_t p, candidate;
    va_turbo_arith_t arith;
    logic [4:0] id;
    logic [18:0] row_bytes;
    logic [2:0] target;
    logic fallback_only, lossless, zero_skip, conversion, grouping, reuse_only;
    logic control_only, approx_products, separate_jobs, order_only;
    logic [8:0] work_count;
    int unsigned group_limit;
    p = '0;
    p.target_numfmt = r.numfmt;
    id = {r.bank, r.subcode};
    arith = va_turbo_arith(id, r.numfmt, r.approx_param);
    p.arith_specified = arith.kind != VA_ARITH_NONE;
    p.arith_kind = arith.kind;
    p.eps_ppm = arith.eps_ppm;
    p.budget_ppm = va_turbo_budget_ppm(r.level);
    p.bound_ppm = va_turbo_bound_ppm(arith, r.kappa_valid ? r.kappa_q8 : 16'd0);
    // Every one of the 32 IDs now has specified arithmetic, so `supported`
    // tracks whether a selection predicate exists rather than whether the
    // namespace slot is defined.
    p.supported = p.arith_specified;
    if (!p.supported || !cfg.VaTurboEn || !cfg.PolicySubcodeEn ||
        !cfg.PolicyBenefitEn || !cfg.PolicyCodecEn || !cfg.IslandFpEn ||
        !cfg.MatrixEn || cfg.Queues == 0 || !r.enable || r.level == 0 || !policy_format_known(r.numfmt) ||
        r.code == POLICY_MOVEMENT || r.m == 0 || r.n == 0 || r.k == 0 ||
        r.m > 256 || r.n > 256 || r.k > 256 ||
        lane_bytes < 8 || lane_bytes > 256 || (lane_bytes & (lane_bytes - 1)) != 0 ||
        min_group_bytes < 8 || min_group_bytes > lane_bytes ||
        (min_group_bytes & (min_group_bytes - 1)) != 0 ||
        max_groups == 0 || max_groups > 32 || (max_groups & (max_groups - 1)) != 0)
      return p;

    fallback_only   = id inside {5'd0, 5'd8, 5'd24};
    lossless        = id inside {5'd1, 5'd3, 5'd17};
    zero_skip       = id == 5'd2;
    conversion      = id inside {5'd4, 5'd5, 5'd6, 5'd7, 5'd18, 5'd19, 5'd20, 5'd29};
    grouping        = id inside {5'd9, 5'd10, 5'd11, 5'd12, 5'd13, 5'd14, 5'd15};
    reuse_only      = id == 5'd16;
    control_only    = id inside {5'd22, 5'd23};
    approx_products = id inside {5'd21, 5'd25, 5'd26, 5'd27, 5'd28, 5'd30, 5'd31};

    // Accuracy admission, required for every non-exact recipe.  Both gates must
    // pass: the analytic bound derived from the arithmetic, and the caller's
    // independently supplied (measured or proven) bound.  Neither substitutes
    // for the other - the analytic bound cannot see the data, and a measured
    // bound is only as good as its sample.
    if (arith.kind != VA_ARITH_EXACT) begin
      if (!r.accuracy_valid || !r.kappa_valid || r.kappa_q8 < 16'd256 ||
          (arith.needs_param && !r.approx_param_valid) ||
          r.error_bound_q4 > {4'd0, r.level} ||
          p.bound_ppm > p.budget_ppm)
        return p;
    end

    p.eligible = 1'b1;
    if (fallback_only) return p;

    candidate = p;
    candidate.recipe = id;
    target = r.numfmt;
    if (conversion) begin
      // Storage narrowing needs a representable range, and the integer targets
      // additionally need scale metadata.  Only FP32 sources are admitted so a
      // second narrowing of an already narrow operand cannot be requested.
      if (r.numfmt != 3'(config_pkg::AI_FMT_FP32) || !r.range_safe) return p;
      case (id)
        5'd4:  target = 3'(config_pkg::AI_FMT_FP16);
        5'd5:  target = 3'(config_pkg::AI_FMT_BF16);
        5'd7:  target = 3'(config_pkg::AI_FMT_FP8_E4M3);
        5'd29: target = 3'(config_pkg::AI_FMT_INT4);
        5'd18: target = approx_param_target(r.approx_param);
        default: target = 3'(config_pkg::AI_FMT_INT);
      endcase
      if (policy_integer_format(target) && !r.scale_valid) return p;
      if (target == 3'(config_pkg::AI_FMT_FP8_E4M3) && !r.scale_valid) return p;
      if (id == 5'd18 && !r.reuse_a_valid) return p;
      if (id inside {5'd20, 5'd29} && !r.approx_param_valid) return p;
      candidate.convert = 1'b1;
    end
    row_bytes = target == 3'(config_pkg::AI_FMT_INT4) ?
        (({3'd0, r.k} + 19'd1) >> 1) :
        ({3'd0, r.k} << (policy_element_bits_log2(target) - 3'd3));
    candidate.target_numfmt = target;
    candidate.row_bytes = row_bytes;

    if (lossless) begin
      // A lossless representation change must be proven reconstructable; a
      // sparsity or range observation is not a proof.  The packed width is the
      // caller's to establish, so no narrower row_bytes is claimed here.
      if (!policy_integer_format(r.numfmt) || !r.lossless_proven) return p;
      if (id == 5'd17 && !r.reuse_b_valid) return p;
      candidate.reuse_b = id == 5'd17;
    end else if (zero_skip) begin
      if (!policy_integer_format(r.numfmt) || !r.exact_zero_proven) return p;
      candidate.skip_products = 1'b1;
    end else if (reuse_only) begin
      if (!r.reuse_a_valid && !r.reuse_b_valid) return p;
      candidate.reuse_a = r.reuse_a_valid;
      candidate.reuse_b = r.reuse_b_valid;
    end else if (control_only) begin
      // Plan prefetch and context separation change no arithmetic and consume
      // no arithmetic resource; they still require a fresh window, which the
      // permission stage below enforces.
      candidate.groups_log2 = 3'd0;
    end else if (approx_products) begin
      // Storage width is unchanged, so these buy multiplier cost and depth and
      // never buy concurrency.  Reporting a group count here would repeat the
      // conflation the accuracy study already disproved.
      candidate.approx_products = 1'b1;
      candidate.groups_log2 = 3'd0;
    end else if (grouping || conversion) begin
      order_only   = id == 5'd14;
      separate_jobs = id inside {5'd11, 5'd12, 5'd15};
      if (!r.regular_layout || (separate_jobs && !r.independent_jobs)) return p;
      candidate.split_rows = !separate_jobs && !order_only &&
                             (r.code == POLICY_TALL || r.n == 1);
      if (id inside {5'd9, 5'd10}) candidate.split_rows = 1'b0;
      work_count = separate_jobs ? r.ready_jobs :
                   candidate.split_rows ? 9'(r.m) : 9'(r.n);
      group_limit = id == 5'd9 ? 2 : id == 5'd10 ? 4 : id == 5'd12 ? 2 : max_groups;
      for (int unsigned log_groups = 1; log_groups <= 5; log_groups++) begin
        if ((32'd1 << log_groups) <= max_groups &&
            (32'd1 << log_groups) <= group_limit &&
            (32'd1 << log_groups) <= 32'(work_count) &&
            (32'd1 << log_groups) <= 32'(r.free_accumulators) &&
            (32'd1 << log_groups) <= 32'(r.bank_groups) &&
            (lane_bytes >> log_groups) >= min_group_bytes &&
            (lane_bytes >> log_groups) >= 32'(row_bytes))
          candidate.groups_log2 = 3'(log_groups);
      end
      if (order_only) begin
        // A read-order change needs independent banks, not extra groups.
        if (r.bank_groups < 9'd2) return p;
        candidate.groups_log2 = 3'd0;
      end else begin
        if (candidate.groups_log2 == 0 && !conversion) return p;
        if (id == 5'd9 && candidate.groups_log2 != 1) return p;
        if (id == 5'd10 && candidate.groups_log2 != 2) return p;
      end
      if (r.free_accumulators == 0 || r.bank_groups == 0) return p;
      if (!separate_jobs && !order_only && candidate.groups_log2 != 0) begin
        candidate.reuse_a = !candidate.split_rows;
        candidate.reuse_b = candidate.split_rows;
        candidate.tail_outputs = 5'(work_count & ((9'd1 << candidate.groups_log2) - 9'd1));
      end
    end else begin
      return p;
    end

    if (consumer_mask[id] && r.window_valid && r.qualified_mask[id]) begin
      candidate.eligible = 1'b1;
      candidate.apply = 1'b1;
      return candidate;
    end
    return p;
  endfunction

  function automatic logic [63:0] policy_normalize_sample(
      input logic [255:0] sample, input logic [2:0] numfmt
  );
    logic [63:0] normalized;
    logic is_zero;
    for (int i = 0; i < 8; i++) begin
      case (numfmt)
        3'(config_pkg::AI_FMT_INT): is_zero = sample[i*8 +: 8] == 8'd0;
        3'(config_pkg::AI_FMT_INT4): is_zero = sample[i*4 +: 4] == 4'd0;
        3'(config_pkg::AI_FMT_FP8_E4M3), 3'(config_pkg::AI_FMT_FP8_E5M2):
          is_zero = sample[i*8 +: 7] == 7'd0;
        3'(config_pkg::AI_FMT_FP16), 3'(config_pkg::AI_FMT_BF16):
          is_zero = sample[i*16 +: 15] == 15'd0;
        3'(config_pkg::AI_FMT_FP32): is_zero = sample[i*32 +: 31] == 31'd0;
        default: is_zero = 1'b0;
      endcase
      normalized[i*8 +: 8] = is_zero ? 8'd0 : 8'd1;
    end
    return normalized;
  endfunction

  function automatic logic [2:0] policy_aligned_log2(
      input logic [15:0] dim, input logic [2:0] cap
  );
    logic [2:0] result;
    result = '0;
    for (int unsigned level = 1; level <= 4; level++) begin
      if (level <= int'(cap) && dim >= (16'd1 << level) &&
          (dim & ((16'd1 << level) - 16'd1)) == 16'd0)
        result = 3'(level);
    end
    return result;
  endfunction

  function automatic logic [3:0] policy_reuse_gain(
      input logic [2:0] row_log, col_log
  );
    logic [5:0] rows, cols, outputs;
    logic [10:0] dividend;
    rows = 6'd1 << row_log;
    cols = 6'd1 << col_log;
    outputs = 6'd1 << (int'(row_log) + int'(col_log));
    dividend = (({5'd0, outputs} << 1) - {5'd0, rows} - {5'd0, cols}) << 4;
    return 4'(dividend >> (int'(row_log) + int'(col_log) + 1));
  endfunction

  function automatic logic [63:0] policy_rowbytes(
      input logic [15:0] k,
      input logic [2:0] numfmt
  );
    logic [2:0] bits;
    logic [63:0] num;
    bits = policy_element_bits_log2(numfmt);
    num = 64'(k) * (64'd1 << bits);
    return (num + 64'd7) >> 3;
  endfunction

  function automatic policy_topology_t policy_topology(
      input policy_code_t code,
      input logic [2:0] numfmt,
      input logic [15:0] m, n, k,
      input logic [1:0] balance,
      input int unsigned read_bytes,
      input int unsigned min_gain,
      input logic [31:0] slots
  );
    policy_topology_t t;
    logic [2:0] row_cap, col_cap, row_log, col_log;
    logic [2:0] row_max, col_max, balanced_row, balanced_col;
    logic [3:0] gain, balanced_gain, group_log;
    logic [15:0] active_k;
    logic [63:0] base_step;
    logic underfilled;
    logic balance_ok;
    t = '0;
    if (!policy_format_known(numfmt) || m == 16'd0 || n == 16'd0 || k == 16'd0 ||
        slots[numfmt*4 +: 4] == 4'd0 || slots[numfmt*4 +: 4] > 4'd9)
      return t;
    t.valid = 1'b1;
    t.slots_log2 = slots[numfmt*4 +: 4];
    t.reduction_log2 = t.slots_log2;
    t.element_bits_log2 = policy_element_bits_log2(numfmt);
    row_cap = '0;
    col_cap = '0;
    case (code)
      POLICY_BULK, POLICY_ATTENTION, POLICY_SPARSE: begin
        row_cap = 3'd2;
        col_cap = 3'd2;
      end
      POLICY_WIDE: begin
        row_cap = 3'd1;
        col_cap = 3'd3;
      end
      POLICY_TALL: begin
        row_cap = 3'd3;
        col_cap = 3'd1;
      end
      POLICY_DECODE: col_cap = 3'd4;
      POLICY_ROUTED: begin
        row_cap = 3'd1;
        col_cap = 3'd2;
      end
      default: begin end
    endcase
    row_log = policy_aligned_log2(m, row_cap);
    col_log = policy_aligned_log2(n, col_cap);
    if (int'(row_log) > int'(t.slots_log2)) row_log = 3'(t.slots_log2);
    if (int'(row_log) + int'(col_log) > int'(t.slots_log2))
      col_log = 3'(t.slots_log2 - {1'b0, row_log});
    gain = policy_reuse_gain(row_log, col_log);
    row_max = policy_aligned_log2(m, 3'd4);
    col_max = policy_aligned_log2(n, 3'd4);
    group_log = {1'b0, row_max} + {1'b0, col_max};
    if (group_log > 4'd4) group_log = 4'd4;
    if (group_log > t.slots_log2) group_log = t.slots_log2;
    balanced_row = 3'(group_log >> 1);
    if (balanced_row > row_max) balanced_row = row_max;
    balanced_col = 3'(group_log - {1'b0, balanced_row});
    if (balanced_col > col_max) begin
      balanced_col = col_max;
      balanced_row = 3'(group_log - {1'b0, balanced_col});
    end
    balanced_gain = policy_reuse_gain(balanced_row, balanced_col);
    if (balanced_gain > gain || (balanced_gain == gain &&
        int'(group_log) > int'(row_log) + int'(col_log))) begin
      row_log = balanced_row;
      col_log = balanced_col;
      gain = balanced_gain;
    end

    active_k = (k < (16'd1 << t.slots_log2)) ? k : (16'd1 << t.slots_log2);
    base_step = (64'(m) + 64'(n)) * policy_rowbytes(active_k, numfmt);
    underfilled = k <= (16'd1 << (int'(t.slots_log2) - 1));

    balance_ok = balance != 2'd0 || (code == POLICY_DECODE);
    if (code != POLICY_MOVEMENT && balance_ok && (row_log != 3'd0 || col_log != 3'd0) &&
        (m >= 16'd8 || n >= 16'd8) && int'(gain) >= min_gain &&
        (underfilled || base_step >= 64'(read_bytes))) begin
      t.apply = 1'b1;
      t.rows_log2 = row_log;
      t.cols_log2 = col_log;
      t.reduction_log2 = 4'(int'(t.slots_log2) - int'(row_log) - int'(col_log));
      t.gain_16ths = gain;
    end
    return t;
  endfunction

  function automatic logic [1:0] policy_bucket(input logic [15:0] dim);
    if (dim <= 16'd1) return 2'd0;
    if (dim <= 16'd8) return 2'd1;
    if (dim <= 16'd64) return 2'd2;
    return 2'd3;
  endfunction

  function automatic logic policy_sparse_residue(input logic [63:0] sample);
    logic [7:0] zero_byte;
    logic [1:0] pair0, pair1, pair2, pair3;
    logic [2:0] half0, half1;
    logic [3:0] count;
    for (int i = 0; i < 8; i++) zero_byte[i] = (sample[i*8 +: 8] == 8'd0);
    pair0 = {1'b0, zero_byte[0]} + {1'b0, zero_byte[1]};
    pair1 = {1'b0, zero_byte[2]} + {1'b0, zero_byte[3]};
    pair2 = {1'b0, zero_byte[4]} + {1'b0, zero_byte[5]};
    pair3 = {1'b0, zero_byte[6]} + {1'b0, zero_byte[7]};
    half0 = {1'b0, pair0} + {1'b0, pair1};
    half1 = {1'b0, pair2} + {1'b0, pair3};
    count = {1'b0, half0} + {1'b0, half1};
    return count >= 4'd6;
  endfunction

  function automatic policy_code_t policy_encode(input policy_features_t f);
    if (!f.shape_valid || f.opcode >= 3'd4) return POLICY_MOVEMENT;
    if (f.opcode == 3'd1) return POLICY_ATTENTION;
    if (f.opcode == 3'd2) return POLICY_ROUTED;
    if (f.m <= 2'd1 && f.n >= 2'd2 && f.k >= 2'd2) return POLICY_DECODE;
    if (f.sparse && f.continuous && f.balance == 2'd2 && f.m >= 2'd2)
      return POLICY_SPARSE;
    if (f.balance == 2'd0) return POLICY_MOVEMENT;
    if (f.n > f.m) return POLICY_WIDE;
    if (f.m > f.n) return POLICY_TALL;
    return POLICY_BULK;
  endfunction

  function automatic policy_code_t policy_successor(input policy_code_t code);
    case (code)
      POLICY_BULK:      return POLICY_ATTENTION;
      POLICY_WIDE:      return POLICY_BULK;
      POLICY_TALL:      return POLICY_WIDE;
      POLICY_DECODE:    return POLICY_DECODE;
      POLICY_ATTENTION: return POLICY_WIDE;
      POLICY_ROUTED:    return POLICY_DECODE;
      POLICY_SPARSE:    return POLICY_WIDE;
      default:          return POLICY_BULK;
    endcase
  endfunction

  function automatic policy_t policy_decode(input policy_code_t code);
    case (code)
      POLICY_BULK:      return {2'd0, 4'd6, 4'd6, 4'd6, 1'b0, 2'd2};
      POLICY_WIDE:      return {2'd1, 4'd4, 4'd8, 4'd6, 1'b0, 2'd3};
      POLICY_TALL:      return {2'd2, 4'd8, 4'd4, 4'd6, 1'b0, 2'd2};
      POLICY_DECODE:    return {2'd2, 4'd0, 4'd7, 4'd8, 1'b0, 2'd1};
      POLICY_ATTENTION: return {2'd0, 4'd5, 4'd5, 4'd6, 1'b0, 2'd2};
      POLICY_ROUTED:    return {2'd2, 4'd3, 4'd5, 4'd7, 1'b0, 2'd1};
      POLICY_SPARSE:    return {2'd1, 4'd5, 4'd6, 4'd7, 1'b1, 2'd1};
      default:          return {2'd3, 4'd3, 4'd6, 4'd3, 1'b0, 2'd3};
    endcase
  endfunction
endpackage
