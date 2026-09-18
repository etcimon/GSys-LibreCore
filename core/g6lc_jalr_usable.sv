// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Soft-ladder EXTRACT E2 — I4t/I4v JALR target is usable fetch.
// E2+: G1gs/G1hf/G1hg mid-line JumpR resolve (bit-identical).
//
// Bit-identical: above page 0 (bits [VLEN-1:12] nonzero) AND inside execute
// PMA. Callers still gate with NrHarts>1. Used at branch_unit resolve,
// frontend is_mispredict / NPC reseed / BTB train, scoreboard bmiss.
//
// G1he all mid-line CTRL_FLOW JumpR — MINI-FAIL. Do not re-land.
// G1ig leftover-PC Branch JumpR — MINI-FAIL. Do not re-land.
//
// Timing: same compares already on the resolve cone. No sequential logic.

package g6lc_jalr_usable;
  import config_pkg::*;

  // Match |target[VLEN-1:12] without a variable part-select.
  function automatic logic above_page0(
      input int unsigned vlen,
      input logic [63:0] target
  );
    logic [63:0] hi;
    hi = target >> 12;
    if (vlen < 64) begin
      hi = hi & ((64'(1) << (vlen - 12)) - 64'(1));
    end
    above_page0 = |hi;
  endfunction

  function automatic logic usable(
      input cva6_cfg_t cfg,
      input int unsigned vlen,
      input logic [63:0] target
  );
    usable = above_page0(vlen, target) &&
             is_inside_execute_regions(cfg, target);
  endfunction

  function automatic logic smt_ss(input cva6_cfg_t cfg);
    smt_ss = cfg.SuperscalarEn && (cfg.NrHarts > 1);
  endfunction

  // Prefer operand_a if usable, else operand_b.
  function automatic logic [63:0] pick_usable(
      input cva6_cfg_t cfg,
      input int unsigned vlen,
      input logic [63:0] op_a,
      input logic [63:0] op_b
  );
    logic [63:0] t;
    t = op_a;
    if (!usable(cfg, vlen, t) && usable(cfg, vlen, op_b)) t = op_b;
    pick_usable = t;
  endfunction

  // G1gs: JALR resolve is JumpR even if RAS tagged Return.
  function automatic logic jalr_cf_jumpr(
      input cva6_cfg_t cfg,
      input logic is_jalr
  );
    jalr_cf_jumpr = smt_ss(cfg) && is_jalr;
  endfunction

  // G1hf: mid-line 01, not a Branch, usable RF target → JumpR.
  function automatic logic mid_nbranch(
      input cva6_cfg_t cfg,
      input logic pc01,
      input logic is_branch
  );
    mid_nbranch = smt_ss(cfg) && pc01 && !is_branch;
  endfunction

  // G1hg: mid-line 01 Branch whose orig 16-bit is exact c.jalr.
  function automatic logic mid_cjalr_branch(
      input cva6_cfg_t cfg,
      input logic pc01,
      input logic is_branch,
      input logic [15:0] orig16
  );
    mid_cjalr_branch = smt_ss(cfg) && pc01 && is_branch &&
                       g6lc_rvc_enc::is_cjalr16(orig16);
  endfunction

endpackage
