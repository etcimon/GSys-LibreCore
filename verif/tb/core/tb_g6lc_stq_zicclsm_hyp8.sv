// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// Isolated mutation-checked leaf TB for hyp8 `store_buffer` multi-beat Zicclsm
// store commit (`RC5`):
//   A word-wrapping store (trans_id=T) is split by g6lc_zicclsm into beat0 and
//   beat1, both pushed into store_buffer's speculative queue with trans_id=T,
//   while commit_stage pulses commit_i ONCE for trans_id=T.
//   Without multi-beat commit drain + equal-tid age ordering:
//     - stb_insert marks beat1 older than beat0 (wrong memory order / assert)
//     - stb_commit pops only 1 beat, stranding the other beat with stale tid=T
//     - under MixCommit (NrHarts>1, hyp8-mc), the next store T+1 hits permanent
//       head_mismatch_o=1 -> commit_ready_o=0 -> commit deadlock!
//     - under flush_i coincident with commit_i, the stranded beat is dropped!
`timescale 1ns / 1ps

module tb_g6lc_stq_zicclsm_hyp8
  import g6lc_core_pkg::*;
;
  localparam config_pkg::g6lc_cfg_t CFG = build_config_pkg::build_config(
      g6lc_config_pkg::g6lc_cfg);
  localparam g6lc_hyp_pkg::g6lc_hyp_cfg_t HYP = g6lc_config_pkg::HypCfg;
  localparam int unsigned TID_W = CFG.TRANS_ID_BITS;
  localparam int unsigned HID_W = $clog2(CFG.NrHarts > 1 ? CFG.NrHarts : 2);
  localparam int unsigned TAG_W = (CFG.NrLoadBufEntries > 1) ? $clog2(CFG.NrLoadBufEntries) : 1;
  typedef logic [7:0] cbo_t;

  typedef struct packed {
    logic [CFG.DCACHE_INDEX_WIDTH-1:0] address_index;
    logic [CFG.DCACHE_TAG_WIDTH-1:0]   address_tag;
    logic [CFG.XLEN-1:0]               data_wdata;
    logic [CFG.DCACHE_USER_WIDTH-1:0]  data_wuser;
    logic                              data_req;
    logic                              data_we;
    logic [(CFG.XLEN/8)-1:0]           data_be;
    logic [1:0]                        data_size;
    logic [CFG.DcacheIdWidth-1:0]      data_id;
    logic                              kill_req;
    logic                              tag_valid;
    cbo_t                              cbo_op;
    logic [2:0]                        data_prot;
  } dcache_req_i_t;

  typedef struct packed {
    logic                              data_gnt;
    logic                              data_rvalid;
    logic [CFG.DcacheIdWidth-1:0]      data_rid;
    logic [CFG.XLEN-1:0]               data_rdata;
    logic [CFG.DCACHE_USER_WIDTH-1:0]  data_ruser;
  } dcache_req_o_t;

  typedef struct packed {
    logic                 valid;
    logic [CFG.PLEN-1:0]  pa;
    logic [1:0]           size;
    logic [TID_W-1:0]     tid;
    logic [HID_W-1:0]     hart;
    logic [TAG_W-1:0]     tag;
  } fwd_req_t;

  typedef struct packed {
    logic                     valid;
    logic [CFG.XLEN-1:0]      data;
    logic [(CFG.XLEN/8)-1:0]  be;
    logic                     forward_possible;
    logic [TAG_W-1:0]         tag;
  } fwd_rsp_t;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic rst_n = 1'b0, flush = 1'b0, commit = 1'b0, valid = 1'b0;
  logic [CFG.NR_SB_ENTRIES-1:0] cancel = '0, sb_live = '1;
  logic [TID_W-1:0] tid = '0, oldest = '0, commit_tid = '0;
  logic [CFG.PLEN-1:0] paddr = '0;
  logic [CFG.XLEN-1:0] data = '0;
  logic [(CFG.XLEN/8)-1:0] be = '0;
  logic [1:0] dsize = 2'b11;
  logic no_st_pending, empty, po_match, po_spec, fwd_valid, commit_ready, ready;
  logic [CFG.XLEN-1:0] fwd_data;
  logic [(CFG.XLEN/8)-1:0] fwd_be;
  logic [CFG.PLEN-1:0] rvfi_paddr, rvfi_st_paddr;
  logic rvfi_st_v;
  logic [TID_W-1:0] rvfi_st_tid;
  fwd_req_t fwd_req = '0;
  fwd_rsp_t fwd_rsp;
  dcache_req_o_t req_in = '0;
  dcache_req_i_t req_out;

  store_buffer #(
      .G6LCCfg       (CFG),
      .HypCfg        (HYP),
      .dcache_req_i_t(dcache_req_i_t),
      .dcache_req_o_t(dcache_req_o_t),
      .cbo_t         (cbo_t)
  ) dut (
      .clk_i                  (clk),
      .rst_ni                 (rst_n),
      .flush_i                (flush),
      .cancelled_mask_i       (cancel),
      .sb_live_i              (sb_live),
      .stall_st_pending_i     (1'b0),
      .no_st_pending_o        (no_st_pending),
      .store_buffer_empty_o   (empty),
      .page_offset_i          ('0),
      .load_paddr_i           ('0),
      .load_paddr_valid_i     (1'b0),
      .load_trans_id_i        ('0),
      .commit_trans_id_i      (commit_tid),
      .oldest_live_tid_i      (oldest),
      .head_phys_pending_i    (1'b0),
      .load_hart_i            ('0),
      .dcache_wbuffer_empty_i (1'b1),
      .page_offset_matches_o  (po_match),
      .page_offset_spec_only_o(po_spec),
      .st_fwd_valid_o         (fwd_valid),
      .st_fwd_data_o          (fwd_data),
      .st_fwd_be_o            (fwd_be),
      .fwd_req_i              (fwd_req),
      .fwd_rsp_o              (fwd_rsp),
      .commit_i               (commit),
      .commit_ready_o         (commit_ready),
      .ready_o                (ready),
      .valid_i                (valid),
      .valid_without_flush_i  (valid),
      .paddr_i                (paddr),
      .trans_id_i             (tid),
      .st_hart_i              ('0),
      .rvfi_mem_paddr_o       (rvfi_paddr),
      .rvfi_st_push_valid_o   (rvfi_st_v),
      .rvfi_st_push_tid_o     (rvfi_st_tid),
      .rvfi_st_push_paddr_o   (rvfi_st_paddr),
      .data_i                 (data),
      .be_i                   (be),
      .data_size_i            (dsize),
      .cbo_op_i               (cbo_t'(CBO_NONE)),
      .data_prot_i            ('0),
      .storamic_resync_i      (1'b0),
      .req_port_i             (req_in),
      .req_port_o             (req_out)
  );

  // Record every D$ store accepted
  int unsigned wr_n = 0;
  logic [CFG.PLEN-1:0] wr_pa [0:15];
  logic [7:0]          wr_be [0:15];
  logic [63:0]         wr_da [0:15];

  always @(posedge clk) begin
    if (rst_n && req_out.data_req && req_in.data_gnt) begin
      wr_pa[wr_n] <= {req_out.address_tag, req_out.address_index};
      wr_be[wr_n] <= req_out.data_be;
      wr_da[wr_n] <= req_out.data_wdata;
      wr_n        <= wr_n + 1;
    end
  end

  task automatic tick();
    @(posedge clk); #1;
  endtask

  task automatic push_st(
      input logic [CFG.PLEN-1:0] pa,
      input logic [63:0]         da,
      input logic [7:0]          b,
      input logic [TID_W-1:0]    t
  );
    while (!ready) tick();
    valid = 1'b1; paddr = pa; data = da; be = b; tid = t; dsize = 2'b11;
    tick();
    valid = 1'b0;
  endtask

  task automatic do_commit(
      input logic [TID_W-1:0] t,
      input logic             with_flush = 1'b0
  );
    int w = 0;
    commit_tid = t;
    #1;
    while (!commit_ready) begin
      tick();
      w++;
      if (w > 40)
        $fatal(1, "STQ_ZICCLSM_COMMIT_DEADLOCK tid=%0d commit_ready stuck 0 (wr_n=%0d)", t, wr_n);
    end
    commit = 1'b1; flush = with_flush;
    tick();
    commit = 1'b0; flush = 1'b0;
  endtask

  bit oracle_neg;

  initial begin
    oracle_neg = $test$plusargs("oracle_negative");
    req_in.data_gnt = 1'b1;
    rst_n = 1'b0;
    repeat (4) tick();
    rst_n = 1'b1;
    tick();

    // =========================================================================
    // S1: Two-beat wrapping store tid=5 + younger store tid=6.
    //     Commit tid=5 ONCE, then commit tid=6 ONCE.
    //     Both beats of tid=5 MUST drain in order (beat0 then beat1), and
    //     tid=6 MUST NOT hit head_mismatch deadlock!
    // =========================================================================
    oldest = TID_W'(5);
    push_st(CFG.PLEN'(64'h8000_1005), 64'h3322_1100_0000_0000, 8'he0, TID_W'(5)); // beat0
    push_st(CFG.PLEN'(64'h8000_1008), 64'h0000_0000_0000_0044, 8'h01, TID_W'(5)); // beat1
    push_st(CFG.PLEN'(64'h8000_1020), 64'hdead_beef_cafe_babe, 8'hff, TID_W'(6)); // younger
    repeat (2) tick();

    do_commit(TID_W'(5));
    oldest = TID_W'(6);
    do_commit(TID_W'(6));
    oldest = TID_W'(7);
    repeat (10) tick();

    if (wr_n !== 3)
      $fatal(1, "STQ_ZICCLSM_COMMIT_LOST S1 expected 3 writes, got %0d", wr_n);
    if (wr_pa[0] !== CFG.PLEN'(64'h8000_1005) || wr_be[0] !== 8'he0)
      $fatal(1, "STQ_ZICCLSM_ORDER S1 wr[0] pa=%h be=%h (want 80001005/e0)", wr_pa[0], wr_be[0]);
    if (wr_pa[1] !== CFG.PLEN'(64'h8000_1008) || wr_be[1] !== 8'h01)
      $fatal(1, "STQ_ZICCLSM_ORDER S1 wr[1] pa=%h be=%h (want 80001008/01)", wr_pa[1], wr_be[1]);
    if (wr_pa[2] !== CFG.PLEN'(64'h8000_1020) || wr_be[2] !== 8'hff)
      $fatal(1, "STQ_ZICCLSM_ORDER S1 wr[2] pa=%h be=%h (want 80001020/ff)", wr_pa[2], wr_be[2]);
    if (!empty)
      $fatal(1, "STQ_ZICCLSM_LEAK S1 store_buffer not empty after commits");

    // =========================================================================
    // S2: Wrapping store tid=7 committed on SAME cycle as flush_i (with
    //     younger speculative tid=8 that must be dropped).
    //     BOTH beat0 AND beat1 of tid=7 MUST survive flush and reach D$!
    // =========================================================================
    push_st(CFG.PLEN'(64'h8000_2005), 64'h7766_5500_0000_0000, 8'he0, TID_W'(7)); // beat0
    push_st(CFG.PLEN'(64'h8000_2008), 64'h0000_0000_0000_0088, 8'h01, TID_W'(7)); // beat1
    push_st(CFG.PLEN'(64'h8000_2040), 64'hbaad_f00d_baad_f00d, 8'hff, TID_W'(8)); // drop!
    repeat (2) tick();

    do_commit(TID_W'(7), 1'b1); // commit tid=7 + flush_i!
    oldest = TID_W'(9);
    repeat (10) tick();

    if (wr_n !== 5)
      $fatal(1, "STQ_ZICCLSM_COMMIT_LOST S2 expected 5 total writes, got %0d", wr_n);
    if (wr_pa[3] !== CFG.PLEN'(64'h8000_2005) || wr_pa[4] !== CFG.PLEN'(64'h8000_2008))
      $fatal(1, "STQ_ZICCLSM_FLUSH S2 wrong writes pa3=%h pa4=%h", wr_pa[3], wr_pa[4]);
    if (!empty)
      $fatal(1, "STQ_ZICCLSM_LEAK S2 store_buffer not empty after commit+flush");

    // =========================================================================
    // S3 (RC5b): beat0 is already installed in spec_valid_q while beat1 arrives
    //            on valid_i (NrStorePipeRegs==0 race). commit_ready_o MUST stay
    //            0 while beat1 is on valid_i AND while beat1 is in S1!
    // =========================================================================
    push_st(CFG.PLEN'(64'h8000_3005), 64'h6677_8800_0000_0000, 8'he0, TID_W'(9)); // beat0
    repeat (2) tick(); // beat0 now installed in spec_valid_q
    commit_tid = TID_W'(9);
    valid = 1'b1; paddr = CFG.PLEN'(64'h8000_3008); data = 64'h0000_0011_2233_4455;
    be = 8'h1f; tid = TID_W'(9); dsize = 2'b11;
    #1;
    if (commit_ready)
      $fatal(1, "STQ_ZICCLSM_S3_PREMATURE commit_ready=1 while beat1 arriving on valid_i!");
    tick(); // beat1 enters S1
    valid = 1'b0;
    #1;
    if (commit_ready)
      $fatal(1, "STQ_ZICCLSM_S3_PREMATURE commit_ready=1 while beat1 staged in S1!");
    tick(); // beat1 installs in spec_valid_q
    do_commit(TID_W'(9), 1'b1); // commit + flush!
    oldest = TID_W'(10);
    repeat (10) tick();
    if (wr_n !== 7 || wr_pa[5] !== CFG.PLEN'(64'h8000_3005) || wr_pa[6] !== CFG.PLEN'(64'h8000_3008))
      $fatal(1, "STQ_ZICCLSM_S3_LOST expected 7 writes with 3005/3008, got wr_n=%0d pa5=%h pa6=%h",
             wr_n, wr_pa[5], wr_pa[6]);
    if (!empty)
      $fatal(1, "STQ_ZICCLSM_LEAK S3 store_buffer not empty");

    if (oracle_neg && (wr_n < 99))
      $fatal(1, "STQ_ZICCLSM_COMMIT_DEADLOCK oracle_negative wr_n=%0d", wr_n);

    $display("PASS tb_g6lc_stq_zicclsm_hyp8 wr_n=%0d", wr_n);
    $finish;
  end
endmodule
