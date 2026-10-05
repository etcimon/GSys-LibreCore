// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_rwd;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_rfy_t rfy;
  logic rwd_req = 0, rwd_rdy, rwd_cpl_v, rwd_cpl_r = 0;
  apu_vgpu_rwd_cpl_t rwd_cpl;
  apu_vgpu_rwd_t rwd;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic rwk_req = 0, rwk_rdy, rwk_cpl_v, rwk_cpl_r = 0;
  apu_vgpu_rwk_cpl_t rwk_cpl;
  apu_vgpu_rwk_t rwk;
  logic rwx_req = 0, rwx_rdy, rwx_cpl_v, rwx_cpl_r = 0;
  apu_vgpu_rwx_cpl_t rwx_cpl, off_cpl;
  apu_vgpu_rwx_t rwx, off_rwx;
  logic off_rdy, off_v;
  logic fail_rd = 0, bad_ind = 0, bad_len = 0, rd_order = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {128'h0, APU_VGPU_QWD_META,
                                  APU_VGPU_QWD_LEN, APU_VGPU_RFW_ADDR};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_rwd #(.Enable(1'b1)) i_rwd (
    .clk_i(clk), .rst_ni, .rfy_i(rfy),
    .req_valid_i(rwd_req), .req_ready_o(rwd_rdy),
    .cpl_valid_o(rwd_cpl_v), .cpl_ready_i(rwd_cpl_r), .cpl_o(rwd_cpl), .rwd_o(rwd),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_rwk #(.Enable(1'b1)) i_rwk (
    .clk_i(clk), .rst_ni, .rwd_i(rwd), .rfy_i(rfy),
    .req_valid_i(rwk_req), .req_ready_o(rwk_rdy),
    .cpl_valid_o(rwk_cpl_v), .cpl_ready_i(rwk_cpl_r), .cpl_o(rwk_cpl), .rwk_o(rwk)
  );
  g6lc_apu_vgpu_rwx #(.Enable(1'b1)) i_rwx (
    .clk_i(clk), .rst_ni, .rwk_i(rwk), .rwd_i(rwd), .rfy_i(rfy),
    .req_valid_i(rwx_req), .req_ready_o(rwx_rdy),
    .cpl_valid_o(rwx_cpl_v), .cpl_ready_i(rwx_cpl_r), .cpl_o(rwx_cpl), .rwx_o(rwx)
  );
  g6lc_apu_vgpu_rwx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .rwk_i(rwk), .rwd_i(rwd), .rfy_i(rfy),
    .req_valid_i(rwx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(rwx_cpl_r), .cpl_o(off_cpl), .rwx_o(off_rwx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu rwd timeout case=%0d", cases); end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_rsp_v <= 1'b0;
      nread <= 0;
      rd_order <= 1'b0;
    end else if (rd_rsp_v && rd_rsp_rdy) rd_rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      logic [255:0] beat;
      beat = Pat;
      if (bad_ind) beat[127:96] = APU_VGPU_QWD_IND;
      if (bad_len) beat[95:64] = APU_VGPU_TFB_BYTES;
      if (rd_addr != APU_VGPU_QWD_ADDR || rd_len != 32'd16) rd_order <= 1'b1;
      rd_seen <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat;
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      bad_ind <= 1'b0;
      bad_len <= 1'b0;
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
    rfy = '0;
    rfy.valid = 1'b1;
    rfy.xfer_addr = APU_VGPU_TFB_CMD;
    rfy.nxt = 16'd2;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_rwx == '0 &&
          off_cpl == '0);
  endtask

  task automatic rwd_step(input apu_vgpu_rwd_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!rwd_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    rwd_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rwd_req = 1'b0;
    while (!rwd_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rwd_cpl.status == st);
    quiet();
    if (st == APU_VGPU_RWD_OK) begin
      check("desc 2", rwd.valid && rwd.rsp_addr == APU_VGPU_RFW_ADDR &&
            rwd.rsp_addr != APU_VGPU_TFB_CMD &&
            rwd.rsp_len == APU_VGPU_QWD_LEN);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_QWD_ADDR && rd_seen != APU_VGPU_QFD_ADDR);
    end else if (name == "bad beat" || name == "indirect" ||
                 name == "xfer len") begin
      check("one read failed", nread == n0 + 1 && !rwd.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), rwd_cpl_v);
    rwd_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rwd_cpl_r = 1'b0;
    while (rwd_cpl_v) @(negedge clk);
  endtask

  task automatic rwk_step(input apu_vgpu_rwk_status_e st, input string name);
    @(negedge clk);
    while (!rwk_rdy) @(negedge clk);
    cases++;
    rwk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rwk_req = 1'b0;
    while (!rwk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rwk_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), rwk_cpl_v);
    rwk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rwk_cpl_r = 1'b0;
    while (rwk_cpl_v) @(negedge clk);
  endtask

  task automatic rwx_step(input apu_vgpu_rwx_status_e st, input string name);
    @(negedge clk);
    while (!rwx_rdy) @(negedge clk);
    cases++;
    rwx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rwx_req = 1'b0;
    while (!rwx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rwx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), rwx_cpl_v);
    rwx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rwx_cpl_r = 1'b0;
    while (rwx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    rwd_req = 1'b0;
    rwk_req = 1'b0;
    rwx_req = 1'b0;
    rwd_cpl_r = 1'b0;
    rwk_cpl_r = 1'b0;
    rwx_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    rfy = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          rwd == '0 && rwk == '0 && rwx == '0);
    check("profiles keep the write peek off",
          !ApuOff.RwdEn && !ApuOff.RwkEn && !ApuOff.RwxEn &&
          !ApuP1Transport.RwdEn && !ApuP1Transport.RwkEn &&
          !ApuP1Transport.RwxEn &&
          !ApuHarness.RwdEn && !ApuHarness.RwkEn && !ApuHarness.RwxEn &&
          !ApuSchedBoth.RwdEn && !ApuSchedBoth.RwkEn && !ApuSchedBoth.RwxEn &&
          !ApuBadVirglGrant.RwdEn && !ApuBadVirglGrant.RwkEn &&
          !ApuBadVirglGrant.RwxEn);
    cfg = ApuP1Transport;
    cfg.RwdEn = 1'b1;
    cfg.RwkEn = 1'b1;
    cfg.RwxEn = 1'b1;
    check("write peek does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.RwdEn = 1'b1;
    cfg.RwkEn = 1'b1;
    cfg.RwxEn = 1'b1;
    check("write peek does not legalize virgl", !apu_cfg_legal(cfg));
    check("write places",
          APU_VGPU_QWD_ADDR == 64'h880D0020 &&
          APU_VGPU_QWD_ADDR == APU_VGPU_TXC_LAST &&
          APU_VGPU_QWD_SCENE == APU_VGPU_NXC_LAST &&
          APU_VGPU_QWD_META == {16'd0, VIRTQ_DESC_F_WRITE} &&
          APU_VGPU_QWD_NXT == {16'd0, VIRTQ_DESC_F_NEXT} &&
          APU_VGPU_QWD_IND == {16'd0, VIRTQ_DESC_F_WRITE | VIRTQ_DESC_F_INDIRECT} &&
          APU_VGPU_QWD_LEN == VGPU_RESP_HDR_BYTES);

    rwd_step(APU_VGPU_RWD_EMPTY, "read empty");
    rwk_step(APU_VGPU_RWK_EMPTY, "keep empty");
    rwx_step(APU_VGPU_RWX_EMPTY, "check empty");
    good_in();
    rfy.nxt = 16'd1;
    rwd_step(APU_VGPU_RWD_FAULT, "stay");
    good_in();
    fail_rd = 1'b1;
    rwd_step(APU_VGPU_RWD_FAULT, "bad beat");
    bad_ind = 1'b1;
    rwd_step(APU_VGPU_RWD_FAULT, "indirect");
    bad_len = 1'b1;
    rwd_step(APU_VGPU_RWD_FAULT, "xfer len");
    rwd_step(APU_VGPU_RWD_OK, "desc 2");
    rwd_step(APU_VGPU_RWD_FAULT, "desc again");
    check("desc stays", rwd.valid && rwd.rsp_addr == APU_VGPU_RFW_ADDR &&
          rwd.rsp_len == 32'd24);
    rfy.nxt = 16'd1;
    rwk_step(APU_VGPU_RWK_FAULT, "keep stay");
    check("keep rejected", !rwk.valid);
    good_in();
    rwk_step(APU_VGPU_RWK_OK, "keep desc");
    check("desc kept", rwk.valid && rwk.rsp_addr == APU_VGPU_RFW_ADDR &&
          rwk.rsp_len == APU_VGPU_QWD_LEN);
    rwk_step(APU_VGPU_RWK_FAULT, "keep again");
    rfy.nxt = 16'd1;
    rwx_step(APU_VGPU_RWX_FAULT, "check stay");
    check("check rejected", !rwx.valid);
    good_in();
    rwx_step(APU_VGPU_RWX_OK, "check desc");
    check("desc checked", rwx.valid && rwx.rsp_addr == APU_VGPU_RFW_ADDR);
    rwx_step(APU_VGPU_RWX_FAULT, "check again");
    check("check stays", rwx.rsp_addr == rwd.rsp_addr);

    pulse_reset();
    check("reset clears", rwd == '0 && rwk == '0 && rwx == '0);
    rfy = '0;
    rwd_step(APU_VGPU_RWD_EMPTY, "after reset");
    good_in();
    rwd_step(APU_VGPU_RWD_OK, "desc after reset");

    if (errors != 0) $fatal(1, "APU vgpu rwd errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_rwd cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
