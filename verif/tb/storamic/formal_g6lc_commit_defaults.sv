// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module formal_g6lc_commit_defaults
  import g6lc_commit_defaults_pkg::*;
  import ariane_pkg::*;
#(parameter int Ports = 2, parameter bit Negative = 0) (
  input logic clk_i, rst_ni, halt_i,
  input scoreboard_entry_t [Ports-1:0] entries_i,
  input logic [Ports-1:0] drop_i, replay_i,
  input amo_resp_t amo_i,
  output logic cover_retire_o, cover_drop_o, cover_dual_o
);
  logic [Ports-1:0] ack, gpr, fpr;
  logic [Ports-1:0][CVA6Cfg.XLEN-1:0] value;
  logic [Ports-1:0][4:0] addr;
  g6lc_commit_defaults_dut #(.Ports(Ports)) dut (
    .clk_i, .rst_ni, .halt_i, .entries_i, .drop_i, .replay_i, .amo_i,
    .ack_o(ack), .gpr_o(gpr), .fpr_o(fpr), .data_o(value), .addr_o(addr)
  );
  assign cover_retire_o = rst_ni && !halt_i && ack[0] && gpr[0] &&
                          entries_i[0].valid && entries_i[0].fu == ALU &&
                          entries_i[0].op == ADD && !drop_i[0];
  assign cover_drop_o = rst_ni && !halt_i && (&drop_i) && entries_i[0].valid &&
                        entries_i[0].op == AMO_CASQ && amo_i.ack && amo_i.dual_we &&
                        gpr == 0 && fpr == 0 && ack[0];
  if (Ports == 2) begin : gen_dual
    assign cover_dual_o = rst_ni && !halt_i && !drop_i[0] && entries_i[0].valid &&
                          entries_i[0].fu == STORE && entries_i[0].op == AMO_CASQ &&
                          amo_i.ack && amo_i.dual_we && ack[0] && (&gpr);
  end else begin : gen_single
    assign cover_dual_o = 1'b0;
  end
  always_comb if (rst_ni) begin
    if (halt_i) assert (gpr == 0 && fpr == 0 && ack == 0);
    if (&drop_i) assert (gpr == 0 && fpr == 0);
    if (Negative) assert (gpr == 0);
  end
endmodule
