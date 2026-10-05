// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// HandlePath create/dispatch then SpirvSubset kick. Not pixels.

`timescale 1ns/1ps

module tb_g6lc_apu_hrn;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic cs_we = 0, req_v = 0, req_rdy, cpl_v, cpl_r = 0, irq;
  logic [7:0] cs_idx = 0;
  logic [31:0] cs_wdata = 0, cs_rdata, in_a = 0, in_b = 0, result;
  apu_hrn_req_t req;
  apu_hrn_cpl_t cpl;
  apu_hrn_t rec;
  logic off_rdy, off_v, off_irq;
  apu_hrn_cpl_t off_cpl;
  apu_hrn_t off_rec;
  logic [31:0] off_rdata, off_res;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_hrn #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(cs_rdata),
    .req_valid_i(req_v), .req_ready_o(req_rdy), .req_i(req),
    .in_a_i(in_a), .in_b_i(in_b),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .hrn_o(rec),
    .irq_o(irq), .result_o(result)
  );
  g6lc_apu_hrn_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(off_rdata),
    .req_valid_i(req_v), .req_ready_o(off_rdy), .req_i(req),
    .in_a_i(in_a), .in_b_i(in_b),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .hrn_o(off_rec),
    .irq_o(off_irq), .result_o(off_res)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "hrn timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_rec !== '0 ||
        off_irq !== 1'b0 || off_res !== '0)
      $fatal(1, "disabled hrn active");
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

  task automatic fire(input apu_hrn_req_t r);
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
    in_a = '0; in_b = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  function automatic apu_hrn_req_t mk_gnh(
      input apu_gnh_op_e op, input apu_gnh_kind_e kind,
      input logic [31:0] oid, input logic [31:0] h);
    mk_gnh = '0;
    mk_gnh.op = APU_HRN_GNH;
    mk_gnh.gnh.op = op;
    mk_gnh.gnh.kind = kind;
    mk_gnh.gnh.object_id = oid;
    mk_gnh.gnh.handle = h;
  endfunction

  function automatic apu_hrn_req_t mk_op(input apu_hrn_op_e op);
    mk_op = '0;
    mk_op.op = op;
  endfunction

  function automatic logic [31:0] enc(input int unsigned wc, input int unsigned op);
    return {16'(wc), 16'(op)};
  endfunction

  task automatic fill_alu(input logic [15:0] alu, ref logic [31:0] mem [0:127],
                          output int unsigned n);
    n = 0;
    mem[n++] = APU_SPIRV_MAGIC;
    mem[n++] = 32'h00010000;
    mem[n++] = 32'h0;
    mem[n++] = 32'd13;
    mem[n++] = 32'h0;
    mem[n++] = enc(2, 17); mem[n++] = 32'd1;
    mem[n++] = enc(3, 14); mem[n++] = 32'd0; mem[n++] = 32'd1;
    mem[n++] = enc(5, 15); mem[n++] = 32'd5; mem[n++] = 32'd8;
    mem[n++] = 32'h6E69616D; mem[n++] = 32'h0;
    mem[n++] = enc(4, 71); mem[n++] = 32'd5; mem[n++] = 32'd33; mem[n++] = 32'd0;
    mem[n++] = enc(4, 71); mem[n++] = 32'd6; mem[n++] = 32'd33; mem[n++] = 32'd1;
    mem[n++] = enc(4, 71); mem[n++] = 32'd7; mem[n++] = 32'd33; mem[n++] = 32'd2;
    mem[n++] = enc(2, 19); mem[n++] = 32'd1;
    mem[n++] = enc(4, 21); mem[n++] = 32'd2; mem[n++] = 32'd32; mem[n++] = 32'd0;
    mem[n++] = enc(4, 32); mem[n++] = 32'd3; mem[n++] = 32'd12; mem[n++] = 32'd2;
    mem[n++] = enc(3, 33); mem[n++] = 32'd4; mem[n++] = 32'd1;
    mem[n++] = enc(4, 59); mem[n++] = 32'd3; mem[n++] = 32'd5; mem[n++] = 32'd12;
    mem[n++] = enc(4, 59); mem[n++] = 32'd3; mem[n++] = 32'd6; mem[n++] = 32'd12;
    mem[n++] = enc(4, 59); mem[n++] = 32'd3; mem[n++] = 32'd7; mem[n++] = 32'd12;
    mem[n++] = enc(5, 54); mem[n++] = 32'd1; mem[n++] = 32'd8; mem[n++] = 32'd0;
    mem[n++] = 32'd4;
    mem[n++] = enc(2, 248); mem[n++] = 32'd9;
    mem[n++] = enc(4, 61); mem[n++] = 32'd2; mem[n++] = 32'd10; mem[n++] = 32'd5;
    mem[n++] = enc(4, 61); mem[n++] = 32'd2; mem[n++] = 32'd11; mem[n++] = 32'd6;
    mem[n++] = enc(5, alu); mem[n++] = 32'd2; mem[n++] = 32'd12; mem[n++] = 32'd10;
    mem[n++] = 32'd11;
    mem[n++] = enc(3, 62); mem[n++] = 32'd7; mem[n++] = 32'd12;
    mem[n++] = enc(1, 253);
    mem[n++] = enc(1, 56);
  endtask

  task automatic load_create(input logic [31:0] mem [0:127], input int unsigned n,
                             input logic [63:0] module_id);
    int unsigned i;
    poke(0, APU_VNENC_CMD_CREATE_SHADER_MODULE);
    poke(1, 32'd0);
    poke64(2, 64'hA1);
    poke64(4, 64'd1);
    poke(6, APU_VNENC_STYPE_SHADER_MODULE);
    poke64(7, 64'd0);
    poke(9, 32'd0);
    poke64(10, 64'(n * 4));
    poke64(12, 64'(n));
    for (i = 0; i < n; i++) poke(APU_VNENC_CODE0 + i, mem[i]);
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
    logic [31:0] mem [0:127];
    logic [31:0] hc;
    int unsigned n;

    do_reset;
    cases++;
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && req_rdy == 1'b1);
    check("profiles keep hrn off",
          !ApuOff.HrnEn && !ApuP1Transport.HrnEn && !ApuHarness.HrnEn);
    cfg = ApuP1Transport;
    cfg.HrnEn = 1'b1;
    check("hrn does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.HrnEn = 1'b1;
    check("hrn does not legalize virgl", !apu_cfg_legal(cfg));

    cases++;
    fill_alu(16'd128, mem, n);
    load_create(mem, n, 64'hB2);
    fire(mk_op(APU_HRN_CREATE));
    check("create module", cpl.status == APU_HRN_OK && rec.valid && rec.create &&
          rec.loaded && rec.kind == APU_GNH_MODULE && rec.object_id == 32'hB2 &&
          !rec.dispatch && !irq);
    ack();
    fire(mk_gnh(APU_GNH_ALLOC, APU_GNH_CMDBUF, 32'd1, 32'd0));
    hc = rec.handle;
    check("alloc cmdbuf", cpl.status == APU_HRN_OK && rec.kind == APU_GNH_CMDBUF);
    ack();
    load_dispatch(64'(hc), 32'd1, 32'd1, 32'd1);
    in_a = 32'd2;
    in_b = 32'd3;
    fire(mk_op(APU_HRN_DISPATCH));
    check("dispatch add", cpl.status == APU_HRN_OK && rec.valid && rec.dispatch &&
          irq && result == 32'd5 && rec.result == 32'd5 && rec.loaded);
    ack();

    cases++;
    in_a = 32'd4;
    in_b = 32'd5;
    fire(mk_op(APU_HRN_DISPATCH));
    check("second dispatch", cpl.status == APU_HRN_OK && rec.valid && irq &&
          result == 32'd9);
    ack();

    cases++;
    do_reset;
    load_dispatch(64'hB1, 32'd1, 32'd1, 32'd1);
    in_a = 32'd2;
    in_b = 32'd3;
    fire(mk_op(APU_HRN_DISPATCH));
    check("dispatch before create faults", cpl.status == APU_HRN_FAULT && !irq);
    ack();

    cases++;
    fill_alu(16'd128, mem, n);
    load_create(mem, n, 64'hB2);
    fire(mk_op(APU_HRN_CREATE));
    ack();
    load_dispatch(64'(rec.handle), 32'd1, 32'd1, 32'd1);
    fire(mk_op(APU_HRN_DISPATCH));
    check("module as cmdbuf faults", cpl.status == APU_HRN_FAULT);
    ack();

    cases++;
    do_reset;
    poke(0, 32'd0);
    poke(1, 32'd0);
    poke64(2, 64'hA1);
    poke64(4, 64'd1);
    poke(6, APU_VNENC_STYPE_SHADER_MODULE);
    fire(mk_op(APU_HRN_CREATE));
    check("instance faults", cpl.status == APU_HRN_FAULT);
    ack();

    if (errors != 0) $fatal(1, "APU hrn errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_hrn cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
