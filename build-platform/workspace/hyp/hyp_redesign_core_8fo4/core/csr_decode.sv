// hyp8 provenance: REWRITTEN (new, group-10 C1 stage of the csr_regfile split)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// csr_decode — C1 of the staged CSR file: registers the commit-side CSR
// request {csr_op_i, csr_addr_i, csr_wdata_i} plus the committing
// instruction's trans_id and virtualization context, and produces the
// registered bank one-hot used by the read partition.
//
// Double-presentation suppression: under the group-6 two-phase commit
// handshake csr_op_o/csr_wdata_o are driven during BOTH the request
// cycle and the fire cycle (the head is held until commit_ack_i, which
// returns +1). Without suppression the C1 register would execute the
// same CSR request twice (once for each presented copy). The request is
// therefore qualified: a presented request identical to the one just
// captured (op/addr/wdata/trans_id, i.e. the still-held head) is
// suppressed so each architectural request executes exactly once. A new
// instruction reusing a trans_id index is never identical (different
// tid), and a contiguous run of identical copies collapses to one
// execution regardless of its length.
//
// Timing: the registered request surfaces the cycle after presentation;
// the read mux / RMW / write decode all run on this record, so
// csr_rdata_o / csr_exception_o are valid on the fire cycle — the
// serialized CSR rank-4 cut of cut_minimization.md.
//
// CsrReadStages==1: NOT reachable under the two-phase commit handshake
// (the request must be registered or the fire-cycle read has nothing to
// consume); guarded below like RenameStages==1 in g6lc_rename.

module csr_decode
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::Hyp8
) (
    input  logic                          clk_i,
    input  logic                          rst_ni,
    input  logic                          flush_i,
    // live commit-side request
    input  fu_op                          csr_op_i,
    input  logic [11:0]                   csr_addr_i,
    input  logic [G6LCCfg.XLEN-1:0]       csr_wdata_i,
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0] commit_tid_i,
    input  logic                          v_i,
    // registered request (C1)
    output fu_op                          req_op_o,
    output logic [11:0]                   req_addr_o,
    output logic [G6LCCfg.XLEN-1:0]       req_wdata_o,
    output logic [G6LCCfg.TRANS_ID_BITS-1:0] req_tid_o,
    output logic                          req_v_o,
    output logic                          req_valid_o,
    output logic                          req_rd_valid_o,
    output logic [11:0]                   req_bank_o
);
  // svt-stage: begin C1

  // read-producing ops (also the ops whose rdata commit_stage consumes)
  localparam int unsigned N_READ_OPS = 4;
  // the ops that carry architectural side effects through this file
  localparam int unsigned N_REQ_OPS  = 8;

  fu_op                       req_op_q;
  logic [11:0]                req_addr_q;
  logic [G6LCCfg.XLEN-1:0]    req_wdata_q;
  logic [G6LCCfg.TRANS_ID_BITS-1:0] req_tid_q;
  logic                       req_v_q;
  logic                       req_valid_q, req_rd_valid_q;
  logic [11:0]                req_bank_q, bank_sel_d;

  logic is_req, is_rd_req, same_req;

  assign is_req = csr_op_i inside {CSR_WRITE, CSR_SET, CSR_CLEAR, CSR_READ,
                                   MRET, SRET, DRET, WFI};
  assign is_rd_req = csr_op_i inside {CSR_WRITE, CSR_SET, CSR_CLEAR, CSR_READ};

  // the same request held for a second (or third) presentation cycle is
  // suppressed: identical op/addr/wdata AND the same committing trans_id.
  assign same_req = is_req && (csr_op_i    == req_op_q)
                          && (csr_addr_i   == req_addr_q)
                          && (csr_wdata_i  == req_wdata_q)
                          && (commit_tid_i == req_tid_q);

  // ~12-bank partition of the CSR address space for the read mux. The
  // one-hot is metadata for the staged read; legality stays in the
  // wrapper's privilege_check on the registered address.
  always_comb begin
    bank_sel_d = '0;
    unique casez (csr_addr_i)
      12'h00?: bank_sel_d[0]  = 1'b1;   // user FP / fflags frm fcsr
      12'h01?: bank_sel_d[1]  = 1'b1;   // supervisor trap/deleg/envcfg
      12'h02?: bank_sel_d[2]  = 1'b1;   // hypervisor trap/status
      12'h1??: bank_sel_d[2]  = 1'b1;   // supervisor + vs range
      12'h2??: bank_sel_d[3]  = 1'b1;   // hypervisor / vs range
      12'h30?: bank_sel_d[4]  = 1'b1;   // machine info/trap/envcfg
      12'h31?: bank_sel_d[5]  = 1'b1;   // machine trap setup/cont
      12'h32?: bank_sel_d[6]  = 1'b1;   // machine counters/inhibit
      12'h3A?: bank_sel_d[7]  = 1'b1;   // pmpcfg
      12'h3B?: bank_sel_d[8]  = 1'b1;   // pmpaddr low
      12'h3C?: bank_sel_d[8]  = 1'b1;   // pmpaddr
      12'h3D?: bank_sel_d[8]  = 1'b1;   // pmpaddr
      12'h3E?: bank_sel_d[8]  = 1'b1;   // pmpaddr high
      12'h7B?: bank_sel_d[9]  = 1'b1;   // debug
      12'hC??: bank_sel_d[10] = 1'b1;   // counters read-only
      12'hB??: bank_sel_d[10] = 1'b1;   // hpm counters
      default: bank_sel_d[11] = 1'b1;   // everything else / custom
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      req_op_q       <= ADD;   // CSR NOP
      req_addr_q     <= '0;
      req_wdata_q    <= '0;
      req_tid_q      <= '0;
      req_v_q        <= 1'b0;
      req_valid_q    <= 1'b0;
      req_rd_valid_q <= 1'b0;
      req_bank_q     <= '0;
    end else if (flush_i) begin
      req_op_q       <= ADD;
      req_valid_q    <= 1'b0;
      req_rd_valid_q <= 1'b0;
    end else begin
      req_op_q       <= csr_op_i;
      req_addr_q     <= csr_addr_i;
      req_wdata_q    <= csr_wdata_i;
      req_tid_q      <= commit_tid_i;
      req_v_q        <= v_i;
      req_valid_q    <= is_req && !same_req;
      req_rd_valid_q <= is_rd_req && !same_req;
      req_bank_q     <= bank_sel_d;
    end
  end

  // gated op: an invalid (suppressed/NOP) record presents ADD so every
  // downstream consumer sees an inert request exactly once per real op.
  assign req_op_o       = req_valid_q ? req_op_q : ADD;
  assign req_addr_o     = req_addr_q;
  assign req_wdata_o    = req_wdata_q;
  assign req_tid_o      = req_tid_q;
  assign req_v_o        = req_v_q;
  assign req_valid_o    = req_valid_q;
  assign req_rd_valid_o = req_rd_valid_q;
  assign req_bank_o     = req_bank_q;

  // pragma translate_off
  initial begin
    assert (HypCfg.CsrReadStages == 2) else
      // hyp8 bring-up: adjacent string literals are not legal SV; the
      // message is one literal (fenced for sim anyway).
      $fatal(1, "csr_decode: CsrReadStages==1 is not reachable under the "
                + "group-6 two-phase commit handshake — the request register "
                + "is the handshake's C1 stage.");
  end
  // pragma translate_on

  // svt-stage: end C1
  // svt-stage: class C1 value
endmodule
