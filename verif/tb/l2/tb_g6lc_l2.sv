// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// tb_g6lc_l2 — leaf-level testbench for the g6lc_l2_top memory-side cache.
//
// Self-contained (verilator --binary --timing): behavioral AXI request
// driver, programmable-latency AXI memory model, golden data model, and
// per-phase hit/miss/eviction counters. Pass criteria are correctness-only:
// every read must return golden data, hit+miss must equal the read count,
// and no phase may hang. Miss/eviction counts are MEASURED and reported —
// the bench never bakes in which replacement policy "should" win; that is
// what the reported numbers are for.
//
// Phases:
//   warm          sequential fill, one line per set order
//   capacity      sequential sweep over 2x cache capacity (all miss)
//   thrash        cyclic K=SET_ASSOC+1 lines on one set (worst case)
//   hot_scan      hot line re-read between rotating scan lines (same set)
//   wr_rd         write-through stores + readback (bypass + self-inval)
//   nc            non-cacheable reads (bypass path, no allocation)
//   lfsr          deterministic pseudo-random mix across 4x capacity
//
// Run: bash verif/tb/l2/run-l2-tb.sh

`timescale 1ns/1ps

package g6lc_l2_tb_pkg;
  localparam int unsigned AW  = 64;
  localparam int unsigned DW  = 64;
  localparam int unsigned IDW = 4;
  localparam int unsigned UW  = 1;

  // ---- AXI channel types (named-member compatible with the DUT) -----------
  typedef logic [IDW-1:0]   id_t;
  typedef logic [AW-1:0]    addr_t;
  typedef logic [DW-1:0]    data_t;
  typedef logic [DW/8-1:0]  strb_t;
  typedef logic [UW-1:0]    user_t;

  typedef struct packed {
    id_t id; addr_t addr; logic [7:0] len; logic [2:0] size;
    logic [1:0] burst; logic lock; logic [3:0] cache; logic [2:0] prot;
    logic [3:0] qos; logic [3:0] region; logic [5:0] atop; user_t user;
  } aw_chan_t;

  typedef struct packed {
    id_t id; addr_t addr; logic [7:0] len; logic [2:0] size;
    logic [1:0] burst; logic lock; logic [3:0] cache; logic [2:0] prot;
    logic [3:0] qos; logic [3:0] region; user_t user;
  } ar_chan_t;

  typedef struct packed {
    data_t data; strb_t strb; logic last; user_t user;
  } w_chan_t;

  typedef struct packed {
    id_t id; logic [1:0] resp; user_t user;
  } b_chan_t;

  typedef struct packed {
    id_t id; data_t data; logic [1:0] resp; logic last; user_t user;
  } r_chan_t;

  typedef struct packed {
    aw_chan_t aw; logic aw_valid;
    w_chan_t  w;  logic w_valid;
    logic     b_ready;
    ar_chan_t ar; logic ar_valid;
    logic     r_ready;
  } req_t;

  typedef struct packed {
    logic aw_ready, ar_ready, w_ready;
    logic b_valid; b_chan_t b;
    logic r_valid; r_chan_t r;
  } resp_t;
endpackage

`ifndef L2TB_STATIC
module tb_g6lc_l2;
  import g6lc_l2_pkg::*;
  import g6lc_l2_tb_pkg::*;

  // ---- DUT geometry (small: thrash reachable in hundreds of cycles) -------
  parameter int unsigned BYTE_SIZE   = 4096;    // 4 KiB
  parameter int unsigned SET_ASSOC   = 4;
  parameter int unsigned LINE_WIDTH  = 512;     // 64 B (Zic64b)
  parameter int unsigned MSHR_DEPTH  = 4;
  parameter int unsigned DATA_BANKS  = 2;
  parameter int unsigned RR_EN       = 0;   // DUT victim-policy candidate
  parameter int unsigned MEM_LATENCY = 6;       // cycles before first R/W beat
  parameter int unsigned STALL_EVERY = 0;       // drop 1 in N beats (0 = never)
  parameter int unsigned SEED        = 32'h600d_f00d;
  parameter int unsigned TAG_SRAM    = 0;       // tag array behind tc_sram
  parameter int unsigned EQ_NEGATIVE = 0;       // eq-mode mutation: flips the signature hit tap

  localparam int unsigned LINE_BYTES = LINE_WIDTH / 8;                    // 64
  localparam int unsigned NUM_SETS   = BYTE_SIZE / (SET_ASSOC * LINE_BYTES);
  localparam int unsigned OFF_BITS   = l2_offset_bits(LINE_WIDTH);        // 6
  localparam int unsigned IDX_BITS   = l2_index_bits(NUM_SETS);
  localparam int unsigned BEATS      = LINE_WIDTH / DW;                   // 8

  // ---- clock / reset ------------------------------------------------------
  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  req_t  slv_req;
  resp_t slv_resp;
  req_t  mst_req;
  resp_t mst_resp, manual_resp, driven_resp;
  bit manual_mode = 0;
  logic [1:0] memory_resp_code = axi_pkg::RESP_OKAY;
  assign driven_resp = manual_mode ? manual_resp : mst_resp;

  logic l2_hit, l2_miss, l2_bypass, l2_mshr_full, l2_bank_conf;
  logic evict_v;
  addr_t evict_addr;
  logic back_inval_ready, back_inval_valid = 1'b0;
  addr_t back_inval_addr = '0;

  g6lc_l2_top #(
      .Enable      (1'b1),
      .BYTE_SIZE   (BYTE_SIZE),
      .SET_ASSOC   (SET_ASSOC),
      .LINE_WIDTH  (LINE_WIDTH),
      .MSHR_DEPTH  (MSHR_DEPTH),
      .DATA_BANKS  (DATA_BANKS),
      .RR_EN       (bit'(RR_EN)),
      .TAG_SRAM    (bit'(TAG_SRAM)),
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
      .mst_resp_i (driven_resp),
      .l2_hit_o           (l2_hit),
      .l2_miss_o          (l2_miss),
      .l2_bypass_o        (l2_bypass),
      .l2_mshr_full_o     (l2_mshr_full),
      .l2_bank_conflict_o (l2_bank_conf),
      .l2_selfinv_hit_o   (),
      .l2_evict_valid_o   (evict_v),
      .l2_evict_addr_o    (evict_addr),
      .l2_evict_ready_i   (1'b1),
      .l2_back_inval_valid_i (back_inval_valid),
      .l2_back_inval_addr_i  (back_inval_addr),
      .l2_back_inval_ready_o (back_inval_ready)
  );

  // ---- eq signature -----------------------------------------------------
  // +eq_run prints one EQSIG line per cycle folding every DUT output (both
  // AXI structs and the sideband flags). Builds that differ only in
  // TAG_SRAM must emit byte-identical streams — that is the cycle-exact
  // flop-vs-SRAM equivalence evidence (run-l2-tb.sh L2TB_EQ_TAGS). In this
  // mode the back-inval injections below are skipped: the SRAM path's
  // deferred inval-match commit is a permitted timing difference, covered
  // by the HUM directed scenarios instead.
  bit eq_run;
  int unsigned eq_cyc = 0;
  initial eq_run = $test$plusargs("eq_run");
  always @(posedge clk) begin
    if (eq_run) begin
      $display("EQSIG %0d %h", eq_cyc,
               {slv_resp, mst_req, l2_hit ^ bit'(EQ_NEGATIVE != 0), l2_miss,
                l2_bypass, l2_mshr_full, l2_bank_conf, evict_v, evict_addr,
                back_inval_ready});
      eq_cyc <= eq_cyc + 1;
    end
  end

  // ---- golden data model --------------------------------------------------
  // Unwritten locations return a deterministic address hash; write-through
  // stores update the model so cached and uncached paths agree.
  data_t golden_mem[addr_t];

  function automatic data_t golden(addr_t a);
    addr_t w = a >> 3;
    if (golden_mem.exists(w) != 0) return golden_mem[w];
    return data_t'(a * 64'h9E37_79B9_7F4A_7C15 ^ {32'(SEED), 32'(SEED ^ 32'hFFFF_FFFF)});
  endfunction

  task automatic golden_write(input addr_t a, input data_t d, input strb_t strb);
    addr_t w = a >> 3;
    data_t cur = golden(a);
    for (int i = 0; i < DW/8; i++)
      if (strb[i]) cur[i*8 +: 8] = d[i*8 +: 8];
    golden_mem[w] = cur;
  endtask

  data_t backing_mem[addr_t];
  function automatic data_t memory_read(addr_t a);
    if (backing_mem.exists(a >> 3) != 0) return backing_mem[a >> 3];
    return data_t'(a * 64'h9E37_79B9_7F4A_7C15 ^ {32'(SEED), 32'(SEED ^ 32'hFFFF_FFFF)});
  endfunction

  task automatic memory_write(input addr_t a, input data_t d, input strb_t mask);
    data_t value = memory_read(a);
    for (int b = 0; b < DW/8; b++)
      if (mask[b]) value[8*b +: 8] = d[8*b +: 8];
    backing_mem[a >> 3] = value;
    if (value !== golden(a)) $fatal(1, "memory-side write mismatch addr=%h", a);
  endtask

  // Install a computed AMO/exclusive result into both models. Unlike
  // memory_write this is the source of truth: the driver does not pre-update
  // golden, because the arithmetic lives in the memory-side monitor.
  task automatic memory_install(input addr_t a, input data_t d, input strb_t mask);
    data_t value = memory_read(a);
    for (int b = 0; b < DW/8; b++)
      if (mask[b]) value[8*b +: 8] = d[8*b +: 8];
    backing_mem[a >> 3] = value;
    golden_mem[a >> 3] = value;
  endtask

  function automatic data_t amo_compute(input data_t old_v, input data_t op, input logic [5:0] atop);
    logic [1:0] kind = atop[5:4];
    data_t result = old_v;
    if (atop == axi_pkg::ATOP_ATOMICSWAP) result = op;
    else if (kind == axi_pkg::ATOP_ATOMICLOAD || kind == axi_pkg::ATOP_ATOMICSTORE) begin
      unique case (atop[2:0])
        axi_pkg::ATOP_ADD: result = old_v + op;
        axi_pkg::ATOP_CLR: result = old_v & ~op;
        axi_pkg::ATOP_EOR: result = old_v ^ op;
        axi_pkg::ATOP_SET: result = old_v | op;
        default: result = old_v;
      endcase
    end
    return result;
  endfunction

  // ---- behavioral AXI memory ----------------------------------------------
  // One outstanding read burst + one write burst (the L2 serializes fills).
  // First beat after MEM_LATENCY cycles; optional periodic stall.
  typedef struct packed { addr_t addr; logic [7:0] len; id_t id; } job_t;
  job_t rd_job;
  logic  rd_active = 1'b0;
  int unsigned rd_wait, rd_beat;
  job_t wr_job;
  logic  wr_hdr = 1'b0;   // AW captured, waiting on W
  logic  wr_active = 1'b0;
  int unsigned wr_wait, wr_beat;
  int unsigned beat_ctr = 0;
  bit inject_short_r = 0, short_sent = 0;
  logic [5:0] wr_atop = '0;
  logic wr_lock = 1'b0;
  logic [1:0] wr_bresp = axi_pkg::RESP_OKAY;
  logic rd_lock = 1'b0;
  data_t amo_old_q = '0;
  logic atop_r_pending = 1'b0;
  bit excl_monitor_en = 0;
  bit excl_valid = 0;
  addr_t excl_line = '0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      mst_resp       <= '0;
      rd_active      <= 1'b0;
      wr_hdr         <= 1'b0;
      wr_active      <= 1'b0;
      rd_wait        <= 0;
      wr_wait        <= 0;
      rd_beat        <= 0;
      wr_beat        <= 0;
      beat_ctr       <= 0;
      short_sent     <= 0;
      wr_atop        <= '0;
      wr_lock        <= 1'b0;
      wr_bresp       <= axi_pkg::RESP_OKAY;
      rd_lock        <= 1'b0;
      amo_old_q      <= '0;
      atop_r_pending <= 1'b0;
      excl_valid     <= 1'b0;
      excl_line      <= '0;
    end else if (!manual_mode) begin
      beat_ctr <= beat_ctr + 1;
      // ---- AR accept
      mst_resp.ar_ready <= !rd_active && !mst_resp.r_valid && !atop_r_pending;
      if (mst_req.ar_valid && mst_resp.ar_ready) begin
        if (rd_active || mst_resp.r_valid || atop_r_pending) $fatal(1, "memory read overlap");
        // Fills issue under the engine's reserved id so their beats can be
        // routed to the collector; a bypass keeps the requester's id.
        if (mst_req.ar.id !== ((l2_is_cacheable(slv_req.ar.cache) && !slv_req.ar.lock)
                               ? id_t'('1) : slv_req.ar.id) ||
            mst_req.ar.size !== 3 ||
            mst_req.ar.burst !== axi_pkg::BURST_INCR || mst_req.ar.lock !== slv_req.ar.lock)
          $fatal(1, "memory AR metadata mismatch");
        if (l2_is_cacheable(slv_req.ar.cache) && !slv_req.ar.lock) begin
          if (mst_req.ar.addr !== (slv_req.ar.addr & ~addr_t'(LINE_BYTES - 1)) ||
              mst_req.ar.len !== 8'(BEATS - 1)) $fatal(1, "incorrect fill request");
        end else if (mst_req.ar.addr !== slv_req.ar.addr || mst_req.ar.len !== slv_req.ar.len ||
                     mst_req.ar.cache !== slv_req.ar.cache) $fatal(1, "incorrect bypass request");
        mst_resp.ar_ready <= 1'b0;
        rd_job    <= '{addr: mst_req.ar.addr, len: mst_req.ar.len, id: mst_req.ar.id};
        rd_lock   <= mst_req.ar.lock;
        rd_active <= 1'b1;
        rd_wait   <= MEM_LATENCY;
        rd_beat   <= 0;
        short_sent <= 0;
        if (excl_monitor_en && mst_req.ar.lock) begin
          excl_valid <= 1'b1;
          excl_line  <= mst_req.ar.addr & ~addr_t'(LINE_BYTES - 1);
        end
      end
      // ---- R stream: hold each beat until r_ready, then advance
      if (rd_active) begin
        if (rd_wait != 0) begin
          rd_wait <= rd_wait - 1;
          mst_resp.r_valid <= 1'b0;
        end else if (inject_short_r && !short_sent && (!mst_resp.r_valid || mst_req.r_ready)) begin
          mst_resp.r_valid <= 1;
          mst_resp.r <= '{id: rd_job.id, data: 64'hdead_0000_bad0_0001,
                          resp: axi_pkg::RESP_OKAY, last: 1'b1, user: '0};
          short_sent <= 1;
        end else if (STALL_EVERY != 0 && (beat_ctr % STALL_EVERY) == 0 &&
                     (!mst_resp.r_valid || mst_req.r_ready)) begin
          mst_resp.r_valid <= 1'b0;  // bubble between beats, never on a held beat
        end else if (!mst_resp.r_valid || mst_req.r_ready) begin
          mst_resp.r_valid <= 1'b1;
          mst_resp.r.id    <= rd_job.id;
          mst_resp.r.resp  <= (excl_monitor_en && rd_lock) ? axi_pkg::RESP_EXOKAY : memory_resp_code;
          mst_resp.r.data  <= memory_read(rd_job.addr + addr_t'(rd_beat) * (DW/8));
          mst_resp.r.last  <= (rd_beat == rd_job.len);
          if (rd_beat == rd_job.len) begin
            rd_active <= 1'b0;
            rd_beat   <= 0;
            rd_lock   <= 1'b0;
          end else begin
            rd_beat <= rd_beat + 1;
          end
        end
      end else if (atop_r_pending) begin
        if (!mst_resp.r_valid) begin
          mst_resp.r_valid <= 1'b1;
          mst_resp.r <= '{id: wr_job.id, data: amo_old_q, resp: axi_pkg::RESP_OKAY,
                          last: 1'b1, user: '0};
        end else if (mst_req.r_ready) begin
          mst_resp.r_valid <= 1'b0;
          mst_resp.r.last  <= 1'b0;
          atop_r_pending   <= 1'b0;
        end
      end else if (mst_resp.r_valid && mst_req.r_ready) begin
        mst_resp.r_valid <= 1'b0;
        mst_resp.r.last  <= 1'b0;
      end
      // ---- AW accept
      mst_resp.aw_ready <= !wr_hdr && !wr_active;
      if (mst_req.aw_valid && mst_resp.aw_ready) begin
        if (wr_hdr || wr_active) $fatal(1, "memory write overlap");
        mst_resp.aw_ready <= 1'b0;
        wr_job  <= '{addr: mst_req.aw.addr, len: mst_req.aw.len, id: mst_req.aw.id};
        wr_atop <= mst_req.aw.atop;
        wr_lock <= mst_req.aw.lock;
        wr_hdr  <= 1'b1;
      end
      // ---- W accept
      mst_resp.w_ready <= wr_hdr;
      if (mst_req.w_valid && mst_resp.w_ready) begin
        if (!wr_hdr || mst_req.w.last !== (wr_beat == wr_job.len))
          $fatal(1, "memory W without AW or wrong WLAST");
        if (wr_atop != 0) begin
          if (mst_req.w.last) begin
            data_t old_v, new_v;
            strb_t mask;
            old_v = memory_read(wr_job.addr);
            amo_old_q <= old_v;
            if (wr_atop == axi_pkg::ATOP_ATOMICCMP) begin
              if (old_v[31:0] == mst_req.w.data[31:0])
                new_v = {old_v[63:32], mst_req.w.data[63:32]};
              else
                new_v = old_v;
              mask = 8'h0F;
            end else begin
              new_v = amo_compute(old_v, mst_req.w.data, wr_atop);
              mask = mst_req.w.strb;
            end
            memory_install(wr_job.addr, new_v, mask);
            atop_r_pending <= wr_atop[5];
            wr_bresp <= axi_pkg::RESP_OKAY;
            excl_valid <= 1'b0;
          end
        end else if (excl_monitor_en && wr_lock) begin
          if (excl_valid && excl_line == (wr_job.addr & ~addr_t'(LINE_BYTES - 1))) begin
            memory_install(wr_job.addr + addr_t'(wr_beat) * (DW/8),
                           mst_req.w.data, mst_req.w.strb);
            wr_bresp <= axi_pkg::RESP_EXOKAY;
            if (mst_req.w.last) excl_valid <= 1'b0;
          end else begin
            wr_bresp <= axi_pkg::RESP_OKAY;
            if (mst_req.w.last) excl_valid <= 1'b0;
          end
        end else begin
          memory_write(wr_job.addr + addr_t'(wr_beat) * (DW/8),
                       mst_req.w.data, mst_req.w.strb);
          wr_bresp <= axi_pkg::RESP_OKAY;
          if (excl_monitor_en &&
              (wr_job.addr & ~addr_t'(LINE_BYTES - 1)) == excl_line)
            excl_valid <= 1'b0;
        end
        if (mst_req.w.last || wr_beat == wr_job.len) begin
          wr_hdr    <= 1'b0;
          mst_resp.w_ready <= 1'b0;
          wr_active <= 1'b1;
          wr_wait   <= MEM_LATENCY;
          wr_beat   <= 0;
        end else begin
          wr_beat <= wr_beat + 1;
        end
      end
      // ---- B emit: present once, hold until b_ready
      if (wr_active) begin
        if (wr_wait != 0) begin
          wr_wait <= wr_wait - 1;
          mst_resp.b_valid <= 1'b0;
        end else if (!mst_resp.b_valid) begin
          mst_resp.b_valid <= 1'b1;
          mst_resp.b.id    <= wr_job.id;
          mst_resp.b.resp  <= wr_bresp;
        end else if (mst_req.b_ready) begin
          mst_resp.b_valid <= 1'b0;
          wr_active        <= 1'b0;
          wr_atop          <= '0;
          wr_lock          <= 1'b0;
        end
      end else begin
        mst_resp.b_valid <= 1'b0;
      end
    end
  end

  longint unsigned cyc_q = 0;
  integer size_fd = 0;
  initial if ($test$plusargs("mshr-trace")) begin
    size_fd = $fopen("ports.log", "w");
    if (size_fd == 0) $fatal(1, "L2SIZE_TRACE_OPEN");
  end
  always @(posedge clk) if (rst_n && size_fd != 0) begin
    if (slv_req.ar_valid && slv_resp.ar_ready) $fdisplay(size_fd, "%0d sar %h", cyc_q, slv_req.ar);
    if (slv_req.aw_valid && slv_resp.aw_ready) $fdisplay(size_fd, "%0d saw %h", cyc_q, slv_req.aw);
    if (slv_req.w_valid && slv_resp.w_ready) $fdisplay(size_fd, "%0d sw %h", cyc_q, slv_req.w);
    if (slv_resp.r_valid && slv_req.r_ready) $fdisplay(size_fd, "%0d sr %h", cyc_q, slv_resp.r);
    if (slv_resp.b_valid && slv_req.b_ready) $fdisplay(size_fd, "%0d sb %h", cyc_q, slv_resp.b);
    if (mst_req.ar_valid && driven_resp.ar_ready) $fdisplay(size_fd, "%0d mar %h", cyc_q, mst_req.ar);
    if (mst_req.aw_valid && driven_resp.aw_ready) $fdisplay(size_fd, "%0d maw %h", cyc_q, mst_req.aw);
    if (mst_req.w_valid && driven_resp.w_ready) $fdisplay(size_fd, "%0d mw %h", cyc_q, mst_req.w);
    if (driven_resp.r_valid && mst_req.r_ready) $fdisplay(size_fd, "%0d mr %h", cyc_q, driven_resp.r);
    if (driven_resp.b_valid && mst_req.b_ready) $fdisplay(size_fd, "%0d mb %h", cyc_q, driven_resp.b);
  end
  final if (size_fd != 0) $fclose(size_fd);

  int unsigned size_live = 0, size_peak = 0, size_allocations = 0, size_completions = 0;
  always @(posedge clk) begin
    if (!rst_n) size_live = 0;
    else if ($test$plusargs("mshr-observe")) begin
      int unsigned observed;
      observed = int'(dut.gen_l2.i_mshr.count_o);
      if ($test$plusargs("mshr-negative") && observed != 0) observed++;
      if (observed != size_live || observed > 1)
        $fatal(1, "L2SIZE_OCCUPANCY observed=%0d expected=%0d", observed, size_live);
      if (size_live > size_peak) size_peak = size_live;
      if (dut.gen_l2.mshr_alloc) begin
        if (!dut.gen_l2.mshr_ready || dut.gen_l2.mshr_merged || size_live != 0 || dut.gen_l2.mshr_complete)
          $fatal(1, "L2SIZE_ALLOCATION");
        size_live++;
        size_allocations++;
      end
      if (dut.gen_l2.mshr_complete) begin
        if (size_live != 1) $fatal(1, "L2SIZE_COMPLETION");
        size_live--;
        size_completions++;
      end
    end
  end

  // ---- per-phase counters ---------------------------------------------------
  int unsigned cnt_hit, cnt_miss, cnt_evict, cnt_bypass, cnt_mshr_full, cnt_bankconf;
  int unsigned ph_hit, ph_miss, ph_evict, ph_bypass, ph_mshr, ph_bank;
  longint unsigned ph_cycles;
  int unsigned total_reads, total_writes, fails = 0;
  int unsigned mem_ar, mem_aw, mem_rbeats, mem_wbeats, mem_b, fills;
  int unsigned ph_mem_ar, ph_mem_aw, ph_mem_rbeats, ph_mem_wbeats, ph_mem_b, ph_fills;
  int unsigned ph_reads, ph_writes, r_left, b_left, completed_reads, completed_writes;
  int unsigned ph_completed_reads, ph_completed_writes;
  bit prev_miss = 0, prev_evict = 0, read_is_atop = 0;
  int unsigned atop_responses = 0;
  addr_t policy_lines[NUM_SETS][SET_ASSOC];
  bit policy_valid[NUM_SETS][SET_ASSOC];
  int unsigned policy_next[NUM_SETS];
  addr_t policy_line;
  int unsigned policy_set, policy_way;
  bit policy_hit, policy_cacheable, policy_lookup_seen;
  int unsigned policy_lookups = 0, policy_installs = 0, policy_evictions = 0;
  // Fills that completed with a non-OKAY R resp: they install no tag, so the
  // installs == fills invariant must subtract them.
  int unsigned fill_errors = 0;
  logic [SET_ASSOC-1:0] policy_evicted_ways = '0;

  always @(posedge clk) begin
    if (!rst_n) begin
      policy_cacheable = 0;
      policy_lookup_seen = 0;
      for (int s = 0; s < NUM_SETS; s++) begin
        policy_next[s] = 0;
        for (int w = 0; w < SET_ASSOC; w++) policy_valid[s][w] = 0;
      end
    end else begin
      if (slv_req.ar_valid && slv_resp.ar_ready) begin
        policy_line = slv_req.ar.addr & ~addr_t'(LINE_BYTES - 1);
        policy_set = int'((slv_req.ar.addr >> OFF_BITS) % NUM_SETS);
        policy_hit = 0;
        policy_cacheable = l2_is_cacheable(slv_req.ar.cache) && !slv_req.ar.lock;
        policy_lookup_seen = 0;
        policy_way = RR_EN != 0 ? policy_next[policy_set] : 0;
        for (int w = int'(SET_ASSOC) - 1; w >= 0; w--)
          if (!policy_valid[policy_set][w]) policy_way = unsigned'(w);
        for (int w = 0; w < SET_ASSOC; w++)
          if (policy_valid[policy_set][w] && policy_lines[policy_set][w] == policy_line) begin
            policy_hit = 1;
            policy_way = unsigned'(w);
          end
      end
      if (l2_hit || l2_miss) begin
        if (!policy_cacheable || l2_hit !== policy_hit || l2_miss === policy_hit)
          $fatal(1, "policy lookup disagrees with independent tags");
        if (!policy_lookup_seen) begin
          policy_lookup_seen = 1;
          policy_lookups++;
          if (!policy_hit) begin
            if (evict_v !== policy_valid[policy_set][policy_way])
              $fatal(1, "invalid-first eviction validity");
            if (evict_v) begin
              addr_t expected_victim;
              expected_victim = policy_lines[policy_set][policy_way];
              if ($test$plusargs("policy-oracle-negative")) expected_victim ^= addr_t'(LINE_BYTES);
              if (evict_addr !== expected_victim) $fatal(1, "policy victim address mismatch");
              policy_evicted_ways[policy_way] = 1;
              policy_evictions++;
            end
          end
        end
      end
      // The install event is the committed tag write itself. MSHR completion is
      // deliberately deferred past the response so that same-line readers which
      // merged during the fill can still be drained from the entry.
      if (dut.gen_l2.tag_write && !dut.gen_l2.bank_conflict) begin
        if (!policy_cacheable || policy_hit || !policy_lookup_seen ||
            int'(dut.gen_l2.tag_wway) != policy_way ||
            int'(dut.gen_l2.tag_windex) != policy_set)
          $fatal(1, "policy install way/set mismatch");
        policy_lines[policy_set][policy_way] = policy_line;
        policy_valid[policy_set][policy_way] = 1;
        policy_next[policy_set] = (policy_way + 1) % SET_ASSOC;
        policy_installs++;
      end
      if (dut.gen_l2.mshr_complete &&
          dut.gen_l2.fill_ferr_q[dut.gen_l2.serve_idx_q] != axi_pkg::RESP_OKAY)
        fill_errors++;
      if (slv_req.aw_valid && slv_resp.aw_ready) begin
        for (int w = 0; w < SET_ASSOC; w++)
          if (policy_lines[int'((slv_req.aw.addr >> OFF_BITS) % NUM_SETS)][w] ==
              (slv_req.aw.addr & ~addr_t'(LINE_BYTES - 1)))
            policy_valid[int'((slv_req.aw.addr >> OFF_BITS) % NUM_SETS)][w] = 0;
      end
      if (back_inval_valid && back_inval_ready) begin
        for (int w = 0; w < SET_ASSOC; w++)
          if (policy_lines[int'((back_inval_addr >> OFF_BITS) % NUM_SETS)][w] ==
              (back_inval_addr & ~addr_t'(LINE_BYTES - 1)))
            policy_valid[int'((back_inval_addr >> OFF_BITS) % NUM_SETS)][w] = 0;
      end
      if (slv_resp.r_valid && slv_req.r_ready && slv_resp.r.last) policy_cacheable = 0;
    end
  end

  assert property (@(posedge clk) disable iff (!rst_n)
      driven_resp.r_valid && !mst_req.r_ready |=> driven_resp.r_valid && $stable(driven_resp.r));
  assert property (@(posedge clk) disable iff (!rst_n)
      driven_resp.b_valid && !mst_req.b_ready |=> driven_resp.b_valid && $stable(driven_resp.b));
  assert property (@(posedge clk) disable iff (!rst_n)
      slv_resp.r_valid && !slv_req.r_ready |=> slv_resp.r_valid && $stable(slv_resp.r));
  assert property (@(posedge clk) disable iff (!rst_n)
      slv_resp.b_valid && !slv_req.b_ready |=> slv_resp.b_valid && $stable(slv_resp.b));

  always @(posedge clk) if (rst_n) begin
    if (slv_req.ar_valid && slv_resp.ar_ready) begin
      if (r_left != 0) $fatal(1, "unexpected overlapping AR");
      r_left = int'(slv_req.ar.len) + 1;
      read_is_atop = 0;
    end
    if (slv_resp.r_valid && slv_req.r_ready) begin
      if (r_left == 0 || slv_resp.r.last !== (r_left == 1)) $fatal(1, "unexpected R");
      r_left--;
      if (r_left == 0) begin
        if (read_is_atop) atop_responses++;
        else completed_reads++;
      end
    end
    if (slv_req.aw_valid && slv_resp.aw_ready) begin
      b_left++;
      if (slv_req.aw.atop[5]) begin
        if (r_left != 0) $fatal(1, "overlapping ATOP response credit");
        r_left = 1;
        read_is_atop = 1;
      end
    end
    if (slv_resp.b_valid && slv_req.b_ready) begin
      if (b_left != 1) $fatal(1, "unexpected B");
      b_left--;
      completed_writes++;
    end
    if (mst_req.ar_valid && driven_resp.ar_ready) mem_ar++;
    if (mst_req.aw_valid && driven_resp.aw_ready) mem_aw++;
    if (driven_resp.r_valid && mst_req.r_ready) mem_rbeats++;
    if (mst_req.w_valid && driven_resp.w_ready) mem_wbeats++;
    if (driven_resp.b_valid && mst_req.b_ready) mem_b++;
    if (dut.gen_l2.mshr_complete) fills++;
  end

  always @(posedge clk) begin
    if (rst_n) begin
      cyc_q <= cyc_q + 1;
      if (l2_hit)      cnt_hit++;
      if (l2_miss && !prev_miss) cnt_miss++;
      if (evict_v && !prev_evict) cnt_evict++;
      prev_miss = l2_miss;
      prev_evict = evict_v;
      if (l2_bypass)   cnt_bypass++;
      if (l2_mshr_full) cnt_mshr_full++;
      if (l2_bank_conf) cnt_bankconf++;
    end
  end

  task automatic phase_begin();
    ph_hit = cnt_hit; ph_miss = cnt_miss; ph_evict = cnt_evict;
    ph_bypass = cnt_bypass; ph_mshr = cnt_mshr_full; ph_bank = cnt_bankconf;
    ph_cycles = cyc_q;
    ph_mem_ar = mem_ar; ph_mem_aw = mem_aw;
    ph_mem_rbeats = mem_rbeats; ph_mem_wbeats = mem_wbeats; ph_mem_b = mem_b;
    ph_fills = fills; ph_reads = total_reads; ph_writes = total_writes;
    ph_completed_reads = completed_reads; ph_completed_writes = completed_writes;
  endtask

  task automatic phase_end(input string name, input int unsigned reads, input int unsigned writes);
    int dhit   = cnt_hit   - ph_hit;
    int dmiss  = cnt_miss  - ph_miss;
    int devict = cnt_evict - ph_evict;
    int dbyp   = cnt_bypass - ph_bypass;
    longint unsigned dcyc = cyc_q - ph_cycles;
    $display("[L2TB] phase=%s cycles=%0d reads=%0d writes=%0d hits=%0d misses=%0d evictions=%0d bypass=%0d mshr_full=%0d bank_conf=%0d",
             name, dcyc, reads, writes, dhit, dmiss, devict, dbyp,
             cnt_mshr_full - ph_mshr, cnt_bankconf - ph_bank);
    // Cacheable reads resolve as exactly one hit or miss each (strobes).
    if (dhit + dmiss + dbyp != reads + writes || total_reads - ph_reads != reads ||
        total_writes - ph_writes != writes || completed_reads - ph_completed_reads != reads ||
        completed_writes - ph_completed_writes != writes || r_left != 0 || b_left != 0 ||
        mem_ar - ph_mem_ar != dmiss + dbyp - writes || mem_aw - ph_mem_aw != writes ||
        mem_wbeats - ph_mem_wbeats != writes || mem_b - ph_mem_b != writes || fills - ph_fills != dmiss)
      $fatal(1, "[L2TB] FAIL phase=%s accounting", name);
    $display("[L2TB] traffic phase=%s mem_ar=%0d mem_rbeats=%0d mem_aw=%0d mem_wbeats=%0d fills=%0d",
             name, mem_ar - ph_mem_ar, mem_rbeats - ph_mem_rbeats,
             mem_aw - ph_mem_aw, mem_wbeats - ph_mem_wbeats, fills - ph_fills);
  endtask

  // ---- slave driver ---------------------------------------------------------
  // Drive at negedge, sample ready #1 later (post-comb-settle): a ready that
  // is high at this point causes the accept at the upcoming posedge. Driving
  // at posedge would race the DUT's sampling edge and make the ready pulse
  // invisible (zero-time handshake — the wedge this bench first hit).
  task automatic axi_read(input addr_t a, input logic [3:0] cache,
                          input int unsigned beats = 1, input bit locked = 0,
                          input int unsigned hold_cycles = 0,
                          input int unsigned beat_hold_cycles = 0,
                          input logic [1:0] expected_resp = axi_pkg::RESP_OKAY);
    int unsigned beats_got = 0;
    int unsigned stall_left = hold_cycles;
    int unsigned guard = 0;
    id_t req_id = id_t'(total_reads);
    if (beats == 0 || beats > BEATS || a[2:0] != 0) $fatal(1, "invalid read request");
    @(negedge clk);
    slv_req.ar = '0;
    slv_req.ar.addr = a;
    slv_req.ar.len = 8'(beats - 1);   // configurable 64-bit beats per request
    slv_req.ar.id = req_id;
    slv_req.ar.lock = locked;
    slv_req.ar.size = 3;             // 8 B
    slv_req.ar.burst = axi_pkg::BURST_INCR;
    slv_req.ar.cache = cache;
    slv_req.ar_valid = 1'b1;
    slv_req.r_ready = 1'b0;         // hold until the response driver is ready
    while (1) begin
      #1;
      if (slv_resp.ar_ready) break;
      @(negedge clk);
      if (++guard >= 10000) begin
        $display("[L2TB] FAIL ar_ready timeout addr=0x%0h", a);
        fails++;
        slv_req.ar_valid = 1'b0;
        return;
      end
    end
    @(negedge clk);                  // the AR accept posedge has passed
    slv_req.ar_valid = 1'b0;
    guard = 0;
    while (1) begin
      slv_req.r_ready = (stall_left == 0);
      @(posedge clk);                // sample the actual response handshake
      guard++;
      if (stall_left != 0) stall_left--;
      if (slv_resp.r_valid && slv_req.r_ready) begin
        if (slv_resp.r.id !== req_id || slv_resp.r.resp !== expected_resp ||
            slv_resp.r.last !== (beats_got == beats - 1))
          $fatal(1, "R metadata/length mismatch addr=%h beat=%0d", a, beats_got);
        if (slv_resp.r.data !== golden(a + addr_t'(beats_got) * (DW/8))) begin
          $display("[L2TB] FAIL data addr=0x%0h beat=%0d got=0x%0h exp=0x%0h",
                   a, beats_got, slv_resp.r.data, golden(a + addr_t'(beats_got) * (DW/8)));
          fails++;
        end
        beats_got++;
        if (slv_resp.r.last) break;
        stall_left = beat_hold_cycles;
      end
      if (guard >= 10000) begin
        $fatal(1, "[L2TB] FAIL r timeout addr=0x%0h", a);
      end
      @(negedge clk);
    end
    if (beats_got != beats) $fatal(1, "incomplete read");
    @(negedge clk);                  // last-accept posedge has passed
    slv_req.r_ready = 1'b0;
  endtask

  task automatic axi_write(input addr_t a, input data_t d, input logic [3:0] cache,
                           input strb_t mask = '1, input int unsigned hold_cycles = 0,
                           input bit locked = 0, input logic [1:0] exp_bresp = axi_pkg::RESP_OKAY,
                           input bit update_golden = 1);
    int unsigned guard = 0;
    id_t req_id = id_t'(total_writes);
    @(negedge clk);
    slv_req.aw = '0;
    slv_req.aw.addr = a;
    slv_req.aw.id = req_id;
    slv_req.aw.len = 0;
    slv_req.aw.size = 3;
    slv_req.aw.burst = axi_pkg::BURST_INCR;
    slv_req.aw.cache = cache;
    slv_req.aw.lock = locked;
    slv_req.aw_valid = 1'b1;
    slv_req.b_ready = 1'b0;
    while (1) begin
      #1;
      if (slv_resp.aw_ready) break;
      @(negedge clk);
      if (++guard >= 10000) begin
        $display("[L2TB] FAIL aw_ready timeout addr=0x%0h", a);
        fails++;
        slv_req.aw_valid = 1'b0;
        return;
      end
    end
    @(negedge clk);                  // AW accept posedge has passed
    slv_req.aw_valid = 1'b0;
    slv_req.w = '0;
    slv_req.w.data = d;
    slv_req.w.strb = mask;
    if (update_golden) golden_write(a, d, mask);
    slv_req.w.last = 1'b1;
    slv_req.w_valid = 1'b1;
    guard = 0;
    while (1) begin
      #1;
      if (slv_resp.w_ready) break;
      @(negedge clk);
      if (++guard >= 10000) begin
        $display("[L2TB] FAIL w_ready timeout addr=0x%0h", a);
        fails++;
        slv_req.w_valid = 1'b0;
        return;
      end
    end
    @(negedge clk);                  // W accept posedge has passed
    slv_req.w_valid = 1'b0;
    guard = 0;
    while (1) begin
      slv_req.b_ready = (guard >= hold_cycles);
      @(posedge clk);
      if (slv_resp.b_valid && slv_req.b_ready) begin
        if (slv_resp.b.id !== req_id || slv_resp.b.resp !== exp_bresp)
          $fatal(1, "B metadata mismatch addr=%h", a);
        break;
      end
      if (++guard >= 10000) $fatal(1, "[L2TB] FAIL b timeout addr=0x%0h", a);
      @(negedge clk);
    end
    @(negedge clk);                  // B accept posedge has passed
    slv_req.b_ready = 1'b0;
  endtask

  // Drive a one-beat AXI ATOP through the L2 slave. The memory model performs
  // the arithmetic; this checks forwarded old-data R, B, and a following
  // cacheable read of the computed result (WT self-inval → miss fill).
  task automatic axi_amo(input addr_t a, input data_t operand, input logic [5:0] atop,
                         input data_t exp_old, input data_t exp_new,
                         input logic [1:0] exp_bresp = axi_pkg::RESP_OKAY);
    int unsigned guard = 0;
    bit got_b = 0, got_r = (atop[5] == 1'b0);
    id_t req_id = id_t'(total_writes);
    @(negedge clk);
    slv_req.aw = '0;
    slv_req.aw.addr = a;
    slv_req.aw.id = req_id;
    slv_req.aw.len = 0;
    slv_req.aw.size = 3;
    slv_req.aw.burst = axi_pkg::BURST_INCR;
    slv_req.aw.cache = CACHEABLE;
    slv_req.aw.atop = atop;
    slv_req.aw_valid = 1'b1;
    slv_req.b_ready = 1'b0;
    slv_req.r_ready = 1'b0;
    while (1) begin
      #1;
      if (slv_resp.aw_ready) break;
      @(negedge clk);
      if (++guard >= 10000) $fatal(1, "AMO AW timeout addr=%h", a);
    end
    @(negedge clk);
    slv_req.aw_valid = 1'b0;
    slv_req.w = '{data: operand, strb: '1, last: 1'b1, user: '0};
    slv_req.w_valid = 1'b1;
    guard = 0;
    while (1) begin
      #1;
      if (slv_resp.w_ready) break;
      @(negedge clk);
      if (++guard >= 10000) $fatal(1, "AMO W timeout addr=%h", a);
    end
    @(negedge clk);
    slv_req.w_valid = 1'b0;
    guard = 0;
    while (!got_b || !got_r) begin
      slv_req.b_ready = 1'b1;
      slv_req.r_ready = 1'b1;
      @(posedge clk);
      if (slv_resp.b_valid && slv_req.b_ready) begin
        if (slv_resp.b.id !== req_id || slv_resp.b.resp !== exp_bresp)
          $fatal(1, "AMO B metadata addr=%h", a);
        got_b = 1;
      end
      if (slv_resp.r_valid && slv_req.r_ready) begin
        if (slv_resp.r.id !== req_id || slv_resp.r.last !== 1'b1 ||
            slv_resp.r.data !== exp_old)
          $fatal(1, "AMO R old-data addr=%h got=%h exp=%h", a, slv_resp.r.data, exp_old);
        got_r = 1;
      end
      if (++guard >= 10000) $fatal(1, "AMO response timeout addr=%h", a);
      @(negedge clk);
    end
    slv_req.b_ready = 1'b0;
    slv_req.r_ready = 1'b0;
    axi_read(a, CACHEABLE);
    if (golden(a) !== exp_new) $fatal(1, "AMO result not visible addr=%h", a);
  endtask

  task automatic manual_b(input id_t id);
    manual_resp.b_valid = 1;
    manual_resp.b = '{id: id, resp: axi_pkg::RESP_OKAY, user: '1};
    slv_req.b_ready = 0;
    repeat (3) begin
      @(posedge clk);
      if (!slv_resp.b_valid || slv_resp.b !== manual_resp.b || mst_req.b_ready)
        $fatal(1, "ATOP B hold/metadata");
      @(negedge clk);
    end
    slv_req.b_ready = 1;
    @(posedge clk);
    if (!mst_req.b_ready || !slv_resp.b_valid) $fatal(1, "ATOP B handshake");
    @(negedge clk);
    manual_resp.b_valid = 0;
    slv_req.b_ready = 0;
  endtask

  task automatic manual_r(input id_t id, input data_t data);
    manual_resp.r_valid = 1;
    manual_resp.r = '{id: id, data: data, resp: axi_pkg::RESP_OKAY, last: 1'b1, user: '1};
    slv_req.r_ready = 0;
    repeat (5) begin
      @(posedge clk);
      if (!slv_resp.r_valid || slv_resp.r !== manual_resp.r || mst_req.r_ready || dut.gen_l2.mst_r_ot_q)
        $fatal(1, "ATOP R hold/metadata/AR-credit");
      if (manual_resp.b_valid && (!slv_resp.b_valid || !mst_req.b_ready))
        $fatal(1, "concurrent ATOP B handshake");
      @(negedge clk);
      if (manual_resp.b_valid) begin
        manual_resp.b_valid = 0;
        slv_req.b_ready = 0;
      end
    end
    slv_req.r_ready = 1;
    @(posedge clk);
    if (!mst_req.r_ready || !slv_resp.r_valid || slv_resp.r !== manual_resp.r)
      $fatal(1, "ATOP R handshake");
    @(negedge clk);
    manual_resp.r_valid = 0;
    slv_req.r_ready = 0;
  endtask

  task automatic atop_forward(input int unsigned mode);
    id_t id = id_t'(8 + mode);
    addr_t addr = 64'h4000_0000 + addr_t'(mode) * 64;
    int unsigned guard = 0;
    int unsigned old_ar = mem_ar, old_aw = mem_aw, old_w = mem_wbeats;
    int unsigned old_r = mem_rbeats, old_b = mem_b, old_atop = atop_responses;
    @(negedge clk);
    manual_mode = 1;
    manual_resp = '0;
    slv_req = '0;
    slv_req.aw = '{id: id, addr: addr, len: 0, size: 3, burst: axi_pkg::BURST_INCR,
                   atop: 6'h20, cache: 4'hf, default: '0};
    slv_req.aw_valid = 1;
    while (1) begin
      @(posedge clk);
      guard++;
      if (slv_resp.aw_ready) break;
      if (guard > 50) $fatal(1, "ATOP slave AW timeout");
    end
    @(negedge clk);
    slv_req.aw_valid = 0;
    slv_req.aw = '0;
    manual_resp.aw_ready = 1;
    guard = 0;
    while (1) begin
      @(posedge clk);
      guard++;
      if (mst_req.aw_valid) break;
      if (guard > 50) $fatal(1, "ATOP master AW timeout");
    end
    if (mst_req.aw.id !== id || mst_req.aw.addr !== addr || mst_req.aw.atop !== 6'h20 ||
        mst_req.aw.len !== 0 || mst_req.aw.size !== 3 || mst_req.aw.cache !== 4'hf)
      $fatal(1, "ATOP captured AW metadata");
    @(negedge clk);
    manual_resp.aw_ready = 0;
    slv_req.w = '{data: 64'h1357_9bdf_2468_ace0, strb: '1, last: 1'b1, user: '1};
    slv_req.w_valid = 1;
    manual_resp.w_ready = 1;
    guard = 0;
    while (1) begin
      @(posedge clk);
      guard++;
      if (slv_resp.w_ready) break;
      if (guard > 50) $fatal(1, "ATOP W timeout");
    end
    if (!mst_req.w_valid || mst_req.w !== slv_req.w) $fatal(1, "ATOP W forwarding");
    @(negedge clk);
    slv_req.w_valid = 0;
    manual_resp.w_ready = 0;
    if (mode == 2) begin
      manual_b(id);
      repeat (5) @(negedge clk);
    end
    if (mode == 1) begin
      manual_resp.b_valid = 1;
      manual_resp.b = '{id: id, resp: axi_pkg::RESP_OKAY, user: '1};
      slv_req.b_ready = 1;
    end
    manual_r(id, 64'hface_cafe_1234_0000 | data_t'(mode));
    if (mode == 0) manual_b(id);
    if (mem_ar != old_ar || mem_aw != old_aw + 1 || mem_wbeats != old_w + 1 ||
        mem_rbeats != old_r + 1 || mem_b != old_b + 1 || atop_responses != old_atop + 1 ||
        r_left != 0 || b_left != 0 || dut.gen_l2.mst_r_ot_q)
      $fatal(1, "ATOP completion accounting");
    manual_mode = 0;
    $display("[L2TB] ATOP mode=%0d forwarded=1 R_before_B=0 concurrent_B=1 late_R=2", mode);
  endtask

  task automatic amo_arith();
    addr_t a = 64'h5000_0000;
    data_t old_v, new_v, cmp;
    logic [5:0] add_atop = {axi_pkg::ATOP_ATOMICLOAD, axi_pkg::ATOP_LITTLE_END, axi_pkg::ATOP_ADD};
    excl_monitor_en = 1;
    axi_write(a, 64'h10, CACHEABLE);
    axi_read(a, CACHEABLE);
    axi_amo(a, 64'h5, add_atop, 64'h10, 64'h15);
    axi_amo(a, 64'hffff_ffff_ffff_0000, axi_pkg::ATOP_ATOMICSWAP, 64'h15, 64'hffff_ffff_ffff_0000);
    old_v = 64'hffff_ffff_ffff_0000;
    cmp = {32'h1111_2222, old_v[31:0]};
    axi_amo(a, cmp, axi_pkg::ATOP_ATOMICCMP, old_v, {old_v[63:32], 32'h1111_2222});
    new_v = golden(a);
    cmp = {32'hdead_beef, 32'h0000_0001};
    axi_amo(a, cmp, axi_pkg::ATOP_ATOMICCMP, new_v, new_v);
    axi_write(a + 64, 64'h20, CACHEABLE);
    axi_read(a + 64, CACHEABLE, 1, 1, 0, 0, axi_pkg::RESP_EXOKAY);
    axi_write(a + 64, 64'h30, CACHEABLE, '1, 0, 1, axi_pkg::RESP_EXOKAY, 0);
    axi_read(a + 64, CACHEABLE);
    if (golden(a + 64) !== 64'h30) $fatal(1, "SC result not visible");
    axi_read(a + 128, CACHEABLE, 1, 1, 0, 0, axi_pkg::RESP_EXOKAY);
    axi_write(a + 128, 64'h40, CACHEABLE);
    axi_write(a + 128, 64'h50, CACHEABLE, '1, 0, 1, axi_pkg::RESP_OKAY, 0);
    axi_read(a + 128, CACHEABLE);
    if (golden(a + 128) !== 64'h40) $fatal(1, "failed SC must not store");
    excl_monitor_en = 0;
    $display("[L2TB] AMO arith add=1 swap=1 cas_hit=1 cas_miss=1 lrsc_ok=1 lrsc_fail=1");
  endtask

  // ---- address helpers ------------------------------------------------------
  // Tag/line addressing: set s, tag t → line-aligned address.
  function automatic addr_t line_addr(input int unsigned set_idx, input int unsigned tag);
    return addr_t'((tag << (IDX_BITS + OFF_BITS)) | (set_idx << OFF_BITS));
  endfunction

  // Deterministic LFSR (xorshift64) for the random phase.
  logic [63:0] lfsr = {32'(SEED), 32'h1};
  function automatic addr_t lfsr_next();
    lfsr ^= lfsr << 13; lfsr ^= lfsr >> 7; lfsr ^= lfsr << 17;
    return lfsr;
  endfunction

  // ---- stimulus -------------------------------------------------------------
  localparam logic [3:0] CACHEABLE = 4'b1111;  // MODIFIABLE|RD_ALLOC|WR_ALLOC
  localparam logic [3:0] NONCACHE  = 4'b0010;  // MODIFIABLE only → bypass

  int unsigned rd_acc, wr_acc;

  initial begin
    slv_req = '0;
    if (RR_EN > 1 || SET_ASSOC < 2 || NUM_SETS < 2 || STALL_EVERY == 1)
      $fatal(1, "unsupported TB geometry or stall period");
    $display("[L2TB] config bytes=%0d ways=%0d line_bits=%0d mshr=%0d banks=%0d rr=%0d latency=%0d stalls=%0d seed=%h",
             BYTE_SIZE, SET_ASSOC, LINE_WIDTH, MSHR_DEPTH, DATA_BANKS, RR_EN, MEM_LATENCY, STALL_EVERY, SEED);
    repeat (8) @(negedge clk);
    rst_n = 1'b1;
    repeat (4) @(negedge clk);

    // ---- warm: one line per set, tag 0 ------------------------------------
    phase_begin(); rd_acc = 0;
    for (int s = 0; s < NUM_SETS; s++) begin
      axi_read(line_addr(s, 0), CACHEABLE); rd_acc++;
    end
    phase_end("warm", rd_acc, 0);
    if (cnt_miss - ph_miss != NUM_SETS || cnt_evict != 0) $fatal(1, "cold fill check");

    phase_begin();
    for (int s = 0; s < NUM_SETS; s++) axi_read(line_addr(s, 0), CACHEABLE, BEATS, 0, 12);
    phase_end("warm_hits", NUM_SETS, 0);
    if (cnt_hit - ph_hit != NUM_SETS || mem_ar != ph_mem_ar) $fatal(1, "hit/burst check");

    // ---- capacity: sequential sweep over 2x capacity -----------------------
    phase_begin(); rd_acc = 0;
    for (int l = 0; l < NUM_SETS * SET_ASSOC * 2; l++) begin
      // distinct tags spread across sets → guaranteed all-miss
      axi_read(line_addr(l % NUM_SETS, 16 + l / NUM_SETS), CACHEABLE); rd_acc++;
    end
    phase_end("capacity", rd_acc, 0);

    // ---- thrash: cyclic K=SET_ASSOC+1 lines on set 0 -----------------------
    phase_begin(); rd_acc = 0;
    for (int r = 0; r < 24; r++) begin
      for (int k = 0; k < SET_ASSOC + 1; k++) begin
        axi_read(line_addr(0, 100 + k), CACHEABLE); rd_acc++;
      end
    end
    phase_end("thrash", rd_acc, 0);

    // ---- hot_scan: hot line + rotating scan lines on each set --------------
    // Per set: hot line tag 200, scan tags 300..300+SET_ASSOC-2 (fills the
    // remaining ways), then rotate in one fresh scan line per round.
    phase_begin(); rd_acc = 0;
    for (int s = 0; s < NUM_SETS; s++) begin
      axi_read(line_addr(s, 200), CACHEABLE); rd_acc++;   // hot install
      for (int k = 0; k < SET_ASSOC - 1; k++) begin
        axi_read(line_addr(s, 300 + k), CACHEABLE); rd_acc++;
      end
    end
    for (int r = 0; r < 16; r++) begin
      for (int s = 0; s < NUM_SETS; s++) begin
        axi_read(line_addr(s, 200), CACHEABLE); rd_acc++;              // hot re-read
        axi_read(line_addr(s, 400 + r), CACHEABLE); rd_acc++;          // one scan line
      end
    end
    phase_end("hot_scan", rd_acc, 0);

    // ---- wr_rd: write-through + readback -----------------------------------
    phase_begin(); rd_acc = 0; wr_acc = 0;
    for (int s = 0; s < NUM_SETS; s++) begin
      axi_read (line_addr(s, 500), CACHEABLE); rd_acc++;              // allocate
      axi_write(line_addr(s, 500) + 8, 64'hDEAD_BEEF_0000_0000 + s, CACHEABLE); wr_acc++;
      axi_read (line_addr(s, 500) + 8, CACHEABLE); rd_acc++;          // must see store
    end
    phase_end("wr_rd", rd_acc, wr_acc);

    // ---- nc: non-cacheable bypass ------------------------------------------
    phase_begin(); rd_acc = 0;
    for (int k = 0; k < 16; k++) begin
      axi_read(addr_t'(64'h7000 + k * 8), NONCACHE); rd_acc++;
    end
    phase_end("nc", rd_acc, 0);

    // ---- lfsr: pseudo-random mix over 4x capacity ---------------------------
    phase_begin(); rd_acc = 0; wr_acc = 0;
    for (int i = 0; i < 512; i++) begin
      addr_t a = line_addr(int'(lfsr_next() % NUM_SETS),
                           int'((lfsr_next() >> 8) % (SET_ASSOC * 4)));
      if (lfsr_next() % 8 == 0) begin
        axi_write(a, lfsr_next(), CACHEABLE); wr_acc++;
      end else begin
        axi_read(a, CACHEABLE); rd_acc++;
      end
    end
    phase_end("lfsr", rd_acc, wr_acc);

    @(negedge clk); rst_n = 0;
    repeat (4) @(negedge clk);
    rst_n = 1;
    repeat (4) @(negedge clk);
    phase_begin();
    for (int w = 0; w < SET_ASSOC; w++) axi_read(line_addr(0, 600 + w), CACHEABLE);
    phase_end("reset_fill", SET_ASSOC, 0);
    if (cnt_miss - ph_miss != SET_ASSOC || cnt_evict != ph_evict) $fatal(1, "reset/invalid-first check");
    phase_begin();
    for (int w = 0; w < SET_ASSOC; w++) axi_read(line_addr(0, 600 + w), CACHEABLE);
    phase_end("all_ways_hit", SET_ASSOC, 0);
    if (cnt_hit - ph_hit != SET_ASSOC) $fatal(1, "invalid-first did not preserve all ways");

    phase_begin(); rd_acc = 0;
    for (int r = 0; r < 32; r++) begin
      axi_read(line_addr(0, 700 + r), CACHEABLE); rd_acc++;
      for (int w = 1; w < SET_ASSOC; w++) begin
        axi_read(line_addr(0, 600 + w), CACHEABLE); rd_acc++;
      end
    end
    phase_end("protected_hot", rd_acc, 0);

    if (!eq_run) begin
      phase_begin();
      axi_read(line_addr(1, 900), CACHEABLE);
      axi_read(line_addr(1, 900) + 8, CACHEABLE, 2, 0, 30);
      @(negedge clk);
      back_inval_addr = line_addr(1, 900); back_inval_valid = 1;
      @(posedge clk);
      if (!back_inval_ready) $fatal(1, "invalidation not accepted");
      @(negedge clk); back_inval_valid = 0;
      axi_read(line_addr(1, 900), CACHEABLE);
      axi_write(line_addr(1, 900) + 8, 64'hcafe_abcd_7654_3210, CACHEABLE, 8'h55, 30);
      axi_read(line_addr(1, 900) + 8, CACHEABLE);
      phase_end("invalidate_masked", 4, 1);
      if (cnt_miss - ph_miss != 3 || cnt_hit - ph_hit != 1) $fatal(1, "invalidation check");

      phase_begin();
      axi_read(line_addr(1, 900), CACHEABLE, 1, 1);
      axi_read(line_addr(1, 900), NONCACHE);
      axi_read(line_addr(1, 900), CACHEABLE);
      phase_end("exclusive_nc", 3, 0);
      if (cnt_hit - ph_hit != 1 || cnt_bypass - ph_bypass != 2) $fatal(1, "bypass check");
    end

    if ($test$plusargs("bypass-backpressure")) begin
      phase_begin();
      axi_read(line_addr(1, 900), NONCACHE, 1, 0, MEM_LATENCY + 30);
      axi_read(line_addr(1, 901), NONCACHE, BEATS, 0, MEM_LATENCY + 30, 5);
      memory_resp_code = axi_pkg::RESP_EXOKAY;
      axi_read(line_addr(1, 902), CACHEABLE, 1, 1, MEM_LATENCY + 30, 0, axi_pkg::RESP_EXOKAY);
      memory_resp_code = axi_pkg::RESP_SLVERR;
      axi_read(line_addr(1, 903), NONCACHE, 2, 0, MEM_LATENCY + 30, 5, axi_pkg::RESP_SLVERR);
      memory_resp_code = axi_pkg::RESP_DECERR;
      axi_read(line_addr(1, 904), NONCACHE, 1, 0, MEM_LATENCY + 30, 0, axi_pkg::RESP_DECERR);
      memory_resp_code = axi_pkg::RESP_OKAY;
      phase_end("bypass_backpressure", 5, 0);
      if (mem_rbeats - ph_mem_rbeats != BEATS + 5 || cnt_hit != ph_hit || cnt_miss != ph_miss)
        $fatal(1, "bypass response/lookup accounting");
    end

    if ($test$plusargs("atop-drain")) begin
      for (int m = 0; m < 3; m++) atop_forward(m);
      phase_begin();
      axi_read(line_addr(1, 990), CACHEABLE, BEATS, 0, 30, 2);
      axi_read(line_addr(1, 990), CACHEABLE);
      phase_end("post_atop_fill", 2, 0);
      if (cnt_miss - ph_miss != 1 || cnt_hit - ph_hit != 1) $fatal(1, "post-ATOP fill/hit");
      phase_begin();
      inject_short_r = 1;
      axi_read(line_addr(1, 991), CACHEABLE, BEATS);
      inject_short_r = 0;
      phase_end("short_last_fill_guard", 1, 0);
      if (mem_rbeats - ph_mem_rbeats != BEATS + 1 || fills - ph_fills != 1 || dut.gen_l2.mst_r_ot_q)
        $fatal(1, "short-last recovery accounting");
    end

    // Cacheable fill error: SLVERR/DECERR fill beats must propagate their resp
    // to the requester, install NO line, and leave a clean retry (the second
    // read must miss+refill, not hit a poisoned install). Bypass-error tests
    // alone do not cover this path.
    phase_begin();
    memory_resp_code = axi_pkg::RESP_SLVERR;
    axi_read(line_addr(1, 950), CACHEABLE, BEATS, 0, MEM_LATENCY + 30, 0, axi_pkg::RESP_SLVERR);
    memory_resp_code = axi_pkg::RESP_OKAY;
    axi_read(line_addr(1, 950), CACHEABLE, BEATS);
    memory_resp_code = axi_pkg::RESP_DECERR;
    axi_read(line_addr(2, 951), CACHEABLE, BEATS, 0, MEM_LATENCY + 30, 0, axi_pkg::RESP_DECERR);
    memory_resp_code = axi_pkg::RESP_OKAY;
    axi_read(line_addr(2, 951), CACHEABLE, BEATS);
    phase_end("fill_error_no_install", 4, 0);
    if (cnt_miss - ph_miss != 4 || cnt_hit != ph_hit || fills - ph_fills != 4)
      $fatal(1, "fill-error poisoned install or resp drop");

    @(negedge clk); rst_n = 0;
    repeat (4) @(negedge clk);
    rst_n = 1;
    repeat (4) @(negedge clk);
    if (!eq_run) begin
      phase_begin();
      for (int w = 0; w < SET_ASSOC; w++) axi_read(line_addr(NUM_SETS - 1, 1100 + w), CACHEABLE);
      @(negedge clk);
      back_inval_addr = line_addr(NUM_SETS - 1, 1101); back_inval_valid = 1;
      @(posedge clk);
      if (!back_inval_ready) $fatal(1, "hole invalidation not accepted");
      @(negedge clk); back_inval_valid = 0;
      axi_read(line_addr(NUM_SETS - 1, 1200), CACHEABLE);
      axi_read(line_addr(NUM_SETS - 1, 1201), CACHEABLE);
      phase_end("replacement_hole", SET_ASSOC + 2, 0);
      if (cnt_evict - ph_evict != 1 || cnt_hit != ph_hit) $fatal(1, "hole refill/eviction coverage");
    end

    if (policy_lookups != cnt_hit + cnt_miss || policy_installs != fills - fill_errors ||
        policy_evictions != cnt_evict || policy_lookups == 0 || policy_installs == 0 ||
        policy_evictions == 0 || policy_evicted_ways !== (RR_EN != 0 ? '1 : SET_ASSOC'(1)))
      $fatal(1, "empty or incomplete replacement coverage");
    $display("[L2TB] policy checks lookups=%0d installs=%0d evictions=%0d victim_mask=%h",
             policy_lookups, policy_installs, policy_evictions, policy_evicted_ways);

    if ($test$plusargs("amo-arith")) amo_arith();

    if ($test$plusargs("mshr-observe")) begin
      if (size_live != 0 || size_peak != 1 || size_allocations == 0 || size_allocations != size_completions)
        $fatal(1, "L2SIZE_EMPTY_OR_INCOMPLETE");
      $display("[L2SIZE] peak=%0d allocated=%0d completed=%0d", size_peak, size_allocations, size_completions);
    end

    // ---- verdict ------------------------------------------------------------
    $display("[L2TB] totals reads=%0d writes=%0d hits=%0d misses=%0d evictions=%0d bypass=%0d mshr_full=%0d bank_conf=%0d cycles=%0d",
             total_reads, total_writes, cnt_hit, cnt_miss, cnt_evict,
             cnt_bypass, cnt_mshr_full, cnt_bankconf, cyc_q);
    if (fails == 0)
      $display("[L2TB] RESULT pass");
    else
      $fatal(1, "[L2TB] RESULT fail errors=%0d", fails);
    $finish;
  end

  // count driver-side accesses for the totals line
  always @(posedge clk) if (rst_n) begin
    if (slv_req.ar_valid && slv_resp.ar_ready) total_reads++;
    if (slv_req.aw_valid && slv_resp.aw_ready) total_writes++;
  end

  // global watchdog
  initial begin
    #20ms;
    $display("[L2TB] RESULT fail watchdog");
    $fatal(1);
  end

`ifdef L2TB_DEBUG
  // hierarchical probe: DUT FSM + channel handshakes around wr_rd (~cyc 17k)
  initial begin
    @(posedge rst_n);
    forever begin
      @(posedge clk);
      if (dbg_arm == 0 && slv_req.aw_valid) dbg_arm = 1;
      if (dbg_arm > 0 && dbg_arm < 80) begin
        dbg_arm++;
        $display("[DBG] cyc=%0d st=%0d awv=%b awr=%b wv=%b wr=%b bv=%b br=%b m_awv=%b m_awr=%b m_wv=%b m_wr=%b m_bv=%b m_br=%b",
                 cyc_q, dut.gen_l2.state_q,
                 slv_req.aw_valid, slv_resp.aw_ready, slv_req.w_valid, slv_resp.w_ready,
                 slv_resp.b_valid, slv_req.b_ready,
                 mst_req.aw_valid, mst_resp.aw_ready, mst_req.w_valid, mst_resp.w_ready,
                 mst_resp.b_valid, mst_req.b_ready);
      end
    end
  end
  int dbg_arm = 0;
`endif

endmodule
`endif

`ifdef L2TB_SYNTH
module g6lc_l2_fixture
  import g6lc_l2_tb_pkg::*;
#(
  parameter int unsigned BYTE_SIZE = 4096,
  parameter int unsigned SET_ASSOC = 4,
  parameter int unsigned RR_EN = 0,
  parameter int unsigned EQ_NEGATIVE = 0,
  parameter bit FAIR_WRITES = 1'b0,
  parameter int unsigned MSHR_DEPTH = 4,
  parameter int unsigned DATA_BANKS = 2,
  parameter bit CHAIN_L3 = 1'b0,
  parameter bit TAG_SRAM = 1'b0,
  // The flop-vs-SRAM miter excludes back-invalidation: its two-cycle commit
  // (vs one on the flop path) is a permitted timing difference.
  parameter bit NO_INVAL = 1'b0
)(
  input logic clk_i, rst_ni,
  input req_t slv_req_i,
  output resp_t slv_resp_o,
  output req_t mst_req_o,
  input resp_t mst_resp_i,
  output logic hit_o, miss_o, bypass_o, full_o, conflict_o, evict_o,
  output addr_t evict_addr_o,
  input logic inval_i,
  input addr_t inval_addr_i,
  output logic inval_ready_o
);
  logic actual_hit;
  req_t cache_req;
  resp_t cache_resp;
  assign hit_o = EQ_NEGATIVE != 0 ? !actual_hit : actual_hit;
  if(CHAIN_L3)begin : gen_l3_chain
    g6lc_l3_top #(
      .Enable(1'b1),.BYTE_SIZE(2048),.SET_ASSOC(2),.LINE_WIDTH(512),
      .MSHR_DEPTH(2),.DATA_BANKS(2),
`ifndef L2TB_LEGACY
      .TAG_SRAM(TAG_SRAM),
`endif
      .AXI_ADDR_WIDTH(AW),.AXI_DATA_WIDTH(DW),
      .AXI_ID_WIDTH(IDW),.AXI_USER_WIDTH(UW),.axi_req_t(req_t),.axi_resp_t(resp_t)
    ) i_l3 (
      .clk_i,.rst_ni,.slv_req_i(cache_req),.slv_resp_o(cache_resp),
      .mst_req_o,.mst_resp_i,.l3_hit_o(),.l3_miss_o(),.l3_bypass_o(),
`ifndef L2TB_LEGACY
      .l3_selfinv_hit_o(),
`endif
      .l3_evict_valid_o(),.l3_evict_addr_o(),.l3_evict_ready_i(1'b1)
    );
  end else begin : gen_l2_only
    assign mst_req_o=cache_req;
    assign cache_resp=mst_resp_i;
  end
  g6lc_l2_top #(
    .BYTE_SIZE(BYTE_SIZE), .SET_ASSOC(SET_ASSOC), .LINE_WIDTH(512),
    .MSHR_DEPTH(MSHR_DEPTH), .DATA_BANKS(DATA_BANKS),
`ifndef L2TB_LEGACY
    .RR_EN(bit'(RR_EN)),
    .FAIR_WRITES(FAIR_WRITES),
    .TAG_SRAM(TAG_SRAM),
`endif
    .axi_req_t(req_t), .axi_resp_t(resp_t)
  ) i_l2 (
    .clk_i, .rst_ni, .slv_req_i, .slv_resp_o, .mst_req_o(cache_req), .mst_resp_i(cache_resp),
    .l2_hit_o(actual_hit), .l2_miss_o(miss_o), .l2_bypass_o(bypass_o),
    .l2_mshr_full_o(full_o), .l2_bank_conflict_o(conflict_o),
`ifndef L2TB_LEGACY
    .l2_selfinv_hit_o(),
`endif
    .l2_evict_valid_o(evict_o), .l2_evict_addr_o(evict_addr_o),
`ifndef L2TB_LEGACY
    .l2_evict_ready_i(1'b1),
`endif
    .l2_back_inval_valid_i(
`ifndef L2TB_LEGACY
      NO_INVAL ? 1'b0 : inval_i
`else
      inval_i
`endif
    ), .l2_back_inval_addr_i(inval_addr_i),
    .l2_back_inval_ready_o(inval_ready_o)
  );
endmodule
`endif

`ifdef L2TB_CONFIG_TEST
module tb_g6lc_l2_config;
  localparam config_pkg::cva6_cfg_t Cfg = build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);
  initial begin
    config_pkg::cva6_cfg_t changed;
    config_pkg::cva6_user_cfg_t user_cfg;
    int bad_cfg;
    if (Cfg.L2RoundRobinEn || cva6_config_pkg::cva6_cfg.L2RoundRobinEn)
      $fatal(1, "production replacement default changed");
    user_cfg = cva6_config_pkg::cva6_cfg;
    user_cfg.L2En = 1; user_cfg.L2RoundRobinEn = 1;
    changed = build_config_pkg::build_config(user_cfg);
    if (!changed.L2RoundRobinEn || !changed.L2En) $fatal(1, "replacement config lost");
    if ($value$plusargs("bad-cfg=%d", bad_cfg)) begin
      if (bad_cfg == 1) changed.L2En = 0;
      if (bad_cfg == 2) changed.L2SetAssoc = 1;
      if (bad_cfg == 3) changed.L2SetAssoc = 3;
    end
    config_pkg::check_cfg(changed);
    $display("[L2CFG] RESULT pass");
    $finish;
  end
endmodule
`endif
