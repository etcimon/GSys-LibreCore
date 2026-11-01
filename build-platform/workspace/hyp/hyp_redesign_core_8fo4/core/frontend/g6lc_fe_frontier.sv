// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Accepted instruction-stream successor for prediction-only restarts.
// Queue-owned CF metadata survives an override, so its predicted successor
// must survive too. NoCF advances by instruction length; unconsumed slots
// cannot move the frontier. The caller owns the hart bank and redirect state.
module g6lc_fe_frontier
  import g6lc_core_pkg::*;
#(
  parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty
) (
  input logic [G6LCCfg.VLEN-1:0] resume_pc_i,
  input logic [G6LCCfg.INSTR_PER_FETCH-1:0] consumed_i,
  input logic [G6LCCfg.INSTR_PER_FETCH-1:0][G6LCCfg.VLEN-1:0] addr_i,
  input logic [G6LCCfg.INSTR_PER_FETCH-1:0][31:0] instr_i,
  input cf_t [G6LCCfg.INSTR_PER_FETCH-1:0] cf_type_i,
  input logic [G6LCCfg.VLEN-1:0] predict_address_i,
  output logic [G6LCCfg.VLEN-1:0] resume_pc_o
);
  always_comb begin
    resume_pc_o = resume_pc_i;
    for (int unsigned i = 0; i < G6LCCfg.INSTR_PER_FETCH; i++) begin
      if (consumed_i[i]) begin
`ifndef G6LC_MUT_FE_FRONTIER_FALLTHROUGH
        if (cf_type_i[i] != NoCF)
          resume_pc_o = predict_address_i;
        else
`endif
          resume_pc_o = addr_i[i] +
              g6lc_fetch_pkg::pc_ilen(G6LCCfg, instr_i[i][15:0]);
      end
    end
  end
endmodule
