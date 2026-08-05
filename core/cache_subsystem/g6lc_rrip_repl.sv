// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Versions of this file released before 2026-08-05 were additionally available
// under Apache-2.0 WITH SHL-2.1; that grant is irrevocable for those versions.
//
// U3 SRRIP / DRRIP replacement (Jaleel et al., ISCA 2010).
// Best policy for scan-resistant streaming (skb / memcpy) that must not thrash
// a small working set — far better than PLRU on that pattern.
//
// SRRIP:  RRPV in {0..2^M-1}, insert at RRPV_MAX-1, hit → 0, victim = max RRPV
//         (age all if none at max).
// DRRIP:  set dueling between SRRIP (insert MAX-1) and BRRIP (insert MAX with
//         probability ~1/32) using a PSEL saturating counter.

module g6lc_rrip_repl
  import ariane_pkg::*;
#(
    parameter int unsigned NR_SETS  = 128,
    parameter int unsigned NR_WAYS  = 4,
    parameter int unsigned RRPV_BITS = 2,
    parameter bit          DRRIP_EN  = 1'b0
) (
    input  logic                       clk_i,
    input  logic                       rst_ni,
    // Hit / promote
    input  logic                       updt_i,
    input  logic [$clog2(NR_SETS)-1:0] updt_set_i,
    input  logic [NR_WAYS-1:0]         updt_way_i,   // one-hot
    // Victim select among candidates
    input  logic                       sel_i,
    input  logic [NR_WAYS-1:0]         sel_valid_i,  // ways eligible for eviction
    input  logic [$clog2(NR_SETS)-1:0] sel_set_i,
    output logic [NR_WAYS-1:0]         sel_way_o,    // one-hot victim
    // Install on fill (one-hot way that is being filled)
    input  logic                       fill_i,
    input  logic [$clog2(NR_SETS)-1:0] fill_set_i,
    input  logic [NR_WAYS-1:0]         fill_way_i
);

  localparam int unsigned SET_W = (NR_SETS <= 1) ? 1 : $clog2(NR_SETS);
  localparam logic [RRPV_BITS-1:0] RRPV_MAX = {RRPV_BITS{1'b1}};
  localparam logic [RRPV_BITS-1:0] RRPV_LONG = RRPV_MAX - {{(RRPV_BITS - 1) {1'b0}}, 1'b1};

  logic [NR_SETS-1:0][NR_WAYS-1:0][RRPV_BITS-1:0] rrpv_q, rrpv_d;
  // PSEL for DRRIP set dueling: MSB=1 → favor BRRIP, 0 → favor SRRIP
  logic [9:0] psel_q, psel_d;
  logic [4:0] lfsr_q, lfsr_d;

  logic [RRPV_BITS-1:0] best_rrpv;
  logic [NR_WAYS-1:0]   cand_ways;
  logic                 use_brrip;
  logic                 any_max;

  // ----- Victim: prefer highest RRPV among valid candidates -----
  always_comb begin
    sel_way_o  = '0;
    best_rrpv  = '0;
    cand_ways  = '0;
    if (sel_i) begin
      for (int unsigned w = 0; w < NR_WAYS; w++) begin
        if (sel_valid_i[w] && (rrpv_q[sel_set_i][w] >= best_rrpv))
          best_rrpv = rrpv_q[sel_set_i][w];
      end
      for (int unsigned w = 0; w < NR_WAYS; w++)
        cand_ways[w] = sel_valid_i[w] && (rrpv_q[sel_set_i][w] == best_rrpv);
      // Lowest-index one-hot
      for (int unsigned w = 0; w < NR_WAYS; w++) begin
        if (cand_ways[w] && sel_way_o == '0) sel_way_o[w] = 1'b1;
      end
      if (sel_way_o == '0) begin
        for (int unsigned w = 0; w < NR_WAYS; w++) begin
          if (sel_valid_i[w] && sel_way_o == '0) sel_way_o[w] = 1'b1;
        end
      end
    end
  end

  // ----- Update / fill / age -----
  always_comb begin
    rrpv_d    = rrpv_q;
    psel_d    = psel_q;
    lfsr_d    = lfsr_q;
    use_brrip = 1'b0;
    any_max   = 1'b0;

    if (fill_i) lfsr_d = {lfsr_q[3:0], lfsr_q[4] ^ lfsr_q[2]};

    if (updt_i) begin
      for (int unsigned w = 0; w < NR_WAYS; w++) begin
        if (updt_way_i[w]) rrpv_d[updt_set_i][w] = '0;
      end
    end

    if (fill_i) begin
      if (DRRIP_EN) begin
        if (fill_set_i == '0) use_brrip = 1'b0;
        else if (fill_set_i == SET_W'(1)) use_brrip = 1'b1;
        else use_brrip = psel_q[9];
        if (fill_set_i == '0) begin
          if (psel_q != '0) psel_d = psel_q - 10'd1;
        end else if (fill_set_i == SET_W'(1)) begin
          if (psel_q != 10'h3ff) psel_d = psel_q + 10'd1;
        end
      end
      for (int unsigned w = 0; w < NR_WAYS; w++) begin
        if (fill_way_i[w]) begin
          if (use_brrip)
            rrpv_d[fill_set_i][w] = (lfsr_q == 5'b0) ? RRPV_LONG : RRPV_MAX;
          else
            rrpv_d[fill_set_i][w] = RRPV_LONG;
        end
      end
      for (int unsigned w = 0; w < NR_WAYS; w++)
        if (rrpv_d[fill_set_i][w] == RRPV_MAX) any_max = 1'b1;
      if (!any_max) begin
        for (int unsigned w = 0; w < NR_WAYS; w++)
          if (rrpv_d[fill_set_i][w] != RRPV_MAX)
            rrpv_d[fill_set_i][w] = rrpv_d[fill_set_i][w] + 1'b1;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      // Distant re-reference on reset
      for (int unsigned s = 0; s < NR_SETS; s++)
        for (int unsigned w = 0; w < NR_WAYS; w++) rrpv_q[s][w] <= RRPV_MAX;
      psel_q <= 10'h200;  // mid
      lfsr_q <= 5'h1f;
    end else begin
      rrpv_q <= rrpv_d;
      psel_q <= psel_d;
      lfsr_q <= lfsr_d;
    end
  end

endmodule
