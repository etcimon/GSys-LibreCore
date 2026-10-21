// hyp8 provenance: REWRITTEN (new, group-10 trap partition of the csr_regfile split)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// csr_trap — CSR Exception Control and privilege-mode-dependent outputs
// of the original csr_regfile (the emit's exception_ctrl + priv_output
// blocks, verbatim) operating on the C1-registered request.
//
// csr_exception_o is consumed by commit_stage on the fire cycle — since
// the request is C1-registered, the access-exception / privilege flags
// and this mux all evaluate in the same cycle the commit decision sees
// them, so no stage is needed here (the serialized cut is C1).
// trap_vector_base_o / epc_o follow the same state taps as before; the
// MRET/SRET/DRET marks arrive on the registered request.

module csr_trap
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter type exception_t = logic
) (
    // legality flags evaluated on the C1-registered request (wrapper)
    input  logic                          update_access_exception_i,
    input  logic                          read_access_exception_i,
    input  logic                          privilege_violation_i,
    input  logic                          virtual_update_access_exception_i,
    input  logic                          virtual_read_access_exception_i,
    input  logic                          virtual_privilege_violation_i,
    // state taps (registered architectural state from the wrapper)
    input  logic [G6LCCfg.XLEN-1:0]       mtvec_i,
    input  logic [G6LCCfg.XLEN-1:0]       stvec_i,
    input  logic [G6LCCfg.XLEN-1:0]       vstvec_i,
    input  logic [G6LCCfg.XLEN-1:0]       mepc_i,
    input  logic [G6LCCfg.XLEN-1:0]       sepc_i,
    input  logic [G6LCCfg.XLEN-1:0]       vsepc_i,
    input  logic [G6LCCfg.XLEN-1:0]       dpc_i,
    input  logic                          debug_mode_i,
    input  logic                          v_i,
    // trap target computed by csr_update on the live exception (commit-timed)
    input  riscv::priv_lvl_t              trap_to_priv_lvl_i,
    input  logic                          trap_to_v_i,
    input  logic [G6LCCfg.XLEN-1:0]       ex_cause_i,
    // return marks from csr_read (C1 request ops)
    input  logic                          sret_i,
    input  logic                          dret_i,
    // outputs
    output exception_t                    csr_exception_o,
    output logic [G6LCCfg.VLEN-1:0]       trap_vector_base_o,
    output logic [G6LCCfg.VLEN-1:0]       epc_o
);

  // ----------------------
  // CSR Exception Control
  // ----------------------
  always_comb begin : exception_ctrl
    csr_exception_o = {
      {G6LCCfg.XLEN{1'b0}}, {G6LCCfg.XLEN{1'b0}}, {G6LCCfg.GPLEN{1'b0}}, {32{1'b0}}, 1'b0, 1'b0
    };
    // ----------------------------------
    // Illegal Access (decode exception)
    // ----------------------------------
    // we got an exception in one of the processes above
    // throw an illegal instruction exception
    if (update_access_exception_i || read_access_exception_i) begin
      csr_exception_o.cause = riscv::ILLEGAL_INSTR;
      // we don't set the tval field as this will be set by the commit stage
      // this spares the extra wiring from commit to CSR and back to commit
      csr_exception_o.valid = 1'b1;
    end

    if (privilege_violation_i) begin
      csr_exception_o.cause = riscv::ILLEGAL_INSTR;
      csr_exception_o.valid = 1'b1;
    end

    if (G6LCCfg.RVH && (virtual_update_access_exception_i || virtual_read_access_exception_i || virtual_privilege_violation_i)) begin
      csr_exception_o.cause = riscv::VIRTUAL_INSTRUCTION;
      csr_exception_o.valid = 1'b1;
    end
  end

  // output assignments dependent on privilege mode
  always_comb begin : priv_output
    trap_vector_base_o = {mtvec_i[G6LCCfg.VLEN-1:2], 2'b0};
    // output user mode stvec
    if (G6LCCfg.RVS && trap_to_priv_lvl_i == riscv::PRIV_LVL_S) begin
      trap_vector_base_o = (G6LCCfg.RVH && trap_to_v_i) ? {vstvec_i[G6LCCfg.VLEN-1:2], 2'b0} : {stvec_i[G6LCCfg.VLEN-1:2], 2'b0};
    end

    // if we are in debug mode jump to a specific address
    if (G6LCCfg.DebugEn && debug_mode_i) begin
      trap_vector_base_o = G6LCCfg.DmBaseAddress[G6LCCfg.VLEN-1:0] + G6LCCfg.ExceptionAddress[G6LCCfg.VLEN-1:0];
    end

    // check if we are in vectored mode, if yes then do BASE + 4 * cause we
    // are imposing an additional alignment-constraint of 64 * 4 bytes since
    // we want to spare the costly addition. Furthermore check to which
    // privilege level we are jumping and whether the vectored mode is
    // activated for _that_ privilege level.
    if (ex_cause_i[G6LCCfg.XLEN-1] &&
                ((((G6LCCfg.RVS || G6LCCfg.RVU) && trap_to_priv_lvl_i == riscv::PRIV_LVL_M && (!G6LCCfg.DirectVecOnly && mtvec_i[0])) || (!G6LCCfg.RVS && !G6LCCfg.RVU && (!G6LCCfg.DirectVecOnly && mtvec_i[0])))
               || (G6LCCfg.RVS && trap_to_priv_lvl_i == riscv::PRIV_LVL_S && !trap_to_v_i && stvec_i[0]))) begin
      trap_vector_base_o[7:2] = ex_cause_i[5:0];
    end
    if (ex_cause_i[G6LCCfg.XLEN-1] &&
                (G6LCCfg.RVH && trap_to_priv_lvl_i == riscv::PRIV_LVL_S && trap_to_v_i && vstvec_i[0])) begin
      trap_vector_base_o[7:2] = {ex_cause_i[5:2], 2'b01};
    end

    epc_o = mepc_i[G6LCCfg.VLEN-1:0];
    // we are returning from supervisor or virtual supervisor mode, so take the sepc register
    if (G6LCCfg.RVS) begin
      if (sret_i) begin
        epc_o = (G6LCCfg.RVH && v_i) ? vsepc_i[G6LCCfg.VLEN-1:0] : sepc_i[G6LCCfg.VLEN-1:0];
      end
    end
    // we are returning from debug mode, to take the dpc register
    if (G6LCCfg.DebugEn) begin
      if (dret_i) begin
        epc_o = dpc_i[G6LCCfg.VLEN-1:0];
      end
    end
  end

endmodule
