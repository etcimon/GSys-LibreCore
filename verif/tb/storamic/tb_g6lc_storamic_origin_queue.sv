// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module tb_g6lc_storamic_origin_queue;
  import ariane_pkg::*;
  `include "g6lc_core_types.svh"
  function automatic config_pkg::cva6_cfg_t configuration();
    config_pkg::cva6_cfg_t c = config_pkg::cva6_cfg_empty;
    c.XLEN = 64; c.VLEN = 64; c.PLEN = 56; c.GPLEN = 64; c.IS_XLEN64 = 1;
    c.NR_SB_ENTRIES = 16; c.TRANS_ID_BITS = 4; c.NrHarts = 1;
    c.MmuPresent = 1; c.MaxOutstandingStores = 4;
    c.DCACHE_INDEX_WIDTH = 12; c.DCACHE_TAG_WIDTH = 44;
    c.DCACHE_LINE_WIDTH = 128; c.DCACHE_USER_WIDTH = 1; c.DcacheIdWidth = 1;
    c.StoramicEn = 1; c.StoramicIoEn = 1;
    c.StoramicCheckpointEn = 1; c.DCacheType = config_pkg::WT;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t C = configuration();
  typedef logic [7:0] cbo_t;
  typedef `G6LC_EXCEPTION_T(C) exception_t;
  typedef struct packed {
    logic [2:0] data_prot;
    logic valid;
    logic [C.VLEN-1:0] vaddr;
    logic [31:0] tinst;
    logic hs_ld_st_inst, hlvx_inst, overflow, g_overflow;
    logic [63:0] data, data_cmp, data_hi, data_cmp_hi;
    logic [7:0] be;
    fu_t fu;
    fu_op operation;
    logic [3:0] trans_id;
    logic hart, is_speculative_load, is_speculative_load_miss;
  } lsu_ctrl_t;
  typedef struct packed {
    logic valid;
    logic [63:0] pc, target_address;
    logic is_mispredict, is_taken;
    cf_t cf_type;
    logic hart_id, ckpt_restore;
    logic [3:0] trans_id;
  } bp_resolve_t;
  typedef struct packed {
    logic [2:0] data_prot;
    logic [11:0] address_index;
    logic [43:0] address_tag;
    logic [63:0] data_wdata;
    logic data_wuser, data_req, data_we;
    logic [7:0] data_be;
    logic [1:0] data_size;
    logic data_id, kill_req, tag_valid;
    cbo_t cbo_op;
  } req_t;
  typedef struct packed {
    logic data_gnt, data_rvalid, data_rid;
    logic [63:0] data_rdata;
    logic data_ruser;
  } rsp_t;
  logic clk = 0, rst_n = 0, flush = 0, offer = 0, pop, ready;
  logic hit = 0, commit = 0, commit_ready, empty;
  logic [1:0] effective_privilege = 0;
  logic virtualized = 0;
  lsu_ctrl_t payload = '0, source_packet, held_packet;
  bp_resolve_t branch_result = '0;
  req_t request;
  rsp_t response;
  logic cache_grant = 0;
  assign response = '{data_gnt: cache_grant, default: '0};
  exception_t exception_in = '0;
  amo_resp_t amo_response = '0;
  int checks = 0, phase = 0;
  logic debug_mode = 0;
  always @(posedge clk) if (rst_n && (commit || response.data_gnt || dut.store_buffer_valid))
    $display("origin-trace t=%0t phase=%0d commit=%b grant=%b/%b req=%b rptr=%0d/%0d wptr=%0d head=%b valid=%b cbo=%h none=%h",
      $time, phase, commit, response.data_gnt, dut.req_port_i.data_gnt, request.data_req,
      dut.store_buffer_i.commit_read_pointer_q, dut.store_buffer_i.commit_read_pointer_n,
      dut.store_buffer_i.commit_write_pointer_q, dut.store_buffer_i.spec_head_oh,
      dut.store_buffer_i.spec_head.valid, request.cbo_op, ariane_pkg::CBO_NONE);
  task automatic tick; #2; clk = 1; #2; clk = 0; #2; endtask
  always_comb begin
    source_packet = payload;
    source_packet.data_prot = config_pkg::g6lc_storamic_data_prot(
        effective_privilege, virtualized, debug_mode);
  end
  lsu_bypass #(.CVA6Cfg(C), .lsu_ctrl_t(lsu_ctrl_t), .bp_resolve_t(bp_resolve_t)) bypass (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush), .cancelled_mask_i('0),
    .lsu_req_i(source_packet), .lsu_req_valid_i(offer), .pop_ld_i(1'b0), .pop_st_i(pop),
    .resolved_branch_i(branch_result), .lsu_ctrl_o(held_packet), .ready_o(ready)
  );
  store_unit #(.CVA6Cfg(C), .dcache_req_i_t(req_t), .dcache_req_o_t(rsp_t),
      .exception_t(exception_t), .lsu_ctrl_t(lsu_ctrl_t), .cbo_t(cbo_t)) dut (
    .clk_i(clk), .rst_ni(rst_n), .flush_i(flush), .cancelled_mask_i('0), .sb_live_i('1),
    .phys_valid_o(), .phys_addr_o(), .phys_id_o(), .phys_hart_o(), .phys_size_o(),
    .stall_st_pending_i(1'b0), .no_st_pending_o(), .store_buffer_empty_o(empty),
    .valid_i(held_packet.valid), .lsu_ctrl_i(held_packet), .pop_st_o(pop),
    .commit_i(commit), .commit_ready_o(commit_ready), .amo_valid_commit_i(1'b0), .mbe_i(1'b0),
    .valid_o(), .trans_id_o(), .result_o(), .ex_o(), .translation_req_o(), .vaddr_o(),
    .rvfi_mem_paddr_o(), .tinst_o(), .hs_ld_st_inst_o(), .hlvx_inst_o(),
    .paddr_i(56'h1000), .ex_i(exception_in), .dtlb_hit_i(hit),
    .page_offset_i('0), .load_paddr_i('0), .load_paddr_valid_i(1'b0),
    .load_trans_id_i('0), .commit_tran_id_i('0), .oldest_live_tid_i('0),
    .head_phys_pending_i(1'b0), .load_hart_i('0), .dcache_wbuffer_empty_i(1'b1),
    .page_offset_matches_o(), .page_offset_spec_only_o(), .st_fwd_valid_o(),
    .st_fwd_data_o(), .st_fwd_be_o(), .amo_req_o(), .amo_resp_i(amo_response),
    .req_port_i(response), .req_port_o(request)
  );
  task automatic ok(input bit condition, input string label);
    checks++;
    if (!condition) $fatal(1, "ORIGIN_QUEUE_FAIL %s phase=%0d checks=%0d state=%0d spec=%0d commit=%0d bypass=%0d live=%b head=%b rptr=%0d wptr=%0d rvalid=%b wait=%b cbo=%h",
        label, phase, checks, dut.state_q, dut.store_buffer_i.speculative_status_cnt_q,
        dut.store_buffer_i.commit_status_cnt_q, bypass.status_cnt_q,
        dut.store_buffer_i.spec_valid_q, dut.store_buffer_i.spec_head_oh,
        dut.store_buffer_i.commit_read_pointer_q, dut.store_buffer_i.commit_write_pointer_q,
        dut.store_buffer_i.commit_queue_q[dut.store_buffer_i.commit_read_pointer_q].valid,
        dut.store_buffer_i.commit_queue_q[dut.store_buffer_i.commit_read_pointer_q].wait_rvalid,
        dut.store_buffer_i.commit_queue_q[dut.store_buffer_i.commit_read_pointer_q].cbo_op);
  endtask
  task automatic send(input logic [1:0] privilege, input int id, input bit debug_source = 0);
    for (int n = 0; n < 100 && !ready; n++) tick();
    ok(ready, "bypass-ready");
    effective_privilege = privilege;
    debug_mode = debug_source;
    payload = '0; payload.valid = 1; payload.vaddr = 64'h1000;
    payload.data = 64'(id); payload.be = 8'hFF; payload.fu = STORE;
    payload.operation = SD; payload.trans_id = 4'(id);
    offer = 1; tick(); offer = 0; payload = '0;
  endtask
  task automatic retire(input logic [2:0] expected, input int data_value);
    phase = data_value;
    for (int n = 0; n < 100 && !commit_ready; n++) tick();
    ok(commit_ready, "commit-ready"); commit = 1; tick(); commit = 0;
    for (int n = 0; n < 100 && !request.data_req; n++) tick();
    ok(request.data_req, "cache-request");
    repeat (7) begin
      effective_privilege = effective_privilege ^ 2'b11;
      debug_mode = ~debug_mode;
      tick();
      ok(request.data_prot == expected && request.data_wdata == 64'(data_value),
         "committed-origin-held-across-CSR-changes");
    end
    cache_grant = 1;
    #1;
    ok(dut.store_buffer_i.req_port_i.data_gnt, "cache-grant-bound-to-buffer");
    ok(dut.store_buffer_i.commit_read_pointer_n ==
        2'(dut.store_buffer_i.commit_read_pointer_q + 1), "accepted-store-advances-head");
    tick(); cache_grant = 0; tick();
  endtask
  initial begin
    repeat (3) tick(); rst_n = 1; tick();
    ok(config_pkg::g6lc_storamic_origin_supported(C), "supported-scalar-profile");
    send(2'b00, 1); effective_privilege = 2'b11;
    repeat (8) tick();
    ok(held_packet.data_prot == 3'b010, "user-not-promoted-during-PTW");
    hit = 1; repeat (5) tick(); retire(3'b010, 1);
    // The first accepted store has left the bypass when the second arrives.
    send(2'b11, 2); repeat (2) tick(); send(2'b01, 3);
    repeat (6) tick(); retire(3'b001, 2); retire(3'b011, 3);
    send(2'b11, 4); repeat (5) tick();
    flush = 1; tick(); flush = 0; repeat (3) tick();
    ok(empty && !request.data_req, "flushed-origin-not-reused");
    send(2'b00, 5); repeat (5) tick(); retire(3'b010, 5);
    send(2'b11, 6, 1); debug_mode = 0;
    repeat (5) tick(); retire(3'b000, 6);
    send(2'b11, 7); debug_mode = 1;
    repeat (5) tick(); retire(3'b001, 7);
    if ($test$plusargs("oracle_negative")) ok(0, "negative-oracle");
    $display("ORIGIN_QUEUE_PASS checks=%0d", checks); $finish;
  end
  initial begin #100000; $fatal(1, "ORIGIN_QUEUE_TIMEOUT"); end
endmodule
