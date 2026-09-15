// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Firmware RAM window: load apu_fw.hex at 0x90000000, cookie at 0x9003FF00,
// CVA6 I$ 2-beat INCR fill. Not a CVA6 testharness boot.

`timescale 1ns/1ps

package g6lc_fwram_test_pkg;
  import g6lc_apu_cfg_pkg::*;
  function automatic apu_cfg_t ram_cfg(input bit enabled, input int unsigned bytes);
    apu_cfg_t cfg = ApuHarness;
    cfg.Enable = enabled;
    if (!enabled) cfg.FirmwareHart = APU_FW_HART_UNASSIGNED;
    if (bytes != 0) cfg.FirmwareRamBytes = 64'(bytes);
    return cfg;
  endfunction
endpackage

module g6lc_apu_fwram_fixture
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_bus_pkg::*;
#(parameter bit Enable = 1'b1, parameter int unsigned RamBytes = 0) (
  input  logic clk_i, rst_ni, testmode_i,
  input  apu_dma_axi_req_t slv_req_i,
  output apu_dma_axi_resp_t slv_rsp_o,
  output axi_pkg::xbar_rule_64_t ram_rule_o,
  output logic [63:0] ram_base_o, ram_end_o
);
  g6lc_apu_fwram #(
    .ApuCfg(g6lc_fwram_test_pkg::ram_cfg(Enable, RamBytes)),
    .RamIdx(12)
  ) i_dut (.*);
endmodule

module tb_g6lc_apu_fwram;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_bus_pkg::*;
  import g6lc_fwram_test_pkg::*;
  import axi_pkg::*;
  logic clk = 0, rst_ni = 0;
  apu_dma_axi_req_t [1:0] req;
  apu_dma_axi_resp_t [1:0] rsp;
  axi_pkg::xbar_rule_64_t ram_rule, off_rule;
  logic [63:0] ram_base, ram_end;
  logic [31:0] image [256];
  int errors = 0, checks = 0, cycles = 0, cases = 0, nwords = 0;

  g6lc_apu_fwram_fixture i_on (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1),
    .slv_req_i(req[0]), .slv_rsp_o(rsp[0]),
    .ram_rule_o(ram_rule), .ram_base_o(ram_base), .ram_end_o(ram_end)
  );
  g6lc_apu_fwram_fixture #(.Enable(0)) i_off (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1),
    .slv_req_i(req[1]), .slv_rsp_o(rsp[1]),
    .ram_rule_o(off_rule), .ram_base_o(), .ram_end_o()
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "fwram timeout case=%0d", cases); end

  initial begin
    string hexfile;
    hexfile = "apu_fw.hex";
    void'($value$plusargs("HEX=%s", hexfile));
    $readmemh(hexfile, image);
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask
  task automatic pack32(input logic [63:0] a, input logic [31:0] d,
      output logic [63:0] data, output logic [7:0] strb);
    if (a[2]) begin data = {d, 32'h0}; strb = 8'hf0; end
    else begin data = {32'h0, d}; strb = 8'h0f; end
  endtask
  task automatic unpack32(input logic [63:0] a, input logic [63:0] data,
      output logic [31:0] d);
    d = a[2] ? data[63:32] : data[31:0];
  endtask
  task automatic send_write(input int p, input logic [63:0] a, input logic [31:0] d,
      input logic [2:0] size = 3'd2);
    logic [63:0] wdata;
    logic [7:0] strb;
    bit aw_done, w_done;
    pack32(a, d, wdata, strb);
    aw_done = 0; w_done = 0;
    @(negedge clk);
    req[p].aw.addr = a; req[p].aw.size = size; req[p].aw.len = '0;
    req[p].aw.burst = BURST_INCR; req[p].aw.id = '0;
    req[p].w.data = wdata; req[p].w.strb = strb; req[p].w.last = 1'b1;
    req[p].aw_valid = 1; req[p].w_valid = 1;
    while (!aw_done || !w_done) begin
      @(posedge clk);
      if (req[p].aw_valid && rsp[p].aw_ready) aw_done = 1;
      if (req[p].w_valid && rsp[p].w_ready) w_done = 1;
      @(negedge clk);
      if (aw_done) req[p].aw_valid = 0;
      if (w_done) req[p].w_valid = 0;
    end
  endtask
  task automatic receive_write(input int p, input logic [1:0] expected = 0);
    @(posedge clk);
    while (!rsp[p].b_valid) @(posedge clk);
    check("AXI B", rsp[p].b.resp == expected);
    @(negedge clk); req[p].b_ready = 1;
    @(posedge clk); @(negedge clk); req[p].b_ready = 0;
  endtask
  task automatic write_reg(input int p, input logic [63:0] a, input logic [31:0] d,
      input logic [1:0] expected = 0, input logic [2:0] size = 3'd2);
    send_write(p, a, d, size);
    receive_write(p, expected);
  endtask
  task automatic send_read(input int p, input logic [63:0] a,
      input logic [2:0] size = 3'd2, input logic [7:0] len = 8'd0,
      input logic [1:0] burst = BURST_INCR);
    @(negedge clk);
    req[p].ar.addr = a; req[p].ar.size = size; req[p].ar.len = len;
    req[p].ar.burst = burst; req[p].ar.id = '0;
    req[p].ar_valid = 1;
    @(posedge clk);
    while (!rsp[p].ar_ready) @(posedge clk);
    @(negedge clk); req[p].ar_valid = 0;
  endtask
  task automatic receive_beat(input int p, input logic [63:0] a,
      output logic [63:0] data, input logic [1:0] expected = 0,
      input bit last_exp = 1);
    @(posedge clk);
    while (!rsp[p].r_valid) @(posedge clk);
    data = rsp[p].r.data;
    check("AXI R", rsp[p].r.resp == expected && rsp[p].r.last == last_exp);
    @(negedge clk); req[p].r_ready = 1;
    @(posedge clk); @(negedge clk); req[p].r_ready = 0;
  endtask
  task automatic drain_read(input int p, input logic [1:0] expected = 0);
    logic [63:0] beat;
    bit seen_last;
    seen_last = 0;
    while (!seen_last) begin
      @(posedge clk);
      while (!rsp[p].r_valid) @(posedge clk);
      beat = rsp[p].r.data;
      check("AXI R resp", rsp[p].r.resp == expected);
      seen_last = rsp[p].r.last;
      @(negedge clk); req[p].r_ready = 1;
      @(posedge clk); @(negedge clk); req[p].r_ready = 0;
    end
  endtask
  task automatic receive_read(input int p, input logic [63:0] a,
      output logic [31:0] data, input logic [1:0] expected = 0);
    logic [63:0] beat;
    receive_beat(p, a, beat, expected, 1);
    unpack32(a, beat, data);
  endtask
  task automatic read_reg(input int p, input logic [63:0] a, output logic [31:0] data,
      input logic [1:0] expected = 0, input logic [2:0] size = 3'd2);
    send_read(p, a, size);
    receive_read(p, a, data, expected);
  endtask

  initial begin
    logic [31:0] r, r2;
    logic [63:0] beat;
    integer i;
    req[0] = '0; req[1] = '0;
    repeat (4) @(negedge clk);
    rst_ni = 1;

    cases = 1;
    check("ram idx 12", ram_rule.idx == 12);
    check("ram window", ram_rule.start_addr == 64'h9000_0000 &&
          ram_rule.end_addr == 64'h9004_0000);
    check("ram misses GPIO/AI",
          !apu_ranges_overlap(ram_base, ram_end - ram_base, 64'h4000_0000, 64'h1000));
    check("ram misses control",
          !apu_ranges_overlap(ram_base, ram_end - ram_base,
                              APU_CONTROL_BASE, APU_CONTROL_LEN));
    check("disabled publishes the same rule",
          off_rule.idx == ram_rule.idx &&
          off_rule.start_addr == ram_rule.start_addr);

    cases = 2;
    nwords = 0;
    for (i = 0; i < 256; i++) if (image[i] !== 32'hx) nwords = i + 1;
    check("image not empty", nwords >= 4);
    for (i = 0; i < nwords; i++)
      write_reg(0, 64'h9000_0000 + 64'(i * 4), image[i]);
    read_reg(0, 64'h9000_0000, r);
    check("reset auipc", r == 32'h0003_f117);
    read_reg(0, 64'h9000_000c, r);
    check("crt0 spin", r == 32'h0000_006f);
    write_reg(0, 64'h9003_FF00, 32'h600D_000A);
    read_reg(0, 64'h9003_FF00, r);
    check("cookie slot", r == 32'h600D_000A);

    cases = 3;
    write_reg(0, 64'h9000_0010, 32'hAABB_CCDD);
    send_read(0, 64'h9000_0010, 3'd3);
    @(posedge clk);
    while (!rsp[0].r_valid) @(posedge clk);
    r = rsp[0].r.data[31:0];
    r2 = rsp[0].r.data[63:32];
    check("size-3 OK", rsp[0].r.resp == 0 && rsp[0].r.last);
    @(negedge clk); req[0].r_ready = 1;
    @(posedge clk); @(negedge clk); req[0].r_ready = 0;
    check("size-3 low lane", r == 32'hAABB_CCDD);
    check("size-3 high lane keeps neighbor", r2 == image[5]);
    write_reg(0, 64'h4000_0000, 32'h1, 2);
    check("GPIO alias SLVERR write", 1'b1);
    read_reg(0, 64'h4000_0000, r, 2);
    check("GPIO alias SLVERR read", 1'b1);
    read_reg(1, 64'h9000_0000, r, 2);
    check("disabled SLVERR", 1'b1);

    cases = 4;
    send_read(0, 64'h9000_0000, 3'd3, 8'd1);
    receive_beat(0, 64'h9000_0000, beat, 0, 0);
    check("I$ fill beat0 auipc", beat[31:0] == 32'h0003_f117);
    receive_beat(0, 64'h9000_0008, beat, 0, 1);
    check("I$ fill beat1 spin", beat[63:32] == 32'h0000_006f);

    cases = 5;
    send_read(0, 64'h9000_0000, 3'd3, 8'd1, BURST_WRAP);
    drain_read(0, 2);
    check("WRAP SLVERR", 1'b1);
    send_read(0, 64'h9000_0000, 3'd3, 8'd16);
    drain_read(0, 2);
    check("len-16 SLVERR", 1'b1);
    send_read(0, 64'h9003_FFF8, 3'd3, 8'd1);
    drain_read(0, 2);
    check("window-cross SLVERR", 1'b1);

    cases = 6;
    send_read(0, 64'h9000_0000, 3'd0);
    receive_beat(0, 64'h9000_0000, beat);
    check("size-0 auipc byte0", beat[7:0] == 8'h17);
    send_read(0, 64'h9000_0001, 3'd0);
    receive_beat(0, 64'h9000_0001, beat);
    check("size-0 auipc byte1", beat[15:8] == 8'hf1);
    read_reg(0, 64'hFFFFFFFF9000_0000, r);
    check("sign-ext PA auipc", r == 32'h0003_f117);
    write_reg(0, 64'hFFFFFFFF9003_EFA0, 32'h4741_5246);
    read_reg(0, 64'hFFFFFFFF9003_EFA0, r);
    check("sign-ext stack FRAG", r == 32'h4741_5246);
    send_read(0, 64'hFFFFFFFF9003_EFA0, 3'd0);
    receive_beat(0, 64'hFFFFFFFF9003_EFA0, beat);
    check("sign-ext stack lbu", beat[7:0] == 8'h46);

    if (errors != 0) $fatal(1, "APU fwram errors=%0d", errors);
    $display("PASS tb_g6lc_apu_fwram cases=%0d checks=%0d cycles=%0d errors=0 nwords=%0d",
             cases, checks, cycles, nwords);
    $finish;
  end
endmodule
