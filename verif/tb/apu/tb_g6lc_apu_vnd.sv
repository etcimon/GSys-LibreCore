// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Mesa vn_protocol vkCmdDispatch CS. Stock encode; not vncs DISPATCH.

`timescale 1ns/1ps

module tb_g6lc_apu_vnd;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic cs_we = 0, req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  logic [3:0] cs_idx = 0;
  logic [31:0] cs_wdata = 0, cs_rdata;
  apu_vnd_cpl_t cpl;
  apu_vnd_t rec;
  logic off_rdy, off_v;
  apu_vnd_cpl_t off_cpl;
  apu_vnd_t off_rec;
  logic [31:0] off_rdata;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_vnd #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(cs_rdata),
    .req_valid_i(req_v), .req_ready_o(req_rdy),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .vnd_o(rec)
  );
  g6lc_apu_vnd_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(off_rdata),
    .req_valid_i(req_v), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .vnd_o(off_rec)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "vnd timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_rec !== '0 || off_cpl !== '0)
      $fatal(1, "disabled vnd active");
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d", name, cases, cycles);
    end
  endtask

  task automatic poke(input int unsigned idx, input logic [31:0] w);
    @(negedge clk);
    cs_we = 1'b1;
    cs_idx = 4'(idx);
    cs_wdata = w;
    @(posedge clk);
    @(negedge clk);
    cs_we = 1'b0;
  endtask

  task automatic peek(input int unsigned idx, output logic [31:0] w);
    cs_idx = 4'(idx);
    @(negedge clk);
    w = cs_rdata;
  endtask

  task automatic poke64(input int unsigned idx, input logic [63:0] v);
    poke(idx, v[31:0]);
    poke(idx + 1, v[63:32]);
  endtask

  task automatic fire;
    @(negedge clk);
    while (!req_rdy) @(negedge clk);
    req_v = 1'b1;
    @(posedge clk);
    @(negedge clk);
    req_v = 1'b0;
    while (!cpl_v) @(negedge clk);
  endtask

  task automatic ack;
    @(negedge clk);
    cpl_r = 1'b1;
    @(posedge clk);
    while (cpl_v) @(posedge clk);
    @(negedge clk);
    cpl_r = 1'b0;
  endtask

  task automatic do_reset;
    cs_we = 1'b0; req_v = 1'b0; cpl_r = 1'b0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  task automatic load_dispatch(input logic [31:0] flags, input logic [63:0] cmdbuf,
                               input logic [31:0] x, input logic [31:0] y,
                               input logic [31:0] z);
    poke(0, APU_VND_CMD_DISPATCH);
    poke(1, flags);
    poke64(2, cmdbuf);
    poke(4, x);
    poke(5, y);
    poke(6, z);
  endtask

  initial begin
    apu_cfg_t cfg;
    logic [31:0] t;

    do_reset;
    cases++;
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && req_rdy == 1'b1);
    check("profiles keep vnd off",
          !ApuOff.VndEn && !ApuP1Transport.VndEn && !ApuHarness.VndEn);
    cfg = ApuP1Transport;
    cfg.VndEn = 1'b1;
    check("vnd does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.VndEn = 1'b1;
    check("vnd does not legalize virgl", !apu_cfg_legal(cfg));
    check("mesa dispatch id", APU_VND_CMD_DISPATCH == 32'd110 &&
          APU_VNENC_CMD_CREATE_SHADER_MODULE == 32'd59);

    cases++;
    load_dispatch(32'd0, 64'h0000_0000_0000_00B1, 32'd2, 32'd3, 32'd4);
    fire();
    check("dispatch ok", cpl.status == APU_VND_OK && rec.valid &&
          rec.cmd_type == 32'd110 && rec.command_buffer == 64'hB1 &&
          rec.group_x == 32'd2 && rec.group_y == 32'd3 && rec.group_z == 32'd4 &&
          !rec.reply);
    ack();

    cases++;
    do_reset;
    load_dispatch(APU_VND_GENERATE_REPLY, 64'hC2, 32'd1, 32'd1, 32'd1);
    fire();
    check("reply dispatch", cpl.status == APU_VND_OK && rec.valid && rec.reply &&
          rec.group_x == 32'd1 && rec.command_buffer == 64'hC2);
    peek(APU_VND_REPLY, t);
    check("reply type", t == 32'd110);
    ack();

    cases++;
    do_reset;
    load_dispatch(32'd0, 64'hB1, 32'd2, 32'd3, 32'd4);
    poke(0, APU_VNENC_CMD_CREATE_SHADER_MODULE);
    fire();
    check("create module faults", cpl.status == APU_VND_FAULT && !rec.valid);
    ack();

    cases++;
    do_reset;
    load_dispatch(32'd0, 64'hB1, 32'd2, 32'd3, 32'd4);
    poke(0, 32'd0);
    fire();
    check("instance faults", cpl.status == APU_VND_FAULT);
    ack();

    cases++;
    do_reset;
    load_dispatch(32'd0, 64'd0, 32'd2, 32'd3, 32'd4);
    fire();
    check("null cmdbuf faults", cpl.status == APU_VND_FAULT);
    ack();

    cases++;
    do_reset;
    load_dispatch(32'd0, 64'hB1, 32'd2, 32'd3, 32'd4);
    poke(0, APU_VND_CMD_DISPATCH_INDIRECT);
    fire();
    check("indirect faults", cpl.status == APU_VND_FAULT);
    ack();

    if (errors != 0) $fatal(1, "APU vnd errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vnd cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
