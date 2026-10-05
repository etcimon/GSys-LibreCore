// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps
module tb_g6lc_apu_vns;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;
  logic clk = 0, rst_ni = 0, cs_we = 0, req_v = 0, req_rdy, cpl_v, cpl_r = 0;
  logic [3:0] cs_idx = 0; logic [31:0] cs_wdata = 0, cs_rdata;
  apu_vns_cpl_t cpl; apu_vns_t rec;
  logic off_rdy, off_v; apu_vns_cpl_t off_cpl; apu_vns_t off_rec; logic [31:0] off_rdata;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  g6lc_apu_vns #(.Enable(1'b1)) i_on (.clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(cs_rdata), .req_valid_i(req_v), .req_ready_o(req_rdy),
    .cpl_valid_o(cpl_v), .cpl_ready_i(cpl_r), .cpl_o(cpl), .vns_o(rec));
  g6lc_apu_vns_fixture #(.Enable(1'b0)) i_off (.clk_i(clk), .rst_ni, .cs_we_i(cs_we), .cs_idx_i(cs_idx),
    .cs_wdata_i(cs_wdata), .cs_rdata_o(off_rdata), .req_valid_i(req_v), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(cpl_r), .cpl_o(off_cpl), .vns_o(off_rec));
  always #5 clk = ~clk; always @(posedge clk) cycles++;
  initial begin #200000; $fatal(1, "vns timeout"); end
  always @(negedge clk) if (off_rdy !== 1'b0 || off_v !== 1'b0 || off_rec !== '0)
    $fatal(1, "disabled vns active");
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
  task automatic load_vns(input logic [31:0] flags, input logic [63:0] cbuf);
    integer i; for (i = 0; i < APU_VNS_WORDS; i++) poke(i, 32'd0);
    poke(0, APU_VNS_CMD_NEXTSP); poke(1, flags); poke64(2, cbuf);
    poke(4, APU_VRB_INLINE);
  endtask
  initial begin
    apu_cfg_t cfg; logic [31:0] t0, t1;
    do_reset; cases++;
    check("off", off_rdy == 1'b0 && req_rdy == 1'b1);
    check("profiles", !ApuOff.VnsEn && !ApuHarness.VnsEn);
    cfg = ApuP1Transport; cfg.VnsEn = 1'b1;
    check("no virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant; cfg.VnsEn = 1'b1;
    check("no legalize", !apu_cfg_legal(cfg));
    check("id", APU_VNS_CMD_NEXTSP == 32'd134 && APU_VRB_INLINE == 32'd0);
    check("capsets", ApuOff.NumCapsets == 0);
    cases++; load_vns(32'd0, 64'hC1); fire();
    check("ok", cpl.status == APU_VNS_OK && rec.valid && rec.cbuf == 64'hC1 && rec.contents == 32'd0); ack();
    cases++; do_reset; load_vns(APU_VNS_GENERATE_REPLY, 64'hC2); fire();
    peek(APU_VNS_REPLY, t0); peek(APU_VNS_REPLY+1, t1);
    check("reply", rec.reply && t0 == 32'd134 && t1 == 32'd0); ack();
    cases++; do_reset; load_vns(32'd0, 64'hC1); poke(0, 32'd135); fire();
    check("endrp cmd faults", cpl.status == APU_VNS_FAULT); ack();
    cases++; do_reset; load_vns(32'd0, 64'd0); fire();
    check("null cbuf", cpl.status == APU_VNS_FAULT); ack();
    cases++; do_reset; load_vns(32'd0, 64'hC1); poke(4, 32'd1); fire();
    check("secondary faults", cpl.status == APU_VNS_FAULT); ack();
    cases++; do_reset; load_vns(32'd0, 64'hC1); poke(3, 32'd1); fire();
    check("high cbuf", cpl.status == APU_VNS_FAULT); ack();
    if (errors != 0) $fatal(1, "vns errors=%0d", errors);
    $display("PASS tb_g6lc_apu_vns cases=%0d checks=%0d cycles=%0d errors=0", cases, checks, cycles);
    $finish;
  end
endmodule
