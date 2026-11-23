// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Server-ready multi-stream + next-line prefetcher at the L2/L3 miss boundary.
//
// Observes demand misses (line-aligned addresses) and generates prefetch
// requests for:
//   1. Next-line(s) at ServerPfDistance
//   2. Stride continuation when a stream is trained
//
// Prefetch traffic is merged onto the memory AXI master via a simple arbiter
// (demand always wins). When Enable=0 this is a pure AXI identity.

module g6lc_server_prefetcher #(
    parameter bit          Enable        = 1'b1,
    parameter int unsigned NR_STREAMS    = 4,
    parameter int unsigned PF_DISTANCE   = 2,   // lines ahead
    parameter int unsigned LINE_BYTES    = 64,
    parameter int unsigned AXI_ADDR_WIDTH = 64,
    parameter int unsigned AXI_DATA_WIDTH = 64,
    parameter int unsigned AXI_ID_WIDTH   = 4,
    parameter int unsigned AXI_USER_WIDTH = 1,
    parameter type axi_req_t  = logic,
    parameter type axi_resp_t = logic
) (
    input  logic     clk_i,
    input  logic     rst_ni,
    // From upper level (L2 or L3 master toward memory)
    input  axi_req_t  up_req_i,
    output axi_resp_t up_resp_o,
    // Toward DRAM
    output axi_req_t  dn_req_o,
    input  axi_resp_t dn_resp_i,
    // Observability
    output logic      pf_issue_o,
    output logic      pf_train_o
);

  if (!Enable) begin : gen_off
    

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_server_prefetcher  region=6427  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: st_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to st_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     st_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node22873 c=3.50 slack=0.00 */
//     /* node22874 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_server_prefetcher  region=6432  makespan=3.500 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: pf_addr_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to pf_addr_q
// order expect: pf_ot_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to pf_ot_q
// order expect: pf_pending_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to pf_pending_q
// order expect: up_pfid_ot_q  ready_cycle=1  ready_fo4=3.500  OpenSTA: report_timing -from clk_i -to up_pfid_ot_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     pf_addr_q <= …; // sv-timing: cycle 1/1 on clk_i
//     pf_ot_q <= …; // sv-timing: cycle 1/1 on clk_i
//     pf_pending_q <= …; // sv-timing: cycle 1/1 on clk_i
//     up_pfid_ot_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node22889 c=3.50 slack=0.00 */
//     /* node22890 c=3.50 slack=0.00 */
//     /* node22891 c=3.50 slack=0.00 */
//     /* node22892 c=3.50 slack=0.00 */
//     /* node22893 c=3.50 slack=0.00 */
//     /* node22894 c=3.50 slack=0.00 */
//     /* node22895 c=3.50 slack=0.00 */
//     /* node22896 c=3.50 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
// sv-timing: origin <src>/corev_apu/l3_cache/g6lc_server_prefetcher.sv:86:15 edit=650
  // relocation t1_balance_mux; balance_mux credit path 16737 node 22859 exclusive residual 67.8->33.9 (latency-neutral) extras=0
// sv-timing: origin <src>/corev_apu/l3_cache/g6lc_server_prefetcher.sv:86:15 edit=657
  // relocation t1_balance_mux; balance_mux credit path 16712 node 22859 exclusive residual 54.8->27.4 (latency-neutral) extras=0
// sv-timing: origin <src>/corev_apu/l3_cache/g6lc_server_prefetcher.sv:86:15 edit=664
  // relocation t1_balance_mux; balance_mux credit path 16713 node 22859 exclusive residual 54.8->27.4 (latency-neutral) extras=0
  // END sv-timing auto-correct (balance_mux rewrite)
assign dn_req_o  = up_req_i;
    assign up_resp_o = dn_resp_i;
    assign pf_issue_o = 1'b0;
    assign pf_train_o = 1'b0;
  end else begin : gen_pf

    localparam int unsigned OFF = $clog2(LINE_BYTES);

    typedef struct packed {
      logic                      valid;
      logic [AXI_ADDR_WIDTH-1:0] addr;     // last demand line
      // A136 registered expected next address (addr + stride) so match is a
      // pure equality compare with no 64-bit add ahead of it.
      logic [AXI_ADDR_WIDTH-1:0] exp_addr;
      logic signed [31:0]        stride;   // bytes
      logic [2:0]                conf;     // train confidence
    } stream_t;

    stream_t [NR_STREAMS-1:0] st_q, st_d;
    logic [NR_STREAMS-1:0] match_s, retrain_s, hit_stream, alloc_oh;
    logic signed [31:0]    delta_s [NR_STREAMS];
    logic [AXI_ADDR_WIDTH-1:0] hit_pf_addr [NR_STREAMS];
    logic [AXI_ADDR_WIDTH-1:0] alloc_pf_addr;
    logic any_hit, any_free;
    logic train, issue;
    logic [AXI_ADDR_WIDTH-1:0] pf_addr, demand_line;
    logic demand_ar;
    // 1-cycle speculative training tap off the demand AR channel: demand AR
    // still bypasses at 0 cycles directly to dn_req_o, while stream matching
    // runs off registered inputs (breaking the cross-module cluster->pf cone).
    logic                      tr_ar_q;
    logic [AXI_ADDR_WIDTH-1:0] tr_line_q;

    assign demand_ar = up_req_i.ar_valid;
    assign demand_line = {up_req_i.ar.addr[AXI_ADDR_WIDTH-1:OFF], {OFF{1'b0}}};

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        tr_ar_q   <= 1'b0;
        tr_line_q <= '0;
      end else begin
        tr_ar_q   <= demand_ar;
        tr_line_q <= demand_line;
      end
    end

    // Precompute first free stream slot purely from st_q flops (independent of
    // demand match) and the next-line alloc prefetch address in parallel.
    logic [NR_STREAMS-1:0] inv_v_s;
    for (genvar gs = 0; gs < NR_STREAMS; gs++) begin : gen_alloc_oh
      assign inv_v_s[gs] = !st_q[gs].valid;
      if (gs == 0) begin : gen_s0
        assign alloc_oh[0] = inv_v_s[0];
      end else begin : gen_sn
        assign alloc_oh[gs] = inv_v_s[gs] && !(|inv_v_s[gs-1:0]);
      end
    end
    assign any_free      = |inv_v_s;
    assign alloc_pf_addr = tr_line_q + AXI_ADDR_WIDTH'(LINE_BYTES * PF_DISTANCE);

    localparam bit PF_DIST_POW2 = (PF_DISTANCE > 0) && ((PF_DISTANCE & (PF_DISTANCE - 1)) == 0);
    localparam int unsigned PF_DIST_SH = (PF_DISTANCE <= 1) ? 0 : $clog2(PF_DISTANCE);

    logic [AXI_ADDR_WIDTH-1:0] match_exp_s [NR_STREAMS];
    logic [AXI_ADDR_WIDTH-1:0] retrain_exp_s [NR_STREAMS];
    logic [AXI_ADDR_WIDTH-1:0] alloc_exp_addr;
    assign alloc_exp_addr = tr_line_q + AXI_ADDR_WIDTH'(LINE_BYTES);

    // Parallel per-stream match / retrain evaluation off registered tr_line_q
    // and st_q (constant-index per stream, all 64b adds unconditional outside
    // if-guards to avoid A146 broadcast billing).
    always_comb begin : gen_match_eval
      for (int unsigned s = 0; s < NR_STREAMS; s++) begin
        logic signed [31:0] d_s;
        logic signed [AXI_ADDR_WIDTH-1:0] str_ext, d_ext, str_dist;
        d_s = signed'(tr_line_q[31:0] - st_q[s].addr[31:0]);
        delta_s[s] = d_s;
        match_s[s] = st_q[s].valid && (tr_line_q == st_q[s].exp_addr);
        retrain_s[s] = st_q[s].valid && !match_s[s] && (d_s != '0) && (st_q[s].conf < 3'd2);
        hit_stream[s] = match_s[s] | retrain_s[s];
        str_ext  = {{(AXI_ADDR_WIDTH-32){st_q[s].stride[31]}}, st_q[s].stride};
        d_ext    = {{(AXI_ADDR_WIDTH-32){d_s[31]}}, d_s};
        str_dist = PF_DIST_POW2 ? (str_ext <<< PF_DIST_SH)
                                : (str_ext * $signed(AXI_ADDR_WIDTH'(PF_DISTANCE)));
        hit_pf_addr[s]   = tr_line_q + AXI_ADDR_WIDTH'(str_dist);
        match_exp_s[s]   = tr_line_q + AXI_ADDR_WIDTH'(str_ext);
        retrain_exp_s[s] = tr_line_q + AXI_ADDR_WIDTH'(d_ext);
      end
      any_hit = |hit_stream;
    end

    // Per-stream constant-index state update + decoupled hit/alloc issue select
    always_comb begin : gen_stream_upd
      logic                      hit_issue;
      logic [AXI_ADDR_WIDTH-1:0] hit_addr;
      st_d      = st_q;
      hit_issue = 1'b0;
      hit_addr  = '0;
      for (int unsigned s = 0; s < NR_STREAMS; s++) begin
        if (tr_ar_q) begin
          if (match_s[s]) begin
            st_d[s].addr     = tr_line_q;
            st_d[s].exp_addr = match_exp_s[s];
            if (st_q[s].conf != 3'b111) st_d[s].conf = st_q[s].conf + 1'b1;
            hit_issue = (st_q[s].conf >= 3'd2);
            hit_addr  = hit_pf_addr[s];
          end else if (retrain_s[s]) begin
            st_d[s].stride   = delta_s[s];
            st_d[s].addr     = tr_line_q;
            st_d[s].exp_addr = retrain_exp_s[s];
            st_d[s].conf     = 3'd1;
          end else if (!any_hit && alloc_oh[s]) begin
            st_d[s].valid    = 1'b1;
            st_d[s].addr     = tr_line_q;
            st_d[s].exp_addr = alloc_exp_addr;
            st_d[s].stride   = LINE_BYTES[31:0];
            st_d[s].conf     = 3'd0;
          end
        end
      end
      train   = tr_ar_q && (any_hit || any_free);
      issue   = tr_ar_q && (any_hit ? hit_issue : any_free);
      pf_addr = any_hit ? hit_addr : alloc_pf_addr;
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) st_q <= '0;
      else st_q <= st_d;
    end

    // --- AXI merge: demand always preferred; PF only when AR idle ---
    // Track PF request + outstanding so R beats are absorbed here and never
    // forwarded to L2 (L2 r_ready is 0 outside S_MISS_R/S_BYPASS_R — a PF R
    // left unabsorbed deadlocks axi2mem forever).
    logic pf_pending_q, pf_pending_d;
    logic pf_ot_q, pf_ot_d;  // PF AR accepted, waiting for R last
    logic [AXI_ADDR_WIDTH-1:0] pf_addr_q, pf_addr_d;
    // Upstream reads already owning the reserved id. While any is outstanding a
    // prefetch response would be indistinguishable from the demand burst, so
    // no prefetch may be injected and the absorb path must stay closed.
    localparam logic [AXI_ID_WIDTH-1:0] PF_ID = '1;
    logic [3:0] up_pfid_ot_q, up_pfid_ot_d;
    logic pf_inject, pf_beat, up_pfid_alias;

    assign up_pfid_alias = up_req_i.ar_valid && (up_req_i.ar.id == PF_ID);
    assign pf_inject     = pf_pending_q && !up_req_i.ar_valid && !pf_ot_q &&
                           (up_pfid_ot_q == '0);
    assign pf_beat       = pf_ot_q && dn_resp_i.r_valid &&
                           (dn_resp_i.r.id == PF_ID);

    always_comb begin
      pf_pending_d = pf_pending_q;
      pf_addr_d    = pf_addr_q;
      pf_ot_d      = pf_ot_q;
      up_pfid_ot_d = up_pfid_ot_q;
      if (issue && !pf_ot_q) begin
        pf_pending_d = 1'b1;
        pf_addr_d    = pf_addr;
      end
      // PF AR accepted by downstream
      if (pf_inject && dn_resp_i.ar_ready) begin
        pf_pending_d = 1'b0;
        pf_ot_d      = 1'b1;
      end
      // PF R completed (absorb last beat) — only the reserved id retires it
      if (pf_beat && dn_resp_i.r.last) begin
        pf_ot_d = 1'b0;
      end
      // Upstream reserved-id reads: accepted downstream, retired upstream
      if (!pf_inject && dn_req_o.ar_valid && dn_resp_i.ar_ready &&
          dn_req_o.ar.id == PF_ID) begin
        up_pfid_ot_d = up_pfid_ot_q + 1'b1;
      end
      if (up_resp_o.r_valid && up_req_i.r_ready && up_resp_o.r.last &&
          up_resp_o.r.id == PF_ID) begin
        up_pfid_ot_d = up_pfid_ot_d - 1'b1;
      end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        pf_pending_q <= 1'b0;
        pf_ot_q      <= 1'b0;
        pf_addr_q    <= '0;
        up_pfid_ot_q <= '0;
      end else begin
        pf_pending_q <= pf_pending_d;
        pf_ot_q      <= pf_ot_d;
        pf_addr_q    <= pf_addr_d;
        up_pfid_ot_q <= up_pfid_ot_d;
      end
    end

    // Default: pass through demand. Hold demand AR while a PF is outstanding
    // so R demux stays unambiguous (PF uses a reserved id).
    always_comb begin
      dn_req_o  = up_req_i;
      up_resp_o = dn_resp_i;

      // Block only the demand ARs that would alias the reserved id: any other
      // id stays independently routable while a prefetch is outstanding.
      if ((pf_ot_q || pf_inject) && up_pfid_alias) begin
        dn_req_o.ar_valid = 1'b0;
        up_resp_o.ar_ready = 1'b0;
      end

      // Inject PF AR when upper AR idle and no PF OT
      // Demand always wins the AR channel, and only one prefetch may be in
      // flight: the PF response is absorbed here, so a second one would have
      // no reserved id to come back on.
      if (pf_inject) begin
        dn_req_o.ar_valid = 1'b1;
        dn_req_o.ar       = up_req_i.ar;  // inherit size/burst/cache defaults
        dn_req_o.ar.addr  = pf_addr_q;
        dn_req_o.ar.id    = PF_ID;        // reserved PF id (all-ones)
        dn_req_o.ar.len   = '0;           // single-beat probe
      end

      // Absorb PF R: do not present to upper; assert r_ready toward memory
      if (pf_beat) begin
        up_resp_o.r_valid = 1'b0;
        dn_req_o.r_ready  = 1'b1;
      end
    end

    assign pf_issue_o = issue;
    assign pf_train_o = train;

  end

endmodule
