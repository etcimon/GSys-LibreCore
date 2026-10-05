// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_sfd;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_shx_t shx;
  logic sfd_req = 0, sfd_rdy, sfd_cpl_v, sfd_cpl_r = 0;
  apu_vgpu_sfd_cpl_t sfd_cpl;
  apu_vgpu_sfd_t sfd;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic sfk_req = 0, sfk_rdy, sfk_cpl_v, sfk_cpl_r = 0;
  apu_vgpu_sfk_cpl_t sfk_cpl;
  apu_vgpu_sfk_t sfk;
  logic sfx_req = 0, sfx_rdy, sfx_cpl_v, sfx_cpl_r = 0;
  apu_vgpu_sfx_cpl_t sfx_cpl, off_cpl;
  apu_vgpu_sfx_t sfx, off_sfx;
  logic off_rdy, off_v;
  logic fail_rd = 0, bad_ind = 0, bad_len = 0, rd_order = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {128'h0, APU_VGPU_QFD_META,
                                  APU_VGPU_SCENE_BYTES, APU_VGPU_EXEC_ADDR};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_sfd #(.Enable(1'b1)) i_sfd (
    .clk_i(clk), .rst_ni, .shx_i(shx),
    .req_valid_i(sfd_req), .req_ready_o(sfd_rdy),
    .cpl_valid_o(sfd_cpl_v), .cpl_ready_i(sfd_cpl_r), .cpl_o(sfd_cpl), .sfd_o(sfd),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_sfk #(.Enable(1'b1)) i_sfk (
    .clk_i(clk), .rst_ni, .sfd_i(sfd), .shx_i(shx),
    .req_valid_i(sfk_req), .req_ready_o(sfk_rdy),
    .cpl_valid_o(sfk_cpl_v), .cpl_ready_i(sfk_cpl_r), .cpl_o(sfk_cpl), .sfk_o(sfk)
  );
  g6lc_apu_vgpu_sfx #(.Enable(1'b1)) i_sfx (
    .clk_i(clk), .rst_ni, .sfk_i(sfk), .sfd_i(sfd), .shx_i(shx),
    .req_valid_i(sfx_req), .req_ready_o(sfx_rdy),
    .cpl_valid_o(sfx_cpl_v), .cpl_ready_i(sfx_cpl_r), .cpl_o(sfx_cpl), .sfx_o(sfx)
  );
  g6lc_apu_vgpu_sfx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .sfk_i(sfk), .sfd_i(sfd), .shx_i(shx),
    .req_valid_i(sfx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(sfx_cpl_r), .cpl_o(off_cpl), .sfx_o(off_sfx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu sfd timeout case=%0d", cases); end

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
      if (bad_len) beat[95:64] = APU_VGPU_TFB_BYTES;
      if (rd_addr != APU_VGPU_SFD_ADDR || rd_len != 32'd16) rd_order <= 1'b1;
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
    shx = '0;
    shx.valid = 1'b1;
    shx.hdr_addr = APU_VGPU_HDR_ADDR;
    shx.nxt = 16'd1;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_sfx == '0 &&
          off_cpl == '0);
  endtask

  task automatic sfd_step(input apu_vgpu_sfd_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!sfd_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    sfd_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sfd_req = 1'b0;
    while (!sfd_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), sfd_cpl.status == st);
    quiet();
    if (st == APU_VGPU_SFD_OK) begin
      check("desc 1", sfd.valid && sfd.exec_addr == APU_VGPU_EXEC_ADDR &&
            sfd.exec_addr != APU_VGPU_HDR_ADDR &&
            sfd.exec_len == APU_VGPU_SCENE_BYTES &&
            sfd.nxt == 16'd2 && sfd.nxt != 16'd1);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_SFD_ADDR && rd_seen != APU_VGPU_SHD_ADDR);
    end else if (name == "bad beat" || name == "indirect" ||
                 name == "xfer len") begin
      check("one read failed", nread == n0 + 1 && !sfd.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), sfd_cpl_v);
    sfd_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sfd_cpl_r = 1'b0;
    while (sfd_cpl_v) @(negedge clk);
  endtask

  task automatic sfk_step(input apu_vgpu_sfk_status_e st, input string name);
    @(negedge clk);
    while (!sfk_rdy) @(negedge clk);
    cases++;
    sfk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sfk_req = 1'b0;
    while (!sfk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), sfk_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), sfk_cpl_v);
    sfk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sfk_cpl_r = 1'b0;
    while (sfk_cpl_v) @(negedge clk);
  endtask

  task automatic sfx_step(input apu_vgpu_sfx_status_e st, input string name);
    @(negedge clk);
    while (!sfx_rdy) @(negedge clk);
    cases++;
    sfx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sfx_req = 1'b0;
    while (!sfx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), sfx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), sfx_cpl_v);
    sfx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    sfx_cpl_r = 1'b0;
    while (sfx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    sfd_req = 1'b0;
    sfk_req = 1'b0;
    sfx_req = 1'b0;
    sfd_cpl_r = 1'b0;
    sfk_cpl_r = 1'b0;
    sfx_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    shx = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          sfd == '0 && sfk == '0 && sfx == '0);
    check("profiles keep the follow peek off",
          !ApuOff.SfdEn && !ApuOff.SfkEn && !ApuOff.SfxEn &&
          !ApuP1Transport.SfdEn && !ApuP1Transport.SfkEn &&
          !ApuP1Transport.SfxEn &&
          !ApuHarness.SfdEn && !ApuHarness.SfkEn && !ApuHarness.SfxEn &&
          !ApuSchedBoth.SfdEn && !ApuSchedBoth.SfkEn && !ApuSchedBoth.SfxEn &&
          !ApuBadVirglGrant.SfdEn && !ApuBadVirglGrant.SfkEn &&
          !ApuBadVirglGrant.SfxEn);
    cfg = ApuP1Transport;
    cfg.SfdEn = 1'b1;
    cfg.SfkEn = 1'b1;
    cfg.SfxEn = 1'b1;
    check("follow peek does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.SfdEn = 1'b1;
    cfg.SfkEn = 1'b1;
    cfg.SfxEn = 1'b1;
    check("follow peek does not legalize virgl", !apu_cfg_legal(cfg));
    check("follow places",
          APU_VGPU_SFD_ADDR == 64'h8800E110 &&
          APU_VGPU_SFD_ADDR == APU_VGPU_QFD_SCENE &&
          APU_VGPU_SFD_ADDR != APU_VGPU_QFD_ADDR &&
          APU_VGPU_QFD_META == {16'd2, VIRTQ_DESC_F_NEXT} &&
          APU_VGPU_QFD_IND == {16'd2, VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_INDIRECT} &&
          APU_VGPU_QFD_WR == {16'd2, VIRTQ_DESC_F_WRITE});

    sfd_step(APU_VGPU_SFD_EMPTY, "read empty");
    sfk_step(APU_VGPU_SFK_EMPTY, "keep empty");
    sfx_step(APU_VGPU_SFX_EMPTY, "check empty");
    good_in();
    shx.nxt = 16'd2;
    sfd_step(APU_VGPU_SFD_FAULT, "jump");
    good_in();
    fail_rd = 1'b1;
    sfd_step(APU_VGPU_SFD_FAULT, "bad beat");
    bad_ind = 1'b1;
    sfd_step(APU_VGPU_SFD_FAULT, "indirect");
    bad_len = 1'b1;
    sfd_step(APU_VGPU_SFD_FAULT, "xfer len");
    sfd_step(APU_VGPU_SFD_OK, "desc 1");
    sfd_step(APU_VGPU_SFD_FAULT, "desc again");
    check("desc stays", sfd.valid && sfd.exec_addr == APU_VGPU_EXEC_ADDR &&
          sfd.nxt == 16'd2);
    shx.nxt = 16'd2;
    sfk_step(APU_VGPU_SFK_FAULT, "keep jump");
    check("keep rejected", !sfk.valid);
    good_in();
    sfk_step(APU_VGPU_SFK_OK, "keep desc");
    check("desc kept", sfk.valid && sfk.exec_addr == APU_VGPU_EXEC_ADDR &&
          sfk.exec_len == APU_VGPU_SCENE_BYTES && sfk.nxt == 16'd2);
    sfk_step(APU_VGPU_SFK_FAULT, "keep again");
    shx.nxt = 16'd2;
    sfx_step(APU_VGPU_SFX_FAULT, "check jump");
    check("check rejected", !sfx.valid);
    good_in();
    sfx_step(APU_VGPU_SFX_OK, "check desc");
    check("desc checked", sfx.valid && sfx.exec_addr == APU_VGPU_EXEC_ADDR &&
          sfx.nxt == 16'd2);
    sfx_step(APU_VGPU_SFX_FAULT, "check again");
    check("check stays", sfx.exec_addr == sfd.exec_addr && sfx.nxt == sfd.nxt);

    pulse_reset();
    check("reset clears", sfd == '0 && sfk == '0 && sfx == '0);
    shx = '0;
    sfd_step(APU_VGPU_SFD_EMPTY, "after reset");
    good_in();
    sfd_step(APU_VGPU_SFD_OK, "desc after reset");

    if (errors != 0) $fatal(1, "APU vgpu sfd errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_sfd cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
