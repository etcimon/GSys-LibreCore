// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Leaf testbench for the T9a CMO engine (g6lc_cmo_engine) and its L1
// broadcaster (g6lc_l3_inclusive_inv #(.InclusiveEn(1)) — the same pairing
// the cluster instantiates). Drives the core-side cmo_* sideband and the
// L2/L3 match-inval backpressure, and checks:
//   sc0  arbiter fairness — round-robin, not fixed priority: a request set
//        {0,1} leaves the rr pointer at 2, so the next {0,1,2} round must
//        grant core 2 first; each cmo_done_o pulses exactly once;
//   sc1  broadcast backpressure — a core's inv_ready held low holds the
//        broadcast's inv_o and blocks done until released;
//   sc2  L2 match-inval handshake under contention — l2_inval_ready_i held
//        low (the cluster's inclusive-victim slot win) keeps l2_inval_valid_o
//        raised with a stable address; completion only after the slot frees;
//   sc3  clean/flush waits for l2_write_idle_i && l3_write_idle_i and touches
//        neither the broadcast nor the match-inval ports;
//   sc4  L3 match-inval is driven too (L3_EN builds) and honours its ready.
// A request line is auto-cleared one cycle after its grant so a held valid
// cannot be re-granted.
// Negative arms (+oracle_negative +neg_kind=n):
//   neg0 dropped core — one inv_ready tied low forever: done never pulses and
//        the per-request wait bound expires (CMO_NO_DONE);
//   neg1 dropped level — l2_inval_ready_i tied low forever: same;
//   neg2 early done — any done preceding full completion hits CMO_EARLY_DONE
//        (the runner's source mutation makes the engine finish early).
//
// PASS token: CMO_ENGINE_PASS

module tb_g6lc_cmo_engine;
  import g6lc_coherence_pkg::*;

  parameter int NR_CORES  = 3;
  parameter int L3_EN_P   = 1;
  localparam int AW = 64;
  localparam int LINE_BYTES = 16;

  logic clk = 0, rst_n = 0;
  logic [NR_CORES-1:0]       cmo_req_v  = '0;
  logic [1:0]                cmo_req_op [NR_CORES];
  logic [AW-1:0]             cmo_req_a  [NR_CORES];
  logic [NR_CORES-1:0]       cmo_ready, cmo_done;
  logic                      bcast_v, bcast_rdy, bcast_done;
  logic [AW-1:0]             bcast_a;
  coh_inval_t [NR_CORES-1:0] bcast_inv;
  logic [NR_CORES-1:0]       inv_rdy = '1;
  logic                      l2_v, l2_rdy = 1'b1;
  logic [AW-1:0]             l2_a;
  logic                      l3_v, l3_rdy = 1'b1;
  logic [AW-1:0]             l3_a;
  logic                      l2_idle = 1'b1, l3_idle = 1'b1;

  bit negative;
  int neg_kind = 0;
  int cycle = 0;

  int done_count[NR_CORES];
  int req_issued[NR_CORES];
  int grant_order[$];
  int bcast_ack_count[NR_CORES];
  int l2_apply_count = 0, l3_apply_count = 0;
  logic [AW-1:0] l2_held_addr;
  int l2_held_cycles = 0;
  logic l2_holding = 0;
  // Per-request completion flags for the early-done oracle: set when the
  // corresponding push completes for the in-flight request, cleared on grant.
  logic l2_seen_done = 0, l3_seen_done = 0, bcast_seen_done = 0;
  logic [1:0] pend_op = '0;

  task automatic tick;
    begin
      #5 clk = 1;
      #5 clk = 0;
      cycle++;
    end
  endtask

  g6lc_l3_inclusive_inv #(
      .InclusiveEn(1'b1), .NR_CORES(NR_CORES), .LINE_BYTES(LINE_BYTES),
      .AXI_ADDR_WIDTH(AW)
  ) i_bcast (
      .clk_i(clk), .rst_ni(rst_n),
      .evict_valid_i(bcast_v), .evict_addr_i(bcast_a),
      .inv_ready_i(inv_rdy), .inv_o(bcast_inv), .inv_busy_o(),
      .evict_ready_o(bcast_rdy), .drain_done_o(bcast_done)
  );

  g6lc_cmo_engine #(
      .NR_CORES(NR_CORES), .L2_EN(1'b1), .L3_EN(L3_EN_P != 0),
      .AXI_ADDR_WIDTH(AW)
  ) i_engine (
      .clk_i(clk), .rst_ni(rst_n),
      .cmo_valid_i(cmo_req_v), .cmo_op_i(cmo_req_op),
      .cmo_addr_i(cmo_req_a), .cmo_ready_o(cmo_ready),
      .cmo_done_o(cmo_done),
      .l1_bcast_valid_o(bcast_v), .l1_bcast_addr_o(bcast_a),
      .l1_bcast_ready_i(bcast_rdy), .l1_bcast_done_i(bcast_done),
      .l2_inval_valid_o(l2_v), .l2_inval_addr_o(l2_a),
      .l2_inval_ready_i(l2_rdy),
      .l3_inval_valid_o(l3_v), .l3_inval_addr_o(l3_a),
      .l3_inval_ready_i(l3_rdy),
      .l2_write_idle_i(l2_idle), .l3_write_idle_i(l3_idle)
  );

  // Auto-clear a request line one cycle after its grant.
  always_ff @(posedge clk)
    for (int c = 0; c < NR_CORES; c++)
      if (cmo_ready[c]) cmo_req_v[c] <= 1'b0;

  // Grants, dones, per-core broadcast acks and level-push applies.
  always_ff @(posedge clk) begin
    for (int c = 0; c < NR_CORES; c++) begin
      if (cmo_ready[c]) begin
        grant_order.push_back(c);
        req_issued[c] <= req_issued[c] + 1;
        pend_op       <= cmo_req_op[c];
      end
      if (cmo_done[c]) begin
        done_count[c] <= done_count[c] + 1;
        if (done_count[c] + 1 > req_issued[c])
          $fatal(1, "CMO_EARLY_DONE core=%0d done=%0d issued=%0d",
                 c, done_count[c] + 1, req_issued[c]);
        if (pend_op == 2'd0 &&
            !(l2_seen_done && (L3_EN_P == 0 || l3_seen_done) && bcast_seen_done))
          $fatal(1, "CMO_EARLY_DONE core=%0d l2=%0d l3=%0d bcast=%0d",
                 c, l2_seen_done, l3_seen_done, bcast_seen_done);
        if (pend_op != 2'd0 && !(l2_idle && l3_idle))
          $fatal(1, "CMO_EARLY_DONE clean core=%0d", c);
      end
      if (bcast_inv[c].valid && inv_rdy[c])
        bcast_ack_count[c] <= bcast_ack_count[c] + 1;
    end
    if (cmo_ready != '0) begin
      l2_seen_done    <= 1'b0;
      l3_seen_done    <= 1'b0;
      bcast_seen_done <= 1'b0;
    end
    if (l2_v && l2_rdy) begin
      l2_apply_count <= l2_apply_count + 1;
      l2_seen_done   <= 1'b1;
    end
    if (l3_v && l3_rdy) begin
      l3_apply_count <= l3_apply_count + 1;
      l3_seen_done   <= 1'b1;
    end
    if (bcast_done) bcast_seen_done <= 1'b1;
  end

  // While the engine waits on l2_inval_ready_i the offered address must be
  // stable and valid must stay raised.
  always_ff @(posedge clk) begin
    if (l2_v && !l2_rdy) begin
      if (l2_holding && l2_a !== l2_held_addr)
        $fatal(1, "CMO_L2_ADDR_UNSTABLE %h -> %h", l2_held_addr, l2_a);
      l2_holding <= 1'b1;
      l2_held_addr <= l2_a;
      l2_held_cycles <= l2_held_cycles + 1;
    end else if (!l2_v) l2_holding <= 1'b0;
  end

  // Global watchdog: negatives hang here by construction.
  always_ff @(posedge clk)
    if (cycle > 20000) $fatal(1, "CMO_TIMEOUT cycle=%0d", cycle);

  // Requests are staged through ask_* regs and moved into cmo_req_* by the
  // clocked process below: under Verilator --timing (5.020), unpacked-array
  // port bindings are not re-synced when a timing process writes the array,
  // so the engine would see stale addresses. A posedge write propagates.
  logic [NR_CORES-1:0] ask_pend = '0;
  logic [1:0]        ask_op  [NR_CORES];
  logic [AW-1:0]     ask_a   [NR_CORES];

  task automatic cmo_ask(input int core, input logic [1:0] op, input logic [AW-1:0] a);
    begin
      if (ask_pend[core] || cmo_req_v[core])
        $fatal(1, "CMO_ASK_COLLIDE core=%0d", core);
      ask_op[core]   = op;
      ask_a[core]    = a;
      ask_pend[core] = 1'b1;
    end
  endtask

  always_ff @(posedge clk)
    for (int c = 0; c < NR_CORES; c++)
      if (ask_pend[c]) begin
        ask_pend[c]   <= 1'b0;
        cmo_req_op[c] <= ask_op[c];
        cmo_req_a[c]  <= ask_a[c];
        cmo_req_v[c]  <= 1'b1;
      end

  task automatic wait_done(input int core, input int prev, input int bound);
    int n;
    begin
      for (n = 0; n < bound && done_count[core] == prev; n++) tick();
      if (done_count[core] == prev) $fatal(1, "CMO_NO_DONE core=%0d", core);
      if (done_count[core] != prev + 1)
        $fatal(1, "CMO_DONE_MULTI core=%0d", core);
    end
  endtask

  initial begin
    negative = $test$plusargs("oracle_negative");
    void'($value$plusargs("neg_kind=%d", neg_kind));
    for (int c = 0; c < NR_CORES; c++) begin
      cmo_req_op[c] = '0;
      cmo_req_a[c]  = '0;
      done_count[c] = 0;
      req_issued[c] = 0;
      bcast_ack_count[c] = 0;
    end
    if (negative && neg_kind == 0) inv_rdy[NR_CORES-1] = 1'b0;  // dropped core
    if (negative && neg_kind == 1) l2_rdy = 1'b0;               // dropped level
    repeat(3) tick();
    rst_n = 1;
    repeat(4) tick();

    // ---- sc0: fairness ----------------------------------------------------
    // Round 1: cores {0,1} request — grants 0 then 1, rr pointer lands on 2.
    cmo_ask(0, 2'd0, 64'h8000_0000);
    cmo_ask(1, 2'd0, 64'h8000_0040);
    wait_done(0, 0, 2000);
    wait_done(1, 0, 2000);
    if (grant_order.size() != 2 || grant_order[0] != 0 || grant_order[1] != 1)
      $fatal(1, "CMO_ARB_ROUND1 %p", grant_order);
    // Round 2: all three request — round-robin must grant core 2 FIRST (a
    // fixed-priority arbiter would pick 0), then 0, then 1.
    cmo_ask(0, 2'd0, 64'h8000_1000);
    cmo_ask(1, 2'd0, 64'h8000_1040);
    cmo_ask(2, 2'd0, 64'h8000_1080);
    wait_done(0, 1, 2000);
    wait_done(1, 1, 2000);
    wait_done(2, 0, 2000);
    if (grant_order.size() != 5 ||
        grant_order[2] != 2 || grant_order[3] != 0 || grant_order[4] != 1)
      $fatal(1, "CMO_ARB_ROTATE %p", grant_order);
    $display("CMO_ENGINE_SC0 grants=%p", grant_order);

    // ---- sc1: broadcast per-core backpressure ------------------------------
    begin
      int ack0[NR_CORES];
      for (int c = 0; c < NR_CORES; c++) ack0[c] = bcast_ack_count[c];
      inv_rdy[1] = 1'b0;
      cmo_ask(0, 2'd0, 64'h8000_2000);
      // Wait until the broadcast is actually offering core 1's inval.
      begin
        int n;
        n = 0;
        while (!bcast_inv[1].valid && n < 2000) begin tick(); n++; end
        if (!bcast_inv[1].valid) $fatal(1, "CMO_BCAST_NOHOLD");
      end
      if (done_count[0] != 2) $fatal(1, "CMO_BCAST_EARLYDONE");
      repeat(5) begin
        tick();
        if (!bcast_inv[1].valid) $fatal(1, "CMO_BCAST_DROPPED");
        if (done_count[0] != 2) $fatal(1, "CMO_BCAST_EARLYDONE");
      end
      inv_rdy[1] = 1'b1;
      wait_done(0, 2, 2000);
      for (int c = 0; c < NR_CORES; c++)
        if (bcast_ack_count[c] != ack0[c] + 1)
          $fatal(1, "CMO_BCAST_ACKS core=%0d", c);
    end
    $display("CMO_ENGINE_SC1 acks=%0d/%0d/%0d",
             bcast_ack_count[0], bcast_ack_count[1], bcast_ack_count[2]);

    // ---- sc2: L2 match-inval under slot contention ------------------------
    l2_rdy = 1'b0;
    cmo_ask(0, 2'd0, 64'h8000_3000);
    begin
      int n;
      n = 0;
      while (!l2_v && n < 2000) begin tick(); n++; end
      if (!l2_v) $fatal(1, "CMO_L2_NOOFFER");
      repeat(4) begin
        tick();
        if (!l2_v) $fatal(1, "CMO_L2_DROPPED_VALID");
        if (done_count[0] != 3) $fatal(1, "CMO_L2_EARLYDONE");
      end
      if (l2_a !== 64'h8000_3000) $fatal(1, "CMO_L2_ADDR %h", l2_a);
      l2_rdy = 1'b1;
      wait_done(0, 3, 2000);
    end
    $display("CMO_ENGINE_SC2 l2_held=%0d applies=%0d", l2_held_cycles, l2_apply_count);

    // ---- sc3: clean waits for write-idle ----------------------------------
    l2_idle = 1'b0;
    cmo_ask(1, 2'd1, 64'h8000_4000);
    begin
      int n;
      repeat(6) begin
        tick();
        if (done_count[1] != 2) $fatal(1, "CMO_CLEAN_EARLYDONE");
      end
      l2_idle = 1'b1;
      l3_idle = 1'b0;
      repeat(4) begin
        tick();
        if (done_count[1] != 2) $fatal(1, "CMO_CLEAN_L3_EARLYDONE");
      end
      l3_idle = 1'b1;
      wait_done(1, 2, 2000);
      n = l2_apply_count;
      tick(); tick();
      if (l2_apply_count != n) $fatal(1, "CMO_CLEAN_L2_INVAL");
    end
    $display("CMO_ENGINE_SC3 done");

    // ---- sc4: L3 match-inval path -----------------------------------------
    if (L3_EN_P != 0) begin
      l3_rdy = 1'b0;
      cmo_ask(2, 2'd0, 64'h8000_5000);
      begin
        int n;
        n = 0;
        while (!l3_v && n < 2000) begin tick(); n++; end
        if (!l3_v) $fatal(1, "CMO_L3_NOOFFER");
        repeat(3) begin
          tick();
          if (!l3_v) $fatal(1, "CMO_L3_DROPPED_VALID");
          if (done_count[2] != 1) $fatal(1, "CMO_L3_EARLYDONE");
        end
        l3_rdy = 1'b1;
        wait_done(2, 1, 2000);
      end
      $display("CMO_ENGINE_SC4 l3_applies=%0d", l3_apply_count);
    end

    if (negative) $fatal(1, "CMO_NEG_UNEXPECTEDLY_COMPLETE neg=%0d", neg_kind);
    $display("CMO_ENGINE_PASS cores=%0d dones=%0d/%0d/%0d l2=%0d l3=%0d",
             NR_CORES, done_count[0], done_count[1], done_count[2],
             l2_apply_count, l3_apply_count);
    $finish;
  end

endmodule
