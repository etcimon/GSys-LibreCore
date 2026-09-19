// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// I14 / RC4 — execute identity is the issuing port, not a shared flop.
//
// A control-flow claim is at most one issue port per cycle. The same port
// supplies branch_unit's fu_data, PC, compressed bit, BP snapshot, hart,
// and flu trans_id. G1p (hold last CF PC), G1r (PC in operand_c) and G1u
// (pair only when SMT) are symptoms of sharing one_cycle_data / pc_o.
//
// SI (NrIssuePorts==1) const-folds to port 0. Timing: a port mux on the
// existing EX resolve cone. No sequential logic.

package g6lc_ex_id;
  import config_pkg::*;

  // Port 0 wins if it has a CF; else the highest later port. No CF → 0
  // (callers must still gate on |branch_valid).
  function automatic int unsigned cf_port(
      input int unsigned nports,
      input logic [7:0]  branch_valid
  );
    cf_port = 0;
    for (int unsigned p = 1; p < nports && p < 8; p++) begin
      if (branch_valid[p]) cf_port = p;
    end
    if (branch_valid[0]) cf_port = 0;
  endfunction

endpackage
