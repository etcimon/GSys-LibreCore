// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module tb_g6lc_apu_vip;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  logic clk = 0, rst_ni = 0, cs_we = 0, req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  logic [3:0] cs_idx = 0; logic [31:0] cs_wdata = 0, cs_rdata;
  apu_vip_cpl_t cpl; apu_vip_t rec;
  logic off_rdy, off_v; apu_vip_cpl_t off_cpl; apu_vip_t off_rec; logic [31:0] off_rdata;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  g6lc_apu_vip #(.Enable(1'b1)) i_on (.clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(cs_rdata), .req_valid_i(req_v), .req_ready_o(req_rdy),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .vip_o(rec));
  g6lc_apu_vip_fixture #(.Enable(1'b0)) i_off (.clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(off_rdata), .req_valid_i(req_v), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .vip_o(off_rec));
  always #5 clk = ~clk; always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "vip timeout"); end
  always @(negedge clk) if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_rec !== '0)
    $fatal(1, "disabled vip active");
  task automatic check(input string name, input logic ok);
    checks++; if (ok !== 1'b1) begin errors++; $display("FAIL %s", name); end
  endtask
  task automatic poke(input int unsigned idx, input logic [31:0] w);
    @(negedge clk); cs_we = 1'b1; cs_idx = 4'(idx); cs_wdata = w; @(posedge clk); @(negedge clk); cs_we = 1'b0;
  endtask
  task automatic peek(input int unsigned idx, output logic [31:0] w);
    cs_idx = 4'(idx); @(negedge clk); w = cs_rdata;
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
  task automatic load_vip(input logic [31:0] flags, input logic [63:0] phys);
    integer i; for (i = 0; i < APU_IFP_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_IFP_CMD_IFP); poke(1, flags); poke64(2, phys);
    poke(4, APU_GFP_FORMAT); poke(5, APU_IFP_TYPE_2D);
    poke(6, APU_IFP_TILING_LINEAR); poke(7, APU_IFP_USAGE_STORAGE);
    poke(8, 32'd0); poke64(9, 64'd1);
  endtask
  initial begin
    apu_cfg_t cfg; logic [31:0] t0, t1;
    do_reset; cases++;
    check("off", off_rdy == 1'b0 && req_rdy == 1'b1);
    check("profiles", !ApuOff.VipEn && !ApuHarness.VipEn);
    cfg = ApuP1Transport; cfg.VipEn = 1'b1;
    check("no virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant; cfg.VipEn = 1'b1;
    check("no legalize", !apu_cfg_legal(cfg));
    check("id", APU_IFP_CMD_IFP == 32'd5);
    check("capsets", ApuOff.NumCapsets == 0);
    cases++; load_vip(32'd0, 64'hB1); fire();
    check("ok", cpl.status == APU_IFP_OK && rec.valid && rec.phys_handle == 64'hB1); ack();
    cases++; do_reset; load_vip(APU_IFP_GENERATE_REPLY, 64'hB2); fire();
    peek(APU_IFP_REPLY, t0); peek(APU_IFP_REPLY+1, t1);
    check("reply", rec.reply && t0 == 32'd5 && t1 == 32'd0); ack();
    cases++; do_reset; load_vip(32'd0, 64'hB1); poke(0, 32'd4); fire();
    check("format cmd faults", cpl.status == APU_IFP_FAULT); ack();
    cases++; do_reset; load_vip(32'd0, 64'd0); fire();
    check("null phys", cpl.status == APU_IFP_FAULT); ack();
    cases++; do_reset; load_vip(32'd0, 64'hB1); poke(5, 32'd0); fire();
    check("type", cpl.status == APU_IFP_FAULT); ack();
    cases++; do_reset; load_vip(32'd0, 64'hB1); poke64(9, 64'd0); fire();
    check("null out", cpl.status == APU_IFP_FAULT); ack();
    if (errors != 0) $fatal(1, "vip errors=%0d", errors);
    $display("PASS tb_g6lc_apu_vip cases=%0d checks=%0d cycles=%0d errors=0", cases, checks, cycles);
    $finish;
  end
endmodule
