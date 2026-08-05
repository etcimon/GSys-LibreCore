// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U5 production full OoO package — sizing helpers and phase status.

package g6lc_ooo_pkg;

  // Phase status (documentation for agents; not synthesised).
  // U5.0 recovery hardening  — scoreboard younger-than-branch cancel (done)
  // U5.1 rename/PRF/RAT      — multi-port rename + PRF write-through + IRO cutover
  // U5.2 ROB                 — multi-WB complete-by-tid; dual free
  // U5.3 IQ/wakeup/select    — chain wakeup + dual age-ordered grant
  // U5.4 OoO LSQ + memdep    — live AGU + CAM/STL + store-set
  // U5.5 widen / formal      — remaining

  function automatic int unsigned ooo_prf_w(input int unsigned prf_entries);
    return (prf_entries <= 2) ? 1 : $clog2(prf_entries);
  endfunction

  function automatic int unsigned ooo_rob_w(input int unsigned rob_entries);
    return (rob_entries <= 2) ? 1 : $clog2(rob_entries);
  endfunction

endpackage
