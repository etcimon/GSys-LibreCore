// hyp8 provenance: REWRITTEN (new, group-10 C3 stage of the csr_regfile split)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// csr_write — the registered side-effect request boundary. In the
// original csr_regfile the combinational csr_update block raised
// flush_o in the same cycle the write/side effect was decided. Under
// the C1-registered request the architectural write lands on the
// csr_update record at the same edge this output is captured, so
// flush_o is presented one cycle AFTER the write lands (H14: no side
// effect request is raised before the state it guards is updated).
// The controller's counted drain (group-10 T2) consumes this registered
// request; the +1 is absorbed by the drain count.

module csr_write
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty
) (
    input  logic                          clk_i,
    input  logic                          rst_ni,
    // comb flush request decided by csr_update (write side effects,
    // fence.i, satp change, MPRV, PMP change, eret/dret returns)
    input  logic                          flush_req_i,
    // pc of the applying CSR instruction (commit_instr.pc on the apply
    // cycle); captured with the request so the controller forms the
    // refetch pc from the CSR itself, not from the head presented one
    // cycle later (r59: the deferred flush used to resume at
    // next_head.pc + 4 and skipped one instruction after every flushing
    // CSR write -- OpenSBI's sbi_hart_switch_mode lost its mret).
    input  logic [G6LCCfg.VLEN-1:0]       flush_pc_i,
    output logic                          flush_o,
    // registered alongside flush_o: valid in the flush_o cycle
    output logic [G6LCCfg.VLEN-1:0]       flush_pc_o
);
  // svt-stage: begin C3

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      flush_o    <= 1'b0;
      flush_pc_o <= '0;
    end else begin
      flush_o <= flush_req_i;
      if (flush_req_i) flush_pc_o <= flush_pc_i;
    end
  end

  // svt-stage: end C3
  // svt-stage: class C3 value
endmodule
