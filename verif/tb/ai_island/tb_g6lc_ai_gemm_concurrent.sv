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
    parameter bit          VA_TURBO     = 1'b1
);
  localparam int unsigned ID_W    = 4;
  // The mux prepends idx_width(NO_SLV_PORTS) port bits to the slave ID.
  localparam int unsigned N_PORTS = N_ENGINES + 1;
  localparam int unsigned MST_ID  = ID_W + ((N_PORTS > 1) ? $clog2(N_PORTS) : 1);
  localparam int unsigned ADDR_W  = 64;
  localparam int unsigned DATA_W  = 64;
  localparam int unsigned NWORDS  = 1024;   // 8 KiB model
  localparam int unsigned TO_HS   = 8000;
  localparam int unsigned TO_RSP  = 60000;

  // Per-engine memory slots inside the 8 KiB model.  A and B each get 512 B
  // (8 rows x k_bytes up to 64 B), C gets 512 B (8x8 x 4 B = 256 B used).
  // Slot i starts at 0x0400 + i*0x600; four engines end at 0x1C00 < 0x2000.
  localparam logic [63:0] ENG_BASE   = 64'h8000_0400;
  localparam int unsigned SLOT       = 16'h0600;
  localparam int unsigned OFF_B      = 16'h0200;
  localparam int unsigned OFF_C      = 16'h0400;

  // Fixed measurement geometry: 8x8x16, 1024 MACs per engine.  Kept constant
  // so serial and concurrent phases are the same work; geometry is a separate
  // axis (the +measure / +measure_k sweeps on the single-engine TB).
  localparam int unsigned JOB_M = 8;
  localparam int unsigned JOB_N = 8;
  localparam int unsigned JOB_K = 16;

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
  logic [N_ENGINES-1:0] permission_v, window_v, policy_enable_v;
  logic [3:0] level_v [N_ENGINES];
  va_turbo_request_t request_v [N_ENGINES];
  va_turbo_plan_t plan_v [N_ENGINES];
  int unsigned b_owner_v [N_ENGINES], b_version_v [N_ENGINES];
  bit signed_data;
  localparam int unsigned REPEATS = 2;
  localparam logic [31:0] REUSE_MASK = 32'h1 << 16;

  // Opportunistic mixed-hit sequence: fixed length and fixed denominator so
  // every hit fraction runs exactly the same amount of useful work.
  localparam int unsigned EXPERIMENTS   = 18;
  localparam int unsigned JOBS_PER_SEQ  = 8;
  localparam int unsigned OPP_FRACTIONS = 5;
  int unsigned opp_cy, opp_r, opp_w, opp_hit_count;

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
      request_v[i].bank = 2'd2;
      request_v[i].subcode = 3'd0;
      request_v[i].code = POLICY_BULK;
      request_v[i].numfmt = numfmt_v[i];
      request_v[i].m = 16'(m_v[i]);
      request_v[i].n = 16'(n_v[i]);
      request_v[i].k = 16'(k_v[i]);
      request_v[i].regular_layout = 1'b1;
      request_v[i].reuse_b_valid = lease_v[i];
      request_v[i].window_valid = window_v[i];
      request_v[i].qualified_mask = permission_v[i] ? REUSE_MASK : 32'd0;
      plan_v[i] = va_turbo_select(TEST_CFG, request_v[i], GEMM_LANES, 8, 1, REUSE_MASK);
      reuse_v[i] = plan_v[i].apply && plan_v[i].reuse_b;
    end

    always @(posedge clk) begin
      if (rst_ni) begin
        if (start_v[i]) begin
          assert (reuse_v[i] == (VA_TURBO && policy_enable_v[i] && level_v[i] != 0 &&
                                 lease_v[i] && window_v[i] && permission_v[i] &&
                                 m_v[i] != 0 && n_v[i] != 0 && k_v[i] != 0 &&
                                 m_v[i] <= 256 && n_v[i] <= 256 && k_v[i] <= 256 &&
                                 policy_format_known(numfmt_v[i])))
            else $fatal(1, "eng%0d recipe16 permission mismatch", i);
          if (plan_v[i].apply)
            assert (plan_v[i].recipe == 16 && plan_v[i].arith_kind == VA_ARITH_EXACT &&
                    !plan_v[i].convert && !plan_v[i].approx_products && !plan_v[i].reuse_a &&
                    plan_v[i].groups_log2 == 0 && plan_v[i].target_numfmt == numfmt_v[i])
              else $fatal(1, "eng%0d unsupported plan reached consumer", i);
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
        .numfmt_i     ( numfmt_v[i] ),
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

  function automatic int a_value(input int unsigned i, r, t);
    int v;
    if (!signed_data) return 1;
    v = 1 + int'((i * 3 + r * 2 + t * (1 + r % 3) + (r / 3) * (t / 2)) % 7);
    return ((r + t / 3 + i) % 2 != 0) ? -v : v;
  endfunction

  function automatic int b_value(input int unsigned owner, c, t, version);
    int v;
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
                         input bit expected_error, output int unsigned wall_cy);
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
    wall_cy = free_cy - t0;
  endtask

  task automatic run_serial(input bit expected_hit, output int unsigned total_cy,
                            output int unsigned total_r, total_w);
    int unsigned wall_cy;
    total_cy = 0;
    total_r = 0;
    total_w = 0;
    for (int unsigned i = 0; i < N_ENGINES; i++) begin
      run_one(i, expected_hit, 1'b0, wall_cy);
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

  task automatic poison_engine(input int unsigned i);
    for (int unsigned e = 0; e < m_v[i] * n_v[i]; e += 2)
      wr8(pc_v[i] + 64'(e * 4), 64'hDEAD_BEEF_BADC_0FFE ^ 64'(i * 256 + e));
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
    lease_v[i] = 1'b1;
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
    for (int unsigned i = 0; i < N_ENGINES; i++) begin
      configure_engine(i, numfmt, shared_b);
      store_engine(i, pattern, bpe, is_packed, shared_b);
    end
    expected_r = N_ENGINES * (JOB_M + JOB_N) * ((JOB_K * element_bits(numfmt) + 63) / 64);
    expected_w = N_ENGINES * JOB_M * JOB_N / 2;
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
        assert (rb * (VA_TURBO ? 2 : 1) == expected_r && wb == expected_w)
          else $fatal(1, "warm traffic fmt=%0d r=%0d w=%0d", numfmt, rb, wb);
        warm_cy[mode] += cy;
        warm_r[mode] += rb;
        warm_w[mode] += wb;
      end
      assert (warm_r[mode] * (VA_TURBO ? 2 : 1) == base_r[mode] &&
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
    int unsigned cy, words_per_row, expected_r, expected_w;
    bit want_hit;
    assert (hits < JOBS_PER_SEQ)
      else $fatal(1, "opportunistic hits=%0d leaves no cold job", hits);
    configure_engine(0, numfmt, 1'b0);
    invalidate_all();
    opp_cy = 0;
    opp_r = 0;
    opp_w = 0;
    opp_hit_count = 0;
    words_per_row = (JOB_K * element_bits(numfmt) + 63) / 64;
    expected_w = JOB_M * JOB_N / 2;
    for (int unsigned j = 0; j < JOBS_PER_SEQ; j++) begin
      want_hit = opp_want_hit(j, hits) && VA_TURBO;
      if (!opp_want_hit(j, hits)) begin
        @(negedge clk);
        b_version_v[0]++;
        epoch_v[0]++;
        store_engine(0, pattern, bpe, is_packed, 1'b0);
      end
      poison_engine(0);
      run_one(0, want_hit, 1'b0, cy);
      check_engine(0);
      expected_r = (JOB_M + (want_hit ? 0 : JOB_N)) * words_per_row;
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

  task automatic directed_job(input string name, input bit want_hit, input bit stage);
    int unsigned cy, expected_r, expected_w;
    bit hit;
    hit = VA_TURBO && want_hit;
    poison_engine(0);
    if (stage)
      store_engine(0, ONES8, (element_bits(numfmt_v[0]) + 7) / 8,
                   numfmt_v[0] == 3'd1, 1'b0);
    run_one(0, hit, 1'b0, cy);
    check_engine(0);
    expected_r = (m_v[0] + (hit ? 0 : n_v[0])) * ((k_v[0] * element_bits(numfmt_v[0]) + 63) / 64);
    expected_w = m_v[0] * (n_v[0][0] ? n_v[0] : n_v[0] / 2);
    assert (pmu_r_v[0] == expected_r && pmu_w_v[0] == expected_w)
      else $fatal(1, "%s traffic r=%0d/%0d w=%0d/%0d", name, pmu_r_v[0], expected_r,
                  pmu_w_v[0], expected_w);
    $display("REUSE_CASE name=%s enabled=%0d hit=%0d cycles=%0d r=%0d w=%0d",
             name, VA_TURBO, reuse_hit_v[0], cy, pmu_r_v[0], pmu_w_v[0]);
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
    run_one(0, 1'b0, 1'b1, cy);
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
    run_one(0, 1'b0, 1'b1, cy);
    @(negedge clk);
    inject_r_error[0] = 1'b0;
    directed_job("RRESP_error_invalidates", 1'b0, 1'b0);
    directed_job("RRESP_error_recovery_warm", 1'b1, 1'b0);
  endtask

  initial begin
    assert (encode_element(-7, 3'd0) == 32'h000000f9 &&
            encode_element(-7, 3'd1) == 32'h00000009)
      else $fatal(1, "packed negative element leaked sign bits into adjacent elements");
    assert (N_ENGINES inside {1, 2, 4}) else $fatal(1, "N_ENGINES must be 1, 2 or 4");
    assert (dram_channels_ok(NCH)) else $fatal(1, "invalid NCH=%0d", NCH);
    assert (GEMM_MAXDIM >= JOB_K && GEMM_LANES >= 8 && GEMM_LANES <= 256 &&
            (GEMM_LANES & (GEMM_LANES - 1)) == 0)
      else $fatal(1, "MAX_DIM must cover k=16; PE_LANES must be power of two in [8,256]");
    assert (ENG_BASE - 64'h8000_0000 + 64'(N_ENGINES * SLOT) <= 64'(NWORDS * 8) &&
            JOB_M * JOB_K * 4 <= OFF_B && JOB_N * JOB_K * 4 <= OFF_C - OFF_B &&
            JOB_M * JOB_N * 4 <= SLOT - OFF_C)
      else $fatal(1, "measurement slots exceed memory");
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
    lease_v = '0;
    permission_v = '0;
    window_v = '0;
    policy_enable_v = '0;
    signed_data = 1'b0;
    clr_seen = 0;
    aw_set = 0; w_set = 0; ar_set = 0;
    b_ready_en = 0;
    r_ready_en = 0;
    for (int i = 0; i < N_ENGINES; i++) begin
      numfmt_v[i] = 3'd0;
      m_v[i] = JOB_M;
      n_v[i] = JOB_N;
      k_v[i] = JOB_K;
      lda_v[i] = 16'(JOB_K);
      ldb_v[i] = 16'(JOB_K);
      epoch_v[i] = 0;
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
