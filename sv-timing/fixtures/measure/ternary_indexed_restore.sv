// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// P10 consumer with a ternary guard: `out = empty ? 0 : mem[port]`.
// index_mem_base must walk the ternary or InsertReg would cut the restore
// (inval_bus `inv_core_o = empty ? 0 : fifo_q[head_q]`).

module ternary_indexed_restore (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        empty_i,
    input  logic [1:0]  active_hart_i,
    input  logic        switch_i,
    input  logic [31:0] npc_live_i,
    output logic [31:0] npc_restore_o
);
  logic [1:0] prev_hart_q;
  logic [3:0][31:0] npc_bank_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      prev_hart_q <= '0;
      npc_bank_q  <= '0;
    end else begin
      prev_hart_q <= active_hart_i;
      if (switch_i) npc_bank_q[prev_hart_q] <= npc_live_i;
    end
  end

  assign npc_restore_o = empty_i ? '0 : npc_bank_q[active_hart_i];
endmodule
