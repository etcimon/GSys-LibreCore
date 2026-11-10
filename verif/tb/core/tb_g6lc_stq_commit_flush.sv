// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// store_buffer: commit_i and flush_i may coincide — the commit stage retires
// a store in the same cycle a full flush arrives (a single-step debug entry
// decided by that store's own commit, or a trap on a younger commit port).
// The flush drops younger speculative stores only; the retiring head must
// still reach the commit queue and be the only store the D$ ever sees.
// The former `commit_and_flush` assertion forbade the coincidence outright —
// its premise was false — and aborted the real-CPU single-step runs (CPU49);
// it is replaced by commit_and_flush_keeps_head / flush_empties_speculative.
// Stimulus note: inputs are held one slot before each posedge (#1 inside
// tick). Concurrent assertions sample settled values; the older flush-ptr
// leaf drove inputs in the same slot as the edge, which the assertion
// sampler never saw — coincident commit+flush was never assertion-visible
// there.
// Scenarios: S1 three stores, commit head + flush in one cycle -> only the
// head is issued on req_port_o; S2 flush without commit -> nothing reaches
// memory; S3 plain commit -> the store drains normally.
// +oracle_negative flips the verdict. +define+G6LC_MUT_STQ_COMMIT_DROPPED_ON_FLUSH
// gates the commit-queue push on !flush_i: the bench checks must reject it
// without --assert, and commit_and_flush_keeps_head must reject it with
// --assert.
module tb_g6lc_stq_commit_flush;
  import ariane_pkg::*;
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c = config_pkg::cva6_cfg_empty;
    c.XLEN = 64; c.VLEN = 64; c.PLEN = 56; c.IS_XLEN64 = 1;
    c.NR_SB_ENTRIES = 16; c.TRANS_ID_BITS = 4;
    c.OoOEn = 1; c.SpeculativeSb = 1; c.SuperscalarEn = 1; c.NrHarts = 1;
    c.MaxOutstandingStores = 4; c.DeepSpecEn = 0; c.RVZiCboz = 0;
    c.DCACHE_INDEX_WIDTH = 12; c.DCACHE_TAG_WIDTH = 44; c.DCACHE_LINE_WIDTH = 128;
    c.DCACHE_USER_WIDTH = 1; c.DcacheIdWidth = 1;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C = configuration();
  localparam type cbo_t = logic [7:0];
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

  logic clk = 0, rst_n = 0, flush = 0, commit = 0, valid = 0;
  logic [15:0] cancel = '0, sb_live = '1;
  logic [3:0] tid = '0, oldest = '0, commit_tid = '0;
  logic [55:0] paddr = '0;
  logic [63:0] data = '0;
  logic no_st_pending, empty, po_match, po_spec, fwd_valid, commit_ready, ready;
  logic [63:0] fwd_data;
  logic [7:0] fwd_be;
  logic [55:0] rvfi_paddr;
  dcache_req_o_t req_in;
  dcache_req_i_t req_out;
  bit negative;
  int checked = 0;

  store_buffer #(.CVA6Cfg(C), .dcache_req_i_t(dcache_req_i_t), .dcache_req_o_t(dcache_req_o_t), .cbo_t(cbo_t)) dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush), .cancelled_mask_i(cancel), .sb_live_i(sb_live),
    .stall_st_pending_i(1'b0), .no_st_pending_o(no_st_pending), .store_buffer_empty_o(empty),
    .page_offset_i('0), .load_paddr_i('0), .load_paddr_valid_i(1'b0),
    .load_trans_id_i('0), .commit_trans_id_i(commit_tid), .oldest_live_tid_i(oldest),
    .head_phys_pending_i(1'b0), .load_hart_i('0), .dcache_wbuffer_empty_i(1'b1),
    .page_offset_matches_o(po_match), .page_offset_spec_only_o(po_spec),
    .st_fwd_valid_o(fwd_valid), .st_fwd_data_o(fwd_data), .st_fwd_be_o(fwd_be),
    .commit_i(commit), .commit_ready_o(commit_ready), .ready_o(ready),
    .valid_i(valid), .valid_without_flush_i(valid),
    .paddr_i(paddr), .trans_id_i(tid), .st_hart_i('0), .data_prot_i('0),
    .rvfi_mem_paddr_o(rvfi_paddr), .data_i(data), .be_i('1), .data_size_i(2'b11),
    .cbo_op_i(cbo_t'(ariane_pkg::CBO_NONE)),
    .req_port_i(req_in), .req_port_o(req_out));

  // DUT state and request fields sampled once after every settled edge.
  logic [2:0] spec_cnt_s, commit_cnt_s;
  logic head_valid_s;
  logic no_st_pending_s, empty_s;
  logic [55:0] commit_head_pa_s;
  logic [63:0] commit_head_data_s;
  logic [7:0] commit_head_be_s;
  logic [1:0] commit_head_size_s;
  logic req_req_s;
  logic [11:0] req_index_s;
  logic [43:0] req_tag_s;
  logic [63:0] req_data_s;
  logic [7:0] req_be_s;
  logic [1:0] req_size_s;
  task automatic tick;
    #1; clk = 1; #2; clk = 0; #2;
    spec_cnt_s = dut.speculative_status_cnt_q; commit_cnt_s = dut.commit_status_cnt_q;
    head_valid_s = dut.commit_queue_q[dut.commit_read_pointer_q].valid;
    commit_head_pa_s = dut.commit_queue_q[dut.commit_read_pointer_q].address;
    commit_head_data_s = dut.commit_queue_q[dut.commit_read_pointer_q].data;
    commit_head_be_s = dut.commit_queue_q[dut.commit_read_pointer_q].be;
    commit_head_size_s = dut.commit_queue_q[dut.commit_read_pointer_q].data_size;
    no_st_pending_s = no_st_pending; empty_s = empty;
    req_req_s = req_out.data_req; req_index_s = req_out.address_index;
    req_tag_s = req_out.address_tag; req_data_s = req_out.data_wdata;
    req_be_s = req_out.data_be; req_size_s = req_out.data_size;
  endtask
  task automatic clear_inputs; flush = 0; commit = 0; valid = 0; cancel = '0; req_in = '0; endtask
  task automatic push(input int id, input logic [55:0] pa);
    valid = 1; tid = 4'(id); paddr = pa; data = 64'hd0d0_0000_0000_0000 | 64'(id);
    tick(); clear_inputs(); #2;
  endtask
  task automatic grant;
    req_in.data_gnt = 1; tick(); req_in.data_gnt = 0; #1;
  endtask
  task automatic check(input bit ok, input string tag);
    if (ok === negative)
      $fatal(1, "%s spec: cnt=%0d/%0d head v=%b pa=%h data=%h be=%h sz=%0d | req=%b idx=%h tag=%h data=%h be=%h sz=%0d nsp=%b empty=%b", tag,
             spec_cnt_s, commit_cnt_s, head_valid_s, commit_head_pa_s, commit_head_data_s,
             commit_head_be_s, commit_head_size_s,
             req_req_s, req_index_s, req_tag_s, req_data_s, req_be_s, req_size_s,
             no_st_pending_s, empty_s);
    checked++;
  endtask

  initial begin
    negative = $test$plusargs("oracle_negative");
    clear_inputs(); #2; tick(); rst_n = 1; #2;

    // S1: stores 1,2,3 queued in program order (oldest anchor 0 -> tid order).
    push(1, 56'h8000_1000); push(2, 56'h8000_2000); push(3, 56'h8000_3000);
    check(spec_cnt_s == 3 && commit_cnt_s == 0, "STQ_PUSHED_3");
    // Commit of the head (tid 1) and a full flush in the same cycle: the
    // committed store must still reach the commit queue; the younger two
    // are dropped.
    commit = 1; commit_tid = 4'd1; flush = 1; tick(); clear_inputs(); #2;
    // One more settled cycle: commit_and_flush_keeps_head is non-overlapped
    // and evaluates on this edge — give it the posedge before the checks so
    // a mutant is rejected by the assertion, not just by the bench oracle.
    tick();
    check(spec_cnt_s == 0, "STQ_SPEC_EMPTY_AFTER_FLUSH");
    check(commit_cnt_s == 1 && head_valid_s &&
          commit_head_pa_s == 56'h8000_1000 &&
          commit_head_data_s == (64'hd0d0_0000_0000_0000 | 64'd1) &&
          commit_head_be_s == 8'hff && commit_head_size_s == 2'b11,
          "STQ_HEAD_RETIRED_WITH_FLUSH");
    check(no_st_pending_s == 0, "STQ_PENDING_AFTER_RETIRE");
    // The commit-queue head issues exactly one request, with A's fields.
    tick();
    check(req_req_s == 1 && req_index_s == 12'h000 && req_tag_s == 44'h80001 &&
          req_data_s == (64'hd0d0_0000_0000_0000 | 64'd1) &&
          req_be_s == 8'hff && req_size_s == 2'b11,
          "STQ_ONLY_HEAD_REQUEST");
    grant;
    check(commit_cnt_s == 0 && no_st_pending_s == 1, "STQ_DRAINED");
    grant; check(req_req_s == 0 && commit_cnt_s == 0, "STQ_NO_YOUNGER_REQ_1");
    grant; check(req_req_s == 0 && commit_cnt_s == 0, "STQ_NO_YOUNGER_REQ_2");

    // S2: a flush without commit drops everything; memory sees nothing.
    push(4, 56'h8000_4000); push(5, 56'h8000_5000);
    check(spec_cnt_s == 2 && commit_cnt_s == 0, "STQ_PUSHED_2");
    flush = 1; tick(); clear_inputs(); #2;
    check(spec_cnt_s == 0 && commit_cnt_s == 0, "STQ_FLUSH_ONLY_EMPTY");
    grant; check(req_req_s == 0 && commit_cnt_s == 0, "STQ_FLUSH_ONLY_NO_REQ");
    grant; check(req_req_s == 0 && commit_cnt_s == 0, "STQ_FLUSH_ONLY_QUIET");

    // S3: a plain commit (no flush) still retires the head to memory.
    push(6, 56'h8000_6000);
    check(spec_cnt_s == 1, "STQ_PUSHED_1");
    commit = 1; commit_tid = 4'd6; tick(); clear_inputs(); #2;
    check(spec_cnt_s == 0 && commit_cnt_s == 1 && head_valid_s &&
          commit_head_pa_s == 56'h8000_6000,
          "STQ_PLAIN_COMMIT");
    tick();
    check(req_req_s == 1 && req_index_s == 12'h000 && req_tag_s == 44'h80006 &&
          req_data_s == (64'hd0d0_0000_0000_0000 | 64'd6) &&
          req_be_s == 8'hff && req_size_s == 2'b11,
          "STQ_PLAIN_REQ");
    grant;
    check(commit_cnt_s == 0 && no_st_pending_s == 1 && empty_s == 1,
          "STQ_FINAL_DRAINED");

    if (negative) $fatal(1, "ORACLE_NEGATIVE forced");
    $display("PASS tb_g6lc_stq_commit_flush checked=%0d", checked);
    $finish;
  end
endmodule
