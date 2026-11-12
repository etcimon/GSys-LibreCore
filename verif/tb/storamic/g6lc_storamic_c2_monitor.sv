// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// C2 native interconnect scoreboard for the real ariane_testharness. Passive
// simulation-only observer: packed request/response struct inputs only, no
// interface ports, no driven functional signal. Fixed-size tables only (no
// dynamic queues) so the pinned simulator generates it without restriction.
//
// Checked, with a reason-coded $fatal naming the offending transaction:
//  - every AW/AR accepted on the Storamic crossbar master port carries a
//    prefix p < NrSlaves and equals, field for field, the oldest not-yet-routed
//    in-window request accepted on requestor port p (the interconnect inserts
//    the prefix and nothing else);
//  - nothing outside the Storamic rule reaches that master port, and no
//    in-window request is lost (bounded age) or duplicated;
//  - the bridge behind the route holds one write (AW..B) and one read
//    (AR..last R) at a time; W beats follow the owning AW;
//  - every B/R observed on a requestor port answers an outstanding request of
//    that port and ID (oldest first); for Storamic requests the device answer
//    must already exist and the response code must be the device's. A
//    response steered to the wrong port therefore fails as spurious there and
//    as lost on the originating port;
//  - served pages answer OKAY, the rest of the rule answers an error;
//  - at transaction completion source_ok equals the exact native candidate
//    shape (prefix 0, PROT 001, CACHE_MODIFIABLE, single aligned word, control
//    page); while source_ok is high the owner has that shape; authorized is
//    never asserted.

module g6lc_storamic_c2_monitor #(
  parameter int unsigned NrSlaves     = 3,
  parameter int unsigned LocalIdWidth = 4,
  parameter int unsigned IdWidthSlave = LocalIdWidth + $clog2(NrSlaves),
  parameter logic [63:0] Base         = 64'h5000_0000,
  parameter logic [63:0] Length       = 64'h10_0000,
  parameter bit          CtrlPageEn   = 1'b1,
  parameter int unsigned Depth        = 32,
  parameter int unsigned MaxAge       = 100000,
  parameter type slv_req_t  = logic,
  parameter type slv_resp_t = logic,
  parameter type mst_req_t  = logic,
  parameter type mst_resp_t = logic
) (
  input logic clk_i,
  input logic rst_ni,
  input slv_req_t  slv_req  [NrSlaves],
  input slv_resp_t slv_resp [NrSlaves],
  input mst_req_t  mst_req,
  input mst_resp_t mst_resp,
  input logic aw_source_ok_i,
  input logic ar_source_ok_i,
  input logic aw_authorized_i,
  input logic ar_authorized_i
);
  // verilator lint_off BLKSEQ
  // verilator lint_off WIDTH
  typedef struct packed {
    logic        vld;
    logic        sto;       // targets the Storamic rule
    logic        at_mst;    // seen on the Storamic master port
    logic        dev_done;  // device answered (B, or last R)
    logic        atop_r;    // R owed by an atomic AW, no AR exists
    logic [1:0]  dev_resp;
    logic [31:0] id;
    logic [63:0] addr;
    logic [7:0]  len;
    logic [2:0]  size;
    logic [1:0]  burst;
    logic        lock;
    logic [3:0]  cache;
    logic [2:0]  prot;
    logic [5:0]  atop;
    logic [31:0] beats;     // requestor-side R beats still owed
    logic [63:0] seq;
    logic [63:0] born;
  } ent_t;

  ent_t wtab [NrSlaves][Depth];
  ent_t rtab [NrSlaves][Depth];
  logic [63:0] seq_q, cycle_q;

  // Single write / read owned by the bridge.
  logic        own_w_vld, own_r_vld;
  int          own_w_p, own_w_i, own_r_p, own_r_i;
  logic [31:0] own_w_beats, own_r_beats;
  logic        own_w_wdone;

  int unsigned p_aw [NrSlaves], p_ar [NrSlaves];   // in-window accepts per port
  int unsigned m_aw [NrSlaves], m_ar [NrSlaves];   // master-port accepts per prefix
  int unsigned dma_beats [NrSlaves];
  int unsigned src_ok_aw, src_ok_ar, err_resp, done_w, done_r, max_outstanding;
  int unsigned max_local_id, violations;

  function automatic bit in_window(input logic [63:0] a);
    return a >= Base && (a - Base) < Length;
  endfunction
  function automatic bit served(input logic [63:0] a);
    return (CtrlPageEn && (a - Base) < 64'h1000) ||
           ((a - Base) >= 64'h1000 && (a - Base) < 64'h2000);
  endfunction
  function automatic bit is_err(input logic [1:0] r);
    return r == axi_pkg::RESP_SLVERR || r == axi_pkg::RESP_DECERR;
  endfunction
  function automatic bit src_shape(input int p, input ent_t e);
    return p == 0 && e.prot == 3'b001 && e.cache == axi_pkg::CACHE_MODIFIABLE &&
           !e.lock && e.len == 0 && e.size == 3'd2 && e.burst <= 2'b01 &&
           e.atop == 0 && e.addr[1:0] == 0 && CtrlPageEn &&
           (e.addr - Base) < 64'h1000;
  endfunction

  task automatic c2_fatal(input string reason, input int p,
                          input logic [63:0] id, input logic [63:0] addr);
    violations++;
    $fatal(1, "STORAMIC_C2_VIOLATION %s p=%0d id=%h addr=%h cycle=%0d",
           reason, p, id, addr, cycle_q);
  endtask

  // Oldest valid entry of port p matching the selector; -1 when none.
  //  mode 0: same id (response matching)
  //  mode 1: Storamic and not yet routed (request matching)
  function automatic int oldest(input bit wr, input int p, input int mode,
                                input logic [31:0] id);
    int best;
    logic [63:0] best_seq;
    ent_t e;
    best = -1; best_seq = '1;
    for (int i = 0; i < Depth; i++) begin
      e = wr ? wtab[p][i] : rtab[p][i];
      if (e.vld && e.seq < best_seq &&
          ((mode == 0 && e.id == id) || (mode == 1 && e.sto && !e.at_mst && !e.atop_r))) begin
        best = i; best_seq = e.seq;
      end
    end
    return best;
  endfunction
  function automatic int free_slot(input bit wr, input int p);
    for (int i = 0; i < Depth; i++)
      if (!(wr ? wtab[p][i].vld : rtab[p][i].vld)) return i;
    return -1;
  endfunction

  int k, outstanding;
  ent_t e;
  logic [31:0] pre, loc;

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int p = 0; p < NrSlaves; p++) begin
        for (int i = 0; i < Depth; i++) begin
          wtab[p][i] = '0; rtab[p][i] = '0;
        end
        p_aw[p] = 0; p_ar[p] = 0; m_aw[p] = 0; m_ar[p] = 0; dma_beats[p] = 0;
      end
      seq_q = 0; cycle_q = 0; own_w_vld = 0; own_r_vld = 0; own_w_wdone = 0;
      own_w_p = 0; own_w_i = 0; own_r_p = 0; own_r_i = 0;
      own_w_beats = 0; own_r_beats = 0;
      src_ok_aw = 0; src_ok_ar = 0; err_resp = 0; done_w = 0; done_r = 0;
      max_outstanding = 0; max_local_id = 0; violations = 0;
    end else begin
      cycle_q = cycle_q + 1;

      // ---- sidebands: registered flags describe the pre-edge owner --------
      if (aw_authorized_i || ar_authorized_i)
        c2_fatal("authorized_asserted", 0, '0, '0);
      if (aw_source_ok_i &&
          !(own_w_vld && src_shape(own_w_p, wtab[own_w_p][own_w_i])))
        c2_fatal("aw_source_ok_shape", own_w_p, '0, '0);
      if (ar_source_ok_i &&
          !(own_r_vld && src_shape(own_r_p, rtab[own_r_p][own_r_i])))
        c2_fatal("ar_source_ok_shape", own_r_p, '0, '0);

      // ---- requestor ports: record every accepted request ------------------
      for (int p = 0; p < NrSlaves; p++) begin
        if (slv_req[p].aw_valid && $test$plusargs("c2_trace"))
          $display("C2TR AWV p=%0d id=%0d addr=%h ready=%0d cyc=%0d",
                   p, slv_req[p].aw.id, slv_req[p].aw.addr,
                   slv_resp[p].aw_ready, cycle_q);
        if (slv_req[p].aw_valid && slv_resp[p].aw_ready) begin
          k = free_slot(1'b1, p);
          if (k < 0) c2_fatal("wtab_full", p, slv_req[p].aw.id, slv_req[p].aw.addr);
          e = '0;
          e.vld = 1'b1; e.sto = in_window(slv_req[p].aw.addr);
          e.id = slv_req[p].aw.id; e.addr = slv_req[p].aw.addr;
          e.len = slv_req[p].aw.len; e.size = slv_req[p].aw.size;
          e.burst = slv_req[p].aw.burst; e.lock = slv_req[p].aw.lock;
          e.cache = slv_req[p].aw.cache; e.prot = slv_req[p].aw.prot;
          e.atop = slv_req[p].aw.atop;
          e.seq = seq_q; e.born = cycle_q; seq_q = seq_q + 1;
          wtab[p][k] = e;
          if (e.sto) p_aw[p]++;
          // AXI5 atomic operations with ATOP_R_RESP answer on R as well as B
          // without any AR; the requestor port owes that read response too.
          if (slv_req[p].aw.atop[axi_pkg::ATOP_R_RESP]) begin
            k = free_slot(1'b0, p);
            if (k < 0) c2_fatal("rtab_full", p, slv_req[p].aw.id, slv_req[p].aw.addr);
            e.atop_r = 1'b1; e.beats = 32'(slv_req[p].aw.len) + 1;
            e.seq = seq_q; seq_q = seq_q + 1;
            rtab[p][k] = e;
          end
          if ($test$plusargs("c2_trace"))
            $display("C2TR AW p=%0d id=%0d addr=%h len=%0d size=%0d beats=%0d seq=%0d",
                     p, e.id, e.addr, e.len, e.size,
                     32'(slv_req[p].aw.len) + 1, e.seq);
        end
        if (slv_req[p].ar_valid && $test$plusargs("c2_trace"))
          $display("C2TR ARV p=%0d id=%0d addr=%h ready=%0d cyc=%0d",
                   p, slv_req[p].ar.id, slv_req[p].ar.addr,
                   slv_resp[p].ar_ready, cycle_q);
        if (slv_req[p].ar_valid && slv_resp[p].ar_ready) begin
          k = free_slot(1'b0, p);
          if (k < 0) c2_fatal("rtab_full", p, slv_req[p].ar.id, slv_req[p].ar.addr);
          e = '0;
          e.vld = 1'b1; e.sto = in_window(slv_req[p].ar.addr);
          e.id = slv_req[p].ar.id; e.addr = slv_req[p].ar.addr;
          e.len = slv_req[p].ar.len; e.size = slv_req[p].ar.size;
          e.burst = slv_req[p].ar.burst; e.lock = slv_req[p].ar.lock;
          e.cache = slv_req[p].ar.cache; e.prot = slv_req[p].ar.prot;
          e.beats = 32'(slv_req[p].ar.len) + 1;
          e.seq = seq_q; e.born = cycle_q; seq_q = seq_q + 1;
          rtab[p][k] = e;
          if ($test$plusargs("c2_trace"))
            $display("C2TR AR p=%0d id=%0d addr=%h len=%0d size=%0d beats=%0d seq=%0d",
                     p, e.id, e.addr, e.len, e.size, e.beats, e.seq);
          if (e.sto) p_ar[p]++;
        end
        if (slv_req[p].w_valid && slv_resp[p].w_ready) dma_beats[p]++;
        if (slv_resp[p].r_valid && slv_req[p].r_ready) dma_beats[p]++;
      end

      // ---- Storamic master port: requests ----------------------------------
      if (mst_req.aw_valid && mst_resp.aw_ready) begin
        pre = 32'(mst_req.aw.id) >> LocalIdWidth;
        loc = 32'(mst_req.aw.id) & ((32'd1 << LocalIdWidth) - 1);
        if (!in_window(mst_req.aw.addr))
          c2_fatal("aw_out_of_rule", pre, mst_req.aw.id, mst_req.aw.addr);
        if (pre >= NrSlaves)
          c2_fatal("aw_bad_prefix", pre, mst_req.aw.id, mst_req.aw.addr);
        if (own_w_vld)
          c2_fatal("aw_overlap", pre, mst_req.aw.id, mst_req.aw.addr);
        k = oldest(1'b1, pre, 1, '0);
        if (k < 0) c2_fatal("aw_unmatched", pre, mst_req.aw.id, mst_req.aw.addr);
        e = wtab[pre][k];
        if (!(e.id == loc && e.addr == mst_req.aw.addr && e.len == mst_req.aw.len &&
              e.size == mst_req.aw.size && e.burst == mst_req.aw.burst &&
              e.lock == mst_req.aw.lock && e.cache == mst_req.aw.cache &&
              e.prot == mst_req.aw.prot && e.atop == mst_req.aw.atop))
          c2_fatal("aw_payload", pre, mst_req.aw.id, mst_req.aw.addr);
        wtab[pre][k].at_mst = 1'b1;
        own_w_vld = 1'b1; own_w_p = pre; own_w_i = k;
        own_w_beats = 32'(mst_req.aw.len) + 1; own_w_wdone = 1'b0;
        if (loc > max_local_id) max_local_id = loc;
        m_aw[pre]++;
      end
      if (mst_req.w_valid && mst_resp.w_ready) begin
        // The bridge may take W with or after its AW, never before.
        if (!own_w_vld || own_w_wdone) c2_fatal("w_no_owner", 0, '0, '0);
        own_w_beats = own_w_beats - 1;
        if (mst_req.w.last != (own_w_beats == 0))
          c2_fatal("w_last", own_w_p, '0, wtab[own_w_p][own_w_i].addr);
        if (mst_req.w.last) own_w_wdone = 1'b1;
      end
      if (mst_req.ar_valid && mst_resp.ar_ready) begin
        pre = 32'(mst_req.ar.id) >> LocalIdWidth;
        loc = 32'(mst_req.ar.id) & ((32'd1 << LocalIdWidth) - 1);
        if (!in_window(mst_req.ar.addr))
          c2_fatal("ar_out_of_rule", pre, mst_req.ar.id, mst_req.ar.addr);
        if (pre >= NrSlaves)
          c2_fatal("ar_bad_prefix", pre, mst_req.ar.id, mst_req.ar.addr);
        if (own_r_vld)
          c2_fatal("ar_overlap", pre, mst_req.ar.id, mst_req.ar.addr);
        k = oldest(1'b0, pre, 1, '0);
        if (k < 0) c2_fatal("ar_unmatched", pre, mst_req.ar.id, mst_req.ar.addr);
        e = rtab[pre][k];
        if (!(e.id == loc && e.addr == mst_req.ar.addr && e.len == mst_req.ar.len &&
              e.size == mst_req.ar.size && e.burst == mst_req.ar.burst &&
              e.lock == mst_req.ar.lock && e.cache == mst_req.ar.cache &&
              e.prot == mst_req.ar.prot))
          c2_fatal("ar_payload", pre, mst_req.ar.id, mst_req.ar.addr);
        rtab[pre][k].at_mst = 1'b1;
        own_r_vld = 1'b1; own_r_p = pre; own_r_i = k;
        own_r_beats = 32'(mst_req.ar.len) + 1;
        if (loc > max_local_id) max_local_id = loc;
        m_ar[pre]++;
      end
      outstanding = (own_w_vld ? 1 : 0) + (own_r_vld ? 1 : 0);
      if (outstanding > max_outstanding) max_outstanding = outstanding;

      // ---- Storamic master port: device responses (before requestor side) --
      if (mst_resp.b_valid && mst_req.b_ready) begin
        if (!own_w_vld) c2_fatal("b_no_owner", 0, mst_resp.b.id, '0);
        e = wtab[own_w_p][own_w_i];
        if (32'(mst_resp.b.id) != ((own_w_p << LocalIdWidth) | e.id))
          c2_fatal("b_id", own_w_p, mst_resp.b.id, e.addr);
        if (!own_w_wdone) c2_fatal("b_before_wlast", own_w_p, mst_resp.b.id, e.addr);
        if (served(e.addr) == is_err(mst_resp.b.resp))
          c2_fatal(served(e.addr) ? "served_b_err" : "unserved_b_okay",
                   own_w_p, mst_resp.b.id, e.addr);
        if (aw_source_ok_i != src_shape(own_w_p, e))
          c2_fatal("aw_source_ok_value", own_w_p, mst_resp.b.id, e.addr);
        if (aw_source_ok_i) src_ok_aw++;
        if (is_err(mst_resp.b.resp)) err_resp++;
        wtab[own_w_p][own_w_i].dev_done = 1'b1;
        wtab[own_w_p][own_w_i].dev_resp = mst_resp.b.resp;
        own_w_vld = 1'b0; done_w++;
      end
      if (mst_resp.r_valid && mst_req.r_ready) begin
        if (!own_r_vld) c2_fatal("r_no_owner", 0, mst_resp.r.id, '0);
        e = rtab[own_r_p][own_r_i];
        if (32'(mst_resp.r.id) != ((own_r_p << LocalIdWidth) | e.id))
          c2_fatal("r_id", own_r_p, mst_resp.r.id, e.addr);
        own_r_beats = own_r_beats - 1;
        if (mst_resp.r.last != (own_r_beats == 0))
          c2_fatal("r_last", own_r_p, mst_resp.r.id, e.addr);
        if (mst_resp.r.last) begin
          if (served(e.addr) == is_err(mst_resp.r.resp))
            c2_fatal(served(e.addr) ? "served_r_err" : "unserved_r_okay",
                     own_r_p, mst_resp.r.id, e.addr);
          if (ar_source_ok_i != src_shape(own_r_p, e))
            c2_fatal("ar_source_ok_value", own_r_p, mst_resp.r.id, e.addr);
          if (ar_source_ok_i) src_ok_ar++;
          if (is_err(mst_resp.r.resp)) err_resp++;
          rtab[own_r_p][own_r_i].dev_done = 1'b1;
          rtab[own_r_p][own_r_i].dev_resp = mst_resp.r.resp;
          own_r_vld = 1'b0; done_r++;
        end
      end

      // ---- requestor ports: responses --------------------------------------
      for (int p = 0; p < NrSlaves; p++) begin
        if (slv_resp[p].b_valid && slv_req[p].b_ready) begin
          k = oldest(1'b1, p, 0, slv_resp[p].b.id);
          if (k < 0) c2_fatal("b_spurious", p, slv_resp[p].b.id, '0);
          e = wtab[p][k];
          if (e.sto) begin
            if (!e.dev_done) c2_fatal("b_without_device", p, slv_resp[p].b.id, e.addr);
            if (slv_resp[p].b.resp != e.dev_resp)
              c2_fatal("b_resp_changed", p, slv_resp[p].b.id, e.addr);
          end
          wtab[p][k].vld = 1'b0;
        end
        if (slv_resp[p].r_valid && slv_req[p].r_ready) begin
          k = oldest(1'b0, p, 0, slv_resp[p].r.id);
          if ($test$plusargs("c2_trace"))
            $display("C2TR RR p=%0d id=%0d last=%0d resp=%0d k=%0d cyc=%0d",
                     p, slv_resp[p].r.id, slv_resp[p].r.last,
                     slv_resp[p].r.resp, k, cycle_q);
          if (k < 0) begin
            $display("C2DBG r_spurious p=%0d rid=%0d rlast=%0d resp=%0d cyc=%0d",
                     p, slv_resp[p].r.id, slv_resp[p].r.last,
                     slv_resp[p].r.resp, cycle_q);
            for (int i = 0; i < Depth; i++)
              if (rtab[p][i].vld)
                $display("C2DBG   slot%0d id=%0d beats=%0d seq=%0d addr=%h sto=%0d at_mst=%0d",
                         i, rtab[p][i].id, rtab[p][i].beats, rtab[p][i].seq,
                         rtab[p][i].addr, rtab[p][i].sto, rtab[p][i].at_mst);
            c2_fatal("r_spurious", p, slv_resp[p].r.id, '0);
          end
          e = rtab[p][k];
          rtab[p][k].beats = e.beats - 1;
          if (slv_resp[p].r.last != (e.beats == 1))
            c2_fatal("r_beats", p, slv_resp[p].r.id, e.addr);
          if (slv_resp[p].r.last) begin
            // The route candidate requires atop == 0, so an atomic request in
            // the Storamic rule can never be a source candidate; its R half is
            // only accounted on the requestor port.
            if (e.sto && !e.atop_r) begin
              if (!e.dev_done)
                c2_fatal("r_without_device", p, slv_resp[p].r.id, e.addr);
              if (slv_resp[p].r.resp != e.dev_resp)
                c2_fatal("r_resp_changed", p, slv_resp[p].r.id, e.addr);
            end
            rtab[p][k].vld = 1'b0;
          end
        end
      end

      // ---- bounded age: an in-window request must be routed and answered ---
      for (int p = 0; p < NrSlaves; p++)
        for (int i = 0; i < Depth; i++) begin
          if (wtab[p][i].vld && wtab[p][i].sto && cycle_q - wtab[p][i].born > MaxAge)
            c2_fatal(wtab[p][i].at_mst ? "b_lost" : "aw_lost", p,
                     wtab[p][i].id, wtab[p][i].addr);
          if (rtab[p][i].vld && rtab[p][i].sto && !rtab[p][i].atop_r && cycle_q - rtab[p][i].born > MaxAge)
            c2_fatal(rtab[p][i].at_mst ? "r_lost" : "ar_lost", p,
                     rtab[p][i].id, rtab[p][i].addr);
        end
    end
  end

  int unsigned pending;
  final begin
    pending = 0;
    for (int p = 0; p < NrSlaves; p++)
      for (int i = 0; i < Depth; i++) begin
        if (wtab[p][i].vld && wtab[p][i].sto) pending++;
        if (rtab[p][i].vld && rtab[p][i].sto && !rtab[p][i].atop_r) pending++;
      end
    if ($test$plusargs("storamic_c2_report"))
      $display("STORAMIC_C2_NATIVE p0_aw=%0d p0_ar=%0d p1_aw=%0d p1_ar=%0d p2_aw=%0d p2_ar=%0d m0_aw=%0d m0_ar=%0d m1_aw=%0d m1_ar=%0d m2_aw=%0d m2_ar=%0d done_w=%0d done_r=%0d src_ok_aw=%0d src_ok_ar=%0d err_resp=%0d max_outstanding=%0d beats0=%0d beats1=%0d beats2=%0d max_lid=%0d pending=%0d violations=%0d",
               p_aw[0], p_ar[0], p_aw[1], p_ar[1], p_aw[2], p_ar[2],
               m_aw[0], m_ar[0], m_aw[1], m_ar[1], m_aw[2], m_ar[2],
               done_w, done_r, src_ok_aw, src_ok_ar, err_resp, max_outstanding,
               dma_beats[0], dma_beats[1], dma_beats[2], max_local_id,
               pending, violations);
  end
  // verilator lint_on WIDTH
  // verilator lint_on BLKSEQ
endmodule
