// hyp8 provenance: NEW (r42-T R1 — slice-accumulate CLMUL pipeline)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// mult_clmul — carry-less multiply folded across the multiplier's S2-S7
// edges. The pre-r42 form computed the full 64x64 carry-less product in
// the operand cycle (64 AND rows + six XOR levels, the multiplier's worst
// in->reg cone) and shifted the finished value through seven stages of
// clm_sq/clmr_sq. Here instead each stage XORs the next 8-bit slice
// product into a pipeline register: stage k forms
//     XOR_j ( b_i[8s+j] ? (a_i << (8s+j)) : 0 )
// for its slice(s) s of b_i — an eight-term XOR tree (three levels) in
// series with one accumulate XOR. Six edges cover eight slices, so the
// first two stages fold two slices each (sixteen-term, four levels +
// accumulate). The accumulated 2*XLEN product equals the old tree's value
// at the same S7 edge (translate_off equivalence in multiplier.sv).
//
// The operands travel with the token (PL-P1): a_q[s] carries a and
// b_rem_*_q carries only the not-yet-consumed b slices (48 bits after
// S2, then 32/24/16/8) — 5*XLEN + 128 = 448 added operand flops, still
// below the retired 7*2*XLEN = 896-flop clm/clmr shift chains. The S2
// stage may read a_i/b_i directly because they are the S1 registers of
// the token entering S2. (Lead review: an early draft folded the LIVE
// operands at every stage, which silently mixed instructions under
// back-to-back multiplies; deferred validation would not have caught
// it until the witness — RT-H1.)
//
// svt-pipe: protocol cl valid=vld_q[0] id=tid_q[0] flush=flush_i
// svt-pipe: cycle cl q=acc_q d=acc_d hold=1'b0 steps=1
//
// Ownership: valid/tid/op cross every edge with the data (the A126 merge
// rule); kill/flush is owned upstream by mult.sv's cancellation-liveness
// pipe (a killed token still walks the pipe but is suppressed at the
// publish mux), so flush_i only clears this module's record track.

module mult_clmul
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t       G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg  = g6lc_hyp_pkg::HypDefault
) (
    // Subsystem Clock - SUBSYSTEM
    input  logic                             clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input  logic                             rst_ni,
    // Flush (clears the record track; data regs are don't-care) - CTRL
    input  logic                             flush_i,
    // New operation captured this edge - Mult
    input  logic                             valid_i,
    input  logic [G6LCCfg.TRANS_ID_BITS-1:0] trans_id_i,
    input  fu_op                             operation_i,
    // Registered S1 operands (already bit-reversed for CLMULR/CLMULH) - Mult
    input  logic [G6LCCfg.XLEN-1:0]          a_i,
    input  logic [G6LCCfg.XLEN-1:0]          b_i,
    // Carry-less products, valid six edges after valid_i - Mult
    output logic [G6LCCfg.XLEN-1:0]          clmul_o,
    output logic [G6LCCfg.XLEN-1:0]          clmulr_o,
    output logic                             valid_o,
    output logic [G6LCCfg.TRANS_ID_BITS-1:0] trans_id_o,
    output fu_op                             operation_o
);

  localparam int unsigned XW  = G6LCCfg.XLEN;
  localparam int unsigned PW  = 2 * XW;            // 128-bit product field
  localparam int unsigned SL  = 8;                 // bits per b_i slice
  localparam int unsigned NST = 6;                 // S2..S7 edges

  // Slice k of the carry-less product: XOR_j b_i[8k+j] ? (a_i << (8k+j)).
  function automatic logic [PW-1:0] slice_prod(
      input logic [XW-1:0] a, input logic [7:0] bs, input int unsigned s);
    logic [PW-1:0] acc;
    acc = '0;
    for (int unsigned j = 0; j < SL; j++)
      acc ^= bs[j] ? (PW'(a) << (SL * s + j)) : '0;
    return acc;
  endfunction

  // Slice schedule over the six edges: {0,1} on S2, {2,3} on S3, then one
  // slice each on S4..S7 — every stage folds at most a sixteen-term XOR
  // tree plus one accumulate XOR.
  logic [PW-1:0]                          acc_q[NST], acc_d[NST];
  logic [NST-1:0]                         vld_q;
  logic [G6LCCfg.TRANS_ID_BITS-1:0]       tid_q[NST];
  fu_op                                   op_q[NST];
  // Operand carry: a enters stages S3..S7 from its own register; the b
  // remainder shrinks as slices are consumed (S2 out: b[63:16], then
  // 32/24/16/8 bits toward S7). Stage s reads only its own copies.
  logic [XW-1:0]  a_q[NST-1];
  logic [47:0]    b_rem_s2_q;
  logic [31:0]    b_rem_s3_q;
  logic [23:0]    b_rem_s4_q;
  logic [15:0]    b_rem_s5_q;
  logic [7:0]     b_rem_s6_q;

  always_comb begin : p_slices
    // S2: slices 0 and 1 — a_i/b_i are this token's own S1 registers
    acc_d[0] = slice_prod(a_i, b_i[7:0], 0) ^
               slice_prod(a_i, b_i[15:8], 1);
    // S3: slices 2 and 3 from the token's registered operands
    acc_d[1] = acc_q[0] ^
               slice_prod(a_q[0], b_rem_s2_q[7:0], 2) ^
               slice_prod(a_q[0], b_rem_s2_q[15:8], 3);
    // S4..S7: one slice each (4,5,6,7)
    acc_d[2] = acc_q[1] ^ slice_prod(a_q[1], b_rem_s3_q[7:0], 4);
    acc_d[3] = acc_q[2] ^ slice_prod(a_q[2], b_rem_s4_q[7:0], 5);
    acc_d[4] = acc_q[3] ^ slice_prod(a_q[3], b_rem_s5_q[7:0], 6);
    acc_d[5] = acc_q[4] ^ slice_prod(a_q[4], b_rem_s6_q[7:0], 7);
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_pipe
    if (~rst_ni) begin
      acc_q <= '{default: '0};
      vld_q <= '0;
      for (int unsigned s = 0; s < NST; s++) begin
        tid_q[s] <= '0;
        op_q[s]  <= MUL;
      end
      a_q        <= '{default: '0};
      b_rem_s2_q <= '0;
      b_rem_s3_q <= '0;
      b_rem_s4_q <= '0;
      b_rem_s5_q <= '0;
      b_rem_s6_q <= '0;
    end else if (flush_i) begin
      // Data regs keep shifting; only the record track is cleared — a
      // killed token is suppressed upstream and may not read the data.
      vld_q <= '0;
      for (int unsigned s = 0; s < NST; s++) begin
        tid_q[s] <= '0;
        op_q[s]  <= MUL;
      end
      acc_q <= '{default: '0};
    end else begin
      for (int unsigned s = 0; s < NST; s++) acc_q[s] <= acc_d[s];
      a_q[0]     <= a_i;
      b_rem_s2_q <= b_i[63:16];
      a_q[1]     <= a_q[0];
      b_rem_s3_q <= b_rem_s2_q[47:16];
      a_q[2]     <= a_q[1];
      b_rem_s4_q <= b_rem_s3_q[31:8];
      a_q[3]     <= a_q[2];
      b_rem_s5_q <= b_rem_s4_q[23:8];
      a_q[4]     <= a_q[3];
      b_rem_s6_q <= b_rem_s5_q[15:8];
      vld_q <= {vld_q[NST-2:0], valid_i};
      tid_q[0] <= trans_id_i;
      op_q[0]  <= operation_i;
      for (int unsigned s = 1; s < NST; s++) begin
        tid_q[s] <= tid_q[s-1];
        op_q[s]  <= op_q[s-1];
      end
    end
  end

  assign clmul_o   = acc_q[NST-1][XW-1:0];
  for (genvar i = 0; i < XW; i++) begin : gen_rev
    assign clmulr_o[i] = acc_q[NST-1][XW-1-i];
  end
  assign valid_o     = vld_q[NST-1];
  assign trans_id_o  = tid_q[NST-1];
  assign operation_o = op_q[NST-1];

  // svt-stage: class S2 value
  // svt-stage: class S3 value
  // svt-stage: class S4 value
  // svt-stage: class S5 value
  // svt-stage: class S6 value
  // svt-stage: class S7 value

//pragma translate_off
  // Cover: the S7 equivalence in multiplier.sv is vacuous unless the
  // pipe actually carries back-to-back tokens. Count consecutive
  // publishes with different products — under the pre-fix live-operand
  // fold a second token's S7 value was polluted by its successor's
  // operands, which only distinct-operand traffic exposes. Reported
  // under +equiv_report.
  logic [XW-1:0] cov_prod_q;
  logic          cov_vld_q;
  int unsigned   clmul_b2b_n = 0;
  always_ff @(posedge clk_i) begin : p_cov_b2b
    if (!rst_ni || flush_i) begin
      cov_vld_q <= 1'b0;
    end else if (valid_o) begin
      if (cov_vld_q && (clmul_o != cov_prod_q))
        clmul_b2b_n <= clmul_b2b_n + 1;
      cov_prod_q <= clmul_o;
      cov_vld_q  <= 1'b1;
    end
  end
  final begin
    if ($test$plusargs("equiv_report"))
      $display("[equiv] mult_clmul b2b: distinct=%0d", clmul_b2b_n);
  end
//pragma translate_on
endmodule
