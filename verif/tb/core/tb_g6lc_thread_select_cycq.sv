// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_thread_select leaf: the SMT cycle-bounded quantum (CycQuantum).
// A resident hart whose fetch rate is too low to reach SmtFetchQuantum
// (spin loops) must still yield once it has stayed resident for CycQuantum
// cycles; a dense-fetch hart must still yield at the fetch quantum.
//   S1  sparse fetch (one fetch_fire every +ff_every cycles, default 100):
//       the *cycle* bound, not the fetch quantum, drives the switches.
//   S2  dense fetch (fetch_fire every cycle): the fetch quantum still bounds
//       residency well below CycQuantum.
// Both harts must become resident at least once in each phase.
// +oracle_negative raises the switch floor so the run cannot pass.
// +ff_every=N sets the sparse-phase fetch period.
`timescale 1ns/1ps
module tb_g6lc_thread_select_cycq;
  import config_pkg::*;

  parameter int unsigned CYCQ = 1024;   // -> DUT .CycQuantum
  localparam int unsigned Q       = 64; // SmtFetchQuantum
  localparam int unsigned FF_D    = 100;
  localparam int unsigned P1_CYC  = 30000;
  localparam int unsigned P2_CYC  = 6000;
  localparam int unsigned MIN_SW  = 15;

  function automatic config_pkg::g6lc_cfg_t mk_cfg();
    config_pkg::g6lc_cfg_t c;
    c = build_config_pkg::build_config(g6lc_config_pkg::g6lc_cfg);
    c.SmtPolicy       = config_pkg::SMT_RR;
    c.SmtFetchQuantum = Q;
    return c;
  endfunction
  localparam config_pkg::g6lc_cfg_t CFG = mk_cfg();
  localparam int unsigned NH = (CFG.NrHarts < 1) ? 1 : CFG.NrHarts;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  logic fetch_fire, issue_fire, commit;
  logic [CFG.VLEN-1:0] drain_force_pc;
  logic drain_force, drain_force_wfi, drain_force_abs, drain_forced;
  logic quiesce, switch, t0_extra, switch_on_miss, switch_on_quantum, switch_on_starve;
  logic [$clog2(CFG.NrHarts > 1 ? CFG.NrHarts : 2)-1:0] active_hart;

  g6lc_thread_select #(.G6LCCfg(CFG), .CycQuantum(CYCQ)) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .fetch_fire_i(fetch_fire), .issue_fire_i(issue_fire), .flush_i(1'b0),
    .hold_i(1'b0), .drain_ready_i(1'b1), .commit_i(commit),
    .drain_killable_i(1'b1), .head_wfi_i(1'b0),
    .head_plain_i(1'b1), .head_pc_i('0),
    .drain_force_o(drain_force), .drain_force_wfi_o(drain_force_wfi),
    .drain_force_abs_o(drain_force_abs), .drain_forced_o(drain_forced),
    .drain_force_pc_o(drain_force_pc), .quiesce_o(quiesce),
    .id_uniss_i(1'b1), .iq_valid_i(1'b1), .t0_imm_i(1'b0),
    .trap_hold_i(1'b0),
    .hart_ready_i({CFG.NrHarts{1'b1}}), .hart_dmiss_i('0),
    .hart_imiss_i('0), .hart_block_i('0),
    .pause_hint_i('0),
    .active_hart_o(active_hart), .switch_o(switch), .t0_extra_o(t0_extra),
    .switch_on_miss_o(switch_on_miss), .switch_on_quantum_o(switch_on_quantum),
    .switch_on_starve_o(switch_on_starve)
  );

  int unsigned ff_every;
  int unsigned cyc = 0;
  int unsigned sw = 0, ff = 0, last_cyc = 0, last_ff = 0;
  int unsigned maxres = 0, minintf = '1, maxintf = 0;
  logic [NH-1:0] seen = '0;
  // phase-1 (sparse) snapshot
  int unsigned s1_sw = 0, s1_maxres = 0;
  logic [NH-1:0] s1_seen = '0;
  bit s1_done = 0, s2_done = 0;

  task automatic note_interval(input int unsigned iv_c, input int unsigned iv_f);
    if (iv_c > maxres) maxres <= iv_c;
    if (iv_f < minintf) minintf <= iv_f;
    if (iv_f > maxintf) maxintf <= iv_f;
  endtask

  always @(posedge clk) begin
    if (rst_n) begin
      // phase boundaries off the cycle count: [0,P1_CYC) sparse, then dense.
      if (!s1_done && cyc >= P1_CYC) begin
        note_interval(cyc - last_cyc, ff - last_ff);   // trailing residency
        s1_sw     <= sw;
        s1_maxres <= maxres;
        s1_seen   <= seen;
        sw <= 0; ff <= 0; maxres <= 0; minintf <= '1; maxintf <= 0; seen <= '0;
        last_cyc <= cyc; last_ff <= ff;
        s1_done <= 1'b1;
      end
      if (s1_done && !s2_done && cyc >= P1_CYC + P2_CYC) begin
        note_interval(cyc - last_cyc, ff - last_ff);   // trailing residency
        s2_done <= 1'b1;
      end
      cyc <= cyc + 1;
      // sparse phase: one fetch every ff_every cycles; dense phase: every cycle
      fetch_fire <= ((!s1_done && ((cyc % ff_every) == ff_every - 1)) ||
                     (s1_done && !s2_done));
      issue_fire <= fetch_fire;
      commit     <= (cyc % 7 == 0);
      seen[int'(active_hart)] <= 1'b1;
      if (fetch_fire) ff <= ff + 1;
      if (switch) begin
        sw <= sw + 1;
        note_interval(cyc - last_cyc, ff - last_ff);
        last_cyc <= cyc;
        last_ff  <= ff;
      end
    end
  end

  initial begin
    int unsigned floor;
    fetch_fire = 0; issue_fire = 0; commit = 0;
    void'($value$plusargs("ff_every=%0d", ff_every));
    if (ff_every == 0) ff_every = FF_D;
    floor = $test$plusargs("oracle_negative") ? 1000 : MIN_SW;
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (P1_CYC + P2_CYC + 40) @(posedge clk);
    // ---- S1: sparse fetch, cycle bound must drive the switches ----
    // RESIDENT_TOO_LONG is checked first so the -GCYCQ=0 build (no cycle
    // bound -> ~fetch-quantum residency) reports the cycle-bound failure
    // rather than the incidental switch-count shortfall.
    if (s1_maxres > CYCQ + 64)
      $fatal(1, "TSEL_CYCQ_S1_RESIDENT_TOO_LONG max_resident=%0d cyc > %0d",
             s1_maxres, CYCQ + 64);
    if (s1_sw < floor)
      $fatal(1, "TSEL_CYCQ_S1_FEW_SWITCHES switches=%0d (floor %0d)", s1_sw, floor);
    if (s1_seen !== {NH{1'b1}})
      $fatal(1, "TSEL_CYCQ_S1_HART_NOT_RESIDENT seen=%b", s1_seen);
    // ---- S2: dense fetch, fetch quantum must still bound residency ----
    if (sw < 8)
      $fatal(1, "TSEL_CYCQ_S2_FEW_SWITCHES switches=%0d", sw);
    if (maxintf < Q - 2 || maxintf > Q + 2)
      $fatal(1, "TSEL_CYCQ_S2_FETCH_QUANTUM_LOST fetches_per_resident=[%0d,%0d] quantum=%0d",
             minintf, maxintf, Q);
    if (maxres >= CYCQ)
      $fatal(1, "TSEL_CYCQ_S2_CYCLE_BOUND_LEAKED max_resident=%0d cyc >= %0d",
             maxres, CYCQ);
    if (seen !== {NH{1'b1}})
      $fatal(1, "TSEL_CYCQ_S2_HART_NOT_RESIDENT seen=%b", seen);
    $display("PASS tb_g6lc_thread_select_cycq CYCQ=%0d ff_every=%0d s1_sw=%0d s1_maxres=%0d s2_sw=%0d s2_fetches=[%0d,%0d] s2_maxres=%0d",
             CYCQ, ff_every, s1_sw, s1_maxres, sw, minintf, maxintf, maxres);
    $finish;
  end
endmodule
