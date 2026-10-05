// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_swd;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_sfx_t sfx;
  logic swd_req = 0, swd_rdy, swd_cpl_v, swd_cpl_r = 0;
  apu_vgpu_swd_cpl_t swd_cpl;
  apu_vgpu_swd_t swd;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic swk_req = 0, swk_rdy, swk_cpl_v, swk_cpl_r = 0;
  apu_vgpu_swk_cpl_t swk_cpl;
  apu_vgpu_swk_t swk;
  logic swx_req = 0, swx_rdy, swx_cpl_v, swx_cpl_r = 0;
  apu_vgpu_swx_cpl_t swx_cpl, off_cpl;
  apu_vgpu_swx_t swx, off_swx;
  logic off_rdy, off_v;
  logic fail_rd = 0, bad_ind = 0, bad_len = 0, rd_order = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nread = 0;

  localparam logic [255:0] Pat = {128'h0, APU_VGPU_QWD_META,
                                  APU_VGPU_QWD_LEN, APU_VGPU_RSP_ADDR};

  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_swd #(.Enable(1'b1)) i_swd (
    .clk_i(clk), .rst_ni, .sfx_i(sfx),
    .req_valid_i(swd_req), .req_ready_o(swd_rdy),
    .cpl_valid_o(swd_cpl_v), .cpl_ready_i(swd_cpl_r), .cpl_o(swd_cpl), .swd_o(swd),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_swk #(.Enable(1'b1)) i_swk (
    .clk_i(clk), .rst_ni, .swd_i(swd), .sfx_i(sfx),
    .req_valid_i(swk_req), .req_ready_o(swk_rdy),
    .cpl_valid_o(swk_cpl_v), .cpl_ready_i(swk_cpl_r), .cpl_o(swk_cpl), .swk_o(swk)
  );
  g6lc_apu_vgpu_swx #(.Enable(1'b1)) i_swx (
    .clk_i(clk), .rst_ni, .swk_i(swk), .swd_i(swd), .sfx_i(sfx),
    .req_valid_i(swx_req), .req_ready_o(swx_rdy),
    .cpl_valid_o(swx_cpl_v), .cpl_ready_i(swx_cpl_r), .cpl_o(swx_cpl), .swx_o(swx)
  );
  g6lc_apu_vgpu_swx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .swk_i(swk), .swd_i(swd), .sfx_i(sfx),
    .req_valid_i(swx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(swx_cpl_r), .cpl_o(off_cpl), .swx_o(off_swx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu swd timeout case=%0d", cases); end

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
      if (bad_len) beat[95:64] = APU_VGPU_SCENE_BYTES;
      if (rd_addr != APU_VGPU_SWD_ADDR || rd_len != 32'd16) rd_order <= 1'b1;
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
    sfx = '0;
    sfx.valid = 1'b1;
    sfx.exec_addr = APU_VGPU_EXEC_ADDR;
    sfx.nxt = 16'd2;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_swx == '0 &&
          off_cpl == '0);
  endtask

  task automatic swd_step(input apu_vgpu_swd_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!swd_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    swd_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    swd_req = 1'b0;
    while (!swd_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), swd_cpl.status == st);
    quiet();
    if (st == APU_VGPU_SWD_OK) begin
      check("desc 2", swd.valid && swd.rsp_addr == APU_VGPU_RSP_ADDR &&
            swd.rsp_addr != APU_VGPU_EXEC_ADDR &&
            swd.rsp_len == APU_VGPU_QWD_LEN);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_SWD_ADDR && rd_seen != APU_VGPU_SFD_ADDR);
    end else if (name == "bad beat" || name == "indirect" ||
                 name == "exec len") begin
      check("one read failed", nread == n0 + 1 && !swd.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), swd_cpl_v);
    swd_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    swd_cpl_r = 1'b0;
    while (swd_cpl_v) @(negedge clk);
  endtask

  task automatic swk_step(input apu_vgpu_swk_status_e st, input string name);
    @(negedge clk);
    while (!swk_rdy) @(negedge clk);
    cases++;
    swk_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    swk_req = 1'b0;
    while (!swk_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), swk_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), swk_cpl_v);
    swk_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    swk_cpl_r = 1'b0;
    while (swk_cpl_v) @(negedge clk);
  endtask

  task automatic swx_step(input apu_vgpu_swx_status_e st, input string name);
    @(negedge clk);
    while (!swx_rdy) @(negedge clk);
    cases++;
    swx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    swx_req = 1'b0;
    while (!swx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), swx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), swx_cpl_v);
    swx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    swx_cpl_r = 1'b0;
    while (swx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    swd_req = 1'b0;
    swk_req = 1'b0;
    swx_req = 1'b0;
    swd_cpl_r = 1'b0;
    swk_cpl_r = 1'b0;
    swx_cpl_r = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    sfx = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          swd == '0 && swk == '0 && swx == '0);
    check("profiles keep the write peek off",
          !ApuOff.SwdEn && !ApuOff.SwkEn && !ApuOff.SwxEn &&
          !ApuP1Transport.SwdEn && !ApuP1Transport.SwkEn &&
          !ApuP1Transport.SwxEn &&
          !ApuHarness.SwdEn && !ApuHarness.SwkEn && !ApuHarness.SwxEn &&
          !ApuSchedBoth.SwdEn && !ApuSchedBoth.SwkEn && !ApuSchedBoth.SwxEn &&
          !ApuBadVirglGrant.SwdEn && !ApuBadVirglGrant.SwkEn &&
          !ApuBadVirglGrant.SwxEn);
    cfg = ApuP1Transport;
    cfg.SwdEn = 1'b1;
    cfg.SwkEn = 1'b1;
    cfg.SwxEn = 1'b1;
    check("write peek does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.SwdEn = 1'b1;
    cfg.SwkEn = 1'b1;
    cfg.SwxEn = 1'b1;
    check("write peek does not legalize virgl", !apu_cfg_legal(cfg));
    check("write places",
          APU_VGPU_SWD_ADDR == 64'h8800E120 &&
          APU_VGPU_SWD_ADDR == APU_VGPU_NXC_LAST &&
          APU_VGPU_SWD_ADDR != APU_VGPU_QWD_ADDR &&
          APU_VGPU_QWD_META == {16'd0, VIRTQ_DESC_F_WRITE} &&
          APU_VGPU_QWD_NXT == {16'd0, VIRTQ_DESC_F_NEXT} &&
          APU_VGPU_QWD_IND == {16'd0, VIRTQ_DESC_F_WRITE | VIRTQ_DESC_F_INDIRECT} &&
          APU_VGPU_QWD_LEN == VGPU_RESP_HDR_BYTES);

    swd_step(APU_VGPU_SWD_EMPTY, "read empty");
    swk_step(APU_VGPU_SWK_EMPTY, "keep empty");
    swx_step(APU_VGPU_SWX_EMPTY, "check empty");
    good_in();
    sfx.nxt = 16'd1;
    swd_step(APU_VGPU_SWD_FAULT, "stay");
    good_in();
    fail_rd = 1'b1;
    swd_step(APU_VGPU_SWD_FAULT, "bad beat");
    bad_ind = 1'b1;
    swd_step(APU_VGPU_SWD_FAULT, "indirect");
    bad_len = 1'b1;
    swd_step(APU_VGPU_SWD_FAULT, "exec len");
    swd_step(APU_VGPU_SWD_OK, "desc 2");
    swd_step(APU_VGPU_SWD_FAULT, "desc again");
    check("desc stays", swd.valid && swd.rsp_addr == APU_VGPU_RSP_ADDR &&
          swd.rsp_len == 32'd24);
    sfx.nxt = 16'd1;
    swk_step(APU_VGPU_SWK_FAULT, "keep stay");
    check("keep rejected", !swk.valid);
    good_in();
    swk_step(APU_VGPU_SWK_OK, "keep desc");
    check("desc kept", swk.valid && swk.rsp_addr == APU_VGPU_RSP_ADDR &&
          swk.rsp_len == APU_VGPU_QWD_LEN);
    swk_step(APU_VGPU_SWK_FAULT, "keep again");
    sfx.nxt = 16'd1;
    swx_step(APU_VGPU_SWX_FAULT, "check stay");
    check("check rejected", !swx.valid);
    good_in();
    swx_step(APU_VGPU_SWX_OK, "check desc");
    check("desc checked", swx.valid && swx.rsp_addr == APU_VGPU_RSP_ADDR);
    swx_step(APU_VGPU_SWX_FAULT, "check again");
    check("check stays", swx.rsp_addr == swd.rsp_addr);

    pulse_reset();
    check("reset clears", swd == '0 && swk == '0 && swx == '0);
    sfx = '0;
    swd_step(APU_VGPU_SWD_EMPTY, "after reset");
    good_in();
    swd_step(APU_VGPU_SWD_OK, "desc after reset");

    if (errors != 0) $fatal(1, "APU vgpu swd errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_swd cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
