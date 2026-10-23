// hyp8 provenance: REWRITTEN (new, group-10 C1 stage of the csr_regfile split)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// csr_decode — C1 of the staged CSR file: an explicitly OCCUPIED request
// record for the commit-side CSR request {csr_op_i, csr_addr_i,
// csr_wdata_i, commit_tid_i, v_i}, plus the registered bank one-hot used
// by the read partition.
//
// Occupancy contract: once a request is captured it is retained whole —
// op, address, write data, trans_id, virtual context and bank one-hot do
// not change while the record is held. consume_i (the csr_apply
// retirement event) or flush_i frees it; a new request is accepted only
// into an EMPTY record, so a still-present old request can never
// re-capture itself on its own consume edge and double-presentation
// suppression is unnecessary: the second presented copy of a held
// request simply finds the record occupied. A new instruction arrives
// only after the slot advanced, i.e. after the record was freed.
//
// Completion identity is req_valid for the whole CSR class (CSR read/
// write/set/clear, MRET/SRET/DRET/WFI, SFENCE/HFENCE, FENCE/FENCE.I);
// req_rd_valid additionally distinguishes the four read-producing ops
// whose data commit_stage consumes.
//
// CsrReadStages==1 presents the live request combinationally (the
// wrapper's apply event consumes it in the same cycle); ==2 uses the
// occupied register above. Other values are rejected at elaboration.
//
// CsrReadStages==1: combinational request path. CsrReadStages==2: the
// held register described above.

module csr_decode
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::Hyp8
) (
    input  logic                          clk_i,
    input  logic                          rst_ni,
    input  logic                          flush_i,
    // retirement apply event: frees the occupied record
    input  logic                          consume_i,
    // live commit-side request
    input  fu_op                          csr_op_i,
    input  logic [11:0]                   csr_addr_i,
    input  logic [G6LCCfg.XLEN-1:0]       csr_wdata_i,
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0] commit_tid_i,
    input  logic                          v_i,
    // staged request
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

  // read-producing ops (the ops whose rdata commit_stage consumes)
  localparam int unsigned N_READ_OPS = 4;
  // every CSR-class op that carries an architectural effect through this
  // file: ordinary CSR RMW + system/fence/privilege-return operations
  localparam int unsigned N_REQ_OPS  = 13;

  logic is_req, is_rd_req;

  assign is_req = csr_op_i inside {CSR_WRITE, CSR_SET, CSR_CLEAR, CSR_READ,
                                   MRET, SRET, DRET, WFI,
                                   SFENCE_VMA, HFENCE_VVMA, HFENCE_GVMA,
                                   FENCE, FENCE_I};
  assign is_rd_req = csr_op_i inside {CSR_WRITE, CSR_SET, CSR_CLEAR, CSR_READ};

  // ~12-bank partition of the CSR address space for the read mux. The
  // one-hot is metadata for the staged read; legality stays in the
  // wrapper's privilege_check on the request address.
  logic [11:0] bank_sel_d;
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

  if (HypCfg.CsrReadStages == 1) begin : gen_comb_req
    // one-stage profile: the live presentation IS the request; the
    // wrapper's apply event consumes it in the same cycle.
    assign req_op_o       = is_req ? csr_op_i : ADD;
    assign req_addr_o     = csr_addr_i;
    assign req_wdata_o    = csr_wdata_i;
    assign req_tid_o      = commit_tid_i;
    assign req_v_o        = v_i;
    assign req_valid_o    = is_req;
    assign req_rd_valid_o = is_rd_req;
    assign req_bank_o     = bank_sel_d;
    // no sequential request state in this profile
    logic unused_sigs;
    assign unused_sigs = consume_i & clk_i & rst_ni;
  end else begin : gen_reg_req
    // Occupied two-stage record: retain every captured field while the
    // request is held; consume or flush frees it. A request is accepted
    // only into an empty record — the old request is still occupied on
    // its own consume edge, so nothing can replace it in place.
    fu_op                       req_op_q;
    logic [11:0]                req_addr_q;
    logic [G6LCCfg.XLEN-1:0]    req_wdata_q;
    logic [G6LCCfg.TRANS_ID_BITS-1:0] req_tid_q;
    logic                       req_v_q;
    logic                       req_valid_q, req_rd_valid_q;
    logic [11:0]                req_bank_q;

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
      end else if (consume_i) begin
        req_valid_q    <= 1'b0;
        req_rd_valid_q <= 1'b0;
      end else if (!req_valid_q && is_req) begin
        req_op_q       <= csr_op_i;
        req_addr_q     <= csr_addr_i;
        req_wdata_q    <= csr_wdata_i;
        req_tid_q      <= commit_tid_i;
        req_v_q        <= v_i;
        req_valid_q    <= 1'b1;
        req_rd_valid_q <= is_rd_req;
        req_bank_q     <= bank_sel_d;
      end
      // occupied or no request: hold the record unchanged
    end

    // gated op: an empty record presents ADD so every downstream
    // consumer sees an inert request.
    assign req_op_o       = req_valid_q ? req_op_q : ADD;
    assign req_addr_o     = req_addr_q;
    assign req_wdata_o    = req_wdata_q;
    assign req_tid_o      = req_tid_q;
    assign req_v_o        = req_v_q;
    assign req_valid_o    = req_valid_q;
    assign req_rd_valid_o = req_rd_valid_q;
    assign req_bank_o     = req_bank_q;
  end

  // pragma translate_off
  initial begin
    assert (HypCfg.CsrReadStages inside {1, 2}) else
      $fatal(1, "csr_decode: CsrReadStages must be 1 (combinational request) "
                + "or 2 (occupied request register)");
  end
  // pragma translate_on

  // svt-stage: end C1
  // svt-stage: class C1 value
endmodule
