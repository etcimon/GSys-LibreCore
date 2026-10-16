// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// lsu_bypass + store_unit: a store cancelled while it waits for its address
// translation must never reach the speculative store queue (T35). The
// scoreboard's cancelled mask names a tid only until the cancelled entry is
// commit-dropped (a few cycles); a store held in WAIT_TRANSLATION behind a
// page-table walk outlives that window, and the store unit used to push it
// when the walk completed -- under a tid whose slot was already free (the
// ooo_spec_entry_live stop on the SMT2 server1 at cycle 76,935,847: hart-1
// store tid 19 cancelled at 76,935,790, PTW done at 76,935,833, pushed after
// the SMT switch) or already re-allocated to another instruction (a ghost
// store that commits with the new occupant: silent memory corruption).
// Scenarios: S1 store A (tid 3) enters WAIT_TRANSLATION (DTLB miss); the
// mask names tid 3 for three cycles and clears (commit-drop); the translation
// then completes -> no push, no writeback, the request is consumed
// (STQ_CANCELLED_NOT_PUSHED, STQ_CANCELLED_NO_WB, STQ_CANCELLED_POPPED);
// S2 store B (tid 5), never cancelled, same DTLB-miss shape -> pushed once,
// written back once (STQ_LIVE_PUSHED); S3 store C (tid 7) queued behind B in
// the bypass and cancelled while B waits -> dropped when it reaches the head
// (STQ_QUEUED_CANCEL_DROPPED); S4 (T40) store D (tid 8) is accepted with a
// DTLB hit and its translation exception arrives in VALID_STORE: the request
// was popped by the accept, so the exception must not pop again (pre-fix the
// bypass counter underflowed 0 -> 3 and lsu_ready stayed low -- the /init
// hang at 494 M cycles -- or the NEXT request was silently lost)
// (STQ_EX_VALID_STORE_NO_DOUBLE_POP, STQ_EX_WB_NOT_PUSHED, STQ_EX_LSU_ALIVE);
// S5 the same exception in WAIT_TRANSLATION pops exactly once
// (STQ_EX_WAIT_POPPED_ONCE).
// Mutations: +define+G6LC_MUT_STQ_NO_STICKY_CANCEL removes the sticky marks
// (mask checked at push time only, the pre-fix shape) and must fail
// STQ_CANCELLED_NOT_PUSHED; +define+G6LC_MUT_SU_EX_POP_ALWAYS restores the
// unconditional exception pop and must fail STQ_EX_VALID_STORE_NO_DOUBLE_POP;
// +oracle_negative flips the verdict.
module tb_g6lc_stq_cancel_ptw;
  import ariane_pkg::*;
  `include "g6lc_core_types.svh"
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c = config_pkg::cva6_cfg_empty;
    c.XLEN = 64; c.VLEN = 64; c.PLEN = 56; c.GPLEN = 64; c.IS_XLEN64 = 1;
    c.NR_SB_ENTRIES = 16; c.TRANS_ID_BITS = 4;
    c.OoOEn = 1; c.SpeculativeSb = 1; c.SuperscalarEn = 1; c.NrHarts = 1;
    c.MmuPresent = 1; c.RVA = 1;
    c.MaxOutstandingStores = 4; c.DeepSpecEn = 0; c.RVZiCboz = 0;
    c.DCACHE_INDEX_WIDTH = 12; c.DCACHE_TAG_WIDTH = 44; c.DCACHE_LINE_WIDTH = 128;
    c.DCACHE_USER_WIDTH = 1; c.DcacheIdWidth = 1;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C = configuration();
  localparam type cbo_t = logic [7:0];
  typedef `G6LC_EXCEPTION_T(C) exception_t;
  typedef struct packed {
    logic                  valid;
    logic [C.VLEN-1:0]     vaddr;
    logic [31:0]           tinst;
    logic                  hs_ld_st_inst;
    logic                  hlvx_inst;
    logic                  overflow;
    logic                  g_overflow;
    logic [C.XLEN-1:0]     data;
    logic [C.XLEN-1:0]     data_cmp;
    logic [C.XLEN-1:0]     data_hi;
    logic [C.XLEN-1:0]     data_cmp_hi;
    logic [(C.XLEN/8)-1:0] be;
    fu_t                   fu;
    fu_op                  operation;
    logic [C.TRANS_ID_BITS-1:0] trans_id;
    logic                  hart;
    logic                  is_speculative_load;
    logic                  is_speculative_load_miss;
  } lsu_ctrl_t;
  typedef struct packed {
    logic valid; logic [63:0] pc, target_address; logic is_mispredict, is_taken;
    cf_t cf_type; logic hart_id, ckpt_restore; logic [3:0] trans_id;
  } bp_resolve_t;
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
    cbo_t                            cbo_op;
  } dcache_req_i_t;
  typedef struct packed {
    logic                            data_gnt;
    logic                            data_rvalid;
    logic [C.DcacheIdWidth-1:0]      data_rid;
    logic [C.XLEN-1:0]               data_rdata;
    logic [C.DCACHE_USER_WIDTH-1:0]  data_ruser;
  } dcache_req_o_t;

  logic clk = 0, rst_n = 0, flush = 0, dtlb_hit = 0, lsu_req_valid = 0;
  logic [15:0] cancel = '0, sb_live = '1;
  lsu_ctrl_t lsu_req = '0, lsu_ctrl;
  bp_resolve_t rb = '0;
  logic pop_st, byp_ready, st_valid_i;
  logic [55:0] paddr = 56'h8000_0000;
  exception_t ex = '0;
  // store unit outputs
  logic phys_valid, no_st_pending, sb_empty, commit_ready, su_valid, translation_req, po_match, po_spec, fwd_valid, hs, hlvx;
  logic [55:0] phys_addr, rvfi_paddr;
  logic [3:0] phys_id, su_tid;
  logic phys_hart;
  logic [1:0] phys_size;
  logic [63:0] su_result, fwd_data, vaddr_o;
  logic [7:0] fwd_be;
  logic [31:0] tinst_o;
  exception_t ex_o;
  amo_req_t amo_req;
  amo_resp_t amo_resp = '0;
  dcache_req_o_t req_in = '0;
  dcache_req_i_t req_out;
  bit negative;
  int checked = 0;

  lsu_bypass #(.CVA6Cfg(C), .lsu_ctrl_t(lsu_ctrl_t), .bp_resolve_t(bp_resolve_t)) byp (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush), .cancelled_mask_i(cancel),
    .lsu_req_i(lsu_req), .lsu_req_valid_i(lsu_req_valid), .pop_ld_i(1'b0), .pop_st_i(pop_st),
    .resolved_branch_i(rb), .lsu_ctrl_o(lsu_ctrl), .ready_o(byp_ready));
  assign st_valid_i = lsu_ctrl.valid && lsu_ctrl.fu == STORE;

  store_unit #(.CVA6Cfg(C), .dcache_req_i_t(dcache_req_i_t), .dcache_req_o_t(dcache_req_o_t),
               .exception_t(exception_t), .lsu_ctrl_t(lsu_ctrl_t), .cbo_t(cbo_t)) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .phys_valid_o(phys_valid), .phys_addr_o(phys_addr), .phys_id_o(phys_id), .phys_hart_o(phys_hart), .phys_size_o(phys_size),
    .flush_i(flush), .cancelled_mask_i(cancel), .sb_live_i(sb_live), .stall_st_pending_i(1'b0),
    .no_st_pending_o(no_st_pending), .store_buffer_empty_o(sb_empty),
    .valid_i(st_valid_i), .lsu_ctrl_i(lsu_ctrl), .pop_st_o(pop_st),
    .commit_i(1'b0), .commit_ready_o(commit_ready), .amo_valid_commit_i(1'b0), .mbe_i(1'b0),
    .valid_o(su_valid), .trans_id_o(su_tid), .result_o(su_result), .ex_o(ex_o),
    .translation_req_o(translation_req), .vaddr_o(vaddr_o), .rvfi_mem_paddr_o(rvfi_paddr),
    .tinst_o(tinst_o), .hs_ld_st_inst_o(hs), .hlvx_inst_o(hlvx),
    .paddr_i(paddr), .ex_i(ex), .dtlb_hit_i(dtlb_hit),
    .page_offset_i('0), .load_paddr_i('0), .load_paddr_valid_i(1'b0),
    .load_trans_id_i('0), .commit_tran_id_i('0), .oldest_live_tid_i('0), .head_phys_pending_i(1'b0),
    .load_hart_i('0), .dcache_wbuffer_empty_i(1'b1),
    .page_offset_matches_o(po_match), .page_offset_spec_only_o(po_spec),
    .st_fwd_valid_o(fwd_valid), .st_fwd_data_o(fwd_data), .st_fwd_be_o(fwd_be),
    .amo_req_o(amo_req), .amo_resp_i(amo_resp), .req_port_i(req_in), .req_port_o(req_out));

  // sampled once per tick (see tb_g6lc_stq_flush_ptr for why)
  int pushes, wbs;
  logic [3:0] last_push_tid, last_wb_tid;
  logic [2:0] spec_cnt_s;
  logic [1:0] byp_cnt_s;
  task automatic tick;
    clk = 1; #2; clk = 0; #2;
    spec_cnt_s = dut.store_buffer_i.speculative_status_cnt_q;
    byp_cnt_s  = byp.status_cnt_q;
  endtask
  // event counters, sampled on the clock edge inside the DUT's own time step
  always @(posedge clk) begin
    if (dut.store_buffer_valid && !cancel[dut.trans_id_q]) begin pushes <= pushes + 1; last_push_tid <= dut.trans_id_q; end
    if (su_valid) begin wbs <= wbs + 1; last_wb_tid <= su_tid; end
  end
  task automatic check(input bit ok, input string tag);
    if (ok === negative)
      $fatal(1, "%s pushes=%0d (tid %0d) wbs=%0d (tid %0d) spec_cnt=%0d byp_cnt=%0d state=%0d", tag,
             pushes, last_push_tid, wbs, last_wb_tid, spec_cnt_s, byp_cnt_s, dut.state_q);
    checked++;
  endtask
  task automatic offer_store(input int id, input logic [63:0] va);
    lsu_req = '0; lsu_req.valid = 1; lsu_req.vaddr = va; lsu_req.data = 64'hd00d_0000_0000_0000 | 64'(id);
    lsu_req.be = '1; lsu_req.fu = STORE; lsu_req.operation = SD; lsu_req.trans_id = 4'(id);
    lsu_req_valid = 1; tick(); lsu_req_valid = 0; lsu_req = '0; #2;
  endtask

  initial begin
    negative = $test$plusargs("oracle_negative");
    pushes = 0; wbs = 0;
    #2; tick(); rst_n = 1; #2;

    // S1: store A (tid 3) misses the DTLB and waits for the walk
    dtlb_hit = 0;
    offer_store(3, 64'h0000_0000_1000_0000);
    tick(); tick();
    check(dut.state_q == 2'd2 && byp_cnt_s == 1, "STQ_WAIT_TRANSLATION_ENTERED");
    // cancelled for three cycles (younger-cancel), then commit-dropped: mask clears
    cancel[3] = 1; tick(); tick(); tick(); cancel[3] = 0;
    // the walk goes on for a while, then the translation completes
    repeat (8) tick();
    dtlb_hit = 1; paddr = 56'h0000_0010_0000_0000; tick(); tick(); tick();
    check(pushes == 0, "STQ_CANCELLED_NOT_PUSHED");
    check(wbs == 0, "STQ_CANCELLED_NO_WB");
    check(byp_cnt_s == 0 && dut.state_q == 2'd0, "STQ_CANCELLED_POPPED");

    // S2: store B (tid 5), the same shape without a cancel -> pushed once
    dtlb_hit = 0;
    offer_store(5, 64'h0000_0000_2000_0000);
    tick(); tick();
    repeat (8) tick();
    dtlb_hit = 1; paddr = 56'h0000_0010_0000_2000; tick(); tick(); tick();
    check(pushes == 1 && last_push_tid == 4'd5 && spec_cnt_s == 1, "STQ_LIVE_PUSHED");
    check(wbs == 1 && last_wb_tid == 4'd5, "STQ_LIVE_WB");

    // S3: store B2 (tid 6) waits on the walk, store C (tid 7) queues behind it in
    // the bypass and is cancelled while B2 waits; C must be dropped at the head.
    dtlb_hit = 0;
    offer_store(6, 64'h0000_0000_3000_0000);
    tick();
    offer_store(7, 64'h0000_0000_4000_0000);
    tick();
    check(byp_cnt_s == 2, "STQ_TWO_QUEUED");
    cancel[7] = 1; tick(); tick(); cancel[7] = 0;
    repeat (4) tick();
    dtlb_hit = 1; paddr = 56'h0000_0010_0000_3000; tick(); tick(); tick(); tick(); tick();
    check(pushes == 2 && last_push_tid == 4'd6 && spec_cnt_s == 2, "STQ_QUEUED_CANCEL_DROPPED");
    check(byp_cnt_s == 0 && dut.state_q == 2'd0, "STQ_QUEUE_DRAINED");

    // S4 (T40): store D (tid 8) hits the DTLB and is accepted (popped) in IDLE;
    // its translation exception arrives in the VALID_STORE cycle. The request
    // was already popped: the bypass must stay consistent (count 0, ready), the
    // store is written back with the exception and not pushed.
    dtlb_hit = 1;
    offer_store(8, 64'h0000_0000_5000_0000);
    check(dut.state_q == 2'd1 && byp_cnt_s == 0, "STQ_EX_ACCEPTED");
    ex = '0; ex.valid = 1'b1; ex.cause = 64'd15; tick(); ex = '0;
    tick(); tick();
    check(byp_cnt_s == 0 && byp_ready && dut.state_q == 2'd0, "STQ_EX_VALID_STORE_NO_DOUBLE_POP");
    check(pushes == 2 && wbs == 3 && last_wb_tid == 4'd8, "STQ_EX_WB_NOT_PUSHED");
    // and the LSU still takes stores afterwards
    offer_store(10, 64'h0000_0000_6000_0000);
    tick(); tick(); tick();
    check(pushes == 3 && last_push_tid == 4'd10, "STQ_EX_LSU_ALIVE");
    // S5: the same exception while the request waits for its translation ->
    // it is still at the head and must be popped exactly once
    dtlb_hit = 0;
    offer_store(12, 64'h0000_0000_7000_0000);
    tick(); tick();
    check(dut.state_q == 2'd2 && byp_cnt_s == 1, "STQ_EX_WAIT_ENTERED");
    ex = '0; ex.valid = 1'b1; ex.cause = 64'd15; tick(); ex = '0;
    tick(); tick();
    check(byp_cnt_s == 0 && byp_ready && dut.state_q == 2'd0 && pushes == 3 && wbs == 5 && last_wb_tid == 4'd12,
          "STQ_EX_WAIT_POPPED_ONCE");

    if (negative) $fatal(1, "ORACLE_NEGATIVE forced");
    $display("PASS tb_g6lc_stq_cancel_ptw checked=%0d", checked);
    $finish;
  end
endmodule
