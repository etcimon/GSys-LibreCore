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
//   S4/S5 (T48 probes) a word whose tag check misses and whose line is
//       refilled before (S4) / after (S5) its ACK must still reach the array
//       (re-check after the refill, deferred write) -- both hold.
// Checks on the array write log: the last write that touches bytes [3:0] of W
// carries B's data (WT_WBUF_FIXUP_YOUNG_BYTES_KEPT); A's upper bytes are
// written by the fixup (WT_WBUF_FIXUP_OLD_BYTES_WRITTEN -- the queue is live,
// not just emptied); the fixup write carries no byte of B's mask
// (WT_WBUF_FIXUP_NO_SUPERSEDED_BYTE).
//   S6  (T37) the fixup-pass drift: FIFO full, the head's pass in flight with
//       its retire write held, a VOID ACK lands in the bypass slot -- the
//       pass must restart on the new selection; pre-fix it finished on the
//       bypass word with the head's hit vector (G6LC_MUT_FIXUP_SEL_DRIFT
//       trips the RTL's own `fixup pass acting on an entry other than the one
//       it tag-checked`; the TB's own-way checks are the second line).
//   S7  (T48, contract) queue and bypass full, a genuinely checked-MISS word
//       ACKed: it leaves the buffer at once (held, it deadlocks the loads
//       that refill the queue's lines -- the t55/t57 builds); safe only
//       because wt_dcache_mem no longer produces false misses (S5 of the
//       mem leaf).
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
  logic [CVA6Cfg.MEM_TID_WIDTH-1:0] miss_id, rtrn_id;
  logic rtrn_vld;
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
      .wr_cl_vld_i(wr_cl_vld), .wr_cl_idx_i(wr_cl_idx), .wr_cl_inv_i(1'b0),
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
  logic wbuf_check_en = 0, fixup_check_en = 0, line_present = 1;
  logic wr_cl_vld = 0;
  logic [DCACHE_CL_IDX_WIDTH-1:0] wr_cl_idx = '0;
  assign rd_ack = rd_req && (dut.fixup_rd_req ? fixup_check_en : wbuf_check_en);
  logic wr_ack_en = 1;                      // S6 holds the head's RETIRE write
  assign wr_ack = |wr_req && wr_ack_en;
  assign inv_ack = inv_req;
  // (folded so that the S6 words -- eight indices apart -- do not all share
  // way 0 with the head: the drifted invalidation must be visibly wrong)
  function automatic logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0] way_of_idx(input logic [DCACHE_CL_IDX_WIDTH-1:0] idx);
    return CVA6Cfg.DCACHE_SET_ASSOC'(1) << ((idx + (idx >> 3)) % CVA6Cfg.DCACHE_SET_ASSOC);
  endfunction
  // invalidation log (the fixup queue's full-queue fallback)
  typedef struct { logic [DCACHE_CL_IDX_WIDTH-1:0] idx; logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0] way; } ilog_t;
  ilog_t ilog[$];
  // array write log
  typedef struct { logic [CVA6Cfg.DCACHE_SET_ASSOC-1:0] way; logic [DCACHE_CL_IDX_WIDTH-1:0] idx;
                   logic [CVA6Cfg.DCACHE_OFFSET_WIDTH-1:0] off; logic [CVA6Cfg.XLEN-1:0] data;
                   logic [(CVA6Cfg.XLEN/8)-1:0] be; bit fixup; } wlog_t;
  wlog_t wlog[$];
  // the ACK of the oldest expired TX is presented combinationally, so
  // ack_delay = 0 means "one cycle after the TX was accepted" (the earliest
  // the wbuffer can see it: tx_stat is registered at the accept)
  always_comb begin
    rtrn_vld = 1'b0; rtrn_id = '0;
    for (int t = CVA6Cfg.DCACHE_MAX_TX - 1; t >= 0; t--)
      if (pend[t] && pend_cnt[t] == 0) begin rtrn_vld = 1'b1; rtrn_id = t[CVA6Cfg.MEM_TID_WIDTH-1:0]; end
  end
  always_ff @(posedge clk) begin
    // the line of index I lives in way way_of_idx(I), so a hit vector carried
    // from one word to another word's line is visibly the wrong way
    rd_hit_oh <= (rd_req && rd_ack && line_present) ? way_of_idx(rd_idx) : '0;
    for (int t = 0; t < CVA6Cfg.DCACHE_MAX_TX; t++) begin
      if (pend[t]) begin
        if (pend_cnt[t] == 0) begin
          if (rtrn_vld && rtrn_id == t[CVA6Cfg.MEM_TID_WIDTH-1:0]) pend[t] <= 0;
        end else pend_cnt[t] <= pend_cnt[t] - 1;
      end
    end
    if (miss_req && miss_ack) begin pend[miss_id] <= 1; pend_cnt[miss_id] <= ack_delay; end
    if (inv_req && inv_ack) begin
      ilog_t iv;
      iv.idx = inv_idx; iv.way = inv_way_oh;
      ilog.push_back(iv);
    end
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
  function automatic int inval_of(input logic [CVA6Cfg.PLEN-1:0] pa);
    int n = 0;
    foreach (ilog[i]) if (ilog[i].idx == pa[CVA6Cfg.DCACHE_INDEX_WIDTH-1:CVA6Cfg.DCACHE_OFFSET_WIDTH]) n++;
    return n;
  endfunction
  task automatic store_pa(input logic [CVA6Cfg.PLEN-1:0] pa, input logic [CVA6Cfg.XLEN-1:0] data,
                          input logic [(CVA6Cfg.XLEN/8)-1:0] be);
    req_in = '0; req_in.data_req = 1; req_in.data_we = 1; req_in.data_wdata = data; req_in.data_be = be;
    req_in.data_size = 2'b11;
    req_in.address_tag   = pa[CVA6Cfg.DCACHE_TAG_WIDTH+CVA6Cfg.DCACHE_INDEX_WIDTH-1:CVA6Cfg.DCACHE_INDEX_WIDTH];
    req_in.address_index = pa[CVA6Cfg.DCACHE_INDEX_WIDTH-1:0];
    #1;
    while (!req_out.data_gnt) tick();
    tick(); req_in = '0; #1;
  endtask
  task automatic store(input logic [CVA6Cfg.XLEN-1:0] data, input logic [(CVA6Cfg.XLEN/8)-1:0] be);
    store_pa(PA_W, data, be);
  endtask
  task automatic refill(input logic [CVA6Cfg.PLEN-1:0] pa);
    wr_cl_vld = 1; wr_cl_idx = pa[CVA6Cfg.DCACHE_INDEX_WIDTH-1:CVA6Cfg.DCACHE_OFFSET_WIDTH]; tick();
    wr_cl_vld = 0; wr_cl_idx = '0; #1;
  endtask
  function automatic int writes_of(input logic [CVA6Cfg.PLEN-1:0] pa, input logic [CVA6Cfg.XLEN-1:0] data);
    int n = 0;
    foreach (wlog[i])
      if (wlog[i].idx == pa[CVA6Cfg.DCACHE_INDEX_WIDTH-1:CVA6Cfg.DCACHE_OFFSET_WIDTH] &&
          wlog[i].off[CVA6Cfg.DCACHE_OFFSET_WIDTH-1:3] == pa[CVA6Cfg.DCACHE_OFFSET_WIDTH-1:3] &&
          wlog[i].data == data && wlog[i].be == '1) n++;
    return n;
  endfunction
  function automatic bit touches_low(input wlog_t w);
    return (w.idx == PA_W[CVA6Cfg.DCACHE_INDEX_WIDTH-1:CVA6Cfg.DCACHE_OFFSET_WIDTH]) &&
           (w.off[CVA6Cfg.DCACHE_OFFSET_WIDTH-1:3] == PA_W[CVA6Cfg.DCACHE_OFFSET_WIDTH-1:3]) && (|w.be[3:0]);
  endfunction

  // S6 words: distinct lines and indices, DRAM
  function automatic logic [CVA6Cfg.PLEN-1:0] s6_pa(input int k);
    return 56'h0000_0000_8010_0000 + 56'(k) * 56'h1110;
  endfunction
  function automatic logic [CVA6Cfg.XLEN-1:0] s6_data(input int k);
    return 64'h6600_0000_0000_0000 | 64'(k + 1) * 64'h0101_0101_0101;
  endfunction
  localparam logic [63:0] DATA_A = 64'hAAAA_AAAA_AAAA_AAAA;
  localparam logic [63:0] DATA_B = 64'h1111_1111_BBBB_BBBB;
  localparam logic [63:0] DATA_C = 64'hCCCC_CCCC_CCCC_CCCC;
  localparam logic [63:0] DATA_D = 64'hDDDD_DDDD_DDDD_DDDD;
  localparam logic [CVA6Cfg.PLEN-1:0] PA_C = 56'h0000_0000_8005_3c10;   // another line, another index
  localparam logic [CVA6Cfg.PLEN-1:0] PA_D = 56'h0000_0000_8006_4d18;
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

    // S4 (T48 probe): a word whose tag check MISSES, then a refill of its line
    // lands before the ACK -> the ACK must not be treated as "line absent":
    // the word has to reach the array (re-check after the refill, write)
    line_present = 0; wbuf_check_en = 1; fixup_check_en = 1; ack_delay = 8;
    store_pa(PA_C, DATA_C, 8'hff);
    repeat (4) tick();                   // checked: miss
    line_present = 1;
    refill(PA_C);                        // the line arrives (memory copy = pre-store)
    repeat (24) tick();                  // ACK, re-check, retire
    check(writes_of(PA_C, DATA_C) >= 1 && empty && dut.gen_fixup_queue.fixup_cnt == 0,
          "WT_WBUF_FIXUP_S4_MISS_REFILL_ACK_WRITTEN");

    // S5 (T48 probe): the ACK comes first (checked miss -> queued), the refill
    // later -> the queued word must be written once the line is present
    line_present = 0; ack_delay = 3;        // the ACK a cycle after the miss result: a checked-miss push
    store_pa(PA_D, DATA_D, 8'hff);
    repeat (10) tick();                  // checked miss, ACKed, queued, re-checked: miss, waits
    check(writes_of(PA_D, DATA_D) == 0 && dut.gen_fixup_queue.fixup_cnt == 1, "WT_WBUF_FIXUP_S5_QUEUED_WAITING");
    line_present = 1;
    refill(PA_D);
    repeat (24) tick();
    check(writes_of(PA_D, DATA_D) >= 1 && empty && dut.gen_fixup_queue.fixup_cnt == 0,
          "WT_WBUF_FIXUP_S5_ACK_REFILL_WRITTEN");

    // S6 (T37, the fixup-pass drift): the FIFO is full (FixupDepth VOID-ACKed
    // words of distinct lines, checks held), the head's pass is released and
    // its retire write held back, and one more VOID ACK lands in the BYPASS
    // slot while that pass is in flight. Pre-fix the pass's address followed
    // fixup_bypass_valid_q combinationally and finished on the bypass word
    // with the head's hit vector: the full-queue fallback invalidated the
    // head's WAY at the bypass word's INDEX and the bypass word was dropped
    // unwritten (G6LC_MUT_FIXUP_SEL_DRIFT); the fix restarts the pass on the
    // new selection. The arrival cycle is swept over the pass.
    for (int off = 0; off < 10; off++) begin
      // reset the DUT and the environment between rounds
      rst_n = 0; req_in = '0; wbuf_check_en = 0; fixup_check_en = 0; line_present = 1; wr_ack_en = 1;
      for (int t = 0; t < CVA6Cfg.DCACHE_MAX_TX; t++) begin pend[t] = 0; pend_cnt[t] = 0; end
      wlog.delete(); ilog.delete(); tick(); tick(); rst_n = 1; #2;
      ack_delay = 2;
      for (int k = 0; k < CVA6Cfg.WtDcacheFixupDepth; k++) begin
        store_pa(s6_pa(k), s6_data(k), 8'hff);
        repeat (4) tick();
      end
      repeat (8) tick();
      check(dut.gen_fixup_queue.fixup_cnt == CVA6Cfg.WtDcacheFixupDepth && !dut.gen_fixup_queue.fixup_bypass_valid_q,
            "WT_WBUF_FIXUP_S6_QUEUE_FULL");
      // release the head's pass; hold its RETIRE write (wr_ack low) so the
      // pass is in flight when the ninth word -- accepted after the pass
      // started, never tag-checked (its check gate stays shut), VOID-ACKed
      // `off` cycles later -- lands in the bypass slot; then let the write go
      fixup_check_en = 1; tick();              // PEND -> CHECK
      wr_ack_en = 0;
      ack_delay = off;
      store_pa(s6_pa(CVA6Cfg.WtDcacheFixupDepth), s6_data(CVA6Cfg.WtDcacheFixupDepth), 8'hff);
      repeat (off + 4) tick();                 // the VOID ACK lands (bypass) while RETIRE waits
      check(dut.gen_fixup_queue.fixup_bypass_valid_q, "WT_WBUF_FIXUP_S6_BYPASS_MID_PASS");
      wr_ack_en = 1;
      for (int c = 0; c < 40 * (CVA6Cfg.WtDcacheFixupDepth + 2); c++) begin
        tick();
        if ($test$plusargs("debug") && c < 60)
          $display("dbg off=%0d c=%0d st=%0d cnt=%0d byp=%b bypbe=%h dead=%b rd_req=%b ack=%b tocheck=%b wr=%b inv=%b empty=%b hit_q=%b",
                   off, c, dut.gen_fixup_queue.fixup_state_q, dut.gen_fixup_queue.fixup_cnt,
                   dut.gen_fixup_queue.fixup_bypass_valid_q, dut.gen_fixup_queue.fixup_bypass_q.be,
                   dut.gen_fixup_queue.fixup_active_dead, dut.fixup_rd_req, rd_ack, |dut.tocheck, |wr_req, inv_req, empty,
                   dut.gen_fixup_queue.fixup_hit_oh_q);
      end
      for (int k = 0; k < CVA6Cfg.WtDcacheFixupDepth; k++)
        if (writes_of(s6_pa(k), s6_data(k)) != 1) begin
          $display("  S6 off=%0d: word %0d written %0d times", off, k, writes_of(s6_pa(k), s6_data(k)));
          check(0, "WT_WBUF_FIXUP_S6_HEAD_WORD_WRITTEN");
        end
      // every array write and every fallback invalidation hit the way its
      // own line lives in (a pass that drifted onto the bypass word carries
      // the head's hit vector to the bypass word's index)
      foreach (wlog[i]) if (wlog[i].way != way_of_idx(wlog[i].idx)) begin
        $display("  S6 off=%0d: write idx=%h way=%b expected %b", off, wlog[i].idx, wlog[i].way, way_of_idx(wlog[i].idx));
        check(0, "WT_WBUF_FIXUP_S6_WRITE_OWN_WAY");
      end
      foreach (ilog[i]) if (ilog[i].way != way_of_idx(ilog[i].idx)) begin
        $display("  S6 off=%0d: inval idx=%h way=%b expected %b", off, ilog[i].idx, ilog[i].way, way_of_idx(ilog[i].idx));
        check(0, "WT_WBUF_FIXUP_S6_INVAL_OWN_WAY");
      end
      // the ninth word reached the array or had its line invalidated
      if (!(writes_of(s6_pa(CVA6Cfg.WtDcacheFixupDepth), s6_data(CVA6Cfg.WtDcacheFixupDepth)) == 1 ||
            inval_of(s6_pa(CVA6Cfg.WtDcacheFixupDepth)) >= 1)) begin
        $display("  S6 off=%0d: ninth word neither written nor invalidated (invals=%0d)", off, ilog.size());
        check(0, "WT_WBUF_FIXUP_S6_BYPASS_WORD_SETTLED");
      end
      check(dut.gen_fixup_queue.fixup_cnt == 0 && !dut.gen_fixup_queue.fixup_bypass_valid_q && empty,
            "WT_WBUF_FIXUP_S6_DRAINED");
    end

    // S7 (T48, the contract): queue AND bypass full, a word whose tag check
    // genuinely MISSED is ACKed -> it leaves the write buffer at once (not
    // held: a held store keeps the buffer non-empty while the loads that
    // would refill the queue's lines wait on that buffer -- the t55/t57
    // deadlock), the buffer is empty again and nothing is written for it.
    // This is safe only because a checked miss is genuine: wt_dcache_mem no
    // longer acknowledges a lookup in a valid-bit write cycle (S5 of
    // tb_g6lc_wt_mem_vld).
    rst_n = 0; req_in = '0; wbuf_check_en = 0; fixup_check_en = 0; line_present = 1; wr_ack_en = 1;
    for (int t = 0; t < CVA6Cfg.DCACHE_MAX_TX; t++) begin pend[t] = 0; pend_cnt[t] = 0; end
    wlog.delete(); ilog.delete(); tick(); tick(); rst_n = 1; #2;
    ack_delay = 2;
    for (int k = 0; k <= CVA6Cfg.WtDcacheFixupDepth; k++) begin   // Depth words + one for the bypass slot
      store_pa(s6_pa(k), s6_data(k), 8'hff);
      repeat (4) tick();
    end
    repeat (8) tick();
    check(dut.gen_fixup_queue.fixup_cnt == CVA6Cfg.WtDcacheFixupDepth && dut.gen_fixup_queue.fixup_bypass_valid_q,
          "WT_WBUF_FIXUP_S7_QUEUE_AND_BYPASS_FULL");
    line_present = 0; wbuf_check_en = 1; ack_delay = 6;
    store_pa(s6_pa(CVA6Cfg.WtDcacheFixupDepth + 1), s6_data(CVA6Cfg.WtDcacheFixupDepth + 1), 8'hff);
    repeat (16) tick();
    wbuf_check_en = 0;
    check(empty, "WT_WBUF_FIXUP_S7_CHECKED_MISS_NOT_HELD");
    check(writes_of(s6_pa(CVA6Cfg.WtDcacheFixupDepth + 1), s6_data(CVA6Cfg.WtDcacheFixupDepth + 1)) == 0, "WT_WBUF_FIXUP_S7_NOTHING_WRITTEN");
    line_present = 1; fixup_check_en = 1;
    repeat (40 * (CVA6Cfg.WtDcacheFixupDepth + 3)) tick();
    check(empty && dut.gen_fixup_queue.fixup_cnt == 0 && !dut.gen_fixup_queue.fixup_bypass_valid_q, "WT_WBUF_FIXUP_S7_DRAINED");

    if (negative) $fatal(1, "ORACLE_NEGATIVE forced");
    $display("WT_WBUF_FIXUP_PASS checked=%0d writes=%0d", checked, wlog.size());
    $finish;
  end
endmodule
