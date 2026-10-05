// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Diagnostic client on the bytes+IRQ test transport. Not a stock Mesa ICD
// and not a Venus frontend.

`timescale 1ns/1ps

module tb_g6lc_apu_spirv;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic prog_we = 0, commit = 0, start = 0;
  logic [6:0] prog_idx = 0;
  logic [31:0] prog_wdata = 0;
  logic [7:0] prog_len = 0;
  logic [31:0] in_a = 0, in_b = 0;
  logic idle, busy, done, fault, irq;
  logic [31:0] result;
  logic off_idle, off_busy, off_done, off_fault, off_irq;
  logic [31:0] off_result;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_spirv #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .prog_we_i(prog_we), .prog_idx_i(prog_idx),
    .prog_wdata_i(prog_wdata), .prog_len_i(prog_len), .commit_i(commit),
    .start_i(start), .in_a_i(in_a), .in_b_i(in_b),
    .idle_o(idle), .busy_o(busy), .done_o(done), .fault_o(fault),
    .irq_o(irq), .result_o(result)
  );
  g6lc_apu_spirv_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .prog_we_i(prog_we), .prog_idx_i(prog_idx),
    .prog_wdata_i(prog_wdata), .prog_len_i(prog_len), .commit_i(commit),
    .start_i(start), .in_a_i(in_a), .in_b_i(in_b),
    .idle_o(off_idle), .busy_o(off_busy), .done_o(off_done),
    .fault_o(off_fault), .irq_o(off_irq), .result_o(off_result)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "spirv timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_idle !== 1'b1 || off_busy !== 1'b0 || off_done !== 1'b0 ||
        off_fault !== 1'b0 || off_irq !== 1'b0 || off_result !== '0)
      $fatal(1, "disabled spirv active");
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask

  task automatic do_reset;
    prog_we = 1'b0;
    commit = 1'b0;
    start = 1'b0;
    prog_idx = '0;
    prog_wdata = '0;
    prog_len = '0;
    in_a = '0;
    in_b = '0;
    @(negedge clk);
    rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  function automatic logic [31:0] enc(input int unsigned wc, input int unsigned op);
    return {16'(wc), 16'(op)};
  endfunction

  task automatic fill_alu(input logic [15:0] alu, ref logic [31:0] mem [0:127],
                          output int unsigned n);
    n = 0;
    mem[n++] = APU_SPIRV_MAGIC;
    mem[n++] = 32'h00010000;
    mem[n++] = 32'h0;
    mem[n++] = 32'd13;
    mem[n++] = 32'h0;
    mem[n++] = enc(2, 17); mem[n++] = 32'd1;
    mem[n++] = enc(3, 14); mem[n++] = 32'd0; mem[n++] = 32'd1;
    mem[n++] = enc(5, 15); mem[n++] = 32'd5; mem[n++] = 32'd8;
    mem[n++] = 32'h6E69616D; mem[n++] = 32'h0;
    mem[n++] = enc(4, 71); mem[n++] = 32'd5; mem[n++] = 32'd33; mem[n++] = 32'd0;
    mem[n++] = enc(4, 71); mem[n++] = 32'd6; mem[n++] = 32'd33; mem[n++] = 32'd1;
    mem[n++] = enc(4, 71); mem[n++] = 32'd7; mem[n++] = 32'd33; mem[n++] = 32'd2;
    mem[n++] = enc(2, 19); mem[n++] = 32'd1;
    mem[n++] = enc(4, 21); mem[n++] = 32'd2; mem[n++] = 32'd32; mem[n++] = 32'd0;
    mem[n++] = enc(4, 32); mem[n++] = 32'd3; mem[n++] = 32'd12; mem[n++] = 32'd2;
    mem[n++] = enc(3, 33); mem[n++] = 32'd4; mem[n++] = 32'd1;
    mem[n++] = enc(4, 59); mem[n++] = 32'd3; mem[n++] = 32'd5; mem[n++] = 32'd12;
    mem[n++] = enc(4, 59); mem[n++] = 32'd3; mem[n++] = 32'd6; mem[n++] = 32'd12;
    mem[n++] = enc(4, 59); mem[n++] = 32'd3; mem[n++] = 32'd7; mem[n++] = 32'd12;
    mem[n++] = enc(5, 54); mem[n++] = 32'd1; mem[n++] = 32'd8; mem[n++] = 32'd0;
    mem[n++] = 32'd4;
    mem[n++] = enc(2, 248); mem[n++] = 32'd9;
    mem[n++] = enc(4, 61); mem[n++] = 32'd2; mem[n++] = 32'd10; mem[n++] = 32'd5;
    mem[n++] = enc(4, 61); mem[n++] = 32'd2; mem[n++] = 32'd11; mem[n++] = 32'd6;
    mem[n++] = enc(5, alu); mem[n++] = 32'd2; mem[n++] = 32'd12; mem[n++] = 32'd10;
    mem[n++] = 32'd11;
    mem[n++] = enc(3, 62); mem[n++] = 32'd7; mem[n++] = 32'd12;
    mem[n++] = enc(1, 253);
    mem[n++] = enc(1, 56);
  endtask

  task automatic load_mem(input logic [31:0] mem [0:127], input int unsigned n);
    int unsigned i;
    for (i = 0; i < n; i++) begin
      @(negedge clk);
      prog_we = 1'b1;
      prog_idx = 7'(i);
      prog_wdata = mem[i];
      @(posedge clk);
    end
    @(negedge clk);
    prog_we = 1'b0;
    prog_idx = '0;
    prog_wdata = '0;
    prog_len = 8'(n);
    @(negedge clk);
    commit = 1'b1;
    @(posedge clk);
    @(negedge clk);
    commit = 1'b0;
  endtask

  task automatic wait_term;
    int unsigned guard;
    guard = 0;
    @(negedge clk);
    start = 1'b1;
    @(posedge clk);
    @(negedge clk);
    start = 1'b0;
    while (!irq && !fault && guard < 1000) begin
      @(posedge clk);
      guard++;
    end
  endtask

  initial begin
    apu_cfg_t cfg;
    logic [31:0] mem [0:127];
    int unsigned n;

    do_reset;
    cases++;
    check("off stays quiet", off_idle == 1'b1 && off_busy == 1'b0 &&
          off_irq == 1'b0 && idle == 1'b1 && !irq && !fault && !done);
    check("profiles keep spirv off",
          !ApuOff.SpirvEn && !ApuP1Transport.SpirvEn && !ApuHarness.SpirvEn &&
          !ApuSchedBoth.SpirvEn && !ApuBadVirglGrant.SpirvEn);
    cfg = ApuP1Transport;
    cfg.SpirvEn = 1'b1;
    check("spirv does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.SpirvEn = 1'b1;
    check("spirv does not legalize virgl", !apu_cfg_legal(cfg) &&
          !apu_cfg_legal(ApuBadVirglGrant));
    check("store is 128 words", APU_SPIRV_IMEM_WORDS == 128 &&
          APU_SPIRV_IDS == 32 && APU_SPIRV_MAGIC == 32'h07230203);

    cases++;
    start = 1'b1;
    @(posedge clk);
    @(negedge clk);
    start = 1'b0;
    @(posedge clk);
    check("start before commit faults", fault && !irq && idle);

    do_reset;
    cases++;
    fill_alu(16'd128, mem, n);
    load_mem(mem, n);
    in_a = 32'd2;
    in_b = 32'd3;
    wait_term;
    check("add irq", irq && done && !fault && !busy);
    check("add 2+3", result == 32'd5);

    cases++;
    in_a = 32'd4;
    in_b = 32'd5;
    wait_term;
    check("mutate irq", irq && done && !fault);
    check("mutate 4+5", result == 32'd9);

    cases++;
    @(negedge clk);
    prog_we = 1'b1;
    prog_idx = 7'd0;
    prog_wdata = APU_SPIRV_MAGIC;
    @(posedge clk);
    @(negedge clk);
    prog_we = 1'b0;
    @(posedge clk);
    check("second store faults", fault && !irq);

    do_reset;
    cases++;
    fill_alu(16'd132, mem, n);
    load_mem(mem, n);
    in_a = 32'd4;
    in_b = 32'd5;
    wait_term;
    check("mul irq", irq && done && !fault);
    check("mul 4*5", result == 32'd20);

    do_reset;
    cases++;
    fill_alu(16'd128, mem, n);
    mem[0] = 32'h0;
    load_mem(mem, n);
    in_a = 32'd2;
    in_b = 32'd3;
    wait_term;
    check("bad magic faults", fault && !irq);

    do_reset;
    cases++;
    n = 0;
    mem[n++] = APU_SPIRV_MAGIC;
    mem[n++] = 32'h00010000;
    mem[n++] = 32'h0;
    mem[n++] = 32'd4;
    mem[n++] = 32'h0;
    mem[n++] = enc(2, 17); mem[n++] = 32'd1;
    mem[n++] = enc(2, 1); mem[n++] = 32'd1;
    load_mem(mem, n);
    wait_term;
    check("unknown opcode faults", fault && !irq);

    if (errors != 0) $fatal(1, "APU spirv errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_spirv cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
