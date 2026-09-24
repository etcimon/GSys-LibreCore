// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Per-core guard: hart 0 cannot push firmware RAM or control into the
// downstream port. Hart 1 is a wire. AXI id and PROT do not select the hart.

`timescale 1ns/1ps

module g6lc_apu_src_guard_fixture
  import g6lc_apu_bus_pkg::*;
#(parameter logic [31:0] Hart = 32'h0,
  parameter logic [31:0] FwHart = 32'd1) (
  input  logic clk_i,
  input  logic rst_ni,
  input  apu_dma_axi_req_t up_req_i,
  output apu_dma_axi_resp_t up_resp_o,
  output apu_dma_axi_req_t dn_req_o,
  input  apu_dma_axi_resp_t dn_resp_i
);
  g6lc_apu_src_guard #(
      .Hart(Hart),
      .FwHart(FwHart),
      .RamBase(64'h9000_0000),
      .RamBytes(64'h4_0000),
      .CtrlBase(64'h4000_2000),
      .CtrlBytes(64'h1000),
      .axi_req_t(apu_dma_axi_req_t),
      .axi_resp_t(apu_dma_axi_resp_t)
  ) i_dut (
      .clk_i, .rst_ni,
      .up_req_i, .up_resp_o,
      .dn_req_o, .dn_resp_i
  );
endmodule

module tb_g6lc_apu_src_guard;
  import g6lc_apu_bus_pkg::*;
  import axi_pkg::*;
  logic clk = 0, rst_ni = 0;
  apu_dma_axi_req_t up0, up1;
  apu_dma_axi_resp_t ur0, ur1, dr0, dr1;
  apu_dma_axi_req_t dn0, dn1;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  bit watch0 = 0;

  g6lc_apu_src_guard_fixture #(.Hart(32'h0), .FwHart(32'd1)) i_app (
      .clk_i(clk), .rst_ni,
      .up_req_i(up0), .up_resp_o(ur0),
      .dn_req_o(dn0), .dn_resp_i(dr0)
  );
  g6lc_apu_src_guard_fixture #(.Hart(32'd1), .FwHart(32'd1)) i_fw (
      .clk_i(clk), .rst_ni,
      .up_req_i(up1), .up_resp_o(ur1),
      .dn_req_o(dn1), .dn_resp_i(dr1)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  always @(posedge clk) begin
    if (rst_ni && watch0 && (dn0.aw_valid || dn0.w_valid || dn0.ar_valid)) begin
      errors++;
      $display("FAIL downstream saw a denied beat cycle=%0d", cycles);
    end
  end
  initial begin #200000; $fatal(1, "src guard timeout case=%0d", cases); end

  // Downstream accepts a beat and answers OKAY. Reads return a fixed word.
  logic b_pend0, r_pend0, b_pend1, r_pend1;
  logic [3:0] b_id0, r_id0, b_id1, r_id1;
  logic [7:0] r_left0, r_left1;
  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      b_pend0 <= 0; r_pend0 <= 0; b_pend1 <= 0; r_pend1 <= 0;
      b_id0 <= '0; r_id0 <= '0; b_id1 <= '0; r_id1 <= '0;
      r_left0 <= '0; r_left1 <= '0;
    end else begin
      if (dn0.aw_valid && dr0.aw_ready && dn0.w_valid && dr0.w_ready && dn0.w.last)
        begin b_pend0 <= 1; b_id0 <= dn0.aw.id; end
      if (b_pend0 && dn0.b_ready) b_pend0 <= 0;
      if (dn0.ar_valid && dr0.ar_ready) begin
        r_pend0 <= 1; r_id0 <= dn0.ar.id; r_left0 <= dn0.ar.len;
      end else if (r_pend0 && dn0.r_ready) begin
        if (r_left0 == '0) r_pend0 <= 0;
        else r_left0 <= r_left0 - 1'b1;
      end
      if (dn1.aw_valid && dr1.aw_ready && dn1.w_valid && dr1.w_ready && dn1.w.last)
        begin b_pend1 <= 1; b_id1 <= dn1.aw.id; end
      if (b_pend1 && dn1.b_ready) b_pend1 <= 0;
      if (dn1.ar_valid && dr1.ar_ready) begin
        r_pend1 <= 1; r_id1 <= dn1.ar.id; r_left1 <= dn1.ar.len;
      end else if (r_pend1 && dn1.r_ready) begin
        if (r_left1 == '0) r_pend1 <= 0;
        else r_left1 <= r_left1 - 1'b1;
      end
    end
  end
  always_comb begin
    dr0 = '0; dr1 = '0;
    dr0.aw_ready = 1; dr0.w_ready = 1; dr0.ar_ready = 1;
    dr1.aw_ready = 1; dr1.w_ready = 1; dr1.ar_ready = 1;
    dr0.b_valid = b_pend0; dr0.b.id = b_id0; dr0.b.resp = RESP_OKAY;
    dr1.b_valid = b_pend1; dr1.b.id = b_id1; dr1.b.resp = RESP_OKAY;
    dr0.r_valid = r_pend0; dr0.r.id = r_id0; dr0.r.resp = RESP_OKAY;
    dr0.r.data = 64'hA5A5_A5A5_A5A5_A5A5; dr0.r.last = (r_left0 == '0);
    dr1.r_valid = r_pend1; dr1.r.id = r_id1; dr1.r.resp = RESP_OKAY;
    dr1.r.data = 64'hA5A5_A5A5_A5A5_A5A5; dr1.r.last = (r_left1 == '0);
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask

  task automatic fwd_write(input int which, input logic [63:0] addr,
      input logic [3:0] id, input logic [2:0] prot);
    apu_dma_axi_req_t req;
    apu_dma_axi_resp_t rsp;
    apu_dma_axi_req_t dn;
    req = '0;
    @(negedge clk);
    if (which == 0) up0 = '0; else up1 = '0;
    req.aw.addr = addr; req.aw.size = 3'd2; req.aw.len = '0;
    req.aw.burst = BURST_INCR; req.aw.id = id; req.aw.prot = prot;
    req.aw.user = 1'b1;
    req.w.data = 64'h11; req.w.strb = 8'h0f; req.w.last = 1'b1;
    req.aw_valid = 1; req.w_valid = 1;
    if (which == 0) up0 = req; else up1 = req;
    @(posedge clk);
    dn = (which == 0) ? dn0 : dn1;
    rsp = (which == 0) ? ur0 : ur1;
    check("forward AW reaches downstream", dn.aw_valid && dn.aw.addr == addr &&
          dn.aw.id == id && dn.aw.prot == prot && dn.aw.user == 1'b1);
    @(negedge clk);
    if (which == 0) begin up0.aw_valid = 0; up0.w_valid = 0; end
    else begin up1.aw_valid = 0; up1.w_valid = 0; end
    @(posedge clk);
    while (!(which == 0 ? ur0.b_valid : ur1.b_valid)) @(posedge clk);
    rsp = (which == 0) ? ur0 : ur1;
    check("forward B is OKAY", rsp.b.resp == RESP_OKAY && rsp.b.id == id);
    @(negedge clk);
    if (which == 0) up0.b_ready = 1; else up1.b_ready = 1;
    @(posedge clk); @(negedge clk);
    if (which == 0) up0.b_ready = 0; else up1.b_ready = 0;
  endtask

  task automatic deny_write(input logic [63:0] addr, input logic [7:0] len,
      input logic [3:0] id, input logic [2:0] prot, input bit bad_last);
    int n;
    watch0 = 1;
    @(negedge clk);
    up0 = '0;
    up0.aw.addr = addr; up0.aw.size = 3'd2; up0.aw.len = len;
    up0.aw.burst = BURST_INCR; up0.aw.id = id; up0.aw.prot = prot;
    up0.w.strb = 8'h0f; up0.w.last = (len == '0) && !bad_last;
    up0.w.data = 64'hffff_ffff;
    up0.aw_valid = 1; up0.w_valid = 1;
    @(posedge clk);
    check("denied AW is not forwarded", !dn0.aw_valid && !dn0.w_valid);
    @(negedge clk);
    up0.aw_valid = 0;
    up0.w_valid = 0;
    if (bad_last) begin
      repeat (3) begin
        @(posedge clk);
        check("bad WLAST stays quiet", !ur0.b_valid && !dn0.aw_valid);
      end
      @(negedge clk); rst_ni = 0; up0 = '0; watch0 = 0;
      repeat (2) @(negedge clk);
      rst_ni = 1;
      @(posedge clk);
      check("reset leaves the guard idle", !ur0.b_valid && !dn0.aw_valid);
      return;
    end
    for (n = 1; n <= int'(len); n++) begin
      @(negedge clk);
      up0.w_valid = 1;
      up0.w.last = (n == int'(len));
      @(posedge clk);
      while (!ur0.w_ready) @(posedge clk);
      @(negedge clk);
      up0.w_valid = 0;
    end
    @(posedge clk);
    while (!ur0.b_valid) @(posedge clk);
    check("denied store is SLVERR", ur0.b.resp == RESP_SLVERR && ur0.b.id == id &&
          !dn0.aw_valid);
    @(negedge clk); up0.b_ready = 1;
    @(posedge clk); @(negedge clk); up0.b_ready = 0;
    watch0 = 0;
  endtask

  task automatic deny_read(input logic [63:0] addr, input logic [7:0] len,
      input logic [3:0] id, input logic [2:0] prot);
    int n;
    watch0 = 1;
    @(negedge clk);
    up0 = '0;
    up0.ar.addr = addr; up0.ar.size = 3'd3; up0.ar.len = len;
    up0.ar.burst = BURST_INCR; up0.ar.id = id; up0.ar.prot = prot;
    up0.ar_valid = 1;
    @(posedge clk);
    check("denied AR is not forwarded", !dn0.ar_valid && ur0.ar_ready);
    @(negedge clk); up0.ar_valid = 0;
    for (n = 0; n <= int'(len); n++) begin
      @(posedge clk);
      while (!ur0.r_valid) @(posedge clk);
      check("denied read beat", ur0.r.resp == RESP_SLVERR && ur0.r.id == id &&
            ur0.r.last == (n == int'(len)) && !dn0.ar_valid);
      @(negedge clk); up0.r_ready = 1;
      @(posedge clk); @(negedge clk); up0.r_ready = 0;
    end
    watch0 = 0;
  endtask

  initial begin
    up0 = '0; up1 = '0;
    repeat (3) @(negedge clk);
    rst_ni = 1;
    @(posedge clk);

    cases = 1;
    fwd_write(0, 64'h8000_1000, 4'h7, 3'b111);
    check("application hart reaches DRAM", 1'b1);
    fwd_write(0, 64'hFFFF_FFFF_9000_0000, 4'h1, 3'b000);
    check("sign-extended alias is not the RAM window", 1'b1);

    cases = 2;
    deny_write(64'h9000_0000, 8'd0, 4'hF, 3'b111, 1'b0);
    deny_write(64'h4000_2000, 8'd0, 4'h2, 3'b001, 1'b0);
    deny_read(64'h9000_0010, 8'd2, 4'h9, 3'b111);
    fwd_write(0, 64'h8000_2000, 4'h3, 3'b000);
    check("DRAM store still completes after a denial", 1'b1);

    cases = 3;
    deny_write(64'h9000_0100, 8'd3, 4'h4, 3'b000, 1'b0);
    deny_write(64'h9000_0100, 8'd0, 4'h5, 3'b000, 1'b1);
    fwd_write(0, 64'h8000_3000, 4'h6, 3'b010);
    check("DRAM store completes after quarantine reset", 1'b1);

    cases = 4;
    fwd_write(1, 64'h9000_0000, 4'hA, 3'b111);
    fwd_write(1, 64'h4000_2004, 4'hB, 3'b001);

    if (errors != 0) $fatal(1, "APU src guard errors=%0d", errors);
    $display("PASS tb_g6lc_apu_src_guard cases=%0d checks=%0d cycles=%0d errors=0",
             cases, checks, cycles);
    $finish;
  end
endmodule
