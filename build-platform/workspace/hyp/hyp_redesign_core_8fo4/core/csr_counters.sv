// hyp8 provenance: REWRITTEN (new, group-10 counter partition of the csr_regfile split)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// csr_counters — the cycle/instret increment terms of the original
// csr_regfile's csr_update block, with the 64-bit ripple split into a
// low-half increment plus a registered carry into the high half (the
// serialized value-path cut, rank 4 — same pattern as perf_counters).
//
// instret: the commit-ack popcount sums into the low word; a registered
// carry chain folds the popcount + low-half carry into the high word.
// cycle: +1 split the same way. The low-half sums are small (32-bit add
// plus a 1..NrCommitPorts-wide count), keeping the value path under the
// 8-FO4 board.

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

  logic [63:0] instret_inc, cycle_inc;
  logic        instret_carry_q, cycle_carry_q;
  logic [31:0] instret_pop;
  logic        instret_low_ovf;

  // low-half increment inputs (emit's counters section, verbatim intent)
  always_comb begin
    instret_pop = '0;
    instret_inc = instret_i;
    cycle_inc   = cycle_i;
    if (!(G6LCCfg.DebugEn && debug_mode_i)) begin
      for (int i = 0; i < G6LCCfg.NrCommitPorts; i++) begin
        if (commit_ack_i[i] && !ex_valid_i && (!G6LCCfg.PerfCounterEn || (G6LCCfg.PerfCounterEn && !mcountinhibit_i[2])))
          instret_pop++;
      end
    end
  end

  assign instret_low_ovf = (instret_i[31:0] + instret_pop) < instret_i[31:0];

  // registered carries: the high word gets +carry one cycle later than
  // the low word would have overflowed it. Since instret increments are
  // small (< NrCommitPorts per cycle), a carry can occur at most once
  // every 2^32 commits — the single registered carry bit is sufficient.
  // (hyp8: same convention as the counters split in perf_counters.)
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      instret_carry_q <= 1'b0;
      cycle_carry_q   <= 1'b0;
    end else begin
      instret_carry_q <= instret_low_ovf
        && !(G6LCCfg.DebugEn && debug_mode_i)
        && (!G6LCCfg.PerfCounterEn || (G6LCCfg.PerfCounterEn && !mcountinhibit_i[2]));
      cycle_carry_q   <= (cycle_i[31:0] == 32'hFFFF_FFFF)
        && !(G6LCCfg.DebugEn && debug_mode_i)
        && (!G6LCCfg.PerfCounterEn || (G6LCCfg.PerfCounterEn && !mcountinhibit_i[0]));
    end
  end

  always_comb begin
    instret_o[31:0]  = instret_i[31:0] + instret_pop;
    instret_o[63:32] = instret_i[63:32] + {31'b0, instret_carry_q};
    cycle_o[31:0]    = ((G6LCCfg.DebugEn && debug_mode_i)
                       || (G6LCCfg.PerfCounterEn && mcountinhibit_i[0]))
                       ? cycle_i[31:0] : cycle_i[31:0] + 1'b1;
    cycle_o[63:32]   = cycle_i[63:32] + {31'b0, cycle_carry_q};
    // debug-mode / inhibit freeze keeps the emit's else-branch values
    if ((G6LCCfg.DebugEn && debug_mode_i)) begin
      instret_o = instret_i;
      cycle_o   = cycle_i;
    end
  end

endmodule
