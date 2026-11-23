// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_axi_atomics_wrap leaf: read-slot accounting across R-producing atomics.
// The AMO adapter answers an AtomicSwap/Load/Compare with an injected R that
// has no AR on the monitor's slave port. g6lc_axi_lrsc must count that read at
// the AW handshake; counting ARs only lets the injected R-last pop an entry
// that was never pushed, the counter wraps, and after MaxOut atomics the
// monitor refuses every AR with nothing outstanding (mc_cas_lock_handoff).
//   S1  NATOP atomics, each followed by a line read that must be accepted
//   S2  the swap chain returns the previous value every time (data path)
//   S3  the monitor's read counter is back at zero once the bus is idle
// +oracle_negative corrupts the expected swap value: the scoreboard must fail.

module tb_g6lc_axi_lrsc_atop;
  localparam int unsigned AW = 64, DW = 64, IW = 4, UW = 1;
  localparam int unsigned MAXOUT = 8;
  localparam int unsigned NATOP  = 3 * MAXOUT + 1;
  localparam int unsigned TMO    = 400;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  AXI_BUS #(.AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW), .AXI_ID_WIDTH(IW), .AXI_USER_WIDTH(UW)) up ();
  AXI_BUS #(.AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW), .AXI_ID_WIDTH(IW), .AXI_USER_WIDTH(UW)) dn ();

  g6lc_axi_atomics_wrap #(
      .AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW), .AXI_ID_WIDTH(IW), .AXI_USER_WIDTH(UW),
      .AXI_MAX_WRITE_TXNS(MAXOUT), .RISCV_WORD_WIDTH(64), .NRes(2)
  ) dut (
      .clk_i(clk), .rst_ni(rst_n), .res_clr_i(1'b0), .mst(dn), .slv(up)
  );

  // ---- memory slave: one read burst and one write at a time ----------------
  logic [DW-1:0] mem [256];
  logic          rd_act, wr_act, wr_b;
  logic [IW-1:0] rd_id, wr_id;
  logic [7:0]    rd_idx, rd_left, wr_idx;

  assign dn.ar_ready = !rd_act;
  assign dn.r_valid  = rd_act;
  assign dn.r_id     = rd_id;
  assign dn.r_data   = mem[rd_idx];
  assign dn.r_resp   = 2'b00;
  assign dn.r_last   = (rd_left == 8'd0);
  assign dn.r_user   = '0;
  assign dn.aw_ready = !wr_act && !wr_b;
  assign dn.w_ready  = wr_act;
  assign dn.b_valid  = wr_b;
  assign dn.b_id     = wr_id;
  assign dn.b_resp   = 2'b00;
  assign dn.b_user   = '0;

  logic [DW-1:0] wr_merge;
  always_comb begin
    wr_merge = mem[wr_idx];
    for (int b = 0; b < DW/8; b++)
      if (dn.w_strb[b]) wr_merge[8*b +: 8] = dn.w_data[8*b +: 8];
  end
  initial for (int i = 0; i < 256; i++) mem[i] = DW'(64'hA500_0000 + i);

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rd_act <= 1'b0; wr_act <= 1'b0; wr_b <= 1'b0;
      rd_id <= '0; wr_id <= '0; rd_idx <= '0; rd_left <= '0; wr_idx <= '0;
    end else begin
      if (dn.ar_valid && dn.ar_ready) begin
        rd_act <= 1'b1; rd_id <= dn.ar_id; rd_idx <= dn.ar_addr[10:3]; rd_left <= dn.ar_len;
      end else if (rd_act && dn.r_ready) begin
        rd_idx <= rd_idx + 8'd1; rd_left <= rd_left - 8'd1;
        if (rd_left == 8'd0) rd_act <= 1'b0;
      end
      if (dn.aw_valid && dn.aw_ready) begin
        wr_act <= 1'b1; wr_id <= dn.aw_id; wr_idx <= dn.aw_addr[10:3];
      end else if (wr_act && dn.w_valid) begin
        mem[wr_idx] <= wr_merge;
        wr_idx <= wr_idx + 8'd1;
        if (dn.w_last) begin wr_act <= 1'b0; wr_b <= 1'b1; end
      end
      if (wr_b && dn.b_ready) wr_b <= 1'b0;
    end
  end

  // ---- master ---------------------------------------------------------------
  initial begin
    up.aw_valid = 1'b0; up.w_valid = 1'b0; up.ar_valid = 1'b0;
    up.b_ready = 1'b1; up.r_ready = 1'b1;
    up.aw_id = '0; up.aw_addr = '0; up.aw_len = '0; up.aw_size = 3'd3; up.aw_burst = 2'b01;
    up.aw_lock = 1'b0; up.aw_cache = '0; up.aw_prot = '0; up.aw_qos = '0; up.aw_region = '0;
    up.aw_atop = '0; up.aw_user = '0;
    up.w_data = '0; up.w_strb = '1; up.w_last = 1'b1; up.w_user = '0;
    up.ar_id = '0; up.ar_addr = '0; up.ar_len = '0; up.ar_size = 3'd3; up.ar_burst = 2'b01;
    up.ar_lock = 1'b0; up.ar_cache = '0; up.ar_prot = '0; up.ar_qos = '0; up.ar_region = '0;
    up.ar_user = '0;
  end

  // AtomicSwap: AW + W, then B and the injected single-beat R (old value).
  task automatic swap(input logic [AW-1:0] addr, input logic [DW-1:0] wdata,
                      output logic [DW-1:0] old);
    bit aw_d, w_d, b_d, r_d;
    int unsigned t;
    aw_d = 0; w_d = 0; b_d = 0; r_d = 0; t = 0;
    up.aw_addr <= addr; up.aw_id <= IW'(0); up.aw_atop <= axi_pkg::ATOP_ATOMICSWAP;
    up.aw_valid <= 1'b1;
    up.w_data <= wdata; up.w_valid <= 1'b1;
    while (!(aw_d && w_d && b_d && r_d)) begin
      @(posedge clk);
      if (up.aw_valid && up.aw_ready) begin aw_d = 1; up.aw_valid <= 1'b0; up.aw_atop <= '0; end
      if (up.w_valid && up.w_ready)   begin w_d = 1;  up.w_valid <= 1'b0; end
      if (up.b_valid && up.b_ready)   b_d = 1;
      if (up.r_valid && up.r_ready && up.r_last) begin r_d = 1; old = up.r_data; end
      t++;
      if (t > TMO) $fatal(1, "LRSC_ATOP_SWAP_TIMEOUT aw=%0d w=%0d b=%0d r=%0d", aw_d, w_d, b_d, r_d);
    end
  endtask

  // Line read: the AR must be accepted and all beats returned.
  task automatic line_read(input logic [AW-1:0] addr, input int unsigned n_atop);
    bit ar_d;
    int unsigned t, beats;
    ar_d = 0; t = 0; beats = 0;
    up.ar_addr <= addr; up.ar_id <= IW'('1); up.ar_len <= 8'd7; up.ar_valid <= 1'b1;
    while (beats < 8) begin
      @(posedge clk);
      if (up.ar_valid && up.ar_ready) begin ar_d = 1; up.ar_valid <= 1'b0; end
      if (up.r_valid && up.r_ready) beats++;
      t++;
      if (t > TMO)
        $fatal(1, "LRSC_ATOP_S1_AR_REFUSED after %0d atomics: ar_done=%0d beats=%0d nar=%0d",
               n_atop, ar_d, beats, dut.i_lrsc.nar);
    end
  endtask

  initial begin
    logic [DW-1:0] old, want;
    bit neg;
    neg = $test$plusargs("oracle_negative");
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    repeat (4) @(posedge clk);
    want = DW'(64'hA500_0000 + 16);
    for (int unsigned i = 0; i < NATOP; i++) begin
      swap(64'h8000_0080, DW'(64'h1000 + i), old);
      if (old !== (neg && i == 5 ? ~want : want))
        $fatal(1, "LRSC_ATOP_S2_SWAP_DATA i=%0d got=%h want=%h", i, old, want);
      want = DW'(64'h1000 + i);
      line_read(64'h8000_0400, i + 1);
    end
    repeat (8) @(posedge clk);
    if (dut.i_lrsc.nar !== '0)
      $fatal(1, "LRSC_ATOP_S3_NAR_LEAK nar=%0d on an idle bus", dut.i_lrsc.nar);
    $display("PASS tb_g6lc_axi_lrsc_atop atomics=%0d", NATOP);
    $finish;
  end

  initial begin
    repeat (200000) @(posedge clk);
    $fatal(1, "LRSC_ATOP_GLOBAL_TIMEOUT");
  end
endmodule
