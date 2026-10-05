// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Mesa vn_protocol vkAllocateCommandBuffers ALLOC CMDBUF. NumCapsets
// stays 0. Not pixels.

`timescale 1ns/1ps

module tb_g6lc_apu_vac;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic cs_we = 0, req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  logic [4:0] cs_idx = 0;
  logic [31:0] cs_wdata = 0, cs_rdata;
  apu_vac_cpl_t cpl;
  apu_vac_t rec;
  logic off_rdy, off_v;
  apu_vac_cpl_t off_cpl;
  apu_vac_t off_rec;
  logic [31:0] off_rdata;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_vac #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(cs_rdata),
    .req_valid_i(req_v), .req_ready_o(req_rdy),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .vac_o(rec)
  );
  g6lc_apu_vac_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(off_rdata),
    .req_valid_i(req_v), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .vac_o(off_rec)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "vac timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_rec !== '0 || off_cpl !== '0)
      $fatal(1, "disabled vac active");
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

  task automatic load_alloc(input logic [31:0] flags, input logic [63:0] pool,
                            input logic [31:0] level, input logic [31:0] n,
                            input logic [63:0] guest);
    integer i;
    for (i = 0; i < APU_VAC_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VAC_CMD_ALLOC);
    poke(1, flags);
    poke64(2, 64'h0000_0000_0000_00D1);
    poke64(4, 64'd1);
    poke(6, APU_VAC_STYPE_ALLOC);
    poke64(7, 64'd0);
    poke64(9, pool);
    poke(11, level);
    poke(12, n);
    poke64(13, {32'd0, n});
    poke64(15, guest);
  endtask

  initial begin
    apu_cfg_t cfg;
    logic [31:0] t0, t1, t4, pub;

    do_reset;
    cases++;
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && req_rdy == 1'b1);
    check("profiles keep vac off",
          !ApuOff.VacEn && !ApuP1Transport.VacEn && !ApuHarness.VacEn);
    cfg = ApuP1Transport;
    cfg.VacEn = 1'b1;
    check("vac does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.VacEn = 1'b1;
    check("vac does not legalize virgl", !apu_cfg_legal(cfg));
    check("num capsets stays 0", ApuOff.NumCapsets == 0 &&
          ApuP1Transport.NumCapsets == 0 && ApuHarness.NumCapsets == 0);
    check("mesa alloc id", APU_VAC_CMD_ALLOC == 32'd88 &&
          APU_VAC_STYPE_ALLOC == 32'd40 &&
          APU_VNENC_CMD_CREATE_SHADER_MODULE == 32'd59 &&
          APU_VND_CMD_DISPATCH == 32'd110);

    cases++;
    load_alloc(32'd0, 64'hA1, APU_VAC_LEVEL_PRIMARY, 32'd1, 64'hC1);
    fire();
    pub = rec.handle;
    check("alloc ok", cpl.status == APU_VAC_OK && rec.valid &&
          rec.cmd_type == 32'd88 && rec.object_id == 32'hC1 &&
          rec.pool == 64'hA1 && rec.count == 32'd1 &&
          rec.kind == APU_GNH_CMDBUF && rec.handle != 32'hC1 &&
          rec.handle[2:0] == rec.slot && rec.gen != 16'd0 && !rec.reply);
    ack();

    cases++;
    do_reset;
    load_alloc(APU_VAC_GENERATE_REPLY, 64'hA1, APU_VAC_LEVEL_PRIMARY, 32'd1,
               64'hC2);
    fire();
    check("reply alloc", cpl.status == APU_VAC_OK && rec.valid && rec.reply &&
          rec.object_id == 32'hC2 && rec.handle != 32'd0);
    peek(APU_VAC_REPLY, t0);
    peek(APU_VAC_REPLY + 1, t1);
    peek(APU_VAC_REPLY + 4, t4);
    check("reply type", t0 == 32'd88 && t1 == 32'd0 && t4 == rec.handle);
    ack();

    cases++;
    load_alloc(32'd0, 64'hA1, APU_VAC_LEVEL_PRIMARY, 32'd1, 64'hC2);
    fire();
    check("duplicate object faults", cpl.status == APU_VAC_FAULT && !rec.valid);
    ack();

    cases++;
    do_reset;
    load_alloc(32'd0, 64'hA1, APU_VAC_LEVEL_PRIMARY, 32'd1, 64'hC1);
    poke(0, APU_VNENC_CMD_CREATE_SHADER_MODULE);
    fire();
    check("create module faults", cpl.status == APU_VAC_FAULT && !rec.valid);
    ack();

    cases++;
    do_reset;
    load_alloc(32'd0, 64'hA1, APU_VAC_LEVEL_PRIMARY, 32'd1, 64'hC1);
    poke(0, 32'd0);
    fire();
    check("instance faults", cpl.status == APU_VAC_FAULT);
    ack();

    cases++;
    do_reset;
    load_alloc(32'd0, 64'hA1, APU_VAC_LEVEL_PRIMARY, 32'd1, 64'hC1);
    poke(0, APU_VND_CMD_DISPATCH);
    fire();
    check("dispatch faults", cpl.status == APU_VAC_FAULT);
    ack();

    cases++;
    do_reset;
    load_alloc(32'd0, 64'hA1, APU_VAC_LEVEL_PRIMARY, 32'd2, 64'hC1);
    fire();
    check("count two faults", cpl.status == APU_VAC_FAULT);
    ack();

    cases++;
    do_reset;
    load_alloc(32'd0, 64'hA1, APU_VAC_LEVEL_SECONDARY, 32'd1, 64'hC1);
    fire();
    check("secondary faults", cpl.status == APU_VAC_FAULT);
    ack();

    cases++;
    do_reset;
    load_alloc(32'd0, 64'hA1, APU_VAC_LEVEL_PRIMARY, 32'd1, 64'hC1);
    poke64(4, 64'd0);
    fire();
    check("null info faults", cpl.status == APU_VAC_FAULT);
    ack();

    cases++;
    do_reset;
    load_alloc(32'd0, 64'hA1, APU_VAC_LEVEL_PRIMARY, 32'd1, 64'd0);
    fire();
    check("zero id faults", cpl.status == APU_VAC_FAULT);
    ack();

    cases++;
    do_reset;
    load_alloc(32'd0, 64'hA1, APU_VAC_LEVEL_PRIMARY, 32'd1,
               64'h0000_0001_0000_00C1);
    fire();
    check("high-half handle faults", cpl.status == APU_VAC_FAULT);
    ack();

    if (errors != 0) $fatal(1, "APU vac errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vac cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
