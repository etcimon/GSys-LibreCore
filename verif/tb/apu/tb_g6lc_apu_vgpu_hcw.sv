// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_hcw;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_gtr_t gtr;
  apu_vgpu_cxr_t cxr;
  logic hcw_req = 0, hcw_rdy, hcw_cpl_v, hcw_cpl_r = 0;
  apu_vgpu_hcw_cpl_t hcw_cpl;
  apu_vgpu_hcw_t hcw;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, wr_seen = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic hcr_req = 0, hcr_rdy, hcr_cpl_v, hcr_cpl_r = 0;
  apu_vgpu_hcr_cpl_t hcr_cpl;
  apu_vgpu_hcr_t hcr;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic [7:0] b0 = 0;
  logic hcx_req = 0, hcx_rdy, hcx_cpl_v, hcx_cpl_r = 0;
  apu_vgpu_hcx_cpl_t hcx_cpl, off_cpl;
  apu_vgpu_hcx_t hcx, off_hcx;
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

  g6lc_apu_vgpu_hcw #(.Enable(1'b1)) i_hcw (
    .clk_i(clk), .rst_ni, .gtr_i(gtr), .cxr_i(cxr),
    .req_valid_i(hcw_req), .req_ready_o(hcw_rdy),
    .cpl_valid_o(hcw_cpl_v), .cpl_ready_i(hcw_cpl_r), .cpl_o(hcw_cpl), .hcw_o(hcw),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_hcr #(.Enable(1'b1)) i_hcr (
    .clk_i(clk), .rst_ni, .hcw_i(hcw), .gtr_i(gtr), .cxr_i(cxr),
    .req_valid_i(hcr_req), .req_ready_o(hcr_rdy),
    .cpl_valid_o(hcr_cpl_v), .cpl_ready_i(hcr_cpl_r), .cpl_o(hcr_cpl), .hcr_o(hcr),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_hcx #(.Enable(1'b1)) i_hcx (
    .clk_i(clk), .rst_ni, .hcr_i(hcr), .b0_i(b0),
    .req_valid_i(hcx_req), .req_ready_o(hcx_rdy),
    .cpl_valid_o(hcx_cpl_v), .cpl_ready_i(hcx_cpl_r), .cpl_o(hcx_cpl), .hcx_o(hcx)
  );
  g6lc_apu_vgpu_hcx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .hcr_i(hcr), .b0_i(b0),
    .req_valid_i(hcx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(hcx_cpl_r), .cpl_o(off_cpl), .hcx_o(off_hcx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu hcw timeout case=%0d", cases); end

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
      if (wr_addr != APU_VGPU_RPW_DST ||
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
      if (rd_addr != APU_VGPU_RPW_DST ||
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
    gtr = '0;
    gtr.valid = 1'b1;
    gtr.refused = 1'b0;
    gtr.origin = APU_VGPU_FTX_ORIGIN;
    gtr.neighbor = APU_VGPU_FTX_NEIGHBOR;
    gtr.used_idx = APU_VGPU_TUW_IDXV;
    cxr = '0;
    cxr.valid = 1'b1;
    cxr.width = 16'd640;
    cxr.height = 16'd480;
    b0 = 8'h00;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_hcx == '0 &&
          off_cpl == '0);
  endtask

  task automatic hcw_step(input apu_vgpu_hcw_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!hcw_rdy) @(negedge clk);
    cases++;
    n0 = nwrite;
    hcw_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    hcw_req = 1'b0;
    while (!hcw_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), hcw_cpl.status == st);
    quiet();
    if (st == APU_VGPU_HCW_OK) begin
      check("color", hcw.valid && hcw.off0 == 16'd0 && hcw.off1 == 16'd4 &&
            hcw.x0 == 7'd0 && hcw.x1 == 7'd1 &&
            hcw.origin == APU_VGPU_FTX_ORIGIN &&
            hcw.neighbor == APU_VGPU_FTX_NEIGHBOR &&
            hcw.origin != APU_VGPU_CLEAR_WORD &&
            hcw.base == APU_VGPU_RPW_DST &&
            hcw.base != APU_VGPU_ACW_ADDR);
      check("one write", nwrite == n0 + 1 && !order_bad && !data_bad &&
            wr_seen == APU_VGPU_RPW_DST && wr_seen != APU_VGPU_ACW_ADDR &&
            wr_seen != APU_VGPU_GBW_ADDR);
    end else if (name == "bad write") begin
      check("one write failed", nwrite == n0 + 1 && !hcw.valid);
    end else check("no write", nwrite == n0);
    @(negedge clk);
    check($sformatf("%s held", name), hcw_cpl_v);
    hcw_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    hcw_cpl_r = 1'b0;
    while (hcw_cpl_v) @(negedge clk);
  endtask

  task automatic hcr_step(input apu_vgpu_hcr_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!hcr_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    hcr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    hcr_req = 1'b0;
    while (!hcr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), hcr_cpl.status == st);
    quiet();
    if (st == APU_VGPU_HCR_OK) begin
      check("read color", hcr.valid && hcr.origin == APU_VGPU_FTX_ORIGIN &&
            hcr.neighbor == APU_VGPU_FTX_NEIGHBOR && hcr.off0 == 16'd0 &&
            hcr.x0 == 7'd0 && hcr.base == APU_VGPU_RPW_DST &&
            hcr.base != APU_VGPU_ACW_ADDR);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_RPW_DST && rd_seen != APU_VGPU_ACW_ADDR);
    end else if (name == "bad read" || name == "clear lane" ||
                 name == "swapped lanes") begin
      check("one read failed", nread == n0 + 1 && !hcr.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), hcr_cpl_v);
    hcr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    hcr_cpl_r = 1'b0;
    while (hcr_cpl_v) @(negedge clk);
  endtask

  task automatic hcx_step(input apu_vgpu_hcx_status_e st, input string name);
    @(negedge clk);
    while (!hcx_rdy) @(negedge clk);
    cases++;
    hcx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    hcx_req = 1'b0;
    while (!hcx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), hcx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), hcx_cpl_v);
    hcx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    hcx_cpl_r = 1'b0;
    while (hcx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    hcw_req = 1'b0;
    hcr_req = 1'b0;
    hcx_req = 1'b0;
    hcw_cpl_r = 1'b0;
    hcr_cpl_r = 1'b0;
    hcx_cpl_r = 1'b0;
    wr_rsp_v = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    gtr = '0;
    cxr = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          hcw == '0 && hcr == '0 && hcx == '0);
    check("profiles keep the window off",
          !ApuOff.HcwEn && !ApuOff.HcrEn && !ApuOff.HcxEn &&
          !ApuP1Transport.HcwEn && !ApuP1Transport.HcrEn &&
          !ApuP1Transport.HcxEn &&
          !ApuHarness.HcwEn && !ApuHarness.HcrEn && !ApuHarness.HcxEn &&
          !ApuSchedBoth.HcwEn && !ApuSchedBoth.HcrEn && !ApuSchedBoth.HcxEn &&
          !ApuBadVirglGrant.HcwEn && !ApuBadVirglGrant.HcrEn &&
          !ApuBadVirglGrant.HcxEn);
    cfg = ApuP1Transport;
    cfg.HcwEn = 1'b1;
    cfg.HcrEn = 1'b1;
    cfg.HcxEn = 1'b1;
    check("window does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.HcwEn = 1'b1;
    cfg.HcrEn = 1'b1;
    cfg.HcxEn = 1'b1;
    check("window does not legalize virgl", !apu_cfg_legal(cfg));
    check("window address",
          APU_VGPU_RPW_DST == 64'h88070000 &&
          APU_VGPU_RPW_DST != APU_VGPU_OCW_ADDR &&
          APU_VGPU_RPW_DST != APU_VGPU_ACW_ADDR &&
          APU_VGPU_TUW_IDXV != APU_VGPU_QSU_IDXV &&
          APU_VGPU_FTX_ORIGIN != APU_VGPU_CLEAR_WORD &&
          APU_VGPU_FTX_ORIGIN != APU_VGPU_FTX_NEIGHBOR);

    hcw_step(APU_VGPU_HCW_EMPTY, "color empty");
    hcr_step(APU_VGPU_HCR_EMPTY, "read empty");
    hcx_step(APU_VGPU_HCX_EMPTY, "order empty");
    good_in();
    cxr.height = 16'd64;
    hcw_step(APU_VGPU_HCW_FAULT, "bad scissor");
    good_in();
    gtr.refused = 1'b1;
    hcw_step(APU_VGPU_HCW_FAULT, "refused");
    good_in();
    gtr.origin = APU_VGPU_CLEAR_WORD;
    hcw_step(APU_VGPU_HCW_FAULT, "clear origin");
    good_in();
    gtr.neighbor = APU_VGPU_CLEAR_WORD;
    hcw_step(APU_VGPU_HCW_FAULT, "clear neighbor");
    good_in();
    fail_wr = 1'b1;
    hcw_step(APU_VGPU_HCW_FAULT, "bad write");
    good_in();
    hcw_step(APU_VGPU_HCW_OK, "color");
    hcw_step(APU_VGPU_HCW_FAULT, "color again");
    check("color stays", hcw.origin == APU_VGPU_FTX_ORIGIN &&
          hcw.neighbor == APU_VGPU_FTX_NEIGHBOR &&
          hcw.base == APU_VGPU_RPW_DST);
    cxr.height = 16'd64;
    hcr_step(APU_VGPU_HCR_FAULT, "read scissor");
    check("read rejected", !hcr.valid);
    good_in();
    fail_rd = 1'b1;
    hcr_step(APU_VGPU_HCR_FAULT, "bad read");
    clear_lane = 1'b1;
    hcr_step(APU_VGPU_HCR_FAULT, "clear lane");
    swap_lanes = 1'b1;
    hcr_step(APU_VGPU_HCR_FAULT, "swapped lanes");
    hcr_step(APU_VGPU_HCR_OK, "read color");
    hcr_step(APU_VGPU_HCR_FAULT, "read again");
    check("read stays", hcr.origin == APU_VGPU_FTX_ORIGIN &&
          hcr.base == APU_VGPU_RPW_DST && hcr.base != APU_VGPU_ACW_ADDR);
    b0 = APU_VGPU_CLEAR_R;
    hcx_step(APU_VGPU_HCX_FAULT, "clear red first");
    check("clear red rejected", !hcx.valid);
    b0 = APU_VGPU_CLEAR_B;
    hcx_step(APU_VGPU_HCX_FAULT, "blue first");
    check("blue rejected", !hcx.valid);
    b0 = APU_VGPU_CLEAR_A;
    hcx_step(APU_VGPU_HCX_FAULT, "high byte first");
    check("high byte rejected", !hcx.valid);
    b0 = 8'h00;
    hcx_step(APU_VGPU_HCX_OK, "sample red first");
    check("sample red", hcx.valid && hcx.b0 == 8'h00 && hcx.off0 == 16'd0 &&
          hcx.x0 == 7'd0 && hcx.origin == APU_VGPU_FTX_ORIGIN &&
          hcx.origin != APU_VGPU_CLEAR_WORD);
    hcx_step(APU_VGPU_HCX_FAULT, "order again");
    check("order stays", hcx.b0 == 8'h00 && hcx.origin == APU_VGPU_FTX_ORIGIN);

    pulse_reset();
    check("reset clears", hcw == '0 && hcr == '0 && hcx == '0);
    gtr = '0;
    cxr = '0;
    hcw_step(APU_VGPU_HCW_EMPTY, "after reset");
    good_in();
    hcw_step(APU_VGPU_HCW_OK, "color after reset");

    if (errors != 0) $fatal(1, "APU vgpu hcw errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_hcw cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
