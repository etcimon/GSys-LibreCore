// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// tb_g6lc_sf_precision — snoop-filter soundness, precision drift and
// observability on the real g6lc_coherence_hub with NC random cores.
//
// Every core runs one transaction at a time: a read (AR -> R) or an
// invalidating write-through store (AW cache=0xf -> W -> B) to a line drawn
// from its private slice (written only by its owner) or a shared slice. The
// bench keeps its own L1 model, independent of the DUT's arrays:
//   holds[c][line]  set when core c's fill R completes, cleared when an
//                   invalidation of the line (or an all_ways one) is handed to
//                   core c on inv_core_o/inv_core_ready_i.
// Checks
//   SF_STALE      soundness: when a write's B reaches the writer, no other core
//                 may still hold the line from a fill whose AR was accepted
//                 before the write's AW (the hub withholds B until delivery).
//   SF_OBS_COUNT  coh_sf_hit_o + coh_sf_overapprox_o must pulse exactly once
//                 per invalidating write (+check_obs).
//   SF_OBS_BLIND  if the hub delivered fewer invalidations than a broadcast
//                 would, the filter spared someone, so coh_sf_hit_o must have
//                 fired at least once (+check_obs).
//   SF_DRIFT      +max_drift_pct=N: the last window's wasted invalidations per
//                 write may not exceed the first displaced window's by more
//                 than N percent.
// Metrics (per window of WIN writes): wasted = invalidations delivered to a
// core that did not hold the line; needed = other holders at AW time.
// +oracle_negative perturbs the observed state (drops one delivered
// invalidation from the model's clear) so SF_STALE must fire.

`timescale 1ns/1ps

module tb_g6lc_sf_precision;
  import g6lc_coherence_pkg::*;
  import g6lc_l2_tb_pkg::*;

  parameter int unsigned NC         = 4;
  parameter bit          OOO        = 1'b1;   // COH_OOO (signature + tagged) vs COH_FILTERED
  parameter int unsigned SF_ENTRIES = 16;
  parameter int unsigned OT         = 8;
  parameter int unsigned LINES_PER_CORE = 24; // private slice per core
  parameter int unsigned SHARED_LINES   = 16;
  parameter int unsigned WRITE_PCT  = 50;
  parameter int unsigned SHARED_PCT = 25;
  parameter int unsigned OPS        = 4000;   // total writes to observe
  parameter int unsigned WIN        = 500;
  parameter int unsigned INV_STALL_PCT = 10;
  parameter int unsigned SEED       = 32'h5f5f_0001;
  localparam int unsigned LINE_BYTES = 64;
  localparam int unsigned CID_W = (NC <= 1) ? 1 : $clog2(NC);

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;

  req_t  [NC-1:0] core_req;
  resp_t [NC-1:0] core_rsp;
  req_t  mem_req;
  resp_t mem_rsp;
  coh_inval_t [NC-1:0] inv;
  logic [NC-1:0] inv_ready;
  logic sf_hit, sf_over;

  g6lc_coherence_hub #(
    .NR_CORES(NC), .MAX_OUTSTANDING(OT), .INVAL_DEPTH(4),
    .SNOOP_FILTER_EN(1'b1), .SNOOP_FILTER_ENTRIES(SF_ENTRIES), .LINE_BYTES(LINE_BYTES),
    .POLICY(OOO ? config_pkg::COH_OOO : config_pkg::COH_FILTERED),
    .axi_req_t(req_t), .axi_resp_t(resp_t)
  ) dut (
    .clk_i(clk), .rst_ni(rst_n), .core_req_i(core_req), .core_resp_o(core_rsp),
    .mem_req_o(mem_req), .mem_resp_i(mem_rsp),
    .inv_core_o(inv), .inv_core_ready_i(inv_ready),
    .lr_valid_i(1'b0), .lr_addr_i('0), .lr_core_i('0),
    .coh_inv_fire_o(), .coh_sf_hit_o(sf_hit), .coh_sf_overapprox_o(sf_over),
    .coh_arb_starve_o(), .coh_split_conflict_o(), .coh_sc_noresv_o(), .coh_lr_kill_o(),
    .hub_aw_sc_collide_o(), .hub_ar_wr_hold_o(), .hub_aw_hold_slot_o(), .hub_aw_hold_other_o()
  );

  // ---- deterministic PRNG ---------------------------------------------------
  int unsigned rng = SEED;
  function automatic int unsigned rnd(input int unsigned n);
    rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5;
    return (n == 0) ? 0 : rng % n;
  endfunction

  function automatic addr_t line_addr(input int unsigned line);
    return addr_t'(64'h8000_0000 + longint'(line) * LINE_BYTES);
  endfunction

  // ---- L1 model -------------------------------------------------------------
  bit          holds   [NC][int unsigned];
  longint      fill_ar [NC][int unsigned];   // AR acceptance cycle of the held fill
  longint      cyc = 0;
  bit          negative, check_obs;
  int unsigned max_drift_pct;

  // ---- per-core drivers -----------------------------------------------------
  typedef enum logic [2:0] {S_IDLE, S_AR, S_R, S_AW, S_W, S_B} st_t;
  st_t         st [NC];
  int unsigned cur_line [NC];
  longint      aw_cyc [NC];
  longint      ar_cyc [NC];
  bit          drop_one = 1'b0;               // negative control armed
  int unsigned writes = 0, inval_writes = 0, delivered = 0, wasted = 0, needed = 0;
  int unsigned hits = 0, overs = 0, stale = 0;
  int unsigned w_writes = 0, w_deliv = 0, w_wasted = 0, w_needed = 0, w_hits = 0, w_overs = 0;
  int unsigned win_no = 0, first_disp_wasted_x1000 = 0, last_wasted_x1000 = 0;
  bit          have_first = 1'b0;

  function automatic int unsigned pick_line(input int unsigned c);
    if (rnd(100) < SHARED_PCT) return NC * LINES_PER_CORE + rnd(SHARED_LINES);
    return c * LINES_PER_CORE + rnd(LINES_PER_CORE);
  endfunction

  // ---- memory model: immediate accept, one-beat R, in-order B ---------------
  id_t rq [$];
  id_t wq [$];
  id_t bq [$];

  always @(posedge clk) begin
    if (!rst_n) begin
      mem_rsp <= '0;
      rq.delete(); wq.delete(); bq.delete();
    end else begin
      resp_t nxt;
      nxt = mem_rsp;
      nxt.ar_ready = 1'b1; nxt.aw_ready = 1'b1; nxt.w_ready = 1'b1;
      if (mem_req.ar_valid && mem_rsp.ar_ready) rq.push_back(mem_req.ar.id);
      if (mem_req.aw_valid && mem_rsp.aw_ready) wq.push_back(mem_req.aw.id);
      if (mem_req.w_valid && mem_rsp.w_ready && mem_req.w.last) begin
        if (wq.size() == 0) $fatal(1, "SF_TB_MEM W without AW");
        bq.push_back(wq.pop_front());
      end
      if (mem_rsp.r_valid && mem_req.r_ready) begin void'(rq.pop_front()); nxt.r_valid = 1'b0; end
      if (mem_rsp.b_valid && mem_req.b_ready) begin void'(bq.pop_front()); nxt.b_valid = 1'b0; end
      if (!nxt.r_valid && rq.size() != 0) begin
        nxt.r_valid = 1'b1; nxt.r = '0; nxt.r.id = rq[0]; nxt.r.last = 1'b1;
      end
      if (!nxt.b_valid && bq.size() != 0) begin
        nxt.b_valid = 1'b1; nxt.b = '0; nxt.b.id = bq[0];
      end
      mem_rsp <= nxt;
    end
  end

  // ---- invalidation delivery + model clear ----------------------------------
  always @(posedge clk) begin
    if (!rst_n) begin
      inv_ready <= '1;
    end else begin
      for (int unsigned c = 0; c < NC; c++) begin
        if (inv[c].valid && inv_ready[c]) begin
          delivered++; w_deliv++;
          if (inv[c].all_ways) begin
            holds[c].delete();
          end else begin
            int unsigned l;
            l = int'((inv[c].line_addr - coh_line_tag(64'h8000_0000, LINE_BYTES)));
            if (!holds[c].exists(l) || !holds[c][l]) begin wasted++; w_wasted++; end
            if (negative && !drop_one && holds[c].exists(l) && holds[c][l]) drop_one = 1'b1;
            else holds[c][l] = 1'b0;
          end
        end
        inv_ready[c] <= (rnd(100) >= INV_STALL_PCT);
      end
      if (sf_hit)  begin hits++;  w_hits++;  end
      if (sf_over) begin overs++; w_overs++; end
    end
  end

  // ---- core FSMs --------------------------------------------------------------
  always @(posedge clk) begin
    cyc <= cyc + 1;
    if (!rst_n) begin
      for (int unsigned c = 0; c < NC; c++) begin
        st[c] = S_IDLE;
        core_req[c] <= '0;
      end
    end else begin
      for (int unsigned c = 0; c < NC; c++) begin
        req_t q;
        q = core_req[c];
        q.r_ready = 1'b1; q.b_ready = 1'b1;
        unique case (st[c])
          S_IDLE: if (writes < OPS) begin
            cur_line[c] = pick_line(c);
            // Shared lines may be written by anyone; private ones by their owner.
            if (rnd(100) < WRITE_PCT) begin
              q.aw = '0; q.aw.addr = line_addr(cur_line[c]); q.aw.id = id_t'(c);
              q.aw.size = 3; q.aw.burst = 1; q.aw.cache = 4'hf;
              q.aw_valid = 1'b1; st[c] = S_AW;
            end else begin
              q.ar = '0; q.ar.addr = line_addr(cur_line[c]); q.ar.id = id_t'(c);
              q.ar.size = 3; q.ar.burst = 1; q.ar.cache = 4'hf;
              q.ar_valid = 1'b1; st[c] = S_AR;
            end
          end
          S_AR: if (core_rsp[c].ar_ready) begin
            q.ar_valid = 1'b0; ar_cyc[c] = cyc; st[c] = S_R;
          end
          S_R: if (core_rsp[c].r_valid) begin
            holds[c][cur_line[c]] = 1'b1;
            fill_ar[c][cur_line[c]] = ar_cyc[c];
            st[c] = S_IDLE;
          end
          S_AW: if (core_rsp[c].aw_ready) begin
            q.aw_valid = 1'b0; aw_cyc[c] = cyc;
            for (int unsigned o = 0; o < NC; o++)
              if (o != c && holds[o].exists(cur_line[c]) && holds[o][cur_line[c]]) begin
                needed++; w_needed++;
              end
            q.w = '0; q.w.data = 64'(cyc); q.w.strb = '1; q.w.last = 1'b1;
            q.w_valid = 1'b1; st[c] = S_W;
          end
          S_W: if (core_rsp[c].w_ready) begin
            q.w_valid = 1'b0; st[c] = S_B;
          end
          S_B: if (core_rsp[c].b_valid) begin
            for (int unsigned o = 0; o < NC; o++)
              if (o != c && holds[o].exists(cur_line[c]) && holds[o][cur_line[c]] &&
                  fill_ar[o][cur_line[c]] < aw_cyc[c]) begin
                stale++;
                $display("SF_STALE cyc=%0d writer=%0d holder=%0d line=%0d fill_ar=%0d aw=%0d",
                         cyc, c, o, cur_line[c], fill_ar[o][cur_line[c]], aw_cyc[c]);
              end
            writes++; inval_writes++; w_writes++;
            if (w_writes == WIN) window_report();
            st[c] = S_IDLE;
          end
          default: ;
        endcase
        core_req[c] <= q;
      end
    end
  end

  task automatic window_report();
    int unsigned wx;
    wx = (w_wasted * 1000) / w_writes;
    $display("SF_WINDOW win=%0d writes=%0d delivered=%0d wasted=%0d needed=%0d hit=%0d over=%0d wasted_per_write_x1000=%0d bcast_pct=%0d",
             win_no, w_writes, w_deliv, w_wasted, w_needed, w_hits, w_overs, wx,
             (w_overs * 100) / w_writes);
    // The first window is the cold system; drift is measured from the second
    // (the working set exceeds SF_ENTRIES, so displacement is under way).
    if (win_no == 1) begin first_disp_wasted_x1000 = wx; have_first = 1'b1; end
    last_wasted_x1000 = wx;
    win_no++;
    w_writes = 0; w_deliv = 0; w_wasted = 0; w_needed = 0; w_hits = 0; w_overs = 0;
  endtask

  initial begin
    negative  = $test$plusargs("oracle_negative");
    check_obs = $test$plusargs("check_obs");
    max_drift_pct = 0;
    void'($value$plusargs("max_drift_pct=%d", max_drift_pct));
    repeat (4) @(posedge clk);
    rst_n = 1'b1;
    wait (writes >= OPS);
    repeat (50) @(posedge clk);
    $display("SF_TOTAL nc=%0d ooo=%0d sf_entries=%0d writes=%0d delivered=%0d wasted=%0d needed=%0d hit=%0d over=%0d stale=%0d first_disp_x1000=%0d last_x1000=%0d",
             NC, OOO, SF_ENTRIES, writes, delivered, wasted, needed, hits, overs, stale,
             first_disp_wasted_x1000, last_wasted_x1000);
    if (stale != 0) $fatal(1, "SF_STALE %0d stale sharers", stale);
    if (check_obs) begin
      if (hits + overs != inval_writes)
        $fatal(1, "SF_OBS_COUNT hit+over=%0d invalidating_writes=%0d", hits + overs, inval_writes);
      // 90 %: the invalidation bus may coalesce same-line deliveries, which
      // lowers `delivered` without any filtering having happened.
      if (delivered * 10 < inval_writes * (NC - 1) * 9 && hits == 0)
        $fatal(1, "SF_OBS_BLIND delivered=%0d < broadcast=%0d but coh_sf_hit_o never fired",
               delivered, inval_writes * (NC - 1));
    end
    if (max_drift_pct != 0 && have_first &&
        last_wasted_x1000 * 100 > first_disp_wasted_x1000 * (100 + max_drift_pct))
      $fatal(1, "SF_DRIFT last=%0d first_displaced=%0d (x1000 wasted/write) > +%0d%%",
             last_wasted_x1000, first_disp_wasted_x1000, max_drift_pct);
    $display("RTL_REVIEW_PASS sf_precision");
    $finish;
  end

  initial begin
    #50_000_000;
    $fatal(1, "SF_TIMEOUT writes=%0d", writes);
  end
endmodule
