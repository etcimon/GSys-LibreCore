// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Mesa vn_protocol vkCreateShaderModule CS. Stock encode; not vncs.

`timescale 1ns/1ps

module tb_g6lc_apu_vnenc;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic cs_we = 0, req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  logic [7:0] cs_idx = 0;
  logic [31:0] cs_wdata = 0, cs_rdata;
  apu_vnenc_cpl_t cpl;
  apu_vnenc_t rec;
  logic off_rdy, off_v;
  apu_vnenc_cpl_t off_cpl;
  apu_vnenc_t off_rec;
  logic [31:0] off_rdata;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_vnenc #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(cs_rdata),
    .req_valid_i(req_v), .req_ready_o(req_rdy),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .vnenc_o(rec)
  );
  g6lc_apu_vnenc_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(off_rdata),
    .req_valid_i(req_v), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .vnenc_o(off_rec)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "vnenc timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_rec !== '0 || off_cpl !== '0)
      $fatal(1, "disabled vnenc active");
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
    cs_idx = 8'(idx);
    cs_wdata = w;
    @(posedge clk);
    @(negedge clk);
    cs_we = 1'b0;
  endtask

  task automatic peek(input int unsigned idx, output logic [31:0] w);
    cs_idx = 8'(idx);
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

  task automatic load_create(input logic [31:0] flags, input logic [31:0] first,
                             input int unsigned n, input logic [63:0] module_id);
    int unsigned i;
    poke(0, APU_VNENC_CMD_CREATE_SHADER_MODULE);
    poke(1, flags);
    poke64(2, 64'h0000_0000_0000_00A1);
    poke64(4, 64'd1);
    poke(6, APU_VNENC_STYPE_SHADER_MODULE);
    poke64(7, 64'd0);
    poke(9, 32'd0);
    poke64(10, 64'(n * 4));
    poke64(12, 64'(n));
    poke(APU_VNENC_CODE0, first);
    for (i = 1; i < n; i++) poke(APU_VNENC_CODE0 + i, 32'h0001_0000);
    poke64(APU_VNENC_CODE0 + n, 64'd0);
    poke64(APU_VNENC_CODE0 + n + 2, 64'd1);
    poke64(APU_VNENC_CODE0 + n + 4, module_id);
  endtask

  initial begin
    apu_cfg_t cfg;
    logic [31:0] t;

    do_reset;
    cases++;
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && req_rdy == 1'b1);
    check("profiles keep vnenc off",
          !ApuOff.VnencEn && !ApuP1Transport.VnencEn && !ApuHarness.VnencEn);
    cfg = ApuP1Transport;
    cfg.VnencEn = 1'b1;
    check("vnenc does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.VnencEn = 1'b1;
    check("vnenc does not legalize virgl", !apu_cfg_legal(cfg));
    check("mesa create id", APU_VNENC_CMD_CREATE_SHADER_MODULE == 32'd59 &&
          APU_VNENC_STYPE_SHADER_MODULE == 32'd16);

    cases++;
    load_create(32'd0, APU_VNENC_SPIRV_MAGIC, 5, 64'h0000_0000_0000_00B2);
    fire();
    check("create ok", cpl.status == APU_VNENC_OK && rec.valid &&
          rec.cmd_type == 32'd59 && rec.code_words == 32'd5 &&
          rec.code_bytes == 32'd20 && rec.first_word == APU_VNENC_SPIRV_MAGIC &&
          rec.module_id == 64'hB2 && rec.device == 64'hA1 && !rec.reply);
    ack();

    cases++;
    do_reset;
    load_create(APU_VNENC_GENERATE_REPLY, 32'hDEAD_BEEF, 2, 64'hC3);
    fire();
    check("reply create", cpl.status == APU_VNENC_OK && rec.valid && rec.reply &&
          rec.first_word == 32'hDEAD_BEEF && rec.code_words == 32'd2);
    peek(APU_VNENC_REPLY, t);
    check("reply type", t == 32'd59);
    peek(APU_VNENC_REPLY + 1, t);
    check("reply success", t == 32'd0);
    peek(APU_VNENC_REPLY + 4, t);
    check("reply handle", t == 32'hC3);
    ack();

    cases++;
    do_reset;
    load_create(32'd0, APU_VNENC_SPIRV_MAGIC, 5, 64'hB2);
    poke(0, 32'd0);
    fire();
    check("instance faults", cpl.status == APU_VNENC_FAULT);
    ack();

    cases++;
    do_reset;
    load_create(32'd0, APU_VNENC_SPIRV_MAGIC, 5, 64'hB2);
    poke64(4, 64'd0);
    fire();
    check("null info faults", cpl.status == APU_VNENC_FAULT);
    ack();

    cases++;
    do_reset;
    load_create(32'd0, APU_VNENC_SPIRV_MAGIC, 5, 64'hB2);
    poke64(12, 64'd0);
    fire();
    check("empty pcode faults", cpl.status == APU_VNENC_FAULT);
    ack();

    if (errors != 0) $fatal(1, "APU vnenc errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vnenc cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
