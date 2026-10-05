// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

`timescale 1ns/1ps

module tb_g6lc_apu_vgpu_ruw;
  import g6lc_apu_cfg_pkg::*;
  import g6lc_apu_pkg::*;

  logic clk = 0, rst_ni = 0;
  apu_vgpu_roy_t roy;
  logic ruw_req = 0, ruw_rdy, ruw_cpl_v, ruw_cpl_r = 0;
  apu_vgpu_ruw_cpl_t ruw_cpl;
  apu_vgpu_ruw_t ruw;
  logic wr_v, wr_rdy, wr_rsp_v = 0, wr_rsp_rdy, wr_rsp_ok = 0;
  logic [63:0] wr_addr, wr_rsp_addr = 0, wr_seen0 = 0, wr_seen1 = 0;
  logic [31:0] wr_len;
  logic [255:0] wr_data;
  logic rul_req = 0, rul_rdy, rul_cpl_v, rul_cpl_r = 0;
  apu_vgpu_rul_cpl_t rul_cpl;
  apu_vgpu_rul_t rul;
  logic rd_v, rd_rdy, rd_rsp_v = 0, rd_rsp_rdy, rd_rsp_ok = 0;
  logic [63:0] rd_addr, rd_rsp_addr = 0, rd_seen0 = 0, rd_seen1 = 0;
  logic [31:0] rd_len, rd_rsp_len = 0;
  logic [255:0] rd_rsp_data = 0;
  logic rux_req = 0, rux_rdy, rux_cpl_v, rux_cpl_r = 0;
  apu_vgpu_rux_cpl_t rux_cpl, off_cpl;
  apu_vgpu_rux_t rux, off_rux;
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

  g6lc_apu_vgpu_ruw #(.Enable(1'b1)) i_ruw (
    .clk_i(clk), .rst_ni, .roy_i(roy),
    .req_valid_i(ruw_req), .req_ready_o(ruw_rdy),
    .cpl_valid_o(ruw_cpl_v), .cpl_ready_i(ruw_cpl_r), .cpl_o(ruw_cpl), .ruw_o(ruw),
    .wr_valid_o(wr_v), .wr_ready_i(wr_rdy), .wr_addr_o(wr_addr), .wr_len_o(wr_len),
    .wr_data_o(wr_data), .wr_rsp_valid_i(wr_rsp_v), .wr_rsp_ready_o(wr_rsp_rdy),
    .wr_rsp_ok_i(wr_rsp_ok), .wr_rsp_addr_i(wr_rsp_addr)
  );
  g6lc_apu_vgpu_rul #(.Enable(1'b1)) i_rul (
    .clk_i(clk), .rst_ni, .ruw_i(ruw), .roy_i(roy),
    .req_valid_i(rul_req), .req_ready_o(rul_rdy),
    .cpl_valid_o(rul_cpl_v), .cpl_ready_i(rul_cpl_r), .cpl_o(rul_cpl), .rul_o(rul),
    .rd_valid_o(rd_v), .rd_ready_i(rd_rdy), .rd_addr_o(rd_addr), .rd_len_o(rd_len),
    .rd_rsp_valid_i(rd_rsp_v), .rd_rsp_ready_o(rd_rsp_rdy), .rd_rsp_ok_i(rd_rsp_ok),
    .rd_rsp_addr_i(rd_rsp_addr), .rd_rsp_len_i(rd_rsp_len), .rd_rsp_data_i(rd_rsp_data)
  );
  g6lc_apu_vgpu_rux #(.Enable(1'b1)) i_rux (
    .clk_i(clk), .rst_ni, .rul_i(rul), .ruw_i(ruw), .roy_i(roy),
    .req_valid_i(rux_req), .req_ready_o(rux_rdy),
    .cpl_valid_o(rux_cpl_v), .cpl_ready_i(rux_cpl_r), .cpl_o(rux_cpl), .rux_o(rux)
  );
  g6lc_apu_vgpu_rux_fixture #(.Enable(1'b0)) i_off (
    .clk_i(clk), .rst_ni, .rul_i(rul), .ruw_i(ruw), .roy_i(roy),
    .req_valid_i(rux_req), .req_ready_o(off_rdy),
    .cpl_valid_o(off_v), .cpl_ready_i(rux_cpl_r), .cpl_o(off_cpl), .rux_o(off_rux)
  );

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;
  initial begin #2000000; $fatal(1, "APU vgpu ruw timeout case=%0d", cases); end

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
    roy = '0;
    roy.valid = 1'b1;
    roy.fence = APU_VGPU_RFW_FENCE;
    roy.resp = VGPU_RESP_OK_NODATA;
  endtask

  task automatic quiet;
    check("off quiet", off_rdy == 1'b0 && off_v == 1'b0 && off_rux == '0 &&
          off_cpl == '0);
  endtask

  task automatic ruw_step(input apu_vgpu_ruw_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!ruw_rdy) @(negedge clk);
    cases++;
    n0 = nwrite;
    wr_base = nwrite;
    ruw_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ruw_req = 1'b0;
    while (!ruw_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), ruw_cpl.status == st);
    quiet();
    if (st == APU_VGPU_RUW_OK) begin
      check("used", ruw.valid && ruw.elem_id == APU_VGPU_TUW_ID &&
            ruw.elem_id != 32'd0 && ruw.elem_len == VGPU_RESP_HDR_BYTES &&
            ruw.used_idx == APU_VGPU_TUW_IDXV && ruw.used_idx != 16'd1 &&
            ruw.elem_addr == APU_VGPU_TUW_ELEM &&
            ruw.elem_addr != APU_VGPU_GCW_ELEM &&
            ruw.idx_addr == APU_VGPU_TUW_IDX);
      check("two writes", nwrite == n0 + 2 && !order_bad && !data_bad &&
            wr_seen0 == APU_VGPU_TUW_ELEM && wr_seen1 == APU_VGPU_TUW_IDX);
    end else if (name == "bad write") begin
      check("one write failed", nwrite == n0 + 1 && !ruw.valid);
    end else if (name == "bad index write") begin
      check("two writes failed", nwrite == n0 + 2 && !ruw.valid);
    end else check("no write", nwrite == n0);
    @(negedge clk);
    check($sformatf("%s held", name), ruw_cpl_v);
    ruw_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    ruw_cpl_r = 1'b0;
    while (ruw_cpl_v) @(negedge clk);
  endtask

  task automatic rul_step(input apu_vgpu_rul_status_e st, input string name);
    int n0;
    @(negedge clk);
    while (!rul_rdy) @(negedge clk);
    cases++;
    n0 = nread;
    rd_base = nread;
    rul_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rul_req = 1'b0;
    while (!rul_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rul_cpl.status == st);
    quiet();
    if (st == APU_VGPU_RUL_OK) begin
      check("echo", rul.valid && rul.elem_id == APU_VGPU_TUW_ID &&
            rul.used_idx == APU_VGPU_TUW_IDXV &&
            rul.elem_addr == APU_VGPU_TUW_ELEM);
      check("two reads", nread == n0 + 2 && !rd_order &&
            rd_seen0 == APU_VGPU_TUW_ELEM && rd_seen1 == APU_VGPU_TUW_IDX);
    end else if (name == "bad read" || name == "scene id") begin
      check("one read failed", nread == n0 + 1 && !rul.valid);
    end else if (name == "scene idx") begin
      check("two reads failed", nread == n0 + 2 && !rul.valid);
    end else check("no read", nread == n0);
    @(negedge clk);
    check($sformatf("%s held", name), rul_cpl_v);
    rul_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rul_cpl_r = 1'b0;
    while (rul_cpl_v) @(negedge clk);
  endtask

  task automatic rux_step(input apu_vgpu_rux_status_e st, input string name);
    @(negedge clk);
    while (!rux_rdy) @(negedge clk);
    cases++;
    rux_req = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rux_req = 1'b0;
    while (!rux_cpl_v) @(negedge clk);
    check($sformatf("%s status", name), rux_cpl.status == st);
    quiet();
    @(negedge clk);
    check($sformatf("%s held", name), rux_cpl_v);
    rux_cpl_r = 1'b1;
    @(posedge clk);
    @(negedge clk);
    rux_cpl_r = 1'b0;
    while (rux_cpl_v) @(negedge clk);
  endtask

  task automatic pulse_reset;
    @(negedge clk);
    rst_ni = 1'b0;
    ruw_req = 1'b0;
    rul_req = 1'b0;
    rux_req = 1'b0;
    ruw_cpl_r = 1'b0;
    rul_cpl_r = 1'b0;
    rux_cpl_r = 1'b0;
    wr_rsp_v = 1'b0;
    rd_rsp_v = 1'b0;
    repeat (2) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
  endtask

  initial begin
    apu_cfg_t cfg;
    roy = '0;
    @(negedge clk); rst_ni = 1'b0;
    repeat (3) @(negedge clk);
    rst_ni = 1'b1;
    @(posedge clk);
    check("off stays quiet", off_rdy == 1'b0 && off_v == 1'b0 &&
          ruw == '0 && rul == '0 && rux == '0);
    check("profiles keep the used ring off",
          !ApuOff.RuwEn && !ApuOff.RulEn && !ApuOff.RuxEn &&
          !ApuP1Transport.RuwEn && !ApuP1Transport.RulEn &&
          !ApuP1Transport.RuxEn &&
          !ApuHarness.RuwEn && !ApuHarness.RulEn && !ApuHarness.RuxEn &&
          !ApuSchedBoth.RuwEn && !ApuSchedBoth.RulEn && !ApuSchedBoth.RuxEn &&
          !ApuBadVirglGrant.RuwEn && !ApuBadVirglGrant.RulEn &&
          !ApuBadVirglGrant.RuxEn);
    cfg = ApuP1Transport;
    cfg.RuwEn = 1'b1;
    cfg.RulEn = 1'b1;
    cfg.RuxEn = 1'b1;
    check("used ring does not require virgl", apu_cfg_legal(cfg) && !cfg.FeatureVirgl);
    cfg = ApuBadVirglGrant;
    cfg.RuwEn = 1'b1;
    cfg.RulEn = 1'b1;
    cfg.RuxEn = 1'b1;
    check("used ring does not legalize virgl", !apu_cfg_legal(cfg));
    check("known used",
          APU_VGPU_TUW_ELEM != APU_VGPU_GCW_ELEM &&
          APU_VGPU_TUW_IDX != APU_VGPU_GCW_IDX &&
          APU_VGPU_TUW_IDX == APU_VGPU_TUW_ELEM + 64'd8 &&
          APU_VGPU_TUW_ID != 32'd0 &&
          APU_VGPU_TUW_IDXV != 16'd1);

    ruw_step(APU_VGPU_RUW_EMPTY, "write empty");
    rul_step(APU_VGPU_RUL_EMPTY, "read empty");
    rux_step(APU_VGPU_RUX_EMPTY, "index empty");
    good_in();
    roy.fence = APU_VGPU_SCENE_FENCE;
    ruw_step(APU_VGPU_RUW_FAULT, "scene fence");
    good_in();
    fail_wr = 1'b1;
    ruw_step(APU_VGPU_RUW_FAULT, "bad write");
    fail_idx = 1'b1;
    ruw_step(APU_VGPU_RUW_FAULT, "bad index write");
    ruw_step(APU_VGPU_RUW_OK, "used element");
    ruw_step(APU_VGPU_RUW_FAULT, "write again");
    fail_rd = 1'b1;
    rul_step(APU_VGPU_RUL_FAULT, "bad read");
    scene_id = 1'b1;
    rul_step(APU_VGPU_RUL_FAULT, "scene id");
    scene_idx = 1'b1;
    rul_step(APU_VGPU_RUL_FAULT, "scene idx");
    rul_step(APU_VGPU_RUL_OK, "echo used");
    rul_step(APU_VGPU_RUL_FAULT, "read again");
    roy.fence = APU_VGPU_SCENE_FENCE;
    rux_step(APU_VGPU_RUX_FAULT, "check scene fence");
    check("check rejected", !rux.valid);
    good_in();
    rux_step(APU_VGPU_RUX_OK, "index two");
    check("index two", rux.valid && rux.used_idx == 16'd2 &&
          rux.used_idx != 16'd1 && rux.elem_id == 32'd1);
    rux_step(APU_VGPU_RUX_FAULT, "index again");
    check("index stays", rux.used_idx == APU_VGPU_TUW_IDXV);

    pulse_reset();
    check("reset clears", ruw == '0 && rul == '0 && rux == '0);
    roy = '0;
    ruw_step(APU_VGPU_RUW_EMPTY, "after reset");
    good_in();
    ruw_step(APU_VGPU_RUW_OK, "write after reset");

    if (errors != 0) $fatal(1, "APU vgpu ruw errors=%0d", errors);
    else begin
      $display("PASS tb_g6lc_apu_vgpu_ruw cases=%0d checks=%0d cycles=%0d errors=0",
               cases, checks, cycles);
      $finish;
    end
  end
endmodule
