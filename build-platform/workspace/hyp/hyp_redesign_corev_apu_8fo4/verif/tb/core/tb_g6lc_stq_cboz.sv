// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// store_unit + store_buffer: a committed cbo.zero drains as exactly the beats
// that cover the architected cache block (T44). The block is
// config_pkg::CBO_BLOCK_BYTES (64, the `riscv,cboz-block-size` every .dts
// publishes), not the D$ line: with DCACHE_LINE_WIDTH = 128 (bits) the
// pre-fix `DCACHE_LINE_WIDTH / 8` derivation aligned the base to 16 bytes
// and drained two 8-byte beats, so Linux's clear_page left bytes 16..63 of
// every block with their previous content (page tables handed out with stale
// PMD entries, user zero pages with old data -- the server1 L1 oops in
// move_page_tables and the 2-hart init segfault).
// Scenarios: S1 cbo.zero on an address 0x38 into a block (tid 3), committed
// -> the D$ port sees CBO_BLOCK_BYTES/8 CBO_ZERO beats, every one with full
// byte enables and zero data, their addresses exactly the block's words
// starting at the block base (STQ_CBOZ_BEATS, STQ_CBOZ_BLOCK_COVERED,
// STQ_CBOZ_ZERO_FULL_BE, STQ_CBOZ_ONE_COMMIT); S2 an ordinary sd (tid 5)
// afterwards drains as one beat (STQ_SD_ONE_BEAT) -- the beat counter resets.
// The D$ model grants every request and answers a CBO_ZERO beat with one
// rvalid the cycle after the grant (the WT dcache's zero_rvalid_q shape).
// Mutation: +define+G6LC_MUT_CBOZ_LINE_BYTES restores the D$-line-derived
// block and must fail STQ_CBOZ_BLOCK_COVERED; +oracle_negative flips the
// verdict.
module tb_g6lc_stq_cboz;
  import g6lc_core_pkg::*;
  `include "g6lc_core_types.svh"
  function automatic config_pkg::g6lc_cfg_t configuration();
    config_pkg::g6lc_cfg_t c = config_pkg::g6lc_cfg_empty;
    c.XLEN = 64; c.VLEN = 64; c.PLEN = 56; c.GPLEN = 64; c.IS_XLEN64 = 1;
    c.NR_SB_ENTRIES = 16; c.TRANS_ID_BITS = 4;
    c.OoOEn = 1; c.SpeculativeSb = 1; c.SuperscalarEn = 1; c.NrHarts = 1;
    c.MmuPresent = 1; c.RVA = 1;
    c.MaxOutstandingStores = 4; c.DeepSpecEn = 0; c.RVZiCboz = 1; c.RVZiCbom = 1;
    c.DCACHE_INDEX_WIDTH = 12; c.DCACHE_TAG_WIDTH = 44; c.DCACHE_LINE_WIDTH = 128;
    c.DCACHE_USER_WIDTH = 1; c.DcacheIdWidth = 1;
    return c;
  endfunction
  localparam config_pkg::g6lc_cfg_t C = configuration();
  localparam type cbo_t = logic [7:0];
  localparam int unsigned BLOCK_B = config_pkg::CBO_BLOCK_BYTES;
  localparam int unsigned BEATS   = BLOCK_B / (C.XLEN / 8);
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

  typedef struct packed {
    logic valid; logic [63:0] pc, target_address; logic is_mispredict, is_taken;
    cf_t cf_type; logic hart_id, ckpt_restore; logic [3:0] trans_id;
  } bp_resolve_t;

  logic clk = 0, rst_n = 0, flush = 0, dtlb_hit = 1, commit = 0, lsu_req_valid = 0;
  logic [15:0] cancel = '0, sb_live = '1;
  logic [3:0] commit_tid = '0;
  lsu_ctrl_t lsu_req = '0, lsu_ctrl;
  bp_resolve_t rb = '0;
  logic pop_st, byp_ready, st_valid_i;
  logic [55:0] paddr = 56'h0000_0010_0000_1038;
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
  dcache_req_o_t req_in;
  dcache_req_i_t req_out;
  bit negative;
  int checked = 0;

  // the request queue in front of the store unit, as in the core (one-shot offers)
  lsu_bypass #(.G6LCCfg(C), .lsu_ctrl_t(lsu_ctrl_t), .bp_resolve_t(bp_resolve_t)) byp (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush), .cancelled_mask_i(cancel),
    .lsu_req_i(lsu_req), .lsu_req_valid_i(lsu_req_valid), .pop_ld_i(1'b0), .pop_st_i(pop_st),
    .resolved_branch_i(rb), .lsu_ctrl_o(lsu_ctrl), .ready_o(byp_ready));
  assign st_valid_i = lsu_ctrl.valid && lsu_ctrl.fu == STORE;

  store_unit #(.G6LCCfg(C), .dcache_req_i_t(dcache_req_i_t), .dcache_req_o_t(dcache_req_o_t),
               .exception_t(exception_t), .lsu_ctrl_t(lsu_ctrl_t), .cbo_t(cbo_t)) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .phys_valid_o(phys_valid), .phys_addr_o(phys_addr), .phys_id_o(phys_id), .phys_hart_o(phys_hart), .phys_size_o(phys_size),
    .flush_i(flush), .cancelled_mask_i(cancel), .sb_live_i(sb_live), .stall_st_pending_i(1'b0),
    .no_st_pending_o(no_st_pending), .store_buffer_empty_o(sb_empty),
    .valid_i(st_valid_i), .lsu_ctrl_i(lsu_ctrl), .pop_st_o(pop_st),
    .commit_i(commit), .commit_ready_o(commit_ready), .amo_valid_commit_i(1'b0), .mbe_i(1'b0),
    .valid_o(su_valid), .trans_id_o(su_tid), .result_o(su_result), .ex_o(ex_o),
    .translation_req_o(translation_req), .vaddr_o(vaddr_o), .rvfi_mem_paddr_o(rvfi_paddr),
    .tinst_o(tinst_o), .hs_ld_st_inst_o(hs), .hlvx_inst_o(hlvx),
    .paddr_i(paddr), .ex_i(ex), .dtlb_hit_i(dtlb_hit),
    .page_offset_i('0), .load_paddr_i('0), .load_paddr_valid_i(1'b0),
    .load_trans_id_i('0), .commit_tran_id_i(commit_tid), .oldest_live_tid_i('0), .head_phys_pending_i(1'b0),
    .load_hart_i('0), .dcache_wbuffer_empty_i(1'b1),
    .page_offset_matches_o(po_match), .page_offset_spec_only_o(po_spec),
    .st_fwd_valid_o(fwd_valid), .st_fwd_data_o(fwd_data), .st_fwd_be_o(fwd_be),
    .amo_req_o(amo_req), .amo_resp_i(amo_resp), .req_port_i(req_in), .req_port_o(req_out));

  // D$ port model: grant every request; a CBO_ZERO beat gets one rvalid the
  // cycle after its grant (wt_dcache's zero_rvalid_q); ordinary stores none.
  logic zero_rvalid_q = 1'b0;
  always_comb begin
    req_in = '0;
    req_in.data_gnt    = req_out.data_req;
    req_in.data_rvalid = zero_rvalid_q;
  end
  // beat log, sampled on the grant edge
  localparam int unsigned BLK_W = $clog2(BLOCK_B);
  localparam logic [55:0] BLOCK_PA = 56'h0000_0010_0000_1038;
  int beats, sd_beats, bad_beats, covered;   // covered: bit k = word k of the block seen
  logic [55:0] beat_pa;
  logic [BLK_W-4:0] beat_word;
  always @(posedge clk) begin
    zero_rvalid_q <= req_out.data_req && (req_out.cbo_op == cbo_t'(CBO_ZERO));
    if (req_out.data_req && req_in.data_gnt) begin
      beat_pa   = {req_out.address_tag, req_out.address_index};
      beat_word = beat_pa[BLK_W-1:3];
      if ($test$plusargs("debug"))
        $display("dbg beat pa=%h cbo=%0d be=%h data=%h", beat_pa, req_out.cbo_op, req_out.data_be, req_out.data_wdata);
      if (req_out.cbo_op == cbo_t'(CBO_ZERO)) begin
        beats <= beats + 1;
        if (req_out.data_be != '1 || req_out.data_wdata != '0) bad_beats <= bad_beats + 1;
        // inside the block of the request's own base?
        if (beat_pa[55:BLK_W] == BLOCK_PA[55:BLK_W])
          covered = covered | (1 << beat_word);
        else
          bad_beats <= bad_beats + 1;
      end else begin
        sd_beats <= sd_beats + 1;
      end
    end
  end

  task automatic tick;
    clk = 1; #2; clk = 0; #2;
  endtask
  task automatic check(input bit ok, input string tag);
    if (ok === negative)
      $fatal(1, "%s beats=%0d covered=%h bad=%0d sd_beats=%0d commit_cnt=%0d state=%0d", tag,
             beats, covered, bad_beats, sd_beats, dut.store_buffer_i.commit_status_cnt_q, dut.state_q);
    checked++;
  endtask
  task automatic offer(input int id, input logic [63:0] va, input fu_op op);
    lsu_req = '0; lsu_req.valid = 1; lsu_req.vaddr = va; lsu_req.data = 64'hd00d_0000_0000_0000 | 64'(id);
    lsu_req.be = '1; lsu_req.fu = STORE; lsu_req.operation = op; lsu_req.trans_id = 4'(id);
    lsu_req_valid = 1; tick(); lsu_req_valid = 0; lsu_req = '0; #2;
  endtask
  task automatic commit_tid_now(input int id);
    // the #2 after the clear keeps the next posedge from racing the deassert
    // (Verilator --timing samples the stale commit_i otherwise)
    commit_tid = 4'(id); commit = 1; tick(); commit = 0; #2;
  endtask

  initial begin
    negative = $test$plusargs("oracle_negative");
    beats = 0; sd_beats = 0; bad_beats = 0; covered = 0;
    #2; tick(); rst_n = 1; #2;

    // S1: cbo.zero (tid 3) on an address 0x38 into the block, translation hits
    paddr = 56'h0000_0010_0000_1038;
    offer(3, 64'h0000_0000_1000_1038, CBO_ZERO);
    tick(); tick();
    check(dut.store_buffer_i.speculative_status_cnt_q == 1 && beats == 0, "STQ_CBOZ_PUSHED_NOT_DRAINED");
    if ($test$plusargs("debug"))
      for (int i = 0; i < 4; i++)
        $display("dbg spec[%0d] valid=%b tid=%0d cbo=%0d addr=%h | head_oh=%b spec_valid_q=%b head_tid=%0d", i,
                 dut.store_buffer_i.speculative_queue_q[i].valid, dut.store_buffer_i.speculative_queue_q[i].trans_id,
                 dut.store_buffer_i.speculative_queue_q[i].cbo_op, dut.store_buffer_i.speculative_queue_q[i].address,
                 dut.store_buffer_i.spec_head_oh, dut.store_buffer_i.spec_valid_q, dut.store_buffer_i.spec_head.trans_id);
    commit_tid_now(3);
    // let the commit queue drain the beats (grant every cycle, rvalid a cycle later)
    repeat (4 * BEATS + 8) tick();
    check(no_st_pending, "STQ_CBOZ_DRAINED");
    check(beats == BEATS, "STQ_CBOZ_BEATS");
    check(covered == (1 << BEATS) - 1 && bad_beats == 0, "STQ_CBOZ_BLOCK_COVERED");
    check(bad_beats == 0, "STQ_CBOZ_ZERO_FULL_BE");
    check(dut.store_buffer_i.commit_status_cnt_q == 0, "STQ_CBOZ_ONE_COMMIT");

    // S2: an ordinary sd (tid 5) afterwards is one beat
    paddr = 56'h0000_0010_0000_2000;
    offer(5, 64'h0000_0000_1000_2000, SD);
    tick();
    commit_tid_now(5);
    repeat (8) tick();
    check(sd_beats == 1 && beats == BEATS && no_st_pending, "STQ_SD_ONE_BEAT");

    if (negative) $fatal(1, "ORACLE_NEGATIVE forced");
    $display("PASS tb_g6lc_stq_cboz checked=%0d beats=%0d block=%0d", checked, beats, BLOCK_B);
    $finish;
  end
endmodule
