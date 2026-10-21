// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
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
  import g6lc_core_pkg::*;
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

  // Victim: highest RRPV among eligible ways, then the lowest index.
  // Same choice as the reference scan in core/cache_subsystem. Invalid
  // ways contribute 0 and are excluded from the one-hot by sel_valid.
  localparam int unsigned WAY_LV = (NR_WAYS <= 1) ? 1 : $clog2(NR_WAYS);
  logic [WAY_LV:0][NR_WAYS-1:0][RRPV_BITS-1:0] vmax;
  for (genvar w = 0; w < NR_WAYS; w++) begin : gen_vmax0
    assign vmax[0][w] = sel_valid_i[w] ? rrpv_q[sel_set_i][w] : '0;
  end
  for (genvar lvl = 0; lvl < WAY_LV; lvl++) begin : gen_vmax
    for (genvar i = 0; i < (NR_WAYS >> (lvl + 1)); i++) begin : gen_pair
      assign vmax[lvl+1][i] = (vmax[lvl][2*i] >= vmax[lvl][2*i+1])
                            ? vmax[lvl][2*i] : vmax[lvl][2*i+1];
    end
  end
  assign best_rrpv = vmax[WAY_LV][0];
  for (genvar w = 0; w < NR_WAYS; w++) begin : gen_cand
    assign cand_ways[w] = sel_i && sel_valid_i[w] &&
                          (rrpv_q[sel_set_i][w] == best_rrpv);
  end
  // Lowest set bit. Empty candidate set falls back to the lowest eligible
  // way, matching the reference second scan.
  logic [NR_WAYS-1:0] sel_fallback;
  assign sel_fallback = sel_valid_i & (~sel_valid_i + {{NR_WAYS-1{1'b0}}, 1'b1});
  assign sel_way_o = !sel_i ? '0
                   : (|cand_ways) ? (cand_ways & (~cand_ways + {{NR_WAYS-1{1'b0}}, 1'b1}))
                                  : sel_fallback;

  // Fill-set next RRPV, per way, before the "age everyone if nobody is
  // at MAX" step. Update-to-zero and the fill insert are both visible,
  // which is what the reference did by writing rrpv_d twice.
  logic [NR_WAYS-1:0][RRPV_BITS-1:0] fill_pre;
  logic fill_same_updt;
  assign fill_same_updt = updt_i && (updt_set_i == fill_set_i);
  assign use_brrip = DRRIP_EN && (fill_set_i != '0) &&
                     ((fill_set_i == SET_W'(1)) || psel_q[9]);
  for (genvar w = 0; w < NR_WAYS; w++) begin : gen_fill_pre
    always_comb begin
      fill_pre[w] = rrpv_q[fill_set_i][w];
      if (fill_same_updt && updt_way_i[w]) fill_pre[w] = '0;
      if (fill_i && fill_way_i[w])
        fill_pre[w] = use_brrip ? ((lfsr_q == '0) ? RRPV_LONG : RRPV_MAX)
                                : RRPV_LONG;
    end
  end
  always_comb begin
    any_max = 1'b0;
    for (int unsigned w = 0; w < NR_WAYS; w++)
      if (fill_pre[w] == RRPV_MAX) any_max = 1'b1;
  end

  // ----- Update / fill / age -----
  always_comb begin
    rrpv_d = rrpv_q;
    psel_d = psel_q;
    lfsr_d = lfsr_q;

    if (fill_i) lfsr_d = {lfsr_q[3:0], lfsr_q[4] ^ lfsr_q[2]};

    if (DRRIP_EN && fill_i) begin
      if (fill_set_i == '0) begin
        if (psel_q != '0) psel_d = psel_q - 10'd1;
      end else if (fill_set_i == SET_W'(1)) begin
        if (psel_q != 10'h3ff) psel_d = psel_q + 10'd1;
      end
    end

    if (updt_i && !fill_same_updt) begin
      for (int unsigned w = 0; w < NR_WAYS; w++)
        if (updt_way_i[w]) rrpv_d[updt_set_i][w] = '0;
    end

    if (fill_i || fill_same_updt) begin
      for (int unsigned w = 0; w < NR_WAYS; w++) begin
        if (fill_i && !any_max && (fill_pre[w] != RRPV_MAX))
          rrpv_d[fill_set_i][w] = fill_pre[w] + {{RRPV_BITS-1{1'b0}}, 1'b1};
        else
          rrpv_d[fill_set_i][w] = fill_pre[w];
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
