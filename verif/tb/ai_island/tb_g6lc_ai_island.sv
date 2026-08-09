// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Standalone Verilator TB for P3 island spine (cap + AI-3 + desc engine).
// Does not require the full Variane SoC.

`timescale 1ns/1ps

module tb_g6lc_ai_island;
  import g6lc_ai_desc_pkg::*;

  logic        clk, rst_ni;
  logic        req, we;
  logic [15:0] addr;
  logic [31:0] wdata, rdata;
  logic        rvalid, irq;

  int unsigned errors;
  int unsigned cycles;

  g6lc_ai_island_top i_dut (
      .clk_i     (clk),
      .rst_ni    (rst_ni),
      .testmode_i(1'b0),
      .req_i     (req),
      .we_i      (we),
      .addr_i    (addr),
      .wdata_i   (wdata),
      .rdata_o   (rdata),
      .rvalid_o  (rvalid),
      .irq_o     (irq)
  );

  initial clk = 0;
  always #5 clk = ~clk;

  task automatic tick;
    @(posedge clk);
    cycles++;
    req  <= 1'b0;
    we   <= 1'b0;
  endtask

  task automatic reg_write(input logic [15:0] a, input logic [31:0] d);
    @(negedge clk);
    req   <= 1'b1;
    we    <= 1'b1;
    addr  <= a;
    wdata <= d;
    @(posedge clk);
    cycles++;
    @(negedge clk);
    req <= 1'b0;
    we  <= 1'b0;
  endtask

  task automatic reg_read(input logic [15:0] a, output logic [31:0] d);
    @(negedge clk);
    req  <= 1'b1;
    we   <= 1'b0;
    addr <= a;
    @(posedge clk);
    cycles++;
    @(posedge clk);
    cycles++;
    d = rdata;
    @(negedge clk);
    req <= 1'b0;
  endtask

  task automatic wait_done(output logic [15:0] st, output logic [31:0] ticket);
    logic [31:0] v;
    int guard;
    guard = 0;
    forever begin
      reg_read(16'h010C, v);
      if (v[0]) break;
      guard++;
      if (guard > 200) begin
        $error("timeout waiting for done");
        errors++;
        st = 16'hFFFF;
        ticket = 0;
        return;
      end
    end
    reg_read(16'h0110, ticket);
    reg_read(16'h0114, v);
    st = v[15:0];
    reg_write(16'h010C, 32'h1);  // clear sticky
  endtask

  task automatic program_region(
      input int unsigned q,
      input logic [63:0] base,
      input logic [63:0] limit,
      input logic [1:0]  perm
  );
    logic [15:0] b;
    b = 16'h0120 + 16'(q * 32);
    reg_write(b + 16'h0, base[31:0]);
    reg_write(b + 16'h4, base[63:32]);
    reg_write(b + 16'h8, limit[31:0]);
    reg_write(b + 16'hC, limit[63:32]);
    reg_write(b + 16'h10, {30'h0, perm});
  endtask

  task automatic load_desc(input desc_t d);
    desc_bits_t b;
    int i;
    b = desc_to_bits(d);
    for (i = 0; i < 16; i++)
      reg_write(16'h0140 + 16'(i * 4), b[i*32 +: 32]);
  endtask

  function automatic desc_t make_ok_desc;
    desc_t d;
    d = '0;
    d.version   = 16'(ContractVersion);
    d.op        = OP_GEMM;
    d.flags     = 32'h0;
    d.m         = 32'd8;
    d.n         = 32'd8;
    d.k         = 32'd8;
    d.ld_ab     = 32'h0008_0008;
    d.ptr_a     = 64'h0000_0000_8001_0000;
    d.ptr_b     = 64'h0000_0000_8001_1000;
    d.ptr_c     = 64'h0000_0000_8001_2000;
    d.ptr_scale = 64'h0;
    d.ptr_done  = 64'h0000_0000_8001_3000;
    return d;
  endfunction

  initial begin
    logic [31:0] r;
    logic [15:0] st;
    logic [31:0] ticket;
    desc_t d;

    errors = 0;
    cycles = 0;
    req = 0; we = 0; addr = 0; wdata = 0;
    rst_ni = 0;
    repeat (5) tick;
    rst_ni = 1;
    repeat (2) tick;

    // ---- Cap window ----
    reg_read(16'h0000, r);
    if (r[15:0] != 16'd1) begin
      $error("cap version got %0h", r); errors++;
    end else $display("PASS cap version=%0d", r[15:0]);

    reg_read(16'h0004, r);
    if (r == 0) begin
      $error("cap clusters zero"); errors++;
    end else $display("PASS cap clusters=%0d", r);

    // ---- Enable ----
    reg_write(16'h0100, 32'h1);

    // Region for q0: [0x80010000, 0x80014000) RW
    program_region(0, 64'h8001_0000, 64'h8001_4000, 2'b11);

    // ---- Good descriptor ----
    d = make_ok_desc();
    load_desc(d);
    reg_write(16'h0108, 32'h0000_0A00);  // ticket=10 (bits[31:8]), qid=0
    wait_done(st, ticket);
    if (st != ST_OK || ticket != 32'd10) begin
      $error("good desc: status=%0d ticket=%0d", st, ticket); errors++;
    end else $display("PASS good desc status=OK ticket=%0d", ticket);

    // ---- Bad pointer (outside region) ----
    d = make_ok_desc();
    d.ptr_a = 64'h0000_0000_9000_0000;  // outside
    load_desc(d);
    reg_write(16'h0108, 32'h0000_0B00);  // ticket=11
    wait_done(st, ticket);
    if (st != ST_BAD_PTR) begin
      $error("bad ptr: expected ST_BAD_PTR got %0d", st); errors++;
    end else $display("PASS AI-3 reject bad ptr status=%0d", st);

    // ---- Bad version ----
    d = make_ok_desc();
    d.version = 16'd99;
    load_desc(d);
    reg_write(16'h0108, 32'h0000_0C00);
    wait_done(st, ticket);
    if (st != ST_BAD_VER) begin
      $error("bad ver: expected ST_BAD_VER got %0d", st); errors++;
    end else $display("PASS bad version status=%0d", st);

    // ---- Write-only region rejects read of A ----
    program_region(0, 64'h8001_0000, 64'h8001_4000, 2'b10);  // W only
    d = make_ok_desc();
    load_desc(d);
    reg_write(16'h0108, 32'h0000_0D00);
    wait_done(st, ticket);
    if (st != ST_BAD_PTR) begin
      $error("W-only region: expected ST_BAD_PTR got %0d", st); errors++;
    end else $display("PASS AI-3 perm reject status=%0d", st);

    // ---- Disabled engine ----
    reg_write(16'h0100, 32'h0);
    program_region(0, 64'h8001_0000, 64'h8001_4000, 2'b11);
    d = make_ok_desc();
    load_desc(d);
    reg_write(16'h0108, 32'h0000_0E00);
    wait_done(st, ticket);
    if (st != ST_DISABLED) begin
      $error("disabled: expected ST_DISABLED got %0d", st); errors++;
    end else $display("PASS disabled engine status=%0d", st);

    if (errors == 0) begin
      $display("*** SUCCESS *** ai-island P3 spine (%0d cycles)", cycles);
      $finish(0);
    end else begin
      $display("*** FAILED *** %0d errors", errors);
      $finish(1);
    end
  end

  // Absolute timeout
  initial begin
    #1_000_000;
    $error("global timeout");
    $finish(2);
  end

endmodule
