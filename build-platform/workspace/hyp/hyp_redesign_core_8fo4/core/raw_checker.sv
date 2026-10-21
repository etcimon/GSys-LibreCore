// hyp8 provenance: ADAPTED (sv-timing emit at the 8-FO4 budget)
// SPDX-FileCopyrightText: machine-generated
// Copyright 2024 Thales DIS France SAS
//
// Licensed under the Solderpad Hardware Licence, Version 0.51 (the "License");
// you may not use this file except in compliance with the License.
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
// You may obtain a copy of the License at https://solderpad.org/licenses/
//
// Original Author: Junheng Zheng - Thales
// U6.1: hart-qualified RAW for fine-grain SMT (Etienne Cimon, 2026)

module raw_checker
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Register source of the instruction to check RAW dependencies - SCOREBOARD
    input logic [REG_ADDR_SIZE-1:0] rs_i,
    // Type of register source (FPR or GPR) - SCOREBOARD
    input logic rs_fpr_i,
    // Registers of destination of the instructions already issued in the scoreboard - SCOREBOARD
    input logic [G6LCCfg.NR_SB_ENTRIES-1:0][REG_ADDR_SIZE-1:0] rd_i,
    // Type of registers of destination (FPR or GPR) - SCOREBOARD
    input logic [G6LCCfg.NR_SB_ENTRIES-1:0] rd_fpr_i,
    // Instructions in the scoreboard are still issued - SCOREBOARD
    input logic [G6LCCfg.NR_SB_ENTRIES-1:0] still_issued_i,
    // Issue pointer - SCOREBOARD
    input logic [G6LCCfg.TRANS_ID_BITS-1:0] issue_pointer_i,
    // U6.1 SMT hart of consumer (issuing) and producers (SB entries)
    input logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] rs_hart_i,
    input logic [G6LCCfg.NR_SB_ENTRIES-1:0][$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] rd_hart_i,

    // Index in the scoreboard of the most recent RAW dependency - SCOREBOARD
    output logic [G6LCCfg.TRANS_ID_BITS-1:0] idx_o,
    // Indicates if there is a RAW dependency - SCOREBOARD
    output logic valid_o
);

  logic [G6LCCfg.NR_SB_ENTRIES-1:0] same_rd_as_rs;

  logic [G6LCCfg.NR_SB_ENTRIES-1:0] same_rd_as_rs_before;
  logic [G6LCCfg.TRANS_ID_BITS-1:0] last_before_idx;

  logic [G6LCCfg.NR_SB_ENTRIES-1:0] same_rd_as_rs_after;
  logic [G6LCCfg.TRANS_ID_BITS-1:0] last_after_idx;

  logic                             rs_is_gpr0;

  for (genvar i = 0; i < G6LCCfg.NR_SB_ENTRIES; i++) begin : gen_same_rd
    // NrHarts==1: always same hart. Else require matching SMT bank so peer
    // and primary never stall/forward on each other's architectural regs.
    logic same_hart;
    assign same_hart = (G6LCCfg.NrHarts <= 1) || (rd_hart_i[i] == rs_hart_i);
    assign same_rd_as_rs[i] =
        same_hart && (rs_fpr_i == rd_fpr_i[i]) && (rs_i == rd_i[i]) && still_issued_i[i];
    // Last SB index compared with a TRANS_ID_BITS pointer is range-constant
    // (i_max < ptr is never, i_max >= ptr is always). Split it out so Verilator
    // does not CMPCONST the tautology; mid indices keep the live compare.
    if (i == G6LCCfg.NR_SB_ENTRIES - 1) begin : gen_last
      assign same_rd_as_rs_before[i] = 1'b0;
      assign same_rd_as_rs_after[i]  = same_rd_as_rs[i];
    end else begin : gen_mid
      assign same_rd_as_rs_before[i] =
          (G6LCCfg.TRANS_ID_BITS'(i) < issue_pointer_i) && same_rd_as_rs[i];
      assign same_rd_as_rs_after[i] =
          (G6LCCfg.TRANS_ID_BITS'(i) >= issue_pointer_i) && same_rd_as_rs[i];
    end
  end

  // hyp8: the NR_SB-wide register compare is registered (+1 on idx_o/valid_o,
  // rank 2). The last-match priority select and the gpr0 suppression stay
  // combinational on the registered compare vector.
  logic [G6LCCfg.NR_SB_ENTRIES-1:0] same_rd_as_rs_before_q, same_rd_as_rs_after_q;
  logic [G6LCCfg.NR_SB_ENTRIES-1:0] same_rd_as_rs_q;
  logic                             rs_is_gpr0_q;

  always_comb begin
    last_before_idx = '0;
    last_after_idx  = '0;

    for (int unsigned i = 0; i < G6LCCfg.NR_SB_ENTRIES; i++) begin
      if (same_rd_as_rs_before_q[i]) begin
        last_before_idx = G6LCCfg.TRANS_ID_BITS'(i);
      end
      if (same_rd_as_rs_after_q[i]) begin
        last_after_idx = G6LCCfg.TRANS_ID_BITS'(i);
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_raw_cmp
    if (~rst_ni) begin
      same_rd_as_rs_q        <= '0;
      same_rd_as_rs_before_q <= '0;
      same_rd_as_rs_after_q  <= '0;
      rs_is_gpr0_q           <= 1'b0;
    end else begin
      same_rd_as_rs_q        <= same_rd_as_rs;
      same_rd_as_rs_before_q <= same_rd_as_rs_before;
      same_rd_as_rs_after_q  <= same_rd_as_rs_after;
      rs_is_gpr0_q           <= rs_is_gpr0;
    end
  end

  assign idx_o = |same_rd_as_rs_before_q ? last_before_idx : last_after_idx;

  assign rs_is_gpr0 = (rs_i == '0) && !rs_fpr_i;
  assign valid_o = |same_rd_as_rs_q && !rs_is_gpr0_q;

endmodule
