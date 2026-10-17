// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Copyright (c) 2026 Etienne Cimon
//
// T43 leaf: one valid-bit write of the WT data cache has one requester.
//
// The missunit's all-ways invalidation (wr_cl_vld_i, wr_cl_we_i = all ones,
// wr_vld_bits_i = 0 -- an AMO or a flush) is driven in the same cycle as a
// pending SL-W fixup `inv_req_i` for another way of the same index. The
// invalidation owns the port (inv_ack_o must stay low) and must leave every
// way of the index invalid: a tag-only lookup with the missunit's tag must
// miss in every way. Pre-fix the valid-bit data mux put inv_req_i first and
// the write validated the fixup's `inv_vld_bits & ~way` (seven ways) with the
// missunit's tag -- the L3 boot's `hit=f7` (G6LC_MUT_VLD_WDATA_INV_PRIO).
//
// S1  refill two ways of index I (tags A, B) -> lookups hit exactly one way each
// S2  the coincidence: all-ways invalidation at I with inv_req pending for way 3
//     -> inv_ack low in that cycle, afterwards lookups of A and B miss (no way
//        valid), rd_vld_bits_o == 0
// S3  the explicit inv alone (no missunit write): acked, invalidates its way only
// Pass token: WT_MEM_VLD_PASS. +oracle_negative flips the S2 expectation.
module tb_g6lc_wt_mem_vld;
  import ariane_pkg::*;
  import wt_cache_pkg::*;

  localparam config_pkg::cva6_cfg_t CVA6Cfg = build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);
  localparam int unsigned NumPorts = 3;
  localparam DCACHE_CL_IDX_WIDTH = $clog2(CVA6Cfg.DCACHE_NUM_WORDS);
  localparam type wbuffer_t = struct packed {
    logic [CVA6Cfg.DCACHE_TAG_WIDTH+(CVA6Cfg.DCACHE_INDEX_WIDTH-CVA6Cfg.XLEN_ALIGN_BYTES)-1:0] wtag;
    logic [CVA6Cfg.XLEN-1:0] data;
    logic [CVA6Cfg.DCACHE_USER_WIDTH-1:0] user;
    logic [(CVA6Cfg.XLEN/8)-1:0] dirty;
    logic [(CVA6Cfg.XLEN/8)-1:0] valid;
    logic [(CVA6Cfg.XLEN/8)-1:0] txblock;
    logic checked;
    logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0] hit_oh;
  };

  logic clk = 0, rst_n = 0;
  bit negative;

  // Every DUT input is driven from a register loaded at the clock edge from a
  // TB-side `d_*` copy, so the combinational outputs are sampled one settled
  // edge after the stimulus (the pattern of the other uncore leaves).
  logic [NumPorts-1:0][CVA6Cfg.DCACHE_TAG_WIDTH-1:0]     rd_tag = '0, d_rd_tag = '0;
  logic [NumPorts-1:0][DCACHE_CL_IDX_WIDTH-1:0]           rd_idx = '0, d_rd_idx = '0;
  logic [NumPorts-1:0][CVA6Cfg.DCACHE_OFFSET_WIDTH-1:0]  rd_off = '0;
  logic [NumPorts-1:0] rd_req = '0, d_rd_req = '0, rd_tag_only = '0, d_rd_tag_only = '0, rd_prio = '1, rd_ack;
  logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0] rd_vld_bits, rd_hit_oh;
  logic [CVA6Cfg.XLEN-1:0] rd_data;
  logic [CVA6Cfg.DCACHE_USER_WIDTH-1:0] rd_user;

  logic wr_cl_vld = 0, d_wr_cl_vld = 0, wr_cl_nc = 0;
  logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0] wr_cl_we = '0, d_wr_cl_we = '0, wr_vld_bits = '0, d_wr_vld_bits = '0;
  logic [CVA6Cfg.DCACHE_TAG_WIDTH-1:0] wr_cl_tag = '0, d_wr_cl_tag = '0;
  logic [DCACHE_CL_IDX_WIDTH-1:0] wr_cl_idx = '0;
  logic [CVA6Cfg.DCACHE_OFFSET_WIDTH-1:0] wr_cl_off = '0;
  logic [CVA6Cfg.DCACHE_LINE_WIDTH-1:0] wr_cl_data = '0;
  logic [CVA6Cfg.DCACHE_USER_LINE_WIDTH-1:0] wr_cl_user = '0;
  logic [CVA6Cfg.DCACHE_LINE_WIDTH/8-1:0] wr_cl_data_be = '0;

  logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0] wr_req = '0;
  logic wr_ack;
  logic [DCACHE_CL_IDX_WIDTH-1:0] wr_idx = '0;
  logic [CVA6Cfg.DCACHE_OFFSET_WIDTH-1:0] wr_off = '0;
  logic [CVA6Cfg.XLEN-1:0] wr_data = '0;
  logic [CVA6Cfg.DCACHE_USER_WIDTH-1:0] wr_user = '0;
  logic [(CVA6Cfg.XLEN/8)-1:0] wr_data_be = '0;

  logic inv_req = 0, d_inv_req = 0, inv_ack;
  logic [DCACHE_CL_IDX_WIDTH-1:0] inv_idx = '0;
  logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0] inv_way_oh = '0, d_inv_way_oh = '0, inv_vld_bits = '0, d_inv_vld_bits = '0;

  always_ff @(posedge clk) begin
    rd_tag      <= d_rd_tag;
    rd_idx      <= d_rd_idx;
    rd_req      <= d_rd_req;
    rd_tag_only <= d_rd_tag_only;
    wr_cl_vld   <= d_wr_cl_vld;
    wr_cl_we    <= d_wr_cl_we;
    wr_vld_bits <= d_wr_vld_bits;
    wr_cl_tag   <= d_wr_cl_tag;
    inv_req     <= d_inv_req;
    inv_way_oh  <= d_inv_way_oh;
    inv_vld_bits<= d_inv_vld_bits;
  end

  wbuffer_t [CVA6Cfg.WtDcacheWbufDepth-1:0] wbuffer_data = '0;
  wbuffer_t [CVA6Cfg.WtDcacheFixupDepth:0]  fixup_wbuffer = '0;
  logic wbuffer_fwd_hit;

  wt_dcache_mem #(
      .CVA6Cfg(CVA6Cfg),
      .DCACHE_CL_IDX_WIDTH(DCACHE_CL_IDX_WIDTH),
      .wbuffer_t(wbuffer_t),
      .NumPorts(NumPorts)
  ) dut (
      .clk_i(clk), .rst_ni(rst_n),
      .rd_tag_i(rd_tag), .rd_idx_i(rd_idx), .rd_off_i(rd_off), .rd_req_i(rd_req),
      .rd_tag_only_i(rd_tag_only), .rd_prio_i(rd_prio), .rd_ack_o(rd_ack),
      .rd_vld_bits_o(rd_vld_bits), .rd_hit_oh_o(rd_hit_oh), .rd_data_o(rd_data), .rd_user_o(rd_user),
      .wr_cl_vld_i(wr_cl_vld), .wr_cl_nc_i(wr_cl_nc), .wr_cl_we_i(wr_cl_we), .wr_cl_tag_i(wr_cl_tag),
      .wr_cl_idx_i(wr_cl_idx), .wr_cl_off_i(wr_cl_off), .wr_cl_data_i(wr_cl_data), .wr_cl_user_i(wr_cl_user),
      .wr_cl_data_be_i(wr_cl_data_be), .wr_vld_bits_i(wr_vld_bits),
      .wr_req_i(wr_req), .wr_ack_o(wr_ack), .wr_idx_i(wr_idx), .wr_off_i(wr_off), .wr_data_i(wr_data),
      .wr_user_i(wr_user), .wr_data_be_i(wr_data_be),
      .inv_req_i(inv_req), .inv_ack_o(inv_ack), .inv_idx_i(inv_idx), .inv_way_oh_i(inv_way_oh),
      .inv_vld_bits_i(inv_vld_bits),
      .wbuffer_data_i(wbuffer_data), .fixup_wbuffer_i(fixup_wbuffer), .wbuffer_fwd_hit_o(wbuffer_fwd_hit)
  );

  localparam logic [DCACHE_CL_IDX_WIDTH-1:0] IDX = DCACHE_CL_IDX_WIDTH'('h38);
  localparam logic [CVA6Cfg.DCACHE_TAG_WIDTH-1:0] TAG_A = CVA6Cfg.DCACHE_TAG_WIDTH'('h8fc8e);
  localparam logic [CVA6Cfg.DCACHE_TAG_WIDTH-1:0] TAG_B = CVA6Cfg.DCACHE_TAG_WIDTH'('h81887);

  task automatic tick; #2 clk = 1; #2 clk = 0; #2; endtask

  // the line write is presented for exactly one cycle (the cycle after tick #1)
  task automatic refill(input logic [CVA6Cfg.DCACHE_TAG_WIDTH-1:0] tag, input int way);
    wr_cl_idx = IDX; wr_cl_data = {CVA6Cfg.DCACHE_LINE_WIDTH/8{8'hA5}}; wr_cl_data_be = '1;
    d_wr_cl_vld = 1; d_wr_cl_we = '0; d_wr_cl_we[way] = 1; d_wr_vld_bits = '0; d_wr_vld_bits[way] = 1;
    d_wr_cl_tag = tag;
    tick();                                   // DUT sees the write this cycle
    d_wr_cl_vld = 0; d_wr_cl_we = '0; d_wr_vld_bits = '0;
    tick(); tick();
  endtask

  // tag-only lookup on port 1: index in cycle 1 (acked, SRAM read), tag in
  // cycle 2 -> the hit / valid vectors are sampled at the end of cycle 2
  task automatic lookup(input logic [CVA6Cfg.DCACHE_TAG_WIDTH-1:0] tag,
                        output logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0] hit,
                        output logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0] vld);
    d_rd_req[1] = 1; d_rd_tag_only[1] = 1; d_rd_idx[1] = IDX; d_rd_tag[1] = tag;
    tick();                                   // cycle 1: request visible
    #1; if (!rd_ack[1]) $fatal(1, "WT_MEM_VLD_LOOKUP_NOT_ACKED rd_req=%b rd_ack=%b wr_cl_vld=%b", rd_req, rd_ack, wr_cl_vld);
    d_rd_req[1] = 0;
    tick();                                   // cycle 2: tag compare on the registered read
    #1; hit = rd_hit_oh; vld = rd_vld_bits;
    d_rd_tag_only[1] = 0;
    tick();
  endtask

  logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0] hit, vld;

  initial begin
    negative = $test$plusargs("oracle_negative");
    #2; tick(); tick(); rst_n = 1; #2; tick();

    // S1: two ways resident
    refill(TAG_A, 0);
    refill(TAG_B, 1);
    lookup(TAG_A, hit, vld);
    if (hit != 8'h01 || vld != 8'h03) $fatal(1, "WT_MEM_VLD_S1_A hit=%h vld=%h", hit, vld);
    lookup(TAG_B, hit, vld);
    if (hit != 8'h02) $fatal(1, "WT_MEM_VLD_S1_B hit=%h", hit);

    // S2: all-ways invalidation at IDX with the missunit's tag TAG_A, while a
    // fixup inv_req for way 3 (inv_vld_bits = all current ways) is pending
    wr_cl_idx = IDX; wr_cl_data = '0; wr_cl_data_be = '0; inv_idx = IDX;
    d_wr_cl_vld = 1; d_wr_cl_we = '1; d_wr_vld_bits = '0; d_wr_cl_tag = TAG_A;
    d_inv_req = 1; d_inv_way_oh = 8'h08; d_inv_vld_bits = 8'hFF;
    tick();                                   // the coincidence cycle
    #1; if (inv_ack) $fatal(1, "WT_MEM_VLD_S2_INV_ACKED_UNDER_LINE_WRITE");
    d_wr_cl_vld = 0; d_wr_cl_we = '0; d_inv_req = 0;
    tick(); tick();
    lookup(TAG_A, hit, vld);
    if ((hit != 8'h00 || vld != 8'h00) != negative)
      $fatal(1, "WT_MEM_VLD_S2_FOREIGN_VALID hit=%h vld=%h (an invalidation validated ways with the missunit's tag)", hit, vld);
    lookup(TAG_B, hit, vld);
    if ((hit != 8'h00) != negative) $fatal(1, "WT_MEM_VLD_S2_B hit=%h", hit);

    // S3: the explicit invalidation alone invalidates exactly its way
    refill(TAG_A, 2);
    refill(TAG_B, 3);
    d_inv_req = 1; d_inv_way_oh = 8'h08; d_inv_vld_bits = 8'h0C;
    tick();
    #1; if (!inv_ack) $fatal(1, "WT_MEM_VLD_S3_INV_NOT_ACKED");
    d_inv_req = 0; tick(); tick();
    lookup(TAG_A, hit, vld);
    if (hit != 8'h04 || vld != 8'h04) $fatal(1, "WT_MEM_VLD_S3_A hit=%h vld=%h", hit, vld);
    lookup(TAG_B, hit, vld);
    if (hit != 8'h00) $fatal(1, "WT_MEM_VLD_S3_B hit=%h", hit);

    $display("WT_MEM_VLD_PASS");
    $finish;
  end
endmodule
