// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Side-by-side harness for the loop buffer: the live `g6lc_loop_buffer`
// against a reference copy renamed `g6lc_loop_buffer_old` (A136 registered
// expectation addresses; cycle-exact outputs expected). The stimulus keeps a
// small set of loop bodies so arm / sequential fill / close / replay / wrap /
// disarm / flush all occur, and drives the fill and lookup addresses from the
// reference's own expectations so captures and hits actually happen.
module g6lc_lbuf_timing
  import g6lc_core_pkg::*;
#(
  parameter int unsigned ENTRIES = 8,
  parameter int unsigned DATA_W = 64,
  parameter int unsigned ALIGN = 3
) (
  input  logic clk_i, rst_ni, flush_i, enable_i,
  input  logic cf_valid_i, cf_taken_i,
  input  logic [63:0] cf_pc_i, cf_target_i,
  input  logic fill_valid_i,
  input  logic [63:0] fill_vaddr_i,
  input  logic [DATA_W-1:0] fill_data_i,
  input  logic [63:0] lookup_vaddr_i,
  input  logic lookup_ready_i,
  output logic hit_o,
  output logic [DATA_W-1:0] data_o,
  output logic active_o, consume_o
);
  function automatic config_pkg::g6lc_cfg_t cfg();
    cfg = config_pkg::g6lc_cfg_empty;
    cfg.XLEN = 64; cfg.VLEN = 64;
    cfg.FETCH_WIDTH = DATA_W; cfg.FETCH_ALIGN_BITS = ALIGN;
  endfunction
  g6lc_loop_buffer #(.G6LCCfg(cfg()), .NR_ENTRIES(ENTRIES), .DATA_W(DATA_W)) dut (.*);
endmodule

module tb_g6lc_loop_buffer_sbs;
  import g6lc_core_pkg::*;
  parameter int unsigned ENTRIES = 8;
  parameter int unsigned DATA_W = 64;
  parameter int unsigned ALIGN = 3;
  function automatic config_pkg::g6lc_cfg_t cfg();
    cfg = config_pkg::g6lc_cfg_empty;
    cfg.XLEN = 64; cfg.VLEN = 64;
    cfg.FETCH_WIDTH = DATA_W; cfg.FETCH_ALIGN_BITS = ALIGN;
  endfunction
  localparam config_pkg::g6lc_cfg_t Cfg = cfg();
  logic clk = 0, rst_ni = 0, flush_i, enable_i, cf_valid_i, cf_taken_i, fill_valid_i, lookup_ready_i;
  logic [63:0] cf_pc_i, cf_target_i, fill_vaddr_i, lookup_vaddr_i;
  logic [DATA_W-1:0] fill_data_i;
  logic hit_o, hit_n, active_o, active_n, consume_o, consume_n;
  logic [DATA_W-1:0] data_o, data_n;
  g6lc_loop_buffer_old #(.G6LCCfg(Cfg), .NR_ENTRIES(ENTRIES), .DATA_W(DATA_W)) u_old (
    .clk_i(clk), .rst_ni, .flush_i, .enable_i, .cf_valid_i, .cf_taken_i, .cf_pc_i, .cf_target_i,
    .fill_valid_i, .fill_vaddr_i, .fill_data_i, .lookup_vaddr_i, .lookup_ready_i,
    .hit_o(hit_o), .data_o(data_o), .active_o(active_o), .consume_o(consume_o));
  g6lc_loop_buffer #(.G6LCCfg(Cfg), .NR_ENTRIES(ENTRIES), .DATA_W(DATA_W)) u_new (
    .clk_i(clk), .rst_ni, .flush_i, .enable_i, .cf_valid_i, .cf_taken_i, .cf_pc_i, .cf_target_i,
    .fill_valid_i, .fill_vaddr_i, .fill_data_i, .lookup_vaddr_i, .lookup_ready_i,
    .hit_o(hit_n), .data_o(data_n), .active_o(active_n), .consume_o(consume_n));
  always #1 clk = ~clk;
  int unsigned cyc = 0, errors = 0, hits = 0, fills = 0, arms = 0, flushes = 0, wraps = 0, seed = 1;
  logic [63:0] bases[4];
  initial begin
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    void'($urandom(seed));
    for (int i = 0; i < 4; i++) bases[i] = 64'h8000_0000 + (($urandom % 64) << ALIGN);
    flush_i = 0; enable_i = 1; cf_valid_i = 0; cf_taken_i = 0; cf_pc_i = 0; cf_target_i = 0;
    fill_valid_i = 0; fill_vaddr_i = 0; fill_data_i = 0; lookup_vaddr_i = 0; lookup_ready_i = 0;
    #5 rst_ni = 1;
  end
  always @(negedge clk) if (rst_ni) begin
    automatic int unsigned r = $urandom;
    automatic logic [63:0] b = bases[r % 4];
    automatic int unsigned len = 1 + ($urandom % (ENTRIES + 2));
    flush_i    = ($urandom % 1500) == 0;
    enable_i   = ($urandom % 64) != 0;
    cf_valid_i = ($urandom % 6) == 0;
    cf_taken_i = ($urandom % 5) != 0;
    cf_target_i = b;
    // back edges of varied span, sometimes too long or forward
    cf_pc_i = (($urandom % 8) == 0) ? b - 64'(8) : b + (64'(len) << ALIGN) - 64'(2);
    if (($urandom % 4) == 0) cf_target_i = b + 64'(($urandom % 3) << ALIGN);
    // fill: mostly the reference's expected next address, sometimes random
    fill_valid_i = ($urandom % 3) != 0;
    fill_vaddr_i = (($urandom % 10) == 0) ? bases[$urandom % 4] : u_old.expect_fill;
    fill_data_i  = {$urandom, $urandom};
    // lookup: mostly the expected replay address, sometimes random
    lookup_vaddr_i  = (($urandom % 8) == 0) ? bases[$urandom % 4] + 64'(($urandom % 4) << ALIGN) : u_old.expect_pc;
    lookup_ready_i  = ($urandom % 4) != 0;
  end
  always @(posedge clk) if (rst_ni) begin
    cyc++;
    #0.2;
    if (hit_o !== hit_n || data_o !== data_n || active_o !== active_n || consume_o !== consume_n) begin
      errors++;
      if (errors < 8) $display("MISMATCH cyc=%0d hit %b/%b data %h/%h active %b/%b consume %b/%b",
                               cyc, hit_o, hit_n, data_o, data_n, active_o, active_n, consume_o, consume_n);
    end
    if (hit_o) hits++;
    if (u_old.fill_accept) fills++;
    if (u_old.short_back && !u_old.capturing_q && enable_i && !flush_i) arms++;
    if (flush_i) flushes++;
    if (consume_o && u_old.replay_d == '0) wraps++;
    if (errors > 8) $fatal(1, "FAIL tb_g6lc_loop_buffer_sbs errors=%0d", errors);
    if (cyc == 300000) begin
      if (errors != 0 || hits == 0 || fills == 0 || arms == 0 || flushes == 0 || wraps == 0)
        $fatal(1, "FAIL/vacuous hits=%0d fills=%0d arms=%0d flushes=%0d wraps=%0d errors=%0d",
               hits, fills, arms, flushes, wraps, errors);
      $display("PASS tb_g6lc_loop_buffer_sbs cycles=%0d hits=%0d fills=%0d arms=%0d flushes=%0d wraps=%0d errors=0",
               cyc, hits, fills, arms, flushes, wraps);
      $finish;
    end
  end
endmodule
