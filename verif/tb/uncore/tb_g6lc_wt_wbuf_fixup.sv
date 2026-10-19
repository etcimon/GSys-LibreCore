// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Copyright (c) 2026 Etienne Cimon
//
// T47 leaf: the SL-W fixup queue's deferred array write never puts older
// bytes back over a younger store to the same word.
//
// wt_dcache_wbuffer alone, with a scripted environment: memory ACKs a TX
// `ack_delay` cycles after it is accepted, the tag check hits way 0 (the line
// is present) one cycle after rd_ack, and the TB decides when the wbuffer's
// own tag checks and the fixup queue's checks may proceed (two gates on
// rd_ack), so the race is laid out cycle by cycle:
//   S1  store A (word W, 8 bytes 0xAA..) with its tag check held back -> its
//       ACK arrives unchecked (VOID) and the word enters the fixup queue
//   S2  store B (word W, low 4 bytes 0xBB..) is accepted while A's fixup entry
//       is pending; the wbuffer checks are released: B is checked (hit), its
//       TX is ACKed and its ACK-time write lands in the array
//   S3  the fixup check is released: A's entry retires. With the fix it writes
//       only the bytes B did not cover (0xf0); pre-fix it wrote all eight,
//       putting A's 0xAA.. back over B's bytes -- the L3 boot's
//       ret_from_exception restore of the previous trap frame (T47).
// Checks on the array write log: the last write that touches bytes [3:0] of W
// carries B's data (WT_WBUF_FIXUP_YOUNG_BYTES_KEPT); A's upper bytes are
// written by the fixup (WT_WBUF_FIXUP_OLD_BYTES_WRITTEN -- the queue is live,
// not just emptied); the fixup write carries no byte of B's mask
// (WT_WBUF_FIXUP_NO_SUPERSEDED_BYTE).
// Pass token: WT_WBUF_FIXUP_PASS. +oracle_negative flips the verdict.
// G6LC_MUT_FIXUP_KEEP_SUPERSEDED (the pre-fix queue) survives this shape:
// B's checked ACK matches the pending entry (fixup_match) and is coalesced
// into it, so even pre-fix the deferred write carried B's bytes -- the
// acceptance-time clearing is a second guard, and the L3's 36.3 s death
// (t47b/t49, gone on t51 and t52) is attributed to T46 and/or T47.
module tb_g6lc_wt_wbuf_fixup;
  import ariane_pkg::*;
  import wt_cache_pkg::*;

  localparam config_pkg::cva6_cfg_t CVA6Cfg = build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);
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
  localparam type dcache_req_i_t = struct packed {
    logic [CVA6Cfg.DCACHE_INDEX_WIDTH-1:0] address_index;
    logic [CVA6Cfg.DCACHE_TAG_WIDTH-1:0]   address_tag;
    logic [CVA6Cfg.XLEN-1:0]               data_wdata;
    logic [CVA6Cfg.DCACHE_USER_WIDTH-1:0]  data_wuser;
    logic                                  data_req;
    logic                                  data_we;
    logic [(CVA6Cfg.XLEN/8)-1:0]           data_be;
    logic [1:0]                            data_size;
    logic [CVA6Cfg.DcacheIdWidth-1:0]      data_id;
    logic                                  kill_req;
    logic                                  tag_valid;
    logic [7:0]                            cbo_op;
  };
  localparam type dcache_req_o_t = struct packed {
    logic                                  data_gnt;
    logic                                  data_rvalid;
    logic [CVA6Cfg.DcacheIdWidth-1:0]      data_rid;
    logic [CVA6Cfg.XLEN-1:0]               data_rdata;
    logic [CVA6Cfg.DCACHE_USER_WIDTH-1:0]  data_ruser;
  };

  logic clk = 0, rst_n = 0;
  bit negative;
  int checked = 0;

  // the word under test: a DRAM line, word offset 8
  localparam logic [CVA6Cfg.PLEN-1:0] PA_W = 56'h0000_0000_8004_2b08;

  dcache_req_i_t req_in = '0;
  dcache_req_o_t req_out;
  logic empty, not_ni;
  // miss unit
  logic miss_ack, miss_req, miss_we, miss_nc;
  logic [CVA6Cfg.PLEN-1:0] miss_paddr;
  logic [CVA6Cfg.XLEN-1:0] miss_wdata;
  logic [CVA6Cfg.DCACHE_USER_WIDTH-1:0] miss_wuser;
  logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0] miss_vld_bits;
  logic [2:0] miss_size;
  logic [CVA6Cfg.MEM_TID_WIDTH-1:0] miss_id, rtrn_id = '0;
  logic rtrn_vld = 0;
  // cache read port
  logic [CVA6Cfg.DCACHE_TAG_WIDTH-1:0] rd_tag;
  logic [DCACHE_CL_IDX_WIDTH-1:0] rd_idx;
  logic [CVA6Cfg.DCACHE_OFFSET_WIDTH-1:0] rd_off;
  logic rd_req, rd_tag_only, rd_ack;
  logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0] rd_hit_oh = '0;
  // cache word write port
  logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0] wr_req;
  logic wr_ack;
  logic [DCACHE_CL_IDX_WIDTH-1:0] wr_idx;
  logic [CVA6Cfg.DCACHE_OFFSET_WIDTH-1:0] wr_off;
  logic [CVA6Cfg.XLEN-1:0] wr_data;
  logic [(CVA6Cfg.XLEN/8)-1:0] wr_data_be;
  logic [CVA6Cfg.DCACHE_USER_WIDTH-1:0] wr_user;
  logic inv_req, inv_ack;
  logic [DCACHE_CL_IDX_WIDTH-1:0] inv_idx;
  logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0] inv_way_oh, inv_vld_bits;
  logic pm_void, pm_fw, pm_fi, pm_ff;
  wbuffer_t [CVA6Cfg.WtDcacheFixupDepth:0] fixup_wbuffer;
  wbuffer_t [CVA6Cfg.WtDcacheWbufDepth-1:0] wbuffer_data;
  logic [CVA6Cfg.DCACHE_MAX_TX-1:0][CVA6Cfg.PLEN-1:0] tx_paddr;
  logic [CVA6Cfg.DCACHE_MAX_TX-1:0] tx_vld;

  wt_dcache_wbuffer #(
      .CVA6Cfg(CVA6Cfg), .DCACHE_CL_IDX_WIDTH(DCACHE_CL_IDX_WIDTH),
      .dcache_req_i_t(dcache_req_i_t), .dcache_req_o_t(dcache_req_o_t), .wbuffer_t(wbuffer_t)
  ) dut (
      .clk_i(clk), .rst_ni(rst_n), .cache_en_i(1'b1), .empty_o(empty), .not_ni_o(not_ni),
      .req_port_i(req_in), .req_port_o(req_out),
      .miss_ack_i(miss_ack), .miss_paddr_o(miss_paddr), .miss_req_o(miss_req), .miss_we_o(miss_we),
      .miss_wdata_o(miss_wdata), .miss_wuser_o(miss_wuser), .miss_vld_bits_o(miss_vld_bits),
      .miss_nc_o(miss_nc), .miss_size_o(miss_size), .miss_id_o(miss_id),
      .miss_rtrn_vld_i(rtrn_vld), .miss_rtrn_id_i(rtrn_id),
      .rd_tag_o(rd_tag), .rd_idx_o(rd_idx), .rd_off_o(rd_off), .rd_req_o(rd_req), .rd_tag_only_o(rd_tag_only),
      .rd_ack_i(rd_ack), .rd_data_i('0), .rd_vld_bits_i(rd_hit_oh), .rd_hit_oh_i(rd_hit_oh),
      .wr_cl_vld_i(1'b0), .wr_cl_idx_i('0), .wr_cl_inv_i(1'b0),
      .wr_req_o(wr_req), .wr_ack_i(wr_ack), .wr_idx_o(wr_idx), .wr_off_o(wr_off), .wr_data_o(wr_data),
      .wr_data_be_o(wr_data_be), .wr_user_o(wr_user),
      .inv_req_o(inv_req), .inv_ack_i(inv_ack), .inv_idx_o(inv_idx), .inv_way_oh_o(inv_way_oh), .inv_vld_bits_o(inv_vld_bits),
      .pm_void_ack_o(pm_void), .pm_fixup_write_o(pm_fw), .pm_fixup_inval_o(pm_fi), .pm_fixup_full_o(pm_ff),
      .fixup_wbuffer_o(fixup_wbuffer), .wbuffer_data_o(wbuffer_data), .tx_paddr_o(tx_paddr), .tx_vld_o(tx_vld)
  );

  // ---- environment -------------------------------------------------------
  // memory: accept every TX, ACK it ack_delay cycles later (in order)
  int ack_delay = 2;
  assign miss_ack = miss_req;
  int pend_cnt[CVA6Cfg.DCACHE_MAX_TX];
  logic pend[CVA6Cfg.DCACHE_MAX_TX];
  // tag check: the TB gates the wbuffer's and the fixup queue's checks apart;
  // the line is present in way 0, the result is valid one cycle after the ack
  logic wbuf_check_en = 0, fixup_check_en = 0;
  assign rd_ack = rd_req && (dut.fixup_rd_req ? fixup_check_en : wbuf_check_en);
  assign wr_ack = |wr_req;
  assign inv_ack = inv_req;
  // array write log
  typedef struct { logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0] way; logic [DCACHE_CL_IDX_WIDTH-1:0] idx;
                   logic [CVA6Cfg.DCACHE_OFFSET_WIDTH-1:0] off; logic [CVA6Cfg.XLEN-1:0] data;
                   logic [(CVA6Cfg.XLEN/8)-1:0] be; bit fixup; } wlog_t;
  wlog_t wlog[$];
  always_ff @(posedge clk) begin
    rd_hit_oh <= (rd_req && rd_ack) ? {{(CVA6Cfg.DCACHE_SET_ASSOC-1){1'b0}}, 1'b1} : '0;
    rtrn_vld  <= 1'b0;
    for (int t = 0; t < CVA6Cfg.DCACHE_MAX_TX; t++) begin
      if (pend[t]) begin
        if (pend_cnt[t] == 0) begin
          pend[t] <= 0; rtrn_vld <= 1'b1; rtrn_id <= t[CVA6Cfg.MEM_TID_WIDTH-1:0];
        end else pend_cnt[t] <= pend_cnt[t] - 1;
      end
    end
    if (miss_req && miss_ack) begin pend[miss_id] <= 1; pend_cnt[miss_id] <= ack_delay; end
    if (|wr_req && wr_ack) begin
      wlog_t w;
      w.way = wr_req; w.idx = wr_idx; w.off = wr_off; w.data = wr_data; w.be = wr_data_be; w.fixup = dut.fixup_wr_req;
      wlog.push_back(w);
    end
  end

  task automatic tick;
    clk = 1; #2; clk = 0; #2;
  endtask
  task automatic check(input bit ok, input string tag);
    if (ok === negative) begin
      foreach (wlog[i]) $display("  wlog[%0d] way=%b idx=%h off=%h be=%h data=%h fixup=%0d", i, wlog[i].way, wlog[i].idx,
                                 wlog[i].off, wlog[i].be, wlog[i].data, wlog[i].fixup);
      $fatal(1, "%s", tag);
    end
    checked++;
  endtask
  task automatic store(input logic [CVA6Cfg.XLEN-1:0] data, input logic [(CVA6Cfg.XLEN/8)-1:0] be);
    req_in = '0; req_in.data_req = 1; req_in.data_we = 1; req_in.data_wdata = data; req_in.data_be = be;
    req_in.data_size = 2'b11;
    req_in.address_tag   = PA_W[CVA6Cfg.DCACHE_TAG_WIDTH+CVA6Cfg.DCACHE_INDEX_WIDTH-1:CVA6Cfg.DCACHE_INDEX_WIDTH];
    req_in.address_index = PA_W[CVA6Cfg.DCACHE_INDEX_WIDTH-1:0];
    #1;
    while (!req_out.data_gnt) tick();
    tick(); req_in = '0; #1;
  endtask
  function automatic bit touches_low(input wlog_t w);
    return (w.idx == PA_W[CVA6Cfg.DCACHE_INDEX_WIDTH-1:CVA6Cfg.DCACHE_OFFSET_WIDTH]) &&
           (w.off[CVA6Cfg.DCACHE_OFFSET_WIDTH-1:3] == PA_W[CVA6Cfg.DCACHE_OFFSET_WIDTH-1:3]) && (|w.be[3:0]);
  endfunction

  localparam logic [63:0] DATA_A = 64'hAAAA_AAAA_AAAA_AAAA;
  localparam logic [63:0] DATA_B = 64'h1111_1111_BBBB_BBBB;
  int last_low, fixup_idx;
  initial begin
    negative = $test$plusargs("oracle_negative");
    for (int t = 0; t < CVA6Cfg.DCACHE_MAX_TX; t++) begin pend[t] = 0; pend_cnt[t] = 0; end
    #2; tick(); rst_n = 1; #2;

    // S1: store A, tag check held back, ACK after 2 cycles -> VOID ACK -> fixup queue
    wbuf_check_en = 0; fixup_check_en = 0; ack_delay = 2;
    store(DATA_A, 8'hff);
    repeat (6) tick();
    check(pm_void || dut.gen_fixup_queue.fixup_cnt > 0 || dut.gen_fixup_queue.fixup_bypass_valid_q, "WT_WBUF_FIXUP_S1_VOID_ACK_QUEUED");
    check(wlog.size() == 0, "WT_WBUF_FIXUP_S1_NO_ARRAY_WRITE_YET");

    // S2: store B (low half) while A's entry is pending; then release the
    // wbuffer checks only: B is checked, ACKed and written
    ack_delay = 4;
    store(DATA_B, 8'h0f);
    wbuf_check_en = 1;
    repeat (12) tick();
    last_low = -1;
    foreach (wlog[i]) if (touches_low(wlog[i])) last_low = i;
    check(last_low >= 0 && wlog[last_low].data[31:0] == DATA_B[31:0] && !wlog[last_low].fixup,
          "WT_WBUF_FIXUP_S2_YOUNG_WRITTEN");

    // S3: release the fixup check: A's entry retires after B's write
    fixup_check_en = 1;
    repeat (12) tick();
    fixup_idx = -1;
    foreach (wlog[i]) if (wlog[i].fixup) fixup_idx = i;
    check(fixup_idx >= 0 && wlog[fixup_idx].data[63:32] == DATA_A[63:32] && (|wlog[fixup_idx].be[7:4]),
          "WT_WBUF_FIXUP_OLD_BYTES_WRITTEN");
    // the fixup write may still carry bytes [3:0] -- only as B's data (the
    // queue coalesces a younger ACK into the pending entry), never as A's
    check(fixup_idx >= 0 && (wlog[fixup_idx].be[3:0] == 4'h0 || wlog[fixup_idx].data[31:0] == DATA_B[31:0]),
          "WT_WBUF_FIXUP_NO_SUPERSEDED_BYTE");
    last_low = -1;
    foreach (wlog[i]) if (touches_low(wlog[i])) last_low = i;
    check(last_low >= 0 && wlog[last_low].data[31:0] == DATA_B[31:0], "WT_WBUF_FIXUP_YOUNG_BYTES_KEPT");
    check(empty && dut.gen_fixup_queue.fixup_cnt == 0 && !dut.gen_fixup_queue.fixup_bypass_valid_q, "WT_WBUF_FIXUP_DRAINED");

    if (negative) $fatal(1, "ORACLE_NEGATIVE forced");
    $display("WT_WBUF_FIXUP_PASS checked=%0d writes=%0d", checked, wlog.size());
    $finish;
  end
endmodule
