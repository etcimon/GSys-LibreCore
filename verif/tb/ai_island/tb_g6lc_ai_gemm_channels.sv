// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// GEMM vs class-1 LiteDRAM stripe (g6lc_ai_dram_channels).
// Job 1: 2x2 k=16 golden C=16 + CAP occupancy. Job 2 (N>1): lda=64 so
// each A row is one 64 B stripe — all NCH read occupancy live. Not Variane.

`timescale 1ns/1ps
`include "axi/typedef.svh"
`include "axi/assign.svh"

module tb_g6lc_ai_gemm_channels
  import g6lc_ai_island_cfg_pkg::*;
#(
    parameter int unsigned NCH = 2
);
  localparam int unsigned ID_W    = 4;
  localparam int unsigned MST_ID  = ID_W + 1;
  localparam int unsigned ADDR_W  = 64;
  localparam int unsigned DATA_W  = 64;
  localparam int unsigned NWORDS  = 1024;
  localparam int unsigned TO_HS   = 40000;
  localparam int unsigned TO_RSP  = 80000;
  localparam logic [DATA_W-1:0] ONES8 = 64'h0101_0101_0101_0101;
  localparam logic [DATA_W-1:0] C16   = 64'h0000_0010_0000_0010;

  typedef logic [ADDR_W-1:0]     addr_t;
  typedef logic [ID_W-1:0]       id_t;
  typedef logic [DATA_W-1:0]     data_t;
  typedef logic [DATA_W/8-1:0]   strb_t;
  typedef logic [0:0]            user_t;
  `AXI_TYPEDEF_ALL(gbus, addr_t, id_t, data_t, strb_t, user_t)

  logic clk, rst_ni, init_done, start, ready, done, err;
  logic [31:0] gemm_m, gemm_n, gemm_k;
  logic [15:0] gemm_lda, gemm_ldb;
  logic [63:0] gemm_pa, gemm_pb, gemm_pc;
  logic aw_pend, w_pend, ar_pend, aw_set, w_set, ar_set;
  logic b_ready_en, r_ready_en;
  gbus_req_t  gemm_req;
  gbus_resp_t gemm_resp;
  logic [AI_DRAM_MAX_CHANNELS-1:0][31:0] ch_r_beats, ch_w_beats;
  logic [31:0] pmu_r, pmu_w, pmu_cy;
  logic        cap_req, cap_rvalid;
  logic [15:0] cap_addr;
  logic [31:0] cap_rdata;
  int unsigned errors, cycles, n_ar, max_inf;
  logic saw_cap, saw_next, saw_id2, saw_id3, straddle;
  logic [15:0] inf_ids;
  logic [DATA_W-1:0] r_data_cap;

  AXI_BUS #(.AXI_ADDR_WIDTH(ADDR_W), .AXI_DATA_WIDTH(DATA_W),
            .AXI_ID_WIDTH(ID_W), .AXI_USER_WIDTH(1)) mux_slv[1:0]();
  AXI_BUS #(.AXI_ADDR_WIDTH(ADDR_W), .AXI_DATA_WIDTH(DATA_W),
            .AXI_ID_WIDTH(MST_ID), .AXI_USER_WIDTH(1)) dram();

  `AXI_ASSIGN_FROM_REQ(mux_slv[1], gemm_req)
  `AXI_ASSIGN_TO_RESP(gemm_resp, mux_slv[1])

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

  g6lc_ai_dram_channels #(
      .NrChannels     ( NCH ),
      .ChanShift      ( AI_DRAM_CHAN_SHIFT_DEFAULT ),
      .AXI_ID_WIDTH   ( MST_ID ),
      .AXI_ADDR_WIDTH ( ADDR_W ),
      .AXI_DATA_WIDTH ( DATA_W ),
      .AXI_USER_WIDTH ( 1 ),
      .MaxAROut       ( AI_MAX_AR_OUT_DRAM )
  ) i_mem (
      .clk_i        ( clk ),
      .rst_ni       ( rst_ni ),
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

  g6lc_ai_gemm_seq #(
      .AddrWidth  ( ADDR_W ),
      .DataWidth  ( DATA_W ),
      .IdWidth    ( ID_W ),
      .MaxDim     ( 16 ),
      .PeLanes    ( 8 ),
      .MaxAROut   ( AI_MAX_AR_OUT_DRAM ),
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
      .ldb_i        ( gemm_ldb ),
      .numfmt_i     ( 3'd0 ),
      .accumulate_i(1'b0),
      .ar_max_i     ( 4'(AI_MAX_AR_OUT_DRAM) ),
      .ptr_a_i      ( gemm_pa ),
      .ptr_b_i      ( gemm_pb ),
      .ptr_c_i      ( gemm_pc ),
      .ready_o      ( ready ),
      .done_o       ( done ),
      .err_o        ( err ),
      .pmu_r_beats_o( pmu_r ),
      .pmu_w_beats_o( pmu_w ),
      .pmu_cycles_o ( pmu_cy ),
      .pmu_phase_o (), .pmu_stall_o (),
      .reuse_b_i(1'b0), .reuse_b_epoch_i(32'd0), .reuse_b_invalidate_i(1'b1),
      .pmu_reuse_b_hit_o(),
      .reuse_a_i(1'b0), .reuse_a_epoch_i(32'd0), .reuse_a_invalidate_i(1'b1),
      .pmu_reuse_a_hit_o(),
      .axi_req_o    ( gemm_req ),
      .axi_resp_i   ( gemm_resp )
  );

  initial clk = 0;
  always #5 clk = ~clk;

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

  initial begin
    logic [DATA_W-1:0] c0, c1;
    errors = 0;
    cycles = 0;
    start = 0;
    gemm_m = 32'd2; gemm_n = 32'd2; gemm_k = 32'd16;
    gemm_lda = 16'd16; gemm_ldb = 16'd16;
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
      $error("LiteDRAM init_done");
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
    end

    rd8(64'h8000_0200, c0);
    rd8(64'h8000_0208, c1);
    if (c0 !== C16 || c1 !== C16) begin
      $error("golden C exp=16,16 got %h %h", c0, c1);
      errors++;
    end

    check_cap;
    if (NCH >= 2)
      run_wide;

    if (errors == 0)
      $display("PASS g6lc_ai_gemm_channels nch=%0d ar=%0d cycles=%0d r=%0d/%0d goldenC=16 cap%s",
               NCH, n_ar, cycles, ch_r_beats[0], ch_r_beats[1],
               (NCH >= 2) ? " wide" : "");
    else begin
      $display("FAIL g6lc_ai_gemm_channels errors=%0d", errors);
      $fatal(1);
    end
    $finish;
  end
endmodule
