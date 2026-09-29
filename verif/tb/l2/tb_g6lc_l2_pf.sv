// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// tb_g6lc_l2_pf — leaf coverage for the T9h/M5 L2 stream/stride prefetcher
// (g6lc_l2_pf + its admission path inside g6lc_l2_top).
//
// Part A drives the stream engine directly: allocation on first miss,
// retrain on the first delta, arm on the second equal delta, at most one
// outstanding candidate, and the 4 KiB page boundary.
//
// Part B runs a real g6lc_l2_top (PF_EN=1, POSTED_WRITES=1) against a
// programmable-latency memory: a committed candidate becomes a pf-flagged
// fill that installs like a demand fill, a demand read of a PF-installed
// line reports useful and issues no new fill AR, and the admission drops
// fire for resident lines, in-flight fills, tracked writes (R1) and the
// MSHR reserve. The reserve-removal mutation is caught by phase B2
// (L2PF_RESERVE). A same-line write killing an in-flight PF fill must
// force a later refetch (B6).

`timescale 1ns/1ps

module tb_g6lc_l2_pf;
  import g6lc_l2_tb_pkg::*;

  localparam int unsigned LINE = 64;          // bytes (LINE_WIDTH=512)
  // Programmable fill latency (raised in B5 to keep a demand fill in flight
  // across the pf probe).
  int unsigned mem_latency = 6;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  // ---------------- Part A: stream engine ---------------------------------
  logic              eng_train;
  addr_t             eng_train_line;
  logic              eng_cand_v;
  addr_t             eng_cand_line;
  logic              eng_take;

  g6lc_l2_pf #(
      .AXI_ADDR_WIDTH(AW), .LINE_BYTES(64), .NR_STREAMS(4),
      .PF_DISTANCE(2), .STRIDE_EN(1'b1)
  ) eng (
      .clk_i(clk), .rst_ni(rst_n),
      .train_i      (eng_train),
      .train_line_i (eng_train_line),
      .cand_valid_o (eng_cand_v),
      .cand_line_o  (eng_cand_line),
      .cand_take_i  (eng_take)
  );

  task automatic eng_miss(input addr_t a);
    @(negedge clk);
    eng_train      = 1'b1;
    eng_train_line = a;
    @(negedge clk);
    eng_train      = 1'b0;
  endtask

  // Take the pending candidate if it is the one expected.
  task automatic eng_expect(input addr_t want);
    int unsigned g = 0;
    while (!eng_cand_v && g < 200) begin @(posedge clk); g++; end
    if (!eng_cand_v) $fatal(1, "L2PF_NO_CAND want=%h", want);
    if (eng_cand_line != want)
      $fatal(1, "L2PF_CAND_ADDR got=%h want=%h", eng_cand_line, want);
    @(negedge clk);
    eng_take = 1'b1;
    @(negedge clk);
    eng_take = 1'b0;
  endtask

  // ---------------- Part B: g6lc_l2_top + mini DRAM ------------------------
  req_t  slv_req;
  resp_t slv_resp;
  req_t  mst_req;
  resp_t mst_resp;

  logic pf_issue_p, pf_useful_p, pf_drop_p;
  int unsigned pf_issue = 0, pf_useful = 0, pf_drop = 0;
  always_ff @(posedge clk) if (rst_n) begin
    if (pf_issue_p)  pf_issue  <= pf_issue + 1;
    if (pf_useful_p) pf_useful <= pf_useful + 1;
    if (pf_drop_p)   pf_drop   <= pf_drop + 1;
  end

  `ifdef L2PF_TRACE
  always @(posedge clk) if (rst_n) begin
    if (pf_issue_p)  $display("[%0t] PF_ISSUE %h", $time, dut.gen_l2.pf_addr_q);
    if (pf_drop_p)   $display("[%0t] PF_DROP %h hit=%b mlh=%b wtrk=%b mcnt=%0d wayok=%b",
                              $time, dut.gen_l2.pf_addr_q, dut.gen_l2.tag_hit,
                              dut.gen_l2.mshr_lookup_hit, dut.gen_l2.wtrk_line0_match,
                              dut.gen_l2.mshr_count, dut.gen_l2.pf_way_ok);
    if (pf_useful_p) $display("[%0t] PF_USEFUL", $time);
    if (mst_req.ar_valid && mst_resp.ar_ready)
      $display("[%0t] MST_AR id=%0d addr=%h", $time, mst_req.ar.id, mst_req.ar.addr);
    if ($time > 3950)
      $display("[%0t] CNT st=%0d rd=%0d wr=%0d fcnt=%0d icnt=%0d ccnt=%0d cact=%b arv=%b arr=%b rv=%b rid=%0d pfret=%b",
               $time, dut.gen_l2.state_q, dut.gen_l2.fifo_rd_q, dut.gen_l2.fifo_wr_q,
               dut.gen_l2.fifo_cnt_q, dut.gen_l2.issued_cnt_q, dut.gen_l2.collect_cnt_q,
               dut.gen_l2.collect_active, mst_req.ar_valid, mst_resp.ar_ready,
               mst_resp.r_valid, mst_resp.r.id, dut.gen_l2.pf_retire);
    if (mst_resp.r_valid && mst_resp.r.id == 4'd15)
      $display("[%0t] FILL_BEAT last=%b cact=%b cidx=%0d ccnt=%0d icnt=%0d fcnt=%0d rd=%0d",
               $time, mst_resp.r.last,
               dut.gen_l2.collect_active, dut.gen_l2.collect_idx,
               dut.gen_l2.collect_cnt_q, dut.gen_l2.issued_cnt_q,
               dut.gen_l2.fifo_cnt_q, dut.gen_l2.fifo_rd_q);
    if (pf_issue_p == 0 && pf_drop_p == 0 && pf_useful_p == 0 &&
        dut.gen_l2.pf_probe_q)
      $display("[%0t] PF_PROBE_ARMED %h state=%0d", $time,
               dut.gen_l2.pf_addr_q, dut.gen_l2.state_q);
  end
  `endif

  g6lc_l2_top #(
      .Enable(1'b1), .BYTE_SIZE(4096), .SET_ASSOC(4), .LINE_WIDTH(512),
      .MSHR_DEPTH(8), .DATA_BANKS(2),
      .POSTED_WRITES(1'b1), .WTRK_DEPTH(4), .RDTRK_DEPTH(4),
      .PF_EN(1'b1), .PF_STREAMS(4), .PF_DISTANCE(2), .PF_STRIDE(1'b1),
      .PF_MSHR_RESERVE(1),
      .AXI_ADDR_WIDTH(AW), .AXI_DATA_WIDTH(DW),
      .AXI_ID_WIDTH(IDW), .AXI_USER_WIDTH(UW),
      .axi_req_t(req_t), .axi_resp_t(resp_t)
  ) dut (
      .clk_i(clk), .rst_ni(rst_n),
      .slv_req_i(slv_req), .slv_resp_o(slv_resp),
      .mst_req_o(mst_req), .mst_resp_i(mst_resp),
      .l2_hit_o(), .l2_miss_o(), .l2_bypass_o(), .l2_mshr_full_o(),
      .l2_bank_conflict_o(), .l2_selfinv_hit_o(), .l2_wupdate_o(),
      .l2_wtrk_full_o(), .l2_wtrk_line_hold_o(),
      .l2_hold_r1_o(), .l2_hold_r1_wu_o(), .l2_hold_r2_o(),
      .l2_posted_o(), .l2_rdtrk_o(), .l2_posted_hold_o(),
      .l2_pf_issue_o(pf_issue_p), .l2_pf_useful_o(pf_useful_p),
      .l2_pf_drop_o(pf_drop_p),
      .l2_evict_valid_o(), .l2_evict_addr_o(), .l2_evict_ready_i(1'b1),
      .l2_back_inval_valid_i(1'b0), .l2_back_inval_addr_i('0),
      .l2_back_inval_ready_o(), .l2_write_idle_o()
  );

  // ---- reference memory: sparse map over an address hash ------------------
  bit [63:0] mem [longint unsigned];
  function automatic data_t ref_word(input addr_t a);
    if (mem.exists(a >> 3)) return mem[a >> 3];
    return data_t'((a >> 3) * 64'h9E37_79B9_7F4A_7C15 ^ 64'h5DEE_CE6B_1357_0F0F);
  endfunction
  task automatic mem_patch(input addr_t a, input data_t d, input strb_t s);
    data_t cur = ref_word(a);
    for (int b = 0; b < 8; b++) if (s[b]) cur[b*8 +: 8] = d[b*8 +: 8];
    mem[a >> 3] = cur;
  endtask

  // ---- mini DRAM: queued read bursts, immediate write apply, held B ------
  localparam int RD_DEPTH = 16;
  typedef struct packed {
    addr_t       addr;
    id_t         id;
    logic [7:0]  len;
    int unsigned beat;
    int unsigned delay;
  } rjob_t;
  rjob_t rjobs[RD_DEPTH];
  int unsigned rd_head = 0, rd_tail = 0, rd_count = 0;
  int unsigned mem_ar_count = 0, w_completed = 0;
  logic memory_hold = 1'b0, memory_b_hold = 1'b0;
  // Pending B responses (id) — memory returns B only when not held.
  id_t bpend[$];
  typedef struct packed { addr_t addr; strb_t strb; } wpend_t;
  wpend_t wpending[$];
  logic wr_active = 1'b0;
  addr_t wr_addr;
  int unsigned wr_beat;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mst_resp <= '0;
      rd_head = 0; rd_tail = 0; rd_count = 0;
      mem_ar_count = 0;
      for (int i = 0; i < RD_DEPTH; i++) rjobs[i] = '0;
    end else begin
      automatic bit take_ar = mst_req.ar_valid && mst_resp.ar_ready;
      for (int i = 0; i < RD_DEPTH; i++)
        if (rjobs[i].delay != 0) rjobs[i].delay--;
      if (!mst_resp.r_valid || mst_req.r_ready) begin
        mst_resp.r_valid <= 1'b0;
        if (rd_count != 0 && rjobs[rd_head].delay == 0 && !memory_hold) begin
          mst_resp.r_valid <= 1'b1;
          mst_resp.r.id    <= rjobs[rd_head].id;
          mst_resp.r.resp  <= axi_pkg::RESP_OKAY;
          mst_resp.r.data  <= ref_word(rjobs[rd_head].addr +
                                       addr_t'(rjobs[rd_head].beat * 8));
          mst_resp.r.last  <= (rjobs[rd_head].beat == int'(rjobs[rd_head].len));
          if (rjobs[rd_head].beat == int'(rjobs[rd_head].len)) begin
            rd_head = (rd_head + 1) % RD_DEPTH; rd_count--;
          end else rjobs[rd_head].beat++;
        end
      end
      if (take_ar) begin
        if (rd_count >= RD_DEPTH) $fatal(1, "L2PF_MEM_OVERFLOW");
        rjobs[rd_tail] = '{addr: mst_req.ar.addr, id: mst_req.ar.id,
                           len: mst_req.ar.len, beat: 0, delay: mem_latency};
        rd_tail = (rd_tail + 1) % RD_DEPTH; rd_count++;
        mem_ar_count++;
      end
      mst_resp.ar_ready <= (rd_count < RD_DEPTH);
      // Write channel: AW handshake, then W beats apply to memory as they
      // arrive; the B response waits for the last beat (and b_hold).
      mst_resp.aw_ready <= !wr_active;
      if (mst_req.aw_valid && mst_resp.aw_ready) begin
        wr_active = 1'b1;
        wr_addr   = mst_req.aw.addr;
        wr_beat   = 0;
        bpend.push_back(mst_req.aw.id);
      end
      mst_resp.w_ready <= wr_active;
      if (wr_active && mst_req.w_valid && mst_resp.w_ready) begin
        mem_patch(wr_addr + addr_t'(wr_beat * 8), mst_req.w.data,
                  mst_req.w.strb);
        wr_beat++;
        if (mst_req.w.last) wr_active = 1'b0;
      end
      if (!mst_resp.b_valid || mst_req.b_ready) begin
        mst_resp.b_valid <= 1'b0;
        if (bpend.size() != 0 && !wr_active && !memory_b_hold) begin
          mst_resp.b_valid <= 1'b1;
          mst_resp.b.id    <= bpend[0];
          mst_resp.b.resp  <= axi_pkg::RESP_OKAY;
          void'(bpend.pop_front());
        end
      end
    end
  end

  // ---- slave-side read driver + data scoreboard ---------------------------
  typedef struct { id_t id; addr_t addr; } stim_t;
  stim_t pending[$];
  stim_t expected[16][32];
  int unsigned exp_head[16], exp_tail[16], beats_seen[16];
  int unsigned requested = 0, completed = 0, slv_b_seen = 0;
  bit negative;

  task automatic push(input id_t id, input addr_t a);
    stim_t s;
    s.id = id; s.addr = a;
    pending.push_back(s);
    requested++;
  endtask

  stim_t s;
  initial begin
    slv_req = '0;
    slv_req.r_ready = 1'b1;
    slv_req.b_ready = 1'b1;
    @(posedge rst_n);
    forever begin
      @(negedge clk);
      if (pending.size() != 0) begin
        s = pending[0];
        slv_req.ar_valid = 1'b1;
        slv_req.ar.id    = s.id;
        slv_req.ar.addr  = s.addr;
        slv_req.ar.len   = 8'd0;
        slv_req.ar.size  = 3'd3;
        slv_req.ar.burst = 2'b01;
        slv_req.ar.cache = 4'hf;
        do @(posedge clk); while (!slv_resp.ar_ready);
        if (exp_tail[s.id] >= 32) $fatal(1, "L2PF_EXPECTED_CAP");
        expected[s.id][exp_tail[s.id]] = s;
        exp_tail[s.id]++;
        void'(pending.pop_front());
        @(negedge clk);
        slv_req.ar_valid = 1'b0;
      end
    end
  end

  always_ff @(posedge clk) if (rst_n) begin
    if (slv_resp.r_valid && slv_req.r_ready) begin
      automatic id_t rid = slv_resp.r.id;
      automatic data_t want;
      if (exp_head[rid] >= exp_tail[rid]) begin
        $display("L2PF_BAD_ID id=%0d data=%h last=%b state=%0d fifo_cnt=%0d pf_issue=%0d pf_drop=%0d pf_probe=%b pf_addr=%h",
                 rid, slv_resp.r.data, slv_resp.r.last, dut.gen_l2.state_q,
                 dut.gen_l2.fifo_cnt_q, pf_issue, pf_drop,
                 dut.gen_l2.pf_probe_q, dut.gen_l2.pf_addr_q);
        for (int e = 0; e < 8; e++)
          $display("  fill[%0d] act=%b st=%0d addr=%h pf=%b kill=%b",
                   e, dut.gen_l2.fill_act_q[e], dut.gen_l2.fill_state_q[e],
                   dut.gen_l2.fill_addr_q[e], dut.gen_l2.fill_pf_q[e],
                   dut.gen_l2.fill_kill_q[e]);
        for (int e = 0; e < 8; e++)
          $display("  fifo[%0d]=%0d", e, dut.gen_l2.fifo_q[e]);
        $display("  rd=%0d wr=%0d ccnt=%0d icnt=%0d collect_active=%b cidx=%0d",
                 dut.gen_l2.fifo_rd_q, dut.gen_l2.fifo_wr_q,
                 dut.gen_l2.collect_cnt_q, dut.gen_l2.issued_cnt_q,
                 dut.gen_l2.collect_active, dut.gen_l2.collect_idx);
        $fatal(1, "L2PF_BAD_ID id=%0d", rid);
      end
      want = ref_word(expected[rid][exp_head[rid]].addr +
                      addr_t'(beats_seen[rid] * 8));
      if (negative) want ^= 64'd1;
      if (slv_resp.r.data !== want)
        $fatal(1, "L2PF_DATA id=%0d got=%h want=%h", rid, slv_resp.r.data, want);
      if (slv_resp.r.last !== 1'b1) $fatal(1, "L2PF_LAST");
      completed++; exp_head[rid]++;
    end
    if (slv_resp.b_valid && slv_req.b_ready) w_completed++;
  end

  task automatic wait_done(input int unsigned limit = 4000);
    int unsigned g = 0;
    while (completed != requested && g < limit) begin @(posedge clk); g++; end
    if (g >= limit) $fatal(1, "L2PF_TIMEOUT done=%0d of %0d", completed, requested);
  endtask

  // Single-beat write (posted → WR_ID); returns after the W beat.
  task automatic send_write(input id_t id, input addr_t a, input data_t d);
    @(negedge clk);
    slv_req.aw = '{id: id, addr: a, len: 8'd0, size: 3'd3,
                   burst: axi_pkg::BURST_INCR, atop: 6'h00, cache: 4'hf,
                   lock: 1'b0, default: '0};
    slv_req.aw_valid = 1'b1;
    do @(posedge clk); while (!slv_resp.aw_ready);
    @(negedge clk);
    slv_req.aw_valid = 1'b0;
    slv_req.w = '{data: d, strb: '1, last: 1'b1, user: '0};
    slv_req.w_valid = 1'b1;
    do @(posedge clk); while (!slv_resp.w_ready);
    @(negedge clk);
    slv_req.w_valid = 1'b0;
  endtask

  // Bounded wait helpers.
  task automatic wait_issue(input int unsigned want, input int unsigned limit = 400);
    int unsigned g = 0;
    while (pf_issue < want && g < limit) begin @(posedge clk); g++; end
    if (pf_issue < want) $fatal(1, "L2PF_NO_ISSUE issue=%0d want=%0d",
                                pf_issue, want);
  endtask
  task automatic wait_drop(input int unsigned want, input int unsigned limit = 400);
    int unsigned g = 0;
    while (pf_drop < want && g < limit) begin @(posedge clk); g++; end
    if (pf_drop < want) $fatal(1, "L2PF_NO_DROP drop=%0d want=%0d",
                               pf_drop, want);
  endtask
  task automatic wait_mshr_empty(input int unsigned limit = 2000);
    int unsigned g = 0;
    while (!dut.gen_l2.mshr_empty && g < limit) begin @(posedge clk); g++; end
    if (!dut.gen_l2.mshr_empty) $fatal(1, "L2PF_FILL_STUCK");
  endtask
  task automatic wait_ar(input int unsigned want, input int unsigned limit = 400);
    int unsigned g = 0;
    while (mem_ar_count < want && g < limit) begin @(posedge clk); g++; end
    if (mem_ar_count < want) $fatal(1, "L2PF_NO_FILL_AR");
  endtask

  // -----------------------------------------------------------------------
  initial begin
    int unsigned m;
    for (int i = 0; i < 16; i++) begin
      exp_head[i] = 0; exp_tail[i] = 0; beats_seen[i] = 0;
    end
    negative = $test$plusargs("oracle_negative");
    eng_train = 1'b0; eng_train_line = '0; eng_take = 1'b0;
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);

    // ---------------- Part A: stream engine -------------------------------
    // A1: next-line stream — first miss allocates, second trains the delta,
    // third arms it; candidates emit one at a time and hold until taken.
    eng_miss(64'h60000);
    if (eng_cand_v) $fatal(1, "L2PF_EARLY_CAND");
    eng_miss(64'h60040);
    if (eng_cand_v) $fatal(1, "L2PF_TRAIN_ISSUE");
    eng_miss(64'h60080);
    eng_expect(64'h600C0);
    eng_expect(64'h60100);
    if (eng_cand_v) $fatal(1, "L2PF_EXTRA_CAND");

    // A2: stride != 1 — misses 2 lines apart arm stride +2.
    eng_miss(64'h68000);
    eng_miss(64'h68080);
    eng_miss(64'h68100);
    eng_expect(64'h68180);
    eng_expect(64'h68200);

    // A3: 4 KiB page boundary — armed at the page tail; both candidates
    // land in the next page and are dropped inside the engine.
    eng_miss(64'h62F00);
    eng_miss(64'h62F80);
    eng_miss(64'h62FC0);
    repeat (16) @(posedge clk);
    if (eng_cand_v) $fatal(1, "L2PF_PAGE_CROSS cand=%h", eng_cand_line);

    // A4: retrain — a delta change drops the not-yet-offered pending burst;
    // an already-offered candidate stays offered (the engine never retracts
    // one), and the new stride must re-confirm before issuing again.
    eng_miss(64'h6A000);
    eng_miss(64'h6A040);
    eng_miss(64'h6A080);    // armed (+1): 6A0C0 offered
    eng_expect(64'h6A0C0);  // take — 6A100 is emitted next
    eng_expect(64'h6A100);
    eng_miss(64'h6A180);    // delta +4: retrain, pending burst cleared
    repeat (8) @(posedge clk);
    if (eng_cand_v) $fatal(1, "L2PF_STALE_CAND cand=%h", eng_cand_line);
    eng_miss(64'h6A280);    // +4 lines confirmed -> arm
    eng_expect(64'h6A380);  // last + stride(4 lines) = 0x6A280 + 0x100
    eng_expect(64'h6A480);

    // ---------------- Part B: L2 admission --------------------------------
    // B1: train at the L2 — demand misses at +0/+40/+80 arm the stream; two
    // PF fills issue, install, and the demand reads then hit them with a
    // useful pulse and no new fill AR.
    push(4'd1, 64'h70000); wait_done();
    push(4'd1, 64'h70040); wait_done();
    push(4'd1, 64'h70080); wait_done();
    wait_issue(2);
    wait_mshr_empty();
    m = mem_ar_count;
    push(4'd2, 64'h700C0); wait_done();
    push(4'd2, 64'h70100); wait_done();
    if (pf_useful != 2) $fatal(1, "L2PF_NO_USEFUL useful=%0d", pf_useful);
    if (mem_ar_count != m) $fatal(1, "L2PF_USEFUL_REFETCH ar=%0d", mem_ar_count - m);

    // B2: MSHR reserve — pin the DRAM R channel and hold seven demand fills
    // in flight (depth 8, reserve 1): both armed candidates must drop, the
    // last slot stays demand-owned. Removing the reserve lets a pf take it —
    // pf_issue grows (L2PF_RESERVE) and the eighth demand then stalls behind
    // a full MSHR (L2PF_NO_FILL_AR).
    memory_hold = 1'b1;
    m = mem_ar_count;
    push(4'd1, 64'h78000);   // p78: new stream        (count 1)
    push(4'd1, 64'h79000);   // p79: new               (count 2)
    push(4'd1, 64'h7A000);   // p7A: new               (count 3)
    push(4'd1, 64'h7B000);   // p7B: new               (count 4)
    push(4'd1, 64'h78040);   // p78: delta seen        (count 5)
    push(4'd1, 64'h7A040);   // p7A: delta seen        (count 6)
    push(4'd1, 64'h78080);   // p78: armed             (count 7)
    wait_ar(m + 7);
    begin
      automatic int unsigned issue_mark = pf_issue;
      automatic int unsigned drop_mark  = pf_drop;
      automatic int unsigned g = 0;
      while (pf_issue == issue_mark && pf_drop < drop_mark + 2 && g < 400) begin
        @(posedge clk); g++;
      end
      if (pf_issue != issue_mark)
        $fatal(1, "L2PF_RESERVE issue grew under reserve window (%0d -> %0d)",
               issue_mark, pf_issue);
      if (pf_drop < drop_mark + 2)
        $fatal(1, "L2PF_NO_DROP drop=%0d", pf_drop - drop_mark);
    end
    // Demand still owns the last MSHR entry: an eighth miss commits and
    // queues a fill AR even while the R channel is pinned.
    push(4'd1, 64'h78140);
    wait_ar(m + 8);        // mutation: demand stalls -> L2PF_NO_FILL_AR
    memory_hold = 1'b0;
    wait_done();

    // B3: resident drop — install two same-page lines by demand, then arm a
    // stream whose candidates are those resident lines; both probes drop.
    push(4'd1, 64'h71AC0); wait_done();
    push(4'd1, 64'h71B00); wait_done();   // resident (stream: page 0x71)
    push(4'd1, 64'h71A00); wait_done();   // retrain
    push(4'd1, 64'h71A40); wait_done();
    push(4'd1, 64'h71A80); wait_done();   // armed (+1): cands 71AC0/71B00
    wait_drop(4);                          // B2's two + two resident drops
    if (pf_issue != 2) $fatal(1, "L2PF_RESIDENT_ISSUE issue=%0d", pf_issue);

    // B4: R1 tracked write — a posted write whose B is held keeps its wtrk
    // entry live; the candidate covering that line must drop, not hold.
    memory_b_hold = 1'b1;
    send_write(4'd6, 64'h720C0, 64'hdead_beef_cafe_f00d);
    push(4'd1, 64'h72000); wait_done();
    push(4'd1, 64'h72040); wait_done();
    push(4'd1, 64'h72080); wait_done();   // armed: cands 720C0/72100
    wait_drop(5);            // + the tracked-write drop
    wait_issue(3);           // the +72100 candidate still issues
    memory_b_hold = 1'b0;
    while (w_completed != 1) @(negedge clk);
    wait_done();
    push(4'd7, 64'h720C0); wait_done();  // post-write data (oracle checks)

    // B5: in-flight drop — a demand fill already sitting in the MSHR for
    // the candidate's line drops it; no duplicate fill AR is queued.
    mem_latency = 14;
    m = mem_ar_count;
    push(4'd1, 64'h730C0);  // demand fill of the future candidate's line
    wait_ar(m + 1);
    push(4'd1, 64'h73000);  // same-page stream: retrain
    push(4'd1, 64'h73040);
    push(4'd1, 64'h73080);  // armed (+1): cand 730C0 probes the in-flight fill
    wait_drop(6);
    wait_issue(4);          // cand 73100 still issues
    mem_latency = 6;
    wait_done();

    // B6: same-line write kills an in-flight PF fill — install_discard
    // applies, a later read refetches post-write data. The write must land
    // AFTER the 740C0 candidate's fill is queued (issue #6): earlier, the
    // candidate just hits the tracked write and drops under R1.
    push(4'd1, 64'h74000); wait_done();
    memory_hold = 1'b1;
    push(4'd1, 64'h74040);  // held fill
    push(4'd1, 64'h74080);  // arm — cand 740C0 issues, fill held too
    wait_issue(6);
    send_write(4'd3, 64'h740C8, 64'hc001_c0de_5eed_5eed);
    while (w_completed != 2) @(negedge clk);
    memory_hold = 1'b0;
    wait_done();
    wait_mshr_empty();
    m = mem_ar_count;
    push(4'd4, 64'h740C0); wait_done();  // killed fill installed nothing
    wait_mshr_empty();
    repeat (40) @(posedge clk);          // let the retrained follow-on PF drain
    // +1 refetch AR on the killed line; +1 fill AR from the follow-on
    // candidate (74140) the refetch's train pulse re-armed.
    if (mem_ar_count != m + 2)
      $fatal(1, "L2PF_KILL_INSTALL ar=%0d", mem_ar_count - m);

    $display("L2PF_METRICS issue=%0d useful=%0d drop=%0d", pf_issue, pf_useful, pf_drop);
    $display("RTL_REVIEW_PASS l2_pf");
    $finish;
  end

  // Global watchdog.
  initial begin
    repeat (200000) @(posedge clk);
    $fatal(1, "L2PF_GLOBAL_TIMEOUT");
  end
endmodule
