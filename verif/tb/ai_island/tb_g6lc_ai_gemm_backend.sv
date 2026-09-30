// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// GEMM vs g6lc_ai_dram_backend (testharness DRAM slave).
// DRAM_CLASS=0: class-0 SRAM. DRAM_CLASS=1: native LiteDRAM wrap (CLASS1).
// Job 1: 2x2 k=16 golden C=16. Job 2 (N>1): lda=64 all-NCH occupancy.
// Not Variane.
//
// `+measure` adds an opt-in RTL measurement sweep (default OFF: without the
// plusarg the directed cost, every $error check and the PASS line are
// byte-identical to before).  It re-runs the SAME 2x2x16 job for every granted
// numeric format x every legal ar_max in [1, GEMM_MAX_AR] and prints one
// MEASURE line per run for verif/tb/ai_island/policy_measure.py.  AR depth is
// a memory-side prefetch cap only: the golden C must be identical at every
// depth, and a difference is an $error.

`timescale 1ns/1ps
`include "axi/typedef.svh"
`include "axi/assign.svh"

module tb_g6lc_ai_gemm_backend
  import g6lc_ai_island_cfg_pkg::*;
#(
    parameter int unsigned NCH        = 2,
    parameter int unsigned DRAM_CLASS = AI_DRAM_SIM_AXI,
    parameter bit          DOT_PIPE_FLOAT = 1'b0,
    // Provisioning overrides for the +measure sweep only.  0 keeps the shipped
    // value, so an unset build is byte-identical to the directed configuration.
    // PE_LANES raises the arithmetic peak (PeLanes MAC/cycle) and AR_PROVISION
    // raises the outstanding-AR bound, which is the only direction that can add
    // throughput: policy prefetch_depth could merely lower it.
    parameter int unsigned PE_LANES     = 0,
    // V2 column array: output columns per cycle (g6lc_ai_gemm_seq OutCols); 1 = single dot.
    parameter int unsigned OUT_COLS     = 1,
    parameter int unsigned AR_PROVISION = 0,
    // MAX_DIM raises the sequencer's MaxDim so the +measure_k sweep can push k
    // past 16. It grows the tile SRAM (BankWords = MaxDim*ceil(MaxDim/PeLanes)),
    // so it is opt-in and 0 keeps the directed value.
    parameter int unsigned MAX_DIM      = 0,
    // Separate M/N/K and reuse are opt-in. 0 keeps the square MaxDim path
    // and leaves the reuse generate unelaborated, so the directed run is
    // unchanged. +panel_reuse drives the keys; it is not the live package.
    parameter int unsigned MAX_M        = 0,
    parameter int unsigned MAX_N        = 0,
    parameter int unsigned MAX_K        = 0,
    parameter bit          REUSE_EN     = 1'b0
);
  localparam int unsigned ID_W    = 4;
  localparam int unsigned MST_ID  = ID_W + 1;
  localparam int unsigned ADDR_W  = 64;
  localparam int unsigned DATA_W  = 64;
  // The directed image is 8 KiB. The panel-key build needs room for an
  // m=1024 operand and an n=512 row without overlapping C.
  localparam int unsigned NWORDS  = (MAX_M == 0) ? 1024 : 8192;
  localparam int unsigned TO_HS   = 8000;
  localparam int unsigned TO_RSP  = 20000;
  // +measure geometry.  m and n must exceed the AR depth under test because A/B
  // ARs are bounded by m then n; k stays 16 because the golden C constant is
  // exactly k for all-ones operands, so varying k would need new per-format
  // constants.  MeasShapes walks the codec's own shape classes so a provisioning
  // optimum can be attributed to a policy group: square/bulk, decode (m=1),
  // tall (m>n), wide (n>m) and the largest square MaxDim allows.
  localparam int unsigned MeasK      = 16;
  localparam int unsigned MeasPasses = 2;
  localparam int unsigned MeasShapes = 6;
  localparam int unsigned MeasMN [MeasShapes][2] = '{
      '{8,  8},   // bulk / square
      '{1,  16},  // decode-like: single output row
      '{16, 1},   // tall
      '{2,  16},  // wide
      '{16, 16},  // largest square at MaxDim=16
      '{1,  32}   // decode row long enough for the intra-row trail store (TrailMinCols)
  };
  localparam logic [DATA_W-1:0] ONES8  = 64'h0101_0101_0101_0101;
  localparam logic [DATA_W-1:0] C16    = 64'h0000_0010_0000_0010;
  // FP8/FP16/BF16/FP32 all-1.0 patterns for little-endian byte storage.
  // FP32 16.0 = 0x41800000 is the expected C row for 2x2x16 with all-1.0.
  // INT4 all +1 packed two per byte = 0x11 per byte.
  localparam logic [DATA_W-1:0] INT4_1  = {8{8'h11}};
  localparam logic [DATA_W-1:0] FP8_E4M3_1 = {8{8'h38}};       // 0_0111_000
  localparam logic [DATA_W-1:0] FP8_E5M2_1 = {8{8'h3C}};       // 0_01111_00
  localparam logic [DATA_W-1:0] FP16_1    = {4{16'h3C00}};
  localparam logic [DATA_W-1:0] BF16_1    = {4{16'h3F80}};
  localparam logic [DATA_W-1:0] FP32_1    = {2{32'h3F800000}};
  localparam logic [DATA_W-1:0] FP_C16    = {2{32'h41800000}};

  typedef logic [ADDR_W-1:0]     addr_t;
  typedef logic [ID_W-1:0]       id_t;
  typedef logic [DATA_W-1:0]     data_t;
  typedef logic [DATA_W/8-1:0]   strb_t;
  typedef logic [0:0]            user_t;
  `AXI_TYPEDEF_ALL(gbus, addr_t, id_t, data_t, strb_t, user_t)

  logic clk, rst_ni, init_done, start, ready, done, err;
  logic [31:0] gemm_m, gemm_n, gemm_k;
  logic [15:0] gemm_lda, gemm_ldb;
  logic [2:0]  gemm_numfmt;
  logic        accumulate = 1'b0;  // flags.accmode 01 for the next kick
  logic [63:0] gemm_pa, gemm_pb, gemm_pc;
  logic aw_pend, w_pend, ar_pend, aw_set, w_set, ar_set;
  logic b_ready_en, r_ready_en;
  gbus_req_t  gemm_req;
  gbus_resp_t gemm_resp, gemm_bus_resp;
  gbus_req_t gemm_bus_req;
  logic [1:0] ar_delay_q, aw_delay_q, w_delay_q;

  always_comb begin
    gemm_bus_req = gemm_req;
    gemm_resp = gemm_bus_resp;
    if ($test$plusargs("review_protocol")) begin
      gemm_bus_req.ar_valid = gemm_req.ar_valid && ar_delay_q == 0;
      gemm_bus_req.aw_valid = gemm_req.aw_valid && aw_delay_q == 0;
      gemm_bus_req.w_valid = gemm_req.w_valid && w_delay_q == 0;
      gemm_resp.ar_ready = gemm_bus_resp.ar_ready && ar_delay_q == 0;
      gemm_resp.aw_ready = gemm_bus_resp.aw_ready && aw_delay_q == 0;
      gemm_resp.w_ready = gemm_bus_resp.w_ready && w_delay_q == 0;
    end
  end

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      ar_delay_q <= 3;
      aw_delay_q <= 3;
      w_delay_q <= 3;
    end else begin
      if (gemm_req.ar_valid) begin
        if (ar_delay_q != 0) ar_delay_q <= ar_delay_q - 1'b1;
        else if (gemm_resp.ar_ready) ar_delay_q <= 3;
      end
      if (gemm_req.aw_valid) begin
        if (aw_delay_q != 0) aw_delay_q <= aw_delay_q - 1'b1;
        else if (gemm_resp.aw_ready) aw_delay_q <= 3;
      end
      if (gemm_req.w_valid) begin
        if (w_delay_q != 0) w_delay_q <= w_delay_q - 1'b1;
        else if (gemm_resp.w_ready) w_delay_q <= 3;
      end
    end
  end
  logic [AI_DRAM_MAX_CHANNELS-1:0][31:0] ch_r_beats, ch_w_beats;
  logic [31:0] pmu_r, pmu_w, pmu_cy;
  logic [3:0][31:0] pmu_phase;
  logic [2:0][31:0] pmu_stall;
  logic        cap_req, cap_rvalid;
  logic [15:0] cap_addr;
  logic [31:0] cap_rdata;
  int unsigned errors, cycles, n_ar, max_inf;
  logic saw_cap, saw_next, saw_id2, saw_id3, straddle;
  logic [15:0] inf_ids;
  logic [DATA_W-1:0] r_data_cap;
  logic [DATA_W-1:0] c0, c1;
  logic [DATA_W-1:0] c0_eqv, c1_eqv;
  logic [3:0]        ar_max_val;
  logic              reuse_b_req, reuse_a_req, reuse_b_inv, reuse_a_inv;
  logic              reuse_b_hit, reuse_a_hit;
  logic [31:0]       reuse_epoch;
  logic [31:0]       panel_epoch;
  logic [63:0]       panel_pc;
  // Measurement plumbing (sim-only, +measure).  `cycles` is the TB's shared
  // TIMEOUT BUDGET -- every helper task compares it against TO_HS/TO_RSP
  // absolutely -- so it can never be the measurement.  `free_cy` is a
  // genuinely free-running clock counter that no timeout loop touches.
  logic [31:0]       free_cy;
  int unsigned       meas_runs;
  logic ar_wait_q, aw_wait_q, w_wait_q;
  gbus_ar_chan_t ar_held_q;
  gbus_aw_chan_t aw_held_q;
  gbus_w_chan_t w_held_q;
  int unsigned protocol_stalls;

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      ar_wait_q <= 1'b0;
      aw_wait_q <= 1'b0;
      w_wait_q <= 1'b0;
      ar_held_q <= '0;
      aw_held_q <= '0;
      w_held_q <= '0;
      protocol_stalls <= 0;
    end else begin
      if ($test$plusargs("review_protocol")) begin
        if (ar_wait_q && (!gemm_req.ar_valid || gemm_req.ar !== ar_held_q))
          $fatal(1, "AXI_AR_STABILITY valid=%b id=%h/%h addr=%h/%h len=%h/%h", gemm_req.ar_valid,
                 gemm_req.ar.id, ar_held_q.id, gemm_req.ar.addr, ar_held_q.addr, gemm_req.ar.len, ar_held_q.len);
        if (aw_wait_q && (!gemm_req.aw_valid || gemm_req.aw !== aw_held_q))
          $fatal(1, "AXI_AW_STABILITY");
        if (w_wait_q && (!gemm_req.w_valid || gemm_req.w !== w_held_q))
          $fatal(1, "AXI_W_STABILITY valid=%b fmt=%0d shape=%0dx%0dx%0d data=%h/%h strb=%h/%h last=%b/%b",
                 gemm_req.w_valid, gemm_numfmt, gemm_m, gemm_n, gemm_k, gemm_req.w.data, w_held_q.data,
                 gemm_req.w.strb, w_held_q.strb, gemm_req.w.last, w_held_q.last);
      end
      ar_wait_q <= gemm_req.ar_valid && !gemm_resp.ar_ready;
      aw_wait_q <= gemm_req.aw_valid && !gemm_resp.aw_ready;
      w_wait_q <= gemm_req.w_valid && !gemm_resp.w_ready;
      ar_held_q <= gemm_req.ar;
      aw_held_q <= gemm_req.aw;
      w_held_q <= gemm_req.w;
      protocol_stalls <= protocol_stalls + 32'(gemm_req.ar_valid && !gemm_resp.ar_ready) +
          32'(gemm_req.aw_valid && !gemm_resp.aw_ready) + 32'(gemm_req.w_valid && !gemm_resp.w_ready);
    end
  end

  AXI_BUS #(.AXI_ADDR_WIDTH(ADDR_W), .AXI_DATA_WIDTH(DATA_W),
            .AXI_ID_WIDTH(ID_W), .AXI_USER_WIDTH(1)) mux_slv[1:0]();
  AXI_BUS #(.AXI_ADDR_WIDTH(ADDR_W), .AXI_DATA_WIDTH(DATA_W),
            .AXI_ID_WIDTH(MST_ID), .AXI_USER_WIDTH(1)) dram();

  `AXI_ASSIGN_FROM_REQ(mux_slv[1], gemm_bus_req)
  `AXI_ASSIGN_TO_RESP(gemm_bus_resp, mux_slv[1])

  assign mux_slv[0].aw_valid = aw_pend;
  assign mux_slv[0].w_valid  = w_pend;
  assign mux_slv[0].ar_valid = ar_pend;
  assign mux_slv[0].b_ready  = b_ready_en;
  assign mux_slv[0].r_ready  = r_ready_en;

  axi_mux_intf #(
      .SLV_AXI_ID_WIDTH ( ID_W ),
      .MST_AXI_ID_WIDTH ( MST_ID ),
      .AXI_ADDR_WIDTH   ( ADDR_W ),
      .AXI_DATA_WIDTH   ( DATA_W ),
      .AXI_USER_WIDTH   ( 1 ),
      .NO_SLV_PORTS     ( 2 )
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

  g6lc_ai_cap_window i_cap (
      .clk_i        ( clk ),
      .rst_ni       ( rst_ni ),
      .req_i        ( cap_req ),
      .we_i         ( 1'b0 ),
      .addr_i       ( cap_addr ),
      .wdata_i      ( 32'd0 ),
      .dram_gbps_meas_x1000_i ( 32'd0 ),
      .dram_init_done_i ( init_done ),
      .ch_r_beats_i ( ch_r_beats ),
      .ch_w_beats_i ( ch_w_beats ),
      .rdata_o      ( cap_rdata ),
      .rvalid_o     ( cap_rvalid )
  );

  localparam int GEMM_SHIPPED_AR = (DRAM_CLASS == AI_DRAM_SIM_AXI) ? AI_MAX_AR_OUT_LIVE
                                                                   : AI_MAX_AR_OUT_DRAM;
  localparam int GEMM_MAX_AR = (AR_PROVISION == 0) ? GEMM_SHIPPED_AR : int'(AR_PROVISION);
  localparam int GEMM_LANES  = (PE_LANES == 0) ? 8 : int'(PE_LANES);
  localparam int GEMM_MAXDIM = (MAX_DIM == 0) ? 16 : int'(MAX_DIM);
  g6lc_ai_gemm_seq #(
      .AddrWidth  ( ADDR_W ),
      .DataWidth  ( DATA_W ),
      .IdWidth    ( ID_W ),
      .MaxDim     ( GEMM_MAXDIM ),
      .MaxM       ( MAX_M ),
      .MaxN       ( MAX_N ),
      .MaxK       ( MAX_K ),
      .PeLanes    ( GEMM_LANES ),
      .OutCols    ( OUT_COLS ),
      .DotPipeFloat( DOT_PIPE_FLOAT ),
      .MaxAROut   ( GEMM_MAX_AR ),
      .ReuseBEn   ( REUSE_EN ),
      .ReuseAEn   ( REUSE_EN ),
      .NrChannels ( NCH ),
      .ChanShift  ( AI_DRAM_CHAN_SHIFT_DEFAULT ),
      .axi_req_t  ( gbus_req_t ),
      .axi_resp_t ( gbus_resp_t )
  ) i_gemm (
      .clk_i        ( clk ),
      .rst_ni       ( rst_ni ),
      .testmode_i   ( 1'b0 ),
      .start_i      ( start ),
      .m_i          ( gemm_m ),
      .n_i          ( gemm_n ),
      .k_i          ( gemm_k ),
      .lda_i        ( gemm_lda ),
      .ldb_i        ( gemm_ldb ), .ldc_i(16'd0),
      .numfmt_i     ( gemm_numfmt ),
      .accumulate_i(accumulate),
      .ar_max_i     ( ar_max_val ),
      .ptr_a_i      ( gemm_pa ),
      .ptr_b_i      ( gemm_pb ),
      .ptr_c_i      ( gemm_pc ),
      .ready_o      ( ready ),
      .done_o       ( done ),
      .err_o        ( err ),
      .pmu_r_beats_o( pmu_r ),
      .pmu_w_beats_o( pmu_w ),
      .pmu_cycles_o ( pmu_cy ),
      .pmu_phase_o  ( pmu_phase ),
      .pmu_stall_o  ( pmu_stall ),
      .reuse_b_i(reuse_b_req), .reuse_b_epoch_i(reuse_epoch),
      .reuse_b_invalidate_i(reuse_b_inv),
      .pmu_reuse_b_hit_o(reuse_b_hit),
      .reuse_a_i(reuse_a_req), .reuse_a_epoch_i(reuse_epoch),
      .reuse_a_invalidate_i(reuse_a_inv),
      .pmu_reuse_a_hit_o(reuse_a_hit),
      .axi_req_o    ( gemm_req ),
      .axi_resp_i   ( gemm_resp )
  );

  initial clk = 0;
  always #5 clk = ~clk;

  // Free-running clock counter: the only source of the reported MEASURE cycle
  // counts.  Wraps at 2^32, which the 2x2x16 jobs never approach.
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

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      n_ar <= 0; max_inf <= 0;
      saw_cap <= 0; saw_next <= 0; saw_id2 <= 0; saw_id3 <= 0;
      straddle <= 0; inf_ids <= '0;
    end else if (mux_slv[1].ar_valid && mux_slv[1].ar_ready) begin
      automatic int unsigned nbytes, inf;
      n_ar <= n_ar + 1;
      nbytes = (unsigned'(mux_slv[1].ar_len) + 1) << unsigned'(mux_slv[1].ar_size);
      if (!dram_burst_fits_stripe(NCH, AI_DRAM_CHAN_SHIFT_DEFAULT,
                                  mux_slv[1].ar_addr, nbytes))
        straddle <= 1'b1;
      if (mux_slv[1].ar_addr == 64'h8000_0038 && mux_slv[1].ar_len == 8'd0)
        saw_cap <= 1'b1;
      if (mux_slv[1].ar_addr == 64'h8000_0040)
        saw_next <= 1'b1;
      if (mux_slv[1].ar_id == 4'd2) saw_id2 <= 1'b1;
      if (mux_slv[1].ar_id == 4'd3) saw_id3 <= 1'b1;
      inf_ids[mux_slv[1].ar_id] <= 1'b1;
      inf = $countones(inf_ids) + (inf_ids[mux_slv[1].ar_id] ? 0 : 1);
      if (inf > max_inf) max_inf <= inf;
    end else if (mux_slv[1].r_valid && mux_slv[1].r_ready && mux_slv[1].r_last)
      inf_ids[mux_slv[1].r_id] <= 1'b0;
  end

  task automatic tick;
    @(posedge clk);
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

  task automatic issue_aw(
      input logic [ADDR_W-1:0] addr
  );
    mux_slv[0].aw_addr = addr;
    mux_slv[0].aw_len  = 8'd0;
    mux_slv[0].aw_size = 3'd3;
    mux_slv[0].aw_burst = 2'b01;
    aw_set = 1'b1;
    tick;
    aw_set = 1'b0;
    while (aw_pend && cycles < TO_HS) tick;
    if (aw_pend) begin
      $error("timeout AW addr=%h", addr);
      errors++;
    end
  endtask

  task automatic issue_w(input logic [DATA_W-1:0] data);
    mux_slv[0].w_data = data;
    mux_slv[0].w_last = 1'b1;
    mux_slv[0].w_strb = 8'hFF;
    w_set = 1'b1;
    tick;
    w_set = 1'b0;
    while (w_pend && cycles < TO_HS) tick;
    if (w_pend) begin
      $error("timeout W");
      errors++;
    end
  endtask

  task automatic wr8(input logic [ADDR_W-1:0] addr, input logic [DATA_W-1:0] data);
    b_ready_en = 1'b0;
    issue_aw(addr);
    issue_w(data);
    b_ready_en = 1'b1;
    while (!mux_slv[0].b_valid && cycles < TO_RSP) tick;
    if (!mux_slv[0].b_valid) begin
      $error("timeout B addr=%h", addr);
      errors++;
    end
    tick;
  endtask

  task automatic cap_read(input logic [15:0] a, output logic [31:0] d);
    cap_addr = a;
    cap_req  = 1'b1;
    tick;
    tick;
    d = cap_rdata;
    cap_req = 1'b0;
    tick;
  endtask

  task automatic check_cap;
    logic [31:0] cap_r, cap_w;
    int unsigned i;
    for (i = 0; i < AI_DRAM_MAX_CHANNELS; i++) begin
      cap_read(CAP_OFF_DRAM_CH_R + 16'(i * 4), cap_r);
      cap_read(CAP_OFF_DRAM_CH_W + 16'(i * 4), cap_w);
      if (cap_r !== ch_r_beats[i] || cap_w !== ch_w_beats[i]) begin
        $error("CAP occupancy ch%0d r exp=%0d got=%0d w exp=%0d got=%0d",
               i, ch_r_beats[i], cap_r, ch_w_beats[i], cap_w);
        errors++;
      end
    end
  endtask

  task automatic kick_gemm;
    start = 1'b1;
    tick;
    start = 1'b0;
    while (!done && cycles < TO_RSP) tick;
    if (!done) begin
      $error("timeout gemm cycles=%0d ar=%0d", cycles, n_ar);
      errors++;
    end
    if (err) begin
      $error("gemm err");
      errors++;
    end
  endtask

  // Format helper: write m x k and n x k operand rows of `pattern`.
  // `bpe` is bytes per element for unpacked formats. `packed` is set only for
  // INT4 (two 4-bit elements per byte).  k=16, m=n=2; golden is 16 for INT8/INT4
  // and FP32 16.0 for the floating formats.
  task automatic run_fmt_float(
      input logic [2:0]  numfmt,
      input logic [DATA_W-1:0] pattern,
      input int unsigned bpe,
      input logic        is_packed = 1'b0
  );
    int unsigned r, c, w, words_per_row;
    logic [63:0] a_base, b_base;
    logic [31:0] k_bytes, a_stride, b_stride;
    if (bpe == 0) bpe = 1;
    gemm_numfmt = numfmt;
    if (is_packed) begin
      k_bytes  = (gemm_k + 32'd1) >> 1;
      a_stride = (32'(gemm_lda) + 32'd1) >> 1;
      b_stride = (32'(gemm_ldb) + 32'd1) >> 1;
    end else begin
      k_bytes  = gemm_k * bpe;
      a_stride = 32'(gemm_lda) * bpe;
      b_stride = 32'(gemm_ldb) * bpe;
    end
    words_per_row = (k_bytes + 32'd7) / 32'd8;
    // A rows
    for (r = 0; r < gemm_m; r++) begin
      a_base = gemm_pa + (64'(r) * 64'(a_stride));
      for (w = 0; w < words_per_row; w++)
        wr8(a_base + (64'(w) << 3), pattern);
    end
    // B rows
    for (c = 0; c < gemm_n; c++) begin
      b_base = gemm_pb + (64'(c) * 64'(b_stride));
      for (w = 0; w < words_per_row; w++)
        wr8(b_base + (64'(w) << 3), pattern);
    end
    kick_gemm;
    if (straddle) begin
      $error("fmt %0d GEMM burst straddled stripe", numfmt);
      errors++;
    end
    rd8(64'h8000_0200, c0);
    rd8(64'h8000_0208, c1);
    if (numfmt == 3'd1) begin
      if (c0 !== C16 || c1 !== C16) begin
        $error("fmt %0d golden C exp=%h got %h %h", numfmt, C16, c0, c1);
        errors++;
      end
    end else begin
      if (c0 !== FP_C16 || c1 !== FP_C16) begin
        $error("fmt %0d golden C exp=%h got %h %h", numfmt, FP_C16, c0, c1);
        errors++;
      end
    end
  endtask

  task automatic run_wide;
    logic [AI_DRAM_MAX_CHANNELS-1:0][31:0] snap_r;
    logic [DATA_W-1:0] cw;
    int unsigned i;
    while (!ready && cycles < TO_RSP) tick;
    if (!ready) begin
      $error("gemm not ready for wide");
      errors++;
    end else begin
      snap_r = ch_r_beats;
      for (i = 0; i < NCH; i++) begin
        wr8(64'h8000_0000 + (64'(i) << 6), ONES8);
        wr8(64'h8000_0000 + (64'(i) << 6) + 64'd8, ONES8);
      end
      wr8(64'h8000_0200, ONES8);
      wr8(64'h8000_0208, ONES8);
      wr8(64'h8000_0210, ONES8);
      wr8(64'h8000_0218, ONES8);
      gemm_m   = 32'(NCH);
      gemm_n   = 32'd2;
      gemm_k   = 32'd16;
      gemm_lda = 16'd64;
      gemm_ldb = 16'd16;
      gemm_pa  = 64'h8000_0000;
      gemm_pb  = 64'h8000_0200;
      gemm_pc  = 64'h8000_0300;
      kick_gemm;
      if (straddle) begin
        $error("wide GEMM burst straddled stripe");
        errors++;
      end
      for (i = 0; i < NCH; i++) begin
        if (ch_r_beats[i] <= snap_r[i]) begin
          $error("wide occupancy silent ch%0d r %0d (was %0d)",
                 i, ch_r_beats[i], snap_r[i]);
          errors++;
        end
        rd8(64'h8000_0300 + (64'(i) << 3), cw);
        if (cw !== C16) begin
          $error("wide golden C row%0d exp=16,16 got %h", i, cw);
          errors++;
        end
      end
      check_cap;
    end
  endtask

  task automatic rd8(
      input  logic [ADDR_W-1:0] addr,
      output logic [DATA_W-1:0] data
  );
    mux_slv[0].ar_addr = addr;
    mux_slv[0].ar_len  = 8'd0;
    mux_slv[0].ar_size = 3'd3;
    mux_slv[0].ar_burst = 2'b01;
    r_ready_en = 1'b1;
    ar_set = 1'b1;
    tick;
    ar_set = 1'b0;
    while (ar_pend && cycles < TO_HS) tick;
    while (!mux_slv[0].r_valid && cycles < TO_RSP) tick;
    if (!mux_slv[0].r_valid) begin
      $error("timeout R addr=%h", addr);
      errors++;
      data = '0;
    end else
      data = mux_slv[0].r_data;
    tick;
  endtask

  function automatic int signed signed_value(input int side, row, element);
    return (side == 0 ? (2 * row + element) % 3 : (2 * row + 2 * element) % 3) - 1;
  endfunction

  function automatic logic [31:0] signed_unit_bits(input int value, input logic [2:0] fmt);
    logic [31:0] positive;
    int sign_bit;
    if (fmt == 0) return 32'(value) & 32'hff;
    if (fmt == 1) return 32'(value) & 32'hf;
    if (value == 0) return '0;
    positive = '0;
    sign_bit = 7;
    case (fmt)
      3: positive = 32'h38;
      4: positive = 32'h3c;
      5: begin positive = 32'h3c00; sign_bit = 15; end
      6: begin positive = 32'h3f80; sign_bit = 15; end
      7: begin positive = 32'h3f80_0000; sign_bit = 31; end
      default: ;
    endcase
    return positive | (value < 0 ? 32'd1 << sign_bit : 32'd0);
  endfunction

  function automatic logic [31:0] signed_integer_f32(input int signed value);
    logic [31:0] magnitude, mantissa;
    int top_bit;
    if (value == 0) return '0;
    magnitude = value < 0 ? 32'(-value) : 32'(value);
    top_bit = 0;
    for (int bit_index = 0; bit_index < 24; bit_index++)
      if (magnitude[bit_index]) top_bit = bit_index;
    mantissa = magnitude << (23 - top_bit);
    return {value < 0, 8'(127 + top_bit), mantissa[22:0]};
  endfunction

  // Signed {-1,0,1} operands for the 2 x n x 17 fixture (lda = ldb = 64 elements).
  task automatic signed_fill(input int fmt, input int shape, input int n);
    int bits_per_element, stride_bytes, elements_per_word, element, value;
    logic [63:0] base, word;
    bits_per_element = fmt == 1 ? 4 : (fmt == 7 ? 32 : ((fmt == 5 || fmt == 6) ? 16 : 8));
    stride_bytes = 64 * bits_per_element / 8;
    elements_per_word = 64 / bits_per_element;
    for (int side = 0; side < 2; side++) begin
      for (int row = 0; row < (side == 0 ? 2 : n); row++) begin
        base = (side == 0 ? 64'h8000_0400 : 64'h8000_0c00) + 64'(row * stride_bytes);
        for (int wi = 0; wi < stride_bytes / 8; wi++) begin
          word = '0;
          for (int slot = 0; slot < elements_per_word; slot++) begin
            element = wi * elements_per_word + slot;
            value = element < 17 ? signed_value(side, row, element + shape) : -1;
            word |= 64'(signed_unit_bits(value, 3'(fmt))) << (slot * bits_per_element);
          end
          wr8(base + 64'(wi * 8), word);
        end
      end
    end
  endtask

  // accmode 01: a K=17 job must equal job(k=8) followed by job(k=9, accumulate) on
  // the same C, bit for bit, for every format. The split sits on the lane width so
  // the RTL lane-tree partition is identical. Negative control: the second job
  // WITHOUT accumulate overwrites C with the partial only.
  task automatic accumulate_backend;
    int bits_per_element, expected, partial, checks;
    logic [63:0] word;
    logic [31:0] got, want;
    logic [31:0] got_full [2][3];
    checks = 0;
    for (int shape = 0; shape < 2; shape++) begin
    for (int fmt = 0; fmt < 8; fmt++) begin
      if (fmt != 2) begin
        bits_per_element = fmt == 1 ? 4 : (fmt == 7 ? 32 : ((fmt == 5 || fmt == 6) ? 16 : 8));
        gemm_m = 2; gemm_n = shape == 0 ? 3 : 1;
        gemm_lda = 64; gemm_ldb = 64; gemm_numfmt = 3'(fmt);
        signed_fill(fmt, shape, int'(gemm_n));
        // Reference: one long job.
        cycles = 0; accumulate = 1'b0;
        gemm_k = 17; gemm_pa = 64'h8000_0400; gemm_pb = 64'h8000_0c00; gemm_pc = 64'h8000_1800;
        for (int wi = 0; wi < 3; wi++) wr8(gemm_pc + 64'(wi * 8), 64'ha5a5_a5a5_a5a5_a5a5);
        kick_gemm;
        if (err || straddle) $fatal(1, "ACCUMULATE reference fmt=%0d", fmt);
        for (int row = 0; row < 2; row++)
          for (int column = 0; column < int'(gemm_n); column++) begin
            rd8(gemm_pc + 64'(((row * int'(gemm_n) + column) / 2) * 8), word);
            got_full[row][column] = 32'(word >> (32 * ((row * int'(gemm_n) + column) % 2)));
          end
        // Chained: k=8 then k=9 seeded from C (ptrs advanced by 8 elements).
        cycles = 0; accumulate = 1'b0; gemm_k = 8;
        for (int wi = 0; wi < 3; wi++) wr8(gemm_pc + 64'(wi * 8), 64'ha5a5_a5a5_a5a5_a5a5);
        kick_gemm;
        if (err) $fatal(1, "ACCUMULATE first half fmt=%0d", fmt);
        cycles = 0; accumulate = 1'b1; gemm_k = 9;
        gemm_pa = 64'h8000_0400 + 64'(8 * bits_per_element / 8);
        gemm_pb = 64'h8000_0c00 + 64'(8 * bits_per_element / 8);
        kick_gemm;
        if (err) $fatal(1, "ACCUMULATE second half fmt=%0d", fmt);
        for (int row = 0; row < 2; row++)
          for (int column = 0; column < int'(gemm_n); column++) begin
            expected = 0;
            for (int t = 0; t < 17; t++) expected += signed_value(0, row, t + shape) * signed_value(1, column, t + shape);
            rd8(gemm_pc + 64'(((row * int'(gemm_n) + column) / 2) * 8), word);
            got  = 32'(word >> (32 * ((row * int'(gemm_n) + column) % 2)));
            want = fmt <= 1 ? 32'(expected) : signed_integer_f32(expected);
            if (got !== want || got !== got_full[row][column])
              $fatal(1, "ACCUMULATE fmt=%0d row=%0d column=%0d got=%h expected=%h long=%h",
                     fmt, row, column, got, want, got_full[row][column]);
            checks++;
          end
        // Negative control: same second half without accmode overwrites with the partial.
        cycles = 0; accumulate = 1'b0;
        kick_gemm;
        if (err) $fatal(1, "ACCUMULATE control fmt=%0d", fmt);
        for (int row = 0; row < 2; row++)
          for (int column = 0; column < int'(gemm_n); column++) begin
            partial = 0;
            for (int t = 8; t < 17; t++) partial += signed_value(0, row, t + shape) * signed_value(1, column, t + shape);
            rd8(gemm_pc + 64'(((row * int'(gemm_n) + column) / 2) * 8), word);
            got  = 32'(word >> (32 * ((row * int'(gemm_n) + column) % 2)));
            want = fmt <= 1 ? 32'(partial) : signed_integer_f32(partial);
            if (got !== want) $fatal(1, "ACCUMULATE control fmt=%0d row=%0d column=%0d got=%h partial=%h", fmt, row, column, got, want);
            checks++;
          end
        accumulate = 1'b0;
      end
    end
    end
    $display("PASS ACCUMULATE checks=%0d", checks);
  endtask

  // `+review_flat`: flat panel mapping (K-split-to-residency). A job with
  // k = 2 * MAXDIM must be accepted as ONE job now that the K box is a byte
  // capacity, and its C must equal the chained k/2 + k/2 accumulate pair bit for
  // bit (the previously qualified path). INT8 (pitch 16 words at 8 lanes) and
  // FP32 (pitch 64 words) exercise two pitches; a panel that overflows the bank
  // (n = LimN rows of FP32 k = 2*MAXDIM) must be refused at ST_CHK with no
  // memory traffic. With REUSE_EN the flat job re-issued with FLAG_REUSE_B hits
  // (lb = 0): the residency the K-split used to defeat.
  function automatic int signed flat_value(input int side, row, element);
    return (side == 0 ? (2 * row + element) % 3 : (row + 2 * element) % 3) - 1;
  endfunction

  task automatic flat_fill(input int fmt, input int k, input int rows_a, input int rows_b);
    int bits_per_element, stride_bytes, elements_per_word, element, value;
    logic [63:0] base, word;
    bits_per_element = fmt == 7 ? 32 : 8;
    stride_bytes = k * bits_per_element / 8;
    elements_per_word = 64 / bits_per_element;
    for (int side = 0; side < 2; side++) begin
      for (int row = 0; row < (side == 0 ? rows_a : rows_b); row++) begin
        base = (side == 0 ? 64'h8000_0400 : 64'h8000_0800) + 64'(row * stride_bytes);
        for (int wi = 0; wi < stride_bytes / 8; wi++) begin
          word = '0;
          for (int slot = 0; slot < elements_per_word; slot++) begin
            element = wi * elements_per_word + slot;
            value = flat_value(side, row, element);
            word |= 64'(signed_unit_bits(value, 3'(fmt))) << (slot * bits_per_element);
          end
          wr8(base + 64'(wi * 8), word);
        end
      end
    end
  endtask

  task automatic flat_backend;
    int checks, k_full, expected, bits_per_element;
    logic [63:0] word;
    logic [31:0] got, want;
    logic [31:0] got_chain [2][4];
    checks = 0;
    k_full = 2 * GEMM_MAXDIM;
    for (int fmt = 0; fmt < 8; fmt += 7) begin   // INT8 and FP32
      bits_per_element = fmt == 7 ? 32 : 8;
      gemm_m = 2; gemm_n = 4; gemm_numfmt = 3'(fmt);
      gemm_lda = 16'(k_full); gemm_ldb = 16'(k_full);
      flat_fill(fmt, k_full, 2, 4);
      // Reference: the chained pair through accmode 01 (qualified path).
      gemm_pc = 64'h8000_1000;
      for (int wi = 0; wi < 4; wi++) wr8(gemm_pc + 64'(wi * 8), 64'ha5a5_a5a5_a5a5_a5a5);
      cycles = 0; accumulate = 1'b0; gemm_k = GEMM_MAXDIM;
      gemm_pa = 64'h8000_0400; gemm_pb = 64'h8000_0800;
      kick_gemm;
      if (err || straddle) $fatal(1, "FLAT chain first half fmt=%0d", fmt);
      cycles = 0; accumulate = 1'b1;
      gemm_pa = 64'h8000_0400 + 64'(GEMM_MAXDIM * bits_per_element / 8);
      gemm_pb = 64'h8000_0800 + 64'(GEMM_MAXDIM * bits_per_element / 8);
      kick_gemm;
      if (err) $fatal(1, "FLAT chain second half fmt=%0d", fmt);
      accumulate = 1'b0;
      for (int row = 0; row < 2; row++)
        for (int column = 0; column < 4; column++) begin
          rd8(gemm_pc + 64'(((row * 4 + column) / 2) * 8), word);
          got_chain[row][column] = 32'(word >> (32 * ((row * 4 + column) % 2)));
        end
      // Flat: one job with the full k. The residency key records the epoch the
      // job starts with, so arm it here (and drop whatever the chain left resident).
      for (int wi = 0; wi < 4; wi++) wr8(gemm_pc + 64'(wi * 8), 64'h5a5a_5a5a_5a5a_5a5a);
      if (REUSE_EN) begin
        reuse_b_inv = 1'b1; reuse_a_inv = 1'b1; tick; reuse_b_inv = 1'b0; reuse_a_inv = 1'b0;
        reuse_epoch = 32'd3;
      end
      cycles = 0; gemm_k = k_full;
      gemm_pa = 64'h8000_0400; gemm_pb = 64'h8000_0800;
      kick_gemm;
      if (err || straddle) $fatal(1, "FLAT full-k job refused fmt=%0d (k=%0d)", fmt, k_full);
      for (int row = 0; row < 2; row++)
        for (int column = 0; column < 4; column++) begin
          expected = 0;
          for (int t = 0; t < k_full; t++) expected += flat_value(0, row, t) * flat_value(1, column, t);
          rd8(gemm_pc + 64'(((row * 4 + column) / 2) * 8), word);
          got  = 32'(word >> (32 * ((row * 4 + column) % 2)));
          want = fmt == 0 ? 32'(expected) : signed_integer_f32(expected);
          if (got !== want || got !== got_chain[row][column])
            $fatal(1, "FLAT fmt=%0d row=%0d column=%0d got=%h expected=%h chain=%h",
                   fmt, row, column, got, want, got_chain[row][column]);
          checks++;
        end
      if (REUSE_EN) begin
        // Same panel again with FLAG_REUSE_B: served from the resident bank.
        cycles = 0; reuse_b_req = 1'b1;
        kick_gemm;
        reuse_b_req = 1'b0;
        if (err) $fatal(1, "FLAT reuse job fmt=%0d", fmt);
        if (reuse_b_hit !== 1'b1 || pmu_phase[1] != 0)
          $fatal(1, "FLAT reuse fmt=%0d hit_b=%0d lb=%0d: the flat panel must be resident", fmt, reuse_b_hit, pmu_phase[1]);
        for (int row = 0; row < 2; row++)
          for (int column = 0; column < 4; column++) begin
            rd8(gemm_pc + 64'(((row * 4 + column) / 2) * 8), word);
            got = 32'(word >> (32 * ((row * 4 + column) % 2)));
            if (got !== got_chain[row][column]) $fatal(1, "FLAT reuse C fmt=%0d", fmt);
          end
        checks++;
        reuse_b_inv = 1'b1; reuse_a_inv = 1'b1; tick; reuse_b_inv = 1'b0; reuse_a_inv = 1'b0;
        reuse_epoch = 32'd0;
      end
    end
    // Negative: n = LimN rows of FP32 at k = 2*MAXDIM overflow the B bank
    // (pitch 64 words x 64 rows = 4096 > 2048): refused, no memory traffic.
    begin
      logic [31:0] r_before;
      r_before = pmu_r;
      gemm_m = 1; gemm_n = 32'(GEMM_MAXDIM); gemm_k = k_full; gemm_numfmt = 3'd7;
      gemm_lda = 16'(k_full); gemm_ldb = 16'(k_full);
      cycles = 0;
      // kick_gemm counts err as a test error; this job must be refused, so drive it here.
      start = 1'b1; tick; start = 1'b0;
      while (!done && cycles < TO_RSP) tick;
      if (!done) $fatal(1, "FLAT capacity: refusal did not complete");
      if (!err) $fatal(1, "FLAT capacity: n=%0d k=%0d FP32 must be refused", GEMM_MAXDIM, k_full);
      if (pmu_r != 0 && pmu_r != r_before) $fatal(1, "FLAT capacity refusal moved read beats");
      checks++;
    end
    gemm_numfmt = 3'd0;
    $display("PASS FLAT_PANEL checks=%0d", checks);
  endtask

  // `+review_slots`: two-slot resident-B directory. Two INT8 panels that each fit
  // half the B bank stay resident together (both hit when alternated, the decode
  // pattern of a layer whose N spans two panels); a panel that needs the whole
  // bank ("big") evicts them, is itself resident, and is evicted by the next
  // small panel. Data differs per panel so a hit on the wrong slot is caught.
  task automatic slots_fill(input int sign, input logic [63:0] base, input int rows, input int k, input int side);
    logic [63:0] word;
    int value;
    for (int row = 0; row < rows; row++)
      for (int wi = 0; wi < k / 8; wi++) begin
        word = '0;
        for (int slot = 0; slot < 8; slot++) begin
          value = sign * flat_value(side, row, wi * 8 + slot);
          word |= 64'(signed_unit_bits(value, 3'd0)) << (slot * 8);
        end
        cycles = 0;   // wr8's handshake budget is per write, not per fill
        wr8(base + 64'(row * k + wi * 8), word);
      end
  endtask

  task automatic slots_check(input logic [63:0] pc, input int n, input int k, input int sign, input string what);
    logic [63:0] word;
    logic [31:0] got;
    int expected;
    for (int column = 0; column < n; column++) begin
      expected = 0;
      for (int t = 0; t < k; t++) expected += flat_value(0, 0, t) * sign * flat_value(1, column, t);
      rd8(pc + 64'((column / 2) * 8), word);
      got = 32'(word >> (32 * (column % 2)));
      if (got !== 32'(expected)) $fatal(1, "SLOTS %s column=%0d got=%h expected=%h", what, column, got, 32'(expected));
    end
  endtask

  task automatic slots_job(input logic [63:0] pa, pb, pc, input int n, input int k, input bit reuse, input bit want_hit, input string what);
    gemm_m = 1; gemm_n = 32'(n); gemm_k = 32'(k); gemm_numfmt = 3'd0;
    gemm_lda = 16'(k); gemm_ldb = 16'(k);
    gemm_pa = pa; gemm_pb = pb; gemm_pc = pc;
    cycles = 0; reuse_b_req = reuse;
    kick_gemm;
    reuse_b_req = 1'b0;
    if (err || straddle) $fatal(1, "SLOTS %s: job error", what);
    if (reuse_b_hit !== want_hit || (want_hit && pmu_phase[1] != 0) || (!want_hit && pmu_phase[1] == 0))
      $fatal(1, "SLOTS %s: hit_b=%0d lb=%0d, expected hit=%0d", what, reuse_b_hit, pmu_phase[1], want_hit);
  endtask

  task automatic slots_backend;
    int checks;
    // Layout inside the 8 KiB model (B_B is 48 x 136 = 6528 B): everything disjoint,
    // so each job is cacheable (the reuse key requires B and C not to overlap).
    localparam logic [63:0] B_B = 64'h8000_0000, A_B = 64'h8000_1A00, C_B = 64'h8000_1B00;
    localparam logic [63:0] A_S = 64'h8000_1C00, B0 = 64'h8000_1C80, B1 = 64'h8000_1D80, C_S = 64'h8000_1F00;
    localparam int N_S = 4, K_S = 64, N_B = 48, K_B = 136;   // 48 rows x 17 words -> pitch 32 words: 1536 > half (1024)
    checks = 0;
    if (!REUSE_EN) begin $display("PASS SLOTS_BACKEND checks=0 (REUSE_EN=0)"); return; end
    slots_fill(1, A_S, 1, K_S, 0);
    slots_fill(1, B0, N_S, K_S, 1);
    slots_fill(-1, B1, N_S, K_S, 1);
    slots_fill(1, A_B, 1, K_B, 0);
    slots_fill(1, B_B, N_B, K_B, 1);
    reuse_b_inv = 1'b1; reuse_a_inv = 1'b1; tick; reuse_b_inv = 1'b0; reuse_a_inv = 1'b0;
    reuse_epoch = 32'd5;
    slots_job(A_S, B0, C_S, N_S, K_S, 1'b1, 1'b0, "P0 cold");        slots_check(C_S, N_S, K_S, 1, "P0 cold");    checks++;
    slots_job(A_S, B1, C_S, N_S, K_S, 1'b1, 1'b0, "P1 cold");        slots_check(C_S, N_S, K_S, -1, "P1 cold");   checks++;
    slots_job(A_S, B0, C_S, N_S, K_S, 1'b1, 1'b1, "P0 resident");    slots_check(C_S, N_S, K_S, 1, "P0 resident"); checks++;
    slots_job(A_S, B1, C_S, N_S, K_S, 1'b1, 1'b1, "P1 resident");    slots_check(C_S, N_S, K_S, -1, "P1 resident"); checks++;
    slots_job(A_S, B0, C_S, N_S, K_S, 1'b1, 1'b1, "P0 resident 2");  slots_check(C_S, N_S, K_S, 1, "P0 resident 2"); checks++;
    // Without the reuse flag a hit is not taken (the flag is the software's consent).
    slots_job(A_S, B1, C_S, N_S, K_S, 1'b0, 1'b0, "P1 no-flag");     slots_check(C_S, N_S, K_S, -1, "P1 no-flag"); checks++;
    slots_job(A_S, B1, C_S, N_S, K_S, 1'b1, 1'b1, "P1 resident 2");  checks++;
    // Big panel: whole bank, evicts both slots, then resident itself.
    slots_job(A_B, B_B, C_B, N_B, K_B, 1'b1, 1'b0, "big cold");      slots_check(C_B, N_B, K_B, 1, "big cold"); checks++;
    slots_job(A_B, B_B, C_B, N_B, K_B, 1'b1, 1'b1, "big resident");  slots_check(C_B, N_B, K_B, 1, "big resident"); checks++;
    slots_job(A_S, B0, C_S, N_S, K_S, 1'b1, 1'b0, "P0 after big");   slots_check(C_S, N_S, K_S, 1, "P0 after big"); checks++;
    slots_job(A_B, B_B, C_B, N_B, K_B, 1'b1, 1'b0, "big after P0");  slots_check(C_B, N_B, K_B, 1, "big after P0"); checks++;
    slots_job(A_S, B1, C_S, N_S, K_S, 1'b1, 1'b0, "P1 after big");   slots_check(C_S, N_S, K_S, -1, "P1 after big"); checks++;
    slots_job(A_S, B0, C_S, N_S, K_S, 1'b1, 1'b0, "P0 after P1");    checks++;
    slots_job(A_S, B1, C_S, N_S, K_S, 1'b1, 1'b1, "P1 resident 3");  slots_check(C_S, N_S, K_S, -1, "P1 resident 3"); checks++;
    slots_job(A_S, B0, C_S, N_S, K_S, 1'b1, 1'b1, "P0 resident 3");  slots_check(C_S, N_S, K_S, 1, "P0 resident 3"); checks++;
    // Invalidation drops every slot.
    reuse_b_inv = 1'b1; tick; reuse_b_inv = 1'b0;
    slots_job(A_S, B0, C_S, N_S, K_S, 1'b1, 1'b0, "P0 after inv");   checks++;
    reuse_epoch = 32'd0;
    reuse_b_inv = 1'b1; reuse_a_inv = 1'b1; tick; reuse_b_inv = 1'b0; reuse_a_inv = 1'b0;
    $display("PASS SLOTS_BACKEND checks=%0d", checks);
  endtask

  task automatic signed_backend;
    int bits_per_element, expected, checks;
    logic [63:0] word;
    logic [31:0] got, want;
    checks = 0;
    if ((MAX_K == 0 ? GEMM_MAXDIM : int'(MAX_K)) < 17) $fatal(1, "SIGNED_BACKEND requires K>=17");
    for (int shape = 0; shape < 2; shape++) begin
    for (int fmt = 0; fmt < 8; fmt++) begin
      if (fmt != 2) begin
        cycles = 0;
        gemm_m = 2; gemm_n = shape == 0 ? 3 : 1; gemm_k = 17;
        gemm_lda = 64; gemm_ldb = 64;
        gemm_pa = 64'h8000_0400;
        gemm_pb = 64'h8000_0c00;
        gemm_pc = 64'h8000_1800;
        gemm_numfmt = 3'(fmt);
        bits_per_element = fmt == 1 ? 4 : (fmt == 7 ? 32 : ((fmt == 5 || fmt == 6) ? 16 : 8));
        signed_fill(fmt, shape, int'(gemm_n));
        for (int wi = 0; wi < 3; wi++) wr8(gemm_pc + 64'(wi * 8), 64'ha5a5_a5a5_a5a5_a5a5);
        kick_gemm;
        if (err || straddle) $fatal(1, "SIGNED_BACKEND execution fmt=%0d", fmt);
        for (int row = 0; row < 2; row++) begin
          for (int column = 0; column < int'(gemm_n); column++) begin
            expected = 0;
            for (int t = 0; t < 17; t++) expected += signed_value(0, row, t + shape) * signed_value(1, column, t + shape);
            rd8(gemm_pc + 64'(((row * int'(gemm_n) + column) / 2) * 8), word);
            got = 32'(word >> (32 * ((row * int'(gemm_n) + column) % 2)));
            want = fmt <= 1 ? 32'(expected) : signed_integer_f32(expected);
            if (got !== want) $fatal(1, "SIGNED_BACKEND fmt=%0d row=%0d column=%0d got=%h expected=%h", fmt, row, column, got, want);
            checks++;
          end
        end
      end
    end
    end
    $display("PASS SIGNED_BACKEND checks=%0d", checks);
  endtask

  // ---------------------------------------------------------------------------
  // Opt-in measurement sweep (+measure).  Sim-only and strictly additive.
  // ---------------------------------------------------------------------------

  // FP32 encoding of a whole power-of-two value: sign 0, exponent 127+log2(v),
  // zero mantissa.  Used for the all-ones golden C, where the dot equals k.
  function automatic logic [31:0] fp32_whole(input int unsigned v);
    return {1'b0, 8'(127 + $clog2(v)), 23'b0};
  endfunction

  // Store the m x k and n x k all-ones operand rows for one measurement job,
  // using the same byte/stride convention as run_fmt_float.
  task automatic measure_store(
      input logic [DATA_W-1:0] pattern,
      input int unsigned       bpe,
      input logic              is_packed
  );
    int unsigned r, c, w, words_per_row, ebytes;
    logic [63:0] a_base, b_base;
    logic [31:0] k_bytes, a_stride, b_stride;
    ebytes = (bpe == 0) ? 1 : bpe;
    if (is_packed) begin
      k_bytes  = (gemm_k + 32'd1) >> 1;
      a_stride = (32'(gemm_lda) + 32'd1) >> 1;
      b_stride = (32'(gemm_ldb) + 32'd1) >> 1;
    end else begin
      k_bytes  = gemm_k * ebytes;
      a_stride = 32'(gemm_lda) * ebytes;
      b_stride = 32'(gemm_ldb) * ebytes;
    end
    words_per_row = (k_bytes + 32'd7) / 32'd8;
    for (r = 0; r < gemm_m; r++) begin
      a_base = gemm_pa + (64'(r) * 64'(a_stride));
      for (w = 0; w < words_per_row; w++)
        wr8(a_base + (64'(w) << 3), pattern);
    end
    for (c = 0; c < gemm_n; c++) begin
      b_base = gemm_pb + (64'(c) * 64'(b_stride));
      for (w = 0; w < words_per_row; w++)
        wr8(b_base + (64'(w) << 3), pattern);
    end
  endtask

  // One numeric format, every legal ar_max in [1, GEMM_MAX_AR].  Same workload,
  // same operands, same pointers: only the AR cap moves.  The golden C is
  // re-checked per run AND pinned against the ar=1 reference, because a
  // prefetch-depth knob that changes arithmetic is a bug, not a tuning result.
  task automatic measure_fmt(
      input logic [2:0]        numfmt,
      input logic [DATA_W-1:0] pattern,
      input int unsigned       bpe,
      input logic              is_packed
  );
    int unsigned ar;
    logic [31:0] start_cy, run_cy;
    logic [DATA_W-1:0] golden, ref0, ref1;
    logic have_ref, straddle_pre;
    // All-ones operands make the dot exactly k, so the integer golden is k in
    // both packed 32-bit halves and the float golden is k.0 in FP32.  At k=16
    // these reduce to the directed C16 / FP_C16 constants, which is what lets
    // the k sweep reuse this task instead of needing a constant per k.
    golden      = (numfmt == 3'd0 || numfmt == 3'd1) ? {2{32'(gemm_k)}}
                                                     : {2{fp32_whole(gemm_k)}};
    have_ref    = 1'b0;
    ref0        = '0;
    ref1        = '0;
    gemm_numfmt = numfmt;
    for (ar = 1; ar <= unsigned'(GEMM_MAX_AR); ar++) begin
      straddle_pre = straddle;
      cycles       = 0;  // fresh timeout budget for this job; never the measurement
      ar_max_val   = 4'(ar);
      measure_store(pattern, bpe, is_packed);
      while (!ready && cycles < TO_RSP) tick;
      if (!ready) begin
        $error("MEASURE fmt=%0d ar=%0d sequencer never ready", numfmt, ar);
        errors++;
      end
      start_cy = free_cy;
      kick_gemm;
      run_cy = free_cy - start_cy;
      if (straddle && !straddle_pre) begin
        $error("MEASURE fmt=%0d ar=%0d burst straddled stripe", numfmt, ar);
        errors++;
      end
      rd8(gemm_pc,         c0);
      rd8(gemm_pc + 64'd8, c1);
      if (c0 !== golden || c1 !== golden) begin
        $error("MEASURE fmt=%0d ar=%0d golden C exp=%h got %h %h", numfmt, ar, golden, c0, c1);
        errors++;
      end
      if (!have_ref) begin
        ref0     = c0;
        ref1     = c1;
        have_ref = 1'b1;
      end else if (c0 !== ref0 || c1 !== ref1) begin
        $error("MEASURE fmt=%0d ar=%0d C differs from ar=1 exp=%h %h got %h %h",
               numfmt, ar, ref0, ref1, c0, c1);
        errors++;
      end
      $display("MEASURE fmt=%0d ar=%0d m=%0d n=%0d k=%0d macs=%0d cycles=%0d pmu_cycles=%0d r_beats=%0d w_beats=%0d c0=%h c1=%h la=%0d lb=%0d mac=%0d stc=%0d stall_ar=%0d stall_r=%0d stall_w=%0d",
               numfmt, ar, gemm_m, gemm_n, gemm_k, gemm_m * gemm_n * gemm_k,
               run_cy, pmu_cy, pmu_r, pmu_w, c0, c1,
               pmu_phase[0], pmu_phase[1], pmu_phase[2], pmu_phase[3],
               pmu_stall[0], pmu_stall[1], pmu_stall[2]);
      meas_runs++;
    end
  endtask

  // The sweep itself.  Restores the directed-phase timeout budget afterwards so
  // the PASS line keeps meaning the same thing as in a sweep-OFF run.
  //
  // Geometry matters for what this sweep can even observe.  g6lc_ai_gemm_seq
  // issues an A-phase AR only while `ar_i_q < m_q` and a B-phase AR only while
  // `ar_j_q < n_q`, so outstanding ARs are bounded by m (then n), NOT by
  // ar_max_eff alone.  At the directed 2x2x16 geometry no more than 2 ARs can
  // ever be inflight, which makes every ar_max >= 2 the same hardware and turns
  // any measured spread at depth 3..8 into memory-page noise.  The sweep
  // therefore uses m=n=8 so depths up to GEMM_MAX_AR=8 are actually reachable,
  // and k=16 so the golden C stays the same constant the directed phase checks.
  // 8x8x16 is also 1024 useful MACs instead of 64, which amortises the fixed
  // descriptor/AR/drain cost the 2x2x16 fixture was dominated by.
  //
  // MeasM x MeasK operands at 8 B/element worst case need 512 B per operand and
  // MeasM*MeasN 8 B results need 512 B, so the three regions are spaced 1 KiB
  // apart inside the NWORDS*8 = 8 KiB model.
  task automatic measure_sweep;
    int unsigned saved_cycles, pass, shape;
    saved_cycles = cycles;
    meas_runs    = 0;
    gemm_k   = MeasK;
    gemm_lda = 16'(MeasK);
    gemm_ldb = 16'(MeasK);
    // 16 rows x 16 elements x 4 B worst case is 1 KiB per operand, and 16x16
    // 32-bit results are another 1 KiB, so the three regions sit 1 KiB apart
    // inside the NWORDS*8 = 8 KiB model.
    gemm_pa  = 64'h8000_0400;
    gemm_pb  = 64'h8000_0800;
    gemm_pc  = 64'h8000_0C00;
    // Each pass is its own block, so the host analyser sees repeated
    // independent observations of the same (format, depth) instead of one
    // sample it would have to trust.  Run-to-run spread inside a block pair is
    // the memory-model noise floor, and no depth may be preferred on a margin
    // smaller than that floor.
    for (shape = 0; shape < MeasShapes; shape++) begin
      gemm_m = 32'(MeasMN[shape][0]);
      gemm_n = 32'(MeasMN[shape][1]);
      // A 32-row B operand (up to 2 KiB at FP32) needs its own room: B at 0x1000,
      // C (128 B) at 0x1C00, all inside the 8 KiB model and disjoint from A.
      gemm_pb = gemm_n > 16 ? 64'h8000_1000 : 64'h8000_0800;
      gemm_pc = gemm_n > 16 ? 64'h8000_1C00 : 64'h8000_0C00;
      for (pass = 0; pass < MeasPasses; pass++) begin
        meas_runs = 0;
        $display("MEASURE_BEGIN schema=g6lc.policy-measure.v1 tb=tb_g6lc_ai_gemm_backend cycle_source=free_running_rtl_counter class=%0d nch=%0d dpf=%0d ar_max=%0d pass=%0d lanes=%0d",
                 DRAM_CLASS, NCH, DOT_PIPE_FLOAT, GEMM_MAX_AR,
                 shape * MeasPasses + pass, GEMM_LANES);
        measure_fmt(3'd0, ONES8,      1, 1'b0);  // INT8
        measure_fmt(3'd1, INT4_1,     1, 1'b1);  // INT4 (two +1 nibbles per byte)
        measure_fmt(3'd3, FP8_E4M3_1, 1, 1'b0);  // FP8 E4M3
        measure_fmt(3'd4, FP8_E5M2_1, 1, 1'b0);  // FP8 E5M2
        measure_fmt(3'd5, FP16_1,     2, 1'b0);  // FP16
        measure_fmt(3'd6, BF16_1,     2, 1'b0);  // BF16
        measure_fmt(3'd7, FP32_1,     4, 1'b0);  // FP32
        $display("MEASURE_END runs=%0d formats=7 ar_max=%0d", meas_runs, GEMM_MAX_AR);
      end
    end
    ar_max_val  = 4'(GEMM_MAX_AR);
    gemm_numfmt = 3'd0;
    cycles = saved_cycles;
  endtask

  // `+measure_reuse` (needs -GREUSE_EN=1): the residency axis of the bench matrix.
  // Per format, at the committed measure geometry (m=n=8, k=MeasK): one cold job
  // after a residency invalidate, then the identical job with FLAG_REUSE_B, then with
  // FLAG_REUSE_A. The MEASURE line gains `reuse=` and the two PMU hit bits; the
  // golden C is re-checked on every pass because a residency hit that changes the
  // arithmetic is a bug, not a speedup. Same emulated stripe and cycle source as the
  // other measure sweeps: sequencer behaviour, not live geometry.
  task automatic measure_reuse_fmt(
      input logic [2:0]        numfmt,
      input logic [DATA_W-1:0] pattern,
      input int unsigned       bpe,
      input logic              is_packed
  );
    int unsigned pass_i;
    logic [31:0] start_cy, run_cy;
    logic [DATA_W-1:0] golden;
    string names [3] = '{"cold", "b", "a"};
    golden      = (numfmt == 3'd0 || numfmt == 3'd1) ? {2{32'(gemm_k)}}
                                                     : {2{fp32_whole(gemm_k)}};
    gemm_numfmt = numfmt;
    ar_max_val  = 4'(GEMM_MAX_AR);
    measure_store(pattern, bpe, is_packed);
    // Drop whatever the previous format left resident, then arm the epoch.
    reuse_b_req = 1'b0; reuse_a_req = 1'b0;
    reuse_b_inv = 1'b1; reuse_a_inv = 1'b1;
    tick;
    reuse_b_inv = 1'b0; reuse_a_inv = 1'b0;
    reuse_epoch = 32'd1;
    for (pass_i = 0; pass_i < 3; pass_i++) begin
      cycles      = 0;
      reuse_b_req = (pass_i == 1);
      reuse_a_req = (pass_i == 2);
      while (!ready && cycles < TO_RSP) tick;
      if (!ready) begin
        $error("MEASURE_REUSE fmt=%0d %s sequencer never ready", numfmt, names[pass_i]);
        errors++;
      end
      start_cy = free_cy;
      kick_gemm;
      run_cy = free_cy - start_cy;
      rd8(gemm_pc,         c0);
      rd8(gemm_pc + 64'd8, c1);
      if (c0 !== golden || c1 !== golden) begin
        $error("MEASURE_REUSE fmt=%0d %s golden C exp=%h got %h %h", numfmt, names[pass_i], golden, c0, c1);
        errors++;
      end
      if ((pass_i == 1 && reuse_b_hit !== 1'b1) || (pass_i == 2 && reuse_a_hit !== 1'b1) ||
          (pass_i == 0 && (reuse_b_hit !== 1'b0 || reuse_a_hit !== 1'b0))) begin
        $error("MEASURE_REUSE fmt=%0d %s hit b=%0d a=%0d unexpected", numfmt, names[pass_i], reuse_b_hit, reuse_a_hit);
        errors++;
      end
      $display("MEASURE fmt=%0d ar=%0d m=%0d n=%0d k=%0d macs=%0d cycles=%0d pmu_cycles=%0d r_beats=%0d w_beats=%0d c0=%h c1=%h la=%0d lb=%0d mac=%0d stc=%0d stall_ar=%0d stall_r=%0d stall_w=%0d reuse=%s hit_b=%0d hit_a=%0d",
               numfmt, GEMM_MAX_AR, gemm_m, gemm_n, gemm_k, gemm_m * gemm_n * gemm_k,
               run_cy, pmu_cy, pmu_r, pmu_w, c0, c1,
               pmu_phase[0], pmu_phase[1], pmu_phase[2], pmu_phase[3],
               pmu_stall[0], pmu_stall[1], pmu_stall[2], names[pass_i], reuse_b_hit, reuse_a_hit);
      meas_runs++;
    end
    reuse_b_req = 1'b0; reuse_a_req = 1'b0;
    reuse_b_inv = 1'b1; reuse_a_inv = 1'b1;
    tick;
    reuse_b_inv = 1'b0; reuse_a_inv = 1'b0;
    reuse_epoch = 32'd0;
  endtask

  task automatic measure_reuse_sweep;
    int unsigned saved_cycles;
    saved_cycles = cycles;
    meas_runs    = 0;
    gemm_k   = MeasK;
    gemm_lda = 16'(MeasK);
    gemm_ldb = 16'(MeasK);
    gemm_pa  = 64'h8000_0400;
    gemm_pb  = 64'h8000_0800;
    gemm_pc  = 64'h8000_0C00;
    gemm_m   = 32'd8;
    gemm_n   = 32'd8;
    if (!REUSE_EN) begin
      $error("measure_reuse needs -GREUSE_EN=1");
      errors++;
    end
    $display("MEASURE_BEGIN schema=g6lc.policy-measure.v1 tb=tb_g6lc_ai_gemm_backend cycle_source=free_running_rtl_counter class=%0d nch=%0d dpf=%0d ar_max=%0d pass=0 lanes=%0d axis=reuse",
             DRAM_CLASS, NCH, DOT_PIPE_FLOAT, GEMM_MAX_AR, GEMM_LANES);
    measure_reuse_fmt(3'd0, ONES8,      1, 1'b0);
    measure_reuse_fmt(3'd1, INT4_1,     1, 1'b1);
    measure_reuse_fmt(3'd3, FP8_E4M3_1, 1, 1'b0);
    measure_reuse_fmt(3'd4, FP8_E5M2_1, 1, 1'b0);
    measure_reuse_fmt(3'd5, FP16_1,     2, 1'b0);
    measure_reuse_fmt(3'd6, BF16_1,     2, 1'b0);
    measure_reuse_fmt(3'd7, FP32_1,     4, 1'b0);
    $display("MEASURE_END runs=%0d formats=7 ar_max=%0d axis=reuse", meas_runs, GEMM_MAX_AR);
    gemm_numfmt = 3'd0;
    cycles = saved_cycles;
  endtask

  // `+measure_k`: sweep the reduction length k against lane width to test the
  // k_bytes rule.  g6lc_ai_gemm_seq ends a reduction when mac_step >= k, with
  // mac_step = 2*PeLanes for INT4 and PeLanes/bytes otherwise, so the lanes a
  // dot can actually use should be fmt_row_bytes(k) -- the operand row in bytes
  // -- rather than a function of element width alone.  The +measure sweep only
  // ever ran k=16, where the two coincide.  Prediction under the rule: INT4's
  // optimum moves 8 -> 16 -> 32 lanes as k goes 16 -> 32 -> 64, and INT8's moves
  // 16 -> 32 -> 64.  If instead the optimum stays put, the decision is not
  // k-dependent and the sub-code has no runtime-varying choice to make.
  //
  // Integer formats only: the golden C is exactly k, and one byte per element
  // keeps a 64-element row inside the 8 KiB model at 1 KiB region spacing.
  task automatic measure_k_sweep;
    int unsigned saved_cycles, ki, pass;
    int unsigned klist [3] = '{16, 32, 64};
    saved_cycles = cycles;
    gemm_m   = 32'd8;
    gemm_n   = 32'd8;
    gemm_pa  = 64'h8000_0400;
    gemm_pb  = 64'h8000_0800;
    gemm_pc  = 64'h8000_0C00;
    for (ki = 0; ki < 3; ki++) begin
      if (klist[ki] <= unsigned'(GEMM_MAXDIM)) begin
        gemm_k   = 32'(klist[ki]);
        gemm_lda = 16'(klist[ki]);
        gemm_ldb = 16'(klist[ki]);
        for (pass = 0; pass < MeasPasses; pass++) begin
          meas_runs = 0;
          $display("MEASURE_BEGIN schema=g6lc.policy-measure.v1 tb=tb_g6lc_ai_gemm_backend cycle_source=free_running_rtl_counter class=%0d nch=%0d dpf=%0d ar_max=%0d pass=%0d lanes=%0d",
                   DRAM_CLASS, NCH, DOT_PIPE_FLOAT, GEMM_MAX_AR,
                   ki * MeasPasses + pass, GEMM_LANES);
          measure_fmt(3'd0, ONES8,  1, 1'b0);  // INT8
          measure_fmt(3'd1, INT4_1, 1, 1'b1);  // INT4
          $display("MEASURE_END runs=%0d formats=2 ar_max=%0d", meas_runs, GEMM_MAX_AR);
        end
      end
    end
    ar_max_val  = 4'(GEMM_MAX_AR);
    gemm_numfmt = 3'd0;
    cycles = saved_cycles;
  endtask

  // Opt-in (+panel_reuse). Reuse blocks exist only when REUSE_EN is set.
  // k=1 all-ones, so every C element is 1. Shapes use the panel dimensions
  // (m=1024, n=512) so the key registers are wide enough for those indices.
  task automatic panel_job(
      input int unsigned m,
      input int unsigned n,
      input logic        rb,
      input logic        ra,
      input logic        inv,
      input logic        exp_b,
      input logic        exp_a,
      input logic [63:0] c0_addr,
      input logic [63:0] c1_addr,
      input string       tag,
      output int unsigned r_beats
  );
    logic [63:0] got;
    int unsigned guard;
    cycles = 0;
    gemm_m = m;
    gemm_n = n;
    gemm_k = 32'd1;
    gemm_lda = 16'd1;
    gemm_ldb = 16'd1;
    gemm_numfmt = 3'd0;
    gemm_pa = 64'h8000_0000;
    gemm_pb = 64'h8000_0800;
    gemm_pc = panel_pc;
    reuse_b_req = rb;
    reuse_a_req = ra;
    reuse_b_inv = inv;
    reuse_a_inv = inv;
    reuse_epoch = panel_epoch;
    wr8(c0_addr, 64'hDEAD_BEEF_DEAD_BEEF);
    if (c1_addr != c0_addr)
      wr8(c1_addr, 64'hDEAD_BEEF_DEAD_BEEF);
    guard = 0;
    while (!ready && guard < 1000) begin
      tick;
      guard++;
    end
    if (!ready) begin
      $error("panel %s not ready", tag);
      errors++;
      r_beats = 0;
      return;
    end
    start = 1'b1;
    tick;
    start = 1'b0;
    guard = cycles;
    while (!done && cycles < guard + 100000) tick;
    if (!done || err) begin
      $error("panel %s done=%0d err=%0d cy=%0d", tag, done, err, cycles);
      errors++;
      r_beats = 0;
      return;
    end
    r_beats = pmu_r;
    if (reuse_b_hit !== exp_b || reuse_a_hit !== exp_a) begin
      $error("panel %s hit b=%0d a=%0d exp %0d/%0d r=%0d",
             tag, reuse_b_hit, reuse_a_hit, exp_b, exp_a, pmu_r);
      errors++;
    end
    // rd8 compares against the absolute timeout budget. The job may have
    // used that budget already; the read itself is a handful of cycles.
    cycles = 0;
    rd8(c0_addr, got);
    if (got !== 64'h0000_0001_0000_0001) begin
      $error("panel %s C0 %h", tag, got);
      errors++;
    end
    if (c1_addr != c0_addr) begin
      rd8(c1_addr, got);
      if (got !== 64'h0000_0001_0000_0001) begin
        $error("panel %s C1 %h", tag, got);
        errors++;
      end
    end
  endtask

  task automatic panel_key_check;
    int unsigned i, r_cold, r_hit;
    logic [63:0] pa, pb, pc;
    if (!REUSE_EN || MAX_M < 1024 || MAX_N < 512 || MAX_K < 1) begin
      $error("panel_reuse needs REUSE_EN and MAX_M>=1024 MAX_N>=512");
      errors++;
      return;
    end
    pa = 64'h8000_0000;
    pb = 64'h8000_0800;
    pc = 64'h8000_1000;
    panel_epoch = 32'd0;
    panel_pc = 64'h8000_1000;
    cycles = 0;
    while (!ready && cycles < 1000) tick;
    for (i = 0; i < 128; i++)
      wr8(pa + (64'(i) * 64'd8), ONES8);
    for (i = 0; i < 64; i++)
      wr8(pb + (64'(i) * 64'd8), ONES8);
    // Invalidate held: a reuse request does not hit and does not install a key.
    // m=4, n=2 with invalidate held. Full reads; this is the cold beat count.
    panel_job(4, 2, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, pc, pc + 64'd16, "inv", r_cold);
    // Prime B at n=2, m=8. The m=4 key was not installed while invalidate was held.
    panel_job(8, 2, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, pc, pc + 64'd48, "prime-b", r_hit);
    // Same B, different m. B hits, and the read count drops against the cold m=4.
    panel_job(4, 2, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0, pc, pc + 64'd16, "hit-b", r_hit);
    if (r_hit == 0 || r_hit >= r_cold) begin
      $error("panel hit-b reads %0d not below cold %0d", r_hit, r_cold);
      errors++;
    end
    // n is in the B key. 2 then 4 must miss.
    panel_job(4, 4, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, pc, pc + 64'd48, "miss-n", r_hit);
    // n is not in the A key. Same m, wider n, A hits.
    panel_job(4, 8, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1, pc, pc + 64'd96, "hit-a", r_hit);
    // m=1024 walks the tall panel index. A from m=4 must not hit.
    panel_job(1024, 2, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0,
              pc, pc + 64'd8176, "tall", r_hit);
    // Same m=1024, different n. A hits.
    panel_job(1024, 4, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1, pc, pc + 64'd32, "hit-a-tall", r_hit);
    // n=512 walks the wide panel index.
    panel_job(2, 512, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, pc, pc + 64'd2040, "wide", r_hit);
    // Same n=512, different m. B hits.
    panel_job(8, 512, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0, pc, pc + 64'd2040, "hit-b-wide", r_hit);
    // n=128 is a different B key from n=512.
    panel_job(2, 128, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, pc, pc + 64'd504, "miss-128", r_hit);
    // Epoch 1 does not match the resident 0. The same epoch then hits,
    // and dropping back to 0 misses A. The island pin stays 0.
    panel_epoch = 32'd1;
    panel_job(2, 128, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, pc, pc + 64'd504, "miss-epoch-b", r_cold);
    panel_job(2, 128, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0, pc, pc + 64'd504, "hit-epoch-b", r_hit);
    if (r_hit == 0 || r_hit >= r_cold) begin
      $error("panel hit-epoch-b reads %0d not below miss %0d", r_hit, r_cold);
      errors++;
    end
    panel_epoch = 32'd0;
    panel_pc = 64'h8000_1000;
    panel_job(2, 128, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, pc, pc + 64'd504, "miss-epoch-a", r_cold);
    panel_job(2, 128, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1, pc, pc + 64'd504, "hit-epoch-a", r_hit);
    if (r_hit == 0 || r_hit >= r_cold) begin
      $error("panel hit-epoch-a reads %0d not below miss %0d", r_hit, r_cold);
      errors++;
    end
    panel_epoch = 32'd0;
    panel_pc = 64'h8000_1000;
    reuse_epoch = 32'd0;
    // C starts on B. The key matches, the skip must not fire, and the
    // key must not stay valid. The checked pair is past the B bytes.
    panel_pc = pb;
    panel_job(2, 128, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, pb + 64'd512, pb + 64'd512,
              "overlap-b", r_hit);
    for (i = 0; i < 16; i++)
      wr8(pb + (64'(i) * 64'd8), ONES8);
    panel_pc = pc;
    panel_job(2, 128, 1'b1, 1'b0, 1'b0, 1'b0, 1'b0, pc, pc + 64'd504, "miss-ov-b", r_cold);
    panel_job(2, 128, 1'b1, 1'b0, 1'b0, 1'b1, 1'b0, pc, pc + 64'd504, "hit-ov-b", r_hit);
    if (r_hit == 0 || r_hit >= r_cold) begin
      $error("panel hit-ov-b reads %0d not below miss %0d", r_hit, r_cold);
      errors++;
    end
    // C starts on A. Same rule for the A key. The checked pair is past
    // the two A bytes.
    panel_pc = pa;
    panel_job(2, 128, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, pa + 64'd8, pa + 64'd8,
              "overlap-a", r_hit);
    for (i = 0; i < 128; i++)
      wr8(pa + (64'(i) * 64'd8), ONES8);
    panel_pc = pc;
    panel_job(2, 128, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, pc, pc + 64'd504, "miss-ov-a", r_cold);
    panel_job(2, 128, 1'b0, 1'b1, 1'b0, 1'b0, 1'b1, pc, pc + 64'd504, "hit-ov-a", r_hit);
    if (r_hit == 0 || r_hit >= r_cold) begin
      $error("panel hit-ov-a reads %0d not below miss %0d", r_hit, r_cold);
      errors++;
    end
    panel_pc = pc;
    $display("PANEL keys m=%0d n=%0d reuse=%0d epoch=1 ov=1", MAX_M, MAX_N, REUSE_EN);
  endtask

  initial begin
    errors = 0;
    cycles = 0;
    meas_runs = 0;
    start = 0;
    reuse_b_req = 1'b0;
    reuse_a_req = 1'b0;
    reuse_b_inv = 1'b1;
    reuse_a_inv = 1'b1;
    reuse_epoch = 32'd0;
    panel_epoch = 32'd0;
    panel_pc = 64'h8000_1000;
    gemm_m = 32'd2; gemm_n = 32'd2; gemm_k = 32'd16;
    gemm_lda = 16'd16; gemm_ldb = 16'd16; gemm_numfmt = 3'd0;
    gemm_pa = 64'h8000_0038;
    gemm_pb = 64'h8000_0100;
    gemm_pc = 64'h8000_0200;
    cap_req = 0;
    cap_addr = 0;
    aw_set = 0; w_set = 0; ar_set = 0;
    b_ready_en = 1;
    r_ready_en = 1;
    idle_payload();
    rst_ni = 0;
    repeat (8) tick;
    rst_ni = 1;
    repeat (32) tick;

    if (!init_done) begin
      $error("backend init_done");
      errors++;
    end
    if (!ready) begin
      $error("gemm not ready");
      errors++;
    end

    wr8(64'h8000_0038, ONES8);
    wr8(64'h8000_0040, ONES8);
    wr8(64'h8000_0048, ONES8);
    wr8(64'h8000_0050, ONES8);
    wr8(64'h8000_0100, ONES8);
    wr8(64'h8000_0108, ONES8);
    wr8(64'h8000_0110, ONES8);
    wr8(64'h8000_0118, ONES8);

    // High run: policy off / fallback (max AR). Capture reference C.
    ar_max_val = 4'(GEMM_MAX_AR);
    start = 1'b1;
    tick;
    start = 1'b0;
    while (!done && cycles < TO_RSP) tick;

    if (!done) begin
      $error("timeout gemm cycles=%0d ar=%0d", cycles, n_ar);
      errors++;
    end
    if (err) begin
      $error("gemm err");
      errors++;
    end
    if (straddle) begin
      $error("GEMM burst straddled stripe");
      errors++;
    end
    if (NCH > 1) begin
      if (!saw_cap) begin
        $error("missing cap AR at 0x38");
        errors++;
      end
      if (!saw_next) begin
        $error("missing AR at 0x40");
        errors++;
      end
      if (!saw_id2 || !saw_id3) begin
        $error("split AR ids saw2=%0d saw3=%0d", saw_id2, saw_id3);
        errors++;
      end
      if (max_inf < 2) begin
        $error("two IDs in flight max_inf=%0d", max_inf);
        errors++;
      end
      if (ch_r_beats[0] == 0 || ch_r_beats[1] == 0) begin
        $error("occupancy silent r %0d/%0d", ch_r_beats[0], ch_r_beats[1]);
        errors++;
      end
    end else begin
      if (!saw_id2) begin
        $error("N=1 GEMM must keep AR id 2");
        errors++;
      end
      if (saw_id3) begin
        $error("N=1 GEMM must not split AR ids");
        errors++;
      end
    end

    rd8(64'h8000_0200, c0);
    rd8(64'h8000_0208, c1);
    if ($test$plusargs("oracle_negative")) c0 = c0 ^ DATA_W'(1);
    if (c0 !== C16 || c1 !== C16) begin
      $error("golden C exp=16,16 got %h %h", c0, c1);
      errors++;
    end
    c0_eqv = c0;
    c1_eqv = c1;

    // Low run: policy consumer on (advisory ar_max=2).  Must match reference C.
    if (4'(GEMM_MAX_AR) > 4'd2) begin
      while (!ready && cycles < TO_RSP) tick;
      ar_max_val = 4'd2;
      start = 1'b1;
      tick;
      start = 1'b0;
      while (!done && cycles < TO_RSP) tick;
      if (!done) begin
        $error("timeout low-ar gemm cycles=%0d ar=%0d", cycles, n_ar);
        errors++;
      end
      if (err) begin
        $error("gemm err low-ar");
        errors++;
      end
      if (straddle) begin
        $error("low-ar GEMM burst straddled stripe");
        errors++;
      end
      rd8(64'h8000_0200, c0);
      rd8(64'h8000_0208, c1);
      if (c0 !== C16 || c1 !== C16) begin
        $error("low-ar golden C exp=16,16 got %h %h", c0, c1);
        errors++;
      end
      if (c0 !== c0_eqv || c1 !== c1_eqv) begin
        $error("ar_max equivalence failed exp=%h %h got=%h %h", c0_eqv, c1_eqv, c0, c1);
        errors++;
      end
    end

    // Restore max AR for the remaining format sweep.
    ar_max_val = 4'(GEMM_MAX_AR);

    // Integer INT4 packed run (two +1 nibbles per byte => dot = 16).
    // numfmt=1 is INT4; bpe is ignored because packed=1.
    run_fmt_float(3'd1, INT4_1, 1, 1'b1); // INT4

    // Floating GEMM runs: each uses all-1.0 operands and expects FP32 16.0.
    // numfmt encodings: 3=FP8 E4M3, 4=FP8 E5M2, 5=FP16, 6=BF16, 7=FP32.
    run_fmt_float(3'd3, FP8_E4M3_1, 1, 1'b0); // FP8 E4M3
    run_fmt_float(3'd4, FP8_E5M2_1, 1, 1'b0); // FP8 E5M2
    run_fmt_float(3'd5, FP16_1,    2, 1'b0); // FP16
    run_fmt_float(3'd6, BF16_1,    2, 1'b0); // BF16
    run_fmt_float(3'd7, FP32_1,    4, 1'b0); // FP32

    check_cap;
    gemm_numfmt = 3'd0;
    if (NCH >= 2)
      run_wide;

    // Opt-in and last: the directed phase above is untouched when it is off.
    // `+measure` is the committed shape/format/AR basis; `+measure_k` is the
    // separate k-versus-lanes experiment, kept apart so the earlier evidence
    // stays reproducible byte for byte.
    if ($test$plusargs("measure"))
      measure_sweep;
    if ($test$plusargs("measure_k"))
      measure_k_sweep;
    if ($test$plusargs("measure_reuse"))
      measure_reuse_sweep;
    // Separate elaboration (REUSE_EN, MAX_M/N/K). The live package keeps
    // VaTurboEn clear, so this does not run in the default backend script.
    if ($test$plusargs("panel_reuse"))
      panel_key_check;

    if ($test$plusargs("review_signed") || $test$plusargs("review_protocol")) signed_backend;
    if ($test$plusargs("review_accumulate")) accumulate_backend;
    if ($test$plusargs("review_flat")) flat_backend;
    if ($test$plusargs("review_slots")) slots_backend;
    if ($test$plusargs("review_protocol")) begin
      if (protocol_stalls == 0) $fatal(1, "AXI_NO_STALL_WITNESS");
      $display("PASS AXI_PROTOCOL stalls=%0d", protocol_stalls);
    end
    if (errors == 0)
      $display("PASS g6lc_ai_gemm_backend class=%0d nch=%0d ar=%0d cycles=%0d r=%0d/%0d goldenC=16 cap%s",
               DRAM_CLASS, NCH, n_ar, cycles, ch_r_beats[0], ch_r_beats[1],
               (NCH >= 2) ? " wide" : "");
    else begin
      $display("FAIL g6lc_ai_gemm_backend errors=%0d", errors);
      $fatal(1);
    end
    $finish;
  end
endmodule
