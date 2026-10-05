// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Mesa vn_protocol vkEndCommandBuffer CS. Stock encode; not pixels.

`timescale 1ns/1ps

module tb_g6lc_apu_ven;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic cs_we = 0, req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  logic [3:0] cs_idx = 0;
  logic [31:0] cs_wdata = 0, cs_rdata;
  apu_ven_cpl_t cpl;
  apu_ven_t rec;
  logic off_rdy, off_v;
  apu_ven_cpl_t off_cpl;
  apu_ven_t off_rec;
  logic [31:0] off_rdata;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_ven #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(cs_rdata),
    .req_valid_i(req_v), .req_ready_o(req_rdy),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .ven_o(rec)
  );
  g6lc_apu_ven_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(off_rdata),
    .req_valid_i(req_v), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .ven_o(off_rec)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "ven timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_rec !== '0 || off_cpl !== '0)
      $fatal(1, "disabled ven active");
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

  task automatic load_end(input logic [31:0] flags, input logic [63:0] cmdbuf);
    poke(0, APU_VEN_CMD_END);
    poke(1, flags);
    poke64(2, cmdbuf);
  endtask

  initial begin
    apu_cfg_t cfg;
    logic [31:0] t0, t1;

    do_reset;
    cases++;
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && req_rdy == 1'b1);
    check("profiles keep ven off",
          !ApuOff.VenEn && !ApuP1Transport.VenEn && !ApuHarness.VenEn);
    cfg = ApuP1Transport;
    cfg.VenEn = 1'b1;
    check("ven does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.VenEn = 1'b1;
    check("ven does not legalize virgl", !apu_cfg_legal(cfg));
    check("mesa end id", APU_VEN_CMD_END == 32'd91 &&
          APU_VBG_CMD_BEGIN == 32'd90 && APU_VAC_CMD_ALLOC == 32'd88 &&
          APU_VND_CMD_DISPATCH == 32'd110);
    check("num capsets stays 0", ApuOff.NumCapsets == 0 &&
          ApuP1Transport.NumCapsets == 0 && ApuHarness.NumCapsets == 0);

    cases++;
    load_end(32'd0, 64'h0000_0000_0000_00C1);
    fire();
    check("end ok", cpl.status == APU_VEN_OK && rec.valid &&
          rec.cmd_type == 32'd91 && rec.command_buffer == 64'hC1 &&
          !rec.reply);
    ack();

    cases++;
    do_reset;
    load_end(APU_VEN_GENERATE_REPLY, 64'hC2);
    fire();
    check("reply end", cpl.status == APU_VEN_OK && rec.valid && rec.reply &&
          rec.command_buffer == 64'hC2);
    peek(APU_VEN_REPLY, t0);
    peek(APU_VEN_REPLY + 1, t1);
    check("reply type success", t0 == 32'd91 && t1 == 32'd0);
    ack();

    cases++;
    do_reset;
    load_end(32'd0, 64'hC1);
    poke(0, APU_VBG_CMD_BEGIN);
    fire();
    check("begin faults", cpl.status == APU_VEN_FAULT && !rec.valid);
    ack();

    cases++;
    do_reset;
    load_end(32'd0, 64'hC1);
    poke(0, APU_VAC_CMD_ALLOC);
    fire();
    check("alloc faults", cpl.status == APU_VEN_FAULT && !rec.valid);
    ack();

    cases++;
    do_reset;
    load_end(32'd0, 64'hC1);
    poke(0, APU_VNENC_CMD_CREATE_SHADER_MODULE);
    fire();
    check("create module faults", cpl.status == APU_VEN_FAULT);
    ack();

    cases++;
    do_reset;
    load_end(32'd0, 64'hC1);
    poke(0, 32'd0);
    fire();
    check("instance faults", cpl.status == APU_VEN_FAULT);
    ack();

    cases++;
    do_reset;
    load_end(32'd0, 64'hC1);
    poke(0, APU_VND_CMD_DISPATCH);
    fire();
    check("dispatch faults", cpl.status == APU_VEN_FAULT);
    ack();

    cases++;
    do_reset;
    load_end(32'd0, 64'd0);
    fire();
    check("null cmdbuf faults", cpl.status == APU_VEN_FAULT);
    ack();

    cases++;
    do_reset;
    load_end(32'd0, 64'h0000_0001_0000_00C1);
    fire();
    check("high-half faults", cpl.status == APU_VEN_FAULT);
    ack();

    if (errors != 0) $fatal(1, "APU ven errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_ven cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
