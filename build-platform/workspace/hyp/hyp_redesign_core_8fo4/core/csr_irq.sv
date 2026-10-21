// hyp8 provenance: REWRITTEN (new, group-10 interrupt partition of the csr_regfile split)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// csr_irq — the irq_ctrl_o bundle of the original csr_regfile, formed on
// registered architectural state and presented one cycle registered.
// The pending-interrupt / global-enable terms are unchanged (mie/mip,
// sie, mideleg/hideleg, single-step and debug masks); only the fan-in to
// the output bundle is staged. irq_ctrl_o feeds the controller's
// interrupt request, which is itself a commit-side decision — +1 there
// is a documented drain-side latency, no semantics change.

module csr_irq
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter type irq_ctrl_t = logic
) (
    input  logic                          clk_i,
    input  logic                          rst_ni,
    // registered architectural state taps
    input  logic [G6LCCfg.XLEN-1:0]       mie_i,
    input  logic [G6LCCfg.XLEN-1:0]       mip_i,
    input  logic                          vsstatus_sie_i,
    input  logic                          mstatus_sie_i,
    input  logic                          mstatus_mie_i,
    input  logic [G6LCCfg.XLEN-1:0]       mideleg_i,
    input  logic [G6LCCfg.XLEN-1:0]       hideleg_i,
    input  logic                          debug_mode_i,
    input  logic                          dcsr_step_i,
    input  logic                          dcsr_stepie_i,
    input  riscv::priv_lvl_t              priv_lvl_i,
    input  logic                          v_i,
    output irq_ctrl_t                     irq_ctrl_o
);

  irq_ctrl_t irq_ctrl_d;

  always_comb begin
    irq_ctrl_d.mie      = mie_i;
    irq_ctrl_d.mip      = mip_i;
    irq_ctrl_d.sie      = (G6LCCfg.RVH && v_i) ? vsstatus_sie_i : mstatus_sie_i;
    irq_ctrl_d.mideleg  = (G6LCCfg.RVS) ? mideleg_i : '0;
    irq_ctrl_d.hideleg  = (G6LCCfg.RVH) ? hideleg_i : '0;
    irq_ctrl_d.global_enable = ~(G6LCCfg.DebugEn & debug_mode_i)
        // interrupts are enabled during single step or we are not stepping
        // No need to check interrupts during single step if we don't support DEBUG mode
        & (~G6LCCfg.DebugEn | (~dcsr_step_i | dcsr_stepie_i))
        & ((mstatus_mie_i & (priv_lvl_i == riscv::PRIV_LVL_M))
           | (G6LCCfg.RVU & priv_lvl_i != riscv::PRIV_LVL_M));
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      irq_ctrl_o <= '0;
    end else begin
      irq_ctrl_o <= irq_ctrl_d;
    end
  end

endmodule
