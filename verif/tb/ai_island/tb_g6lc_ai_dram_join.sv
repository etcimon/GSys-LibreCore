// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Directed checks for g6lc_ai_dram_join. The live testharness does not
// elaborate this path (G6LC_AI_DRAM_ISLAND_PORT is unset).

`include "axi/assign.svh"

module tb_g6lc_ai_dram_join;
  localparam int unsigned AW = 64;
  localparam int unsigned DW = 64;
  localparam int unsigned IW = 4;
  localparam int unsigned UW = 1;
  localparam logic [63:0] DRAM = 64'h8000_0000;
  localparam int unsigned NWORDS = 1024;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  AXI_BUS #(.AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW), .AXI_ID_WIDTH(IW), .AXI_USER_WIDTH(UW))
      cl (), is (), mem ();
  AXI_BUS #(.AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW), .AXI_ID_WIDTH(IW + 1), .AXI_USER_WIDTH(UW))
      mst ();
  AXI_BUS #(.AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(128), .AXI_ID_WIDTH(IW), .AXI_USER_WIDTH(UW))
      isw ();
  AXI_BUS #(.AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW), .AXI_ID_WIDTH(IW), .AXI_USER_WIDTH(UW))
      clw ();
  AXI_BUS #(.AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW), .AXI_ID_WIDTH(IW + 1), .AXI_USER_WIDTH(UW))
      mstw ();
  AXI_BUS #(.AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(512), .AXI_ID_WIDTH(IW), .AXI_USER_WIDTH(UW))
      iss ();
  AXI_BUS #(.AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW), .AXI_ID_WIDTH(IW), .AXI_USER_WIDTH(UW))
      cls ();
  AXI_BUS #(.AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW), .AXI_ID_WIDTH(IW + 1), .AXI_USER_WIDTH(UW))
      msts ();

  logic [7:0][31:0] ch_r, ch_w, ch_rw, ch_ww, ch_rs, ch_ws;

  g6lc_ai_dram_join #(
      .AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW), .AXI_ID_WIDTH(IW), .AXI_USER_WIDTH(UW),
      .ISLAND_DATA_WIDTH(DW), .MAX_AR_OUT(1),
      .DRAM_BASE(DRAM), .DRAM_BYTES(64'h0000_1000), .FATAL_LOCK(1'b0)
  ) i_join (
      .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0), .init_done_i(1'b1),
      .cluster(cl), .island(is), .master(mst)
  );

  g6lc_ai_dram_backend #(
      .DramClass(0), .AXI_ID_WIDTH(IW + 1), .AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW),
      .AXI_USER_WIDTH(UW), .AXI_USER_EN(0), .NUM_WORDS(NWORDS),
      .NrChannels(2), .ChanShift(6), .MaxAROut(2)
  ) i_mem (
      .clk_i(clk), .rst_ni(rst_n), .rst_sram_ni(rst_n), .testmode_i(1'b0),
      .slave(mst), .init_done_o(), .ch_r_beats_o(ch_r), .ch_w_beats_o(ch_w)
  );

  g6lc_ai_dram_join #(
      .AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW), .AXI_ID_WIDTH(IW), .AXI_USER_WIDTH(UW),
      .ISLAND_DATA_WIDTH(128), .MAX_AR_OUT(2),
      .DRAM_BASE(DRAM), .DRAM_BYTES(64'h0000_1000), .FATAL_LOCK(1'b1)
  ) i_wide (
      .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0), .init_done_i(1'b1),
      .cluster(clw), .island(isw), .master(mstw)
  );

  g6lc_ai_dram_backend #(
      .DramClass(0), .AXI_ID_WIDTH(IW + 1), .AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW),
      .AXI_USER_WIDTH(UW), .AXI_USER_EN(0), .NUM_WORDS(NWORDS),
      .NrChannels(2), .ChanShift(6), .MaxAROut(2)
  ) i_wide_mem (
      .clk_i(clk), .rst_ni(rst_n), .rst_sram_ni(rst_n), .testmode_i(1'b0),
      .slave(mstw), .init_done_o(), .ch_r_beats_o(ch_rw), .ch_w_beats_o(ch_ww)
  );

  // 512-bit island beat: the NocWidth of AiIslandLatencySkuTarget. Channel stays 64.
  g6lc_ai_dram_join #(
      .AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW), .AXI_ID_WIDTH(IW), .AXI_USER_WIDTH(UW),
      .ISLAND_DATA_WIDTH(512), .MAX_AR_OUT(2),
      .DRAM_BASE(DRAM), .DRAM_BYTES(64'h0000_1000), .FATAL_LOCK(1'b1)
  ) i_sku (
      .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0), .init_done_i(1'b1),
      .cluster(cls), .island(iss), .master(msts)
  );

  g6lc_ai_dram_backend #(
      .DramClass(0), .AXI_ID_WIDTH(IW + 1), .AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW),
      .AXI_USER_WIDTH(UW), .AXI_USER_EN(0), .NUM_WORDS(NWORDS),
      .NrChannels(1), .ChanShift(6), .MaxAROut(2)
  ) i_sku_mem (
      .clk_i(clk), .rst_ni(rst_n), .rst_sram_ni(rst_n), .testmode_i(1'b0),
      .slave(msts), .init_done_o(), .ch_r_beats_o(ch_rs), .ch_w_beats_o(ch_ws)
  );

  always @(posedge clk) begin
    #1;
    if (rst_n && mst.aw_valid && (mst.aw_lock || (|mst.aw_atop)))
      $fatal(1, "island lock/ATOP reached the stripe");
  end

  task automatic idle_bus(input int which);
    if (which == 0) begin
      cl.aw_valid = 0; cl.w_valid = 0; cl.b_ready = 0; cl.ar_valid = 0; cl.r_ready = 0;
      is.aw_valid = 0; is.w_valid = 0; is.b_ready = 0; is.ar_valid = 0; is.r_ready = 0;
    end else if (which == 1) begin
      clw.aw_valid = 0; clw.w_valid = 0; clw.b_ready = 0; clw.ar_valid = 0; clw.r_ready = 0;
      isw.aw_valid = 0; isw.w_valid = 0; isw.b_ready = 0; isw.ar_valid = 0; isw.r_ready = 0;
    end else begin
      cls.aw_valid = 0; cls.w_valid = 0; cls.b_ready = 0; cls.ar_valid = 0; cls.r_ready = 0;
      iss.aw_valid = 0; iss.w_valid = 0; iss.b_ready = 0; iss.ar_valid = 0; iss.r_ready = 0;
    end
  endtask

  task automatic wr64(input int island, input logic [63:0] addr, input logic [63:0] data,
                       input logic lock);
    int guard;
    @(negedge clk);
    if (!island) begin
      cl.aw_id = '0; cl.aw_addr = addr; cl.aw_len = 0; cl.aw_size = 3; cl.aw_burst = 1;
      cl.aw_lock = lock; cl.aw_cache = 0; cl.aw_prot = 0; cl.aw_qos = 0; cl.aw_region = 0;
      cl.aw_atop = 0; cl.aw_user = 0; cl.aw_valid = 1; cl.b_ready = 1;
      cl.w_data = data; cl.w_strb = '1; cl.w_last = 1; cl.w_user = 0; cl.w_valid = 1;
      guard = 0;
      do begin @(posedge clk); guard++; end while (!(cl.aw_ready) && guard < 40);
      if (!cl.aw_ready) $fatal(1, "cluster AW timeout %h ready %b", addr, cl.aw_ready);
      @(negedge clk); cl.aw_valid = 0;
      guard = 0;
      do begin @(posedge clk); guard++; end while (!cl.w_ready && guard < 40);
      if (!cl.w_ready) $fatal(1, "cluster W timeout");
      @(negedge clk); cl.w_valid = 0;
      guard = 0;
      do begin @(posedge clk); guard++; end while (!cl.b_valid && guard < 40);
      if (!cl.b_valid) $fatal(1, "cluster B timeout");
      @(negedge clk); cl.b_ready = 0;
    end else begin
      is.aw_id = 4'h3; is.aw_addr = addr; is.aw_len = 0; is.aw_size = 3; is.aw_burst = 1;
      is.aw_lock = lock; is.aw_cache = 0; is.aw_prot = 0; is.aw_qos = 0; is.aw_region = 0;
      is.aw_atop = lock ? 6'h20 : '0; is.aw_user = 0; is.aw_valid = 1; is.b_ready = 1;
      is.w_data = data; is.w_strb = '1; is.w_last = 1; is.w_user = 0; is.w_valid = 1;
      guard = 0;
      do begin @(posedge clk); guard++; end while (!is.aw_ready && guard < 40);
      if (!is.aw_ready) $fatal(1, "island AW timeout %h", addr);
      @(negedge clk); is.aw_valid = 0;
      guard = 0;
      do begin @(posedge clk); guard++; end while (!is.w_ready && guard < 40);
      if (!is.w_ready) $fatal(1, "island W timeout");
      @(negedge clk); is.w_valid = 0;
      guard = 0;
      do begin @(posedge clk); guard++; end while (!is.b_valid && guard < 40);
      if (!is.b_valid) $fatal(1, "island B timeout");
      if (addr < DRAM && is.b_resp != 2'b10)
        $fatal(1, "expected SLVERR on island write");
      @(negedge clk); is.b_ready = 0;
    end
  endtask

  task automatic rd64(input int island, input logic [63:0] addr, output logic [63:0] data,
                       output logic [1:0] resp);
    int guard;
    @(negedge clk);
    if (!island) begin
      cl.ar_id = 4'h1; cl.ar_addr = addr; cl.ar_len = 0; cl.ar_size = 3; cl.ar_burst = 1;
      cl.ar_lock = 0; cl.ar_cache = 0; cl.ar_prot = 0; cl.ar_qos = 0; cl.ar_region = 0;
      cl.ar_user = 0; cl.ar_valid = 1; cl.r_ready = 1;
      guard = 0;
      do begin @(posedge clk); guard++; end while (!cl.ar_ready && guard < 40);
      if (!cl.ar_ready) $fatal(1, "cluster AR timeout");
      @(negedge clk); cl.ar_valid = 0;
      guard = 0;
      do begin @(posedge clk); guard++; end while (!(cl.r_valid && cl.r_last) && guard < 40);
      if (!(cl.r_valid && cl.r_last)) $fatal(1, "cluster R timeout");
      data = cl.r_data; resp = cl.r_resp;
      @(negedge clk); cl.r_ready = 0;
    end else begin
      is.ar_id = 4'h5; is.ar_addr = addr; is.ar_len = 0; is.ar_size = 3; is.ar_burst = 1;
      is.ar_lock = 0; is.ar_cache = 0; is.ar_prot = 0; is.ar_qos = 0; is.ar_region = 0;
      is.ar_user = 0; is.ar_valid = 1; is.r_ready = 1;
      guard = 0;
      do begin @(posedge clk); guard++; end while (!is.ar_ready && guard < 40);
      if (!is.ar_ready) $fatal(1, "island AR timeout %h", addr);
      @(negedge clk); is.ar_valid = 0;
      guard = 0;
      do begin @(posedge clk); guard++; end while (!(is.r_valid && is.r_last) && guard < 40);
      if (!(is.r_valid && is.r_last)) $fatal(1, "island R timeout");
      data = is.r_data; resp = is.r_resp;
      @(negedge clk); is.r_ready = 0;
    end
  endtask

  initial begin
    logic [63:0] d0, d1;
    logic [1:0] rsp;
    logic [127:0] wide;
    logic [511:0] pat, got;
    logic [31:0] w0;
    int guard;
    idle_bus(0);
    idle_bus(1);
    idle_bus(2);
    rst_n = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    // +stripe_cross: two 16 B beats from DRAM+0x30. The downsizer narrows
    // that to one len=3 size=3 burst, which still crosses the 64 B stripe.
    // The backend $error stops the sim. Reaching the fatal means it did not.
    if ($test$plusargs("stripe_cross")) begin
      int wbeats;
      bit aw_done;
      wbeats = 0;
      aw_done = 0;
      @(negedge clk);
      isw.aw_valid = 1; isw.aw_id = 2; isw.aw_addr = DRAM + 64'h30; isw.aw_len = 1;
      isw.aw_size = 4; isw.aw_burst = 1; isw.aw_lock = 0; isw.aw_atop = 0;
      isw.aw_cache = 0; isw.aw_prot = 0; isw.aw_qos = 0; isw.aw_region = 0;
      isw.aw_user = 0; isw.b_ready = 1;
      isw.w_valid = 1; isw.w_data = 128'h1111_1111_1111_1111_1111_1111_1111_1111;
      isw.w_strb = '1; isw.w_last = 0; isw.w_user = 0;
      guard = 0;
      while (guard < 80) begin
        @(posedge clk);
        if (isw.aw_valid && isw.aw_ready) aw_done = 1;
        if (isw.w_valid && isw.w_ready) wbeats++;
        guard++;
        @(negedge clk);
        if (aw_done) isw.aw_valid = 0;
        if (wbeats == 1) begin
          isw.w_data = 128'h2222_2222_2222_2222_2222_2222_2222_2222;
          isw.w_last = 1;
        end else if (wbeats >= 2)
          isw.w_valid = 0;
      end
      $fatal(1, "stripe-cross burst was not reported");
    end

    wr64(0, DRAM, 64'h1111_0000_0000_00A5, 0);
    rd64(0, DRAM, d0, rsp);
    if (d0 != 64'h1111_0000_0000_00A5 || rsp != 2'b00)
      $fatal(1, "cluster readback %h resp %h", d0, rsp);

    wr64(1, DRAM + 64'h40, 64'h2222_0000_0000_005A, 0);
    rd64(1, DRAM + 64'h40, d1, rsp);
    if (d1 != 64'h2222_0000_0000_005A || rsp != 2'b00)
      $fatal(1, "island readback %h resp %h", d1, rsp);
    if (ch_w[0] == 0 || ch_w[1] == 0)
      $fatal(1, "stripe counters ch0=%0d ch1=%0d", ch_w[0], ch_w[1]);

    // Cluster wins a simultaneous AR.
    @(negedge clk);
    cl.ar_valid = 1; cl.ar_addr = DRAM; cl.ar_len = 0; cl.ar_size = 3; cl.ar_burst = 1;
    cl.ar_id = 1; cl.ar_lock = 0; cl.ar_cache = 0; cl.ar_prot = 0; cl.ar_qos = 0;
    cl.ar_region = 0; cl.ar_user = 0; cl.r_ready = 1;
    is.ar_valid = 1; is.ar_addr = DRAM + 64'h40; is.ar_len = 0; is.ar_size = 3; is.ar_burst = 1;
    is.ar_id = 5; is.ar_lock = 0; is.ar_cache = 0; is.ar_prot = 0; is.ar_qos = 0;
    is.ar_region = 0; is.ar_user = 0; is.r_ready = 1;
    @(posedge clk);
    if (is.ar_ready)
      $fatal(1, "island AR was accepted beside a cluster AR");
    if (!cl.ar_ready)
      $fatal(1, "cluster AR lost the simultaneous slot");
    @(negedge clk);
    cl.ar_valid = 0;
    guard = 0;
    do begin @(posedge clk); guard++; end while (!cl.r_valid && guard < 40);
    if (!cl.r_valid) $fatal(1, "cluster priority R timeout");
    @(negedge clk); cl.r_ready = 0;
    guard = 0;
    do begin @(posedge clk); guard++; end while (!is.ar_ready && guard < 40);
    if (!is.ar_ready) $fatal(1, "island AR did not proceed after the cluster");
    @(negedge clk); is.ar_valid = 0;
    guard = 0;
    do begin @(posedge clk); guard++; end while (!is.r_valid && guard < 40);
    if (!is.r_valid) $fatal(1, "island priority R timeout");
    @(negedge clk); is.r_ready = 0;

    rd64(1, 64'h1000, d0, rsp);
    if (rsp != 2'b10)
      $fatal(1, "non-DRAM island read resp %h", rsp);

    wr64(1, DRAM + 64'h80, 64'h3, 1);
    rd64(1, DRAM + 64'h80, d0, rsp);
    if (d0 != 64'h3)
      $fatal(1, "stripped-lock write did not land");

    // MaxAROut is 1. A second island AR waits. A cluster AR still proceeds.
    @(negedge clk);
    is.ar_valid = 1; is.ar_addr = DRAM + 64'h40; is.ar_id = 5; is.ar_len = 0;
    is.ar_size = 3; is.ar_burst = 1; is.r_ready = 0;
    @(posedge clk);
    if (!is.ar_ready) $fatal(1, "first capped island AR was not accepted");
    @(negedge clk);
    is.ar_valid = 0;
    is.ar_valid = 1; is.ar_addr = DRAM + 64'h48;
    cl.ar_valid = 1; cl.ar_addr = DRAM; cl.ar_id = 1; cl.ar_len = 0; cl.ar_size = 3;
    cl.ar_burst = 1; cl.r_ready = 1;
    @(posedge clk);
    if (is.ar_ready)
      $fatal(1, "second island AR passed MaxAROut");
    if (!cl.ar_ready)
      $fatal(1, "cluster AR stalled behind a full island budget");
    @(negedge clk);
    cl.ar_valid = 0;
    is.r_ready = 1;
    guard = 0;
    do begin @(posedge clk); guard++; end while (!cl.r_valid && guard < 40);
    if (!cl.r_valid) $fatal(1, "cluster R behind island cap timed out");
    @(negedge clk); cl.r_ready = 0;
    guard = 0;
    do begin @(posedge clk); guard++; end while (!(is.r_valid && is.r_last) && guard < 40);
    if (!(is.r_valid && is.r_last)) $fatal(1, "capped island R timeout");
    @(negedge clk);
    is.r_ready = 0;
    // The second AR is still pending; accept and drain it now that the cap is free.
    guard = 0;
    do begin @(posedge clk); guard++; end while (!is.ar_ready && guard < 40);
    if (!is.ar_ready) $fatal(1, "second island AR never accepted");
    @(negedge clk); is.ar_valid = 0; is.r_ready = 1;
    guard = 0;
    do begin @(posedge clk); guard++; end while (!(is.r_valid && is.r_last) && guard < 40);
    if (!(is.r_valid && is.r_last)) $fatal(1, "second island R timeout");
    @(negedge clk); is.r_ready = 0;

    // MaxAROut is 1 for writes as well. Hold B so the first AW stays
    // outstanding. A second island AW waits. A cluster AW still proceeds.
    begin
      bit aw_done, w_done, saw_cl, cl_w;
      @(negedge clk);
      is.aw_id = 4'h3; is.aw_addr = DRAM + 64'h10; is.aw_len = 0; is.aw_size = 3;
      is.aw_burst = 1; is.aw_lock = 0; is.aw_cache = 0; is.aw_prot = 0;
      is.aw_qos = 0; is.aw_region = 0; is.aw_atop = 0; is.aw_user = 0;
      is.aw_valid = 1; is.b_ready = 0;
      is.w_data = 64'h11; is.w_strb = '1; is.w_last = 1; is.w_user = 0; is.w_valid = 1;
      aw_done = 0; w_done = 0; guard = 0;
      while (!(aw_done && w_done) && guard < 40) begin
        @(posedge clk);
        if (is.aw_valid && is.aw_ready) aw_done = 1;
        if (is.w_valid && is.w_ready) w_done = 1;
        guard++;
        @(negedge clk);
        if (aw_done) is.aw_valid = 0;
        if (w_done) is.w_valid = 0;
      end
      if (!(aw_done && w_done))
        $fatal(1, "first capped island AW/W was not accepted");
      guard = 0;
      do begin @(posedge clk); guard++; end while (!is.b_valid && guard < 40);
      if (!is.b_valid) $fatal(1, "first capped island B missing");
      @(negedge clk);
      is.aw_valid = 1; is.aw_addr = DRAM + 64'h18;
      // Other stripe channel than the held island write (ChanShift=6).
      cl.aw_id = 1; cl.aw_addr = DRAM + 64'h40; cl.aw_len = 0; cl.aw_size = 3;
      cl.aw_burst = 1; cl.aw_lock = 0; cl.aw_cache = 0; cl.aw_prot = 0;
      cl.aw_qos = 0; cl.aw_region = 0; cl.aw_atop = 0; cl.aw_user = 0;
      cl.aw_valid = 1; cl.b_ready = 1;
      cl.w_data = 64'h22; cl.w_strb = '1; cl.w_last = 1; cl.w_user = 0; cl.w_valid = 1;
      saw_cl = 0; cl_w = 0; guard = 0;
      while (guard < 8) begin
        @(posedge clk);
        if (is.aw_ready)
          $fatal(1, "second island AW passed MaxAROut");
        if (cl.w_valid && cl.w_ready) cl_w = 1;
        if (cl.aw_ready) begin
          saw_cl = 1;
          break;
        end
        guard++;
      end
      if (!saw_cl)
        $fatal(1, "cluster AW stalled behind a full island budget");
      @(negedge clk); cl.aw_valid = 0;
      if (cl_w) cl.w_valid = 0;
      else begin
        guard = 0;
        do begin @(posedge clk); guard++; end while (!cl.w_ready && guard < 40);
        if (!cl.w_ready) $fatal(1, "cluster W behind island AW cap timed out");
        @(negedge clk); cl.w_valid = 0;
      end
      // Island B is still untaken, so it occupies the single response pipe.
      // Drop the waiting AW while that response drains, or it would be
      // accepted on the same cycle the cap frees and before its W beat.
      @(negedge clk); is.aw_valid = 0; is.b_ready = 1;
      @(posedge clk);
      @(negedge clk); is.b_ready = 0;
      guard = 0;
      do begin @(posedge clk); guard++; end while (!cl.b_valid && guard < 40);
      if (!cl.b_valid) $fatal(1, "cluster B behind island AW cap timed out");
      @(negedge clk); cl.b_ready = 0;
      is.aw_valid = 1; is.aw_addr = DRAM + 64'h18;
      is.w_valid = 1; is.w_data = 64'h33; is.w_strb = '1; is.w_last = 1;
      is.b_ready = 0;
      aw_done = 0; w_done = 0; guard = 0;
      while (!(aw_done && w_done) && guard < 40) begin
        @(posedge clk);
        if (is.aw_valid && is.aw_ready) aw_done = 1;
        if (is.w_valid && is.w_ready) w_done = 1;
        guard++;
        @(negedge clk);
        if (aw_done) is.aw_valid = 0;
        if (w_done) is.w_valid = 0;
      end
      if (!(aw_done && w_done))
        $fatal(1, "second island AW never accepted");
      is.b_ready = 1;
      guard = 0;
      do begin @(posedge clk); guard++; end while (!is.b_valid && guard < 40);
      if (!is.b_valid) $fatal(1, "second island B timeout");
      @(negedge clk); is.b_ready = 0;
    end

    // 128-bit island beat becomes two channel beats and reads back.
    @(negedge clk);
    isw.aw_valid = 1; isw.aw_id = 0; isw.aw_addr = DRAM; isw.aw_len = 0; isw.aw_size = 4;
    isw.aw_burst = 1; isw.aw_lock = 0; isw.aw_atop = 0; isw.aw_cache = 0; isw.aw_prot = 0;
    isw.aw_qos = 0; isw.aw_region = 0; isw.aw_user = 0;
    isw.w_valid = 1; isw.w_data = 128'h0123_4567_89AB_CDEF_0011_2233_4455_6677;
    isw.w_strb = '1; isw.w_last = 1; isw.w_user = 0; isw.b_ready = 1;
    guard = 0;
    do begin @(posedge clk); guard++; end while (!isw.aw_ready && guard < 40);
    if (!isw.aw_ready) $fatal(1, "wide AW timeout");
    @(negedge clk); isw.aw_valid = 0;
    // Keep the wide W beat until its handshake. The downsizer may ack it only
    // after both narrow beats have been issued.
    guard = 0;
    do begin @(posedge clk); guard++; end while (!(isw.w_ready && isw.w_valid) && guard < 40);
    if (!(isw.w_ready && isw.w_valid)) $fatal(1, "wide W timeout");
    @(negedge clk); isw.w_valid = 0;
    guard = 0;
    do begin @(posedge clk); guard++; end while (!isw.b_valid && guard < 40);
    if (!isw.b_valid) $fatal(1, "wide B timeout");
    if (ch_ww[0] < 2)
      $fatal(1, "128-bit write produced %0d channel beats", ch_ww[0]);
    @(negedge clk); isw.b_ready = 0;
    // The split beats are read back on the cluster port of the same join.
    clw.ar_id = 1; clw.ar_addr = DRAM; clw.ar_len = 0; clw.ar_size = 3; clw.ar_burst = 1;
    clw.ar_lock = 0; clw.ar_cache = 0; clw.ar_prot = 0; clw.ar_qos = 0; clw.ar_region = 0;
    clw.ar_user = 0; clw.ar_valid = 1; clw.r_ready = 1;
    guard = 0;
    do begin @(posedge clk); guard++; end while (!clw.ar_ready && guard < 40);
    if (!clw.ar_ready) $fatal(1, "wide-memory cluster AR timeout");
    @(negedge clk); clw.ar_valid = 0;
    guard = 0;
    do begin @(posedge clk); guard++; end while (!(clw.r_valid && clw.r_last) && guard < 40);
    if (!(clw.r_valid && clw.r_last)) $fatal(1, "wide-memory cluster R timeout");
    d0 = clw.r_data;
    @(negedge clk); clw.r_ready = 0;
    clw.ar_addr = DRAM + 64'h8; clw.ar_valid = 1; clw.r_ready = 1;
    guard = 0;
    do begin @(posedge clk); guard++; end while (!clw.ar_ready && guard < 40);
    if (!clw.ar_ready) $fatal(1, "wide-memory second AR timeout");
    @(negedge clk); clw.ar_valid = 0;
    guard = 0;
    do begin @(posedge clk); guard++; end while (!(clw.r_valid && clw.r_last) && guard < 40);
    if (!(clw.r_valid && clw.r_last)) $fatal(1, "wide-memory second R timeout");
    d1 = clw.r_data;
    wide = {d1, d0};
    if (wide != 128'h0123_4567_89AB_CDEF_0011_2233_4455_6677 &&
        wide != 128'h0011_2233_4455_6677_0123_4567_89AB_CDEF)
      $fatal(1, "wide bytes read back as %h", wide);
    // Same word back through the downsizer, after the narrow write has retired.
    @(negedge clk);
    isw.ar_valid = 1; isw.ar_id = 1; isw.ar_addr = DRAM; isw.ar_len = 0; isw.ar_size = 4;
    isw.ar_burst = 1; isw.ar_lock = 0; isw.ar_cache = 0; isw.ar_prot = 0; isw.ar_qos = 0;
    isw.ar_region = 0; isw.ar_user = 0; isw.r_ready = 1;
    guard = 0;
    do begin @(posedge clk); guard++; end while (!isw.ar_ready && guard < 40);
    if (!isw.ar_ready) $fatal(1, "wide AR timeout");
    @(negedge clk); isw.ar_valid = 0;
    guard = 0;
    do begin @(posedge clk); guard++; end while (!(isw.r_valid && isw.r_last) && guard < 80);
    if (!(isw.r_valid && isw.r_last)) $fatal(1, "wide R timeout");
    if (isw.r_data != 128'h0123_4567_89AB_CDEF_0011_2233_4455_6677 &&
        isw.r_data != wide)
      $fatal(1, "wide downsizer readback %h", isw.r_data);

    // 512-bit line, eight channel beats, then the same word back. A cluster
    // read of another address must still complete on this join.
    pat = {64'h0707_0707_0707_0707, 64'h0606_0606_0606_0606,
           64'h0505_0505_0505_0505, 64'h0404_0404_0404_0404,
           64'h0303_0303_0303_0303, 64'h0202_0202_0202_0202,
           64'h0101_0101_0101_0101, 64'h0000_0000_0000_00A5};
    w0 = ch_ws[0];
    @(negedge clk);
    iss.aw_valid = 1; iss.aw_id = 0; iss.aw_addr = DRAM + 64'h80; iss.aw_len = 0;
    iss.aw_size = 6; iss.aw_burst = 1; iss.aw_lock = 0; iss.aw_atop = 0;
    iss.aw_cache = 0; iss.aw_prot = 0; iss.aw_qos = 0; iss.aw_region = 0; iss.aw_user = 0;
    iss.w_valid = 1; iss.w_data = pat; iss.w_strb = '1; iss.w_last = 1; iss.w_user = 0;
    iss.b_ready = 1;
    guard = 0;
    do begin @(posedge clk); guard++; end while (!iss.aw_ready && guard < 40);
    if (!iss.aw_ready) $fatal(1, "512 AW timeout");
    @(negedge clk); iss.aw_valid = 0;
    guard = 0;
    do begin @(posedge clk); guard++; end while (!(iss.w_ready && iss.w_valid) && guard < 80);
    if (!(iss.w_ready && iss.w_valid)) $fatal(1, "512 W timeout");
    @(negedge clk); iss.w_valid = 0;
    guard = 0;
    do begin @(posedge clk); guard++; end while (!iss.b_valid && guard < 80);
    if (!iss.b_valid) $fatal(1, "512 B timeout");
    @(negedge clk); iss.b_ready = 0;
    if (ch_ws[0] < w0 + 32'd8)
      $fatal(1, "512-bit write produced %0d new beats", ch_ws[0] - w0);
    // Cluster read of a different line once the eight beats have retired.
    cls.ar_id = 2; cls.ar_addr = DRAM; cls.ar_len = 0; cls.ar_size = 3; cls.ar_burst = 1;
    cls.ar_lock = 0; cls.ar_cache = 0; cls.ar_prot = 0; cls.ar_qos = 0; cls.ar_region = 0;
    cls.ar_user = 0; cls.ar_valid = 1; cls.r_ready = 1;
    guard = 0;
    do begin @(posedge clk); guard++; end while (!cls.ar_ready && guard < 40);
    if (!cls.ar_ready) $fatal(1, "cluster AR behind 512-bit write timed out");
    @(negedge clk); cls.ar_valid = 0;
    guard = 0;
    do begin @(posedge clk); guard++; end while (!(cls.r_valid && cls.r_last) && guard < 40);
    if (!(cls.r_valid && cls.r_last)) $fatal(1, "cluster R behind 512-bit write timed out");
    @(negedge clk); cls.r_ready = 0;
    iss.ar_valid = 1; iss.ar_id = 1; iss.ar_addr = DRAM + 64'h80; iss.ar_len = 0;
    iss.ar_size = 6; iss.ar_burst = 1; iss.ar_lock = 0; iss.ar_cache = 0; iss.ar_prot = 0;
    iss.ar_qos = 0; iss.ar_region = 0; iss.ar_user = 0; iss.r_ready = 1;
    guard = 0;
    do begin @(posedge clk); guard++; end while (!iss.ar_ready && guard < 40);
    if (!iss.ar_ready) $fatal(1, "512 AR timeout");
    @(negedge clk); iss.ar_valid = 0;
    guard = 0;
    do begin @(posedge clk); guard++; end while (!(iss.r_valid && iss.r_last) && guard < 80);
    if (!(iss.r_valid && iss.r_last)) $fatal(1, "512 R timeout");
    got = iss.r_data;
    if (got != pat)
      $fatal(1, "512 downsizer readback mismatch");

    // 512-bit port, MaxAROut is 2. Two 8-byte reads fill it. The third waits.
    // A cluster read on the same join still proceeds. size=3 is one channel
    // beat, so the cap is the wide transaction and not the eight-beat split.
    @(negedge clk);
    iss.ar_valid = 1; iss.ar_id = 3; iss.ar_addr = DRAM + 64'h40; iss.ar_len = 0;
    iss.ar_size = 3; iss.ar_burst = 1; iss.ar_lock = 0; iss.ar_cache = 0;
    iss.ar_prot = 0; iss.ar_qos = 0; iss.ar_region = 0; iss.ar_user = 0;
    iss.r_ready = 0;
    guard = 0;
    do begin @(posedge clk); guard++; end while (!iss.ar_ready && guard < 40);
    if (!iss.ar_ready) $fatal(1, "first 512-bit capped AR was not accepted");
    @(negedge clk); iss.ar_valid = 0;
    iss.ar_valid = 1; iss.ar_id = 4; iss.ar_addr = DRAM + 64'h48;
    guard = 0;
    do begin @(posedge clk); guard++; end while (!iss.ar_ready && guard < 40);
    if (!iss.ar_ready) $fatal(1, "second 512-bit capped AR was not accepted");
    @(negedge clk);
    iss.ar_valid = 1; iss.ar_id = 5; iss.ar_addr = DRAM + 64'h50;
    cls.ar_id = 3; cls.ar_addr = DRAM + 64'h60; cls.ar_len = 0; cls.ar_size = 3;
    cls.ar_burst = 1; cls.ar_lock = 0; cls.ar_cache = 0; cls.ar_prot = 0;
    cls.ar_qos = 0; cls.ar_region = 0; cls.ar_user = 0;
    cls.ar_valid = 1; cls.r_ready = 1;
    begin
      bit saw_cl, third;
      int got_r;
      saw_cl = 0; guard = 0;
      while (guard < 8) begin
        @(posedge clk);
        if (iss.ar_ready)
          $fatal(1, "third 512-bit AR passed MaxAROut");
        if (cls.ar_ready) begin
          saw_cl = 1;
          break;
        end
        guard++;
      end
      if (!saw_cl)
        $fatal(1, "cluster AR stalled behind a full 512-bit island budget");
      @(negedge clk); cls.ar_valid = 0;
      guard = 0;
      do begin @(posedge clk); guard++; end while (!(cls.r_valid && cls.r_last) && guard < 40);
      if (!(cls.r_valid && cls.r_last))
        $fatal(1, "cluster R behind 512-bit cap timed out");
      @(negedge clk); cls.r_ready = 0; iss.r_ready = 1;
      // Taking the held R beats frees a slot, which may accept the third AR
      // before both beats have been drained.
      got_r = 0; third = 0; guard = 0;
      while (got_r < 2 && guard < 40) begin
        @(posedge clk);
        if (iss.r_valid && iss.r_last) got_r++;
        if (iss.ar_valid && iss.ar_ready) third = 1;
        guard++;
        @(negedge clk);
        if (third) iss.ar_valid = 0;
      end
      if (got_r != 2) $fatal(1, "held 512 R drain got %0d", got_r);
      if (!third) begin
        guard = 0;
        do begin @(posedge clk); guard++; end while (!iss.ar_ready && guard < 40);
        if (!iss.ar_ready) $fatal(1, "third 512-bit AR never accepted");
        @(negedge clk); iss.ar_valid = 0;
      end
      guard = 0;
      do begin @(posedge clk); guard++; end while (!(iss.r_valid && iss.r_last) && guard < 40);
      if (!(iss.r_valid && iss.r_last)) $fatal(1, "third 512 R timeout");
      @(negedge clk); iss.r_ready = 0;
    end

    $display("PASS tb_g6lc_ai_dram_join");
    $finish;
  end

  initial begin
    repeat (20000) @(posedge clk);
    $fatal(1, "timeout");
  end
endmodule
