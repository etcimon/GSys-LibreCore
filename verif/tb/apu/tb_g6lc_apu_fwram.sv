// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Firmware RAM window: load apu_fw.hex at 0x90000000, cookie at 0x9003FF00,
// CVA6 I$ 2-beat INCR fill. A reserved hart is captured at AW/AR. AXI id
// and PROT are not authority. Not a CVA6 testharness boot.

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
  input  logic [31:0] aw_hart_i, ar_hart_i,
  input  apu_dma_axi_req_t slv_req_i,
  output apu_dma_axi_resp_t slv_rsp_o,
  output axi_pkg::xbar_rule_64_t ram_rule_o,
  output logic [63:0] ram_base_o, ram_end_o,
  output logic fault_o
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
  logic [31:0] aw_hart, ar_hart;
  apu_dma_axi_req_t [1:0] req;
  apu_dma_axi_resp_t [1:0] rsp;
  axi_pkg::xbar_rule_64_t ram_rule, off_rule;
  logic [63:0] ram_base, ram_end;
  logic fault, off_fault;
  logic [31:0] image [256];
  int errors = 0, checks = 0, cycles = 0, cases = 0, nwords = 0;

  g6lc_apu_fwram_fixture i_on (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1),
    .aw_hart_i(aw_hart), .ar_hart_i(ar_hart),
    .slv_req_i(req[0]), .slv_rsp_o(rsp[0]),
    .ram_rule_o(ram_rule), .ram_base_o(ram_base), .ram_end_o(ram_end),
    .fault_o(fault)
  );
  g6lc_apu_fwram_fixture #(.Enable(0)) i_off (
    .clk_i(clk), .rst_ni, .testmode_i(1'b1),
    .aw_hart_i(aw_hart), .ar_hart_i(ar_hart),
    .slv_req_i(req[1]), .slv_rsp_o(rsp[1]),
    .ram_rule_o(off_rule), .ram_base_o(), .ram_end_o(),
    .fault_o(off_fault)
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
    req[p].aw.lock = 1'b0; req[p].aw.atop = '0;
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
    req[p].ar.burst = burst; req[p].ar.id = '0; req[p].ar.lock = 1'b0;
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
    int beats;
    seen_last = 0;
    beats = 0;
    while (!seen_last) begin
      @(posedge clk);
      while (!rsp[p].r_valid) @(posedge clk);
      beat = rsp[p].r.data;
      check("AXI R resp", rsp[p].r.resp == expected);
      seen_last = rsp[p].r.last;
      beats++;
      @(negedge clk); req[p].r_ready = 1;
      @(posedge clk); @(negedge clk); req[p].r_ready = 0;
    end
    check("read response count matches accepted ARLEN", beats == int'(req[p].ar.len) + 1);
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

  // AW is accepted before W. The hart pin may change in between. The id is
  // the AXI id, checked on B, and is not a hart.
  task automatic aw_then_w(
      input logic [31:0] hart_aw, input logic [31:0] hart_w,
      input logic [63:0] a, input logic [31:0] d,
      input logic [3:0] id, input logic [2:0] prot,
      input logic [1:0] expected);
    logic [63:0] wdata;
    logic [7:0] strb;
    pack32(a, d, wdata, strb);
    @(negedge clk);
    aw_hart = hart_aw;
    req[0].aw.addr = a; req[0].aw.size = 3'd2; req[0].aw.len = '0;
    req[0].aw.burst = BURST_INCR; req[0].aw.id = id; req[0].aw.prot = prot;
    req[0].aw_valid = 1'b1; req[0].w_valid = 1'b0;
    @(posedge clk);
    while (!rsp[0].aw_ready) @(posedge clk);
    @(negedge clk);
    req[0].aw_valid = 1'b0;
    aw_hart = hart_w;
    req[0].w.data = wdata; req[0].w.strb = strb; req[0].w.last = 1'b1;
    req[0].w_valid = 1'b1;
    @(posedge clk);
    while (!rsp[0].w_ready) @(posedge clk);
    @(negedge clk);
    req[0].w_valid = 1'b0;
    @(posedge clk);
    while (!rsp[0].b_valid) @(posedge clk);
    check("AXI B id", rsp[0].b.id == id && rsp[0].b.resp == expected);
    @(negedge clk); req[0].b_ready = 1;
    @(posedge clk); @(negedge clk); req[0].b_ready = 0;
  endtask

  task automatic write_id(
      input logic [31:0] hart, input logic [63:0] a, input logic [31:0] d,
      input logic [3:0] id, input logic [2:0] prot,
      input logic [1:0] expected);
    logic [63:0] wdata;
    logic [7:0] strb;
    bit aw_done, w_done;
    pack32(a, d, wdata, strb);
    aw_done = 0; w_done = 0;
    @(negedge clk);
    aw_hart = hart;
    req[0].aw.addr = a; req[0].aw.size = 3'd2; req[0].aw.len = '0;
    req[0].aw.burst = BURST_INCR; req[0].aw.id = id; req[0].aw.prot = prot;
    req[0].w.data = wdata; req[0].w.strb = strb; req[0].w.last = 1'b1;
    req[0].aw_valid = 1; req[0].w_valid = 1;
    while (!aw_done || !w_done) begin
      @(posedge clk);
      if (req[0].aw_valid && rsp[0].aw_ready) aw_done = 1;
      if (req[0].w_valid && rsp[0].w_ready) w_done = 1;
      @(negedge clk);
      if (aw_done) req[0].aw_valid = 0;
      if (w_done) req[0].w_valid = 0;
    end
    @(posedge clk);
    while (!rsp[0].b_valid) @(posedge clk);
    check("AXI B id", rsp[0].b.id == id && rsp[0].b.resp == expected);
    @(negedge clk); req[0].b_ready = 1;
    @(posedge clk); @(negedge clk); req[0].b_ready = 0;
  endtask

  // AR is accepted, then the hart pin may change, before R.
  task automatic capture_read(
      input logic [31:0] hart_ar, input logic [31:0] hart_after,
      input logic [63:0] a, input logic [3:0] id, input logic [2:0] prot,
      input logic [1:0] expected, output logic [31:0] data);
    logic [63:0] beat;
    @(negedge clk);
    ar_hart = hart_ar;
    req[0].ar.addr = a; req[0].ar.size = 3'd2; req[0].ar.len = '0;
    req[0].ar.burst = BURST_INCR; req[0].ar.id = id; req[0].ar.prot = prot;
    req[0].ar_valid = 1'b1;
    @(posedge clk);
    while (!rsp[0].ar_ready) @(posedge clk);
    @(negedge clk);
    req[0].ar_valid = 1'b0;
    ar_hart = hart_after;
    @(posedge clk);
    while (!rsp[0].r_valid) @(posedge clk);
    beat = rsp[0].r.data;
    check("AXI R id", rsp[0].r.id == id && rsp[0].r.resp == expected &&
          rsp[0].r.last);
    unpack32(a, beat, data);
    @(negedge clk); req[0].r_ready = 1;
    @(posedge clk); @(negedge clk); req[0].r_ready = 0;
  endtask

  // One plain or rejected store. want_r waits for the atomic read result.
  task automatic store_once(
      input int p, input logic [63:0] a, input logic [31:0] d,
      input logic [2:0] size, input logic [7:0] strb,
      input logic lock, input logic [5:0] atop, input bit want_r,
      input logic [1:0] expected);
    logic [63:0] wdata;
    bit aw_done, w_done;
    wdata = {32'h0, d};
    aw_done = 0; w_done = 0;
    @(negedge clk);
    req[p].aw.addr = a; req[p].aw.size = size; req[p].aw.len = '0;
    req[p].aw.burst = BURST_INCR; req[p].aw.id = 4'h3;
    req[p].aw.lock = lock; req[p].aw.atop = atop;
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
    @(posedge clk);
    while (!rsp[p].b_valid) @(posedge clk);
    check("store B", rsp[p].b.id == 4'h3 && rsp[p].b.resp == expected &&
          rsp[p].b.resp != RESP_EXOKAY);
    @(negedge clk); req[p].b_ready = 1;
    @(posedge clk); @(negedge clk); req[p].b_ready = 0;
    if (want_r) begin
      @(posedge clk);
      while (!rsp[p].r_valid) @(posedge clk);
      check("atomic R", rsp[p].r.id == 4'h3 && rsp[p].r.resp == expected &&
            rsp[p].r.resp != RESP_EXOKAY && rsp[p].r.last);
      @(negedge clk); req[p].r_ready = 1;
      @(posedge clk); @(negedge clk); req[p].r_ready = 0;
    end else begin
      repeat (3) begin
        @(posedge clk);
        check("store has no R", !rsp[p].r_valid);
      end
    end
  endtask

  task automatic exercise_write(input int p, input logic [63:0] addr,
      input logic [7:0] len, input logic [2:0] size, input logic [7:0] strb,
      input int skew, input int bad_last, input logic [1:0] expected);
    int accepted, b_stalls, fault_cycle;
    bit aw_done, w_pending, done;
    apu_dma_axi_resp_t held;
    accepted = 0; b_stalls = 0; fault_cycle = -1;
    aw_done = 0; w_pending = 0; done = 0; held = '0;
    cases++;
    for (int tick = 0; tick < 2048; tick++) begin
      @(negedge clk);
      req[p].aw.addr = addr; req[p].aw.len = len; req[p].aw.size = size;
      req[p].aw.burst = BURST_INCR; req[p].aw.id = 5;
      req[p].aw.lock = 1'b0; req[p].aw.atop = '0;
      req[p].aw_valid = !aw_done && tick >= (skew < 0 ? -skew : 0);
      if (aw_done) begin
        req[p].aw.addr = ~addr; req[p].aw.len = ~len;
        req[p].aw.size = 0; req[p].aw.id = 0;
      end
      if (!w_pending && accepted <= int'(len) && fault_cycle < 0 &&
          tick >= (skew > 0 ? skew : 0) && tick % 3 != 2) begin
        w_pending = 1;
        req[p].w.data = 64'h11223344_55667788; req[p].w.strb = strb;
        req[p].w.last = bad_last == 1 ? accepted == 0 :
                       bad_last == 2 ? 1'b0 : accepted == int'(len);
      end
      req[p].w_valid = w_pending;
      req[p].b_ready = b_stalls >= 4;
      if (fault_cycle >= 0) begin
        req[p].aw_valid = 1; req[p].ar_valid = 1; req[p].w_valid = 1;
      end
      @(posedge clk);
      if (p == 0 && (expected != RESP_OKAY || bad_last != 0))
        check("rejected write has no SRAM effect", !i_on.i_dut.gen_on.ram_we);
      if (fault_cycle >= 0) begin
        check("malformed WLAST quarantines all channels",
              !rsp[p].aw_ready && !rsp[p].ar_ready && !rsp[p].w_ready &&
              !rsp[p].b_valid && !rsp[p].r_valid);
        if (tick - fault_cycle >= 4) begin done = 1; break; end
      end else begin
        if (aw_done) check("pending write blocks new addresses", !rsp[p].aw_ready && !rsp[p].ar_ready);
        if (rsp[p].b_valid) begin
          check("B follows complete accepted write", aw_done && accepted == int'(len) + 1);
          check("B preserves ID and response", rsp[p].b.id == 5 && rsp[p].b.resp == expected);
          if (b_stalls != 0) check("stalled B payload stable", rsp[p].b == held.b);
          held = rsp[p];
          check("B blocks new addresses", !rsp[p].aw_ready && !rsp[p].ar_ready);
          b_stalls++;
          if (req[p].b_ready) begin done = 1; break; end
        end
        if (req[p].aw_valid && rsp[p].aw_ready) aw_done = 1;
        if (req[p].w_valid && rsp[p].w_ready) begin
          if (req[p].w.last != (accepted == int'(len))) fault_cycle = tick;
          accepted++; w_pending = 0;
        end
      end
    end
    check("write completes or quarantines within bound", done);
    if (bad_last == 0) check("all accepted write beats drained", accepted == int'(len) + 1);
    else check("bad WLAST observed", fault_cycle >= 0);
    @(negedge clk); req[p] = '0;
    if (!done || bad_last != 0 || accepted != int'(len) + 1) begin
      rst_ni = 0;
      repeat (3) @(negedge clk);
      rst_ni = 1;
      @(posedge clk);
      check("fabric reset recovers admission", rsp[p].aw_ready && rsp[p].ar_ready);
    end
  endtask

  initial begin
    logic [31:0] r, r2;
    logic [63:0] beat;
    integer i;
    req[0] = '0; req[1] = '0;
    aw_hart = 32'd1; ar_hart = 32'd1;
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
    read_reg(0, 64'hFFFF_FFFF_9000_0000, r, 2);
    check("sign-ext PA is outside the window", 1'b1);
    write_reg(0, 64'hFFFF_FFFF_9000_0000, 32'h1111_1111, 2);
    read_reg(0, 64'h9000_0000, r);
    check("sign-ext write does not alias", r == 32'h0003_f117);
    read_reg(0, 64'h1_9000_0000, r, 2);
    check("upper PA bit is outside the window", 1'b1);
    write_reg(0, 64'h1_9000_0000, 32'h2222_2222, 2);
    read_reg(0, 64'h9000_0000, r);
    check("upper-bit write does not alias", r == 32'h0003_f117);
    send_read(0, 64'hFFFF_FFFF_9000_0000, 3'd3, 8'd1);
    drain_read(0, 2);
    check("sign-ext fill is rejected", 1'b1);
    send_read(0, 64'hFFFF_FFFF_FFFF_FFF8, 3'd3, 8'd1);
    drain_read(0, 2);
    check("wrapping span is rejected", 1'b1);

    cases++;
    for (int p = 0; p < 2; p++) begin
      send_read(p, 64'h9000_0000, 3'd3, 8'd255);
      drain_read(p, RESP_SLVERR);
    end
    cases++;
    for (int offset = 1; offset < 8; offset++) begin
      send_read(0, 64'h9000_0000 + 64'(offset), 3'd3);
      receive_beat(0, 64'h9000_0000 + 64'(offset), beat, RESP_SLVERR);
    end

    write_reg(0, 64'h9000_1000, 32'haabbccdd);
    write_reg(0, 64'h9000_1004, 32'heeff0011);
    for (int p = 0; p < 2; p++) begin
      for (int skew = -4; skew <= 4; skew += 4) begin
        exercise_write(p, 64'h4000_0000, 0, 2, 8'h0f, skew, 0, RESP_SLVERR);
        exercise_write(p, 64'h9000_1000, 1, 3, 8'hff, skew, 0, RESP_SLVERR);
        exercise_write(p, 64'h9000_1000, 15, 3, 8'hff, skew, 0, RESP_SLVERR);
        exercise_write(p, 64'h9000_1000, 255, 3, 8'hff, skew, 0, RESP_SLVERR);
      end
      exercise_write(p, 64'h9000_1000, 3, 3, 8'hff, 0, 1, RESP_SLVERR);
      exercise_write(p, 64'h9000_1000, 0, 3, 8'hff, 4, 2, RESP_SLVERR);
    end
    for (int p = 0; p < 2; p++) begin
      cases++;
      @(negedge clk);
      req[p].aw.addr = 64'h9000_1000; req[p].aw.len = 15;
      req[p].aw.size = 3; req[p].aw.burst = BURST_INCR;
      req[p].aw_valid = 1; req[p].w_valid = 1;
      req[p].w.last = 0; req[p].w.strb = 8'hff;
      @(posedge clk);
      check("rejected burst accepts first AW and W", rsp[p].aw_ready && rsp[p].w_ready);
      @(negedge clk); req[p].aw_valid = 0; req[p].w_valid = 0;
      repeat (6) begin
        @(posedge clk);
        check("missing burst data prevents completion", !rsp[p].b_valid && rsp[p].w_ready &&
              !rsp[p].aw_ready && !rsp[p].ar_ready);
      end
      @(negedge clk); rst_ni = 0; req[p] = '0;
      repeat (3) @(negedge clk);
      rst_ni = 1;
      @(posedge clk);
      check("fabric reset drops incomplete burst without stale B", !rsp[p].b_valid && rsp[p].aw_ready);
    end
    exercise_write(1, 64'h9000_1000, 0, 3, 8'hff, 0, 0, RESP_SLVERR);
    for (int skew = 0; skew <= 4; skew += 4) begin
      exercise_write(0, 64'h9000_1000, 0, 2, 8'hf0, skew, 0, RESP_SLVERR);
      exercise_write(0, 64'h9000_1004, 0, 2, 8'h0f, skew, 0, RESP_SLVERR);
      exercise_write(0, 64'h9000_1000, 0, 2, 8'hff, skew, 0, RESP_SLVERR);
    end
    read_reg(0, 64'h9000_1000, r);
    read_reg(0, 64'h9000_1004, r2);
    check("rejected writes preserve both guard words", r == 32'haabbccdd && r2 == 32'heeff0011);
    exercise_write(0, 64'h9000_1000, 0, 2, 8'h05, 4, 0, RESP_OKAY);
    read_reg(0, 64'h9000_1000, r);
    check("sparse low strobes preserve guard bytes", r == 32'haa66cc88);
    exercise_write(0, 64'h9000_1004, 0, 2, 8'ha0, -4, 0, RESP_OKAY);
    read_reg(0, 64'h9000_1004, r);
    check("sparse high strobes preserve guard bytes", r == 32'h11ff3311);
    exercise_write(0, 64'h9000_1000, 0, 3, 0, 0, 0, RESP_OKAY);
    read_reg(0, 64'h9000_1000, r);
    read_reg(0, 64'h9000_1004, r2);
    check("zero strobes preserve both words", r == 32'haa66cc88 && r2 == 32'h11ff3311);
    exercise_write(0, 64'h9000_1000, 0, 3, 8'hff, 0, 0, RESP_OKAY);
    send_read(0, 64'h9000_1000, 3'd3);
    receive_beat(0, 64'h9000_1000, beat);
    check("full-width write recovers after rejected bursts", beat == 64'h11223344_55667788);

    cases++;
    read_reg(0, 64'h9000_0000, r);
    check("firmware hart reads the canonical word", r == 32'h0003_f117);
    write_id(32'd0, 64'h9000_0000, 32'h1111_1111, 4'h0, 3'b000, RESP_SLVERR);
    aw_hart = 32'd1; ar_hart = 32'd1;
    read_reg(0, 64'h9000_0000, r);
    check("other hart write leaves the canonical word", r == 32'h0003_f117);
    capture_read(32'd0, 32'd0, 64'h9000_0000, 4'h0, 3'b000, RESP_SLVERR, r);
    check("other hart read is SLVERR", 1'b1);
    aw_hart = 32'd1; ar_hart = 32'd1;
    read_reg(0, 64'h9000_0000, r);
    check("canonical word stays after the denied read", r == 32'h0003_f117);

    cases++;
    aw_then_w(32'd1, 32'd0, 64'h9000_2000, 32'h6E7A_0001, 4'h0, 3'b000, RESP_OKAY);
    aw_hart = 32'd1; ar_hart = 32'd1;
    read_reg(0, 64'h9000_2000, r);
    check("captured write grant survives a later hart pin", r == 32'h6E7A_0001);
    aw_then_w(32'd0, 32'd1, 64'h9000_2000, 32'hD11E_D11E, 4'h0, 3'b000, RESP_SLVERR);
    aw_hart = 32'd1; ar_hart = 32'd1;
    read_reg(0, 64'h9000_2000, r);
    check("later firmware hart cannot retag a denied write", r == 32'h6E7A_0001);
    capture_read(32'd1, 32'd0, 64'h9000_2000, 4'h0, 3'b000, RESP_OKAY, r);
    check("captured read grant survives a later hart pin", r == 32'h6E7A_0001);
    capture_read(32'd0, 32'd1, 64'h9000_2000, 4'h0, 3'b000, RESP_SLVERR, r);
    check("later firmware hart cannot retag a denied read", 1'b1);
    aw_hart = 32'd1; ar_hart = 32'd1;
    read_reg(0, 64'h9000_2000, r);
    check("denied read leaves the captured word", r == 32'h6E7A_0001);

    cases++;
    write_id(32'd1, 64'h9000_2000, 32'hF107_F107, 4'h7, 3'b111, RESP_OKAY);
    capture_read(32'd1, 32'd1, 64'h9000_2000, 4'hA, 3'b111, RESP_OKAY, r);
    check("PROT and AXI id do not block the firmware hart", r == 32'hF107_F107);
    write_id(32'd0, 64'h9000_2000, 32'hBAD0_BAD0, 4'h9, 3'b001, RESP_SLVERR);
    aw_hart = 32'd1; ar_hart = 32'd1;
    read_reg(0, 64'h9000_2000, r);
    check("privileged PROT does not admit another hart", r == 32'hF107_F107);
    capture_read(32'd0, 32'd0, 64'h9000_2000, 4'h9, 3'b001, RESP_SLVERR, r);
    check("privileged PROT does not admit another hart read", 1'b1);
    aw_hart = 32'd1; ar_hart = 32'd1;

    cases++;
    write_reg(0, 64'h9000_3000, 32'hAABB_CCDD);
    send_read(0, 64'h9000_3002, 3'd1);
    receive_beat(0, 64'h9000_3002, beat);
    check("aligned halfword", beat[31:16] == 16'hAABB);
    send_read(0, 64'h9000_3001, 3'd1);
    receive_beat(0, 64'h9000_3001, beat, RESP_SLVERR);
    check("misaligned halfword is SLVERR", 1'b1);
    send_read(0, 64'h9000_3000, 3'd1, 8'd1);
    drain_read(0, RESP_SLVERR);
    check("narrow burst is SLVERR", 1'b1);
    store_once(0, 64'h9000_3000, 32'h0000_005A, 3'd0, 8'h01, 1'b0, 6'h0, 1'b0,
               RESP_SLVERR);
    read_reg(0, 64'h9000_3000, r);
    check("narrow store leaves the word", r == 32'hAABB_CCDD);

    cases++;
    write_reg(0, 64'h9000_0FF0, 32'h1111_0000);
    write_reg(0, 64'h9000_0FF4, 32'h2222_0000);
    write_reg(0, 64'h9000_0FF8, 32'h3333_0000);
    write_reg(0, 64'h9000_0FFC, 32'h4444_0000);
    send_read(0, 64'h9000_0FF0, 3'd3, 8'd1);
    receive_beat(0, 64'h9000_0FF0, beat, RESP_OKAY, 0);
    check("4 KiB fill stays on the page", beat == 64'h2222_0000_1111_0000);
    receive_beat(0, 64'h9000_0FF8, beat, RESP_OKAY, 1);
    check("4 KiB fill ends on the page", beat == 64'h4444_0000_3333_0000);
    send_read(0, 64'h9000_0FF8, 3'd3, 8'd1);
    drain_read(0, RESP_SLVERR);
    check("burst that crosses 4 KiB is SLVERR", 1'b1);
    send_read(0, 64'h9000_0FF8, 3'd3);
    receive_beat(0, 64'h9000_0FF8, beat);
    check("single beat at the page end stays", beat == 64'h4444_0000_3333_0000);

    cases++;
    store_once(0, 64'h9000_3000, 32'h1111_1111, 3'd2, 8'h0f, 1'b1, 6'h0, 1'b0,
               RESP_SLVERR);
    read_reg(0, 64'h9000_3000, r);
    check("exclusive store does not write", r == 32'hAABB_CCDD);
    @(negedge clk);
    req[0].ar.addr = 64'h9000_3000; req[0].ar.size = 3'd2; req[0].ar.len = '0;
    req[0].ar.burst = BURST_INCR; req[0].ar.id = 4'h1; req[0].ar.lock = 1'b1;
    req[0].ar_valid = 1'b1;
    @(posedge clk);
    while (!rsp[0].ar_ready) @(posedge clk);
    @(negedge clk); req[0].ar_valid = 1'b0;
    @(posedge clk);
    while (!rsp[0].r_valid) @(posedge clk);
    check("exclusive read is SLVERR", rsp[0].r.resp == RESP_SLVERR &&
          rsp[0].r.resp != RESP_EXOKAY && rsp[0].r.last && rsp[0].r.id == 4'h1);
    @(negedge clk); req[0].r_ready = 1;
    @(posedge clk); @(negedge clk); req[0].r_ready = 0;
    store_once(0, 64'h9000_3000, 32'h2222_2222, 3'd2, 8'h0f, 1'b0,
               ATOP_ATOMICSWAP, 1'b1, RESP_SLVERR);
    read_reg(0, 64'h9000_3000, r);
    check("atomic swap does not write", r == 32'hAABB_CCDD);
    store_once(0, 64'h9000_3000, 32'h3333_3333, 3'd2, 8'h0f, 1'b0,
               {ATOP_ATOMICSTORE, ATOP_LITTLE_END, ATOP_ADD}, 1'b0, RESP_SLVERR);
    read_reg(0, 64'h9000_3000, r);
    check("atomic store does not write", r == 32'hAABB_CCDD);
    store_once(1, 64'h9000_3000, 32'h4444_4444, 3'd2, 8'h0f, 1'b0,
               ATOP_ATOMICSWAP, 1'b1, RESP_SLVERR);
    check("disabled atomic stays out of quarantine", !off_fault && !fault);

    cases++;
    write_reg(0, 64'h9000_4000, 32'h5150_0001);
    @(negedge clk);
    req[0].aw.addr = 64'h9000_4000; req[0].aw.size = 3'd2; req[0].aw.len = '0;
    req[0].aw.burst = BURST_INCR; req[0].aw.id = 4'h0;
    req[0].aw.lock = 1'b0; req[0].aw.atop = '0;
    req[0].w.data = 64'hffff_ffff; req[0].w.strb = 8'h0f; req[0].w.last = 1'b0;
    req[0].aw_valid = 1'b1; req[0].w_valid = 1'b1;
    @(posedge clk);
    while (!(rsp[0].aw_ready && rsp[0].w_ready)) @(posedge clk);
    @(negedge clk); req[0].aw_valid = 1'b0; req[0].w_valid = 1'b0;
    repeat (4) begin
      @(posedge clk);
      check("quarantine holds the outstanding store",
            fault && !off_fault && !rsp[0].b_valid && !rsp[0].r_valid &&
            !rsp[0].aw_ready && !rsp[0].ar_ready && !rsp[0].w_ready);
    end
    @(negedge clk); rst_ni = 1'b0; req[0] = '0; req[1] = '0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("reset releases quarantine", !fault && !off_fault && rsp[0].aw_ready &&
          !rsp[0].b_valid);
    read_reg(0, 64'h9000_4000, r);
    check("quarantined store did not land", r == 32'h5150_0001);
    write_reg(0, 64'h9000_4000, 32'h5150_0002);
    read_reg(0, 64'h9000_4000, r);
    check("legal store works after reset", r == 32'h5150_0002);

    if (errors != 0) $fatal(1, "APU fwram errors=%0d", errors);
    $display("PASS tb_g6lc_apu_fwram cases=%0d checks=%0d cycles=%0d errors=0 nwords=%0d",
             cases, checks, cycles, nwords);
    $finish;
  end
endmodule
