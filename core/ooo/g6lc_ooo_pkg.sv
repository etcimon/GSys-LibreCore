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

  // Program-order key: circular trans_id distance from the oldest live slot.
  // Sound only while both operands are scoreboard-live; width is the config's
  // TRANS_ID_BITS so the modular subtraction wraps exactly like the scoreboard.
  function automatic logic ooo_age_older(input int unsigned width, input logic [31:0] a,
                                         input logic [31:0] b, input logic [31:0] cp);
    logic [31:0] mask;
    mask = (32'd1 << width) - 32'd1;
    return ((a - cp) & mask) < ((b - cp) & mask);
  endfunction

  function automatic logic [31:0] ooo_age_dist(input int unsigned width, input logic [31:0] a,
                                               input logic [31:0] cp);
    logic [31:0] mask;
    mask = (32'd1 << width) - 32'd1;
    return (a - cp) & mask;
  endfunction

  // Keep in lockstep with store_buffer.sv's DEPTH_SPEC: an LSQ store credit
  // reserves a speculative-queue slot, so g6lc_ooo_dispatch refuses a
  // configuration whose store queue outnumbers the slots it reserves. The
  // non-DeepSpec fallback is ariane_pkg::DEPTH_SPEC (=4), inlined as a literal
  // so this package does not import ariane_pkg.
  function automatic int unsigned ooo_spec_store_depth(input config_pkg::cva6_cfg_t cfg);
    int unsigned clamped;
    if (!cfg.DeepSpecEn) return 4;
    clamped = (cfg.MaxOutstandingStores < 4) ? 4 :
              (cfg.MaxOutstandingStores > 16) ? 16 : cfg.MaxOutstandingStores;
    if (clamped <= 4) return 4;
    if (clamped <= 8) return 8;
    return 16;
  endfunction

endpackage
