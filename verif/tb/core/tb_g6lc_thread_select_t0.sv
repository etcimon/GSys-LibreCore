// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_thread_select leaf: the I4bg `li t0` deferral of a quantum switch is
// bounded. The resident loop is OpenSBI's _wait_for_boot_hart seen from the
// selector: one fetch_fire per iteration, and an ALU-immediate write of t0
// issued a few cycles before it, so t0_extra_q is set at every cycle the
// quantum predicate is evaluated. Unbounded, the switch never happens and the
// peer (the boot hart) starves forever.
//   S1  both harts become resident, repeatedly (>= MIN_SWITCHES switches)
//   S2  the deferral is still granted: a switch needs more than Q fetches
//   S3  and it is one fetch, not a second quantum
// +oracle_negative raises the switch floor past what the run can reach.
`timescale 1ns/1ps
module tb_g6lc_thread_select_t0;
  import config_pkg::*;

  localparam int unsigned Q      = 64;
  localparam int unsigned PERIOD = 49;
  localparam int unsigned CYCLES = PERIOD * Q * 8;
  localparam int unsigned MIN_SWITCHES = 5;

  function automatic config_pkg::g6lc_cfg_t mk_cfg();
    config_pkg::g6lc_cfg_t c;
    c = build_config_pkg::build_config(g6lc_config_pkg::g6lc_cfg);
    c.SmtPolicy       = config_pkg::SMT_RR;
    c.SmtFetchQuantum = Q;
    return c;
  endfunction
  localparam config_pkg::g6lc_cfg_t CFG = mk_cfg();

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic fetch_fire, issue_fire, t0_imm, commit;
  logic [CFG.VLEN-1:0] drain_force_pc;
  logic drain_force, drain_force_wfi, drain_force_abs, drain_forced;
  logic quiesce, switch, t0_extra, switch_on_miss, switch_on_quantum, switch_on_starve;
  logic [$clog2(CFG.NrHarts > 1 ? CFG.NrHarts : 2)-1:0] active_hart;

  g6lc_thread_select #(.G6LCCfg(CFG)) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .fetch_fire_i(fetch_fire), .issue_fire_i(issue_fire), .flush_i(1'b0),
    .hold_i(1'b0), .drain_ready_i(1'b1), .commit_i(commit),
    .drain_killable_i(1'b1), .head_wfi_i(1'b0),
    .head_plain_i(1'b1), .head_pc_i('0),
    .drain_force_o(drain_force), .drain_force_wfi_o(drain_force_wfi),
    .drain_force_abs_o(drain_force_abs), .drain_forced_o(drain_forced),
    .drain_force_pc_o(drain_force_pc), .quiesce_o(quiesce),
    .id_uniss_i(1'b1), .iq_valid_i(1'b1), .t0_imm_i(t0_imm),
    .trap_hold_i(1'b0),
    .hart_ready_i({CFG.NrHarts{1'b1}}), .hart_dmiss_i('0),
    .hart_imiss_i('0), .hart_block_i('0),
    .pause_hint_i('0),
    .active_hart_o(active_hart), .switch_o(switch), .t0_extra_o(t0_extra),
    .switch_on_miss_o(switch_on_miss), .switch_on_quantum_o(switch_on_quantum),
    .switch_on_starve_o(switch_on_starve)
  );

  int unsigned cyc = 0, switches = 0, fetches = 0, min_f = '1, max_f = 0;
  logic [1:0]  seen = '0;

  always @(posedge clk) begin
    if (rst_n) begin
      cyc <= cyc + 1;
      // the resident loop: `li t0` issues, then the iteration's one fetch
      t0_imm     <= (cyc % PERIOD == PERIOD - 9);
      fetch_fire <= (cyc % PERIOD == PERIOD - 4);
      issue_fire <= (cyc % PERIOD == PERIOD - 4) || (cyc % PERIOD == PERIOD - 9);
      commit     <= (cyc % 7 == 0);
      seen[active_hart] <= 1'b1;
      if (fetch_fire) fetches <= fetches + 1;
      if (switch) begin
        switches <= switches + 1;
        if (fetches < min_f) min_f <= fetches;
        if (fetches > max_f) max_f <= fetches;
        fetches <= fetch_fire ? 1 : 0;
      end
    end
  end

  initial begin
    int unsigned floor;
    fetch_fire = 0; issue_fire = 0; t0_imm = 0; commit = 0;
    floor = $test$plusargs("oracle_negative") ? 1000 : MIN_SWITCHES;
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (CYCLES) @(posedge clk);
    if (switches < floor || seen !== 2'b11)
      $fatal(1, "TSEL_T0_S1_PEER_STARVED switches=%0d (floor %0d) harts_resident=%b",
             switches, floor, seen);
    if (min_f <= Q)
      $fatal(1, "TSEL_T0_S2_DEFERRAL_LOST a switch after %0d fetches (quantum %0d)", min_f, Q);
    if (max_f > Q + 3)
      $fatal(1, "TSEL_T0_S3_DEFERRAL_UNBOUNDED a switch after %0d fetches (quantum %0d)", max_f, Q);
    $display("PASS tb_g6lc_thread_select_t0 switches=%0d fetches_per_resident=[%0d,%0d] quantum=%0d",
             switches, min_f, max_f, Q);
    $finish;
  end
endmodule
