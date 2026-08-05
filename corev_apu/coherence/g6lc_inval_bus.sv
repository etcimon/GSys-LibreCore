// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U6.2 invalidation fan-out bus for 1..CVA6_MAX_CORES.
//
// Contention optimisations:
//   * Per-core shallow FIFO (CohInvalDepth) — producer never blocks on one slow core
//   * Source-excluded delivery (writer does not self-invalidate for WT store)
//   * RR drain across cores when multiple invs pending
//   * Line-coalesce: back-to-back same-line inv to same core merges
//   * NR_CORES==1: identity (accept and drop; no fan-out)

module g6lc_inval_bus
  import g6lc_coherence_pkg::*;
#(
    parameter int unsigned NR_CORES     = 1,
    parameter int unsigned DEPTH        = COH_DEFAULT_INVAL_DEPTH,
    parameter int unsigned LINE_BYTES   = COH_DEFAULT_LINE_BYTES
) (
    input  logic clk_i,
    input  logic rst_ni,
    // Producer (coherence hub)
    input  coh_inval_t                         inv_req_i,
    input  logic [NR_CORES-1:0]                inv_target_i,  // bitset of cores to hit
    output logic                               inv_ready_o,   // accepted this cycle
    // Per-core consumer ports (toward L1 inv adapter)
    output coh_inval_t [NR_CORES-1:0]          inv_core_o,
    input  logic       [NR_CORES-1:0]          inv_core_ready_i,
    // Observability
    output logic                               inv_drop_o,    // producer drop (all FIFOs full)
    output logic                               inv_coalesce_o
);

  localparam int unsigned NC    = (NR_CORES < 1) ? 1 : NR_CORES;
  localparam int unsigned DP    = (DEPTH < 1) ? 1 : DEPTH;
  localparam int unsigned PTR_W = (DP <= 1) ? 1 : $clog2(DP);

  if (NC <= 1) begin : gen_single
    // Single core: no remote inv needed; always ready, never emits
    assign inv_ready_o     = 1'b1;
    assign inv_core_o      = '{default: '0};
    assign inv_drop_o      = 1'b0;
    assign inv_coalesce_o  = 1'b0;
  end else begin : gen_multi

    coh_inval_t fifo_q[NC][DP];
    logic [PTR_W-1:0] head_q[NC], tail_q[NC];
    logic [PTR_W:0]   count_q[NC];  // 0..DP

    logic [NC-1:0] full, empty;
    logic          can_accept;
    logic          coalesce;

    for (genvar c = 0; c < NC; c++) begin : gen_status
      assign full[c]  = (count_q[c] == DP[PTR_W:0]);
      assign empty[c] = (count_q[c] == '0);
    end

    // Accept if every targeted non-empty-needed slot has room OR coalesce
    always_comb begin
      can_accept = 1'b1;
      coalesce   = 1'b0;
      if (inv_req_i.valid) begin
        for (int unsigned c = 0; c < NC; c++) begin
          if (inv_target_i[c]) begin
            // Coalesce with tail if same line
            if (!empty[c] &&
                fifo_q[c][(tail_q[c] == 0) ? PTR_W'(DP-1) : PTR_W'(int'(tail_q[c])-1)].line_addr
                  == inv_req_i.line_addr &&
                fifo_q[c][(tail_q[c] == 0) ? PTR_W'(DP-1) : PTR_W'(int'(tail_q[c])-1)].valid) begin
              coalesce = 1'b1;
            end else if (full[c]) begin
              can_accept = 1'b0;
            end
          end
        end
      end
    end

    assign inv_ready_o    = can_accept | coalesce;
    assign inv_drop_o     = inv_req_i.valid & ~inv_ready_o;
    assign inv_coalesce_o = inv_req_i.valid & coalesce & can_accept;

    // Push / pop
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        for (int unsigned c = 0; c < NC; c++) begin
          head_q[c]  <= '0;
          tail_q[c]  <= '0;
          count_q[c] <= '0;
          for (int unsigned d = 0; d < DP; d++) fifo_q[c][d] <= '0;
        end
      end else begin
        for (int unsigned c = 0; c < NC; c++) begin
          automatic logic do_push, do_pop;
          automatic logic [PTR_W-1:0] tail_m1;
          do_push = 1'b0;
          do_pop  = inv_core_ready_i[c] & ~empty[c];
          tail_m1 = (tail_q[c] == 0) ? PTR_W'(DP - 1) : PTR_W'(int'(tail_q[c]) - 1);

          if (inv_req_i.valid && inv_ready_o && inv_target_i[c]) begin
            if (!empty[c] && fifo_q[c][tail_m1].valid &&
                fifo_q[c][tail_m1].line_addr == inv_req_i.line_addr) begin
              // Coalesce: OR flags into tail entry
              fifo_q[c][tail_m1].dcache  <= fifo_q[c][tail_m1].dcache | inv_req_i.dcache;
              fifo_q[c][tail_m1].icache  <= fifo_q[c][tail_m1].icache | inv_req_i.icache;
              fifo_q[c][tail_m1].all_ways<= fifo_q[c][tail_m1].all_ways | inv_req_i.all_ways;
            end else if (!full[c]) begin
              do_push = 1'b1;
              fifo_q[c][tail_q[c]] <= inv_req_i;
              tail_q[c] <= PTR_W'((int'(tail_q[c]) + 1) % DP);
            end
          end

          if (do_pop) begin
            fifo_q[c][head_q[c]].valid <= 1'b0;
            head_q[c] <= PTR_W'((int'(head_q[c]) + 1) % DP);
          end

          unique case ({do_push, do_pop})
            2'b10: count_q[c] <= count_q[c] + 1'b1;
            2'b01: count_q[c] <= count_q[c] - 1'b1;
            default: ;
          endcase
        end
      end
    end

    // Present head to each core
    for (genvar c = 0; c < NC; c++) begin : gen_out
      assign inv_core_o[c] = empty[c] ? '0 : fifo_q[c][head_q[c]];
    end

  end

endmodule
