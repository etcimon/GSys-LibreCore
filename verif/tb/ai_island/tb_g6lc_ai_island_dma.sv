// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Standalone Verilator testbench for g6lc_ai_island_top with EnableDmaFetch=1.
// Uses a simple AXI stub memory supporting INCR bursts so a single GEMM job
// can run and the policy PMU words (0x0190..0x019C) can be read after completion.
//
// This is a directed policy-in-context smoke, not a full SoC replacement.

`timescale 1ns/1ps
`include "axi/typedef.svh"
`include "axi/assign.svh"

module tb_g6lc_ai_island_dma #(
    parameter bit DMA_INVAL_EN = 1'b0,
    parameter bit ISLAND_FP_EN = 1'b1,
    parameter bit SMALL_GEOMETRY = 1'b0
) (
    input  logic        clk,
    input  logic        rst_ni,
    input  logic        req,
    input  logic        we,
    input  logic [15:0] addr,
    input  logic [31:0] wdata,
    output logic [31:0] rdata,
    output logic        rvalid,
    output logic        irq
);
  import g6lc_ai_desc_pkg::*;
  import g6lc_ai_island_cfg_pkg::*;
  import config_pkg::*;

  localparam int unsigned ADDR_W  = 64;
  localparam int unsigned DATA_W  = 64;
  localparam int unsigned ID_W    = 4;
  localparam int unsigned USER_W  = 1;
  localparam int unsigned STRB_W  = DATA_W / 8;

  typedef logic [ADDR_W-1:0] addr_t;
  typedef logic [ID_W-1:0]   id_t;
  typedef logic [DATA_W-1:0] data_t;
  typedef logic [STRB_W-1:0] strb_t;
  typedef logic [USER_W-1:0] user_t;
  `AXI_TYPEDEF_ALL(gbus, addr_t, id_t, data_t, strb_t, user_t)

  localparam ai_cfg_t AiCfgOn = '{
    MatrixEn: 1'b1,
    AccelEn: 1'b0,
    TileLdEn: 1'b0,
    RequantEn: 1'b1,
    SparseEn: 1'b1,
    UmodeEn: 1'b1,
    PolicyCodecEn: 1'b1,
    PolicyBenefitEn: 1'b1,
    PolicySubcodeEn: 1'b0,
    PolicySubcodeCacheEn: 1'b0,
    VaTurboEn: 1'b0,
    IslandFpEn: ISLAND_FP_EN,
    DmaInvalEn: DMA_INVAL_EN,
    Int4En: 1'b1,
    Sparse24En: 1'b0,
    FormatMask: ISLAND_FP_EN ? 32'h0000_00FF : 32'h0000_0003,
    TileM: 32'd8,
    TileN: 32'd8,
    TileK: 32'd8,
    TileCount: 32'd8,
    AccBanks: 32'd1,
    AccDepth: 32'd8,
    Queues: 32'd1,
    QueueDepth: 32'd16,
    QosClasses: 32'd1
  };

  gbus_req_t  axi_req;
  gbus_resp_t axi_resp;

  logic [AI_DRAM_MAX_CHANNELS-1:0][31:0] ch_r, ch_w;
  logic inval_valid, inval_ready, inval_done_q, inval_busy_q;
  logic completion_valid;
  logic [ADDR_W-1:0] inval_addr;
  logic [2:0] inval_delay_q;
  assign ch_r = '0;
  assign ch_w = '0;
  function automatic ai_island_cfg_t smoke_island_cfg();
    ai_island_cfg_t c = AiIslandLatencyDefault;
    if (SMALL_GEOMETRY) begin
      c.MacsPerCycle = 8;
      c.AccTileM = 8; c.AccTileN = 8; c.AccTileK = 8;
      c.SramBytes = 4096;
    end
    return c;
  endfunction
  assign inval_ready = !inval_busy_q;
  // CMO consumer: retain an accepted request for four cycles before done.
  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      inval_busy_q <= 1'b0;
      inval_done_q <= 1'b0;
      inval_delay_q <= '0;
    end else begin
      inval_done_q <= 1'b0;
      if (inval_busy_q) begin
        if (inval_delay_q == 0) begin
          inval_busy_q <= 1'b0;
          inval_done_q <= 1'b1;
        end else inval_delay_q <= inval_delay_q - 1'b1;
      end else if (inval_valid && inval_ready) begin
        inval_busy_q <= 1'b1;
        inval_delay_q <= 3'd3;
      end
    end
  end

  g6lc_ai_island_top #(
      .AiCfg(AiCfgOn),
      .IslandCfg(smoke_island_cfg()),
      .EnableDmaFetch(1'b1),
      .AxiDataWidth(DATA_W),
      .AxiIdWidth(ID_W),
      .axi_req_t(gbus_req_t),
      .axi_resp_t(gbus_resp_t)
  ) i_dut (
      .clk_i(clk),
      .rst_ni,
      .testmode_i(1'b0),
      .req_i(req),
      .we_i(we),
      .addr_i(addr),
      .wdata_i(wdata),
      .rdata_o(rdata),
      .rvalid_o(rvalid),
      .rerror_o(),
      .irq_o(irq),
      .sb_enq_valid_i(1'b0),
      .sb_enq_ready_o(),
      .sb_qid_i(8'd0),
      .sb_ticket_i(32'd0),
      .sb_desc_ptr_i(64'd0),
      .sb_last_ticket_o(),
      .sb_last_status_o(),
      .sb_has_completion_o(completion_valid),
      .sb_retired_valid_o(),
      .sb_retired_ticket_o(),
      .dma_inval_valid_o(inval_valid), .dma_inval_addr_o(inval_addr),
      .dma_inval_ready_i(inval_ready), .dma_inval_done_i(inval_done_q),
      .axi_dma_req_o(axi_req),
      .axi_dma_resp_i(axi_resp),
      .dram_init_done_i(1'b1),
      .ch_r_beats_i(ch_r),
      .ch_w_beats_i(ch_w)
  );

  // AXI stub memory
  localparam int unsigned MEM_WORDS = 8192;  // 64 KiB, enough for 32 small policy-walk jobs
  localparam logic [ADDR_W-1:0] MEM_BASE = 64'h8001_0000;
  logic [DATA_W-1:0] mem [0:MEM_WORDS-1];

  // Read channel
  typedef enum logic [1:0] {RD_IDLE, RD_DATA} rd_state_t;
  rd_state_t rd_state;
  addr_t ar_addr_q;
  logic [7:0] ar_len_q;
  id_t ar_id_q;
  logic [7:0] rd_beat;

  // Write channel
  typedef enum logic [1:0] {WR_IDLE, WR_DATA, WR_RESP} wr_state_t;
  wr_state_t wr_state;
  addr_t aw_addr_q;
  logic [7:0] aw_len_q;
  logic [2:0] aw_size_q;
  id_t aw_id_q;
  logic [7:0] wr_beat;

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_state   <= RD_IDLE;
      ar_addr_q  <= '0;
      ar_len_q   <= '0;
      ar_id_q    <= '0;
      rd_beat    <= '0;
      wr_state   <= WR_IDLE;
      aw_addr_q  <= '0;
      aw_len_q   <= '0;
      aw_size_q  <= '0;
      aw_id_q    <= '0;
      wr_beat    <= '0;
    end else begin
      // AR handshake
      if (rd_state == RD_IDLE && axi_req.ar_valid) begin
        rd_state  <= RD_DATA;
        ar_addr_q <= axi_req.ar.addr;
        ar_len_q  <= axi_req.ar.len;
        ar_id_q   <= axi_req.ar.id;
        rd_beat   <= '0;
      end else if (rd_state == RD_DATA && axi_req.r_ready) begin
        if (rd_beat == ar_len_q) begin
          rd_state <= RD_IDLE;
        end else begin
          rd_beat <= rd_beat + 8'd1;
        end
      end

      // AW/W handshake
      case (wr_state)
        WR_IDLE: if (axi_req.aw_valid) begin
          wr_state  <= WR_DATA;
          aw_addr_q <= axi_req.aw.addr;
          aw_len_q  <= axi_req.aw.len;
          aw_size_q <= axi_req.aw.size;
          aw_id_q   <= axi_req.aw.id;
          wr_beat   <= '0;
        end
        WR_DATA: if (axi_req.w_valid) begin
          if (axi_req.w.last || wr_beat == aw_len_q) begin
            wr_state <= WR_RESP;
          end else begin
            wr_beat <= wr_beat + 8'd1;
          end
        end
        WR_RESP: if (axi_req.b_ready) begin
          wr_state <= WR_IDLE;
        end
      endcase
    end
  end

  // Independent per-line B/invalidation scoreboard. Coalescing may invalidate
  // several landed writes once; the last invalidation must cover the last B.
  typedef logic [ADDR_W-7:0] line_t;
  int unsigned landed [line_t];
  int unsigned invalidations [line_t];
  int unsigned last_inv_land [line_t];
  int unsigned total_invals;
  logic completion_prev_q;
  int unsigned trace_cycle;
  always @(posedge clk) begin
    if (!rst_ni) trace_cycle = 0;
    else begin
      trace_cycle++;
      if ($test$plusargs("trace_load")) begin
        if (axi_req.ar_valid && axi_resp.ar_ready)
          $display("TRACE %0d EXT_AR addr=%h len=%0d id=%0d",
              trace_cycle, axi_req.ar.addr, axi_req.ar.len, axi_req.ar.id);
        if (axi_resp.r_valid && axi_req.r_ready)
          $display("TRACE %0d EXT_R addr=%h beat=%0d last=%b id=%0d",
              trace_cycle, ar_addr_q, rd_beat, axi_resp.r.last, axi_resp.r.id);
        if (i_dut.gen_dma_fetch.gen_one_engine.i_gemm.load_ar_fire)
          $display("TRACE %0d GEMM_AR addr=%h len=%0d row=%0d",
              trace_cycle, i_dut.gen_dma_fetch.gen_one_engine.i_gemm.read_req.ar.addr,
              i_dut.gen_dma_fetch.gen_one_engine.i_gemm.read_req.ar.len,
              i_dut.gen_dma_fetch.gen_one_engine.i_gemm.ar_i_q);
        if (i_dut.gen_dma_fetch.gen_one_engine.i_gemm.load_r_fire)
          $display("TRACE %0d GEMM_R row=%0d last=%b id=%0d",
              trace_cycle, i_dut.gen_dma_fetch.gen_one_engine.i_gemm.receive_row,
              i_dut.gen_dma_fetch.gen_one_engine.i_gemm.axi_resp_s.r.last,
              i_dut.gen_dma_fetch.gen_one_engine.i_gemm.axi_resp_s.r.id);
      end
    end
  end
  always @(posedge clk) begin
    if (!rst_ni) begin
      landed.delete();
      invalidations.delete();
      last_inv_land.delete();
      total_invals = 0;
      completion_prev_q = 1'b0;
    end else if (DMA_INVAL_EN) begin
      if (wr_state == WR_RESP && axi_req.b_ready) begin
        logic [ADDR_W-1:0] last_byte;
        line_t first_line, last_line;
        last_byte = aw_addr_q + ((ADDR_W'(aw_len_q) + 1) << aw_size_q) - 1;
        first_line = aw_addr_q[ADDR_W-1:6];
        last_line = last_byte[ADDR_W-1:6];
        for (line_t l = first_line; l <= last_line; l++) landed[l]++;
      end
      if (inval_valid && inval_ready) begin
        line_t l;
        l = inval_addr[ADDR_W-1:6];
        if (!landed.exists(l) || landed[l] <= invalidations[l])
          $fatal(1, "DMA_INVAL_BEFORE_B line=%h", l);
        invalidations[l]++;
        last_inv_land[l] = landed[l];
        total_invals++;
      end
      if (completion_valid && !completion_prev_q) begin
        if (inval_busy_q || inval_valid || total_invals == 0 || wr_state != WR_IDLE)
          $fatal(1, "DMA_COMPLETION_BEFORE_INVALIDATION_DRAIN");
        foreach (landed[l])
          if (last_inv_land[l] != landed[l])
            $fatal(1, "DMA_COMPLETION_STALE_LINE line=%h", l);
        $display("PASS DMA_INVAL_INTEGRATION invalidations=%0d", total_invals);
      end
      completion_prev_q = completion_valid;
    end
  end

  data_t r_data;
  always_comb begin
    automatic logic [ADDR_W-1:0] off;
    off = (ar_addr_q - MEM_BASE) >> $clog2(DATA_W / 8);
    off = off + rd_beat;
    if (off < MEM_WORDS)
      r_data = mem[off[ $clog2(MEM_WORDS)-1:0 ]];
    else
      r_data = '0;
  end

  assign axi_resp = '{
    aw_ready: (wr_state == WR_IDLE),
    w_ready:  (wr_state == WR_DATA),
    ar_ready: (rd_state == RD_IDLE),
    b:        '{id: aw_id_q, resp: 2'b00, user: '0},
    b_valid:  (wr_state == WR_RESP),
    r:        '{data: r_data, last: (rd_beat == ar_len_q), id: ar_id_q,
                 resp: 2'b00, user: '0},
    r_valid:  (rd_state == RD_DATA)
  };

  // Initialize memory: descriptor at MEM_BASE; A/B/C/done data are zero.
  // For a policy-walk replay, a +walk_file plusarg loads a $readmemh() image
  // generated by gen_policy_walk.py instead of the single fixed descriptor.
  initial begin
    desc_t d;
    desc_bits_t b;
    string walk_file;
    int i;

    for (i = 0; i < MEM_WORDS; i++)
      mem[i] = '0;

    if ($value$plusargs("walk_file=%s", walk_file)) begin
      $readmemh(walk_file, mem);
      $display("[tb] loaded walk image %s into AXI stub memory", walk_file);
    end else begin
      d = '0;
      d.version   = 16'(ContractVersion);
      d.op        = OP_GEMM;
      d.flags     = 32'h0;
      d.m         = 32'd8;
      d.n         = 32'd8;
      d.k         = 32'd8;
      d.ld_ab     = {16'd8, 16'd8};
      d.ptr_a     = 64'h0000_0000_8001_0100;
      d.ptr_b     = 64'h0000_0000_8001_0200;
      d.ptr_c     = 64'h0000_0000_8001_0300;
      d.ptr_scale = 64'h0;
      d.ptr_done  = 64'h0000_0000_8001_0400;

      b = desc_to_bits(d);
      for (i = 0; i < 8; i++)
        mem[i] = {b[i*64 + 32 +: 32], b[i*64 +: 32]};
    end
  end
endmodule
