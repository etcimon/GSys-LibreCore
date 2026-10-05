// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module tb_g6lc_apu_vsi;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  logic clk = 0, rst_ni = 0, cs_we = 0, req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  logic [3:0] cs_idx = 0; logic [31:0] cs_wdata = 0, cs_rdata;
  apu_vsi_cpl_t cpl; apu_vsi_t rec;
  logic off_rdy, off_v; apu_vsi_cpl_t off_cpl; apu_vsi_t off_rec; logic [31:0] off_rdata;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  g6lc_apu_vsi #(.Enable(1'b1)) i_on (.clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(cs_rdata), .req_valid_i(req_v), .req_ready_o(req_rdy),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .vsi_o(rec));
  g6lc_apu_vsi_fixture #(.Enable(1'b0)) i_off (.clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(off_rdata), .req_valid_i(req_v), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .vsi_o(off_rec));
  always #5 clk = ~clk; always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "vsi timeout"); end
  always @(negedge clk) if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_rec !== '0)
    $fatal(1, "disabled vsi active");
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
  task automatic load_vsi(input logic [31:0] flags, input logic [63:0] cbuf);
    integer i; for (i = 0; i < APU_VSI_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VSI_CMD_SETSC); poke(1, flags); poke64(2, cbuf);
    poke(4, 32'd0); poke(5, 32'd1); poke64(6, 64'd1);
    poke(8, 32'd0); poke(9, 32'd0); poke(10, APU_VXI_WIDTH); poke(11, APU_VXI_HEIGHT);
  endtask
  initial begin
    apu_cfg_t cfg; logic [31:0] t0, t1;
    do_reset; cases++;
    check("off", off_rdy == 1'b0 && req_rdy == 1'b1);
    check("profiles", !ApuOff.VsiEn && !ApuHarness.VsiEn);
    cfg = ApuP1Transport; cfg.VsiEn = 1'b1;
    check("no virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant; cfg.VsiEn = 1'b1;
    check("no legalize", !apu_cfg_legal(cfg));
    check("id", APU_VSI_CMD_SETSC == 32'd95 && APU_VXI_WIDTH == 32'd64);
    check("capsets", ApuOff.NumCapsets == 0);
    cases++; load_vsi(32'd0, 64'hC1); fire();
    check("ok", cpl.status == APU_VSI_OK && rec.valid && rec.cbuf == 64'hC1 && rec.width == 32'd64); ack();
    cases++; do_reset; load_vsi(APU_VSI_GENERATE_REPLY, 64'hC2); fire();
    peek(APU_VSI_REPLY, t0); peek(APU_VSI_REPLY+1, t1);
    check("reply", rec.reply && t0 == 32'd95 && t1 == 32'd0); ack();
    cases++; do_reset; load_vsi(32'd0, 64'hC1); poke(0, 32'd94); fire();
    check("viewport cmd faults", cpl.status == APU_VSI_FAULT); ack();
    cases++; do_reset; load_vsi(32'd0, 64'd0); fire();
    check("null cbuf", cpl.status == APU_VSI_FAULT); ack();
    cases++; do_reset; load_vsi(32'd0, 64'hC1); poke(5, 32'd0); fire();
    check("zero count", cpl.status == APU_VSI_FAULT); ack();
    cases++; do_reset; load_vsi(32'd0, 64'hC1); poke(10, 32'd0); fire();
    check("zero width", cpl.status == APU_VSI_FAULT); ack();
    if (errors != 0) $fatal(1, "vsi errors=%0d", errors);
    $display("PASS tb_g6lc_apu_vsi cases=%0d checks=%0d cycles=%0d errors=0", cases, checks, cycles);
    $finish;
  end
endmodule
