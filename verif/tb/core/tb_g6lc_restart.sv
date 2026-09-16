// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

module tb_g6lc_restart;
  function automatic config_pkg::cva6_cfg_t cfg(input int harts);
    config_pkg::cva6_cfg_t c = config_pkg::cva6_cfg_empty;
    c.XLEN = 64;
    c.VLEN = 64;
    c.NrHarts = harts;
    return c;
  endfunction

  logic clk = 0, rst_n = 0;
  logic active = 0, switch_req = 0, live_valid = 0;
  logic [63:0] live_pc = 0, restored_pc, single_pc;
  logic redirect_valid = 0, redirect_hart = 0;
  logic [63:0] redirect_pc = 0;
  logic restored, outgoing, single_restore, single_outgoing;

  g6lc_smt_pc_bank #(.CVA6Cfg(cfg(2))) dut (
    .clk_i(clk), .rst_ni(rst_n), .boot_addr_i(64'h10000),
    .npc_live_i(live_pc), .npc_live_valid_i(live_valid),
    .redirect_valid_i(redirect_valid), .redirect_hart_i(redirect_hart), .redirect_pc_i(redirect_pc),
    .active_hart_i(active), .switch_i(switch_req),
    .npc_alt_valid_i(1'b0), .npc_alt_i('0),
    .npc_restore_o(restored_pc), .restore_o(restored), .outgoing_hart_o(outgoing)
  );
  g6lc_smt_pc_bank #(.CVA6Cfg(cfg(1))) single (
    .clk_i(clk), .rst_ni(rst_n), .boot_addr_i(64'h10000),
    .npc_live_i(live_pc), .npc_live_valid_i(live_valid),
    .redirect_valid_i(redirect_valid), .redirect_hart_i(redirect_hart), .redirect_pc_i(redirect_pc),
    .active_hart_i(1'b0), .switch_i(switch_req),
    .npc_alt_valid_i(1'b0), .npc_alt_i('0),
    .npc_restore_o(single_pc), .restore_o(single_restore), .outgoing_hart_o(single_outgoing)
  );

  task automatic step(input bit h, sw, valid_pc,
                      input logic [63:0] pc, expected_pc,
                      input bit expected_owner);
    active = h;
    switch_req = sw;
    live_valid = valid_pc;
    live_pc = pc;
    #5;
    if (rst_n) begin
      if (outgoing != expected_owner || restored != sw || (sw && restored_pc != expected_pc))
        $fatal(1, "restart mismatch owner=%0d expected_owner=%0d pc=%h expected_pc=%h", outgoing, expected_owner, restored_pc, expected_pc);
      if (single_pc != 0 || single_restore || single_outgoing)
        $fatal(1, "single-hart bank is not inert");
    end
    clk = 1;
    #5;
    clk = 0;
  endtask

  initial begin
    step(0, 0, 0, 0, 0, 0);
    rst_n = 1;
    step(0, 0, 1, 64'hdead, 0, 0);
    step(1, 1, 1, 64'h68, 64'h10000, 0);
    step(1, 0, 1, 64'h999, 0, 1);
    step(0, 1, 1, 64'h70, 64'h68, 1);
    step(0, 0, 1, 64'h555, 0, 0);
    step(1, 1, 1, 0, 64'h70, 0);
    step(1, 0, 1, 64'hfff, 0, 1);
    step(0, 1, 0, 64'hbad, 0, 1);
    step(0, 0, 1, 64'habc, 0, 0);
    step(1, 1, 1, 64'h80, 64'h70, 0);
    step(1, 0, 1, 64'h123, 0, 1);
    step(0, 1, 1, 64'h60, 64'h80, 1);
    rst_n = 0;
    step(0, 0, 0, 0, 0, 0);
    rst_n = 1;
    step(1, 1, 0, 0, 64'h10000, 0);
    redirect_valid = 1;
    redirect_hart = 0;
    redirect_pc = 64'h94;
    step(1, 0, 0, 0, 0, 1);
    redirect_valid = 0;
    step(0, 1, 0, 0, 64'h94, 1);
    redirect_valid = 1;
    redirect_pc = 64'h88;
    step(0, 0, 0, 0, 0, 0);
    redirect_valid = 0;
    step(1, 1, 0, 0, 64'h10000, 0);
    step(1, 0, 0, 0, 0, 1);
    step(0, 1, 0, 0, 64'h94, 1);
    redirect_valid = 1;
    redirect_pc = 64'ha0;
    step(1, 1, 1, 64'hb0, 64'h10000, 0);
    redirect_valid = 0;
    step(1, 0, 0, 0, 0, 1);
    step(0, 1, 0, 0, 64'ha0, 1);
    redirect_valid = 1;
    redirect_hart = 1;
    redirect_pc = 0;
    step(0, 0, 0, 0, 0, 0);
    redirect_valid = 0;
    step(1, 1, 0, 0, 0, 0);
    $display("RESTART_BANK_PASS");
    $finish;
  end
endmodule
