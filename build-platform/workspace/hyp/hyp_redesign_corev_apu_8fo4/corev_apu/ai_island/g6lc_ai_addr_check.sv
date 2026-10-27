// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai per-queue address region checker (AI-3).
//
// Each queue has a programmed [base, limit) window and R/W permission bits
// carrying the submitting context. A T2 DMA master must pass every pointer
// through this unit before issue — unchecked dereference from a mapped
// doorbell is privilege escalation (architecture/ai-matrix/isa-encoding.md §7).
//
// Timing: pure combinational check; programming is FF'd. No DMA path lengthening.

module g6lc_ai_addr_check #(
    parameter int unsigned NumQueues = 2,
    parameter int unsigned AddrWidth = 64,
    parameter int unsigned QidWidth  = (NumQueues > 1) ? $clog2(NumQueues) : 1
) (
    input  logic                  clk_i,
    input  logic                  rst_ni,
    // Programming (S-mode / island BAR). Applies on prog_we_i.
    input  logic                  prog_we_i,
    input  logic [QidWidth-1:0]   prog_qid_i,
    input  logic [AddrWidth-1:0]  prog_base_i,
    input  logic [AddrWidth-1:0]  prog_limit_i,  // exclusive end
    input  logic [1:0]            prog_perm_i,   // [0]=R [1]=W
    // Check request (combinational result when check_req_i)
    input  logic                  check_req_i,
    input  logic [QidWidth-1:0]   check_qid_i,
    input  logic [AddrWidth-1:0]  check_addr_i,
    input  logic [AddrWidth-1:0]  check_len_i,   // bytes; 0 means 1-byte probe
    input  logic                  check_need_r_i,
    input  logic                  check_need_w_i,
    output logic                  check_ok_o,
    // Second probe so a descriptor fetch can be checked while the engine
    // holds the primary request. Same committed window.
    input  logic                  probe_req_i,
    input  logic [QidWidth-1:0]   probe_qid_i,
    input  logic [AddrWidth-1:0]  probe_addr_i,
    input  logic [AddrWidth-1:0]  probe_len_i,
    input  logic                  probe_need_r_i,
    input  logic                  probe_need_w_i,
    output logic                  probe_ok_o
);

  typedef logic [AddrWidth-1:0] addr_t;

  addr_t              base_q  [NumQueues];
  addr_t              limit_q [NumQueues];
  logic [1:0]         perm_q  [NumQueues];
  logic [NumQueues-1:0] valid_q;  // programmed at least once

  

  // BEGIN sv-timing auto-correct (balance_mux rewrite)
// ----------------------------------------------------------------
// sv-timing: always_ff factorize  (clock-aware ParallelScratch)
// timing-basis: S(s)=max producer C; C(s)=S(s)+L(s); M=max C;
//   N=ceil(M/B) cycles of posedge clk_i  period_ns=0.200000  B=8.000 FO4
// module=g6lc_ai_addr_check  region=6620  makespan=6.850 FO4  cycle_count=1  deps=0  procedural_ok=true
// OpenSTA (review-only seeds — not set_max_delay):
//   create_clock -name clk_i -period 0.200000 [get_ports clk_i]
// order expect: base_q  ready_cycle=1  ready_fo4=6.850  OpenSTA: report_timing -from clk_i -to base_q
// order expect: limit_q  ready_cycle=1  ready_fo4=6.850  OpenSTA: report_timing -from clk_i -to limit_q
// order expect: perm_q  ready_cycle=1  ready_fo4=6.850  OpenSTA: report_timing -from clk_i -to perm_q
// order expect: valid_q  ready_cycle=1  ready_fo4=6.850  OpenSTA: report_timing -from clk_i -to valid_q
// --- factor stage 1/1  capture on posedge clk_i ---
// always_ff @(posedge clk_i or negedge rst_ni) begin
//   if (!rst_ni) begin /* reset */ end else begin
//     base_q <= …; // sv-timing: cycle 1/1 on clk_i
//     limit_q <= …; // sv-timing: cycle 1/1 on clk_i
//     perm_q <= …; // sv-timing: cycle 1/1 on clk_i
//     valid_q <= …; // sv-timing: cycle 1/1 on clk_i
//     /* node23227 c=3.50 slack=3.35 */
//     /* node23228 c=3.50 slack=3.35 */
//     /* node23229 c=3.50 slack=3.35 */
//     /* node23230 c=3.50 slack=3.35 */
//     /* node23231 c=6.85 slack=0.00 */
//     /* node23232 c=6.85 slack=0.00 */
//     /* node23233 c=6.85 slack=0.00 */
//     /* node23234 c=6.85 slack=0.00 */
//   end
// end
// ----------------------------------------------------------------
  // END sv-timing auto-correct (balance_mux rewrite)
always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned q = 0; q < NumQueues; q++) begin
        base_q[q]  <= '0;
        limit_q[q] <= '0;
        perm_q[q]  <= '0;
      end
      valid_q <= '0;
    end else if (prog_we_i && (int'(prog_qid_i) < NumQueues)) begin
      base_q[prog_qid_i]  <= prog_base_i;
      limit_q[prog_qid_i] <= prog_limit_i;
      perm_q[prog_qid_i]  <= prog_perm_i;
      valid_q[prog_qid_i] <= 1'b1;
    end
  end

  function automatic bit range_ok(
      input logic v,
      input logic [1:0] perm,
      input addr_t base, limit, addr, len,
      input logic need_r, need_w);
    addr_t span;
    logic [64:0] end65;
    logic in_range, perm_ok;
    // Zero length means a one-byte probe, so an empty range cannot pass.
    span = (len == '0) ? addr_t'(1) : len;
    // G6: one shared 65-bit addr+span; the wrap test is the carry bit and
    // `last < limit` becomes `end <= limit` (no wrap), so both compares run
    // off the single adder instead of `addr + span - 1` feeding two compares.
    end65 = 65'(addr) + 65'(span);
    in_range = v && (limit > base) && (addr >= base)
        && !end65[64] && (end65[63:0] <= 64'(limit));
    perm_ok = (!need_r || perm[0]) && (!need_w || perm[1]);
    return in_range && perm_ok;
  endfunction

  always_comb begin
    check_ok_o = 1'b0;
    probe_ok_o = 1'b0;
    if (check_req_i && (int'(check_qid_i) < NumQueues))
      check_ok_o = range_ok(
          valid_q[check_qid_i], perm_q[check_qid_i],
          base_q[check_qid_i], limit_q[check_qid_i],
          check_addr_i, check_len_i, check_need_r_i, check_need_w_i);
    if (probe_req_i && (int'(probe_qid_i) < NumQueues))
      probe_ok_o = range_ok(
          valid_q[probe_qid_i], perm_q[probe_qid_i],
          base_q[probe_qid_i], limit_q[probe_qid_i],
          probe_addr_i, probe_len_i, probe_need_r_i, probe_need_w_i);
  end

endmodule
