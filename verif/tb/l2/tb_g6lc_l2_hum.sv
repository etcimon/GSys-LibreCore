// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// tb_g6lc_l2_hum — hit-under-miss contract for g6lc_l2_top.
//
// The base bench (tb_g6lc_l2) drives strictly one outstanding slave AR at a
// time, so it cannot observe same-line merging at all. This bench issues
// concurrent reads and checks the contract that matters:
//   * a further cacheable read to the line currently being filled is accepted
//     and parked as an MSHR waiter (observed directly, not inferred),
//   * every requester gets its OWN beats back (its addr/len/size, not the
//     primary's) with its own AXI id,
//   * one DRAM fill serves all of them,
//   * requests that must NOT merge (other line / non-cacheable / locked) are
//     refused while the fill is outstanding and served correctly afterwards.
//
// Data returned is checked against an independent reference function, never
// against the DUT's own state.

`timescale 1ns/1ps

module tb_g6lc_l2_hum;
  import g6lc_l2_pkg::*;
  import g6lc_l2_tb_pkg::*;

  parameter int unsigned BYTE_SIZE   = 4096;
  parameter int unsigned SET_ASSOC   = 4;
  parameter int unsigned LINE_WIDTH  = 512;
  parameter int unsigned MSHR_DEPTH  = 4;
  parameter int unsigned DATA_BANKS  = 2;
  parameter int unsigned MEM_LATENCY = 8;
  parameter int unsigned MAX_WAITERS = 4;   // mirrors the DUT instantiation

  localparam int unsigned LINE_BYTES = LINE_WIDTH / 8;
  localparam int unsigned BEATS      = LINE_WIDTH / DW;
  localparam int unsigned OFF_BITS   = l2_offset_bits(LINE_WIDTH);

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  req_t  slv_req;
  resp_t slv_resp;
  req_t  mst_req;
  resp_t mst_resp;

  logic l2_hit, l2_miss, l2_bypass, l2_mshr_full, l2_bank_conf, evict_v;
  addr_t evict_addr;
  logic back_inval_ready;

  g6lc_l2_top #(
      .Enable      (1'b1),
      .BYTE_SIZE   (BYTE_SIZE),
      .SET_ASSOC   (SET_ASSOC),
      .LINE_WIDTH  (LINE_WIDTH),
      .MSHR_DEPTH  (MSHR_DEPTH),
      .DATA_BANKS  (DATA_BANKS),
      .RR_EN       (1'b0),
      .AXI_ADDR_WIDTH (AW),
      .AXI_DATA_WIDTH (DW),
      .AXI_ID_WIDTH   (IDW),
      .AXI_USER_WIDTH (UW),
      .axi_req_t   (req_t),
      .axi_resp_t  (resp_t)
  ) dut (
      .clk_i (clk),
      .rst_ni(rst_n),
      .slv_req_i  (slv_req),
      .slv_resp_o (slv_resp),
      .mst_req_o  (mst_req),
      .mst_resp_i (mst_resp),
      .l2_hit_o           (l2_hit),
      .l2_miss_o          (l2_miss),
      .l2_bypass_o        (l2_bypass),
      .l2_mshr_full_o     (l2_mshr_full),
      .l2_bank_conflict_o (l2_bank_conf),
      .l2_evict_valid_o   (evict_v),
      .l2_evict_addr_o    (evict_addr),
      .l2_back_inval_valid_i (1'b0),
      .l2_back_inval_addr_i  ('0),
      .l2_back_inval_ready_o (back_inval_ready)
  );

  // ---- independent reference memory --------------------------------------
  function automatic data_t reference_word(input addr_t a);
    reference_word = {a[31:0], ~a[31:0]} ^ 64'h5a5a_a5a5_1234_9876;
  endfunction

  // Beat i of a burst starting at `a`: the DUT indexes within the line and
  // wraps at the line boundary, so the reference must wrap identically.
  function automatic data_t reference_beat(input addr_t a, input int unsigned i);
    addr_t base  = a & ~addr_t'(LINE_BYTES - 1);
    int unsigned first = int'((a >> 3) % BEATS);
    reference_beat = reference_word(base + addr_t'(((first + i) % BEATS) * 8));
  endfunction

  // ---- memory model: serves any AR after MEM_LATENCY cycles ---------------
  int unsigned mem_ar_count = 0;
  bit          rd_active = 0;
  int unsigned rd_wait = 0, rd_beat = 0, rd_len = 0;
  addr_t       rd_addr;
  id_t         rd_id;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mst_resp  <= '0;
      rd_active <= 0; rd_wait <= 0; rd_beat <= 0; rd_len <= 0;
      mem_ar_count <= 0;
    end else begin
      mst_resp.aw_ready <= 1'b0;
      mst_resp.w_ready  <= 1'b0;
      mst_resp.b_valid  <= 1'b0;
      mst_resp.ar_ready <= !rd_active && !mst_resp.r_valid;
      if (mst_resp.r_valid && mst_req.r_ready) mst_resp.r_valid <= 1'b0;

      if (mst_req.ar_valid && mst_resp.ar_ready) begin
        rd_active <= 1; rd_addr <= mst_req.ar.addr; rd_id <= mst_req.ar.id;
        rd_len <= int'(mst_req.ar.len); rd_beat <= 0; rd_wait <= MEM_LATENCY;
        mem_ar_count <= mem_ar_count + 1;
        mst_resp.ar_ready <= 1'b0;
      end else if (rd_active) begin
        if (rd_wait != 0) begin
          rd_wait <= rd_wait - 1;
        end else if (!mst_resp.r_valid || mst_req.r_ready) begin
          mst_resp.r_valid <= 1'b1;
          mst_resp.r.id    <= rd_id;
          mst_resp.r.resp  <= axi_pkg::RESP_OKAY;
          mst_resp.r.data  <= reference_beat(rd_addr, rd_beat);
          mst_resp.r.last  <= (rd_beat == rd_len);
          if (rd_beat == rd_len) rd_active <= 0;
          else rd_beat <= rd_beat + 1;
        end
      end
    end
  end

  // ---- observed DUT events (for engagement, never for data checking) ------
  int unsigned merges = 0;
  int unsigned fills  = 0;
  always_ff @(posedge clk) if (rst_n) begin
    if (dut.gen_l2.mshr_alloc && dut.gen_l2.mshr_merged) merges <= merges + 1;
    if (dut.gen_l2.tag_write && !dut.gen_l2.bank_conflict) fills <= fills + 1;
  end

  // ---- concurrent slave-side request driver ------------------------------
  typedef struct {
    id_t         id;
    addr_t       addr;
    int unsigned len;
    logic [3:0]  cache;
    bit          lock;
  } stim_t;

  stim_t pending[$];
  int unsigned issued = 0, completed = 0, expected_total = 0;
  int unsigned beats_seen[16];
  addr_t       req_addr[16];
  int unsigned req_len[16];
  bit          req_used[16];
  int unsigned order[$];
  bit          negative;
  int unsigned start_cyc = 0, end_cyc = 0, cyc = 0;
  int          scenario;

  always_ff @(posedge clk) if (rst_n) cyc <= cyc + 1;

  task automatic push(input id_t id, input addr_t a, input int unsigned len,
                      input logic [3:0] cache = 4'b1111, input bit lock = 0);
    stim_t s;
    s.id = id; s.addr = a; s.len = len; s.cache = cache; s.lock = lock;
    pending.push_back(s);
    req_addr[id] = a; req_len[id] = len; req_used[id] = 1; beats_seen[id] = 0;
    expected_total += len + 1;
  endtask

  // AR driver: keeps the head of the queue presented until accepted.
  stim_t s;
  initial begin
    slv_req = '0;
    slv_req.r_ready = 1'b1;
    @(posedge rst_n);
    forever begin
      @(negedge clk);
      if (pending.size() != 0) begin
        s = pending[0];
        slv_req.ar_valid = 1'b1;
        slv_req.ar.id    = s.id;
        slv_req.ar.addr  = s.addr;
        slv_req.ar.len   = 8'(s.len);
        slv_req.ar.size  = 3'd3;
        slv_req.ar.burst = 2'b01;
        slv_req.ar.cache = s.cache;
        slv_req.ar.lock  = s.lock;
        @(posedge clk);
        if (slv_resp.ar_ready) begin
          void'(pending.pop_front());
          issued++;
        end
        @(negedge clk);
        slv_req.ar_valid = 1'b0;
      end
    end
  end

  // R collector: every beat checked against the independent reference.
  always_ff @(posedge clk) if (rst_n) begin
    if (slv_resp.r_valid && slv_req.r_ready) begin
      automatic id_t rid = slv_resp.r.id;
      automatic data_t want;
      if (!req_used[rid]) $fatal(1, "HUM_UNEXPECTED_ID id=%0d", rid);
      want = reference_beat(req_addr[rid], beats_seen[rid]);
      if (negative) want ^= 64'd1;
      if (slv_resp.r.data !== want)
        $fatal(1, "HUM_DATA id=%0d beat=%0d got=%h want=%h",
               rid, beats_seen[rid], slv_resp.r.data, want);
      if (slv_resp.r.last !== (beats_seen[rid] == req_len[rid]))
        $fatal(1, "HUM_LAST id=%0d beat=%0d", rid, beats_seen[rid]);
      if (slv_resp.r.last) begin
        order.push_back(int'(rid));
        completed++;
      end
      beats_seen[rid] = beats_seen[rid] + 1;
      if (beats_seen[rid] > req_len[rid] + 1)
        $fatal(1, "HUM_EXTRA_BEATS id=%0d", rid);
      end_cyc = cyc;
    end
  end

  task automatic wait_done(input int unsigned limit = 4000);
    int unsigned guard = 0;
    while (completed != expected_count() && guard < limit) begin
      @(posedge clk); guard++;
    end
    if (guard >= limit) $fatal(1, "HUM_TIMEOUT completed=%0d", completed);
  endtask

  function automatic int unsigned expected_count();
    int unsigned n = 0;
    for (int i = 0; i < 16; i++) if (req_used[i]) n++;
    expected_count = n;
  endfunction

  initial begin
    scenario = 0;
    for (int i = 0; i < 16; i++) begin req_used[i] = 0; beats_seen[i] = 0; end
    negative = $test$plusargs("oracle_negative");
    void'($value$plusargs("scenario=%d", scenario));
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    @(posedge clk);
    start_cyc = cyc;

    case (scenario)
      // Same-line readers merge onto one fill and each get their own beats.
      0: begin
        push(4'd1, 64'h2000, 0);
        push(4'd2, 64'h2008, 0);
        push(4'd3, 64'h2010, 0);
        wait_done();
        if (fills != 1) $fatal(1, "HUM_FILLS fills=%0d", fills);
        if (mem_ar_count != 1) $fatal(1, "HUM_DRAM_AR count=%0d", mem_ar_count);
        if (merges != 2) $fatal(1, "HUM_NOT_ENGAGED merges=%0d", merges);
      end
      // Waiters with a different shape than the primary.
      1: begin
        push(4'd1, 64'h3000, 0);
        push(4'd2, 64'h3010, 1);
        push(4'd3, 64'h3038, 0);
        wait_done();
        if (mem_ar_count != 1) $fatal(1, "HUM_DRAM_AR count=%0d", mem_ar_count);
        if (merges != 2) $fatal(1, "HUM_NOT_ENGAGED merges=%0d", merges);
      end
      // One more same-line reader than there are waiter slots.
      2: begin
        push(4'd1, 64'h4000, 0);
        for (int i = 0; i < int'(MAX_WAITERS) + 1; i++)
          push(id_t'(2 + i), 64'h4000 + addr_t'(8 * (i + 1)), 0);
        wait_done();
        if (mem_ar_count != 1) $fatal(1, "HUM_DRAM_AR count=%0d", mem_ar_count);
        if (merges != MAX_WAITERS) $fatal(1, "HUM_WAITER_CAP merges=%0d", merges);
      end
      // Requests that must never merge into the in-flight line.
      3: begin
        push(4'd1, 64'h5000, 0);                 // primary, cacheable
        push(4'd2, 64'h6000, 0);                 // different line
        push(4'd3, 64'h5008, 0, 4'b0000);        // same line, non-cacheable
        push(4'd4, 64'h5010, 0, 4'b1111, 1'b1);  // same line, locked
        wait_done();
        if (merges != 0) $fatal(1, "HUM_ILLEGAL_MERGE merges=%0d", merges);
      end
      // Primary first, then waiters in attach order.
      4: begin
        push(4'd1, 64'h7000, 0);
        push(4'd2, 64'h7008, 0);
        push(4'd3, 64'h7010, 0);
        push(4'd4, 64'h7018, 0);
        wait_done();
        if (merges != 3) $fatal(1, "HUM_NOT_ENGAGED merges=%0d", merges);
        if (order.size() != 4) $fatal(1, "HUM_ORDER_COUNT");
        for (int i = 0; i < 4; i++)
          if (order[i] != i + 1) $fatal(1, "HUM_ORDER pos=%0d id=%0d", i, order[i]);
      end
      // Measurement: 8 readers of one shared line.
      5: begin
        for (int i = 0; i < 8; i++) push(id_t'(1 + i), 64'h8000 + addr_t'(8 * i), 0);
        wait_done();
      end
      // Measurement control: 8 readers of 8 distinct lines (no merge possible).
      6: begin
        for (int i = 0; i < 8; i++) push(id_t'(1 + i), 64'h9000 + addr_t'(LINE_BYTES * i), 0);
        wait_done();
        if (merges != 0) $fatal(1, "HUM_ILLEGAL_MERGE merges=%0d", merges);
      end
      default: $fatal(1, "HUM_SCENARIO");
    endcase

    $display("HUM_METRICS scenario=%0d cycles=%0d dram_ar=%0d fills=%0d merges=%0d responses=%0d",
             scenario, end_cyc - start_cyc, mem_ar_count, fills, merges, completed);
    $display("RTL_REVIEW_PASS hum scenario=%0d", scenario);
    $finish;
  end

  initial begin
    #500us;
    $fatal(1, "HUM_WATCHDOG");
  end

endmodule
