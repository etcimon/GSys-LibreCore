// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_ctx_barrier -- hyp8 context barrier at dispatch (rfix131a-02).
//
// A CSR-class instruction (fu == CSR: CSR access, xRET, ECALL/EBREAK, WFI,
// the fences) is the only kind that changes the privilege / translation
// context, and it changes it when it commits. The rule this module states
// once, for every dispatch lane:
//
//   no instruction enters the out-of-order window behind a CSR-class
//   instruction that has not committed.
//
// Lanes arrive in program order. While a CSR-class instruction is in flight
// (hold_i, from csr_buffer) no lane is kept; otherwise lanes are kept up to
// and including the first CSR-class lane, which is therefore the last lane
// of its group. A lane that is not kept is simply not shown to rename and
// not acknowledged; the scoreboard presents it again.
//
// Consequence: a load, a page-table walk or a fetch never runs under a
// context that an older in-flight instruction is about to replace, so the
// consumers need no ownership / foreign-result special cases for it.
//
// Purely combinational, no state. Timing: one NP-wide prefix AND over
// registered lane records (NP = 2 scalar, 8 multi-core).

module g6lc_ctx_barrier #(
    parameter int unsigned NrLanes = 2
) (
    // a CSR-class instruction is in flight (dispatch .. commit + 1)
    input  logic               hold_i,
    // lane carries a valid instruction, program order (lane 0 oldest)
    input  logic [NrLanes-1:0] lane_valid_i,
    // lane's instruction is CSR-class (qualified by lane_valid_i here)
    input  logic [NrLanes-1:0] lane_csr_i,
    // lane may be dispatched this cycle
    output logic [NrLanes-1:0] keep_o
);

  logic [NrLanes-1:0] csr_lane;
  assign csr_lane = lane_valid_i & lane_csr_i;

  for (genvar p = 0; p < NrLanes; p++) begin : gen_keep
    if (p == 0) begin : gen_first
      assign keep_o[p] = !hold_i;
    end else begin : gen_rest
      assign keep_o[p] = keep_o[p-1] && !csr_lane[p-1];
    end
  end

endmodule
