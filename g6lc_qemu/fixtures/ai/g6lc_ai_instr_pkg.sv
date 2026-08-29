// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

package g6lc_ai_instr_pkg;
  localparam logic [6:0] OpcodeCustom2 = 7'b1011011;
  localparam logic [11:0] CSR_AIQBASE = 12'h5C0;
  localparam logic [11:0] CSR_AIQCTL  = 12'h5C1;
  localparam logic [11:0] CSR_AIQHEAD = 12'h5C2;
  localparam logic [31:0] MaskF7F3Op =
      32'b1111111_00000_00000_111_00000_1111111;

  function automatic logic [31:0] mk_instr(input logic [6:0] f, input logic [2:0] g);
    return {f, 5'b0, 5'b0, g, 5'b0, OpcodeCustom2};
  endfunction

  parameter int unsigned NbInstr = 3;
  parameter copro_issue_resp_t CoproInstr[NbInstr] = '{
      '{
          instr: mk_instr(7'b0000000, 3'b101),
          mask: MaskF7F3Op,
          resp: '{accept: 1'b1, writeback: 1'b1, register_read: 3'b001},
          opcode: AI_ENQ
      },
      '{
          instr: mk_instr(7'b0000001, 3'b101),
          mask: MaskF7F3Op,
          resp: '{accept: 1'b1, writeback: 1'b1, register_read: 3'b001},
          opcode: AI_POLL
      },
      '{
          instr: mk_instr(7'b0000010, 3'b101),
          mask: MaskF7F3Op,
          resp: '{accept: 1'b1, writeback: 1'b0, register_read: 3'b000},
          opcode: AI_QFENCE
      }
  };
endpackage
