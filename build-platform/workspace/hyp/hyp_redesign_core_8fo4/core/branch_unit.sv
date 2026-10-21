// hyp8 provenance: REWRITTEN (sv-timing emit base, B1/B2 split, registered resolve)
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
// Author: Florian Zaruba, ETH Zurich
// Date: 09.05.2017
// Description: Branch target calculation and comparison
//
// hyp8 (group 7): two-stage resolve, same ports plus `flush_i`.
//   B1 (combinational, registered): jump-base select (JALR rs1 vs pc),
//     next_pc, the LOW half of the target add with carry-out, and every
//     input the resolution logic needs (fu_data fields, branch_predict
//     fields, v_i, hart_id, compressed/zcmt flags, branch_valid).
//   B2 (combinational, registered outputs): high half of the target add
//     with the registered carry, the compare/mispredict resolution
//     (verbatim from the emit case structure), the misaligned-target
//     exception, and the link value. resolved_branch_o, resolve_branch_o,
//     branch_exception_o and branch_result_o are all REGISTERS -- this is
//     the B2 output register that the scoreboard cancel window and the
//     frontend redirect record read (no extra register downstream).
// Resolve arrives two cycles after branch_valid_i (+2 on the
// mispredict-penalty path, rank 4). branch_comp_res_i is the ALU's A2
// output, which is valid in the same cycle B2 evaluates, so the compare
// and the target complete on the same boundary.
// Deviation from "ports identical": `flush_i` is added -- the emit's unit
// was combinational and held no state, but B1/B2 are now stateful and the
// kill contract requires flush to clear a captured wrong-path resolve
// (an output-only gate cannot: a stale B1 would still pulse the resolve
// one cycle after flush drops).

module branch_unit
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter g6lc_hyp_pkg::g6lc_hyp_cfg_t HypCfg = g6lc_hyp_pkg::HypDefault,
    parameter type bp_resolve_t = logic,
    parameter type branchpredict_sbe_t = logic,
    parameter type exception_t = logic,
    parameter type fu_data_t = logic
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // hyp8: pipeline flush -- clears the staged B1/B2 resolve records - CONTROLLER
    input logic flush_i,
    // Virtualization mode state - CSR_REGFILE
    input logic v_i,
    // Debug mode state - CSR_REGFILE
    input logic debug_mode_i,
    // FU data needed to execute instruction - ISSUE_STAGE
    input fu_data_t fu_data_i,
    // Instruction PC - ISSUE_STAGE
    input logic [G6LCCfg.VLEN-1:0] pc_i,
    // FSE S5: SMT hart of the resolving control-flow instruction
    input logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] hart_id_i,
    // Is zcmt instruction - ISSUE_STAGE
    input logic is_zcmt_i,
    // Instruction is compressed - ISSUE_STAGE
    input logic is_compressed_instr_i,
    // Branch unit instruction is valid - ISSUE_STAGE
    input logic branch_valid_i,
    // ALU branch compare result - ALU
    input logic branch_comp_res_i,
    // Brach unit result - ISSUE_STAGE
    output logic [G6LCCfg.VLEN-1:0] branch_result_o,
    // Information of branch prediction - ISSUE_STAGE
    input branchpredict_sbe_t branch_predict_i,
    // Signaling that we resolved the branch - ISSUE_STAGE
    output bp_resolve_t resolved_branch_o,
    // Branch is resolved, new entries can be accepted by scoreboard - ID_STAGE
    output logic resolve_branch_o,
    // Branch exception out - TO_BE_COMPLETED
    output exception_t branch_exception_o
);

  localparam int unsigned HW = G6LCCfg.VLEN / 2;

  // -------------------------------------------------------
  // svt-stage: begin B1
  // B1: capture + low-half target add (registered).
  // -------------------------------------------------------
  logic [G6LCCfg.VLEN-1:0] jump_base;
  logic [G6LCCfg.VLEN-1:0] next_pc;
  // I14: pc_i is the CF issue port (IRO / ex_stage pick). Not operand_c.
  assign jump_base = (fu_data_i.operation == g6lc_core_pkg::JALR)
                     ? fu_data_i.operand_a[G6LCCfg.VLEN-1:0]
                     : pc_i;
  assign next_pc   = pc_i + ((is_compressed_instr_i)
                     ? {{G6LCCfg.VLEN-2{1'b0}}, 2'h2}
                     : {{G6LCCfg.VLEN-3{1'b0}}, 3'h4});

  // B1 registers
  fu_op                              b1_op_q;
  logic                              b1_valid_q;
  logic [G6LCCfg.VLEN-1:0]           b1_pc_q;
  logic [G6LCCfg.VLEN-1:0]           b1_next_pc_q;
  logic [HW:0]                       b1_tgt_lo_q;     // low-half sum + carry
  logic [HW-1:0]                     b1_jb_hi_q;      // jump_base high half
  logic [HW-1:0]                     b1_imm_hi_q;     // imm high half
  logic                              b1_v_q;
  logic                              b1_zcmt_q;
  logic                              b1_is_br_q;      // op_is_branch(fu_data_i.operation)
  logic                              b1_is_jalr_q;
  logic [$clog2(G6LCCfg.NrHarts > 1 ? G6LCCfg.NrHarts : 2)-1:0] b1_hart_q;
  logic [G6LCCfg.TRANS_ID_BITS-1:0]  b1_tid_q;
  logic [G6LCCfg.VLEN-1:0]           b1_opa_q;        // jalr base / sib-jalr pick
  logic [G6LCCfg.VLEN-1:0]           b1_opb_q;
  logic [15:0]                       b1_opc_hi_q;
  // branch_predict fields the resolution reads
  logic [G6LCCfg.VLEN-1:0]           b1_pred_addr_q;
  logic                              b1_cf_is_branch_q;
  logic                              b1_cf_is_nocf_q;
  logic                              b1_cf_is_return_q;
  cf_t                               b1_cf_q;
  logic                              b1_is_call_q;
  logic                              b1_is_ret_q;
  logic                              b1_ckpt_v_q;
  logic [$bits(branch_predict_i.ckpt_idx)-1:0] b1_ckpt_idx_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : b1_regs
    if (!rst_ni) begin
      b1_valid_q       <= 1'b0;
      b1_op_q          <= ADD;
      b1_pc_q          <= '0;
      b1_next_pc_q     <= '0;
      b1_tgt_lo_q      <= '0;
      b1_jb_hi_q       <= '0;
      b1_imm_hi_q      <= '0;
      b1_v_q           <= 1'b0;
      b1_zcmt_q        <= 1'b0;
      b1_is_br_q       <= 1'b0;
      b1_is_jalr_q     <= 1'b0;
      b1_hart_q        <= '0;
      b1_tid_q         <= '0;
      b1_opa_q         <= '0;
      b1_opb_q         <= '0;
      b1_opc_hi_q      <= '0;
      b1_pred_addr_q   <= '0;
      b1_cf_is_branch_q <= 1'b0;
      b1_cf_is_nocf_q   <= 1'b0;
      b1_cf_is_return_q <= 1'b0;
      b1_cf_q          <= NoCF;
      b1_is_call_q     <= 1'b0;
      b1_is_ret_q      <= 1'b0;
      b1_ckpt_v_q      <= 1'b0;
      b1_ckpt_idx_q    <= '0;
    end else if (flush_i) begin
      b1_valid_q       <= 1'b0;
    end else begin
      b1_valid_q       <= branch_valid_i;
      b1_op_q          <= fu_data_i.operation;
      b1_pc_q          <= pc_i;
      b1_next_pc_q     <= next_pc;
      b1_tgt_lo_q      <= {1'b0, jump_base[HW-1:0]} + {1'b0, fu_data_i.imm[HW-1:0]};
      b1_jb_hi_q       <= jump_base[G6LCCfg.VLEN-1:HW];
      b1_imm_hi_q      <= fu_data_i.imm[G6LCCfg.VLEN-1:HW];
      b1_v_q           <= v_i;
      b1_zcmt_q        <= is_zcmt_i;
      b1_is_br_q       <= g6lc_core_pkg::op_is_branch(fu_data_i.operation);
      b1_is_jalr_q     <= (fu_data_i.operation == g6lc_core_pkg::JALR);
      b1_hart_q        <= hart_id_i;
      b1_tid_q         <= fu_data_i.trans_id;
      b1_opa_q         <= fu_data_i.operand_a[G6LCCfg.VLEN-1:0];
      b1_opb_q         <= fu_data_i.operand_b[G6LCCfg.VLEN-1:0];
      b1_opc_hi_q      <= fu_data_i.operand_c_hi[15:0];
      b1_pred_addr_q   <= branch_predict_i.predict_address;
      b1_cf_is_branch_q <= (branch_predict_i.cf == g6lc_core_pkg::Branch);
      b1_cf_is_nocf_q   <= (branch_predict_i.cf == g6lc_core_pkg::NoCF);
      b1_cf_is_return_q <= (branch_predict_i.cf == g6lc_core_pkg::Return);
      b1_cf_q          <= branch_predict_i.cf;
      b1_is_call_q     <= branch_predict_i.is_call;
      b1_is_ret_q      <= branch_predict_i.is_ret;
      b1_ckpt_v_q      <= branch_predict_i.ckpt_v;
      b1_ckpt_idx_q    <= branch_predict_i.ckpt_idx;
    end
  end

  // -------------------------------------------------------
  // svt-stage: end B1
  // svt-stage: begin B2
  // B2: high-half add + compare/mispredict resolution + exception.
  // branch_comp_res_i is the ALU A2 compare -- live in this cycle.
  // All B2 outputs are registered: the register IS the resolve record.
  // -------------------------------------------------------
  logic [G6LCCfg.VLEN-1:0] b2_target_address;
  logic [HW:0]             b2_tgt_hi;
  assign b2_tgt_hi = {1'b0, b1_jb_hi_q} + {1'b0, b1_imm_hi_q} + {{HW{1'b0}}, b1_tgt_lo_q[HW]};
  assign b2_target_address = {b2_tgt_hi[HW-1:0], b1_tgt_lo_q[HW-1:0]};
  // JALR clears the target LSB before the mispredict compare. Two 32-bit
  // compares instead of one unfolded VLEN compare. hyp8 VLEN is 64.
  logic [63:0] tgt64;
  logic        ne_lo, ne_hi, tgt_mis;
  assign tgt64   = {b2_target_address[63:1], b1_is_jalr_q ? 1'b0 : b2_target_address[0]};
  assign ne_lo   = tgt64[31:0] != b1_pred_addr_q[31:0];
  assign ne_hi   = tgt64[63:32] != b1_pred_addr_q[63:32];
  assign tgt_mis = ne_lo | ne_hi;

  bp_resolve_t b2_resolved;
  logic        b2_resolve;
  exception_t  b2_ex;
  logic [G6LCCfg.VLEN-1:0] b2_branch_result;
  logic        jump_taken;

  always_comb begin : mispredict_handler
    logic [G6LCCfg.VLEN-1:0] target_address;
    target_address = tgt64;

    b2_resolve = 1'b0;
    b2_resolved.target_address = {G6LCCfg.VLEN{1'b0}};
    b2_resolved.is_taken = 1'b0;
    b2_resolved.valid = b1_valid_q;
    b2_resolved.is_mispredict = 1'b0;
    b2_resolved.cf_type = b1_cf_q;
    b2_resolved.hart_id = b1_hart_q;
    // Default: restore BP ckpt on any mispredict (Return verify overrides below)
    b2_resolved.ckpt_restore = 1'b0;
    // R3a: carry branch SB tid for younger-cancel (not FLU_WB mux tid)
    b2_resolved.trans_id = b1_tid_q;
    // T21: the CF's own BP checkpoint identity and RAS effect, for the frontend
    b2_resolved.ckpt_v   = b1_ckpt_v_q;
    b2_resolved.ckpt_idx = b1_ckpt_idx_q;
    b2_resolved.is_call  = b1_is_call_q;
    b2_resolved.next_pc  = b1_next_pc_q;
    // we need to put the branch target address into rd, this is the result of this unit
    b2_branch_result = b1_next_pc_q;
    b2_resolved.pc = b1_pc_q;
    // There are only three sources of mispredicts:
    // 1. Branches
    // 2. Jumps to register addresses
    // 3. Zcmt instructions
    if (b1_valid_q) begin
      // write target address which goes to PC Gen or select target address if zcmt
      b2_resolved.target_address = (branch_comp_res_i) ? target_address : b1_next_pc_q;
      b2_resolved.is_taken = branch_comp_res_i;
      // hyp8 RVZCMT is 0. That arm does not fold, so it is not in this core.
      // check the outcome of the branch speculation
      if (b1_is_br_q) begin
        // Set the `cf_type` of the output as `branch`, this will update the BHT.
        b2_resolved.cf_type = g6lc_core_pkg::Branch;
        // If the ALU comparison does not agree with the BHT prediction set the resolution as mispredicted.
        b2_resolved.is_mispredict  = branch_comp_res_i != b1_cf_is_branch_q;
        b2_resolved.ckpt_restore   = b2_resolved.is_mispredict;
      end
      if (b1_is_jalr_q
          // check if the address of the jump register is correct and that we actually predicted
          && (b1_cf_is_nocf_q
              || tgt_mis)) begin
        b2_resolved.is_mispredict = 1'b1;
        b2_resolved.ckpt_restore  = 1'b1;
        // update BTB only if this wasn't a return (predicted: cf == Return;
        // unpredicted, T23: NoCF with is_ret -- resolves like an unpredicted
        // jalr, cf_type stays NoCF so neither BTB nor RAS re-pop is touched)
        if (!b1_cf_is_return_q && !b1_is_ret_q)
          b2_resolved.cf_type = g6lc_core_pkg::JumpR;
      end
      // JAL is decoded as CTRL_FLOW with default op=ADD (no JAL fu_op).
      // Always taken; EX-correct if frontend left NoCF or wrong target.
      if (!b1_is_br_q && !b1_is_jalr_q) begin
        b2_resolved.is_taken = 1'b1;
        b2_resolved.target_address = target_address;
        b2_resolved.cf_type = g6lc_core_pkg::Jump;
        if (b1_cf_is_nocf_q || tgt_mis) begin
          b2_resolved.is_mispredict = 1'b1;
          b2_resolved.ckpt_restore  = 1'b1;
        end
      end
      // EXTRACT E2: I4t/I4v JALR to unusable target is not a mispredict.
      // I11: B never filters resolve by value. A keeps recover.
`ifndef G6LC_FETCH_B
      if (G6LCCfg.NrHarts > 1 &&
          b1_is_jalr_q &&
          !g6lc_jalr_usable::usable(G6LCCfg, G6LCCfg.VLEN, 64'(target_address))) begin
        b2_resolved.is_mispredict = 1'b0;
        b2_resolved.ckpt_restore  = 1'b0;
      end
      // E2+: G1gs / G1hf / G1hg in g6lc_jalr_usable (bit-identical).
      // G1he / G1ig -- MINI-FAIL. Do not re-land.
      if (g6lc_jalr_usable::jalr_cf_jumpr(
              G6LCCfg, b1_is_jalr_q))
        b2_resolved.cf_type = g6lc_core_pkg::JumpR;
      if (g6lc_jalr_usable::mid_nbranch(
              G6LCCfg, b1_pc_q[2:1] == 2'b01,
              b1_is_br_q)) begin
        automatic logic [63:0] g1hf_tgt;
        g1hf_tgt = g6lc_jalr_usable::pick_usable(
            G6LCCfg, G6LCCfg.VLEN, 64'(b1_opa_q),
            64'(b1_opb_q));
        if (g6lc_jalr_usable::usable(
                G6LCCfg, G6LCCfg.VLEN, g1hf_tgt)) begin
          b2_resolved.cf_type = g6lc_core_pkg::JumpR;
          b2_resolved.is_taken = 1'b1;
          b2_resolved.target_address = g1hf_tgt[G6LCCfg.VLEN-1:0];
          b2_resolved.target_address[0] = 1'b0;
          if (b1_cf_is_nocf_q ||
              (b2_resolved.target_address !=
               b1_pred_addr_q)) begin
            b2_resolved.is_mispredict = 1'b1;
            b2_resolved.ckpt_restore  = 1'b1;
          end
        end
      end
      if (g6lc_jalr_usable::mid_cjalr_branch(
              G6LCCfg, b1_pc_q[2:1] == 2'b01,
              b1_is_br_q,
              b1_opc_hi_q)) begin
        automatic logic [63:0] g1hg_tgt;
        g1hg_tgt = g6lc_jalr_usable::pick_usable(
            G6LCCfg, G6LCCfg.VLEN, 64'(b1_opa_q),
            64'(b1_opb_q));
        if (g6lc_jalr_usable::usable(
                G6LCCfg, G6LCCfg.VLEN, g1hg_tgt)) begin
          b2_resolved.cf_type = g6lc_core_pkg::JumpR;
          b2_resolved.is_taken = 1'b1;
          b2_resolved.target_address = g1hg_tgt[G6LCCfg.VLEN-1:0];
          b2_resolved.target_address[0] = 1'b0;
          if (b1_cf_is_nocf_q ||
              (b2_resolved.target_address !=
               b1_pred_addr_q)) begin
            b2_resolved.is_mispredict = 1'b1;
            b2_resolved.ckpt_restore  = 1'b1;
          end
        end
      end
`endif
      // to resolve the branch in ID
      b2_resolve = 1'b1;
    end
  end

  // use ALU exception signal for storing instruction fetch exceptions if
  // the target address is not aligned to a 2 byte boundary
  always_comb begin : exception_handling
    logic [G6LCCfg.VLEN-1:0] target_address;
    target_address = b2_target_address;
    if (b1_is_jalr_q) target_address[0] = 1'b0;

    // Do a jump if it is either unconditional jump (JAL | JALR) or `taken` conditional jump
    b2_ex.cause = riscv::INSTR_ADDR_MISALIGNED;
    b2_ex.valid = 1'b0;
    if (G6LCCfg.TvalEn)
      b2_ex.tval = {
        {G6LCCfg.XLEN - G6LCCfg.VLEN{target_address[G6LCCfg.VLEN-1]}}, target_address
      };
    else b2_ex.tval = '0;
    b2_ex.tval2 = {G6LCCfg.GPLEN{1'b0}};
    b2_ex.tinst = '0;
    b2_ex.gva   = G6LCCfg.RVH ? b1_v_q : 1'b0;
    // Only throw instruction address misaligned exception if this is indeed a `taken` conditional branch or
    // an unconditional jump
    if (!G6LCCfg.RVC) begin
      jump_taken = !b1_is_br_q || (b1_is_br_q && branch_comp_res_i);
      if (b1_valid_q && (target_address[0] || target_address[1]) && jump_taken) begin
        b2_ex.valid = 1'b1;
      end
    end else begin
      jump_taken = 1'b0;
    end
  end

  // -------------------------------------------------------
  // B2 output registers -- the resolve record the scoreboard cancel
  // window and the frontend redirect read (no downstream re-capture).
  // -------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin : b2_regs
    if (!rst_ni) begin
      resolved_branch_o  <= '0;
      resolve_branch_o   <= 1'b0;
      branch_exception_o <= '0;
      branch_result_o    <= '0;
    end else if (flush_i) begin
      resolved_branch_o  <= '0;
      resolve_branch_o   <= 1'b0;
      branch_exception_o <= '0;
      branch_result_o    <= '0;
    end else begin
      resolved_branch_o  <= b2_resolved;
      // a flushed-between-B1-and-B2 record: b1_valid_q is cleared by
      // flush, so a stale B1 cannot produce a valid record here; kill the
      // record anyway for the same-cycle flush case.
      resolve_branch_o   <= b2_resolve;
      branch_exception_o <= b2_ex;
      branch_result_o    <= b2_branch_result;
    end
  end

  // debug_mode_i is unused (same as the emit base).
  logic _unused;
  assign _unused = debug_mode_i;

  // svt-stage: end B2
  // svt-stage: class B1 value
  // svt-stage: class B2 value
endmodule
