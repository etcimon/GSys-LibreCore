// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module tb_g6lc_apu_vcy;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  logic clk = 0, rst_ni = 0, cs_we = 0, req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  logic [4:0] cs_idx = 0; logic [31:0] cs_wdata = 0, cs_rdata;
  apu_vcy_cpl_t cpl; apu_vcy_t rec;
  logic off_rdy, off_v; apu_vcy_cpl_t off_cpl; apu_vcy_t off_rec; logic [31:0] off_rdata;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  g6lc_apu_vcy #(.Enable(1'b1)) i_on (.clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(cs_rdata), .req_valid_i(req_v), .req_ready_o(req_rdy),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .vcy_o(rec));
  g6lc_apu_vcy_fixture #(.Enable(1'b0)) i_off (.clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(off_rdata), .req_valid_i(req_v), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .vcy_o(off_rec));
  always #5 clk = ~clk; always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "vcy timeout"); end
  always @(negedge clk) if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_rec !== '0)
    $fatal(1, "disabled vcy active");
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
  task automatic load_vcy(input logic [31:0] flags, input logic [63:0] cbuf,
                          input logic [63:0] src, input logic [63:0] dst);
    integer i; for (i = 0; i < APU_CCI_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_CCI_CMD_CCI); poke(1, flags); poke64(2, cbuf);
    poke64(4, src); poke64(6, dst);
    poke(8, APU_CCI_SRC_LAYOUT); poke(9, APU_CCI_DST_LAYOUT); poke(10, APU_CCI_COUNT);
    poke(11, APU_CCI_ASPECT); poke(14, 32'd1);
    poke(18, APU_CCI_ASPECT); poke(21, 32'd1); poke(22, APU_CCI_DST_X);
    poke(25, APU_CCI_EXT_W); poke(26, APU_CCI_EXT_H); poke(27, APU_CCI_EXT_D);
  endtask
  initial begin
    apu_cfg_t cfg; logic [31:0] t0, t1;
    do_reset; cases++;
    check("off", off_rdy == 1'b0 && req_rdy == 1'b1);
    check("profiles", !ApuOff.VcyEn && !ApuHarness.VcyEn);
    cfg = ApuP1Transport; cfg.VcyEn = 1'b1;
    check("no virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant; cfg.VcyEn = 1'b1;
    check("no legalize", !apu_cfg_legal(cfg));
    check("id", APU_CCI_CMD_CCI == 32'd113);
    check("capsets", ApuOff.NumCapsets == 0);
    cases++; load_vcy(32'd0, 64'hC1, 64'hB9, 64'hB9); fire();
    check("ok", cpl.status == APU_CCI_OK && rec.valid && rec.src == 64'hB9); ack();
    cases++; do_reset; load_vcy(APU_CCI_GENERATE_REPLY, 64'hC2, 64'hB9, 64'hB9); fire();
    peek(APU_CCI_REPLY, t0); peek(APU_CCI_REPLY+1, t1);
    check("reply", rec.reply && t0 == 32'd113 && t1 == 32'd0); ack();
    cases++; do_reset; load_vcy(32'd0, 64'hC1, 64'hB9, 64'hB9); poke(0, 32'd112); fire();
    check("copybuf cmd faults", cpl.status == APU_CCI_FAULT); ack();
    cases++; do_reset; load_vcy(32'd0, 64'd0, 64'hB9, 64'hB9); fire();
    check("null cbuf", cpl.status == APU_CCI_FAULT); ack();
    cases++; do_reset; load_vcy(32'd0, 64'hC1, 64'hB9, 64'hB9); poke(22, 32'd0); fire();
    check("dst x", cpl.status == APU_CCI_FAULT); ack();
    cases++; do_reset; load_vcy(32'd0, 64'hC1, 64'hB9, 64'hB9); poke(8, 32'd1); fire();
    check("layout", cpl.status == APU_CCI_FAULT); ack();
    cases++; do_reset; load_vcy(32'd2, 64'hC1, 64'hB9, 64'hB9); fire();
    check("flags", cpl.status == APU_CCI_FAULT); ack();
    if (errors != 0) $fatal(1, "vcy errors=%0d", errors);
    $display("PASS tb_g6lc_apu_vcy cases=%0d checks=%0d cycles=%0d errors=0", cases, checks, cycles);
    $finish;
  end
endmodule
