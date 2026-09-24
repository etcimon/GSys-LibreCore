// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Enabled APU configs must name the execution file the cluster builds:
// 4 threads, 8 registers, 16 instruction words, 64 data words.

`timescale 1ns/1ps

package g6lc_exec_geom_pkg;
  import g6lc_apu_cfg_pkg::*;
  function automatic apu_cfg_t geom_cfg(input bit enabled);
    apu_cfg_t cfg = ApuP1Transport;
    cfg.Enable = enabled;
    cfg.ExecEn = enabled;
    cfg.ExecQuadThreads = APU_EXEC_THREADS;
    cfg.ExecRegs = APU_EXEC_REGS;
    cfg.ExecMemWords = APU_EXEC_DMEM_WORDS;
    return cfg;
  endfunction
endpackage

module g6lc_apu_exec_geom_fixture
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
  g6lc_apu_exec #(.ApuCfg(g6lc_exec_geom_pkg::geom_cfg(Enable))) i_dut (.*);
endmodule

module tb_g6lc_apu_exec_geom;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  import g6lc_exec_geom_pkg::*;
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
  logic [31:0] off_data, off_dmem;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  apu_exec_job_t geom_job;
  localparam int unsigned REGS_BAD[4] = '{0, 4, 16, 32};
  localparam int unsigned MEM_BAD[5] = '{0, 16, 32, 128, 256};
  localparam int unsigned THR_BAD[3] = '{0, 2, 8};

  g6lc_apu_exec_geom_fixture i_on (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1), .enable_i(enable), .cancel_i(cancel),
    .start_i(start), .shader_i(shader),
    .imem_we_i(imem_we), .imem_idx_i(imem_idx), .imem_wdata_i(imem_wdata),
    .idle_o(idle), .busy_o(busy), .fault_o(fault),
    .dbg_thread_i(dth), .dbg_reg_i(dreg), .dbg_data_o(ddata),
    .dbg_dmem_idx_i(ddmem_idx), .dbg_dmem_o(ddmem),
    .dbg_we_i(dwe), .dbg_wdata_i(dwdata)
  );
  g6lc_apu_exec_geom_fixture #(.Enable(0)) i_off (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1), .enable_i(enable), .cancel_i(cancel),
    .start_i(start), .shader_i(shader),
    .imem_we_i(imem_we), .imem_idx_i(imem_idx), .imem_wdata_i(imem_wdata),
    .idle_o(off_idle), .busy_o(off_busy), .fault_o(off_fault),
    .dbg_thread_i(dth), .dbg_reg_i(dreg), .dbg_data_o(off_data),
    .dbg_dmem_idx_i(ddmem_idx), .dbg_dmem_o(off_dmem),
    .dbg_we_i(dwe), .dbg_wdata_i(dwdata)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "exec geom timeout case=%0d", cases); end
  always @(negedge clk) begin
    #1;
    if ({off_busy, off_fault, off_data, off_dmem} !== '0 || off_idle !== 1'b1)
      $fatal(1, "disabled exec active");
  end

  task automatic check(input string name, input bit cond);
    checks++;
    if (!cond) begin
      errors++;
      $display("FAIL %s", name);
    end
  endtask

  task automatic sweep_bad(input bit exec_on);
    apu_cfg_t cfg;
    int i;
    for (i = 0; i < 4; i++) begin
      cfg = geom_cfg(1);
      cfg.ExecEn = exec_on;
      cfg.ExecRegs = REGS_BAD[i];
      check($sformatf("regs %0d with exec %0d", REGS_BAD[i], exec_on),
            !apu_cfg_legal(cfg));
    end
    for (i = 0; i < 5; i++) begin
      cfg = geom_cfg(1);
      cfg.ExecEn = exec_on;
      cfg.ExecMemWords = MEM_BAD[i];
      check($sformatf("dmem %0d with exec %0d", MEM_BAD[i], exec_on),
            !apu_cfg_legal(cfg));
    end
    for (i = 0; i < 3; i++) begin
      cfg = geom_cfg(1);
      cfg.ExecEn = exec_on;
      cfg.ExecQuadThreads = THR_BAD[i];
      check($sformatf("threads %0d with exec %0d", THR_BAD[i], exec_on),
            !apu_cfg_legal(cfg));
    end
  endtask

  initial begin
    apu_cfg_t cfg;
    enable = 0; cancel = 0; start = 0; shader = 0; imem_we = 0; dwe = 0;
    imem_idx = '0; imem_wdata = '0; dth = '0; dreg = '0; dwdata = '0; ddmem_idx = '0;

    cases = 1;
    check("IMEM depth is 16", APU_EXEC_IMEM == 16 && APU_EXEC_IMEM_WORDS == 16);
    check("IMEM alias matches the config constant", APU_EXEC_IMEM == APU_EXEC_IMEM_WORDS);
    check("IMEM index is 4 bits", $bits(geom_job.idx) == $clog2(APU_EXEC_IMEM_WORDS));
    check("register index is 3 bits", $bits(geom_job.regno) == $clog2(APU_EXEC_REGS));
    check("thread index is 2 bits", $bits(geom_job.thread) == $clog2(APU_EXEC_THREADS));
    check("DMEM index is 6 bits", $clog2(APU_EXEC_DMEM_WORDS) == 6);

    cases = 2;
    cfg = ApuOff;
    cfg.ExecRegs = 32;
    cfg.ExecMemWords = 256;
    cfg.ExecQuadThreads = 8;
    check("disabled device stays legal", apu_cfg_legal(cfg));
    check("harness geometry is legal", apu_cfg_legal(ApuHarness));
    check("transport geometry is legal", apu_cfg_legal(ApuP1Transport));
    check("virgl grant stays illegal", !apu_cfg_legal(ApuBadVirglGrant));

    cases = 3;
    sweep_bad(0);
    check("exec off with the real file is legal", apu_cfg_legal(geom_cfg(0)));

    cases = 4;
    sweep_bad(1);
    check("exec on with the real file is legal", apu_cfg_legal(geom_cfg(1)));
    cfg = geom_cfg(1);
    cfg.MaxResources = 8;
    check("memory plus exec stays illegal", !apu_cfg_legal(cfg));

    cases = 5;
    repeat (2) @(negedge clk);
    rst_ni = 1;
    enable = 1;
    @(negedge clk);
    check("enabled cluster is idle", idle === 1'b1 && busy === 1'b0 && fault === 1'b0);
    dth = 2'd0;
    dreg = 3'd7;
    dwdata = 32'h0000_0007;
    dwe = 1'b1;
    @(negedge clk);
    dwe = 1'b0;
    @(negedge clk);
    check("register 7 holds the poke", ddata === 32'h0000_0007);
    dreg = 3'd0;
    dwdata = 32'hffff_ffff;
    dwe = 1'b1;
    @(negedge clk);
    dwe = 1'b0;
    @(negedge clk);
    check("register 0 stays zero", ddata === 32'h0);
    ddmem_idx = 6'd0;
    @(negedge clk);
    check("DMEM word 0 is clear", ddmem === 32'h0);
    ddmem_idx = 6'd63;
    @(negedge clk);
    check("DMEM word 63 is clear", ddmem === 32'h0);
    check("disabled outputs stay quiet", off_idle === 1'b1 && off_data === 32'h0 &&
          off_dmem === 32'h0);

    if (errors != 0) $fatal(1, "APU exec geom errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_exec_geom cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
