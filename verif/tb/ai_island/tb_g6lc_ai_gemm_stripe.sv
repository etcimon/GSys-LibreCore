// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// Island GEMM vs a striped address map (N=2, shift 6). A starts 8 B from the
// end of a 64 B stripe so the first AR must cap. A=1, B=1 ⇒ C=k=16 proves
// SplitArId tile writes. TB SRAM slave (not LiteDRAM, not Variane).

`timescale 1ns/1ps
`include "axi/typedef.svh"
`include "axi/assign.svh"

module tb_g6lc_ai_gemm_stripe
  import g6lc_ai_island_cfg_pkg::*;
#(
    parameter int unsigned NCH = 2
);
  localparam int unsigned ID_W   = 4;
  localparam int unsigned ADDR_W = 64;
  localparam int unsigned DATA_W = 64;
  localparam int unsigned USER_W = 1;
  localparam int unsigned SHIFT  = AI_DRAM_CHAN_SHIFT_DEFAULT;
  localparam int unsigned TO     = 20000;
  localparam logic [DATA_W-1:0] ONES8 = 64'h0101_0101_0101_0101;
  localparam logic [DATA_W-1:0] C16   = 64'h0000_0010_0000_0010;

  typedef logic [ADDR_W-1:0]     addr_t;
  typedef logic [ID_W-1:0]       id_t;
  typedef logic [DATA_W-1:0]     data_t;
  typedef logic [DATA_W/8-1:0]   strb_t;
  typedef logic [USER_W-1:0]     user_t;
  `AXI_TYPEDEF_ALL(dram, addr_t, id_t, data_t, strb_t, user_t)

  logic clk, rst_ni, start, ready, done, err;
  dram_req_t  gemm_req;
  dram_resp_t gemm_resp;
  int unsigned errors, cycles, n_ar, n_aw, n_cap, max_inf;
  logic saw_cap, saw_next, straddle, saw_id2, saw_id3;
  logic [15:0] inf_ids;
  logic [31:0] ch_r[2], ch_w[2];
  logic [31:0] pmu_r, pmu_w, pmu_cy;

  logic [DATA_W-1:0] ram [0:1023];
  logic              wr_busy, b_pend;
  logic [ID_W-1:0]   wr_id;
  logic [ADDR_W-1:0] wr_addr;
  typedef struct packed {
    logic [ID_W-1:0]   id;
    logic [ADDR_W-1:0] addr;
    logic [7:0]        left;
  } rdq_t;
  rdq_t          rdq [0:1];
  logic [1:0]    rd_n;
  logic          rd_hd, rd_tl;

  AXI_BUS #(
      .AXI_ADDR_WIDTH ( ADDR_W ),
      .AXI_DATA_WIDTH ( DATA_W ),
      .AXI_ID_WIDTH   ( ID_W   ),
      .AXI_USER_WIDTH ( USER_W )
  ) dram();

  `AXI_ASSIGN_FROM_REQ(dram, gemm_req)
  `AXI_ASSIGN_TO_RESP(gemm_resp, dram)

  function automatic int unsigned ram_idx(input logic [ADDR_W-1:0] a);
    return unsigned'(a[12:3]);
  endfunction

  assign dram.aw_ready = rst_ni && !wr_busy && !b_pend;
  assign dram.w_ready  = rst_ni && wr_busy;
  assign dram.ar_ready = rst_ni && (rd_n < 2'd2);
  assign dram.b_valid  = rst_ni && b_pend;
  assign dram.b_id     = wr_id;
  assign dram.b_resp   = 2'b00;
  assign dram.b_user   = '0;
  assign dram.r_valid  = rst_ni && (rd_n != 2'd0);
  assign dram.r_id     = rdq[rd_hd].id;
  assign dram.r_data   = ram[ram_idx(rdq[rd_hd].addr)];
  assign dram.r_resp   = 2'b00;
  assign dram.r_last   = (rd_n != 2'd0) && (rdq[rd_hd].left == 8'd0);
  assign dram.r_user   = '0;

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      wr_busy <= 1'b0;
      b_pend  <= 1'b0;
      wr_id   <= '0;
      wr_addr <= '0;
      rd_n    <= '0;
      rd_hd   <= 1'b0;
      rd_tl   <= 1'b0;
      rdq[0]  <= '0;
      rdq[1]  <= '0;
      ch_r[0] <= '0;
      ch_r[1] <= '0;
      ch_w[0] <= '0;
      ch_w[1] <= '0;
    end else begin
      if (dram.aw_valid && dram.aw_ready) begin
        wr_busy <= 1'b1;
        wr_id   <= dram.aw_id;
        wr_addr <= dram.aw_addr;
      end
      if (dram.w_valid && dram.w_ready) begin
        ram[ram_idx(wr_addr)] <= dram.w_data;
        ch_w[wr_addr[SHIFT]]  <= ch_w[wr_addr[SHIFT]] + 32'd1;
        wr_addr <= wr_addr + ADDR_W'(DATA_W/8);
        if (dram.w_last) begin
          wr_busy <= 1'b0;
          b_pend  <= 1'b1;
        end
      end
      if (dram.b_valid && dram.b_ready)
        b_pend <= 1'b0;
      if (dram.ar_valid && dram.ar_ready) begin
        rdq[rd_tl].id   <= dram.ar_id;
        rdq[rd_tl].addr <= dram.ar_addr;
        rdq[rd_tl].left <= dram.ar_len;
        rd_tl <= ~rd_tl;
      end
      if (dram.r_valid && dram.r_ready) begin
        ch_r[rdq[rd_hd].addr[SHIFT]] <= ch_r[rdq[rd_hd].addr[SHIFT]] + 32'd1;
        if (dram.r_last)
          rd_hd <= ~rd_hd;
        else begin
          rdq[rd_hd].addr <= rdq[rd_hd].addr + ADDR_W'(DATA_W/8);
          rdq[rd_hd].left <= rdq[rd_hd].left - 8'd1;
        end
      end
      unique case ({dram.ar_valid && dram.ar_ready,
                    dram.r_valid && dram.r_ready && dram.r_last})
        2'b10: rd_n <= rd_n + 2'd1;
        2'b01: rd_n <= rd_n - 2'd1;
        default: ;
      endcase
    end
  end

  g6lc_ai_gemm_seq #(
      .AddrWidth  ( ADDR_W ),
      .DataWidth  ( DATA_W ),
      .IdWidth    ( ID_W ),
      .MaxDim     ( 16 ),
      .PeLanes    ( 8 ),
      .MaxAROut   ( 2 ),
      .NrChannels ( NCH ),
      .ChanShift  ( SHIFT ),
      .axi_req_t  ( dram_req_t ),
      .axi_resp_t ( dram_resp_t )
  ) i_gemm (
      .clk_i        ( clk ),
      .rst_ni       ( rst_ni ),
      .testmode_i   ( 1'b0 ),
      .start_i      ( start ),
      .m_i          ( 32'd2 ),
      .n_i          ( 32'd2 ),
      .k_i          ( 32'd16 ),
      .lda_i        ( 16'd16 ),
      .ldb_i        ( 16'd16 ), .ldc_i(16'd0),
      .numfmt_i     ( 3'd0 ),
      .accumulate_i(1'b0),
      .ar_max_i     ( 4'd2 ),
      .ptr_a_i      ( 64'h8000_0038 ),
      .ptr_b_i      ( 64'h8000_0100 ),
      .ptr_c_i      ( 64'h8000_0200 ),
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
      n_ar      <= 0;
      n_aw      <= 0;
      n_cap     <= 0;
      max_inf   <= 0;
      saw_cap   <= 1'b0;
      saw_next  <= 1'b0;
      straddle  <= 1'b0;
      saw_id2   <= 1'b0;
      saw_id3   <= 1'b0;
      inf_ids   <= '0;
    end else begin
      if (dram.ar_valid && dram.ar_ready) begin
        automatic int unsigned nbytes, inf;
        n_ar <= n_ar + 1;
        nbytes = (unsigned'(dram.ar_len) + 1) << unsigned'(dram.ar_size);
        if (!dram_burst_fits_stripe(NCH, SHIFT, dram.ar_addr, nbytes))
          straddle <= 1'b1;
        if (dram.ar_addr == 64'h8000_0038 && dram.ar_len == 8'd0) begin
          saw_cap <= 1'b1;
          n_cap   <= n_cap + 1;
        end
        if (dram.ar_addr == 64'h8000_0040)
          saw_next <= 1'b1;
        if (dram.ar_id == 4'd2) saw_id2 <= 1'b1;
        if (dram.ar_id == 4'd3) saw_id3 <= 1'b1;
        inf_ids[dram.ar_id] <= 1'b1;
        inf = $countones(inf_ids) + (inf_ids[dram.ar_id] ? 0 : 1);
        if (inf > max_inf) max_inf <= inf;
      end
      if (dram.r_valid && dram.r_ready && dram.r_last)
        inf_ids[dram.r_id] <= 1'b0;
      if (dram.aw_valid && dram.aw_ready) begin
        automatic int unsigned nbytes;
        n_aw <= n_aw + 1;
        nbytes = (unsigned'(dram.aw_len) + 1) << unsigned'(dram.aw_size);
        if (!dram_burst_fits_stripe(NCH, SHIFT, dram.aw_addr, nbytes))
          straddle <= 1'b1;
      end
    end
  end

  task automatic tick;
    @(posedge clk);
    cycles++;
  endtask

  initial begin
    int unsigned i;
    errors = 0;
    cycles = 0;
    start  = 1'b0;
    for (i = 0; i < 1024; i++)
      ram[i] = '0;
    ram[ram_idx(64'h8000_0038)] = ONES8;
    ram[ram_idx(64'h8000_0040)] = ONES8;
    ram[ram_idx(64'h8000_0048)] = ONES8;
    ram[ram_idx(64'h8000_0050)] = ONES8;
    ram[ram_idx(64'h8000_0100)] = ONES8;
    ram[ram_idx(64'h8000_0108)] = ONES8;
    ram[ram_idx(64'h8000_0110)] = ONES8;
    ram[ram_idx(64'h8000_0118)] = ONES8;
    rst_ni = 1'b0;
    repeat (8) tick;
    rst_ni = 1'b1;
    repeat (8) tick;

    if (!ready) begin
      $error("gemm not ready after reset");
      errors++;
    end

    start = 1'b1;
    tick;
    start = 1'b0;

    while (!done && cycles < TO) tick;

    if (!done) begin
      $error("timeout gemm done cycles=%0d ar=%0d aw=%0d", cycles, n_ar, n_aw);
      errors++;
    end
    if (err) begin
      $error("gemm err");
      errors++;
    end
    if (straddle) begin
      $error("GEMM AR/AW straddled a 64 B stripe");
      errors++;
    end
    if (NCH > 1) begin
      if (!saw_cap) begin
        $error("missing capped AR at 0x80000038 len=0");
        errors++;
      end
      if (!saw_next) begin
        $error("missing continuation AR at 0x80000040 (next stripe/channel)");
        errors++;
      end
      if (!saw_id2 || !saw_id3) begin
        $error("N>1 GEMM must split AR ids (saw2=%0d saw3=%0d)", saw_id2, saw_id3);
        errors++;
      end
      if (max_inf < 2) begin
        $error("MaxAROut did not place two IDs in flight (max_inf=%0d)", max_inf);
        errors++;
      end
      if (ch_r[0] == 0 || ch_r[1] == 0) begin
        $error("occupancy silent r ch0=%0d ch1=%0d", ch_r[0], ch_r[1]);
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
    if (ram[ram_idx(64'h8000_0200)] !== C16 ||
        ram[ram_idx(64'h8000_0208)] !== C16) begin
      $error("golden C exp=16,16 got %h %h",
             ram[ram_idx(64'h8000_0200)], ram[ram_idx(64'h8000_0208)]);
      errors++;
    end

    if (errors == 0)
      $display("PASS g6lc_ai_gemm_stripe nch=%0d cap_ar=%0d ar=%0d aw=%0d cycles=%0d r=%0d/%0d goldenC=16",
               NCH, n_cap, n_ar, n_aw, cycles, ch_r[0], ch_r[1]);
    else begin
      $display("FAIL g6lc_ai_gemm_stripe errors=%0d", errors);
      $fatal(1);
    end
    $finish;
  end
endmodule
