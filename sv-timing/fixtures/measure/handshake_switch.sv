// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// PASS-STRATEGY P10: same-edge pulse + index handshake.
// InsertReg on do_switch / active_d / switch_o / active_hart_o desynchronizes
// the consumer bank restore (SMT2 switch_q <= do_switch with active_q).

module handshake_switch (
    input  logic       clk_i,
    input  logic       rst_ni,
    input  logic       ready_i,
    input  logic [1:0] peer_i,
    output logic [1:0] active_hart_o,
    output logic       switch_o
);
  logic [1:0] active_q, active_d;
  logic       do_switch;
  logic       switch_q;

  always_comb begin
    do_switch = ready_i;
    active_d  = do_switch ? peer_i : active_q;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      active_q <= '0;
      switch_q <= 1'b0;
    end else begin
      active_q <= active_d;
      switch_q <= do_switch;
    end
  end

  assign active_hart_o = active_q;
  assign switch_o      = switch_q;
endmodule

module handshake_bank (
    input  logic        clk_i,
    input  logic        rst_ni,
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

  assign npc_restore_o = npc_bank_q[active_hart_i];
endmodule
