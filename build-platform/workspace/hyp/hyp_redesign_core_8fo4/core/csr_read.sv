// hyp8 provenance: REWRITTEN (new, group-10 C2 stage of the csr_regfile split)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// csr_read — C2 of the staged CSR file: the CSR OP select logic of the
// original csr_regfile (the emit's csr_op_logic block, verbatim) driven by
// the C1-registered request, plus the RMW operand preparation
// (CSR_SET/CLEAR read-modify-write against this cycle's comb rdata) and
// the registered read-response valid.
//
// The bank-local read mux itself stays in csr_regfile (the wrapper owns
// architectural state; the single case is already behind the C1 request
// register, which is the serialized timing cut — the per-bank split would
// buy wiring locality, not budget; recorded deviation in decisions.md).
//
// rdata validity: the request is registered in C1, so the comb read mux
// and this RMW both evaluate during the fire cycle — csr_rdata_o and
// csr_exception_o are live exactly when commit_stage consumes them.
// rdata_valid_o is the C1 read-request flag (one cycle after
// presentation), exported for the commit-stage handshake check.

module csr_read
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty
) (
    // C1-registered request
    input  fu_op                       req_op_i,
    input  logic [G6LCCfg.XLEN-1:0]    req_wdata_i,
    input  logic                       req_valid_i,
    input  logic                       req_rd_valid_i,
    // comb read-mux output from the wrapper (this cycle's architectural read)
    input  logic [G6LCCfg.XLEN-1:0]    rdata_i,
    // legality verdict on the registered request (wrapper privilege_check)
    input  logic                       privilege_violation_i,
    // op-select results (emit's csr_op_logic, verbatim)
    output logic [G6LCCfg.XLEN-1:0]    csr_wdata_o,
    output logic                       csr_we_o,
    output logic                       csr_rd_en_o,
    output logic                       mret_o,
    output logic                       sret_o,
    output logic                       dret_o,
    // read-response handshake for commit_stage
    output logic                       rdata_valid_o
);
  // svt-stage: begin C2

  always_comb begin : csr_op_logic
    csr_wdata_o  = req_wdata_i;
    csr_we_o     = 1'b1;
    csr_rd_en_o  = 1'b1;
    mret_o       = 1'b0;
    sret_o       = 1'b0;
    dret_o       = 1'b0;

    unique case (req_op_i)
      CSR_WRITE: csr_wdata_o = req_wdata_i;
      CSR_SET:   csr_wdata_o = req_wdata_i | rdata_i;
      CSR_CLEAR: csr_wdata_o = (~req_wdata_i) & rdata_i;
      CSR_READ:  csr_we_o = 1'b0;
      MRET: begin
        // the return should not have any write or read side-effects
        csr_we_o    = 1'b0;
        csr_rd_en_o = 1'b0;
        mret_o      = 1'b1;  // signal a return from machine mode
      end
      default: begin
        if (G6LCCfg.RVS && req_op_i == SRET) begin
          // the return should not have any write or read side-effects
          csr_we_o    = 1'b0;
          csr_rd_en_o = 1'b0;
          sret_o      = 1'b1;  // signal a return from supervisor mode
        end else if (G6LCCfg.DebugEn && req_op_i == DRET) begin
          // the return should not have any write or read side-effects
          csr_we_o    = 1'b0;
          csr_rd_en_o = 1'b0;
          dret_o      = 1'b1;  // signal a return from debug mode
        end else begin
          csr_we_o    = 1'b0;
          csr_rd_en_o = 1'b0;
        end
      end
    endcase
    // if we are violating our privilges do not update the architectural state
    if (privilege_violation_i) begin
      csr_we_o    = 1'b0;
      csr_rd_en_o = 1'b0;
    end
  end

  // the C1 record is the handshake: a read request presented last cycle
  // has its rdata live this (fire) cycle.
  assign rdata_valid_o = req_rd_valid_i;

  // svt-stage: end C2
  // svt-stage: class C2 value
endmodule
