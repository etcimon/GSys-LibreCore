// hyp8 provenance: REWRITTEN (new, group-10 counter partition of the csr_regfile split)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// csr_counters — the cycle/instret increment terms of the original
// csr_regfile's csr_update block.
//
// hyp8 common-event retirement: the carry is resolved in the same cycle.
// Each low word is extended to 33 bits, the gated increment is added, and
// sum bit 32 selects between the current high word and an independent
// high+1 candidate. There is no carry register — a software write applies
// through the csr_apply defaults in csr_regfile, so no carry state can
// outlive it, and the +1 into the high word lands in the same cycle the
// low word overflows.
//
// instret: the enabled delta is the popcount of commit_ack_i (at most
// NrCommitPorts per cycle). cycle: +1. The value path stays two short
// adds and a mux; its timing requires remeasurement.
//
// clk_i/rst_ni are part of the module interface (registered on the
// instantiation seam) but no sequential state remains here.

module csr_counters
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty
) (
    input  logic                          clk_i,
    input  logic                          rst_ni,
    input  logic [63:0]                   cycle_i,
    input  logic [63:0]                   instret_i,
    input  logic [G6LCCfg.NrCommitPorts-1:0] commit_ack_i,
    input  logic                          ex_valid_i,
    input  logic                          debug_mode_i,
    input  logic [31:0]                   mcountinhibit_i,
    output logic [63:0]                   cycle_o,
    output logic [63:0]                   instret_o
);

  logic [31:0] instret_pop;
  logic        instret_en, cycle_en;
  logic [32:0] instret_sum, cycle_sum;
  logic [31:0] instret_hi1, cycle_hi1;

  // enabled deltas (emit's counter gating, same terms)
  assign instret_en = !ex_valid_i
                   && !(G6LCCfg.DebugEn && debug_mode_i)
                   && (!G6LCCfg.PerfCounterEn || !mcountinhibit_i[2]);
  assign cycle_en   = !(G6LCCfg.DebugEn && debug_mode_i)
                   && (!G6LCCfg.PerfCounterEn || !mcountinhibit_i[0]);

  always_comb begin
    instret_pop = '0;
    for (int i = 0; i < G6LCCfg.NrCommitPorts; i++)
      if (commit_ack_i[i]) instret_pop++;
  end

  // 33-bit low-half sums; bit 32 is the same-cycle carry
  // r74 (A120 late count off the adder): the retire count is 0..NrCommitPorts,
  // so every candidate low-half sum is a constant increment of the registered
  // counter computed in parallel; the popcount (and the enable) only select
  // one of them as a one-hot. Exact: exactly one k equals the gated count.
  logic [G6LCCfg.NrCommitPorts:0][32:0] instret_cand;
  logic [G6LCCfg.NrCommitPorts:0]       instret_sel;
  for (genvar k = 0; k <= G6LCCfg.NrCommitPorts; k++) begin : gen_instret_cand
    assign instret_cand[k] = {1'b0, instret_i[31:0]} + 33'(k);
    assign instret_sel[k]  = (k == 0) ? (!instret_en || instret_pop == 32'd0)
                                      : (instret_en && instret_pop == 32'(k));
  end
  always_comb begin
    instret_sum = '0;
    for (int unsigned k = 0; k <= G6LCCfg.NrCommitPorts; k++)
      instret_sum |= {33{instret_sel[k]}} & instret_cand[k];
  end
  assign cycle_sum   = {1'b0, cycle_i[31:0]} + {32'b0, cycle_en};

  // independent high+1 candidates
  assign instret_hi1 = instret_i[63:32] + 32'd1;
  assign cycle_hi1   = cycle_i[63:32] + 32'd1;

  assign instret_o = {(instret_sum[32] ? instret_hi1 : instret_i[63:32]),
                      instret_sum[31:0]};
  assign cycle_o   = {(cycle_sum[32] ? cycle_hi1 : cycle_i[63:32]),
                      cycle_sum[31:0]};

endmodule
