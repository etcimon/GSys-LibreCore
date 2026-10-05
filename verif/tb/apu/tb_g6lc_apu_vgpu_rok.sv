// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_rok;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_rwx_t rwx;
  logic rok_req = 0, rok_rdy, rok_cpl_v, rok_cpl_r = 0;
  apu_vgpu_rok_cpl_t rok_cpl;
  apu_vgpu_rok_t rok;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, wr_seen = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic rol_req = 0, rol_rdy, rol_cpl_v, rol_cpl_r = 0;
  apu_vgpu_rol_cpl_t rol_cpl;
  apu_vgpu_rol_t rol;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic roy_req = 0, roy_rdy, roy_cpl_v, roy_cpl_r = 0;
  apu_vgpu_roy_cpl_t roy_cpl, off_cpl;
  apu_vgpu_roy_t roy, off_roy;
  logic off_rdy, off_v;
  logic fail_wr = 0, fail_rd = 0, scene_fence = 0, no_flag = 0;
  logic order_bad = 0, data_bad = 0, rd_order = 0;
  logic [255:0] stored = 0;
  logic stored_v = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nwrite = 0, nread = 0;

  localparam logic [255:0] RespBeat = {64'h0, 32'h0, APU_VGPU_CTX_ID,
                                       APU_VGPU_RFW_FENCE, VGPU_FLAG_FENCE,
                                       VGPU_RESP_OK_NODATA};

  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;
  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_rok #(.Enable(1'b1)) i_rok (
    .clk_i(clk), .rst_ni, .rwx_i(rwx),
    .req_valid_i(rok_req), .req_ready_o(rok_rdy),
    .cpl_valid_o(rok_cpl_v), .cpl_ready_i(rok_cpl_r), .cpl_o(rok_cpl), .rok_o(rok),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_rol #(.Enable(1'b1)) i_rol (
    .clk_i(clk), .rst_ni, .rok_i(rok), .rwx_i(rwx),
    .req_valid_i(rol_req), .req_ready_o(rol_rdy),
    .cpl_valid_o(rol_cpl_v), .cpl_ready_i(rol_cpl_r), .cpl_o(rol_cpl), .rol_o(rol),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_roy #(.Enable(1'b1)) i_roy (
    .clk_i(clk), .rst_ni, .rol_i(rol), .rok_i(rok), .rwx_i(rwx),
    .req_valid_i(roy_req), .req_ready_o(roy_rdy),
    .cpl_valid_o(roy_cpl_v), .cpl_ready_i(roy_cpl_r), .cpl_o(roy_cpl), .roy_o(roy)
  );
  g6lc_apu_vgpu_roy_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .rol_i(rol), .rok_i(rok), .rwx_i(rwx),
    .req_valid_i(roy_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(roy_cpl_r), .cpl_o(off_cpl), .roy_o(off_roy)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu rok timeout case=%0d", cases); end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      wr_rsp_v <= 1'b0;
      nwrite <= 0;
      order_bad <= 1'b0;
      data_bad <= 1'b0;
      stored_v <= 1'b0;
      stored <= '0;
    end else if (wr_rsp_v && wr_rsp_rdy) wr_rsp_v <= 1'b0;
    else if (wr_v && wr_rdy) begin
      if (wr_addr != APU_VGPU_RFW_ADDR || wr_len != VGPU_RESP_HDR_BYTES)
        order_bad <= 1'b1;
      if (wr_data[191:0] != RespBeat[191:0]) data_bad <= 1'b1;
      wr_seen <= wr_addr;
      stored <= wr_data;
      stored_v <= 1'b1;
      wr_rsp_addr <= wr_addr;
      wr_rsp_ok <= !fail_wr;
      fail_wr <= 1'b0;
      nwrite <= nwrite + 1;
      wr_rsp_v <= 1'b1;
    end
  end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_rsp_v <= 1'b0;
      nread <= 0;
      rd_order <= 1'b0;
    end else if (rd_rsp_v && rd_rsp_rdy) rd_rsp_v <= 1'b0;
    else if (rd_v && rd_rdy) begin
      logic [255:0] beat;
      beat = stored_v ? stored : RespBeat;
      if (scene_fence) beat[127:64] = APU_VGPU_SCENE_FENCE;
      if (no_flag) beat[63:32] = 32'h0;
      if (rd_addr != APU_VGPU_RFW_ADDR || rd_len != VGPU_RESP_HDR_BYTES)
        rd_order <= 1'b1;
      rd_seen <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat;
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      scene_fence <= 1'b0;
      no_flag <= 1'b0;
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
    rwx = '0;
    rwx.valid = 1'b1;
    rwx.rsp_addr = APU_VGPU_RFW_ADDR;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_roy == '0 &&
          off_cpl == '0);
  endtask

  task automatic rok_step(input apu_vgpu_rok_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!rok_rdy) @(negedge clk);
    cases++;
    n0 = nwrite;
    rok_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rok_req = 1'b0;
    while (!rok_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rok_cpl.status == st);
    quiet();
    if (st == APU_VGPU_ROK_OK) begin
      check("response", rok.valid && rok.resp == VGPU_RESP_OK_NODATA &&
            rok.fence == APU_VGPU_RFW_FENCE &&
            rok.fence != APU_VGPU_SCENE_FENCE &&
            rok.addr == APU_VGPU_RFW_ADDR && rok.addr != APU_VGPU_RSP_ADDR);
      check("one write", nwrite == n0 + 1 && !order_bad && !data_bad &&
            wr_seen == APU_VGPU_RFW_ADDR && wr_seen != APU_VGPU_QWD_ADDR);
    end else if (name == "bad write") begin
      check("one write failed", nwrite == n0 + 1 && !rok.valid);
    end else check("no write", nwrite == n0);
    @(negedge clk);
    check($sformatf("%s held", name), rok_cpl_v);
    rok_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rok_cpl_r = 1'b0;
    while (rok_cpl_v) @(negedge clk);
  endtask

  task automatic rol_step(input apu_vgpu_rol_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!rol_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    rol_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rol_req = 1'b0;
    while (!rol_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rol_cpl.status == st);
    quiet();
    if (st == APU_VGPU_ROL_OK) begin
      check("echo", rol.valid && rol.fence == APU_VGPU_RFW_FENCE &&
            rol.fence != APU_VGPU_SCENE_FENCE &&
            rol.flg == VGPU_FLAG_FENCE &&
            rol.resp == VGPU_RESP_OK_NODATA &&
            rol.addr == APU_VGPU_RFW_ADDR);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_RFW_ADDR);
    end else if (name == "bad read" || name == "scene fence" ||
                 name == "no flag") begin
      check("one read failed", nread == n0 + 1 && !rol.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), rol_cpl_v);
    rol_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rol_cpl_r = 1'b0;
    while (rol_cpl_v) @(negedge clk);
  endtask

  task automatic roy_step(input apu_vgpu_roy_status_e st, input string name);
    @(negedge clk);
    while (!roy_rdy) @(negedge clk);
    cases++;
    roy_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    roy_req = 1'b0;
    while (!roy_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), roy_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), roy_cpl_v);
    roy_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    roy_cpl_r = 1'b0;
    while (roy_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    rok_req = 1'b0;
    rol_req = 1'b0;
    roy_req = 1'b0;
    rok_cpl_r = 1'b0;
    rol_cpl_r = 1'b0;
    roy_cpl_r = 1'b0;
    wr_rsp_v = 1'b0;
    rd_rsp_v = 1'b0;
    stored_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    rwx = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          rok == '0 && rol == '0 && roy == '0);
    check("profiles keep the nodata off",
          !ApuOff.RokEn && !ApuOff.RolEn && !ApuOff.RoyEn &&
          !ApuP1Transport.RokEn && !ApuP1Transport.RolEn &&
          !ApuP1Transport.RoyEn &&
          !ApuHarness.RokEn && !ApuHarness.RolEn && !ApuHarness.RoyEn &&
          !ApuSchedBoth.RokEn && !ApuSchedBoth.RolEn && !ApuSchedBoth.RoyEn &&
          !ApuBadVirglGrant.RokEn && !ApuBadVirglGrant.RolEn &&
          !ApuBadVirglGrant.RoyEn);
    cfg = ApuP1Transport;
    cfg.RokEn = 1'b1;
    cfg.RolEn = 1'b1;
    cfg.RoyEn = 1'b1;
    check("nodata does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.RokEn = 1'b1;
    cfg.RolEn = 1'b1;
    cfg.RoyEn = 1'b1;
    check("nodata does not legalize virgl", !apu_cfg_legal(cfg));
    check("nodata places",
          APU_VGPU_RFW_ADDR != APU_VGPU_RSP_ADDR &&
          APU_VGPU_RFW_ADDR != APU_VGPU_QWD_ADDR &&
          APU_VGPU_RFW_FENCE == 64'd2 &&
          APU_VGPU_RFW_FENCE != APU_VGPU_SCENE_FENCE &&
          VGPU_RESP_HDR_BYTES == 32'd24);

    rok_step(APU_VGPU_ROK_EMPTY, "write empty");
    rol_step(APU_VGPU_ROL_EMPTY, "read empty");
    roy_step(APU_VGPU_ROY_EMPTY, "check empty");
    good_in();
    rwx.rsp_addr = APU_VGPU_RSP_ADDR;
    rok_step(APU_VGPU_ROK_FAULT, "scene dest");
    good_in();
    fail_wr = 1'b1;
    rok_step(APU_VGPU_ROK_FAULT, "bad write");
    rok_step(APU_VGPU_ROK_OK, "ok nodata");
    rok_step(APU_VGPU_ROK_FAULT, "write again");
    fail_rd = 1'b1;
    rol_step(APU_VGPU_ROL_FAULT, "bad read");
    scene_fence = 1'b1;
    rol_step(APU_VGPU_ROL_FAULT, "scene fence");
    no_flag = 1'b1;
    rol_step(APU_VGPU_ROL_FAULT, "no flag");
    rol_step(APU_VGPU_ROL_OK, "echo fence");
    rol_step(APU_VGPU_ROL_FAULT, "read again");
    rwx.rsp_addr = APU_VGPU_RSP_ADDR;
    roy_step(APU_VGPU_ROY_FAULT, "check scene dest");
    check("check rejected", !roy.valid);
    good_in();
    roy_step(APU_VGPU_ROY_OK, "check fence");
    check("fence checked", roy.valid && roy.fence == 64'd2 &&
          roy.resp == VGPU_RESP_OK_NODATA);
    roy_step(APU_VGPU_ROY_FAULT, "check again");
    check("check stays", roy.fence == rok.fence);

    pulse_reset();
    check("reset clears", rok == '0 && rol == '0 && roy == '0);
    rwx = '0;
    rok_step(APU_VGPU_ROK_EMPTY, "after reset");
    good_in();
    rok_step(APU_VGPU_ROK_OK, "nodata after reset");

    if (errors != 0) $fatal(1, "APU vgpu rok errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_rok cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
