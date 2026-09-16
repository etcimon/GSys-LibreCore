// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

package g6lc_exec_test_pkg;
  import g6lc_apu_cfg_pkg::*;
  function automatic apu_cfg_t ex_cfg(input bit enabled);
    apu_cfg_t cfg = ApuP1Transport;
    cfg.Enable = enabled;
    cfg.ExecEn = enabled;
    cfg.ExecQuadThreads = 4;
    cfg.ExecRegs = 8;
    cfg.ExecMemWords = 64;
    return cfg;
  endfunction
endpackage

module g6lc_apu_exec_fixture
  import g6lc_apu_pkg::*;
#(parameter bit Enable = 1) (
  input logic clk_i, rst_ni, testmode_i, enable_i, cancel_i, start_i, shader_i,
  input logic imem_we_i,
  input logic [3:0] imem_idx_i,
  input logic [31:0] imem_wdata_i,
  output logic idle_o, busy_o, fault_o,
  input logic [1:0] dbg_thread_i,
  input logic [2:0] dbg_reg_i,
  output logic [31:0] dbg_data_o,
  input logic [5:0] dbg_dmem_idx_i,
  output logic [31:0] dbg_dmem_o,
  input logic dbg_we_i,
  input logic [31:0] dbg_wdata_i
);
  g6lc_apu_exec #(.ApuCfg(g6lc_exec_test_pkg::ex_cfg(Enable))) i_dut (.*);
endmodule

module tb_g6lc_apu_exec;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_exec_test_pkg::*;
  logic clk = 0, rst_ni = 0, enable, cancel, start, shader, idle, busy, fault;
  logic imem_we;
  logic [3:0] imem_idx;
  logic [31:0] imem_wdata;
  logic [1:0] dth;
  logic [2:0] dreg;
  logic [31:0] ddata, dwdata, ddmem;
  logic [5:0] ddmem_idx;
  logic dwe;
  logic off_idle, off_busy, off_fault;
  logic [31:0] off_data;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_exec_fixture i_on (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1), .enable_i(enable), .cancel_i(cancel),
    .start_i(start), .shader_i(shader),
    .imem_we_i(imem_we), .imem_idx_i(imem_idx), .imem_wdata_i(imem_wdata),
    .idle_o(idle), .busy_o(busy), .fault_o(fault),
    .dbg_thread_i(dth), .dbg_reg_i(dreg), .dbg_data_o(ddata),
    .dbg_dmem_idx_i(ddmem_idx), .dbg_dmem_o(ddmem),
    .dbg_we_i(dwe), .dbg_wdata_i(dwdata)
  );
  g6lc_apu_exec_fixture #(.Enable(0)) i_off (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1), .enable_i(enable), .cancel_i(cancel),
    .start_i(start), .shader_i(shader),
    .imem_we_i(imem_we), .imem_idx_i(imem_idx), .imem_wdata_i(imem_wdata),
    .idle_o(off_idle), .busy_o(off_busy), .fault_o(off_fault),
    .dbg_thread_i(dth), .dbg_reg_i(dreg), .dbg_data_o(off_data),
    .dbg_dmem_idx_i(ddmem_idx), .dbg_dmem_o(),
    .dbg_we_i(dwe), .dbg_wdata_i(dwdata)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #20000000; $fatal(1, "exec timeout case=%0d", cases); end
  always @(negedge clk) begin
    #1;
    if ({off_busy, off_fault, off_data} !== '0 || off_idle !== 1'b1)
      $fatal(1, "disabled exec active");
  end
  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask
  task automatic load(input logic [3:0] idx, input logic [31:0] word);
    @(negedge clk); imem_idx = idx; imem_wdata = word; imem_we = 1;
    @(posedge clk); @(negedge clk); imem_we = 0;
  endtask
  task automatic clear_imem;
    integer i;
    for (i = 0; i < APU_EXEC_IMEM; i++)
      load(4'(i), apu_exec_enc(APU_EX_HALT, 0, 0, 0, 0, 0, 0, 0));
  endtask
  task automatic reset_all;
    @(negedge clk); rst_ni = 0; start = 0; cancel = 0; shader = 0; dwe = 0;
    dth = 0; dreg = 0; dwdata = 0; ddmem_idx = 0; imem_we = 0; imem_idx = 0;
    imem_wdata = 0;
    repeat (3) @(negedge clk);
    rst_ni = 1; enable = 1;
    clear_imem();
  endtask
  task automatic run;
    cases++;
    @(negedge clk); start = 1; @(posedge clk); @(negedge clk); start = 0;
    while (!idle) @(negedge clk);
  endtask
  task automatic poke(input logic [1:0] th, input logic [2:0] rg, input logic [31:0] val);
    @(negedge clk); dth = th; dreg = rg; dwdata = val; dwe = 1;
    @(posedge clk); @(negedge clk); dwe = 0;
  endtask
  task automatic peek(input logic [1:0] th, input logic [2:0] rg, output logic [31:0] val);
    @(negedge clk); dth = th; dreg = rg;
    @(posedge clk); val = ddata;
  endtask

  initial begin
    logic [31:0] v0, v1, v2, v3;
    reset_all();

    load(0, apu_exec_enc(APU_EX_TID, 1, 0, 0, 0, 0, 0, 0));
    load(1, apu_exec_enc(APU_EX_LDI, 2, 0, 0, 0, 0, 0, 9'd10));
    load(2, apu_exec_enc(APU_EX_IADD, 3, 1, 2, 0, 0, 0, 0));
    load(3, apu_exec_enc(APU_EX_HALT, 0, 0, 0, 0, 0, 0, 0));
    run();
    peek(0, 3, v0); peek(1, 3, v1); peek(2, 3, v2); peek(3, 3, v3);
    check("iadd t0", v0 == 32'd10);
    check("iadd t1", v1 == 32'd11);
    check("iadd t2", v2 == 32'd12);
    check("iadd t3", v3 == 32'd13);
    check("no fault", !fault);

    clear_imem();
    poke(0, 3, 0); poke(1, 3, 0); poke(2, 3, 0); poke(3, 3, 0);
    load(0, apu_exec_enc(APU_EX_TID, 1, 0, 0, 0, 0, 0, 0));
    load(1, apu_exec_enc(APU_EX_LDI, 2, 0, 0, 0, 0, 0, 9'd2));
    load(2, apu_exec_enc(APU_EX_CMPLT, 0, 1, 2, 0, 0, 0, 0));
    load(3, apu_exec_enc(APU_EX_LDI, 3, 0, 0, 0, 1, 0, 9'd99));
    load(4, apu_exec_enc(APU_EX_HALT, 0, 0, 0, 0, 0, 0, 0));
    run();
    peek(0, 3, v0); peek(1, 3, v1); peek(2, 3, v2); peek(3, 3, v3);
    check("pred t0", v0 == 32'd99);
    check("pred t1", v1 == 32'd99);
    check("pred t2 skipped", v2 == 32'd0);
    check("pred t3 skipped", v3 == 32'd0);

    clear_imem();
    poke(0, 1, 32'h3f800000); poke(0, 2, 32'h40000000); poke(0, 3, 32'h40400000);
    poke(1, 1, 32'h3f800000); poke(1, 2, 32'h40000000); poke(1, 3, 32'h40400000);
    poke(2, 1, 32'h3f800000); poke(2, 2, 32'h40000000); poke(2, 3, 32'h40400000);
    poke(3, 1, 32'h3f800000); poke(3, 2, 32'h40000000); poke(3, 3, 32'h40400000);
    load(0, apu_exec_enc(APU_EX_FMADD, 4, 1, 2, 3, 0, 0, 0));
    load(1, apu_exec_enc(APU_EX_HALT, 0, 0, 0, 0, 0, 0, 0));
    run();
    peek(0, 4, v0); peek(3, 4, v3);
    check("fmadd t0", v0 == 32'h40a00000);
    check("fmadd t3", v3 == 32'h40a00000);

    clear_imem();
    poke(0, 1, 32'h40000000); poke(0, 2, 32'h3f800000);
    poke(1, 1, 32'h40000000); poke(1, 2, 32'h3f800000);
    poke(2, 1, 32'h40000000); poke(2, 2, 32'h3f800000);
    poke(3, 1, 32'h40000000); poke(3, 2, 32'h3f800000);
    load(0, apu_exec_enc(APU_EX_FSUB, 3, 1, 2, 0, 0, 0, 0));
    load(1, apu_exec_enc(APU_EX_HALT, 0, 0, 0, 0, 0, 0, 0));
    run();
    peek(0, 3, v0); peek(3, 3, v3);
    check("fsub t0", v0 == 32'h3f800000);
    check("fsub t3", v3 == 32'h3f800000);

    clear_imem();
    poke(0, 2, 32'h3f800000); poke(1, 2, 32'h3f800000);
    poke(2, 2, 32'h3f800000); poke(3, 2, 32'h3f800000);
    load(0, apu_exec_enc(APU_EX_FNEG, 1, 2, 0, 0, 0, 0, 0));
    load(1, apu_exec_enc(APU_EX_HALT, 0, 0, 0, 0, 0, 0, 0));
    run();
    peek(0, 1, v0); peek(3, 1, v3);
    check("fneg t0", v0 == 32'hbf800000);
    check("fneg t3", v3 == 32'hbf800000);

    clear_imem();
    poke(0, 1, 32'ha); poke(1, 1, 32'hb); poke(2, 1, 32'hc); poke(3, 1, 32'hd);
    load(0, apu_exec_enc(APU_EX_QUADX, 2, 1, 0, 0, 0, 0, 0));
    load(1, apu_exec_enc(APU_EX_HALT, 0, 0, 0, 0, 0, 0, 0));
    run();
    peek(0, 2, v0); peek(1, 2, v1); peek(2, 2, v2); peek(3, 2, v3);
    check("quadx 0-1", v0 == 32'hb && v1 == 32'ha);
    check("quadx 2-3", v2 == 32'hd && v3 == 32'hc);

    clear_imem();
    shader = 1;
    load(0, apu_exec_enc(APU_EX_IADD, 1, 1, 1, 0, 0, 1, 0));
    load(1, apu_exec_enc(APU_EX_HALT, 0, 0, 0, 0, 0, 0, 0));
    run();
    check("shader rejected micro op", fault);
    shader = 0;

    clear_imem();
    load(0, apu_exec_enc(APU_EX_LDI, 2, 0, 0, 0, 0, 0, 9'd0));
    load(1, apu_exec_enc(APU_EX_BR, 0, 0, 0, 0, 0, 0, 9'd2));
    load(2, apu_exec_enc(APU_EX_LDI, 2, 0, 0, 0, 0, 0, 9'd99));
    load(3, apu_exec_enc(APU_EX_LDI, 3, 0, 0, 0, 0, 0, 9'd5));
    load(4, apu_exec_enc(APU_EX_HALT, 0, 0, 0, 0, 0, 0, 0));
    run();
    peek(0, 2, v0); peek(0, 3, v1);
    check("br skipped delay slot", v0 == 32'd0);
    check("br landed", v1 == 32'd5);
    check("br no fault", !fault);

    clear_imem();
    load(0, apu_exec_enc(APU_EX_LDI, 1, 0, 0, 0, 0, 0, 9'd0));
    load(1, apu_exec_enc(APU_EX_SETMASK, 0, 1, 0, 0, 0, 0, 0));
    load(2, apu_exec_enc(APU_EX_BR, 0, 0, 0, 0, 0, 0, 9'd2));
    load(3, apu_exec_enc(APU_EX_LDI, 2, 0, 0, 0, 0, 0, 9'd7));
    load(4, apu_exec_enc(APU_EX_HALT, 0, 0, 0, 0, 0, 0, 0));
    load(5, apu_exec_enc(APU_EX_LDI, 2, 0, 0, 0, 0, 0, 9'd1));
    load(6, apu_exec_enc(APU_EX_HALT, 0, 0, 0, 0, 0, 0, 0));
    run();
    peek(0, 2, v0);
    check("br not taken", v0 == 32'd7);

    clear_imem();
    load(0, apu_exec_enc(APU_EX_LDI, 1, 0, 0, 0, 0, 0, 9'd0));
    load(1, apu_exec_enc(APU_EX_LDI, 2, 0, 0, 0, 0, 0, 9'd42));
    load(2, apu_exec_enc(APU_EX_ST, 0, 1, 2, 0, 0, 0, 9'd0));
    load(3, apu_exec_enc(APU_EX_LD, 3, 1, 0, 0, 0, 0, 9'd0));
    load(4, apu_exec_enc(APU_EX_HALT, 0, 0, 0, 0, 0, 0, 0));
    run();
    peek(0, 3, v0); peek(3, 3, v3);
    check("micro ld/st t0", v0 == 32'd42);
    check("micro ld/st t3", v3 == 32'd42);
    check("ldst no fault", !fault);
    @(negedge clk); ddmem_idx = 0;
    @(posedge clk);
    check("micro dmem[0] readback", ddmem == 32'd42);

    clear_imem();
    load(0, apu_exec_enc(APU_EX_LDI, 1, 0, 0, 0, 0, 0, 9'd0));
    load(1, apu_exec_enc(APU_EX_LDI, 4, 0, 0, 0, 0, 0, 9'd4));
    load(2, apu_exec_enc(APU_EX_LDC, 2, 0, 0, 0, 0, 0, 0));
    load(3, 32'h3f800000);
    load(4, apu_exec_enc(APU_EX_MOV, 3, 1, 0, 0, 0, 0, 0));
    load(5, apu_exec_enc(APU_EX_IADD, 3, 3, 3, 0, 0, 0, 0));
    load(6, apu_exec_enc(APU_EX_IADD, 3, 3, 3, 0, 0, 0, 0));
    load(7, apu_exec_enc(APU_EX_ST, 0, 3, 2, 0, 0, 0, 9'd0));
    load(8, apu_exec_enc(APU_EX_LDI, 6, 0, 0, 0, 0, 0, 9'd1));
    load(9, apu_exec_enc(APU_EX_IADD, 1, 1, 6, 0, 0, 0, 0));
    load(10, apu_exec_enc(APU_EX_CMPLT, 0, 1, 4, 0, 0, 0, 0));
    load(11, apu_exec_enc(APU_EX_BR, 0, 0, 0, 0, 0, 0, 9'h1F9));
    load(12, apu_exec_enc(APU_EX_HALT, 0, 0, 0, 0, 0, 0, 0));
    run();
    check("scanline no fault", !fault);
    @(negedge clk); ddmem_idx = 0; @(posedge clk);
    check("scanline dmem[0]", ddmem == 32'h3f800000);
    @(negedge clk); ddmem_idx = 3; @(posedge clk);
    check("scanline dmem[3]", ddmem == 32'h3f800000);
    @(negedge clk); ddmem_idx = 4; @(posedge clk);
    check("scanline dmem[4] empty", ddmem == 32'h0);

    clear_imem();
    shader = 1;
    poke(0, 1, 32'd128);
    poke(1, 1, 32'd128);
    poke(2, 1, 32'd128);
    poke(3, 1, 32'd128);
    load(0, apu_exec_enc(APU_EX_ST, 0, 1, 2, 0, 0, 0, 9'd0));
    load(1, apu_exec_enc(APU_EX_HALT, 0, 0, 0, 0, 0, 0, 0));
    run();
    check("shader rejected micro window", fault);
    shader = 0;

    clear_imem();
    load(0, apu_exec_enc(APU_EX_LDC, 4, 0, 0, 0, 0, 0, 0));
    load(1, 32'h3f800000);
    load(2, apu_exec_enc(APU_EX_HALT, 0, 0, 0, 0, 0, 0, 0));
    run();
    peek(0, 4, v0); peek(3, 4, v3);
    check("ldc t0", v0 == 32'h3f800000);
    check("ldc t3", v3 == 32'h3f800000);
    check("ldc no fault", !fault);

    for (int opcode = 0; opcode < 32; opcode++) begin
      clear_imem();
      shader = 1;
      poke(0, 3, 32'h12345678);
      if (opcode == int'(APU_EX_NOP) || opcode == int'(APU_EX_HALT) || opcode == int'(APU_EX_BR)) begin
        load(0, apu_exec_enc(apu_exec_op_e'(opcode), 0, 0, 0, 0, 0, 1, 9'd1));
        run();
        check("fetch-only opcode enforces shader privilege", fault);
      end else if (opcode > int'(APU_EX_LDC)) begin
        load(0, apu_exec_enc(apu_exec_op_e'(opcode), 3, 0, 0, 0, 0, 0, 0));
        run();
        check("unknown opcode faults", fault);
        peek(0, 3, v0);
        check("unknown opcode cannot write registers", v0 == 32'h12345678);
      end
    end
    clear_imem();
    load(0, apu_exec_enc(APU_EX_MOV, 3, 8, 0, 0, 0, 0, 0));
    run();
    check("out-of-range source register faults rather than aliases", fault);
    clear_imem();
    load(0, apu_exec_enc(APU_EX_LDI, 11, 0, 0, 0, 0, 0, 9'd1));
    run();
    check("out-of-range destination register faults rather than aliases", fault);
    peek(0, 3, v0);
    check("invalid encodings preserve RF", v0 == 32'h12345678);
    shader = 0;
    clear_imem();
    load(0, apu_exec_enc(APU_EX_LDI, 3, 0, 0, 0, 0, 0, 9'd7));
    run();
    peek(0, 3, v0);
    check("valid run recovers after decode fault", !fault && v0 == 7);

    if (errors != 0) $fatal(1, "APU exec errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_exec cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
