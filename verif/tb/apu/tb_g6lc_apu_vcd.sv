// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Mesa vn_protocol vkCreateDevice CS. Stock encode; not pixels.

`timescale 1ns/1ps

module tb_g6lc_apu_vcd;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic cs_we = 0, req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  logic [5:0] cs_idx = 0;
  logic [31:0] cs_wdata = 0, cs_rdata;
  apu_vcd_cpl_t cpl;
  apu_vcd_t rec;
  logic off_rdy, off_v;
  apu_vcd_cpl_t off_cpl;
  apu_vcd_t off_rec;
  logic [31:0] off_rdata;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_vcd #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(cs_rdata),
    .req_valid_i(req_v), .req_ready_o(req_rdy),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .vcd_o(rec)
  );
  g6lc_apu_vcd_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(off_rdata),
    .req_valid_i(req_v), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .vcd_o(off_rec)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "vcd timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_rec !== '0 || off_cpl !== '0)
      $fatal(1, "disabled vcd active");
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
    cs_idx = 6'(idx);
    cs_wdata = w;
    @(posedge clk);
    @(negedge clk);
    cs_we = 1'b0;
  endtask

  task automatic peek(input int unsigned idx, output logic [31:0] w);
    cs_idx = 6'(idx);
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

  task automatic load_device(input logic [31:0] flags, input logic [63:0] phys);
    integer i;
    for (i = 0; i < APU_VCD_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VCD_CMD_DEVICE);
    poke(1, flags);
    poke64(2, phys);
    poke64(4, 64'd1);
    poke(6, APU_VCD_STYPE_DEVICE);
    poke64(7, 64'd0);
    poke(9, 32'd0);
    poke(10, 32'd1);
    poke64(11, 64'd1);
    poke(13, APU_VCD_STYPE_QUEUE);
    poke64(14, 64'd0);
    poke(16, 32'd0);
    poke(17, 32'd0);
    poke(18, 32'd1);
    poke64(19, 64'd1);
    poke(21, APU_VCD_PRIORITY_ONE);
    poke(22, 32'd0);
    poke64(23, 64'd0);
    poke(25, 32'd0);
    poke64(26, 64'd0);
    poke64(28, 64'd0);
    poke64(30, 64'd0);
  endtask

  initial begin
    apu_cfg_t cfg;
    logic [31:0] t0, t1;

    do_reset;
    cases++;
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && req_rdy == 1'b1);
    check("profiles keep vcd off",
          !ApuOff.VcdEn && !ApuP1Transport.VcdEn && !ApuHarness.VcdEn);
    cfg = ApuP1Transport;
    cfg.VcdEn = 1'b1;
    check("vcd does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.VcdEn = 1'b1;
    check("vcd does not legalize virgl", !apu_cfg_legal(cfg));
    check("mesa device id", APU_VCD_CMD_DEVICE == 32'd11 &&
          APU_VGQ_CMD_QUEUE == 32'd17 && APU_GNH_DEVICE == 3'd5);
    check("num capsets stays 0", ApuOff.NumCapsets == 0 &&
          ApuP1Transport.NumCapsets == 0 && ApuHarness.NumCapsets == 0);

    cases++;
    load_device(32'd0, 64'hA1);
    fire();
    check("device ok", cpl.status == APU_VCD_OK && rec.valid &&
          rec.cmd_type == 32'd11 && rec.physical_device == 64'hA1 && !rec.reply);
    ack();

    cases++;
    do_reset;
    load_device(APU_VCD_GENERATE_REPLY, 64'hA2);
    fire();
    check("reply device", cpl.status == APU_VCD_OK && rec.valid && rec.reply);
    peek(APU_VCD_REPLY, t0);
    peek(APU_VCD_REPLY + 1, t1);
    check("reply type", t0 == 32'd11 && t1 == 32'd0);
    ack();

    cases++;
    do_reset;
    load_device(32'd0, 64'hA1);
    poke(0, APU_VGQ_CMD_QUEUE);
    fire();
    check("queue faults", cpl.status == APU_VCD_FAULT && !rec.valid);
    ack();

    cases++;
    do_reset;
    load_device(32'd0, 64'd0);
    fire();
    check("null phys faults", cpl.status == APU_VCD_FAULT);
    ack();

    cases++;
    do_reset;
    load_device(32'd0, 64'hA1);
    poke(17, 32'd1);
    fire();
    check("family faults", cpl.status == APU_VCD_FAULT);
    ack();

    cases++;
    do_reset;
    load_device(32'd0, 64'hA1);
    poke(6, 32'd2);
    fire();
    check("stype faults", cpl.status == APU_VCD_FAULT);
    ack();

    if (errors != 0) $fatal(1, "APU vcd errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vcd cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
