// hyp8 provenance: ADAPTED (sv-timing emit base, staged alignment + 32/32 digit step)
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
// Author: Michael Schaffner <schaffner@iis.ee.ethz.ch>, ETH Zurich
//         Andreas Traber    <traber@iis.ee.ethz.ch>, ETH Zurich
//
// Description: simple 64-bit serial divider (one quotient digit per cycle).
//
// hyp8 (group 7): two timing edits on the recurrence, semantics unchanged.
//  1. A NORM state between IDLE and DIVIDE: the leading-zero counts are
//     registered at accept (comb from the live inputs), then div_shift and
//     the left-shifted divisor land in op_b_q one cycle later. This splits
//     the old input->lzc->div_shift->barrel-shift->op_b_q cone. +1 cycle on
//     the (already multi-cycle) divide latency; in_rdy_o behaviour is
//     unchanged -- STABLE_HANDSHAKE=0 still deasserts in_rdy_o in the accept
//     cycle, so the caller sees the same handshake.
//  2. The DIVIDE digit step computes the 64-bit subtract as a carry-select
//     pair: low 32-bit difference plus two speculative high halves
//     (borrow / no-borrow), selected by the registered-width carry-out of
//     the low half in the same cycle. ab_comp (a==b, a>b unsigned) is
//     derived from that same difference, so the reg->reg digit step is a
//     32-bit add + a borrow select instead of a 64-bit subtract + a 64-bit
//     compare in series. Still exactly one quotient digit per cycle.
//     flush_i is unchanged: it drops the FSM to IDLE and clears enables.
//     No port changes.

module serdiv
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter WIDTH = 64,
    parameter STABLE_HANDSHAKE = 0             // Guarantee a stable in_rdy_o during the input handshake. Keep it at 0.
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Serdiv translation ID - Mult
    input logic [G6LCCfg.TRANS_ID_BITS-1:0] id_i,
    // A operand - Mult
    input logic [WIDTH-1:0] op_a_i,
    // B operand - Mult
    input logic [WIDTH-1:0] op_b_i,
    // Serdiv operation - Mult
    input logic [1:0] opcode_i,  // 0: udiv, 2: urem, 1: div, 3: rem
    // Serdiv instruction is valid - Mult
    input logic in_vld_i,
    // Serdiv FU is ready - Mult
    output logic in_rdy_o,
    // Flush - CONTROLLER
    input logic flush_i,
    // Serdiv result is valid - Mult
    output logic out_vld_o,
    // Serdiv is ready - Mult
    input logic out_rdy_i,
    // Serdiv transaction ID - Mult
    output logic [G6LCCfg.TRANS_ID_BITS-1:0] id_o,
    // Serdiv result - Mult
    output logic [WIDTH-1:0] res_o
);

  /////////////////////////////////////
  // signal declarations
  /////////////////////////////////////

  enum logic [1:0] {
    IDLE,
    NORM,   // hyp8: alignment stage (div_shift + shifted divisor)
    DIVIDE,
    FINISH
  }
      state_d, state_q;

  logic [WIDTH-1:0] res_q, res_d;
  logic [WIDTH-1:0] op_a_q, op_a_d;
  logic [WIDTH-1:0] op_b_q, op_b_d;
  logic op_a_sign, op_b_sign;
  logic op_b_zero, op_b_zero_q, op_b_zero_d;
  logic op_b_neg_one, op_b_neg_one_q, op_b_neg_one_d;

  logic [G6LCCfg.TRANS_ID_BITS-1:0] id_q, id_d;

  logic rem_sel_d, rem_sel_q;
  logic comp_inv_d, comp_inv_q;
  logic res_inv_d, res_inv_q;

  logic [WIDTH-1:0] b_mux;
  logic [WIDTH-1:0] out_mux;

  logic [$clog2(WIDTH)-1:0] cnt_q, cnt_d;
  logic cnt_zero;

  logic [WIDTH-1:0] lzc_a_input, lzc_b_input, op_b;
  logic [$clog2(WIDTH)-1:0] lzc_a_result, lzc_b_result;
  logic [$clog2(WIDTH)-1:0] lzc_a_q, lzc_b_q;
  logic [  $clog2(WIDTH+1):0] div_shift;

  logic a_reg_en, b_reg_en, res_reg_en, ab_comp, load_en, norm_en;
  logic lzc_a_no_one, lzc_b_no_one;
  logic div_res_zero_d, div_res_zero_q;

  // hyp8: raw operands captured at accept; the sign/zero work reads these
  // in NORM instead of recomputing from the inputs in the accept cycle.
  logic [WIDTH-1:0] op_a_raw_q, op_b_raw_q;
  logic [1:0] opcode_q;

  /////////////////////////////////////
  // align the input operands
  // for faster division
  /////////////////////////////////////

  assign op_a_sign    = op_a_i[$high(op_a_i)];
  assign op_b_sign    = op_b_i[$high(op_b_i)];
  assign op_b_zero    = lzc_b_no_one & ~op_b_sign;
  assign op_b_neg_one = lzc_b_no_one & op_b_sign;

  assign lzc_a_input  = (opcode_i[0] & op_a_sign) ? {~op_a_i[$high(op_a_i)-1:0], 1'b1} : op_a_i;
  assign lzc_b_input  = (opcode_i[0] & op_b_sign) ? ~op_b_i : op_b_i;

  g6lc_hyp_lzc #(
      .MODE (1),     // count leading zeros
      .WIDTH(WIDTH)
  ) i_lzc_a (
      .in_i   (lzc_a_input),
      .cnt_o  (lzc_a_result),
      .empty_o(lzc_a_no_one)
  );

  g6lc_hyp_lzc #(
      .MODE (1),     // count leading zeros
      .WIDTH(WIDTH)
  ) i_lzc_b (
      .in_i   (lzc_b_input),
      .cnt_o  (lzc_b_result),
      .empty_o(lzc_b_no_one)
  );

  // hyp8: shift_a/div_shift/op_b are computed in NORM from the registered
  // counts and operands.
  logic [$clog2(WIDTH+1)-1:0] shift_a_n;
  assign shift_a_n = (op_a_raw_q == '0) ? $clog2(WIDTH+1)'(WIDTH) : {1'b0, lzc_a_q};
  assign div_shift = {1'b0, lzc_b_q} - shift_a_n;
  assign op_b = op_b_raw_q <<< div_shift;

  // the division is zero if |opB| > |opA| and can be terminated
  // hyp8: evaluated in NORM (norm_en) instead of the accept cycle (load_en).
  assign div_res_zero_d = (norm_en) ? div_shift[$high(div_shift)] : div_res_zero_q;

  /////////////////////////////////////
  // Datapath
  /////////////////////////////////////

  logic pm_sel_q;
  // hyp8: pm_sel is decided at accept and registered; in DIVIDE the step
  // always subtracts (pm_sel_q==0), matching the original where
  // pm_sel = load_en & ... is 0 outside the load cycle.
  assign b_mux = (norm_en) ? op_b : {comp_inv_q, (op_b_q[$high(op_b_q):1])};

  // in case of bad timing, we could output from regs -> needs a cycle more in the FSM
  assign out_mux     = (rem_sel_q) ? (op_b_neg_one_q ? '0 : op_a_q) : (op_b_zero_q ? '1 : (op_b_neg_one_q ? op_a_q : res_q));

  // invert if necessary
  assign res_o = (res_inv_q) ? -$signed(out_mux) : out_mux;

  // hyp8: carry-select 32/32 subtract. The low half's carry-out picks
  // between two speculative high halves; equality and unsigned-greater
  // come off the same difference, so the per-cycle step is a 32-bit add,
  // a borrow select and a zero check -- one quotient digit per cycle.
  localparam int unsigned HW = WIDTH / 2;
  logic [HW:0]       lo_diff;
  logic [HW:0]       hi_diff_b0, hi_diff_b1;
  logic [WIDTH-1:0]  step_diff;
  logic              step_borrow, step_zero, step_gt;
  logic [WIDTH-1:0]  add_out;

  assign lo_diff   = {1'b0, op_a_q[HW-1:0]} + {1'b0, ~op_b_q[HW-1:0]} + {{HW{1'b0}}, 1'b1};
  assign hi_diff_b0 = {1'b0, op_a_q[WIDTH-1:HW]} + {1'b0, ~op_b_q[WIDTH-1:HW]} + {{HW{1'b0}}, 1'b1};
  assign hi_diff_b1 = {1'b0, op_a_q[WIDTH-1:HW]} + {1'b0, ~op_b_q[WIDTH-1:HW]};

  assign step_diff = lo_diff[HW] ? {hi_diff_b0[HW-1:0], lo_diff[HW-1:0]}
                                 : {hi_diff_b1[HW-1:0], lo_diff[HW-1:0]};
  assign step_borrow = lo_diff[HW] ? ~hi_diff_b0[HW] : ~hi_diff_b1[HW];
  assign step_zero   = (step_diff == '0);
  assign step_gt     = ~step_borrow & ~step_zero;

  // at NORM the first partial remainder is +/- op_a (two's complement of
  // the captured operand); in DIVIDE it is the carry-select difference
  // op_a_q - op_b_q.
  assign add_out = (state_q == NORM) ? (pm_sel_q ? op_a_raw_q : (~op_a_raw_q + {{WIDTH-1{1'b0}}, 1'b1}))
                                     : step_diff;

  // main comparator (unsigned compare of the current remainder vs. the
  // shifted divisor, comp_inv flips the sense for the negative-divisor
  // convention exactly as the original).
  assign ab_comp = ((step_zero) | (step_gt ^ comp_inv_q)) & ((|op_a_q) | op_b_zero_q);

  /////////////////////////////////////
  // FSM, counter
  /////////////////////////////////////

  assign cnt_zero = (cnt_q == 0);
  assign cnt_d = (norm_en) ? div_shift[$clog2(WIDTH)-1:0] : (~cnt_zero) ? cnt_q - 1 : cnt_q;

  always_comb begin : p_fsm
    // default
    state_d    = state_q;
    in_rdy_o   = 1'b0;
    out_vld_o  = 1'b0;
    load_en    = 1'b0;
    norm_en    = 1'b0;
    a_reg_en   = 1'b0;
    b_reg_en   = 1'b0;
    res_reg_en = 1'b0;

    unique case (state_q)
      IDLE: begin
        in_rdy_o = 1'b1;

        if (in_vld_i) begin
          // upstream note: there is a cycle delay until the valid signal is asserted by the id stage
          // Ara:  we need a stable handshake
          in_rdy_o = (STABLE_HANDSHAKE) ? 1'b1 : 1'b0;
          // hyp8: capture raw operands + lzc counts; the shifted operand
          // and the flag resolution happen in NORM.
          load_en  = 1'b1;
          state_d  = NORM;
        end
      end
      NORM: begin
        // apply div_shift / shifted divisor / flags, then run digits
        norm_en    = 1'b1;
        a_reg_en   = 1'b1;   // load first partial remainder (add_out at load path)
        b_reg_en   = 1'b1;   // op_b (shifted divisor)
        res_reg_en = 1'b1;   // clear res (res_d load path)
        state_d    = DIVIDE;
      end
      DIVIDE: begin
        if (~(div_res_zero_q | op_b_zero_q | op_b_neg_one_q)) begin
          a_reg_en   = ab_comp;
          b_reg_en   = 1'b1;
          res_reg_en = 1'b1;
        end
        // can end the division immediately if the result is known
        if (div_res_zero_q | op_b_zero_q | op_b_neg_one_q) begin
          out_vld_o = 1'b1;
          state_d   = FINISH;
          if (out_rdy_i) begin
            state_d = IDLE;
          end
        end else if (cnt_zero) begin
          state_d = FINISH;
        end
      end
      FINISH: begin
        out_vld_o = 1'b1;

        if (out_rdy_i) begin
          state_d = IDLE;
        end
      end
      default: state_d = IDLE;
    endcase

    if (flush_i) begin
      a_reg_en = 1'b0;
      b_reg_en = 1'b0;
      load_en  = 1'b0;
      norm_en  = 1'b0;
      state_d  = IDLE;
    end
  end

  /////////////////////////////////////
  // regs, flags
  /////////////////////////////////////

  // hyp8: flags are resolved in NORM from the registered operands and the
  // registered lzc counts (identical values, one stage later).
  logic op_b_zero_n, op_b_neg_one_n, res_inv_n, comp_inv_n, lzc_b_full;
  // lzc_b_full mirrors lzc_b_no_one on the registered count: the lzc input
  // was all-zero iff the count equals WIDTH. (For all-zero op_b the count
  // wraps to 0 on the narrow lzc output; op_b_zero/neg_one then rely on
  // the operand bits -- matching the original where no_one comes straight
  // from the lzc, the raw sign still qualifies the flag.)
  assign lzc_b_full     = (lzc_b_q == $clog2(WIDTH)'(WIDTH));
  assign op_b_zero_n    = lzc_b_full & ~op_b_raw_q[$high(op_b_raw_q)];
  assign op_b_neg_one_n = lzc_b_full & op_b_raw_q[$high(op_b_raw_q)];
  assign res_inv_n      = (~op_b_zero_n | opcode_q[1]) & opcode_q[0] &
                          (op_a_raw_q[$high(op_a_raw_q)] ^ op_b_raw_q[$high(op_b_raw_q)] ^ op_b_neg_one_n);
  assign comp_inv_n     = opcode_q[0] & op_b_raw_q[$high(op_b_raw_q)];

  assign rem_sel_d      = (norm_en) ? opcode_q[1] : rem_sel_q;
  assign comp_inv_d     = (norm_en) ? comp_inv_n : comp_inv_q;
  assign op_b_zero_d    = (norm_en) ? op_b_zero_n : op_b_zero_q;
  assign op_b_neg_one_d = (norm_en) ? op_b_neg_one_n : op_b_neg_one_q;
  assign res_inv_d      = (norm_en) ? res_inv_n : res_inv_q;

  // transaction id
  assign id_d = (load_en) ? id_i : id_q;
  assign id_o = id_q;

  assign op_a_d = (a_reg_en) ? add_out : op_a_q;
  assign op_b_d = (b_reg_en) ? b_mux : op_b_q;
  assign res_d = (norm_en) ? '0 : (res_reg_en) ? {res_q[$high(res_q)-1:0], ab_comp} : res_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_regs
    if (~rst_ni) begin
      state_q        <= IDLE;
      op_a_q         <= '0;
      op_b_q         <= '0;
      op_a_raw_q     <= '0;
      op_b_raw_q     <= '0;
      opcode_q       <= '0;
      lzc_a_q        <= '0;
      lzc_b_q        <= '0;
      pm_sel_q       <= 1'b0;
      res_q          <= '0;
      cnt_q          <= '0;
      id_q           <= '0;
      rem_sel_q      <= 1'b0;
      comp_inv_q     <= 1'b0;
      res_inv_q      <= 1'b0;
      op_b_zero_q    <= 1'b0;
      op_b_neg_one_q <= 1'b0;
      div_res_zero_q <= 1'b0;
    end else begin
      state_q        <= state_d;
      op_a_q         <= op_a_d;
      op_b_q         <= op_b_d;
      res_q          <= res_d;
      cnt_q          <= cnt_d;
      id_q           <= id_d;
      rem_sel_q      <= rem_sel_d;
      comp_inv_q     <= comp_inv_d;
      res_inv_q      <= res_inv_d;
      op_b_zero_q    <= op_b_zero_d;
      op_b_neg_one_q <= op_b_neg_one_d;
      div_res_zero_q <= div_res_zero_d;
      if (load_en) begin
        op_a_raw_q <= op_a_i;
        op_b_raw_q <= op_b_i;
        opcode_q   <= opcode_i;
        lzc_a_q    <= lzc_a_result;
        lzc_b_q    <= lzc_b_result;
        pm_sel_q   <= ~(opcode_i[0] & (op_a_sign ^ op_b_sign));
      end
    end
  end

  // Accept-cycle comb flags (op_b_zero/op_b_neg_one and the lzc empty
  // outputs) are superseded by the NORM forms; keep them consumed.
  logic _unused;
  assign _unused = &{1'b0, lzc_a_no_one, lzc_b_no_one, op_b_zero, op_b_neg_one};

endmodule
