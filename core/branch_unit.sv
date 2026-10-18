// Modified by: Etienne Cimon (2026) - A139 pipeline-design comments.
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

module branch_unit #(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type bp_resolve_t = logic,
    parameter type branchpredict_sbe_t = logic,
    parameter type exception_t = logic,
    parameter type fu_data_t = logic
) (
    // Subsystem Clock - SUBSYSTEM
    input logic clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input logic rst_ni,
    // Virtualization mode state - CSR_REGFILE
    input logic v_i,
    // Debug mode state - CSR_REGFILE
    input logic debug_mode_i,
    // FU data needed to execute instruction - ISSUE_STAGE
    input fu_data_t fu_data_i,
    // Instruction PC - ISSUE_STAGE
    input logic [CVA6Cfg.VLEN-1:0] pc_i,
    // FSE S5: SMT hart of the resolving control-flow instruction
    input logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] hart_id_i,
    // Is zcmt instruction - ISSUE_STAGE
    input logic is_zcmt_i,
    // Instruction is compressed - ISSUE_STAGE
    input logic is_compressed_instr_i,
    // Branch unit instruction is valid - ISSUE_STAGE
    input logic branch_valid_i,
    // ALU branch compare result - ALU
    input logic branch_comp_res_i,
    // Brach unit result - ISSUE_STAGE
    output logic [CVA6Cfg.VLEN-1:0] branch_result_o,
    // Information of branch prediction - ISSUE_STAGE
    input branchpredict_sbe_t branch_predict_i,
    // Signaling that we resolved the branch - ISSUE_STAGE
    output bp_resolve_t resolved_branch_o,
    // Branch is resolved, new entries can be accepted by scoreboard - ID_STAGE
    output logic resolve_branch_o,
    // Branch exception out - TO_BE_COMPLETED
    output exception_t branch_exception_o
);
  // A139 design proposal; vocabulary: architecture/RTL-PIPELINE-PLANS.md.
  // svt-plan: begin branch_unit status=proposal target=10-adjusted-FO4
  // svt-plan: cone target addition, branch condition/prediction comparison
  // and resolve delivery form a dependency chain; link result also uses PC/length.
  // svt-plan: boundary target/link preparation and condition -> resolve
  // comparison; segment the target adder if its own carry depth dominates.
  // svt-plan: carry TID+generation, hart, PC/length, target, condition,
  // prediction/checkpoint identity, CF type, link value and exception context.
  // svt-plan: ownership suppress killed branch tokens; compare only against
  // that token's prediction; recovery must include every younger op admitted
  // during the added delay, not a frozen old cancellation bitmap.
  // svt-plan: effect removes target-add depth from resolve comparison;
  // a resolve output register alone would leave both in the same stage.
  // svt-plan: cost branch latency and mispredict penalty; controller,
  // checkpoint recovery and FLU completion must accept the delayed token together.
  // svt-plan: limit JALR masking/alignment and exception priority stay exact;
  // retirement cannot pass an unresolved older branch.
  // svt-plan: end
  // Re-pipelining contract (sv-timing A128; 77.4 adjusted FO4 on the
  // Nangate45 board): branch resolution: pure datapath; resolved_branch_o feeds the controller the same cycle — an FLU / redirect latency decision.
  // svt-pipe: require-contract

  logic [CVA6Cfg.VLEN-1:0] target_address;
  logic [CVA6Cfg.VLEN-1:0] next_pc;

  // A140: carry-free "sum equals" test for the target check. a + b == c
  // (mod 2**VLEN) iff the bitwise x = a ^ b ^ c equals
  // y = ((a & b) | ((a ^ b) & ~c)) << 1: the carry each bit would need
  // (a_i ^ b_i ^ c_i) must reproduce the majority recurrence. Constant depth
  // per bit plus one equality, no carry propagation in front of the
  // mispredict decision; the adder still produces the redirect address.
  // With ignore_lsb (JALR clears the target's LSB) bit 0 of the sum is not
  // compared, the carry into bit 1 is the real a0 & b0, and c[0] must be 0.
  function automatic logic sum_eq(input logic [CVA6Cfg.VLEN-1:0] a, input logic [CVA6Cfg.VLEN-1:0] b,
                                  input logic [CVA6Cfg.VLEN-1:0] c, input logic ignore_lsb);
    logic [CVA6Cfg.VLEN-1:0] x, y;
    x = a ^ b ^ c;
    y = ((a & b) | ((a ^ b) & ~c)) << 1;
    if (ignore_lsb) begin
      y[1] = a[0] & b[0];
      return (x[CVA6Cfg.VLEN-1:1] == y[CVA6Cfg.VLEN-1:1]) && !c[0];
    end
    return x == y;
  endfunction
  logic target_eq_jalr, target_eq_jal;

  // here we handle the various possibilities of mis-predicts
  always_comb begin : mispredict_handler
    // set the jump base, for JALR we need to look at the register, for all other control flow instructions we can take the current PC
    automatic logic [CVA6Cfg.VLEN-1:0] jump_base;
    automatic logic [CVA6Cfg.VLEN-1:0] instr_pc;
    // I14: pc_i is the CF issue port (IRO / ex_stage pick). Not operand_c.
    instr_pc = pc_i;
    // TODO(zarubaf): The ALU can be used to calculate the branch target
    jump_base = (fu_data_i.operation == ariane_pkg::JALR) ? fu_data_i.operand_a[CVA6Cfg.VLEN-1:0] : instr_pc;

    resolve_branch_o = 1'b0;
    resolved_branch_o.target_address = {CVA6Cfg.VLEN{1'b0}};
    resolved_branch_o.is_taken = 1'b0;
    resolved_branch_o.valid = branch_valid_i;
    resolved_branch_o.is_mispredict = 1'b0;
    resolved_branch_o.cf_type = branch_predict_i.cf;
    resolved_branch_o.hart_id = hart_id_i;
    // Default: restore BP ckpt on any mispredict (Return verify overrides below)
    resolved_branch_o.ckpt_restore = 1'b0;
    // R3a: carry branch SB tid for younger-cancel (not FLU_WB mux tid)
    resolved_branch_o.trans_id = fu_data_i.trans_id;
    // T21: the CF's own BP checkpoint identity and RAS effect, for the frontend
    resolved_branch_o.ckpt_v   = branch_predict_i.ckpt_v;
    resolved_branch_o.ckpt_idx = branch_predict_i.ckpt_idx;
    resolved_branch_o.is_call  = branch_predict_i.is_call;
    // calculate next PC, depending on whether the instruction is compressed or not this may be different
    // TODO(zarubaf): We already calculate this a couple of times, maybe re-use?
    next_pc                          = instr_pc + ((is_compressed_instr_i) ? {{CVA6Cfg.VLEN-2{1'b0}}, 2'h2} : {{CVA6Cfg.VLEN-3{1'b0}}, 3'h4});
    resolved_branch_o.next_pc  = next_pc;
    // calculate target address simple 64 bit addition
    target_address = $unsigned($signed(jump_base) + $signed(fu_data_i.imm[CVA6Cfg.VLEN-1:0]));
    // on a JALR we are supposed to reset the LSB to 0 (according to the specification)
    if (fu_data_i.operation == ariane_pkg::JALR) target_address[0] = 1'b0;
    // the prediction check as a carry-free test on the same operands (A140)
    target_eq_jalr = sum_eq(jump_base, fu_data_i.imm[CVA6Cfg.VLEN-1:0],
                            branch_predict_i.predict_address, 1'b1);
    target_eq_jal  = sum_eq(jump_base, fu_data_i.imm[CVA6Cfg.VLEN-1:0],
                            branch_predict_i.predict_address, 1'b0);
    // we need to put the branch target address into rd, this is the result of this unit
    branch_result_o = next_pc;
    resolved_branch_o.pc = instr_pc;
    // There are only three sources of mispredicts:
    // 1. Branches
    // 2. Jumps to register addresses
    // 3. Zcmt instructions
    if (branch_valid_i) begin
      // write target address which goes to PC Gen or select target address if zcmt
      resolved_branch_o.target_address = (branch_comp_res_i) ? target_address : next_pc;
      resolved_branch_o.is_taken = branch_comp_res_i;
      if (CVA6Cfg.RVZCMT) begin
        if (is_zcmt_i) begin
          // Unconditional jump handling
          resolved_branch_o.is_mispredict = 1'b1;  // miss prediction for ZCMT
          resolved_branch_o.ckpt_restore = 1'b1;
          resolved_branch_o.cf_type = ariane_pkg::JumpR;
        end
      end
      // check the outcome of the branch speculation
      if (ariane_pkg::op_is_branch(fu_data_i.operation)) begin
        // Set the `cf_type` of the output as `branch`, this will update the BHT.
        resolved_branch_o.cf_type = ariane_pkg::Branch;
        // If the ALU comparison does not agree with the BHT prediction set the resolution as mispredicted.
        resolved_branch_o.is_mispredict  = branch_comp_res_i != (branch_predict_i.cf == ariane_pkg::Branch);
        resolved_branch_o.ckpt_restore   = resolved_branch_o.is_mispredict;
      end
      if (fu_data_i.operation == ariane_pkg::JALR
          // check if the address of the jump register is correct and that we actually predicted
          && (branch_predict_i.cf == ariane_pkg::NoCF
              || !target_eq_jalr)) begin
        resolved_branch_o.is_mispredict = 1'b1;
        resolved_branch_o.ckpt_restore  = 1'b1;
        // update BTB only if this wasn't a return (predicted: cf == Return;
        // unpredicted, T23: NoCF with is_ret -- resolves like an unpredicted
        // jalr, cf_type stays NoCF so neither BTB nor RAS re-pop is touched)
        if (branch_predict_i.cf != ariane_pkg::Return && !branch_predict_i.is_ret)
          resolved_branch_o.cf_type = ariane_pkg::JumpR;
      end
      // JAL is decoded as CTRL_FLOW with default op=ADD (no JAL fu_op).
      // Always taken; EX-correct if frontend left NoCF or wrong target.
      // Hang-6 residual at jal@0x80012b0a has cf=Jump+matching tgt (jal_ex
      // misp=0) yet sequential still retires — frontend IQ/NPC follow-through.
      // Forced is_mispredict on every JAL regressed to early IAF
      // (mepc=0x1400000000) even without ckpt_restore; keep selective only.
      if (!ariane_pkg::op_is_branch(fu_data_i.operation) &&
          fu_data_i.operation != ariane_pkg::JALR) begin
        resolved_branch_o.is_taken = 1'b1;
        resolved_branch_o.target_address = target_address;
        resolved_branch_o.cf_type = ariane_pkg::Jump;
        if (branch_predict_i.cf == ariane_pkg::NoCF || !target_eq_jal) begin
          resolved_branch_o.is_mispredict = 1'b1;
          resolved_branch_o.ckpt_restore  = 1'b1;
        end
      end
      // EXTRACT E2: I4t/I4v JALR to unusable target is not a mispredict.
      // I11: B never filters resolve by value. A keeps recover.
`ifndef G6LC_FETCH_B
      if (CVA6Cfg.NrHarts > 1 &&
          fu_data_i.operation == ariane_pkg::JALR &&
          !g6lc_jalr_usable::usable(CVA6Cfg, CVA6Cfg.VLEN, 64'(target_address))) begin
        resolved_branch_o.is_mispredict = 1'b0;
        resolved_branch_o.ckpt_restore  = 1'b0;
      end
      // E2+: G1gs / G1hf / G1hg in g6lc_jalr_usable (bit-identical).
      // G1he / G1ig — MINI-FAIL. Do not re-land.
      if (g6lc_jalr_usable::jalr_cf_jumpr(
              CVA6Cfg, fu_data_i.operation == ariane_pkg::JALR))
        resolved_branch_o.cf_type = ariane_pkg::JumpR;
      if (g6lc_jalr_usable::mid_nbranch(
              CVA6Cfg, instr_pc[2:1] == 2'b01,
              ariane_pkg::op_is_branch(fu_data_i.operation))) begin
        automatic logic [63:0] g1hf_tgt;
        g1hf_tgt = g6lc_jalr_usable::pick_usable(
            CVA6Cfg, CVA6Cfg.VLEN, 64'(fu_data_i.operand_a),
            64'(fu_data_i.operand_b));
        if (g6lc_jalr_usable::usable(
                CVA6Cfg, CVA6Cfg.VLEN, g1hf_tgt)) begin
          resolved_branch_o.cf_type = ariane_pkg::JumpR;
          resolved_branch_o.is_taken = 1'b1;
          resolved_branch_o.target_address = g1hf_tgt[CVA6Cfg.VLEN-1:0];
          resolved_branch_o.target_address[0] = 1'b0;
          if (branch_predict_i.cf == ariane_pkg::NoCF ||
              (resolved_branch_o.target_address !=
               branch_predict_i.predict_address)) begin
            resolved_branch_o.is_mispredict = 1'b1;
            resolved_branch_o.ckpt_restore  = 1'b1;
          end
        end
      end
      if (g6lc_jalr_usable::mid_cjalr_branch(
              CVA6Cfg, instr_pc[2:1] == 2'b01,
              ariane_pkg::op_is_branch(fu_data_i.operation),
              fu_data_i.operand_c_hi[15:0])) begin
        automatic logic [63:0] g1hg_tgt;
        g1hg_tgt = g6lc_jalr_usable::pick_usable(
            CVA6Cfg, CVA6Cfg.VLEN, 64'(fu_data_i.operand_a),
            64'(fu_data_i.operand_b));
        if (g6lc_jalr_usable::usable(
                CVA6Cfg, CVA6Cfg.VLEN, g1hg_tgt)) begin
          resolved_branch_o.cf_type = ariane_pkg::JumpR;
          resolved_branch_o.is_taken = 1'b1;
          resolved_branch_o.target_address = g1hg_tgt[CVA6Cfg.VLEN-1:0];
          resolved_branch_o.target_address[0] = 1'b0;
          if (branch_predict_i.cf == ariane_pkg::NoCF ||
              (resolved_branch_o.target_address !=
               branch_predict_i.predict_address)) begin
            resolved_branch_o.is_mispredict = 1'b1;
            resolved_branch_o.ckpt_restore  = 1'b1;
          end
        end
      end
`endif
      // G1ig mid-line 01 Branch leftover-PC
      // target JumpR — MINI-FAIL FDT hang
      // @400000. Do not re-land (G1he
      // class; yanks live mid-line Branch
      // whose imm lands on [2:1]==11).
      // Isolated P4 stays.
      // to resolve the branch in ID
      resolve_branch_o = 1'b1;
    end
  end
  // use ALU exception signal for storing instruction fetch exceptions if
  // the target address is not aligned to a 2 byte boundary
  //
  logic jump_taken;
  always_comb begin : exception_handling

    // Do a jump if it is either unconditional jump (JAL | JALR) or `taken` conditional jump
    branch_exception_o.cause = riscv::INSTR_ADDR_MISALIGNED;
    branch_exception_o.valid = 1'b0;
    if (CVA6Cfg.TvalEn)
      branch_exception_o.tval = {
        {CVA6Cfg.XLEN - CVA6Cfg.VLEN{target_address[CVA6Cfg.VLEN-1]}}, target_address
      };
    else branch_exception_o.tval = '0;
    branch_exception_o.tval2 = {CVA6Cfg.GPLEN{1'b0}};
    branch_exception_o.tinst = '0;
    branch_exception_o.gva   = CVA6Cfg.RVH ? v_i : 1'b0;
    // Only throw instruction address misaligned exception if this is indeed a `taken` conditional branch or
    // an unconditional jump
    if (!CVA6Cfg.RVC) begin
      jump_taken = !(ariane_pkg::op_is_branch(fu_data_i.operation)) ||
          ((ariane_pkg::op_is_branch(fu_data_i.operation)) && branch_comp_res_i);
      if (branch_valid_i && (target_address[0] || target_address[1]) && jump_taken) begin
        branch_exception_o.valid = 1'b1;
      end
    end
  end
  //pragma translate_off
  // A140 witness: the carry-free target checks agree with the adder-based
  // compare for this cycle's operands (target_address carries the JALR LSB
  // clear exactly when the operation is a JALR).
  always_ff @(posedge clk_i) if (rst_ni) begin
    if (fu_data_i.operation == ariane_pkg::JALR)
      assert (target_eq_jalr == (target_address == branch_predict_i.predict_address))
      else $error("branch_unit: carry-free JALR target check differs from the adder compare");
    else
      assert (target_eq_jal == (target_address == branch_predict_i.predict_address))
      else $error("branch_unit: carry-free JAL target check differs from the adder compare");
  end
  //pragma translate_on

endmodule
