// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
// Leaf for g6lc_tb_dram_latency_intf: pipelined per-burst DRAM latency.
// The upstream driver talks to the slv port; a permissive always-ready
// backend sits on mst and returns bursts 1 beat/cycle in AR order (except
// scenario 5, which reverses two pending bursts to prove the in-DUT order
// check). oracle_negative flips the expected values, so each scenario must
// die with its own DRAM_LAT_* tag.
module tb_g6lc_tb_dram_latency;
  parameter int unsigned LATENCY = 0;
  parameter int unsigned DEPTH   = 32;
  logic clk = 0, rst_n = 0;

  AXI_BUS #(.AXI_ADDR_WIDTH(64), .AXI_DATA_WIDTH(64), .AXI_ID_WIDTH(4),
            .AXI_USER_WIDTH(1)) up();
  AXI_BUS #(.AXI_ADDR_WIDTH(64), .AXI_DATA_WIDTH(64), .AXI_ID_WIDTH(4),
            .AXI_USER_WIDTH(1)) dn();

  g6lc_tb_dram_latency_intf #(
    .AXI_ID_WIDTH(4), .AXI_ADDR_WIDTH(64), .AXI_DATA_WIDTH(64),
    .AXI_USER_WIDTH(1), .Latency(LATENCY), .Depth(DEPTH)
  ) dut (.clk_i(clk), .rst_ni(rst_n), .slv(up), .mst(dn));

  bit negative;
  int scenario, cycle = 0;

  // ------------------------------------------------------------- backend --
  // AR order is kept in a job queue; the R engine serves one burst at a
  // time, one beat per cycle once started, after a short warmup so two
  // back-to-back ARs coexist in the queue (scenario 5 needs that to serve
  // the newer one first). Scenario 5's positive arm serves the tail of the
  // queue first, violating AR-acceptance order.
  typedef struct packed {logic [3:0] id; logic [7:0] len;} rjob_t;
  rjob_t rq[8];
  int rq_h = 0, rq_n = 0;
  int r_warm = 0;
  logic r_active = 0;
  logic [3:0] r_id = 0;
  logic [7:0] r_len = 0, r_beat = 0;
  logic [3:0] aw_q[8];
  int aw_h = 0, aw_n = 0;
  logic [3:0] bq[8];
  int bq_h = 0, bq_n = 0;

  always_comb begin
    dn.ar_ready = 1;
    dn.aw_ready = 1;
    dn.w_ready  = 1;
    dn.r_valid  = r_active;
    dn.r_id     = r_id;
    dn.r_data   = {48'hc0de_0000_0000, r_id, 4'h0, r_beat};
    dn.r_resp   = '0;
    dn.r_user   = '0;
    dn.r_last   = r_active && (r_beat == r_len);
    dn.b_valid  = bq_n > 0;
    dn.b_id     = bq[bq_h];
    dn.b_resp   = '0;
    dn.b_user   = '0;
  end

  // Upstream observation (posedge numbering): cycle==N at beat_edge N.
  int ar_hs_cycle = -1, w_last_cycle = -1, b_cycle = -1;
  int r_beats = 0, r_id_n = 0;
  int r_beat_ts[64];
  logic [3:0] r_ids[64];
  logic [7:0] r_beat_seq[64];
  bit id_err = 0;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rq_h <= 0; rq_n <= 0; r_warm <= 0; r_active <= 0;
      aw_h <= 0; aw_n <= 0; bq_h <= 0; bq_n <= 0;
    end else begin
      if (dn.ar_valid && dn.ar_ready) begin
        rq[(rq_h + rq_n) % 8] <= '{id: dn.ar_id, len: dn.ar_len};
        rq_n <= rq_n + 1;
        r_warm <= 3;
      end
      if (!r_active && rq_n > 0) begin
        if (r_warm > 0) r_warm <= r_warm - 1;
        else begin
          int idx;
          idx = (scenario == 5 && !negative && rq_n > 1) ? (rq_h + rq_n - 1) % 8 : rq_h;
          r_active <= 1; r_id <= rq[idx].id; r_len <= rq[idx].len; r_beat <= 0;
          if (idx != rq_h) rq[idx] <= rq[rq_h];
          rq_h <= (rq_h + 1) % 8; rq_n <= rq_n - 1;
        end
      end else if (r_active && dn.r_valid && dn.r_ready) begin
        if (r_beat == r_len) r_active <= 0;
        else r_beat <= r_beat + 1'b1;
      end
      if (dn.aw_valid && dn.aw_ready) begin
        aw_q[(aw_h + aw_n) % 8] <= dn.aw_id; aw_n <= aw_n + 1;
      end
      if (dn.w_valid && dn.w_ready && dn.w_last) begin
        bq[(bq_h + bq_n) % 8] <= aw_q[aw_h];
        bq_n <= bq_n + 1;
        if (aw_n > 0) begin aw_h <= (aw_h + 1) % 8; aw_n <= aw_n - 1; end
      end
      if (dn.b_valid && dn.b_ready) begin bq_h <= (bq_h + 1) % 8; bq_n <= bq_n - 1; end
    end
  end

  always @(posedge clk) if (rst_n) begin
    cycle++;
    if (up.ar_valid && up.ar_ready) ar_hs_cycle <= cycle;
    if (up.w_valid && up.w_ready && up.w_last) w_last_cycle <= cycle;
    if (up.b_valid && up.b_ready) b_cycle <= cycle;
    if (up.r_valid && up.r_ready) begin
      if (r_beats < 64) begin
        r_beat_ts[r_beats]  <= cycle;
        r_beat_seq[r_beats] <= up.r_data[7:0];
        r_ids[r_beats]      <= up.r_id;
      end
      r_beats <= r_beats + 1;
      r_id_n  <= r_id_n + 1;
    end
    // scenario 0 identity: handshake coincidence, per channel
    if ((up.ar_valid && up.ar_ready) != (dn.ar_valid && dn.ar_ready)) id_err <= 1;
    if ((up.aw_valid && up.aw_ready) != (dn.aw_valid && dn.aw_ready)) id_err <= 1;
    if ((up.w_valid  && up.w_ready)  != (dn.w_valid  && dn.w_ready))  id_err <= 1;
    if ((up.r_valid  && up.r_ready)  != (dn.r_valid  && dn.r_ready))  id_err <= 1;
    if ((up.b_valid  && up.b_ready)  != (dn.b_valid  && dn.b_ready))  id_err <= 1;
  end

  task automatic tick; #2; clk = 1; #2; clk = 0; #2; endtask

  function automatic int exp_lat;
    return LATENCY + (negative ? 1 : 0);
  endfunction

  task automatic clear_r;
    r_beats = 0; r_id_n = 0;
    for (int i = 0; i < 64; i++) begin r_beat_ts[i] = -1; r_ids[i] = 0; r_beat_seq[i] = 0; end
  endtask

  task automatic send_ar(input logic [3:0] id, input logic [7:0] len,
                         input logic [63:0] addr);
    up.ar_id = id; up.ar_addr = addr; up.ar_len = len; up.ar_size = 3;
    up.ar_burst = 1; up.ar_lock = 0; up.ar_cache = 4'hf; up.ar_prot = 0;
    up.ar_qos = 0; up.ar_region = 0; up.ar_user = 0;
    up.ar_valid = 1;
    for (int n = 0; n < 400; n++) begin
      #1;
      if (up.ar_ready) begin tick(); up.ar_valid = 0; return; end
      tick();
    end
    $fatal(1, "DRAM_LAT_AR_TIMEOUT");
  endtask

  // Mid-window observation `cycle==v` means the handshake lands at beat_edge
  // v+1, so collect_r records beat edges as cycle+1 to match the monitor.
  task automatic collect_r(input int len);
    int first = -1, prev = -1, seen = 0, beat_edge;
    up.r_ready = 1;
    for (int n = 0; n < 2000 && seen < len; n++) begin
      #1;
      if (up.r_valid && up.r_ready) begin
        beat_edge = cycle + 1;
        if (first < 0) first = beat_edge;
        else begin
          if (beat_edge != prev + 1) $fatal(1, "DRAM_LAT_GAP beat=%0d", seen);
          if (up.r_data[7:0] != seen[7:0])
            $fatal(1, "DRAM_LAT_SEQ beat=%0d data=%h", seen, up.r_data[7:0]);
        end
        prev = beat_edge; seen++;
      end
      tick();
    end
    up.r_ready = 0;
    if (seen != len) $fatal(1, "DRAM_LAT_COUNT seen=%0d exp=%0d", seen, len);
    if (first - ar_hs_cycle != exp_lat())
      $fatal(1, "DRAM_LAT_RD gap=%0d exp=%0d", first - ar_hs_cycle, exp_lat());
    clear_r();
  endtask

  task automatic send_write(input logic [3:0] id, input int len);
    bit done;
    done = 0;
    up.aw_id = id; up.aw_addr = 64'h8000_0000 + 64'h40 * id; up.aw_len = len - 1;
    up.aw_size = 3; up.aw_burst = 1; up.aw_lock = 0; up.aw_cache = 4'hf;
    up.aw_prot = 0; up.aw_qos = 0; up.aw_atop = 0; up.aw_region = 0;
    up.aw_user = 0; up.aw_valid = 1;
    for (int n = 0; n < 400 && !done; n++) begin
      #1;
      if (up.aw_ready) begin tick(); up.aw_valid = 0; done = 1; end
      else tick();
    end
    if (!done) $fatal(1, "DRAM_LAT_AW_TIMEOUT");
    for (int i = 0; i < len; i++) begin
      done = 0;
      up.w_data = 64'h1000 + i; up.w_strb = '1; up.w_user = 0;
      up.w_last = (i == len - 1); up.w_valid = 1;
      for (int n = 0; n < 400 && !done; n++) begin
        #1;
        if (up.w_ready) begin tick(); up.w_valid = 0; done = 1; end
        else tick();
      end
      if (!done) $fatal(1, "DRAM_LAT_W_TIMEOUT");
    end
  endtask

  task automatic expect_b;
    int got = -1;
    up.b_ready = 1;
    for (int n = 0; n < 2000 && got < 0; n++) begin
      #1;
      if (up.b_valid && up.b_ready) got = cycle + 1;
      tick();
    end
    up.b_ready = 0;
    if (got < 0) $fatal(1, "DRAM_LAT_B timeout");
    if (got - w_last_cycle != exp_lat())
      $fatal(1, "DRAM_LAT_B gap=%0d exp=%0d", got - w_last_cycle, exp_lat());
  endtask

  initial begin
    up.ar_valid = 0; up.aw_valid = 0; up.w_valid = 0;
    up.r_ready = 0; up.b_ready = 0;
    clear_r();
    negative = $test$plusargs("oracle_negative");
    if (!$value$plusargs("scenario=%d", scenario)) scenario = 0;
    repeat (3) tick(); rst_n = 1; repeat (20) tick();
    case (scenario)
      // Latency==0: every channel handshake must coincide up/dn.
      0: begin
        if (LATENCY != 0) $fatal(1, "DRAM_LAT_ID scenario0 needs LATENCY=0");
        send_ar(4'h3, 8'd7, 64'h8000_0000);
        up.r_ready = 1;
        for (int n = 0; n < 2000 && r_beats < 8; n++) tick();
        up.r_ready = 0;
        send_write(4'h5, 2);
        up.b_ready = 1;
        for (int n = 0; n < 2000 && b_cycle < 0; n++) tick();
        up.b_ready = 0;
        if (id_err != negative) $fatal(1, "DRAM_LAT_ID id_err=%0b", id_err);
      end
      // One 8-beat read: first beat exactly Latency after AR accept, the
      // remaining beats on consecutive cycles, data in beat order.
      1: begin
        send_ar(4'h1, 8'd7, 64'h8000_0000);
        collect_r(8);
      end
      // Two back-to-back ARs: the second burst's first beat is gated by its
      // own deadline (or by burst-1 finishing, whichever is later) and the
      // bursts do not interleave.
      2: begin
        int ar2, first2, exp2;
        send_ar(4'h1, 8'd7, 64'h8000_0000);
        send_ar(4'h2, 8'd7, 64'h8000_1000);
        ar2 = ar_hs_cycle;
        up.r_ready = 1;
        for (int n = 0; n < 2000 && r_id_n < 16; n++) tick();
        up.r_ready = 0;
        if (r_id_n < 16) $fatal(1, "DRAM_LAT_DBL got=%0d", r_id_n);
        for (int i = 0; i < 8; i++) begin
          if (r_ids[i] != 4'h1) $fatal(1, "DRAM_LAT_DBL interleave i=%0d id=%h", i, r_ids[i]);
          if (r_beat_seq[i] != i) $fatal(1, "DRAM_LAT_DBL seq[%0d]=%0d", i, r_beat_seq[i]);
          if (i > 0 && r_beat_ts[i] != r_beat_ts[i-1] + 1)
            $fatal(1, "DRAM_LAT_DBL gap i=%0d", i);
        end
        for (int i = 8; i < 16; i++) begin
          if (r_ids[i] != 4'h2) $fatal(1, "DRAM_LAT_DBL interleave i=%0d id=%h", i, r_ids[i]);
          if (r_beat_seq[i] != i - 8) $fatal(1, "DRAM_LAT_DBL seq[%0d]=%0d", i, r_beat_seq[i]);
          if (i > 8 && r_beat_ts[i] != r_beat_ts[i-1] + 1)
            $fatal(1, "DRAM_LAT_DBL gap i=%0d", i);
        end
        // Burst 2's first beat is the later of its own deadline and the
        // backend's next slot (one reload bubble after burst 1's last beat).
        first2 = r_beat_ts[8];
        exp2 = (ar2 + LATENCY > r_beat_ts[7] + 2) ? ar2 + LATENCY : r_beat_ts[7] + 2;
        if (negative) exp2 = exp2 + 1;
        if (first2 != exp2)
          $fatal(1, "DRAM_LAT_DBL first2=%0d exp=%0d (ar2=%0d)", first2, exp2, ar2);
        clear_r();
      end
      // Write burst: B exactly Latency after the W-last handshake.
      3: begin
        send_write(4'h9, 4);
        expect_b();
      end
      // Backpressure: drop r_ready mid-burst; no beat lost or duplicated.
      4: begin
        int seq[8], sn = 0, stall = 0;
        bit stalled = 0;
        send_ar(4'h4, 8'd7, 64'h8000_2000);
        up.r_ready = 1;
        for (int n = 0; n < 2000 && sn < 8; n++) begin
          if (sn == 3 && !stalled) begin stall = 4; stalled = 1; end
          if (stall > 0) begin up.r_ready = 0; stall--; end
          else up.r_ready = 1;
          #1;
          if (up.r_valid && up.r_ready) begin seq[sn] = up.r_data[7:0]; sn++; end
          tick();
        end
        up.r_ready = 0;
        if (sn != 8) $fatal(1, "DRAM_LAT_BP seen=%0d", sn);
        for (int i = 0; i < 8; i++)
          if (seq[i] != i + (negative ? 1 : 0))
            $fatal(1, "DRAM_LAT_BP seq[%0d]=%0d", i, seq[i]);
        clear_r();
      end
      // Order check: the slave returns the second AR's burst first — the
      // DUT must die with DRAM_LAT_ORDER (positive), or the bench flags the
      // missing check (negative arm serves in order and expects a fatal
      // that correctly never comes: it must fail with its own tag).
      5: begin
        send_ar(4'h1, 8'd7, 64'h8000_0000);
        send_ar(4'h2, 8'd7, 64'h8000_1000);
        up.r_ready = 1;
        repeat (40) tick();
        up.r_ready = 0;
        $fatal(1, "DRAM_LAT_MISS order check did not fire (negative=%0b)", negative);
      end
      default: $fatal(1, "DRAM_LAT_SCENARIO");
    endcase
    repeat (8) tick();
    $display("DRAM_LAT_PASS scenario=%0d latency=%0d", scenario, LATENCY);
    $finish;
  end
endmodule
