// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// store_buffer: the speculative queue's pointer pair and status count must
// describe one queue after a flush that coincides with a commit (T35). The
// old flush path wrote `write_pointer_n = read_pointer_q` while the same-cycle
// commit had moved `read_pointer_n` to `read_pointer_q + 1`: count 0 with the
// pointers one apart. The next arrival was then written one slot behind the
// head, and under OoO the program-order rewrite (which snapshots
// [read_pointer_n, read_pointer_n + count)) copied the STALE slot at the head
// into position 0 and re-validated it -- a speculative entry whose scoreboard
// slot is dead (`ooo_spec_entry_live`), a ghost store that would commit with
// the next store, and a dropped real store. Linux on the SMT2 server1 hit it
// at cycle 76,935,847 (the forced drain's registered flush pulse landing in
// the cycle the head store committed).
// Scenarios: S1 two stores queued, commit + flush in one cycle -> queue empty,
// pointers agree (STQ_PTR_AGREE); S2 a new store arrives -> it is the head,
// with its own tid (STQ_HEAD_IS_ARRIVAL); S3 commit of that store hands its
// own address to the commit queue (STQ_COMMIT_IS_ARRIVAL).
// Mutation +define+G6LC_MUT_STQ_FLUSH_WP_Q restores the old `_q` write and
// must fail STQ_PTR_AGREE / STQ_HEAD_IS_ARRIVAL; +oracle_negative flips the
// verdict.
module tb_g6lc_stq_flush_ptr;
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
    .paddr_i(paddr), .trans_id_i(tid), .st_hart_i('0), .rvfi_mem_paddr_o(rvfi_paddr),
    .data_i(data), .be_i('1), .data_size_i(2'b11), .cbo_op_i(cbo_t'(ariane_pkg::CBO_NONE)),
    .req_port_i(req_in), .req_port_o(req_out));

  // DUT state sampled once after every clock and checked from these copies.
  // (Verilator 5.020 --timing evaluated the commit-queue pop with a stale
  // req_in when the DUT was only read through hierarchical references inside
  // the checks -- entry 0 was popped without a grant; one sample point per
  // tick pins the evaluation order and keeps the leaf deterministic.)
  logic [2:0] spec_cnt_s, commit_cnt_s;
  logic [1:0] spec_rp_s, spec_wp_s;
  logic [3:0] head_tid_s, commit_last_tid_s;
  logic head_valid_s, commit_last_valid_s;
  logic [55:0] head_pa_s, commit_head_pa_s, commit_last_pa_s;
  logic [3:0] spec_valid_s, spec_is5_s;
  task automatic tick;
    clk = 1; #2; clk = 0; #2;
    spec_cnt_s = dut.speculative_status_cnt_q; spec_rp_s = dut.speculative_read_pointer_q; spec_wp_s = dut.speculative_write_pointer_q;
    head_tid_s = dut.speculative_queue_q[dut.speculative_read_pointer_q].trans_id;
    head_valid_s = dut.speculative_queue_q[dut.speculative_read_pointer_q].valid;
    head_pa_s = dut.speculative_queue_q[dut.speculative_read_pointer_q].address;
    for (int i = 0; i < 4; i++) begin
      spec_valid_s[i] = dut.speculative_queue_q[i].valid;
      spec_is5_s[i] = dut.speculative_queue_q[i].trans_id == 4'd5;
    end
    commit_cnt_s = dut.commit_status_cnt_q;
    commit_head_pa_s = dut.commit_queue_q[dut.commit_read_pointer_q].address;
    commit_last_pa_s = dut.commit_queue_q[2'(dut.commit_write_pointer_q - 1'b1)].address;
    commit_last_valid_s = dut.commit_queue_q[2'(dut.commit_write_pointer_q - 1'b1)].valid;
    commit_last_tid_s = dut.commit_queue_q[2'(dut.commit_write_pointer_q - 1'b1)].trans_id;
  endtask
  task automatic clear_inputs; flush = 0; commit = 0; valid = 0; cancel = '0; req_in = '0; endtask
  // push one store (AGU time): tid, address; the scoreboard keeps every tid live
  task automatic push(input int id, input logic [55:0] pa);
    valid = 1; tid = 4'(id); paddr = pa; data = 64'hd0d0_0000_0000_0000 | 64'(id);
    tick(); clear_inputs(); #2;
  endtask
  task automatic check(input bit ok, input string tag);
    if (ok === negative)
      $fatal(1, "%s spec: cnt=%0d rp=%0d wp=%0d head tid=%0d v=%b | commit: cnt=%0d head pa=%h last pa=%h v=%b", tag,
             spec_cnt_s, spec_rp_s, spec_wp_s, head_tid_s, head_valid_s,
             commit_cnt_s, commit_head_pa_s, commit_last_pa_s, commit_last_valid_s);
    checked++;
  endtask
  // the invariant the RTL assertion carries: wp - rp == count (mod DEPTH_SPEC)
  function automatic bit ptr_agree();
    return (2'(spec_wp_s - spec_rp_s) == 2'(spec_cnt_s));
  endfunction

  initial begin
    negative = $test$plusargs("oracle_negative");
    clear_inputs(); #2; tick(); rst_n = 1; #2;

    // S1: stores 1 and 2 queued (program order 1 < 2 under oldest = 0).
    push(1, 56'h8000_1000); push(2, 56'h8000_2000);
    check(spec_cnt_s == 2 && ptr_agree(), "STQ_PTR_AGREE_AFTER_PUSH");
    // commit of the head (tid 1) and a flush in the same cycle: the
    // committed store goes to the commit queue, the rest is dropped.
    commit = 1; commit_tid = 4'd1; flush = 1; tick(); clear_inputs(); #2;
    check(spec_cnt_s == 0, "STQ_EMPTY_AFTER_FLUSH");
    check(ptr_agree(), "STQ_PTR_AGREE");
    check(commit_cnt_s == 1 && commit_head_pa_s == 56'h8000_1000, "STQ_COMMITTED_SURVIVES_FLUSH");
    // The commit queue is left undrained (no D$ grant): the leaf is about the
    // speculative side; S3 reads the newest commit-queue entry.

    // S2: the next arrival must be the head, with its own tid.
    oldest = 4'd5;
    push(5, 56'h8000_5000);
    check(spec_cnt_s == 1 && ptr_agree(), "STQ_PTR_AGREE_AFTER_ARRIVAL");
    check(head_valid_s && head_tid_s == 4'd5 && head_pa_s == 56'h8000_5000, "STQ_HEAD_IS_ARRIVAL");
    // every valid speculative entry names a live slot (the T35 assertion's condition)
    for (int i = 0; i < 4; i++)
      if (spec_valid_s[i]) check(spec_is5_s[i], "STQ_NO_GHOST");

    // S3: committing it hands its own address to the commit queue.
    commit = 1; commit_tid = 4'd5; tick(); clear_inputs(); #2;
    check(commit_cnt_s == 2 && commit_last_valid_s && commit_last_pa_s == 56'h8000_5000 && commit_last_tid_s == 4'd5,
          "STQ_COMMIT_IS_ARRIVAL");
    check(spec_cnt_s == 0 && ptr_agree(), "STQ_PTR_AGREE_FINAL");

    if (negative) $fatal(1, "ORACLE_NEGATIVE forced");
    $display("PASS tb_g6lc_stq_flush_ptr checked=%0d", checked);
    $finish;
  end
endmodule
