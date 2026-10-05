// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// GenHandle lookup of vkCmdDispatch commandBuffer. Not pixels.

`timescale 1ns/1ps

module tb_g6lc_apu_hdp;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic cs_we = 0, req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  logic [3:0] cs_idx = 0;
  logic [31:0] cs_wdata = 0, cs_rdata;
  apu_hdp_req_t req;
  apu_hdp_cpl_t cpl;
  apu_hdp_t rec;
  logic off_rdy, off_v;
  apu_hdp_cpl_t off_cpl;
  apu_hdp_t off_rec;
  logic [31:0] off_rdata;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_hdp #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(cs_rdata),
    .req_valid_i(req_v), .req_ready_o(req_rdy), .req_i(req),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .hdp_o(rec)
  );
  g6lc_apu_hdp_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(off_rdata),
    .req_valid_i(req_v), .req_ready_o(off_rdy), .req_i(req),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .hdp_o(off_rec)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "hdp timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_rec !== '0 || off_cpl !== '0)
      $fatal(1, "disabled hdp active");
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

  task automatic poke64(input int unsigned idx, input logic [63:0] v);
    poke(idx, v[31:0]);
    poke(idx + 1, v[63:32]);
  endtask

  task automatic fire(input apu_hdp_req_t r);
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

  function automatic apu_hdp_req_t mk_gnh(
      input apu_gnh_op_e op, input apu_gnh_kind_e kind,
      input logic [31:0] oid, input logic [31:0] h);
    mk_gnh = '0;
    mk_gnh.dispatch = 1'b0;
    mk_gnh.gnh.op = op;
    mk_gnh.gnh.kind = kind;
    mk_gnh.gnh.object_id = oid;
    mk_gnh.gnh.handle = h;
  endfunction

  function automatic apu_hdp_req_t mk_disp;
    mk_disp = '0;
    mk_disp.dispatch = 1'b1;
  endfunction

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
    logic [31:0] h0;

    do_reset;
    cases++;
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && req_rdy == 1'b1);
    check("profiles keep hdp off",
          !ApuOff.HdpEn && !ApuP1Transport.HdpEn && !ApuHarness.HdpEn);
    cfg = ApuP1Transport;
    cfg.HdpEn = 1'b1;
    check("hdp does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.HdpEn = 1'b1;
    check("hdp does not legalize virgl", !apu_cfg_legal(cfg));

    cases++;
    fire(mk_gnh(APU_GNH_ALLOC, APU_GNH_CMDBUF, 32'd1, 32'd0));
    h0 = rec.handle;
    check("alloc cmdbuf", cpl.status == APU_HDP_OK && rec.valid &&
          rec.kind == APU_GNH_CMDBUF && rec.object_id == 32'd1 && !rec.dispatch);
    ack();
    load_dispatch(64'(h0), 32'd2, 32'd3, 32'd4);
    fire(mk_disp());
    check("dispatch ok", cpl.status == APU_HDP_OK && rec.valid && rec.dispatch &&
          rec.handle == h0 && rec.kind == APU_GNH_CMDBUF &&
          rec.group_x == 32'd2 && rec.group_y == 32'd3 && rec.group_z == 32'd4);
    ack();

    cases++;
    load_dispatch(64'h0000_0000_0000_00B1, 32'd1, 32'd1, 32'd1);
    fire(mk_disp());
    check("unknown handle faults", cpl.status == APU_HDP_FAULT && !rec.valid);
    ack();

    cases++;
    fire(mk_gnh(APU_GNH_RETIRE, APU_GNH_CMDBUF, 32'd0, h0));
    check("retire", cpl.status == APU_HDP_OK && !rec.valid);
    ack();
    load_dispatch(64'(h0), 32'd2, 32'd3, 32'd4);
    fire(mk_disp());
    check("retired handle faults", cpl.status == APU_HDP_FAULT);
    ack();

    cases++;
    do_reset;
    fire(mk_gnh(APU_GNH_ALLOC, APU_GNH_MODULE, 32'hB2, 32'd0));
    h0 = rec.handle;
    ack();
    load_dispatch(64'(h0), 32'd1, 32'd1, 32'd1);
    fire(mk_disp());
    check("module kind faults", cpl.status == APU_HDP_FAULT && !rec.valid);
    ack();

    cases++;
    do_reset;
    poke(0, 32'd0);
    poke(1, 32'd0);
    poke64(2, 64'hB1);
    poke(4, 32'd1);
    poke(5, 32'd1);
    poke(6, 32'd1);
    fire(mk_disp());
    check("instance faults", cpl.status == APU_HDP_FAULT);
    ack();

    if (errors != 0) $fatal(1, "APU hdp errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_hdp cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
