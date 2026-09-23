// SPDX-License-Identifier: MIT
// Packed bank with integer parameter defaults, and a user type that stays unresolved.
module packed_bank;
  parameter int DEPTH = 48;
  parameter int WIDTH = 64;
  typedef struct packed {
    logic flag;
  } slot_t;
  logic [DEPTH-1:0][WIDTH-1:0] mem;
  var slot_t flop_q;
endmodule
