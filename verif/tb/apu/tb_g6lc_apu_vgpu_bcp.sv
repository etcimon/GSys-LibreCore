// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_bcp;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_sxf_t sxf;
  apu_vgpu_sbk_t sbk;
  logic bcp_req = 0, bcp_rdy, bcp_cpl_v, bcp_cpl_r = 0;
  apu_vgpu_bcp_cpl_t bcp_cpl;
  apu_vgpu_bcp_t bcp;
  logic rd_v, rd_rdy, rsp_v = 0, rsp_rdy, rsp_ok = 0;
  logic arm_count = 0;
  logic [63:0] rd_addr, rsp_addr = 0;
  logic [31:0] rd_len, rsp_len = 0;
  logic [255:0] rsp_data = 0;
  logic bcr_req = 0, bcr_rdy, bcr_cpl_v, bcr_cpl_r = 0;
  apu_vgpu_bcr_cpl_t bcr_cpl, off_cpl;
  logic off_rdy, off_v;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  int unsigned beats_seen;
  logic fail_next;
  logic [63:0] last_addr;

  localparam logic [31:0] StandIn = 32'h8800_F000;
  localparam logic [31:0] Word0 = 32'hA500_0000;

  g6lc_apu_vgpu_bcp #(.Enable(1'b1)) i_bcp (
    .clk_i(clk), .rst_ni, .sxf_i(sxf), .sbk_i(sbk),
    .req_valid_i(bcp_req), .req_ready_o(bcp_rdy),
    .cpl_valid_o(bcp_cpl_v), .cpl_ready_i(bcp_cpl_r), .cpl_o(bcp_cpl), .bcp_o(bcp),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rsp_v), .rd_rsp_ready_o(rsp_rdy), .rd_rsp_ok_i(rsp_ok),
    .rd_rsp_addr_i(rsp_addr), .rd_rsp_len_i(rsp_len), .rd_rsp_data_i(rsp_data)
  );
  g6lc_apu_vgpu_bcr #(.Enable(1'b1)) i_bcr (
    .clk_i(clk), .rst_ni, .bcp_i(bcp), .sxf_i(sxf),
    .req_valid_i(bcr_req), .req_ready_o(bcr_rdy),
    .cpl_valid_o(bcr_cpl_v), .cpl_ready_i(bcr_cpl_r), .cpl_o(bcr_cpl)
  );
  g6lc_apu_vgpu_bcr_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .bcp_i(bcp), .sxf_i(sxf),
    .req_valid_i(bcr_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(bcr_cpl_r), .cpl_o(off_cpl)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu bcp timeout case=%0d beats=%0d", cases, beats_seen); end

  task automatic check(input string name, input logic cond);
    checks++;
    if (!cond) begin
      errors++;
      $display("FAIL %s", name);
    end
  endtask

  function automatic logic [31:0] pat(input logic [12:0] beat);
    pat = Word0 ^ {19'b0, beat};
  endfunction

  task automatic good_sxf;
    sxf = '0;
    sxf.valid = 1'b1;
    sxf.copied = 1'b0;
    sxf.width = APU_VGPU_SCAN_W;
    sxf.height = APU_VGPU_SCAN_BAND;
    sxf.word = APU_VGPU_CLEAR_WORD;
  endtask

  task automatic good_sbk;
    sbk = '0;
    sbk.valid = 1'b1;
    sbk.resource_id = APU_VIRGL_RES_SCAN;
    sbk.addr = StandIn;
    sbk.length = APU_VGPU_SCAN_BYTES;
  endtask

  assign rd_rdy = rd_v && rst_ni && !rsp_v;

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rsp_v <= 1'b0;
      beats_seen <= 0;
      last_addr <= '0;
    end else if (arm_count) begin
      beats_seen <= 0;
      last_addr <= '0;
    end else if (rsp_v && rsp_rdy) begin
      rsp_v <= 1'b0;
    end else if (rd_v && rd_rdy) begin
      logic [63:0] delta;
      delta = rd_addr - {32'h0, StandIn};
      rsp_addr <= rd_addr;
      rsp_len <= rd_len;
      rsp_data <= {224'b0, pat(delta[17:5])};
      rsp_ok <= !(fail_next && rd_addr == {32'h0, StandIn});
      if (!(fail_next && rd_addr == {32'h0, StandIn})) begin
        beats_seen <= beats_seen + 1;
        last_addr <= rd_addr;
      end
      fail_next <= 1'b0;
      rsp_v <= 1'b1;
    end
  end

  task automatic bcp_step(input apu_vgpu_bcp_status_e st, input string name);
    @(negedge clk);
    while (!bcp_rdy) @(negedge clk);
    cases++;
    arm_count = 1'b1;
    @(posedge clk);
    @(negedge clk);
    arm_count = 1'b0;
    bcp_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    bcp_req = 1'b0;
    while (!bcp_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), bcp_cpl.status == st);
    if (st == APU_VGPU_BCP_OK)
      check($sformatf("%s copy", name), bcp.valid && bcp.beats == 13'd5120 &&
            bcp.bytes == 32'd163840 && bcp.word == Word0);
    @(negedge clk);
    check($sformatf("%s held", name), bcp_cpl_v);
    bcp_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    bcp_cpl_r = 1'b0;
    while (bcp_cpl_v) @(negedge clk);
  endtask

  task automatic bcr_step(input apu_vgpu_bcr_status_e st, input string name);
    @(negedge clk);
    while (!bcr_rdy) @(negedge clk);
    cases++;
    bcr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    bcr_req = 1'b0;
    while (!bcr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), bcr_cpl.status == st);
    if (st == APU_VGPU_BCR_OK)
      check($sformatf("%s words", name), bcr_cpl.beats == 13'd5120 &&
            bcr_cpl.word == Word0 && bcr_cpl.scene == 32'hFF1A0D0D);
    else
      check($sformatf("%s quiet", name), bcr_cpl.word == 32'h0 && bcr_cpl.scene == 32'h0);
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_cpl == '0);
    @(negedge clk);
    check($sformatf("%s held", name), bcr_cpl_v);
    bcr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    bcr_cpl_r = 1'b0;
    while (bcr_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    bcp_req = 1'b0;
    bcr_req = 1'b0;
    bcp_cpl_r = 1'b0;
    bcr_cpl_r = 1'b0;
    rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    sxf = '0;
    sbk = '0;
    fail_next = 1'b0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 && bcp == '0);
    check("profiles keep copy off",
          !ApuOff.BcpEn && !ApuOff.BcrEn &&
          !ApuP1Transport.BcpEn && !ApuP1Transport.BcrEn &&
          !ApuHarness.BcpEn && !ApuHarness.BcrEn &&
          !ApuSchedBoth.BcpEn && !ApuSchedBoth.BcrEn &&
          !ApuBadVirglGrant.BcpEn && !ApuBadVirglGrant.BcrEn);
    cfg = ApuP1Transport;
    cfg.BcpEn = 1'b1;
    cfg.BcrEn = 1'b1;
    check("copy does not require virgl", apu_cfg_legal(cfg));
    cfg = ApuBadVirglGrant;
    cfg.BcpEn = 1'b1;
    cfg.BcrEn = 1'b1;
    check("copy does not legalize virgl", !apu_cfg_legal(cfg));
    check("band size", APU_VGPU_SCAN_BAND_BYTES == 32'd163840 &&
          APU_VGPU_SCAN_BAND_BEATS == 13'd5120 &&
          32'(APU_VGPU_SCAN_W) * 32'(APU_VGPU_SCAN_BAND) * 32'd4 == 32'd163840);

    bcp_step(APU_VGPU_BCP_EMPTY, "bcp empty");
    good_sxf();
    good_sbk();
    sxf.height = APU_VGPU_SCAN_H;
    bcp_step(APU_VGPU_BCP_FAULT, "full height");
    check("height keeps", !bcp.valid);
    good_sxf();
    sxf.copied = 1'b1;
    bcp_step(APU_VGPU_BCP_FAULT, "already copied");
    good_sxf();
    fail_next = 1'b1;
    bcp_step(APU_VGPU_BCP_FAULT, "bad beat");
    check("beat keeps", !bcp.valid);
    bcp_step(APU_VGPU_BCP_OK, "band");
    check("beat count", beats_seen == 5120);
    check("last addr", last_addr == 64'h0000_0000_8803_6FE0);
    check("scene stays", sxf.word == 32'hFF1A0D0D && !sxf.copied);
    bcp_step(APU_VGPU_BCP_FAULT, "band again");
    check("band stays", bcp.valid && bcp.word == Word0 && bcp.beats == 13'd5120);

    bcr_step(APU_VGPU_BCR_OK, "report");
    sxf.word = 32'h0;
    bcr_step(APU_VGPU_BCR_FAULT, "scene changed");
    good_sxf();
    bcr_step(APU_VGPU_BCR_OK, "report again");

    pulse_reset();
    check("reset clears", bcp == '0);
    bcr_step(APU_VGPU_BCR_EMPTY, "after reset");

    if (errors != 0) $fatal(1, "APU vgpu bcp errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_bcp cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
