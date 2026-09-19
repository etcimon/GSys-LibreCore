// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

module tb_g6lc_restart;
  function automatic config_pkg::cva6_cfg_t cfg(input int harts);
    config_pkg::cva6_cfg_t c = config_pkg::cva6_cfg_empty;
    c.XLEN = 64;
    c.VLEN = 64;
    c.NrHarts = harts;
    c.NrCommitPorts = 2;
    return c;
  endfunction
  logic clk=0, rst_n=0, active=0, switch_req=0;
  logic [63:0] restored_pc, single_pc, live_pc=64'hbad0;
  logic restored, outgoing, single_restore, single_outgoing;
  logic [1:0] retire_valid=0, retire_hart=0;
  logic [1:0][63:0] retire_pc='0;
  logic redirect_valid=0, redirect_hart=0;
  logic [63:0] redirect_pc=0;
  bit negative;
  g6lc_smt_pc_bank #(.CVA6Cfg(cfg(2))) dut (
    .clk_i(clk),.rst_ni(rst_n),.boot_addr_i(64'h10000),
    .npc_live_i(live_pc),.npc_live_valid_i(1'b1),
    .retire_valid_i(retire_valid),.retire_hart_i(retire_hart),.retire_pc_i(retire_pc),
    .redirect_valid_i(redirect_valid),.redirect_hart_i(redirect_hart),.redirect_pc_i(redirect_pc),
    .active_hart_i(active),.switch_i(switch_req),.npc_alt_valid_i(1'b0),.npc_alt_i('0),
    .npc_restore_o(restored_pc),.restore_o(restored),.outgoing_hart_o(outgoing)
  );
  g6lc_smt_pc_bank #(.CVA6Cfg(cfg(1))) single (
    .clk_i(clk),.rst_ni(rst_n),.boot_addr_i(64'h10000),
    .npc_live_i(live_pc),.npc_live_valid_i(1'b1),
    .retire_valid_i(retire_valid),.retire_hart_i('0),.retire_pc_i(retire_pc),
    .redirect_valid_i(redirect_valid),.redirect_hart_i(1'b0),.redirect_pc_i(redirect_pc),
    .active_hart_i(1'b0),.switch_i(switch_req),.npc_alt_valid_i(1'b0),.npc_alt_i('0),
    .npc_restore_o(single_pc),.restore_o(single_restore),.outgoing_hart_o(single_outgoing)
  );
  task automatic tick;
    #2; clk=1; #2; clk=0; #2;
    if (single_pc || single_restore || single_outgoing) $fatal(1,"RESTART_SINGLE");
  endtask
  task automatic check(input logic [63:0] expected);
    #2;
    if ((restored_pc ^ (negative ? 64'd1 : 64'd0)) !== expected)
      $fatal(1,"RESTART_ARCH_PC expected=%h actual=%h",expected,restored_pc);
  endtask
  initial begin
    negative=$test$plusargs("oracle_negative");
    tick(); rst_n=1;
    retire_valid=2'b11; retire_hart=0; retire_pc[0]=64'h202; retire_pc[1]=64'h306;
    tick(); retire_valid=0;
    active=1; switch_req=1; check(64'h10000); tick(); switch_req=0; tick();
    retire_valid=1; retire_hart=1; retire_pc[0]=64'h402;
    tick(); retire_valid=0;
    active=0; switch_req=1; check(64'h306); tick(); switch_req=0; tick();
    redirect_valid=1; redirect_hart=0; redirect_pc=0;
    retire_valid=1; retire_hart=0; retire_pc[0]=64'h666;
    tick(); redirect_valid=0; retire_valid=0;
    active=1; switch_req=1; check(64'h402); tick(); switch_req=0; tick();
    active=0; switch_req=1; check(0); tick(); switch_req=0; tick();
    retire_valid=1; retire_hart=0; retire_pc[0]=64'h8002;
    tick(); retire_valid=0;
    live_pc=64'h8004;
    active=1; switch_req=1; check(64'h402); tick(); switch_req=0; tick();
    active=0; switch_req=1; check(64'h8002); tick(); switch_req=0;
    retire_valid=3; retire_hart=2; retire_pc[0]=64'h9002; retire_pc[1]=64'ha004;
    tick(); retire_valid=0;
    active=1; switch_req=1; check(64'ha004); tick(); switch_req=0; tick();
    active=0; switch_req=1; check(64'h9002); tick(); switch_req=0;
    $display("RESTART_BANK_PASS");
    $finish;
  end
endmodule
