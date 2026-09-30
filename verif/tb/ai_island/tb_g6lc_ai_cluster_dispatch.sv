// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// V3/V4 cluster dispatch leaf. A 2-cluster and a 4-cluster dispatch run the same
// INT8 GEMM as a single engine against a shared-memory backend; the single engine's
// C is the golden. Shapes: m=2 n=32 k=16 (two 16-column slices; on 4 clusters two
// slices are empty and complete at once) and m=3 n=48 k=8 (slices 16/16/16; the
// third cluster of four idles). Also: the dispatch's PMU cycles must not exceed the
// single engine's (parallel slices), and the per-slice ldc keeps rows at pitch n.
module tb_g6lc_ai_cluster_dispatch;
  localparam int unsigned AW = 64, DW = 64, IW = 6, UW = 1;
  localparam logic [63:0] DRAM = 64'h8000_0000;
  localparam logic [63:0] PA = DRAM + 64'h0000, PB = DRAM + 64'h1000;
  localparam logic [63:0] PC0 = DRAM + 64'h2000, PC2 = DRAM + 64'h3000, PC4 = DRAM + 64'h4000;
  localparam int unsigned NWORDS = 4096;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  typedef logic [AW-1:0] addr_t;
  typedef logic [IW-1:0] id_t;
  typedef logic [IW-2:0] id5_t;   // 2 clusters: one prefix bit
  typedef logic [IW-3:0] id4_t;   // 4 clusters: two prefix bits
  typedef logic [UW-1:0] user_t;
  typedef logic [DW-1:0] data_t;
  typedef logic [DW/8-1:0] strb_t;
  `AXI_TYPEDEF_ALL(m6, addr_t, id_t, data_t, strb_t, user_t)
  `AXI_TYPEDEF_ALL(e5, addr_t, id5_t, data_t, strb_t, user_t)
  `AXI_TYPEDEF_ALL(e4, addr_t, id4_t, data_t, strb_t, user_t)

  // three engines share one memory through a 3:1 mux (each master keeps its IDs)
  m6_req_t  [2:0] req;
  m6_resp_t [2:0] rsp;
  typedef logic [IW+1:0] mid_t;
  `AXI_TYPEDEF_ALL(mm, addr_t, mid_t, data_t, strb_t, user_t)
  mm_req_t  mreq;
  mm_resp_t mrsp;
  AXI_BUS #(.AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW), .AXI_ID_WIDTH(IW + 2), .AXI_USER_WIDTH(UW)) mst ();
  `AXI_ASSIGN_FROM_REQ(mst, mreq)
  `AXI_ASSIGN_TO_RESP(mrsp, mst)
  logic [7:0][31:0] ch_r, ch_w;

  axi_mux #(
      .SlvAxiIDWidth(IW), .slv_aw_chan_t(m6_aw_chan_t), .mst_aw_chan_t(mm_aw_chan_t),
      .w_chan_t(m6_w_chan_t), .slv_b_chan_t(m6_b_chan_t), .mst_b_chan_t(mm_b_chan_t),
      .slv_ar_chan_t(m6_ar_chan_t), .mst_ar_chan_t(mm_ar_chan_t),
      .slv_r_chan_t(m6_r_chan_t), .mst_r_chan_t(mm_r_chan_t),
      .slv_req_t(m6_req_t), .slv_resp_t(m6_resp_t), .mst_req_t(mm_req_t), .mst_resp_t(mm_resp_t),
      .NoSlvPorts(3), .MaxWTrans(4), .FallThrough(1'b0),
      .SpillAw(1'b1), .SpillW(1'b0), .SpillB(1'b0), .SpillAr(1'b1), .SpillR(1'b0)
  ) i_mux (
      .clk_i(clk), .rst_ni(rst_n), .test_i(1'b0),
      .slv_reqs_i(req), .slv_resps_o(rsp), .mst_req_o(mreq), .mst_resp_i(mrsp)
  );
  g6lc_ai_dram_backend #(
      .DramClass(0), .AXI_ID_WIDTH(IW + 2), .AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW),
      .AXI_USER_WIDTH(UW), .AXI_USER_EN(0), .NUM_WORDS(NWORDS),
      .NrChannels(1), .ChanShift(6), .MaxAROut(4)
  ) i_mem (
      .clk_i(clk), .rst_ni(rst_n), .rst_sram_ni(rst_n), .testmode_i(1'b0),
      .slave(mst), .init_done_o(), .ch_r_beats_o(ch_r), .ch_w_beats_o(ch_w)
  );

  // job registers
  logic [31:0] m, n, k;
  logic [63:0] pc [3];
  logic start [3];
  logic ready [3], done [3], err [3];
  logic [31:0] cyc [3];

  g6lc_ai_gemm_seq #(
      .AddrWidth(AW), .DataWidth(DW), .IdWidth(IW), .MaxDim(64), .PeLanes(8),
      .MaxAROut(2), .axi_req_t(m6_req_t), .axi_resp_t(m6_resp_t)
  ) i_single (
      .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0),
      .start_i(start[0]), .m_i(m), .n_i(n), .k_i(k), .lda_i(16'd64), .ldb_i(16'd64), .ldc_i(16'd0),
      .numfmt_i(3'd0), .accumulate_i(1'b0), .ar_max_i(4'd0),
      .ptr_a_i(PA), .ptr_b_i(PB), .ptr_c_i(pc[0]),
      .ready_o(ready[0]), .done_o(done[0]), .err_o(err[0]),
      .pmu_r_beats_o(), .pmu_w_beats_o(), .pmu_cycles_o(cyc[0]), .pmu_phase_o(), .pmu_stall_o(),
      .reuse_b_i(1'b0), .reuse_b_epoch_i('0), .reuse_b_invalidate_i(1'b1), .pmu_reuse_b_hit_o(),
      .reuse_a_i(1'b0), .reuse_a_epoch_i('0), .reuse_a_invalidate_i(1'b1), .pmu_reuse_a_hit_o(),
      .axi_req_o(req[0]), .axi_resp_i(rsp[0])
  );

  g6lc_ai_cluster_dispatch #(
      .Clusters(2), .AddrWidth(AW), .DataWidth(DW), .IdWidth(IW), .MaxDim(64), .PeLanes(8),
      .MaxAROut(2), .axi_req_t(m6_req_t), .axi_resp_t(m6_resp_t),
      .eng_req_t(e5_req_t), .eng_resp_t(e5_resp_t)
  ) i_d2 (
      .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0),
      .start_i(start[1]), .m_i(m), .n_i(n), .k_i(k), .lda_i(16'd64), .ldb_i(16'd64),
      .numfmt_i(3'd0), .accumulate_i(1'b0), .ar_max_i(4'd0),
      .ptr_a_i(PA), .ptr_b_i(PB), .ptr_c_i(pc[1]),
      .ready_o(ready[1]), .done_o(done[1]), .err_o(err[1]),
      .pmu_r_beats_o(), .pmu_w_beats_o(), .pmu_cycles_o(cyc[1]), .pmu_phase_o(), .pmu_stall_o(),
      .reuse_b_i(1'b0), .reuse_b_epoch_i('0), .reuse_b_invalidate_i(1'b1), .pmu_reuse_b_hit_o(),
      .reuse_a_i(1'b0), .reuse_a_epoch_i('0), .reuse_a_invalidate_i(1'b1), .pmu_reuse_a_hit_o(),
      .axi_req_o(req[1]), .axi_resp_i(rsp[1])
  );

  g6lc_ai_cluster_dispatch #(
      .Clusters(4), .AddrWidth(AW), .DataWidth(DW), .IdWidth(IW), .MaxDim(64), .PeLanes(8),
      .MaxAROut(2), .axi_req_t(m6_req_t), .axi_resp_t(m6_resp_t),
      .eng_req_t(e4_req_t), .eng_resp_t(e4_resp_t)
  ) i_d4 (
      .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0),
      .start_i(start[2]), .m_i(m), .n_i(n), .k_i(k), .lda_i(16'd64), .ldb_i(16'd64),
      .numfmt_i(3'd0), .accumulate_i(1'b0), .ar_max_i(4'd0),
      .ptr_a_i(PA), .ptr_b_i(PB), .ptr_c_i(pc[2]),
      .ready_o(ready[2]), .done_o(done[2]), .err_o(err[2]),
      .pmu_r_beats_o(), .pmu_w_beats_o(), .pmu_cycles_o(cyc[2]), .pmu_phase_o(), .pmu_stall_o(),
      .reuse_b_i(1'b0), .reuse_b_epoch_i('0), .reuse_b_invalidate_i(1'b1), .pmu_reuse_b_hit_o(),
      .reuse_a_i(1'b0), .reuse_a_epoch_i('0), .reuse_a_invalidate_i(1'b1), .pmu_reuse_a_hit_o(),
      .axi_req_o(req[2]), .axi_resp_i(rsp[2])
  );

  // backdoor memory access (64-bit words of the class-0 SRAM)
  function automatic logic [63:0] mem_rd(input logic [63:0] addr);
    return i_mem.gen_sim_axi.i_sram.gen_cut[0].i_tc_sram_wrapper.i_tc_sram.sram[(addr - DRAM) >> 3];
  endfunction
  task automatic mem_wr(input logic [63:0] addr, input logic [63:0] data);
    i_mem.gen_sim_axi.i_sram.gen_cut[0].i_tc_sram_wrapper.i_tc_sram.sram[(addr - DRAM) >> 3] = data;
  endtask

  task automatic run(input int which);
    int guard;
    guard = 0; do begin @(posedge clk); guard++; end while (!ready[which] && guard < 200);
    if (!ready[which]) $fatal(1, "engine %0d not ready", which);
    @(negedge clk); start[which] = 1;
    @(negedge clk); start[which] = 0;
    guard = 0; do begin @(posedge clk); guard++; end while (!done[which] && guard < 60000);
    if (!done[which]) $fatal(1, "engine %0d timeout", which);
    if (err[which]) $fatal(1, "engine %0d err", which);
  endtask

  task automatic compare(input string what);
    int r, c;
    logic [63:0] g, d2, d4;
    for (r = 0; r < m; r++)
      for (c = 0; c < n; c += 2) begin
        g  = mem_rd(PC0 + 64'((r * n + c) * 4));
        d2 = mem_rd(PC2 + 64'((r * n + c) * 4));
        d4 = mem_rd(PC4 + 64'((r * n + c) * 4));
        if (d2 !== g) $fatal(1, "%s: 2-cluster C[%0d][%0d..] %h != golden %h", what, r, c, d2, g);
        if (d4 !== g) $fatal(1, "%s: 4-cluster C[%0d][%0d..] %h != golden %h", what, r, c, d4, g);
      end
    // sentinel past the panel
    if (mem_rd(PC2 + 64'((m * n) * 4)) !== 64'hFEED_FACE_FEED_FACE) $fatal(1, "%s: 2-cluster wrote past C", what);
    if (mem_rd(PC4 + 64'((m * n) * 4)) !== 64'hFEED_FACE_FEED_FACE) $fatal(1, "%s: 4-cluster wrote past C", what);
    // A job with more than one slice must be faster than the single engine; a
    // single-slice job pays only the dispatch register and the mux (a few cycles).
    if (n > 16 && cyc[1] >= cyc[0]) $fatal(1, "%s: 2-cluster not faster than single (%0d >= %0d)", what, cyc[1], cyc[0]);
    if (cyc[1] > cyc[0] + 8) $fatal(1, "%s: dispatch overhead too high (%0d vs %0d)", what, cyc[1], cyc[0]);
    $display("%s: golden match, cycles single %0d / 2-cluster %0d / 4-cluster %0d", what, cyc[0], cyc[1], cyc[2]);
  endtask

  task automatic shape(input int mm_, input int nn_, input int kk_, input string what);
    int i;
    m = mm_; n = nn_; k = kk_;
    // A: rows of 64 B (lda 64), B: rows of 64 B, distinct byte patterns
    for (i = 0; i < 64 * 8; i++) mem_wr(PA + 64'(i * 8), 64'h0102_0304_0506_0708 + 64'(i) * 64'h0101_0101_0101_0101);
    for (i = 0; i < 64 * 8; i++) mem_wr(PB + 64'(i * 8), 64'h1011_1213_1415_1617 ^ (64'(i) * 64'h0307_0B0D_1113_1719));
    for (i = 0; i < 512; i++) begin mem_wr(PC0 + 64'(i * 8), 64'h0); mem_wr(PC2 + 64'(i * 8), 64'h0); mem_wr(PC4 + 64'(i * 8), 64'h0); end
    mem_wr(PC2 + 64'((m * n) * 4), 64'hFEED_FACE_FEED_FACE);
    mem_wr(PC4 + 64'((m * n) * 4), 64'hFEED_FACE_FEED_FACE);
    pc[0] = PC0; pc[1] = PC2; pc[2] = PC4;
    run(0); run(1); run(2);
    compare(what);
  endtask

  initial begin
    start[0] = 0; start[1] = 0; start[2] = 0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    repeat (3) @(posedge clk);
    shape(2, 32, 16, "m2 n32 k16");
    shape(3, 48, 8,  "m3 n48 k8");
    shape(1, 16, 64, "m1 n16 k64 (one slice)");
    $display("PASS tb_g6lc_ai_cluster_dispatch");
    $finish;
  end

  initial begin
    repeat (200000) @(posedge clk);
    $fatal(1, "timeout");
  end
endmodule
