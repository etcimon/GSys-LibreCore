// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module tb_g6lc_apu_vbl;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  logic clk = 0, rst_ni = 0, cs_we = 0, req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  logic [4:0] cs_idx = 0; logic [31:0] cs_wdata = 0, cs_rdata;
  apu_vbl_cpl_t cpl; apu_vbl_t rec;
  logic off_rdy, off_v; apu_vbl_cpl_t off_cpl; apu_vbl_t off_rec; logic [31:0] off_rdata;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  g6lc_apu_vbl #(.Enable(1'b1)) i_on (.clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(cs_rdata), .req_valid_i(req_v), .req_ready_o(req_rdy),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .vbl_o(rec));
  g6lc_apu_vbl_fixture #(.Enable(1'b0)) i_off (.clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(off_rdata), .req_valid_i(req_v), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .vbl_o(off_rec));
  always #5 clk = ~clk; always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "vbl timeout"); end
  always @(negedge clk) if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_rec !== '0)
    $fatal(1, "disabled vbl active");
  task automatic check(input string name, input logic ok);
    checks++; if (ok !== 1'b1) begin errors++; $display("FAIL %s", name); end
  endtask
  task automatic poke(input int unsigned idx, input logic [31:0] w);
    @(negedge clk); cs_we = 1'b1; cs_idx = 5'(idx); cs_wdata = w; @(posedge clk); @(negedge clk); cs_we = 1'b0;
  endtask
  task automatic peek(input int unsigned idx, output logic [31:0] w);
    cs_idx = 5'(idx); @(negedge clk); w = cs_rdata;
  endtask
  task automatic poke64(input int unsigned idx, input logic [63:0] v);
    poke(idx, v[31:0]); poke(idx+1, v[63:32]);
  endtask
  task automatic fire;
    @(negedge clk); while (!req_rdy) @(negedge clk); req_v = 1'b1; @(posedge clk); @(negedge clk); req_v = 1'b0;
    while (!cpl_v) @(negedge clk);
  endtask
  task automatic ack;
    @(negedge clk); cpl_r = 1'b1; @(posedge clk); while (cpl_v) @(posedge clk); @(negedge clk); cpl_r = 1'b0;
  endtask
  task automatic do_reset;
    cs_we = 1'b0; req_v = 1'b0; cpl_r = 1'b0; @(negedge clk); rst_ni = 1'b0; repeat (3) @(negedge clk); rst_ni = 1'b1; @(posedge clk);
  endtask
  task automatic load_vbl(input logic [31:0] flags, input logic [63:0] cbuf,
                          input logic [63:0] src, input logic [63:0] dst);
    integer i; for (i = 0; i < APU_BLI_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_BLI_CMD_BLI); poke(1, flags); poke64(2, cbuf);
    poke64(4, src); poke64(6, dst);
    poke(8, APU_CCI_SRC_LAYOUT); poke(9, APU_CCI_DST_LAYOUT); poke(10, APU_CCI_COUNT);
    poke(11, APU_CCI_ASPECT); poke(14, 32'd1);
    poke(18, APU_BLI_SRC1_X); poke(19, APU_BLI_SRC1_Y); poke(20, APU_BLI_SRC1_Z);
    poke(21, APU_CCI_ASPECT); poke(24, 32'd1);
    poke(25, APU_BLI_DST0_X); poke(28, APU_BLI_DST1_X);
    poke(29, APU_BLI_DST1_Y); poke(30, APU_BLI_DST1_Z); poke(31, APU_BLI_FILTER);
  endtask
  initial begin
    apu_cfg_t cfg; logic [31:0] t0, t1;
    do_reset; cases++;
    check("off", off_rdy == 1'b0 && req_rdy == 1'b1);
    check("profiles", !ApuOff.VblEn && !ApuHarness.VblEn);
    cfg = ApuP1Transport; cfg.VblEn = 1'b1;
    check("no virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant; cfg.VblEn = 1'b1;
    check("no legalize", !apu_cfg_legal(cfg));
    check("id", APU_BLI_CMD_BLI == 32'd114);
    check("capsets", ApuOff.NumCapsets == 0);
    cases++; load_vbl(32'd0, 64'hC1, 64'hB9, 64'hB9); fire();
    check("ok", cpl.status == APU_BLI_OK && rec.valid && rec.dst == 64'hB9); ack();
    cases++; do_reset; load_vbl(APU_BLI_GENERATE_REPLY, 64'hC2, 64'hB9, 64'hB9); fire();
    peek(APU_BLI_REPLY, t0); peek(APU_BLI_REPLY+1, t1);
    check("reply", rec.reply && t0 == 32'd114 && t1 == 32'd0); ack();
    cases++; do_reset; load_vbl(32'd0, 64'hC1, 64'hB9, 64'hB9); poke(0, 32'd113); fire();
    check("copyimg cmd faults", cpl.status == APU_BLI_FAULT); ack();
    cases++; do_reset; load_vbl(32'd0, 64'd0, 64'hB9, 64'hB9); fire();
    check("null cbuf", cpl.status == APU_BLI_FAULT); ack();
    cases++; do_reset; load_vbl(32'd0, 64'hC1, 64'hB9, 64'hB9); poke(31, 32'd1); fire();
    check("filter", cpl.status == APU_BLI_FAULT); ack();
    cases++; do_reset; load_vbl(32'd0, 64'hC1, 64'hB9, 64'd0); fire();
    check("null dst", cpl.status == APU_BLI_FAULT); ack();
    cases++; do_reset; load_vbl(32'd2, 64'hC1, 64'hB9, 64'hB9); fire();
    check("flags", cpl.status == APU_BLI_FAULT); ack();
    if (errors != 0) $fatal(1, "vbl errors=%0d", errors);
    $display("PASS tb_g6lc_apu_vbl cases=%0d checks=%0d cycles=%0d errors=0", cases, checks, cycles);
    $finish;
  end
endmodule
