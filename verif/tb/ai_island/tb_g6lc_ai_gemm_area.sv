// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// Synthesis-only area probe for g6lc_ai_gemm_seq.  Pairs with the measured
// throughput sweep in run-gemm-scaling.sh so "wider engine" and "more engines"
// can be compared on generic cells per MAC/cycle instead of intuition.
//
// Lanes/ArOut are the only knobs; the defaults match the shipped live
// configuration.  This module is never simulated and is not part of any
// functional testbench: it exists so Yosys has a synthesizable top with
// concrete AXI struct types.
//
// KNOWN LIMITATION (measured, not assumed): the Yosys `read_slang` frontend
// cannot currently elaborate g6lc_ai_gemm_seq through this top.  The operand
// assembly loop at g6lc_ai_gemm_seq.sv:1164 is bounded by the runtime value
// `mac_step` rather than a constant, so slang tries to unroll it and reports
// "unroll limit exhausted" even at --unroll-limit=12000; raising the limit to
// 200000 exhausts host memory instead.  Consequently no gate-level cell count
// exists for the GEMM datapath, and the published synthesis evidence covers
// only the small policy controllers.  Making the sequencer elaborate under an
// open frontend (constant loop bounds derived from PeLanes/MaxDim) is a
// prerequisite for any area, timing or area-efficiency claim about it.

`include "axi/typedef.svh"

module tb_g6lc_ai_gemm_area
  import g6lc_ai_island_cfg_pkg::*;
#(
    parameter int unsigned Lanes    = 8,
    parameter int unsigned ArOut    = 2,
    parameter int unsigned Channels = 1,
    parameter bit ReuseBEn = 1'b0,
    parameter bit ReuseAEn = 1'b0,
    // 0 selects the combinational float dot, 1 the pipelined one. This matters
    // for any depth/timing statement: the combinational variant is what makes the
    // longest topological path enormous, and it is not the configuration a float
    // build would ship.
    parameter bit          DotPipe  = 1'b0,
    // Generous flat widths for the struct-typed AXI pair, declared here so the
    // port list can use them; the casts inside pick out exactly the struct bits.
    parameter int unsigned AXI_REQ_BITS  = 512,
    parameter int unsigned AXI_RESP_BITS = 256
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        testmode_i,
    input  logic        start_i,
    input  logic [31:0] m_i,
    input  logic [31:0] n_i,
    input  logic [31:0] k_i,
    input  logic [15:0] lda_i,
    input  logic [15:0] ldb_i,
    input  logic [2:0]  numfmt_i,
    input  logic [3:0]  ar_max_i,
    input  logic [39:0] ptr_a_i,
    input  logic [39:0] ptr_b_i,
    input  logic [39:0] ptr_c_i,
    output logic        ready_o,
    output logic        done_o,
    output logic        err_o,
    output logic [31:0] pmu_r_beats_o,
    output logic [31:0] pmu_w_beats_o,
    output logic [31:0] pmu_cycles_o,
    input logic reuse_b_i,
    input logic [31:0] reuse_b_epoch_i,
    input logic reuse_b_invalidate_i,
    output logic pmu_reuse_b_hit_o,
    input logic reuse_a_i,
    input logic [31:0] reuse_a_epoch_i,
    input logic reuse_a_invalidate_i,
    output logic pmu_reuse_a_hit_o,
    // The AXI pair must cross the boundary as real ports. An earlier version of
    // this harness fed the response back from the request, which let synthesis
    // constant-fold the whole operand path: the MAC arrays vanished and the cell
    // count barely moved between 8 and 64 lanes. Any area number from a harness
    // that internally closes this loop is meaningless.
    output logic [AXI_REQ_BITS-1:0] axi_req_o,
    input  logic [AXI_RESP_BITS-1:0] axi_resp_i
);
  localparam int unsigned ADDR_W = 40;
  localparam int unsigned DATA_W = 64;
  localparam int unsigned ID_W   = 4;

  typedef logic [ADDR_W-1:0]     addr_t;
  typedef logic [ID_W-1:0]       id_t;
  typedef logic [DATA_W-1:0]     data_t;
  typedef logic [DATA_W/8-1:0]   strb_t;
  typedef logic [0:0]            user_t;
  `AXI_TYPEDEF_ALL(gbus, addr_t, id_t, data_t, strb_t, user_t)

  gbus_req_t  gemm_req;
  gbus_resp_t gemm_resp;
  logic [AI_DRAM_MAX_CHANNELS-1:0][31:0] ch_r_beats, ch_w_beats;

  // Both directions leave the module, so no operand or result bit can be
  // resolved to a constant and pruned.
  assign axi_req_o = AXI_REQ_BITS'(gemm_req);
  assign gemm_resp = gbus_resp_t'(axi_resp_i);
  assign ch_r_beats = '0;
  assign ch_w_beats = '0;

  g6lc_ai_gemm_seq #(
      .AddrWidth  ( ADDR_W ),
      .DataWidth  ( DATA_W ),
      .IdWidth    ( ID_W ),
      .MaxDim     ( 16 ),
      .PeLanes    ( Lanes ),
      .DotPipeFloat( DotPipe ),
      .ReuseBEn(ReuseBEn),
      .ReuseAEn(ReuseAEn),
      .MaxAROut   ( ArOut ),
      .NrChannels ( Channels ),
      .ChanShift  ( AI_DRAM_CHAN_SHIFT_DEFAULT ),
      .axi_req_t  ( gbus_req_t ),
      .axi_resp_t ( gbus_resp_t )
  ) i_gemm (
      .clk_i        ( clk_i ),
      .rst_ni       ( rst_ni ),
      .testmode_i   ( testmode_i ),
      .start_i      ( start_i ),
      .m_i, .n_i, .k_i, .lda_i, .ldb_i, .numfmt_i, .ar_max_i,
      .ptr_a_i      ( ptr_a_i ),
      .ptr_b_i      ( ptr_b_i ),
      .ptr_c_i      ( ptr_c_i ),
      .ready_o      ( ready_o ),
      .done_o       ( done_o ),
      .err_o        ( err_o ),
      .axi_req_o    ( gemm_req ),
      .axi_resp_i   ( gemm_resp ),
      .pmu_r_beats_o( pmu_r_beats_o ),
      .pmu_w_beats_o( pmu_w_beats_o ),
      .pmu_cycles_o ( pmu_cycles_o ),
      .reuse_b_i, .reuse_b_epoch_i, .reuse_b_invalidate_i, .pmu_reuse_b_hit_o,
      .reuse_a_i, .reuse_a_epoch_i, .reuse_a_invalidate_i, .pmu_reuse_a_hit_o
  );
endmodule
