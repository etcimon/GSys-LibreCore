// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// vkCreateShaderModule publishes MODULE; vkCmdDispatch looks up CMDBUF.

`timescale 1ns/1ps

module tb_g6lc_apu_hph;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic cs_we = 0, req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  logic [7:0] cs_idx = 0;
  logic [31:0] cs_wdata = 0, cs_rdata;
  apu_hph_req_t req;
  apu_hph_cpl_t cpl;
  apu_hph_t rec;
  logic off_rdy, off_v;
  apu_hph_cpl_t off_cpl;
  apu_hph_t off_rec;
  logic [31:0] off_rdata;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_hph #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(cs_rdata),
    .req_valid_i(req_v), .req_ready_o(req_rdy), .req_i(req),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .hph_o(rec)
  );
  g6lc_apu_hph_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(off_rdata),
    .req_valid_i(req_v), .req_ready_o(off_rdy), .req_i(req),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .hph_o(off_rec)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "hph timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_rec !== '0 || off_cpl !== '0)
      $fatal(1, "disabled hph active");
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

  task automatic poke64(input int unsigned idx, input logic [63:0] v);
    poke(idx, v[31:0]);
    poke(idx + 1, v[63:32]);
  endtask

  task automatic fire(input apu_hph_req_t r);
    @(negedge clk);
    while (!req_rdy) @(negedge clk);
    req = r;
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
    cs_we = 1'b0; req_v = 1'b0; cpl_r = 1'b0; req = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  function automatic apu_hph_req_t mk_gnh(
      input apu_gnh_op_e op, input apu_gnh_kind_e kind,
      input logic [31:0] oid, input logic [31:0] h);
    mk_gnh = '0;
    mk_gnh.op = APU_HPH_GNH;
    mk_gnh.gnh.op = op;
    mk_gnh.gnh.kind = kind;
    mk_gnh.gnh.object_id = oid;
    mk_gnh.gnh.handle = h;
  endfunction

  function automatic apu_hph_req_t mk_op(input apu_hph_op_e op);
    mk_op = '0;
    mk_op.op = op;
  endfunction

  task automatic load_create(input logic [31:0] first, input int unsigned n,
                             input logic [63:0] module_id);
    int unsigned i;
    poke(0, APU_VNENC_CMD_CREATE_SHADER_MODULE);
    poke(1, 32'd0);
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

  task automatic load_dispatch(input logic [63:0] cmdbuf,
                               input logic [31:0] x, input logic [31:0] y,
                               input logic [31:0] z);
    poke(0, APU_VND_CMD_DISPATCH);
    poke(1, 32'd0);
    poke64(2, cmdbuf);
    poke(4, x);
    poke(5, y);
    poke(6, z);
  endtask

  initial begin
    apu_cfg_t cfg;
    logic [31:0] hm, hc;

    do_reset;
    cases++;
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && req_rdy == 1'b1);
    check("profiles keep hph off",
          !ApuOff.HphEn && !ApuP1Transport.HphEn && !ApuHarness.HphEn);
    cfg = ApuP1Transport;
    cfg.HphEn = 1'b1;
    check("hph does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.HphEn = 1'b1;
    check("hph does not legalize virgl", !apu_cfg_legal(cfg));

    cases++;
    load_create(APU_VNENC_SPIRV_MAGIC, 5, 64'hB2);
    fire(mk_op(APU_HPH_CREATE));
    hm = rec.handle;
    check("create module", cpl.status == APU_HPH_OK && rec.valid && rec.create &&
          rec.kind == APU_GNH_MODULE && rec.object_id == 32'hB2 &&
          rec.code_words == 32'd5 && !rec.dispatch);
    ack();
    fire(mk_gnh(APU_GNH_LOOKUP, APU_GNH_MODULE, 32'd0, hm));
    check("lookup module", cpl.status == APU_HPH_OK && rec.valid &&
          rec.object_id == 32'hB2 && rec.kind == APU_GNH_MODULE);
    ack();

    cases++;
    fire(mk_gnh(APU_GNH_ALLOC, APU_GNH_CMDBUF, 32'd1, 32'd0));
    hc = rec.handle;
    check("alloc cmdbuf", cpl.status == APU_HPH_OK && rec.valid &&
          rec.kind == APU_GNH_CMDBUF);
    ack();
    load_dispatch(64'(hc), 32'd2, 32'd3, 32'd4);
    fire(mk_op(APU_HPH_DISPATCH));
    check("dispatch ok", cpl.status == APU_HPH_OK && rec.valid && rec.dispatch &&
          rec.handle == hc && rec.kind == APU_GNH_CMDBUF &&
          rec.group_x == 32'd2 && rec.group_y == 32'd3 && rec.group_z == 32'd4);
    ack();

    cases++;
    load_dispatch(64'(hm), 32'd1, 32'd1, 32'd1);
    fire(mk_op(APU_HPH_DISPATCH));
    check("module as cmdbuf faults", cpl.status == APU_HPH_FAULT && !rec.valid);
    ack();

    cases++;
    load_create(APU_VNENC_SPIRV_MAGIC, 5, 64'hB2);
    fire(mk_op(APU_HPH_CREATE));
    check("duplicate module faults", cpl.status == APU_HPH_FAULT);
    ack();

    cases++;
    do_reset;
    poke(0, 32'd0);
    poke(1, 32'd0);
    poke64(2, 64'hA1);
    poke64(4, 64'd1);
    poke(6, APU_VNENC_STYPE_SHADER_MODULE);
    fire(mk_op(APU_HPH_CREATE));
    check("instance faults", cpl.status == APU_HPH_FAULT);
    ack();

    if (errors != 0) $fatal(1, "APU hph errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_hph cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
