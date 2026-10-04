// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
// Directed + seeded-random test of g6lc_apu_objtab against an in-TB
// reference model that mirrors the directory (valid/tomb/id/slot buckets,
// 8-probe cap, lazy tombstoning) and the entry RAM.
module tb_g6lc_apu_objtab;
  import g6lc_apu_objtab_pkg::*;

  localparam int unsigned Slots  = 64;
  localparam int unsigned DirW   = 2 * Slots;
  localparam int unsigned DirB   = $clog2(DirW);

  logic clk = 0, rst_ni = 0, testmode = 0;
  logic req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  apu_objtab_req_t req = '0;
  apu_objtab_cpl_t cpl;
  logic off_rdy, off_v; apu_objtab_cpl_t off_cpl;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_objtab #(.Enable(1'b1), .Slots(Slots)) i_on (
    .clk_i(clk), .rst_ni, .testmode_i(testmode),
    .req_valid_i(req_v), .req_ready_o(req_rdy), .req_i(req),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .live_o());
  g6lc_apu_objtab_fixture #(.Enable(1'b0), .Slots(Slots)) i_off (
    .clk_i(clk), .rst_ni, .testmode_i(testmode),
    .req_valid_i(req_v), .req_ready_o(off_rdy), .req_i(req),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl),
    .live_o());

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #50_000_000; $fatal(1, "objtab timeout"); end
  always @(negedge clk) if (off_rdy !== 1'b0 || off_v !== 1'b0 ||
                            off_cpl !== '0)
    $fatal(1, "disabled objtab active");

  int g_got = -1, g_exp = -1;
  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s got=%0d exp=%0d", name, g_got, g_exp);
    end
    g_got = -1; g_exp = -1;
  endtask

  task automatic do_reset;
    req_v = 1'b0; cpl_r = 1'b0; req = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk); rst_ni = 1'b1;
    // init sweep: DirWords cycles before req_ready
    while (!req_rdy) @(negedge clk);
  endtask

  task automatic op(input apu_objtab_req_t r, output apu_objtab_cpl_t c);
    @(negedge clk);
    while (!req_rdy) @(negedge clk);
    req = r; req_v = 1'b1;
    @(posedge clk);
    @(negedge clk); req_v = 1'b0;
    while (!cpl_v) @(negedge clk);
    c = cpl;
    g_got = int'(c.status);
    cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk); cpl_r = 1'b0;
  endtask

  function automatic apu_objtab_req_t mkr(
      input apu_objtab_op_e o, input logic [63:0] id,
      input logic [5:0] kind, input logic [63:0] pid,
      input logic [7:0] ctx, input logic [31:0] mask,
      input logic [31:0] value, input logic [63:0] mid,
      input logic [63:0] off, input logic [63:0] sz);
    return '{op: o, id: id, kind: kind, parent_id: pid, ctx: ctx,
             mask: mask, value: value, mem_id: mid, offset: off, size: sz};
  endfunction

  function automatic logic [DirB-1:0] mhash(logic [63:0] id);
    logic [DirB-1:0] h;
    h = '0;
    for (int c = 0; c < 64; c += DirB) h ^= DirB'(id >> c);
    return h;
  endfunction

  // ---------------- reference model ----------------
  bit         md_v [DirW], md_t [DirW];
  logic [63:0] md_id [DirW];
  int          md_slot [DirW];
  bit          me_live [Slots];
  int          me_kind [Slots], me_gen [Slots], me_parent [Slots];
  int          me_refcnt [Slots], me_pins [Slots], me_ctx [Slots];
  logic [31:0] me_state [Slots];
  int          me_bind [Slots];
  logic [63:0] me_boff [Slots], me_size [Slots];

  // probe result: 0 = hit bucket, 1 = miss (reusable in rb), 2 = miss-full
  function automatic int m_probe(input logic [63:0] id,
                                 output int hitb, output int rb);
    int first_tomb;
    first_tomb = -1; hitb = -1; rb = -1;
    for (int i = 0; i < 8; i++) begin
      automatic int b;
      b = (mhash(id) + i) % DirW;
      if (md_v[b] && !md_t[b] && md_id[b] == id) begin
        hitb = b; return 0;
      end
      if (!md_v[b] && !md_t[b]) begin
        rb = first_tomb >= 0 ? first_tomb : b;
        return 1;
      end
      if (md_t[b] && first_tomb < 0) first_tomb = b;
    end
    rb = first_tomb;
    return first_tomb >= 0 ? 1 : 2;
  endfunction

  // resolve like the DUT (id or handle); status out, slot out.
  // handle mode only when id[63:32]==0.
  function automatic apu_objtab_status_e m_resolve(
      input logic [63:0] id, input logic [5:0] kind,
      input logic knd_en, output int slot);
    int hb, rb;
    slot = -1;
    if (id[63:32] == 0) begin
      if (id[15:0] >= Slots) return APU_OBJTAB_GEN;
      slot = int'(id[15:0]);
      if (!me_live[slot] || me_gen[slot] != int'(id[31:16]))
        return APU_OBJTAB_GEN;
      if (knd_en && me_kind[slot] != kind) return APU_OBJTAB_KIND;
      return APU_OBJTAB_OK;
    end
    if (m_probe(id, hb, rb) != 0) return APU_OBJTAB_MISS;
    slot = md_slot[hb];
    if (!me_live[slot]) begin
      md_t[hb] = 1'b1;            // lazy tombstone
      return APU_OBJTAB_MISS;
    end
    if (knd_en && me_kind[slot] != kind) return APU_OBJTAB_KIND;
    return APU_OBJTAB_OK;
  endfunction

  task automatic m_reset;
    for (int i = 0; i < DirW; i++) begin
      md_v[i] = 0; md_t[i] = 0; md_id[i] = '0; md_slot[i] = 0;
    end
    for (int i = 0; i < Slots; i++) begin
      me_live[i] = 0; me_kind[i] = 0; me_gen[i] = 0; me_parent[i] = -1;
      me_refcnt[i] = 0; me_pins[i] = 0; me_ctx[i] = 0; me_state[i] = '0;
      me_bind[i] = -1; me_boff[i] = '0; me_size[i] = '0;
    end
  endtask

  // model ALLOC -> expected status (+slot/gen on OK)
  function automatic apu_objtab_status_e m_alloc(
      input logic [63:0] id, input logic [5:0] kind,
      input logic [63:0] pid, input logic [7:0] ctx,
      output int slot, output int gen);
    int hb, rb, pslot;
    slot = -1; gen = 0;
    if (m_probe(id, hb, rb) == 0) begin
      if (me_live[md_slot[hb]]) return APU_OBJTAB_DUP;
      rb = hb;                       // dead entry behind live bucket
    end else if (rb < 0) return APU_OBJTAB_FULL;
    if (pid != 0) begin
      if (m_resolve(pid, 0, 0, pslot) != APU_OBJTAB_OK)
        return APU_OBJTAB_PARENT_MISS;
    end
    for (int i = 0; i < Slots; i++)
      if (!me_live[i] && slot < 0) slot = i;
    if (slot < 0) return APU_OBJTAB_FULL;
    gen = me_gen[slot] == 16'hFFFF ? 1 : me_gen[slot] + 1;
    me_live[slot] = 1; me_kind[slot] = kind; me_gen[slot] = gen;
    me_parent[slot] = pid == 0 ? -1 : pslot;
    me_refcnt[slot] = 0; me_pins[slot] = 0; me_ctx[slot] = ctx;
    me_state[slot] = '0; me_bind[slot] = -1;
    me_boff[slot] = '0; me_size[slot] = '0;
    if (hb >= 0) begin end
    md_v[rb] = 1; md_t[rb] = 0; md_id[rb] = id; md_slot[rb] = slot;
    if (pid != 0) me_refcnt[pslot]++;
    return APU_OBJTAB_OK;
  endfunction

  // ---------- helpers ----------
  function automatic logic [63:0] hnd(input int gen, input int slot);
    return {32'h0, 16'(gen), 16'(slot)};
  endfunction

  task automatic xpect(input string name, input apu_objtab_req_t r,
                        input apu_objtab_status_e st);
    apu_objtab_cpl_t c;
    op(r, c);
    g_got = int'(c.status); g_exp = int'(st);
    check(name, c.status == st);
  endtask

  // ---------------- test sequence ----------------
  int rnd;
  logic [63:0] ids [$];
  int gens [int];
  int slots_of [longint unsigned];

  initial begin
    apu_objtab_cpl_t c;
    apu_objtab_status_e st;
    int slot, gen, pslot, hb, rb;
    logic [63:0] id, pid, mid, h1;
    logic [31:0] h;
    int live_cnt;
    longint unsigned seed;

    seed = 64'hC0FFEE;
    rnd = 32'h12345678;
    m_reset;
    do_reset;
    cases++;
    check("ready after init", req_rdy == 1'b1);

    // ---- fill to FULL ----
    for (int i = 0; i < Slots; i++) begin
      id = 64'hA000_0000_0000_0000 | 64'(i + 1);
      st = m_alloc(id, 6'd7, 64'h0, 8'd1, slot, gen);
      op(mkr(APU_OBJTAB_OP_ALLOC, id, 6'd7, 0, 8'd1, 0, 0, 0, 0, 0), c);
      check($sformatf("alloc[%0d]", i),
            st == APU_OBJTAB_OK && c.status == APU_OBJTAB_OK &&
            c.handle == {16'(gen), 16'(slot)});
    end
    op(mkr(APU_OBJTAB_OP_ALLOC, 64'hA000_0000_0000_0100, 6'd7, 0, 8'd1,
           0, 0, 0, 0, 0), c);
    check("fill FULL", c.status == APU_OBJTAB_FULL);

    // ---- retire everything, refill one slot and check gen ----
    for (int i = 0; i < Slots; i++) begin
      id = 64'hA000_0000_0000_0000 | 64'(i + 1);
      op(mkr(APU_OBJTAB_OP_RETIRE, id, 6'd7, 0, 0, 0, 0, 0, 0, 0), c);
      check($sformatf("retire[%0d]", i), c.status == APU_OBJTAB_OK);
      void'(m_probe(id, hb, rb));
      me_live[md_slot[hb]] = 0;
      md_t[hb] = 1;
    end
    cases++;

    // ---- DUP + KIND + GEN directed ----
    op(mkr(APU_OBJTAB_OP_ALLOC, 64'hB000_0000_0000_0001, 6'd5, 0, 8'd2,
           0, 0, 0, 0, 0), c);
    check("alloc b1", c.status == APU_OBJTAB_OK);
    slot = int'(c.handle[15:0]); gen = int'(c.handle[31:16]);
    void'(m_alloc(64'hB000_0000_0000_0001, 6'd5, 64'h0, 8'd2, slot, gen));
    xpect("dup", mkr(APU_OBJTAB_OP_ALLOC, 64'hB000_0000_0000_0001, 6'd5,
                      0, 0, 0, 0, 0, 0, 0), APU_OBJTAB_DUP);
    xpect("kind", mkr(APU_OBJTAB_OP_LOOKUP, 64'hB000_0000_0000_0001, 6'd9,
                       0, 0, 0, 0, 0, 0, 0), APU_OBJTAB_KIND);
    xpect("miss", mkr(APU_OBJTAB_OP_LOOKUP, 64'hB000_0000_DEAD_BEEF, 6'd5,
                       0, 0, 0, 0, 0, 0, 0), APU_OBJTAB_MISS);
    // retire -> realloc -> stale handle GEN
    h1 = hnd(gen, slot);
    xpect("retire b1", mkr(APU_OBJTAB_OP_RETIRE, 64'hB000_0000_0000_0001,
                            6'd5, 0, 0, 0, 0, 0, 0, 0), APU_OBJTAB_OK);
    me_live[slot] = 0;
    void'(m_probe(64'hB000_0000_0000_0001, hb, rb));
    md_t[hb] = 1;
    op(mkr(APU_OBJTAB_OP_ALLOC, 64'hB000_0000_0000_0002, 6'd5, 0, 8'd2,
           0, 0, 0, 0, 0), c);
    check("realloc", c.status == APU_OBJTAB_OK &&
                     int'(c.handle[15:0]) == slot &&
                     int'(c.handle[31:16]) != gen);
    void'(m_alloc(64'hB000_0000_0000_0002, 6'd5, 64'h0, 8'd2, slot, gen));
    xpect("stale GEN", mkr(APU_OBJTAB_OP_LOOKUP, h1, 6'd5, 0, 0, 0, 0,
                            0, 0, 0), APU_OBJTAB_GEN);
    cases++;

    // ---- PIN / UNPIN ----
    id = 64'hB000_0000_0000_0002;
    xpect("pin", mkr(APU_OBJTAB_OP_PIN, id, 6'd5, 0, 0, 0, 0, 0, 0, 0),
           APU_OBJTAB_OK);
    me_pins[slot] = 1;
    xpect("retire pinned", mkr(APU_OBJTAB_OP_RETIRE, id, 6'd5, 0, 0, 0,
                                0, 0, 0, 0), APU_OBJTAB_PINNED);
    xpect("unpin", mkr(APU_OBJTAB_OP_UNPIN, id, 6'd5, 0, 0, 0, 0, 0,
                        0, 0), APU_OBJTAB_OK);
    me_pins[slot] = 0;
    xpect("retire ok", mkr(APU_OBJTAB_OP_RETIRE, id, 6'd5, 0, 0, 0, 0,
                            0, 0, 0), APU_OBJTAB_OK);
    me_live[slot] = 0;
    void'(m_probe(id, hb, rb));
    md_t[hb] = 1;
    cases++;

    // ---- parent / child ----
    op(mkr(APU_OBJTAB_OP_ALLOC, 64'hC000_0000_0000_0001, 6'd3, 0, 8'd3,
           0, 0, 0, 0, 0), c);
    check("alloc dev", c.status == APU_OBJTAB_OK);
    void'(m_alloc(64'hC000_0000_0000_0001, 6'd3, 64'h0, 8'd3, pslot, gen));
    pid = 64'hC000_0000_0000_0001;
    op(mkr(APU_OBJTAB_OP_ALLOC, 64'hC000_0000_0000_0002, 6'd7, pid, 8'd3,
           0, 0, 0, 0, 0), c);
    check("alloc child", c.status == APU_OBJTAB_OK);
    void'(m_alloc(64'hC000_0000_0000_0002, 6'd7, pid, 8'd3, slot, gen));
    xpect("retire parent busy", mkr(APU_OBJTAB_OP_RETIRE, pid, 6'd3, 0, 0,
                                     0, 0, 0, 0, 0), APU_OBJTAB_BUSY_CHILDREN);
    xpect("retire child", mkr(APU_OBJTAB_OP_RETIRE,
                               64'hC000_0000_0000_0002, 6'd7, 0, 0, 0, 0,
                               0, 0, 0), APU_OBJTAB_OK);
    void'(m_probe(64'hC000_0000_0000_0002, hb, rb));
    me_live[md_slot[hb]] = 0;
    md_t[hb] = 1;
    me_refcnt[pslot]--;
    xpect("retire parent", mkr(APU_OBJTAB_OP_RETIRE, pid, 6'd3, 0, 0, 0,
                                0, 0, 0, 0), APU_OBJTAB_OK);
    me_live[pslot] = 0;
    void'(m_probe(pid, hb, rb));
    md_t[hb] = 1;
    xpect("parent miss", mkr(APU_OBJTAB_OP_ALLOC, 64'hC000_0000_0000_0009,
                              6'd7, 64'hD000_0000_0000_0001, 8'd3, 0, 0,
                              0, 0, 0), APU_OBJTAB_PARENT_MISS);
    cases++;

    // ---- RESET_CTX with mixed pinned ----
    begin
      logic [63:0] ctx_ids [4];
      int ctx_slots [4];
      for (int i = 0; i < 4; i++) begin
        ctx_ids[i] = 64'hE000_0000_0000_0000 | 64'(i + 1);
        op(mkr(APU_OBJTAB_OP_ALLOC, ctx_ids[i], 6'd4, 0, 8'd7, 0, 0, 0,
               0, 0), c);
        check($sformatf("ctx alloc %0d", i), c.status == APU_OBJTAB_OK);
        ctx_slots[i] = int'(c.handle[15:0]);
        void'(m_alloc(ctx_ids[i], 6'd4, 64'h0, 8'd7, slot, gen));
      end
      // pin slots 1 and 3
      xpect("ctx pin1", mkr(APU_OBJTAB_OP_PIN, ctx_ids[1], 6'd4, 0, 0, 0,
                             0, 0, 0, 0), APU_OBJTAB_OK);
      xpect("ctx pin3", mkr(APU_OBJTAB_OP_PIN, ctx_ids[3], 6'd4, 0, 0, 0,
                             0, 0, 0, 0), APU_OBJTAB_OK);
      me_pins[ctx_slots[1]] = 1; me_pins[ctx_slots[3]] = 1;
      op(mkr(APU_OBJTAB_OP_RESET_CTX, 0, 0, 0, 8'd7, 0, 0, 0, 0, 0), c);
      check("reset_ctx pinned count", c.status == APU_OBJTAB_OK &&
                                      c.handle[15:0] == 16'd2);
      // model the sweep
      for (int i = 0; i < Slots; i++)
        if (me_live[i] && me_ctx[i] == 8'd7 && me_pins[i] == 0)
          me_live[i] = 0;
      // unpinned ids are gone, pinned remain
      xpect("ctx gone", mkr(APU_OBJTAB_OP_LOOKUP, ctx_ids[0], 6'd4, 0, 0,
                             0, 0, 0, 0, 0), APU_OBJTAB_MISS);
      op(mkr(APU_OBJTAB_OP_LOOKUP, ctx_ids[1], 6'd4, 0, 0, 0, 0, 0, 0, 0),
         c);
      check("ctx pinned stays", c.status == APU_OBJTAB_OK);
    end
    cases++;

    // ---- 9 colliding ids: the 9th gets FULL despite free slots ----
    m_reset;
    do_reset;
    begin
      logic [63:0] base, deltas [16];
      int nfull;
      base = 64'hF000_0000_0000_0000 | 64'(mhash(64'h1));
      for (int k = 0; k < 4; k++) begin
        // pairs of bits that fold to the same hash bit cancel out
      end
      nfull = 0;
      for (int n = 0; n < 12; n++) begin
        logic [63:0] cid;
        cid = base;
        for (int k = 0; k < 4; k++)
          if ((n & (1 << k)) != 0)
            cid ^= (64'd1 << k) ^ (64'd1 << (k + DirB));
        if (cid[63:32] == 0) cid |= 64'h1000_0000_0000_0000;
        if (mhash(cid) != mhash(base)) begin
          $display("collision id %0d hash mismatch", n);
          errors++;
        end
        op(mkr(APU_OBJTAB_OP_ALLOC, cid, 6'd6, 0, 8'd9, 0, 0, 0, 0, 0), c);
        if (c.status == APU_OBJTAB_FULL) nfull++;
        else void'(m_alloc(cid, 6'd6, 64'h0, 8'd9, slot, gen));
      end
      check("collision cap", nfull == 12 - 8);
    end
    cases++;

    // ---- seeded random: 2000 ops vs model ----
    m_reset;
    do_reset;
    ids.delete();
    live_cnt = 0;
    for (int i = 0; i < 2000; i++) begin
      int sel, which, s2, g2;
      logic [63:0] rid, rpid;
      apu_objtab_status_e est;
      rnd = rnd * 32'h9E3779B9 + 32'h85EBCA6B;
      sel = int'(rnd[31:28]) % 10;
      // build a request
      if (sel < 4) begin
        // alloc fresh id (high word always nonzero)
        rnd = rnd * 32'h9E3779B9 + 32'h85EBCA6B;
        rid = 64'h9000_0000_0000_0000 ^ {32'h0, rnd} ^ (64'(i) << 40);
        rnd = rnd * 32'h9E3779B9 + 32'h85EBCA6B;
        rpid = (rnd[7] && ids.size() > 0) ? ids[$urandom_range(0, ids.size()-1)] : 64'h0;
        est = m_alloc(rid, 6'(rnd[13:8]), rpid, rnd[15:8], s2, g2);
        op(mkr(APU_OBJTAB_OP_ALLOC, rid, 6'(rnd[13:8]), rpid, rnd[15:8],
               0, 0, 0, 0, 0), c);
        g_exp = int'(est); check($sformatf("rnd alloc %0d", i), c.status == est &&
              (est != APU_OBJTAB_OK ||
               c.handle == {16'(g2), 16'(s2)}));
        if (est == APU_OBJTAB_OK) ids.push_back(rid);
      end else if (sel < 7) begin
        // lookup / retire / pin-unpin on a live-ish id or a handle
        if (ids.size() == 0) continue;
        rid = ids[$urandom_range(0, ids.size()-1)];
        rnd = rnd * 32'h9E3779B9 + 32'h85EBCA6B;
        if (rnd[5]) begin
          // handle form
          int mslot;
          if (m_resolve(rid, 0, 0, mslot) == APU_OBJTAB_OK)
            rid = hnd(me_gen[mslot] + (rnd[6] ? 0 : 1), mslot);
          else
            rid = {32'h0, 32'($urandom)};
        end
        case (rnd[4:3])
          2'd0: begin
            est = m_resolve(rid, 6'(rnd[13:8]), 1'b1, s2);
            op(mkr(APU_OBJTAB_OP_LOOKUP, rid, 6'(rnd[13:8]), 0, 0, 0, 0,
                   0, 0, 0), c);
            g_exp = int'(est); check($sformatf("rnd lookup %0d", i), c.status == est);
          end
          2'd1: begin
            logic [5:0] kk;
            kk = 6'(rnd[13:8]);
            est = m_resolve(rid, kk, 1'b1, s2);
            if (est != APU_OBJTAB_OK) est = est;
            else if (me_pins[s2] != 0) est = APU_OBJTAB_PINNED;
            else if (me_refcnt[s2] != 0) est = APU_OBJTAB_BUSY_CHILDREN;
            else begin
              me_live[s2] = 0;
              if (rid[63:32] != 0 && m_probe(rid, hb, rb) == 0)
                md_t[hb] = 1;
              if (me_parent[s2] >= 0 && me_live[me_parent[s2]] &&
                  me_refcnt[me_parent[s2]] > 0)
                me_refcnt[me_parent[s2]]--;
            end
            op(mkr(APU_OBJTAB_OP_RETIRE, rid, kk, 0, 0, 0, 0, 0, 0, 0), c);
            g_exp = int'(est); check($sformatf("rnd retire %0d", i), c.status == est);
            if (est == APU_OBJTAB_OK) begin
              int q;
              for (q = 0; q < ids.size(); q++)
                if (ids[q] == rid) begin ids.delete(q); break; end
            end
          end
          2'd2: begin
            est = m_resolve(rid, 6'(rnd[13:8]), 1'b1, s2);
            if (est == APU_OBJTAB_OK)
              me_pins[s2] = me_pins[s2] == 255 ? 255 : me_pins[s2] + 1;
            op(mkr(APU_OBJTAB_OP_PIN, rid, 6'(rnd[13:8]), 0, 0, 0, 0, 0,
                   0, 0), c);
            g_exp = int'(est); check($sformatf("rnd pin %0d", i), c.status == est);
          end
          default: begin
            est = m_resolve(rid, 6'(rnd[13:8]), 1'b1, s2);
            if (est == APU_OBJTAB_OK && me_pins[s2] > 0) me_pins[s2]--;
            op(mkr(APU_OBJTAB_OP_UNPIN, rid, 6'(rnd[13:8]), 0, 0, 0, 0,
                   0, 0, 0), c);
            g_exp = int'(est); check($sformatf("rnd unpin %0d", i), c.status == est);
          end
        endcase
      end else if (sel < 8) begin
        // setstate / setbind on live id
        if (ids.size() == 0) continue;
        rid = ids[$urandom_range(0, ids.size()-1)];
        rnd = rnd * 32'h9E3779B9 + 32'h85EBCA6B;
        if (m_probe(rid, hb, rb) != 0 || !me_live[md_slot[hb]]) continue;
        s2 = md_slot[hb];
        if (rnd[4]) begin
          me_state[s2] = (me_state[s2] & rnd) | (rnd & ~rnd);
          op(mkr(APU_OBJTAB_OP_SETSTATE, rid, 6'(me_kind[s2]), 0, 0,
                 ~rnd, rnd & ~rnd, 0, 0, 0), c);
          check($sformatf("rnd setstate %0d", i), c.status == APU_OBJTAB_OK);
        end else begin
          logic [63:0] mm;
          mm = ids[$urandom_range(0, ids.size()-1)];
          est = APU_OBJTAB_OK;
          if (m_resolve(mm, 0, 0, slot) != APU_OBJTAB_OK)
            est = APU_OBJTAB_MISS;
          else begin
            me_bind[s2] = slot; me_boff[s2] = {rnd, rnd};
            me_size[s2] = {32'h0, rnd};
          end
          op(mkr(APU_OBJTAB_OP_SETBIND, rid, 6'(me_kind[s2]), 0, 0, 0, 0,
                 mm, {rnd, rnd}, {32'h0, rnd}), c);
          g_exp = int'(est); check($sformatf("rnd setbind %0d", i), c.status == est);
        end
      end else if (sel < 9) begin
        // reset_ctx
        int pcnt;
        rnd = rnd * 32'h9E3779B9 + 32'h85EBCA6B;
        pcnt = 0;
        for (int s3 = 0; s3 < Slots; s3++)
          if (me_live[s3] && me_ctx[s3] == rnd[10:8])
            if (me_pins[s3] != 0) pcnt++;
            else begin
              me_live[s3] = 0;
              if (me_parent[s3] >= 0 && me_live[me_parent[s3]] &&
                  me_refcnt[me_parent[s3]] > 0)
                me_refcnt[me_parent[s3]]--;
            end
        op(mkr(APU_OBJTAB_OP_RESET_CTX, 0, 0, 0, rnd[10:8], 0, 0, 0, 0,
               0), c);
        check($sformatf("rnd reset_ctx %0d", i),
              c.status == APU_OBJTAB_OK && c.handle[15:0] == 16'(pcnt));
        // drop dead ids from the pool
        begin
          int q;
          for (q = int'(ids.size()) - 1; q >= 0; q--)
            if (m_probe(ids[q], hb, rb) == 0 && !me_live[md_slot[hb]])
              ids.delete(q);
        end
      end else begin
        // dup alloc of a live id, or miss lookup
        if (ids.size() == 0) continue;
        rid = ids[$urandom_range(0, ids.size()-1)];
        rnd = rnd * 32'h9E3779B9 + 32'h85EBCA6B;
        if (rnd[3]) begin
          if (m_probe(rid, hb, rb) == 0 && me_live[md_slot[hb]]) begin
            op(mkr(APU_OBJTAB_OP_ALLOC, rid, 6'(rnd[13:8]), 0, 0, 0, 0,
                   0, 0, 0), c);
            check($sformatf("rnd dup %0d", i), c.status == APU_OBJTAB_DUP);
          end
        end else begin
          rid[63:32] = rid[63:32] ^ 32'hDEAD0000;
          est = m_resolve(rid, 6'(rnd[13:8]), 1'b1, s2);
          op(mkr(APU_OBJTAB_OP_LOOKUP, rid, 6'(rnd[13:8]), 0, 0, 0, 0, 0,
                 0, 0), c);
          g_exp = int'(est); check($sformatf("rnd miss %0d", i), c.status == est);
        end
      end
    end
    cases++;

    // ---- global invariant: every model-live slot answers its handle;
    //      the model holds each (kind,id) at most once by construction ----
    begin
      int nlive;
      nlive = 0;
      for (int i = 0; i < Slots; i++)
        if (me_live[i]) begin
          nlive++;
          op(mkr(APU_OBJTAB_OP_LOOKUP, hnd(me_gen[i], i), 6'(me_kind[i]),
                 0, 0, 0, 0, 0, 0, 0), c);
          check($sformatf("live slot %0d", i),
                c.status == APU_OBJTAB_OK &&
                c.handle == {16'(me_gen[i]), 16'(i)});
        end
      check("some live", nlive >= 0);
    end

    $display("PASS tb_g6lc_apu_objtab cases=%0d checks=%0d cycles=%0d",
             cases, checks, cycles);
    if (errors != 0) $fatal(1, "objtab %0d errors", errors);
    $finish;
  end
endmodule
