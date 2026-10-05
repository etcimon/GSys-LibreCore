// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// vkAllocateCommandBuffers ALLOC CMDBUF, vkBeginCommandBuffer LOOKUP,
// then vkEndCommandBuffer LOOKUP. NumCapsets stays 0. Not pixels.

`timescale 1ns/1ps

module tb_g6lc_apu_eal;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic cs_we = 0, req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  logic [4:0] cs_idx = 0;
  logic [31:0] cs_wdata = 0, cs_rdata;
  apu_eal_req_t req;
  apu_eal_cpl_t cpl;
  apu_eal_t rec;
  logic off_rdy, off_v;
  apu_eal_cpl_t off_cpl;
  apu_eal_t off_rec;
  logic [31:0] off_rdata;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_eal #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(cs_rdata),
    .req_valid_i(req_v), .req_ready_o(req_rdy), .req_i(req),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .eal_o(rec)
  );
  g6lc_apu_eal_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(off_rdata),
    .req_valid_i(req_v), .req_ready_o(off_rdy), .req_i(req),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .eal_o(off_rec)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "eal timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_rec !== '0 || off_cpl !== '0)
      $fatal(1, "disabled eal active");
  end

  task automatic check(input string name, input logic ok);
    checks++;
    if (ok !== 1'b1) begin
      errors++;
      $display("FAIL %s case=%0d cycle=%0d st=%0d", name, cases, cycles, cpl.status);
    end
  endtask

  task automatic poke(input int unsigned idx, input logic [31:0] w);
    @(negedge clk);
    cs_we = 1'b1;
    cs_idx = 5'(idx);
    cs_wdata = w;
    @(posedge clk);
    @(negedge clk);
    cs_we = 1'b0;
  endtask

  task automatic peek(input int unsigned idx, output logic [31:0] w);
    cs_idx = 5'(idx);
    @(negedge clk);
    w = cs_rdata;
  endtask

  task automatic poke64(input int unsigned idx, input logic [63:0] v);
    poke(idx, v[31:0]);
    poke(idx + 1, v[63:32]);
  endtask

  task automatic fire(input apu_eal_req_t r);
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

  function automatic apu_eal_req_t mk_gnh(
      input apu_gnh_op_e op, input apu_gnh_kind_e kind,
      input logic [31:0] oid, input logic [31:0] h);
    mk_gnh = '0;
    mk_gnh.op = APU_EAL_GNH;
    mk_gnh.gnh.op = op;
    mk_gnh.gnh.kind = kind;
    mk_gnh.gnh.object_id = oid;
    mk_gnh.gnh.handle = h;
  endfunction

  function automatic apu_eal_req_t mk_alloc;
    mk_alloc = '0;
    mk_alloc.op = APU_EAL_ALLOC;
  endfunction

  function automatic apu_eal_req_t mk_begin;
    mk_begin = '0;
    mk_begin.op = APU_EAL_BEGIN;
  endfunction

  function automatic apu_eal_req_t mk_end;
    mk_end = '0;
    mk_end.op = APU_EAL_END;
  endfunction

  task automatic load_alloc(input logic [31:0] flags, input logic [63:0] guest);
    integer i;
    for (i = 0; i < APU_VAC_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VAC_CMD_ALLOC);
    poke(1, flags);
    poke64(2, 64'hD1);
    poke64(4, 64'd1);
    poke(6, APU_VAC_STYPE_ALLOC);
    poke64(7, 64'd0);
    poke64(9, 64'hA1);
    poke(11, APU_VAC_LEVEL_PRIMARY);
    poke(12, 32'd1);
    poke64(13, 64'd1);
    poke64(15, guest);
  endtask

  task automatic load_begin(input logic [31:0] flags, input logic [63:0] cmdbuf,
                            input logic [31:0] bflags);
    poke(0, APU_VBG_CMD_BEGIN);
    poke(1, flags);
    poke64(2, cmdbuf);
    poke64(4, 64'd1);
    poke(6, APU_VBG_STYPE_BEGIN);
    poke64(7, 64'd0);
    poke(9, bflags);
    poke64(10, 64'd0);
  endtask

  task automatic load_end(input logic [31:0] flags, input logic [63:0] cmdbuf);
    poke(0, APU_VEN_CMD_END);
    poke(1, flags);
    poke64(2, cmdbuf);
  endtask

  initial begin
    apu_cfg_t cfg;
    logic [31:0] h0, t0, t1, t4;

    do_reset;
    cases++;
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && req_rdy == 1'b1);
    check("profiles keep eal off",
          !ApuOff.EalEn && !ApuP1Transport.EalEn && !ApuHarness.EalEn);
    cfg = ApuP1Transport;
    cfg.EalEn = 1'b1;
    check("eal does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.EalEn = 1'b1;
    check("eal does not legalize virgl", !apu_cfg_legal(cfg));
    check("num capsets stays 0", ApuOff.NumCapsets == 0 &&
          ApuP1Transport.NumCapsets == 0 && ApuHarness.NumCapsets == 0);
    check("mesa ids", APU_VAC_CMD_ALLOC == 32'd88 &&
          APU_VBG_CMD_BEGIN == 32'd90 && APU_VEN_CMD_END == 32'd91);

    cases++;
    load_end(32'd0, 64'hC1);
    fire(mk_end());
    check("end before alloc faults", cpl.status == APU_EAL_FAULT &&
          !rec.valid);
    ack();

    cases++;
    do_reset;
    load_alloc(32'd0, 64'hC1);
    fire(mk_alloc());
    h0 = rec.handle;
    check("alloc cmdbuf", cpl.status == APU_EAL_OK && rec.valid && rec.alloc &&
          !rec.begin_cmd && !rec.end_cmd && rec.kind == APU_GNH_CMDBUF &&
          rec.object_id == 32'hC1 && rec.handle != 32'hC1 && rec.gen != 16'd0);
    ack();
    load_end(32'd0, 64'(h0));
    fire(mk_end());
    check("end before begin faults", cpl.status == APU_EAL_FAULT && !rec.valid);
    ack();

    cases++;
    do_reset;
    load_alloc(32'd0, 64'hC1);
    fire(mk_alloc());
    h0 = rec.handle;
    ack();
    load_begin(32'd0, 64'(h0), 32'd1);
    fire(mk_begin());
    check("begin lookup", cpl.status == APU_EAL_OK && rec.valid &&
          rec.begin_cmd && !rec.alloc && !rec.end_cmd && rec.handle == h0 &&
          rec.kind == APU_GNH_CMDBUF && rec.begin_flags == 32'd1);
    ack();
    load_end(32'd0, 64'(h0));
    fire(mk_end());
    check("end lookup", cpl.status == APU_EAL_OK && rec.valid &&
          rec.end_cmd && !rec.alloc && !rec.begin_cmd && rec.handle == h0 &&
          rec.kind == APU_GNH_CMDBUF);
    ack();

    cases++;
    do_reset;
    load_alloc(APU_VAC_GENERATE_REPLY, 64'hC2);
    fire(mk_alloc());
    h0 = rec.handle;
    check("reply alloc", cpl.status == APU_EAL_OK && rec.valid && rec.reply &&
          rec.object_id == 32'hC2);
    peek(APU_VAC_REPLY, t0);
    peek(APU_VAC_REPLY + 4, t4);
    check("reply type", t0 == 32'd88 && t4 == h0);
    ack();
    load_begin(APU_VBG_GENERATE_REPLY, 64'(h0), 32'd0);
    fire(mk_begin());
    check("reply begin", cpl.status == APU_EAL_OK && rec.valid && rec.reply &&
          rec.begin_cmd && rec.handle == h0);
    peek(APU_VBG_REPLY, t0);
    peek(APU_VBG_REPLY + 1, t1);
    check("begin reply words", t0 == 32'd90 && t1 == 32'd0);
    ack();
    load_end(APU_VEN_GENERATE_REPLY, 64'(h0));
    fire(mk_end());
    check("reply end", cpl.status == APU_EAL_OK && rec.valid && rec.reply &&
          rec.end_cmd && rec.handle == h0);
    peek(APU_VEN_REPLY, t0);
    peek(APU_VEN_REPLY + 1, t1);
    check("end reply words", t0 == 32'd91 && t1 == 32'd0);
    ack();

    cases++;
    load_end(32'd0, 64'(h0));
    fire(mk_end());
    check("second end faults", cpl.status == APU_EAL_FAULT && !rec.valid);
    ack();

    cases++;
    do_reset;
    load_alloc(32'd0, 64'hC2);
    fire(mk_alloc());
    ack();
    load_alloc(32'd0, 64'hC2);
    fire(mk_alloc());
    check("duplicate object faults", cpl.status == APU_EAL_FAULT && !rec.valid);
    ack();

    cases++;
    do_reset;
    load_alloc(32'd0, 64'hC1);
    poke(0, APU_VNENC_CMD_CREATE_SHADER_MODULE);
    fire(mk_alloc());
    check("create module faults", cpl.status == APU_EAL_FAULT);
    ack();

    cases++;
    do_reset;
    fire(mk_gnh(APU_GNH_ALLOC, APU_GNH_MODULE, 32'hB2, 32'd0));
    h0 = rec.handle;
    ack();
    load_end(32'd0, 64'(h0));
    fire(mk_end());
    check("module kind faults", cpl.status == APU_EAL_FAULT && !rec.valid);
    ack();

    cases++;
    do_reset;
    poke(0, 32'd0);
    poke(1, 32'd0);
    poke64(2, 64'hB1);
    poke64(4, 64'd1);
    poke(6, APU_VBG_STYPE_BEGIN);
    poke64(7, 64'd0);
    poke(9, 32'd0);
    poke64(10, 64'd0);
    fire(mk_begin());
    check("instance faults", cpl.status == APU_EAL_FAULT);
    ack();

    if (errors != 0) $fatal(1, "APU eal errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_eal cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
