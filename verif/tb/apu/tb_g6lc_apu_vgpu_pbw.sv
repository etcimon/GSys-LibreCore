// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_pbw;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_ocx_t ocx;
  apu_vgpu_cxr_t cxr;
  logic pbw_req = 0, pbw_rdy, pbw_cpl_v, pbw_cpl_r = 0;
  apu_vgpu_pbw_cpl_t pbw_cpl;
  apu_vgpu_pbw_t pbw;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, wr_seen = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic pbr_req = 0, pbr_rdy, pbr_cpl_v, pbr_cpl_r = 0;
  apu_vgpu_pbr_cpl_t pbr_cpl;
  apu_vgpu_pbr_t pbr;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic [7:0] b0 = 0;
  logic pbx_req = 0, pbx_rdy, pbx_cpl_v, pbx_cpl_r = 0;
  apu_vgpu_pbx_cpl_t pbx_cpl, off_cpl;
  apu_vgpu_pbx_t pbx, off_pbx;
  logic off_rdy, off_v;
  logic fail_wr = 0, fail_rd = 0, swap_lanes = 0, clear_lane = 0;
  logic order_bad = 0, data_bad = 0, rd_order = 0;
  logic [255:0] stored = 0;
  logic stored_v = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  int nwrite = 0, nread = 0;

  localparam logic [255:0] SampleBeat =
      {192'b0, APU_VGPU_FTX_NEIGHBOR, APU_VGPU_FTX_ORIGIN};

  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;
  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_pbw #(.Enable(1'b1)) i_pbw (
    .clk_i(clk), .rst_ni, .ocx_i(ocx), .cxr_i(cxr),
    .req_valid_i(pbw_req), .req_ready_o(pbw_rdy),
    .cpl_valid_o(pbw_cpl_v), .cpl_ready_i(pbw_cpl_r), .cpl_o(pbw_cpl), .pbw_o(pbw),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_pbr #(.Enable(1'b1)) i_pbr (
    .clk_i(clk), .rst_ni, .pbw_i(pbw), .ocx_i(ocx), .cxr_i(cxr),
    .req_valid_i(pbr_req), .req_ready_o(pbr_rdy),
    .cpl_valid_o(pbr_cpl_v), .cpl_ready_i(pbr_cpl_r), .cpl_o(pbr_cpl), .pbr_o(pbr),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_pbx #(.Enable(1'b1)) i_pbx (
    .clk_i(clk), .rst_ni, .pbr_i(pbr), .b0_i(b0),
    .req_valid_i(pbx_req), .req_ready_o(pbx_rdy),
    .cpl_valid_o(pbx_cpl_v), .cpl_ready_i(pbx_cpl_r), .cpl_o(pbx_cpl), .pbx_o(pbx)
  );
  g6lc_apu_vgpu_pbx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .pbr_i(pbr), .b0_i(b0),
    .req_valid_i(pbx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(pbx_cpl_r), .cpl_o(off_cpl), .pbx_o(off_pbx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu pbw timeout case=%0d", cases); end

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
      if (wr_addr != APU_VGPU_PBW_ADDR ||
          wr_len != 32'(APU_VGPU_BEAT_BYTES)) order_bad <= 1'b1;
      if (wr_data != SampleBeat) data_bad <= 1'b1;
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
      beat = stored_v ? stored : 256'b0;
      if (swap_lanes) beat = {192'b0, beat[31:0], beat[63:32]};
      if (clear_lane) beat[31:0] = APU_VGPU_CLEAR_WORD;
      if (rd_addr != APU_VGPU_PBW_ADDR ||
          rd_len != 32'(APU_VGPU_BEAT_BYTES)) rd_order <= 1'b1;
      rd_seen <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat;
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      swap_lanes <= 1'b0;
      clear_lane <= 1'b0;
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
    ocx = '0;
    ocx.valid = 1'b1;
    ocx.format = APU_VIRGL_FMT_B8G8R8X8;
    ocx.off0 = APU_VGPU_ACW_AT0;
    ocx.off1 = APU_VGPU_ACW_AT1;
    ocx.x0 = 7'd0;
    ocx.x1 = 7'd1;
    ocx.b0 = 8'h00;
    ocx.origin = APU_VGPU_FTX_ORIGIN;
    ocx.neighbor = APU_VGPU_FTX_NEIGHBOR;
    cxr = '0;
    cxr.valid = 1'b1;
    cxr.width = 16'd640;
    cxr.height = 16'd480;
    b0 = 8'h00;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_pbx == '0 &&
          off_cpl == '0);
  endtask

  task automatic pbw_step(input apu_vgpu_pbw_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!pbw_rdy) @(negedge clk);
    cases++;
    n0 = nwrite;
    pbw_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    pbw_req = 1'b0;
    while (!pbw_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), pbw_cpl.status == st);
    quiet();
    if (st == APU_VGPU_PBW_OK) begin
      check("color", pbw.valid && pbw.off0 == 16'd0 && pbw.off1 == 16'd4 &&
            pbw.x0 == 7'd0 && pbw.x1 == 7'd1 &&
            pbw.origin == APU_VGPU_FTX_ORIGIN &&
            pbw.neighbor == APU_VGPU_FTX_NEIGHBOR &&
            pbw.origin != APU_VGPU_CLEAR_WORD &&
            pbw.base == APU_VGPU_GBW_ADDR &&
            pbw.base != APU_VGPU_GPW_ADDR);
      check("one write", nwrite == n0 + 1 && !order_bad && !data_bad &&
            wr_seen == APU_VGPU_GBW_ADDR && wr_seen != APU_VGPU_GPW_ADDR &&
            wr_seen != APU_VGPU_ACW_ADDR);
    end else if (name == "bad write") begin
      check("one write failed", nwrite == n0 + 1 && !pbw.valid);
    end else check("no write", nwrite == n0);
    @(negedge clk);
    check($sformatf("%s held", name), pbw_cpl_v);
    pbw_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    pbw_cpl_r = 1'b0;
    while (pbw_cpl_v) @(negedge clk);
  endtask

  task automatic pbr_step(input apu_vgpu_pbr_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!pbr_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    pbr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    pbr_req = 1'b0;
    while (!pbr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), pbr_cpl.status == st);
    quiet();
    if (st == APU_VGPU_PBR_OK) begin
      check("read color", pbr.valid && pbr.origin == APU_VGPU_FTX_ORIGIN &&
            pbr.neighbor == APU_VGPU_FTX_NEIGHBOR && pbr.off0 == 16'd0 &&
            pbr.x0 == 7'd0 && pbr.base == APU_VGPU_GBW_ADDR &&
            pbr.base != APU_VGPU_GPW_ADDR);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_GBW_ADDR && rd_seen != APU_VGPU_GPW_ADDR);
    end else if (name == "bad read" || name == "clear lane" ||
                 name == "swapped lanes") begin
      check("one read failed", nread == n0 + 1 && !pbr.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), pbr_cpl_v);
    pbr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    pbr_cpl_r = 1'b0;
    while (pbr_cpl_v) @(negedge clk);
  endtask

  task automatic pbx_step(input apu_vgpu_pbx_status_e st, input string name);
    @(negedge clk);
    while (!pbx_rdy) @(negedge clk);
    cases++;
    pbx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    pbx_req = 1'b0;
    while (!pbx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), pbx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), pbx_cpl_v);
    pbx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    pbx_cpl_r = 1'b0;
    while (pbx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    pbw_req = 1'b0;
    pbr_req = 1'b0;
    pbx_req = 1'b0;
    pbw_cpl_r = 1'b0;
    pbr_cpl_r = 1'b0;
    pbx_cpl_r = 1'b0;
    wr_rsp_v = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    ocx = '0;
    cxr = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          pbw == '0 && pbr == '0 && pbx == '0);
    check("profiles keep the readback off",
          !ApuOff.PbwEn && !ApuOff.PbrEn && !ApuOff.PbxEn &&
          !ApuP1Transport.PbwEn && !ApuP1Transport.PbrEn &&
          !ApuP1Transport.PbxEn &&
          !ApuHarness.PbwEn && !ApuHarness.PbrEn && !ApuHarness.PbxEn &&
          !ApuSchedBoth.PbwEn && !ApuSchedBoth.PbrEn && !ApuSchedBoth.PbxEn &&
          !ApuBadVirglGrant.PbwEn && !ApuBadVirglGrant.PbrEn &&
          !ApuBadVirglGrant.PbxEn);
    cfg = ApuP1Transport;
    cfg.PbwEn = 1'b1;
    cfg.PbrEn = 1'b1;
    cfg.PbxEn = 1'b1;
    check("readback does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.PbwEn = 1'b1;
    cfg.PbrEn = 1'b1;
    cfg.PbxEn = 1'b1;
    check("readback does not legalize virgl", !apu_cfg_legal(cfg));
    check("readback address",
          APU_VGPU_PBW_ADDR == 64'h88030000 &&
          APU_VGPU_PBW_ADDR == APU_VGPU_GBW_ADDR &&
          APU_VGPU_PBW_ADDR != APU_VGPU_GPW_ADDR &&
          APU_VGPU_PBW_ADDR != APU_VGPU_ACW_ADDR &&
          APU_VGPU_FTX_ORIGIN != APU_VGPU_CLEAR_WORD);

    pbw_step(APU_VGPU_PBW_EMPTY, "color empty");
    pbr_step(APU_VGPU_PBR_EMPTY, "read empty");
    pbx_step(APU_VGPU_PBX_EMPTY, "order empty");
    good_in();
    cxr.height = 16'd64;
    pbw_step(APU_VGPU_PBW_FAULT, "bad scissor");
    good_in();
    ocx.origin = APU_VGPU_CLEAR_WORD;
    pbw_step(APU_VGPU_PBW_FAULT, "clear origin");
    good_in();
    ocx.neighbor = APU_VGPU_CLEAR_WORD;
    pbw_step(APU_VGPU_PBW_FAULT, "clear neighbor");
    good_in();
    ocx.b0 = APU_VGPU_CLEAR_R;
    pbw_step(APU_VGPU_PBW_FAULT, "clear red");
    good_in();
    fail_wr = 1'b1;
    pbw_step(APU_VGPU_PBW_FAULT, "bad write");
    good_in();
    pbw_step(APU_VGPU_PBW_OK, "color");
    pbw_step(APU_VGPU_PBW_FAULT, "color again");
    check("color stays", pbw.origin == APU_VGPU_FTX_ORIGIN &&
          pbw.base == APU_VGPU_GBW_ADDR);
    cxr.height = 16'd64;
    pbr_step(APU_VGPU_PBR_FAULT, "read scissor");
    check("read rejected", !pbr.valid);
    good_in();
    fail_rd = 1'b1;
    pbr_step(APU_VGPU_PBR_FAULT, "bad read");
    clear_lane = 1'b1;
    pbr_step(APU_VGPU_PBR_FAULT, "clear lane");
    swap_lanes = 1'b1;
    pbr_step(APU_VGPU_PBR_FAULT, "swapped lanes");
    pbr_step(APU_VGPU_PBR_OK, "read color");
    pbr_step(APU_VGPU_PBR_FAULT, "read again");
    check("read stays", pbr.origin == APU_VGPU_FTX_ORIGIN &&
          pbr.base == APU_VGPU_GBW_ADDR && pbr.base != APU_VGPU_GPW_ADDR);
    b0 = APU_VGPU_CLEAR_R;
    pbx_step(APU_VGPU_PBX_FAULT, "clear red first");
    check("clear red rejected", !pbx.valid);
    b0 = APU_VGPU_CLEAR_B;
    pbx_step(APU_VGPU_PBX_FAULT, "blue first");
    check("blue rejected", !pbx.valid);
    b0 = APU_VGPU_CLEAR_A;
    pbx_step(APU_VGPU_PBX_FAULT, "high byte first");
    check("high byte rejected", !pbx.valid);
    b0 = 8'h00;
    pbx_step(APU_VGPU_PBX_OK, "sample red first");
    check("sample red", pbx.valid && pbx.b0 == 8'h00 && pbx.off0 == 16'd0 &&
          pbx.x0 == 7'd0 && pbx.origin == APU_VGPU_FTX_ORIGIN &&
          pbx.origin != APU_VGPU_CLEAR_WORD);
    pbx_step(APU_VGPU_PBX_FAULT, "order again");
    check("order stays", pbx.b0 == 8'h00 && pbx.origin == APU_VGPU_FTX_ORIGIN);

    pulse_reset();
    check("reset clears", pbw == '0 && pbr == '0 && pbx == '0);
    ocx = '0;
    cxr = '0;
    pbw_step(APU_VGPU_PBW_EMPTY, "after reset");
    good_in();
    pbw_step(APU_VGPU_PBW_OK, "color after reset");

    if (errors != 0) $fatal(1, "APU vgpu pbw errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_pbw cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
