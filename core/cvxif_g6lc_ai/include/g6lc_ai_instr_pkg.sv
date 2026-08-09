// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai mask/match table for the CVXIF seam (option B).
// Normative encodings: architecture/ai-matrix/isa-encoding.md
// custom-2 opcode 0x5B (0b1011011). custom-3 is taken by the CVXIF example.
//
// Operand class (isa-encoding.md §2): register_read is set only for GPR fields.
// Tile/accumulator indices never request RF ports.
//
// Timing: package only — no combinational path.

package g6lc_ai_instr_pkg;

  // custom-2
  localparam logic [6:0] OpcodeCustom2 = 7'b1011011;

  // Contract version returned by ai.setcfg (isa-encoding.md §9)
  localparam logic [3:0] AiContractVersion = 4'd1;

  // Extension status encodings (spec Table 101 / aistatus.ais)
  localparam logic [1:0] AiOff     = 2'b00;
  localparam logic [1:0] AiInitial = 2'b01;
  localparam logic [1:0] AiClean   = 2'b10;
  localparam logic [1:0] AiDirty   = 2'b11;

  typedef enum logic [5:0] {
    AI_ILLEGAL   = 6'd0,
    // funct3=000 configuration
    AI_SETCFG    = 6'd1,
    AI_GETCFG    = 6'd2,
    AI_RELACC    = 6'd3,
    // funct3=001 matrix MMA (tile indices)
    AI_MMA_S8    = 6'd4,
    AI_MMA_U8    = 6'd5,
    AI_MMA_SU8   = 6'd6,
    AI_MMA_US8   = 6'd7,
    // funct3=010 tile move (no native ldt/stt under seam B)
    AI_MVACC     = 6'd8,
    AI_MVTA      = 6'd9,
    // funct3=011 GPR dot
    AI_DOT4_S8   = 6'd10,
    AI_DOT4_U8   = 6'd11,
    AI_DOT4A_S8  = 6'd12,
    // funct3=100 requant / act (gated AiRequantEn)
    AI_REQUANT   = 6'd13,
    AI_REQUANT_T = 6'd14,
    AI_ACT_RELU  = 6'd15,
    AI_ACT_GELU  = 6'd16,
    // funct3=101 queue (gated AiQueues > 0)
    AI_ENQ       = 6'd17,
    AI_POLL      = 6'd18,
    AI_QFENCE    = 6'd19,
    // funct3=110 sparse (gated AiSparseEn); gathr needs memory — seam B omits it
    AI_EXPSEL    = 6'd20
  } opcode_t;

  typedef struct packed {
    logic       accept;
    logic       writeback;
    logic [2:0] register_read;  // {rs3, rs2, rs1}
  } issue_resp_t;

  typedef struct packed {
    logic [31:0]  instr;
    logic [31:0]  mask;
    issue_resp_t  resp;
    opcode_t      opcode;
  } copro_issue_resp_t;

  // Match funct7[31:25] + funct3[14:12] + opcode[6:0]. rs/rd are don't-care.
  localparam logic [31:0] MaskF7F3Op =
      32'b1111111_00000_00000_111_00000_1111111;

  function automatic logic [31:0] mk_instr(input logic [6:0] f7, input logic [2:0] f3);
    return {f7, 5'b0, 5'b0, f3, 5'b0, OpcodeCustom2};
  endfunction

  // NbInstr is the full allocated set executable under seam B (no ldt/stt/gathr).
  parameter int unsigned NbInstr = 20;
  parameter copro_issue_resp_t CoproInstr[NbInstr] = '{
      // ---- configuration (funct3=000) ----
      '{
          instr: mk_instr(7'b0000000, 3'b000),
          mask: MaskF7F3Op,
          resp: '{accept: 1'b1, writeback: 1'b1, register_read: 3'b001},  // rs1
          opcode: AI_SETCFG
      },
      '{
          instr: mk_instr(7'b0000001, 3'b000),
          mask: MaskF7F3Op,
          resp: '{accept: 1'b1, writeback: 1'b1, register_read: 3'b000},
          opcode: AI_GETCFG
      },
      '{
          instr: mk_instr(7'b0000010, 3'b000),
          mask: MaskF7F3Op,
          resp: '{accept: 1'b1, writeback: 1'b0, register_read: 3'b000},  // tile idx in rd
          opcode: AI_RELACC
      },
      // ---- MMA (funct3=001) — tile indices only ----
      '{
          instr: mk_instr(7'b0000000, 3'b001),
          mask: MaskF7F3Op,
          resp: '{accept: 1'b1, writeback: 1'b0, register_read: 3'b000},
          opcode: AI_MMA_S8
      },
      '{
          instr: mk_instr(7'b0000001, 3'b001),
          mask: MaskF7F3Op,
          resp: '{accept: 1'b1, writeback: 1'b0, register_read: 3'b000},
          opcode: AI_MMA_U8
      },
      '{
          instr: mk_instr(7'b0000010, 3'b001),
          mask: MaskF7F3Op,
          resp: '{accept: 1'b1, writeback: 1'b0, register_read: 3'b000},
          opcode: AI_MMA_SU8
      },
      '{
          instr: mk_instr(7'b0000011, 3'b001),
          mask: MaskF7F3Op,
          resp: '{accept: 1'b1, writeback: 1'b0, register_read: 3'b000},
          opcode: AI_MMA_US8
      },
      // ---- tile move (funct3=010); ldt/stt omitted under seam B ----
      '{
          instr: mk_instr(7'b0000010, 3'b010),
          mask: MaskF7F3Op,
          resp: '{accept: 1'b1, writeback: 1'b1, register_read: 3'b000},  // rd GPR; indices in rs
          opcode: AI_MVACC
      },
      '{
          instr: mk_instr(7'b0000011, 3'b010),
          mask: MaskF7F3Op,
          resp: '{accept: 1'b1, writeback: 1'b0, register_read: 3'b001},  // rs1 GPR data
          opcode: AI_MVTA
      },
      // ---- GPR dot (funct3=011) ----
      '{
          instr: mk_instr(7'b0000000, 3'b011),
          mask: MaskF7F3Op,
          resp: '{accept: 1'b1, writeback: 1'b1, register_read: 3'b011},  // rs1, rs2
          opcode: AI_DOT4_S8
      },
      '{
          instr: mk_instr(7'b0000001, 3'b011),
          mask: MaskF7F3Op,
          resp: '{accept: 1'b1, writeback: 1'b1, register_read: 3'b011},
          opcode: AI_DOT4_U8
      },
      '{
          // RMW into rd: needs X_NUM_RS >= 3 (true when RVZacas and single-issue)
          instr: mk_instr(7'b0000010, 3'b011),
          mask: MaskF7F3Op,
          resp: '{accept: 1'b1, writeback: 1'b1, register_read: 3'b111},  // rs1,rs2,rd as rs3
          opcode: AI_DOT4A_S8
      },
      // ---- requant / act (funct3=100) ----
      '{
          instr: mk_instr(7'b0000000, 3'b100),
          mask: MaskF7F3Op,
          resp: '{accept: 1'b1, writeback: 1'b0, register_read: 3'b010},  // rs2 scale ptr
          opcode: AI_REQUANT
      },
      '{
          instr: mk_instr(7'b0000001, 3'b100),
          mask: MaskF7F3Op,
          resp: '{accept: 1'b1, writeback: 1'b0, register_read: 3'b010},
          opcode: AI_REQUANT_T
      },
      '{
          instr: mk_instr(7'b0000010, 3'b100),
          mask: MaskF7F3Op,
          resp: '{accept: 1'b1, writeback: 1'b0, register_read: 3'b000},
          opcode: AI_ACT_RELU
      },
      '{
          instr: mk_instr(7'b0000011, 3'b100),
          mask: MaskF7F3Op,
          resp: '{accept: 1'b1, writeback: 1'b0, register_read: 3'b000},
          opcode: AI_ACT_GELU
      },
      // ---- queue (funct3=101) ----
      '{
          instr: mk_instr(7'b0000000, 3'b101),
          mask: MaskF7F3Op,
          resp: '{accept: 1'b1, writeback: 1'b1, register_read: 3'b001},  // rs1 desc ptr
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
      },
      // ---- sparse assist (funct3=110); gathr omitted (memory) under seam B ----
      '{
          instr: mk_instr(7'b0000001, 3'b110),
          mask: MaskF7F3Op,
          resp: '{accept: 1'b1, writeback: 1'b1, register_read: 3'b011},
          opcode: AI_EXPSEL
      }
  };

  // Group membership helpers for config gates (isa-encoding.md §3).
  function automatic logic is_requant_group(input opcode_t op);
    return op inside {AI_REQUANT, AI_REQUANT_T, AI_ACT_RELU, AI_ACT_GELU};
  endfunction

  function automatic logic is_queue_group(input opcode_t op);
    return op inside {AI_ENQ, AI_POLL, AI_QFENCE};
  endfunction

  function automatic logic is_sparse_group(input opcode_t op);
    return op inside {AI_EXPSEL};
  endfunction

  function automatic logic is_mma_group(input opcode_t op);
    return op inside {AI_MMA_S8, AI_MMA_U8, AI_MMA_SU8, AI_MMA_US8};
  endfunction

  function automatic logic writes_ai_state(input opcode_t op);
    // Any op that mutates tile/acc/cfg marks ais Dirty (isa-encoding.md §5).
    return op inside {
      AI_SETCFG, AI_RELACC,
      AI_MMA_S8, AI_MMA_U8, AI_MMA_SU8, AI_MMA_US8,
      AI_MVTA, AI_REQUANT, AI_REQUANT_T, AI_ACT_RELU, AI_ACT_GELU
    };
  endfunction

endpackage
