// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_tuw;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_rfx_t rfx;
  apu_vgpu_rfw_t rfw;
  logic tuw_req = 0, tuw_rdy, tuw_cpl_v, tuw_cpl_r = 0;
  apu_vgpu_tuw_cpl_t tuw_cpl;
  apu_vgpu_tuw_t tuw;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, wr_seen0 = 0, wr_seen1 = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic tur_req = 0, tur_rdy, tur_cpl_v, tur_cpl_r = 0;
  apu_vgpu_tur_cpl_t tur_cpl;
  apu_vgpu_tur_t tur;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen0 = 0, rd_seen1 = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic tux_req = 0, tux_rdy, tux_cpl_v, tux_cpl_r = 0;
  apu_vgpu_tux_cpl_t tux_cpl, off_cpl;
  apu_vgpu_tux_t tux, off_tux;
  logic off_rdy, off_v;
  logic fail_wr = 0, fail_idx = 0, fail_rd = 0, scene_id = 0, scene_idx = 0;
  logic order_bad = 0, data_bad = 0, rd_order = 0;
  logic [255:0] stored0 = 0, stored1 = 0;
  int errors = 0, checks = 0, cycles = 0, cases = 0;
  int nwrite = 0, wr_base = 0, nread = 0, rd_base = 0;

  localparam logic [255:0] ElemBeat = {192'h0, VGPU_RESP_HDR_BYTES, APU_VGPU_TUW_ID};
  localparam logic [255:0] IdxBeat  = {224'h0, APU_VGPU_TUW_IDXV, 16'd0};

  assign wr_rdy = wr_v && rst_ni && !wr_rsp_v;
  assign rd_rdy = rd_v && rst_ni && !rd_rsp_v;

  g6lc_apu_vgpu_tuw #(.Enable(1'b1)) i_tuw (
    .clk_i(clk), .rst_ni, .rfx_i(rfx), .rfw_i(rfw),
    .req_valid_i(tuw_req), .req_ready_o(tuw_rdy),
    .cpl_valid_o(tuw_cpl_v), .cpl_ready_i(tuw_cpl_r), .cpl_o(tuw_cpl), .tuw_o(tuw),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_tur #(.Enable(1'b1)) i_tur (
    .clk_i(clk), .rst_ni, .tuw_i(tuw), .rfx_i(rfx),
    .req_valid_i(tur_req), .req_ready_o(tur_rdy),
    .cpl_valid_o(tur_cpl_v), .cpl_ready_i(tur_cpl_r), .cpl_o(tur_cpl), .tur_o(tur),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_tux #(.Enable(1'b1)) i_tux (
    .clk_i(clk), .rst_ni, .tur_i(tur), .tuw_i(tuw),
    .req_valid_i(tux_req), .req_ready_o(tux_rdy),
    .cpl_valid_o(tux_cpl_v), .cpl_ready_i(tux_cpl_r), .cpl_o(tux_cpl), .tux_o(tux)
  );
  g6lc_apu_vgpu_tux_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .tur_i(tur), .tuw_i(tuw),
    .req_valid_i(tux_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(tux_cpl_r), .cpl_o(off_cpl), .tux_o(off_tux)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu tuw timeout case=%0d", cases); end

  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      wr_rsp_v <= 1'b0;
      nwrite <= 0;
      order_bad <= 1'b0;
      data_bad <= 1'b0;
      stored0 <= '0;
      stored1 <= '0;
    end else if (wr_rsp_v && wr_rsp_rdy) wr_rsp_v <= 1'b0;
    else if (wr_v && wr_rdy) begin
      int idx;
      logic [63:0] want;
      logic [31:0] wlen;
      logic [255:0] wdat;
      idx = nwrite - wr_base;
      want = idx == 0 ? APU_VGPU_TUW_ELEM : APU_VGPU_TUW_IDX;
      wlen = idx == 0 ? 32'd8 : 32'd4;
      wdat = idx == 0 ? ElemBeat : IdxBeat;
      if (wr_addr != want || wr_len != wlen) order_bad <= 1'b1;
      if (idx == 0 && wr_data[63:0] != wdat[63:0]) data_bad <= 1'b1;
      if (idx == 1 && wr_data[31:0] != wdat[31:0]) data_bad <= 1'b1;
      if (idx == 0) begin
        wr_seen0 <= wr_addr;
        stored0 <= wr_data;
      end
      wr_seen1 <= wr_addr;
      stored1 <= wr_data;
      wr_rsp_addr <= wr_addr;
      wr_rsp_ok <= !(idx == 0 ? fail_wr : fail_idx);
      if (idx == 0) fail_wr <= 1'b0;
      else fail_idx <= 1'b0;
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
      int idx;
      logic [63:0] want;
      logic [31:0] rlen;
      logic [255:0] beat;
      idx = nread - rd_base;
      want = idx == 0 ? APU_VGPU_TUW_ELEM : APU_VGPU_TUW_IDX;
      rlen = idx == 0 ? 32'd8 : 32'd4;
      beat = idx == 0 ? stored0 : stored1;
      if (idx == 0 && scene_id) beat[31:0] = 32'd0;
      if (idx == 1 && scene_idx) beat[31:16] = 16'd1;
      if (rd_addr != want || rd_len != rlen) rd_order <= 1'b1;
      if (idx == 0) rd_seen0 <= rd_addr;
      rd_seen1 <= rd_addr;
      rd_rsp_addr <= rd_addr;
      rd_rsp_len <= rd_len;
      rd_rsp_data <= beat;
      rd_rsp_ok <= !fail_rd;
      fail_rd <= 1'b0;
      if (idx == 0) scene_id <= 1'b0;
      if (idx == 1) scene_idx <= 1'b0;
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
    rfx = '0;
    rfx.valid = 1'b1;
    rfx.fence = APU_VGPU_RFW_FENCE;
    rfx.flags = VGPU_FLAG_FENCE;
    rfx.resp = VGPU_RESP_OK_NODATA;
    rfw = '0;
    rfw.valid = 1'b1;
    rfw.resp = VGPU_RESP_OK_NODATA;
    rfw.flags = VGPU_FLAG_FENCE;
    rfw.fence = APU_VGPU_RFW_FENCE;
    rfw.ctx_id = APU_VGPU_CTX_ID;
    rfw.addr = APU_VGPU_RFW_ADDR;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_tux == '0 &&
          off_cpl == '0);
  endtask

  task automatic tuw_step(input apu_vgpu_tuw_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!tuw_rdy) @(negedge clk);
    cases++;
    n0 = nwrite;
    wr_base = nwrite;
    tuw_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tuw_req = 1'b0;
    while (!tuw_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), tuw_cpl.status == st);
    quiet();
    if (st == APU_VGPU_TUW_OK) begin
      check("used", tuw.valid && tuw.elem_id == APU_VGPU_TUW_ID &&
            tuw.elem_id != 32'd0 && tuw.elem_len == VGPU_RESP_HDR_BYTES &&
            tuw.used_idx == APU_VGPU_TUW_IDXV && tuw.used_idx != 16'd1 &&
            tuw.elem_addr == APU_VGPU_TUW_ELEM &&
            tuw.elem_addr != APU_VGPU_GCW_ELEM &&
            tuw.idx_addr == APU_VGPU_TUW_IDX);
      check("two writes", nwrite == n0 + 2 && !order_bad && !data_bad &&
            wr_seen0 == APU_VGPU_TUW_ELEM && wr_seen1 == APU_VGPU_TUW_IDX);
    end else if (name == "bad write") begin
      check("one write failed", nwrite == n0 + 1 && !tuw.valid);
    end else if (name == "bad index write") begin
      check("two writes failed", nwrite == n0 + 2 && !tuw.valid);
    end else check("no write", nwrite == n0);
    @(negedge clk);
    check($sformatf("%s held", name), tuw_cpl_v);
    tuw_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tuw_cpl_r = 1'b0;
    while (tuw_cpl_v) @(negedge clk);
  endtask

  task automatic tur_step(input apu_vgpu_tur_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!tur_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    rd_base = nread;
    tur_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tur_req = 1'b0;
    while (!tur_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), tur_cpl.status == st);
    quiet();
    if (st == APU_VGPU_TUR_OK) begin
      check("echo", tur.valid && tur.elem_id == APU_VGPU_TUW_ID &&
            tur.used_idx == APU_VGPU_TUW_IDXV &&
            tur.elem_addr == APU_VGPU_TUW_ELEM);
      check("two reads", nread == n0 + 2 && !rd_order &&
            rd_seen0 == APU_VGPU_TUW_ELEM && rd_seen1 == APU_VGPU_TUW_IDX);
    end else if (name == "bad read" || name == "scene id") begin
      check("one read failed", nread == n0 + 1 && !tur.valid);
    end else if (name == "scene idx") begin
      check("two reads failed", nread == n0 + 2 && !tur.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), tur_cpl_v);
    tur_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tur_cpl_r = 1'b0;
    while (tur_cpl_v) @(negedge clk);
  endtask

  task automatic tux_step(input apu_vgpu_tux_status_e st, input string name);
    @(negedge clk);
    while (!tux_rdy) @(negedge clk);
    cases++;
    tux_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tux_req = 1'b0;
    while (!tux_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), tux_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), tux_cpl_v);
    tux_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    tux_cpl_r = 1'b0;
    while (tux_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    tuw_req = 1'b0;
    tur_req = 1'b0;
    tux_req = 1'b0;
    tuw_cpl_r = 1'b0;
    tur_cpl_r = 1'b0;
    tux_cpl_r = 1'b0;
    wr_rsp_v = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    rfx = '0;
    rfw = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          tuw == '0 && tur == '0 && tux == '0);
    check("profiles keep the used ring off",
          !ApuOff.TuwEn && !ApuOff.TurEn && !ApuOff.TuxEn &&
          !ApuP1Transport.TuwEn && !ApuP1Transport.TurEn &&
          !ApuP1Transport.TuxEn &&
          !ApuHarness.TuwEn && !ApuHarness.TurEn && !ApuHarness.TuxEn &&
          !ApuSchedBoth.TuwEn && !ApuSchedBoth.TurEn && !ApuSchedBoth.TuxEn &&
          !ApuBadVirglGrant.TuwEn && !ApuBadVirglGrant.TurEn &&
          !ApuBadVirglGrant.TuxEn);
    cfg = ApuP1Transport;
    cfg.TuwEn = 1'b1;
    cfg.TurEn = 1'b1;
    cfg.TuxEn = 1'b1;
    check("used ring does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.TuwEn = 1'b1;
    cfg.TurEn = 1'b1;
    cfg.TuxEn = 1'b1;
    check("used ring does not legalize virgl", !apu_cfg_legal(cfg));
    check("known used",
          APU_VGPU_TUW_ELEM != APU_VGPU_GCW_ELEM &&
          APU_VGPU_TUW_IDX != APU_VGPU_GCW_IDX &&
          APU_VGPU_TUW_IDX == APU_VGPU_TUW_ELEM + 64'd8 &&
          APU_VGPU_TUW_ID != 32'd0 &&
          APU_VGPU_TUW_IDXV != 16'd1);

    tuw_step(APU_VGPU_TUW_EMPTY, "write empty");
    tur_step(APU_VGPU_TUR_EMPTY, "read empty");
    tux_step(APU_VGPU_TUX_EMPTY, "index empty");
    good_in();
    fail_wr = 1'b1;
    tuw_step(APU_VGPU_TUW_FAULT, "bad write");
    fail_idx = 1'b1;
    tuw_step(APU_VGPU_TUW_FAULT, "bad index write");
    tuw_step(APU_VGPU_TUW_OK, "used element");
    tuw_step(APU_VGPU_TUW_FAULT, "write again");
    fail_rd = 1'b1;
    tur_step(APU_VGPU_TUR_FAULT, "bad read");
    scene_id = 1'b1;
    tur_step(APU_VGPU_TUR_FAULT, "scene id");
    scene_idx = 1'b1;
    tur_step(APU_VGPU_TUR_FAULT, "scene idx");
    tur_step(APU_VGPU_TUR_OK, "echo used");
    tur_step(APU_VGPU_TUR_FAULT, "read again");
    tux_step(APU_VGPU_TUX_OK, "index two");
    check("index two", tux.valid && tux.used_idx == 16'd2 &&
          tux.used_idx != 16'd1 && tux.elem_id == 32'd1);
    tux_step(APU_VGPU_TUX_FAULT, "index again");
    check("index stays", tux.used_idx == APU_VGPU_TUW_IDXV);

    pulse_reset();
    check("reset clears", tuw == '0 && tur == '0 && tux == '0);
    rfx = '0;
    rfw = '0;
    tuw_step(APU_VGPU_TUW_EMPTY, "after reset");
    good_in();
    tuw_step(APU_VGPU_TUW_OK, "write after reset");

    if (errors != 0) $fatal(1, "APU vgpu tuw errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_tuw cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
