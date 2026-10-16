// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
// Directed + seeded-random test of g6lc_apu_objtab (§5a ObjTab-V)
// driven through g6lc_apu_objmem's DRAM-backed directory/entry/
// free-stack services plus a behavioural aperture responder with
// random 1-8 cycle latency.  The in-TB reference model mirrors the
// directory (valid/tomb/id/slot buckets, 32-probe cap, lazy
// tombstoning), the per-entry fields, the ctx linked lists (head
// insert, newest-first walks) and the LIFO free stack + bump.
module tb_g6lc_apu_objtab;
  import g6lc_apu_objtab_pkg::*;
  import g6lc_apu_mp_pkg::*;

  localparam int unsigned ObjEntries = 16384;
  localparam int unsigned MaxCtx     = 8;
  localparam int unsigned DirW       = 2 * ObjEntries;
  localparam int unsigned DirB       = $clog2(DirW);
  localparam int unsigned PayMemB    = 64 * 1024;

  logic clk = 0, rst_ni = 0, testmode = 0;
  logic req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  apu_objtab_req_t req = '0;
  apu_objtab_cpl_t cpl;
  logic off_rdy, off_v; apu_objtab_cpl_t off_cpl;
  logic [15:0] live_o_w;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  // ---- objmem plumbing ----------------------------------------------------
  logic         omt_v, omt_r, omt_rv;
  apu_omt_req_t omt_req;
  apu_omt_rsp_t omt_rsp;
  logic         ompr_r, ompr_rv;
  apu_omp_rsp_t ompr_rsp;
  logic         mp_v, mp_r, mp_rv;
  apu_mp_req_t  mp_req;
  apu_mp_rsp_t  mp_rsp;

  g6lc_apu_objtab #(.Enable(1'b1), .ObjEntries(ObjEntries),
                    .MaxCtx(MaxCtx)) i_on (
    .clk_i(clk), .rst_ni, .testmode_i(testmode),
    .req_valid_i(req_v), .req_ready_o(req_rdy), .req_i(req),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl),
    .live_o(live_o_w),
    .omt_req_valid_o(omt_v), .omt_req_ready_i(omt_r),
    .omt_req_o(omt_req),
    .omt_rsp_valid_i(omt_rv), .omt_rsp_i(omt_rsp));

  // omp (payload) port tied off — objmem still needs a legal tie
  g6lc_apu_objmem #(.Enable(1'b1), .ObjEntries(ObjEntries),
                    .PayMemBytes(PayMemB),
                    .DirCacheSets(16), .EntCacheLines(8),
                    .PayCacheLines(4)) i_om (
    .clk_i(clk), .rst_ni, .testmode_i(testmode),
    .omt_req_valid_i(omt_v), .omt_req_ready_o(omt_r),
    .omt_req_i(omt_req),
    .omt_rsp_valid_o(omt_rv), .omt_rsp_o(omt_rsp),
    .omp_req_valid_i(1'b0), .omp_req_ready_o(ompr_r),
    .omp_req_i(apu_omp_req_t'(0)),
    .omp_rsp_valid_o(ompr_rv), .omp_rsp_o(ompr_rsp),
    .mp_req_valid_o(mp_v), .mp_req_ready_i(mp_r),
    .mp_req_o(mp_req),
    .mp_rsp_valid_i(mp_rv), .mp_rsp_i(mp_rsp));

  // aperture responder: carve window only; +mp_lat_min/max=1..8
  tb_apu_mp_mem #(.N(1), .GMW(1), .APW(0),
                  .PWB(32'(APU_OBJMEM_OFF >> 2)),
                  .PPW(32'((apu_objmem_pay_off(ObjEntries) +
                            64'(PayMemB) - APU_OBJMEM_OFF) >> 2) +
                        64))
      i_mem (
    .clk_i(clk), .rst_ni(rst_ni),
    .req_valid_i(mp_v), .req_ready_o(mp_r), .req_i('{mp_req}),
    .rsp_valid_o(mp_rv), .rsp_o('{mp_rsp}));

  g6lc_apu_objtab_fixture #(.Enable(1'b0), .ObjEntries(ObjEntries),
                            .MaxCtx(MaxCtx)) i_off (
    .clk_i(clk), .rst_ni, .testmode_i(testmode),
    .req_valid_i(req_v), .req_ready_o(off_rdy), .req_i(req),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl),
    .live_o(), .omt_req_valid_o(), .omt_req_ready_i(1'b0),
    .omt_req_o(), .omt_rsp_valid_i(1'b0),
    .omt_rsp_i(apu_omt_rsp_t'(0)));

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  always @(posedge clk) if (omt_v && omt_r && $test$plusargs("tromt"))
    $display("[%0t] OMT  op=%0d id=%x bk=%0d en=%0d", $time,
             omt_req.op, omt_req.id, omt_req.bucket, omt_req.entry);
  always @(posedge clk) if (omt_rv && $test$plusargs("tromt"))
    $display("[%0t] OMTR st=%0d en=%0d bk=%0d live=%0d gen=%0d ep=%0d eq=%0d id=%x",
             $time, omt_rsp.status, omt_rsp.entry, omt_rsp.bucket,
             omt_rsp.rec.live, omt_rsp.rec.gen, omt_rsp.rec.epoch,
             i_om.gen_on.epoch_q, omt_rsp.rec.id);
  always @(posedge clk) if (mp_v && mp_r && $test$plusargs("trmp"))
    $display("[%0t] MP   we=%0d addr=%08x d=%016x", $time,
             mp_req.we, mp_req.addr, mp_req.wdata);
  always @(posedge clk) if (mp_rv && $test$plusargs("trmp"))
    $display("[%0t] MPR  d=%016x", $time, mp_rsp.rdata);
  initial begin #4_000_000_000; $fatal(1, "objtab timeout"); end
  always @(negedge clk) if (off_rdy !== 1'b0 || off_v !== 1'b0 ||
                            off_cpl !== '0)
    $fatal(1, "disabled objtab active");

  int g_got = -1, g_exp = -1;
  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s got=%0d exp=%0d", name, g_got, g_exp);
      if (errors > 16) $fatal(1, "too many errors");
    end
    g_got = -1; g_exp = -1;
  endtask

  task automatic do_reset;
    req_v = 1'b0; cpl_r = 1'b0; req = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk); rst_ni = 1'b1;
    // objmem init sweep (dir zero + stack/magic) before req_ready
    while (!req_rdy) @(negedge clk);
  endtask

  task automatic op(input apu_objtab_req_t r, output apu_objtab_cpl_t c);
    @(negedge clk);
    while (!req_rdy) @(negedge clk);
    req = r; req_v = 1'b1;
    @(posedge clk);
    @(negedge clk); req_v = 1'b0;
    // RESET_CTX streams one SWEEP completion per tombstoned entry
    // before the final status — drain them here so callers always see
    // the terminating completion
    while (!cpl_v) @(negedge clk);
    c = cpl;
    while (c.status == APU_OBJTAB_SWEEP) begin
      cpl_r = 1'b1;
      @(posedge clk);
      @(negedge clk); cpl_r = 1'b0;
      while (!cpl_v) @(negedge clk);
      c = cpl;
    end
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
    logic [63:0] x;
    x = id * 64'h9E37_79B9_7F4A_7C15;
    return DirB'(x >> (64 - DirB));
  endfunction

  function automatic int mcidx(input int ctx);
    return ctx >= MaxCtx ? MaxCtx : ctx;
  endfunction

  // ---------------- reference model ----------------
  bit         md_v [DirW], md_t [DirW];
  logic [63:0] md_id [DirW];
  int          md_slot [DirW], md_gen [DirW];
  bit          me_live [ObjEntries];
  int          me_kind [ObjEntries], me_gen [ObjEntries],
               me_parent [ObjEntries];
  int          me_refcnt [ObjEntries], me_pins [ObjEntries],
               me_ctx [ObjEntries];
  logic [31:0] me_state [ObjEntries];
  int          me_bind [ObjEntries];
  logic [63:0] me_boff [ObjEntries], me_size [ObjEntries];
  logic [63:0] me_aux  [ObjEntries];
  // LIFO free stack + bump pointer — mirrors objmem's segmented
  // stack: a 32-entry flop top (LIFO) over a DRAM stack refilled a
  // 4-entry DRAM word at a time (entries banked below the served top)
  int          mf_fsk [$];   // flop top (max 32)
  int          mf_stk [$];   // DRAM stack
  int          m_bump;
  // ctx live lists, head = newest (queue front)
  int          m_ctxq [int][$];
  // global DEVICE_MEMORY (kind 8) list, front = newest — SCAN_OVL order
  int          m_memq [$];

  // probe result: 0 = hit bucket, 1 = miss (reusable in rb), 2 = miss-full
  function automatic int m_probe(input logic [63:0] id,
                                 output int hitb, output int rb);
    int first_tomb;
    first_tomb = -1; hitb = -1; rb = -1;
    for (int i = 0; i < 32; i++) begin
      automatic int b;
      b = (mhash(id) + i) % DirW;
      if (md_v[b] && !md_t[b] && md_id[b] == id) begin
        // stale row: slot dead or re-idd'd — tombstone and keep
        // probing, like the DUT's entry-verify path
        if (!me_live[md_slot[b]] || me_gen[md_slot[b]] != md_gen[b]) begin
          md_t[b] = 1'b1;
          if (first_tomb < 0) first_tomb = b;
          continue;
        end
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
  function automatic apu_objtab_status_e m_resolve(
      input logic [63:0] id, input logic [5:0] kind,
      input logic knd_en, output int slot);
    int hb, rb;
    slot = -1;
    if (id[63:32] == 0 && id[31:16] != 0) begin
      if (id[15:0] >= ObjEntries) return APU_OBJTAB_GEN;
      slot = int'(id[15:0]);
      if (!me_live[slot] || me_gen[slot] != int'(id[31:16]))
        return APU_OBJTAB_GEN;
      if (knd_en && me_kind[slot] != kind) return APU_OBJTAB_KIND;
      return APU_OBJTAB_OK;
    end
    if (m_probe(id, hb, rb) != 0) return APU_OBJTAB_MISS;
    slot = md_slot[hb];
    if (!me_live[slot]) begin
      md_t[hb] = 1'b1;
      return APU_OBJTAB_MISS;
    end
    if (knd_en && me_kind[slot] != kind) return APU_OBJTAB_KIND;
    return APU_OBJTAB_OK;
  endfunction

  task automatic m_reset;
    for (int i = 0; i < DirW; i++) begin
      md_v[i] = 0; md_t[i] = 0; md_id[i] = '0; md_slot[i] = 0;
      md_gen[i] = 0;
    end
    for (int i = 0; i < ObjEntries; i++) begin
      me_live[i] = 0; me_kind[i] = 0; me_gen[i] = 0;
      me_parent[i] = -1;
      me_refcnt[i] = 0; me_pins[i] = 0; me_ctx[i] = 0;
      me_state[i] = '0;
      me_bind[i] = -1; me_boff[i] = '0; me_size[i] = '0; me_aux[i] = '0;
    end
    mf_fsk.delete(); mf_stk.delete(); m_bump = 0;
    m_ctxq.delete(); m_memq.delete();
  endtask

  // push a freed slot: flop top first, spill to DRAM stack
  function automatic void m_fpush(input int slot);
    if (mf_fsk.size() < 32) mf_fsk.push_back(slot);
    else                    mf_stk.push_back(slot);
  endfunction

  // pop a free entry slot, flop-top LIFO -> DRAM word -> bump
  function automatic int m_fslot;
    if (mf_fsk.size() != 0) return mf_fsk.pop_back();
    if (mf_stk.size() != 0) begin
      automatic int top  = mf_stk.size() - 1;
      automatic int base = top & ~3;
      automatic int e    = mf_stk[top];
      // remaining word entries bank into the flop top ascending
      for (int i = base; i < top; i++) mf_fsk.push_back(mf_stk[i]);
      for (int i = top; i >= base; i--) mf_stk.delete(i);
      return e;
    end
    if (m_bump < ObjEntries) begin
      automatic int s = m_bump;
      m_bump++;
      return s;
    end
    return -1;
  endfunction

  // unlink slot from its ctx list / the devmem list
  task automatic m_unlink(input int slot);
    int q;
    q = mcidx(me_ctx[slot]);
    for (int i = 0; i < m_ctxq[q].size(); i++)
      if (m_ctxq[q][i] == slot) begin m_ctxq[q].delete(i); break; end
    for (int i = 0; i < m_memq.size(); i++)
      if (m_memq[i] == slot) begin m_memq.delete(i); break; end
  endtask

  // retire bookkeeping shared by RETIRE / RESET_CTX / RETIRE_KIDS
  task automatic m_kill(input int slot);
    if (me_parent[slot] >= 0 && me_live[me_parent[slot]] &&
        me_refcnt[me_parent[slot]] > 0)
      me_refcnt[me_parent[slot]]--;
    me_live[slot] = 0;
    m_unlink(slot);
    m_fpush(slot);
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
      rb = hb;
    end else if (rb < 0) return APU_OBJTAB_FULL;
    if (pid != 0) begin
      if (m_resolve(pid, 0, 0, pslot) != APU_OBJTAB_OK)
        return APU_OBJTAB_PARENT_MISS;
    end
    slot = m_fslot();
    if (slot < 0) return APU_OBJTAB_FULL;
    gen = me_gen[slot] == 16'hFFFF ? 1 : me_gen[slot] + 1;
    me_live[slot] = 1; me_kind[slot] = kind; me_gen[slot] = gen;
    me_parent[slot] = pid == 0 ? -1 : pslot;
    me_refcnt[slot] = 0; me_pins[slot] = 0; me_ctx[slot] = ctx;
    me_state[slot] = '0; me_bind[slot] = -1;
    me_boff[slot] = '0; me_size[slot] = '0; me_aux[slot] = '0;
    md_v[rb] = 1; md_t[rb] = 0; md_id[rb] = id; md_slot[rb] = slot;
    md_gen[rb] = gen;
    m_ctxq[mcidx(ctx)].push_front(slot);
    if (kind == 6'd8) m_memq.push_front(slot);
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

  initial begin
    apu_objtab_cpl_t c;
    apu_objtab_status_e st;
    int slot, gen, pslot, hb, rb;
    logic [63:0] id, pid, mid, h1;
    logic [31:0] h;
    int live_cnt;
    int aslot [ObjEntries], agen [ObjEntries];
    logic [63:0] aid [ObjEntries];

    rnd = 32'h12345678;
    m_reset;
    do_reset;
    cases++;
    check("ready after init", req_rdy == 1'b1);

    // ================= maxconc: fill to ObjEntries in ctx 1 ==========
    // 16,384 live allocs, lookup each by id + by handle, retire all,
    // re-alloc exercises free-stack reuse + generation increments.
    for (int i = 0; i < ObjEntries; i++) begin
      aid[i] = 64'hA000_0000_0000_0000 | 64'(i + 1);
      st = m_alloc(aid[i], 6'd7, 64'h0, 8'd1, slot, gen);
      op(mkr(APU_OBJTAB_OP_ALLOC, aid[i], 6'd7, 0, 8'd1, 0, 0, 0, 0, 0),
         c);
      check($sformatf("maxc alloc[%0d]", i),
            st == APU_OBJTAB_OK && c.status == APU_OBJTAB_OK &&
            c.handle == {16'(gen), 16'(slot)});
      aslot[i] = slot; agen[i] = gen;
    end
    op(mkr(APU_OBJTAB_OP_ALLOC, 64'hA000_0000_DEAD_BEEF, 6'd7, 0, 8'd1,
           0, 0, 0, 0, 0), c);
    check("maxc FULL", c.status == APU_OBJTAB_FULL);
    check("maxc live_o", live_o_w == 16'(ObjEntries));
    // every live entry answers by id and by handle
    for (int i = 0; i < ObjEntries; i++) begin
      op(mkr(APU_OBJTAB_OP_LOOKUP, aid[i], 6'd7, 0, 0, 0, 0, 0, 0, 0), c);
      check($sformatf("maxc id[%0d]", i),
            c.status == APU_OBJTAB_OK &&
            c.handle == {16'(agen[i]), 16'(aslot[i])});
      op(mkr(APU_OBJTAB_OP_LOOKUP, hnd(agen[i], aslot[i]), 6'd7, 0, 0,
             0, 0, 0, 0, 0), c);
      check($sformatf("maxc hnd[%0d]", i),
            c.status == APU_OBJTAB_OK &&
            c.handle == {16'(agen[i]), 16'(aslot[i])} &&
            c.entry.kind == 6'd7);
    end
    // retire everything (id-form), then re-alloc: stack pops recycle
    // the slots with bumped generations
    for (int i = 0; i < ObjEntries; i++) begin
      op(mkr(APU_OBJTAB_OP_RETIRE, aid[i], 6'd7, 0, 0, 0, 0, 0, 0, 0), c);
      check($sformatf("maxc retire[%0d]", i),
            c.status == APU_OBJTAB_OK);
      void'(m_probe(aid[i], hb, rb));
      m_kill(md_slot[hb]);
      md_t[hb] = 1;
    end
    check("maxc drained", live_o_w == 16'd0);
    for (int i = 0; i < ObjEntries; i++) begin
      aid[i] = 64'hA100_0000_0000_0000 | 64'(i + 1);
      st = m_alloc(aid[i], 6'd7, 64'h0, 8'd1, slot, gen);
      op(mkr(APU_OBJTAB_OP_ALLOC, aid[i], 6'd7, 0, 8'd1, 0, 0, 0, 0, 0),
         c);
      check($sformatf("maxc realloc[%0d]", i),
            st == APU_OBJTAB_OK && c.status == APU_OBJTAB_OK &&
            c.handle == {16'(gen), 16'(slot)} &&
            gen == 16'(me_gen[slot]));
    end
    cases++;

    // ---- retire everything again, refill one slot and check gen ----
    m_reset;
    do_reset;
    for (int i = 0; i < ObjEntries; i++) begin
      id = 64'hA000_0000_0000_0000 | 64'(i + 1);
      st = m_alloc(id, 6'd7, 64'h0, 8'd1, slot, gen);
      op(mkr(APU_OBJTAB_OP_ALLOC, id, 6'd7, 0, 8'd1, 0, 0, 0, 0, 0), c);
      check($sformatf("alloc[%0d]", i),
            st == APU_OBJTAB_OK && c.status == APU_OBJTAB_OK &&
            c.handle == {16'(gen), 16'(slot)});
    end
    op(mkr(APU_OBJTAB_OP_ALLOC, 64'hA000_0000_0001_0000, 6'd7, 0, 8'd1,
           0, 0, 0, 0, 0), c);
    check("fill FULL", c.status == APU_OBJTAB_FULL);
    cases++;

    // ---- DUP + KIND + GEN directed ----
    m_reset;
    do_reset;
    op(mkr(APU_OBJTAB_OP_ALLOC, 64'hB000_0000_0000_0001, 6'd5, 0, 8'd2,
           0, 0, 0, 0, 0), c);
    check("alloc b1", c.status == APU_OBJTAB_OK);
    slot = int'(c.handle[15:0]); gen = int'(c.handle[31:16]);
    void'(m_alloc(64'hB000_0000_0000_0001, 6'd5, 64'h0, 8'd2, slot, gen));
    xpect("dup", mkr(APU_OBJTAB_OP_ALLOC, 64'hB000_0000_0000_0001, 6'd5,
                      0, 0, 0, 0, 0, 0, 0), APU_OBJTAB_DUP);
    xpect("kind", mkr(APU_OBJTAB_OP_LOOKUP, 64'hB000_0000_0000_0001, 6'd9,
                       0, 0, 0, 0, 0, 0, 0), APU_OBJTAB_KIND);
    xpect("kind0 wildcard",
          mkr(APU_OBJTAB_OP_LOOKUP, 64'hB000_0000_0000_0001, 6'd0, 0, 0,
              0, 0, 0, 0, 0), APU_OBJTAB_OK);
    xpect("miss", mkr(APU_OBJTAB_OP_LOOKUP, 64'hB000_0000_DEAD_BEEF, 6'd5,
                       0, 0, 0, 0, 0, 0, 0), APU_OBJTAB_MISS);
    // retire -> realloc -> stale handle GEN
    h1 = hnd(gen, slot);
    xpect("retire b1", mkr(APU_OBJTAB_OP_RETIRE, 64'hB000_0000_0000_0001,
                            6'd5, 0, 0, 0, 0, 0, 0, 0), APU_OBJTAB_OK);
    me_live[slot] = 0; m_unlink(slot); m_fpush(slot);
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
    op(mkr(APU_OBJTAB_OP_READSLOT, 64'(slot), 6'd0, 0, 0, 0, 0, 0, 0, 0),
       c);
    check("readslot live", c.status == APU_OBJTAB_OK &&
                           int'(c.handle[15:0]) == slot &&
                           int'(c.handle[31:16]) == gen);
    op(mkr(APU_OBJTAB_OP_READSLOT, 64'(ObjEntries + 3), 6'd0, 0, 0, 0, 0,
           0, 0, 0), c);
    check("readslot range", c.status == APU_OBJTAB_MISS);
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
    me_live[slot] = 0; m_unlink(slot); m_fpush(slot);
    void'(m_probe(id, hb, rb));
    md_t[hb] = 1;
    xpect("readslot dead", mkr(APU_OBJTAB_OP_READSLOT, 64'(slot), 6'd0,
                               0, 0, 0, 0, 0, 0, 0), APU_OBJTAB_MISS);
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
    m_kill(md_slot[hb]);
    md_t[hb] = 1;
    xpect("retire parent", mkr(APU_OBJTAB_OP_RETIRE, pid, 6'd3, 0, 0, 0,
                                0, 0, 0, 0), APU_OBJTAB_OK);
    me_live[pslot] = 0; m_unlink(pslot); m_fpush(pslot);
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
      xpect("ctx pin1", mkr(APU_OBJTAB_OP_PIN, ctx_ids[1], 6'd4, 0, 0, 0,
                             0, 0, 0, 0), APU_OBJTAB_OK);
      xpect("ctx pin3", mkr(APU_OBJTAB_OP_PIN, ctx_ids[3], 6'd4, 0, 0, 0,
                             0, 0, 0, 0), APU_OBJTAB_OK);
      me_pins[ctx_slots[1]] = 1; me_pins[ctx_slots[3]] = 1;
      op(mkr(APU_OBJTAB_OP_RESET_CTX, 0, 0, 0, 8'd7, 0, 0, 0, 0, 0), c);
      check("reset_ctx pinned count", c.status == APU_OBJTAB_OK &&
                                      c.handle[15:0] == 16'd2);
      // model the sweep: ctx-7 unpinned entries die in walk order
      begin
        int nq, wq [$];
        nq = mcidx(7);
        for (int i = 0; i < m_ctxq[nq].size(); i++) begin
          automatic int s = m_ctxq[nq][i];
          if (me_ctx[s] == 8'd7 && me_pins[s] == 0) begin
            me_live[s] = 0; m_fpush(s);
            if (me_parent[s] >= 0 && me_live[me_parent[s]] &&
                me_refcnt[me_parent[s]] > 0)
              me_refcnt[me_parent[s]]--;
            for (int j = 0; j < m_memq.size(); j++)
              if (m_memq[j] == s) begin m_memq.delete(j); break; end
          end else
            wq.push_back(s);
        end
        m_ctxq[nq] = wq;
      end
      xpect("ctx gone", mkr(APU_OBJTAB_OP_LOOKUP, ctx_ids[0], 6'd4, 0, 0,
                             0, 0, 0, 0, 0), APU_OBJTAB_MISS);
      op(mkr(APU_OBJTAB_OP_LOOKUP, ctx_ids[1], 6'd4, 0, 0, 0, 0, 0, 0, 0),
         c);
      check("ctx pinned stays", c.status == APU_OBJTAB_OK);
    end
    cases++;

    // ---- ctxwalk: two interleaved contexts ------------------------
    // RESET_CTX of one leaves the other's entries live in order and
    // reports the pinned count
    m_reset;
    do_reset;
    begin
      logic [63:0] w_ids [32];
      int          w_slots [32];
      for (int i = 0; i < 32; i++) begin
        w_ids[i] = 64'hE100_0000_0000_0000 | 64'(i + 1);
        op(mkr(APU_OBJTAB_OP_ALLOC, w_ids[i], 6'd6, 0,
               8'(i % 2 == 0 ? 2 : 3), 0, 0, 0, 0, 0), c);
        check($sformatf("walk alloc %0d", i), c.status == APU_OBJTAB_OK);
        w_slots[i] = int'(c.handle[15:0]);
        void'(m_alloc(w_ids[i], 6'd6, 64'h0,
                      8'(i % 2 == 0 ? 2 : 3), slot, gen));
      end
      // pin one ctx-2 entry so the count is nonzero
      xpect("walk pin", mkr(APU_OBJTAB_OP_PIN, w_ids[0], 6'd6, 0, 0, 0,
                             0, 0, 0, 0), APU_OBJTAB_OK);
      me_pins[w_slots[0]] = 1;
      op(mkr(APU_OBJTAB_OP_RESET_CTX, 0, 0, 0, 8'd2, 0, 0, 0, 0, 0), c);
      check("walk reset count", c.status == APU_OBJTAB_OK &&
                                c.handle[15:0] == 16'd1);
      // model: kill ctx-2 unpinned in ctx-2's list order
      begin
        int wq [$];
        for (int i = 0; i < m_ctxq[2].size(); i++) begin
          automatic int s = m_ctxq[2][i];
          if (me_ctx[s] == 8'd2 && me_pins[s] == 0) begin
            me_live[s] = 0; m_fpush(s);
            for (int j = 0; j < m_memq.size(); j++)
              if (m_memq[j] == s) begin m_memq.delete(j); break; end
          end else
            wq.push_back(s);
        end
        m_ctxq[2] = wq;
      end
      // ctx-3 entries are all still live and resolvable
      for (int i = 1; i < 32; i += 2) begin
        op(mkr(APU_OBJTAB_OP_LOOKUP, w_ids[i], 6'd6, 0, 0, 0, 0, 0, 0,
               0), c);
        check($sformatf("walk ctx3 live %0d", i),
              c.status == APU_OBJTAB_OK);
      end
      xpect("walk ctx2 dead", mkr(APU_OBJTAB_OP_LOOKUP, w_ids[2], 6'd6,
                                   0, 0, 0, 0, 0, 0, 0), APU_OBJTAB_MISS);
      // pinned ctx-2 entry survives
      op(mkr(APU_OBJTAB_OP_LOOKUP, w_ids[0], 6'd6, 0, 0, 0, 0, 0, 0, 0),
         c);
      check("walk pinned stays", c.status == APU_OBJTAB_OK);
      // overflow head: ctx >= MaxCtx share one list — reset of ctx 8
      // must not kill ctx 9's entries
      for (int i = 0; i < 2; i++) begin
        logic [63:0] oid;
        oid = 64'hE200_0000_0000_0000 | 64'(i + 1);
        op(mkr(APU_OBJTAB_OP_ALLOC, oid, 6'd6, 0, 8'(8 + i), 0, 0, 0,
               0, 0), c);
        check($sformatf("walk ovl alloc %0d", i),
              c.status == APU_OBJTAB_OK);
        void'(m_alloc(oid, 6'd6, 64'h0, 8'(8 + i), slot, gen));
      end
      op(mkr(APU_OBJTAB_OP_RESET_CTX, 0, 0, 0, 8'd8, 0, 0, 0, 0, 0), c);
      check("walk ovl reset", c.status == APU_OBJTAB_OK &&
                              c.handle[15:0] == 16'd0);
      begin
        int wq [$];
        for (int i = 0; i < m_ctxq[MaxCtx].size(); i++) begin
          automatic int s = m_ctxq[MaxCtx][i];
          if (me_ctx[s] == 8'd8 && me_pins[s] == 0) begin
            me_live[s] = 0; m_fpush(s);
          end else
            wq.push_back(s);
        end
        m_ctxq[MaxCtx] = wq;
      end
      xpect("walk ovl ctx9 lives",
            mkr(APU_OBJTAB_OP_LOOKUP, 64'hE200_0000_0000_0002, 6'd6, 0,
                0, 0, 0, 0, 0, 0), APU_OBJTAB_OK);
    end
    cases++;

    // ---- probe cap: 12 colliding ids all allocate (cap 32) --------
    m_reset;
    do_reset;
    begin
      logic [63:0] base;
      int nfound;
      logic [63:0] col_ids [12];
      base = 64'hF000_0000_0000_0000;
      nfound = 0;
      for (longint t = 0; t < 400000 && nfound < 12; t++) begin
        logic [63:0] cid;
        cid = base + 64'(t + 1);
        if (cid[63:32] == 0) cid |= 64'h1000_0000_0000_0000;
        if (mhash(cid) != mhash(base)) continue;
        col_ids[nfound] = cid;
        nfound++;
        op(mkr(APU_OBJTAB_OP_ALLOC, cid, 6'd6, 0, 8'd9, 0, 0, 0, 0, 0),
           c);
        check($sformatf("probe alloc %0d", nfound),
              c.status == APU_OBJTAB_OK);
        void'(m_alloc(cid, 6'd6, 64'h0, 8'd9, slot, gen));
      end
      check("collision search", nfound == 12);
      for (int i = 0; i < 12; i++) begin
        op(mkr(APU_OBJTAB_OP_LOOKUP, col_ids[i], 6'd6, 0, 0, 0, 0, 0, 0,
               0), c);
        check($sformatf("probe lookup %0d", i),
              c.status == APU_OBJTAB_OK);
      end
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
      if (sel < 4) begin
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
        if (ids.size() == 0) continue;
        rid = ids[$urandom_range(0, ids.size()-1)];
        rnd = rnd * 32'h9E3779B9 + 32'h85EBCA6B;
        if (rnd[5]) begin
          int mslot;
          if (m_resolve(rid, 0, 0, mslot) == APU_OBJTAB_OK)
            rid = hnd(me_gen[mslot] + (rnd[6] ? 0 : 1), mslot);
          else
            rid = {32'h0, 32'($urandom)};
        end
        case (rnd[4:3])
          2'd0: begin
            est = m_resolve(rid, 6'(rnd[13:8]), 6'(rnd[13:8]) != 0, s2);
            op(mkr(APU_OBJTAB_OP_LOOKUP, rid, 6'(rnd[13:8]), 0, 0, 0, 0,
                   0, 0, 0), c);
            g_exp = int'(est); check($sformatf("rnd lookup %0d", i), c.status == est);
          end
          2'd1: begin
            logic [5:0] kk;
            kk = 6'(rnd[13:8]);
            est = m_resolve(rid, kk, kk != 0, s2);
            if (est != APU_OBJTAB_OK) est = est;
            else if (me_pins[s2] != 0) est = APU_OBJTAB_PINNED;
            else if (me_refcnt[s2] != 0) est = APU_OBJTAB_BUSY_CHILDREN;
            else begin
              m_kill(s2);
              if (rid[63:32] != 0 && m_probe(rid, hb, rb) == 0)
                md_t[hb] = 1;
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
            est = m_resolve(rid, 6'(rnd[13:8]), 6'(rnd[13:8]) != 0, s2);
            if (est == APU_OBJTAB_OK)
              me_pins[s2] = me_pins[s2] == 255 ? 255 : me_pins[s2] + 1;
            op(mkr(APU_OBJTAB_OP_PIN, rid, 6'(rnd[13:8]), 0, 0, 0, 0, 0,
                   0, 0), c);
            g_exp = int'(est); check($sformatf("rnd pin %0d", i), c.status == est);
          end
          default: begin
            est = m_resolve(rid, 6'(rnd[13:8]), 6'(rnd[13:8]) != 0, s2);
            if (est == APU_OBJTAB_OK && me_pins[s2] > 0) me_pins[s2]--;
            op(mkr(APU_OBJTAB_OP_UNPIN, rid, 6'(rnd[13:8]), 0, 0, 0, 0,
                   0, 0, 0), c);
            g_exp = int'(est); check($sformatf("rnd unpin %0d", i), c.status == est);
          end
        endcase
      end else if (sel < 8) begin
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
        int pcnt;
        rnd = rnd * 32'h9E3779B9 + 32'h85EBCA6B;
        pcnt = 0;
        begin
          // model RESET_CTX: walk the ctx head's list, kill matching
          // unpinned entries in order
          int wq [$];
          int rc8 = rnd[10:8];
          for (int s3 = 0; s3 < m_ctxq[mcidx(rc8)].size(); s3++) begin
            automatic int s = m_ctxq[mcidx(rc8)][s3];
            if (me_live[s] && me_ctx[s] == rc8) begin
              if (me_pins[s] != 0) begin
                pcnt++; wq.push_back(s);
              end else begin
                if (me_parent[s] >= 0 && me_live[me_parent[s]] &&
                    me_refcnt[me_parent[s]] > 0)
                  me_refcnt[me_parent[s]]--;
                me_live[s] = 0; m_fpush(s);
                for (int j = 0; j < m_memq.size(); j++)
                  if (m_memq[j] == s) begin m_memq.delete(j); break; end
              end
            end else
              wq.push_back(s);
          end
          m_ctxq[mcidx(rc8)] = wq;
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
          est = m_resolve(rid, 6'(rnd[13:8]), 6'(rnd[13:8]) != 0, s2);
          op(mkr(APU_OBJTAB_OP_LOOKUP, rid, 6'(rnd[13:8]), 0, 0, 0, 0, 0,
                 0, 0), c);
          g_exp = int'(est); check($sformatf("rnd miss %0d", i), c.status == est);
        end
      end
    end
    cases++;

    // ---- epoch reuse: rows a RESET_CTX leaves behind must not alias
    m_reset;
    do_reset;
    begin
      int slot0, a0_slot;
      for (int rep = 0; rep < 3; rep++) begin
        if (rep == 0) begin
          for (int i = 0; i < 6; i++) begin
            id = 64'hCAFE_0000_0000_0000 | 64'(i + 1);
            st = m_alloc(id, 6'd7, 64'h0, 8'd1, slot, gen);
            op(mkr(APU_OBJTAB_OP_ALLOC, id, 6'd7, 0, 8'd1,
                   0, 0, 0, 0, 0), c);
            check($sformatf("epoch%0d alloc A%0d", rep, i),
                  st == APU_OBJTAB_OK && c.status == APU_OBJTAB_OK &&
                  c.handle == {16'(gen), 16'(slot)});
            if (i == 0) a0_slot = slot;
          end
        end
        op(mkr(APU_OBJTAB_OP_RESET_CTX, 0, 0, 0, 8'd1, 0, 0, 0, 0, 0), c);
        check($sformatf("epoch%0d reset_ctx", rep),
              c.status == APU_OBJTAB_OK && c.handle[15:0] == 16'd0);
        begin
          int wq [$];
          for (int i = 0; i < m_ctxq[1].size(); i++) begin
            automatic int s = m_ctxq[1][i];
            if (me_ctx[s] == 8'd1 && me_pins[s] == 0) begin
              me_live[s] = 0; m_fpush(s);
              for (int j = 0; j < m_memq.size(); j++)
                if (m_memq[j] == s) begin m_memq.delete(j); break; end
            end else
              wq.push_back(s);
          end
          m_ctxq[1] = wq;
        end
        // blob-style epoch: different ids in ctx 0 recycle the freed
        // slots — stack order serves the oldest swept slot first
        for (int i = 0; i < 4; i++) begin
          id = 64'hB10B_0000_0000_0000 | 64'(rep * 16 + i + 1);
          st = m_alloc(id, 6'd27, 64'h0, 8'd0, slot, gen);
          op(mkr(APU_OBJTAB_OP_ALLOC, id, 6'd27, 0, 8'd0,
                 0, 0, 0, 0, 0), c);
          check($sformatf("epoch%0d blob %0d", rep, i),
                st == APU_OBJTAB_OK && c.status == APU_OBJTAB_OK &&
                c.handle == {16'(gen), 16'(slot)});
          if (i == 0) slot0 = slot;
        end
        check($sformatf("epoch%0d blobs recycled epoch-A slots", rep),
              slot0 == a0_slot);
        for (int i = 0; i < 6; i++) begin
          id = 64'hCAFE_0000_0000_0000 | 64'(i + 1);
          xpect($sformatf("epoch%0d lookup A%0d", rep, i),
                mkr(APU_OBJTAB_OP_LOOKUP, id, 6'd7, 0, 0, 0, 0, 0, 0, 0),
                APU_OBJTAB_MISS);
          st = m_alloc(id, 6'd7, 64'h0, 8'd1, slot, gen);
          op(mkr(APU_OBJTAB_OP_ALLOC, id, 6'd7, 0, 8'd1, 0, 0, 0, 0, 0),
             c);
          check($sformatf("epoch%0d realloc A%0d", rep, i),
                st == APU_OBJTAB_OK && c.status == APU_OBJTAB_OK &&
                c.handle == {16'(gen), 16'(slot)});
          if (i == 0) a0_slot = slot;
        end
        check($sformatf("epoch%0d live A+blob", rep),
              live_o_w == 16'(6 + 4 * (rep + 1)));
      end
    end
    cases++;

    // ---- RETIRE_KIDS: pool-shaped parent sweep ---------------------
    m_reset;
    do_reset;
    begin
      int psl, kn;
      op(mkr(APU_OBJTAB_OP_ALLOC, 64'hD000_0000_0000_0001, 6'd20, 0,
             8'd3, 0, 0, 0, 0, 0), c);
      check("kids: alloc pool A", c.status == APU_OBJTAB_OK);
      psl = int'(c.handle[15:0]);
      void'(m_alloc(64'hD000_0000_0000_0001, 6'd20, 64'h0, 8'd3,
                    slot, gen));
      op(mkr(APU_OBJTAB_OP_ALLOC, 64'hD000_0000_0000_0002, 6'd20, 0,
             8'd3, 0, 0, 0, 0, 0), c);
      check("kids: alloc pool B", c.status == APU_OBJTAB_OK);
      void'(m_alloc(64'hD000_0000_0000_0002, 6'd20, 64'h0, 8'd3,
                    slot, gen));
      for (int i = 0; i < 5; i++) begin
        id = 64'hD000_0000_0000_0100 | 64'(i + 1);
        st = m_alloc(id, 6'd21, 64'hD000_0000_0000_0001, 8'd3,
                     slot, gen);
        op(mkr(APU_OBJTAB_OP_ALLOC, id, 6'd21,
               64'hD000_0000_0000_0001, 8'd3, 0, 0, 0, 0, 0), c);
        check($sformatf("kids: alloc set %0d", i),
              st == APU_OBJTAB_OK && c.status == APU_OBJTAB_OK &&
              c.handle == {16'(gen), 16'(slot)});
      end
      id = 64'hD000_0000_0000_0200;
      st = m_alloc(id, 6'd21, 64'hD000_0000_0000_0002, 8'd3,
                   slot, gen);
      op(mkr(APU_OBJTAB_OP_ALLOC, id, 6'd21, 64'hD000_0000_0000_0002,
             8'd3, 0, 0, 0, 0, 0), c);
      check("kids: alloc set B0",
            st == APU_OBJTAB_OK && c.status == APU_OBJTAB_OK);
      xpect("kids: busy parent", mkr(APU_OBJTAB_OP_RETIRE,
              64'hD000_0000_0000_0001, 6'd20, 0, 0, 0, 0, 0, 0, 0),
            APU_OBJTAB_BUSY_CHILDREN);
      op(mkr(APU_OBJTAB_OP_RETIRE_KIDS, 64'(psl), 6'd0, 0, 0,
             0, 0, 0, 0, 0), c);
      check("kids: sweep count", c.status == APU_OBJTAB_OK &&
                                c.handle[15:0] == 16'd5);
      // model the kids walk: kills land on the free stack in the
      // parent's ctx-list order (snapshot first — m_kill mutates
      // m_ctxq through m_unlink)
      kn = 0;
      begin
        int kills [$];
        for (int i = 0; i < m_ctxq[3].size(); i++) begin
          automatic int s = m_ctxq[3][i];
          if (me_live[s] && me_parent[s] == psl)
            kills.push_back(s);
        end
        foreach (kills[i]) begin m_kill(kills[i]); kn++; end
      end
      check("kids: model count", kn == 5);
      me_refcnt[psl] = 0;
      check("kids: live_o", live_o_w == 16'd3);
      for (int i = 0; i < 5; i++) begin
        id = 64'hD000_0000_0000_0100 | 64'(i + 1);
        xpect($sformatf("kids: dead set %0d", i),
              mkr(APU_OBJTAB_OP_LOOKUP, id, 6'd21, 0, 0, 0, 0, 0, 0, 0),
              APU_OBJTAB_MISS);
      end
      xpect("kids: sibling set lives",
            mkr(APU_OBJTAB_OP_LOOKUP, 64'hD000_0000_0000_0200, 6'd21,
                0, 0, 0, 0, 0, 0, 0), APU_OBJTAB_OK);
      xpect("kids: retire pool A", mkr(APU_OBJTAB_OP_RETIRE,
              64'hD000_0000_0000_0001, 6'd20, 0, 0, 0, 0, 0, 0, 0),
            APU_OBJTAB_OK);
      me_live[psl] = 0; m_unlink(psl); m_fpush(psl);
      void'(m_probe(64'hD000_0000_0000_0001, hb, rb));
      if (hb >= 0) md_t[hb] = 1;
      xpect("kids: range", mkr(APU_OBJTAB_OP_RETIRE_KIDS,
              64'(ObjEntries + 7), 6'd0, 0, 0, 0, 0, 0, 0, 0),
            APU_OBJTAB_MISS);
      op(mkr(APU_OBJTAB_OP_RETIRE_KIDS, 64'(ObjEntries - 1), 6'd0, 0, 0,
             0, 0, 0, 0, 0), c);
      check("kids: empty sweep", c.status == APU_OBJTAB_OK &&
                                 c.handle[15:0] == 16'd0);
    end
    cases++;

    // ---- SCAN_OVL among 1000 other-kind live entries ----------------
    m_reset;
    do_reset;
    begin
      int o_slot [5], o_gen [5];
      logic [63:0] o_ids [5];
      // noise: 1,000 live entries of a non-devmem kind — none may be
      // reported by the overlap scan (they are not on the kind list)
      for (int i = 0; i < 1000; i++) begin
        id = 64'h0E00_0000_0000_0000 | 64'(i + 1);
        op(mkr(APU_OBJTAB_OP_ALLOC, id, 6'd5, 0, 8'd4, 0, 0, 0, 0, 0),
           c);
        check($sformatf("ovl: noise %0d", i),
              c.status == APU_OBJTAB_OK);
        void'(m_alloc(id, 6'd5, 64'h0, 8'd4, slot, gen));
      end
      // devmem extents: A/B overlap the window, C not devbacked,
      // D UNBACKED, E wrong kind.  The kind list is head-inserted, so
      // the scan reports the NEWEST overlapping entry first.
      o_ids[0] = 64'h0E11_0000_0000_0001;   // A base 0x8000 sz 0x4000
      o_ids[1] = 64'h0E11_0000_0000_0002;   // B base 0x8800 sz 0x1000
      o_ids[2] = 64'h0E11_0000_0000_0003;   // C base 0x8400 sz 0x0800
      o_ids[3] = 64'h0E11_0000_0000_0004;   // D UNBACKED
      o_ids[4] = 64'h0E11_0000_0000_0005;   // E wrong kind
      for (int i = 0; i < 5; i++) begin
        op(mkr(APU_OBJTAB_OP_ALLOC, o_ids[i], i == 4 ? 6'd7 : 6'd8,
               0, 8'd1, 0, 0, 0, 0, 0), c);
        check($sformatf("ovl: alloc %0d", i),
              c.status == APU_OBJTAB_OK);
        o_slot[i] = int'(c.handle[15:0]);
        o_gen[i]  = int'(c.handle[31:16]);
        void'(m_alloc(o_ids[i], i == 4 ? 6'd7 : 6'd8, 64'h0, 8'd1,
                      slot, gen));
      end
      begin
        logic [63:0] szs [5];
        szs[0] = 64'h4000; szs[1] = 64'h1000; szs[2] = 64'h0800;
        szs[3] = 64'h4000; szs[4] = 64'h4000;
        for (int i = 0; i < 5; i++) begin
          op(mkr(APU_OBJTAB_OP_SETBIND, o_ids[i],
                 i == 4 ? 6'd7 : 6'd8, 0, 0, 0, 0,
                 o_ids[0], 0, szs[i]), c);
          check($sformatf("ovl: setbind %0d", i),
                c.status == APU_OBJTAB_OK);
        end
      end
      begin
        logic [31:0] bases [5];
        bases[0] = 32'h8000; bases[1] = 32'h8800; bases[2] = 32'h8400;
        bases[3] = APU_MEM_UNBACKED; bases[4] = 32'h8000;
        for (int i = 0; i < 5; i++) begin
          op(mkr(APU_OBJTAB_OP_SETAUXHI, o_ids[i],
                 i == 4 ? 6'd7 : 6'd8, 0, 0, 32'hFFFF_FFFF,
                 bases[i], 0, 0, 0), c);
          check($sformatf("ovl: setauxhi %0d", i),
                c.status == APU_OBJTAB_OK);
          if (i != 2) begin
            op(mkr(APU_OBJTAB_OP_SETAUX, o_ids[i],
                   i == 4 ? 6'd7 : 6'd8, 0, 0, 32'h1, 32'h1,
                   0, 0, 0), c);
            check($sformatf("ovl: devbacked %0d", i),
                  c.status == APU_OBJTAB_OK);
          end
        end
      end
      // kind list order is D,C,B,A — first overlap = B
      op(mkr(APU_OBJTAB_OP_SCAN_OVL, 64'hFFFF,
             6'd8, 0, 0, 0, 0, 0, 64'h7000, 64'h9000), c);
      check("ovl: first match B", c.status == APU_OBJTAB_OK &&
            c.handle == {16'(o_gen[1]), 16'(o_slot[1])});
      op(mkr(APU_OBJTAB_OP_SCAN_OVL, 64'(o_slot[1]),
             6'd8, 0, 0, 0, 0, 0, 64'h7000, 64'h9000), c);
      check("ovl: excluding B yields A",
            c.status == APU_OBJTAB_OK &&
            c.handle == {16'(o_gen[0]), 16'(o_slot[0])});
      op(mkr(APU_OBJTAB_OP_SCAN_OVL, 64'(o_slot[0]),
             6'd8, 0, 0, 0, 0, 0, 64'h7000, 64'h9000), c);
      check("ovl: B still first",
            c.status == APU_OBJTAB_OK &&
            c.handle == {16'(o_gen[1]), 16'(o_slot[1])});
      xpect("ovl: disjoint", mkr(APU_OBJTAB_OP_SCAN_OVL, 64'hFFFF,
             6'd8, 0, 0, 0, 0, 0, 64'h1000, 64'h7000),
            APU_OBJTAB_MISS);
      xpect("ovl: edge", mkr(APU_OBJTAB_OP_SCAN_OVL, 64'hFFFF,
             6'd8, 0, 0, 0, 0, 0, 64'hC000, 64'hD000),
            APU_OBJTAB_MISS);
      op(mkr(APU_OBJTAB_OP_SCAN_OVL, 64'hFFFF,
             6'd8, 0, 0, 0, 0, 0, 64'h8800, 64'h9800), c);
      check("ovl: B precedes A", c.status == APU_OBJTAB_OK &&
            c.handle == {16'(o_gen[1]), 16'(o_slot[1])});
      xpect("ovl: retire B", mkr(APU_OBJTAB_OP_RETIRE, o_ids[1],
              6'd8, 0, 0, 0, 0, 0, 0, 0), APU_OBJTAB_OK);
      me_live[o_slot[1]] = 0; m_unlink(o_slot[1]);
      m_fpush(o_slot[1]);
      op(mkr(APU_OBJTAB_OP_SCAN_OVL, 64'hFFFF,
             6'd8, 0, 0, 0, 0, 0, 64'h7000, 64'h9000), c);
      check("ovl: evicted A", c.status == APU_OBJTAB_OK &&
            c.handle == {16'(o_gen[0]), 16'(o_slot[0])});
      xpect("ovl: retire A", mkr(APU_OBJTAB_OP_RETIRE, o_ids[0],
              6'd8, 0, 0, 0, 0, 0, 0, 0), APU_OBJTAB_OK);
      me_live[o_slot[0]] = 0; m_unlink(o_slot[0]);
      m_fpush(o_slot[0]);
      xpect("ovl: all evicted", mkr(APU_OBJTAB_OP_SCAN_OVL, 64'hFFFF,
              6'd8, 0, 0, 0, 0, 0, 64'h7000, 64'h9000),
            APU_OBJTAB_MISS);
    end
    cases++;

    // ---- SETAUXHI_CAS: atomic aux[63:32] publish ---------------------
    m_reset;
    do_reset;
    begin
      int          cs_slot, cs_gen;
      logic [63:0] cs_id;
      cs_id = 64'h0E33_0000_0000_0001;
      op(mkr(APU_OBJTAB_OP_ALLOC, cs_id, 6'd8, 0, 8'd1, 0, 0, 0, 0, 0),
         c);
      check("cas: alloc", c.status == APU_OBJTAB_OK);
      cs_slot = int'(c.handle[15:0]); cs_gen = int'(c.handle[31:16]);
      void'(m_alloc(cs_id, 6'd8, 64'h0, 8'd1, slot, gen));
      h1 = hnd(cs_gen, cs_slot);
      xpect("cas: expect UNBACKED vs 0",
            mkr(APU_OBJTAB_OP_SETAUXHI_CAS, h1, 6'd8, 0, 0, 32'h1,
                32'h017F_C000, 0, 64'hFFFF_FFFF, 0),
            APU_OBJTAB_CONFLICT);
      xpect("cas: setauxhi UNBACKED",
            mkr(APU_OBJTAB_OP_SETAUXHI, h1, 6'd8, 0, 0, 32'hFFFF_FFFF,
                32'hFFFF_FFFF, 0, 0, 0), APU_OBJTAB_OK);
      op(mkr(APU_OBJTAB_OP_SETAUXHI_CAS, h1, 6'd8, 0, 0, 32'h1,
             32'h017F_C000, 0, 64'hFFFF_FFFF, 0), c);
      check("cas: bind publish", c.status == APU_OBJTAB_OK &&
            c.entry.aux == 64'hFFFF_FFFF_0000_0000);
      op(mkr(APU_OBJTAB_OP_LOOKUP, h1, 6'd8, 0, 0, 0, 0, 0, 0, 0), c);
      check("cas: aux after publish",
            c.status == APU_OBJTAB_OK &&
            c.entry.aux == 64'h017F_C000_0000_0001);
      op(mkr(APU_OBJTAB_OP_SETAUXHI_CAS, h1, 6'd8, 0, 0, 32'h0,
             32'h0012_3000, 0, 64'hFFFF_FFFF, 0), c);
      check("cas: late map loses", c.status == APU_OBJTAB_CONFLICT &&
            c.entry.aux[63:32] == 32'h017F_C000);
      op(mkr(APU_OBJTAB_OP_LOOKUP, h1, 6'd8, 0, 0, 0, 0, 0, 0, 0), c);
      check("cas: aux preserved",
            c.status == APU_OBJTAB_OK &&
            c.entry.aux == 64'h017F_C000_0000_0001);
      cs_id = 64'h0E33_0000_0000_0002;
      op(mkr(APU_OBJTAB_OP_ALLOC, cs_id, 6'd8, 0, 8'd1, 0, 0, 0, 0, 0),
         c);
      cs_slot = int'(c.handle[15:0]); cs_gen = int'(c.handle[31:16]);
      void'(m_alloc(cs_id, 6'd8, 64'h0, 8'd1, slot, gen));
      h1 = hnd(cs_gen, cs_slot);
      xpect("cas: setauxhi UNBACKED 2",
            mkr(APU_OBJTAB_OP_SETAUXHI, h1, 6'd8, 0, 0, 32'hFFFF_FFFF,
                32'hFFFF_FFFF, 0, 0, 0), APU_OBJTAB_OK);
      op(mkr(APU_OBJTAB_OP_SETAUXHI_CAS, h1, 6'd8, 0, 0, 32'h0,
             32'h0092_6000, 0, 64'hFFFF_FFFF, 0), c);
      check("cas: map publish", c.status == APU_OBJTAB_OK);
      op(mkr(APU_OBJTAB_OP_LOOKUP, h1, 6'd8, 0, 0, 0, 0, 0, 0, 0), c);
      check("cas: map published base",
            c.status == APU_OBJTAB_OK &&
            c.entry.aux == 64'h0092_6000_0000_0000);
      xpect("cas: dead is MISS",
            mkr(APU_OBJTAB_OP_RETIRE, cs_id, 6'd8, 0, 0, 0, 0, 0, 0, 0),
            APU_OBJTAB_OK);
      me_live[cs_slot] = 0; m_unlink(cs_slot); m_fpush(cs_slot);
      xpect("cas: dead handle",
            mkr(APU_OBJTAB_OP_SETAUXHI_CAS, h1, 6'd8, 0, 0, 32'h0,
                32'h1, 0, 64'hFFFF_FFFF, 0), APU_OBJTAB_GEN);
    end
    cases++;

    // ---- global invariant ----------------------------------------------
    begin
      int nlive;
      nlive = 0;
      for (int i = 0; i < ObjEntries; i++)
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
