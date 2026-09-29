// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Bounded formal: FP writeback ownership at the fpu_wrap output seam
// (M4/T9g). The DUT is the LIVE `fpu_wrap` (core/fpu_wrap.sv) with OoOEn=1
// and the ring-8 transaction space (NR_SB_ENTRIES=8, TRANS_ID_BITS=3).
//
// `fpnew_top` is replaced by an anyseq stub (fpnew_top_anyseq.sv): its
// in_ready/out_valid/tag/result are coherent free variables, the maximally
// adversarial neighbour for the owner tables — a return may arrive for any
// transaction id, submitted or not, cancelled or reallocated. The property is
// the seam contract, so a fully free producer is sound and makes the owner
// compare load-bearing:
//
//   P1  fpu_valid_o asserted => the returning trans_id still owns its slot
//       (owner_live_q set), is not remembered-cancelled (owner_cancelled_q),
//       is not cancelled this cycle (cancelled_mask_i), and no flush is in
//       flight. This is the gate at fpu_wrap.sv:fpu_valid_o; a stale or
//       foreign return must never write the PRF / mark the entry complete.
//   P2  fpu_valid_o asserted => the tag was not cancelled while owned by the
//       FU (harness-owned cxl_q mirror — catches the S2 needle: dropping the
//       cancelled latch).
//   P3  A tag is never submitted twice live: an accepted input (in_valid &&
//       in_ready) only lands on a slot whose owner table is clear.
//   P4  A cancelled input (cancelled_mask_i asserted on the offered tag) is
//       never submitted to the FU.
//
// Mutation control (task mut_owner): G6LC_MUT_FP_NO_OWNER_LIVE drops the
// owner_live_q term from the fpu_valid_o gate — P1 must FAIL.
//
// Run: sby -f core/ooo/formal/g6lc_ooo_fp_owner.sby

module g6lc_ooo_fp_owner_props #(
    parameter int unsigned XLEN = 64,
    parameter int unsigned FLEN = 32,
    parameter int unsigned NSB  = 8,
    parameter int unsigned TW   = 3
) (
    input logic             clk_i,
    // Stimulus enters through ports so every use sees one coherent free value
    // per cycle; an undriven internal logic is split into independent free
    // variables by the slang frontend and the property cannot be trusted.
    input logic             flush_i,
    input logic [NSB-1:0]   cancelled_mask_i,
    input logic             fpu_valid_i,
    input logic [TW-1:0]    fpu_tid_i,
    input logic [3:0]       fpu_fu_i,
    input logic [6:0]       fpu_op_i,
    input logic [XLEN-1:0]  operand_a_i,
    input logic [XLEN-1:0]  operand_b_i,
    input logic [XLEN-1:0]  imm_i,
    input logic [1:0]       fpu_fmt_i,
    input logic [2:0]       fpu_rm_i,
    input logic [2:0]       fpu_frm_i,
    input logic [6:0]       fpu_prec_i
);

`ifdef FORMAL
  import ariane_pkg::*;

  function automatic config_pkg::cva6_cfg_t mk_cfg();
    config_pkg::cva6_cfg_t c;
    c                 = config_pkg::cva6_cfg_empty;
    c.XLEN            = XLEN;
    c.VLEN            = XLEN;
    c.PLEN            = 56;
    c.GPLEN           = XLEN;
    c.IS_XLEN64       = 1'b1;
    c.NrHarts         = 1;
    c.NrIssuePorts    = 2;
    c.NR_SB_ENTRIES   = NSB;
    c.TRANS_ID_BITS   = TW;
    c.FpPresent       = 1'b1;
    c.RVF             = 1'b1;
    c.RVD             = 1'b0;
    c.FLen            = FLEN;
    c.OoOEn           = 1'b1;
    c.SuperscalarEn   = 1'b1;
    return c;
  endfunction

  localparam config_pkg::cva6_cfg_t Cfg = mk_cfg();

  // Layout-identical to the fu_data_t the scoreboard hands the FU (the fields
  // fpu_wrap consumes: trans_id, fu, operation, operand_a, operand_b, imm).
  typedef struct packed {
    logic [TW-1:0]   trans_id;
    fu_t             fu;
    fu_op            operation;
    logic [XLEN-1:0] operand_a, operand_b, imm;
  } fu_typed_t;

  // Layout-identical to the exception_t localparam struct in core/cva6.sv.
  typedef struct packed {
    logic [XLEN-1:0] cause;
    logic [XLEN-1:0] tval;
    logic [XLEN-1:0] tval2;
    logic [31:0]     tinst;
    logic            gva;
    logic            valid;
  } exc_t;

  fu_typed_t fu_data_i;
  assign fu_data_i = '{trans_id: fpu_tid_i, fu: fu_t'(fpu_fu_i),
                      operation: fu_op'(fpu_op_i), operand_a: operand_a_i,
                      operand_b: operand_b_i, imm: imm_i};

  logic rst_init_q = 1'b1;
  logic rst_ni;
  always_ff @(posedge clk_i) rst_init_q <= 1'b0;
  assign rst_ni = ~rst_init_q;

  logic                        fpu_ready_o;
  logic [TW-1:0]               fpu_trans_id_o;
  logic [FLEN-1:0]             result_o;
  logic                        fpu_valid_o;
  exc_t                        fpu_exception_o;
  logic                        fpu_early_valid_o;

  fpu_wrap #(
      .CVA6Cfg      (Cfg),
      .exception_t  (exc_t),
      .fu_data_t    (fu_typed_t)
  ) dut (
      .clk_i,
      .rst_ni,
      .flush_i,
      .cancelled_mask_i,
      .fpu_valid_i,
      .fpu_ready_o,
      .fu_data_i,
      .fpu_fmt_i,
      .fpu_rm_i,
      .fpu_frm_i,
      .fpu_prec_i,
      .fpu_trans_id_o,
      .result_o,
      .fpu_valid_o,
      .fpu_exception_o,
      .fpu_early_valid_o
  );

  // --- seam aliases ----------------------------------------------------------
  wire        in_valid   = dut.fpu_gen.fpu_in_valid;
  wire        in_ready   = dut.fpu_gen.fpu_in_ready;
  wire [TW-1:0] in_tag    = dut.fpu_gen.fpu_tag;
  wire        out_valid  = dut.fpu_gen.fpu_out_valid;
  wire        out_ready  = dut.fpu_gen.fpu_out_ready;
  wire [TW-1:0] res_tag   = dut.fpu_gen.result_tag;
  wire [NSB-1:0] live_q   = dut.fpu_gen.owner_live_q;
  wire [NSB-1:0] cxled_q  = dut.fpu_gen.owner_cancelled_q;
  wire        accept = in_valid && in_ready;
  wire        consume = out_valid && out_ready;

  // --- harness model: tag cancelled while the FU owns it ---------------------
  // Set on accept with the mask cleared; set again if cancelled_mask_i fires
  // while the slot is live; cleared by the consume that frees the slot.
  // Mirrors the RTL owner's intent but is mutation-independent, so dropping
  // the cancelled latch in the DUT cannot hide the cancellation.
  logic [NSB-1:0] cxl_q;
  always_ff @(posedge clk_i) begin
    if (!rst_ni || flush_i) begin
      cxl_q <= '0;
    end else begin
      cxl_q <= (cxl_q | (cancelled_mask_i & live_q));
      if (consume) cxl_q[res_tag] <= 1'b0;
      if (accept)  cxl_q[in_tag]  <= 1'b0;
    end
  end

  // --- the properties --------------------------------------------------------
  // Indexed selects are hoisted into wires: slang lowers a variable bit index
  // inside a procedural assert condition to 1'x.
  wire live_hit   = live_q[res_tag];
  wire cxled_hit  = cxled_q[res_tag];
  wire mask_hit   = cancelled_mask_i[res_tag];
  wire cxl_hit    = cxl_q[res_tag];
  wire in_live    = live_q[in_tag];
  wire in_masked  = cancelled_mask_i[in_tag];
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      // P1: a completion/writeback lands only for a live, uncancelled,
      // unmasked owner with no flush in flight.
      if (fpu_valid_o) begin
        assert (!flush_i);
        assert (live_hit);
        assert (!cxled_hit);
        assert (!mask_hit);
        // P2: the tag was not cancelled while this FU owned it.
        assert (!cxl_hit);
      end
      // P3: no double ownership — an accepted submission only lands on a
      // slot whose owner table entry is clear.
      if (accept) begin
        assert (!in_live);
        // P4: a cancelled tag is never submitted to the FU.
        assert (!in_masked);
      end
    end
  end

  // --- witnesses -------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (rst_ni) begin
      // normal completion: accept then emit
      cover (accept);
      cover (fpu_valid_o);
      // stale suppression: a return for a cancelled owner is dropped at the
      // gate (the T5/S2 needle scenario)
      cover (out_valid && cxled_q[res_tag]);
      // realloc after consume: the same tag is owned twice across a window
      cover (accept && cxl_q == '0 && live_q != '0);
      // held input dropped by cancellation (STALL path)
      cover (dut.state_q);
      cover (dut.state_q && dut.fpu_gen.input_cancelled);
      // flush with an owner live
      cover (flush_i && live_q != '0);
    end
  end
`endif

endmodule
