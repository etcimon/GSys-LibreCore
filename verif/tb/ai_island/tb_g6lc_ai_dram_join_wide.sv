// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// V1 wide channel, as a directed leaf: a 512-bit class-0 channel behind
// g6lc_ai_dram_join with a 64-bit cluster port (CLUSTER_DATA_WIDTH upsizer) and
// a 512-bit island port (gen_island_same). This is the exact shape of the
// G6LC_AI_DRAM_WIDE_CH SoC model on which the core made no progress, reduced
// to four questions the SoC could not answer without a waveform:
//   Q1 a cluster 8-byte write then read returns the data (the core's path);
//   Q2 a cluster 8-byte read of preloaded memory returns it (instruction fetch);
//   Q3 an island narrow (size 3) 8-byte write lands at its address and leaves
//      the neighbouring bytes of the 64-byte word intact (the C pair / completion
//      word / descriptor beat shape on a wide channel);
//   Q4 an island full-width 64-byte write/read round-trips.
// Each question fails with its own message.
module tb_g6lc_ai_dram_join_wide;
  localparam int unsigned AW = 64;
  localparam int unsigned CW = 64;    // cluster (xbar) width
  localparam int unsigned DW = 512;   // channel = island width
  localparam int unsigned IW = 4;
  localparam int unsigned UW = 1;
  localparam logic [63:0] DRAM = 64'h8000_0000;
  localparam int unsigned NWORDS = 256;  // 256 x 64 B = 16 KiB

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  AXI_BUS #(.AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(CW), .AXI_ID_WIDTH(IW), .AXI_USER_WIDTH(UW)) cl ();
  AXI_BUS #(.AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW), .AXI_ID_WIDTH(IW), .AXI_USER_WIDTH(UW)) is ();
  AXI_BUS #(.AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW), .AXI_ID_WIDTH(IW + 1), .AXI_USER_WIDTH(UW)) mst ();
  logic [7:0][31:0] ch_r, ch_w;

  g6lc_ai_dram_join #(
      .AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW), .CLUSTER_DATA_WIDTH(CW), .AXI_ID_WIDTH(IW),
      .AXI_USER_WIDTH(UW), .ISLAND_DATA_WIDTH(DW), .MAX_AR_OUT(2),
      .DRAM_BASE(DRAM), .DRAM_BYTES(64'h0000_4000), .FATAL_LOCK(1'b0)
  ) i_join (
      .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0), .init_done_i(1'b1),
      .cluster(cl), .island(is), .master(mst)
  );

  g6lc_ai_dram_backend #(
      .DramClass(0), .AXI_ID_WIDTH(IW + 1), .AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW),
      .AXI_USER_WIDTH(UW), .AXI_USER_EN(0), .NUM_WORDS(NWORDS),
      .NrChannels(1), .ChanShift(6), .MaxAROut(2)
  ) i_mem (
      .clk_i(clk), .rst_ni(rst_n), .rst_sram_ni(rst_n), .testmode_i(1'b0),
      .slave(mst), .init_done_o(), .ch_r_beats_o(ch_r), .ch_w_beats_o(ch_w)
  );

  task automatic idle;
    cl.aw_valid = 0; cl.w_valid = 0; cl.b_ready = 0; cl.ar_valid = 0; cl.r_ready = 0;
    is.aw_valid = 0; is.w_valid = 0; is.b_ready = 0; is.ar_valid = 0; is.r_ready = 0;
  endtask

  // Cluster 8-byte write / read (the core's shape through the upsizer).
  task automatic cl_wr64(input logic [63:0] addr, input logic [63:0] data, input string what);
    int guard;
    @(negedge clk);
    cl.aw_id = '0; cl.aw_addr = addr; cl.aw_len = 0; cl.aw_size = 3; cl.aw_burst = 1;
    cl.aw_lock = 0; cl.aw_cache = 0; cl.aw_prot = 0; cl.aw_qos = 0; cl.aw_region = 0;
    cl.aw_atop = 0; cl.aw_user = 0; cl.aw_valid = 1; cl.b_ready = 1;
    cl.w_data = data; cl.w_strb = '1; cl.w_last = 1; cl.w_user = 0; cl.w_valid = 1;
    guard = 0; do begin @(posedge clk); guard++; end while (!cl.aw_ready && guard < 60);
    if (!cl.aw_ready) $fatal(1, "%s: cluster AW never accepted (upsizer)", what);
    @(negedge clk); cl.aw_valid = 0;
    guard = 0; do begin @(posedge clk); guard++; end while (!cl.w_ready && guard < 60);
    if (!cl.w_ready) $fatal(1, "%s: cluster W never accepted (upsizer)", what);
    @(negedge clk); cl.w_valid = 0;
    guard = 0; do begin @(posedge clk); guard++; end while (!cl.b_valid && guard < 60);
    if (!cl.b_valid) $fatal(1, "%s: cluster B never returned", what);
    if (cl.b_resp != 2'b00) $fatal(1, "%s: cluster B resp %h", what, cl.b_resp);
    @(negedge clk); cl.b_ready = 0;
  endtask

  task automatic cl_rd64(input logic [63:0] addr, output logic [63:0] data, input string what);
    int guard;
    @(negedge clk);
    cl.ar_id = 4'h1; cl.ar_addr = addr; cl.ar_len = 0; cl.ar_size = 3; cl.ar_burst = 1;
    cl.ar_lock = 0; cl.ar_cache = 0; cl.ar_prot = 0; cl.ar_qos = 0; cl.ar_region = 0;
    cl.ar_user = 0; cl.ar_valid = 1; cl.r_ready = 1;
    guard = 0; do begin @(posedge clk); guard++; end while (!cl.ar_ready && guard < 60);
    if (!cl.ar_ready) $fatal(1, "%s: cluster AR never accepted (upsizer)", what);
    @(negedge clk); cl.ar_valid = 0;
    guard = 0; do begin @(posedge clk); guard++; end while (!(cl.r_valid && cl.r_last) && guard < 60);
    if (!(cl.r_valid && cl.r_last)) $fatal(1, "%s: cluster R never returned (upsizer)", what);
    if (cl.r_resp != 2'b00) $fatal(1, "%s: cluster R resp %h", what, cl.r_resp);
    data = cl.r_data;
    @(negedge clk); cl.r_ready = 0;
  endtask

  // Island write of `nbytes` (8 = narrow size 3 at the address lane; 64 = full beat).
  task automatic is_wr(input logic [63:0] addr, input logic [DW-1:0] data, input logic [DW/8-1:0] strb,
                       input logic [2:0] size, input string what);
    int guard;
    @(negedge clk);
    is.aw_id = 4'h3; is.aw_addr = addr; is.aw_len = 0; is.aw_size = size; is.aw_burst = 1;
    is.aw_lock = 0; is.aw_cache = 0; is.aw_prot = 0; is.aw_qos = 0; is.aw_region = 0;
    is.aw_atop = '0; is.aw_user = 0; is.aw_valid = 1; is.b_ready = 1;
    is.w_data = data; is.w_strb = strb; is.w_last = 1; is.w_user = 0; is.w_valid = 1;
    guard = 0; do begin @(posedge clk); guard++; end while (!is.aw_ready && guard < 60);
    if (!is.aw_ready) $fatal(1, "%s: island AW never accepted", what);
    @(negedge clk); is.aw_valid = 0;
    guard = 0; do begin @(posedge clk); guard++; end while (!is.w_ready && guard < 60);
    if (!is.w_ready) $fatal(1, "%s: island W never accepted", what);
    @(negedge clk); is.w_valid = 0;
    guard = 0; do begin @(posedge clk); guard++; end while (!is.b_valid && guard < 60);
    if (!is.b_valid) $fatal(1, "%s: island B never returned", what);
    if (is.b_resp != 2'b00) $fatal(1, "%s: island B resp %h", what, is.b_resp);
    @(negedge clk); is.b_ready = 0;
  endtask

  task automatic is_rd(input logic [63:0] addr, input logic [2:0] size, output logic [DW-1:0] data, input string what);
    int guard;
    @(negedge clk);
    is.ar_id = 4'h5; is.ar_addr = addr; is.ar_len = 0; is.ar_size = size; is.ar_burst = 1;
    is.ar_lock = 0; is.ar_cache = 0; is.ar_prot = 0; is.ar_qos = 0; is.ar_region = 0;
    is.ar_user = 0; is.ar_valid = 1; is.r_ready = 1;
    guard = 0; do begin @(posedge clk); guard++; end while (!is.ar_ready && guard < 60);
    if (!is.ar_ready) $fatal(1, "%s: island AR never accepted", what);
    @(negedge clk); is.ar_valid = 0;
    guard = 0; do begin @(posedge clk); guard++; end while (!(is.r_valid && is.r_last) && guard < 60);
    if (!(is.r_valid && is.r_last)) $fatal(1, "%s: island R never returned", what);
    if (is.r_resp != 2'b00) $fatal(1, "%s: island R resp %h", what, is.r_resp);
    data = is.r_data;
    @(negedge clk); is.r_ready = 0;
  endtask

  logic [63:0] d64;
  logic [DW-1:0] dwide, fill;
  initial begin
    idle();
    repeat (3) @(posedge clk);
    rst_n = 1;
    repeat (3) @(posedge clk);

    // Q4 first: fill a 64-byte word from the island at full width so the narrow
    // questions have known neighbours.
    for (int b = 0; b < 64; b++) fill[b*8 +: 8] = 8'hA0 + b[7:0];
    is_wr(DRAM + 64'h100, fill, '1, 3'd6, "Q4 island full-width write");
    is_rd(DRAM + 64'h100, 3'd6, dwide, "Q4 island full-width read");
    if (dwide !== fill) $fatal(1, "Q4 FAIL: island 64-byte round-trip got %h", dwide[63:0]);

    // Q1: cluster 8-byte write then read through the upsizer.
    cl_wr64(DRAM + 64'h040, 64'h1122_3344_5566_7788, "Q1 cluster write");
    cl_rd64(DRAM + 64'h040, d64, "Q1 cluster read");
    if (d64 !== 64'h1122_3344_5566_7788) $fatal(1, "Q1 FAIL: cluster round-trip got %h", d64);

    // Q2: cluster 8-byte read of a lane inside the island-filled word (fetch shape).
    cl_rd64(DRAM + 64'h118, d64, "Q2 cluster read of lane 3");
    if (d64 !== fill[3*64 +: 64]) $fatal(1, "Q2 FAIL: cluster read of lane 3 got %h want %h", d64, fill[3*64 +: 64]);

    // Q3: island narrow (size 3) 8-byte write into lane 5 of the filled word.
    begin
      logic [DW-1:0] nd; logic [DW/8-1:0] ns;
      nd = '0; ns = '0;
      nd[5*64 +: 64] = 64'hCAFE_F00D_DEAD_BEEF; ns[5*8 +: 8] = 8'hFF;
      is_wr(DRAM + 64'h128, nd, ns, 3'd3, "Q3 island narrow write");
    end
    is_rd(DRAM + 64'h100, 3'd6, dwide, "Q3 island full-width readback");
    if (dwide[5*64 +: 64] !== 64'hCAFE_F00D_DEAD_BEEF)
      $fatal(1, "Q3 FAIL: island narrow write did not land at lane 5 (got %h)", dwide[5*64 +: 64]);
    for (int l = 0; l < 8; l++)
      if (l != 5 && dwide[l*64 +: 64] !== fill[l*64 +: 64])
        $fatal(1, "Q3 FAIL: island narrow write clobbered lane %0d (got %h)", l, dwide[l*64 +: 64]);
    // ... and the cluster sees it too.
    cl_rd64(DRAM + 64'h128, d64, "Q3 cluster read of the narrow write");
    if (d64 !== 64'hCAFE_F00D_DEAD_BEEF) $fatal(1, "Q3 FAIL: cluster reads %h after the island narrow write", d64);

    // Q5 throughput: a 16-beat 64 B island INCR read (the B-row shape at K=1024):
    // cycles per beat on the wide path. Correctness above; this is the number the SoC
    // could not give. Expect 1.00 cycles/beat (64 B/cycle).
    begin
      int t0, t1, beats, guard;
      @(negedge clk);
      is.ar_id = 4'h6; is.ar_addr = DRAM + 64'h400; is.ar_len = 15; is.ar_size = 3'd6; is.ar_burst = 1;
      is.ar_lock = 0; is.ar_cache = 0; is.ar_prot = 0; is.ar_qos = 0; is.ar_region = 0;
      is.ar_user = 0; is.ar_valid = 1; is.r_ready = 1;
      guard = 0; do begin @(posedge clk); guard++; end while (!is.ar_ready && guard < 60);
      if (!is.ar_ready) $fatal(1, "Q5: 16-beat island AR never accepted");
      t0 = $time; beats = 0;
      @(negedge clk); is.ar_valid = 0;
      guard = 0;
      while (beats < 16 && guard < 400) begin
        @(posedge clk); guard++;
        if (is.r_valid && is.r_ready) begin beats++; if (is.r_last && beats != 16) $fatal(1, "Q5: early r_last at beat %0d", beats); end
      end
      t1 = $time;
      if (beats != 16) $fatal(1, "Q5 FAIL: got %0d of 16 beats", beats);
      $display("Q5 island 16 x 64 B read burst: %0d cycles from AR accept to last beat (%0.2f cycles/beat incl. latency)",
               (t1 - t0) / 10, real'(t1 - t0) / 10.0 / 16.0);
      if ((t1 - t0) / 10 > 24) $fatal(1, "Q5 FAIL: wide path slower than 1.5 cycles/beat");
      @(negedge clk); is.r_ready = 0;
    end

    $display("PASS tb_g6lc_ai_dram_join_wide");
    $finish;
  end

  initial begin
    repeat (4000) @(posedge clk);
    $fatal(1, "timeout");
  end
endmodule
