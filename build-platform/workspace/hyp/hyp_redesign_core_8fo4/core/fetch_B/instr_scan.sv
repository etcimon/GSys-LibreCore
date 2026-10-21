// hyp8 provenance: ADAPTED (sv-timing emit at the 8-FO4 budget)
// Copyright 2018 - 2019 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 2.0 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-2.0. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
// Author: Florian Zaruba, ETH Zurich
// Date: 08.02.2018
// Migrated: Luis Vitorio Cargnini, IEEE
// Date: 09.06.2018
// Modified by: Etienne Cimon

// ------------------------------
// Instruction Scanner
// ------------------------------
// hyp8: one registered predecode stage (rank 4, front-end depth). The opcode
// decoders and immediate extractors run combinationally on instr_i; all module
// outputs are registered results, so the decoder cone lands in stage B of the
// response path and the override stage reads flops, not decode logic.
module instr_scan #(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty
) (
    // hyp8: registered stage needs clock and async-active-low reset
    input logic clk_i,
    input logic rst_ni,
    // Instruction to be predecoded - instr_realign
    input logic [31:0] instr_i,
    // Return instruction - FRONTEND
    output logic rvi_return_o,
    // JAL instruction - FRONTEND
    output logic rvi_call_o,
    // Branch instruction - FRONTEND
    output logic rvi_branch_o,
    // JALR instruction - FRONTEND
    output logic rvi_jalr_o,
    // Unconditional jump instruction - FRONTEND
    output logic rvi_jump_o,
    // Instruction immediate - FRONTEND
    output logic [G6LCCfg.VLEN-1:0] rvi_imm_o,
    // Branch compressed instruction - FRONTEND
    output logic rvc_branch_o,
    // Unconditional jump compressed instruction - FRONTEND
    output logic rvc_jump_o,
    // JR compressed instruction - FRONTEND
    output logic rvc_jr_o,
    // Return compressed instruction - FRONTEND
    output logic rvc_return_o,
    // JALR compressed instruction - FRONTEND
    output logic rvc_jalr_o,
    // JAL compressed instruction - FRONTEND
    output logic rvc_call_o,
    // Instruction compressed immediate - FRONTEND
    output logic [G6LCCfg.VLEN-1:0] rvc_imm_o
);

  function automatic logic [G6LCCfg.VLEN-1:0] uj_imm(logic [31:0] instruction_i);
    return {
      {44 + G6LCCfg.VLEN - 64{instruction_i[31]}},
      instruction_i[19:12],
      instruction_i[20],
      instruction_i[30:21],
      1'b0
    };
  endfunction

  function automatic logic [G6LCCfg.VLEN-1:0] sb_imm(logic [31:0] instruction_i);
    return {
      {51 + G6LCCfg.VLEN - 64{instruction_i[31]}},
      instruction_i[31],
      instruction_i[7],
      instruction_i[30:25],
      instruction_i[11:8],
      1'b0
    };
  endfunction

  logic rv32_rvc_jal;
  assign rv32_rvc_jal = G6LCCfg.IS_XLEN32 & ((instr_i[15:13] == riscv::OpcodeC1Jal) & (instr_i[1:0] == riscv::OpcodeC1));

  logic is_xret;
  assign is_xret = logic'(instr_i[31:30] == 2'b00) & logic'(instr_i[28:0] == 29'b10000001000000000000001110011);

  logic rvi_return_d, rvi_call_d, rvi_branch_d, rvi_jalr_d, rvi_jump_d;
  logic [G6LCCfg.VLEN-1:0] rvi_imm_d;
  logic rvc_branch_d, rvc_jump_d, rvc_jr_d, rvc_return_d, rvc_jalr_d, rvc_call_d;
  logic [G6LCCfg.VLEN-1:0] rvc_imm_d;

  // check that rs1 is either x1 or x5 and that rd is not rs1
  // rd != rs1 is what separates a RAS pop from a call through the link register:
  // if the jump also rewrites its own source it is not a plain return.
  assign rvi_return_d = rvi_jalr_d & ((instr_i[19:15] == 5'd1) | instr_i[19:15] == 5'd5)
                                     & (instr_i[19:15] != instr_i[11:7]);
  // Opcode is JAL[R] and destination register is either x1 or x5
  assign rvi_call_d = (rvi_jalr_d | rvi_jump_d) & ((instr_i[11:7] == 5'd1) | instr_i[11:7] == 5'd5);
  // differentiates between JAL and BRANCH opcode, JALR comes from BHT
  // xret has no immediate: its target comes from a CSR, so a zero here keeps the
  // predictor from computing a bogus pc-relative target for it.
  assign rvi_imm_d = is_xret ? '0 : (instr_i[3]) ? uj_imm(instr_i) : sb_imm(instr_i);
  assign rvi_branch_d = (instr_i[6:0] == riscv::OpcodeBranch);
  assign rvi_jalr_d = (instr_i[6:0] == riscv::OpcodeJalr);
  assign rvi_jump_d = logic'(instr_i[6:0] == riscv::OpcodeJal) | is_xret;

  // opcode JAL
  assign rvc_jump_d   = ((instr_i[15:13] == riscv::OpcodeC1J) & (instr_i[1:0] == riscv::OpcodeC1)) | rv32_rvc_jal;

  // always links to register 0
  logic is_jal_r;
  assign is_jal_r     = (instr_i[15:13] == riscv::OpcodeC2JalrMvAdd)
                        & (instr_i[6:2] == 5'b00000)
                        & (instr_i[1:0] == riscv::OpcodeC2);
  // c.jr and c.jalr share one encoding and differ only in bit 12; the link write
  // is what makes one a call and the other a candidate return.
  assign rvc_jr_d = is_jal_r & ~instr_i[12];
  // always links to register 1 e.g.: it is a jump
  assign rvc_jalr_d = is_jal_r & instr_i[12];
  assign rvc_call_d = rvc_jalr_d | rv32_rvc_jal;

  assign rvc_branch_d = ((instr_i[15:13] == riscv::OpcodeC1Beqz) | (instr_i[15:13] == riscv::OpcodeC1Bnez))
                        & (instr_i[1:0] == riscv::OpcodeC1);
  // check that rs1 is x1 or x5
  assign rvc_return_d = ((instr_i[11:7] == 5'd1) | (instr_i[11:7] == 5'd5)) & rvc_jr_d;

  // differentiates between JAL and BRANCH opcode, JALR comes from BHT
  assign rvc_imm_d    = (instr_i[14]) ? {{56+G6LCCfg.VLEN-64{instr_i[12]}}, instr_i[6:5], instr_i[2], instr_i[11:10], instr_i[4:3], 1'b0}
                                       : {{53+G6LCCfg.VLEN-64{instr_i[12]}}, instr_i[8], instr_i[10:9], instr_i[6], instr_i[7], instr_i[2], instr_i[11], instr_i[5:3], 1'b0};

  // hyp8: the predecode outputs are registered; consumers see them one cycle
  // after the realigned slot (response stage 3 of 4).
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rvi_return_o <= 1'b0;
      rvi_call_o   <= 1'b0;
      rvi_branch_o <= 1'b0;
      rvi_jalr_o   <= 1'b0;
      rvi_jump_o   <= 1'b0;
      rvi_imm_o    <= '0;
      rvc_branch_o <= 1'b0;
      rvc_jump_o   <= 1'b0;
      rvc_jr_o     <= 1'b0;
      rvc_return_o <= 1'b0;
      rvc_jalr_o   <= 1'b0;
      rvc_call_o   <= 1'b0;
      rvc_imm_o    <= '0;
    end else begin
      rvi_return_o <= rvi_return_d;
      rvi_call_o   <= rvi_call_d;
      rvi_branch_o <= rvi_branch_d;
      rvi_jalr_o   <= rvi_jalr_d;
      rvi_jump_o   <= rvi_jump_d;
      rvi_imm_o    <= rvi_imm_d;
      rvc_branch_o <= rvc_branch_d;
      rvc_jump_o   <= rvc_jump_d;
      rvc_jr_o     <= rvc_jr_d;
      rvc_return_o <= rvc_return_d;
      rvc_jalr_o   <= rvc_jalr_d;
      rvc_call_o   <= rvc_call_d;
      rvc_imm_o    <= rvc_imm_d;
    end
  end
endmodule
