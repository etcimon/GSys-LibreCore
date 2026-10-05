// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_ocw;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_ftk_t ftk;
  apu_vgpu_cxr_t cxr;
  logic ocw_req = 0, ocw_rdy, ocw_cpl_v, ocw_cpl_r = 0;
  apu_vgpu_ocw_cpl_t ocw_cpl;
  apu_vgpu_ocw_t ocw;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, wr_seen = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic ocr_req = 0, ocr_rdy, ocr_cpl_v, ocr_cpl_r = 0;
  apu_vgpu_ocr_cpl_t ocr_cpl;
  apu_vgpu_ocr_t ocr;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic [7:0] b0 = 0;
  logic ocx_req = 0, ocx_rdy, ocx_cpl_v, ocx_cpl_r = 0;
  apu_vgpu_ocx_cpl_t ocx_cpl, off_cpl;
  apu_vgpu_ocx_t ocx, off_ocx;
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

  g6lc_apu_vgpu_ocw #(.Enable(1'b1)) i_ocw (
    .clk_i(clk), .rst_ni, .ftk_i(ftk), .cxr_i(cxr),
    .req_valid_i(ocw_req), .req_ready_o(ocw_rdy),
    .cpl_valid_o(ocw_cpl_v), .cpl_ready_i(ocw_cpl_r), .cpl_o(ocw_cpl), .ocw_o(ocw),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_ocr #(.Enable(1'b1)) i_ocr (
    .clk_i(clk), .rst_ni, .ocw_i(ocw), .ftk_i(ftk), .cxr_i(cxr),
    .req_valid_i(ocr_req), .req_ready_o(ocr_rdy),
    .cpl_valid_o(ocr_cpl_v), .cpl_ready_i(ocr_cpl_r), .cpl_o(ocr_cpl), .ocr_o(ocr),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_ocx #(.Enable(1'b1)) i_ocx (
    .clk_i(clk), .rst_ni, .ocr_i(ocr), .b0_i(b0),
    .req_valid_i(ocx_req), .req_ready_o(ocx_rdy),
    .cpl_valid_o(ocx_cpl_v), .cpl_ready_i(ocx_cpl_r), .cpl_o(ocx_cpl), .ocx_o(ocx)
  );
  g6lc_apu_vgpu_ocx_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .ocr_i(ocr), .b0_i(b0),
    .req_valid_i(ocx_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(ocx_cpl_r), .cpl_o(off_cpl), .ocx_o(off_ocx)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu ocw timeout case=%0d", cases); end

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
      if (wr_addr != APU_VGPU_OCW_ADDR ||
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
      if (rd_addr != APU_VGPU_OCW_ADDR ||
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
    ftk = '0;
    ftk.valid = 1'b1;
    ftk.refused = 1'b0;
    ftk.origin = APU_VGPU_FTX_ORIGIN;
    ftk.neighbor = APU_VGPU_FTX_NEIGHBOR;
    cxr = '0;
    cxr.valid = 1'b1;
    cxr.width = 16'd640;
    cxr.height = 16'd480;
    b0 = 8'h00;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_ocx == '0 &&
          off_cpl == '0);
  endtask

  task automatic ocw_step(input apu_vgpu_ocw_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!ocw_rdy) @(negedge clk);
    cases++;
    n0 = nwrite;
    ocw_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ocw_req = 1'b0;
    while (!ocw_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), ocw_cpl.status == st);
    quiet();
    if (st == APU_VGPU_OCW_OK) begin
      check("color", ocw.valid && ocw.off0 == 16'd0 && ocw.off1 == 16'd4 &&
            ocw.x0 == 7'd0 && ocw.x1 == 7'd1 &&
            ocw.origin == APU_VGPU_FTX_ORIGIN &&
            ocw.neighbor == APU_VGPU_FTX_NEIGHBOR &&
            ocw.origin != APU_VGPU_CLEAR_WORD &&
            ocw.base == APU_VGPU_GPW_ADDR &&
            ocw.base != APU_VGPU_ACW_ADDR);
      check("one write", nwrite == n0 + 1 && !order_bad && !data_bad &&
            wr_seen == APU_VGPU_GPW_ADDR && wr_seen != APU_VGPU_ACW_ADDR &&
            wr_seen != APU_VGPU_GBW_ADDR);
    end else if (name == "bad write") begin
      check("one write failed", nwrite == n0 + 1 && !ocw.valid);
    end else check("no write", nwrite == n0);
    @(negedge clk);
    check($sformatf("%s held", name), ocw_cpl_v);
    ocw_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ocw_cpl_r = 1'b0;
    while (ocw_cpl_v) @(negedge clk);
  endtask

  task automatic ocr_step(input apu_vgpu_ocr_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!ocr_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    ocr_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ocr_req = 1'b0;
    while (!ocr_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), ocr_cpl.status == st);
    quiet();
    if (st == APU_VGPU_OCR_OK) begin
      check("read color", ocr.valid && ocr.origin == APU_VGPU_FTX_ORIGIN &&
            ocr.neighbor == APU_VGPU_FTX_NEIGHBOR && ocr.off0 == 16'd0 &&
            ocr.x0 == 7'd0 && ocr.base == APU_VGPU_GPW_ADDR &&
            ocr.base != APU_VGPU_ACW_ADDR);
      check("one read", nread == n0 + 1 && !rd_order &&
            rd_seen == APU_VGPU_GPW_ADDR && rd_seen != APU_VGPU_ACW_ADDR);
    end else if (name == "bad read" || name == "clear lane" ||
                 name == "swapped lanes") begin
      check("one read failed", nread == n0 + 1 && !ocr.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), ocr_cpl_v);
    ocr_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ocr_cpl_r = 1'b0;
    while (ocr_cpl_v) @(negedge clk);
  endtask

  task automatic ocx_step(input apu_vgpu_ocx_status_e st, input string name);
    @(negedge clk);
    while (!ocx_rdy) @(negedge clk);
    cases++;
    ocx_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ocx_req = 1'b0;
    while (!ocx_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), ocx_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), ocx_cpl_v);
    ocx_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ocx_cpl_r = 1'b0;
    while (ocx_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    ocw_req = 1'b0;
    ocr_req = 1'b0;
    ocx_req = 1'b0;
    ocw_cpl_r = 1'b0;
    ocr_cpl_r = 1'b0;
    ocx_cpl_r = 1'b0;
    wr_rsp_v = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    ftk = '0;
    cxr = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          ocw == '0 && ocr == '0 && ocx == '0);
    check("profiles keep the window off",
          !ApuOff.OcwEn && !ApuOff.OcrEn && !ApuOff.OcxEn &&
          !ApuP1Transport.OcwEn && !ApuP1Transport.OcrEn &&
          !ApuP1Transport.OcxEn &&
          !ApuHarness.OcwEn && !ApuHarness.OcrEn && !ApuHarness.OcxEn &&
          !ApuSchedBoth.OcwEn && !ApuSchedBoth.OcrEn && !ApuSchedBoth.OcxEn &&
          !ApuBadVirglGrant.OcwEn && !ApuBadVirglGrant.OcrEn &&
          !ApuBadVirglGrant.OcxEn);
    cfg = ApuP1Transport;
    cfg.OcwEn = 1'b1;
    cfg.OcrEn = 1'b1;
    cfg.OcxEn = 1'b1;
    check("window does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.OcwEn = 1'b1;
    cfg.OcrEn = 1'b1;
    cfg.OcxEn = 1'b1;
    check("window does not legalize virgl", !apu_cfg_legal(cfg));
    check("window address",
          APU_VGPU_OCW_ADDR == 64'h88020000 &&
          APU_VGPU_OCW_ADDR == APU_VGPU_GPW_ADDR &&
          APU_VGPU_OCW_ADDR != APU_VGPU_ACW_ADDR &&
          APU_VGPU_FTX_ORIGIN != APU_VGPU_CLEAR_WORD &&
          APU_VGPU_FTX_ORIGIN != APU_VGPU_FTX_NEIGHBOR);

    ocw_step(APU_VGPU_OCW_EMPTY, "color empty");
    ocr_step(APU_VGPU_OCR_EMPTY, "read empty");
    ocx_step(APU_VGPU_OCX_EMPTY, "order empty");
    good_in();
    cxr.height = 16'd64;
    ocw_step(APU_VGPU_OCW_FAULT, "bad scissor");
    good_in();
    ftk.refused = 1'b1;
    ocw_step(APU_VGPU_OCW_FAULT, "refused");
    good_in();
    ftk.origin = APU_VGPU_CLEAR_WORD;
    ocw_step(APU_VGPU_OCW_FAULT, "clear origin");
    good_in();
    ftk.neighbor = APU_VGPU_CLEAR_WORD;
    ocw_step(APU_VGPU_OCW_FAULT, "clear neighbor");
    good_in();
    fail_wr = 1'b1;
    ocw_step(APU_VGPU_OCW_FAULT, "bad write");
    good_in();
    ocw_step(APU_VGPU_OCW_OK, "color");
    ocw_step(APU_VGPU_OCW_FAULT, "color again");
    check("color stays", ocw.origin == APU_VGPU_FTX_ORIGIN &&
          ocw.neighbor == APU_VGPU_FTX_NEIGHBOR &&
          ocw.base == APU_VGPU_GPW_ADDR);
    cxr.height = 16'd64;
    ocr_step(APU_VGPU_OCR_FAULT, "read scissor");
    check("read rejected", !ocr.valid);
    good_in();
    fail_rd = 1'b1;
    ocr_step(APU_VGPU_OCR_FAULT, "bad read");
    clear_lane = 1'b1;
    ocr_step(APU_VGPU_OCR_FAULT, "clear lane");
    swap_lanes = 1'b1;
    ocr_step(APU_VGPU_OCR_FAULT, "swapped lanes");
    ocr_step(APU_VGPU_OCR_OK, "read color");
    ocr_step(APU_VGPU_OCR_FAULT, "read again");
    check("read stays", ocr.origin == APU_VGPU_FTX_ORIGIN &&
          ocr.base == APU_VGPU_GPW_ADDR && ocr.base != APU_VGPU_ACW_ADDR);
    b0 = APU_VGPU_CLEAR_R;
    ocx_step(APU_VGPU_OCX_FAULT, "clear red first");
    check("clear red rejected", !ocx.valid);
    b0 = APU_VGPU_CLEAR_B;
    ocx_step(APU_VGPU_OCX_FAULT, "blue first");
    check("blue rejected", !ocx.valid);
    b0 = APU_VGPU_CLEAR_A;
    ocx_step(APU_VGPU_OCX_FAULT, "high byte first");
    check("high byte rejected", !ocx.valid);
    b0 = 8'h00;
    ocx_step(APU_VGPU_OCX_OK, "sample red first");
    check("sample red", ocx.valid && ocx.b0 == 8'h00 && ocx.off0 == 16'd0 &&
          ocx.x0 == 7'd0 && ocx.origin == APU_VGPU_FTX_ORIGIN &&
          ocx.origin != APU_VGPU_CLEAR_WORD);
    ocx_step(APU_VGPU_OCX_FAULT, "order again");
    check("order stays", ocx.b0 == 8'h00 && ocx.origin == APU_VGPU_FTX_ORIGIN);

    pulse_reset();
    check("reset clears", ocw == '0 && ocr == '0 && ocx == '0);
    ftk = '0;
    cxr = '0;
    ocw_step(APU_VGPU_OCW_EMPTY, "after reset");
    good_in();
    ocw_step(APU_VGPU_OCW_OK, "color after reset");

    if (errors != 0) $fatal(1, "APU vgpu ocw errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_ocw cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
