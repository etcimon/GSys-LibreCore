// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_acw;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_lnr_t lnr;
  apu_vgpu_tbn_t tbn;
  apu_vgpu_fbr_t fbr;
  apu_vgpu_cxr_t cxr;
  logic acw_req = 0, acw_rdy, acw_cpl_v, acw_cpl_r = 0;
  apu_vgpu_acw_cpl_t acw_cpl;
  apu_vgpu_acw_t acw;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, wr_seen = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic acr_req = 0, acr_rdy, acr_cpl_v, acr_cpl_r = 0;
  apu_vgpu_acr_cpl_t acr_cpl;
  apu_vgpu_acr_t acr;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic [7:0] b0 = 0;
  logic acx_req = 0, acx_rdy, acx_cpl_v, acx_cpl_r = 0;
  apu_vgpu_acx_cpl_t acx_cpl, off_cpl;
  apu_vgpu_acx_t acx, off_acx;
  logic off_rdy, off_v;
  logic fail_wr = 0, fail_rd = 0, swap_lanes = 0, clear_lane = 0;
  logic order_bad = 0, data_bad = 0, rd_order = 0;
  logic [255:0] stored = 0;
  logic stored_v = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  int nwrite = 0, wr_base = 0, nread = 0, rd_base = 0;

  localparam logic [31:0] Origin = 32'hA500_0000;
  localparam logic [31:0] Neighbor = 32'hD200_8000;
  localparam logic [255:0] SampleBeat = {192'b0, Neighbor, Origin};

  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;
  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_acw #(.Enable(1'b1)) i_acw (
    .clk_i(clk), .rst_ni, .lnr_i(lnr), .tbn_i(tbn), .fbr_i(fbr), .cxr_i(cxr),
    .req_valid_i(acw_req), .req_ready_o(acw_rdy),
    .cpl_valid_o(acw_cpl_v), .cpl_ready_i(acw_cpl_r), .cpl_o(acw_cpl), .acw_o(acw),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_acr #(.Enable(1'b1)) i_acr (
    .clk_i(clk), .rst_ni, .acw_i(acw), .lnr_i(lnr), .cxr_i(cxr),
    .req_valid_i(acr_req), .req_ready_o(acr_rdy),
    .cpl_valid_o(acr_cpl_v), .cpl_ready_i(acr_cpl_r), .cpl_o(acr_cpl), .acr_o(acr),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_acx #(.Enable(1'b1)) i_acx (
    .clk_i(clk), .rst_ni, .acr_i(acr), .b0_i(b0),
    .req_valid_i(acx_req), .req_ready_o(acx_rdy),
    .cpl_valid_o(acx_cpl_v), .cpl_ready_i(acx_cpl_r), .cpl_o(acx_cpl), .acx_o(acx)
  );
  g6lc_apu_vgpu_acx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .acr_i(acr), .b0_i(b0),
    .req_valid_i(acx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(acx_cpl_r), .cpl_o(off_cpl), .acx_o(off_acx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu acw timeout case=%0d", cases); end

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
      if (wr_addr != APU_VGPU_ACW_ADDR ||
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
      if (clear_lane) beat[63:32] = APU_VGPU_CLEAR_WORD;
      if (rd_addr != APU_VGPU_ACW_ADDR ||
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
    lnr = '0;
    lnr.valid = 1'b1;
    lnr.origin = Origin;
    lnr.neighbor = Neighbor;
    tbn = '0;
    tbn.valid = 1'b1;
    tbn.resource_id = APU_VIRGL_RES_SCAN;
    tbn.view = APU_VIRGL_SV_HANDLE;
    tbn.sampler = APU_VIRGL_SS_HANDLE;
    fbr = '0;
    fbr.valid = 1'b1;
    fbr.nr_cbufs = 32'd1;
    fbr.surface = APU_VIRGL_SURFACE_HANDLE;
    fbr.word = APU_VGPU_CLEAR_WORD;
    cxr = '0;
    cxr.valid = 1'b1;
    cxr.width = 16'd640;
    cxr.height = 16'd480;
    b0 = Neighbor[7:0];
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_acx == '0 &&
          off_cpl == '0);
  endtask

  task automatic acw_step(input apu_vgpu_acw_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!acw_rdy) @(negedge clk);
    cases++;
    n0 = nwrite;
    wr_base = nwrite;
    acw_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    acw_req = 1'b0;
    while (!acw_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), acw_cpl.status == st);
    quiet();
    if (st == APU_VGPU_ACW_OK) begin
      check("color", acw.valid && acw.off0 == 16'd0 && acw.off1 == 16'd4 &&
            acw.x0 == 7'd0 && acw.x1 == 7'd1 &&
            acw.origin == Origin && acw.neighbor == Neighbor &&
            acw.neighbor != APU_VGPU_CLEAR_WORD &&
            acw.base == APU_VGPU_ACW_ADDR);
      check("one write", nwrite == n0 + 1 && !order_bad && !data_bad &&
            wr_seen == APU_VGPU_ACW_ADDR && wr_seen != APU_VGPU_GPW_ADDR &&
            wr_seen != APU_VGPU_GBW_ADDR &&
            wr_seen != {32'h0, APU_VGPU_CEIL_RB});
    end else if (name == "bad write") begin
      check("one write failed", nwrite == n0 + 1 && !acw.valid);
    end else check("no write", nwrite == n0);
    @(negedge clk);
    check($sformatf("%s held", name), acw_cpl_v);
    acw_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    acw_cpl_r = 1'b0;
    while (acw_cpl_v) @(negedge clk);
  endtask

  task automatic acr_step(input apu_vgpu_acr_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!acr_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    rd_base = nread;
    acr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    acr_req = 1'b0;
    while (!acr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), acr_cpl.status == st);
    quiet();
    if (st == APU_VGPU_ACR_OK) begin
      check("read color", acr.valid && acr.origin == Origin &&
            acr.neighbor == Neighbor && acr.off1 == 16'd4 &&
            acr.x1 == 7'd1 && acr.base == APU_VGPU_ACW_ADDR);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_ACW_ADDR && rd_seen != APU_VGPU_GPW_ADDR &&
            rd_seen != APU_VGPU_GBW_ADDR);
    end else if (name == "bad read" || name == "clear lane" ||
                 name == "swapped lanes") begin
      check("one read failed", nread == n0 + 1 && !acr.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), acr_cpl_v);
    acr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    acr_cpl_r = 1'b0;
    while (acr_cpl_v) @(negedge clk);
  endtask

  task automatic acx_step(input apu_vgpu_acx_status_e st, input string name);
    @(negedge clk);
    while (!acx_rdy) @(negedge clk);
    cases++;
    acx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    acx_req = 1'b0;
    while (!acx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), acx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), acx_cpl_v);
    acx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    acx_cpl_r = 1'b0;
    while (acx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    acw_req = 1'b0;
    acr_req = 1'b0;
    acx_req = 1'b0;
    acw_cpl_r = 1'b0;
    acr_cpl_r = 1'b0;
    acx_cpl_r = 1'b0;
    wr_rsp_v = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    lnr = '0;
    tbn = '0;
    fbr = '0;
    cxr = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          acw == '0 && acr == '0 && acx == '0);
    check("profiles keep the sample off",
          !ApuOff.AcwEn && !ApuOff.AcrEn && !ApuOff.AcxEn &&
          !ApuP1Transport.AcwEn && !ApuP1Transport.AcrEn &&
          !ApuP1Transport.AcxEn &&
          !ApuHarness.AcwEn && !ApuHarness.AcrEn && !ApuHarness.AcxEn &&
          !ApuSchedBoth.AcwEn && !ApuSchedBoth.AcrEn && !ApuSchedBoth.AcxEn &&
          !ApuBadVirglGrant.AcwEn && !ApuBadVirglGrant.AcrEn &&
          !ApuBadVirglGrant.AcxEn);
    cfg = ApuP1Transport;
    cfg.AcwEn = 1'b1;
    cfg.AcrEn = 1'b1;
    cfg.AcxEn = 1'b1;
    check("sample does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.AcwEn = 1'b1;
    cfg.AcrEn = 1'b1;
    cfg.AcxEn = 1'b1;
    check("sample does not legalize virgl", !apu_cfg_legal(cfg));
    check("sample address",
          APU_VGPU_ACW_AT0 == 16'd0 &&
          APU_VGPU_ACW_AT1 == 16'd4 &&
          (16'd1 << 2) == APU_VGPU_ACW_AT1 &&
          APU_VGPU_ACW_ADDR == 64'h0000_0000_8805_0000 &&
          APU_VGPU_ACW_ADDR != APU_VGPU_GPW_ADDR &&
          APU_VGPU_ACW_ADDR != APU_VGPU_GBW_ADDR &&
          APU_VGPU_ACW_ADDR != {32'h0, APU_VGPU_CEIL_RB} &&
          Neighbor != APU_VGPU_CLEAR_WORD &&
          Origin != Neighbor &&
          Neighbor[7:0] != APU_VGPU_CLEAR_R);

    acw_step(APU_VGPU_ACW_EMPTY, "color empty");
    acr_step(APU_VGPU_ACR_EMPTY, "read empty");
    acx_step(APU_VGPU_ACX_EMPTY, "order empty");
    good_in();
    cxr.height = 16'd64;
    acw_step(APU_VGPU_ACW_FAULT, "bad scissor");
    good_in();
    lnr.neighbor = APU_VGPU_CLEAR_WORD;
    acw_step(APU_VGPU_ACW_FAULT, "clear neighbor");
    good_in();
    lnr.origin = APU_VGPU_CLEAR_WORD;
    acw_step(APU_VGPU_ACW_FAULT, "clear origin");
    good_in();
    lnr.origin = Neighbor;
    acw_step(APU_VGPU_ACW_FAULT, "same words");
    good_in();
    tbn.resource_id = 32'd4;
    acw_step(APU_VGPU_ACW_FAULT, "wrong resource");
    good_in();
    fail_wr = 1'b1;
    acw_step(APU_VGPU_ACW_FAULT, "bad write");
    good_in();
    acw_step(APU_VGPU_ACW_OK, "color");
    acw_step(APU_VGPU_ACW_FAULT, "color again");
    check("color stays", acw.origin == Origin && acw.neighbor == Neighbor &&
          acw.off1 == 16'd4 && acw.x1 == 7'd1);
    cxr.height = 16'd64;
    acr_step(APU_VGPU_ACR_FAULT, "read scissor");
    check("read rejected", !acr.valid);
    good_in();
    fail_rd = 1'b1;
    acr_step(APU_VGPU_ACR_FAULT, "bad read");
    clear_lane = 1'b1;
    acr_step(APU_VGPU_ACR_FAULT, "clear lane");
    swap_lanes = 1'b1;
    acr_step(APU_VGPU_ACR_FAULT, "swapped lanes");
    acr_step(APU_VGPU_ACR_OK, "read color");
    acr_step(APU_VGPU_ACR_FAULT, "read again");
    check("read stays", acr.origin == Origin && acr.neighbor == Neighbor &&
          acr.off1 == 16'd4);
    b0 = APU_VGPU_CLEAR_R;
    acx_step(APU_VGPU_ACX_FAULT, "clear red first");
    check("clear red rejected", !acx.valid);
    b0 = APU_VGPU_CLEAR_B;
    acx_step(APU_VGPU_ACX_FAULT, "blue first");
    check("blue rejected", !acx.valid);
    b0 = APU_VGPU_CLEAR_A;
    acx_step(APU_VGPU_ACX_FAULT, "high byte first");
    check("high byte rejected", !acx.valid);
    b0 = Neighbor[7:0];
    acx_step(APU_VGPU_ACX_OK, "sample red first");
    check("sample red", acx.valid && acx.b0 == 8'h00 && acx.off1 == 16'd4 &&
          acx.x1 == 7'd1 && acx.neighbor == Neighbor);
    acx_step(APU_VGPU_ACX_FAULT, "order again");
    check("order stays", acx.b0 == 8'h00 && acx.off1 == 16'd4);

    pulse_reset();
    check("reset clears", acw == '0 && acr == '0 && acx == '0);
    lnr = '0;
    tbn = '0;
    fbr = '0;
    cxr = '0;
    acw_step(APU_VGPU_ACW_EMPTY, "after reset");
    acr_step(APU_VGPU_ACR_EMPTY, "read after reset");
    acx_step(APU_VGPU_ACX_EMPTY, "order after reset");

    if (errors != 0) $fatal(1, "APU vgpu acw errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_acw cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
