// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module tb_g6lc_commit_defaults;
  import g6lc_commit_defaults_pkg::*;
  import ariane_pkg::*;
  parameter int Ports = 2;
  logic clk = 0, rst_n = 0, halt = 0;
  scoreboard_entry_t [Ports-1:0] entries = '0, next_entries;
  amo_resp_t amo = '0;
  logic [Ports-1:0] drop = '0, ack, gpr, fpr;
  logic [Ports-1:0][CVA6Cfg.XLEN-1:0] value;
  logic [Ports-1:0][4:0] addr;
  int checks = 0;
  always #5 clk = ~clk;
  g6lc_commit_defaults_dut #(.Ports(Ports)) dut (
    .clk_i(clk), .rst_ni(rst_n), .halt_i(halt), .entries_i(entries),
    .drop_i(drop), .replay_i('0), .amo_i(amo),
    .ack_o(ack), .gpr_o(gpr), .fpr_o(fpr), .data_o(value), .addr_o(addr)
  );
  task automatic ok(input bit condition, input string label);
    checks++;
    assert(condition) else $fatal(1, "COMMIT_DEFAULTS_FAIL %s ports=%0d", label, Ports);
  endtask
  task automatic tick;
    @(posedge clk); #1;
  endtask
  initial begin
    repeat (3) tick(); rst_n = 1; tick();
    ok(gpr == 0 && fpr == 0 && ack == 0, "empty");
    if ($test$plusargs("oracle_negative")) ok(0, "negative-oracle");
    next_entries = '0;
    for (int i = 0; i < Ports; i++) begin
      next_entries[i].valid = 1;
      next_entries[i].fu = ALU; next_entries[i].op = ADD;
      next_entries[i].result = 64'h1234 + i; next_entries[i].rd = 5'(8+i);
      next_entries[i].trans_id = CVA6Cfg.TRANS_ID_BITS'(i);
    end
    entries = next_entries; #1;
    ok((&gpr) && (&ack) && fpr == 0, "ordinary-retire");
    for (int i = 0; i < Ports; i++)
      ok(value[i] == next_entries[i].result && addr[i] == next_entries[i].rd, "ordinary-payload");
    halt = 1; #1; ok(gpr == 0 && fpr == 0 && ack == 0, "halt-no-writes"); halt = 0;
    drop = '1; #1; ok(gpr == 0 && fpr == 0, "drop-no-writes"); drop = 0;
    if (Ports == 2 && CVA6Cfg.RVA && CVA6Cfg.RVZacas) begin
      next_entries = '0; next_entries[0].valid = 1;
      next_entries[0].fu = STORE; next_entries[0].op = AMO_CASQ;
      next_entries[0].rd = 8;
      entries = next_entries;
      amo = '{default: '0}; amo.ack = 1; amo.dual_we = 1;
      amo.result = 64'hCAB0; amo.result_hi = 64'hCAB1; #1;
      ok(gpr == 3 && ack[0] && value[0] == 'hCAB0 && value[1] == 'hCAB1 &&
         addr[1] == 9, "dual-AMO-payload");
      halt = 1; #1; ok(gpr == 0 && fpr == 0 && ack == 0, "late-AMO-halt-no-writes");
      halt = 0; drop = '1; #1;
      ok(gpr == 0 && fpr == 0 && ack[0], "late-AMO-drop-no-writes");
      drop = 0; next_entries[0].valid = 0; entries = next_entries; #1;
      ok(gpr == 0 && fpr == 0 && ack == 0, "late-AMO-invalid-no-writes");
    end
    $display("COMMIT_DEFAULTS_PASS ports=%0d checks=%0d", Ports, checks);
    $finish;
  end
  initial begin #10000; $fatal(1, "COMMIT_DEFAULTS_TIMEOUT"); end
endmodule
