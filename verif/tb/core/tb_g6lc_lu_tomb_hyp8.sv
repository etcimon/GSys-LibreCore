// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Isolated hyp8 load_unit leaf: parallel tombstone drain for ldbuf_full relief.
// Instantiates real hyp8 load_unit (Hyp8, NrLoadBufEntries>=2) and proves:
//   S1. Concurrent publish + tombstone drain: fill 2 ldbuf slots (slot 0 live
//       load, slot 1 cancelled tombstone), return both D$ responses; on the
//       cycle slot 0 publishes (a_data=1), slot 1's tombstone ALSO frees in
//       the same cycle (ldbuf_valid_q drops to 0 immediately instead of
//       stalling ldbuf_full for an extra cycle).
//   S2. Simultaneous multi-tombstone drain: fill 2 ldbuf slots, flush both,
//       return both D$ responses -> BOTH tombstones free in 1 single cycle!
//
// Review mutation (must fail):
//   -DG6LC_MUT_LU_SERIAL_TOMB -> S1 stalls tombstone behind a_data (fails
//                                S1_CONCURRENT_TOMB_DRAIN)
//
// PASS token: PASS tb_g6lc_lu_tomb_hyp8
`include "g6lc_core_types.svh"

module tb_g6lc_lu_tomb_hyp8;
  import g6lc_core_pkg::*;

  localparam config_pkg::g6lc_cfg_t C =
      build_config_pkg::build_config(g6lc_config_pkg::g6lc_cfg);
  localparam g6lc_hyp_pkg::g6lc_hyp_cfg_t H = g6lc_hyp_pkg::Hyp8;
  localparam int unsigned NLD   = C.NrLoadBufEntries;
  localparam int unsigned TAG_W = (NLD > 1) ? $clog2(NLD) : 1;
  localparam int unsigned HID_W = $clog2(C.NrHarts > 1 ? C.NrHarts : 2);

  typedef `G6LC_EXCEPTION_T(C) exception_t;
  typedef struct packed {
    logic                       valid;
    logic [C.VLEN-1:0]          vaddr;
    logic [31:0]                tinst;
    logic                       hs_ld_st_inst;
    logic                       hlvx_inst;
    logic                       overflow;
    logic                       g_overflow;
    logic [C.XLEN-1:0]          data;
    logic [C.XLEN-1:0]          data_cmp;
    logic [C.XLEN-1:0]          data_hi;
    logic [C.XLEN-1:0]          data_cmp_hi;
    logic [(C.XLEN/8)-1:0]      be;
    fu_t                        fu;
    fu_op                       operation;
    logic [C.TRANS_ID_BITS-1:0] trans_id;
    logic [HID_W-1:0]           hart;
    logic                       is_speculative_load;
    logic                       is_speculative_load_miss;
    logic [2:0]                 data_prot;
  } lsu_ctrl_t;
  typedef struct packed {
    logic [C.DCACHE_INDEX_WIDTH-1:0] address_index;
    logic [C.DCACHE_TAG_WIDTH-1:0]   address_tag;
    logic [C.XLEN-1:0]               data_wdata;
    logic [C.DCACHE_USER_WIDTH-1:0]  data_wuser;
    logic                            data_req;
    logic                            data_we;
    logic [(C.XLEN/8)-1:0]           data_be;
    logic [1:0]                      data_size;
    logic [C.DcacheIdWidth-1:0]      data_id;
    logic                            kill_req;
    logic                            tag_valid;
    logic [7:0]                      cbo_op;
    logic [2:0]                      data_prot;
  } dcache_req_i_t;
  typedef struct packed {
    logic                            data_gnt;
    logic                            data_rvalid;
    logic [C.DcacheIdWidth-1:0]      data_rid;
    logic [C.XLEN-1:0]               data_rdata;
    logic [C.DCACHE_USER_WIDTH-1:0]  data_ruser;
  } dcache_req_o_t;
  typedef struct packed {
    logic                       valid;
    logic [C.PLEN-1:0]          pa;
    logic [1:0]                 size;
    logic [C.TRANS_ID_BITS-1:0] tid;
    logic [HID_W-1:0]           hart;
    logic [TAG_W-1:0]           tag;
  } fwd_req_t;
  typedef struct packed {
    logic                       valid;
    logic [C.XLEN-1:0]          data;
    logic [(C.XLEN/8)-1:0]      be;
    logic                       forward_possible;
    logic [TAG_W-1:0]           tag;
  } fwd_rsp_t;

  logic clk = 0, rst_n = 0;
  int checked = 0;
  always #5 clk = ~clk;
  task tick(); @(posedge clk); #1; endtask
  task check(input logic cond, input string name);
    checked++;
    if (!cond) begin
      $display("FAIL %s", name);
      $fatal(1, "tb_g6lc_lu_tomb_hyp8");
    end
  endtask

  logic                             flush = 0, valid = 0, pop_ld, valid_o;
  logic [C.NR_SB_ENTRIES-1:0]       cancel = '0, ld_checked = '1;
  lsu_ctrl_t                        lsu_ctrl = '0;
  logic [C.TRANS_ID_BITS-1:0]       trans_id_o, commit_tid = '0;
  logic [C.XLEN-1:0]                result_o;
  exception_t                       ex_o, ex_i = '0;
  dcache_req_i_t                    req_out;
  dcache_req_o_t                    req_in = '0;
  fwd_req_t                         fwd_req;
  fwd_rsp_t                         fwd_rsp = '0;

  // 1-cycle fwd_rsp responder so fwd_seen_q resolves cleanly for every issued load
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      fwd_rsp <= '0;
    end else begin
      fwd_rsp <= '{valid: fwd_req.valid, data: '0, be: '0,
                   forward_possible: 1'b0, tag: fwd_req.tag};
    end
  end

  load_unit #(
      .G6LCCfg       (C),
      .HypCfg        (H),
      .dcache_req_i_t(dcache_req_i_t),
      .dcache_req_o_t(dcache_req_o_t),
      .exception_t   (exception_t),
      .lsu_ctrl_t    (lsu_ctrl_t)
  ) dut (
      .clk_i                  (clk),
      .rst_ni                 (rst_n),
      .flush_i                (flush),
      .cancelled_mask_i       (cancel),
      .valid_i                (valid),
      .lsu_ctrl_i             (lsu_ctrl),
      .pop_ld_o               (pop_ld),
      .valid_o                (valid_o),
      .trans_id_o             (trans_id_o),
      .result_o               (result_o),
      .ex_o                   (ex_o),
      .mbe_i                  (1'b0),
      .translation_req_o      (),
      .vaddr_o                (),
      .tinst_o                (),
      .hs_ld_st_inst_o        (),
      .hlvx_inst_o            (),
      .paddr_i                (C.PLEN'(64'h8000_1000)),
      .ex_i                   (ex_i),
      .ex_ptw_i               (1'b0),
      .dtlb_hit_i             (1'b1),
      .dtlb_ppn_i             (C.PPNW'(44'h80001)),
      .page_offset_o          (),
      .load_paddr_o           (),
      .load_paddr_valid_o     (),
      .load_trans_id_o        (),
      .load_hart_o            (),
      .page_offset_matches_i  (1'b0),
      .page_offset_spec_only_i(1'b0),
      .lu_replay_o            (),
      .lu_replay_id_o         (),
      .store_buffer_empty_i   (1'b1),
      .no_st_pending_i        (1'b1),
      .st_fwd_valid_i         (1'b0),
      .st_fwd_data_i          ('0),
      .st_fwd_be_i            ('0),
      .commit_tran_id_i       (commit_tid),
      .req_port_i             (req_in),
      .req_port_o             (req_out),
      .dcache_wbuffer_not_ni_i(1'b1),
      .dcache_wbuffer_empty_i (1'b1),
      .phys_valid_o           (),
      .phys_addr_o            (),
      .phys_id_o              (),
      .phys_hart_o            (),
      .phys_size_o            (),
      .ld_checked_i           (ld_checked),
      .fwd_req_o              (fwd_req),
      .fwd_rsp_i              (fwd_rsp),
      .replay_o               (),
      .replay_tid_o           ()
  );

  task automatic issue_ld(input logic [C.TRANS_ID_BITS-1:0] tid, input logic [63:0] va);
    lsu_ctrl = '0;
    lsu_ctrl.valid     = 1'b1;
    lsu_ctrl.vaddr     = va;
    lsu_ctrl.fu        = LOAD;
    lsu_ctrl.operation = LD;
    lsu_ctrl.be        = 8'hff;
    lsu_ctrl.trans_id  = tid;
    commit_tid         = tid;
    valid              = 1'b1;
    req_in             = '{data_gnt: 1'b1, default: '0};
    #1;
    check(req_out.data_req === 1'b1 && pop_ld === 1'b1, "ISSUE_GNT");
    tick();
    valid  = 1'b0;
    req_in = '0;
  endtask

  initial begin
    repeat (3) tick();
    rst_n = 1'b1;
    repeat (2) tick();

    // ---- S1: Concurrent publish (slot 0) + tombstone drain (slot 1) ----
    // Hold ld_checked[1]=0 so slot 0 waits until BOTH D$ responses arrive.
    ld_checked = '0;
    issue_ld('d1, 64'h8000_1000);  // slot 0
    issue_ld('d2, 64'h8000_1008);  // slot 1
    // Cancel slot 1 (tid=2) -> tombstoned
    cancel = '0;
    cancel[2] = 1'b1;
    tick();
    cancel = '0;
    check(dut.ldbuf_valid_q[1:0] === 2'b11, "S1_BOTH_VALID");
    check(dut.ldbuf_flushed_q[1:0] === 2'b10, "S1_SLOT1_TOMB");

    // Return D$ response for slot 0 (tid=1), then slot 1 (tid=2) while slot 0 waits on ld_checked
    req_in = '{data_rvalid: 1'b1, data_rid: 'd0, data_rdata: 64'hCAFE_BABE_1111_2222, default: '0};
    tick();
    req_in = '{data_rvalid: 1'b1, data_rid: 'd1, data_rdata: 64'hDEAD_BEEF_3333_4444, default: '0};
    tick();
    req_in = '0;
    // Now BOTH rpend_q[1:0]==2'b11; release ld_checked[1]=1 so slot 0 publishes on THIS cycle!
    // Under parallel tombstone drain, slot 0 publishes AND slot 1 drains on the SAME cycle!
    ld_checked = '1;
    #1;
    check(valid_o === 1'b1 && trans_id_o === 'd1 && result_o === 64'hCAFE_BABE_1111_2222, "S1_SLOT0_PUB");
    tick();
    #1;
    check(dut.ldbuf_valid_q[1:0] === 2'b00, "S1_CONCURRENT_TOMB_DRAIN");

    // ---- S2: Two ready tombstones drain together in 1 single cycle ----
    ld_checked = '0;
    issue_ld('d3, 64'h8000_1010);  // slot 0
    issue_ld('d4, 64'h8000_1018);  // slot 1
    // Return slot 0 response while live (held by ld_checked=0), then return slot 1 response
    req_in = '{data_rvalid: 1'b1, data_rid: 'd0, data_rdata: 64'h1, default: '0};
    tick();
    req_in = '{data_rvalid: 1'b1, data_rid: 'd1, data_rdata: 64'h2, default: '0};
    tick();
    req_in = '0;
    // Flush both -> both slots become ready tombstones simultaneously (rpend=11, flushed=11)
    flush = 1'b1;
    tick();
    flush = 1'b0;
    check(dut.ldbuf_valid_q[1:0] === 2'b11 && dut.ldbuf_flushed_q[1:0] === 2'b11, "S2_TWO_TOMBS_ARMED");
    // ONE tick must drain BOTH tombstones simultaneously!
    tick();
    #1;
    check(dut.ldbuf_valid_q[1:0] === 2'b00, "S2_DUAL_TOMB_DRAIN");

    // ---- S3: Misaligned tombstone drained concurrently with aligned publish, then slot reused ----
    // Seam regression: mis_trk_q[1] must clear on parallel ldbuf_pop_oh[1] so
    // a subsequent aligned load reusing slot 1 never false-fires misaligned_entry_excepts.
    ld_checked = '0;
    issue_ld('d5, 64'h8000_1000);  // slot 0: aligned LD
    issue_ld('d6, 64'h8000_1003);  // slot 1: misaligned LD (sets mis_trk_q[1]=1)
    cancel = '0;
    cancel[6] = 1'b1;              // cancel misaligned slot 1
    tick();
    cancel = '0;
    req_in = '{data_rvalid: 1'b1, data_rid: 'd0, data_rdata: 64'hAAAA_BBBB, default: '0};
    tick();
    req_in = '{data_rvalid: 1'b1, data_rid: 'd1, data_rdata: 64'hCCCC_DDDD, default: '0};
    tick();
    req_in = '0;
    ld_checked = '1;               // slot 0 publishes (a_data=1) while slot 1 drains in parallel!
    tick();
    #1;
    check(dut.ldbuf_valid_q[1:0] === 2'b00, "S3_MIS_TOMB_DRAINED");
    // Now reuse slot 0 and slot 1 with aligned loads; slot 1 publishing data must not assert!
    ld_checked = '0;
    issue_ld('d7, 64'h8000_1020);  // slot 0
    issue_ld('d8, 64'h8000_1028);  // slot 1 (reused!)
    req_in = '{data_rvalid: 1'b1, data_rid: 'd1, data_rdata: 64'h5555_6666, default: '0};
    tick();
    req_in = '0;
    ld_checked = '1;
    #1;
    check(valid_o === 1'b1 && trans_id_o === 'd8 && result_o === 64'h5555_6666, "S3_REUSED_SLOT1_PUB");
    tick();
    req_in = '{data_rvalid: 1'b1, data_rid: 'd0, data_rdata: 64'h7777_8888, default: '0};
    tick();
    req_in = '0;
    tick();

    $display("PASS tb_g6lc_lu_tomb_hyp8 checked=%0d", checked);
    $finish;
  end
endmodule
