// hyp8 provenance: REWRITTEN (sv-timing emit base, A1/A2 staggered ALU)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Matthias Baer <baermatt@student.ethz.ch>
// Author: Igor Loi <igor.loi@unibo.it>
// Author: Andreas Traber <atraber@student.ethz.ch>
// Author: Lukas Mueller <lukasmue@student.ethz.ch>
// Author: Florian Zaruba <zaruabf@iis.ee.ethz.ch>
//
// Date: 19.03.2017
// Description: LibreCore ALU based on RI5CY's ALU
//
// hyp8 (group 7): HypCfg.AluStages>=2 && AluStaggered splits the datapath
// into A1 (registered) and A2 (combinational to result_o); with
// HypCfg.AluStages==3 the full-result cone is split once more into A3:
//   A1: operand conditioning (bitmanip a select, b negate, shift operand
//       reverse/select), the LOW 32-bit add/sub with its carry-out,
//       and every operand copy A2/A3 still needs. Shift amount[5:3] is
//       captured, not consumed. Low-half compare runs in A2 on a_q/b_q.
//   A2 capture: barrel places 32/16/8 from the A1 shift operand.
//   A2: high-32 add with the registered carry, high logic, compare
//       finalize (slt/eq incl. signed -- kept here because
//       alu_branch_res_o must keep B-stage timing), the LOW-class
//       (LAT_ALU_LOW) result mux. Bit-index ops and SLLIUW are A3.
//       and the A2->A3 input capture registers.
//   A3 (AluStages==3 only): second barrel-shift level group + reversal,
//       all operand-transform results (bitmanip, count, pack, perm,
//       sext, czero), and the LAT_ALU_FULL result mux -> result3_q.
// Dependent distance: add/logic results are forwardable one cycle after
// issue through alu_fwd_low_o (the A1 low half) and write back through
// the A2 lane record at +2; shifts, compares and all LAT_ALU_FULL ops
// complete three cycles after issue through the A3 lane record (the
// named rank-5 dependent cut, analysis/cut_minimization.md). The IQ
// countdown lands the dependent's rdy on the result3 publish cycle and
// its operand pick uses the third forward tap (fwd_*_i[2]).
// HypCfg.AluStages==1 instantiates the original combinational ALU;
// HypCfg.AluStages==2 keeps the original two-stage form (A3EN off, the
// A3 cone merges back into result_q).
// New ports (deviations, all documented):
//   alu_fwd_low_o - A1 low-32 result tap, valid one cycle after fu_data_i.
//   alu_fwd_tid_o - trans_id of the op in the A1 registers.
//   alu_fwd_qtid_o - trans_id of the op in the result_q (A2) slot.
//   alu_fwd_rtid_o - trans_id of the op in the result3_q (A3) slot
//     (equals qtid when AluStages==2 so a stray [2] pick is harmless).
//   alu_s2_a3_o/alu_s3_a3_o - the op in the A2-result / A3-result slot is
//     A3-class; ex_stage uses them to pick the +2 or +3 lane record.
//   fwd_a_i/fwd_b_i - 3-bit operand select for the A1 capture:
//     bit0 picks the live A2-comb result (op in A1, sel_d), bit1 the
//     registered A2 result (sel_q), bit2 the registered A3 result (sel_r).
//     Driven by the IRO from the IQ spec-arm producer tids; the ALU
//     carries no valid line so a stale tid match is guarded by the
//     spec-arm flag.
// Timing: for LAT_ALU_FULL ops result_o is the registered A3 output
// (full-result latency = 3 cycles after fu_data_i, dependent distance 3,
// rank-5); for LAT_ALU_LOW ops it is the registered A2 output (2 cycles,
// dependent distance 1 through the A1-capture forward).

module alu
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::HypDefault,
    parameter bit HasBranch = 1'b1,
    parameter type fu_data_t = logic
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // FU data needed to execute instruction - ISSUE_STAGE
    input fu_data_t fu_data_i,
    // FU data needed to execute CPOP/CPOPW - ISSUE_STAGE
    input fu_data_t fu_data_cpop_i,
    // ALU result - ISSUE_STAGE
    output logic [G6LCCfg.XLEN-1:0] result_o,
    // ALU branch compare result - branch_unit
    output logic alu_branch_res_o,
    // hyp8: A1 low-half forward (low 32 bits of add/logic class results,
    // valid one cycle after fu_data_i) - ISSUE_STAGE
    output logic [31:0] alu_fwd_low_o,
    // hyp8: trans_id of the op currently in the A1 registers - ISSUE_STAGE
    // (the IRO compares spec-armed producer tids against it).
    output logic [G6LCCfg.TRANS_ID_BITS-1:0] alu_fwd_tid_o,
    // hyp8: trans_id of the op in the registered A2 result slot (the op
    // that was in A1 last cycle; the result_q forward source).
    output logic [G6LCCfg.TRANS_ID_BITS-1:0] alu_fwd_qtid_o,
    // hyp8: trans_id of the op in the registered A3 result slot (the
    // result3_q forward source identity; tied to qtid when
    // HypCfg.AluStages==2 so the [2] operand pick is a safe alias).
    output logic [G6LCCfg.TRANS_ID_BITS-1:0] alu_fwd_rtid_o,
    // hyp8: slot-class taps for the ex_stage FLU lane: the op in the
    // result_q slot / the result3_q slot is A3-class (LAT_ALU_FULL).
    // Both 0 when HypCfg.AluStages==2.
    output logic                               alu_s2_a3_o,
    output logic                               alu_s3_a3_o,
    // hyp8: live A2-comb result (one cycle after fu_data_i; the pre-
    // register result). The alu2 cross-bypass uses this as the closest
    // analogue of the original same-cycle result_o. Observability only.
    output logic [G6LCCfg.XLEN-1:0] alu_result_d_o,
    // hyp8: A1-stage operand select. Per operand, bit 0 selects the live
    // A2-comb result (result_d: the op in the A1 registers), bit 1 the
    // registered A2 result (result_q: the op that was in A1 last cycle),
    // bit 2 the registered A3 result (result3_q: the LAT_ALU_FULL op that
    // was in A1 two cycles ago). Driven by issue_read_operands from the
    // IQ spec-arm producer tids; all zero for every non-speculative
    // operand. New port (deviation).
    input  logic [2:0] fwd_a_i,
    input  logic [2:0] fwd_b_i
);

  if (HypCfg.AluStages >= 2 && HypCfg.AluStaggered) begin : gen_staggered
    // hyp8 r5: A3EN -- the full-result (LAT_ALU_FULL) cone is retimed one
    // more cycle into an explicit A3 stage. When 0 (AluStages==2) the
    // s3_* stage inputs alias the A1 registers and the A3 result mux
    // merges back into result_q, reproducing the two-stage form.
    localparam bit A3EN = (HypCfg.AluStages >= 3);

    // Ops whose result completes in A3: exactly the fu==ALU LAT_ALU_FULL
    // set = the complement of the LAT_ALU_LOW distance-1 table in
    // g6lc_ooo_pkg::ooo_lat_class. Kept as an explicit op list so the A2
    // result mux (low arms) and this predicate can never drift apart.
    function automatic logic alu_is_a3(input fu_op op);
      unique case (op)
        ADD,      SUB,      ADDW,     SUBW,
        XORL,     ORL,      ANDL,     ANDN,     ORN,      XNOR,
        SH1ADD,   SH2ADD,   SH3ADD,
        SH1ADDUW, SH2ADDUW, SH3ADDUW,
        ADDUW:              return 1'b0;
        // hyp8 r7: bit-index and SLLIUW are a variable shift. They complete
        // in A3 (LAT_ALU_FULL) so the distance-1 bypass of result_d is only
        // the add/logic mux. ooo_lat_class lists the same ops.
        default:            return 1'b1;
      endcase
    endfunction
    // -------------------------------------------------------
    // svt-stage: begin A1
    // A1: operand conditioning + low-half work, registered.
    // -------------------------------------------------------
    logic [G6LCCfg.XLEN-1:0] operand_a;
    logic [G6LCCfg.XLEN-1:0] operand_a_rev;
    logic [           31:0] operand_a_rev32;
    logic [G6LCCfg.XLEN-1:0] operand_b;
    logic [ G6LCCfg.XLEN:0] operand_b_neg;
    logic adder_op_b_negate;

    // hyp8: forward-declared result stages. result_d is this cycle's
    // combinational A2 output (the op in the A1 registers); result_q is
    // the registered A2 result (one cycle older); result3_q is the
    // registered A3 result (two cycles older, A3EN only). The A1 operand
    // capture below selects among {result_d, result_q, result3_q, fu_data
    // operand}: a spec-woken dependent whose producer sits in A1/A2/A3
    // right now picks up the full forwarded result at the A1 capture
    // edge - distance 1 for LAT_ALU_LOW (bit0/bit1), distance 3 for
    // LAT_ALU_FULL (bit2). The low-half tap of the same mechanism is
    // exported as alu_fwd_low_o for observability.
    logic [G6LCCfg.XLEN-1:0] result_d;
    logic [G6LCCfg.XLEN-1:0] result_q;
    logic [G6LCCfg.XLEN-1:0] a3_d;
    logic [G6LCCfg.XLEN-1:0] result3_q;
    logic [G6LCCfg.XLEN-1:0] result3_eff;
    // Class of the op in each result slot. Declared here so the operand
    // mux can refuse an A3-class slot: that slot's result_d/result_q is
    // 0, and forwarding the 0 would retire a wrong GPR value. Bit 2 is
    // the only forward of an A3 result (result3_q), matching the
    // ex_stage rule that flu_valid for that op is alu_vld_q3 & alu_s3_a3.
    logic                    a3cls1_q, a3cls2_q, a3cls3_q;
    logic                    fwd_a0, fwd_a1, fwd_a2, fwd_b0, fwd_b1, fwd_b2;

    assign result3_eff = A3EN ? result3_q : result_q;
    assign fwd_a0 = fwd_a_i[0] && !(A3EN && a3cls1_q);
    assign fwd_a1 = fwd_a_i[1] && !(A3EN && a3cls2_q);
    assign fwd_a2 = fwd_a_i[2] && (!A3EN || a3cls3_q);
    assign fwd_b0 = fwd_b_i[0] && !(A3EN && a3cls1_q);
    assign fwd_b1 = fwd_b_i[1] && !(A3EN && a3cls2_q);
    assign fwd_b2 = fwd_b_i[2] && (!A3EN || a3cls3_q);
    // Priority lives in a 2-bit code (distance 0, then 1, then 2). Each
    // half is its own unique case, so the wide select is one mux, not a
    // chain of ternaries, and each code drives 32 bits.
    logic [31:0] opa_lo, opa_hi, opb_lo, opb_hi;
    logic [1:0] asel_lo, asel_hi, bsel_lo, bsel_hi;
    always_comb begin
      if (fwd_a0) asel_hi = 2'd0;
      else if (fwd_a1) asel_hi = 2'd1;
      else if (fwd_a2) asel_hi = 2'd2;
      else asel_hi = 2'd3;
    end
    always_comb begin
      if (fwd_a0) asel_lo = 2'd0;
      else if (fwd_a1) asel_lo = 2'd1;
      else if (fwd_a2) asel_lo = 2'd2;
      else asel_lo = 2'd3;
    end
    always_comb begin
      if (fwd_b0) bsel_hi = 2'd0;
      else if (fwd_b1) bsel_hi = 2'd1;
      else if (fwd_b2) bsel_hi = 2'd2;
      else bsel_hi = 2'd3;
    end
    always_comb begin
      if (fwd_b0) bsel_lo = 2'd0;
      else if (fwd_b1) bsel_lo = 2'd1;
      else if (fwd_b2) bsel_lo = 2'd2;
      else bsel_lo = 2'd3;
    end
    // Distance 0 low half is fwd_low (add_lo_q or the logic op). It matches
    // result_d[31:0] for a low-class producer and does not wait for add_hi.
    always_comb begin
      unique case (asel_hi)
        2'd0: opa_hi = result_d[63:32];
        2'd1: opa_hi = result_q[63:32];
        2'd2: opa_hi = result3_eff[63:32];
        default: opa_hi = fu_data_i.operand_a[63:32];
      endcase
    end
    always_comb begin
      unique case (asel_lo)
        2'd0: opa_lo = fwd_low;
        2'd1: opa_lo = result_q[31:0];
        2'd2: opa_lo = result3_eff[31:0];
        default: opa_lo = fu_data_i.operand_a[31:0];
      endcase
    end
    always_comb begin
      unique case (bsel_hi)
        2'd0: opb_hi = result_d[63:32];
        2'd1: opb_hi = result_q[63:32];
        2'd2: opb_hi = result3_eff[63:32];
        default: opb_hi = fu_data_i.operand_b[63:32];
      endcase
    end
    always_comb begin
      unique case (bsel_lo)
        2'd0: opb_lo = fwd_low;
        2'd1: opb_lo = result_q[31:0];
        2'd2: opb_lo = result3_eff[31:0];
        default: opb_lo = fu_data_i.operand_b[31:0];
      endcase
    end
    assign operand_a = {opa_hi, opa_lo};
    assign operand_b = {opb_hi, opb_lo};

    for (genvar k = 0; k < G6LCCfg.XLEN; k++) assign operand_a_rev[k] = operand_a[G6LCCfg.XLEN-1-k];
    for (genvar k = 0; k < 32; k++) assign operand_a_rev32[k] = operand_a[31-k];

    logic [G6LCCfg.XLEN-1:0] operand_a_bitmanip, operand_a_cpop;

    assign adder_op_b_negate = fu_data_i.operation inside {EQ, NE, SUB, SUBW, ANDN, ORN, XNOR};

    always_comb begin
      operand_a_bitmanip = operand_a;
      // hyp8: the forwarded producer result replaces the CPOP operand too.
      unique case (asel_lo)
        2'd0: operand_a_cpop = result_d;
        2'd1: operand_a_cpop = result_q;
        2'd2: operand_a_cpop = result3_eff;
        default: operand_a_cpop = fu_data_cpop_i.operand_a;
      endcase

      if (G6LCCfg.RVB) begin
        if (G6LCCfg.IS_XLEN64) begin
          unique case (fu_data_i.operation)
            SH1ADDUW:    operand_a_bitmanip = G6LCCfg.XLEN'(operand_a[31:0]) << 1;
            SH2ADDUW:    operand_a_bitmanip = G6LCCfg.XLEN'(operand_a[31:0]) << 2;
            SH3ADDUW:    operand_a_bitmanip = G6LCCfg.XLEN'(operand_a[31:0]) << 3;
            CTZW:        operand_a_bitmanip = G6LCCfg.XLEN'(operand_a_rev32);
            ADDUW, CLZW: operand_a_bitmanip = G6LCCfg.XLEN'(operand_a[31:0]);
            CPOPW:       operand_a_cpop = G6LCCfg.XLEN'(operand_a_cpop[31:0]);
            default:     ;
          endcase
        end
        unique case (fu_data_i.operation)
          SH1ADD:  operand_a_bitmanip = operand_a << 1;
          SH2ADD:  operand_a_bitmanip = operand_a << 2;
          SH3ADD:  operand_a_bitmanip = operand_a << 3;
          CTZ:     operand_a_bitmanip = operand_a_rev;
          default: ;
        endcase
      end
    end

    // prepare operand b (negated for subtract-class and ANDN/ORN/XNOR ops)
    // Same as {operand_b, 1'b0} ^ {XLEN+1{negate}}, per half.
    logic [32:0] opb_neg_lo;
    logic [31:0] opb_neg_hi;
    assign opb_neg_lo = {opb_lo, 1'b0} ^ {33{adder_op_b_negate}};
    assign opb_neg_hi = opb_hi ^ {32{adder_op_b_negate}};
    assign operand_b_neg = {opb_neg_hi, opb_neg_lo};

    logic [G6LCCfg.XLEN:0] adder_in_a, adder_in_b;
    assign adder_in_a = {operand_a_bitmanip, 1'b1};
    assign adder_in_b = operand_b_neg;
    // Low-class addends. A left shift of 1..3 into the low word does not
    // read the high half, so this add does not wait for the producer's add_hi.
    logic [31:0] add_a_lo;
    always_comb begin
      unique case (fu_data_i.operation)
        SH1ADD, SH1ADDUW: add_a_lo = {opa_lo[30:0], 1'b0};
        SH2ADD, SH2ADDUW: add_a_lo = {opa_lo[29:0], 2'b0};
        SH3ADD, SH3ADDUW: add_a_lo = {opa_lo[28:0], 3'b0};
        default:          add_a_lo = opa_lo;
      endcase
    end

    logic shift_left;
    assign shift_left = (fu_data_i.operation == SLL) | (G6LCCfg.IS_XLEN64 && fu_data_i.operation == SLLW);

    // A1 registers
    localparam int unsigned HW = G6LCCfg.XLEN / 2;
    fu_op                          op_q;
    logic                          sgn_q;
    logic [G6LCCfg.XLEN-1:0]       a_q, b_q, ab_q, ac_q;
    logic [G6LCCfg.XLEN:0]         bneg_q;
    logic [HW+1:0]                 add_lo_q;      // low 33-bit sum + carry-out
    logic [HW-1:0]                 ina_hi_q, inb_hi_q;
    logic [2:0]                    shamt_q;
    logic [2:0]                    shamt_hi_q;
    logic                          shl_q;

    wire signed_cmp = (fu_data_i.operation inside {SLTS, LTS, GES, MAX, MIN});

    always_ff @(posedge clk_i or negedge rst_ni) begin : alu_a1_regs
      if (!rst_ni) begin
        op_q      <= ADD;
        sgn_q     <= 1'b0;
        a_q       <= '0;
        b_q       <= '0;
        ab_q      <= '0;
        ac_q      <= '0;
        bneg_q    <= '0;
        add_lo_q  <= '0;
        ina_hi_q  <= '0;
        inb_hi_q  <= '0;
        shamt_q    <= '0;
        shamt_hi_q <= '0;
        shl_q      <= 1'b0;
      end else begin
        op_q      <= fu_data_i.operation;
        sgn_q     <= signed_cmp;
        a_q       <= operand_a;
        b_q       <= operand_b;
        ab_q      <= operand_a_bitmanip;
        ac_q      <= operand_a_cpop;
        bneg_q    <= operand_b_neg;
        add_lo_q  <= {1'b0, add_a_lo, 1'b1} + {1'b0, opb_neg_lo};
        ina_hi_q  <= adder_in_a[G6LCCfg.XLEN:HW+1];
        inb_hi_q  <= adder_in_b[G6LCCfg.XLEN:HW+1];
        // Reverse and the arithmetic sign bit are applied with the barrel
        // after this flop, from a_q. Low bits stay in shamt_q for A3.
        shamt_q    <= operand_b[2:0];
        shamt_hi_q <= operand_b[5:3];
        shl_q      <= shift_left;
      end
    end

    // -------------------------------------------------------
    // svt-stage: end A1
    // svt-stage: begin A2
    // hyp8: A1 low-half forward -- the low 32 bits of the add/logic
    // result, one cycle after issue. This is the LAT_ALU_LOW bypass
    // source for the next dependent's operand stage.
    // -------------------------------------------------------
    logic [31:0] fwd_low;
    always_comb begin
      unique case (op_q)
        ANDL, ANDN: fwd_low = a_q[31:0] & bneg_q[32:1];
        ORL,  ORN:  fwd_low = a_q[31:0] | bneg_q[32:1];
        XORL, XNOR: fwd_low = a_q[31:0] ^ bneg_q[32:1];
        default:    fwd_low = add_lo_q[32:1];  // adder result [31:0] = ext[32:1]
      endcase
    end
    assign alu_fwd_low_o = fwd_low;

    // -------------------------------------------------------
    // A2: high-half completion + result select (combinational).
    // -------------------------------------------------------
    logic [HW:0]               add_hi;
    logic [G6LCCfg.XLEN+1:0]   adder_result_ext;
    logic [G6LCCfg.XLEN-1:0]   adder_result;
    assign add_hi = {1'b0, ina_hi_q} + {1'b0, inb_hi_q} +
                    {{HW{1'b0}}, add_lo_q[HW+1]};
    assign adder_result_ext = {add_hi, add_lo_q[HW:0]};
    assign adder_result = adder_result_ext[G6LCCfg.XLEN:1];

    // Both halves compare the registered operands. They are independent,
    // then one gate merges them. Branch and A3 still sample this cycle.
    logic eq_lo, lt_lo, eq_hi, lt_hi, operands_equal, less;
    assign eq_lo = (a_q[31:0] == b_q[31:0]);
    assign lt_lo = (a_q[31:0] < b_q[31:0]);
    assign eq_hi = (a_q[G6LCCfg.XLEN-1:32] == b_q[G6LCCfg.XLEN-1:32]);
    assign lt_hi = ($signed({sgn_q & a_q[G6LCCfg.XLEN-1], a_q[G6LCCfg.XLEN-1:32]}) <
                    $signed({sgn_q & b_q[G6LCCfg.XLEN-1], b_q[G6LCCfg.XLEN-1:32]}));
    assign operands_equal = eq_hi & eq_lo;
    assign less = lt_hi | (eq_hi & lt_lo);

    // get the right branch comparison result
    if (HasBranch) begin
      always_comb begin : branch_resolve
        case (op_q)
          EQ:       alu_branch_res_o = operands_equal;
          NE:       alu_branch_res_o = ~operands_equal;
          LTS, LTU: alu_branch_res_o = less;
          GES, GEU: alu_branch_res_o = ~less;
          default:  alu_branch_res_o = 1'b1;
        endcase
      end
    end else begin
      assign alu_branch_res_o = 1'b0;
    end

    // -----------
    // Result MUX (A2, combinational; LAT_ALU_LOW arms only). Bit-index
    // and SLLIUW are A3 (alu_is_a3). A priority chain would sum those
    // arms into the distance-1 bypass; a one-hot OR does not.
    // For a LAT_ALU_FULL op every sel_* is 0 and result_d is '0 -- its
    // WB goes through result3_q, never through result_q.
    // -----------
    logic [G6LCCfg.XLEN-1:0] res_logic, res_w;
    logic sel_add, sel_w, sel_logic;
    assign res_logic = (op_q inside {ANDL, ANDN}) ? (a_q & bneg_q[G6LCCfg.XLEN:1]) :
                       (op_q inside {ORL, ORN})   ? (a_q | bneg_q[G6LCCfg.XLEN:1]) :
                       (op_q inside {XORL, XNOR}) ? (a_q ^ bneg_q[G6LCCfg.XLEN:1]) :
                                                    '0;
    assign res_w = {{G6LCCfg.XLEN - 32{adder_result[31]}}, adder_result[31:0]};
    assign sel_w = G6LCCfg.IS_XLEN64 && (op_q inside {ADDW, SUBW});
    assign sel_add = (op_q inside {ADD, SUB, ADDUW, SH1ADD, SH2ADD, SH3ADD}) ||
                     (G6LCCfg.IS_XLEN64 && (op_q inside {SH1ADDUW, SH2ADDUW, SH3ADDUW}));
    assign sel_logic = op_q inside {ANDL, ANDN, ORL, ORN, XORL, XNOR};
    assign result_d = ({G6LCCfg.XLEN{sel_w}} & res_w) |
                      ({G6LCCfg.XLEN{sel_add}} & adder_result) |
                      ({G6LCCfg.XLEN{sel_logic}} & res_logic);

    // -------------------------------------------------------
    // hyp8: A2 output register (the LAT_ALU_LOW path). result_o is the
    // REGISTERED A2 output for low-class ops; with !A3EN result_q
    // additionally merges the A3 mux so the two-stage form is
    // bit-identical to the original. The register doubles as the
    // ex_stage WB lane record and as the sel_q forward source for a
    // dependent two pipe cycles behind.
    // -------------------------------------------------------
    logic [G6LCCfg.TRANS_ID_BITS-1:0] fwd_tid_q, fwd_tid2_q, fwd_tid3_q;
    always_ff @(posedge clk_i or negedge rst_ni) begin : alu_a2_reg
      if (!rst_ni) begin
        result_q   <= '0;
        fwd_tid_q  <= '0;
        fwd_tid2_q <= '0;
      end else begin
        result_q   <= A3EN ? result_d : (result_d | a3_d);
        fwd_tid_q  <= fu_data_i.trans_id;
        fwd_tid2_q <= fwd_tid_q;
      end
    end

    // svt-stage: end A2
    // svt-stage: begin A3
    // -------------------------------------------------------
    // hyp8 r5: A2->A3 input capture. With A3EN these registers hold the
    // A1-stage record for the A3 cone one more cycle; without it the
    // s3_* stage inputs alias the A1 registers and this region is the
    // original same-cycle A2 compute.
    // -------------------------------------------------------
    fu_op                          a2_op_q;
    logic                          a2_shl_q, a2_less_q, a2_eq_q;
    logic [G6LCCfg.XLEN-1:0]       a2_a_q, a2_b_q, a2_ab_q, a2_ac_q;
    logic [G6LCCfg.XLEN:0]         a2_shift_q;
    logic [          32:0]         a2_shift32_q;
    logic [2:0]                    a2_shamt_q;

    fu_op                          s3_op;
    logic                          s3_shl, s3_less, s3_eq;
    logic [G6LCCfg.XLEN-1:0]       s3_a, s3_b, s3_ab, s3_ac;
    logic [G6LCCfg.XLEN:0]         s3_shift;
    logic [          32:0]         s3_shift32;
    logic [2:0]                    s3_shamt;

    // Reverse, sign, then places 32/16/8. All from A1 flops, so this is
    // not on the forward mux. a3_d still applies places 4, 2 and 1 and
    // reverses a left shift back.
    logic [G6LCCfg.XLEN-1:0] a_sh_rev;
    logic [31:0]             a_sh_rev32;
    logic [G6LCCfg.XLEN-1:0] a_sh;
    logic [31:0]             a_sh32;
    logic                    shift_arith_q;
    logic [G6LCCfg.XLEN:0]   shift_base_64;
    logic [32:0]             shift_base_32;
    logic [G6LCCfg.XLEN:0]   shift_hi_64;
    logic [32:0]             shift_hi_32;
    for (genvar kr = 0; kr < 64; kr++) assign a_sh_rev[kr] = a_q[63-kr];
    for (genvar kr = 0; kr < 32; kr++) assign a_sh_rev32[kr] = a_q[31-kr];
    assign shift_arith_q = (op_q == SRA) | (G6LCCfg.IS_XLEN64 && op_q == SRAW);
    assign a_sh   = shl_q ? a_sh_rev : a_q;
    assign a_sh32 = shl_q ? a_sh_rev32 : a_q[31:0];
    assign shift_base_64 = {shift_arith_q & a_sh[G6LCCfg.XLEN-1], a_sh};
    assign shift_base_32 = {shift_arith_q & a_q[31], a_sh32};
    // Arithmetic places 32, 16, 8 as bit muxes. Each amount bit is copied
    // per 13-bit group so the select fanout stays small. Sign fills from
    // the top bit, matching $signed(base) >>> N.
    logic [64:0] sh64_32, sh64_16;
    logic [32:0] sh32_16;
    logic k32_0, k32_1, k32_2, k32_3, k32_4;
    logic k16_0, k16_1, k16_2, k16_3, k16_4;
    logic k8_0, k8_1, k8_2, k8_3, k8_4;
    logic w16_0, w16_1, w16_2, w8_0, w8_1, w8_2;
    assign k32_0 = shamt_hi_q[2]; assign k32_1 = shamt_hi_q[2];
    assign k32_2 = shamt_hi_q[2]; assign k32_3 = shamt_hi_q[2];
    assign k32_4 = shamt_hi_q[2];
    assign k16_0 = shamt_hi_q[1]; assign k16_1 = shamt_hi_q[1];
    assign k16_2 = shamt_hi_q[1]; assign k16_3 = shamt_hi_q[1];
    assign k16_4 = shamt_hi_q[1];
    assign k8_0 = shamt_hi_q[0]; assign k8_1 = shamt_hi_q[0];
    assign k8_2 = shamt_hi_q[0]; assign k8_3 = shamt_hi_q[0];
    assign k8_4 = shamt_hi_q[0];
    assign w16_0 = shamt_hi_q[1]; assign w16_1 = shamt_hi_q[1];
    assign w16_2 = shamt_hi_q[1];
    assign w8_0 = shamt_hi_q[0]; assign w8_1 = shamt_hi_q[0];
    assign w8_2 = shamt_hi_q[0];
    for (genvar b = 0; b < 65; b++) begin : gen_sh64
      if (b < 13) begin : g0
        assign sh64_32[b] = k32_0 ? ((b + 32 > 64) ? shift_base_64[64] : shift_base_64[b + 32]) : shift_base_64[b];
        assign sh64_16[b] = k16_0 ? ((b + 16 > 64) ? sh64_32[64] : sh64_32[b + 16]) : sh64_32[b];
        assign shift_hi_64[b] = k8_0 ? ((b + 8 > 64) ? sh64_16[64] : sh64_16[b + 8]) : sh64_16[b];
      end else if (b < 26) begin : g1
        assign sh64_32[b] = k32_1 ? ((b + 32 > 64) ? shift_base_64[64] : shift_base_64[b + 32]) : shift_base_64[b];
        assign sh64_16[b] = k16_1 ? ((b + 16 > 64) ? sh64_32[64] : sh64_32[b + 16]) : sh64_32[b];
        assign shift_hi_64[b] = k8_1 ? ((b + 8 > 64) ? sh64_16[64] : sh64_16[b + 8]) : sh64_16[b];
      end else if (b < 39) begin : g2
        assign sh64_32[b] = k32_2 ? ((b + 32 > 64) ? shift_base_64[64] : shift_base_64[b + 32]) : shift_base_64[b];
        assign sh64_16[b] = k16_2 ? ((b + 16 > 64) ? sh64_32[64] : sh64_32[b + 16]) : sh64_32[b];
        assign shift_hi_64[b] = k8_2 ? ((b + 8 > 64) ? sh64_16[64] : sh64_16[b + 8]) : sh64_16[b];
      end else if (b < 52) begin : g3
        assign sh64_32[b] = k32_3 ? ((b + 32 > 64) ? shift_base_64[64] : shift_base_64[b + 32]) : shift_base_64[b];
        assign sh64_16[b] = k16_3 ? ((b + 16 > 64) ? sh64_32[64] : sh64_32[b + 16]) : sh64_32[b];
        assign shift_hi_64[b] = k8_3 ? ((b + 8 > 64) ? sh64_16[64] : sh64_16[b + 8]) : sh64_16[b];
      end else begin : g4
        assign sh64_32[b] = k32_4 ? ((b + 32 > 64) ? shift_base_64[64] : shift_base_64[b + 32]) : shift_base_64[b];
        assign sh64_16[b] = k16_4 ? ((b + 16 > 64) ? sh64_32[64] : sh64_32[b + 16]) : sh64_32[b];
        assign shift_hi_64[b] = k8_4 ? ((b + 8 > 64) ? sh64_16[64] : sh64_16[b + 8]) : sh64_16[b];
      end
    end
    for (genvar b = 0; b < 33; b++) begin : gen_sh32
      if (b < 11) begin : g0
        assign sh32_16[b] = w16_0 ? ((b + 16 > 32) ? shift_base_32[32] : shift_base_32[b + 16]) : shift_base_32[b];
        assign shift_hi_32[b] = w8_0 ? ((b + 8 > 32) ? sh32_16[32] : sh32_16[b + 8]) : sh32_16[b];
      end else if (b < 22) begin : g1
        assign sh32_16[b] = w16_1 ? ((b + 16 > 32) ? shift_base_32[32] : shift_base_32[b + 16]) : shift_base_32[b];
        assign shift_hi_32[b] = w8_1 ? ((b + 8 > 32) ? sh32_16[32] : sh32_16[b + 8]) : sh32_16[b];
      end else begin : g2
        assign sh32_16[b] = w16_2 ? ((b + 16 > 32) ? shift_base_32[32] : shift_base_32[b + 16]) : shift_base_32[b];
        assign shift_hi_32[b] = w8_2 ? ((b + 8 > 32) ? sh32_16[32] : sh32_16[b + 8]) : sh32_16[b];
      end
    end

    if (A3EN) begin : g_a3cap
      always_ff @(posedge clk_i or negedge rst_ni) begin : alu_a2_in_regs
        if (!rst_ni) begin
          a2_op_q      <= ADD;
          a2_a_q       <= '0;
          a2_b_q       <= '0;
          a2_ab_q      <= '0;
          a2_ac_q      <= '0;
          a2_shl_q     <= 1'b0;
          a2_less_q    <= 1'b0;
          a2_eq_q      <= 1'b0;
          a2_shift_q   <= '0;
          a2_shift32_q <= '0;
          a2_shamt_q   <= '0;
        end else begin
          a2_op_q      <= op_q;
          a2_a_q       <= a_q;
          a2_b_q       <= b_q;
          a2_ab_q      <= ab_q;
          a2_ac_q      <= ac_q;
          a2_shl_q     <= shl_q;
          a2_less_q    <= less;
          a2_eq_q      <= operands_equal;
          a2_shift_q   <= shift_hi_64;
          a2_shift32_q <= shift_hi_32;
          a2_shamt_q   <= shamt_q;
        end
      end
      assign s3_op      = a2_op_q;
      assign s3_a       = a2_a_q;
      assign s3_b       = a2_b_q;
      assign s3_ab      = a2_ab_q;
      assign s3_ac      = a2_ac_q;
      assign s3_shl     = a2_shl_q;
      assign s3_less    = a2_less_q;
      assign s3_eq      = a2_eq_q;
      assign s3_shift   = a2_shift_q;
      assign s3_shift32 = a2_shift32_q;
      assign s3_shamt   = a2_shamt_q;
    end else begin : g_a3cap_off
      assign a2_op_q      = ADD;
      assign a2_a_q       = '0;
      assign a2_b_q       = '0;
      assign a2_ab_q      = '0;
      assign a2_ac_q      = '0;
      assign a2_shl_q     = 1'b0;
      assign a2_less_q    = 1'b0;
      assign a2_eq_q      = 1'b0;
      assign a2_shift_q   = '0;
      assign a2_shift32_q = '0;
      assign a2_shamt_q   = '0;
      assign s3_op      = op_q;
      assign s3_a       = a_q;
      assign s3_b       = b_q;
      assign s3_ab      = ab_q;
      assign s3_ac      = ac_q;
      assign s3_shl     = shl_q;
      assign s3_less    = less;
      assign s3_eq      = operands_equal;
      // AluStages==2 has no A2 flop between the places. The places live in
      // alu_shift_hi so this arm does not lengthen alu's own cone.
      alu_shift_hi #(.XLEN(G6LCCfg.XLEN)) i_shift_hi (
          .op_a_i     (a_q),
          .shl_i      (shl_q),
          .arith_i    ((op_q == SRA) | (G6LCCfg.IS_XLEN64 && op_q == SRAW)),
          .shamt_hi_i (shamt_hi_q),
          .shift_o    (s3_shift),
          .shift32_o  (s3_shift32)
      );
      assign s3_shamt   = shamt_q;
    end

    // ---------
    // Shifts -- second level group (low amount bits), A3 stage
    // ---------
    logic [G6LCCfg.XLEN:0] shift_right_result;
    logic [          32:0] shift_right_result32;
    always_comb begin
      shift_right_result = s3_shift;
      for (int l = 2; l >= 0; l--)
        if (s3_shamt[l]) shift_right_result = $unsigned($signed(shift_right_result) >>> (1 << l));
      shift_right_result32 = s3_shift32;
      for (int l = 2; l >= 0; l--)
        if (s3_shamt[l]) shift_right_result32 = $unsigned($signed(shift_right_result32) >>> (1 << l));
    end

    //pragma translate_off
    // M3 bring-up probe (+icf_trace): shift-op datapath check (slli s0,s0,31
    // produced 0 in the first smoke run).
    logic alu_trace;
    initial alu_trace = $test$plusargs("icf_trace");
    always_ff @(negedge clk_i) begin
      if (rst_ni && alu_trace &&
          ((fu_data_i.operation inside {SLL, SRL, SRA, SLLW, SRLW, SRAW}) ||
           (op_q inside {SLL, SRL, SRA, SLLW, SRLW, SRAW}) ||
           (s3_op inside {SLL, SRL, SRA, SLLW, SRLW, SRAW}))) begin
        $display("[alu] t=%0t in: op=%0d a=%h b=%h tid=%0d | a1q: opq=%0d shq=%h shamt=%h shl=%b | a3: sop=%0d ssh=%h srr=%h slr=%h a3d=%h r3q=%h a3c=%b%b%b res_o=%h",
          $time, fu_data_i.operation, operand_a, operand_b, fu_data_i.trans_id,
          op_q, a_q, shamt_q, shl_q,
          s3_op, s3_shift, shift_right_result, shift_left_result, a3_d,
          result3_q, a3cls1_q, a3cls2_q, a3cls3_q, result_o);
      end
    end
    //pragma translate_on

    // bit reverse the shift_right_result for left shifts
    logic [G6LCCfg.XLEN-1:0] shift_left_result;
    logic [          31:0] shift_left_result32;
    for (genvar j = 0; j < G6LCCfg.XLEN; j++)
      assign shift_left_result[j] = shift_right_result[G6LCCfg.XLEN-1-j];
    for (genvar j = 0; j < 32; j++)
      assign shift_left_result32[j] = shift_right_result32[31-j];

    logic [G6LCCfg.XLEN-1:0] shift_result;
    logic [          31:0] shift_result32;
    assign shift_result   = s3_shl ? shift_left_result : shift_right_result[G6LCCfg.XLEN-1:0];
    assign shift_result32 = s3_shl ? shift_left_result32 : shift_right_result32[31:0];

    // ------------
    // Bitmanip / crypto transforms (operand-only, A3 stage)
    // ------------
    logic [  $clog2(G6LCCfg.XLEN) : 0] cpop;
    logic [$clog2(G6LCCfg.XLEN)-1 : 0] lz_tz_count;
    logic [                       4:0] lz_tz_wcount;
    logic lz_tz_empty, lz_tz_wempty;
    logic [31:0] orcbw, rev8w;
    logic [G6LCCfg.XLEN-1:0] orcbw_result, rev8w_result;
    logic [G6LCCfg.XLEN-1:0] brev8_reversed;
    logic [           31:0] unzip_gen;
    logic [           31:0] zip_gen;
    logic [G6LCCfg.XLEN-1:0] xperm8_result;
    logic [G6LCCfg.XLEN-1:0] xperm4_result;
    logic [           31:0] rolw;
    logic [           31:0] rorw;

    if (G6LCCfg.RVB) begin : gen_bitmanip
      popcount #(
          .INPUT_WIDTH(G6LCCfg.XLEN)
      ) i_cpop_count (
          .data_i    (s3_ac),
          .popcount_o(cpop)
      );
      g6lc_hyp_lzc #(
          .WIDTH(G6LCCfg.XLEN),
          .MODE (1)
      ) i_clz_64b (
          .in_i(s3_ab),
          .cnt_o(lz_tz_count),
          .empty_o(lz_tz_empty)
      );
      if (G6LCCfg.IS_XLEN64) begin
        g6lc_hyp_lzc #(
            .WIDTH(32),
            .MODE (1)
        ) i_clz_32b (
            .in_i(s3_ab[31:0]),
            .cnt_o(lz_tz_wcount),
            .empty_o(lz_tz_wempty)
        );
      end else begin
        assign lz_tz_wcount = '0;
        assign lz_tz_wempty = 1'b0;
      end
    end else begin : gen_no_bitmanip
      assign cpop = '0;
      assign lz_tz_count = '0;
      assign lz_tz_wcount = '0;
      assign lz_tz_empty = 1'b0;
      assign lz_tz_wempty = 1'b0;
    end

    if (G6LCCfg.RVB) begin : gen_orcbw_rev8w_results
      assign orcbw = {
        {8{|s3_a[31:24]}}, {8{|s3_a[23:16]}}, {8{|s3_a[15:8]}}, {8{|s3_a[7:0]}}
      };
      assign rev8w = {{s3_a[7:0]}, {s3_a[15:8]}, {s3_a[23:16]}, {s3_a[31:24]}};
      if (G6LCCfg.IS_XLEN64) begin : gen_64b
        assign orcbw_result = {
          {8{|s3_a[63:56]}},
          {8{|s3_a[55:48]}},
          {8{|s3_a[47:40]}},
          {8{|s3_a[39:32]}},
          orcbw
        };
        assign rev8w_result = {
          rev8w, {s3_a[39:32]}, {s3_a[47:40]}, {s3_a[55:48]}, {s3_a[63:56]}
        };
      end else begin : gen_32b
        assign orcbw_result = orcbw;
        assign rev8w_result = rev8w;
      end
    end else begin : gen_no_orcbw
      assign orcbw_result = '0;
      assign rev8w_result = '0;
    end

    if (G6LCCfg.ZKN && G6LCCfg.RVB) begin : zkn_gen_block
      for (genvar i = 0; i < (G6LCCfg.XLEN / 8); i++) begin : brev8_xperm8_gen
        logic [7:0] xperm8_idx;
        assign xperm8_idx = s3_b[i << 3 +: 8];
        assign xperm8_result[i << 3 +: 8] = (xperm8_idx < 8'(G6LCCfg.XLEN / 8))
            ? s3_a[{xperm8_idx[$clog2(G6LCCfg.XLEN)-4:0], 3'b0} +: 8]
            : 8'b0;
        for (genvar m = 0; m < 8; m++) begin : reverse_bits
          assign brev8_reversed[(i<<3)+m] = s3_a[(i<<3)+(7-m)];
        end
      end
      for (genvar q = 0; q < (G6LCCfg.XLEN / 4); q++) begin : xperm4_gen
        assign xperm4_result[q << 2 +: 4] = (8'(s3_b[q << 2 +: 4]) < 8'(G6LCCfg.XLEN / 4))
            ? s3_a[{s3_b[q << 2 +: 4], 2'b0} +: 4]
            : 4'b0;
      end
      if (G6LCCfg.IS_XLEN32) begin
        for (genvar n = 0; n < 16; n++) begin : zip_unzip_gen
          assign zip_gen[n<<1] = s3_a[n];
          assign zip_gen[(n<<1)+1] = s3_a[n+16];
          assign unzip_gen[n] = s3_a[n<<1];
          assign unzip_gen[n+16] = s3_a[(n<<1)+1];
        end
      end else begin
        assign zip_gen = '0;
        assign unzip_gen = '0;
      end
    end else begin : no_zkn_gen
      assign xperm8_result = '0;
      assign xperm4_result = '0;
      assign brev8_reversed = '0;
      assign zip_gen = '0;
      assign unzip_gen = '0;
    end

    // -----------
    // Result MUX (A3, combinational; LAT_ALU_FULL arms only -- the
    // complement of the A2 mux by alu_is_a3). Registered into result3_q.
    // hyp8 r7: bit-index decode and SLLIUW live here, off result_d.
    // -----------
    logic [G6LCCfg.XLEN-1:0] s3_bit_indx;
    assign s3_bit_indx = G6LCCfg.RVB ? G6LCCfg.XLEN'(1) << s3_b[$clog2(G6LCCfg.XLEN)-1:0]
                                     : '0;
    always_comb begin : a3_result_mux
      a3_d = '0;
      rolw = '0;
      rorw = '0;
      if (G6LCCfg.IS_XLEN64) begin
        unique case (s3_op)
          SLLW, SRLW, SRAW:
          a3_d = {{G6LCCfg.XLEN - 32{shift_result32[31]}}, shift_result32[31:0]};
          default: ;
        endcase
      end
      unique case (s3_op)
        // Shift Operations
        SLL, SRL, SRA: a3_d = G6LCCfg.IS_XLEN64 ? shift_result : G6LCCfg.XLEN'(shift_result32);
        // Comparison Operations
        SLTS, SLTU: a3_d = {{G6LCCfg.XLEN - 1{1'b0}}, s3_less};
        default: ;  // default case to suppress unique warning
      endcase

      if (G6LCCfg.RVB) begin
        if (G6LCCfg.IS_XLEN64) begin
          rolw = (s3_a[31:0] << s3_b[4:0]) | (s3_a[31:0] >> (5'd0 - s3_b[4:0]));
          rorw = (s3_a[31:0] >> s3_b[4:0]) | (s3_a[31:0] << (5'd0 - s3_b[4:0]));
          unique case (s3_op)
            CLZW, CTZW:
            a3_d = (lz_tz_wempty) ? 32 : {{G6LCCfg.XLEN - 5{1'b0}}, lz_tz_wcount};
            ROLW: a3_d = {{G6LCCfg.XLEN - 32{rolw[31]}}, rolw};
            RORW, RORIW: a3_d = {{G6LCCfg.XLEN - 32{rorw[31]}}, rorw};
            default: ;
          endcase
        end
        unique case (s3_op)
          // Bit-index and SLLIUW (off the distance-1 bypass).
          BCLR, BCLRI: a3_d = s3_a & ~s3_bit_indx;
          BEXT, BEXTI: a3_d = {{G6LCCfg.XLEN - 1{1'b0}}, |(s3_a & s3_bit_indx)};
          BINV, BINVI: a3_d = s3_a ^ s3_bit_indx;
          BSET, BSETI: a3_d = s3_a | s3_bit_indx;

          // Integer minimum/maximum
          MAX:  a3_d = s3_less ? s3_b : s3_a;
          MAXU: a3_d = s3_less ? s3_b : s3_a;
          MIN:  a3_d = ~s3_less ? s3_b : s3_a;
          MINU: a3_d = ~s3_less ? s3_b : s3_a;

          // Count Leading/Trailing Zeros
          CLZ, CTZ:
          a3_d = (lz_tz_empty) ? ({{G6LCCfg.XLEN - $clog2(G6LCCfg.XLEN) {1'b0}}, lz_tz_count} + 1)
              : {{G6LCCfg.XLEN - $clog2(G6LCCfg.XLEN) {1'b0}}, lz_tz_count};

          // Count population
          CPOP, CPOPW: a3_d = {{(G6LCCfg.XLEN - ($clog2(G6LCCfg.XLEN) + 1)) {1'b0}}, cpop};

          // Sign and Zero Extend
          SEXTB: a3_d = {{G6LCCfg.XLEN - 8{s3_a[7]}}, s3_a[7:0]};
          SEXTH: a3_d = {{G6LCCfg.XLEN - 16{s3_a[15]}}, s3_a[15:0]};
          ZEXTH: a3_d = {{G6LCCfg.XLEN - 16{1'b0}}, s3_a[15:0]};

          // Bitwise Rotation
          ROL:
          a3_d = G6LCCfg.IS_XLEN64 ? ((s3_a << s3_b[5:0]) | (s3_a >> (6'd0 - s3_b[5:0]))) : ((s3_a << s3_b[4:0]) | (s3_a >> (5'd0 - s3_b[4:0])));

          ROR, RORI:
          a3_d = G6LCCfg.IS_XLEN64 ? ((s3_a >> s3_b[5:0]) | (s3_a << (6'd0 - s3_b[5:0]))) : ((s3_a >> s3_b[4:0]) | (s3_a << (5'd0 - s3_b[4:0])));

          ORCB: a3_d = orcbw_result;
          REV8: a3_d = rev8w_result;

          default: if (s3_op == SLLIUW && G6LCCfg.IS_XLEN64)
            a3_d = {{32{1'b0}}, s3_a[31:0]} << s3_b[5:0];
        endcase
      end
      if (G6LCCfg.RVZiCond) begin
        unique case (s3_op)
          CZERO_EQZ:
          a3_d = (|s3_b) ? s3_a : '0;  // move zero to rd if rs2 is equal to zero else rs1
          CZERO_NEZ:
          a3_d = (|s3_b) ? '0 : s3_a;  // move zero to rd if rs2 is nonzero else rs1
          default: ;
        endcase
      end
      // ZKN instructions
      if (G6LCCfg.ZKN && G6LCCfg.RVB) begin
        unique case (s3_op)
          PACK:
          a3_d = G6LCCfg.IS_XLEN32 ? G6LCCfg.XLEN'({s3_b[15:0], s3_a[15:0]}) : {s3_b[31:0], s3_a[31:0]};
          PACK_H:
          a3_d = G6LCCfg.IS_XLEN32 ? G6LCCfg.XLEN'({16'b0, s3_b[7:0], s3_a[7:0]}) : {48'b0, s3_b[7:0], s3_a[7:0]};
          BREV8: a3_d = brev8_reversed;
          XPERM8: a3_d = xperm8_result;
          XPERM4: a3_d = xperm4_result;
          default: ;
        endcase
        if (s3_op == PACK_W && G6LCCfg.IS_XLEN64)
          a3_d = {{32{s3_b[15]}}, {s3_b[15:0]}, {s3_a[15:0]}};
        if (G6LCCfg.IS_XLEN32) begin
          if (s3_op == UNZIP) a3_d = G6LCCfg.XLEN'(unzip_gen);
          if (s3_op == ZIP) a3_d = G6LCCfg.XLEN'(zip_gen);
        end
      end
    end

    // -------------------------------------------------------
    // hyp8 r5: A3 output register + slot-class pipe. result3_q is the
    // registered A3 result (three cycles after fu_data_i, LAT_ALU_FULL).
    // a3cls1/2/3_q track the class of the op in each result slot so
    // result_o (and the ex_stage lane) can pick the due record; the
    // take-gate's WB reservation guarantees at most one FLU_WB record is
    // due per cycle. fwd_tid3_q is the sel_r forward source identity.
    // -------------------------------------------------------
    always_ff @(posedge clk_i or negedge rst_ni) begin : alu_a3_reg
      if (!rst_ni) begin
        result3_q  <= '0;
        fwd_tid3_q <= '0;
        a3cls1_q   <= 1'b0;
        a3cls2_q   <= 1'b0;
        a3cls3_q   <= 1'b0;
      end else begin
        result3_q  <= a3_d;
        fwd_tid3_q <= fwd_tid2_q;
        a3cls1_q   <= alu_is_a3(fu_data_i.operation);
        a3cls2_q   <= a3cls1_q;
        a3cls3_q   <= a3cls2_q;
      end
    end
    assign result_o       = (A3EN && a3cls3_q) ? result3_q : result_q;
    assign alu_fwd_tid_o  = fwd_tid_q;
    assign alu_fwd_qtid_o = fwd_tid2_q;
    assign alu_fwd_rtid_o = A3EN ? fwd_tid3_q : fwd_tid2_q;
    assign alu_s2_a3_o    = A3EN & a3cls2_q;
    assign alu_s3_a3_o    = A3EN & a3cls3_q;
    assign alu_result_d_o = result_d;

    // -------------------------------------------------------
    // hyp8 r5: retimed-original reference. ref_d is the pre-split A2
    // result cone evaluated VERBATIM on the A1 registers -- what the
    // two-stage ALU would have registered into result_q next edge. The
    // A3 form registers the same cone (on a2_q = the A1 record one cycle
    // later) into result3_q, so for an A3-class op a3_d equals the
    // reference one cycle late; for a LAT_ALU_LOW op result_d equals the
    // reference in the same cycle. Assertion fences per project
    // convention; sim-only duplicate transforms under translate_off.
    // -------------------------------------------------------
// pragma translate_off
`ifndef VERILATOR
    if (A3EN) begin : g_a3_ref
      logic [G6LCCfg.XLEN:0] ref_srr, ref_srr32;
      logic [G6LCCfg.XLEN-1:0] ref_slr, ref_shift;
      logic [          31:0] ref_slr32, ref_shift32;
      always_comb begin
        ref_srr = {((op_q == SRA) | (G6LCCfg.IS_XLEN64 && op_q == SRAW)) & a_q[G6LCCfg.XLEN-1],
                   shl_q ? {<<{a_q}} : a_q};
        if (shamt_hi_q[2]) ref_srr = $unsigned($signed(ref_srr) >>> 32);
        if (shamt_hi_q[1]) ref_srr = $unsigned($signed(ref_srr) >>> 16);
        if (shamt_hi_q[0]) ref_srr = $unsigned($signed(ref_srr) >>> 8);
        for (int l = 2; l >= 0; l--)
          if (shamt_q[l]) ref_srr = $unsigned($signed(ref_srr) >>> (1 << l));
        ref_srr32 = {((op_q == SRA) | (G6LCCfg.IS_XLEN64 && op_q == SRAW)) & a_q[31],
                     shl_q ? {<<{a_q[31:0]}} : a_q[31:0]};
        if (shamt_hi_q[1]) ref_srr32 = $unsigned($signed(ref_srr32) >>> 16);
        if (shamt_hi_q[0]) ref_srr32 = $unsigned($signed(ref_srr32) >>> 8);
        for (int l = 2; l >= 0; l--)
          if (shamt_q[l]) ref_srr32 = $unsigned($signed(ref_srr32) >>> (1 << l));
      end
      for (genvar j = 0; j < G6LCCfg.XLEN; j++)
        assign ref_slr[j] = ref_srr[G6LCCfg.XLEN-1-j];
      for (genvar j = 0; j < 32; j++)
        assign ref_slr32[j] = ref_srr32[31-j];
      assign ref_shift   = shl_q ? ref_slr : ref_srr[G6LCCfg.XLEN-1:0];
      assign ref_shift32 = shl_q ? ref_slr32 : ref_srr32[31:0];

      logic [  $clog2(G6LCCfg.XLEN) : 0] ref_cpop;
      logic [$clog2(G6LCCfg.XLEN)-1 : 0] ref_lz;
      logic [4:0] ref_lzw;
      logic ref_lze, ref_lzwe;
      logic [31:0] ref_orcb, ref_rev8;
      logic [G6LCCfg.XLEN-1:0] ref_orcbw, ref_rev8w;
      logic [G6LCCfg.XLEN-1:0] ref_brev8;
      logic [31:0] ref_zip, ref_unzip;
      logic [G6LCCfg.XLEN-1:0] ref_xp8, ref_xp4;
      logic [31:0] ref_rolw, ref_rorw;
      logic [G6LCCfg.XLEN-1:0] ref_d;
      logic [G6LCCfg.XLEN-1:0] bit_indx;
      assign bit_indx = G6LCCfg.RVB ? G6LCCfg.XLEN'(1) << b_q[$clog2(G6LCCfg.XLEN)-1:0]
                                    : '0;

      if (G6LCCfg.RVB) begin : ref_bitmanip
        popcount #(.INPUT_WIDTH(G6LCCfg.XLEN)) i_ref_cpop (
            .data_i(ac_q), .popcount_o(ref_cpop));
        g6lc_hyp_lzc #(.WIDTH(G6LCCfg.XLEN), .MODE(1)) i_ref_lzc (
            .in_i(ab_q), .cnt_o(ref_lz), .empty_o(ref_lze));
        if (G6LCCfg.IS_XLEN64) begin
          g6lc_hyp_lzc #(.WIDTH(32), .MODE(1)) i_ref_lzc32 (
              .in_i(ab_q[31:0]), .cnt_o(ref_lzw), .empty_o(ref_lzwe));
        end else begin
          assign ref_lzw = '0;
          assign ref_lzwe = 1'b0;
        end
        assign ref_orcb = {
          {8{|a_q[31:24]}}, {8{|a_q[23:16]}}, {8{|a_q[15:8]}}, {8{|a_q[7:0]}}
        };
        assign ref_rev8 = {{a_q[7:0]}, {a_q[15:8]}, {a_q[23:16]}, {a_q[31:24]}};
        if (G6LCCfg.IS_XLEN64) begin : ref_orcb_64b
          assign ref_orcbw = {
            {8{|a_q[63:56]}}, {8{|a_q[55:48]}}, {8{|a_q[47:40]}}, {8{|a_q[39:32]}},
            ref_orcb
          };
          assign ref_rev8w = {
            ref_rev8, {a_q[39:32]}, {a_q[47:40]}, {a_q[55:48]}, {a_q[63:56]}
          };
        end else begin : ref_orcb_32b
          assign ref_orcbw = ref_orcb;
          assign ref_rev8w = ref_rev8;
        end
      end else begin : ref_no_bitmanip
        assign ref_cpop = '0;
        assign ref_lz = '0;
        assign ref_lzw = '0;
        assign ref_lze = 1'b0;
        assign ref_lzwe = 1'b0;
        assign ref_orcb = '0;
        assign ref_rev8 = '0;
        assign ref_orcbw = '0;
        assign ref_rev8w = '0;
      end

      if (G6LCCfg.ZKN && G6LCCfg.RVB) begin : ref_zkn
        for (genvar i = 0; i < (G6LCCfg.XLEN / 8); i++) begin : ref_xp8_gen
          logic [7:0] xi;
          assign xi = b_q[i << 3 +: 8];
          assign ref_xp8[i << 3 +: 8] = (xi < 8'(G6LCCfg.XLEN / 8))
              ? a_q[{xi[$clog2(G6LCCfg.XLEN)-4:0], 3'b0} +: 8]
              : 8'b0;
          for (genvar m = 0; m < 8; m++) begin : ref_rv
            assign ref_brev8[(i<<3)+m] = a_q[(i<<3)+(7-m)];
          end
        end
        for (genvar q = 0; q < (G6LCCfg.XLEN / 4); q++) begin : ref_xp4_gen
          assign ref_xp4[q << 2 +: 4] = (8'(b_q[q << 2 +: 4]) < 8'(G6LCCfg.XLEN / 4))
              ? a_q[{b_q[q << 2 +: 4], 2'b0} +: 4]
              : 4'b0;
        end
        if (G6LCCfg.IS_XLEN32) begin
          for (genvar n = 0; n < 16; n++) begin : ref_zip_gen
            assign ref_zip[n<<1] = a_q[n];
            assign ref_zip[(n<<1)+1] = a_q[n+16];
            assign ref_unzip[n] = a_q[n<<1];
            assign ref_unzip[n+16] = a_q[(n<<1)+1];
          end
        end else begin
          assign ref_zip = '0;
          assign ref_unzip = '0;
        end
      end else begin : ref_no_zkn
        assign ref_xp8 = '0;
        assign ref_xp4 = '0;
        assign ref_brev8 = '0;
        assign ref_zip = '0;
        assign ref_unzip = '0;
      end

      always_comb begin : ref_result_mux
        ref_d = '0;
        ref_rolw = '0;
        ref_rorw = '0;
        if (G6LCCfg.IS_XLEN64) begin
          unique case (op_q)
            ADDW, SUBW: ref_d = {{G6LCCfg.XLEN - 32{adder_result[31]}}, adder_result[31:0]};
            SH1ADDUW, SH2ADDUW, SH3ADDUW: ref_d = adder_result;
            SLLW, SRLW, SRAW:
            ref_d = {{G6LCCfg.XLEN - 32{ref_shift32[31]}}, ref_shift32[31:0]};
            default: ;
          endcase
        end
        unique case (op_q)
          ANDL, ANDN: ref_d = a_q & bneg_q[G6LCCfg.XLEN:1];
          ORL, ORN: ref_d = a_q | bneg_q[G6LCCfg.XLEN:1];
          XORL, XNOR: ref_d = a_q ^ bneg_q[G6LCCfg.XLEN:1];
          ADD, SUB, ADDUW, SH1ADD, SH2ADD, SH3ADD: ref_d = adder_result;
          SLL, SRL, SRA: ref_d = G6LCCfg.IS_XLEN64 ? ref_shift : G6LCCfg.XLEN'(ref_shift32);
          SLTS, SLTU: ref_d = {{G6LCCfg.XLEN - 1{1'b0}}, less};
          default: ;
        endcase
        if (G6LCCfg.RVB) begin
          if (G6LCCfg.IS_XLEN64) begin
            ref_rolw = (a_q[31:0] << b_q[4:0]) | (a_q[31:0] >> (5'd0 - b_q[4:0]));
            ref_rorw = (a_q[31:0] >> b_q[4:0]) | (a_q[31:0] << (5'd0 - b_q[4:0]));
            unique case (op_q)
              CLZW, CTZW:
              ref_d = (ref_lzwe) ? 32 : {{G6LCCfg.XLEN - 5{1'b0}}, ref_lzw};
              ROLW: ref_d = {{G6LCCfg.XLEN - 32{ref_rolw[31]}}, ref_rolw};
              RORW, RORIW: ref_d = {{G6LCCfg.XLEN - 32{ref_rorw[31]}}, ref_rorw};
              default: ;
            endcase
          end
          unique case (op_q)
            MAX:  ref_d = less ? b_q : a_q;
            MAXU: ref_d = less ? b_q : a_q;
            MIN:  ref_d = ~less ? b_q : a_q;
            MINU: ref_d = ~less ? b_q : a_q;
            BCLR, BCLRI: ref_d = a_q & ~bit_indx;
            BEXT, BEXTI: ref_d = {{G6LCCfg.XLEN - 1{1'b0}}, |(a_q & bit_indx)};
            BINV, BINVI: ref_d = a_q ^ bit_indx;
            BSET, BSETI: ref_d = a_q | bit_indx;
            CLZ, CTZ:
            ref_d = (ref_lze) ? ({{G6LCCfg.XLEN - $clog2(G6LCCfg.XLEN) {1'b0}}, ref_lz} + 1)
                : {{G6LCCfg.XLEN - $clog2(G6LCCfg.XLEN) {1'b0}}, ref_lz};
            CPOP, CPOPW: ref_d = {{(G6LCCfg.XLEN - ($clog2(G6LCCfg.XLEN) + 1)) {1'b0}}, ref_cpop};
            SEXTB: ref_d = {{G6LCCfg.XLEN - 8{a_q[7]}}, a_q[7:0]};
            SEXTH: ref_d = {{G6LCCfg.XLEN - 16{a_q[15]}}, a_q[15:0]};
            ZEXTH: ref_d = {{G6LCCfg.XLEN - 16{1'b0}}, a_q[15:0]};
            ROL:
            ref_d = G6LCCfg.IS_XLEN64 ? ((a_q << b_q[5:0]) | (a_q >> (6'd0 - b_q[5:0]))) : ((a_q << b_q[4:0]) | (a_q >> (5'd0 - b_q[4:0])));
            ROR, RORI:
            ref_d = G6LCCfg.IS_XLEN64 ? ((a_q >> b_q[5:0]) | (a_q << (6'd0 - b_q[5:0]))) : ((a_q >> b_q[4:0]) | (a_q << (5'd0 - b_q[4:0])));
            ORCB: ref_d = ref_orcbw;
            REV8: ref_d = ref_rev8w;
            default:
            if (op_q == SLLIUW && G6LCCfg.IS_XLEN64)
              ref_d = {{32{1'b0}}, a_q[31:0]} << b_q[5:0];
          endcase
        end
        if (G6LCCfg.RVZiCond) begin
          unique case (op_q)
            CZERO_EQZ: ref_d = (|b_q) ? a_q : '0;
            CZERO_NEZ: ref_d = (|b_q) ? '0 : a_q;
            default: ;
          endcase
        end
        if (G6LCCfg.ZKN && G6LCCfg.RVB) begin
          unique case (op_q)
            PACK:
            ref_d = G6LCCfg.IS_XLEN32 ? G6LCCfg.XLEN'({b_q[15:0], a_q[15:0]}) : {b_q[31:0], a_q[31:0]};
            PACK_H:
            ref_d = G6LCCfg.IS_XLEN32 ? G6LCCfg.XLEN'({16'b0, b_q[7:0], a_q[7:0]}) : {48'b0, b_q[7:0], a_q[7:0]};
            BREV8: ref_d = ref_brev8;
            XPERM8: ref_d = ref_xp8;
            XPERM4: ref_d = ref_xp4;
            default: ;
          endcase
          if (op_q == PACK_W && G6LCCfg.IS_XLEN64)
            ref_d = {{32{b_q[15]}}, {b_q[15:0]}, {a_q[15:0]}};
          if (G6LCCfg.IS_XLEN32) begin
            if (op_q == UNZIP) ref_d = G6LCCfg.XLEN'(ref_unzip);
            if (op_q == ZIP) ref_d = G6LCCfg.XLEN'(ref_zip);
          end
        end
      end

      // A3-class op: the new A3 comb equals the retimed original one
      // cycle later ($past(op_q) is the op now in the s3 slot).
      a_a3_retime : assert property (@(posedge clk_i) disable iff (!rst_ni)
          alu_is_a3($past(op_q)) |-> (a3_d == $past(ref_d)))
        else $fatal(1, "alu A3: full-result cone != retimed original (a3_d vs ref_d)");
      // LOW-class op: the A2 mux equals the original cone same-cycle.
      a_a2_low : assert property (@(posedge clk_i) disable iff (!rst_ni)
          !alu_is_a3(op_q) |-> (result_d == ref_d))
        else $fatal(1, "alu A3: low-class result_d != original A2 cone");
    end
`endif
// pragma translate_on

    // svt-stage: end A3
  end else begin : gen_comb
    // -------------------------------------------------------
    // AluStages==1: the original combinational ALU (emit base).
    // -------------------------------------------------------
    logic [G6LCCfg.XLEN-1:0] operand_a;
    logic [G6LCCfg.XLEN-1:0] operand_a_rev;
    logic [           31:0] operand_a_rev32;
    logic [G6LCCfg.XLEN-1:0] operand_b;
    logic [ G6LCCfg.XLEN:0] operand_b_neg;
    logic [G6LCCfg.XLEN+1:0] adder_result_ext_o;
    logic                    less;  // handles both signed and unsigned forms
    logic [           31:0] rolw;  // Rotate Left Word
    logic [           31:0] rorw;  // Rotate Right Word
    logic [31:0] orcbw, rev8w;
    logic [  $clog2(G6LCCfg.XLEN) : 0] cpop;  // Count Population
    logic [$clog2(G6LCCfg.XLEN)-1 : 0] lz_tz_count;  // Count Leading Zeros
    logic [                       4:0] lz_tz_wcount;  // Count Leading Zeros Word
    logic lz_tz_empty, lz_tz_wempty;
    logic [G6LCCfg.XLEN-1:0] orcbw_result, rev8w_result;

    logic [G6LCCfg.XLEN-1:0] brev8_reversed;
    logic [           31:0] unzip_gen;
    logic [           31:0] zip_gen;
    logic [G6LCCfg.XLEN-1:0] xperm8_result;
    logic [G6LCCfg.XLEN-1:0] xperm4_result;

    assign operand_a = fu_data_i.operand_a;
    assign operand_b = fu_data_i.operand_b;

    // hyp8: no low-half forward exists in the single-stage form; the
    // bypass source list simply skips it (IRO gates by latency class).
    assign alu_fwd_low_o = '0;
    assign alu_fwd_tid_o = '0;
    assign alu_fwd_qtid_o = '0;
    assign alu_fwd_rtid_o = '0;
    assign alu_s2_a3_o = 1'b0;
    assign alu_s3_a3_o = 1'b0;
    assign alu_result_d_o = '0;
    // verilator lint_off UNUSEDSIGNAL
    wire _unused_fwd = &{1'b0, fwd_a_i, fwd_b_i};
    // verilator lint_on UNUSEDSIGNAL

    for (genvar k = 0; k < G6LCCfg.XLEN; k++) assign operand_a_rev[k] = operand_a[G6LCCfg.XLEN-1-k];
    for (genvar k = 0; k < 32; k++) assign operand_a_rev32[k] = operand_a[31-k];

    logic adder_op_b_negate;
    logic operands_equal;
    logic [G6LCCfg.XLEN:0] adder_in_a, adder_in_b;
    logic [G6LCCfg.XLEN-1:0] adder_result;
    logic [G6LCCfg.XLEN-1:0] operand_a_bitmanip, bit_indx;
    logic [G6LCCfg.XLEN-1:0] operand_a_cpop;

    assign adder_op_b_negate = fu_data_i.operation inside {EQ, NE, SUB, SUBW, ANDN, ORN, XNOR};

    always_comb begin
      operand_a_bitmanip = operand_a;
      operand_a_cpop     = fu_data_cpop_i.operand_a;

      if (G6LCCfg.RVB) begin
        if (G6LCCfg.IS_XLEN64) begin
          unique case (fu_data_i.operation)
            SH1ADDUW:    operand_a_bitmanip = G6LCCfg.XLEN'(operand_a[31:0]) << 1;
            SH2ADDUW:    operand_a_bitmanip = G6LCCfg.XLEN'(operand_a[31:0]) << 2;
            SH3ADDUW:    operand_a_bitmanip = G6LCCfg.XLEN'(operand_a[31:0]) << 3;
            CTZW:        operand_a_bitmanip = G6LCCfg.XLEN'(operand_a_rev32);
            ADDUW, CLZW: operand_a_bitmanip = G6LCCfg.XLEN'(operand_a[31:0]);
            CPOPW:       operand_a_cpop = G6LCCfg.XLEN'(fu_data_cpop_i.operand_a[31:0]);
            default:     ;
          endcase
        end
        unique case (fu_data_i.operation)
          SH1ADD:  operand_a_bitmanip = operand_a << 1;
          SH2ADD:  operand_a_bitmanip = operand_a << 2;
          SH3ADD:  operand_a_bitmanip = operand_a << 3;
          CTZ:     operand_a_bitmanip = operand_a_rev;
          default: ;
        endcase
      end
    end

    // prepare operand a
    assign adder_in_a         = {operand_a_bitmanip, 1'b1};

    // prepare operand b
    assign operand_b_neg      = {operand_b, 1'b0} ^ {G6LCCfg.XLEN + 1{adder_op_b_negate}};
    assign adder_in_b         = operand_b_neg;

    // actual adder
    assign adder_result_ext_o = adder_in_a + adder_in_b;
    assign adder_result       = adder_result_ext_o[G6LCCfg.XLEN:1];
    // EQ/NE do not need the subtraction carry chain. For these opcodes the
    // bitmanip input is unchanged and (a-b)==0 iff a==b modulo 2^XLEN.
    assign operands_equal    = (operand_a == operand_b);

    // get the right branch comparison result
    if (HasBranch) begin
      always_comb begin : branch_resolve
        case (fu_data_i.operation)
          EQ:       alu_branch_res_o = operands_equal;
          NE:       alu_branch_res_o = ~operands_equal;
          LTS, LTU: alu_branch_res_o = less;
          GES, GEU: alu_branch_res_o = ~less;
          default:  alu_branch_res_o = 1'b1;
        endcase
      end
    end else begin
      assign alu_branch_res_o = 1'b0;
    end

    // ---------
    // Shifts
    // ---------
    logic                    shift_left;  // should we shift left
    logic                    shift_arithmetic;

    logic [G6LCCfg.XLEN-1:0] shift_amt;  // amount of shift, to the right
    logic [G6LCCfg.XLEN-1:0] shift_op_a;  // input of the shifter
    logic [           31:0] shift_op_a32;  // input to the 32 bit shift operation

    logic [G6LCCfg.XLEN-1:0] shift_result;
    logic [           31:0] shift_result32;

    logic [ G6LCCfg.XLEN:0] shift_right_result;
    logic [           32:0] shift_right_result32;

    logic [G6LCCfg.XLEN-1:0] shift_left_result;
    logic [           31:0] shift_left_result32;

    assign shift_amt = operand_b;

    assign shift_left = (fu_data_i.operation == SLL) | (G6LCCfg.IS_XLEN64 && fu_data_i.operation == SLLW);

    assign shift_arithmetic = (fu_data_i.operation == SRA) | (G6LCCfg.IS_XLEN64 && fu_data_i.operation == SRAW);

    logic [G6LCCfg.XLEN:0] shift_op_a_64;
    logic [32:0] shift_op_a_32;

    // choose the bit reversed or the normal input for shift operand a
    assign shift_op_a           = shift_left ? operand_a_rev : operand_a;
    assign shift_op_a32         = shift_left ? operand_a_rev32 : operand_a[31:0];

    assign shift_op_a_64        = {shift_arithmetic & shift_op_a[G6LCCfg.XLEN-1], shift_op_a};
    assign shift_op_a_32        = {shift_arithmetic & shift_op_a[31], shift_op_a32};

    assign shift_right_result   = $unsigned($signed(shift_op_a_64) >>> shift_amt[5:0]);

    assign shift_right_result32 = $unsigned($signed(shift_op_a_32) >>> shift_amt[4:0]);
    // bit reverse the shift_right_result for left shifts
    for (genvar j = 0; j < G6LCCfg.XLEN; j++)
      assign shift_left_result[j] = shift_right_result[G6LCCfg.XLEN-1-j];

    for (genvar j = 0; j < 32; j++) assign shift_left_result32[j] = shift_right_result32[31-j];

    assign shift_result   = shift_left ? shift_left_result : shift_right_result[G6LCCfg.XLEN-1:0];
    assign shift_result32 = shift_left ? shift_left_result32 : shift_right_result32[31:0];

    // ------------
    // Comparisons
    // ------------

    always_comb begin
      logic sgn;
      sgn = 1'b0;

      if ((fu_data_i.operation == SLTS) ||
              (fu_data_i.operation == LTS)  ||
              (fu_data_i.operation == GES)  ||
              (fu_data_i.operation == MAX)  ||
              (fu_data_i.operation == MIN))
        sgn = 1'b1;

      less = ($signed({sgn & operand_a[G6LCCfg.XLEN-1], operand_a}) <
              $signed({sgn & operand_b[G6LCCfg.XLEN-1], operand_b}));
    end

    if (G6LCCfg.RVB) begin : gen_bitmanip
      // Count Population + Count population Word
      popcount #(
          .INPUT_WIDTH(G6LCCfg.XLEN)
      ) i_cpop_count (
          .data_i    (operand_a_cpop),
          .popcount_o(cpop)
      );

      // Count Leading/Trailing Zeros
      // 64b
      g6lc_hyp_lzc #(
          .WIDTH(G6LCCfg.XLEN),
          .MODE (1)
      ) i_clz_64b (
          .in_i(operand_a_bitmanip),
          .cnt_o(lz_tz_count),
          .empty_o(lz_tz_empty)
      );
      if (G6LCCfg.IS_XLEN64) begin
        //32b
        g6lc_hyp_lzc #(
            .WIDTH(32),
            .MODE (1)
        ) i_clz_32b (
            .in_i(operand_a_bitmanip[31:0]),
            .cnt_o(lz_tz_wcount),
            .empty_o(lz_tz_wempty)
        );
      end else begin
        assign lz_tz_wcount = '0;
        assign lz_tz_wempty = 1'b0;
      end
    end else begin : gen_no_bitmanip
      assign cpop = '0;
      assign lz_tz_count = '0;
      assign lz_tz_wcount = '0;
      assign lz_tz_empty = 1'b0;
      assign lz_tz_wempty = 1'b0;
    end

    if (G6LCCfg.RVB) begin : gen_orcbw_rev8w_results
      assign orcbw = {
        {8{|operand_a[31:24]}}, {8{|operand_a[23:16]}}, {8{|operand_a[15:8]}}, {8{|operand_a[7:0]}}
      };
      assign rev8w = {{operand_a[7:0]}, {operand_a[15:8]}, {operand_a[23:16]}, {operand_a[31:24]}};
      if (G6LCCfg.IS_XLEN64) begin : gen_64b
        assign orcbw_result = {
          {8{|operand_a[63:56]}},
          {8{|operand_a[55:48]}},
          {8{|operand_a[47:40]}},
          {8{|operand_a[39:32]}},
          orcbw
        };
        assign rev8w_result = {
          rev8w, {operand_a[39:32]}, {operand_a[47:40]}, {operand_a[55:48]}, {operand_a[63:56]}
        };
      end else begin : gen_32b
        assign orcbw_result = orcbw;
        assign rev8w_result = rev8w;
      end
    end else begin : gen_no_orcbw
      assign orcbw_result = '0;
      assign rev8w_result = '0;
    end

    // ZKN gen block
    if (G6LCCfg.ZKN && G6LCCfg.RVB) begin : zkn_gen_block
      for (genvar i = 0; i < (G6LCCfg.XLEN / 8); i++) begin : brev8_xperm8_gen
        logic [7:0] xperm8_idx;
        assign xperm8_idx = operand_b[i << 3 +: 8];
        assign xperm8_result[i << 3 +: 8] = (xperm8_idx < 8'(G6LCCfg.XLEN / 8))
            ? operand_a[{xperm8_idx[$clog2(G6LCCfg.XLEN)-4:0], 3'b0} +: 8]
            : 8'b0;
        for (genvar m = 0; m < 8; m++) begin : reverse_bits
          assign brev8_reversed[(i<<3)+m] = operand_a[(i<<3)+(7-m)];
        end
      end
      for (genvar q = 0; q < (G6LCCfg.XLEN / 4); q++) begin : xperm4_gen
        assign xperm4_result[q << 2 +: 4] = (8'(operand_b[q << 2 +: 4]) < 8'(G6LCCfg.XLEN / 4))
            ? operand_a[{operand_b[q << 2 +: 4], 2'b0} +: 4]
            : 4'b0;
      end
      if (G6LCCfg.IS_XLEN32) begin
        for (genvar n = 0; n < 16; n++) begin : zip_unzip_gen
          assign zip_gen[n<<1] = operand_a[n];
          assign zip_gen[(n<<1)+1] = operand_a[n+16];
          assign unzip_gen[n] = operand_a[n<<1];
          assign unzip_gen[n+16] = operand_a[(n<<1)+1];
        end
      end else begin
        assign zip_gen = '0;
        assign unzip_gen = '0;
      end
    end else begin : no_zkn_gen
      assign xperm8_result = '0;
      assign xperm4_result = '0;
      assign brev8_reversed = '0;
      assign zip_gen = '0;
      assign unzip_gen = '0;
    end

    // -----------
    // Result MUX
    // -----------
    always_comb begin
      result_o = '0;
      bit_indx = '0;
      rolw = '0;
      rorw = '0;
      if (G6LCCfg.IS_XLEN64) begin
        unique case (fu_data_i.operation)
          ADDW, SUBW: result_o = {{G6LCCfg.XLEN - 32{adder_result[31]}}, adder_result[31:0]};
          SH1ADDUW, SH2ADDUW, SH3ADDUW: result_o = adder_result;
          SLLW, SRLW, SRAW:
          result_o = {{G6LCCfg.XLEN - 32{shift_result32[31]}}, shift_result32[31:0]};
          default: ;
        endcase
      end
      unique case (fu_data_i.operation)
        ANDL, ANDN: result_o = operand_a & operand_b_neg[G6LCCfg.XLEN:1];
        ORL, ORN: result_o = operand_a | operand_b_neg[G6LCCfg.XLEN:1];
        XORL, XNOR: result_o = operand_a ^ operand_b_neg[G6LCCfg.XLEN:1];
        ADD, SUB, ADDUW, SH1ADD, SH2ADD, SH3ADD: result_o = adder_result;
        SLL, SRL, SRA: result_o = G6LCCfg.IS_XLEN64 ? shift_result : G6LCCfg.XLEN'(shift_result32);
        SLTS, SLTU: result_o = {{G6LCCfg.XLEN - 1{1'b0}}, less};
        default: ;
      endcase

      if (G6LCCfg.RVB) begin
        bit_indx = G6LCCfg.XLEN'(1) << operand_b[$clog2(G6LCCfg.XLEN)-1:0];
        if (G6LCCfg.IS_XLEN64) begin
          rolw = (operand_a[31:0] << operand_b[4:0]) | (operand_a[31:0] >> (5'd0 - operand_b[4:0]));
          rorw = (operand_a[31:0] >> operand_b[4:0]) | (operand_a[31:0] << (5'd0 - operand_b[4:0]));
          unique case (fu_data_i.operation)
            CLZW, CTZW:
            result_o = (lz_tz_wempty) ? 32 : {{G6LCCfg.XLEN - 5{1'b0}}, lz_tz_wcount};
            ROLW: result_o = {{G6LCCfg.XLEN - 32{rolw[31]}}, rolw};
            RORW, RORIW: result_o = {{G6LCCfg.XLEN - 32{rorw[31]}}, rorw};
            default: ;
          endcase
        end
        unique case (fu_data_i.operation)
          MAX:  result_o = less ? operand_b : operand_a;
          MAXU: result_o = less ? operand_b : operand_a;
          MIN:  result_o = ~less ? operand_b : operand_a;
          MINU: result_o = ~less ? operand_b : operand_a;

          BCLR, BCLRI: result_o = operand_a & ~bit_indx;
          BEXT, BEXTI: result_o = {{G6LCCfg.XLEN - 1{1'b0}}, |(operand_a & bit_indx)};
          BINV, BINVI: result_o = operand_a ^ bit_indx;
          BSET, BSETI: result_o = operand_a | bit_indx;

          CLZ, CTZ:
          result_o = (lz_tz_empty) ? ({{G6LCCfg.XLEN - $clog2(G6LCCfg.XLEN) {1'b0}}, lz_tz_count} + 1)
              : {{G6LCCfg.XLEN - $clog2(G6LCCfg.XLEN) {1'b0}}, lz_tz_count};

          CPOP, CPOPW: result_o = {{(G6LCCfg.XLEN - ($clog2(G6LCCfg.XLEN) + 1)) {1'b0}}, cpop};

          SEXTB: result_o = {{G6LCCfg.XLEN - 8{operand_a[7]}}, operand_a[7:0]};
          SEXTH: result_o = {{G6LCCfg.XLEN - 16{operand_a[15]}}, operand_a[15:0]};
          ZEXTH: result_o = {{G6LCCfg.XLEN - 16{1'b0}}, operand_a[15:0]};

          ROL:
          result_o = G6LCCfg.IS_XLEN64 ? ((operand_a << operand_b[5:0]) | (operand_a >> (6'd0 - operand_b[5:0]))) : ((operand_a << operand_b[4:0]) | (operand_a >> (5'd0 - operand_b[4:0])));

          ROR, RORI:
          result_o = G6LCCfg.IS_XLEN64 ? ((operand_a >> operand_b[5:0]) | (operand_a << (6'd0 - operand_b[5:0]))) : ((operand_a >> operand_b[4:0]) | (operand_a << (5'd0 - operand_b[4:0])));

          ORCB: result_o = orcbw_result;
          REV8: result_o = rev8w_result;

          default:
          if (fu_data_i.operation == SLLIUW && G6LCCfg.IS_XLEN64)
            result_o = {{G6LCCfg.XLEN-32{1'b0}}, operand_a[31:0]} << operand_b[5:0];
        endcase
      end
      if (G6LCCfg.RVZiCond) begin
        unique case (fu_data_i.operation)
          CZERO_EQZ:
          result_o = (|operand_b) ? operand_a : '0;
          CZERO_NEZ:
          result_o = (|operand_b) ? '0 : operand_a;
          default: ;
        endcase
      end
      if (G6LCCfg.ZKN && G6LCCfg.RVB) begin
        unique case (fu_data_i.operation)
          PACK:
          result_o = G6LCCfg.IS_XLEN32 ? G6LCCfg.XLEN'({operand_b[15:0], operand_a[15:0]}) : {operand_b[31:0], operand_a[31:0]};
          PACK_H:
          result_o = G6LCCfg.IS_XLEN32 ? G6LCCfg.XLEN'({16'b0, operand_b[7:0], operand_a[7:0]}) : {48'b0, operand_b[7:0], operand_a[7:0]};
          BREV8: result_o = brev8_reversed;
          XPERM8: result_o = xperm8_result;
          XPERM4: result_o = xperm4_result;
          default: ;
        endcase
        if (fu_data_i.operation == PACK_W && G6LCCfg.IS_XLEN64)
          result_o = {{32{operand_b[15]}}, {operand_b[15:0]}, {operand_a[15:0]}};
        if (G6LCCfg.IS_XLEN32) begin
          if (fu_data_i.operation == UNZIP) result_o = G6LCCfg.XLEN'(unzip_gen);
          if (fu_data_i.operation == ZIP) result_o = G6LCCfg.XLEN'(zip_gen);
        end
      end
    end
  end

  // clk_i/rst_ni are unused when AluStages==1 (no registers exist then).
  // They stay in the port list: the public interface is fixed.
  // verilator lint_off UNUSEDSIGNAL
  wire _unused_clk = clk_i;
  wire _unused_rst = rst_ni;
  // verilator lint_on UNUSEDSIGNAL

  // svt-stage: class A1 value
  // svt-stage: class A2 value
  // svt-stage: class A3 value
endmodule
