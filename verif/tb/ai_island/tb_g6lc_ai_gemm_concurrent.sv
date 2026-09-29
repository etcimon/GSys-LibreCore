// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// N g6lc_ai_gemm_seq engines vs ONE shared g6lc_ai_dram_backend through the
// real axi_mux_intf -- the concurrent-group throughput experiment the
// sub-code/V-A-Turbo work has been missing.  Every engine runs the same
// all-ones GEMM so the golden C is exactly k, and the only thing under test is
// whether N engines sharing one memory port finish N jobs faster than one
// engine running them back to back.
//
// Two sharing modes are measured per format:
//   * independent: each engine owns disjoint A/B/C regions (N x useful MACs,
//     N x read traffic);
//   * shared_b:    all engines read the SAME B (weight) region -- the decode
//     scenario where one weight matrix feeds several output tiles.  The
//     backend does not coalesce, so this still issues N x B traffic; it only
//     changes addresses, which is the honest model until a read multicast or
//     cache exists.
//
// Reported numbers are sim cycles on a free-running counter, on the class-0
// SRAM memory model: they answer "does concurrency beat serial under THIS
// memory", nothing more.  They are not MAC/s, not silicon, and not a statement
// about a real DRAM controller's queueing.
//
// `done_o` is a single-cycle pulse, so per-engine done flags latch it; `cycles`
// is only the timeout budget and `free_cy` is the measurement, same split as
// tb_g6lc_ai_gemm_backend.
//
// Not Variane.

`timescale 1ns/1ps
`include "axi/typedef.svh"
`include "axi/assign.svh"

module tb_g6lc_ai_gemm_concurrent
  import g6lc_ai_island_cfg_pkg::*;
  import g6lc_ai_policy_pkg::*;
#(
    parameter int unsigned NCH        = 2,
    parameter int unsigned N_ENGINES  = 4,
    parameter int unsigned DRAM_CLASS = AI_DRAM_SIM_AXI,
    parameter bit          DOT_PIPE_FLOAT = 1'b0,
    parameter int unsigned PE_LANES     = 0,
    parameter int unsigned MAX_DIM      = 0,
    parameter bit          VA_TURBO     = 1'b1,
    // Measurement geometry.  Defaults are the historical fixed 8x8x16 tile
    // (1024 MACs per engine), so an unset build is byte-for-byte the build it
    // always was; overriding them makes SHAPE an axis of this TB as well as of
    // the single-engine one.  They are held constant WITHIN a run, which is the
    // property the serial-vs-concurrent comparison actually needs: both phases
    // must do the same work.  The DECODE experiment at the bottom of the file is
    // the one deliberate exception -- it drives m = 1 while keeping n and k on
    // these parameters, because the whole point there is that shape moves the
    // answer.
    //
    // Bounds are checked in the initial block: m, n, k must each be <= MaxDim,
    // and the 512-byte A/B/C sub-slots must hold the tile at 4 bytes/element
    // (so e.g. JOB_N=16 with JOB_K=16 does NOT fit the B sub-slot and is
    // rejected there rather than corrupting a neighbour).
    parameter int unsigned JOB_M        = 8,
    parameter int unsigned JOB_N        = 8,
    parameter int unsigned JOB_K        = 16
);
  localparam int unsigned ID_W    = 4;
  // The mux prepends idx_width(NO_SLV_PORTS) port bits to the slave ID.
  localparam int unsigned N_PORTS = N_ENGINES + 1;
  localparam int unsigned MST_ID  = ID_W + ((N_PORTS > 1) ? $clog2(N_PORTS) : 1);
  localparam int unsigned ADDR_W  = 64;
  localparam int unsigned DATA_W  = 64;
  localparam int unsigned TO_HS   = 8000;
  localparam int unsigned TO_RSP  = 60000;

  // Per-engine memory slots, DERIVED from the geometry rather than fixed.
  //
  // They used to be constants sized for the 8x8x16 default (A and B 512 B each,
  // C 512 B, slot 0x600), which is exactly what blocked the decode point the
  // shape analysis asked for: FP32 at n=16, k=16 needs 1,024 B of B and the
  // guard correctly refused it.  Deriving them lifts that limit without moving
  // anything at the default -- each sub-slot keeps a 512 B FLOOR, so
  // OFF_B/OFF_C/SLOT come out 0x200/0x400/0x600 exactly as before and every
  // multi-engine address is unchanged.  Only a larger geometry grows them.
  //
  // Bounds are taken at 4 bytes per element, the widest format staged.  C is
  // charged an even element count because poison_engine writes 64-bit pairs.
  localparam int unsigned SUBSLOT_MIN = 16'h0200;
  localparam int unsigned A_BYTES = JOB_M * JOB_K * 4;
  localparam int unsigned B_BYTES = JOB_N * JOB_K * 4;
  localparam int unsigned C_BYTES = ((JOB_M * JOB_N + 1) / 2) * 8;
  // Round each region up to a 64-byte boundary so a row never straddles the
  // next region's first beat.
  localparam int unsigned A_SPAN = ((A_BYTES < SUBSLOT_MIN ? SUBSLOT_MIN : A_BYTES) + 63) / 64 * 64;
  localparam int unsigned B_SPAN = ((B_BYTES < SUBSLOT_MIN ? SUBSLOT_MIN : B_BYTES) + 63) / 64 * 64;
  localparam int unsigned C_SPAN = ((C_BYTES < SUBSLOT_MIN ? SUBSLOT_MIN : C_BYTES) + 63) / 64 * 64;
  localparam logic [63:0] ENG_BASE   = 64'h8000_0400;
  localparam int unsigned OFF_B      = A_SPAN;
  localparam int unsigned OFF_C      = A_SPAN + B_SPAN;
  localparam int unsigned SLOT       = A_SPAN + B_SPAN + C_SPAN;

  // 8 KiB model, or as much more as the derived slots need. The floor keeps the
  // default build at exactly 1024 words (0x400 + 4*0x600 = 0x1C00 fits), so the
  // memory model is byte-identical unless a larger geometry is asked for.
  // Declared after SLOT because it depends on it.
  localparam int unsigned NWORDS_MIN  = 1024;
  localparam int unsigned NWORDS_NEED = (16'h0400 + N_ENGINES * SLOT + 7) / 8;
  localparam int unsigned NWORDS      =
      (NWORDS_NEED > NWORDS_MIN) ? NWORDS_NEED : NWORDS_MIN;

  // The measurement geometry (default 8x8x16, 1024 MACs per engine) is now the
  // JOB_M/JOB_N/JOB_K module parameters above.  It is still kept CONSTANT across
  // the serial and concurrent phases -- that is what makes them the same work --
  // but it is no longer a compile-time constant of this file, so shape is an
  // axis here too and not only on the single-engine TB's +measure / +measure_k
  // sweeps.

  localparam logic [DATA_W-1:0] ONES8      = 64'h0101_0101_0101_0101;
  localparam logic [DATA_W-1:0] INT4_1     = {8{8'h11}};
  localparam logic [DATA_W-1:0] FP8_E4M3_1 = {8{8'h38}};
  localparam logic [DATA_W-1:0] FP8_E5M2_1 = {8{8'h3C}};
  localparam logic [DATA_W-1:0] FP16_1     = {4{16'h3C00}};
  localparam logic [DATA_W-1:0] BF16_1     = {4{16'h3F80}};
  localparam logic [DATA_W-1:0] FP32_1     = {2{32'h3F800000}};

  typedef logic [ADDR_W-1:0]     addr_t;
  typedef logic [ID_W-1:0]       id_t;
  typedef logic [DATA_W-1:0]     data_t;
  typedef logic [DATA_W/8-1:0]   strb_t;
  typedef logic [0:0]            user_t;
  `AXI_TYPEDEF_ALL(gbus, addr_t, id_t, data_t, strb_t, user_t)

  logic clk, rst_ni, init_done;
  logic aw_pend, w_pend, ar_pend, aw_set, w_set, ar_set;
  logic b_ready_en, r_ready_en;
  logic [AI_DRAM_MAX_CHANNELS-1:0][31:0] ch_r_beats, ch_w_beats;
  int unsigned errors, cycles;
  logic        straddle, clr_seen;
  logic [31:0] free_cy;

  // Per-engine control/status.
  logic [N_ENGINES-1:0] start_v, ready_v, done_v, err_v, done_seen;
  logic [2:0]  numfmt_v [N_ENGINES];
  logic [63:0] pa_v [N_ENGINES], pb_v [N_ENGINES], pc_v [N_ENGINES];
  logic [31:0] pmu_cy_v [N_ENGINES], pmu_r_v [N_ENGINES], pmu_w_v [N_ENGINES];
  logic [31:0] m_v [N_ENGINES], n_v [N_ENGINES], k_v [N_ENGINES];
  logic [15:0] lda_v [N_ENGINES], ldb_v [N_ENGINES];
  logic [N_ENGINES-1:0] reuse_v, invalidate_v, reuse_hit_v, lease_v;
  logic [31:0] epoch_v [N_ENGINES];
  // Resident-A mirror of the four B-side residency signals.  A and B residency
  // are two INDEPENDENT keys of the same recipe 16 -- one job may hit neither,
  // either or both -- so the lease, the epoch and the invalidation are all
  // per-engine and per-side, never shared.
  logic [N_ENGINES-1:0] reuse_a_v, invalidate_a_v, reuse_hit_a_v, lease_a_v;
  logic [31:0] epoch_a_v [N_ENGINES];
  logic [N_ENGINES-1:0] permission_v, window_v, policy_enable_v;
  logic [3:0] level_v [N_ENGINES];
  // LOSSLESS NARROWING control, per engine.  `lossless_v` swaps the whole
  // request over to recipe 1 (bank 0 sub-code 1) and `lossless_target_v` is the
  // proven-exact target format.  Both default low/zero and are only raised by
  // run_lossless, exactly as the A lease is, so no other experiment can see a
  // lossless request.
  logic [N_ENGINES-1:0] lossless_v;
  logic [2:0] lossless_target_v [N_ENGINES];
  va_turbo_request_t request_v [N_ENGINES];
  va_turbo_plan_t plan_v [N_ENGINES];
  int unsigned b_owner_v [N_ENGINES], b_version_v [N_ENGINES];
  bit signed_data;
  localparam int unsigned REPEATS = 2;
  localparam logic [31:0] REUSE_MASK = 32'h1 << 16;
  // Recipe 1 is the lossless repack; it shares the family with 3 and 17 but is
  // the plain one (17 additionally demands the B lease, which these runs
  // deliberately do not hold so both runs pay full operand traffic).
  localparam logic [31:0] LOSSLESS_MASK = 32'h1 << 1;

  // Opportunistic mixed-hit sequence: fixed length and fixed denominator so
  // every hit fraction runs exactly the same amount of useful work.
  localparam int unsigned EXPERIMENTS   = 18;
  localparam int unsigned JOBS_PER_SEQ  = 8;
  localparam int unsigned OPP_FRACTIONS = 5;
  int unsigned opp_cy, opp_r, opp_w, opp_hit_count;

  // Directed A-residency set and the four-point A/B combination experiment,
  // both driven from tables for the compile-time reason spelled out at the
  // EXPERIMENTS loop in the stimulus block below.
  localparam int unsigned A_CASES     = 32;
  localparam int unsigned DUAL_FMTS   = 2;
  localparam int unsigned DUAL_POINTS = 4;

  // Proven-exact narrowing pairs, table driven for the same compile-time reason
  // as everything else here.  One integer pair (which must be BIT-IDENTICAL)
  // and the two float pairs (which may only regroup the FP32 accumulator).
  localparam int unsigned LOSSLESS_PAIRS = 3;
  // Bound for the float pairs, stated in FP32 ULPs of the C word because that
  // is the only integer metric the raw 32-bit C storage supports.  FP32 RNE has
  // a 2^-23 relative spacing, so the 1 ppm the selector reports for a float
  // lossless narrowing (VA_FP32_RNE_PPM, eps_per_window) is ~8.4 ULP: 8 ULP is
  // therefore the plan's own promise expressed in the storage domain.  It is
  // also ~4 orders of magnitude tighter than any change to the PRODUCTS: C here
  // is a whole number of magnitude <= 784, so one unit of C is >= 16,384 ULP.
  // A regrouping difference can hide under this bound; a wrong product cannot.
  //
  // MEASURED: all three pairs come out at 0 ULP, the float pairs included.  That
  // is not the host model's ~5.8 ppm (BF16) / ~0.3 ppm (FP16) and it does not
  // contradict it -- it bounds where those figures can come from.  This fixture's
  // operands are small whole numbers, so every partial sum is a whole number
  // well inside FP32's 24-bit significand and NO fold rounds; regrouping folds
  // that round nothing cannot move the result.  A non-zero float difference
  // needs operands that are exact in the target yet mantissa-rich enough to make
  // the FP32 accumulator round mid-reduction, which this harness's integer
  // fixture cannot express.  The bound is kept at the plan's declared 1 ppm
  // rather than tightened to the observed 0, because 0 is a property of THESE
  // operands and not of the recipe.
  //
  // UPDATE: the last sentence of that paragraph was too pessimistic about the
  // HARNESS, not about the arithmetic.  Operands of the form mantissa * 2^exp
  // with positive exponents only are still whole numbers -- no fractional
  // operand path is needed -- and a wide enough exponent ladder does make the
  // accumulator round mid-reduction.  That is the `wide_exponent` data class
  // below; the small-integer class and its 0 ULP measurement stay exactly as
  // they are, because they are still the right control.
  localparam int unsigned LOSSLESS_FP_ULP_BOUND = 8;
  // Second data class over the SAME pairs: WIDE EXPONENT.  Values are
  // sign * mantissa * 2^exponent, with the mantissa bounded by the TARGET's
  // explicit mantissa bits (BF16 7 -> <= 127, FP16 10 -> <= 1023) so every
  // element remains EXACTLY representable in the target -- proved element by
  // element through the same element_exact_in over both tiles that the
  // small-integer class uses, never assumed -- and with mantissa * 2^max_exp
  // kept inside the target's finite range (FP16: 1023 * 2^6 = 65472 <= 65504).
  //
  // Why the ladder is what makes the difference appear.  The engine's reduction
  // window is mac_step = PeLanes / bytes_per_element (g6lc_ai_gemm_seq F1), so
  // an FP32 tile folds 2 products at a time and a BF16/FP16 tile folds 4.  Each
  // window is summed EXACTLY by the block-float tree and rounded once, and the
  // windows are then combined by g6lc_ai_fp_pkg::fp32_add.  Regrouping can
  // therefore only move the result where a fold actually rounds, and a fold only
  // rounds when the terms in flight differ in magnitude by more than FP32's
  // 24-bit significand.  The exponent ladder manufactures exactly that: the
  // small products fall below the ULP of the running sum, and WHERE they fall
  // below it depends on the window -- which is the whole effect being measured.
  localparam int unsigned LOSSLESS_CLASSES = 2;
  // Bound for the float pairs under the wide-exponent class, again stated in
  // FP32 ULPs of the raw C word.  MEASURED here: 32 ULP with 38/64 elements
  // differing (FP32 -> BF16) and 5 ULP with 19/64 (FP32 -> FP16), which an
  // independent host model of the same window/fold structure reproduces exactly.
  // 256 is 8x the worst observation -- loose enough that a different PE_LANES or
  // fold order stays inside it -- and still ~64x BELOW the smallest move a LOSSY
  // narrowing could make: dropping even one BF16 mantissa bit perturbs an
  // element by 2^-8 relative, so a product of the same order as C moves C by
  // >= 2^-9 relative, i.e. >= 2^14 = 16384 ULP.  The bound therefore separates
  // "the accumulator regrouped" from "the operands changed", which is the only
  // distinction this experiment has to make.
  localparam int unsigned LOSSLESS_WIDE_ULP_BOUND = 256;
  logic [31:0] loss_ref_c [JOB_M*JOB_N];
  longint loss_max_diff;
  // Element-resolved companions to loss_max_diff: how many C words moved between
  // the two runs, and how many are still the poison value (i.e. were never
  // written).  Both are maintained unconditionally by compare_c and are only
  // ASSERTED on by the wide-exponent class, so the small-integer class's output
  // and checks are untouched.
  int unsigned loss_diff_elems, loss_poison_elems;
  // Wide-exponent data-class state.  `wide_exp_data` swaps a_value/b_value over
  // to the ladder and `wide_exp_dst` is the target format whose mantissa/range
  // envelope the ladder must respect.  Both default off and are only raised by
  // run_lossless, exactly as the lossless request itself is, so no other
  // experiment can see this data.
  bit wide_exp_data;
  logic [2:0] wide_exp_dst;

  function automatic config_pkg::ai_cfg_t test_cfg();
    config_pkg::ai_cfg_t cfg;
    cfg = config_pkg::AiCfgOff;
    cfg.MatrixEn = 1'b1;
    cfg.PolicyCodecEn = 1'b1;
    cfg.PolicyBenefitEn = 1'b1;
    cfg.PolicySubcodeEn = 1'b1;
    cfg.IslandFpEn = 1'b1;
    cfg.VaTurboEn = VA_TURBO;
    cfg.Queues = 1;
    cfg.Int4En = 1'b1;
    cfg.FormatMask = config_pkg::AiFmtMaskAll & ~(1 << config_pkg::AI_FMT_SP24);
    return cfg;
  endfunction

  localparam config_pkg::ai_cfg_t TEST_CFG = test_cfg();
  gbus_req_t   eng_req  [N_ENGINES];
  gbus_resp_t  eng_resp [N_ENGINES];
  gbus_resp_t  checked_resp [N_ENGINES];
  logic [N_ENGINES-1:0] inject_r_error;

  AXI_BUS #(.AXI_ADDR_WIDTH(ADDR_W), .AXI_DATA_WIDTH(DATA_W),
            .AXI_ID_WIDTH(ID_W), .AXI_USER_WIDTH(1)) mux_slv[N_PORTS-1:0]();
  AXI_BUS #(.AXI_ADDR_WIDTH(ADDR_W), .AXI_DATA_WIDTH(DATA_W),
            .AXI_ID_WIDTH(MST_ID), .AXI_USER_WIDTH(1)) dram();

  assign mux_slv[0].aw_valid = aw_pend;
  assign mux_slv[0].w_valid  = w_pend;
  assign mux_slv[0].ar_valid = ar_pend;
  assign mux_slv[0].b_ready  = b_ready_en;
  assign mux_slv[0].r_ready  = r_ready_en;

  for (genvar i = 0; i < N_ENGINES; i++) begin : gen_eng_bus
    `AXI_ASSIGN_FROM_REQ(mux_slv[i+1], eng_req[i])
    `AXI_ASSIGN_TO_RESP(eng_resp[i], mux_slv[i+1])
  end

  axi_mux_intf #(
      .SLV_AXI_ID_WIDTH ( ID_W ),
      .MST_AXI_ID_WIDTH ( MST_ID ),
      .AXI_ADDR_WIDTH   ( ADDR_W ),
      .AXI_DATA_WIDTH   ( DATA_W ),
      .AXI_USER_WIDTH   ( 1 ),
      .NO_SLV_PORTS     ( N_PORTS )
  ) i_mux (
      .clk_i  ( clk ),
      .rst_ni ( rst_ni ),
      .test_i ( 1'b0 ),
      .slv    ( mux_slv ),
      .mst    ( dram )
  );

  g6lc_ai_dram_backend #(
      .DramClass      ( DRAM_CLASS ),
      .AXI_ID_WIDTH   ( MST_ID ),
      .AXI_ADDR_WIDTH ( ADDR_W ),
      .AXI_DATA_WIDTH ( DATA_W ),
      .AXI_USER_WIDTH ( 1 ),
      .AXI_USER_EN    ( 0 ),
      .NUM_WORDS      ( NWORDS ),
      .NrChannels     ( NCH ),
      .ChanShift      ( AI_DRAM_CHAN_SHIFT_DEFAULT ),
      .MaxAROut       ( (DRAM_CLASS == AI_DRAM_SIM_AXI) ? AI_MAX_AR_OUT_LIVE
                                                       : AI_MAX_AR_OUT_DRAM )
  ) i_mem (
      .clk_i        ( clk ),
      .rst_ni       ( rst_ni ),
      .rst_sram_ni  ( rst_ni ),
      .testmode_i   ( 1'b0 ),
      .slave        ( dram ),
      .init_done_o  ( init_done ),
      .ch_r_beats_o ( ch_r_beats ),
      .ch_w_beats_o ( ch_w_beats )
  );

  localparam int GEMM_MAX_AR = (DRAM_CLASS == AI_DRAM_SIM_AXI) ? AI_MAX_AR_OUT_LIVE
                                                               : AI_MAX_AR_OUT_DRAM;
  localparam int GEMM_LANES  = (PE_LANES == 0) ? 8 : int'(PE_LANES);
  localparam int GEMM_MAXDIM = (MAX_DIM == 0) ? 16 : int'(MAX_DIM);

  for (genvar i = 0; i < N_ENGINES; i++) begin : gen_eng
    always_comb begin
      checked_resp[i] = eng_resp[i];
      if (inject_r_error[i]) checked_resp[i].r.resp = axi_pkg::RESP_SLVERR;
    end
    always_comb begin
      request_v[i] = '0;
      request_v[i].enable = policy_enable_v[i];
      request_v[i].level = level_v[i];
      // Recipe 16 is bank 2 sub-code 0; the lossless repack is recipe 1, i.e.
      // bank 0 sub-code 1.  One request publishes one plan, so the sub-code and
      // the consumer mask below move together with `lossless_v`.
      request_v[i].bank = lossless_v[i] ? 2'd0 : 2'd2;
      request_v[i].subcode = lossless_v[i] ? 3'd1 : 3'd0;
      request_v[i].code = POLICY_BULK;
      request_v[i].numfmt = numfmt_v[i];
      request_v[i].m = 16'(m_v[i]);
      request_v[i].n = 16'(n_v[i]);
      request_v[i].k = 16'(k_v[i]);
      request_v[i].regular_layout = 1'b1;
      request_v[i].reuse_b_valid = lease_v[i];
      request_v[i].reuse_a_valid = lease_a_v[i];
      request_v[i].window_valid = window_v[i];
      // LOSSLESS NARROWING evidence.  Every field is gated on `lossless_v`, so
      // it reads as a hard zero for the reuse, opportunistic, directed and dual
      // experiments and cannot move any of their measurements.
      request_v[i].lossless_proven        = lossless_v[i];
      request_v[i].lossless_narrow_valid  = lossless_v[i];
      request_v[i].lossless_narrow_target = lossless_v[i] ? lossless_target_v[i] : 3'd0;
      // A float target makes recipe 1 report VA_ARITH_REL at 1 ppm, so it has to
      // clear the accuracy admission gate; the integer pair reports EXACT and
      // never reaches that gate at all.  kappa is caller evidence the harness
      // cannot honestly measure here, so it supplies the neutral Q8 1.0 floor
      // the gate demands -- the accuracy claim this test actually makes is the
      // MEASURED max_abs_diff below, not the selector's reported bound.
      request_v[i].accuracy_valid         = lossless_v[i];
      request_v[i].kappa_valid            = lossless_v[i];
      request_v[i].kappa_q8               = lossless_v[i] ? 16'd256 : 16'd0;
      request_v[i].range_safe             = lossless_v[i];
      request_v[i].relative_domain_valid  = lossless_v[i];
      request_v[i].qualified_mask = permission_v[i]
          ? (lossless_v[i] ? LOSSLESS_MASK : REUSE_MASK) : 32'd0;
      plan_v[i] = va_turbo_select(TEST_CFG, request_v[i], GEMM_LANES, 8, 1,
                                  lossless_v[i] ? LOSSLESS_MASK : REUSE_MASK);
      reuse_v[i] = plan_v[i].apply && plan_v[i].reuse_b;
      // Same real plan, other operand: recipe 16 publishes the two residencies
      // separately, so an A lease alone is enough for the plan to apply.
      reuse_a_v[i] = plan_v[i].apply && plan_v[i].reuse_a;
    end

    always @(posedge clk) begin
      if (rst_ni) begin
        // A lossless job publishes recipe 1, not recipe 16, so the recipe-16
        // expectations below cannot apply to it; they are guarded rather than
        // weakened, and the recipe-1 plan gets its own complete set instead.
        if (start_v[i] && !lossless_v[i]) begin
          automatic bit recipe16_ok;
          // Everything recipe 16 demands EXCEPT the owner lease.  The two sides
          // share every other gate, so factoring it out is what keeps the A and
          // B expectations provably identical apart from which lease is held.
          recipe16_ok = VA_TURBO && policy_enable_v[i] && level_v[i] != 0 &&
                        window_v[i] && permission_v[i] &&
                        m_v[i] != 0 && n_v[i] != 0 && k_v[i] != 0 &&
                        m_v[i] <= 256 && n_v[i] <= 256 && k_v[i] <= 256 &&
                        policy_format_known(numfmt_v[i]);
          assert (reuse_v[i] == (recipe16_ok && lease_v[i]))
            else $fatal(1, "eng%0d recipe16 permission mismatch", i);
          assert (reuse_a_v[i] == (recipe16_ok && lease_a_v[i]))
            else $fatal(1, "eng%0d recipe16 A permission mismatch", i);
          if (plan_v[i].apply)
            // A plan that claims resident A is still the SAME exact recipe: no
            // conversion, no approximation, no grouping, no format change.  It
            // must also claim at least one residency, or recipe 16 bought
            // nothing and should not have applied.
            assert (plan_v[i].recipe == 16 && plan_v[i].arith_kind == VA_ARITH_EXACT &&
                    !plan_v[i].convert && !plan_v[i].approx_products &&
                    !plan_v[i].skip_products && !plan_v[i].split_rows &&
                    plan_v[i].groups_log2 == 0 && plan_v[i].target_numfmt == numfmt_v[i] &&
                    (plan_v[i].reuse_a || plan_v[i].reuse_b) &&
                    plan_v[i].reuse_a == lease_a_v[i] && plan_v[i].reuse_b == lease_v[i])
              else $fatal(1, "eng%0d unsupported plan reached consumer", i);
        end
        if (start_v[i] && lossless_v[i]) begin
          automatic bit narrower, both_int, gates_ok, lossless_ok;
          // STRICTLY narrower is what makes it a NARROWING: an equal-width pair
          // buys no beats, so the selector refuses to CONVERT one.  It does not
          // follow that it refuses the request: recipe 1 is the lossless repack
          // family, and its pre-existing integer arm admits a proven-exact
          // INTEGER tensor at unchanged width (convert=0, lossless_narrowed=0).
          // Measured, not assumed -- an INT4 request with an INT4 target does
          // apply.  So the dst run below is a live check of BOTH rules at once:
          // the float pair must be refused outright, the integer pair must fall
          // back to the plain repack and must NOT claim a narrowing.
          narrower = policy_format_known(numfmt_v[i]) &&
                     policy_format_known(lossless_target_v[i]) &&
                     policy_element_bits_log2(lossless_target_v[i]) <
                     policy_element_bits_log2(numfmt_v[i]);
          both_int = policy_integer_format(numfmt_v[i]) &&
                     policy_integer_format(lossless_target_v[i]);
          gates_ok = VA_TURBO && policy_enable_v[i] && level_v[i] != 0 &&
                     window_v[i] && permission_v[i] &&
                     m_v[i] != 0 && n_v[i] != 0 && k_v[i] != 0 &&
                     m_v[i] <= 256 && n_v[i] <= 256 && k_v[i] <= 256 &&
                     policy_format_known(numfmt_v[i]);
          lossless_ok = gates_ok &&
                        (narrower || policy_integer_format(numfmt_v[i]));
          assert (plan_v[i].apply == lossless_ok)
            else $fatal(1, "eng%0d lossless apply=%0b expected=%0b fmt=%0d target=%0d",
                        i, plan_v[i].apply, lossless_ok, numfmt_v[i],
                        lossless_target_v[i]);
          if (plan_v[i].apply) begin
            // Whichever arm applied, recipe 1 changes STORAGE and nothing else:
            // same products, no approximation, no grouping, no residency (that
            // is recipe 17's job and this plan never takes a lease).
            assert (plan_v[i].recipe == 5'd1 &&
                    !plan_v[i].approx_products && !plan_v[i].skip_products &&
                    !plan_v[i].split_rows && plan_v[i].groups_log2 == 0 &&
                    !plan_v[i].reuse_a && !plan_v[i].reuse_b &&
                    plan_v[i].lossless_narrowed == narrower)
              else $fatal(1, "eng%0d lossless plan recipe=%0d narrowed=%0b expected_narrowed=%0b",
                          i, plan_v[i].recipe, plan_v[i].lossless_narrowed, narrower);
            if (narrower)
              // The arithmetic split is the load-bearing part: an integer
              // source narrowing into an integer target has no rounding site
              // anywhere (EXACT, eps 0, no window term), while anything that
              // reaches the FP32 accumulator merely regroups its folds and is
              // charged the accumulation epsilon per WINDOW, not the target
              // format's per-product one.
              assert (plan_v[i].convert &&
                      plan_v[i].target_numfmt == lossless_target_v[i] &&
                      plan_v[i].arith_kind == (both_int ? VA_ARITH_EXACT : VA_ARITH_REL) &&
                      plan_v[i].eps_ppm == (both_int ? 20'd0 : VA_FP32_RNE_PPM) &&
                      plan_v[i].eps_per_window == !both_int)
                else $fatal(1, "eng%0d lossless narrow convert=%0b target=%0d kind=%0d eps=%0d per_window=%0b",
                            i, plan_v[i].convert, plan_v[i].target_numfmt,
                            plan_v[i].arith_kind, plan_v[i].eps_ppm,
                            plan_v[i].eps_per_window);
            else
              // The plain integer repack: no conversion, no format change, and
              // exact by construction, so it may claim no per-window site.
              assert (!plan_v[i].convert &&
                      plan_v[i].target_numfmt == numfmt_v[i] &&
                      plan_v[i].arith_kind == VA_ARITH_EXACT &&
                      plan_v[i].eps_ppm == 20'd0 && !plan_v[i].eps_per_window)
                else $fatal(1, "eng%0d lossless repack convert=%0b target=%0d kind=%0d eps=%0d per_window=%0b",
                            i, plan_v[i].convert, plan_v[i].target_numfmt,
                            plan_v[i].arith_kind, plan_v[i].eps_ppm,
                            plan_v[i].eps_per_window);
          end
        end
        if (eng_resp[i].r_valid && eng_req[i].r_ready)
          assert (eng_resp[i].r.resp == axi_pkg::RESP_OKAY)
            else $fatal(1, "eng%0d AXI RRESP=%0h", i, eng_resp[i].r.resp);
        if (eng_resp[i].b_valid && eng_req[i].b_ready)
          assert (eng_resp[i].b.resp == axi_pkg::RESP_OKAY)
            else $fatal(1, "eng%0d AXI BRESP=%0h", i, eng_resp[i].b.resp);
      end
    end

    g6lc_ai_gemm_seq #(
        .AddrWidth  ( ADDR_W ),
        .DataWidth  ( DATA_W ),
        .IdWidth    ( ID_W ),
        .MaxDim     ( GEMM_MAXDIM ),
        .PeLanes    ( GEMM_LANES ),
        .DotPipeFloat( DOT_PIPE_FLOAT ),
        .ReuseBEn   ( VA_TURBO ),
        .ReuseAEn   ( VA_TURBO ),
        .MaxAROut   ( GEMM_MAX_AR ),
        .NrChannels ( NCH ),
        .ChanShift  ( AI_DRAM_CHAN_SHIFT_DEFAULT ),
        .axi_req_t  ( gbus_req_t ),
        .axi_resp_t ( gbus_resp_t )
    ) i_gemm (
        .clk_i        ( clk ),
        .rst_ni       ( rst_ni ),
        .testmode_i   ( 1'b0 ),
        .start_i      ( start_v[i] ),
        .m_i          ( m_v[i] ),
        .n_i          ( n_v[i] ),
        .k_i          ( k_v[i] ),
        .lda_i        ( lda_v[i] ),
        .ldb_i        ( ldb_v[i] ),
        .reuse_b_i    ( reuse_v[i] ),
        .reuse_b_epoch_i ( epoch_v[i] ),
        .reuse_b_invalidate_i ( invalidate_v[i] ),
        .pmu_reuse_b_hit_o ( reuse_hit_v[i] ),
        .reuse_a_i    ( reuse_a_v[i] ),
        .reuse_a_epoch_i ( epoch_a_v[i] ),
        .reuse_a_invalidate_i ( invalidate_a_v[i] ),
        .pmu_reuse_a_hit_o ( reuse_hit_a_v[i] ),
        .numfmt_i     ( numfmt_v[i] ),
        .accumulate_i(1'b0),
        .ar_max_i     ( 4'(GEMM_MAX_AR) ),  // AR-cap consumer was removed: always max
        .ptr_a_i      ( pa_v[i] ),
        .ptr_b_i      ( pb_v[i] ),
        .ptr_c_i      ( pc_v[i] ),
        .ready_o      ( ready_v[i] ),
        .done_o       ( done_v[i] ),
        .err_o        ( err_v[i] ),
        .pmu_r_beats_o( pmu_r_v[i] ),
        .pmu_w_beats_o( pmu_w_v[i] ),
        .pmu_cycles_o ( pmu_cy_v[i] ),
        .pmu_phase_o (), .pmu_stall_o (),
        .axi_req_o    ( eng_req[i] ),
        .axi_resp_i   ( checked_resp[i] )
    );
  end

  initial clk = 0;
  always #5 clk = ~clk;

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) free_cy <= 32'd0;
    else         free_cy <= free_cy + 32'd1;
  end

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      aw_pend <= 1'b0;
      w_pend  <= 1'b0;
      ar_pend <= 1'b0;
    end else begin
      if (aw_set) aw_pend <= 1'b1;
      else if (aw_pend && mux_slv[0].aw_ready) aw_pend <= 1'b0;
      if (w_set) w_pend <= 1'b1;
      else if (w_pend && mux_slv[0].w_ready) w_pend <= 1'b0;
      if (ar_set) ar_pend <= 1'b1;
      else if (ar_pend && mux_slv[0].ar_ready) ar_pend <= 1'b0;
    end
  end

  // done_o is a pulse: latch one flag per engine.  clr_seen is the task-side
  // clear, mirroring the aw_set/w_set/ar_set handshake pattern.
  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      done_seen <= '0;
    end else if (clr_seen) begin
      done_seen <= '0;
    end else begin
      for (int i = 0; i < N_ENGINES; i++)
        if (done_v[i]) done_seen[i] <= 1'b1;
    end
  end

  // Stripe-fit monitor across every engine port.  Any engine burst that
  // straddles a channel stripe is a harness bug, not contention.  One flag per
  // port in a generate scope because an interface array index must be static.
  logic [N_ENGINES-1:0] straddle_v;
  for (genvar gi = 0; gi < N_ENGINES; gi++) begin : gen_straddle
    always_ff @(posedge clk or negedge rst_ni) begin
      if (!rst_ni) begin
        straddle_v[gi] <= 1'b0;
      end else if (mux_slv[gi+1].ar_valid && mux_slv[gi+1].ar_ready) begin
        automatic int unsigned nbytes;
        nbytes = (unsigned'(mux_slv[gi+1].ar_len) + 1) << unsigned'(mux_slv[gi+1].ar_size);
        if (!dram_burst_fits_stripe(NCH, AI_DRAM_CHAN_SHIFT_DEFAULT,
                                    mux_slv[gi+1].ar_addr, nbytes))
          straddle_v[gi] <= 1'b1;
      end
    end
  end
  always_comb straddle = |straddle_v;

  task automatic tick;
    @(posedge clk);
    #1;
    cycles++;
  endtask

  task automatic idle_payload;
    mux_slv[0].aw_id     = '0;
    mux_slv[0].aw_addr   = '0;
    mux_slv[0].aw_len    = '0;
    mux_slv[0].aw_size   = 3'd3;
    mux_slv[0].aw_burst  = 2'b01;
    mux_slv[0].aw_lock   = 1'b0;
    mux_slv[0].aw_cache  = '0;
    mux_slv[0].aw_prot   = '0;
    mux_slv[0].aw_qos    = '0;
    mux_slv[0].aw_region = '0;
    mux_slv[0].aw_atop   = '0;
    mux_slv[0].aw_user   = '0;
    mux_slv[0].w_data    = '0;
    mux_slv[0].w_strb    = 8'hFF;
    mux_slv[0].w_last    = 1'b1;
    mux_slv[0].w_user    = '0;
    mux_slv[0].ar_id     = '0;
    mux_slv[0].ar_addr   = '0;
    mux_slv[0].ar_len    = '0;
    mux_slv[0].ar_size   = 3'd3;
    mux_slv[0].ar_burst  = 2'b01;
    mux_slv[0].ar_lock   = 1'b0;
    mux_slv[0].ar_cache  = '0;
    mux_slv[0].ar_prot   = '0;
    mux_slv[0].ar_qos    = '0;
    mux_slv[0].ar_region = '0;
    mux_slv[0].ar_user   = '0;
  endtask

  task automatic issue_aw(input logic [ADDR_W-1:0] addr);
    @(negedge clk);
    cycles = 0;
    mux_slv[0].aw_addr = addr;
    mux_slv[0].aw_len  = 8'd0;
    mux_slv[0].aw_size = 3'd3;
    mux_slv[0].aw_burst = 2'b01;
    aw_set = 1'b1;
    tick;
    @(negedge clk);
    aw_set = 1'b0;
    while (aw_pend && cycles < TO_HS) tick;
    if (aw_pend) $fatal(1, "timeout AW addr=%h", addr);
  endtask

  task automatic issue_w(input logic [DATA_W-1:0] data);
    @(negedge clk);
    cycles = 0;
    mux_slv[0].w_data = data;
    mux_slv[0].w_last = 1'b1;
    mux_slv[0].w_strb = 8'hFF;
    w_set = 1'b1;
    tick;
    @(negedge clk);
    w_set = 1'b0;
    while (w_pend && cycles < TO_HS) tick;
    if (w_pend) $fatal(1, "timeout W");
  endtask

  task automatic wr8(input logic [ADDR_W-1:0] addr, input logic [DATA_W-1:0] data);
    @(negedge clk);
    b_ready_en = 1'b0;
    issue_aw(addr);
    issue_w(data);
    cycles = 0;
    while (!mux_slv[0].b_valid && cycles < TO_RSP) tick;
    if (!mux_slv[0].b_valid) $fatal(1, "timeout B addr=%h", addr);
    assert (mux_slv[0].b_resp == axi_pkg::RESP_OKAY)
      else $fatal(1, "staging BRESP=%0h addr=%h", mux_slv[0].b_resp, addr);
    @(negedge clk);
    b_ready_en = 1'b1;
    tick;
    @(negedge clk);
    b_ready_en = 1'b0;
  endtask

  task automatic rd8(input logic [ADDR_W-1:0] addr, output logic [DATA_W-1:0] data);
    @(negedge clk);
    cycles = 0;
    mux_slv[0].ar_addr = addr;
    mux_slv[0].ar_len  = 8'd0;
    mux_slv[0].ar_size = 3'd3;
    mux_slv[0].ar_burst = 2'b01;
    r_ready_en = 1'b0;
    ar_set = 1'b1;
    tick;
    @(negedge clk);
    ar_set = 1'b0;
    while (ar_pend && cycles < TO_HS) tick;
    if (ar_pend) $fatal(1, "timeout AR addr=%h", addr);
    cycles = 0;
    while (!mux_slv[0].r_valid && cycles < TO_RSP) tick;
    if (!mux_slv[0].r_valid) $fatal(1, "timeout R addr=%h", addr);
    assert (mux_slv[0].r_resp == axi_pkg::RESP_OKAY && mux_slv[0].r_last)
      else $fatal(1, "checking RRESP=%0h last=%0b addr=%h",
                  mux_slv[0].r_resp, mux_slv[0].r_last, addr);
    data = mux_slv[0].r_data;
    @(negedge clk);
    r_ready_en = 1'b1;
    tick;
    @(negedge clk);
    r_ready_en = 1'b0;
  endtask

  function automatic logic [31:0] fp32_whole(input int v);
    int unsigned mag, exp;
    logic [31:0] norm;
    if (v == 0) return 32'd0;
    mag = (v < 0) ? unsigned'(-v) : unsigned'(v);
    exp = 0;
    for (int b = 0; b < 31; b++)
      if ((mag >> b) != 0) exp = unsigned'(b);
    norm = mag << (23 - exp);
    return {v < 0, 8'(127 + exp), norm[22:0]};
  endfunction

  // ---------------------------------------------------------------------------
  // WIDE-EXPONENT DATA CLASS.  The envelope is a pure function of the TARGET
  // format, which is what makes every element provably exact in it:
  //   * mant_max is the target's explicit mantissa bit count expressed as a
  //     bound (BF16 7 bits -> 127, FP16 10 bits -> 1023).  INT4 has no mantissa
  //     field at all, so its only usable ladder is 1 * 2^e with |v| <= 7; that
  //     degenerate case is deliberate -- integer accumulation is exact at ANY
  //     magnitude, so the integer pair must stay bit-identical under this class
  //     too and is worth running as the control.
  //   * exp_step * (exp_slots - 1) is the top of the ladder, chosen so that
  //     mant_max << top stays inside the target's finite range (FP16 max finite
  //     is 65504 and 1023 << 6 = 65472) and, for INT4, inside -8..7.
  // Every value is a whole number: the exponents are all >= 0, so nothing here
  // needs a fractional operand path, and fp32_whole/encode_element/
  // element_exact_in take these values unchanged (the widest is 127 << 12 =
  // 520192, an FP32 exponent of 19, well inside their existing domain).
  function automatic int unsigned wide_mant_max(input logic [2:0] dst);
    case (dst)
      3'd1:    return 1;      // INT4: no mantissa field, ladder is 1 * 2^e
      3'd5:    return 1023;   // FP16 keeps 10 explicit mantissa bits
      3'd6:    return 127;    // BF16 keeps 7
      default: return 1;
    endcase
  endfunction

  function automatic int unsigned wide_exp_slots(input logic [2:0] dst);
    return (dst == 3'd1) ? 3 : 4;
  endfunction

  function automatic int unsigned wide_exp_step(input logic [2:0] dst);
    case (dst)
      3'd1:    return 1;   // 0,1,2   -> |v| <= 4, inside INT4's -8..7
      3'd5:    return 2;   // 0,2,4,6 -> 1023 << 6 = 65472 <= 65504 (FP16 max)
      3'd6:    return 4;   // 0,4,8,12
      default: return 0;
    endcase
  endfunction

  // The A and B ladders use different mantissa and exponent mixes so a product
  // pairs a large operand with a small one as often as not; that is what puts
  // terms of very different magnitude inside ONE reduction window.
  function automatic int wide_a_value(input int unsigned r, t);
    int unsigned m, e;
    int v;
    m = 1 + ((r * 13 + t * 29 + (r / 2) * 7) % wide_mant_max(wide_exp_dst));
    e = wide_exp_step(wide_exp_dst) * ((t + r) % wide_exp_slots(wide_exp_dst));
    v = int'(m << e);
    return ((r + t / 2) % 2 != 0) ? -v : v;
  endfunction

  function automatic int wide_b_value(input int unsigned c, t);
    int unsigned m, e;
    int v;
    m = 1 + ((c * 17 + t * 23 + (c / 3) * 11) % wide_mant_max(wide_exp_dst));
    e = wide_exp_step(wide_exp_dst) * ((t * 3 + c) % wide_exp_slots(wide_exp_dst));
    v = int'(m << e);
    return ((c + t / 3) % 2 != 0) ? -v : v;
  endfunction

  function automatic int a_value(input int unsigned i, r, t);
    int v;
    if (wide_exp_data) return wide_a_value(r, t);
    if (!signed_data) return 1;
    v = 1 + int'((i * 3 + r * 2 + t * (1 + r % 3) + (r / 3) * (t / 2)) % 7);
    return ((r + t / 3 + i) % 2 != 0) ? -v : v;
  endfunction

  function automatic int b_value(input int unsigned owner, c, t, version);
    int v;
    if (wide_exp_data) return wide_b_value(c, t);
    if (!signed_data) return 1;
    v = 1 + int'((owner * 2 + c * 3 + t * (1 + c % 4) + (c / 4) * (t / 3) + version * 2) % 7);
    return ((c + t / 5 + version + owner) % 2 != 0) ? -v : v;
  endfunction

  function automatic logic [31:0] encode_element(input int v, input logic [2:0] fmt);
    logic [31:0] f;
    f = fp32_whole(v);
    case (fmt)
      3'd0: return {24'd0, 8'(v)};
      3'd1: return {28'd0, 4'(v)};
      3'd3: return 32'({f[31], 4'(int'(f[30:23]) - 120), f[22:20]});
      3'd4: return 32'({f[31], 5'(int'(f[30:23]) - 112), f[22:21]});
      3'd5: return 32'({f[31], 5'(int'(f[30:23]) - 112), f[22:13]});
      3'd6: return 32'(f[31:16]);
      default: return f;
    endcase
  endfunction

  function automatic int unsigned element_bits(input logic [2:0] fmt);
    case (fmt)
      3'd1: return 4;
      3'd5, 3'd6: return 16;
      3'd7: return 32;
      default: return 8;
    endcase
  endfunction

  // Is the whole number `v` representable in `fmt` with NOTHING discarded?
  // This is the proof `lossless_proven` stands for, done for real rather than
  // assumed: the integer formats need the value inside their two's-complement
  // range, and every narrow float format needs each FP32 mantissa bit it drops
  // to already be zero.  The exponent never binds for the small whole numbers
  // this harness uses (|v| <= 7 is exponent 0..2, inside every format's range),
  // and fp32_whole only ever emits normals, so the mantissa test is sufficient.
  function automatic bit element_exact_in(input int v, input logic [2:0] fmt);
    logic [31:0] f;
    f = fp32_whole(v);
    case (fmt)
      3'd0:    return v >= -128 && v <= 127;   // INT8
      3'd1:    return v >= -8 && v <= 7;       // INT4
      3'd5:    return f[12:0] == 13'd0;        // FP16 keeps 10 of 23 mantissa bits
      3'd6:    return f[15:0] == 16'd0;        // BF16 keeps 7
      3'd7:    return 1'b1;                    // FP32 is the source domain
      3'd3:    return f[19:0] == 20'd0;        // FP8 E4M3 keeps 3
      3'd4:    return f[20:0] == 21'd0;        // FP8 E5M2 keeps 2
      default: return 1'b0;                    // SP24 is not a supported target
    endcase
  endfunction

  // Operand read beats for ONE job.  A contributes m rows and B contributes n
  // rows, each of words_per_row beats, and a resident operand contributes none.
  // The two terms vanish INDEPENDENTLY: A and B are separate keys, so an
  // expectation that can only lose the B term (as this harness assumed while
  // only resident B existed) is wrong the moment an A lease is held.
  function automatic int unsigned job_read_beats(
      input int unsigned m, n, k, input logic [2:0] fmt, input bit a_hit, b_hit
  );
    return (m * (a_hit ? 0 : 1) + n * (b_hit ? 0 : 1)) *
           ((k * element_bits(fmt) + 63) / 64);
  endfunction

  // C write beats for ONE job.  A C row is n 32-bit words, so it pairs into
  // n/2 64-bit beats only when n is EVEN; an odd row costs one beat per element
  // because the tail word cannot be paired with the next row's head.  The
  // shorthand `m * n / 2` that the phase experiments used is therefore a
  // property of the square 8x8 default and not a law -- it is wrong for any odd
  // n, and it happens to survive an odd m.  This is the same expression
  // directed_job has always used, factored out so no site can disagree.
  function automatic int unsigned job_write_beats(input int unsigned m, n);
    return m * ((n % 2 != 0) ? n : n / 2);
  endfunction

  function automatic logic [31:0] golden_element(input int unsigned i, r, c);
    int sum;
    sum = 0;
    for (int unsigned t = 0; t < k_v[i]; t++)
      sum += a_value(i, r, t) * b_value(b_owner_v[i], c, t, b_version_v[i]);
    return (numfmt_v[i] inside {3'd0, 3'd1}) ? 32'(sum) : fp32_whole(sum);
  endfunction

  function automatic logic [63:0] eng_a(input int unsigned i);
    return ENG_BASE + 64'(i) * 64'(SLOT);
  endfunction

  // Store one engine's operands.  shared_b routes every engine's ptr_b at
  // engine 0's B region; only engine 0's B is written in that mode.
  task automatic store_engine(
      input int unsigned       i,
      input logic [DATA_W-1:0] pattern,
      input int unsigned       bpe,
      input logic              is_packed,
      input logic              shared_b
  );
    int unsigned r, c, w, words_per_row, bits, elems_per_word, t;
    logic [63:0] a_base, b_base, data;
    logic [31:0] k_bytes, a_stride, b_stride;
    bits = is_packed ? 4 : bpe * 8;
    assert (bits == element_bits(numfmt_v[i])) else $fatal(1, "staging format width");
    elems_per_word = 64 / bits;
    k_bytes = (k_v[i] * bits + 7) / 8;
    a_stride = (32'(lda_v[i]) * bits + 7) / 8;
    b_stride = (32'(ldb_v[i]) * bits + 7) / 8;
    assert ((m_v[i] - 1) * a_stride + k_bytes <= OFF_B &&
            (n_v[i] - 1) * b_stride + k_bytes <= OFF_C - OFF_B)
      else $fatal(1, "eng%0d staging exceeds slot", i);
    words_per_row = (k_bytes + 32'd7) / 32'd8;
    for (r = 0; r < m_v[i]; r++) begin
      a_base = pa_v[i] + (64'(r) * 64'(a_stride));
      for (w = 0; w < words_per_row; w++) begin
        data = signed_data ? 64'd0 : pattern;
        if (signed_data)
          for (int unsigned e = 0; e < elems_per_word; e++) begin
            t = w * elems_per_word + e;
            if (t < k_v[i]) data |= 64'(encode_element(a_value(i, r, t), numfmt_v[i])) << (e * bits);
          end
        wr8(a_base + (64'(w) << 3), data);
      end
    end
    if (!shared_b || i == 0) begin
      for (c = 0; c < n_v[i]; c++) begin
        b_base = pb_v[i] + (64'(c) * 64'(b_stride));
        for (w = 0; w < words_per_row; w++) begin
          data = signed_data ? 64'd0 : pattern;
          if (signed_data)
            for (int unsigned e = 0; e < elems_per_word; e++) begin
              t = w * elems_per_word + e;
              if (t < k_v[i])
                data |= 64'(encode_element(b_value(b_owner_v[i], c, t, b_version_v[i]),
                                           numfmt_v[i])) << (e * bits);
            end
          wr8(b_base + (64'(w) << 3), data);
        end
      end
    end
  endtask

  // Serial phase: engines one at a time.  Returns the summed wall cycles of
  // the N individual start->done windows in `total_cy`.
  task automatic run_one(input int unsigned i, input bit expected_hit,
                         input bit expected_hit_a, input bit expected_error,
                         output int unsigned wall_cy);
    logic [31:0] t0;
    @(negedge clk);
    cycles = 0;
    clr_seen = 1'b1;
    tick;
    @(negedge clk);
    clr_seen = 1'b0;
    while (!ready_v[i] && cycles < TO_RSP) tick;
    if (!ready_v[i]) $fatal(1, "serial eng%0d never ready", i);
    @(negedge clk);
    t0 = free_cy;
    start_v[i] = 1'b1;
    tick;
    @(negedge clk);
    start_v[i] = 1'b0;
    cycles = 0;
    while (!done_seen[i] && cycles < TO_RSP) tick;
    if (!done_seen[i]) $fatal(1, "serial eng%0d timeout", i);
    assert (err_v[i] == expected_error)
      else $fatal(1, "serial eng%0d err=%b expected=%b", i, err_v[i], expected_error);
    assert (reuse_hit_v[i] == expected_hit)
      else $fatal(1, "serial eng%0d reuse_hit=%b expected=%b", i, reuse_hit_v[i], expected_hit);
    assert (reuse_hit_a_v[i] == expected_hit_a)
      else $fatal(1, "serial eng%0d reuse_hit_a=%b expected=%b", i, reuse_hit_a_v[i],
                  expected_hit_a);
    wall_cy = free_cy - t0;
  endtask

  task automatic run_serial(input bit expected_hit, output int unsigned total_cy,
                            output int unsigned total_r, total_w);
    int unsigned wall_cy;
    total_cy = 0;
    total_r = 0;
    total_w = 0;
    for (int unsigned i = 0; i < N_ENGINES; i++) begin
      run_one(i, expected_hit, 1'b0, 1'b0, wall_cy);
      total_cy += wall_cy;
      total_r += pmu_r_v[i];
      total_w += pmu_w_v[i];
    end
  endtask

  // Concurrent phase: one start pulse to every engine on the same cycle, wall
  // time to the LAST done pulse.
  task automatic run_concurrent(input bit expected_hit, output int unsigned wall_cy,
                                output int unsigned total_r, total_w);
    logic [31:0] t0;
    wall_cy = 0;
    total_r = 0;
    total_w = 0;
    @(negedge clk);
    cycles = 0;
    clr_seen = 1'b1;
    tick;
    @(negedge clk);
    clr_seen = 1'b0;
    while (ready_v != {N_ENGINES{1'b1}} && cycles < TO_RSP) tick;
    if (ready_v != {N_ENGINES{1'b1}})
      $fatal(1, "concurrent: not all engines ready ready=%b", ready_v);
    @(negedge clk);
    t0 = free_cy;
    start_v = {N_ENGINES{1'b1}};
    tick;
    @(negedge clk);
    start_v = '0;
    cycles = 0;
    while (done_seen != {N_ENGINES{1'b1}} && cycles < TO_RSP) tick;
    if (done_seen != {N_ENGINES{1'b1}})
      $fatal(1, "concurrent timeout done=%b", done_seen);
    if (err_v != '0) $fatal(1, "concurrent err=%b", err_v);
    assert (reuse_hit_v == {N_ENGINES{expected_hit}})
      else $fatal(1, "concurrent reuse_hit=%b expected=%b", reuse_hit_v, expected_hit);
    // The phase experiments never take an A lease, so a resident-A hit here
    // would mean the engine skipped a load nobody asked it to skip.
    assert (reuse_hit_a_v == '0)
      else $fatal(1, "concurrent reuse_hit_a=%b without an A lease", reuse_hit_a_v);
    wall_cy = free_cy - t0;
    for (int unsigned i = 0; i < N_ENGINES; i++) begin
      total_r += pmu_r_v[i];
      total_w += pmu_w_v[i];
    end
  endtask

  // Golden check: sample first and last 8 B of every C row per engine.
  task automatic check_engine(input int unsigned i);
    logic [DATA_W-1:0] got;
    logic [31:0] golden;
    for (int unsigned e = 0; e < m_v[i] * n_v[i]; e += 2) begin
      rd8(pc_v[i] + 64'(e * 4), got);
      for (int unsigned lane = 0; lane < 2; lane++) begin
        if (e + lane < m_v[i] * n_v[i]) begin
          golden = golden_element(i, (e + lane) / n_v[i], (e + lane) % n_v[i]);
          if (got[lane * 32 +: 32] !== golden) begin
            $error("eng%0d fmt=%0d C row%0d col%0d exp=%h got=%h", i, numfmt_v[i],
                   (e + lane) / n_v[i], (e + lane) % n_v[i], golden, got[lane * 32 +: 32]);
            errors++;
          end
        end
      end
    end
  endtask

  task automatic check_golden(input logic [2:0] numfmt);
    for (int unsigned i = 0; i < N_ENGINES; i++) begin
      assert (numfmt_v[i] == numfmt) else $fatal(1, "check format mismatch");
      check_engine(i);
    end
  endtask

  // The poison a C element pair is pre-loaded with, and the 32-bit word of it
  // that one element sees.  Factored out of poison_engine (whose value is
  // unchanged) so a reader can ask "is this word still poison, i.e. did the
  // engine never write it?" against exactly the same constant.
  function automatic logic [63:0] poison_pair(input int unsigned i, e);
    return 64'hDEAD_BEEF_BADC_0FFE ^ 64'(i * 256 + e);
  endfunction

  function automatic logic [31:0] poison_word(input int unsigned i, e, lane);
    logic [63:0] p;
    p = poison_pair(i, e);
    return p[lane * 32 +: 32];
  endfunction

  task automatic poison_engine(input int unsigned i);
    for (int unsigned e = 0; e < m_v[i] * n_v[i]; e += 2)
      wr8(pc_v[i] + 64'(e * 4), poison_pair(i, e));
  endtask

  task automatic poison_all;
    for (int unsigned i = 0; i < N_ENGINES; i++) poison_engine(i);
  endtask

  task automatic invalidate_all;
    @(negedge clk);
    invalidate_v = '1;
    tick;
    @(negedge clk);
    invalidate_v = '0;
  endtask

  // The A invalidation is a separate port: flushing resident B must not flush
  // resident A, so the B-side cases below keep using invalidate_all alone.
  task automatic invalidate_a_all;
    @(negedge clk);
    invalidate_a_v = '1;
    tick;
    @(negedge clk);
    invalidate_a_v = '0;
  endtask

  task automatic configure_engine(input int unsigned i, input logic [2:0] fmt,
                                  input bit shared_b);
    @(negedge clk);
    numfmt_v[i] = fmt;
    m_v[i] = JOB_M;
    n_v[i] = JOB_N;
    k_v[i] = JOB_K;
    lda_v[i] = 16'(JOB_K);
    ldb_v[i] = 16'(JOB_K);
    pa_v[i] = eng_a(i);
    pb_v[i] = eng_a(shared_b ? 0 : i) + 64'(OFF_B);
    pc_v[i] = eng_a(i) + 64'(OFF_C);
    b_owner_v[i] = shared_b ? 0 : i;
    b_version_v[i] = 0;
    epoch_v[i]++;
    epoch_a_v[i]++;
    lease_v[i] = 1'b1;
    // Reconfiguration never carries an A lease: the B-side and phase
    // experiments must stay byte-for-byte the measurements they were, so the A
    // path is only ever armed by the A cases that explicitly ask for it.
    lease_a_v[i] = 1'b0;
    permission_v[i] = 1'b1;
    window_v[i] = 1'b1;
    policy_enable_v[i] = 1'b1;
    level_v[i] = 4'd1;
  endtask

  task automatic measured_phase(input bit concurrent_run, input bit expected_hit,
                                input logic [2:0] fmt, output int unsigned wall_cy,
                                output int unsigned read_beats, write_beats);
    poison_all();
    if (concurrent_run) run_concurrent(expected_hit, wall_cy, read_beats, write_beats);
    else run_serial(expected_hit, wall_cy, read_beats, write_beats);
    check_golden(fmt);
  endtask

  // One full experiment for one format in one sharing mode: stage, serial,
  // golden, concurrent, golden.  Operand data persists between phases so the
  // second phase reuses the staged image (all-ones inputs are never written
  // by the engines -- only C is, and C is re-checked after each phase).
  task automatic run_experiment(
      input logic [2:0]        numfmt,
      input logic [DATA_W-1:0] pattern,
      input int unsigned       bpe,
      input logic              is_packed,
      input logic              shared_b
  );
    int unsigned base_cy [2], base_r [2], base_w [2];
    int unsigned warm_cy [2], warm_r [2], warm_w [2];
    int unsigned cold_cy, cold_r, cold_w, cy, rb, wb, expected_r, expected_w, base_prime_cy;
    int unsigned warm_expected_r;
    for (int unsigned i = 0; i < N_ENGINES; i++) begin
      configure_engine(i, numfmt, shared_b);
      store_engine(i, pattern, bpe, is_packed, shared_b);
    end
    // These phases lease B only (configure_engine leaves the A lease low), so
    // the warm expectation loses the B term and keeps the whole A term.
    expected_r = N_ENGINES * job_read_beats(JOB_M, JOB_N, JOB_K, numfmt, 1'b0, 1'b0);
    warm_expected_r = N_ENGINES * job_read_beats(JOB_M, JOB_N, JOB_K, numfmt, 1'b0, VA_TURBO);
    expected_w = N_ENGINES * job_write_beats(JOB_M, JOB_N);
    for (int unsigned mode = 0; mode < 2; mode++) begin
      base_cy[mode] = 0;
      base_r[mode] = 0;
      base_w[mode] = 0;
      warm_cy[mode] = 0;
      warm_r[mode] = 0;
      warm_w[mode] = 0;
      @(negedge clk);
      permission_v = '0;
      for (int unsigned rep = 0; rep < REPEATS; rep++) begin
        measured_phase(mode != 0, 1'b0, numfmt, cy, rb, wb);
        assert (rb == expected_r && wb == expected_w)
          else $fatal(1, "baseline traffic fmt=%0d r=%0d/%0d w=%0d/%0d",
                      numfmt, rb, expected_r, wb, expected_w);
        base_cy[mode] += cy;
        base_r[mode] += rb;
        base_w[mode] += wb;
      end
      measured_phase(mode != 0, 1'b0, numfmt, base_prime_cy, rb, wb);
      assert (rb == expected_r && wb == expected_w)
        else $fatal(1, "matched cold-batch baseline traffic");
      invalidate_all();
      @(negedge clk);
      permission_v = '1;
      measured_phase(mode != 0, 1'b0, numfmt, cold_cy, cold_r, cold_w);
      assert (cold_r == expected_r && cold_w == expected_w)
        else $fatal(1, "cold prime traffic fmt=%0d", numfmt);
      for (int unsigned rep = 0; rep < REPEATS; rep++) begin
        measured_phase(mode != 0, VA_TURBO, numfmt, cy, rb, wb);
        assert (rb == warm_expected_r && wb == expected_w)
          else $fatal(1, "warm traffic fmt=%0d r=%0d/%0d w=%0d", numfmt, rb,
                      warm_expected_r, wb);
        warm_cy[mode] += cy;
        warm_r[mode] += rb;
        warm_w[mode] += wb;
      end
      // Stated against the per-phase expectations rather than as a ratio: the
      // old "warm is half of baseline" factor was only true because m == n and
      // because B was the only operand that could go resident.
      assert (base_r[mode] == REPEATS * expected_r &&
              warm_r[mode] == REPEATS * warm_expected_r &&
              warm_w[mode] == base_w[mode]) else $fatal(1, "reuse PMU sum mismatch");
      $display("REUSE fmt=%0d shared_b=%0d signed=%0d enabled=%0d eng=%0d concurrent=%0d repeats=%0d baseline=%0d cold_prime=%0d warm=%0d reuse_including_prime=%0d warm_speedup_x1000=%0d base_r=%0d cold_r=%0d warm_r=%0d base_w=%0d cold_w=%0d warm_w=%0d baseline_including_prime=%0d batches_including_prime=%0d",
               numfmt, shared_b, signed_data, VA_TURBO, N_ENGINES, mode, REPEATS,
               base_cy[mode], cold_cy, warm_cy[mode], cold_cy + warm_cy[mode],
               warm_cy[mode] != 0 ? base_cy[mode] * 1000 / warm_cy[mode] : 0,
               base_r[mode], cold_r, warm_r[mode], base_w[mode], cold_w, warm_w[mode],
               base_cy[mode] + base_prime_cy, REPEATS + 1);
    end
    $display("CONC fmt=%0d shared_b=%0d signed=%0d eng=%0d macs_total=%0d repeats=%0d serial=%0d concurrent=%0d speedup_x1000=%0d warm_serial=%0d warm_concurrent=%0d warm_speedup_x1000=%0d serial_r=%0d concurrent_r=%0d serial_w=%0d concurrent_w=%0d",
             numfmt, shared_b, signed_data, N_ENGINES, REPEATS * N_ENGINES * JOB_M * JOB_N * JOB_K,
             REPEATS, base_cy[0], base_cy[1], base_cy[1] != 0 ? base_cy[0] * 1000 / base_cy[1] : 0,
             warm_cy[0], warm_cy[1], warm_cy[1] != 0 ? warm_cy[0] * 1000 / warm_cy[1] : 0,
             base_r[0], base_r[1], base_w[0], base_w[1]);
    $display("CONC_PMU fmt=%0d shared_b=%0d eng_cycles=%p r=%p w=%p hits=%b",
             numfmt, shared_b, pmu_cy_v, pmu_r_v, pmu_w_v, reuse_hit_v);
  endtask

  // The experiment table.  Entries 0..10 are the all-ones set and 11..17 the
  // signed set, in the original order.
  function automatic logic [2:0] exp_fmt(input int unsigned e);
    case (e)
      0, 1, 11: return 3'd0;
      2, 3, 12: return 3'd1;
      4, 5, 15: return 3'd5;
      6, 7, 17: return 3'd7;
      8, 13:    return 3'd3;
      9, 14:    return 3'd4;
      default:  return 3'd6;
    endcase
  endfunction

  function automatic bit exp_shared(input int unsigned e);
    return e inside {1, 3, 5, 7, 9, 12, 14, 16};
  endfunction

  function automatic bit exp_signed(input int unsigned e);
    return e >= 11;
  endfunction

  function automatic logic [DATA_W-1:0] exp_pattern(input logic [2:0] fmt);
    case (fmt)
      3'd1:    return INT4_1;
      3'd3:    return FP8_E4M3_1;
      3'd4:    return FP8_E5M2_1;
      3'd5:    return FP16_1;
      3'd6:    return BF16_1;
      3'd7:    return FP32_1;
      default: return ONES8;
    endcase
  endfunction

  function automatic int unsigned exp_bpe(input logic [2:0] fmt);
    return (element_bits(fmt) + 7) / 8;
  endfunction

  function automatic int unsigned opp_fraction(input int unsigned idx);
    case (idx)
      0: return 0;
      1: return 2;
      2: return 4;
      3: return 6;
      default: return 7;
    endcase
  endfunction

  // Which jobs of the sequence reuse the resident B.  Job 0 can never hit --
  // nothing is resident at sequence start -- so the `hits` hits are spread
  // evenly over jobs 1..JOBS_PER_SEQ-1 by the integer-slope test below, which
  // steps exactly `hits` times across that range.
  function automatic bit opp_want_hit(input int unsigned job, hits);
    if (job == 0) return 1'b0;
    return ((job * hits) / (JOBS_PER_SEQ - 1)) >
           (((job - 1) * hits) / (JOBS_PER_SEQ - 1));
  endfunction

  // One opportunistic job stream on engine 0: JOBS_PER_SEQ jobs, `hits` of
  // which reuse the resident B while the rest deliberately change B identity
  // (bump b_version + epoch, restage through store_engine) so residency must
  // miss.  The feature stays fully enabled throughout -- this measures a mixed
  // weight stream, not a disabled recipe.  b_version feeds b_value, so every
  // restage moves the golden C as well, which check_engine re-verifies.
  task automatic run_opportunistic(
      input logic [2:0]        numfmt,
      input logic [DATA_W-1:0] pattern,
      input int unsigned       bpe,
      input logic              is_packed,
      input int unsigned       hits
  );
    int unsigned cy, expected_r, expected_w;
    bit want_hit;
    assert (hits < JOBS_PER_SEQ)
      else $fatal(1, "opportunistic hits=%0d leaves no cold job", hits);
    configure_engine(0, numfmt, 1'b0);
    invalidate_all();
    opp_cy = 0;
    opp_r = 0;
    opp_w = 0;
    opp_hit_count = 0;
    expected_w = job_write_beats(JOB_M, JOB_N);
    for (int unsigned j = 0; j < JOBS_PER_SEQ; j++) begin
      want_hit = opp_want_hit(j, hits) && VA_TURBO;
      if (!opp_want_hit(j, hits)) begin
        @(negedge clk);
        b_version_v[0]++;
        epoch_v[0]++;
        store_engine(0, pattern, bpe, is_packed, 1'b0);
      end
      poison_engine(0);
      run_one(0, want_hit, 1'b0, 1'b0, cy);
      check_engine(0);
      // No A lease is taken in this stream, so only the B term may vanish.
      expected_r = job_read_beats(JOB_M, JOB_N, JOB_K, numfmt, 1'b0, want_hit);
      assert (pmu_r_v[0] == expected_r && pmu_w_v[0] == expected_w)
        else $fatal(1, "opportunistic fmt=%0d job%0d traffic r=%0d/%0d w=%0d/%0d",
                    numfmt, j, pmu_r_v[0], expected_r, pmu_w_v[0], expected_w);
      opp_cy += cy;
      opp_r += pmu_r_v[0];
      opp_w += pmu_w_v[0];
      opp_hit_count += reuse_hit_v[0] ? 32'd1 : 32'd0;
    end
    assert (opp_hit_count == (VA_TURBO ? hits : 0))
      else $fatal(1, "opportunistic fmt=%0d hits=%0d counted=%0d", numfmt, hits,
                  opp_hit_count);
  endtask

  // Hit-fraction sweep for one format.  The all-miss sequence is the speedup
  // reference; it must be the first fraction so the reference exists.
  task automatic run_opportunistic_sweep(
      input logic [2:0]        numfmt,
      input logic [DATA_W-1:0] pattern,
      input int unsigned       bpe,
      input logic              is_packed
  );
    int unsigned ref_cy, prev_cy, prev_r, prev_hits, hits;
    @(negedge clk);
    // A forced miss only moves the golden when the operands depend on
    // b_version, so the mixed stream is only honest with signed data.
    signed_data = 1'b1;
    ref_cy = 0;
    prev_cy = 0;
    prev_r = 0;
    prev_hits = 0;
    for (int unsigned f = 0; f < OPP_FRACTIONS; f++) begin
      hits = opp_fraction(f);
      run_opportunistic(numfmt, pattern, bpe, is_packed, hits);
      if (f == 0) begin
        assert (hits == 0) else $fatal(1, "opportunistic sweep needs an all-miss reference");
        ref_cy = opp_cy;
      end else begin
        assert (hits > prev_hits) else $fatal(1, "opportunistic fractions must ascend");
        assert (opp_cy <= prev_cy)
          else $fatal(1, "opportunistic fmt=%0d hits=%0d cycles=%0d above hits=%0d cycles=%0d",
                      numfmt, hits, opp_cy, prev_hits, prev_cy);
        if (VA_TURBO)
          assert (opp_r < prev_r)
            else $fatal(1, "opportunistic fmt=%0d hits=%0d r=%0d not below hits=%0d r=%0d",
                        numfmt, hits, opp_r, prev_hits, prev_r);
        else
          assert (opp_cy == ref_cy && opp_r == prev_r)
            else $fatal(1, "opportunistic disabled fmt=%0d hits=%0d cycles=%0d/%0d r=%0d/%0d",
                        numfmt, hits, opp_cy, ref_cy, opp_r, prev_r);
      end
      $display("OPP fmt=%0d hits=%0d of=%0d enabled=%0d cycles=%0d r=%0d w=%0d hit_count=%0d expected_hits=%0d speedup_x1000=%0d",
               numfmt, hits, JOBS_PER_SEQ, VA_TURBO, opp_cy, opp_r, opp_w,
               opp_hit_count, VA_TURBO ? hits : 0,
               opp_cy != 0 ? ref_cy * 1000 / opp_cy : 0);
      prev_cy = opp_cy;
      prev_r = opp_r;
      prev_hits = hits;
    end
  endtask

  // `want_hit_a` defaults low so every B-side case below reads exactly as it did
  // when resident B was the only residency: those cases hold no A lease, so the
  // A term of the read-beat expectation can never vanish there.
  task automatic directed_job(input string name, input bit want_hit, input bit stage,
                              input bit want_hit_a = 1'b0);
    int unsigned cy, expected_r, expected_w;
    bit hit, hit_a;
    hit = VA_TURBO && want_hit;
    hit_a = VA_TURBO && want_hit_a;
    poison_engine(0);
    if (stage)
      store_engine(0, ONES8, (element_bits(numfmt_v[0]) + 7) / 8,
                   numfmt_v[0] == 3'd1, 1'b0);
    run_one(0, hit, hit_a, 1'b0, cy);
    check_engine(0);
    expected_r = job_read_beats(m_v[0], n_v[0], k_v[0], numfmt_v[0], hit_a, hit);
    expected_w = job_write_beats(m_v[0], n_v[0]);
    assert (pmu_r_v[0] == expected_r && pmu_w_v[0] == expected_w)
      else $fatal(1, "%s traffic r=%0d/%0d w=%0d/%0d", name, pmu_r_v[0], expected_r,
                  pmu_w_v[0], expected_w);
    $display("REUSE_CASE name=%s enabled=%0d hit=%0d hit_a=%0d cycles=%0d r=%0d w=%0d",
             name, VA_TURBO, reuse_hit_v[0], reuse_hit_a_v[0], cy, pmu_r_v[0], pmu_w_v[0]);
  endtask

  task automatic prime_directed;
    invalidate_all();
    directed_job("reprime", 1'b0, 1'b0);
    directed_job("rewarm", 1'b1, 1'b0);
  endtask

  task automatic run_directed;
    int unsigned cy;
    signed_data = 1'b1;
    configure_engine(0, 3'd0, 1'b0);
    invalidate_all();
    directed_job("cold_miss", 1'b0, 1'b1);
    directed_job("warm_hit", 1'b1, 1'b0);

    @(negedge clk);
    b_version_v[0]++;
    epoch_v[0]++;
    directed_job("changed_B_epoch", 1'b0, 1'b1);
    directed_job("changed_B_epoch_warm", 1'b1, 1'b0);

    @(negedge clk);
    pb_v[0] += 64'd128;
    b_version_v[0]++;
    directed_job("pointer_mismatch", 1'b0, 1'b1);
    directed_job("pointer_warm", 1'b1, 1'b0);

    @(negedge clk);
    ldb_v[0] = 16'd24;
    directed_job("stride_mismatch", 1'b0, 1'b1);
    directed_job("stride_warm", 1'b1, 1'b0);

    @(negedge clk);
    n_v[0] = 6;
    directed_job("n_shape_mismatch", 1'b0, 1'b1);
    directed_job("n_shape_warm", 1'b1, 1'b0);

    @(negedge clk);
    k_v[0] = 8;
    directed_job("k_shape_mismatch", 1'b0, 1'b1);
    directed_job("k_shape_warm", 1'b1, 1'b0);

    @(negedge clk);
    m_v[0] = 4;
    directed_job("m_not_B_key", 1'b1, 1'b0);

    @(negedge clk);
    numfmt_v[0] = 3'd3;
    directed_job("format_mismatch", 1'b0, 1'b1);
    directed_job("format_warm", 1'b1, 1'b0);

    invalidate_all();
    directed_job("explicit_invalidation", 1'b0, 1'b0);
    directed_job("explicit_invalidation_warm", 1'b1, 1'b0);

    @(negedge clk);
    permission_v[0] = 1'b0;
    directed_job("missing_plan_permission", 1'b0, 1'b0);
    @(negedge clk);
    permission_v[0] = 1'b1;
    prime_directed();

    @(negedge clk);
    window_v[0] = 1'b0;
    directed_job("stale_window", 1'b0, 1'b0);
    @(negedge clk);
    window_v[0] = 1'b1;
    prime_directed();

    @(negedge clk);
    level_v[0] = 4'd0;
    directed_job("runtime_level0", 1'b0, 1'b0);
    @(negedge clk);
    level_v[0] = 4'd1;
    prime_directed();

    @(negedge clk);
    policy_enable_v[0] = 1'b0;
    directed_job("runtime_disabled", 1'b0, 1'b0);
    @(negedge clk);
    policy_enable_v[0] = 1'b1;
    prime_directed();

    @(negedge clk);
    lease_v[0] = 1'b0;
    directed_job("missing_owner_lease", 1'b0, 1'b0);
    @(negedge clk);
    lease_v[0] = 1'b1;
    prime_directed();

    @(negedge clk);
    m_v[0] = 0;
    run_one(0, 1'b0, 1'b0, 1'b1, cy);
    @(negedge clk);
    m_v[0] = 4;
    directed_job("error_clears_residency", 1'b0, 1'b0);
    directed_job("error_recovery_warm", 1'b1, 1'b0);

    configure_engine(0, 3'd1, 1'b0);
    @(negedge clk);
    n_v[0] = 7;
    k_v[0] = 7;
    directed_job("INT4_odd_n_k_cold", 1'b0, 1'b1);
    directed_job("INT4_odd_n_k_warm", 1'b1, 1'b0);

    configure_engine(0, 3'd0, 1'b0);
    invalidate_all();
    @(negedge clk);
    pc_v[0] = pb_v[0];
    directed_job("C_alias_B_cold", 1'b0, 1'b1);
    @(negedge clk);
    pc_v[0] = eng_a(0) + 64'(OFF_C);
    b_version_v[0]++;
    directed_job("C_alias_B_not_resident", 1'b0, 1'b1);
    directed_job("C_alias_B_recovery_warm", 1'b1, 1'b0);
    @(negedge clk);
    pc_v[0] = pb_v[0];
    directed_job("C_alias_B_warm_refused", 1'b0, 1'b1);
    @(negedge clk);
    pc_v[0] = eng_a(0) + 64'(OFF_C);
    directed_job("C_alias_B_reload", 1'b0, 1'b1);
    directed_job("C_alias_B_rewarm", 1'b1, 1'b0);

    @(negedge clk);
    inject_r_error[0] = 1'b1;
    run_one(0, 1'b0, 1'b0, 1'b1, cy);
    @(negedge clk);
    inject_r_error[0] = 1'b0;
    directed_job("RRESP_error_invalidates", 1'b0, 1'b0);
    directed_job("RRESP_error_recovery_warm", 1'b1, 1'b0);
  endtask

  // ---------------------------------------------------------------------------
  // Directed resident-A set, the mirror of run_directed above.  It is a TABLE
  // and a runtime loop, not a list of literal calls, for the same compile-time
  // reason as the EXPERIMENTS table: one call site emits the job body once.
  //
  // `a_case_op` is the mutation applied immediately before case `c` runs, so
  // each row inherits the state the previous row left behind -- the order is
  // load-bearing, exactly as in the B-side sequence.
  function automatic int unsigned a_case_op(input int unsigned c);
    case (c)
      2:      return 1;   // bump the A epoch: same bytes, new generation
      4:      return 2;   // move ptr_a inside the A slot
      6:      return 3;   // widen lda without changing k
      8:      return 4;   // change m -- part of the A key
      10:     return 5;   // change k -- part of both keys
      12:     return 6;   // change n -- part of NEITHER A key term
      13:     return 7;   // change the element format
      15:     return 8;   // pulse reuse_a_invalidate_i
      17:     return 9;   // drop the A owner lease
      18:     return 10;  // restore the A owner lease
      19:     return 11;  // full reset to INT8 8x8x16 with both keys flushed
      20, 23: return 12;  // alias C over A
      21, 24: return 13;  // restore C to its own region
      26:     return 14;  // m=0: a job that must error
      27:     return 15;  // restore m
      29:     return 16;  // inject an AXI read error
      30:     return 17;  // stop injecting
      default: return 0;
    endcase
  endfunction

  function automatic string a_case_name(input int unsigned c);
    case (c)
      0:  return "A_cold_miss";
      1:  return "A_warm_hit";
      2:  return "A_changed_epoch";
      3:  return "A_changed_epoch_warm";
      4:  return "A_pointer_mismatch";
      5:  return "A_pointer_warm";
      6:  return "A_lda_stride_mismatch";
      7:  return "A_lda_stride_warm";
      8:  return "A_m_shape_mismatch";
      9:  return "A_m_shape_warm";
      10: return "A_k_mismatch";
      11: return "A_k_mismatch_warm";
      12: return "n_not_A_key";
      13: return "A_format_mismatch";
      14: return "A_format_warm";
      15: return "A_explicit_invalidation";
      16: return "A_explicit_invalidation_warm";
      17: return "A_missing_owner_lease";
      18: return "A_owner_lease_warm";
      19: return "A_reset_cold";
      20: return "C_alias_A_cold";
      21: return "C_alias_A_not_resident";
      22: return "C_alias_A_recovery_warm";
      23: return "C_alias_A_warm_refused";
      24: return "C_alias_A_reload";
      25: return "C_alias_A_rewarm";
      26: return "A_error_job";
      27: return "A_error_clears_residency";
      28: return "A_error_recovery_warm";
      29: return "A_RRESP_error_job";
      30: return "A_RRESP_error_invalidates";
      default: return "A_RRESP_error_recovery_warm";
    endcase
  endfunction

  // Case 12 is the point of the whole set: n is the B-side dimension, so
  // changing it must NOT cost the A residency, exactly as changing m does not
  // cost the B residency ("m_not_B_key" above).
  function automatic bit a_case_hit(input int unsigned c);
    return c inside {1, 3, 5, 7, 9, 11, 12, 14, 16, 18, 22, 25, 28, 31};
  endfunction

  // Restaging is required wherever the previous row moved the A image (new
  // pointer, new stride, new format) or wherever the previous job's C store
  // landed on top of A because C was aliased over it.
  function automatic bit a_case_stage(input int unsigned c);
    return c inside {0, 4, 6, 13, 19, 20, 21, 23, 24};
  endfunction

  function automatic bit a_case_error(input int unsigned c);
    return c inside {26, 29};
  endfunction

  // The B owner lease is held LOW for the whole set, so B is refetched by every
  // job and the only read beats that may vanish are A's.  That is what makes
  // each expectation attributable to the A key alone.
  task automatic run_directed_a;
    int unsigned cy;
    signed_data = 1'b1;
    configure_engine(0, 3'd0, 1'b0);
    invalidate_all();
    invalidate_a_all();
    @(negedge clk);
    lease_v[0] = 1'b0;
    lease_a_v[0] = 1'b1;
    for (int unsigned c = 0; c < A_CASES; c++) begin
      @(negedge clk);
      case (a_case_op(c))
        1:  epoch_a_v[0]++;
        2:  pa_v[0] += 64'd128;
        3:  lda_v[0] = 16'd24;
        4:  m_v[0] = 4;
        5:  k_v[0] = 8;
        6:  n_v[0] = 6;
        7:  numfmt_v[0] = 3'd3;
        8:  invalidate_a_all();
        9:  lease_a_v[0] = 1'b0;
        10: lease_a_v[0] = 1'b1;
        11: begin
          configure_engine(0, 3'd0, 1'b0);
          invalidate_all();
          invalidate_a_all();
          @(negedge clk);
          lease_v[0] = 1'b0;
          lease_a_v[0] = 1'b1;
        end
        12: pc_v[0] = pa_v[0];
        13: pc_v[0] = eng_a(0) + 64'(OFF_C);
        14: m_v[0] = 0;
        15: m_v[0] = JOB_M;
        16: inject_r_error[0] = 1'b1;
        17: inject_r_error[0] = 1'b0;
        default: ;
      endcase
      // An erroring job publishes nothing, so it is run bare: there is no
      // golden C to check and no traffic law to hold once err_o is set.
      if (a_case_error(c)) run_one(0, 1'b0, 1'b0, 1'b1, cy);
      else directed_job(a_case_name(c), 1'b0, a_case_stage(c), a_case_hit(c));
    end
  endtask

  // ---------------------------------------------------------------------------
  // The combined experiment: four residency points on ONE physical engine with
  // IDENTICAL work -- no reuse, A only, B only, both.  The leases are the only
  // thing that moves between points, so every difference in read beats is
  // attributable to residency and to nothing else.
  //
  // The points must run in this order: each point's job is what publishes the
  // residency the next point hits, and point 0 (no lease) is the reference.
  function automatic bit dual_reuse_a(input int unsigned p);
    return p inside {1, 3};
  endfunction

  function automatic bit dual_reuse_b(input int unsigned p);
    return p inside {2, 3};
  endfunction

  // One integer and one float format: the residency key carries numfmt, and the
  // float path is the one whose row is widest (FP32 k=16 is 8 beats a row).
  function automatic logic [2:0] dual_fmt(input int unsigned d);
    return (d == 0) ? 3'd0 : 3'd7;
  endfunction

  task automatic run_dual(
      input logic [2:0]        numfmt,
      input logic [DATA_W-1:0] pattern,
      input int unsigned       bpe,
      input logic              is_packed
  );
    int unsigned cy, rb, wb, expected_r, expected_w, ref_cy;
    int unsigned point_r [DUAL_POINTS];
    bit want_a, want_b;
    signed_data = 1'b1;
    configure_engine(0, numfmt, 1'b0);
    store_engine(0, pattern, bpe, is_packed, 1'b0);
    invalidate_all();
    invalidate_a_all();
    ref_cy = 0;
    expected_w = job_write_beats(JOB_M, JOB_N);
    for (int unsigned p = 0; p < DUAL_POINTS; p++) begin
      want_a = VA_TURBO && dual_reuse_a(p);
      want_b = VA_TURBO && dual_reuse_b(p);
      @(negedge clk);
      lease_a_v[0] = dual_reuse_a(p);
      lease_v[0]   = dual_reuse_b(p);
      poison_engine(0);
      run_one(0, want_b, want_a, 1'b0, cy);
      check_engine(0);
      rb = pmu_r_v[0];
      wb = pmu_w_v[0];
      expected_r = job_read_beats(JOB_M, JOB_N, JOB_K, numfmt, want_a, want_b);
      assert (rb == expected_r && wb == expected_w)
        else $fatal(1, "dual fmt=%0d point%0d traffic r=%0d/%0d w=%0d/%0d",
                    numfmt, p, rb, expected_r, wb, expected_w);
      point_r[p] = rb;
      if (p == 0) ref_cy = cy;
      $display("DUAL fmt=%0d reuse_a=%0d reuse_b=%0d cycles=%0d r=%0d w=%0d hit_a=%0d hit_b=%0d speedup_x1000=%0d",
               numfmt, dual_reuse_a(p), dual_reuse_b(p), cy, rb, wb,
               reuse_hit_a_v[0], reuse_hit_v[0], cy != 0 ? ref_cy * 1000 / cy : 0);
    end
    if (VA_TURBO) begin
      assert (point_r[1] < point_r[0] && point_r[2] < point_r[0])
        else $fatal(1, "dual fmt=%0d single-hit r not below no-reuse: a=%0d b=%0d none=%0d",
                    numfmt, point_r[1], point_r[2], point_r[0]);
      assert (point_r[3] < point_r[1] && point_r[3] < point_r[2])
        else $fatal(1, "dual fmt=%0d both-hit r=%0d not below single-hit a=%0d b=%0d",
                    numfmt, point_r[3], point_r[1], point_r[2]);
    end else
      assert (point_r[0] == point_r[1] && point_r[1] == point_r[2] &&
              point_r[2] == point_r[3])
        else $fatal(1, "dual disabled fmt=%0d read beats moved %p", numfmt, point_r);
  endtask

  // ---------------------------------------------------------------------------
  // LOSSLESS NARROWING.  A narrowing is lossless when every operand element is
  // exactly representable in the narrower format; the products are then the
  // SAME real numbers, so the narrowed job differs from the source job ONLY in
  // that the narrower format has a wider mac_step and therefore regroups the
  // FP32 accumulator folds.  Nothing in the datapath consumes the plan yet --
  // the narrowed job IS an ordinary native job at the target format, which is
  // precisely the claim -- so the measurement is: run the SAME logical matrix
  // twice, once native at src and once native at dst, and compare.
  //
  // The pairs.  One integer pair, which the selector calls VA_ARITH_EXACT and
  // which must therefore come out BIT-IDENTICAL, and the two float pairs, which
  // it calls VA_ARITH_REL at 1 ppm per window.
  function automatic logic [2:0] lossless_src(input int unsigned p);
    case (p)
      0:       return 3'd0;   // INT8
      default: return 3'd7;   // FP32
    endcase
  endfunction

  function automatic logic [2:0] lossless_dst(input int unsigned p);
    case (p)
      0:       return 3'd1;   // INT8 -> INT4
      1:       return 3'd6;   // FP32 -> BF16
      default: return 3'd5;   // FP32 -> FP16
    endcase
  endfunction

  // Capture (store_ref) or compare engine i's whole C tile in the RAW 32-bit
  // storage domain, accumulating the largest absolute difference in
  // `loss_max_diff`.
  //
  // Integer C is a two's-complement int32, so the difference of the raw words
  // IS the arithmetic difference and the metric needs no interpretation.  Float
  // C is IEEE FP32, whose bit pattern is monotone in magnitude within one sign,
  // so the unsigned difference of the raw words is the ULP distance -- the
  // natural integer metric for "how far apart are these two floats" and the one
  // LOSSLESS_FP_ULP_BOUND is stated in.  Both runs of a pair compute the same
  // real numbers, so no sign crossing can arise; were one to arise anyway the
  // raw distance is enormous and the bound fails loudly, which is correct.
  // It also counts, for the run it is looking at, how many C words are still the
  // poison value -- "this element was never written" is a different failure from
  // "this element is wrong", and the wide-exponent class has no golden with
  // which to catch the former.  A real result could in principle collide with
  // its poison word; that is a 2^-32 coincidence per element and the count is
  // only ever asserted to be zero, never used as a pass condition.
  task automatic compare_c(input int unsigned i, input bit store_ref,
                           input bit integer_domain);
    logic [DATA_W-1:0] got;
    logic [31:0] word;
    longint diff;
    int unsigned idx;
    loss_poison_elems = 0;
    for (int unsigned e = 0; e < m_v[i] * n_v[i]; e += 2) begin
      rd8(pc_v[i] + 64'(e * 4), got);
      for (int unsigned lane = 0; lane < 2; lane++) begin
        idx = e + lane;
        if (idx < m_v[i] * n_v[i]) begin
          word = got[lane * 32 +: 32];
          if (word === poison_word(i, e, lane)) loss_poison_elems++;
          if (store_ref) begin
            loss_ref_c[idx] = word;
          end else begin
            diff = integer_domain
                 ? (longint'($signed(word)) - longint'($signed(loss_ref_c[idx])))
                 : (longint'(word) - longint'(loss_ref_c[idx]));
            if (diff < 0) diff = -diff;
            if (diff != 0) loss_diff_elems++;
            if (diff > loss_max_diff) loss_max_diff = diff;
          end
        end
      end
    end
  endtask

  // One proven-exact narrowing pair on ONE engine.
  //
  // The operands are the signed fixture's small whole numbers in -7..7, which
  // are exact in FP32, FP16, BF16, INT8 and INT4 alike; that is not assumed but
  // asserted element by element through element_exact_in before either run, so
  // the narrowing really is lossless and any C difference is regrouping and
  // nothing else.  Neither run holds a lease, so both pay the FULL operand
  // traffic and the byte-ratio law below measures storage width and not a
  // skipped load.
  //
  // `wide` selects the second data class instead: sign * mantissa * 2^exponent
  // off the target's ladder (see wide_mant_max).  The exactness proof below is
  // the SAME proof over BOTH tiles -- it is what makes the class legitimate, and
  // if it ever stops firing the fixture is wrong and must be fixed, never the
  // proof relaxed.  What the wide class trades away is golden checking: the two
  // runs deliberately produce DIFFERENT answers, so no single golden can check
  // both, and golden_element cannot model FP32 windowed accumulation anyway.  In
  // exchange it gets regrouping OBSERVABILITY, which is the one thing the
  // small-integer class provably cannot deliver.  In its place the wide class
  // demands: no engine error, no C word left at its poison value (so both runs
  // really did write all 64 elements), a BOUNDED run-to-run difference, and a
  // NON-ZERO one.  The small-integer class keeps full element-by-element golden
  // checking and its max_abs_diff == 0 assertions, unchanged; so does the
  // integer pair under the wide class, whose golden is exact at any magnitude.
  task automatic run_lossless(input logic [2:0] src_fmt, input logic [2:0] dst_fmt,
                              input bit wide);
    int unsigned src_cy, dst_cy, src_r, dst_r, expected_w;
    bit both_int, golden_ok;
    both_int = policy_integer_format(src_fmt) && policy_integer_format(dst_fmt);
    signed_data = 1'b1;
    wide_exp_dst = dst_fmt;
    wide_exp_data = wide;
    // golden_element sums i32 products in the order it likes, which is exactly
    // what the hardware computes for an integer tile at ANY magnitude, so the
    // integer pair keeps its golden under both data classes.  Only the float
    // pairs under the wide class have no checkable golden.
    golden_ok = !wide || both_int;
    expected_w = job_write_beats(JOB_M, JOB_N);

    configure_engine(0, src_fmt, 1'b0);
    for (int unsigned r = 0; r < JOB_M; r++)
      for (int unsigned t = 0; t < JOB_K; t++)
        assert (element_exact_in(a_value(0, r, t), dst_fmt) &&
                element_exact_in(a_value(0, r, t), src_fmt))
          else $fatal(1, "A[%0d][%0d]=%0d is not exact in src=%0d dst=%0d",
                      r, t, a_value(0, r, t), src_fmt, dst_fmt);
    for (int unsigned c = 0; c < JOB_N; c++)
      for (int unsigned t = 0; t < JOB_K; t++)
        assert (element_exact_in(b_value(0, c, t, 0), dst_fmt) &&
                element_exact_in(b_value(0, c, t, 0), src_fmt))
          else $fatal(1, "B[%0d][%0d]=%0d is not exact in src=%0d dst=%0d",
                      c, t, b_value(0, c, t, 0), src_fmt, dst_fmt);

    @(negedge clk);
    lease_v[0]   = 1'b0;
    lease_a_v[0] = 1'b0;
    lossless_target_v[0] = dst_fmt;
    lossless_v[0] = 1'b1;
    invalidate_all();
    invalidate_a_all();
    store_engine(0, exp_pattern(src_fmt), exp_bpe(src_fmt), src_fmt == 3'd1, 1'b0);
    poison_engine(0);
    run_one(0, 1'b0, 1'b0, 1'b0, src_cy);
    if (golden_ok) check_engine(0);
    src_r = pmu_r_v[0];
    assert (pmu_w_v[0] == expected_w)
      else $fatal(1, "lossless src=%0d w=%0d/%0d", src_fmt, pmu_w_v[0], expected_w);
    compare_c(0, 1'b1, both_int);
    // (b) for the wide class: with no golden on the src run, "every element was
    // written" has to be checked directly.  run_one has already checked (a),
    // err_v[0] == 0.
    if (wide)
      assert (loss_poison_elems == 0)
        else $fatal(1, "LOSSLESS wide src=%0d: %0d C words never written (still poison)",
                    src_fmt, loss_poison_elems);

    // The dst run keeps the lossless request up with the SAME target, where
    // numfmt now equals it.  An equal-width pair buys no beats, so no NARROWING
    // may be claimed; the gen_eng assertion checks that outcome (refused for
    // the float pairs, demoted to the plain integer repack for the integer
    // pair) rather than this task having to know which arm wins.
    configure_engine(0, dst_fmt, 1'b0);
    @(negedge clk);
    lease_v[0]   = 1'b0;
    lease_a_v[0] = 1'b0;
    invalidate_all();
    invalidate_a_all();
    store_engine(0, exp_pattern(dst_fmt), exp_bpe(dst_fmt), dst_fmt == 3'd1, 1'b0);
    poison_engine(0);
    run_one(0, 1'b0, 1'b0, 1'b0, dst_cy);
    if (golden_ok) check_engine(0);
    dst_r = pmu_r_v[0];
    assert (pmu_w_v[0] == expected_w)
      else $fatal(1, "lossless dst=%0d w=%0d/%0d", dst_fmt, pmu_w_v[0], expected_w);
    loss_max_diff = 0;
    loss_diff_elems = 0;
    compare_c(0, 1'b0, both_int);
    @(negedge clk);
    lossless_v[0] = 1'b0;
    wide_exp_data = 1'b0;

    // Reported BEFORE the assertions so the measurement survives a failure --
    // a pair that violates the bound is a finding, and a finding with no number
    // attached is useless.
    //
    // The wide class prints its own line, tagged with the data class and
    // carrying differing_elements, so the small-integer line above stays exactly
    // the string it has always been and the two classes can never be confused
    // for one another in a log.
    if (!wide)
      $display("LOSSLESS src=%0d dst=%0d src_cycles=%0d dst_cycles=%0d speedup_x1000=%0d src_r=%0d dst_r=%0d max_abs_diff=%0d bit_identical=%0d",
               src_fmt, dst_fmt, src_cy, dst_cy,
               dst_cy != 0 ? src_cy * 1000 / dst_cy : 0, src_r, dst_r,
               loss_max_diff, loss_max_diff == 0);
    else
      $display("LOSSLESS data=wide_exponent src=%0d dst=%0d src_cycles=%0d dst_cycles=%0d speedup_x1000=%0d src_r=%0d dst_r=%0d max_abs_diff=%0d bit_identical=%0d differing_elements=%0d/%0d",
               src_fmt, dst_fmt, src_cy, dst_cy,
               dst_cy != 0 ? src_cy * 1000 / dst_cy : 0, src_r, dst_r,
               loss_max_diff, loss_max_diff == 0, loss_diff_elems, JOB_M * JOB_N);

    assert (src_r == job_read_beats(JOB_M, JOB_N, JOB_K, src_fmt, 1'b0, 1'b0) &&
            dst_r == job_read_beats(JOB_M, JOB_N, JOB_K, dst_fmt, 1'b0, 1'b0))
      else $fatal(1, "lossless src=%0d dst=%0d read beats %0d/%0d %0d/%0d",
                  src_fmt, dst_fmt, src_r,
                  job_read_beats(JOB_M, JOB_N, JOB_K, src_fmt, 1'b0, 1'b0), dst_r,
                  job_read_beats(JOB_M, JOB_N, JOB_K, dst_fmt, 1'b0, 1'b0));
    // Operand beats must drop by exactly the element-width ratio: that is the
    // entire mechanism by which a lossless narrowing buys anything.
    assert (src_r * element_bits(dst_fmt) == dst_r * element_bits(src_fmt))
      else $fatal(1, "lossless src=%0d dst=%0d beats %0d->%0d not the %0d:%0d byte ratio",
                  src_fmt, dst_fmt, src_r, dst_r, element_bits(src_fmt),
                  element_bits(dst_fmt));
    assert (dst_cy < src_cy)
      else $fatal(1, "lossless src=%0d dst=%0d cycles %0d -> %0d did not fall",
                  src_fmt, dst_fmt, src_cy, dst_cy);
    if (both_int)
      // Not a tolerance: integer -> integer has no rounding site anywhere, so
      // anything but zero here is a REAL defect in the claim, not noise.  This
      // holds under BOTH data classes -- i32 accumulation is exact at every
      // magnitude, so the wide-exponent ladder must not move it either; if it
      // ever does, that is a bug to report, not a tolerance to widen.
      assert (loss_max_diff == 0)
        else $fatal(1, "INT src=%0d -> dst=%0d is NOT bit-identical: max_abs_diff=%0d",
                    src_fmt, dst_fmt, loss_max_diff);
    else if (!wide)
      assert (loss_max_diff <= longint'(LOSSLESS_FP_ULP_BOUND))
        else $fatal(1, "lossless src=%0d dst=%0d differs by %0d ULP, above the %0d ULP (1 ppm) bound",
                    src_fmt, dst_fmt, loss_max_diff, LOSSLESS_FP_ULP_BOUND);
    else begin
      // (b) the dst run wrote every element too.
      assert (loss_poison_elems == 0)
        else $fatal(1, "LOSSLESS wide dst=%0d: %0d C words never written (still poison)",
                    dst_fmt, loss_poison_elems);
      // (c) BOUNDED.  Above this, the difference is no longer explicable as the
      // accumulator regrouping: it would mean the PRODUCTS changed, i.e. the
      // narrowing is not actually lossless in hardware.  That is the single most
      // important thing this experiment can find, so it fails loudly and says so.
      assert (loss_max_diff <= longint'(LOSSLESS_WIDE_ULP_BOUND))
        else $fatal(1, "LOSSLESS wide src=%0d dst=%0d differs by %0d ULP, above the %0d ULP regrouping bound -- too large for a fold reorder, so the NARROWING ITSELF LOOKS LOSSY (a product changed, not just the grouping)",
                    src_fmt, dst_fmt, loss_max_diff, LOSSLESS_WIDE_ULP_BOUND);
      // (d) NON-ZERO, for at least one element.  This is the point of the
      // fixture: a zero here means the ladder failed to make any fold round, so
      // the experiment measured nothing and the claim stays unwitnessed.
      assert (loss_diff_elems > 0)
        else $fatal(1, "LOSSLESS wide src=%0d dst=%0d is bit-identical: the exponent ladder did not make any accumulator fold round, so regrouping was NOT observed",
                    src_fmt, dst_fmt);
    end
  endtask

  // ---------------------------------------------------------------------------
  // DECODE RESIDENCY.  The four residency points of run_dual again -- cold, A,
  // B, both, one engine, identical work -- but on the shape a token-by-token
  // decode actually issues: ONE output row, m = 1, with n and k left on the
  // module parameters so it is the SAME weight matrix the square tile saw.
  //
  // Why the shape is the whole question.  The out-of-sample-validated cycle
  // model is
  //     cycles     = steps + beta(fmt) * read_beats + c
  //     steps      = m * n * ceil(row_bytes / PeLanes)
  //     read_beats = ceil(m * row_bytes / 8) + ceil(n * row_bytes / 8)
  // so STEPS grow with m*n while BEATS grow with m+n.  A square tile is
  // therefore step-dominated and a decode row is traffic-dominated, and within
  // that traffic B is n / (m + n) of every beat -- 8/9 = 888 thousandths at the
  // default n = 8, 16/17 = 941 at n = 16.  B is also the operand that is re-read
  // for every token while A is one row of activations.  If residency is worth
  // more where traffic dominates, the resident-B gain measured here must sit far
  // above the square tile's; if it comes out near the square figure instead, the
  // shape reasoning is simply wrong.  That is a finding, not a failure, so
  // NOTHING about the speedup is asserted and the numbers are printed BEFORE any
  // assertion runs.
  //
  // What IS asserted is only what must hold whichever way the measurement goes:
  //   * every residency point produces a BIT-IDENTICAL C tile to the cold point
  //     (skipping an operand load is not an arithmetic change) -- this is the
  //     real correctness content and it is checked on top of, not instead of,
  //     the per-point golden check;
  //   * the read beats of each point are exactly the cold beats minus the
  //     contribution of whichever operands went resident;
  //   * warm_b does not exceed cold;
  //   * the PMU reuse-hit flags come up exactly where the leases were taken.
  //
  // Table-driven with a runtime loop for the same compile-time reason as every
  // other multi-point experiment in this file: literal repeated call sites inline
  // into the single VlCoroutine and cost a serial multi-thousand-second build.
  localparam int unsigned DECODE_M    = 1;
  localparam int unsigned DECODE_FMTS = 4;

  // Two integer and two float widths, spanning the narrowest and the widest row
  // this harness can stage, so `beta` and row_bytes both move across the set.
  function automatic logic [2:0] decode_fmt(input int unsigned d);
    case (d)
      0:       return 3'd0;   // INT8
      1:       return 3'd1;   // INT4, the narrowest row
      2:       return 3'd5;   // FP16
      default: return 3'd7;   // FP32, the widest row
    endcase
  endfunction

  task automatic run_decode(input logic [2:0] numfmt);
    int unsigned cy, expected_w, cold_beats, a_beats, b_beats;
    int unsigned point_cy [DUAL_POINTS];
    int unsigned point_rb [DUAL_POINTS];
    int unsigned point_wb [DUAL_POINTS];
    int unsigned point_diff [DUAL_POINTS];
    bit point_hit_a [DUAL_POINTS];
    bit point_hit_b [DUAL_POINTS];
    bit want_a, want_b;
    signed_data = 1'b1;
    configure_engine(0, numfmt, 1'b0);
    // m is the ONLY thing that leaves the shared geometry.  configure_engine has
    // just set m/n/k from the parameters, so this is a one-field override and
    // every downstream helper (store_engine, poison_engine, check_engine,
    // compare_c) reads the new m out of m_v[0] with no duplication.
    @(negedge clk);
    m_v[0] = DECODE_M;
    store_engine(0, exp_pattern(numfmt), exp_bpe(numfmt), numfmt == 3'd1, 1'b0);
    invalidate_all();
    invalidate_a_all();
    // job_read_beats with the OTHER operand marked resident IS that operand's
    // contribution, so B's share needs no second formula that could disagree
    // with the expectation the assertions use.
    cold_beats = job_read_beats(DECODE_M, JOB_N, JOB_K, numfmt, 1'b0, 1'b0);
    a_beats    = job_read_beats(DECODE_M, JOB_N, JOB_K, numfmt, 1'b0, 1'b1);
    b_beats    = job_read_beats(DECODE_M, JOB_N, JOB_K, numfmt, 1'b1, 1'b0);
    // The general C law, not the square tile's `m * n / 2`: at m = 1 the whole
    // tile is one row, so nothing about m*n being even is available to lean on.
    expected_w = job_write_beats(DECODE_M, JOB_N);
    for (int unsigned p = 0; p < DUAL_POINTS; p++) begin
      want_a = VA_TURBO && dual_reuse_a(p);
      want_b = VA_TURBO && dual_reuse_b(p);
      @(negedge clk);
      lease_a_v[0] = dual_reuse_a(p);
      lease_v[0]   = dual_reuse_b(p);
      poison_engine(0);
      run_one(0, want_b, want_a, 1'b0, cy);
      check_engine(0);
      // Cross-run identity in the RAW storage domain against the cold tile.
      // check_engine already proves each point matches the golden; this proves
      // the four points match EACH OTHER bit for bit, which is the property
      // residency has to have and the one thing a tolerance could hide.
      loss_max_diff   = 0;
      loss_diff_elems = 0;
      compare_c(0, p == 0, policy_integer_format(numfmt));
      point_cy[p]    = cy;
      point_rb[p]    = pmu_r_v[0];
      point_wb[p]    = pmu_w_v[0];
      point_diff[p]  = loss_diff_elems;
      point_hit_a[p] = reuse_hit_a_v[0];
      point_hit_b[p] = reuse_hit_v[0];
    end

    // Printed before a single assertion below, so a violating case still reports
    // its numbers.  b_share is B's contribution over the MEASURED cold beats.
    $display("DECODE fmt=%0d m=%0d n=%0d k=%0d cold=%0d warm_a=%0d warm_b=%0d warm_both=%0d cold_r=%0d warm_b_r=%0d b_share_x1000=%0d",
             numfmt, DECODE_M, JOB_N, JOB_K, point_cy[0], point_cy[1],
             point_cy[2], point_cy[3], point_rb[0], point_rb[2],
             point_rb[0] != 0 ? b_beats * 1000 / point_rb[0] : 0);

    for (int unsigned p = 0; p < DUAL_POINTS; p++) begin
      assert (point_diff[p] == 0)
        else $fatal(1, "decode fmt=%0d point%0d changed C in %0d elements -- residency is not arithmetically neutral",
                    numfmt, p, point_diff[p]);
      assert (point_rb[p] == job_read_beats(DECODE_M, JOB_N, JOB_K, numfmt,
                                            VA_TURBO && dual_reuse_a(p),
                                            VA_TURBO && dual_reuse_b(p)) &&
              point_wb[p] == expected_w)
        else $fatal(1, "decode fmt=%0d point%0d traffic r=%0d/%0d w=%0d/%0d",
                    numfmt, p, point_rb[p],
                    job_read_beats(DECODE_M, JOB_N, JOB_K, numfmt,
                                   VA_TURBO && dual_reuse_a(p),
                                   VA_TURBO && dual_reuse_b(p)),
                    point_wb[p], expected_w);
      assert (point_hit_a[p] == (VA_TURBO && dual_reuse_a(p)) &&
              point_hit_b[p] == (VA_TURBO && dual_reuse_b(p)))
        else $fatal(1, "decode fmt=%0d point%0d hit_a=%0b hit_b=%0b expected %0b/%0b",
                    numfmt, p, point_hit_a[p], point_hit_b[p],
                    VA_TURBO && dual_reuse_a(p), VA_TURBO && dual_reuse_b(p));
    end
    assert (point_rb[0] == cold_beats)
      else $fatal(1, "decode fmt=%0d cold beats %0d != %0d", numfmt, point_rb[0],
                  cold_beats);
    if (VA_TURBO) begin
      // The beats a resident operand buys are EXACTLY that operand's own, no
      // more and no less: an over-count would mean the engine dropped a load it
      // still needed, an under-count that residency did not actually engage.
      assert (point_rb[0] - point_rb[2] == b_beats)
        else $fatal(1, "decode fmt=%0d resident B saved %0d beats, not B's %0d",
                    numfmt, point_rb[0] - point_rb[2], b_beats);
      assert (point_rb[0] - point_rb[1] == a_beats)
        else $fatal(1, "decode fmt=%0d resident A saved %0d beats, not A's %0d",
                    numfmt, point_rb[0] - point_rb[1], a_beats);
      assert (point_rb[3] == 0)
        else $fatal(1, "decode fmt=%0d both-resident still read %0d operand beats",
                    numfmt, point_rb[3]);
      // Deliberately an inequality and nothing more.  How MUCH warm_b is below
      // cold is the measurement; that it is not above it is the law.
      assert (point_cy[2] <= point_cy[0])
        else $fatal(1, "decode fmt=%0d resident B cycles %0d exceed cold %0d",
                    numfmt, point_cy[2], point_cy[0]);
    end else
      assert (point_rb[0] == point_rb[1] && point_rb[1] == point_rb[2] &&
              point_rb[2] == point_rb[3])
        else $fatal(1, "decode disabled fmt=%0d read beats moved %p", numfmt,
                    point_rb);
    @(negedge clk);
    m_v[0] = JOB_M;
  endtask

  initial begin
    assert (encode_element(-7, 3'd0) == 32'h000000f9 &&
            encode_element(-7, 3'd1) == 32'h00000009)
      else $fatal(1, "packed negative element leaked sign bits into adjacent elements");
    assert (N_ENGINES inside {1, 2, 4}) else $fatal(1, "N_ENGINES must be 1, 2 or 4");
    assert (dram_channels_ok(NCH)) else $fatal(1, "invalid NCH=%0d", NCH);
    // Now that the geometry is a parameter, MaxDim has to cover every one of its
    // three dimensions, not just k: the engine's own bound is m,n,k in
    // [1, MaxDim] and it raises err_o outside it.
    assert (GEMM_MAXDIM >= JOB_K && GEMM_MAXDIM >= JOB_M && GEMM_MAXDIM >= JOB_N &&
            JOB_M >= 1 && JOB_N >= 1 && JOB_K >= 1 &&
            GEMM_LANES >= 8 && GEMM_LANES <= 256 &&
            (GEMM_LANES & (GEMM_LANES - 1)) == 0)
      else $fatal(1, "MAX_DIM must cover JOB_M/JOB_N/JOB_K (>=1 each); PE_LANES must be power of two in [8,256]");
    // The sub-slots are now derived (see their declaration), so this checks the
    // derivation rather than a fixed 512 B: every region must hold its tile at 4
    // bytes per element, the widest format staged, and the whole engine array
    // must fit the memory model.  The C bound rounds m*n UP to an even element
    // count because poison_engine writes C in 64-bit pairs and so pads an ODD
    // tile by one word; an even tile is charged nothing extra and may fill the
    // sub-slot exactly.
    assert (ENG_BASE - 64'h8000_0000 + 64'(N_ENGINES * SLOT) <= 64'(NWORDS * 8) &&
            JOB_M * JOB_K * 4 <= OFF_B && JOB_N * JOB_K * 4 <= OFF_C - OFF_B &&
            (JOB_M * JOB_N + (JOB_M * JOB_N) % 2) * 4 <= SLOT - OFF_C)
      else $fatal(1, "measurement slots exceed memory");
    // THE GEOMETRY AXIS MAY ONLY GROW THE SHAPE, NOT SHRINK IT.
    //
    // The directed suites perturb the shape with LITERALS -- n_v[0] = 6 and 7,
    // m_v[0] = 4, k_v[0] = 8 -- because they are testing which fields are part
    // of the reuse key.  Several of those cases deliberately do NOT re-stage the
    // operands, so they rely on the nominal staging already covering the larger
    // shape: at the 8x8x16 default, B rows 4 and 5 exist because eight were
    // staged, and the n=6 case reads them.
    //
    // Below the default that stops being true and the failure is confusing
    // rather than loud: JOB_N=4 reports `C row0 col4` -- a column the nominal
    // tile does not even have -- because the n=6 case read two B rows nobody
    // staged.  So the axis is bounded here instead, with the reason, rather
    // than leaving a smaller geometry to produce a golden mismatch that looks
    // like an RTL bug.  Making the literals relative to the parameters would
    // lift this, and would also change what the directed cases test.
    assert (JOB_M >= 8 && JOB_N >= 8 && JOB_K >= 16)
      else $fatal(1, "JOB_M/JOB_N must be >= 8 and JOB_K >= 16: the directed cases perturb the shape with literals (n=6,7 m=4 k=8) and some do not re-stage, so a SMALLER nominal shape leaves them reading operands that were never written");
    // ROW STRIDE ALIGNMENT.  configure_engine sets lda = ldb = JOB_K, so the row
    // stride in bytes is JOB_K * element_bits / 8, and the narrowest format in
    // the tables is INT4 at 4 bits.  A stride that is not a whole number of
    // 64-bit words puts row r at a non-8-byte-aligned address, which the loader
    // does not read back correctly -- MEASURED at JOB_K=8, where INT4 gets a
    // 4-byte stride: the all-ones tiles still pass (uniform data cannot detect a
    // shifted read) and the first SIGNED INT4 tile fails its golden.  It is the
    // STRIDE and not the row content that binds: the directed "INT4_odd_n_k"
    // case runs k=7 happily because it leaves ldb at 16, i.e. a partial row
    // inside an aligned stride.  So JOB_K must be a multiple of 16 while INT4 is
    // in the format tables; k=16 (the default) is the smallest legal value.
    assert ((JOB_K * 4) % 64 == 0)
      else $fatal(1, "JOB_K=%0d gives INT4 a %0d-byte row stride: lda/ldb = JOB_K must make every format's row a whole number of 64-bit words, so JOB_K must be a multiple of 16",
                  JOB_K, (JOB_K * 4) / 8);
    assert (int'(gen_eng[0].i_gemm.a_bank_addr(0, 4 * GEMM_MAXDIM - 1)) <
            int'(gen_eng[0].i_gemm.a_bank_addr(1, 0)) &&
            int'(gen_eng[0].i_gemm.b_bank_addr(4 * GEMM_MAXDIM - 1, 0)) <
            int'(gen_eng[0].i_gemm.b_bank_addr(0, 1)))
      else $fatal(1, "multi-byte operand rows alias in tile SRAM");
    errors = 0;
    cycles = 0;
    inject_r_error = '0;
    start_v = '0;
    invalidate_v = '0;
    invalidate_a_v = '0;
    lease_v = '0;
    lease_a_v = '0;
    permission_v = '0;
    window_v = '0;
    policy_enable_v = '0;
    lossless_v = '0;
    loss_max_diff = 0;
    loss_diff_elems = 0;
    loss_poison_elems = 0;
    wide_exp_data = 1'b0;
    wide_exp_dst = 3'd0;
    signed_data = 1'b0;
    clr_seen = 0;
    aw_set = 0; w_set = 0; ar_set = 0;
    b_ready_en = 0;
    r_ready_en = 0;
    for (int i = 0; i < N_ENGINES; i++) begin
      numfmt_v[i] = 3'd0;
      lossless_target_v[i] = 3'd0;
      m_v[i] = JOB_M;
      n_v[i] = JOB_N;
      k_v[i] = JOB_K;
      lda_v[i] = 16'(JOB_K);
      ldb_v[i] = 16'(JOB_K);
      epoch_v[i] = 0;
      epoch_a_v[i] = 0;
      level_v[i] = 0;
      b_owner_v[i] = unsigned'(i);
      b_version_v[i] = 0;
      pa_v[i] = eng_a(i);
      pb_v[i] = eng_a(i) + 64'(OFF_B);
      pc_v[i] = eng_a(i) + 64'(OFF_C);
    end
    idle_payload();
    rst_ni = 0;
    repeat (8) tick;
    @(negedge clk);
    rst_ni = 1;
    repeat (32) tick;

    if (!init_done) begin
      $error("backend init_done");
      errors++;
    end
    if (ready_v != {N_ENGINES{1'b1}}) begin
      $error("engines not ready ready=%b", ready_v);
      errors++;
    end

    // Independent regions, then shared-B, across the format set.  INT4 is
    // packed; the float formats all expect FP32 k.0 on the golden path.
    //
    // Driven from a table rather than as literal calls, and NOT for tidiness:
    // with --timing every task inlines into this one `initial`, which Verilator
    // emits as a single VlCoroutine that no output-split can break up.  As
    // literal calls the coroutine reached 321,102 lines in one 27.4 MB
    // translation unit, so the object build was one serial g++ no matter what
    // -j said.  A runtime-indexed loop emits the body once.  The order and
    // arguments below are exactly the previous call sequence.
    for (int unsigned e = 0; e < EXPERIMENTS; e++) begin
      signed_data = exp_signed(e);
      run_experiment(exp_fmt(e), exp_pattern(exp_fmt(e)), exp_bpe(exp_fmt(e)),
                     exp_fmt(e) == 3'd1, exp_shared(e));
    end

    // Mixed job streams: throughput as a function of hit rate, not just the
    // 0% and 100% corners the phase experiments above measure.
    run_opportunistic_sweep(3'd0, ONES8,  1, 1'b0);
    run_opportunistic_sweep(3'd7, FP32_1, 4, 1'b0);
    run_directed();
    run_directed_a();

    // Four residency points per format on one engine: the A and B keys must
    // compose, not merely coexist.  Table-driven for the same compile-time
    // reason as the EXPERIMENTS loop above.
    for (int unsigned d = 0; d < DUAL_FMTS; d++)
      run_dual(dual_fmt(d), exp_pattern(dual_fmt(d)), exp_bpe(dual_fmt(d)),
               dual_fmt(d) == 3'd1);

    // Proven-exact narrowing pairs: the same logical matrix at both widths.
    // Table-driven for the same compile-time reason as the EXPERIMENTS loop --
    // and the data class is the OUTER loop index, not a second literal call
    // sequence, for that same reason.  Class 0 (small integer) runs first and in
    // the original order, so its three lines are byte-identical to what they
    // were before the wide-exponent class existed.
    for (int unsigned dc = 0; dc < LOSSLESS_CLASSES; dc++)
      for (int unsigned p = 0; p < LOSSLESS_PAIRS; p++)
        run_lossless(lossless_src(p), lossless_dst(p), dc != 0);

    // The same four residency points on the DECODE shape (m = 1).  Runs last and
    // touches nothing above it, so every line printed before this point is
    // exactly the line it was.  Table-driven for the compile-time reason spelled
    // out at the EXPERIMENTS loop.
    for (int unsigned d = 0; d < DECODE_FMTS; d++)
      run_decode(decode_fmt(d));

    if (straddle) begin
      $error("an engine burst straddled a channel stripe");
      errors++;
    end

    if (errors == 0)
      $display("PASS g6lc_ai_gemm_concurrent class=%0d nch=%0d eng=%0d lanes=%0d va_turbo=%0d",
               DRAM_CLASS, NCH, N_ENGINES, GEMM_LANES, VA_TURBO);
    else begin
      $display("FAIL g6lc_ai_gemm_concurrent errors=%0d", errors);
      $fatal(1);
    end
    $finish;
  end
endmodule
