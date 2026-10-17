// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Side-by-side harness: the live `store_buffer` against a reference copy
// (`store_buffer_old`, a prior revision renamed) under the module's legal
// environment — no commit on an empty queue or an invalid head, no push into
// a full queue, unique live trans_ids — comparing every output each cycle
// (the head address is compared only while the speculative queue is live).
// Used for sv-timing A109 (one permutation for insertion + squash): 4 seeds x
// 400k cycles, 0 mismatches. See README.md for how to run it.
module tb_sb_sbs;
  import ariane_pkg::*;
  localparam config_pkg::cva6_cfg_t CVA6Cfg = build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);
  localparam type cbo_t = logic [7:0];
  typedef struct packed {
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
    cbo_t                                  cbo_op;
  } dcache_req_i_t;
  typedef struct packed {
    logic                                 data_gnt;
    logic                                 data_rvalid;
    logic [CVA6Cfg.DcacheIdWidth-1:0]     data_rid;
    logic [CVA6Cfg.XLEN-1:0]              data_rdata;
    logic [CVA6Cfg.DCACHE_USER_WIDTH-1:0] data_ruser;
  } dcache_req_o_t;
  logic clk = 1'b0, rst_ni = 1'b0;
  always #1 clk = ~clk;
  logic flush_i;
  logic [CVA6Cfg.NR_SB_ENTRIES-1:0] cancelled_mask_i;
  logic [CVA6Cfg.NR_SB_ENTRIES-1:0] sb_live_i;
  logic stall_st_pending_i;
  logic [11:0] page_offset_i;
  logic [CVA6Cfg.PLEN-1:0] load_paddr_i;
  logic load_paddr_valid_i;
  logic [CVA6Cfg.TRANS_ID_BITS-1:0] load_trans_id_i;
  logic [CVA6Cfg.TRANS_ID_BITS-1:0] commit_trans_id_i;
  logic [CVA6Cfg.TRANS_ID_BITS-1:0] oldest_live_tid_i;
  logic head_phys_pending_i;
  logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] load_hart_i;
  logic dcache_wbuffer_empty_i;
  logic commit_i;
  logic valid_i;
  logic valid_without_flush_i;
  logic [CVA6Cfg.PLEN-1:0] paddr_i;
  logic [CVA6Cfg.TRANS_ID_BITS-1:0] trans_id_i;
  logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] st_hart_i;
  logic [CVA6Cfg.XLEN-1:0] data_i;
  logic [(CVA6Cfg.XLEN/8)-1:0] be_i;
  logic [1:0] data_size_i;
  cbo_t cbo_op_i;
  dcache_req_o_t req_port_i;
  logic no_st_pending_o_old, no_st_pending_o_new;
  logic store_buffer_empty_o_old, store_buffer_empty_o_new;
  logic page_offset_matches_o_old, page_offset_matches_o_new;
  logic page_offset_spec_only_o_old, page_offset_spec_only_o_new;
  logic st_fwd_valid_o_old, st_fwd_valid_o_new;
  logic [CVA6Cfg.XLEN-1:0] st_fwd_data_o_old, st_fwd_data_o_new;
  logic [(CVA6Cfg.XLEN/8)-1:0] st_fwd_be_o_old, st_fwd_be_o_new;
  logic commit_ready_o_old, commit_ready_o_new;
  logic ready_o_old, ready_o_new;
  logic [CVA6Cfg.PLEN-1:0] rvfi_mem_paddr_o_old, rvfi_mem_paddr_o_new;
  dcache_req_i_t req_port_o_old, req_port_o_new;
  sb_wrap_old u_old (.clk_i(clk), .rst_ni(rst_ni), .flush_i(flush_i), .cancelled_mask_i(cancelled_mask_i), .sb_live_i(sb_live_i), .stall_st_pending_i(stall_st_pending_i), .page_offset_i(page_offset_i), .load_paddr_i(load_paddr_i), .load_paddr_valid_i(load_paddr_valid_i), .load_trans_id_i(load_trans_id_i), .commit_trans_id_i(commit_trans_id_i), .oldest_live_tid_i(oldest_live_tid_i), .head_phys_pending_i(head_phys_pending_i), .load_hart_i(load_hart_i), .dcache_wbuffer_empty_i(dcache_wbuffer_empty_i), .commit_i(commit_i), .valid_i(valid_i), .valid_without_flush_i(valid_without_flush_i), .paddr_i(paddr_i), .trans_id_i(trans_id_i), .st_hart_i(st_hart_i), .data_i(data_i), .be_i(be_i), .data_size_i(data_size_i), .cbo_op_i(cbo_op_i), .req_port_i(req_port_i), .no_st_pending_o(no_st_pending_o_old), .store_buffer_empty_o(store_buffer_empty_o_old), .page_offset_matches_o(page_offset_matches_o_old), .page_offset_spec_only_o(page_offset_spec_only_o_old), .st_fwd_valid_o(st_fwd_valid_o_old), .st_fwd_data_o(st_fwd_data_o_old), .st_fwd_be_o(st_fwd_be_o_old), .commit_ready_o(commit_ready_o_old), .ready_o(ready_o_old), .rvfi_mem_paddr_o(rvfi_mem_paddr_o_old), .req_port_o(req_port_o_old));
  sb_wrap_new u_new (.clk_i(clk), .rst_ni(rst_ni), .flush_i(flush_i), .cancelled_mask_i(cancelled_mask_i), .sb_live_i(sb_live_i), .stall_st_pending_i(stall_st_pending_i), .page_offset_i(page_offset_i), .load_paddr_i(load_paddr_i), .load_paddr_valid_i(load_paddr_valid_i), .load_trans_id_i(load_trans_id_i), .commit_trans_id_i(commit_trans_id_i), .oldest_live_tid_i(oldest_live_tid_i), .head_phys_pending_i(head_phys_pending_i), .load_hart_i(load_hart_i), .dcache_wbuffer_empty_i(dcache_wbuffer_empty_i), .commit_i(commit_i), .valid_i(valid_i), .valid_without_flush_i(valid_without_flush_i), .paddr_i(paddr_i), .trans_id_i(trans_id_i), .st_hart_i(st_hart_i), .data_i(data_i), .be_i(be_i), .data_size_i(data_size_i), .cbo_op_i(cbo_op_i), .req_port_i(req_port_i), .no_st_pending_o(no_st_pending_o_new), .store_buffer_empty_o(store_buffer_empty_o_new), .page_offset_matches_o(page_offset_matches_o_new), .page_offset_spec_only_o(page_offset_spec_only_o_new), .st_fwd_valid_o(st_fwd_valid_o_new), .st_fwd_data_o(st_fwd_data_o_new), .st_fwd_be_o(st_fwd_be_o_new), .commit_ready_o(commit_ready_o_new), .ready_o(ready_o_new), .rvfi_mem_paddr_o(rvfi_mem_paddr_o_new), .req_port_o(req_port_o_new));

  function automatic logic [255:0] rnd256();
    rnd256 = {$urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom, $urandom};
  endfunction
  // width-generic random value (packed types cast from a 256-bit vector)
  `define RND(sig, w) sig = (w)'(rnd256())

  int unsigned cyc = 0, errors = 0, pushes = 0, commits = 0, cancels = 0, flushes = 0, seed = 1;
  int unsigned pc_mode;
  initial begin
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    void'($urandom(seed));
    #7 rst_ni = 1'b1;
  end
  // drive inputs on the negative edge (settle before posedge)
  always @(negedge clk) begin
    logic [255:0] r;
    r = rnd256(); sb_live_i = $bits(sb_live_i)'(r);
    r = rnd256(); stall_st_pending_i = $bits(stall_st_pending_i)'(r);
    r = rnd256(); page_offset_i = $bits(page_offset_i)'(r);
    r = rnd256(); load_paddr_i = $bits(load_paddr_i)'(r);
    r = rnd256(); load_paddr_valid_i = $bits(load_paddr_valid_i)'(r);
    r = rnd256(); load_trans_id_i = $bits(load_trans_id_i)'(r);
    r = rnd256(); commit_trans_id_i = $bits(commit_trans_id_i)'(r);
    r = rnd256(); oldest_live_tid_i = $bits(oldest_live_tid_i)'(r);
    r = rnd256(); head_phys_pending_i = $bits(head_phys_pending_i)'(r);
    r = rnd256(); load_hart_i = $bits(load_hart_i)'(r);
    r = rnd256(); dcache_wbuffer_empty_i = $bits(dcache_wbuffer_empty_i)'(r);
    r = rnd256(); valid_without_flush_i = $bits(valid_without_flush_i)'(r);
    r = rnd256(); paddr_i = $bits(paddr_i)'(r);
    r = rnd256(); trans_id_i = $bits(trans_id_i)'(r);
    r = rnd256(); st_hart_i = $bits(st_hart_i)'(r);
    r = rnd256(); data_i = $bits(data_i)'(r);
    r = rnd256(); be_i = $bits(be_i)'(r);
    r = rnd256(); data_size_i = $bits(data_size_i)'(r);
    r = rnd256(); cbo_op_i = $bits(cbo_op_i)'(r);
    r = rnd256(); req_port_i = $bits(req_port_i)'(r);

    // sparse cancels, rare flushes; density varies by phase
    r = rnd256();
    pc_mode = cyc[11:9];
    cancelled_mask_i = (r[7:0] < 8'd40) ? ($bits(cancelled_mask_i)'(rnd256()) & $bits(cancelled_mask_i)'(rnd256())) : '0;
    if (pc_mode == 3) cancelled_mask_i = (r[15:8] < 8'd120) ? $bits(cancelled_mask_i)'(rnd256()) : '0;
    flush_i = (r[23:16] < 8'd6);
    // legal environment: no commit on an empty speculative queue
    commit_i = (r[31:24] < 8'd110) && (u_old.u.speculative_status_cnt_q != '0);
    // no push when not ready (ready_o depends on commit_i)
    #0.1;
    // room after this cycle's pop (the module's own ready_o counts the push
    // it is being asked about, so it cannot be sampled for the decision)
    begin
      logic can_push;
      can_push = (int'(u_old.u.speculative_status_cnt_q) - int'(commit_i)) < 4;
      valid_i = (r[39:32] < 8'd150) && can_push;
      if (pc_mode == 5) valid_i = (r[39:32] < 8'd250) && can_push;
    end
    // legal environment: a live tid is unique — pick the arrival's tid among
    // the tids not live in the queue (shadow set maintained below)
    begin
      int tries;
      logic [4:0] cand;
      cand = 5'(r[55:48] % 12);
      for (tries = 0; tries < 16 && live_tid[cand]; tries++) cand = 5'(($urandom % 12));
      trans_id_i = cand;
      if (live_tid[cand]) valid_i = 1'b0;
    end
    // legal environment: commit only a valid head
    if (commit_i && !u_old.u.speculative_queue_q[u_old.u.speculative_read_pointer_q].valid) commit_i = 1'b0;
    valid_without_flush_i = valid_i && !flush_i;
  end
  // shadow set of live tids (per the OLD model's own state)
  logic [31:0] live_tid = '0;
  always @(posedge clk) begin
    if (!rst_ni) live_tid <= '0;
    else begin
      logic [31:0] nxt;
      nxt = live_tid;
      if (commit_i) nxt[u_old.u.speculative_queue_q[u_old.u.speculative_read_pointer_q].trans_id] = 1'b0;
      nxt &= ~cancelled_mask_i;
      if (flush_i) nxt = '0;
      if (valid_i && !cancelled_mask_i[trans_id_i] && !flush_i) nxt[trans_id_i] = 1'b1;
      live_tid <= nxt;
    end
  end
  // the OLD model must itself stay consistent under this stimulus
  always @(posedge clk) if (rst_ni && u_old.u.speculative_status_cnt_q > 3'd4) begin
    $display("ILLEGAL cyc=%0d old cnt=%0d", cyc, u_old.u.speculative_status_cnt_q); $finish;
  end
  int unsigned dbg_from = 0, dbg_to = 0;
  initial begin
    void'($value$plusargs("dbg_from=%d", dbg_from));
    void'($value$plusargs("dbg_to=%d", dbg_to));
  end
  function automatic string qdump(input logic [3:0] v, input logic [3:0][4:0] t, input logic [1:0] rp, input logic [1:0] wp, input logic [2:0] cnt);
    qdump = $sformatf("v=%b tids=%0d,%0d,%0d,%0d rp=%0d wp=%0d cnt=%0d", v, t[0], t[1], t[2], t[3], rp, wp, cnt);
  endfunction
  always @(posedge clk) begin
    if (rst_ni && cyc >= dbg_from && cyc <= dbg_to) begin
      logic [3:0] vo, vn; logic [3:0][4:0] to, tn;
      for (int i = 0; i < 4; i++) begin
        vo[i] = u_old.u.speculative_queue_q[i].valid; to[i] = u_old.u.speculative_queue_q[i].trans_id;
        vn[i] = u_new.u.speculative_queue_q[i].valid; tn[i] = u_new.u.speculative_queue_q[i].trans_id;
      end
      $display("DBG cyc=%0d in: valid=%b tid=%0d commit=%b flush=%b cancel=%h oldest=%0d | OLD %s | NEW %s", cyc, valid_i, trans_id_i, commit_i, flush_i, cancelled_mask_i, oldest_live_tid_i,
        qdump(vo, to, u_old.u.speculative_read_pointer_q, u_old.u.speculative_write_pointer_q, u_old.u.speculative_status_cnt_q),
        qdump(vn, tn, u_new.u.speculative_read_pointer_q, u_new.u.speculative_write_pointer_q, u_new.u.speculative_status_cnt_q));
    end
    if (rst_ni) begin
      cyc++;
      if (valid_i) pushes++;
      if (commit_i) commits++;
      if (|cancelled_mask_i) cancels++;
      if (flush_i) flushes++;
      #0.2;
        if (no_st_pending_o_old !== no_st_pending_o_new && !("no_st_pending_o" == "rvfi_mem_paddr_o" && u_old.u.speculative_status_cnt_q == '0)) begin
          $display("MISMATCH cyc=%0d no_st_pending_o old=%h new=%h", cyc, no_st_pending_o_old, no_st_pending_o_new); errors++;
        end
        if (store_buffer_empty_o_old !== store_buffer_empty_o_new && !("store_buffer_empty_o" == "rvfi_mem_paddr_o" && u_old.u.speculative_status_cnt_q == '0)) begin
          $display("MISMATCH cyc=%0d store_buffer_empty_o old=%h new=%h", cyc, store_buffer_empty_o_old, store_buffer_empty_o_new); errors++;
        end
        if (page_offset_matches_o_old !== page_offset_matches_o_new && !("page_offset_matches_o" == "rvfi_mem_paddr_o" && u_old.u.speculative_status_cnt_q == '0)) begin
          $display("MISMATCH cyc=%0d page_offset_matches_o old=%h new=%h", cyc, page_offset_matches_o_old, page_offset_matches_o_new); errors++;
        end
        if (page_offset_spec_only_o_old !== page_offset_spec_only_o_new && !("page_offset_spec_only_o" == "rvfi_mem_paddr_o" && u_old.u.speculative_status_cnt_q == '0)) begin
          $display("MISMATCH cyc=%0d page_offset_spec_only_o old=%h new=%h", cyc, page_offset_spec_only_o_old, page_offset_spec_only_o_new); errors++;
        end
        if (st_fwd_valid_o_old !== st_fwd_valid_o_new && !("st_fwd_valid_o" == "rvfi_mem_paddr_o" && u_old.u.speculative_status_cnt_q == '0)) begin
          $display("MISMATCH cyc=%0d st_fwd_valid_o old=%h new=%h", cyc, st_fwd_valid_o_old, st_fwd_valid_o_new); errors++;
        end
        if (st_fwd_data_o_old !== st_fwd_data_o_new && !("st_fwd_data_o" == "rvfi_mem_paddr_o" && u_old.u.speculative_status_cnt_q == '0)) begin
          $display("MISMATCH cyc=%0d st_fwd_data_o old=%h new=%h", cyc, st_fwd_data_o_old, st_fwd_data_o_new); errors++;
        end
        if (st_fwd_be_o_old !== st_fwd_be_o_new && !("st_fwd_be_o" == "rvfi_mem_paddr_o" && u_old.u.speculative_status_cnt_q == '0)) begin
          $display("MISMATCH cyc=%0d st_fwd_be_o old=%h new=%h", cyc, st_fwd_be_o_old, st_fwd_be_o_new); errors++;
        end
        if (commit_ready_o_old !== commit_ready_o_new && !("commit_ready_o" == "rvfi_mem_paddr_o" && u_old.u.speculative_status_cnt_q == '0)) begin
          $display("MISMATCH cyc=%0d commit_ready_o old=%h new=%h", cyc, commit_ready_o_old, commit_ready_o_new); errors++;
        end
        if (ready_o_old !== ready_o_new && !("ready_o" == "rvfi_mem_paddr_o" && u_old.u.speculative_status_cnt_q == '0)) begin
          $display("MISMATCH cyc=%0d ready_o old=%h new=%h", cyc, ready_o_old, ready_o_new); errors++;
        end
        if (rvfi_mem_paddr_o_old !== rvfi_mem_paddr_o_new && !("rvfi_mem_paddr_o" == "rvfi_mem_paddr_o" && u_old.u.speculative_status_cnt_q == '0)) begin
          $display("MISMATCH cyc=%0d rvfi_mem_paddr_o old=%h new=%h", cyc, rvfi_mem_paddr_o_old, rvfi_mem_paddr_o_new); errors++;
        end
        if (req_port_o_old !== req_port_o_new && !("req_port_o" == "rvfi_mem_paddr_o" && u_old.u.speculative_status_cnt_q == '0)) begin
          $display("MISMATCH cyc=%0d req_port_o old=%h new=%h", cyc, req_port_o_old, req_port_o_new); errors++;
        end
      if (errors > 5) begin
        $display("FAIL tb_sb_sbs cyc=%0d errors=%0d", cyc, errors);
        $finish;
      end
      if (cyc == 400000) begin
        $display("%s tb_sb_sbs cycles=%0d pushes=%0d commits=%0d cancels=%0d flushes=%0d errors=%0d",
                 errors == 0 ? "PASS" : "FAIL", cyc, pushes, commits, cancels, flushes, errors);
        $finish;
      end
    end
  end
endmodule
