// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_srg;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_sax_t sax;
  logic srg_req = 0, srg_rdy, srg_cpl_v, srg_cpl_r = 0;
  apu_vgpu_srg_cpl_t srg_cpl;
  apu_vgpu_srg_t srg;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic srk_req = 0, srk_rdy, srk_cpl_v, srk_cpl_r = 0;
  apu_vgpu_srk_cpl_t srk_cpl;
  apu_vgpu_srk_t srk;
  logic srx_req = 0, srx_rdy, srx_cpl_v, srx_cpl_r = 0;
  apu_vgpu_srx_cpl_t srx_cpl, off_cpl;
  apu_vgpu_srx_t srx, off_srx;
  logic off_rdy, off_v;
  logic fail_rd = 0, bad_desc = 0, rd_order = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {224'h0, APU_VGPU_QRG_WORD};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_srg #(.Enable(1'b1)) i_srg (
    .clk_i(clk), .rst_ni, .sax_i(sax),
    .req_valid_i(srg_req), .req_ready_o(srg_rdy),
    .cpl_valid_o(srg_cpl_v), .cpl_ready_i(srg_cpl_r), .cpl_o(srg_cpl), .srg_o(srg),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_srk #(.Enable(1'b1)) i_srk (
    .clk_i(clk), .rst_ni, .srg_i(srg), .sax_i(sax),
    .req_valid_i(srk_req), .req_ready_o(srk_rdy),
    .cpl_valid_o(srk_cpl_v), .cpl_ready_i(srk_cpl_r), .cpl_o(srk_cpl), .srk_o(srk)
  );
  g6lc_apu_vgpu_srx #(.Enable(1'b1)) i_srx (
    .clk_i(clk), .rst_ni, .srk_i(srk), .srg_i(srg), .sax_i(sax),
    .req_valid_i(srx_req), .req_ready_o(srx_rdy),
    .cpl_valid_o(srx_cpl_v), .cpl_ready_i(srx_cpl_r), .cpl_o(srx_cpl), .srx_o(srx)
  );
  g6lc_apu_vgpu_srx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .srk_i(srk), .srg_i(srg), .sax_i(sax),
    .req_valid_i(srx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(srx_cpl_r), .cpl_o(off_cpl), .srx_o(off_srx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu srg timeout case=%0d", cases); end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_rsp_v <= 1'b0;
      nread <= 0;
      rd_order <= 1'b0;
    end else if (rd_rsp_v && rd_rsp_rdy) rd_rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      logic [255:0] beat;
      beat = Pat;
      if (bad_desc) beat[31:0] = APU_VGPU_QRG_BAD;
      if (rd_addr != APU_VGPU_SRG_ADDR || rd_len != 32'd4) rd_order <= 1'b1;
      rd_seen <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat;
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      bad_desc <= 1'b0;
      nread <= nread + 1;
      rd_rsp_v <= 1'b1;
    end
  end

  task automatic check(input string name, input logic cond);
    checks++;
    if (!cond) begin
      errors++;
      $display("FAIL %s", name);
    end
  endtask

  task automatic good_in;
    sax = '0;
    sax.valid = 1'b1;
    sax.avail_idx = APU_VGPU_QSU_IDXV;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_srx == '0 &&
          off_cpl == '0);
  endtask

  task automatic srg_step(input apu_vgpu_srg_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!srg_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    srg_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    srg_req = 1'b0;
    while (!srg_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), srg_cpl.status == st);
    quiet();
    if (st == APU_VGPU_SRG_OK) begin
      check("ring name", srg.valid && srg.desc_id == 16'd0 &&
            srg.desc_id != 16'd1 &&
            srg.addr == APU_VGPU_SRG_ADDR &&
            srg.addr != APU_VGPU_QRG_ADDR &&
            srg.addr != APU_VGPU_SAV_ADDR);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_SRG_ADDR && rd_seen != APU_VGPU_QRG_ADDR);
    end else if (name == "bad beat" || name == "bad desc") begin
      check("one read failed", nread == n0 + 1 && !srg.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), srg_cpl_v);
    srg_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    srg_cpl_r = 1'b0;
    while (srg_cpl_v) @(negedge clk);
  endtask

  task automatic srk_step(input apu_vgpu_srk_status_e st, input string name);
    @(negedge clk);
    while (!srk_rdy) @(negedge clk);
    cases++;
    srk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    srk_req = 1'b0;
    while (!srk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), srk_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), srk_cpl_v);
    srk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    srk_cpl_r = 1'b0;
    while (srk_cpl_v) @(negedge clk);
  endtask

  task automatic srx_step(input apu_vgpu_srx_status_e st, input string name);
    @(negedge clk);
    while (!srx_rdy) @(negedge clk);
    cases++;
    srx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    srx_req = 1'b0;
    while (!srx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), srx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), srx_cpl_v);
    srx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    srx_cpl_r = 1'b0;
    while (srx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    srg_req = 1'b0;
    srk_req = 1'b0;
    srx_req = 1'b0;
    srg_cpl_r = 1'b0;
    srk_cpl_r = 1'b0;
    srx_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    sax = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          srg == '0 && srk == '0 && srx == '0);
    check("profiles keep the ring peek off",
          !ApuOff.SrgEn && !ApuOff.SrkEn && !ApuOff.SrxEn &&
          !ApuP1Transport.SrgEn && !ApuP1Transport.SrkEn &&
          !ApuP1Transport.SrxEn &&
          !ApuHarness.SrgEn && !ApuHarness.SrkEn && !ApuHarness.SrxEn &&
          !ApuSchedBoth.SrgEn && !ApuSchedBoth.SrkEn && !ApuSchedBoth.SrxEn &&
          !ApuBadVirglGrant.SrgEn && !ApuBadVirglGrant.SrkEn &&
          !ApuBadVirglGrant.SrxEn);
    cfg = ApuP1Transport;
    cfg.SrgEn = 1'b1;
    cfg.SrkEn = 1'b1;
    cfg.SrxEn = 1'b1;
    check("ring peek does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.SrgEn = 1'b1;
    cfg.SrkEn = 1'b1;
    cfg.SrxEn = 1'b1;
    check("ring peek does not legalize virgl", !apu_cfg_legal(cfg));
    check("ring places",
          APU_VGPU_SRG_ADDR == 64'h8800E204 &&
          APU_VGPU_SRG_ADDR == APU_VGPU_QRG_SCENE &&
          APU_VGPU_SRG_ADDR != APU_VGPU_QRG_ADDR &&
          APU_VGPU_QRG_DESC == 16'd0 &&
          APU_VGPU_QRG_WORD == 32'h00070000 &&
          APU_VGPU_QRG_BAD == 32'h00070001);

    srg_step(APU_VGPU_SRG_EMPTY, "read empty");
    srk_step(APU_VGPU_SRK_EMPTY, "keep empty");
    srx_step(APU_VGPU_SRX_EMPTY, "check empty");
    good_in();
    sax.avail_idx = APU_VGPU_TUW_IDXV;
    srg_step(APU_VGPU_SRG_FAULT, "xfer index");
    good_in();
    fail_rd = 1'b1;
    srg_step(APU_VGPU_SRG_FAULT, "bad beat");
    bad_desc = 1'b1;
    srg_step(APU_VGPU_SRG_FAULT, "bad desc");
    srg_step(APU_VGPU_SRG_OK, "ring name");
    srg_step(APU_VGPU_SRG_FAULT, "ring again");
    check("ring stays", srg.valid && srg.desc_id == 16'd0 &&
          srg.addr == APU_VGPU_SRG_ADDR);
    sax.avail_idx = APU_VGPU_TUW_IDXV;
    srk_step(APU_VGPU_SRK_FAULT, "keep xfer index");
    check("keep rejected", !srk.valid);
    good_in();
    srk_step(APU_VGPU_SRK_OK, "keep name");
    check("name kept", srk.valid && srk.desc_id == 16'd0 &&
          srk.addr == APU_VGPU_SRG_ADDR);
    srk_step(APU_VGPU_SRK_FAULT, "keep again");
    sax.avail_idx = APU_VGPU_TUW_IDXV;
    srx_step(APU_VGPU_SRX_FAULT, "check xfer index");
    check("check rejected", !srx.valid);
    good_in();
    srx_step(APU_VGPU_SRX_OK, "check name");
    check("name checked", srx.valid && srx.desc_id == 16'd0);
    srx_step(APU_VGPU_SRX_FAULT, "check again");
    check("check stays", srx.desc_id == srg.desc_id);

    pulse_reset();
    check("reset clears", srg == '0 && srk == '0 && srx == '0);
    sax = '0;
    srg_step(APU_VGPU_SRG_EMPTY, "after reset");
    good_in();
    srg_step(APU_VGPU_SRG_OK, "ring after reset");

    if (errors != 0) $fatal(1, "APU vgpu srg errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_srg cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
