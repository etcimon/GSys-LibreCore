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
  logic redirect2_valid=0, redirect2_hart=0;
  logic [63:0] redirect2_pc=0;
  g6lc_fetch_pkg::restart_t fr;
  bit negative;
  g6lc_smt_pc_bank #(.CVA6Cfg(cfg(2))) dut (
    .clk_i(clk),.rst_ni(rst_n),.boot_addr_i(64'h10000),
    .npc_live_i(live_pc),.npc_live_valid_i(1'b1),
    .retire_valid_i(retire_valid),.retire_hart_i(retire_hart),.retire_pc_i(retire_pc),
    .redirect_valid_i(redirect_valid),.redirect_hart_i(redirect_hart),.redirect_pc_i(redirect_pc),
    .redirect2_valid_i(redirect2_valid),.redirect2_hart_i(redirect2_hart),.redirect2_pc_i(redirect2_pc),
    .active_hart_i(active),.switch_i(switch_req),.npc_alt_valid_i(1'b0),.npc_alt_i('0),
    .npc_restore_o(restored_pc),.restore_o(restored),.outgoing_hart_o(outgoing)
  );
  g6lc_smt_pc_bank #(.CVA6Cfg(cfg(1))) single (
    .clk_i(clk),.rst_ni(rst_n),.boot_addr_i(64'h10000),
    .npc_live_i(live_pc),.npc_live_valid_i(1'b1),
    .retire_valid_i(retire_valid),.retire_hart_i('0),.retire_pc_i(retire_pc),
    .redirect_valid_i(redirect_valid),.redirect_hart_i(1'b0),.redirect_pc_i(redirect_pc),
    .redirect2_valid_i(1'b0),.redirect2_hart_i('0),.redirect2_pc_i('0),
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
    // --- T6b-2a: second redirect port (peer restart / inactive-hart mispredict)
    // Banks now: hart0=0x9002, hart1=0xa004, active=0.
    // P-A: a redirect2 for the INACTIVE hart writes only its bank — the active
    // hart's restore view neither pulses nor moves.
    redirect2_valid=1; redirect2_hart=1; redirect2_pc=64'h5000;
    tick(); redirect2_valid=0; #2;
    if (restored) $fatal(1,"RESTART_PEER_PULSE");
    if ((restored_pc ^ (negative?64'd1:64'd0)) !== 64'h9002)
      $fatal(1,"RESTART_PEER_NOACTIVE got=%h want=9002",restored_pc);
    // The write lands: switching to hart 1 restores the redirect2 target.
    active=1; switch_req=1; check(64'h5000); tick(); switch_req=0; tick();
    active=0; switch_req=1; check(64'h9002); tick(); switch_req=0; tick();
    // P-B: a redirect2 for the ACTIVE hart must not disturb the peer bank.
    redirect2_valid=1; redirect2_hart=0; redirect2_pc=64'h6000;
    tick(); redirect2_valid=0; #2;
    if (restored) $fatal(1,"RESTART_PEER2_PULSE");
    active=1; switch_req=1; check(64'h5000); tick(); switch_req=0; tick();
    active=0; switch_req=1; check(64'h6000); tick(); switch_req=0; tick();
    // P-C: the primary port keeps its semantics alongside port 2 — a same-cycle
    // pair writes different banks.
    redirect_valid=1; redirect_hart=0; redirect_pc=64'h7000;
    redirect2_valid=1; redirect2_hart=1; redirect2_pc=64'h7100;
    tick(); redirect_valid=0; redirect2_valid=0; tick();
    active=1; switch_req=1; check(64'h7100); tick(); switch_req=0; tick();
    active=0; switch_req=1; check(64'h7000); tick(); switch_req=0; tick();
    // --- T6b-3b: partial-flush peer restart ---------------------------------
    // F-A: hart0's mispredict while hart1 holds decode-stage PC X and queue
    // PC X+4 — the peer's frontier is X (the decode entry wins; the mispredict
    // redirect is for hart0 and must not retarget hart1's frontier).
    fr = g6lc_fetch_pkg::restart_frontier(
        2, 8'd1,
        8'b00000001, '{0:8'd1, default:'0}, '{0:64'h8c30, default:'0},
        8'b00000001, '{0:8'd1, default:'0}, '{0:64'h8c34, default:'0},
        '{valid: 1'b1, pc: 64'h8c38},
        1'b1, 8'd0, 64'h7000);
    if (!fr.valid || fr.pc != 64'h8c30)
      $fatal(1,"RESTART_FRONTIER_DECODE got=%h",fr.pc);
    // F-B: the killed-parcel gap — hart1's only surviving frontier is the
    // fetch-side transport (the in-flight request killed mid-flight). It must
    // restart there, never at the fetch-ahead cursor.
    fr = g6lc_fetch_pkg::restart_frontier(
        2, 8'd1, '0, '0, '0, '0, '0, '0,
        '{valid: 1'b1, pc: 64'h8c2e}, 1'b0, '0, '0);
    if (!fr.valid || fr.pc != 64'h8c2e)
      $fatal(1,"RESTART_FRONTIER_INFLIGHT got=%h",fr.pc);
    // F-C: a queue entry still outranks the fetch-side transport — the queue
    // head is fetch-order older than any live fetch position.
    fr = g6lc_fetch_pkg::restart_frontier(
        2, 8'd1, '0, '0, '0,
        8'b00000001, '{0:8'd1, default:'0}, '{0:64'h8c30, default:'0},
        '{valid: 1'b1, pc: 64'h8c2e}, 1'b0, '0, '0);
    if (!fr.valid || fr.pc != 64'h8c30)
      $fatal(1,"RESTART_FRONTIER_QUEUE got=%h",fr.pc);
    // P-D: the partial-flush cycle — hart0's mispredict rides the primary
    // port while hart1's peer restart takes the second; both banks land in
    // the same cycle. +mut_no_peer drops the second-port write, modelling the
    // peer leg removed: hart1's bank keeps its stale PC and the check fails.
    redirect_valid=1; redirect_hart=0; redirect_pc=64'hb000;
    if (!$test$plusargs("mut_no_peer")) begin
      redirect2_valid=1; redirect2_hart=1; redirect2_pc=64'h8c2e;
    end
    tick(); redirect_valid=0; redirect2_valid=0; tick();
    active=1; switch_req=1; #2;
    // With the peer leg removed the bank keeps its stale value and this
    // check fails — the runner matches RESTART_PEER_MISP for +mut_no_peer.
    if (restored_pc != 64'h8c2e)
      $fatal(1,"RESTART_PEER_MISP hart1 bank got=%h want=8c2e",restored_pc);
    tick(); switch_req=0; tick();
    active=0; switch_req=1; check(64'hb000); tick(); switch_req=0; tick();
    // P-E: deep-queue peer frontier — the peer's only surviving entries sit
    // deeper than the NrIssuePorts port positions (queued behind the faulting
    // hart's presented slots, invisible to the port view). The per-hart
    // pending-FIFO head is the frontier — modelled here as the queue
    // candidate; the peer is inactive so no fetch transport exists. With the
    // candidate dropped (+mut_no_deep) nothing lands in the peer's bank and
    // its stale PC survives — the killed-window loss this fix closes.
    fr = g6lc_fetch_pkg::restart_frontier(
        2, 8'd1, '0, '0, '0,
        $test$plusargs("mut_no_deep") ? 8'b0 : 8'b00000001,
        '{0:8'd1, default:'0}, '{0:64'h9500, default:'0},
        '{valid: 1'b0, pc: '0},
        1'b0, '0, '0);
    if (fr.valid) begin
      redirect2_valid=1; redirect2_hart=1; redirect2_pc=fr.pc;
    end
    tick(); redirect2_valid=0; tick();
    active=1; switch_req=1; #2;
    if (restored_pc != 64'h9500)
      $fatal(1,"RESTART_PEER_DEEP hart1 bank got=%h want=9500",restored_pc);
    tick(); switch_req=0; tick();
    active=0; switch_req=1; check(64'hb000); tick(); switch_req=0; tick();
    $display("RESTART_BANK_PASS");
    $finish;
  end
endmodule
