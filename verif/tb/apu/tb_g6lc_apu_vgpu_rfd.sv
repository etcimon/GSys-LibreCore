// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_rfd;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_rhx_t rhx;
  logic rfd_req = 0, rfd_rdy, rfd_cpl_v, rfd_cpl_r = 0;
  apu_vgpu_rfd_cpl_t rfd_cpl;
  apu_vgpu_rfd_t rfd;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic rfk_req = 0, rfk_rdy, rfk_cpl_v, rfk_cpl_r = 0;
  apu_vgpu_rfk_cpl_t rfk_cpl;
  apu_vgpu_rfk_t rfk;
  logic rfy_req = 0, rfy_rdy, rfy_cpl_v, rfy_cpl_r = 0;
  apu_vgpu_rfy_cpl_t rfy_cpl, off_cpl;
  apu_vgpu_rfy_t rfy, off_rfy;
  logic off_rdy, off_v;
  logic fail_rd = 0, bad_ind = 0, bad_len = 0, rd_order = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {128'h0, APU_VGPU_QFD_META,
                                  APU_VGPU_TFB_BYTES, APU_VGPU_TFB_CMD};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_rfd #(.Enable(1'b1)) i_rfd (
    .clk_i(clk), .rst_ni, .rhx_i(rhx),
    .req_valid_i(rfd_req), .req_ready_o(rfd_rdy),
    .cpl_valid_o(rfd_cpl_v), .cpl_ready_i(rfd_cpl_r), .cpl_o(rfd_cpl), .rfd_o(rfd),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_rfk #(.Enable(1'b1)) i_rfk (
    .clk_i(clk), .rst_ni, .rfd_i(rfd), .rhx_i(rhx),
    .req_valid_i(rfk_req), .req_ready_o(rfk_rdy),
    .cpl_valid_o(rfk_cpl_v), .cpl_ready_i(rfk_cpl_r), .cpl_o(rfk_cpl), .rfk_o(rfk)
  );
  g6lc_apu_vgpu_rfy #(.Enable(1'b1)) i_rfy (
    .clk_i(clk), .rst_ni, .rfk_i(rfk), .rfd_i(rfd), .rhx_i(rhx),
    .req_valid_i(rfy_req), .req_ready_o(rfy_rdy),
    .cpl_valid_o(rfy_cpl_v), .cpl_ready_i(rfy_cpl_r), .cpl_o(rfy_cpl), .rfy_o(rfy)
  );
  g6lc_apu_vgpu_rfy_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .rfk_i(rfk), .rfd_i(rfd), .rhx_i(rhx),
    .req_valid_i(rfy_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(rfy_cpl_r), .cpl_o(off_cpl), .rfy_o(off_rfy)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu rfd timeout case=%0d", cases); end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_rsp_v <= 1'b0;
      nread <= 0;
      rd_order <= 1'b0;
    end else if (rd_rsp_v && rd_rsp_rdy) rd_rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      logic [255:0] beat;
      beat = Pat;
      if (bad_ind) beat[127:96] = APU_VGPU_QFD_IND;
      if (bad_len) beat[95:64] = APU_VGPU_RAB_BYTES;
      if (rd_addr != APU_VGPU_QFD_ADDR || rd_len != 32'd16) rd_order <= 1'b1;
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
    rhx = '0;
    rhx.valid = 1'b1;
    rhx.att_addr = APU_VGPU_RAB_CMD;
    rhx.nxt = 16'd1;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_rfy == '0 &&
          off_cpl == '0);
  endtask

  task automatic rfd_step(input apu_vgpu_rfd_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!rfd_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    rfd_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rfd_req = 1'b0;
    while (!rfd_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rfd_cpl.status == st);
    quiet();
    if (st == APU_VGPU_RFD_OK) begin
      check("desc 1", rfd.valid && rfd.xfer_addr == APU_VGPU_TFB_CMD &&
            rfd.xfer_addr != APU_VGPU_RAB_CMD &&
            rfd.xfer_len == APU_VGPU_TFB_BYTES &&
            rfd.nxt == 16'd2 && rfd.nxt != 16'd1);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_QFD_ADDR && rd_seen != APU_VGPU_QHD_ADDR);
    end else if (name == "bad beat" || name == "indirect" ||
                 name == "attach len") begin
      check("one read failed", nread == n0 + 1 && !rfd.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), rfd_cpl_v);
    rfd_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rfd_cpl_r = 1'b0;
    while (rfd_cpl_v) @(negedge clk);
  endtask

  task automatic rfk_step(input apu_vgpu_rfk_status_e st, input string name);
    @(negedge clk);
    while (!rfk_rdy) @(negedge clk);
    cases++;
    rfk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rfk_req = 1'b0;
    while (!rfk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rfk_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), rfk_cpl_v);
    rfk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rfk_cpl_r = 1'b0;
    while (rfk_cpl_v) @(negedge clk);
  endtask

  task automatic rfy_step(input apu_vgpu_rfy_status_e st, input string name);
    @(negedge clk);
    while (!rfy_rdy) @(negedge clk);
    cases++;
    rfy_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rfy_req = 1'b0;
    while (!rfy_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rfy_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), rfy_cpl_v);
    rfy_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rfy_cpl_r = 1'b0;
    while (rfy_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    rfd_req = 1'b0;
    rfk_req = 1'b0;
    rfy_req = 1'b0;
    rfd_cpl_r = 1'b0;
    rfk_cpl_r = 1'b0;
    rfy_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    rhx = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          rfd == '0 && rfk == '0 && rfy == '0);
    check("profiles keep the follow peek off",
          !ApuOff.RfdEn && !ApuOff.RfkEn && !ApuOff.RfyEn &&
          !ApuP1Transport.RfdEn && !ApuP1Transport.RfkEn &&
          !ApuP1Transport.RfyEn &&
          !ApuHarness.RfdEn && !ApuHarness.RfkEn && !ApuHarness.RfyEn &&
          !ApuSchedBoth.RfdEn && !ApuSchedBoth.RfkEn && !ApuSchedBoth.RfyEn &&
          !ApuBadVirglGrant.RfdEn && !ApuBadVirglGrant.RfkEn &&
          !ApuBadVirglGrant.RfyEn);
    cfg = ApuP1Transport;
    cfg.RfdEn = 1'b1;
    cfg.RfkEn = 1'b1;
    cfg.RfyEn = 1'b1;
    check("follow peek does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.RfdEn = 1'b1;
    cfg.RfkEn = 1'b1;
    cfg.RfyEn = 1'b1;
    check("follow peek does not legalize virgl", !apu_cfg_legal(cfg));
    check("follow places",
          APU_VGPU_QFD_ADDR == 64'h880D0010 &&
          APU_VGPU_QFD_ADDR != APU_VGPU_QHD_ADDR &&
          APU_VGPU_QFD_SCENE == 64'h8800E110 &&
          APU_VGPU_QFD_META == {16'd2, VIRTQ_DESC_F_NEXT} &&
          APU_VGPU_QFD_IND == {16'd2, VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_INDIRECT} &&
          APU_VGPU_QFD_WR == {16'd2, VIRTQ_DESC_F_WRITE});

    rfd_step(APU_VGPU_RFD_EMPTY, "read empty");
    rfk_step(APU_VGPU_RFK_EMPTY, "keep empty");
    rfy_step(APU_VGPU_RFY_EMPTY, "check empty");
    good_in();
    rhx.nxt = 16'd2;
    rfd_step(APU_VGPU_RFD_FAULT, "jump");
    good_in();
    fail_rd = 1'b1;
    rfd_step(APU_VGPU_RFD_FAULT, "bad beat");
    bad_ind = 1'b1;
    rfd_step(APU_VGPU_RFD_FAULT, "indirect");
    bad_len = 1'b1;
    rfd_step(APU_VGPU_RFD_FAULT, "attach len");
    rfd_step(APU_VGPU_RFD_OK, "desc 1");
    rfd_step(APU_VGPU_RFD_FAULT, "desc again");
    check("desc stays", rfd.valid && rfd.xfer_addr == APU_VGPU_TFB_CMD &&
          rfd.nxt == 16'd2);
    rhx.nxt = 16'd2;
    rfk_step(APU_VGPU_RFK_FAULT, "keep jump");
    check("keep rejected", !rfk.valid);
    good_in();
    rfk_step(APU_VGPU_RFK_OK, "keep desc");
    check("desc kept", rfk.valid && rfk.xfer_addr == APU_VGPU_TFB_CMD &&
          rfk.xfer_len == APU_VGPU_TFB_BYTES && rfk.nxt == 16'd2);
    rfk_step(APU_VGPU_RFK_FAULT, "keep again");
    rhx.nxt = 16'd2;
    rfy_step(APU_VGPU_RFY_FAULT, "check jump");
    check("check rejected", !rfy.valid);
    good_in();
    rfy_step(APU_VGPU_RFY_OK, "check desc");
    check("desc checked", rfy.valid && rfy.xfer_addr == APU_VGPU_TFB_CMD &&
          rfy.nxt == 16'd2);
    rfy_step(APU_VGPU_RFY_FAULT, "check again");
    check("check stays", rfy.xfer_addr == rfd.xfer_addr && rfy.nxt == rfd.nxt);

    pulse_reset();
    check("reset clears", rfd == '0 && rfk == '0 && rfy == '0);
    rhx = '0;
    rfd_step(APU_VGPU_RFD_EMPTY, "after reset");
    good_in();
    rfd_step(APU_VGPU_RFD_OK, "desc after reset");

    if (errors != 0) $fatal(1, "APU vgpu rfd errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_rfd cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
