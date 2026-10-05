// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Mesa vn_protocol vkInvalidateMappedMemoryRanges CS.
// Stock encode; not pixels.

`timescale 1ns/1ps

module tb_g6lc_apu_vim;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  logic cs_we = 0, req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  logic [4:0] cs_idx = 0;
  logic [31:0] cs_wdata = 0, cs_rdata;
  apu_vim_cpl_t cpl;
  apu_vim_t rec;
  logic off_rdy, off_v;
  apu_vim_cpl_t off_cpl;
  apu_vim_t off_rec;
  logic [31:0] off_rdata;
  int errors = 0, checks = 0, cycles = 0, cases = 0;

  g6lc_apu_vim #(.Enable(1'b1)) i_on (
    .clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(cs_rdata),
    .req_valid_i(req_v), .req_ready_o(req_rdy),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .vim_o(rec)
  );
  g6lc_apu_vim_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(off_rdata),
    .req_valid_i(req_v), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .vim_o(off_rec)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "vim timeout case=%0d", cases); end
  always @(negedge clk) begin
    if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_rec !== '0 || off_cpl !== '0)
      $fatal(1, "disabled vim active");
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

  task automatic load_inval(input logic [31:0] flags, input logic [63:0] dev,
                            input logic [63:0] memh);
    integer i;
    for (i = 0; i < APU_VIM_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VIM_CMD_INVAL);
    poke(1, flags);
    poke64(2, dev);
    poke(4, 32'd1);
    poke64(5, 64'd1);
    poke(7, APU_VIM_STYPE_RANGE);
    poke64(8, 64'd0);
    poke64(10, memh);
    poke64(12, 64'd0);
    poke64(14, 64'd4096);
  endtask

  initial begin
    apu_cfg_t cfg;
    logic [31:0] t0, t1;

    do_reset;
    cases++;
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && req_rdy == 1'b1);
    check("profiles keep vim off",
          !ApuOff.VimEn && !ApuP1Transport.VimEn && !ApuHarness.VimEn);
    cfg = ApuP1Transport;
    cfg.VimEn = 1'b1;
    check("vim does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.VimEn = 1'b1;
    check("vim does not legalize virgl", !apu_cfg_legal(cfg));
    check("mesa inval id", APU_VIM_CMD_INVAL == 32'd26 &&
          APU_VIM_STYPE_RANGE == 32'd6 &&
          APU_VFM_CMD_FLUSH == 32'd25);
    check("num capsets stays 0", ApuOff.NumCapsets == 0 &&
          ApuP1Transport.NumCapsets == 0 && ApuHarness.NumCapsets == 0);

    cases++;
    load_inval(32'd0, 64'hD1, 64'hB1);
    fire();
    check("inval ok", cpl.status == APU_VIM_OK && rec.valid &&
          rec.cmd_type == 32'd26 && rec.device == 64'hD1 &&
          rec.memory == 64'hB1 && !rec.reply);
    ack();

    cases++;
    do_reset;
    load_inval(APU_VIM_GENERATE_REPLY, 64'hD2, 64'hB1);
    fire();
    check("reply inval", cpl.status == APU_VIM_OK && rec.valid && rec.reply);
    peek(APU_VIM_REPLY, t0);
    peek(APU_VIM_REPLY + 1, t1);
    check("reply type", t0 == 32'd26 && t1 == 32'd0);
    ack();

    cases++;
    do_reset;
    load_inval(32'd0, 64'hD1, 64'hB1);
    poke(0, APU_VFM_CMD_FLUSH);
    fire();
    check("flush cmd faults", cpl.status == APU_VIM_FAULT && !rec.valid);
    ack();

    cases++;
    do_reset;
    load_inval(32'd0, 64'd0, 64'hB1);
    fire();
    check("null device faults", cpl.status == APU_VIM_FAULT);
    ack();

    cases++;
    do_reset;
    load_inval(32'd0, 64'hD1, 64'd0);
    fire();
    check("null memory faults", cpl.status == APU_VIM_FAULT);
    ack();

    cases++;
    do_reset;
    load_inval(32'd0, 64'hD1, 64'hB1);
    poke(4, 32'd0);
    fire();
    check("zero count faults", cpl.status == APU_VIM_FAULT);
    ack();

    cases++;
    do_reset;
    load_inval(32'd0, 64'hD1, 64'hB1);
    poke64(12, 64'd16);
    fire();
    check("nonzero offset faults", cpl.status == APU_VIM_FAULT);
    ack();

    if (errors != 0) $fatal(1, "APU vim errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vim cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
