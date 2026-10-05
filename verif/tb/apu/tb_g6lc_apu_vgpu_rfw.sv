// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_rfw;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_rax_t rax;
  apu_vgpu_tfx_t tfx;
  apu_vgpu_rpw_t rpw;
  logic rfw_req = 0, rfw_rdy, rfw_cpl_v, rfw_cpl_r = 0;
  apu_vgpu_rfw_cpl_t rfw_cpl;
  apu_vgpu_rfw_t rfw;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, wr_seen = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic rfr_req = 0, rfr_rdy, rfr_cpl_v, rfr_cpl_r = 0;
  apu_vgpu_rfr_cpl_t rfr_cpl;
  apu_vgpu_rfr_t rfr;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic rfx_req = 0, rfx_rdy, rfx_cpl_v, rfx_cpl_r = 0;
  apu_vgpu_rfx_cpl_t rfx_cpl, off_cpl;
  apu_vgpu_rfx_t rfx, off_rfx;
  logic off_rdy, off_v;
  logic fail_wr = 0, fail_rd = 0, scene_fence = 0, no_flag = 0;
  logic order_bad = 0, data_bad = 0, rd_order = 0;
  logic [255:0] stored = 0;
  logic stored_v = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0, nwrite = 0, nread = 0;

  localparam logic [31:0] Origin = 32'hA500_0000;
  localparam logic [31:0] Neighbor = 32'hD200_8000;
  localparam logic [255:0] RespBeat = {64'h0, 32'h0, APU_VGPU_CTX_ID,
                                       APU_VGPU_RFW_FENCE, VGPU_FLAG_FENCE,
                                       VGPU_RESP_OK_NODATA};

  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;
  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_rfw #(.Enable(1'b1)) i_rfw (
    .clk_i(clk), .rst_ni, .rax_i(rax), .tfx_i(tfx), .rpw_i(rpw),
    .req_valid_i(rfw_req), .req_ready_o(rfw_rdy),
    .cpl_valid_o(rfw_cpl_v), .cpl_ready_i(rfw_cpl_r), .cpl_o(rfw_cpl), .rfw_o(rfw),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_rfr #(.Enable(1'b1)) i_rfr (
    .clk_i(clk), .rst_ni, .rfw_i(rfw), .rax_i(rax),
    .req_valid_i(rfr_req), .req_ready_o(rfr_rdy),
    .cpl_valid_o(rfr_cpl_v), .cpl_ready_i(rfr_cpl_r), .cpl_o(rfr_cpl), .rfr_o(rfr),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_rfx #(.Enable(1'b1)) i_rfx (
    .clk_i(clk), .rst_ni, .rfr_i(rfr), .rfw_i(rfw),
    .req_valid_i(rfx_req), .req_ready_o(rfx_rdy),
    .cpl_valid_o(rfx_cpl_v), .cpl_ready_i(rfx_cpl_r), .cpl_o(rfx_cpl), .rfx_o(rfx)
  );
  g6lc_apu_vgpu_rfx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .rfr_i(rfr), .rfw_i(rfw),
    .req_valid_i(rfx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(rfx_cpl_r), .cpl_o(off_cpl), .rfx_o(off_rfx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu rfw timeout case=%0d", cases); end

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
    rax = '0;
    rax.valid = 1'b1;
    rax.length = APU_VGPU_GBD_BYTES;
    rax.addr = APU_VGPU_RPW_DST;
    rax.resource_id = APU_VIRGL_RES_RT;
    tfx = '0;
    tfx.valid = 1'b1;
    tfx.stride = APU_VGPU_TFB_STRIDE;
    tfx.x = 16'd0;
    tfx.y = 16'd0;
    tfx.res_w = APU_VGPU_RT_W;
    rpw = '0;
    rpw.valid = 1'b1;
    rpw.origin = Origin;
    rpw.neighbor = Neighbor;
    rpw.beats = APU_VGPU_GPW_BEATS;
    rpw.src = APU_VGPU_CSW_DST;
    rpw.dst = APU_VGPU_RPW_DST;
    rpw.cmd = VGPU_CMD_TRANSFER_FROM_HOST_3D;
    rpw.resource_id = APU_VIRGL_RES_RT;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_rfx == '0 &&
          off_cpl == '0);
  endtask

  task automatic rfw_step(input apu_vgpu_rfw_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!rfw_rdy) @(negedge clk);
    cases++;
    n0 = nwrite;
    rfw_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rfw_req = 1'b0;
    while (!rfw_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rfw_cpl.status == st);
    quiet();
    if (st == APU_VGPU_RFW_OK) begin
      check("response", rfw.valid && rfw.resp == VGPU_RESP_OK_NODATA &&
            rfw.flags == VGPU_FLAG_FENCE && rfw.fence == APU_VGPU_RFW_FENCE &&
            rfw.fence != APU_VGPU_SCENE_FENCE &&
            rfw.addr == APU_VGPU_RFW_ADDR && rfw.addr != APU_VGPU_RSP_ADDR);
      check("one write", nwrite == n0 + 1 && !order_bad && !data_bad &&
            wr_seen == APU_VGPU_RFW_ADDR);
    end else if (name == "bad write") begin
      check("one write failed", nwrite == n0 + 1 && !rfw.valid);
    end else check("no write", nwrite == n0);
    @(negedge clk);
    check($sformatf("%s held", name), rfw_cpl_v);
    rfw_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rfw_cpl_r = 1'b0;
    while (rfw_cpl_v) @(negedge clk);
  endtask

  task automatic rfr_step(input apu_vgpu_rfr_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!rfr_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    rfr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rfr_req = 1'b0;
    while (!rfr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rfr_cpl.status == st);
    quiet();
    if (st == APU_VGPU_RFR_OK) begin
      check("echo", rfr.valid && rfr.fence == APU_VGPU_RFW_FENCE &&
            rfr.fence != APU_VGPU_SCENE_FENCE &&
            rfr.flags == VGPU_FLAG_FENCE &&
            rfr.resp == VGPU_RESP_OK_NODATA &&
            rfr.addr == APU_VGPU_RFW_ADDR);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_RFW_ADDR);
    end else if (name == "bad read" || name == "scene fence" ||
                 name == "no flag") begin
      check("one read failed", nread == n0 + 1 && !rfr.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), rfr_cpl_v);
    rfr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rfr_cpl_r = 1'b0;
    while (rfr_cpl_v) @(negedge clk);
  endtask

  task automatic rfx_step(input apu_vgpu_rfx_status_e st, input string name);
    @(negedge clk);
    while (!rfx_rdy) @(negedge clk);
    cases++;
    rfx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rfx_req = 1'b0;
    while (!rfx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rfx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), rfx_cpl_v);
    rfx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rfx_cpl_r = 1'b0;
    while (rfx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    rfw_req = 1'b0;
    rfr_req = 1'b0;
    rfx_req = 1'b0;
    rfw_cpl_r = 1'b0;
    rfr_cpl_r = 1'b0;
    rfx_cpl_r = 1'b0;
    wr_rsp_v = 1'b0;
    rd_rsp_v = 1'b0;
    stored_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    rax = '0;
    tfx = '0;
    rpw = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          rfw == '0 && rfr == '0 && rfx == '0);
    check("profiles keep the fence off",
          !ApuOff.RfwEn && !ApuOff.RfrEn && !ApuOff.RfxEn &&
          !ApuP1Transport.RfwEn && !ApuP1Transport.RfrEn &&
          !ApuP1Transport.RfxEn &&
          !ApuHarness.RfwEn && !ApuHarness.RfrEn && !ApuHarness.RfxEn &&
          !ApuSchedBoth.RfwEn && !ApuSchedBoth.RfrEn && !ApuSchedBoth.RfxEn &&
          !ApuBadVirglGrant.RfwEn && !ApuBadVirglGrant.RfrEn &&
          !ApuBadVirglGrant.RfxEn);
    cfg = ApuP1Transport;
    cfg.RfwEn = 1'b1;
    cfg.RfrEn = 1'b1;
    cfg.RfxEn = 1'b1;
    check("fence does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.RfwEn = 1'b1;
    cfg.RfrEn = 1'b1;
    cfg.RfxEn = 1'b1;
    check("fence does not legalize virgl", !apu_cfg_legal(cfg));
    check("known fence",
          APU_VGPU_RFW_ADDR != APU_VGPU_RSP_ADDR &&
          APU_VGPU_RFW_ADDR != APU_VGPU_RAB_CMD &&
          APU_VGPU_RFW_FENCE != APU_VGPU_SCENE_FENCE &&
          APU_VGPU_RFW_FENCE == 64'd2 &&
          VGPU_RESP_HDR_BYTES == 32'd24);

    rfw_step(APU_VGPU_RFW_EMPTY, "write empty");
    rfr_step(APU_VGPU_RFR_EMPTY, "read empty");
    rfx_step(APU_VGPU_RFX_EMPTY, "fence empty");
    good_in();
    fail_wr = 1'b1;
    rfw_step(APU_VGPU_RFW_FAULT, "bad write");
    rfw_step(APU_VGPU_RFW_OK, "ok nodata");
    rfw_step(APU_VGPU_RFW_FAULT, "write again");
    fail_rd = 1'b1;
    rfr_step(APU_VGPU_RFR_FAULT, "bad read");
    scene_fence = 1'b1;
    rfr_step(APU_VGPU_RFR_FAULT, "scene fence");
    no_flag = 1'b1;
    rfr_step(APU_VGPU_RFR_FAULT, "no flag");
    rfr_step(APU_VGPU_RFR_OK, "echo fence");
    rfr_step(APU_VGPU_RFR_FAULT, "read again");
    rfx_step(APU_VGPU_RFX_OK, "transfer fence");
    check("transfer fence", rfx.valid && rfx.fence == 64'd2 &&
          rfx.fence != APU_VGPU_SCENE_FENCE && rfx.flags == VGPU_FLAG_FENCE &&
          rfx.resp == VGPU_RESP_OK_NODATA);
    rfx_step(APU_VGPU_RFX_FAULT, "fence again");
    check("fence stays", rfx.fence == APU_VGPU_RFW_FENCE);

    pulse_reset();
    check("reset clears", rfw == '0 && rfr == '0 && rfx == '0);
    rax = '0;
    tfx = '0;
    rpw = '0;
    rfw_step(APU_VGPU_RFW_EMPTY, "after reset");
    good_in();
    rfw_step(APU_VGPU_RFW_OK, "write after reset");

    if (errors != 0) $fatal(1, "APU vgpu rfw errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_rfw cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
