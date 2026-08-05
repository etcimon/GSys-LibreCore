// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// issue_read_operands-style module surface (offline, no monorepo deps):
//   import ariane_pkg::*;
//   parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty
//   parameter type scoreboard_entry_t = ...
//   input scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0] issue_instr_i
//   for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) ...

module issue_style_unit
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    // Type parameters default to package types (as parents override in real CVA6).
    parameter type branchpredict_sbe_t = ariane_pkg::branchpredict_sbe_t,
    parameter type fu_data_t = ariane_pkg::fu_data_t,
    parameter type scoreboard_entry_t = ariane_pkg::scoreboard_entry_t,
    parameter type forwarding_t = ariane_pkg::forwarding_t,
    parameter type writeback_t = ariane_pkg::writeback_t
) (
    input  logic                                          clk_i,
    input  logic                                          rst_ni,
    input  logic                                          flush_i,
    input  scoreboard_entry_t [CVA6Cfg.NrIssuePorts-1:0]  issue_instr_i,
    input  logic              [CVA6Cfg.NrIssuePorts-1:0]  issue_instr_valid_i,
    output logic              [CVA6Cfg.NrIssuePorts-1:0]  issue_ack_o,
    input  forwarding_t                                   fwd_i,
    output fu_data_t          [CVA6Cfg.NrIssuePorts-1:0]  fu_data_o,
    output logic              [CVA6Cfg.XLEN-1:0]          pc_o
);
  // issue_read_operands: genvar loop casting / assigns
  logic [CVA6Cfg.NrIssuePorts-1:0][31:0] orig_q;
  for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin : gen_orig
    assign orig_q[i] = issue_instr_valid_i[i] ? 32'(i) : '0;
  end

  // Named gen loop with RAW-style body (density of issue_read_operands gen_raw_checks)
  logic [CVA6Cfg.NrIssuePorts-1:0] raw_stall;
  for (genvar i = 0; i < CVA6Cfg.NrIssuePorts; i++) begin : gen_raw_checks
    always_comb begin
      raw_stall[i] = issue_instr_valid_i[i] && flush_i;
    end
  end

  // Comb cloud for FO4 paths (operand forward-ish)
  logic [CVA6Cfg.XLEN-1:0] op_a, op_b, acc;
  always_comb begin : issue_operand_comb
    op_a = issue_instr_i[0].result;
    op_b = {32'b0, orig_q[0]};
    acc  = op_a + op_b + op_a;
    pc_o = acc;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : issue_regs
    if (!rst_ni) begin
      issue_ack_o <= '0;
      fu_data_o   <= '0;
    end else begin
      for (int unsigned k = 0; k < CVA6Cfg.NrIssuePorts; k++) begin
        issue_ack_o[k] <= issue_instr_valid_i[k] && !raw_stall[k];
        fu_data_o[k].operand_a <= op_a;
        fu_data_o[k].operand_b <= op_b;
        fu_data_o[k].imm       <= acc;
      end
    end
  end
endmodule
