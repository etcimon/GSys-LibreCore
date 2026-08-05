// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Minimal stand-in for ariane_pkg types used by issue_read_operands-style ports.

package ariane_pkg;
  localparam int unsigned REG_ADDR_SIZE = 6;

  typedef struct packed {
    logic [4:0]  rd;
    logic [63:0] result;
    logic        valid;
    logic [2:0]  trans_id;
  } scoreboard_entry_t;

  typedef struct packed {
    logic [63:0] operand_a;
    logic [63:0] operand_b;
    logic [63:0] imm;
  } fu_data_t;

  typedef struct packed {logic dummy;} forwarding_t;
  typedef struct packed {logic dummy;} writeback_t;
  typedef struct packed {logic dummy;} branchpredict_sbe_t;
endpackage
