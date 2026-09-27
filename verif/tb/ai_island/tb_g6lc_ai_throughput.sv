// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Non-default throughput cluster: format mask, N copies, class-2 rate socket,
// and the parameter sketches. The live 256-MAC package is not this config.

module tb_g6lc_ai_throughput;
  import g6lc_ai_island_cfg_pkg::*;

  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;

  logic        start, done, wrote;
  logic [2:0]  fmt;
  logic [7:0]  which;
  logic [31:0] a0, a1, b0, b1, c;
  logic [15:0] status, live_status;

  g6lc_ai_cluster_set #(
    .CLUSTERS(2), .DTYPE_MASK(AiIslandFastDtypeMask), .FP_REAL_MODEL(1)
  ) i_fast (
    .clk_i(clk), .rst_ni(rst_n), .start_i(start), .fmt_i(fmt), .cluster_i(which),
    .a0_i(a0), .a1_i(a1), .b0_i(b0), .b1_i(b1),
    .done_o(done), .status_o(status), .c_o(c), .wrote_o(wrote)
  );

  g6lc_ai_cluster_set #(.CLUSTERS(8), .DTYPE_MASK(AiIslandDtypeMask)) i_live (
    .clk_i(clk), .rst_ni(rst_n), .start_i(start), .fmt_i(fmt), .cluster_i(which),
    .a0_i(a0), .a1_i(a1), .b0_i(b0), .b1_i(b1),
    .done_o(), .status_o(live_status), .c_o(), .wrote_o()
  );

  AXI_BUS #(
    .AXI_ADDR_WIDTH(64), .AXI_DATA_WIDTH(64),
    .AXI_ID_WIDTH(4), .AXI_USER_WIDTH(1)
  ) mem ();

  logic model_init;
  logic [7:0][31:0] model_r, model_w;
  logic w_go;

  logic t_load, t_ab, t_start, t_busy, t_done;
  logic [2:0] t_fmt;
  logic [7:0] t_cl;
  logic [1:0] t_row, t_col;
  logic [15:0] t_m, t_n, t_k, t_status;
  logic [31:0] t_elem;

  logic n_load, n_ab, n_start, n_done;
  logic [2:0] n_fmt;
  logic [7:0] n_cl;
  logic [1:0] n_row, n_col;
  logic [15:0] n_m, n_n, n_k, n_status;
  logic [31:0] n_elem;

  // One physical multiplier. Same 2x2x2 tile must match the 8-lane C.
  g6lc_ai_cluster_tile #(.CLUSTERS(1), .LANES(1)) i_narrow (
    .clk_i(clk), .rst_ni(rst_n),
    .load_i(n_load), .ab_i(n_ab), .cluster_i(n_cl),
    .row_i(n_row), .col_i(n_col), .elem_i(n_elem),
    .start_i(n_start), .fmt_i(n_fmt), .m_i(n_m), .n_i(n_n), .k_i(n_k),
    .busy_o(), .done_o(n_done), .status_o(n_status)
  );

  g6lc_ai_cluster_tile #(.CLUSTERS(2), .FP_REAL_MODEL(1)) i_tile (
    .clk_i(clk), .rst_ni(rst_n),
    .load_i(t_load), .ab_i(t_ab), .cluster_i(t_cl),
    .row_i(t_row), .col_i(t_col), .elem_i(t_elem),
    .start_i(t_start), .fmt_i(t_fmt), .m_i(t_m), .n_i(t_n), .k_i(t_k),
    .busy_o(t_busy), .done_o(t_done), .status_o(t_status)
  );

  g6lc_ai_dram_backend #(
    .DramClass(AI_DRAM_LPDDR5),
    .Class2Model(1'b1),
    .AXI_ID_WIDTH(4), .AXI_ADDR_WIDTH(64), .AXI_DATA_WIDTH(64),
    .AXI_USER_WIDTH(1), .NUM_WORDS(256), .NrChannels(1)
  ) i_model (
    .clk_i(clk), .rst_ni(rst_n), .rst_sram_ni(rst_n), .testmode_i(1'b0),
    .slave(mem), .init_done_o(model_init),
    .ch_r_beats_o(model_r), .ch_w_beats_o(model_w)
  );

  assign mem.aw_valid = 1'b0;
  assign mem.aw_id = '0;
  assign mem.aw_addr = '0;
  assign mem.aw_len = '0;
  assign mem.aw_size = '0;
  assign mem.aw_burst = 2'b01;
  assign mem.aw_lock = 1'b0;
  assign mem.aw_cache = '0;
  assign mem.aw_prot = '0;
  assign mem.aw_qos = '0;
  assign mem.aw_region = '0;
  assign mem.aw_atop = '0;
  assign mem.aw_user = '0;
  assign mem.w_valid = w_go;
  assign mem.w_data = '0;
  assign mem.w_strb = '1;
  assign mem.w_last = 1'b1;
  assign mem.w_user = '0;
  assign mem.b_ready = 1'b1;
  assign mem.ar_valid = 1'b0;
  assign mem.ar_id = '0;
  assign mem.ar_addr = '0;
  assign mem.ar_len = '0;
  assign mem.ar_size = '0;
  assign mem.ar_burst = 2'b01;
  assign mem.ar_lock = 1'b0;
  assign mem.ar_cache = '0;
  assign mem.ar_prot = '0;
  assign mem.ar_qos = '0;
  assign mem.ar_region = '0;
  assign mem.ar_user = '0;
  assign mem.r_ready = 1'b1;

  task automatic pulse(input logic [2:0] f, input logic [7:0] cl,
                        input logic [31:0] ea0, ea1, eb0, eb1);
    begin
      fmt = f; which = cl; a0 = ea0; a1 = ea1; b0 = eb0; b1 = eb1;
      start = 1'b1;
      @(posedge clk);
      #1;
    end
  endtask

  initial begin
    start = 0; w_go = 0; fmt = 0; which = 0; a0 = 0; a1 = 0; b0 = 0; b1 = 0;
    t_load = 0; t_ab = 0; t_start = 0; t_fmt = 0; t_cl = 0;
    t_row = 0; t_col = 0; t_m = 0; t_n = 0; t_k = 0; t_elem = 0;
    n_load = 0; n_ab = 0; n_start = 0; n_fmt = 0; n_cl = 0;
    n_row = 0; n_col = 0; n_m = 0; n_n = 0; n_k = 0; n_elem = 0;
    if (!island_cfg_legal(AiIslandLatencyDefault))
      $fatal(1, "live cfg illegal");
    if (island_cfg_legal(AiIslandLatencySkuTarget))
      $fatal(1, "8192-MAC sku target must stay illegal");
    if (!island_cfg_legal(AiIslandThroughputSku))
      $fatal(1, "throughput sku illegal");
    if (AiIslandThroughputSku.ClustersEnabled != 8 ||
        AiIslandThroughputSku.MacsPerCycle != 4096 ||
        AiIslandThroughputSku.DramGBps != AI_DRAM_LPDDR5_GBPS)
      $fatal(1, "throughput geometry");
    // Live geometry: 2 × 1 × AI_LIVE_MACS × 2 GHz. At 512 that is 2.048 TOPS.
    // DramGBps stays 16. mac_mul projects a wider issue rate and does not
    // change PeLanes. A VA level does not scale the dense peak.
    if (AiIslandLatencyDefault.MacsPerCycle != AI_LIVE_MACS ||
        AI_LIVE_MACS != 512 ||
        AiIslandLatencyDefault.AccTileM != AI_PANEL_M ||
        AiIslandLatencyDefault.AccTileN != AI_PANEL_N ||
        AiIslandLatencyDefault.AccTileK != AI_PANEL_K ||
        AiIslandLatencyDefault.ClockKhz != 2_000_000 ||
        AiIslandLatencyDefault.NocWidth != 64 ||
        AiIslandLatencyDefault.DramGBps != 16 ||
        AiIslandLatencyDefault.DramClass != AI_DRAM_SIM_AXI)
      $fatal(1, "live nameplate geometry");
    if (AiIslandLatencyDefault.DramGBps !=
        dram_nameplate_gbps(64, 2_000_000, 1, AI_DRAM_SIM_AXI))
      $fatal(1, "live DramGBps drifted from the NoC function");
    if (sketch_milli_tops(AiIslandLatencyDefault, 0) != 2048)
      $fatal(1, "live INT8 sketch %0d", sketch_milli_tops(AiIslandLatencyDefault, 0));
    if (sketch_milli_tops_scaled(AiIslandLatencyDefault, 0, 1, 1, 0) != 2048)
      $fatal(1, "scaled identity");
    if (sketch_milli_tops_scaled(AiIslandLatencyDefault, 0, 2, 1, 0) != 4096)
      $fatal(1, "mac_mul projection must not be the elaborated rate");
    if (sketch_milli_tops_scaled(AiIslandLatencyDefault, 0, 1, 1, 8) != 2048)
      $fatal(1, "VA level scaled the dense peak");
    if (sketch_milli_tops_scaled(AiIslandLatencyDefault, 0, 1, 1, 16) != 0)
      $fatal(1, "VA level above 15 published a peak");
    if (sketch_milli_tops_scaled(AiIslandLatencyDefault, 1, 1, 1, 0) != 4096)
      $fatal(1, "live INT4 sketch");
    if (bumped_dram_gbps(64, 2_000_000, 8, AI_DRAM_SIM_AXI, 1, 1) != 16)
      $fatal(1, "class-0 channels multiplied the nameplate");
    if (bumped_dram_gbps(64, 2_000_000, 1, AI_DRAM_SIM_AXI, 2, 1) != 32)
      $fatal(1, "width multiplier");
    if (bumped_dram_gbps(64, 1_000_000, 2, AI_DRAM_DDR4, 4, 4) != 38)
      $fatal(1, "DDR4 multiplier changed N×19");
    if (bumped_dram_gbps(512, 1_500_000, 1, AI_DRAM_LPDDR5, 2, 2) != 400)
      $fatal(1, "class 2 multiplier changed 400");
    if (bumped_dram_gbps(64, 2_000_000, 1, AI_DRAM_SIM_AXI, 0, 1) != 0)
      $fatal(1, "zero width multiplier published a nameplate");
    begin
      automatic ai_island_cfg_t one_ghz;
      one_ghz = AiIslandLatencyDefault;
      one_ghz.ClockKhz = 1_000_000;
      if (sketch_milli_tops(one_ghz, 0) != 1024)
        $fatal(1, "1 GHz point of the 512-MAC array");
      one_ghz.MacsPerCycle = 256;
      one_ghz.ClockKhz = 1_000_000;
      if (sketch_milli_tops(one_ghz, 0) != 512)
        $fatal(1, "1 GHz point of the previous 256-MAC array");
    end
    // 512×512×k basis. Any k that fits the tile is one issue per output,
    // so k=16 and k=512 take the same 262144 MAC issues. Operand bytes
    // scale with k. A VA hit skips those bytes and does not add issues.
    if (panel_k_issues(16) != 1 || panel_k_issues(512) != 1 ||
        panel_k_issues(0) != 0 || panel_k_issues(513) != 0)
      $fatal(1, "panel K issues");
    if (panel_mac_issues(512, 512, 512) != 262144 ||
        panel_mac_issues(512, 512, 16) != 262144)
      $fatal(1, "512x512 panel MAC issues");
    if (panel_operand_bytes(512, 512) != 262144 ||
        panel_operand_bytes(512, 16) != 8192)
      $fatal(1, "panel operand bytes");
    if (!va_panel_ok(512, 512) || !va_panel_ok(512, 256) || !va_panel_ok(1024, 128))
      $fatal(1, "VA panels");
    if (va_panel_ok(1024, 256) || va_panel_ok(256, 512))
      $fatal(1, "unnamed shape marked as a VA panel");
    if (panel_mac_issues(512, 256, 512) != 131072 ||
        panel_mac_issues(512, 256, 16) != 131072 ||
        panel_mac_issues(1024, 128, 512) != 131072)
      $fatal(1, "half panels");
    // 129 columns fit N<=512. 513 columns and 1025 rows do not.
    if (panel_mac_issues(1024, 129, 512) != 132096)
      $fatal(1, "1024x129 is inside the box");
    if (panel_mac_issues(1024, 513, 512) != 0 ||
        panel_mac_issues(1025, 128, 512) != 0)
      $fatal(1, "panel outside the box");
    if (panel_operand_bytes(1024, 512) != 524288 ||
        panel_operand_bytes(128, 512) != 65536 ||
        panel_operand_bytes(256, 512) != 131072)
      $fatal(1, "VA panel operand bytes");
    if (panel_mac_issues(512, 512, 512) !=
        panel_mac_issues(512, 512, 16))
      $fatal(1, "short K must not look faster than a full lane");
    if (sketch_milli_tops(AiIslandThroughputSku, 0) != 98304)
      $fatal(1, "INT8 sketch %0d", sketch_milli_tops(AiIslandThroughputSku, 0));
    if (sketch_milli_tops(AiIslandThroughputSku, 1) != 196608)
      $fatal(1, "INT4 sketch");
    if (sketch_milli_tops(AiIslandThroughputSku, 3) != 98304 ||
        sketch_milli_tops(AiIslandThroughputSku, 4) != 98304)
      $fatal(1, "FP8 sketch");
    if (sketch_milli_tops(AiIslandThroughputSku, 5) != 49152 ||
        sketch_milli_tops(AiIslandThroughputSku, 6) != 49152)
      $fatal(1, "FP16/BF16 sketch");
    if (sketch_milli_tops(AiIslandThroughputSku, 7) != 24576)
      $fatal(1, "FP32 sketch");
    if (sketch_milli_tops(AiIslandThroughputSku, 2) != 0)
      $fatal(1, "SP24 must not have a peak");

    repeat (2) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // INT8 1*3+2*4 = 11 on cluster 0. Cluster 1 is idle and stays 0.
    pulse(3'd0, 8'd0, 32'd1, 32'd2, 32'd3, 32'd4);
    if (status != 16'd0 || c != 32'd11 || !wrote)
      $fatal(1, "INT8 c=%0d st=%0d wrote=%b", c, status, wrote);
    if (i_fast.c_lane[1] != 32'd0 || i_fast.wrote_lane[1] != 1'b0)
      $fatal(1, "cluster 1 wrote");

    // Fast mask accepts floats. 1*3+2*4 = 11, binary32 0x41300000.
    pulse(3'd7, 8'd0, 32'h3f800000, 32'h40000000, 32'h40400000, 32'h40800000);
    if (status != 16'd0 || c != 32'h41300000)
      $fatal(1, "FP32 c=%h st=%0d", c, status);
    if (live_status != 16'd8)
      $fatal(1, "live mask accepted FP32");

    // FP16 1,2,3,4.
    pulse(3'd5, 8'd0, 32'h3c00, 32'h4000, 32'h4200, 32'h4400);
    if (status != 16'd0 || c != 32'h41300000)
      $fatal(1, "FP16 c=%h", c);
    // BF16 top-16 of the same binary32 values.
    pulse(3'd6, 8'd0, 32'h3f80, 32'h4000, 32'h4040, 32'h4080);
    if (status != 16'd0 || c != 32'h41300000)
      $fatal(1, "BF16 c=%h", c);
    // FP8 E4M3: 1,2,3,4 → 0x38,0x40,0x44,0x48.
    pulse(3'd3, 8'd0, 32'h38, 32'h40, 32'h44, 32'h48);
    if (status != 16'd0 || c != 32'h41300000)
      $fatal(1, "E4M3 c=%h", c);
    // FP8 E5M2: 1,2,3,4 → 0x3c,0x40,0x42,0x44.
    pulse(3'd4, 8'd0, 32'h3c, 32'h40, 32'h42, 32'h44);
    if (status != 16'd0 || c != 32'h41300000)
      $fatal(1, "E5M2 c=%h", c);
    pulse(3'd2, 8'd0, 32'd1, 32'd1, 32'd1, 32'd1);
    if (status != 16'd8)
      $fatal(1, "SP24 status %0d", status);

    // 2x2x2 tile, 8 physical lanes, K fits in one strip.
    // A=[[1,2],[3,4]] B=[[5,6],[7,8]] → C=[[19,22],[43,50]]
    begin
      int unsigned rr, cc;
      int unsigned amat[2][2];
      int unsigned bmat[2][2];
      amat[0][0] = 1; amat[0][1] = 2; amat[1][0] = 3; amat[1][1] = 4;
      bmat[0][0] = 5; bmat[1][0] = 7; bmat[0][1] = 6; bmat[1][1] = 8;
      for (rr = 0; rr < 2; rr++) begin
        for (cc = 0; cc < 2; cc++) begin
          t_cl = 0; t_row = rr[1:0]; t_col = cc[1:0]; t_ab = 0; t_elem = amat[rr][cc];
          t_load = 1; @(posedge clk); #1; t_load = 0;
          t_ab = 1; t_elem = bmat[cc][rr];
          // B[k][j] with k=cc, j=rr is wrong. Load B[k][j] explicitly below.
          t_load = 0;
        end
      end
      t_cl = 0; t_ab = 1;
      t_row = 0; t_col = 0; t_elem = 32'd5; t_load = 1; @(posedge clk); #1;
      t_row = 0; t_col = 1; t_elem = 32'd6; @(posedge clk); #1;
      t_row = 1; t_col = 0; t_elem = 32'd7; @(posedge clk); #1;
      t_row = 1; t_col = 1; t_elem = 32'd8; @(posedge clk); #1;
      t_load = 0;
      t_fmt = 3'd0; t_m = 16'd2; t_n = 16'd2; t_k = 16'd2; t_cl = 0;
      t_start = 1; @(posedge clk); #1; t_start = 0;
      begin
        int unsigned guard;
        guard = 0;
        while (!t_done && guard < 24) begin
          @(posedge clk);
          guard++;
        end
        if (!t_done)
          $fatal(1, "tile did not finish");
      end
      if (t_status != 16'd0)
        $fatal(1, "tile status %0d", t_status);
      if (i_tile.c_mem[0][0][0] != 32'd19 || i_tile.c_mem[0][0][1] != 32'd22 ||
          i_tile.c_mem[0][1][0] != 32'd43 || i_tile.c_mem[0][1][1] != 32'd50)
        $fatal(1, "tile C %0d %0d %0d %0d",
               i_tile.c_mem[0][0][0], i_tile.c_mem[0][0][1],
               i_tile.c_mem[0][1][0], i_tile.c_mem[0][1][1]);
      if (i_tile.c_mem[1][0][0] != 32'd0)
        $fatal(1, "idle cluster wrote C");

      // Same INT8 tile through one multiplier. Two K steps per output.
      n_ab = 0;
      n_row = 0; n_col = 0; n_elem = 32'd1; n_load = 1; @(posedge clk); #1;
      n_col = 1; n_elem = 32'd2; @(posedge clk); #1;
      n_row = 1; n_col = 0; n_elem = 32'd3; @(posedge clk); #1;
      n_col = 1; n_elem = 32'd4; @(posedge clk); #1;
      n_ab = 1;
      n_row = 0; n_col = 0; n_elem = 32'd5; @(posedge clk); #1;
      n_col = 1; n_elem = 32'd6; @(posedge clk); #1;
      n_row = 1; n_col = 0; n_elem = 32'd7; @(posedge clk); #1;
      n_col = 1; n_elem = 32'd8; @(posedge clk); #1;
      n_load = 0;
      n_fmt = 0; n_m = 16'd2; n_n = 16'd2; n_k = 16'd2;
      n_start = 1; @(posedge clk); #1; n_start = 0;
      begin
        int unsigned guard;
        guard = 0;
        while (!n_done && guard < 40) begin
          @(posedge clk);
          guard++;
        end
        if (!n_done) $fatal(1, "1-lane tile did not finish");
      end
      if (n_status != 16'd0 ||
          i_narrow.c_mem[0][0][0] != 32'd19 || i_narrow.c_mem[0][0][1] != 32'd22 ||
          i_narrow.c_mem[0][1][0] != 32'd43 || i_narrow.c_mem[0][1][1] != 32'd50)
        $fatal(1, "1-lane C %0d %0d %0d %0d",
               i_narrow.c_mem[0][0][0], i_narrow.c_mem[0][0][1],
               i_narrow.c_mem[0][1][0], i_narrow.c_mem[0][1][1]);
      // Fast mask, no real model: a float name is not a float datapath.
      while (n_done) @(posedge clk);
      n_fmt = 3'd7; n_m = 16'd1; n_n = 16'd1; n_k = 16'd1;
      n_start = 1; @(posedge clk); #1; n_start = 0;
      begin
        int unsigned guard;
        guard = 0;
        while (!n_done && guard < 8) begin
          @(posedge clk);
          guard++;
        end
      end
      if (n_status != 16'd8)
        $fatal(1, "1-lane integer tile accepted FP32 status %0d", n_status);

      // FP32 on the 8-lane tile. 1*5+2*7 = 19 → 0x41980000.
      while (t_done) @(posedge clk);
      t_ab = 0; t_cl = 0;
      t_row = 0; t_col = 0; t_elem = 32'h3f800000; t_load = 1; @(posedge clk); #1;
      t_col = 1; t_elem = 32'h40000000; @(posedge clk); #1;
      t_row = 1; t_col = 0; t_elem = 32'h40400000; @(posedge clk); #1;
      t_col = 1; t_elem = 32'h40800000; @(posedge clk); #1;
      t_ab = 1;
      t_row = 0; t_col = 0; t_elem = 32'h40a00000; @(posedge clk); #1;
      t_col = 1; t_elem = 32'h40c00000; @(posedge clk); #1;
      t_row = 1; t_col = 0; t_elem = 32'h40e00000; @(posedge clk); #1;
      t_col = 1; t_elem = 32'h41000000; @(posedge clk); #1;
      t_load = 0;
      t_fmt = 3'd7; t_m = 16'd2; t_n = 16'd2; t_k = 16'd2;
      t_start = 1; @(posedge clk); #1; t_start = 0;
      begin
        int unsigned guard;
        guard = 0;
        while (!t_done && guard < 24) begin
          @(posedge clk);
          guard++;
        end
        if (!t_done) $fatal(1, "fp32 tile did not finish");
      end
      if (t_status != 16'd0 ||
          i_tile.c_mem[0][0][0] != 32'h41980000 ||
          i_tile.c_mem[0][0][1] != 32'h41b00000 ||
          i_tile.c_mem[0][1][0] != 32'h422c0000 ||
          i_tile.c_mem[0][1][1] != 32'h42480000)
        $fatal(1, "fp32 tile C %h %h %h %h",
               i_tile.c_mem[0][0][0], i_tile.c_mem[0][0][1],
               i_tile.c_mem[0][1][0], i_tile.c_mem[0][1][1]);
    end

    if (!model_init)
      $fatal(1, "class2 model init");
    w_go = 1;
    @(posedge clk);
    @(posedge clk);
    w_go = 0;
    @(posedge clk);
    if (model_w[0] < 32'd1)
      $fatal(1, "class2 model counted no beats");
    $display("PASS tb_g6lc_ai_throughput model");
    $finish;
  end
endmodule
