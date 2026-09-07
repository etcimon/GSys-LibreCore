// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon

module tb_g6lc_ai_policy_subcode #(
  parameter bit CacheEn = 1'b0,
  parameter int unsigned ReadBytesPerCycle = 128,
  parameter int unsigned MinSavingsCycles = 2,
  parameter int unsigned SwitchCycles = 2,
  parameter logic [31:0] FormatStepCycles = 32'h11111111,
  parameter logic [31:0] FormatMinReductionLog2 = 32'h00000000,
  parameter logic [23:0] GroupShapeLog2 = 24'h4420ca
) (
  input logic clk_i, rst_ni, testmode_i, enable_i, flush_i, cancel_i, start_i,
  input logic [2:0] code_i, numfmt_i,
  input logic [15:0] m_i, n_i, k_i,
  input logic [1:0] balance_i,
  input logic baseline_override_i,
  input g6lc_ai_policy_pkg::policy_topology_t baseline_i,
  output g6lc_ai_policy_pkg::policy_topology_t baseline_o,
  output logic ready_o, busy_o, valid_o, evaluated_o,
  output logic [2:0] subcode_o,
  output g6lc_ai_policy_pkg::policy_topology_t topology_o,
  output logic [31:0] baseline_cycles_o, selected_cycles_o,
  output logic disabled_nonzero_o, cache_enabled_o, cache_hit_o,
  output logic [31:0] read_bytes_o, min_savings_o, switch_cycles_o,
  output logic [31:0] format_steps_o, format_min_reduction_o,
  output logic [23:0] group_shapes_o,
  input logic steer_enable_i, steer_flush_i, steer_valid_i,
  input logic steer_batch_first_i, steer_batch_last_i,
  input logic [15:0] steer_m_i, steer_n_i, steer_k_i,
  input logic [2:0] steer_opcode_i, steer_numfmt_i,
  input logic [1:0] steer_balance_i,
  input logic [255:0] steer_sample_i,
  input logic steer_sample_valid_i, steer_exact_zero_i,
  input logic [63:0] steer_next_addr_i,
  input logic steer_next_addr_valid_i, steer_mispredict_i,
  output logic steer_ready_o, steer_work_valid_o,
  output logic [2:0] steer_code_o, steer_numfmt_o,
  output g6lc_ai_policy_pkg::policy_topology_t steer_topology_o,
  output logic steer_legacy_mismatch_o, steer_disabled_nonzero_o,
  output logic steer_subcode_valid_o, steer_subcode_evaluated_o, steer_subcode_cache_hit_o,
  output logic [2:0] steer_subcode_o,
  output g6lc_ai_policy_pkg::policy_topology_t steer_subcode_topology_o,
  output logic [31:0] steer_baseline_cycles_o, steer_selected_cycles_o
);
  import g6lc_ai_policy_pkg::*;

  assign baseline_o = baseline_override_i ? baseline_i : policy_topology(
      policy_code_t'(code_i), numfmt_i, m_i, n_i, k_i, balance_i,
      ReadBytesPerCycle, 2, 32'h67788098);
  assign cache_enabled_o = CacheEn;
  assign read_bytes_o = ReadBytesPerCycle;
  assign min_savings_o = MinSavingsCycles;
  assign switch_cycles_o = SwitchCycles;
  assign format_steps_o = FormatStepCycles;
  assign format_min_reduction_o = FormatMinReductionLog2;
  assign group_shapes_o = GroupShapeLog2;

  task automatic va_eps_rational_checks();
    logic [63:0] unit_den, numerator, denominator, expected;
    logic [19:0] actual;
    for (int bits = 0; bits <= 23; bits++) begin
      unit_den = 64'd1 << (bits + 1);
      numerator = 64'd1000000 * (64'd2 * unit_den + 64'd1);
      denominator = unit_den * unit_den;
      expected = (numerator + denominator - 64'd1) / denominator;
      if (expected > 64'd1000000) expected = 64'hfffff;
      actual = va_turbo_round_eps_ppm(5'(bits));
      assert (64'(actual) == expected)
        else $fatal(1, "VA RNE rational p=%0d got=%0d expected=%0d", bits, actual, expected);
      unit_den = 64'd1 << bits;
      numerator = 64'd1000000 * (64'd2 * unit_den - 64'd1);
      denominator = unit_den * unit_den;
      expected = (numerator + denominator - 64'd1) / denominator;
      actual = va_turbo_trunc_eps_ppm(5'(bits));
      assert (64'(actual) == expected)
        else $fatal(1, "VA trunc rational p=%0d got=%0d expected=%0d", bits, actual, expected);
    end
    for (int bits = 24; bits <= 31; bits++) begin
      assert (va_turbo_round_eps_ppm(5'(bits)) == 20'hfffff)
        else $fatal(1, "VA RNE invalid precision p=%0d", bits);
      assert (va_turbo_trunc_eps_ppm(5'(bits)) == 20'hfffff)
        else $fatal(1, "VA trunc invalid precision p=%0d", bits);
    end
    for (int levels = 0; levels <= 255; levels++) begin
      if (levels inside {7, 127}) begin
        for (int flat = 0; flat <= 512; flat++) begin
          numerator = 64'd1000000 * (64'(flat) * 64'd2 * 64'(levels) + 64'd256);
          denominator = 64'd1024 * 64'(levels) * 64'(levels);
          expected = (numerator + denominator - 64'd1) / denominator;
          actual = va_turbo_quant_eps_ppm(8'(levels), 10'(flat));
          assert (64'(actual) >= expected && actual <= 20'd1000000)
            else $fatal(1, "VA quant rational levels=%0d flat=%0d", levels, flat);
        end
      end else
        assert (va_turbo_quant_eps_ppm(8'(levels), 10'd512) == 20'hfffff)
          else $fatal(1, "VA invalid quant level count=%0d", levels);
    end
    $display("VA_EPS_RATIONAL PASS rne_p=0..31 trunc_p=0..31 quant_levels=0..255 oracle_bits=64");
  endtask

  task automatic va_bound_rational_checks();
    va_turbo_arith_t a;
    logic [63:0] product, expected;
    logic [19:0] actual;
    a = '0;
    a.kind = VA_ARITH_REL;
    for (int sample_id = 0; sample_id < 12; sample_id++) begin
      case (sample_id)
        0: a.eps_ppm = 20'd1;
        1: a.eps_ppm = 20'd2;
        2: a.eps_ppm = 20'd16;
        3: a.eps_ppm = 20'd31;
        4: a.eps_ppm = 20'd489;
        5: a.eps_ppm = 20'd977;
        6: a.eps_ppm = 20'd7828;
        7: a.eps_ppm = 20'd250000;
        8: a.eps_ppm = 20'd999999;
        9: a.eps_ppm = 20'd1000000;
        10: a.eps_ppm = 20'd1000001;
        default: a.eps_ppm = 20'hfffff;
      endcase
      for (int kq = 0; kq <= 65535; kq++) begin
        product = 64'(a.eps_ppm) * 64'(kq);
        expected = product / 64'd256 + 64'((product % 64'd256) != 0);
        if (kq < 256 || a.eps_ppm > 20'd1000000 || expected > 64'd1000000)
          expected = 64'hfffff;
        actual = va_turbo_bound_ppm(a, 16'(kq));
        assert (64'(actual) == expected)
          else $fatal(1, "VA composition eps=%0d kq=%0d got=%0d expected=%0d",
                      a.eps_ppm, kq, actual, expected);
      end
    end
    a.eps_ppm = 20'd1;
    assert (va_turbo_bound_ppm(a, 16'd257) == 20'd2)
      else $fatal(1, "VA fractional ppm must round upward");
    a.eps_ppm = 20'd250000;
    assert (va_turbo_bound_ppm(a, 16'd1024) == 20'd1000000 &&
            va_turbo_bound_ppm(a, 16'd1025) == 20'hfffff)
      else $fatal(1, "VA numeric maximum and overflow must differ");
    a.kind = VA_ARITH_NONE; a.eps_ppm = 20'd0;
    assert (va_turbo_bound_ppm(a, 16'd256) == 20'hfffff)
      else $fatal(1, "VA NONE must be INVALID even with zero epsilon");
    a.kind = VA_ARITH_EXACT;
    assert (va_turbo_bound_ppm(a, 16'd0) == 20'd0)
      else $fatal(1, "VA exact requires no kappa");
    $display("VA_BOUND_RATIONAL PASS eps_cases=12 kappa_q8=0..65535 oracle_bits=64");
  endtask

  // The moving-window bound.  Two properties matter more than the arithmetic:
  // the window a caller claims must be the one the datapath actually reduces
  // exactly before rounding, and a window can only ever make the reported
  // bound tighter, never looser.
  task automatic va_window_bound_checks();
    va_turbo_arith_t a;
    logic [63:0] product, expected;
    logic [19:0] actual;
    int unsigned checks;
    a = '0;
    a.kind = VA_ARITH_REL;
    checks = 0;
    // The datapath's window is lanes/element_bytes, doubled for INT4.  Anything
    // else is a claim the hardware cannot honour.
    for (int lanes_log = 3; lanes_log <= 8; lanes_log++) begin
      assert (va_turbo_pow2_log2(32'd1 << lanes_log) == 5'(lanes_log))
        else $fatal(1, "VA pow2 log2 lanes_log=%0d", lanes_log);
      assert (va_turbo_window_log2(3'(config_pkg::AI_FMT_INT), 5'(lanes_log)) == 5'(lanes_log))
        else $fatal(1, "VA INT8 window must equal the lane count");
      assert (va_turbo_window_log2(3'(config_pkg::AI_FMT_INT4), 5'(lanes_log)) == 5'(lanes_log + 1))
        else $fatal(1, "VA INT4 window packs two per byte");
      assert (va_turbo_window_log2(3'(config_pkg::AI_FMT_FP16), 5'(lanes_log)) == 5'(lanes_log - 1))
        else $fatal(1, "VA FP16 window halves with element bytes");
      assert (va_turbo_window_log2(3'(config_pkg::AI_FMT_FP32), 5'(lanes_log)) == 5'(lanes_log - 2))
        else $fatal(1, "VA FP32 window quarters with element bytes");
    end
    assert (va_turbo_pow2_log2(32'd0) == 5'd0 && va_turbo_pow2_log2(32'd3) == 5'd0 &&
            va_turbo_pow2_log2(32'd1000) == 5'd0)
      else $fatal(1, "VA pow2 log2 must reject non-powers of two");
    // Rounding sites: W block-float conversions plus W-1 accumulator folds.
    for (int window_log = 1; window_log <= 5; window_log++) begin
      for (int k = 1; k <= 256; k++) begin
        logic [16:0] windows;
        windows = (17'(k) + (17'd1 << window_log) - 17'd1) >> window_log;
        expected = windows > 17'd32 ? 64'd63 : (64'(windows) * 64'd2) - 64'd1;
        assert (64'(va_turbo_accum_sites(16'(k), 5'(window_log))) == expected)
          else $fatal(1, "VA accum sites k=%0d window_log=%0d", k, window_log);
        checks++;
      end
    end
    assert (va_turbo_accum_sites(16'd0, 5'd3) == 6'd0 &&
            va_turbo_accum_sites(16'd16, 5'd0) == 6'd0)
      else $fatal(1, "VA accum sites must be zero without work or a window");
    // The accumulation term and the additive total, against a rational oracle.
    for (int sites = 0; sites <= 63; sites++) begin
      for (int kq = 0; kq <= 1024; kq++) begin
        product = 64'(sites) * 64'(kq);
        expected = (kq < 256 || sites == 0)
            ? 64'd0 : product / 64'd256 + 64'((product % 64'd256) != 0);
        if (expected > 64'd1000000) expected = 64'hfffff;
        actual = va_turbo_accum_bound_ppm(16'(kq), 6'(sites));
        assert (64'(actual) == expected)
          else $fatal(1, "VA accum bound sites=%0d kq=%0d got=%0d expected=%0d",
                      sites, kq, actual, expected);
        checks++;
      end
    end
    for (int p_case = 0; p_case < 4; p_case++) begin
      for (int a_case = 0; a_case < 3; a_case++) begin
        for (int f_case = 0; f_case < 3; f_case++) begin
          logic [19:0] pp, ap, fp;
          pp = p_case == 0 ? 20'd0 : p_case == 1 ? 20'd7828 :
               p_case == 2 ? 20'd1000000 : 20'd1000001;
          ap = a_case == 0 ? 20'd0 : a_case == 1 ? 20'd6 : 20'd1000001;
          fp = f_case == 0 ? 20'd0 : f_case == 1 ? 20'd59737 : 20'd1000001;
          expected = 64'(pp) + 64'(ap) + 64'(fp);
          if (pp > 20'd1000000 || ap > 20'd1000000 || fp > 20'd1000000 ||
              expected > 64'd1000000)
            expected = 64'hfffff;
          actual = va_turbo_total_bound_ppm(pp, ap, fp);
          assert (64'(actual) == expected)
            else $fatal(1, "VA total bound %0d+%0d+%0d got=%0d expected=%0d",
                        pp, ap, fp, actual, expected);
          // Adding terms must never reduce the bound.
          assert (actual == 20'hfffff || actual >= pp)
            else $fatal(1, "VA total bound must never fall below the product term");
          checks++;
        end
      end
    end
    $display("VA_WINDOW_BOUND PASS lanes_log=3..8 sites_k=1..256 accum_kappa=0..1024 totals=36 checks=%0d",
             checks);
  endtask

  // A windowed bound must be earned: matched window, valid windowed kappa, and
  // it may only replace the element-level number by being smaller.
  task automatic va_window_admission_checks();
    config_pkg::ai_cfg_t cfg;
    va_turbo_request_t r;
    va_turbo_plan_t p, element_only;
    cfg = config_pkg::AiCfgOff;
    cfg.VaTurboEn = 1'b1; cfg.MatrixEn = 1'b1; cfg.Queues = 1;
    cfg.PolicyCodecEn = 1'b1; cfg.PolicyBenefitEn = 1'b1;
    cfg.PolicySubcodeEn = 1'b1; cfg.IslandFpEn = 1'b1;
    r = '0;
    r.enable = 1'b1; r.code = POLICY_BULK;
    r.numfmt = 3'(config_pkg::AI_FMT_FP32);
    r.m = 16'd16; r.n = 16'd16; r.k = 16'd16;
    r.regular_layout = 1'b1; r.ready_jobs = 9'd16;
    r.free_accumulators = 9'd16; r.bank_groups = 9'd16;
    r.range_safe = 1'b1; r.scale_valid = 1'b1; r.accuracy_valid = 1'b1;
    r.relative_domain_valid = 1'b1;
    r.kappa_valid = 1'b1; r.kappa_q8 = 16'd65535;   // element level: vacuous
    r.approx_param_valid = 1'b1; r.approx_param = 4'd10;
    r.window_valid = 1'b1; r.qualified_mask = '1;
    r.bank = 2'd2; r.subcode = 3'd5;                 // recipe 21, REL, truncation
    r.level = 4'd15;
    r.kappa_q8 = 16'd300;                            // finite, so terms are visible
    element_only = va_turbo_select(cfg, r, 64, 8, 8, '1);
    // 64-byte lanes with FP32 gives a 16-element window.
    assert (element_only.window_log2 == 5'd4)
      else $fatal(1, "VA reported window must follow lanes and format, got %0d",
                  element_only.window_log2);
    assert (!element_only.window_matched && element_only.bound_accum_ppm == 20'd0)
      else $fatal(1, "VA unclaimed window must not be matched or charged");
    // Right kappa, WRONG window: refused as a window claim, so no accumulation
    // term is added.  This is the guard against a window the hardware does not
    // implement -- which for these recipes would UNDER-state the bound, since
    // the per-product term is the one that matters.
    r.kappa_window_valid = 1'b1; r.kappa_window_q8 = 16'd512;
    for (int bad = 0; bad <= 8; bad++) begin
      if (5'(bad) != 5'd4) begin
        r.window_log2 = 5'(bad);
        p = va_turbo_select(cfg, r, 64, 8, 8, '1);
        assert (!p.window_matched && p.bound_ppm == element_only.bound_ppm &&
                p.bound_accum_ppm == 20'd0)
          else $fatal(1, "VA mismatched window_log2=%0d must not be charged", bad);
      end
    end
    // Matched window: the accumulation term is ADDED, never substituted.  A
    // windowed kappa cannot buy a tighter bound, because every non-exact recipe
    // here perturbs the product BEFORE the exact reduction, and substituting a
    // windowed kappa for those is measurably unsound (INT8 violates by 5.8x).
    r.window_log2 = 5'd4;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.window_matched && p.bound_accum_ppm > 20'd0 &&
            p.bound_ppm == element_only.bound_ppm + p.bound_accum_ppm)
      else $fatal(1, "VA matched window must ADD its term: total=%0d element=%0d accum=%0d",
                  p.bound_ppm, element_only.bound_ppm, p.bound_accum_ppm);
    assert (p.bound_ppm >= element_only.bound_ppm)
      else $fatal(1, "VA window must never reduce the reported bound");
    // A windowed kappa below one rounding is not evidence.
    r.kappa_window_q8 = 16'd255;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.window_matched && p.bound_ppm == element_only.bound_ppm)
      else $fatal(1, "VA sub-unity windowed kappa must be refused");
    // A larger windowed kappa may only ever cost more, never less.
    r.kappa_window_q8 = 16'd1024;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.bound_ppm > element_only.bound_ppm)
      else $fatal(1, "VA larger windowed kappa must cost more");
    // The floor only ever adds, and it is reported separately.
    r.kappa_window_q8 = 16'd512;
    r.abs_floor_valid = 1'b1; r.abs_floor_ppm = 20'd1000;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.bound_floor_ppm == 20'd1000 &&
            p.bound_ppm == element_only.bound_ppm + p.bound_accum_ppm + 20'd1000)
      else $fatal(1, "VA floor term must add exactly");
    // Out-of-range floor is ignored rather than trusted.
    r.abs_floor_ppm = 20'd1000001;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.bound_floor_ppm == 20'd0)
      else $fatal(1, "VA out-of-range floor must be ignored, not applied");
    r.abs_floor_ppm = 20'd1000;
    // The subnormal-domain admission: no relative domain, but a floor plus a
    // matched window is now sufficient, and without the floor it is refused.
    r.abs_floor_valid = 1'b0; r.relative_domain_valid = 1'b0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply && !p.eligible)
      else $fatal(1, "VA REL without domain or floor must stay refused");
    r.abs_floor_valid = 1'b1; r.abs_floor_ppm = 20'd1000;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && p.window_matched)
      else $fatal(1, "VA floor plus matched window must admit a subnormal REL");
    // ...but a floor WITHOUT a matched window must not, because then the floor
    // was never added to the reported bound.
    r.window_log2 = 5'd2;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply && !p.eligible)
      else $fatal(1, "VA floor without a matched window must not admit");
    $display("VA_WINDOW_ADMISSION PASS window=4 mismatches=8 floor_cases=4 subnormal_admission=1");
  endtask

  task automatic va_admission_boundary_checks();
    config_pkg::ai_cfg_t cfg;
    va_turbo_request_t r;
    va_turbo_plan_t p;
    va_turbo_arith_t a;
    int unsigned checks;
    cfg = config_pkg::AiCfgOff;
    cfg.VaTurboEn = 1'b1; cfg.MatrixEn = 1'b1; cfg.Queues = 1;
    cfg.PolicyCodecEn = 1'b1; cfg.PolicyBenefitEn = 1'b1;
    cfg.PolicySubcodeEn = 1'b1; cfg.IslandFpEn = 1'b1;
    r = '0;
    r.enable = 1'b1; r.code = POLICY_BULK;
    r.numfmt = 3'(config_pkg::AI_FMT_FP32);
    r.m = 16'd16; r.n = 16'd16; r.k = 16'd16;
    r.regular_layout = 1'b1; r.ready_jobs = 9'd16;
    r.free_accumulators = 9'd16; r.bank_groups = 9'd16;
    r.range_safe = 1'b1; r.scale_valid = 1'b1; r.accuracy_valid = 1'b1;
    r.kappa_valid = 1'b1; r.kappa_q8 = 16'd412;
    r.approx_param_valid = 1'b1; r.approx_param = 4'd15;
    r.window_valid = 1'b1; r.qualified_mask = '1;
    r.reuse_a_valid = 1'b1;
    r.bank = 2'd3; r.subcode = 3'd1; r.level = 4'd1;
    assert (!r.relative_domain_valid) else $fatal(1, "VA REL domain must default false");
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply && !p.eligible) else $fatal(1, "VA REL requires normal-domain evidence");
    r.worst_case_waived = 1'b1;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply && !p.bound_waived) else $fatal(1, "VA waiver must not bypass REL domain");
    r.relative_domain_valid = 1'b1; r.worst_case_waived = 1'b0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && p.eps_ppm == 20'd62 && p.bound_ppm == 20'd100 && !p.bound_waived)
      else $fatal(1, "VA upward-rounded budget equality");
    r.kappa_q8 = 16'd413;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply && !p.eligible && p.bound_ppm == 20'd101)
      else $fatal(1, "VA fractional excess must fail the 100 ppm budget");
    r.worst_case_waived = 1'b1;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && p.bound_waived && p.bound_ppm == 20'd101)
      else $fatal(1, "VA finite overbudget waiver remains available");
    r.kappa_q8 = 16'd412;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && !p.bound_waived) else $fatal(1, "VA unnecessary waiver must stay clear");
    checks = 0;
    r.level = 4'd15; r.kappa_q8 = 16'd256; r.approx_param = 4'd10;
    for (int id = 0; id < 32; id++) begin
      r.bank = 2'(id >> 3); r.subcode = 3'(id);
      a = va_turbo_arith(5'(id), r.numfmt, r.approx_param, 10'd512);
      if (a.kind != VA_ARITH_EXACT && a.kind != VA_ARITH_NONE) begin
        r.range_safe = 1'b0; r.relative_domain_valid = 1'b1;
        p = va_turbo_select(cfg, r, 64, 8, 8, '1);
        assert (!p.apply && !p.eligible && !p.bound_waived)
          else $fatal(1, "VA non-exact range prerequisite id=%0d", id);
        r.range_safe = 1'b1; r.relative_domain_valid = 1'b0;
        p = va_turbo_select(cfg, r, 64, 8, 8, '1);
        if (a.kind == VA_ARITH_REL)
          assert (!p.apply && !p.eligible && !p.bound_waived)
            else $fatal(1, "VA REL domain prerequisite id=%0d", id);
        else
          assert (p.apply) else $fatal(1, "VA FULL must not need the REL domain id=%0d", id);
        r.relative_domain_valid = 1'b1;
        for (int missing = 0; missing < 3; missing++) begin
          r.kappa_valid = missing != 0;
          r.kappa_q8 = missing == 2 ? 16'd255 : 16'd0;
          p = va_turbo_select(cfg, r, 64, 8, 8, '1);
          assert (!p.apply && !p.bound_waived && p.bound_ppm == 20'hfffff)
            else $fatal(1, "VA invalid/missing kappa must preserve INVALID id=%0d", id);
          checks++;
        end
        r.kappa_valid = 1'b1; r.kappa_q8 = 16'd256;
      end
    end
    for (int id = 0; id < 32; id++) begin
      if (id inside {21, 25, 30, 31}) begin
        r.bank = 2'(id >> 3); r.subcode = 3'(id);
        for (int par = 0; par < 16; par++) begin
          r.approx_param = 4'(par);
          p = va_turbo_select(cfg, r, 64, 8, 8, '1);
          assert (p.apply && p.approx_products && !p.convert && p.groups_log2 == 0 &&
                  p.eps_ppm == va_turbo_trunc_eps_ppm(5'(par)) && !p.bound_waived)
            else $fatal(1, "VA truncation mapping id=%0d p=%0d", id, par);
          checks++;
        end
        r.approx_param_valid = 1'b0;
        p = va_turbo_select(cfg, r, 64, 8, 8, '1);
        assert (!p.apply) else $fatal(1, "VA truncation missing parameter id=%0d", id);
        r.approx_param_valid = 1'b1;
      end
    end
    r.bank = 2'd3; r.subcode = 3'd3;
    r.kappa_q8 = 16'd1024;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && p.bound_ppm == 20'd1000000 && !p.bound_waived)
      else $fatal(1, "VA genuine 100 percent bound remains numeric");
    for (int waive = 0; waive <= 1; waive++) begin
      r.worst_case_waived = 1'(waive);
      for (int kcase = 0; kcase < 2; kcase++) begin
        r.kappa_q8 = kcase == 0 ? 16'd1025 : 16'd65535;
        p = va_turbo_select(cfg, r, 64, 8, 8, '1);
        assert (!p.apply && !p.eligible && !p.bound_waived && p.bound_ppm == 20'hfffff &&
                p.recipe == 0 && p.target_numfmt == r.numfmt && !p.approx_products)
          else $fatal(1, "VA max-budget overflow cannot be waived kq=%0d", r.kappa_q8);
        checks++;
      end
    end
    r.subcode = 3'd2; r.kappa_q8 = 16'd256;
    for (int fmt = 0; fmt < 8; fmt++) begin
      r.numfmt = 3'(fmt);
      for (int par = 0; par < 16; par++) begin
        r.approx_param = 4'(par);
        for (int waive = 0; waive <= 1; waive++) begin
          r.worst_case_waived = 1'(waive);
          p = va_turbo_select(cfg, r, 64, 8, 8, '1);
          assert (p.supported && p.arith_specified && p.eps_ppm == 20'hfffff &&
                  p.bound_ppm == 20'hfffff && !p.apply && !p.eligible && !p.bound_waived)
            else $fatal(1, "VA block exponent has no valid derivation fmt=%0d par=%0d", fmt, par);
          checks++;
        end
      end
    end
    r.bank = 2'd1; r.subcode = 3'd1; r.numfmt = 3'(config_pkg::AI_FMT_INT);
    r.range_safe = 1'b0; r.relative_domain_valid = 1'b0;
    r.accuracy_valid = 1'b0; r.kappa_valid = 1'b0; r.approx_param_valid = 1'b0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && p.bound_ppm == 0 && !p.bound_waived)
      else $fatal(1, "VA exact path must not require non-exact prerequisites");
    $display("VA_ADMISSION_BOUNDARIES PASS checks=%0d sentinel=1048575 domain_default=0", checks);
  endtask

  initial begin : va_heuristic_checks
    config_pkg::ai_cfg_t cfg;
    va_turbo_request_t r;
    va_turbo_plan_t p;
    int unsigned bytes_per_row, expected_groups, checks;
    cfg = config_pkg::AiCfgOff;
    cfg.VaTurboEn = 1'b1;
    cfg.MatrixEn = 1'b1;
    cfg.Queues = 1;
    cfg.PolicyCodecEn = 1'b1;
    cfg.PolicyBenefitEn = 1'b1;
    cfg.PolicySubcodeEn = 1'b1;
    cfg.IslandFpEn = 1'b1;
    r = '0;
    r.enable = 1'b1;
    r.level = 4'd15;
    r.bank = 2'd1;
    r.subcode = 3'd5;
    r.code = POLICY_BULK;
    r.m = 16'd16;
    r.n = 16'd16;
    r.regular_layout = 1'b1;
    r.ready_jobs = 9'd16;
    r.free_accumulators = 9'd16;
    r.bank_groups = 9'd16;
    r.qualified_mask = '1;
    r.window_valid = 1'b1;
    checks = 0;
    for (int fmt = 0; fmt < 8; fmt++) begin
      r.numfmt = 3'(fmt);
      for (int k = 1; k <= 256; k++) begin
        r.k = 16'(k);
        bytes_per_row = (k * (fmt == 1 ? 4 : fmt == 5 || fmt == 6 ? 16 : fmt == 7 ? 32 : 8) + 7) / 8;
        for (int bank_cap = 0; bank_cap <= 8; bank_cap++) begin
          r.bank_groups = 9'(bank_cap);
          p = va_turbo_select(cfg, r, 64, 8, 8, 32'hffffffff);
          expected_groups = 1;
          for (int g = 2; g <= 8; g *= 2)
            if (fmt != 2 && bytes_per_row <= 64/g && 8 <= 64/g && g <= bank_cap)
              expected_groups = g;
          assert (p.apply == (expected_groups > 1) &&
                  (1 << p.groups_log2) == expected_groups)
            else $fatal(1, "VA group capacity fmt=%0d k=%0d banks=%0d", fmt, k, bank_cap);
          if (p.apply)
            assert (p.reuse_a && !p.reuse_b && !p.convert && p.target_numfmt == r.numfmt)
              else $fatal(1, "VA exact grouping changed arithmetic");
          checks++;
        end
      end
    end
    r.numfmt = 3'd1; r.k = 16'd17; r.bank_groups = 9'd8;
    r.code = POLICY_TALL; r.m = 16'd3; r.n = 16'd1;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && p.groups_log2 == 1 && p.tail_outputs == 1 &&
            p.split_rows && p.reuse_b && !p.reuse_a)
      else $fatal(1, "VA tall odd-tail grouping");
    r.bank = 1; r.subcode = 3; r.independent_jobs = 1;
    for (int jobs = 0; jobs <= 8; jobs++) begin
      r.ready_jobs = 9'(jobs);
      r.free_accumulators = 9'd3;
      p = va_turbo_select(cfg, r, 64, 8, 8, '1);
      assert (p.apply == (jobs >= 2) && p.groups_log2 == (jobs >= 2 ? 1 : 0))
        else $fatal(1, "VA independent-job/accumulator bound");
      checks++;
    end
    r.m = 16; r.n = 16; r.k = 16; r.code = POLICY_BULK;
    r.numfmt = 7; r.bank = 0; r.subcode = 4;
    r.free_accumulators = 8; r.ready_jobs = 8; r.bank_groups = 8;
    // FP16 needs 977 ppm, which on the geometric ladder is level 5 (1,600 ppm).
    r.range_safe = 1; r.accuracy_valid = 1; r.error_bound_q4 = 3; r.level = 5;
    r.relative_domain_valid = 1'b1;
    // Conversions now also carry the analytic bound, so kappa is mandatory.
    r.kappa_valid = 1'b1; r.kappa_q8 = 16'd256;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && p.convert && p.target_numfmt == 5 && p.groups_log2 == 1 && p.row_bytes == 32)
      else $fatal(1, "VA FP16 bound equality");
    r.level = 4'd4;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply) else $fatal(1, "VA FP16 must not fit an 800 ppm budget");
    r.level = 4'd5; r.error_bound_q4 = 6;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply && p.target_numfmt == 7 && !p.convert) else $fatal(1, "VA excessive error");
    r.error_bound_q4 = 1; r.accuracy_valid = 0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply) else $fatal(1, "VA missing accuracy contract");
    r.accuracy_valid = 1; r.range_safe = 0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply) else $fatal(1, "VA unqualified range");
    r.range_safe = 1; r.subcode = 5;
    // BF16 costs 7,828 ppm, so it needs level 8 (12,800 ppm); level 5 refuses it.
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply) else $fatal(1, "VA BF16 must not fit a 1600 ppm budget");
    r.level = 4'd8;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && p.target_numfmt == 6) else $fatal(1, "VA BF16 recipe");
    r.subcode = 6; r.scale_valid = 0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply) else $fatal(1, "VA INT8 missing scale");
    r.scale_valid = 1;
    // INT8's full-scale bound is now expressible, which the old linear
    // ladder could not do at any level.
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && p.target_numfmt == 0 && p.groups_log2 == 2 &&
            p.bound_ppm == 20'd7892 && p.budget_ppm == 20'd12800)
      else $fatal(1, "VA INT8 recipe");
    r.level = 4'd5;
    r.subcode = 2; r.exact_zero_proven = 1;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply) else $fatal(1, "VA floating zero skip forbidden");
    r.numfmt = 0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && p.skip_products) else $fatal(1, "VA integer-zero recipe");
    r.exact_zero_proven = 0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply) else $fatal(1, "VA sparse residue is not proof");
    r.bank = 2; r.subcode = 0; r.reuse_a_valid = 1;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && p.reuse_a && !p.reuse_b) else $fatal(1, "VA resident operand reuse");
    r.reuse_a_valid = 0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply) else $fatal(1, "VA stale reuse");
    r.bank = 1; r.subcode = 1;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && p.groups_log2 == 1) else $fatal(1, "VA paired output");
    r.subcode = 2;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && p.groups_log2 == 2) else $fatal(1, "VA four outputs");
    p = va_turbo_select(cfg, r, 64, 8, 8, '0);
    assert (!p.apply && p.eligible && p.recipe == 0) else $fatal(1, "VA absent consumer gate");
    r.qualified_mask = '0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply && p.eligible) else $fatal(1, "VA approval gate");
    r.qualified_mask = '1; r.window_valid = 0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply && p.eligible) else $fatal(1, "VA stale opportunity window");
    r.window_valid = 1; r.level = 0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply && !p.eligible) else $fatal(1, "VA level zero");
    r.level = 2; cfg.VaTurboEn = 0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply && !p.eligible) else $fatal(1, "VA compile gate");
    cfg.VaTurboEn = 1; cfg.Queues = 0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply && !p.eligible) else $fatal(1, "VA queue prerequisite");
    cfg.Queues = 1;
    // All 32 IDs now carry specified arithmetic, so the invariant is no longer
    // "most IDs are unsupported" but "an unauthorised or inadmissible plan takes
    // no action and leaves the native format in place".
    for (int id = 0; id < 32; id++) begin
      r.bank = 2'(id >> 3); r.subcode = 3'(id);
      p = va_turbo_select(cfg, r, 64, 8, 8, '1);
      assert (p.supported && p.arith_specified)
        else $fatal(1, "VA id=%0d has no specified arithmetic", id);
      if (!p.apply)
        assert (p.recipe == 0 && p.target_numfmt == r.numfmt && !p.convert &&
                !p.approx_products && !p.skip_products && !p.reuse_a && !p.reuse_b &&
                p.groups_log2 == 0 && p.tail_outputs == 0)
          else $fatal(1, "VA id=%0d acted without permission", id);
      if (p.apply && p.arith_kind == VA_ARITH_EXACT)
        assert (p.bound_ppm == 0) else $fatal(1, "VA exact id=%0d bound", id);
      if (p.apply)
        assert (p.bound_ppm <= p.budget_ppm) else $fatal(1, "VA id=%0d over budget", id);
      checks++;
    end
    r.bank = 1; r.subcode = 5;
    r.k = 0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply) else $fatal(1, "VA zero K");
    r.k = 257;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply) else $fatal(1, "VA oversized K");
    r.k = 16; r.regular_layout = 0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply) else $fatal(1, "VA irregular layout");
    r.regular_layout = 1;
    p = va_turbo_select(cfg, r, 63, 8, 8, '1);
    assert (!p.apply) else $fatal(1, "VA invalid provisioning");
    $display("VA_HEURISTICS PASS sweep_checks=%0d formats=8 k=1..256 banks=0..8 unauthorised=native_fallback", checks);
  end

  // Arithmetic and error-bound checks.  These are about soundness of the bound,
  // not about performance: a bound that can be exceeded is worse than none.
  initial begin : va_arith_checks
    config_pkg::ai_cfg_t cfg;
    va_turbo_request_t r;
    va_turbo_plan_t p;
    va_turbo_arith_t a;
    int unsigned specified, exact_ids, rel_ids, full_ids, checks;
    logic [19:0] prev_bound, bound;
    va_eps_rational_checks();
    va_bound_rational_checks();
    va_admission_boundary_checks();
    va_window_bound_checks();
    va_window_admission_checks();
    cfg = config_pkg::AiCfgOff;
    cfg.VaTurboEn = 1'b1; cfg.MatrixEn = 1'b1; cfg.Queues = 1;
    cfg.PolicyCodecEn = 1'b1; cfg.PolicyBenefitEn = 1'b1;
    cfg.PolicySubcodeEn = 1'b1; cfg.IslandFpEn = 1'b1;

    // Every ID in the 32-recipe namespace must have specified arithmetic, and
    // an unspecified one must be unusable rather than optimistically exact.
    specified = 0; exact_ids = 0; rel_ids = 0; full_ids = 0; checks = 0;
    for (int id = 0; id < 32; id++) begin
      for (int fmt = 0; fmt < 8; fmt++) begin
        for (int par = 0; par < 16; par++) begin
          a = va_turbo_arith(5'(id), 3'(fmt), 4'(par), 10'd512);
          assert (a.kind != VA_ARITH_NONE || (id == 18 && par[1:0] == 2'd3))
            else $fatal(1, "VA arith unspecified id=%0d fmt=%0d par=%0d", id, fmt, par);
          if (a.kind == VA_ARITH_EXACT)
            assert (a.eps_ppm == 0) else $fatal(1, "VA exact recipe carries error id=%0d", id);
          if (a.kind == VA_ARITH_NONE)
            assert (va_turbo_bound_ppm(a, 16'd256) == 20'hfffff)
              else $fatal(1, "VA unspecified arithmetic must return INVALID");
          checks++;
        end
      end
      a = va_turbo_arith(5'(id), 3'(config_pkg::AI_FMT_FP32), 4'd10, 10'd512);
      if (a.kind != VA_ARITH_NONE) specified++;
      if (a.kind == VA_ARITH_EXACT) exact_ids++;
      if (a.kind == VA_ARITH_REL) rel_ids++;
      if (a.kind == VA_ARITH_FULL) full_ids++;
    end
    assert (specified == 32) else $fatal(1, "VA specified=%0d of 32", specified);

    // Derived per-product bounds must match the closed form 2u+u^2 exactly at
    // the format mantissa widths that matter.
    assert (va_turbo_round_eps_ppm(5'd10) == 20'd977)   else $fatal(1, "FP16 eps");
    assert (va_turbo_round_eps_ppm(5'd7)  == 20'd7828)  else $fatal(1, "BF16 eps");
    assert (va_turbo_round_eps_ppm(5'd3)  == 20'd128907) else $fatal(1, "FP8E4M3 eps");
    assert (va_turbo_round_eps_ppm(5'd2)  == 20'd265625) else $fatal(1, "FP8E5M2 eps");
    assert (va_turbo_round_eps_ppm(5'd0)  == 20'hfffff) else $fatal(1, "eps overflow");
    assert (va_turbo_round_eps_ppm(5'd16) == 20'd16)      else $fatal(1, "p16 eps ceiling");
    assert (va_turbo_round_eps_ppm(5'd23) == 20'd1) else $fatal(1, "sub-ppm eps must be nonzero");
    // Monotone in retained bits: more precision may never bound worse.
    for (int bits = 0; bits < 23; bits++)
      assert (va_turbo_round_eps_ppm(5'(bits)) >= va_turbo_round_eps_ppm(5'(bits + 1)) &&
              va_turbo_trunc_eps_ppm(5'(bits)) >= va_turbo_trunc_eps_ppm(5'(bits + 1)))
        else $fatal(1, "VA eps not monotone at %0d", bits);

    // Bound composition: monotone non-decreasing in kappa, saturating at 100%,
    // and exactly eps at kappa=1.
    a = va_turbo_arith(5'd4, 3'(config_pkg::AI_FMT_FP32), 4'd0, 10'd512);
    assert (va_turbo_bound_ppm(a, 16'd256) == 20'd977) else $fatal(1, "kappa=1 identity");
    assert (va_turbo_bound_ppm(a, 16'd512) == 20'd1954) else $fatal(1, "kappa=2 doubling");
    prev_bound = 0;
    for (int kq = 256; kq <= 65535; kq += 137) begin
      bound = va_turbo_bound_ppm(a, 16'(kq));
      assert (bound >= prev_bound) else $fatal(1, "VA bound not monotone in kappa");
      assert (bound <= 20'd1000000) else $fatal(1, "VA bound exceeds 100%%");
      prev_bound = bound;
      checks++;
    end
    a = va_turbo_arith(5'd27, 3'(config_pkg::AI_FMT_FP32), 4'd0, 10'd512);
    assert (a.eps_ppm == 20'd250000) else $fatal(1, "Mitchell supremum");
    assert (va_turbo_bound_ppm(a, 16'd65535) == 20'hfffff) else $fatal(1, "bound overflow");

    // Budget ladder: 100 ppm doubling per step, saturating at 100%, level 0 off.
    // The ladder must span the whole useful range, which is the defect the old
    // linear 625-ppm form had: it could not express INT8's measured error.
    assert (va_turbo_budget_ppm(4'd0) == 20'd0) else $fatal(1, "level 0 budget");
    assert (va_turbo_budget_ppm(4'd1) == 20'd100) else $fatal(1, "level 1 budget");
    assert (va_turbo_budget_ppm(4'd5) == 20'd1600) else $fatal(1, "level 5 budget");
    assert (va_turbo_budget_ppm(4'd8) == 20'd12800) else $fatal(1, "level 8 budget");
    assert (va_turbo_budget_ppm(4'd14) == 20'd819200) else $fatal(1, "level 14 budget");
    assert (va_turbo_budget_ppm(4'd15) == 20'd1000000) else $fatal(1, "level 15 saturation");
    for (int lv = 0; lv < 15; lv++)
      assert (va_turbo_budget_ppm(4'(lv)) < va_turbo_budget_ppm(4'(lv + 1)))
        else $fatal(1, "VA budget ladder not strictly increasing at %0d", lv);
    // Every declared eps must be expressible by some level, or the encoding
    // would again be the blocker rather than the arithmetic.
    for (int id = 0; id < 32; id++) begin
      a = va_turbo_arith(5'(id), 3'(config_pkg::AI_FMT_FP32), 4'd10, 10'd512);
      if (a.kind != VA_ARITH_EXACT && a.kind != VA_ARITH_NONE)
        assert (a.eps_ppm == 20'hfffff || a.eps_ppm <= va_turbo_budget_ppm(4'd15))
          else $fatal(1, "VA id=%0d eps inexpressible by any level", id);
    end

    // Admission: the analytic bound gates independently of the caller's bound.
    r = '0;
    r.enable = 1'b1; r.bank = 2'd0; r.subcode = 3'd4; r.code = POLICY_BULK;
    r.numfmt = 3'(config_pkg::AI_FMT_FP32);
    r.m = 16'd16; r.n = 16'd16; r.k = 16'd16;
    r.regular_layout = 1'b1; r.ready_jobs = 9'd16;
    r.free_accumulators = 9'd16; r.bank_groups = 9'd16;
    r.range_safe = 1'b1; r.scale_valid = 1'b1; r.accuracy_valid = 1'b1;
    r.relative_domain_valid = 1'b1;
    r.kappa_valid = 1'b1; r.kappa_q8 = 16'd256;
    r.approx_param_valid = 1'b1; r.approx_param = 4'd10;
    r.window_valid = 1'b1; r.qualified_mask = '1;
    r.error_bound_q4 = 8'd0;
    // FP16 needs 977 ppm: level 5 (1,600 ppm) admits, level 4 (800) does not.
    r.level = 4'd5;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && p.bound_ppm == 20'd977 && p.budget_ppm == 20'd1600 &&
            p.arith_kind == VA_ARITH_REL && p.convert)
      else $fatal(1, "VA FP16 analytic admission");
    r.level = 4'd4;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply && p.eligible == 1'b0 && p.bound_ppm == 20'd977)
      else $fatal(1, "VA analytic bound must refuse over budget");
    // Cancellation alone can push an otherwise fine recipe out of budget:
    // 977 x 2 = 1,954 ppm exceeds level 5's 1,600.
    r.level = 4'd5; r.kappa_q8 = 16'd512;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply && p.bound_ppm == 20'd1954)
      else $fatal(1, "VA kappa must widen the bound");
    // Missing or unphysical kappa fails closed rather than assuming kappa=1.
    r.kappa_q8 = 16'd256; r.kappa_valid = 1'b0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply) else $fatal(1, "VA missing kappa");
    r.kappa_valid = 1'b1; r.kappa_q8 = 16'd255;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply) else $fatal(1, "VA kappa below unity");
    r.kappa_q8 = 16'd256;
    // BF16 at 7,828 ppm sits between level 7 (6,400) and level 8 (12,800).
    r.subcode = 3'd5; r.level = 4'd8;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && p.bound_ppm == 20'd7828 && p.budget_ppm == 20'd12800)
      else $fatal(1, "VA BF16 admission at level 8");
    r.level = 4'd7;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply) else $fatal(1, "VA BF16 refused at level 7");
    // FP8 E4M3 (128,906 ppm) and INT4 (147,908 ppm) are now EXPRESSIBLE, but
    // only against a budget above 10%, so they cannot slip in under a small one.
    // Expressible is not the same as acceptable; that is an approval decision.
    for (int id = 0; id < 32; id++) begin
      if (id inside {7, 29}) begin
        r.bank = 2'(id >> 3); r.subcode = 3'(id); r.error_bound_q4 = 8'd0;
        r.level = 4'd11;  // 102,400 ppm
        p = va_turbo_select(cfg, r, 64, 8, 8, '1);
        assert (!p.apply && p.bound_ppm > p.budget_ppm)
          else $fatal(1, "VA id=%0d must not fit a 10%% budget", id);
        r.level = 4'd12;  // 204,800 ppm
        p = va_turbo_select(cfg, r, 64, 8, 8, '1);
        assert (p.bound_ppm <= p.budget_ppm)
          else $fatal(1, "VA id=%0d must be expressible at level 12", id);
        checks++;
      end
    end
    r.level = 4'd5;
    // Exact recipes need no accuracy evidence at all.  INT8 rather than FP32:
    // an FP32 row at k=16 is 64 bytes and consumes the whole lane width, so
    // grouping is correctly impossible there and would not isolate the point.
    r.bank = 2'd1; r.subcode = 3'd1; r.level = 4'd1; r.error_bound_q4 = 8'd0;
    r.numfmt = 3'(config_pkg::AI_FMT_INT);
    r.accuracy_valid = 1'b0; r.kappa_valid = 1'b0; r.approx_param_valid = 1'b0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && p.arith_kind == VA_ARITH_EXACT && p.bound_ppm == 0 &&
            !p.convert && !p.approx_products)
      else $fatal(1, "VA exact grouping must not require accuracy evidence");
    // Approximate-product recipes never report concurrency.
    r.numfmt = 3'(config_pkg::AI_FMT_FP32);
    r.accuracy_valid = 1'b1; r.kappa_valid = 1'b1; r.kappa_q8 = 16'd256;
    // 12 retained mantissa bits is 244 ppm, which fits level 3 (400 ppm).
    r.approx_param_valid = 1'b1; r.approx_param = 4'd12; r.level = 4'd4;
    r.bank = 2'd3; r.subcode = 3'd1;  // id 25, mantissa reduction
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && p.approx_products && p.groups_log2 == 0 && !p.convert &&
            p.target_numfmt == r.numfmt && p.bound_ppm == 20'd489)
      else $fatal(1, "VA approximate products must not claim grouping");
    r.approx_param = 4'd4;  // 63,477 ppm at 4 retained bits
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply) else $fatal(1, "VA coarse mantissa must exceed budget");
    r.approx_param = 4'd12; r.approx_param_valid = 1'b0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply) else $fatal(1, "VA missing arithmetic parameter");
    // Lossless recipes demand a reconstruction proof, not a residue.
    r.approx_param_valid = 1'b1;
    r.bank = 2'd0; r.subcode = 3'd1; r.numfmt = 3'(config_pkg::AI_FMT_INT);
    r.exact_zero_proven = 1'b1; r.lossless_proven = 1'b0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply) else $fatal(1, "VA lossless requires a proof");
    r.lossless_proven = 1'b1;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && p.bound_ppm == 0) else $fatal(1, "VA lossless packing");
    // Corrected full-scale constants.  The previous literals (7,887 and 147,908
    // ppm) were understated against the exact values 7,889.52 and 147,959.18,
    // so they were UNSOUND.  The two-step ceiling used here lands slightly above
    // the exact ceiling (7,892 and 147,961), which is the safe direction; the
    // soundness assertion below is the one that matters, the equalities merely
    // pin the implemented arithmetic.
    assert (va_turbo_quant_eps_ppm(8'd127, 10'd512) == 20'd7892)
      else $fatal(1, "INT8 full-scale worst case");
    assert (va_turbo_quant_eps_ppm(8'd7, 10'd512) == 20'd147961)
      else $fatal(1, "INT4 full-scale worst case");
    assert (va_turbo_quant_eps_ppm(8'd127, 10'd512) > 20'd7889 &&
            va_turbo_quant_eps_ppm(8'd7, 10'd512) > 20'd147959)
      else $fatal(1, "quantisation bound must round UP, never down");
    // Flatness only ever tightens, monotonically, and never below the constant
    // term that survives at zero flatness.
    for (int flat = 1; flat < 512; flat++) begin
      assert (va_turbo_quant_eps_ppm(8'd127, 10'(flat)) <=
              va_turbo_quant_eps_ppm(8'd127, 10'(flat + 1)))
        else $fatal(1, "INT8 flatness not monotone at %0d", flat);
      assert (va_turbo_quant_eps_ppm(8'd127, 10'(flat)) <= 20'd7892)
        else $fatal(1, "flatness must not loosen the worst case");
      checks++;
    end
    assert (va_turbo_quant_eps_ppm(8'd127, 10'd256) == 20'd3954)
      else $fatal(1, "INT8 at unity flatness");
    assert (va_turbo_quant_eps_ppm(8'd255, 10'd512) == 20'hfffff)
      else $fatal(1, "unknown level count must return INVALID");

    // An absent or unphysical flatness must fall back to the worst case, not to
    // an optimistic value.
    r.bank = 2'd0; r.subcode = 3'd6; r.level = 4'd8;  // INT8 conversion
    r.numfmt = 3'(config_pkg::AI_FMT_FP32);
    r.range_safe = 1'b1; r.scale_valid = 1'b1; r.accuracy_valid = 1'b1;
    r.relative_domain_valid = 1'b1;
    r.kappa_valid = 1'b1; r.kappa_q8 = 16'd256; r.error_bound_q4 = 8'd0;
    r.approx_param_valid = 1'b1; r.worst_case_waived = 1'b0;
    r.flatness_valid = 1'b0; r.flatness_q8 = 10'd128;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && p.bound_ppm == 20'd7892 && !p.bound_waived)
      else $fatal(1, "invalid flatness must fall back to the worst case");
    r.flatness_valid = 1'b1; r.flatness_q8 = 10'd1023;  // out of range
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && p.bound_ppm == 20'd7892)
      else $fatal(1, "out-of-range flatness must fall back");
    r.flatness_q8 = 10'd256;  // fa+fb = 1.0
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && p.bound_ppm == 20'd3954)
      else $fatal(1, "flatness must tighten the bound");

    // The waiver: at a realistic full-scale kappa the analytic gate refuses
    // INT8, and only an explicit waiver admits it - recorded as such.
    // Measured full-scale kappa is 85.681, i.e. 21,934 in Q8, which takes the
    // INT8 bound to about 676,000 ppm - far above any budget anyone would sign.
    r.flatness_valid = 1'b0; r.kappa_q8 = 16'd21934;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply && p.bound_ppm > p.budget_ppm && p.bound_ppm > 20'd600000)
      else $fatal(1, "realistic kappa must refuse INT8 without a waiver");
    r.worst_case_waived = 1'b1;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && p.bound_waived && p.bound_ppm > p.budget_ppm)
      else $fatal(1, "waiver must admit and must record itself");
    // A waiver never removes the measured-bound gate.
    r.error_bound_q4 = 8'd9;  // above level 8
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply) else $fatal(1, "waiver must not bypass the measured bound");
    r.error_bound_q4 = 8'd0; r.accuracy_valid = 1'b0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply) else $fatal(1, "waiver must not bypass accuracy evidence");
    r.accuracy_valid = 1'b1; r.kappa_valid = 1'b0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (!p.apply) else $fatal(1, "waiver must not bypass kappa");
    r.kappa_valid = 1'b1; r.kappa_q8 = 16'd256; r.worst_case_waived = 1'b0;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && !p.bound_waived)
      else $fatal(1, "an in-budget plan must not be marked waived");
    // Exact recipes are never waived, because they have nothing to waive.
    r.bank = 2'd1; r.subcode = 3'd1; r.numfmt = 3'(config_pkg::AI_FMT_INT);
    r.worst_case_waived = 1'b1;
    p = va_turbo_select(cfg, r, 64, 8, 8, '1);
    assert (p.apply && !p.bound_waived && p.bound_ppm == 0)
      else $fatal(1, "exact recipe must not report a waiver");

    $display("VA_ARITH PASS ids=32 specified=%0d exact=%0d rel=%0d full=%0d checks=%0d bound=eps_times_kappa",
             specified, exact_ids, rel_ids, full_ids, checks);
  end

  g6lc_ai_policy_subcode #(
    .Enabled(1'b1), .CacheEn(CacheEn), .ReadBytesPerCycle(ReadBytesPerCycle),
    .MinSavingsCycles(MinSavingsCycles), .SwitchCycles(SwitchCycles),
    .FormatStepCycles(FormatStepCycles),
    .FormatMinReductionLog2(FormatMinReductionLog2), .GroupShapeLog2(GroupShapeLog2)
  ) i_enabled (
    .clk_i, .rst_ni, .testmode_i, .enable_i, .flush_i, .cancel_i, .start_i,
    .code_i(policy_code_t'(code_i)), .numfmt_i, .m_i, .n_i, .k_i,
    .baseline_i(baseline_o), .ready_o, .busy_o, .valid_o, .subcode_o,
    .evaluated_o, .cache_hit_o, .topology_o, .baseline_cycles_o, .selected_cycles_o
  );

  logic off_ready, off_busy, off_valid, off_evaluated, off_hit;
  logic [2:0] off_subcode;
  policy_topology_t off_topology;
  logic [31:0] off_baseline_cycles, off_selected_cycles;
  g6lc_ai_policy_subcode #(
    .Enabled(1'b0), .ReadBytesPerCycle(ReadBytesPerCycle),
    .MinSavingsCycles(MinSavingsCycles), .SwitchCycles(SwitchCycles),
    .FormatStepCycles(FormatStepCycles),
    .FormatMinReductionLog2(FormatMinReductionLog2), .GroupShapeLog2(GroupShapeLog2)
  ) i_disabled (
    .clk_i, .rst_ni, .testmode_i, .enable_i, .flush_i, .cancel_i, .start_i,
    .code_i(policy_code_t'(code_i)), .numfmt_i, .m_i, .n_i, .k_i,
    .baseline_i(baseline_o), .ready_o(off_ready), .busy_o(off_busy),
    .valid_o(off_valid), .subcode_o(off_subcode), .evaluated_o(off_evaluated), .cache_hit_o(off_hit),
    .topology_o(off_topology), .baseline_cycles_o(off_baseline_cycles),
    .selected_cycles_o(off_selected_cycles)
  );
  assign disabled_nonzero_o = |{off_ready, off_busy, off_valid, off_evaluated, off_hit,
      off_subcode, off_topology, off_baseline_cycles, off_selected_cycles};

  function automatic config_pkg::ai_cfg_t steer_cfg(input bit subcode);
    config_pkg::ai_cfg_t cfg = config_pkg::AiCfgOff;
    cfg.MatrixEn = 1'b1;
    cfg.Queues = 1;
    cfg.PolicyCodecEn = 1'b1;
    cfg.PolicyBenefitEn = 1'b1;
    cfg.PolicySubcodeEn = subcode;
    cfg.PolicySubcodeCacheEn = subcode && CacheEn;
    return cfg;
  endfunction

  logic [142:0] steer_legacy [2];
  logic [1:0] s_ready, s_work, s_valid, s_evaluated, s_hit;
  logic [2:0] s_code [2], s_fmt [2], s_subcode [2];
  policy_topology_t s_topology [2], s_selected [2];
  logic [31:0] s_baseline_cycles [2], s_selected_cycles [2];
  for (genvar i = 0; i < 2; i++) begin : gen_steer
    policy_code_t next_code;
    policy_t policy, next_policy;
    logic warm, skip, evaluated, commit, hold, hit, miss;
    logic [63:0] warm_addr;
    logic [3:0] warm_bank;
    g6lc_ai_policy_steer #(
      .AiCfg(steer_cfg(i == 1)), .ReadBytesPerCycle(ReadBytesPerCycle),
      .SubcodeMinSavingsCycles(MinSavingsCycles), .SubcodeSwitchCycles(SwitchCycles),
      .SubcodeFormatStepCycles(FormatStepCycles),
      .SubcodeMinReductionLog2(FormatMinReductionLog2),
      .SubcodeGroupShapeLog2(GroupShapeLog2)
    ) i_steer (
      .clk_i, .rst_ni, .testmode_i, .enable_i(steer_enable_i), .flush_i(steer_flush_i),
      .valid_i(steer_valid_i), .batch_first_i(steer_batch_first_i),
      .batch_last_i(steer_batch_last_i), .m_i(steer_m_i), .n_i(steer_n_i), .k_i(steer_k_i),
      .opcode_i(steer_opcode_i), .numfmt_i(steer_numfmt_i), .balance_i(steer_balance_i),
      .sample_i(steer_sample_i), .sample_valid_i(steer_sample_valid_i),
      .exact_zero_i(steer_exact_zero_i), .next_addr_i(steer_next_addr_i),
      .next_addr_valid_i(steer_next_addr_valid_i), .mispredict_i(steer_mispredict_i),
      .ready_o(s_ready[i]), .work_valid_o(s_work[i]), .code_o(s_code[i]), .next_code_o(next_code),
      .policy_o(policy), .next_policy_o(next_policy), .warm_valid_o(warm), .warm_addr_o(warm_addr),
      .warm_bank_o(warm_bank), .residual_skip_o(skip), .eval_o(evaluated), .commit_o(commit),
      .hold_o(hold), .predict_hit_o(hit), .predict_miss_o(miss), .numfmt_o(s_fmt[i]),
      .topology_o(s_topology[i]), .subcode_valid_o(s_valid[i]), .subcode_evaluated_o(s_evaluated[i]),
      .subcode_cache_hit_o(s_hit[i]), .subcode_o(s_subcode[i]), .subcode_topology_o(s_selected[i]),
      .subcode_baseline_cycles_o(s_baseline_cycles[i]), .subcode_selected_cycles_o(s_selected_cycles[i])
    );
    assign steer_legacy[i] = {s_ready[i], s_work[i], s_code[i], next_code, policy, next_policy,
        warm, warm_addr, warm_bank, skip, evaluated, commit, hold, hit, miss, s_fmt[i], s_topology[i]};
  end
  assign steer_legacy_mismatch_o = steer_legacy[0] != steer_legacy[1];
  assign steer_disabled_nonzero_o = |{s_valid[0], s_evaluated[0], s_hit[0], s_subcode[0], s_selected[0],
      s_baseline_cycles[0], s_selected_cycles[0]};
  assign steer_ready_o = s_ready[1];
  assign steer_work_valid_o = s_work[1];
  assign steer_code_o = s_code[1];
  assign steer_numfmt_o = s_fmt[1];
  assign steer_topology_o = s_topology[1];
  assign steer_subcode_valid_o = s_valid[1];
  assign steer_subcode_evaluated_o = s_evaluated[1];
  assign steer_subcode_cache_hit_o = s_hit[1];
  assign steer_subcode_o = s_subcode[1];
  assign steer_subcode_topology_o = s_selected[1];
  assign steer_baseline_cycles_o = s_baseline_cycles[1];
  assign steer_selected_cycles_o = s_selected_cycles[1];

  // pragma translate_off
  // Pin policy_dot_lanes_log2 / policy_lane_groups_log2 to the measured
  // provisioning basis (ai-gemm-codec-basis-20260906T165957Z-718434a9a9d1):
  // best lanes were 8 for INT4, 16 for INT8/FP8, 32 for FP16/BF16/FP32.  If
  // someone retunes these functions without new measured evidence, this fails.
  //
  // These expectations are k=16 values.  The underlying quantity is
  // fmt_row_bytes(k) (the operand row in bytes), which only equals twice the
  // element width at k=16; the basis could not measure other k because MaxDim
  // caps it.  If a k sweep lands, these assertions must be re-derived rather
  // than relaxed.
  initial begin
    assert (policy_dot_lanes_log2(3'(config_pkg::AI_FMT_INT4)) == 3'd3)
      else $fatal(1, "INT4 measured optimum is 8 lanes");
    assert (policy_dot_lanes_log2(3'(config_pkg::AI_FMT_INT)) == 3'd4)
      else $fatal(1, "INT8 measured optimum is 16 lanes");
    assert (policy_dot_lanes_log2(3'(config_pkg::AI_FMT_FP8_E4M3)) == 3'd4)
      else $fatal(1, "FP8 E4M3 measured optimum is 16 lanes");
    assert (policy_dot_lanes_log2(3'(config_pkg::AI_FMT_FP8_E5M2)) == 3'd4)
      else $fatal(1, "FP8 E5M2 measured optimum is 16 lanes");
    assert (policy_dot_lanes_log2(3'(config_pkg::AI_FMT_FP16)) == 3'd5)
      else $fatal(1, "FP16 measured optimum is 32 lanes");
    assert (policy_dot_lanes_log2(3'(config_pkg::AI_FMT_BF16)) == 3'd5)
      else $fatal(1, "BF16 measured optimum is 32 lanes");
    // FP32 wants 64, measured: it wins at 64 lanes for every shape class in the
    // 8/32/64-lane run, up to +320.0% on 16x16 against the 8-lane baseline.
    assert (policy_dot_lanes_log2(3'(config_pkg::AI_FMT_FP32)) == 3'd6)
      else $fatal(1, "FP32 measured optimum is 64 lanes");
    // Unsupported format must gang everything and split nothing.
    assert (policy_dot_lanes_log2(3'(config_pkg::AI_FMT_SP24)) == 3'd6 &&
            policy_lane_groups_log2(3'(config_pkg::AI_FMT_SP24), 3'd5) == 3'd0)
      else $fatal(1, "unknown format must fail closed to a single group");
    // A 32-lane array (log2 5) splits 4 ways for INT4, 2 for INT8/FP8 and not
    // at all for the 16/32-bit formats.
    assert (policy_lane_groups_log2(3'(config_pkg::AI_FMT_INT4), 3'd5) == 3'd2)
      else $fatal(1, "INT4 leaves 32 lanes idle enough for four groups");
    assert (policy_lane_groups_log2(3'(config_pkg::AI_FMT_INT), 3'd5) == 3'd1)
      else $fatal(1, "INT8 splits a 32-lane array in two");
    assert (policy_lane_groups_log2(3'(config_pkg::AI_FMT_FP16), 3'd5) == 3'd0 &&
            policy_lane_groups_log2(3'(config_pkg::AI_FMT_FP32), 3'd5) == 3'd0)
      else $fatal(1, "16/32-bit formats gang a 32-lane array");
    // Never split below the shipped 8-lane provisioning.
    for (int unsigned fmt = 0; fmt < 8; fmt++)
      assert (policy_lane_groups_log2(3'(fmt), 3'd3) == 3'd0)
        else $fatal(1, "an 8-lane array must never be split");
  end
  // pragma translate_on
endmodule

module tb_g6lc_ai_va_turbo_plan #(
  parameter bit Enabled = 1'b0
) (
  input g6lc_ai_policy_pkg::va_turbo_request_t request_i,
  input logic [31:0] consumer_mask_i,
  output g6lc_ai_policy_pkg::va_turbo_plan_t plan_o
);
  function automatic config_pkg::ai_cfg_t va_cfg();
    config_pkg::ai_cfg_t cfg = config_pkg::AiCfgOff;
    cfg.MatrixEn = 1'b1;
    cfg.Queues = 1;
    cfg.PolicyCodecEn = Enabled;
    cfg.PolicyBenefitEn = Enabled;
    cfg.PolicySubcodeEn = Enabled;
    cfg.IslandFpEn = Enabled;
    cfg.VaTurboEn = Enabled;
    return cfg;
  endfunction
  if (Enabled) begin : gen_on
    assign plan_o = g6lc_ai_policy_pkg::va_turbo_select(va_cfg(), request_i, 64, 8, 8, consumer_mask_i);
  end else begin : gen_off
    assign plan_o = '0;
  end
endmodule

module tb_g6lc_ai_va_turbo_plan_on (
  input g6lc_ai_policy_pkg::va_turbo_request_t request_i,
  input logic [31:0] consumer_mask_i,
  output g6lc_ai_policy_pkg::va_turbo_plan_t plan_o
);
  tb_g6lc_ai_va_turbo_plan #(.Enabled(1'b1)) i_on (.*);
endmodule

module tb_g6lc_ai_policy_subcode_instance #(
  parameter bit Enabled = 1'b0,
  parameter bit CacheEn = 1'b0
) (
  input logic clk_i, rst_ni, testmode_i, enable_i, flush_i, start_i,
  input g6lc_ai_policy_pkg::policy_code_t code_i,
  input logic [2:0] numfmt_i,
  input logic [15:0] m_i, n_i, k_i,
  input g6lc_ai_policy_pkg::policy_topology_t baseline_i,
  output logic ready_o, busy_o, valid_o, evaluated_o,
  output logic [2:0] subcode_o,
  output g6lc_ai_policy_pkg::policy_topology_t topology_o,
  output logic [31:0] baseline_cycles_o, selected_cycles_o
);
  g6lc_ai_policy_subcode #(.Enabled(Enabled), .CacheEn(CacheEn)) i_subcode (
    .cancel_i(1'b0), .cache_hit_o(), .*
  );
endmodule

module tb_g6lc_ai_policy_subcode_on (
  input logic clk_i, rst_ni, testmode_i, enable_i, flush_i, start_i,
  input g6lc_ai_policy_pkg::policy_code_t code_i,
  input logic [2:0] numfmt_i,
  input logic [15:0] m_i, n_i, k_i,
  input g6lc_ai_policy_pkg::policy_topology_t baseline_i,
  output logic ready_o, busy_o, valid_o, evaluated_o,
  output logic [2:0] subcode_o,
  output g6lc_ai_policy_pkg::policy_topology_t topology_o,
  output logic [31:0] baseline_cycles_o, selected_cycles_o
);
  tb_g6lc_ai_policy_subcode_instance #(.Enabled(1'b1)) i_on (.*);
endmodule

module tb_g6lc_ai_policy_subcode_cache_on (
  input logic clk_i, rst_ni, testmode_i, enable_i, flush_i, cancel_i, start_i,
  input g6lc_ai_policy_pkg::policy_code_t code_i,
  input logic [2:0] numfmt_i,
  input logic [15:0] m_i, n_i, k_i,
  input g6lc_ai_policy_pkg::policy_topology_t baseline_i,
  output logic ready_o, busy_o, valid_o, evaluated_o, cache_hit_o,
  output logic [2:0] subcode_o,
  output g6lc_ai_policy_pkg::policy_topology_t topology_o,
  output logic [31:0] baseline_cycles_o, selected_cycles_o
);
  g6lc_ai_policy_subcode #(.Enabled(1'b1), .CacheEn(1'b1)) i_cache (.*);
endmodule

`ifdef FORMAL
module tb_g6lc_ai_policy_subcode_cache_control (
  input logic clk_i, rst_ni, testmode_i, enable_i, flush_i, cancel_i, start_i, key_i,
  output logic ready_o, busy_o, valid_o, evaluated_o, cache_hit_o
);
  import g6lc_ai_policy_pkg::*;
  localparam policy_topology_t Base = {1'b1, 1'b0, 3'd0, 3'd0, 4'd9, 4'd9, 3'd2, 4'd0};
  logic [2:0] subcode;
  policy_topology_t topology;
  logic [31:0] baseline_cycles, selected_cycles;
  g6lc_ai_policy_subcode #(.Enabled(1'b1), .CacheEn(1'b1)) i_control (
    .clk_i, .rst_ni, .testmode_i, .enable_i, .flush_i, .cancel_i, .start_i,
    .code_i(POLICY_BULK), .numfmt_i(3'd1), .m_i(16'd16), .n_i(16'd16),
    .k_i(key_i ? 16'd18 : 16'd17), .baseline_i(Base),
    .ready_o, .busy_o, .valid_o, .evaluated_o, .cache_hit_o,
    .subcode_o(subcode), .topology_o(topology), .baseline_cycles_o(baseline_cycles),
    .selected_cycles_o(selected_cycles)
  );
  logic past_valid = 1'b0;
  logic [5:0] remaining_q;
  logic result_q, hit_q, pending_hit_q, completed_q, key_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      remaining_q <= '0; result_q <= 1'b0; hit_q <= 1'b0;
      pending_hit_q <= 1'b0; completed_q <= 1'b0; key_q <= 1'b0;
    end else if (flush_i || !enable_i) begin
      remaining_q <= '0; result_q <= 1'b0; hit_q <= 1'b0;
      pending_hit_q <= 1'b0; completed_q <= 1'b0; key_q <= 1'b0;
    end else if (cancel_i) begin
      remaining_q <= '0; result_q <= 1'b0; hit_q <= 1'b0;
      pending_hit_q <= 1'b0;
    end else if (remaining_q != 0) begin
      remaining_q <= remaining_q - 6'd1;
      if (remaining_q == 1) begin
        result_q <= 1'b1; hit_q <= pending_hit_q; completed_q <= 1'b1;
      end
    end else if (start_i) begin
      remaining_q <= completed_q && key_i == key_q ? 6'd1 : 6'd32;
      pending_hit_q <= completed_q && key_i == key_q;
      completed_q <= completed_q && key_i == key_q;
      key_q <= key_i; result_q <= 1'b0; hit_q <= 1'b0;
    end
  end
  always_ff @(posedge clk_i) begin
    past_valid <= 1'b1;
    if (!past_valid) assume (!rst_ni);
    if (past_valid && rst_ni) begin
      assert (busy_o == (remaining_q != 0));
      assert (ready_o == (enable_i && !flush_i && !cancel_i && remaining_q == 0));
      assert (valid_o == result_q);
      assert (evaluated_o == result_q);
      assert (cache_hit_o == hit_q);
    end
  end
endmodule

module tb_g6lc_ai_policy_subcode_control (
  input logic clk_i, rst_ni, testmode_i, enable_i, flush_i, start_i,
  output logic ready_o, busy_o, valid_o, evaluated_o
);
  import g6lc_ai_policy_pkg::*;
  localparam policy_topology_t Base = {1'b1, 1'b0, 3'd0, 3'd0, 4'd9, 4'd9, 3'd2, 4'd0};
  logic [2:0] subcode;
  policy_topology_t topology;
  logic [31:0] baseline_cycles, selected_cycles;
  g6lc_ai_policy_subcode #(.Enabled(1'b1)) i_control (
    .clk_i, .rst_ni, .testmode_i, .enable_i, .flush_i, .start_i, .cancel_i(1'b0), .cache_hit_o(),
    .code_i(POLICY_BULK), .numfmt_i(3'd1), .m_i(16'd16), .n_i(16'd16), .k_i(16'd17),
    .baseline_i(Base), .ready_o, .busy_o, .valid_o, .evaluated_o,
    .subcode_o(subcode), .topology_o(topology), .baseline_cycles_o(baseline_cycles),
    .selected_cycles_o(selected_cycles)
  );
  logic past_valid = 1'b0;
  logic [5:0] remaining_q;
  logic result_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin remaining_q <= '0; result_q <= 1'b0; end
    else if (flush_i || !enable_i) begin remaining_q <= '0; result_q <= 1'b0; end
    else if (remaining_q != 0) begin
      remaining_q <= remaining_q - 6'd1;
      if (remaining_q == 1) result_q <= 1'b1;
    end else if (start_i) begin remaining_q <= 6'd32; result_q <= 1'b0; end
  end
  always_ff @(posedge clk_i) begin
    past_valid <= 1'b1;
    if (!past_valid) assume (!rst_ni);
    if (past_valid && rst_ni) begin
      assert (busy_o == (remaining_q != 0));
      assert (ready_o == (enable_i && !flush_i && remaining_q == 0));
      assert (valid_o == result_q);
      assert (evaluated_o == result_q);
    end
  end
endmodule
`endif
